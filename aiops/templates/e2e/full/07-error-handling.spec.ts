/**
 * full/07-error-handling.spec.ts — 에러 처리 회귀
 *
 * 시나리오:
 *   - 404 라우트 → "찾을 수 없음" 화면
 *   - 403 권한 없음 (가능 시) → 에러 표시
 *   - API 5xx → UI 알림 표시
 */
import { test, expect } from '../fixtures/auth';

test.describe('에러 처리', () => {
  test('존재하지 않는 라우트는 404 화면을 노출한다', async ({ page }) => {
    const res = await page.goto('/this-route-does-not-exist-zzz');
    // SPA 라우터는 200 응답 + 404 UI 표시도 가능 → UI 우선 확인
    await expect(
      page.getByText(/찾을 수 없|not found|404/i),
    ).toBeVisible({ timeout: 5_000 });
    if (res) {
      expect([200, 404]).toContain(res.status());
    }
  });

  test('API 5xx 응답 시 UI 에러 메시지가 노출된다', async ({ page }) => {
    // API 요청을 가로채 강제로 500 응답
    await page.route('**/api/v1/items**', (route) => {
      route.fulfill({
        status: 500,
        contentType: 'application/json',
        body: JSON.stringify({ error: 'internal server error' }),
      });
    });

    await page.goto('/items');
    await expect(
      page.getByText(/오류|에러|실패|error/i),
    ).toBeVisible({ timeout: 5_000 });
  });

  test('비인증 상태에서 보호된 라우트 접근 시 로그인으로 리다이렉트된다', async ({ browser }) => {
    // storageState 우회 — 익명 컨텍스트
    const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
    const page = await ctx.newPage();

    await page.goto('/dashboard');
    await expect(page).toHaveURL(/login/);

    await ctx.close();
  });
});
