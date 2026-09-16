#!/usr/bin/env bash
# release.sh — aiops 배포 태그의 **단일 소유자**.
#
#   tools/release.sh v1.4.0        # vX.Y.Z 생성 + latest 이동 + 푸시
#   DRY=1 tools/release.sh v1.4.0  # 무엇이 나갈지만 출력
#
# 왜 스크립트인가:
#   ① `latest` 는 손으로 옮기면 **반드시 잊는다.** 그러면 `#latest` 를 핀한 사용자는 낡은 버전을
#      받으면서 최신이라고 믿는다 — 실패처럼 보이지 않는 종류의 사고다.
#   ② 태그와 `plugin.json` 의 `version` 이 어긋나면 캐시 경로
#      (`~/.claude/plugins/cache/aiops/aiops/<version>/`)가 옛 디렉토리를 재사용해 갱신이 조용히
#      실패한다. 그래서 여기서 **일치를 강제**한다.
#
# 전제: 버전 올림은 이미 PR 로 main 에 머지돼 있다(이 스크립트는 커밋하지 않는다 — 태그만 만든다).
set -uo pipefail

MODE=release
if [[ "${1:-}" == "--sync-latest" ]]; then MODE=sync; shift; fi
# 공개 게시만 재실행(사내 태그는 이미 있음). 공개 push 가 실패했을 때의 복구 경로.
if [[ "${1:-}" == "--publish-only" ]]; then MODE=publish; shift; fi

TAG="${1:-}"
[[ -z "$TAG" ]] && { echo "사용: tools/release.sh vX.Y.Z | --sync-latest vX.Y.Z   (DRY=1 로 예행)" >&2; exit 2; }
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "태그 형식은 vX.Y.Z 여야 합니다: $TAG" >&2; exit 2; }

ROOT=$(git rev-parse --show-toplevel) || exit 2
cd "$ROOT" || exit 2

# ── 사전 검사 ────────────────────────────────────────────────────────
BR=$(git branch --show-current)
[[ "$BR" == "main" ]] || { echo "main 에서 실행하세요 (현재: $BR)" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "커밋되지 않은 변경이 있습니다." >&2; exit 2; }

git fetch origin main --tags --quiet
LOCAL=$(git rev-parse main); REMOTE=$(git rev-parse origin/main)
[[ "$LOCAL" == "$REMOTE" ]] || { echo "main 이 origin/main 과 다릅니다. 먼저 동기화하세요." >&2; exit 2; }

# ── --sync-latest: 이미 있는 릴리스 태그로 latest 만 맞춘다 ──────────
#   latest 가 드리프트했거나(손으로 태그를 냈다), 과거 태그로 되돌릴 때 쓴다.
if [[ "$MODE" == sync ]]; then
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "$TAG 태그가 없습니다." >&2; exit 2; }
  echo "── latest 동기화 ──"
  echo "  latest : $(git rev-parse --short latest 2>/dev/null || echo '(없음)') → $(git rev-parse --short "$TAG^{commit}") ($TAG)"
  [[ -n "${DRY:-}" ]] && { echo "── DRY=1 — 아무것도 하지 않았습니다."; exit 0; }
  git tag -f latest "$TAG^{commit}" >/dev/null
  git push -f origin latest
  echo "✓ latest → $TAG"
  exit 0
fi

VER=$(python3 -c "import json;print(json.load(open('aiops/.claude-plugin/plugin.json'))['version'])")
[[ "v$VER" == "$TAG" ]] || {
  echo "plugin.json version($VER) 과 태그($TAG) 가 다릅니다." >&2
  echo "  → 버전 올림을 먼저 PR 로 머지하세요. 어긋난 태그는 캐시 갱신을 조용히 실패시킵니다." >&2
  exit 2
}

if [[ "$MODE" == publish ]]; then
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || {
    echo "--publish-only 는 **이미 있는 태그**를 게시합니다. $TAG 태그가 없습니다." >&2; exit 2; }
else
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && {
    echo "$TAG 태그가 이미 있습니다. 릴리스는 **새 태그**로 냅니다(이력이 감사 기록)." >&2
    exit 2
  }
fi

[[ -f LICENSE ]] || echo "::warning:: LICENSE 가 없습니다 — 외부 배포 태그에는 있어야 합니다." >&2

PREV=$(git tag -l 'v*' | sort -V | tail -1)
# 계획 줄은 **실제로 나갈 커밋**을 찍어야 한다. publish 모드는 태그를 새로 만들지 않고
#   기존 태그의 트리를 게시하므로 main 이 아니라 그 태그를 가리킨다.
#   실측 사고(2026-09-16): publish-only 계획이 main(cc4744d)을 찍었는데 실제로 게시된 것은
#   기존 태그(9d7b1db)였다. 출력만 보고는 무엇이 나갔는지 알 수 없었다.
if [[ "$MODE" == publish ]]; then
  TARGET=$(git rev-parse --short "$TAG^{commit}")
  LATEST_TO="$TARGET"
else
  TARGET=$(git rev-parse --short main)
  LATEST_TO="$TARGET"
fi

echo "── 릴리스 계획 ──"
echo "  태그    : $TAG  → $TARGET$([[ "$MODE" == publish ]] && echo '  (기존 태그 — 새로 만들지 않음)')"
echo "  version : $VER  (plugin.json 일치 확인됨)"
echo "  직전    : ${PREV:-(없음)}"
echo "  latest  : $(git rev-parse --short latest 2>/dev/null || echo '(없음)') → $LATEST_TO"
echo "  스킬    : $(ls aiops/skills | wc -l | tr -d ' ') · 에이전트 $(ls aiops/agents | wc -l | tr -d ' ')"

# main 이 태그보다 앞서 있으면 **릴리스에 안 담긴 커밋이 있다.** 릴리스 노트가 그 커밋을
#   설명하고 있으면 노트와 내용이 어긋난다(2026-09-16 v1.13.1 이 그랬다).
if [[ "$MODE" == publish ]]; then
  AHEAD=$(git rev-list --count "$TAG^{commit}..main" 2>/dev/null || echo 0)
  if [[ "$AHEAD" != "0" ]]; then
    echo "  ⚠️ main 이 이 태그보다 $AHEAD 커밋 앞서 있습니다 — 그 변경은 이 릴리스에 없습니다." >&2
    echo "     노트가 그 커밋을 설명한다면 새 patch 릴리스를 내세요(태그 이동 금지)." >&2
  fi
fi

[[ -n "${DRY:-}" ]] && { echo "── DRY=1 — 아무것도 하지 않았습니다."; exit 0; }

# ── 태그 생성·이동 (publish 모드에서는 건너뛴다 — 이미 있다) ──────────
if [[ "$MODE" != publish ]]; then
  git tag -a "$TAG" -m "$TAG"
  # push 실패를 확인하지 않으면 "생성 완료" 를 찍고 아무것도 안 나간다.
  #   실측 사고(2026-09-16): 공개본 push 가 403 두 번으로 실패했는데 스크립트가
  #   "게시 완료" 를 출력했다. 사내 태그는 나갔고 공개본만 안 나간 상태를 아무도 몰랐다.
  git push origin "$TAG" || { echo "  ❌ 사내 태그 push 실패: $TAG" >&2; exit 1; }
  # `latest` 는 **이동하는 포인터**다(경량 태그). vX.Y.Z 와 달리 이력이 아니라 별칭이다.
  git tag -f latest "$TAG^{commit}" >/dev/null
  git push -f origin latest || { echo "  ❌ 사내 latest 이동 push 실패 — $TAG 태그는 이미 나갔다." >&2; exit 1; }
else
  echo "── --publish-only: 사내 태그 생성 건너뜀 ($TAG 이미 존재) ──"
fi

echo "✓ $TAG 생성 · latest → $(git rev-parse --short "$TAG^{commit}") 이동 완료."

# ── 공개본 게시 ──────────────────────────────────────────────────────
# 왜 스크립트에 넣나: 수동이면 잊는다. 잊으면 `#latest` 를 핀한 외부 사용자가 **옛 버전을 최신이라
#   믿는다** — 실패처럼 보이지 않는 종류의 사고다(이 레포가 버전·ref 로 이미 겪었다).
# 왜 그냥 push 하지 않나: 사내 히스토리에는 정리 이전의 내부 리소스명(도메인·DB 이름·인증 서비스명)이
#   남아 있다. 전진 미러를 밀면 현재 트리가 깨끗해도 git 이력에서 영구히 조회된다.
#   그래서 **릴리스 트리만** 공개 레포의 히스토리 위에 새 커밋으로 얹는다.
PUBLIC=$(git config --get aiops.publicRemote || true)
if [[ -z "$PUBLIC" ]]; then
  echo "  ℹ️ 공개본 게시 건너뜀 — 설정되지 않음."
  echo "     활성화: git config aiops.publicRemote https://github.com/<owner>/<repo>.git"
else
  echo "── 공개본 게시 → $PUBLIC ──"
  TMP=$(mktemp -d) || exit 2
  trap 'rm -rf "$TMP"' EXIT

  if ! git clone -q "$PUBLIC" "$TMP/pub" 2>/dev/null; then
    echo "  ❌ 공개 레포 clone 실패 — 권한/URL 확인. **사내 태그는 이미 밀렸다**(위 참조)." >&2
    echo "     수동 복구: 이 스크립트를 --publish-only $TAG 로 다시 실행." >&2
    exit 1
  fi

  # 릴리스 트리로 **완전 교체**(삭제된 파일도 반영). .git 은 보존한다.
  find "$TMP/pub" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  git archive "$TAG" | tar -x -C "$TMP/pub"

  if [[ -z "$(git -C "$TMP/pub" status --porcelain)" ]]; then
    echo "  ℹ️ 공개본이 이미 이 트리와 동일 — 커밋 없음. 태그만 맞춘다."
  else
    git -C "$TMP/pub" add -A
    git -C "$TMP/pub" commit -q -m "aiops $TAG

사내 정본의 $TAG 릴리스 트리. 개발 이력은 공개하지 않는다(README 참조)."
  fi

  git -C "$TMP/pub" tag -f "$TAG" >/dev/null
  git -C "$TMP/pub" tag -f latest >/dev/null
  if ! git -C "$TMP/pub" push -q origin HEAD:main; then
    echo "  ❌ 공개본 push 실패(main) — 권한/URL 확인. **사내 태그는 이미 밀렸다.**" >&2
    echo "     복구: 권한 해결 후 이 스크립트를 --publish-only $TAG 로 재실행." >&2
    exit 1
  fi
  if ! git -C "$TMP/pub" push -qf origin "$TAG" latest; then
    echo "  ❌ 공개본 태그 push 실패($TAG·latest) — main 은 나갔을 수 있다." >&2
    echo "     복구: 권한 해결 후 이 스크립트를 --publish-only $TAG 로 재실행." >&2
    exit 1
  fi
  echo "  ✓ 공개본 $TAG · latest 게시 완료."
fi

echo "  소비자: #$TAG 핀(권장) 또는 #latest(자동 추종)."
echo "  ⚠️ #latest 사용자도 마켓플레이스 재등록 또는 update 가 필요합니다 — 자동으로 당겨오지 않습니다."
