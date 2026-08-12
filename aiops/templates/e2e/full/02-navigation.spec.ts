/**
 * full/02-navigation.spec.ts — 네비게이션 회귀
 *
 * 인증된 상태(storageState)에서 메뉴 클릭 → URL/주요 셀렉터 검증.
 */
import { test, expect } from '../fixtures/auth';
import { HomePage } from '../pages';

test.describe('네비게이션', () => {
  test('홈 진입 시 nav/main 영역이 노출된다', async ({ page }) => {
    const home = new HomePage(page);
    await home.goto('/');
    await expect(home.nav).toBeVisible();
    await expect(home.main).toBeVisible();
  });

  test('항목 메뉴 클릭 시 항목 리스트 URL로 이동한다', async ({ page }) => {
    const home = new HomePage(page);
    await home.goto('/');
    await home.navigateToItems();
    await expect(home.main).toBeVisible();
  });

  // TODO(domain): 도메인 라우트가 늘어나면 아래 패턴으로 추가.
  // test('사용자 메뉴 클릭 시 사용자 페이지로 이동한다', async ({ page }) => { ... });
});
