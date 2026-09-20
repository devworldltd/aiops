#!/usr/bin/env python3
"""서명된 AAB 를 Google Play 트랙에 업로드한다.

`ScanBarcode/scripts/play_upload.py` 를 일반화한 것이다. 앱 이름 하드코딩을 없애고
공통 기반(`store_common.py`)의 결정을 따른다.

  python3 play_upload.py --slug zen-koi --root ~/src/game/zen-koi --dry-run
  python3 play_upload.py --slug zen-koi --track internal

자격증명은 KMS 에서 조회한다(`PLAY_SERVICE_ACCOUNT_JSON`, scope=org). 값은 출력하지 않는다.

**불가역 경계**: `--dry-run` 은 편집 세션을 열었다 버려 접근만 확인한다. 그 외에는
**실제로 트랙에 반영한다** — 되돌릴 수 없다.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import store_common as sc  # noqa: E402

SECRET_KIND = "PLAY_SERVICE_ACCOUNT_JSON"
HANDOFF_ITEM = "play_service_account"
SCOPES = ["https://www.googleapis.com/auth/androidpublisher"]


def _client(service_account: dict):
    try:
        from google.oauth2 import service_account as sa_module
        from googleapiclient.discovery import build
    except ImportError:
        sys.exit("❌ 패키지 없음: pip install google-auth google-api-python-client")
    creds = sa_module.Credentials.from_service_account_info(service_account, scopes=SCOPES)
    return build("androidpublisher", "v3", credentials=creds, cache_discovery=False)


# --------------------------------------------------------------------------- 대상 판정

def detect_package_name(root: Path, explicit: str | None) -> str:
    if explicit:
        return explicit
    for f in sorted(root.glob("**/build.gradle.kts")) + sorted(root.glob("**/build.gradle")):
        if "/build/" in str(f) or "/node_modules/" in str(f):
            continue
        m = re.search(r'applicationId\s*=?\s*"([A-Za-z0-9._]+)"',
                      f.read_text(encoding="utf-8", errors="replace"))
        if m:
            return m.group(1)
    sys.exit("❌ packageName 을 찾을 수 없습니다. --package-name 으로 지정하세요.")


def detect_aab(root: Path, explicit: Path | None) -> Path:
    if explicit:
        return explicit if explicit.is_absolute() else root / explicit
    hits = sorted(root.glob("**/build/outputs/bundle/release/*.aab"))
    if hits:
        return hits[0]
    return root / "android/app/build/outputs/bundle/release/app-release.aab"


def release_notes(portal: Path | None, slug: str, lang: str) -> str | None:
    """app-portal 의 content/<slug>/releases.json 최신 Android 릴리스에서 노트를 만든다.

    `/aiops:app-pages` 가 만드는 그 파일이다. 같은 정본을 쓴다.
    """
    if not portal:
        return None
    source = portal / f"content/{slug}/releases.json"
    if not source.is_file():
        return None
    doc = json.loads(source.read_text(encoding="utf-8"))
    for entry in doc.get("releases", []):
        if entry.get("platforms", {}).get("android"):
            key = lang.split("-")[0]
            picked = [c.get(lang) or c.get(key) or c.get("ko", "") for c in entry.get("changes", [])]
            picked = [p for p in picked if p]
            if picked:
                return "\n".join(f"• {line}" for line in picked)
    return None


# --------------------------------------------------------------------------- 접근·업로드

def verify_access(service_account: dict, package_name: str) -> None:
    """편집 세션을 열었다 바로 버려 인증과 앱 권한을 확인한다. **아무것도 바꾸지 않는다.**"""
    from googleapiclient.errors import HttpError
    edits = _client(service_account).edits()
    try:
        edit_id = edits.insert(body={}, packageName=package_name).execute()["id"]
    except HttpError as e:
        status = e.resp.status
        hint = {
            401: "인증 실패 — 서비스 계정 키를 확인하세요.",
            403: f"권한 없음 — Play Console > 사용자 및 권한에서 이 서비스 계정에 "
                 f"{package_name} 앱 권한(앱 정보 보기 + 트랙 게시)을 부여했는지 확인하세요. "
                 "또는 Google Play Android Developer API 가 사용 설정되지 않았을 수 있습니다.",
            404: f"앱을 찾을 수 없음 — packageName={package_name} 확인 필요. 신규 출시라면 "
                 "Play Console 에서 앱 레코드를 먼저 만들어야 합니다.",
        }.get(status, "")
        sys.exit(f"❌ Play API 접근 실패 (HTTP {status}). {hint}")
    edits.delete(editId=edit_id, packageName=package_name).execute()
    print(f"✅ Play API 접근 확인 — {package_name} 편집 권한 있음")


def upload(service_account: dict, package_name: str, aab: Path,
           track: str, notes: str | None, notes_lang: str) -> None:
    from googleapiclient.http import MediaFileUpload
    edits = _client(service_account).edits()

    edit_id = edits.insert(body={}, packageName=package_name).execute()["id"]
    print(f"편집 세션 생성: {edit_id}")

    bundle = edits.bundles().upload(
        editId=edit_id, packageName=package_name,
        media_body=MediaFileUpload(str(aab), mimetype="application/octet-stream", resumable=True),
    ).execute()
    version_code = bundle["versionCode"]
    print(f"업로드 완료: versionCode {version_code}")

    release: dict = {"versionCodes": [version_code], "status": "completed"}
    if notes:
        release["releaseNotes"] = [{"language": notes_lang, "text": notes}]

    edits.tracks().update(editId=edit_id, track=track, packageName=package_name,
                          body={"track": track, "releases": [release]}).execute()
    print(f"트랙 반영: {track}")

    edits.commit(editId=edit_id, packageName=package_name).execute()
    print(f"✅ 출시 완료 — {track} 트랙에 versionCode {version_code}")


def main() -> int:
    ap = argparse.ArgumentParser(description="서명된 AAB 를 Play 트랙에 업로드합니다.")
    ap.add_argument("--slug", required=True, help="KMS service · app-portal content 의 앱 슬러그")
    ap.add_argument("--root", type=Path, default=Path.cwd(), help="대상 레포 루트")
    ap.add_argument("--package-name", help="생략 시 build.gradle 의 applicationId 에서")
    ap.add_argument("--aab", type=Path, help="생략 시 build/outputs/bundle/release 에서 탐색")
    ap.add_argument("--track", default="internal",
                    choices=["internal", "alpha", "beta", "production"])
    ap.add_argument("--portal", type=Path, help="app-portal 경로 (릴리즈 노트 출처)")
    ap.add_argument("--notes-lang", default="ko-KR")
    ap.add_argument("--no-notes", action="store_true", help="릴리즈 노트를 넣지 않습니다")
    ap.add_argument("--dry-run", action="store_true", help="자격증명·AAB 확인만 하고 종료")
    args = ap.parse_args()

    root = args.root.resolve()
    package_name = detect_package_name(root, args.package_name)
    aab = detect_aab(root, args.aab)
    if not aab.exists():
        sys.exit(f"❌ AAB 없음: {aab}\n   먼저 ./gradlew bundleRelease 로 서명 빌드를 만드세요.")

    res = sc.kms_fetch(root, args.slug, SECRET_KIND, required=("client_email", "private_key"))
    if not res.ok:
        print(res.handoff(HANDOFF_ITEM, "kms"), file=sys.stderr)
        sys.exit(f"❌ 자격증명을 얻지 못했습니다 ({res.status}).")
    if res.legacy:
        print(f"⚠️  이관 전 형식으로 찾았습니다: {res.name}@{res.service} — 공용으로 옮겨야 합니다.")
    account = res.value
    print(f"✅ KMS 에서 서비스 계정 확인 ({res.name}@{res.service}, "
          f"client_email={account.get('client_email', '?')})")
    print(f"✅ 대상: {package_name} / AAB {aab} ({aab.stat().st_size / 1_048_576:.1f} MB)")

    notes = None if args.no_notes else release_notes(args.portal, args.slug, args.notes_lang)
    if notes:
        print(f"릴리즈 노트 ({args.notes_lang}):\n{notes}")
    elif not args.no_notes:
        print("ℹ️  릴리즈 노트 없음 — --portal 경로와 content/<slug>/releases.json 을 확인하세요.")

    if args.dry_run:
        verify_access(account, package_name)
        print("dry-run — 업로드하지 않고 종료합니다.")
        return 0

    upload(account, package_name, aab, args.track, notes, args.notes_lang)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
