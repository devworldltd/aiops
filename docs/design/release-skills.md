# `/aiops:iphone-release` · `/aiops:android-release` 설계

zen-koi 요청(ai-chat, 2026-09-20). 세션이 담당하는 앱 하나를 스토어에 올리는 전 과정.
신규 출시와 업데이트를 모두 다루고, **스토어 계정 로그인을 제외한 나머지를 자동화**한다.

> **상태: 전제 확정.** 착수를 막던 넷이 모두 정리됐다(2026-09-20, zen-koi 답신).
> HANDOFF 계약은 v1.15.0 에 들어갔다. 남은 것은 §2-4 의 시크릿 이름 규칙 결정과 구현이다.

## §1 입력 — 이미 있는 것

| 자산 | 위치 | 확인 |
|---|---|---|
| 감지 계층 (권한·SDK·언어) | `/aiops:setup` §20 | **확인됨** — v1.14.1+ |
| 문서 4종 | `/aiops:app-pages` → app-portal | **확인됨** — zen-koi 등재(`2ac064e`) |
| 광고 + UMP | `/aiops:app-ads` | **확인됨** |
| 아이콘 | `/aiops:app-icon` | **확인됨** |
| 중단 상태 | HANDOFF 계약 v1 | **확정** — v1.15.0, `docs/contracts/handoff-marker.md` |
| 업로드 자동화 | `ScanBarcode/scripts/` | **일반화 필요** — §2 참조 |
| 스크린샷 자산 | `brick-breaker/artifacts/` | **확인됨** — 명명 규약대로 존재 |

## §2 업로드 경로 — 확정 사항

요청에는 "`appstore_upload.py` · `play_upload.py` 가 있으면 스토어 로그인 없이 업로드가 이미
성립한다" 고 적혀 있었다. 실측 결과 그대로 쓸 수 없었고, zen-koi 와 정리해 아래로 확정했다.

### 2-1. 스크립트를 일반화한다 (안 A 확정)

두 스크립트는 ScanBarcode 전용이다. 레포 전수 검색 결과 **복사본이 없다**.

```python
SECRET_NAME       = "SCANBARCODE_APPSTORE_API_KEY_JSON"
SECRET_SERVICE    = "scanbarcode"
SECRET_ENV        = "prod"
BUNDLE_ID         = "kr.co.devworld.ScanBarcode"
PROJECT           = ROOT / "ScanBarcode.xcodeproj"
SCHEME            = "ScanBarcode"
EXPORT_OPTIONS    = ROOT / "AppStore/ExportOptions-AppStore.plist"
DEFAULT_ARCHIVE   = ROOT / "build/ScanBarcode.xcarchive"
DEFAULT_EXPORT_DIR= ROOT / "build/export"
```

`play_upload.py` 는 `SECRET_NAME`·`SECRET_SERVICE`·`SECRET_ENV`·`PACKAGE_NAME`·`DEFAULT_AAB` 다섯이다.

**안 A(일반화)로 확정.** 안 B(앱마다 복사)는 사본이 갈라지는 문제를 다시 만든다.

역할 분담과 순서도 정해졌다.

```
1. aiops 가 일반화본 제공
2. zen-koi 가 첫 소비자로 검증   ← 아직 어느 스토어에도 안 올라간 유일한 앱
3. ScanBarcode 역이식            ← zen-koi 가 맡는다. 별도 건이며 급하지 않다
```

2번을 3번보다 먼저 두는 이유는 **검증되지 않은 일반화본으로 이미 출시된 앱을 건드리지 않기 위해서**다.

### 2-2. ASC API 키가 표준이다. Xcode 계정은 폴백이었다

`brick-breaker` 가 Xcode 계정으로 업로드한 것은 선택이 아니었다. 그 레포 문서 §3-3-2 의 제목이
**"원래 계획 (API 키 방식)"** 이고 §3-4 에 이렇게 적혀 있다.

> API 키를 KMS 에 넣은 뒤 ScanBarcode 의 `scripts/appstore_upload.py` 를 이 레포에 맞춰 가져오면
> 아카이브부터 업로드까지 자동화된다. **그 전에는** Xcode Organizer 나 Transporter 로 올린다.

**키가 KMS 에 없어서 폴백한 것**이다. 팀 권한 문제나 의도적 선택이 아니다.

| 경로 | 로그인 | 자동화 | 처리 |
|---|---|---|---|
| ASC API 키 | 불필요 | 완전 | **기본** |
| Xcode 계정 | **필요** | 부분 | 폴백. `HANDOFF_REQUIRED=appstore_api_key` 를 남긴다 |

폴백으로 갈 때 HANDOFF 마커를 남기는 이유는 **"스토어 로그인 제외" 가 깨진 사실이 기록되게**
하기 위해서다. 조용히 폴백하면 목표가 지켜졌는지 알 수 없다.

### 2-3. KMS 조회는 토큰 스코프에 좌우된다

"pong 만 등록되어 있다" 를 확인하려 했으나 이 작업의 토큰으로는 0건이었다. **가시성 한계였다.**
zen-koi 토큰으로는 보인다.

```
PONG_APPSTORE_API_KEY_JSON   service=pong   env=prod    ← 존재
ANDROID_KEYSTORE_BASE64      service=pong   env=prod
ANDROID_KEYSTORE_PASSWORD    service=pong   env=prod
ANDROID_KEY_ALIAS            service=pong   env=prod
```

**`play_service_account` 는 양쪽 토큰 모두 0건이다 — 실제 부재로 보인다.** zen-koi 토큰이 pong 의
다른 스토어 자격증명은 전부 보는데 play 것만 없기 때문이다.
`/aiops:android-release` 첫 실행은 `HANDOFF_REQUIRED=play_service_account` 로 멈춘다.
**HANDOFF 계약이 실제로 쓰이는 첫 사례가 될 예정이다.**

조회 결과 해석은 다음 셋을 구별한다.

| 상황 | 구별 방법 | 처리 |
|---|---|---|
| 토큰 자체가 없음 | `KMS_TOKEN` 미설정 | 환경 문제. HANDOFF 이전에 중단 |
| 0건 | HTTP 200 + 빈 items | **미등록과 권한 없음을 구별할 수 없다.** 둘 다 차단 |
| 조회 실패 | `rc≠0` | 규약 3 — 검사 못 함. 차단 |

0건일 때 미등록인지 권한 없음인지 **구별할 방법이 없다.** 둘 다 HTTP 200 에 빈 items 로 온다.

### 2-4. 시크릿 이름 규칙 — 결정 필요

현재 두 패턴이 섞여 있다.

```
PONG_APPSTORE_API_KEY_JSON    service=pong    ← 앱 접두사 있음
ANDROID_KEYSTORE_BASE64       service=pong    ← 접두사 없음. service 로만 구분
```

그리고 **하이픈 슬러그의 대문자 변환 규칙이 없다.** `zen-koi` → `ZEN_KOI` 인지 `ZEN-KOI` 인지
정해진 바가 없다. 기존 사례가 `pong`·`scanbarcode`(하이픈 없음)뿐이라 답이 나오지 않는다.

**확정**: service 는 슬러그 그대로, `SECRET_NAME` 은 하이픈을 언더스코어로 바꾼 대문자 접두사.

```
service     = zen-koi                          슬러그 그대로 (하이픈 유지)
SECRET_NAME = ZEN_KOI_APPSTORE_API_KEY_JSON    하이픈 → 언더스코어, 대문자
```

| 슬러그 | service | SECRET_NAME 접두사 |
|---|---|---|
| `pong` | `pong` | `PONG_` |
| `zen-koi` | `zen-koi` | `ZEN_KOI_` |
| `brick-breaker` | `brick-breaker` | `BRICK_BREAKER_` |
| `scanbarcode` | `scanbarcode` | `SCANBARCODE_` |

### 조회는 두 번 시도한다 — 기존 것을 깨지 않기 위해

기존 무접두사 이름(`ANDROID_KEYSTORE_BASE64` 등)이 이미 등록돼 있다. 새 규칙으로만 찾으면
pong 이 깨진다.

```
1순위  <접두사><종류>  + service=<슬러그>     예: ZEN_KOI_APPSTORE_API_KEY_JSON
2순위  <종류>          + service=<슬러그>     예: ANDROID_KEYSTORE_BASE64
```

둘 다 0건이면 **미등록과 권한 없음을 구별할 수 없으므로 차단한다**(§2-3).
2순위로 찾았으면 그 사실을 보고에 남긴다 — 옛 규칙으로 등록된 것이며 언젠가 옮겨야 한다.

**새로 등록하는 것은 1순위 형식만 쓴다.** 혼재를 늘리지 않는다.

## §2-5 일반화 인터페이스 — 레포마다 어긋나는 네 가지

zen-koi 로 대조해 드러난 것들이다. **인자만 받아서는 해결되지 않는다.**

### (1) `.xcodeproj` 가 아예 없을 수 있다

```
ScanBarcode : ROOT/ScanBarcode.xcodeproj    레포에 커밋됨
zen-koi     : ios/ZenKoi.xcodeproj          .gitignore 됨 — XcodeGen 생성물
```

클린 체크아웃에서는 `xcodegen generate` 를 먼저 돌려야 존재한다.
**"없으면 생성 시도 → 그래도 없으면 중단"** 이 필요하다.

### (2) 버전 정본이 `pbxproj` 가 아니다 — 조용히 틀리는 지점

`appstore_upload.py` 는 `project.pbxproj` 에서 `MARKETING_VERSION` 을 읽는다. zen-koi 의 pbxproj 는
**생성물**이고 정본은 `project.yml` 이다.

`project.yml` 을 고치고 `generate` 를 안 했으면 **옛 버전으로 업로드된다. 빌드는 성공하고 스토어에
잘못된 버전이 올라간다.**

XcodeGen 을 쓰는 레포에서는 `project.yml` 을 읽거나, 최소한 **`pbxproj` 가 `project.yml` 보다
오래됐으면 중단**한다.

### (3) ExportOptions plist 가 레포마다 다르거나 없다

```
ScanBarcode   : AppStore/ExportOptions-AppStore.plist
brick-breaker : artifacts/app-store/uploadOptions.plist
zen-koi       : 없음
```

경로만 인자로 받으면 zen-koi 는 돌지 않는다. **없으면 스킬이 생성한다** — 내용이 정형적이다
(`method`·`teamID`·`destination: upload`).

### (4) `KMS_TOKEN` 이 레포 안에 없다

```
/Users/devworld/src/game/.envrc      ← KMS_TOKEN
/Users/devworld/src/game/zen-koi/    ← 레포. .envrc 없음
```

레포의 `.envrc` 만 찾으면 못 찾는다. **상위로 거슬러 올라가는 탐색**이 필요하고, 못 찾으면
"토큰 없음" 으로 중단한다(§2-3 표의 첫 행).

## §3 신규 출시와 업데이트 판정

세션이 어느 쪽인지 **스스로 판정한다.** 스토어에 기존 레코드가 있는지로 갈리며 API 로 확인된다.

| | 신규 | 업데이트 |
|---|---|---|
| 앱 레코드 | 생성 (**불가역**) | 있음 |
| 메타데이터 | 전량 | 변경분만 |
| 설문 | 전량 | 변경 시에만 |
| 스크린샷 | 전량 | 변경분만 |
| 빌드 | 첫 빌드 | 버전 증가 |

판정 실패 시 **신규로 가정하지 않는다.** 신규 경로는 앱 레코드를 만들고 이는 되돌릴 수 없다.
조회가 실패하면 중단한다(§5 등급 3).

## §4 사전 점검 — brick-breaker 실측 8가지

출시 시도 전에 검사한다. 실패는 출시 도중이 아니라 **여기서** 드러나야 한다.

| 점검 | 방법 | 실패 시 |
|---|---|---|
| 개인정보처리방침 URL | `app.devworld.co.kr/<slug>/privacy` 가 200 | `privacy_policy_not_published` |
| 앱 이름 가용성 | 스토어 조회 | `app_name_conflict` (DECISION) |
| 전화번호 형식 | `+82` 등 국가 코드 포함 | **입력 검증** — 자동 교정 |
| 수출 규정 | `Info.plist` 에 `ITSAppUsesNonExemptEncryption=false` | 스킬이 추가 |
| 콘텐츠 권한 | 에셋 생성 방식·광고 송출 주체로 판정 | `content_rights` (DECISION) |
| 스크린샷 슬롯 | **ASC API 로 조회** — 하드코딩 금지 | 필요한 해상도만 촬영 |
| DSA 거래자 전환 | 확인 불가 | `dsa_trader_verification` |
| AdMob 유럽 메시지 | 확인 불가 | `admob_eu_message` |

스크린샷 슬롯이 계정마다 다르다는 것이 실측이다 — brick-breaker 계정은 6.5"(1284×2778)와
13"(2064×2752)를 받고 6.9"(1320×2868)는 받지 않았다. **하드코딩하면 계정이 바뀔 때 깨진다.**

6.5" 는 iPhone 14 Plus 시뮬레이터로 찍어야 한다. 최신 기기 목록에 그 해상도가 없다.

## §5 API 호출 3등급

`aiops-codex` 채널에서 합의 중인 분류. **실행 정책이 계약이다** — 스키마만 맞추고 정책을 각자
정하면 한쪽 런타임만 심사를 제출한다.

| 등급 | 예 | 정책 |
|---|---|---|
| 1 조회 | 앱 레코드 존재, 현재 버전, 스크린샷 슬롯 | 자유 |
| 2 멱등 갱신 | 메타데이터·스크린샷·릴리즈 노트 등록 | 자유 (다시 쓰면 덮어씀) |
| 3 **불가역** | 앱 레코드 생성, **심사 제출**, 트랙 반영 | **사람 확인 필수** |

3등급 목록 자체가 계약이다. 새 API 를 쓸 때 어느 등급인지 판정하는 기준도 함께 둔다.

## §6 연령 3축 — 스토어 쪽 두 축

`/aiops:app-ads` 가 셋째 축(TFCD/TFUA)을 다룬다. 이 스킬은 앞의 둘을 다룬다.

| 축 | App Store | Play |
|---|---|---|
| 콘텐츠 등급 | `4+`·`9+`·`12+`·`17+` | IARC 설문 |
| 대상 연령층 | **대응물 없음** | 5세 미만·6-8·9-12·13-15·16-17·18+ |

**Play 에 14+ 버킷이 없다.** 한국 개인정보보호법의 14세 기준과 어긋나는 회색지대다.

**App Store 콘텐츠 등급은 개인화 광고와 무관하다.** Kids Category 선택과 ATT 가 가른다.
등급이 `4+` 라는 이유로 개인화를 끄지 않는다.

값은 **프로젝트 설정으로 받는다**(`age_rating_decision` DECISION). 등급을 올리는 것은 노출 범위를
줄이는 사업 결정이다.

**이 스킬은 법률 자문을 하지 않는다.** 출시 전 사람 확인을 체크리스트에 둔다.

## §7 자동화 경계

| 가능 (API 자격증명으로 로그인 없이) | 사람 영역 |
|---|---|
| 빌드·아카이브·서명, AAB/IPA 생성 | 개발자 계정 생성, API 키 발급 |
| 시뮬레이터 스크린샷 촬영 | DSA 거래자 전환 (이메일 6자리) |
| 바이너리 업로드 | AdMob 콘솔 유럽 규정 메시지 |
| 메타데이터·스크린샷·릴리즈 노트 등록 | 심사 반려 대응 |
| 연령 등급 선언, 개인정보 설문 | |

**경계를 흐리지 않는다.** 불가능한 항목은 HANDOFF 마커로 "여기서 멈추고 사람에게 넘긴다" 를
기계 판독 가능하게 남긴다. 완료 표시만 되고 실제로는 안 된 상태가 가장 위험하다.

계약은 `docs/contracts/handoff-marker.md`(v1.15.0)다. 이 스킬이 **첫 소비자**다.

| 상황 | 마커 |
|---|---|
| ASC API 키 없음 → Xcode 폴백 | `HANDOFF_REQUIRED=appstore_api_key` + `HANDOFF_ACCESS=appstore_account` |
| Play 서비스 계정 없음 | `HANDOFF_REQUIRED=play_service_account` + `HANDOFF_ACCESS=play_console` |
| 앱 이름 중복 | `HANDOFF_DECISION=app_name_conflict` — **대안 목록을 계산해 제시한다** |
| 연령 등급 미정 | `HANDOFF_DECISION=age_rating_decision` |
| DSA 거래자 전환 | `HANDOFF_REQUIRED=dsa_trader_verification` + `HANDOFF_ACCESS=mailbox:<주소>` |

`HANDOFF_VERIFY` 가 가능한 항목은 재개 시 **직접 확인한다** — KMS 조회(§2-3 의 셋 구별을 지킨다),
`app.devworld.co.kr/<slug>/privacy` 200, ASC API, config 값.

### 스크린샷은 광고 초기화를 기다린다

광고 SDK 초기화에 수 초 걸린다. 실행 직후 캡처하면 **배너가 빠진 화면이 찍힌다.**
`/aiops:app-ads` §6-2 와 같은 대기 조건이 필요하다(`adb logcat | grep Ads`).

## §8 구현 순서

전제는 모두 확정됐다. §2-1 의 합의 순서를 따른다.

| | 단계 | 담당 |
|---|---|---|
| 1 | 업로드 스크립트 일반화본 제공 — §2-5 의 네 가지를 인터페이스에 반영 | aiops |
| 2 | `/aiops:iphone-release` · `/aiops:android-release` 작성 | aiops |
| 3 | zen-koi 로 첫 검증 (어느 스토어에도 안 올라간 유일한 앱) | zen-koi |
| 4 | ScanBarcode 역이식 — 별도 건, 급하지 않다 | zen-koi |

1번이 2번의 입력이다. 스킬이 감싸는 대상이 없으면 스킬을 쓸 수 없다.
