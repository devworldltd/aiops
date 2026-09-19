# HANDOFF 마커 계약 v1

**사람이 해야 하는 일에 막혀 멈춘 상태**를 기계 판독 가능하게 표현하는 규약.

정본은 이 문서다. `/aiops:iphone-release`·`/aiops:android-release` 를 비롯해 사람 영역에 걸려
멈추는 모든 스킬이 이 계약을 따른다.

## 왜 필요한가

**완료 표시만 되고 실제로는 안 된 상태가 가장 위험하다.** 이 실패 모드는 런타임과 무관하다.

산문으로만 "여기서 멈추고 사람에게 넘긴다" 고 적으면 **멈췄는지 아닌지 아무도 판정할 수 없다.**
후속 단계가 앞 단계의 중단을 모르고 진행하는 것을 막으려면 기계가 읽을 수 있어야 한다.

## 마커

```
## ⏸️ 사람 확인 대기
HANDOFF_REQUIRED=<항목코드>      순수 사람 영역 — 스킬이 할 수 있는 것이 없다
HANDOFF_DECISION=<항목코드>      결정 대기 — 스킬이 선택지를 계산해 제시해야 한다
HANDOFF_ACCESS=<접근권한>        무엇에 접근할 수 있어야 하는가
HANDOFF_VERIFY=<확인코드>        완료를 어떻게 확인하는가

## ✅ 사람 확인 완료
HANDOFF_CLEARED=<항목코드>
```

앵커 고정 정규식: `^## ⏸️ 사람 확인 대기$` · `^## ✅ 사람 확인 완료$`

`⏸️` 와 `✅` 는 기존 마커 헤더(`🌐`·`❌`·`⚠️`·`ℹ️`·`🚀`·`🛑`)가 쓰지 않는다.

### REQUIRED 와 DECISION 을 나누는 이유

둘을 한 토큰으로 두면 **스킬의 의무가 사라진다.** "사람이 알아서 하세요" 로 끝내도 규약 위반이
아니게 되기 때문이다.

| | `HANDOFF_REQUIRED` | `HANDOFF_DECISION` |
|---|---|---|
| 스킬이 할 수 있는 것 | 없음 | **선택지를 계산해 제시해야 한다** |
| 재개 확인 | 사람 보고에 의존 | **기계적으로 확인 가능** |
| 예 | `dsa_trader_verification` | `app_name_conflict` · `age_rating_decision` |

게이트 차단 효과는 같다. 다른 것은 **스킬에 붙는 의무**다.

## 항목코드

`확인` 열은 재개 시 스킬이 **직접 확인할 수 있는지**를 뜻한다. 확인 불가 항목은 그 사실 자체를
기록한다 — **"확인했다고 함" 과 "확인됨" 은 다르다.**

### REQUIRED (순수 사람 영역)

| 항목코드 | 무엇 | 접근권한 | 확인 |
|---|---|---|---|
| `developer_account` | 개발자 계정 생성 | `appstore_account`·`play_console` | 불가 |
| `appstore_api_key` | ASC API 키 발급 | `appstore_account` | **가능** — KMS 에 `<APP>_APPSTORE_API_KEY_JSON` |
| `play_service_account` | Play 서비스 계정 발급 | `play_console` | **가능** — KMS 조회 |
| `android_keystore` | 업로드 키 생성·보관 | `kms` | **가능** — KMS 에 `ANDROID_KEYSTORE_BASE64` |
| `bundle_id_registration` | Apple Developer 번들 ID 최초 등록 | `appstore_account` | **가능** — ASC API |
| `signing_certificate` | 배포 인증서·프로비저닝 프로파일 | `appstore_account` | **가능** — ASC API |
| `dsa_trader_verification` | DSA 거래자 전환 (이메일 6자리 코드) | `mailbox:<주소>` | 불가 |
| `admob_eu_message` | AdMob 콘솔 유럽 규정 메시지 | `admob_console` | 불가 |
| `review_rejection` | 심사 반려 대응 | `appstore_account`·`play_console` | 불가 |
| `privacy_policy_not_published` | app-portal 배포 (스토어 등록보다 먼저) | — | **가능** — URL 200 |

> `android_keystore` 는 **분실 시 복구가 불가능**하다. 이 목록에서 가장 위험한 항목이다.

### DECISION (결정 대기 — 스킬이 선택지를 제시한다)

| 항목코드 | 스킬이 제시할 것 | 확인 |
|---|---|---|
| `app_name_conflict` | 가용한 대안 이름 목록 | **가능** — 스토어 가용성 |
| `age_rating_decision` | 콘텐츠 등급 · Play 대상 연령층 후보와 각각의 노출 범위 | **가능** — config 값 |
| `price_and_territories` | 가격 티어 · 배포 국가 후보 | **가능** — config 값 |
| `content_rights` | 근거와 함께 "타사 콘텐츠 없음" 제안 | **가능** — 사람 승인 기록 |

`content_rights` 는 스킬이 판정할 수 있지만 **법적 선언이라 사람 확정을 받는다.** 근거는 기계적이다
(에셋을 코드로 생성했고 광고는 Google 이 자기 계약으로 송출).

### 사람 영역이 아닌 것 (오분류 주의)

| | 왜 |
|---|---|
| 전화번호 국가 코드 | **입력 검증**이다. `+82` 형식 검증·자동 교정이 가능하다. 값 자체는 설정에서 받는다 |
| 스크린샷 슬롯 차이 | **스킬이 처리한다.** 하드코딩하면 계정이 바뀔 때 깨진다. ASC API 로 그 앱이 받는 슬롯을 조회한 뒤 필요한 해상도만 찍는다 |

## 접근권한 (`HANDOFF_ACCESS`)

**"누구" 가 아니라 "무엇에 접근할 수 있어야 하는가" 로 정의한다.** 소규모 조직에서는 계정 소유자·
콘솔 관리자가 실질적으로 같은 사람이라 역할 구분이 무의미하고, 받는 사람이 무엇을 해야 하는지
알기 어렵다.

```
appstore_account      App Store Connect 로그인
play_console          Play Console 로그인
admob_console         AdMob 콘솔
mailbox:<주소>        해당 메일함 확인
kms                   KMS 등록 권한
```

한 사람이 여러 권한을 겸해도 메시지가 정확하다.

## 게이트 규약

### 규약 1 — 해소 댓글은 REQUIRED·DECISION 토큰을 인용하지 않는다

`"HANDOFF_REQUIRED=dsa_trader_verification 를 해소했습니다"` 라고 적으면 그 문장에 grep 이 걸려
**영구 차단**된다. forge 에 댓글 삭제 기능이 없어 되돌릴 수 없다.

해소 댓글에는 `HANDOFF_CLEARED=<항목코드>` 만 적는다.

> 같은 함정을 `/aiops:merge-main` #49 에서 이미 겪었다. dry-run 마커를 차단 목록에 넣으면 사람이
> 확인용으로 한 번 돌린 순간 그 이슈가 영구 차단되므로 넣지 않기로 했다.

### 규약 2 — 개수로 판정한다

```
항목 X 에 대해  count(REQUIRED=X 또는 DECISION=X) > count(CLEARED=X)  이면 차단
```

댓글은 append-only 라 순서가 보존되고, 개수 비교가 재발생·재해소를 자연히 처리한다.
"마지막 것이 이긴다" 는 순서 파싱이 필요해 더 약하다.

### 규약 3 — 조회 실패는 통과가 아니다

댓글 조회가 `rc≠0` 이면 "중단 항목 없음" 이 아니라 **검사 못 함**으로 차단한다.
`/aiops:merge-main` 이 v1.14.2 에서 같은 원칙을 적용했다(사유 코드 `comments_fetch_failed`).

### 규약 4 — 확인은 산출물에서 한다, 보고에서 하지 않는다

재개 확인이 **가능한** 항목은 사람 말을 믿지 않고 직접 확인한다.

**"했다고 함" 과 "된 것이 반영됨" 은 다르다.** 실측 사례가 있다.

```
릴리스 → 소스 레포 갱신 → 플러그인 캐시 갱신 → 세션 재시작 → 실제 사용
```

zen-koi 가 2026-09-20 에 두 번째 단계까지 하고 그것을 "갱신했다" 로 알고 있었다. 플러그인이
`directory` 소스라 캐시가 설치 시점에 복사되고 소스 변경이 자동 반영되지 않았다. 세션은 계속
옛 버전을 로드했다.

따라서 확인은 **소스가 아니라 실제 로드되는 산출물**에서 한다.

```bash
grep -c 'maxdepth 6' <캐시경로>/skills/setup/SKILL.md    # 소스가 아니라 캐시를 본다
```

## 기존 마커와의 충돌 검토

`HANDOFF_` 접두사는 기존 판정 토큰(`E2E_RESULT=`·`PROD_RESULT=`·`E2E_ENV_ERROR=`) 어느 것도
부분 문자열로 포함하지 않고, 어느 것에도 포함되지 않는다.

v1.11.0 의 `PASS_DRY_RUN` 사례(앵커 없는 grep 에 기존 값이 부분 문자열로 걸림)는 재발하지 않는다.

**새 토큰을 추가할 때는 이 검토를 반복한다.** 기존 값이 부분 문자열로 포함되면 기존 게이트가
새 값에 걸린다.

## 계약 #1 과의 관계

이 마커들은 기계 판독 토큰이므로 **`aiops-codex` 통지 대상**이다. 계약 #1 에 따라 추가는 릴리스와
동시에, 변경·삭제는 릴리스 전에 통지한다.

## 합의 경위

- 2026-09-20 `aiops-codex` 채널 — 사람 영역을 계약이 아닌 공통 규약으로 두자는 제안에서 출발
- 2026-09-20 `aiops-v1` 이 기계 판독 가능해야 검사할 수 있다고 제안, 토큰 초안 제시
- 2026-09-20 `zen-koi` 가 항목코드 보강, REQUIRED/DECISION 분리, 접근권한 기준 제안 — 전부 반영
- 규약 4 는 `zen-koi` 가 캐시 미갱신을 실제로 겪고 공유한 내용에서 나왔다
