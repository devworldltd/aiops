#!/usr/bin/env bash
# setup-prod-workflow-detect.test.sh — aiops/skills/setup/SKILL.md §10-1
# "prod 전용 배포 워크플로우 감지(deploy_workflow_prod)" 로직 검증.
# 이슈 #33 기술 스펙 D-5 + 기획 §5(E5)·E2E 제안 T22/T23 을 구현한다.
#
# 순수 bash(3.2 호환). aiops/tests/forge-reviewer-token.test.sh 규약을 그대로 따른다:
#   - 케이스별 `ok N - <설명>` / `not ok N - <설명>`
#   - 마지막 줄 `TESTS=<총> PASS=<n> FAIL=<n>`
#   - 종료 코드: 전건 통과 0, 1건 이상 실패 1
#
# 리졸버를 재구현하지 않는다 — setup/SKILL.md 의
#   `# >>> setup:prod-workflow-detect >>>` ~ `# <<< setup:prod-workflow-detect <<<`
# 사이 코드를 awk 로 그대로 추출해 픽스처 디렉터리에서 eval 한다(문서-코드 일치 강제).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_SKILL="$REPO_ROOT/aiops/skills/setup/SKILL.md"
ANCHOR="setup:prod-workflow-detect"
HELPER_ANCHOR="setup:config-update"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/setup-prod-workflow-detect-test.XXXXXX")"
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

DETECT_CODE="$(extract_block "$SETUP_SKILL" "$ANCHOR")"
HELPER_CODE="$(extract_block "$SETUP_SKILL" "$HELPER_ANCHOR")"

if [[ -z "$DETECT_CODE" ]]; then
  notok "앵커 사이 코드 추출 실패 — setup/SKILL.md 의 $ANCHOR 앵커 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
  exit 1
fi

if [[ -z "$HELPER_CODE" ]]; then
  notok "헬퍼 앵커 추출 실패 — setup/SKILL.md 의 $HELPER_ANCHOR 앵커 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# 헬퍼 정의를 감지 코드 앞에 이어 붙여 eval 한다 (이슈 #35 D-1 A안).
EVAL_CODE="$HELPER_CODE"$'\n'"$DETECT_CODE"

# ── 픽스처 헬퍼 ──────────────────────────────────────────────────────
# 각 테스트는 독립 디렉터리에서 실행한다 (WFDIR·PROD_CANDIDATES 등 변수 오염 방지).
new_ws() {
  local ws="$TMPBASE/ws_$RANDOM$RANDOM"
  mkdir -p "$ws"
  echo "$ws"
}

write_config() {   # $1=ws $2=config json 내용
  mkdir -p "$1/.claude"
  printf '%s' "$2" > "$1/.claude/config.json"
}

write_workflow() {  # $1=ws $2=dir(.github/workflows 또는 .gitea/workflows) $3=파일명 $4=내용
  mkdir -p "$1/$2"
  printf '%s' "$4" > "$1/$2/$3"
}

# 감지 코드를 픽스처 디렉터리에서 실행하고 stdout 과 최종 config.json 을 캡처한다.
run_detect() {   # $1=ws
  local ws="$1"
  DETECT_OUT="$( ( cd "$ws" && eval "$EVAL_CODE" ) 2>&1 )"
  DETECT_RC=$?
  DETECT_CONFIG="$(cat "$ws/.claude/config.json" 2>/dev/null || echo "")"
}

has_key() {   # $1=config json $2=키 → "true"/"false" 출력
  printf '%s' "$1" | jq -r --arg k "$2" 'has($k)' 2>/dev/null
}

key_value() {  # $1=config json $2=키
  printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null
}

DEV_MAIN_YML='name: deploy
on:
  push:
    branches:
      - main
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo deploy
'

TRIGGER_DEV_YML='name: deploy-dev
on:
  push:
    branches: [dev]
jobs:
  deploy:
    runs-on: ubuntu-latest
'

NEUTRAL_YML='name: ci
on:
  pull_request:
    branches: [dev, main]
jobs:
  build:
    runs-on: ubuntu-latest
'

# ══════════════════════════════════════════════════════════════════
# T1 — 워크플로우 디렉터리 자체 부재 → 조용히 스킵 (T22)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_config "$ws" '{}'
run_detect "$ws"
check "$([[ -z "$DETECT_OUT" ]] && echo 1 || echo 0)" "T1 워크플로우 디렉터리 부재 시 출력 없음(조용히 스킵)"
check "$([[ "$(has_key "$DETECT_CONFIG" deploy_workflow_prod)" == "false" ]] && echo 1 || echo 0)" "T1 deploy_workflow_prod 키 미생성"

# ══════════════════════════════════════════════════════════════════
# T2 — 워크플로우 디렉터리는 있으나 후보 0개
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_config "$ws" '{}'
write_workflow "$ws" ".github/workflows" "ci.yml" "$NEUTRAL_YML"
run_detect "$ws"
check "$([[ "$DETECT_RC" == "0" ]] && echo 1 || echo 0)" "T2 exit 0"
check "$([[ "$(has_key "$DETECT_CONFIG" deploy_workflow_prod)" == "false" ]] && echo 1 || echo 0)" "T2 후보 0개 → deploy_workflow_prod 미생성"

# ══════════════════════════════════════════════════════════════════
# T3 — 파일명에 prod 포함 1개 → 기입
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_config "$ws" '{}'
write_workflow "$ws" ".github/workflows" "deploy-prod.yml" "$NEUTRAL_YML"
run_detect "$ws"
check "$([[ "$(key_value "$DETECT_CONFIG" deploy_workflow_prod)" == "deploy-prod.yml" ]] && echo 1 || echo 0)" "T3 파일명 prod 1개 → deploy_workflow_prod=deploy-prod.yml 기입"
check "$([[ "$DETECT_OUT" == *"deploy-prod.yml"* ]] && echo 1 || echo 0)" "T3 stdout 에 감지 결과 출력"

# ══════════════════════════════════════════════════════════════════
# T4 — branches: main 단독 트리거 1개(파일명은 prod 미포함) → 기입
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_config "$ws" '{}'
write_workflow "$ws" ".github/workflows" "release.yml" "$DEV_MAIN_YML"
run_detect "$ws"
check "$([[ "$(key_value "$DETECT_CONFIG" deploy_workflow_prod)" == "release.yml" ]] && echo 1 || echo 0)" "T4 branches:main 단독 트리거 1개 → deploy_workflow_prod=release.yml 기입"

# ══════════════════════════════════════════════════════════════════
# T5 — 후보 2개 이상 → 미기입 + 후보 목록 출력
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_config "$ws" '{}'
write_workflow "$ws" ".github/workflows" "deploy-prod.yml" "$NEUTRAL_YML"
write_workflow "$ws" ".github/workflows" "release-production.yml" "$NEUTRAL_YML"
run_detect "$ws"
check "$([[ "$(has_key "$DETECT_CONFIG" deploy_workflow_prod)" == "false" ]] && echo 1 || echo 0)" "T5 후보 2개 → deploy_workflow_prod 미기입"
check "$([[ "$DETECT_OUT" == *"deploy-prod.yml"* && "$DETECT_OUT" == *"release-production.yml"* ]] && echo 1 || echo 0)" "T5 stdout 에 후보 2개 모두 출력"
check "$([[ "$DETECT_OUT" == *"다수"* ]] && echo 1 || echo 0)" "T5 모호 안내 문구 출력"

# ══════════════════════════════════════════════════════════════════
# T6 — 기존 값 보존(덮어쓰기 금지)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_config "$ws" '{"deploy_workflow_prod":"already-set.yml"}'
write_workflow "$ws" ".github/workflows" "deploy-prod.yml" "$NEUTRAL_YML"
run_detect "$ws"
check "$([[ "$(key_value "$DETECT_CONFIG" deploy_workflow_prod)" == "already-set.yml" ]] && echo 1 || echo 0)" "T6 기존 값 보존(덮어쓰지 않음)"
check "$([[ "$DETECT_OUT" == *"already-set.yml"* ]] && echo 1 || echo 0)" "T6 stdout 에 보존 안내 출력"

# ══════════════════════════════════════════════════════════════════
# T7 — .gitea/workflows 경로 (Gitea 우선)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_config "$ws" '{}'
write_workflow "$ws" ".gitea/workflows" "deploy-prod.yml" "$NEUTRAL_YML"
run_detect "$ws"
check "$([[ "$(key_value "$DETECT_CONFIG" deploy_workflow_prod)" == "deploy-prod.yml" ]] && echo 1 || echo 0)" "T7 .gitea/workflows 경로에서도 감지"

# ══════════════════════════════════════════════════════════════════
# T8 (제안 T23) — 파일명 기준 후보 1개 + 트리거 기준 후보 1개(서로 다른 파일)
#                → 합쳐서 후보 2개로 취급, 미기입
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_config "$ws" '{}'
write_workflow "$ws" ".github/workflows" "deploy-prod.yml" "$TRIGGER_DEV_YML"   # 파일명 기준 후보
write_workflow "$ws" ".github/workflows" "release.yml" "$DEV_MAIN_YML"          # 트리거 기준 후보(main 단독)
run_detect "$ws"
check "$([[ "$(has_key "$DETECT_CONFIG" deploy_workflow_prod)" == "false" ]] && echo 1 || echo 0)" "T8(T23) 파일명 기준·트리거 기준 후보가 다른 파일 → 후보 2개로 미기입"
check "$([[ "$DETECT_OUT" == *"deploy-prod.yml"* && "$DETECT_OUT" == *"release.yml"* ]] && echo 1 || echo 0)" "T8(T23) stdout 에 두 후보 파일명 모두 출력"

# ══════════════════════════════════════════════════════════════════
# 이슈 #38 확장 — T30(§10-1 실패 분기) / T31-1~4(§18 profile 앵커) / T32·T33(§5·§13)
# ══════════════════════════════════════════════════════════════════
PROFILE_ANCHOR="setup:profile-register"
PROFILE_CODE="$(extract_block "$SETUP_SKILL" "$PROFILE_ANCHOR")"

if [[ -z "$PROFILE_CODE" ]]; then
  notok "§18 profile-register 앵커 추출 실패 — setup/SKILL.md 의 $PROFILE_ANCHOR 앵커 확인 필요"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
  exit 1
fi

file_sha() {   # $1=파일
  if command -v shasum >/dev/null 2>&1; then
    shasum "$1" 2>/dev/null | awk '{print $1}'
  else
    cksum "$1" 2>/dev/null
  fi
}

IS_ROOT=0
[[ "$(id -u)" == "0" ]] && IS_ROOT=1

# §18 앵커 코드를 헬퍼와 결합해 픽스처 디렉터리에서 실행한다. 앵커 밖 변수 $PLATFORM
# 을 eval 전에 미리 세팅한다(기술 스펙 U-3).
run_profile() {   # $1=ws $2=PLATFORM 값
  local ws="$1" plat="$2" code
  code="$HELPER_CODE"$'\n'"PLATFORM=\"$plat\""$'\n'"$PROFILE_CODE"
  PROFILE_OUT="$( (cd "$ws" && eval "$code") 2>&1 )"
  PROFILE_RC=$?
  PROFILE_CONFIG="$(cat "$ws/.claude/config.json" 2>/dev/null || echo "")"
}

# §5·§13 호출부는 setup:prod-workflow-detect/setup:profile-register 처럼 전용 앵커로
# 감싸여 있지 않다. 위치(행 번호) 기반 sed 추출은 SKILL.md 편집으로 쉽게 어긋나므로,
# 대신 호출 문자열을 grep -Fn 으로 찾아 그 라인을 감싼 가장 가까운 ```bash 코드펜스
# 전체(=이 호출부의 유일한 자연 경계)를 awk 로 추출해 사용한다.
fence_block() {   # $1=파일 $2=기준 라인 번호 → 그 라인을 감싼 코드펜스 내용 출력
  local file="$1" ln="$2"
  awk -v ln="$ln" '
    { lines[NR]=$0 }
    END {
      start=0; end=0
      for (i=ln; i>=1; i--) { if (lines[i] ~ /^```/) { start=i; break } }
      for (i=ln; i<=NR; i++) { if (lines[i] ~ /^```$/ && i>start) { end=i; break } }
      if (start>0 && end>start) { for (i=start+1; i<end; i++) print lines[i] }
    }
  ' "$file"
}

# ══════════════════════════════════════════════════════════════════
# T30 — §10-1 실패 분기(AC-1/AC-2/AC-3): .claude 쓰기 불가 → F1 WARN 출력,
#        S1("…기입") 미출력, config 바이트 불변, 헬퍼 stderr 원인 보존.
# T30-2 — root 로 실행 중이면 chmod 가 무력화되므로 스킵 처리한다.
# ══════════════════════════════════════════════════════════════════
if [[ "$IS_ROOT" == "1" ]]; then
  ok "T30 §10-1 실패 분기 (root 실행 — chmod 무력화로 스킵) [T30-2]"
else
  ws=$(new_ws)
  write_config "$ws" '{}'
  write_workflow "$ws" ".github/workflows" "deploy-prod.yml" "$NEUTRAL_YML"
  before_sha="$(file_sha "$ws/.claude/config.json")"
  chmod 555 "$ws/.claude"
  run_detect "$ws"
  chmod 755 "$ws/.claude" 2>/dev/null || true
  after_sha="$(file_sha "$ws/.claude/config.json")"
  gichip_count="$(printf '%s\n' "$DETECT_OUT" | grep -c '→ deploy_workflow_prod 기입' || true)"
  check "$([[ "$DETECT_OUT" == *"[setup] §10-1 WARN: deploy_workflow_prod 기입 실패 — 위 오류를 확인하세요"* ]] && echo 1 || echo 0)" "T30 F1 WARN 문구 출력"
  check "$([[ "${gichip_count:-0}" == "0" ]] && echo 1 || echo 0)" "T30 '→ deploy_workflow_prod 기입'(S1) 0회 출력"
  check "$([[ "$before_sha" == "$after_sha" ]] && echo 1 || echo 0)" "T30 config 바이트 불변"
  check "$([[ "$DETECT_OUT" == *"임시 파일 생성 실패"* ]] && echo 1 || echo 0)" "T30 헬퍼 stderr 원인 메시지 보존"
fi

# ══════════════════════════════════════════════════════════════════
# T31-1 — §18 신규 등록(AC-10 반례): profile 미설정 + 정상 쓰기 → S4 등록 문구 + profile=web
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_config "$ws" '{}'
run_profile "$ws" "web"
check "$([[ "$PROFILE_OUT" == *"[/aiops:setup] profile=web 자동 등록 (#161)"* ]] && echo 1 || echo 0)" "T31-1 신규 등록 성공 문구(S4) 출력"
check "$([[ "$(key_value "$PROFILE_CONFIG" profile)" == "web" ]] && echo 1 || echo 0)" "T31-1 config.profile == web"

# ══════════════════════════════════════════════════════════════════
# T31-2 — §18 기존 profile 보존(AC-11): 헬퍼 미호출, 값·바이트 불변
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_config "$ws" '{"profile":"reviewer"}'
before_sha="$(file_sha "$ws/.claude/config.json")"
run_profile "$ws" "web"
after_sha="$(file_sha "$ws/.claude/config.json")"
check "$([[ "$PROFILE_OUT" == *"[/aiops:setup] profile=reviewer 보존 (사용자 명시 또는 이전 설정)"* ]] && echo 1 || echo 0)" "T31-2 기존 profile 보존 문구(S5) 출력"
check "$([[ "$(key_value "$PROFILE_CONFIG" profile)" == "reviewer" ]] && echo 1 || echo 0)" "T31-2 config.profile 값 유지(reviewer)"
check "$([[ "$before_sha" == "$after_sha" ]] && echo 1 || echo 0)" "T31-2 헬퍼 미호출 — config 바이트 불변"
check "$([[ "$PROFILE_OUT" != *"자동 등록"* ]] && echo 1 || echo 0)" "T31-2 '자동 등록' 문구 미출력"

# ══════════════════════════════════════════════════════════════════
# T31-3 — §18 실패 분기(AC-10): profile 미설정 + .claude 쓰기 불가 → F2 WARN
# ══════════════════════════════════════════════════════════════════
if [[ "$IS_ROOT" == "1" ]]; then
  ok "T31-3 §18 실패 분기 (root 실행 — chmod 무력화로 스킵)"
else
  ws=$(new_ws)
  write_config "$ws" '{}'
  before_sha="$(file_sha "$ws/.claude/config.json")"
  chmod 555 "$ws/.claude"
  run_profile "$ws" "web"
  chmod 755 "$ws/.claude" 2>/dev/null || true
  after_sha="$(file_sha "$ws/.claude/config.json")"
  check "$([[ "$PROFILE_OUT" == *"[setup] §18 WARN: profile 기입 실패 — 위 오류를 확인하세요"* ]] && echo 1 || echo 0)" "T31-3 F2 WARN 문구 출력"
  check "$([[ "$PROFILE_OUT" != *"자동 등록"* ]] && echo 1 || echo 0)" "T31-3 '자동 등록' 문구 미출력"
  check "$([[ "$before_sha" == "$after_sha" ]] && echo 1 || echo 0)" "T31-3 config 바이트 불변"
fi

# ══════════════════════════════════════════════════════════════════
# T31-4 — §18 PLATFORM 빈 값 → case 의 * 분기로 AUTO_PROFILE=minimal 결정 후 등록
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_config "$ws" '{}'
run_profile "$ws" ""
check "$([[ "$(key_value "$PROFILE_CONFIG" profile)" == "minimal" ]] && echo 1 || echo 0)" "T31-4 PLATFORM 빈 값 → profile=minimal 자동 결정"
check "$([[ "$PROFILE_OUT" == *"[/aiops:setup] profile=minimal 자동 등록 (#161)"* ]] && echo 1 || echo 0)" "T31-4 minimal 등록 성공 문구 출력"

# ══════════════════════════════════════════════════════════════════
# T31-5 (이슈 #16) — §18 PLATFORM=cli → 전용 프로필 신설 없이 표준 web 세트 재사용
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
write_config "$ws" '{}'
run_profile "$ws" "cli"
check "$([[ "$(key_value "$PROFILE_CONFIG" profile)" == "web" ]] && echo 1 || echo 0)" "T31-5 PLATFORM=cli → profile=web 자동 결정 (#16)"
check "$([[ "$PROFILE_OUT" == *"[/aiops:setup] profile=web 자동 등록 (#161)"* ]] && echo 1 || echo 0)" "T31-5 web 등록 성공 문구 출력"

# ══════════════════════════════════════════════════════════════════
# T32 — §5(tech_stack) 호출부: 전용 앵커 없음 → 코드펜스 전체를 위치-무관하게
#        추출해 정적 검사 + 가능한 범위에서 동적 실패/성공 검증을 함께 수행한다.
# ══════════════════════════════════════════════════════════════════
line5="$(grep -Fn "_config_update '.tech_stack = \$ts'" "$SETUP_SKILL" | grep -v '^[0-9]*:[[:space:]]*#' | head -1 | cut -d: -f1)"
BLOCK5="$(fence_block "$SETUP_SKILL" "${line5:-0}")"
check "$([[ -n "$BLOCK5" && "$BLOCK5" == *'if !'* && "$BLOCK5" == *'§5 WARN: tech_stack 기입 실패'* ]] && echo 1 || echo 0)" "T32 §5 코드펜스에 if-가드 + F3 WARN 문구 존재(정적)"

if [[ -z "$BLOCK5" ]]; then
  notok "T32 §5 코드펜스 추출 실패 — 동적 검증 불가(정적 검사만 적용). 사유: §5 호출부는 전용 앵커가 없어 코드펜스 경계로만 추출 가능한데 이번 추출이 실패했다"
elif [[ "$IS_ROOT" == "1" ]]; then
  ok "T32 §5 동적 실패 분기 (root 실행 — chmod 무력화로 스킵)"
else
  ws=$(new_ws)
  write_config "$ws" '{}'
  before_sha="$(file_sha "$ws/.claude/config.json")"
  chmod 555 "$ws/.claude"
  code5="$HELPER_CODE"$'\n'"$BLOCK5"
  T32_FAIL_OUT="$( (cd "$ws" && eval "$code5") 2>&1 )"
  chmod 755 "$ws/.claude" 2>/dev/null || true
  after_sha="$(file_sha "$ws/.claude/config.json")"
  check "$([[ "$T32_FAIL_OUT" == *"[setup] §5 WARN: tech_stack 기입 실패 — 위 오류를 확인하세요"* ]] && echo 1 || echo 0)" "T32 §5 실패 시 F3 WARN 출력(동적)"
  check "$([[ "$before_sha" == "$after_sha" ]] && echo 1 || echo 0)" "T32 §5 config 바이트 불변(동적)"
fi

if [[ -n "$BLOCK5" ]]; then
  ws=$(new_ws)
  write_config "$ws" '{}'
  code5ok="$HELPER_CODE"$'\n'"$BLOCK5"
  T32_OK_OUT="$( (cd "$ws" && eval "$code5ok") 2>&1 )"
  ts_val="$(jq -c '.tech_stack' "$ws/.claude/config.json" 2>/dev/null)"
  check "$([[ -z "$T32_OK_OUT" ]] && echo 1 || echo 0)" "T32 §5 성공 시 무출력(M-3)"
  check "$([[ -n "$ts_val" && "$ts_val" != "null" ]] && echo 1 || echo 0)" "T32 §5 성공 시 tech_stack 기입됨"
fi

# ══════════════════════════════════════════════════════════════════
# T33 — §13(agent_hints) 호출부: 전용 앵커 없음 → T32 와 동일한 방식으로 검증
# ══════════════════════════════════════════════════════════════════
line13="$(grep -Fn "_config_update '.agent_hints = \$hints'" "$SETUP_SKILL" | head -1 | cut -d: -f1)"
BLOCK13="$(fence_block "$SETUP_SKILL" "${line13:-0}")"
check "$([[ -n "$BLOCK13" && "$BLOCK13" == *'if !'* && "$BLOCK13" == *'§13 WARN: agent_hints 기입 실패'* ]] && echo 1 || echo 0)" "T33 §13 코드펜스에 if-가드 + F4 WARN 문구 존재(정적)"

if [[ -z "$BLOCK13" ]]; then
  notok "T33 §13 코드펜스 추출 실패 — 동적 검증 불가(정적 검사만 적용). 사유: §13 호출부는 전용 앵커가 없어 코드펜스 경계로만 추출 가능한데 이번 추출이 실패했다"
elif [[ "$IS_ROOT" == "1" ]]; then
  ok "T33 §13 동적 실패 분기 (root 실행 — chmod 무력화로 스킵)"
else
  ws=$(new_ws)
  write_config "$ws" '{}'
  before_sha="$(file_sha "$ws/.claude/config.json")"
  chmod 555 "$ws/.claude"
  code13="$HELPER_CODE"$'\n'"AGENT_HINTS_JSON='{\"backend\":{\"framework\":\"fastapi\"}}'"$'\n'"$BLOCK13"
  T33_FAIL_OUT="$( (cd "$ws" && eval "$code13") 2>&1 )"
  chmod 755 "$ws/.claude" 2>/dev/null || true
  after_sha="$(file_sha "$ws/.claude/config.json")"
  check "$([[ "$T33_FAIL_OUT" == *"[setup] §13 WARN: agent_hints 기입 실패 — 위 오류를 확인하세요"* ]] && echo 1 || echo 0)" "T33 §13 실패 시 F4 WARN 출력(동적)"
  check "$([[ "$before_sha" == "$after_sha" ]] && echo 1 || echo 0)" "T33 §13 config 바이트 불변(동적)"
fi

if [[ -n "$BLOCK13" ]]; then
  ws=$(new_ws)
  write_config "$ws" '{}'
  code13ok="$HELPER_CODE"$'\n'"AGENT_HINTS_JSON='{\"backend\":{\"framework\":\"fastapi\"}}'"$'\n'"$BLOCK13"
  T33_OK_OUT="$( (cd "$ws" && eval "$code13ok") 2>&1 )"
  fw_check="$(jq -r '.agent_hints.backend.framework' "$ws/.claude/config.json" 2>/dev/null)"
  check "$([[ -z "$T33_OK_OUT" ]] && echo 1 || echo 0)" "T33 §13 성공 시 무출력(M-3)"
  check "$([[ "$fw_check" == "fastapi" ]] && echo 1 || echo 0)" "T33 §13 성공 시 agent_hints 기입됨"
fi

# ══════════════════════════════════════════════════════════════════
echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
