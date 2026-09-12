/**
 * smoke/03-dry-run.test.mjs — 부작용 없는 경로만 (dry-run / --check 류)
 *
 * prod 안전 원칙: 실제 쓰기/네트워크 부작용이 있는 명령은 smoke 에 포함하지 않는다.
 */
import { test } from 'node:test';
import { runCli } from '../lib/run-cli.mjs';
import { expectExit, expectEntryResolved } from '../lib/assert-cli.mjs';

test('@smoke dry-run/check 계열 명령이 부작용 없이 성공한다', async (t) => {
  // TODO(cli): 프로젝트에 dry-run/--check/lint 류 read-only 명령이 있으면 그것으로 교체.
  //            없다면 이 테스트는 read-only 대체 명령(--help 등)으로 남겨둔다.
  const r = await runCli(['--help']);
  expectEntryResolved(r);
  expectExit(r, 0);
  void t;
});
