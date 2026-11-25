#!/usr/bin/env bash
# profile-style.sh
# Detect formatting/linting environment and existing configs in a target project.
# Emits key=value pairs on stdout; never fails on partial detection.
#
# Usage: profile-style.sh [path]
#   path  Optional directory to profile (defaults to $PWD).
#
# Output format: one key=value per line, machine-readable.
# Errors: written to stderr. Detection never fails (always exits 0 unless bad path).
# Exit codes: 0 = success, 1 = argument error (bad/missing path).

set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "[profile-style] ERROR: too many arguments. Usage: profile-style.sh [path]" >&2
    exit 1
fi

target="${1:-$PWD}"

if [[ ! -d "$target" ]]; then
    echo "[profile-style] ERROR: directory not found: ${target}" >&2
    exit 1
fi

project_root="$(cd "$target" && pwd)"

# ---------------------------------------------------------------------------
# Shared ignore-aware detection helpers (path_is_excluded / dir_has_source_suffix).
# Resolve this script's real directory through symlinks so the source works no
# matter how the profiler was invoked, then load the bundle's excludes lib.
# ---------------------------------------------------------------------------
_pf_src="${BASH_SOURCE[0]}"
while [[ -L "$_pf_src" ]]; do
    _pf_dir="$(cd -P "$(dirname "$_pf_src")" >/dev/null 2>&1 && pwd)"
    _pf_src="$(readlink "$_pf_src")"
    [[ "$_pf_src" != /* ]] && _pf_src="${_pf_dir}/${_pf_src}"
done
_pf_script_dir="$(cd -P "$(dirname "$_pf_src")" >/dev/null 2>&1 && pwd)"
_pf_excludes="${_pf_script_dir}/bundle/lib/excludes.sh"
if [[ -f "$_pf_excludes" ]]; then
    # shellcheck source=bundle/lib/excludes.sh
    . "$_pf_excludes"
    style_load_extra_excludes "$project_root"
else
    echo "[profile-style] WARN: excludes helper not found at ${_pf_excludes}; detection falls back to an unfiltered scan" >&2
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
file_exists() { [[ -f "${project_root}/${1}" ]]; }
dir_exists()  { [[ -d "${project_root}/${1}" ]]; }

# True if any non-ignored, non-excluded file under $project_root ends with any of
# the given suffixes. Delegates to the shared ignore-aware helper when it could be
# sourced (honors .gitignore + STYLE_EXCLUDES); otherwise falls back to a raw scan
# that at least prunes the common vendor dirs so a broken install still runs.
any_file_with_suffix() {
    if declare -F dir_has_source_suffix >/dev/null 2>&1; then
        dir_has_source_suffix "$project_root" "$@"
        return
    fi
    local suffix
    for suffix in "$@"; do
        if find "$project_root" -type f ! -path '*/.git/*' \
            ! -path '*/node_modules/*' ! -path '*/vendor/*' ! -path '*/.venv/*' \
            -name "*${suffix}" -print -quit 2>/dev/null | grep -q .; then
            return 0
        fi
    done
    return 1
}

emit() { printf '%s=%s\n' "$1" "$2"; }

# ---------------------------------------------------------------------------
# Stack detection — mirrors scripts/style.sh detect_* functions.
# ---------------------------------------------------------------------------
detect_rust=false
if file_exists "Cargo.toml" || any_file_with_suffix ".rs"; then
    detect_rust=true
fi

detect_go=false
if file_exists "go.mod" || any_file_with_suffix ".go"; then
    detect_go=true
fi

detect_ts=false
if compgen -G "${project_root}/tsconfig*.json" >/dev/null \
   || file_exists "biome.json" || file_exists "biome.jsonc" \
   || any_file_with_suffix ".ts" ".tsx" ".mts" ".cts" ".js" ".jsx" ".mjs" ".cjs"; then
    detect_ts=true
fi

detect_python=false
if file_exists "pyproject.toml" || file_exists "requirements.txt" || file_exists "setup.py" \
   || any_file_with_suffix ".py" ".pyi"; then
    detect_python=true
fi

detect_docs=false
if file_exists ".prettierrc" || file_exists ".prettierrc.json" \
   || file_exists ".prettierrc.yml" || file_exists ".prettierrc.yaml" \
   || file_exists ".markdownlint.json" || file_exists ".markdownlint.jsonc" \
   || file_exists ".markdownlint.yml" || file_exists ".markdownlint.yaml" \
   || any_file_with_suffix ".md" ".mdx" ".yaml" ".yml" \
   || { [[ "$detect_ts" == "false" ]] && any_file_with_suffix ".json" ".jsonc"; }; then
    detect_docs=true
fi

detect_shell=false
if any_file_with_suffix ".sh"; then
    detect_shell=true
fi

emit detect_rust   "$detect_rust"
emit detect_go     "$detect_go"
emit detect_ts     "$detect_ts"
emit detect_python "$detect_python"
emit detect_docs   "$detect_docs"
emit detect_shell  "$detect_shell"

# ---------------------------------------------------------------------------
# Manifest + alias-host probes
# ---------------------------------------------------------------------------
has_package_json=false
package_manager=""
if file_exists "package.json"; then
    has_package_json=true
    if   file_exists "pnpm-lock.yaml";  then package_manager="pnpm"
    elif file_exists "yarn.lock";       then package_manager="yarn"
    elif file_exists "bun.lockb";       then package_manager="bun"
    elif file_exists "package-lock.json"; then package_manager="npm"
    else                                     package_manager="npm"
    fi
fi

has_makefile=false
file_exists "Makefile" && has_makefile=true
file_exists "makefile" && has_makefile=true
file_exists "GNUmakefile" && has_makefile=true

has_justfile=false
file_exists "justfile" && has_justfile=true
file_exists "Justfile" && has_justfile=true

emit has_package_json "$has_package_json"
emit package_manager  "${package_manager:-none}"
emit has_makefile     "$has_makefile"
emit has_justfile     "$has_justfile"

# ---------------------------------------------------------------------------
# Managed-bundle probes
# ---------------------------------------------------------------------------
has_style_bundle=false
file_exists "scripts/.style-bundle-manifest" && has_style_bundle=true
emit has_style_bundle "$has_style_bundle"

# ---------------------------------------------------------------------------
# Existing tool-config probes (drives create-vs-skip decisions)
# ---------------------------------------------------------------------------
has_existing_prettierrc=false
for candidate in .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml .prettierrc.js .prettierrc.cjs .prettierrc.mjs .prettierrc.toml; do
    if file_exists "$candidate"; then has_existing_prettierrc=true; break; fi
done

has_existing_biome_json=false
if file_exists "biome.json" || file_exists "biome.jsonc"; then
    has_existing_biome_json=true
fi

has_existing_golangci_yml=false
if file_exists ".golangci.yml" || file_exists ".golangci.yaml"; then
    has_existing_golangci_yml=true
fi

has_existing_rustfmt_toml=false
file_exists "rustfmt.toml" && has_existing_rustfmt_toml=true
file_exists ".rustfmt.toml" && has_existing_rustfmt_toml=true

has_existing_clippy_toml=false
file_exists "clippy.toml" && has_existing_clippy_toml=true
file_exists ".clippy.toml" && has_existing_clippy_toml=true

has_existing_pyproject_ruff=false
if file_exists "pyproject.toml"; then
    if grep -qE '^\[tool\.(ruff|black)' "${project_root}/pyproject.toml" 2>/dev/null; then
        has_existing_pyproject_ruff=true
    fi
fi

has_existing_markdownlint_json=false
for candidate in .markdownlint.json .markdownlint.jsonc .markdownlint.yaml .markdownlint.yml; do
    if file_exists "$candidate"; then has_existing_markdownlint_json=true; break; fi
done

has_existing_shellcheckrc=false
file_exists ".shellcheckrc" && has_existing_shellcheckrc=true

emit has_existing_prettierrc       "$has_existing_prettierrc"
emit has_existing_biome_json       "$has_existing_biome_json"
emit has_existing_golangci_yml     "$has_existing_golangci_yml"
emit has_existing_rustfmt_toml     "$has_existing_rustfmt_toml"
emit has_existing_clippy_toml      "$has_existing_clippy_toml"
emit has_existing_pyproject_ruff   "$has_existing_pyproject_ruff"
emit has_existing_markdownlint_json "$has_existing_markdownlint_json"
emit has_existing_shellcheckrc     "$has_existing_shellcheckrc"

# ---------------------------------------------------------------------------
# Hook + CI probes
# ---------------------------------------------------------------------------
has_lefthook=false
if file_exists "lefthook.yml" || file_exists "lefthook.yaml" || file_exists ".lefthook.yml" || file_exists ".lefthook.yaml"; then
    has_lefthook=true
fi

has_husky=false
dir_exists ".husky" && has_husky=true

has_pre_commit_framework=false
file_exists ".pre-commit-config.yaml" && has_pre_commit_framework=true

has_git=false
if dir_exists ".git" || git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1; then
    has_git=true
fi

ci_provider="none"
if dir_exists ".github/workflows";  then ci_provider="github"
elif file_exists ".gitlab-ci.yml";   then ci_provider="gitlab"
elif dir_exists ".circleci";         then ci_provider="circleci"
elif file_exists "azure-pipelines.yml"; then ci_provider="azure"
elif file_exists ".drone.yml";       then ci_provider="drone"
fi

has_lint_workflow=false
if [[ "$ci_provider" == "github" ]] && file_exists ".github/workflows/lint.yml"; then
    has_lint_workflow=true
fi

emit has_lefthook             "$has_lefthook"
emit has_husky                "$has_husky"
emit has_pre_commit_framework "$has_pre_commit_framework"
emit has_git                  "$has_git"
emit ci_provider              "$ci_provider"
emit has_lint_workflow        "$has_lint_workflow"

# ---------------------------------------------------------------------------
# Docs target precedence (for apply-docs.sh)
# ---------------------------------------------------------------------------
docs_target="none"
for candidate in README.md readme.md CONTRIBUTING.md AGENTS.md CLAUDE.md; do
    if file_exists "$candidate"; then
        docs_target="$candidate"
        break
    fi
done
emit docs_target "$docs_target"
emit project_root "$project_root"

exit 0
