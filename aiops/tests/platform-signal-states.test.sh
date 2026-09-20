#!/usr/bin/env bash
# platform-signal-states.test.sh — 출시 스킬 §2 전제 표의 platform_signal 세 상태
#
# 결함(zen-koi #32): 코드가 `// "unknown"` 을 기본값으로 쓰는데 표에 그 행이 없어
# **아무 판정 없이 통과**했다. v1.16.1 이전 `/aiops:setup` 이 만든 config 는 이 키가 없다.
#
# #28 에서 분리한 것은 두 상태였지만 실제로는 셋이었다 — 기능을 추가할 때 **이전 산출물이
# 어떤 값을 갖는지**가 빠졌다. 그래서 여기서는 코드의 기본값과 표의 행이 맞는지를 본다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TOTAL=0; PASS=0; FAIL=0
ok()    { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1"; }
notok() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "not ok $TOTAL - $1"; }
check() { [[ "$1" == "1" ]] && ok "$2" || notok "$2"; }

for name in android-release iphone-release; do
  SK="$REPO_ROOT/aiops/skills/$name/SKILL.md"
  if [[ ! -f "$SK" ]]; then
    notok "$name/SKILL.md 이 없어 검증하지 못했습니다 — **검사 불가**"; continue
  fi

  # 코드가 쓰는 기본값을 문서에서 직접 뽑는다 — 값을 테스트에 복사하지 않는다.
  DEFAULT=$(grep -o "platform_signal // \"[a-z]*\"" "$SK" | head -1 | sed 's/.*"\(.*\)"/\1/')
  check "$([[ -n "$DEFAULT" ]] && echo 1)" "$name: 기본값을 문서에서 읽었다 (${DEFAULT:-못 읽음})"

  # **그 기본값을 받는 행이 표에 있어야 한다.** 없으면 아무 판정 없이 통과한다.
  check "$(grep -q "\`platform_signal\` 이 \`$DEFAULT\`" "$SK" && echo 1)" \
        "$name: 기본값 '$DEFAULT' 을 받는 행이 표에 있다"

  check "$(grep -q '`platform_signal` 이 `none (fallback)`' "$SK" && echo 1)" \
        "$name: none (fallback) 행이 있다"

  # 두 행의 처방이 달라야 한다 — 같으면 구별한 의미가 없다
  UNK=$(grep "\`platform_signal\` 이 \`$DEFAULT\`" "$SK" | head -1)
  NONE=$(grep '`platform_signal` 이 `none (fallback)`' "$SK" | head -1)
  check "$([[ -n "$UNK" && -n "$NONE" && "${UNK#*|}" != "${NONE#*|}" ]] && echo 1)" \
        "$name: unknown 과 none (fallback) 의 처방이 서로 다르다"

  # unknown 의 처방은 '사람 확인' 이 아니라 재실행이어야 한다 (자동 해소 가능한 상태)
  check "$(echo "$UNK" | grep -q 'setup' && echo 1)" \
        "$name: unknown 행이 /aiops:setup 재실행을 안내한다"
  check "$(echo "$NONE" | grep -q '사람' && echo 1)" \
        "$name: none (fallback) 행은 사람 확인을 안내한다"

  # 감지 실패와 기록 부재를 말로 구별하는가
  check "$(grep -q '기록 부재' "$SK" && echo 1)" "$name: '기록 부재' 라는 구별을 명시한다"
  check "$(grep -q 'pre-v1.16.1' "$SK" && echo 1)" "$name: HANDOFF_VERIFY 예시로 셋을 구별한다"
done

# jq 가 있으면 기본값 동작 자체를 확인한다 — 키 부재가 정말 'unknown' 으로 떨어지는가
if command -v jq >/dev/null 2>&1; then
  T="$(mktemp)"; trap 'rm -f "$T"' EXIT
  echo '{"agent_hints":{"platform":"mobile"}}' > "$T"
  V=$(jq -r '.agent_hints.platform_signal // "unknown"' "$T")
  check "$([[ "$V" == "unknown" ]] && echo 1)" "키가 없으면 jq 가 'unknown' 을 돌려준다 (실측: $V)"
  echo '{"agent_hints":{"platform_signal":"none (fallback)"}}' > "$T"
  V=$(jq -r '.agent_hints.platform_signal // "unknown"' "$T")
  check "$([[ "$V" == "none (fallback)" ]] && echo 1)" "값이 있으면 그 값이 나온다 — 둘은 구별 가능하다"
  # null 이 들어 있는 경우도 unknown 으로 떨어진다 (jq 의 // 는 null 도 대체한다)
  echo '{"agent_hints":{"platform_signal":null}}' > "$T"
  V=$(jq -r '.agent_hints.platform_signal // "unknown"' "$T")
  check "$([[ "$V" == "unknown" ]] && echo 1)" "명시적 null 도 unknown 으로 떨어진다 (실측: $V)"
else
  notok "jq 가 없어 기본값 동작을 확인하지 못했습니다 — **검사 불가**"
fi

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
