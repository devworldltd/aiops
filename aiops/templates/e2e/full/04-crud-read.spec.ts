/**
 * full/04-crud-read.spec.ts — CRUD: Read / List
 *
 * 시나리오:
 *   - 리스트 진입 → 1개 이상 행 노출
 *   - 검색 → 결과 필터링
 *   - 행 클릭 → 상세 페이지 진입
 */
import { test, expect } from '../fixtures/auth';
import { HomePage } from '../pages';
import { makeItem } from '../fixtures/test-data';
import { newApiClient, seedItem, deleteItem } from '../fixtures/api-client';

test.describe('CRUD - Read', () => {
  let seededId: string | number | undefined;
  let seededName: string | undefined;

  test.beforeAll(async ({ baseURL }) => {
    const api = await newApiClient(baseURL!);
    const payload = makeItem();
    const item = await seedItem(api, payload);
    seededId = item.id;
    seededName = String(payload.name);
    await api.dispose();
  });

  test.afterAll(async ({ baseURL }) => {
    if (!seededId || !baseURL) return;
    const api = await newApiClient(baseURL);
    await deleteItem(api, seededId);
    await api.dispose();
  });

  test('항목 리스트 진입 시 시드 데이터가 노출된다', async ({ page }) => {
    const home = new HomePage(page);
    await home.goto('/');
    await home.navigateToItems();
    await expect(page.getByText(seededName!)).toBeVisible();
  });

  test('검색 입력 시 결과가 필터링된다', async ({ page }) => {
    const home = new HomePage(page);
    await home.goto('/');
    await home.navigateToItems();
    await home.search(seededName!);
    await expect(page.getByText(seededName!)).toBeVisible();
  });

  test('항목 행 클릭 시 상세 페이지로 진입한다', async ({ page }) => {
    const home = new HomePage(page);
    await home.goto('/');
    await home.navigateToItems();
    await home.openItemByName(seededName!);
    // TODO(domain): 상세 페이지 라우트 패턴에 맞춰 검증.
    await expect(page).toHaveURL(/items\/.+|detail/);
  });
});
