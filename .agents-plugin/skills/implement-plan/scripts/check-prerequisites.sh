#!/usr/bin/env bash
# Check that required planning documents exist for implementation.
# Usage: check-prerequisites.sh <feature-name> [--store=linear|local] [--plan=<path>]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="${SCRIPT_DIR}/../../../ycc-shared/scripts"
if [[ -f "${SHARED_DIR}/resolve-artifact-store.sh" ]]; then
  # shellcheck source=../../../ycc-shared/scripts/resolve-artifact-store.sh
  source "${SHARED_DIR}/resolve-artifact-store.sh"
else
  echo "ERROR: resolve-artifact-store.sh not found at ${SHARED_DIR}" >&2
  echo "Cannot resolve plans directory safely; refusing to guess." >&2
  exit 1
fi
# shellcheck source=../../../ycc-shared/scripts/artifact-body.sh
source "${SHARED_DIR}/artifact-body.sh"
FEATURE_NAME='' STORE_FLAG='' PLAN_FILE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --store=*) STORE_FLAG=$1 ;;
    --plan=*)
      PLAN_FILE=${1#--plan=}
      [[ -n "$PLAN_FILE" ]] || { echo 'ERROR: Plan path required' >&2; exit 1; }
      ;;
    --*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    *)
      if [[ -n "$FEATURE_NAME" ]]; then
        echo 'Usage: check-prerequisites.sh <feature-name> [--store=linear|local] [--plan=<path>]' >&2
        exit 1
      fi
      FEATURE_NAME=$1
      ;;
  esac
  shift
done
if [[ -n "$STORE_FLAG" ]]; then resolve_artifact_store "$PWD" "$STORE_FLAG" || exit 1; fi
if [[ -z "$FEATURE_NAME" && -z "$PLAN_FILE" ]]; then
  echo "ERROR: Feature name required"
  echo 'Usage: check-prerequisites.sh <feature-name> [--store=linear|local] [--plan=<path>]' >&2
  exit 1
fi
EXPLICIT_PLAN=$PLAN_FILE
if [[ -n "$PLAN_FILE" ]]; then
  PLAN_DIR=$(dirname "$PLAN_FILE")
  if [[ -d "$PLAN_DIR" ]]; then
    PLAN_DIR=$(CDPATH='' cd -- "$PLAN_DIR" >/dev/null && pwd -P)
  elif [[ "$PLAN_DIR" != /* ]]; then
    PLAN_DIR="$PWD/$PLAN_DIR"
  fi
  PLAN_FILE="${PLAN_DIR}/$(basename "$PLAN_FILE")"
  FEATURE_NAME=${FEATURE_NAME:-${PLAN_DIR##*/}}
else
  PLAN_DIR="$(get_plans_feature_dir "$FEATURE_NAME")" || exit 1
  PLAN_FILE="${PLAN_DIR}/parallel-plan.md"
fi
# Guidance follows the input: an explicit plan outside the linear cache is a
# local plan (artifact-store.md Inputs) even when the store resolves to linear.
LINEAR_INPUT=0
if [[ "${ARTIFACT_STORE:-}" == linear ]]; then
  if [[ -z "$EXPLICIT_PLAN" || "$PLAN_DIR/" == "${ARTIFACT_DIR}/"* ]]; then LINEAR_INPUT=1; fi
fi
missing_guidance() {
  if [[ "$LINEAR_INPUT" == 1 ]]; then
    echo 'Run Lookup and hydrate the plan from Linear before implementation.'
    echo 'See artifact-store.md, Implementation skills (Resolve and hydrate).'
    local local_dir=''
    if [[ -z "$EXPLICIT_PLAN" && "${ARTIFACT_STORE_SOURCE:-}" == default ]]; then
      local_dir=$( (resolve_artifact_store "$PWD" --store=local && get_plans_feature_dir "$FEATURE_NAME") 2>/dev/null) || local_dir=''
    fi
    if [[ -n "$local_dir" && -d "$local_dir" ]]; then
      echo "Local plan found at ${local_dir}; rerun with --store=local or set store: local in .plans-config."
    fi
  elif [[ "$1" == dir ]]; then
    echo "Create the planning documents first:"
    echo "  1. Run /shared-context ${FEATURE_NAME}"
    echo "  2. Run /parallel-plan ${FEATURE_NAME}"
  else
    echo "The implementation requires a parallel plan to be created first."
    echo "Run: /parallel-plan ${FEATURE_NAME}"
    echo ""
    echo "This will create parallel-plan.md with detailed implementation tasks."
  fi
}
if [[ ! -d "$PLAN_DIR" ]]; then
  echo "ERROR: Plan directory not found: $PLAN_DIR"
  echo ""
  missing_guidance dir
  exit 1
fi
if [[ ! -f "$PLAN_FILE" ]]; then
  echo "ERROR: ${PLAN_FILE} not found"
  echo ""
  missing_guidance file
  exit 1
fi
if [[ ! -f "${PLAN_DIR}/shared.md" ]]; then
  echo "WARNING: ${PLAN_DIR}/shared.md not found"
  echo "The shared context document is recommended for implementation."
  echo "Consider running /shared-context ${FEATURE_NAME} first."
  echo ""
fi

echo "Prerequisites satisfied"
echo "  Found: ${PLAN_FILE}"
if [[ -f "${PLAN_DIR}/shared.md" ]]; then echo "  Found: ${PLAN_DIR}/shared.md"; fi
# grep -c returns 1 for zero matches; other statuses are real read failures.
plan_count() {
  local pattern="$1" status=0 count
  if [[ ! -r "$PLAN_FILE" ]]; then
    echo "ERROR: Failed to read ${PLAN_FILE}" >&2
    exit 2
  fi
  count=$(grep -cE "$pattern" < <(artifact_body "$PLAN_FILE")) || status=$?
  if [[ "$status" -gt 1 ]]; then
    echo "ERROR: Failed to read ${PLAN_FILE}" >&2
    exit "$status"
  fi
  echo "$count"
}
TASK_COUNT=$(plan_count "^#### Task")
echo "  Tasks in plan: ${TASK_COUNT}"
PHASE_COUNT=$(plan_count "^### (Phase|Batch)")
echo "  Phases/Batches in plan: ${PHASE_COUNT}"
INDEPENDENT_COUNT=$(plan_count "(Depends on \[none\]|\*\*Dependencies\*\*: *[Nn]one)")
echo "  Independent tasks: ${INDEPENDENT_COUNT}"
exit 0
