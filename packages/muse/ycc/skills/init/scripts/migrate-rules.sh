#!/usr/bin/env bash
# migrate-rules.sh --repo DIR [--dry-run|--yes] [--allow-non-git]
# Bash 3.2-compatible entrypoint; Python 3.11+ engine handles rules safely
# (guarded up front with a readable error and no partial output).
# Show --dry-run first; --yes applies after showing the complete diff/report.
# Only git repositories by default. --allow-non-git creates timestamped backups.
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
  echo "migrate-rules: shared require-python.sh not found (broken ycc install)" >&2
  exit 1
fi
export PYTHONDONTWRITEBYTECODE=1
exec python3 "${SCRIPT_DIR}/migrate-rules.py" "$@"
