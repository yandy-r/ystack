#!/usr/bin/env bash
# verify-links.sh - Verify internal markdown links
# Part of the write-docs plugin

set -euo pipefail

DOCS_DIR="${1:-docs}"
ERRORS=0

echo "# Link Verification Report"
echo ""
echo "Checking internal links in: $DOCS_DIR"
echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# Find all markdown files
md_files=$(find "$DOCS_DIR" -type f -name "*.md" 2>/dev/null)

if [[ -z "$md_files" ]]; then
    echo "No markdown files found in $DOCS_DIR"
    exit 0
fi

echo "## Results"
echo ""

# Check each file (using process substitution to avoid subshell)
while IFS= read -r file; do
    file_dir=$(dirname "$file")

    # Extract markdown links [text](path)
    links=$(grep -oE '\[([^\]]+)\]\(([^)]+)\)' "$file" 2>/dev/null | grep -oE '\]\([^)]+\)' | sed 's/\](//' | sed 's/)$//' || true)

    for link in $links; do
        # Skip external links, anchors, and special protocols
        [[ "$link" == http* ]] && continue
        [[ "$link" == mailto:* ]] && continue
        [[ "$link" == "#"* ]] && continue
        [[ "$link" == "" ]] && continue

        # Remove anchor from link
        link_path="${link%%#*}"
        [[ -z "$link_path" ]] && continue

        # Resolve relative path
        if [[ "$link_path" == /* ]]; then
            # Absolute path from repo root
            full_path=".${link_path}"
        else
            # Relative path from file location
            full_path="${file_dir}/${link_path}"
        fi

        # Normalize path
        full_path=$(realpath -m "$full_path" 2>/dev/null || echo "$full_path")

        # Check if target exists
        if [[ ! -e "$full_path" ]]; then
            echo "❌ **Broken link** in \`$file\`"
            echo "   Link: \`$link\`"
            echo "   Expected: \`$full_path\`"
            echo ""
            ERRORS=$((ERRORS + 1))
        fi
    done
done < <(echo "$md_files")

# Summary
echo "## Summary"
echo ""
total_files=$(echo "$md_files" | wc -l | tr -d ' ')
echo "- Files checked: $total_files"
echo "- Broken links found: $ERRORS"
echo ""

if [[ $ERRORS -eq 0 ]]; then
    echo "✅ All internal links are valid!"
else
    echo "⚠️ Please fix the broken links listed above."
    exit 1
fi
