#!/usr/bin/env bash
# Bump the product version across every hand-edited version surface in lockstep.
#
# Usage:
#   bump-version.sh <new-version>
#
# Updates (discovery rules live in release_versions.py):
#   - ycc/.claude-plugin/plugin.json (.version)
#   - .claude-plugin/marketplace.json (.metadata.version and each
#     .plugins[].version that exists)
#   - versioned source package manifest (ycc/package.json)
#
# Reads ycc/settings/packages.json (directly, in release_versions.py) to learn the
# required included native manifests; a missing or malformed model fails before any
# writes. Included native manifests must exist and carry a version; deferred/excluded
# paths are suppressed and file-copy entries are skipped. Included opencode npm
# manifests are required to exist at the lockstep version (check-only).
# Never touches ycc/mods (versioned separately) or generated bundles
# (packages/ including packages/omp/<pkg>/.omp-plugin/plugin.json, .agents/plugins/,
# .cursor-plugin/, .codex-plugin/, .opencode-plugin/, the .omp-plugin/ catalog) —
# refresh those with ./scripts/sync.sh after the bump; preflight.sh enforces their parity.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_repo_root() {
    local root
    if [[ -n "${YCC_REPO_ROOT:-}" ]]; then
        root="$(cd "${YCC_REPO_ROOT}" && pwd)"
        if [[ -f "${root}/ycc/.claude-plugin/plugin.json" ]]; then
            printf '%s\n' "${root}"
            return 0
        fi
        echo "bump-version.sh: FAIL: YCC_REPO_ROOT does not point at ystack: ${YCC_REPO_ROOT}" >&2
        exit 1
    fi

    if root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        if [[ -f "${root}/ycc/.claude-plugin/plugin.json" ]]; then
            printf '%s\n' "${root}"
            return 0
        fi
    fi

    root="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
    if [[ -f "${root}/ycc/.claude-plugin/plugin.json" ]]; then
        printf '%s\n' "${root}"
        return 0
    fi

    echo "bump-version.sh: FAIL: could not resolve ystack repo root" >&2
    echo "  run from the repository checkout or use the source-tree script" >&2
    exit 1
}

REPO_ROOT="$(resolve_repo_root)"

usage() {
    cat <<EOF
Usage: bump-version.sh <new-version>

Bump the product version across every hand-edited version surface in lockstep:
  - ycc/.claude-plugin/plugin.json (.version)
  - .claude-plugin/marketplace.json (.metadata.version and every .plugins[].version)
  - ycc/package.json if it already carries a version
Versionless entries stay versionless. ycc/mods is never touched. Generated
bundles (packages/ including packages/omp/<pkg>/.omp-plugin/plugin.json,
.agents/plugins/, .cursor-plugin/, .codex-plugin/, .opencode-plugin/, the
.omp-plugin/ catalog) are not edited — run ./scripts/sync.sh afterwards. Validates
semver format (x.y.z); malformed inputs, a missing/malformed package model, or a
missing/versionless required manifest abort before any file is written.
EOF
}

if [[ $# -eq 0 ]]; then
    usage >&2
    exit 1
fi

case "$1" in
    -h|--help)
        usage
        exit 0
        ;;
esac

NEW_VERSION="$1"

if ! [[ "${NEW_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "bump-version.sh: invalid semver '${NEW_VERSION}' (expected x.y.z)" >&2
    exit 1
fi

python3 "${SCRIPT_DIR}/release_versions.py" bump "${REPO_ROOT}" "${NEW_VERSION}" || {
    echo "bump-version.sh: FAIL: version bump failed (see diagnostics above)" >&2
    exit 1
}

echo "bump-version.sh: OK (${NEW_VERSION})"
