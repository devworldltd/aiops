/**
 * pages/LoginPage.ts — 로그인 페이지 POM
 *
 * 사용법:
 *   const login = new LoginPage(page);
 *   await login.goto();
 *   await login.login('e2e@example.com', 'secret');
 *
 * TODO(selector): 셀렉터는 대상 프로젝트 라벨/role/testid 에 맞게 조정.
 */
import { Page, Locator, expect } from '@playwright/test';

export class LoginPage {
  readonly page: Page;
  readonly email: Locator;
  readonly password: Locator;
  readonly submit: Locator;
  readonly errorBanner: Locator;

  constructor(page: Page) {
    this.page = page;
    // TODO(selector): 한국어/영문 라벨 둘 다 사용 가능하면 또는 사용 .or() 로 결합.
    this.email = page.getByLabel(/이메일|email/i);
    this.password = page.getByLabel(/비밀번호|password/i);
    this.submit = page.getByRole('button', { name: /로그인|sign in|log in/i });
    this.errorBanner = page.getByRole('alert');
  }

  async goto(): Promise<void> {
    await this.page.goto('/login');
    await expect(this.email).toBeVisible();
  }

  async login(email: string, password: string): Promise<void> {
    await this.email.fill(email);
    await this.password.fill(password);
    await this.submit.click();
  }

  async expectError(messageRegex: RegExp = /실패|invalid|incorrect/i): Promise<void> {
    await expect(this.errorBanner).toBeVisible();
    await expect(this.errorBanner).toHaveText(messageRegex);
  }
}
