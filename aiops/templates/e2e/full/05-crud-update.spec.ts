/**
 * full/05-crud-update.spec.ts — CRUD: Update
 */
import { test, expect } from '../fixtures/auth';
import { HomePage } from '../pages';
import { makeItem, uniqueName } from '../fixtures/test-data';
import { newApiClient, seedItem, getItem, deleteItem } from '../fixtures/api-client';

test.describe('CRUD - Update', () => {
  let seededId: string | number | undefined;
  let originalName: string | undefined;

  test.beforeAll(async ({ baseURL }) => {
    const api = await newApiClient(baseURL!);
    const payload = makeItem();
    const item = await seedItem(api, payload);
    seededId = item.id;
    originalName = String(payload.name);
    await api.dispose();
  });

  test.afterAll(async ({ baseURL }) => {
    if (!seededId || !baseURL) return;
    const api = await newApiClient(baseURL);
    await deleteItem(api, seededId);
    await api.dispose();
  });

  test('UI: 항목 이름을 수정하면 리스트에 반영된다', async ({ page, baseURL }) => {
    const home = new HomePage(page);
    const newName = uniqueName('updated');

    await home.goto('/');
    await home.navigateToItems();
    await home.openItemByName(originalName!);

    // TODO(domain): 수정 폼 셀렉터.
    await page.getByRole('button', { name: /수정|edit/i }).click();
    await page.getByLabel(/이름|name/i).fill(newName);
    await page.getByRole('button', { name: /저장|save/i }).click();

    // API 로 변경 확인
    const api = await newApiClient(baseURL!);
    const updated = await getItem(api, seededId!);
    expect(String(updated.name)).toBe(newName);
    await api.dispose();
  });
});
