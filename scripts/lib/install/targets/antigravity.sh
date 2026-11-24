# shellcheck shell=bash
# antigravity.sh — the Google Antigravity target (App, IDE and the agy CLI):
# implements the per-target contract that install.sh dispatches through (see
# scripts/lib/install/steps.sh):
#   antigravity_valid_steps, antigravity_intent_steps <intent>,
#   antigravity_config_groups, antigravity_supports_repo_mode,
#   sync_antigravity_target, remove_antigravity_target
# plus the optional hooks the generic shell calls when they exist:
#   antigravity_dry_run_steps, antigravity_in_all, antigravity_all_skip_reason,
#   antigravity_repo_mode_hint
#
# Sourced by install.sh (never run directly); inherits SCRIPT_DIR and the
# shared helpers from core.sh / steps.sh.
#
# The generated plugins under packages/antigravity/ (ycc, ycc-mcp, ycc-rules)
# land in ~/.gemini/config/plugins/, the global folder the App, IDE and CLI all
# read. scripts/antigravity_install.py owns every agy call, the ownership record
# and the dry-run previews: with agy on PATH it runs 'agy plugin install <path>'
# / 'agy plugin uninstall <name>', else it places an owned copy. The opt-in
# 'rules' step links the shared ycc AGENTS.md to ~/.gemini/config/AGENTS.md.
# Skills reach their helpers by absolute global paths, so there is no project
# scope (no antigravity_project_steps): --project is rejected by preflight.

ANTIGRAVITY_INSTALL_HELPER="${SCRIPT_DIR}/scripts/antigravity_install.py"
ANTIGRAVITY_RULES_SRC="${SCRIPT_DIR}/ycc/settings/rules/AGENTS.md"

# antigravity_valid_steps — comma-separated steps antigravity accepts for --only.
antigravity_valid_steps() { echo "base,rules"; }

# antigravity_dry_run_steps — both steps preview themselves under --dry-run.
antigravity_dry_run_steps() { antigravity_valid_steps; }

# antigravity_intent_steps <intent> — steps <intent> maps to; empty means no-op.
antigravity_intent_steps() {
    case "$1" in
        # The ycc, ycc-mcp and ycc-rules plugins carry skills, agents, MCP
        # servers and language rules; enabling them is the install itself.
        base|skills|agents|commands|mcp|plugins) echo "base" ;;
        rules) echo "rules" ;;
        *) echo "" ;;
    esac
}

# antigravity_config_groups — no managed config file: settings.json carries no
# ycc-managed keys, and hooks are Claude-specific.
antigravity_config_groups() { echo ""; }

# antigravity_supports_repo_mode — Antigravity documents no subdirectory
# install from a GitHub repository and publishes no marketplace format.
antigravity_supports_repo_mode() { return 1; }
antigravity_repo_mode_hint() { echo "antigravity installs the local packages/antigravity plugins (no published marketplace format)"; }

# antigravity_config_dir — the global folder shared by the App, IDE and CLI.
antigravity_config_dir() { echo "${YCC_ANTIGRAVITY_CONFIG_DIR:-${HOME}/.gemini/config}"; }

# antigravity_in_all — 'all' includes antigravity only where it is installed:
# agy on PATH, or an existing Antigravity config folder.
antigravity_in_all() {
    command -v agy >/dev/null 2>&1 || [[ -d "$(antigravity_config_dir)" ]]
}
antigravity_all_skip_reason() { echo "needs agy on PATH or an existing $(antigravity_config_dir)"; }

# run_antigravity_install <install|remove> — dispatch to the helper with the
# run's package selection and dry-run/force flags.
run_antigravity_install() {
    local -a command=(python3 "${ANTIGRAVITY_INSTALL_HELPER}" "$1")
    [[ -n "${PACKAGE:-}" ]] && command+=(--packages "${PACKAGE}")
    [[ "${FORCE:-0}" == "1" ]] && command+=(--force)
    [[ "${DRY_RUN:-0}" == "1" ]] && command+=(--dry-run)
    "${command[@]}"
}

antigravity_rules_dest() { echo "$(antigravity_config_dir)/AGENTS.md"; }

antigravity_rules_step() {
    local dest
    dest="$(antigravity_rules_dest)"
    printf '\n%sAntigravity: link rules (AGENTS.md) into %s%s\n' "${BOLD}" "$(antigravity_config_dir)" "${NC}"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        info "[dry-run] would link ${dest} -> ${ANTIGRAVITY_RULES_SRC}"
        return 0
    fi
    mkdir -p "$(antigravity_config_dir)"
    link_rules_file "${ANTIGRAVITY_RULES_SRC}" "${dest}"
}

# ---------------------------------------------------------------------------
# Antigravity sync (base: the native plugins; rules: the AGENTS.md link)
# ---------------------------------------------------------------------------
sync_antigravity_target() {
    validate_only_steps "antigravity"
    local ran=0
    if step_enabled base; then
        command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
        printf '\n%sAntigravity: install the ycc plugins%s\n' "${BOLD}" "${NC}"
        run_antigravity_install install || {
            err "Antigravity plugin install failed (see above)"
            exit 1
        }
        ran=1
    fi
    if step_enabled rules; then
        antigravity_rules_step
        ran=1
    fi
    [[ ${ran} -eq 1 ]] || warn "antigravity target ran no steps"
    printf '\n%sAntigravity %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
}

# ---------------------------------------------------------------------------
# Antigravity remove (base: ycc-owned plugins only; rules: our link only)
# ---------------------------------------------------------------------------
remove_antigravity_target() {
    validate_only_steps "antigravity"
    local ran=0
    if step_enabled base; then
        command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
        printf '\n%sAntigravity: remove the ycc plugins%s\n' "${BOLD}" "${NC}"
        run_antigravity_install remove || {
            err "Antigravity plugin removal failed (see above)"
            exit 1
        }
        ran=1
    fi
    if step_enabled rules; then
        local dest
        dest="$(antigravity_rules_dest)"
        printf '\n%sAntigravity: unlink rules (AGENTS.md)%s\n' "${BOLD}" "${NC}"
        if [[ "${DRY_RUN:-0}" == "1" ]]; then
            info "[dry-run] would unlink ${dest} if it links to ${ANTIGRAVITY_RULES_SRC}"
        else
            unlink_owned_link "${ANTIGRAVITY_RULES_SRC}" "${dest}"
        fi
        ran=1
    fi
    [[ ${ran} -eq 1 ]] || warn "antigravity target ran no steps"
    printf '\n%sAntigravity remove complete.%s\n' "${BOLD}" "${NC}"
}
