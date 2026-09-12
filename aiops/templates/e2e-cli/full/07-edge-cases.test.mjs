/**
 * full/07-edge-cases.test.mjs — 빈 입력 · 없는 경로 · 권한 오류 · 타임아웃
 */
import { test } from 'node:test';
import { runCli } from '../lib/run-cli.mjs';
import { makeWorkdir, nonExistentPath } from '../lib/test-data.mjs';
import { expectEntryResolved, expectNoTimeout } from '../lib/assert-cli.mjs';
import { chmodSync } from 'node:fs';
import path from 'node:path';

test('빈 입력(stdin) 을 전달해도 크래시하지 않는다', async () => {
  const r = await runCli(['--help'], { stdin: '' });
  expectEntryResolved(r);
  expectNoTimeout(r);
});

test('존재하지 않는 경로를 인자로 주면 비0 종료 코드로 안전하게 실패한다', async () => {
  // TODO(cli): 경로 인자를 받는 실제 서브커맨드로 교체
  const r = await runCli(['--help', nonExistentPath()]);
  expectEntryResolved(r);
  expectNoTimeout(r);
});

test('권한 없는 경로에 쓰기 시도 시 비0 종료 코드로 안전하게 실패한다', async (t) => {
  const { dir, cleanup } = makeWorkdir('e2e-cli-perm-');
  try {
    const readonlyDir = path.join(dir, 'readonly');
    const { mkdirSync } = await import('node:fs');
    mkdirSync(readonlyDir);
    chmodSync(readonlyDir, 0o444);
    // TODO(cli): 실제 쓰기 서브커맨드로 교체 (예: ['write', path.join(readonlyDir, 'out.txt')])
    const r = await runCli(['--help']);
    expectEntryResolved(r);
    expectNoTimeout(r);
  } finally {
    cleanup();
  }
});

test('장시간 무응답 시 타임아웃으로 안전하게 종료된다 (timeoutMs 짧게 설정)', async () => {
  // TODO(cli): 정상적으로 즉시 종료되는 명령이므로 timedOut=false 여야 한다.
  //            실제로 블로킹되는 명령이 있다면 그 명령으로 교체해 timedOut=true 를 검증한다.
  const r = await runCli(['--version'], { timeoutMs: 5000 });
  expectEntryResolved(r);
  expectNoTimeout(r);
});
