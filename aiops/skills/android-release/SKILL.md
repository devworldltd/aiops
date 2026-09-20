---
name: android-release
description: "Android 앱을 Google Play 트랙에 올린다 — 신규 출시와 업데이트 모두. AAB 빌드·업로드·트랙 반영·릴리즈 노트·Data safety 설문을 자동화하고, 사람만 할 수 있는 것(개발자 계정·서비스 계정 발급·AdMob 콘솔·심사 반려 대응)에서는 HANDOFF 마커를 남기고 멈춘다. 업로드 키 분실은 복구 불가다."
---

# /aiops:android-release — Google Play 출시

세션이 담당하는 앱 하나를 Google Play 에 올린다.

설계 정본은 [`docs/design/release-skills.md`](../../../docs/design/release-skills.md),
중단 상태 규약은 [`docs/contracts/handoff-marker.md`](../../../docs/contracts/handoff-marker.md) 다.

## 절대 원칙

1. **키스토어는 이 흐름에서 가장 위험한 항목이다.** 잘못된 키로 서명해 올리면 기존 등록의
   서명과 달라지고, **업로드가 거부될 때까지 드러나지 않는다.**
   분실 시 무엇이 복구되고 무엇이 안 되는지는 §3-1 에 적었다 — **조건부다.**
2. **불가역 단계를 격리한다.** 트랙 반영(`commit`)은 되돌릴 수 없다.
3. **판정 실패 시 신규로 가정하지 않는다.**
4. **사람 영역에서는 멈추고 마커를 남긴다.**
5. **확인할 수 있는 것은 확인한다**(계약 규약 4).

---

## §1 인자

```
/aiops:android-release <slug> [--root=<경로>] [--portal=<경로>]
                              [--track=internal|alpha|beta|production]
                              [--dry-run] [--no-notes]
```

기본 트랙은 `internal` 이다. **`production` 은 명시해야 한다** — 즉시 사용자에게 나간다.

`--dry-run` 은 편집 세션을 열었다 바로 버려 **아무것도 바꾸지 않고** 접근만 확인한다.

## §2 전제 확인 (생략 금지)

```bash
PLATFORM=$(jq -r '.agent_hints.platform // ""' .claude/config.json 2>/dev/null)
SIGNAL=$(jq -r '.agent_hints.platform_signal // "unknown"' .claude/config.json 2>/dev/null)
```

| 상태 | 처리 |
|---|---|
| `agent_hints.mobile` 없음 | `/aiops:setup` 을 먼저 돌린다. 여기서 중단 |
| `platform_signal` 이 `none (fallback)` | **감지가 돌았고 아무것도 못 찾았다.** 사람이 platform 을 확인 |
| `platform_signal` 이 `unknown` | **키 자체가 없다** — v1.16.1 이전 `/aiops:setup` 이 만든 config. 감지 실패가 아니라 **기록 부재**다. `/aiops:setup` 재실행으로 채워진다 |
| `framework` 에 `android-native` 없음 | 이 스킬 대상이 아니다 |

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

## §3 자격증명 — 범위가 둘로 갈린다

| 항목 | scope | service |
|---|---|---|
| `PLAY_SERVICE_ACCOUNT_JSON` | `org` | `devworld` |
| `ANDROID_KEYSTORE_BASE64` · `_PASSWORD` · `KEY_ALIAS` | `app` | `<슬러그>` |

**서비스 계정은 조직 공용이고 키스토어는 앱별이다.** 조직 공용을 앱별로 두면 키 교체 시
앱 수만큼 고쳐야 하고 일부만 갱신돼 조용히 갈린다. 키스토어는 반대로 앱마다 달라야 한다.

### §3-1 키스토어가 없으면 — 생성과 보관

`ANDROID_KEYSTORE_*` 가 `not_found` 이고 **이관할 사본도 없으면 신규 생성**이다.
org 항목(이관 대기)과 성격이 다르다.

**생성은 되돌릴 수 없는 결정이다.** 한 번 그 키로 올리면 이후 모든 업데이트가 같은 키를 요구한다.
**사람 확인 없이 만들지 않는다.**

#### 분실하면 실제로 무슨 일이 일어나는가

"복구 불가" 는 흔히 뭉뚱그려 말해지지만 **두 키가 다르다.**

| 키 | 누가 보관 | 분실 시 |
|---|---|---|
| **앱 서명 키** | Play App Signing 가입 시 **Google** | 개발자가 잃을 수 없다 |
| **업로드 키** | 개발자 | Play Console 에서 **재설정 요청 가능** |
| 앱 서명 키 (Play App Signing 미가입 레거시) | 개발자 | **복구 불가.** 그 앱은 영영 업데이트할 수 없다 |

2021년 8월 이후 신규 앱은 AAB 필수이며 **Play App Signing 에 자동 가입**된다.
따라서 새로 만드는 앱의 업로드 키는 **재설정이 가능하다** — 다만 지원 요청이고 즉시가 아니다.

> **이 표를 근거로 방심하지 않는다.** 재설정은 절차·대기·승인이 붙고, 그동안 업데이트가 막힌다.
> 그리고 **정책은 바뀐다** — 실제 상황에서는 Play Console 의 현재 안내를 확인한다.
> 레거시 앱(Play App Signing 미가입)이라면 마지막 행이 그대로 적용되며, 그때는 진짜로 끝이다.

#### 생성

```bash
# 사람 확인을 받은 뒤 실행한다. 비밀번호는 난수로 만들고 화면에 찍지 않는다.
KS="$(mktemp -d)/<slug>-upload.jks"
PW="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
ALIAS="<slug>-upload"

keytool -genkeypair -v \
  -keystore "$KS" -storetype PKCS12 \
  -keyalg RSA -keysize 4096 -sigalg SHA384withRSA -validity 10000 \
  -alias "$ALIAS" \
  -storepass "$PW" -keypass "$PW" \
  -dname "CN=<앱 이름>, O=<조직>, C=KR"
```

- `PKCS12` 를 쓴다. JKS 는 폐기 예정 형식이다
- **`-keysize 4096`.** 2048 은 관행적 하한일 뿐이다. 이 키는 27년을 쓰는 물건이고 교체가
  수월하지 않으므로 상한을 쓴다. zen-koi 가 RSA 4096 / SHA384withRSA 로 만들어
  Play 요건을 넘기는 것을 실측했다(2026-09-20)
- `-validity 10000`(약 27년). **Play 는 업로드 키에 충분히 긴 유효기간을 요구한다**
  (2033-10-22 이후 만료). 만료되면 그 키로 더 올릴 수 없다
- `storepass` 와 `keypass` 를 같게 둔다. PKCS12 는 분리를 지원하지 않는다

#### KMS 등록 — 3종을 함께

```
ZEN_KOI_ANDROID_KEYSTORE_BASE64      base64 -i "$KS"
ZEN_KOI_ANDROID_KEYSTORE_PASSWORD    $PW
ZEN_KOI_ANDROID_KEY_ALIAS            $ALIAS
```

`scope=app` 이므로 **`service=<슬러그>`** 다(§3 표). 등록 절차는
[`/aiops:kms`](../kms/SKILL.md) `register` 를 따른다.

**세 개가 한 벌이다.** 하나라도 빠지면 서명할 수 없고, 그 사실은 빌드가 아니라 **업로드에서**
드러난다.

#### 등록했다고 복원되는 것은 아니다 — 왕복 검증

계약 규약 4 를 그대로 적용한다. **"등록했다" 와 "다시 꺼내 쓸 수 있다" 는 다르다.**

```bash
# 지문만 비교한다 — 값은 출력하지 않는다.
# keytool 출력은 **로케일에 따라 레이블이 다르다**("SHA256:" · "인증서 지문" …).
# 레이블을 잡지 말고 32바이트 16진 패턴을 잡는다(SHA-1 은 20바이트라 걸리지 않는다).
fp() {
  keytool -list -v -keystore "$1" -storepass "$2" 2>/dev/null \
    | grep -oE '[0-9A-F]{2}(:[0-9A-F]{2}){31}' | head -1
}

F1="$(fp "$KS" "$PW")"                                   # 원본
# KMS 에서 받은 base64 를 복원해 같은 함수를 돌린다
printf '%s' "$FROM_KMS" | base64 -d > "$TMP/restored.jks"
F2="$(fp "$TMP/restored.jks" "$PW")"

[ -n "$F1" ] && [ "$F1" = "$F2" ] || { echo "❌ 왕복 실패 — 이 키로 서명하지 않는다"; exit 1; }
```

지문이 다르면 **base64 인코딩·개행·문자 집합 어디선가 깨진 것**이다. 서비스 계정 JSON 과 같은
부류의 함정이다(§3 값 형식). **왕복이 확인되기 전에는 그 키로 서명하지 않는다.**

> `F1` 이 비어 있는 경우도 실패로 본다. 지문을 못 읽은 것과 지문이 같은 것은 다르다 —
> `grep` 이 아무것도 못 잡았을 때 `[ "$F1" = "$F2" ]` 는 빈 문자열끼리 비교해 **참이 된다.**
> 이 스킬 계열에서 반복해 확인한 "검사 못 함 ≠ 통과" 가 여기에도 적용된다.

#### 원본 파일 처리

```bash
shred -u "$KS" 2>/dev/null || rm -P "$KS"     # GNU 가 없으면 rm -P
```

**키스토어 파일을 레포에 두지 않는다.** `signingConfigs` 는 KMS → 환경변수로 주입하고,
`.gitignore` 에 `*.jks` · `*.keystore` 가 있는지 확인한다.

#### 사람이 확인할 것

- 생성 여부 자체 (되돌릴 수 없다)
- `dname` 의 조직·국가 표기
- 유효기간이 충분한지
- **왕복 검증 결과** — 지문이 같다는 것을 사람이 본다

`HANDOFF_REQUIRED=android_keystore` · `HANDOFF_ACCESS=kms` 로 멈추고,
`HANDOFF_VERIFY` 에 조회한 이름과 service 를 남긴다.

### 값 형식 — JSON 원문 그대로다

Play 서비스 계정은 **base64 가 아니라 JSON 원문 텍스트**로 보관한다.
스크립트가 reveal 응답의 `.value` 를 **한 번 더 `json.loads`** 한다.
KMS 가 객체로 파싱해 중첩시키거나 `private_key` 의 `\n` 을 정규화하면 거기서 깨진다.

### 1·2순위에 값이 둘 다 있으면 조용히 고르지 않는다

```
지문이 같다    1순위 사용 + duplicate=identical 로 보고
지문이 다르다  duplicate_conflict 로 중단 → HANDOFF_DECISION=keystore_conflict
```

지문은 SHA-256 앞 8자다. **값을 노출하지 않고 같은지만 비교**한다.
키스토어에서 이 판정이 가장 중요하다(§절대 원칙 1).

### KMS 가 막히면 브라우저로 확인한다 (설계 §2-6)

`not_found` 는 미등록인지 권한 없음인지 구별하지 못한다. **Chrome 브라우저 도구**로
Play Console 개발자 계정과 서비스 계정 존재를 확인한다.

| 확인 | URL |
|---|---|
| 개발자 계정 | `play.google.com/console/developers` |
| 서비스 계정 | `…/developers/<id>/users-and-permissions` — `@….iam.gserviceaccount.com` |
| 키 생성 여부 | `console.cloud.google.com/iam-admin/serviceaccounts?project=<프로젝트>` |

읽기 전용이다. 만들지 않고, 로그인하지 않으며, 끝나면 탭을 닫는다.

> **GCP 에 키가 있다고 JSON 파일을 가지고 있다는 뜻은 아니다.** 비공개 부분은 생성 시점에
> 한 번만 내려받을 수 있다. 그때 저장하지 않았으면 새 키를 만들어야 한다.

## §4 신규 출시와 업데이트 판정

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/play_upload.py" --slug <slug> --root <root> --portal <app-portal> --dry-run
```

| 결과 | 판정 |
|---|---|
| 편집 세션이 열림 | **업데이트** — 버전 코드 증가, 변경된 것만 |
| HTTP 404 | **신규** — Play Console 에 앱 레코드가 없다 |
| HTTP 401 | 인증 실패 — 서비스 계정 키 확인 |
| HTTP 403 | 권한 없음 — 앱 권한 또는 API 사용 설정 |
| 그 밖의 실패 | **중단.** 신규로 가정하지 않는다 |

앱 레코드 생성은 이 스킬이 하지 않는다. `HANDOFF_REQUIRED=app_record` 를 남기고 멈추고,
[`/aiops:app-record`](../app-record/SKILL.md) 로 넘긴다 — **Play Console 에 생성 API 가 없어**
브라우저가 유일한 길이다.

## §5 사전 점검

| 점검 | 방법 | 실패 시 |
|---|---|---|
| 개인정보처리방침 URL | §5-1 게이트 — **리다이렉트를 따라간** 최종 상태 | `HANDOFF_REQUIRED=privacy_policy_not_published` |
| AAB 존재 | `build/outputs/bundle/release/*.aab` | `./gradlew bundleRelease` 안내 |
| **AAB 서명** | §5-1 게이트 — `META-INF/*.RSA` | 중단. 업로드하지 않는다 |
| 앱 이름 가용성 | Play Console 조회 | `HANDOFF_DECISION=app_name_conflict` |
| 대상 연령층 | config 값 | `HANDOFF_DECISION=age_rating_decision` |
| 가격·배포 국가 | config 값 | `HANDOFF_DECISION=price_and_territories` |
| AdMob 유럽 규정 메시지 | 확인 불가 | `HANDOFF_REQUIRED=admob_eu_message` |

**`--portal` 을 빠뜨리면 릴리즈 노트가 만들어지지 않는다.** `release_notes()` 가 즉시 빠져나가고,
v1.20.0 까지는 그것이 `ℹ️` 한 줄로만 나와 **노트 없는 AAB 가 성공으로 올라갔다**(zen-koi #33).
지금은 종료 코드 2 로 멈춘다 — 노트 없이 올리려면 `--no-notes` 를 **명시**해야 한다.

**AdMob 유럽 규정 메시지가 없으면 릴리스 빌드에서 EEA 동의 폼이 뜨지 않는다.**
콘솔에서만 만들 수 있어 이 스킬이 할 수 없다.

### §5-1 서명 게이트 — 빌드 성공은 서명의 증거가 아니다

`build.gradle.kts` 가 `keystore.properties` → 환경변수 순으로 읽고 **둘 다 없으면 서명 없이
빌드되는** 구조가 흔하다(zen-koi·pong 실측). 새 클론이나 CI 의 일반 작업에서도 빌드는 되어야
하므로 일부러 그렇게 둔 것이다.

즉 **`bundleRelease` 가 성공해도 서명되지 않았을 수 있다.** 파일 존재만 보는 점검은 그 경우를
통과시킨다. 서명 없는 AAB 는 업로드가 거부되므로 불가역 사고는 아니지만, 실패가 자격증명
조회·릴리즈 노트·편집 세션 개설을 **다 지나서** 나온다. 앞으로 당긴다.

```bash
# >>> android-release:signing-gate >>>
# AAB 서명 게이트. 종료 코드 0=서명됨 1=서명 없음 2=검사불가.
# **"열지 못했다" 를 "서명 없음" 으로 판정하지 않는다** — 그 둘은 다른 처방이 필요하다.
_sig_aab="${1:-}"
if [ -z "$_sig_aab" ]; then
  # 글롭은 인용한다 — 비인용이면 zsh 에서 "no matches found" 로 죽어 게이트가 사라진다.
  _sig_aab=$(find . -path '*/build/outputs/bundle/release/*.aab' -type f 2>/dev/null | head -1)
fi
if [ -z "$_sig_aab" ] || [ ! -f "$_sig_aab" ]; then
  echo "❌ AAB 를 찾지 못했습니다 — ./gradlew bundleRelease 를 먼저 실행하세요."
  exit 2
fi

command -v unzip >/dev/null 2>&1 || {
  echo "❌ unzip 이 없어 서명을 확인하지 못했습니다(검사 불가)."; exit 2; }

_sig_list=$(unzip -Z1 "$_sig_aab" 2>/dev/null)
_sig_rc=$?
if [ "$_sig_rc" -ne 0 ] || [ -z "$_sig_list" ]; then
  echo "❌ AAB 를 열지 못했습니다(손상·zip 아님) — 서명 여부를 판정할 수 없습니다: $_sig_aab"
  exit 2
fi

_sig_hit=$(printf '%s\n' "$_sig_list" | grep -E '^META-INF/[^/]+\.(RSA|DSA|EC)$')
if [ -z "$_sig_hit" ]; then
  echo "❌ 서명 블록이 없습니다 — 서명되지 않은 AAB: $_sig_aab"
  echo "   keystore.properties 도 서명 환경변수도 없으면 Gradle 은 조용히 서명 없이 빌드합니다."
  exit 1
fi

printf '%s\n' "$_sig_hit"
echo "✅ 서명 확인 (AAB 항목 $(printf '%s\n' "$_sig_list" | wc -l | tr -d ' ')개)"
# <<< android-release:signing-gate <<<
```

**종료 코드 2 를 0 으로 뭉개지 않는다.** AAB 를 열지 못한 것과 서명이 확인된 것은 다르다 —
이 구분이 §3-1 왕복 검증·`app-ads` 광고 ID 게이트와 같은 규약이다.

> 서명 여부만 본다. **어느 키로 서명됐는지는 보지 않는다.** 그것은 Play 업로드가 거부로
> 알려 주며, 여기서 판정하려면 업로드 키 인증서가 필요하다(§3-1).


### §5-1 개인정보처리방침 점검 — 리다이렉트를 따라간다

```bash
# >>> release:privacy-check >>>
# 개인정보처리방침 게시 점검. 종료 코드 0=게시됨 1=미게시 2=검사 불가.
# **-L 이 없으면 게시된 방침이 미게시로 판정된다.** app-portal 은 Cloudflare Workers
#   정적 자산이라 트레일링 슬래시로 307 을 건다 — 실측(2026-09-20) privacy·terms·support
#   셋 다 307 → 200 이다. 200 만 보면 app-portal 을 쓰는 **모든 앱**이 걸린다(zen-koi #31).
_PRIV_URL="${1:?사용: privacy-check <url>}"
_PRIV_OUT=$(curl -sL --max-time 15 -o /dev/null -w '%{http_code} %{url_effective}' "$_PRIV_URL" 2>/dev/null)
_PRIV_RC=$?
_PRIV_CODE=${_PRIV_OUT%% *}
_PRIV_FINAL=${_PRIV_OUT#* }

# curl 이 실패하면 %{http_code} 는 000 이다. 숫자 비교로만 짜면 "200 이 아니므로 미게시" 로
#   떨어진다 — **네트워크가 막힌 것과 방침이 없는 것은 처방이 다르다.**
if [ "$_PRIV_RC" -ne 0 ] || [ "$_PRIV_CODE" = "000" ] || [ -z "$_PRIV_CODE" ]; then
  echo "❌ 방침 URL 에 접근하지 못했습니다(curl rc=$_PRIV_RC code=${_PRIV_CODE:-없음}) — 게시 여부를 판정할 수 없습니다."
  echo "   네트워크·DNS·프록시를 확인하세요. **미게시로 단정하지 않습니다.**"
  exit 2
fi

case "$_PRIV_CODE" in
  2??)
    echo "✅ 방침 게시 확인 (HTTP $_PRIV_CODE)"
    # 최종 URL 을 반드시 남긴다 — 도메인 오타·와일드카드 폴백이 엉뚱한 페이지로 리다이렉트돼
    #   200 으로 통과하는 것을 사람이 볼 수 있어야 한다.
    echo "   최종 URL: $_PRIV_FINAL"
    [ "$_PRIV_FINAL" != "$_PRIV_URL" ] && echo "   (리다이렉트됨 — 요청: $_PRIV_URL)"
    exit 0 ;;
  *)
    echo "❌ 방침이 게시되지 않았습니다 (HTTP $_PRIV_CODE, 최종 $_PRIV_FINAL)"
    exit 1 ;;
esac
# <<< release:privacy-check <<<
```

| 실제 상태 | 판정 |
|---|---|
| 307 → 200 | 통과. **최종 URL 을 보고에 남긴다** |
| 200 | 통과 |
| 404 · 5xx | `HANDOFF_REQUIRED=privacy_policy_not_published` |
| 연결 실패 (`000`) | **검사 불가** — 통과도 실패도 아니다 |


## §6 릴리즈 노트

`app-portal` 의 `content/<slug>/releases.json` 에서 읽는다 — **`/aiops:app-pages` 가 만드는
그 파일**이다. 정본이 하나로 이어진다.

`platforms.android` 가 채워진 최신 릴리스의 `changes` 를 쓴다.
`--portal` 로 경로를 준다. 없으면 노트 없이 진행하고 그 사실을 보고한다.

## §7 업로드 — 불가역 경계

```bash
S="${CLAUDE_PLUGIN_ROOT}/scripts/play_upload.py"
python3 "$S" --slug <slug> --root <root> --portal <app-portal> --dry-run         # 되돌릴 수 있음
python3 "$S" --slug <slug> --root <root> --portal <app-portal> --track internal  # **트랙 반영. 되돌릴 수 없음**
```

`commit` 전에 **사람 확인을 받는다.** `--track production` 은 즉시 사용자에게 나간다.

## §8 연령 3축 — 이 스킬이 다루는 둘

| 축 | Play |
|---|---|
| 콘텐츠 등급 | IARC 설문 |
| 대상 연령층 | 5세 미만 · 6-8 · 9-12 · **13-15** · 16-17 · 18+ |
| 아동 대상 태그 | `/aiops:app-ads` 가 다룬다 |

**14+ 버킷이 없다.** 한국 개인정보보호법의 14세 기준과 어긋나는 회색지대다 —
`13-15` 를 포함해 13세 이상으로 가거나 `16-17` 부터 시작하거나 둘 중 하나다.

13세 미만을 포함하지 않으면 Families 정책 대상이 아니므로 개인화 광고가 가능하다.
**EEA·영국은 나이와 무관하게 UMP 동의 결과가 개인화를 가른다.**

값은 프로젝트 설정으로 받는다. **이 스킬은 법률 자문을 하지 않는다.**

## §9 API 호출 3등급

| 등급 | 예 | 정책 |
|---|---|---|
| 1 조회 | 앱 존재·현재 버전 코드 | 자유 |
| 2 멱등 갱신 | 메타데이터·스크린샷·릴리즈 노트·AAB 업로드 | 자유 |
| 3 **불가역** | `edits.commit()` · 트랙 반영 | **사람 확인 필수** |

AAB 업로드 자체는 편집 세션 안이라 `commit` 전에는 되돌릴 수 있다 — 세션을 버리면 된다.
**`commit` 이 경계다.**

## §10 사람이 해야 할 일 (보고에 반드시 포함)

- 개발자 계정 생성, 서비스 계정 발급 + Play Console 권한 부여
- **업로드 키 생성·보관** (§3-1) — 생성은 되돌릴 수 없다. 왕복 검증까지 확인
- **AdMob 콘솔 유럽 규정 메시지 생성**
- 앱 레코드 생성, 심사 반려 대응
- **연령 등급·개인화 설정 법무 검토**

## §11 결과 보고

```
## 🤖 Android 출시 결과 — <slug>
- 경로: 신규 | 업데이트     트랙: <track>     versionCode: <n>
- 사전 점검: <통과/실패 항목>
- 자격증명: <name>@<service> (legacy·duplicate 면 명시)
- 릴리즈 노트: <있음/없음 + 출처>
- HANDOFF: <남긴 마커. 없으면 "없음">
- 사람이 할 일: §10 목록 중 해당 항목
```

**`commit` 을 실행했으면 그 사실을 맨 앞에 적는다.**

## 다른 스킬과의 관계

- 문서 4종은 [`/aiops:app-pages`](../app-pages/SKILL.md) — **배포가 이 스킬보다 먼저다**
- 광고·아이콘은 `/aiops:app-ads` · `/aiops:app-icon`
- 자격증명 조회는 `scripts/store_common.py`, 업로드는 `scripts/play_upload.py`
- iOS 는 `/aiops:iphone-release`
