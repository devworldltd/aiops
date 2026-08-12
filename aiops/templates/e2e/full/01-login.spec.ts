/**
 * full/01-login.spec.ts — 로그인 흐름 회귀 (local/dev 전용)
 *
 * 시나리오:
 *   - 정상 로그인 → 홈/대시보드 진입
 *   - 잘못된 비밀번호 → 에러 배너 노출
 *   - 세션 유지 → 새로고침 후에도 인증 상태 유지
 */
import { test, expect } from '../fixtures/auth';
import { LoginPage, HomePage } from '../pages';
import { FIXED_TEST_USER, INVALID_USER } from '../fixtures/test-data';

test.describe('로그인', () => {
  // 로그인 자체를 테스트하므로 storageState 우회
  test.use({ storageState: { cookies: [], origins: [] } });

  test('정상 자격으로 로그인하면 대시보드에 진입한다', async ({ page }) => {
    const login = new LoginPage(page);
    const home = new HomePage(page);

    await login.goto();
    await login.login(FIXED_TEST_USER.email, FIXED_TEST_USER.password);

    await home.expectAuthenticated();
    await expect(page).toHaveURL(/(\/|dashboard|home)/);
  });

  test('잘못된 비밀번호 입력 시 에러 배너가 노출된다', async ({ page }) => {
    const login = new LoginPage(page);

    await login.goto();
    await login.login(INVALID_USER.email, INVALID_USER.password);

    await login.expectError();
    await expect(page).toHaveURL(/login/);
  });

  test('로그인 후 새로고침해도 세션이 유지된다', async ({ page }) => {
    const login = new LoginPage(page);
    const home = new HomePage(page);

    await login.goto();
    await login.login(FIXED_TEST_USER.email, FIXED_TEST_USER.password);
    await home.expectAuthenticated();

    await page.reload();
    await home.expectAuthenticated();
  });
});
