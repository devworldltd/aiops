#!/usr/bin/env bash
# release-tag-or-skip.test.sh — tools/release.sh 의 태그 생성·건너뜀 분기
# `release:tag-or-skip` 앵커를 검증한다.
#
# 핵심은 **하지 않은 일을 했다고 보고하지 않는 것**이다.
# --publish-only 는 사내 태그를 만들지도 latest 를 옮기지도 않는데,
# 완료 메시지가 분기 바깥에 있으면 둘 다 했다고 출력한다.
# (이 스크립트가 2026-09-16 사고 이후 없애 온 것과 같은 부류)
#
# 순수 bash(3.2 호환). aiops/tests/setup-platform-detect.test.sh 규약을 따른다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RELEASE_SH="$REPO_ROOT/tools/release.sh"
ANCHOR="release:tag-or-skip"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/release-tag-test.XXXXXX")"
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

CODE="$(extract_block "$RELEASE_SH" "$ANCHOR")"
if [[ -z "$CODE" ]]; then
  notok "앵커 사이 코드 추출 실패 — tools/release.sh 의 $ANCHOR 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"; exit 1
fi

# git 스텁 — 실제 태그·push 를 하지 않고 호출만 기록한다.
STUB_DIR="$TMPBASE/bin"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/git" <<'STUB'
#!/usr/bin/env bash
echo "GIT $*" >> "$GIT_CALLS"
case "$1" in
  rev-parse) echo "abc1234" ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/git"

run_mode() {   # $1=MODE
  GIT_CALLS="$TMPBASE/calls_$1_$RANDOM"; : > "$GIT_CALLS"
  export GIT_CALLS
  OUT="$(PATH="$STUB_DIR:$PATH" MODE="$1" TAG="v9.9.9" bash -c 'eval "$CODE"' 2>&1)"
  RC=$?
  CALLS="$(cat "$GIT_CALLS")"
}
export CODE

# ══════════════════════════════════════════════════════════════════
# R1 — 일반 모드: 태그를 만들고 latest 를 옮기고, 그렇게 보고한다
# ══════════════════════════════════════════════════════════════════
run_mode "tag"
check "$(printf '%s' "$CALLS" | grep -q 'GIT tag -a v9.9.9' && echo 1 || echo 0)" \
      "R1 일반 모드 — 태그 생성 호출"
check "$(printf '%s' "$CALLS" | grep -q 'GIT push origin v9.9.9' && echo 1 || echo 0)" \
      "R1 일반 모드 — 태그 push 호출"
check "$(printf '%s' "$CALLS" | grep -q 'GIT push -f origin latest' && echo 1 || echo 0)" \
      "R1 일반 모드 — latest 이동 push 호출"
check "$(printf '%s' "$OUT" | grep -q '생성 · latest' && echo 1 || echo 0)" \
      "R1 일반 모드 — 생성·이동 완료를 보고"

# ══════════════════════════════════════════════════════════════════
# R2 — publish 모드: 아무것도 만들지 않는다
# ══════════════════════════════════════════════════════════════════
run_mode "publish"
check "$(printf '%s' "$CALLS" | grep -q 'GIT tag' && echo 0 || echo 1)" \
      "R2 publish 모드 — 태그를 만들지 않음"
check "$(printf '%s' "$CALLS" | grep -q 'GIT push' && echo 0 || echo 1)" \
      "R2 publish 모드 — push 하지 않음"

# ══════════════════════════════════════════════════════════════════
# R3 — publish 모드: 하지 않은 일을 했다고 보고하지 않는다 (이 수정의 핵심)
# ══════════════════════════════════════════════════════════════════
check "$(printf '%s' "$OUT" | grep -q '생성 · latest' && echo 0 || echo 1)" \
      "R3 publish 모드 — '생성 · latest 이동 완료' 를 출력하지 않음"
check "$(printf '%s' "$OUT" | grep -q '건드리지 않았습니다' && echo 1 || echo 0)" \
      "R3 publish 모드 — 건드리지 않았음을 명시"
check "$(printf '%s' "$OUT" | grep -q '사내 태그 생성 건너뜀' && echo 1 || echo 0)" \
      "R3 publish 모드 — 건너뛴 사실을 알림"

# ══════════════════════════════════════════════════════════════════
# R4 — 두 모드의 출력이 서로 다르다
# ══════════════════════════════════════════════════════════════════
run_mode "tag";     out_tag="$OUT"
run_mode "publish"; out_pub="$OUT"
check "$([[ "$out_tag" != "$out_pub" ]] && echo 1 || echo 0)" \
      "R4 일반 모드와 publish 모드의 출력이 다름"

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]] && exit 0 || exit 1
