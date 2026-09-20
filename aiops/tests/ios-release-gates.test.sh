#!/usr/bin/env bash
# ios-release-gates.test.sh — iOS 출시 경로의 세 결함 (zen-koi #38·#39·#40)
#
# 셋 다 **첫 실사용에서만 드러나는** 종류였다.
#   #38  PyJWT 부재 시 접근 확인을 건너뛰고 종료 코드 0 — "확인 불가"가 ✅ 와 같은 코드
#   #39  팀 ID 를 인자로 요구하는데 이미 읽고 있는 파일에 있다
#   #40  시뮬레이터 캡처가 RGBA — App Store 가 거부한다
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$REPO_ROOT/aiops/skills/iphone-release/SKILL.md"
UP="$REPO_ROOT/aiops/scripts/appstore_upload.py"
SC="$REPO_ROOT/aiops/scripts/store_common.py"

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/ios-gates-test.XXXXXX")"
trap 'rm -rf "$TMPBASE"' EXIT

TOTAL=0; PASS=0; FAIL=0
ok()    { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "ok $TOTAL - $1"; }
notok() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "not ok $TOTAL - $1"; }
check() { [[ "$1" == "1" ]] && ok "$2" || notok "$2"; }

py() { python3 - "$@"; }
load_sc() {  # store_common 을 이름 붙여 로드한다 (dataclass 가 sys.modules 를 본다)
  cat <<'PYHDR'
import importlib.util, sys, pathlib, tempfile, shutil
spec = importlib.util.spec_from_file_location("store_common", sys.argv[1])
sc = importlib.util.module_from_spec(spec); sys.modules["store_common"] = sc
spec.loader.exec_module(sc)
PYHDR
}

# ── A. #38 — 접근 확인을 건너뛰지 않는가 ────────────────────────────
SRC="$(cat "$UP")"
check "$(echo "$SRC" | grep -q 'import jwt' && echo 0 || echo 1)" "A1 PyJWT 의존이 없다"
check "$(echo "$SRC" | grep -q '건너뜁니다' && echo 0 || echo 1)" "A2 '건너뜁니다' 경로가 없다"
check "$(echo "$SRC" | grep -q 'decode_dss_signature' && echo 1)" "A3 ES256 DER→R‖S 변환을 한다"
check "$(echo "$SRC" | grep -A3 'cryptography 가 없어' | grep -q 'SystemExit(2)' && echo 1)" \
      "A4 cryptography 부재는 **종료 코드 2** (0 이 아니다)"
check "$(echo "$SRC" | grep -q '확인했다고 보지 않습니다' && echo 1)" "A5 확인 못 했다고 말한다"

# JWT 가 **실제로 유효한 서명**인가 — 문자열이 그럴듯한 것과는 다르다
JWT_OUT="$(py "$UP" <<'PYEOF' 2>&1
import importlib.util, sys, base64, json
spec = importlib.util.spec_from_file_location("appstore_upload", sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.modules["appstore_upload"] = m
try:
    spec.loader.exec_module(m)
except Exception as e:
    print("LOADFAIL:%s" % e); raise SystemExit(0)
try:
    from cryptography.hazmat.primitives.asymmetric import ec, utils as au
    from cryptography.hazmat.primitives import hashes, serialization
except ImportError:
    print("SKIP:cryptography 없음"); raise SystemExit(0)
k = ec.generate_private_key(ec.SECP256R1())
pem = k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                      serialization.NoEncryption()).decode()
tok = m._asc_jwt({"key_id": "K1", "issuer_id": "I1", "private_key": pem})
h, p, s = tok.split(".")
d = lambda x: base64.urlsafe_b64decode(x + "=" * (-len(x) % 4))
raw = d(s)
hdr = json.loads(d(h)); pld = json.loads(d(p))
r = int.from_bytes(raw[:32], "big"); s2 = int.from_bytes(raw[32:], "big")
try:
    k.public_key().verify(au.encode_dss_signature(r, s2), (h + "." + p).encode(),
                          ec.ECDSA(hashes.SHA256()))
    verified = True
except Exception:
    verified = False
try:
    k.public_key().verify(au.encode_dss_signature(r, s2), (h + "." + p + "x").encode(),
                          ec.ECDSA(hashes.SHA256()))
    tamper_rejected = False
except Exception:
    tamper_rejected = True
print("ALG:%s AUD:%s LEN:%d VERIFIED:%s TAMPER_REJECTED:%s"
      % (hdr.get("alg"), pld.get("aud"), len(raw), verified, tamper_rejected))
PYEOF
)"
if [[ "$JWT_OUT" == SKIP:* || "$JWT_OUT" == LOADFAIL:* ]]; then
  notok "A6 JWT 를 검증하지 못했습니다 — $JWT_OUT (**검사 불가**)"
  notok "A7 건너뜀"; notok "A8 건너뜀"
else
  check "$(echo "$JWT_OUT" | grep -q 'ALG:ES256' && echo 1)" "A6 alg 가 ES256 ($JWT_OUT)"
  check "$(echo "$JWT_OUT" | grep -q 'LEN:64' && echo 1)" "A7 서명이 64바이트 (DER 그대로면 다르다)"
  check "$(echo "$JWT_OUT" | grep -q 'VERIFIED:True TAMPER_REJECTED:True' && echo 1)" \
        "A8 **서명이 실제로 검증되고 변조본은 거부된다**"
fi

# ── B. #39 — 팀 ID 를 이미 읽는 파일에서 찾는가 ─────────────────────
TEAM_OUT="$( { load_sc; cat <<'PYEOF'
root = pathlib.Path(tempfile.mkdtemp())
(root / "ios").mkdir()
(root / "ios/project.yml").write_text('settings:\n  DEVELOPMENT_TEAM: "FROMYML99"\n')
print("YML:%s" % (sc.find_team_id(root, root / "none.pbxproj", "")[0],))
print("YMLSRC:%s" % ("project.yml" in sc.find_team_id(root, root / "none.pbxproj", "")[1],))
print("EXPLICIT:%s" % (sc.find_team_id(root, root / "none.pbxproj", "GIVEN123")[0],))
(root / "ExportOptions.plist").write_text(
    "<plist><dict><key>teamID</key><string>FROMPLIST</string></dict></plist>")
print("PLIST:%s" % (sc.find_team_id(root, root / "none.pbxproj", "")[0],))
r2 = pathlib.Path(tempfile.mkdtemp())
(r2 / "p.pbxproj").write_text("\t\t\t\tDEVELOPMENT_TEAM = FROMPBX77;\n")
print("PBX:%s" % (sc.find_team_id(r2, r2 / "p.pbxproj", "")[0],))
r3 = pathlib.Path(tempfile.mkdtemp())
print("NONE:%s|%s" % sc.find_team_id(r3, r3 / "none.pbxproj", ""))
for d in (root, r2, r3): shutil.rmtree(d)
PYEOF
} | python3 - "$SC" 2>&1)"
check "$(echo "$TEAM_OUT" | grep -q 'YML:FROMYML99' && echo 1)" "B1 project.yml 의 DEVELOPMENT_TEAM 을 읽는다"
check "$(echo "$TEAM_OUT" | grep -q 'YMLSRC:True' && echo 1)" "B2 출처를 돌려준다 (엉뚱한 팀 서명을 사람이 본다)"
check "$(echo "$TEAM_OUT" | grep -q 'EXPLICIT:GIVEN123' && echo 1)" "B3 --team-id 가 1순위"
check "$(echo "$TEAM_OUT" | grep -q 'PLIST:FROMPLIST' && echo 1)" "B4 기존 ExportOptions.plist 가 project.yml 보다 앞선다"
check "$(echo "$TEAM_OUT" | grep -q 'PBX:FROMPBX77' && echo 1)" "B5 XcodeGen 미사용 레포는 pbxproj 로 폴백"
check "$(echo "$TEAM_OUT" | grep -q 'NONE:|' && echo 1)" "B6 어디에도 없으면 빈 값 (추측하지 않는다)"
check "$(grep -q '추측하지 않습니다' "$SC" && echo 1)" "B7 못 찾으면 추측하지 않는다고 말한다"
check "$(grep -q '찾아본 곳' "$SC" && echo 1)" "B8 어디를 찾아봤는지 알려준다"

# ── C. #40 — 알파 채널 게이트 ───────────────────────────────────────
extract_block() {
  awk -v a=">>> $2 >>>" -v b="<<< $2 <<<" 'index($0,a){f=1;next} index($0,b){f=0} f' "$1"
}
CODE="$(extract_block "$SKILL" "iphone-release:screenshot-alpha")"
if [[ -z "$CODE" ]]; then
  notok "C0 앵커 추출 실패 — iphone-release:screenshot-alpha"
else
  GATE="$TMPBASE/alpha.sh"; printf '%s\n' "$CODE" > "$GATE"
  python3 -c "import PIL" 2>/dev/null && HAVE_PIL=1 || HAVE_PIL=0
  if [[ "$HAVE_PIL" == "0" ]]; then
    notok "C1 Pillow 가 없어 알파 게이트를 검증하지 못했습니다 — **검사 불가**"
  else
    python3 - "$TMPBASE" <<'PYEOF'
import sys, pathlib
from PIL import Image
W = pathlib.Path(sys.argv[1])
def mk(sub, mode, alpha=None):
    d = W / sub; d.mkdir(parents=True, exist_ok=True)
    im = Image.new(mode, (40, 60), (1, 2, 3, 255) if mode == "RGBA" else (1, 2, 3))
    if mode == "RGBA" and alpha is not None:
        im.putalpha(im.getchannel("A").point(lambda _: alpha))
    im.save(d / "s.png")
mk("a_rgb", "RGB"); mk("a_opaque", "RGBA", 255); mk("a_transp", "RGBA", 128)
(W / "a_empty").mkdir(exist_ok=True)
(W / "a_broken").mkdir(exist_ok=True); (W / "a_broken/x.png").write_bytes(b"nope")
PYEOF
    OUT="$(bash "$GATE" "$TMPBASE/a_rgb" 2>&1)"; RC=$?
    check "$([[ "$RC" == "0" ]] && echo 1)" "C1 알파 없는 PNG 는 0"
    OUT="$(bash "$GATE" "$TMPBASE/a_opaque" 2>&1)"; RC=$?
    check "$([[ "$RC" == "1" ]] && echo 1)" "C2 알파 채널이 있으면 1 (전부 불투명이어도)"
    check "$(echo "$OUT" | grep -q '무손실' && echo 1)" "C3 무손실임을 알려준다"
    OUT="$(bash "$GATE" "$TMPBASE/a_transp" 2>&1)"; RC=$?
    check "$([[ "$RC" == "1" ]] && echo 1)" "C4 투명 픽셀이 있어도 1"
    check "$(echo "$OUT" | grep -q '배경색' && echo 1)" \
          "C5 **투명 픽셀은 배경색이 필요하다고 구별한다** (그냥 떼면 검게 나간다)"
    check "$(echo "$OUT" | grep -q '무손실' && echo 0 || echo 1)" "C6 투명한 경우를 무손실이라 하지 않는다"
    OUT="$(bash "$GATE" "$TMPBASE/a_empty" 2>&1)"; RC=$?
    check "$([[ "$RC" == "2" ]] && echo 1)" "C7 PNG 가 없으면 2 (이상 없음 0 이 아니다)"
    OUT="$(bash "$GATE" "$TMPBASE/a_broken" 2>&1)"; RC=$?
    check "$([[ "$RC" == "2" ]] && echo 1)" "C8 열지 못하면 2"
    OUT="$(bash "$GATE" "$TMPBASE/없는디렉터리" 2>&1)"; RC=$?
    check "$([[ "$RC" == "2" ]] && echo 1)" "C9 디렉터리가 없으면 2"
  fi
fi

# ── D. 문서 규약 ─────────────────────────────────────────────────────
check "$(grep -q "Images can't include alpha channels" "$SKILL" && echo 1)" "D1 Apple 규격 원문을 인용한다"
check "$(grep -q 'asc_version_mismatch' "$SKILL" && echo 1)" "D2 ASC 버전 불일치 마커가 있다"
check "$(grep -q 'assetDeliveryState' "$SKILL" && echo 1)" "D3 업로드 후 대기를 적는다"
check "$(grep -q '빌드가 안 보인다' "$SKILL" && echo 1)" "D4 버전 불일치가 어떤 모습으로 드러나는지 적는다"
# **확인하지 않은 단정을 지웠는가** — 이 레포가 반복해 고쳐 온 부류다
check "$(grep -q '스크린샷 슬롯은 계정마다 다르다' "$SKILL" && echo 0 || echo 1)" \
      "D5 '계정마다 다르다' 단정이 남아 있지 않다"
check "$(grep -q '확인하지 않은 단정' "$SKILL" && echo 1)" "D6 그것이 단정이었음을 밝힌다"
check "$(grep -q '여전히 확인되지 않았다' "$SKILL" && echo 1)" \
      "D7 새 설명도 확정으로 쓰지 않는다 (반대편 단정으로 갈아타지 않는다)"

# ── E. §4-5 — 모르는 것을 게이트로 굳히지 않았는가 ──────────────────
# zen-koi 가 "확인이 어려우면 확인 자체를 안 하는 것도 답" 이라고 물었고 그 답을 적었다.
# **판정 기준을 모르는 채 게이트를 두면 통과도 실패도 근거가 없다.**
check "$(grep -q 'iOS 9.0–26.0 Deprecated' "$SKILL" && echo 1)" "E1 UIRequiresFullScreen deprecated 를 원문으로 인용한다"
check "$(grep -q '새로 넣지 않는다' "$SKILL" && echo 1)" "E2 경고를 없애려고 deprecated 키를 넣지 말라고 한다"
check "$(grep -q '심사 반려 사유인지 확인하지 못했다' "$SKILL" && echo 1)" "E3 확인 못 한 것을 확인 못 했다고 적는다"
check "$(grep -q '게이트를 만들지 않는다' "$SKILL" && echo 1)" "E4 모르는 것을 게이트로 굳히지 않는다"
# 이 절이 §4 표에 행을 추가하지 **않았는지** — 기준을 모르는데 표에 넣으면 판정이 생긴다
check "$(grep -q '| \*\*iPad 방향\*\* |' "$SKILL" && echo 0 || echo 1)" "E5 §4 표에 방향 행을 넣지 않았다"

echo "TESTS=$TOTAL PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
