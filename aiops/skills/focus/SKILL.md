---
name: focus
description: 특정 작업 대상(모노레포의 앱 또는 이슈)에 집중하라는 요청 시, 그 대상 전용 git 워크트리로 진입한다. 아직 없으면 확인 후 만든다. 레포 형태를 감지해 모노레포(apps/)면 앱 축으로, 단일 레포면 이슈/주제 축으로 동작한다. "포털에 집중해줘", "영수증 작업할게", "#123 작업 시작", "쿠폰이라는 새 앱 시작할게", "/aiops:focus <대상> [이슈]", "/aiops:focus --new <새앱>" 같은 프롬프트에서 트리거.
---

# /aiops:focus — 작업 대상 워크트리 진입

사용자가 특정 대상에 "집중"/"작업"하겠다고 하면, 그 대상 전용 git 워크트리를 (필요시 생성 후) **진입**한다.
진입은 세션 cwd 를 그 워크트리로 전환하는 것이며, `EnterWorktree` 네이티브 도구로 수행한다.

> 이 스킬은 사용자가 명시적으로 요청한 워크트리 워크플로이므로 `EnterWorktree` 호출이 허용된다.
> git 레포 밖에서 호출되면 그 사실을 알리고 중단한다.

## STEP 0 — 레포 형태 감지 (하드코딩 금지)

이 스킬은 **여러 프로젝트에 설치된다.** 특정 레포의 디렉토리 구조·스크립트·서비스 목록을 문서에 박아두면
그 레포 밖에서 조용히 깨진다. 그래서 매 실행마다 감지한다.

```bash
# ① 메인 워크트리 루트 (다른 워크트리 안에서 호출돼도 메인을 찾는다 — 중첩 생성 방지)
COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
  echo "git 레포가 아닙니다."; exit 1; }
case "$COMMON" in /*) ;; *) COMMON="$PWD/$COMMON" ;; esac
MAIN=$(dirname "$COMMON")

# ② base ref — dev 흐름 레포면 origin/dev, 아니면 원격 기본 브랜치
BASE=$(git -C "$MAIN" config --get aiops.worktreeBase || true)          # 프로젝트 오버라이드
if [[ -z "$BASE" ]]; then
  if git -C "$MAIN" rev-parse --verify --quiet origin/dev >/dev/null; then BASE=origin/dev
  else BASE=$(git -C "$MAIN" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null \
              | sed 's|refs/remotes/||'); BASE=${BASE:-origin/main}; fi
fi
git -C "$MAIN" fetch "${BASE%%/*}" "${BASE#*/}" --quiet 2>/dev/null || true

# ③ 모노레포인가 — base 의 후보 루트로 판정 (현재 체크아웃이 아니다: main 에 있으면 dev 전용 앱을 못 본다)
#    ⚠️ 루트가 하나라고 가정하지 말 것. 배포 실행체가 두 버킷에 나뉜 레포가 있다
#       (예: Next.js 앱은 apps/, 순수 Worker 는 services/ — 한쪽만 읽으면 그 앱은 /focus 가 안 된다).
ROOTS=$(git -C "$MAIN" config --get aiops.worktreeRoots || echo "apps services")
APPS=""
for r in $ROOTS; do
  APPS="$APPS $(git -C "$MAIN" ls-tree --name-only "$BASE" "$r/" 2>/dev/null | sed "s|$r/||")"
done
APPS=$(echo "$APPS" | tr ' ' '\n' | sed '/^$/d' | sort -u)
[[ -n "$APPS" ]] && MODE=monorepo || MODE=single

# ④ 규약 소유 스크립트가 있으면 위임 대상
HELPER="$MAIN/scripts/new-worktree.sh"; [[ -x "$HELPER" ]] || HELPER=""
```

- `aiops.worktreeBase` git config 로 base 를 프로젝트별로 덮을 수 있다(예: `trunk`).
- **`$HELPER` 가 있으면 생성 로직을 그 스크립트에 위임한다.** 규약(브랜치명·디렉토리명·base·`--no-track`)의
  단일 소유자는 그 레포다. 같은 로직을 스킬에 복사하면 두 곳이 갈라진다(실제로 그렇게 갈라진 적이 있다).

## STEP 1 — 대상 해석

### 1-1. `MODE=monorepo` — 앱 축

앱 목록은 **`$APPS`(= base 의 후보 루트 실측)가 진실원천**이다. 문서에 목록을 박지 않는다 — 앱은 계속 늘어난다.
후보 루트는 기본 `apps services` 이고 `aiops.worktreeRoots` git config 로 프로젝트별로 바꾼다.

사용자 표현 → 앱 매칭 순서:
1. `$APPS` 와 정확히 일치
2. 부분매칭(대소문자·공백·하이픈 무시). 예: `포토스튜디오` → `photo-studio`
3. 프로젝트가 별칭표를 두었으면 참고: `.claude/config.json` 의 `worktree.aliases`
   (`{"별칭": "app"}`). 없으면 무시한다 — **스킬에 특정 프로젝트의 한글 별칭을 박지 않는다.**

- **이슈 번호**: 프롬프트에 `#N` 또는 명시적 이슈 언급이 있으면 사용, 없으면 **focus 모드**(이슈 없음).
- **앱을 특정할 수 없으면** `$APPS` 를 후보로 제시하고 되묻는다. **임의 추측 금지.**
- **여러 앱에 걸리면 되묻는다.** 짧은 말일수록 겹친다("이메일"이 작성기인지 발송기인지).

### 1-2. `MODE=single` — 이슈/주제 축

앱 축이 없으므로 이슈 번호(또는 짧은 주제 슬러그)가 대상이다.
- `#N` 이 있으면 이슈 스코프, 없으면 사용자 표현에서 소문자·숫자·하이픈 슬러그를 만들어 확인받는다.

### 1-3. `$APPS` 에 없는 이름 — 신규 앱일 수 있다 (monorepo)

새 앱은 `apps/<app>` 을 **만드는 것이 첫 작업**이라 존재 검사만 하면 영원히 시작할 수 없다(닭-달걀).
그렇다고 미등록 이름을 곧바로 받으면 오타가 조용히 엉뚱한 브랜치가 된다. 그래서 **되묻는다**:

1. 1-1 의 부분매칭으로 근접 후보가 있으면 **그걸 먼저 제시**한다("`recept` → `receipt` 말씀인가요?").
2. 근접이 없거나 사용자가 부정하면 **신규 앱인지 명시적으로 확인**한다 — 이름 규약(소문자·숫자·하이픈)과
   이슈 번호 유무를 함께 묻는다.
3. 사용자가 신규라고 확인한 경우에만 STEP 3 을 `--new` 로 실행한다. **확인 없이 `--new` 금지.**

사용자가 "새 앱", "신규 앱" 이라고 **먼저 밝힌 경우**(`/aiops:focus --new coupon`)에는 1~2 를 건너뛴다.

> 워크트리까지가 이 스킬의 책임이다. 앱 골격과 레지스트리 등록은 **진입 후** 그 워크트리 안에서 한다
> (STEP 5 참조). 스킬이 템플릿을 들면 앱 구조가 바뀔 때마다 낡는다.

## STEP 2 — 대상 브랜치·디렉토리 계산

`$HELPER` 가 있으면 **그 스크립트의 규약이 정본**이다(아래는 그와 같은 형태를 가정한 기본값).

| MODE | 스코프 | 브랜치 | 디렉토리 |
|---|---|---|---|
| monorepo | 이슈 | `feature/<app>/issue-<N>` | `$MAIN/.claude/worktrees/<app>-<N>` |
| monorepo | focus | `work/<app>` | `$MAIN/.claude/worktrees/<app>` |
| single | 이슈 | `feature/issue-<N>` | `$MAIN/.claude/worktrees/issue-<N>` |
| single | focus | `work/<slug>` | `$MAIN/.claude/worktrees/<slug>` |

현재 세션 cwd 가 이미 대상 디렉토리면(`realpath` 비교) 진입을 생략하고 "이미 `<대상>` 워크트리입니다"만 알린다.

## STEP 3 — 디렉토리 상태별 분기

### 3-a. 없으면 — 생성

```bash
if [[ -n "$HELPER" ]]; then
  "$HELPER" <app-or-slug> [issue]            # 규약 소유자에게 위임 (권장)
  "$HELPER" --new <app> [issue]              # 1-3 에서 확인된 신규 앱만
else
  git -C "$MAIN" worktree add --no-track -b "<branch>" "<dir>" "$BASE"
fi
```

`--new` 는 "base 의 `apps/` 에 있어야 한다"는 검사만 면제하고 나머지 규약은 동일하다.
`$HELPER` 가 `--new` 를 모르면(다른 프로젝트) 폴백 경로를 쓰고 그 사실을 알린다.

### 3-b. 있으면 — **브랜치를 확인한 뒤** 재사용

디렉토리가 있다고 그냥 들어가지 않는다. 누군가(사람이든 이전 세션이든) 그 안에서 `git checkout` 했을 수 있고,
모르고 들어가면 **`dev`·`main` 에 직접 커밋**하게 된다(feature 브랜치·PR 우회).

```bash
CUR=$(git -C "$DIR" branch --show-current)
```

- `CUR` == 기대 브랜치 → STEP 4.
- 다르면 **진입하지 말고** 기대/실제 브랜치와 `git -C "$DIR" status --short`(미커밋이 있으면 전환이 실패한다)를
  함께 보여주고 선택지를 제시한다.
  1. **그 브랜치 그대로 사용** — 의도한 상태일 수 있다. 단 `dev`·`main`(또는 base) 이면 직접 커밋 위험을 명시 경고.
  2. **규약 브랜치로 전환** — `git -C "$DIR" checkout <expected>`, 없으면 `$BASE` 에서 생성.
  3. **취소**

## STEP 4 — 진입

`EnterWorktree` 를 **`path=$DIR`(절대경로)** 로 호출한다.
(`name` 생성 모드 금지 — 그 모드는 `origin/main` 기준이라 dev 흐름 레포와 어긋난다.)

## STEP 5 — 확인

한 줄로 보고: 대상·브랜치·경로. 상태줄을 쓰는 프로젝트면 `📁 <대상> · [#N ·] <branch>` 로 표시된다고 알린다.
이후 작업은 그 대상(`apps/<app>` 또는 이슈 범위)에 집중한다.

**신규 앱(`--new`)인 경우**, `apps/<app>` 이 아직 없다는 점과 다음 할 일을 알린다. 프로젝트에
서비스 레지스트리가 있으면(`registry/services.yaml` 등 — **있을 때만**) 등록 누락이 조용한 실패가 되므로 함께 짚는다:

1. `apps/<app>` 골격 — 기존 앱 하나를 본으로 삼는다(스킬에 템플릿을 두지 않는 이유는 1-3 참조).
2. 레지스트리 등록 — 그 파일이 진실원천이면 누락 시 포털/목록에 안 뜬다.
   프로젝트가 fail-closed 기본값(예: `visibility`·`tier` 미지정 시 숨김·잠금)을 쓰면 **반드시 명시**한다.
3. 코드젠 산출물 재생성 — 레지스트리에서 생성되는 JSON 등이 있으면 그 생성 명령을 돌린다(직접 편집 금지).

이 세 항목의 **실제 파일·명령은 프로젝트 문서(CLAUDE.md·docs/)에서 확인**한다. 여기에 박아두지 않는다.

## 진출

`/aiops:unfocus` (또는 "워크트리 나가기") → `ExitWorktree`.
