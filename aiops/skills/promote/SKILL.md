---
name: promote
description: "Dev → Main 프로모션. dev 브랜치를 main으로 병합하는 PR을 생성하거나 기존 PR을 확인. 자동 병합하지 않음 (수동 승인 필요)."
---

> ⚠️ **DEPRECATED — 본 스킬은 #120 부터 deprecated 입니다.**
>
> dev → main 승격은 **`/aiops:merge-main`** 을 사용하세요.
>
> | 항목 | `/aiops:promote` (deprecated) | `/aiops:merge-main` (권장) |
> |------|------------------------|---------------------|
> | dev → main PR 생성 | ✅ | ✅ |
> | dev E2E PASS 마커 검증 | ❌ | ✅ (#119 마커 4종) |
> | 자동 머지 | ❌ (수동 필요) | ✅ (`--merge`, dev 브랜치 보존) |
> | `main_sha` 이슈 댓글 기록 | ❌ | ✅ (#121 `/aiops:deploy-prod` 소비) |
> | `/aiops:deploy-prod` 다음 단계 안내 | ❌ | ✅ |
>
> 마이그레이션: `/aiops:promote` 사용처를 `/aiops:merge-main` 으로 교체하세요. 본 스킬은 호환성을 위해 #122 완료 시까지 유지되며, 차기 릴리스에서 제거 예정입니다.

dev 브랜치를 main으로 프로모션하는 PR을 생성합니다.

> ⚠️ **자동 병합하지 않습니다.** PR 생성까지만 수행하며, 실제 병합은 수동으로 진행합니다.
>
> **이 스킬은 dev → main 승격만 수행합니다. 사용자 테스트 완료 후 실행하세요.**

## 1. 사전 확인

### 1-A. 현재 브랜치 확인
```bash
git branch --show-current
```

### 1-B. dev 브랜치 최신화
```bash
git fetch origin dev main
git checkout dev
git pull --ff-only origin dev
```

### 1-C. dev와 main 차이 확인
```bash
# dev에 main 대비 새로운 커밋이 있는지 확인
git log --oneline origin/main..origin/dev
```

새로운 커밋이 없으면:
```
⚠️ dev 브랜치에 main 대비 새로운 커밋이 없습니다. 프로모션할 내용이 없습니다.
```
를 출력하고 종료합니다.

## 2. 기존 PR 확인

```bash
# 열린 dev→main PR 번호 (forge.sh 는 origin 으로 GitHub↔Gitea 자동 감지, 실행형 — 소싱 금지)
EXISTING_PR=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" pr-list dev main open | head -1)
# 상세(제목/URL 등)는 pr-view 로 조회
[[ -n "$EXISTING_PR" ]] && bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" pr-view "$EXISTING_PR"
```

### 기존 PR이 있는 경우

기존 PR 정보를 표시하고 종료합니다:
```markdown
## 📋 기존 프로모션 PR 발견

- **PR**: #<PR_NUMBER>
- **제목**: <TITLE>
- **생성일**: <CREATED_AT>
- **URL**: <URL>

기존 PR이 이미 열려 있습니다. 위 PR에서 리뷰 후 수동으로 병합해주세요.
```

### 기존 PR이 없는 경우

STEP 3으로 진행합니다.

## 3. PR 생성

### 3-A. 변경 내용 요약 수집
```bash
# dev에 포함된 커밋 목록
git log --oneline origin/main..origin/dev

# 변경된 파일 목록
git diff --stat origin/main..origin/dev
```

### 3-B. PR 본문 작성

커밋 목록과 변경 파일을 분석하여 PR 본문을 작성합니다:

```markdown
## 📦 Dev → Main 프로모션

### 포함된 변경사항
| 커밋 | 설명 |
|------|------|
| <SHA> | <메시지> |
| ... | ... |

### 변경 파일 요약
- 변경된 파일 수: N개
- 추가: +N줄
- 삭제: -N줄

### 주요 변경 내용
- ...
- ...

### 체크리스트
- [ ] 모든 이슈 PR이 dev에 병합됨
- [ ] QA 테스트 통과
- [ ] 배포 준비 완료
```

### 3-C. PR 생성 실행
```bash
# forge.sh pr-create <head> <base> <title> <body> → 마지막 줄 "PR_NUMBER=<n> PR_URL=<url>"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" pr-create dev main \
  "chore: dev → main 프로모션 ($(date +%Y-%m-%d))" \
  "[위에서 작성한 PR 본문]"
```

## 4. 결과 출력

```markdown
## ✅ 프로모션 PR 생성 완료

- **PR**: #<PR_NUMBER>
- **URL**: <PR_URL>
- **방향**: dev → main
- **포함 커밋**: N개

> ⚠️ 자동 병합하지 않습니다. PR에서 리뷰 후 수동으로 병합해주세요.
```

---

현재 제공된 인자: $ARGUMENTS

위 절차대로 진행해줘.
