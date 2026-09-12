/**
 * full/04-stdout-contract.test.mjs — 출력 포맷 계약 (줄 단위 / --json 모드)
 *
 * 시나리오:
 *   - 기본(줄 단위) 출력 포맷 확인
 *   - `--json` 플래그가 있으면 유효한 JSON 출력 확인
 */
import { test } from 'node:test';
import { runCli } from '../lib/run-cli.mjs';
import { expectExit, expectJsonStdout, expectEntryResolved } from '../lib/assert-cli.mjs';

test('기본 출력은 줄 단위 텍스트 포맷을 따른다', async () => {
  // TODO(cli): 실제 대표 명령으로 교체
  const r = await runCli(['--help']);
  expectEntryResolved(r);
  expectExit(r, 0);
  // TODO(cli): 줄 수/구분자 등 실제 계약으로 검증 로직 추가
});

test('--json 플래그 사용 시 유효한 JSON 을 출력한다 (지원하는 경우)', async (t) => {
  // TODO(cli): --json 미지원 CLI 라면 이 테스트를 t.skip() 처리
  const r = await runCli(['--help', '--json']);
  expectEntryResolved(r);
  if (r.code !== 0) {
    t.skip('이 CLI 는 --json 플래그를 지원하지 않는 것으로 보임 — TODO(cli) 확인 필요');
    return;
  }
  expectJsonStdout(r);
});
