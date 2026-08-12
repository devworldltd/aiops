---
name: prd
description: "PRD(제품 요구사항 문서) 작성. context/00_brief.md를 기반으로 기능 요구사항, 수용 기준, 마일스톤을 포함한 PRD를 context/01_prd.md에 저장."
---
`context/00_brief.md`를 읽고 PRD를 작성하여 `context/01_prd.md`에 저장해줘.
다음 형식으로 작성해줘:
```markdown
# [기능명] PRD
작성자: 기획팀 PM
작성일시: [오늘 날짜]
선행파일: context/00_brief.md
상태: DONE
---

## 배경 및 목표
- **문제**: 현재 대상 프로젝트 사용자가 겪는 문제
- **해결책**: 이 기능이 해결하는 방법
- **성공 지표**: 측정 가능한 KPI

## 사용자 스토리
- As a [사용자 유형], I want to [목표], so that [이유]
- ...

## 기능 요구사항

### Must (P0)
- [ ] ...

### Should (P1)
- [ ] ...

### Could (P2)
- [ ] ...

## 비기능 요구사항
- **성능**: ...
- **보안**: 멀티테넌시 격리 필수, JWT 인증
- **가용성**: ...

## 수용 기준 (Acceptance Criteria)
| # | 시나리오 | 입력 | 예상 결과 |
|---|---------|------|---------|
| 1 | ... | ... | ... |

## 마일스톤
| 단계 | 산출물 | 예상일 |
|------|-------|--------|
| 기술 스펙 | context/03_tech_spec.md | D+N |
| BE 구현 | context/05_be_done.md | D+N |
| FE 구현 | context/06_fe_done.md | D+N |
| QA | context/07_qa_signoff.md | D+N |
```

$ARGUMENTS가 있으면 추가 요구사항으로 반영해줘.
