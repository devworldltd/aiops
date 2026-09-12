/**
 * smoke/04-critical-readonly.test.mjs — 핵심 read-only 흐름 (prod 안전)
 *
 * templates/e2e/smoke/04-critical-crud.spec.ts 의 CLI 대응물이지만, CLI 에는 배포된
 * prod 대상이 없다(기술 스펙 결정 (e)) — 따라서 쓰기/삭제(CRUD)가 아니라 프로젝트의
 * 핵심 read-only 서브커맨드 1건을 검증한다. 데이터 생성/tearDown 이 없다.
 */
import { test } from 'node:test';
import { runCli } from '../lib/run-cli.mjs';
import { expectExit, expectEntryResolved } from '../lib/assert-cli.mjs';

test('@smoke 핵심 read-only 서브커맨드가 정상 동작한다', async () => {
  // TODO(cli): 프로젝트의 핵심 read-only 서브커맨드로 교체 (예: ['list', '--limit=1'])
  const r = await runCli(['--version']);
  expectEntryResolved(r);
  expectExit(r, 0);
});
