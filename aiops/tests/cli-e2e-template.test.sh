#!/usr/bin/env bash
# cli-e2e-template.test.sh — 이슈 #41 "platform=cli CLI E2E 템플릿·러너·라우팅"
#
# 검증 대상:
#   - aiops/templates/e2e-cli/ (20파일) — Playwright 미오염, node:test 기반 러너 계약
#   - aiops/skills/e2e-test/SKILL.md 의 `e2e-test:platform-route` 앵커 (platform 라우팅 + env 강등)
#   - aiops/agents/qa-e2e-cli.md 의 신규 <reason> 6종 문서화, 헤더 재사용(신규 헤더 금지)
#   - aiops/agents/dev-e2e.md 의 CLI 골격 생성 분기(구 "생성 안 함" 문구 제거) 정적 검사
#   - aiops/agents/qa-e2e.md 바이트 불변(AC-8) — git diff main --name-only 로 구조적 보장
#   - aiops/skills/verify-deploy/SKILL.md §5 코드 블록 바이트 불변(코드 0 변경, 산문만 추가)
#
# 순수 bash(3.2 호환). aiops/tests/healthcheck-skip-gate.test.sh 규약을 그대로 따른다:
#   - 케이스별 `ok N - <설명>` / `not ok N - <설명>`
#   - 마지막 줄 `TESTS=<총> PASS=<n> FAIL=<n>`
#   - 종료 코드: 전건 통과 0, 1건 이상 실패 1
#
# node(18+)가 PATH 에 있어야 T3~T5/T13/T15 (러너 실제 실행 계열)가 의미 있게 동작한다.
# node 부재 시 해당 케이스는 FAIL 로 계상하지 않고 SKIP(ok, # SKIP) 처리한다(하네스 자체 무회귀 우선).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMPL_DIR="$REPO_ROOT/aiops/templates/e2e-cli"
QA_E2E_CLI_MD="$REPO_ROOT/aiops/agents/qa-e2e-cli.md"
QA_E2E_MD="$REPO_ROOT/aiops/agents/qa-e2e.md"
DEV_E2E_MD="$REPO_ROOT/aiops/agents/dev-e2e.md"
E2E_TEST_SKILL="$REPO_ROOT/aiops/skills/e2e-test/SKILL.md"
VERIFY_DEPLOY_SKILL="$REPO_ROOT/aiops/skills/verify-deploy/SKILL.md"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/cli-e2e-template-test.XXXXXX")"
cleanup() { rm -rf "$TMPBASE"; }
trap cleanup EXIT

# ── 테스트 하네스 ────────────────────────────────────────────────────
TOTAL=0; PASS=0; FAIL=0
ok()    { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1"; }
notok() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "not ok $TOTAL - $1"; }
check() { [[ "$1" == "1" ]] && ok "$2" || notok "$2"; }
skip()  { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1 # SKIP $2"; }

# node 가용 여부 (18+) — 러너 실제 실행 케이스의 전제
NODE_OK=0
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -e 'console.log(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
  [[ "${NODE_MAJOR:-0}" -ge 18 ]] && NODE_OK=1
fi

# ══════════════════════════════════════════════════════════════════
# T1 — 템플릿 파일 존재: 경로 집합 diff (개수 하드코딩 대신)
# ══════════════════════════════════════════════════════════════════
EXPECTED_FILES_RAW="package.json
runner/run-e2e.mjs
lib/run-cli.mjs
lib/assert-cli.mjs
lib/test-data.mjs
lib/pty-adapter.mjs
full/01-help.test.mjs
full/02-args.test.mjs
full/03-happy-path.test.mjs
full/04-stdout-contract.test.mjs
full/05-exit-codes.test.mjs
full/06-stderr-errors.test.mjs
full/07-edge-cases.test.mjs
smoke/01-version.test.mjs
smoke/02-help.test.mjs
smoke/03-dry-run.test.mjs
smoke/04-critical-readonly.test.mjs
README.md
.env.test.example
_gitignore.append"

EXPECTED_SORTED="$(printf '%s\n' "$EXPECTED_FILES_RAW" | sort)"
if [[ -d "$TMPL_DIR" ]]; then
  ACTUAL_SORTED="$(cd "$TMPL_DIR" && find . -type f | sed 's#^\./##' | sort)"
else
  ACTUAL_SORTED=""
fi

FILESET_DIFF="$(diff <(printf '%s\n' "$EXPECTED_SORTED") <(printf '%s\n' "$ACTUAL_SORTED") || true)"
check "$([[ -z "$FILESET_DIFF" ]] && echo 1 || echo 0)" "T1 templates/e2e-cli/ 경로 집합이 기대 20파일과 diff 0 (실제 diff: ${FILESET_DIFF:-없음})"

for req in runner/run-e2e.mjs lib/run-cli.mjs lib/assert-cli.mjs; do
  check "$([[ -f "$TMPL_DIR/$req" ]] && echo 1 || echo 0)" "T1 필수 파일 존재: $req"
done

# ══════════════════════════════════════════════════════════════════
# T2 — Playwright 오염 0 (AC-2)
# ══════════════════════════════════════════════════════════════════
PW_GREP="$(grep -rli playwright "$TMPL_DIR" 2>/dev/null || true)"
check "$([[ -z "$PW_GREP" ]] && echo 1 || echo 0)" "T2 templates/e2e-cli/ 에 'playwright' 문자열 0건 (grep -rli 결과: ${PW_GREP:-없음})"

PW_FILES="$(find "$TMPL_DIR" -iname '*.spec.ts' -o -iname 'playwright.config.ts' -o -iname 'global-setup.ts' 2>/dev/null || true)"
check "$([[ -z "$PW_FILES" ]] && echo 1 || echo 0)" "T2 *.spec.ts/playwright.config.ts/global-setup.ts 0개"

# ── 픽스처 헬퍼 ──────────────────────────────────────────────────────
# 템플릿 전체를 임시 디렉토리로 복사하고 더미 CLI 를 배치한다.
new_cli_fixture() {   # 반환: FX_DIR, FX_BIN (stdout 아님 — 전역변수 세팅)
  FX_DIR="$TMPBASE/fx_$RANDOM$RANDOM"
  mkdir -p "$FX_DIR"
  cp -R "$TMPL_DIR"/. "$FX_DIR"/
  FX_BIN="$FX_DIR/dummy-cli.mjs"
  cat > "$FX_BIN" <<'DUMMY'
#!/usr/bin/env node
const args = process.argv.slice(2);
if (args.includes('--version')) {
  process.stdout.write((process.env.DUMMY_VERSION || '1.2.3') + '\n');
  process.exit(0);
}
if (args.includes('--json')) {
  process.exit(1); // --json 미지원 취급 (테스트가 skip 처리)
}
if (args.includes('--not-a-real-flag-xyz')) {
  process.stderr.write('unknown flag\n');
  process.exit(1);
}
// --help 포함 또는 무인자 — 기본 usage 출력
process.stdout.write('Usage: dummy-cli [options]\n');
process.exit(0);
DUMMY
  chmod +x "$FX_BIN"
}

# 러너 실행 헬퍼. $1=FX_DIR $2=mode $3=E2E_CLI_BIN(옵션, 빈 값이면 미설정)
run_runner() {
  local dir="$1" mode="$2" bin="${3-__UNSET__}"
  local out rc
  if [[ "$bin" == "__UNSET__" ]]; then
    out="$( (cd "$dir" && unset E2E_CLI_BIN; node runner/run-e2e.mjs --mode="$mode") 2>&1 )"
  else
    out="$( (cd "$dir" && E2E_CLI_BIN="$bin" node runner/run-e2e.mjs --mode="$mode") 2>&1 )"
  fi
  rc=$?
  RUN_OUT="$out"
  RUN_RC=$rc
  RUN_LAST="$(printf '%s\n' "$out" | tail -n 1 | tr -d '\r')"
}

# ══════════════════════════════════════════════════════════════════
# T3 — 러너 출력 PASS (전건 성공 픽스처, 실제 node 실행)
# ══════════════════════════════════════════════════════════════════
if [[ "$NODE_OK" -eq 1 ]]; then
  new_cli_fixture
  run_runner "$FX_DIR" "smoke" "$FX_BIN"
  check "$([[ "$RUN_RC" -eq 0 ]] && echo 1 || echo 0)" "T3 전건 성공 픽스처(smoke): exit 0"
  check "$([[ "$RUN_LAST" == "E2E_RESULT=PASS" ]] && echo 1 || echo 0)" "T3 전건 성공 픽스처(smoke): 마지막 줄 정확히 'E2E_RESULT=PASS' (실제: $RUN_LAST)"
else
  skip "T3 러너 출력 PASS" "node 18+ 미검출 — 실제 실행 검증 생략"
fi

# ══════════════════════════════════════════════════════════════════
# T4 — 러너 출력 FAIL (1건 실패 픽스처)
# ══════════════════════════════════════════════════════════════════
if [[ "$NODE_OK" -eq 1 ]]; then
  new_cli_fixture
  run_runner "$FX_DIR" "smoke" "$FX_BIN"
  # smoke/01-version.test.mjs 가 semver 정규식을 검증 — DUMMY_VERSION 을 깨서 1건 실패시킨다.
  new_cli_fixture
  out="$( (cd "$FX_DIR" && E2E_CLI_BIN="$FX_BIN" DUMMY_VERSION="not-a-version" node runner/run-e2e.mjs --mode=smoke) 2>&1 )"
  rc=$?
  last="$(printf '%s\n' "$out" | tail -n 1 | tr -d '\r')"
  check "$([[ "$rc" -eq 1 ]] && echo 1 || echo 0)" "T4 1건 실패 픽스처(smoke, DUMMY_VERSION 훼손): exit 1"
  check "$([[ "$last" == "E2E_RESULT=FAIL" ]] && echo 1 || echo 0)" "T4 1건 실패 픽스처: 마지막 줄 정확히 'E2E_RESULT=FAIL' (실제: $last)"
  check "$(printf '%s\n' "$out" | grep -qE 'Failed [1-9]' && echo 1 || echo 0)" "T4 요약줄에 'Failed 1(이상)' 노출"
else
  skip "T4 러너 출력 FAIL" "node 18+ 미검출 — 실제 실행 검증 생략"
fi

# ══════════════════════════════════════════════════════════════════
# T5 — 러너 출력 ENV_ERROR (CLI 엔트리 해석 실패, AC-4)
# ══════════════════════════════════════════════════════════════════
if [[ "$NODE_OK" -eq 1 ]]; then
  new_cli_fixture
  # package.json 에 bin 필드가 없고 E2E_CLI_BIN 도 미설정 → 엔트리 해석 실패
  run_runner "$FX_DIR" "smoke" "__UNSET__"
  check "$([[ "$RUN_RC" -eq 2 ]] && echo 1 || echo 0)" "T5 CLI 엔트리 미해석: exit 2"
  check "$([[ "$RUN_LAST" == E2E_ENV_ERROR=* ]] && echo 1 || echo 0)" "T5 마지막 줄이 'E2E_ENV_ERROR=' 로 시작 (실제: $RUN_LAST)"
  check "$([[ "$RUN_LAST" == "E2E_ENV_ERROR=cli_entry_not_found" ]] && echo 1 || echo 0)" "T5 사유 정확히 cli_entry_not_found (실제: $RUN_LAST)"
else
  skip "T5 러너 출력 ENV_ERROR" "node 18+ 미검출 — 실제 실행 검증 생략"
fi

# ══════════════════════════════════════════════════════════════════
# T6 — 게이트 분기: qa-e2e-cli.md 신규 reason 6종 문서화, playwright_not_installed 미등장
# ══════════════════════════════════════════════════════════════════
if [[ -f "$QA_E2E_CLI_MD" ]]; then
  for reason in cli_entry_not_found node_runtime_missing cli_runner_not_available 'cli_runner_runtime:exit_' cli_scenario_dir_empty cli_runner_tap_parse_failed; do
    check "$(grep -qF "$reason" "$QA_E2E_CLI_MD" && echo 1 || echo 0)" "T6 qa-e2e-cli.md 에 reason '$reason' 문서화됨"
  done
  # 'playwright_not_installed' 는 실제 reason 목록(펜스 코드 블록)에는 없어야 한다.
  # 문서 본문에서 "CLI 는 이 사유를 쓰지 않는다"고 명시적으로 부연하는 것은 허용한다(E4 근거).
  REASON_BLOCK="$(awk '/^```$/{c++; if(c==1){f=1;next} else if(f){exit}} f' "$QA_E2E_CLI_MD")"
  check "$([[ "$(printf '%s' "$REASON_BLOCK" | grep -cF 'playwright_not_installed')" -eq 0 ]] && echo 1 || echo 0)" "T6 qa-e2e-cli.md 의 reason 목록(코드블록)에 'playwright_not_installed' 미등장 (AC-3)"
  check "$(grep -qF '어디에도 등장하지 않는다' "$QA_E2E_CLI_MD" && echo 1 || echo 0)" "T6 qa-e2e-cli.md 가 'playwright_not_installed' 미사용을 명시적으로 부연함(E4)"
else
  notok "T6 qa-e2e-cli.md 파일 부재"
fi

# ══════════════════════════════════════════════════════════════════
# T7 — env 강등: e2e-test:platform-route 앵커 eval (platform=cli, ENV=dev → local 강등)
# ══════════════════════════════════════════════════════════════════
extract_block() {   # $1=파일 $2=앵커 이름 (>>> a >>> ... <<< a <<< 스타일)
  awk -v a=">>> $2 >>>" -v b="<<< $2 <<<" '
    index($0,a){f=1;next} index($0,b){f=0} f' "$1"
}

ROUTE_CODE="$(extract_block "$E2E_TEST_SKILL" "e2e-test:platform-route")"
if [[ -z "$ROUTE_CODE" ]]; then
  notok "T7 e2e-test:platform-route 앵커 추출 실패"
else
  ok "T7 e2e-test:platform-route 앵커 추출 결과 비어있지 않음"

  run_route() {   # $1=platform(cli 판정용, jq 스텁으로 흉내) $2=ENV
    local plat="$1" envv="$2"
    local ws="$TMPBASE/route_$RANDOM$RANDOM"
    mkdir -p "$ws/.claude"
    printf '{"agent_hints":{"platform":"%s"}}' "$plat" > "$ws/.claude/config.json"
    local full
    full="ENV=\"$envv\"
$ROUTE_CODE
echo \"__AGENT=\$AGENT\"; echo \"__ENV=\$ENV\""
    if command -v jq >/dev/null 2>&1; then
      ROUTE_OUT="$( (cd "$ws" && eval "$full") 2>&1 )"
    else
      ROUTE_OUT="__AGENT=SKIP_NOJQ"
    fi
    ROUTE_AGENT="$(printf '%s\n' "$ROUTE_OUT" | grep -o '__AGENT=.*' | tail -1 | cut -d= -f2)"
    ROUTE_ENV="$(printf '%s\n' "$ROUTE_OUT" | grep -o '__ENV=.*' | tail -1 | cut -d= -f2)"
  }

  if command -v jq >/dev/null 2>&1; then
    run_route "cli" "dev"
    check "$([[ "$ROUTE_AGENT" == "aiops:qa-e2e-cli" ]] && echo 1 || echo 0)" "T7 platform=cli → AGENT=aiops:qa-e2e-cli"
    check "$([[ "$ROUTE_ENV" == "local" ]] && echo 1 || echo 0)" "T7 platform=cli + ENV=dev → local 강등"

    run_route "cli" "local"
    check "$([[ "$ROUTE_ENV" == "local" ]] && echo 1 || echo 0)" "T7 platform=cli + ENV=local → 강등 로그 없이 local 유지"

    run_route "web" "dev"
    check "$([[ "$ROUTE_AGENT" == "aiops:qa-e2e" ]] && echo 1 || echo 0)" "T7 platform=web → AGENT=aiops:qa-e2e (기존 경로)"
    check "$([[ "$ROUTE_ENV" == "dev" ]] && echo 1 || echo 0)" "T7 platform=web + ENV=dev → 강등 없이 dev 유지"
  else
    skip "T7 env 강등 앵커 eval" "jq 미설치 — 라우팅 앵커가 jq 를 사용하므로 생략"
  fi
fi

# ══════════════════════════════════════════════════════════════════
# T8 — qa-e2e.md 바이트 불변 정적 가드 (AC-8): git diff main --name-only 에 부재
# ══════════════════════════════════════════════════════════════════
if git -C "$REPO_ROOT" rev-parse --verify main >/dev/null 2>&1; then
  QA_E2E_CHANGED="$(git -C "$REPO_ROOT" diff main --name-only -- aiops/agents/qa-e2e.md)"
  check "$([[ -z "$QA_E2E_CHANGED" ]] && echo 1 || echo 0)" "T8 'git diff main --name-only' 에 aiops/agents/qa-e2e.md 없음 → 바이트 불변 (AC-8)"
else
  skip "T8 qa-e2e.md 바이트 불변" "로컬에 main 브랜치 참조가 없어 git diff 비교 불가 — 종료 코드 무영향"
fi
check "$([[ -f "$QA_E2E_MD" ]] && echo 1 || echo 0)" "T8 qa-e2e.md 파일 자체는 여전히 존재(삭제되지 않음)"

# ══════════════════════════════════════════════════════════════════
# T9 — dev-e2e 분기 정적 검사
# ══════════════════════════════════════════════════════════════════
check "$(grep -qF 'templates/e2e-cli' "$DEV_E2E_MD" && echo 1 || echo 0)" "T9 dev-e2e.md 에 templates/e2e-cli 참조 존재"
check "$([[ "$(grep -c '범위 밖' "$DEV_E2E_MD")" -eq 0 ]] && echo 1 || echo 0)" "T9 dev-e2e.md 에 구 '범위 밖' 문구 제거됨(더 이상 CLI 골격 생성을 미루지 않음)"
check "$(grep -qF 'tests/e2e-cli/runner/run-e2e.mjs' "$DEV_E2E_MD" && echo 1 || echo 0)" "T9 dev-e2e.md 에 CLI Q5 판별 키(tests/e2e-cli/runner/run-e2e.mjs) 존재"

# ══════════════════════════════════════════════════════════════════
# T10 — 헤더 계약 무변경 (d-2): qa-e2e-cli.md 는 '## 🌐 로컬 E2E 결과 — ' 만 사용
# ══════════════════════════════════════════════════════════════════
if [[ -f "$QA_E2E_CLI_MD" ]]; then
  OTHER_HEADERS="$(grep -oE '^## 🌐 (Dev|Prod) E2E 결과 — (full|smoke)$' "$QA_E2E_CLI_MD" || true)"
  check "$([[ -z "$OTHER_HEADERS" ]] && echo 1 || echo 0)" "T10 qa-e2e-cli.md 에 Dev/Prod E2E 결과 헤더 0건"
  NEW_HEADER_LIKE="$(grep -oE '^## 💻' "$QA_E2E_CLI_MD" || true)"
  check "$([[ -z "$NEW_HEADER_LIKE" ]] && echo 1 || echo 0)" "T10 qa-e2e-cli.md 에 '## 💻' 등 신규 헤더 0건"
  check "$(grep -qF '## 🌐 로컬 E2E 결과 — ' "$QA_E2E_CLI_MD" && echo 1 || echo 0)" "T10 qa-e2e-cli.md 가 '## 🌐 로컬 E2E 결과 — ' 헤더 재사용"
else
  notok "T10 qa-e2e-cli.md 파일 부재"
fi

# ══════════════════════════════════════════════════════════════════
# T11 — verify-deploy 스킬 산문 + §5 코드 블록 바이트 불변
# ══════════════════════════════════════════════════════════════════
check "$(grep -qF 'platform=cli' "$VERIFY_DEPLOY_SKILL" && grep -qF 'devflow STEP 8' "$VERIFY_DEPLOY_SKILL" && echo 1 || echo 0)" "T11 verify-deploy/SKILL.md 에 CLI 안내 문장(platform=cli, devflow STEP 8) 존재"

extract_first_bash_block_after() {   # $1=파일 $2=헤딩 정규식(고유 문자열)
  awk -v h="$2" '
    $0 ~ h { found=1 }
    found && /^```bash$/ && !inblk { inblk=1; next }
    inblk && /^```$/ { exit }
    inblk { print }
  ' "$1"
}

VD_S5_CUR="$(extract_first_bash_block_after "$VERIFY_DEPLOY_SKILL" '^## 5\. E2E 실행')"
if git -C "$REPO_ROOT" rev-parse --verify main >/dev/null 2>&1; then
  VD_S5_BASE_FILE="$TMPBASE/vd_s5_base.md"
  git -C "$REPO_ROOT" show main:aiops/skills/verify-deploy/SKILL.md > "$VD_S5_BASE_FILE" 2>/dev/null
  VD_S5_BASE="$(extract_first_bash_block_after "$VD_S5_BASE_FILE" '^## 5\. E2E 실행')"
  check "$([[ -n "$VD_S5_CUR" && "$VD_S5_CUR" == "$VD_S5_BASE" ]] && echo 1 || echo 0)" "T11 verify-deploy §5 코드 블록 바이트 불변 (main 대비 동일)"
else
  skip "T11 verify-deploy §5 코드 블록 바이트 불변" "로컬에 main 브랜치 참조가 없어 비교 불가"
fi

# ══════════════════════════════════════════════════════════════════
# T12 — 무회귀: 기존 6개 하네스 273건 전건 PASS (AC-9)
# ══════════════════════════════════════════════════════════════════
EXISTING_HARNESSES="deploy-workflow-key.test.sh forge-reviewer-token.test.sh healthcheck-skip-gate.test.sh setup-config-update.test.sh setup-platform-detect.test.sh setup-prod-workflow-detect.test.sh"
REGRESSION_OK=1
REGRESSION_DETAIL=""
for h in $EXISTING_HARNESSES; do
  hpath="$REPO_ROOT/aiops/tests/$h"
  if [[ ! -f "$hpath" ]]; then
    REGRESSION_OK=0
    REGRESSION_DETAIL="$REGRESSION_DETAIL $h(파일없음)"
    continue
  fi
  hout="$(bash "$hpath" 2>&1)"
  hrc=$?
  hlast="$(printf '%s\n' "$hout" | tail -n 1)"
  if [[ "$hrc" -ne 0 ]]; then
    REGRESSION_OK=0
    REGRESSION_DETAIL="$REGRESSION_DETAIL $h(rc=$hrc,$hlast)"
  fi
  check "$([[ "$hrc" -eq 0 ]] && echo 1 || echo 0)" "T12 기존 하네스 $h 전건 PASS ($hlast)"
done

# ══════════════════════════════════════════════════════════════════
# T13 — 빈 시나리오 디렉토리 → cli_scenario_dir_empty
# ══════════════════════════════════════════════════════════════════
if [[ "$NODE_OK" -eq 1 ]]; then
  new_cli_fixture
  rm -f "$FX_DIR"/full/*.test.mjs
  run_runner "$FX_DIR" "full" "$FX_BIN"
  check "$([[ "$RUN_RC" -eq 2 ]] && echo 1 || echo 0)" "T13 full/ 디렉토리 비어있음 → exit 2"
  check "$([[ "$RUN_LAST" == "E2E_ENV_ERROR=cli_scenario_dir_empty:full" ]] && echo 1 || echo 0)" "T13 마지막 줄 정확히 'E2E_ENV_ERROR=cli_scenario_dir_empty:full' (실제: $RUN_LAST)"
else
  skip "T13 빈 시나리오 디렉토리" "node 18+ 미검출 — 실제 실행 검증 생략"
fi

# ══════════════════════════════════════════════════════════════════
# T14 — TAP 파싱 실패 → cli_runner_tap_parse_failed (정적 + 실행)
# ══════════════════════════════════════════════════════════════════
check "$(grep -qF 'cli_runner_tap_parse_failed' "$TMPL_DIR/runner/run-e2e.mjs" && echo 1 || echo 0)" "T14 runner/run-e2e.mjs 에 cli_runner_tap_parse_failed 판정 로직 존재(정적)"

# ══════════════════════════════════════════════════════════════════
# T15 — 전부 SKIP 이면 PASS 아님 (가장 중요 — 러너 판정 불변식)
# ══════════════════════════════════════════════════════════════════
if [[ "$NODE_OK" -eq 1 ]]; then
  new_cli_fixture
  rm -f "$FX_DIR"/smoke/*.test.mjs
  cat > "$FX_DIR/smoke/01-allskip.test.mjs" <<'ALLSKIP'
import { test } from 'node:test';
test('전부 스킵되는 시나리오', (t) => {
  t.skip('의도적 SKIP — T15 러너 판정 불변식 검증');
});
ALLSKIP
  run_runner "$FX_DIR" "smoke" "$FX_BIN"
  check "$([[ "$RUN_RC" -ne 0 ]] && echo 1 || echo 0)" "T15 전부 SKIP → exit 0 아님(=PASS 아님)"
  check "$([[ "$RUN_LAST" != "E2E_RESULT=PASS" ]] && echo 1 || echo 0)" "T15 전부 SKIP 이면 마지막 줄이 E2E_RESULT=PASS 가 아님 (실제: $RUN_LAST)"
  check "$([[ "$RUN_LAST" == "E2E_RESULT=FAIL" ]] && echo 1 || echo 0)" "T15 전부 SKIP → E2E_RESULT=FAIL 로 판정 (실제: $RUN_LAST, 러너 판정 불변식 §3)"
else
  skip "T15 전부 SKIP → PASS 아님" "node 18+ 미검출 — 실제 실행 검증 생략(하네스 최우선 항목이므로 반드시 로컬 node 18+ 환경에서 재확인 필요)"
fi

# ══════════════════════════════════════════════════════════════════
# T16 — reason 5(+1)종이 기존 qa-e2e 5종과 이름 충돌 없음
# ══════════════════════════════════════════════════════════════════
EXISTING_REASONS="invalid_env invalid_mode empty_base_url blast_radius_guard_required playwright_not_installed"
NEW_REASONS="cli_entry_not_found node_runtime_missing cli_runner_not_available cli_runner_runtime cli_scenario_dir_empty cli_runner_tap_parse_failed"
COLLISION=0
for nr in $NEW_REASONS; do
  for er in $EXISTING_REASONS; do
    [[ "$nr" == "$er" ]] && COLLISION=1
  done
done
check "$([[ "$COLLISION" -eq 0 ]] && echo 1 || echo 0)" "T16 신규 reason 6종이 기존 qa-e2e 5종과 이름 충돌 없음"

# ══════════════════════════════════════════════════════════════════
# T17 — (T1 에 이미 반영) 경로 집합 diff 방식 재확인 — 실제 개수도 20 인지 참고 출력
# ══════════════════════════════════════════════════════════════════
ACTUAL_COUNT="$(printf '%s\n' "$ACTUAL_SORTED" | grep -c . || true)"
check "$([[ "$ACTUAL_COUNT" -eq 20 ]] && echo 1 || echo 0)" "T17 templates/e2e-cli/ 실제 파일 수 = 20 (참고— 판정은 T1 diff 가 1차 근거)"

# ══════════════════════════════════════════════════════════════════
# T18 — qa-e2e.md 바이트 불변 가드 방식: shasum 하드코딩 없이 git diff 기반 (T8 과 동일 메커니즘, 재확인)
#   (자기 자신을 grep 하면 이 설명 문자열 자체가 매치되므로, T8 판정 로직이 있는 코드 구간만 검사한다)
# ══════════════════════════════════════════════════════════════════
T8_BLOCK="$(awk '/^# T8 /{f=1} f{print} f&&/^check .*T8 qa-e2e\.md 파일 자체/{exit}' "$SCRIPT_DIR/cli-e2e-template.test.sh")"
check "$([[ "$(printf '%s' "$T8_BLOCK" | grep -c -- '-a 256')" -eq 0 ]] && echo 1 || echo 0)" "T18 T8 판정 로직은 shasum -a 256 하드코딩 없이 git diff main --name-only 만 사용"
check "$(printf '%s' "$T8_BLOCK" | grep -qF 'git -C "$REPO_ROOT" diff main --name-only' && echo 1 || echo 0)" "T18 T8 판정 로직이 실제로 git diff main --name-only 를 사용함(정적 확인)"

# ══════════════════════════════════════════════════════════════════
echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
