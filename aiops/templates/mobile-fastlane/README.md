# Mobile Fastlane

Android (Play Store) + iOS (App Store / TestFlight) 자동 배포.

## 설치

```bash
# Android
cd android && bundle init && echo 'gem "fastlane"' >> Gemfile && bundle install

# iOS
cd ios && bundle init && echo 'gem "fastlane"' >> Gemfile && bundle install
```

## Lane 매트릭스

| Platform | internal | beta | production |
|----------|---------|------|----------|
| Android | Play Internal track | Play Beta (open testing) | Play Production (10% rollout) |
| iOS | TestFlight Internal | TestFlight External + Beta Testers | App Store + submit for review |

## 필요한 시크릿 (Gitea Actions)

> Gitea repo/org secrets 로 재등록한다 (Settings → Actions → Secrets). 아래 목록은 그대로.

### Android
- `PLAY_STORE_JSON_KEY_BASE64` — Play Console Service Account JSON (base64)
- `ANDROID_KEYSTORE_BASE64` — upload-key.jks (base64)
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

### iOS
- `APP_STORE_CONNECT_API_KEY_BASE64` — .p8 (base64)
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`
- `MATCH_PASSWORD` — Match 인증서 저장소 비밀번호
- `MATCH_GIT_BASIC_AUTHORIZATION` — 인증서 git 저장소 접근

## 사용

```bash
# 로컬
bundle exec fastlane internal
bundle exec fastlane beta
bundle exec fastlane production

# CI (Gitea Actions workflow_dispatch)
# 방법 1: Gitea 웹 UI → 레포 Actions 탭 → 워크플로 선택 → "Run workflow" 로 입력(track/lane) 지정 후 실행.
# 방법 2: Gitea REST API 로 디스패치 (GITEA_TOKEN 필요)
#   FORGE_HOST 는 이 레포의 forge 호스트 — `forge.sh web` 로 확인할 수 있다.
curl -X POST \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  "https://$FORGE_HOST/api/v1/repos/{owner}/{repo}/actions/workflows/mobile-release-android.yml/dispatches" \
  -d '{"ref":"main","inputs":{"track":"internal"}}'

curl -X POST \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  "https://$FORGE_HOST/api/v1/repos/{owner}/{repo}/actions/workflows/mobile-release-ios.yml/dispatches" \
  -d '{"ref":"main","inputs":{"lane":"internal"}}'
```
