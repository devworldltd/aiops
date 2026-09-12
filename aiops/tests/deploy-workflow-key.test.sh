#!/usr/bin/env bash
# deploy-workflow-key.test.sh — deploy_workflow_prod 키 지원(이슈 #33) 검증.
#
# 기술 스펙 §8(테스트 설계) T1~T19 + 보강 T20/T21 구현. 리졸버를 재구현하지 않고
# aiops/skills/{deploy-prod,verify-deploy}/SKILL.md 의 앵커 주석
#   # >>> workflow-resolve:prod >>> / # <<< workflow-resolve:prod <<<   (deploy-prod)
#   # >>> workflow-resolve:env >>>  / # <<< workflow-resolve:env <<<    (verify-deploy)
# 사이 코드를 awk 로 추출해 eval 한다 — 문서(마크다운 bash 블록)와 실제 동작이
# 갈라지는 사고를 원천 차단한다(D-4).
#
# setup 감지(S-1/S-2, T22/T23 제안)는 aiops:dev-frontend 담당 범위이므로 본 파일에서
# 다루지 않는다(작업 지시 §2 명시). T20(공백 trim)·T21(비문자열 타입) 은 본 파일에서 보강.
#
# 출력 규약(forge-reviewer-token.test.sh 와 동일): `ok N - <설명>` / `not ok N - <설명>`,
# 마지막 줄 `TESTS=<총> PASS=<n> FAIL=<n>`. 전건 통과 exit 0 / 1건 이상 실패 exit 1.
# 순수 bash 3.2, 네트워크 호출 없음, 픽스처는 mktemp -d 아래에만 쓴다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_PROD_SKILL="$REPO_ROOT/aiops/skills/deploy-prod/SKILL.md"
VERIFY_DEPLOY_SKILL="$REPO_ROOT/aiops/skills/verify-deploy/SKILL.md"
MERGE_PR_SKILL="$REPO_ROOT/aiops/skills/merge-pr/SKILL.md"
USAGE_DOC="$REPO_ROOT/docs/USAGE.md"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/deploy-workflow-key-test.XXXXXX")"
cleanup() { rm -rf "$TMPBASE"; }
trap cleanup EXIT

# ── 테스트 하네스 (forge-reviewer-token.test.sh 규약 그대로) ─────────────
TOTAL=0; PASS=0; FAIL=0
ok()    { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1"; }
notok() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "not ok $TOTAL - $1"; }
check() { [[ "$1" == "1" ]] && ok "$2" || notok "$2"; }

# ── 앵커 블록 추출 (D-4) ─────────────────────────────────────────────
extract_block() {   # $1=파일, $2=앵커 이름 (예: workflow-resolve:prod)
  awk -v a=">>> $2 >>>" -v b="<<< $2 <<<" '
    index($0,a){f=1;next} index($0,b){f=0} f' "$1"
}

# ── 리졸버 평가: $1=eval 할 코드, $2=fixture 작업 디렉터리(.claude/config.json 위치) ──
# 구분자는 스페이스가 아니라 유닛 구분자(\x1f)를 쓴다 — WORKFLOW 값 자체에 공백이
# 들어있는 케이스(T20)에서 파싱이 깨지지 않게 하기 위함.
RS=$'\x1f'
resolve() {
  local code="$1" dir="$2"
  ( cd "$dir" && eval "$code" >/dev/null 2>&1; printf '%s\x1f%s' "${WORKFLOW-}" "${WORKFLOW_SOURCE-}" )
}
split_workflow() { printf '%s' "${1%%$RS*}"; }
split_source()   { printf '%s' "${1#*$RS}"; }

PROD_BLOCK="$(extract_block "$DEPLOY_PROD_SKILL" "workflow-resolve:prod")"
ENV_BLOCK="$(extract_block "$VERIFY_DEPLOY_SKILL" "workflow-resolve:env")"

DEV_KEYS_LINE='WORKFLOW_KEYS="deploy_workflow github_actions_workflow"'
PROD_KEYS_LINE='WORKFLOW_KEYS="deploy_workflow_prod deploy_workflow github_actions_workflow"'

DEV_VIA_VERIFY="$DEV_KEYS_LINE"$'\n'"$ENV_BLOCK"
PROD_VIA_VERIFY="$PROD_KEYS_LINE"$'\n'"$ENV_BLOCK"

# fixture 준비 헬퍼: $1=작업 디렉터리, $2=config.json 내용("__NOFILE__"면 파일 미생성, "__BROKEN__"이면 깨진 JSON)
mk_fixture() {
  local dir="$1" content="$2"
  rm -rf "$dir"
  mkdir -p "$dir/.claude"
  case "$content" in
    __NOFILE__) rm -rf "$dir/.claude" ;;
    __BROKEN__) printf '%s' '{"deploy_workflow":' > "$dir/.claude/config.json" ;;
    *) printf '%s' "$content" > "$dir/.claude/config.json" ;;
  esac
}

assert_pair() {   # $1=case label, $2=실제 "WORKFLOW\x1fSOURCE", $3=기대 workflow, $4=기대 source
  local label="$1" actual="$2" ew="$3" es="$4"
  local aw as
  aw="$(split_workflow "$actual")"; as="$(split_source "$actual")"
  check "$([[ "$aw" == "$ew" && "$as" == "$es" ]] && echo 1 || echo 0)" \
    "$label (실측 workflow=[$aw] source=[$as], 기대 workflow=[$ew] source=[$es])"
}

# ══════════════════════════════════════════════════════════════════
# T1 — {} → 3경로 모두 deploy-cf.yml + source=default (AC-1)
# ══════════════════════════════════════════════════════════════════
mk_fixture "$TMPBASE/t1" '{}'
assert_pair "T1 dev" "$(resolve "$DEV_VIA_VERIFY" "$TMPBASE/t1")" "deploy-cf.yml" "default"
assert_pair "T1 prod(verify-deploy)" "$(resolve "$PROD_VIA_VERIFY" "$TMPBASE/t1")" "deploy-cf.yml" "default"
assert_pair "T1 deploy-prod" "$(resolve "$PROD_BLOCK" "$TMPBASE/t1")" "deploy-cf.yml" "default"

# ══════════════════════════════════════════════════════════════════
# T2 — {"deploy_workflow":"deploy-cf.yml"} → dev/prod 모두 deploy-cf.yml (AC-2)
# ══════════════════════════════════════════════════════════════════
mk_fixture "$TMPBASE/t2" '{"deploy_workflow":"deploy-cf.yml"}'
assert_pair "T2 dev" "$(resolve "$DEV_VIA_VERIFY" "$TMPBASE/t2")" "deploy-cf.yml" "deploy_workflow"
assert_pair "T2 prod" "$(resolve "$PROD_VIA_VERIFY" "$TMPBASE/t2")" "deploy-cf.yml" "deploy_workflow"

# ══════════════════════════════════════════════════════════════════
# T3 — {"github_actions_workflow":"legacy.yml"} → dev/prod 모두 legacy.yml (AC-3)
# ══════════════════════════════════════════════════════════════════
mk_fixture "$TMPBASE/t3" '{"github_actions_workflow":"legacy.yml"}'
assert_pair "T3 dev" "$(resolve "$DEV_VIA_VERIFY" "$TMPBASE/t3")" "legacy.yml" "github_actions_workflow"
assert_pair "T3 prod" "$(resolve "$PROD_VIA_VERIFY" "$TMPBASE/t3")" "legacy.yml" "github_actions_workflow"

# ══════════════════════════════════════════════════════════════════
# T4 — {"deploy_workflow":"a.yml","github_actions_workflow":"legacy.yml"} → a.yml (AC-4)
# ══════════════════════════════════════════════════════════════════
mk_fixture "$TMPBASE/t4" '{"deploy_workflow":"a.yml","github_actions_workflow":"legacy.yml"}'
assert_pair "T4 dev" "$(resolve "$DEV_VIA_VERIFY" "$TMPBASE/t4")" "a.yml" "deploy_workflow"
assert_pair "T4 prod" "$(resolve "$PROD_VIA_VERIFY" "$TMPBASE/t4")" "a.yml" "deploy_workflow"

# ══════════════════════════════════════════════════════════════════
# T5/T6/T7 — AC-5 config: dev 회귀 게이트 + prod 신규 1단 + 두 스킬 동치
# ══════════════════════════════════════════════════════════════════
AC5='{"deploy_workflow":"deploy-dev.yml","deploy_workflow_prod":"deploy-prod.yml"}'
mk_fixture "$TMPBASE/t5" "$AC5"
assert_pair "T5 dev(회귀 게이트)" "$(resolve "$DEV_VIA_VERIFY" "$TMPBASE/t5")" "deploy-dev.yml" "deploy_workflow"
assert_pair "T6 prod(verify-deploy)" "$(resolve "$PROD_VIA_VERIFY" "$TMPBASE/t5")" "deploy-prod.yml" "deploy_workflow_prod"
assert_pair "T7 deploy-prod(두 스킬 동치)" "$(resolve "$PROD_BLOCK" "$TMPBASE/t5")" "deploy-prod.yml" "deploy_workflow_prod"

# ══════════════════════════════════════════════════════════════════
# T8/T9 — {"deploy_workflow_prod":"deploy-prod.yml"} (AC-6): dev 열은 누수 없이 default
# ══════════════════════════════════════════════════════════════════
AC6='{"deploy_workflow_prod":"deploy-prod.yml"}'
mk_fixture "$TMPBASE/t8" "$AC6"
assert_pair "T8 dev(prod 키 누수 없음)" "$(resolve "$DEV_VIA_VERIFY" "$TMPBASE/t8")" "deploy-cf.yml" "default"
assert_pair "T9 prod" "$(resolve "$PROD_VIA_VERIFY" "$TMPBASE/t8")" "deploy-prod.yml" "deploy_workflow_prod"

# ══════════════════════════════════════════════════════════════════
# T10 — {"deploy_workflow_prod":null,"deploy_workflow":"a.yml"} → prod=a.yml (AC-7, null 엣지)
# ══════════════════════════════════════════════════════════════════
mk_fixture "$TMPBASE/t10" '{"deploy_workflow_prod":null,"deploy_workflow":"a.yml"}'
assert_pair "T10 prod(null 엣지)" "$(resolve "$PROD_VIA_VERIFY" "$TMPBASE/t10")" "a.yml" "deploy_workflow"

# ══════════════════════════════════════════════════════════════════
# T11 — {"deploy_workflow_prod":"","deploy_workflow":"a.yml"} → prod=a.yml (AC-8, D-1 핵심)
# ══════════════════════════════════════════════════════════════════
mk_fixture "$TMPBASE/t11" '{"deploy_workflow_prod":"","deploy_workflow":"a.yml"}'
assert_pair "T11 prod(빈 문자열 엣지 — D-1 핵심)" "$(resolve "$PROD_VIA_VERIFY" "$TMPBASE/t11")" "a.yml" "deploy_workflow"

# ══════════════════════════════════════════════════════════════════
# T12/T13 — {"deploy_workflow_prod":"p.yml","github_actions_workflow":"legacy.yml"} (AC-9)
# ══════════════════════════════════════════════════════════════════
AC9='{"deploy_workflow_prod":"p.yml","github_actions_workflow":"legacy.yml"}'
mk_fixture "$TMPBASE/t12" "$AC9"
assert_pair "T12 dev(prod 키 누수 없음)" "$(resolve "$DEV_VIA_VERIFY" "$TMPBASE/t12")" "legacy.yml" "github_actions_workflow"
assert_pair "T13 prod" "$(resolve "$PROD_VIA_VERIFY" "$TMPBASE/t12")" "p.yml" "deploy_workflow_prod"

# ══════════════════════════════════════════════════════════════════
# T14 — config 파일 부재 → dev/prod 모두 deploy-cf.yml + default, 에러 미전파 (D-1a)
# ══════════════════════════════════════════════════════════════════
mk_fixture "$TMPBASE/t14" '__NOFILE__'
assert_pair "T14 dev(config 부재)" "$(resolve "$DEV_VIA_VERIFY" "$TMPBASE/t14")" "deploy-cf.yml" "default"
assert_pair "T14 prod(config 부재)" "$(resolve "$PROD_VIA_VERIFY" "$TMPBASE/t14")" "deploy-cf.yml" "default"

# ══════════════════════════════════════════════════════════════════
# T15 — 깨진 JSON → prod=deploy-cf.yml + default (파싱 실패 폴백)
# ══════════════════════════════════════════════════════════════════
mk_fixture "$TMPBASE/t15" '__BROKEN__'
assert_pair "T15 prod(깨진 JSON 폴백)" "$(resolve "$PROD_VIA_VERIFY" "$TMPBASE/t15")" "deploy-cf.yml" "default"

# ══════════════════════════════════════════════════════════════════
# T16 — 정적 검사: merge-pr/SKILL.md 에 deploy_workflow_prod 문자열 0회 (M-3 무변경 가드)
# ══════════════════════════════════════════════════════════════════
merge_pr_hits=$(grep -c "deploy_workflow_prod" "$MERGE_PR_SKILL" 2>/dev/null)
merge_pr_hits="${merge_pr_hits:-0}"
check "$([[ "$merge_pr_hits" == "0" ]] && echo 1 || echo 0)" "T16 merge-pr/SKILL.md 에 deploy_workflow_prod 0회 (실측 ${merge_pr_hits}회, M-3)"

merge_pr_line205=$(sed -n '205p' "$MERGE_PR_SKILL")
check "$([[ "$merge_pr_line205" == 'WORKFLOW=$(jq -r '"'"'.deploy_workflow // .github_actions_workflow // "deploy-cf.yml"'"'"' .claude/config.json)' ]] && echo 1 || echo 0)" \
  "T16b merge-pr/SKILL.md 205행 원문 무변경"

# ══════════════════════════════════════════════════════════════════
# T17 — 정적 검사: verify-deploy §2.2 dev 갈래의 WORKFLOW_KEYS 에 deploy_workflow_prod 미포함
# ══════════════════════════════════════════════════════════════════
dev_keys_hits=$(grep -c 'deploy_workflow_prod' <<<"$DEV_KEYS_LINE")
check "$([[ "$dev_keys_hits" == "0" ]] && echo 1 || echo 0)" "T17 verify-deploy dev 갈래 WORKFLOW_KEYS 에 deploy_workflow_prod 미포함"
dev_keys_present=$(grep -c "$DEV_KEYS_LINE" "$VERIFY_DEPLOY_SKILL")
check "$([[ "$dev_keys_present" -ge 1 ]] && echo 1 || echo 0)" "T17b verify-deploy 파일 내 dev WORKFLOW_KEYS 라인 실존"

# ══════════════════════════════════════════════════════════════════
# T18 — 정적 검사: 앵커 쌍이 각 1개씩 존재(추출 가능) — 테스트 자기 검증
# ══════════════════════════════════════════════════════════════════
prod_open=$(grep -c ">>> workflow-resolve:prod >>>" "$DEPLOY_PROD_SKILL")
prod_close=$(grep -c "<<< workflow-resolve:prod <<<" "$DEPLOY_PROD_SKILL")
env_open=$(grep -c ">>> workflow-resolve:env >>>" "$VERIFY_DEPLOY_SKILL")
env_close=$(grep -c "<<< workflow-resolve:env <<<" "$VERIFY_DEPLOY_SKILL")
check "$([[ "$prod_open" == "1" && "$prod_close" == "1" ]] && echo 1 || echo 0)" "T18 deploy-prod workflow-resolve:prod 앵커 쌍 각 1개"
check "$([[ "$env_open" == "1" && "$env_close" == "1" ]] && echo 1 || echo 0)" "T18b verify-deploy workflow-resolve:env 앵커 쌍 각 1개"
check "$([[ -n "$PROD_BLOCK" ]] && echo 1 || echo 0)" "T18c deploy-prod 앵커 사이 코드 추출 가능(비어있지 않음)"
check "$([[ -n "$ENV_BLOCK" ]] && echo 1 || echo 0)" "T18d verify-deploy 앵커 사이 코드 추출 가능(비어있지 않음)"
# 마크다운 코드펜스 줄(```)이 추출 블록에 섞이지 않았는지 확인
check "$([[ "$PROD_BLOCK" != *'```'* ]] && echo 1 || echo 0)" "T18e deploy-prod 추출 블록에 코드펜스 줄 미포함"
check "$([[ "$ENV_BLOCK" != *'```'* ]] && echo 1 || echo 0)" "T18f verify-deploy 추출 블록에 코드펜스 줄 미포함"

# ══════════════════════════════════════════════════════════════════
# T19 — 정적 검사: docs/USAGE.md 우선순위 표 prod 행 키 순서가 실제 WORKFLOW_KEYS 와 일치 (AC-R9)
# ══════════════════════════════════════════════════════════════════
prod_keys_str=$(sed -E 's/.*WORKFLOW_KEYS="([^"]*)".*/\1/' <<<"$PROD_KEYS_LINE")
usage_prod_row=$(grep -F -- '--env=prod' "$USAGE_DOC" | grep -F 'deploy_workflow_prod' | head -1)
order_ok=1
search_from=1
for k in $prod_keys_str; do
  idx=$(awk -v l="$usage_prod_row" -v k="$k" -v from="$search_from" \
    'BEGIN{print index(substr(l,from),k)}')
  if [[ "$idx" -eq 0 ]]; then
    order_ok=0
  else
    abs_idx=$((search_from + idx - 1))
    search_from=$((abs_idx + ${#k}))
  fi
done
check "$([[ -n "$usage_prod_row" ]] && echo 1 || echo 0)" "T19 docs/USAGE.md 에 prod 우선순위 행 존재"
check "$([[ "$order_ok" == "1" ]] && echo 1 || echo 0)" "T19b docs/USAGE.md prod 행 키 순서가 WORKFLOW_KEYS($prod_keys_str) 와 일치"

# ══════════════════════════════════════════════════════════════════
# T20(보강) — 공백만 있는 문자열 {"deploy_workflow_prod":"   "} → D-1 은 trim 하지 않는다
# 확정: [[ -n "$v" ]] 는 공백 문자열도 "설정됨"으로 판정한다(기술 스펙이 trim 로직을 명시하지
# 않았고, D-1 은 오직 empty/null/"" 만 미설정으로 정의). 본 케이스로 그 동작을 고정한다.
# ══════════════════════════════════════════════════════════════════
mk_fixture "$TMPBASE/t20" '{"deploy_workflow_prod":"   ","deploy_workflow":"a.yml"}'
assert_pair "T20 prod(공백 문자열은 trim 없이 '설정됨'으로 채택 — 스펙 고정)" \
  "$(resolve "$PROD_VIA_VERIFY" "$TMPBASE/t20")" "   " "deploy_workflow_prod"

# ══════════════════════════════════════════════════════════════════
# T21(보강) — 비문자열 타입({"deploy_workflow_prod":123}) 도 jq -r 로 문자열화되어
# actions-wait.sh --workflow 인자가 깨지지 않아야 한다(공백·개행 없이 단일 토큰).
# ══════════════════════════════════════════════════════════════════
mk_fixture "$TMPBASE/t21" '{"deploy_workflow_prod":123}'
t21_out=$(resolve "$PROD_VIA_VERIFY" "$TMPBASE/t21")
t21_wf="$(split_workflow "$t21_out")"; t21_src="$(split_source "$t21_out")"
check "$([[ "$t21_wf" == "123" && "$t21_src" == "deploy_workflow_prod" ]] && echo 1 || echo 0)" \
  "T21 비문자열 타입(숫자)도 안전하게 단일 토큰으로 해석 (실측 workflow=$t21_wf source=$t21_src)"
check "$([[ "$t21_wf" != *$'\n'* && "$t21_wf" != *" "* ]] && echo 1 || echo 0)" \
  "T21b WORKFLOW 값에 공백/개행 없음(--workflow 인자 안전)"

# ══════════════════════════════════════════════════════════════════
echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
