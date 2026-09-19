---
name: app-pages
description: "앱 법적 문서·지원 페이지 4종(개인정보 처리방침·이용약관·릴리즈 노트·support)을 app-portal 입력 JSON 으로 생성한다. 대상 레포의 권한·SDK·지원 언어를 /aiops:setup §20 감지 계층에서 읽어 근거로 삼는다. 페이지 HTML 을 직접 쓰지 않고 content/<slug>/*.json 과 apps.json 항목을 만든다. 배포는 하지 않는다."
---

# /aiops:app-pages — 앱 문서 4종 생성

`app.devworld.co.kr`(레포 `devworld-ltd/app-portal`)에 올릴 앱 문서를 만든다.

**이 스킬은 페이지를 만들지 않는다. 입력 JSON 을 만든다.** app-portal 에 이미 생성기가 있다.

```
content/<slug>/privacy.json     ← 이 스킬이 생성
content/<slug>/terms.json       ← 이 스킬이 생성
content/<slug>/releases.json    ← 이 스킬이 생성
content/apps.json 에 {slug,name,badge,summary} 한 항목 추가
        ↓ python3 scripts/generate_site.py
public/<slug>/{privacy,terms,releases}/index.html   (생성물 — 절대 손대지 않는다)

public/<slug>/support/index.html   ← 생성 대상이 아니다. 이 스킬이 손으로 쓴다.
public/_headers 에 /<slug>/releases.json 캐시 규칙 한 줄   ← 손으로 추가
```

## 절대 원칙

1. **`public/` 아래 생성물을 고치지 않는다.** `support/index.html` 과 `_headers` 만 예외다 — 생성기가 만들지 않는 둘뿐이다.
2. **배포하지 않는다.** `npx wrangler deploy` 는 실제 사이트를 바꾼다. 산출물을 만든 뒤 **명령을 안내만** 하고 실행은 사람에게 맡긴다.
3. **법적 문서는 그 앱이 실제로 하는 동작만 적는다.** 다른 앱 문서를 복사하지 않는다 — 없는 권한(카메라 등)이 섞여 들어간다. 근거는 §2 의 감지 결과다.
4. **감지되지 않은 것을 쓰지 않는다.** `capabilities` 는 근거이지 허가가 아니다. 반대로 감지된 것을 자동으로 조항에 넣지도 않는다 — 생성물은 사람 검토를 거친다.
5. **감지된 언어 전체에 실제 번역을 넣는다.** 언어별 dict 의 키 집합은 `languages` 와 같아야 한다(§5).
   번역을 만들 수 없을 때만 한국어로 채우고, 그 사실을 보고한다. **빈 문자열은 넣지 않는다** — 사이트에 공백으로 렌더된다.

---

## §1 인자

```
/aiops:app-pages <slug> [--portal=<경로>] [--only=privacy,terms,releases,support] [--dry-run]
```

| 인자 | 뜻 |
|---|---|
| `<slug>` | app-portal 의 앱 식별자(소문자). `apps.json` 의 `slug` 와 같다. |
| `--portal` | app-portal 레포 경로. 생략 시 §3 으로 찾는다. |
| `--only` | 일부만 생성. 생략 시 4종 + `apps.json` + `_headers` 전부. |
| `--dry-run` | 파일을 쓰지 않고 생성될 내용을 보여준다. |

`<slug>` 는 **대상 앱 레포가 아니라 포털에서의 이름**이다. 현재 작업 중인 레포가 그 앱인지 반드시 확인한다.

## §2 입력 — 감지 계층 (생략 금지)

`/aiops:setup` §20 이 기록한 값을 읽는다. **없으면 먼저 `/aiops:setup` 을 돌린다.** 추측해서 채우지 않는다.

```bash
CAP_PERMISSIONS=$(jq -r '.agent_hints.mobile.capabilities.permissions // [] | join(",")' .claude/config.json 2>/dev/null)
CAP_SDKS=$(jq -r '.agent_hints.mobile.capabilities.sdks // [] | join(",")' .claude/config.json 2>/dev/null)
CAP_LANGUAGES=$(jq -r '.agent_hints.mobile.capabilities.languages // [] | join(",")' .claude/config.json 2>/dev/null)
CAP_BASE_UNKNOWN=$(jq -r '.agent_hints.mobile.capabilities.languages_base_unknown // false' .claude/config.json 2>/dev/null)
```

`CAP_BASE_UNKNOWN=true` 면 **Android 기본 언어를 판정하지 못한 상태다.** `languages` 에 기본 언어가
빠져 있을 수 있으므로 **사람에게 묻고** 답을 받아 진행한다. 짐작해서 채우면 `releases.json` 에
없는 언어 칸이 생기거나 실제 지원 언어가 빠진다.

권한·SDK 가 조항에 어떻게 들어가는지는 §4 의 대응표를 따른다.

## §3 포털 레포 찾기

```bash
PORTAL="${PORTAL:-}"                       # --portal 인자 우선
[ -z "$PORTAL" ] && for _p in ../app-portal ../../app-portal ~/src/game/app-portal; do
  [ -f "$_p/content/apps.json" ] && { PORTAL="$_p"; break; }
done
[ -n "$PORTAL" ] || { echo "❌ app-portal 을 찾을 수 없습니다 — --portal=<경로> 로 지정하세요."; exit 2; }
[ -f "$PORTAL/scripts/generate_site.py" ] || { echo "❌ $PORTAL 은 app-portal 이 아닙니다."; exit 2; }
```

포털 레포의 `CLAUDE.md` 를 읽는다. 이 스킬의 규약과 **그쪽 규약이 다르면 그쪽이 정본이다** —
포털의 스키마가 바뀌었는데 이 스킬이 낡았을 수 있다.

## §4 privacy.json · terms.json

### 스키마

```json
{
  "$comment": "<이 파일이 무엇인지 한 줄>",
  "documentVersion": "1.0",
  "effectiveDate": "2026년 9월 19일",
  "lead": "<문서 도입부 한두 문장>",
  "sections": [
    { "title": "<절 제목>", "blocks": [ {"p": "<문단>"}, {"ul": ["<항목>"]}, {"notice": "<강조 박스>"} ] }
  ]
}
```

- `documentVersion` — **semver 스타일 `MAJOR.MINOR` 문자열.** 날짜 기반이 아니다. 신규는 `"1.0"`.
- `effectiveDate` — **ISO 가 아니라 한국어 표기.** `"2026년 9월 19일"`.
- `blocks` 의 키는 `p` · `ul` · `notice` 셋뿐이다. 다른 키를 만들지 않는다.
- **문서를 고칠 때는 `documentVersion` 과 `effectiveDate` 를 함께 올린다.**

### 절 구성 (기존 앱 관례)

| privacy.json | terms.json |
|---|---|
| 수집하는 개인정보 | 목적과 적용 |
| 기기에 저장되는 정보 | 서비스 내용 |
| 광고와 제3자 서비스 | 이용자의 의무 |
| 동의와 권한 관리 | 지식재산권 |
| 보관 기간과 삭제 | 광고 |
| 아동의 개인정보 | 면책과 책임 제한 |
| 국외 처리 | 서비스 변경과 중단 |
| 문의 | 약관의 변경 · 준거법과 분쟁 해결 · 문의 |

절 제목은 관례이고 **내용은 앱마다 다르다.** 해당 없는 절은 넣지 않는다 —
빈 절을 채우려고 없는 기능을 지어내는 것이 이 스킬이 막으려는 실패다.

### 감지 결과 → 조항 대응표

**이 표는 "쓸 수 있는 근거" 이지 "써야 할 문장" 이 아니다.** 감지되지 않은 행은 아예 다루지 않는다.

| 감지값 | 어디에 반영 |
|---|---|
| `sdks` 에 `admob` | 「광고와 제3자 서비스」 — Google Mobile Ads SDK 가 처리하는 데이터 |
| `sdks` 에 `ump` | 「동의와 권한 관리」 — UMP 동의 화면에서 동의를 바꿀 수 있음 |
| `permissions` 에 `tracking` | 「광고와 제3자 서비스」 + iOS ATT / Android 광고 ID |
| `permissions` 에 `camera` | 「수집하는 개인정보」 — 카메라 사용 목적과 저장 여부 |
| `permissions` 에 `location` | 「수집하는 개인정보」 — 위치 정확도와 사용 목적 |
| `permissions` 에 `photo_library` | 「수집하는 개인정보」 — 사진 접근 범위 |
| `sdks` 에 `firebase_analytics`·`crashlytics` | 「광고와 제3자 서비스」 — 진단·분석 데이터 |
| `sdks` 에 `iap` | 「서비스 내용」(terms) — 결제와 환불 |
| `permissions` 가 비어 있음 | 「수집하는 개인정보」 — 수집하지 않는다는 사실을 명시 |

`internet` 은 기본 허용이라 별도 조항을 만들지 않는다. 다만 **네트워크를 쓰지 않는 앱**이면
그 사실(로그인·서버 전송 없음)을 적는 것이 기존 앱 관례다.

## §5 releases.json

```json
{
  "$comment": "<한 줄>",
  "app": "<앱 표시 이름>",
  "languages": ["ko", "en", "ja", "zh-Hans"],
  "releases": [
    {
      "version": "1.0.0",
      "releasedAt": "2026-09-19",
      "platforms": {},                      // 또는 {"ios": "1.2", "android": null}
      "title": { "ko": "첫 출시", "en": "첫 출시" },
      "changes": [ { "ko": "<항목>", "en": "<항목>" } ]
    }
  ]
}
```

- `languages` — **§2 의 `CAP_LANGUAGES` 를 그대로 쓴다.** 기존 앱 파일에서 복사하지 않는다.
  앱마다 다르다(기존 4개는 5개 언어, zen-koi 는 7개이고 `zh-Hant` 가 없다).
- `title` · `changes[]` — **언어별 dict.** 키 집합은 `languages` 와 정확히 같아야 한다.
- **실제 번역을 넣는다.** app-portal 에는 두 관례가 공존한다 — `scanbarcode`·`zen-koi` 는 실제 번역이고
  `omg19`·`onemoregame`·`brickbreaker` 는 모든 언어에 한국어를 복사해 두었다. **실제 번역이 기본**이고
  한국어 복사는 번역을 만들 수 없을 때의 폴백이다(그때는 보고에 적는다).
  **빈 문자열을 넣지 않는다** — 사이트에 공백이 렌더된다.
- `releasedAt` — 여기는 ISO(`2026-09-19`)다. `effectiveDate` 의 한국어 표기와 **다르다.**
- `platforms` — **플랫폼별 버전 dict** 다. 빈 객체 `{}` 도 유효하다.
  ```json
  {"ios": "1.2", "android": null}     // scanbarcode — 그 릴리스가 iOS 에만 나간 경우
  {}                                   // 플랫폼 구분이 없는 경우
  ```
  해당 플랫폼에 나가지 않은 릴리스는 `null` 을 넣는다. **`date` 라는 키는 없다** — 날짜는 `releasedAt` 이다.

`languages` 키가 **없는** 기존 파일이 있다(`content/omg19/releases.json`). 기존 앱 문서를 갱신할 때
그 키를 새로 채워 넣을지는 **사람에게 묻는다** — 기존 데이터의 형태를 바꾸는 일이다.

### 릴리즈 노트 본문과 `languages` 가 어긋나지 않게 한다

`changes` 에 "한국어·영어·…를 지원합니다" 같은 문장을 쓸 때는 **`languages` 와 같은 집합**이어야 한다.
기존 데이터에 이미 어긋난 사례가 있다(`brickbreaker` 는 `languages` 가 5개인데 본문은 7개 언어를
나열하고 `zh-Hant` 를 빼먹었다). 생성 후 §8 에서 대조한다.

### 입력(content)과 공개 산출물(public)은 모양이 다르다

생성기가 만드는 `public/<slug>/releases.json` 은 `content` 의 복사본이 아니다. **이 스킬이 쓰는 것은
`content` 뿐이다.** `public` 은 읽기 전용 산출물이며 계약을 쓸 때 둘을 섞지 않는다.

| | `content/<slug>/releases.json` (입력) | `public/<slug>/releases.json` (산출물) |
|---|---|---|
| 최상위 키 | `$comment` · `app` · `languages` · `releases` | `app` · `latestVersion` · `releases` |
| `languages` | 있음 | **없음** |
| `latestVersion` | 없음 | **있음** (최신 `version`) |
| `title` | 언어별 dict | 사이트 언어(`ko`) 문자열로 **평탄화** |
| `changes[]` | 언어별 dict 의 배열 | 문자열 배열로 **평탄화** |

zen-koi 실측 대조:

```jsonc
// content — title 이 dict
"title": { "ko": "첫 출시", "en": "First release", "ja": "初回リリース", … }
// public — ko 하나로 평탄화되고 languages 키가 사라짐
"title": "첫 출시"
```

### 참조 구현

`zen-koi` 가 app-portal 에 등재되어 있다(커밋 `2ac064e`). 4종 + `apps.json` 항목 + `_headers` 한 줄이
모두 갖춰진 상태이고 `generate_site.py --check` 를 통과했다. **새 앱을 만들 때 형태의 기준으로 삼는다** —
다만 문서 *내용*은 복사하지 않는다(§절대 원칙 3).

## §6 apps.json 항목

`content/apps.json` 의 `apps` 배열에 한 항목을 **추가**한다. 배열 순서가 홈 화면 순서다.

```json
{ "slug": "<slug>", "name": "<표시 이름>", "badge": "iOS · Android", "summary": "<한두 문장>" }
```

- 4필드 고정. 다른 키를 넣지 않는다.
- `badge` — 실제 배포 플랫폼. 대상 레포에 Android·iOS 중 무엇이 있는지로 판단한다
  (`agent_hints.mobile.framework`). 연령 등급이 붙는 앱은 `"iOS · 19+"` 처럼 쓴다.
- `site` 절(회사명·baseUrl·supportEmail)은 **건드리지 않는다.**
- 이미 같은 `slug` 가 있으면 추가하지 않고 **갱신 여부를 묻는다.**

## §7 support/index.html 과 _headers (손으로 쓰는 둘)

### support/index.html

생성기가 만들지 않는다. **FAQ 본문이 앱 기능마다 완전히 다르기 때문**이지 문의 채널이 달라서가
아니다 — 메일 주소는 4개 앱 모두 `support@devworld.co.kr` 로 같다.

앱별로 다른 것은 둘이다.

1. `mailto:` 의 `subject` 프리필 — **URL 인코딩된 앱 이름**
2. FAQ 본문 — 그 앱의 실제 기능에서 나온 질문

```html
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title><앱 이름> 고객지원</title><meta name="description" content="<앱 이름> 사용 안내 및 고객지원">
<link rel="stylesheet" href="/styles.css">
</head>
<body>
<header><nav class="shell"><a class="brand" href="/"><span class="mark"><글리프></span><앱 이름></a><a class="back" href="/<slug>/privacy">개인정보처리방침</a></nav></header>
<main class="shell">
<div class="eyebrow">SUPPORT</div><h1>무엇을 도와드릴까요?</h1>
<p class="lead"><한 문장></p>
<div class="actions"><a class="button" href="mailto:support@devworld.co.kr?subject=<URL인코딩>">이메일 문의</a><a class="button secondary" href="/<slug>/releases">업데이트 기록</a></div>
<h2>자주 묻는 질문</h2>
<section class="card"><h3><질문></h3><p><답></p></section>
<h2>문의할 때 알려주시면 좋은 정보</h2>
<ul><li>앱 버전과 기기·OS 버전</li><li><앱 고유 항목></li></ul>
<p class="meta">지원 이메일: <a href="mailto:support@devworld.co.kr">support@devworld.co.kr</a></p>
</main>
<footer><div class="shell">유한회사 데브월드 · <a href="https://devworld.co.kr">devworld.co.kr</a></div></footer>
</body></html>
```

FAQ 는 **그 앱을 실제로 해 본 사람이 받을 질문**을 쓴다. 감지 계층이 답을 주지 못하는 부분이라
대상 레포의 화면·설정 코드를 읽어 쓰고, 확신이 없으면 사람에게 확인한다.

`subject` 프리필은 반드시 URL 인코딩한다.

```bash
python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "<앱 이름> 지원 문의"
```

### _headers

`public/_headers` 에 캐시 규칙 한 줄을 추가한다. 다른 규칙(`/*` 의 보안 헤더 등)은 건드리지 않는다.

```
/<slug>/releases.json
  Cache-Control: public, max-age=300
```

## §8 검증 (생략 금지)

```bash
cd "$PORTAL"
python3 scripts/generate_site.py --check      # 생성물이 최신인지
```

`--check` 가 실패하면 `python3 scripts/generate_site.py` 로 생성한 뒤 다시 검사한다.

추가로 대조한다.

| 항목 | 방법 |
|---|---|
| `title`·`changes` 의 키 집합 = `languages` | `jq` 로 차집합이 비는지 |
| 빈 문자열 없음 | `jq '..|strings|select(.=="")'` 가 비어야 함 |
| `apps.json` 에 `slug` 중복 없음 | `jq '[.apps[].slug]|length == (unique|length)'` |
| `_headers` 에 해당 줄 1회만 | `grep -c "^/<slug>/releases.json$"` |
| 조항이 감지 결과와 맞는가 | `permissions`·`sdks` 에 없는 기능이 본문에 있는지 사람이 확인 |

마지막 항목은 기계가 못 한다. **생성된 법적 문서는 사람 검토를 거친다.**

## §9 결과 보고

```
## 📄 앱 문서 생성 결과 — <slug>
- 포털: <PORTAL 경로>
- 근거: permissions=[...] sdks=[...] languages=[...]
- 생성: content/<slug>/{privacy,terms,releases}.json
- 추가: content/apps.json 항목, public/_headers 1줄
- 손으로 쓴 것: public/<slug>/support/index.html
- generate_site.py --check: PASS | FAIL
- 배포: 하지 않음 — `npx wrangler deploy` 는 사람이 실행
```

`CAP_BASE_UNKNOWN=true` 였다면 **무엇을 사람에게 물어 정했는지** 보고에 적는다.

## 다른 스킬과의 관계

- 입력은 [`/aiops:setup`](../setup/SKILL.md) §20 감지 계층이다. 없으면 이 스킬을 실행하지 않는다.
- 광고 SDK 도입 자체는 `/aiops:app-ads`, 아이콘은 `/aiops:app-icon` 이 맡는다.
  이 스킬은 **이미 있는 것을 문서로 옮길 뿐** 대상 레포의 코드를 고치지 않는다.
