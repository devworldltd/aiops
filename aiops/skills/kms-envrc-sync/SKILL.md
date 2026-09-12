---
name: kms-envrc-sync
description: "`.envrc`의 secret들을 DevWorld KMS에 일괄 등록한다. `.envrc`의 KMS_TOKEN으로 인증하며, 각 secret을 local/dev/prod 3개 environment에 동일한 이름·값으로 등록한다. 같은 이름의 secret이 이미 있고 값도 같으면 스킵, 값이 다르면 사용자에게 확인 후 진행한다. 등록 확인 후에는 `.envrc`에 이미 있는 kms_reveal_by_name 함수를 이용해 평문 줄을 reveal 호출로 전환할 수도 있다. 사용법: /aiops:kms-envrc-sync [envrc경로] [--service=<name>] [--only=A,B] [--exclude=A,B] | /aiops:kms-envrc-sync rewrite [envrc경로] --items=A,B [--env=local] [--confirm]"
---

# /aiops:kms-envrc-sync — `.envrc` → KMS 일괄 등록

`.envrc`에 평문으로 흩어져 있는 secret들을 **DevWorld KMS**로 이관한다. `/aiops:kms`의 `register` 절차(§4)를 그대로 따르되, 한 번에 여러 개를 스캔·비교·확인까지 자동화한다.

- 인증은 `.envrc` 안의 **`KMS_TOKEN`**을 사용한다 (셸 환경변수가 아니라 파일에서 직접 읽는다).
- 등록 대상 secret 하나당 **environment 3개(local/dev/prod)**에 **이름·값 동일**하게 3개의 KMS secret을 만든다 (KMS는 name+service+environment 조합으로 구분하므로 environment별 레코드가 별도로 필요하다).
- 이미 같은 이름의 secret이 있으면: **값이 같으면 그냥 진행(스킵)**, **값이 다르면 사용자에게 확인**한다 — 절대 조용히 덮어쓰지 않는다.
- 신규 등록(`NEW`)은 `.envrc`의 `KMS_TOKEN`만으로 승인 게이트를 통과한다 — `KMS_WRITE_APPROVAL_TOKEN` 같은 별도 승인 토큰은 요구하지 않는다 (`/aiops:kms` §4 전제 조건 및 aiops-codex v0.4.4와 동일 규약). 사용자 확인이 필요한 것은 `CONFLICT` 건뿐이다.

## 절대 원칙 (`/aiops:kms`와 동일 + 추가)

1. Secret 값과 `KMS_TOKEN`을 로그·보고·커밋·PR·이슈 어디에도 남기지 않는다. 비교도 셸 안에서만 하고 값 자체를 echo 하지 않는다.
2. `.envrc`는 신뢰할 수 있는 로컬 파일이라 가정하고 서브셸에서 `source` 하지만, 그 서브셸 밖으로 값을 내보내지 않는다 (현재 세션 환경 오염 금지).
3. 값이 다른 충돌 건은 **사용자 승인 없이 덮어쓰지 않는다.**
4. 신규 생성은 자유롭게 하되, 값이 다른 기존 secret의 **업데이트(PATCH)**는 KMS 앱의 `allow_update` 플래그가 켜져 있어야 가능하다 — 꺼져 있으면 업데이트 대신 "KMS UI에서 allow_update 활성화 필요"를 안내하고 스킵한다.
5. 삭제는 절대 하지 않는다.

---

## §0 인자 파싱

호출: `/aiops:kms-envrc-sync [envrc경로] [옵션]`

| 인자/옵션 | 기본값 | 효과 |
|-----------|--------|------|
| `<envrc경로>` | `.envrc` | 대상 파일 |
| `--service=<name>` | 현재 디렉토리 basename (또는 `.claude/config.json`의 `project_name`) | KMS에 등록할 `service` 값 (모든 secret 공통) |
| `--only=A,B,...` | (없음 = 전체) | 이 변수명들만 등록 대상으로 삼는다 |
| `--exclude=A,B,...` | (없음) | 기본 제외 목록에 추가로 더 제외한다 |
| `--envs=local,dev,prod` | `local,dev,prod` | 등록할 environment 목록 (필요 시 부분집합으로 축소 가능) |

**기본 제외 변수** (secret으로 등록하지 않음 — KMS 인증에 쓰이는 값 자체이므로):
`KMS_TOKEN`, `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`

---

## §1 `.envrc` 로드

```bash
ENVRC_PATH="${1:-.envrc}"
[[ -f "$ENVRC_PATH" ]] || { echo "❌ $ENVRC_PATH 를 찾을 수 없습니다."; exit 2; }

# export NAME= 선언(들여쓰기 허용)만 정규식으로 뽑고, 그 이름들의 "최종 값"만 서브셸에서
# 읽는다. before/after diff 방식은 쓰지 않는다 — 이 세션에 direnv 로 .envrc 가 이미
# 로드돼 있으면(흔한 경우) ambient 환경과 겹쳐 diff 로는 KMS_TOKEN 조차 못 잡는다(실측).
# 선행 공백을 허용하는 이유: `if [ -n "$KMS_TOKEN" ]; then export ...; fi` 처럼 export 가
# 블록 안에 들여써 있는 실제 사례가 있다 (kms_reveal_by_name 함수 본문에는 export 가
# 없으므로 함수 내부 지역 변수와 섞일 걱정은 없다).
mapfile -t DECLARED_NAMES < <(
  grep -oE '^[[:space:]]*export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=' "$ENVRC_PATH" \
    | sed -E 's/^[[:space:]]*export[[:space:]]+//; s/=$//' | awk '!seen[$0]++'
)

_load_final_values() {
  local body="source '$ENVRC_PATH' >/dev/null 2>&1"$'\n'
  local n
  for n in "${DECLARED_NAMES[@]}"; do
    body+="printf '%s\x1f%s\x1e' '$n' \"\${$n}\""$'\n'
  done
  bash -c "$body"
}
ENVRC_DUMP_RAW="$(_load_final_values)"
# ENVRC_DUMP_RAW 는 NAME\x1fVALUE\x1e 반복 — 이후 §2/§4 에서 이름별 최종 값 조회에
# 이 원시 덤프를 그대로 파싱해 쓴다(값은 echo 하지 않고 변수 대입에만 쓴다).

KMS_TOKEN="$(printf '%s' "$ENVRC_DUMP_RAW" | awk -F'\x1f' -v RS='\x1e' '$1=="KMS_TOKEN"{print $2}')"
[[ -n "$KMS_TOKEN" ]] || { echo "❌ $ENVRC_PATH 에 KMS_TOKEN 이 없습니다."; exit 2; }

KMS_URL="${KMS_URL:-$(jq -r '.kms_url // "https://kms.devworld.co.kr"' .claude/config.json 2>/dev/null || echo "https://kms.devworld.co.kr")}"
KMS_H=(-H "Authorization: Bearer $KMS_TOKEN" -H "Accept: application/json" -H "Content-Type: application/json")
# CF Access 자격 체인 초기화 (의무) — KMS용 CF 자격이 셸에 없거나 다른 용도의 자격이
# 남아 있으면 302 거부되므로, 항상 unset 후 키체인(MBP_KMS_KEY) 체인을 재로드한다.
unset CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET
[ -f ~/.kms/cf-access-env.sh ] && source ~/.kms/cf-access-env.sh
[[ -n "$CF_ACCESS_CLIENT_ID" && -n "$CF_ACCESS_CLIENT_SECRET" ]] && \
  KMS_H+=(-H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET")

curl -sf --max-time 5 "${KMS_H[@]}" "$KMS_URL/api/v1/health" >/dev/null \
  || { echo "❌ KMS 응답 없음: $KMS_URL — CF Access 뒤에 있다면 CF_ACCESS_CLIENT_ID/SECRET 이 셸에 로드됐는지도 확인"; exit 2; }
```

`DECLARED_NAMES`에서 기본 제외 목록(`KMS_TOKEN`, `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`) + `--exclude`로 지정된 이름을 뺀 나머지가 **등록 후보**다. `--only`가 있으면 그 목록과의 교집합만 남긴다. 값이 비어 있는 이름(reveal 실패 등)은 후보에서 제외하고 사유를 남긴다.

`SERVICE`는 `--service` → `.claude/config.json`의 `project_name` → 현재 디렉토리 basename 순으로 결정한다.

---

## §2 스캔 — 후보 × environment 별 상태 판정 (쓰기 없음)

각 후보 변수 `NAME` × 각 `ENV`(기본 local/dev/prod)에 대해:

```bash
curl -sf "${KMS_H[@]}" "$KMS_URL/api/v1/secrets?q=${NAME}&environment=${ENV}"
```

응답(`{"items":[...]}`)에서 `name`과 `service`가 **정확히 일치**하는 항목만 후보로 남긴다.

- **일치 항목 없음** → 상태 `NEW` (신규 생성 대상)
- **일치 항목 있음, `has_value=false`** → 상태 `EMPTY` (레코드는 있으나 값 없음 → 채워야 함, PATCH 대상)
- **일치 항목 있음, `has_value=true`** → reveal 해서 `.envrc` 값과 비교:
  ```bash
  REMOTE_VALUE="$(curl -sf -X POST "${KMS_H[@]}" "$KMS_URL/api/v1/secrets/<id>/reveal" | jq -r '.value')"
  ```
  - 값이 **같음** → 상태 `MATCH` (스킵, 승인 불필요)
  - 값이 **다름** → 상태 `CONFLICT` (사용자 확인 필요)

  값 비교는 셸 변수 안에서만 하고 `REMOTE_VALUE`/`.envrc` 값 어느 쪽도 echo 하지 않는다.

스캔 결과를 표로 요약해 보여준다 (**값은 절대 표시하지 않음**):

| NAME | local | dev | prod |
|------|:-----:|:---:|:----:|
| STRIPE_SECRET_KEY | NEW | MATCH | CONFLICT |
| ... | ... | ... | ... |

---

## §3 충돌 확인

`CONFLICT` 상태가 하나도 없으면 이 절은 스킵하고 §4로 진행한다.

`CONFLICT`가 있으면 **AskUserQuestion**으로 각 충돌 건(또는 동일 패턴이면 일괄)에 대해 사용자에게 확인한다. 절대 자동으로 덮어쓰지 않는다.

- 제시할 선택지(권장 3개):
  1. **기존 값 유지 (스킵)** — 추천값. `.envrc` 값을 등록하지 않고 그대로 둔다.
  2. **KMS 값을 `.envrc` 값으로 갱신** — §4에서 PATCH 시도 (allow_update 필요, 아래 참고)
  3. **이번 실행 중단**

여러 건이 충돌하면 한 번에 다중 선택 질문으로 묶어 물어봐도 되고, 건별로 나눠 물어봐도 된다 — 사용자 피로도를 고려해 판단한다.

---

## §4 실행

### NEW → 생성 (`/aiops:kms` §4와 동일한 스키마)

```bash
curl -sf -X POST "${KMS_H[@]}" "$KMS_URL/api/v1/secrets" -d @- <<JSON
{
  "name": "${NAME}",
  "service": "${SERVICE}",
  "environment": "${ENV}",
  "secret_type": "${SECRET_TYPE}",
  "status": "active",
  "description": ".envrc 일괄 이관 (/aiops:kms-envrc-sync)",
  "value": "${VALUE}"
}
JSON
```

`secret_type`은 `/aiops:kms` §4의 분류표를 그대로 따른다 (`*TOKEN*`→token, `*API_KEY*`/`*CLIENT_SECRET*`/`*SECRET_KEY*`→api_key, 사람이 입력하는 비밀번호→password, `*PRIVATE_KEY*`/SSH·인증서→ssh_key/certificate, 그 외 식별자류→other). 모호하면 `other`.

### EMPTY, 또는 CONFLICT 중 "갱신" 선택 → PATCH 시도

```bash
curl -s -X PATCH "${KMS_H[@]}" "$KMS_URL/api/v1/secrets/<id>" -d @- <<JSON
{
  "name": "${NAME}",
  "service": "${SERVICE}",
  "environment": "${ENV}",
  "secret_type": "${SECRET_TYPE}",
  "status": "active",
  "value": "${VALUE}"
}
JSON
```

- name/service/environment/secret_type은 **기존 저장값과 정확히 같아야 한다** (app-token PATCH는 식별 필드 불변 — 다르면 `400 immutable_field`).
- 앱의 `allow_update` 플래그가 꺼져 있으면 `403 app_update_forbidden`이 온다 → 이 건은 스킵 처리하고 "KMS Apps 화면에서 이 앱의 allow_update를 켠 뒤 재실행하세요"를 결과에 안내한다. **KMS_TOKEN 자체로는 이 플래그를 켤 수 없다.**

### MATCH, "스킵" 선택, 중단 선택된 CONFLICT → 아무 것도 하지 않음

---

## §5 결과 보고

값은 어떤 경우에도 포함하지 않는다. environment별 집계표로 보고한다:

```
## 🔐 .envrc → KMS 일괄 등록 결과
- KMS: ✅ OK (<KMS_URL>) / service=<SERVICE>
- 대상 secret: N개 × 3 environment

| NAME | local | dev | prod |
|------|-------|-----|------|
| STRIPE_SECRET_KEY | ✅ 생성 | ⏭️ 스킵(동일값) | ⚠️ 스킵(allow_update 필요) |
| ... | | | |

- 생성: X건 / 스킵(동일값): Y건 / 스킵(사용자 선택): Z건 / 차단(allow_update 필요): W건
- 차단 건이 있으면: KMS Apps 화면 → 해당 앱 상세 → allow_update 활성화 후 `/aiops:kms-envrc-sync` 재실행
```

---

## §6 (선택) `.envrc` 평문 → `kms_reveal_by_name` 전환

§4에서 KMS에 값이 이미 있는 것으로 확인된 이름들에 한해, `.envrc` 안의 평문 줄을 `.envrc`에 **이미 정의돼 있는** `kms_reveal_by_name(name, service, environment)` 부트스트랩 함수 호출로 바꿔 평문을 제거한다. 함수 자체는 새로 만들거나 수정하지 않는다 — 이 절은 §0~§5(등록)와 별개로, 사용자가 명시적으로 요청했을 때만 수행한다:

```
/aiops:kms-envrc-sync rewrite [envrc경로] [--service=<name>] [--env=local] --items=A,B,... [--confirm]
```

`--items`는 필수다(전체를 무조건 바꾸지 않는다 — §4에서 KMS 등록이 실제로 확인된 이름만 넘긴다). `--env`는 기본 `local`이다(`.envrc`는 보통 로컬 개발 환경이므로).

### 0. 함수 존재 확인 (선행)

```bash
grep -qE '^\s*kms_reveal_by_name\s*\(\)\s*\{' "$ENVRC_PATH" \
  || { echo "❌ $ENVRC_PATH 에 kms_reveal_by_name 함수가 없습니다 — 새로 만들지 않으므로 전환을 중단합니다."; exit 2; }
```

함수가 없으면 여기서 즉시 중단한다. 정의 안 된 함수를 호출하는 줄을 만들면 그 개발자의 `.envrc`가 깨진다.

### 1. 이름별 판정

각 `--items`의 `NAME`에 대해 (순서대로):

1. `NAME`이 `KMS_TOKEN`이면 항상 제외한다 — 그 값을 reveal로 바꾸면 부트스트랩이 순환 참조에 빠진다.
2. `.envrc`에서 `export NAME=...` 줄을 찾는다(선행 공백 허용 — `if` 블록 안에 들여써 있는 경우가 실제로 있다):
   ```bash
   grep -nE "^[[:space:]]*export[[:space:]]+${NAME}=" "$ENVRC_PATH"
   ```
   못 찾으면 스킵("export 줄 없음"). 매치된 줄의 선행 공백(들여쓰기)을 그대로 기억해 뒀다가 치환 시 유지한다 — 안 그러면 `if`/함수 블록의 셸 문법이 깨질 수 있다.
3. **이미 KMS에서 오는 값인지 판정한다 — export 줄만 보지 말 것.** 파일 전체에 그 이름에 대한 `kms_reveal_by_name` 호출이 있으면 "이미 전환됨"으로 스킵한다(멱등, 재실행 안전):
   ```bash
   grep -qE "kms_reveal_by_name[[:space:]]+${NAME}([[:space:]]|$)" "$ENVRC_PATH" && echo ALREADY
   ```
   export 줄의 문자열만 검사하면 **병렬 reveal 패턴을 놓친다**(실측 사례):
   ```bash
   kms_reveal_by_name GITEA_TOKEN aiops-codex local > "$_KMS_TMP/GITEA_TOKEN" &   # 백그라운드 동시 실행
   wait
   export GITEA_TOKEN="$(cat "$_KMS_TMP/GITEA_TOKEN")"                            # export 줄엔 호출이 없다
   ```
   이 형태는 export 줄에 `kms_reveal_by_name`이 없지만 값은 이미 KMS에서 온다. 이걸 '미전환'으로 오판해 직렬 호출로 되돌리면 KMS 왕복이 항목 수만큼 직렬로 늘어 `direnv` 로딩이 느려진다 — 기능은 같지만 명백한 퇴보이므로 **절대 건드리지 않는다.**
4. KMS에 `name=${NAME}` + `service=${SERVICE}` + `environment=${ENV}`가 **`has_value=true`로 이미 존재**하는지 §2와 동일한 방식으로 재확인한다. 없으면 "먼저 §2~§4로 등록 후 재시도"를 안내하고 스킵한다 — 값이 없는데 reveal로 바꾸면 그 개발자의 `.envrc`가 빈 값을 반환하게 된다.
5. 통과한 항목만 치환 후보에 넣는다(원래 들여쓰기 유지): `<들여쓰기>export ${NAME}="$(kms_reveal_by_name ${NAME} ${SERVICE} ${ENV})"`

### 2. 미리보기 → 확인 → 적용

- **`--confirm` 없이 호출된 경우**: 치환될 줄만 (값 없이, `이름` 단위로) 보여주고 아무것도 쓰지 않는다. 이 상태로 사용자에게 진행 여부를 확인한다(AskUserQuestion 또는 자연어 확인).
- **사용자가 승인하고 `--confirm`으로 재호출한 경우**에만 실제로 파일을 바꾼다:
  1. 원본을 백업한다: `cp "$ENVRC_PATH" "${ENVRC_PATH}.bak"`
  2. 치환 대상 줄만 정확히 바꾼다 (Edit 도구로 `export NAME=...` 한 줄을 `export NAME="$(kms_reveal_by_name NAME SERVICE ENV)"`로 교체 — 값이 어떤 도구 출력에도 노출되지 않도록 grep/sed 결과에 값이 포함되지 않는 방식으로 처리한다. 다른 줄(주석·함수 정의·다른 변수)은 절대 건드리지 않는다).
  3. 변환 건수와 백업 경로만 보고한다.

### 3. 결과 보고

```
## 🔐 .envrc → kms_reveal_by_name 전환 결과
- 대상: N건 요청 / M건 전환 / K건 스킵(사유별 집계)
- 백업: <ENVRC_PATH>.bak
- 스킵 사유: EMPTY_IN_KMS(아직 KMS 미등록) X건 / ALREADY_CONVERTED(직접 호출·병렬 reveal 모두 포함) Y건 / NOT_FOUND Z건
```

값은 어떤 경우에도 보고에 포함하지 않는다.

---

## 참고

- 단건 조회/검색/등록은 `/aiops:kms`를 그대로 쓴다. 본 스킬은 `.envrc` 일괄 이관에 특화된 스캔·비교·확인 레이어일 뿐, KMS API 계약은 `/aiops:kms`와 동일하다.
- `secrets/{id}` PATCH의 app-token 경로(`allow_update`, 식별 필드 불변)는 KMS 서버 OpenAPI(`updateSecret`, issue #46)에 정의된 계약이다 — 서버 쪽 스키마가 바뀌면 본 절도 함께 갱신해야 한다.
- §6의 `kms_reveal_by_name` 호출 형태(`export NAME="$(kms_reveal_by_name NAME service environment)"`)는 이 레포 `.envrc`가 이미 쓰고 있는 부트스트랩 패턴을 그대로 따른 것이다 — 그 함수의 시그니처가 바뀌면 본 절도 함께 갱신해야 한다.
