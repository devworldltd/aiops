#!/usr/bin/env bash
# forge-arg-validation.test.sh — forge.sh 가 잘못된 인자를 **조용히 받아들이지 않는지** 검증.
# ai-chat 이슈 #3 대응.
#
# 막으려는 사고: `issue-comment <n> --body-file x.md` 가 body="--body-file" 로 **등록되고**
#   정상 COMMENT_ID 를 돌려줬다. 한 번의 devflow 에서 서로 다른 에이전트 4명이 같은 함정에
#   빠졌고 넷 다 "등록 완료" 로 보고했다. 사람은 결과를 눈으로 보지만 자동화는 종료 코드와
#   반환 ID 만 본다 — 틀린 호출이 0 으로 끝나면 검증할 방법이 없다.
#
# 그래서 이 하니스의 핵심 단언은 두 가지다:
#   (1) 종료 코드가 0 이 아니다
#   (2) **쓰기 호출(POST/PATCH)이 0건이다** — 거부했다면 아무것도 등록되지 않아야 한다
#
# 순수 bash(3.2 호환). 네트워크는 전부 스텁. 실제 forge 에 아무 요청도 보내지 않는다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FORGE="$REPO_ROOT/aiops/scripts/forge.sh"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/forge-arg-validation.XXXXXX")"
WS="$TMPBASE/ws"; STUBBIN="$TMPBASE/bin"; STUB_LOG="$TMPBASE/log"
export STUB_LOG
cleanup() { rm -rf "$TMPBASE"; }
trap cleanup EXIT
mkdir -p "$WS" "$STUBBIN" "$STUB_LOG"

# ── 스텁 curl: 메서드+URL 만 기록하고 고정 응답 ──────────────────────
cat > "$STUBBIN/curl" <<'CURL_STUB'
#!/usr/bin/env bash
set -u
args=("$@"); n=${#args[@]}; url="${args[$((n-1))]}"
method="GET"; i=0
while (( i < n )); do
  case "${args[$i]}" in -X) method="${args[$((i+1))]:-GET}"; i=$((i+2));; *) i=$((i+1));; esac
done
printf '%s %s\n' "$method" "$url" >> "${STUB_LOG}/curl.calls"
case "$url" in
  */api/v1/version) echo '{"version":"1.22.0"}';;
  *) echo '{"id":99999,"number":42,"state":"open"}';;
esac
exit 0
CURL_STUB

cat > "$STUBBIN/git" <<'GIT_STUB'
#!/usr/bin/env bash
set -u
case "$1 ${2:-}" in
  "remote get-url") echo "https://git.example.test/acme/demo.git";;
  "credential fill") echo "password=stub-token";;
  "config --global") exit 1;;
  *) exit 0;;
esac
GIT_STUB
chmod +x "$STUBBIN/curl" "$STUBBIN/git"

TOTAL=0; PASS=0; FAIL=0
check() { # check <0|1> <설명>
  TOTAL=$((TOTAL+1))
  if [[ "$1" == "1" ]]; then PASS=$((PASS+1)); echo "ok $TOTAL - $2"
  else FAIL=$((FAIL+1)); echo "not ok $TOTAL - $2"; fi
}

LAST_RC=0; LAST_ERR=""
run_forge() { # run_forge <서브커맨드 인자...>
  : > "$STUB_LOG/curl.calls"
  LAST_ERR=$(cd "$WS" && PATH="$STUBBIN:$PATH" bash "$FORGE" "$@" 2>&1 >/dev/null)
  LAST_RC=$?
}
write_calls() { grep -cE '^(POST|PATCH|PUT) ' "$STUB_LOG/curl.calls" 2>/dev/null | tr -d ' '; }

# ── A. 위치 인자 자리에 옵션이 오면 거부한다 ────────────────────────
#    등록 0건이어야 한다 — 이게 이 이슈의 본질이다.
for case_args in \
  "issue-comment 1 --body-file" \
  "issue-create --title x" \
  "issue-close --comment" \
  "pr-review 1 --approve body" \
  "issue-search --state"
do
  set -- $case_args
  run_forge "$@"
  sub="$1"
  check "$([[ "$LAST_RC" != "0" ]] && echo 1 || echo 0)" "A: '$case_args' → 종료 코드 0 아님 (실측 $LAST_RC)"
  check "$([[ "$(write_calls)" == "0" ]] && echo 1 || echo 0)" "A: '$case_args' → 쓰기 호출 0건 (실측 $(write_calls)건)"
done

# ── B. 모르는 플래그를 조용히 삼키지 않는다 ─────────────────────────
run_forge issue-create "제목" "본문" --lable bug
check "$([[ "$LAST_RC" != "0" ]] && echo 1 || echo 0)" "B: issue-create 의 오타 플래그(--lable) → 실패 (실측 $LAST_RC)"
check "$([[ "$LAST_ERR" == *"알 수 없는 옵션"* ]] && echo 1 || echo 0)" "B: stderr 에 '알 수 없는 옵션' 안내"
check "$([[ "$(write_calls)" == "0" ]] && echo 1 || echo 0)" "B: 오타 플래그 → 쓰기 호출 0건"

run_forge issue-list --stat open
check "$([[ "$LAST_RC" != "0" ]] && echo 1 || echo 0)" "B: issue-list 의 오타 플래그(--stat) → 실패"

# ── C. 의도된 위치 플래그는 그대로 통과한다 (회귀 방지) ─────────────
#    pr-diff --name-only · pr-merge --delete-branch 를 막아버리면 기존 호출이 전부 깨진다.
run_forge pr-diff 61 --name-only
check "$([[ "$LAST_ERR" != *"알 수 없는 옵션"* ]] && echo 1 || echo 0)" "C: pr-diff --name-only 는 거부되지 않는다"
run_forge pr-merge 61 --delete-branch
check "$([[ "$LAST_ERR" != *"알 수 없는 옵션"* ]] && echo 1 || echo 0)" "C: pr-merge --delete-branch 는 거부되지 않는다"

# ── D. 그 자리에 다른 옵션이 오면 거부한다 ──────────────────────────
run_forge pr-diff 61 --name-onlyy
check "$([[ "$LAST_RC" != "0" ]] && echo 1 || echo 0)" "D: pr-diff 의 오타(--name-onlyy) → 실패 (실측 $LAST_RC)"
run_forge pr-merge 61 --squash
check "$([[ "$LAST_RC" != "0" ]] && echo 1 || echo 0)" "D: pr-merge 의 미지원 옵션(--squash) → 실패"
check "$([[ "$(write_calls)" == "0" ]] && echo 1 || echo 0)" "D: 미지원 머지 옵션 → 쓰기 호출 0건"

# ── E. 정상 호출은 여전히 동작한다 (가드가 과잉 차단하지 않는지) ────
run_forge issue-comment 1 "정상 본문입니다"
check "$([[ "$LAST_ERR" != *"옵션처럼 보이는"* ]] && echo 1 || echo 0)" "E: 평범한 본문은 거부되지 않는다"
run_forge issue-comment 1 "중간에 - 하이픈이 있는 문장"
check "$([[ "$LAST_ERR" != *"옵션처럼 보이는"* ]] && echo 1 || echo 0)" "E: 하이픈이 중간에 있는 본문은 거부되지 않는다"
# 마크다운 목록으로 시작하는 본문은 흔하다 — `-*` 만으로 거부하면 멀쩡한 호출이 막힌다.
run_forge issue-comment 1 "- 첫 항목
- 둘째 항목"
check "$([[ "$LAST_ERR" != *"옵션처럼 보이는"* ]] && echo 1 || echo 0)" "E: 마크다운 목록(- 항목)으로 시작하는 본문은 거부되지 않는다"
check "$([[ "$LAST_RC" == "0" ]] && echo 1 || echo 0)" "E: 마크다운 목록 본문은 정상 등록된다 (실측 $LAST_RC)"

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
