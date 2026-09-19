#!/usr/bin/env bash
# setup-mobile-capability-detect.test.sh — 모바일 앱 역량 감지(권한·SDK) 계층
# aiops/skills/setup/SKILL.md 의 `setup:mobile-capability-detect` 앵커(§20)를 검증한다.
#
# 순수 bash(3.2 호환). aiops/tests/setup-platform-detect.test.sh 규약을 그대로 따른다:
#   - 케이스별 `ok N - <설명>` / `not ok N - <설명>`
#   - 마지막 줄 `TESTS=<총> PASS=<n> FAIL=<n>`
#   - 종료 코드: 전건 통과 0, 1건 이상 실패 1
#
# 감지기를 재구현하지 않는다 — SKILL.md 의 앵커 사이 코드를 awk 로 그대로
# 추출해 픽스처 디렉터리에서 eval 한다(문서-코드 일치 강제).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_SKILL="$REPO_ROOT/aiops/skills/setup/SKILL.md"
CAP_ANCHOR="setup:mobile-capability-detect"
WRITE_ANCHOR="setup:mobile-capability-write"
UPDATE_ANCHOR="setup:config-update"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/setup-mobile-cap-test.XXXXXX")"
cleanup() { rm -rf "$TMPBASE"; }
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

CAP_CODE="$(extract_block "$SETUP_SKILL" "$CAP_ANCHOR")"
WRITE_CODE="$(extract_block "$SETUP_SKILL" "$WRITE_ANCHOR")"

if [[ -z "$CAP_CODE" ]]; then
  notok "앵커 사이 코드 추출 실패 — setup/SKILL.md 의 $CAP_ANCHOR 앵커 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
  exit 1
fi

UPDATE_CODE="$(extract_block "$SETUP_SKILL" "$UPDATE_ANCHOR")"
if [[ -z "$WRITE_CODE" || -z "$UPDATE_CODE" ]]; then
  notok "앵커 사이 코드 추출 실패 — $WRITE_ANCHOR / $UPDATE_ANCHOR 앵커 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# ── 픽스처 헬퍼 ──────────────────────────────────────────────────────
new_ws() {
  local ws="$TMPBASE/ws_$RANDOM$RANDOM"
  mkdir -p "$ws"
  echo "$ws"
}

write_manifest() {   # $1=ws $2..=권한 이름(android.permission.X 또는 FQCN)
  local ws="$1"; shift
  mkdir -p "$ws/app/src/main"
  {
    echo '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
    for _p in "$@"; do echo "  <uses-permission android:name=\"$_p\"/>"; done
    echo '</manifest>'
  } > "$ws/app/src/main/AndroidManifest.xml"
}

write_plist() {      # $1=ws $2..=NS*UsageDescription 키
  local ws="$1"; shift
  mkdir -p "$ws/ios/App"
  {
    echo '<plist><dict>'
    for _k in "$@"; do echo "  <key>$_k</key><string>reason</string>"; done
    echo '</dict></plist>'
  } > "$ws/ios/App/Info.plist"
}

write_gradle() {     # $1=ws $2=파일 내용
  local ws="$1"
  mkdir -p "$ws/app"
  printf '%s\n' "$2" > "$ws/app/build.gradle.kts"
}

# 앵커 코드를 픽스처 디렉터리에서 실행하고 결과 변수를 회수한다.
# eval 결과 변수는 서브셸에 갇히므로 출력으로 흘려 파싱한다.
run_cap() {   # $1=ws
  local ws="$1" out
  out="$( (cd "$ws" && eval "$CAP_CODE" >/dev/null 2>&1
           printf 'PERM=%s\nSDK=%s\nSRC=%s\nLANG=%s\nBASEUNK=%s\n' \
             "$MOBILE_PERMISSIONS" "$MOBILE_SDKS" "$MOBILE_CAPABILITY_SOURCES" \
             "$MOBILE_LANGUAGES" "$MOBILE_LANG_BASE_UNKNOWN") 2>&1 )"
  CAP_RC=$?
  CAP_PERM="$(printf '%s\n' "$out" | grep '^PERM=' | head -1 | cut -d= -f2-)"
  CAP_SDK="$(printf '%s\n' "$out"  | grep '^SDK='  | head -1 | cut -d= -f2-)"
  CAP_SRC="$(printf '%s\n' "$out"  | grep '^SRC='  | head -1 | cut -d= -f2-)"
  CAP_LANG="$(printf '%s\n' "$out"    | grep '^LANG='    | head -1 | cut -d= -f2-)"
  CAP_BASEUNK="$(printf '%s\n' "$out" | grep '^BASEUNK=' | head -1 | cut -d= -f2-)"
}

# 쉼표 목록에 토큰이 있는지 (부분 일치 오탐 방지 — 앵커 있는 비교)
has_tok() {   # $1=쉼표목록 $2=토큰
  printf '%s' ",$1," | grep -q ",$2,"
}

# ══════════════════════════════════════════════════════════════════
# T1 — Android uses-permission 정규화
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_manifest "$ws" android.permission.INTERNET android.permission.CAMERA
run_cap "$ws"
check "$(has_tok "$CAP_PERM" camera && echo 1 || echo 0)"   "T1 Android CAMERA → camera"
check "$(has_tok "$CAP_PERM" internet && echo 1 || echo 0)" "T1 Android INTERNET → internet"

# ══════════════════════════════════════════════════════════════════
# T2 — Android AD_ID(FQCN)와 iOS ATT 가 같은 tracking 토큰으로 수렴
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_manifest "$ws" com.google.android.gms.permission.AD_ID
run_cap "$ws"
check "$(has_tok "$CAP_PERM" tracking && echo 1 || echo 0)" "T2 Android AD_ID → tracking"

ws=$(new_ws)
write_plist "$ws" NSUserTrackingUsageDescription
run_cap "$ws"
check "$(has_tok "$CAP_PERM" tracking && echo 1 || echo 0)" "T2 iOS ATT 키 → tracking"

# ══════════════════════════════════════════════════════════════════
# T3 — iOS Info.plist 키 정규화 (위치·사진)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_plist "$ws" NSLocationWhenInUseUsageDescription NSPhotoLibraryAddUsageDescription
run_cap "$ws"
check "$(has_tok "$CAP_PERM" location && echo 1 || echo 0)"      "T3 iOS 위치 키 → location"
check "$(has_tok "$CAP_PERM" photo_library && echo 1 || echo 0)" "T3 iOS 사진 추가 키 → photo_library"

# ══════════════════════════════════════════════════════════════════
# T4 — Android + iOS 합집합, 중복 제거
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_manifest "$ws" android.permission.CAMERA android.permission.CAMERA android.permission.RECORD_AUDIO
write_plist "$ws" NSCameraUsageDescription
run_cap "$ws"
check "$(has_tok "$CAP_PERM" camera && echo 1 || echo 0)"     "T4 양 플랫폼 camera 합집합"
check "$(has_tok "$CAP_PERM" microphone && echo 1 || echo 0)" "T4 RECORD_AUDIO → microphone"
check "$([[ "$(printf '%s' "$CAP_PERM" | tr ',' '\n' | grep -c '^camera$')" == "1" ]] && echo 1 || echo 0)" \
      "T4 camera 중복 제거 (1회만)"

# ══════════════════════════════════════════════════════════════════
# T5 — SDK 감지 (Gradle)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_gradle "$ws" 'dependencies {
  implementation("com.google.android.gms:play-services-ads:23.0.0")
  implementation("com.google.android.ump:user-messaging-platform:2.2.0")
}'
run_cap "$ws"
check "$(has_tok "$CAP_SDK" admob && echo 1 || echo 0)" "T5 play-services-ads → admob"
check "$(has_tok "$CAP_SDK" ump && echo 1 || echo 0)"   "T5 user-messaging-platform → ump"

# ══════════════════════════════════════════════════════════════════
# T6 — 제외 디렉터리(node_modules)는 스캔하지 않는다
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
mkdir -p "$ws/node_modules/pkg"
echo '{"dependencies":{"@sentry/react-native":"^5.0.0"}}' > "$ws/node_modules/pkg/package.json"
run_cap "$ws"
check "$(has_tok "$CAP_SDK" sentry && echo 0 || echo 1)" "T6 node_modules 내부 의존성은 감지 제외"

# ══════════════════════════════════════════════════════════════════
# T7 — 감지 0건은 오류가 아니다 (빈 목록 + rc=0)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
run_cap "$ws"
check "$([[ -z "$CAP_PERM" && -z "$CAP_SDK" ]] && echo 1 || echo 0)" "T7 빈 레포 → 권한·SDK 빈 목록"
check "$([[ "$CAP_RC" == "0" ]] && echo 1 || echo 0)"                "T7 빈 레포 → 종료 코드 0"

# ══════════════════════════════════════════════════════════════════
# T8 — 표에 없는 권한은 무시한다 (선언된 것만 적는다 원칙의 역방향)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_manifest "$ws" android.permission.VIBRATE
run_cap "$ws"
check "$([[ -z "$CAP_PERM" ]] && echo 1 || echo 0)" "T8 정규화 표에 없는 VIBRATE 는 토큰 미생성"

# ══════════════════════════════════════════════════════════════════
# T9 — sources 에 실제로 읽은 파일이 기록된다 ("감지 안 됨" 과 "권한 없음" 구별)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_manifest "$ws" android.permission.VIBRATE
run_cap "$ws"
check "$(printf '%s' "$CAP_SRC" | grep -q 'AndroidManifest.xml' && echo 1 || echo 0)" \
      "T9 권한 0건이어도 읽은 매니페스트가 sources 에 남는다"

# ══════════════════════════════════════════════════════════════════
# T10 — 앵커 코드가 bash 3.2 금지 구문을 쓰지 않는다
# ══════════════════════════════════════════════════════════════════
# 주석 줄은 제외한다 — 규칙을 설명하는 주석이 그 규칙에 걸리면 안 된다.
CAP_CODE_NOCOMMENT="$(printf '%s\n' "$CAP_CODE" | sed 's/[[:space:]]*#.*$//')"
check "$(printf '%s' "$CAP_CODE_NOCOMMENT" | grep -qE 'declare -A|mapfile|\$\{[A-Za-z_]+,,\}' && echo 0 || echo 1)" \
      "T10 연관배열·mapfile·\${v,,} 미사용 (bash 3.2 준수, 주석 제외)"

# ══════════════════════════════════════════════════════════════════
# T11 — 표준 Android 레이아웃 깊이(<wrapper>/app/src/main = 깊이 5) 회귀 방지
#       maxdepth 4 로 되돌리면 android/ 래퍼를 쓰는 레포가 통째로 미감지된다.
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
mkdir -p "$ws/android/app/src/main"
cat > "$ws/android/app/src/main/AndroidManifest.xml" <<'MANIFEST'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.INTERNET"/>
</manifest>
MANIFEST
run_cap "$ws"
check "$(has_tok "$CAP_PERM" internet && echo 1 || echo 0)" \
      "T11 android/app/src/main (깊이 5) 매니페스트 감지"

# ══════════════════════════════════════════════════════════════════
# T12 — Privacy Sandbox 광고 권한도 tracking 으로 수렴
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_manifest "$ws" android.permission.ACCESS_ADSERVICES_AD_ID
run_cap "$ws"
check "$(has_tok "$CAP_PERM" tracking && echo 1 || echo 0)" "T12 ACCESS_ADSERVICES_AD_ID → tracking"

# ══════════════════════════════════════════════════════════════════
# T13 — 빌드 생성물(build/)은 깊이를 올려도 읽지 않는다
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
mkdir -p "$ws/android/app/build/intermediates/merged"
cat > "$ws/android/app/build/intermediates/merged/AndroidManifest.xml" <<'MANIFEST'
<uses-permission android:name="android.permission.CAMERA"/>
MANIFEST
run_cap "$ws"
check "$([[ -z "$CAP_PERM" ]] && echo 1 || echo 0)" "T13 build/ 내부 병합 매니페스트는 감지 제외"

# ── 언어 픽스처 헬퍼 ────────────────────────────────────────────────
write_values() {   # $1=ws $2..=values- 한정자
  local ws="$1"; shift
  for _q in "$@"; do mkdir -p "$ws/android/app/src/main/res/values-$_q"; done
  mkdir -p "$ws/android/app/src/main/res/values"
}

write_xcstrings() {   # $1=ws $2=sourceLanguage $3..=localizations 키
  local ws="$1" src="$2"; shift 2
  mkdir -p "$ws/ios/App/Resources"
  {
    printf '{\n  "sourceLanguage" : "%s",\n  "strings" : {\n    "hello" : {\n      "localizations" : {\n' "$src"
    local first=1
    for _k in "$@"; do
      [[ $first == 0 ]] && printf ',\n'
      printf '        "%s" : { "stringUnit" : { "value" : "x" } }' "$_k"
      first=0
    done
    printf '\n      }\n    }\n  },\n  "version" : "1.0"\n}\n'
  } > "$ws/ios/App/Resources/Localizable.xcstrings"
}

# ══════════════════════════════════════════════════════════════════
# L1 — Android values-* 정규화 (중국어 지역 코드 포함)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_values "$ws" ko ja zh-rCN zh-rTW
run_cap "$ws"
check "$(has_tok "$CAP_LANG" ko && echo 1 || echo 0)"      "L1 values-ko → ko"
check "$(has_tok "$CAP_LANG" zh-Hans && echo 1 || echo 0)" "L1 values-zh-rCN → zh-Hans"
check "$(has_tok "$CAP_LANG" zh-Hant && echo 1 || echo 0)" "L1 values-zh-rTW → zh-Hant"

# ══════════════════════════════════════════════════════════════════
# L2 — 언어가 아닌 한정자는 걸러낸다 (night·land·v21·sw600dp·tv)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_values "$ws" ko night land v21 sw600dp tv xxhdpi
run_cap "$ws"
check "$([[ "$CAP_LANG" == "ko" ]] && echo 1 || echo 0)" \
      "L2 UI/밀도 한정자 제외 — ko 만 남음 (실제: $CAP_LANG)"

# ══════════════════════════════════════════════════════════════════
# L3 — iOS xcstrings: sourceLanguage + localizations 키
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_xcstrings "$ws" en ko ja fr
run_cap "$ws"
check "$(has_tok "$CAP_LANG" en && echo 1 || echo 0)" "L3 sourceLanguage=en 포함"
check "$(has_tok "$CAP_LANG" ja && echo 1 || echo 0)" "L3 localizations 키 ja 포함"

# ══════════════════════════════════════════════════════════════════
# L4 — Android 기본 언어 미판정: iOS sourceLanguage 가 없으면 모름으로 남긴다
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_values "$ws" ko ja
run_cap "$ws"
check "$([[ "$CAP_BASEUNK" == "true" ]] && echo 1 || echo 0)" \
      "L4 Android 전용 → languages_base_unknown=true"
check "$([[ "$CAP_LANG" == "ja,ko" ]] && echo 1 || echo 0)" \
      "L4 기본 언어를 임의로 채우지 않음 (실제: $CAP_LANG)"

# ══════════════════════════════════════════════════════════════════
# L5 — Android + iOS 조합이면 기본 언어를 sourceLanguage 로 안다
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_values "$ws" ko ja de
write_xcstrings "$ws" en ko ja de
run_cap "$ws"
check "$([[ "$CAP_BASEUNK" == "false" ]] && echo 1 || echo 0)" "L5 iOS sourceLanguage 있으면 base_unknown=false"
check "$([[ "$CAP_LANG" == "de,en,ja,ko" ]] && echo 1 || echo 0)" \
      "L5 합집합 de,en,ja,ko (실제: $CAP_LANG)"

# ══════════════════════════════════════════════════════════════════
# L6 — 빌드 산출물의 .lproj 는 읽지 않는다
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
mkdir -p "$ws/ios/build/DerivedData/App.app/th.lproj"
mkdir -p "$ws/ios/App/ko.lproj"
run_cap "$ws"
check "$(has_tok "$CAP_LANG" th && echo 0 || echo 1)" "L6 DerivedData 내부 .lproj 제외"
check "$(has_tok "$CAP_LANG" ko && echo 1 || echo 0)" "L6 소스 .lproj 는 감지"

# ══════════════════════════════════════════════════════════════════
# 배선(setup:mobile-capability-write) — 감지 → config.json 기입
# ══════════════════════════════════════════════════════════════════
# 감지 + 헬퍼 + 기입을 한 셸에서 순서대로 실행한다(실제 §20 실행 순서와 동일).
run_write() {   # $1=ws $2=PLATFORM
  local ws="$1" plat="$2"
  WRITE_OUT="$( (cd "$ws" && PLATFORM="$plat" eval "$CAP_CODE
$UPDATE_CODE
$WRITE_CODE") 2>&1 )"
  WRITE_RC=$?
}

cfg_get() {   # $1=ws $2=jq 필터
  jq -r "$2" "$1/.claude/config.json" 2>/dev/null
}

seed_cfg() {  # $1=ws $2=config.json 내용
  mkdir -p "$1/.claude"; printf '%s\n' "$2" > "$1/.claude/config.json"
}

if ! command -v jq >/dev/null 2>&1; then
  notok "SKIP: jq 미설치 — 배선 테스트를 실행할 수 없습니다"
else

# ── W1 — 감지 결과가 agent_hints.mobile.capabilities 에 기입된다
ws=$(new_ws)
seed_cfg "$ws" '{"agent_hints":{"platform":"mobile","mobile":{"framework":"android-native"}}}'
write_manifest "$ws" android.permission.INTERNET com.google.android.gms.permission.AD_ID
write_gradle "$ws" 'implementation("com.google.android.gms:play-services-ads:23.0.0")'
run_write "$ws" mobile
check "$([[ "$(cfg_get "$ws" '.agent_hints.mobile.capabilities.permissions | join(",")')" == "internet,tracking" ]] && echo 1 || echo 0)" \
      "W1 permissions 기입 (internet,tracking)"
check "$([[ "$(cfg_get "$ws" '.agent_hints.mobile.capabilities.sdks | join(",")')" == "admob" ]] && echo 1 || echo 0)" \
      "W1 sdks 기입 (admob)"
check "$([[ "$(cfg_get "$ws" '.agent_hints.mobile.capabilities.languages | type')" == "array" ]] && echo 1 || echo 0)" \
      "W1 languages 키가 배열로 기입"
check "$([[ "$(cfg_get "$ws" '.agent_hints.mobile.framework')" == "android-native" ]] && echo 1 || echo 0)" \
      "W1 기존 framework 보존 (덮어쓰지 않음)"

# ── W2 — 웹 전용(platform=web)은 mobile 키를 만들지 않는다 (역호환)
ws=$(new_ws)
seed_cfg "$ws" '{"agent_hints":{"backend":{"framework":"fastapi"}}}'
write_manifest "$ws" android.permission.CAMERA
run_write "$ws" web
check "$([[ "$(cfg_get "$ws" '.agent_hints.mobile // "absent"')" == "absent" ]] && echo 1 || echo 0)" \
      "W2 platform=web → mobile 키 미생성"
check "$([[ "$(cfg_get "$ws" '.agent_hints.backend.framework')" == "fastapi" ]] && echo 1 || echo 0)" \
      "W2 기존 backend 힌트 불변"

# ── W3 — cli 도 기입 생략
ws=$(new_ws)
seed_cfg "$ws" '{"agent_hints":{}}'
run_write "$ws" cli
check "$(printf '%s' "$WRITE_OUT" | grep -q 'capabilities 기입 생략' && echo 1 || echo 0)" \
      "W3 platform=cli → 기입 생략 메시지"

# ── W4 — 감지 0건이어도 기입한다 (sources 가 근거)
ws=$(new_ws)
seed_cfg "$ws" '{"agent_hints":{"mobile":{"framework":"ios-native"}}}'
write_manifest "$ws" android.permission.VIBRATE
run_write "$ws" mobile
check "$([[ "$(cfg_get "$ws" '.agent_hints.mobile.capabilities.permissions | length')" == "0" ]] && echo 1 || echo 0)" \
      "W4 권한 0건 → 빈 배열 기입"
check "$([[ "$(cfg_get "$ws" '.agent_hints.mobile.capabilities.sources | length')" -ge 1 ]] && echo 1 || echo 0)" \
      "W4 읽은 파일이 sources 에 기입 (미감지와 구별)"

# ── W4b — Android 전용이면 languages_base_unknown 이 기입된다
ws=$(new_ws)
seed_cfg "$ws" '{"agent_hints":{"mobile":{"framework":"android-native"}}}'
mkdir -p "$ws/android/app/src/main/res/values-ko"
run_write "$ws" mobile
check "$([[ "$(cfg_get "$ws" '.agent_hints.mobile.capabilities.languages_base_unknown')" == "true" ]] && echo 1 || echo 0)" \
      "W4b Android 전용 → languages_base_unknown=true 기입"

# ── W4c — 기본 언어를 아는 경우 그 키를 남기지 않는다
ws=$(new_ws)
seed_cfg "$ws" '{"agent_hints":{"mobile":{"framework":"ios-native"}}}'
write_xcstrings "$ws" en ko
run_write "$ws" mobile
check "$([[ "$(cfg_get "$ws" '.agent_hints.mobile.capabilities.languages_base_unknown // "absent"')" == "absent" ]] && echo 1 || echo 0)" \
      "W4c base 판정 가능 → languages_base_unknown 키 없음"

# ── W5 — agent_hints 가 null 이어도 경로를 만든다
ws=$(new_ws)
seed_cfg "$ws" '{"use_docker":false,"agent_hints":null}'
write_manifest "$ws" android.permission.CAMERA
run_write "$ws" both
check "$([[ "$(cfg_get "$ws" '.agent_hints.mobile.capabilities.permissions | join(",")')" == "camera" ]] && echo 1 || echo 0)" \
      "W5 agent_hints=null 에서도 경로 생성 후 기입"
check "$([[ "$(cfg_get "$ws" '.use_docker')" == "false" ]] && echo 1 || echo 0)" \
      "W5 config.json 의 다른 필드 불변"

# ── W6 — config.json 이 없으면 원본을 만들지 않고 실패를 보고한다
ws=$(new_ws)
write_manifest "$ws" android.permission.CAMERA
run_write "$ws" mobile
check "$([[ ! -f "$ws/.claude/config.json" ]] && echo 1 || echo 0)" \
      "W6 config.json 부재 시 새로 만들지 않음"
check "$(printf '%s' "$WRITE_OUT" | grep -qE 'WARN|없음' && echo 1 || echo 0)" \
      "W6 config.json 부재를 경고로 보고"

# ── W7 — 잘못된 JSON 은 원본 바이트를 건드리지 않는다
ws=$(new_ws)
seed_cfg "$ws" '{"agent_hints": INVALID'
before="$(cat "$ws/.claude/config.json")"
write_manifest "$ws" android.permission.CAMERA
run_write "$ws" mobile
check "$([[ "$(cat "$ws/.claude/config.json")" == "$before" ]] && echo 1 || echo 0)" \
      "W7 깨진 config.json 은 원본 불변 (원자적 갱신)"

fi

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]] && exit 0 || exit 1
