#!/usr/bin/env bash
# Unified sync entrypoint — regenerate all derived artifacts from ycc source-of-truth.
#
# Usage:
#   ./scripts/sync.sh                            # all targets
#   ./scripts/sync.sh --only inventory           # single target
#   ./scripts/sync.sh --only cursor,codex        # comma-separated subset
#
# Targets: inventory, cursor, codex, opencode, omp, pi, antigravity, agents, claude
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VALID_TARGETS=(inventory cursor codex opencode omp pi antigravity agents claude)
TARGETS=("${VALID_TARGETS[@]}")

usage() {
    cat <<EOF
Usage: $(basename "$0") [--only <targets>]

Regenerate derived artifacts from the ycc source-of-truth directory.

Options:
  --only <targets>   Comma-separated subset (valid: ${VALID_TARGETS[*]})
  -h, --help         Show this help

Examples:
  $(basename "$0")
  $(basename "$0") --only inventory
  $(basename "$0") --only cursor,codex
  $(basename "$0") --only opencode
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)
            [[ $# -lt 2 ]] && { echo "sync.sh: --only requires an argument" >&2; exit 1; }
            IFS=',' read -r -a TARGETS <<<"$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "sync.sh: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

for target in "${TARGETS[@]}"; do
    valid=0
    for v in "${VALID_TARGETS[@]}"; do
        [[ "$target" == "$v" ]] && valid=1 && break
    done
    if [[ "$valid" -eq 0 ]]; then
        echo "sync.sh: unknown target '$target' (valid: ${VALID_TARGETS[*]})" >&2
        exit 1
    fi
done

run_ycc_target() {
    case "$1" in
        inventory)
            echo "== sync: inventory =="
            "${REPO_ROOT}/scripts/generate-inventory.sh"
            ;;
        cursor)
            echo "== sync: cursor native packages =="
            "${REPO_ROOT}/scripts/generate-cursor-packages.sh"
            ;;
        codex)
            echo "== sync: codex skills =="
            "${REPO_ROOT}/scripts/generate-codex-skills.sh"
            echo "== sync: codex agents =="
            "${REPO_ROOT}/scripts/generate-codex-agents.sh"
            echo "== sync: codex plugin =="
            "${REPO_ROOT}/scripts/generate-codex-plugin.sh"
            ;;
        opencode)
            echo "== sync: opencode skills =="
            "${REPO_ROOT}/scripts/generate-opencode-skills.sh"
            echo "== sync: opencode agents =="
            "${REPO_ROOT}/scripts/generate-opencode-agents.sh"
            echo "== sync: opencode commands =="
            "${REPO_ROOT}/scripts/generate-opencode-commands.sh"
            echo "== sync: opencode plugin =="
            "${REPO_ROOT}/scripts/generate-opencode-plugin.sh"
            echo "== sync: opencode npm package =="
            "${REPO_ROOT}/scripts/generate-opencode-package.sh"
            ;;
        omp)
            echo "== sync: omp skills =="
            "${REPO_ROOT}/scripts/generate-omp-skills.sh"
            echo "== sync: omp agents =="
            "${REPO_ROOT}/scripts/generate-omp-agents.sh"
            echo "== sync: omp commands =="
            "${REPO_ROOT}/scripts/generate-omp-commands.sh"
            echo "== sync: omp native packages and catalog =="
            "${REPO_ROOT}/scripts/generate-omp-packages.sh"
            ;;
        pi)
            # Skills only (YAN-1184); packages/pi/ycc/package.json arrives with YAN-1188.
            echo "== sync: pi skills =="
            "${REPO_ROOT}/scripts/generate-pi-skills.sh"
            ;;
        antigravity)
            echo "== sync: antigravity plugins =="
            "${REPO_ROOT}/scripts/generate-antigravity-packages.sh"
            ;;
        agents)
            echo "== sync: agents skills =="
            "${REPO_ROOT}/scripts/generate-agents-skills.sh"
            ;;
        claude)
            echo "== sync: claude packages =="
            "${REPO_ROOT}/scripts/generate-claude-packages.sh"
            ;;
    esac
}

for target in "${TARGETS[@]}"; do
    run_ycc_target "${target}"
done

echo "sync.sh: done (targets: ${TARGETS[*]})"
