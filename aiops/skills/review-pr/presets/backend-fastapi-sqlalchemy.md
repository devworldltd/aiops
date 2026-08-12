# 백엔드 체크리스트 — FastAPI + SQLAlchemy

이 프리셋은 FastAPI + SQLAlchemy 2.0 + Alembic + PostgreSQL 스택을 전제로 한다.
`stack.backend: fastapi-sqlalchemy` 일 때 사용된다.

## 아키텍처

- [ ] 라우터는 얇게 — 비즈니스 로직은 반드시 서비스 레이어에 위치
- [ ] 모듈 구조 준수: `api/{module}/router.py`, `services/{module}/service.py`, `models/{module}/model.py`, `schemas/{module}/schema.py`
- [ ] 관리자 전용 코드는 `models_admin/`, `schemas_admin/`, `services_admin/`, `api/admin/`에 분리

## 멀티테넌시 (해당 프로젝트에 `TenantMixin`이 존재하는 경우만 적용)

- [ ] 신규 비즈니스 모델은 `TenantMixin` 상속
- [ ] 서비스에서 직접 `tenant_id` 필터를 추가하지 않음 (자동 필터 위임)
- [ ] 테스트에 멀티테넌시 격리 케이스 포함

> `TenantMixin`이 코드베이스에 없으면 이 블록은 건너뛴다.

## API 규칙

- [ ] API 경로 프리픽스가 프로젝트 규약을 따름 (`/api/v1/` 또는 해당 규약)
- [ ] Pydantic 스키마로 입출력 검증 (dict 직접 반환 금지)
- [ ] 에러 응답은 `HTTPException` 사용
- [ ] 페이지네이션은 프로젝트 규약(`skip/limit` 또는 `page/size`)

## 인증/인가

- [ ] 인증 필요 엔드포인트에 의존성 주입으로 현재 사용자 식별
- [ ] 공개 API와 비공개 API 경로 분리

## SQLAlchemy

- [ ] 비동기 세션 사용 (`AsyncSession`) — 프로젝트가 sync 세션만 쓴다면 해당 규약 확인
- [ ] N+1 쿼리 없음 (관계 로딩 시 `selectinload` / `joinedload`)
- [ ] 신규 `Enum` 타입은 `PgEnum(create_type=False)` + DDL 예외 처리 패턴 (PostgreSQL)

## Alembic 마이그레이션

- [ ] `upgrade()` / `downgrade()` 모두 구현
- [ ] `downgrade()`에서 추가한 컬럼/테이블 제거 로직 있음
- [ ] 기존 데이터 호환성 고려 (NULL 허용, 기본값, 데이터 마이그레이션 전략)
- [ ] `sa.Enum` + `create_type=False` 패턴에서 DROP TYPE 처리 누락 없음

## 네이밍

- [ ] 클래스명: PascalCase
- [ ] 함수/변수: snake_case
- [ ] 상수: UPPER_SNAKE_CASE
- [ ] 비공개 메서드: `_` 접두사

## 테스트 (pytest)

- [ ] 테스트 클래스는 `Test{Feature}` 형식
- [ ] 테스트 함수는 `test_{scenario}` 형식
- [ ] `async def test_` + `asyncio_mode = auto` (프로젝트 규약에 따름)
- [ ] 각 테스트는 독립적 (TRUNCATE/rollback으로 초기화)
- [ ] 신규 라우터/서비스마다 행복 경로 + 에러 경로 테스트 최소 1개
