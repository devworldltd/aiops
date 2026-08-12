---
name: e2e-test
description: "Playwright E2E 테스트 실행 — `--env=<local|dev|prod> --mode=<full|smoke>` 매트릭스 지원. qa-e2e 에이전트 호출 + 표준 출력 마지막 줄 캡처(E2E_RESULT/E2E_ENV_ERROR)."
---

Playwright 기반 E2E 테스트를 실행합니다. **local/dev/prod 3환경 × full/smoke 2모드 = 6셀 매트릭스**를 지원하며,
실제 테스트 실행은 `aiops:qa-e2e` 서브에이전트가 담당합니다. 본 스킬은 인자 파싱과 호출 프록시 역할을 합니다.

선행 문서: 이슈 #117 댓글의 📋 브리프 / 📝 PRD / ⚙️ 기술 스펙 §2(SKILL.md 변경 명세).

> **📢 사용 안내 (#131)**
>
> - 본 스킬은 **명시적 매개변수 호출 진입점** (저수준) 입니다 — `--env=`/`--mode=` 를 사용자가 직접 지정합니다.
> - **자동 환경 선택**을 원하면 `/aiops:run-e2e` 를 사용하세요 (현재 브랜치 기준 local/dev/prod 자동 감지 + 본 스킬 위임).
> - **배포 검증과 함께 실행**하려면 `/aiops:verify-deploy --env=dev|prod` 를 사용하세요 (Actions workflow_run 대기 + CF 헬스체크 + 본 스킬 호출).
> - devflow STEP 8 / `/aiops:merge-pr` 자동 dev E2E 는 **기본 SKIP** 으로 반전됨 (#131). `e2e_devflow_step8_enabled` / `e2e_run_on_merge_pr` config 토글로 활성화.

---

## 1. 인자 파싱

`$ARGUMENTS`에서 다음 패턴을 추출합니다.

| 인자 | 패턴 | 기본값 | 비고 |
|------|------|--------|------|
| `--env=<value>` | `local` \| `dev` \| `prod` | `dev` | 환경 선택 |
| `--mode=<value>` | `full` \| `smoke` | `full` | 시나리오 모드 |
| `#숫자` 또는 `숫자` | 정수 | (없음) | ISSUE_NUMBER (선택) |
| `--dry-run` | flag | `false` | 실제 실행 없이 해석 결과만 출력 |

### 파싱 의사 코드

```bash
# $ARGUMENTS 예시: "--env=dev --mode=smoke #117"
ARG_ENV=$(grep -oE -- '--env=[a-z]+'   <<<"$ARGUMENTS" | head -1 | cut -d= -f2)
ARG_MODE=$(grep -oE -- '--mode=[a-z]+' <<<"$ARGUMENTS" | head -1 | cut -d= -f2)
ARG_ISSUE=$(grep -oE '#?[0-9]+'        <<<"$ARGUMENTS" | head -1 | tr -d '#')
ARG_DRY=$(grep -qE -- '--dry-run'      <<<"$ARGUMENTS" && echo true || echo false)

# 기본값 (역호환 — AC-6: 인자 미지정 시 dev/full)
ENV="${ARG_ENV:-dev}"
MODE="${ARG_MODE:-full}"
ISSUE="${ARG_ISSUE:-}"
DRY_RUN="${ARG_DRY:-false}"
```

### 값 검증

- `ENV` ∉ {local, dev, prod} → 사용법 안내 후 종료 코드 2
- `MODE` ∉ {full, smoke} → 사용법 안내 후 종료 코드 2

```bash
case "$ENV"  in local|dev|prod) ;; *) echo "사용법: /aiops:e2e-test [--env=local|dev|prod] [--mode=full|smoke] [#이슈번호] [--dry-run]"; echo "E2E_ENV_ERROR=invalid_env:$ENV"; exit 2 ;; esac
case "$MODE" in full|smoke)    ;; *) echo "사용법: /aiops:e2e-test [--env=local|dev|prod] [--mode=full|smoke] [#이슈번호] [--dry-run]"; echo "E2E_ENV_ERROR=invalid_mode:$MODE"; exit 2 ;; esac
```

> 주: 본 스킬은 파싱·라우팅만 수행하고 더 엄격한 환경 검증(BLAST_RADIUS_GUARD, baseURL 빈 값, Playwright 설치 등 G3~G5)은 `aiops:qa-e2e` 에이전트가 수행합니다.

---

## 2. qa-e2e 에이전트 호출

**반드시 Agent 도구로 `aiops:qa-e2e` 서브에이전트를 호출합니다.** 파싱한 매개변수를 모두 명시적으로 전달합니다.

### 호출 프롬프트

```
qa-e2e 에이전트 호출 — Playwright E2E 실행

매개변수:
- --env=<ENV>             # local | dev | prod
- --mode=<MODE>           # full | smoke
- --issue=<ARG_ISSUE 또는 (없음)>
- --dry-run=<true|false>

요구사항:
1. 기술 스펙은 이슈 #117 댓글의 ⚙️ 기술 스펙(§1 agents/qa-e2e.md 변경 명세)을 그대로 따른다.
2. 사전 검증 게이트 G1~G5를 통과한 뒤에만 Playwright를 호출한다.
3. 결과 헤더는 라벨 매트릭스(M8) 6종 중 하나로 고정한다:
   - `## 🌐 로컬 E2E 결과 — full` / `## 🌐 로컬 E2E 결과 — smoke`
   - `## 🌐 Dev E2E 결과 — full`   / `## 🌐 Dev E2E 결과 — smoke`
   - `## 🌐 Prod E2E 결과 — full`  / `## 🌐 Prod E2E 결과 — smoke`
4. 종료 코드: 0=PASS / 1=FAIL / 2=환경 설정 오류.
5. 표준 출력 마지막 줄은 반드시 다음 중 하나로 끝나야 한다:
   - `E2E_RESULT=PASS`
   - `E2E_RESULT=FAIL`
   - `E2E_ENV_ERROR=<reason>`

실행 후 표준 출력 마지막 줄(E2E_RESULT 또는 E2E_ENV_ERROR)을 그대로 반환해줘.
```

---

## 3. 표준 출력 처리 (종료 코드 매핑)

`aiops:qa-e2e` 에이전트 출력의 마지막 줄을 검사하여 종료 코드를 결정합니다.

```bash
LAST_LINE=$(tail -n 1 <<<"$AGENT_OUTPUT")
echo "$LAST_LINE"

case "$LAST_LINE" in
  E2E_RESULT=PASS)    exit 0 ;;
  E2E_RESULT=FAIL)    exit 1 ;;
  E2E_ENV_ERROR=*)
    REASON="${LAST_LINE#E2E_ENV_ERROR=}"
    echo "환경 설정 오류: $REASON" >&2
    exit 2
    ;;
  *)
    echo "알 수 없는 출력 형식 (마지막 줄): $LAST_LINE" >&2
    exit 2
    ;;
esac
```

| 마지막 줄 | 종료 코드 | 의미 |
|-----------|-----------|------|
| `E2E_RESULT=PASS` | 0 | 전체 통과 (또는 dry-run 해석 성공) |
| `E2E_RESULT=FAIL` | 1 | 테스트 실패 (failed≥1 또는 timedOut≥1) |
| `E2E_ENV_ERROR=<reason>` | 2 | 환경 설정 오류 — 사유 표시 |

`<reason>` 예시:
- `invalid_env:<v>` / `invalid_mode:<v>`
- `empty_base_url:<env>`
- `blast_radius_guard_required` (prod 실행 시 가드 미설정)
- `playwright_not_installed`

---

## 4. 이슈 댓글 저장 흐름

- **`ISSUE_NUMBER`가 있는 경우**: `aiops:qa-e2e` 에이전트가 결과를 이슈 댓글로 등록합니다 (`forge.sh issue-comment $ISSUE "..."`).
  - forge 불가 폴백: `context/issue-<N>/09_e2e_test.md`
- **`ISSUE_NUMBER`가 없는 경우**: 터미널 출력만 수행하고, 필요 시 `context/e2e_test_<YYYYMMDD-HHMMSS>.md`에 저장합니다.

> 본 스킬은 댓글 등록을 직접 수행하지 않습니다. 저장 책임은 `aiops:qa-e2e` 에이전트가 가집니다.

---

## 5. 사용 예시

```bash
/aiops:e2e-test --env=local --mode=full #117      # 로컬 풀 회귀, 이슈 #117 결과 등록
/aiops:e2e-test --env=dev #117                    # Dev 환경 풀 회귀 (mode 기본값 = full)
/aiops:e2e-test --env=prod --mode=smoke #117      # Prod smoke (BLAST_RADIUS_GUARD 의무)
/aiops:e2e-test                                   # 기본값: --env=dev --mode=full (역호환)
/aiops:e2e-test --env=local --dry-run             # 해석 결과만 확인, 실제 실행 없음
```

### 후속 자동화 호출 예시 (계약 불변)

| 호출자 | 명령 |
|--------|------|
| 개발자 (수동) | `/aiops:e2e-test --env=local --mode=full #N` |
| devflow STEP 8 (#118) | `/aiops:e2e-test --env=local --mode=full #N` |
| merge-pr 자동 (#119) | `/aiops:e2e-test --env=dev --mode=smoke #N` |
| deploy-prod (#121) | `BLAST_RADIUS_GUARD=1 /aiops:e2e-test --env=prod --mode=smoke #N` |

### 3개 진입점 비교 (#131)

| 항목 | `/aiops:e2e-test` | `/aiops:run-e2e` | `/aiops:verify-deploy` |
|------|------------|-----------|------------------|
| 수준 | 저수준 (명시 매개변수) | 고수준 (자동 감지) | 통합 (배포 + E2E) |
| 환경 결정 | `--env=` 필수 명시 | 브랜치 자동 감지 | `--env=` 명시 (dev/prod) |
| Actions workflow_run 대기 | ❌ | ❌ | ✅ |
| CF 헬스체크 (deployed_sha 매칭) | ❌ | ❌ | ✅ |
| E2E 실행 (qa-e2e 호출) | ✅ | ✅ (위임) | ✅ |
| 결과 마커 등록 | qa-e2e | qa-e2e | qa-e2e + 배포 검증 헤더 |
| 권장 사용 시나리오 | 자동화/스크립트 | 개발자 일상 수동 호출 | 배포 직후 검증 |
| `BLAST_RADIUS_GUARD` 검사 | qa-e2e (G4) | run-e2e (사용자 안내) + qa-e2e | verify-deploy + qa-e2e |

---

## 6. 현재 제공된 인자

$ARGUMENTS

위 절차(1 → 2 → 3 → 4) 순서로 진행해줘.
