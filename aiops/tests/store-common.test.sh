#!/usr/bin/env bash
# store-common.test.sh — aiops/scripts/store_common.py
#
# 스토어 업로드 공통 기반. 여기 있는 것은 전부 **조용히 틀릴 수 있는 지점**이다.
#   · KMS 0건은 "미등록" 이 아니다 (권한 없음과 구별 불가)
#   · KMS_TOKEN 은 레포 상위 폴더에 있을 수 있다 (zen-koi 실측)
#   · XcodeGen 레포의 버전 정본은 pbxproj 가 아니라 project.yml 이다
#
# 순수 bash(3.2 호환) + python3. 다른 테스트와 같은 출력 규약.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MOD_DIR="$REPO_ROOT/aiops/scripts"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/store-common-test.XXXXXX")"
cleanup() { rm -rf "$TMPBASE"; }
trap cleanup EXIT

TOTAL=0; PASS=0; FAIL=0
ok()    { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1"; }
notok() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "not ok $TOTAL - $1"; }
check() { [[ "$1" == "1" ]] && ok "$2" || notok "$2"; }

py()    { PYTHONPATH="$MOD_DIR" python3 -c "$1" 2>&1; }
# KMS_TOKEN 없는 상태로 실행 — env -u 는 셸 함수에 쓸 수 없다.
py_notok() { ( unset KMS_TOKEN; PYTHONPATH="$MOD_DIR" python3 -c "$1" 2>&1 ); }

new_ws() { local ws="$TMPBASE/ws_$RANDOM$RANDOM"; mkdir -p "$ws"; echo "$ws"; }

# ══════════════════════════════════════════════════════════════════
# C1 — 시크릿 이름 규칙: 하이픈 → 언더스코어, 대문자
# ══════════════════════════════════════════════════════════════════
out="$(py 'import store_common as s; print(s.secret_prefix("zen-koi"))')"
check "$([[ "$out" == "ZEN_KOI_" ]] && echo 1 || echo 0)" "C1 zen-koi → ZEN_KOI_ (실제: $out)"
out="$(py 'import store_common as s; print(s.secret_prefix("brick-breaker"))')"
check "$([[ "$out" == "BRICK_BREAKER_" ]] && echo 1 || echo 0)" "C1 brick-breaker → BRICK_BREAKER_"
out="$(py 'import store_common as s; print(s.secret_prefix("pong"))')"
check "$([[ "$out" == "PONG_" ]] && echo 1 || echo 0)" "C1 pong → PONG_"

# ══════════════════════════════════════════════════════════════════
# C2 — scope=app: 1순위 접두사, 2순위 무접두사. 둘 다 service=<앱슬러그>
# ══════════════════════════════════════════════════════════════════
out="$(py 'import store_common as s
print("|".join(f"{n}@{v}:{int(l)}" for n,v,l in s.secret_candidates("pong","ANDROID_KEYSTORE_BASE64")))')"
check "$([[ "$out" == "PONG_ANDROID_KEYSTORE_BASE64@pong:0|ANDROID_KEYSTORE_BASE64@pong:1" ]] && echo 1 || echo 0)" \
      "C2 app 범위 — 둘 다 service=pong (실제: $out)"

# ══════════════════════════════════════════════════════════════════
# C2b — scope=org: 조직 공용이 1순위. **service 가 조직으로 바뀐다**
#       이게 없으면 값이 등록돼 있는데 not_found 가 난다 (zen-koi #29)
# ══════════════════════════════════════════════════════════════════
out="$(py 'import store_common as s
print("|".join(f"{n}@{v}:{int(l)}" for n,v,l in s.secret_candidates("pong","APPSTORE_API_KEY_JSON")))')"
check "$([[ "$out" == "APPSTORE_API_KEY_JSON@devworld:0|PONG_APPSTORE_API_KEY_JSON@pong:1" ]] && echo 1 || echo 0)" \
      "C2b org 범위 — 1순위 service=devworld, 2순위는 이관 전 형식 (실제: $out)"

out="$(py 'import store_common as s
print("|".join(f"{n}@{v}" for n,v,_ in s.secret_candidates("zen-koi","PLAY_SERVICE_ACCOUNT_JSON")))')"
check "$([[ "$out" == "PLAY_SERVICE_ACCOUNT_JSON@devworld|ZEN_KOI_PLAY_SERVICE_ACCOUNT_JSON@zen-koi" ]] && echo 1 || echo 0)" \
      "C2b play 서비스 계정도 org (실제: $out)"

# ══════════════════════════════════════════════════════════════════
# C2c — scope 판정. 모르는 항목은 app (조직으로 잘못 넓히지 않는다)
# ══════════════════════════════════════════════════════════════════
out="$(py 'import store_common as s
print(",".join(s.secret_scope(k) for k in
  ["ANDROID_KEYSTORE_BASE64","ANDROID_KEY_ALIAS","APPSTORE_API_KEY_JSON","PLAY_SERVICE_ACCOUNT_JSON","UNKNOWN_KIND"]))')"
check "$([[ "$out" == "app,app,org,org,app" ]] && echo 1 || echo 0)" \
      "C2c 키스토어=app · API키/서비스계정=org · 미지=app (실제: $out)"

# ══════════════════════════════════════════════════════════════════
# C2d — service 를 빼지 않는다. 모든 후보에 service 가 있다
#       빼면 다른 앱의 동명 시크릿이 섞여 ambiguous 가 난다
# ══════════════════════════════════════════════════════════════════
out="$(py 'import store_common as s
bad=[c for k in s.SECRET_SCOPE for c in s.secret_candidates("zen-koi",k) if not c[1]]
print("EMPTY" if bad else "ALL_SET")')"
check "$([[ "$out" == "ALL_SET" ]] && echo 1 || echo 0)" "C2d 모든 후보에 service 가 있다"

# ══════════════════════════════════════════════════════════════════
# C3 — KMS_TOKEN 상위 폴더 탐색 (zen-koi 실측 구조)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); mkdir -p "$ws/game/zen-koi"
printf 'export KMS_TOKEN=tok_from_parent\n' > "$ws/game/.envrc"
out="$(py_notok "import store_common as s; from pathlib import Path; print(s.kms_token(Path('$ws/game/zen-koi')))")"
check "$([[ "$out" == "tok_from_parent" ]] && echo 1 || echo 0)" \
      "C3 레포에 .envrc 없어도 상위에서 찾는다 (실제: $out)"

ws=$(new_ws); mkdir -p "$ws/repo"
out="$(py_notok "import store_common as s; from pathlib import Path; print(s.kms_token(Path('$ws/repo')))")"
check "$([[ "$out" == "None" ]] && echo 1 || echo 0)" "C3 어디에도 없으면 None"

out="$(KMS_TOKEN=from_env py "import store_common as s; from pathlib import Path; print(s.kms_token(Path('$ws/repo')))")"
check "$([[ "$out" == "from_env" ]] && echo 1 || echo 0)" "C3 환경변수가 우선"

# ══════════════════════════════════════════════════════════════════
# C4 — 버전 정본: XcodeGen 레포는 project.yml 을 읽는다
# ══════════════════════════════════════════════════════════════════
# pbxproj 가 아직 없는 상태(클린 체크아웃) — 정본에서 읽어야 한다
ws=$(new_ws)
printf 'targets:\n  App:\n    settings:\n      MARKETING_VERSION: "2.5.0"\n      CURRENT_PROJECT_VERSION: 42\n' > "$ws/project.yml"
out="$(py "import store_common as s; from pathlib import Path
r=Path('$ws'); print('|'.join(s.ios_version(r, r/'App.xcodeproj/project.pbxproj')))")"
check "$(printf '%s' "$out" | grep -q '^2.5.0|42|project.yml' && echo 1 || echo 0)" \
      "C4 pbxproj 부재 시 project.yml 이 정본 (실제: $out)"

# pbxproj 가 있고 값이 같은 정상 상태 — 출처는 여전히 project.yml
ws=$(new_ws)
printf 'targets:\n  App:\n    settings:\n      MARKETING_VERSION: "2.5.0"\n      CURRENT_PROJECT_VERSION: 42\n' > "$ws/project.yml"
mkdir -p "$ws/App.xcodeproj"
printf 'MARKETING_VERSION = 2.5.0;\nCURRENT_PROJECT_VERSION = 42;\n' > "$ws/App.xcodeproj/project.pbxproj"
out="$(py "import store_common as s; from pathlib import Path
r=Path('$ws'); print('|'.join(s.ios_version(r, r/'App.xcodeproj/project.pbxproj')))")"
check "$(printf '%s' "$out" | grep -q '^2.5.0|42|project.yml' && echo 1 || echo 0)" \
      "C4 값이 같아도 출처는 project.yml (실제: $out)"

# ══════════════════════════════════════════════════════════════════
# C5 — 버전이 **갈려 있으면** 중단한다
#      generate 안 한 상태로 올리면 빌드는 성공하고 옛 버전이 올라간다
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
mkdir -p "$ws/App.xcodeproj"
printf 'MARKETING_VERSION = 1.0.0;\n' > "$ws/App.xcodeproj/project.pbxproj"
printf 'targets:\n  App:\n    settings:\n      MARKETING_VERSION: "2.5.0"\n' > "$ws/project.yml"
out="$(py "import store_common as s; from pathlib import Path
r=Path('$ws'); s.ios_version(r, r/'App.xcodeproj/project.pbxproj')" ; echo "rc=$?")"
check "$(printf '%s' "$out" | grep -q 'xcodegen generate' && echo 1 || echo 0)" \
      "C5 버전이 갈리면 중단하고 generate 를 안내"
check "$(printf '%s' "$out" | grep -q 'rc=1' && echo 1 || echo 0)" "C5 종료 코드 1"
check "$(printf '%s' "$out" | grep -q '2.5.0' && printf '%s' "$out" | grep -q '1.0.0' && echo 1 || echo 0)" \
      "C5 두 값을 모두 보여준다 (무엇이 갈렸는지)"

# ══════════════════════════════════════════════════════════════════
# C5b — mtime 이 뒤집혀도 **버전이 같으면 통과한다**
#       project.yml 을 버전과 무관한 이유로 고쳐도 막히면 안 된다.
#       zen-koi 실측에서 오탐이 났던 경우다(서명 팀 설정 변경).
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
mkdir -p "$ws/App.xcodeproj"
printf 'MARKETING_VERSION = 1.0.0;\nCURRENT_PROJECT_VERSION = 3;\n' > "$ws/App.xcodeproj/project.pbxproj"
sleep 1
printf 'targets:\n  App:\n    settings:\n      MARKETING_VERSION: "1.0.0"\n      CURRENT_PROJECT_VERSION: 3\n      DEVELOPMENT_TEAM: ABC123\n' > "$ws/project.yml"
out="$(py "import store_common as s; from pathlib import Path
r=Path('$ws'); print('|'.join(s.ios_version(r, r/'App.xcodeproj/project.pbxproj')))" ; echo "rc=$?")"
check "$(printf '%s' "$out" | grep -q '^1.0.0|3|project.yml' && echo 1 || echo 0)" \
      "C5b mtime 은 뒤집혔으나 버전이 같으면 통과 (실제: $(printf '%s' "$out" | head -1))"
check "$(printf '%s' "$out" | grep -q 'rc=0' && echo 1 || echo 0)" "C5b 종료 코드 0"

# ══════════════════════════════════════════════════════════════════
# C6 — XcodeGen 을 안 쓰는 레포는 pbxproj 를 읽는다 (종전 동작)
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws); mkdir -p "$ws/App.xcodeproj"
printf 'MARKETING_VERSION = 3.1.0;\nCURRENT_PROJECT_VERSION = 9;\n' > "$ws/App.xcodeproj/project.pbxproj"
out="$(py "import store_common as s; from pathlib import Path
r=Path('$ws'); print('|'.join(s.ios_version(r, r/'App.xcodeproj/project.pbxproj')))")"
check "$(printf '%s' "$out" | grep -q '^3.1.0|9|project.pbxproj' && echo 1 || echo 0)" \
      "C6 project.yml 없으면 pbxproj (실제: $out)"

# ══════════════════════════════════════════════════════════════════
# C7 — KmsResult 세 상태를 구별한다. ok 가 아니면 전부 차단 대상
# ══════════════════════════════════════════════════════════════════
out="$(py 'import store_common as s
for st in ("ok","token_missing","not_found","fetch_failed","ambiguous","no_value"):
    print(st, s.KmsResult(st).ok)')"
check "$(printf '%s' "$out" | grep -q '^ok True' && echo 1 || echo 0)" "C7 ok 만 통과"
check "$(printf '%s' "$out" | grep -c 'False' | grep -q '^5$' && echo 1 || echo 0)" \
      "C7 나머지 5상태는 전부 차단"

# ══════════════════════════════════════════════════════════════════
# C8 — HANDOFF 마커가 계약 형식을 따른다
# ══════════════════════════════════════════════════════════════════
out="$(py 'import store_common as s
r=s.KmsResult("not_found", name="APPSTORE_API_KEY_JSON", service="devworld",
              tried="APPSTORE_API_KEY_JSON@devworld · PONG_APPSTORE_API_KEY_JSON@pong",
              detail="조회 0건")
print(r.handoff("appstore_api_key","kms"))')"
check "$(printf '%s' "$out" | grep -q '^## ⏸️ 사람 확인 대기$' && echo 1 || echo 0)" "C8 헤더가 계약과 일치"
check "$(printf '%s' "$out" | grep -q '^HANDOFF_REQUIRED=appstore_api_key$' && echo 1 || echo 0)" "C8 REQUIRED 토큰"
check "$(printf '%s' "$out" | grep -q '^HANDOFF_ACCESS=kms$' && echo 1 || echo 0)" "C8 ACCESS 토큰"

# VERIFY 에 조회 범위가 담겨야 한다 — "못 찾았다" 를 받은 사람이
# 범위 밖인지 진짜 없는지를 스스로 판단할 수 있어야 한다 (zen-koi #29)
check "$(printf '%s' "$out" | grep -q 'HANDOFF_VERIFY=.*@devworld' && echo 1 || echo 0)" \
      "C8 VERIFY 에 조회한 service 가 담긴다"
check "$(printf '%s' "$out" | grep -q 'HANDOFF_VERIFY=.*@pong' && echo 1 || echo 0)" \
      "C8 VERIFY 에 2순위(이관 전)도 담긴다"

# ══════════════════════════════════════════════════════════════════
# C9 — 실측: zen-koi 의 버전 정본이 project.yml 로 읽힌다
# ══════════════════════════════════════════════════════════════════
ZK=/Users/devworld/src/game/zen-koi
if [[ -f "$ZK/ios/project.yml" ]]; then
  out="$(py "import store_common as s; from pathlib import Path
r=Path('$ZK'); print(s.xcodegen_project(r))")"
  check "$(printf '%s' "$out" | grep -q 'ios/project.yml' && echo 1 || echo 0)" \
        "C9 zen-koi 의 project.yml 을 찾는다 (실제: $out)"
else
  ok "C9 SKIP — zen-koi 로컬에 없음"
fi

# ══════════════════════════════════════════════════════════════════
# D1~ — 1·2순위가 둘 다 있을 때 조용히 고르지 않는다
#       키스토어는 조용한 실패 비용이 가장 크다 (zen-koi, seq 113)
# ══════════════════════════════════════════════════════════════════
out="$(py 'import store_common as s
r = s.KmsResult("duplicate_conflict", name="ANDROID_KEYSTORE_BASE64", service="pong",
                tried="A@pong · B@pong", detail="서로 다른 값")
print(r.handoff("keystore_conflict","kms"))')"
check "$(printf '%s' "$out" | grep -q '^HANDOFF_DECISION=keystore_conflict$' && echo 1 || echo 0)" \
      "D1 충돌은 DECISION 토큰 — 스킬이 선택지를 제시할 수 있다"
check "$(printf '%s' "$out" | grep -q 'HANDOFF_REQUIRED' && echo 0 || echo 1)" \
      "D1 충돌에 REQUIRED 를 쓰지 않는다"

out="$(py 'import store_common as s
r = s.KmsResult("not_found", name="X", service="devworld", tried="X@devworld")
print(r.handoff("play_service_account","kms"))')"
check "$(printf '%s' "$out" | grep -q '^HANDOFF_REQUIRED=play_service_account$' && echo 1 || echo 0)" \
      "D1 그 밖의 실패는 REQUIRED 그대로"

# ── 지문은 값을 노출하지 않고 같은지만 구별한다
out="$(py 'import hashlib, json
def fp(p): return hashlib.sha256(json.dumps(p,sort_keys=True,ensure_ascii=False).encode()).hexdigest()[:8]
a={"private_key":"AAA","client_email":"x@y"}; b={"client_email":"x@y","private_key":"AAA"}; c={"private_key":"BBB"}
print(fp(a)==fp(b), fp(a)==fp(c), len(fp(a)), "AAA" in fp(a))')"
check "$([[ "$out" == "True False 8 False" ]] && echo 1 || echo 0)" \
      "D2 지문 — 키 순서 무관·다른 값 구별·8자·원문 미포함 (실제: $out)"

# ══════════════════════════════════════════════════════════════════
# D2b — **실제 kms_fetch 경로**를 탄다. _curl 을 대체해 KMS 응답을 흉내낸다.
#       앞의 D1·D2 는 handoff()·지문 함수만 보므로 조회 로직의 회귀를 못 잡는다.
#       (변이 테스트에서 이 구멍이 드러났다)
# ══════════════════════════════════════════════════════════════════
fetch_case() {   # $1=1순위 값 $2=2순위 값 (빈 문자열이면 없음) → "status|duplicate|legacy"
  FIRST="$1" SECOND="$2" PYTHONPATH="$MOD_DIR" python3 - <<'PYEOF' 2>&1
import json, os, sys
import store_common as s
from pathlib import Path
first, second = os.environ["FIRST"], os.environ["SECOND"]

def fake_curl(args):
    url = args[-1]
    if url.endswith("/health"):
        return (0, "{}")
    if "secrets?q=" in url:
        name = url.split("q=")[1].split("&")[0]
        svc = "devworld" if name == "APPSTORE_API_KEY_JSON" else "pong"
        val = first if name == "APPSTORE_API_KEY_JSON" else second
        if not val:
            return (0, json.dumps({"items": []}))
        return (0, json.dumps({"items": [{"id": name, "name": name, "service": svc,
                                          "environment": "prod", "has_value": True}]}))
    if "/reveal" in url:
        sid = url.split("/secrets/")[1].split("/reveal")[0]
        val = first if sid == "APPSTORE_API_KEY_JSON" else second
        return (0, json.dumps({"value": val}))
    return (1, "")

s._curl = fake_curl
s.kms_token = lambda root: "tok"
r = s.kms_fetch(Path("/tmp"), "pong", "APPSTORE_API_KEY_JSON")
print(f"{r.status}|{r.duplicate}|{int(r.legacy)}")
PYEOF
}
V1='{"key_id": "AAA"}'
V2='{"key_id": "BBB"}'

out="$(fetch_case "$V1" "")"
check "$([[ "$out" == "ok||0" ]] && echo 1 || echo 0)" "D2b 1순위만 있으면 ok (실제: $out)"

out="$(fetch_case "" "$V1")"
check "$([[ "$out" == "ok||1" ]] && echo 1 || echo 0)" "D2b 2순위만 있으면 ok+legacy (실제: $out)"

out="$(fetch_case "$V1" "$V1")"
check "$([[ "$out" == "ok|identical|0" ]] && echo 1 || echo 0)" \
      "D2b 값이 같으면 ok+duplicate=identical (실제: $out)"

out="$(fetch_case "$V1" "$V2")"
check "$([[ "$out" == "duplicate_conflict||0" ]] && echo 1 || echo 0)" \
      "D2b 값이 다르면 **중단** — 조용히 1순위를 쓰지 않는다 (실제: $out)"

out="$(fetch_case "" "")"
check "$(printf '%s' "$out" | grep -q '^not_found' && echo 1 || echo 0)" \
      "D2b 둘 다 없으면 not_found (실제: $out)"

# ══════════════════════════════════════════════════════════════════
# D3 — ExportOptions 는 destination=export 로 만든다
#      upload 로 두면 내보내기와 업로드가 한 명령에 붙어 불가역 단계를 떼어낼 수 없다
# ══════════════════════════════════════════════════════════════════
ws=$(new_ws)
out="$(py "import store_common as s; from pathlib import Path
p = s.ensure_export_options(Path('$ws/ExportOptions.plist'), 'ABC123')
print(p.read_text())")"
check "$(printf '%s' "$out" | grep -q '<key>destination</key><string>export</string>' && echo 1 || echo 0)" \
      "D3 destination=export (upload 아님)"
check "$(printf '%s' "$out" | grep -q '<key>signingStyle</key><string>automatic</string>' && echo 1 || echo 0)" \
      "D3 signingStyle=automatic (기존 두 레포와 일치)"
check "$(printf '%s' "$out" | grep -q 'ABC123' && echo 1 || echo 0)" "D3 teamID 주입"

# ── 있으면 덮어쓰지 않는다. 한 레포에 AppStore·TestFlight 용이 따로 있다
ws=$(new_ws)
printf 'EXISTING-DO-NOT-TOUCH\n' > "$ws/ExportOptions.plist"
out="$(py "import store_common as s; from pathlib import Path
p = s.ensure_export_options(Path('$ws/ExportOptions.plist'), 'ABC123')
print(p.read_text().strip())")"
check "$([[ "$out" == "EXISTING-DO-NOT-TOUCH" ]] && echo 1 || echo 0)" \
      "D3 기존 파일을 덮어쓰지 않는다 (실제: $out)"

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]] && exit 0 || exit 1
