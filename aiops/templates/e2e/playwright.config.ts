/**
 * Playwright 설정 — 환경 분기 (local / dev / prod)
 *
 * 환경변수:
 *   - E2E_ENV: local | dev | prod (기본 local)
 *   - E2E_LOCAL_URL / E2E_DEV_URL / E2E_PROD_URL: 각 환경 baseURL
 *
 * 환경별 동작:
 *   - local/dev: full + smoke 모두 실행, fully parallel, workers=4, retries=0
 *   - prod:      smoke 전용,          workers=1,        retries=2
 */
import { defineConfig, devices } from '@playwright/test';

type E2eEnv = 'local' | 'dev' | 'prod';
const ENV = ((process.env.E2E_ENV ?? 'local') as E2eEnv);

const BASE_URL_MAP: Record<E2eEnv, string> = {
  local: process.env.E2E_LOCAL_URL ?? 'http://localhost:8787',
  dev:   process.env.E2E_DEV_URL   ?? '',
  prod:  process.env.E2E_PROD_URL  ?? '',
};

// prod 는 smoke 디렉토리만, 그 외는 전체.
const TEST_DIR_MAP: Record<E2eEnv, string> = {
  local: '.',
  dev:   '.',
  prod:  './smoke',
};

const baseURL = BASE_URL_MAP[ENV];
if (!baseURL) {
  // 빈 baseURL 로 실행되면 무한 대기 위험 → 즉시 종료.
  throw new Error(`[playwright.config] E2E_${ENV.toUpperCase()}_URL 이 비어있습니다.`);
}

export default defineConfig({
  testDir: TEST_DIR_MAP[ENV],
  fullyParallel: ENV !== 'prod',
  forbidOnly: !!process.env.CI,
  retries: ENV === 'prod' ? 2 : 0,
  workers: ENV === 'prod' ? 1 : 4,
  timeout: 30_000,
  expect: { timeout: 5_000 },
  reporter: [
    ['list'],
    ['json', { outputFile: 'playwright-results.json' }],
    ['junit', { outputFile: 'playwright-junit.xml' }],
    ['html', { open: 'never' }],
  ],
  globalSetup: require.resolve('./global-setup.ts'),
  use: {
    baseURL,
    storageState: '.auth/user.json',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    actionTimeout: 10_000,
    navigationTimeout: 15_000,
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    // 멀티 브라우저로 확장하려면 주석 해제:
    // { name: 'webkit',   use: { ...devices['Desktop Safari']  } },
    // { name: 'firefox',  use: { ...devices['Desktop Firefox'] } },
  ],
});
