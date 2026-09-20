---
name: setup
description: "설치 후 프로젝트 파일 분석 → tech_stack 감지 + 프레임워크/ORM/구조/배포/CI 정밀 감지 → .reviewer/profile.yaml + .claude/config.json(agent_hints) 자동 생성. /aiops:devflow 전 최초 1회 실행 권장."
---

프로젝트 루트 디렉터리를 스캔하여 tech_stack 을 감지하고, 프레임워크·ORM·구조·배포·CI 까지 정밀 분석하여 `.reviewer/profile.yaml` 과 `.claude/config.json` 의 `agent_hints` 를 자동 생성해줘.

본 스킬은 **install.sh 없이도 독립 실행**되어야 한다 (`.claude/config.json` 없으면 신규 생성).

## 실행 단계

### 1. 파일 시스템 스캔

다음 파일이 존재하는지 확인해줘 (최대 3단계 하위 디렉터리까지).
`node_modules/`, `.git/`, `dist/`, `build/` 경로는 제외한다.

| 파일 | 감지 스택 |
|------|---------|
| `package.json` | `node` |
| `requirements.txt` 또는 `pyproject.toml` | `python` |
| `go.mod` | `go` |
| `Cargo.toml` | `rust` |
| `pom.xml` 또는 `build.gradle(.kts)` | `java` |
| `Gemfile` | `ruby` |
| `composer.json` | `php` |
| `*.csproj` 또는 `*.sln` | `dotnet` |

스캔 명령 예시:
```bash
find . -maxdepth 3 -name "package.json" ! -path "*/node_modules/*" -print -quit 2>/dev/null
find . -maxdepth 3 \( -name "requirements.txt" -o -name "pyproject.toml" \) ! -path "*/node_modules/*" -print -quit 2>/dev/null
find . -maxdepth 3 -name "go.mod" -print -quit 2>/dev/null
find . -maxdepth 3 -name "Cargo.toml" -print -quit 2>/dev/null
find . -maxdepth 3 \( -name "pom.xml" -o -name "build.gradle" -o -name "build.gradle.kts" \) -print -quit 2>/dev/null
find . -maxdepth 3 -name "Gemfile" ! -path "*/node_modules/*" -print -quit 2>/dev/null
find . -maxdepth 3 -name "composer.json" ! -path "*/node_modules/*" -print -quit 2>/dev/null
find . -maxdepth 3 \( -name "*.csproj" -o -name "*.sln" \) -print -quit 2>/dev/null
```

> `build.gradle.kts` 를 포함하는 이유는 Kotlin DSL 만 쓰는 레포에서 `java` 가 누락되던 것을
> 막기 위해서다. **이 변경이 `platform` 판정을 바꾸지는 않는다** — §15-1 에서 Gradle·Maven 은
> 웹 신호가 아니기 때문이다(Android 도 Gradle 을 쓴다).

### 2. 추가 분석 (package.json 존재 시)

`package.json`의 `dependencies`/`devDependencies`를 읽어 프레임워크를 세분화해줘:

| 패키지 키 | 추가 스택 |
|----------|---------|
| `next` | `nextjs` |
| `react` | `react` |
| `hono` | `hono` |
| `express` | `express` |
| `@angular/core` | `angular` |
| `vue` | `vue` |
| `svelte` | `svelte` |

### 3. Python 추가 분석

`requirements.txt` 또는 `pyproject.toml`에서 프레임워크를 세분화해줘:

| 패키지 키 | 추가 스택 |
|----------|---------|
| `fastapi` | `fastapi` |
| `django` | `django` |
| `flask` | `flask` |

### 4. 결과 출력

감지 결과를 다음 형식으로 출력해줘:
```
[setup] 감지된 tech_stack:
  package.json    → node, hono
  requirements.txt → python, fastapi
  go.mod          → (없음)
  Cargo.toml      → (없음)

최종 tech_stack: ["node", "hono", "python", "fastapi"]
```

### 5. config.json 업데이트

`.claude/config.json`이 존재하면 `tech_stack` 필드만 감지된 배열로 업데이트해줘.
파일이 없으면 다음을 출력한다:
```
[WARN] .claude/config.json 없음 — install.sh를 먼저 실행하세요.
```

config.json 갱신은 **아래 공용 헬퍼 `_config_update` 를 반드시 경유한다**(이슈 #35).
고정 `/tmp` 경로를 직접 쓰지 말 것 — 동시 실행 교차 오염과 심볼릭 링크 공격 표면이 된다.

```bash
# >>> setup:config-update >>>
# .claude/config.json 원자적 갱신 헬퍼 — 이슈 #35 D-1~D-5 확정.
# 사용법: _config_update '<jq 필터>' [jq 추가 인자…]
#   예: _config_update '.tech_stack = $ts' --argjson ts "$TECH_STACK"
# 대상 경로: $CONFIG_PATH (기본 .claude/config.json). 임시 파일은 대상과 같은
# 디렉터리에 mktemp 무작위 이름(0600)으로 만들어 mv 가 같은 FS 내 원자적 rename 이
# 되게 한다. 실패 시 원본 바이트 불변 + 임시 파일 제거 + return 1.
_config_update() {
  local filter="$1"; shift
  local cfg="${CONFIG_PATH:-.claude/config.json}"
  local dir tmp rc

  if [[ ! -f "$cfg" ]]; then
    echo "[WARN] .claude/config.json 없음 — install.sh를 먼저 실행하세요." >&2
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "[setup] ERROR: jq 미설치 — config.json 갱신 불가." >&2
    return 1
  fi

  dir="$(dirname "$cfg")"
  tmp="$(mktemp "$dir/.config.XXXXXX" 2>/dev/null)" || {
    echo "[setup] ERROR: 임시 파일 생성 실패 ($dir) — 디스크 공간/쓰기 권한을 확인하세요." >&2
    return 1
  }

  if jq "$@" "$filter" "$cfg" > "$tmp" 2>/dev/null; then
    :
  else
    rc=$?
    rm -f "$tmp"
    echo "[setup] ERROR: config.json 갱신 실패 — jq 종료 코드 $rc. 원본은 변경되지 않았습니다." >&2
    return 1
  fi

  # jq 가 rc=0 이어도 빈 출력/비-JSON 이면 데이터 손실 방지를 위해 실패 처리한다 (T22).
  if [[ ! -s "$tmp" ]] || ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "[setup] ERROR: config.json 갱신 실패 — jq 출력이 비어있거나 유효한 JSON이 아닙니다. 원본은 변경되지 않았습니다." >&2
    return 1
  fi

  if ! mv "$tmp" "$cfg"; then
    rm -f "$tmp"
    echo "[setup] ERROR: config.json 교체 실패 ($cfg) — 원본은 변경되지 않았습니다." >&2
    return 1
  fi
  return 0
}
# <<< setup:config-update <<<
```

> 위 코드를 감싼 `setup:config-update` 시작/종료 주석 앵커는 테스트
> (`aiops/tests/setup-config-update.test.sh`, `aiops/tests/setup-prod-workflow-detect.test.sh`)
> 가 코드를 추출하는 지점이다. 앵커 문자열 자체를 바꾸지 말 것.

**jq 사용 가능 시:**
```bash
TECH_STACK='["node","hono","python","fastapi"]'
if ! _config_update '.tech_stack = $ts' --argjson ts "$TECH_STACK"; then
  echo "[setup] §5 WARN: tech_stack 기입 실패 — 위 오류를 확인하세요"
fi
```

**jq 미설치 시 Python 폴백:**
```python
import json, sys

config_path = ".claude/config.json"
tech_stack = ["node", "hono", "python", "fastapi"]  # 감지 결과로 교체

with open(config_path, "r") as f:
    config = json.load(f)

config["tech_stack"] = tech_stack

with open(config_path, "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"[setup] tech_stack 업데이트 완료: {tech_stack}")
```

### 6. 완료 메시지

```
[setup] config.json 업데이트 완료
  tech_stack: ["node", "hono", "python", "fastapi"]
  경로: .claude/config.json

다음 단계: /aiops:devflow #이슈번호 로 개발 워크플로우를 시작하세요.
```

### 7. 정밀 프레임워크 감지

각 언어 매니페스트의 의존성을 정밀 분석하여 프레임워크 단일 식별자를 결정한다.

**Node.js (`package.json` deps/devDeps):**

| 패키지 키 | framework |
|----------|-----------|
| `next` | `nextjs` |
| `hono` | `hono` |
| `fastify` | `fastify` |
| `express` | `express` |
| `koa` | `koa` |
| `@nestjs/core` | `nestjs` |
| `react` (단독) | `react` |
| `vue` | `vue` |
| `svelte` 또는 `@sveltejs/kit` | `svelte` 또는 `sveltekit` |
| `@remix-run/*` | `remix` |
| `astro` | `astro` |

**Python (`requirements.txt` / `pyproject.toml`):**

| 패키지 키 | framework |
|----------|-----------|
| `fastapi` | `fastapi` |
| `django` | `django` |
| `flask` | `flask` |
| `starlette` | `starlette` |
| `litestar` | `litestar` |

**Go (`go.mod`):** `gin-gonic/gin` → `gin`, `labstack/echo` → `echo`, `gofiber/fiber` → `fiber`

**Rust (`Cargo.toml`):** `actix-web` → `actix-web`, `axum` → `axum`, `rocket` → `rocket`

### 8. ORM/DB 감지

**Node.js:** `drizzle-orm` → `drizzle`, `@prisma/client` → `prisma`, `typeorm` → `typeorm`, `sequelize` → `sequelize`, `mongoose` → `mongoose`, `kysely` → `kysely`.

**Python:** `sqlalchemy` → `sqlalchemy`, `sqlmodel` → `sqlmodel`, `django` (자체 ORM) → `django-orm`, `tortoise-orm` → `tortoise`, `peewee` → `peewee`.

DB 종류 추론: `psycopg2`/`asyncpg`/`pg` → `postgres`, `pymysql`/`mysql2` → `mysql`, `sqlite3`/`better-sqlite3` → `sqlite`, `mongoose`/`pymongo` → `mongodb`.

### 8-1. Hono-as-backend 판별 휴리스틱 (#206)

Hono 는 Cloudflare Workers 프론트엔드로도, **백엔드 API(cf_api 패턴)** 로도 쓰인다. `hono` 의존성을 무조건 frontend 로만 분류하면 백엔드 API 프로젝트에서 `agent_hints.backend = null` 이 되어 dev-backend/aiops:qa-backend 가 FastAPI 폴백으로 오작동한다. 아래 신호를 수집하여 backend/aiops:frontend/both 를 판정한다.

**신호 수집 (파일 시스템 탐색만 — §1 스캔 재사용 + 라우트 grep 1회):**

| 신호 | 수집 방법 | 의미 |
|------|----------|------|
| `HAS_HONO` | package.json deps/devDeps 에 `hono` | Hono 사용 |
| `HAS_WRANGLER` | `wrangler.toml` 또는 `wrangler.jsonc` 존재 | Cloudflare Workers 배포 |
| `HAS_OTHER_BACKEND` | §7 backend 프레임워크(FastAPI/Django/Flask/Express/NestJS/Fastify 등) 감지됨 | 별도 전용 백엔드 존재 |
| `HAS_RENDER` | 소스에 `hono/jsx`, `.tsx` 렌더, `c.html(`, `c.render(`, `serveStatic` 등 HTML/SSR 신호 | 프론트엔드 성격 |
| `HAS_API_ROUTE` | 소스에 `/api/` 경로 라우트 + `c.json(` JSON 응답 | 백엔드 API 성격 |

```bash
HAS_HONO=false;    grep -q '"hono"' package.json 2>/dev/null && HAS_HONO=true
HAS_WRANGLER=false
find . -maxdepth 3 \( -name "wrangler.toml" -o -name "wrangler.jsonc" \) \
  ! -path "*/node_modules/*" -print -quit 2>/dev/null | grep -q . && HAS_WRANGLER=true

# §7 backend 프레임워크 감지 결과 재사용 (fastapi/django/flask/express/nestjs/fastify …)
HAS_OTHER_BACKEND=<§7 결과에 전용 백엔드가 있으면 true>

# 소스 라우트 성격 (src/ 우선, 없으면 프로젝트 루트 ts/tsx)
SRC=$(find . -maxdepth 3 -type d -name src ! -path "*/node_modules/*" -print -quit 2>/dev/null); SRC="${SRC:-.}"
HAS_RENDER=false
grep -rIlqE "hono/jsx|c\.html\(|c\.render\(|serveStatic|\.tsx" "$SRC" 2>/dev/null && HAS_RENDER=true
HAS_API_ROUTE=false
grep -rIlqE "/api/|c\.json\(" "$SRC" 2>/dev/null && HAS_API_ROUTE=true
```

**결정 규칙 (위에서부터 최초 매치):**

| # | 조건 | 결과 |
|---|------|------|
| R0 | `HAS_HONO=false` | 규칙 미적용 — 기존 §11 backend 매핑 그대로 (fastapi/django/nestjs/none) |
| R1 | `HAS_OTHER_BACKEND=true` | **backend = 그 전용 백엔드**, Hono 는 frontend 후보로만 처리 (Hono 가 backend 덮어쓰기 금지, AC-4) |
| R2 | `HAS_HONO && HAS_WRANGLER && HAS_API_ROUTE && HAS_RENDER=false` | **backend = hono-ts** (API-only), frontend 미채움 (AC-1) |
| R3 | `HAS_HONO && HAS_WRANGLER && HAS_API_ROUTE && HAS_RENDER=true` | **풀스택 Hono → both**: backend=hono-ts + frontend=hono-ts (C1) |
| R4 | `HAS_HONO && HAS_RENDER=true && HAS_API_ROUTE=false` | **frontend = hono-ts** (기존 동작, 역호환 AC-3) |
| R5 | 그 외 모호 (`HAS_HONO && HAS_WRANGLER` 이나 라우트 신호 불명확) | 기본 frontend=hono-ts 로 두되 §14 UI 에서 1회 질의 (C2) |

**충돌 해소 원칙:**
- backend 우선권은 **전용 백엔드(R1)** 에게만 있다. Hono 는 전용 백엔드가 없을 때만 backend 후보가 된다.
- Hono 의 backend/aiops:frontend 성격은 **라우트 성격(`HAS_RENDER` vs `HAS_API_ROUTE`)** 으로 가른다 — 렌더 신호=frontend, 순수 JSON API=backend, 둘 다=both.
- `wrangler` 는 배포 타깃 신호일 뿐 **backend 확정 신호가 아니다**. 프론트 Hono 도 wrangler 를 쓰므로 반드시 라우트 성격과 함께 판정한다.

### 9. 구조 감지

```bash
if [[ -f .gitmodules ]]; then
  STRUCTURE="monorepo-submodules"
elif [[ -d backend && -d frontend ]] || [[ -d packages ]] || [[ -d apps ]]; then
  STRUCTURE="monorepo"
else
  STRUCTURE="single"
fi
```

### 10. 배포/CI 감지

| 파일 | deploy_target |
|------|---------------|
| `wrangler.toml` | `cloudflare-workers` |
| `vercel.json` | `vercel` |
| `netlify.toml` | `netlify` |
| `Dockerfile` | `docker` |
| `serverless.yml` | `serverless` |
| `fly.toml` | `fly.io` |

| 디렉토리 | ci |
|---------|-----|
| `.gitea/workflows/` | `gitea-actions` |
| `.github/workflows/` | `github-actions` |
| `.gitlab-ci.yml` | `gitlab-ci` |
| `.circleci/` | `circleci` |

#### 10-1. prod 전용 배포 워크플로우 감지 (deploy_workflow_prod, 이슈 #33)

dev 배포와 prod 배포가 서로 다른 워크플로우 파일인 레포(예: `deploy-dev.yml` / `deploy-prod.yml`)를 위해,
워크플로우 디렉터리(`.gitea/workflows/` 우선, 없으면 `.github/workflows/`)의 `*.yml`·`*.yaml` 중
아래 두 조건 **중 하나**를 만족하는 파일을 prod 후보로 본다. YAML 파서는 도입하지 않고 `grep` 만 쓴다.

1. 파일명에 `prod` 포함 (대소문자 무시)
2. `branches:` 트리거가 `main` 또는 `master` **단독** (`branches: [main]`, `branches:\n  - main` 형태 모두 인식)

- 후보가 **정확히 1개**일 때만 `.claude/config.json` 에 `deploy_workflow_prod` 를 기입한다. 이미 값이 있으면 **덮어쓰지 않는다.**
- 후보가 **0개**면 키를 만들지 않는다(기존 레포 무영향).
- 후보가 **2개 이상**이면 자동 기입하지 않고 후보 목록을 출력한다(오기입 방지).
- 워크플로우 디렉터리 자체가 없으면 아무 출력 없이 조용히 스킵한다.

```bash
# >>> setup:prod-workflow-detect >>>
# prod 전용 배포 워크플로우 감지 (deploy_workflow_prod) — 이슈 #33 D-5 확정.
# YAML 파서 미도입 — grep 기반 휴리스틱. .gitea/workflows 우선, 없으면 .github/workflows.
WFDIR=""
if [[ -d ".gitea/workflows" ]]; then
  WFDIR=".gitea/workflows"
elif [[ -d ".github/workflows" ]]; then
  WFDIR=".github/workflows"
fi

if [[ -n "$WFDIR" ]]; then
  PROD_CANDIDATES=()
  while IFS= read -r -d '' _f; do
    _base=$(basename "$_f")
    _lname=$(printf '%s' "$_base" | tr '[:upper:]' '[:lower:]')
    _is_prod=0
    if [[ "$_lname" == *prod* ]]; then
      _is_prod=1
    else
      # branches: 줄 + 뒤따르는 `- 브랜치명` 목록 줄만 훑어 트리거 토큰을 추출한다 (YAML 파서 미도입).
      # 예: `branches: [main]` 한 줄 표기, 또는 `branches:\n  - main` 목록 표기 모두 인식.
      _btext=$(awk '
        /^[[:space:]]*branches:/ { print; inblock=1; next }
        inblock && /^[[:space:]]*-[[:space:]]*[A-Za-z0-9_.\/-]+[[:space:]]*$/ { print; next }
        { inblock=0 }
      ' "$_f" 2>/dev/null || true)
      if [[ -n "$_btext" ]]; then
        _tokens=$(printf '%s\n' "$_btext" \
          | grep -oE '[A-Za-z0-9_./-]+' \
          | grep -vE '^-+$' \
          | grep -vE '^(branches|on|push|pull_request)$' \
          | sort -u | tr '\n' ' ')
        _tokens="${_tokens% }"
        if [[ "$_tokens" == "main" || "$_tokens" == "master" ]]; then
          _is_prod=1
        fi
      fi
    fi
    [[ "$_is_prod" == "1" ]] && PROD_CANDIDATES+=("$_base")
  done < <(find "$WFDIR" -maxdepth 1 \( -name "*.yml" -o -name "*.yaml" \) -print0 2>/dev/null)

  PROD_COUNT=${#PROD_CANDIDATES[@]}
  if [[ "$PROD_COUNT" == "1" ]]; then
    _existing=$(jq -r '.deploy_workflow_prod // empty' .claude/config.json 2>/dev/null || echo "")
    if [[ -z "$_existing" ]]; then
      if _config_update '.deploy_workflow_prod = $v' --arg v "${PROD_CANDIDATES[0]}"; then
        echo "[setup] §10-1 prod 워크플로우 감지: ${PROD_CANDIDATES[0]} → deploy_workflow_prod 기입"
      else
        echo "[setup] §10-1 WARN: deploy_workflow_prod 기입 실패 — 위 오류를 확인하세요"
      fi
    else
      echo "[setup] §10-1 deploy_workflow_prod 기존 값 보존: $_existing (덮어쓰기 금지)"
    fi
  elif [[ "$PROD_COUNT" -ge 2 ]]; then
    echo "[setup] §10-1 WARN: prod 워크플로우 후보 다수 — 자동 기입 생략: ${PROD_CANDIDATES[*]}"
    echo "[setup] §10-1 .claude/config.json 의 deploy_workflow_prod 를 직접 지정하세요"
  fi
  # PROD_COUNT -eq 0 → 아무 것도 하지 않음(키 미생성, AC-R11)
fi
# WFDIR 이 빈 문자열(워크플로우 디렉터리 자체 부재) → 조용히 스킵 (T22)
# <<< setup:prod-workflow-detect <<<
```

> 위 코드를 감싼 `setup:prod-workflow-detect` 시작/종료 주석 앵커는 테스트(`aiops/tests/setup-prod-workflow-detect.test.sh`)가 코드를 추출하는 지점이다. 앵커 문자열 자체를 바꾸지 말 것.

### 11. 매핑 테이블 (profile.yaml stack 필드)

§7~§8 결과를 다음 단일 식별자로 매핑한다.

| backend 감지 | profile.yaml stack.backend |
|-------------|---------------------------|
| `fastapi` + `sqlalchemy` | `fastapi-sqlalchemy` |
| `fastapi` + (없음 또는 sqlite) | `fastapi-sqlite` |
| `django` | `django` |
| `nestjs` | `nestjs` |
| `hono` + Hono-as-backend 휴리스틱(§8-1 R2/R3) | `hono-ts` |
| `bin` 엔트리 + typescript 또는 javascript + 웹 프레임워크 미감지 (= §16 `platform=cli`) | `node-cli` |
| 그 외 / 미지원 | `none` |

| frontend/admin 감지 | profile.yaml stack |
|--------------------|-------------------|
| `hono` + typescript | `hono-ts` |
| `nextjs` + react | `nextjs` |
| `react` (단독) | `react` |
| `vue` | `vue` |
| `svelte` 또는 `sveltekit` | `svelte` |
| 그 외 / 미지원 | `none` |

### 12. .reviewer/profile.yaml 자동 생성

기존 파일 보호:
```bash
if [[ -f .reviewer/profile.yaml ]]; then
  read -p "[보호] 기존 .reviewer/profile.yaml 이 존재합니다. 덮어쓰시겠습니까? [y/N]: " ANS
  ANS="${ANS:-N}"
  if [[ ! "$ANS" =~ ^[yY]$ ]]; then
    echo "[스킵] profile.yaml 유지"
    SKIP_PROFILE=1
  fi
fi
```

신규 생성 포맷 (forge.sh repo 로 repo 자동 감지):
```yaml
# Reviewer 프로필 — /aiops:setup 이 자동 생성
# 스키마: claude-ai-devops/docs/review-profile-schema.md

repo: OWNER/NAME           # forge.sh repo (→ owner/repo)
forge: github | gitea      # 선택 — 생략 시 origin 리모트로 자동감지(forge.sh kind)
structure: single | monorepo | monorepo-submodules

stack:
  backend: fastapi-sqlalchemy | fastapi-sqlite | django | nestjs | none
  frontend: hono-ts | nextjs | react | vue | svelte | none
  admin: hono-ts | nextjs | none

prd_source: github-issue
max_diff_loc: 1500
```

### 13. config.json 의 agent_hints 작성

`.claude/config.json` 의 `agent_hints` 필드를 다음 스키마로 갱신:

```json
{
  "agent_hints": {
    "backend": {
      "language": "python",
      "framework": "fastapi",
      "orm": "sqlalchemy",
      "db": "postgres",
      "test_runner": "pytest"
    },
    "frontend": {
      "language": "typescript",
      "framework": "hono",
      "deploy_target": "cloudflare-workers",
      "test_runner": "vitest"
    },
    "structure": "monorepo",
    "ci": "gitea-actions"
  }
}
```

**Hono 백엔드(§8-1 R2/R3)일 때 `agent_hints.backend` 예시 (#206):**

```json
{
  "agent_hints": {
    "backend": {
      "language": "typescript",
      "framework": "hono",
      "deploy_target": "cloudflare-workers",
      "orm": "drizzle",
      "db": "sqlite",
      "test_runner": "vitest"
    },
    "frontend": null,
    "structure": "single",
    "ci": "gitea-actions"
  }
}
```

필드 채움 규칙:

| 필드 | 값 | 근거 |
|------|----|----|
| `language` | `typescript` | package.json + TS 사용 |
| `framework` | `hono` | deps 의 `hono` |
| `deploy_target` | `cloudflare-workers` | §10 `wrangler.toml`/`wrangler.jsonc` |
| `orm` | §8 감지값(`drizzle`/`prisma`/…) 또는 `none` | §8 ORM 감지 결과 |
| `db` | §8 추론값(`sqlite`(D1)/`postgres`/…) 또는 생략 | §8 DB 추론 |
| `test_runner` | `vitest`(감지 시) 또는 `none` | devDeps 의 `vitest`/`jest` |

> backend 스키마의 `deploy_target` 는 Hono 백엔드용 신규 필드다(frontend 스키마와 대칭). 기존 FastAPI 백엔드는 이 키가 없어도 dev-backend 가 조회하지 않으므로 무해하다. 풀스택(R3)이면 `frontend` 도 동일 규칙으로 채운다.
>
> **profile.yaml 동기화(S1):** `.reviewer/profile.yaml` 의 `stack.backend=hono-ts` 와 `agent_hints.backend.framework=hono` 를 동시 기록하여 dev-backend 의 1순위(agent_hints)·3순위(profile.yaml) 경로가 모두 정합하도록 한다.

`tech_stack` 필드는 §5 와 동일하게 갱신, `agent_hints` 만 추가 갱신한다.

`.claude/config.json` 이 **없으면 신규 생성** (claude-ai-devops/config.template.json 기반).

```bash
if [[ ! -f .claude/config.json ]]; then
  mkdir -p .claude
  cat > .claude/config.json << 'EOF'
{
  "use_docker": false,
  "tech_stack": [],
  "agent_hints": null
}
EOF
  echo "[신규] .claude/config.json 생성"
fi
```

jq 사용 예:
```bash
if ! _config_update '.agent_hints = $hints' --argjson hints "$AGENT_HINTS_JSON"; then
  echo "[setup] §13 WARN: agent_hints 기입 실패 — 위 오류를 확인하세요"
fi
```

### 14. 사용자 확인 UI

감지가 끝나면 다음 형식으로 결과를 보여주고 [Y/n] 확인을 받는다 (기본 Y).
`platform=mobile | both` 인 경우 모바일 정보(언어/프레임워크/빌드 시스템/E2E 러너)를 추가 표시한다.

```
=== /aiops:setup 감지 결과 ===
플랫폼:     web + mobile (both)
언어:       typescript (frontend), kotlin (android), swift (ios)
프레임워크: hono (frontend), android-native + ios-native (mobile)
ORM:        none
구조:       monorepo
테스트:     vitest, junit (android), xctest (ios)
모바일 E2E: maestro
배포:       cloudflare-workers, play-store + app-store
CI:         gitea-actions

생성될 파일:
  .reviewer/profile.yaml (platform/mobile 절 포함)
  .claude/config.json (agent_hints.mobile 작성)

위 정보로 진행하시겠습니까? [Y/n]:
```

`platform=web` 인 경우 기존 형식 (모바일 절 생략):

```
=== /aiops:setup 감지 결과 ===
플랫폼:     web
언어:       python (backend), typescript (frontend)
프레임워크: fastapi (backend), hono (frontend)
ORM:        sqlalchemy
DB:         postgres
구조:       monorepo
테스트:     pytest, vitest
배포:       cloudflare-workers
CI:         gitea-actions

생성될 파일:
  .reviewer/profile.yaml (신규 또는 덮어쓰기)
  .claude/config.json (agent_hints 필드 추가)

위 정보로 진행하시겠습니까? [Y/n]:
```

`platform=cli` 인 경우 (#16 신규) — 모바일 절 생략, `CLI 엔트리:` 행 추가, `배포:` 미감지 시 안내 문구, 참고 2줄:

```
=== /aiops:setup 감지 결과 ===
플랫폼:     cli (터미널 CLI — 웹/모바일 미감지, bin 엔트리 감지)
언어:       typescript
프레임워크: node-cli
CLI 엔트리: dwc → dist/cli.js
구조:       single
테스트:     vitest
배포:       없음 (배포 매니페스트 미감지)
헬스체크:   자동 스킵 (dev_url / prod_url 미생성 — 배포 대상 없음, #42)
CI:         gitea-actions

참고: platform=cli 는 npm bin 엔트리 기반 터미널 도구를 뜻합니다.
      profile 은 전용 세트 없이 표준 web 세트를 그대로 사용합니다 (#16).

생성될 파일:
  .reviewer/profile.yaml (신규 또는 덮어쓰기)
  .claude/config.json (agent_hints 필드 추가)

위 정보로 진행하시겠습니까? [Y/n]:
```

`CLI 엔트리:` 값 규칙: `bin` 이 문자열이면 `<패키지명> → <경로>`, 객체면 첫 3개 항목 후 `외 N개`.

사용자가 `n` 입력 시 중단. 그 외(엔터 포함)는 진행.

**Hono 백엔드(§8-1) 표시 보정 (#206):** 휴리스틱이 Hono 를 backend 로 분류하면 위 결과 UI 의 `프레임워크` 줄에 `hono (backend)` 를, backend 로 채워졌음을 감지 근거(S2)와 함께 표시한다.

```
프레임워크: hono (backend)
[/aiops:setup] Hono를 backend로 분류 — 근거: wrangler + /api/ 라우트, 렌더 신호 없음 (§8-1 R2)
```

풀스택(R3)이면 `hono (backend + frontend)` 로 표시한다. §8-1 R5(모호)에 해당하면 진행 전에 1회 질의한다(C2):

```
[/aiops:setup] Hono 역할이 모호합니다 (wrangler 존재하나 라우트 성격 불명확).
  backend / frontend / both 중 무엇입니까? [frontend]:
```

엔터 시 기본값 `frontend` (역호환).

### 15. 모바일 프로젝트 감지

§1~§14 (웹 스택 감지) 와 병렬로 모바일 스택 감지를 실행한다.
스캔은 `find` `-maxdepth 3` 기준, `node_modules/`, `.git/`, `dist/`, `build/`, `Pods/`, `DerivedData/` 경로 제외.

```bash
# Android 네이티브 — build.gradle(.kts) + AndroidManifest.xml 동시 존재
ANDROID_DETECTED=false
if find . -maxdepth 3 \( -name "build.gradle.kts" -o -name "build.gradle" \) ! -path "*/node_modules/*" -print -quit 2>/dev/null | grep -q .; then
  # maxdepth 6 — 표준 레이아웃 <wrapper>/app/src/main/AndroidManifest.xml 이 깊이 5 다.
  # 4 로 두면 android/ 래퍼를 쓰는 레포(zen-koi 등)가 통째로 미감지된다.
  if find . -maxdepth 6 -name "AndroidManifest.xml" ! -path "*/node_modules/*" ! -path "*/build/*" -print -quit 2>/dev/null | grep -q .; then
    ANDROID_DETECTED=true
  fi
fi

# iOS 네이티브 — *.xcodeproj / *.xcworkspace / Package.swift 중 하나 이상
IOS_DETECTED=false
if find . -maxdepth 3 \( -name "*.xcodeproj" -o -name "*.xcworkspace" -o -name "Package.swift" \) -print -quit 2>/dev/null | grep -q .; then
  IOS_DETECTED=true
fi

# React Native — package.json deps 에 react-native
RN_DETECTED=false
if [[ -f "package.json" ]] && grep -q '"react-native"' package.json 2>/dev/null; then
  RN_DETECTED=true
fi

# Flutter — pubspec.yaml 존재
FLUTTER_DETECTED=false
if find . -maxdepth 3 -name "pubspec.yaml" -print -quit 2>/dev/null | grep -q .; then
  FLUTTER_DETECTED=true
fi
```

### 15-1. platform 신호 계산 — `WEB_DETECTED` · `MOBILE_DETECTED`

§16 의 판정은 이 두 값에서 출발한다. **산문이 아니라 코드로 계산한다** — 앞 절의 "§1~§3·§7 결과"
같은 참조에 기대면 실행 주체의 해석에 따라 같은 레포가 `web`·`mobile`·`both` 로 갈린다.

#### `MOBILE_DETECTED`

§15 의 네 플래그(`ANDROID_DETECTED`·`IOS_DETECTED`·`RN_DETECTED`·`FLUTTER_DETECTED`)의 **OR** 이다.

#### `WEB_DETECTED` — Gradle·Maven 단독은 웹 신호가 아니다

§1 의 `java` 감지(`build.gradle`·`pom.xml`)를 그대로 웹 신호로 쓰면 **Android 레포가 전부 `both` 가 된다.**
Android 도 Gradle 을 쓰기 때문이다. 웹 신호는 다음 둘 중 하나여야 한다.

| 신호 | 근거 |
|---|---|
| **웹 프레임워크 의존성** | §7 의 식별자 — `hono`·`next`·`react`·`vue`·`svelte`·`astro`·`express`·`fastify`·`koa`·`@nestjs/core`·`@remix-run/*`·`nuxt` / `fastapi`·`django`·`flask`·`starlette`·`litestar` / `gin`·`echo`·`fiber` / `actix-web`·`axum`·`rocket` / **`spring-boot`·`ktor`·`micronaut`·`quarkus`·`javalin`** |
| **웹 배포 매니페스트** | `wrangler.toml`·`wrangler.jsonc`·`vercel.json`·`netlify.toml`·`fly.toml`·`serverless.yml` (깊이 3까지 — 모노레포는 `apps/*/` 아래에 있다) |

`react` 는 `"react":` 로 키를 정확히 본다. `react-native` 에 `react` 가 부분 문자열로 들어 있어
**앵커 없이 찾으면 RN 레포가 웹으로 잡힌다** — v1.11.0 의 `PASS_DRY_RUN` 과 같은 부류다.

```bash
# >>> setup:platform-signals >>>
# WEB_DETECTED · MOBILE_DETECTED 를 파일시스템에서 직접 계산한다.
# 선행 변수(선택): §15 의 ANDROID_DETECTED·IOS_DETECTED·RN_DETECTED·FLUTTER_DETECTED.
#                  없으면 false 로 보고 웹 신호만으로 판정한다.
# bash 3.2 준수. 이 블록은 아무것도 출력하지 않아도 두 변수를 반드시 정의한다.

MOBILE_DETECTED=false; MOBILE_SIGNAL=""
for _pair in "android:${ANDROID_DETECTED:-false}" "ios:${IOS_DETECTED:-false}" \
             "rn:${RN_DETECTED:-false}" "flutter:${FLUTTER_DETECTED:-false}"; do
  if [ "${_pair#*:}" = "true" ]; then
    MOBILE_DETECTED=true
    MOBILE_SIGNAL="${MOBILE_SIGNAL:+$MOBILE_SIGNAL+}${_pair%%:*}"
  fi
done

WEB_DETECTED=false; WEB_SIGNAL=""

# (1) 웹 배포 매니페스트 — 모노레포는 apps/*/ 아래에 있다. 루트만 보면 놓친다.
#     §15 가 모바일을 깊이 3·6 으로 보는 것과 균형을 맞춘다.
_ps_find_any() {   # $1=maxdepth, $2..=-name 조건
  local d="$1"; shift
  find . -maxdepth "$d" \
    \( -name node_modules -o -name .git -o -name build -o -name Pods -o -name DerivedData \) -prune -o \
    \( "$@" \) -type f -print 2>/dev/null
}
for _m in $(_ps_find_any 3 -name 'wrangler.toml' -o -name 'wrangler.jsonc' -o -name 'vercel.json' \
            -o -name 'netlify.toml' -o -name 'fly.toml' -o -name 'serverless.yml'); do
  WEB_DETECTED=true; WEB_SIGNAL="${_m#./}"; break
done

# (2) 웹 프레임워크 의존성
_ps_find() {   # $1=maxdepth, $2..=-name 조건
  local d="$1"; shift
  find . -maxdepth "$d" \
    \( -name node_modules -o -name .git -o -name build -o -name Pods -o -name DerivedData \) -prune -o \
    \( "$@" \) -type f -print 2>/dev/null
}

if [ "$WEB_DETECTED" = "false" ]; then
  # Node — 키를 "이름": 형태로 정확히 본다.
  for _f in $(_ps_find 3 -name 'package.json'); do
    # react 는 **단독일 때만** 웹 신호다(§7 표). React Native 는 react 를 반드시 의존하므로
    # 같은 파일에 react-native 가 있으면 react 를 웹 신호로 세지 않는다.
    _web_keys='hono|next|nuxt|vue|svelte|@sveltejs/kit|astro|express|fastify|koa|@nestjs/core'
    grep -qE '"react-native"[[:space:]]*:' "$_f" 2>/dev/null || _web_keys="$_web_keys|react"
    _hit="$(grep -oE "\"($_web_keys)\"[[:space:]]*:" "$_f" 2>/dev/null | head -1 | tr -d '":[:space:]')"
    [ -z "$_hit" ] && grep -qE '"@remix-run/' "$_f" 2>/dev/null && _hit="@remix-run"
    if [ -n "$_hit" ]; then
      WEB_DETECTED=true; WEB_SIGNAL="${_f#./}:$_hit"; break
    fi
  done
fi

if [ "$WEB_DETECTED" = "false" ]; then
  # Java · Kotlin 웹 — **빌드 파일의 존재가 아니라 내용을 본다.**
  # Gradle·Maven 자체는 웹 신호가 아니다(Android 도 쓴다). 웹 프레임워크 의존성이 있을 때만이다.
  for _f in $(_ps_find 4 -name 'build.gradle' -o -name 'build.gradle.kts' -o -name 'pom.xml' \
              -o -name 'libs.versions.toml'); do
    _hit="$(grep -oiE '(spring-boot|io\.ktor|ktor-server|micronaut|quarkus|javalin)' "$_f" 2>/dev/null | head -1)"
    if [ -n "$_hit" ]; then
      WEB_DETECTED=true; WEB_SIGNAL="${_f#./}:$_hit"; break
    fi
  done
fi

if [ "$WEB_DETECTED" = "false" ]; then
  # Python · Go · Rust
  for _f in $(_ps_find 3 -name 'requirements.txt' -o -name 'pyproject.toml' -o -name 'go.mod' -o -name 'Cargo.toml'); do
    _hit="$(grep -oiE '(fastapi|django|flask|starlette|litestar|gin-gonic/gin|labstack/echo|gofiber/fiber|actix-web|axum|rocket)' "$_f" 2>/dev/null | head -1)"
    if [ -n "$_hit" ]; then
      WEB_DETECTED=true; WEB_SIGNAL="${_f#./}:$_hit"; break
    fi
  done
fi

echo "[setup] §15-1 web=$WEB_DETECTED(${WEB_SIGNAL:-none}) mobile=$MOBILE_DETECTED(${MOBILE_SIGNAL:-none})"
# <<< setup:platform-signals <<<
```

앵커 문자열은 `aiops/tests/setup-platform-signals.test.sh` 의 추출 지점이므로 변경 금지.

**실행 순서**: §15(모바일 플래그) → **§15-1(신호 계산)** → §16(platform 판정). §16 의 앵커는 이 두
값을 입력으로 받는다.

### 16. platform 결정 로직

웹 스택 감지 여부(§1~§3 결과)와 모바일 감지 여부(§15)를 조합하여 `platform` 값을 결정한다.

| 웹 감지 | 모바일 감지 | platform |
|--------|------------|----------|
| O | X | `web` (기본, 역호환) |
| X | O | `mobile` |
| O | O | `both` |
| X | X + `bin` O + 웹배포매니페스트 X | `cli` (신규, #16) |
| X | X (그 외) | `web` (안전 기본값) |

CLI 판정 보조 조건표 (#16 신규):

| 조건 | 값 |
|---|---|
| `package.json` `bin` (문자열 또는 원소 ≥1 객체) | `node-cli` |
| `pyproject.toml` `[project.scripts]` | `python-cli` (**예약** — 후속 이슈, 이번 범위 아님) |

CLI 판정을 무효화하는 것은 **웹 호스팅 매니페스트만**이다: `wrangler.toml`·`wrangler.jsonc`·`vercel.json`·`netlify.toml`·`fly.toml`·`serverless.yml`(루트만 검사). **`Dockerfile` 은 제외 조건이 아니다** — CLI 도 Docker 로 배포되므로 `deploy_target=docker` 로 §10 에 계속 기록되되 platform 판정에는 쓰이지 않는다.

```bash
# >>> setup:platform-detect >>>
# 선행 변수: WEB_DETECTED · MOBILE_DETECTED — **§15-1 앵커가 계산한다.**
# 기본값은 안전망일 뿐이다. §15-1 을 실행하지 않으면 둘 다 false 가 되어 platform=web 으로
# 떨어진다 — 모바일 레포가 조용히 web 으로 판정되므로 §15-1 을 건너뛰지 않는다.
WEB_DETECTED="${WEB_DETECTED:-false}"; MOBILE_DETECTED="${MOBILE_DETECTED:-false}"
HAS_BIN=false                      # (1) package.json bin — 빈 객체 {} 는 미판정
if [[ -f package.json ]]; then
  if command -v jq >/dev/null 2>&1; then
    _bin=$(jq -r 'if ((.bin|type)=="string" or (.bin|type)=="object") and ((.bin|length)>0)
                  then "yes" else "no" end' package.json 2>/dev/null || echo "no")
    [[ "$_bin" == "yes" ]] && HAS_BIN=true
  else
    grep -q '"bin"[[:space:]]*:' package.json 2>/dev/null && HAS_BIN=true
  fi
fi
HAS_WEB_DEPLOY_MANIFEST=false      # (2) 웹 호스팅 매니페스트 (Dockerfile 불포함 — 결정 (b))
for _m in wrangler.toml wrangler.jsonc vercel.json netlify.toml fly.toml serverless.yml; do
  [[ -f "$_m" ]] && { HAS_WEB_DEPLOY_MANIFEST=true; break; }
done
# PLATFORM_SIGNAL — **무엇이 판정했는가.** "신호로 판정" 과 "기본값으로 떨어짐" 은 다르다.
# 후자는 감지가 아무것도 못 찾았다는 뜻이며 사람이 한 번 봐야 하는 상태다.
if   [[ "$WEB_DETECTED" == "true" && "$MOBILE_DETECTED" == "true" ]]; then
  PLATFORM="both";   PLATFORM_SIGNAL="${WEB_SIGNAL:-?} + ${MOBILE_SIGNAL:-?}"
elif [[ "$MOBILE_DETECTED" == "true" ]]; then
  PLATFORM="mobile"; PLATFORM_SIGNAL="${MOBILE_SIGNAL:-?}"
elif [[ "$WEB_DETECTED" == "true" ]]; then
  PLATFORM="web";    PLATFORM_SIGNAL="${WEB_SIGNAL:-?}"
elif [[ "$HAS_BIN" == "true" && "$HAS_WEB_DEPLOY_MANIFEST" == "false" ]]; then
  PLATFORM="cli";    PLATFORM_SIGNAL="package.json:bin"
else
  PLATFORM="web";    PLATFORM_SIGNAL="none (fallback)"
fi
echo "[setup] §16 platform=$PLATFORM signal=$PLATFORM_SIGNAL (web=$WEB_DETECTED mobile=$MOBILE_DETECTED bin=$HAS_BIN web_manifest=$HAS_WEB_DEPLOY_MANIFEST)"
[[ "$PLATFORM_SIGNAL" == "none (fallback)" ]] && \
  echo "[setup] §16 ⚠️ 신호 없이 기본값으로 판정했습니다 — 감지가 아무것도 찾지 못했습니다. 사람이 확인하세요."
# <<< setup:platform-detect <<<
```

앵커 문자열은 `aiops/tests/setup-platform-detect.test.sh` 의 추출 지점이므로 변경 금지. bash 3.2 준수(연관배열·`${v,,}`·`mapfile` 미사용), jq 부재 시 grep 폴백은 `"bin"[[:space:]]*:` 키 패턴만 확인한다(오탐 방지를 위한 값 검사는 하지 않음 — jq 가용 환경을 권장).

### 판정 근거를 남긴다 — "판정됨" 과 "기본값으로 떨어짐" 은 다르다

§16 표의 마지막 행(웹X·모바일X·bin X)은 **안전 기본값**이지 판정이 아니다. 결과만 보면
신호로 `web` 이 된 레포와 구별되지 않아 **감지가 제대로 됐는지 아무도 모른다.**

```
platform=web  signal=apps/blog/package.json:hono   ← 신호로 판정
platform=web  signal=none (fallback)               ← 기본값. 사람이 봐야 한다
```

뒤의 경우에는 경고를 함께 출력한다. HANDOFF 계약의 "확인됨 / 확인했다고 함" 구분과 같은 논리다.

`mobile.framework` 값 결정 (다중 가능 → 배열):

| 감지 플래그 | framework 값 |
|-----------|-------------|
| `ANDROID_DETECTED=true` 단독 | `android-native` |
| `IOS_DETECTED=true` 단독 | `ios-native` |
| `ANDROID_DETECTED=true` + `IOS_DETECTED=true` | `[android-native, ios-native]` |
| `RN_DETECTED=true` | `react-native` |
| `FLUTTER_DETECTED=true` | `flutter` |

크로스플랫폼(`react-native`, `flutter`)이 감지되면 네이티브 플래그보다 우선한다 (모노레포가 아닌 한).

`mobile.build_system` 값:

| framework | build_system |
|-----------|--------------|
| `android-native` | `gradle` |
| `ios-native` | `xcode` |
| `react-native` | `metro` |
| `flutter` | `flutter` |
| 다중(배열) | 배열 (예: `[gradle, xcode]`) |

`mobile.e2e_runner` 값: `maestro` (기본 고정, 후속 이슈 #150에서 사용).

### 16-1. 판정 근거를 config 에 기록한다

§16 은 `PLATFORM_SIGNAL` 을 **출력**한다. 출력만으로는 세션이 끝나면 근거가 사라지고, 나중에
`agent_hints.platform` 만 보면 **신호로 판정된 것인지 기본값으로 떨어진 것인지 알 수 없다.**

`platform` 옆에 근거를 함께 기록한다.

```jsonc
{
  "agent_hints": {
    "platform": "web",
    "platform_signal": "apps/blog/wrangler.jsonc"   // 또는 "none (fallback)"
  }
}
```

**실행 순서 제약** — §13·§19 의 `agent_hints` 기입 뒤에 온다. §19 가 `.agent_hints` 를 통째로
덮어쓰므로 그 앞에서 쓰면 지워진다(§20 과 같은 제약).

```bash
# >>> setup:platform-signal-write >>>
# 선행: $PLATFORM·$PLATFORM_SIGNAL(§16), 헬퍼 _config_update(§5).
# §13·§19 의 agent_hints 기입이 끝난 뒤에 실행한다.
if command -v jq >/dev/null 2>&1; then
  if _config_update '.agent_hints.platform = $p | .agent_hints.platform_signal = $s' \
       --arg p "${PLATFORM:-web}" --arg s "${PLATFORM_SIGNAL:-unknown}"; then
    echo "[setup] §16-1 platform=$PLATFORM signal=$PLATFORM_SIGNAL 기록 완료"
  else
    echo "[setup] §16-1 WARN: platform 기록 실패 — 위 오류를 확인하세요."
  fi
else
  echo "[setup] §16-1 WARN: jq 미설치 — platform 기록 생략."
fi
# <<< setup:platform-signal-write <<<
```

앵커 문자열은 `aiops/tests/setup-platform-signals.test.sh` 의 추출 지점이므로 변경 금지.

`platform_signal` 이 `none (fallback)` 이면 **감지가 아무것도 찾지 못한 상태**다. 그 config 를
읽는 쪽(`/aiops:mobileflow` 진입 라우팅, `dev-mobile-*` 분기)은 값을 신뢰하기 전에 이 필드를 본다.

§19 보존 목록에도 `agent_hints.platform_signal` 을 넣는다 — 재실행 시 감지 실패가 기존 근거를
`unknown` 으로 덮지 않게 한다.

### 17. profile.yaml 작성 확장

§12 의 신규 생성 포맷을 다음과 같이 확장한다. `platform` 필드는 항상 작성하며, `mobile:` 절은 `platform=mobile | both` 일 때만 작성한다.

```yaml
# Reviewer 프로필 — /aiops:setup 이 자동 생성
# 스키마: claude-ai-devops/docs/review-profile-schema.md
# 모바일 스키마: claude-ai-devops/docs/mobile-overview.md

repo: OWNER/NAME                   # forge.sh repo (→ owner/repo)
forge: github | gitea              # 선택 — 생략 시 origin 리모트로 자동감지(forge.sh kind)
platform: web | mobile | both | cli   # cli 는 #16 신규 (기본 web, 역호환)
structure: single | monorepo | monorepo-submodules

stack:
  backend: fastapi-sqlalchemy | fastapi-sqlite | django | nestjs | node-cli | none
  frontend: hono-ts | nextjs | react | vue | svelte | none
  admin: hono-ts | nextjs | none

# platform=mobile 또는 both 일 때만 작성
mobile:
  framework: android-native | ios-native | react-native | flutter   # 또는 배열
  build_system: gradle | xcode | metro | flutter                    # 또는 배열
  e2e_runner: maestro

prd_source: github-issue
max_diff_loc: 1500
```

`.claude/config.json` 의 `agent_hints` 도 동일 정보를 반영한다 (§13 스키마에 `platform`, `mobile` 필드 추가).

`agent_hints.platform` 허용값: `web | mobile | both | cli` (cli 는 #16 신규, 끝에 추가하여 기존 diff 최소화).

```json
{
  "agent_hints": {
    "platform": "both",
    "backend": { ... },
    "frontend": { ... },
    "mobile": {
      "framework": ["android-native", "ios-native"],
      "build_system": ["gradle", "xcode"],
      "e2e_runner": "maestro"
    },
    "structure": "monorepo",
    "ci": "gitea-actions"
  }
}
```

웹 전용 프로젝트는 `mobile` 키를 생략하거나 `null` 로 둔다 (역호환 보장).

## §18. 프로필 자동 등록 (#161 신규)

§16에서 platform 결정 후 `.claude/config.json` 의 `profile` 필드를 자동 작성한다. 사용자가 명시적으로 변경하지 않는 한 다음 매핑을 따른다:

| platform | mobile.framework | 자동 profile |
|----------|------------------|------------|
| web | (없음) | `web` |
| cli | (없음) | `web` (전용 프로필 신설 없이 표준 세트 재사용, #16) |
| mobile | android-native 또는 ios-native | `mobile` |
| mobile | react-native 또는 flutter | `mobile` |
| both | (모두) | `full` |
| (감지 실패) | — | `minimal` |

```bash
# >>> setup:profile-register >>>
# 선행 변수: $PLATFORM (§10 감지 결과). 헬퍼 _config_update 정의가 앞서야 한다.
case "$PLATFORM" in
  web)    AUTO_PROFILE="web" ;;
  cli)    AUTO_PROFILE="web" ;;   # #16 — 전용 프로필 신설 없이 표준 세트 재사용
  mobile) AUTO_PROFILE="mobile" ;;
  both)   AUTO_PROFILE="full" ;;
  *)      AUTO_PROFILE="minimal" ;;
esac

# 기존 profile 보존 (사용자 수동 변경 우선)
CURRENT_PROFILE=$(jq -r '.profile // empty' .claude/config.json 2>/dev/null)
if [[ -z "$CURRENT_PROFILE" ]]; then
  if _config_update '.profile = $p' --arg p "$AUTO_PROFILE"; then
    echo "[/aiops:setup] profile=$AUTO_PROFILE 자동 등록 (#161)"
    echo "         변경하려면: install.sh --profile=<web|mobile|full|minimal|reviewer> 재실행"
  else
    echo "[setup] §18 WARN: profile 기입 실패 — 위 오류를 확인하세요"
  fi
else
  echo "[/aiops:setup] profile=$CURRENT_PROFILE 보존 (사용자 명시 또는 이전 설정)"
fi
# <<< setup:profile-register <<<
```

§13 사용자 확인 UI 출력에 profile 추가:

```
=== /aiops:setup 감지 결과 ===
플랫폼:     mobile (android + ios)
프로파일:   mobile (자동 — 변경: install.sh --profile=<n>)
...
```

## §19. agent_hints 보존 (#173 — 중요)

`/aiops:setup` 재실행 시 기존 `.claude/config.json` 의 다음 필드를 **반드시 보존**해야 한다. 빈 값으로 덮어쓰면 mobileflow/aiops:review-pr 등 의존 워크플로우가 깨진다.

| 보존 대상 | 사유 |
|---------|------|
| `agent_hints` | dev-backend/dev-frontend/dev-mobile-* 등 에이전트가 동적 스택 적응에 사용 |
| `agent_hints.mobile.framework` | /aiops:mobileflow 진입 라우팅 |
| `agent_hints.mobile.capabilities` | §20 권한·SDK 감지 결과 — 법적 문서·광고 스킬의 근거 |
| `agent_hints.platform_signal` | §16-1 판정 근거 — 신호 판정과 폴백을 구별한다 |
| `agent_hints.backend.framework` | dev-backend 가이드 결정 |
| `workspaces` | #167 모노레포 매핑 |
| `profile` | #161 프로필 선택 |

### 보존 패턴

```bash
# 기존 값 백업 (jq -c로 JSON 인코딩 보장)
PRESERVE_AGENT_HINTS=$(jq -c '.agent_hints // null' .claude/config.json 2>/dev/null || echo null)
PRESERVE_WORKSPACES=$(jq -c '.workspaces // null' .claude/config.json 2>/dev/null || echo null)
PRESERVE_PROFILE=$(jq -c '.profile // null' .claude/config.json 2>/dev/null || echo null)

# 새 값으로 갱신할 때는 정밀 감지 결과가 있을 때만 덮어쓰기
NEW_HINTS=$(detect_agent_hints)  # 정밀 감지
if [[ -n "$NEW_HINTS" && "$NEW_HINTS" != "null" ]]; then
  _config_update '.agent_hints = $h' --argjson h "$NEW_HINTS" \
    || echo "[setup] §19 WARN: agent_hints 기입 실패 — 위 오류를 확인하세요"
else
  # 감지 실패 — 기존 값 보존
  _config_update '.agent_hints = $h' --argjson h "$PRESERVE_AGENT_HINTS" \
    || echo "[setup] §19 WARN: agent_hints 기입 실패 — 위 오류를 확인하세요"
fi
```

### tech_stack confirm 처리 (#173)

프롬프트 `"Enter=확인, 직접 입력=수정"` 에 사용자가 `Y`/`y`/`yes`/`N`/`n`/`no` 등 confirm 응답을 입력하면 **DETECTED_STACK 변경 없이 확인 처리**. 실제 스택 문자열(예: `python, fastapi`)일 때만 적용.

```bash
case "$(echo "$stack_input" | tr '[:upper:]' '[:lower:]')" in
  ""|y|yes|n|no) ;;  # confirm — 변경 없음
  *) DETECTED_STACK="$stack_input" ;;
esac
```

## §20. 모바일 앱 역량 감지 — 권한·SDK (감지 계층)

`platform=mobile | both` 일 때 §15 의 프레임워크 감지에 더해 **대상 앱이 실제로 무엇을 하는지**를 읽어낸다.
런타임 권한 선언과 서드파티 SDK 의존성이 감지 대상이며, 결과는 `agent_hints.mobile.capabilities` 에 기록된다.

이 절이 필요한 이유는 산출물이 아니라 **입력** 때문이다. 법적 문서(개인정보 처리방침·이용약관)는 그 앱이
실제로 하는 동작만 적어야 한다 — 다른 앱 문서를 복사하면 선언하지 않은 권한(카메라 등)이 섞인다.
광고·아이콘 작업이 필요로 하는 스택 감지와 같은 입력을 쓰므로 **한 번만 정의한다**.

### 감지 원칙

- **선언된 것만 적는다.** 매니페스트·plist·의존성 선언에 없는 것을 추론하지 않는다.
- **정규화한다.** 플랫폼별 원시 키를 공통 토큰으로 사상하여 Android·iOS 가 같은 어휘를 쓰게 한다.
- **기본 언어는 추론하지 않는다.** Android 의 `res/values/` 는 한정자가 없어 어느 언어인지 기계적으로
  알 수 없다. iOS `sourceLanguage` 가 있으면 그것을 쓰고, 없으면 `languages_base_unknown: true` 로
  남겨 사람이 확인하게 한다 — 짐작해서 채우면 `releases.json` 에 없는 언어 칸이 생긴다.
- **깊이 6까지 스캔한다.** 표준 Android 레이아웃 `<wrapper>/app/src/main/AndroidManifest.xml` 이 깊이 5 이고,
  모노레포 래퍼가 한 겹 더 붙는 경우까지 감안한 값이다. `build/`·`Pods/`·`DerivedData/` 를 prune 하므로
  깊이를 올려도 생성물은 읽지 않는다.
- **감지 실패는 빈 목록이다.** 오류가 아니다 — 소비자가 "감지 안 됨"과 "권한 없음"을 구별할 수 있도록
  `sources` 에 실제로 읽은 파일을 함께 남긴다.

### 권한 정규화 표

| Android `uses-permission` | iOS Info.plist 키 | 공통 토큰 |
|---|---|---|
| `CAMERA` | `NSCameraUsageDescription` | `camera` |
| `RECORD_AUDIO` | `NSMicrophoneUsageDescription` | `microphone` |
| `ACCESS_FINE_LOCATION` · `ACCESS_COARSE_LOCATION` | `NSLocationWhenInUseUsageDescription` · `NSLocationAlwaysAndWhenInUseUsageDescription` | `location` |
| `READ_EXTERNAL_STORAGE` · `WRITE_EXTERNAL_STORAGE` · `READ_MEDIA_*` | `NSPhotoLibraryUsageDescription` · `NSPhotoLibraryAddUsageDescription` | `photo_library` |
| `READ_CONTACTS` · `WRITE_CONTACTS` | `NSContactsUsageDescription` | `contacts` |
| `POST_NOTIFICATIONS` | — (런타임 API) | `notifications` |
| `BLUETOOTH*` | `NSBluetoothAlwaysUsageDescription` · `NSBluetoothPeripheralUsageDescription` | `bluetooth` |
| `com.google.android.gms.permission.AD_ID` · `ACCESS_ADSERVICES_{AD_ID,ATTRIBUTION,TOPICS}` | `NSUserTrackingUsageDescription` | `tracking` |
| `INTERNET` | — (기본 허용) | `internet` |

`tracking` 은 법적 문서에서 가장 자주 누락되는 항목이다 — Android 의 `AD_ID` 와 iOS 의 ATT 가 서로 다른
자리에 선언되어 한쪽만 보면 놓친다. 두 플랫폼을 함께 스캔하는 이유가 여기에 있다.

### SDK 정규화 표

| 의존성 문자열 (Gradle · SPM · Pod · npm · pub) | 공통 토큰 |
|---|---|
| `play-services-ads` · `GoogleMobileAds` · `google_mobile_ads` | `admob` |
| `user-messaging-platform` · `UserMessagingPlatform` | `ump` |
| `firebase-analytics` · `FirebaseAnalytics` | `firebase_analytics` |
| `firebase-crashlytics` · `FirebaseCrashlytics` | `crashlytics` |
| `play-services-auth` · `GoogleSignIn` | `google_signin` |
| `billing` · `StoreKit` · `purchases` (RevenueCat) | `iap` |
| `sentry` | `sentry` |

### 언어 정규화 표

`releases.json` 의 `languages` 는 앱마다 다르다. 기존 앱 파일을 복사하면 없는 언어 칸이 생기거나
(사이트에 공백이 렌더된다) 실제 지원 언어가 빠지므로, **대상 레포의 실제 리소스에서 읽는다.**

| 출처 | 원시 값 | 공통 토큰 |
|---|---|---|
| Android `res/values-*` | `values-ko` | `ko` |
| Android `res/values-*` | `values-zh-rCN` · `values-zh-rSG` · `values-b+zh+Hans` | `zh-Hans` |
| Android `res/values-*` | `values-zh-rTW` · `values-zh-rHK` · `values-zh-rMO` · `values-b+zh+Hant` | `zh-Hant` |
| Android `res/values-*` | `values-pt-rBR` | `pt-BR` |
| iOS `*.xcstrings` | `sourceLanguage` | 그 값 (기본 언어) |
| iOS `*.xcstrings` | `strings[].localizations` 키 | 그 키 |
| iOS `*.lproj` | `ko.lproj` | `ko` |

`res/values-*` 의 한정자는 **언어가 아닌 것이 더 많다** — `values-night`·`values-land`·`values-v21`·
`values-sw600dp` 등이 섞인다. 허용 패턴(2~3자 소문자, `-rXX`, `b+zh+Hans`)만 받고 충돌하는 UI 한정자
(`night`·`land`·`port`·`round`·`car`·`tv`·`watch`·`television`·`ldrtl`·`ldltr`)는 먼저 걸러낸다.

### 감지 코드

```bash
# >>> setup:mobile-capability-detect >>>
# 선행 변수(앵커 밖): 없음 — 현재 디렉터리를 직접 스캔한다.
# 출력: MOBILE_PERMISSIONS / MOBILE_SDKS / MOBILE_LANGUAGES / MOBILE_CAPABILITY_SOURCES
#       (쉼표 구분, 빈 값 가능) + MOBILE_LANG_BASE_UNKNOWN (true|false)
# bash 3.2 준수 — 연관배열·${v,,}·mapfile 미사용. 감지 실패는 빈 목록이며 rc=0.
# 제외 디렉터리는 함수 안에 그대로 적는다 — 변수에 담아 비인용 전개하면
# 셸에 따라 단어 분리가 일어나지 않아 find 가 통째로 한 인자로 받는다.
_cap_find() {   # $1=maxdepth, $2..=매칭 조건(-name …). -type f 는 함수가 붙인다.
  local d="$1"; shift
  find . -maxdepth "$d" \
    \( -name node_modules -o -name .git -o -name build -o -name Pods -o -name DerivedData \) -prune -o \
    \( "$@" \) -type f -print 2>/dev/null
}

_CAP_PERM_RAW=""; _CAP_SDK_RAW=""; _CAP_SRC=""

# ── Android: AndroidManifest.xml 의 uses-permission ──────────────────
for _f in $(_cap_find 6 -name AndroidManifest.xml); do
  _CAP_SRC="$_CAP_SRC $_f"
  _CAP_PERM_RAW="$_CAP_PERM_RAW $(grep -o 'android:name="[^"]*"' "$_f" 2>/dev/null \
    | sed 's/.*permission\.//; s/"$//' | tr '\n' ' ')"
done

# ── iOS: Info.plist 의 NS*UsageDescription 키 ────────────────────────
for _f in $(_cap_find 6 -name 'Info.plist'); do
  _CAP_SRC="$_CAP_SRC $_f"
  _CAP_PERM_RAW="$_CAP_PERM_RAW $(grep -o 'NS[A-Za-z]*UsageDescription' "$_f" 2>/dev/null | tr '\n' ' ')"
done

# ── 의존성 선언 파일 (SDK) ───────────────────────────────────────────
for _f in $(_cap_find 6 -name '*.gradle' -o -name '*.gradle.kts' -o -name 'libs.versions.toml' \
            -o -name 'Package.swift' -o -name 'Podfile' -o -name 'project.pbxproj' \
            -o -name 'package.json' -o -name 'pubspec.yaml'); do
  _CAP_SRC="$_CAP_SRC $_f"
  _CAP_SDK_RAW="$_CAP_SDK_RAW $(grep -oiE 'play-services-ads|GoogleMobileAds|google_mobile_ads|user-messaging-platform|UserMessagingPlatform|firebase-analytics|FirebaseAnalytics|firebase-crashlytics|FirebaseCrashlytics|play-services-auth|GoogleSignIn|billing|StoreKit|purchases|sentry' "$_f" 2>/dev/null | tr '\n' ' ')"
done

# ── 지원 언어 (releases.json 의 languages 근거) ──────────────────────
_CAP_LANG_RAW=""; _CAP_HAS_ANDROID_LANG=false; _CAP_HAS_IOS_SOURCE=false
MOBILE_LANG_BASE_UNKNOWN=false

_cap_find_dir() {   # $1=maxdepth, $2..=매칭 조건. 디렉터리만 반환한다.
  local d="$1"; shift
  find . -maxdepth "$d" \
    \( -name node_modules -o -name .git -o -name build -o -name Pods -o -name DerivedData \) -prune -o \
    \( "$@" \) -type d -print 2>/dev/null
}

# Android res/values-<한정자>/ — 한정자는 언어가 아닌 것이 더 많다(night·land·v21…).
# 허용 패턴(2~3자 소문자, -rXX, b+zh+Hans)만 받고, 충돌하는 UI 한정자는 먼저 걸러낸다.
_cap_lang_android() {   # $1=values- 뒤 한정자 → 공통 토큰 또는 빈 출력
  case "$1" in
    night|notnight|land|port|round|car|tv|watch|television|ldrtl|ldltr) : ;;
    zh-rCN|zh-rSG|b+zh+Hans)        echo zh-Hans ;;
    zh-rTW|zh-rHK|zh-rMO|b+zh+Hant) echo zh-Hant ;;
    *-r[A-Z][A-Z])                  echo "$1" | sed 's/-r/-/' ;;
    [a-z][a-z]|[a-z][a-z][a-z])     echo "$1" ;;
  esac
}

for _d in $(_cap_find_dir 7 -name 'values-*'); do
  _q="${_d##*/values-}"
  _tok="$(_cap_lang_android "$_q")"
  if [ -n "$_tok" ]; then
    _CAP_LANG_RAW="$_CAP_LANG_RAW $_tok"; _CAP_HAS_ANDROID_LANG=true
  fi
done

# iOS .xcstrings — sourceLanguage(기본 언어) + 각 문자열의 localizations 키
for _f in $(_cap_find 6 -name '*.xcstrings'); do
  _CAP_SRC="$_CAP_SRC $_f"
  if command -v jq >/dev/null 2>&1; then
    _src="$(jq -r '.sourceLanguage // empty' "$_f" 2>/dev/null)"
    [ -n "$_src" ] && { _CAP_LANG_RAW="$_CAP_LANG_RAW $_src"; _CAP_HAS_IOS_SOURCE=true; }
    _CAP_LANG_RAW="$_CAP_LANG_RAW $(jq -r '[.strings[]?.localizations? // {} | keys[]] | unique | join(" ")' "$_f" 2>/dev/null)"
  else
    _CAP_LANG_RAW="$_CAP_LANG_RAW $(grep -oE '"[a-z]{2,3}(-[A-Za-z]{2,4})?"[[:space:]]*:[[:space:]]*\{' "$_f" 2>/dev/null \
      | sed 's/[":{ ]//g' | tr '\n' ' ')"
  fi
done

# 구형 프로젝트의 <lang>.lproj — build/·DerivedData/ 는 prune 되므로 소스만 잡힌다.
for _d in $(_cap_find_dir 6 -name '*.lproj'); do
  _b="${_d##*/}"; _CAP_LANG_RAW="$_CAP_LANG_RAW ${_b%.lproj}"
done

# Android 기본 언어(res/values/)는 한정자가 없어 기계적으로 알 수 없다.
# iOS sourceLanguage 가 없으면 기본 언어를 추론하지 않고 "모름" 으로 남긴다.
if [ "$_CAP_HAS_ANDROID_LANG" = "true" ] && [ "$_CAP_HAS_IOS_SOURCE" = "false" ]; then
  MOBILE_LANG_BASE_UNKNOWN=true
fi

# ── 정규화 ───────────────────────────────────────────────────────────
_cap_norm_perm() {   # stdin=원시 토큰 → stdout=공통 토큰(1줄 1개)
  tr ' ' '\n' | while IFS= read -r _t; do
    case "$_t" in
      CAMERA|NSCameraUsageDescription)                      echo camera ;;
      RECORD_AUDIO|NSMicrophoneUsageDescription)            echo microphone ;;
      ACCESS_FINE_LOCATION|ACCESS_COARSE_LOCATION|NSLocation*UsageDescription) echo location ;;
      READ_EXTERNAL_STORAGE|WRITE_EXTERNAL_STORAGE|READ_MEDIA_*|NSPhotoLibrary*UsageDescription) echo photo_library ;;
      READ_CONTACTS|WRITE_CONTACTS|NSContactsUsageDescription) echo contacts ;;
      POST_NOTIFICATIONS)                                   echo notifications ;;
      BLUETOOTH*|NSBluetooth*UsageDescription)              echo bluetooth ;;
      AD_ID|ACCESS_ADSERVICES_AD_ID|ACCESS_ADSERVICES_ATTRIBUTION|ACCESS_ADSERVICES_TOPICS|NSUserTrackingUsageDescription) echo tracking ;;
      INTERNET)                                             echo internet ;;
    esac
  done
}

_cap_norm_sdk() {    # stdin=원시 토큰 → stdout=공통 토큰(1줄 1개)
  tr ' ' '\n' | tr '[:upper:]' '[:lower:]' | while IFS= read -r _t; do
    case "$_t" in
      play-services-ads|googlemobileads|google_mobile_ads)  echo admob ;;
      user-messaging-platform|usermessagingplatform)        echo ump ;;
      firebase-analytics|firebaseanalytics)                 echo firebase_analytics ;;
      firebase-crashlytics|firebasecrashlytics)             echo crashlytics ;;
      play-services-auth|googlesignin)                      echo google_signin ;;
      billing|storekit|purchases)                           echo iap ;;
      sentry)                                               echo sentry ;;
    esac
  done
}

MOBILE_PERMISSIONS="$(printf '%s' "$_CAP_PERM_RAW" | _cap_norm_perm | sort -u | tr '\n' ',' | sed 's/,$//')"
MOBILE_SDKS="$(printf '%s' "$_CAP_SDK_RAW" | _cap_norm_sdk | sort -u | tr '\n' ',' | sed 's/,$//')"
MOBILE_CAPABILITY_SOURCES="$(printf '%s' "$_CAP_SRC" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')"
MOBILE_LANGUAGES="$(printf '%s' "$_CAP_LANG_RAW" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')"

echo "[setup] §20 permissions=${MOBILE_PERMISSIONS:-none} sdks=${MOBILE_SDKS:-none} languages=${MOBILE_LANGUAGES:-none}"
[ "$MOBILE_LANG_BASE_UNKNOWN" = "true" ] && \
  echo "[setup] §20 WARN: Android 기본 언어(res/values/)를 판정할 수 없습니다 — languages 에 기본 언어가 빠졌을 수 있습니다. 사람에게 확인하세요."
# <<< setup:mobile-capability-detect <<<
```

앵커 문자열은 `aiops/tests/setup-mobile-capability-detect.test.sh` 의 추출 지점이므로 변경 금지.

### agent_hints 확장

§17 의 `mobile` 절에 `capabilities` 를 추가한다. 웹 전용 프로젝트와의 역호환을 위해 **`mobile` 키가 없으면
이 절도 없다**. `capabilities` 가 없는 기존 config 도 유효하다 — 소비자는 빈 목록으로 취급한다.

```json
{
  "agent_hints": {
    "platform": "mobile",
    "mobile": {
      "framework": ["android-native", "ios-native"],
      "build_system": ["gradle", "xcode"],
      "e2e_runner": "maestro",
      "capabilities": {
        "permissions": ["camera", "internet", "tracking"],
        "sdks": ["admob", "ump"],
        "languages": ["de", "en", "es", "fr", "ja", "ko", "zh-Hans"],
        "sources": ["./app/src/main/AndroidManifest.xml", "./ios/App/Info.plist"]
      }
    }
  }
}
```

`.reviewer/profile.yaml` 의 `mobile:` 절에도 같은 정보를 기록한다.

```yaml
mobile:
  framework: android-native | ios-native | react-native | flutter
  build_system: gradle | xcode | metro | flutter
  e2e_runner: maestro
  capabilities:
    permissions: [camera, internet, tracking]
    sdks: [admob, ump]
    languages: [de, en, es, fr, ja, ko, zh-Hans]
    # languages_base_unknown: true   # Android 기본 언어 미판정 시에만 기록
```

### config.json 기입 (배선)

감지만으로는 아무 일도 일어나지 않는다. 감지 결과를 `.claude/config.json` 에 실제로 쓰는 것이 이 절이다.

**실행 순서 제약 — 반드시 §13·§19 의 `agent_hints` 기입 뒤에 온다.** §19 는 `.agent_hints = $h` 로
객체를 통째로 덮어쓰므로, 그 앞에서 `capabilities` 를 쓰면 지워진다. 순서는 다음과 같다.

```
§15 모바일 감지 → §16 platform 결정 → §13·§19 agent_hints 기입 → §20 감지 → §20 기입 → §14 확인 UI
```

```bash
# >>> setup:mobile-capability-write >>>
# 선행: $PLATFORM(§16), MOBILE_PERMISSIONS·MOBILE_SDKS·MOBILE_CAPABILITY_SOURCES(§20 감지),
#       헬퍼 _config_update(§5). §13·§19 의 agent_hints 기입이 끝난 뒤에 실행해야 한다.
# 웹 전용(platform=web|cli)은 아무것도 쓰지 않는다 — mobile 키 부재 역호환(§17).
_cap_to_json() {   # $1=쉼표 목록 → JSON 배열 문자열 (빈 값이면 [])
  if [ -z "$1" ]; then printf '[]'; return 0; fi
  printf '%s' "$1" | tr ',' '\n' | grep -v '^$' | jq -R . | jq -cs .
}

if [ "${PLATFORM:-web}" = "mobile" ] || [ "${PLATFORM:-web}" = "both" ]; then
  if command -v jq >/dev/null 2>&1; then
    _CAP_JSON="$(jq -cn \
      --argjson p "$(_cap_to_json "${MOBILE_PERMISSIONS:-}")" \
      --argjson s "$(_cap_to_json "${MOBILE_SDKS:-}")" \
      --argjson l "$(_cap_to_json "${MOBILE_LANGUAGES:-}")" \
      --argjson f "$(_cap_to_json "${MOBILE_CAPABILITY_SOURCES:-}")" \
      --arg     u "${MOBILE_LANG_BASE_UNKNOWN:-false}" \
      '{permissions: $p, sdks: $s, languages: $l, sources: $f}
       + (if $u == "true" then {languages_base_unknown: true} else {} end)')"
    # 감지 0건이어도 기입한다 — sources 가 "읽었으나 선언이 없음"의 근거다(§20 감지 원칙).
    if _config_update '.agent_hints.mobile.capabilities = $c' --argjson c "$_CAP_JSON"; then
      echo "[setup] §20 capabilities 기입 완료 (permissions=${MOBILE_PERMISSIONS:-none} sdks=${MOBILE_SDKS:-none} languages=${MOBILE_LANGUAGES:-none})"
    else
      echo "[setup] §20 WARN: capabilities 기입 실패 — 위 오류를 확인하세요. 감지 결과는 반영되지 않았습니다."
    fi
  else
    echo "[setup] §20 WARN: jq 미설치 — capabilities 기입 생략(감지 결과는 위 출력에만 남는다)."
  fi
else
  echo "[setup] §20 platform=${PLATFORM:-web} — capabilities 기입 생략(웹 전용)"
fi
# <<< setup:mobile-capability-write <<<
```

앵커 문자열은 `aiops/tests/setup-mobile-capability-detect.test.sh` 의 추출 지점이므로 변경 금지.

`agent_hints` 보존(§19) 대상에 `agent_hints.mobile.capabilities` 를 추가한다 — `/aiops:setup` 재실행 시
감지가 실패하면(대상 레포가 일시적으로 비어 있는 등) 기존 값을 빈 목록으로 덮어쓰지 않는다.

### 확인 UI 확장 (§14)

`platform=mobile | both` 일 때 §14 출력에 두 줄을 추가한다. 감지 0건이면 `없음` 으로 표시하여
"감지를 안 했다" 와 구별한다.

```
=== /aiops:setup 감지 결과 ===
플랫폼:     mobile (android + ios)
프레임워크: android-native + ios-native
권한:       internet, tracking
SDK:        admob, ump
지원 언어:  de, en, es, fr, ja, ko, zh-Hans
```

### 소비자

| 소비자 | 쓰임 |
|---|---|
| 법적 문서 생성 (app-portal `content/<slug>/privacy.json`) | 선언된 권한·SDK 만 근거로 조항을 쓴다 |
| 릴리즈 노트 생성 (app-portal `content/<slug>/releases.json`) | `languages` 가 언어별 dict 의 키 집합을 정한다 |
| 광고 스킬 | `admob`·`ump` 유무로 신규 도입인지 기존 설정 수정인지 가른다 |
| `dev-mobile-*` 에이전트 | §17 우선순위 경로(`agent_hints` → `profile.yaml`)를 그대로 따른다 |

**`capabilities` 는 근거이지 허가가 아니다.** 감지되지 않았다는 이유로 권한을 추가하거나, 감지되었다는
이유로 조항을 자동 삽입하지 않는다 — 생성물은 사람 검토를 거친다.

## 주의사항

- 스캔은 현재 디렉터리(`.`) 기준으로 실행한다.
- `node_modules/`, `.git/`, `dist/`, `build/`, `.next/`, `__pycache__/` 경로는 제외한다.
- 동일 스택이 여러 번 감지되어도 중복 없이 1개만 포함한다.
- `.claude/config.json` 의 다른 필드(use_docker, e2e_*, docker 등)는 변경하지 않는다.
- `.reviewer/profile.yaml` 기존 파일은 [y/N] 명시 동의 없이는 덮어쓰지 않는다.
- 본 스킬은 install.sh 없이도 독립 실행 가능해야 한다 (config.json 신규 생성 지원).
