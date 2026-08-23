# 로컬 LLM 연동 가이드 (api.devworld.co.kr)

에이전트 티어(모델·effort)와 로컬 LLM 위임을 함께 구성하는 정본 문서.
적용일: 2026-08-19.

## 1. 아키텍처 결정

Claude Code 공식 문서 기준(2026-08 확인):

- 에이전트 프론트매터 `model:`은 **Anthropic 모델 별칭/ID만** 허용 — 특정 서브에이전트만 외부(OpenAI 호환) 엔드포인트로 보내는 기능은 없다.
- `ANTHROPIC_BASE_URL`(게이트웨이/LiteLLM)은 **세션 전역**에 적용되고, claude.ai **구독(OAuth) 인증이 깨져** API 키 과금으로 전환된다.

따라서 채택한 구조:

| 축 | 방식 |
|---|---|
| 에이전트 루프 | Claude 3티어 유지 (`model:` + `effort:` 프론트매터) |
| 로컬 LLM | **서브태스크 위임** — 에이전트가 `scripts/llm-local.sh`를 Bash로 호출해 기계적·대량 작업(로그 요약, 초안 생성, 스크린샷 분석)을 오프로드 |
| 비권장 | LiteLLM 전역 게이트웨이 (구독 인증 파괴). API 키 과금 체계로 전환할 때만 재검토 |

## 2. 역할별 최종 매핑

| 에이전트 | model | effort | 로컬 LLM 위임 |
|---|---|---|---|
| orchestrator, dev, planning | opus | (기본) | 없음 — 판단 품질이 하류 비용을 결정 |
| dev-backend/frontend/designer/devops/e2e, dev-mobile-* | sonnet | (기본) | 없음 (실험 시 qwen3-coder-next:q8_0-tools) |
| bug-analyst | sonnet | (기본) | 로그 축약 qwen3-coder:30b, 심층 추론 deepseek-r1:70b |
| bug-verifier, doc-updater | sonnet | (기본) | doc-updater: 문서 초안 qwen2.5:72b-instruct-q4_K_M |
| qa-e2e, qa-mobile-e2e | sonnet | (기본) | 스크린샷 진단 qwen2.5vl:32b, 로그 요약 qwen3-coder:30b |
| marketing | sonnet | (기본) | 카피 초안 gemma4:31b / muse-glimmer:30b-mlx |
| qa-backend/frontend/admin, qa-mobile-android/ios | haiku | **low** | 테스트 로그 요약 qwen3-coder:30b |
| dev-pr | haiku | **low** | PR 본문 초안 qwen3-coder:30b |
| release-manager | haiku (sonnet→강등) | **low** | 릴리즈 노트 초안 qwen3-coder:30b |

위임 공통 원칙 (각 에이전트 "## 로컬 LLM 위임 (선택)" 절에 명시):

1. `llm-local.sh health` 성공 시에만 사용 — 실패하면 위임 없이 직접 수행 (로컬 LLM 다운이 파이프라인을 막지 않음)
2. **Sign-off·E2E_RESULT·Root Cause 등 최종 판정은 항상 Claude 에이전트가 직접** — 로컬 LLM 출력은 참고 자료
3. 머지/배포 등 실제 조작 명령은 위임 금지 — 초안·요약 전용

## 3. llm-local.sh 사용법

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/llm-local.sh" health          # 가용성 게이트
bash "${CLAUDE_PLUGIN_ROOT}/scripts/llm-local.sh" models          # 서빙 모델 목록
bash "${CLAUDE_PLUGIN_ROOT}/scripts/llm-local.sh" chat qwen3-coder:30b "프롬프트"
cat 로그 | bash "${CLAUDE_PLUGIN_ROOT}/scripts/llm-local.sh" chat qwen3-coder:30b --system "요약해"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/llm-local.sh" vision qwen2.5vl:32b shot.png "실패 원인?"
```

환경변수: `LOCAL_LLM_BASE_URL`(기본 https://api.devworld.co.kr), `CF_Access_Client_Id`/`CF_Access_Client_Secret`(Cloudflare Access 서비스 토큰 — `.envrc`/direnv로 로드, 파일에 값 저장 금지).

### Cloudflare Access 인증 (2026-08-19 구성)

api.devworld.co.kr 은 CF Access 앱으로 보호된다 (Zero Trust 조직 devworld-ltd-ai). 스크립트의 인증 우선순위:

1. **서비스 토큰** — `CF_Access_Client_Id/Secret` env (정책 `aiops-to-api` 등 Service Auth). CI·헤드리스용.
2. **이메일 OTP** — 서비스 토큰이 없으면 `cloudflared access token --app=<URL>` 캐시 토큰을 `cf-access-token` 헤더로 사용.
   최초 1회 `cloudflared access login https://api.devworld.co.kr` 실행 → 이메일(One-time PIN) 인증 → 세션 기간 동안 캐시 재사용.
   허용 이메일은 앱 정책 `aiops-email-otp` (Allow) 에 등록한다.
3. **무인증** — Bypass 정책(예: `macbook pro`)에 매칭되는 네트워크에서는 토큰 없이 통과.

health 게이트가 302/401/403 을 받으면 `cloudflared access login` 안내 메시지를 출력하고 종료 코드 2.

## 3-1. Claude Code 본체를 로컬 모델로 구동 (claude-local)

위 §1 은 "에이전트 루프는 Claude, 서브태스크만 로컬" 구조다. 그와 별개로 **Claude Code 자체를 로컬 모델로 돌리는** 경로도 가능하다 — api.devworld.co.kr 게이트웨이가 Anthropic `/v1/messages` 형식(텍스트·tool_use·SSE 스트리밍)을 그대로 지원하기 때문에 별도 변환 프록시(LiteLLM 등)가 필요 없다.

런처: `~/.local/bin/claude-gemma` (레포 밖, 사용자 환경 파일)

```bash
claude-gemma                    # gemma4:26b-a4b-it-q8_0 로 대화형 실행
claude-gemma -p "질문"          # 원샷
LOCAL_MODEL=qwen3-coder-next:q8_0-tools claude-gemma   # 모델 교체
claude-gemma --list-models      # 서빙 모델 목록
```

> 이름 주의: `~/.zshrc:193` 에 **기존 `claude-local()` 셸 함수**가 따로 있다 (localhost:11434 · qwen3-coder-64k). 셸 함수가 PATH 실행파일보다 우선하므로 이름을 `claude-gemma` 로 분리했다.

전역 설정(`settings.json`)이 아니라 **런처로 분리한 이유**: `ANTHROPIC_BASE_URL` 은 세션 전역이고 claude.ai 구독 인증을 우회한다. 전역에 넣으면 평소 Opus 사용까지 전부 로컬 모델로 바뀐다. 평소에는 `claude`, 로컬로 돌릴 때만 `claude-gemma` 를 쓴다.

주의:
- 실행 중인 세션의 모델은 바꿀 수 없다 — 새 프로세스로 시작해야 한다.
- 구독 인증이 비활성화되므로 claude.ai 커넥터가 꺼진다(경고 문구 정상).
- `[claude-code:unrecognized_model]` 경고는 모델 ID 메타데이터 미등록 때문이며 동작에는 영향 없다.
- 서버가 동시 1요청(`-np 1`)이라 서브에이전트 병렬 실행은 직렬화된다.

## 4. 서빙 모델 용도 맵 (2026-08-19 기준 25종)

| 용도 | 모델 | 비고 |
|---|---|---|
| 코딩·QA 요약·툴콜 | qwen3-coder-next:q8_0-tools | 262K 컨텍스트, 유일한 툴콜 지원 |
| 코딩·요약 (기본) | qwen3-coder:30b, qwen2.5-coder:32b | 빠름, 에이전트 위임 기본값 |
| 한국어 문서/카피 | qwen2.5:72b-instruct-q4_K_M, gemma4:31b | 72b는 느림 — 품질 우선 시 |
| 창작 톤 | muse-glimmer:30b-mlx | 마케팅 카피 변형 |
| 비전/OCR | qwen2.5vl:7b/32b/72b (+ocr16k) | E2E 스크린샷, 와이어프레임 대조 |
| 심층 추론 | deepseek-r1:70b | 매우 느림 — 단독 분석 전용, --timeout 600 |
| 임베딩(RAG) | bge-m3, nomic-embed-text | 에이전트 아님 — 검색용 |

## 5. 서버 운영 주의

- llama-server가 `-np 1`(동시 1요청)로 떠 있어 병렬 STEP(5/7)에서 위임이 몰리면 직렬화된다. 위임은 "큰 입력 1회 요약" 용도로 제한하고, 상시화하려면 서버에서 `-np`를 2~3으로 올릴 것.
- 2026-08-18 장애: Cloudflare 터널 인그레스가 127.0.0.1:11435를 가리키나 게이트웨이는 11434 수신 → 현재 **임시 포워더(11435→11434, DEVOPSKR ~/tmp/fwd11435.py)로 유지 중**. 재부팅 시 소실되므로 CF 대시보드에서 인그레스를 11434로 수정하거나 포워더를 launchd 등록할 것.

## 6. 비용 효과 (참고)

- haiku 티어 + effort low: 출력 토큰·툴 호출 수 감소 (Haiku 4.5 $1/$5 per MTok)
- 대량 로그를 haiku가 직접 읽는 대신 로컬 LLM 요약본만 읽으면 입력 토큰이 로그 크기와 무관해짐
- Sonnet 5 인트로 가격($2/$10)은 2026-08-31 종료 — 이후 sonnet 티어 비용 1.5배
