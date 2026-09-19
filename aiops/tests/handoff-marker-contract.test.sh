#!/usr/bin/env bash
# handoff-marker-contract.test.sh — docs/contracts/handoff-marker.md
#
# 계약 문서의 불변식을 기계적으로 강제한다. 충돌 검토를 문서에만 적으면
# 다음 토큰을 추가할 때 잊는다 — v1.11.0 의 PASS_DRY_RUN 이 그렇게 생겼다.
#
# 순수 bash(3.2 호환). aiops/tests/setup-platform-detect.test.sh 규약을 따른다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONTRACT="$REPO_ROOT/docs/contracts/handoff-marker.md"
SKILLS_DIR="$REPO_ROOT/aiops/skills"

TOTAL=0; PASS=0; FAIL=0
ok()    { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1"; }
notok() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "not ok $TOTAL - $1"; }
check() { [[ "$1" == "1" ]] && ok "$2" || notok "$2"; }

if [[ ! -f "$CONTRACT" ]]; then
  notok "계약 문서 없음: docs/contracts/handoff-marker.md"
  echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"; exit 1
fi

# ── 계약이 선언한 HANDOFF 토큰 이름 ──────────────────────────────────
# 숫자를 포함한다 — HANDOFF_E2E_RESULT 같은 이름을 HANDOFF_E 로 자르면
# 충돌 검사가 헛돈다(이 테스트를 변이로 검증하다 발견).
HANDOFF_TOKENS="$(grep -oE 'HANDOFF_[A-Z0-9_]+' "$CONTRACT" | sed 's/_$//' | sort -u)"

# ── 기존 게이트가 grep 하는 판정 토큰 ────────────────────────────────
# 이름(= 앞)과 전체(이름=값) 둘 다 모은다. 충돌은 어느 수준에서도 일어난다.
EXISTING_FULL="$(grep -rhoE '(E2E_RESULT|PROD_RESULT|E2E_ENV_ERROR)=[A-Za-z_]+' \
                 "$SKILLS_DIR"/*/SKILL.md 2>/dev/null | sort -u)"
EXISTING_NAMES="$(printf '%s\n' "$EXISTING_FULL" | cut -d= -f1 | sort -u)"
EXISTING_TOKENS="$(printf '%s\n%s\n' "$EXISTING_FULL" "$EXISTING_NAMES" | grep -v '^$' | sort -u)"

# ══════════════════════════════════════════════════════════════════
# H1 — 계약이 네 토큰을 모두 선언한다
# ══════════════════════════════════════════════════════════════════
for t in HANDOFF_REQUIRED HANDOFF_DECISION HANDOFF_ACCESS HANDOFF_VERIFY HANDOFF_CLEARED; do
  check "$(printf '%s\n' "$HANDOFF_TOKENS" | grep -qx "$t" && echo 1 || echo 0)" \
        "H1 계약이 $t 를 선언"
done

# ══════════════════════════════════════════════════════════════════
# H2 — 기존 토큰이 HANDOFF 토큰의 부분 문자열이 아니다
#      (기존 게이트가 새 마커 줄에 걸리면 안 된다)
# ══════════════════════════════════════════════════════════════════
_collide=""
for h in $HANDOFF_TOKENS; do
  for e in $EXISTING_TOKENS; do
    case "$h" in *"$e"*) _collide="$_collide $h⊃$e" ;; esac
  done
done
check "$([[ -z "$_collide" ]] && echo 1 || echo 0)" \
      "H2 기존 판정 토큰이 HANDOFF 토큰에 포함되지 않음${_collide:+ (충돌:$_collide)}"

# ══════════════════════════════════════════════════════════════════
# H3 — HANDOFF 토큰이 기존 토큰의 부분 문자열이 아니다 (역방향)
# ══════════════════════════════════════════════════════════════════
_rev=""
for e in $EXISTING_TOKENS; do
  for h in $HANDOFF_TOKENS; do
    case "$e" in *"$h"*) _rev="$_rev $e⊃$h" ;; esac
  done
done
check "$([[ -z "$_rev" ]] && echo 1 || echo 0)" \
      "H3 HANDOFF 토큰이 기존 토큰에 포함되지 않음${_rev:+ (충돌:$_rev)}"

# ══════════════════════════════════════════════════════════════════
# H4 — HANDOFF 토큰끼리 부분 문자열 관계가 없다
#      REQUIRED 를 grep 하는 게이트가 CLEARED 에 걸리면 안 된다
# ══════════════════════════════════════════════════════════════════
_self=""
for a in $HANDOFF_TOKENS; do
  for b in $HANDOFF_TOKENS; do
    [[ "$a" == "$b" ]] && continue
    case "$a" in *"$b"*) _self="$_self $a⊃$b" ;; esac
  done
done
check "$([[ -z "$_self" ]] && echo 1 || echo 0)" \
      "H4 HANDOFF 토큰끼리 포함 관계 없음${_self:+ (충돌:$_self)}"

# ══════════════════════════════════════════════════════════════════
# H5 — 헤더 이모지가 기존 마커 헤더와 겹치지 않는다
# ══════════════════════════════════════════════════════════════════
EXISTING_HEADERS="$(grep -rhoE '\^## [^ ]+ ' "$SKILLS_DIR"/*/SKILL.md 2>/dev/null \
                    | sed 's/^\^## //' | sort -u)"
for emo in "⏸️" "✅"; do
  check "$(printf '%s\n' "$EXISTING_HEADERS" | grep -qF "$emo" && echo 0 || echo 1)" \
        "H5 헤더 이모지 $emo 가 기존 마커와 겹치지 않음"
done

# ══════════════════════════════════════════════════════════════════
# H6 — 규약 4종이 문서에 모두 있다 (누락 방지)
# ══════════════════════════════════════════════════════════════════
for rule in "규약 1" "규약 2" "규약 3" "규약 4"; do
  check "$(grep -q "$rule" "$CONTRACT" && echo 1 || echo 0)" "H6 $rule 이 계약에 존재"
done

# ══════════════════════════════════════════════════════════════════
# H7 — REQUIRED 와 DECISION 을 나눈 이유가 명시돼 있다
#      (합치자는 제안이 다시 나왔을 때 근거가 남아 있어야 한다)
# ══════════════════════════════════════════════════════════════════
check "$(grep -q '스킬의 의무가 사라진다' "$CONTRACT" && echo 1 || echo 0)" \
      "H7 REQUIRED/DECISION 분리 근거가 문서에 남아 있음"

# ══════════════════════════════════════════════════════════════════
# H8 — 계약 #1 통지 의무가 명시돼 있다
# ══════════════════════════════════════════════════════════════════
check "$(grep -q '통지 대상' "$CONTRACT" && echo 1 || echo 0)" \
      "H8 aiops-codex 통지 의무가 명시됨"

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]] && exit 0 || exit 1
