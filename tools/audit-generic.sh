#!/bin/bash
# 범용성 감사 — 특정 조직·앱·기계·경로를 지칭하는 것이 남았는지
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
rc=0

check() { # <라벨> <정규식> [허용파일정규식]
  local label="$1" pat="$2" allow="${3:-__none__}"
  local hits
  # 자기 자신(패턴 목록)은 제외한다 — 안 그러면 감사 스크립트가 스스로를 신고한다.
  hits=$(grep -rniE "$pat" aiops/ tools/ docs/ README.md 2>/dev/null \
         | grep -v '^tools/audit-generic.sh:' | grep -vE "$allow" || true)
  if [[ -n "$hits" ]]; then
    echo "❌ $label"; echo "$hits" | sed 's/^/     /' | head -8; rc=1
  else
    echo "✅ $label"
  fi
}

echo "── 조직·호스트 ──"
check "조직명(devworld)" "devworld" "plugin\.json|README\.md|plugin\.json|docs/USAGE\.md|NOTICE"
check "사내 호스트(git.devworld.co.kr)" "git\.devworld\.co\.kr" "README\.md|plugin\.json|docs/USAGE\.md"
check "특정 기계명(macstudio)" "macstudio"

echo "── 특정 앱 이름 ──"
check "devworld 앱 이름" "scan2md|ai-photo-studio|requirement-manager|news-brief|notify-hub|ai-movie|task-queue|blog-automation|email-template|workflow-maker|images2prompt|audio-newsletter"

echo "── 로컬 절대경로 ──"
check "사용자 홈 경로" "/Users/[a-z]+|~/src/"

echo "── 거래처·고객 실명 ──"
check "외부 호출자명(laonnuri)" "laonnuri"

echo "── 특정 인프라 하드 전제 ──"
check "CF 기본값 true" "use_cloudflare_workers // true"

echo
echo "── 참고: 예시로 남긴 것(허용) ──"
grep -rn "git.devworld.co.kr" README.md docs/USAGE.md 2>/dev/null | sed 's/^/     /' | head -4
exit $rc
