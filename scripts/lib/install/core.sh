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

# dry_run_note <verb> <dest> [src] — true when the mutation was previewed.
dry_run_note() {
    [[ "${DRY_RUN:-0}" == "1" ]] || return 1
    info "[dry-run] would $1 $2${3:+ -> $3}"
}

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
    if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
        info "link up-to-date: $dest -> $src"
        return 0
    fi
    dry_run_note link "${dest}" "${src}" && return 0
    mkdir -p "$(dirname "$dest")"
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
    if [[ -L "$dest" ]]; then
        local link_target
        link_target="$(readlink "$dest")"
        warn "replacing symlink with copy: $dest -> $link_target"
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
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        info "[dry-run] would copy ${src} -> ${dest}"
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    [[ ! -L "${dest}" ]] || rm "${dest}"
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
    # At project scope the destination is usually committed and written by the
    # team, so a value matching the repo proves nothing: remove (and adoption
    # on sync) must touch only keys the state records as ycc-written.
    if [[ ",${groups}," == *",settings-project,"* && " $* " != *" --owned-only "* ]]; then
        command+=(--owned-only)
    fi
    "${command[@]}"
}

unlink_owned_link() {
    local src="$1" dest="$2"
    if [[ ! -e "${dest}" && ! -L "${dest}" ]]; then
        info "nothing to remove: ${dest}"
    elif [[ -L "${dest}" && "$(readlink "${dest}")" == "${src}" ]]; then
        dry_run_note unlink "${dest}" "${src}" && return 0
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
        dry_run_note remove "${dest}" && return 0
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
# settings merge, then map the result onto the settings scope. Sets:
#   CONFIG_GROUPS          <groups>, minus each narrowed group <target>
#                          manages none of the selected names for (warns) and
#                          minus each group the project scope never merges;
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
# At project scope (no --package) the remaining groups must be listed by the
# target's <t>_project_groups hook: any other group is global-only, so it is
# dropped with a notice ('--project' + an explicitly requested group was
# already rejected by preflight_step_support), and each kept base group g
# merges the helper's fail-closed g-project allowlist group instead (the
# catalog plugins stay project-capable as PLUGINS_CATALOG_SELECT). Remove
# paths use this too, so remove at project scope only touches
# project-allowed leaves.
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
        if [[ -z "${PACKAGE:-}" && "$(step_scope "${target}" settings)" == project \
            && ",$(target_project_groups "${target}")," != *",${group},"* ]]; then
            if [[ -n "${selection}" ]]; then
                warn "${target}: the ${group} group is global-only — skipped at project scope. Pass --global to merge it."
            fi
            kept=()
            for name in ${CONFIG_GROUPS//,/ }; do
                [[ "${name}" == "${group}" ]] || kept+=("${name}")
            done
            CONFIG_GROUPS="$(IFS=','; echo "${kept[*]:-}")"
            continue
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
    if [[ ${#narrowed[@]} -gt 0 ]]; then
        local IFS=','
        # shellcheck disable=SC2034  # CONFIG_SELECT is read by the target libs.
        CONFIG_SELECT=(--entry-groups "${narrowed[*]}" --entries "${names[*]}")
    fi

    # Project scope: drop every group the target's project allowlist does not
    # cover, then merge each kept base group through its g-project subset.
    if [[ -z "${PACKAGE:-}" && "$(step_scope "${target}" settings)" == "project" ]]; then
        local allowed
        allowed="$(target_project_groups "${target}")"
        kept=()
        for group in ${CONFIG_GROUPS//,/ }; do
            [[ -n "${group}" ]] || continue
            if [[ ",${allowed}," == *",${group},"* ]]; then
                kept+=("${group}")
                continue
            fi
            local message="${target}: the ${group} group is global-only — skipped at project scope. Pass --global to merge it."
            # A catalog-only plugins selection drops the bundle group quietly
            # already (the catalog names ride PLUGINS_CATALOG_SELECT).
            if [[ "${group}" == plugins && -n "${PLUGINS_CATALOG_SELECT}" ]]; then
                continue
            elif [[ "${SCOPE}" == "project" ]] || intent_requested "${group}"; then
                warn "${message}"
            else
                info "${message}"
            fi
        done
        CONFIG_GROUPS="$(IFS=','; echo "${kept[*]:-}")"
        CONFIG_GROUPS="${CONFIG_GROUPS%,}"
        if [[ -n "${CONFIG_GROUPS}" ]]; then
            # Merge each kept base group through its fail-closed g-project
            # subset (merge_managed_config.py's settings-project group).
            local -a projected=()
            for group in ${CONFIG_GROUPS//,/ }; do
                projected+=("${group}-project")
            done
            CONFIG_GROUPS="$(IFS=','; echo "${projected[*]}")"
        fi
    fi
}
# project_home_conflict — echo why project scope cannot run when the project
# root IS $HOME (physical paths compared). Empty output means no conflict;
# the settings skip and the explicit --project gate read it. Kept generic:
# <context> (e.g. 'claude project scope', 'settings project scope') names the
# caller in the message.
project_home_conflict() {
    local root home
    root="$(cd "$(project_root)" && pwd -P)"
    home="$(cd "${HOME}" && pwd -P)"
    if [[ "${root}" == "${home}" ]]; then
        # shellcheck disable=SC2016  # Explain the literal HOME boundary.
        echo "--project at \$HOME: $1 needs a project directory (cd into a project, or use --global)"
    fi
}

# settings_legacy_hint <target> <profile> <global dest> — once per target per
# run, when the settings scope was defaulted (no --project/--global, no
# --package) and the GLOBAL destination still holds ycc-managed keys from an
# earlier global sync, note that settings now default to the project so the
# user knows to pass --global to update or remove them.
declare -gA SETTINGS_LEGACY_HINT_SHOWN=()
settings_legacy_hint() {
    [[ -z "${SCOPE}" && -z "${PACKAGE:-}" ]] || return 0
    [[ "$(step_scope "$1" settings)" == "project" ]] || return 0
    [[ -z "${SETTINGS_LEGACY_HINT_SHOWN[$1]:-}" ]] || return 0
    [[ -f "${CONFIG_MERGE_HELPER}" && -r "${CONFIG_MERGE_HELPER}" ]] || return 0
    # Only SETTINGS state counts: an earlier mcp/plugins/hooks global sync
    # records state in the same file but says nothing about settings.
    if python3 "${CONFIG_MERGE_HELPER}" --profile "$2" --destination "$3" --has-state --groups settings; then
        warn "$1: settings now default to project scope; $3 still holds ycc-managed keys from earlier syncs — pass --global to update or remove them."
        SETTINGS_LEGACY_HINT_SHOWN[$1]=1
    fi
}

# codex_trust_warn <dest> — the Codex project-config trust warning, once per
# run (a run with both the mcp and settings steps warns once). Trust lives in
# ~/.codex/config.toml and is a user decision; ycc never writes it.
CODEX_TRUST_WARNED=0
codex_trust_warn() {
    [[ "${CODEX_TRUST_WARNED}" == "0" ]] || return 0
    CODEX_TRUST_WARNED=1
    warn "Codex loads $1 only when the project is trusted in ~/.codex/config.toml."
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
# Without an explicit flag, these steps default to project scope and every
# other step stays global: 'mcp' everywhere; 'hooks' for claude; 'settings'
# for every target that declares <t>_project_groups (claude, codex, opencode).
# Package installs keep Claude hooks global alongside their package-wide
# settings and rules. Targets without <t>_project_groups (cursor, omp) skip
# their settings step at the default scope with a notice (steps.sh).
#
# target_project_groups <target> — csv of the settings-file config groups
# mergeable at project scope ('' when the target has none). Defining the
# optional <t>_project_groups hook is what makes 'settings' default to
# project scope for <target>; a listed group g merges the helper's g-project
# allowlist group (fail-closed: only the allowlisted rules leave the global
# group), so the plugins/hooks groups stay global-only here.
target_project_groups() {
    declare -F "${1}_project_groups" >/dev/null || return 0
    "${1}_project_groups"
}

step_supports_project() {
    case "$2" in
        mcp) return 0 ;;
        hooks) [[ "$1" == claude && -z "${PACKAGE:-}" ]] ;;
        settings) [[ -z "${PACKAGE:-}" && -n "$(target_project_groups "$1")" ]] ;;
        *) return 1 ;;
    esac
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

    # shellcheck disable=SC2153  # COMMAND is install.sh's subcommand global.
    if [[ "${COMMAND}" == "remove" ]]; then
        info "Removing managed MCP servers from ${dest}"
        merge_settings_config "${profile}" "${src}" "${dest}" "mcp" --remove "${select[@]}"
        return 0
    fi
    info "Merging MCP servers into ${dest}"
    merge_settings_config "${profile}" "${src}" "${dest}" "mcp" "${select[@]}"
    if [[ "${target}" == "codex" && "${dest}" != "${HOME}/.codex/config.toml" ]]; then
        codex_trust_warn "${dest}"
    fi
}
