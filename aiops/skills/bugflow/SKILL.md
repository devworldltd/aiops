---
name: bugflow
description: "BugFlow 버그 수정 워크플로우 시작. 버그 리포트를 분석하여 재현 → 원인 분석 → 수정 → 검증 → PR 순으로 진행."
---
BugFlow 멀티에이전트 버그 수정 워크플로우를 시작합니다.

> **forge 도구 규약**: 이슈/PR 조작은 `gh` 대신 forge 중립 헬퍼 `forge.sh`(origin 리모트로 GitHub↔Gitea 자동감지)를 **실행**한다. 문서에선 `forge.sh <sub>` 로 표기하지만 실제 호출은 항상 절대경로 실행형이다: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" <sub> ...` (소싱 금지). forge.sh 는 origin 자동감지라 `--repo` 가 불필요하고, 인증(Gitea 토큰/CF Access)도 forge.sh 가 처리한다.

> ⚠️ **필수 원칙**
> - 각 단계는 반드시 지정된 **서브에이전트(Agent 도구)**를 호출해야 합니다.
> - 오케스트레이터가 직접 구현하거나 단계를 생략하는 것은 금지입니다.
> - **산출물은 이슈 댓글이 1순위**, context 파일은 forge 장애 시 폴백입니다.
> - 에이전트는 이전 단계 산출물을 **이슈 댓글에서 먼저 읽고**, 없으면 context 파일을 읽습니다.
> - **PRD / 와이어프레임 / 컴포넌트 스펙은 생략합니다.** (버그 수정은 최소 변경 원칙)
> - **재현 실패 시 추측으로 수정하지 않습니다.** 반드시 재현 성공 후 수정 진행.

---

## 모드 감지 (가장 먼저 실행)

`$ARGUMENTS` 에서 이슈 번호를 추출한다. 패턴: `#?\d+` (예: `#456`, `456`, `#456,#457`, `#456 #457 #458`).

- 추출된 이슈가 **1개 이하** → **단일 이슈 모드** (아래 STEP 0~6 그대로 실행)
- 추출된 이슈가 **2개 이상** → **배치 모드** (아래 "배치 모드" 섹션 실행)

---

## 배치 모드 (복수 이슈 병렬 처리)

**동시에 여러 버그 이슈를 처리하되, 공용 자원(git 워킹 디렉토리, Docker 등) 경합을 피하기 위해 안전한 단계만 병렬 실행한다.**

### B-0. 배치 준비

각 이슈에 대해 **순차적으로** 다음을 수행:
1. 이슈 레포 검증 (STEP 0-A-0 동일). 불일치 1건이라도 발견되면 전체 배치 중단.
2. feature/issue-N 브랜치 생성 (STEP 0-B 동일, `git fetch origin dev` 는 첫 이슈에서만).
3. forge 가용성 확인.

> 배치 모드에서는 **모든 fallback 경로가 `context/issue-<N>/` 로 격리**된다.

### B-1. 버그 분석 병렬 (`aiops:bug-analyst` 서브에이전트 N개 동시 호출)

**한 메시지에서 Agent 도구로 N개를 동시에 호출**. 각 호출의 프롬프트는 STEP 1과 동일하되 `ISSUE_NUMBER` 값이 다름.

각 서브에이전트는 해당 이슈의 Bug Brief + 재현 절차 + 근본 원인 분석을 작성 → 이슈 댓글 또는 `context/issue-<N>/` 경로에 저장.

> ⚠️ 재현 실패 이슈가 있으면 **그 이슈만** "❌ 재현 실패" 로 표시하고 배치 요약에 기록. 나머지 이슈는 계속 진행.

### B-2. 이슈별 순차 수정/검증/PR (STEP 2~6)

각 이슈에 대해 **순차적으로** 다음을 수행 (Docker 빌드/테스트 DB 충돌 방지):

```
for ISSUE_NUMBER in [issues]:
  재현 실패인 이슈는 스킵 (배치 요약에 이미 기록됨)
  git checkout feature/issue-<ISSUE_NUMBER>
  STEP 2 (dev-backend / dev-frontend 조건부 병렬)
  STEP 3 (dev-devops)
  STEP 4 (bug-verifier 검증)
  STEP 5 (dev-pr)
  STEP 6 (/aiops:review-pr)

  한 단계라도 실패하면:
    - 해당 이슈 중단
    - 실패 단계/원인을 이슈 #N 댓글에 기록 (## ❌ 배치 실패)
    - 배치 요약에 "❌ 실패 (STEP X)" 기록
    - 다음 이슈로 넘어감
```

### B-3. 배치 요약 출력

```markdown
# BugFlow 배치 결과

## 이슈 #<N1>
[STEP 0~6 진행 로그 요약]

## 이슈 #<N2>
[...]

## 배치 요약

| 이슈 | 브랜치 | 재현 | 검증 | PR | 리뷰 판정 | 상태 | 실패 단계 |
|------|--------|:----:|:----:|------|----------|:----:|-----------|
| #456 | feature/issue-456 | ✅ | ✅ | #70 | APPROVE | ✅ | — |
| #457 | feature/issue-457 | ❌ | — | — | — | ❌ | STEP 1 재현 실패 |
| #458 | feature/issue-458 | ✅ | ✅ | #71 | REQUEST_CHANGES | ⚠️ | — |

### 재실행 안내
- 재현 실패 이슈: 환경/재현 시나리오 점검 후 `/aiops:bugflow #457` 단독 실행
- 리뷰 요청 이슈: 코멘트 반영 후 `/aiops:review-pr <PR번호>` 재리뷰
```

---

## forge 가용성 확인 함수 (모든 단계에서 사용)

각 단계에서 forge(이슈/PR 호스트)에 쓰기 전에 아래를 실행해 가용성을 확인합니다:

```bash
forge.sh repo >/dev/null 2>&1 && echo "FORGE_OK" || echo "FORGE_DOWN"
```

- `FORGE_OK` → 이슈 댓글에 산출물 저장, context 파일 작성 **생략**
- `FORGE_DOWN` → context 파일에 산출물 저장 (폴백), 나중에 복구 시 동기화

### forge 장애 복구 후 동기화
`context/` 폴더에 저장된 파일이 있고 forge 가 복구되면:
1. 각 파일을 해당 이슈 댓글로 등록
2. `context/` 파일 삭제 (선택)

### 장애 중 context 백업 폴더
장애 상황에서 기존 context를 백업할 때는 **이슈 번호**로 폴더명 지정:
```
context/archive/issue-<ISSUE_NUMBER>/
```
정상 상황에서는 archive 폴더를 만들지 않습니다.

---

## STEP 0 — 사전 준비 (오케스트레이터 직접 실행)

### 0-A-0. 이슈 레포 검증

**중요**: 이슈는 반드시 현재 작업 중인 레포에서 관리해야 합니다.

forge.sh 는 origin 리모트에 스코프되므로 `forge.sh issue-view <ISSUE_NUMBER>` 는 항상 현재 레포의 이슈를 조회한다. 즉 크로스-레포 오염은 구조적으로 방지된다.

1. 현재 레포 확인: `forge.sh repo` (→ `owner/repo`)
2. 이슈 존재 확인: `forge.sh issue-view <ISSUE_NUMBER>` 가 정상 JSON 을 반환하는지 확인.
3. 조회 실패(존재하지 않는 번호/타 레포 번호)면 **작업을 즉시 중단**하고 사용자에게 알립니다:
   "⚠️ 이슈 #N을 현재 레포(<owner/repo>)에서 찾을 수 없습니다.
   올바른 레포에서 다시 실행하거나 이슈 번호를 확인해주세요."
4. 서브모듈이 있는 경우 부모(=origin) 레포의 이슈 사용은 허용합니다.
5. 인증/Access 문제로 이슈 접근 불가 시에도 작업을 중단하고 사용자에게 forge 인증(Gitea 토큰/CF Access) 설정을 요청합니다.

### 0-A. 인자 파싱

`$ARGUMENTS`에서 추출:
- **ISSUE_NUMBER**: `#숫자` 또는 `issue #숫자` 패턴 → 없으면 에러 (버그 이슈 번호 필수)
- **버그 설명 텍스트**: 이슈 번호 제외 나머지

이슈 번호로 이슈 내용을 가져옵니다:
```bash
forge.sh issue-view <ISSUE_NUMBER>       # 본문/라벨 JSON
forge.sh issue-comments <ISSUE_NUMBER>   # 전 댓글 본문
```

### 0-B. issue 브랜치 생성

```bash
# dev 브랜치 기준으로 issue 브랜치 생성 (main 아님)
git fetch origin dev
git checkout dev && git pull origin dev
git checkout -b issue-<ISSUE_NUMBER>
git push -u origin issue-<ISSUE_NUMBER>
```

> 이후 모든 수정은 이 브랜치에서 진행합니다.

### 0-C. forge 가용성 확인 및 기존 context 처리

- forge 가용성 확인
- `FORGE_OK`: 기존 context 파일이 있으면 이슈 댓글로 등록 후 삭제
- `FORGE_DOWN`: 기존 context 파일을 `context/archive/issue-<ISSUE_NUMBER>/`로 이동

---

## STEP 1 — 버그 분석 (`aiops:bug-analyst` 역할, 오케스트레이터 직접 실행)

이슈 내용을 분석하여 다음 3가지를 작성합니다:

### 1-A. Bug Brief (버그 요약)
```markdown
# 버그 브리프
작성자: Orchestrator
작성일시: [현재 날짜]
이슈: #<ISSUE_NUMBER>
상태: DONE
---

## 버그 개요
- **증상**: ...
- **영향 범위**: ...
- **심각도**: P0(서비스 중단) / P1(주요 기능 장애) / P2(부분 장애) / P3(개선)
- **보고자**: ...

## 재현 환경
- **브라우저/OS**: ...
- **사용자 역할**: ...
- **테넌트**: ...
```

### 1-B. Reproduction (재현 절차)
```markdown
## 재현 절차
1. ...
2. ...
3. ...

## 재현 결과
- **기대 동작**: ...
- **실제 동작**: ...
- **재현 성공 여부**: ✅ 재현됨 / ❌ 재현 안됨

> ❌ 재현 안됨인 경우: 추가 정보를 이슈에 요청하고 워크플로우를 중단합니다.
```

### 1-C. Root Cause (근본 원인 분석)
```markdown
## 근본 원인 분석
- **원인 위치**: [파일 경로 + 라인 번호]
- **원인 설명**: ...
- **영향받는 코드**: ...

## 수정 방향
- **수정 범위**: 최소 변경 원칙
- **백엔드 수정 필요**: 예/아니오
- **프론트엔드 수정 필요**: 예/아니오
- **DB 마이그레이션 필요**: 예/아니오
```

**저장 (forge 우선):**
```bash
# FORGE_OK 인 경우
forge.sh issue-comment <ISSUE_NUMBER> "## 🐛 버그 분석

### 버그 브리프
[내용]

### 재현 절차
[내용]

### 근본 원인 분석
[내용]"

# FORGE_DOWN 인 경우
# → context/00_bug_brief.md 에 저장
```

> ⚠️ **재현 실패 시 워크플로우를 중단합니다.** 추측으로 수정하지 않습니다.

---

## STEP 2 — 병렬 수정 (2개 서브에이전트 **조건부 동시 호출**)

근본 원인 분석 결과에 따라 해당 에이전트만 호출합니다.
**백엔드/프론트엔드 모두 수정이 필요하면 반드시 동시 호출합니다.**

### dev-backend 호출 프롬프트 (백엔드 수정 필요 시):
```
이슈 #<ISSUE_NUMBER> 댓글에서 버그 분석(🐛 버그 분석)을 읽어줘.
forge 접속 불가 시 context/00_bug_brief.md 를 읽어줘.

근본 원인 분석에 기반하여 **최소 변경 원칙**으로 백엔드를 수정해줘.
- 버그 원인 코드만 수정 (관련 없는 리팩토링 금지)
- 수정한 버그를 검증하는 테스트 추가 — 러너는 `agent_hints.backend.test_runner`(pytest·jest·go test 등)
- 기존 테스트가 깨지지 않는지 확인

저장:
- forge 가용: 수정 완료 내용을 이슈 댓글로 등록 (## 🔧 백엔드 수정 완료)
- forge 불가: context/01_be_fix.md 에 저장
```

### dev-frontend 호출 프롬프트 (프론트엔드 수정 필요 시):
```
이슈 #<ISSUE_NUMBER> 댓글에서 버그 분석(🐛 버그 분석)을 읽어줘.
forge 접속 불가 시 context/00_bug_brief.md 를 읽어줘.

근본 원인 분석에 기반하여 **최소 변경 원칙**으로 프론트엔드를 수정해줘.
- 버그 원인 코드만 수정 (관련 없는 리팩토링 금지)
- 수정한 버그를 검증하는 테스트 추가 — 러너는 `agent_hints.frontend.test_runner`(vitest·jest 등)
- 기존 테스트가 깨지지 않는지 확인

저장:
- forge 가용: 수정 완료 내용을 이슈 댓글로 등록 (## 💻 프론트엔드 수정 완료)
- forge 불가: context/02_fe_fix.md 에 저장
```

---

## STEP 3 — 환경 배포 (`aiops:dev-devops` 서브에이전트 **필수 호출**)

**반드시 `aiops:dev-devops` 서브에이전트를 Agent 도구로 호출해야 합니다.**

호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 댓글에서 수정 완료 내용(🔧, 💻)을 읽어줘.
forge 접속 불가 시 context/01_be_fix.md, context/02_fe_fix.md 를 읽어줘.

아래를 순서대로 실행해줘:
1. 신규 마이그레이션 파일 여부 확인 → 있으면 **그 프로젝트의 도구로** 적용(Alembic·prisma migrate·drizzle-kit·d1 등). 스키마 변경이 없으면 "해당 없음" 을 적는다
2. 변경된 서비스 Docker 재빌드 및 재시작
3. 전체 서비스 헬스체크
4. QA 접속 URL 확인

저장:
- forge 가용: 배포 완료 내용을 이슈 댓글로 등록 (## 🚢 배포 완료)
- forge 불가: context/03_devops_done.md 에 저장
```

---

## STEP 4 — 버그 검증 (`aiops:bug-verifier` 역할, 오케스트레이터 직접 실행)

STEP 1에서 작성한 재현 절차를 다시 수행하여 버그가 수정되었는지 검증합니다.

### 검증 항목
1. **재현 절차 재실행**: STEP 1의 재현 절차를 동일하게 수행
2. **기대 동작 확인**: 수정 후 기대 동작대로 작동하는지 확인
3. **회귀 테스트**: 기존 테스트 전체 실행 — 존재하는 레인의 러너로(레인 판정은 `/aiops:qa-check` §0 과 동일)
4. **사이드이펙트 확인**: 수정으로 인한 다른 기능 영향 없는지 확인

### 검증 결과
```markdown
## 버그 검증 결과
- **재현 절차 재실행**: ✅ 수정됨 / ❌ 여전히 발생
- **기대 동작**: ✅ 정상 / ❌ 비정상
- **회귀 테스트**: ✅ PASS (FAILED=0) / ❌ FAIL
- **사이드이펙트**: ✅ 없음 / ⚠️ 발견됨
```

**PASS**: 모든 ✅ → STEP 5(PR 생성) 진행
**FAIL**: 하나라도 ❌ → dev-backend/dev-frontend 재호출 → STEP 3(재배포) → STEP 4 재실행

**저장 (forge 우선):**
```bash
# FORGE_OK 인 경우
forge.sh issue-comment <ISSUE_NUMBER> "## ✅ 버그 검증 완료\n\n[검증 결과]"

# FORGE_DOWN 인 경우
# → context/04_bug_verified.md 에 저장
```

---

## STEP 5 — PR 생성 (`aiops:dev-pr` 서브에이전트 **필수 호출**)

> PR 생성 완료 후 반드시 STEP 6(리뷰)을 이어서 실행해야 합니다.

**반드시 `aiops:dev-pr` 서브에이전트를 Agent 도구로 호출해야 합니다.**

호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 의 본문/댓글을 읽어줘:
forge.sh issue-view <ISSUE_NUMBER>
forge.sh issue-comments <ISSUE_NUMBER>

댓글에서 버그 분석과 수정 내용을 파악하고 PR을 생성해줘.
forge 접속 불가 시 context/ 디렉토리 파일들을 읽어줘.

ISSUE_NUMBER: <ISSUE_NUMBER>
BRANCH: issue-<ISSUE_NUMBER>

issue-<ISSUE_NUMBER> 브랜치에서 dev로 PR을 만들고, Fixes #<ISSUE_NUMBER> 포함.
PR 제목은 "fix: [버그 요약]" 형식.
(해당 브랜치가 이미 origin에 push되어 있음)

저장:
- forge 가용: PR URL을 이슈 댓글로 등록 (## 🚀 PR 생성 완료)
- forge 불가: context/05_pr.md 에 저장
```

---

## STEP 6 — PR 리뷰 (`review-pr` 스킬 **필수 실행**)

**반드시 `/aiops:review-pr` 스킬을 실행해야 합니다.**

STEP 5에서 생성된 PR 번호를 인자로 전달:

```
/aiops:review-pr <PR_NUMBER> ISSUE_NUMBER:<ISSUE_NUMBER>
```

- PR diff 전체 분석 (보안 / 품질 / 아키텍처 / 테스트 체크리스트)
- 판정:
  - **APPROVE**: P0 이슈 없음 → `forge.sh pr-review <PR> APPROVE`
  - **REQUEST_CHANGES**: P0 이슈 발견 → `forge.sh pr-review <PR> REQUEST_CHANGES` → dev-backend/dev-frontend 재호출 → STEP 3(재배포) → STEP 4(재검증) → STEP 5(PR 업데이트) → STEP 6(재리뷰)
  - **COMMENT**: 권고사항만 → `forge.sh pr-review <PR> COMMENT`
- 결과를 이슈 댓글로 등록 (## 🔍 PR 리뷰 완료) 및 `context/06_review.md` 저장

---

## 전체 흐름 요약

```
STEP 0    오케스트레이터  인자 파싱 + issue-N 브랜치 생성 + context 처리
STEP 1    오케스트레이터  버그 분석 (Brief + 재현 + 근본 원인)
             ↓ 저장: GH 댓글(🐛) 또는 context/00_bug_brief.md
             ↓ 재현 실패 시 → 워크플로우 중단
STEP 2    [dev-backend]   백엔드 수정 (조건부)  ─┐
          [dev-frontend]  프론트엔드 수정 (조건부) ─┘ 동시 실행
             ↓ 저장: GH 댓글(🔧 💻) 또는 context/01,02
STEP 3    [dev-devops]    DB 마이그레이션 + 재빌드 + 헬스체크
             ↓ 저장: GH 댓글(🚢) 또는 context/03_devops_done.md
STEP 4    오케스트레이터  버그 검증 (재현 절차 재실행 + 회귀 테스트)
             ↓ 저장: GH 댓글(✅) 또는 context/04_bug_verified.md
             ↓ FAIL → dev-backend/aiops:frontend 재호출 → STEP 3 재시작
STEP 5    [dev-pr]        PR 생성 (issue-N → dev)
             ↓ 저장: GH 댓글(🚀) 또는 context/05_pr.md
STEP 6    /aiops:review-pr      PR 코드 리뷰 → approve/request-changes/comment
             ↓ 저장: GH PR 리뷰 댓글(🔍) 및 context/06_review.md
             ↓ REQUEST_CHANGES → dev-backend/aiops:frontend 재호출 → STEP 3 재시작
```

**forge 장애 시:**
```
정상 흐름과 동일하나 모든 저장이 context 파일로 대체됨
archive 폴더: context/archive/issue-<ISSUE_NUMBER>/

복구 후:
context 파일들 → forge.sh issue-comment 로 일괄 동기화 → context 파일 삭제
```

---

현재 제공된 인자: $ARGUMENTS

위 절차대로 STEP 0부터 순서대로 진행해줘.
