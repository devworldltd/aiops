#!/usr/bin/env bash
# e2e-dry-run-token.test.sh — 이슈 #49 "dry-run 전용 결과 토큰 E2E_RESULT=DRY_RUN 도입"
#
# 검증 대상:
#   - 생산 5경로: aiops/agents/qa-e2e.md · qa-e2e-cli.md · qa-mobile-e2e.md,
#     aiops/skills/run-e2e/SKILL.md, aiops/templates/e2e-cli/runner/run-e2e.mjs
#   - 소비 측: aiops/skills/e2e-test/SKILL.md 결과 매핑(M6),
#     aiops/skills/merge-pr/SKILL.md §14.2 case 블록 불변(M7),
#     aiops/skills/merge-main/SKILL.md 차단/허용 목록 불변 + dry_run_only 사유(M8),
#     aiops/skills/devflow/SKILL.md · docs/USAGE.md · aiops/templates/e2e-cli/README.md 문서 반영(S1~S3)
#   - mutation: 토큰을 PASS 로 되돌리면 판정기가 실제로 위반을 검출하는지
#
# 순수 bash(3.2 호환 — 연관배열·${var^^}·mapfile 금지). 기존 하니스 규약을 그대로 따른다:
#   - 케이스별 `ok N - <설명>` / `not ok N - <설명>`
#   - 마지막 줄 `TESTS=<총> PASS=<n> FAIL=<n>`
#   - 종료 코드: 전건 통과 0, 1건 이상 실패 1
#
# node(18+)가 PATH 에 있어야 T1~T6·T19 (러너 실제 실행 계열)가 의미 있게 동작한다.
# node 부재 시 해당 케이스는 FAIL 로 계상하지 않고 SKIP(ok, # SKIP) 처리한다(하니스 자체 무회귀 우선).
# 원본 트리는 어떤 케이스도 오염시키지 않는다 — 모든 실행/치환은 mktemp -d 사본 위에서만 수행한다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMPL_DIR="$REPO_ROOT/aiops/templates/e2e-cli"
QA_E2E_MD="$REPO_ROOT/aiops/agents/qa-e2e.md"
QA_E2E_CLI_MD="$REPO_ROOT/aiops/agents/qa-e2e-cli.md"
QA_MOBILE_E2E_MD="$REPO_ROOT/aiops/agents/qa-mobile-e2e.md"
RUN_E2E_SKILL="$REPO_ROOT/aiops/skills/run-e2e/SKILL.md"
RUNNER_MJS="$REPO_ROOT/aiops/templates/e2e-cli/runner/run-e2e.mjs"
E2E_TEST_SKILL="$REPO_ROOT/aiops/skills/e2e-test/SKILL.md"
MERGE_PR_SKILL="$REPO_ROOT/aiops/skills/merge-pr/SKILL.md"
MERGE_MAIN_SKILL="$REPO_ROOT/aiops/skills/merge-main/SKILL.md"
DEVFLOW_SKILL="$REPO_ROOT/aiops/skills/devflow/SKILL.md"
USAGE_MD="$REPO_ROOT/docs/USAGE.md"
CLI_README="$REPO_ROOT/aiops/templates/e2e-cli/README.md"
DEPLOY_PROD_SKILL="$REPO_ROOT/aiops/skills/deploy-prod/SKILL.md"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/e2e-dry-run-token-test.XXXXXX")"
cleanup() { rm -rf "$TMPBASE"; }
trap cleanup EXIT

# ── 테스트 하니스 ────────────────────────────────────────────────────
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

# ── 앵커 추출 (기존 cli-e2e-template.test.sh 와 동일 패턴) ──────────────
extract_block() {   # $1=파일 $2=앵커 이름 (>>> a >>> ... <<< a <<< 스타일)
  awk -v a=">>> $2 >>>" -v b="<<< $2 <<<" '
    index($0,a){f=1;next} index($0,b){f=0} f' "$1"
}

# 하드 실패 규칙(의무): 추출 결과가 비면 notok 로 넘기지 않고 즉시 하드 exit 1.
require_block() {   # $1=파일 $2=앵커 — stdout 으로 블록 반환, 비면 하드 중단
  local b
  b="$(extract_block "$1" "$2")"
  if [[ -z "$b" ]]; then
    echo "not ok $((TOTAL+1)) - 앵커 추출 실패(하드 중단): $2 in $1"
    echo "TESTS=$((TOTAL+1)) PASS=$PASS FAIL=$((FAIL+1))"
    exit 1
  fi
  printf '%s' "$b"
}

# ── mutation 판정 함수 공유 원칙 (§5.5) ─────────────────────────────────
# 정상 케이스와 mutation 케이스가 반드시 같은 함수를 호출해야 증명력이 있다.
# 반환: 0 = 규약 만족(DRY_RUN 토큰 정상), 1 = 위반(=mutation 검출 대상)
assert_dry_token() {   # $1=출력 $2=rc
  local last
  last="$(printf '%s\n' "$1" | tail -n 1 | tr -d '\r')"
  [[ "$last" == "E2E_RESULT=DRY_RUN" ]] || return 1
  [[ "$2" -eq 0 ]] || return 1
  [[ "$(printf '%s\n' "$1" | grep -c 'E2E_RESULT=PASS')" -eq 0 ]] || return 1
  return 0
}

# ── #55 deploy-prod dry-run 판정 함수 (기술 스펙 §5.1) ─────────────────
# case 팔 순서: PASS < DRY_RUN < FAIL(또는 시나리오 C *)) — 정상·mutation 이 반드시 같은
# 함수를 호출해야 증명력이 있다(§5.5 원칙). 첫-일치 고정(줄-시작 앵커링)으로 인접 주석
# 문장 안의 동일 문자열 오탐(예: "순서 제약: … 1:E2E_RESULT=FAIL) 앞." 주석줄)을 배제하고,
# 보조로 중첩 case 의 앵커 열림 줄에서 스캔을 중단한다(§4.1 이중 방어).
assert_case_order() {   # $1=블록 텍스트 $2=P 토큰 $3=D 토큰 $4=X 토큰(FAIL 또는 *)) $5=중첩 경계 앵커명(옵션)
  printf '%s\n' "$1" | awk -v P="$2" -v D="$3" -v X="$4" -v B="${5:-}" '
    {
      if (B != "" && index($0, B) > 0) { exit }
      line = $0
      sub(/^[ \t]*/, "", line)
      if (!p && index(line, P) == 1) p = NR
      if (!d && index(line, D) == 1) d = NR
      if (!x && index(line, X) == 1) x = NR
    }
    END{ if (p && d && x && p < d && d < x) print "OK"; else print "BAD" }'
}

# dry-run 계획 블록 불변식(PRD F1·F2·F4, M5~M7) + 마커/텔레그램 스텁 미호출 + rc 0
assert_plan_output() {   # $1=stdout $2=rc
  [[ "$2" -eq 0 ]] || return 1
  [[ "$(printf '%s\n' "$1" | grep -c 'PROD_RESULT')" -eq 0 ]] || return 1
  [[ "$(printf '%s\n' "$1" | grep -cE '^## ')" -eq 0 ]] || return 1
  [[ "$(printf '%s\n' "$1" | grep -cE '_(CALLED|FORCED)')" -eq 0 ]] || return 1
  [[ "$(printf '%s\n' "$1" | tail -n 1)" == "[deploy-prod] DRY-RUN 종료 — prod 검증 통과 신호가 아님" ]] || return 1
  return 0
}

# §6/§7.6 mock 합성 불변식: echo "E2E_RESULT=PASS" 합성 잔존이 없어야 규약 만족
assert_no_pass_synthesis() {   # $1=파일
  [[ "$(grep -c 'echo "E2E_RESULT=PASS"' "$1")" -eq 0 ]]
}

# ── CLI 러너 픽스처 헬퍼 (cli-e2e-template.test.sh 와 동일 방식) ────────
new_cli_fixture() {   # 반환: FX_DIR, FX_BIN (전역변수 세팅)
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
  process.exit(1);
}
if (args.includes('--not-a-real-flag-xyz')) {
  process.stderr.write('unknown flag\n');
  process.exit(1);
}
process.stdout.write('Usage: dummy-cli [options]\n');
process.exit(0);
DUMMY
  chmod +x "$FX_BIN"
}

run_runner() {   # $1=dir $2=mode $3=extra-args(옵션, 공백구분)
  local dir="$1" mode="$2" extra="${3-}"
  local out rc
  out="$( (cd "$dir" && E2E_CLI_BIN="$FX_BIN" node runner/run-e2e.mjs --mode="$mode" $extra) 2>&1 )"
  rc=$?
  RUN_OUT="$out"
  RUN_RC=$rc
  RUN_LAST="$(printf '%s\n' "$out" | tail -n 1 | tr -d '\r')"
}

# ══════════════════════════════════════════════════════════════════
# T1 — CLI 러너 dry-run(smoke): 마지막 줄 정확히 E2E_RESULT=DRY_RUN, exit 0
# ══════════════════════════════════════════════════════════════════
if [[ "$NODE_OK" -eq 1 ]]; then
  new_cli_fixture
  run_runner "$FX_DIR" "smoke" "--dry-run"
  check "$([[ "$RUN_RC" -eq 0 ]] && echo 1 || echo 0)" "T1 러너 --mode=smoke --dry-run: exit 0"
  check "$([[ "$RUN_LAST" == "E2E_RESULT=DRY_RUN" ]] && echo 1 || echo 0)" "T1 러너 dry-run: 마지막 줄 정확히 'E2E_RESULT=DRY_RUN' (실제: $RUN_LAST)"
else
  skip "T1 러너 dry-run 실행" "node 18+ 미검출 — 실제 실행 검증 생략"
fi

# ══════════════════════════════════════════════════════════════════
# T2 — 위 출력에 E2E_RESULT=PASS 부분 문자열 0건 (AC-1 핵심)
# ══════════════════════════════════════════════════════════════════
if [[ "$NODE_OK" -eq 1 ]]; then
  check "$([[ "$(printf '%s\n' "$RUN_OUT" | grep -c 'E2E_RESULT=PASS')" -eq 0 ]] && echo 1 || echo 0)" "T2 러너 dry-run 출력 전체에 'E2E_RESULT=PASS' 부분 문자열 0건"
else
  skip "T2 dry-run 출력 PASS 부재 확인" "node 18+ 미검출 — 실제 실행 검증 생략"
fi

# ══════════════════════════════════════════════════════════════════
# T3 — 모드 무관 확인: --mode=full --dry-run 도 동일
# ══════════════════════════════════════════════════════════════════
if [[ "$NODE_OK" -eq 1 ]]; then
  new_cli_fixture
  run_runner "$FX_DIR" "full" "--dry-run"
  check "$([[ "$RUN_RC" -eq 0 ]] && echo 1 || echo 0)" "T3 러너 --mode=full --dry-run: exit 0"
  check "$([[ "$RUN_LAST" == "E2E_RESULT=DRY_RUN" ]] && echo 1 || echo 0)" "T3 러너 --mode=full --dry-run: 마지막 줄 정확히 'E2E_RESULT=DRY_RUN' (실제: $RUN_LAST)"
else
  skip "T3 러너 dry-run(full) 실행" "node 18+ 미검출 — 실제 실행 검증 생략"
fi

# ══════════════════════════════════════════════════════════════════
# T4 — 무회귀: 전건 성공 픽스처(dry-run 없이) → E2E_RESULT=PASS, exit 0
# ══════════════════════════════════════════════════════════════════
if [[ "$NODE_OK" -eq 1 ]]; then
  new_cli_fixture
  run_runner "$FX_DIR" "smoke" ""
  check "$([[ "$RUN_RC" -eq 0 ]] && echo 1 || echo 0)" "T4 무회귀 전건 성공 픽스처(smoke): exit 0"
  check "$([[ "$RUN_LAST" == "E2E_RESULT=PASS" ]] && echo 1 || echo 0)" "T4 무회귀 전건 성공 픽스처: 마지막 줄 정확히 'E2E_RESULT=PASS' (실제: $RUN_LAST)"
else
  skip "T4 무회귀 러너 PASS" "node 18+ 미검출 — 실제 실행 검증 생략"
fi

# ══════════════════════════════════════════════════════════════════
# T5 — 무회귀: 1건 실패 픽스처 → E2E_RESULT=FAIL, exit 1
# ══════════════════════════════════════════════════════════════════
if [[ "$NODE_OK" -eq 1 ]]; then
  new_cli_fixture
  out="$( (cd "$FX_DIR" && E2E_CLI_BIN="$FX_BIN" DUMMY_VERSION="not-a-version" node runner/run-e2e.mjs --mode=smoke) 2>&1 )"
  rc=$?
  last="$(printf '%s\n' "$out" | tail -n 1 | tr -d '\r')"
  check "$([[ "$rc" -eq 1 ]] && echo 1 || echo 0)" "T5 무회귀 1건 실패 픽스처(smoke, DUMMY_VERSION 훼손): exit 1"
  check "$([[ "$last" == "E2E_RESULT=FAIL" ]] && echo 1 || echo 0)" "T5 무회귀 1건 실패 픽스처: 마지막 줄 정확히 'E2E_RESULT=FAIL' (실제: $last)"
else
  skip "T5 무회귀 러너 FAIL" "node 18+ 미검출 — 실제 실행 검증 생략"
fi

# ══════════════════════════════════════════════════════════════════
# T6 — 무회귀: 빈 시나리오 디렉토리 → E2E_ENV_ERROR=cli_scenario_dir_empty:full, exit 2
# ══════════════════════════════════════════════════════════════════
if [[ "$NODE_OK" -eq 1 ]]; then
  new_cli_fixture
  rm -f "$FX_DIR"/full/*.test.mjs
  out="$( (cd "$FX_DIR" && E2E_CLI_BIN="$FX_BIN" node runner/run-e2e.mjs --mode=full) 2>&1 )"
  rc=$?
  last="$(printf '%s\n' "$out" | tail -n 1 | tr -d '\r')"
  check "$([[ "$rc" -eq 2 ]] && echo 1 || echo 0)" "T6 무회귀 빈 시나리오 디렉토리(full): exit 2"
  check "$([[ "$last" == "E2E_ENV_ERROR=cli_scenario_dir_empty:full" ]] && echo 1 || echo 0)" "T6 무회귀: 마지막 줄 정확히 'E2E_ENV_ERROR=cli_scenario_dir_empty:full' (실제: $last)"
else
  skip "T6 무회귀 빈 디렉토리 ENV_ERROR" "node 18+ 미검출 — 실제 실행 검증 생략"
fi

# ══════════════════════════════════════════════════════════════════
# T7 — 정적 반증: 부분 문자열 안전성 + PASS_DRY_RUN 계열 이름 금지 증명
# ══════════════════════════════════════════════════════════════════
check "$([[ "$(printf 'E2E_RESULT=DRY_RUN\n' | grep -c 'E2E_RESULT=PASS')" -eq 0 ]] && echo 1 || echo 0)" "T7 'E2E_RESULT=DRY_RUN' 은 'E2E_RESULT=PASS' 부분 문자열과 불일치(0건)"
check "$([[ "$(printf 'E2E_RESULT=DRY_RUN\n' | grep -c 'E2E_RESULT=FAIL')" -eq 0 ]] && echo 1 || echo 0)" "T7 'E2E_RESULT=DRY_RUN' 은 'E2E_RESULT=FAIL' 부분 문자열과도 불일치(0건)"
check "$([[ "$(printf 'E2E_RESULT=PASS_DRY_RUN\n' | grep -c 'E2E_RESULT=PASS')" -eq 1 ]] && echo 1 || echo 0)" "T7(반증) 'E2E_RESULT=PASS_DRY_RUN' 은 'E2E_RESULT=PASS' 와 부분 일치(1건) → PASS_* 계열 이름 금지 증명"

# ══════════════════════════════════════════════════════════════════
# T8 — eval(앵커): qa-e2e.md dry-run 분기 실제 서브셸 실행
# ══════════════════════════════════════════════════════════════════
QA_E2E_BLOCK="$(require_block "$QA_E2E_MD" "qa-e2e:dry-run")"
ok "T8 qa-e2e:dry-run 앵커 추출 결과 비어있지 않음"
T8_OUT="$( (DRY_RUN=true ENV=local MODE=smoke BASE_URL="http://localhost:3000" WORKERS=1 RETRIES=0 TEST_DIRS="tests/e2e/smoke" eval "$QA_E2E_BLOCK") 2>&1 )"
T8_RC=$?
check "$(assert_dry_token "$T8_OUT" "$T8_RC" && echo 1 || echo 0)" "T8 qa-e2e.md dry-run 분기 eval: E2E_RESULT=DRY_RUN, exit 0, PASS 부분 문자열 0건"

# ══════════════════════════════════════════════════════════════════
# T9 — eval(앵커): qa-mobile-e2e.md dry-run 분기
# ══════════════════════════════════════════════════════════════════
QA_MOBILE_BLOCK="$(require_block "$QA_MOBILE_E2E_MD" "qa-mobile-e2e:dry-run")"
ok "T9 qa-mobile-e2e:dry-run 앵커 추출 결과 비어있지 않음"
T9_OUT="$( (DRY_RUN=true ENV=local MODE=smoke PLATFORM=android BASE_URL="http://localhost:3000" eval "$QA_MOBILE_BLOCK") 2>&1 )"
T9_RC=$?
check "$(assert_dry_token "$T9_OUT" "$T9_RC" && echo 1 || echo 0)" "T9 qa-mobile-e2e.md dry-run 분기 eval: E2E_RESULT=DRY_RUN, exit 0, PASS 부분 문자열 0건"

# ══════════════════════════════════════════════════════════════════
# T10 — eval(앵커): run-e2e/SKILL.md §4.2 dry-run 분기
# ══════════════════════════════════════════════════════════════════
RUN_E2E_BLOCK="$(require_block "$RUN_E2E_SKILL" "run-e2e:dry-run")"
ok "T10 run-e2e:dry-run 앵커 추출 결과 비어있지 않음"
T10_OUT="$( (ARG_DRY=true CURRENT_BRANCH=feature/issue-49 FINAL_ENV=local FINAL_MODE=full ARG_ISSUE=49 DELEGATE_ARGS="--env=local --mode=full" eval "$RUN_E2E_BLOCK") 2>&1 )"
T10_RC=$?
check "$(assert_dry_token "$T10_OUT" "$T10_RC" && echo 1 || echo 0)" "T10 run-e2e/SKILL.md dry-run 분기 eval: E2E_RESULT=DRY_RUN, exit 0, PASS 부분 문자열 0건"

# ══════════════════════════════════════════════════════════════════
# T11 — eval(앵커): e2e-test/SKILL.md 결과 매핑이 DRY_RUN 을 exit 0 으로 매핑 (M6 누락 회귀 직접 검출)
# ══════════════════════════════════════════════════════════════════
E2E_TEST_BLOCK="$(require_block "$E2E_TEST_SKILL" "e2e-test:result-map")"
ok "T11 e2e-test:result-map 앵커 추출 결과 비어있지 않음"
T11_OUT="$( (AGENT_OUTPUT="E2E_RESULT=DRY_RUN" eval "$E2E_TEST_BLOCK") 2>&1 )"
T11_RC=$?
check "$([[ "$T11_RC" -eq 0 ]] && echo 1 || echo 0)" "T11 e2e-test 결과 매핑: LAST_LINE=E2E_RESULT=DRY_RUN → exit 0 (2 가 아님, 실제: $T11_RC)"

# ══════════════════════════════════════════════════════════════════
# T12 — eval(앵커) 무회귀: 같은 블록의 PASS/FAIL/ENV_ERROR/쓰레기 4분기 불변 확인
# ══════════════════════════════════════════════════════════════════
t12_out="$( (AGENT_OUTPUT="E2E_RESULT=PASS" eval "$E2E_TEST_BLOCK") 2>&1 )"; t12_rc=$?
check "$([[ "$t12_rc" -eq 0 ]] && echo 1 || echo 0)" "T12 무회귀 e2e-test 결과 매핑: E2E_RESULT=PASS → exit 0"
t12_out="$( (AGENT_OUTPUT="E2E_RESULT=FAIL" eval "$E2E_TEST_BLOCK") 2>&1 )"; t12_rc=$?
check "$([[ "$t12_rc" -eq 1 ]] && echo 1 || echo 0)" "T12 무회귀 e2e-test 결과 매핑: E2E_RESULT=FAIL → exit 1"
t12_out="$( (AGENT_OUTPUT="E2E_ENV_ERROR=playwright_not_installed" eval "$E2E_TEST_BLOCK") 2>&1 )"; t12_rc=$?
check "$([[ "$t12_rc" -eq 2 ]] && echo 1 || echo 0)" "T12 무회귀 e2e-test 결과 매핑: E2E_ENV_ERROR=* → exit 2"
t12_out="$( (AGENT_OUTPUT="hello" eval "$E2E_TEST_BLOCK") 2>&1 )"; t12_rc=$?
check "$([[ "$t12_rc" -eq 2 ]] && echo 1 || echo 0)" "T12 무회귀 e2e-test 결과 매핑: 쓰레기 문자열 → exit 2(*폴백)"

# ══════════════════════════════════════════════════════════════════
# T13 — 정적: 생산 5경로 각각 E2E_RESULT=DRY_RUN 1건 이상
# ══════════════════════════════════════════════════════════════════
for pair in "$QA_E2E_MD:qa-e2e.md" "$QA_E2E_CLI_MD:qa-e2e-cli.md" "$QA_MOBILE_E2E_MD:qa-mobile-e2e.md" "$RUN_E2E_SKILL:run-e2e/SKILL.md" "$RUNNER_MJS:run-e2e.mjs"; do
  f="${pair%%:*}"; label="${pair##*:}"
  check "$([[ "$(grep -c 'E2E_RESULT=DRY_RUN' "$f")" -ge 1 ]] && echo 1 || echo 0)" "T13 $label 에 E2E_RESULT=DRY_RUN 1건 이상"
done

# ══════════════════════════════════════════════════════════════════
# T14 — 정적(문맥): dry-run 분기 인접 6행 내 E2E_RESULT=PASS 0건
#   (AC-5 원문 그대로 3개 에이전트 정의 파일에만 적용 — run-e2e/SKILL.md 는 §5 매핑표에
#    'E2E_RESULT=PASS' 행이 dry-run 절 인접에 정당하게 존재해 오탐이 나므로 대상에서 제외)
# ══════════════════════════════════════════════════════════════════
for pair in "$QA_E2E_MD:qa-e2e.md" "$QA_E2E_CLI_MD:qa-e2e-cli.md" "$QA_MOBILE_E2E_MD:qa-mobile-e2e.md"; do
  f="${pair%%:*}"; label="${pair##*:}"
  cnt="$(awk '/dry-run|dryRun|DRY_RUN/{f=6} f&&f--{print}' "$f" | grep -c 'E2E_RESULT=PASS' || true)"
  check "$([[ "${cnt:-0}" -eq 0 ]] && echo 1 || echo 0)" "T14 $label dry-run 분기 인접 6행 내 E2E_RESULT=PASS 0건 (실제: ${cnt:-0})"
done

# ══════════════════════════════════════════════════════════════════
# T15 — 정적(범위): merge-pr §14.2 case 블록 내부에 실행 팔로서의 DRY_RUN 0건, 파일 전체는 1건 이상
# ══════════════════════════════════════════════════════════════════
MERGE_PR_CASE_BLOCK="$(awk '/^case "\$E2E_EXIT/{f=1} f{print} f&&/^esac/{exit}' "$MERGE_PR_SKILL")"
check "$([[ -n "$MERGE_PR_CASE_BLOCK" ]] && echo 1 || echo 0)" "T15 merge-pr §14.2 case 블록 추출 결과 비어있지 않음"
check "$([[ "$(printf '%s' "$MERGE_PR_CASE_BLOCK" | grep -cF '0:E2E_RESULT=DRY_RUN)')" -eq 0 ]] && echo 1 || echo 0)" "T15 merge-pr §14.2 case 블록 내부에 '0:E2E_RESULT=DRY_RUN)' 실행 팔 0건 (코드 불변, 주석 언급은 허용)"
check "$([[ "$(grep -c 'DRY_RUN' "$MERGE_PR_SKILL")" -ge 1 ]] && echo 1 || echo 0)" "T15 merge-pr/SKILL.md 파일 전체에는 DRY_RUN 1건 이상(§14.3 매트릭스 문서 행)"

# ══════════════════════════════════════════════════════════════════
# T16 — 정적: merge-main §4.2/§4.3 차단·허용 판정 행 각 1건 그대로 존재 (불변)
# ══════════════════════════════════════════════════════════════════
check "$([[ "$(grep -c "grep -c 'E2E_RESULT=FAIL'" "$MERGE_MAIN_SKILL")" -ge 1 ]] && echo 1 || echo 0)" "T16 merge-main §4.2 차단 판정(grep -c 'E2E_RESULT=FAIL') 존재(불변)"
check "$([[ "$(grep -c "grep -c 'E2E_RESULT=PASS'" "$MERGE_MAIN_SKILL")" -ge 1 ]] && echo 1 || echo 0)" "T16 merge-main §4.3 허용 판정(grep -c 'E2E_RESULT=PASS') 존재(불변)"

# ══════════════════════════════════════════════════════════════════
# T17 — 정적: merge-main 에 dry_run_only 사유 구체화(C') 1건 이상
# ══════════════════════════════════════════════════════════════════
check "$([[ "$(grep -c 'dry_run_only' "$MERGE_MAIN_SKILL")" -ge 1 ]] && echo 1 || echo 0)" "T17 merge-main/SKILL.md 에 'dry_run_only' 사유 구체화 1건 이상"

# ══════════════════════════════════════════════════════════════════
# T18 — 정적: devflow · docs/USAGE.md · templates/e2e-cli/README.md 문서 반영
# ══════════════════════════════════════════════════════════════════
for pair in "$DEVFLOW_SKILL:devflow/SKILL.md" "$USAGE_MD:docs/USAGE.md" "$CLI_README:templates/e2e-cli/README.md"; do
  f="${pair%%:*}"; label="${pair##*:}"
  check "$([[ "$(grep -c 'DRY_RUN' "$f")" -ge 1 ]] && echo 1 || echo 0)" "T18 $label 에 DRY_RUN 1건 이상"
done

# ══════════════════════════════════════════════════════════════════
# T19 — mutation(실행): run-e2e.mjs 사본에서 DRY_RUN→PASS 되돌린 뒤 재실행 → assert_dry_token 이 위반을 검출해야 ok
# ══════════════════════════════════════════════════════════════════
if [[ "$NODE_OK" -eq 1 ]]; then
  new_cli_fixture
  sed -i.bak "s/E2E_RESULT=DRY_RUN/E2E_RESULT=PASS/g" "$FX_DIR/runner/run-e2e.mjs"
  run_runner "$FX_DIR" "smoke" "--dry-run"
  if assert_dry_token "$RUN_OUT" "$RUN_RC"; then
    notok "T19 mutation(run-e2e.mjs DRY_RUN→PASS): 위반이 검출되지 않음 — 회귀 방지 실패 (실제 마지막 줄: $RUN_LAST)"
  else
    ok "T19 mutation(run-e2e.mjs DRY_RUN→PASS): assert_dry_token 이 위반을 검출함(회귀 방지 확인, 실제 마지막 줄: $RUN_LAST)"
  fi
  check "$([[ "$(printf '%s\n' "$RUN_OUT" | grep -c 'E2E_RESULT=PASS')" -ge 1 ]] && echo 1 || echo 0)" "T19 mutation 후 실제로 'E2E_RESULT=PASS' 가 부분 문자열로 검출됨(치환이 유효했음을 재확인)"
else
  skip "T19 mutation(run-e2e.mjs)" "node 18+ 미검출 — 실제 실행 검증 생략"
fi

# ══════════════════════════════════════════════════════════════════
# T20 — mutation(정적): e2e-test:result-map 추출본에서 DRY_RUN 팔 삭제 후 재평가 → exit 2 로 바뀌어야 ok (M6 유효성 증명)
# ══════════════════════════════════════════════════════════════════
E2E_TEST_BLOCK_MUTATED="$(printf '%s\n' "$E2E_TEST_BLOCK" | sed '/E2E_RESULT=DRY_RUN)[[:space:]]*exit 0/d')"
t20_out="$( (AGENT_OUTPUT="E2E_RESULT=DRY_RUN" eval "$E2E_TEST_BLOCK_MUTATED") 2>&1 )"
t20_rc=$?
check "$([[ "$t20_rc" -eq 2 ]] && echo 1 || echo 0)" "T20 mutation(e2e-test DRY_RUN 팔 삭제): exit 코드가 2 로 회귀함 → M6 팔이 실제로 유효함을 증명 (실제: $t20_rc)"

# ══════════════════════════════════════════════════════════════════
# T21 — 메타: 4개 앵커(qa-e2e/qa-mobile-e2e/run-e2e/e2e-test) 각각 열림/닫힘 마커 1건씩 존재
# ══════════════════════════════════════════════════════════════════
for pair in "$QA_E2E_MD||qa-e2e:dry-run" "$QA_MOBILE_E2E_MD||qa-mobile-e2e:dry-run" "$RUN_E2E_SKILL||run-e2e:dry-run" "$E2E_TEST_SKILL||e2e-test:result-map"; do
  f="${pair%%||*}"; anchor="${pair##*||}"
  open_cnt="$(grep -c ">>> $anchor >>>" "$f")"
  close_cnt="$(grep -c "<<< $anchor <<<" "$f")"
  check "$([[ "$open_cnt" -eq 1 && "$close_cnt" -eq 1 ]] && echo 1 || echo 0)" "T21 앵커 '$anchor' in $(basename "$f"): 열림/닫힘 각 1건 (실제 open=$open_cnt close=$close_cnt)"
done

# ══════════════════════════════════════════════════════════════════
# T22 — 이슈 #55: deploy-prod §6 mock 토큰이 E2E_RESULT=DRY_RUN 으로 교체됨 (AC-1)
# ══════════════════════════════════════════════════════════════════
check "$([[ "$(grep -c 'echo "E2E_RESULT=PASS" > "\$E2E_OUTPUT_FILE"' "$DEPLOY_PROD_SKILL")" -eq 0 ]] && echo 1 || echo 0)" "T22 deploy-prod §6 E2E_OUTPUT_FILE mock 합성에 E2E_RESULT=PASS 잔존 0건"
check "$([[ "$(grep -c 'echo "E2E_RESULT=DRY_RUN" > "\$E2E_OUTPUT_FILE"' "$DEPLOY_PROD_SKILL")" -eq 1 ]] && echo 1 || echo 0)" "T22 deploy-prod §6 E2E_OUTPUT_FILE mock 합성이 E2E_RESULT=DRY_RUN 로 교체됨(1건)"

# ══════════════════════════════════════════════════════════════════
# T23 — 이슈 #55: deploy-prod §7.6 mock 토큰이 E2E_RESULT=DRY_RUN 으로 교체됨 (AC-2)
# ══════════════════════════════════════════════════════════════════
check "$([[ "$(grep -c 'echo "E2E_RESULT=PASS" > "\$RETRY_OUTPUT_FILE"' "$DEPLOY_PROD_SKILL")" -eq 0 ]] && echo 1 || echo 0)" "T23 deploy-prod §7.6 RETRY_OUTPUT_FILE mock 합성에 E2E_RESULT=PASS 잔존 0건"
check "$([[ "$(grep -c 'echo "E2E_RESULT=DRY_RUN" > "\$RETRY_OUTPUT_FILE"' "$DEPLOY_PROD_SKILL")" -eq 1 ]] && echo 1 || echo 0)" "T23 deploy-prod §7.6 RETRY_OUTPUT_FILE mock 합성이 E2E_RESULT=DRY_RUN 로 교체됨(1건)"

# ══════════════════════════════════════════════════════════════════
# T24 — 파일 전체 PASS 합성 잔존 0 + §7 case 팔 순서 PASS<DRY_RUN<FAIL (AC-3·AC-4)
# ══════════════════════════════════════════════════════════════════
check "$(assert_no_pass_synthesis "$DEPLOY_PROD_SKILL" && echo 1 || echo 0)" "T24 deploy-prod 파일 전체에 echo \"E2E_RESULT=PASS\" 합성 잔존 0건 (AC-3)"
DP_OUTER_BLOCK="$(require_block "$DEPLOY_PROD_SKILL" "deploy-prod:e2e-result-case")"
ok "T24 deploy-prod:e2e-result-case 앵커 추출 결과 비어있지 않음"
DP_ORDER_OUTER="$(assert_case_order "$DP_OUTER_BLOCK" '0:E2E_RESULT=PASS)' '0:E2E_RESULT=DRY_RUN)' '1:E2E_RESULT=FAIL)' 'deploy-prod:retry-result-case')"
check "$([[ "$DP_ORDER_OUTER" == "OK" ]] && echo 1 || echo 0)" "T24 §7 case 팔 순서: PASS < DRY_RUN < FAIL (실제: $DP_ORDER_OUTER)"

# ══════════════════════════════════════════════════════════════════
# T25 — §7.6 case 팔이 *) 폴백(시나리오 C — 거짓 CRITICAL 마커 등록)보다 앞 (AC-5)
# ══════════════════════════════════════════════════════════════════
DP_INNER_BLOCK="$(require_block "$DEPLOY_PROD_SKILL" "deploy-prod:retry-result-case")"
ok "T25 deploy-prod:retry-result-case 앵커 추출 결과 비어있지 않음"
DP_ORDER_INNER="$(assert_case_order "$DP_INNER_BLOCK" '0:E2E_RESULT=PASS)' '0:E2E_RESULT=DRY_RUN)' '*)')"
check "$([[ "$DP_ORDER_INNER" == "OK" ]] && echo 1 || echo 0)" "T25 §7.6 case 팔 순서: PASS < DRY_RUN < *)(시나리오 C) (실제: $DP_ORDER_INNER)"

# ══════════════════════════════════════════════════════════════════
# T26 — eval(앵커): §7 dry-run 팔 — 마커 미호출 + 계획 블록 불변식 (AC-6·AC-7)
# ══════════════════════════════════════════════════════════════════
DP_ORIG_HASH_BEFORE="$(shasum -a256 "$DEPLOY_PROD_SKILL" 2>/dev/null | awk '{print $1}')"
T26_OUT="$( (
  E2E_EXIT=0
  E2E_LAST_LINE="E2E_RESULT=DRY_RUN"
  MAIN_SHA="2be9ed1"
  BLAST_RADIUS_GUARD=1
  DEPLOYED_SHA=""
  _post_marker_A(){ echo MARKER_A_CALLED; }
  _post_marker_B(){ echo MARKER_B_CALLED; }
  _post_marker_C(){ echo MARKER_C_CALLED; }
  _post_marker_D(){ echo MARKER_D_CALLED; }
  _post_marker_FAIL_NO_ROLLBACK(){ echo MARKER_FNR_CALLED; }
  _post_marker_ROLLBACK_UNAVAILABLE(){ echo MARKER_RU_CALLED; }
  eval "$DP_OUTER_BLOCK"
) 2>&1 )"
T26_RC=$?
check "$(assert_plan_output "$T26_OUT" "$T26_RC" && echo 1 || echo 0)" "T26 §7 dry-run 팔 eval: PROD_RESULT·## ·마커 호출 각 0건, rc 0 (AC-6·AC-7)"

# ══════════════════════════════════════════════════════════════════
# T27 — eval(앵커): §7.6 dry-run 팔 — 거짓 위험 경보 없음 (AC-8)
# ══════════════════════════════════════════════════════════════════
T27_OUT="$( (
  RETRY_EXIT=0
  RETRY_LAST_LINE="E2E_RESULT=DRY_RUN"
  PREV_DEPLOY="dryrun-prev-deploy-id"
  _post_marker_B(){ echo MARKER_B_CALLED; }
  _post_marker_C(){ echo MARKER_C_CALLED; }
  eval "$DP_INNER_BLOCK"
) 2>&1 )"
T27_RC=$?
check "$([[ "$(printf '%s\n' "$T27_OUT" | grep -cE 'MARKER_B_CALLED|MARKER_C_CALLED')" -eq 0 ]] && echo 1 || echo 0)" "T27 §7.6 dry-run 팔 eval: MARKER_B/C 모두 미호출"
check "$([[ "$T27_RC" -eq 0 ]] && echo 1 || echo 0)" "T27 §7.6 dry-run 팔 eval: exit 0 (실제: $T27_RC)"
check "$([[ "$(printf '%s\n' "$T27_OUT" | grep -c 'rolled_back_to')" -ge 1 ]] && echo 1 || echo 0)" "T27 §7.6 dry-run 팔 계획 블록에 rolled_back_to 줄 존재"

# ══════════════════════════════════════════════════════════════════
# T28 — mutation: 토큰을 PASS 로 되돌리면 assert_no_pass_synthesis 가 위반을 검출 (AC-9)
# ══════════════════════════════════════════════════════════════════
MUT_TOKEN_DIR="$TMPBASE/mut_token_$RANDOM"
mkdir -p "$MUT_TOKEN_DIR"
cp "$DEPLOY_PROD_SKILL" "$MUT_TOKEN_DIR/SKILL.md"
sed -i.bak 's/E2E_RESULT=DRY_RUN/E2E_RESULT=PASS/g' "$MUT_TOKEN_DIR/SKILL.md"
if assert_no_pass_synthesis "$MUT_TOKEN_DIR/SKILL.md"; then
  notok "T28 mutation(토큰 되돌림 DRY_RUN→PASS): 위반이 검출되지 않음 — 회귀 방지 실패"
else
  ok "T28 mutation(토큰 되돌림 DRY_RUN→PASS): assert_no_pass_synthesis 가 위반을 검출함(회귀 방지 확인)"
fi
check "$([[ "$(grep -c 'echo \"E2E_RESULT=PASS\"' "$MUT_TOKEN_DIR/SKILL.md")" -ge 1 ]] && echo 1 || echo 0)" "T28 mutation 사본에 실제로 E2E_RESULT=PASS 합성이 재등장함(치환 유효성 재확인)"

# ══════════════════════════════════════════════════════════════════
# T29 — mutation: §7 dry-run 팔 삭제 시 exit 2(프로토콜 위반)로 회귀 (AC-4 유효성)
# ══════════════════════════════════════════════════════════════════
DP_OUTER_MUTATED="$(printf '%s\n' "$DP_OUTER_BLOCK" | sed '/^[[:space:]]*0:E2E_RESULT=DRY_RUN)[[:space:]]*$/,/^[[:space:]]*;;[[:space:]]*$/d')"
T29_OUT="$( (
  E2E_EXIT=0
  E2E_LAST_LINE="E2E_RESULT=DRY_RUN"
  MAIN_SHA="2be9ed1"
  BLAST_RADIUS_GUARD=1
  DEPLOYED_SHA=""
  _post_marker_A(){ echo MARKER_A_CALLED; }
  _post_marker_D(){ echo MARKER_D_CALLED; }
  eval "$DP_OUTER_MUTATED"
) 2>&1 )"
T29_RC=$?
check "$([[ "$T29_RC" -eq 2 ]] && echo 1 || echo 0)" "T29 mutation(§7 dry-run 팔 삭제): exit 코드가 2 로 회귀함 → 팔 필요성 증명 (실제: $T29_RC)"
check "$([[ "$(printf '%s\n' "$T29_OUT" | grep -c 'MARKER_D_CALLED')" -ge 1 ]] && echo 1 || echo 0)" "T29 mutation(§7 dry-run 팔 삭제): 프로토콜 위반 마커(D) 스텁이 호출됨"

# ══════════════════════════════════════════════════════════════════
# T30 — mutation(핵심): §7.6 dry-run 팔 삭제 시 거짓 CRITICAL 경보 검출 (M4·AC-5 유효성)
# ══════════════════════════════════════════════════════════════════
# #55 이후 Telegram 헬퍼가 전면 제거되어(이슈 #55, deploy-prod Telegram 제거 작업) 종전에는
# _send_telegram_force 스텁 호출(TELEGRAM_FORCED) 로 "거짓 위험 경보"를 검출했으나, 이제 그
# 경보 자체가 _post_marker_C 오호출이므로 검증 대상을 마커 오호출(그 인자까지)로 옮긴다.
# 케이스 수는 줄이지 않는다 — 삭제된 TELEGRAM_FORCED 검증 1건을 마커 인자 검증 1건으로 대체.
DP_INNER_MUTATED="$(printf '%s\n' "$DP_INNER_BLOCK" | sed '/^[[:space:]]*0:E2E_RESULT=DRY_RUN)[[:space:]]*$/,/^[[:space:]]*;;[[:space:]]*$/d')"
T30_OUT="$( (
  RETRY_EXIT=0
  RETRY_LAST_LINE="E2E_RESULT=DRY_RUN"
  PREV_DEPLOY="dryrun-prev-deploy-id"
  _post_marker_B(){ echo MARKER_B_CALLED; }
  _post_marker_C(){ echo "MARKER_C_CALLED:arg1=$1:arg2=$2"; }
  eval "$DP_INNER_MUTATED"
) 2>&1 )"
T30_RC=$?
check "$([[ "$(printf '%s\n' "$T30_OUT" | grep -c 'MARKER_C_CALLED')" -ge 1 ]] && echo 1 || echo 0)" "T30 mutation(§7.6 dry-run 팔 삭제): 거짓 CRITICAL 마커(C) 스텁이 호출됨 → 팔이 없으면 실제로 위험 경보(마커 오등록)가 남을 증명"
check "$([[ "$(printf '%s\n' "$T30_OUT" | grep -c 'MARKER_C_CALLED:arg1=dryrun-prev-deploy-id:arg2=E2E_RESULT=DRY_RUN')" -ge 1 ]] && echo 1 || echo 0)" "T30 mutation(§7.6 dry-run 팔 삭제): 오호출된 마커(C)의 인자(rolled_back_to·사유)가 dry-run 값 그대로 새어나감(거짓 경보 내용 검증)"
check "$([[ "$T30_RC" -eq 1 ]] && echo 1 || echo 0)" "T30 mutation(§7.6 dry-run 팔 삭제): exit 코드 1(시나리오 C) (실제: $T30_RC)"

DP_ORIG_HASH_AFTER="$(shasum -a256 "$DEPLOY_PROD_SKILL" 2>/dev/null | awk '{print $1}')"
check "$([[ "$DP_ORIG_HASH_BEFORE" == "$DP_ORIG_HASH_AFTER" ]] && echo 1 || echo 0)" "T28~T30 mutation 전체 원본 트리 무오염 확인(SHA256 해시 불변)"

# ══════════════════════════════════════════════════════════════════
# T31 — 문서 정합(§10.1 갱신) + 신규 앵커 2종 메타 (AC-10·AC-11)
# ══════════════════════════════════════════════════════════════════
DP_101_102_BLOCK="$(sed -n '/### 10.1/,/### 10.2/p' "$DEPLOY_PROD_SKILL")"
check "$([[ "$(printf '%s\n' "$DP_101_102_BLOCK" | grep -c 'mock PASS')" -eq 0 ]] && echo 1 || echo 0)" "T31 §10.1 구간에 'mock PASS' 잔존 0건 (AC-10)"
DP_TAIL_BLOCK="$(sed -n '/### 10.1/,$p' "$DEPLOY_PROD_SKILL")"
check "$([[ "$(printf '%s\n' "$DP_TAIL_BLOCK" | grep -c 'prod 검증 통과 신호')" -ge 1 ]] && echo 1 || echo 0)" "T31 §10.1 이후 구간에 'prod 검증 통과 신호' 1건 이상 (AC-11)"
for anchor in "deploy-prod:e2e-result-case" "deploy-prod:retry-result-case"; do
  open_cnt="$(grep -c ">>> $anchor >>>" "$DEPLOY_PROD_SKILL")"
  close_cnt="$(grep -c "<<< $anchor <<<" "$DEPLOY_PROD_SKILL")"
  check "$([[ "$open_cnt" -eq 1 && "$close_cnt" -eq 1 ]] && echo 1 || echo 0)" "T31 앵커 '$anchor': 열림/닫힘 각 1건 (실제 open=$open_cnt close=$close_cnt)"
done

# ══════════════════════════════════════════════════════════════════
# T32 — 이슈 #55: deploy-prod 에서 Telegram 알림 전면 제거 회귀 방지 (정적 검사)
#   AC-9 결번 각주(§10)는 "외부 알림 옵션 전제 검증" 으로 표현을 바꿔 "Telegram"
#   낱말 자체를 쓰지 않는다(#58 리뷰 P2 — 종전에는 'AC-9' 포함 줄을 통째로 grep -v
#   해 그 줄에 실제 코드를 끼워 넣어도 통과했다). 따라서 각주 예외 없이 'telegram'
#   0건을 그대로 요구한다.
# ══════════════════════════════════════════════════════════════════
check "$([[ "$(grep -ic 'telegram' "$DEPLOY_PROD_SKILL")" -eq 0 ]] && echo 1 || echo 0)" "T32 deploy-prod/SKILL.md 에 'telegram' 문자열 잔존 0건 (대소문자 무시, 각주 예외 없음)"
check "$([[ "$(grep -c '_send_telegram' "$DEPLOY_PROD_SKILL")" -eq 0 ]] && echo 1 || echo 0)" "T32 deploy-prod/SKILL.md 에 _send_telegram* 호출/정의 잔존 0건"
check "$([[ "$(grep -c 'TELEGRAM_STATUS' "$DEPLOY_PROD_SKILL")" -eq 0 ]] && echo 1 || echo 0)" "T32 deploy-prod/SKILL.md 에 TELEGRAM_STATUS 잔존 0건"

# ══════════════════════════════════════════════════════════════════
# T33 — 이슈 #58 선택지 1: merge-pr 와 설정 문서에서 Telegram 알림 전면 제거 회귀 방지
#   deploy-prod(#55) 와 달리 merge-pr 의 AC-10/§16 결번 각주는 'telegram' 낱말을
#   쓰지 않고 작성했으므로(§16 은 "외부 알림 옵션 헬퍼 절", AC-10 은 "외부 알림 옵션
#   전제 검증") 각주 예외 없이 'telegram' 0건을 그대로 요구한다 — T32 처럼 각주 줄을
#   통째로 grep -v 하는 방식은 여기서는 필요 없다.
# ══════════════════════════════════════════════════════════════════
check "$([[ "$(grep -ic 'telegram' "$MERGE_PR_SKILL")" -eq 0 ]] && echo 1 || echo 0)" "T33 merge-pr/SKILL.md 에 'telegram' 문자열 잔존 0건 (대소문자 무시, 각주 예외 없음)"
check "$([[ "$(grep -c '_send_telegram_notification' "$MERGE_PR_SKILL")" -eq 0 ]] && echo 1 || echo 0)" "T33 merge-pr/SKILL.md 에 _send_telegram_notification 호출/정의 잔존 0건"
check "$([[ "$(grep -c 'TG_BOT_TOKEN\|TG_CHAT_ID' "$MERGE_PR_SKILL")" -eq 0 ]] && echo 1 || echo 0)" "T33 merge-pr/SKILL.md 에 TG_BOT_TOKEN/TG_CHAT_ID 잔존 0건"
check "$([[ "$(grep -c 'telegram_bot_token' "$USAGE_MD")" -eq 0 ]] && echo 1 || echo 0)" "T33 docs/USAGE.md 에 telegram_bot_token 잔존 0건"
check "$([[ "$(grep -c 'telegram_chat_id' "$USAGE_MD")" -eq 0 ]] && echo 1 || echo 0)" "T33 docs/USAGE.md 에 telegram_chat_id 잔존 0건"

# ══════════════════════════════════════════════════════════════════
echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
