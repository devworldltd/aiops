#!/usr/bin/env bash
# setup-config-update.test.sh — aiops/skills/setup/SKILL.md `_config_update` 헬퍼
# (.claude/config.json 원자적 갱신) 검증.
# 이슈 #35 기술 스펙 §3(헬퍼 계약 표)·§12-1(T1~T20) + E2E 제안(T21~T24) 을 구현한다.
#
# 순수 bash(3.2 호환). aiops/tests/forge-reviewer-token.test.sh /
# setup-prod-workflow-detect.test.sh 규약을 그대로 따른다:
#   - 케이스별 `ok N - <설명>` / `not ok N - <설명>`
#   - 마지막 줄 `TESTS=<총> PASS=<n> FAIL=<n>`
#   - 종료 코드: 전건 통과 0, 1건 이상 실패 1
#
# 헬퍼를 재구현하지 않는다 — setup/SKILL.md 의
#   `# >>> setup:config-update >>>` ~ `# <<< setup:config-update <<<`
# 사이 코드를 awk 로 그대로 추출해 픽스처 디렉터리에서 eval 한다(문서-코드 일치 강제).
# 네트워크 호출 없음.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_SKILL="$REPO_ROOT/aiops/skills/setup/SKILL.md"
HELPER_ANCHOR="setup:config-update"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/setup-config-update-test.XXXXXX")"
cleanup() {
  # T12/T21 이 .claude 를 읽기전용으로 만들 수 있어 삭제 전 쓰기 권한을 복구한다.
  find "$TMPBASE" -type d -exec chmod u+rwx {} \; 2>/dev/null || true
  rm -rf "$TMPBASE"
}
trap cleanup EXIT

# ── 테스트 하네스 ────────────────────────────────────────────────────
TOTAL=0; PASS=0; FAIL=0
ok()    { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1"; }
notok() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "not ok $TOTAL - $1"; }
check() { [[ "$1" == "1" ]] && ok "$2" || notok "$2"; }

# ── 앵커 사이 코드 추출 ──────────────────────────────────────────────
extract_block() {   # $1=파일 $2=앵커 이름
  awk -v a=">>> $2 >>>" -v b="<<< $2 <<<" '
    index($0,a){f=1;next} index($0,b){f=0} f' "$1"
}

HELPER_CODE="$(extract_block "$SETUP_SKILL" "$HELPER_ANCHOR")"

if [[ -z "$HELPER_CODE" ]]; then
  notok "헬퍼 앵커 추출 실패 — setup/SKILL.md 의 $HELPER_ANCHOR 앵커 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# ── 픽스처 헬퍼 ──────────────────────────────────────────────────────
new_ws() {
  local ws="$TMPBASE/ws_$RANDOM$RANDOM"
  mkdir -p "$ws/.claude"
  echo "$ws"
}

write_config() {   # $1=ws $2=config json 내용
  mkdir -p "$1/.claude"
  printf '%s' "$2" > "$1/.claude/config.json"
}

file_sha() {   # $1=파일
  if command -v shasum >/dev/null 2>&1; then
    shasum "$1" 2>/dev/null | awk '{print $1}'
  else
    cksum "$1" 2>/dev/null
  fi
}

# 헬퍼를 픽스처 디렉터리에서 정의·호출하고 stdout/stderr/rc 를 캡처한다.
# 사용: run_update <ws> <_config_update 인자...>
# 선택: UPD_CFG_PATH 를 미리 설정하면 그 값을 CONFIG_PATH 로 넘긴다.
# 선택: UPD_PATH_OVERRIDE 를 미리 설정하면 그 값을 PATH 로 넘긴다(jq 미존재 시뮬레이션용).
run_update() {
  local ws="$1"; shift
  local errfile
  errfile="$TMPBASE/.stderr.$$_$RANDOM"
  if [[ -n "${UPD_CFG_PATH:-}" && -n "${UPD_PATH_OVERRIDE:-}" ]]; then
    UPD_OUT="$( (cd "$ws" && eval "$HELPER_CODE"; CONFIG_PATH="$UPD_CFG_PATH" PATH="$UPD_PATH_OVERRIDE" _config_update "$@") 2>"$errfile" )"
  elif [[ -n "${UPD_CFG_PATH:-}" ]]; then
    UPD_OUT="$( (cd "$ws" && eval "$HELPER_CODE"; CONFIG_PATH="$UPD_CFG_PATH" _config_update "$@") 2>"$errfile" )"
  elif [[ -n "${UPD_PATH_OVERRIDE:-}" ]]; then
    UPD_OUT="$( (cd "$ws" && eval "$HELPER_CODE"; PATH="$UPD_PATH_OVERRIDE" _config_update "$@") 2>"$errfile" )"
  else
    UPD_OUT="$( (cd "$ws" && eval "$HELPER_CODE"; _config_update "$@") 2>"$errfile" )"
  fi
  UPD_RC=$?
  UPD_ERR="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
  UPD_CONFIG="$(cat "$ws/.claude/config.json" 2>/dev/null || echo "")"
}

reset_overrides() { unset UPD_CFG_PATH UPD_PATH_OVERRIDE 2>/dev/null || true; }

has_key() {   # $1=config json $2=키 → "true"/"false"
  printf '%s' "$1" | jq -r --arg k "$2" 'has($k)' 2>/dev/null
}

key_value() {  # $1=config json $2=키
  printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════
# T1 — 정상 갱신: 대상 키만 변경, 나머지 키 보존, 유효 JSON
# ══════════════════════════════════════════════════════════════════
reset_overrides
ws=$(new_ws)
write_config "$ws" '{"a":1,"tech_stack":[]}'
run_update "$ws" '.tech_stack = $ts' --argjson ts '["node"]'
check "$([[ "$UPD_RC" == "0" ]] && echo 1 || echo 0)" "T1 rc=0"
ts_compact="$(printf '%s' "$UPD_CONFIG" | jq -c '.tech_stack' 2>/dev/null)"
check "$([[ "$ts_compact" == "[\"node\"]" ]] && echo 1 || echo 0)" "T1 tech_stack == [\"node\"]"
check "$([[ "$(key_value "$UPD_CONFIG" a)" == "1" ]] && echo 1 || echo 0)" "T1 기존 키 a 보존"
check "$(printf '%s' "$UPD_CONFIG" | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)" "T1 결과가 유효 JSON"
check "$([[ -z "$UPD_OUT" ]] && echo 1 || echo 0)" "T1 stdout 없음(성공 시 무출력)"

# ══════════════════════════════════════════════════════════════════
# T2 — --arg 전달 (문자열)
# ══════════════════════════════════════════════════════════════════
reset_overrides
ws=$(new_ws)
write_config "$ws" '{}'
run_update "$ws" '.deploy_workflow_prod = $v' --arg v 'deploy-prod.yml'
check "$([[ "$(key_value "$UPD_CONFIG" deploy_workflow_prod)" == "deploy-prod.yml" ]] && echo 1 || echo 0)" "T2 --arg 문자열 값 반영"

# ══════════════════════════════════════════════════════════════════
# T3 — --argjson 중첩 객체 전달
# ══════════════════════════════════════════════════════════════════
reset_overrides
ws=$(new_ws)
write_config "$ws" '{}'
run_update "$ws" '.agent_hints = $h' --argjson h '{"backend":{"framework":"fastapi"}}'
fw="$(printf '%s' "$UPD_CONFIG" | jq -r '.agent_hints.backend.framework' 2>/dev/null)"
check "$([[ "$fw" == "fastapi" ]] && echo 1 || echo 0)" "T3 --argjson 중첩 객체 반영"

# ══════════════════════════════════════════════════════════════════
# T4 — jq 필터 문법 오류 → 원본 바이트 불변, rc=1
# ══════════════════════════════════════════════════════════════════
reset_overrides
ws=$(new_ws)
write_config "$ws" '{"a":1}'
before_sha="$(file_sha "$ws/.claude/config.json")"
run_update "$ws" '.x = = ='
after_sha="$(file_sha "$ws/.claude/config.json")"
check "$([[ "$UPD_RC" == "1" ]] && echo 1 || echo 0)" "T4 rc=1"
check "$([[ "$before_sha" == "$after_sha" ]] && echo 1 || echo 0)" "T4 원본 바이트 불변(체크섬 동일)"

# ══════════════════════════════════════════════════════════════════
# T5 — config 자체가 유효하지 않은 JSON
# ══════════════════════════════════════════════════════════════════
reset_overrides
ws=$(new_ws)
write_config "$ws" '{nope'
before_content="$(cat "$ws/.claude/config.json")"
run_update "$ws" '.a = 1'
after_content="$(cat "$ws/.claude/config.json")"
check "$([[ "$UPD_RC" == "1" ]] && echo 1 || echo 0)" "T5 rc=1"
check "$([[ "$before_content" == "$after_content" ]] && echo 1 || echo 0)" "T5 원본 내용 완전 동일"

# ══════════════════════════════════════════════════════════════════
# T6 — 실패 후 임시 파일 잔존 0
# ══════════════════════════════════════════════════════════════════
reset_overrides
ws=$(new_ws)
write_config "$ws" '{"a":1}'
run_update "$ws" '.x = = ='
leftover="$(ls -A "$ws/.claude" | grep -c '^\.config\.' || true)"
total_files="$(ls -A "$ws/.claude" | wc -l | tr -d ' ')"
check "$([[ "$leftover" == "0" ]] && echo 1 || echo 0)" "T6 실패 후 .config.* 임시 파일 0건"
check "$([[ "$total_files" == "1" ]] && echo 1 || echo 0)" "T6 .claude 안에 config.json 단 1건"

# ══════════════════════════════════════════════════════════════════
# T7 — 성공 후 임시 파일 잔존 0
# ══════════════════════════════════════════════════════════════════
reset_overrides
ws=$(new_ws)
write_config "$ws" '{"a":1}'
run_update "$ws" '.a = 2'
leftover="$(ls -A "$ws/.claude" | grep -c '^\.config\.' || true)"
check "$([[ "$leftover" == "0" ]] && echo 1 || echo 0)" "T7 성공 후 .config.* 임시 파일 0건"

# ══════════════════════════════════════════════════════════════════
# T8 — 실패 문구(W-3)
# ══════════════════════════════════════════════════════════════════
reset_overrides
ws=$(new_ws)
write_config "$ws" '{"a":1}'
run_update "$ws" '.x = = ='
check "$([[ "$UPD_ERR" == *"갱신 실패"* && "$UPD_ERR" == *"원본은 변경되지 않았습니다"* ]] && echo 1 || echo 0)" "T8 stderr(W-3) 문구 포함"

# ══════════════════════════════════════════════════════════════════
# T9 — config 부재(W-1)
# ══════════════════════════════════════════════════════════════════
reset_overrides
ws=$(new_ws)
rm -f "$ws/.claude/config.json"
run_update "$ws" '.a = 1'
check "$([[ "$UPD_RC" == "1" ]] && echo 1 || echo 0)" "T9 rc=1"
check "$([[ "$UPD_ERR" == *".claude/config.json 없음"* ]] && echo 1 || echo 0)" "T9 stderr(W-1) 문구 포함"
check "$([[ ! -f "$ws/.claude/config.json" ]] && echo 1 || echo 0)" "T9 파일 신규 생성 없음"

# ══════════════════════════════════════════════════════════════════
# T10/T11 — 동시 실행 2잡 격리 + 잔존물 0
# ══════════════════════════════════════════════════════════════════
reset_overrides
ws1=$(new_ws); ws2=$(new_ws)
write_config "$ws1" '{"tech_stack":[]}'
write_config "$ws2" '{"tech_stack":[]}'
(
  cd "$ws1" && eval "$HELPER_CODE"
  _config_update '.tech_stack = $ts' --argjson ts '["ws1"]'
) >"$TMPBASE/conc1.out" 2>"$TMPBASE/conc1.err" &
pid1=$!
(
  cd "$ws2" && eval "$HELPER_CODE"
  _config_update '.tech_stack = $ts' --argjson ts '["ws2"]'
) >"$TMPBASE/conc2.out" 2>"$TMPBASE/conc2.err" &
pid2=$!
wait "$pid1"; rc1=$?
wait "$pid2"; rc2=$?
cfg1="$(cat "$ws1/.claude/config.json")"
cfg2="$(cat "$ws2/.claude/config.json")"
check "$([[ "$rc1" == "0" && "$rc2" == "0" ]] && echo 1 || echo 0)" "T10 동시 실행 양쪽 rc=0"
check "$([[ "$(printf '%s' "$cfg1" | jq -r '.tech_stack[0]')" == "ws1" ]] && echo 1 || echo 0)" "T10 ws1 은 자기 값만 반영"
check "$([[ "$(printf '%s' "$cfg2" | jq -r '.tech_stack[0]')" == "ws2" ]] && echo 1 || echo 0)" "T10 ws2 는 자기 값만 반영"
check "$([[ "$cfg1" != *"ws2"* ]] && echo 1 || echo 0)" "T10 ws1 파일에 ws2 문자열 0회"
check "$([[ "$cfg2" != *"ws1"* ]] && echo 1 || echo 0)" "T10 ws2 파일에 ws1 문자열 0회"
leftover1="$(ls -A "$ws1/.claude" | grep -c '^\.config\.' || true)"
leftover2="$(ls -A "$ws2/.claude" | grep -c '^\.config\.' || true)"
check "$([[ "$leftover1" == "0" && "$leftover2" == "0" ]] && echo 1 || echo 0)" "T11 동시 실행 후 양쪽 임시 파일 0건"

# ══════════════════════════════════════════════════════════════════
# T12 — 임시 파일 위치: 대상과 같은 디렉터리(.claude 읽기전용 → mktemp 실패로 반증)
# ══════════════════════════════════════════════════════════════════
reset_overrides
ws=$(new_ws)
write_config "$ws" '{"a":1}'
chmod 555 "$ws/.claude"
run_update "$ws" '.a = 2'
chmod 755 "$ws/.claude"
check "$([[ "$UPD_RC" == "1" ]] && echo 1 || echo 0)" "T12 .claude 읽기전용 시 rc=1"
check "$([[ "$UPD_ERR" == *"임시 파일 생성 실패"* ]] && echo 1 || echo 0)" "T12 stderr(W-2) 문구 포함"

# ══════════════════════════════════════════════════════════════════
# T13 — CONFIG_PATH 오버라이드
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
mkdir -p "$ws/alt"
printf '%s' '{"a":1}' > "$ws/alt/conf.json"
write_config "$ws" '{"untouched":true}'
UPD_CFG_PATH="alt/conf.json"
run_update "$ws" '.a = 99'
reset_overrides
altcfg="$(cat "$ws/alt/conf.json")"
main_cfg="$(cat "$ws/.claude/config.json")"
check "$([[ "$(printf '%s' "$altcfg" | jq -r '.a')" == "99" ]] && echo 1 || echo 0)" "T13 CONFIG_PATH 대상 파일이 갱신됨"
check "$([[ "$(printf '%s' "$main_cfg" | jq -r '.untouched')" == "true" ]] && echo 1 || echo 0)" "T13 기본 .claude/config.json 은 무변경"

# ══════════════════════════════════════════════════════════════════
# T14/T15/T16 — 정적 가드: 고정 /tmp 경로 재발 차단
# ══════════════════════════════════════════════════════════════════
c14="$(grep -c '/tmp/config_tmp\.json' "$SETUP_SKILL" || true)"
c15="$(grep -c '/tmp/c\.json' "$SETUP_SKILL" || true)"
c16="$(grep -rn '> /tmp/' "$REPO_ROOT/aiops/skills" | wc -l | tr -d ' ')"
check "$([[ "${c14:-0}" == "0" ]] && echo 1 || echo 0)" "T14 /tmp/config_tmp.json 0건"
check "$([[ "${c15:-0}" == "0" ]] && echo 1 || echo 0)" "T15 /tmp/c.json 0건"
check "$([[ "$c16" == "0" ]] && echo 1 || echo 0)" "T16 aiops/skills 전체 '> /tmp/' 패턴 0건"

# ══════════════════════════════════════════════════════════════════
# T17 — 헬퍼 경유 강제: 호출 6회 이상 (정의 라인 제외)
# §5·§10-1·§13·§18 4곳 + §19(#173 agent_hints 보존, 신규 감지/기존 보존 분기 2곳) = 6곳.
# ══════════════════════════════════════════════════════════════════
call_count="$(grep -n "_config_update '" "$SETUP_SKILL" | grep -vc '_config_update() {' || true)"
check "$([[ "${call_count:-0}" -ge 6 ]] && echo 1 || echo 0)" "T17 SKILL.md 내 _config_update 호출 6회 이상 (§5·§10-1·§13·§18·§19x2, 실측 ${call_count:-0})"

# ══════════════════════════════════════════════════════════════════
# T18 — 앵커 존재(시작/종료 각 1)
# ══════════════════════════════════════════════════════════════════
start_count="$(grep -c '>>> setup:config-update >>>' "$SETUP_SKILL" || true)"
end_count="$(grep -c '<<< setup:config-update <<<' "$SETUP_SKILL" || true)"
check "$([[ "${start_count:-0}" == "1" ]] && echo 1 || echo 0)" "T18 시작 앵커 1회"
check "$([[ "${end_count:-0}" == "1" ]] && echo 1 || echo 0)" "T18 종료 앵커 1회"

# ══════════════════════════════════════════════════════════════════
# T19 — 앵커 순서: 정의(종료 앵커) 가 첫 호출보다 앞
# ══════════════════════════════════════════════════════════════════
end_line="$(grep -n '<<< setup:config-update <<<' "$SETUP_SKILL" | head -1 | cut -d: -f1)"
# 정의부 자체(함수 선언줄)와 헬퍼 코드 블록 내부의 사용법 주석(#  예: _config_update …)은
# "호출"이 아니므로 제외하고, 실제 사용처(호출부)만 남긴다.
first_call_line="$(grep -n "_config_update '" "$SETUP_SKILL" | grep -v '_config_update() {' | grep -v '^[0-9]*:#' | awk -F: -v e="$end_line" '$1 > e' | head -1 | cut -d: -f1)"
check "$([[ -n "$end_line" && -n "$first_call_line" && "$end_line" -lt "$first_call_line" ]] && echo 1 || echo 0)" "T19 헬퍼 종료 앵커(${end_line:-?}행) < 첫 호출(${first_call_line:-?}행)"

# ══════════════════════════════════════════════════════════════════
# T20 — bash 3.2 호환: 비호환 문법 미사용
# ══════════════════════════════════════════════════════════════════
incompat="$(printf '%s\n' "$HELPER_CODE" | grep -Ec 'mapfile|readarray|declare -A|\$\{[A-Za-z_][A-Za-z0-9_]*@Q\}' || true)"
check "$([[ "${incompat:-0}" == "0" ]] && echo 1 || echo 0)" "T20 bash 3.2 비호환 문법(mapfile/readarray/declare -A/\${var@Q}) 0건"

# ══════════════════════════════════════════════════════════════════
# T21 — CONFIG_PATH 가 가리키는 디렉터리 자체가 쓰기 불가
# ══════════════════════════════════════════════════════════════════
reset_overrides
ws=$(new_ws)
mkdir -p "$ws/ro"
printf '%s' '{"a":1}' > "$ws/ro/conf.json"
chmod 555 "$ws/ro"
UPD_CFG_PATH="ro/conf.json"
run_update "$ws" '.a = 2'
reset_overrides
chmod 755 "$ws/ro"
check "$([[ "$UPD_RC" == "1" ]] && echo 1 || echo 0)" "T21 CONFIG_PATH 디렉터리 쓰기 불가 시 rc=1"
check "$([[ "$UPD_ERR" == *"임시 파일 생성 실패"* ]] && echo 1 || echo 0)" "T21 stderr(W-2) 문구 포함"
check "$([[ "$(cat "$ws/ro/conf.json")" == '{"a":1}' ]] && echo 1 || echo 0)" "T21 원본 무변경"

# ══════════════════════════════════════════════════════════════════
# T22 — jq 성공(rc=0)이어도 출력이 0바이트/비-JSON 이면 실패 + 원본 보존
# ══════════════════════════════════════════════════════════════════
reset_overrides
ws=$(new_ws)
write_config "$ws" '{"a":1}'
before_sha="$(file_sha "$ws/.claude/config.json")"
run_update "$ws" 'empty'
after_sha="$(file_sha "$ws/.claude/config.json")"
check "$([[ "$UPD_RC" == "1" ]] && echo 1 || echo 0)" "T22(빈 출력) rc=1"
check "$([[ "$before_sha" == "$after_sha" ]] && echo 1 || echo 0)" "T22(빈 출력) 원본 바이트 불변"

reset_overrides
ws=$(new_ws)
write_config "$ws" '{"name":"hello world"}'
before_sha="$(file_sha "$ws/.claude/config.json")"
run_update "$ws" '.name' -r
after_sha="$(file_sha "$ws/.claude/config.json")"
check "$([[ "$UPD_RC" == "1" ]] && echo 1 || echo 0)" "T22(비-JSON 출력) rc=1"
check "$([[ "$before_sha" == "$after_sha" ]] && echo 1 || echo 0)" "T22(비-JSON 출력) 원본 바이트 불변"

# ══════════════════════════════════════════════════════════════════
# T23 — jq 미설치(PATH 조작) → 실패 + 원본 보존
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_config "$ws" '{"a":1}'
before_content="$(cat "$ws/.claude/config.json")"
UPD_PATH_OVERRIDE="$TMPBASE/no-jq-bin-$$"
run_update "$ws" '.a = 2'
reset_overrides
after_content="$(cat "$ws/.claude/config.json")"
check "$([[ "$UPD_RC" == "1" ]] && echo 1 || echo 0)" "T23 jq 미존재(PATH 비움) 시 rc=1"
check "$([[ "$UPD_ERR" == *"jq"* ]] && echo 1 || echo 0)" "T23 stderr 에 jq 관련 안내 포함"
check "$([[ "$before_content" == "$after_content" ]] && echo 1 || echo 0)" "T23 원본 무변경"

# ══════════════════════════════════════════════════════════════════
# T24 — --arg 값에 따옴표·개행이 섞여도 안전하게 반영
# ══════════════════════════════════════════════════════════════════
reset_overrides
ws=$(new_ws)
write_config "$ws" '{}'
tricky_val='He said "hi"
line2 with '\''single'\'' quotes'
run_update "$ws" '.note = $v' --arg v "$tricky_val"
got="$(printf '%s' "$UPD_CONFIG" | jq -r '.note' 2>/dev/null)"
check "$([[ "$UPD_RC" == "0" ]] && echo 1 || echo 0)" "T24 rc=0"
check "$(printf '%s' "$UPD_CONFIG" | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)" "T24 결과가 유효 JSON"
check "$([[ "$got" == "$tricky_val" ]] && echo 1 || echo 0)" "T24 따옴표·개행 포함 값이 원본 그대로 반영"

# ══════════════════════════════════════════════════════════════════
# T25 — 정적 가드: 고정 임시 파일명 config.json.tmp 재발 차단 (AC-7, 이슈 #38 M-6)
# ══════════════════════════════════════════════════════════════════
c25="$(grep -c 'config\.json\.tmp' "$SETUP_SKILL" || true)"
check "$([[ "${c25:-0}" == "0" ]] && echo 1 || echo 0)" "T25 config.json.tmp 0회 (실측 ${c25:-0})"

# ══════════════════════════════════════════════════════════════════
# T26 — 정적 가드: 헬퍼 미경유 config.json 직접 쓰기 0건 (AC-8, 이슈 #38 M-6)
# 제외 대상:
#   (1) 헬퍼 정의 블록 — `setup:config-update` 앵커 시작~종료 행 범위. 정의 자체는
#       갱신 호출이 아니므로 카운트하지 않는다.
#   (2) §13 heredoc 신규 생성부 — `cat > .claude/config.json <<'EOF'`. 파일이 아직
#       없을 때의 최초 생성이며 기존 config 갱신이 아니므로 카운트하지 않는다.
# 위 두 곳을 제외한 범위에서 `.claude/config.json` 에 대한 **실제 쓰기**(리다이렉트
# 대상 / mv 대상 / `jq … config.json > tmp && mv` 패턴)만 매칭한다. 출력 문구 예시처럼
# 줄 끝이 우연히 `.claude/config.json` 으로 끝나는 프로즈 라인(예: §6 `경로: .claude/config.json`)
# 은 쓰기가 아니므로 매칭 대상에서 제외한다(코디네이터 보정 요청 반영).
# ══════════════════════════════════════════════════════════════════
helper_start_line="$(grep -n '>>> setup:config-update >>>' "$SETUP_SKILL" | head -1 | cut -d: -f1)"
helper_end_line="$(grep -n '<<< setup:config-update <<<' "$SETUP_SKILL" | head -1 | cut -d: -f1)"
heredoc_line="$(grep -n "cat > \.claude/config\.json << 'EOF'" "$SETUP_SKILL" | head -1 | cut -d: -f1)"

direct_write_matches="$(grep -nE '>[[:space:]]*\.claude/config\.json|mv[[:space:]]+[^[:space:]]+[[:space:]]+\.claude/config\.json|\.claude/config\.json[[:space:]]*>[[:space:]]*[^[:space:]]+[[:space:]]*&&[[:space:]]*mv' "$SETUP_SKILL" \
  | awk -v hs="${helper_start_line:-0}" -v he="${helper_end_line:-0}" -v hd="${heredoc_line:-0}" -F: '
      {
        ln = $1
        if (hs > 0 && he > 0 && ln >= hs && ln <= he) next
        if (hd > 0 && ln == hd) next
        print
      }')"
direct_write_count=0
if [[ -n "$direct_write_matches" ]]; then
  direct_write_count="$(printf '%s\n' "$direct_write_matches" | grep -c '.' || true)"
fi
direct_write_summary="$(printf '%s' "$direct_write_matches" | tr '\n' ' | ')"
check "$([[ "${direct_write_count:-0}" == "0" ]] && echo 1 || echo 0)" "T26 헬퍼 미경유 config.json 직접 쓰기 0건 (실측 ${direct_write_count:-0}건: ${direct_write_summary:-없음})"

# ══════════════════════════════════════════════════════════════════
echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
