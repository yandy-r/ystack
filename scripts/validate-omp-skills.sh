#!/usr/bin/env bash
# Ensure packages/omp/ycc/skills matches generator output and has no Claude-only residue.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "== Sync check (generator --check) =="
python3 "${REPO_ROOT}/scripts/generate_omp_skills.py" --check

echo "== Content policy (generated skills) =="
# VERBATIM_SKILL_FILES (scripts/generate_codex_common.py) and the source's
# <!-- ycc:verbatim-block --> regions are copied byte-for-byte because they
# describe every target literally; they are the only places the forbidden
# patterns may remain. REPOSITORY_LAYOUT_FILES (scripts/generate_omp_skills.py)
# are source-authoring guidance that keeps `${CLAUDE_PLUGIN_ROOT}` literal, so
# only that token is allowed there; it is imported, never copied, to stay in sync.
PYTHONPATH="${REPO_ROOT}/scripts" python3 - "${REPO_ROOT}" <<'PY'
import re
import sys
from pathlib import Path

from generate_codex_common import VERBATIM_SKILL_FILES, protect_marked_verbatim_blocks
from generate_omp_skills import REPOSITORY_LAYOUT_FILES

repo = Path(sys.argv[1])
src = repo / "ycc/skills"
dest = repo / "packages/omp/ycc/skills"
forbidden = re.compile(r"CLAUDE_PLUGIN_ROOT|/ycc:|\bycc:")
layout_forbidden = re.compile(r"/ycc:|\bycc:")
bad = False
for path in sorted(p for p in dest.rglob("*") if p.is_file()):
    rel = path.relative_to(dest)
    if rel.as_posix() in VERBATIM_SKILL_FILES:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    source = src / rel
    if source.is_file():
        _, blocks = protect_marked_verbatim_blocks(source.read_text(encoding="utf-8"))
        for block in blocks.values():
            text = text.replace(block, "")
    pattern = layout_forbidden if rel.as_posix() in REPOSITORY_LAYOUT_FILES else forbidden
    for number, line in enumerate(text.splitlines(), 1):
        if pattern.search(line) or "mcp**" in line:
            print(f"FORBIDDEN pattern in {path}:{number}: {line.strip()}", file=sys.stderr)
            bad = True
if not (dest / "_shared/SKILL.md").is_file():
    print(f"missing generated stub {dest / '_shared/SKILL.md'}", file=sys.stderr)
    bad = True
sys.exit(1 if bad else 0)
PY

echo "== Workflow semantics (packages/omp) =="
# Claude-only workflow semantics (subagent_type, run_in_background, isolation
# "worktree", AskUserQuestion, TaskOutput/BashOutput, the Claude worktree root)
# must not reach the OMP package. FORBIDDEN_SEMANTICS and its file and
# line-anchored allowlists live in scripts/generate_omp_skills.py.
PYTHONPATH="${REPO_ROOT}/scripts" python3 - "${REPO_ROOT}" <<'PY'
import sys
from pathlib import Path

from generate_omp_skills import scan_forbidden_semantics

package = Path(sys.argv[1]) / "packages/omp/ycc"
findings = scan_forbidden_semantics(package)
for finding in findings:
    print(f"FORBIDDEN semantics in packages/omp/ycc/{finding}", file=sys.stderr)
sys.exit(1 if findings else 0)
PY

echo "== Generated shell helper paths =="
python3 "${REPO_ROOT}/scripts/validate_generated_shell_paths.py" --root "${REPO_ROOT}/packages/omp"

echo "OK: packages/omp/ycc/skills is in sync and passes content and semantics policy."
