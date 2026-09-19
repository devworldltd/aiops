#!/usr/bin/env bash
# app-ads-id-gate.test.sh — /aiops:app-ads §6-1 광고 ID 게이트
# aiops/skills/app-ads/SKILL.md 의 `app-ads:id-gate` 앵커를 검증한다.
#
# 이 게이트의 핵심은 위반 탐지가 아니라 **"검사 못 함" 과 "위반 없음" 의 구분**이다.
# 둘이 같은 종료 코드로 나오면 게이트가 조용히 통과한다(zen-koi 지적, 2026-09-20).
#
# 순수 bash(3.2 호환). aiops/tests/setup-platform-detect.test.sh 규약을 따른다:
#   - 케이스별 `ok N - <설명>` / `not ok N - <설명>`
#   - 마지막 줄 `TESTS=<총> PASS=<n> FAIL=<n>`
#   - 종료 코드: 전건 통과 0, 1건 이상 실패 1
#
# 게이트를 재구현하지 않는다 — SKILL.md 의 앵커 사이 코드를 awk 로 추출해 실행한다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADS_SKILL="$REPO_ROOT/aiops/skills/app-ads/SKILL.md"
GATE_ANCHOR="app-ads:id-gate"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/app-ads-gate-test.XXXXXX")"
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

GATE_CODE="$(extract_block "$ADS_SKILL" "$GATE_ANCHOR")"
if [[ -z "$GATE_CODE" ]]; then
  notok "앵커 사이 코드 추출 실패 — app-ads/SKILL.md 의 $GATE_ANCHOR 앵커 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
  exit 1
fi

GATE_FILE="$TMPBASE/gate.sh"
printf '%s\n' "$GATE_CODE" > "$GATE_FILE"

new_ws() { local ws="$TMPBASE/ws_$RANDOM$RANDOM"; mkdir -p "$ws"; echo "$ws"; }

write_gradle() {  # $1=ws $2=내용
  mkdir -p "$1/app"; printf '%s\n' "$2" > "$1/app/build.gradle.kts"
}

# 게이트를 지정한 셸로 실행하고 종료 코드를 회수한다.
run_gate() {   # $1=ws $2=셸(bash|zsh)
  GATE_OUT="$("$2" -c 'cd "$1" && . "$2"' _ "$1" "$GATE_FILE" 2>&1)"
  GATE_RC=$?
}

TEST_ID='ca-app-pub-3940256099942544/6300978111'
REAL_ID='ca-app-pub-8888888888888888/2222222222'

# 실행 셸 목록 — zsh 이 있으면 양쪽에서 돌린다(글롭 전개 차이가 이 버그의 원인이었다).
SHELLS="bash"
command -v zsh >/dev/null 2>&1 && SHELLS="bash zsh"

for SH in $SHELLS; do

# ══════════════════════════════════════════════════════════════════
# G1 — 대상 파일 0개는 "통과" 가 아니라 "검사 불가"(rc=2)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
run_gate "$ws" "$SH"
check "$([[ "$GATE_RC" == "2" ]] && echo 1 || echo 0)" \
      "G1[$SH] 대상 파일 0개 → rc=2 (검사 불가, 실제 rc=$GATE_RC)"
check "$(printf '%s' "$GATE_OUT" | grep -q '검사 대상 파일이 0개' && echo 1 || echo 0)" \
      "G1[$SH] 검사 불가 사유를 출력"

# ══════════════════════════════════════════════════════════════════
# G2 — debug 에 테스트 ID 만 있으면 통과(rc=0)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_gradle "$ws" "debug { buildConfigField(\"String\",\"B\",\"\\\"$TEST_ID\\\"\") }
release { buildConfigField(\"String\",\"B\",\"\\\"$REAL_ID\\\"\") }"
run_gate "$ws" "$SH"
check "$([[ "$GATE_RC" == "0" ]] && echo 1 || echo 0)" \
      "G2[$SH] debug=테스트ID·release=실ID → rc=0 (실제 rc=$GATE_RC)"

# ══════════════════════════════════════════════════════════════════
# G3 — debug 에 실 ID 가 있으면 위반(rc=1)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_gradle "$ws" "debug { buildConfigField(\"String\",\"B\",\"\\\"$REAL_ID\\\"\") }"
run_gate "$ws" "$SH"
check "$([[ "$GATE_RC" == "1" ]] && echo 1 || echo 0)" \
      "G3[$SH] debug 에 실 ID → rc=1 (실제 rc=$GATE_RC)"

# ══════════════════════════════════════════════════════════════════
# G4 — release 에 테스트 ID 가 남으면 위반(rc=1) — 역방향
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_gradle "$ws" "release { buildConfigField(\"String\",\"B\",\"\\\"$TEST_ID\\\"\") }"
run_gate "$ws" "$SH"
check "$([[ "$GATE_RC" == "1" ]] && echo 1 || echo 0)" \
      "G4[$SH] release 에 테스트 ID → rc=1 (실제 rc=$GATE_RC)"

# ══════════════════════════════════════════════════════════════════
# G5 — 세 결과의 종료 코드가 서로 다르다 (이 게이트의 존재 이유)
#      검사불가(2) ≠ 위반(1) ≠ 통과(0)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); run_gate "$ws" "$SH"; rc_none=$GATE_RC
ws=$(new_ws); write_gradle "$ws" "debug { \"$TEST_ID\" }"; run_gate "$ws" "$SH"; rc_pass=$GATE_RC
ws=$(new_ws); write_gradle "$ws" "debug { \"$REAL_ID\" }"; run_gate "$ws" "$SH"; rc_viol=$GATE_RC
check "$([[ "$rc_none" != "$rc_pass" && "$rc_pass" != "$rc_viol" && "$rc_none" != "$rc_viol" ]] && echo 1 || echo 0)" \
      "G5[$SH] 검사불가·통과·위반의 종료 코드가 모두 다름 ($rc_none/$rc_pass/$rc_viol)"

# ══════════════════════════════════════════════════════════════════
# G6 — build/ 안의 파일은 검사 대상이 아니다 (생성물)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
mkdir -p "$ws/app/build/generated"
printf 'debug { "%s" }\n' "$REAL_ID" > "$ws/app/build/generated/Gen.kts"
run_gate "$ws" "$SH"
check "$([[ "$GATE_RC" == "2" ]] && echo 1 || echo 0)" \
      "G6[$SH] build/ 만 있으면 검사 대상 0개 → rc=2 (실제 rc=$GATE_RC)"

done

# ══════════════════════════════════════════════════════════════════
# G7 — 앵커 코드가 글롭을 인용한다 (비인용이면 zsh 에서 조용히 통과)
# ══════════════════════════════════════════════════════════════════
# -name 뒤 토큰을 모두 뽑아, * 를 포함한 것이 인용부호로 시작하지 않으면 실패.
_unquoted="$(printf '%s\n' "$GATE_CODE" | grep -oE -- "-name [^ )]+" | grep '\*' | grep -v -- "-name ['\"]")"
check "$([[ -z "$_unquoted" ]] && echo 1 || echo 0)" \
      "G7 find -name 글롭이 모두 인용됨${_unquoted:+ (비인용: $_unquoted)}"

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]] && exit 0 || exit 1
