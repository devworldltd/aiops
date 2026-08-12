/**
 * smoke/04-critical-crud.spec.ts — prod 핵심 CRUD 라운드트립 (Q3-C)
 *
 * 안전 패턴:
 *   1) 모든 생성 데이터는 TEST_PREFIX="e2e-prod-" 를 갖는다.
 *   2) afterAll 에서 생성한 모든 항목을 삭제 + prefix 기반 안전망 삭제.
 *   3) BLAST_RADIUS_GUARD=1 (기본) 이면 fixtures/api-client.ts 가
 *      prefix 누락된 데이터 생성을 차단한다.
 *   4) 실패해도 tearDown 은 항상 실행된다.
 */
import { test, expect } from '@playwright/test';
import {
  newApiClient,
  loginAndGetToken,
  seedItem,
  getItem,
  deleteItem,
  deleteByPrefix,
} from '../fixtures/api-client';
import { TEST_PREFIX, FIXED_TEST_USER, CURRENT_ENV } from '../fixtures/test-data';

// prod 안전 prefix 강제
const PROD_PREFIX = 'e2e-prod-';

// prod 환경이면 TEST_PREFIX 가 반드시 e2e-prod- 여야 함 — 빌드 타임 보호.
if (CURRENT_ENV === 'prod' && TEST_PREFIX !== PROD_PREFIX) {
  throw new Error(
    `[smoke/04] prod 환경 prefix 가 "${PROD_PREFIX}" 가 아님: TEST_PREFIX="${TEST_PREFIX}"`,
  );
}

const createdIds: Array<string | number> = [];
let authToken: string | undefined;

test.use({ storageState: { cookies: [], origins: [] } });

test.beforeAll(async ({ baseURL }) => {
  if (!baseURL) throw new Error('baseURL 미설정');
  // 고정 테스트 계정으로 로그인 (Q3) — prod 운영 사용자 데이터 격리 보장.
  authToken = await loginAndGetToken(
    baseURL,
    FIXED_TEST_USER.email,
    FIXED_TEST_USER.password,
  );
});

test.afterAll(async ({ baseURL }) => {
  if (!baseURL) return;
  const api = await newApiClient(baseURL, authToken);

  // 1) 명시적 정리 — 본 spec 에서 생성한 id
  for (const id of createdIds) {
    await deleteItem(api, id);
  }

  // 2) 안전망 — prefix 매칭 일괄 삭제 (이전 실행 잔여물 포함)
  const purged = await deleteByPrefix(api, PROD_PREFIX);
  console.log(`[smoke/04 tearDown] 명시적 삭제 ${createdIds.length}건, prefix 삭제 ${purged}건`);

  await api.dispose();
});

test('@smoke 핵심 CRUD 라운드트립: create → read → delete', async ({ baseURL }) => {
  const api = await newApiClient(baseURL!, authToken);

  // 1) Create — prefix 강제
  const name = `${PROD_PREFIX}critical-${Date.now()}`;
  const item = await seedItem(api, { name, description: 'prod smoke' });
  expect(item.id).toBeTruthy();
  createdIds.push(item.id);

  // 2) Read — 같은 항목이 조회되는지
  const read = await getItem(api, item.id);
  expect(String(read.name)).toBe(name);

  // 3) Delete — 즉시 삭제하여 잔여물 최소화
  await deleteItem(api, item.id);
  // createdIds 에서도 제거 (afterAll 중복 삭제 방지)
  const idx = createdIds.indexOf(item.id);
  if (idx >= 0) createdIds.splice(idx, 1);

  // 4) 삭제 확인
  const after = await api.get(`/api/v1/items/${item.id}`, { failOnStatusCode: false });
  expect([404, 410]).toContain(after.status());

  await api.dispose();
});
