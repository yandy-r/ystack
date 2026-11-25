#!/usr/bin/env bash
# Pre-flight gate for the bundle-release skill.
# Checks that the git working tree is clean, every product version field is in
# parity with ycc/.claude-plugin/plugin.json (all marketplace plugins[] entries
# and package manifests; ycc/mods is excluded), warns if not on the main
# branch, and scans hand-edited docs for stale semver literals that don't
# match the current version. Version discovery reads ycc/settings/packages.json
# directly: included native manifests are required to exist with a version
# (regardless of listed), deferred/excluded paths are suppressed, file-copy
# entries are skipped, and included opencode npm manifests are required to exist
# at the lockstep version (check-only). A bounded scan backstops unmodeled
# manifests. A missing or malformed model fails the check.
#
# Usage:
#   preflight.sh
#   preflight.sh -h|--help
#
# Exits 0 on success and prints: current_version=<ver>, branch=<name>
# Exits 1 on hard failure (tree dirty, version parity violation, or stale
# version literal detected in hand-edited docs)
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
        echo "preflight.sh: FAIL: YCC_REPO_ROOT does not point at ystack: ${YCC_REPO_ROOT}" >&2
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

    echo "preflight.sh: FAIL: could not resolve ystack repo root" >&2
    echo "  run from the repository checkout or use the source-tree script" >&2
    exit 1
}

REPO_ROOT="$(resolve_repo_root)"

usage() {
    cat <<'EOF'
Usage: preflight.sh

Gate checks before a ycc release:
  1. git working tree is clean
  2. version parity across ycc/.claude-plugin/plugin.json, every
     marketplace plugins[] entry, and package manifests (ycc/mods excluded),
     driven by ycc/settings/packages.json (included native and opencode npm
     manifests required at the lockstep version; deferred/excluded suppressed)
     plus a bounded scan for unmodeled manifests
  3. warn if not on main branch
  4. no stale version literals (version: X.Y.Z or "version": "X.Y.Z")
     in hand-edited docs where the semver does not match the current
     version. Example literals should use the "<managed by the
     bundle-release skill>" placeholder — or match the current version.

Exits 0 on success and prints: current_version=<ver>, branch=<name>
Exits 1 on hard failure (tree dirty, version parity, or stale literal)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "preflight.sh: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# --- Check 1: clean git tree ---
cd "${REPO_ROOT}"
if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git status --porcelain)" ]]; then
    echo "preflight.sh: FAIL: git working tree is not clean" >&2
    git status --short >&2
    exit 1
fi

# --- Check 2: current branch warn ---
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "${BRANCH}" != "main" ]]; then
    echo "preflight.sh: WARN: current branch is '${BRANCH}', not 'main'" >&2
fi

# --- Check 3: version parity (all discovered surfaces; see release_versions.py) ---
if ! PLUGIN_VERSION="$(python3 "${SCRIPT_DIR}/release_versions.py" check "${REPO_ROOT}")"; then
    echo "preflight.sh: FAIL: version parity violation" >&2
    echo "  expected every product version field to equal ycc/.claude-plugin/plugin.json .version" >&2
    echo "  (run ./scripts/sync.sh to refresh generated manifests after a bump)" >&2
    exit 1
fi

# --- Check 4: no stale version literals in hand-edited docs ---
#
# Scans a fixed allowlist of hand-edited files for patterns that look like
# version declarations in an example (version: X.Y.Z or "version": "X.Y.Z").
# Any matched semver that does not equal PLUGIN_VERSION is flagged as stale
# — the author should either bump the example to match or replace it with
# the "<managed by bundle-release>" placeholder.
#
# Prose mentions of older versions (e.g., "2.0.0 breaking change") are not
# matched because the pattern requires a "version" key preceding the semver.
#
# Generated bundles (.opencode-plugin, .cursor-plugin, .codex-plugin, the
# .omp-plugin catalog, packages/ including packages/omp/<pkg>/.omp-plugin) and
# historical directories (docs/releases, docs/plans, docs/research,
# docs/internal) are excluded.

scan_targets=(
    "${REPO_ROOT}/CLAUDE.md"
    "${REPO_ROOT}/AGENTS.md"
    "${REPO_ROOT}/README.md"
    "${REPO_ROOT}/docs/README.md"
)

stale_found=0
version_literal_re='[Vv]ersion"?[[:space:]]*[:=][[:space:]]*"?[0-9]+\.[0-9]+\.[0-9]+"?'
semver_re='[0-9]+\.[0-9]+\.[0-9]+'

for target in "${scan_targets[@]}"; do
    [[ -f "${target}" ]] || continue
    while IFS=: read -r lineno match; do
        [[ -n "${match}" ]] || continue
        sem="$(printf '%s' "${match}" | grep -oE "${semver_re}" | head -n1)"
        [[ -n "${sem}" ]] || continue
        if [[ "${sem}" != "${PLUGIN_VERSION}" ]]; then
            rel="${target#"${REPO_ROOT}"/}"
            echo "preflight.sh: FAIL: stale version literal (${sem} != ${PLUGIN_VERSION}) at ${rel}:${lineno}" >&2
            echo "    ${match}" >&2
            stale_found=1
        fi
    done < <(grep -nE "${version_literal_re}" "${target}" 2>/dev/null || true)
done

if [[ ${stale_found} -eq 1 ]]; then
    echo "preflight.sh: HINT: update the literal to match ${PLUGIN_VERSION}, or replace it with the '<managed by the bundle-release skill>' placeholder." >&2
    exit 1
fi

# --- Success ---
echo "preflight.sh: OK"
echo "current_version=${PLUGIN_VERSION}"
echo "branch=${BRANCH}"
