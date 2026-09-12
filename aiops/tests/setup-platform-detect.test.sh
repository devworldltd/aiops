#!/usr/bin/env bash
# setup-platform-detect.test.sh — 이슈 #16 "platform 분류에 cli 지원 추가"
# aiops/skills/setup/SKILL.md 의 `setup:platform-detect` 앵커(§16)와
# aiops/skills/devflow/SKILL.md 의 `devflow:platform-branch` 앵커(§M.2)를
# 한 파일에서 함께 검증한다(결정 (d) — AC-1·AC-2 가 동일 기능의 앞뒤 구간).
#
# 순수 bash(3.2 호환). aiops/tests/setup-prod-workflow-detect.test.sh 규약을 그대로 따른다:
#   - 케이스별 `ok N - <설명>` / `not ok N - <설명>`
#   - 마지막 줄 `TESTS=<총> PASS=<n> FAIL=<n>`
#   - 종료 코드: 전건 통과 0, 1건 이상 실패 1
#
# 리졸버를 재구현하지 않는다 — SKILL.md 의 앵커 사이 코드를 awk 로 그대로
# 추출해 픽스처 디렉터리에서 eval 한다(문서-코드 일치 강제).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_SKILL="$REPO_ROOT/aiops/skills/setup/SKILL.md"
DEVFLOW_SKILL="$REPO_ROOT/aiops/skills/devflow/SKILL.md"
DETECT_ANCHOR="setup:platform-detect"
BRANCH_ANCHOR="devflow:platform-branch"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/setup-platform-detect-test.XXXXXX")"
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

DETECT_CODE="$(extract_block "$SETUP_SKILL" "$DETECT_ANCHOR")"
BRANCH_CODE="$(extract_block "$DEVFLOW_SKILL" "$BRANCH_ANCHOR")"

if [[ -z "$DETECT_CODE" ]]; then
  notok "앵커 사이 코드 추출 실패 — setup/SKILL.md 의 $DETECT_ANCHOR 앵커 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
  exit 1
fi

if [[ -z "$BRANCH_CODE" ]]; then
  notok "앵커 사이 코드 추출 실패 — devflow/SKILL.md 의 $BRANCH_ANCHOR 앵커 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# ── 픽스처 헬퍼 ──────────────────────────────────────────────────────
new_ws() {
  local ws="$TMPBASE/ws_$RANDOM$RANDOM"
  mkdir -p "$ws"
  echo "$ws"
}

write_pkg() {   # $1=ws $2=package.json 내용
  printf '%s' "$2" > "$1/package.json"
}

touch_manifest() {   # $1=ws $2=파일명
  : > "$1/$2"
}

# §16 앵커 코드를 픽스처 디렉터리에서 실행한다. WEB_DETECTED/MOBILE_DETECTED 는
# 앵커 밖 입력이므로 eval 전에 export 해 둔다(기술 스펙 결정 (d)).
run_detect() {   # $1=ws $2=WEB_DETECTED $3=MOBILE_DETECTED
  local ws="$1" web="${2:-false}" mobile="${3:-false}"
  DETECT_OUT="$( (cd "$ws" && WEB_DETECTED="$web" MOBILE_DETECTED="$mobile" eval "$DETECT_CODE") 2>&1 )"
  DETECT_RC=$?
  DETECT_PLATFORM="$(printf '%s\n' "$DETECT_OUT" | grep -o 'platform=[a-z]*' | head -1 | cut -d= -f2)"
}

# ══════════════════════════════════════════════════════════════════
# T40-1 — bin(객체) + 웹X + 모바일X + 매니페스트X → cli (AC-1 #1)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_pkg "$ws" '{"name":"dwc","bin":{"dwc":"dist/cli.js"}}'
run_detect "$ws" false false
check "$([[ "$DETECT_PLATFORM" == "cli" ]] && echo 1 || echo 0)" "T40-1 bin 객체 + 웹/모바일 미감지 → platform=cli"
check "$([[ "$DETECT_OUT" == *"[setup] §16 platform=cli"* ]] && echo 1 || echo 0)" "T40-1 stdout에 §16 platform=cli 출력"

# ══════════════════════════════════════════════════════════════════
# T40-2 — bin + WEB_DETECTED=true(hono) → web (AC-1 #2)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_pkg "$ws" '{"name":"dwc","bin":{"dwc":"dist/cli.js"},"dependencies":{"hono":"^4.0.0"}}'
run_detect "$ws" true false
check "$([[ "$DETECT_PLATFORM" == "web" ]] && echo 1 || echo 0)" "T40-2 bin + WEB_DETECTED=true → platform=web"

# ══════════════════════════════════════════════════════════════════
# T40-3 — bin 없음, 웹X·모바일X → web (AC-1 #3)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_pkg "$ws" '{"name":"plain"}'
run_detect "$ws" false false
check "$([[ "$DETECT_PLATFORM" == "web" ]] && echo 1 || echo 0)" "T40-3 bin 없음, 웹/모바일 미감지 → platform=web(안전 기본값)"

# ══════════════════════════════════════════════════════════════════
# T40-4 — bin + wrangler.toml → web (AC-1 #4)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_pkg "$ws" '{"name":"dwc","bin":{"dwc":"dist/cli.js"}}'
touch_manifest "$ws" wrangler.toml
run_detect "$ws" false false
check "$([[ "$DETECT_PLATFORM" == "web" ]] && echo 1 || echo 0)" "T40-4 bin + wrangler.toml → platform=web"
check "$([[ "$DETECT_OUT" == *"web_manifest=true"* ]] && echo 1 || echo 0)" "T40-4 stdout에 web_manifest=true 근거 출력"

# ══════════════════════════════════════════════════════════════════
# T40-5 — bin + Dockerfile → cli 유지 (결정 (b) 회귀 감시점, AC-1 #5)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_pkg "$ws" '{"name":"dwc","bin":{"dwc":"dist/cli.js"}}'
touch_manifest "$ws" Dockerfile
run_detect "$ws" false false
check "$([[ "$DETECT_PLATFORM" == "cli" ]] && echo 1 || echo 0)" "T40-5 bin + Dockerfile → platform=cli 유지(Dockerfile 은 제외 조건 아님, 결정 (b))"

# ══════════════════════════════════════════════════════════════════
# T40-6 — MOBILE_DETECTED=true 단독 → mobile (AC-1 #6)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
run_detect "$ws" false true
check "$([[ "$DETECT_PLATFORM" == "mobile" ]] && echo 1 || echo 0)" "T40-6 MOBILE_DETECTED=true 단독 → platform=mobile"

# ══════════════════════════════════════════════════════════════════
# T40-7 — WEB_DETECTED=true + MOBILE_DETECTED=true → both (AC-1 #7)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
run_detect "$ws" true true
check "$([[ "$DETECT_PLATFORM" == "both" ]] && echo 1 || echo 0)" "T40-7 웹+모바일 동시 감지 → platform=both"

# ══════════════════════════════════════════════════════════════════
# T40-8 — 빈 디렉터리(package.json 없음) → web (AC-1 #8)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
run_detect "$ws" false false
check "$([[ "$DETECT_PLATFORM" == "web" ]] && echo 1 || echo 0)" "T40-8 package.json 없음 → platform=web(안전 기본값)"

# ══════════════════════════════════════════════════════════════════
# T40-9 (엣지) — "bin": {} 빈 객체 → web (cli 아님)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_pkg "$ws" '{"name":"dwc","bin":{}}'
run_detect "$ws" false false
check "$([[ "$DETECT_PLATFORM" == "web" ]] && echo 1 || echo 0)" "T40-9 bin 빈 객체 {} → platform=web(cli 아님)"

# ══════════════════════════════════════════════════════════════════
# T40-10 (엣지) — 깨진 JSON → web (jq 파싱 실패 시 안전 기본값)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_pkg "$ws" '{"bin":'
run_detect "$ws" false false
check "$([[ "$DETECT_PLATFORM" == "web" ]] && echo 1 || echo 0)" "T40-10 package.json 파싱 실패(깨진 JSON) → platform=web"

# ══════════════════════════════════════════════════════════════════
# T40-11 (엣지) — bin 문자열 형태 → cli
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_pkg "$ws" '{"name":"dwc","bin":"dist/cli.js"}'
run_detect "$ws" false false
check "$([[ "$DETECT_PLATFORM" == "cli" ]] && echo 1 || echo 0)" "T40-11 bin 문자열 형태 → platform=cli"

# ══════════════════════════════════════════════════════════════════
# T40-12 (엣지) — wrangler.jsonc 단독으로도 웹 매니페스트로 인정 → web
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_pkg "$ws" '{"name":"dwc","bin":{"dwc":"dist/cli.js"}}'
touch_manifest "$ws" wrangler.jsonc
run_detect "$ws" false false
check "$([[ "$DETECT_PLATFORM" == "web" ]] && echo 1 || echo 0)" "T40-12 bin + wrangler.jsonc 단독 → platform=web"

# ══════════════════════════════════════════════════════════════════
# T40-13~16 (엣지) — 나머지 웹 배포 매니페스트 4종 전수 검사
# ══════════════════════════════════════════════════════════════════
for m in vercel.json netlify.toml fly.toml serverless.yml; do
  ws=$(new_ws)
  write_pkg "$ws" '{"name":"dwc","bin":{"dwc":"dist/cli.js"}}'
  touch_manifest "$ws" "$m"
  run_detect "$ws" false false
  check "$([[ "$DETECT_PLATFORM" == "web" ]] && echo 1 || echo 0)" "T40-13~16 bin + $m 단독 → platform=web"
done

# ══════════════════════════════════════════════════════════════════
# T40-17 (엣지) — jq 부재 폴백: PATH 조작으로 jq 를 숨기고 grep 폴백 경로 검증
# ══════════════════════════════════════════════════════════════════
FAKE_BIN="$TMPBASE/fakebin"
mkdir -p "$FAKE_BIN"
for tool in bash awk grep sed cat cut mkdir rm mktemp printf cd ls true false; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [[ -n "$real" ]] && ln -sf "$real" "$FAKE_BIN/$tool" 2>/dev/null || true
done
ws=$(new_ws)
write_pkg "$ws" '{"name":"dwc","bin":{"dwc":"dist/cli.js"}}'
NOJQ_OUT="$( (cd "$ws" && PATH="$FAKE_BIN" WEB_DETECTED=false MOBILE_DETECTED=false eval "$DETECT_CODE") 2>&1 )"
NOJQ_PLATFORM="$(printf '%s\n' "$NOJQ_OUT" | grep -o 'platform=[a-z]*' | head -1 | cut -d= -f2)"
check "$([[ "$NOJQ_PLATFORM" == "cli" ]] && echo 1 || echo 0)" "T40-17 jq 부재(PATH 조작) → grep 폴백으로도 platform=cli 판정"

# ══════════════════════════════════════════════════════════════════
# devflow §M.2 — devflow:platform-branch 앵커
#
# §M.2 eval 안전 규약(결정 (d)) — 3중 방어:
#   ① mobile 케이스는 동적 실행하지 않는다(정적 grep 만, T41-5).
#   ② eval 코드 앞에 exec 스텁 함수를 정의해 프로세스 치환을 차단한다.
#   ③ 모든 eval 은 서브셸 ( ... ) 안에서 실행한다.
# ══════════════════════════════════════════════════════════════════
EXEC_STUB='exec() { echo "[stub] exec $*"; return 0; }'

run_branch() {   # $1=PLATFORM 값
  local plat="$1" code
  code="$EXEC_STUB"$'\n'"PLATFORM=\"$plat\""$'\n'"$BRANCH_CODE"
  BRANCH_OUT="$( ( eval "$code" ) 2>&1 )"
  BRANCH_RC=$?
}

# 스텁 자기 점검 — exec 가 함수로 등록됐는지 확인 (누락 엣지 케이스 제안 #5 반영)
STUB_CHECK_OUT="$( ( eval "$EXEC_STUB"; type exec ) 2>&1 )"
check "$([[ "$STUB_CHECK_OUT" == *"exec is a function"* ]] && echo 1 || echo 0)" "T41-0 exec 스텁 자기 점검 — type exec 가 function 으로 등록됨"

# ══════════════════════════════════════════════════════════════════
# T41-1~3 — PLATFORM=cli eval → CLI 흐름 진행 1회, WARN 0회, mobileflow 미포함 (AC-2)
# ══════════════════════════════════════════════════════════════════
run_branch "cli"
cli_line_count="$(printf '%s\n' "$BRANCH_OUT" | grep -c 'CLI 흐름 진행' || true)"
warn_count="$(printf '%s\n' "$BRANCH_OUT" | grep -c 'WARN' || true)"
check "$([[ "${cli_line_count:-0}" == "1" ]] && echo 1 || echo 0)" "T41-1 PLATFORM=cli → 'CLI 흐름 진행' 정확히 1회 출력"
check "$([[ "${warn_count:-0}" == "0" ]] && echo 1 || echo 0)" "T41-2 PLATFORM=cli → WARN 0회, rc=0"
check "$([[ "$BRANCH_RC" == "0" ]] && echo 1 || echo 0)" "T41-2 PLATFORM=cli → 종료 코드 0"
check "$([[ "$BRANCH_OUT" != *"mobileflow"* ]] && echo 1 || echo 0)" "T41-3 PLATFORM=cli → 'mobileflow' 문자열 미포함"

# ══════════════════════════════════════════════════════════════════
# T41-4 — PLATFORM=web|both|zzz(미지값) eval → 기존 3문구 바이트 동일 (AC-3, 무회귀)
# ══════════════════════════════════════════════════════════════════
run_branch "web"
check "$([[ "$BRANCH_OUT" == *"[devflow] 웹 흐름 진행"* ]] && echo 1 || echo 0)" "T41-4 PLATFORM=web → 기존 문구 '[devflow] 웹 흐름 진행' 무회귀"

run_branch "zzz"
check "$([[ "$BRANCH_OUT" == *"WARN: unknown platform"* ]] && echo 1 || echo 0)" "T41-4 PLATFORM=zzz(미지값) → 'WARN: unknown platform' 폴백 보존"

# ══════════════════════════════════════════════════════════════════
# T41-5 — mobile 분기는 동적 실행하지 않고 정적 grep 으로만 존치 확인 (안전)
# ══════════════════════════════════════════════════════════════════
check "$(grep -q 'exec /aiops:mobileflow' "$DEVFLOW_SKILL" && echo 1 || echo 0)" "T41-5 devflow/SKILL.md 에 'exec /aiops:mobileflow' 정적 존치 확인(동적 실행 금지)"

# ══════════════════════════════════════════════════════════════════
# 정적 가드 — setup §16 결정표·§11·§17·§13·§18 매핑표에 cli 문자열 존재 확인
# ══════════════════════════════════════════════════════════════════
check "$(grep -q '`cli`' "$SETUP_SKILL" && echo 1 || echo 0)" "정적 가드: setup/SKILL.md 에 \`cli\` 문자열 존재(§16 결정표 등)"
check "$(grep -q 'node-cli' "$SETUP_SKILL" && echo 1 || echo 0)" "정적 가드: setup/SKILL.md §11 매핑표에 node-cli 존재"
check "$(grep -q 'platform: web | mobile | both | cli' "$SETUP_SKILL" && echo 1 || echo 0)" "정적 가드: setup/SKILL.md §17 platform 열거값에 cli 포함"
check "$(grep -q 'cli)    AUTO_PROFILE="web"' "$SETUP_SKILL" && echo 1 || echo 0)" "정적 가드: setup/SKILL.md §18 case 문에 cli) 분기 존재"

# ══════════════════════════════════════════════════════════════════
echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
