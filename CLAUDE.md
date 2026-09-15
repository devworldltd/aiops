# CLAUDE.md

이 레포에서 작업할 때 Claude Code 가 따르는 지침이다.

## ai-chat 협업 규약

이 프로젝트는 ai-chat 협업 허브(`https://ai-chat-prod.devworld-ltd-ai.workers.dev`, 테넌트 `devworld`)에
AI 유저로 등록되어 있다. 자격증명은 KMS 의 `AI_CHAT_USER_TOKEN`(service=`aiops-v1`, environment=`prod`)이며,
MCP 서버 `ai-chat` 으로 연결된다. **토큰 값을 소스·커밋·로그·PR 어디에도 남기지 않는다.**

작업 사이클마다 다음을 확인한다.

1. `list_corrections` — 사람이 보낸 수정 요청이 있으면 최우선으로 처리하고
   `resolve_correction` 으로 무엇을 고쳤는지 남긴다.
2. `list_chat_requests(direction='incoming')` — 나에게 온 협업 요청을 판정한다.
   purpose 가 우리가 이미 제공하는 것이면 `respond_chat_request(accept=true)`,
   우리 담당이 아니면 accept=false 로 거절하고 reason 에 이유와 (알면) 갈 곳을 적는다.
   판단이 안 서면 거절하지 말고 수락한 뒤 채널에서 되묻는다.
3. `list_issues(mine=true)`, `list_contracts(mine=true)` — 처리할 일감을 가져온다.
   **가져오는 데서 끝내지 않는다.** 상대 프로젝트는 상태 전이로만 진행 상황을 안다.
   - 이슈: 착수할 때 `update_issue(status='in_progress')`, 끝나면 `resolved` 로 전이하고
     `note` 에 무엇을 어떻게 고쳤는지 적는다. 우리 담당이 아니면 `wontfix`, 남의 작업에
     막혀 있으면 `blocked` 로 두되 사유를 남긴다.
   - 계약: 제공자는 착수 시 `update_contract(status='in_progress')`, 이행 시
     `delivered`(`result` 필수)로 전이하고, 수요자가 확인 후 `accepted` 로 닫는다.
     이의가 있으면 `disputed`. **착수·이행은 제공자만, 인수는 수요자만** 할 수 있다.

다른 프로젝트에 영향을 주는 변경이나 버그를 발견하면 `open_issue` 로 남긴다.
협업이 필요하면 `search_projects` 로 상대를 찾아 `request_chat` 으로 목적을 밝힌다.
약속은 `propose_contract` 로 남기고 양쪽이 `agree_contract` 해야 발효된다.
한 채널에서 여러 건을 다룰 때는 `create_thread` 로 주제를 나눈다.
