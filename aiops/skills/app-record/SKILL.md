---
name: app-record
description: "스토어에 앱 레코드를 만든다 — Play Console 과 App Store Connect 둘 다 **웹 콘솔이 유일한 길**이므로 Chrome 브라우저 도구로 생성한다. 앱 이름·기본 언어·패키지명을 레포에서 읽어 근거와 함께 제안하고 사람이 승인한 뒤에만 만든다. 로그인하지 않고, 삭제하지 않고, 출시하지 않는다."
---

# /aiops:app-record — 스토어 앱 레코드 생성

`android-release` · `iphone-release` 가 `HANDOFF_REQUIRED=app_record` 로 멈추는 지점을 넘긴다.
**계정 발급·키 발급과 달리 이건 신규 앱마다 매번 필요하다.**

설계 정본은 [`docs/design/release-skills.md`](../../../docs/design/release-skills.md),
중단 상태 규약은 [`docs/contracts/handoff-marker.md`](../../../docs/contracts/handoff-marker.md) 다.

## 절대 원칙

1. **로그인하지 않는다.** 사용자의 Chrome 세션을 쓴다. 세션이 없으면 **거기서 멈추고 알린다** —
   자격증명을 입력하지 않는다.
2. **사람이 승인하기 전에 만들지 않는다.** 생성은 되돌릴 수 없는 축을 하나 포함한다(§4).
3. **삭제하지 않는다.** 잘못 만든 레코드의 정리는 사람 몫이다.
4. **출시하지 않는다.** 이 스킬은 레코드만 만든다. 업로드·트랙 반영은
   `android-release` · `iphone-release` 가 한다.
5. **확인할 수 있는 것은 확인한다**(계약 규약 4). 만들었다는 것과 쓸 수 있다는 것은 다르다(§7).

---

## §1 인자

```
/aiops:app-record <slug> [--root=<경로>] [--platform=android|ios|both]
                         [--dry-run]
```

기본 `--platform` 은 `both` 다. `--dry-run` 은 §3~§5 까지만 하고 **아무것도 만들지 않는다.**

## §2 전제 확인 (생략 금지)

```bash
PLATFORM=$(jq -r '.agent_hints.platform // ""' .claude/config.json 2>/dev/null)
SIGNAL=$(jq -r '.agent_hints.platform_signal // "unknown"' .claude/config.json 2>/dev/null)
```

| 상태 | 처리 |
|---|---|
| `agent_hints.mobile` 없음 | `/aiops:setup` 을 먼저 돌린다. 여기서 중단 |
| `platform_signal` 이 `none (fallback)` | **감지가 돌았고 아무것도 못 찾았다.** 사람이 platform 을 확인 |
| `platform_signal` 이 `unknown` | **키 자체가 없다** — v1.16.1 이전 config. `/aiops:setup` 재실행으로 채워진다 |

> 세 상태를 구별한다. `android-release` §2 와 같은 규약이다.

## §3 입력 — 레포에서 읽어 제안한다, 백지에서 묻지 않는다

**세 값 모두 레포에 근거가 있다.** 백지에서 물으면 사람이 레포와 다른 값을 적어 넣고,
그 불일치는 업로드에서야 드러난다.

```bash
# >>> app-record:extract >>>
# 앱 레코드 입력값 추출. 종료 코드 0=추출됨 1=플랫폼 간 불일치 2=추출 불가.
# **못 읽은 것을 빈 값으로 넘기지 않는다** — 빈 값이 그대로 스토어에 들어간다.
_AR_ROOT="${1:-.}"

# 패키지명 — 양 플랫폼이 일치해야 한다. 불일치 자체가 경고감이다.
_AR_AND_PKG=$(grep -rhoE 'applicationId[[:space:]]*=?[[:space:]]*"[^"]+"' \
    "$_AR_ROOT/android" 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')

# **테스트 타깃의 번들 ID 를 집지 않는다.** project.yml 에는 보통 여럿이 있고
#   `<앱>.tests` 가 먼저 나올 수 있다 — zen-koi 실측에서 실제로 둘이 잡혔다.
#   앱 타깃의 ID 는 다른 ID 들의 **접두사**라는 성질을 쓴다(가장 짧은 것).
_AR_IOS_PKG=$(grep -rhoE 'PRODUCT_BUNDLE_IDENTIFIER:[[:space:]]*[A-Za-z0-9._-]+' \
    "$_AR_ROOT/ios/project.yml" 2>/dev/null | sed 's/.*:[[:space:]]*//' \
    | grep -viE '\.(tests?|uitests?)$' | awk '{print length, $0}' | sort -n | head -1 | cut -d' ' -f2-)

# 앱 이름 — 스토어 표시명과 다를 수 있다. 제안일 뿐이다.
# **기본 로케일만 읽는다.** `values-zh` · `values-ja` 까지 훑으면 번역본을 집는다 —
#   zen-koi 실측에서 `禅鲤`(중국어)가 나왔다. 기본값은 접미사 없는 `values/` 다.
_AR_NAME=$(grep -rhoE '<string name="app_name">[^<]+</string>' \
    "$_AR_ROOT"/android/*/src/main/res/values/strings.xml \
    "$_AR_ROOT"/android/src/main/res/values/strings.xml 2>/dev/null \
    | head -1 | sed 's/.*>\(.*\)<.*/\1/')

# 언어 목록 — **그중 무엇이 기본인지는 코드가 정하지 못한다.** 사람이 고른다(§5).
_AR_LANGS=$(grep -rhoE 'resourceConfigurations[^)]*' "$_AR_ROOT/android" 2>/dev/null \
    | head -1 | grep -oE '"[a-zA-Z-]+"' | tr -d '"' | tr '\n' ' ')

if [ -z "$_AR_AND_PKG" ] && [ -z "$_AR_IOS_PKG" ]; then
  echo "❌ 패키지명/번들 ID 를 어느 쪽에서도 읽지 못했습니다 — 경로·레이아웃을 확인하세요."
  echo "   **빈 값으로 진행하지 않습니다.** 빈 값은 그대로 스토어에 들어갑니다."
  exit 2
fi

if [ -n "$_AR_AND_PKG" ] && [ -n "$_AR_IOS_PKG" ] && [ "$_AR_AND_PKG" != "$_AR_IOS_PKG" ]; then
  echo "❌ 플랫폼 간 식별자 불일치 — 사람이 판단해야 합니다."
  echo "   android: $_AR_AND_PKG"
  echo "   ios    : $_AR_IOS_PKG"
  exit 1
fi

echo "패키지명: ${_AR_AND_PKG:-$_AR_IOS_PKG}"
echo "앱 이름  : ${_AR_NAME:-(못 읽음 — 사람에게 묻는다)}"
echo "언어 목록: ${_AR_LANGS:-(못 읽음)}"
# <<< app-record:extract <<<
```

| 값 | 근거 | 스킬이 정할 수 있나 |
|---|---|---|
| 패키지명 · 번들 ID | `applicationId` · `PRODUCT_BUNDLE_IDENTIFIER` | 읽어서 제안. **바꾸지 않는다** |
| 앱 이름 | `app_name` · `CFBundleDisplayName` | 제안만 — **스토어 표시명은 다를 수 있다** |
| 기본 언어 | `resourceConfigurations` · `sourceLanguage` | **정하지 못한다.** 목록만 알 수 있다 |

**기본 언어가 실제로 물어야 하는 것이다.** 조직 소재지와 소스 언어가 서로 다른 근거를 주는 일이
흔하다(zen-koi: 한국 조직 · `sourceLanguage=en`). 코드가 고르면 둘 중 하나를 말없이 버린다.

## §4 되돌릴 수 있는 것과 없는 것 — 하나뿐이다

**"신중히 정하세요" 로 뭉뚱그리지 않는다.** Play Console 문서 실측(2026-09-20)이다.

| 값 | 나중에 바꿀 수 있나 | 근거 |
|---|---|---|
| **패키지명 · 번들 ID** | **불가.** 삭제도 재사용도 안 된다 | Play: "고유하고 영구적… 나중에 삭제하거나 다시 사용할 수 없습니다" |
| 기본 언어 | 가능 | Play: "이는 나중에 변경할 수 있습니다" |
| 스토어 앱 이름 | 가능 | 위와 같은 문장 |
| 앱/게임 구분 | 가능 | Play: "이는 나중에 변경할 수 있습니다" |

**되돌릴 수 없는 것은 패키지명 하나다.** 확인을 강하게 걸 지점도 거기다 — 나머지 셋에 같은 무게를
실으면 정작 중요한 한 줄이 묻힌다.

> iOS 는 생성 **이후**가 다르다. ASC API `Modify an app` 이 **번들 ID 와 기본 언어까지** 고칠 수
> 있다. Android 패키지명은 영구다. **비대칭은 생성이 아니라 생성 이후에 있다.**

## §5 확인 — 한 화면에 모아 승인받는다

```
앱 이름     Zen Koi
패키지명    kr.co.devworld.zenkoi     ← **변경 불가**
기본 언어   한국어 / English          ← 골라 주세요
앱 유형     게임 · 무료
→  이대로 만들까요?
```

`HANDOFF_DECISION=app_record` 로 선택지를 제시한다. **승인 없이 §6 으로 가지 않는다.**

`--dry-run` 은 여기서 끝난다.

## §6 생성 — 양쪽 다 웹 콘솔이 유일한 길이다

**App Store Connect API 로는 앱을 만들 수 없다.** Apple 공식 문서가 명시한다.

> Don't use this API to create new apps; instead, create new apps on the App Store Connect website.

`apps` 리소스는 **이미 있는 앱을 읽고 고치는 용도**다. 따라서 두 플랫폼의 처방이 같다 —
**Chrome 브라우저 도구**를 쓴다.

| 플랫폼 | 경로 |
|---|---|
| Android | `play.google.com/console` → 모든 앱 → 앱 만들기 |
| iOS | `appstoreconnect.apple.com/apps` → `+` → 신규 앱 |

### 로그인하지 않는다

세션이 없으면 로그인 화면이 뜬다. **거기서 멈춘다.**

```
HANDOFF_REQUIRED=store_console_session
HANDOFF_ACCESS=browser
```

자격증명을 입력하지 않는다. 사용자가 Chrome 에서 직접 로그인한 뒤 다시 부른다.

### 만들기 전에 읽는다

- 같은 패키지명의 레코드가 이미 있는가 — 있으면 **생성이 아니라 그것을 쓴다**
- 앱 이름이 중복인가 — 중복이면 `HANDOFF_DECISION=app_name_conflict`

읽기는 되돌릴 수 있다. **먼저 읽고 나서 만든다.**

### 선언 항목은 사람이 체크한다

Play 의 '개발자 프로그램 정책' · '미국 수출 법규' 선언과 Play 앱 서명 약관 동의는
**법적 선언**이다. 스킬이 대신 체크하지 않는다 — 화면을 사람에게 보여주고 멈춘다.

## §7 검증 — 만들었다는 것과 쓸 수 있다는 것은 다르다

계약 규약 4 를 적용한다. **콘솔에 보이는 것으로 끝내지 않는다.**

```bash
# Android — 지금까지 404 나던 편집 세션이 열리면 레코드가 생긴 것이다.
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/play_upload.py" --slug <slug> --root <root> \
        --portal <app-portal> --dry-run
```

| 결과 | 판정 |
|---|---|
| 편집 세션이 열림 | ✅ 레코드 생성 확인. `HANDOFF_CLEARED=app_record` |
| HTTP 404 | ❌ 아직 없다 — 콘솔에서 저장이 안 됐을 수 있다 |
| HTTP 403 | 레코드는 있으나 **서비스 계정에 이 앱 권한이 없다** — 별개 문제다 |
| 그 밖의 실패 | **검사 불가.** 생성됐다고 단정하지 않는다 |

**404 와 403 을 구별한다.** 403 은 레코드가 있다는 증거이지 없다는 증거가 아니다.

iOS 는 ASC API `List apps` 로 번들 ID 를 조회해 확인한다. 생성은 못 해도 **읽기는 된다.**

## §8 자동화 경계

| 한다 | 하지 않는다 |
|---|---|
| 레코드 생성 (§5 승인 후) | **앱 삭제** |
| 읽기 — 이름 중복·기존 레코드 확인 | **패키지명 변경 시도** |
| 생성 결과 검증 (§7) | 가격·배포 국가 확정 |
| | 프로덕션 트랙 출시 |
| | **로그인** |

## §9 사람이 해야 할 일 (보고에 반드시 포함)

- 개발자 계정 생성 (이 스킬의 전제다)
- **기본 언어 선택** — 코드가 정할 수 없다(§3)
- **정책·수출 법규 선언과 앱 서명 약관 동의** — 법적 선언이다
- Chrome 로그인
- 잘못 만든 레코드의 정리

## §10 결과 보고

```
## 🏷️ 앱 레코드 생성 결과 — <slug>
- 플랫폼: <android|ios|both>
- 패키지명: <값>  (변경 불가)
- 앱 이름: <값> / 기본 언어: <값>
- 생성: <생성함 | 이미 있었음 | 중단(사유)>
- 검증: <편집 세션 열림 | 404 | 403 | 검사 불가>
- 남은 마커: <HANDOFF_* 또는 없음>
```

## 다른 스킬과의 관계

- [`/aiops:android-release`](../android-release/SKILL.md) · [`/aiops:iphone-release`](../iphone-release/SKILL.md) 가
  `HANDOFF_REQUIRED=app_record` 로 멈추면 이 스킬을 부른다. 끝나면 그쪽으로 돌아간다.
- §2 전제 확인과 `platform_signal` 세 상태 판정은 두 출시 스킬과 같은 규약을 쓴다.
