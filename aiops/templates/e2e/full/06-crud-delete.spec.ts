/**
 * full/06-crud-delete.spec.ts — CRUD: Delete
 */
import { test, expect } from '../fixtures/auth';
import { HomePage } from '../pages';
import { makeItem } from '../fixtures/test-data';
import { newApiClient, seedItem } from '../fixtures/api-client';

test.describe('CRUD - Delete', () => {
  test('UI: 항목을 삭제하면 리스트에서 사라진다', async ({ page, baseURL }) => {
    // 정리 책임이 이 테스트에 있으므로 afterAll 시드 불필요
    const api = await newApiClient(baseURL!);
    const payload = makeItem();
    const item = await seedItem(api, payload);
    const name = String(payload.name);
    await api.dispose();

    const home = new HomePage(page);
    await home.goto('/');
    await home.navigateToItems();
    await expect(page.getByText(name)).toBeVisible();

    const row = await home.findRowByName(name);
    await row.getByRole('button', { name: /삭제|delete/i }).click();
    // 확인 다이얼로그
    await page.getByRole('button', { name: /확인|confirm|예/i }).click();

    // 리스트에서 사라짐
    await expect(page.getByText(name)).toHaveCount(0);

    // API 로 410/404 확인
    const api2 = await newApiClient(baseURL!);
    const r = await api2.get(`/api/v1/items/${item.id}`, { failOnStatusCode: false });
    expect([404, 410]).toContain(r.status());
    await api2.dispose();
  });
});
