---
name: jira-to-issue
description: "Jira 티켓을 이슈로 등록. 티켓 내용·댓글·메타데이터를 변환하여 forge.sh issue-create 로 생성(GitHub/Gitea 자동감지). 사용법: /aiops:jira-to-issue PROJECT-123 [PROJECT-456 ...]"
---

Jira 티켓을 이슈로 변환·등록해줘 (forge.sh 가 origin 리모트로 GitHub/Gitea 자동감지).

## 환경 변수 확인

먼저 아래 환경 변수가 설정되어 있는지 확인해줘:

```bash
echo "JIRA_URL: ${JIRA_URL:-(미설정)}"
echo "JIRA_EMAIL: ${JIRA_EMAIL:-(미설정)}"
echo "JIRA_API_TOKEN: ${JIRA_API_TOKEN:+설정됨}${JIRA_API_TOKEN:-(미설정)}"
```

미설정 항목이 있으면 작업을 중단하고 아래 안내를 출력해줘:

```
[오류] 다음 환경 변수를 설정해주세요:
  export JIRA_URL="https://yourcompany.atlassian.net"
  export JIRA_EMAIL="your@email.com"
  export JIRA_API_TOKEN="your-api-token"

Jira API 토큰 발급: https://id.atlassian.com/manage-profile/security/api-tokens
```

## 처리할 티켓 목록

$ARGUMENTS 를 공백으로 분리하여 각 Jira 티켓 키로 처리해줘.
인수가 없으면 "처리할 티켓 키를 인수로 전달해주세요. 예: /aiops:jira-to-issue PROJECT-123" 를 출력하고 중단해줘.

## 각 티켓에 대해 아래 단계를 순서대로 실행해줘

### STEP 1 — Jira 티켓 데이터 조회

```bash
JIRA_KEY="<티켓키>"
AUTH=$(echo -n "${JIRA_EMAIL}:${JIRA_API_TOKEN}" | base64)

# 이슈 메타데이터 + 댓글 한 번에 조회 (API v2: 마크다운 친화적 텍스트 반환)
curl -s \
  -H "Authorization: Basic ${AUTH}" \
  -H "Accept: application/json" \
  "${JIRA_URL}/rest/api/2/issue/${JIRA_KEY}?fields=summary,description,comment,reporter,assignee,priority,status,issuetype,labels,components,fixVersions,created,updated,customfield_10016" \
  -o /tmp/jira_${JIRA_KEY}.json

# HTTP 오류 확인
if ! jq -e '.key' /tmp/jira_${JIRA_KEY}.json > /dev/null 2>&1; then
  echo "[오류] ${JIRA_KEY} 조회 실패:"
  cat /tmp/jira_${JIRA_KEY}.json
  exit 1
fi
```

### STEP 2 — 이슈 본문 구성

아래 형식으로 이슈 본문을 생성해줘. `jq`로 필드를 추출하고 마크다운으로 조합해줘:

```
## 📋 Jira 티켓 정보

| 항목 | 내용 |
|------|------|
| **티켓 키** | [<key>](<JIRA_URL>/browse/<key>) |
| **유형** | <issuetype.name> |
| **상태** | <status.name> |
| **우선순위** | <priority.name> |
| **보고자** | <reporter.displayName> |
| **담당자** | <assignee.displayName 또는 미지정> |
| **컴포넌트** | <components[].name 쉼표 구분 또는 없음> |
| **레이블** | <labels 쉼표 구분 또는 없음> |
| **수정 버전** | <fixVersions[].name 쉼표 구분 또는 없음> |
| **스프린트** | <customfield_10016[].name 또는 없음> |
| **생성일** | <created> |

## 📝 설명

<description (없으면 "설명 없음")>

## 💬 댓글 (<총 댓글 수>개)

<각 댓글을 아래 형식으로 나열, 최대 20개>
---
**<author.displayName>** · <created>

<body>

```

댓글이 없으면 "댓글 없음" 을 표시해줘.
댓글이 20개를 초과하면 "... 외 N개 댓글은 Jira에서 확인: <JIRA_URL>/browse/<key>" 를 추가해줘.

### STEP 3 — 레이블 매핑

Jira 필드를 이슈 레이블로 변환해줘 (없는 레이블은 생성 시도 없이 조용히 스킵):

- issuetype: `Bug` → `bug`, `Story`/`Task` → `enhancement`, `Epic` → `epic`, `Sub-task` → `task`
- priority: `Highest`/`Critical` → `priority:critical`, `High` → `priority:high`, `Medium` → `priority:medium`, `Low`/`Lowest` → `priority:low`
- Jira labels → 이슈 레이블 그대로 추가 (소문자 변환)

레이블은 `forge.sh issue-create --label a,b` 로 best-effort 전달한다(GitHub: 레이블명, Gitea: 레이블 ID). forge.sh 는 레이블 목록 조회를 제공하지 않으므로 사전 교집합 검증은 생략하고, forge 에 존재하지 않는 레이블은 forge 측에서 조용히 무시된다(자동 생성 없음).

### STEP 4 — 이슈 생성

```bash
forge.sh issue-create \
  "[<JIRA_KEY>] <summary>" \
  "@/tmp/issue_body_${JIRA_KEY}.md" \
  --label "<매핑된 레이블 쉼표 구분>"
# -> ISSUE_NUMBER=.. ISSUE_URL=..
```

생성 후 출력된 `ISSUE_URL` 을 사용자에게 알려줘.

### STEP 5 — 완료 보고

모든 티켓 처리 후 아래 표 형태로 결과를 출력해줘:

```
=== Jira → 이슈 변환 결과 ===

| Jira 티켓 | 제목 | 이슈 | 상태 |
|-----------|------|------|------|
| PROJECT-123 | 로그인 오류 | <ISSUE_URL> | ✅ 생성 완료 |
| PROJECT-456 | ...  | -           | ❌ 실패: 오류 메시지 |
```

## 주의사항

- Jira 설명/댓글이 Atlassian Wiki Markup 또는 ADF 형식일 경우, 가독성이 떨어지는 JSON 원문 대신 텍스트만 추출해서 표시해줘
- 설명이 null이거나 비어 있으면 "설명 없음" 으로 대체해줘
- 이미 동일한 `[<JIRA_KEY>]` 제목을 가진 이슈가 있으면 중복 생성 전 경고 후 사용자 확인을 받아줘:
  ```bash
  forge.sh issue-list | grep -F "[${JIRA_KEY}]"   # number\ttitle 중 매칭 확인
  ```
- 임시 파일(`/tmp/jira_*.json`, `/tmp/issue_body_*.md`)은 작업 완료 후 삭제해줘
