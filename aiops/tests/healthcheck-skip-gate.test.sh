#!/usr/bin/env bash
# healthcheck-skip-gate.test.sh — 이슈 #42 "배포 대상 없는 프로젝트의 헬스체크 스킵"
# aiops/skills/{merge-pr,verify-deploy,deploy-prod}/SKILL.md 의
# `<skill>:healthcheck-gate` 앵커 3종과 merge-main/SKILL.md 의 차단·면제 분기,
# setup/SKILL.md 의 정적 안내 문구를 함께 검증한다.
#
# 순수 bash(3.2 호환). aiops/tests/setup-platform-detect.test.sh 규약을 그대로 따른다:
#   - 케이스별 `ok N - <설명>` / `not ok N - <설명>`
#   - 마지막 줄 `TESTS=<총> PASS=<n> FAIL=<n>`
#   - 종료 코드: 전건 통과 0, 1건 이상 실패 1
#
# 판정 로직을 재구현하지 않는다 — SKILL.md 의 앵커 사이 코드를 awk 로 그대로
# 추출해 픽스처 디렉터리에서 eval 한다(문서-코드 일치 강제). 네트워크 호출 없음.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MP_SKILL="$REPO_ROOT/aiops/skills/merge-pr/SKILL.md"
VD_SKILL="$REPO_ROOT/aiops/skills/verify-deploy/SKILL.md"
DP_SKILL="$REPO_ROOT/aiops/skills/deploy-prod/SKILL.md"
MM_SKILL="$REPO_ROOT/aiops/skills/merge-main/SKILL.md"

MP_ANCHOR="merge-pr:healthcheck-gate"
VD_ANCHOR="verify-deploy:healthcheck-gate"
DP_ANCHOR="deploy-prod:healthcheck-gate"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/healthcheck-skip-gate-test.XXXXXX")"
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

MP_CODE="$(extract_block "$MP_SKILL" "$MP_ANCHOR")"
VD_CODE="$(extract_block "$VD_SKILL" "$VD_ANCHOR")"
DP_CODE="$(extract_block "$DP_SKILL" "$DP_ANCHOR")"

for pair in "MP_CODE:$MP_ANCHOR (merge-pr)" "VD_CODE:$VD_ANCHOR (verify-deploy)" "DP_CODE:$DP_ANCHOR (deploy-prod)"; do
  var="${pair%%:*}"; label="${pair#*:}"
  val="$(eval "printf '%s' \"\${$var}\"")"
  if [[ -z "$val" ]]; then
    notok "앵커 사이 코드 추출 실패 — $label 앵커 확인 필요"
    echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
    exit 1
  fi
done

# ══════════════════════════════════════════════════════════════════
# T-1~T-3 — 3스킬 앵커 추출: 비어있지 않음 + 앵커명 제외 시 동일 바이트
# ══════════════════════════════════════════════════════════════════
check "$([[ -n "$MP_CODE" ]] && echo 1 || echo 0)" "T-1 merge-pr 앵커 추출 결과 비어있지 않음"
check "$([[ -n "$VD_CODE" ]] && echo 1 || echo 0)" "T-2 verify-deploy 앵커 추출 결과 비어있지 않음"
check "$([[ -n "$DP_CODE" ]] && echo 1 || echo 0)" "T-3 deploy-prod 앵커 추출 결과 비어있지 않음"
check "$([[ "$MP_CODE" == "$VD_CODE" ]] && echo 1 || echo 0)" "T-1~T-3 merge-pr == verify-deploy 앵커 내부 코드 동일 바이트"
check "$([[ "$MP_CODE" == "$DP_CODE" ]] && echo 1 || echo 0)" "T-1~T-3 merge-pr == deploy-prod 앵커 내부 코드 동일 바이트"

# ── 픽스처 헬퍼 ──────────────────────────────────────────────────────
new_ws() {
  local ws="$TMPBASE/ws_$RANDOM$RANDOM"
  mkdir -p "$ws/.claude" "$ws/.reviewer"
  echo "$ws"
}

write_config_raw() {   # $1=ws $2=config.json 내용(원문)
  printf '%s' "$2" > "$1/.claude/config.json"
}

write_config_platform() {   # $1=ws $2=platform 값
  write_config_raw "$1" "{\"agent_hints\":{\"platform\":\"$2\"}}"
}

write_profile_platform() {   # $1=ws $2=platform 값
  printf 'stack:\n  frontend: none\nplatform: %s\n' "$2" > "$1/.reviewer/profile.yaml"
}

rm_config() { rm -f "$1/.claude/config.json"; }
rm_profile() { rm -f "$1/.reviewer/profile.yaml"; }

# 앵커 코드를 픽스처 디렉터리에서 실행하고 HC_SKIP/HC_SKIP_REASON/HC_PLATFORM 을 캡처한다.
run_gate() {   # $1=CODE변수명(MP_CODE|VD_CODE|DP_CODE) $2=ws $3=HC_URL_ASSEMBLED
  local codevar="$1" ws="$2" url="${3:-}"
  local code; code="$(eval "printf '%s' \"\${$codevar}\"")"
  local full
  full="$code"$'\n''echo "__GATE_SKIP=$HC_SKIP"; echo "__GATE_REASON=$HC_SKIP_REASON"; echo "__GATE_PLATFORM=$HC_PLATFORM"'
  GATE_OUT="$( (cd "$ws" && HC_URL_ASSEMBLED="$url" eval "$full") 2>&1 )"
  GATE_RC=$?
  GATE_SKIP="$(printf '%s\n' "$GATE_OUT" | grep -o '__GATE_SKIP=[a-z]*' | tail -1 | cut -d= -f2)"
  GATE_REASON="$(printf '%s\n' "$GATE_OUT" | grep -o '__GATE_REASON=[a-z_]*' | tail -1 | cut -d= -f2)"
  GATE_PLATFORM="$(printf '%s\n' "$GATE_OUT" | grep -o '__GATE_PLATFORM=[a-z]*' | tail -1 | cut -d= -f2)"
}

# ══════════════════════════════════════════════════════════════════
# T-4~T-7 — merge-pr 4조합
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); write_config_platform "$ws" "cli"
run_gate MP_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "true" && "$GATE_REASON" == "platform_cli" ]] && echo 1 || echo 0)" "T-4 merge-pr: platform=cli + URL없음 → HC_SKIP=true/platform_cli"

ws=$(new_ws); write_config_platform "$ws" "cli"
run_gate MP_CODE "$ws" "https://x.dev"
check "$([[ "$GATE_SKIP" == "false" ]] && echo 1 || echo 0)" "T-5 merge-pr: platform=cli + URL있음 → HC_SKIP=false(검사)"

ws=$(new_ws); write_config_platform "$ws" "web"
run_gate MP_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "false" ]] && echo 1 || echo 0)" "T-6 merge-pr: platform=web + URL없음 → HC_SKIP=false(종전 차단)"

ws=$(new_ws); write_config_platform "$ws" "web"
run_gate MP_CODE "$ws" "https://x.dev"
check "$([[ "$GATE_SKIP" == "false" ]] && echo 1 || echo 0)" "T-7 merge-pr: platform=web + URL있음 → HC_SKIP=false"

# ══════════════════════════════════════════════════════════════════
# T-8~T-11 — verify-deploy 동일 4조합
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); write_config_platform "$ws" "cli"
run_gate VD_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "true" && "$GATE_REASON" == "platform_cli" ]] && echo 1 || echo 0)" "T-8 verify-deploy: platform=cli + URL없음 → SKIP"

ws=$(new_ws); write_config_platform "$ws" "cli"
run_gate VD_CODE "$ws" "https://x.dev"
check "$([[ "$GATE_SKIP" == "false" ]] && echo 1 || echo 0)" "T-9 verify-deploy: platform=cli + URL있음 → CHECK"

ws=$(new_ws); write_config_platform "$ws" "web"
run_gate VD_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "false" ]] && echo 1 || echo 0)" "T-10 verify-deploy: platform=web + URL없음 → CHECK(종전)"

ws=$(new_ws); write_config_platform "$ws" "web"
run_gate VD_CODE "$ws" "https://x.dev"
check "$([[ "$GATE_SKIP" == "false" ]] && echo 1 || echo 0)" "T-11 verify-deploy: platform=web + URL있음 → CHECK"

# ══════════════════════════════════════════════════════════════════
# T-12~T-14 — deploy-prod (cli+없음 / cli+있음 / web+없음)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); write_config_platform "$ws" "cli"
run_gate DP_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "true" && "$GATE_REASON" == "platform_cli" ]] && echo 1 || echo 0)" "T-12 deploy-prod: platform=cli + URL없음 → SKIP"

ws=$(new_ws); write_config_platform "$ws" "cli"
run_gate DP_CODE "$ws" "https://x.example.com"
check "$([[ "$GATE_SKIP" == "false" ]] && echo 1 || echo 0)" "T-13 deploy-prod: platform=cli + URL있음 → CHECK"

ws=$(new_ws); write_config_platform "$ws" "web"
run_gate DP_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "false" ]] && echo 1 || echo 0)" "T-14 deploy-prod: platform=web + URL없음 → CHECK(종전)"

# ══════════════════════════════════════════════════════════════════
# T-15 · T-16 — 헤더 정규식 상호 비매치
# ══════════════════════════════════════════════════════════════════
HC_SKIP_HEADER='## ℹ️ 헬스체크 스킵'
E2E_SKIP_HEADER='## ℹ️ Dev E2E 자동 실행 스킵'
HC_RE='^## ℹ️ 헬스체크 스킵$'
E2E_RE='^## ℹ️ Dev E2E 자동 실행 스킵$'

m1="$(printf '%s\n' "$E2E_SKIP_HEADER" | grep -cE "$HC_RE" || true)"
check "$([[ "${m1:-0}" -eq 0 ]] && echo 1 || echo 0)" "T-15 '$HC_RE' 는 '$E2E_SKIP_HEADER' 에 매치하지 않음(0건)"

m2="$(printf '%s\n' "$HC_SKIP_HEADER" | grep -cE "$E2E_RE" || true)"
check "$([[ "${m2:-0}" -eq 0 ]] && echo 1 || echo 0)" "T-16 '$E2E_RE' 는 '$HC_SKIP_HEADER' 에 매치하지 않음(0건, 양방향)"

# ══════════════════════════════════════════════════════════════════
# T-17~T-20 — merge-main 차단 4종 정규식이 신규 헤더/본문에 매치하지 않음
# ══════════════════════════════════════════════════════════════════
NEW_MARKER_BODY="## ℹ️ 헬스체크 스킵

healthcheck_skipped=platform_cli

- 환경: dev
- 스킬: /aiops:merge-pr §13"

BLOCK_RE_1='^## ❌ Dev E2E FAIL$'
BLOCK_RE_2='E2E_RESULT=FAIL'
BLOCK_RE_3='^## ⚠️ Dev E2E 환경 오류$'
BLOCK_RE_4='^## ⚠️ Dev 배포 검증 실패$'

c1="$(printf '%s\n' "$NEW_MARKER_BODY" | grep -cE "$BLOCK_RE_1" || true)"
check "$([[ "${c1:-0}" -eq 0 ]] && echo 1 || echo 0)" "T-17 차단 regex 1 '$BLOCK_RE_1' 은 신규 마커에 매치하지 않음"

c2="$(printf '%s\n' "$NEW_MARKER_BODY" | grep -c "$BLOCK_RE_2" || true)"
check "$([[ "${c2:-0}" -eq 0 ]] && echo 1 || echo 0)" "T-18 차단 regex 2 '$BLOCK_RE_2' 은 신규 마커에 매치하지 않음"

c3="$(printf '%s\n' "$NEW_MARKER_BODY" | grep -cE "$BLOCK_RE_3" || true)"
check "$([[ "${c3:-0}" -eq 0 ]] && echo 1 || echo 0)" "T-19 차단 regex 3 '$BLOCK_RE_3' 은 신규 마커에 매치하지 않음"

c4="$(printf '%s\n' "$NEW_MARKER_BODY" | grep -cE "$BLOCK_RE_4" || true)"
check "$([[ "${c4:-0}" -eq 0 ]] && echo 1 || echo 0)" "T-20 차단 regex 4 '$BLOCK_RE_4' 은 신규 마커에 매치하지 않음"

# ══════════════════════════════════════════════════════════════════
# T-21 — merge-main 차단 grep 4행 원문 그대로 존재(정적 가드, 무변경)
# ══════════════════════════════════════════════════════════════════
check "$(grep -qF "grep -cE '^## ❌ Dev E2E FAIL$'" "$MM_SKILL" && echo 1 || echo 0)" "T-21a merge-main 차단 grep 1 원문 존재"
check "$(grep -qF "grep -c 'E2E_RESULT=FAIL'" "$MM_SKILL" && echo 1 || echo 0)" "T-21b merge-main 차단 grep 2 원문 존재"
check "$(grep -qF "grep -cE '^## ⚠️ Dev E2E 환경 오류\$'" "$MM_SKILL" && echo 1 || echo 0)" "T-21c merge-main 차단 grep 3 원문 존재"
check "$(grep -qF "grep -cE '^## ⚠️ Dev 배포 검증 실패\$'" "$MM_SKILL" && echo 1 || echo 0)" "T-21d merge-main 차단 grep 4 원문 존재"

# ══════════════════════════════════════════════════════════════════
# T-22 — 부정: config·profile 둘 다 부재 → 크래시 없음(rc=0) · HC_SKIP=false
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); rm_config "$ws"; rm_profile "$ws"
run_gate MP_CODE "$ws" ""
check "$([[ "$GATE_RC" -eq 0 ]] && echo 1 || echo 0)" "T-22 config·profile 둘 다 부재 → 크래시 없음(rc=0)"
check "$([[ "$GATE_SKIP" == "false" ]] && echo 1 || echo 0)" "T-22 config·profile 둘 다 부재 → HC_SKIP=false(안전 기본값)"

# ══════════════════════════════════════════════════════════════════
# T-23 — 부정: config 부재 + profile.yaml platform: cli, URL없음 → HC_SKIP=true(폴백)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); rm_config "$ws"; write_profile_platform "$ws" "cli"
run_gate MP_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "true" ]] && echo 1 || echo 0)" "T-23 config 부재 + profile.yaml platform:cli → HC_SKIP=true(폴백 경로)"

# ══════════════════════════════════════════════════════════════════
# T-24 — 엣지: dev_url="   "(공백만) + platform=cli → HC_SKIP=true(트림 후 빈 값)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); write_config_platform "$ws" "cli"
run_gate MP_CODE "$ws" "   "
check "$([[ "$GATE_SKIP" == "true" ]] && echo 1 || echo 0)" "T-24 공백만 있는 URL + platform=cli → 트림 후 빈 값 취급 → HC_SKIP=true"

# ══════════════════════════════════════════════════════════════════
# T-25 — agent_hints.platform=cli + profile.yaml platform:web → agent_hints 우선 → HC_SKIP=true
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); write_config_platform "$ws" "cli"; write_profile_platform "$ws" "web"
run_gate MP_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "true" ]] && echo 1 || echo 0)" "T-25 config(cli) + profile.yaml(web) 동시 존재 → config 우선 → HC_SKIP=true"

# ══════════════════════════════════════════════════════════════════
# T-26 — jq 바이너리 부재(PATH 조작) + config platform=cli → 크래시 없이 HC_SKIP=false(web 취급)
# ══════════════════════════════════════════════════════════════════
FAKE_BIN="$TMPBASE/fakebin_nojq"
mkdir -p "$FAKE_BIN"
for tool in bash awk grep sed cat cut mkdir rm mktemp printf ls true false head; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [[ -n "$real" ]] && ln -sf "$real" "$FAKE_BIN/$tool" 2>/dev/null || true
done
ws=$(new_ws); write_config_platform "$ws" "cli"
NOJQ_CODE="$MP_CODE"$'\n''echo "__GATE_SKIP=$HC_SKIP"; echo "__GATE_RC=0"'
NOJQ_OUT="$( (cd "$ws" && PATH="$FAKE_BIN" HC_URL_ASSEMBLED="" eval "$NOJQ_CODE") 2>&1 )"
NOJQ_RC=$?
NOJQ_SKIP="$(printf '%s\n' "$NOJQ_OUT" | grep -o '__GATE_SKIP=[a-z]*' | tail -1 | cut -d= -f2)"
check "$([[ "$NOJQ_RC" -eq 0 ]] && echo 1 || echo 0)" "T-26 jq 부재(PATH 조작) → 크래시 없음(rc=0)"
check "$([[ "$NOJQ_SKIP" == "false" ]] && echo 1 || echo 0)" "T-26 jq 부재 → HC_PLATFORM 조회 실패로 HC_SKIP=false(안전 기본값, web 취급)"

# ══════════════════════════════════════════════════════════════════
# T-27 — URL 키 null / "" / 부재 3종, platform=cli → 3종 모두 HC_SKIP=true/platform_cli
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); write_config_raw "$ws" '{"agent_hints":{"platform":"cli"},"dev_url":null}'
run_gate MP_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "true" && "$GATE_REASON" == "platform_cli" ]] && echo 1 || echo 0)" "T-27a dev_url=null(조립 후 빈 값) + platform=cli → HC_SKIP=true"

ws=$(new_ws); write_config_raw "$ws" '{"agent_hints":{"platform":"cli"},"dev_url":""}'
run_gate MP_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "true" && "$GATE_REASON" == "platform_cli" ]] && echo 1 || echo 0)" "T-27b dev_url=\"\"(조립 후 빈 값) + platform=cli → HC_SKIP=true"

ws=$(new_ws); write_config_raw "$ws" '{"agent_hints":{"platform":"cli"}}'
run_gate MP_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "true" && "$GATE_REASON" == "platform_cli" ]] && echo 1 || echo 0)" "T-27c dev_url 키 자체 부재(조립 후 빈 값) + platform=cli → HC_SKIP=true"

# ══════════════════════════════════════════════════════════════════
# T-28 — platform 값이 cli도 web도 아닌 미지값 → HC_SKIP=false(web과 동일, cli 외 전부 CHECK)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); write_config_platform "$ws" "android"
run_gate MP_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "false" ]] && echo 1 || echo 0)" "T-28 platform=android(미지값) + URL없음 → HC_SKIP=false(종전 차단)"

ws=$(new_ws); write_config_platform "$ws" "other"
run_gate MP_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "false" ]] && echo 1 || echo 0)" "T-28 platform=other(미지값) + URL없음 → HC_SKIP=false(종전 차단)"

# ══════════════════════════════════════════════════════════════════
# T-29 — ${cf_dev_url} 치환 후 결과가 빈 문자열이면(원본 키 존재 무관) HC_SKIP=true
#   조립은 앵커 밖 로직이므로, 여기서는 "치환 완료 후 값" 기준으로 앵커가 판정함을
#   HC_URL_ASSEMBLED 에 이미 치환된 빈 문자열을 넘겨 검증한다.
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); write_config_platform "$ws" "cli"
# dev_url="${cf_dev_url}" 이고 cf_dev_url="" 이면 실제 skill 코드의 치환 결과는 빈 문자열이 된다.
run_gate MP_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "true" && "$GATE_REASON" == "platform_cli" ]] && echo 1 || echo 0)" "T-29 \${cf_dev_url} 치환 후 결과 빈 문자열(원본 키 존재 무관) → HC_SKIP=true"

# ══════════════════════════════════════════════════════════════════
# T-30 — deploy-prod --dry-run + platform=cli + URL없음 동시 → dry-run 무관하게 스킵 우선 판정
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); write_config_platform "$ws" "cli"
DRYRUN_CODE="$DP_CODE"$'\n''echo "__GATE_SKIP=$HC_SKIP"; echo "__GATE_REASON=$HC_SKIP_REASON"'
DRYRUN_OUT="$( (cd "$ws" && DRY_RUN=true HC_URL_ASSEMBLED="" eval "$DRYRUN_CODE") 2>&1 )"
DRYRUN_SKIP="$(printf '%s\n' "$DRYRUN_OUT" | grep -o '__GATE_SKIP=[a-z]*' | tail -1 | cut -d= -f2)"
DRYRUN_REASON="$(printf '%s\n' "$DRYRUN_OUT" | grep -o '__GATE_REASON=[a-z_]*' | tail -1 | cut -d= -f2)"
check "$([[ "$DRYRUN_SKIP" == "true" && "$DRYRUN_REASON" == "platform_cli" ]] && echo 1 || echo 0)" "T-30 deploy-prod DRY_RUN=true + platform=cli + URL없음 → dry-run 무관 HC_SKIP=true"
check "$(grep -qF '_post_marker_HC_SKIP() {' "$DP_SKILL" && echo 1 || echo 0)" "T-30 deploy-prod SKILL.md 에 _post_marker_HC_SKIP 함수 정의 존재"

# ══════════════════════════════════════════════════════════════════
# T-31 — merge-main: 스킵 마커 + 차단 마커(Dev E2E FAIL) 동시 존재 시 차단 우선
# ══════════════════════════════════════════════════════════════════
BOTH_MARKERS="## ❌ Dev E2E FAIL

E2E_RESULT=FAIL

## ℹ️ 헬스체크 스킵

healthcheck_skipped=platform_cli"

both_block_count="$(printf '%s\n' "$BOTH_MARKERS" | grep -cE "$BLOCK_RE_1" || true)"
check "$([[ "${both_block_count:-0}" -gt 0 ]] && echo 1 || echo 0)" "T-31 차단 마커+스킵 마커 동시 존재 시 차단 regex 는 여전히 매치(count>0) — 차단 우선"

# merge-main §4.4 elif 체인에서 차단 분기(HAS_E2E_FAIL 등)가 HAS_HC_SKIP 분기보다
# 코드상 먼저 오는지 정적으로 확인한다(if/elif 우선순위 = 차단 우선의 구조적 근거).
mm_block_line="$(grep -n 'HAS_E2E_FAIL.*-gt 0' "$MM_SKILL" | head -1 | cut -d: -f1)"
mm_hcskip_line="$(grep -n 'HAS_HC_SKIP.*-gt 0' "$MM_SKILL" | tail -1 | cut -d: -f1)"
check "$([[ -n "$mm_block_line" && -n "$mm_hcskip_line" && "$mm_block_line" -lt "$mm_hcskip_line" ]] && echo 1 || echo 0)" "T-31 merge-main §4.4: 차단 분기(HAS_E2E_FAIL)가 HC_SKIP 면제 분기보다 코드상 선행(elif 우선순위로 차단 우선 보장)"

# ══════════════════════════════════════════════════════════════════
# T-32 — verify-deploy --env=prod 전용: platform=cli + prod 계열 3키 전부 없음
#   dev 키 존재 여부와 무관해야 한다(변수 격리). HC_URL_ASSEMBLED 는 호출측에서
#   ENV=prod 일 때 prod 계열 키로만 조립되므로, dev_url 이 있어도 영향 없음을
#   "prod 조립 결과"만 앵커에 넘겨 검증한다.
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_config_raw "$ws" '{"agent_hints":{"platform":"cli"},"dev_url":"https://dev.example.com","cf_dev_url":"https://dev2.example.com","e2e_dev_url":"https://dev3.example.com"}'
# ENV=prod 이므로 실제 skill 은 prod_url/cf_prod_url/e2e_prod_url 만 읽어 TARGET_URL 을 조립한다.
# 이 3키가 모두 없으므로 조립 결과는 빈 문자열 — dev 키 값은 무시된다(변수 격리).
run_gate VD_CODE "$ws" ""
check "$([[ "$GATE_SKIP" == "true" && "$GATE_REASON" == "platform_cli" ]] && echo 1 || echo 0)" "T-32 verify-deploy env=prod: prod 3키 전부 없음(dev 키는 값이 있어도 무시) → HC_SKIP=true(변수 격리 확인)"

# ══════════════════════════════════════════════════════════════════
# 정적 가드 — setup/SKILL.md Should-1 안내 1행 존재
# ══════════════════════════════════════════════════════════════════
SETUP_SKILL="$REPO_ROOT/aiops/skills/setup/SKILL.md"
check "$(grep -qF '헬스체크:   자동 스킵' "$SETUP_SKILL" && echo 1 || echo 0)" "정적 가드: setup/SKILL.md CLI 결과 UI 에 헬스체크 자동 스킵 안내 1행 존재(Should-1)"

# ══════════════════════════════════════════════════════════════════
# 이슈 #44 — verify-deploy 헬스체크 스킵 경로 early-exit 0 통일 (T-33~T-46)
# 기존 45건(T-1~T-32 + 정적 가드) 본문은 위에서 손대지 않음. 이하 추가분.
# ══════════════════════════════════════════════════════════════════

# SKIP 판정 헬퍼 — ok 로 계상하되 사유를 출력. FAIL 에는 영향 없음(#44 T-41).
skip() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1 # SKIP $2"; }

# ── §2.3b 스킵 분기 블록(마커 등록 + exit 0) 추출 ────────────────────
# 앵커(verify-deploy:healthcheck-gate)는 HC_SKIP 판정 로직만 감싼다.
# 마커 등록 + early-exit 는 그 뒤 if/elif/fi 블록이므로, 고유 문자열
# 앵커(if 문 시작 ~ 첫 fi)로 그대로 추출해 eval 한다(문서-코드 일치 강제).
extract_skip_branch() {   # $1=파일
  awk '
    /^if \[\[ "\$HC_SKIP" == "true" \]\]; then$/ { f=1 }
    f { print }
    f && /^fi$/ { exit }
  ' "$1"
}

SKIP_CODE="$(extract_skip_branch "$VD_SKILL")"
if [[ -z "$SKIP_CODE" ]]; then
  notok "T-33 스킵 분기 블록 추출 실패 — verify-deploy/SKILL.md 의 if [[ \"\$HC_SKIP\" == \"true\" ]] 구조 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# 스킵 분기를 픽스처에서 eval 하고 forge.sh 스텁으로 마커 호출을 가로챈다.
run_skip_branch() {   # $1=ws $2=ENV $3=ISSUE $4=추가 prelude(선택, 예: SKIP_E2E=true)
  local ws="$1" envv="$2" issue="$3" prelude="${4:-}"
  local plugin="$ws/plugin"
  mkdir -p "$plugin/scripts"
  SKIPB_CALL_LOG="$ws/forge_calls.log";  : > "$SKIPB_CALL_LOG"
  SKIPB_BODY_FILE="$ws/forge_body.txt";  rm -f "$SKIPB_BODY_FILE"
  SKIPB_HEADER_LOG="$ws/forge_headers.log"; : > "$SKIPB_HEADER_LOG"
  cat > "$plugin/scripts/forge.sh" <<'STUB'
#!/usr/bin/env bash
echo "CALLED" >> "$SKIPB_CALL_LOG"
printf '%s' "$3" > "$SKIPB_BODY_FILE"
printf '%s\n' "$3" | head -1 >> "$SKIPB_HEADER_LOG"
STUB
  chmod +x "$plugin/scripts/forge.sh"
  local full
  full="$prelude
ENV=\"$envv\"
ISSUE=\"$issue\"
HC_SKIP=true
HC_SKIP_REASON=platform_cli
TARGET_URL=\"\"
$SKIP_CODE"
  SKIPB_OUT="$( (
    cd "$ws"
    export CLAUDE_PLUGIN_ROOT="$plugin"
    export SKIPB_CALL_LOG SKIPB_BODY_FILE SKIPB_HEADER_LOG
    eval "$full"
  ) 2>&1 )"
  SKIPB_RC=$?
  SKIPB_CALLS="$(grep -c 'CALLED' "$SKIPB_CALL_LOG" 2>/dev/null)"
  SKIPB_CALLS="${SKIPB_CALLS:-0}"
}

# ══════════════════════════════════════════════════════════════════
# T-33~T-40 — 기술 스펙 확정분 (E1~E4, E-4)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
run_skip_branch "$ws" "dev" "44"
check "$([[ "$SKIPB_RC" -eq 0 ]] && echo 1 || echo 0)" "T-33 스킵 분기: ISSUE=44 ENV=dev HC_SKIP=true → exit 0 (E1)"

check "$(grep -qF 'healthcheck_skipped=platform_cli' "$SKIPB_BODY_FILE" \
      && grep -qF 'Actions 대기' "$SKIPB_BODY_FILE" \
      && grep -qF '헬스체크' "$SKIPB_BODY_FILE" \
      && grep -qF 'E2E' "$SKIPB_BODY_FILE" \
      && echo 1 || echo 0)" "T-34 마커 본문에 healthcheck_skipped=platform_cli · Actions 대기 · 헬스체크 · E2E 4개 문자열 전부 hit (E2/AC-2)"

check "$([[ "$(head -1 "$SKIPB_BODY_FILE" | grep -cE '^## ℹ️ 헬스체크 스킵$')" -eq 1 ]] && echo 1 || echo 0)" "T-35 마커 헤더 첫 줄 정확 일치 '^## ℹ️ 헬스체크 스킵\$' (AC-3)"

check "$(printf '%s\n' "$SKIPB_OUT" | grep -qE '^\[verify-deploy\] §2 ' \
      && [[ "$(printf '%s\n' "$SKIPB_OUT" | grep -cF '§4 헬스체크 스킵')" -eq 0 ]] \
      && echo 1 || echo 0)" "T-36 stdout 접두어가 §2 로 정정되고 구 문구 '§4 헬스체크 스킵' 은 0건 (AC-5)"

check "$([[ "$(grep -cF 'if [[ "$HC_SKIP" != "true" ]]' "$VD_SKILL")" -eq 0 ]] \
      && [[ "$(grep -c '는 헬스체크 스킵이 아닐 때만 실행' "$VD_SKILL")" -eq 0 ]] \
      && echo 1 || echo 0)" "T-37 §3/§4 가드 문자열 '\$HC_SKIP\" != \"true\"' · 안내 주석 파일 전체 0건 (정적)"

SKIP_EXIT0_LINE="$(grep -n '^  exit 0$' "$VD_SKILL" | head -1 | cut -d: -f1)"
S3_ACTIONS_LINE="$(grep -n 'actions-wait\.sh' "$VD_SKILL" | head -1 | cut -d: -f1)"
S5_E2E_LINE="$(grep -n 'run-qa-e2e\.sh' "$VD_SKILL" | head -1 | cut -d: -f1)"
S6_CASE_LINE="$(grep -n 'case "\$E2E_EXIT' "$VD_SKILL" | head -1 | cut -d: -f1)"
check "$([[ -n "$SKIP_EXIT0_LINE" && -n "$S3_ACTIONS_LINE" && -n "$S5_E2E_LINE" && -n "$S6_CASE_LINE" \
        && "$SKIP_EXIT0_LINE" -lt "$S3_ACTIONS_LINE" && "$S3_ACTIONS_LINE" -lt "$S5_E2E_LINE" \
        && "$S5_E2E_LINE" -lt "$S6_CASE_LINE" ]] && echo 1 || echo 0)" \
  "T-38 스킵 분기 exit 0($SKIP_EXIT0_LINE) < §3 actions-wait.sh($S3_ACTIONS_LINE) < §5 run-qa-e2e.sh($S5_E2E_LINE) < §6 case(\$S6_CASE_LINE) 행 번호 단조 증가 → §6 도달 경로 없음 (정적, (c))"

# T-39 — §3·§4 본문 바이트 불변. 커밋 해시가 로컬에 없으면 SKIP(ok, FAIL 무영향) — T-41 근거.
BASE_COMMIT_REF="27ea94f~1"
if git -C "$REPO_ROOT" cat-file -e "$BASE_COMMIT_REF" 2>/dev/null; then
  BASE_VD_TMP="$TMPBASE/base_vd_44.md"
  git -C "$REPO_ROOT" show "$BASE_COMMIT_REF:aiops/skills/verify-deploy/SKILL.md" > "$BASE_VD_TMP" 2>/dev/null
  BASE_S34="$(sed -n '/^## 3\. /,/^## 5\. /p' "$BASE_VD_TMP" | sed '$d')"
  CUR_S34="$(sed -n '/^## 3\. /,/^## 5\. /p' "$VD_SKILL" | sed '$d')"
  check "$([[ "$BASE_S34" == "$CUR_S34" ]] && echo 1 || echo 0)" "T-39 §3·§4 구간 바이트 불변 — $BASE_COMMIT_REF 사본과 동일 (AC-6, B-1·B-2)"
else
  skip "T-39 §3·§4 구간 바이트 불변" "기준 커밋 $BASE_COMMIT_REF 를 로컬에서 찾을 수 없음(shallow clone 등) — 종료 코드에 영향 없음"
fi

# T-40 — ISSUE 빈 값 (E-4)
ws=$(new_ws)
run_skip_branch "$ws" "dev" ""
check "$([[ "$SKIPB_RC" -eq 0 ]] && echo 1 || echo 0)" "T-40 ISSUE=\"\" 에도 exit 0 유지 (E-4)"
check "$([[ "${SKIPB_CALLS:-0}" -eq 0 ]] && echo 1 || echo 0)" "T-40 ISSUE=\"\" 이면 forge.sh 스텁 호출 0회 (if/fi 전환 확인, E-4)"
check "$([[ -n "$SKIPB_OUT" ]] && echo 1 || echo 0)" "T-40 ISSUE=\"\" 이어도 stdout 1행 이상 존재"

# ══════════════════════════════════════════════════════════════════
# T-41~T-46 (제안, 구현) — 누락 엣지 보강
# ══════════════════════════════════════════════════════════════════

# T-41 — T-39 커밋 해시 하드코딩 취약성: 존재하지 않는 해시는 SKIP 분기로 빠지고
# FAIL 로 계상되지 않음을 더미 해시로 직접 시뮬레이션한다.
BOGUS_HASH="0000000000000000000000000000000000000000"
if git -C "$REPO_ROOT" cat-file -e "$BOGUS_HASH" 2>/dev/null; then
  notok "T-41 시뮬레이션 무효 — 더미 해시 $BOGUS_HASH 가 실제로 존재함(테스트 환경 이상)"
else
  skip "T-41 커밋 해시 하드코딩 취약성" "더미 해시 $BOGUS_HASH 는 git cat-file -e 로 부재 확인됨 → T-39 와 동일 가드로 SKIP(ok) 처리, 전체 종료 코드 무영향"
fi

# T-42 — 전체 파이프라인(§2→§6) 1회 통짜 eval 은 구현하지 않음(과업 지시 3번, 사유는 보고서 참조).
# 대신 T-38(행 번호 단조 증가)이 절 경계 손상 여부를, T-4~T-32 가 절 단위 계약을 이미 커버한다.

# T-43 — --env=prod 스킵 경로: 힌트 문자열 및 판정 신호가 dev 와 동일하게 성립
ws=$(new_ws)
run_skip_branch "$ws" "prod" "44"
check "$([[ "$SKIPB_RC" -eq 0 ]] && echo 1 || echo 0)" "T-43 --env=prod 스킵 분기도 exit 0"
check "$(grep -qF 'prod_url / cf_prod_url / e2e_prod_url' "$SKIPB_BODY_FILE" && echo 1 || echo 0)" "T-43 prod 사유 힌트 'prod_url / cf_prod_url / e2e_prod_url' 로 치환됨"
check "$([[ "$(head -1 "$SKIPB_BODY_FILE" | grep -cE '^## ℹ️ 헬스체크 스킵$')" -eq 1 ]] && echo 1 || echo 0)" "T-43 prod 에서도 마커 헤더 정확 일치 유지"

# T-44 — 마커 본문 3항목을 부분 문자열이 아닌 라인 앵커로 고유 판정(헤더 자체의 '헬스체크' 오매치 방지)
ws=$(new_ws)
run_skip_branch "$ws" "dev" "44"
ANCHORED_ITEM_COUNT="$(grep -cE '^- (Actions 대기|헬스체크|E2E):' "$SKIPB_BODY_FILE")"
check "$([[ "$ANCHORED_ITEM_COUNT" -eq 3 ]] && echo 1 || echo 0)" "T-44 '- Actions 대기:' · '- 헬스체크:' · '- E2E:' 라인 앵커 3건 고유 판정(헤더 '## ℹ️ 헬스체크 스킵' 과 오매치 없음)"

# T-45 — §6 마커 4종이 스킵 경로 forge 호출 로그에 전혀 등장하지 않음
check "$([[ "$(grep -cE '^\$?HEADER_OK$|^## 🌐|^## 🚦' "$SKIPB_HEADER_LOG")" -eq 0 ]] \
      && [[ "$(grep -cE '^## ❌ .* E2E FAIL$' "$SKIPB_HEADER_LOG")" -eq 0 ]] \
      && [[ "$(grep -cE '^## ⚠️ .* E2E 환경 오류$' "$SKIPB_HEADER_LOG")" -eq 0 ]] \
      && [[ "$(grep -cE '^## ℹ️ 헬스체크 스킵$' "$SKIPB_HEADER_LOG")" -eq 1 ]] \
      && echo 1 || echo 0)" "T-45 forge 호출 누적 로그에 §6 마커 4종(A/B/C/E) 0건, 스킵 마커만 정확히 1건"

# T-46 — --skip-e2e 동시 지정해도 스킵 판정·마커에 영향 없음(확정 (d))
check "$(printf '%s' "$SKIP_CODE" | grep -qF 'SKIP_E2E' && echo 0 || echo 1)" "T-46 스킵 분기 코드는 SKIP_E2E 를 참조하지 않음(정적 — 판정 순서상 무관, 확정 (d))"
ws=$(new_ws)
run_skip_branch "$ws" "dev" "44" 'SKIP_E2E=true'
check "$([[ "$SKIPB_RC" -eq 0 ]] && [[ "${SKIPB_CALLS:-0}" -eq 1 ]] && echo 1 || echo 0)" "T-46 SKIP_E2E=true 동시 지정해도 마커 1건만 등록(exit 0)"
check "$([[ "$(head -1 "$SKIPB_BODY_FILE" | grep -cE '^## ℹ️ 헬스체크 스킵$')" -eq 1 ]] && echo 1 || echo 0)" "T-46 SKIP_E2E=true 여도 헤더는 여전히 '## ℹ️ 헬스체크 스킵' (본문 E2E 문구 미분기)"

# ══════════════════════════════════════════════════════════════════
echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
