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
5. **스크린샷 슬롯을 하드코딩하지 않는다.** 계정마다 다르다 — ASC API 로 조회한다.

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
| `platform_signal` 이 `none (fallback)` | **감지가 아무것도 찾지 못했다.** 사람 확인을 받고 진행 |
| `framework` 에 `ios-native` 없음 | 이 스킬 대상이 아니다 |

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

앱 레코드 생성은 이 스킬이 하지 않는다 — **사람이 App Store Connect 에서 만든다.**
`HANDOFF_REQUIRED=app_record` 를 남기고 멈춘다. 자동화 가능하지만 되돌릴 수 없고,
이름·기본 언어·번들 ID 가 한 번 정해지면 바꾸기 어렵다.

## §4 사전 점검 — 출시 도중이 아니라 여기서 드러나야 한다

brick-breaker 실측(2026-09-19)에서 막힌 것들이다.

| 점검 | 방법 | 실패 시 |
|---|---|---|
| 개인정보처리방침 URL | `app.devworld.co.kr/<slug>/privacy` 가 200 | `HANDOFF_REQUIRED=privacy_policy_not_published` |
| 앱 이름 가용성 | ASC API 조회 | `HANDOFF_DECISION=app_name_conflict` — **대안을 계산해 제시한다** |
| 전화번호 형식 | `+82` 등 국가 코드 포함 | **입력 검증** — 자동 교정. 사람 영역이 아니다 |
| 수출 규정 | `Info.plist` 에 `ITSAppUsesNonExemptEncryption=false` | 스킬이 추가 |
| 콘텐츠 권한 | 에셋 생성 방식·광고 송출 주체로 판정 | `HANDOFF_DECISION=content_rights` — 근거와 함께 제안 |
| 스크린샷 슬롯 | **ASC API 로 조회** | 필요한 해상도만 촬영 |
| DSA 거래자 전환 | 확인 불가 | `HANDOFF_REQUIRED=dsa_trader_verification` |
| 연령 등급 | config 값 | `HANDOFF_DECISION=age_rating_decision` |

**개인정보처리방침 URL 이 404 면 반려된다.** app-portal 배포가 스토어 등록보다 먼저다 —
`/aiops:app-pages` 로 문서를 만들고 사람이 배포한 뒤에 여기로 온다.

**스크린샷 슬롯은 계정마다 다르다.** brick-breaker 계정은 6.5"(1284×2778)와 13"(2064×2752)를
받고 6.9"(1320×2868)는 받지 않았다. **하드코딩하면 계정이 바뀔 때 깨진다.**
6.5" 는 iPhone 14 Plus 시뮬레이터로 찍는다 — 최신 기기 목록에 그 해상도가 없다.

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
