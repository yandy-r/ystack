# shellcheck shell=bash
# cursor.sh — the Cursor target: implements the per-target contract that install.sh
# dispatches through (see scripts/lib/install/steps.sh):
#   cursor_valid_steps, cursor_intent_steps <intent>, cursor_config_groups,
#   cursor_supports_repo_mode, cursor_reads_agents_skills, sync_cursor_target, remove_cursor_target
#
# Sourced by install.sh (never run directly); inherits SCRIPT_DIR and the
# shared helpers from core.sh / steps.sh / bundle.sh.

CURSOR_PACKAGES_DIR="${SCRIPT_DIR}/packages/cursor"
CURSOR_CLI_CONFIG_SRC="${CURSOR_PACKAGES_DIR}/installer-fallback/config/cli-config.json"

# cursor_unit_src_root <unit> — generated package root that ships <unit>; the
# installed ~/.cursor/<unit>/ layout is unchanged by the native package split.
cursor_unit_src_root() {
    case "$1" in
        skills | agents) echo "${CURSOR_PACKAGES_DIR}/ycc" ;;
        rules) echo "${CURSOR_PACKAGES_DIR}/ycc-rules" ;;
        *) err "Unknown Cursor bundle unit: $1"; exit 1 ;;
    esac
}

# cursor_valid_steps — comma-separated steps Cursor accepts for --only.
cursor_valid_steps() { echo "base,skills,agents,commands,settings,rules,mcp,hooks"; }

# Base installation builds bundles; removal is a read-only entry preview.
cursor_dry_run_steps() {
    printf 'mcp,settings,rules,hooks'
    [[ "${COMMAND}" != remove ]] || printf ',base'
    echo
}

# cursor_intent_steps <intent> — steps <intent> maps to; empty means no-op.
cursor_intent_steps() {
    case "$1" in
        skills|agents|commands|hooks) echo "$1" ;;
        base|rules|mcp) echo "$1" ;;
        settings) echo "settings" ;;
        plugins) echo "" ;;
        # Mods are Claude Code only for now. A target gains them by mapping
        # 'mods' to a step that translates ycc/mods/<name> into that tool's
        # extension format; until then the intent is reported and skipped.
        mods) echo "" ;;
        *) echo "" ;;
    esac
}

# cursor_config_groups — default managed config groups for cli-config.json.
cursor_config_groups() { echo "settings"; }

# Cursor reads bundles from local directories only.
cursor_supports_repo_mode() { return 1; }

# Cursor reads ~/.agents/skills plus ~/.cursor/skills; installing both duplicates them.
cursor_reads_agents_skills() { return 0; }
# cursor_native_skills_dirs — where this target installs ycc skills natively.
cursor_native_skills_dirs() { printf '%s\n' "${HOME}/.cursor/skills"; }

# Where a commands carrier finds the skills it references this run: the chosen
# skills home (native or consolidated ~/.agents/skills), never a plugin root.
cursor_skills_home() {
    if [[ "${SKILLS_HOME:-}" == "agents" ]] || skills_consolidated cursor; then
        echo "${HOME}/.agents/skills"
    else
        echo "${HOME}/.cursor/skills"
    fi
}

# cursor_preflight — before any target runs: each Cursor command references
# its skill, so an install/sync that runs cursor's commands and skills steps
# with --skills needs --commands, every selected command cursor ships among
# cursor's --skills (none shipped: the commands step skips); anything else is
# refused before any target writes.
cursor_preflight() {
    [[ "${COMMAND}" != "remove" ]] && has_selection skills || return 0
    target_runs_step cursor commands && target_runs_step cursor skills || return 0
    local name skills commands="" missing=""
    skills="$(selection_for_target skills cursor)"
    if has_selection commands; then
        commands="$(selection_for_target commands cursor)"
        [[ -n "${commands}" ]] || return 0
    fi
    for name in ${commands//,/ }; do
        [[ ",${skills}," == *",${name},"* ]] || missing+="${missing:+,}${name}"
    done
    [[ -n "${commands}" && -z "${missing}" ]] && return 0
    if [[ -z "${commands}" ]]; then
        err "Cursor commands reference their skills; --skills narrows a run that installs every Cursor command"
        err "  select the commands too (each needs its skill): ${CLI_NAME} sync --target cursor --intent skills,commands --skills ${skills} --commands ${skills}"
    else
        err "Cursor commands need their skills; --skills misses the selected commands ${missing//,/, }"
        err "  add them to --skills: ${CLI_NAME} sync --target cursor --intent skills,commands --skills ${skills},${missing} --commands ${commands}"
    fi
    exit 1
}

# cursor_commands_entries — set CURSOR_COMMANDS_ENTRIES to the --entries flag
# the commands step passes (empty: the whole slice); false when --commands
# names none cursor ships (the step skips, so there is nothing to preflight).
cursor_commands_entries() {
    CURSOR_COMMANDS_ENTRIES=()
    has_selection commands || return 0
    local names
    names="$(selection_for_target commands cursor)"
    [[ -n "${names}" ]] || return 1
    CURSOR_COMMANDS_ENTRIES=(--entries "${names}")
}

# Preflight both carriers before any user file is changed. The helpers reject
# unsafe ownership, local edits, malformed hooks, and symlink destinations.
# Slice-helper stdout (its dry-run preview lines) is discarded: the real step
# prints them once under --dry-run and never in a live run; stderr stays.
cursor_carrier_preflight() {
    local action="$1" skills_home
    local -a flags=()
    [[ "${FORCE:-0}" == "1" ]] && flags+=(--force)
    if [[ "${action}" == "install" ]] && step_enabled commands; then
        skills_home="$(cursor_skills_home)"
        # Skills land later in the same run: reference the destination, not what
        # is on disk yet. Standalone commands without skills fail closed here.
        local -a skills_flags=(--skills-dir "${skills_home}")
        if step_enabled base || step_enabled skills; then
            skills_flags+=(--skills-pending)
        fi
        if cursor_commands_entries; then
            python3 "${SLICE_HELPER}" install --target cursor --slice commands --dry-run \
                "${skills_flags[@]}" "${flags[@]}" "${CURSOR_COMMANDS_ENTRIES[@]}" >/dev/null || return 1
        fi
    fi
    if [[ "${action}" == "remove" ]] && step_enabled commands; then
        if cursor_commands_entries; then
            python3 "${SLICE_HELPER}" remove --target cursor --slice commands --dry-run \
                "${flags[@]}" "${CURSOR_COMMANDS_ENTRIES[@]}" >/dev/null || return 1
        fi
    fi
    if step_enabled hooks; then
        python3 "${SLICE_HELPER}" "${action}" --target cursor --slice hooks --dry-run "${flags[@]}" >/dev/null || return 1
    fi
    if step_enabled hooks; then
        [[ "${action}" == "remove" ]] && flags+=(--remove)
        merge_settings_config cursor-hooks "${CURSOR_PACKAGES_DIR}/ycc-hooks/hooks/hooks.json" \
            "${HOME}/.cursor/hooks.json" hooks --dry-run "${flags[@]}" || return 1
    fi
}

cursor_sync_hooks() {
    run_slice cursor hooks
    merge_settings_config cursor-hooks "${CURSOR_PACKAGES_DIR}/ycc-hooks/hooks/hooks.json" \
        "${HOME}/.cursor/hooks.json" hooks
}

# ---------------------------------------------------------------------------
# Cursor sync (base + optional MCP + optional settings/rules)
# ---------------------------------------------------------------------------
sync_cursor_target() {
    validate_only_steps "cursor"

    local cursor_dir="${HOME}/.cursor"
    local scripts_dir="${SCRIPT_DIR}/scripts"

    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    cursor_carrier_preflight install || exit 1

    [[ "${DRY_RUN:-0}" == "1" ]] || mkdir -p "${cursor_dir}"

    # 'base' ships every bundle unit; 'skills' / 'agents' ship one each.
    local -a units=()
    read -r -a units <<< "$(skills_filter cursor "$(selected_bundle_units skills agents rules)")"
    if [[ -n "${PACKAGE:-}" ]]; then
        # A package installs only the bundle units its closure names: ycc-rules
        # is rules only, ycc-mcp carries no bundle unit. base alone would mirror all.
        # The planner already rejected any closure with an undeliverable own
        # component, and Cursor plugin caches are never treated as active.
        local -a package_units=()
        local unit_name
        for unit_name in "${units[@]}"; do
            [[ " ${PACKAGE_CURSOR_UNITS:-} " == *" ${unit_name} "* ]] && package_units+=("${unit_name}")
        done
        units=("${package_units[@]}")
    fi
    local do_bundle=0 do_settings=0 do_mcp=0 do_rules=0 do_commands=0 do_hooks=0
    [[ ${#units[@]} -gt 0 ]] && do_bundle=1
    step_enabled settings && do_settings=1
    step_enabled mcp && do_mcp=1
    step_enabled rules && do_rules=1
    step_enabled commands && do_commands=1
    step_enabled hooks && do_hooks=1

    [[ $do_bundle -eq 1 ]] && { command -v rsync >/dev/null 2>&1 || { err "rsync is required but not found"; exit 1; }; }

    if [[ $do_bundle -eq 0 && $do_settings -eq 0 && $do_mcp -eq 0 && $do_rules -eq 0 && $do_commands -eq 0 && $do_hooks -eq 0 ]]; then
        warn "Cursor target ran no steps"
        printf '\n%sCursor %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
        return 0
    fi

    local total=0
    [[ $do_bundle -eq 1 ]] && total=$((total + 4))
    [[ $do_settings -eq 1 ]] && total=$((total + 1))
    [[ $do_mcp -eq 1 ]] && total=$((total + 1))
    [[ $do_rules -eq 1 ]] && total=$((total + 1))
    [[ $do_commands -eq 1 ]] && total=$((total + 1))
    [[ $do_hooks -eq 1 ]] && total=$((total + 1))
    local step=0

    if [[ $do_bundle -eq 1 ]]; then
        local unit
        for unit in "${units[@]}"; do
            if [[ ! -d "$(cursor_unit_src_root "${unit}")/${unit}" ]]; then
                err "Cursor plugin source directory not found: $(cursor_unit_src_root "${unit}")/${unit}"
                exit 1
            fi
        done

        for unit in "${units[@]}"; do
            require_scripts "${scripts_dir}/generate-cursor-${unit}.sh" "${scripts_dir}/validate-cursor-${unit}.sh"
        done

        step=$((step + 1))
        printf '\n%s[%d/%d] Generate Cursor-native bundle (%s)%s\n' "${BOLD}" "$step" "$total" "${units[*]}" "${NC}"
        for unit in "${units[@]}"; do
            run_build_script "${scripts_dir}/generate-cursor-${unit}.sh"
        done

        step=$((step + 1))
        printf '\n%s[%d/%d] Validate generated bundle%s\n' "${BOLD}" "$step" "$total" "${NC}"
        for unit in "${units[@]}"; do
            run_build_script "${scripts_dir}/validate-cursor-${unit}.sh"
        done

        step=$((step + 1))
        printf '\n%s[%d/%d] Format modified repository files%s\n' "${BOLD}" "$step" "$total" "${NC}"
        run_repo_style_format_modified

        step=$((step + 1))
        printf '\n%s[%d/%d] Sync bundle to ~/.cursor%s\n' "${BOLD}" "$step" "$total" "${NC}"
        # base mirrors every unit dir; a slice installs just its entries.
        if step_enabled base; then
            # Project native-form init resources back to the legacy bytes the
            # file-copy installer ships: the checked-in package stays
            # package-local while installed skills remain byte-identical.
            for unit in "${units[@]}"; do
                sync_bundle_units "$(cursor_unit_src_root "${unit}")" "${cursor_dir}" "${unit}"
            done
            if [[ " ${units[*]} " == *" skills "* ]]; then
                python3 - "${scripts_dir}" "${cursor_dir}" "${HOME}" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from cursor_native_resources import restore_installer_init
from install_slices import rewrites_for, transform_tree

skills = Path(sys.argv[2]) / "skills"
restore_installer_init(skills)
transform_tree(skills, rewrites_for("cursor", Path(sys.argv[3])), None)
PY
            fi
        fi
        local slice
        for slice in $(skills_filter cursor "$(selected_slices skills agents)"); do
            run_slice cursor "${slice}" select
        done
    fi

    if [[ $do_commands -eq 1 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] Install Cursor user commands%s\n' "${BOLD}" "$step" "$total" "${NC}"
        if skills_consolidated cursor; then
            # The agents target normally runs later; commands cannot land with
            # dangling references, so materialize its scheduled skills first.
            run_slice agents skills select
        fi
        YCC_CURSOR_SKILLS_HOME="$(cursor_skills_home)" run_slice cursor commands select
    fi
    if [[ $do_hooks -eq 1 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] Merge Cursor sessionStart hook%s\n' "${BOLD}" "$step" "$total" "${NC}"
        cursor_sync_hooks
    fi

    if [[ $do_settings -eq 1 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] Merge Cursor CLI settings%s\n' "${BOLD}" "$step" "$total" "${NC}"
        merge_settings_config \
            "cursor-cli" \
            "${CURSOR_CLI_CONFIG_SRC}" \
            "${cursor_dir}/cli-config.json" \
            "settings"
    fi

    if [[ $do_mcp -eq 1 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] %s MCP servers%s\n' "${BOLD}" "$step" "$total" "${COMMAND}" "${NC}"
        run_mcp_step cursor
    fi

    if [[ $do_rules -eq 1 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] Cursor rules: user rules are settings-managed%s\n' "${BOLD}" "$step" "$total" "${NC}"
        # Official docs describe User Rules in Settings (Customize → Rules).
        # File-based global provisioning is unsupported/unverified, so link nothing.
        # Project rules use .cursor/rules/*.mdc or AGENTS.md. https://cursor.com/docs/rules
        info "To install these rules for Cursor, paste ycc/settings/rules/CLAUDE.md"
        info "into Cursor Settings → Rules (User Rules)."
        # Links from older installs are left alone; 'remove --intent rules' still unlinks them.
    fi

    printf '\n%sCursor %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
}

# ---------------------------------------------------------------------------
# Cursor remove
# ---------------------------------------------------------------------------
remove_cursor_target() {
    validate_only_steps "cursor"
    local cursor_dir="${HOME}/.cursor"
    cursor_carrier_preflight remove || exit 1
    if step_enabled hooks; then
        remove_settings cursor-hooks "${CURSOR_PACKAGES_DIR}/ycc-hooks/hooks/hooks.json" "${cursor_dir}/hooks.json" hooks || exit 1
        run_slice cursor hooks
    fi
    remove_slices cursor commands

    if step_enabled rules; then
        printf '\n%sCursor: unlink rules (CLAUDE.md + AGENTS.md)%s\n' "${BOLD}" "${NC}"
        unlink_owned_link "${SCRIPT_DIR}/ycc/settings/rules/CLAUDE.md" "${cursor_dir}/CLAUDE.md"
        unlink_owned_link "${SCRIPT_DIR}/ycc/settings/rules/AGENTS.md" "${cursor_dir}/AGENTS.md"
    fi
    if step_enabled mcp; then
        printf '\n%sCursor: remove MCP servers%s\n' "${BOLD}" "${NC}"
        run_mcp_step cursor
    fi
    if step_enabled settings; then
        printf '\n%sCursor: remove managed CLI settings%s\n' "${BOLD}" "${NC}"
        remove_settings "cursor-cli" "${CURSOR_CLI_CONFIG_SRC}" "${cursor_dir}/cli-config.json" "settings"
    fi
    remove_slices cursor skills agents
    if step_enabled base; then
        printf '\n%sCursor: remove bundle from ~/.cursor%s\n' "${BOLD}" "${NC}"
        local unit
        for unit in skills agents rules; do
            remove_mirrored_entries "$(cursor_unit_src_root "${unit}")/${unit}" "${cursor_dir}/${unit}"
        done
    fi
    printf '\n%sCursor remove complete.%s\n' "${BOLD}" "${NC}"
}
