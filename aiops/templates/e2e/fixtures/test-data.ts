/**
 * fixtures/test-data.ts — 테스트 데이터 팩토리 + prod 안전 prefix 상수
 *
 * 핵심 약속(Q3-C):
 *   - prod 환경의 모든 생성 데이터는 'e2e-prod-' prefix 를 가진다.
 *   - 그 외 환경(local/dev)은 'e2e-' prefix 를 사용한다.
 *   - smoke/04-critical-crud.spec.ts 의 afterAll 은 이 prefix 로 정리한다.
 */
const ENV = process.env.E2E_ENV ?? 'local';

/** prod 에서는 'e2e-prod-', 그 외는 'e2e-' */
export const TEST_PREFIX: string = ENV === 'prod' ? 'e2e-prod-' : 'e2e-';

/** 고정 테스트 계정 — 환경별로 다른 값을 주입할 수 있다. */
export const FIXED_TEST_USER = {
  email: process.env.E2E_TEST_USER ?? process.env.E2E_USER_EMAIL ?? 'e2e@example.com',
  password: process.env.E2E_TEST_PASS ?? process.env.E2E_USER_PASSWORD ?? 'changeme',
} as const;

/** 잘못된 비밀번호 시나리오용 (07-error-handling 등) */
export const INVALID_USER = {
  email: 'e2e-invalid@example.com',
  password: 'wrong-password',
} as const;

/** 타임스탬프 기반 유니크 이름 — 충돌 방지. */
export function uniqueName(base = 'item'): string {
  return `${TEST_PREFIX}${base}-${Date.now()}-${Math.floor(Math.random() * 1000)}`;
}

/** 엔티티 팩토리 — 도메인 필드에 맞게 확장. */
export function makeItem(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    name: uniqueName('item'),
    description: 'E2E 자동 생성 데이터',
    ...overrides,
  };
}

export function makeUser(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    email: `${TEST_PREFIX}user-${Date.now()}@example.com`,
    name: uniqueName('user'),
    ...overrides,
  };
}

/** 현재 환경 식별자 — spec 내 분기에 활용. */
export const CURRENT_ENV = ENV as 'local' | 'dev' | 'prod';
