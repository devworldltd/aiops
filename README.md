# aiops-v1

DevWorld **AI DevOps 워크플로**를 **Claude Code 플러그인 네이티브**로 재구축한 레포. `/devflow`(기획 → 개발 → QA/E2E/PR/배포) 멀티에이전트 방향성을 유지하되, 복사 설치(install.sh)가 아니라 **플러그인 마켓플레이스**로 배포한다.

> 🌐 **배포**: 공개본은 [github.com/devworldltd/aiops](https://github.com/devworldltd/aiops) (Apache-2.0),
> 개발 정본은 사내 Gitea 다. 공개본에는 **릴리스 트리만 새 히스토리로** 게시된다.
>
> 📖 **[`docs/USAGE.md`](docs/USAGE.md) — 의도 · 정책 · 결과물 포함 전체 사용법.**
> 스킬 32개·에이전트 25개의 목록과 결과물, 마커 헤더 인터페이스, 게이트 통과 조건,
> 설정 표면(`config.json`·`profile.yaml`·`git config aiops.*`), 알려진 한계까지.

## 왜 v1 인가 (설계 배경)

이전 `ai-devops-v2`는 `.claude/skills`·`.claude/agents`를 프로젝트마다 **복사**하는 모델이었다. 플러그인으로 이관하려다 실측으로 **근본 제약**을 확인했다:

> **플러그인 에이전트·스킬은 네임스페이스 이름으로만 해석된다.** `subagent_type: "planning"`(bare) → `Agent type 'planning' not found`. `aiops:planning`(네임스페이스) → 정상.

기존 스킬들은 서로를 **bare 이름**으로 참조(devflow가 `planning`·`dev-frontend` 호출)해서 그대로는 플러그인화 시 워크플로가 깨진다. 그래서 aiops-v1은 **모든 상호참조를 네임스페이스(`aiops:`)로** 재작성해 처음부터 plugin-native로 만들었다.

## 구조

- **단일 플러그인 `aiops`** — 스킬 32 + 에이전트 25 + 템플릿(E2E·모바일)을 하나의 네임스페이스 `aiops:`에.
  - 스킬 32 중 **3개(`backend`·`frontend`·`wireframe`)는 `disable-model-invocation: true`** 로
    모델이 자동 선택하지 않는다(사람이 슬래시로만 호출) → 모델에 노출되는 것은 29개.
  - 크로스-플러그인 참조 없음(단일 플러그인) → 재편에 견고.
- 스킬은 에이전트를 `aiops:planning` 처럼 참조. 슬래시 명령은 `/aiops:devflow`.
- 템플릿은 `${CLAUDE_PLUGIN_ROOT}/templates/…`.
- 프로젝트별 설정(`.claude/config.json`·`.reviewer/profile.yaml`)은 **`/aiops:setup`** 이 생성(install.sh 불필요).

```
aiops-v1/
├── .claude-plugin/marketplace.json      # 마켓플레이스: aiops → ./aiops
├── aiops/                                # 플러그인
│   ├── .claude-plugin/plugin.json
│   ├── skills/     (32)                  # devflow·bugflow·chainflow·setup·qa-*·merge-*·focus·unfocus·explain-app …
│   ├── agents/     (25)                  # planning·dev·dev-backend·qa-e2e·dev-pr …
│   ├── scripts/                          # forge.sh(이슈/PR/리뷰) · actions-wait.sh(CI 대기)
│   └── templates/  (e2e·mobile-*)
└── tools/transform.py                    # ai-devops → aiops 네임스페이스 전환(재현용)
```

## Forge 중립 (Gitea 네이티브, v1.1.0)

이슈·PR·리뷰·CI 대기 조작은 **`git origin` 리모트로 GitHub↔Gitea 를 자동 감지**하는 forge 중립 헬퍼로 수행한다. `gh` CLI 하드 의존을 제거했다.

- **`scripts/forge.sh`** — 실행형 CLI(소싱 금지). `forge.sh repo`, `issue-comment/comments/view/create/list/search/close`, `pr-create/list/view/diff/review/merge/url`. GitHub 이면 내부에서 `gh`, 그 외(Gitea)면 REST API(`/api/v1`).
- **`scripts/actions-wait.sh`** — CI/CD run 대기(`RUN_ID/RUN_URL/CONCLUSION` 계약).
- **Gitea 인증(CF Access 대응)**: `git credential fill` 토큰 → gitconfig `extraheader` 서비스토큰 → `cloudflared access token`(cf-access-token 헤더). Access 302 는 `/version` JSON 유무로 판정.
- **Gitea 특성**: 자기 PR APPROVE 불가 → `forge.sh pr-review APPROVE` 는 자동 COMMENT 강등. PR URL 은 `/{owner}/{repo}/pulls/N`(복수형). `setup` 은 `.gitea/workflows/` → `gitea-actions` 를 감지.
- 모바일 CI 템플릿은 `templates/mobile-ci/.gitea/workflows/`(iOS 는 self-hosted macOS 러너).

## 전제 조건

| 필요 | 용도 | 없으면 |
|---|---|---|
| Claude Code | 플러그인 호스트 | — |
| `git` | 워크트리·브랜치 조작 | `focus`·`unfocus` 불가 |
| `python3` | `forge.sh` 의 JSON 조립·파싱 | 이슈/PR 조작 전부 불가 |
| `curl` | Gitea REST API | Gitea 레포에서 이슈/PR 불가 |
| `gh` CLI (GitHub 레포만) | `forge.sh` 의 GitHub 경로 | GitHub 레포에서 이슈/PR 불가 |
| Node/npm·pytest 등 | QA 스킬이 호출하는 테스트 러너 | 해당 QA 스킬만 스킵 |

## 설치 (소비 프로젝트)

**두 가지 채널**이 있다. 팀이라면 핀을, 혼자 쓰며 늘 최신을 원하면 `latest` 를 고른다.

| 채널 | ref | 성격 |
|---|---|---|
| **고정 (권장)** | `#v1.3.2` | 그 커밋에 못 박힌다. 언제 무엇이 바뀌는지 팀이 통제한다 |
| **최신 추종** | `#latest` | 새 릴리스가 나오면 그 태그로 **이동하는 포인터**. 릴리스마다 재등록 없이 `update` 로 따라간다 |

```sh
# 1. 마켓플레이스 등록 — 고정(권장)
claude plugin marketplace add https://github.com/devworldltd/aiops.git#v1.3.2

# 또는 최신 추종
claude plugin marketplace add https://github.com/devworldltd/aiops.git#latest

# 2. 플러그인 활성화
claude plugin install aiops@aiops

# 3. 프로젝트 설정 생성(최초 1회) — 스택·프레임워크·CI 를 감지해
#    .claude/config.json(agent_hints) + .reviewer/profile.yaml 을 만든다
/aiops:setup
```

또는 프로젝트 `.claude/settings.json`(팀 공유, 첫 오픈 시 신뢰 프롬프트 1회):
```json
{
  "extraKnownMarketplaces": {
    "aiops": { "source": { "source": "git", "url": "https://github.com/devworldltd/aiops.git", "ref": "v1.3.0" } }
  },
  "enabledPlugins": { "aiops@aiops": true }
}
```

> ⚠️ **선언만으로는 로드되지 않는다.** `settings.json` 은 의도를 적을 뿐이고, 각자 머신에서 위 `install` 을 한 번 실행해야 실제로 붙는다.

### 업그레이드

**`#latest` 를 쓰는 경우** — 포인터가 이동하므로 재등록 없이 갱신한다:

```sh
claude plugin marketplace update aiops
claude plugin install aiops@aiops     # 새 version 이면 새 캐시 디렉토리로 설치된다
```

**버전을 핀한 경우** — `ref` 가 고정 태그면 `update` 로는 새 버전이 오지 않는다(그 태그는 움직이지 않으므로). **재등록**해야 한다:

```sh
claude plugin marketplace remove aiops
claude plugin marketplace add https://github.com/devworldltd/aiops.git#<새태그>
claude plugin install aiops@aiops
```

어느 쪽이든 **갱신됐는지 눈으로 확인**한다. 빼먹으면 `/reload-plugins` 가 정상 출력되면서 **스킬만 옛 내용(또는 0개)** 인 상태가 되고, 그건 실패처럼 보이지 않는다:

```sh
ls -d ~/.claude/plugins/cache/aiops/aiops/*/           # 설치된 버전들
ls ~/.claude/plugins/cache/aiops/aiops/<버전>/skills/ | wc -l    # 32
```

> 캐시 경로가 `plugin.json` 의 `version` 에서 나오기 때문에, **태그와 version 은 항상 함께 올라간다.**
> 어긋나면 새 태그를 받아도 옛 캐시 디렉토리를 재사용해 갱신이 조용히 실패한다.
> `tools/release.sh` 가 이 일치를 강제한다.

### `latest` 의 대가 (알고 쓸 것)

- **어느 커밋을 쓰고 있는지 이력으로 확인할 수 없다.** 고정 태그는 그 자체가 감사 기록이지만 `latest` 는 별칭이다. 사고 조사 때 "그때 무슨 버전이었나" 를 답하기 어렵다.
- **팀원 간 버전이 갈라진다.** 각자 `update` 한 시점이 다르면 서로 다른 스킬로 같은 워크플로를 돈다.
- 그래서 **프로젝트 `settings.json` 에는 고정 태그를 쓰고**(팀 공유 선언), 개인이 앞서 보고 싶을 때만 `latest` 를 쓰는 편을 권한다.

## 릴리스 (메인테이너)

태그 규약의 소유자는 **`tools/release.sh`** 다. 손으로 `git tag` 하지 않는다 — `latest` 이동을 잊으면 `#latest` 사용자가 낡은 버전을 최신이라 믿게 된다.

```sh
# 0) 버전 올림은 PR 로 main 에 먼저 머지한다 (plugin.json 의 version)
DRY=1 tools/release.sh v1.4.0     # 무엇이 나갈지 확인
tools/release.sh v1.4.0           # vX.Y.Z 생성 + latest 이동 + 푸시

tools/release.sh --sync-latest v1.3.2   # latest 가 드리프트했을 때 되맞추기
```

검사 항목: main 체크아웃 · 클린 트리 · `origin/main` 동기화 · **`plugin.json` version 과 태그 일치** · 태그 중복(릴리스는 언제나 새 태그로) · `LICENSE` 존재.

## 외부 사용자에게 — 알고 시작할 것

**① 이 레포는 공개 배포본이다.** 개발 정본은 사내 Gitea(비공개)이며, 여기에는 **릴리스 시점의 트리가 새 히스토리로** 게시된다. 이슈·PR 은 이 레포에서 받는다.

**② 기본 스택 가정이 남아 있다.** `/aiops:setup` 이 만든 `agent_hints` 로 에이전트는 적응하지만, 일부 스킬 본문은 아직 FastAPI·Alembic·pytest·Docker 를 기본값으로 서술한다(`devflow`·`qa-check`·`tech-spec` 등). 그 스택이 아니면 **해당 STEP 을 스킵하거나 범위를 좁혀야** 한다. 감지 기반으로 이미 정리된 스킬: `focus`·`unfocus`·`explain-app`.

**③ 문서·프롬프트는 한국어다.** 에이전트 산출물(PRD·기술 스펙·리뷰)도 한국어로 나온다.

**④ forge 는 GitHub·Gitea 양쪽에서 동작한다.** origin 리모트로 자동 감지하며, GitHub 이면 `gh` CLI 를 탄다.

## 사용

**전체 사용법은 [`docs/USAGE.md`](docs/USAGE.md)** — 의도·정책·결과물, 스킬/에이전트 전체 목록, 마커 인터페이스, 게이트, 설정 표면, 한계.

처음 시작하는 흐름만 옮기면:

```sh
/aiops:setup                 # 최초 1회 — 스택 감지 → config.json + profile.yaml
/aiops:focus <앱> 123        # 대상 워크트리 진입 (모노레포는 앱 축, 단일 레포는 이슈 축)
/aiops:devflow #123          # STEP 0~10: 기획 → 스펙 → E2E 골격 → 구현 → 배포 → QA → E2E → PR → 리뷰
/aiops:merge-pr 123          # dev 머지 + CI 대기 + deployed_sha 확인 + dev E2E
/aiops:merge-main            # dev → main 승격
/aiops:deploy-prod           # prod 검증 + 실패 시 자동 롤백
```

부분만 필요하면 단계 스킬을 직접 부른다 — `prd`·`tech-spec`·`qa-check`·`run-e2e`·`review-pr`·`verify-deploy`.
버그는 `bugflow`, 여러 이슈 순차는 `chainflow`, 모바일은 `mobileflow`, 문서는 `explain-app`.

**두 가지만 기억하면 된다**:
1. **`aiops:` 네임스페이스를 붙인다.** 맨 `/focus` 는 내장 화면 토글에 먹혀 조용히 아무 일도 안 한다.
2. **그린이 곧 검증됨이 아니다.** 각 게이트는 수치·판정 신호를 요구하고, 스킵은 사유와 함께 기록된다.

## 검증

- `claude plugin validate ./aiops` 통과 · 마켓플레이스 검증 통과.
- 실측: `/aiops:devflow` 로드 + `aiops:planning` 서브에이전트 실제 spawn·resolve 성공.

## 토큰

단일 플러그인 전체 로드 = always-on ~5,536 tok/세션. (필요 시 프로파일 분할은 크로스-플러그인 네임스페이스 결합을 감수해야 하므로 v1은 단순·견고 우선.)

## 재현

`tools/transform.py <aiops-plugin-dir>` — ai-devops 원본에서 네임스페이스 전환(멱등). 에이전트 참조(`aiops:`)·슬래시(`/aiops:`)·템플릿(`${CLAUDE_PLUGIN_ROOT}`)·frontmatter description 따옴표 처리.

## 라이선스

**Apache License 2.0** — 전문은 [`LICENSE`](LICENSE), 저작권 표시는 [`NOTICE`](NOTICE).

요약(법적 효력은 전문에 있다):

- 상업적 사용·수정·재배포·비공개 사용 **허용**
- **특허 허여 포함**(§3). 특허 소송을 제기하면 그 사용자의 특허 라이선스는 종료된다
- 재배포 시 **라이선스 사본 포함**, 수정한 파일에 **변경 표시**(§4b), `NOTICE` **보존**(§4d)
- 상표권은 허여하지 않는다(§6). 보증 없음·책임 제한(§7·§8)

기여하면 별도 합의가 없는 한 그 기여도 Apache-2.0 조건으로 제공된다(§5).
