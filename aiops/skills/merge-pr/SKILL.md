---
name: merge-pr
description: "PR 병합 + 정리 + dev 배포 대기 + dev E2E 자동 실행. issue-N → dev 머지 후 CI/CD Actions(GitHub/Gitea 자동 감지) workflow_run 완료를 대기하고 /health deployed_sha 매칭 후 qa-e2e --env=dev --mode=full 을 자동 트리거하여 결과 마커 댓글까지 등록."
---
이슈 PR을 병합하고 정리 작업을 수행합니다.

> **이 스킬은 issue-N → dev 머지만 수행합니다. dev → main 승격은 `/aiops:promote` (또는 #120 `/aiops:merge-main`) 스킬을 사용하세요.**

> **§11~§14 dev E2E 자동 진행 통합**: 머지 후 CI(Actions) 완료 대기 → 헬스체크 → dev E2E 자동 실행 → 결과 마커 댓글 등록 흐름이 포함됩니다 (`e2e_test_enabled=true` 인 프로젝트만, `--skip-e2e` 로 우회 가능).

## 1. 인자 파싱

`$ARGUMENTS`에서 이슈 번호와 옵션 플래그를 추출합니다:
- **ISSUE_NUMBER**: `#숫자` 또는 숫자 → 없으면 에러
- **`--skip-e2e`** (선택): §11~§14 (배포 대기 + 헬스체크 + dev E2E) 흐름 전체 스킵. §1~§10 (머지/정리/댓글) 만 수행.
- **`--run-e2e`** (선택, #131 신규): §14 dev E2E 자동 실행을 강제로 켭니다. 기본은 SKIP (config `e2e_run_on_merge_pr=false`). 설정 우선순위: `--run-e2e` > `e2e_run_on_merge_pr` > 기본 false.

```bash
# §1.1 인자 파싱
ISSUE_NUMBER=""
SKIP_E2E=false
RUN_E2E_ARG=false
for arg in $ARGUMENTS; do
  case "$arg" in
    --skip-e2e) SKIP_E2E=true ;;
    --run-e2e)  RUN_E2E_ARG=true ;;
    \#*) ISSUE_NUMBER="${arg#\#}" ;;
    [0-9]*) ISSUE_NUMBER="$arg" ;;
  esac
done

if [[ -z "$ISSUE_NUMBER" ]]; then
  echo "ERROR: 이슈 번호가 필요합니다. 예: /aiops:merge-pr 119 [--skip-e2e] [--run-e2e]"
  exit 1
fi

echo "이슈 번호: $ISSUE_NUMBER (skip_e2e=$SKIP_E2E, run_e2e_arg=$RUN_E2E_ARG)"
```

> **#131 정책 변경**: 기존에는 `e2e_test_enabled=true` 면 §14 dev E2E 가 자동 실행되었으나, 시간이 오래 걸려 머지 흐름을 지연시키는 문제로 **기본 SKIP 으로 반전**되었습니다. §11~§13 (Actions 대기 + 헬스체크) 은 그대로 자동 수행되며, §14 만 opt-in 으로 전환됩니다.

## 2. PR 찾기

이슈 브랜치(`issue-<ISSUE_NUMBER>` 또는 `feature/issue-<ISSUE_NUMBER>`)에서 dev로 향하는 열린 PR을 찾습니다:

forge.sh 는 origin 리모트로 GitHub↔Gitea 를 자동 감지하며, `pr-list <head> <base> [state]` 는 매칭된 PR 번호를 줄 단위로 출력합니다(**실행형 — 소싱 금지**).

```bash
# issue-N 브랜치의 열린 PR 검색
bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" pr-list "issue-<ISSUE_NUMBER>" dev open
# 없으면 feature/issue-N 브랜치도 검색
bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" pr-list "feature/issue-<ISSUE_NUMBER>" dev open
```

PR이 없으면:
```bash
# main 대상 PR도 검색
bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" pr-list "issue-<ISSUE_NUMBER>" main open
bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" pr-list "feature/issue-<ISSUE_NUMBER>" main open
```

PR을 찾지 못하면 에러 메시지를 출력하고 종료합니다.

## 3. PR 상태 확인

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" pr-view <PR_NUMBER>
```

- `state` 가 `open` 인지만 확인 (닫힘/머지됨이면 §4 스킵).
- Gitea 는 `reviewDecision` / `statusCheckRollup` 개념이 없으므로 approve 상태·CI 롤업 사전확인은 **생략**합니다. CI 통과 여부는 §12 의 `actions-wait.sh` 로 머지 후 검증합니다.
- `forge.sh pr-review APPROVE` 가 `REVIEWER_TOKEN`(env→KMS) 경로로 해석되면 PR 에 실제 `APPROVED` 리뷰가 남지만, **머지 게이트는 여전히 이를 전제하지 않습니다**(리뷰어 토큰 미보유 환경에서는 COMMENT 강등이 정상이므로 §4 진행에 영향 없음, 이슈 #28).

## 4. PR 병합

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" pr-merge <PR_NUMBER> --delete-branch
```

- 머지 방식은 머지 커밋(스쿼시 아님) — feature→dev 는 origin 브랜치를 삭제(`--delete-branch`).
- 성공 시 `MERGED=1` 을 출력합니다.

병합 실패 시 에러 메시지를 출력하고 종료합니다.

## 5. 리뷰 추적 이슈 닫기

리뷰 추적 이슈가 있으면 닫습니다:

```bash
# 열린 이슈 목록에서 "review"/"리뷰" + issue-<ISSUE_NUMBER> 키워드로 필터 (forge.sh 는 텍스트 검색 미지원 → 목록 grep)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-list --state open \
  | grep -iE "issue-<ISSUE_NUMBER>.*(review|리뷰)|(review|리뷰).*issue-<ISSUE_NUMBER>"
# 출력은 `번호\t제목` — 리뷰 추적 이슈 번호를 추출

# 찾은 리뷰 이슈 닫기 (닫기 코멘트 동반)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-close <REVIEW_ISSUE_NUMBER> "PR #<PR_NUMBER> 병합 완료로 리뷰 이슈를 닫습니다."
```

리뷰 추적 이슈가 없으면 이 단계를 건너뜁니다.

## 6. 베이스 브랜치 최신화

```bash
# 병합 대상 브랜치로 전환 후 최신화
git checkout dev
git pull --ff-only origin dev
```

## 7. 로컬 브랜치 정리

```bash
# 로컬 이슈 브랜치 삭제
git branch -d issue-<ISSUE_NUMBER> 2>/dev/null || true
git branch -d feature/issue-<ISSUE_NUMBER> 2>/dev/null || true

# 원격 추적 브랜치 정리
git fetch --prune
```

## 8. 이슈에 머지 완료 + dev URL 댓글

병합 완료 후, `.claude/config.json`에서 `use_cloudflare_workers`와 `cf_dev_url`을 읽어 조건부로 이슈에 댓글을 등록합니다:

```bash
# 기본값을 true 로 두면 CF 를 쓰지 않는 레포에 CF 경로가 걸린다 — **감지값에서 파생**시킨다.
#   (/aiops:setup 이 deploy_target 을 채운다. 둘 다 없으면 false = 하지 않는 쪽이 안전하다.)
USE_CF=$(jq -r '
  if .use_cloudflare_workers != null then .use_cloudflare_workers
  elif (.agent_hints.frontend.deploy_target // .agent_hints.backend.deploy_target // "") == "cloudflare-workers" then true
  else false end' .claude/config.json 2>/dev/null || echo "false")
CF_DEV_URL=$(jq -r '.dev_url // .cf_dev_url // ""' .claude/config.json 2>/dev/null || echo "")

if [[ "$USE_CF" == "true" ]] && [[ -n "$CF_DEV_URL" ]]; then
  CF_LINE="- dev URL: ${CF_DEV_URL}"
  DEPLOY_LINE="- 배포: CI 에 의해 자동 배포 진행 중"
else
  CF_LINE="- dev URL: 해당 없음 (CF Workers 미사용)"
  DEPLOY_LINE="- 배포: Docker/로컬 환경 기준"
fi

bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-comment <ISSUE_NUMBER> \
  "## ✅ dev 머지 완료

PR #<PR_NUMBER>이 dev 브랜치에 머지되었습니다.

### 테스트 환경
${CF_LINE}
${DEPLOY_LINE}

사용자 테스트 완료 후 main 승격을 진행해주세요."
```

## 9. 머지 후 문서 업데이트

PR 머지 완료 후 `/aiops:update-docs` 스킬을 실행하거나 doc-updater 에이전트를 호출하여 관련 문서를 자동 업데이트합니다.

## 10. 결과 출력

```markdown
## ✅ PR 병합 완료

- **PR**: #<PR_NUMBER>
- **이슈**: #<ISSUE_NUMBER>
- **병합 대상**: dev
- **원격 브랜치**: 삭제됨
- **로컬 브랜치**: 삭제됨
- **리뷰 이슈**: 닫힘 / 해당없음
- **현재 브랜치**: dev (최신)
- **dev URL**: 이슈 댓글에 등록됨
```

---

## 11. config 게이트 (e2e_test_enabled 토글 + --skip-e2e)

기존 §1~§10 (머지 + 정리 + `## ✅ dev 머지 완료` 댓글) 이 모두 끝난 직후 진입합니다. **§11~§14 는 추가 흐름**이며, `e2e_test_enabled=false` 또는 `--skip-e2e` 인자가 있으면 즉시 종료합니다 (역호환, AC-4).

```bash
# §11.1 --skip-e2e 인자 (§1.1 에서 SKIP_E2E 파싱 완료)
if [[ "$SKIP_E2E" == "true" ]]; then
  echo "[merge-pr] --skip-e2e 지정 — §11~§14 전체 스킵"
  exit 0
fi

# §11.2 config 토글
E2E_ENABLED=$(jq -r '.e2e_test_enabled // false' .claude/config.json 2>/dev/null || echo false)
if [[ "$E2E_ENABLED" != "true" ]]; then
  echo "[merge-pr] e2e_test_enabled=false — §11~§14 전체 스킵 (역호환)"
  exit 0
fi
```

핵심 제약:
- `exit 0` (성공 종료) — §11 스킵은 정상 흐름, 오류 아님.
- 이 구간에서 **신규 댓글 등록 금지** (§8 의 `## ✅ dev 머지 완료` 만 남는다).

---

## 12. CI/CD Actions workflow_run 완료 대기 (GitHub/Gitea forge 자동 감지)

`.claude/config.json` 의 `deploy_workflow` (구키 `github_actions_workflow` 폴백, 기본값 `deploy-cf.yml`) 와 `e2e_deploy_wait_sec` (기본값 120) 을 사용합니다. 머지 직후 Actions trigger 지연을 고려해 **grace 6회 × 5초 = 최대 30초** 동안 RUN_ID 를 폴링합니다.

```bash
# §12.1 config 로드
WORKFLOW=$(jq -r '.deploy_workflow // .github_actions_workflow // "deploy-cf.yml"' .claude/config.json)
DEPLOY_WAIT=$(jq -r '.e2e_deploy_wait_sec // 120' .claude/config.json)
ISSUE="$ISSUE_NUMBER"

# §12.2~12.4 workflow run 대기 — forge 자동 감지 헬퍼 (GitHub=gh CLI / Gitea=REST API)
#   출력 계약: 마지막 stdout 줄 "RUN_ID=<id> RUN_URL=<url> CONCLUSION=<...>"
#   종료 코드: 0=success / 1=failure·cancelled / 124=timeout / 2=run 미발견
WAIT_LINE=$("${CLAUDE_PLUGIN_ROOT}/scripts/actions-wait.sh" \
  --branch dev --workflow "$WORKFLOW" --timeout "$DEPLOY_WAIT")
WORKFLOW_EXIT=$?
RUN_ID=$(sed -E 's/.*RUN_ID=([^ ]*).*/\1/' <<<"$WAIT_LINE")
RUN_URL=$(sed -E 's/.*RUN_URL=([^ ]*).*/\1/' <<<"$WAIT_LINE")

# §12.3 run 미발견 → 환경 오류 (워크플로우 미정의 등)
if [[ $WORKFLOW_EXIT -eq 2 ]]; then
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-comment "$ISSUE" "## ⚠️ Dev E2E 환경 오류

E2E_ENV_ERROR=workflow_run_not_found:$WORKFLOW

- 워크플로우 \`$WORKFLOW\` 의 head_branch=dev run 을 30초 내 찾지 못함
- 다음 액션: \`.claude/config.json\` 의 \`deploy_workflow\` 필드 확인, 또는 \`.gitea/workflows/$WORKFLOW\`(Gitea) · \`.github/workflows/$WORKFLOW\`(GitHub) 존재 여부 확인"
  _send_telegram_notification "Dev E2E 환경 오류: workflow_run_not_found (issue=$ISSUE)" || true
  exit 2
fi

# §12.5 Actions FAIL / timeout → 시나리오 D
if [[ $WORKFLOW_EXIT -ne 0 ]]; then
  if [[ $WORKFLOW_EXIT -eq 124 ]]; then
    REASON="timeout(${DEPLOY_WAIT}s)"
  else
    REASON="workflow_failed"
  fi

  bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-comment "$ISSUE" "## ⚠️ Dev 배포 검증 실패

- 사유: $REASON
- 워크플로우: \`$WORKFLOW\`
- run_id: $RUN_ID
- run_url: $RUN_URL
- 다음 액션: run_url 로그 확인 후 재시도 (CI 웹 UI 에서 re-run)
- 참고: dev 환경은 자동 롤백을 수행하지 않습니다 (Q4-A)"

  _send_telegram_notification "Dev 배포 검증 실패 ($REASON, issue=$ISSUE, run=$RUN_ID)" || true
  exit 1
fi
```

핵심 제약:
- `timeout` 종료 코드 `124` 는 SIGTERM 타임아웃 — 별도 분기로 사유 명시.
- §13 (헬스체크) 는 §12 통과 후에만 실행. 시나리오 D 발생 시 §13~§14 스킵.

---

## 13. 헬스체크 (deployed_sha 매칭)

`${cf_dev_url}` 치환 + `e2e_healthcheck_path` (기본값 `/health`) 로 URL 을 조립한 뒤, `origin/dev` 의 SHA 와 응답 `deployed_sha` 를 **full / short 양쪽 허용**으로 매칭합니다.

```bash
# §13.1 config 로드 + ${cf_dev_url} 치환
# 배포 대상 무관 — `dev_url` 이 일반 이름이고 `cf_dev_url` 은 옛 이름(호환 유지)이다.
CF_DEV_URL_BASE=$(jq -r '.dev_url // .cf_dev_url // ""' .claude/config.json)
CF_DEV_URL_RAW=$(jq -r '.e2e_dev_url // .dev_url // .cf_dev_url // ""' .claude/config.json)
CF_DEV_URL="${CF_DEV_URL_RAW//\$\{cf_dev_url\}/$CF_DEV_URL_BASE}"
HC_PATH=$(jq -r '.e2e_healthcheck_path // "/health"' .claude/config.json)

# §13.2 baseURL 빈 값 → 환경 오류
if [[ -z "$CF_DEV_URL" ]]; then
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-comment "$ISSUE" "## ⚠️ Dev E2E 환경 오류

E2E_ENV_ERROR=empty_dev_url

- \`e2e_dev_url\` / \`cf_dev_url\` 모두 비어있어 헬스체크 URL 조립 불가
- 다음 액션: \`.claude/config.json\` 의 \`cf_dev_url\` 또는 \`e2e_dev_url\` 설정"
  _send_telegram_notification "Dev E2E 환경 오류: empty_dev_url (issue=$ISSUE)" || true
  exit 2
fi

# §13.3 기대 SHA = origin/dev 의 최신 SHA (40자 full + 7자 short)
git fetch origin dev --quiet 2>/dev/null || true
EXPECTED_SHA=$(git rev-parse origin/dev)
EXPECTED_SHORT=${EXPECTED_SHA:0:7}

# §13.4 폴링 (최대 30회 × 5초 = 150초)
HC_PASS=false
DEPLOYED_SHA=""
HC_URL="${CF_DEV_URL%/}${HC_PATH}"
for i in $(seq 1 30); do
  RESP=$(curl -s -m 5 "$HC_URL" 2>/dev/null || echo "")
  DEPLOYED_SHA=$(echo "$RESP" | jq -r '.deployed_sha // ""' 2>/dev/null)

  # full SHA / short SHA 양쪽 허용 + prefix 매칭
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

# §13.5 헬스체크 타임아웃 → 시나리오 D
if [[ "$HC_PASS" != "true" ]]; then
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-comment "$ISSUE" "## ⚠️ Dev 배포 검증 실패

- 사유: healthcheck_timeout(150s)
- URL: $HC_URL
- 기대 SHA: $EXPECTED_SHA
- 응답 SHA: ${DEPLOYED_SHA:-none}
- 다음 액션:
  - \`/health\` 응답에 \`deployed_sha\` 필드가 포함되는지 확인 (대상 프로젝트 책임)
  - CF 워커 배포 로그에서 빌드 SHA 주입 여부 확인
  - 참고 가이드: SKILL.md §15 \"/health deployed_sha 가이드\""
  _send_telegram_notification "Dev 헬스체크 타임아웃 (issue=$ISSUE, url=$HC_URL)" || true
  exit 1
fi

echo "[merge-pr] §13 헬스체크 통과 (SHA=$EXPECTED_SHORT)"
```

핵심 제약:
- `deployed_sha` 가 빈 문자열인 응답은 매칭 실패 — 대상 프로젝트가 필드를 안 채운 경우.
- short(7자) ↔ full(40자) SHA 모두 허용 — 빌드 시점 환경변수 주입 관행에 따라 형식이 다름.
- 폴링 간격은 고정 5초 (지수 backoff 는 비범위, follow-up).

---

## 14. dev E2E 자동 실행 + 결과 마커 댓글

qa-e2e 에이전트를 `--env=dev --mode=full --issue=$ISSUE` 로 호출하고, **종료 코드와 마지막 줄을 동시에 검증**하여 시나리오 A/B/C 로 분기합니다.

### 14.0 RUN_E2E 결정 (#131 신규 — 기본 SKIP)

§13 헬스체크 통과 직후, §14 진입 전에 `--run-e2e` 인자와 `e2e_run_on_merge_pr` config 를 합쳐 실행 여부를 결정합니다. **둘 다 false 면 즉시 SKIP 마커 등록 후 종료** (시나리오 E).

```bash
# §14.0.1 config 토글 읽기
RUN_E2E_CFG=$(jq -r '.e2e_run_on_merge_pr // false' .claude/config.json 2>/dev/null || echo false)

# §14.0.2 OR 조건 — 인자 우선
if [[ "$RUN_E2E_ARG" == "true" || "$RUN_E2E_CFG" == "true" ]]; then
  RUN_E2E=true
else
  RUN_E2E=false
fi

echo "[merge-pr] §14.0 RUN_E2E=$RUN_E2E (arg=$RUN_E2E_ARG, cfg=$RUN_E2E_CFG)"

# §14.0.3 SKIP 분기 (시나리오 E)
if [[ "$RUN_E2E" != "true" ]]; then
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-comment "$ISSUE" "## ℹ️ Dev E2E 자동 실행 스킵

- 사유: 기본 비활성 (#131)
- 활성화 방법 (택1):
  - 1회성: \`/aiops:merge-pr $ISSUE --run-e2e\`
  - 영구: \`.claude/config.json\` 에 \`\"e2e_run_on_merge_pr\": true\`
- §11~§13 (Actions 대기 + 헬스체크) 는 정상 통과 — dev 배포 검증은 완료됨
- 수동 실행:
  - \`/aiops:e2e-test --env=dev --mode=full #$ISSUE\` — dev 환경 full
  - \`/aiops:run-e2e\` — 현재 브랜치에 맞는 환경 자동 선택
  - \`/aiops:verify-deploy --env=dev\` — 헬스체크 + E2E 통합
- \`/aiops:merge-main\` 차단 여부: \`e2e_required_for_merge_main\` config 에 따름 (기본 false 시 통과)"

  echo "[merge-pr] §14.0 시나리오 E — Dev E2E 자동 실행 스킵 (#131)"
  exit 0
fi
```

핵심 제약:
- SKIP 시 §14.2 의 PASS/FAIL/ENV_ERROR 마커는 등록하지 않음 — 별도 헤더 `## ℹ️ Dev E2E 자동 실행 스킵` 사용.
- `## 🌐 Dev E2E 결과 — full` 헤더는 등록 금지 — `/aiops:merge-main` 의 마커 검사가 PASS 로 오인하면 안 됨 (#131 PRD AC-3 와 정합).
- `/aiops:merge-main` 입장: `e2e_required_for_merge_main=true` 일 때만 본 SKIP 이 차단 사유 (`marker_absent`) 가 됨.

### 14.1 qa-e2e 호출 (Agent 도구 권장)

CC harness 내부에서는 **Agent 도구로 qa-e2e 를 호출**하는 것이 표준입니다:

```
Agent("qa-e2e", "--env=dev --mode=full --issue=<ISSUE_NUMBER>")
```

헤드리스 / 직접 실행 환경에서는 다음 동등 셸 호출을 사용하며, 출력은 임시 파일에 기록합니다:

```bash
E2E_OUTPUT_FILE=$(mktemp)
E2E_EXIT=0
{
  # qa-e2e 에이전트 표준 출력 규약 (#117):
  #   마지막 줄: E2E_RESULT=PASS|FAIL 또는 E2E_ENV_ERROR=<reason>
  ./run-qa-e2e.sh --env=dev --mode=full --issue="$ISSUE" 2>&1
} | tee "$E2E_OUTPUT_FILE"
E2E_EXIT=${PIPESTATUS[0]}

E2E_LAST_LINE=$(tail -n 1 "$E2E_OUTPUT_FILE" | tr -d '\r\n')
```

### 14.2 결과 분기 (종료 코드 + 마지막 줄 이중 검증)

```bash
case "$E2E_EXIT:$E2E_LAST_LINE" in
  0:E2E_RESULT=PASS)
    # 시나리오 A — qa-e2e 가 `## 🌐 Dev E2E 결과 — full` 댓글을 이미 등록.
    # SKILL.md 는 추가 마커 없이 종료 (중복 헤더 등록 금지).
    echo "[merge-pr] §14 시나리오 A — dev E2E PASS"
    exit 0
    ;;

  1:E2E_RESULT=FAIL)
    # 시나리오 B — qa-e2e 의 `## 🌐 …` 댓글에 더해 #120 차단용 별도 마커 등록.
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-comment "$ISSUE" "## ❌ Dev E2E FAIL

E2E_RESULT=FAIL

- 상세 결과: 본 이슈의 \`## 🌐 Dev E2E 결과 — full\` 댓글 참조
- 다음 액션: dev-be / dev-fe 수정 → STEP 6 재배포 → STEP 7~8 재실행 → \`/aiops:merge-pr\` 재시도
- \`/aiops:merge-main\` 차단: 본 이슈에 \`E2E_RESULT=PASS\` 마커가 추가될 때까지 진행 불가"
    _send_telegram_notification "Dev E2E FAIL (issue=$ISSUE)" || true
    exit 1
    ;;

  2:E2E_ENV_ERROR=*)
    # 시나리오 C — qa-e2e 가 G1~G5 환경 오류로 종료.
    REASON="${E2E_LAST_LINE#E2E_ENV_ERROR=}"
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-comment "$ISSUE" "## ⚠️ Dev E2E 환경 오류

E2E_ENV_ERROR=$REASON

- 가이드: \`claude-ai-devops/docs/e2e-quick-start.md\` G1~G5 트러블슈팅 참조
- 다음 액션: 환경 설정 보정 후 \`/aiops:merge-pr $ISSUE\` 재시도"
    _send_telegram_notification "Dev E2E 환경 오류 ($REASON, issue=$ISSUE)" || true
    exit 2
    ;;

  *)
    # qa-e2e 종료 코드와 마지막 줄이 규약 불일치 — 환경 오류로 처리.
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-comment "$ISSUE" "## ⚠️ Dev E2E 환경 오류

E2E_ENV_ERROR=qa_e2e_protocol_violation:exit=$E2E_EXIT,last_line=$(echo "$E2E_LAST_LINE" | head -c 80)

- qa-e2e 에이전트가 표준 출력 규약(#117)을 위반함
- 다음 액션: qa-e2e 에이전트 SKILL/Agent 정의 확인"
    _send_telegram_notification "Dev E2E 프로토콜 위반 (issue=$ISSUE, exit=$E2E_EXIT)" || true
    exit 2
    ;;
esac
```

핵심 제약:
- 종료 코드와 마지막 줄을 **동시에** 검사 — 단일 신호 의존 시 회귀 위험.
- qa-e2e 가 이미 `## 🌐 Dev E2E 결과 — full` 댓글을 등록하므로 SKILL.md 는 시나리오 B/C 에서 **차단 마커만** 추가 등록 (중복 헤더 금지).

---

## 14.3 마커 매트릭스 (불변 계약 — 바이트 단위 일치 필수)

본 표는 PRD M4 / 흐름도 §4 와 1:1 동일하며, SKILL.md / qa-e2e / `/aiops:merge-main` (#120) / `/aiops:deploy-prod` (#121) 가 공유하는 **단일 진실 원천**입니다. 헤더의 `—` 는 **EM DASH (U+2014)** 이며 EN DASH (U+2013 `–`) / HYPHEN (U+002D `-`) 과 절대 혼동 금지.

| 시나리오 | 헤더 라벨 (^...$ 정확 일치) | 본문 핵심 키 | 등록 주체 | #120 검사 |
| --- | --- | --- | --- | --- |
| **A. 정상 PASS** | `## 🌐 Dev E2E 결과 — full` | `E2E_RESULT=PASS` | qa-e2e | **허용** |
| **B. E2E FAIL** | `## ❌ Dev E2E FAIL` | `E2E_RESULT=FAIL` | merge-pr §14 (qa-e2e 댓글 추가 등록) | **차단** |
| **C. 환경 오류** | `## ⚠️ Dev E2E 환경 오류` | `E2E_ENV_ERROR=<reason>` | merge-pr §12/§13/§14 또는 qa-e2e | **차단** |
| **D. 배포 검증 실패** | `## ⚠️ Dev 배포 검증 실패` | (사유 텍스트) | merge-pr §12/§13 | **차단** |
| **E. 자동 실행 SKIP** (#131) | `## ℹ️ Dev E2E 자동 실행 스킵` | (사유 텍스트) | merge-pr §14.0 | **조건부** (`e2e_required_for_merge_main=true` 시 차단, 기본 false 시 허용) |
| (역호환) | (신규 댓글 없음) | — | — | 검사 대상 외 |

### 14.4 grep 회귀 테스트 (#120 입장)

```bash
# 허용 (AND 조건)
COMMENTS=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/forge.sh" issue-comments <N>)
echo "$COMMENTS" | grep -qE '^## 🌐 Dev E2E 결과 — full$' \
  && echo "$COMMENTS" | grep -q 'E2E_RESULT=PASS'

# 차단 (OR 조건)
echo "$COMMENTS" | grep -qE '^## ❌ Dev E2E FAIL$|^## ⚠️ Dev (E2E 환경 오류|배포 검증 실패)$|E2E_RESULT=FAIL'
```

---

## 15. /health deployed_sha 가이드 (대상 프로젝트 책임)

§13 의 헬스체크 매칭이 동작하려면, 대상 프로젝트가 `/health` 응답에 `deployed_sha` 필드를 채워야 합니다. 본 가이드는 SKILL 이 강제하지 않고 **문서화만 책임**합니다.

### 15.1 응답 스키마

```json
{
  "status": "ok",
  "deployed_sha": "abc1234"
}
```

- `deployed_sha`: 7자 short SHA 또는 40자 full SHA. 빈 문자열 / 누락 시 §13 매칭 실패 → 시나리오 D.
- 빌드 시점에 git SHA 를 환경변수로 받아 응답에 포함해야 합니다.

### 15.2 CF Workers (Hono / TypeScript) 예시

```typescript
// wrangler.toml 의 [vars] 에서 DEPLOYED_SHA 주입
// CI(GitHub/Gitea Actions 공통): env.DEPLOYED_SHA = ${{ github.sha }}
app.get('/health', (c) => c.json({
  status: 'ok',
  deployed_sha: c.env.DEPLOYED_SHA || '',
}));
```

### 15.3 FastAPI (Python) 예시

```python
import os

@app.get("/health")
def health():
    return {"status": "ok", "deployed_sha": os.getenv("DEPLOYED_SHA", "")}
```

---

## 16. Telegram 알림 헬퍼 (선택)

config 또는 환경변수에 채널 정보가 있을 때만 동작하고, 미설정 시 **조용히 스킵** (반환값 0). 본 SKILL.md 의 §12 / §13 / §14 실패 분기에서 호출됩니다.

```bash
_send_telegram_notification() {
  local MSG="$1"
  local TOKEN="${TG_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-$(jq -r '.telegram_bot_token // ""' .claude/config.json 2>/dev/null)}}"
  local CHAT="${TG_CHAT_ID:-${TELEGRAM_CHAT_ID:-$(jq -r '.telegram_chat_id // ""' .claude/config.json 2>/dev/null)}}"

  if [[ -z "$TOKEN" || -z "$CHAT" ]]; then
    return 0  # 미설정 → 조용히 스킵 (정상 흐름)
  fi

  curl -s -m 5 -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d chat_id="$CHAT" \
    -d text="$MSG" \
    >/dev/null 2>&1 || true
}
```

호출 위치 (실패 마커 등록 직후):
- §12.3 / §12.5 시나리오 D 등록 후
- §13.2 / §13.5 환경 오류 / 시나리오 D 등록 후
- §14.2 시나리오 B / C / 프로토콜 위반 등록 후

---

## 17. AC-1~10 검증 절차 (회귀 테스트 매트릭스)

| AC | 시나리오 | 검증 명령 |
| --- | --- | --- |
| AC-1 | Actions 대기 정상 | §12 통과 후 `[merge-pr] §13 헬스체크 통과` 라인 stdout 존재 |
| AC-2 | 헬스체크 매칭 | `curl $HC_URL \| jq -r .deployed_sha` 결과가 `git rev-parse origin/dev` 의 prefix |
| AC-3 | PASS 댓글 등록 | `forge.sh issue-comments <N> \| grep -E '^## 🌐 Dev E2E 결과 — full$'` 1건 이상 |
| AC-4 | 역호환 | `e2e_test_enabled=false` 또는 `--skip-e2e` → §8 만 등록, §11~§14 댓글 0건 |
| AC-5 | FAIL 마커 | qa-e2e mock exit=1 → `## ❌ Dev E2E FAIL` + `E2E_RESULT=FAIL` 동시 존재 |
| AC-6 | 헤더 정확 일치 | `grep -cE '^## (🌐 Dev E2E 결과 — full\|❌ Dev E2E FAIL\|⚠️ Dev (E2E 환경 오류\|배포 검증 실패))$'` 정합 |
| AC-7 | 환경 오류 | forge.sh API 인증 실패 mock → `## ⚠️ Dev E2E 환경 오류` 등록 + exit 2 |
| AC-8 | 타임아웃 | `e2e_deploy_wait_sec=1` → `## ⚠️ Dev 배포 검증 실패` 등록 + §14 스킵 |
| AC-9 | /health 가이드 | `grep -c "deployed_sha" claude-ai-devops/skills/aiops:merge-pr/SKILL.md` ≥ 1 |
| AC-10 | Telegram 옵션 | TOKEN/CHAT 미설정 → `_send_telegram_notification` no-op 반환, 설정 시 curl 호출 1회 |

---

현재 제공된 인자: $ARGUMENTS

위 절차대로 진행해줘.
