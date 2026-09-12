/**
 * lib/pty-adapter.mjs — 선택 어댑터 (이슈 #41 결정 (b))
 *
 * `node-pty` 는 네이티브 빌드 의존성이라 CI 이미지·Node 버전별 설치 실패가 흔하다.
 * 이는 CLI E2E 템플릿의 "의존성 0" 원칙과 충돌하므로, 대화형(PTY) 검증이 필요한
 * 시나리오만 **선택적으로** 이 어댑터를 통해 `node-pty` 를 동적 로드한다.
 *
 * 미설치 시: 해당 시나리오만 `t.skip()` 으로 SKIPPED 처리한다 — 전체 FAIL 로 전이하지 않는다.
 * (러너 판정 불변식: SKIP 은 FAIL 이 아니다. 단, 전부 SKIP 이면 러너가 PASS 로도 판정하지 않는다 — runner/run-e2e.mjs 참조.)
 *
 * 사용 예:
 *   import { test } from 'node:test';
 *   import { hasPty, loadPty } from '../lib/pty-adapter.mjs';
 *
 *   test('대화형 프롬프트 확인', async (t) => {
 *     if (!(await hasPty())) { t.skip('node-pty 미설치 — PTY 시나리오 스킵'); return; }
 *     const pty = await loadPty();
 *     // ... pty.spawn(...) 사용
 *   });
 */
let cached; // undefined=미확인, null=미설치, module=로드됨

async function tryLoad() {
  if (cached !== undefined) return cached;
  if (process.env.E2E_PTY !== '1') {
    cached = null;
    return cached;
  }
  try {
    cached = await import('node-pty');
  } catch {
    cached = null;
  }
  return cached;
}

/** `E2E_PTY=1` 이 설정되어 있고 `node-pty` 가 실제로 로드 가능한지 확인한다. */
export async function hasPty() {
  const mod = await tryLoad();
  return mod !== null;
}

/** `node-pty` 모듈을 반환한다. 미설치/미활성 시 null. */
export async function loadPty() {
  return tryLoad();
}
