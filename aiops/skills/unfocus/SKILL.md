---
name: unfocus
description: /aiops:focus 로 진입한 작업 워크트리에서 나와 원래 디렉토리로 복귀한다. "워크트리 나가기", "focus 끝", "집중 그만", "이 워크트리 정리하고 나가기", "/aiops:unfocus" 같은 프롬프트에서 트리거.
---

# /aiops:unfocus — 작업 워크트리 진출

`/aiops:focus`(EnterWorktree)로 진입한 워크트리에서 나와 원래 작업 디렉토리로 돌아간다.
`ExitWorktree` 네이티브 도구로 수행한다.

> `ExitWorktree` 는 **이 세션에서 EnterWorktree 로 진입한 워크트리에만** 작용한다.
> 진입한 적 없으면 no-op(안내만) — 손으로 만든 워크트리나 이전 세션의 것은 건드리지 않는다.

## 판정 — keep vs remove

사용자 표현으로 동작을 정한다. **기본은 `keep`(안전, 작업 보존)**.

| 사용자 의도 | action |
|---|---|
| "나가기", "focus 끝", "집중 그만", "돌아가기", 그냥 진출 | `keep` (디렉토리·브랜치 유지) |
| "정리하고 나가기", "삭제", "지우고 나가기", "remove", 작업 폐기 | `remove` |

## STEP 1 — 진출 실행

- 기본: `ExitWorktree` `action="keep"`.
- 제거 요청 시: `ExitWorktree` `action="remove"`.
  - 미커밋 변경/미병합 커밋이 있으면 도구가 목록과 함께 거부한다. 그 목록을 **사용자에게 보여주고 확인**받은
    뒤에만 `discard_changes=true` 로 재호출한다. **임의로 폐기하지 않는다.**
  - 폐기 판단 전에 그 파일이 **어디에 정본이 있는지** 확인한다. 워크플로 폴백 산출물(`context/*.md` 등)은
    이슈/PR 에 이미 같은 내용이 있어 버려도 되는 경우가 많지만, 그 확인 없이 지우면 작업을 잃는다.

## STEP 2 — 확인

- keep: "원래 디렉토리로 복귀했습니다. 워크트리(`<경로>`)와 브랜치는 유지 — `/aiops:focus <대상>` 으로 재진입 가능."
- remove: "워크트리와 브랜치를 삭제하고 복귀했습니다."
- no-op: "현재 EnterWorktree 세션이 아닙니다. 진출할 워크트리가 없습니다."
  + 필요하면 `git worktree list` 로 수동 정리 안내(머지 완료 브랜치의 워크트리는 `git worktree remove` 로 정리).
