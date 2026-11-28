#!/usr/bin/env bash
# apply-hooks.sh
# Wire a pre-commit hook that runs `./scripts/style.sh lint --staged --fix`
# and `./scripts/style.sh format --staged`.
# Chooses between lefthook (preferred) and husky based on what the project uses.
#
# When an existing `lefthook.yml` is present (e.g., because `ycc:init --git` ran
# first), merge managed `pre-commit` commands into it instead of overwriting —
# this preserves init-owned `pre-push` and `commit-msg` stages.
#
# Usage: apply-hooks.sh --target <dir> --profile-file <path>
#                       [--tool=auto|lefthook|husky|native]
#                       [--template-dir <dir>] [--dry-run] [--force]

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
DEFAULT_TEMPLATE_DIR="${SCRIPT_DIR}/../references/templates"

target=""
profile_file=""
tool="auto"
template_dir="$DEFAULT_TEMPLATE_DIR"
dry_run=false
force=false

usage() {
    cat >&2 <<'EOF'
Usage: apply-hooks.sh --target <dir> --profile-file <path>
                      [--tool=auto|lefthook|husky|native]
                      [--template-dir <dir>] [--dry-run] [--force]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)        target="$2"; shift 2 ;;
        --target=*)      target="${1#*=}"; shift ;;
        --profile-file)  profile_file="$2"; shift 2 ;;
        --profile-file=*) profile_file="${1#*=}"; shift ;;
        --tool)          tool="$2"; shift 2 ;;
        --tool=*)        tool="${1#*=}"; shift ;;
        --template-dir)  template_dir="$2"; shift 2 ;;
        --template-dir=*) template_dir="${1#*=}"; shift ;;
        --dry-run)       dry_run=true; shift ;;
        --force)         force=true; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "[apply-hooks] ERROR: unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

[[ -z "$target" ]]         && { echo "[apply-hooks] ERROR: --target is required" >&2; exit 1; }
[[ -z "$profile_file" ]]   && { echo "[apply-hooks] ERROR: --profile-file is required" >&2; exit 1; }
[[ ! -d "$target" ]]       && { echo "[apply-hooks] ERROR: target not a directory: $target" >&2; exit 1; }
[[ ! -f "$profile_file" ]] && { echo "[apply-hooks] ERROR: profile file missing: $profile_file" >&2; exit 1; }

target="$(cd "$target" && pwd)"

info() { echo "[apply-hooks] $*"; }
warn() { echo "[apply-hooks] WARN: $*" >&2; }

get_profile() {
    local key="$1"
    awk -F= -v k="$key" '$1 == k { print $2; found=1; exit } END { if (!found) print "" }' "$profile_file"
}

has_git="$(get_profile has_git)"
has_lefthook="$(get_profile has_lefthook)"
has_husky="$(get_profile has_husky)"

if [[ "$has_git" != "true" ]]; then
    echo "[apply-hooks] ERROR: target is not a git repository: $target" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve tool
# ---------------------------------------------------------------------------
if [[ "$tool" == "auto" ]]; then
    if   [[ "$has_lefthook" == "true" ]]; then tool="lefthook"
    elif [[ "$has_husky"    == "true" ]]; then tool="husky"
    else                                        tool="lefthook"
    fi
    info "tool=auto resolved to: $tool"
fi

# ---------------------------------------------------------------------------
# Merge helpers (lefthook only)
# ---------------------------------------------------------------------------
# Check if the managed commands (style-lint, style-format) are already present
# in an existing lefthook.yml.
managed_commands_present() {
    local dest="$1"
    grep -qE '^[[:space:]]*style-lint:' "$dest" \
        && grep -qE '^[[:space:]]*style-format:' "$dest"
}

# Merge the managed `pre-commit` commands from the template into an existing
# lefthook.yml, preserving all other stages (pre-push, commit-msg, etc.) and
# any commands the user added under pre-commit. Uses Python with PyYAML when
# available — yaml is not trivially mergeable with shell tooling.
merge_lefthook_yaml() {
    local dest="$1"
    local tpl="$2"

    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import yaml" >/dev/null 2>&1; then
        return 2
    fi

    python3 - "$dest" "$tpl" <<'PY' || return 1
import sys
import yaml
from pathlib import Path

dest_path = Path(sys.argv[1])
tpl_path = Path(sys.argv[2])

existing = yaml.safe_load(dest_path.read_text()) or {}
managed = yaml.safe_load(tpl_path.read_text()) or {}

existing.setdefault("pre-commit", {})
existing["pre-commit"].setdefault("commands", {})

managed_pc = managed.get("pre-commit", {})
for key, value in managed_pc.get("commands", {}).items():
    existing["pre-commit"]["commands"][key] = value

# Inherit parallel flag from managed when the user has not set one.
if "parallel" in managed_pc and "parallel" not in existing["pre-commit"]:
    existing["pre-commit"]["parallel"] = managed_pc["parallel"]

dest_path.write_text(yaml.safe_dump(existing, sort_keys=False, default_flow_style=False))
PY
}

install_lefthook() {
    local tpl="$template_dir/lefthook.yml.tmpl"
    [[ ! -f "$tpl" ]] && { echo "[apply-hooks] ERROR: template missing: $tpl" >&2; exit 1; }

    local dest="$target/lefthook.yml"

    # Case 1: fresh install — copy template verbatim.
    if [[ ! -f "$dest" ]]; then
        if $dry_run; then
            info "[dry-run] would write $dest"
            return 0
        fi
        cp "$tpl" "$dest"
        info "wrote $dest"
        warn "run 'lefthook install' (once) to activate git hooks"
        warn "bypass a single commit with: git commit --no-verify"
        return 0
    fi

    # Case 2: existing file with managed commands already present — no-op.
    if managed_commands_present "$dest"; then
        info "existing $dest already has managed pre-commit commands (style-lint, style-format); no changes"
        return 0
    fi

    # Case 3: --force — overwrite.
    if [[ "$force" == "true" ]]; then
        if $dry_run; then
            info "[dry-run] would overwrite $dest"
            return 0
        fi
        cp "$tpl" "$dest"
        info "overwrote $dest (--force)"
        warn "run 'lefthook install' to re-activate git hooks"
        return 0
    fi

    # Case 4: existing lefthook.yml from init (or user) — merge our pre-commit commands in.
    if $dry_run; then
        info "[dry-run] would merge pre-commit.commands (style-lint, style-format) into $dest"
        return 0
    fi

    local backup="${dest}.bak.$$"
    cp "$dest" "$backup"

    if merge_lefthook_yaml "$dest" "$tpl"; then
        info "merged managed pre-commit commands into $dest (backup at $backup)"
        warn "run 'lefthook install' to activate the updated hooks"
        warn "bypass a single commit with: git commit --no-verify"
        return 0
    fi

    local merge_status=$?
    # Restore original and surface a manual-merge instruction.
    mv "$backup" "$dest"
    if [[ "$merge_status" == "2" ]]; then
        warn "python3 with PyYAML not found — automatic merge unavailable."
    else
        warn "python merge failed — left $dest unchanged."
    fi
    warn "manual merge required: add the 'pre-commit.commands' entries from $tpl into $dest"
    warn "no changes written; skipping lefthook install"
    return 0
}

install_husky() {
    local tpl="$template_dir/husky-pre-commit.tmpl"
    [[ ! -f "$tpl" ]] && { echo "[apply-hooks] ERROR: template missing: $tpl" >&2; exit 1; }

    local husky_dir="$target/.husky"
    local dest="$husky_dir/pre-commit"

    if [[ -f "$dest" && "$force" != "true" ]]; then
        info ".husky/pre-commit already exists; skipping (pass --force to overwrite)"
        return 0
    fi

    if $dry_run; then
        info "[dry-run] would write $dest"
        return 0
    fi

    mkdir -p "$husky_dir"
    cp "$tpl" "$dest"
    chmod +x "$dest"
    info "wrote $dest"
    warn "ensure 'husky install' ran (usually via package.json prepare script)"
    warn "bypass a single commit with: git commit --no-verify"
}

install_native() {
    local dest="$target/.git/hooks/pre-commit"
    if [[ -f "$dest" && "$force" != "true" ]]; then
        info ".git/hooks/pre-commit already exists; skipping (pass --force to overwrite)"
        return 0
    fi

    if $dry_run; then
        info "[dry-run] would write $dest"
        return 0
    fi

    cat > "$dest" <<'EOF'
#!/usr/bin/env sh
# Managed by ycc:formatters (native install — not shared via git).
# To bypass once: git commit --no-verify
set -e
./scripts/style.sh lint --staged --fix
./scripts/style.sh format --staged
git diff --name-only --diff-filter=ACMR --cached | xargs -r git add
EOF
    chmod +x "$dest"
    info "wrote $dest"
    warn "native hook is LOCAL ONLY — it is not shared via git. Prefer lefthook for repo-wide install."
    warn "bypass a single commit with: git commit --no-verify"
}

case "$tool" in
    lefthook) install_lefthook ;;
    husky)    install_husky ;;
    native)   install_native ;;
    *) echo "[apply-hooks] ERROR: unknown tool: $tool" >&2; exit 1 ;;
esac

exit 0
