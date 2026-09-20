#!/usr/bin/env bash
# android-release-signing-gate.test.sh — /aiops:android-release §5-1 AAB 서명 게이트
# aiops/skills/android-release/SKILL.md 의 `android-release:signing-gate` 앵커를 검증한다.
#
# 이 게이트의 핵심은 서명 탐지가 아니라 **세 상태의 분리**다.
#   0  서명됨
#   1  서명 없음        → 사람이 서명 설정을 고쳐야 한다
#   2  검사 불가        → AAB 가 없거나 열리지 않는다. 처방이 다르다
# 2 를 0 으로 뭉개면 서명 없는 AAB 가 업로드까지 간다(zen-koi 지적, 2026-09-20).
#
# 순수 bash(3.2 호환). aiops/tests/app-ads-id-gate.test.sh 규약을 따른다.
# 게이트를 재구현하지 않는다 — SKILL.md 의 앵커 사이 코드를 awk 로 추출해 실행한다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$REPO_ROOT/aiops/skills/android-release/SKILL.md"
ANCHOR="android-release:signing-gate"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/and-sign-gate-test.XXXXXX")"
cleanup() { rm -rf "$TMPBASE"; }
trap cleanup EXIT

TOTAL=0; PASS=0; FAIL=0
ok()    { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1"; }
notok() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "not ok $TOTAL - $1"; }
check() { [[ "$1" == "1" ]] && ok "$2" || notok "$2"; }

extract_block() {   # $1=파일 $2=앵커 이름
  awk -v a=">>> $2 >>>" -v b="<<< $2 <<<" '
    index($0,a){f=1;next} index($0,b){f=0} f' "$1"
}

GATE_CODE="$(extract_block "$SKILL" "$ANCHOR")"
if [[ -z "$GATE_CODE" ]]; then
  notok "앵커 사이 코드 추출 실패 — android-release/SKILL.md 의 $ANCHOR 앵커 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
  exit 1
fi
GATE_FILE="$TMPBASE/gate.sh"
printf '%s\n' "$GATE_CODE" > "$GATE_FILE"

# ── 작업공간 준비 ────────────────────────────────────────────────────
new_ws() { local ws="$TMPBASE/ws_$RANDOM$RANDOM"; mkdir -p "$ws"; echo "$ws"; }
aab_dir() { local d="$1/app/build/outputs/bundle/release"; mkdir -p "$d"; echo "$d"; }

# $1=ws  $2...=zip 에 넣을 상대 경로들
make_aab() {
  local ws="$1"; shift
  local d; d="$(aab_dir "$ws")"
  local stage="$ws/.stage"; rm -rf "$stage"; mkdir -p "$stage"
  local p
  for p in "$@"; do mkdir -p "$stage/$(dirname "$p")"; echo "payload" > "$stage/$p"; done
  ( cd "$stage" && zip -qr "$d/app-release.aab" . )
  echo "$d/app-release.aab"
}

# 게이트를 ws 에서 **인자 없이** 돌린다. 소싱하면 호출자의 위치 인자가 그대로 보여
# 게이트의 `${1:-}` 가 ws 경로를 AAB 경로로 읽는다 — 그래서 별도 프로세스로 실행한다.
run_gate() {   # $1=ws  [$2=셸]
  local sh="${2:-bash}"
  GATE_OUT="$(cd "$1" && "$sh" "$GATE_FILE" 2>&1)"
  GATE_RC=$?
}

command -v zip >/dev/null 2>&1 || {
  notok "zip 이 없어 테스트를 수행할 수 없습니다 — 검사 불가"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"; exit 1; }

# ── A. 서명된 AAB → 0 ────────────────────────────────────────────────
ws="$(new_ws)"; make_aab "$ws" "META-INF/ZEN-KOI.RSA" "META-INF/MANIFEST.MF" "classes.dex" >/dev/null
run_gate "$ws"
check "$([[ "$GATE_RC" == "0" ]] && echo 1)" "A1 RSA 서명 블록이 있으면 0"
check "$(echo "$GATE_OUT" | grep -q '✅' && echo 1)" "A2 통과 시 ✅ 를 출력"

for ext in DSA EC; do
  ws="$(new_ws)"; make_aab "$ws" "META-INF/CERT.$ext" "classes.dex" >/dev/null
  run_gate "$ws"
  check "$([[ "$GATE_RC" == "0" ]] && echo 1)" "A3 $ext 서명 블록도 0 (RSA 만 보지 않는다)"
done

# ── B. 서명 없는 AAB → 1 ─────────────────────────────────────────────
ws="$(new_ws)"; make_aab "$ws" "META-INF/MANIFEST.MF" "classes.dex" "base/manifest/AndroidManifest.xml" >/dev/null
run_gate "$ws"
check "$([[ "$GATE_RC" == "1" ]] && echo 1)" "B1 서명 블록이 없으면 1 (0 도 2 도 아니다)"
check "$(echo "$GATE_OUT" | grep -q '서명되지 않은' && echo 1)" "B2 서명 없음을 명시"

# MANIFEST.MF 만 있는 것을 서명으로 오인하지 않는다 — jar 는 서명 없이도 이 파일을 가진다
check "$(echo "$GATE_OUT" | grep -qv '✅' && echo 1)" "B3 MANIFEST.MF 를 서명으로 오인하지 않는다"

# META-INF 하위 디렉터리의 .RSA 는 서명 블록이 아니다 (^META-INF/[^/]+\.RSA$ 여야 한다)
ws="$(new_ws)"; make_aab "$ws" "META-INF/services/foo.RSA" "classes.dex" >/dev/null
run_gate "$ws"
check "$([[ "$GATE_RC" == "1" ]] && echo 1)" "B4 META-INF 하위 디렉터리의 .RSA 는 서명이 아니다"

# 이름에 RSA 가 들어갈 뿐인 파일도 아니다
ws="$(new_ws)"; make_aab "$ws" "META-INF/RSA-notes.txt" "res/raw/RSA.key" >/dev/null
run_gate "$ws"
check "$([[ "$GATE_RC" == "1" ]] && echo 1)" "B5 확장자가 아닌 이름 속 RSA 는 서명이 아니다"

# ── C. 검사 불가 → 2 ─────────────────────────────────────────────────
ws="$(new_ws)"; mkdir -p "$ws"
run_gate "$ws"
check "$([[ "$GATE_RC" == "2" ]] && echo 1)" "C1 AAB 가 없으면 2 (서명 없음 1 이 아니다)"

ws="$(new_ws)"; d="$(aab_dir "$ws")"; echo "not a zip at all" > "$d/app-release.aab"
run_gate "$ws"
check "$([[ "$GATE_RC" == "2" ]] && echo 1)" "C2 zip 이 아니면 2"
check "$(echo "$GATE_OUT" | grep -q '판정할 수 없' && echo 1)" "C3 2 는 판정 불가임을 밝힌다"

ws="$(new_ws)"; d="$(aab_dir "$ws")"; : > "$d/app-release.aab"
run_gate "$ws"
check "$([[ "$GATE_RC" == "2" ]] && echo 1)" "C4 빈 파일도 2 (0바이트를 서명 없음으로 읽지 않는다)"

# **이 테스트가 이 파일의 존재 이유다** — 세 상태가 서로 다른 코드로 나오는가
ws_ok="$(new_ws)";   make_aab "$ws_ok" "META-INF/A.RSA" "classes.dex" >/dev/null
ws_un="$(new_ws)";   make_aab "$ws_un" "classes.dex" >/dev/null
ws_no="$(new_ws)"
run_gate "$ws_ok"; RC_OK=$GATE_RC
run_gate "$ws_un"; RC_UN=$GATE_RC
run_gate "$ws_no"; RC_NO=$GATE_RC
check "$([[ "$RC_OK" != "$RC_UN" && "$RC_UN" != "$RC_NO" && "$RC_OK" != "$RC_NO" ]] && echo 1)" \
      "C5 서명됨·서명없음·검사불가가 서로 다른 종료 코드 ($RC_OK/$RC_UN/$RC_NO)"

# ── D. 인자로 경로를 직접 줄 수 있다 ─────────────────────────────────
ws="$(new_ws)"; AAB="$(make_aab "$ws" "META-INF/X.RSA" "classes.dex")"
GATE_OUT="$(bash "$GATE_FILE" "$AAB" 2>&1)"; GATE_RC=$?
check "$([[ "$GATE_RC" == "0" ]] && echo 1)" "D1 인자로 준 경로를 사용한다"

GATE_OUT="$(bash "$GATE_FILE" "$ws/없는파일.aab" 2>&1)"; GATE_RC=$?
check "$([[ "$GATE_RC" == "2" ]] && echo 1)" "D2 인자 경로가 없으면 2 (탐색으로 폴백해 딴 파일을 집지 않는다)"

# ── E. zsh 에서도 같아야 한다 (글롭 전개 차이가 과거 게이트를 죽인 원인) ──
if command -v zsh >/dev/null 2>&1; then
  ws="$(new_ws)"; make_aab "$ws" "META-INF/A.RSA" "classes.dex" >/dev/null
  run_gate "$ws" zsh
  check "$([[ "$GATE_RC" == "0" ]] && echo 1)" "E1 zsh 에서도 서명된 AAB 는 0"
  ws="$(new_ws)"
  run_gate "$ws" zsh
  check "$([[ "$GATE_RC" == "2" ]] && echo 1)" "E2 zsh 에서 AAB 부재는 2 (글롭으로 죽지 않는다)"
else
  ok "E1 zsh 미설치 — 건너뜀"
  ok "E2 zsh 미설치 — 건너뜀"
fi

# ── F. 문서 규약 ─────────────────────────────────────────────────────
# 비인용 글롭은 zsh 에서 게이트를 통째로 죽인다. find 의 -path/-name 인자가 인용돼 있는가.
UNQUOTED=$(printf '%s\n' "$GATE_CODE" | grep -v '^[[:space:]]*#' \
           | grep -oE "\-(path|name) [^'\"[:space:]]*[*?][^[:space:]]*")
check "$([[ -z "$UNQUOTED" ]] && echo 1)" "F1 find 의 글롭 인자가 모두 인용됨 ${UNQUOTED:+(비인용: $UNQUOTED)}"

# 종료 코드 세 개가 모두 코드에 존재하는가 — 하나라도 빠지면 상태가 뭉개진 것이다
for rc in 0 1 2; do
  case "$rc" in
    0) hit=$(printf '%s\n' "$GATE_CODE" | grep -cE '^[[:space:]]*(echo .*✅)') ;;
    *) hit=$(printf '%s\n' "$GATE_CODE" | grep -cE "exit $rc") ;;
  esac
  check "$([[ "$hit" -ge 1 ]] && echo 1)" "F2-$rc 종료 코드 $rc 경로가 코드에 있다"
done

# §5 표가 서명을 별도 행으로 분리했는가 (뭉뚱그린 "AAB 존재·서명" 이 이 결함의 출발점이었다)
check "$(grep -q '| \*\*AAB 서명\*\* |' "$SKILL" && echo 1)" "F3 §5 표에 AAB 서명 행이 분리돼 있다"
check "$(grep -q 'AAB 존재·서명' "$SKILL" && echo 1 || echo 1)" "F4 뭉뚱그린 행이 남아 있지 않다"
check "$(grep -q 'AAB 존재·서명' "$SKILL" && echo 0 || echo 1)" "F5 'AAB 존재·서명' 문구 제거 확인"

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
