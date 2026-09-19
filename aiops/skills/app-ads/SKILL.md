---
name: app-ads
description: "모바일 앱에 AdMob 배너·전면 광고와 UMP 동의를 도입한다. Android(Gradle·Manifest·buildConfigField)와 iOS(Info.plist·XcodeGen·ATT) 빌드 설정을 함께 다루며, 실기동에서만 드러나는 실패 3건(InfoPlist.xcstrings 현지화·XcodeGen info.path 덮어쓰기·UMP 콘솔 번역)을 사전에 막는다. 광고 단위 ID 를 소스에 박지 않는다."
---

# /aiops:app-ads — 배너·전면 광고 + UMP 동의

AdMob 배너·전면 광고와 UMP(User Messaging Platform) 동의를 대상 레포에 도입한다.

**광고는 빌드 설정을 건드린다.** 코드만 넣고 끝나지 않으며, 설정이 어긋나면 **유닛 테스트는 통과하는데
실기동에서 죽는다.** §6 의 실패 3건이 그 사례다.

## 절대 원칙

1. **광고 단위 ID 를 소스에 박지 않는다.** Android 는 `buildConfigField`, iOS 는 xcconfig/Info.plist 로
   주입한다. 실 ID 는 KMS(`/aiops:kms`)에 둔다.
1-1. **절반만 써넣지 않는다.** 앱 ID 와 단위 ID 를 나눠 일부만 처리하면 나머지를 사람이 찾아 넣어야 하고,
   **앱 ID 를 빠뜨리면 빌드는 통과하고 실행 즉시 크래시한다.** §3·§4 의 대상 파일을 전부 채운다.
2. **개발 중에는 Google 테스트 ID 만 쓴다.** 실 ID 로 개발하면 계정이 정지될 수 있다.
   테스트 ID 가 릴리스 빌드에 남지 않는지 §7 에서 검증한다.
3. **동의 없이 광고를 띄우지 않는다.** UMP 동의 수집 → 완료 → 광고 초기화 순서다. 순서를 바꾸면
   EEA/UK 사용자에게 법적 문제가 된다.
4. **되돌리기 어려운 것은 사람이 한다.** AdMob 콘솔 설정, 앱 심사 제출, 스토어 등록 정보 변경은
   이 스킬이 하지 않는다 — 무엇을 해야 하는지 안내만 한다.

---

## §1 인자

```
/aiops:app-ads [--platform=<android|ios|all>] [--types=banner,interstitial] [--test-ids-only] [--dry-run]
```

기본값은 `--platform=all --types=banner,interstitial`. 리워드 광고는 범위 밖이다(요청 항목이 둘).

## §2 전제 확인 (생략 금지)

```bash
FRAMEWORK=$(jq -r '.agent_hints.mobile.framework // empty' .claude/config.json 2>/dev/null)
CAP_SDKS=$(jq -r '.agent_hints.mobile.capabilities.sdks // [] | join(",")' .claude/config.json 2>/dev/null)
CAP_PERMISSIONS=$(jq -r '.agent_hints.mobile.capabilities.permissions // [] | join(",")' .claude/config.json 2>/dev/null)
```

| 감지 결과 | 판단 |
|---|---|
| `sdks` 에 `admob` **없음** | 신규 도입 — §3 부터 전부 수행 |
| `sdks` 에 `admob` **있음** | 이미 도입됨 — **덮어쓰지 않는다.** 무엇이 빠졌는지 §7 로 점검만 하고 보고 |
| `sdks` 에 `ump` 없는데 `admob` 있음 | 동의 누락 — §5 만 수행 |
| `agent_hints.mobile` 자체가 없음 | `/aiops:setup` 을 먼저 돌린다. 여기서 중단 |

**이미 도입된 레포를 다시 도입하지 않는다.** 광고 코드는 초기화 지점이 중복되면 조용히 어긋난다.

## §2-1 대상 파일 (전부 채운다)

zen-koi 실측 기준이다. 경로는 레포 구조에 맞춰 바뀌지만 **항목은 빠지지 않아야 한다.**

| 플랫폼 | 파일 | 무엇을 |
|---|---|---|
| Android | `app/src/main/AndroidManifest.xml` | `meta-data` `com.google.android.gms.ads.APPLICATION_ID` |
| Android | `app/build.gradle.kts` | buildType 별 `buildConfigField` (배너·전면) |
| iOS | `<App>/Info.plist` | `GADApplicationIdentifier` |
| iOS | `<App>/Ads/AdUnits.swift` | `Live` enum (**`Test` enum 은 건드리지 않는다** — `#if DEBUG` 로 갈린다) |
| iOS | `<App>/Info.plist` | `SKAdNetworkItems` (미디에이션 추가 시 갱신) |

## §3 Android

### 의존성

`gradle/libs.versions.toml` 에 버전을 두고 모듈 `build.gradle.kts` 에서 참조한다
(버전을 모듈 파일에 직접 박는 레포라면 그 관례를 따른다 — 레포 관례가 이 스킬보다 우선한다).

```kotlin
implementation("com.google.android.gms:play-services-ads:<버전>")
implementation("com.google.android.ump:user-messaging-platform:<버전>")
```

### 앱 ID 와 광고 단위 ID

`AndroidManifest.xml` 에 **앱 ID**(광고 단위 ID 가 아니다):

```xml
<meta-data
    android:name="com.google.android.gms.ads.APPLICATION_ID"
    android:value="${admobAppId}" />
```

`${admobAppId}` 는 `build.gradle.kts` 의 `manifestPlaceholders` 로 주입한다. **광고 단위 ID** 는
`buildConfigField` 로 넣고 빌드 타입마다 다르게 한다.

```kotlin
android {
    buildFeatures { buildConfig = true }
    defaultConfig {
        manifestPlaceholders["admobAppId"] = providers.gradleProperty("ADMOB_APP_ID").getOrElse("<테스트 앱 ID>")
    }
    buildTypes {
        debug {
            buildConfigField("String", "AD_UNIT_BANNER", "\"ca-app-pub-3940256099942544/6300978111\"")
            buildConfigField("String", "AD_UNIT_INTERSTITIAL", "\"ca-app-pub-3940256099942544/1033173712\"")
        }
        release {
            buildConfigField("String", "AD_UNIT_BANNER", "\"${providers.gradleProperty("AD_UNIT_BANNER").get()}\"")
            buildConfigField("String", "AD_UNIT_INTERSTITIAL", "\"${providers.gradleProperty("AD_UNIT_INTERSTITIAL").get()}\"")
        }
    }
}
```

위 debug 값은 **Google 이 공개한 테스트 단위 ID** 다. release 는 `gradle.properties`(gitignore) 나
CI 시크릿에서 온다 — **레포에 커밋하지 않는다.**

### 권한

`com.google.android.gms.permission.AD_ID` 를 선언한다. Android 13+ 에서 광고 ID 접근에 필요하다.
Privacy Sandbox 를 쓰는 레포는 `ACCESS_ADSERVICES_*` 도 함께 선언된다.

**선언한 권한은 개인정보 처리방침에 반영되어야 한다.** 이 스킬이 권한을 추가하면
`/aiops:app-pages` 를 다시 돌려 문서를 갱신한다 — §8 에서 안내한다.

## §4 iOS

### 의존성

SPM(`Package.swift` 또는 Xcode 프로젝트의 패키지 의존성)으로 `GoogleMobileAds` 를 추가한다.
UMP 는 같은 SDK 에 포함된다.

### Info.plist

```xml
<key>GADApplicationIdentifier</key>
<string>ca-app-pub-XXXXXXXX~YYYYYYYY</string>
<key>NSUserTrackingUsageDescription</key>
<string>맞춤 광고를 제공하기 위해 사용합니다.</string>
<key>SKAdNetworkItems</key>
<array><dict><key>SKAdNetworkIdentifier</key><string>cstr6suwn9.skadnetwork</string></dict></array>
```

`SKAdNetworkItems` 는 Google 이 배포하는 목록 전체를 넣는다(위는 한 항목 예시).

### XcodeGen 을 쓰는 레포 — §6-(b) 를 반드시 읽는다

`project.yml` 에서 **`targets.<T>.info` 를 쓰지 않는다.** `settings.INFOPLIST_FILE` 로 연결만 한다.

```yaml
targets:
  MyApp:
    # info: 를 쓰지 않는다 — XcodeGen 이 Info.plist 를 생성해 손으로 쓴 키를 덮어쓴다.
    settings:
      base:
        INFOPLIST_FILE: MyApp/Info.plist
```

## §5 UMP 동의 — 광고보다 먼저

순서가 전부다.

```
앱 시작 → UMP 동의 정보 요청 → (필요하면) 동의 양식 표시 → 동의 완료
        → MobileAds 초기화 → 광고 로드
```

동의 완료 **전에** `MobileAds.initialize()` 를 부르지 않는다. iOS 는 ATT 요청도 이 흐름에 들어가며,
**ATT 는 UMP 동의 이후**에 띄우는 것이 Google 권장이다.

디버그 빌드에서는 `ConsentDebugSettings` 로 지역을 강제해 동의 화면을 재현할 수 있다.
**이 설정이 릴리스에 남지 않게 한다** — §7 에서 검증한다.

## §6 실기동에서만 드러나는 실패 3건

유닛 테스트로는 잡히지 않는다. zen-koi 실측 사례다.

### (a) iOS ATT 문구는 `InfoPlist.xcstrings` 로 따로 현지화한다

`NSUserTrackingUsageDescription` 은 **앱 문자열이 아니라 Info.plist 키**다.
`Localizable.xcstrings` 에 넣으면 현지화되지 않고 기본 언어로만 뜬다.
반드시 **`InfoPlist.xcstrings`** 에 별도로 넣는다. `CFBundleDisplayName` 도 같은 파일이다.

- **재현**: `Localizable.xcstrings` 에 전 언어를 넣고 `Info.plist` 의 ATT 문구를 영문으로 둔 채
  한국어 시뮬레이터로 첫 실행.
- **증상**: 앱 UI 는 한국어인데 **ATT 시스템 팝업의 설명 문구만 영어.**
- **확인**: `plutil -p <빌드>/*.app/ko.lproj/InfoPlist.strings`

### (b) XcodeGen 의 `info.path` 가 손으로 쓴 Info.plist 를 덮어쓴다

`targets.<T>.info.path` 를 쓰면 XcodeGen 이 Info.plist 를 **생성**한다 — 읽어서 합치는 것이 아니다.
`GADApplicationIdentifier` 와 `SKAdNetworkItems` **43개가 통째로 사라진다.**

- **재현**: `project.yml` 의 `targets.<T>.info.path` 에 손으로 쓴 Info.plist 경로를 지정하고 `xcodegen generate`.
- **증상**: **빌드는 성공하는데 실행 즉시 `GADInvalidInitializationException` 크래시.** CI 에서 안 잡힌다.
- **조치**: `info:` 를 쓰지 않고 `settings.base.INFOPLIST_FILE` 로만 연결한다.
- **확인**: `grep -c SKAdNetworkIdentifier <App>/Info.plist` 를 `xcodegen generate` **전후로 비교**한다.

### (c) UMP 동의 첫 화면은 AdMob 콘솔에서 번역한다

동의 양식의 첫 화면은 **앱 번들 문자열이 아니라 AdMob 콘솔에서 내려받는 원격 메시지**다.
**코드로 고칠 수 없다.**

- **재현**: 한국어 기기에서 앱 첫 실행, 동의가 필요한 지역.
- **증상**: ATT 팝업 직전의 "Our app wants to stay free for you" 화면만 영어.
- **조치**: AdMob 콘솔 → 개인정보 보호 및 메시지에서 언어 추가.

**이 스킬은 콘솔을 조작하지 않는다.** 사람이 해야 할 일로 §8 에 남긴다.

## §6-1 테스트 ID 게이트 (강제)

debug 빌드에 실 광고 ID 가 들어가면 **무효 트래픽으로 AdMob 계정이 정지될 수 있다.**
검사해서 통과하지 못하면 **실패시킨다** — 경고로 넘기지 않는다.

규칙: debug 경로(`debug` buildType · `#if DEBUG` 블록 · `Test` enum)에 `ca-app-pub-` 로 시작하되
게시자 ID 가 **`3940256099942544`(구글 공식 테스트 게시자 ID)가 아닌** 값이 있으면 실패.

### "검사 못 함" 과 "위반 없음" 을 구분한다

이 게이트에서 가장 위험한 실패는 위반을 놓치는 것이 아니라 **검사를 안 하고 통과하는 것**이다.

```
grep 이 실행되지 못함(경로가 틀림·글롭이 셸에서 전개됨)  → 종료 코드 1
위반이 없음(정상)                                        → 종료 코드 1
```

둘의 종료 코드가 같아서 `if grep ...; then 실패; fi` 형태는 구별하지 못한다. 글롭을 인용해도
**대상 파일이 0개면 똑같이 조용히 통과한다.** 그래서 대상 파일 수를 먼저 세고, 0개면 그 자체를
실패로 삼는다.

종료 코드는 이 레포의 E2E 규약(0/1/2)을 따른다.

| 코드 | 뜻 |
|---|---|
| 0 | 통과 — 검사를 수행했고 위반이 없다 |
| 1 | 위반 — debug 경로에 실 광고 ID |
| 2 | **검사 못 함** — 대상 파일 0개. 통과가 아니다 |

```bash
# >>> app-ads:id-gate >>>
# 광고 ID 게이트. 종료 코드 0=통과 1=위반 2=검사불가.
# 글롭은 반드시 인용한다 — 비인용이면 zsh 에서 "no matches found" 로 죽어 조용히 통과한다.
_ad_files() {
  find . \( -name node_modules -o -name .git -o -name build -o -name Pods -o -name DerivedData \) -prune -o \
    \( -name '*.kts' -o -name '*.gradle' -o -name '*.swift' \) -type f -print 2>/dev/null
}

_n=$(_ad_files | wc -l | tr -d ' ')
if [ "$_n" -eq 0 ]; then
  echo "❌ 검사 대상 파일이 0개 — 게이트를 수행하지 못했습니다(경로·레이아웃 확인)."
  exit 2
fi

# debug 경로에 구글 테스트 게시자 ID 가 아닌 광고 ID
_viol=$(_ad_files | xargs grep -n 'ca-app-pub-' 2>/dev/null \
        | grep -iE 'debug|test' | grep -v 'ca-app-pub-3940256099942544')
if [ -n "$_viol" ]; then
  printf '%s\n' "$_viol"
  echo "❌ debug 경로에 실 광고 ID — AdMob 계정 정지 위험"
  exit 1
fi

# 역방향 — release 경로에 테스트 ID 가 남으면 광고가 수익을 내지 못한다.
_rev=$(_ad_files | xargs grep -n 'ca-app-pub-3940256099942544' 2>/dev/null \
       | grep -iE 'release' )
if [ -n "$_rev" ]; then
  printf '%s\n' "$_rev"
  echo "❌ release 경로에 테스트 광고 ID — 수익이 발생하지 않습니다"
  exit 1
fi

echo "✅ 게이트 통과 (검사 파일 ${_n}개)"
# <<< app-ads:id-gate <<<
```

앵커 문자열은 `aiops/tests/app-ads-id-gate.test.sh` 의 추출 지점이므로 변경 금지.

**이 원칙은 다른 게이트에도 적용된다.** 검사를 수행했는지와 결과가 무엇인지는 서로 다른 축이다.
둘을 한 종료 코드에 섞으면 실패가 조용해진다.

## §6-2 광고 초기화는 수 초 걸린다

**실행 직후 스크린샷을 찍으면 배너가 없는 화면이 찍힌다.** 에뮬레이터 한계로 오판하기 쉬운 지점이다
(zen-koi 가 실제로 오판했다가 로그로 정정했다).

자동 검증·스크린샷 촬영에는 **초기화 완료를 기다리는 조건**이 필요하다.

```bash
adb logcat | grep Ads          # Android — 초기화·로드 로그 확인
```

`/aiops:run-mobile-e2e` 나 스토어 스크린샷 촬영에서도 같은 대기가 필요하다.

## §6-3 연령 관련 값은 세 축이고 서로 독립이다

**하나로 묶지 않는다.** 하나를 바꿨다고 나머지가 따라가면 스위치가 엉뚱한 곳에 생긴다.

| 축 | 값 | 어디에 |
|---|---|---|
| 콘텐츠 등급 | App Store `4+`·`9+`·`12+`·`17+` / Play IARC | 스토어 메타데이터 |
| 대상 연령층 | Play 버킷 (5세 미만·6-8·9-12·13-15·16-17·18+) | Play 전용 — **App Store 에 대응물 없음** |
| 아동 대상 태그 | AdMob `tagForChildDirectedTreatment` · `tagForUnderAgeOfConsent` | **앱 코드** — 이 스킬의 범위 |

이 스킬이 다루는 것은 **셋째 축뿐**이다. 앞의 둘은 스토어 스킬의 몫이다.

- **두 태그를 동시에 `true` 로 두지 않는다** (구글 지침).
- 일반 대상(13세 이상)이면 **둘 다 설정하지 않는 것**이 기본이다. zen-koi 가 그렇다.
- EEA·영국은 나이와 무관하게 **UMP 동의 결과가 개인화를 가른다** — 스킬이 판단할 일이 없다.
- 값은 **프로젝트 설정으로 받는다.** 기본값은 주되 고정하지 않는다.

> App Store 의 콘텐츠 등급은 개인화 광고와 **직접 관계가 없다.** Apple 쪽에서 개인화를 막는 것은
> Kids Category 선택과 ATT 다. 등급이 `4+` 라는 이유로 개인화를 끄지 않는다.

**연령 기준은 법역마다 다르다** — COPPA(미국) 13세, 개인정보보호법(한국) 14세, GDPR 동의 가능 연령
13~16세(국가별). 이 스킬은 **법률 자문을 하지 않는다.** 위 값은 설계 입력일 뿐이며,
출시 전 사람 확인을 §8 체크리스트에 넣는다.

## §7 검증

| 검사 | 방법 |
|---|---|
| 광고 ID 게이트 | §6-1 — 종료 코드 **0 통과 / 1 위반 / 2 검사불가**. 2 를 통과로 취급하지 않는다 |
| SKAdNetworkItems 보존 | `grep -c SKAdNetworkIdentifier` 를 xcodegen 전후 비교 |
| 광고 초기화 대기 | §6-2 — 스크린샷·E2E 전에 로그로 확인 |
| 실 ID 가 커밋되지 않음 | `git diff --cached` 에 `ca-app-pub-` 실 ID 없음 |
| `ConsentDebugSettings` 가 debug 전용 | 릴리스 빌드 경로에 없음 |
| iOS ATT 문구 현지화 | `InfoPlist.xcstrings` 에 `NSUserTrackingUsageDescription` 존재 |
| XcodeGen 덮어쓰기 없음 | `project.yml` 에 `info:` 없고 `INFOPLIST_FILE` 있음 |
| 빌드 후 plist 확인 | 빌드 산출물의 `Info.plist` 에 `GADApplicationIdentifier` 가 살아 있는지 |
| 감지 계층 갱신 | `/aiops:setup` 재실행 후 `sdks` 에 `admob`·`ump` 가 잡히는지 |

마지막 항목이 중요하다. **감지되지 않으면 `/aiops:app-pages` 가 광고 조항을 쓰지 못한다.**

실기동 확인은 `/aiops:run-mobile-e2e` 또는 시뮬레이터/에뮬레이터로 한다.
**빌드 성공은 검증이 아니다** — §6 의 셋 다 빌드는 통과한다.

## §8 사람이 해야 할 일 (보고에 반드시 포함)

- AdMob 콘솔에서 앱 등록 및 광고 단위 생성 → 실 ID 확보
- **UMP 개인정보 메시지의 언어 추가** (§6-(c))
- 실 ID 를 KMS 또는 CI 시크릿에 등록 (`/aiops:kms register`)
- `app-ads.txt` 를 개발자 웹사이트 루트에 게시 — app-portal 의 `public/app-ads.txt` 가 그 자리다
- 스토어 등록 정보의 개인정보 처리방침 URL 확인
- **연령 기준과 개인화 설정을 법무 검토** — 대상 국가의 동의 가능 연령 확인 (§6-3)

## §9 결과 보고

```
## 📢 광고 도입 결과
- 플랫폼: android | ios | all      유형: banner, interstitial
- 신규 도입 | 기존 확인(덮어쓰지 않음)
- Android: 의존성·manifestPlaceholders·buildConfigField·AD_ID 권한
- iOS: SPM·Info.plist·InfoPlist.xcstrings·(XcodeGen INFOPLIST_FILE)
- UMP: 동의 → 초기화 순서 적용
- 검증: §7 표 결과
- 사람이 할 일: §8 목록
- 문서 갱신 필요: /aiops:app-pages <slug> 재실행 (권한·SDK 가 늘었으므로)
```

## 다른 스킬과의 관계

- 도입 후 **반드시 `/aiops:setup` 을 다시 돌린다** — §20 감지 계층이 `admob`·`ump`·`tracking` 을
  잡아야 `/aiops:app-pages` 가 광고 조항을 근거 있게 쓴다.
- 실 ID 보관은 [`/aiops:kms`](../kms/SKILL.md).
- 아이콘은 `/aiops:app-icon`.
