#!/usr/bin/env bash
# Validates research artifact files for shared-context
# Usage: validate-research-artifacts.sh <feature-dir> [--optimized]
#
# Modes:
#   default      Standard 4-file research set (research-architecture/patterns/integration/docs.md)
#   --optimized  plan-workflow --optimized: 5-file unified-analyst set
#                (analysis-architecture/patterns/integration/docs/tasks.md).
#                In optimized mode the workflow does not produce research-*.md;
#                this validator delegates to the same 5-file set as
#                validate-analysis-artifacts.sh --optimized so Phase 2 has a
#                meaningful check to run.
#
# Checks that all required outputs exist, are non-empty, meet minimum size,
# and contain expected headings. Exits non-zero if any file is missing or invalid.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RESOLVER="${SCRIPT_DIR}/../../../ycc-shared/scripts/resolve-artifact-store.sh"

# Source resolver to get PLANS_ROOT/ARTIFACT_ROOT for path resolution and the
# artifact_body helper for frontmatter-skipping heading checks.
if [[ -f "$RESOLVER" ]]; then
    # shellcheck source=../../../ycc-shared/scripts/resolve-artifact-store.sh
    source "$RESOLVER"
    # shellcheck source=../../../ycc-shared/scripts/artifact-body.sh
    source "${SCRIPT_DIR}/../../../ycc-shared/scripts/artifact-body.sh"
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

require_any_heading() {
    local file="$1"
    local label="$2"
    shift 2

    local found=false
    local heading
    for heading in "$@"; do
        # Match against the body only: identity frontmatter is not content
        # (see _shared/references/artifact-store.md, Frontmatter).
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

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <feature-dir> [--optimized] [--store=linear|local]"
    exit 1
fi

feature_dir=""
optimized="false"
store_flag=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --optimized)
            optimized="true"
            shift
            ;;
        --store=*)
            store_flag="$1"
            shift
            ;;
        *)
            if [[ -z "$feature_dir" ]]; then
                feature_dir="$1"
            else
                echo -e "${RED}ERROR:${NC} unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -n "$store_flag" ]]; then
    # shellcheck disable=SC2086
    resolve_artifact_store "$PWD" "$store_flag" || {
        echo -e "${RED}ERROR:${NC} invalid ${store_flag#--}" >&2
        exit 1
    }
fi

if [[ -z "$feature_dir" ]]; then
    echo -e "${RED}ERROR:${NC} feature-dir required" >&2
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

declare -a files
if [[ "$optimized" == "true" ]]; then
    # Optimized mode: validate the 5 unified analyst outputs instead.
    files=(
        "analysis-architecture.md"
        "analysis-patterns.md"
        "analysis-integration.md"
        "analysis-docs.md"
        "analysis-tasks.md"
    )
else
    files=(
        "research-architecture.md"
        "research-patterns.md"
        "research-integration.md"
        "research-docs.md"
    )
fi

mode_label="standard"
if [[ "$optimized" == "true" ]]; then
    mode_label="optimized"
fi

echo "Validating research artifacts (${mode_label}) in: $feature_dir"
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

    # Check for title heading in the body (frontmatter skipped)
    if grep -q "^# " < <(artifact_body "$path"); then
        log_success "${file}: has title heading"
    else
        log_warning "${file}: missing title heading"
    fi

    # File-specific heading checks
    case "$file" in
        research-architecture.md)
            require_any_heading "$path" "system/components section" \
                "## System Overview" "## Relevant Components" "## Architecture Overview"
            require_any_heading "$path" "integration section" \
                "## Integration Points" "## Data Flow" "## Key Dependencies"
            ;;
        research-patterns.md)
            require_any_heading "$path" "patterns section" \
                "## Architectural Patterns" "## Patterns to Follow" "## Code Conventions"
            ;;
        research-integration.md)
            require_any_heading "$path" "API/database section" \
                "## API Endpoints" "## Database" "## External Services"
            ;;
        research-docs.md)
            require_any_heading "$path" "documentation section" \
                "## Must-Read Documents" "## Architecture Docs" "## Documentation Gaps"
            ;;
        analysis-architecture.md)
            require_any_heading "$path" "summary section" \
                "## Executive Summary" "## Summary" "## Overview"
            require_any_heading "$path" "architecture section" \
                "## Architecture Context" "## Architecture" "## System Overview" "## Critical Files Reference"
            ;;
        analysis-patterns.md)
            require_any_heading "$path" "summary section" \
                "## Executive Summary" "## Summary" "## Overview"
            require_any_heading "$path" "patterns section" \
                "## Implementation Patterns" "## Architectural Patterns" "## Existing Code Structure" "## Code Conventions"
            ;;
        analysis-integration.md)
            require_any_heading "$path" "summary section" \
                "## Executive Summary" "## Summary" "## Overview"
            require_any_heading "$path" "API/database section" \
                "## API Endpoints" "## Database" "## External Services" "## Integration Points"
            ;;
        analysis-docs.md)
            require_any_heading "$path" "summary section" \
                "## Executive Summary" "## Summary" "## Overview"
            require_any_heading "$path" "documentation section" \
                "## Must-Read Documents" "## Architecture Docs" "## Documentation Gaps" "## Reading List"
            ;;
        analysis-tasks.md)
            require_any_heading "$path" "summary section" \
                "## Executive Summary" "## Summary" "## Overview"
            require_any_heading "$path" "phase/task section" \
                "## Recommended Phase Structure" "## Task Granularity" "## Dependency Analysis"
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
