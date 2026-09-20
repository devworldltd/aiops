#!/usr/bin/env bash
# release-notify-gate.test.sh — tools/release.sh 의 마커·출력 토큰 통지 게이트
# `release:notify-gate` 앵커를 추출해 임의의 두 git ref 를 대조시킨다.
#
# 이 게이트가 존재하는 이유는 v1.18.0 이 HANDOFF 값 10개 + 마커 헤더 2종을
# **통지 없이 내보냈기 때문**이다. 계약은 발효돼 있었고 깨진 것도 없었지만
# 사람이 재대조할 때까지 아무도 몰랐다. 그래서 검증의 핵심은 두 가지다.
#   ① 추가·삭제를 실제로 잡는가 (과거 사고 재현)
#   ② **대조 불가를 통과로 읽지 않는가** — 이쪽이 더 중요하다
#
# 순수 bash(3.2 호환). aiops/tests/app-ads-id-gate.test.sh 규약을 따른다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RELEASE_SH="$REPO_ROOT/tools/release.sh"
ANCHOR="release:notify-gate"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/rel-notify-gate-test.XXXXXX")"
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

GATE_CODE="$(extract_block "$RELEASE_SH" "$ANCHOR")"
if [[ -z "$GATE_CODE" ]]; then
  notok "앵커 추출 실패 — tools/release.sh 의 $ANCHOR 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"; exit 1
fi
GATE_FILE="$TMPBASE/gate.sh"
printf '%s\n' "$GATE_CODE" > "$GATE_FILE"

# 게이트를 이 레포에서, 주어진 PREV/TARGET/TAG/MODE 로 돌린다.
run_gate() {   # $1=PREV $2=TARGET $3=TAG [$4=MODE]
  GATE_OUT="$(cd "$REPO_ROOT" && PREV="$1" TARGET="$2" TAG="$3" MODE="${4:-release}" \
    bash -c 'set -uo pipefail; . "$0"' "$GATE_FILE" 2>&1)"
  GATE_RC=$?
}

have_tag() { git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1; }

# ── A. 과거 사고 재현 — 실제 태그로 대조한다 ─────────────────────────
if have_tag v1.18.0 && have_tag v1.19.0; then
  run_gate v1.18.0 v1.19.0 v1.19.0
  check "$([[ "$GATE_RC" == "1" ]] && echo 1)" "A1 v1.18.0→v1.19.0 은 통지 필요로 중단"
  check "$(echo "$GATE_OUT" | grep -q 'HANDOFF_REQUIRED=android_keystore' && echo 1)" \
        "A2 새 값 android_keystore 를 짚는다"
  check "$(echo "$GATE_OUT" | grep -q 'HANDOFF_ACCESS=kms' && echo 1)" \
        "A3 새 값 HANDOFF_ACCESS=kms 를 짚는다"
else
  ok "A1 v1.18.0/v1.19.0 태그 없음 — 건너뜀"; ok "A2 건너뜀"; ok "A3 건너뜀"
fi

if have_tag v1.17.0 && have_tag v1.18.0; then
  # **통지가 실제로 누락된 구간.** 게이트가 있었다면 막았어야 한다.
  run_gate v1.17.0 v1.18.0 v1.18.0
  check "$([[ "$GATE_RC" == "1" ]] && echo 1)" "A4 통지 누락이 났던 v1.17.0→v1.18.0 을 막는다"
  check "$(echo "$GATE_OUT" | grep -q '출시 결과' && echo 1)" \
        "A5 토큰뿐 아니라 **마커 헤더 추가**도 잡는다 (손으로 쓴 통지가 빠뜨린 부분)"
else
  ok "A4 태그 없음 — 건너뜀"; ok "A5 건너뜀"
fi

# 변화 없음 → 통과
if have_tag v1.19.0; then
  run_gate v1.19.0 v1.19.0 v1.19.1
  check "$([[ "$GATE_RC" == "0" ]] && echo 1)" "A6 같은 ref 끼리는 통과"
  check "$(echo "$GATE_OUT" | grep -q '변화 없음' && echo 1)" "A7 통과 시 대조한 종수를 밝힌다"
  check "$(echo "$GATE_OUT" | grep -qE '토큰 [0-9]+종' && echo 1)" "A8 '0종 대조' 를 숨기지 않는다"
else
  ok "A6 건너뜀"; ok "A7 건너뜀"; ok "A8 건너뜀"
fi

# ── B. 대조 불가를 통과로 읽지 않는가 (이 파일의 존재 이유) ──────────
run_gate "" "HEAD" "v9.9.9"
check "$([[ "$GATE_RC" == "2" ]] && echo 1)" "B1 직전 태그가 없으면 2 (통과 0 이 아니다)"
check "$(echo "$GATE_OUT" | grep -q '대조 불가' && echo 1)" "B2 대조 불가임을 밝힌다"

# 존재하지 않는 ref → 양쪽 추출이 빈다. 빈 결과를 '변화 없음' 으로 읽으면 안 된다.
run_gate "v1.19.0" "refs/tags/없는태그" "v9.9.9"
check "$([[ "$GATE_RC" == "2" ]] && echo 1)" "B3 대상 ref 를 읽지 못하면 2"
check "$(echo "$GATE_OUT" | grep -q '추출이 깨졌' && echo 1)" "B4 추출 실패임을 밝힌다"

# 세 상태가 서로 다른 코드로 나오는가
if have_tag v1.18.0 && have_tag v1.19.0; then
  run_gate v1.19.0 v1.19.0 v1.19.1; RC_OK=$GATE_RC
  run_gate v1.18.0 v1.19.0 v1.19.0;  RC_NEED=$GATE_RC
  run_gate "" HEAD v9.9.9;           RC_BLIND=$GATE_RC
  check "$([[ "$RC_OK" != "$RC_NEED" && "$RC_NEED" != "$RC_BLIND" && "$RC_OK" != "$RC_BLIND" ]] && echo 1)" \
        "B5 통과·통지필요·대조불가가 서로 다른 종료 코드 ($RC_OK/$RC_NEED/$RC_BLIND)"
else
  ok "B5 건너뜀"
fi

# ── C. 우회 경로는 '변화 없음' 이 아니라 '미확인' 이어야 한다 ────────
run_gate "" HEAD v9.9.9 release   # NOTIFY_GATE 미설정 → 중단
RC_A=$GATE_RC
GATE_OUT="$(cd "$REPO_ROOT" && PREV="" TARGET=HEAD TAG=v9.9.9 MODE=release NOTIFY_GATE=off \
  bash -c 'set -uo pipefail; . "$0"' "$GATE_FILE" 2>&1)"; RC_B=$?
check "$([[ "$RC_A" == "2" && "$RC_B" == "0" ]] && echo 1)" "C1 NOTIFY_GATE=off 로만 우회된다"
check "$(echo "$GATE_OUT" | grep -q '미확인' && echo 1)" "C2 우회 시 '미확인' 이라고 말한다"
check "$(echo "$GATE_OUT" | grep -q "'변화 없음' 이 아닙니다" && echo 1)" \
      "C3 우회를 '변화 없음' 으로 읽지 말라고 명시한다"

# NOTIFIED=1 은 통지 필요 상태를 통과시킨다
if have_tag v1.18.0 && have_tag v1.19.0; then
  GATE_OUT="$(cd "$REPO_ROOT" && PREV=v1.18.0 TARGET=v1.19.0 TAG=v1.19.0 MODE=release NOTIFIED=1 \
    bash -c 'set -uo pipefail; . "$0"' "$GATE_FILE" 2>&1)"; RC=$?
  check "$([[ "$RC" == "0" ]] && echo 1)" "C4 NOTIFIED=1 이면 통지 필요 상태를 지나간다"
  check "$(echo "$GATE_OUT" | grep -q 'HANDOFF_ACCESS=kms' && echo 1)" \
        "C5 NOTIFIED=1 이어도 무엇이 바뀌었는지는 여전히 출력한다"
  # NOTIFIED 는 통지 필요만 통과시킨다 — 대조 불가는 통과시키면 안 된다
  GATE_OUT="$(cd "$REPO_ROOT" && PREV="" TARGET=HEAD TAG=v9.9.9 MODE=release NOTIFIED=1 \
    bash -c 'set -uo pipefail; . "$0"' "$GATE_FILE" 2>&1)"; RC=$?
  check "$([[ "$RC" == "2" ]] && echo 1)" "C6 NOTIFIED=1 은 **대조 불가를 통과시키지 않는다**"
else
  ok "C4 건너뜀"; ok "C5 건너뜀"; ok "C6 건너뜀"
fi

# ── D. publish 모드는 새 내용이 없다 — 건너뛰되 조용하지 않게 ────────
run_gate "" "HEAD" "v1.19.0" publish
check "$([[ "$GATE_RC" == "0" ]] && echo 1)" "D1 --publish-only 는 게이트를 건너뛴다"
check "$(echo "$GATE_OUT" | grep -q '건너' && echo 1)" "D2 건너뛴 사실을 출력한다 (조용히 통과하지 않는다)"

# ── E. 추출 패턴 자체 ────────────────────────────────────────────────
# 패턴을 테스트에 **복사하지 않는다.** 복사본은 원본과 갈리고, 갈린 줄도 모른다.
# MODE=publish 로 소싱하면 게이트 본체는 한 줄 출력하고 끝나지만 함수는 정의된다.
eval "$(cd "$REPO_ROOT" && MODE=publish bash -c '. "$0" >/dev/null 2>&1; declare -f _rel_headers _rel_tokens; declare -p _REL_EMOJI_PAT _REL_TOKEN_PAT' "$GATE_FILE")"

cd "$REPO_ROOT" || exit 1

# **작업 트리를 본다 — HEAD 가 아니다.**
# HEAD 만 보면 아직 커밋되지 않은 값은 보이지 않는다. 그러면 계약 위반이
# **릴리스된 뒤에야** 잡힌다 — 실제로 v1.21.0 이 `console` ⊂ `store_console_session`
# 위반을 그대로 내보냈고, 다음 사이클에서야 드러났다(2026-09-20).
# 커밋 전에 걸려야 게이트다.
_wt_tokens()  { LC_ALL=C grep -rhoE "$_REL_TOKEN_PAT" aiops/skills aiops/agents 2>/dev/null | LC_ALL=C sort -u; }
_wt_headers() { LC_ALL=C grep -rhoE "$_REL_EMOJI_PAT" aiops/skills aiops/agents 2>/dev/null \
                  | sed 's/[[:space:]]*$//' | LC_ALL=C sort -u; }

HDR_N=$(_wt_headers | grep -c . || true)
TOK_N=$(_wt_tokens  | grep -c . || true)

# HEAD 와 작업 트리가 갈리면 그 사실을 보여준다 — 무엇을 검사했는지 사람이 알아야 한다
HDR_HEAD=$(_rel_headers HEAD | grep -c . || true)
TOK_HEAD=$(_rel_tokens  HEAD | grep -c . || true)
[[ "$HDR_N" != "$HDR_HEAD" || "$TOK_N" != "$TOK_HEAD" ]] && \
  echo "# 작업 트리(토큰 $TOK_N · 헤더 $HDR_N) ≠ HEAD(토큰 $TOK_HEAD · 헤더 $HDR_HEAD) — 작업 트리로 검사합니다"

# 이모지 선두만 골라야 한다. '비ASCII' 로 잡으면 한글 절 제목이 섞인다(실측 379종).
check "$([[ "$HDR_N" -gt 10 && "$HDR_N" -lt 100 ]] && echo 1)" \
      "E1 마커 헤더가 이모지 선두만 잡힌다 (${HDR_N}종 — 수백 종이면 절 제목이 섞인 것)"
check "$([[ "$TOK_N" -ge 10 ]] && echo 1)" "E2 토큰 추출이 비어 있지 않다 (${TOK_N}종)"

# 한글 절 제목이 섞이지 않았는지 직접 확인한다 — 개수만으로는 종류를 모른다
check "$(_wt_headers | grep -qv '^## ' && echo 0 || echo 1)" "E3 추출된 헤더가 모두 '## ' 로 시작한다"
check "$(_wt_headers | grep -q '§' && echo 0 || echo 1)" "E4 § 절 제목이 섞이지 않았다"
check "$(_wt_headers | grep -q '📝' && echo 1)" "E5 계약이 예로 든 이모지 마커가 실제로 잡힌다"

# 계약 제약: 새 값이 기존 값의 부분 문자열이면 앵커 없는 grep 이 오판한다
DUP=$(_wt_tokens | grep '^HANDOFF_' | sed 's/^[A-Z_]*=//' | LC_ALL=C sort -u | awk '
        {v[NR]=$0} END{for(i=1;i<=NR;i++)for(j=1;j<=NR;j++) if(i!=j && index(v[j],v[i])) print v[i]" in "v[j]}')
check "$([[ -z "$DUP" ]] && echo 1)" "E6 HANDOFF 값끼리 부분 문자열 포함 없음 ${DUP:+($DUP)}"

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
