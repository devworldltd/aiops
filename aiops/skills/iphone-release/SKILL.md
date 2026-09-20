---
name: iphone-release
description: "iOS 앱을 App Store Connect 에 올린다 — 신규 출시와 업데이트 모두. 빌드·아카이브·내보내기·업로드·메타데이터·설문을 자동화하고, 사람만 할 수 있는 것(개발자 계정·API 키 발급·DSA 거래자 전환·심사 반려 대응)에서는 HANDOFF 마커를 남기고 멈춘다. 불가역 단계를 격리한다."
---

# /aiops:iphone-release — iOS 스토어 출시

세션이 담당하는 앱 하나를 App Store Connect 에 올린다.

설계 정본은 [`docs/design/release-skills.md`](../../../docs/design/release-skills.md),
중단 상태 규약은 [`docs/contracts/handoff-marker.md`](../../../docs/contracts/handoff-marker.md) 다.

## 절대 원칙

1. **불가역 단계를 격리한다.** 앱 레코드 생성·심사 제출·업로드는 되돌릴 수 없다.
   되돌릴 수 있는 단계를 먼저 끝내고, 불가역 단계는 **사람 확인을 받고** 실행한다.
2. **판정 실패 시 신규로 가정하지 않는다.** 신규 경로는 앱 레코드를 만든다.
   조회가 실패하면 중단한다.
3. **사람 영역에서는 멈추고 마커를 남긴다.** 완료 표시만 되고 실제로는 안 된 상태가 가장 위험하다.
4. **확인할 수 있는 것은 확인한다.** 사람 보고를 그대로 믿지 않는다(계약 규약 4).
5. **스크린샷 슬롯을 하드코딩하지 않는다.** ASC API 로 조회한다(§4-2).

---

## §1 인자

```
/aiops:iphone-release <slug> [--root=<경로>] [--portal=<경로>]
                             [--dry-run] [--archive-only] [--export-only]
                             [--submit]
```

| 인자 | 뜻 |
|---|---|
| `<slug>` | KMS service · app-portal content 의 앱 슬러그 |
| `--dry-run` | 자격증명·접근·사전 점검만. **아무것도 바꾸지 않는다** |
| `--archive-only` | 빌드까지 |
| `--export-only` | ipa 로컬 내보내기까지. **업로드하지 않는다** |
| `--submit` | 심사 제출까지. **없으면 업로드에서 멈춘다** |

기본값은 **업로드까지**이며 심사 제출은 하지 않는다. 제출은 별도 플래그로 분리한다 —
되돌릴 수 없고, 반려되면 사람이 대응해야 한다.

## §2 전제 확인 (생략 금지)

```bash
PLATFORM=$(jq -r '.agent_hints.platform // ""' .claude/config.json 2>/dev/null)
SIGNAL=$(jq -r '.agent_hints.platform_signal // "unknown"' .claude/config.json 2>/dev/null)
CAPS=$(jq -r '.agent_hints.mobile.capabilities // {} | @json' .claude/config.json 2>/dev/null)
```

| 상태 | 처리 |
|---|---|
| `agent_hints.mobile` 없음 | `/aiops:setup` 을 먼저 돌린다. 여기서 중단 |
| `platform_signal` 이 `none (fallback)` | **감지가 돌았고 아무것도 못 찾았다.** 사람 확인을 받고 진행 |
| `platform_signal` 이 `unknown` | **키 자체가 없다** — v1.16.1 이전 `/aiops:setup` 이 만든 config. 감지 실패가 아니라 **기록 부재**다. `/aiops:setup` 재실행으로 채워진다 |
| `framework` 에 `ios-native` 없음 | 이 스킬 대상이 아니다 |

> **세 상태를 구별한다.** `unknown` 은 감지가 실패한 것도 성공한 것도 아니고, **그 기능이
> 생기기 전에 만들어진 설정**이다. 처방이 `none (fallback)` 과 다르다 — 사람 확인이 아니라
> `/aiops:setup` 재실행이다(zen-koi #32).
>
> ```
> apps/blog/wrangler.jsonc   신호로 판정
> none (fallback)            감지가 돌았고 못 찾음
> unknown                    필드가 생기기 전 config — 기록 자체가 없음
> ```
>
> `HANDOFF_VERIFY` 에는 셋을 구별할 수 있게 적는다:
> `platform=mobile signal=unknown (pre-v1.16.1 config)`

## §3 신규 출시와 업데이트 판정

**스토어에 기존 레코드가 있는지로 갈린다.** ASC API 로 확인한다.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/appstore_upload.py" --slug <slug> --root <root> --dry-run
```

`--dry-run` 이 `verify_access` 를 호출해 `bundleId` 로 앱을 조회한다.

| 결과 | 판정 |
|---|---|
| 앱이 있음 | **업데이트** — 버전 증가, 변경된 메타데이터만, 설문은 변경 시에만 |
| 앱이 없음 | **신규** — 앱 레코드 생성(**불가역**), 메타데이터 전량, 설문 전량 |
| 조회 실패 (HTTP 4xx/5xx) | **중단.** 신규로 가정하지 않는다 |

앱 레코드 생성은 이 스킬이 하지 않는다. `HANDOFF_REQUIRED=app_record` 를 남기고 멈추고
[`/aiops:app-record`](../app-record/SKILL.md) 로 넘긴다.

**ASC API 로는 앱을 만들 수 없다.** Apple 공식 문서가 명시한다 — `apps` 리소스는 이미 있는
앱을 읽고 고치는 용도다.

> Don't use this API to create new apps; instead, create new apps on the App Store Connect website.

> **정정(2026-09-20).** 이 자리에 "이름·기본 언어·번들 ID 가 한 번 정해지면 바꾸기 어렵다" 고
> 적혀 있었는데 **확인하지 않은 단정이었다.** ASC API `Modify an app` 은
> **번들 ID 와 기본 언어까지** 고칠 수 있다. 바꾸기 어려운 쪽은 Android 다 — Play 의
> 패키지명은 영구다(`/aiops:app-record` §4). 비대칭은 **생성이 아니라 생성 이후**에 있다.

## §4 사전 점검 — 출시 도중이 아니라 여기서 드러나야 한다

brick-breaker 실측(2026-09-19)에서 막힌 것들이다.

| 점검 | 방법 | 실패 시 |
|---|---|---|
| 개인정보처리방침 URL | §4-1 게이트 — **리다이렉트를 따라간** 최종 상태 | `HANDOFF_REQUIRED=privacy_policy_not_published` |
| 앱 이름 가용성 | ASC API 조회 | `HANDOFF_DECISION=app_name_conflict` — **대안을 계산해 제시한다** |
| 전화번호 형식 | `+82` 등 국가 코드 포함 | **입력 검증** — 자동 교정. 사람 영역이 아니다 |
| 수출 규정 | `Info.plist` 에 `ITSAppUsesNonExemptEncryption=false` | 스킬이 추가 |
| 콘텐츠 권한 | 에셋 생성 방식·광고 송출 주체로 판정 | `HANDOFF_DECISION=content_rights` — 근거와 함께 제안 |
| 스크린샷 슬롯 | **ASC API 로 조회** | 필요한 해상도만 촬영 |
| **스크린샷 알파 채널** | §4-2 게이트 — RGBA 면 거부된다 | 중단. 채널을 떼고 다시 |
| **ASC 버전 일치** | §4-3 — `MARKETING_VERSION` == `versionString` | `HANDOFF_DECISION=asc_version_mismatch` |
| DSA 거래자 전환 | 확인 불가 | `HANDOFF_REQUIRED=dsa_trader_verification` |
| 연령 등급 | config 값 | `HANDOFF_DECISION=age_rating_decision` |

**개인정보처리방침 URL 이 404 면 반려된다.** app-portal 배포가 스토어 등록보다 먼저다 —
`/aiops:app-pages` 로 문서를 만들고 사람이 배포한 뒤에 여기로 온다.

### §4-1 개인정보처리방침 점검 — 리다이렉트를 따라간다

`android-release` §5-1 의 `release:privacy-check` 게이트를 그대로 쓴다. 판정도 같다.

| 실제 상태 | 판정 |
|---|---|
| 307 → 200 | 통과. **최종 URL 을 보고에 남긴다** |
| 200 | 통과 |
| 404 · 5xx | `HANDOFF_REQUIRED=privacy_policy_not_published` |
| 연결 실패 (`000`) | **검사 불가** — 통과도 실패도 아니다 |

**`-L` 이 없으면 게시된 방침이 미게시로 판정된다.** app-portal 은 Cloudflare Workers 정적
자산이라 트레일링 슬래시로 307 을 건다 — 실측(2026-09-20) privacy·terms·support 셋 다
307 → 200 이다. `app-portal` 을 쓰는 **모든 앱**이 해당한다(zen-koi #31).

`curl` 이 실패하면 `%{http_code}` 는 `000` 이다. 숫자 비교로만 짜면 "200 이 아니므로 미게시" 로
떨어진다 — **네트워크가 막힌 것과 방침이 없는 것은 처방이 다르다.**

**스크린샷 슬롯을 하드코딩하지 않는다.** brick-breaker 에서 6.5"(1284×2778)와 13"(2064×2752)를
받고 6.9"(1320×2868)는 받지 않는 것을 관찰했다.

> **정정(2026-09-20).** 이 자리에 "계정마다 다르다" 고 적혀 있었는데 **확인하지 않은 단정**이었다.
> 관찰한 것은 "brick-breaker 에서 슬롯이 그랬다" 뿐이고 **원인이 계정이라는 근거는 없었다.**
> zen-koi 가 짚었다 — Apple 규격은 **기기 지원 범위**로 요구 사항을 정한다(6.9" 또는 6.5" 필수,
> iPad 를 지원하면 13" 필수). 계정 축이 아닐 가능성이 높다.
>
> **어느 쪽인지는 여전히 확인되지 않았다.** 양쪽 다 한 계정씩만 봤다. 그래서 원인을 적지 않고
> **조회한다**는 결론만 남긴다 — 원인이 무엇이든 조회가 맞기 때문이다.
6.5" 는 iPhone 14 Plus 시뮬레이터로 찍는다 — 최신 기기 목록에 그 해상도가 없다.

### §4-2 스크린샷 알파 채널 게이트 — 시뮬레이터 캡처는 RGBA 다

Apple 규격이 명시한다.

> Images can't include alpha channels or transparencies.

`xcrun simctl io … screenshot` 은 **RGBA 로 내놓는다.** zen-koi 실측(2026-09-20)에서 6장 전부
RGBA 였다. **촬영 단계와 업로드 단계가 분리돼 있으면 촬영한 사람은 모르고 업로드에서야 막힌다.**

#### 떼기 전에 무손실인지 본다

`convert("RGB")` 를 그냥 하면 **투명한 곳이 검게 나온다.** 알파가 전부 255면 무손실이고,
아니면 배경색을 깔아야 한다 — 그건 사람이 정할 일이다.

```bash
# >>> iphone-release:screenshot-alpha >>>
# 스크린샷 알파 채널 게이트. 종료 코드 0=이상 없음 1=알파 있음 2=검사 불가.
# **"채널이 있다" 와 "투명 픽셀이 있다" 를 구별한다.** 전자는 떼면 되고 후자는 사람이
#   배경색을 정해야 한다 — 그냥 떼면 투명한 곳이 검게 나간다(zen-koi #40).
_SS_DIR="${1:-artifacts/app-store/screenshots}"
if [ ! -d "$_SS_DIR" ]; then
  echo "❌ 스크린샷 디렉터리가 없습니다: $_SS_DIR — 알파 채널을 판정할 수 없습니다."
  exit 2
fi

python3 - "$_SS_DIR" <<'PYEOF'
import sys, pathlib
try:
    from PIL import Image
except ImportError:
    print("❌ Pillow 가 없어 알파 채널을 확인하지 못했습니다 (pip install pillow).")
    print("   **이상 없음으로 보지 않습니다.**")
    raise SystemExit(2)

files = sorted(p for p in pathlib.Path(sys.argv[1]).glob("*.png"))
if not files:
    print(f"❌ {sys.argv[1]} 에 PNG 가 없습니다 — 판정할 수 없습니다.")
    raise SystemExit(2)

opaque, transparent, bad = [], [], []
for f in files:
    try:
        im = Image.open(f)
    except Exception as e:
        bad.append((f, e)); continue
    if "A" not in im.getbands():
        continue
    lo, hi = im.getchannel("A").getextrema()
    (opaque if lo == 255 else transparent).append((f, im.size, lo, hi))

if bad:
    for f, e in bad:
        print(f"❌ 열지 못함: {f.name} — {e}")
    print("   **판정할 수 없습니다.**")
    raise SystemExit(2)

for f, size, lo, hi in transparent:
    print(f"❌ 투명 픽셀 있음: {f.name} {size[0]}x{size[1]} alpha={lo}..{hi}")
for f, size, lo, hi in opaque:
    print(f"⚠️  알파 채널 있음(전부 불투명): {f.name} {size[0]}x{size[1]}")

if transparent:
    print("→ 배경색을 깔아야 합니다. **그냥 RGB 변환하면 투명한 곳이 검게 나갑니다.**")
    raise SystemExit(1)
if opaque:
    print(f"→ {len(opaque)}장의 채널 제거는 **무손실**입니다: im.convert('RGB')")
    raise SystemExit(1)
print(f"✅ 알파 채널 없음 ({len(files)}장)")
PYEOF
# <<< iphone-release:screenshot-alpha <<<
```

### §4-3 ASC 버전 일치 — 빌드가 안 붙는다

앱 레코드를 만들면 ASC 가 버전을 **`1.0` 으로** 만든다. `project.yml` 이 `1.0.0` 이면 다르다.

```
ASC appStoreVersions.versionString   1.0
ios/project.yml MARKETING_VERSION    1.0.0
```

**빌드는 같은 `CFBundleShortVersionString` 을 가진 버전에만 붙는다.** 그대로 두면 ipa 를 올려도
그 버전에 매달리지 않아 심사에 넣을 수 없다.

**`--export-only` 까지는 전혀 드러나지 않는다.** 아카이브도 내보내기도 ASC 를 보지 않는다.
드러나는 형태가 "빌드가 안 보인다" 라서 **엉뚱한 곳을 찾게 된다**(zen-koi #40).

```
같다      진행
다르다    HANDOFF_DECISION=asc_version_mismatch
          → ASC 버전을 PATCH 로 맞추거나(되돌릴 수 있다) project.yml 을 맞춘다
조회 실패  **검사 불가.** 일치한다고 가정하지 않는다
```

### §4-5 iPad 방향 경고 — **판정 기준을 모른다**

아카이브에서 이 경고가 난다.

```
warning: All interface orientations must be supported unless the app
         requires full screen.
```

iPad 를 지원하면서(`TARGETED_DEVICE_FAMILY: "1,2"`) 방향을 하나만 선언하면 나온다.
**빌드를 막지는 않는다.**

#### 확인된 것

`UIRequiresFullScreen` 은 **deprecated 다.** Apple 문서 실측(2026-09-20).

> **iOS 9.0–26.0 Deprecated**
> Opting out of iPad multitasking and dynamic resizing is deprecated. Use a combination of
> `UISceneSizeRestrictions` and `prefersInterfaceOrientationLocked` to replace some of the
> behaviors of `UIRequiresFullScreen`.
>
> Make updates to your app to handle multitasking and dynamic resizing, then **remove
> `UIRequiresFullScreen`** from your information property list.

**그러므로 경고를 없애려고 이 키를 넣지 않는다.** 지금 넣는 것은 deprecated 키를 새로 추가하는
것이다. 이전 iOS 를 위해 남겨야 하면 `UIRequiresFullScreenIgnoredStartingWithVersion` 으로
무시 시작 버전을 지정하라고 Apple 이 안내한다.

#### 확인하지 못한 것

**이 경고가 심사 반려 사유인지 확인하지 못했다.** Xcode 빌드 경고이고, App Review 가 이것을
근거로 반려하는지는 근거를 찾지 못했다. `prefersInterfaceOrientationLocked` 의 정확한 사용법도
문서 페이지를 열지 못해 확인하지 못했다.

**그래서 게이트를 만들지 않는다.** 판정 기준을 모르는 채로 게이트를 두면 통과·실패 둘 다
근거가 없다 — 이 레포가 반복해 고쳐 온 "확인 안 한 단정" 이 게이트 형태로 굳는 것이다.

```
경고가 난다            사실
UIRequiresFullScreen   deprecated — 새로 넣지 않는다
심사 반려 사유인가      **미확인**
대체 API 사용법        **미확인**
```

세로 고정이 의도한 설계라면 그대로 두고, **심사에 넣기 전에 사람이 결론을 낸다.**
결론이 나면 그때 §4 표에 행을 더한다.

### §4-4 업로드는 끝이 아니다 — `assetDeliveryState` 를 기다린다

`PATCH uploaded=true` 가 끝이 아니다. `assetDeliveryState.state` 가 `COMPLETE` 가 될 때까지
기다려야 하고 `errors` 가 실릴 수 있다.

**올렸다는 것과 쓸 수 있다는 것은 다르다** — §5-1 서명 게이트·§3-1 왕복 검증과 같은 축이다.

### 스크린샷은 광고 초기화를 기다린다

광고 SDK 초기화에 수 초 걸린다. **실행 직후 캡처하면 배너가 빠진 화면이 찍힌다.**
`/aiops:app-ads` §6-2 와 같은 대기 조건이 필요하다.

## §5 자격증명

```bash
python3 - <<'PY'
import sys; sys.path.insert(0, "${CLAUDE_PLUGIN_ROOT}/scripts")
import store_common as sc
from pathlib import Path
res = sc.kms_fetch(Path("<root>"), "<slug>", "APPSTORE_API_KEY_JSON",
                   required=("key_id", "issuer_id", "private_key"))
if not res.ok:
    print(res.handoff("appstore_api_key", "appstore_account"))
PY
```

`APPSTORE_API_KEY_JSON` 은 **조직 공용**(`scope=org`, `service=devworld`)이다.
앱 접두사 이름으로 찾히면 `legacy=True` 로 표시된다 — **이관 유예이지 대체 경로가 아니다.**

### KMS 가 막히면 브라우저로 확인한다 (설계 §2-6)

`not_found` 는 **미등록인지 권한 없음인지 구별하지 못한다.** 그러면 사람에게 무엇을 시켜야 할지도
모른다 — 계정을 만들라는 것과 키를 등록하라는 것은 다르다.

**Chrome 브라우저 도구로 1·2단계를 확인한다.** 내장 브라우저는 Google·Apple 세션이 없어
로그인 화면으로 떨어진다.

읽기 전용이다. 계정·키를 만들지 않고, 로그인하지 않으며, 끝나면 탭을 닫는다.
확인 결과를 `HANDOFF_VERIFY` 에 담는다.

```
HANDOFF_VERIFY=console:account+key / kms:not_found (APPSTORE_API_KEY_JSON@devworld · …)
```

확인하지 못했으면 `console:unverified (no session)` 로 남긴다.
**확인하지 않은 것을 확인된 것처럼 적지 않는다.**

## §6 빌드 → 내보내기 → 업로드

```bash
S="${CLAUDE_PLUGIN_ROOT}/scripts/appstore_upload.py"
python3 "$S" --slug <slug> --root <root> --dry-run       # 되돌릴 수 있음
python3 "$S" --slug <slug> --root <root> --archive-only  # 되돌릴 수 있음
python3 "$S" --slug <slug> --root <root> --export-only   # 되돌릴 수 있음
python3 "$S" --slug <slug> --root <root>                 # **업로드. 되돌릴 수 없음**
```

마지막 단계 **전에 사람 확인을 받는다.**

스크립트가 자동으로 처리하는 것:
- `.xcodeproj` 가 없으면 `xcodegen generate` 시도(생성물이라 클린 체크아웃에 없다)
- 버전 정본은 `project.yml`. `pbxproj` 와 **값이 갈리면 중단**한다
- ExportOptions 가 없으면 `destination=export` 로 생성. **있으면 덮어쓰지 않는다**

## §7 연령 3축 — 이 스킬이 다루는 둘

| 축 | App Store |
|---|---|
| 콘텐츠 등급 | `4+` · `9+` · `12+` · `17+` |
| 대상 연령층 | **대응물 없음** (Play 전용 개념) |
| 아동 대상 태그 | `/aiops:app-ads` 가 다룬다 |

**App Store 콘텐츠 등급은 개인화 광고와 무관하다.** Apple 쪽 개인화 차단은 Kids Category
선택과 ATT 다. 등급이 `4+` 라는 이유로 개인화를 끄지 않는다.

값은 **프로젝트 설정으로 받는다.** 등급을 올리는 것은 노출 범위를 줄이는 사업 결정이다.

**이 스킬은 법률 자문을 하지 않는다.** 출시 전 사람 확인을 §9 체크리스트에 둔다.

## §8 API 호출 3등급

| 등급 | 예 | 정책 |
|---|---|---|
| 1 조회 | 앱 존재·현재 버전·스크린샷 슬롯 | 자유 |
| 2 멱등 갱신 | 메타데이터·스크린샷·릴리즈 노트 | 자유 (다시 쓰면 덮어씀) |
| 3 **불가역** | 앱 레코드 생성 · **심사 제출** · 업로드 | **사람 확인 필수** |

**3등급 목록이 계약이다.** 새 API 를 쓸 때 어느 등급인지 먼저 판정한다.

## §9 사람이 해야 할 일 (보고에 반드시 포함)

- 개발자 계정 생성, ASC API 키 발급
- **DSA 거래자 전환** — 이메일 6자리 코드. 완료 전까지 EU 27개국에 노출되지 않는다
- 앱 레코드 생성 (이름·기본 언어·번들 ID)
- 심사 반려 대응
- **연령 등급·개인화 설정 법무 검토**

## §10 결과 보고

```
## 🍎 iOS 출시 결과 — <slug>
- 경로: 신규 | 업데이트     버전: <version> (빌드 <build>)  [출처: project.yml]
- 사전 점검: <통과/실패 항목>
- 진행 단계: dry-run | archive | export | upload | submit
- 자격증명: <name>@<service> (legacy 면 명시)
- HANDOFF: <남긴 마커. 없으면 "없음">
- 사람이 할 일: §9 목록 중 해당 항목
```

**불가역 단계를 실행했으면 그 사실을 맨 앞에 적는다.**

## 다른 스킬과의 관계

- 문서 4종은 [`/aiops:app-pages`](../app-pages/SKILL.md) — **배포가 이 스킬보다 먼저다**
- 광고·아이콘은 `/aiops:app-ads` · `/aiops:app-icon`
- 자격증명 조회는 `scripts/store_common.py`, 업로드는 `scripts/appstore_upload.py`
- Android 는 `/aiops:android-release`
