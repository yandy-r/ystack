#!/usr/bin/env bash
# Check that required planning documents exist for report generation
# Usage: check-prerequisites.sh <feature-name> [--store=linear|local]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="${SCRIPT_DIR}/../../_shared/scripts"
for helper in resolve-artifact-store.sh artifact-body.sh; do
  if [[ ! -f "${SHARED_DIR}/${helper}" ]]; then
    echo "ERROR: ${helper} not found at ${SHARED_DIR}" >&2
    exit 1
  fi
done
# shellcheck source=../../_shared/scripts/resolve-artifact-store.sh
source "${SHARED_DIR}/resolve-artifact-store.sh"
# shellcheck source=../../_shared/scripts/artifact-body.sh
source "${SHARED_DIR}/artifact-body.sh"

FEATURE_NAME='' STORE_FLAG=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --store=*) STORE_FLAG=$1 ;;
    --*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    *)
      if [[ -n "$FEATURE_NAME" ]]; then
        echo "Usage: check-prerequisites.sh <feature-name> [--store=linear|local]" >&2
        exit 1
      fi
      FEATURE_NAME=$1
      ;;
  esac
  shift
done

if [[ -z "$FEATURE_NAME" ]]; then
  echo "ERROR: Feature name required"
  echo "Usage: check-prerequisites.sh <feature-name> [--store=linear|local]"
  exit 1
fi

if [[ -n "$STORE_FLAG" ]]; then
  resolve_artifact_store "$PWD" "$STORE_FLAG" || exit 1
elif [[ "${ARTIFACT_STORE_SOURCE:-}" == default ]]; then
  # Existing local plans keep local mode (artifact-store.md Inputs).
  local_dir=$( (resolve_artifact_store "$PWD" --store=local && get_plans_feature_dir "$FEATURE_NAME") 2>/dev/null) || local_dir=''
  if [[ -n "$local_dir" && -d "$local_dir" ]]; then
    resolve_artifact_store "$PWD" --store=local || exit 1
    echo "Using local plan at ${local_dir}; pin with store: local in .plans-config"
  fi
fi
[[ -n "${ARTIFACT_STORE:-}" ]] || exit 1
PLAN_DIR="$(get_plans_feature_dir "$FEATURE_NAME")" || exit 1

if [[ ! -d "$PLAN_DIR" ]]; then
  echo "ERROR: Plan directory not found: $PLAN_DIR"
  echo ""
  echo "The report requires a planning directory."
  if [[ "$ARTIFACT_STORE" == linear ]]; then
    echo "Run Lookup and hydrate the plan from Linear first (artifact-store.md, Lookup and Load),"
    echo "or rerun with --store=local for a plan under docs/plans."
  else
    echo "Either:"
    echo "  1. Create planning documents: /shared-context ${FEATURE_NAME}"
    echo "  2. Create the directory manually: mkdir -p ${PLAN_DIR}"
  fi
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
echo "  Store: ${ARTIFACT_STORE}"
echo "  Target: ${PLAN_DIR}/report.md"

if [[ -f "${PLAN_DIR}/parallel-plan.md" ]]; then
  echo "  Found: ${PLAN_DIR}/parallel-plan.md"

  # Count tasks in the plan body (identity frontmatter is metadata, not
  # content). grep -c prints the count itself; exit 1 only means zero matches.
  # Any other non-zero status is a real read failure. The body is captured
  # first so an artifact_body failure is seen (a process substitution would
  # hide it), then matched with a here-string, never `artifact_body | grep`.
  TASK_COUNT_STATUS=0
  if [[ ! -r "${PLAN_DIR}/parallel-plan.md" ]] || ! PLAN_BODY=$(artifact_body "${PLAN_DIR}/parallel-plan.md"); then
    echo "ERROR: Failed to read ${PLAN_DIR}/parallel-plan.md" >&2
    exit 2
  fi
  TASK_COUNT=$(grep -c "^#### Task" <<<"$PLAN_BODY") || TASK_COUNT_STATUS=$?
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
