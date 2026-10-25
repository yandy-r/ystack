#!/usr/bin/env bash
# Validate deep research output quality

set -euo pipefail
shopt -s globstar 2>/dev/null || true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Usage function
usage() {
    cat << EOF
Usage: $(basename "$0") OUTPUT_DIR

Validate the quality and completeness of deep research output.

Arguments:
    OUTPUT_DIR    The output directory containing research artifacts

Example:
    $(basename "$0") research/ai-deployment
EOF
    exit 1
}

# Check if output directory is provided
if [ $# -eq 0 ]; then
    usage
fi

OUTPUT_DIR="$1"

# Check if output directory exists
if [ ! -d "$OUTPUT_DIR" ]; then
    echo -e "${RED}✗ Error:${NC} Output directory does not exist: $OUTPUT_DIR"
    exit 1
fi

echo -e "${BLUE}Validating deep research output...${NC}"
echo "Directory: $OUTPUT_DIR"
echo ""

# Track validation status
ERRORS=0
WARNINGS=0
CHECKS_PASSED=0
TOTAL_CHECKS=0

# Helper function to check file existence and minimum size
check_file() {
    local file="$1"
    local min_size="${2:-100}"  # Minimum size in bytes (default 100)
    local description="$3"

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    if [ ! -f "$file" ]; then
        echo -e "${RED}✗${NC} Missing: $description"
        echo "  Expected: $file"
        ERRORS=$((ERRORS + 1))
        return 1
    fi

    local size
    size=$(wc -c < "$file")
    if [ "$size" -lt "$min_size" ]; then
        echo -e "${YELLOW}⚠${NC} Too small: $description"
        echo "  File: $file (${size} bytes, expected at least ${min_size})"
        WARNINGS=$((WARNINGS + 1))
        return 1
    fi

    echo -e "${GREEN}✓${NC} Valid: $description (${size} bytes)"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    return 0
}

# Helper function to count lines in file
count_lines() {
    local file="$1"
    if [ -f "$file" ]; then
        wc -l < "$file"
    else
        echo "0"
    fi
}

# Helper function to check for search queries
check_search_queries() {
    local file="$1"
    local persona="$2"
    local min_queries=8

    if [ ! -f "$file" ]; then
        return 1
    fi

    # Count "Search Queries Executed" section entries
    local query_count status=0
    # grep -c prints the count itself; exit 1 only means zero matches. Any
    # other non-zero status (e.g. unreadable file) is a real read failure.
    query_count=$(grep -c "^[0-9]\+\." "$file" 2>/dev/null) || status=$?
    if [ "$status" -gt 1 ]; then
        echo "Error: Failed to read findings file: $file" >&2
        return "$status"
    fi

    if [ "$query_count" -lt "$min_queries" ]; then
        echo -e "${YELLOW}⚠${NC} $persona: Only $query_count search queries (expected $min_queries+)"
        WARNINGS=$((WARNINGS + 1))
    fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 1: Checking Core Structure"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check objective file
check_file "$OUTPUT_DIR/objective.md" 200 "Research objective document"

# Check directory structure
echo ""
echo "Checking directory structure..."
for dir in "persona-findings" "synthesis" "evidence"; do
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if [ -d "$OUTPUT_DIR/$dir" ]; then
        echo -e "${GREEN}✓${NC} Directory exists: $dir/"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Missing directory: $dir/"
        ERRORS=$((ERRORS + 1))
    fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 2: Validating Persona Findings (8 required)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

PERSONAS=(
    "historian:Historian"
    "contrarian:Contrarian"
    "analogist:Analogist"
    "systems-thinker:Systems Thinker"
    "journalist:Journalist"
    "archaeologist:Archaeologist"
    "futurist:Futurist"
    "negative-space:Negative Space Explorer"
)

for persona_entry in "${PERSONAS[@]}"; do
    IFS=':' read -r filename displayname <<< "$persona_entry"
    file="$OUTPUT_DIR/persona-findings/${filename}.md"
    check_file "$file" 500 "Persona: $displayname"
    check_search_queries "$file" "$displayname"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 3: Validating Synthesis Files"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

check_file "$OUTPUT_DIR/synthesis/crucible-analysis.md" 500 "Crucible analysis (ACH)"
check_file "$OUTPUT_DIR/synthesis/contradiction-mapping.md" 300 "Contradiction mapping"
check_file "$OUTPUT_DIR/synthesis/tension-mapping.md" 300 "Tension mapping"
check_file "$OUTPUT_DIR/synthesis/pattern-recognition.md" 300 "Pattern recognition"
check_file "$OUTPUT_DIR/synthesis/negative-space.md" 300 "Negative space analysis"
check_file "$OUTPUT_DIR/synthesis/innovation.md" 300 "Innovation synthesis"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 4: Validating Evidence & Report"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Evidence verification (optional but recommended)
if [ -f "$OUTPUT_DIR/evidence/verification-log.md" ]; then
    check_file "$OUTPUT_DIR/evidence/verification-log.md" 200 "Evidence verification log"
else
    echo -e "${YELLOW}⚠${NC} Optional: Evidence verification log not found"
    WARNINGS=$((WARNINGS + 1))
fi

# Final report
check_file "$OUTPUT_DIR/report.md" 1000 "Final strategic report"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Quality Metrics"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Count total files
TOTAL_FILES=$(find "$OUTPUT_DIR" -type f -name "*.md" | wc -l)
echo "Total markdown files: $TOTAL_FILES"

# Calculate total content size
TOTAL_SIZE=$(find "$OUTPUT_DIR" -type f -name "*.md" -exec wc -c {} + | tail -1 | awk '{print $1}')
TOTAL_SIZE_KB=$((TOTAL_SIZE / 1024))
echo "Total content size: ${TOTAL_SIZE_KB}KB"

# Count lines across all files
TOTAL_LINES=0
for file in "$OUTPUT_DIR"/**/*.md; do
    if [ -f "$file" ]; then
        LINES=$(count_lines "$file")
        TOTAL_LINES=$((TOTAL_LINES + LINES))
    fi
done
echo "Total lines of research: $TOTAL_LINES"

# Estimate reading time (assuming 250 words per minute, ~5 words per line)
WORDS=$((TOTAL_LINES * 5))
READING_MINUTES=$((WORDS / 250))
echo "Estimated reading time: ${READING_MINUTES} minutes"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Validation Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

[ "$TOTAL_CHECKS" -eq 0 ] && SUCCESS_RATE=0 || SUCCESS_RATE=$((CHECKS_PASSED * 100 / TOTAL_CHECKS))

echo "Checks passed: $CHECKS_PASSED / $TOTAL_CHECKS (${SUCCESS_RATE}%)"
echo "Errors: $ERRORS"
echo "Warnings: $WARNINGS"

echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}✓ All validation checks passed!${NC}"
    echo "The research output is complete and meets quality standards."
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}✓ Validation passed with warnings${NC}"
    echo "Review warnings above for potential quality improvements."
    exit 0
else
    echo -e "${RED}✗ Validation failed${NC}"
    echo "Please address the errors above before using the research output."
    exit 1
fi
