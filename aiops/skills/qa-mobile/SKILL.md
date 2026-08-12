---
name: qa-mobile
description: "모바일 통합 QA 오케스트레이터 — agent_hints.mobile.framework에 따라 4 프레임워크 라우팅 (android-native → qa-mobile-android, ios-native → qa-mobile-ios, react-native → npm test, flutter → flutter test). mobileflow STEP 7에서 자동 호출되거나 단독 실행 가능."
---

# /aiops:qa-mobile — 모바일 통합 QA

웹의 `/aiops:qa-check` (be + fe + admin 병렬)에 해당하는 모바일판. 4 프레임워크 중 하나 또는 다중을 라우팅한다.

## 인자

- `--platform=<android|ios|all>` (선택) — 명시적 플랫폼 선택. 미지정 시 profile.yaml의 mobile.framework 사용
- `#<ISSUE_NUMBER>` (선택) — 이슈 댓글 등록 대상

```bash
ARG_PLATFORM=$(grep -oE -- '--platform=[a-z]+' <<<"$ARGUMENTS" | head -1 | cut -d= -f2)
ARG_ISSUE=$(grep -oE '#?[0-9]+' <<<"$ARGUMENTS" | head -1 | tr -d '#')
```

## 라우팅 결정

```bash
# profile.yaml 또는 agent_hints에서 framework 결정
HINTS_FW=$(jq -r '.agent_hints.mobile.framework // empty' .claude/config.json 2>/dev/null)
PROFILE_FW=$(grep -A5 '^mobile:' .reviewer/profile.yaml 2>/dev/null | grep 'framework:' | awk '{print $2}')

# framework 가 배열인 경우 (platform=both 또는 다중 네이티브) 모두 실행
FRAMEWORKS=()
if [[ -n "$HINTS_FW" ]]; then
  FRAMEWORKS=("$HINTS_FW")
elif [[ -n "$PROFILE_FW" ]]; then
  FRAMEWORKS=("$PROFILE_FW")
fi

# --platform 인자 우선
if [[ -n "$ARG_PLATFORM" ]]; then
  case "$ARG_PLATFORM" in
    android) FRAMEWORKS=("android-native") ;;
    ios)     FRAMEWORKS=("ios-native") ;;
    all)     FRAMEWORKS=("android-native" "ios-native") ;;
  esac
fi
```

## 실행 매트릭스

각 프레임워크에 따라 다음 에이전트/명령으로 라우팅:

| framework | 호출 방식 | 산출물 헤더 |
|-----------|---------|-----------|
| `android-native` | Agent `aiops:qa-mobile-android` | `## 📱 Mobile QA 결과 — android-native` |
| `ios-native` | Agent `aiops:qa-mobile-ios` (macOS 필수) | `## 📱 Mobile QA 결과 — ios-native` |
| `react-native` | `cd $PROJECT_ROOT && npm test` | `## 📱 Mobile QA 결과 — react-native` |
| `flutter` | `cd $PROJECT_ROOT && flutter test` | `## 📱 Mobile QA 결과 — flutter` |

### React Native 직접 실행 예시

```bash
cd "$PROJECT_ROOT"
npm test 2>&1 | tee /tmp/rn_test.txt
EXIT_CODE=${PIPESTATUS[0]}

# Jest 결과 파싱
FAILED=$(grep -oE "Tests:.*[0-9]+ failed" /tmp/rn_test.txt | grep -oE "[0-9]+ failed" | grep -oE "[0-9]+" | head -1)
FAILED=${FAILED:-0}
PASSED=$(grep -oE "[0-9]+ passed" /tmp/rn_test.txt | grep -oE "[0-9]+" | head -1)
```

### Flutter 직접 실행 예시

```bash
cd "$PROJECT_ROOT"
flutter test --reporter=expanded 2>&1 | tee /tmp/flutter_test.txt
EXIT_CODE=${PIPESTATUS[0]}

# flutter test 결과 파싱
FAILED=$(grep -oE "[0-9]+ -[0-9]+:[0-9]+ \+[0-9]+ -[0-9]+" /tmp/flutter_test.txt | tail -1 | grep -oE "\-[0-9]+$" | tr -d '-')
FAILED=${FAILED:-0}
```

## Sign-off 게이트

다중 프레임워크 실행 시 **모두 PASS**여야 종합 Sign-off:

```bash
TOTAL_FAILED=0
RESULTS_TABLE=""

for fw in "${FRAMEWORKS[@]}"; do
  # 각 프레임워크 실행 (위 매트릭스)
  case "$fw" in
    android-native) # Agent 호출 ;;
    ios-native)     # Agent 호출 ;;
    react-native)   # npm test ;;
    flutter)        # flutter test ;;
  esac

  if [[ "$FW_FAILED" != "0" ]]; then
    TOTAL_FAILED=$((TOTAL_FAILED + FW_FAILED))
  fi

  RESULTS_TABLE="$RESULTS_TABLE\n| $fw | $FW_PASSED | $FW_FAILED | $([[ $FW_FAILED == 0 ]] && echo ✅ PASS || echo ❌ FAIL) |"
done

if [[ "$TOTAL_FAILED" == "0" ]]; then
  HEADER="## ✅ Mobile QA Sign-off"
  RESULT="PASS"
else
  HEADER="## ❌ Mobile QA FAIL"
  RESULT="FAIL"
fi
```

## 산출물

```markdown
## ✅ Mobile QA Sign-off

### 프레임워크별 결과
| Framework | Passed | Failed | 판정 |
|-----------|-------:|-------:|:----:|
| android-native | 6 | 0 | ✅ PASS |
| ios-native | 4 | 0 | ✅ PASS |

### 종합
- 전체 PASSED: 10
- 전체 FAILED: 0
- 종합 판정: ✅ PASS → STEP 8 진입 허용 (mobileflow)
```

저장:
- GitHub: 이슈 댓글 (`## ✅ Mobile QA Sign-off` 또는 `## ❌ Mobile QA FAIL`)
- GitHub 불가: `context/issue-<N>/08_qa_mobile_signoff.md`

## 사용 예시

```bash
# 명시적 호출 (전체 — profile.yaml 기반)
/aiops:qa-mobile #N

# Android만
/aiops:qa-mobile --platform=android #N

# iOS만
/aiops:qa-mobile --platform=ios #N

# 양쪽 모두
/aiops:qa-mobile --platform=all #N

# 자동 호출 (mobileflow STEP 7 — #151에서 도입)
```

## /aiops:qa-check 와의 관계

| 항목 | /aiops:qa-check (웹) | /aiops:qa-mobile (모바일) |
|------|---------------|--------------------|
| 대상 | backend + frontend + admin | android + ios + RN + flutter (라우팅) |
| 병렬 | be/fe/admin 동시 | android/ios 동시 가능 |
| Sign-off | 모두 FAILED=0 | 모든 프레임워크 FAILED=0 |
| 호출 시점 | devflow STEP 7 | mobileflow STEP 7 (#151) |

## 환경 요구사항

| Framework | 요구 환경 |
|-----------|---------|
| android-native | JDK 17+, Android SDK, Gradle |
| ios-native | macOS, Xcode 15+, iOS Simulator |
| react-native | Node 18+, npm/yarn |
| flutter | Flutter SDK |

## 의존 정보

- 인터페이스: #146 (mobile.framework 4값)
- 위임 에이전트: #149 (qa-mobile-android, qa-mobile-ios) — 본 이슈에서 작성
- 호출자: #151 (mobileflow STEP 7)

---

현재 제공된 인자: $ARGUMENTS

위 절차대로 진행해줘.
