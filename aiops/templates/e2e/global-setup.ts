/**
 * global-setup.ts — Playwright 전역 인증 1회 수행
 *
 * 흐름:
 *   1) E2E_AUTH_MODE=api 일 때 구성된 로그인 API 호출
 *   2) 브라우저 컨텍스트에 토큰 주입 (쿠키 또는 localStorage)
 *   3) storageState 를 .auth/user.json 으로 저장
 *   4) 이후 모든 spec 은 playwright.config.ts 의 use.storageState 로 자동 로그인 상태
 *
 * 환경변수:
 *   - E2E_ENV, E2E_LOCAL_URL / E2E_DEV_URL / E2E_PROD_URL
 *   - E2E_TEST_USER (또는 E2E_USER_EMAIL)
 *   - E2E_TEST_PASS (또는 E2E_USER_PASSWORD)
 *   - E2E_AUTH_MODE: none | api (기본 none)
 *   - E2E_AUTH_ENDPOINT: api 모드의 필수 로그인 경로
 */
import { chromium, FullConfig, request } from '@playwright/test';
import * as fs from 'node:fs';
import * as path from 'node:path';

function resolveBaseURL(): string {
  const env = (process.env.E2E_ENV ?? 'local').toUpperCase();
  const url = process.env[`E2E_${env}_URL`] ?? 'http://localhost:8787';
  if (!url) throw new Error(`global-setup: E2E_${env}_URL 이 비어있습니다.`);
  return url;
}

export default async function globalSetup(_config: FullConfig): Promise<void> {
  const baseURL = resolveBaseURL();
  const authMode = process.env.E2E_AUTH_MODE ?? 'none';

  fs.mkdirSync('.auth', { recursive: true });
  const storagePath = path.join('.auth', 'user.json');

  if (authMode === 'none') {
    fs.writeFileSync(storagePath, JSON.stringify({ cookies: [], origins: [] }, null, 2));
    console.log(`[global-setup] 인증 미사용 storageState 저장 → ${storagePath}`);
    return;
  }
  if (authMode !== 'api') {
    throw new Error(`global-setup: 지원하지 않는 E2E_AUTH_MODE=${authMode}`);
  }

  const endpoint = process.env.E2E_AUTH_ENDPOINT;
  if (!endpoint) throw new Error('global-setup: api 인증에는 E2E_AUTH_ENDPOINT가 필요합니다.');
  const email = process.env.E2E_TEST_USER ?? process.env.E2E_USER_EMAIL;
  const password = process.env.E2E_TEST_PASS ?? process.env.E2E_USER_PASSWORD;
  if (!email || !password) {
    throw new Error('global-setup: api 인증에는 E2E_TEST_USER/E2E_TEST_PASS가 필요합니다.');
  }

  // 1) API 로그인 — 백엔드가 쿠키 발급형이면 쿠키가 응답에 포함되고,
  //    JWT 토큰형이면 응답 본문에 토큰이 담긴다.
  const apiCtx = await request.newContext({ baseURL });
  const res = await apiCtx.post(endpoint, {
    data: { email, password },
    failOnStatusCode: false,
  });

  if (!res.ok()) {
    const body = await res.text().catch(() => '');
    throw new Error(
      `global-setup 로그인 실패: status=${res.status()} body=${body.slice(0, 200)}`
    );
  }

  let token: string | undefined;
  try {
    const json = await res.json();
    token = json?.access_token ?? json?.token ?? json?.data?.access_token;
  } catch {
    // 쿠키 인증형이면 본문 파싱 실패해도 무방.
  }

  // 2) 브라우저 컨텍스트 생성 후 토큰 주입
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ baseURL });

  // TODO(token-injection): 대상 프로젝트 인증 방식에 맞게 아래 중 하나를 선택/수정.
  if (token) {
    // (a) localStorage 주입형 — SPA 라우트 진입 후 setItem.
    await ctx.addInitScript((t: string) => {
      window.localStorage.setItem('access_token', t);
    }, token);
    // 라우트 한 번 진입해서 init script 가 적용되도록 함.
    const page = await ctx.newPage();
    await page.goto('/');
    await page.close();
  } else {
    // (b) 쿠키 인증형 — apiCtx 의 쿠키를 그대로 옮긴다.
    const cookies = await apiCtx.storageState();
    await ctx.addCookies(cookies.cookies);
  }

  // 3) storageState 저장
  await ctx.storageState({ path: storagePath });

  await ctx.close();
  await browser.close();
  await apiCtx.dispose();

  console.log(`[global-setup] storageState 저장 완료 → ${storagePath} (env=${process.env.E2E_ENV ?? 'local'})`);
}
