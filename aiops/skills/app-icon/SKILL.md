---
name: app-icon
description: "앱 아이콘을 코드로 생성한다 — 외부 에셋 없이 Android 적응형 아이콘(벡터 XML)과 iOS 1024 PNG 를 만들고 각 플랫폼의 에셋 카탈로그/리소스 경로에 배치한다. 디자인은 앱의 실제 성격에서 끌어오며, 저작권 있는 이미지를 쓰지 않는다."
---

# /aiops:app-icon — 앱 아이콘 생성

외부 에셋 없이 **코드로** 앱 아이콘을 만든다. Android 는 벡터 드로어블, iOS 는 1024×1024 PNG 다.

## 절대 원칙

1. **외부 이미지를 가져오지 않는다.** 웹에서 내려받은 아이콘·클립아트·폰트 아이콘을 쓰지 않는다 —
   저작권 문제가 스토어 심사에서 터진다. 도형과 색으로 만든다.
2. **기존 아이콘을 말없이 덮어쓰지 않는다.** 이미 아이콘이 있으면 교체 여부를 **묻는다.**
   출시된 앱의 아이콘 변경은 사용자가 앱을 못 찾게 만드는 변경이다.
3. **도형 정의를 한 곳에 둔다.** Android 벡터와 iOS 생성 스크립트가 같은 도형을 두 번 구현하면
   **한쪽만 고쳤을 때 아이콘이 갈라진다.** §3-1 의 공유 좌표계를 쓴다.
4. **스토어에 제출하지 않는다.** 파일을 만들 뿐이다.

---

## §1 인자

```
/aiops:app-icon [--platform=<android|ios|all>] [--force] [--dry-run]
```

`--force` 없이 기존 아이콘을 덮어쓰지 않는다.

## §2 전제 확인

```bash
FRAMEWORK=$(jq -r '.agent_hints.mobile.framework // empty' .claude/config.json 2>/dev/null)
```

`agent_hints.mobile` 이 없으면 `/aiops:setup` 을 먼저 돌린다.

기존 아이콘 존재 확인:

```bash
find . -maxdepth 7 \( -name node_modules -o -name .git -o -name build -o -name DerivedData \) -prune -o \
  \( -path '*/mipmap-*/ic_launcher*' -o -path '*AppIcon.appiconset/*' \) -print 2>/dev/null | head
```

## §3 디자인 결정 — 앱에서 끌어온다

아이콘은 장식이 아니라 **식별자**다. 임의로 예쁜 도형을 고르지 않고 앱의 실제 성격에서 끌어온다.

| 근거 | 어디서 읽는가 |
|---|---|
| 앱 이름·표시 이름 | `strings.xml` · `InfoPlist` · `apps.json` 의 `name` |
| 앱이 무엇을 하는가 | README · 주요 화면 코드 · `apps.json` 의 `summary` |
| 기존 브랜드 색 | 테마 정의(`Color.kt` · `Theme.swift` · `colors.xml`) |

**기존 브랜드 색이 있으면 그것을 쓴다.** 없을 때만 새로 정하고, 새로 정했다는 사실을 보고한다.

제약:

- 단순해야 한다. 48dp 로 줄었을 때 알아볼 수 있어야 한다. 가는 선·작은 글자는 뭉개진다.
- 글자를 넣더라도 **한 글자**까지다. 앱 이름을 다 넣지 않는다.
- 배경과 전경의 명도 차이를 충분히 둔다. 다크 모드 배경에서도 보여야 한다.

## §3-1 도형은 한 번만 정의한다 — 108 공유 좌표계

Android 벡터(`viewportWidth=108`)와 iOS PNG 생성이 **같은 도형 정의를 읽게 한다.** 두 플랫폼 모두
108 기준 좌표계로 기술하고, 출력 단계에서만 각자의 형식으로 바꾼다.

```
tools/icon_shape.py        # 도형 정의 — 단일 정본 (108 좌표계)
        ├─→ res/drawable/ic_launcher_foreground.xml   (벡터 pathData)
        └─→ Assets.xcassets/.../icon-1024.png         (108 → 1024 스케일, ×9.481)
```

한쪽만 고치면 갈라지므로, **정의를 고친 뒤 양쪽을 다시 생성**하고 §6 에서 대조한다.
기존 레포가 이미 두 곳에 따로 그려 두었다면(zen-koi 가 그렇다) 통합 여부를 **사람에게 묻는다** —
아이콘이 바뀌는 변경이다.

## §4 Android — 적응형 아이콘

Android 8.0+ 는 배경/전경 두 레이어를 받아 기기 모양(원·스퀘클 등)으로 마스킹한다.

```
app/src/main/res/
  mipmap-anydpi-v26/ic_launcher.xml            # <adaptive-icon> 배경+전경+모노크롬 참조
  mipmap-anydpi-v26/ic_launcher_round.xml      # 같은 내용
  drawable/ic_launcher_background.xml          # 벡터
  drawable/ic_launcher_foreground.xml          # 벡터
  drawable/ic_launcher_monochrome.xml          # 벡터 — 테마 아이콘(Android 13+)
```

```xml
<!-- mipmap-anydpi-v26/ic_launcher.xml -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background"/>
    <foreground android:drawable="@drawable/ic_launcher_foreground"/>
    <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>
</adaptive-icon>
```

`monochrome` 은 Android 13+ 의 테마 아이콘(사용자 배경색에 맞춰 단색으로 렌더)에 쓰인다.
**빠뜨리면 테마 아이콘을 켠 사용자에게 기본 아이콘으로 떨어진다.** 전경과 같은 도형을 단색으로 그린다.

**안전 영역이 핵심이다.** 108×108dp 캔버스에서 **가운데 66dp 원 안**에 든 것만 반드시 보인다.
바깥은 기기 모양에 따라 잘린다. 전경 요소를 이 원 밖으로 내보내지 않는다.

```xml
<!-- drawable/ic_launcher_foreground.xml -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <!-- 안전 영역: 중심 (54,54), 반지름 33 -->
    <path android:fillColor="#FFFFFF" android:pathData="..."/>
</vector>
```

**`minSdk` 가 26 이상이면 밀도별 PNG(`mipmap-hdpi` 등)가 아예 필요 없다.** 적응형 아이콘만으로 끝난다.
`minSdk` 가 26 미만인 레포에서만 래스터를 추가하고, 그 사실을 보고한다.

```bash
grep -rn 'minSdk' --include='*.gradle' --include='*.gradle.kts' . 2>/dev/null | head -3
```

## §5 iOS — 1024 PNG

Xcode 14+ 는 **1024×1024 한 장**만 받는다(단일 크기 방식). 크기별 PNG 를 만들지 않는다.

```
<App>/Assets.xcassets/AppIcon.appiconset/
  Contents.json
  icon-1024.png
```

```json
{
  "images": [
    { "filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
```

제약:

- **알파 채널이 없어야 한다.** 투명도가 있으면 App Store Connect 업로드가 거부된다.
- 모서리를 직접 둥글게 만들지 않는다. iOS 가 마스킹한다. 사각형 전체를 채운다.

PNG 는 코드로 만든다. 외부 에셋을 쓰지 않는 원칙(§절대 원칙 1)을 지키는 방법이다.

```bash
# 벡터 정의 → PNG. Pillow 가 없으면 설치 대신 사람에게 알린다(환경을 임의로 바꾸지 않는다).
python3 -c "import PIL" 2>/dev/null || echo "Pillow 미설치 — 'pip install Pillow' 를 사람에게 안내한다"
```

알파 제거는 RGB 로 변환해 배경을 채우는 방식으로 한다(`RGBA` 저장 금지).

## §6 검증

| 검사 | 방법 |
|---|---|
| iOS PNG 크기 | `sips -g pixelWidth -g pixelHeight icon-1024.png` → 1024×1024 |
| iOS 알파 없음 | `sips -g hasAlpha icon-1024.png` → `no` |
| Android 벡터 유효성 | 빌드가 통과하는지 (`assembleDebug`) |
| 안전 영역 | 전경 벡터의 좌표가 중심 반경 33 안에 드는지 |
| monochrome 존재 | `ic_launcher.xml` 에 `<monochrome>` 이 있는지 |
| 양 플랫폼 도형 일치 | 같은 정의에서 생성했는지 — 따로 그렸다면 육안 대조 |
| 48dp 가독성 | 축소 렌더해 사람이 확인 — **기계가 못 한다** |

마지막 항목은 사람이 본다. `/aiops:run-mobile-e2e` 나 시뮬레이터 홈 화면 스크린샷으로 확인한다.

## §7 결과 보고

```
## 🎨 앱 아이콘 생성 결과
- 플랫폼: android | ios | all
- 디자인 근거: <앱 이름/성격에서 끌어온 것>, 색: <기존 브랜드 색 | 신규 지정>
- Android: mipmap-anydpi-v26/ic_launcher.xml + drawable 벡터 2종
- iOS: AppIcon.appiconset/icon-1024.png (알파 없음 확인)
- 기존 아이콘: 없음 | 있음(교체 동의 받음) | 있음(보존 — --force 없음)
- 사람 확인 필요: 48dp 축소 가독성
```

색을 새로 정했다면 **무엇을 왜 골랐는지** 한 줄로 적는다.

## 다른 스킬과의 관계

- 스택 판정은 [`/aiops:setup`](../setup/SKILL.md) 의 `agent_hints.mobile.framework`.
- 광고는 `/aiops:app-ads`, 문서는 `/aiops:app-pages`.
