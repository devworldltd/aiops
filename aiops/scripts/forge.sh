#!/usr/bin/env bash
# forge.sh — Git forge(코드호스팅) 중립 CLI. origin 리모트로 GitHub↔Gitea 자동 감지.
#
# ⚠️ 반드시 **실행**한다(소싱 금지). 호출 셸이 zsh 여도 shebang(bash)으로 실행되어야
#    BASH_REMATCH·배열 등이 동작한다. actions-wait.sh 와 동일 관례.
#
# aiops 워크플로의 이슈/PR/리뷰 조작을 forge 무관하게 수행한다. GitHub 이면 `gh` CLI,
# 그 외(Gitea 등)면 REST API(/api/v1). 사내 Gitea 는 Cloudflare Access 뒤에 있을 수 있어
# 인증 3단 폴백을 actions-wait.sh 에서 승계.
#
# 사용:
#   forge.sh repo                                   # -> owner/repo (nameWithOwner 대체)
#   forge.sh kind                                   # -> github | gitea
#   forge.sh issue-comment <n> <body|@file>         # -> COMMENT_ID=<id>
#   forge.sh issue-comments <n>                     # 전 댓글 본문(마커 grep 용)
#   forge.sh issue-view <n>                          # 이슈 JSON(title/body/labels/…)
#   forge.sh issue-create <title> <body|@file> [--label a,b] [--milestone id]  # -> ISSUE_NUMBER=.. ISSUE_URL=..
#   forge.sh issue-list [--label x] [--milestone name] [--state open]          # number\ttitle
#   forge.sh issue-search <query> [--state open]    # 제목/본문 텍스트 검색 -> number\ttitle
#   forge.sh issue-close <n> [comment]
#   forge.sh pr-create <head> <base> <title> <body|@file>   # -> PR_NUMBER=<n> PR_URL=<url>
#   forge.sh pr-list <head> <base> [state]                  # 매칭 PR 번호
#   forge.sh pr-view <n>                                     # PR JSON
#   forge.sh pr-diff <n> [--name-only]
#   forge.sh pr-review <n> <APPROVE|REQUEST_CHANGES|COMMENT> <body|@file>  # Gitea self-approve→COMMENT 강등
#   forge.sh pr-merge <n> [--delete-branch]   # feature→dev 는 --delete-branch, dev→main 은 생략(head 보존)
#   forge.sh pr-url <n>                        # 웹 PR URL (Gitea /pulls/, GitHub /pull/)
#
# 인증(Gitea): git credential fill 토큰 → gitconfig extraheader 서비스토큰 → cloudflared 캐시토큰.
set -uo pipefail

# ── 초기화: forge 종류·host·owner·repo·인증 헤더 ─────────────────────
FORGE_KIND="" HOST="" OWNER="" REPO="" API="" WEB=""
AUTH=()
_init() {
  local origin; origin=$(git remote get-url origin 2>/dev/null || echo "")
  [[ -z "$origin" ]] && { echo "[forge] git origin 리모트 없음" >&2; exit 2; }
  if [[ "$origin" == *github.com* ]]; then
    FORGE_KIND="github"
    [[ "$origin" =~ github.com[:/]([^/]+)/([^/]+)$ ]] && { OWNER="${BASH_REMATCH[1]}"; REPO="${BASH_REMATCH[2]%.git}"; }
    WEB="https://github.com"
    return 0
  fi
  FORGE_KIND="gitea"
  if [[ "$origin" =~ ^https?://([^/]+)/([^/]+)/([^/]+)$ ]]; then
    HOST="${BASH_REMATCH[1]}"; OWNER="${BASH_REMATCH[2]}"; REPO="${BASH_REMATCH[3]%.git}"
  elif [[ "$origin" =~ ^[^@]+@([^:]+):([^/]+)/([^/]+)$ ]]; then
    HOST="${BASH_REMATCH[1]}"; OWNER="${BASH_REMATCH[2]}"; REPO="${BASH_REMATCH[3]%.git}"
  else
    echo "[forge] origin URL 파싱 실패: $origin" >&2; exit 2
  fi
  API="https://${HOST}/api/v1"; WEB="https://${HOST}"
  local gtok; gtok=$(printf "protocol=https\nhost=%s\n" "$HOST" | git credential fill 2>/dev/null | awk -F= '/^password/{print $2}')
  AUTH=(-H "Authorization: token $gtok")
  if ! _api_ok; then
    local extra; extra=$(git config --global --get-all "http.https://${HOST}/.extraheader" 2>/dev/null || true)
    [[ -n "$extra" ]] && while IFS= read -r h; do AUTH+=(-H "$h"); done <<< "$extra"
    if ! _api_ok; then
      local cftok; cftok=$(cloudflared access token --app="https://${HOST}" 2>/dev/null || echo "")
      [[ -z "$cftok" ]] && { echo "[forge] ${HOST} API 접근 실패 — 서비스토큰/캐시 만료. 'cloudflared access login https://${HOST}' 후 재시도" >&2; exit 2; }
      AUTH+=(-H "cf-access-token: $cftok")
      _api_ok || { echo "[forge] ${HOST} API 인증 실패(Gitea 토큰/Access 토큰 확인)" >&2; exit 2; }
    fi
  fi
}
_api_ok() { curl -s -m 10 "${AUTH[@]}" "$API/version" 2>/dev/null | grep -q '"version"'; }

# _api <METHOD> <path> [json|@file]
_api() {
  local method="$1" path="$2" data="${3:-}"
  if [[ "$FORGE_KIND" == "github" ]]; then
    if [[ -n "$data" ]]; then
      if [[ "$data" == @* ]]; then gh api -X "$method" "${path#/}" --input "${data#@}"; else gh api -X "$method" "${path#/}" --input <(printf '%s' "$data"); fi
    else gh api -X "$method" "${path#/}"; fi
    return $?
  fi
  local args=(-s -X "$method" "${AUTH[@]}" -H "Content-Type: application/json")
  [[ -n "$data" ]] && { [[ "$data" == @* ]] && args+=(--data-binary "@${data#@}") || args+=(-d "$data"); }
  curl "${args[@]}" "$API$path"
}

# _guard_body <body-string|@file>
#   `@` 를 빼고 파일 경로만 넘기는 실수를 **조용히 통과시키지 않는다.**
#   실측 사고(2026-08-12): dev-pr 에이전트가 PR 본문에 `/tmp/…/pr_body.md` 를 그대로 넘겨
#   PR 본문이 경로 한 줄이 되었고, `Closes #N` 이 없어 머지 시 이슈가 자동 종료되지 않았다.
#   에러로 죽는 편이 낫다 — 호출자가 `@` 를 붙여 다시 부르면 된다.
_guard_body() {
  local a="$1"
  if [[ "$a" == @* ]]; then
    # @file 인데 파일이 없으면 **빈 본문으로 등록되지 않게** 여기서 막는다.
    #   실측 사고(2026-08-12): 경로 오타로 cat 이 실패했는데도 빈 리뷰가 등록됐다.
    [[ -f "${a#@}" ]] && return 0
    echo "[forge] 본문 파일이 없습니다: ${a#@}" >&2
    return 3
  fi
  [[ -n "$a" ]] || { echo "[forge] 본문이 빕니다 — 등록하지 않습니다." >&2; return 3; }
  if [[ "$a" != *$'\n'* && -f "$a" ]]; then
    echo "[forge] 본문이 파일 경로로 보입니다: $a" >&2
    echo "[forge] 파일 내용을 본문으로 쓰려면 '@' 를 붙이세요: @$a" >&2
    return 3
  fi
  return 0
}

_json_body() {  # arg: body-string | @file  -> {"body": ...}
  local a="$1"
  _guard_body "$a" || return 3
  if [[ "$a" == @* ]]; then python3 -c "import json,sys;print(json.dumps({'body':open(sys.argv[1]).read()}))" "${a#@}"
  else python3 -c "import json,sys;print(json.dumps({'body':sys.argv[1]}))" "$a"; fi
}

# _resolve_labels <csv of name-or-id>  -> JSON array of numeric label IDs (Gitea).
#   숫자는 그대로, 이름은 GET /labels 로 ID 해석, 없는 라벨은 스킵(무시).
_resolve_labels() {
  local csv="$1"
  [[ -z "$csv" ]] && { echo "[]"; return 0; }
  local labels_json; labels_json=$(_api GET "/repos/$OWNER/$REPO/labels?limit=100")
  python3 -c "
import json,sys
csv=sys.argv[1]
try: labels=json.load(sys.stdin)
except Exception: labels=[]
byname={ (l.get('name') or '').lower(): l.get('id') for l in labels }
out=[]
for tok in [x.strip() for x in csv.split(',') if x.strip()]:
    if tok.isdigit(): out.append(int(tok))
    elif tok.lower() in byname: out.append(byname[tok.lower()])
print(json.dumps(out))" "$csv" <<<"$labels_json"
}

# ── 서브커맨드 ──────────────────────────────────────────────────────
cmd_repo() { echo "${OWNER}/${REPO}"; }
cmd_kind() { echo "$FORGE_KIND"; }
cmd_web()  { echo "$WEB"; }

cmd_issue_comment() {
  local n="$1" body="$2"
  if [[ "$FORGE_KIND" == "github" ]]; then
    [[ "$body" == @* ]] && gh issue comment "$n" --body-file "${body#@}" || gh issue comment "$n" --body "$body"; return $?
  fi
  _api POST "/repos/$OWNER/$REPO/issues/$n/comments" "$(_json_body "$body")" \
    | python3 -c "import json,sys;print('COMMENT_ID='+str(json.load(sys.stdin).get('id','')))" 2>/dev/null
}

cmd_issue_comments() {
  local n="$1"
  if [[ "$FORGE_KIND" == "github" ]]; then gh issue view "$n" --comments; return $?; fi
  _api GET "/repos/$OWNER/$REPO/issues/$n/comments?limit=100" \
    | python3 -c "import json,sys
for c in json.load(sys.stdin): print(c.get('body') or ''); print('---')" 2>/dev/null
}

cmd_issue_view() {
  local n="$1"
  if [[ "$FORGE_KIND" == "github" ]]; then gh issue view "$n" --json title,body,labels,comments; return $?; fi
  _api GET "/repos/$OWNER/$REPO/issues/$n"
}

cmd_issue_create() {
  local title="$1" body="$2"; shift 2
  local labels="" milestone=""
  while [[ $# -gt 0 ]]; do case "$1" in --label) labels="$2"; shift 2;; --milestone) milestone="$2"; shift 2;; *) shift;; esac; done
  if [[ "$FORGE_KIND" == "github" ]]; then
    local a=(--title "$title"); [[ "$body" == @* ]] && a+=(--body-file "${body#@}") || a+=(--body "$body"); [[ -n "$labels" ]] && a+=(--label "$labels")
    gh issue create "${a[@]}"; return $?
  fi
  local labelids="[]"; [[ -n "$labels" ]] && labelids=$(_resolve_labels "$labels")
  local payload; payload=$(python3 -c "
import json,sys
title,b=sys.argv[1],sys.argv[2]
body=open(b[1:]).read() if b.startswith('@') else b
o={'title':title,'body':body}
labs=json.loads(sys.argv[3])
if labs: o['labels']=labs
if sys.argv[4]: o['milestone']=int(sys.argv[4])
print(json.dumps(o))" "$title" "$body" "$labelids" "$milestone")
  _api POST "/repos/$OWNER/$REPO/issues" "$payload" \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print('ISSUE_NUMBER='+str(d.get('number',''))+' ISSUE_URL='+(d.get('html_url') or ''))" 2>/dev/null
}

cmd_issue_list() {
  local labels="" milestone="" state="open"
  while [[ $# -gt 0 ]]; do case "$1" in --label) labels="$2"; shift 2;; --milestone) milestone="$2"; shift 2;; --state) state="$2"; shift 2;; *) shift;; esac; done
  if [[ "$FORGE_KIND" == "github" ]]; then
    local a=(--state "$state" --json number,title); [[ -n "$labels" ]] && a+=(--label "$labels"); [[ -n "$milestone" ]] && a+=(--milestone "$milestone")
    gh issue list "${a[@]}"; return $?
  fi
  local q="state=$state&type=issues&limit=50"; [[ -n "$labels" ]] && q="$q&labels=$labels"
  _api GET "/repos/$OWNER/$REPO/issues?$q" | python3 -c "import json,sys
ms='$milestone'
for i in json.load(sys.stdin):
    if ms and (i.get('milestone') or {}).get('title')!=ms: continue
    print(str(i['number'])+'\t'+i['title'])" 2>/dev/null
}

# forge.sh issue-search <query> [--state open]  -> number\ttitle (제목/본문 텍스트 매칭)
cmd_issue_search() {
  local query="$1"; shift || true
  local state="open"
  while [[ $# -gt 0 ]]; do case "$1" in --state) state="$2"; shift 2;; *) shift;; esac; done
  if [[ "$FORGE_KIND" == "github" ]]; then
    gh issue list --search "$query" --state "$state" --json number,title --jq '.[] | "\(.number)\t\(.title)"'; return $?
  fi
  local q; q=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$query")
  _api GET "/repos/$OWNER/$REPO/issues?q=$q&type=issues&state=$state&limit=50" \
    | python3 -c "import json,sys
for i in json.load(sys.stdin): print(str(i['number'])+'\t'+i.get('title',''))" 2>/dev/null
}

cmd_issue_close() {
  local n="$1" comment="${2:-}"
  [[ -n "$comment" ]] && cmd_issue_comment "$n" "$comment" >/dev/null 2>&1
  if [[ "$FORGE_KIND" == "github" ]]; then gh issue close "$n"; return $?; fi
  _api PATCH "/repos/$OWNER/$REPO/issues/$n" '{"state":"closed"}' >/dev/null
}

cmd_pr_create() {
  local head="$1" base="$2" title="$3" body="$4"
  _guard_body "$body" || return 3
  if [[ "$FORGE_KIND" == "github" ]]; then
    local a=(--head "$head" --base "$base" --title "$title"); [[ "$body" == @* ]] && a+=(--body-file "${body#@}") || a+=(--body "$body")
    local url num; url=$(gh pr create "${a[@]}"); num=$(sed -E 's#.*/pull/([0-9]+).*#\1#' <<<"$url"); echo "PR_NUMBER=$num PR_URL=$url"; return 0
  fi
  local payload; payload=$(python3 -c "
import json,sys
head,base,title,b=sys.argv[1:5]
body=open(b[1:]).read() if b.startswith('@') else b
print(json.dumps({'head':head,'base':base,'title':title,'body':body}))" "$head" "$base" "$title" "$body")
  _api POST "/repos/$OWNER/$REPO/pulls" "$payload" \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print('PR_NUMBER='+str(d.get('number',''))+' PR_URL='+(d.get('html_url') or ''))" 2>/dev/null
}

cmd_pr_list() {
  local head="$1" base="$2" state="${3:-open}"
  if [[ "$FORGE_KIND" == "github" ]]; then gh pr list --head "$head" --base "$base" --state "$state" --json number --jq '.[].number'; return $?; fi
  _api GET "/repos/$OWNER/$REPO/pulls?state=$state&limit=50" | python3 -c "import json,sys
head='$head'
for p in json.load(sys.stdin):
    if (p.get('head') or {}).get('ref')==head: print(p['number'])" 2>/dev/null
}

cmd_pr_view() {
  local n="$1"
  if [[ "$FORGE_KIND" == "github" ]]; then gh pr view "$n" --json number,title,body,state,headRefName,baseRefName,additions,deletions; return $?; fi
  _api GET "/repos/$OWNER/$REPO/pulls/$n"
}

cmd_pr_diff() {
  local n="$1" no="${2:-}"
  if [[ "$FORGE_KIND" == "github" ]]; then [[ "$no" == "--name-only" ]] && gh pr diff "$n" --name-only || gh pr diff "$n"; return $?; fi
  if [[ "$no" == "--name-only" ]]; then
    _api GET "/repos/$OWNER/$REPO/pulls/$n/files?limit=100" | python3 -c "import json,sys
[print(f.get('filename','')) for f in json.load(sys.stdin)]" 2>/dev/null
  else _api GET "/repos/$OWNER/$REPO/pulls/$n.diff"; fi
}

cmd_pr_review() {
  local n="$1" verdict="$2" body="$3"
  if [[ "$FORGE_KIND" == "github" ]]; then
    local flag; case "$verdict" in APPROVE) flag=--approve;; REQUEST_CHANGES) flag=--request-changes;; *) flag=--comment;; esac
    [[ "$body" == @* ]] && gh pr review "$n" "$flag" --body-file "${body#@}" || gh pr review "$n" "$flag" --body "$body"; return $?
  fi
  _guard_body "$body" || return 3
  local event text; case "$verdict" in APPROVE) event=APPROVED;; REQUEST_CHANGES) event=REQUEST_CHANGES;; *) event=COMMENT;; esac
  [[ "$body" == @* ]] && text=$(cat "${body#@}") || text="$body"
  # ⚠️ payload 를 **변수로 분리**한다. `_api ... "$(python3 -c "…{'a':1,'b':2}…")"` 처럼
  #   중첩 $( ) 안에 이중따옴표를 두면 안쪽 따옴표 짝이 어긋나 dict 리터럴이 **중괄호 확장**되고,
  #   python 이 `json.dumps('event':…)` 를 받아 SyntaxError 로 죽는다(리뷰가 조용히 등록되지 않았다).
  #   python 코드는 단일따옴표로 감싸 셸 확장을 원천 차단한다.
  local payload resp
  payload=$(python3 -c 'import json,sys;print(json.dumps({"event":sys.argv[1],"body":sys.argv[2]}))' "$event" "$text")
  resp=$(_api POST "/repos/$OWNER/$REPO/pulls/$n/reviews" "$payload")
  if echo "$resp" | grep -qi "approve your own\|self.approv"; then
    echo "[forge] 자기 PR APPROVE 불가(Gitea) → COMMENT 등록" >&2
    payload=$(python3 -c 'import json,sys;print(json.dumps({"event":"COMMENT","body":sys.argv[1]}))' "$text")
    resp=$(_api POST "/repos/$OWNER/$REPO/pulls/$n/reviews" "$payload")
  fi
  echo "$resp" | python3 -c "import json,sys;d=json.load(sys.stdin);print('REVIEW_ID='+str(d.get('id',''))+' STATE='+str(d.get('state','')))" 2>/dev/null
}

cmd_pr_merge() {
  local n="$1" del="${2:-}"
  if [[ "$FORGE_KIND" == "github" ]]; then local a=("$n" --merge); [[ "$del" == "--delete-branch" ]] && a+=(--delete-branch); gh pr merge "${a[@]}"; return $?; fi
  local delflag=false; [[ "$del" == "--delete-branch" ]] && delflag=true
  _api POST "/repos/$OWNER/$REPO/pulls/$n/merge" "{\"Do\":\"merge\",\"delete_branch_after_merge\":$delflag}" >/dev/null 2>&1
  local merged; merged=$(_api GET "/repos/$OWNER/$REPO/pulls/$n" | python3 -c "import json,sys;print('1' if json.load(sys.stdin).get('merged') else '0')" 2>/dev/null)
  [[ "$merged" == "1" ]] && { echo "MERGED=1"; return 0; } || { echo "MERGED=0" >&2; return 1; }
}

cmd_pr_url() {
  [[ "$FORGE_KIND" == "github" ]] && echo "https://github.com/${OWNER}/${REPO}/pull/$1" || echo "${WEB}/${OWNER}/${REPO}/pulls/$1"
}

# ── 디스패치 ────────────────────────────────────────────────────────
[[ $# -lt 1 ]] && { grep -E '^#   forge.sh' "$0" | sed 's/^#   //'; exit 2; }
SUB="$1"; shift
_init
case "$SUB" in
  repo) cmd_repo ;;
  kind) cmd_kind ;;
  web)  cmd_web ;;
  issue-comment)  cmd_issue_comment "$@" ;;
  issue-comments) cmd_issue_comments "$@" ;;
  issue-view)     cmd_issue_view "$@" ;;
  issue-create)   cmd_issue_create "$@" ;;
  issue-list)     cmd_issue_list "$@" ;;
  issue-search)   cmd_issue_search "$@" ;;
  issue-close)    cmd_issue_close "$@" ;;
  pr-create) cmd_pr_create "$@" ;;
  pr-list)   cmd_pr_list "$@" ;;
  pr-view)   cmd_pr_view "$@" ;;
  pr-diff)   cmd_pr_diff "$@" ;;
  pr-review) cmd_pr_review "$@" ;;
  pr-merge)  cmd_pr_merge "$@" ;;
  pr-url)    cmd_pr_url "$@" ;;
  *) echo "[forge] 알 수 없는 서브커맨드: $SUB" >&2; exit 2 ;;
esac
