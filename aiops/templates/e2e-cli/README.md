# CLI E2E 테스트 가이드 (node:test 내장 러너)

본 디렉토리는 `platform=cli` 프로젝트용 CLI E2E 골격입니다(이슈 #41).
`aiops:dev-e2e` 에이전트가 대상 레포의 `tests/e2e-cli/`에 배치합니다.
브라우저·DOM 전제(POM, storageState)가 없고, **명령 실행 → 종료 코드/stdout/stderr 계약**을
검증하는 구조입니다. 의존성 0(devDependencies `{}`) — `npm ci` 없이 바로 실행됩니다.

## 0. 실행 (설치 불필요)

```bash
node --version                 # 18 이상 필요 (node:test 내장 러너)
node runner/run-e2e.mjs --mode=full     # = npm run e2e
node runner/run-e2e.mjs --mode=smoke    # = npm run e2e:smoke
```

> `package.json` 은 dev-e2e 에이전트가 배치합니다. 기존 `package.json` 이 있는 레포에서는
> `scripts.e2e`/`scripts.e2e:smoke`만 **병합**되며(덮어쓰기 금지), 루트로 병합될 때는
> `cd tests/e2e-cli && node runner/run-e2e.mjs --mode=full` 형태로 작업 디렉토리를 보정합니다
> (시나리오 디렉토리 `full/`·`smoke/` 가 `runner/`와 같은 위치에 있어야 하므로).

## 1. 환경 변수 매트릭스

CLI 는 배포 대상이 없는 **local 단일 환경**입니다(기술 스펙 결정 (d)). `E2E_LOCAL_URL` 등
URL 계열 키는 사용하지 않습니다.

| 환경변수 | 설명 | 기본값 |
|----------|------|--------|
| `E2E_MODE` | 실행 모드 — `full` / `smoke` (`--mode=` 인자가 우선) | `full` |
| `E2E_CLI_BIN` | 실행할 CLI 진입점 경로 | 미지정 시 `package.json` 의 `bin` 첫 엔트리 |
| `E2E_FULL_PATHS` | full 모드 시나리오 디렉토리 재해석(콤마/공백 구분) | `full` |
| `E2E_SMOKE_PATHS` | smoke 모드 시나리오 디렉토리 재해석(콤마/공백 구분) | `smoke` |
| `E2E_TEST_WORKDIR` | 시나리오가 쓰기 작업을 수행할 임시 디렉토리 상위 경로 | OS 임시 디렉토리 |
| `E2E_PTY` | `1` 이면 `node-pty` 로드를 시도(선택 어댑터) | 미설정 |

> `.claude/config.json` 의 `e2e_full_paths`/`e2e_smoke_paths` 는 **재해석 재사용**됩니다 —
> 웹 프로젝트에서는 브라우저 E2E testDir 경로였지만, CLI 프로젝트에서는 이 CLI 테스트
> 디렉토리를 가리키는 값으로 씁니다. `e2e_local_url`/`e2e_dev_url`/`e2e_prod_url` 은 미사용입니다.

## 2. 러너 판정 불변식 (반드시 지켜야 하는 계약 — 이슈 #41 T13/T14/T15)

1. **실행된 테스트가 0건이면 PASS 가 아니라 환경 오류다.**
   시나리오 디렉토리에 `*.test.mjs` 파일이 하나도 없으면
   `E2E_ENV_ERROR=cli_scenario_dir_empty:<mode>` (exit 2) 로 종료한다. 이 경우 `node --test`
   자체를 spawn 하지 않는다.
2. **TAP 파싱 실패 시 PASS 로 폴백하지 않는다.** `node --test --test-reporter=tap` 출력에서
   `# tests`/`# pass`/`# fail`/`# skipped` 요약 라인 중 하나라도 파싱할 수 없으면
   `E2E_ENV_ERROR=cli_runner_tap_parse_failed` (exit 2) 로 처리한다.
3. **`passed >= 1` 이 아니면 PASS 가 아니다.** `failed==0` 이라도 `passed==0`(전부 SKIP —
   예: `node-pty` 미설치로 PTY 시나리오만 모여 있는 경우)이면 `E2E_RESULT=FAIL` (exit 1) 로
   판정한다. "실패 0건 = 통과" 가 아니다.
4. **`cli_entry_not_found` 와 "바이너리는 있으나 비정상 종료"는 다르다.**
   - `E2E_CLI_BIN`/`package.json bin` 모두 해석 실패 → spawn 자체가 불가능한 **환경 오류**.
     `node --test` 를 실행하기도 전에 `E2E_ENV_ERROR=cli_entry_not_found` (exit 2) 로 종료한다.
   - 진입점은 존재하지만 개별 시나리오가 기대한 종료 코드/출력과 다르면 → 그 **개별 테스트의
     실패**(TAP `not ok`)로 집계되어 최종 `E2E_RESULT=FAIL` (exit 1) 이 된다.

## 3. 종료 코드 / 마지막 줄 규약 (qa-e2e 와 동일 계약)

| 코드 | 의미 | 마지막 줄 |
|------|------|-----------|
| 0 | PASS (`failed==0 && passed>=1`) | `E2E_RESULT=PASS` |
| 1 | FAIL (`failed>=1` 이거나 전부 SKIP) | `E2E_RESULT=FAIL` |
| 0 | DRY_RUN (`--dry-run` — 테스트 미실행, 해석만 수행) | `E2E_RESULT=DRY_RUN` (게이트 통과 신호 아님, #49) |
| 2 | 환경 오류 | `E2E_ENV_ERROR=<reason>` |

`<reason>` 값: `cli_entry_not_found` · `node_runtime_missing` · `cli_runner_not_available` ·
`cli_runner_runtime:exit_<n>` · `cli_scenario_dir_empty:<mode>` · `cli_runner_tap_parse_failed` ·
`invalid_mode:<v>`.

마지막 줄 위에는 요약 줄이 출력된다:

```
── 요약: 총 N (Passed p / Failed f / Skipped s) · T s
```

## 4. 디렉토리 구조

```
tests/e2e-cli/ (대상 프로젝트 복사 위치)
├── package.json            # scripts.e2e / e2e:smoke, devDependencies {} (의존성 0)
├── runner/
│   └── run-e2e.mjs         # ★ 진입점 — node:test 실행 + TAP 집계 + E2E_RESULT 환산
├── lib/
│   ├── run-cli.mjs         # 명령 실행 래퍼 (비대화형 child_process, shell:false)
│   ├── assert-cli.mjs      # 어서션 헬퍼 (node:assert/strict 위에 얇게 얹음)
│   ├── test-data.mjs       # 고정 입력 · 임시 작업 디렉토리 팩토리
│   └── pty-adapter.mjs     # 선택 어댑터 — node-pty 미설치 시 해당 시나리오만 SKIP
├── full/                   # 전체 회귀 (7건)
│   ├── 01-help.test.mjs
│   ├── 02-args.test.mjs
│   ├── 03-happy-path.test.mjs
│   ├── 04-stdout-contract.test.mjs
│   ├── 05-exit-codes.test.mjs
│   ├── 06-stderr-errors.test.mjs
│   └── 07-edge-cases.test.mjs
└── smoke/                  # 최소 검증 (4건, read-only)
    ├── 01-version.test.mjs
    ├── 02-help.test.mjs
    ├── 03-dry-run.test.mjs
    └── 04-critical-readonly.test.mjs
```

**의도적으로 만들지 않는 것** (CLI 에 대응물 없음 — `templates/e2e/` 대비):
브라우저 설정 파일 · `global-setup.ts` · `pages/*`(POM = DOM 전제) · `fixtures/auth.ts`(storageState).
`agent/task.md.tmpl` 도 신설하지 않는다 — `.e2e-agent` 이미터는 기존 템플릿을 그대로 쓴다.

## 5. 작성 규칙 (대상 프로젝트에서 채워야 할 부분)

각 `*.test.mjs` 파일의 `// TODO(cli)` 주석을 실제 서브커맨드/플래그/기대 출력으로 교체한다.

1. **CLI 진입점**: `.env.test` 의 `E2E_CLI_BIN` 또는 `package.json` 의 `bin` 엔트리를 실제 값으로.
2. **대표 명령**: `full/03-happy-path.test.mjs` 의 placeholder 명령을 프로젝트의 대표 서브커맨드로.
3. **종료 코드 표**: `full/05-exit-codes.test.mjs` 를 프로젝트의 실제 종료 코드 규약으로.
4. **PTY 시나리오**: 대화형 프롬프트가 있는 CLI 라면 `lib/pty-adapter.mjs` 를 이용해
   `E2E_PTY=1` + `node-pty` 설치 시에만 동작하는 시나리오를 추가한다(옵트인, 미설치 시 SKIP).

## 6. PTY(대화형) 옵션

- 기본은 **비대화형 `child_process` 모드**다(이슈 #41 결정 (b)) — 의존성 0 원칙 유지.
- 대화형 프롬프트 검증이 필요하면 `lib/pty-adapter.mjs::hasPty()`/`loadPty()` 를 통해
  `node-pty` 를 선택적으로 로드한다. `node-pty` 는 네이티브 빌드 의존성이라 CI 환경별로
  설치가 실패할 수 있으므로, 미설치 시 **해당 시나리오만 SKIP** 되고 전체 FAIL 로 전이되지
  않는다(단, §2-3 불변식에 따라 전부 SKIP 이면 `E2E_RESULT=FAIL` 이 된다 — PTY 시나리오만으로
  구성된 스위트를 만들지 않는다).

## 7. 디버깅 팁

- 단일 파일만 실행: `node --test --test-reporter=tap full/01-help.test.mjs`
- 상세 로그: `E2E_CLI_BIN=./dist/cli.js node runner/run-e2e.mjs --mode=full`
- 해석 결과만 확인(부작용 없음): `node runner/run-e2e.mjs --mode=full --dry-run`
- 시나리오 디렉토리 재지정: `node runner/run-e2e.mjs --dirs=full,smoke`
