# aiops-v1 릴리스 체크리스트

체크리스트 버전: `1.0` (2026-09-13 — v1.10.0 릴리스 시점에 신설)

이 저장소의 릴리스는 **`tools/release.sh` 가 단일 소유자**다. 이 문서는 그 스크립트가 검사하지
*않는* 것들 — 무엇을 어떤 순서로 준비해 스크립트에 넘기는가 — 을 정한다.

> aiops-codex 의 체크리스트와 혼동하지 말 것. 그쪽은 `scripts/release.py` + `ReleaseValidator` +
> `unittest` 가 게이트지만, 이 저장소에는 그 셋 중 무엇도 없다. 여기 게이트는 **bash 하니스**와
> **플러그인 매니페스트 검증**이다.

## 1. 릴리스 판정 게이트

- [ ] 테스트 하니스 전량 통과 — `for t in aiops/tests/*.test.sh; do bash "$t" | tail -1; done`
      각 줄이 `TESTS=N PASS=N FAIL=0` 이어야 한다. 현재 **8종 413건**(#55 머지 시점).
      ⚠️ 하니스를 추가·개정하는 PR 은 이 수치를 **같은 PR 에서** 갱신한다. 수치가 줄었다면
      커버리지가 준 것과 구별되지 않으므로, 줄인 이유를 PR 본문에 적지 않은 감소는 거부한다.
- [ ] 플러그인 매니페스트 — `claude plugin validate ./aiops` → `Validation passed`
- [ ] 마켓플레이스 매니페스트 — `claude plugin validate .` → `Validation passed`
- [ ] P0/P1 미해결 없음. P2 는 이슈로 분리돼 있으면 릴리스를 막지 않는다.

## 2. 수치 정합 (릴리스마다 어긋난다)

스킬·에이전트 수는 **세 곳**에 문자열로 박혀 있고, 새 에이전트·스킬이 들어오면 반드시 어긋난다.
`plugin.json` 의 `description` 은 플러그인 피커에 그대로 노출되므로 사용자가 가장 먼저 본다.

```sh
ls aiops/skills/*/SKILL.md | wc -l      # 스킬 실측
ls aiops/agents/*.md | wc -l            # 에이전트 실측
grep -n '스킬 [0-9]* + 에이전트 [0-9]*' aiops/.claude-plugin/plugin.json
grep -n '스킬 [0-9]*개·에이전트 [0-9]*개' README.md
grep -n '^## [34]\. \(스킬\|에이전트\) [0-9]*개' docs/USAGE.md
```

- [ ] 세 위치의 수치가 실측과 일치
- [ ] `docs/USAGE.md` §3 의 "나머지 N개는 모델이 …" = 스킬 수 − `disable-model-invocation` 수
      (`grep -l '^disable-model-invocation' aiops/skills/*/SKILL.md | wc -l`)
- [ ] 신규 에이전트가 `docs/USAGE.md` §4 표의 해당 묶음 행에 들어갔는가

## 3. 버전 결정

`plugin.json` 의 `version` 하나가 정본이다. 캐시 경로
`~/.claude/plugins/cache/aiops/aiops/<version>/` 가 이 값으로 갈리므로, **올리지 않으면 설치본은
변경을 받지 못한다** — 실패처럼 보이지 않는 종류의 사고다.

| 상승 | 기준 |
|---|---|
| major | 마커 계약·스킬 인터페이스 파괴 변경 |
| minor | 스킬·에이전트·템플릿 신설, 새 config 키, 새 `platform` 값 |
| patch | 문구·문서·기존 경로 버그 수정 |

- [ ] 상승 폭을 정하고 근거를 릴리스 노트에 한 줄로 남긴다

## 4. 순서 (이 순서를 지킨다)

1. [ ] 버전 올림 + 릴리스 노트를 **한 브랜치**에 담는다
   - `aiops/.claude-plugin/plugin.json` 의 `version`
   - `docs/release/v<버전>.md` (아래 §5 서식)
2. [ ] PR → main 머지 (보호 브랜치 직접 push 금지)
3. [ ] `git checkout main && git pull --ff-only origin main`
4. [ ] `DRY=1 tools/release.sh v<버전>` — 계획 출력 확인
5. [ ] `tools/release.sh v<버전>` — 태그 + `latest` 이동 + **공개본 게시**까지

> **릴리스 노트는 태그 이전에 머지한다.** 태그 트리에 그 릴리스의 기록이 들어 있어야
> `git archive <태그>` 로 나가는 공개본이 자기 자신을 설명한다. (v1.10.0 은 이 문서가 생기기
> 전에 태그돼 예외다 — 노트가 태그 뒤에 붙었다.)

## 5. 릴리스 노트 서식

`docs/release/v<버전>.md`:

```markdown
# 릴리스 v<버전>

릴리스 일자: YYYY-MM-DD
직전 릴리스: v<이전>

## 상승 근거
<major|minor|patch 와 한 줄 이유>

## 변경 내용 (v<이전> 이후)
### 기능
- feat: … (#N)
### 수정·정리
- fix/refactor: … (#N)

## 릴리스 판정 근거
- 테스트 하니스 N종 M건 PASS
- `claude plugin validate ./aiops` / `claude plugin validate .` — 둘 다 통과

## 알려진 한계
- <없으면 "없음" 이라고 쓴다 — 빈 절을 남기지 않는다>

## 태그
- `v<버전>` — 본 릴리스가 머지된 main 커밋
- `latest` — 같은 커밋으로 이동
```

## 6. 태그 규약

- **손으로 `git tag` 하지 않는다.** `tools/release.sh` 가 태그·`latest`·공개 게시를 한 번에
  묶고 있다. 손으로 태그하면 공개본 게시가 빠지고, `#latest` 를 핀한 외부 사용자는 **옛 버전을
  최신이라 믿는다.**
- 릴리스는 언제나 **새 태그**로 낸다(스크립트가 중복 태그를 거부한다 — 이력이 감사 기록이다).
- `latest` 는 이력이 아니라 **이동하는 별칭**이다. 릴리스마다 최신 커밋으로 옮긴다(누락 금지).
- 드리프트 복구: `tools/release.sh --sync-latest v<버전>`
- 공개 게시만 재실행: `tools/release.sh --publish-only v<버전>`

## 7. 릴리스 후

- [ ] `git ls-remote --tags origin | grep -E 'v<버전>|latest'` — 둘 다 같은 커밋
- [ ] 공개 레포(`git config --get aiops.publicRemote`)의 트리·태그 갱신 확인
- [ ] 소비 프로젝트는 **자동으로 당겨오지 않는다** — 마켓플레이스 재등록 또는 update 안내

## 알려진 한계

- 공개본 게시는 전진 미러가 아니라 릴리스 트리를 공개 레포 히스토리 위에 새 커밋으로 얹는
  방식이다. 사내 이력의 내부 리소스명이 공개되지 않게 하려는 의도적 설계다(README 참조).
- 릴리스 노트는 v1.10.0 부터 기록한다. 그 이전 버전은 태그와 커밋 이력으로만 재구성된다 —
  없는 기록을 소급해 지어내지 않는다.
- 이 저장소에는 CI 파이프라인이 없다. 게이트는 릴리스 담당자가 로컬에서 실행한 결과다.
