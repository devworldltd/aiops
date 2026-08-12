---
name: devplanning
description: "개발 직전(STEP 0~4)까지의 기획/문서화를 자동 실행하는 스킬. 단일 이슈 또는 복수 이슈 배치 모드 지원. STEP 2/3/4를 이슈별 병렬 호출하여 여러 이슈의 PRD·기술 스펙·E2E 골격을 동시에 완료."
---

devflow의 **STEP 0~4 (개발 직전까지)** 만 실행하는 스킬입니다. 구현(STEP 5+)은 다루지 않으며, 완료 후 `/aiops:devflow`로 이어서 진행하거나 `/aiops:backend` `/aiops:frontend` 등 단계별 스킬을 사용합니다.

> 💡 **언제 쓰나요?**
> - 여러 이슈의 기획·기술 스펙·E2E 골격을 미리 일괄 정리하고 싶을 때
> - 스프린트 시작 시 다음 작업할 N개 이슈를 한 번에 준비
> - 구현은 나중에 별도 시점에 진행

> **forge 도구 규약**: 이슈 조작은 `gh` 대신 forge 중립 헬퍼 `forge.sh`(origin 리모트로 GitHub↔Gitea 자동감지)를 **실행**한다. 문서에선 `forge.sh <sub>` 로 표기하지만 실제 호출은 항상 절대경로 실행형이다: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" <sub> ...` (소싱 금지). forge.sh 는 origin 자동감지라 `--repo` 가 불필요하고, 인증(Gitea 토큰/CF Access)도 forge.sh 가 처리한다.

---

## 모드 감지 (가장 먼저 실행)

`$ARGUMENTS`에서 이슈 번호를 추출. 패턴: `#?\d+` (예: `#23`, `23`, `#23,#24`, `#23 #24 #25`)

- 추출 **1개 이하** → **단일 이슈 모드** (아래 단일 모드 섹션)
- 추출 **2개 이상** → **배치 모드** (아래 배치 모드 섹션)

> ⚠️ `/aiops:devflow`와 동일한 산출물/헤더/context 파일명을 사용합니다. 본 스킬로 STEP 0~4 완료 후 `/aiops:devflow #N`으로 다시 실행하면 STEP 5부터 자동 인식되어 이어 진행됩니다.

---

## forge 가용성 확인

각 단계에서 다음 명령으로 가용성을 확인합니다:

```bash
forge.sh repo >/dev/null 2>&1 && echo "FORGE_OK" || echo "FORGE_DOWN"
```

- `FORGE_OK` → 이슈 댓글에 산출물 저장
- `FORGE_DOWN` → `context/issue-<N>/` 폴더에 fallback 저장

---

## 단일 이슈 모드 (STEP 0~4)

### STEP 0 — 사전 준비 (오케스트레이터)

#### 0-A 이슈 레포 검증
```bash
forge.sh repo                       # → owner/repo (현재 origin 레포)
forge.sh issue-view <ISSUE_NUMBER>  # 정상 JSON 반환 시 현재 레포에 존재
```
forge.sh 는 origin 스코프이므로 issue-view 는 항상 현재 레포 이슈를 조회한다. 조회 실패(존재하지 않는 번호)면 작업 중단 + 사용자 안내.

#### 0-B 이슈 번호/요구사항 텍스트 처리

- 이슈 번호만 있고 텍스트 없음 → `forge.sh issue-view` / `forge.sh issue-comments`로 본문/댓글 컨텍스트로 사용
- 텍스트만 있고 이슈 번호 없음 → `forge.sh issue-create`로 신규 이슈 생성 후 번호 채택
- 둘 다 있음 → 이슈 번호 사용 + 텍스트는 추가 컨텍스트

#### 0-C feature 브랜치 생성
```bash
git fetch origin dev
git checkout dev && git pull origin dev
git checkout -b feature/issue-<ISSUE_NUMBER>
git push -u origin feature/issue-<ISSUE_NUMBER>
```

#### 0-D 기존 context 처리
- `FORGE_OK` + 기존 context 파일 존재 → 이슈 댓글로 등록 후 삭제
- `FORGE_DOWN` + 기존 context 파일 존재 → `context/archive/issue-<N>/`로 이동

---

### STEP 1 — 브리프 (오케스트레이터 직접)

요구사항을 분석하여 다음 형식으로 작성:

```markdown
# 프로젝트 브리프
작성자: Orchestrator
작성일시: <오늘>
이슈: #<ISSUE_NUMBER>
상태: DONE
---
## 목표
<요구사항을 한두 문단으로 정리>

## 범위 (In-scope / Out-of-scope)
- In: ...
- Out: ...

## 일정 (추정)
- 기획~기술 스펙: 0.5일
- 구현: 1~2일
- QA/PR: 0.5일
```

**저장:**
- FORGE_OK: `forge.sh issue-comment <N> "## 📋 브리프\n\n<내용>"`
- FORGE_DOWN: `context/issue-<N>/00_brief.md`

---

### STEP 2 — PRD + 와이어프레임 (`aiops:planning` 에이전트 **필수 호출**)

**Agent 도구로 `aiops:planning` 서브에이전트 호출.**

호출 프롬프트:
```
이슈 #<ISSUE_NUMBER>의 댓글에서 브리프(📋 브리프)를 읽어줘.
forge 접속 불가 시 context/issue-<N>/00_brief.md 를 읽어줘.

명령:
forge.sh issue-comments <ISSUE_NUMBER>

아래 두 산출물을 작성해줘:
1. PRD (배경/목표, 사용자 스토리, Must/Should/Could 요구사항, 수용 기준, 마일스톤)
2. UX 와이어프레임 (화면 흐름도, 핵심 화면, 인터랙션 명세)

저장:
- forge 가용: 각각 이슈 댓글로 등록 (## 📝 PRD, ## 🖼️ 와이어프레임)
- forge 불가: context/issue-<N>/01_prd.md, 02_wireframe.md 에 저장
```

---

### STEP 3 — 기술 스펙 + E2E 검증 시나리오 (`aiops:dev` 에이전트 **필수 호출**)

**Agent 도구로 `aiops:dev` 서브에이전트 호출.**

호출 프롬프트:
```
이슈 #<ISSUE_NUMBER>의 댓글에서 PRD(📝 PRD)와 와이어프레임(🖼️ 와이어프레임)을 읽어줘.
forge 접속 불가 시 context/issue-<N>/01_prd.md, 02_wireframe.md 를 읽어줘.

명령:
forge.sh issue-comments <ISSUE_NUMBER>

FastAPI API 명세, DB 스키마 변경, Alembic 마이그레이션 전략, 시퀀스 다이어그램,
프론트엔드 연동 명세를 포함한 기술 스펙을 작성해줘.

⭐ 기술 스펙 본문에 '## E2E 검증 시나리오' 절을 반드시 포함하라 (#118).
시나리오 항목은 {ID, 사전조건, 스텝, 기대결과} 4필드를 갖는다.
이 절은 다음 STEP 4(dev-e2e) 에이전트의 입력이 된다.

저장:
- forge 가용: 이슈 댓글로 등록 (## ⚙️ 기술 스펙)
- forge 불가: context/issue-<N>/03_tech_spec.md 에 저장
```

---

### STEP 4 — E2E 코드 골격 (`aiops:dev-e2e` 에이전트 **필수 호출**)

**Agent 도구로 `aiops:dev-e2e` 서브에이전트 호출.**

호출 프롬프트:
```
이슈 #<ISSUE_NUMBER>의 댓글에서 다음을 읽어줘:
- PRD (## 📝 PRD)
- 기술 스펙 (## ⚙️ 기술 스펙) — 내부 "## E2E 검증 시나리오" 절 핵심 입력
- 와이어프레임 (## 🖼️ 와이어프레임)

forge 접속 불가 시: context/issue-<N>/01_prd.md, 03_tech_spec.md, 02_wireframe.md

명령:
forge.sh issue-comments <ISSUE_NUMBER>

다음을 수행해줘:
1. Q5 보호: 기존 playwright.config.ts 또는 tests/e2e/playwright.config.ts 존재 시
   → tests/e2e/.devflow-hint.md 만 작성, 골격 생성 스킵 (덮어쓰기 금지)
2. 신규: ${CLAUDE_PLUGIN_ROOT}/templates/e2e/ 골격을 대상 프로젝트로 복사 + 도메인 토큰 치환
   → 18~21개 파일 생성/배치 (POM, fixtures, full/, smoke/)

산출물 (두 헤더 모두 등록):
- ## 🧪 E2E 시나리오 — 도메인/full 수/smoke 수/보호 동작 요약
- ## 🧪 E2E 코드 작성 완료 — 생성 파일 수와 경로 목록

저장:
- forge 가용: 위 두 헤더로 이슈 댓글 등록
- forge 불가: context/issue-<N>/04_e2e_plan.md, 05_e2e_scaffold.md 에 저장
```

---

### 완료 안내 (단일 모드)

STEP 4 완료 후 다음을 출력:

```markdown
## ✅ /aiops:devplanning 완료 — 이슈 #<N>

### 산출물
- 📋 브리프 / 📝 PRD / 🖼️ 와이어프레임 / ⚙️ 기술 스펙
- 🧪 E2E 시나리오 / 🧪 E2E 코드 작성 완료

### 다음 단계
구현을 진행하려면:

  /aiops:devflow #<N>           # STEP 5(병렬 구현)부터 자동 인식하여 이어 진행
  
또는 단계별:

  /aiops:backend #<N>           # 백엔드만
  /aiops:frontend #<N>          # 프론트엔드만
  
브랜치: feature/issue-<N> (origin 푸시 완료)
```

---

## 배치 모드 (복수 이슈 병렬)

### B-0 배치 준비 (순차)

각 이슈에 대해 **순차적으로** 다음을 수행:
1. 이슈 레포 검증 (STEP 0-A 동일). 불일치 1건이라도 발견 시 전체 배치 중단.
2. feature/issue-N 브랜치 생성 (STEP 0-C 동일, `git fetch origin dev`는 첫 이슈에서만)
3. forge 가용성 확인 (STEP 0-D 동일)

> 배치 모드에서는 **모든 fallback이 `context/issue-<N>/`로 격리**되어 이슈 간 파일 충돌 없음.

### B-1 브리프 (순차, 빠름)

각 이슈에 대해 오케스트레이터가 직접 STEP 1 작성. 짧은 작업이므로 순차로 처리.

### B-2 PRD + 와이어프레임 병렬 (`aiops:planning` 에이전트 N개 동시)

**반드시 한 메시지에서 Agent 도구로 N개를 동시 호출.** 각 호출의 프롬프트는 단일 모드 STEP 2와 동일하되 `ISSUE_NUMBER` 값만 다름.

### B-3 기술 스펙 병렬 (`aiops:dev` 에이전트 N개 동시)

한 메시지에서 N개 동시 호출. 각 호출의 프롬프트는 단일 모드 STEP 3과 동일.

### B-4 E2E 골격 병렬 (`aiops:dev-e2e` 에이전트 N개 동시)

한 메시지에서 N개 동시 호출. 각 호출의 프롬프트는 단일 모드 STEP 4와 동일.

> ⚠️ STEP 4의 파일 생성은 각 이슈의 `feature/issue-<N>` 브랜치(또는 대상 프로젝트의 같은 디렉토리)에서 발생하므로 brunchroot 격리 필요. 본 스킬은 대상 프로젝트 루트(현재 cwd)를 공유하므로, **여러 이슈의 STEP 4가 동일한 `tests/e2e/` 경로에 동시 쓰기를 시도하면 충돌 가능**. 따라서:
>
> - **단일 대상 프로젝트** + **여러 이슈가 같은 e2e 도메인 영역**일 때는 B-4를 **순차**로 전환 (한 번에 1 이슈씩)
> - **이슈마다 별도 브랜치/도메인**이면 병렬 안전
>
> 안전을 위해 본 스킬은 **B-4는 기본 순차**로 실행하되, 충돌 가능성이 없다고 판단되면 (예: 도메인 영역이 명확히 분리됨) 사용자가 `--parallel-e2e` 인자로 강제 병렬 가능.

### B-5 배치 요약 출력

모든 이슈 STEP 0~4 완료 후 아래 형식 출력:

```markdown
# /aiops:devplanning 배치 결과

## 처리된 이슈

| 이슈 | 브랜치 | 브리프 | PRD | 와이어 | 기술스펙 | E2E 시나리오 | E2E 코드 | 상태 |
|------|--------|:------:|:---:|:------:|:--------:|:------------:|:--------:|:----:|
| #23 | feature/issue-23 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | DONE |
| #24 | feature/issue-24 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | DONE |
| #25 | feature/issue-25 | ✅ | ✅ | ✅ | ❌ | — | — | FAIL (STEP 3) |

## 다음 단계

구현을 시작하려면 이슈별로 `/aiops:devflow` 또는 단계별 스킬을 호출:

  /aiops:devflow #23    # STEP 5+ 자동 진행
  /aiops:devflow #24
  /aiops:devflow #25    # STEP 3 재시도 후 진행

실패한 이슈는 해당 STEP만 수동 재실행 가능:

  Agent 도구로 dev 에이전트 재호출 (이슈 #25, STEP 3 프롬프트)
```

---

## 인자

| 인자 | 설명 |
|------|------|
| `#N` 또는 `N` | 이슈 번호 (다수 지정 시 배치 모드) |
| 텍스트 | 이슈 번호 없을 시 신규 이슈로 생성 |
| `--parallel-e2e` | (배치 모드) STEP 4를 병렬로 실행. 기본 순차. |
| `--dry-run` | 실제 에이전트 호출 없이 흐름만 출력 |

---

## /aiops:devflow와의 관계

| 항목 | /aiops:devplanning | /aiops:devflow |
|------|-------------|----------|
| 범위 | STEP 0~4 | STEP 0~10 |
| 구현 단계 (STEP 5+) | ❌ 다루지 않음 | ✅ 포함 |
| 단일 모드 | ✅ | ✅ |
| 배치 모드 | ✅ | ✅ |
| STEP 2/3/4 병렬 (배치) | ✅ | ✅ |
| STEP 5+ 병렬 (배치) | — | ❌ Docker 충돌 회피로 순차 |

> /aiops:devplanning 완료 후 `/aiops:devflow #N`으로 호출하면 이미 등록된 STEP 0~4 산출물을 인식하여 STEP 5부터 자동 진행됩니다.

---

## 산출물 헤더 일람 (devflow와 동일)

| STEP | 헤더 |
|------|------|
| 1 | `## 📋 브리프` |
| 2 | `## 📝 PRD` + `## 🖼️ 와이어프레임` |
| 3 | `## ⚙️ 기술 스펙` (내부 `## E2E 검증 시나리오` 절 의무) |
| 4 | `## 🧪 E2E 시나리오` + `## 🧪 E2E 코드 작성 완료` |
| 완료 | `## ✅ /aiops:devplanning 완료` |

---

## context fallback 파일명 (forge 장애 시)

| STEP | 파일명 |
|------|--------|
| 1 | `context/issue-<N>/00_brief.md` |
| 2 | `01_prd.md` + `02_wireframe.md` |
| 3 | `03_tech_spec.md` |
| 4 | `04_e2e_plan.md` + `05_e2e_scaffold.md` |

---

## 사용 예시

```bash
# 단일 이슈
/aiops:devplanning #42

# 배치 (3개 이슈 동시 기획)
/aiops:devplanning #42 #43 #44

# 이슈 없이 요구사항 텍스트로 시작 (이슈 자동 생성)
/aiops:devplanning 로그인 기능 구현. 이메일+비밀번호 인증, JWT 토큰 발급.

# 배치 + STEP 4 병렬 강제 (도메인 격리가 확실할 때)
/aiops:devplanning #42 #43 #44 --parallel-e2e

# dry-run (호출 없이 흐름만)
/aiops:devplanning #42 --dry-run
```

---

현재 제공된 인자: $ARGUMENTS

위 절차대로 진행해줘.
