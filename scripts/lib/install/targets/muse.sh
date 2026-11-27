# shellcheck shell=bash
# muse.sh — the Muse Code target (Meta's `muse` terminal coding agent):
# implements the per-target contract that install.sh dispatches through (see
# scripts/lib/install/steps.sh):
#   muse_valid_steps, muse_intent_steps <intent>, muse_config_groups,
#   muse_supports_repo_mode, sync_muse_target, remove_muse_target
# plus the optional hooks the generic shell calls when they exist:
#   muse_dry_run_steps, muse_in_all, muse_all_skip_reason, muse_repo_mode_hint
#
# Sourced by install.sh (never run directly); inherits SCRIPT_DIR and the
# shared helpers from core.sh / steps.sh.
#
# The generated plugins under packages/muse/ (ycc, ycc-mcp, ycc-rules) are copied to the
# ycc-owned folder ~/.local/share/ycc/muse/ and registered from there with
# 'muse plugins install <copy> --scope user', then approved so the ycc agents
# and MCP servers leave Muse's review queue. scripts/muse_install.py owns every
# muse call, the ownership record and the dry-run previews. The opt-in 'rules'
# step links the shared ycc AGENTS.md to Muse's user rules file
# ($XDG_CONFIG_HOME/muse/AGENTS.md). With --project, base registers the plugins
# at Muse's project scope ('--scope project'); the owned copies (which the
# skills' helper paths name) stay in the user's data folder either way.

MUSE_INSTALL_HELPER="${SCRIPT_DIR}/scripts/muse_install.py"
MUSE_RULES_SRC="${SCRIPT_DIR}/ycc/settings/rules/AGENTS.md"

# muse_project_steps — steps that honour --project. rules stays user scope:
# project rules are the repository's own AGENTS.md, which ycc never writes.
muse_project_steps() { echo "base"; }

# muse_valid_steps — comma-separated steps muse accepts for --only.
muse_valid_steps() { echo "base,rules"; }

# muse_dry_run_steps — both steps preview themselves under --dry-run.
muse_dry_run_steps() { muse_valid_steps; }

# muse_intent_steps <intent> — steps <intent> maps to; empty means no-op.
muse_intent_steps() {
    case "$1" in
        # The ycc, ycc-mcp and ycc-rules plugins carry skills, commands, agents,
        # MCP servers and rules;
        # registering them is the install itself.
        base|skills|agents|commands|mcp|plugins) echo "base" ;;
        rules) echo "rules" ;;
        *) echo "" ;;
    esac
}

# muse_config_groups — no managed config file: Muse's settings.json carries no
# ycc-managed keys (MCP servers ship in the ycc-mcp plugin), and hooks are
# Claude-specific (Muse has no WorktreeCreate event).
muse_config_groups() { echo ""; }

# muse_supports_repo_mode — the only marketplace file Muse reads at a repo root
# is .agents/plugins/marketplace.json, which this repository owns for Codex.
muse_supports_repo_mode() { return 1; }
muse_repo_mode_hint() { echo "muse installs the local packages/muse plugins (the repo's .agents/plugins catalog belongs to Codex)"; }

# muse_config_dir — Muse's config root (holds settings.json and AGENTS.md).
muse_config_dir() { echo "${YCC_MUSE_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/muse}"; }

muse_bin() { echo "${YCC_MUSE_BIN:-muse}"; }

# muse_in_all — 'all' includes muse only where it is installed.
muse_in_all() { command -v "$(muse_bin)" >/dev/null 2>&1; }
muse_all_skip_reason() { echo "needs muse on PATH"; }

# run_muse_install <install|remove> — dispatch to the helper with the run's
# package selection and dry-run/force flags.
run_muse_install() {
    local -a command=(python3 "${MUSE_INSTALL_HELPER}" "$1")
    [[ -n "${PACKAGE:-}" ]] && command+=(--packages "${PACKAGE}")
    [[ "${FORCE:-0}" == "1" ]] && command+=(--force)
    [[ "${DRY_RUN:-0}" == "1" ]] && command+=(--dry-run)
    [[ "$1" == "install" && "${SCOPE:-}" == "project" ]] && command+=(--scope project)
    "${command[@]}"
}

muse_rules_dest() { echo "$(muse_config_dir)/AGENTS.md"; }

muse_rules_step() {
    local dest
    dest="$(muse_rules_dest)"
    printf '\n%sMuse: link rules (AGENTS.md) into %s%s\n' "${BOLD}" "$(muse_config_dir)" "${NC}"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        info "[dry-run] would link ${dest} -> ${MUSE_RULES_SRC}"
        return 0
    fi
    mkdir -p "$(muse_config_dir)"
    link_rules_file "${MUSE_RULES_SRC}" "${dest}"
}

# ---------------------------------------------------------------------------
# Muse sync (base: the native plugins; rules: the AGENTS.md link)
# ---------------------------------------------------------------------------
sync_muse_target() {
    validate_only_steps "muse"
    local ran=0
    if step_enabled base; then
        command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
        printf '\n%sMuse: install the ycc plugins%s\n' "${BOLD}" "${NC}"
        run_muse_install install || {
            err "Muse plugin install failed (see above)"
            exit 1
        }
        ran=1
    fi
    if step_enabled rules; then
        muse_rules_step
        ran=1
    fi
    [[ ${ran} -eq 1 ]] || warn "muse target ran no steps"
    printf '\n%sMuse %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
}

# ---------------------------------------------------------------------------
# Muse remove (base: ycc-owned plugins only; rules: our link only)
# ---------------------------------------------------------------------------
remove_muse_target() {
    validate_only_steps "muse"
    local ran=0
    if step_enabled base; then
        command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
        printf '\n%sMuse: remove the ycc plugins%s\n' "${BOLD}" "${NC}"
        run_muse_install remove || {
            err "Muse plugin removal failed (see above)"
            exit 1
        }
        ran=1
    fi
    if step_enabled rules; then
        local dest
        dest="$(muse_rules_dest)"
        printf '\n%sMuse: unlink rules (AGENTS.md)%s\n' "${BOLD}" "${NC}"
        if [[ "${DRY_RUN:-0}" == "1" ]]; then
            info "[dry-run] would unlink ${dest} if it links to ${MUSE_RULES_SRC}"
        else
            unlink_owned_link "${MUSE_RULES_SRC}" "${dest}"
        fi
        ran=1
    fi
    [[ ${ran} -eq 1 ]] || warn "muse target ran no steps"
    printf '\n%sMuse remove complete.%s\n' "${BOLD}" "${NC}"
}
