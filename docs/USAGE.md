# aiops 사용법 — 의도 · 정책 · 결과물

이 문서는 **무엇을 위해 만들었고(의도)**, **무엇을 강제하며(정책)**, **무엇이 남는지(결과물)** 를 적는다.
개별 스킬의 절차는 각 `SKILL.md` 가 정본이고, 여기서는 **전체가 어떻게 맞물리는지**를 설명한다.

- 설치·업그레이드·릴리스: [`../README.md`](../README.md)
- 스킬 35 · 에이전트 26 · 스크립트 2 · 라이선스 Apache-2.0

---

## 1. 의도 — 왜 이렇게 생겼나

**한 사람이 기획부터 배포 검증까지 끌고 가되, 각 단계의 판단 근거가 남게 한다.**

혼자 또는 소수로 여러 서비스를 운영하면 두 가지가 반복해서 무너진다 —
① 기획·스펙 없이 코드부터 쓰다 나중에 왜 그렇게 했는지 아무도 모르고,
② 테스트·배포 검증이 "그린이니까 됐다" 로 끝나 **조용한 실패**가 프로덕션까지 간다.

그래서 이 도구는 두 가지에 집착한다:

| 집착 | 구현 |
|---|---|
| **모든 산출물에 근거를 남긴다** | 각 STEP 이 이슈 댓글에 마커 헤더로 기록. 다음 STEP 은 그 댓글을 읽어 이어간다 |
| **그린이 곧 검증됨이 아니다** | 게이트마다 **수치·판정 신호**를 요구하고, 스킵은 사유와 함께 명시적으로 기록 |

에이전트를 여러 개로 나눈 이유도 같다. 한 컨텍스트에서 기획·구현·QA·리뷰를 다 하면
**자기 코드를 자기가 검증**하게 된다. 역할을 분리해 QA·리뷰가 구현 보고를 **재실측**하게 만든다.

---

## 2. 정책 — 시스템이 강제하는 것

### P1. 네임스페이스 필수

플러그인 스킬·에이전트는 **`aiops:` 네임스페이스로만 해석된다.** bare 이름(`planning`)은
`Agent type not found` 로 죽는다. 그래서 모든 상호참조가 `aiops:planning`·`/aiops:devflow` 형태다.

⚠️ 맨 `/focus` 는 Claude Code **내장 화면 토글**과 이름이 겹쳐 스킬이 실행되지 않는데
`Focus view enabled` 만 뜨고 조용히 끝난다. **`/aiops:focus` 로 부른다.**

### P2. 산출물은 이슈 댓글이 1순위, `context/` 는 폴백

이슈 스레드가 정본이다(팀이 보고, 링크가 남고, 검색된다). forge 장애 시에만 `context/*.md` 에
쓰고 복구 후 동기화한다. 배치 모드에서는 `context/issue-<N>/` 로 이슈별 격리한다.

### P3. 마커 헤더는 인터페이스다 — 함부로 바꾸지 않는다

후속 스킬이 이 헤더를 **grep 으로** 찾아 진행 가능 여부를 판단한다. 헤더를 바꾸면 조용히 끊긴다.

| 마커 | 쓰는 STEP | 읽는 쪽 |
|---|---|---|
| `## 📋 브리프` | devflow 1 | planning |
| `## 📝 PRD` · `## 🖼️ 와이어프레임` | 2 | dev, dev-e2e |
| `## ⚙️ 기술 스펙` | 3 | dev-e2e, 구현 에이전트 |
| `## 🧪 E2E 시나리오` · `## 🧪 E2E 코드 작성 완료` | 4 | 구현 에이전트 |
| `## 🎨 컴포넌트 스펙` · `## 🔧 백엔드 구현 완료` · `## 💻 프론트엔드 구현 완료` | 5 | dev-devops, QA |
| `## 🚢 배포 완료` | 6 | QA |
| `## ✅ Unit QA Sign-off` / `## ❌ Unit QA FAIL` | 7 | 게이트 #1 |
| `## 🌐 로컬 E2E 결과 — full` (본문 `E2E_RESULT=PASS\|FAIL\|SKIPPED`) | 8 | 게이트 #2, merge-pr, merge-main |
| `## ℹ️ E2E dry-run (검증 아님)` (본문 `E2E_RESULT=DRY_RUN`, `--issue` 지정 시에만 등록) | — | 게이트 대상 외 — PASS/FAIL/SKIPPED 와 달리 통과·차단 어느 목록에도 없다 (#49) |
| `## 🚀 PR 생성 완료` | 9 | review-pr |
| `## 🔍 PR 리뷰 완료` | 10 | merge-pr |
| `## 🌐 Dev E2E 결과 — full` | merge-pr | merge-main |
| `## 🚀 main 머지 완료` · `## 🚀 Prod 배포 검증` | merge-main, deploy-prod | — |
| `## ⚠️ Prod 자동 롤백 완료` · `## ⚠️ … 환경 오류` | deploy-prod, e2e-* | 사람 |
| `## ℹ️ 헬스체크 스킵` (본문 `healthcheck_skipped=platform_cli`) | merge-pr §13, verify-deploy §2, deploy-prod §4 | merge-main(E2E 게이트 면제), 사람 |

### P4. 게이트 — 통과 조건이 수치다

| 게이트 | 조건 | 실패 시 |
|---|---|---|
| **#1 Unit QA** (STEP 7) | 각 레인 `FAILED=0` | 구현 에이전트 재호출 → 재배포 → 재QA |
| **#2 로컬 E2E** (STEP 8) | `E2E_RESULT=PASS` 또는 `SKIPPED` | 원인 영역 판정 → 재구현 루프 **최대 3회** |
| **Dev E2E** (merge-pr) | `deployed_sha` 일치 후 E2E PASS | 배포 검증 실패 마커 + 중단 |
| **Prod smoke** (deploy-prod) | smoke PASS | **자동 롤백**(Q4-B) + 마커 |

`SKIPPED` 를 PASS 동등으로 취급하는 것은 의도다 — 단, **사유를 본문에 반드시 남긴다.**
조용한 스킵은 금지다.

### P5. forge 중립 — `gh` 하드 의존 없음

이슈·PR·리뷰·CI 대기는 **`git origin` 리모트로 GitHub↔Gitea 를 자동 감지**하는 헬퍼가 처리한다.
GitHub 이면 `gh` CLI, 그 외(Gitea)면 REST API(`/api/v1`). Cloudflare Access 뒤의 Gitea 도
3단 인증 폴백으로 지원한다.

### P6. 버전·태그·ref 는 함께 올린다

캐시 경로가 `plugin.json` 의 `version` 에서 나온다(`~/.claude/plugins/cache/aiops/aiops/<version>/`).
태그·version·소비 레포의 `ref` 중 하나만 빠지면 **옛 내용이 남으면서 성공처럼 보인다.**
`tools/release.sh` 가 이 일치를 강제한다. 자세히는 README 릴리스 절.

### P7. 워크트리 규약

작업 대상은 **브랜치·디렉토리명이 진실원천**이다. 모노레포는 앱 축, 단일 레포는 이슈 축.
`/aiops:focus` 는 기존 디렉토리를 재사용하기 전에 **브랜치가 규약과 맞는지 확인**한다 —
누군가 그 안에서 `git checkout` 했다면 모르고 `dev`·`main` 에 직접 커밋하게 되기 때문이다.

### P8. 산출물 언어는 한국어

PRD·기술 스펙·리뷰·커밋 메시지 전부 한국어다.

---

## 3. 스킬 35개 — 무엇을 부르면 무엇이 남나

호출은 `/aiops:<이름>`. **3개(`backend`·`frontend`·`wireframe`)는 frontmatter 에
`disable-model-invocation: true`** 가 있어 모델이 자동 선택하지 않고 사람이 슬래시로만 부른다
(아래 ✋ 표시). 나머지 32개는 모델이 상황에 맞게 스스로 고를 수 있다.

> 확인법: `grep -l '^disable-model-invocation' aiops/skills/*/SKILL.md` — **frontmatter(파일 앞
> `---` 구간) 안에 있을 때만 효력이 있다.** 본문에 있으면 아무 일도 하지 않으며, 산출물 템플릿
> 안이라면 생성 문서에 그 줄이 그대로 박힌다(v1.3.3 에서 `brief`·`prd`·`tech-spec`·`wireframe`
> 4곳을 그렇게 고쳤다).

### 3-1. 오케스트레이터 (통째로 굴리는 것)

| 스킬 | 언제 | 결과물 |
|---|---|---|
| `devflow #N` | 기능 하나를 기획→배포검증까지 | STEP 0~10 마커 전체 + feature 브랜치 + PR + 리뷰 |
| `devplanning #N [#M …]` | 개발 직전까지만(STEP 0~4). 복수 이슈 병렬 | 브리프·PRD·와이어프레임·기술스펙·E2E 골격 |
| `chainflow` | 여러 이슈를 **순차** 자동 처리 | 이슈별 devflow → merge-pr → (옵션) merge-main |
| `mobileflow #N` | 모바일 앱(Android/iOS/RN/Flutter) | devflow 10 STEP 의 모바일판 |
| `bugflow` | 버그 리포트 대응 | 재현 → 원인 → 수정 → 검증 → PR |

### 3-2. 단계별 (부분만 다시 돌릴 때)

| 스킬 | 결과물 |
|---|---|
| `brief` | `context/00_brief.md` 또는 `## 📋 브리프` |
| `prd` | `context/01_prd.md` / `## 📝 PRD` |
| `wireframe` ✋ | `context/02_wireframe.md` / `## 🖼️ 와이어프레임` |
| `tech-spec` | `context/03_tech_spec.md` / `## ⚙️ 기술 스펙` (`## E2E 검증 시나리오` 절 의무) |
| `backend` ✋ · `frontend` ✋ | 구현 + 단위 테스트, `## 🔧`/`## 💻` 마커 |
| `review-pr <PR>` | PR 리뷰(APPROVE/REQUEST_CHANGES/COMMENT) + P2 이슈 자동 등록 |
| `update-docs` | 변경 코드 분석 → 관련 문서 갱신 |

### 3-3. QA

| 스킬 | 실행 | Sign-off |
|---|---|---|
| `qa-check` | Backend·Frontend·Admin **병렬** | 전체 판정 |
| `qa-backend` · `qa-frontend` · `qa-admin` | 각 레인 단독 | `FAILED=0` |
| `qa-mobile` | `agent_hints.mobile.framework` 로 4방향 라우팅 | 프레임워크별 |

### 3-4. E2E

| 스킬 | 성격 |
|---|---|
| `run-e2e` | **사용자 친화 진입점** — 브랜치/머지 상태로 환경 자동 선택 후 위임 |
| `e2e-test --env=<local\|dev\|prod> --mode=<full\|smoke>` | 매트릭스 직접 지정 |
| `run-mobile-e2e` | 위의 모바일판(플랫폼 자동) |
| `e2e-onboard` | 레포를 e2e-runner 서비스에 등록(config·.env·웹훅 스니펫) |

출력 계약: 마지막 줄이 `E2E_RESULT=PASS|FAIL|DRY_RUN` 또는 `E2E_ENV_ERROR=<사유>`.
종료 코드 `0`/`1`/`2`(환경 오류). `DRY_RUN` 은 `--dry-run` 전용이며 게이트 통과 신호가 아니다 — 테스트를 한 건도 실행하지 않았다는 뜻이고, 종료 코드는 오류가 아니므로 `0` 그대로다(#49).

`agent_hints.platform=cli` (또는 `.reviewer/profile.yaml` 폴백) 인 프로젝트는 `e2e-test` 가 Playwright 대신 `qa-e2e-cli` 로 라우팅한다(#41). CLI 는 배포 대상이 없는 **local 단일 환경**이라 `--env=dev|prod` 요청은 거부되지 않고 local 로 강등된다. `qa-e2e.md` 자체는 바이트 불변이며, CLI 전용 게이트·`<reason>` 은 `qa-e2e-cli` 문서를 따른다.

### 3-5. 머지·배포

| 스킬 | 하는 일 |
|---|---|
| `merge-pr <N>` | issue→dev 머지 + CI 대기 + `deployed_sha` 확인 + **dev E2E 자동 실행** |
| `merge-main` | dev 안정성 게이트(직전 이슈의 Dev E2E PASS 마커) 확인 → **버전 올리기(§7.0, 있는 경우)** → dev→main PR·머지 |
| `deploy-prod` | main Actions 대기 + prod 헬스체크 + smoke E2E + **자동 롤백** |
| `verify-deploy --env=dev\|prod` | 위 검증 흐름만 단독 실행 |
| `promote` | **deprecated** — `merge-main` 권장 |

### 3-6. 작업 환경·문서

| 스킬 | 하는 일 |
|---|---|
| `setup` | 스택·프레임워크·ORM·CI 감지 → `.claude/config.json`(`agent_hints`) + `.reviewer/profile.yaml` 생성. **설치 후 1회** |
| `focus <대상> [이슈]` | 대상 전용 워크트리 진입(없으면 확인 후 생성). `--new` 는 신규 앱 |
| `unfocus` | 워크트리 진출(기본 `keep`, 요청 시 `remove`) |
| `explain-app <앱>` | 비개발자용 구조 해설 → `docs/apps/<앱>.md` 정본 + (선택) Artifact HTML |
| `jira-to-issue KEY-1 …` | Jira 티켓 → 이슈 변환 등록 |
| `kms <search\|get\|register\|health>` | DevWorld KMS 로 credential 검색·조회(reveal)·등록 — 값은 환경변수/메모리에서만, 소스·`.env`·로그 기록 금지 |
| `ai-chat <register\|status\|connect\|cycle>` | ai-chat 협업 허브 가입(레포 분석 → 토큰 생성 → KMS 보관 → 신청 → 심사) + 승인 후 작업 사이클 확인. 토큰 비노출·승인 전 호출 금지 |

---

## 4. 에이전트 26개 — 누가 무엇을 판단하나

스킬이 절차라면 에이전트는 **역할**이다. 직접 부르기보다 스킬이 위임한다.

| 묶음 | 에이전트 | 역할 |
|---|---|---|
| 총괄 | `orchestrator` | 단계 조율·위임(직접 구현 금지) |
| 기획 | `planning` · `marketing` | PRD·와이어프레임 / GTM·콘텐츠 |
| 설계 | `dev` | 기술 스펙 총괄 |
| 구현 | `dev-backend` · `dev-frontend` · `dev-designer` · `dev-devops` · `dev-e2e` · `dev-pr` | 스택 적응 구현 · 배포 · E2E 골격 · PR |
| 모바일 | `dev-mobile-android` · `dev-mobile-ios` · `dev-mobile-rn` · `dev-mobile-flutter` | 프레임워크별 구현 |
| QA | `qa-backend` · `qa-frontend` · `qa-admin` · `qa-e2e` · `qa-e2e-cli` | 재실측 + Sign-off 판정 (CLI 플랫폼은 `qa-e2e-cli`) |
| 모바일 QA | `qa-mobile-android` · `qa-mobile-ios` · `qa-mobile-e2e` | 단위·E2E |
| 버그 | `bug-analyst` · `bug-verifier` | 재현·원인 / 수정 전후 증거 검증 |
| 릴리스 | `release-manager` · `doc-updater` | 머지·정리 / 문서 자동 갱신 |

**스택 적응**: `dev-backend`·`dev-frontend`·`dev-devops`·`qa-backend`·`qa-frontend` 5개는
`agent_hints` → `tech_stack` → `.reviewer/profile.yaml` 순으로 읽어 프레임워크를 결정한다.

---

## 5. 도구 3개 — 계약이 있는 스크립트

`${CLAUDE_PLUGIN_ROOT}/scripts/` 에 있다. **반드시 실행**한다(소싱 금지 — 호출 셸이 zsh 여도
shebang bash 로 돌아야 `BASH_REMATCH`·배열이 동작한다).

### `forge.sh` — 이슈·PR·리뷰 (forge 중립)

```sh
forge.sh repo | kind
forge.sh issue-view <n> | issue-comments <n> | issue-comment <n> <body|@file>
forge.sh issue-create <title> <body|@file> [--label a,b] [--milestone id]
forge.sh issue-list | issue-search <q> | issue-close <n> [comment]
forge.sh pr-create <head> <base> <title> <body|@file>   # → PR_NUMBER=.. PR_URL=..
forge.sh pr-view <n> | pr-diff <n> [--name-only] | pr-url <n>
forge.sh pr-review <n> <APPROVE|REQUEST_CHANGES|COMMENT> <body|@file>
forge.sh pr-merge <n> [--delete-branch]
```

- **본문에 `@` 를 붙이면 파일**을 읽는다. `@` 없이 파일 경로를 넘기면 **exit 3 으로 거부**한다
  (경로 문자열이 본문으로 등록되던 사고 방지). 없는 `@파일`·빈 본문도 거부한다.
- Gitea 는 자기 PR self-approve 를 거부한다. `forge.sh pr-review <n> APPROVE` 는 3단 우선순위로 동작한다: ① `REVIEWER_TOKEN` 환경변수 있으면 즉시 그 계정으로 APPROVE ② 없고 `KMS_TOKEN` 있으면 KMS 에서 `REVIEWER_TOKEN` secret 을 조회해 APPROVE(≤15초) ③ 둘 다 없거나 실패하면 기존처럼 자동 COMMENT 강등(경고 출력). 관련 환경변수 이름(값은 여기 기재하지 않음):

  | 변수 | 용도 | 기본값 |
  |---|---|---|
  | `REVIEWER_TOKEN` | 리뷰어 계정 토큰 직접 지정 | — |
  | `KMS_TOKEN` | KMS 앱 토큰(② 경로 활성화 조건) | — |
  | `REVIEWER_ENV` | KMS 조회 environment | `local` |
  | `REVIEWER_SECRET_SERVICE` | KMS 조회 service | `aiops` |
  | `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET` | KMS Cloudflare Access 자격(없으면 `~/.kms/cf-access-env.sh` → `cloudflared` 순 자동 폴백) | — |
- Gitea 인증 3단: `git credential fill` 토큰 → gitconfig `extraheader` 서비스토큰 →
  `cloudflared access token`.

### `actions-wait.sh` — CI 완료 대기

```sh
actions-wait.sh --branch <branch> [--workflow <file.yml>] [--sha <40hex>] [--timeout <sec>]
# 마지막 줄: RUN_ID=<id> RUN_URL=<url> CONCLUSION=<success|failure|cancelled|timeout|not_found>
# 종료 코드: 0 성공 / 1 실패·취소 / 124 타임아웃 / 2 미발견·환경오류
```

⚠️ Gitea 는 **취소(cancelled)를 커밋 상태 API 에서 failure 로 보고**한다. 실패 판정 전에
job conclusion 을 확인할 것(동시 세션이 같은 브랜치에 푸시하면 빈번하다).

### `tools/release.sh` — 배포 태그 (메인테이너)

```sh
DRY=1 tools/release.sh v1.4.0        # 계획만
tools/release.sh v1.4.0              # vX.Y.Z 생성 + latest 이동 + 푸시
tools/release.sh --sync-latest v1.3.2
```

검사: main 체크아웃 · 클린 트리 · `origin/main` 동기화 · **version↔태그 일치** · 태그 중복 거부 ·
`LICENSE` 존재.

---

## 6. 설정 표면 — 무엇을 어디서 바꾸나

### `.claude/config.json` (`/aiops:setup` 이 생성)

| 키 | 용도 |
|---|---|
| `agent_hints` | `platform` · `backend{language,framework,orm,test_runner}` · `frontend{…}` · `mobile{framework}` · `structure` · `ci` · `db` · `build_system` |
| `tech_stack` | 감지된 스택 목록(에이전트 폴백) |
| `use_docker` · `docker.*` | QA·배포 스킬의 Docker 경로 |
| `dev_url` · `prod_url` (옛 이름 `cf_dev_url`·`cf_prod_url` 호환) | 환경별 기준 URL — **배포 대상 무관**. 헬스체크는 `<url><e2e_healthcheck_path>` 의 `deployed_sha` 를 본다. `agent_hints.platform=cli` 이고 두 키가 모두 비면 헬스체크는 자동 스킵(#42) |
| `use_cloudflare_workers` | CF 전용 단계 on/off. **미지정 시 `agent_hints.*.deploy_target` 에서 파생**하고, 그것도 없으면 `false`(하지 않는 쪽이 안전) |
| `deploy_workflow` · `project_root` | Actions 파일명(분리 레포에서는 **dev 전용** 의미) · 작업 루트 |
| `deploy_workflow_prod` | prod(main) 배포 Actions 파일명. 미설정 시 `deploy_workflow` 로 폴백 — dev/prod 워크플로우가 분리된 레포에서만 필요 |
| `github_actions_workflow` | (레거시 구키) 위 두 키가 모두 없을 때의 폴백 |
| `auto_merge_to_dev` | review-pr APPROVE 시 자동 dev 머지 |
| `release_command` | merge-main §7.0 이 승격 직전에 돌릴 릴리스 명령. 미설정 시 `package.json` 의 `scripts.release` 를 쓰고, 그것도 없으면 **아무 일도 하지 않는다** |
| `e2e_test_enabled` · `e2e_devflow_step8_enabled` | E2E 활성(기본 false) |
| `e2e_local_url` · `e2e_dev_url` · `e2e_prod_url` · `e2e_healthcheck_path` | 대상 URL |
| `e2e_full_paths` · `e2e_smoke_paths` · `e2e_deploy_wait_sec` | 실행 범위·대기 |
| `e2e_run_on_merge_pr` · `e2e_required_for_merge_main` | 자동 실행·게이트 강제 |
| `e2e_runner_host` | e2e-runner 원격 |

#### 배포 워크플로우 키 우선순위 (env 별)

| 실행 경로 | 브랜치 | 키 해석 순서 (앞선 키가 비어 있지 않으면 즉시 채택) |
|---|---|---|
| `/aiops:merge-pr` | dev | `deploy_workflow` → `github_actions_workflow` → `deploy-cf.yml` |
| `/aiops:verify-deploy --env=dev` | dev | `deploy_workflow` → `github_actions_workflow` → `deploy-cf.yml` |
| `/aiops:verify-deploy --env=prod` | main | **`deploy_workflow_prod`** → `deploy_workflow` → `github_actions_workflow` → `deploy-cf.yml` |
| `/aiops:deploy-prod` | main | **`deploy_workflow_prod`** → `deploy_workflow` → `github_actions_workflow` → `deploy-cf.yml` |

- `null` 과 빈 문자열 `""` 은 **미설정으로 취급**하고 다음 키로 내려간다.
- 실제 적용된 키는 실행 로그의 `source=<키이름>` (미설정 전부일 때 `default`) 으로 확인한다.
- 단일 워크플로우 레포는 `deploy_workflow_prod` 를 **넣지 않는 것이 정상**이다.

### `.reviewer/profile.yaml` (`/aiops:setup` 이 생성)

`repo` · `platform`(`web | mobile | both | cli`) · `structure` · `paths{backend,frontend,admin}` ·
`stack{backend,frontend,admin}` · `prd_source` · `max_diff_loc`. `review-pr` 이 이 프로필로 체크리스트를 고른다.
`platform: cli` 는 터미널 CLI 프로젝트(npm `bin` 엔트리, 웹/모바일 미감지)를 뜻하며 `profile` 은 표준 `web` 세트를 그대로 쓴다 (#16).

### `git config aiops.*` (워크트리·문서 스킬)

| 키 | 기본값 | 용도 |
|---|---|---|
| `aiops.worktreeBase` | `origin/dev` 있으면 그것, 없으면 원격 기본 브랜치 | 분기 base |
| `aiops.worktreeRoots` | `apps services` | 모노레포 앱 후보 루트 |
| `aiops.explainDocsDir` | `docs/apps` | explain-app 정본 경로 |

---

### 버전 올리기 연동 (merge-main §7.0)

`main` 은 대개 브랜치 보호가 걸려 **CI 가 버전 커밋을 되밀 수 없다.** 그래서
`/aiops:merge-main` 은 dev → main PR 을 만들기 **직전**에 릴리스 명령을 돌린다.

| 설정 | 값 |
|------|-----|
| `.claude/config.json` 의 `release_command` | 예: `"npm run release"` · `"make release"` |
| (미설정 시) `package.json` 의 `scripts.release` | 있으면 `npm run release` 로 자동 인식 |
| 둘 다 없으면 | **아무 일도 하지 않는다** (역호환) |

동작:

1. 릴리스 명령 실행 → `package.json`·`CHANGELOG.md` 등이 갱신됨
2. 바뀐 것이 없으면 그대로 승격 (문서·잡무만 있는 승격이 여기 해당 — **오류가 아니다**)
3. 바뀌었으면 `chore/release-vX.Y.Z` 브랜치 → **dev PR 생성·머지** → dev 재최신화 후 승격 계속

> dev 에 직접 push 하지 않는다 — dev 도 보호돼 있는 경우가 많고, 버전 상승은
> 리뷰 가능한 형태로 남는 편이 낫다.
>
> `--dry-run` 에서는 실행하지 않고 **무엇을 돌릴지만** 출력한다.

## 7. 처음 시작하는 흐름

```sh
# 1. 설치 (README 참조)
claude plugin marketplace add https://…/aiops-v1.git#latest
claude plugin install aiops@aiops

# 2. 프로젝트 감지 — 최초 1회
/aiops:setup

# 3. 작업 대상으로 진입
/aiops:focus <앱> 123

# 4. 굴린다
/aiops:devflow #123

# 5. 머지·배포
/aiops:merge-pr 123
/aiops:merge-main
/aiops:deploy-prod
```

부분만 필요하면 3-2·3-3·3-4 의 단계 스킬을 직접 부른다.

---

## 8. 알려진 한계 (정직하게)

| 한계 | 영향 | 추적 |
|---|---|---|
| ~~스킬 본문 스택 하드코딩~~ | **v1.5.0 에서 해소** — `devflow`(STEP 3·4·6·7)·`qa-check`·`tech-spec`·`bugflow`·`backend`·`bug-verifier` 가 `agent_hints` 를 읽어 분기하고, 없는 레인·단계는 **"해당 없음: 사유" 를 산출물에 남기고 스킵**한다 | [#7](../../issues/7) |
| 에이전트 본문의 FastAPI 절은 **어댑터의 한 분기**로 남아 있다 | 의도된 구조다 — `dev-backend`·`qa-backend`·`dev-devops` 등은 상단 어댑터 표에서 감지값으로 분기하고, FastAPI 가이드는 `fastapi-sqlalchemy` 분기의 본문이다. 다른 스택이면 그 분기를 타지 않는다 | — |
| **정본 remote 가 Cloudflare Access 뒤** | 외부 사용자는 `marketplace add` 단계에서 막힌다 | [#6](../../issues/6) |
| STEP 4 가 E2E 배선 없는 프로젝트에 Playwright 골격을 만들 수 있다 | 리뷰 범위 오염 — 필요 없으면 범위 제한을 지시할 것 | #7 |
| `#latest` 는 자동으로 당겨오지 않는다 | `marketplace update` + `install` 이 필요 | README |
| 산출물이 한국어 | 한국어권 밖에서는 장벽 | — |

---

## 9. 이 문서를 고칠 때

스킬을 추가·변경했으면 **§3 표와 §2 의 마커·게이트**를 함께 고친다. 마커 헤더는 후속 스킬이
grep 하는 인터페이스이므로, 바꾸면 이 문서만 낡는 게 아니라 **워크플로가 조용히 끊긴다.**

