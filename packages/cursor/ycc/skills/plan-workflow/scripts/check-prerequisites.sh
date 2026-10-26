#!/usr/bin/env bash
# Check that required planning documents exist
# Usage: check-prerequisites.sh <feature-name>
#
# Supports monorepo configurations via .plans-config file.
# See resolve-plans-dir.sh for configuration options.

set -euo pipefail

# Source the artifact-store resolver: the feature dir is PLANS_DIR/<feature>
# in local mode and .ycc/artifacts/<feature> in linear mode.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SHARED_DIR="${SCRIPT_DIR}/../../_shared/scripts"

if [[ -f "${SHARED_DIR}/resolve-artifact-store.sh" ]]; then
  # shellcheck source=../../_shared/scripts/resolve-artifact-store.sh
  source "${SHARED_DIR}/resolve-artifact-store.sh"
else
  # ponytail: resolver ships with the plugin; failing beats guessing a wrong
  # relative docs/plans. Upgrade path: restore resolver alongside this script.
  echo "ERROR: resolve-artifact-store.sh not found at ${SHARED_DIR}" >&2
  echo "Cannot resolve plans directory safely; refusing to guess." >&2
  exit 1
fi

FEATURE_NAME=""
STORE_FLAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --store=*)
      STORE_FLAG="$1"
      ;;
    *)
      if [[ -z "$FEATURE_NAME" ]]; then
        FEATURE_NAME="$1"
      else
        echo "Usage: check-prerequisites.sh <feature-name> [--store=linear|local]" >&2
        exit 1
      fi
      ;;
  esac
  shift
done

if [[ -n "$STORE_FLAG" ]]; then
  # shellcheck disable=SC2086
  resolve_artifact_store "$PWD" "$STORE_FLAG" || {
    echo "ERROR: invalid ${STORE_FLAG#--}" >&2
    exit 1
  }
fi

if [[ -z "$FEATURE_NAME" ]]; then
  echo "ERROR: Feature name required"
  echo "Usage: check-prerequisites.sh <feature-name> [--store=linear|local]"
  exit 1
fi

# The resolver prints its own reason (invalid store config or feature name).
PLAN_DIR="$(get_plans_feature_dir "$FEATURE_NAME")" || exit 1

if [[ ! -d "$PLAN_DIR" ]]; then
  echo "ERROR: Plan directory not found: $PLAN_DIR"
  echo "Create the directory first or run /shared-context to initialize planning"
  exit 1
fi

if [[ ! -f "${PLAN_DIR}/shared.md" ]]; then
  echo "ERROR: ${PLAN_DIR}/shared.md not found"
  echo ""
  echo "The parallel plan requires shared context to be created first."
  echo "Run the shared-context skill:"
  echo "  /shared-context ${FEATURE_NAME}"
  echo ""
  echo "This will create shared.md with relevant files, patterns, and documentation."
  exit 1
fi

echo "✓ Prerequisites satisfied"
echo "  Found: ${PLAN_DIR}/shared.md"

if [[ -f "${PLAN_DIR}/requirements.md" ]]; then
  echo "  Found: ${PLAN_DIR}/requirements.md"
fi

# Count other markdown files for context. Research lives either directly in
# the feature dir (local layout) or in its research/ subdir (linear layout).
RESEARCH_DIR="${PLAN_DIR}/research"
if [[ -d "$RESEARCH_DIR" ]]; then
  OTHER_FILES=$(find "$RESEARCH_DIR" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
  if [[ $OTHER_FILES -gt 0 ]]; then
    echo "  Found: $OTHER_FILES research file(s)"
  fi
  OTHER_FILES=$(find "$PLAN_DIR" -maxdepth 1 -name "*.md" ! -name "shared.md" ! -name "requirements.md" ! -name "parallel-plan.md" 2>/dev/null | wc -l | tr -d ' ')
else
  OTHER_FILES=$(find "$PLAN_DIR" -maxdepth 1 -name "*.md" ! -name "shared.md" ! -name "requirements.md" ! -name "parallel-plan.md" 2>/dev/null | wc -l | tr -d ' ')
fi
if [[ $OTHER_FILES -gt 0 ]]; then
  echo "  Found: $OTHER_FILES additional context file(s)"
fi

exit 0
