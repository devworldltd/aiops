/**
 * lib/run-cli.mjs — 명령 실행 래퍼 (비대화형 child_process, 이슈 #41 결정 (b))
 *
 * runCli(argv: string[], opts?) -> Promise<Result>
 *   opts = { cwd, env, timeoutMs = 30000, stdin = '', bin = resolveCliEntry() }
 *   Result = { code:number|null, signal:string|null, stdout:string, stderr:string,
 *              durationMs:number, timedOut:boolean, argv:string[], entry:string|null,
 *              error?:'cli_entry_not_found' }
 *
 * 설계 원칙:
 *   - `child_process.spawn` 은 `shell:false` 고정 — 셸 인젝션·따옴표 문제 차단.
 *   - stdout/stderr 는 별도 버퍼로 전량 캡처(스트리밍 아님 — 어서션은 완료 후 문자열 비교).
 *   - `timeoutMs` 초과 시 SIGTERM → 1s 후 SIGKILL. throw 하지 않고 `timedOut:true` 로 반환한다.
 *     판정(성공/실패)은 호출자(어서션 헬퍼)의 몫이다.
 *   - 실행 대상 바이너리는 `E2E_CLI_BIN`(없으면 `package.json` `bin` 첫 엔트리) 로 해석한다.
 *     미해석 시 `entry:null` + `error:'cli_entry_not_found'` 를 담아 반환한다(throw 금지 —
 *     러너/게이트가 이 신호로 `E2E_ENV_ERROR=cli_entry_not_found` 를 판정한다).
 */
import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

/**
 * `E2E_CLI_BIN` 환경변수 또는 `package.json` 의 `bin` 첫 엔트리로 CLI 진입점을 해석한다.
 * @param {{cwd?: string}} opts
 * @returns {string|null} 절대경로 또는 미해석 시 null
 */
export function resolveCliEntry(opts = {}) {
  const cwd = opts.cwd || process.cwd();

  const envBin = process.env.E2E_CLI_BIN;
  if (envBin) {
    const resolved = path.isAbsolute(envBin) ? envBin : path.resolve(cwd, envBin);
    return existsSync(resolved) ? resolved : null;
  }

  const pkgPath = path.resolve(cwd, 'package.json');
  if (!existsSync(pkgPath)) return null;

  let pkg;
  try {
    pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
  } catch {
    return null;
  }
  if (!pkg.bin) return null;

  let binRel;
  if (typeof pkg.bin === 'string') {
    binRel = pkg.bin;
  } else if (typeof pkg.bin === 'object') {
    const keys = Object.keys(pkg.bin);
    if (keys.length === 0) return null;
    binRel = pkg.bin[keys[0]];
  } else {
    return null;
  }
  if (!binRel) return null;

  const resolved = path.resolve(cwd, binRel);
  return existsSync(resolved) ? resolved : null;
}

function isJsEntry(entry) {
  return /\.(mjs|cjs|js)$/i.test(entry);
}

/**
 * CLI 명령을 비대화형으로 실행한다.
 * @param {string[]} argv
 * @param {{cwd?:string, env?:object, timeoutMs?:number, stdin?:string, bin?:string}} [opts]
 * @returns {Promise<object>} Result
 */
export function runCli(argv = [], opts = {}) {
  const cwd = opts.cwd || process.cwd();
  const env = opts.env || process.env;
  const timeoutMs = opts.timeoutMs ?? 30000;
  const stdin = opts.stdin ?? '';
  const entry = opts.bin || resolveCliEntry({ cwd });

  const startedAt = Date.now();

  if (!entry) {
    return Promise.resolve({
      code: null,
      signal: null,
      stdout: '',
      stderr: '',
      durationMs: 0,
      timedOut: false,
      argv,
      entry: null,
      error: 'cli_entry_not_found',
    });
  }

  const spawnCmd = isJsEntry(entry) ? process.execPath : entry;
  const spawnArgs = isJsEntry(entry) ? [entry, ...argv] : [...argv];

  return new Promise((resolve) => {
    const child = spawn(spawnCmd, spawnArgs, { cwd, env, shell: false });

    let stdout = '';
    let stderr = '';
    let timedOut = false;
    let killTimer = null;
    let termTimer = null;

    const finish = (code, signal) => {
      if (termTimer) clearTimeout(termTimer);
      if (killTimer) clearTimeout(killTimer);
      resolve({
        code,
        signal,
        stdout,
        stderr,
        durationMs: Date.now() - startedAt,
        timedOut,
        argv,
        entry,
      });
    };

    child.stdout.on('data', (d) => { stdout += d.toString('utf8'); });
    child.stderr.on('data', (d) => { stderr += d.toString('utf8'); });

    termTimer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
      killTimer = setTimeout(() => child.kill('SIGKILL'), 1000);
    }, timeoutMs);

    child.on('error', (err) => {
      stderr += `\n[run-cli] spawn error: ${err.message}`;
      finish(null, null);
    });

    child.on('close', (code, signal) => finish(code, signal));

    if (stdin) {
      child.stdin.write(stdin);
    }
    child.stdin.end();
  });
}
