#!/usr/bin/env bash
#
# Cleanup Report Generation Script
# Combines findings from all agents into a single comprehensive report
#
# Usage: generate-report.sh [target-directory]
#
# Exit codes:
#   0 - Report generated successfully
#   1 - Invalid usage or missing findings
#   2 - Failed to generate report
#

set -euo pipefail

# Any unexpected failure (including a failed findings read) maps to exit 2 so
# the script never claims success after a partial run, and the partial report
# is removed. Usage errors below exit 1 explicitly and do not pass through this
# trap. Functions do not inherit ERR (no set -E), so they must `|| return`.
trap 'echo "Error: Failed to generate report (line ${LINENO}: ${BASH_COMMAND})" >&2; if [[ -n "${REPORT_PATH:-}" ]]; then rm -f "$REPORT_PATH" "$REPORT_PATH.tmp" || true; fi; exit 2' ERR

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Get target directory from argument or use current directory
TARGET_DIR="${1:-.}"

if [[ ! -d "$TARGET_DIR" ]]; then
    echo -e "${RED}Error: Directory does not exist: $TARGET_DIR${NC}" >&2
    exit 1
fi

# Convert to absolute path
TARGET_DIR=$(cd "$TARGET_DIR" && pwd) || {
    echo -e "${RED}Error: Cannot access directory: $TARGET_DIR${NC}" >&2
    exit 1
}

# Findings directory
FINDINGS_DIR="$TARGET_DIR/.cleanup-analysis/findings"

if [[ ! -d "$FINDINGS_DIR" ]]; then
    echo -e "${RED}Error: Findings directory not found: $FINDINGS_DIR${NC}" >&2
    echo "Agent analysis must be run first." >&2
    exit 1
fi

# Report output path
REPORT_PATH="$TARGET_DIR/.cleanup-analysis/cleanup-report.md"

echo "Generating cleanup report..."
echo "Target Directory: $TARGET_DIR"
echo "Findings Directory: $FINDINGS_DIR"
echo "Report Output: $REPORT_PATH"
echo ""

# Function to count files in a findings file
count_files() {
    local findings_file="$1"
    if [[ -f "$findings_file" ]]; then
        # grep -c prints the count itself; exit 1 only means zero matches. Any
        # other non-zero status (e.g. unreadable file) is a real failure.
        local count status=0
        count=$(grep -c '^###' "$findings_file") || status=$?
        if [[ "$status" -gt 1 ]]; then
            echo "Error: Failed to read findings file: $findings_file" >&2
            return "$status"
        fi
        echo "$count"
    else
        echo "0"
    fi
}

# Function to extract total size from findings
extract_total_size() {
    local findings_file="$1"
    if [[ -f "$findings_file" ]]; then
        # grep exit 1 means no Total Size line; anything above 1 is a read error.
        local line status=0
        line=$(grep -i "^- \*\*Total.*Size\*\*:" "$findings_file") || status=$?
        if [[ "$status" -gt 1 ]]; then
            echo "Error: Failed to read findings file: $findings_file" >&2
            return "$status"
        fi
        if [[ "$status" -eq 1 ]]; then
            echo "0 B"
        else
            line="${line%%$'\n'*}"
            echo "${line##*: }"
        fi
    else
        echo "0 B"
    fi
}

# Initialize counters
total_files=0

# Check which findings exist
declare -A findings_exist=(
    ["code-files"]=0
    ["binaries"]=0
    ["assets"]=0
    ["documentation"]=0
    ["config"]=0
    ["docker"]=0
)

for category in "${!findings_exist[@]}"; do
    if [[ -f "$FINDINGS_DIR/${category}.md" ]]; then
        findings_exist[$category]=1
        file_count=$(count_files "$FINDINGS_DIR/${category}.md")
        total_files=$((total_files + file_count))
    fi
done

echo "Found findings for:"
for category in "${!findings_exist[@]}"; do
    if [[ ${findings_exist[$category]} -eq 1 ]]; then
        file_count=$(count_files "$FINDINGS_DIR/${category}.md")
        echo "  - $category: $file_count files"
    fi
done

echo ""
echo "Generating report..."

# Get current date and time
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
REPORT_DATE=$(date +"%Y-%m-%d")

# Start building the report
cat > "$REPORT_PATH" << 'EOF_HEADER'
---
title: Project Cleanup Report
date: REPORT_DATE_PLACEHOLDER
target_directory: TARGET_DIR_PLACEHOLDER
project_type: PROJECT_TYPE_PLACEHOLDER
analysis_mode: full
---

# Project Cleanup Report

**Generated**: TIMESTAMP_PLACEHOLDER
**Target Directory**: TARGET_DIR_PLACEHOLDER
**Project Type**: PROJECT_TYPE_PLACEHOLDER
**Total Files Analyzed**: TOTAL_FILES_PLACEHOLDER
**Analysis Duration**: (Completed by agents)

---

## Executive Summary

### Overview

This cleanup analysis identified **TOTAL_FILES_PLACEHOLDER** unnecessary files that can potentially be removed from the project.

### Quick Stats

| Category       | Files | Size  | Risk Level      |
| -------------- | ----- | ----- | --------------- |
EOF_HEADER

# Replace placeholders
replace_in_file() {
    local file="$1"
    local pattern="$2"
    local replacement="$3"
    local tmp_file

    tmp_file="${file}.tmp"
    sed "s|${pattern}|${replacement}|g" "$file" > "$tmp_file" || return
    mv "$tmp_file" "$file" || return
}

replace_in_file "$REPORT_PATH" "REPORT_DATE_PLACEHOLDER" "$REPORT_DATE"
replace_in_file "$REPORT_PATH" "TIMESTAMP_PLACEHOLDER" "$TIMESTAMP"
replace_in_file "$REPORT_PATH" "TARGET_DIR_PLACEHOLDER" "$TARGET_DIR"
replace_in_file "$REPORT_PATH" "TOTAL_FILES_PLACEHOLDER" "$total_files"

# Detect project type (or use cached value)
if [[ -n "${DETECTED_PROJECT_TYPE:-}" ]]; then
    PROJECT_TYPE="$DETECTED_PROJECT_TYPE"
else
    PROJECT_TYPE="Generic"
fi
replace_in_file "$REPORT_PATH" "PROJECT_TYPE_PLACEHOLDER" "$PROJECT_TYPE"

# Add category stats
for category in code-files binaries assets documentation config docker; do
    if [[ ${findings_exist[${category}]} -eq 1 ]]; then
        file_count=$(count_files "$FINDINGS_DIR/${category}.md")
        size=$(extract_total_size "$FINDINGS_DIR/${category}.md")
        risk="Mixed"

        cat_display=$(echo "$category" | sed 's/-/ /g' | awk '{for (i=1; i<=NF; i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}')
        printf "| %-14s | %-5s | %-5s | %-15s |\n" "$cat_display" "$file_count" "$size" "$risk" >> "$REPORT_PATH"
    fi
done

# Continue report with findings sections
cat >> "$REPORT_PATH" << 'EOF_SECTIONS'

---

## Findings by Category

EOF_SECTIONS

# Include each category's findings
for category in code-files binaries assets documentation config docker; do
    if [[ ${findings_exist[${category}]} -eq 1 ]]; then
        echo "" >> "$REPORT_PATH"

        cat_display=$(echo "$category" | sed 's/-/ /g' | awk '{for (i=1; i<=NF; i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}')
        echo "### $cat_display" >> "$REPORT_PATH"
        echo "" >> "$REPORT_PATH"

        tail -n +4 "$FINDINGS_DIR/${category}.md" >> "$REPORT_PATH"
        echo "" >> "$REPORT_PATH"
    fi
done

# Add risk assessment and recommendations
cat >> "$REPORT_PATH" << 'EOF_RISK'

---

## Risk Assessment

### Overall Risk Level

Based on the findings above, the cleanup operation has a **MIXED** risk level:

- Some files are clearly safe to remove (backups, temp files)
- Some files require human review (orphaned code, unused assets)
- Some files need careful consideration (configs, documentation)

### Recommendations

1. **Review Category by Category**: Don't remove all files at once
2. **Start with Low Risk**: Begin with obvious temp/backup files
3. **Test After Each Category**: Verify project still works after removing each category
4. **Use Safe Mode**: Enable --safe-mode for confirmation prompts
5. **Backup First**: Create a git commit or backup before cleanup

---

## Next Steps

1. Review the cleanup report
2. Validate safety: run validate-safety.sh on this report
3. Proceed with cleanup or use --report-only mode

EOF_RISK

# Replace final placeholders
replace_in_file "$REPORT_PATH" "TIMESTAMP_HERE" "$TIMESTAMP"
replace_in_file "$REPORT_PATH" "REPORT_PATH_HERE" "$REPORT_PATH"
replace_in_file "$REPORT_PATH" "FINDINGS_DIR_HERE" "$FINDINGS_DIR"

echo ""
echo -e "${GREEN}✓ Report generated successfully${NC}"
echo ""
echo "Report location: $REPORT_PATH"
echo ""
echo "Summary:"
echo "  - Total files identified: $total_files"
echo "  - Categories analyzed: ${#findings_exist[@]}"

exit 0
