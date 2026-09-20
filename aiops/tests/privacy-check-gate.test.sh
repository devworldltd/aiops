#!/usr/bin/env bash
# privacy-check-gate.test.sh — /aiops:android-release §5-1 개인정보처리방침 점검 게이트
# `release:privacy-check` 앵커를 추출해 검증한다. (iphone-release §4-1 이 같은 게이트를 쓴다)
#
# 이 게이트의 결함은 판정 로직이 아니라 **그 앞의 관측 방법**이었다 — `-L` 이 없어
# app-portal 의 307 리다이렉트를 미게시로 읽었다(zen-koi #31). 실제 URL 로 한 번도
# 돌려 보지 않으면 드러나지 않는 종류다. 그래서 네트워크 없이도 도는 로컬 서버로 검증한다.
#
# 순수 bash(3.2 호환). aiops/tests/app-ads-id-gate.test.sh 규약을 따른다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$REPO_ROOT/aiops/skills/android-release/SKILL.md"
IOS_SKILL="$REPO_ROOT/aiops/skills/iphone-release/SKILL.md"
ANCHOR="release:privacy-check"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/privacy-gate-test.XXXXXX")"
SRV_PID=""
# 종료 시 셸이 "Terminated" 를 **마지막 줄에** 찍으면 집계 스크립트가 TESTS= 줄 대신
# 그것을 읽는다. 잡 제어를 끄고 wait 로 회수한다 — 출력 규약(마지막 줄 = 집계)을 지킨다.
cleanup() {
  if [[ -n "$SRV_PID" ]]; then
    set +m 2>/dev/null
    kill "$SRV_PID" 2>/dev/null
    wait "$SRV_PID" 2>/dev/null
  fi
  rm -rf "$TMPBASE"
}
trap cleanup EXIT

TOTAL=0; PASS=0; FAIL=0
ok()    { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1"; }
notok() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "not ok $TOTAL - $1"; }
check() { [[ "$1" == "1" ]] && ok "$2" || notok "$2"; }

extract_block() {
  awk -v a=">>> $2 >>>" -v b="<<< $2 <<<" 'index($0,a){f=1;next} index($0,b){f=0} f' "$1"
}

GATE_CODE="$(extract_block "$SKILL" "$ANCHOR")"
if [[ -z "$GATE_CODE" ]]; then
  notok "앵커 추출 실패 — android-release/SKILL.md 의 $ANCHOR 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"; exit 1
fi
GATE_FILE="$TMPBASE/gate.sh"; printf '%s\n' "$GATE_CODE" > "$GATE_FILE"

run_gate() { GATE_OUT="$(bash "$GATE_FILE" "$1" 2>&1)"; GATE_RC=$?; }

# ── 로컬 서버: app-portal 과 같은 307 동작을 재현한다 ────────────────
PORT=0
for p in 18731 18732 18733 18734; do
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then PORT=$p; break; fi
done
if [[ "$PORT" == "0" ]] || ! command -v python3 >/dev/null 2>&1; then
  notok "로컬 서버를 띄우지 못해 게이트를 검증하지 못했습니다 — **검사 불가**"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"; exit 1
fi

cat > "$TMPBASE/srv.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/privacy":            # app-portal 과 같은 트레일링 슬래시 307
            self.send_response(307); self.send_header("Location", "/privacy/"); self.end_headers()
        elif self.path == "/privacy/":
            self.send_response(200); self.send_header("Content-Type","text/html"); self.end_headers()
            self.wfile.write(b"policy")
        elif self.path == "/elsewhere":        # 엉뚱한 곳으로 가는 리다이렉트
            self.send_response(302); self.send_header("Location", "/privacy/"); self.end_headers()
        elif self.path == "/boom":
            self.send_response(500); self.end_headers()
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
set +m 2>/dev/null          # 잡 종료 알림을 끈다
python3 "$TMPBASE/srv.py" "$PORT" 2>/dev/null & SRV_PID=$!
BASE="http://127.0.0.1:$PORT"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null --max-time 1 "$BASE/privacy/" && break
  # 폴링 간격 — sleep 대신 curl 자체의 연결 시도로 시간을 쓴다
  curl -s -o /dev/null --max-time 1 "$BASE/" 2>/dev/null
done

# ── A. 307 → 200 은 통과해야 한다 (이 이슈의 본체) ───────────────────
run_gate "$BASE/privacy"
check "$([[ "$GATE_RC" == "0" ]] && echo 1)" "A1 307 → 200 은 통과 (미게시로 읽지 않는다)"
check "$(echo "$GATE_OUT" | grep -q '최종 URL' && echo 1)" "A2 최종 URL 을 보고에 남긴다"
check "$(echo "$GATE_OUT" | grep -q '리다이렉트됨' && echo 1)" "A3 리다이렉트가 있었음을 밝힌다"
check "$(echo "$GATE_OUT" | grep -q '/privacy/' && echo 1)" "A4 최종 URL 이 슬래시 붙은 주소다"

run_gate "$BASE/privacy/"
check "$([[ "$GATE_RC" == "0" ]] && echo 1)" "A5 리다이렉트 없는 200 도 통과"
check "$(echo "$GATE_OUT" | grep -q '리다이렉트됨' && echo 0 || echo 1)" "A6 리다이렉트가 없으면 그 말을 하지 않는다"

# 엉뚱한 곳으로 가는 리다이렉트도 최종 URL 이 드러나야 한다
run_gate "$BASE/elsewhere"
check "$([[ "$GATE_RC" == "0" ]] && echo 1)" "A7 302 도 최종 200 이면 통과"
check "$(echo "$GATE_OUT" | grep -q 'elsewhere' && echo 1)" "A8 요청 URL 을 함께 보여 엉뚱한 리다이렉트를 사람이 본다"

# ── B. 미게시 ────────────────────────────────────────────────────────
run_gate "$BASE/없는페이지"
check "$([[ "$GATE_RC" == "1" ]] && echo 1)" "B1 404 는 미게시(1)"
check "$(echo "$GATE_OUT" | grep -q '404' && echo 1)" "B2 실제 상태 코드를 밝힌다"
run_gate "$BASE/boom"
check "$([[ "$GATE_RC" == "1" ]] && echo 1)" "B3 5xx 도 미게시(1)"

# ── C. 검사 불가 — 이 파일의 존재 이유 ───────────────────────────────
# curl 실패 시 %{http_code} 는 000 이다. 숫자 비교로 짜면 "200 이 아니므로 미게시" 가 된다.
run_gate "http://127.0.0.1:1/privacy"
check "$([[ "$GATE_RC" == "2" ]] && echo 1)" "C1 연결 실패는 2 (미게시 1 이 아니다)"
check "$(echo "$GATE_OUT" | grep -q '판정할 수 없' && echo 1)" "C2 판정 불가임을 밝힌다"
check "$(echo "$GATE_OUT" | grep -q '단정하지 않습니다' && echo 1)" "C3 미게시로 단정하지 않는다고 말한다"

run_gate "http://존재하지않는호스트.invalid/privacy"
check "$([[ "$GATE_RC" == "2" ]] && echo 1)" "C4 DNS 실패도 2"

run_gate ""
check "$([[ "$GATE_RC" != "0" ]] && echo 1)" "C5 빈 URL 은 통과하지 않는다"

# 세 상태가 서로 다른 코드인가
run_gate "$BASE/privacy";              RC_OK=$GATE_RC
run_gate "$BASE/없는페이지";            RC_NO=$GATE_RC
run_gate "http://127.0.0.1:1/privacy"; RC_BLIND=$GATE_RC
check "$([[ "$RC_OK" != "$RC_NO" && "$RC_NO" != "$RC_BLIND" && "$RC_OK" != "$RC_BLIND" ]] && echo 1)" \
      "C6 게시·미게시·검사불가가 서로 다른 종료 코드 ($RC_OK/$RC_NO/$RC_BLIND)"

# ── D. 코드 규약 ─────────────────────────────────────────────────────
NC=$(printf '%s\n' "$GATE_CODE" | grep -v '^[[:space:]]*#' | grep -c 'curl.*-sL' || true)
check "$([[ "$NC" -ge 1 ]] && echo 1)" "D1 curl 에 -L 이 있다 (없으면 307 이 미게시가 된다)"
check "$(printf '%s\n' "$GATE_CODE" | grep -q 'url_effective' && echo 1)" "D2 최종 URL 을 조회한다"
check "$(printf '%s\n' "$GATE_CODE" | grep -q 'max-time' && echo 1)" "D3 타임아웃이 있다 (릴리스가 매달리지 않는다)"
check "$(printf '%s\n' "$GATE_CODE" | grep -q '000' && echo 1)" "D4 000 을 명시적으로 다룬다"

# ── E. 양쪽 스킬이 같은 게이트를 가리키는가 ──────────────────────────
check "$(grep -q '리다이렉트를 따라간' "$SKILL" && echo 1)" "E1 android-release 표가 게이트를 가리킨다"
check "$(grep -q '리다이렉트를 따라간' "$IOS_SKILL" && echo 1)" "E2 iphone-release 표도 게이트를 가리킨다"
check "$(grep -q 'release:privacy-check' "$IOS_SKILL" && echo 1)" "E3 iphone-release 가 앵커 이름을 명시한다"
check "$(grep -q '가 200 |' "$SKILL" && echo 0 || echo 1)" "E4 android 표에 '200' 단독 판정이 남아 있지 않다"
check "$(grep -q '가 200 |' "$IOS_SKILL" && echo 0 || echo 1)" "E5 iphone 표에도 남아 있지 않다"

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
