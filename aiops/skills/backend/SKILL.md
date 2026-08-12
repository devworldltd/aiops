---
name: backend
description: "백엔드 개발 태스크 실행. tech-spec 을 기반으로 엔드포인트·데이터 모델·마이그레이션·서비스 레이어·테스트를 구현. 스택은 agent_hints.backend 를 따른다(FastAPI·Django·Express·Hono 등)."
disable-model-invocation: true
---

`aiops:dev-backend` 에이전트로서 백엔드 구현을 수행해줘.

## 선행 조건 확인
먼저 다음 파일들을 읽어줘:
- `context/03_tech_spec.md` — 구현할 API 스펙과 DB 스키마

## 구현 순서

1. **DB 모델** (`backend/app/models/{module}/model.py`)
   - `TenantMixin` 상속 필수
   - 컬럼 정의, 관계 설정

2. **마이그레이션** — 그 프로젝트의 도구·경로로(예: Alembic `alembic/versions/`, Prisma `prisma/migrations/`, D1 `migrations/`). 스키마 변경이 없으면 만들지 않는다
   - `alembic revision --autogenerate -m "설명"`
   - Enum 타입은 `PgEnum` + 중복 방지 SQL 사용

3. **Pydantic 스키마** (`backend/app/schemas/{module}/schema.py`)
   - 요청/응답 스키마 분리

4. **서비스 레이어** (`backend/app/services/{module}/service.py`)
   - 비즈니스 로직 구현
   - 멀티테넌시 자동 적용 (TenantMixin 덕분에 자동)

5. **API 라우터** (`backend/app/api/{module}/router.py`)
   - 얇게 유지 (서비스 호출만)
   - `main.py`에 라우터 등록

6. **테스트** (`backend/tests/{module}/test_{module}.py`)
   - 각 엔드포인트 테스트
   - 멀티테넌시 격리 테스트 필수

## 완료 후
테스트 실행:
```bash
docker-compose --profile test run --rm test
```

`context/05_be_done.md`에 완료 보고서 작성.

구현할 기능: $ARGUMENTS
