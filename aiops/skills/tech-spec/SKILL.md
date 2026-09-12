---
name: tech-spec
description: "기술 스펙 설계. PRD와 와이어프레임을 기반으로 API 명세·데이터 스키마·시퀀스 다이어그램을 작성하여 context/03_tech_spec.md에 저장. 절 구성과 코드 예시는 agent_hints 의 프로젝트 스택을 따른다(FastAPI·Hono·Django·Express 등)."
---
`context/01_prd.md`와 `context/02_wireframe.md`를 읽고
대상 프로젝트 기술 스펙을 작성하여 `context/03_tech_spec.md`에 저장해줘.

## 먼저 — 스택을 확인한다 (아래 형식은 뼈대일 뿐이다)

`.claude/config.json` 의 `agent_hints`(없으면 `tech_stack`, 그것도 없으면 `.reviewer/profile.yaml`)를 읽어
**그 프로젝트의 언어·프레임워크·ORM·테스트 러너**를 확인한다. 아래 형식의 코드 예시는 **FastAPI+SQLAlchemy
기준 샘플**이다 — 다른 스택이면 그 스택의 관례로 바꿔 쓴다:

| 절 | FastAPI+SQLAlchemy | Hono/Express+Prisma·Drizzle | Django |
|---|---|---|---|
| 요청/응답 스키마 | Pydantic 모델 | zod·TypeScript 인터페이스 | 시리얼라이저 |
| 데이터 스키마 | SQLAlchemy 모델 | Prisma schema·Drizzle 테이블 | 모델 |
| 마이그레이션 | Alembic | prisma migrate·drizzle-kit·D1 마이그레이션 | makemigrations |
| 테스트 | pytest | vitest·jest | pytest·unittest |

**해당 없는 절은 만들지 않는다.** 빈 절을 남기면 다음 사람이 그걸 채우려 한다.
프로젝트에 없는 개념(멀티테넌시·API 프리픽스 규약 등)은 **그 프로젝트 코드에서 확인된 것만** 쓴다.

**platform=cli 인 프로젝트**: `agent_hints`/`profile.yaml` 의 `platform` 이 `cli` 면 HTTP 서버·DB·인증이 없는 터미널 도구다. `## API 엔드포인트`(`/health` 포함)·`## 데이터 스키마`·`## 인증/로그인` 절은 **"해당 없음" 한 줄로 남기거나 만들지 않는다.** 대신 **명령 인터페이스**(서브커맨드·인자·옵션·기본값), **종료 코드 규약**, **stdout/stderr 출력 계약**을 그 자리에 쓴다. `## E2E 검증 시나리오` 는 Playwright 가 아니라 CLI 실행·PTY 기반 검증으로 서술한다.

다음 형식으로 작성해줘:
```markdown
# [기능명] 기술 스펙
작성자: 개발팀 기획자
작성일시: [오늘 날짜]
선행파일: context/01_prd.md, context/02_wireframe.md
상태: DONE
---

## 개요
- 구현 범위 요약
- 영향받는 모듈

## API 엔드포인트
프리픽스는 **그 프로젝트의 기존 관례를 따른다**(예: `/api/v1/`). 새로 정하지 말고 기존 라우트를 먼저 볼 것.

| Method | Path | 설명 | Auth |
|--------|------|------|------|
| GET | /api/v1/... | ... | JWT |

### `/health` 엔드포인트 (필수)

배포 검증(`/aiops:merge-pr`, `/aiops:deploy-prod`, `/aiops:verify-deploy`)이 배포 SHA 매칭에 사용하므로 **모든 서비스는 `/health`를 반드시 구현**한다. 응답에 `status` + `deployed_sha` 를 포함해야 한다(빌드 시점 주입된 커밋 SHA).

```json
{ "status": "ok", "deployed_sha": "abc1234" }
```

- `deployed_sha`: 7자 short SHA 또는 40자 full SHA. 빈 문자열/누락 시 헬스체크 SHA 매칭 실패(타임아웃).
- 표준 계약 단일 출처: `/aiops:merge-pr` SKILL.md §15 "/health deployed_sha 가이드".

### 요청/응답 스키마
그 스택의 검증 계층으로 쓴다. **HTTP 계약(필드·타입·필수 여부·오류 형태)은 스택 무관하게 항상 명시한다.**

<details><summary>FastAPI 예시</summary>

```python
class MyRequest(BaseModel):
    field: type
```
</details>

## 데이터 스키마
테이블·컬럼·인덱스·제약을 쓴다. 표현은 그 프로젝트의 ORM/스키마 도구로.
**스키마 변경이 없으면 "변경 없음" 한 줄로 끝낸다.**

<details><summary>SQLAlchemy 예시</summary>

```python
class MyModel(Base):
    __tablename__ = "my_models"
    id: Mapped[int] = mapped_column(primary_key=True)
```
</details>

### 마이그레이션 고려사항
- 신규 테이블 / 컬럼 추가 / Enum·제약 변경 / 되돌리기(rollback) 가능 여부
- 도구는 그 프로젝트의 것(Alembic·prisma migrate·drizzle-kit·`wrangler d1 migrations` 등)
- ⚠️ **여러 서비스가 공유하는 DB** 라면 배포 전 선적용이 필요할 수 있다 — 그 프로젝트 문서를 확인

## 시퀀스 다이어그램
실제 경계를 그린다 — 클라이언트 → (프론트) → (API) → (저장소) → (외부 의존). 비동기면 큐·콜백까지.

```
클라이언트 → 프론트엔드 → API → 데이터 저장소
                          ↓ (외부 작업 시)
                     큐/워커 → 외부 서비스 → 콜백
```

## 격리·권한 (해당하는 경우만)
그 프로젝트에 멀티테넌시·조직 격리 개념이 **있을 때만** 쓴다(예: 모든 모델에 테넌트 키, 자동 필터링).
없으면 이 절을 만들지 않는다 — 대신 인증·인가 경로를 API 표의 `Auth` 열로 충분히 표현한다.

## 성능 요구사항
- 응답시간: ...
- 동시 요청: ...

## 보안 고려사항
- JWT 인증 방식
- n8n 웹훅: X-Webhook-Secret 검증
- 입력 검증: Pydantic

## 인증/로그인 (E2E 입력, 의무)
> 이 절은 `aiops:dev-e2e` 에이전트가 `global-setup.ts` 의 로그인 경로/방식을 치환하는 **단일 출처**다.
> 누락 시 dev-e2e 는 `E2E_AUTH_MODE=none`으로 처리하며 특정 로그인 API를 추측하지 않는다.

| 항목 | 값 | 예시 |
|------|-----|------|
| 인증 방식 | `api` \| `form` | api=토큰 응답, form=세션/폼 POST |
| 로그인 라우트 | 실제 경로 | 프로젝트에서 확인된 API 또는 form 경로 |
| 폼/요청 필드 | 자격증명 필드명 | `username`+`password` 또는 `email`+`password` |
| 폼 셀렉터 (form일 때) | 아이디/비번/제출 | `#id_username`, `#id_password`, `button[type=submit]` |
| 성공 판정 신호 | 리다이렉트 URL 또는 토큰 응답 | `/dashboard/` 리다이렉트, `{ "access_token": ... }` |
| 테스트 계정 | E2E 시드 계정 (username/password) | `e2e_user` / `e2e_pass` (C11 시드와 1:1 매칭) |

## Frontend 연동 방법
- API 호출 방식 (Hono fetch 패턴)
- 환경변수: API_BASE_URL
```

$ARGUMENTS가 있으면 추가 요구사항으로 반영해줘.
