#!/usr/bin/env bash
# Validate PRP plan artifact structure, task completeness, and file paths
# Usage: validate-prp-plan.sh <plan-file>
#
# Validates:
#   - Required sections from the PRP plan template
#   - Task structure (### Task headings with ACTION/VALIDATE fields)
#   - File path existence (via validate-file-paths.sh)
#   - Parallel-mode annotations (if Batches section present)
#   - Placeholder text detection
#
# Exit codes:
#   0 - Valid (warnings OK)
#   1 - Errors found
#
# Supports monorepo configurations via .plans-config file.
# See resolve-plans-dir.sh for configuration options.

set -uo pipefail
ERRORS=0
WARNINGS=0

# Source shared scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SHARED_DIR="${SCRIPT_DIR}/../../_shared/scripts"

if [[ -f "${SHARED_DIR}/resolve-artifact-store.sh" ]]; then
  # shellcheck source=../../_shared/scripts/resolve-artifact-store.sh
  source "${SHARED_DIR}/resolve-artifact-store.sh"
  # shellcheck source=../../_shared/scripts/artifact-body.sh
  source "${SHARED_DIR}/artifact-body.sh"
fi

if [[ -f "${SHARED_DIR}/validate-file-paths.sh" ]]; then
  # shellcheck source=../../_shared/scripts/validate-file-paths.sh
  source "${SHARED_DIR}/validate-file-paths.sh"
fi

# Colors for output
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

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
        echo "Usage: validate-prp-plan.sh <plan-file> [--store=linear|local]" >&2
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
  echo "Usage: validate-prp-plan.sh <plan-file> [--store=linear|local]"
  echo ""
  echo "Validates the structure and content of a PRP plan artifact."
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

# Check non-empty
if [[ ! -s "$PLAN_FILE" ]]; then
  error "Plan file is empty: $PLAN_FILE"
  exit 1
fi

echo "Validating PRP plan: $PLAN_FILE"
echo ""
# Read file content minus any leading frontmatter block (linear-mode identity
# metadata is not body; see _shared/references/artifact-store.md, Frontmatter).
CONTENT=$(artifact_body "$PLAN_FILE")

# --- Title check ---
echo "Checking document structure..."
# Match against the body only: the H1 must sit in its first five lines.
if grep -q "^# " <<<"$(head -n 5 <<<"$CONTENT")"; then
  success "Title present"
else
  error "Missing title (# heading)"
fi

# --- Required sections ---
echo ""
echo "Checking required sections..."

REQUIRED_SECTIONS=(
  "Summary"
  "Files to Change"
  "Step-by-Step Tasks"
  "Validation Commands"
  "Acceptance Criteria"
)

for section in "${REQUIRED_SECTIONS[@]}"; do
  if grep -q "^## ${section}" <<< "$CONTENT"; then
    success "Found: ## ${section}"
  else
    error "Missing required section: ## ${section}"
  fi
done

# --- Recommended sections ---
echo ""
echo "Checking recommended sections..."

RECOMMENDED_SECTIONS=(
  "User Story"
  "Patterns to Mirror"
  "Testing Strategy"
  "Completion Checklist"
  "Risks"
)

# Optional sections: present → pass, absent → pass (no error, no warning).
# Add new optional sections here as the plan format evolves.
# Optional: --no-worktree plans omit this annotation. Worktree mode is now
# default-on, but plans generated with --no-worktree skip the annotation.
OPTIONAL_SECTIONS=(
  "Worktree Setup"
)

for section in "${RECOMMENDED_SECTIONS[@]}"; do
  if grep -q "^## ${section}" <<< "$CONTENT"; then
    success "Found: ## ${section}"
  else
    warning "Missing recommended section: ## ${section}"
  fi
done

# --- Optional sections (present → note; absent → silent; never error or warning) ---
echo ""
echo "Checking optional sections..."
for section in "${OPTIONAL_SECTIONS[@]}"; do
  if grep -q "^## ${section}" <<< "$CONTENT"; then
    success "Found optional: ## ${section}"
  fi
done

# --- Task structure ---
echo ""
echo "Checking task structure..."
TASK_HEADING_REGEX='^#{3,4}[[:space:]]+Task[[:space:]]+[0-9]+([.][0-9]+)*:'
TASK_COUNT=$(grep -Ec "$TASK_HEADING_REGEX" <<< "$CONTENT" || true)

if [[ $TASK_COUNT -eq 0 ]]; then
  error "No tasks found (expected ### Task N: or #### Task N.N: headings)"
else
  success "$TASK_COUNT task(s) found"
fi

# --- Task field completeness ---
if [[ $TASK_COUNT -gt 0 ]]; then
  echo ""
  echo "Checking task field completeness..."

  # Count tasks with required fields
  ACTION_COUNT=$(grep -c '\*\*ACTION\*\*:' <<< "$CONTENT" || true)
  VALIDATE_COUNT=$(grep -c '\*\*VALIDATE\*\*:' <<< "$CONTENT" || true)
  MIRROR_COUNT=$(grep -c '\*\*MIRROR\*\*:' <<< "$CONTENT" || true)

  if [[ $ACTION_COUNT -ge $TASK_COUNT ]]; then
    success "All tasks have ACTION fields ($ACTION_COUNT)"
  elif [[ $ACTION_COUNT -gt 0 ]]; then
    warning "Only $ACTION_COUNT of $TASK_COUNT tasks have ACTION fields"
  else
    error "No tasks have ACTION fields"
  fi

  if [[ $VALIDATE_COUNT -ge $TASK_COUNT ]]; then
    success "All tasks have VALIDATE fields ($VALIDATE_COUNT)"
  elif [[ $VALIDATE_COUNT -gt 0 ]]; then
    warning "Only $VALIDATE_COUNT of $TASK_COUNT tasks have VALIDATE fields"
  else
    error "No tasks have VALIDATE fields"
  fi

  if [[ $MIRROR_COUNT -ge $TASK_COUNT ]]; then
    success "All tasks have MIRROR fields ($MIRROR_COUNT)"
  elif [[ $MIRROR_COUNT -gt 0 ]]; then
    warning "Only $MIRROR_COUNT of $TASK_COUNT tasks have MIRROR fields"
  else
    warning "No tasks have MIRROR fields"
  fi

  # Optional. Single worktree: per-task **Worktree** is not required; count is informational.
  WORKTREE_FIELD_COUNT=$(grep -c '\*\*Worktree\*\*:' <<< "$CONTENT" || true)
  if [[ $WORKTREE_FIELD_COUNT -gt 0 ]]; then
    success "Per-task **Worktree** field(s) present: $WORKTREE_FIELD_COUNT (deprecated — not required)"
  fi

  # Self-containment heuristic: tasks with all 4 core fields
  COMPLETE_TASKS=0
  # Extract task blocks and check each
  current_has_action=false
  current_has_implement=false
  current_has_mirror=false
  current_has_validate=false
  in_task=false

  while IFS= read -r line; do
    if [[ "$line" =~ $TASK_HEADING_REGEX ]]; then
      # Score previous task
      if $in_task; then
        if $current_has_action && $current_has_implement && $current_has_mirror && $current_has_validate; then
          COMPLETE_TASKS=$((COMPLETE_TASKS + 1))
        fi
      fi
      in_task=true
      current_has_action=false
      current_has_implement=false
      current_has_mirror=false
      current_has_validate=false
    elif $in_task; then
      [[ "$line" == *'**ACTION**:'* ]] && current_has_action=true
      [[ "$line" == *'**IMPLEMENT**:'* ]] && current_has_implement=true
      [[ "$line" == *'**MIRROR**:'* ]] && current_has_mirror=true
      [[ "$line" == *'**VALIDATE**:'* ]] && current_has_validate=true
    fi
  done <<< "$CONTENT"

  # Score last task
  if $in_task && $current_has_action && $current_has_implement && $current_has_mirror && $current_has_validate; then
    COMPLETE_TASKS=$((COMPLETE_TASKS + 1))
  fi

  if [[ $TASK_COUNT -gt 0 ]]; then
    COMPLETENESS=$(( (COMPLETE_TASKS * 100) / TASK_COUNT ))
    if [[ $COMPLETENESS -ge 80 ]]; then
      success "Self-containment: $COMPLETE_TASKS/$TASK_COUNT tasks fully specified ($COMPLETENESS%)"
    else
      warning "Self-containment: only $COMPLETE_TASKS/$TASK_COUNT tasks have all 4 fields ($COMPLETENESS%) — plan may need more detail for single-pass implementation"
    fi
  fi
fi

# --- File path existence ---
echo ""
echo "Checking file paths..."

if type -t validate_file_paths &>/dev/null; then
  # Check Files to Change section
  if grep -q "^## Files to Change" <<< "$CONTENT"; then
    echo "  Checking ## Files to Change..."
    validate_file_paths "$PLAN_FILE" "Files to Change" "table" "true" || true
  fi

  # Check Mandatory Reading section
  if grep -q "^## Mandatory Reading" <<< "$CONTENT"; then
    echo "  Checking ## Mandatory Reading..."
    validate_file_paths "$PLAN_FILE" "Mandatory Reading" "table" "false" || true
  fi
else
  warning "validate-file-paths.sh not found — skipping file path checks"
fi

# --- Parallel-mode checks ---
if grep -q "^## Batches" <<< "$CONTENT"; then
  echo ""
  echo "Checking parallel-mode structure..."

  BATCH_FIELD_COUNT=$(grep -c '\*\*BATCH\*\*:' <<< "$CONTENT" || true)
  DEPENDS_COUNT=$(grep -c 'Depends on' <<< "$CONTENT" || true)

  if [[ $BATCH_FIELD_COUNT -ge $TASK_COUNT && $TASK_COUNT -gt 0 ]]; then
    success "All tasks have BATCH fields ($BATCH_FIELD_COUNT)"
  elif [[ $BATCH_FIELD_COUNT -gt 0 ]]; then
    warning "Only $BATCH_FIELD_COUNT of $TASK_COUNT tasks have BATCH fields"
  else
    error "Batches section exists but no tasks have BATCH fields"
  fi

  if [[ $DEPENDS_COUNT -ge $TASK_COUNT && $TASK_COUNT -gt 0 ]]; then
    success "All tasks have dependency declarations ($DEPENDS_COUNT)"
  elif [[ $DEPENDS_COUNT -gt 0 ]]; then
    warning "Only $DEPENDS_COUNT of $TASK_COUNT tasks have 'Depends on' declarations"
  else
    error "Batches section exists but no dependency declarations found"
  fi

  # Check batch table has entries
  BATCH_TABLE_ROWS=$(echo "$CONTENT" | sed -n '/^## Batches/,/^## /p' | grep -E "^\|[[:space:]]*B[0-9]+" | wc -l | tr -d ' ')
  if [[ $BATCH_TABLE_ROWS -gt 0 ]]; then
    success "Batch table has $BATCH_TABLE_ROWS batch(es)"
  else
    error "Batches section missing batch table entries (expected | B1 | ... rows)"
  fi
fi

# --- Placeholder detection ---
echo ""
echo "Checking for placeholder text..."

PLACEHOLDERS=(
  '\[TODO\]'
  '\[TBD\]'
  '\[PLACEHOLDER\]'
  '\[INSERT'
  '\[ADD'
  '\[FILL'
  'Lorem ipsum'
)

PLACEHOLDER_FOUND=false
for placeholder in "${PLACEHOLDERS[@]}"; do
  if grep -qi "$placeholder" <<< "$CONTENT"; then
    warning "Found potential placeholder text: $placeholder"
    PLACEHOLDER_FOUND=true
  fi
done

if ! $PLACEHOLDER_FOUND; then
  success "No placeholder text found"
fi

# --- Summary ---
echo ""
echo "========================================="
echo "Validation Summary"
echo "  Errors:   $ERRORS"
echo "  Warnings: $WARNINGS"
echo ""

if [[ $TASK_COUNT -gt 0 ]]; then
  echo "Plan statistics:"
  echo "  Tasks: $TASK_COUNT"
  echo "  ACTION fields: $ACTION_COUNT"
  echo "  VALIDATE fields: $VALIDATE_COUNT"
  if grep -q "^## Batches" <<< "$CONTENT"; then
    echo "  Batch fields: $BATCH_FIELD_COUNT"
    echo "  Batch table rows: $BATCH_TABLE_ROWS"
  fi
  if [[ ${WORKTREE_FIELD_COUNT:-0} -gt 0 ]]; then
    echo "  Worktree annotations: $WORKTREE_FIELD_COUNT"
  fi
  echo ""
fi

if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
  echo -e "${GREEN}✓ Plan structure is valid${NC}"
  exit 0
elif [[ $ERRORS -eq 0 ]]; then
  echo -e "${YELLOW}✓ Plan structure is valid with $WARNINGS warning(s)${NC}"
  exit 0
else
  echo -e "${RED}✗ Plan has $ERRORS error(s) and $WARNINGS warning(s)${NC}"
  echo ""
  echo "Fix the errors above before proceeding with implementation."
  exit 1
fi
