#!/usr/bin/env bash
# generate-agent-catalog.sh
# Scans ~/.cursor/agents/ (Cursor config; synced by install.sh from packages/cursor/ycc/agents) and outputs a markdown catalog organized by category
# Reads YAML frontmatter from each agent file for metadata

set -euo pipefail

# Define paths (override for tests: AGENTS_DIR=/path/to/agents ./generate-agent-catalog.sh)
AGENTS_DIR="${AGENTS_DIR:-${HOME}/.cursor/agents}"

# Category mappings based on agent names/purposes
declare -A CATEGORIES=(
    # Code Discovery & Research
    ["code-finder"]="Code Discovery"
    ["code-researcher"]="Code Discovery"
    ["codebase-research-analyst"]="Code Discovery"
    ["feature-researcher"]="Code Discovery"

    # Backend Development
    ["go-api-architect"]="Backend Development"
    ["go-expert-architect"]="Backend Development"
    ["nodejs-backend-architect"]="Backend Development"

    # Database
    ["db-modifier"]="Database"
    ["turso-database-architect"]="Database"

    # Frontend Development
    ["frontend-ui-developer"]="Frontend Development"
    ["nextjs-ux-ui-expert"]="Frontend Development"

    # Infrastructure & DevOps
    ["terraform-architect"]="Infrastructure"
    ["ansible-automation-expert"]="Infrastructure"
    ["cloudflare-architect"]="Infrastructure"
    ["reverse-proxy-architect"]="Infrastructure"
    ["systems-engineering-expert"]="Infrastructure"

    # Documentation
    ["documentation-writer"]="Documentation"
    ["api-docs-expert"]="Documentation"
    ["library-docs-writer"]="Documentation"
    ["docs-git-committer"]="Documentation"

    # Testing & Quality
    ["test-strategy-planner"]="Testing & Quality"
    ["root-cause-analyzer"]="Testing & Quality"

    # Implementation & Maintenance
    ["implementor"]="Implementation"
    ["project-file-cleaner"]="Maintenance"

    # Research
    ["research-specialist"]="Research"
)

# Arrays to hold discovered agents
declare -A AGENTS_BY_CATEGORY

# Function to extract simple YAML field value
extract_yaml_field() {
    local file="$1"
    local field="$2"

    local result
    result=$(sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null | \
        grep -E "^${field}:" | \
        sed "s/^${field}:[[:space:]]*//" | \
        sed 's/^["'"'"']//' | \
        sed 's/["'"'"']$//' | \
        head -1 || true)
    echo "$result"
}

# Function to extract and clean description (first sentence only)
extract_description() {
    local file="$1"

    local raw
    raw=$(sed -n '/^---$/,/^---$/p' "$file" 2>/dev/null | \
        grep -E "^description:" | \
        sed 's/^description:[[:space:]]*//' | \
        sed 's/^["'"'"']//' | \
        sed 's/["'"'"']$//' | \
        head -1 || true)

    if [[ -z "$raw" ]]; then
        echo "No description available"
        return 0
    fi

    local first_sentence
    first_sentence=$(echo "$raw" | sed 's/\. .*/./; s/\.$//' || true)

    first_sentence=$(echo "$first_sentence" | \
        sed 's/\\n/ /g' | \
        sed 's/\\t/ /g' | \
        sed "s/\\\\''/'/g" | \
        sed 's/[[:space:]]\+/ /g' | \
        sed 's/^ //; s/ $//' || true)

    if [[ ${#first_sentence} -gt 120 ]]; then
        first_sentence="${first_sentence:0:117}..."
    fi

    echo "$first_sentence"
}

# Function to add agent to category
add_agent() {
    local name="$1"
    local title="$2"
    local description="$3"
    local tools="$4"
    local model="$5"
    local category="${CATEGORIES[$name]:-Other}"

    if [[ -z "${AGENTS_BY_CATEGORY[$category]+x}" ]]; then
        AGENTS_BY_CATEGORY[$category]=""
    fi

    local entry="- **${name}**"
    if [[ -n "$title" && "$title" != "$name" ]]; then
        entry+=" (${title})"
    fi
    entry+=": ${description:-No description available}"

    if [[ -n "$model" ]]; then
        entry+=" [${model}]"
    fi

    AGENTS_BY_CATEGORY[$category]+="${entry}"$'\n'
}

# Check if agents directory exists
if [[ ! -d "$AGENTS_DIR" ]]; then
    echo "# Available Agents"
    echo ""
    echo "No agents directory found at ${AGENTS_DIR}"
    exit 0
fi

# Scan agents directory
for file in "$AGENTS_DIR"/*.md; do
    [[ -f "$file" ]] || continue

    name=$(basename "$file" .md)
    title=$(extract_yaml_field "$file" "title")
    description=$(extract_description "$file")
    tools=$(extract_yaml_field "$file" "tools")
    model=$(extract_yaml_field "$file" "model")

    add_agent "$name" "$title" "$description" "$tools" "$model"
done

# Output the catalog
echo "# Available Agents"
echo ""
echo "The following specialized agents are available for project configuration."
echo ""

# Sort categories for consistent output
sorted_categories=(
    "Code Discovery"
    "Backend Development"
    "Database"
    "Frontend Development"
    "Infrastructure"
    "Documentation"
    "Testing & Quality"
    "Implementation"
    "Maintenance"
    "Research"
    "Other"
)

for category in "${sorted_categories[@]}"; do
    if [[ -n "${AGENTS_BY_CATEGORY[$category]+x}" && -n "${AGENTS_BY_CATEGORY[$category]}" ]]; then
        echo "## ${category}"
        echo ""
        echo "${AGENTS_BY_CATEGORY[$category]}"
    fi
done

# Summary
total=0
for cat in "${!AGENTS_BY_CATEGORY[@]}"; do
    count=$(echo "${AGENTS_BY_CATEGORY[$cat]}" | grep -c "^-" || true)
    total=$((total + count))
done

echo "---"
echo "**Total agents available**: ${total}"
