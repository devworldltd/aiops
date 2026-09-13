---
name: devflow
description: "DevFlow 전체 프로젝트 워크플로우 시작. 신규 기능이나 프로젝트를 Phase 1(기획) → Phase 2(개발) → Phase 3(QA/E2E/PR/배포) 순으로 진행 (10 STEP)."
---
DevFlow 멀티에이전트 워크플로우를 시작합니다.

## 공통 workflow 계약

실행 전에 저장소의 `shared/workflows/aiops:devflow.yaml`이 있으면 `shared/scripts/validate_contracts.py`로 검증합니다. 대상 프로젝트 설치본은 `.codex/workflows/aiops:devflow.yaml` 또는 프로젝트 설정이 가리키는 workflow를 사용합니다.

```bash
PROFILE=${AI_DEVOPS_PROFILE:-.codex/project-profile.yaml}
WORKFLOW=${AI_DEVOPS_WORKFLOW:-shared/workflows/aiops:devflow.yaml}
VALIDATOR=shared/scripts/validate_contracts.py

if [[ -f "$VALIDATOR" && -f "$WORKFLOW" ]]; then
  [[ -f "$PROFILE" ]] || PROFILE=shared/examples/project-profile.v2.yaml
  python3 "$VALIDATOR" --profile "$PROFILE" --workflow "$WORKFLOW" || {
    echo "BLOCKED: 공통 workflow/project profile 계약 검증 실패"
    exit 1
  }
fi
```

단계 번호, 산출물, comment header와 gate는 공통 계약을 정본으로 사용합니다. Claude의 서브에이전트·병렬 호출은 실행 방식일 뿐 계약 자체를 변경하지 않습니다.

> **forge 도구 규약**: 이슈/PR 조작은 `gh` 대신 forge 중립 헬퍼 `forge.sh`(origin 리모트로 GitHub↔Gitea 자동감지)를 **실행**한다. 문서에선 `forge.sh <sub>` 로 표기하지만 실제 호출은 항상 절대경로 실행형이다: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" <sub> ...` (소싱 금지). forge.sh 는 origin 자동감지라 `--repo` 가 불필요하고, 인증(Gitea 토큰/CF Access)도 forge.sh 가 처리한다.

> ⚠️ **필수 원칙**
> - 각 단계는 반드시 지정된 **서브에이전트(Agent 도구)**를 호출해야 합니다.
> - 오케스트레이터가 직접 구현하거나 단계를 생략하는 것은 금지입니다.
> - **산출물은 이슈 댓글이 1순위**, context 파일은 forge 장애 시 폴백입니다.
> - 에이전트는 이전 단계 산출물을 **이슈 댓글에서 먼저 읽고**, 없으면 context 파일을 읽습니다.

---

## 모드 감지 (가장 먼저 실행)

`$ARGUMENTS` 에서 이슈 번호를 추출한다. 패턴: `#?\d+` (예: `#23`, `23`, `#23,#24`, `#23 #24 #25`).

- 추출된 이슈가 **1개 이하** → **단일 이슈 모드** (아래 STEP 0~10 그대로 실행)
- 추출된 이슈가 **2개 이상** → **배치 모드** (아래 "배치 모드" 섹션 실행)

---

## 플랫폼 자동 분기 (STEP 0 직후 — #151 신규)

STEP 0(브랜치 생성)이 완료된 직후, `.reviewer/profile.yaml`의 `platform` 또는 `.claude/config.json`의 `agent_hints.platform`을 읽어 플랫폼별로 분기한다.

```bash
# §M.1 platform 결정 (profile 우선)
PROFILE_PLATFORM=$(grep -E '^platform:' .reviewer/profile.yaml 2>/dev/null | awk '{print $2}')
HINTS_PLATFORM=$(jq -r '.agent_hints.platform // empty' .claude/config.json 2>/dev/null)
PLATFORM="${HINTS_PLATFORM:-${PROFILE_PLATFORM:-web}}"

echo "[devflow] 감지된 플랫폼: $PLATFORM"
```

### §M.2 분기

| platform | 동작 |
|----------|------|
| `web` (기본) | 기존 STEP 1~10 진행 (변경 없음, 역호환) |
| `cli` | 기존 STEP 1~10 진행 (web 과 동일, 경고 없음) — #16 |
| `mobile` | 즉시 `/aiops:mobileflow #N`에 위임 + 종료 (STEP 1~10 진행하지 않음) |
| `both` | 기존 STEP 1~10 (웹) 진행 후 `/aiops:mobileflow #N` 추가 호출 (순차) |

```bash
# >>> devflow:platform-branch >>>
case "$PLATFORM" in
  web)
    echo "[devflow] 웹 흐름 진행"
    # STEP 1 이하 정상 진행
    ;;
  cli)
    echo "[devflow] CLI 흐름 진행 (web 동일)"
    # web 과 동일하게 STEP 1 이하 정상 진행. mobileflow 위임 없음.
    ;;
  mobile)
    echo "[devflow] 모바일 전용 — /aiops:mobileflow 위임"
    # /aiops:mobileflow 호출 (Skill 도구 또는 사용자 안내)
    exec /aiops:mobileflow "$ISSUE_NUMBER"
    exit 0
    ;;
  both)
    echo "[devflow] 웹 + 모바일 — 웹 STEP 1~10 완료 후 /aiops:mobileflow 추가 호출"
    # STEP 1~10 진행 후 마지막에 /aiops:mobileflow 호출
    DEVFLOW_THEN_MOBILE=true
    ;;
  *)
    echo "[devflow] WARN: unknown platform=$PLATFORM — web 폴백"
    ;;
esac
# <<< devflow:platform-branch <<<
```

### §M.3 platform=both 사용자 흐름

```
STEP 0 (브랜치) → §M 분기 (platform=both 감지)
  → STEP 1~10 (웹 흐름 완료)
  → /aiops:mobileflow $ISSUE_NUMBER 추가 호출
  → 두 PR 머지 시점이 다를 수 있음 (각 환경별 검증)
```

> ⚠️ platform=both는 웹과 모바일이 동일 이슈에서 진행됨. 별도 이슈 분리도 가능.

---

## 워크플로우 lock 관리 (#176 신규)

devflow 시작 시 `.claude/.devflow.lock` 을 작성하고, 종료(STEP 10 완료, 사용자 취소, 또는 에러) 시 제거. install.sh가 이 lock을 감지하여 동시 실행 시 사용자에게 경고한다.

### L.1 시작 시점 (STEP 0 직후)

```bash
mkdir -p .claude
cat > .claude/.devflow.lock <<EOF
{
  "workflow": "devflow",
  "issue": $ISSUE_NUMBER,
  "branch": "feature/issue-$ISSUE_NUMBER",
  "step": 0,
  "started_at": "$(date -u +%FT%TZ)",
  "pid": $$
}
EOF
```

### L.2 STEP 진행 갱신 (각 STEP 시작 시)

```bash
# 예: STEP N 시작 시
jq --argjson step "$STEP_N" '.step = $step' .claude/.devflow.lock > .claude/.devflow.lock.tmp \
  && mv .claude/.devflow.lock.tmp .claude/.devflow.lock
```

### L.3 종료 시점 (STEP 10 완료, 사용자 취소, 에러)

```bash
rm -f .claude/.devflow.lock
```

### L.4 trap 등록 (이상 종료 보호)

```bash
trap 'rm -f .claude/.devflow.lock' EXIT INT TERM
```

이 절은 mobileflow / bugflow / devplanning 에서도 동일 패턴으로 적용된다. install.sh 가 lock 감지 시 사용자 확인을 요구하므로 동시 실행으로 인한 정의 변경 사고를 예방한다.

---

## 배치 모드 (복수 이슈 병렬 처리)

**동시에 여러 이슈를 처리하되, 공용 자원(git 워킹 디렉토리, Docker 등) 경합을 피하기 위해 안전한 단계만 병렬 실행한다.**

### B-0. 배치 준비

각 이슈에 대해 **순차적으로** 다음을 수행:
1. 이슈 레포 검증 (STEP 0-A-0 동일). 불일치 1건이라도 발견되면 전체 배치를 중단하고 사용자에게 보고.
2. feature/issue-N 브랜치 생성 (STEP 0-B 동일, `git fetch origin dev` 는 첫 이슈에서만).
3. forge 가용성 확인 (STEP 0-C 동일).

> 배치 모드에서는 **모든 fallback 경로가 `context/issue-<N>/` 로 격리**된다 (예: `context/issue-23/01_prd.md`). 이슈 간 파일 충돌 방지.

### B-1. 이슈별 브리프 (순차, 빠름)

각 이슈에 대해 오케스트레이터가 직접 브리프 작성 (STEP 1과 동일 내용, 저장 경로만 이슈별 격리).

### B-2. 기획 단계 병렬 (`aiops:planning` 서브에이전트 N개 동시 호출)

**반드시 한 메시지에서 Agent 도구로 N개를 동시에 호출**. 각 호출의 프롬프트는 STEP 2와 동일하되 `ISSUE_NUMBER` 값이 다름.

각 서브에이전트는 해당 이슈의 PRD 와 와이어프레임을 작성 → 이슈 댓글 또는 `context/issue-<N>/01_prd.md`, `02_wireframe.md` 에 저장.

### B-3. 기술 스펙 병렬 (`aiops:dev` 서브에이전트 N개 동시 호출)

마찬가지로 한 메시지에서 N개 동시 호출. 각 서브에이전트는 해당 이슈의 기술 스펙 작성 → `## ⚙️ 기술 스펙` 댓글 또는 `context/issue-<N>/03_tech_spec.md`. 본문에 `## E2E 검증 시나리오` 절을 반드시 포함.

### B-4. 이슈별 순차 구현/QA/E2E/PR (STEP 4~10)

각 이슈에 대해 **순차적으로** 다음을 수행 (이 구간은 Docker 빌드/포트/테스트 DB 충돌 때문에 직렬이 안전):

```
for ISSUE_NUMBER in [issues]:
  git checkout feature/issue-<ISSUE_NUMBER>
  STEP 4  (dev-e2e)                                            # 신규
  STEP 5  (dev-designer + dev-backend + dev-frontend 이슈 내 병렬)
  STEP 6  (dev-devops)
  STEP 7  (qa-backend + qa-frontend + qa-admin 이슈 내 병렬)   # Sign-off 게이트 #1
  STEP 8  (/aiops:e2e-test --env=local --mode=full)                  # 신규 / Sign-off 게이트 #2
  STEP 9  (dev-pr)
  STEP 10 (/aiops:review-pr)

  한 단계라도 실패하면:
    - 해당 이슈 중단
    - 실패 단계/원인을 이슈 #N 댓글에 기록 (## ❌ 배치 실패)
    - 배치 요약 테이블에 "❌ 실패 (STEP X)" 기록
    - 다음 이슈로 넘어감 (전체 배치 중단 금지)
```

### B-5. 배치 요약 출력

모든 이슈 처리 완료 후 아래 형식으로 요약을 출력:

```markdown
# DevFlow 배치 결과

## 이슈 #<N1>
[STEP 0~10 진행 로그 요약]

## 이슈 #<N2>
[...]

...

## 배치 요약

| 이슈 | 브랜치 | PR | 리뷰 판정 | 상태 | 실패 단계 |
|------|--------|------|----------|:----:|-----------|
| #23 | feature/issue-23 | #50 | APPROVE | ✅ | — |
| #24 | feature/issue-24 | #51 | REQUEST_CHANGES | ⚠️ | — |
| #25 | feature/issue-25 | — | — | ❌ | STEP 8 E2E FAIL |

### 재실행 안내
- 실패한 이슈만 개별 실행: `/aiops:devflow #25`
- 리뷰 요청 이슈는 `/aiops:review-pr <PR번호>` 로 재리뷰 후 `/aiops:merge-pr <이슈번호>` 진행
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
- **ISSUE_NUMBER**: `#숫자` 또는 `issue #숫자` 패턴 → 없으면 null
- **요구사항 텍스트**: 이슈 번호 제외 나머지

**케이스별 처리:**

**① 이슈 번호만 있고 요구사항 텍스트가 없는 경우:**
```bash
# 이슈 본문 JSON + 전 댓글(이전 단계 산출물)
forge.sh issue-view <ISSUE_NUMBER>
forge.sh issue-comments <ISSUE_NUMBER>
```
이슈 내용 + 기존 댓글(이전 단계 산출물)을 모두 가져와 요구사항으로 사용.

**② 요구사항 텍스트만 있고 이슈 번호가 없는 경우:**
요구사항 텍스트로 이슈를 생성하고 발급된 번호를 ISSUE_NUMBER로 사용합니다.
```bash
# 요구사항 첫 줄을 제목으로, 전체 텍스트를 본문으로 이슈 생성 (→ ISSUE_NUMBER=.. ISSUE_URL=..)
CREATED=$(forge.sh issue-create "<요구사항 첫 줄 또는 한 줄 요약>" "<요구사항 전체 텍스트>")
ISSUE_NUMBER=$(echo "$CREATED" | sed -nE 's/.*ISSUE_NUMBER=([0-9]+).*/\1/p')
echo "새 이슈 생성: #$ISSUE_NUMBER"
```
이후 ISSUE_NUMBER가 있는 것과 동일하게 처리합니다.

**③ 이슈 번호와 요구사항 텍스트가 모두 있는 경우:**
이슈 번호를 사용하고, 요구사항 텍스트를 추가 컨텍스트로 활용합니다.

**ISSUE_NUMBER가 없고 요구사항 텍스트가 있으면 — 이슈 자동 생성:**
```bash
# 요구사항 텍스트 첫 줄을 제목으로, 전체를 본문으로 이슈 생성
CREATED=$(forge.sh issue-create "<요구사항 첫 줄 또는 50자 요약>" "<요구사항 전체 텍스트>")
ISSUE_NUMBER=$(echo "$CREATED" | sed -nE 's/.*ISSUE_NUMBER=([0-9]+).*/\1/p')
```
생성된 번호를 `ISSUE_NUMBER`로 설정하고 이후 모든 단계에서 사용한다.

### 0-B. feature 브랜치 생성

**이슈별 feature 브랜치 전략을 사용합니다.**

ISSUE_NUMBER가 확정되면 (0-A에서 항상 확정됨):
```bash
# dev 브랜치 기준으로 feature 브랜치 생성 (main 아님)
git fetch origin dev
git checkout dev && git pull origin dev
git checkout -b feature/issue-<ISSUE_NUMBER>
git push -u origin feature/issue-<ISSUE_NUMBER>
```

> 이후 모든 구현(백엔드/프론트엔드 서브모듈 포함)은 이 브랜치에서 진행합니다.

### 0-C. forge 가용성 확인 및 기존 context 처리

- forge 가용성 확인
- `FORGE_OK`: 기존 context 파일이 있으면 이슈 댓글로 등록 후 삭제
- `FORGE_DOWN`: 기존 context 파일을 `context/archive/issue-<ISSUE_NUMBER>/`로 이동

---

## STEP 1 — 브리프 작성 (오케스트레이터 직접 실행)

요구사항을 분석하여 브리프 작성.

```markdown
# 프로젝트 브리프
작성자: Orchestrator
작성일시: [현재 날짜]
이슈: #<ISSUE_NUMBER>
상태: DONE
---
[내용]
```

**저장 (forge 우선):**
```bash
# FORGE_OK 인 경우
forge.sh issue-comment <ISSUE_NUMBER> "## 📋 브리프

[내용]"
# FORGE_DOWN 인 경우
# → context/00_brief.md 에 저장
```

---

## STEP 2 — Phase 1: 기획 (`aiops:planning` 서브에이전트 **필수 호출**)

**반드시 `aiops:planning` 서브에이전트를 Agent 도구로 호출해야 합니다.**

호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 의 댓글에서 브리프(📋 브리프)를 읽어줘.
forge 접속 불가 시 context/00_brief.md 를 읽어줘.

명령:
forge.sh issue-comments <ISSUE_NUMBER>

아래 두 산출물을 작성해줘:
1. PRD (배경/목표, 사용자 스토리, 기능 요구사항 Must/Should/Could, 수용 기준, 마일스톤)
2. UX 와이어프레임 (화면 흐름도, 핵심 화면, 인터랙션 명세)

저장:
- forge 가용: 각각 이슈 댓글로 등록 (## 📝 PRD, ## 🖼️ 와이어프레임)
- forge 불가: context/01_prd.md, context/02_wireframe.md 에 저장
```

---

## STEP 3 — 기술 스펙 (`aiops:dev` 서브에이전트 **필수 호출**)

**반드시 `aiops:dev` 서브에이전트를 Agent 도구로 호출해야 합니다.**

호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 의 댓글에서 PRD(📝 PRD)와 와이어프레임(🖼️ 와이어프레임)을 읽어줘.
forge 접속 불가 시 context/01_prd.md, context/02_wireframe.md 를 읽어줘.

명령:
forge.sh issue-comments <ISSUE_NUMBER>

기술 스펙을 작성해줘. **절 구성은 이 프로젝트의 스택에서 결정한다** —
`.claude/config.json` 의 `agent_hints`(없으면 `tech_stack`, 그것도 없으면 `.reviewer/profile.yaml`)를
먼저 읽고, 그 스택에 실제로 존재하는 것만 쓴다:

- API 명세 — 그 프레임워크의 관례로(FastAPI 라면 라우터·Pydantic, Hono/Express 라면 라우트 핸들러,
  Django 라면 뷰·시리얼라이저). **HTTP 계약(경로·메서드·요청/응답·상태코드)은 스택 무관하게 항상 쓴다.**
- 데이터 스키마 변경 + 마이그레이션 전략 — 그 ORM·DB 의 도구로(Alembic·Prisma·Drizzle·D1 마이그레이션 등).
  **스키마 변경이 없으면 "없음" 이라고 쓰고 절을 만들지 않는다.**
- 시퀀스 다이어그램 · 프론트엔드 연동 명세
- 그 스택에 해당 없는 항목은 **억지로 만들지 않는다** — 빈 절이 남으면 다음 사람이 그걸 채우려 한다.

기술 스펙 본문에 '## E2E 검증 시나리오' 절을 반드시 포함하라 (#118, #239).
각 시나리오 항목은 {ID, 사전조건, 스텝, 기대결과} 4필드에 더해 다음을 반드시 채운다:
  - 성공 판정 신호(관찰 가능·구체): 리다이렉트 URL / 노출 텍스트 / HTTP 상태 코드 /
    표시·사라짐 요소 중 최소 1개. "성공하면 된다" 식 모호 서술 금지.
  - 테스트 데이터: 구체 입력값(예: 상호="모두모 분식") + 부정/엣지 케이스 최소 1건
    (빈 값 / 중복 / 권한 없음 / 타 테넌트 격리 등).
  - 러너 중립 자연어: 사람·LLM 에이전트·구독 CLI 모두 따라갈 수 있는 순수 자연어로 서술.
    browser-use 전용 문법(액션 DSL, CSS 셀렉터 코드) 금지.
이 절은 STEP 4(dev-e2e)의 `.e2e-agent` 이미터 + Playwright 골격 양쪽 입력이 된다.

저장:
- forge 가용: 이슈 댓글로 등록 (## ⚙️ 기술 스펙)
- forge 불가: context/03_tech_spec.md 에 저장
```

---

## STEP 4 — E2E 테스트 코드 골격 작성 (`aiops:dev-e2e` 서브에이전트 **필수 호출**)

**반드시 `aiops:dev-e2e` 서브에이전트를 Agent 도구로 호출해야 합니다.**
tech-spec 직후, 병렬 구현(STEP 5) 이전에 단독 실행됩니다.

호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 댓글에서 다음을 읽어줘:
- PRD (## 📝 PRD)
- 기술 스펙 (## ⚙️ 기술 스펙) — 내부의 "## E2E 검증 시나리오" 절이 핵심 입력
- 와이어프레임 (## 🖼️ 와이어프레임)

forge 접속 불가 시: context/01_prd.md, 03_tech_spec.md, 02_wireframe.md

명령:
forge.sh issue-comments <ISSUE_NUMBER>

다음을 수행해줘:
0. **골격을 만들 것인지 먼저 판단한다.** 무조건 생성하면 E2E 배선이 없는 프로젝트에
   프레임워크 20여 파일이 이 PR 로 들어와 리뷰 범위가 오염된다(실측). 아래를 확인해 결정하라:
   - 이 변경이 **E2E 로 관측 가능한가** — UI·HTTP 응답·배포 산출물 중 하나라도 바뀌는가.
     테스트 헬퍼·픽스처 이동·내부 리팩터링처럼 배포물이 0바이트도 안 바뀌면 **E2E 대상이 없다.**
   - `.claude/config.json` 의 `e2e_test_enabled` 가 `false` 인가.
   - 이 레포에 이미 E2E 배선이 있는가(`playwright.config.*`·`tests/e2e/`·다른 러너).
   → **만들지 않기로 했으면** 두 마커 댓글에 "골격 생성 스킵: <사유>" 를 명시하고, 대신 그 변경을
     실제로 검증하는 **단위 테스트 케이스 목록**을 산출물로 남긴다. 게이트는 그것으로 통과시킨다.
     (억지 E2E 시나리오를 만들지 말 것 — 인과 없는 게이트는 다음 사람이 지운다.)
1. Q5 보호 로직: 기존 playwright.config.ts 또는 tests/e2e/playwright.config.ts 존재 시
   → tests/e2e/.devflow-hint.md 만 작성하고 골격 생성을 스킵 (덮어쓰기 금지)
2. 신규: ${CLAUDE_PLUGIN_ROOT}/templates/e2e/ 골격을 대상 프로젝트로 복사 → 도메인 토큰(라우트/엔티티) 치환
   → 18~21개 파일 생성/배치:
   - 루트 2개 (playwright.config.ts, global-setup.ts)
   - tests/e2e/ 1개 (README.md)
   - fixtures/ 3개 / pages/ 3개 / full/ 7개 / smoke/ 4개
3. 신규(#239): STEP 3 '## E2E 검증 시나리오' 표를 ${CLAUDE_PLUGIN_ROOT}/templates/e2e/agent/task.md.tmpl 기반으로
   `.e2e-agent/<route-slug>-<ID>.md` + `.e2e-agent/task.md`(대표/smoke 기본 진입점)로
   결정론적 렌더(템플릿 치환, LLM 자유생성 아님). Q5형 덮어쓰기 보호(첫 줄 서명 없는 사람
   편집 파일은 미덮음, 멱등). 산출 마커 `## 🧪 E2E 코드 작성 완료` 본문에
   `.e2e-agent 시나리오 N건` 라인을 추가한다. (#118 헤더 6종 자체는 불변)

산출물 (두 헤더 모두 등록):
- ## 🧪 E2E 시나리오 — 도메인/full 수/smoke 수/보호 동작 요약 (+ .e2e-agent 렌더 N건)
- ## 🧪 E2E 코드 작성 완료 — 생성 파일 수와 경로 목록 (+ .e2e-agent 시나리오 N건 라인)

저장:
- forge 가용: 위 두 헤더로 이슈 댓글 등록
- forge 불가: context/issue-<N>/04_e2e_plan.md, 05_e2e_scaffold.md 에 저장
```

---

## STEP 5 — Phase 2: 병렬 개발 (3개 서브에이전트 **동시 필수 호출**)

**반드시 `aiops:dev-designer`, `aiops:dev-backend`, `aiops:dev-frontend` 서브에이전트를 Agent 도구로 동시에 호출해야 합니다.**

> STEP 4에서 생성된 tests/e2e/ 골격을 입력 컨텍스트로 참조하여, 구현이 E2E 시나리오를 통과하도록 설계합니다.

### dev-designer 호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 댓글에서 기술 스펙(⚙️ 기술 스펙)과 와이어프레임(🖼️ 와이어프레임)을 읽어줘.
forge 접속 불가 시 context/02_wireframe.md, context/03_tech_spec.md 를 읽어줘.

UI 컴포넌트 스펙을 작성해줘 (HTML/CSS 명세, 디자인 토큰, 기존 디자인 시스템 조화).

저장:
- forge 가용: 이슈 댓글로 등록 (## 🎨 컴포넌트 스펙)
- forge 불가: context/06_component_spec.md 에 저장 (기존 호환: 04_component_spec.md 도 허용)
```

### dev-backend 호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 댓글에서 기술 스펙(⚙️ 기술 스펙)과 E2E 코드(🧪 E2E 코드 작성 완료)를 읽어줘.
forge 접속 불가 시 context/03_tech_spec.md, 05_e2e_scaffold.md 를 읽어줘.

백엔드를 구현해줘. **스택은 `agent_hints.backend` 에서 읽는다**(§동적 스택 적응) —
예: FastAPI+SQLAlchemy+Alembic+pytest / Hono+Drizzle+vitest / Django+ORM+pytest /
Express+Prisma+jest. 라우터·모델·마이그레이션·서비스 레이어·테스트를 **그 스택의 관례로** 만든다.
`agent_hints.backend` 가 `null` 이면(전용 백엔드가 없는 프로젝트) 그 사실을 산출물에 적고
프론트엔드/워커 쪽 서버 로직으로 대체한다 — FastAPI 를 새로 들이지 않는다.

단위 테스트 작성은 필수입니다. 모든 신규 라우터/서비스/모델에 대한 단위 테스트(그 스택의 러너)가
STEP 7 게이트를 통과해야 합니다. STEP 4 산출물(tests/e2e/ 골격)을 입력 컨텍스트로 참조하여,
구현이 E2E 시나리오를 통과하도록 설계해주세요.

저장:
- forge 가용: 구현 완료 내용을 이슈 댓글로 등록 (## 🔧 백엔드 구현 완료)
- forge 불가: context/06_be_done.md 에 저장 (기존 호환: 05_be_done.md 도 허용)
```

### dev-frontend 호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 댓글에서 기술 스펙(⚙️ 기술 스펙), 컴포넌트 스펙(🎨 컴포넌트 스펙),
E2E 코드(🧪 E2E 코드 작성 완료)를 읽어줘.
forge 접속 불가 시 context/03_tech_spec.md, 06_component_spec.md, 05_e2e_scaffold.md 를 읽어줘.

프론트엔드를 구현해줘 (Hono Workers 라우트, 뷰 컴포넌트, 백엔드 API 연동, vitest 테스트).

단위 테스트 작성은 필수입니다. vitest 기반 단위 테스트가 STEP 7 게이트를 통과해야 합니다.
STEP 4 산출물(tests/e2e/ 골격)을 입력 컨텍스트로 참조하여, 구현이 E2E 시나리오를 통과하도록 설계해주세요.

저장:
- forge 가용: 구현 완료 내용을 이슈 댓글로 등록 (## 💻 프론트엔드 구현 완료)
- forge 불가: context/06_fe_done.md 에 저장 (기존 호환: 06_fe_done.md 그대로 유지)
```

---

## STEP 6 — 환경 배포 (`aiops:dev-devops` 서브에이전트 **필수 호출**)

**반드시 `aiops:dev-devops` 서브에이전트를 Agent 도구로 호출해야 합니다.**
백엔드·프론트엔드 구현이 완료된 직후, QA 전에 실행합니다.

호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 댓글에서 백엔드 구현 완료(🔧)와 프론트엔드 구현 완료(💻)를 읽어줘.
forge 접속 불가 시 context/06_be_done.md, context/06_fe_done.md 를 읽어줘.

**선행 작업: config.json 설정 읽기**
아래를 먼저 실행하여 환경 변수를 설정해줘:
```bash
PROJECT_ROOT=$(jq -r '.project_root // "."' .claude/config.json 2>/dev/null || echo ".")
# 기본값을 true 로 두면 CF 를 쓰지 않는 레포에 CF 경로가 걸린다 — **감지값에서 파생**시킨다.
#   (/aiops:setup 이 deploy_target 을 채운다. 둘 다 없으면 false = 하지 않는 쪽이 안전하다.)
USE_CF=$(jq -r '
  if .use_cloudflare_workers != null then .use_cloudflare_workers
  elif (.agent_hints.frontend.deploy_target // .agent_hints.backend.deploy_target // "") == "cloudflare-workers" then true
  else false end' .claude/config.json 2>/dev/null || echo "false")
CF_DEV_URL=$(jq -r '.cf_dev_url // ""' .claude/config.json 2>/dev/null || echo "")
DOCKER_NETWORK=$(jq -r '.docker.network // "app_net"' .claude/config.json 2>/dev/null || echo "app_net")
BACKEND_IMAGE=$(jq -r '.docker.backend_image // "app-backend"' .claude/config.json 2>/dev/null || echo "app-backend")
DB_CONTAINER=$(jq -r '.docker.db_container // "app-postgres"' .claude/config.json 2>/dev/null || echo "app-postgres")
DB_USER=$(jq -r '.docker.db_user // "app"' .claude/config.json 2>/dev/null || echo "app")
DB_PASS=$(jq -r '.docker.db_password // "app"' .claude/config.json 2>/dev/null || echo "app")
DB_NAME=$(jq -r '.docker.db_name // "app"' .claude/config.json 2>/dev/null || echo "app")
if [[ "$USE_CF" != "true" ]] || [[ -z "$CF_DEV_URL" ]]; then
  echo "[스킵] CF Workers 미사용 — CF 배포 단계를 건너뜁니다."
fi
```

아래를 순서대로 실행해줘. **각 항목은 그 프로젝트에 해당할 때만 실행하고, 해당 없으면
"해당 없음: <사유>" 를 산출물에 명시한다** — 조용히 건너뛰지 않는다(그러면 안 한 것과 구별되지 않는다).

1. **DB 마이그레이션** — `use_docker`·`agent_hints.backend.orm` 과 실제 마이그레이션 디렉토리를 먼저 확인.
   신규 마이그레이션 파일이 있으면 **그 ORM 의 도구로** 적용한다(Alembic·Prisma·Drizzle·`wrangler d1 migrations` 등).
   ⚠️ 공유 DB(여러 서비스가 같은 인스턴스를 쓰는 경우)의 스키마 변경은 **배포 전 선적용**이 필요할 수 있다 —
   그 프로젝트 문서를 확인할 것.
2. **재빌드·재시작** — `use_docker=true` 면 변경된 서비스만 Docker 재빌드·재시작.
   Docker 를 쓰지 않는 프로젝트(서버리스·정적 배포 등)면 대신 **빌드가 깨지지 않는지** 확인한다
   (그 프로젝트의 빌드 명령 — `npm run build`·`cargo build` 등).
3. **헬스체크** — 로컬 실행체가 있으면 확인. 없으면(배포 후에만 관측 가능한 구조) 그 사실을 적는다.
4. QA 접속 URL 확인 — 없으면 "로컬 접속 대상 없음" 을 적는다.
5. **원격 배포 확인** — `USE_CF=true` 이고 dev URL 이 있을 때만 CI 배포 상태 + dev URL 헬스체크.
   그 외 배포 대상(Vercel·Fly·컨테이너 레지스트리 등)이면 같은 성격의 확인으로 대체한다.

⚠️ **이 단계에서 프로덕션에 배포하지 않는다.** dev/로컬 검증까지다.

작업 디렉토리: .claude/config.json의 project_root 값 (기본값: 현재 폴더 .)

저장:
- forge 가용: 배포 완료 내용을 이슈 댓글로 등록 (## 🚢 배포 완료)
- forge 불가: context/07_deploy.md 에 저장 (기존 호환: 07_devops_done.md 도 허용)
```

---

## STEP 7 — Phase 3: Unit QA (해당 레인을 **동시 호출**)

### 7-0. 레인 결정 — 3개 고정이 아니다

**어떤 레인이 존재하는지 먼저 판정한다.** 없는 레인을 부르면 에이전트가 빈손으로 돌거나
없는 러너를 찾다 실패한다(실측: 백엔드가 없는 프로젝트에서 qa-backend 가 매번 헛돌았다).

```bash
BE=$(jq -r '.agent_hints.backend.test_runner // empty' .claude/config.json 2>/dev/null)
FE=$(jq -r '.agent_hints.frontend.test_runner // empty' .claude/config.json 2>/dev/null)
ADMIN_DIR=$(jq -r '.paths.admin // "admin"' .reviewer/profile.yaml 2>/dev/null || echo admin)
LANES=""
[[ -n "$BE" ]] && LANES="$LANES backend"
[[ -n "$FE" ]] && LANES="$LANES frontend"
[[ -d "$ADMIN_DIR" ]] && LANES="$LANES admin"
# 하나도 없으면: 레포 루트의 테스트 명령(npm test·pytest·cargo test 등)을 단일 레인으로 잡는다.
[[ -z "${LANES// /}" ]] && LANES="root"
echo "[STEP 7] 레인: $LANES"
```

**존재하는 레인만** Agent 도구로 **동시에** 호출한다(`aiops:qa-backend`·`aiops:qa-frontend`·`aiops:qa-admin`).
`/aiops:qa-check` 스킬을 쓰면 이 판정을 대신 해 준다.

⚠️ 없는 레인은 **"해당 없음: 사유" 를 Sign-off 표에 적는다.** 조용히 빼면 커버리지가 준 것과 구별되지 않는다.

### qa-backend 호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 백엔드 QA 수행.

**먼저 러너를 확인한다** — `agent_hints.backend.test_runner`(pytest·jest·vitest·go test·cargo test …).
Docker 를 쓰지 않는 프로젝트면 아래 docker 블록은 건너뛰고 그 러너를 **로컬에서 직접** 실행한다.

Docker 를 쓰는 경우(`use_docker=true`)의 설정 읽기:
DOCKER_NETWORK=$(jq -r '.docker.network // "app_net"' .claude/config.json 2>/dev/null || echo "app_net")
BACKEND_IMAGE=$(jq -r '.docker.backend_image // "app-backend"' .claude/config.json 2>/dev/null || echo "app-backend")
DB_CONTAINER=$(jq -r '.docker.db_container // "app-postgres"' .claude/config.json 2>/dev/null || echo "app-postgres")
DB_USER=$(jq -r '.docker.db_user // "app"' .claude/config.json 2>/dev/null || echo "app")
DB_PASS=$(jq -r '.docker.db_password // "app"' .claude/config.json 2>/dev/null || echo "app")
DB_TEST=$(jq -r '.docker.test_db_name // "app_test"' .claude/config.json 2>/dev/null || echo "app_test")

Docker 테스트 실행 (러너가 pytest 인 경우의 예 — 다른 러너면 그에 맞게 바꾼다):
docker run --rm --network "$DOCKER_NETWORK" \
  -e DATABASE_URL=postgresql+asyncpg://${DB_USER}:${DB_PASS}@${DB_CONTAINER}:5432/${DB_TEST} \
  -e DATABASE_URL_SYNC=postgresql://${DB_USER}:${DB_PASS}@${DB_CONTAINER}:5432/${DB_TEST} \
  -e SECRET_KEY=test-secret-key \
  -v $(pwd)/aiops:backend:/app "$BACKEND_IMAGE" \
  pytest tests/ -v 2>&1 | tee /tmp/aiops:backend_test.txt

Sign-off 기준: FAILED=0
저장: FORGE_OK → 이슈 댓글 (## 🔬 Backend QA 결과) / FORGE_DOWN → context/08a_qa_backend.md
```

### qa-frontend 호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 프론트엔드 QA 수행.

cd frontend && npm test 2>&1 | tee /tmp/aiops:frontend_test.txt

Sign-off 기준: FAILED=0
저장: FORGE_OK → 이슈 댓글 (## 💻 Frontend QA 결과) / FORGE_DOWN → context/08b_qa_frontend.md
```

### qa-admin 호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 어드민 QA 수행.

cd admin && npm test 2>&1 | tee /tmp/admin_test.txt
(test 스크립트 없으면: cd admin && npx vitest run)

Sign-off 기준: FAILED=0
저장: FORGE_OK → 이슈 댓글 (## 🛠️ Admin QA 결과) / FORGE_DOWN → context/08c_qa_admin.md
```

### Sign-off 게이트 #1 (STEP 7 → STEP 8)

**존재하는 레인만** 표에 넣고, 없는 레인은 `해당 없음: <사유>` 로 적는다.

| 항목 | 기준 | 결과 |
|------|------|------|
| Backend (그 스택의 러너) | FAILED=0 | ✅/❌/해당 없음 |
| Frontend (그 스택의 러너) | FAILED=0 | ✅/❌/해당 없음 |
| Admin (있는 경우) | FAILED=0 | ✅/❌/해당 없음 |

- **PASS** (모든 ✅) → **STEP 8 진입** (로컬 E2E)
- **FAIL** (하나라도 ❌) → 해당 dev-backend 또는 dev-frontend 재호출 → STEP 6(재배포) → STEP 7 재실행
- 산출물 헤더: `## ✅ Unit QA Sign-off` (PASS) / `## ❌ Unit QA FAIL` (FAIL)

저장:
- forge 가용: 이슈 댓글로 등록 (## ✅ Unit QA Sign-off 또는 ## ❌ Unit QA FAIL)
- forge 불가: context/08_qa_signoff.md 에 저장

---

## STEP 8 — 로컬 E2E 자동 실행 (`/aiops:e2e-test` 스킬 또는 `aiops:qa-e2e` 에이전트 — config 토글)

STEP 7 Sign-off PASS를 확인한 후 진입합니다.

### 8-0. config 토글 게이트 (#131 신규)

진입 즉시 `.claude/config.json` 의 `e2e_devflow_step8_enabled` 를 읽어 자동 실행 여부를 결정합니다. **기본값은 `false`** 로, 시간이 오래 걸리는 로컬 E2E를 기본적으로 SKIP 처리합니다.

```bash
# §8-0.1 config 토글 읽기
STEP8_ENABLED=$(jq -r '.e2e_devflow_step8_enabled // false' .claude/config.json 2>/dev/null || echo false)

if [[ "$STEP8_ENABLED" != "true" ]]; then
  echo "[STEP 8] 로컬 E2E 자동 실행 비활성화됨 (config.json e2e_devflow_step8_enabled=false)"
  echo "         필요 시 /aiops:e2e-test --env=local --mode=full #$ISSUE_NUMBER 또는 /aiops:run-e2e 로 명시 실행"

  # SKIP 마커 등록 (게이트 #2 통과 — STEP 9 진입 허용)
  forge.sh issue-comment "$ISSUE_NUMBER" "## 🌐 로컬 E2E 결과 — full

E2E_RESULT=SKIPPED

- 사유: config.json \`e2e_devflow_step8_enabled=false\` (기본값)
- 게이트 #2: SKIP 으로 통과 처리 → STEP 9(PR 생성) 진입 허용
- 수동 실행 가이드:
  - \`/aiops:e2e-test --env=local --mode=full #$ISSUE_NUMBER\` — 로컬 환경에서 full 실행
  - \`/aiops:run-e2e\` — 현재 브랜치에 맞는 환경/모드 자동 선택
- 활성화 방법: \`.claude/config.json\` 에 \`\"e2e_devflow_step8_enabled\": true\` 설정"

  # STEP 9 으로 진행
  goto STEP_9
fi
# e2e_devflow_step8_enabled=true 인 경우 기존 흐름 그대로 진행
```

핵심 제약:
- SKIP 시에도 헤더 `## 🌐 로컬 E2E 결과 — full` 는 동일하게 사용 (#118 인터페이스 계약 보존).
- 본문 키만 `E2E_RESULT=SKIPPED` 로 구분 — `/aiops:merge-pr` / `/aiops:merge-main` 입장에서는 PASS 동등으로 취급 (PRD AC-1).
- 활성화(true)된 경우 아래 기존 §8-1 ~ §8-3 흐름이 그대로 실행됨.

### 8-1. 호출 패턴 (config 활성화 시)

호출 패턴:
```
/aiops:e2e-test --env=local --mode=full #<ISSUE_NUMBER>
```
또는 Agent 도구로 `aiops:qa-e2e` 에이전트 직접 호출 (env=local, mode=full, issue=<N>).

내부적으로 `aiops:qa-e2e` 에이전트가 호출되어:
1. Playwright 실행 (tests/e2e/full/ 전체)
2. 실패 시 스크린샷/trace 저장
3. 결과를 stdout 마지막 줄에 결정적 토큰으로 출력:
   - PASS: `E2E_RESULT=PASS`
   - FAIL: `E2E_RESULT=FAIL`
   - 환경 오류: `E2E_ENV_ERROR=<reason>`

오케스트레이터는 stdout 마지막 줄을 파싱하여 판정합니다.

종료 코드 약속:
- `0` = PASS
- `1` = FAIL
- `2` = 환경 설정 오류

산출물:
- 이슈 댓글 헤더: `## 🌐 로컬 E2E 결과 — full`
  본문에 `E2E_RESULT=PASS` 또는 `E2E_RESULT=FAIL` 토큰 + 시나리오별 결과 표 포함
- context fallback: `context/issue-<N>/09_local_e2e.md`

### Sign-off 게이트 #2 (STEP 8 → STEP 9)

- **PASS** (`E2E_RESULT=PASS`) → **STEP 9 진입** (PR 생성)
- **FAIL** (`E2E_RESULT=FAIL`) → 아래 재실행 루프 (최대 3회)
- **환경 오류** (`E2E_ENV_ERROR=<reason>`) → STEP 8 차단 + 사용자 가이드 표시:
  > Playwright 미설치 또는 baseURL 응답 없음. `npx playwright install` 후 재시도하거나
  > `.claude/config.json` 의 `e2e_local_url` 을 확인해주세요. `.env.test` 누락도 확인.

### STEP 8 FAIL 재실행 루프 (최대 3회)

1. 실패 시나리오 분석 (스크린샷/trace 첨부) → 이슈 댓글 추가
2. 원인 영역 판정 (Backend / Frontend / Both)
3. dev-backend 또는 dev-frontend (또는 둘 다 병렬) 재호출
4. STEP 6 재배포 → STEP 7 재Unit QA → STEP 8 재E2E
5. 매 재시도마다 헤더 `## 🌐 로컬 E2E 결과 — full (재시도 N/3)` 로 누적 기록
6. 3회 초과 시 자동 중단 + `## ⚠️ 자동 회복 실패` 댓글 등록 + 사용자 개입 요청

---

## STEP 9 — PR 생성 (`aiops:dev-pr` 서브에이전트 **필수 호출**)

> 진입 조건: 직전 STEP 8 댓글에 `E2E_RESULT=PASS` 또는 `E2E_RESULT=SKIPPED` (#131) 토큰이 존재해야 합니다. (`E2E_RESULT=DRY_RUN` 은 게이트 통과 신호가 아니다 — `SKIPPED` 는 devflow 자신이 의도적으로 등록하는 마커라 PASS 동등이지만, `DRY_RUN` 은 사람이 손으로 `--dry-run` 을 돌린 흔적이라 통과가 아니다. #49)
> PR 생성 완료 후 반드시 STEP 10(리뷰)을 이어서 실행해야 합니다.

**반드시 `aiops:dev-pr` 서브에이전트를 Agent 도구로 호출해야 합니다.**

호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 의 본문/댓글을 읽어줘:
forge.sh issue-view <ISSUE_NUMBER>
forge.sh issue-comments <ISSUE_NUMBER>

댓글에서 구현 내용을 파악하고 PR을 생성해줘.
forge 접속 불가 시 context/ 디렉토리 파일들을 읽어줘.

ISSUE_NUMBER: <ISSUE_NUMBER>
BRANCH: feature/issue-<ISSUE_NUMBER>

feature/issue-<ISSUE_NUMBER> 브랜치에서 dev로 PR을 만들고, Closes #<ISSUE_NUMBER> 포함.
(해당 브랜치가 이미 origin에 push되어 있음)

저장:
- forge 가용: PR URL을 이슈 댓글로 등록 (## 🚀 PR 생성 완료)
- forge 불가: context/10_pr.md 에 저장
```

> ⚠️ feature 브랜치 전략에서는 **이슈를 수동으로 close하지 않습니다**.
> PR 본문의 `Closes #N` 키워드가 PR merge 시 자동으로 이슈를 close합니다.

---

## STEP 10 — PR 리뷰 (`review-pr` 스킬 **필수 실행**)

**반드시 `/aiops:review-pr` 스킬을 실행해야 합니다.**

STEP 9에서 생성된 PR 번호를 인자로 전달:

```
/aiops:review-pr <PR_NUMBER> ISSUE_NUMBER:<ISSUE_NUMBER>
```

- PR diff 전체 분석 (보안 / 품질 / 아키텍처 / 테스트 체크리스트)
- 판정:
  - **APPROVE**: P0 이슈 없음 → `forge.sh pr-review <PR> APPROVE`
    - Gitea 는 `REVIEWER_TOKEN`(env→KMS) 이 해석되면 `STATE=APPROVED`, 해석되지 않으면 self-approve→`STATE=COMMENTED` 로 강등되며 **어느 쪽도 STEP 10 통과로 간주**한다(이슈 #28).
  - **REQUEST_CHANGES**: P0 이슈 발견 → `forge.sh pr-review <PR> REQUEST_CHANGES` → dev-backend/dev-frontend 재호출 → STEP 6(재배포) → STEP 7(재Unit QA) → STEP 8(재E2E) → STEP 9(PR 업데이트) → STEP 10(재리뷰)
  - **COMMENT**: 권고사항만 → `forge.sh pr-review <PR> COMMENT`
- 인라인 코멘트: 구체적 수정 위치가 있으면 파일/라인 지정하여 등록
- 결과를 이슈 댓글로 등록 (## 🔍 PR 리뷰 완료) 및 `context/11_review.md` 저장

---

## 전체 흐름 요약

```
STEP 0    오케스트레이터  인자 파싱 + (이슈 없으면 자동 생성) + feature/issue-N 브랜치 생성 + context 처리
STEP 1    오케스트레이터  브리프 작성 (📋)
             ↓ 저장: GH 댓글(📋) 또는 context/00_brief.md
STEP 2    [planning]      PRD + 와이어프레임 (📝 🖼️)
             ↓ 저장: GH 댓글 또는 context/01,02
STEP 3    [dev]           기술 스펙 (⚙️) — 내부 "## E2E 검증 시나리오" 절 의무
             ↓ 저장: GH 댓글 또는 context/03_tech_spec.md
STEP 4    [dev-e2e]       E2E 코드 골격 (🧪 시나리오 + 🧪 코드 작성 완료)               ← NEW
             ↓ 저장: GH 댓글 또는 context/04_e2e_plan.md, 05_e2e_scaffold.md
STEP 5    [dev-designer]  컴포넌트 스펙       ─┐
          [dev-backend]   백엔드 구현          ─┤ 동시 실행 (단위 테스트 필수)
          [dev-frontend]  프론트엔드 구현      ─┘
             ↓ 저장: GH 댓글(🎨 🔧 💻) 또는 context/06_*
STEP 6    [dev-devops]    DB 마이그레이션 + 재빌드 + 헬스체크
             ↓ 저장: GH 댓글(🚢) 또는 context/07_deploy.md
STEP 7    [qa-backend] Backend 단위테스트        ─┐
          [qa-frontend] Frontend 단위테스트       ─┤ **존재하는 레인만** 동시 실행 (게이트 #1)
          [qa-admin]   Admin 단위테스트          ─┘  (러너는 agent_hints 에서)
             ↓ 저장: GH 댓글(🔬 💻 🛠️ ✅/❌) 또는 context/08a,08b,08c,08
             ↓ PASS → STEP 8 / FAIL → 재배포 루프 (dev-be/fe → STEP 6 → STEP 7)
STEP 8    /aiops:e2e-test       로컬 E2E full (🌐) — config 토글 (#131)
             ↓ e2e_devflow_step8_enabled=false (기본) → SKIPPED 마커 등록 → STEP 9
             ↓ e2e_devflow_step8_enabled=true → 기존 흐름 (PASS 게이트 #2)
             ↓ 저장: GH 댓글(🌐) 또는 context/09_local_e2e.md
             ↓ PASS → STEP 9 / FAIL → 재실행 루프 (최대 3회) / SKIPPED → STEP 9 (#131)
STEP 9    [dev-pr]        PR 생성 → 이슈 자동 close (Closes #N)
             ↓ 저장: GH 댓글(🚀) 또는 context/10_pr.md
STEP 10   /aiops:review-pr      PR 코드 리뷰 → approve/request-changes/comment
             ↓ 저장: GH PR 리뷰 댓글(🔍) 및 context/11_review.md
             ↓ REQUEST_CHANGES → dev-backend/aiops:frontend 재호출 → STEP 6 재시작
```

**forge 장애 시:**
```
정상 흐름과 동일하나 모든 저장이 context 파일로 대체됨
archive 폴더: context/archive/issue-<ISSUE_NUMBER>/

복구 후:
context 파일들 → forge.sh issue-comment 로 일괄 동기화 → context 파일 삭제
```

> 🔗 bugflow는 본 이슈 범위 외입니다. `skills/aiops:bugflow/SKILL.md`의 STEP 동기화는
> 별도 후속 이슈에서 처리됩니다 (PRD S1).

---

## 인터페이스 계약 (후속 이슈 보호)

본 이슈(#118) 머지 후 변경 불가 항목 — 후속 이슈 #119(merge-pr), #120(/aiops:merge-main), #121(/aiops:deploy-prod), #122(update-docs)가 이 계약에 의존합니다.

| 항목 | 고정 값 | 의존 이슈 |
|------|---------|----------|
| STEP 번호 | STEP 0~10 (총 11) | #119, #120, #121, #122 |
| STEP 4 호출 에이전트 | `aiops:dev-e2e` | #122 |
| STEP 8 호출 명령 | `/aiops:e2e-test --env=local --mode=full #<N>` | #120, #121 |
| STEP 9 = PR 생성 STEP | 고정 | #119 |
| STEP 10 = 리뷰 STEP | 고정 | #119 |
| 헤더 6종 | `## 🧪 E2E 시나리오`, `## 🧪 E2E 코드 작성 완료`, `## ✅ Unit QA Sign-off`, `## 🌐 로컬 E2E 결과 — full`, `## 🚀 PR 생성 완료`, `## 🔍 PR 리뷰 완료` | #119, #122 |
| Sign-off 토큰 | `E2E_RESULT=PASS` (STEP 8 본문 내 정확 매칭) | #119, #120 |
| context 파일명 신규 | `04_e2e_plan.md`, `05_e2e_scaffold.md`, `09_local_e2e.md` | #122 |

### context 파일명 매트릭스 (옵션 A)

| STEP | 산출물 | fallback 파일명 |
|------|--------|----------------|
| 1 | 브리프 | `00_brief.md` |
| 2 | PRD / 와이어프레임 | `01_prd.md` / `02_wireframe.md` |
| 3 | 기술 스펙 | `03_tech_spec.md` |
| 4 | E2E 코드 작성 | `04_e2e_plan.md` + `05_e2e_scaffold.md` |
| 5 | 컴포넌트/be/fe 구현 | `06_component_spec.md` / `06_be_done.md` / `06_fe_done.md` (기존 `04`/`05` 호환) |
| 6 | 배포 | `07_deploy.md` (기존 `07_devops_done.md` 호환) |
| 7 | Unit QA | `08a_qa_backend.md` / `08b_qa_frontend.md` / `08c_qa_admin.md` / `08_qa_signoff.md` |
| 8 | 로컬 E2E | `09_local_e2e.md` |
| 9 | PR | `10_pr.md` |
| 10 | 리뷰 | `11_review.md` |

변경 시 영향: 위 표의 모든 항목은 후속 이슈가 grep/파싱으로 의존하므로 본 이슈 머지 후 변경 시 후속 이슈를 함께 갱신해야 합니다.

---

현재 제공된 인자: $ARGUMENTS

위 절차대로 STEP 0부터 순서대로 진행해줘.
