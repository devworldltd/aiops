#!/usr/bin/env bash
# llm-local.sh — 로컬 LLM(api.devworld.co.kr) 호출 CLI. OpenAI 호환 /v1 엔드포인트.
#
# ⚠️ 반드시 **실행**한다(소싱 금지). actions-wait.sh / forge.sh 와 동일 관례.
#
# 에이전트가 기계적·대량 서브태스크(테스트 출력 요약, 초안 생성, 스크린샷 OCR 등)를
# 로컬 LLM에 위임할 때 사용한다. 에이전트 루프 자체를 대체하지 않는다.
#
# 환경변수:
#   LOCAL_LLM_BASE_URL       기본 https://api.devworld.co.kr
#   CF_Access_Client_Id      Cloudflare Access 서비스 토큰 (선택, .envrc/direnv 로드)
#   CF_Access_Client_Secret  〃
#
# 사용:
#   llm-local.sh health                          # 엔드포인트 가용성 확인
#   llm-local.sh models                          # 서빙 모델 목록
#   llm-local.sh chat <model> [프롬프트]         # 프롬프트 인자 또는 stdin
#     [--system <시스템프롬프트>] [--max-tokens N(기본 4096)] [--timeout 초(기본 300)]
#   llm-local.sh vision <model> <이미지경로> [프롬프트]   # qwen2.5vl 계열 전용
#
# 출력: 응답 본문(stdout). 오류 시 stderr 메시지 + 종료 코드 2.
# 종료 코드: 0=성공 / 2=엔드포인트·인자·응답 오류
#
# 권장 모델 (역할 매핑은 docs/local-llm-integration.md 참조):
#   코딩·QA 판정 위임: qwen3-coder:30b, qwen3-coder-next:q8_0-tools
#   한국어 문서 초안:  qwen2.5:72b-instruct-q4_K_M, gemma4:31b
#   스크린샷/OCR:      qwen2.5vl:32b, qwen2.5vl-ocr16k:32b
#   심층 추론(느림):   deepseek-r1:70b
set -uo pipefail

BASE_URL="${LOCAL_LLM_BASE_URL:-https://api.devworld.co.kr}"
AUTH_ARGS=()
if [[ -n "${CF_Access_Client_Id:-}" && -n "${CF_Access_Client_Secret:-}" ]]; then
  AUTH_ARGS=(-H "CF-Access-Client-Id: ${CF_Access_Client_Id}" -H "CF-Access-Client-Secret: ${CF_Access_Client_Secret}")
fi

die() { echo "[llm-local] $*" >&2; exit 2; }

api() { # api <path> [curl 추가 인자...]
  local path="$1"; shift
  curl -sS --max-time "${TIMEOUT:-300}" "${AUTH_ARGS[@]}" "$@" "${BASE_URL}${path}"
}

extract_content() { # stdin: chat.completion JSON → content 출력
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.stderr.write("[llm-local] JSON 파싱 실패 — 엔드포인트 응답 이상\n"); sys.exit(2)
if "error" in d:
    err = d["error"]
    sys.stderr.write("[llm-local] API 오류: %s\n" % err); sys.exit(2)
try:
    print(d["choices"][0]["message"]["content"])
except (KeyError, IndexError):
    sys.stderr.write(f"[llm-local] 예상 외 응답 구조: {json.dumps(d)[:300]}\n"); sys.exit(2)
'
}

cmd="${1:-}"; shift || true
case "$cmd" in
  health)
    code=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' "${AUTH_ARGS[@]}" "${BASE_URL}/v1/models" || echo 000)
    if [[ "$code" == "200" ]]; then echo "OK ${BASE_URL}"; else die "엔드포인트 응답 없음 (HTTP ${code}) — ${BASE_URL}"; fi
    ;;

  models)
    api "/v1/models" | python3 -c 'import sys,json; [print(m["id"]) for m in json.load(sys.stdin)["data"]]' \
      || die "모델 목록 조회 실패"
    ;;

  chat)
    MODEL="${1:-}"; shift || true
    [[ -n "$MODEL" ]] || die "사용법: llm-local.sh chat <model> [프롬프트] [--system ..] [--max-tokens N]"
    SYSTEM="" MAX_TOKENS=4096 TIMEOUT=300 PROMPT=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --system)     SYSTEM="$2"; shift 2 ;;
        --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
        --timeout)    TIMEOUT="$2"; shift 2 ;;
        *)            PROMPT="${PROMPT:+$PROMPT }$1"; shift ;;
      esac
    done
    [[ -n "$PROMPT" ]] || PROMPT=$(cat)   # 인자 없으면 stdin
    [[ -n "$PROMPT" ]] || die "프롬프트가 비어 있음 (인자 또는 stdin)"
    BODY=$(python3 - "$MODEL" "$MAX_TOKENS" "$SYSTEM" "$PROMPT" <<'PYEOF'
import sys, json
model, max_tokens, system, prompt = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
msgs = ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": prompt}]
print(json.dumps({"model": model, "messages": msgs, "max_tokens": max_tokens, "stream": False}))
PYEOF
    )
    api "/v1/chat/completions" -H "Content-Type: application/json" -d "$BODY" | extract_content
    ;;

  vision)
    MODEL="${1:-}"; IMG="${2:-}"; shift 2 || true
    PROMPT="${*:-이미지의 내용을 한국어로 설명해줘.}"
    [[ -n "$MODEL" && -f "$IMG" ]] || die "사용법: llm-local.sh vision <model> <이미지경로> [프롬프트]"
    TIMEOUT=300
    BODY=$(python3 - "$MODEL" "$IMG" "$PROMPT" <<'PYEOF'
import sys, json, base64, mimetypes
model, img, prompt = sys.argv[1], sys.argv[2], sys.argv[3]
mime = mimetypes.guess_type(img)[0] or "image/png"
b64 = base64.b64encode(open(img, "rb").read()).decode()
print(json.dumps({"model": model, "max_tokens": 4096, "stream": False, "messages": [{
    "role": "user",
    "content": [
        {"type": "text", "text": prompt},
        {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}},
    ]}]}))
PYEOF
    )
    api "/v1/chat/completions" -H "Content-Type: application/json" -d "$BODY" | extract_content
    ;;

  *)
    die "사용법: llm-local.sh {health|models|chat|vision} — 상세는 파일 상단 주석"
    ;;
esac
