#!/usr/bin/env bash
# release-notes-platforms.test.sh — play_upload.release_notes 의 platforms 해석과 침묵 제거
#
# 결함(zen-koi #33): `platforms.get("android")` 가 빈 객체 `{}` 를 "안드로이드 아님" 으로 읽어
# app-portal 8개 앱 중 **7개**의 릴리즈 노트가 빠졌다. 그리고 누락이 `ℹ️` 한 줄이라
# 종료 코드가 바뀌지 않아, **노트 없는 AAB 가 성공으로 올라갔다.**
#
# `app-pages` 문서가 `{}` 를 유효하다고 보증한다 — 같은 플러그인의 산출물을 같은 플러그인이
# 못 읽는 상태였다. 그래서 여기서는 **문서와 코드가 같은 것을 말하는지**도 본다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PU="$REPO_ROOT/aiops/scripts/play_upload.py"
PAGES="$REPO_ROOT/aiops/skills/app-pages/SKILL.md"
AND="$REPO_ROOT/aiops/skills/android-release/SKILL.md"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/rel-notes-test.XXXXXX")"
trap 'rm -rf "$TMPBASE"' EXIT

TOTAL=0; PASS=0; FAIL=0
ok()    { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1"; }
notok() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "not ok $TOTAL - $1"; }
check() { [[ "$1" == "1" ]] && ok "$2" || notok "$2"; }

command -v python3 >/dev/null 2>&1 || {
  notok "python3 이 없어 검증하지 못했습니다 — **검사 불가**"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"; exit 1; }

# 스크립트를 재구현하지 않는다 — 실제 모듈을 로드해 호출한다.
# $1=portal 경로(빈 문자열이면 None) $2=slug → "why|notes(한 줄)"
call_notes() {
  python3 - "$PU" "$1" "$2" <<'PY' 2>&1
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("pu", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
spec.loader.exec_module(m)
portal = pathlib.Path(sys.argv[2]) if sys.argv[2] else None
notes, why = m.release_notes(portal, sys.argv[3], "ko-KR")
print(f"{why}|{(notes or '').replace(chr(10), ' / ')}")
PY
}

mk() {  # $1=이름 $2=slug ; stdin=json
  local d="$TMPBASE/$1/content/$2"; mkdir -p "$d"; cat > "$d/releases.json"; echo "$TMPBASE/$1"
}

# ── A. `{}` 는 해당으로 읽는다 (결함의 본체) ─────────────────────────
P=$(mk p_empty zen-koi <<'J'
{"releases":[{"version":"1.0.0","platforms":{},"changes":[{"ko":"첫 출시","en":"First"}]}]}
J
)
R=$(call_notes "$P" zen-koi)
check "$([[ "${R%%|*}" == "ok" ]] && echo 1)" "A1 platforms={} 는 Android 해당으로 읽는다"
check "$(echo "$R" | grep -q '첫 출시' && echo 1)" "A2 노트 본문이 만들어진다"

# platforms 키 자체가 없는 경우도 같다
P=$(mk p_nokey app <<'J'
{"releases":[{"version":"1.0.0","changes":[{"ko":"키 없음"}]}]}
J
)
check "$([[ "$(call_notes "$P" app)" == ok\|* ]] && echo 1)" "A3 platforms 키가 아예 없어도 해당으로 읽는다"

# ── B. 명시적 null 은 제외 — {} 와 구별된다 ─────────────────────────
P=$(mk p_null app <<'J'
{"releases":[{"version":"1.0","platforms":{"ios":"1.0","android":null},"changes":[{"ko":"아이폰만"}]}]}
J
)
R=$(call_notes "$P" app)
check "$([[ "${R%%|*}" == "no_android_release" ]] && echo 1)" "B1 android:null 은 제외 ({} 와 다르다)"
check "$(echo "$R" | grep -q '아이폰만' && echo 0 || echo 1)" "B2 제외된 릴리스의 노트를 쓰지 않는다"

# null 다음에 해당 릴리스가 있으면 그것을 쓴다
P=$(mk p_mixed app <<'J'
{"releases":[{"version":"1.2","platforms":{"ios":"1.2","android":null},"changes":[{"ko":"아이폰만"}]},
             {"version":"1.1","platforms":{"ios":null,"android":"1.1"},"changes":[{"ko":"안드로이드"}]}]}
J
)
R=$(call_notes "$P" app)
check "$([[ "${R%%|*}" == "ok" ]] && echo 1)" "B3 건너뛰고 다음 해당 릴리스를 찾는다"
check "$(echo "$R" | grep -q '안드로이드' && echo 1)" "B4 올바른 릴리스의 노트를 쓴다"

# ── C. 못 만든 이유가 구별되는가 (처방이 다르다) ────────────────────
check "$([[ "$(call_notes "" app)" == no_portal\|* ]] && echo 1)" "C1 --portal 없음 → no_portal"
check "$([[ "$(call_notes "$TMPBASE/p_empty" 없는앱)" == no_file\|* ]] && echo 1)" "C2 파일 없음 → no_file"

P=$(mk p_none app <<'J'
{"releases":[]}
J
)
check "$([[ "$(call_notes "$P" app)" == no_releases\|* ]] && echo 1)" "C3 릴리스 배열이 빔 → no_releases"

P=$(mk p_bad app <<'J'
{"releases": [ this is not json
J
)
R=$(call_notes "$P" app)
check "$(echo "${R%%|*}" | grep -q '^unreadable' && echo 1)" "C4 깨진 JSON → unreadable (조용히 없음으로 넘어가지 않는다)"

# **이 파일의 존재 이유** — 이유가 전부 같은 값이면 처방을 구별할 수 없다
W1=$(call_notes "" app); W2=$(call_notes "$TMPBASE/p_empty" 없는앱); W3=$(call_notes "$TMPBASE/p_null" app)
check "$([[ "${W1%%|*}" != "${W2%%|*}" && "${W2%%|*}" != "${W3%%|*}" && "${W1%%|*}" != "${W3%%|*}" ]] && echo 1)" \
      "C5 못 만든 이유 셋이 서로 다르다 (${W1%%|*}/${W2%%|*}/${W3%%|*})"

# ── D. 누락이 조용하지 않은가 — main() 의 종료 코드 ──────────────────
SRC="$(cat "$PU")"
# `return 2` 가 노트 실패 경로에 있어야 한다
check "$(echo "$SRC" | grep -q '릴리즈 노트를 만들지 못했습니다' && echo 1)" "D1 실패를 ❌ 로 말한다"
check "$(echo "$SRC" | grep -A4 '릴리즈 노트를 만들지 못했습니다' | grep -q 'return 2' && echo 1)" \
      "D2 노트를 못 만들면 **종료 코드 2** 로 멈춘다 (예전엔 그대로 업로드됐다)"
check "$(echo "$SRC" | grep -q 'no-notes 를 \*\*명시\*\*' && echo 1)" "D3 --no-notes 를 명시하라고 안내한다"
check "$(echo "$SRC" | grep -q 'ℹ️  --no-notes' && echo 1)" "D4 --no-notes 를 준 경우는 정상 경로로 남는다"

# ── E. 문서와 코드가 같은 것을 말하는가 ──────────────────────────────
check "$(grep -q '빈 객체 `{}` 도 유효하다' "$PAGES" && echo 1)" "E1 app-pages 가 {} 를 유효로 보증한다"
check "$(echo "$SRC" | grep -q '빈 객체' && echo 1)" "E2 코드가 그 보증을 근거로 적는다"
check "$(grep -q 'portal <app-portal>' "$AND" && echo 1)" "E3 android-release 예시에 --portal 이 있다"
# 예시에서 --portal 없는 play_upload 호출이 남아 있으면 문서대로 따를 때 노트가 무조건 빈다
LEFT=$(grep -n 'play_upload.py.*--slug' "$AND" | grep -v -- '--portal' || true)
check "$([[ -z "$LEFT" ]] && echo 1)" "E4 --portal 없는 예시가 남아 있지 않다 ${LEFT:+($LEFT)}"

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
