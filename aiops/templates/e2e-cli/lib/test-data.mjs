/**
 * lib/test-data.mjs — 고정 입력 · 임시 작업 디렉토리 팩토리
 * (templates/e2e/fixtures/test-data.ts 의 CLI 대응물)
 *
 * 핵심 약속:
 *   - CLI 시나리오가 파일시스템에 쓰기를 수행할 때는 반드시 `makeWorkdir()` 가 만든
 *     임시 디렉토리 아래에서만 수행한다(격리·권한 경계 — 기술 스펙 "격리·권한 경계 방식").
 *   - `E2E_TEST_WORKDIR` 환경변수가 있으면 그 아래에, 없으면 OS 임시 디렉토리 아래에 생성한다.
 */
import { mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const ENV = process.env.E2E_MODE ?? 'full';

/** 테스트 데이터 접두사 — 충돌/오염 방지. */
export const TEST_PREFIX = 'e2e-cli-';

/** 현재 모드 식별자 — 시나리오 내 분기에 활용. */
export const CURRENT_MODE = ENV;

/**
 * 임시 작업 디렉토리를 생성하고 정리 함수를 반환한다.
 * @param {string} [base] 접두사 (기본 TEST_PREFIX)
 * @returns {{dir:string, cleanup:() => void}}
 */
export function makeWorkdir(base = TEST_PREFIX) {
  const root = process.env.E2E_TEST_WORKDIR
    ? path.resolve(process.env.E2E_TEST_WORKDIR)
    : os.tmpdir();
  const dir = mkdtempSync(path.join(root, base));
  return {
    dir,
    cleanup: () => rmSync(dir, { recursive: true, force: true }),
  };
}

/** 타임스탬프 기반 유니크 이름 — 충돌 방지. */
export function uniqueName(base = 'item') {
  return `${TEST_PREFIX}${base}-${Date.now()}-${Math.floor(Math.random() * 1000)}`;
}

/** 존재하지 않는 경로(엣지케이스 — full/07)를 생성한다. */
export function nonExistentPath() {
  return path.join(os.tmpdir(), `e2e-cli-missing-${Date.now()}-${Math.random().toString(36).slice(2)}`);
}
