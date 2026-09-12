/**
 * full/03-happy-path.test.mjs — 대표 명령 정상 수행 (stdout 계약)
 *
 * 시나리오: 프로젝트의 대표 서브커맨드를 정상 인자로 실행 → exit 0 + 기대 stdout.
 */
import { test } from 'node:test';
import { runCli } from '../lib/run-cli.mjs';
import { uniqueName } from '../lib/test-data.mjs';
import { expectExit, expectStdoutContains, expectEntryResolved } from '../lib/assert-cli.mjs';

test('대표 명령을 정상 인자로 실행하면 성공한다', async () => {
  // TODO(cli): 실제 대표 서브커맨드/인자로 교체 (예: ['create', '--name', uniqueName('item')])
  const name = uniqueName('item');
  const r = await runCli(['--version']); // TODO(cli): placeholder — 프로젝트 대표 명령으로 교체
  expectEntryResolved(r);
  expectExit(r, 0);
  expectStdoutContains(r, ''); // TODO(cli): 기대 stdout 부분 문자열로 교체
  void name;
});
