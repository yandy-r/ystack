#!/usr/bin/env bash
# Ensure .agents-plugin/skills (and /ycc-shared) matches generator output, has
# agentskills.io frontmatter with valid names, and strips plugin residue.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_ROOT="${REPO_ROOT}/.agents-plugin"
SKILLS_DIR="${BUNDLE_ROOT}/skills"

echo "== Sync check (generator --check) =="
python3 "${REPO_ROOT}/scripts/generate_agents_skills.py" --check

echo "== Text transform regressions =="
python3 "${REPO_ROOT}/scripts/test_generate_agents_common.py"

echo "== Frontmatter lint (agentskills.io) =="
python3 - <<'PY' "${SKILLS_DIR}"
import re
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
# agentskills.io SKILL.md frontmatter keys (allowed-tools passes through from
# the Claude source verbatim; readers interpret it per tool).
ALLOWED = {"name", "description", "license", "compatibility", "metadata", "allowed-tools"}
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
# because they describe all deployment targets.
# Note: _shared/references/target-capability-matrix.md lives under
# .agents-plugin/ycc-shared/ (outside SKILLS_DIR) and is already excluded.
# ~/.claude/ references are intentionally ALLOWED here: product-specific home
# paths are left as-is for this cross-tool target (no truthful rewrite exists).
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

BAD=0
pattern='/ycc:|\bycc:|CLAUDE_PLUGIN_ROOT|\.\./\.\./_shared/'
while IFS= read -r -d '' f; do
  if is_verbatim "$f"; then
    continue
  fi
  if grep -qE "$pattern" "$f" 2>/dev/null; then
    echo "FORBIDDEN pattern in $f:" >&2
    grep -nE "$pattern" "$f" >&2 || true
    BAD=1
  fi
done < <(find "$SKILLS_DIR" -type f -print0)

if [[ "$BAD" -ne 0 ]]; then
  echo "validate-agents-skills.sh: content policy failed." >&2
  exit 1
fi

echo "OK: .agents-plugin/skills is in sync and passes agentskills.io lint."
