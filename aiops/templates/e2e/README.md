# E2E 테스트 가이드 (Playwright)

본 디렉토리는 claude-ai-devops `install.sh`가 복사한 Playwright E2E 골격입니다.
환경(local / dev / prod) 분기, storageState 1회 인증, POM 패턴, full/smoke 분리를 기본 전제로 합니다.

## 0. 설치 (최초 1회)

```bash
npm ci                       # 또는 npm install — package.json 의존성 설치
npx playwright install chromium   # 브라우저 바이너리 (npm run test:install 과 동일)
npm test                     # = npx playwright test (E2E_ENV 로 환경 분기)
```

> `package.json` 은 dev-e2e 에이전트가 배치합니다. 기존 `package.json` 이 있는 레포에서는
> `@playwright/test`·`@types/node`·`typescript` devDependency 와 `test`/`test:smoke` 스크립트만
> **병합**되며(덮어쓰기 금지), `package-lock.json` 은 대상 레포에서 `npm install` 로 생성됩니다.

## 1. 환경 변수 매트릭스

| 환경변수 | 설명 | 기본값 |
|----------|------|--------|
| `E2E_ENV` | 실행 환경 — `local` / `dev` / `prod` | `local` |
| `E2E_MODE` | 실행 모드 — `full` / `smoke` (옵션, `--grep @smoke`로도 가능) | (미지정) |
| `E2E_LOCAL_URL` | local baseURL | `http://localhost:8787` |
| `E2E_DEV_URL` | dev baseURL | `.claude/config.json` 의 `e2e_dev_url` |
| `E2E_PROD_URL` | prod baseURL | `.claude/config.json` 의 `e2e_prod_url` |
| `E2E_TEST_USER` | 고정 테스트 계정 이메일 | `e2e@example.com` |
| `E2E_TEST_PASS` | 고정 테스트 계정 비밀번호 | — (필수) |
| `BLAST_RADIUS_GUARD` | prod 안전 가드 — `1`이면 `e2e-prod-` prefix 없는 데이터 생성 시 즉시 실패 | `1` |

> 환경변수 `E2E_USER_EMAIL`, `E2E_USER_PASSWORD` 도 하위 호환을 위해 인식합니다.

## 2. 실행 명령 매트릭스

| 목적 | 명령 |
|------|------|
| local 전체 회귀 (full + smoke) | `E2E_ENV=local npx playwright test` |
| dev 전체 회귀 (CI, PR 머지 후) | `E2E_ENV=dev npx playwright test --reporter=list` |
| prod smoke 게이트 (배포 후) | `E2E_ENV=prod npx playwright test --grep @smoke` |
| 단일 파일 디버그 | `npx playwright test --headed --debug full/01-login.spec.ts` |
| HTML 리포트 열기 | `npx playwright show-report` |
| 트레이스 뷰어 | `npx playwright show-trace test-results/.../trace.zip` |

## 3. 디렉토리 구조

```
tests/e2e/ (또는 본 ${CLAUDE_PLUGIN_ROOT}/templates/e2e/ — 대상 프로젝트 복사 위치)
├── playwright.config.ts   # 환경 분기 baseURL / workers / retries
├── global-setup.ts        # storageState 1회 인증 → .auth/user.json
├── fixtures/
│   ├── auth.ts            # storageState 로드 fixture
│   ├── api-client.ts      # REST 헬퍼 + tearDown 유틸
│   └── test-data.ts       # TEST_PREFIX + makeItem() 팩토리
├── pages/                 # Page Object Model
│   ├── LoginPage.ts
│   ├── HomePage.ts
│   └── index.ts           # barrel export
├── full/                  # local/dev 전체 회귀 (7건)
│   ├── 01-login.spec.ts
│   ├── 02-navigation.spec.ts
│   ├── 03-crud-create.spec.ts
│   ├── 04-crud-read.spec.ts
│   ├── 05-crud-update.spec.ts
│   ├── 06-crud-delete.spec.ts
│   └── 07-error-handling.spec.ts
└── smoke/                 # prod 최소 검증 (4건, @smoke 태그)
    ├── 01-health.spec.ts
    ├── 02-homepage.spec.ts
    ├── 03-auth-flow.spec.ts
    └── 04-critical-crud.spec.ts
```

## 4. 작성 규칙 (대상 프로젝트에서 채워야 할 부분)

1. **셀렉터**: `pages/*.ts` 내 `TODO(selector)` 주석을 실제 라벨/role/testid 로 교체.
2. **API 엔드포인트**: `fixtures/api-client.ts` 의 `/api/v1/items` 경로를 도메인 엔티티에 맞게 교체.
3. **도메인 시나리오**: `full/03~06-crud-*.spec.ts` 의 `// TODO(domain)` 블록에 실제 흐름 채움.
4. **storageState 토큰 주입**: `global-setup.ts` 하단 `// TODO(token-injection)` 블록을 프로젝트 인증 방식(쿠키/localStorage)에 맞게 작성.

## 5. prod 안전 패턴 (Q3-C)

- `smoke/04-critical-crud.spec.ts` 는 항상 `TEST_PREFIX="e2e-prod-"` 로 데이터 생성 후 `afterAll`에서 전부 삭제합니다.
- `BLAST_RADIUS_GUARD=1` (기본) 이면 prefix 없는 prod 데이터 생성 시 throw 합니다.
- 실패해도 tearDown 은 항상 수행됩니다.

## 6. 디버깅 팁

- 인증 캐시 초기화: `rm -rf .auth/`
- 단일 테스트만: `--grep "로그인 성공"`
- 헤드풀 + 디버거: `--headed --debug`
- 리트라이 끄기 (디버깅 시): `--retries=0`
