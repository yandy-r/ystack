#!/usr/bin/env bash
# Validate parallel-plan.md structure
# Usage: validate-plan.sh <plan-file>
#
# Validates:
# - Required sections exist
# - Task structure is correct
# - Dependencies are properly formatted
# - Phase organization is present
#
# Optional sections (back-compat + forward-compat, never flagged as errors):
# - ## Worktree Setup  — emitted by default in plan-workflow / parallel-plan (opt out: --no-worktree)
#
# Optional per-task fields (never flagged as errors):
# - **Worktree**: ...  — legacy field; new plans use a single **Parent** worktree only
#
# Supports monorepo configurations via .plans-config file.
# See resolve-plans-dir.sh for configuration options.

set -uo pipefail

ERRORS=0
WARNINGS=0

# Source the artifact-store resolver to get PLANS_ROOT/ARTIFACT_ROOT for path
# resolution and the store mode.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SHARED_DIR="${SCRIPT_DIR}/../../../ycc-shared/scripts"

if [[ -f "${SHARED_DIR}/resolve-artifact-store.sh" ]]; then
  # shellcheck source=../../../ycc-shared/scripts/resolve-artifact-store.sh
  source "${SHARED_DIR}/resolve-artifact-store.sh"
  # shellcheck source=../../../ycc-shared/scripts/artifact-body.sh
  source "${SHARED_DIR}/artifact-body.sh"
else
  # ponytail: resolver ships with the plugin; failing beats resolving a
  # relative plan path against the wrong cwd. Upgrade: restore the resolver.
  echo "ERROR: resolve-artifact-store.sh not found at ${SHARED_DIR}" >&2
  echo "Cannot resolve PLANS_ROOT safely; refusing to guess." >&2
  exit 1
fi

# Colors for output
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

error() {
  echo -e "${RED}ERROR${NC}: $1"
  ERRORS=$((ERRORS + 1))
}

warning() {
  echo -e "${YELLOW}WARNING${NC}: $1"
  WARNINGS=$((WARNINGS + 1))
}

success() {
  echo -e "${GREEN}✓${NC} $1"
}

PLAN_FILE=""
STORE_FLAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --store=*)
      STORE_FLAG="$1"
      ;;
    *)
      if [[ -z "$PLAN_FILE" ]]; then
        PLAN_FILE="$1"
      else
        echo "Usage: validate-plan.sh <plan-file> [--store=linear|local]" >&2
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

if [[ -z "$PLAN_FILE" ]]; then
  echo "Usage: validate-plan.sh <plan-file> [--store=linear|local]"
  echo ""
  echo "Validates the structure of a parallel implementation plan."
  exit 1
fi

# Resolve relative paths against the active artifact root: PLANS_ROOT in local
# mode, ARTIFACT_ROOT in linear mode.
if [[ "$PLAN_FILE" != /* && -n "${ARTIFACT_ROOT:-${PLANS_ROOT:-}}" ]]; then
  PLAN_FILE="${ARTIFACT_ROOT:-$PLANS_ROOT}/${PLAN_FILE}"
fi

if [[ ! -f "$PLAN_FILE" ]]; then
  error "Plan file not found: $PLAN_FILE"
  exit 1
fi

echo "Validating plan structure: $PLAN_FILE"
echo ""

# Read file content minus any leading frontmatter block (linear-mode identity
# metadata is not body; see _shared/references/artifact-store.md, Frontmatter).
CONTENT=$(artifact_body "$PLAN_FILE")

# Title check
echo "Checking document structure..."
if grep -q "^# " <<<"$(head -n 5 <<<"$CONTENT")"; then
  success "Title present"
else
  error "Missing title (# heading)"
fi

# Check for overview (text between title and first non-worktree H2)
# Skip ## Worktree Setup — it is an optional annotation block, not the overview.
TITLE_LINE=$(echo "$CONTENT" | grep -n "^# " | head -1 | cut -d: -f1)
if [[ -n "$TITLE_LINE" ]]; then
  OVERVIEW=$(echo "$CONTENT" | sed -n "$((TITLE_LINE+1)),/^## /p" | head -n -1 | grep -v "^## Worktree Setup" | tr -d '\n')
  WORD_COUNT=$(echo "$OVERVIEW" | wc -w | tr -d ' ')

  if [[ $WORD_COUNT -lt 20 ]]; then
    warning "Overview seems short ($WORD_COUNT words). Aim for 3-4 sentences."
  elif [[ $WORD_COUNT -gt 200 ]]; then
    warning "Overview seems long ($WORD_COUNT words). Keep it to 3-4 sentences."
  else
    success "Overview present ($WORD_COUNT words)"
  fi
fi

# Critically Relevant Files section
echo ""
echo "Checking required sections..."
if grep -q "## Critically Relevant Files" <<<"$CONTENT"; then
  success "Critically Relevant Files section present"

  # Count files listed (absolute or relative paths)
  FILE_COUNT=$(echo "$CONTENT" | sed -n '/^## Critically Relevant Files/,/^## /p' | grep -c "^- " || true)
  if [[ $FILE_COUNT -eq 0 ]]; then
    warning "No files listed in Critically Relevant Files section"
  else
    success "  $FILE_COUNT file(s) listed"
  fi
else
  error "Missing 'Critically Relevant Files' section"
fi

# Implementation Plan section
if grep -q "## Implementation Plan" <<<"$CONTENT"; then
  success "Implementation Plan section present"
else
  error "Missing 'Implementation Plan' section"
fi

# Advice section
if grep -q "## Advice" <<<"$CONTENT"; then
  success "Advice section present"

  # Count advice items
  ADVICE_COUNT=$(echo "$CONTENT" | sed -n '/^## Advice/,/^## /p' | grep -c "^- " || true)
  if [[ $ADVICE_COUNT -eq 0 ]]; then
    warning "No advice items found (expected bullet points)"
  else
    success "  $ADVICE_COUNT advice item(s)"
  fi
else
  warning "Missing 'Advice' section"
fi

# Optional. Single-worktree contract: ## Worktree Setup contains only **Parent**;
# per-task **Worktree** lines are legacy and not required in new plans.
echo ""
echo "Checking optional worktree annotations..."
if grep -q "^## Worktree Setup" <<<"$CONTENT"; then
  success "Worktree Setup section present (single feature worktree — see worktree-strategy.md)"
  WORKTREE_TASK_FIELDS=$(echo "$CONTENT" | grep -c '\*\*Worktree\*\*:' || true)
  success "  $WORKTREE_TASK_FIELDS legacy per-task **Worktree** field(s) (expected 0 in new plans)"
else
  echo "       (no ## Worktree Setup — plan was generated with --no-worktree)"
fi

# Phase structure
echo ""
echo "Checking phase structure..."
PHASE_COUNT=$(echo "$CONTENT" | grep -c "^### Phase" || true)
if [[ $PHASE_COUNT -eq 0 ]]; then
  error "No phases found (expected ### Phase N)"
else
  success "$PHASE_COUNT phase(s) found"

  # List phase names
  echo "$CONTENT" | grep "^### Phase" | while read -r line; do
    echo "       - $line"
  done
fi

# Task structure
echo ""
echo "Checking task structure..."
TASK_COUNT=$(echo "$CONTENT" | grep -c "^#### Task" || true)
if [[ $TASK_COUNT -eq 0 ]]; then
  error "No tasks found (expected #### Task N.N)"
else
  success "$TASK_COUNT task(s) found"
fi

# Task dependencies
echo ""
echo "Checking task dependencies..."
DEPENDS_COUNT=$(echo "$CONTENT" | grep -c "Depends on" || true)
if [[ $DEPENDS_COUNT -eq 0 ]]; then
  warning "No task dependencies found"
  echo "       Tasks should include 'Depends on [none]' or 'Depends on [1.1, 2.3]'"
elif [[ $DEPENDS_COUNT -ne $TASK_COUNT ]]; then
  warning "Dependency count ($DEPENDS_COUNT) doesn't match task count ($TASK_COUNT)"
  echo "       Every task should have a 'Depends on' declaration"
else
  success "All tasks have dependency declarations"
fi

# Count independent tasks
INDEPENDENT_COUNT=$(echo "$CONTENT" | grep -c "Depends on \[none\]" || true)
if [[ $INDEPENDENT_COUNT -eq 0 ]]; then
  warning "No independent tasks (Depends on [none]) found"
  echo "       Plans should have at least some tasks that can run in parallel"
else
  success "$INDEPENDENT_COUNT independent task(s) can run in parallel"
fi

# Check for READ THESE BEFORE TASK sections
echo ""
echo "Checking task content..."
READ_BEFORE_COUNT=$(echo "$CONTENT" | grep -c "READ THESE BEFORE TASK" || true)
if [[ $READ_BEFORE_COUNT -lt $TASK_COUNT ]]; then
  warning "Only $READ_BEFORE_COUNT of $TASK_COUNT tasks have 'READ THESE BEFORE TASK' section"
else
  success "All tasks have 'READ THESE BEFORE TASK' sections"
fi

# Check for Files to Create / Files to Modify
FILES_CREATE_COUNT=$(echo "$CONTENT" | grep -c "Files to Create" || true)
FILES_MODIFY_COUNT=$(echo "$CONTENT" | grep -c "Files to Modify" || true)

if [[ $((FILES_CREATE_COUNT + FILES_MODIFY_COUNT)) -lt $TASK_COUNT ]]; then
  warning "Some tasks may be missing file change lists"
else
  success "Tasks have file change lists"
fi

# Summary
echo ""
echo "========================================="
echo "Validation Summary"
echo "  Errors:   $ERRORS"
echo "  Warnings: $WARNINGS"
echo ""

if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
  echo -e "${GREEN}✓ Plan structure is valid${NC}"
  echo ""
  echo "Plan statistics:"
  echo "  Phases: $PHASE_COUNT"
  echo "  Tasks: $TASK_COUNT"
  echo "  Independent tasks: $INDEPENDENT_COUNT"
  exit 0
elif [[ $ERRORS -eq 0 ]]; then
  echo -e "${YELLOW}✓ Plan structure is valid with $WARNINGS warning(s)${NC}"
  echo ""
  echo "Plan statistics:"
  echo "  Phases: $PHASE_COUNT"
  echo "  Tasks: $TASK_COUNT"
  echo "  Independent tasks: $INDEPENDENT_COUNT"
  exit 0
else
  echo -e "${RED}✗ Plan structure has $ERRORS error(s) and $WARNINGS warning(s)${NC}"
  echo ""
  echo "Fix the errors above before proceeding with implementation."
  exit 1
fi
