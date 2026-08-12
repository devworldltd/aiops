---
name: review-pr
description: "PR 코드 리뷰 실행. 리뷰 프로필 자동 탐색 → 프로필 기반 체크리스트로 PRD 요구사항/코드 컨벤션 검증. 프로필 없으면 폴백 모드(diff 기반 범용 체크). LGTM이면 approve, 수정 필요 시 request changes."
---

PR 코드 리뷰를 수행하고 결과를 PR 댓글로 등록한다.

> **forge 도구 규약**: 이슈/PR 조작은 `gh` 대신 forge 중립 헬퍼 `forge.sh`(origin 리모트로 GitHub↔Gitea 자동감지)를 **실행**한다. 아래 문서에선 `forge.sh <sub>` 로 표기하지만 실제 호출은 항상 절대경로 실행형이다: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" <sub> ...` (소싱 금지 — 호출 셸이 zsh 여도 bash 문법이 유지되어야 한다). forge.sh 는 origin 자동감지라 `--repo` 인자가 불필요하다. 인증(Gitea 토큰/CF Access)은 forge.sh 가 처리하므로 스킬에서 토큰을 직접 다루지 않는다.

---

## 0. 리뷰 프로필 로딩 (가장 먼저 실행)

이 스킬은 어떤 프로젝트에 설치되어 있든 해당 프로젝트의 **리뷰 프로필**을 먼저 읽어서 체크리스트와 스택 정보를 결정한다. 하드코딩 레포/경로/스택을 사용하지 않는다.

### 0-1. 프로필 탐색 우선순위

```
1. <cwd>/.reviewer/profile.yaml            ← 있으면 가장 우선
2. <cwd>/CLAUDE.md 안의 "## Reviewer Profile" 섹션 YAML 블록
3. reviewer 서비스 config.yaml의 해당 리포 profile 필드
   (경로: $REVIEWER_CONFIG_PATH → ~/.config/reviewer/config.yaml → /etc/reviewer/config.yaml)
4. 자동 감지 폴백 (git remote + 파일 구조 휴리스틱)
```

### 0-2. 탐색 실행

```bash
# 1순위
test -f .reviewer/profile.yaml && cat .reviewer/profile.yaml

# 2순위 (1순위 없을 때)
# CLAUDE.md에서 "## Reviewer Profile" 섹션 추출 — Read 도구로 파일 읽어 파싱

# 3순위 (1·2 모두 없을 때)
REVIEWER_CONFIG=""
for CONFIG_PATH in \
    "${REVIEWER_CONFIG_PATH}" \
    "${HOME}/.config/reviewer/config.yaml" \
    "/etc/reviewer/config.yaml"; do
    if [[ -n "$CONFIG_PATH" && -f "$CONFIG_PATH" ]]; then
        REVIEWER_CONFIG="$CONFIG_PATH"
        break
    fi
done

if [[ -n "$REVIEWER_CONFIG" ]]; then
    REPO=$("${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" repo 2>/dev/null)
    if command -v yq &>/dev/null; then
        PROFILE_NAME=$(yq ".repos[] | select(.name == \"$REPO\") | .profile" "$REVIEWER_CONFIG" 2>/dev/null)
    else
        PROFILE_NAME=$(python3 -c "
import yaml, sys
data = yaml.safe_load(open('$REVIEWER_CONFIG'))
repos = data.get('repos', [])
match = next((r for r in repos if r.get('name') == '$REPO'), None)
print(match.get('profile', '') if match else '')
" 2>/dev/null)
    fi
    # profiles: 섹션에서 $PROFILE_NAME 키로 프로필 로드
fi

# 4순위 (모두 없을 때) — 폴백 (명시적 기본값)
REPO=$("${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" repo)
# structure 는 파일 구조로 추정:
#   - .gitmodules 있으면 monorepo-submodules
#   - packages/ 또는 apps/ 있으면 monorepo
#   - 그 외 single
# 폴백 기본값:
STACK_BACKEND=none
STACK_FRONTEND=none
STACK_ADMIN=none
PRD_SOURCE=none
MAX_DIFF_LOC=1500
```

> 폴백 모드에서는 스택 프리셋이 모두 `none`이므로 범용 체크리스트 + 공통 보안만 적용된다. PRD 검증도 건너뛴다.

### 0-3. 프로필 스키마

```yaml
repo: owner/name              # 생략 시 git remote 자동 감지
structure: single             # single | monorepo | monorepo-submodules
paths:                        # monorepo* 일 때만 사용
  backend: backend
  frontend: frontend
  admin: admin
stack:
  backend: fastapi-sqlalchemy # fastapi-sqlalchemy | fastapi-sqlite | none
  frontend: hono-ts           # hono-ts | nextjs | none
  admin: hono-ts              # hono-ts | nextjs | none
prd_source: github-issue      # github-issue | none
max_diff_loc: 1500
```

프로필 값을 다음 변수로 메모리에 유지한다:
- `REPO` (예: `owner/name`)
- `STRUCTURE`
- `PATHS_BACKEND`, `PATHS_FRONTEND`, `PATHS_ADMIN`
- `STACK_BACKEND`, `STACK_FRONTEND`, `STACK_ADMIN`
- `PRD_SOURCE`
- `MAX_DIFF_LOC`

forge.sh 는 origin 자동감지라 `--repo` 인자가 필요 없다. `REPO` 는 표시/로그용으로만 유지한다.

### 0-4. 프리셋 파일 로딩

스택 값에 따라 스킬 디렉토리 내 프리셋 파일을 Read 도구로 읽어 체크리스트를 구성한다:

```
presets/backend-${STACK_BACKEND}.md       # 예: backend-fastapi-sqlalchemy.md
presets/frontend-${STACK_FRONTEND}.md     # 예: frontend-hono-ts.md
presets/frontend-${STACK_ADMIN}.md        # admin도 같은 프리셋 풀 공유
presets/common-security.md                # 항상 로드
```

지원하지 않는 값(`none` 포함)이면 해당 범주의 `-none.md` 프리셋을 사용.

---

## 1. 입력 파싱

`$ARGUMENTS`에서 추출:
- `PR:<숫자>` 또는 첫 번째 숫자 → `PR_NUMBER`
- `ISSUE_NUMBER:<숫자>` 또는 두 번째 숫자 → `ISSUE_NUMBER` (선택)

```bash
# PR 메타(제목/본문/브랜치/증감 라인 등) JSON
forge.sh pr-view $PR_NUMBER
```

### 1-1. diff 크기 점검

```bash
# forge.sh pr-view JSON 의 additions/deletions 합산
TOTAL_LOC=$(forge.sh pr-view $PR_NUMBER | python3 -c "import json,sys;d=json.load(sys.stdin);print((d.get('additions') or 0)+(d.get('deletions') or 0))")
```

`TOTAL_LOC > MAX_DIFF_LOC` 이면 리뷰 본문 상단에 요약 모드 경고 표시:
```
⚠️ 이 PR은 ${TOTAL_LOC} LOC로 기준(${MAX_DIFF_LOC})을 초과합니다.
파일별 상세 리뷰가 생략될 수 있으니 핵심 파일 위주로 검토하세요.
```

---

## 2. PRD 요구사항 수집 (`prd_source` 분기)

### `prd_source: github-issue` 일 때

```bash
# 이슈 전 댓글 본문 (마커 헤더 검색용)
forge.sh issue-comments $ISSUE_NUMBER
```

댓글에서 `## 📝 PRD`, `## ⚙️ 기술 스펙` 헤더를 찾아 다음을 추출:
- Must 요구사항 목록
- 수용 기준(AC) 목록
- API 명세 (엔드포인트, 요청/응답 스키마)
- DB 스키마 변경 내용

### `prd_source: none` 일 때

PRD 검증 표는 "해당 없음"으로 건너뛴다. 대신 PR 본문·커밋 메시지·이슈 본문(있으면)으로부터 스코프만 파악한다.

---

## 3. 변경 코드 수집 (`structure` 분기)

### `structure: single`

```bash
forge.sh pr-diff $PR_NUMBER --name-only
forge.sh pr-diff $PR_NUMBER
```

변경 파일을 Read 도구로 직접 읽어 확인.

### `structure: monorepo`

```bash
forge.sh pr-diff $PR_NUMBER --name-only
```

파일 경로 접두사(`$PATHS_BACKEND/`, `$PATHS_FRONTEND/`, `$PATHS_ADMIN/`)로 범주 분류 후 해당 디렉토리만 읽음.

### `structure: monorepo-submodules`

서브모듈 커밋이 PR에 포함된 경우:

```bash
# PR 대상 브랜치와 비교해 변경된 서브모듈 경로 확인
git diff ${BASE_REF}...HEAD --name-only

# 각 서브모듈 디렉토리로 진입해 git log/diff 확인
cd $PATHS_BACKEND && git log --oneline ${BASE_REF}..HEAD && git diff ${BASE_REF}...HEAD
cd $PATHS_FRONTEND && git log --oneline ${BASE_REF}..HEAD && git diff ${BASE_REF}...HEAD
```

---

## 4. PRD 요구사항 검증 (`prd_source: none` 이면 전체 스킵)

### Must 요구사항 충족 여부
각 Must 항목에 대해 코드에서 구현 여부를 확인하고 ✅/❌ 표시.

### 수용 기준(AC) 충족 여부
각 AC 항목에 대해 코드/테스트에서 검증 여부 확인.

### API 스펙 일치 여부
- PRD/기술 스펙의 API 명세와 실제 라우터/스키마 코드 비교
- 요청 필드 누락, 응답 필드 불일치, HTTP 메서드/경로 오류 체크
- **`/health` deployed_sha 확인**: 백엔드 서비스가 있으면 `/health` 응답에 `status` + `deployed_sha` 가 포함되고, 빌드 주입 SHA(환경변수 등)를 반영하는지 확인. 누락 시 배포 검증(merge-pr/aiops:deploy-prod)의 SHA 매칭이 타임아웃으로 실패한다. 표준 계약: `/aiops:merge-pr` SKILL.md §15.

### DB 스키마 일치 여부
- 기술 스펙의 컬럼 정의와 모델/마이그레이션 코드 비교 (백엔드 스택이 DB를 쓰는 경우만)

---

## 5. 코드 컨벤션 체크 (프리셋 주입)

0-4 단계에서 로드한 프리셋 파일의 체크리스트를 그대로 적용한다. 프리셋은 아래 우선순위로 선택된다:

| 범주 | 프리셋 선택 | 해당 경로 (monorepo*) |
|------|-------------|---------------------|
| 백엔드 | `presets/backend-${STACK_BACKEND}.md` | `$PATHS_BACKEND` 하위 변경 |
| 프론트엔드 | `presets/frontend-${STACK_FRONTEND}.md` | `$PATHS_FRONTEND` 하위 변경 |
| 어드민 | `presets/frontend-${STACK_ADMIN}.md` | `$PATHS_ADMIN` 하위 변경 |

해당 범주 변경이 없으면 그 프리셋은 검사하지 않는다 (예: 백엔드 변경 없는 PR은 backend 프리셋 생략).

---

## 6. 보안 체크

`presets/common-security.md` 내용을 적용한다. 스택 무관 공통 체크.

---

## 7. 리뷰 결과 판정

| 등급 | 설명 | 판정 |
|------|------|------|
| P0 | 보안 취약점, 데이터 손실, 인가 우회, Must 요구사항 미구현 | REQUEST_CHANGES |
| P1 | 컨벤션 위반 (아키텍처, 네이밍), 테스트 누락, AC 미충족 | REQUEST_CHANGES |
| P2 | 개선 권고 (DRY, 가독성 등) | COMMENT (머지 블로킹 없음) |
| 없음 | 모든 체크리스트 통과 | APPROVE |

### P2 항목 수집

판정과 무관하게, 리뷰 중 발견된 P2 항목 전체를 P2_LIST 변수에 수집한다.

```
REVIEW_DATE=$(date '+%Y-%m-%d')
P2_LIST = []
CREATED_ISSUE_REFS = []   # 성공 시 "#<번호>" 형식으로 추가
FAILED_ISSUE_REFS  = []   # 실패 시 "생성 실패: <summary>" 형식으로 추가

# review_findings: §5(컨벤션) 및 §6(보안) 체크 단계에서 수집된 모든 발견 사항 목록
for each finding in review_findings:
    if finding.grade == "P2":
        P2_LIST.append({
            summary: finding.summary,   # 50자 이내
            file:    finding.file,      # 파일 경로
            line:    finding.line,      # 라인 번호 또는 범위
            detail:  finding.detail,    # 상세 설명
            suggest: finding.suggest    # 수정 방향
        })
```

---

## 8-A. P2 이슈 자동 등록

§7에서 수집한 P2_LIST를 순회하여 항목별로 이슈를 자동 생성한다 (`forge.sh issue-create`).
이슈 생성 실패 시 플로우를 중단하지 않고 FAILED_ISSUE_REFS에 기록 후 계속 진행한다.

P2_LIST가 비어 있으면 이 단계 전체를 생략하고 §8로 넘어간다.

> ⚠️ 라벨 처리: forge.sh issue-create `--label` 은 GitHub 이면 라벨명, Gitea 이면 **숫자 라벨 ID** 만 반영한다(비숫자 라벨명은 무시됨). 라벨 없이도 생성은 성공하므로, 라벨 지정으로 실패하면 라벨 없이 재시도한다.

```
if len(P2_LIST) > 0:
    for each p2 in P2_LIST:
        P2_SUMMARY=${p2.summary}
        P2_FILE=${p2.file}
        P2_LINE=${p2.line}
        P2_DETAIL=${p2.detail}
        P2_SUGGEST=${p2.suggest}
        PR_URL=$(forge.sh pr-url $PR_NUMBER)
        ISSUE_BODY = """
## 개요
PR #$PR_NUMBER 코드 리뷰에서 발견된 P2(개선 권고) 사항입니다.

## 위치
- 파일: `$P2_FILE`
- 라인: `$P2_LINE`

## 내용
$P2_DETAIL

## 권고 사항
$P2_SUGGEST

## 참고
- 원본 PR: $PR_URL
- 리뷰 일시: $REVIEW_DATE
- 등급: P2 (개선 권고 — 머지 블로킹 없음)
"""

        try:
            # 레이블 포함 1차 시도 (→ ISSUE_NUMBER=.. ISSUE_URL=..)
            RESULT=$(forge.sh issue-create \
                "[권고] $P2_SUMMARY" \
                "$ISSUE_BODY" \
                --label "p2,tech-debt,review-suggestion")
            ISSUE_NUMBER_CREATED=$(echo "$RESULT" | sed -nE 's/.*ISSUE_NUMBER=([0-9]+).*/\1/p')
            if [[ -n "$ISSUE_NUMBER_CREATED" ]]:
                CREATED_ISSUE_REFS += "#$ISSUE_NUMBER_CREATED"
            else:
                raise  # 아래 재시도로

        catch (레이블 미반영/생성 실패):
            # 레이블 없이 1회 재시도
            RESULT=$(forge.sh issue-create \
                "[권고] $P2_SUMMARY" \
                "$ISSUE_BODY")
            ISSUE_NUMBER_CREATED=$(echo "$RESULT" | sed -nE 's/.*ISSUE_NUMBER=([0-9]+).*/\1/p')
            if [[ -n "$ISSUE_NUMBER_CREATED" ]]:
                CREATED_ISSUE_REFS += "#$ISSUE_NUMBER_CREATED"
            else:
                FAILED_ISSUE_REFS += "생성 실패: $P2_SUMMARY"

        catch (기타 오류):
            FAILED_ISSUE_REFS += "생성 실패: $P2_SUMMARY"
            # 다음 항목으로 계속 진행 (플로우 중단 없음)
```

이슈 생성 실패가 있어도 §8 PR 리뷰 댓글 등록 / §9 저장 / §10 머지 흐름은 반드시 실행된다.

---

## 8. PR에 리뷰 등록

### 전체 리뷰 코멘트

판정에 따라 forge.sh pr-review 의 verdict 인자를 넣는다 (`APPROVE` | `REQUEST_CHANGES` | `COMMENT`). 본문이 길면 `@파일` 형태로 전달해도 된다.

```bash
forge.sh pr-review $PR_NUMBER APPROVE \
  "## 🔍 코드 리뷰 결과

[요약 모드 경고 — MAX_DIFF_LOC 초과 시만]

### 프로필
- 레포: $REPO
- 구조: $STRUCTURE
- 스택: backend=$STACK_BACKEND, frontend=$STACK_FRONTEND, admin=$STACK_ADMIN
- PRD 소스: $PRD_SOURCE

### PRD 요구사항 검증
[prd_source: github-issue 일 때만 Must/AC 표, none이면 '해당 없음']

### 코드 컨벤션
[프리셋별 체크 결과 — 범주에 변경이 있는 항목만]

### 보안
[공통 보안 체크 결과]

### 발견 사항
| 등급 | 위치 | 설명 | 권고 | 이슈 |
|------|------|------|------|------|
[P0/P1 행: 이슈 컬럼 '-' 표기]
[P2 행: CREATED_ISSUE_REFS에서 해당 이슈 번호 삽입 (예: '#83'), 이슈 생성 실패 시 '이슈 생성 실패' 표기]
[발견 사항 없으면 '없음']

### 결론
LGTM ✅ — 모든 요구사항 충족, 컨벤션 준수"
```

판정별 verdict 인자 (forge.sh pr-review 두 번째 인자):
- APPROVE: `APPROVE`
- REQUEST_CHANGES: `REQUEST_CHANGES`
- COMMENT: `COMMENT`

> ⚠️ 자기 PR APPROVE: Gitea 는 자기 PR 을 APPROVE 할 수 없어 forge.sh 가 자동으로 COMMENT 로 강등한다(경고만 출력). 따라서 APPROVE 판정이어도 자기 PR 은 COMMENT 리뷰로 등록되는 것이 정상이며, 머지 진행에는 영향을 주지 않는다.

### 인라인(라인-레벨) 코멘트

라인-레벨 인라인 코멘트는 forge.sh 미지원이다. **P0/P1 발견 사항의 파일·라인은 위 요약 리뷰 본문의 "발견 사항" 표에 함께 기재**하고, 필요 시 Gitea 웹 리뷰 UI 에서 수동으로 인라인 코멘트를 남긴다. (즉 인라인 코멘트는 요약 코멘트 또는 Gitea 웹 리뷰로 대체한다.)

---

## 9. 결과 저장

### `context/10_review.md` (로컬 사본)

```markdown
# PR 리뷰 결과
작성자: 코드 리뷰어
작성일시: [오늘 날짜]
PR: #<PR_NUMBER>
이슈: #<ISSUE_NUMBER>
판정: APPROVE / REQUEST_CHANGES / COMMENT
P2 이슈 생성: #83, #84   (없으면 '없음')
P2 이슈 생성 실패: 생성 실패: ...   (실패가 있을 때만 기재)
상태: DONE

프로필:
- 레포: $REPO
- 구조: $STRUCTURE
- 스택: backend=$STACK_BACKEND, frontend=$STACK_FRONTEND, admin=$STACK_ADMIN
- PRD 소스: $PRD_SOURCE

---

[본문은 § 8과 동일 구조]
```

### 이슈 댓글 (ISSUE_NUMBER가 있고 forge 가용 시)

```bash
forge.sh issue-comment $ISSUE_NUMBER \
  "## 🔍 PR 리뷰 완료

PR #$PR_NUMBER 판정: [APPROVE/REQUEST_CHANGES/COMMENT]

[요약]"
```

---

## 10. 자동 머지 (설정에 따라)

판정이 APPROVE일 때, `.claude/config.json`의 `auto_merge_to_dev`를 확인한다:

```bash
AUTO_MERGE=$(jq -r '.auto_merge_to_dev // false' .claude/config.json 2>/dev/null)
```

`true`이면:

```bash
# feature→dev 머지는 브랜치 삭제 동반 (→ MERGED=1)
forge.sh pr-merge $PR_NUMBER --delete-branch

CF_DEV_URL=$(jq -r '.cf_dev_url // ""' .claude/config.json)

forge.sh issue-comment $ISSUE_NUMBER \
  "## ✅ dev 머지 완료

PR #$PR_NUMBER이 dev 브랜치에 머지되었습니다.

### 테스트 환경
- dev URL: ${CF_DEV_URL:-(설정 필요)}
- 배포: CI(Gitea Actions)에 의해 자동 배포 진행 중

사용자 테스트 완료 후 main 승격을 진행해주세요."
```

`false`거나 설정 없으면 자동 머지를 건너뛴다.

---

## 탐색 예시 — 빠른 참조

```bash
# 프로필 로드 예시 (bash + yq)
if [[ -f .reviewer/profile.yaml ]]; then
  REPO=$(yq '.repo // ""' .reviewer/profile.yaml)
  STRUCTURE=$(yq '.structure // "single"' .reviewer/profile.yaml)
  STACK_BACKEND=$(yq '.stack.backend // "none"' .reviewer/profile.yaml)
  STACK_FRONTEND=$(yq '.stack.frontend // "none"' .reviewer/profile.yaml)
  STACK_ADMIN=$(yq '.stack.admin // "none"' .reviewer/profile.yaml)
  PRD_SOURCE=$(yq '.prd_source // "none"' .reviewer/profile.yaml)
  MAX_DIFF_LOC=$(yq '.max_diff_loc // 1500' .reviewer/profile.yaml)
fi

# repo 미지정 시 자동 감지
[[ -z "$REPO" ]] && REPO=$("${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" repo)
```

`yq`가 없으면 Read 도구로 파일 내용을 읽어 직접 파싱해도 된다.

---

$ARGUMENTS
