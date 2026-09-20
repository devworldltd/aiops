#!/usr/bin/env bash
# setup-platform-signals.test.sh — /aiops:setup §15-1 platform 신호 계산
# `setup:platform-signals` 앵커를 검증한다.
#
# 이 블록이 생긴 이유: §16 의 platform 판정이 쓰는 WEB_DETECTED·MOBILE_DETECTED 가
# 어디에서도 계산되지 않아 **판정이 실행 주체의 해석에 달려 있었다**(zen-koi 이슈 #26).
# 검사(판정)가 실행 가능한 코드가 아니면 지켜졌는지 알 수 없다.
#
# 순수 bash(3.2 호환). aiops/tests/setup-platform-detect.test.sh 규약을 따른다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_SKILL="$REPO_ROOT/aiops/skills/setup/SKILL.md"
SIG_ANCHOR="setup:platform-signals"
DETECT_ANCHOR="setup:platform-detect"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/platform-signals-test.XXXXXX")"
cleanup() { rm -rf "$TMPBASE"; }
trap cleanup EXIT

TOTAL=0; PASS=0; FAIL=0
ok()    { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1"; }
notok() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "not ok $TOTAL - $1"; }
check() { [[ "$1" == "1" ]] && ok "$2" || notok "$2"; }

extract_block() {
  awk -v a=">>> $2 >>>" -v b="<<< $2 <<<" '
    index($0,a){f=1;next} index($0,b){f=0} f' "$1"
}

SIG_CODE="$(extract_block "$SETUP_SKILL" "$SIG_ANCHOR")"
DETECT_CODE="$(extract_block "$SETUP_SKILL" "$DETECT_ANCHOR")"
if [[ -z "$SIG_CODE" || -z "$DETECT_CODE" ]]; then
  notok "앵커 추출 실패 — $SIG_ANCHOR / $DETECT_ANCHOR 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"; exit 1
fi
export SIG_CODE DETECT_CODE

new_ws() { local ws="$TMPBASE/ws_$RANDOM$RANDOM"; mkdir -p "$ws"; echo "$ws"; }
pkg()    { printf '%s\n' "$2" > "$1/package.json"; }

# 신호 블록만 실행
run_sig() {   # $1=ws, 나머지=env (ANDROID_DETECTED=true 등)
  local ws="$1"; shift
  SIG_OUT="$(env "$@" bash -c 'cd "$1" && eval "$SIG_CODE" >/dev/null 2>&1
             printf "WEB=%s\nMOB=%s\nWSIG=%s\nMSIG=%s\n" \
               "$WEB_DETECTED" "$MOBILE_DETECTED" "$WEB_SIGNAL" "$MOBILE_SIGNAL"' _ "$ws" 2>&1)"
  SIG_WEB="$(printf '%s\n' "$SIG_OUT" | grep '^WEB=' | cut -d= -f2)"
  SIG_MOB="$(printf '%s\n' "$SIG_OUT" | grep '^MOB=' | cut -d= -f2)"
  SIG_WSIG="$(printf '%s\n' "$SIG_OUT" | grep '^WSIG=' | cut -d= -f2-)"
  SIG_MSIG="$(printf '%s\n' "$SIG_OUT" | grep '^MSIG=' | cut -d= -f2-)"
}

# 신호 + 판정을 이어서 실행 (§15-1 → §16 실행 순서 그대로)
run_chain() {   # $1=ws, 나머지=env
  local ws="$1"; shift
  CHAIN_OUT="$(env "$@" bash -c 'cd "$1" && eval "$SIG_CODE
$DETECT_CODE"' _ "$ws" 2>&1)"
  CHAIN_PLATFORM="$(printf '%s\n' "$CHAIN_OUT" | grep -o 'platform=[a-z]*' | tail -1 | cut -d= -f2)"
  CHAIN_SIGNAL="$(printf '%s\n' "$CHAIN_OUT" | grep -o 'signal=[^(]*' | tail -1 | sed 's/^signal=//;s/ *$//')"
  CHAIN_FALLBACK="$(printf '%s\n' "$CHAIN_OUT" | grep -c 'none (fallback)')"
}

# ══════════════════════════════════════════════════════════════════
# S1 — 두 변수를 반드시 정의한다 (이슈 #26 의 본질)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); run_sig "$ws"
check "$([[ -n "$SIG_WEB" && -n "$SIG_MOB" ]] && echo 1 || echo 0)" \
      "S1 빈 레포에서도 두 변수를 정의 (web=$SIG_WEB mobile=$SIG_MOB)"

# ══════════════════════════════════════════════════════════════════
# S2 — MOBILE_DETECTED 는 네 플래그의 OR
# ══════════════════════════════════════════════════════════════════
for flag in ANDROID_DETECTED IOS_DETECTED RN_DETECTED FLUTTER_DETECTED; do
  ws=$(new_ws); run_sig "$ws" "$flag=true"
  check "$([[ "$SIG_MOB" == "true" ]] && echo 1 || echo 0)" "S2 $flag=true → mobile=true"
done
ws=$(new_ws); run_sig "$ws"
check "$([[ "$SIG_MOB" == "false" ]] && echo 1 || echo 0)" "S2 네 플래그 모두 false → mobile=false"

# ══════════════════════════════════════════════════════════════════
# S3 — Gradle·Maven 단독은 웹 신호가 아니다 (이슈 #26 곁가지)
#      이게 깨지면 Android 레포가 전부 both 가 된다
# ══════════════════════════════════════════════════════════════════
for f in build.gradle build.gradle.kts pom.xml; do
  ws=$(new_ws); mkdir -p "$ws/app"; : > "$ws/app/$f"
  run_sig "$ws" ANDROID_DETECTED=true
  check "$([[ "$SIG_WEB" == "false" ]] && echo 1 || echo 0)" "S3 $f 단독 → web=false"
done

# ══════════════════════════════════════════════════════════════════
# S4 — react 는 단독일 때만 웹 신호 (RN 은 react 를 반드시 의존한다)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); pkg "$ws" '{"dependencies":{"react-native":"0.74","react":"18.2.0"}}'
run_sig "$ws" RN_DETECTED=true
check "$([[ "$SIG_WEB" == "false" ]] && echo 1 || echo 0)" \
      "S4 react-native + react → web=false (react 단독 아님)"

ws=$(new_ws); pkg "$ws" '{"dependencies":{"react":"18.2.0","react-dom":"18"}}'
run_sig "$ws"
check "$([[ "$SIG_WEB" == "true" ]] && echo 1 || echo 0)" "S4 react 단독 → web=true"

ws=$(new_ws); pkg "$ws" '{"dependencies":{"react-native":"0.74","react":"18"},"devDependencies":{"next":"14"}}'
run_sig "$ws" RN_DETECTED=true
check "$([[ "$SIG_WEB" == "true" ]] && echo 1 || echo 0)" "S4 RN + next → web=true (실제 both)"

# ══════════════════════════════════════════════════════════════════
# S5 — 웹 프레임워크·배포 매니페스트 감지
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); pkg "$ws" '{"dependencies":{"hono":"^4"}}'; run_sig "$ws"
check "$([[ "$SIG_WEB" == "true" ]] && echo 1 || echo 0)" "S5 hono → web=true"
ws=$(new_ws); printf 'fastapi==0.110\n' > "$ws/requirements.txt"; run_sig "$ws"
check "$([[ "$SIG_WEB" == "true" ]] && echo 1 || echo 0)" "S5 fastapi → web=true"
ws=$(new_ws); : > "$ws/wrangler.toml"; run_sig "$ws"
check "$([[ "$SIG_WEB" == "true" ]] && echo 1 || echo 0)" "S5 wrangler.toml → web=true"
ws=$(new_ws); printf 'module example.com/m\nrequire github.com/gin-gonic/gin v1.9.1\n' > "$ws/go.mod"; run_sig "$ws"
check "$([[ "$SIG_WEB" == "true" ]] && echo 1 || echo 0)" "S5 gin → web=true"

# ══════════════════════════════════════════════════════════════════
# S6 — §15-1 → §16 연결. platform 이 코드로 결정된다
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); mkdir -p "$ws/android"; : > "$ws/android/build.gradle.kts"
run_chain "$ws" ANDROID_DETECTED=true IOS_DETECTED=true
check "$([[ "$CHAIN_PLATFORM" == "mobile" ]] && echo 1 || echo 0)" \
      "S6 Android+iOS 모바일 레포 → platform=mobile (실제: $CHAIN_PLATFORM)"

ws=$(new_ws); pkg "$ws" '{"dependencies":{"hono":"^4"}}'; run_chain "$ws"
check "$([[ "$CHAIN_PLATFORM" == "web" ]] && echo 1 || echo 0)" \
      "S6 Hono 웹 레포 → platform=web (실제: $CHAIN_PLATFORM)"

ws=$(new_ws); printf 'fastapi==0.110\n' > "$ws/requirements.txt"; mkdir -p "$ws/android"; : > "$ws/android/build.gradle.kts"
run_chain "$ws" ANDROID_DETECTED=true
check "$([[ "$CHAIN_PLATFORM" == "both" ]] && echo 1 || echo 0)" \
      "S6 FastAPI+Android → platform=both (실제: $CHAIN_PLATFORM)"

# ══════════════════════════════════════════════════════════════════
# S7 — 신호가 산문이 아니라 코드로 계산된다 (회귀 방지)
# ══════════════════════════════════════════════════════════════════
check "$(printf '%s' "$SIG_CODE" | grep -qE '^MOBILE_DETECTED=false' && echo 1 || echo 0)" \
      "S7 MOBILE_DETECTED 를 앵커 안에서 계산"
check "$(printf '%s' "$SIG_CODE" | grep -qE '^WEB_DETECTED=false' && echo 1 || echo 0)" \
      "S7 WEB_DETECTED 를 앵커 안에서 계산"

# ══════════════════════════════════════════════════════════════════
# P1 — 신호 근거를 기록한다. "판정됨" 과 "기본값으로 떨어짐" 은 다르다
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); : > "$ws/wrangler.toml"; run_sig "$ws"
check "$([[ "$SIG_WSIG" == "wrangler.toml" ]] && echo 1 || echo 0)" \
      "P1 배포 매니페스트 근거 기록 (실제: $SIG_WSIG)"

ws=$(new_ws); pkg "$ws" '{"dependencies":{"hono":"^4"}}'; run_sig "$ws"
check "$(printf '%s' "$SIG_WSIG" | grep -q 'package.json:hono' && echo 1 || echo 0)" \
      "P1 프레임워크 근거에 파일과 키 (실제: $SIG_WSIG)"

ws=$(new_ws); run_sig "$ws" ANDROID_DETECTED=true IOS_DETECTED=true
check "$([[ "$SIG_MSIG" == "android+ios" ]] && echo 1 || echo 0)" \
      "P1 모바일 근거에 플래그 전부 (실제: $SIG_MSIG)"

# ══════════════════════════════════════════════════════════════════
# P2 — 폴백은 폴백이라고 말한다 + 경고를 출력한다
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); run_chain "$ws"
check "$([[ "$CHAIN_PLATFORM" == "web" ]] && echo 1 || echo 0)" "P2 빈 레포 → platform=web (종전 동작)"
check "$([[ "$CHAIN_FALLBACK" -ge 1 ]] && echo 1 || echo 0)" \
      "P2 폴백임을 signal 에 명시"
check "$(printf '%s' "$CHAIN_OUT" | grep -q '사람이 확인하세요' && echo 1 || echo 0)" \
      "P2 폴백일 때 경고 출력"

# ══════════════════════════════════════════════════════════════════
# P3 — 신호로 판정한 web 과 폴백 web 이 구별된다 (이 기능의 존재 이유)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); pkg "$ws" '{"dependencies":{"hono":"^4"}}'; run_chain "$ws"
sig_web_platform="$CHAIN_PLATFORM"; sig_web_signal="$CHAIN_SIGNAL"; sig_web_fb="$CHAIN_FALLBACK"
ws=$(new_ws); run_chain "$ws"
check "$([[ "$sig_web_platform" == "$CHAIN_PLATFORM" && "$sig_web_signal" != "$CHAIN_SIGNAL" ]] && echo 1 || echo 0)" \
      "P3 platform 은 같고(web) signal 은 다르다 ($sig_web_signal vs $CHAIN_SIGNAL)"
check "$([[ "$sig_web_fb" == "0" && "$CHAIN_FALLBACK" -ge 1 ]] && echo 1 || echo 0)" \
      "P3 신호 판정에는 폴백 경고가 없다"

# ══════════════════════════════════════════════════════════════════
# P4 — 기존 platform= grep 이 깨지지 않는다 (§16 소비자 호환)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); pkg "$ws" '{"dependencies":{"hono":"^4"}}'; run_chain "$ws"
check "$(printf '%s' "$CHAIN_OUT" | grep -qE 'platform=web( |$)' && echo 1 || echo 0)" \
      "P4 'platform=<값>' 형식이 유지됨"

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]] && exit 0 || exit 1
