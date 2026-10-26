#!/usr/bin/env bash
# Check the current state of planning documents for a feature
# Usage: check-state.sh <feature-name>
#
# Reports:
# - Whether the plan directory exists
# - Whether shared.md exists
# - Whether parallel-plan.md exists
# - Count of research files
# - Count of analysis files
#
# Supports monorepo configurations via .plans-config file.
# See resolve-plans-dir.sh for configuration options.

set -uo pipefail

# Source the artifact-store resolver: the feature dir is PLANS_DIR/<feature>
# in local mode and .ycc/artifacts/<feature> in linear mode.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SHARED_DIR="${SCRIPT_DIR}/../../_shared/scripts"

if [[ -f "${SHARED_DIR}/resolve-artifact-store.sh" ]]; then
  # shellcheck source=../../_shared/scripts/resolve-artifact-store.sh
  source "${SHARED_DIR}/resolve-artifact-store.sh"
else
  # Fallback if shared resolver not found - compute absolute repo root
  echo "WARNING: resolve-artifact-store.sh not found, using default path" >&2

  # Try to find repo root using git
  if REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    PLANS_DIR="${REPO_ROOT}/docs/plans"
  else
    # If not in a git repo, prefer the runtime plugin root env var when available.
    plugin_root_var="CLAUDE_PLUGIN""_ROOT"
    plugin_root="$(printenv "$plugin_root_var" 2>/dev/null || true)"
    if [[ -n "$plugin_root" ]]; then
      REPO_ROOT="$(cd "${plugin_root}/.." && pwd)"
    else
      # Source-tree fallback from ycc/skills/plan-workflow/scripts.
      REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
    fi
    PLANS_DIR="${REPO_ROOT}/docs/plans"
  fi

  # Export PLANS_ROOT for consistency with resolve-plans-dir.sh
  export PLANS_ROOT="$REPO_ROOT"
fi

# Optional explicit store override from the invoking skill.
STORE_FLAG=""
FEATURE_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --store=*)
      STORE_FLAG="$1"
      ;;
    *)
      if [[ -z "$FEATURE_NAME" ]]; then
        FEATURE_NAME="$1"
      else
        echo "Usage: check-state.sh <feature-name> [--store=linear|local]" >&2
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

# Colors for output
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() {
  echo -e "${BLUE}INFO${NC}: $1"
}

found() {
  echo -e "${GREEN}FOUND${NC}: $1"
}

missing() {
  echo -e "${YELLOW}MISSING${NC}: $1"
}

warning() {
  echo -e "${YELLOW}WARNING${NC}: $1"
}

if [[ -z "$FEATURE_NAME" ]]; then
  echo "Usage: check-state.sh <feature-name>"
  echo ""
  echo "Checks the current state of planning documents for a feature."
  echo "Reports what files exist and what phases have been completed."
  exit 1
fi

# The resolver prints its own reason (invalid store config or feature name).
if [[ -f "${SHARED_DIR}/resolve-artifact-store.sh" ]]; then
  PLAN_DIR="$(get_plans_feature_dir "$FEATURE_NAME")" || exit 1
else
  PLAN_DIR="${PLANS_DIR}/${FEATURE_NAME}"
fi

echo "Checking state for: ${FEATURE_NAME}"
echo "Directory: ${PLAN_DIR}"
echo "---"

# Track state
DIR_EXISTS="false"
SHARED_EXISTS="false"
PLAN_EXISTS="false"
RESEARCH_COUNT=0
ANALYSIS_COUNT=0

# Check directory
if [[ -d "$PLAN_DIR" ]]; then
  found "Plan directory exists"
  DIR_EXISTS="true"
else
  missing "Plan directory does not exist"
fi

# If directory exists, check contents
if [[ "$DIR_EXISTS" == "true" ]]; then
  echo ""
  echo "Checking files..."

  # Check shared.md
  if [[ -f "${PLAN_DIR}/shared.md" ]]; then
    found "shared.md"
    SHARED_EXISTS="true"
  else
    missing "shared.md"
  fi

  # Check parallel-plan.md
  if [[ -f "${PLAN_DIR}/parallel-plan.md" ]]; then
    found "parallel-plan.md"
    PLAN_EXISTS="true"
  else
    missing "parallel-plan.md"
  fi

  # Count research files: directly in the feature dir (local layout) and in
  # its research/ subdir when present (linear layout).
  RESEARCH_COUNT=$(find "$PLAN_DIR" -maxdepth 1 -name "research-*.md" 2>/dev/null | wc -l | tr -d ' ')
  if [[ -d "${PLAN_DIR}/research" ]]; then
    SUB_COUNT=$(find "${PLAN_DIR}/research" -maxdepth 1 -name "research-*.md" 2>/dev/null | wc -l | tr -d ' ')
    RESEARCH_COUNT=$((RESEARCH_COUNT + SUB_COUNT))
  fi
  if [[ $RESEARCH_COUNT -gt 0 ]]; then
    found "$RESEARCH_COUNT research file(s)"
    find "$PLAN_DIR" -maxdepth 1 -name "research-*.md" -exec basename {} \; | while read -r f; do
      echo "       - $f"
    done
    if [[ -d "${PLAN_DIR}/research" ]]; then
      find "${PLAN_DIR}/research" -maxdepth 1 -name "research-*.md" -exec basename {} \; | while read -r f; do
        echo "       - $f"
      done
    fi
  fi

  # Count analysis files
  ANALYSIS_COUNT=$(find "$PLAN_DIR" -maxdepth 1 -name "analysis-*.md" 2>/dev/null | wc -l | tr -d ' ')
  if [[ $ANALYSIS_COUNT -gt 0 ]]; then
    found "$ANALYSIS_COUNT analysis file(s)"
    find "$PLAN_DIR" -maxdepth 1 -name "analysis-*.md" -exec basename {} \; | while read -r f; do
      echo "       - $f"
    done
  fi

  # Check for requirements
  if [[ -f "${PLAN_DIR}/requirements.md" ]]; then
    found "requirements.md"
  fi

  # Check for other files
  OTHER_COUNT=$(find "$PLAN_DIR" -maxdepth 1 -name "*.md" ! -name "shared.md" ! -name "parallel-plan.md" ! -name "requirements.md" ! -name "research-*.md" ! -name "analysis-*.md" 2>/dev/null | wc -l | tr -d ' ')
  if [[ $OTHER_COUNT -gt 0 ]]; then
    info "$OTHER_COUNT other markdown file(s)"
  fi
fi

# Summary
echo ""
echo "---"
echo "State Summary"
echo ""

# Determine phase
if [[ "$DIR_EXISTS" == "false" ]]; then
  echo "Phase: NOT STARTED"
  echo "  No planning directory exists."
  echo "  Ready to start full workflow."
elif [[ "$SHARED_EXISTS" == "false" ]]; then
  echo "Phase: INITIALIZED (no research)"
  echo "  Directory exists but no shared.md."
  echo "  Ready to start research phase."
elif [[ "$PLAN_EXISTS" == "false" ]]; then
  echo "Phase: RESEARCH COMPLETE"
  echo "  shared.md exists but no parallel-plan.md."
  echo "  Ready for --plan-only or full workflow."
else
  echo "Phase: PLAN COMPLETE"
  echo "  Both shared.md and parallel-plan.md exist."
  echo "  Ready for implementation."
  if [[ "$PLAN_EXISTS" == "true" ]]; then
    warning "Running workflow will overwrite parallel-plan.md"
  fi
fi

# Output machine-readable state
echo ""
echo "---"
echo "Machine-readable state:"
echo "DIR_EXISTS=$DIR_EXISTS"
echo "SHARED_EXISTS=$SHARED_EXISTS"
echo "PLAN_EXISTS=$PLAN_EXISTS"
echo "RESEARCH_COUNT=$RESEARCH_COUNT"
echo "ANALYSIS_COUNT=$ANALYSIS_COUNT"

exit 0
