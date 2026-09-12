#!/usr/bin/env node
/**
 * runner/run-e2e.mjs — ★ CLI E2E 러너 진입점 (이슈 #41)
 *
 * 호출: node runner/run-e2e.mjs --mode=full|smoke [--dirs=<csv>] [--dry-run]
 * 입력:
 *   --mode  (선택, 기본 full)
 *   --dirs  (선택, 미지정 시 mode 기본 경로 'full/'|'smoke/' 를 cwd 기준으로 사용)
 *   env: E2E_CLI_BIN, E2E_MODE, E2E_FULL_PATHS, E2E_SMOKE_PATHS, E2E_PTY=1(선택)
 *
 * 동작: 대상 디렉토리에서 `*.test.mjs` 를 수집 → `node --test --test-reporter=tap <files>` 를
 *       spawn → TAP 을 stdout 에 스트리밍 + ok/not ok/# SKIP 집계 → 요약 1줄 + 마지막 줄 1줄 출력.
 *
 * ── 러너 판정 불변식 (T13/T14/T15 — 반드시 지킬 것) ──────────────────────────────
 *   1) 실행된 테스트가 0건이면 PASS 가 아니라
 *        E2E_ENV_ERROR=cli_scenario_dir_empty:<mode>   (exit 2)
 *   2) TAP 파싱에 실패하면 PASS 로 폴백하지 않는다 — 환경 오류로 처리한다.
 *        E2E_ENV_ERROR=cli_runner_tap_parse_failed     (exit 2)
 *   3) **`passed >= 1` 이 아니면 PASS 로 판정하지 않는다.**
 *      전부 SKIP(PTY 미설치 등)인 경우 — failed==0 이지만 passed==0 이면 PASS 가 아니라 FAIL 로 판정한다.
 *   4) `cli_entry_not_found`(spawn 자체 불가 = 환경 오류)와
 *      "바이너리는 있으나 비정상 종료"(개별 테스트 FAIL 로 집계)를 명확히 구분한다:
 *      전자는 runner 가 node --test 를 spawn 하기도 전에 게이트에서 걸러 exit 2 로 종료하고,
 *      후자는 개별 시나리오(*.test.mjs) 내부에서 `expectExit()` 등이 assert 실패로 처리해
 *      TAP 의 `not ok` 로 집계된다(=최종 E2E_RESULT=FAIL, exit 1).
 *
 * 출력 마지막 줄 (정확히 1줄, 뒤 공백·개행 금지):
 *   E2E_RESULT=PASS        (failed==0 && passed>=1)     exit 0
 *   E2E_RESULT=FAIL        (failed>=1 이거나 전부 SKIP)  exit 1
 *   E2E_ENV_ERROR=<reason> (사전 검사 실패·러너 이상)    exit 2
 * 요약 줄: ── 요약: 총 N (Passed p / Failed f / Skipped s) · T s
 */
import { spawn } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { resolveCliEntry } from '../lib/run-cli.mjs';

const RUNNER_TIMEOUT_MS = 10 * 60 * 1000; // 10분 상한

function parseArgs(argv) {
  const out = { mode: null, dirs: null, dryRun: false };
  for (const a of argv) {
    if (a === '--dry-run') out.dryRun = true;
    else if (a.startsWith('--mode=')) out.mode = a.slice('--mode='.length);
    else if (a.startsWith('--dirs=')) out.dirs = a.slice('--dirs='.length);
  }
  return out;
}

function printLast(line) {
  process.stdout.write(`${line}\n`);
}

function envError(reason, code = 2) {
  printLast(`E2E_ENV_ERROR=${reason}`);
  process.exitCode = code;
}

function splitCsv(v) {
  return v.split(/[,\s]+/).map((s) => s.trim()).filter(Boolean);
}

/** mode 기본 디렉토리 결정 (기술 스펙: e2e_full_paths/e2e_smoke_paths 재해석 — 값 의미만 CLI 테스트 디렉토리) */
function resolveDirs(mode, dirsArg) {
  if (dirsArg) return splitCsv(dirsArg);
  const envKey = mode === 'smoke' ? 'E2E_SMOKE_PATHS' : 'E2E_FULL_PATHS';
  const envVal = process.env[envKey];
  if (envVal) return splitCsv(envVal);
  return [mode === 'smoke' ? 'smoke' : 'full'];
}

/** 디렉토리들에서 *.test.mjs 파일을 수집한다(1단계 — 하위 재귀 없음). */
function collectTestFiles(dirs, cwd) {
  const files = [];
  for (const d of dirs) {
    const abs = path.isAbsolute(d) ? d : path.resolve(cwd, d);
    if (!existsSync(abs)) continue;
    let entries = [];
    try {
      entries = readdirSync(abs, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      if (e.isFile() && e.name.endsWith('.test.mjs')) {
        files.push(path.join(abs, e.name));
      }
    }
  }
  return files.sort();
}

/** node --test TAP 요약 라인을 파싱한다. 하나라도 누락되면 파싱 실패로 간주한다. */
function parseTapSummary(stdout) {
  const pick = (label) => {
    const m = stdout.match(new RegExp(`^# ${label} (\\d+)\\s*$`, 'm'));
    return m ? Number(m[1]) : null;
  };
  const tests = pick('tests');
  const pass = pick('pass');
  const fail = pick('fail');
  const skipped = pick('skipped');
  if (tests === null || pass === null || fail === null || skipped === null) {
    return null;
  }
  return { tests, pass, fail, skipped };
}

async function runTapProcess(files, cwd) {
  return new Promise((resolve) => {
    const child = spawn(
      process.execPath,
      ['--test', '--test-reporter=tap', ...files],
      { cwd, env: process.env, shell: false },
    );

    let stdout = '';
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
      setTimeout(() => child.kill('SIGKILL'), 1000);
    }, RUNNER_TIMEOUT_MS);

    child.stdout.on('data', (d) => {
      const s = d.toString('utf8');
      stdout += s;
      process.stdout.write(s); // TAP 스트리밍
    });
    child.stderr.on('data', (d) => process.stderr.write(d));

    child.on('close', (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stdout, timedOut });
    });
    child.on('error', (err) => {
      clearTimeout(timer);
      resolve({ code: null, signal: null, stdout, timedOut, spawnError: err.message });
    });
  });
}

async function main() {
  const cwd = process.cwd();
  const args = parseArgs(process.argv.slice(2));

  const mode = args.mode || process.env.E2E_MODE || 'full';
  if (mode !== 'full' && mode !== 'smoke') {
    envError(`invalid_mode:${mode}`);
    return;
  }

  const dirs = resolveDirs(mode, args.dirs);
  const files = collectTestFiles(dirs, cwd);

  if (files.length === 0) {
    envError(`cli_scenario_dir_empty:${mode}`);
    return;
  }

  const entry = resolveCliEntry({ cwd });
  if (!entry) {
    envError('cli_entry_not_found');
    return;
  }

  if (args.dryRun) {
    console.log(`[dry-run] mode=${mode} dirs=${dirs.join(',')} files=${files.length}`);
    console.log(`[dry-run] cli_entry=${entry}`);
    printLast('E2E_RESULT=PASS');
    process.exitCode = 0;
    return;
  }

  const { code, stdout, timedOut, spawnError } = await runTapProcess(files, cwd);

  const summary = parseTapSummary(stdout);
  if (summary === null) {
    if (spawnError) process.stderr.write(`[run-e2e] spawn error: ${spawnError}\n`);
    envError('cli_runner_tap_parse_failed');
    return;
  }

  const { tests, pass, fail, skipped } = summary;
  const durationMatch = stdout.match(/^# duration_ms ([\d.]+)\s*$/m);
  const durationS = durationMatch ? (Number(durationMatch[1]) / 1000).toFixed(1) : '0.0';

  console.log(`── 요약: 총 ${tests} (Passed ${pass} / Failed ${fail} / Skipped ${skipped}) · ${durationS}s`);

  // 러너 자체 이상 종료 판정 (G6): TAP 파싱은 성공했으나 exit code 가 정상 범위(0/1) 밖.
  if (code !== 0 && code !== 1) {
    envError(`cli_runner_runtime:exit_${code === null ? (timedOut ? 'timeout' : 'null') : code}`);
    return;
  }

  // ── 판정 불변식 ──
  if (fail >= 1) {
    printLast('E2E_RESULT=FAIL');
    process.exitCode = 1;
    return;
  }
  if (pass >= 1) {
    printLast('E2E_RESULT=PASS');
    process.exitCode = 0;
    return;
  }
  // fail==0 && pass==0 → 전부 SKIP(또는 그에 준하는 결과). PASS 로 판정하지 않는다.
  console.log('[run-e2e] 판정: 실행된 테스트가 전부 SKIP 이거나 통과 0건 — PASS 로 판정하지 않음');
  printLast('E2E_RESULT=FAIL');
  process.exitCode = 1;
}

main();
