/**
 * pages/HomePage.ts — 홈/대시보드/대표 CRUD POM
 *
 * 본 골격은 "홈 진입 + 네비게이션 + 대표 CRUD" 3가지 흐름을 한 클래스에서 다룬다.
 * 도메인이 크면 DashboardPage, ItemListPage 등으로 쪼개도 무방.
 *
 * TODO(selector): 셀렉터/라우트는 대상 프로젝트 와이어프레임에 맞게 조정.
 */
import { Page, Locator, expect } from '@playwright/test';

export class HomePage {
  readonly page: Page;
  readonly nav: Locator;
  readonly main: Locator;
  readonly userMenu: Locator;
  readonly itemsLink: Locator;
  readonly createButton: Locator;
  readonly searchInput: Locator;

  constructor(page: Page) {
    this.page = page;
    this.nav = page.getByRole('navigation');
    this.main = page.getByRole('main');
    this.userMenu = page.getByRole('button', { name: /사용자|user menu/i });
    this.itemsLink = page.getByRole('link', { name: /항목|items/i });
    this.createButton = page.getByRole('button', { name: /생성|만들기|create|new/i });
    this.searchInput = page.getByPlaceholder(/검색|search/i);
  }

  async goto(path = '/'): Promise<void> {
    await this.page.goto(path);
    await expect(this.main).toBeVisible();
  }

  async expectAuthenticated(): Promise<void> {
    await expect(this.userMenu.or(this.nav)).toBeVisible();
  }

  async navigateToItems(): Promise<void> {
    await this.itemsLink.click();
    await expect(this.page).toHaveURL(/items|항목/);
  }

  async findRowByName(name: string): Promise<Locator> {
    return this.page.getByRole('row', { name: new RegExp(name) });
  }

  async openItemByName(name: string): Promise<void> {
    const row = await this.findRowByName(name);
    await row.click();
  }

  async search(keyword: string): Promise<void> {
    await this.searchInput.fill(keyword);
    await this.searchInput.press('Enter');
  }
}
