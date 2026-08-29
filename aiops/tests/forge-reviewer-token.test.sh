#!/usr/bin/env bash
# forge-reviewer-token.test.sh — aiops/scripts/forge.sh 의 Gitea 리뷰어 토큰(REVIEWER_TOKEN) 경로 검증.
# 이슈 #28 기술 스펙 §12(테스트 전략)·§13(E2E 검증 시나리오) T1~T14 를 구현한다.
#
# 순수 bash(3.2 호환). bats 미사용(레포에 테스트 러너가 없고, 함수 6개 수준이라 하네스 1개로 충분 — §12-1).
# 네트워크 모킹: PATH 앞단에 curl/git/cloudflared/gh 스텁을 주입하고 forge.sh 를 통째로 실행한다
# (forge.sh 는 "반드시 실행"이 관례이며 소싱하지 않는다 — 함수 단위 호출 불가).
#
# 출력 규약: 케이스별 `ok N - <설명>` / `not ok N - <설명>`, 마지막 줄 `TESTS=<총> PASS=<n> FAIL=<n>`.
# 종료 코드: 전건 통과 0, 1건 이상 실패 1.
#
# ⚠️ 실제 KMS reveal 호출은 하지 않는다 — 전부 스텁 curl 이 흉내낸다. 실제 secret 값은 어디에도 없다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FORGE="$REPO_ROOT/aiops/scripts/forge.sh"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/forge-reviewer-token-test.XXXXXX")"
WS="$TMPBASE/ws"
STUBBIN="$TMPBASE/bin"
STUB_LOG="$TMPBASE/log"
FAKEHOME="$TMPBASE/home"
export STUB_LOG

cleanup() { rm -rf "$TMPBASE"; }
trap cleanup EXIT

mkdir -p "$WS" "$STUBBIN" "$STUB_LOG" "$FAKEHOME"

# ── 스텁 바이너리 생성 ──────────────────────────────────────────────
# 스텁 curl: 인자를 redacted 형태로 $STUB_LOG/curl.calls 에 기록하고, URL 패턴별 고정 응답을 낸다.
cat > "$STUBBIN/curl" <<'CURL_STUB'
#!/usr/bin/env bash
set -u
LOGFILE="${STUB_LOG:?STUB_LOG not set}/curl.calls"

args=("$@")
n=${#args[@]}
if (( n == 0 )); then exit 0; fi
url="${args[$((n-1))]}"

method="GET"
maxtime=""
use_config=0
haswrite=0
i=0
while (( i < n )); do
  case "${args[$i]}" in
    -X) method="${args[$((i+1))]:-GET}"; i=$((i+2));;
    --max-time|-m) maxtime="${args[$((i+1))]:-}"; i=$((i+2));;
    --config) [[ "${args[$((i+1))]:-}" == "-" ]] && use_config=1; i=$((i+2));;
    -w) haswrite=1; i=$((i+2));;
    *) i=$((i+1));;
  esac
done

# --config - 는 stdin 으로 헤더(KMS_TOKEN 포함)를 받는다 — 소비만 하고 절대 로그에 남기지 않는다.
if [[ "$use_config" == "1" ]]; then
  cat >/dev/null 2>&1 || true
fi

# ── 호출 로그(redacted) — 토큰 값은 어떤 형태로도 남기지 않는다 ──
{
  printf '%s %s' "$method" "$url"
  j=0
  while (( j < n )); do
    a="${args[$j]}"
    if [[ "$a" == "-H" ]]; then
      v="${args[$((j+1))]:-}"
      case "$v" in
        [Aa]uthorization:*) printf ' -H Authorization:<REDACTED>' ;;
        *) printf ' -H %s' "$v" ;;
      esac
      j=$((j+2))
    else
      j=$((j+1))
    fi
  done
  [[ "$use_config" == "1" ]] && printf ' --config <REDACTED-stdin-headers>'
  printf '\n'
} >> "$LOGFILE"

case "$url" in
  */api/v1/version)
    cnt=0
    [[ -f "${STUB_LOG}/version_count" ]] && cnt=$(cat "${STUB_LOG}/version_count")
    cnt=$((cnt+1)); echo "$cnt" > "${STUB_LOG}/version_count"
    # 첫 시도는 일부러 실패시켜 _init() 의 extraheader 폴백 경로를 강제한다(T13 헤더 승계 검증용).
    if [[ "$cnt" == "1" ]]; then exit 1; fi
    echo '{"version":"1.22.0"}'
    exit 0
    ;;
  */api/v1/health)
    if [[ "${MOCK_HANG:-0}" == "1" ]]; then
      sleep $(( ${maxtime:-5} + 1 ))
      exit 28
    fi
    code="${MOCK_HEALTH:-200}"
    if [[ "$code" == "000" ]]; then exit 7; fi
    body='{"status":"ok"}'
    [[ "$code" != "200" ]] && body='{"message":"unauthorized"}'
    if [[ "$haswrite" == "1" ]]; then printf '%s\n%s' "$body" "$code"; else printf '%s' "$body"; fi
    exit 0
    ;;
  */api/v1/secrets\?q=REVIEWER_TOKEN*)
    body="${MOCK_SEARCH_BODY:-}"; [[ -z "$body" ]] && body='{"items":[]}'
    code="${MOCK_SEARCH_CODE:-200}"
    if [[ "$haswrite" == "1" ]]; then printf '%s\n%s' "$body" "$code"; else printf '%s' "$body"; fi
    exit 0
    ;;
  */api/v1/secrets/*/reveal)
    body="${MOCK_REVEAL_BODY:-}"; [[ -z "$body" ]] && body='{"value":"REVTOK-default"}'
    code="${MOCK_REVEAL_CODE:-200}"
    if [[ "$haswrite" == "1" ]]; then printf '%s\n%s' "$body" "$code"; else printf '%s' "$body"; fi
    exit 0
    ;;
  */pulls/*/reviews)
    is_reviewer=0
    j=0
    while (( j < n )); do
      a="${args[$j]}"
      if [[ "$a" == "-H" ]]; then
        v="${args[$((j+1))]:-}"
        case "$v" in *REVTOK-*) is_reviewer=1 ;; esac
        j=$((j+2))
      else
        j=$((j+1))
      fi
    done
    if [[ "$is_reviewer" == "1" ]]; then
      body="${MOCK_REVIEWER_POST_BODY:-}"; [[ -z "$body" ]] && body='{"id":9001,"state":"APPROVED"}'
      code="${MOCK_REVIEWER_POST_CODE:-200}"
    else
      cnt=0
      [[ -f "${STUB_LOG}/base_post_count" ]] && cnt=$(cat "${STUB_LOG}/base_post_count")
      cnt=$((cnt+1)); echo "$cnt" > "${STUB_LOG}/base_post_count"
      if [[ "$cnt" == "1" ]]; then
        body="${MOCK_BASE_POST1_BODY:-}"; [[ -z "$body" ]] && body='{"id":9002,"state":"COMMENTED"}'
        code="${MOCK_BASE_POST1_CODE:-200}"
      else
        body="${MOCK_BASE_POST2_BODY:-}"; [[ -z "$body" ]] && body='{"id":9003,"state":"COMMENTED"}'
        code="${MOCK_BASE_POST2_CODE:-200}"
      fi
    fi
    if [[ "$haswrite" == "1" ]]; then printf '%s\n%s' "$body" "$code"; else printf '%s' "$body"; fi
    exit 0
    ;;
  *)
    echo '{}'
    exit 0
    ;;
esac
CURL_STUB
chmod +x "$STUBBIN/curl"

# 스텁 git: origin 리모트 / credential fill / extraheader 만 흉내낸다.
cat > "$STUBBIN/git" <<'GIT_STUB'
#!/usr/bin/env bash
set -u
{ printf 'git'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${STUB_LOG:?}/git.calls" 2>/dev/null || true

if [[ "${1:-}" == "remote" && "${2:-}" == "get-url" && "${3:-}" == "origin" ]]; then
  echo "${TEST_ORIGIN:-https://git.devworld.co.kr/devworld-ltd/aiops-v1}"
  exit 0
fi
if [[ "${1:-}" == "credential" && "${2:-}" == "fill" ]]; then
  cat >/dev/null 2>&1 || true
  echo "protocol=https"
  echo "host=git.devworld.co.kr"
  echo "username=stub"
  echo "password=stub-base-token"
  exit 0
fi
if [[ "${1:-}" == "config" ]]; then
  full="$*"
  if [[ "$full" == *"--get-all"* && "$full" == *".extraheader"* ]]; then
    echo "Authorization: basic ZmFrZQ=="
    exit 0
  fi
  exit 1
fi
exit 0
GIT_STUB
chmod +x "$STUBBIN/git"

# 스텁 cloudflared: 항상 실패(빈 토큰) — 테스트는 CF Access 캐시토큰 폴백까지는 검증하지 않는다.
cat > "$STUBBIN/cloudflared" <<'CF_STUB'
#!/usr/bin/env bash
{ printf 'cloudflared'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${STUB_LOG:?}/cloudflared.calls" 2>/dev/null || true
exit 1
CF_STUB
chmod +x "$STUBBIN/cloudflared"

# 스텁 gh: GitHub 분기(T4) 전용 — 호출만 기록.
cat > "$STUBBIN/gh" <<'GH_STUB'
#!/usr/bin/env bash
{ printf 'gh'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${STUB_LOG:?}/gh.calls" 2>/dev/null || true
exit 0
GH_STUB
chmod +x "$STUBBIN/gh"

# ── 테스트 하네스 ────────────────────────────────────────────────────
TOTAL=0; PASS=0; FAIL=0
ok()    { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1"; }
notok() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "not ok $TOTAL - $1"; }
check() { [[ "$1" == "1" ]] && ok "$2" || notok "$2"; }

ALL_MOCK_VARS="REVIEWER_TOKEN KMS_TOKEN REVIEWER_ENV REVIEWER_SECRET_SERVICE KMS_URL KMS_ENV \
CF_ACCESS_CLIENT_ID CF_ACCESS_CLIENT_SECRET MOCK_HEALTH MOCK_SEARCH_BODY MOCK_SEARCH_CODE \
MOCK_REVEAL_BODY MOCK_REVEAL_CODE MOCK_REVIEWER_POST_BODY MOCK_REVIEWER_POST_CODE \
MOCK_BASE_POST1_BODY MOCK_BASE_POST1_CODE MOCK_BASE_POST2_BODY MOCK_BASE_POST2_CODE MOCK_HANG"

reset_test() {
  rm -rf "$WS" "$STUB_LOG"
  mkdir -p "$WS" "$STUB_LOG"
  # shellcheck disable=SC2086
  unset $ALL_MOCK_VARS 2>/dev/null || true
  export TEST_ORIGIN="https://git.devworld.co.kr/devworld-ltd/aiops-v1"
  printf '## 🔍 코드 리뷰 결과\nLGTM ✅ (test)\n' > "$WS/body.md"
}

LAST_OUT=""; LAST_ERR=""; LAST_RC=0
run_forge() {
  local n="$1" verdict="$2"
  LAST_OUT=$(cd "$WS" && HOME="$FAKEHOME" PATH="$STUBBIN:$PATH" bash "$FORGE" pr-review "$n" "$verdict" "@body.md" 2>"$WS/stderr.log")
  LAST_RC=$?
  LAST_ERR=$(cat "$WS/stderr.log" 2>/dev/null || echo "")
}

run_forge_xtrace() {
  # bash -x 로 실행 — stdout/stderr 를 분리 캡처(T6). 값 비노출 검증용.
  local n="$1" verdict="$2"
  ( cd "$WS" && HOME="$FAKEHOME" PATH="$STUBBIN:$PATH" bash -x "$FORGE" pr-review "$n" "$verdict" "@body.md" >"$WS/xtrace_out.log" 2>"$WS/xtrace_err.log" )
  LAST_RC=$?
}

kms_call_count() {
  if [[ -f "$STUB_LOG/curl.calls" ]]; then grep -c "kms\|KMS" "$STUB_LOG/curl.calls" 2>/dev/null; else echo 0; fi
}
reviews_call_count() {
  if [[ -f "$STUB_LOG/curl.calls" ]]; then grep -c "/pulls/.*reviews" "$STUB_LOG/curl.calls" 2>/dev/null; else echo 0; fi
}

# ══════════════════════════════════════════════════════════════════
# T1 — env 최우선 (AC-1)
# ══════════════════════════════════════════════════════════════════
reset_test
export REVIEWER_TOKEN="REVTOK-env-AAA"
run_forge 101 APPROVE
check "$([[ "$LAST_RC" == "0" ]] && echo 1 || echo 0)" "T1 exit 0"
check "$([[ "$LAST_OUT" == *"STATE=APPROVED"* ]] && echo 1 || echo 0)" "T1 STATE=APPROVED"
check "$([[ "$(kms_call_count)" == "0" ]] && echo 1 || echo 0)" "T1 KMS 호출 0건 (curl.calls 에 kms 문자열 없음)"
check "$([[ "$LAST_ERR" == *"[forge] 리뷰어 토큰: env"* ]] && echo 1 || echo 0)" "T1 stderr에 env 경로 표시"

# ══════════════════════════════════════════════════════════════════
# T2 — KMS reveal 경로 (AC-2)
# ══════════════════════════════════════════════════════════════════
reset_test
export KMS_TOKEN="stub-kms-app-token"
export MOCK_HEALTH=200
export MOCK_SEARCH_BODY='{"items":[{"id":"sec-1","name":"REVIEWER_TOKEN","service":"aiops","environment":"local","secret_type":"token","status":"active","has_value":true}]}'
export MOCK_REVEAL_BODY='{"value":"REVTOK-kms-XYZ"}'
run_forge 102 APPROVE
check "$([[ "$LAST_RC" == "0" ]] && echo 1 || echo 0)" "T2 exit 0"
check "$([[ "$LAST_OUT" == *"STATE=APPROVED"* ]] && echo 1 || echo 0)" "T2 STATE=APPROVED"
check "$([[ "$(grep -c '/api/v1/health' "$STUB_LOG/curl.calls" 2>/dev/null || echo 0)" == "1" ]] && echo 1 || echo 0)" "T2 health 호출 1건"
check "$([[ "$(grep -c '/api/v1/secrets?q=REVIEWER_TOKEN' "$STUB_LOG/curl.calls" 2>/dev/null || echo 0)" == "1" ]] && echo 1 || echo 0)" "T2 secrets 검색 호출 1건"
check "$([[ "$(grep -c '/reveal' "$STUB_LOG/curl.calls" 2>/dev/null || echo 0)" == "1" ]] && echo 1 || echo 0)" "T2 reveal 호출 정확히 1회"

# ══════════════════════════════════════════════════════════════════
# T3 — 무중단 폴백 (AC-3, AC-14)
# ══════════════════════════════════════════════════════════════════
reset_test
export MOCK_BASE_POST1_BODY='{"message":"You are not allowed to approve your own pull request"}'
export MOCK_BASE_POST2_BODY='{"id":9010,"state":"COMMENTED"}'
run_forge 103 APPROVE
check "$([[ "$LAST_RC" == "0" ]] && echo 1 || echo 0)" "T3 exit 0"
check "$([[ "$LAST_OUT" == *"STATE=COMMENTED"* ]] && echo 1 || echo 0)" "T3 STATE=COMMENTED"
check "$([[ "$(kms_call_count)" == "0" ]] && echo 1 || echo 0)" "T3 KMS 호출 0건"

# ══════════════════════════════════════════════════════════════════
# T4 — GitHub 무변경 (AC-4)
# ══════════════════════════════════════════════════════════════════
reset_test
export TEST_ORIGIN="https://github.com/devworld-ltd/aiops-v1.git"
export REVIEWER_TOKEN="REVTOK-env-should-not-be-used"
export KMS_TOKEN="stub-kms-should-not-be-used"
run_forge 104 APPROVE
check "$([[ -f "$STUB_LOG/gh.calls" && $(grep -c "pr review 104 --approve" "$STUB_LOG/gh.calls") -ge 1 ]] && echo 1 || echo 0)" "T4 gh pr review --approve 호출됨"
check "$([[ ! -f "$STUB_LOG/curl.calls" ]] && echo 1 || echo 0)" "T4 curl.calls 파일 자체가 없음(curl 호출 0건)"
check "$([[ "$LAST_ERR" != *"[forge] 리뷰어 토큰"* ]] && echo 1 || echo 0)" "T4 stderr에 리뷰어 토큰 문자열 없음"

# ══════════════════════════════════════════════════════════════════
# T5 — verdict 게이트: REQUEST_CHANGES / COMMENT 는 KMS 호출 0건 (AC-5)
# ══════════════════════════════════════════════════════════════════
reset_test
export KMS_TOKEN="stub-kms-app-token"
run_forge 105 REQUEST_CHANGES
rc_kms1=$(kms_call_count)
reset_test
export KMS_TOKEN="stub-kms-app-token"
run_forge 105 COMMENT
rc_kms2=$(kms_call_count)
check "$([[ "$rc_kms1" == "0" && "$rc_kms2" == "0" ]] && echo 1 || echo 0)" "T5 REQUEST_CHANGES/COMMENT 모두 KMS 호출 0건"

# ══════════════════════════════════════════════════════════════════
# T6 — 값 비노출, bash -x 추적 (AC-6)
# ══════════════════════════════════════════════════════════════════
reset_test
export KMS_TOKEN="stub-kms-secret-SUPERSECRET1"
export MOCK_SEARCH_BODY='{"items":[{"id":"sec-2","name":"REVIEWER_TOKEN","service":"aiops","environment":"local","has_value":true}]}'
export MOCK_REVEAL_BODY='{"value":"REVTOK-SECRETVAL9"}'
run_forge_xtrace 106 APPROVE
xout=$(cat "$WS/xtrace_out.log" 2>/dev/null || echo "")
xerr=$(cat "$WS/xtrace_err.log" 2>/dev/null || echo "")
check "$([[ "$xout$xerr" != *"REVTOK-SECRETVAL9"* ]] && echo 1 || echo 0)" "T6 리뷰어 토큰 값이 어디에도 없음"
check "$([[ "$xout$xerr" != *"stub-kms-secret-SUPERSECRET1"* ]] && echo 1 || echo 0)" "T6 KMS_TOKEN 값이 어디에도 없음"
check "$([[ "$xout" == *"STATE=APPROVED"* ]] && echo 1 || echo 0)" "T6 bash -x 아래서도 정상 동작(STATE=APPROVED)"

# ══════════════════════════════════════════════════════════════════
# T7 — AUTH 비오염 (AC-7). 소싱 불가하므로 정적 검사: cmd_pr_review 본문에
#      전역 AUTH 재대입(AUTH=/AUTH+=)이 없는지 확인한다(_RAUTH 는 별개).
# ══════════════════════════════════════════════════════════════════
cpr_body=$(sed -n '/^cmd_pr_review() {/,/^}/p' "$FORGE")
if echo "$cpr_body" | grep -E '(^|[^A-Za-z0-9_])AUTH\+?=' | grep -qv '_RAUTH\|_KMS'; then
  check 0 "T7 cmd_pr_review 내부에서 전역 AUTH 재대입 없음"
else
  check 1 "T7 cmd_pr_review 내부에서 전역 AUTH 재대입 없음"
fi

# ══════════════════════════════════════════════════════════════════
# T8a-f — KMS 이상 6종, 전부 exit 0 + STATE=COMMENTED + 서로 다른 stderr (AC-8)
# ══════════════════════════════════════════════════════════════════
run_kms_anomaly() {
  local label="$1" n="$2" expect_substr="$3"
  run_forge "$n" APPROVE
  check "$([[ "$LAST_RC" == "0" ]] && echo 1 || echo 0)" "T8${label} exit 0"
  check "$([[ "$LAST_OUT" == *"STATE=COMMENTED"* ]] && echo 1 || echo 0)" "T8${label} STATE=COMMENTED"
  check "$([[ "$LAST_ERR" == *"$expect_substr"* ]] && echo 1 || echo 0)" "T8${label} stderr: $expect_substr"
}

reset_test; export KMS_TOKEN="stub-kms"; export MOCK_HEALTH=000
export MOCK_BASE_POST1_BODY='{"message":"approve your own pull request"}'; export MOCK_BASE_POST2_BODY='{"id":9101,"state":"COMMENTED"}'
run_kms_anomaly a 108 "KMS 응답 없음"

reset_test; export KMS_TOKEN="stub-kms"; export MOCK_HEALTH=401
export MOCK_BASE_POST1_BODY='{"message":"approve your own pull request"}'; export MOCK_BASE_POST2_BODY='{"id":9102,"state":"COMMENTED"}'
run_kms_anomaly b 109 "KMS 인증 실패 HTTP 401"

reset_test; export KMS_TOKEN="stub-kms"; export MOCK_HEALTH=200
export MOCK_SEARCH_BODY='{"items":[]}'
export MOCK_BASE_POST1_BODY='{"message":"approve your own pull request"}'; export MOCK_BASE_POST2_BODY='{"id":9103,"state":"COMMENTED"}'
run_kms_anomaly c 110 "KMS 후보 0건"

reset_test; export KMS_TOKEN="stub-kms"; export MOCK_HEALTH=200
export MOCK_SEARCH_BODY='{"items":[{"id":"s1","name":"REVIEWER_TOKEN","service":"aiops","environment":"local","has_value":true},{"id":"s2","name":"REVIEWER_TOKEN","service":"aiops","environment":"local","has_value":true}]}'
export MOCK_BASE_POST1_BODY='{"message":"approve your own pull request"}'; export MOCK_BASE_POST2_BODY='{"id":9104,"state":"COMMENTED"}'
run_kms_anomaly d 111 "KMS 후보 2건"

reset_test; export KMS_TOKEN="stub-kms"; export MOCK_HEALTH=200
export MOCK_SEARCH_BODY='{"items":[{"id":"s1","name":"REVIEWER_TOKEN","service":"aiops","environment":"local","has_value":false}]}'
export MOCK_BASE_POST1_BODY='{"message":"approve your own pull request"}'; export MOCK_BASE_POST2_BODY='{"id":9105,"state":"COMMENTED"}'
run_kms_anomaly e 112 "has_value=false"

reset_test; export KMS_TOKEN="stub-kms"; export MOCK_HEALTH=200
export MOCK_SEARCH_BODY='{"items":[{"id":"s1","name":"REVIEWER_TOKEN","service":"aiops","environment":"local","has_value":true}]}'
export MOCK_REVEAL_BODY='{"message":"internal error"}'; export MOCK_REVEAL_CODE=500
export MOCK_BASE_POST1_BODY='{"message":"approve your own pull request"}'; export MOCK_BASE_POST2_BODY='{"id":9106,"state":"COMMENTED"}'
run_kms_anomaly f 113 "KMS reveal 실패 HTTP 500"

# ══════════════════════════════════════════════════════════════════
# T9 — 타임아웃 상한 (AC-9): MOCK_HANG=1, 총 대기 <= 15s
# ══════════════════════════════════════════════════════════════════
reset_test
export KMS_TOKEN="stub-kms"; export MOCK_HANG=1
export MOCK_BASE_POST1_BODY='{"message":"approve your own pull request"}'; export MOCK_BASE_POST2_BODY='{"id":9200,"state":"COMMENTED"}'
_t9_start=$(date +%s)
run_forge 114 APPROVE
_t9_end=$(date +%s)
_t9_elapsed=$((_t9_end - _t9_start))
check "$([[ "$_t9_elapsed" -le 15 ]] && echo 1 || echo 0)" "T9 타임아웃 상한 준수 (경과 ${_t9_elapsed}s <= 15s)"
check "$([[ "$LAST_RC" == "0" ]] && echo 1 || echo 0)" "T9 exit 0"

# ══════════════════════════════════════════════════════════════════
# T10 — 리뷰어 POST 실패 → 1회 재시도 (AC-10)
# ══════════════════════════════════════════════════════════════════
reset_test
export REVIEWER_TOKEN="REVTOK-env-BBB"
export MOCK_REVIEWER_POST_BODY='{"message":"unauthorized"}'; export MOCK_REVIEWER_POST_CODE=401
export MOCK_BASE_POST1_BODY='{"message":"approve your own pull request"}'; export MOCK_BASE_POST2_BODY='{"id":9300,"state":"COMMENTED"}'
run_forge 115 APPROVE
_t10_calls=$(reviews_call_count)
check "$([[ "$_t10_calls" -ge 2 && "$_t10_calls" -le 3 ]] && echo 1 || echo 0)" "T10 리뷰 POST 총 2~3회 (실측 ${_t10_calls}회), 무한루프 없음"
check "$([[ "$LAST_RC" == "0" ]] && echo 1 || echo 0)" "T10 exit 0"
check "$([[ "$LAST_OUT" == *"STATE=COMMENTED"* ]] && echo 1 || echo 0)" "T10 최종 STATE=COMMENTED"

# ══════════════════════════════════════════════════════════════════
# T11 — 출력 규약: 마지막 줄 REVIEW_ID=<n> STATE=<s> (AC-11)
# ══════════════════════════════════════════════════════════════════
reset_test
export REVIEWER_TOKEN="REVTOK-env-CCC"
run_forge 116 APPROVE
last_line=$(printf '%s' "$LAST_OUT" | tail -1)
check "$([[ "$last_line" =~ ^REVIEW_ID=[0-9]+\ STATE=.*$ ]] && echo 1 || echo 0)" "T11 stdout 마지막 줄이 REVIEW_ID=<n> STATE=<s> 형식"

# ══════════════════════════════════════════════════════════════════
# T12 — stdout 청결: 줄 수 == 1 (AC-12)
# ══════════════════════════════════════════════════════════════════
reset_test
export REVIEWER_TOKEN="REVTOK-env-DDD"
run_forge 117 APPROVE
lc=$(printf '%s' "$LAST_OUT" | grep -c '.' || true)
check "$([[ "$lc" == "1" ]] && echo 1 || echo 0)" "T12(env경로) stdout 줄 수 == 1"

reset_test
export MOCK_BASE_POST1_BODY='{"message":"approve your own pull request"}'; export MOCK_BASE_POST2_BODY='{"id":9400,"state":"COMMENTED"}'
run_forge 118 APPROVE
lc2=$(printf '%s' "$LAST_OUT" | grep -c '.' || true)
check "$([[ "$lc2" == "1" ]] && echo 1 || echo 0)" "T12(폴백경로) stdout 줄 수 == 1"

# ══════════════════════════════════════════════════════════════════
# T13 — 헤더 승계: 리뷰어 POST 의 Authorization 헤더가 정확히 1개 (S-8)
#        AUTH 는 스텁 _init() 이 token + extraheader(basic) 2개를 채운 상태에서 시작한다.
# ══════════════════════════════════════════════════════════════════
reset_test
export KMS_TOKEN="stub-kms"; export MOCK_HEALTH=200
export MOCK_SEARCH_BODY='{"items":[{"id":"s1","name":"REVIEWER_TOKEN","service":"aiops","environment":"local","has_value":true}]}'
export MOCK_REVEAL_BODY='{"value":"REVTOK-headertest"}'
run_forge 119 APPROVE
reviewer_line=$(grep '/pulls/.*reviews' "$STUB_LOG/curl.calls" | tail -1)
auth_count=$(printf '%s' "$reviewer_line" | grep -o 'Authorization:<REDACTED>' | wc -l | tr -d ' ')
check "$([[ "$auth_count" == "1" ]] && echo 1 || echo 0)" "T13 리뷰어 POST 의 Authorization 헤더 정확히 1개 (실측 ${auth_count}개)"

# ══════════════════════════════════════════════════════════════════
# T14 — environment 화이트리스트(오타) → KMS 호출 0건 (D-4)
# ══════════════════════════════════════════════════════════════════
reset_test
export KMS_TOKEN="stub-kms"
export REVIEWER_ENV="production"   # 오타 — 화이트리스트(local/dev/stg/test/prod) 밖
export MOCK_BASE_POST1_BODY='{"message":"approve your own pull request"}'; export MOCK_BASE_POST2_BODY='{"id":9500,"state":"COMMENTED"}'
run_forge 120 APPROVE
check "$([[ "$(kms_call_count)" == "0" ]] && echo 1 || echo 0)" "T14 environment 오타 → KMS 호출 0건"
check "$([[ "$LAST_ERR" == *"environment 값 불인정"* ]] && echo 1 || echo 0)" "T14 stderr에 environment 값 불인정 안내"

# ══════════════════════════════════════════════════════════════════
echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
