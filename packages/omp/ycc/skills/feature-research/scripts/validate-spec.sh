#!/usr/bin/env bash
# Validates feature-spec.md structure and content
# Usage: validate-spec.sh <path-to-feature-spec.md>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RESOLVER="${SCRIPT_DIR}/../../_shared/scripts/resolve-plans-dir.sh"

# Source resolver to get PLANS_ROOT for path resolution
if [[ -f "$RESOLVER" ]]; then
    # shellcheck source=../../_shared/scripts/resolve-plans-dir.sh
    source "$RESOLVER"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Required sections (exact headings)
REQUIRED_SECTIONS=(
    "## Executive Summary"
    "## External Dependencies"
    "## Business Requirements"
    "## Technical Specifications"
    "## UX Considerations"
    "## Recommendations"
    "## Risk Assessment"
    "## Task Breakdown Preview"
)

# Optional but recommended sections
RECOMMENDED_SECTIONS=(
    "## Decisions Needed"
    "## Research References"
)

# Subsections to check for (at least one of these should exist under parent)
SUBSECTION_CHECKS=(
    "External Dependencies:### APIs and Services|### Libraries"
    "Business Requirements:### User Stories|### Business Rules"
    "Technical Specifications:### Architecture|### Data Models|### API Design"
    "UX Considerations:### User Workflows|### UI Patterns"
    "Recommendations:### Implementation|### Technology"
    "Risk Assessment:### Security Considerations|### Technical Risks"
)

errors=0
warnings=0

log_error() {
    echo -e "${RED}ERROR:${NC} $1"
    ((errors++)) || true
}

log_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1"
    ((warnings++)) || true
}

log_success() {
    echo -e "${GREEN}OK:${NC} $1"
}

log_info() {
    echo -e "INFO: $1"
}

# Check if file exists
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <path-to-feature-spec.md>"
    exit 1
fi

SPEC_FILE="$1"

# Always resolve relative paths against PLANS_ROOT
if [[ "$SPEC_FILE" != /* && -n "${PLANS_ROOT:-}" ]]; then
    SPEC_FILE="${PLANS_ROOT}/${SPEC_FILE}"
fi

if [[ ! -f "$SPEC_FILE" ]]; then
    log_error "File not found: $SPEC_FILE"
    exit 1
fi

echo "Validating: $SPEC_FILE"
echo "=========================================="

# Read file content. Match against it with here-strings, not `echo | grep -q`:
# under pipefail an early-exiting reader SIGPIPEs the echo writer and a
# present section reads as missing (YAN-1587).
CONTENT=$(cat "$SPEC_FILE")

# Check for title
if grep -q "^# Feature Spec:" <<<"$CONTENT"; then
    log_success "Title present"
else
    log_error "Missing title (should start with '# Feature Spec: [Name]')"
fi

# Check required sections
echo ""
echo "Checking required sections..."
for section in "${REQUIRED_SECTIONS[@]}"; do
    if grep -q "^${section}" <<<"$CONTENT"; then
        log_success "Found: $section"
    else
        log_error "Missing required section: $section"
    fi
done

# Check recommended sections
echo ""
echo "Checking recommended sections..."
for section in "${RECOMMENDED_SECTIONS[@]}"; do
    if grep -q "^${section}" <<<"$CONTENT"; then
        log_success "Found: $section"
    else
        log_warning "Missing recommended section: $section"
    fi
done

# Check subsections
echo ""
echo "Checking subsections..."
for check in "${SUBSECTION_CHECKS[@]}"; do
    parent="${check%%:*}"
    subsections="${check#*:}"

    # Check if at least one subsection exists
    found=false
    IFS='|' read -ra SUBS <<< "$subsections"
    for sub in "${SUBS[@]}"; do
        if grep -q "^${sub}" <<<"$CONTENT"; then
            found=true
            break
        fi
    done

    if $found; then
        log_success "$parent has required subsections"
    else
        log_warning "$parent is missing subsections (expected one of: ${subsections//|/, })"
    fi
done

# Check for empty sections (section followed immediately by another section or end)
echo ""
echo "Checking for empty sections..."
last_section=""
content_seen=false
while IFS= read -r line; do
    if [[ "$line" =~ ^##[[:space:]] ]]; then
        # If we have a previous section that had no content, report it
        if [[ -n "$last_section" && "$content_seen" == false ]]; then
            log_error "Empty section detected: $last_section"
        fi
        last_section="$line"
        content_seen=false
    elif [[ -n "$line" ]]; then
        # Non-blank, non-heading line means we've seen content
        content_seen=true
    fi
done <<< "$CONTENT"

if [[ -n "$last_section" && "$content_seen" == false ]]; then
    log_error "Empty section detected: $last_section"
fi

# Check Executive Summary length
echo ""
echo "Checking content quality..."
exec_summary=$(echo "$CONTENT" | sed -n '/^## Executive Summary/,/^## /p' | head -n -1 | tail -n +2)
word_count=$(echo "$exec_summary" | wc -w | tr -d ' ')

if [[ $word_count -lt 50 ]]; then
    log_warning "Executive Summary seems too short ($word_count words, recommend 50-100)"
elif [[ $word_count -gt 100 ]]; then
    log_warning "Executive Summary seems too long ($word_count words, recommend 50-100)"
else
    log_success "Executive Summary length is appropriate ($word_count words)"
fi

# Check for placeholder text
echo ""
echo "Checking for placeholder text..."
placeholders=(
    "\[TODO\]"
    "\[PLACEHOLDER\]"
    "\[TBD\]"
    "\[INSERT"
    "\[ADD"
    "\[FILL"
    "Lorem ipsum"
    "example\.com"
)

for placeholder in "${placeholders[@]}"; do
    if grep -qi "$placeholder" <<<"$CONTENT"; then
        log_warning "Found potential placeholder text: $placeholder"
    fi
done

# Check for code blocks
echo ""
echo "Checking code blocks..."
code_blocks=$(echo "$CONTENT" | grep -c '```' || true)
if [[ $code_blocks -gt 0 ]]; then
    # Check if code blocks have language tags
    untagged=$(echo "$CONTENT" | grep -c '^```$' || true)
    if [[ $untagged -gt 0 ]]; then
        log_warning "Found $untagged code blocks without language tags"
    else
        log_success "All code blocks have language tags"
    fi
else
    log_warning "No code blocks found (expected for technical spec)"
fi

# Check for tables
echo ""
echo "Checking tables..."
tables=$(echo "$CONTENT" | grep -c '^|' || true)
if [[ $tables -gt 0 ]]; then
    log_success "Found table content ($tables table rows)"
else
    log_warning "No tables found (expected for data models, risks, etc.)"
fi

# Check for links
echo ""
echo "Checking links..."
links=$(grep -oE '\[([^\]]+)\]\(([^\)]+)\)' <<<"$CONTENT" | wc -l | tr -d ' ' || true)
if [[ $links -gt 0 ]]; then
    log_success "Found $links links"

    # Check for broken internal links to research files
    research_links=$(echo "$CONTENT" | grep -oE '\./research-[a-z]+\.md' || true)
    if [[ -n "$research_links" ]]; then
        dir=$(dirname "$SPEC_FILE")
        while IFS= read -r link; do
            if [[ -n "$link" && ! -f "$dir/$link" ]]; then
                log_warning "Research file not found: $link"
            fi
        done <<< "$research_links"
    fi
else
    log_warning "No links found (expected for documentation references)"
fi

# Summary
echo ""
echo "=========================================="
echo "Validation Summary"
echo "=========================================="
echo -e "Errors:   ${RED}$errors${NC}"
echo -e "Warnings: ${YELLOW}$warnings${NC}"
echo ""

if [[ $errors -gt 0 ]]; then
    echo -e "${RED}FAILED:${NC} Fix $errors error(s) before proceeding"
    exit 1
elif [[ $warnings -gt 0 ]]; then
    echo -e "${YELLOW}PASSED WITH WARNINGS:${NC} Consider addressing $warnings warning(s)"
    exit 0
else
    echo -e "${GREEN}PASSED:${NC} Feature spec is valid"
    exit 0
fi
