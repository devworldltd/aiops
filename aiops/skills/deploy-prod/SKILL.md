---
name: deploy-prod
description: "Prod 배포 검증 — main 머지 후 호출. CI/CD Actions(GitHub/Gitea 자동 감지) 대기 + 프로덕션 헬스체크 + smoke E2E + Q4-B 자동 롤백. /aiops:merge-main 완료 후 다음 단계."
---

# /aiops:deploy-prod — Prod 배포 검증 + smoke E2E + Q4-B 자동 롤백

본 스킬은 `/aiops:merge-main` 완료 직후 호출되어 다음을 순차 자동화한다.

1. **main_sha 획득** — `--main-sha=` 인자 → #120 댓글 grep → `git rev-parse origin/main` 3단 우선순위
2. **CI/CD Actions**(GitHub/Gitea 자동 감지) `workflow_run` 대기 (`branch=main`, `head_sha=MAIN_SHA`)
3. **프로덕션 `/health`** `deployed_sha` 매칭 폴링 (≤ 150초)
4. **G4 BLAST_RADIUS_GUARD** 사전 검사 (qa-e2e 호출 전 외부 게이트)
5. **qa-e2e `--env=prod --mode=smoke`** 호출
6. **smoke FAIL 시 Q4-B 자동 롤백** + 재 smoke
7. **5종 마커 댓글** 등록

산출물 마커 헤더 (불변 인터페이스 계약):

- A 시나리오 — `## 🚀 Prod 배포 검증` + `PROD_RESULT=PASS`
- B 시나리오 — `## ⚠️ Prod 자동 롤백 완료` + `PROD_RESULT=ROLLBACK_PASS` + `rolled_back_to=<deployment_id>`
- C 시나리오 — `## 🚨 Prod 롤백 후 FAIL — 운영자 즉시 확인` + `PROD_RESULT=ROLLBACK_FAIL`
- D 시나리오 — `## ⚠️ Prod E2E 환경 오류` + `E2E_ENV_ERROR=<reason>`
- E 시나리오 — `## ⚠️ Prod 배포 검증 실패`
- F 시나리오 (#42) — `## ℹ️ 헬스체크 스킵` + `healthcheck_skipped=platform_cli` (platform=cli 이며 prod URL 이 전부 비어 있을 때, 3~6 단계를 건너뛰고 정상 종료)

> EM DASH `—` 은 U+2014 (UTF-8 `0xE2 0x80 0x94`). EN DASH (U+2013) / HYPHEN (U+002D) 와 절대 혼동 금지.

---

## §1 인자 파싱

지원 플래그:

| 플래그 | 기본값 | 효과 |
|--------|--------|------|
| `--skip-rollback` | false | smoke FAIL 시 wrangler rollback 미호출, `PROD_RESULT=FAIL_NO_ROLLBACK` 마커 후 종료 (긴급 점검 모드) |
| `--dry-run` | false | Actions / 헬스체크 / qa-e2e / wrangler / gh comment 호출 0건, 분기 결과만 stdout 출력 |
| `--confirm-rollback` | false | 자동 롤백 직전 사용자 확인 (`[y/N]`) — 비대화 환경에서는 무시되고 자동 진행 |
| `--main-sha=<40-hex>` | (없음) | main_sha 수동 지정 — 댓글 grep / git rev-parse 폴백 둘 다 우회 |
| `--issue=<N>` | (자동 감지) | 결과 댓글 등록 이슈. 미지정 시 #120 댓글 grep 으로 발견한 이슈로 폴백 |

```bash
SKIP_ROLLBACK=false
DRY_RUN=false
CONFIRM_ROLLBACK=false
MAIN_SHA_OVERRIDE=""
ISSUE_OVERRIDE=""

for arg in $ARGUMENTS; do
  case "$arg" in
    --skip-rollback)      SKIP_ROLLBACK=true ;;
    --dry-run)            DRY_RUN=true ;;
    --confirm-rollback)   CONFIRM_ROLLBACK=true ;;
    --main-sha=*)         MAIN_SHA_OVERRIDE="${arg#--main-sha=}" ;;
    --issue=*)            ISSUE_OVERRIDE="${arg#--issue=}" ;;
    *) echo "[deploy-prod] WARN: 알 수 없는 인자: $arg" ;;
  esac
done

echo "[deploy-prod] §1 인자: skip_rollback=$SKIP_ROLLBACK dry_run=$DRY_RUN confirm_rollback=$CONFIRM_ROLLBACK"
```

핵심 제약:

- `--skip-rollback` 와 `--confirm-rollback` 은 상호 배타 — 둘 다 지정 시 `--skip-rollback` 우선 (안전 기본).
- `--dry-run` 은 모든 부수효과를 차단하므로 다른 플래그와 자유롭게 조합 가능.

---

## §2 사전 검증 + main_sha 획득

### 2.1 forge 접근 + git 정렬

인증(GitHub `gh` / Gitea 토큰·CF Access)은 forge.sh 가 처리합니다. `forge.sh repo` 성공 시 인증 OK.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" repo >/dev/null 2>&1 || { echo "[deploy-prod] §2 ERROR: forge 접근 실패"; exit 2; }
git fetch origin main --quiet 2>/dev/null || true
```

### 2.2 main_sha 3단 우선순위

| 순위 | 출처 | 패턴 |
|------|------|------|
| 1 | `--main-sha=<SHA>` | 인자 명시 |
| 2 | 이슈 #120 (또는 최근 머지 이슈) 댓글 grep | `## 🚀 main 머지 완료` 블록 내 `^main_sha=([0-9a-f]{40})$` |
| 3 | `git rev-parse origin/main` | 폴백 |

```bash
MAIN_SHA=""
MAIN_SHA_SOURCE=""
CANDIDATE_ISSUE=""

# §2.2.1 우선순위 1
if [[ -n "$MAIN_SHA_OVERRIDE" ]]; then
  MAIN_SHA="$MAIN_SHA_OVERRIDE"
  MAIN_SHA_SOURCE="argument"
fi

# §2.2.2 우선순위 2 — #120 패턴 댓글 grep
if [[ -z "$MAIN_SHA" ]]; then
  RECENT_MERGE_SHA=$(git log origin/main --merges --first-parent --format=%H | head -1)
  RECENT_MERGE_MSG=$(git log -1 --format=%s "$RECENT_MERGE_SHA" 2>/dev/null || echo "")
  RECENT_PR=$(echo "$RECENT_MERGE_MSG" | grep -oE '#[0-9]+' | head -1 | tr -d '#')

  if [[ -n "$RECENT_PR" ]]; then
    PR_BODY=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" pr-view "$RECENT_PR" 2>/dev/null | jq -r '.body // ""')
    CANDIDATE_ISSUE=$(echo "$PR_BODY" | grep -oiE '(Closes|Fixes|Resolves)[[:space:]]+#[0-9]+' | head -1 | grep -oE '[0-9]+')

    if [[ -n "$CANDIDATE_ISSUE" ]]; then
      MAIN_SHA=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-comments "$CANDIDATE_ISSUE" 2>/dev/null \
        | grep -E '^main_sha=[0-9a-f]{40}$' \
        | tail -1 \
        | cut -d= -f2)
      [[ -n "$MAIN_SHA" ]] && MAIN_SHA_SOURCE="comment(issue=#$CANDIDATE_ISSUE)"
      [[ -z "$ISSUE_OVERRIDE" ]] && ISSUE_OVERRIDE="$CANDIDATE_ISSUE"
    fi
  fi
fi

# §2.2.3 우선순위 3 — git rev-parse 폴백
if [[ -z "$MAIN_SHA" ]]; then
  MAIN_SHA=$(git rev-parse origin/main 2>/dev/null || echo "")
  [[ -n "$MAIN_SHA" ]] && MAIN_SHA_SOURCE="git_rev_parse"
fi

# §2.2.4 정규식 검증 — #120 §11 인터페이스 보호
if [[ ! "$MAIN_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  _post_marker_E "main_sha_unresolved" "획득 경로(인자/댓글/git) 모두 실패 또는 형식 위반"
  exit 1
fi

ISSUE="${ISSUE_OVERRIDE:-$CANDIDATE_ISSUE}"
echo "[deploy-prod] §2 main_sha=$MAIN_SHA (source=$MAIN_SHA_SOURCE) issue=#${ISSUE:-N/A}"
```

핵심 제약:

- 정규식 `^[0-9a-f]{40}$` 통과 필수 (#120 §11 인터페이스 일관).
- 이슈 번호를 댓글 grep 과정에서 확보하므로 `--issue=` 미지정 시에도 결과 댓글 등록 가능.
- 이슈 미발견 + 댓글 grep 폴백 실패 → `git rev-parse` 만으로 진행하되 결과 댓글은 stdout 출력으로 대체.

---

## §3 CI/CD Actions workflow_run 대기 (GitHub/Gitea forge 자동 감지)

#119 §12 와 동일하게 `${CLAUDE_PLUGIN_ROOT}/scripts/actions-wait.sh` 헬퍼를 사용하되,
`--branch main` + `--sha $MAIN_SHA` 로 호출한다.

```bash
# >>> workflow-resolve:prod >>>
# prod 키 체인 — deploy_workflow_prod 가 1순위. null·""·부재는 모두 미설정으로 취급(AC-7/AC-8).
WORKFLOW_KEYS="deploy_workflow_prod deploy_workflow github_actions_workflow"
WORKFLOW_KEY_HINT="\`deploy_workflow_prod\`(권장) 또는 \`deploy_workflow\`"
WORKFLOW=""; WORKFLOW_SOURCE="default"
for _k in $WORKFLOW_KEYS; do
  _v=$(jq -r --arg k "$_k" '.[$k] // empty' .claude/config.json 2>/dev/null || echo "")
  if [[ -n "$_v" ]]; then WORKFLOW="$_v"; WORKFLOW_SOURCE="$_k"; break; fi
done
[[ -z "$WORKFLOW" ]] && WORKFLOW="deploy-cf.yml"
# <<< workflow-resolve:prod <<<

DEPLOY_WAIT=$(jq -r '.e2e_deploy_wait_sec // 120' .claude/config.json)
echo "[deploy-prod] §3 workflow=$WORKFLOW (source=$WORKFLOW_SOURCE) branch=main sha=$MAIN_SHA"
```

> 위 블록을 감싼 `workflow-resolve:prod` 앵커 주석은 **테스트가 코드를 추출하는 지점**이다. 앵커 문자열 자체를 임의로 바꾸지 말 것.

```bash
# §3.1~3.3 run 대기 — forge 자동 감지 헬퍼 (GitHub=gh CLI / Gitea=REST API)
#   main 에는 여러 run 이 누적되므로 --sha 매칭 필수.
#   출력 계약: 마지막 stdout 줄 "RUN_ID=<id> RUN_URL=<url> CONCLUSION=<...>"
#   종료 코드: 0=success / 1=failure·cancelled / 124=timeout / 2=run 미발견
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[deploy-prod] §3 DRY-RUN: actions-wait 스킵"
  WORKFLOW_EXIT=0; RUN_ID="dryrun"; RUN_URL=""
else
  WAIT_LINE=$("${CLAUDE_PLUGIN_ROOT}/scripts/actions-wait.sh" \
    --branch main --sha "$MAIN_SHA" --workflow "$WORKFLOW" --timeout "$DEPLOY_WAIT")
  WORKFLOW_EXIT=$?
  RUN_ID=$(sed -E 's/.*RUN_ID=([^ ]*).*/\1/' <<<"$WAIT_LINE")
  RUN_URL=$(sed -E 's/.*RUN_URL=([^ ]*).*/\1/' <<<"$WAIT_LINE")
fi

# §3.2 run 미발견 → 시나리오 E
if [[ $WORKFLOW_EXIT -eq 2 ]]; then
  _post_marker_E "actions_run_not_found" \
    "workflow=$WORKFLOW (적용 키: $WORKFLOW_SOURCE), branch=main, head_sha=$MAIN_SHA 의 run 을 30초 내 미발견. 확인: .claude/config.json 의 $WORKFLOW_KEY_HINT, 그리고 .gitea/workflows/$WORKFLOW · .github/workflows/$WORKFLOW 존재 여부"
  exit 1
fi

# §3.4 Actions FAIL → 시나리오 E
if [[ $WORKFLOW_EXIT -ne 0 ]]; then
  if [[ $WORKFLOW_EXIT -eq 124 ]]; then
    REASON="timeout(${DEPLOY_WAIT}s)"
  else
    REASON="actions_failed"
  fi
  _post_marker_E "$REASON" "워크플로우=$WORKFLOW run_id=$RUN_ID run_url=$RUN_URL"
  exit 1
fi
```

#119 §12 와의 차이점:

- `--branch main`
- `--sha $MAIN_SHA` 필터 추가 (main 에는 여러 run 이 누적되므로 SHA 매칭 필수)
- 자동 롤백 정책 — Actions 단계 실패는 **롤백 대상 아님** (배포가 안 됐으므로 롤백할 deployment 없음)

---

## §4 프로덕션 헬스체크 (deployed_sha 매칭)

#119 §13 의 코드를 `cf_prod_url` / `e2e_prod_url` 로 변형하여 재사용한다.

```bash
# 배포 대상 무관 — `prod_url` 이 일반 이름이고 `cf_prod_url` 은 옛 이름(호환 유지)이다.
CF_PROD_URL_BASE=$(jq -r '.prod_url // .cf_prod_url // ""' .claude/config.json)
CF_PROD_URL_RAW=$(jq -r '.e2e_prod_url // .prod_url // .cf_prod_url // ""' .claude/config.json)
CF_PROD_URL="${CF_PROD_URL_RAW//\$\{cf_prod_url\}/$CF_PROD_URL_BASE}"
HC_PATH=$(jq -r '.e2e_healthcheck_path // "/health"' .claude/config.json)

HC_URL_ASSEMBLED="$CF_PROD_URL"
# >>> deploy-prod:healthcheck-gate >>>
# 선행 변수(앵커 밖): HC_URL_ASSEMBLED — 치환 완료된 헬스체크 base URL (빈 문자열 허용)
# 산출 변수(앵커 밖에서 소비): HC_SKIP("true"|"false") · HC_SKIP_REASON · HC_PLATFORM
# 판정: platform=cli AND URL 전부 빈 값 → SKIP. 그 외 전부 CHECK(종전 동작).
HC_URL_ASSEMBLED="${HC_URL_ASSEMBLED:-}"
HC_PLATFORM=$(jq -r '.agent_hints.platform // ""' .claude/config.json 2>/dev/null || echo "")
if [[ -z "$HC_PLATFORM" && -f .reviewer/profile.yaml ]]; then
  HC_PLATFORM=$(grep -E '^[[:space:]]*platform:[[:space:]]*' .reviewer/profile.yaml 2>/dev/null \
    | head -1 | sed -E 's/^[[:space:]]*platform:[[:space:]]*"?([A-Za-z]+)"?.*$/\1/')
fi
HC_PLATFORM="${HC_PLATFORM:-}"
HC_SKIP=false
HC_SKIP_REASON=""
if [[ -z "${HC_URL_ASSEMBLED//[[:space:]]/}" && "$HC_PLATFORM" == "cli" ]]; then
  HC_SKIP=true
  HC_SKIP_REASON="platform_cli"
fi
# <<< deploy-prod:healthcheck-gate <<<

if [[ "$HC_SKIP" == "true" ]]; then
  _post_marker_HC_SKIP "prod"
  echo "[deploy-prod] §4 헬스체크 스킵 (사유=$HC_SKIP_REASON) — smoke E2E·Q4-B 자동 롤백 대상 제외"
  exit 0
fi

if [[ -z "$CF_PROD_URL" ]]; then
  _post_marker_E "empty_prod_url" "cf_prod_url / e2e_prod_url 모두 비어있음"
  exit 1
fi

EXPECTED_SHA="$MAIN_SHA"
EXPECTED_SHORT="${EXPECTED_SHA:0:7}"
HC_URL="${CF_PROD_URL%/}${HC_PATH}"

# §4.1 폴링 (최대 30회 × 5초 = 150초)
HC_PASS=false
DEPLOYED_SHA=""
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[deploy-prod] §4 DRY-RUN: 헬스체크 폴링 스킵"
  HC_PASS=true
  DEPLOYED_SHA="$EXPECTED_SHA"
else
  for i in $(seq 1 30); do
    RESP=$(curl -s -m 5 "$HC_URL" 2>/dev/null || echo "")
    DEPLOYED_SHA=$(echo "$RESP" | jq -r '.deployed_sha // ""' 2>/dev/null)
    if [[ -n "$DEPLOYED_SHA" ]]; then
      if [[ "$DEPLOYED_SHA" == "$EXPECTED_SHA" ]] \
        || [[ "$DEPLOYED_SHA" == "$EXPECTED_SHORT" ]] \
        || [[ "$EXPECTED_SHA" == "$DEPLOYED_SHA"* ]]; then
        HC_PASS=true
        break
      fi
    fi
    sleep 5
  done
fi

# §4.2 헬스체크 타임아웃 → 시나리오 E
if [[ "$HC_PASS" != "true" ]]; then
  _post_marker_E "health_timeout" \
    "URL=$HC_URL expected=$EXPECTED_SHA actual=${DEPLOYED_SHA:-none}"
  exit 1
fi

echo "[deploy-prod] §4 헬스체크 통과 (SHA=$EXPECTED_SHORT)"
```

#119 §13 과의 차이점:

- `cf_dev_url` → `cf_prod_url`
- `e2e_dev_url` → `e2e_prod_url`
- 폴링 횟수/간격 동일 (30회 × 5초 = 150초)

---

## §5 BLAST_RADIUS_GUARD 사전 검사 (외부 G4 게이트)

qa-e2e G4 게이트는 에이전트 내부에서도 확인하지만, **외부에서 한 번 더 차단**하여 prod 안전성을 이중 보장한다.

```bash
if [[ -z "${BLAST_RADIUS_GUARD:-}" ]]; then
  ENV_ERR_BODY="## ⚠️ Prod E2E 환경 오류

E2E_ENV_ERROR=BLAST_RADIUS_GUARD_MISSING

- 사유: BLAST_RADIUS_GUARD 환경변수 미설정 (qa-e2e G4 게이트)
- 가이드: \`BLAST_RADIUS_GUARD=1 /aiops:deploy-prod\` 형태로 재실행
- 참고: claude-ai-devops/agents/qa-e2e.md §4 G4"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[deploy-prod] §5 DRY-RUN: 환경 오류 댓글 미등록 (BLAST_RADIUS_GUARD 미설정 감지)"
    echo "$ENV_ERR_BODY"
  elif [[ -n "$ISSUE" ]]; then
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-comment "$ISSUE" "$ENV_ERR_BODY" >/dev/null 2>&1 || echo "$ENV_ERR_BODY"
  else
    echo "$ENV_ERR_BODY"
  fi
  exit 2
fi
```

핵심 제약:

- 종료 코드 `2` (qa-e2e 규약과 일관).
- 댓글 헤더 `## ⚠️ Prod E2E 환경 오류` 는 PRD §5 인터페이스 계약과 바이트 단위 일치.
- `E2E_ENV_ERROR=BLAST_RADIUS_GUARD_MISSING` (대문자 + 언더스코어) — PRD AC-4 명시 값.

---

## §6 smoke E2E 실행

CC harness 내부에서는 Agent 도구로 호출:

```
Agent("qa-e2e", "--env=prod --mode=smoke --issue=<ISSUE>")
```

헤드리스 셸 동등 호출:

```bash
E2E_OUTPUT_FILE=$(mktemp)
E2E_EXIT=0

# dry-run mock 판별 기준(#55): "바깥으로 나가는 결과 토큰"이면 DRY_RUN 으로 분리하고,
# "안에서만 쓰는 단계 스킵 플래그"(175·262·438 등)면 현행 유지 — 바꾸면 오히려 나빠진다.
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[deploy-prod] §6 DRY-RUN: smoke E2E 미실행 (내부 토큰 DRY_RUN)"
  echo "E2E_RESULT=DRY_RUN" > "$E2E_OUTPUT_FILE"
  E2E_EXIT=0
else
  {
    BLAST_RADIUS_GUARD="$BLAST_RADIUS_GUARD" \
    ./run-qa-e2e.sh --env=prod --mode=smoke --issue="${ISSUE:-}" 2>&1
  } | tee "$E2E_OUTPUT_FILE"
  E2E_EXIT=${PIPESTATUS[0]}
fi

E2E_LAST_LINE=$(tail -n 1 "$E2E_OUTPUT_FILE" | tr -d '\r\n')
```

핵심 제약:

- `BLAST_RADIUS_GUARD` 인라인 전달 — qa-e2e G4 통과용.
- qa-e2e 가 이미 `## 🌐 Prod E2E 결과 — smoke` 헤더 댓글을 등록하므로 본 SKILL.md 는 §7 에서 **추가 마커만** 등록 (중복 헤더 금지).

---

## §7 결과 분기 + Q4-B 자동 롤백

3분기 + 롤백 서브플로우 = 시나리오 A/B/C/D/E + S1(FAIL_NO_ROLLBACK) 매핑.

```bash
# >>> deploy-prod:e2e-result-case >>>
case "$E2E_EXIT:$E2E_LAST_LINE" in

  # ─── 시나리오 A — smoke PASS ────────────────────
  0:E2E_RESULT=PASS)
    _post_marker_A "$DEPLOYED_SHA"
    exit 0
    ;;

  # ─── DRY-RUN — 계획만 출력, 마커 미등록 (#55) ────
  # 순서 제약: 이 팔은 반드시 0:E2E_RESULT=PASS) 뒤, 1:E2E_RESULT=FAIL) 앞.
  0:E2E_RESULT=DRY_RUN)
    echo "[deploy-prod] §7 DRY-RUN: 검증 계획만 출력 — 마커 미등록"
    echo "  main_sha        = ${MAIN_SHA:-N/A}"
    echo "  deployed_sha    = (미조회 — 헬스체크 스킵)"
    echo "  smoke 대상      = --env=prod --mode=smoke"
    echo "  blast_radius    = ${BLAST_RADIUS_GUARD:+set}"
    echo "  실행 시 등록될 마커 = 시나리오 A (smoke 통과 경로)"
    echo "  실제 등록 마커  = 없음"
    echo "[deploy-prod] DRY-RUN 종료 — prod 검증 통과 신호가 아님"
    exit 0
    ;;

  # ─── smoke FAIL → 시나리오 B/C 또는 FAIL_NO_ROLLBACK ──
  1:E2E_RESULT=FAIL)

    # §7.1 --skip-rollback → FAIL_NO_ROLLBACK 마커 후 종료
    if [[ "$SKIP_ROLLBACK" == "true" ]]; then
      _post_marker_FAIL_NO_ROLLBACK
      exit 1
    fi

    # §7.2 --confirm-rollback → 사용자 확인
    if [[ "$CONFIRM_ROLLBACK" == "true" && -t 0 ]]; then
      echo
      read -r -p "Prod smoke FAIL — 자동 롤백을 진행하시겠습니까? [y/N] " ANS
      if [[ ! "$ANS" =~ ^[yY]$ ]]; then
        _post_marker_FAIL_NO_ROLLBACK
        exit 1
      fi
    fi

    # §7.3 이전 deployment_id 획득 (Q4-B C1 옵션)
    PREV_DEPLOY=""
    PREV_DEPLOY_SHA=""
    if [[ "$DRY_RUN" != "true" ]]; then
      PREV_DEPLOY=$(wrangler deployments list --env production --json 2>/dev/null \
        | jq -r '.[1].id // ""')
      PREV_DEPLOY_SHA=$(wrangler deployments list --env production --json 2>/dev/null \
        | jq -r '.[1].metadata.head_sha // ""')
    else
      PREV_DEPLOY="dryrun-prev-deploy-id"
      PREV_DEPLOY_SHA="dryrun-prev-sha"
    fi

    if [[ -z "$PREV_DEPLOY" ]]; then
      _post_marker_ROLLBACK_UNAVAILABLE
      exit 1
    fi

    # §7.4 wrangler rollback 실행
    if [[ "$DRY_RUN" != "true" ]]; then
      wrangler rollback "$PREV_DEPLOY" --env production
      ROLLBACK_EXIT=$?
    else
      ROLLBACK_EXIT=0
    fi

    if [[ $ROLLBACK_EXIT -ne 0 ]]; then
      _post_marker_C "$PREV_DEPLOY" "rollback_command_failed"
      exit 1
    fi

    # §7.5 헬스체크 (롤백된 SHA 매칭)
    sleep 30
    HC_RETRY_PASS=false
    if [[ "$DRY_RUN" == "true" ]]; then
      HC_RETRY_PASS=true
    else
      for i in $(seq 1 30); do
        RESP=$(curl -s -m 5 "$HC_URL" 2>/dev/null || echo "")
        ROLLED_SHA=$(echo "$RESP" | jq -r '.deployed_sha // ""' 2>/dev/null)
        if [[ -n "$PREV_DEPLOY_SHA" && -n "$ROLLED_SHA" ]]; then
          if [[ "$ROLLED_SHA" == "$PREV_DEPLOY_SHA" ]] \
            || [[ "$PREV_DEPLOY_SHA" == "$ROLLED_SHA"* ]] \
            || [[ "$ROLLED_SHA" == "$PREV_DEPLOY_SHA"* ]]; then
            HC_RETRY_PASS=true
            break
          fi
        fi
        sleep 5
      done
    fi

    if [[ "$HC_RETRY_PASS" != "true" ]]; then
      _post_marker_C "$PREV_DEPLOY" "rollback_healthcheck_timeout"
      exit 1
    fi

    # §7.6 재 smoke E2E
    RETRY_OUTPUT_FILE=$(mktemp)
    # dry-run mock 판별 기준(#55): "바깥으로 나가는 결과 토큰"이면 DRY_RUN 으로 분리하고,
    # "안에서만 쓰는 단계 스킵 플래그"(175·262·438 등)면 현행 유지 — 바꾸면 오히려 나빠진다.
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[deploy-prod] §7.6 DRY-RUN: 재 smoke 미실행 (내부 토큰 DRY_RUN)"
      echo "E2E_RESULT=DRY_RUN" > "$RETRY_OUTPUT_FILE"
      RETRY_EXIT=0
    else
      {
        BLAST_RADIUS_GUARD="$BLAST_RADIUS_GUARD" \
        ./run-qa-e2e.sh --env=prod --mode=smoke --issue="${ISSUE:-}" 2>&1
      } | tee "$RETRY_OUTPUT_FILE"
      RETRY_EXIT=${PIPESTATUS[0]}
    fi
    RETRY_LAST_LINE=$(tail -n 1 "$RETRY_OUTPUT_FILE" | tr -d '\r\n')

    # >>> deploy-prod:retry-result-case >>>
    case "$RETRY_EXIT:$RETRY_LAST_LINE" in
      0:E2E_RESULT=PASS)
        # 시나리오 B — 롤백 성공
        _post_marker_B "$PREV_DEPLOY"
        exit 1   # 머지된 main 변경은 실패한 상태이므로 비정상 종료 (hotfix 강제 트리거)
        ;;
      # ─── DRY-RUN — 롤백 검증 계획만 출력 (#55) ────
      # 순서 제약(강): 이 팔이 *) 보다 앞에 없으면 dry-run 이 시나리오 C(거짓 시나리오 C 마커 등록)를 타서
      # 거짓 위험 경보를 발사한다. 토큰만 바꾸고 이 팔을 빼면 고치기 전보다 나빠진다.
      0:E2E_RESULT=DRY_RUN)
        echo "[deploy-prod] §7.6 DRY-RUN: 롤백 검증 계획만 출력 — 마커 미등록"
        echo "  rolled_back_to  = ${PREV_DEPLOY:-N/A}"
        echo "  실행 시 등록될 마커 = 시나리오 B 또는 C"
        echo "  실제 등록 마커  = 없음"
        echo "[deploy-prod] DRY-RUN 종료 — prod 검증 통과 신호가 아님"
        exit 0
        ;;
      *)
        # 시나리오 C — 롤백 후에도 FAIL
        _post_marker_C "$PREV_DEPLOY" "$RETRY_LAST_LINE"
        exit 1
        ;;
    esac
    # <<< deploy-prod:retry-result-case <<<
    ;;

  # ─── 시나리오 D — qa-e2e 환경 오류 (G1~G5) ──────
  2:E2E_ENV_ERROR=*)
    REASON="${E2E_LAST_LINE#E2E_ENV_ERROR=}"
    _post_marker_D "$REASON"
    exit 2
    ;;

  # ─── 프로토콜 위반 ─────────────────────────────
  *)
    _post_marker_D "qa_e2e_protocol_violation:exit=$E2E_EXIT,last_line=$(echo "$E2E_LAST_LINE" | head -c 80)"
    exit 2
    ;;
esac
# <<< deploy-prod:e2e-result-case <<<
```

핵심 제약:

- 종료 코드와 마지막 줄 **이중 검증** (#119 §14.2 패턴 일관).
- 시나리오 B (롤백 성공) 도 `exit 1` — main 머지 자체는 회귀로 간주되어야 후속 hotfix 가 트리거됨.
- DRY-RUN 시 wrangler / curl / qa-e2e / gh comment 모두 mock — 실제 부수효과 0건.

---

## §9 마커 매트릭스 (5종 + 보조 2종, 불변 계약)

EM DASH `—` = U+2014 (UTF-8 `0xE2 0x80 0x94`). EN DASH (U+2013) / HYPHEN (U+002D) 와 절대 혼동 금지.

### 9.1 헬퍼 함수

```bash
_now() { date -u +%FT%TZ; }

_post() {
  # $1 = 댓글 본문
  local BODY="$1"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[deploy-prod] DRY-RUN 댓글 미등록 — 본문:"
    echo "$BODY"
  elif [[ -n "$ISSUE" ]]; then
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-comment "$ISSUE" "$BODY" >/dev/null 2>&1 || echo "$BODY"
  else
    echo "$BODY"
  fi
}

# 시나리오 A — smoke PASS
_post_marker_A() {
  local DEPLOYED="$1"
  _post "## 🚀 Prod 배포 검증

- main_sha=$MAIN_SHA
- deployed_sha=$DEPLOYED
- smoke 결과: PASS
- PROD_RESULT=PASS
- verified_at: $(_now)"
}

# 시나리오 B — 롤백 후 PASS
_post_marker_B() {
  local ROLLED_TO="$1"
  _post "## ⚠️ Prod 자동 롤백 완료

- main_sha=$MAIN_SHA
- rolled_back_to=$ROLLED_TO
- 재 smoke 결과: PASS
- PROD_RESULT=ROLLBACK_PASS
- 다음 액션: 운영자가 hotfix 진행 (main 의 회귀 원인 분석)
- rolled_back_at: $(_now)"
}

# 시나리오 C — 롤백 후에도 FAIL  (EM-DASH U+2014)
_post_marker_C() {
  local ROLLED_TO="$1"
  local REASON="$2"
  _post "## 🚨 Prod 롤백 후 FAIL — 운영자 즉시 확인

- main_sha=$MAIN_SHA
- rolled_back_to=$ROLLED_TO
- 재 smoke: $REASON
- PROD_RESULT=ROLLBACK_FAIL
- 다음 액션: 운영자가 prod 환경을 직접 점검 (CF 워커 상태 / DB / 외부 서비스)
- failed_at: $(_now)"
}

# 시나리오 D — qa-e2e 환경 오류
_post_marker_D() {
  local REASON="$1"
  _post "## ⚠️ Prod E2E 환경 오류

E2E_ENV_ERROR=$REASON

- 가이드: \`claude-ai-devops/docs/e2e-quick-start.md\` G1~G5 트러블슈팅 참조
- 다음 액션: 환경 설정 보정 후 \`/aiops:deploy-prod\` 재시도"
}

# 시나리오 E — 배포 검증 실패
_post_marker_E() {
  local REASON="$1"
  local DETAIL="$2"
  _post "## ⚠️ Prod 배포 검증 실패

- 사유: \`$REASON\`
- 상세: $DETAIL
- main_sha=${MAIN_SHA:-N/A}
- 다음 액션:
  - actions_failed → CI 로그 확인 후 재실행
  - timeout → 워크플로우 진행 상황 확인 후 \`/aiops:deploy-prod\` 재시도
  - health_timeout → \`/health\` 응답에 \`deployed_sha\` 포함 여부 확인
  - main_sha_unresolved → \`/aiops:merge-main\` 재실행 또는 \`--main-sha=<SHA>\` 명시"
}

# S1: FAIL_NO_ROLLBACK — --skip-rollback 모드
_post_marker_FAIL_NO_ROLLBACK() {
  _post "## ❌ Prod smoke FAIL (--skip-rollback)

- main_sha=$MAIN_SHA
- smoke 결과: FAIL
- PROD_RESULT=FAIL_NO_ROLLBACK
- 다음 액션: 수동 wrangler rollback 또는 hotfix PR
- failed_at: $(_now)"
}

# 보조: 롤백 불가 — 이전 deployment 미존재 (시나리오 C 클래스로 분류)
_post_marker_ROLLBACK_UNAVAILABLE() {
  _post "## 🚨 Prod 롤백 후 FAIL — 운영자 즉시 확인

- main_sha=$MAIN_SHA
- rolled_back_to=(불가 — 이전 deployment 미존재)
- PROD_RESULT=ROLLBACK_FAIL
- 다음 액션: 수동 hotfix PR + wrangler deployments list 점검
- failed_at: $(_now)"
}

# 보조: 헬스체크 스킵 — 배포 대상 없음 (#42)
_post_marker_HC_SKIP() {
  local ENV="$1"
  _post "## ℹ️ 헬스체크 스킵

healthcheck_skipped=platform_cli

- 환경: $ENV
- 스킬: /aiops:deploy-prod §4
- 사유: platform=cli 이며 prod_url / cf_prod_url / e2e_prod_url 이 모두 비어 있음 — 헬스체크 대상 없음
- smoke E2E: 스킵 (prod URL 없음)
- Q4-B 자동 롤백: 대상 제외 — 배포 산출물이 없어 롤백할 deployment 가 존재하지 않음 (wrangler deployments 조회 자체를 수행하지 않음)
- main_sha=${MAIN_SHA:-N/A}
- 다음 액션: 없음 (정상 종료, exit 0)"
}
```

### 9.2 마커 매트릭스 표 (불변 — #122 문서 색인 입력)

| 시나리오 | 헤더 라벨 (`^...$` 정확 일치) | PROD_RESULT | 핵심 본문 키 | exit |
|----------|------------------------------|-------------|--------------|------|
| **A. smoke PASS** | `## 🚀 Prod 배포 검증` | `PASS` | `main_sha`, `deployed_sha` | 0 |
| **B. 롤백 후 PASS** | `## ⚠️ Prod 자동 롤백 완료` | `ROLLBACK_PASS` | `main_sha`, `rolled_back_to` | 1 |
| **C. 롤백 후 FAIL** | `## 🚨 Prod 롤백 후 FAIL — 운영자 즉시 확인` | `ROLLBACK_FAIL` | `main_sha`, `rolled_back_to` | 1 |
| **D. 환경 오류** | `## ⚠️ Prod E2E 환경 오류` | — | `E2E_ENV_ERROR=<reason>` | 2 |
| **E. 배포 검증 실패** | `## ⚠️ Prod 배포 검증 실패` | — | `reason`, `main_sha` | 1 |
| (S1) FAIL_NO_ROLLBACK | `## ❌ Prod smoke FAIL (--skip-rollback)` | `FAIL_NO_ROLLBACK` | `main_sha` | 1 |
| **F. 헬스체크 스킵** (#42) | `## ℹ️ 헬스체크 스킵` | — | `healthcheck_skipped=platform_cli` | 0 |

> 본 매트릭스는 PRD §5 인터페이스 계약과 1:1 동일. 헤더 / 키 명칭 변경 시 #122 문서와 동시 업데이트 의무.

---

## §10 검증 절차 (AC-1~AC-10)

| AC | 시나리오 | 검증 명령 |
|----|----------|-----------|
| AC-1 | smoke PASS | `forge.sh issue-comments <N> \| grep -E '^## 🚀 Prod 배포 검증$'` ≥ 1 + `grep 'PROD_RESULT=PASS'` ≥ 1 |
| AC-2 | 롤백 후 PASS | `grep -E '^## ⚠️ Prod 자동 롤백 완료$'` + `grep 'PROD_RESULT=ROLLBACK_PASS'` + `grep 'rolled_back_to='` |
| AC-3 | 롤백 후 FAIL | `grep -E '^## 🚨 Prod 롤백 후 FAIL — 운영자 즉시 확인$'` + `grep 'PROD_RESULT=ROLLBACK_FAIL'` |
| AC-4 | BLAST_RADIUS_GUARD 미설정 | `unset BLAST_RADIUS_GUARD; /aiops:deploy-prod` → `## ⚠️ Prod E2E 환경 오류` + `E2E_ENV_ERROR=BLAST_RADIUS_GUARD_MISSING`, smoke 미실행 |
| AC-5 | Actions FAIL / healthcheck timeout | `## ⚠️ Prod 배포 검증 실패` + `reason=actions_failed` 또는 `reason=health_timeout` |
| AC-6 | 헤더 5종 정확 일치 | `grep -cE '^## (🚀 Prod 배포 검증\|⚠️ Prod 자동 롤백 완료\|🚨 Prod 롤백 후 FAIL — 운영자 즉시 확인\|⚠️ Prod E2E 환경 오류\|⚠️ Prod 배포 검증 실패)$'` = 5 |
| AC-7 | Q3-C smoke 자동 정리 | qa-e2e `04-critical-crud.spec.ts` afterEach 정상 종료 (#117 위임) |
| AC-8 | `--skip-rollback` + FAIL | wrangler rollback 미호출 + `## ❌ Prod smoke FAIL (--skip-rollback)` + `PROD_RESULT=FAIL_NO_ROLLBACK` |
| AC-10 | main_sha 미획득 | `## ⚠️ Prod 배포 검증 실패` + `reason=main_sha_unresolved` + exit 1 |

> AC-9 는 외부 알림 옵션 전제 검증이었으나 해당 기능 제거로 삭제됐다(#55). 번호는 이력 참조를 위해 재배번하지 않는다.

### 10.1 DRY-RUN 회귀 시나리오 (수동 QA)

dry-run 은 마커를 등록하지 않으며 마커 헤더 모양(`^## ` 로 시작하는 줄)을 출력하지 않는다(#55).
기대 출력은 `[deploy-prod]` 접두 평문 계획 줄이다.

| 케이스 | 명령 | 기대 stdout 마지막 줄 | 헤더 줄 | exit |
|--------|------|----------------------|---------|------|
| 정상 | `BLAST_RADIUS_GUARD=1 /aiops:deploy-prod --dry-run` | `[deploy-prod] DRY-RUN 종료 — prod 검증 통과 신호가 아님` | 없음 | 0 |
| 환경 오류 | `unset BLAST_RADIUS_GUARD; /aiops:deploy-prod --dry-run` | `- 참고: …qa-e2e.md §4 G4` | `## ⚠️ Prod E2E 환경 오류` (§5 가드 불변) | 2 |
| 수동 SHA | `BLAST_RADIUS_GUARD=1 /aiops:deploy-prod --dry-run --main-sha=$(printf 'a%.0s' {1..40})` | 정상 케이스와 동일 평문 계획 블록 | 없음 | 0 |
| SHA 위반 | `/aiops:deploy-prod --dry-run --main-sha=invalid` | `reason=main_sha_unresolved` | `## ⚠️ Prod 배포 검증 실패` (§7 도달 전 — 불변) | 1 |

> "환경 오류"·"SHA 위반" 두 행이 여전히 마커 헤더를 갖는 것은 **의도된 결과**다.
> 두 경로는 §7 case 에 도달하기 전에 종료하며 결정 2의 "출력 가드" 계열이라 범위 밖이다.

### 10.2 EM-DASH 바이트 검증

시나리오 C 의 헤더는 EM DASH (U+2014, UTF-8 `0xE2 0x80 0x94`) 를 사용한다. 본 파일을 수정한 뒤 다음 명령으로 바이트를 검증한다:

```bash
grep -E '^## 🚨 Prod 롤백 후 FAIL ' claude-ai-devops/skills/aiops:deploy-prod/SKILL.md \
  | head -1 | hexdump -C | head -3
# 기대 시퀀스: ... 46 41 49 4c 20 E2 80 94 20 ec 9a b4 ec 98 81 ...
#                            ^^^^^^^^ (U+2014 EM-DASH)
```

### 10.3 DRY-RUN 종료 코드 계약 (#55 — 값 불변, 의미 명문화)

| dry-run 상황 | exit | 의미 |
|---|---|---|
| 계획 해석 성공 (§7 dry-run 팔 도달) | 0 | 계획 출력만 — **prod 검증 통과 신호가 아니며** 마커를 등록하지 않는다 |
| §7.6 롤백 검증 계획 출력 | 0 | 동일 — 롤백 성공 신호가 아니다 |
| `BLAST_RADIUS_GUARD` 미설정 (§5) | 2 | 환경 오류 — 현행 유지 |
| `main_sha` 미해석 (`--main-sha=invalid`) | 1 | 입력 오류 — 현행 유지 |

종료 코드 **값은 바뀌지 않는다**. `qa-e2e.md` 177행과 같은 취지다 —
0 은 dry-run 이 오류가 아님을 뜻할 뿐, 어떤 게이트에도 통과 신호로 취급되지 않는다.

---

## 사용 예

```bash
# 정상 배포 검증 (Orchestrator 호출)
BLAST_RADIUS_GUARD=1 /aiops:deploy-prod

# DRY-RUN — 분기 시뮬레이션
BLAST_RADIUS_GUARD=1 /aiops:deploy-prod --dry-run

# 긴급 점검 (자동 롤백 비활성)
BLAST_RADIUS_GUARD=1 /aiops:deploy-prod --skip-rollback

# 사용자 확인 후 롤백
BLAST_RADIUS_GUARD=1 /aiops:deploy-prod --confirm-rollback

# main_sha 수동 명시 (#120 댓글 누락 시)
BLAST_RADIUS_GUARD=1 /aiops:deploy-prod --main-sha=abcdef0123456789abcdef0123456789abcdef01 --issue=121
```

---

## 호출 시점

`/aiops:deploy-prod` 는 다음 흐름에서 자동 호출된다:

1. `/aiops:merge-main` 종료 → `## 🚀 main 머지 완료` 댓글 + `main_sha=<40-hex>` 라인 등록
2. Orchestrator 가 본 스킬 호출 (`BLAST_RADIUS_GUARD=1 /aiops:deploy-prod`)
3. 본 스킬이 5종 마커 중 하나를 등록하고 종료 코드 반환
4. 시나리오 B/C 또는 FAIL_NO_ROLLBACK 발생 시 운영자가 hotfix PR 생성

---

## 의존 스킬 / 에이전트

| 의존 | 역할 |
|------|------|
| `/aiops:merge-main` (#120) | `main_sha=<40-hex>` 라인 인터페이스 제공 |
| qa-e2e (#117) | `--env=prod --mode=smoke` 실행 + G4 BLAST_RADIUS_GUARD 게이트 |
| `/aiops:merge-pr` (#119) | §11~§17 코드 패턴 재사용 (workflow_run 대기 / 헬스체크 헬퍼) |

본 스킬 완료 후 `/aiops:update-docs` (#122) 가 총 10종 마커를 일괄 색인한다.
