/**
 * fixtures/api-client.ts — REST API 헬퍼
 *
 * 시드 데이터 생성/조회/삭제, tearDown 정리 유틸을 제공한다.
 * smoke/04-critical-crud.spec.ts 의 afterAll 정리에 활용된다.
 *
 * BLAST_RADIUS_GUARD=1 (기본): prod 환경에서 'e2e-prod-' prefix 없는 데이터 생성 시 throw.
 */
import { APIRequestContext, request } from '@playwright/test';

const BLAST_RADIUS_GUARD = (process.env.BLAST_RADIUS_GUARD ?? '1') === '1';
const ENV = process.env.E2E_ENV ?? 'local';

export async function newApiClient(
  baseURL: string,
  token?: string,
): Promise<APIRequestContext> {
  return request.newContext({
    baseURL,
    extraHTTPHeaders: token ? { Authorization: `Bearer ${token}` } : {},
  });
}

/** 로그인 → access_token 반환. */
export async function loginAndGetToken(
  baseURL: string,
  email: string,
  password: string,
): Promise<string> {
  const endpoint = process.env.E2E_AUTH_ENDPOINT;
  if (!endpoint) {
    throw new Error('loginAndGetToken: E2E_AUTH_ENDPOINT가 설정되지 않았습니다.');
  }
  const api = await request.newContext({ baseURL });
  try {
    const r = await api.post(endpoint, {
      data: { email, password },
      failOnStatusCode: false,
    });
    if (!r.ok()) throw new Error(`loginAndGetToken 실패: ${r.status()}`);
    const json = await r.json();
    const token = json?.access_token ?? json?.token ?? json?.data?.access_token;
    if (!token) throw new Error('loginAndGetToken: 응답에 access_token 없음');
    return token;
  } finally {
    await api.dispose();
  }
}

/** 엔티티 시드 — 도메인별 엔드포인트로 교체 가능. */
export async function seedItem(
  api: APIRequestContext,
  payload: Record<string, unknown>,
): Promise<{ id: string | number; name?: string }> {
  // prod 안전 가드: prefix 검증
  if (BLAST_RADIUS_GUARD && ENV === 'prod') {
    const name = String(payload.name ?? '');
    if (!name.startsWith('e2e-prod-')) {
      throw new Error(
        `[BLAST_RADIUS_GUARD] prod 환경에서 'e2e-prod-' prefix 없는 데이터 생성 시도: name="${name}"`,
      );
    }
  }
  // TODO(domain): 엔드포인트를 대상 프로젝트 엔티티에 맞춰 교체.
  const r = await api.post('/api/v1/items', { data: payload, failOnStatusCode: false });
  if (!r.ok()) throw new Error(`seedItem 실패: ${r.status()} ${await r.text()}`);
  return r.json();
}

export async function getItem(
  api: APIRequestContext,
  id: string | number,
): Promise<Record<string, unknown>> {
  const r = await api.get(`/api/v1/items/${id}`);
  if (!r.ok()) throw new Error(`getItem 실패: ${r.status()}`);
  return r.json();
}

export async function deleteItem(
  api: APIRequestContext,
  id: string | number,
): Promise<void> {
  // tearDown 은 실패해도 throw 하지 않음 (다른 항목 정리 계속).
  try {
    await api.delete(`/api/v1/items/${id}`, { failOnStatusCode: false });
  } catch (err) {
    console.warn(`[api-client] deleteItem(${id}) 실패 — 무시:`, err);
  }
}

/** prefix 매칭 일괄 삭제 — afterAll tearDown 의 안전망. */
export async function deleteByPrefix(
  api: APIRequestContext,
  prefix: string,
): Promise<number> {
  try {
    const listRes = await api.get(`/api/v1/items?prefix=${encodeURIComponent(prefix)}`);
    if (!listRes.ok()) return 0;
    const list = await listRes.json();
    const items: Array<{ id: string | number }> = list?.data ?? list?.items ?? list ?? [];
    let n = 0;
    for (const it of items) {
      await deleteItem(api, it.id);
      n += 1;
    }
    return n;
  } catch (err) {
    console.warn(`[api-client] deleteByPrefix(${prefix}) 실패:`, err);
    return 0;
  }
}
