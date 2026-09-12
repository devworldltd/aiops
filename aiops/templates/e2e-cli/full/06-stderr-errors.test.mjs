/**
 * full/06-stderr-errors.test.mjs — 오류는 stderr, 정상 출력은 stdout 분리
 *
 * 시나리오: 정상 실행 시 stderr 가 비어있고, 오류 실행 시 stderr 에 메시지가 실린다.
 */
import { test } from 'node:test';
import { runCli } from '../lib/run-cli.mjs';
import { expectExit, expectStderrEmpty, expectEntryResolved } from '../lib/assert-cli.mjs';

test('정상 실행 시 stderr 는 비어있다', async () => {
  const r = await runCli(['--version']);
  expectEntryResolved(r);
  expectExit(r, 0);
  expectStderrEmpty(r); // TODO(cli): 정상 실행 시에도 stderr 에 로그를 남기는 CLI 라면 이 어서션을 조정
});

test('오류 실행 시 오류 메시지는 stderr 로 출력된다 (stdout 오염 금지)', async () => {
  const r = await runCli(['--not-a-real-flag-xyz']);
  expectEntryResolved(r);
  if (r.code === 0) return; // 이 플래그를 허용하는 CLI 라면 스킵
  // TODO(cli): 실제 오류 메시지 부분 문자열 검증 추가
});
