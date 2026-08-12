# Mobile E2E (Maestro)

크로스 플랫폼 모바일 E2E 테스트 — Android + iOS 동일 YAML.

## 설치

```bash
# Maestro 설치
curl -Ls "https://get.maestro.mobile.dev" | bash
export PATH="$PATH":"$HOME/.maestro/bin"
maestro --version
```

## 실행

```bash
# Android 에뮬레이터/디바이스에 앱 설치 후
maestro test .maestro/full/01-login.yaml

# 전체 full 실행
maestro test .maestro/full/

# smoke 실행
maestro test .maestro/smoke/
```

## 환경변수

- `MAESTRO_APP_ID`: Android 패키지명 또는 iOS Bundle ID
- `E2E_TEST_USER`, `E2E_TEST_PASS`: 테스트 계정
- `BLAST_RADIUS_GUARD`: prod 환경에서 의무 (`1` 설정)

## 디렉토리

- `full/`: 전체 시나리오 (local/dev 환경)
- `smoke/`: 최소 시나리오 (prod 환경, read-only 권장)
