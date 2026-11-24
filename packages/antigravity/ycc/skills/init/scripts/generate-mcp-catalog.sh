#!/usr/bin/env bash
# generate-mcp-catalog.sh
# Scans MCP sources and outputs a markdown catalog organized by category.
#
# Sources:
#   - Plugin marketplace directory (scans plugin.json files)
#   - MCP library doc (parses markdown list entries)
#
# Environment variable overrides (both have sensible defaults):
#   YCC_MCP_MARKETPLACE_DIR  — directory containing marketplace plugin subdirs
#                              Default: ${HOME}/.claude/plugins/marketplaces
#   YCC_MCP_LIBRARY_DOC      — path to an MCP library CLAUDE.md
#                              Default: ${HOME}/.claude/mcp-library/CLAUDE.md
#
# Graceful degradation:
#   - If neither source exists, a warning is emitted to stderr and an
#     empty-but-well-formed catalog is written to stdout. Exit code is 0.
#   - If only one source exists, a notice is emitted to stderr and the
#     script proceeds with whichever source is available.

set -euo pipefail

# ---------------------------------------------------------------------------
# Path resolution (overridable via env vars)
# ---------------------------------------------------------------------------
MARKETPLACE_DIR="${YCC_MCP_MARKETPLACE_DIR:-${HOME}/.claude/plugins/marketplaces}"
MCP_LIBRARY_DOC="${YCC_MCP_LIBRARY_DOC:-${HOME}/.claude/mcp-library/CLAUDE.md}"

# ---------------------------------------------------------------------------
# Source availability checks
# ---------------------------------------------------------------------------
marketplace_ok=false
library_ok=false

[[ -d "$MARKETPLACE_DIR" ]] && marketplace_ok=true
[[ -f "$MCP_LIBRARY_DOC" ]] && library_ok=true

if [[ "$marketplace_ok" == "false" && "$library_ok" == "false" ]]; then
    cat >&2 <<EOF
[generate-mcp-catalog] WARNING: neither MCP source is available on this machine.
  Marketplace dir : ${MARKETPLACE_DIR}
  MCP library doc : ${MCP_LIBRARY_DOC}
Set YCC_MCP_MARKETPLACE_DIR and/or YCC_MCP_LIBRARY_DOC to override the defaults.
Emitting empty catalog.
EOF
    # Emit empty-but-well-formed catalog and exit cleanly
    echo "# Available MCP Servers"
    echo ""
    echo "The following MCP servers are available for configuration."
    echo ""
    echo "---"
    echo "**Total MCPs available**: 0"
    exit 0
fi

if [[ "$marketplace_ok" == "false" ]]; then
    echo "[generate-mcp-catalog] NOTICE: marketplace dir not found (${MARKETPLACE_DIR}); skipping. Set YCC_MCP_MARKETPLACE_DIR to override." >&2
fi

if [[ "$library_ok" == "false" ]]; then
    echo "[generate-mcp-catalog] NOTICE: MCP library doc not found (${MCP_LIBRARY_DOC}); skipping. Set YCC_MCP_LIBRARY_DOC to override." >&2
fi

# Category mappings for better organization
declare -A CATEGORIES=(
    # Version Control
    ["github"]="Version Control"
    ["gitlab"]="Version Control"

    # Project Management
    ["linear"]="Project Management"
    ["asana"]="Project Management"

    # Code Quality & Analysis
    ["serena"]="Code Quality"
    ["greptile"]="Code Quality"
    ["playwright"]="Testing"
    ["static-analysis"]="Code Quality"

    # Documentation
    ["context7"]="Documentation"

    # Backend Services
    ["firebase"]="Backend Services"
    ["supabase"]="Backend Services"
    ["sql"]="Backend Services"
    ["convex"]="Backend Services"

    # Communication
    ["slack"]="Communication"

    # Payments
    ["stripe"]="Payments"

    # Framework-Specific
    ["laravel-boost"]="Framework-Specific"

    # Media & Content
    ["images"]="Media & Content"
    ["videos"]="Media & Content"
    ["speech"]="Media & Content"

    # Search & Research
    ["search"]="Search & Research"
    ["google-mcp"]="Search & Research"
    ["mcp-reddit"]="Search & Research"

    # AI & Collaboration
    ["zen"]="AI Collaboration"

    # Templates
    ["boilerplate"]="Templates"
)

# Arrays to hold discovered MCPs
declare -A MCPS_BY_CATEGORY

# Function to add MCP to category
add_mcp() {
    local name="$1"
    local description="$2"
    local category="${CATEGORIES[$name]:-Other}"

    if [[ -z "${MCPS_BY_CATEGORY[$category]+x}" ]]; then
        MCPS_BY_CATEGORY[$category]=""
    fi
    MCPS_BY_CATEGORY[$category]+="- **${name}**: ${description}"$'\n'
}

# Scan plugin marketplace
if [[ "$marketplace_ok" == "true" ]]; then
    for dir in "$MARKETPLACE_DIR"/*/; do
        [[ -d "$dir" ]] || continue
        plugin_json="$dir/.claude-plugin/plugin.json"

        if [[ -f "$plugin_json" ]]; then
            name=$(jq -r '.name // empty' "$plugin_json" 2>/dev/null)
            desc=$(jq -r '.description // "No description"' "$plugin_json" 2>/dev/null)

            if [[ -n "$name" ]]; then
                add_mcp "$name" "$desc"
            fi
        else
            # Fallback: use directory name
            name=$(basename "$dir")
            add_mcp "$name" "MCP plugin (no description available)"
        fi
    done
fi

# Parse MCP library CLAUDE.md for additional MCPs
if [[ "$library_ok" == "true" ]]; then
    while IFS= read -r line; do
        if [[ "$line" =~ ^-\ \`([^\`]+)\`\ -\ (.+)$ ]]; then
            name="${BASH_REMATCH[1]}"
            desc="${BASH_REMATCH[2]}"

            # Only add if not already discovered
            found=false
            for cat in "${!MCPS_BY_CATEGORY[@]}"; do
                if [[ "${MCPS_BY_CATEGORY[$cat]}" == *"**${name}**"* ]]; then
                    found=true
                    break
                fi
            done

            if [[ "$found" == "false" ]]; then
                add_mcp "$name" "$desc"
            fi
        fi
    done < "$MCP_LIBRARY_DOC"
fi

# Output the catalog
echo "# Available MCP Servers"
echo ""
echo "The following MCP servers are available for configuration."
echo ""

# Sort categories for consistent output
sorted_categories=(
    "Version Control"
    "Project Management"
    "Code Quality"
    "Testing"
    "Documentation"
    "Backend Services"
    "Communication"
    "Payments"
    "Framework-Specific"
    "Media & Content"
    "Search & Research"
    "AI Collaboration"
    "Templates"
    "Other"
)

for category in "${sorted_categories[@]}"; do
    if [[ -n "${MCPS_BY_CATEGORY[$category]+x}" && -n "${MCPS_BY_CATEGORY[$category]}" ]]; then
        echo "## ${category}"
        echo ""
        echo "${MCPS_BY_CATEGORY[$category]}"
    fi
done

# Summary
total=0
for cat in "${!MCPS_BY_CATEGORY[@]}"; do
    count=$(echo "${MCPS_BY_CATEGORY[$cat]}" | grep -c "^-" || true)
    total=$((total + count))
done

echo "---"
echo "**Total MCPs available**: ${total}"
