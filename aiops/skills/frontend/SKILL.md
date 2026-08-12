---
name: frontend
description: "프론트엔드 개발 태스크 실행. tech-spec과 component-spec을 기반으로 Hono Workers 라우트, API 연동, 인증 미들웨어를 구현."
disable-model-invocation: true
---

`aiops:dev-frontend` 에이전트로서 프론트엔드 구현을 수행해줘.

## 선행 조건 확인
먼저 다음 파일들을 읽어줘:
- `context/03_tech_spec.md` — API 연동 스펙
- `context/04_component_spec.md` — UI 컴포넌트 스펙 (있으면)

## 구현 순서

1. **라우트 파일** (`frontend/src/routes/{module}.ts`)
   - Hono 라우트 정의
   - 인증 미들웨어 적용 (`authMiddleware`)
   - FastAPI API 호출 (`c.env.API_BASE_URL`)

2. **HTML 렌더링**
   - 서버사이드 렌더링 (Hono `c.html()`)
   - 컴포넌트 스펙의 HTML 구조 사용

3. **라우터 등록** (`frontend/src/index.ts`)
   - 새 라우트를 메인 앱에 등록

4. **테스트** (`frontend/src/...test.ts`)
   - vitest로 핵심 로직 테스트

## Docker 재빌드 (필수!)
```bash
docker-compose -f docker-compose.yml -f docker-compose.dev.yml up --build frontend
```

## 완료 후
`context/06_fe_done.md`에 완료 보고서 작성.

구현할 기능: $ARGUMENTS
