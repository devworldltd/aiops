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
| `pom.xml` 또는 `build.gradle` | `java` |
| `Gemfile` | `ruby` |
| `composer.json` | `php` |
| `*.csproj` 또는 `*.sln` | `dotnet` |

스캔 명령 예시:
```bash
find . -maxdepth 3 -name "package.json" ! -path "*/node_modules/*" -print -quit 2>/dev/null
find . -maxdepth 3 \( -name "requirements.txt" -o -name "pyproject.toml" \) ! -path "*/node_modules/*" -print -quit 2>/dev/null
find . -maxdepth 3 -name "go.mod" -print -quit 2>/dev/null
find . -maxdepth 3 -name "Cargo.toml" -print -quit 2>/dev/null
find . -maxdepth 3 \( -name "pom.xml" -o -name "build.gradle" \) -print -quit 2>/dev/null
find . -maxdepth 3 -name "Gemfile" ! -path "*/node_modules/*" -print -quit 2>/dev/null
find . -maxdepth 3 -name "composer.json" ! -path "*/node_modules/*" -print -quit 2>/dev/null
find . -maxdepth 3 \( -name "*.csproj" -o -name "*.sln" \) -print -quit 2>/dev/null
```

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

**jq 사용 가능 시:**
```bash
TECH_STACK='["node","hono","python","fastapi"]'
jq --argjson ts "$TECH_STACK" '.tech_stack = $ts' .claude/config.json > /tmp/config_tmp.json \
  && mv /tmp/config_tmp.json .claude/config.json
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

### 11. 매핑 테이블 (profile.yaml stack 필드)

§7~§8 결과를 다음 단일 식별자로 매핑한다.

| backend 감지 | profile.yaml stack.backend |
|-------------|---------------------------|
| `fastapi` + `sqlalchemy` | `fastapi-sqlalchemy` |
| `fastapi` + (없음 또는 sqlite) | `fastapi-sqlite` |
| `django` | `django` |
| `nestjs` | `nestjs` |
| `hono` + Hono-as-backend 휴리스틱(§8-1 R2/R3) | `hono-ts` |
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
jq --argjson hints "$AGENT_HINTS_JSON" '.agent_hints = $hints' .claude/config.json > /tmp/c.json \
  && mv /tmp/c.json .claude/config.json
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
  if find . -maxdepth 4 -name "AndroidManifest.xml" ! -path "*/node_modules/*" -print -quit 2>/dev/null | grep -q .; then
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

### 16. platform 결정 로직

웹 스택 감지 여부(§1~§3 결과)와 모바일 감지 여부(§15)를 조합하여 `platform` 값을 결정한다.

| 웹 감지 | 모바일 감지 | platform |
|--------|------------|----------|
| O | X | `web` (기본, 역호환) |
| X | O | `mobile` |
| O | O | `both` |
| X | X | `web` (안전 기본값) |

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

### 17. profile.yaml 작성 확장

§12 의 신규 생성 포맷을 다음과 같이 확장한다. `platform` 필드는 항상 작성하며, `mobile:` 절은 `platform=mobile | both` 일 때만 작성한다.

```yaml
# Reviewer 프로필 — /aiops:setup 이 자동 생성
# 스키마: claude-ai-devops/docs/review-profile-schema.md
# 모바일 스키마: claude-ai-devops/docs/mobile-overview.md

repo: OWNER/NAME                   # forge.sh repo (→ owner/repo)
forge: github | gitea              # 선택 — 생략 시 origin 리모트로 자동감지(forge.sh kind)
platform: web | mobile | both      # 신규 (기본 web, 역호환)
structure: single | monorepo | monorepo-submodules

stack:
  backend: fastapi-sqlalchemy | fastapi-sqlite | django | nestjs | none
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
| mobile | android-native 또는 ios-native | `mobile` |
| mobile | react-native 또는 flutter | `mobile` |
| both | (모두) | `full` |
| (감지 실패) | — | `minimal` |

```bash
case "$PLATFORM" in
  web)    AUTO_PROFILE="web" ;;
  mobile) AUTO_PROFILE="mobile" ;;
  both)   AUTO_PROFILE="full" ;;
  *)      AUTO_PROFILE="minimal" ;;
esac

# 기존 profile 보존 (사용자 수동 변경 우선)
CURRENT_PROFILE=$(jq -r '.profile // empty' .claude/config.json 2>/dev/null)
if [[ -z "$CURRENT_PROFILE" ]]; then
  jq --arg p "$AUTO_PROFILE" '.profile = $p' .claude/config.json > .claude/config.json.tmp \
    && mv .claude/config.json.tmp .claude/config.json
  echo "[/aiops:setup] profile=$AUTO_PROFILE 자동 등록 (#161)"
  echo "         변경하려면: install.sh --profile=<web|mobile|full|minimal|reviewer> 재실행"
else
  echo "[/aiops:setup] profile=$CURRENT_PROFILE 보존 (사용자 명시 또는 이전 설정)"
fi
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
  jq --argjson h "$NEW_HINTS" '.agent_hints = $h' .claude/config.json > tmp && mv tmp .claude/config.json
else
  # 감지 실패 — 기존 값 보존
  jq --argjson h "$PRESERVE_AGENT_HINTS" '.agent_hints = $h' .claude/config.json > tmp && mv tmp .claude/config.json
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

## 주의사항

- 스캔은 현재 디렉터리(`.`) 기준으로 실행한다.
- `node_modules/`, `.git/`, `dist/`, `build/`, `.next/`, `__pycache__/` 경로는 제외한다.
- 동일 스택이 여러 번 감지되어도 중복 없이 1개만 포함한다.
- `.claude/config.json` 의 다른 필드(use_docker, e2e_*, docker 등)는 변경하지 않는다.
- `.reviewer/profile.yaml` 기존 파일은 [y/N] 명시 동의 없이는 덮어쓰지 않는다.
- 본 스킬은 install.sh 없이도 독립 실행 가능해야 한다 (config.json 신규 생성 지원).
