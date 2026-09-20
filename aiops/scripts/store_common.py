#!/usr/bin/env python3
"""스토어 업로드 공통 기반.

`appstore_upload.py` · `play_upload.py` 가 공유한다. 앱별 하드코딩을 없애고
설계(`docs/design/release-skills.md`)에서 정한 결정을 한곳에 모은다.

여기 있는 것은 전부 **조용히 틀릴 수 있는 지점**이다.

  · KMS 조회 0건은 "미등록" 이 아니다 — 권한 없음과 구별되지 않는다
  · KMS_TOKEN 은 레포 안이 아니라 상위 폴더에 있을 수 있다
  · XcodeGen 레포의 버전 정본은 pbxproj 가 아니라 project.yml 이다

값(시크릿)은 어떤 경로로도 출력하지 않는다.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

KMS_URL = os.environ.get("KMS_URL", "https://kms.devworld.co.kr")


# --------------------------------------------------------------------------- 시크릿 이름

def secret_prefix(slug: str) -> str:
    """슬러그 → SECRET_NAME 접두사. 하이픈은 언더스코어로, 대문자로.

    zen-koi → ZEN_KOI_    brick-breaker → BRICK_BREAKER_    pong → PONG_
    """
    return re.sub(r"[^A-Za-z0-9]+", "_", slug).strip("_").upper() + "_"


# 항목마다 앱 단위인지 조직 단위인지가 다르다. 이것을 구별하지 않으면
# 조직 단위 자격증명을 앱 service 로 찾다가 **값이 있는데 not_found 가 난다.**
# 범위 밖인 것과 없는 것이 같은 결과로 나오는 것 — 이 모듈이 없애려는 바로 그 실패다.
#
#   app  앱마다 값이 다르다. service=<앱슬러그>
#   org  조직 공용이라 앱마다 같다. service=<조직>. 앱 접두사를 붙이지 않는다
#        (구별할 대상이 없다). 키 교체 시 한 곳만 고치면 된다.
SECRET_SCOPE = {
    "ANDROID_KEYSTORE_BASE64":    "app",
    "ANDROID_KEYSTORE_PASSWORD":  "app",
    "ANDROID_KEY_ALIAS":          "app",
    "APPSTORE_API_KEY_JSON":      "org",
    "PLAY_SERVICE_ACCOUNT_JSON":  "org",
}

DEFAULT_ORG = "devworld"


def secret_scope(kind: str) -> str:
    """모르는 항목은 app 으로 본다 — 조직 공용으로 잘못 넓히는 것보다 안전하다."""
    return SECRET_SCOPE.get(kind, "app")


def secret_candidates(slug: str, kind: str, org: str = DEFAULT_ORG) -> list[tuple[str, str, bool]]:
    """조회 순서를 (이름, service, legacy) 로 돌려준다.

    **service 를 빼지 않는다.** 빼면 다른 앱의 동명 시크릿이 섞여 ambiguous 가 난다.
    scope 에 따라 고정 대상만 바뀐다.

    legacy=True 로 찾았으면 호출 측이 보고에 남긴다 — 옛 규칙이며 언젠가 옮겨야 한다.
    표시가 없으면 이관이 영원히 끝나지 않는다.
    """
    pref = secret_prefix(slug) + kind
    if secret_scope(kind) == "org":
        # 공용이 정답. 앱 접두사 + 앱 service 는 이관 전 상태다(PONG_APPSTORE_API_KEY_JSON).
        return [(kind, org, False), (pref, slug, True)]
    return [(pref, slug, False), (kind, slug, True)]


# --------------------------------------------------------------------------- KMS_TOKEN 탐색

def find_envrc(start: Path) -> Path | None:
    """레포에서 위로 거슬러 올라가며 .envrc 를 찾는다.

    zen-koi 는 레포 안에 .envrc 가 없고 상위 폴더에 있다. 레포만 보면 못 찾는다.
    """
    cur = start.resolve()
    for d in [cur, *cur.parents]:
        cand = d / ".envrc"
        if cand.is_file():
            return cand
        if (d / ".git").exists() and d != cur:
            # 레포 경계를 넘어서도 계속 본다 — 상위 폴더에 있는 것이 실제 사례다.
            continue
    return None


def kms_token(root: Path) -> str | None:
    """환경변수 우선, 없으면 .envrc 에서 읽는다. 값은 반환만 하고 출력하지 않는다."""
    tok = os.environ.get("KMS_TOKEN")
    if tok:
        return tok
    envrc = find_envrc(root)
    if not envrc:
        return None
    for line in envrc.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"\s*export\s+KMS_TOKEN=(.+)", line)
        if m:
            return m.group(1).strip().strip("'\"")
    return None


# --------------------------------------------------------------------------- KMS 조회

@dataclass
class KmsResult:
    """조회 결과. status 로 세 상태를 구별한다 — 이 구별이 이 모듈의 핵심이다."""
    status: str          # ok | token_missing | not_found | fetch_failed | ambiguous | no_value
    value: dict | None = None
    name: str = ""       # 실제로 찾은(또는 1순위) 이름
    service: str = ""    # 그때 쓴 service
    legacy: bool = False # 이관 전 형식으로 찾았는가
    tried: str = ""      # 시도한 (이름, service) 전부 — 사람이 범위 밖인지 판단하는 근거
    detail: str = ""

    @property
    def ok(self) -> bool:
        return self.status == "ok"

    def handoff(self, item: str, access: str) -> str:
        """HANDOFF 마커 본문. docs/contracts/handoff-marker.md 규약을 따른다.

        VERIFY 에 **조회 범위**를 담는다. "못 찾았다" 를 받은 사람이 범위 밖인지
        진짜 없는지를 스스로 판단할 수 있어야 한다.
        """
        scope = f"kms:{self.status}"
        if self.tried:
            scope += f" ({self.tried})"
        return (
            "## ⏸️ 사람 확인 대기\n"
            f"HANDOFF_REQUIRED={item}\n"
            f"HANDOFF_ACCESS={access}\n"
            f"HANDOFF_VERIFY={scope}\n\n"
            f"{self.detail}"
        )


def _headers(token: str) -> list[str]:
    h = ["-H", f"Authorization: Bearer {token}", "-H", "Accept: application/json"]
    cid, csec = os.environ.get("CF_ACCESS_CLIENT_ID"), os.environ.get("CF_ACCESS_CLIENT_SECRET")
    if cid and csec:
        h += ["-H", f"CF-Access-Client-Id: {cid}", "-H", f"CF-Access-Client-Secret: {csec}"]
    return h


def _curl(args: list[str]) -> tuple[int, str]:
    r = subprocess.run(["curl", "-sS", *args], capture_output=True, text=True)
    return r.returncode, r.stdout


def kms_fetch(root: Path, slug: str, kind: str, env: str = "prod",
              required: tuple[str, ...] = (), org: str = DEFAULT_ORG) -> KmsResult:
    """시크릿을 조회한다. 값은 반환만 하고 절대 출력하지 않는다.

    **0건은 '미등록' 이 아니다.** 권한 없는 토큰도 HTTP 200 에 빈 items 로 온다.
    둘을 구별할 방법이 없으므로 양쪽 다 not_found 로 두고 호출 측이 차단한다.
    """
    token = kms_token(root)
    if not token:
        return KmsResult("token_missing",
                         detail="KMS_TOKEN 을 찾을 수 없습니다. 레포와 상위 폴더의 .envrc 를 확인하세요.")
    hdr = _headers(token)

    rc, _ = _curl([*hdr, "-o", "/dev/null", f"{KMS_URL}/api/v1/health"])
    if rc != 0:
        return KmsResult("fetch_failed", detail=f"KMS 응답 없음: {KMS_URL} (curl rc={rc})")

    cands = secret_candidates(slug, kind, org)
    tried = " · ".join(f"{n}@{svc}" for n, svc, _ in cands)

    for name, service, legacy in cands:
        rc, body = _curl([*hdr, f"{KMS_URL}/api/v1/secrets?q={name}&environment={env}"])
        if rc != 0:
            return KmsResult("fetch_failed", name=name, service=service, tried=tried,
                             detail=f"조회 실패 (curl rc={rc})")
        try:
            items = json.loads(body or '{"items": []}').get("items", [])
        except json.JSONDecodeError:
            return KmsResult("fetch_failed", name=name, service=service, tried=tried,
                             detail="응답이 JSON 이 아닙니다.")
        # service 를 빼지 않는다 — 빼면 다른 앱의 동명 시크릿이 섞여 ambiguous 가 난다.
        hits = [i for i in items
                if i.get("name") == name and i.get("service") == service
                and i.get("environment") == env]
        if not hits:
            continue
        if len(hits) > 1:
            return KmsResult("ambiguous", name=name, service=service, tried=tried,
                             detail=f"같은 이름이 여러 건입니다: {[h.get('id') for h in hits]}")
        sec = hits[0]
        if not sec.get("has_value"):
            return KmsResult("no_value", name=name, service=service, tried=tried,
                             detail=f"값이 등록돼 있지 않습니다 (id={sec.get('id')}).")

        rc, revealed = _curl([*hdr, "-X", "POST", f"{KMS_URL}/api/v1/secrets/{sec['id']}/reveal"])
        if rc != 0 or not revealed:
            return KmsResult("fetch_failed", name=name, service=service, tried=tried,
                             detail="reveal 실패")
        try:
            payload = json.loads(json.loads(revealed).get("value"))
        except (TypeError, json.JSONDecodeError):
            return KmsResult("no_value", name=name, service=service, tried=tried,
                             detail="값이 올바른 JSON 이 아닙니다.")
        missing = [k for k in required if not payload.get(k)]
        if missing:
            return KmsResult("no_value", name=name, service=service, tried=tried,
                             detail=f"필수 필드가 없습니다: {', '.join(missing)}")
        return KmsResult("ok", value=payload, name=name, service=service,
                         legacy=legacy, tried=tried)

    first_name, first_svc, _ = cands[0]
    return KmsResult(
        "not_found", name=first_name, service=first_svc, tried=tried,
        detail=(f"조회 0건 (scope={secret_scope(kind)}, environment={env}).\n"
                f"시도: {tried}\n"
                "0건은 미등록과 권한 없음을 구별하지 못합니다 — 토큰 스코프도 함께 확인하세요.\n"
                "조회 범위가 맞는지도 확인하세요 — 조직 공용 항목을 앱 service 로 찾으면 "
                "값이 있어도 0건이 납니다."))


# --------------------------------------------------------------------------- iOS 프로젝트

def xcodegen_project(root: Path) -> Path | None:
    """project.yml 경로. XcodeGen 을 쓰지 않는 레포면 None."""
    for c in (root / "project.yml", root / "ios/project.yml"):
        if c.is_file():
            return c
    return None


def ios_version(root: Path, pbxproj: Path) -> tuple[str, str, str]:
    """(MARKETING_VERSION, CURRENT_PROJECT_VERSION, 출처) 를 돌려준다.

    **XcodeGen 레포의 정본은 project.yml 이다.** pbxproj 는 생성물이라
    generate 를 안 한 상태면 옛 값이 나온다 — 빌드는 성공하고 스토어에
    잘못된 버전이 올라간다. 조용히 틀리는 지점이므로 정본을 먼저 본다.
    """
    yml = xcodegen_project(root)
    if yml:
        if pbxproj.is_file() and pbxproj.stat().st_mtime < yml.stat().st_mtime:
            sys.exit(
                f"❌ {pbxproj.name} 가 {yml.name} 보다 오래됐습니다.\n"
                f"   `xcodegen generate` 를 먼저 실행하세요 — 지금 올리면 옛 버전이 업로드됩니다."
            )
        text = yml.read_text(encoding="utf-8", errors="replace")
        mk = re.search(r"MARKETING_VERSION:\s*\"?([0-9][0-9.]*)\"?", text)
        bd = re.search(r"CURRENT_PROJECT_VERSION:\s*\"?([0-9]+)\"?", text)
        if mk:
            return mk.group(1), (bd.group(1) if bd else "1"), yml.name

    if not pbxproj.is_file():
        sys.exit(f"❌ 버전을 읽을 수 없습니다 — {pbxproj} 와 project.yml 둘 다 없습니다.")
    text = pbxproj.read_text(encoding="utf-8", errors="replace")
    def first(key: str) -> str:
        m = re.search(rf"{key} = ([^;]+);", text)
        return m.group(1).strip().strip('"') if m else ""
    mk, bd = first("MARKETING_VERSION"), first("CURRENT_PROJECT_VERSION")
    if not mk:
        sys.exit(f"❌ {pbxproj.name} 에서 MARKETING_VERSION 을 찾지 못했습니다.")
    return mk, bd or "1", pbxproj.name


def ensure_xcodeproj(root: Path, project: Path) -> None:
    """.xcodeproj 가 없으면 xcodegen 으로 생성을 시도한다.

    zen-koi 는 .xcodeproj 가 .gitignore 된 생성물이다. 클린 체크아웃에는 없다.
    """
    if project.exists():
        return
    yml = xcodegen_project(root)
    if not yml:
        sys.exit(f"❌ {project} 가 없고 project.yml 도 없습니다.")
    if subprocess.run(["which", "xcodegen"], capture_output=True).returncode != 0:
        sys.exit(f"❌ {project} 가 없습니다. XcodeGen 을 설치하고 `xcodegen generate` 를 실행하세요.")
    print(f"[store] {project.name} 없음 — xcodegen generate 실행")
    if subprocess.run(["xcodegen", "generate"], cwd=yml.parent).returncode != 0:
        sys.exit("❌ xcodegen generate 실패")
    if not project.exists():
        sys.exit(f"❌ xcodegen 을 돌렸으나 {project} 가 생성되지 않았습니다.")


EXPORT_OPTIONS_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>{team_id}</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
"""


def ensure_export_options(path: Path, team_id: str) -> Path:
    """ExportOptions plist 가 없으면 만든다. 레포마다 경로·이름이 다르고 아예 없기도 하다."""
    if path.is_file():
        return path
    if not team_id:
        sys.exit(f"❌ {path} 가 없고 --team-id 도 주어지지 않아 생성할 수 없습니다.")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(EXPORT_OPTIONS_TEMPLATE.format(team_id=team_id), encoding="utf-8")
    print(f"[store] {path} 생성 (teamID={team_id})")
    return path
