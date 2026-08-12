# 프론트엔드 체크리스트 — Next.js + TypeScript

`stack.frontend: nextjs` 또는 `stack.admin: nextjs` 일 때 사용된다.

## 아키텍처

- [ ] 서버 컴포넌트/클라이언트 컴포넌트 분리가 명확 (`"use client"` 남용 없음)
- [ ] 데이터 페칭은 서버 컴포넌트/Route Handler에서 우선 처리
- [ ] API 라우트는 `app/api/**/route.ts` 규약 준수

## TypeScript

- [ ] `any` 타입 사용 금지
- [ ] API 응답·props 타입 명시
- [ ] 옵셔널 체이닝(`?.`) 및 nullish coalescing(`??`) 적절히 사용

## 라우팅 / 데이터

- [ ] `fetch` 캐시 정책(`cache`, `next.revalidate`)이 데이터 특성에 맞음
- [ ] dynamic route 파라미터 타입 안전성 확보
- [ ] 서버 액션에서 사용자 입력 검증 누락 없음

## 환경변수

- [ ] 클라이언트에 노출될 변수만 `NEXT_PUBLIC_` 접두사
- [ ] 비밀값이 `NEXT_PUBLIC_`로 노출되지 않음

## 성능

- [ ] `next/image` 사용 (일반 `<img>` 대신)
- [ ] 무거운 컴포넌트는 dynamic import 고려
- [ ] 불필요한 `"use client"` 경계로 인한 리렌더 없음

## 테스트

- [ ] Jest/vitest 또는 Playwright 중 프로젝트 규약에 맞는 프레임워크 사용
- [ ] 서버 컴포넌트 테스트와 클라이언트 컴포넌트 테스트 분리
