/**
 * full/01-help.test.mjs — --help/--version 계약
 *
 * 시나리오:
 *   - `--help` → exit 0 + usage 문자열 노출
 *   - `--version` → exit 0 + 버전 문자열 노출(semver 형태)
 */
import { test } from 'node:test';
import { runCli } from '../lib/run-cli.mjs';
import { expectExit, expectStdoutContains, expectStdoutMatches, expectEntryResolved } from '../lib/assert-cli.mjs';

test('--help 실행 시 exit 0 과 usage 문자열을 노출한다', async () => {
  const r = await runCli(['--help']);
  expectEntryResolved(r);
  expectExit(r, 0);
  // TODO(cli): 실제 usage 문자열/헤더로 교체 (예: 'Usage:', 'USAGE', 커맨드명 등)
  expectStdoutContains(r, 'Usage');
});

test('--version 실행 시 exit 0 과 semver 형태 버전 문자열을 노출한다', async () => {
  const r = await runCli(['--version']);
  expectEntryResolved(r);
  expectExit(r, 0);
  // TODO(cli): 프로젝트 버전 출력 포맷에 맞게 정규식 조정
  expectStdoutMatches(r, /\d+\.\d+\.\d+/);
});
