# 백엔드 체크리스트 — FastAPI + stdlib sqlite3

이 프리셋은 FastAPI + Python `sqlite3` (stdlib) 기반 경량 서비스 전용이다.
`stack.backend: fastapi-sqlite` 일 때 사용된다.

## 금지 사항 (이 스택에서는 쓰지 않아야 함)

- [ ] **SQLAlchemy 사용 금지** — ORM 의존성 추가 없이 `sqlite3` stdlib 그대로 사용
- [ ] **Alembic 사용 금지** — 마이그레이션은 자체 러너(`schema_version` 테이블)로 관리
- [ ] **비동기 DB 드라이버 금지** — `sqlite3.Connection` 동기 API 사용

## 아키텍처

- [ ] 라우터는 얇게 — 쿼리 로직은 서비스/리포지토리 계층에 위치
- [ ] `sqlite3.Connection` 은 FastAPI 의존성으로 주입 (전역 커넥션 지양)
- [ ] 트랜잭션 경계가 서비스 함수 단위로 명확

## 마이그레이션

- [ ] `schema_version` 테이블로 적용된 마이그레이션 추적
- [ ] 마이그레이션 러너가 멱등 실행 가능 (이미 적용된 버전 스킵)
- [ ] 신규 마이그레이션은 순번 충돌 없는 파일명

## API 규칙

- [ ] API 경로 프리픽스가 프로젝트 규약을 따름
- [ ] Pydantic 스키마로 입출력 검증
- [ ] 에러 응답은 `HTTPException` 사용

## 쿼리 안전성

- [ ] **파라미터 바인딩 필수** (`?` placeholder, f-string/concat 금지) — SQL Injection 차단
- [ ] 사용자 입력을 테이블/컬럼 이름으로 직접 사용하지 않음 (허용 목록으로 제한)

## 네이밍

- [ ] 클래스명: PascalCase
- [ ] 함수/변수: snake_case
- [ ] 상수: UPPER_SNAKE_CASE

## 테스트 (pytest)

- [ ] 각 테스트는 자체 인메모리 DB(`:memory:`) 또는 임시 파일 DB로 격리
- [ ] 마이그레이션이 테스트 setup에서 적용됨
- [ ] 신규 라우터/서비스마다 행복 경로 + 에러 경로 테스트 최소 1개
