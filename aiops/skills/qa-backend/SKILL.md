---
name: qa-backend
description: "Backend pytest 테스트 실행. 단독으로 백엔드 QA만 수행할 때 사용."
---

`aiops:qa-backend` 에이전트로서 백엔드 테스트를 실행해줘.

## 실행 지시
1. 프로젝트 루트에서 Docker pytest 실행
2. 결과 파싱: PASSED/FAILED 수
3. Sign-off 판정 (FAILED=0 → PASS)
4. 결과를 아래 형식으로 출력

## 결과 저장
- forge 가용: 이슈 댓글 (## 🔬 Backend QA 결과)
- forge 불가: context/08a_qa_backend.md

대상 이슈/프로젝트: $ARGUMENTS
