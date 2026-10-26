#!/usr/bin/env bash
# apply-aliases.sh
# Inject lint/format aliases into a project's native task-runner surface:
#   - package.json scripts (preferred when Node is present)
#   - Makefile
#   - justfile
#
# Usage: apply-aliases.sh --target <dir> [--strategy=auto|package-json|makefile|justfile]
#                         [--template-dir <dir>] [--dry-run] [--force]
#
# Reads: the template files under --template-dir (default: alongside this script)
# Writes (subject to --dry-run): package.json, Makefile, or justfile inside --target.
# Safe: makes a .bak copy of package.json before jq-merge.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DEFAULT_TEMPLATE_DIR="${SCRIPT_DIR}/../references/templates"

target=""
strategy="auto"
template_dir="$DEFAULT_TEMPLATE_DIR"
dry_run=false
force=false

usage() {
    cat >&2 <<'EOF'
Usage: apply-aliases.sh --target <dir> [--strategy=auto|package-json|makefile|justfile]
                        [--template-dir <dir>] [--dry-run] [--force]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)        target="$2"; shift 2 ;;
        --target=*)      target="${1#*=}"; shift ;;
        --strategy)      strategy="$2"; shift 2 ;;
        --strategy=*)    strategy="${1#*=}"; shift ;;
        --template-dir)  template_dir="$2"; shift 2 ;;
        --template-dir=*) template_dir="${1#*=}"; shift ;;
        --dry-run)       dry_run=true; shift ;;
        --force)         force=true; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "[apply-aliases] ERROR: unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$target" ]]; then
    echo "[apply-aliases] ERROR: --target is required" >&2
    usage
    exit 1
fi

if [[ ! -d "$target" ]]; then
    echo "[apply-aliases] ERROR: target not a directory: $target" >&2
    exit 1
fi

target="$(cd "$target" && pwd)"

require_template() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "[apply-aliases] ERROR: template missing: $path" >&2
        exit 1
    fi
}

info() { echo "[apply-aliases] $*"; }

# ---------------------------------------------------------------------------
# Strategy resolution
# ---------------------------------------------------------------------------
if [[ "$strategy" == "auto" ]]; then
    if   [[ -f "$target/package.json" ]]; then strategy="package-json"
    elif [[ -f "$target/Makefile" || -f "$target/makefile" || -f "$target/GNUmakefile" ]]; then strategy="makefile"
    elif [[ -f "$target/justfile" || -f "$target/Justfile" ]]; then strategy="justfile"
    else strategy="makefile"
    fi
    info "strategy=auto resolved to: $strategy"
fi

# ---------------------------------------------------------------------------
# Strategy: package-json (jq-merge)
# ---------------------------------------------------------------------------
apply_package_json() {
    local tpl="$template_dir/package-json-scripts.json.tmpl"
    require_template "$tpl"

    local pkg="$target/package.json"
    if [[ ! -f "$pkg" ]]; then
        echo "[apply-aliases] ERROR: package.json missing at $pkg" >&2
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "[apply-aliases] ERROR: jq is required for package-json strategy" >&2
        exit 1
    fi

    if ! jq empty "$pkg" >/dev/null 2>&1; then
        echo "[apply-aliases] ERROR: $pkg is not valid JSON" >&2
        exit 1
    fi

    # Detect existing alias keys to avoid clobbering unless --force.
    local existing
    existing="$(jq -r '.scripts // {} | to_entries[]? | .key' "$pkg" 2>/dev/null || true)"

    local template_keys=(
        lint lint:modified lint:staged lint:unstaged
        lint:fix lint:fix:modified
        format format:modified format:staged format:unstaged
    )
    local conflicts=()
    # Here-string, not `printf | grep -q`: under pipefail the early-exiting
    # grep can SIGPIPE the writer and a present key reads as absent (YAN-1607).
    for key in "${template_keys[@]}"; do
        if grep -Fxq -- "$key" <<<"$existing"; then
            conflicts+=("$key")
        fi
    done

    local merged
    if $force || [[ ${#conflicts[@]} -eq 0 ]]; then
        merged="$(jq --slurpfile tpl <(cat "$tpl") '
            .scripts = ((.scripts // {}) + ($tpl[0].scripts // {}))
        ' "$pkg")"
    else
        # Only add non-conflicting keys.
        merged="$(jq --slurpfile tpl <(cat "$tpl") '
            .scripts = (($tpl[0].scripts // {}) + (.scripts // {}))
        ' "$pkg")"
        info "kept existing keys: ${conflicts[*]} (pass --force to overwrite)"
    fi

    if $dry_run; then
        info "[dry-run] would update $pkg with merged scripts block"
        diff -u <(jq . "$pkg") <(printf '%s\n' "$merged") | head -40 || true
        return 0
    fi

    cp "$pkg" "${pkg}.bak"
    printf '%s\n' "$merged" > "$pkg"
    info "updated $pkg (backup at ${pkg}.bak)"
}

# ---------------------------------------------------------------------------
# Strategy: makefile
# ---------------------------------------------------------------------------
apply_makefile() {
    local tpl="$template_dir/makefile-snippet.mk.tmpl"
    require_template "$tpl"

    local mk
    if   [[ -f "$target/Makefile" ]];    then mk="$target/Makefile"
    elif [[ -f "$target/makefile" ]];    then mk="$target/makefile"
    elif [[ -f "$target/GNUmakefile" ]]; then mk="$target/GNUmakefile"
    else mk="$target/Makefile"
    fi

    if [[ -f "$mk" ]] && grep -q 'ycc:formatters managed block' "$mk" 2>/dev/null; then
        if ! $force; then
            info "Makefile already contains ycc:formatters managed block; skipping (pass --force to replace)"
            return 0
        fi
        if $dry_run; then
            info "[dry-run] would replace managed block in $mk"
            return 0
        fi
        # Strip existing block and append fresh.
        awk '
            /^# --- ycc:formatters managed block/ {skip=1; next}
            /^# --- end ycc:formatters managed block/ {skip=0; next}
            !skip
        ' "$mk" > "${mk}.tmp"
        mv "${mk}.tmp" "$mk"
    fi

    if $dry_run; then
        info "[dry-run] would append makefile snippet to $mk"
        return 0
    fi

    if [[ -f "$mk" ]]; then
        printf '\n' >> "$mk"
        cat "$tpl" >> "$mk"
        info "appended managed block to $mk"
    else
        cp "$tpl" "$mk"
        info "created $mk"
    fi
}

# ---------------------------------------------------------------------------
# Strategy: justfile
# ---------------------------------------------------------------------------
apply_justfile() {
    local tpl="$template_dir/justfile-snippet.just.tmpl"
    require_template "$tpl"

    local jf
    if   [[ -f "$target/justfile" ]]; then jf="$target/justfile"
    elif [[ -f "$target/Justfile" ]]; then jf="$target/Justfile"
    else jf="$target/justfile"
    fi

    if [[ -f "$jf" ]] && grep -q 'ycc:formatters managed block' "$jf" 2>/dev/null; then
        if ! $force; then
            info "justfile already contains ycc:formatters managed block; skipping (pass --force to replace)"
            return 0
        fi
        if $dry_run; then
            info "[dry-run] would replace managed block in $jf"
            return 0
        fi
        awk '
            /^# --- ycc:formatters managed block/ {skip=1; next}
            /^# --- end ycc:formatters managed block/ {skip=0; next}
            !skip
        ' "$jf" > "${jf}.tmp"
        mv "${jf}.tmp" "$jf"
    fi

    if $dry_run; then
        info "[dry-run] would append justfile recipes to $jf"
        return 0
    fi

    if [[ -f "$jf" ]]; then
        printf '\n' >> "$jf"
        cat "$tpl" >> "$jf"
        info "appended managed block to $jf"
    else
        cp "$tpl" "$jf"
        info "created $jf"
    fi
}

case "$strategy" in
    package-json) apply_package_json ;;
    makefile)     apply_makefile ;;
    justfile)     apply_justfile ;;
    *) echo "[apply-aliases] ERROR: unknown strategy: $strategy" >&2; exit 1 ;;
esac

exit 0
