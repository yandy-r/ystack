# shellcheck shell=bash
# core.sh — shared installer primitives: colors, logging, link/copy helpers,
# managed-config merge, scope handling and the MCP step.
#
# Sourced by install.sh (never run directly); inherits its shell options and
# SCRIPT_DIR, and reads its arg globals (FORCE, SCOPE, COMMAND) and the --mcps
# selection (select.sh) at call time.

MCP_CONFIG_SRC="${SCRIPT_DIR}/mcp-configs/mcp.json"
CONFIG_MERGE_HELPER="${SCRIPT_DIR}/scripts/merge_managed_config.py"

# Colors ($'...' so escapes are real bytes, not literal \\033)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
# shellcheck disable=SC2034  # BOLD is read by bundle.sh and the target libs.
BOLD=$'\033[1m'
NC=$'\033[0m'

info()  { printf "${GREEN}[ok]${NC}  %s\n" "$1"; }
warn()  { printf "${YELLOW}[!!]${NC}  %s\n" "$1"; }
err()   { printf "${RED}[err]${NC} %s\n" "$1" >&2; }

# link_file <src> <dest>
# - Ensures parent of <dest> exists.
# - If <dest> is already a symlink pointing at <src>, does nothing.
# - Otherwise, removes any existing file/symlink at <dest> and creates a symlink.
# - Errors if <src> is missing. Refuses to operate on a directory at <dest>.
link_file() {
    local src="$1"
    local dest="$2"
    [[ -e "$src" ]] || { err "source not found: $src"; exit 1; }
    if [[ -d "$dest" && ! -L "$dest" ]]; then
        err "refusing to replace directory with symlink: $dest"
        exit 1
    fi
    mkdir -p "$(dirname "$dest")"
    if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
        info "link up-to-date: $dest -> $src"
        return 0
    fi
    ln -sfn "$src" "$dest"
    info "linked $dest -> $src"
}

# link_rules_file <src> <dest>
# Stricter variant of link_file for user-customizable agent rules files
# (CLAUDE.md, AGENTS.md). Behaves like link_file EXCEPT that a real
# (non-symlink) regular file at <dest> is treated as user content and the
# link is refused unless FORCE=1. Symlinks are replaced as usual.
link_rules_file() {
    local src="$1"
    local dest="$2"
    [[ -e "$src" ]] || { err "rules source not found: $src"; exit 1; }
    if [[ -d "$dest" && ! -L "$dest" ]]; then
        err "refusing to replace directory with symlink: $dest"
        exit 1
    fi
    if [[ -e "$dest" && ! -L "$dest" && "${FORCE:-0}" != "1" ]]; then
        err "refusing to replace user-authored rules file: $dest"
        err "  move it aside or re-run with --force to overwrite."
        exit 1
    fi
    link_file "$src" "$dest"
}

# copy_settings_file <src> <dest>
# Copy <src> to <dest> so per-machine edits don't propagate back into the repo.
# - Errors if <src> is missing.
# - Refuses to replace a directory at <dest>.
# - If <dest> is a symlink, warns and replaces it with a real copy (no --force
#   needed — symlinks are considered agent-owned upgrade artifacts).
# - If <dest> is a regular file whose content is byte-identical to <src>, the
#   copy is a no-op (idempotent re-run; no --force needed).
# - If <dest> is a regular file whose content differs from <src>, refuses
#   unless FORCE=1 (protects user edits).
# - Uses 'cp -p' to preserve the source's exec bit (matters for
#   statusline-command.sh and friends).
copy_settings_file() {
    local src="$1"
    local dest="$2"
    [[ -e "$src" ]] || { err "settings source not found: $src"; exit 1; }
    if [[ -d "$dest" && ! -L "$dest" ]]; then
        err "refusing to replace directory with file: $dest"
        exit 1
    fi
    mkdir -p "$(dirname "$dest")"
    if [[ -L "$dest" ]]; then
        local link_target
        link_target="$(readlink "$dest")"
        warn "replacing symlink with copy: $dest -> $link_target"
        rm "$dest"
    elif [[ -f "$dest" ]]; then
        if cmp -s "$src" "$dest"; then
            info "copy up-to-date: $dest"
            return 0
        fi
        if [[ "${FORCE:-0}" != "1" ]]; then
            err "refusing to overwrite real file with differing content: $dest"
            err "  local edits differ from repo; re-run with --force to overwrite."
            exit 1
        fi
    fi
    cp -p "$src" "$dest"
    info "copied $src -> $dest"
}

# merge_settings_config <profile> <src> <dest> <groups> [helper-args...]
# Merge only repo-managed keys while preserving unknown/local settings. Managed
# values previously written by this helper update automatically; locally edited
# managed values are preserved unless --force is passed. With --dry-run the
# helper only reports the change (no config or ownership-state write).
merge_settings_config() {
    local profile="$1"
    local src="$2"
    local dest="$3"
    local groups="$4"

    [[ -f "${CONFIG_MERGE_HELPER}" ]] || { err "config merge helper not found: ${CONFIG_MERGE_HELPER}"; exit 1; }
    [[ -r "${CONFIG_MERGE_HELPER}" ]] || { err "config merge helper not readable: ${CONFIG_MERGE_HELPER}"; exit 1; }
    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }

    local -a command=(
        python3 "${CONFIG_MERGE_HELPER}"
        --profile "${profile}"
        --source "${src}"
        --destination "${dest}"
        --groups "${groups}"
        "${@:5}"
    )
    [[ "${FORCE:-0}" == "1" ]] && command+=(--force)
    [[ "${DRY_RUN:-0}" == "1" ]] && command+=(--dry-run)
    "${command[@]}"
}

unlink_owned_link() {
    local src="$1" dest="$2"
    if [[ ! -e "${dest}" && ! -L "${dest}" ]]; then
        info "nothing to remove: ${dest}"
    elif [[ -L "${dest}" && "$(readlink "${dest}")" == "${src}" ]]; then
        rm "${dest}"
        info "removed link ${dest}"
    else
        warn "kept ${dest}: not a link to ${src} (not installed by ycc)"
    fi
}

# remove_copied_file <src> <dest> — remove a file the installer copied.
remove_copied_file() {
    local src="$1" dest="$2"
    if [[ ! -e "${dest}" && ! -L "${dest}" ]]; then
        info "nothing to remove: ${dest}"
        return 0
    fi
    local ours=0
    if [[ -L "${dest}" ]]; then
        # Pre-copy installs symlinked the file instead.
        [[ "$(readlink "${dest}")" == "${src}" ]] && ours=1
    elif [[ -f "${dest}" ]]; then
        if cmp -s "${src}" "${dest}" || [[ "${FORCE}" == "1" ]]; then
            ours=1
        fi
    fi
    if [[ ${ours} -eq 1 ]]; then
        rm "${dest}"
        info "removed ${dest}"
    else
        warn "kept ${dest}: it differs from the repo copy (re-run with --force to remove it)"
    fi
}

# remove_settings <profile> <src> <dest> <groups> [helper-args...] — strip
# managed config keys.
remove_settings() {
    [[ -n "$4" ]] || return 0
    info "Removing managed keys ($4) from $3"
    merge_settings_config "$1" "$2" "$3" "$4" --remove "${@:5}"
}

# plugins_source <target> — echo "<merge profile> <source file>" for the
# settings file that carries <target>'s plugins (and claude's hooks) config
# group (legacy codex layout; the native codex route lists through
# codex_install.py).
plugins_source() {
    case "$1" in
        claude)   echo "claude-settings ${SCRIPT_DIR}/ycc/settings/settings.json" ;;
        codex)    echo "codex-config ${SCRIPT_DIR}/.codex-plugin/config/config.toml" ;;
        opencode) echo "opencode-config ${OPENCODE_PLUGIN_DIR}/opencode.json" ;;
        *) err "plugins_source: unknown target '$1'"; exit 1 ;;
    esac
}

# config_group_selection <target> <groups> — apply every config-group
# selector (select.sh SELECTION_GROUP kinds: --plugins, --hooks) to one
# settings merge. Sets:
#   CONFIG_GROUPS          <groups>, minus each narrowed group <target>
#                          manages none of the selected names for (warns);
#   CONFIG_GROUP_ENTRIES   [<group>]=<csv> of the names kept per narrowed group;
#   CONFIG_SELECT          helper arguments narrowing only those groups (one
#                          --entry-groups g1,g2 --entries <union>; plugin keys
#                          and hook event names never collide), empty when
#                          nothing is narrowed, so the other groups in the
#                          same run always stay whole;
#   PLUGINS_CATALOG_SELECT the selected opt-in catalog plugins of a target
#                          with <t>_catalog_names (opencode), split off the
#                          bundle merge; a selection of catalog names only
#                          drops the bundle 'plugins' group without a warning.
declare -gA CONFIG_GROUP_ENTRIES=()
config_group_selection() {
    local target="$1" kind group selection name
    local -a narrowed=() names=() kept=()
    CONFIG_GROUPS="$2"
    CONFIG_SELECT=()
    CONFIG_GROUP_ENTRIES=()
    PLUGINS_CATALOG_SELECT=""
    for kind in "${SELECTABLE_KINDS[@]}"; do
        group="${SELECTION_GROUP[${kind}]:-}"
        [[ -n "${group}" ]] || continue
        has_selection "${kind}" || continue
        [[ ",${CONFIG_GROUPS}," == *",${group},"* ]] || continue
        selection="$(selection_for_target "${kind}" "${target}")"
        if [[ "${kind}" == plugins && -n "${selection}" ]] && declare -F "${target}_catalog_names" >/dev/null; then
            local -a catalog=() bundle=()
            mapfile -t catalog < <("${target}_catalog_names")
            for name in ${selection//,/ }; do
                if [[ " ${catalog[*]} " == *" ${name} "* ]]; then
                    PLUGINS_CATALOG_SELECT+="${PLUGINS_CATALOG_SELECT:+,}${name}"
                else
                    bundle+=("${name}")
                fi
            done
            selection="$(IFS=','; echo "${bundle[*]:-}")"
        fi
        if [[ -z "${selection}" ]]; then
            [[ "${kind}" == plugins && -n "${PLUGINS_CATALOG_SELECT}" ]] \
                || warn "none of the selected ${SELECTION_NOUNS[${kind}]} ($(selection_for "${kind}" | tr ',' ' ')) is managed for ${target} — skipping its ${group} group"
            kept=()
            for name in ${CONFIG_GROUPS//,/ }; do
                [[ "${name}" == "${group}" ]] || kept+=("${name}")
            done
            CONFIG_GROUPS="$(IFS=','; echo "${kept[*]:-}")"
            continue
        fi
        # shellcheck disable=SC2034  # CONFIG_GROUP_ENTRIES is read by the target libs.
        CONFIG_GROUP_ENTRIES[${group}]="${selection}"
        narrowed+=("${group}")
        names+=("${selection}")
        info "${SELECTION_NOUNS[${kind}]^}: ${selection//,/, }"
    done
    [[ ${#narrowed[@]} -gt 0 ]] || return 0
    local IFS=','
    # shellcheck disable=SC2034  # CONFIG_SELECT is read by the target libs.
    CONFIG_SELECT=(--entry-groups "${narrowed[*]}" --entries "${names[*]}")
}

# ---------------------------------------------------------------------------
# Bundle build (generate -> validate -> format)
# ---------------------------------------------------------------------------
# build_skipped — true when YCC_INSTALL_SKIP_BUILD=1: install the bundles as
# they sit in this checkout instead of regenerating, validating and formatting
# them first. For callers that already ran ./scripts/sync.sh; the install tests
# set it for every case that only asserts where files land.
build_skipped() {
    [[ "${YCC_INSTALL_SKIP_BUILD:-0}" == "1" ]]
}

# run_build_script <script> — run one bundle generator or validator.
run_build_script() {
    if build_skipped; then
        info "Skipping $(basename "$1") (YCC_INSTALL_SKIP_BUILD=1)"
        return 0
    fi
    info "Running $(basename "$1")"
    bash "$1"
}

# ---------------------------------------------------------------------------
# Repo formatting (modified files via scripts/style.sh)
# Only stacks present in this repo: Markdown/JSON (prettier) and Python (black).
# style.sh format has no shell formatter; Rust/TS/Go are omitted to avoid requiring
# those toolchains or failing on unrelated stacks.
# ---------------------------------------------------------------------------
run_repo_style_format_modified() {
    if build_skipped; then
        info "Skipping repository formatting (YCC_INSTALL_SKIP_BUILD=1)"
        return 0
    fi

    local style_sh="${SCRIPT_DIR}/scripts/style.sh"

    if [[ ! -f "${style_sh}" ]]; then
        err "style script not found: ${style_sh}"
        exit 1
    fi
    if [[ ! -r "${style_sh}" ]]; then
        err "style script not readable: ${style_sh}"
        exit 1
    fi
    if [[ ! -x "${style_sh}" ]]; then
        err "style script not executable: ${style_sh}"
        exit 1
    fi

    info "Running scripts/style.sh format --modified --docs --python"
    PROJECT_ROOT="${SCRIPT_DIR}" bash "${style_sh}" format --modified --docs --python

    info "Running scripts/style.sh lint --modified --fix --python --shell"
    PROJECT_ROOT="${SCRIPT_DIR}" bash "${style_sh}" lint --modified --fix --python --shell
}

# ---------------------------------------------------------------------------
# Scope (--project / --global)
# ---------------------------------------------------------------------------
# config. Without an explicit flag, these default to project scope and every
# other step stays global. Package installs keep Claude hooks global alongside
# their package-wide settings and rules.
# ponytail: widen this per step as project support lands for settings, rules.
step_supports_project() {
    [[ "$2" == "mcp" ]] || [[ "$1" == "claude" && "$2" == "hooks" && -z "${PACKAGE:-}" ]]
}

# step_allows_project <target> <step> — true when an explicit --project is
# valid for <step>: the default-to-project steps above, plus any step the
# target lists in its optional <t>_project_steps (opt-in only, never default).
step_allows_project() {
    step_supports_project "$1" "$2" && return 0
    declare -F "${1}_project_steps" >/dev/null || return 1
    [[ ",$("${1}_project_steps")," == *",$2,"* ]]
}

# step_scope <target> <step> — echo 'project' or 'global'.
step_scope() {
    if [[ -n "${SCOPE}" ]]; then
        echo "${SCOPE}"
    elif step_supports_project "$1" "$2"; then
        echo "project"
    else
        echo "global"
    fi
}

# project_root — git toplevel of $PWD, else $PWD itself.
project_root() {
    git rev-parse --show-toplevel 2>/dev/null || pwd
}

# ---------------------------------------------------------------------------
# MCP step (every target, project or global scope, merge or remove)
# ---------------------------------------------------------------------------
# The shared merge helper gives every MCP file the same ownership tracking,
# local-edit protection and atomic writes; state is keyed per destination, so
# project and global copies never interfere.
#
#   target    project                          global
#   claude    <project>/.mcp.json              ~/.claude.json
#   cursor    <project>/.cursor/mcp.json       ~/.cursor/mcp.json
#   codex     <project>/.codex/config.toml     ~/.codex/config.toml
#   opencode  <project>/opencode.json          ~/.config/opencode/opencode.json
mcp_destination() {
    local target="$1"
    if [[ "$(step_scope "${target}" mcp)" == "project" ]]; then
        local root
        root="$(project_root)"
        case "${target}" in
            claude)   echo "${root}/.mcp.json" ;;
            cursor)   echo "${root}/.cursor/mcp.json" ;;
            codex)    echo "${root}/.codex/config.toml" ;;
            opencode) echo "${root}/opencode.json" ;;
        esac
    else
        case "${target}" in
            claude)   echo "${HOME}/.claude.json" ;;
            cursor)   echo "${HOME}/.cursor/mcp.json" ;;
            codex)    echo "${HOME}/.codex/config.toml" ;;
            opencode) echo "${HOME}/.config/opencode/opencode.json" ;;
        esac
    fi
}

# mcp_source <target> — echo "<merge profile> <source file>" for <target>'s MCP step.
mcp_source() {
    case "$1" in
        claude)   echo "claude-mcp ${MCP_CONFIG_SRC}" ;;
        cursor)   echo "cursor-mcp ${MCP_CONFIG_SRC}" ;;
        codex)    echo "codex-config ${SCRIPT_DIR}/.codex-plugin/config/mcp-servers.json" ;;
        opencode) echo "opencode-config ${OPENCODE_PLUGIN_DIR}/opencode.json" ;;
        *) err "mcp_source: unknown target '$1'"; exit 1 ;;
    esac
}

# run_mcp_step <target> — merge (or, for 'remove', strip) managed MCP servers;
# with --mcps, only the selected servers (others are left untouched).
run_mcp_step() {
    local target="$1" profile src dest
    read -r profile src <<< "$(mcp_source "${target}")"
    dest="$(mcp_destination "${target}")"

    local -a select=()
    if has_selection mcps; then
        local selection
        selection="$(selection_for_target mcps "${target}")"
        if [[ -z "${selection}" ]]; then
            selection="$(selection_for mcps)"
            warn "none of the selected MCP servers (${selection//,/ }) is managed for ${target} — skipping"
            return 0
        fi
        select=(--entries "${selection}")
        info "MCP servers: ${selection//,/, }"
    fi

    if [[ "${COMMAND}" == "remove" ]]; then
        info "Removing managed MCP servers from ${dest}"
        merge_settings_config "${profile}" "${src}" "${dest}" "mcp" --remove "${select[@]}"
        return 0
    fi
    info "Merging MCP servers into ${dest}"
    merge_settings_config "${profile}" "${src}" "${dest}" "mcp" "${select[@]}"
    if [[ "${target}" == "codex" && "${dest}" != "${HOME}/.codex/config.toml" ]]; then
        warn "Codex loads ${dest} only when the project is trusted in ~/.codex/config.toml."
    fi
}
