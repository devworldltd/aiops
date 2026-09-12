/**
 * smoke/01-version.test.mjs — 버전 확인 (read-only)
 */
import { test } from 'node:test';
import { runCli } from '../lib/run-cli.mjs';
import { expectExit, expectStdoutMatches, expectEntryResolved } from '../lib/assert-cli.mjs';

test('@smoke --version 이 정상 동작한다', async () => {
  const r = await runCli(['--version']);
  expectEntryResolved(r);
  expectExit(r, 0);
  expectStdoutMatches(r, /\d+\.\d+\.\d+/); // TODO(cli): 버전 출력 포맷에 맞게 조정
});
