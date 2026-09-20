#!/usr/bin/env bash
# target-sdk-gate.test.sh — /aiops:android-release §5-2 대상 API 수준 게이트
#
# 결함(zen-koi #37): 점검이 아예 없어 신규 앱의 **첫 업로드가 반드시 실패**했다.
# 실패 지점이 나빴다 — 편집 세션 생성 · 6MB 업로드 · 트랙 반영을 다 하고 `edits.commit`
# 에서 거부된다. 불가역 경계 바로 앞이다.
#
# Google 의 거부 메시지가 오진을 부른다: "Target SDK of artifact is too low: 1."
# `1` 은 versionCode 처럼 보이고 실제 값도 요구 값도 없다. 그래서 이 게이트의 핵심은
# 탐지가 아니라 **무엇이 얼마여서 걸렸는지 말하는 것**이다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$REPO_ROOT/aiops/skills/android-release/SKILL.md"
ANCHOR="android-release:target-sdk"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/tsdk-gate-test.XXXXXX")"
trap 'rm -rf "$TMPBASE"' EXIT

TOTAL=0; PASS=0; FAIL=0
ok()    { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1"; }
notok() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "not ok $TOTAL - $1"; }
check() { [[ "$1" == "1" ]] && ok "$2" || notok "$2"; }

extract_block() {
  awk -v a=">>> $2 >>>" -v b="<<< $2 <<<" 'index($0,a){f=1;next} index($0,b){f=0} f' "$1"
}
CODE="$(extract_block "$SKILL" "$ANCHOR")"
if [[ -z "$CODE" ]]; then
  notok "앵커 추출 실패 — android-release/SKILL.md 의 $ANCHOR 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"; exit 1
fi
GATE="$TMPBASE/gate.sh"; printf '%s\n' "$CODE" > "$GATE"

command -v python3 >/dev/null 2>&1 || {
  notok "python3 이 없어 검증하지 못했습니다 — **검사 불가**"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"; exit 1; }

# AAB 를 만든다 — 실제 구조(protobuf manifest)를 그대로 흉내 낸다.
# 속성은 [0x12 len "이름"][0x1A len "값"] 이다.
mkaab() {  # $1=경로 $2=targetSdk 값("" 이면 속성 자체를 넣지 않는다)
  python3 - "$1" "$2" <<'PY'
import sys, os, zipfile
path, val = sys.argv[1], sys.argv[2]
def attr(name, value):
    n, v = name.encode(), value.encode()
    return b"\x12" + bytes([len(n)]) + n + b"\x1a" + bytes([len(v)]) + v
blob = b"\x0a\x08manifest" + attr("minSdkVersion", "26")
if val:
    blob += attr("targetSdkVersion", val)
blob += attr("compileSdkVersion", "36")
os.makedirs(os.path.dirname(path), exist_ok=True)
with zipfile.ZipFile(path, "w") as z:
    z.writestr("base/manifest/AndroidManifest.xml", blob)
    z.writestr("BundleConfig.pb", b"\x00")
PY
}

run() { OUT="$(bash "$GATE" "$@" 2>&1)"; RC=$?; }

# ── A. 충족 ─────────────────────────────────────────────────────────
mkaab "$TMPBASE/ok/app.aab" 36
run "$TMPBASE/ok/app.aab"
check "$([[ "$RC" == "0" ]] && echo 1)" "A1 36 은 통과"
check "$(echo "$OUT" | grep -q '36' && echo 1)" "A2 읽은 값을 출력한다"
mkaab "$TMPBASE/hi/app.aab" 37
run "$TMPBASE/hi/app.aab"
check "$([[ "$RC" == "0" ]] && echo 1)" "A3 요구보다 높아도 통과 (같음만 보지 않는다)"

# ── B. 미달 — 메시지가 오진을 부르지 않아야 한다 ────────────────────
mkaab "$TMPBASE/low/app.aab" 35
run "$TMPBASE/low/app.aab"
check "$([[ "$RC" == "1" ]] && echo 1)" "B1 35 는 미달(1)"
check "$(echo "$OUT" | grep -q '35' && echo 1)" "B2 **실제 값**을 보여준다"
check "$(echo "$OUT" | grep -q '36' && echo 1)" "B3 **요구 값**을 보여준다 (Google 메시지엔 둘 다 없다)"
check "$(echo "$OUT" | grep -q '다시 빌드' && echo 1)" "B4 재빌드가 필요함을 말한다 (설정만 고치는 것을 막는다)"
check "$(echo "$OUT" | grep -q "$TMPBASE/low/app.aab" && echo 1)" "B5 어느 AAB 인지 밝힌다"

mkaab "$TMPBASE/vlow/app.aab" 24
run "$TMPBASE/vlow/app.aab"
check "$([[ "$RC" == "1" ]] && echo 1)" "B6 훨씬 낮아도 1 (2 로 새지 않는다)"

# ── C. 검사 불가 — 이 파일의 존재 이유 ──────────────────────────────
# 리소스 참조로 지정된 경우. **미달로 단정하면 안 된다.**
mkaab "$TMPBASE/ref/app.aab" "@integer/tsdk"
run "$TMPBASE/ref/app.aab"
check "$([[ "$RC" == "2" ]] && echo 1)" "C1 숫자가 아니면 2 (미달 1 이 아니다)"
check "$(echo "$OUT" | grep -q '단정하지 않습니다' && echo 1)" "C2 미달로 단정하지 않는다고 말한다"

mkaab "$TMPBASE/noattr/app.aab" ""
run "$TMPBASE/noattr/app.aab"
check "$([[ "$RC" == "2" ]] && echo 1)" "C3 targetSdkVersion 속성이 없으면 2"

printf 'not a zip' > "$TMPBASE/bad.aab"
run "$TMPBASE/bad.aab"
check "$([[ "$RC" == "2" ]] && echo 1)" "C4 zip 이 아니면 2"

mkdir -p "$TMPBASE/empty" && (cd "$TMPBASE/empty" && bash "$GATE" >/dev/null 2>&1); RC=$?
check "$([[ "$RC" == "2" ]] && echo 1)" "C5 AAB 를 못 찾으면 2"

# 세 상태가 서로 다른 코드인가
run "$TMPBASE/ok/app.aab";  RC_OK=$RC
run "$TMPBASE/low/app.aab"; RC_LOW=$RC
run "$TMPBASE/ref/app.aab"; RC_BLIND=$RC
check "$([[ "$RC_OK" != "$RC_LOW" && "$RC_LOW" != "$RC_BLIND" && "$RC_OK" != "$RC_BLIND" ]] && echo 1)" \
      "C6 충족·미달·검사불가가 서로 다른 종료 코드 ($RC_OK/$RC_LOW/$RC_BLIND)"

# ── D. 폼 팩터 — 36 을 박아 두면 Wear/TV 를 잘못 막는다 ─────────────
OUT="$(ANDROID_TARGET_SDK_REQUIRED=35 bash "$GATE" "$TMPBASE/low/app.aab" 2>&1)"; RC=$?
check "$([[ "$RC" == "0" ]] && echo 1)" "D1 요구 수준을 조정할 수 있다 (Wear/Automotive 35)"
OUT="$(ANDROID_TARGET_SDK_REQUIRED=34 bash "$GATE" "$TMPBASE/vlow/app.aab" 2>&1)"; RC=$?
check "$([[ "$RC" == "1" ]] && echo 1)" "D2 조정해도 그보다 낮으면 여전히 1"

# ── E. 실제 AAB 가 있으면 그것으로도 돌린다 ─────────────────────────
# **$HOME 전체를 훑지 않는다.** 실측에서 이 한 줄이 스위트를 수 분 늘렸다.
# 경로를 주고 싶으면 AIOPS_TEST_AAB 로 준다 — 없으면 건너뛴다.
# "실제 AAB 로도 돌려 본다" 는 좋지만, 그 대가가 매 실행 수 분이면 사람이 스위트를 안 돌린다.
REAL="${AIOPS_TEST_AAB:-}"
if [[ -n "$REAL" ]]; then
  run "$REAL"
  check "$([[ "$RC" == "0" || "$RC" == "1" ]] && echo 1)" \
        "E1 실제 AAB 에서 숫자를 읽는다 (rc=$RC — 2 면 파싱이 깨진 것)"
  check "$(echo "$OUT" | grep -qE '수준 [0-9]+|AAB 는 [0-9]+' && echo 1)" "E2 실제 AAB 의 값을 출력한다"
else
  ok "E1 실제 AAB 없음 — 건너뜀"; ok "E2 건너뜀"
fi

# ── F. 문서 규약 ─────────────────────────────────────────────────────
# **제출 기준은 신규·업데이트가 같다.** 35 는 노출 요건이지 제출 기준이 아니다 —
# 둘을 섞으면 35짜리 업데이트를 통과시키고 커밋에서 실패한다(#37 보고서의 제안이 그랬다).
check "$(grep -q '제출 기준은 신규·업데이트가 같다' "$SKILL" && echo 1)" "F1 신규·업데이트 기준이 같음을 명시한다"
check "$(grep -q '앱 제공 가능 요건' "$SKILL" && echo 1)" "F2 35 가 다른 요건임을 구별한다"
check "$(grep -q 'Target SDK of artifact is too low' "$SKILL" && echo 1)" "F3 오진을 부르는 원문 메시지를 남긴다"
check "$(grep -q 'support.google.com' "$SKILL" && echo 1)" "F4 출처 URL 을 주석에 남긴다"
check "$(grep -q '매년 오른다' "$SKILL" && echo 1)" "F5 값이 낡는다는 것을 경고한다"
check "$(grep -q '| \*\*대상 API 수준\*\* |' "$SKILL" && echo 1)" "F6 §5 표에 행이 있다"
# 상수로 두었는가 — 숫자를 조건문에 직접 박으면 폼 팩터 조정이 불가능하다
check "$(printf '%s\n' "$CODE" | grep -q 'ANDROID_TARGET_SDK_REQUIRED' && echo 1)" "F7 요구 수준이 상수·환경변수다"

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
