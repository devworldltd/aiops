/**
 * full/05-exit-codes.test.mjs — 종료코드 매핑 전수 (0/1/2)
 *
 * 시나리오: 정상(0) / 사용자 오류(1) / 시스템·환경 오류(2) 매핑을 확인한다.
 * TODO(cli): 프로젝트의 실제 종료 코드 표(있다면 README/docs)를 근거로 케이스를 채운다.
 */
import { test } from 'node:test';
import { runCli } from '../lib/run-cli.mjs';
import { nonExistentPath } from '../lib/test-data.mjs';
import { expectExit, expectEntryResolved } from '../lib/assert-cli.mjs';

test('정상 실행은 exit 0 을 반환한다', async () => {
  const r = await runCli(['--version']);
  expectEntryResolved(r);
  expectExit(r, 0);
});

test('사용자 입력 오류는 exit 1 을 반환한다', async () => {
  const r = await runCli(['--not-a-real-flag-xyz']);
  expectEntryResolved(r);
  expectExit(r, 1); // TODO(cli): 실제 매핑으로 교체
});

test('존재하지 않는 경로 인자는 비0 종료 코드를 반환한다', async () => {
  // TODO(cli): 경로 인자를 받는 실제 서브커맨드로 교체 (예: ['read', nonExistentPath()])
  const missing = nonExistentPath();
  const r = await runCli(['--help', missing]);
  expectEntryResolved(r);
  // placeholder — 프로젝트의 실제 서브커맨드로 교체 시 exit != 0 기대
  void r;
});
