#!/usr/bin/env bash
# Ensure packages/pi/ycc/skills matches generator output and has no Claude-only residue.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "== Sync check (generator --check) =="
python3 "${REPO_ROOT}/scripts/generate_pi_skills.py" --check

echo "== Content policy and discovery layout (generated skills) =="
# VERBATIM_SKILL_FILES and <!-- ycc:verbatim-block --> regions describe every target
# literally; REPOSITORY_LAYOUT_FILES keep `${CLAUDE_PLUGIN_ROOT}` as source-authoring
# guidance. Everywhere else Pi would leave these tokens literal (ADR 0003).
PYTHONPATH="${REPO_ROOT}/scripts" python3 - "${REPO_ROOT}" <<'PY'
import re
import sys
from pathlib import Path

from generate_codex_common import VERBATIM_SKILL_FILES, protect_marked_verbatim_blocks
from generate_pi_skills import REPOSITORY_LAYOUT_FILES, SRC_DIR, check_discovery_layout

repo = Path(sys.argv[1])
dest = repo / "packages/pi/ycc/skills"
forbidden = re.compile(r"CLAUDE_PLUGIN_ROOT|/ycc:|\bycc:|skill://")
layout_forbidden = re.compile(r"/ycc:|\bycc:|skill://")
bad = False
files = sorted(p for p in dest.rglob("*") if p.is_file())
for path in files:
    rel = path.relative_to(dest)
    if rel.as_posix() in VERBATIM_SKILL_FILES:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    source = SRC_DIR / rel
    if source.is_file():
        _, blocks = protect_marked_verbatim_blocks(source.read_text(encoding="utf-8"))
        for block in blocks.values():
            text = text.replace(block, "")
    pattern = layout_forbidden if rel.as_posix() in REPOSITORY_LAYOUT_FILES else forbidden
    for number, line in enumerate(text.splitlines(), 1):
        if pattern.search(line) or "mcp**" in line:
            print(f"FORBIDDEN pattern in {path}:{number}: {line.strip()}", file=sys.stderr)
            bad = True
try:
    check_discovery_layout({p.relative_to(dest) for p in files})
except ValueError as error:
    print(f"discovery layout: {error}", file=sys.stderr)
    bad = True
sys.exit(1 if bad else 0)
PY

echo "== Generated shell helper paths =="
python3 "${REPO_ROOT}/scripts/validate_generated_shell_paths.py" --root "${REPO_ROOT}/packages/pi"

echo "OK: packages/pi/ycc/skills is in sync and passes content and discovery policy."
