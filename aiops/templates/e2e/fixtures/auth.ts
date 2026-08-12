/**
 * fixtures/auth.ts — 인증 상태 fixture
 *
 * 사용법:
 *   import { test, expect } from '../fixtures/auth';
 *
 *   test('인증된 사용자만 접근 가능', async ({ page }) => {
 *     await page.goto('/dashboard');
 *     await expect(page).toHaveURL(/dashboard/);
 *   });
 *
 * 인증 우회(로그인 화면 자체를 테스트할 때):
 *   test.use({ storageState: { cookies: [], origins: [] } });
 */
import { test as base, expect, Page } from '@playwright/test';

type AuthFixtures = {
  /** storageState 가 적용된 페이지 (기본). */
  authedPage: Page;
};

export const test = base.extend<AuthFixtures>({
  authedPage: async ({ page }, use) => {
    // playwright.config.ts 의 use.storageState 가 자동 적용된 page 를 그대로 사용.
    await use(page);
  },
});

export { expect };
