#!/usr/bin/env bash
# Validate shared.md document structure and content
# Usage: validate-shared.sh <path-to-shared.md>
#
# Validates:
# - Required sections exist
# - Overview is appropriate length
# - File paths are valid
# - Patterns have example links
# - Documentation has must-read markers

set -uo pipefail

ERRORS=0
WARNINGS=0

# Source the artifact-store resolver to get PLANS_ROOT/ARTIFACT_ROOT for path
# resolution and the store mode.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SHARED_DIR="${SCRIPT_DIR}/../../_shared/scripts"

if [[ -f "${SHARED_DIR}/resolve-artifact-store.sh" ]]; then
  # shellcheck source=../../_shared/scripts/resolve-artifact-store.sh
  source "${SHARED_DIR}/resolve-artifact-store.sh"
  # shellcheck source=../../_shared/scripts/artifact-body.sh
  source "${SHARED_DIR}/artifact-body.sh"
else
  # ponytail: resolver ships with the plugin; failing beats guessing a wrong
  # relative docs/plans. Upgrade path: restore resolver alongside this script.
  echo "ERROR: resolve-artifact-store.sh not found at ${SHARED_DIR}" >&2
  echo "Cannot resolve plans directory safely; refusing to guess." >&2
  exit 1
fi

# Resolve relative paths against the active artifact root: PLANS_ROOT in local
# mode, ARTIFACT_ROOT in linear mode.
VALIDATE_ROOT="${ARTIFACT_ROOT:-${PLANS_ROOT:-$(pwd)}}"

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

SHARED_FILE=""
STORE_FLAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --store=*)
      STORE_FLAG="$1"
      ;;
    *)
      if [[ -z "$SHARED_FILE" ]]; then
        SHARED_FILE="$1"
      else
        echo "Usage: validate-shared.sh <path-to-shared.md> [--store=linear|local]" >&2
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

if [[ -z "$SHARED_FILE" ]]; then
  echo "Usage: validate-shared.sh <path-to-shared.md> [--store=linear|local]"
  echo ""
  echo "Validates the structure and content of a shared.md document."
  exit 1
fi

# Resolve relative paths against the active artifact root: PLANS_ROOT in local
# mode, ARTIFACT_ROOT in linear mode.
if [[ "$SHARED_FILE" != /* && -n "${ARTIFACT_ROOT:-${PLANS_ROOT:-}}" ]]; then
  SHARED_FILE="${ARTIFACT_ROOT:-$PLANS_ROOT}/${SHARED_FILE}"
fi

if [[ ! -f "$SHARED_FILE" ]]; then
  error "File not found: $SHARED_FILE"
  exit 1
fi

echo "Validating: $SHARED_FILE"
echo "---"

# Read file content minus any leading frontmatter block (linear-mode identity
# metadata is not body; see _shared/references/artifact-store.md, Frontmatter).
# Match against it with here-strings, not `echo | grep -q`: under pipefail an
# early-exiting reader SIGPIPEs the echo writer and a present section reads as
# missing (YAN-1285).
CONTENT=$(artifact_body "$SHARED_FILE")

# Check for required sections
check_section() {
  local section="$1"
  local required="$2"

  if grep -q "^## $section" <<<"$CONTENT"; then
    success "Found section: $section"
    return 0
  else
    if [[ "$required" == "true" ]]; then
      error "Missing required section: $section"
    else
      warning "Missing optional section: $section"
    fi
    return 1
  fi
}

echo ""
echo "Checking required sections..."
check_section "Relevant Files" "true" || true
check_section "Relevant Patterns" "true" || true
check_section "Relevant Docs" "true" || true

echo ""
echo "Checking optional sections..."
check_section "Relevant Tables" "false" || true

# Check for title (H1)
echo ""
echo "Checking document structure..."
if grep -q "^# " <<<"$(head -n 5 <<<"$CONTENT")"; then
  success "Found document title (H1)"
else
  error "Missing document title (should start with '# ')"
fi

# Check for overview paragraph
TITLE_LINE=$(echo "$CONTENT" | grep -n "^# " | head -1 | cut -d: -f1)
if [[ -n "$TITLE_LINE" ]]; then
  # Get content between title and first H2
  # Extract content between title and first H2, excluding the H2 line
  OVERVIEW=$(echo "$CONTENT" | sed -n "$((TITLE_LINE+1)),/^## /p" | sed '$d' | tr -d '\n')
  WORD_COUNT=$(echo "$OVERVIEW" | wc -w | tr -d ' ')

  if [[ $WORD_COUNT -lt 20 ]]; then
    warning "Overview seems short ($WORD_COUNT words). Aim for 3-4 sentences."
  elif [[ $WORD_COUNT -gt 150 ]]; then
    warning "Overview seems long ($WORD_COUNT words). Keep it to 3-4 sentences."
  else
    success "Overview length looks good ($WORD_COUNT words)"
  fi
fi

# Check file paths in Relevant Files section
# Supports formats:
#   - /absolute/path/to/file: description
#   - relative/path/to/file: description
#   - `/path/to/file`: description
echo ""
echo "Checking file paths..."

# Extract the Relevant Files section
FILES_SECTION=$(echo "$CONTENT" | sed -n '/^## Relevant Files/,/^## /p' | head -n -1)

# Extract paths from list items - handle absolute, relative, with/without backticks
FILE_PATHS=$(echo "$FILES_SECTION" | grep -E "^- " | sed -E 's/^- `?([^`:]+)`?[:]?.*/\1/' | sed 's/[[:space:]]*$//')

if [[ -z "$FILE_PATHS" ]]; then
  warning "No file paths found in Relevant Files section"
else
  VALID_PATHS=0
  INVALID_PATHS=0

  while IFS= read -r path; do
    # Skip empty lines and section headers
    [[ -z "$path" ]] && continue
    [[ "$path" == "##"* ]] && continue

    if [[ "$path" == /* ]]; then
      # Absolute path - check directly
      if [[ -f "$path" ]] || [[ -d "$path" ]]; then
        VALID_PATHS=$((VALID_PATHS + 1))
      else
        warning "File not found: $path"
        INVALID_PATHS=$((INVALID_PATHS + 1))
      fi
    else
      # Relative path - resolve against VALIDATE_ROOT
      FULL_PATH="${VALIDATE_ROOT}/${path}"
      if [[ -f "$FULL_PATH" ]] || [[ -d "$FULL_PATH" ]]; then
        VALID_PATHS=$((VALID_PATHS + 1))
      else
        warning "File not found: $path (checked: $FULL_PATH)"
        INVALID_PATHS=$((INVALID_PATHS + 1))
      fi
    fi
  done <<< "$FILE_PATHS"

  if [[ $INVALID_PATHS -eq 0 ]]; then
    success "All $VALID_PATHS file paths are valid"
  else
    echo "  Valid: $VALID_PATHS, Invalid: $INVALID_PATHS"
  fi
fi

# Check for pattern examples
echo ""
echo "Checking patterns..."
PATTERN_COUNT=$(echo "$CONTENT" | sed -n '/^## Relevant Patterns/,/^## /p' | grep -c "^\*\*" || true)

if [[ $PATTERN_COUNT -eq 0 ]]; then
  warning "No patterns found (format: **Pattern Name**: description)"
else
  success "Found $PATTERN_COUNT pattern(s)"

  # Check if patterns have example links
  PATTERNS_WITH_LINKS=$(echo "$CONTENT" | sed -n '/^## Relevant Patterns/,/^## /p' | grep -c "\[.*\](.*)" || true)
  if [[ $PATTERNS_WITH_LINKS -lt $PATTERN_COUNT ]]; then
    warning "Some patterns missing example links"
  fi
fi

# Check for must-read documentation
echo ""
echo "Checking documentation references..."
MUST_READ_COUNT=$(echo "$CONTENT" | sed -n '/^## Relevant Docs/,/^## /p' | grep -c "_must_" || true)

if [[ $MUST_READ_COUNT -eq 0 ]]; then
  warning "No 'must read' documentation marked (use: You _must_ read this...)"
else
  success "Found $MUST_READ_COUNT must-read documentation reference(s)"
fi

# Summary
echo ""
echo "---"
echo "Validation Summary"
echo "  Errors:   $ERRORS"
echo "  Warnings: $WARNINGS"

if [[ $ERRORS -gt 0 ]]; then
  echo ""
  echo -e "${RED}Validation failed with $ERRORS error(s)${NC}"
  echo "Fix the errors above before proceeding with planning."
  exit 1
elif [[ $WARNINGS -gt 0 ]]; then
  echo ""
  echo -e "${YELLOW}Validation passed with $WARNINGS warning(s)${NC}"
  echo "Consider addressing the warnings for better quality."
  exit 0
else
  echo ""
  echo -e "${GREEN}Validation passed!${NC}"
  echo "Ready for planning phase."
  exit 0
fi
