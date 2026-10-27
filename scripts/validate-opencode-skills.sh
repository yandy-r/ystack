#!/usr/bin/env bash
# Ensure .opencode-plugin/skills (and /shared) matches generator output, has
# opencode-strict frontmatter, and strips Claude-only residue.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_ROOT="${REPO_ROOT}/.opencode-plugin"
SKILLS_DIR="${BUNDLE_ROOT}/skills"

echo "== Sync check (generator --check) =="
python3 "${REPO_ROOT}/scripts/generate_opencode_skills.py" --check

echo "== Native V2 dispatch projection regressions =="
python3 "${REPO_ROOT}/scripts/test_generate_opencode_dispatch.py"

echo "== Skill-derived command regressions =="
python3 "${REPO_ROOT}/scripts/test_generate_opencode_commands.py"

echo "== Skill shell plugin-root regressions =="
python3 "${REPO_ROOT}/scripts/test_generate_opencode_skills.py"

echo "== Generated shell helper paths =="
python3 "${REPO_ROOT}/scripts/validate_generated_shell_paths.py" --root "${BUNDLE_ROOT}" \
  --root "${REPO_ROOT}/packages/opencode"

echo "== Frontmatter lint =="
python3 - <<'PY' "${SKILLS_DIR}" "${REPO_ROOT}"
import re
import sys
from pathlib import Path

import yaml

repo = Path(sys.argv[2])
sys.path.insert(0, str(repo / "scripts"))
from generate_codex_common import model_invocation_disabled, parse_frontmatter

root = Path(sys.argv[1])
# opencode's skills API recognises exactly these keys (per opencode.ai/docs/skills).
# Unknown keys are ignored at runtime, but the generator should emit a minimal
# frontmatter so this validator stays useful.
ALLOWED = {"name", "description", "license", "compatibility", "metadata"}
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
errors = 0
for path in sorted(root.rglob("SKILL.md")):
    text = path.read_text(encoding="utf-8")
    match = re.match(r"^---\n(.*?)\n---\n", text, re.DOTALL)
    if not match:
        print(f"MISSING frontmatter: {path}", file=sys.stderr)
        errors += 1
        continue
    data = yaml.safe_load(match.group(1)) or {}
    source, _ = parse_frontmatter((repo / "ycc/skills" / path.parent.name / "SKILL.md").read_text(encoding="utf-8"))
    disabled = model_invocation_disabled(source, path.parent.name)
    metadata = data.get("metadata", {})
    if not isinstance(metadata, dict) or ("opencode/autoinvoke" in metadata) != disabled or (disabled and metadata.get("opencode/autoinvoke") != "false"):
        print(f"INVALID invocation metadata: {path}", file=sys.stderr)
        errors += 1
    unknown = set(data) - ALLOWED
    if unknown:
        print(
            f"UNEXPECTED frontmatter keys in {path}: {sorted(unknown)}",
            file=sys.stderr,
        )
        errors += 1
    for required in ("name", "description"):
        if required not in data:
            print(f"MISSING required skill key '{required}' in {path}", file=sys.stderr)
            errors += 1
    name = str(data.get("name") or "")
    if name and not NAME_RE.match(name):
        print(f"INVALID skill name '{name}' in {path} (regex: ^[a-z0-9]+(-[a-z0-9]+)*$)", file=sys.stderr)
        errors += 1
    if name and name != path.parent.name:
        print(
            f"NAME MISMATCH in {path}: frontmatter name={name!r} but directory is {path.parent.name!r}",
            file=sys.stderr,
        )
        errors += 1
    description = str(data.get("description") or "")
    if description and not (1 <= len(description) <= 1024):
        print(
            f"DESCRIPTION length {len(description)} out of range (1–1024) in {path}",
            file=sys.stderr,
        )
        errors += 1
if errors:
    sys.exit(1)
PY

echo "== Content policy (generated skills) =="
# Verbatim list must mirror VERBATIM_SKILL_FILES in generate_opencode_common.py.
# The cross-target meta files legitimately reference Claude-only identifiers
# because they describe all four deployment targets.
# Note: _shared/references/target-capability-matrix.md lives under
# .opencode-plugin/shared/ (outside SKILLS_DIR) and is already excluded.
VERBATIM=(
  "${SKILLS_DIR}/init/scripts/migrate-rules.sh"
  "${SKILLS_DIR}/init/scripts/migrate-rules.py"
  "${SKILLS_DIR}/init/scripts/rules_file_lib.py"
  "${SKILLS_DIR}/init/scripts/render-template.sh"
  "${SKILLS_DIR}/init/scripts/render-template.py"
  "${SKILLS_DIR}/init/scripts/profile-project.sh"
  "${SKILLS_DIR}/init/scripts/rules-report.sh"
  "${SKILLS_DIR}/hooks-workflow/references/support-notes.md"
  "${SKILLS_DIR}/hooks-workflow/scripts/build-hook-config.sh"
  "${SKILLS_DIR}/compatibility-audit/scripts/audit-install-assumptions.sh"
  "${SKILLS_DIR}/compatibility-audit/scripts/audit-target-features.sh"
  "${SKILLS_DIR}/compatibility-audit/references/reading-the-report.md"
)
is_verbatim() {
  local f="$1" v
  for v in "${VERBATIM[@]}"; do
    [[ "$f" == "$v" ]] && return 0
  done
  return 1
}

is_bundle_release_file() {
  local rel="${1#"${SKILLS_DIR}/"}"
  [[ "$rel" == bundle-release/* ]]
}

BAD=0
while IFS= read -r -d '' f; do
  if is_verbatim "$f"; then
    continue
  fi
  if is_bundle_release_file "$f"; then
    # bundle-release intentionally manages Claude plugin metadata as the
    # source-of-truth version surface, even from generated opencode skills.
    pattern='/ycc:|\bycc:|CLAUDE_PLUGIN_ROOT|~/\.claude/|TeamCreate|TeamDelete|TaskCreate|TaskUpdate|TaskList|TaskGet|SendMessage|AskUserQuestion|TodoWrite|subagent_type:'
  else
    pattern='/ycc:|\bycc:|CLAUDE_PLUGIN_ROOT|~/\.claude/|\.claude-plugin/|TeamCreate|TeamDelete|TaskCreate|TaskUpdate|TaskList|TaskGet|SendMessage|AskUserQuestion|TodoWrite|subagent_type:'
  fi
  if grep -qE "$pattern" "$f" 2>/dev/null; then
    echo "FORBIDDEN pattern in $f:" >&2
    grep -nE "$pattern" "$f" >&2 || true
    BAD=1
  fi
done < <(find "$SKILLS_DIR" -type f -print0)

if [[ "$BAD" -ne 0 ]]; then
  echo "validate-opencode-skills.sh: content policy failed." >&2
  exit 1
fi

echo "== Native V2 dispatch content policy =="
python3 "${REPO_ROOT}/scripts/validate_opencode_dispatch.py" \
  "${SKILLS_DIR}" "${BUNDLE_ROOT}/shared"

echo "OK: .opencode-plugin/skills is in sync and passes opencode-native lint."
