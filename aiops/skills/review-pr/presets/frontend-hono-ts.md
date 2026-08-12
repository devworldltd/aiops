# 프론트엔드 체크리스트 — Hono + TypeScript (Cloudflare Workers)

`stack.frontend: hono-ts` 또는 `stack.admin: hono-ts` 일 때 사용된다.

## 아키텍처

- [ ] 라우트 핸들러는 얇게 — 복잡한 로직은 유틸 함수로 분리
- [ ] 뷰(View)와 라우트(Route) 분리: `routes/*.tsx` 데이터 처리, `views/**/*.tsx` 렌더링
- [ ] 백엔드 API 호출은 `API_BASE_URL` 환경변수 사용 (하드코딩 URL 금지)

## TypeScript

- [ ] `any` 타입 사용 금지 (불가피한 경우 `unknown` + 타입 가드)
- [ ] API 응답 타입 명시 (interface 또는 type alias)
- [ ] 옵셔널 체이닝(`?.`) 및 nullish coalescing(`??`) 적절히 사용
- [ ] `as` 캐스팅 남용 금지 (런타임 검증 선행)

## 유효성 검사

- [ ] FE에서 1차 검사, BE에서 2차 검사 (이중 방어)
- [ ] 사용자 입력 폼은 제출 전 클라이언트 유효성 검사

## API 연동

- [ ] fetch 에러 응답(`!response.ok`) 처리
- [ ] 422 등 백엔드 validation 에러를 사용자에게 표시
- [ ] 인증 토큰이 필요한 요청에 Authorization 헤더 누락 없음

## 네이밍

- [ ] 컴포넌트 함수: PascalCase
- [ ] 일반 함수/변수: camelCase
- [ ] CSS 클래스: kebab-case

## CSS

- [ ] 전역 CSS는 공통 레이아웃 파일에만 추가 (페이지별 전역 스타일 금지)
- [ ] 기존 CSS 변수(`--border`, `--accent` 등) 재사용
- [ ] 하드코딩 색상값보다 CSS 변수 우선

## 테스트 (vitest)

- [ ] 테스트 ID 형식이 프로젝트 규약을 따름
- [ ] 각 테스트는 독립적 (`vi.fn()` mock 초기화)
- [ ] 신규 라우트/뷰마다 렌더 + 주요 인터랙션 테스트 최소 1개
