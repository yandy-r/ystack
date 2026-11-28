#!/usr/bin/env bash
#
# derive-visual-dir.sh — compute the visual/ output directory for a plan path.
#
# The visual-plan contract (skills/_shared/references/visual-mode.md) requires
# the output to live in a `visual/` sibling of the input plan file, derived from
# the path handed in — never hardcoded. This thin wrapper performs that single
# derivation so the skill never improvises the path.
#
# Usage:
#   derive-visual-dir.sh <path/to/plan.md> [--mkdir]
#
# Arguments:
#   <path/to/plan.md>   Source plan path (absolute or relative). Must exist.
#   --mkdir             Create the derived directory if it does not exist.
#
# Output:
#   The derived visual/ directory path on stdout.
#
# Exit codes:
#   0 - Derived (and created, if --mkdir) successfully
#   1 - Usage error or plan path missing
#
set -euo pipefail

_error() {
  echo "derive-visual-dir.sh: error: $*" >&2
}

PLAN_PATH=""
DO_MKDIR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mkdir)
      DO_MKDIR=1
      shift
      ;;
    -h|--help)
      echo "Usage: derive-visual-dir.sh <path/to/plan.md> [--mkdir]" >&2
      exit 0
      ;;
    -*)
      _error "unknown flag: $1"
      exit 1
      ;;
    *)
      if [[ -n "$PLAN_PATH" ]]; then
        _error "unexpected extra argument: $1"
        exit 1
      fi
      PLAN_PATH="$1"
      shift
      ;;
  esac
done

if [[ -z "$PLAN_PATH" ]]; then
  _error "a plan path is required"
  echo "Usage: derive-visual-dir.sh <path/to/plan.md> [--mkdir]" >&2
  exit 1
fi

if [[ ! -f "$PLAN_PATH" ]]; then
  _error "plan file not found: $PLAN_PATH"
  exit 1
fi

PLAN_DIR="$(cd "$(dirname "$PLAN_PATH")" && pwd)"
OUT_DIR="${PLAN_DIR}/visual"

if [[ "$DO_MKDIR" -eq 1 ]]; then
  mkdir -p "$OUT_DIR"
fi

echo "$OUT_DIR"
exit 0
