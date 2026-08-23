---
name: kms
description: "DevWorld KMS 연동 — Token·API Key·Password·SSH Key 등 모든 credential을 소스/파일에 저장하지 않고 KMS API로 검색·조회(reveal)·등록한다. 앱 전용 KMS_TOKEN 인증, 환경(local/dev/stg/test/prod) 일치 강제, 값 비노출 원칙. 사용법: /aiops:kms search <key-name> | /aiops:kms get <key-name> | /aiops:kms register <name> | /aiops:kms health"
---

# /aiops:kms — DevWorld KMS Secret 관리

외부 앱·서비스 개발에 필요한 credential(Token, API Key, Password, SSH Key 등)을 **DevWorld KMS**에서 관리한다. 값을 소스 코드·`.env`·Git·로그에 저장하는 대신, 필요한 시점에 KMS API로 조회해 **프로세스 환경변수/메모리에서만** 사용한다.

## 접속 정보

| 항목 | 값 |
|------|----|
| KMS URL | `.claude/config.json` `kms_url` → 없으면 `https://kms.devworld.co.kr` |
| 인증 | 앱 전용 `KMS_TOKEN` 환경변수 (Bearer) |
| CF Access | `CF_ACCESS_CLIENT_ID`/`CF_ACCESS_CLIENT_SECRET` 환경변수를 서비스 토큰 헤더로 동반 |
| 환경 | `local` \| `dev` \| `stg` \| `test` \| `prod` 중 하나 |

```bash
KMS_URL="${KMS_URL:-$(jq -r '.kms_url // "https://kms.devworld.co.kr"' .claude/config.json 2>/dev/null || echo "https://kms.devworld.co.kr")}"

if [ -z "$KMS_TOKEN" ]; then
  echo "❌ KMS_TOKEN 환경변수가 없습니다. KMS Apps 상세 화면에서 앱 토큰을 발급받아 셸 환경에 설정하세요."
  exit 2
fi

KMS_H=(-H "Authorization: Bearer $KMS_TOKEN" -H "Accept: application/json" -H "Content-Type: application/json")
if [ -n "$CF_ACCESS_CLIENT_ID" ] && [ -n "$CF_ACCESS_CLIENT_SECRET" ]; then
  KMS_H+=(-H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET")
fi
```

> **주의**: `KMS_TOKEN`은 **앱 전용 토큰**이다. 사용자 세션 token과 혼동하지 않는다. 토큰 재발행은 KMS Apps 상세 화면에서만 수행한다. `kms.devworld.co.kr`는 Cloudflare Access 뒤에 있으므로 서비스 토큰(`CF_ACCESS_CLIENT_ID`/`CF_ACCESS_CLIENT_SECRET`)이 필요하다 — 로컬 macOS 키체인의 `MBP_KMS_KEY` 항목(JSON: `client_id`/`client_secret`)에서 `~/.kms/cf-access-env.sh`로 로드된다 (구 IP 직결 방식 대체).

## 절대 원칙 (모든 서브커맨드 공통)

1. Secret **값**과 `KMS_TOKEN`을 소스 코드, `.env` 파일, Git, 로그, 터미널 출력, PR, Issue, 채팅, 작업 보고 어디에도 기록하지 않는다.
2. 조회한 값은 프로세스 환경변수나 메모리에서만 사용한다 (예: `export MY_KEY=$(... reveal ...)` 를 사용자에게 안내하되, 값 자체를 echo 하지 않는다).
3. 개발·배포 대상 환경과 **일치하는 environment**의 Secret만 사용한다.
4. Secret을 임의로 교체(update)·삭제하지 않는다. 본 스킬은 **검색·조회·신규 등록**만 다룬다.
5. 작업 결과 보고에는 **KMS 상태, Secret name, service, environment, Secret ID, 사용 환경변수 이름**만 포함한다.

---

## §0 인자 파싱

호출: `/aiops:kms <subcommand> [인자] [옵션]`

| 서브커맨드 | 동작 |
|-----------|------|
| `health` | KMS API 상태 확인만 수행 |
| `search <key-name>` | Secret 검색 (값 없이 메타데이터만) |
| `get <key-name>` | 검색 → 정확 일치 확인 → reveal → 환경변수 사용 안내 |
| `register <name>` | 신규 Secret 등록 (사용자 값 제공 + 승인 필수) |

| 옵션 | 기본값 | 효과 |
|------|--------|------|
| `--env=<environment>` | (필수에 준함 — 생략 시 사용자에게 확인) | `local\|dev\|stg\|test\|prod` |
| `--service=<name>` | (없음) | 검색/등록 시 service 필터·지정 |

`--env` 값이 5개 환경 밖이면 즉시 중단하고 올바른 값을 안내한다.

---

## §1 health — KMS 상태 확인

**모든 서브커맨드는 이 단계를 선행한다.**

```bash
if ! curl -sf --max-time 5 "${KMS_H[@]}" "$KMS_URL/api/v1/health" >/dev/null; then
  echo "❌ KMS 응답 없음: $KMS_URL — 네트워크/서비스 상태를 확인하세요."
  exit 2
fi
echo "✅ KMS OK: $KMS_URL"
```

- 401/403 응답이면 `KMS_TOKEN`이 유효하지 않거나 이 앱에 권한이 없는 것 — 토큰 재발행(KMS Apps 상세 화면)을 안내하고 중단한다.
- `KMS_TOKEN`은 등록된 앱에 연결된 Secret만 접근할 수 있다. 검색 결과가 비어 있으면 "앱에 해당 Secret이 연결되지 않았을 수 있음"을 함께 안내한다.

## §2 search — Secret 검색

```bash
curl -sf "${KMS_H[@]}" "$KMS_URL/api/v1/secrets?q=<key-name>&environment=<environment>"
```

- 응답은 배열이 아니라 **`{"items": [...]}` 래퍼**다 — 바로 순회하면 터진다.
- 응답의 `name`, `service`, `environment`를 표로 정리해 보여준다. 목록·상세 응답에는 실제 값이 없고 `has_value`만 포함된다.
- `q` 없이 `environment` 만으로도 조회된다(그 환경 전체 목록) — 이관 전 중복 검사에 쓴다.
- `--service` 지정 시 응답에서 service 일치 항목만 남긴다.
- 결과 표 예시 (값 컬럼 없음):

| ID | name | service | environment | has_value |
|----|------|---------|-------------|-----------|

## §3 get — 값 조회 (reveal)

1. §2 검색을 수행한다.
2. **`name`, `service`, `environment`가 요청과 정확히 일치**하는 Secret만 후보로 남긴다. 후보가 0개면 중단(§2 안내), 2개 이상이면 사용자에게 어느 것인지 확인한다.
3. 후보의 `has_value`가 `true`인지 확인한다. `false`면 reveal 하지 않고 "값 미등록" 상태를 보고한다.
4. `has_value=true`인 **정확한 Secret ID**를 확인한 뒤에만 reveal 한다:

```bash
# 값을 화면에 출력하지 않고 곧바로 환경변수로 주입하는 형태로만 사용
export <ENV_VAR_NAME>="$(curl -sf -X POST "${KMS_H[@]}" "$KMS_URL/api/v1/secrets/<id>/reveal" | jq -r '.value')"
```

5. 값이 필요한 후속 명령(예: 배포, API 호출)은 위 환경변수를 참조하게 하고, **값 자체를 echo/로그/파일로 내보내지 않는다.** 사용자에게는 "환경변수 `<ENV_VAR_NAME>`에 주입됨"만 보고한다.

## §4 register — 신규 Secret 등록

전제 조건 두 가지가 **모두** 충족될 때만 진행한다:

1. **사용자가 실제 값을 직접 제공**했다 (스킬이 값을 생성·추측하지 않는다).
2. **사용자가 등록을 명시적으로 승인**했다.

절차:

1. 중복 검사: §2와 동일하게 `q=<name>&environment=<environment>`로 검색하고, **같은 `name` + `service` + `environment`** 조합이 이미 있으면 등록하지 않고 사용자에게 확인한다 (중복 등록 금지).
2. 등록 요청. **필수 필드는 5개**다 — `name` · `service` · `secret_type` · `value` · `status`.
   `environment` 는 스키마상 기본값이 `local` 이라 **생략하면 조용히 local 로 들어간다** → 항상 명시한다.

   ⚠️ **`secret_type` 과 `status` 를 빠뜨리면 400 이다.** 이 문서의 첫 판이 그 둘을 빼고 있었고,
     그대로 따르면 등록이 **전건 실패**한다(2026-08-14 실측 — 71건 이관 직전에 발견).
     정본은 KMS 레포의 `openapi/openapi.yaml` `SecretRequest` 스키마다.

```bash
curl -sf -X POST "${KMS_H[@]}" "$KMS_URL/api/v1/secrets" -d @- <<'JSON'
{
  "name": "<name>",
  "service": "<service>",
  "environment": "<local|dev|stg|test|prod>",
  "secret_type": "<token|api_key|password|ssh_key|certificate|other>",
  "status": "active",
  "description": "<선택 — 어디서 왔고 무엇에 쓰는지>",
  "value": "<사용자가 제공한 값 — 명령 이력에 남지 않도록 heredoc/파이프 사용>"
}
JSON
```

   `secret_type` 분류 기준(모호하면 `other` — 틀린 분류보다 낫다):

   | 값 | 쓰는 경우 |
   |---|---|
   | `token` | 이름에 TOKEN — API 액세스 토큰·서비스 토큰 |
   | `api_key` | API 키·클라이언트 시크릿(`*_API_KEY`·`*_CLIENT_SECRET`·`*_SECRET_KEY`) |
   | `password` | 사람이 입력하는 비밀번호 |
   | `ssh_key` · `certificate` | SSH 키 · 인증서·개인키(`*_PRIVATE_KEY`) |
   | `other` | 식별자(`*_CLIENT_ID`·`*_ACCOUNT_ID`) 등 위에 안 맞는 것 |

   ⚠️ **응답 201 의 본문에는 값이 없다**(`has_value` 만 온다). 등록 성공 확인은 `has_value: true` 로 한다.

3. 등록 후 응답의 Secret ID를 확인하고, 값이 셸 히스토리·임시 파일에 남았으면 즉시 제거한다.

## §5 결과 보고

작업 종류와 무관하게 보고 형식은 다음으로 제한한다:

```
## 🔐 KMS 작업 결과
- KMS 상태: ✅ OK (<KMS_URL>)
- Secret: <name> / service=<service> / environment=<environment>
- Secret ID: <id>
- 사용 환경변수: <ENV_VAR_NAME>
```

**실제 Secret 값·KMS_TOKEN은 어떤 경우에도 보고에 포함하지 않는다.**

---

## 다른 스킬/에이전트에서의 사용

- `dev-backend`·`dev-frontend`·`dev-devops` 등이 개발 중 credential이 필요하면 `.env`에 평문을 넣는 대신 본 스킬 절차(§1→§2→§3)로 조회한다.
- `/aiops:e2e-onboard`의 NFR-3(시크릿 평문 금지)과 동일 원칙을 공유한다 — 산출물에는 키 **이름**과 자리표시자만.
