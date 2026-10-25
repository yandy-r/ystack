#!/usr/bin/env bash
# audit-documentation.sh - Scan existing documentation and identify gaps
# Part of the write-docs plugin

set -euo pipefail

# Output header
echo "# Documentation Audit Report"
echo ""
echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Directory: $(pwd)"
echo ""

# Section: docs/ directory
echo "## Documentation Directory Structure"
echo ""
if [[ -d "docs" ]]; then
    echo "✅ \`docs/\` directory exists"
    echo ""
    echo "\`\`\`"
    if command -v tree &> /dev/null; then
        tree -L 3 docs 2>/dev/null || find docs -type f -name "*.md" | head -50
    else
        find docs -type f -name "*.md" 2>/dev/null | head -50
    fi
    echo "\`\`\`"
    echo ""

    # Count files
    doc_count=$(find docs -type f -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    echo "📊 **Total markdown files in docs/**: ${doc_count}"
else
    echo "❌ \`docs/\` directory does not exist"
fi
echo ""

# Section: README files
echo "## README Files"
echo ""
readme_files=$(find . -name "README.md" -not -path "./node_modules/*" -not -path "./.git/*" 2>/dev/null)
# grep -c prints the count itself; exit 1 only means zero matches. Any other
# non-zero status is a real failure.
readme_count_status=0
readme_count=$(grep -c "README.md" <<<"$readme_files") || readme_count_status=$?
if [ "$readme_count_status" -gt 1 ]; then
    echo "Error: Failed to count README.md files" >&2
    exit "$readme_count_status"
fi
echo "📊 **Total README.md files**: ${readme_count}"
echo ""
if [[ -n "$readme_files" ]]; then
    echo "| File | Size | Last Modified |"
    echo "|------|------|---------------|"
    echo "$readme_files" | while read -r file; do
        if [[ -f "$file" ]]; then
            size=$(wc -c < "$file" | tr -d ' ')
            modified=$(stat -c '%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null)
            modified_date=$(date -d "@$modified" '+%Y-%m-%d' 2>/dev/null || date -r "$modified" '+%Y-%m-%d' 2>/dev/null)
            echo "| \`$file\` | ${size} bytes | ${modified_date} |"
        fi
    done
fi
echo ""

# Section: AGENTS.md files
echo "## AGENTS.md Files"
echo ""
claude_files=$(find . -name "AGENTS.md" -not -path "./node_modules/*" -not -path "./.git/*" 2>/dev/null)
# grep -c prints the count itself; exit 1 only means zero matches. Any other
# non-zero status is a real failure.
claude_count_status=0
claude_count=$(grep -c "AGENTS.md" <<<"$claude_files") || claude_count_status=$?
if [ "$claude_count_status" -gt 1 ]; then
    echo "Error: Failed to count AGENTS.md files" >&2
    exit "$claude_count_status"
fi
echo "📊 **Total AGENTS.md files**: ${claude_count}"
echo ""
if [[ -n "$claude_files" && "$claude_count" -gt 0 ]]; then
    echo "| File | Size |"
    echo "|------|------|"
    echo "$claude_files" | while read -r file; do
        if [[ -f "$file" ]]; then
            size=$(wc -c < "$file" | tr -d ' ')
            echo "| \`$file\` | ${size} bytes |"
        fi
    done
fi
echo ""

# Section: API Specifications
echo "## API Specifications"
echo ""
openapi_files=$(find . -name "openapi*.yaml" -o -name "openapi*.yml" -o -name "openapi*.json" -o -name "swagger*.yaml" -o -name "swagger*.yml" -o -name "swagger*.json" 2>/dev/null | grep -v node_modules || true)
graphql_files=$(find . -name "*.graphql" -o -name "schema.gql" 2>/dev/null | grep -v node_modules || true)

if [[ -n "$openapi_files" ]]; then
    echo "### OpenAPI/Swagger"
    echo "$openapi_files" | while read -r file; do
        [[ -f "$file" ]] && echo "- \`$file\`"
    done
    echo ""
else
    echo "❌ No OpenAPI/Swagger specifications found"
    echo ""
fi

if [[ -n "$graphql_files" ]]; then
    echo "### GraphQL Schemas"
    echo "$graphql_files" | while read -r file; do
        [[ -f "$file" ]] && echo "- \`$file\`"
    done
    echo ""
else
    echo "❌ No GraphQL schema files found"
    echo ""
fi

# Section: Inline Documentation Density
echo "## Inline Documentation Density"
echo ""

# Check for JSDoc comments in JS/TS files
js_ts_files=$(find . -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \) -not -path "./node_modules/*" -not -path "./.git/*" 2>/dev/null | head -100)
if [[ -n "$js_ts_files" ]]; then
    total_js_files=$(echo "$js_ts_files" | wc -l | tr -d ' ')
    jsdoc_count=$(echo "$js_ts_files" | xargs grep -l "@param\|@returns\|@description" 2>/dev/null | wc -l | tr -d ' ')
    echo "### JavaScript/TypeScript"
    echo "- Files scanned: ${total_js_files}"
    echo "- Files with JSDoc: ${jsdoc_count}"
    if [[ "$total_js_files" -gt 0 ]]; then
        percentage=$((jsdoc_count * 100 / total_js_files))
        echo "- Documentation coverage: ${percentage}%"
    fi
    echo ""
fi

# Check for docstrings in Python files
py_files=$(find . -type f -name "*.py" -not -path "./node_modules/*" -not -path "./.git/*" -not -path "./.venv/*" 2>/dev/null | head -100)
if [[ -n "$py_files" ]]; then
    total_py_files=$(echo "$py_files" | wc -l | tr -d ' ')
    docstring_count=$(echo "$py_files" | xargs grep -l '"""' 2>/dev/null | wc -l | tr -d ' ')
    echo "### Python"
    echo "- Files scanned: ${total_py_files}"
    echo "- Files with docstrings: ${docstring_count}"
    if [[ "$total_py_files" -gt 0 ]]; then
        percentage=$((docstring_count * 100 / total_py_files))
        echo "- Documentation coverage: ${percentage}%"
    fi
    echo ""
fi

# Check for Go doc comments
go_files=$(find . -type f -name "*.go" -not -path "./node_modules/*" -not -path "./.git/*" 2>/dev/null | head -100)
if [[ -n "$go_files" ]]; then
    total_go_files=$(echo "$go_files" | wc -l | tr -d ' ')
    godoc_count=$(echo "$go_files" | xargs grep -l "^// [A-Z]" 2>/dev/null | wc -l | tr -d ' ')
    echo "### Go"
    echo "- Files scanned: ${total_go_files}"
    echo "- Files with doc comments: ${godoc_count}"
    if [[ "$total_go_files" -gt 0 ]]; then
        percentage=$((godoc_count * 100 / total_go_files))
        echo "- Documentation coverage: ${percentage}%"
    fi
    echo ""
fi

# Section: Source Code Overview
echo "## Source Code Overview"
echo ""
echo "| Language | File Count |"
echo "|----------|------------|"

for ext in ts tsx js jsx go py rs java rb php; do
    count=$(find . -type f -name "*.$ext" -not -path "./node_modules/*" -not -path "./.git/*" -not -path "./.venv/*" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -gt 0 ]]; then
        echo "| .$ext | $count |"
    fi
done
echo ""

# Section: Recommendations
echo "## Recommendations"
echo ""
echo "Based on this audit, consider documenting:"
echo ""

# Check for undocumented areas
if [[ ! -d "docs/architecture" ]]; then
    echo "- [ ] **Architecture**: Create \`docs/architecture/\` with system overview and diagrams"
fi
if [[ ! -d "docs/api" ]]; then
    echo "- [ ] **API Reference**: Create \`docs/api/\` with endpoint documentation"
fi
if [[ ! -d "docs/features" ]]; then
    echo "- [ ] **Feature Guides**: Create \`docs/features/\` with user-facing documentation"
fi
if [[ ! -f "docs/development/setup.md" && ! -f "docs/CONTRIBUTING.md" ]]; then
    echo "- [ ] **Developer Guide**: Create setup and contribution documentation"
fi

echo ""
echo "---"
echo "*Audit complete*"
