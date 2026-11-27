#!/usr/bin/env bash
# render-template.sh — thin Bash 3.2-compatible wrapper around render-template.py.
# Renders a bundled init template to stdout from profile-project.sh output.
# Never writes files. Requires Python 3.11+ (guarded up front; readable error,
# no partial output). See render-template.py for flags, blocks and exit codes.
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
  echo "render-template: shared require-python.sh not found (broken ycc install)" >&2
  exit 1
fi
export PYTHONDONTWRITEBYTECODE=1
exec python3 "${SCRIPT_DIR}/render-template.py" "$@"
