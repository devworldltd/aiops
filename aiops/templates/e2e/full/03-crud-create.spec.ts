/**
 * full/03-crud-create.spec.ts — CRUD: Create
 *
 * API + UI 양쪽으로 생성을 확인하는 하이브리드 패턴.
 *   1) API 로 직접 생성 (간단 회귀)
 *   2) UI 폼으로 생성 (E2E 흐름)
 */
import { test, expect } from '../fixtures/auth';
import { HomePage } from '../pages';
import { makeItem, uniqueName } from '../fixtures/test-data';
import { newApiClient, seedItem, deleteItem } from '../fixtures/api-client';

test.describe('CRUD - Create', () => {
  const createdIds: Array<string | number> = [];

  test.afterAll(async ({ baseURL }) => {
    if (!baseURL) return;
    const api = await newApiClient(baseURL);
    for (const id of createdIds) await deleteItem(api, id);
    await api.dispose();
  });

  test('API: 신규 항목을 생성하면 200/201 응답과 id가 반환된다', async ({ baseURL }) => {
    const api = await newApiClient(baseURL!);
    const payload = makeItem();
    const item = await seedItem(api, payload);
    expect(item.id).toBeTruthy();
    createdIds.push(item.id);
    await api.dispose();
  });

  test('UI: 폼으로 생성하면 리스트에 노출된다', async ({ page }) => {
    const home = new HomePage(page);
    const name = uniqueName('ui-create');

    await home.goto('/');
    await home.navigateToItems();
    await home.createButton.click();

    // TODO(domain): 폼 필드는 도메인 스키마에 맞게.
    await page.getByLabel(/이름|name/i).fill(name);
    await page.getByRole('button', { name: /저장|submit|create/i }).click();

    // 리스트로 복귀 후 노출 확인
    await expect(page.getByText(name)).toBeVisible();
  });
});
