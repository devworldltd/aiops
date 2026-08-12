/**
 * smoke/03-auth-flow.spec.ts — 고정 테스트 계정 로그인 검증 (prod 안전)
 *
 * - 비인증 상태에서 /login 도달
 * - 폼 요소(이메일/비번/로그인 버튼) 노출
 * - 실제 로그인까지 수행하여 인증 흐름이 끝까지 동작하는지 검증
 *   (생성 데이터는 없으므로 tearDown 불필요)
 */
import { test, expect } from '@playwright/test';
import { LoginPage, HomePage } from '../pages';
import { FIXED_TEST_USER } from '../fixtures/test-data';

test.use({ storageState: { cookies: [], origins: [] } });

test('@smoke /login 도달 시 폼 요소가 노출된다', async ({ page }) => {
  const login = new LoginPage(page);
  await login.goto();
  await expect(login.email).toBeVisible();
  await expect(login.password).toBeVisible();
  await expect(login.submit).toBeVisible();
});

test('@smoke 고정 테스트 계정으로 로그인하면 인증 상태가 된다', async ({ page }) => {
  const login = new LoginPage(page);
  const home = new HomePage(page);

  await login.goto();
  await login.login(FIXED_TEST_USER.email, FIXED_TEST_USER.password);

  await home.expectAuthenticated();
});
