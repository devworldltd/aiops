#!/usr/bin/env bash
# app-record-extract.test.sh — /aiops:app-record §3 입력 추출 게이트
#
# 이 게이트의 위험은 **틀린 값을 자신 있게 제안하는 것**이다. 빈 값도 위험하지만,
# 그럴듯한 오답이 더 위험하다 — 사람이 확인 화면에서 그냥 넘긴다.
#
# 실제로 초안이 둘 다 틀렸다(zen-koi 레포 실측, 2026-09-20):
#   앱 이름   values-zh 의 번역본 `禅鲤` 를 집었다 (기본 로케일이 아니라)
#   번들 ID   `<앱>.tests` 가 함께 잡혀 순서에 따라 테스트 타깃을 집을 수 있었다
# 그래서 여기서는 "읽혔는가" 가 아니라 **"올바른 것을 읽었는가"** 를 본다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$REPO_ROOT/aiops/skills/app-record/SKILL.md"
ANCHOR="app-record:extract"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/app-record-test.XXXXXX")"
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
  notok "앵커 추출 실패 — app-record/SKILL.md 의 $ANCHOR 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"; exit 1
fi
GATE="$TMPBASE/gate.sh"; printf '%s\n' "$CODE" > "$GATE"

run() { OUT="$(bash "$GATE" "$1" 2>&1)"; RC=$?; }
field() { echo "$OUT" | grep "^$1" | sed 's/^[^:]*:[[:space:]]*//'; }

# 실제 레포와 같은 레이아웃을 만든다 (모듈 디렉터리 + 로케일 디렉터리)
mkrepo() {  # $1=이름
  local r="$TMPBASE/$1"
  mkdir -p "$r/android/app/src/main/res/values" "$r/ios"
  echo "$r"
}

# ── A. 올바른 값을 읽는가 ────────────────────────────────────────────
R=$(mkrepo ok)
cat > "$R/android/app/build.gradle.kts" <<'G'
android {
    defaultConfig {
        applicationId = "kr.co.devworld.zenkoi"
        resourceConfigurations += listOf("en", "ko", "ja", "zh-rCN")
    }
}
G
printf '<resources><string name="app_name">Zen Koi</string></resources>\n' \
  > "$R/android/app/src/main/res/values/strings.xml"
cat > "$R/ios/project.yml" <<'Y'
targets:
  App:
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: kr.co.devworld.zenkoi
  AppTests:
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: kr.co.devworld.zenkoi.tests
Y
run "$R"
check "$([[ "$RC" == "0" ]] && echo 1)" "A1 정상 레포는 0"
check "$([[ "$(field 패키지명)" == "kr.co.devworld.zenkoi" ]] && echo 1)" "A2 패키지명을 읽는다 ($(field 패키지명))"
check "$([[ "$(field 앱)" == "Zen Koi" ]] && echo 1)" "A3 앱 이름을 읽는다 ($(field 앱))"
check "$(echo "$OUT" | grep -q 'ko' && echo 1)" "A4 언어 목록을 읽는다"

# ── B. 번역본을 집지 않는가 (실측 결함 1) ────────────────────────────
mkdir -p "$R/android/app/src/main/res/values-zh-rCN" "$R/android/app/src/main/res/values-ja"
printf '<resources><string name="app_name">禅鲤</string></resources>\n' \
  > "$R/android/app/src/main/res/values-zh-rCN/strings.xml"
printf '<resources><string name="app_name">禅の鯉</string></resources>\n' \
  > "$R/android/app/src/main/res/values-ja/strings.xml"
run "$R"
check "$([[ "$(field 앱)" == "Zen Koi" ]] && echo 1)" "B1 로케일 디렉터리가 있어도 기본값을 읽는다 ($(field 앱))"
check "$(echo "$OUT" | grep -q '禅' && echo 0 || echo 1)" "B2 번역본이 결과에 섞이지 않는다"

# 기본 로케일 파일이 **없으면** 번역본으로 때우지 않는다 — 못 읽었다고 말해야 한다
R2=$(mkrepo nodefault)
echo 'applicationId = "kr.co.x"' > "$R2/android/app/build.gradle.kts"
mkdir -p "$R2/android/app/src/main/res/values-ja"
printf '<resources><string name="app_name">翻訳</string></resources>\n' \
  > "$R2/android/app/src/main/res/values-ja/strings.xml"
run "$R2"
check "$(echo "$OUT" | grep -q '翻訳' && echo 0 || echo 1)" "B3 기본 로케일이 없으면 번역본으로 때우지 않는다"
check "$(echo "$OUT" | grep -q '못 읽음' && echo 1)" "B4 못 읽었다고 말한다 (빈 값을 조용히 넘기지 않는다)"

# ── C. 테스트 타깃을 집지 않는가 (실측 결함 2) ───────────────────────
R3=$(mkrepo iosorder)
cat > "$R3/ios/project.yml" <<'Y'
targets:
  AppTests:
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: kr.co.devworld.zenkoi.tests
  AppUITests:
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: kr.co.devworld.zenkoi.uitests
  App:
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: kr.co.devworld.zenkoi
Y
run "$R3"
check "$([[ "$(field 패키지명)" == "kr.co.devworld.zenkoi" ]] && echo 1)" \
      "C1 테스트 타깃이 **먼저 나와도** 앱 타깃을 집는다 ($(field 패키지명))"
check "$(echo "$OUT" | grep -q 'tests' && echo 0 || echo 1)" "C2 .tests 가 결과에 나오지 않는다"

# ── D. 불일치는 사람 판단으로 넘긴다 ─────────────────────────────────
R4=$(mkrepo mismatch)
echo 'applicationId = "kr.co.a"' > "$R4/android/app/build.gradle.kts"
printf 'targets:\n  App:\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: kr.co.b\n' > "$R4/ios/project.yml"
run "$R4"
check "$([[ "$RC" == "1" ]] && echo 1)" "D1 플랫폼 간 불일치는 1"
check "$(echo "$OUT" | grep -q 'kr.co.a' && echo "$OUT" | grep -q 'kr.co.b' && echo 1)" \
      "D2 양쪽 값을 모두 보여준다 (사람이 고를 수 있게)"

# ── E. 추출 불가를 빈 값으로 넘기지 않는가 ───────────────────────────
R5=$(mkrepo empty)
run "$R5"
check "$([[ "$RC" == "2" ]] && echo 1)" "E1 식별자를 어느 쪽에서도 못 읽으면 2"
check "$(echo "$OUT" | grep -q '빈 값으로 진행하지 않습니다' && echo 1)" "E2 빈 값으로 진행하지 않는다고 말한다"

# 세 상태가 서로 다른 코드인가
run "$R";  RC_OK=$RC
run "$R4"; RC_MIS=$RC
run "$R5"; RC_NONE=$RC
check "$([[ "$RC_OK" != "$RC_MIS" && "$RC_MIS" != "$RC_NONE" && "$RC_OK" != "$RC_NONE" ]] && echo 1)" \
      "E3 정상·불일치·추출불가가 서로 다른 종료 코드 ($RC_OK/$RC_MIS/$RC_NONE)"

# 한쪽 플랫폼만 있는 레포도 통과해야 한다 (Android 전용 · iOS 전용)
R6=$(mkrepo androidonly)
echo 'applicationId = "kr.co.only"' > "$R6/android/app/build.gradle.kts"
run "$R6"; check "$([[ "$RC" == "0" ]] && echo 1)" "E4 Android 전용 레포도 통과"
R7=$(mkrepo iosonly)
printf 'targets:\n  App:\n    settings:\n      PRODUCT_BUNDLE_IDENTIFIER: kr.co.ios\n' > "$R7/ios/project.yml"
run "$R7"; check "$([[ "$RC" == "0" && "$(field 패키지명)" == "kr.co.ios" ]] && echo 1)" "E5 iOS 전용 레포도 통과"

# ── F. 문서 규약 ─────────────────────────────────────────────────────
# 되돌릴 수 없는 것이 패키지명 하나라는 것을 문서가 말하는가 (뭉뚱그리면 경고가 묻힌다)
check "$(grep -q '되돌릴 수 없는 것은 패키지명 하나다' "$SKILL" && echo 1)" "F1 불가역 항목이 하나임을 명시한다"
check "$(grep -q '나중에 변경할 수 있습니다' "$SKILL" && echo 1)" "F2 변경 가능 항목의 근거를 인용한다"
# ASC API 로 생성 불가 — 이 전제가 설계를 결정했다
check "$(grep -q "Don't use this API to create new apps" "$SKILL" && echo 1)" "F3 ASC 생성 불가를 원문으로 인용한다"
check "$(grep -q '로그인' "$SKILL" && echo 1)" "F4 로그인 금지를 명시한다"
# 기본 언어는 코드가 정하지 못한다
check "$(grep -q '정하지 못한다' "$SKILL" && echo 1)" "F5 기본 언어를 코드가 정하지 못함을 명시한다"
# 404 와 403 을 구별하는가
check "$(grep -q '404 와 403 을 구별한다' "$SKILL" && echo 1)" "F6 검증에서 404 와 403 을 구별한다"

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
