/**
 * smoke/02-help.test.mjs — 도움말 확인 (read-only)
 */
import { test } from 'node:test';
import { runCli } from '../lib/run-cli.mjs';
import { expectExit, expectStdoutContains, expectEntryResolved } from '../lib/assert-cli.mjs';

test('@smoke --help 가 정상 동작한다', async () => {
  const r = await runCli(['--help']);
  expectEntryResolved(r);
  expectExit(r, 0);
  expectStdoutContains(r, 'Usage'); // TODO(cli): 실제 usage 문자열로 교체
});
