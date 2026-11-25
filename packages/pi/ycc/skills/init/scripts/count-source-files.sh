#!/usr/bin/env bash
# count-source-files.sh [--repo DIR] — read-only estimate for init Phase 2.
# One scoped host command, three output keys, stops after 51 regular files.
# Ignores .git and common dependency/build directories; never hides walk errors.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SHARED_SEG="/_shared/scripts"; _SHARED_SEG_FLAT="/shared/scripts"; _SHARED_SEG_AGENTS="/ycc-shared/scripts"
_guard_found=false
for _guard in "${SCRIPT_DIR}/../..${_SHARED_SEG}/require-python.sh" \
              "${SCRIPT_DIR}/../../..${_SHARED_SEG_FLAT}/require-python.sh" \
              "${SCRIPT_DIR}/../../..${_SHARED_SEG_AGENTS}/require-python.sh"; do
  if [[ -f "$_guard" ]]; then
    # shellcheck source=/dev/null
    . "$_guard"
    _guard_found=true
    break
  fi
done
if [[ "$_guard_found" != true ]]; then
  echo 'count-source-files: shared require-python.sh not found (broken ycc install)' >&2
  exit 1
fi
python3 - "$@" <<'PY'
import argparse
import os
import stat
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description="Count up to 51 project files (read-only)")
parser.add_argument("--repo", default=os.getcwd())
args = parser.parse_args()
root = Path(args.repo)
if not root.is_dir():
    parser.error(f"directory not found: {root}")

excluded = {".git", "node_modules", "vendor", ".venv", "venv", "__pycache__", "dist", "build", "target"}

def fail_walk(error: OSError) -> None:
    raise error

count = 0
try:
    for directory, dirs, files in os.walk(root, onerror=fail_walk, followlinks=False):
        dirs[:] = [name for name in dirs if name not in excluded]
        for name in files:
            if stat.S_ISREG((Path(directory) / name).lstat().st_mode):
                count += 1
                if count == 51:
                    break
        if count == 51:
            break
except OSError as exc:
    print(f"count-source-files: cannot scan project: {exc}", file=sys.stderr)
    sys.exit(1)

print(f"count={count}")
print(f"capped={str(count == 51).lower()}")
print("cap=50")
PY
