#!/usr/bin/env python3
"""aiops 플러그인 네임스페이스 전환 — ai-devops(flat 복사모델)의 스킬·에이전트를
plugin-native(단일 플러그인 aiops)로 in-place 전환.

핵심(실측 근거): 플러그인 에이전트/스킬은 bare 이름으로 해석 안 됨 → 네임스페이스 필수.
  - 에이전트 참조 → `aiops:<name>`  (Agent 도구 subagent_type)
  - 스킬 슬래시 → /aiops:<name>
  - 템플릿 경로 → ${CLAUDE_PLUGIN_ROOT}/templates/...
'dev' 는 에이전트이자 'dev 브랜치'라 문맥(서브에이전트/에이전트 뒤)일 때만 전환.
"""
import re, sys, pathlib

ROOT = pathlib.Path(sys.argv[1])  # aiops/ 플러그인 루트
AGENTS = ["bug-analyst","bug-verifier","dev-backend","dev-designer","dev-devops","dev-e2e",
          "dev-frontend","dev-mobile-android","dev-mobile-flutter","dev-mobile-ios","dev-mobile-rn",
          "dev-pr","doc-updater","marketing","orchestrator","planning","qa-admin","qa-backend",
          "qa-e2e","qa-frontend","qa-mobile-android","qa-mobile-e2e","qa-mobile-ios","release-manager"]
# 'dev' 는 특수처리(브랜치 충돌). 아래 AGENTS 에서 제외됨.
SKILLS = ["backend","brief","bugflow","chainflow","deploy-prod","devflow","devplanning",
          "e2e-onboard","e2e-test","frontend","jira-to-issue","merge-main","merge-pr","mobileflow",
          "prd","promote","qa-admin","qa-backend","qa-check","qa-frontend","qa-mobile","review-pr",
          "run-e2e","run-mobile-e2e","setup","tech-spec","update-docs","verify-deploy","wireframe"]

# 긴 이름 먼저(부분매치 방지)
AGENTS.sort(key=len, reverse=True)
SKILLS.sort(key=len, reverse=True)

def transform(text: str) -> tuple[str, int]:
    n = 0
    # 1) 에이전트(dev 제외): 백틱 래핑 → 네임스페이스. 이름이 유일해 안전.
    for a in AGENTS:
        new, c = re.subn(rf'`{re.escape(a)}`', f'`aiops:{a}`', text)
        text, n = new, n + c
    # 2) 에이전트: subagent_type / --agent 비백틱 (dev 포함)
    for a in AGENTS + ["dev"]:
        text, c1 = re.subn(rf'(subagent_type\s*[=:]\s*["\']?){re.escape(a)}(["\'\s,)}}])', rf'\1aiops:{a}\2', text); n += c1
        text, c2 = re.subn(rf'(--agent\s+){re.escape(a)}(?![a-z0-9-])', rf'\1aiops:{a}', text); n += c2
    # 3) 'dev' 에이전트: 문맥(서브에이전트/에이전트 바로 앞)일 때만
    text, c = re.subn(r'`dev`(\s*(?:서브)?에이전트)', r'`aiops:dev`\1', text); n += c
    # 4) 스킬 슬래시: /<name> → /aiops:<name> (이름 뒤 경계)
    for s in SKILLS:
        text, c = re.subn(rf'/{re.escape(s)}(?![a-z0-9-])', f'/aiops:{s}', text); n += c
    # 5) 템플릿 경로 → 플러그인 루트 (aiops 는 plugin-only, install.sh 복사 없음)
    for t in ["templates/e2e", "templates/mobile-ci", "templates/mobile-e2e", "templates/mobile-fastlane"]:
        # 이미 ${CLAUDE_PLUGIN_ROOT}/ 붙은 건 건너뜀
        text, c = re.subn(rf'(?<!ROOT}}/){re.escape(t)}', '${CLAUDE_PLUGIN_ROOT}/' + t, text); n += c
    return text, n

def quote_description(text: str) -> tuple[str, int]:
    """프론트matter(첫 --- ~ ---)의 description 값을 쌍따옴표로 감싼다(콜론 등 특수문자 안전).
       이미 쌍따옴표면 건너뜀. YAML 파싱 오류 방지(네임스페이스 aiops: 콜론 대응)."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return text, 0
    # 두 번째 --- 위치
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
    if end is None:
        return text, 0
    changed = 0
    for i in range(1, end):
        m = re.match(r'^(description:\s*)(.*\S)\s*$', lines[i])
        if not m:
            continue
        val = m.group(2)
        if val.startswith('"') and val.endswith('"'):
            continue
        if val.startswith("'") and val.endswith("'"):
            val = val[1:-1]
        val = val.replace('\\', '\\\\').replace('"', '\\"')
        lines[i] = m.group(1) + '"' + val + '"'
        changed += 1
    return "\n".join(lines), changed

total_files = total_changes = 0
for md in sorted(ROOT.glob("**/*.md")):
    orig = md.read_text(encoding="utf-8")
    new, n = transform(orig)
    new, q = quote_description(new)
    if n or q:
        md.write_text(new, encoding="utf-8")
        total_files += 1; total_changes += n + q
print(f"전환 완료: {total_files}개 파일, {total_changes}건 치환")
