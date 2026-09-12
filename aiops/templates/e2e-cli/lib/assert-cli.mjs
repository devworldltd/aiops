/**
 * lib/assert-cli.mjs — 어서션 헬퍼 (node:assert/strict 위에 얇게 얹음)
 *
 * 모든 실패 메시지는 "기대/실제 + stderr 첫 3줄" 을 포함한다(와이어프레임 §3-B 출력 형태).
 * `r` 은 lib/run-cli.mjs 의 `runCli()` 결과(Result) 객체를 받는다.
 */
import assert from 'node:assert/strict';

function stderrHead(r, n = 3) {
  return (r.stderr || '').split('\n').slice(0, n).join('\n');
}

function fail(message, r) {
  const head = stderrHead(r);
  throw new assert.AssertionError({
    message: head ? `${message}\n--- stderr(첫 3줄) ---\n${head}` : message,
  });
}

/** 종료 코드가 기대값과 일치하는지 확인한다. */
export function expectExit(r, expected) {
  if (r.code !== expected) {
    fail(`종료 코드 기대=${expected} 실제=${r.code} (signal=${r.signal ?? 'null'})`, r);
  }
}

/** stdout 이 부분 문자열을 포함하는지 확인한다. */
export function expectStdoutContains(r, needle) {
  if (!r.stdout.includes(needle)) {
    fail(`stdout 에 "${needle}" 포함 기대. 실제 stdout(앞 200자)=${r.stdout.slice(0, 200)}`, r);
  }
}

/** stdout 이 정규식과 매치하는지 확인한다. */
export function expectStdoutMatches(r, re) {
  if (!re.test(r.stdout)) {
    fail(`stdout 이 정규식 ${re} 와 매치하지 않음. 실제 stdout(앞 200자)=${r.stdout.slice(0, 200)}`, r);
  }
}

/** stderr 가 비어있는지 확인한다(정상 출력은 stdout, 오류만 stderr — full/06). */
export function expectStderrEmpty(r) {
  if (r.stderr.trim() !== '') {
    fail(`stderr 가 비어있어야 하나 값이 있음`, r);
  }
}

/** stderr 가 부분 문자열을 포함하는지 확인한다. */
export function expectStderrContains(r, needle) {
  if (!r.stderr.includes(needle)) {
    fail(`stderr 에 "${needle}" 포함 기대`, r);
  }
}

/** stdout 을 JSON 으로 파싱해 반환한다(--json 모드 계약 검증용). */
export function expectJsonStdout(r) {
  try {
    return JSON.parse(r.stdout);
  } catch (e) {
    fail(`stdout 이 유효한 JSON 이 아님: ${e.message}`, r);
    return undefined; // unreachable — fail()이 throw
  }
}

/** 타임아웃되지 않았는지 확인한다(엣지케이스: 무한대기 방지 — full/07). */
export function expectNoTimeout(r) {
  if (r.timedOut) {
    fail(`명령이 타임아웃됨 (durationMs=${r.durationMs})`, r);
  }
}

/** CLI 진입점 해석 자체가 실패하지 않았는지 확인한다. */
export function expectEntryResolved(r) {
  if (r.error === 'cli_entry_not_found') {
    fail(`CLI 엔트리 해석 실패 — E2E_CLI_BIN 또는 package.json bin 확인 필요`, r);
  }
}
