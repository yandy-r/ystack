#!/usr/bin/env bash
# Validates research artifact structure for feature-research
# Usage: validate-research.sh <feature-dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RESOLVER="${SCRIPT_DIR}/../../_shared/scripts/resolve-artifact-store.sh"

# Source resolver to get PLANS_ROOT/ARTIFACT_ROOT for path resolution and the
# artifact_body helper for frontmatter-skipping heading checks.
if [[ -f "$RESOLVER" ]]; then
    # shellcheck source=../../_shared/scripts/resolve-artifact-store.sh
    source "$RESOLVER"
    # shellcheck source=../../_shared/scripts/artifact-body.sh
    source "${SCRIPT_DIR}/../../_shared/scripts/artifact-body.sh"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

require_heading() {
    local file="$1"
    local heading="$2"
    # Match against the body only: identity frontmatter is not content
    # (see _shared/references/artifact-store.md, Frontmatter).
    if grep -q "^${heading}" < <(artifact_body "$file"); then
        log_success "$(basename "$file"): found ${heading}"
    else
        log_error "$(basename "$file"): missing required heading ${heading}"
    fi
}

require_any_heading() {
    local file="$1"
    local label="$2"
    shift 2

    local found=false
    local heading
    for heading in "$@"; do
        # Body-only match: identity frontmatter is not content.
        if grep -q "^${heading}" < <(artifact_body "$file"); then
            found=true
            break
        fi
    done

    if [[ "$found" == true ]]; then
        log_success "$(basename "$file"): found ${label}"
    else
        log_error "$(basename "$file"): missing ${label} (expected one of: $*)"
    fi
}

feature_dir=""
store_flag=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --store=*)
            store_flag="$1"
            ;;
        *)
            if [[ -z "$feature_dir" ]]; then
                feature_dir="$1"
            else
                echo "Usage: $0 <feature-dir> [--store=linear|local]" >&2
                exit 1
            fi
            ;;
    esac
    shift
done

if [[ -n "$store_flag" ]]; then
    # shellcheck disable=SC2086
    resolve_artifact_store "$PWD" "$store_flag" || {
        echo -e "${RED}ERROR:${NC} invalid ${store_flag#--}" >&2
        exit 1
    }
fi

if [[ -z "$feature_dir" ]]; then
    echo "Usage: $0 <feature-dir> [--store=linear|local]"
    exit 1
fi

# Resolve relative paths against the active artifact root: PLANS_ROOT in local
# mode, ARTIFACT_ROOT in linear mode.
if [[ "$feature_dir" != /* && -n "${ARTIFACT_ROOT:-${PLANS_ROOT:-}}" ]]; then
    feature_dir="${ARTIFACT_ROOT:-$PLANS_ROOT}/${feature_dir}"
fi

if [[ ! -d "$feature_dir" ]]; then
    log_error "Feature directory not found: $feature_dir"
    exit 1
fi

declare -a files=(
    "research-external.md"
    "research-business.md"
    "research-technical.md"
    "research-ux.md"
    "research-security.md"
    "research-practices.md"
    "research-recommendations.md"
)

echo "Validating research artifacts in: $feature_dir"
echo "=========================================="

for file in "${files[@]}"; do
    path="${feature_dir}/${file}"

    # Research files live directly in the feature dir (local layout) or in its
    # research/ subdir (linear layout). An existing research/ directory wins.
    if [[ "$file" == research-* && -d "${feature_dir}/research" ]]; then
        path="${feature_dir}/research/${file}"
    fi

    if [[ ! -f "$path" ]]; then
        log_error "${file}: file not found"
        continue
    fi

    if [[ ! -s "$path" ]]; then
        log_error "${file}: file is empty"
        continue
    fi

    size_bytes="$(wc -c < "$path" | tr -d ' ')"
    if [[ "$size_bytes" -lt 400 ]]; then
        log_warning "${file}: content is short (${size_bytes} bytes)"
    fi

    require_heading "$path" "## Executive Summary"

    case "$file" in
        research-external.md)
            require_any_heading "$path" "API section" "### Candidate APIs and Services" "## Primary APIs"
            require_any_heading "$path" "integration section" "### Integration Patterns" "## Integration Patterns"
            ;;
        research-business.md)
            require_any_heading "$path" "user stories section" "### User Stories" "## User Stories"
            require_any_heading "$path" "business rules section" "### Business Rules" "## Business Rules"
            ;;
        research-technical.md)
            require_any_heading "$path" "architecture section" "### Architecture Approach" "## Architecture Design" "## Architecture Approach"
            require_any_heading "$path" "data model section" "### Data Model Implications" "## Data Models"
            ;;
        research-ux.md)
            require_any_heading "$path" "workflow section" "### Core User Workflows" "## User Workflows"
            require_any_heading "$path" "state/feedback section" "### Feedback and State Design" "## Performance UX"
            ;;
        research-security.md)
            require_any_heading "$path" "severity findings section" "## Findings by Severity" "### CRITICAL"
            require_any_heading "$path" "dependency section" "## Dependency Security" "### Dependency Security"
            ;;
        research-practices.md)
            require_any_heading "$path" "reusable code section" "## Existing Reusable Code"
            require_any_heading "$path" "modularity section" "## Modularity Design" "## Modularity"
            ;;
        research-recommendations.md)
            require_any_heading "$path" "recommendation strategy section" "### Recommended Implementation Strategy" "## Implementation Recommendations" "### Recommended Approach"
            require_any_heading "$path" "risk section" "### Risk Mitigations" "## Risk Assessment"
            ;;
    esac
done

echo "=========================================="
echo "Errors: $errors"
echo "Warnings: $warnings"

if [[ $errors -gt 0 ]]; then
    exit 1
fi

exit 0
