---
name: qa-admin
description: "Admin vitest 테스트 실행. 단독으로 어드민 QA만 수행할 때 사용."
---

`aiops:qa-admin` 에이전트로서 어드민 테스트를 실행해줘.

## 실행 지시
1. `cd admin && npm test` 실행
2. 결과 파싱: PASSED/FAILED 수
3. Sign-off 판정 (FAILED=0 → PASS)
4. 결과를 정해진 형식으로 출력

## 결과 저장
- forge 가용: 이슈 댓글 (## 🛠️ Admin QA 결과)
- forge 불가: context/08c_qa_admin.md

대상 이슈/프로젝트: $ARGUMENTS
