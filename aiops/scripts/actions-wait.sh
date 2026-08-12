#!/usr/bin/env bash
# actions-wait.sh — CI/CD workflow run 대기 (forge 자동 감지: GitHub ↔ Gitea)
#
# origin 리모트가 github.com 이면 gh CLI, 그 외(예: Gitea)면 해당 호스트의
# Gitea Actions REST API(/api/v1/repos/{owner}/{repo}/actions/runs)로 동작한다.
#
# 사용:
#   actions-wait.sh --branch <branch> [--workflow <file.yml>] [--sha <40hex>] \
#                   [--timeout <sec>] [--grace <n>]
#
# 출력: 진행 로그(stderr) + 마지막 줄(stdout, 기계판독 계약):
#   RUN_ID=<id> RUN_URL=<url> CONCLUSION=<success|failure|cancelled|timeout|not_found>
#
# 종료 코드: 0=success / 1=failure·cancelled / 124=timeout / 2=run 미발견·환경 오류
#
# Gitea 인증:
#   - Gitea 토큰: `git credential fill`(키체인/credential store)의 password
#   - CF Access 게이팅 감지 시: `cloudflared access token --app=https://<host>` 캐시 토큰을
#     cf-access-token 헤더로 동반 (미캐시면 `cloudflared access login` 안내 후 exit 2)
set -uo pipefail

BRANCH="" WORKFLOW="deploy-cf.yml" SHA="" TIMEOUT=120 GRACE=6
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)   BRANCH="$2"; shift 2 ;;
    --workflow) WORKFLOW="$2"; shift 2 ;;
    --sha)      SHA="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    --grace)    GRACE="$2"; shift 2 ;;
    *) echo "[actions-wait] 알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
done
[[ -z "$BRANCH" ]] && { echo "[actions-wait] --branch 필수" >&2; exit 2; }

ORIGIN_URL=$(git remote get-url origin 2>/dev/null || echo "")
[[ -z "$ORIGIN_URL" ]] && { echo "[actions-wait] git origin 리모트 없음" >&2; exit 2; }

# ── GitHub 경로 (기존 gh CLI 동작 유지) ─────────────────────────────
if [[ "$ORIGIN_URL" == *github.com* ]]; then
  RUN_ID=""
  for _ in $(seq 1 "$GRACE"); do
    if [[ -n "$SHA" ]]; then
      RUN_ID=$(gh run list --workflow="$WORKFLOW" --branch="$BRANCH" --limit=5 \
        --json databaseId,headSha --jq ".[] | select(.headSha==\"$SHA\") | .databaseId" 2>/dev/null | head -1)
    else
      RUN_ID=$(gh run list --workflow="$WORKFLOW" --branch="$BRANCH" --limit=1 \
        --json databaseId --jq '.[0].databaseId' 2>/dev/null)
    fi
    [[ -n "$RUN_ID" && "$RUN_ID" != "null" ]] && break
    sleep 5
  done
  if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
    echo "RUN_ID= RUN_URL= CONCLUSION=not_found"; exit 2
  fi
  timeout "$TIMEOUT" gh run watch "$RUN_ID" --exit-status >/dev/null 2>&1
  EXIT=$?
  RUN_URL=$(gh run view "$RUN_ID" --json url --jq '.url' 2>/dev/null || echo "")
  case "$EXIT" in
    0)   echo "RUN_ID=$RUN_ID RUN_URL=$RUN_URL CONCLUSION=success"; exit 0 ;;
    124) echo "RUN_ID=$RUN_ID RUN_URL=$RUN_URL CONCLUSION=timeout"; exit 124 ;;
    *)   echo "RUN_ID=$RUN_ID RUN_URL=$RUN_URL CONCLUSION=failure"; exit 1 ;;
  esac
fi

# ── Gitea 경로 ──────────────────────────────────────────────────────
# origin URL → host / owner / repo 파싱 (https://host/owner/repo(.git) | git@host:owner/repo(.git))
if [[ "$ORIGIN_URL" =~ ^https?://([^/]+)/([^/]+)/([^/]+)$ ]]; then
  HOST="${BASH_REMATCH[1]}"; OWNER="${BASH_REMATCH[2]}"; REPO="${BASH_REMATCH[3]%.git}"
elif [[ "$ORIGIN_URL" =~ ^[^@]+@([^:]+):([^/]+)/([^/]+)$ ]]; then
  HOST="${BASH_REMATCH[1]}"; OWNER="${BASH_REMATCH[2]}"; REPO="${BASH_REMATCH[3]%.git}"
else
  echo "[actions-wait] origin URL 파싱 실패: $ORIGIN_URL" >&2; exit 2
fi
API="https://${HOST}/api/v1"

GTOK=$(printf "protocol=https\nhost=%s\n" "$HOST" | git credential fill 2>/dev/null | awk -F= '/^password/{print $2}')
AUTH=(-H "Authorization: token $GTOK")

# CF Access 게이팅 대응 — 우선순위: gitconfig 서비스토큰(만료 없음) → cloudflared 캐시 토큰.
# (주의: Access 는 302 를 돌려주므로 curl -f 로는 감지 불가 — JSON 응답 여부로 판정)
_api_ok() { curl -s -m 10 "${AUTH[@]}" "$API/version" 2>/dev/null | grep -q '"version"'; }
if ! _api_ok; then
  EXTRA=$(git config --global --get-all "http.https://${HOST}/.extraheader" 2>/dev/null || true)
  if [[ -n "$EXTRA" ]]; then
    while IFS= read -r h; do AUTH+=(-H "$h"); done <<< "$EXTRA"
  fi
  if ! _api_ok; then
    CFTOK=$(cloudflared access token --app="https://${HOST}" 2>/dev/null || echo "")
    if [[ -z "$CFTOK" ]]; then
      echo "[actions-wait] $HOST API 접근 실패 — 서비스토큰(gitconfig extraheader) 없음/무효, cloudflared 캐시도 만료. 'cloudflared access login https://$HOST' 후 재시도" >&2
      echo "RUN_ID= RUN_URL= CONCLUSION=not_found"; exit 2
    fi
    AUTH+=(-H "cf-access-token: $CFTOK")
    _api_ok || {
      echo "[actions-wait] $HOST API 인증 실패 (Gitea 토큰/Access 토큰 확인)" >&2
      echo "RUN_ID= RUN_URL= CONCLUSION=not_found"; exit 2
    }
  fi
fi

_find_run() {  # stdout: "<id> <status> <conclusion>" (최신 매칭 1건)
  curl -s -m 10 "${AUTH[@]}" "$API/repos/$OWNER/$REPO/actions/runs?limit=20" \
  | python3 -c "
import json, sys
wf, br, sha = '$WORKFLOW', '$BRANCH', '$SHA'
try: runs = json.load(sys.stdin).get('workflow_runs', [])
except Exception: runs = []
for r in sorted(runs, key=lambda x: -x.get('id', 0)):
    path = (r.get('path') or '')
    # path 형식: '<file>@refs/heads/<branch>' — PR 런은 '@refs/pull/N/head' 라 브랜치 대기에선 제외됨
    if not path.startswith(wf + '@'): continue
    if r.get('head_branch') != br: continue
    if sha and r.get('head_sha') and r.get('head_sha') != sha: continue
    print(r.get('id', ''), r.get('status', ''), r.get('conclusion') or '')
    break
"
}

RUN_ID="" STATUS="" CONCLUSION=""
for _ in $(seq 1 "$GRACE"); do
  read -r RUN_ID STATUS CONCLUSION <<<"$(_find_run)" || true
  [[ -n "$RUN_ID" ]] && break
  sleep 5
done
if [[ -z "$RUN_ID" ]]; then
  echo "RUN_ID= RUN_URL= CONCLUSION=not_found"; exit 2
fi
RUN_URL="https://${HOST}/${OWNER}/${REPO}/actions/runs/${RUN_ID}"
echo "[actions-wait] run $RUN_ID 발견 (status=$STATUS) — 최대 ${TIMEOUT}s 대기" >&2

ELAPSED=0
while [[ "$STATUS" != "completed" && $ELAPSED -lt $TIMEOUT ]]; do
  sleep 5; ELAPSED=$((ELAPSED + 5))
  read -r _ STATUS CONCLUSION <<<"$(curl -s -m 10 "${AUTH[@]}" "$API/repos/$OWNER/$REPO/actions/runs?limit=20" \
    | python3 -c "
import json, sys
try: runs = json.load(sys.stdin).get('workflow_runs', [])
except Exception: runs = []
r = next((x for x in runs if x.get('id') == $RUN_ID), None)
print(r.get('id',''), r.get('status',''), (r.get('conclusion') or '')) if r else print('', '', '')
")" || true
done

if [[ "$STATUS" != "completed" ]]; then
  echo "RUN_ID=$RUN_ID RUN_URL=$RUN_URL CONCLUSION=timeout"; exit 124
fi
case "$CONCLUSION" in
  success) echo "RUN_ID=$RUN_ID RUN_URL=$RUN_URL CONCLUSION=success"; exit 0 ;;
  *)       echo "RUN_ID=$RUN_ID RUN_URL=$RUN_URL CONCLUSION=${CONCLUSION:-failure}"; exit 1 ;;
esac
