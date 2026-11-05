#!/usr/bin/env bash
# Check that every command hook the native ycc-hooks Claude package registers
# (packages/claude/ycc-hooks/hooks/hooks.json) resolves to a script shipped in
# that package. The installer no longer links ~/.claude/hooks; Claude Code runs
# these through ${CLAUDE_PLUGIN_ROOT} once ycc-hooks@ycc is installed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_DIR="${REPO_ROOT}/packages/claude/ycc-hooks"
HOOKS_FILE="${PACKAGE_DIR}/hooks/hooks.json"

if [[ ! -f "${HOOKS_FILE}" ]]; then
    echo "ERROR: ${HOOKS_FILE} is missing (run ./scripts/sync.sh)" >&2
    exit 1
fi

python3 - "${HOOKS_FILE}" "${PACKAGE_DIR}" <<'PYEOF'
import json
import re
import sys
from pathlib import Path

hooks_file, package = Path(sys.argv[1]), Path(sys.argv[2])
data = json.loads(hooks_file.read_text(encoding="utf-8"))
missing = []
count = 0
for groups in data.get("hooks", {}).values():
    for group in groups:
        for hook in group.get("hooks", []):
            if hook.get("type") != "command":
                continue
            for rel in re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/([^\"'\s]+)", hook.get("command", "")):
                count += 1
                if not (package / rel).is_file():
                    missing.append(rel)
if missing:
    print(f"ERROR: ycc-hooks registers scripts it does not ship: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)
print(f"OK: ycc-hooks registers {count} packaged hook script(s), all present.")
PYEOF
