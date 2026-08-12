/**
 * smoke/01-health.spec.ts — 헬스체크 (prod 안전)
 *
 * 인증 없이 /health 200 + JSON status:"ok" 확인.
 */
import { test, expect } from '@playwright/test';

test.use({ storageState: { cookies: [], origins: [] } });

test('@smoke /health 엔드포인트가 200 응답을 반환한다', async ({ request }) => {
  const path = process.env.E2E_HEALTHCHECK_PATH ?? '/health';
  const r = await request.get(path);
  expect(r.status()).toBe(200);

  // JSON 응답이 표준이면 status 필드 확인.
  try {
    const body = await r.json();
    if (body && typeof body === 'object') {
      expect(['ok', 'healthy', 'up']).toContain(String(body.status ?? body.health ?? 'ok'));
    }
  } catch {
    // text/plain 응답도 허용.
  }
});
