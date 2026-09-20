#!/usr/bin/env python3
"""iOS 앱을 아카이브해 App Store Connect 에 업로드한다.

`ScanBarcode/scripts/appstore_upload.py` 를 일반화한 것이다. 앱 이름 하드코딩을 없애고
공통 기반(`store_common.py`)의 결정을 따른다.

  python3 appstore_upload.py --slug zen-koi --root ~/src/game/zen-koi --dry-run
  python3 appstore_upload.py --slug zen-koi --archive-only
  python3 appstore_upload.py --slug zen-koi

자격증명은 KMS 에서 조회한다(`APPSTORE_API_KEY_JSON`, scope=org). 값은 출력하지 않는다.

**불가역 경계** — 되돌릴 수 있는 단계와 없는 단계를 나눠 두었다.

  --dry-run       자격증명·접근만 확인            되돌릴 수 있음
  --archive-only  빌드까지만                      되돌릴 수 있음
  --export-only   ipa 를 로컬에 내보내기까지만    되돌릴 수 있음
  (없음)          **실제로 업로드한다**           되돌릴 수 없음

디스크의 ExportOptions 는 `destination=export` 다. 업로드할 때만 메모리에서 `upload` 로 바꿔
임시 파일로 넘기므로 **파일은 그대로 남는다.**
"""
from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import store_common as sc  # noqa: E402

SECRET_KIND = "APPSTORE_API_KEY_JSON"
HANDOFF_ITEM = "appstore_api_key"


# --------------------------------------------------------------------------- 대상 판정

def detect_project(root: Path, explicit: Path | None) -> Path:
    """.xcodeproj 를 찾는다. XcodeGen 레포는 생성물이라 없을 수 있다."""
    if explicit:
        return explicit if explicit.is_absolute() else root / explicit
    found = sorted(p for p in root.glob("*.xcodeproj")) or sorted(root.glob("*/*.xcodeproj"))
    if found:
        return found[0]
    yml = sc.xcodegen_project(root)
    if yml:
        # 아직 생성 전이다. 이름은 project.yml 의 name 에서 온다.
        text = yml.read_text(encoding="utf-8", errors="replace")
        m = re.search(r"^name:\s*(\S+)", text, re.M)
        if m:
            return yml.parent / f"{m.group(1)}.xcodeproj"
    sys.exit("❌ .xcodeproj 를 찾을 수 없습니다. --project 로 지정하세요.")


def detect_scheme(root: Path, project: Path, explicit: str | None) -> str:
    if explicit:
        return explicit
    yml = sc.xcodegen_project(root)
    if yml:
        text = yml.read_text(encoding="utf-8", errors="replace")
        m = re.search(r"^targets:\s*\n\s{2}(\S+):", text, re.M)
        if m:
            return m.group(1)
    return project.stem


def detect_bundle_id(root: Path, project: Path, explicit: str | None) -> str:
    if explicit:
        return explicit
    for src, pat in (
        (sc.xcodegen_project(root), r"PRODUCT_BUNDLE_IDENTIFIER:\s*\"?([A-Za-z0-9.\-]+)\"?"),
        (project / "project.pbxproj", r"PRODUCT_BUNDLE_IDENTIFIER = \"?([A-Za-z0-9.\-]+)\"?;"),
    ):
        if src and Path(src).is_file():
            m = re.search(pat, Path(src).read_text(encoding="utf-8", errors="replace"))
            if m:
                return m.group(1)
    sys.exit("❌ bundle id 를 찾을 수 없습니다. --bundle-id 로 지정하세요.")


# --------------------------------------------------------------------------- 접근 확인

def verify_access(api_key: dict, bundle_id: str) -> None:
    """앱을 한 건 조회해 자격증명과 권한을 확인한다. **아무것도 바꾸지 않는다.**"""
    try:
        import jwt  # PyJWT
    except ImportError:
        print("⚠️  PyJWT 가 없어 API 접근 확인을 건너뜁니다 (pip install pyjwt cryptography)")
        return

    now = int(time.time())
    token = jwt.encode(
        {"iss": api_key["issuer_id"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        api_key["private_key"], algorithm="ES256",
        headers={"kid": api_key["key_id"], "typ": "JWT"},
    )
    req = urllib.request.Request(
        f"https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]={bundle_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        hint = {
            401: "인증 실패 — key_id·issuer_id·private_key 를 확인하세요.",
            403: "권한 없음 — API 키 역할이 App Manager 이상인지 확인하세요.",
        }.get(e.code, "")
        sys.exit(f"❌ App Store Connect API 접근 실패 (HTTP {e.code}). {hint}")

    apps = data.get("data", [])
    if not apps:
        # 신규 출시면 앱 레코드가 아직 없다. 이것만으로 실패로 보지 않는다.
        print(f"⚠️  bundleId={bundle_id} 인 앱이 없습니다 — 신규 출시라면 정상입니다.")
        return
    print(f"✅ App Store Connect 접근 확인 — {apps[0].get('attributes', {}).get('name', '?')} ({bundle_id})")


# --------------------------------------------------------------------------- 빌드·업로드

def run(command: list[str], label: str) -> None:
    print(f"▶ {label}")
    if subprocess.run(command).returncode != 0:
        sys.exit(f"❌ {label} 실패")


def archive(project: Path, scheme: str, archive_path: Path) -> None:
    if archive_path.exists():
        subprocess.run(["rm", "-rf", str(archive_path)], check=True)
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    run(["xcodebuild", "archive",
         "-project", str(project), "-scheme", scheme,
         "-configuration", "Release", "-destination", "generic/platform=iOS",
         "-archivePath", str(archive_path)],
        f"아카이브 → {archive_path}")


def export_only(archive_path: Path, export_dir: Path, export_options: Path) -> None:
    """ipa 를 로컬에 내보내기만 한다. **업로드하지 않는다** — 되돌릴 수 있는 단계다.

    디스크의 plist 를 그대로 쓴다(`destination=export`). 불가역 동작을 별도 단계로 떼어
    사람 확인을 붙일 자리를 만든다.
    """
    run(["xcodebuild", "-exportArchive",
         "-archivePath", str(archive_path), "-exportPath", str(export_dir),
         "-exportOptionsPlist", str(export_options),
         "-allowProvisioningUpdates"],
        f"ipa 내보내기 → {export_dir}")


def upload(archive_path: Path, export_dir: Path, export_options: Path, api_key: dict) -> None:
    """destination=upload 로 내보내면 xcodebuild 가 곧바로 업로드한다. **불가역이다.**

    디스크의 plist 는 건드리지 않는다 — 메모리에서 바꿔 임시 파일로만 넘긴다.
    """
    options = plistlib.loads(export_options.read_bytes())
    options["destination"] = "upload"

    with tempfile.TemporaryDirectory() as workdir:
        # 개인키는 파일로만 넘길 수 있어 잠깐 쓴다. 블록을 벗어나면 지워진다.
        key_path = Path(workdir) / f"AuthKey_{api_key['key_id']}.p8"
        key_path.write_text(api_key["private_key"], encoding="utf-8")
        key_path.chmod(0o600)
        opts_path = Path(workdir) / "ExportOptions-upload.plist"
        opts_path.write_bytes(plistlib.dumps(options))

        run(["xcodebuild", "-exportArchive",
             "-archivePath", str(archive_path), "-exportPath", str(export_dir),
             "-exportOptionsPlist", str(opts_path),
             "-authenticationKeyPath", str(key_path),
             "-authenticationKeyID", api_key["key_id"],
             "-authenticationKeyIssuerID", api_key["issuer_id"],
             "-allowProvisioningUpdates"],
            "App Store Connect 업로드")


def main() -> int:
    ap = argparse.ArgumentParser(description="iOS 앱을 App Store Connect 에 업로드합니다.")
    ap.add_argument("--slug", required=True, help="KMS service 로 쓰는 앱 슬러그")
    ap.add_argument("--root", type=Path, default=Path.cwd(), help="대상 레포 루트")
    ap.add_argument("--project", type=Path, help=".xcodeproj (생략 시 자동 탐색)")
    ap.add_argument("--scheme", help="생략 시 project.yml 또는 파일명에서")
    ap.add_argument("--bundle-id", help="생략 시 project.yml / pbxproj 에서")
    ap.add_argument("--team-id", default="", help="ExportOptions 를 새로 만들 때 필요")
    ap.add_argument("--export-options", type=Path, help="생략 시 <root>/ExportOptions.plist, 없으면 생성")
    ap.add_argument("--archive", type=Path, help="생략 시 <root>/build/<scheme>.xcarchive")
    ap.add_argument("--export-dir", type=Path, help="생략 시 <root>/build/export")
    ap.add_argument("--archive-only", action="store_true", help="아카이브까지만 하고 종료")
    ap.add_argument("--export-only", action="store_true",
                    help="ipa 를 로컬에 내보내기만 하고 업로드하지 않는다 (되돌릴 수 있는 단계)")
    ap.add_argument("--skip-archive", action="store_true", help="기존 아카이브를 그대로 업로드")
    ap.add_argument("--dry-run", action="store_true", help="자격증명·접근 확인만 하고 종료")
    args = ap.parse_args()

    root = args.root.resolve()
    project = detect_project(root, args.project)
    sc.ensure_xcodeproj(root, project)          # 없으면 xcodegen generate 시도
    scheme = detect_scheme(root, project, args.scheme)
    bundle_id = detect_bundle_id(root, project, args.bundle_id)

    # 버전 정본은 project.yml 이다. pbxproj 가 오래됐으면 여기서 중단한다.
    version, build, src = sc.ios_version(root, project / "project.pbxproj")
    print(f"✅ 대상: {scheme} {version} (빌드 {build}) / {bundle_id}   [버전 출처: {src}]")

    archive_path = args.archive or (root / "build" / f"{scheme}.xcarchive")
    export_dir = args.export_dir or (root / "build/export")

    api_key = None
    needs_credentials = not (args.archive_only or args.export_only)
    if needs_credentials:
        # 아카이브만 만들 때는 자격증명이 필요 없으므로 KMS 를 건드리지 않는다.
        res = sc.kms_fetch(root, args.slug, SECRET_KIND,
                           required=("key_id", "issuer_id", "private_key"))
        if not res.ok:
            print(res.handoff(HANDOFF_ITEM, "appstore_account"), file=sys.stderr)
            sys.exit(f"❌ 자격증명을 얻지 못했습니다 ({res.status}).")
        if res.legacy:
            print(f"⚠️  이관 전 형식으로 찾았습니다: {res.name}@{res.service} — 공용으로 옮겨야 합니다.")
        api_key = res.value
        print(f"✅ KMS 에서 API 키 확인 ({res.name}@{res.service})")

        if args.dry_run:
            verify_access(api_key, bundle_id)
            print("dry-run — 아카이브·업로드하지 않고 종료합니다.")
            return 0

    export_options = args.export_options or (root / "ExportOptions.plist")
    if not args.archive_only:
        export_options = sc.ensure_export_options(export_options, args.team_id)

    if not args.skip_archive:
        archive(project, scheme, archive_path)
    elif not archive_path.exists():
        sys.exit(f"❌ 아카이브 없음: {archive_path}")

    if args.archive_only:
        print(f"✅ 아카이브만 완료 — {archive_path}")
        return 0

    if args.export_only:
        export_only(archive_path, export_dir, export_options)
        print(f"✅ 내보내기만 완료 — {export_dir}. 업로드하지 않았습니다.")
        return 0

    upload(archive_path, export_dir, export_options, api_key)
    print(f"✅ 업로드 완료 — App Store Connect 에서 빌드 {build} 처리 상태를 확인하세요.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
