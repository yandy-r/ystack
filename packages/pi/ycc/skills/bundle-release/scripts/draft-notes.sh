#!/usr/bin/env bash
# draft-notes.sh — Fill the release-notes template and write docs/releases/<version>.md.
#
# Usage:
#   draft-notes.sh <new-version>
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
        echo "draft-notes.sh: FAIL: YCC_REPO_ROOT does not point at ystack: ${YCC_REPO_ROOT}" >&2
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

    echo "draft-notes.sh: FAIL: could not resolve ystack repo root" >&2
    echo "  run from the repository checkout or use the source-tree script" >&2
    exit 1
}

REPO_ROOT="$(resolve_repo_root)"

usage() {
    cat <<EOF
Usage: $(basename "$0") <new-version>

Draft release notes for <new-version> at docs/releases/<new-version>.md,
filled from ycc/skills/bundle-release/references/release-notes-template.md.

Sources:
  - Date: UTC today
  - Commits: git log since last tag (or full history if no tags)
  - Added/Changed/Removed/Fixed: filtered by conventional-commit prefix

Options:
  -h, --help   Show this help
EOF
}

# --- argument parsing ---
NEW_VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "draft-notes.sh: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -z "${NEW_VERSION}" ]]; then
                NEW_VERSION="$1"
            else
                echo "draft-notes.sh: unexpected argument: $1" >&2
                usage >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "${NEW_VERSION}" ]]; then
    echo "draft-notes.sh: new-version is required" >&2
    usage >&2
    exit 1
fi

if ! [[ "${NEW_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "draft-notes.sh: invalid version '${NEW_VERSION}' — expected semver (e.g. 1.2.3)" >&2
    exit 1
fi

# --- guards ---
OUT="${REPO_ROOT}/docs/releases/${NEW_VERSION}.md"
[[ -e "${OUT}" ]] && { echo "draft-notes.sh: refuse: ${OUT} already exists" >&2; exit 1; }

TEMPLATE="${REPO_ROOT}/ycc/skills/bundle-release/references/release-notes-template.md"
[[ -f "${TEMPLATE}" ]] || { echo "draft-notes.sh: template missing: ${TEMPLATE}" >&2; exit 1; }

# --- gather inputs ---
cd "${REPO_ROOT}"

DATE_STR="$(date -u +%Y-%m-%d)"
PREV_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo "(no previous tag)")"

if [[ "${PREV_TAG}" == "(no previous tag)" ]]; then
    COMMITS_RAW="$(git log --oneline)"
else
    COMMITS_RAW="$(git log "${PREV_TAG}..HEAD" --oneline)"
fi
[[ -z "${COMMITS_RAW}" ]] && COMMITS_RAW="(no commits since ${PREV_TAG})"

filter() {
    local pattern="$1"
    local out
    out="$(echo "${COMMITS_RAW}" | grep -iE "${pattern}" || true)"
    [[ -z "${out}" ]] && out="TODO: none this release"
    echo "${out}"
}

ADDED="$(filter '^[a-f0-9]+ (feat|add)')"
CHANGED="$(filter '^[a-f0-9]+ (refactor|chore|perf|update|change)')"
REMOVED="$(filter '(remove|delete|drop)')"
FIXED="$(filter '^[a-f0-9]+ fix')"
# --- packages table from ycc/settings/packages.json (skips file-copy entries) ---
PACKAGES_TABLE="$(python3 - "${REPO_ROOT}/ycc/settings/packages.json" "${NEW_VERSION}" <<'PY'
import json, sys

path = sys.argv[1]
version = sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        model = json.load(fh)
except (OSError, ValueError) as exc:
    print(f"draft-notes.sh: FAIL: cannot read {path}: {exc}", file=sys.stderr)
    sys.exit(1)
packages = model.get("packages", {})
if not isinstance(packages, dict):
    print(f"draft-notes.sh: FAIL: {path}: packages must be an object", file=sys.stderr)
    sys.exit(1)

RUNTIME_ORDER = ("claude", "codex", "cursor", "opencode", "agents", "omp", "pi")
rows = []
for key in sorted(packages):
    package = packages[key]
    if not isinstance(package, dict):
        continue
    runtimes = package.get("runtimes", {})
    if not isinstance(runtimes, dict):
        continue
    for runtime in RUNTIME_ORDER:
        entry = runtimes.get(runtime)
        if not isinstance(entry, dict):
            continue
        if entry.get("mechanism") == "file-copy":
            continue
        status = entry.get("status", "")
        mechanism = entry.get("mechanism", "")
        listed = entry.get("listed") is True
        target = entry.get("target_release")
        if status == "included":
            version_cell = version
        elif target:
            version_cell = f"target {target}"
        else:
            version_cell = "—"
        notes = []
        if entry.get("experimental"):
            notes.append("experimental")
        if entry.get("opt_in"):
            notes.append("opt-in")
        if entry.get("notes"):
            notes.append(str(entry["notes"]))
        rows.append(
            f"| {key} | {runtime} | {status} | {mechanism} | {'yes' if listed else 'no'} "
            f"| {version_cell} | {'; '.join(notes) or '—'} |"
        )

print("| Package | Runtime | Status | Mechanism | Listed | Version or target | Notes |")
print("| --- | --- | --- | --- | --- | --- | --- |")
for row in rows:
    print(row)
PY
)"

# --- substitute placeholders via python3 (template, out, version, table, inputs) ---
python3 - "${TEMPLATE}" "${OUT}" "${NEW_VERSION}" "${PACKAGES_TABLE}" "${DATE_STR}" "${PREV_TAG}" "${COMMITS_RAW}" "${ADDED}" "${CHANGED}" "${REMOVED}" "${FIXED}" <<'PY'
import sys, pathlib
template_path = pathlib.Path(sys.argv[1])
out_path      = pathlib.Path(sys.argv[2])
version       = sys.argv[3]
packages_table= sys.argv[4]
date_str      = sys.argv[5]
prev_tag      = sys.argv[6]
commits       = sys.argv[7]
added         = sys.argv[8]
changed       = sys.argv[9]
removed       = sys.argv[10]
fixed         = sys.argv[11]

text = template_path.read_text()
text = (text
        .replace("{{VERSION}}", version)
        .replace("{{DATE}}", date_str)
        .replace("{{PREV_TAG}}", prev_tag)
        .replace("{{COMMITS_ADDED}}", added)
        .replace("{{COMMITS_CHANGED}}", changed)
        .replace("{{COMMITS_REMOVED}}", removed)
        .replace("{{COMMITS_FIXED}}", fixed)
        .replace("{{PACKAGES_TABLE}}", packages_table)
        .replace("{{COMMITS}}", commits)
       )
out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(text)
PY

echo "draft-notes.sh: wrote ${OUT}"
