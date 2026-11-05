# shellcheck shell=bash
# codex.sh — the Codex target: implements the per-target contract that install.sh
# dispatches through (see scripts/lib/install/steps.sh):
#   codex_valid_steps, codex_intent_steps <intent>, codex_config_groups,
#   codex_supports_repo_mode, codex_reads_agents_skills, sync_codex_target, remove_codex_target
# plus the optional project-scope hooks: codex_project_groups (settings),
# codex_settings_global_dest, codex_config_file.
#
# Sourced by install.sh (never run directly); inherits SCRIPT_DIR and the
# shared helpers from core.sh / steps.sh / bundle.sh.
#
# ycc ships to Codex only as native packages: 'base' registers marketplace ycc
# and runs 'codex plugin add ycc@ycc' + 'ycc-mcp@ycc'; 'mcp' adds ycc-mcp@ycc
# alone. scripts/codex_install.py owns every codex plugin call and the
# ownership record. Custom agents (~/.codex/agents), config.toml settings and
# the rules links have no native carrier and stay installer-managed.

CODEX_AGENTS_DIR="${SCRIPT_DIR}/.codex-plugin/agents"

# codex_valid_steps — comma-separated steps Codex accepts for --only.
codex_valid_steps() { echo "base,agents,settings,rules,mcp"; }

# codex_dry_run_steps — native installs need the Codex CLI, so only their
# removal can be previewed.
codex_dry_run_steps() {
    if [[ "${COMMAND:-}" == remove ]]; then
        echo "base,agents,settings,rules,mcp"
    else
        echo "settings,rules"
    fi
}

# codex_intent_steps <intent> — steps <intent> maps to; empty means no-op.
codex_intent_steps() {
    case "$1" in
        # Skills ship only inside the native ycc plugin.
        base|skills) echo "base" ;;
        # Custom agents have no native carrier: ~/.codex/agents.
        agents) echo "agents" ;;
        settings|rules|mcp) echo "$1" ;;
        # Plugin enablement lives in config.toml.
        plugins) echo "settings" ;;
        # Codex has no command layer, mods are Claude-only, hooks are excluded.
        *) echo "" ;;
    esac
}

# codex_config_groups — default managed config groups for config.toml.
codex_config_groups() { echo "settings,plugins"; }

# codex_project_groups — settings-file config groups mergeable at project
# scope (<project>/.codex/config.toml): 'settings' only, through the helper's
# settings-project allowlist (no approval/sandbox posture keys, no provider/
# profile/notify/otel keys Codex ignores at project level). plugins stays
# global-only.
codex_project_groups() { echo "settings"; }

# codex_settings_global_dest — the user-scope config file (legacy-hint target).
codex_settings_global_dest() { echo "${HOME}/.codex/config.toml"; }

# codex_config_file — the config.toml destination for the current scope:
# project <root>/.codex/config.toml (loaded only for trusted projects; the
# sync path prints the trust warning), global ~/.codex/config.toml.
codex_config_file() {
    if [[ "$(step_scope codex settings)" == "project" ]]; then
        echo "$(project_root)/.codex/config.toml"
    else
        echo "${HOME}/.codex/config.toml"
    fi
}

codex_supports_repo_mode() { return 0; }

# Codex skills come only from the native ycc@ycc plugin; nothing to consolidate.
codex_reads_agents_skills() { return 1; }

# ---------------------------------------------------------------------------
# Codex plugin CLI (Codex >= 0.160 ships 'codex plugin')
# ---------------------------------------------------------------------------

# codex_plugin_cli_supported — true when the codex CLI has 'plugin add'.
codex_plugin_cli_supported() {
    command -v codex >/dev/null 2>&1 && codex plugin add --help >/dev/null 2>&1
}

# codex_require_cli — fail clearly when the native route cannot run.
codex_require_cli() {
    codex_plugin_cli_supported && return 0
    err "Codex installs ycc as native plugins, which needs the Codex CLI with 'codex plugin' (Codex >= 0.160)."
    err "  install or upgrade Codex (https://developers.openai.com/codex), then rerun this command."
    exit 1
}

# codex_native_settings [--remove] — merge (or strip) the native config.toml
# groups in CONFIG_GROUPS through codex_install.py; the --plugins names kept
# for the plugins group (CONFIG_GROUP_ENTRIES[plugins], set by
# config_group_selection) pass on as --entries (codex_install.py scopes them
# to the plugins group itself and takes plugin keys only).
codex_native_settings() {
    local -a command=(python3 "${SCRIPT_DIR}/scripts/codex_install.py" settings --groups "${CONFIG_GROUPS}" "$@")
    [[ -n "${CONFIG_GROUP_ENTRIES[plugins]:-}" ]] && command+=(--entries "${CONFIG_GROUP_ENTRIES[plugins]}")
    [[ "${FORCE:-0}" == 1 ]] && command+=(--force)
    [[ "${DRY_RUN:-0}" == 1 ]] && command+=(--dry-run)
    "${command[@]}"
}

# codex_native_packages <install|remove> <packages csv> — run codex_install.py
# for the native packages (install registers marketplace ycc first).
codex_native_packages() {
    local -a command=(python3 "${SCRIPT_DIR}/scripts/codex_install.py" "$1" --packages "$2")
    [[ "$1" == install ]] && command+=(--mode "${MODE:-local}")
    [[ "${DRY_RUN:-0}" == 1 ]] && command+=(--dry-run)
    "${command[@]}"
}

# ---------------------------------------------------------------------------
# Codex sync
# ---------------------------------------------------------------------------
sync_codex_target() {
    validate_only_steps "codex"

    local scripts_dir="${SCRIPT_DIR}/scripts"
    local do_base=0 do_agents=0 do_settings=0 do_rules=0 do_mcp=0
    step_enabled base && do_base=1
    # Local base also mirrors the custom agents (repo mode installs only the
    # GitHub-hosted packages); the agents step mirrors them on its own.
    if step_enabled agents || [[ $do_base -eq 1 && "${MODE:-local}" == "local" ]]; then
        do_agents=1
    fi
    step_enabled settings && do_settings=1
    step_enabled rules && do_rules=1
    # base already installs ycc-mcp@ycc alongside ycc@ycc.
    step_enabled mcp && [[ $do_base -eq 0 ]] && do_mcp=1

    if [[ $do_base -eq 0 && $do_agents -eq 0 && $do_settings -eq 0 && $do_rules -eq 0 && $do_mcp -eq 0 ]]; then
        warn "Codex target ran no steps"
        printf '\n%sCodex %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
        return 0
    fi

    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    [[ $do_base -eq 1 || $do_mcp -eq 1 ]] && codex_require_cli

    # Generator/validator passes (generate-codex-<pass>.sh) for what this run
    # installs from the checkout: repo mode fetches the packages from GitHub.
    local -a passes=()
    if [[ "${MODE:-local}" == "local" ]]; then
        [[ $do_base -eq 1 ]] && passes+=(skills)
        [[ $do_agents -eq 1 ]] && passes+=(agents)
        [[ $do_base -eq 1 || $do_mcp -eq 1 ]] && passes+=(plugin)
    elif [[ $do_agents -eq 1 ]]; then
        passes+=(agents)
    fi

    local total=0
    [[ ${#passes[@]} -gt 0 ]] && total=$((total + 3))
    [[ $do_agents -eq 1 ]] && total=$((total + 1))
    [[ $do_base -eq 1 ]] && total=$((total + 1))
    [[ $do_mcp -eq 1 ]] && total=$((total + 1))
    [[ $do_settings -eq 1 ]] && total=$((total + 1))
    [[ $do_rules -eq 1 ]] && total=$((total + 1))
    local step=0

    if [[ ${#passes[@]} -gt 0 ]]; then
        if [[ ! -d "${SCRIPT_DIR}/.codex-plugin" ]]; then
            err "Codex plugin source directory not found: ${SCRIPT_DIR}/.codex-plugin"
            exit 1
        fi
        local pass
        for pass in "${passes[@]}"; do
            require_scripts "${scripts_dir}/generate-codex-${pass}.sh" "${scripts_dir}/validate-codex-${pass}.sh"
        done

        step=$((step + 1))
        printf '\n%s[%d/%d] Generate Codex-native bundle (%s)%s\n' "${BOLD}" "$step" "$total" "${passes[*]}" "${NC}"
        for pass in "${passes[@]}"; do
            run_build_script "${scripts_dir}/generate-codex-${pass}.sh"
        done

        step=$((step + 1))
        printf '\n%s[%d/%d] Validate generated bundle%s\n' "${BOLD}" "$step" "$total" "${NC}"
        for pass in "${passes[@]}"; do
            run_build_script "${scripts_dir}/validate-codex-${pass}.sh"
        done

        step=$((step + 1))
        printf '\n%s[%d/%d] Format modified repository files%s\n' "${BOLD}" "$step" "$total" "${NC}"
        run_repo_style_format_modified
    fi

    if [[ $do_agents -eq 1 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] Sync custom agents%s\n' "${BOLD}" "$step" "$total" "${NC}"
        if [[ ! -d "${CODEX_AGENTS_DIR}" ]]; then
            err "Codex agent source directory not found: ${CODEX_AGENTS_DIR}"
            exit 1
        fi
        # Ownership-tracked: only ycc's agents are replaced or retired; the
        # user's own agents are never touched.
        run_slice codex agents
    fi

    if [[ $do_base -eq 1 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] Install native Codex packages (ycc + ycc-mcp)%s\n' "${BOLD}" "$step" "$total" "${NC}"
        codex_native_packages install ycc,ycc-mcp
        # The packages are installed: a refused cleanup leaves only legacy leftovers behind.
        run_legacy_cleanup codex || warn "legacy cleanup skipped: legacy ycc@local-ycc-plugins files were retained (see the message above); rerun this base step to retry"
    fi

    if [[ $do_mcp -eq 1 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] Install native Codex MCP package (ycc-mcp)%s\n' "${BOLD}" "$step" "$total" "${NC}"
        codex_native_packages install ycc-mcp
        run_legacy_cleanup codex || warn "legacy cleanup skipped: the legacy Codex [mcp_servers] tables were retained (see the message above); rerun this step to retry"
    fi

    if [[ $do_settings -eq 1 ]]; then
        step=$((step + 1))
        local codex_config_dest
        codex_config_dest="$(codex_config_file)"
        printf '\n%s[%d/%d] Merge Codex config (%s)%s\n' "${BOLD}" "$step" "$total" "${codex_config_dest}" "${NC}"
        # Merge managed keys only: trusted-project entries, MCP tokens,
        # connector IDs and comments in the user's config.toml are preserved.
        config_group_selection codex "$(config_groups_for_target codex)"
        if [[ -n "${CONFIG_GROUPS}" ]]; then
            if [[ "$(step_scope codex settings)" == "project" ]]; then
                # codex_install.py settings is hard-wired to the user config;
                # its only difference (the plugins group) stays global-only.
                merge_settings_config \
                    "codex-config" \
                    "${SCRIPT_DIR}/.codex-plugin/config/config.toml" \
                    "${codex_config_dest}" \
                    "${CONFIG_GROUPS}" "${CONFIG_SELECT[@]}"
                codex_trust_warn "${codex_config_dest}"
            else
                codex_native_settings
            fi
        fi
        settings_legacy_hint codex codex-config "$(codex_settings_global_dest)"
    fi

    if [[ $do_rules -eq 1 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] Link Codex rules (default.rules + AGENTS.md)%s\n' "${BOLD}" "$step" "$total" "${NC}"
        # Codex loads global instructions from AGENTS.md under $CODEX_HOME;
        # CLAUDE.md is not a native global filename, so only AGENTS.md is linked.
        # https://developers.openai.com/codex/guides/agents-md
        link_file       "${SCRIPT_DIR}/.codex-plugin/config/default.rules" "${HOME}/.codex/rules/default.rules"
        link_rules_file "${SCRIPT_DIR}/ycc/settings/rules/AGENTS.md"       "${HOME}/.codex/AGENTS.md"
    fi

    printf '\n%sCodex %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
    if [[ $do_base -eq 1 ]]; then
        warn "Restart Codex; ycc@ycc and ycc-mcp@ycc are installed. Rerun this base step to refresh their snapshots."
    elif [[ $do_mcp -eq 1 ]]; then
        warn "Restart Codex; ycc-mcp@ycc is installed."
    fi
}

# ---------------------------------------------------------------------------
# Codex remove
# ---------------------------------------------------------------------------
remove_codex_target() {
    validate_only_steps "codex"
    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    local codex_dir="${HOME}/.codex"

    if step_enabled base; then
        printf '\n%sCodex: remove owned native packages (ycc + ycc-mcp) + marketplace%s\n' "${BOLD}" "${NC}"
        codex_native_packages remove ycc,ycc-mcp
    elif step_enabled mcp; then
        printf '\n%sCodex: remove owned native MCP package (ycc-mcp)%s\n' "${BOLD}" "${NC}"
        codex_native_packages remove ycc-mcp
    fi
    if step_enabled base || step_enabled agents; then
        printf '\n%sCodex: remove custom agents%s\n' "${BOLD}" "${NC}"
        run_slice codex agents
    fi
    if step_enabled rules; then
        printf '\n%sCodex: unlink rules (default.rules + CLAUDE.md + AGENTS.md)%s\n' "${BOLD}" "${NC}"
        unlink_owned_link "${SCRIPT_DIR}/.codex-plugin/config/default.rules" "${codex_dir}/rules/default.rules"
        unlink_owned_link "${SCRIPT_DIR}/ycc/settings/rules/CLAUDE.md" "${codex_dir}/CLAUDE.md"
        unlink_owned_link "${SCRIPT_DIR}/ycc/settings/rules/AGENTS.md" "${codex_dir}/AGENTS.md"
    fi
    if step_enabled settings; then
        local codex_config_dest
        codex_config_dest="$(codex_config_file)"
        printf '\n%sCodex: remove managed config (%s)%s\n' "${BOLD}" "${codex_config_dest}" "${NC}"
        config_group_selection codex "$(config_groups_for_target codex)"
        if [[ "$(step_scope codex settings)" == "project" ]]; then
            remove_settings "codex-config" "${SCRIPT_DIR}/.codex-plugin/config/config.toml" \
                "${codex_config_dest}" "${CONFIG_GROUPS}" "${CONFIG_SELECT[@]}"
        elif [[ -n "${CONFIG_GROUPS}" ]]; then
            codex_native_settings --remove
        fi
        settings_legacy_hint codex codex-config "$(codex_settings_global_dest)"
    fi
    if step_enabled base; then
        # Retire whatever the retired legacy installer left behind as well.
        run_legacy_cleanup codex || warn "legacy cleanup skipped: legacy ycc@local-ycc-plugins files were retained (see the message above)"
    fi
    printf '\n%sCodex remove complete.%s\n' "${BOLD}" "${NC}"
}
