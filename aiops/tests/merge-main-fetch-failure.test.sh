#!/usr/bin/env bash
# merge-main-fetch-failure.test.sh — /aiops:merge-main §4.1 이슈 댓글 조회
# aiops/skills/merge-main/SKILL.md 의 `merge-main:comments-fetch` 앵커를 검증한다.
#
# 핵심은 **조회 실패("검사 못 함")와 댓글 0건("검사했더니 없음")의 구분**이다.
# 종료 코드를 버리면 둘이 같아지고, e2e_required_for_merge_main 기본값(false)에서
# forge 장애·인증 만료 때 검증 없이 dev → main 머지가 진행된다.
# (app-ads §6-1 과 같은 결함 계열 — zen-koi 지적, 2026-09-20)
#
# 순수 bash(3.2 호환). aiops/tests/setup-platform-detect.test.sh 규약을 따른다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MM_SKILL="$REPO_ROOT/aiops/skills/merge-main/SKILL.md"
FETCH_ANCHOR="merge-main:comments-fetch"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/mm-fetch-test.XXXXXX")"
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

FETCH_CODE="$(extract_block "$MM_SKILL" "$FETCH_ANCHOR")"
if [[ -z "$FETCH_CODE" ]]; then
  notok "앵커 사이 코드 추출 실패 — merge-main/SKILL.md 의 $FETCH_ANCHOR 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"; exit 1
fi

# forge.sh 스텁을 만들어 조회 성공/실패를 흉내 낸다.
# $1=rc, $2=stdout 내용
make_stub() {
  local dir="$TMPBASE/stub_$RANDOM$RANDOM/scripts"
  mkdir -p "$dir"
  cat > "$dir/forge.sh" <<STUB
#!/usr/bin/env bash
printf '%s' "$2"
[ -n "$2" ] || true
exit $1
STUB
  chmod +x "$dir/forge.sh"
  echo "${dir%/scripts}"
}

# 앵커 코드를 실행한다. _block_and_exit 는 호출되면 rc=9 로 표시하고 멈춘다.
run_fetch() {   # $1=CLAUDE_PLUGIN_ROOT
  RUN_OUT="$(
    CLAUDE_PLUGIN_ROOT="$1" RECENT_ISSUE=42 bash -c '
      _block_and_exit() { echo "BLOCKED reason=$1"; exit 9; }
      eval "$FETCH_CODE"
      echo "PROCEEDED comments=[$ISSUE_COMMENTS] rc=$MM_FETCH_RC"
    ' 2>&1
  )"
  RUN_RC=$?
}
export FETCH_CODE

# ══════════════════════════════════════════════════════════════════
# M1 — 조회 실패(rc≠0)는 차단한다. 이것이 이 수정의 핵심이다.
# ══════════════════════════════════════════════════════════════════
root="$(make_stub 1 "")"
run_fetch "$root"
check "$([[ "$RUN_RC" == "9" ]] && echo 1 || echo 0)" \
      "M1 조회 실패(rc=1) → 차단 (실제 rc=$RUN_RC)"
check "$(printf '%s' "$RUN_OUT" | grep -q 'reason=comments_fetch_failed' && echo 1 || echo 0)" \
      "M1 사유 코드가 comments_fetch_failed"
check "$(printf '%s' "$RUN_OUT" | grep -q '검사를 수행하지 못했습니다' && echo 1 || echo 0)" \
      "M1 '검사 못 함' 을 명시적으로 알림"

# ══════════════════════════════════════════════════════════════════
# M2 — 조회 성공 + 댓글 0건은 통과시킨다(뒤의 §4.1 빈 검사가 처리)
#      "검사했더니 없음" 은 이 앵커의 차단 대상이 아니다.
# ══════════════════════════════════════════════════════════════════
root="$(make_stub 0 "")"
run_fetch "$root"
check "$([[ "$RUN_RC" == "0" ]] && echo 1 || echo 0)" \
      "M2 조회 성공·댓글 0건 → 이 앵커는 차단하지 않음 (실제 rc=$RUN_RC)"
check "$(printf '%s' "$RUN_OUT" | grep -q 'PROCEEDED' && echo 1 || echo 0)" \
      "M2 다음 단계로 진행"

# ══════════════════════════════════════════════════════════════════
# M3 — 조회 성공 + 댓글 있음은 내용을 그대로 넘긴다
# ══════════════════════════════════════════════════════════════════
root="$(make_stub 0 "E2E_RESULT=PASS")"
run_fetch "$root"
check "$([[ "$RUN_RC" == "0" ]] && echo 1 || echo 0)" "M3 조회 성공·댓글 있음 → 진행"
check "$(printf '%s' "$RUN_OUT" | grep -q 'comments=\[E2E_RESULT=PASS\]' && echo 1 || echo 0)" \
      "M3 댓글 내용이 ISSUE_COMMENTS 에 전달"

# ══════════════════════════════════════════════════════════════════
# M4 — 실패와 0건이 서로 다른 결과를 낸다 (이 수정의 존재 이유)
# ══════════════════════════════════════════════════════════════════
root="$(make_stub 1 "")"; run_fetch "$root"; rc_fail=$RUN_RC
root="$(make_stub 0 "")"; run_fetch "$root"; rc_empty=$RUN_RC
check "$([[ "$rc_fail" != "$rc_empty" ]] && echo 1 || echo 0)" \
      "M4 조회 실패($rc_fail) 와 댓글 0건($rc_empty) 의 결과가 다름"

# ══════════════════════════════════════════════════════════════════
# M5 — 종료 코드를 버리지 않는다 (2>/dev/null 로 삼키던 회귀 방지)
# ══════════════════════════════════════════════════════════════════
check "$(printf '%s' "$FETCH_CODE" | grep -q 'MM_FETCH_RC=\$?' && echo 1 || echo 0)" \
      "M5 forge.sh 호출 직후 종료 코드를 담는다"
check "$(printf '%s' "$FETCH_CODE" | grep -qE 'issue-comments[^|]*2>/dev/null' && echo 0 || echo 1)" \
      "M5 issue-comments 호출이 stderr 를 /dev/null 로 버리지 않는다"

# ══════════════════════════════════════════════════════════════════
# M6 — 완화 모드에서도 차단한다는 것이 코드·문서에 명시돼 있다
# ══════════════════════════════════════════════════════════════════
check "$(grep -q 'comments_fetch_failed' "$MM_SKILL" && echo 1 || echo 0)" \
      "M6 §9 사유 매트릭스에 comments_fetch_failed 등재"
check "$(printf '%s' "$FETCH_CODE" | grep -q 'e2e_required_for_merge_main' && echo 1 || echo 0)" \
      "M6 완화 모드와 무관하게 차단함을 코드 주석에 명시"

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]] && exit 0 || exit 1
