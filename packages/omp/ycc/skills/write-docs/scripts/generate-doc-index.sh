#!/usr/bin/env bash
# generate-doc-index.sh - Generate documentation index and navigation tree
# Part of the write-docs plugin

set -euo pipefail

DOCS_DIR="${1:-docs}"

# Check if docs directory exists
if [[ ! -d "$DOCS_DIR" ]]; then
    echo "Error: Documentation directory '$DOCS_DIR' does not exist" >&2
    exit 1
fi

# Get project name from directory or package.json
if [[ -f "package.json" ]]; then
    PROJECT_NAME=$(grep -o '"name": *"[^"]*"' package.json | head -1 | cut -d'"' -f4)
elif [[ -f "go.mod" ]]; then
    PROJECT_NAME=$(head -1 go.mod | awk '{print $2}' | xargs basename)
else
    PROJECT_NAME=$(basename "$(pwd)")
fi

# Extract title from markdown file
extract_title() {
    local file="$1"
    # Try to get H1 heading
    local title
    title=$(grep -m1 "^# " "$file" 2>/dev/null | sed 's/^# //')
    if [[ -z "$title" ]]; then
        # Fall back to filename
        title=$(basename "$file" .md)
    fi
    echo "$title"
}

# Generate navigation tree
generate_tree() {
    local dir="$1"
    local prefix="$2"
    local indent="$3"

    # Get directories first, then files (null-delimited to handle spaces)
    while IFS= read -r -d '' item; do
        local name
        name=$(basename "$item")

        # Skip hidden files and node_modules
        [[ "$name" == .* ]] && continue
        [[ "$name" == "node_modules" ]] && continue

        if [[ -d "$item" ]]; then
            echo "${indent}- **${name}/**"
            generate_tree "$item" "$prefix" "  $indent"
        elif [[ "$name" == *.md ]]; then
            local title
            title=$(extract_title "$item")
            local rel_path="${item#$DOCS_DIR/}"
            echo "${indent}- [${title}](${rel_path})"
        fi
    done < <(find "$dir" -maxdepth 1 -mindepth 1 \( -type d -o -name "*.md" \) -print0 | sort -z)
}

# Get recently updated files (portable across GNU/BSD)
get_recent_files() {
    # Find all markdown files and get their timestamps using portable stat.
    # Sort into a variable and trim with head on a here-string, not
    # `sort | head`: under pipefail an early-exiting head SIGPIPEs the writer
    # (YAN-1587).
    local stamped sorted
    stamped="$(find "$DOCS_DIR" -type f -name "*.md" 2>/dev/null | while IFS= read -r file; do
        # Try GNU stat first, fallback to BSD stat
        if timestamp=$(stat -c '%Y' "$file" 2>/dev/null); then
            # GNU stat
            echo "$timestamp $file"
        elif timestamp=$(stat -f '%m' "$file" 2>/dev/null); then
            # BSD stat
            echo "$timestamp $file"
        fi
    done)"
    [[ -n "$stamped" ]] || return 0
    sorted="$(sort -rn <<<"$stamped")"
    head -n 10 <<<"$sorted" | while read -r timestamp file; do
        # Format date (both GNU and BSD date support -r)
        local date
        date=$(date -d "@$timestamp" '+%Y-%m-%d' 2>/dev/null || date -r "$timestamp" '+%Y-%m-%d' 2>/dev/null)
        local title
        title=$(extract_title "$file")
        local rel_path="${file#$DOCS_DIR/}"
        echo "- [${title}](${rel_path}) - *${date}*"
    done
}

# Output the index
cat << EOF
# ${PROJECT_NAME} Documentation

Welcome to the ${PROJECT_NAME} documentation.

## Quick Links

EOF

# Add quick links if standard directories exist
[[ -d "$DOCS_DIR/architecture" ]] && echo "- [Architecture Overview](architecture/overview.md)"
[[ -d "$DOCS_DIR/api" ]] && echo "- [API Reference](api/README.md)"
[[ -d "$DOCS_DIR/features" ]] && echo "- [Feature Guides](features/README.md)"
[[ -d "$DOCS_DIR/development" ]] && echo "- [Developer Guide](development/README.md)"
[[ -f "$DOCS_DIR/../CONTRIBUTING.md" ]] && echo "- [Contributing](../CONTRIBUTING.md)"

cat << EOF

## Documentation Map

EOF

generate_tree "$DOCS_DIR" "$DOCS_DIR" ""

cat << EOF

## Recently Updated

EOF

get_recent_files

cat << EOF

---

*Last generated: $(date '+%Y-%m-%d %H:%M:%S')*
EOF
