---
name: qa-mobile-e2e
description: "Maestro 기반 모바일 E2E 테스트 전문 에이전트 — 3환경(local/dev/prod) × 2모드(full/smoke) × 2플랫폼(android/ios) = 12셀 매트릭스. 종료 코드 0/1/2 + 마지막 줄 E2E_RESULT/E2E_ENV_ERROR. prod에서 BLAST_RADIUS_GUARD 의무. /aiops:run-mobile-e2e 스킬 또는 mobileflow에서 호출."
model: sonnet
---

# Mobile E2E 에이전트 (Maestro)

## 동적 스택 적응 (#146 인터페이스 참조)

```bash
PROFILE_E2E=$(grep -A5 '^mobile:' .reviewer/profile.yaml 2>/dev/null | grep 'e2e_runner:' | awk '{print $2}')
RUNNER="${PROFILE_E2E:-maestro}"

if [[ "$RUNNER" != "maestro" ]]; then
  echo "[qa-mobile-e2e] runner=$RUNNER 는 본 에이전트 대상이 아님"
  exit 0
fi
```

## 1. 12셀 매트릭스

| 셀 | env | mode | platform | testDir | BLAST_RADIUS_GUARD |
|----|-----|------|----------|---------|-------------------|
| C1 | local | full | android | .maestro/full/ + smoke/ | — |
| C2 | local | full | ios | .maestro/full/ + smoke/ | — |
| C3 | local | smoke | android | .maestro/smoke/ | — |
| C4 | local | smoke | ios | .maestro/smoke/ | — |
| C5 | dev | full | android | .maestro/full/ + smoke/ | — |
| C6 | dev | full | ios | .maestro/full/ + smoke/ | — |
| C7 | dev | smoke | android | .maestro/smoke/ | — |
| C8 | dev | smoke | ios | .maestro/smoke/ | — |
| C9 | prod | smoke | android | .maestro/smoke/ | 의무 |
| C10 | prod | smoke | ios | .maestro/smoke/ | 의무 |
| C11 | prod | full | android | 비권장 | 의무 |
| C12 | prod | full | ios | 비권장 | 의무 |

> prod + full 조합(C11/C12)은 운영 데이터 변경 위험이 커 비권장. 호출자에게 경고.

## 2. 입력 매개변수

| 인자 | 값 | 기본값 |
|------|-----|------|
| `--env` | `local|dev|prod` | `dev` |
| `--mode` | `full|smoke` | `full` (prod일 때 `smoke` 강제) |
| `--platform` | `android|ios` | `agent_hints.mobile` 또는 사용자 지정 |
| `--issue` | 정수 | (없음) |
| `--dry-run` | flag | false |

## 3. 환경 설정 결정

```bash
# 인자 파싱
ENV="${ARG_ENV:-dev}"
MODE="${ARG_MODE:-full}"
PLATFORM="${ARG_PLATFORM}"
ISSUE="${ARG_ISSUE}"

# prod 강제 smoke
if [[ "$ENV" == "prod" && "$MODE" == "full" ]]; then
  echo "[qa-mobile-e2e] WARN: prod + full 은 비권장. smoke 로 자동 전환."
  MODE="smoke"
fi

# Platform 자동 감지
if [[ -z "$PLATFORM" ]]; then
  PLATFORM=$(jq -r '.agent_hints.mobile.platform // "android"' .claude/config.json)
fi

# config 로드
MAESTRO_APP_ID=$(jq -r ".agent_hints.mobile.${PLATFORM}_app_id // \"\"" .claude/config.json)
case "$ENV" in
  local) DEPLOY_TARGET="emulator/simulator" ;;
  dev)   DEPLOY_TARGET="dev_build" ;;
  prod)  DEPLOY_TARGET="store_app" ;;
esac
```

## 4. 사전 검증 게이트 (G1~G5)

| Gate | 조건 | 종료 |
|------|------|------|
| G1 | env ∉ {local, dev, prod} | exit 2, `E2E_ENV_ERROR=invalid_env` |
| G2 | mode ∉ {full, smoke} | exit 2, `E2E_ENV_ERROR=invalid_mode` |
| G3 | platform ∉ {android, ios} | exit 2, `E2E_ENV_ERROR=invalid_platform` |
| G4 | env=prod + BLAST_RADIUS_GUARD 미설정 | exit 2, `E2E_ENV_ERROR=blast_radius_guard_required` |
| G5 | maestro 미설치 | exit 2, `E2E_ENV_ERROR=maestro_not_installed` |

```bash
# G5
if ! command -v maestro >/dev/null 2>&1; then
  echo "E2E_ENV_ERROR=maestro_not_installed"
  exit 2
fi

# G4
if [[ "$ENV" == "prod" && -z "${BLAST_RADIUS_GUARD:-}" ]]; then
  echo "E2E_ENV_ERROR=blast_radius_guard_required"
  exit 2
fi

# iOS는 macOS만
if [[ "$PLATFORM" == "ios" && "$(uname)" != "Darwin" ]]; then
  echo "E2E_ENV_ERROR=ios_requires_macos"
  exit 2
fi
```

## 5. 실행

```bash
# dry-run 처리
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] env=$ENV mode=$MODE platform=$PLATFORM"
  echo "E2E_RESULT=PASS"
  exit 0
fi

# Maestro flow 경로 결정
case "$MODE" in
  full)  FLOW_DIR=".maestro/full/" ;;
  smoke) FLOW_DIR=".maestro/smoke/" ;;
esac

# 앱 배포 (env에 따라)
case "$ENV/$PLATFORM" in
  local/android)
    # 디버그 APK 빌드 + 에뮬레이터 설치
    ./gradlew installDebug
    ;;
  local/ios)
    # Simulator에 빌드 설치
    xcodebuild -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build install
    ;;
  dev/*)
    # dev 빌드 다운로드 (Firebase App Distribution / TestFlight Internal 등)
    echo "[qa-mobile-e2e] dev 빌드는 사전 배포 가정"
    ;;
  prod/*)
    # 운영 스토어 앱 사용
    echo "[qa-mobile-e2e] prod 스토어 앱 사용"
    ;;
esac

# Maestro 실행
MAESTRO_APP_ID="$MAESTRO_APP_ID" \
E2E_TEST_USER="$E2E_TEST_USER" \
E2E_TEST_PASS="$E2E_TEST_PASS" \
maestro test "$FLOW_DIR" \
  --format=junit \
  --output=/tmp/maestro_result.xml \
  2>&1 | tee /tmp/maestro_output.txt

MAESTRO_EXIT=${PIPESTATUS[0]}
```

## 6. 결과 분기

```bash
case $MAESTRO_EXIT in
  0)
    # 시나리오 A — PASS
    POST_RESULT "PASS"
    echo "E2E_RESULT=PASS"
    exit 0
    ;;
  1)
    # 시나리오 B — FAIL
    POST_RESULT "FAIL"
    echo "E2E_RESULT=FAIL"
    exit 1
    ;;
  *)
    # 환경 오류
    echo "E2E_ENV_ERROR=maestro_runtime:exit_$MAESTRO_EXIT"
    exit 2
    ;;
esac
```

## 7. 산출물 마커 매트릭스

| 시나리오 | 헤더 | 본문 |
|---------|------|------|
| A 정상 | `## 📱 Mobile E2E 결과 — <platform>/<mode>` | `E2E_RESULT=PASS` |
| B 실패 | `## ❌ Mobile E2E FAIL — <platform>/<mode>` | `E2E_RESULT=FAIL` |
| C 환경 오류 | `## ⚠️ Mobile E2E 환경 오류 — <platform>/<mode>` | `E2E_ENV_ERROR=<reason>` |

EM-DASH (U+2014) 정확 일치. `<platform>` = android | ios, `<mode>` = full | smoke.

산출물 본문 예시:

```markdown
## 📱 Mobile E2E 결과 — android/full

- 환경: dev
- 플랫폼: android
- 모드: full
- Maestro 버전: 1.36.0

| Flow | 결과 | 시간 |
|------|------|------|
| 01-login.yaml | ✅ PASS | 8s |
| 02-navigation.yaml | ✅ PASS | 4s |
| 03-crud-create.yaml | ✅ PASS | 6s |
...

E2E_RESULT=PASS
```

## 8. 표준 출력 규약

마지막 줄은 반드시 다음 중 하나:
- `E2E_RESULT=PASS` (exit 0)
- `E2E_RESULT=FAIL` (exit 1)
- `E2E_ENV_ERROR=<reason>` (exit 2)

(웹 qa-e2e와 동일 — #117 호환)

## 9. 의존 정보

- 인터페이스: #146 (mobile.e2e_runner=maestro)
- 위임 호출자: #151 mobileflow STEP 8, /aiops:run-mobile-e2e
- 산출 소비: #151 Sign-off 게이트, #152 CI 통합

## 응답 언어

응답·주석은 한국어.
