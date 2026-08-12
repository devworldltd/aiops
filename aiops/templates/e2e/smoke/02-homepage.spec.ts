/**
 * smoke/02-homepage.spec.ts — 메인 페이지 200 + 핵심 셀렉터 노출
 *
 * 인증 없이 / 응답이 정상이고 nav/main 영역이 렌더링되는지 확인.
 */
import { test, expect } from '@playwright/test';

test.use({ storageState: { cookies: [], origins: [] } });

test('@smoke 메인 페이지는 200 응답이며 주요 영역이 노출된다', async ({ page }) => {
  const res = await page.goto('/');
  expect(res?.status()).toBeLessThan(400);

  // 비인증이라도 헤더/메인 또는 로그인 화면이 보여야 함.
  await expect(
    page.getByRole('main').or(page.getByRole('banner')).or(page.getByRole('navigation')),
  ).toBeVisible({ timeout: 10_000 });
});
