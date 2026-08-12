---
name: mobileflow
description: "모바일 앱(Android/iOS/RN/Flutter) 전용 워크플로우. devflow의 모바일판 — 10 STEP 미러링. profile.yaml.mobile.framework에 따라 에이전트 자동 분기. /aiops:devflow가 platform=mobile|both 감지 시 자동 위임, 또는 사용자가 직접 호출."
---

# /aiops:mobileflow

웹 devflow와 평행 구조의 모바일 전용 워크플로우. 동일한 10 STEP, Sign-off 게이트 #1/#2, FAIL 재실행 루프를 가지되 모든 단계가 모바일 컨텍스트로 동작.

> 🔗 분기 진입: `/aiops:devflow #N`이 platform=mobile|both 감지 시 자동 호출 (#151). 단독 호출도 가능.

---

## 모드 감지

`$ARGUMENTS` 에서 이슈 번호 추출 (#?\d+). 단일/배치 모드 동작은 /aiops:devflow와 동일.

---

## 워크플로우 lock 관리 (#176)

devflow와 동일 패턴 — STEP 0 직후 `.claude/.devflow.lock` 작성, 종료/취소 시 제거. workflow 필드만 `"mobileflow"` 로 구분.

```bash
trap 'rm -f .claude/.devflow.lock' EXIT INT TERM
cat > .claude/.devflow.lock <<EOF
{ "workflow": "mobileflow", "issue": $ISSUE_NUMBER, "branch": "feature/issue-$ISSUE_NUMBER",
  "step": 0, "started_at": "$(date -u +%FT%TZ)", "pid": $$ }
EOF
```

상세: devflow SKILL.md "워크플로우 lock 관리" 절 참조.

---

## 플랫폼 사전 검사

```bash
PROFILE_FW=$(grep -A5 '^mobile:' .reviewer/profile.yaml 2>/dev/null | grep 'framework:' | awk '{print $2}')
HINTS_FW=$(jq -r '.agent_hints.mobile.framework // empty' .claude/config.json 2>/dev/null)
FRAMEWORK="${HINTS_FW:-${PROFILE_FW:-android-native}}"

case "$FRAMEWORK" in
  android-native|ios-native|react-native|flutter) ;;
  *) echo "ERROR: 지원하지 않는 framework=$FRAMEWORK"; exit 2 ;;
esac

echo "[mobileflow] framework=$FRAMEWORK"
```

---

## STEP 0~3 — devflow와 동일

- STEP 0: 브랜치 (devflow에서 진입 시 이미 완료)
- STEP 1: 브리프 (오케스트레이터)
- STEP 2: PRD + 와이어프레임 (`aiops:planning`)
- STEP 3: 기술 스펙 (`dev`) — 본문에 "## E2E 검증 시나리오" 절 의무

> 산출물 헤더는 devflow와 완전히 동일 (📋 / 📝 / 🖼️ / ⚙️).

---

## STEP 4 — Mobile E2E 코드 골격 (Maestro)

웹 dev-e2e가 Playwright를 생성하듯, 모바일은 ${CLAUDE_PLUGIN_ROOT}/templates/mobile-e2e/ 골격을 대상 프로젝트로 복사.

호출 패턴 (Agent 도구):
```
Agent("qa-mobile-e2e", "--prep-only --issue=<N>")
```

또는 dev-e2e 에이전트의 모바일 분기 (profile.yaml에서 e2e_runner=maestro 감지 시 maestro 골격 생성).

수행 내용:
1. Q5 보호: 기존 `.maestro/` 존재 시 골격 생성 스킵 + hint 작성
2. ${CLAUDE_PLUGIN_ROOT}/templates/mobile-e2e/.maestro/ 골격 13개 파일을 대상 프로젝트 .maestro/로 복사
3. README.md / _gitignore.append 안내

산출물 헤더:
- `## 🧪 Mobile E2E 시나리오`
- `## 🧪 Mobile E2E 코드 작성 완료`

context fallback: `04_mobile_e2e_plan.md` + `05_mobile_e2e_scaffold.md`

---

## STEP 5 — 모바일 구현 (framework별 분기)

dev-mobile-* 에이전트를 framework에 따라 호출:

| framework | 에이전트 | 산출물 헤더 |
|-----------|---------|-----------|
| android-native | `aiops:dev-mobile-android` | `## 📱 Android 구현 완료` |
| ios-native | `aiops:dev-mobile-ios` | `## 📱 iOS 구현 완료` |
| react-native | `aiops:dev-mobile-rn` | `## 📱 React Native 구현 완료` |
| flutter | `aiops:dev-mobile-flutter` | `## 📱 Flutter 구현 완료` |

dev-designer도 병렬 호출 (UI 컴포넌트 스펙):
- `## 🎨 컴포넌트 스펙` (devflow와 동일)

단위 테스트 의무화 (#147/#148 에이전트 본문 명시):
- Android: JUnit / iOS: XCTest / RN: Jest / Flutter: flutter_test

context fallback: `06_mobile_done.md` (또는 framework별 분리)

---

## STEP 6 — 모바일 빌드/배포

framework별 빌드 명령:

| framework | 빌드 명령 |
|-----------|---------|
| android-native | `./gradlew assembleDebug` |
| ios-native | `xcodebuild -scheme App build` (macOS) |
| react-native | `npx react-native run-android` or `run-ios` |
| flutter | `flutter build apk` / `flutter build ios --no-codesign` |

dev-devops 에이전트가 빌드 + 시뮬레이터/에뮬레이터 띄우기 + 로그 확인.

산출물 헤더: `## 🚢 모바일 빌드 완료`
context fallback: `07_mobile_build.md`

---

## STEP 7 — Mobile Unit QA (Sign-off 게이트 #1)

`/aiops:qa-mobile` 스킬 호출 (또는 framework별 qa-mobile-* 에이전트 직접 호출).

| framework | 호출 | Sign-off 기준 |
|-----------|------|-------------|
| android-native | qa-mobile-android | FAILED=0 |
| ios-native | qa-mobile-ios (macOS) | FAILED=0 |
| react-native | npm test | FAILED=0 |
| flutter | flutter test | FAILED=0 |

산출물 헤더:
- PASS: `## ✅ Mobile QA Sign-off`
- FAIL: `## ❌ Mobile QA FAIL`

FAIL 재실행 루프: dev-mobile-* 재호출 → STEP 6 재빌드 → STEP 7 재QA.

context fallback: `08_mobile_qa_signoff.md`

---

## STEP 8 — Mobile E2E (Maestro, config 토글)

`/aiops:run-mobile-e2e` 또는 `aiops:qa-mobile-e2e` 직접 호출.

### 8-0. config 토글 게이트 (#131 일관)

```bash
STEP8_ENABLED=$(jq -r '.e2e_devflow_step8_enabled // false' .claude/config.json)

if [[ "$STEP8_ENABLED" != "true" ]]; then
  # SKIP 마커 등록 (게이트 #2 통과)
  forge.sh issue-comment "$ISSUE" "## 📱 Mobile E2E 결과 — $PLATFORM/full

E2E_RESULT=SKIPPED

- 사유: e2e_devflow_step8_enabled=false
- 수동 실행: /aiops:run-mobile-e2e #$ISSUE 또는 maestro test .maestro/"
  goto STEP_9
fi
```

### 8-1. 실행 (활성 시)

```
/aiops:run-mobile-e2e --env=local --mode=full --platform=$PLATFORM #$ISSUE
```

종료 코드 0/1/2 + 마지막 줄 E2E_RESULT 규약은 #150과 동일.

### Sign-off 게이트 #2
- PASS → STEP 9
- FAIL → 재실행 루프 (최대 3회)
- 환경 오류 → 가이드 표시 후 차단

산출물 헤더: `## 📱 Mobile E2E 결과 — <platform>/full`
context fallback: `09_mobile_local_e2e.md`

---

## STEP 9 — PR 생성 (`aiops:dev-pr` 재사용)

devflow와 동일 — feature/issue-N → dev PR + `Closes #N`.

산출물 헤더: `## 🚀 PR 생성 완료`
context fallback: `10_pr.md`

---

## STEP 10 — PR 리뷰 (`/aiops:review-pr` 재사용)

devflow와 동일. APPROVE/REQUEST_CHANGES/COMMENT.

REQUEST_CHANGES → STEP 6 재빌드 → STEP 7 재QA → STEP 8 재E2E → STEP 9/10 재실행.

context fallback: `11_review.md`

---

## 전체 흐름 요약

```
STEP 0    오케스트레이터  feature/issue-N 브랜치 (devflow와 공유)
STEP 1    오케스트레이터  브리프 (📋)
STEP 2    [planning]      PRD + 와이어프레임 (📝 🖼️)
STEP 3    [dev]           기술 스펙 (⚙️) — E2E 검증 시나리오 절 의무
STEP 4    [qa-mobile-e2e] Maestro E2E 골격 (🧪)
STEP 5    [dev-designer + dev-mobile-<fw>]  컴포넌트 스펙 + 모바일 구현 (🎨 📱)
STEP 6    [dev-devops]    빌드/에뮬레이터 (🚢)
STEP 7    /aiops:qa-mobile      framework별 Unit QA (✅/❌ 게이트 #1)
STEP 8    /aiops:run-mobile-e2e Mobile E2E (📱 게이트 #2, config 토글)
STEP 9    [dev-pr]        PR 생성 (🚀)
STEP 10   /aiops:review-pr      PR 리뷰 (🔍)
```

## 헤더 매트릭스 (devflow와 차이)

| STEP | devflow (웹) | mobileflow (모바일) |
|------|-------------|-------------------|
| 4 | 🧪 E2E 시나리오 + 코드 작성 완료 | 🧪 Mobile E2E 시나리오 + 코드 작성 완료 |
| 5 | 🎨 + 🔧 + 💻 | 🎨 + 📱 Android/iOS/RN/Flutter 구현 완료 |
| 6 | 🚢 배포 완료 | 🚢 모바일 빌드 완료 |
| 7 | ✅ Unit QA Sign-off | ✅ Mobile QA Sign-off |
| 8 | 🌐 로컬 E2E 결과 — full | 📱 Mobile E2E 결과 — <platform>/full |

## 의존 정보

- 인터페이스: #146 (platform/mobile 스키마), #147~#150 (에이전트/스킬 전체)
- 호출자: /aiops:devflow (platform=mobile|both 시 자동), 사용자 직접
- 후속 소비: #152 (CI), #153 (문서)

---

현재 제공된 인자: $ARGUMENTS

위 절차대로 STEP 0부터 진행해줘.
