#!/usr/bin/env bash
# Check that required planning documents exist for report generation
# Usage: check-prerequisites.sh <feature-name>

set -euo pipefail

FEATURE_NAME="${1:-}"
PLAN_DIR="docs/plans/${FEATURE_NAME}"

if [[ -z "$FEATURE_NAME" ]]; then
  echo "ERROR: Feature name required"
  echo "Usage: check-prerequisites.sh <feature-name>"
  exit 1
fi

if [[ ! -d "$PLAN_DIR" ]]; then
  echo "ERROR: Plan directory not found: $PLAN_DIR"
  echo ""
  echo "The report requires a planning directory."
  echo "Either:"
  echo "  1. Create planning documents: /shared-context ${FEATURE_NAME}"
  echo "  2. Create the directory manually: mkdir -p ${PLAN_DIR}"
  exit 1
fi

if [[ ! -f "${PLAN_DIR}/parallel-plan.md" ]]; then
  echo "WARNING: ${PLAN_DIR}/parallel-plan.md not found"
  echo ""
  echo "The report can be generated without parallel-plan.md, but it will"
  echo "have limited context about the implementation."
  echo ""
  echo "Consider creating the plan first: /parallel-plan ${FEATURE_NAME}"
  echo ""
  # Not a fatal error - report can still be generated
fi

if [[ ! -f "${PLAN_DIR}/shared.md" ]]; then
  echo "WARNING: ${PLAN_DIR}/shared.md not found"
  echo "The shared context document would provide additional context."
  echo ""
fi

echo "Report can be generated for: ${FEATURE_NAME}"
echo "  Target: ${PLAN_DIR}/report.md"

if [[ -f "${PLAN_DIR}/parallel-plan.md" ]]; then
  echo "  Found: ${PLAN_DIR}/parallel-plan.md"

  # Count tasks in the plan. grep -c prints the count itself; exit 1 only
  # means zero matches. Any other non-zero status is a real read failure.
  TASK_COUNT_STATUS=0
  TASK_COUNT=$(grep -c "^#### Task" "${PLAN_DIR}/parallel-plan.md" 2>/dev/null) || TASK_COUNT_STATUS=$?
  if [[ "$TASK_COUNT_STATUS" -gt 1 ]]; then
    echo "ERROR: Failed to read ${PLAN_DIR}/parallel-plan.md" >&2
    exit "$TASK_COUNT_STATUS"
  fi
  echo "  Tasks in plan: ${TASK_COUNT}"
fi

if [[ -f "${PLAN_DIR}/shared.md" ]]; then
  echo "  Found: ${PLAN_DIR}/shared.md"
fi

# Check if report already exists
if [[ -f "${PLAN_DIR}/report.md" ]]; then
  echo ""
  echo "NOTE: ${PLAN_DIR}/report.md already exists"
  echo "It will be overwritten if you proceed."
fi

exit 0
