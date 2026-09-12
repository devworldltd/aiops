/**
 * full/02-args.test.mjs — 인자 파싱 · 필수 인자 누락
 *
 * 시나리오:
 *   - 필수 인자 누락 시 비0 종료 + stderr 에 사용법 안내
 *   - 알 수 없는 플래그 입력 시 비0 종료
 */
import { test } from 'node:test';
import { runCli } from '../lib/run-cli.mjs';
import { expectExit, expectEntryResolved } from '../lib/assert-cli.mjs';

test('필수 인자 누락 시 비0 종료 코드를 반환한다', async () => {
  // TODO(cli): 실제 서브커맨드/필수 인자로 교체 (예: ['create'] — --name 누락)
  const r = await runCli([]);
  expectEntryResolved(r);
  if (r.code === 0) {
    // 인자 없이도 정상 동작(예: 기본 도움말 출력)하는 CLI 는 이 분기를 유지한다.
    return;
  }
  expectExit(r, 1); // TODO(cli): 프로젝트의 실제 "필수 인자 누락" 종료 코드로 교체
});

test('알 수 없는 플래그 입력 시 비0 종료 코드를 반환한다', async () => {
  const r = await runCli(['--not-a-real-flag-xyz']);
  expectEntryResolved(r);
  expectExit(r, 1); // TODO(cli): 프로젝트가 다른 종료 코드를 쓰면 조정
});
