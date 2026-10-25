#!/usr/bin/env bash
# Check that required planning documents exist for implementation
# Usage: check-prerequisites.sh <feature-name>
#
# Supports monorepo configurations via .plans-config file.
# See resolve-plans-dir.sh for configuration options.

set -euo pipefail

FEATURE_NAME="${1:-}"

# Source the shared resolver to get PLANS_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="${SCRIPT_DIR}/../../../ycc-shared/scripts"

if [[ -f "${SHARED_DIR}/resolve-plans-dir.sh" ]]; then
  # shellcheck source=../../../ycc-shared/scripts/resolve-plans-dir.sh
  source "${SHARED_DIR}/resolve-plans-dir.sh"
else
  # Fallback if shared resolver not found
  echo "WARNING: resolve-plans-dir.sh not found, using default path" >&2
  PLANS_DIR="docs/plans"
fi

PLAN_DIR="${PLANS_DIR}/${FEATURE_NAME}"

if [[ -z "$FEATURE_NAME" ]]; then
  echo "ERROR: Feature name required"
  echo "Usage: check-prerequisites.sh <feature-name>"
  exit 1
fi

if [[ ! -d "$PLAN_DIR" ]]; then
  echo "ERROR: Plan directory not found: $PLAN_DIR"
  echo ""
  echo "Create the planning documents first:"
  echo "  1. Run /shared-context ${FEATURE_NAME}"
  echo "  2. Run /parallel-plan ${FEATURE_NAME}"
  exit 1
fi

if [[ ! -f "${PLAN_DIR}/parallel-plan.md" ]]; then
  echo "ERROR: ${PLAN_DIR}/parallel-plan.md not found"
  echo ""
  echo "The implementation requires a parallel plan to be created first."
  echo "Run: /parallel-plan ${FEATURE_NAME}"
  echo ""
  echo "This will create parallel-plan.md with detailed implementation tasks."
  exit 1
fi

if [[ ! -f "${PLAN_DIR}/shared.md" ]]; then
  echo "WARNING: ${PLAN_DIR}/shared.md not found"
  echo "The shared context document is recommended for implementation."
  echo "Consider running /shared-context ${FEATURE_NAME} first."
  echo ""
fi

echo "Prerequisites satisfied"
echo "  Found: ${PLAN_DIR}/parallel-plan.md"

if [[ -f "${PLAN_DIR}/shared.md" ]]; then
  echo "  Found: ${PLAN_DIR}/shared.md"
fi

# Count pattern matches in the plan. grep -c prints the count itself; exit 1
# only means zero matches. Any other non-zero status is a real read failure.
plan_count() {
  local pattern="$1" status=0 count
  count=$(grep -cE "$pattern" "${PLAN_DIR}/parallel-plan.md" 2>/dev/null) || status=$?
  if [[ "$status" -gt 1 ]]; then
    echo "ERROR: Failed to read ${PLAN_DIR}/parallel-plan.md" >&2
    exit "$status"
  fi
  echo "$count"
}

# Count tasks in the plan
TASK_COUNT=$(plan_count "^#### Task")
echo "  Tasks in plan: ${TASK_COUNT}"

# Count phases
PHASE_COUNT=$(plan_count "^### (Phase|Batch)")
echo "  Phases/Batches in plan: ${PHASE_COUNT}"

# Count independent tasks
INDEPENDENT_COUNT=$(plan_count "(Depends on \[none\]|\*\*Dependencies\*\*: *[Nn]one)")
echo "  Independent tasks: ${INDEPENDENT_COUNT}"

exit 0
