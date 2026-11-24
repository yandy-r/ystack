#!/usr/bin/env bash
# Pre-generation gate: blocks plan generation if analysis files are missing.
# Usage: persist-or-fail.sh <feature-dir> [--optimized]
#
# Modes:
#   default      Standard plan-workflow / parallel-plan: requires
#                analysis-context.md, analysis-code.md, analysis-tasks.md.
#   --optimized  plan-workflow --optimized: requires the 5 unified analyst
#                outputs — analysis-architecture.md, analysis-patterns.md,
#                analysis-integration.md, analysis-docs.md, analysis-tasks.md.
#
# Exit 0 = all required analysis files present and non-empty, safe to generate plan
# Exit 1 = prints MISSING_FILES list and ACTION_REQUIRED message
#
# This is the critical chokepoint that runs immediately before plan generation.
# Unlike validate-analysis-artifacts.sh (which checks quality), this script
# is a binary pass/fail gate: files exist and are non-empty, or plan generation
# is blocked.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RESOLVER="${SCRIPT_DIR}/../../../ycc-shared/scripts/resolve-artifact-store.sh"

# Source resolver to get PLANS_ROOT/ARTIFACT_ROOT for path resolution
if [[ -f "$RESOLVER" ]]; then
    # shellcheck source=../../../ycc-shared/scripts/resolve-artifact-store.sh
    source "$RESOLVER"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <feature-dir> [--optimized] [--store=linear|local]"
    echo ""
    echo "Pre-generation gate: ensures all analysis files exist before plan generation."
    echo "  default      Standard 3-file set (analysis-context/code/tasks)"
    echo "  --optimized  5-file unified-analyst set (architecture/patterns/integration/docs/tasks)"
    echo "Exit 0 = proceed to plan generation"
    echo "Exit 1 = analysis files missing, plan generation blocked"
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
                echo -e "${RED}ERROR${NC}: unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$feature_dir" ]]; then
    echo -e "${RED}ERROR${NC}: feature-dir required" >&2
    exit 1
fi

if [[ -n "$store_flag" ]]; then
    # shellcheck disable=SC2086
    resolve_artifact_store "$PWD" "$store_flag" || {
        echo -e "${RED}ERROR${NC}: invalid ${store_flag#--}" >&2
        exit 1
    }
fi

# Resolve relative paths against the active artifact root: PLANS_ROOT in local
# mode, ARTIFACT_ROOT in linear mode.
if [[ "$feature_dir" != /* && -n "${ARTIFACT_ROOT:-${PLANS_ROOT:-}}" ]]; then
    feature_dir="${ARTIFACT_ROOT:-$PLANS_ROOT}/${feature_dir}"
fi

if [[ ! -d "$feature_dir" ]]; then
    echo -e "${RED}GATE FAILED${NC}: Feature directory not found: $feature_dir"
    exit 1
fi

declare -a required_files
if [[ "$optimized" == "true" ]]; then
    required_files=(
        "analysis-architecture.md"
        "analysis-patterns.md"
        "analysis-integration.md"
        "analysis-docs.md"
        "analysis-tasks.md"
    )
else
    required_files=(
        "analysis-context.md"
        "analysis-code.md"
        "analysis-tasks.md"
    )
fi

declare -a missing_files=()

for file in "${required_files[@]}"; do
    path="${feature_dir}/${file}"
    if [[ ! -f "$path" ]]; then
        missing_files+=("$file")
    elif [[ ! -s "$path" ]]; then
        missing_files+=("$file (empty)")
    fi
done

mode_label="standard"
if [[ "$optimized" == "true" ]]; then
    mode_label="optimized"
fi

if [[ ${#missing_files[@]} -eq 0 ]]; then
    echo -e "${GREEN}GATE PASSED${NC} (${mode_label}): All analysis files present in ${feature_dir}"
    for file in "${required_files[@]}"; do
        size=$(wc -c < "${feature_dir}/${file}" | tr -d ' ')
        echo -e "  ${GREEN}OK${NC}: ${file} (${size} bytes)"
    done
    exit 0
else
    echo -e "${RED}GATE FAILED${NC} (${mode_label}): Analysis files missing — plan generation BLOCKED"
    echo ""
    echo "MISSING_FILES:"
    for file in "${missing_files[@]}"; do
        echo -e "  ${RED}-${NC} ${file}"
    done
    echo ""
    echo -e "${YELLOW}ACTION_REQUIRED${NC}: Re-dispatch the failing agent(s) to write the missing files to ${feature_dir}/."
    echo "Do NOT have the orchestrator write these files itself from captured agent summaries — that bypasses the contract."
    echo "Do NOT proceed to plan generation until this gate passes (exit 0)."
    exit 1
fi
