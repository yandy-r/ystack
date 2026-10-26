#!/usr/bin/env bash
# apply-ci.sh
# Render the CI workflow templates (lint.yml + lint-autofix.yml) and install
# them under .github/workflows/ in the target repo. Each destination is managed
# independently: refuses to overwrite an existing file unless --force.
#
# Usage: apply-ci.sh --target <dir> --profile-file <path>
#                    [--template-dir <dir>] [--dry-run] [--force] [--no-autofix]

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DEFAULT_TEMPLATE_DIR="${SCRIPT_DIR}/../references/templates"

target=""
profile_file=""
template_dir="$DEFAULT_TEMPLATE_DIR"
dry_run=false
force=false
no_autofix=false

usage() {
    cat >&2 <<'EOF'
Usage: apply-ci.sh --target <dir> --profile-file <path>
                   [--template-dir <dir>] [--dry-run] [--force] [--no-autofix]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)         target="$2"; shift 2 ;;
        --target=*)       target="${1#*=}"; shift ;;
        --profile-file)   profile_file="$2"; shift 2 ;;
        --profile-file=*) profile_file="${1#*=}"; shift ;;
        --template-dir)   template_dir="$2"; shift 2 ;;
        --template-dir=*) template_dir="${1#*=}"; shift ;;
        --dry-run)        dry_run=true; shift ;;
        --force)          force=true; shift ;;
        --no-autofix)     no_autofix=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "[apply-ci] ERROR: unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

[[ -z "$target" ]]         && { echo "[apply-ci] ERROR: --target is required" >&2; exit 1; }
[[ -z "$profile_file" ]]   && { echo "[apply-ci] ERROR: --profile-file is required" >&2; exit 1; }
[[ ! -d "$target" ]]       && { echo "[apply-ci] ERROR: target not a directory: $target" >&2; exit 1; }
[[ ! -f "$profile_file" ]] && { echo "[apply-ci] ERROR: profile file missing: $profile_file" >&2; exit 1; }

target="$(cd "$target" && pwd)"

# Resolve the target repo's default branch for the lint.yml push trigger and
# the autofix PR trigger.
# Falls back to "main" when the target is not a git repo or has no origin/HEAD.
default_branch=""
if ref="$(git -C "$target" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    default_branch="${ref#origin/}"
fi
[[ -z "$default_branch" ]] && default_branch="main"

info() { echo "[apply-ci] $*"; }

render_and_install() {
    local tpl_name="$1"
    local rel_dest="$2"
    local tpl="$template_dir/$tpl_name"
    local dest="$target/$rel_dest"

    if [[ ! -f "$tpl" ]]; then
        echo "[apply-ci] ERROR: template missing: $tpl" >&2
        return 1
    fi

    if [[ -f "$dest" && "$force" != "true" ]]; then
        info "$dest already exists; skipping (pass --force to overwrite)"
        return 0
    fi

    export APPLY_CI_TEMPLATE="$tpl"
    export APPLY_CI_PROFILE="$profile_file"
    export APPLY_CI_DEFAULT_BRANCH="$default_branch"

    local rendered
    rendered="$(python3 <<'PYEOF'
import os, re
from pathlib import Path

tpl = Path(os.environ["APPLY_CI_TEMPLATE"]).read_text(encoding="utf-8")
profile_text = Path(os.environ["APPLY_CI_PROFILE"]).read_text(encoding="utf-8")
default_branch = os.environ.get("APPLY_CI_DEFAULT_BRANCH") or "main"

profile = {}
for line in profile_text.splitlines():
    if "=" not in line:
        continue
    k, _, v = line.partition("=")
    profile[k.strip()] = v.strip()

flags = {
    "IF_RUST":   profile.get("detect_rust")   == "true",
    "IF_GO":     profile.get("detect_go")     == "true",
    "IF_TS":     profile.get("detect_ts")     == "true",
    "IF_PYTHON": profile.get("detect_python") == "true",
    "IF_DOCS":   profile.get("detect_docs")   == "true",
    "IF_SHELL":  profile.get("detect_shell")  == "true",
}

docs_prettier_glob = "**/*.{md,mdx,yaml,yml}" if flags["IF_TS"] else "**/*.{md,mdx,json,jsonc,yaml,yml}"

pat = re.compile(r"\{\{#(\w+)\}\}(.*?)\{\{/\1\}\}", re.DOTALL)
out = pat.sub(lambda m: m.group(2) if flags.get(m.group(1), False) else "", tpl)
out = out.replace("{{DEFAULT_BRANCH}}", default_branch)
out = out.replace("{{DOCS_PRETTIER_GLOB}}", docs_prettier_glob)
out = re.sub(r"\n{3,}", "\n\n", out)
print(out, end="")
PYEOF
)"

    if $dry_run; then
        info "[dry-run] would write $dest"
        # Print the preview from a here-string, not `printf | head`: under
        # pipefail the early-exiting head SIGPIPEs the writer (YAN-1587).
        head -n 20 <<<"$rendered"
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    printf '%s' "$rendered" > "$dest"
    info "wrote $dest"
}

render_and_install "lint.yml.tmpl" ".github/workflows/lint.yml"

if [[ "$no_autofix" != "true" ]]; then
    render_and_install "lint-autofix.yml.tmpl" ".github/workflows/lint-autofix.yml"
fi

exit 0
