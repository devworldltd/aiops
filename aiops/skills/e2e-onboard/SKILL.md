---
name: e2e-onboard
description: "레포를 e2e-runner 서비스에 등록하는 온보딩 스킬. config.yaml repos 스니펫 + .env 키 목록 + 웹훅(Gitea/GitHub) 안내를 한 번에 생성한다. /aiops:setup 이 감지한 e2e_dev_url/e2e_prod_url 을 재사용해 프로젝트 config ↔ 러너 .env URL 불일치를 차단. --apply 로 러너 원격 반영(백업 후 멱등 append) 옵션."
---

# /aiops:e2e-onboard — e2e-runner 레포 등록 온보딩

`e2e-runner` 서비스(대상 레포와 **별도 Linux 호스트**)에 한 레포를 붙이는 데 필요한 등록 산출물을 **한 번에** 생성한다.

E2E 실행 경로 (b) 러너 서비스 경로에는 러너 호스트 측 등록(레포 화이트리스트 / 테스트계정·URL `.env` / 웹훅+App 설치)이 필요한데, 이 작업은 레포 안 산출물로 해결되지 않아 `/aiops:devflow`·`/aiops:setup` 어디에도 없다. 본 스킬이 그 갭을 메운다.

**기본 산출물은 복사·붙여넣기 가능한 스니펫 + 체크리스트**이며, 러너 접근(SSH/권한)이 가능할 때만 `--apply` 로 원격 반영한다.

## 산출물 (4종)

1. `config.yaml` 의 `repos:` 항목 YAML 스니펫
2. 러너 `.env` 에 필요한 키 목록 (값은 자리표시자 — **시크릿 평문 금지**)
3. 웹훅 URL + 공유 시크릿 키명 + 러너 인증(Gitea 액세스 토큰 / GitHub App) 안내
4. 온보딩 체크리스트 (✅ 자동 반영 / ⬜ 수동 필요)

## 핵심 원칙

- **NFR-3 보안**: 시크릿 **값**을 이슈 코멘트/파일에 평문 노출하지 않는다. `.env` 키 **이름**과 자리표시자만 출력, 실제 값은 러너 `.env` 에서 관리.
- **NFR-4 안전한 원격 반영**: `--apply` 는 대상 파일 **백업 선행 + 멱등 append** 만. 파괴적 덮어쓰기 금지. 권한 부족 시 즉시 스니펫-only 폴백.
- **NFR-5 스키마 정합**: 생성 스니펫은 `e2e-runner/config.yaml.example`·`.env.example` 스키마와 필드명이 **정확히 일치**.
- **NFR-2 문서 규약**: 자기완결형(self-contained), forge(이슈) first → context 폴백.

---

## §1 인자 파싱 + 대상 레포 파악

호출: `/aiops:e2e-onboard <owner/repo> [옵션]`

| 인자/플래그 | 기본값 | 효과 |
|-------------|--------|------|
| `<owner/repo>` | (git remote 유추) | 등록할 레포. 생략 시 `git remote get-url origin` 에서 `owner/repo` 파싱 |
| `--profile=<name>` | `default` | repos 항목 `profile` |
| `--branch-filter=<a,b>` | `dev,main` | repos 항목 `branch_filter` |
| `--env-default=<env>` | `dev` | repos 항목 `env_default` (local\|dev\|prod) |
| `--mode-default=<mode>` | `full` | repos 항목 `mode_default` (full\|smoke) |
| `--runner-host=<host>` | config `e2e_runner_host` → 자리표시자 `<runner-host>` | 웹훅 URL·헬스핑 대상 |
| `--apply` | false | 러너 원격 반영 (SSH/권한 전제, S1) |
| `--issue=<N>` | (자동 감지) | 체크리스트를 등록할 이슈 번호 |
| `--dry-run` | false | 스니펫만 stdout 출력, 파일/원격 반영 0건 |

```bash
REPO_ARG=""; PROFILE="default"; BRANCH_FILTER="dev,main"
ENV_DEFAULT="dev"; MODE_DEFAULT="full"; RUNNER_HOST=""
APPLY=false; ISSUE_OVERRIDE=""; DRY_RUN=false

for arg in $ARGUMENTS; do
  case "$arg" in
    --profile=*)       PROFILE="${arg#--profile=}" ;;
    --branch-filter=*) BRANCH_FILTER="${arg#--branch-filter=}" ;;
    --env-default=*)   ENV_DEFAULT="${arg#--env-default=}" ;;
    --mode-default=*)  MODE_DEFAULT="${arg#--mode-default=}" ;;
    --runner-host=*)   RUNNER_HOST="${arg#--runner-host=}" ;;
    --apply)           APPLY=true ;;
    --issue=*)         ISSUE_OVERRIDE="${arg#--issue=}" ;;
    --dry-run)         DRY_RUN=true ;;
    --*)               echo "[e2e-onboard] WARN: 알 수 없는 플래그: $arg" ;;
    */*)               REPO_ARG="$arg" ;;
    *)                 echo "[e2e-onboard] WARN: 알 수 없는 인자: $arg" ;;
  esac
done

# owner/repo 유추 — forge.sh 가 origin 리모트로 GitHub/Gitea 자동감지
if [[ -z "$REPO_ARG" ]]; then
  REPO_ARG=$(forge.sh repo 2>/dev/null)   # -> owner/repo
fi

if [[ ! "$REPO_ARG" =~ ^[^/]+/[^/]+$ ]]; then
  echo "[e2e-onboard] ERROR: owner/repo 를 확정할 수 없습니다. '/aiops:e2e-onboard owner/repo' 형태로 재시도하세요."
  exit 1
fi
OWNER="${REPO_ARG%%/*}"
echo "[e2e-onboard] §1 대상 레포: $REPO_ARG (owner=$OWNER)"
```

---

## §2 프로젝트 config 감지값 로드 (M4 — single source 재사용)

`/aiops:setup` 이 이미 감지한 값을 **입력으로 재사용**하여 프로젝트 config ↔ 러너 `.env` URL 불일치(drift)를 원천 차단한다.

`.claude/config.json` 에서 다음을 읽는다 (`jq` 우선, 미설치 시 grep 라인 파싱):

- `e2e_dev_url`, `e2e_prod_url`, `e2e_local_url` — 러너 `.env` 의 `E2E_DEV_URL` / `E2E_PROD_URL` / `E2E_LOCAL_URL` 로 주입
- `cf_dev_url`, `cf_prod_url` — `${cf_dev_url}` 변수 참조 해석용
- `e2e_runner_host` (있으면) — 웹훅 URL 호스트
- test user/pass 필드가 있으면 그것 (없으면 자리표시자)

```bash
CONFIG_FILE=".claude/config.json"
E2E_DEV_URL=""; E2E_PROD_URL=""; E2E_LOCAL_URL=""; CONFIG_RUNNER_HOST=""
if [[ -f "$CONFIG_FILE" ]]; then
  if command -v jq >/dev/null 2>&1; then
    E2E_DEV_URL=$(jq -r '.e2e_dev_url // ""' "$CONFIG_FILE")
    E2E_PROD_URL=$(jq -r '.e2e_prod_url // ""' "$CONFIG_FILE")
    E2E_LOCAL_URL=$(jq -r '.e2e_local_url // ""' "$CONFIG_FILE")
    CF_DEV=$(jq -r '.cf_dev_url // ""' "$CONFIG_FILE")
    CF_PROD=$(jq -r '.cf_prod_url // ""' "$CONFIG_FILE")
    CONFIG_RUNNER_HOST=$(jq -r '.e2e_runner_host // ""' "$CONFIG_FILE")
    # ${cf_dev_url} / ${cf_prod_url} 변수 참조 해석
    [[ "$E2E_DEV_URL"  == '${cf_dev_url}'  ]] && E2E_DEV_URL="$CF_DEV"
    [[ "$E2E_PROD_URL" == '${cf_prod_url}' ]] && E2E_PROD_URL="$CF_PROD"
  else
    E2E_DEV_URL=$(grep -o '"e2e_dev_url"[^,]*' "$CONFIG_FILE" | sed -E 's/.*:\s*"?([^"]*)"?/\1/')
    E2E_PROD_URL=$(grep -o '"e2e_prod_url"[^,]*' "$CONFIG_FILE" | sed -E 's/.*:\s*"?([^"]*)"?/\1/')
  fi
else
  echo "[e2e-onboard] WARN: .claude/config.json 없음 — 먼저 /aiops:setup 실행을 권장합니다. URL 자리표시자를 유지합니다."
fi

# 러너 호스트 우선순위: 인자 > config > 자리표시자
[[ -z "$RUNNER_HOST" ]] && RUNNER_HOST="$CONFIG_RUNNER_HOST"
[[ -z "$RUNNER_HOST" ]] && RUNNER_HOST="<runner-host>"

# 감지값 없으면 자리표시자 + 경고
DEV_VAL="${E2E_DEV_URL:-<dev-base-url>}"
PROD_VAL="${E2E_PROD_URL:-<prod-base-url>}"
[[ "$DEV_VAL"  == "<dev-base-url>"  ]] && echo "[e2e-onboard] WARN: e2e_dev_url 미감지 — 자리표시자 유지. /aiops:setup 실행 권장."
[[ "$PROD_VAL" == "<prod-base-url>" ]] && echo "[e2e-onboard] WARN: e2e_prod_url 미감지 — 자리표시자 유지. /aiops:setup 실행 권장."
```

---

## §3 repos: 스니펫 생성 (M2)

`config.yaml.example` 스키마와 정확히 일치하는 `repos:` 항목을 생성한다 (필드 5개: `name` / `profile` / `branch_filter` / `env_default` / `mode_default`).

```yaml
# --- e2e-runner config.yaml 의 repos: 아래에 append ---
  - name: <owner/repo>
    profile: default
    branch_filter: [dev, main]
    env_default: dev
    mode_default: full
```

값은 §1 플래그(`--profile` 등)와 §2 감지값으로 오버라이드한다. `branch_filter` 는 `[a, b]` YAML 리스트 형태로 렌더링한다.

---

## §4 .env 키 목록 생성 (M3 — 값 자리표시자, 시크릿 금지)

러너 `.env` 에 필요한 키를 **용도 주석과 함께** 출력한다. `.env.example` 스키마와 필드명 일치. **실제 값은 절대 출력하지 않는다** — URL 은 `/aiops:setup` 감지값(공개 URL)까지만 주입하고, 계정/토큰류는 자리표시자.

```bash
# --- e2e-runner .env 에 누락 키만 append (값은 러너에서 관리) ---
E2E_DEV_URL=<dev-base-url>       # dev 환경 baseURL — /aiops:setup 의 e2e_dev_url 재사용
E2E_PROD_URL=<prod-base-url>     # prod 환경 baseURL — /aiops:setup 의 e2e_prod_url 재사용
# E2E_LOCAL_URL=http://localhost:8787   # (선택) local 환경 baseURL
E2E_TEST_USER=<test-account-email>       # 로그인 테스트 계정 ID (시크릿 — 러너에서만 관리)
E2E_TEST_PASS=<test-account-password>    # 로그인 테스트 계정 PW (시크릿 — 러너에서만 관리)
# secrets.extra_env 매핑 시 추가 키 (예):
# E2E_CUSTOM_API_KEY=<custom-api-key>    # config.yaml secrets.extra_env.CUSTOM_API_KEY 대응
```

- `E2E_DEV_URL` / `E2E_PROD_URL` 은 §2 에서 감지한 공개 URL(`$DEV_VAL` / `$PROD_VAL`)로 렌더링한다. 감지 실패 시 자리표시자 유지.
- `E2E_TEST_USER` / `E2E_TEST_PASS` 및 `extra_env` 키는 **자리표시자만** — 러너 관리자가 값 입력.
- `config.yaml` 의 `secrets.extra_env` 에 매핑된 추가 키가 있으면 그 이름을 `E2E_<NAME>` 형태로 병기.

---

## §5 웹훅 / 러너 인증 안내 (M5)

**Gitea (기본 — origin 이 Gitea 일 때):**

```
■ Gitea 웹훅 설정 (레포 Settings → Webhooks → Add Webhook → Gitea)
  - Target URL   : https://<runner-host>/webhook/gitea   (러너가 GitHub 호환 엔드포인트만 노출하면 /webhook/github 유지 — 러너 설정에 따름)
  - HTTP Method  : POST
  - Content Type : application/json
  - Secret       : WEBHOOK_SECRET  (값은 러너 .env 에서 관리 — 여기 노출 금지)
  - Trigger On   : Custom Events → Pull Request (opened, synchronized)

■ 러너 인증 (Gitea 액세스 토큰)
  - Gitea 는 GitHub App/installation 개념이 없다. 러너가 레포 API(체크아웃/상태 보고)를
    호출하려면 Gitea 액세스 토큰을 러너 .env 에 둔다 (키명만): GITEA_TOKEN
  - 토큰 단위 인증이므로 owner→installation 매핑(installation_map)은 불필요.
```

**GitHub (origin 이 GitHub 일 때 — 역호환):**

```
■ GitHub 웹훅 설정 (레포 Settings → Webhooks → Add webhook)
  - Payload URL : https://<runner-host>/webhook/github
  - Content type: application/json
  - Secret      : WEBHOOK_SECRET  (값은 러너 .env 에서 관리 — 여기 노출 금지)
  - Events      : Pull requests (opened, synchronize)

■ GitHub App 설치 (기존 App 에 레포 추가)
  - 대상 org 의 App 설치 페이지에서 <owner/repo> 를 Repository access 에 추가
  - config.yaml 의 github_app.installation_map 에 owner 매핑 추가:
        installation_map:
          <owner>: "<installation_id>"
  - (App 생성 자체는 범위 밖 — 기존 App 에 레포 추가/설치까지만)
```

- `<runner-host>` 는 §1/§2 로 확보한 `$RUNNER_HOST` 로 렌더링. forge 종류는 `forge.sh kind`(github|gitea)로 판별해 해당 블록만 안내한다.
- `WEBHOOK_SECRET`(및 GitHub 경로의 `GITEA_TOKEN`/App 자격증명)은 **키명만** 안내 (NFR-3). 실제 러너 `.env` 키명은 러너 스키마(`.env.example`)를 따른다.
- Gitea 는 `installation_map` 불필요. GitHub 경로에서만 `installation_map` 에 owner 가 이미 있으면 "이미 매핑됨" 표시, 없으면 append 안내 (C1 멀티 org).

---

## §6 precheck — 형제 이슈 갭 점검 (S3)

대상 레포에 E2E 가 green 이려면 필요한 항목의 존재 여부를 점검한다. **미충족이어도 온보딩은 진행**하되 경고한다.

| 점검 항목 | 방법 | 미충족 시 안내 |
|-----------|------|----------------|
| `package.json` + `@playwright/test` | 파일/의존성 존재 | #211 필요 |
| `playwright.config.ts` | 파일 존재 | #211 필요 |
| `@smoke` 태그 | `grep -r '@smoke' tests/e2e` | prod smoke 게이트용 — #212 필요 |
| 로그인 경로 / 계정 시드 | tech-spec 인증절 / 시드 스크립트 | #212·#213 필요 |
| `/health` `deployed_sha` | 헬스체크 응답 필드 | #213 필요 |

```bash
echo "[e2e-onboard] §6 precheck"
[[ -f package.json ]] && grep -q '@playwright/test' package.json \
  && echo "  ✅ package.json + @playwright/test" \
  || echo "  ⬜ package.json/@playwright/test 미충족 — #211 필요"
[[ -f playwright.config.ts ]] && echo "  ✅ playwright.config.ts" || echo "  ⬜ playwright.config.ts 없음 — #211 필요"
grep -rq '@smoke' tests/e2e 2>/dev/null && echo "  ✅ @smoke 태그" || echo "  ⬜ @smoke 태그 없음 — #212 필요"
```

로컬에서 확인 불가한 항목(원격 `/health` 등)은 "수동 확인 필요"로 체크리스트에 남긴다.

---

## §7 `--apply` — 러너 원격 반영 (S1/S2, 옵션)

`--apply` 가 있고 러너 SSH/권한이 확보될 때만 실행. **없거나 권한 부족이면 자동으로 스니펫-only 폴백** (NFR-4).

멱등 처리 절차:

1. **백업 선행**: `cp /etc/e2e-runner/config.yaml{,.bak.$(date +%s)}` · `.env` 동일.
2. **멱등 검사 (S2)**: `config.yaml` 의 `repos:` 에 `name: <owner/repo>` 가 이미 있으면 **중복 추가 금지** — 기존 항목과의 차이(diff)만 안내.
3. **append 만**: 신규면 `repos:` 에 §3 스니펫 append, `.env` 는 **누락 키만** append (기존 값 덮어쓰기 금지).
4. **재시작 안내/실행**: `systemctl restart e2e-runner-api e2e-runner-worker`.
5. `installation_map` 에 owner 없으면 append (있으면 스킵).

```bash
if $APPLY && ! $DRY_RUN; then
  echo "[e2e-onboard] §7 --apply: 백업 → 멱등 검사 → append → 재시작 (권한 없으면 스니펫-only 폴백)"
  # 러너는 별도 호스트(root 전제) — SSH 컨텍스트에서 위 1~5 절차 수행.
  # 권한/접근 실패 시: echo "권한 없음 — 스니펫-only 폴백" 후 §3~§5 산출물만 제공.
else
  echo "[e2e-onboard] §7 스니펫-only 모드 — 위 산출물을 러너 관리자에게 전달하세요."
fi
```

> 러너는 대상 레포와 **별도 Linux 호스트**(root 권한 전제)에 있다. `--apply` 는 SSH 컨텍스트가 있을 때만 의미가 있으며, 없으면 기본(스니펫+체크리스트)으로 동작한다.

---

## §8 체크리스트 산출 + 저장 (M6)

온보딩 항목별 상태를 마크다운 체크리스트로 최종 출력한다. **forge(이슈 코멘트) first → context 폴백** 규약.

```markdown
## 🧪 E2E Onboard — <owner/repo>

### repos: 스니펫 (config.yaml)
```yaml
  - name: <owner/repo>
    profile: default
    branch_filter: [dev, main]
    env_default: dev
    mode_default: full
```

### .env 키 (값은 러너에서 관리 — 자리표시자만)
- `E2E_DEV_URL` = <dev-base-url>   # /aiops:setup 재사용
- `E2E_PROD_URL` = <prod-base-url> # /aiops:setup 재사용
- `E2E_TEST_USER` / `E2E_TEST_PASS` = ⬜ 러너에서 입력
- (extra_env 매핑 시) `E2E_<NAME>` = ⬜

### 웹훅 / 러너 인증
- 웹훅 URL: `https://<runner-host>/webhook/<gitea|github>` · content-type `application/json` · events `pull_request(opened,synchronize)`
- Secret 키명: `WEBHOOK_SECRET` (값 비노출)
- Gitea: `GITEA_TOKEN` (러너 .env, 키명만) / GitHub: `installation_map.<owner>` 매핑

### 온보딩 체크리스트
- [ ] config.yaml `repos:` 에 항목 추가 (✅ --apply 반영 / ⬜ 수동)
- [ ] `.env` 키 입력 (URL 자동 / 계정·시크릿 ⬜ 수동)
- [ ] 웹훅 등록 (⬜ 수동)
- [ ] 러너 인증: Gitea 액세스 토큰 또는 GitHub App 레포 설치+installation_map (⬜ 수동)
- [ ] precheck: package.json/playwright.config/@smoke/health (§6 결과)
- [ ] 러너 재시작 (✅ --apply / ⬜ 수동)
```

저장 절차:

```bash
if [[ -n "$ISSUE_OVERRIDE" ]]; then
  # forge-first: 이슈 코멘트 등록 (forge.sh 가 GitHub/Gitea 인증·자동감지 처리)
  forge.sh issue-comment "$ISSUE_OVERRIDE" "@checklist.md" 2>/dev/null \
    || echo "[e2e-onboard] forge 등록 실패 — context 폴백"
fi
# 폴백: context/issue-<N>/ 또는 표준 출력
```

forge 불가 시 `context/issue-<N>/` 폴백 파일에 저장하고 `상태: SYNC_PENDING` 메타 부여.

---

## §9 현재 제공된 인자

$ARGUMENTS

위 절차 (§1 → §2 → §3 → §4 → §5 → §6 → §7 → §8) 순서로 진행해줘. 시크릿 값은 절대 출력하지 말고 키명·자리표시자만 노출한다.
