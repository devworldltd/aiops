---
name: qa-check
description: "통합 QA 오케스트레이터 — 존재하는 테스트 레인(backend·frontend·admin)을 agent_hints 에서 판정해 병렬 실행하고 전체 Sign-off를 판정. 러너는 프로젝트 스택을 따른다(pytest·vitest·jest·go test 등). devflow STEP 7에서 자동 호출됨."
---

통합 QA를 수행합니다.

## 0. 레인 판정 — 3개 고정이 아니다

**없는 레인을 부르면 에이전트가 빈손으로 돌거나 없는 러너를 찾다 실패한다.** 먼저 판정한다:

```bash
BE=$(jq -r '.agent_hints.backend.test_runner // empty' .claude/config.json 2>/dev/null)
FE=$(jq -r '.agent_hints.frontend.test_runner // empty' .claude/config.json 2>/dev/null)
ADMIN_DIR=$(jq -r '.paths.admin // "admin"' .reviewer/profile.yaml 2>/dev/null || echo admin)
LANES=""; [[ -n "$BE" ]] && LANES="$LANES backend"; [[ -n "$FE" ]] && LANES="$LANES frontend"
[[ -d "$ADMIN_DIR" ]] && LANES="$LANES admin"
[[ -z "${LANES// /}" ]] && LANES="root"   # 레포 루트 단일 테스트 명령
echo "[qa-check] 레인: $LANES"
```

**존재하는 레인만** Agent 도구로 **동시에** 호출한다(순차 금지). 없는 레인은
Sign-off 표에 `해당 없음: <사유>` 로 적는다 — 조용히 빼면 커버리지가 준 것과 구별되지 않는다.

## 0-1. 어디에 대고 테스트하나

원격 dev 환경이 있으면(`dev_url`/`cf_dev_url`) 그쪽을 우선한다 — 머지 → CI → dev 배포 완료 후 QA 시작.
- API: dev 엔드포인트에 HTTP 요청으로 검증
- UI: dev URL 에서 렌더링·기능 검증
- dev 환경이 없거나 배포 실패면 **로컬 테스트로 폴백**(Docker 를 쓰는 프로젝트면 컨테이너, 아니면 로컬 러너)

## 병렬 호출 지시

### qa-backend 호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 관련 백엔드 QA를 수행해줘.
프로젝트 루트: <PROJECT_ROOT>

1. 러너 확인(`agent_hints.backend.test_runner`) → Docker 를 쓰지 않으면 로컬에서 그 러너를 직접 실행하고
   아래 블록은 건너뛴다. Docker 를 쓰는 경우의 설정 읽기:
DOCKER_NETWORK=$(jq -r '.docker.network // "app_net"' .claude/config.json 2>/dev/null || echo "app_net")
BACKEND_IMAGE=$(jq -r '.docker.backend_image // "app-backend"' .claude/config.json 2>/dev/null || echo "app-backend")
DB_CONTAINER=$(jq -r '.docker.db_container // "app-postgres"' .claude/config.json 2>/dev/null || echo "app-postgres")
DB_USER=$(jq -r '.docker.db_user // "app"' .claude/config.json 2>/dev/null || echo "app")
DB_PASS=$(jq -r '.docker.db_password // "app"' .claude/config.json 2>/dev/null || echo "app")
DB_TEST=$(jq -r '.docker.test_db_name // "app_test"' .claude/config.json 2>/dev/null || echo "app_test")

2. Docker 테스트 실행 (러너가 pytest 인 경우의 예 — 다른 러너면 그에 맞게 바꾼다):
docker run --rm --network "$DOCKER_NETWORK" \
  -e DATABASE_URL=postgresql+asyncpg://${DB_USER}:${DB_PASS}@${DB_CONTAINER}:5432/${DB_TEST} \
  -e DATABASE_URL_SYNC=postgresql://${DB_USER}:${DB_PASS}@${DB_CONTAINER}:5432/${DB_TEST} \
  -e SECRET_KEY=test-secret-key \
  -v $(pwd)/aiops:backend:/app "$BACKEND_IMAGE" \
  pytest tests/ -v 2>&1 | tee /tmp/aiops:backend_test.txt

3. 결과 파싱 후 Sign-off 판정 (FAILED=0 → PASS)
4. 결과 저장 (forge 가용: 이슈 댓글 ## 🔬 Backend QA 결과, 불가: context/08a_qa_backend.md)
```

### qa-frontend 호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 관련 프론트엔드 QA를 수행해줘.
프로젝트 루트: <PROJECT_ROOT>

1. cd frontend && npm test 2>&1 | tee /tmp/aiops:frontend_test.txt
2. 결과 파싱 후 Sign-off 판정 (FAILED=0 → PASS)
3. 결과 저장 (forge 가용: 이슈 댓글 ## 💻 Frontend QA 결과, 불가: context/08b_qa_frontend.md)
```

### qa-admin 호출 프롬프트:
```
이슈 #<ISSUE_NUMBER> 관련 어드민 QA를 수행해줘.
프로젝트 루트: <PROJECT_ROOT>

1. cd admin && npm test 2>&1 | tee /tmp/admin_test.txt
   (admin/package.json에 test 스크립트 없으면 npx vitest run 실행)
2. 결과 파싱 후 Sign-off 판정 (FAILED=0 → PASS)
3. 결과 저장 (forge 가용: 이슈 댓글 ## 🛠️ Admin QA 결과, 불가: context/08c_qa_admin.md)
```

## 전체 Sign-off 판정

3개 에이전트 결과 수집 후:

| 항목 | 기준 | 결과 |
|------|------|------|
| Backend (그 스택의 러너) | FAILED=0 | ✅/❌/해당 없음 |
| Frontend (그 스택의 러너) | FAILED=0 | ✅/❌/해당 없음 |
| Admin (있는 경우) | FAILED=0 | ✅/❌/해당 없음 |

**전체 PASS**: 모든 항목 ✅ → QA Sign-off 완료 → STEP 7(PR 생성) 진행
**전체 FAIL**: 하나라도 ❌ → 해당 에이전트(dev-backend/dev-frontend) 재호출 → dev-devops 재배포 → qa-check 재실행

## 최종 결과 저장
- forge 가용: 이슈 댓글 (## ✅ QA Sign-off 또는 ## ❌ QA FAIL)
- forge 불가: context/08_qa_signoff.md

인자: $ARGUMENTS
