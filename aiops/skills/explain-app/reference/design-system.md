# 해설 문서 디자인 시스템

`reference/example.html` 이 이 시스템의 구현체다. 아래는 그 규칙과 이유.

---

## 1. 색 = 위치

이 시리즈의 유일한 시각적 규칙이다. **색은 예쁘라고 있는 게 아니라 "이 일이 어디서 벌어지는가"를
인코딩한다.** 문서 전체에서 규칙이 유지되므로 독자는 그림만 보고 지대를 읽는다.

| 토큰 | 뜻 | 라이트 | 다크 |
|---|---|---|---|
| `--cf` / `--cf-soft` | 클라우드 (사용자가 마주하는 쪽) | `#B0530F` / `#F7EBDF` | `#E89550` / `#3A2A1B` |
| `--mac` / `--mac-soft` | LLM 서버 (뒤에서 도는 연산) | `#1F6577` / `#E2EEF1` | `#6BB8C9` / `#16313A` |
| `--warn` / `--warn-soft` | 실패·삭제·거절 | `#8B1F3E` / `#F8E7EC` | `#E5849F` / `#3A1D27` |

> 토큰 이름 `--mac` 은 역사적 잔재다. **화면에 보이는 글자는 언제나 "LLM 서버"** 여야 한다.
> 이름을 바꾸고 싶으면 예제 HTML 과 함께 바꿀 것.

**연산 백엔드를 안 쓰는 앱**(클라우드에서 다 끝나는 앱)은 지대가 하나뿐이다. 그때는 두 색을
버리지 말고 **"사용자가 보는 것 / 뒤에서 저절로 도는 것"** 으로 재배정한다 —
Cron·정리 작업이 `--mac` 을 받는다. 색 수를 줄이면 그림이 밋밋해지고 대비가 사라진다.

### 중립색

순회색을 쓰지 않는다. 종이 쪽으로 아주 살짝 따뜻하게 기울인 값이다.

```
--paper #FAF9F7   --card #FFFFFF   --ink #191A1D
--ink-2 #5C5F66   --ink-3 #8A8D95  --rule #E3E0DA   --rule-2 #F0EDE7
```

다크: `--paper #14151A` · `--card #1B1D23` · `--ink #EAE9E5` · `--ink-2 #9DA0A8` ·
`--ink-3 #71757E` · `--rule #2C2F37` · `--rule-2 #23262C`.

### 테마 배선 (셋 다 필요)

```css
:root { /* 라이트 토큰 */ }
@media (prefers-color-scheme: dark) { :root { /* 다크 토큰 */ } }
:root[data-theme="dark"]  { /* 다크 토큰 (뷰어 토글이 이겨야 한다) */ }
:root[data-theme="light"] { /* 라이트 토큰 */ }
```

컴포넌트는 **토큰으로만** 스타일링한다. 미디어쿼리 안에서 직접 컴포넌트를 건드리면 토글이 안 먹는다.

---

## 2. 타이포

외부 폰트 금지(CSP 가 막는다). 시스템 스택으로 **역할 3개**를 만든다.

```css
--sans: "Pretendard Variable", Pretendard, -apple-system, BlinkMacSystemFont,
        "Apple SD Gothic Neo", "Segoe UI", Roboto, sans-serif;
--mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
```

| 역할 | 설정 |
|---|---|
| 표제 | `clamp(2.1rem, 5vw, 3.1rem)` · 800 · `letter-spacing:-0.03em` · `text-wrap:balance` |
| 절 제목 | `clamp(1.45rem, 3vw, 1.9rem)` · 750 · `-0.02em` |
| 본문 | 17px · `line-height:1.85` · `--ink` |
| 눈썹말·표 머리 | mono · 0.72rem · `letter-spacing:0.16em` · 대문자 · `--ink-3` |
| 데이터·식별자 | mono · `font-variant-numeric: tabular-nums` |

**한국어 필수 3종**: `word-break: keep-all` (단어 중간에서 안 끊기게),
`overflow-wrap: anywhere` (긴 URL 대비), 본문 `line-height` 1.8 이상.

---

## 3. 레이아웃

- 본문 측정폭 `--measure: 40rem`. 그림·표는 `--wide: 72rem` 로 넓게 나간다.
  **읽는 것은 좁게, 보는 것은 넓게.**
- 형제 간격은 전부 flex/grid + `gap`. per-element margin 을 쓰면 조용히 겹치거나 두 배가 된다.
- 넓은 것(표·그림)은 각자 `overflow-x:auto` 컨테이너 안에. 페이지 본문은 절대 가로로 안 밀린다.
- 그림 프레임: `.figframe` = `--card` 배경 + `--rule` 테두리 + 6px radius + 1.4rem 패딩.
  `min-width: 46rem` 를 준 SVG 는 좁은 화면에서 프레임 안에서만 스크롤된다.

---

## 4. SVG 관용구

### 화살표

```html
<defs>
  <marker id="ah" viewBox="0 0 10 10" refX="9" refY="5"
          markerWidth="7" markerHeight="7" orient="auto-start-reverse">
    <path d="M 0 0 L 10 5 L 0 10 z" style="fill:var(--ink-2)"></path>
  </marker>
</defs>
<line x1="…" y1="…" x2="…" y2="…" style="stroke:var(--ink-2)" stroke-width="1.6"
      marker-end="url(#ah)"></line>
```

> **id 는 문서 안에서 유일**해야 한다. 한 페이지에 SVG 가 여럿이면 `ah`·`ah2`·`ah3` 로 나눈다.
> 겹치면 뒤에 온 marker 가 앞 그림의 화살촉을 바꿔 버린다.

### 색

프레젠테이션 속성(`fill="…"`)이 아니라 **`style="fill:var(--…)"`** 로 준다. 커스텀 속성이
속성 자리에서 해석되지 않는 환경이 있다.

### 좌표 규율

- 같은 층의 박스는 **같은 y**, 같은 열은 **같은 x**. 눈대중 어긋남이 곧 아마추어 느낌이다.
- 대각선 화살표의 라벨은 **중점 x, 공통 y**(예: 전부 `y=215/232`)에 놓아 라벨끼리 한 줄로 정렬시킨다.
- 지대 밴드는 박스보다 위아래 8px 씩 크게. 박스가 밴드에 닿으면 답답하다.
- 글자 크기 11~14px. 설명 문장은 그림이 아니라 `figcaption` 에 쓴다.

### 잘림 방지 (자주 겪는 사고)

왼쪽 거터 라벨을 `text-anchor="end"` 로 놓으면 긴 라벨이 viewBox 밖으로 나간다.
**viewBox 의 x 를 음수로** 준다:

```
viewBox="-32 0 1432 470"    <!-- 왼쪽 32px 여백 -->
```

### 접근성

`<figure>` 안에 넣고, `<svg role="img" aria-label="…">` 에 그림이 주장하는 바를 한 문장으로 적는다.
`figcaption` 과 같은 내용이면 된다. SVG 안에 `<script>`·`<style>`·`<foreignObject>` 를 넣지 않는다.

---

## 5. 반복 컴포넌트

| 컴포넌트 | 용도 |
|---|---|
| `.chip.cf` / `.chip.mac` | 본문 안에서 지대를 표시하는 알약. 범례에도 같은 것을 쓴다 |
| `.facts` / `.fact` | 핵심 숫자 카드. `dd` 를 `order:1`, `dt` 를 `order:2` 로 두어 숫자가 위 |
| `.note` | 좌측 `--warn` 3px 바 + 번호 마커. "조용히 넘어가지 않게 만든 것" 절 전용 |
| `.tablewrap > table` | 등장인물 표. 이름 칸에 mono 서브라벨로 실제 식별자를 단다 |

`.note` 의 번호는 **순서가 있을 때만** 숫자로 쓴다. 순서가 없으면 `!` 같은 단일 마커를 쓴다 —
번호는 정보이지 장식이 아니다.
