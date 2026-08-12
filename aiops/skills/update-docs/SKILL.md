---
name: update-docs
description: "dev 머지 후 변경된 코드를 분석하여 관련 문서를 자동 업데이트. PR 머지 직후 실행."
---

dev 머지 후 변경사항을 분석하여 관련 문서를 자동 업데이트합니다.

## 인자 파싱

`$ARGUMENTS`에서 다음을 추출합니다:
- **PR 번호** 또는 **머지 커밋 해시** (선택)

## 실행

doc-updater 에이전트를 Agent 도구로 호출합니다.

### 에이전트 호출 프롬프트

```
최근 dev 머지 변경사항을 분석하여 docs/ 폴더의 관련 문서를 업데이트해줘.

변경된 파일 확인:
git log dev --oneline -1
git diff HEAD~1 --stat

업데이트 대상 문서 판별 기준:
- agents/*.md 변경 → docs/02_service_architecture.md, docs/03_relationships.md
- skills/*/SKILL.md 변경 → docs/03_relationships.md
- scripts/cx-* 변경 → docs/03_relationships.md
- install.sh / install-local-skills.sh 변경 → docs/01_project_overview.md
- .gitea/workflows/ 또는 .github/workflows/ 변경 → docs/08_deployment.md
- 에이전트/스킬 추가/삭제 → docs/05_feature_status.md
- 모든 변경 → docs/09_history.md
```

## 결과

- 문서 업데이트 커밋 자동 생성: `docs: 문서 자동 업데이트 (PR #N 반영)`
- 변경된 문서 목록 출력

---

현재 제공된 인자: $ARGUMENTS

위 절차대로 doc-updater 에이전트를 호출하여 문서를 업데이트해줘.
