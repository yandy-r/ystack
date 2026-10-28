# shellcheck shell=bash
# opencode.sh — the opencode target: implements the per-target contract that install.sh
# dispatches through (see scripts/lib/install/steps.sh):
#   opencode_valid_steps, opencode_intent_steps <intent>, opencode_config_groups,
#   opencode_project_steps, opencode_preflight, opencode_catalog_names,
#   opencode_supports_repo_mode, opencode_reads_agents_skills, sync_opencode_target, remove_opencode_target
#
# Sourced by install.sh (never run directly); inherits SCRIPT_DIR and the
# shared helpers from core.sh / steps.sh / bundle.sh. The opt-in third-party
# plugin catalog lives in opencode-catalog.sh.

# shellcheck source=scripts/lib/install/targets/opencode-catalog.sh
source "${SCRIPT_DIR}/scripts/lib/install/targets/opencode-catalog.sh"

# shellcheck disable=SC2034  # read by the opencode sync/remove and MCP steps.
OPENCODE_PLUGIN_DIR="${SCRIPT_DIR}/.opencode-plugin"

# Bundle units 'base' mirrors into ~/.config/opencode. `shared/` carries the
# cross-skill scripts and references that ycc/skills/_shared/... is rewritten
# to at generation time (~/.config/opencode/shared/...). `ycc-sensitive-guard/`
# is the local plugin the managed `plugins` entry "./ycc-sensitive-guard"
# loads; the agents generator writes it beside the agents it protects, `base`
# (or the `plugins` settings group) installs it, and it is never dropped by
# skills consolidation. Both MUST stay in this list:
# scripts/validate-opencode-install-coverage.sh parses this line and checks
# every <dir> the bundle references is either listed here or explicitly
# allowlisted as a user-global/runtime path.
OPENCODE_BUNDLE_UNITS=(skills agents commands shared ycc-sensitive-guard)

# opencode_valid_steps — comma-separated steps opencode accepts for --only.
opencode_valid_steps() { echo "base,skills,agents,commands,settings,rules,mcp"; }

# Base installation builds bundles; removal is a read-only entry preview.
opencode_dry_run_steps() {
    printf 'mcp,settings,rules'
    # shellcheck disable=SC2153  # COMMAND is install.sh's subcommand global.
    [[ "${COMMAND}" != remove ]] || printf ',base'
    echo
}

# opencode_intent_steps <intent> — steps <intent> maps to; empty means no-op.
opencode_intent_steps() {
    case "$1" in
        skills|agents|commands) echo "$1" ;;
        # Mods are Claude Code only for now (see cursor_intent_steps).
        mods) echo "" ;;
        # MCP has its own scope-aware step; plugin enablement lives in
        # opencode.json.
        base|settings|rules|mcp) echo "$1" ;;
        plugins) echo "settings" ;;
        hooks) echo "" ;;
        *) echo "" ;;
    esac
}

# opencode_config_groups — default managed config groups for opencode.json.
# MCP servers are owned by the scope-aware 'mcp' step.
opencode_config_groups() { echo "settings,plugins"; }

# opencode_project_steps — steps an explicit --project may run: settings, for
# catalog plugins only (opencode_preflight rejects anything else).
opencode_project_steps() { echo "settings"; }

# opencode reads bundles from local directories only.
opencode_supports_repo_mode() { return 1; }

# opencode reads ~/.agents/skills plus its own skills dir; installing both duplicates them.
opencode_reads_agents_skills() { return 0; }
# opencode_native_skills_dirs — where this target installs ycc skills natively.
opencode_native_skills_dirs() { printf '%s\n' "${HOME}/.config/opencode/skills"; }

# ---------------------------------------------------------------------------
# opencode sync (base: skills + agents + commands; settings: config + rules)
# ---------------------------------------------------------------------------
sync_opencode_target() {
    validate_only_steps "opencode"

    local opencode_dir="${HOME}/.config/opencode"
    local scripts_dir="${SCRIPT_DIR}/scripts"

    # 'base' ships every unit in OPENCODE_BUNDLE_UNITS; 'skills' (plus the
    # shared/ helpers skill bodies reference), 'agents' and 'commands' ship
    # one each.
    local -a units=()
    read -r -a units <<< "$(skills_filter opencode "$(selected_bundle_units "${OPENCODE_BUNDLE_UNITS[@]}")")"
    local do_base=0 do_bundle=0 do_settings=0 do_rules=0 do_mcp=0
    step_enabled base && do_base=1
    [[ ${#units[@]} -gt 0 ]] && do_bundle=1
    step_enabled settings && do_settings=1
    step_enabled rules && do_rules=1
    step_enabled mcp && do_mcp=1

    if [[ $do_bundle -eq 0 && $do_settings -eq 0 && $do_rules -eq 0 && $do_mcp -eq 0 ]]; then
        warn "opencode target ran no steps"
        printf '\n%sopencode %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
        return 0
    fi

    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    [[ $do_bundle -eq 1 ]] && { command -v rsync >/dev/null 2>&1 || { err "rsync is required but not found"; exit 1; }; }

    local total=0
    [[ $do_bundle -eq 1 ]] && total=$((total + 4))
    [[ $do_settings -eq 1 ]] && total=$((total + 1))
    [[ $do_rules -eq 1 ]] && total=$((total + 1))
    [[ $do_mcp -eq 1 ]] && total=$((total + 1))
    local step=0

    if [[ $do_bundle -eq 1 ]]; then
        if [[ ! -d "${OPENCODE_PLUGIN_DIR}" ]]; then
            err "opencode plugin source directory not found: ${OPENCODE_PLUGIN_DIR}"
            exit 1
        fi

        # Generators run per unit (shared/ is written by the skills generator,
        # ycc-sensitive-guard/ by the agents generator); 'base' also
        # regenerates opencode.json + AGENTS.md (the 'plugin' pass).
        local -a passes=()
        local unit
        for unit in "${units[@]}"; do
            [[ "${unit}" == "shared" || "${unit}" == "ycc-sensitive-guard" ]] || passes+=("${unit}")
        done
        [[ $do_base -eq 1 ]] && passes+=(plugin)
        local pass
        for pass in "${passes[@]}"; do
            require_scripts "${scripts_dir}/generate-opencode-${pass}.sh" "${scripts_dir}/validate-opencode-${pass}.sh"
        done

        mkdir -p "${opencode_dir}"

        step=$((step + 1))
        printf '\n%s[%d/%d] Generate opencode-native bundle (%s)%s\n' "${BOLD}" "$step" "$total" "${passes[*]}" "${NC}"
        for pass in "${passes[@]}"; do
            run_build_script "${scripts_dir}/generate-opencode-${pass}.sh"
        done

        step=$((step + 1))
        printf '\n%s[%d/%d] Validate generated bundle%s\n' "${BOLD}" "$step" "$total" "${NC}"
        for pass in "${passes[@]}"; do
            run_build_script "${scripts_dir}/validate-opencode-${pass}.sh"
        done

        step=$((step + 1))
        printf '\n%s[%d/%d] Format modified repository files%s\n' "${BOLD}" "$step" "$total" "${NC}"
        run_repo_style_format_modified

        step=$((step + 1))
        printf '\n%s[%d/%d] Sync bundle to ~/.config/opencode%s\n' "${BOLD}" "$step" "$total" "${NC}"
        # base mirrors every unit dir; a slice installs just its entries.
        if [[ $do_base -eq 1 ]]; then
            sync_bundle_units "${OPENCODE_PLUGIN_DIR}" "${opencode_dir}" "${units[@]}"
        fi
        local slice
        for slice in $(skills_filter opencode "$(selected_slices skills agents commands)"); do
            run_slice opencode "${slice}" select
        done

        # opencode ALSO reads bundles from the Claude-compat path .claude/skills.
        # We deliberately do not write to that path from the opencode target so
        # users who also run `--target claude` don't end up with two copies.
    fi

    if [[ $do_settings -eq 1 ]]; then
        step=$((step + 1))
        opencode_settings_paths
        printf '\n%s[%d/%d] Merge opencode config (%s)%s\n' "${BOLD}" "$step" "$total" "${OPENCODE_SETTINGS_FILE}" "${NC}"
        [[ "${DRY_RUN:-0}" == "1" ]] || mkdir -p "$(dirname "${OPENCODE_SETTINGS_FILE}")"
        # Merge managed keys only: per-machine model overrides, provider
        # credentials and unknown keys in the user's opencode.json are kept.
        # Project scope (opencode_preflight) carries catalog plugins only.
        config_group_selection opencode "$(config_groups_for_target opencode)"
        if [[ -n "${CONFIG_GROUPS}" ]]; then
            merge_settings_config \
                "opencode-config" \
                "${OPENCODE_PLUGIN_DIR}/opencode.json" \
                "${OPENCODE_SETTINGS_FILE}" \
                "${CONFIG_GROUPS}" "${CONFIG_SELECT[@]}"
        fi
        # The managed `plugins` group loads "./ycc-sensitive-guard"; ship that
        # directory with it (unless 'base' mirrored it above) so the entry
        # never points at a missing plugin.
        if opencode_guard_selected && [[ " ${units[*]:-} " != *" ycc-sensitive-guard "* ]]; then
            command -v rsync >/dev/null 2>&1 || { err "rsync is required but not found"; exit 1; }
            sync_bundle_units "${OPENCODE_PLUGIN_DIR}" "${opencode_dir}" ycc-sensitive-guard
        fi
        opencode_catalog_sync
    fi

    if [[ $do_rules -eq 1 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] Link opencode rules (AGENTS.md)%s\n' "${BOLD}" "$step" "$total" "${NC}"
        # Native global rules path: https://opencode.ai/docs/rules
        # The generator copies the tool-neutral source verbatim behind a header.
        link_rules_file "${OPENCODE_PLUGIN_DIR}/AGENTS.md" "${opencode_dir}/AGENTS.md"
    fi

    if [[ $do_mcp -eq 1 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] %s MCP servers%s\n' "${BOLD}" "$step" "$total" "${COMMAND}" "${NC}"
        run_mcp_step opencode
    fi

    printf '\n%sopencode %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
    if [[ $do_bundle -eq 1 ]]; then
        warn "Restart opencode to pick up the new ${units[*]}."
    fi
}

# ---------------------------------------------------------------------------
# opencode remove
# ---------------------------------------------------------------------------
remove_opencode_target() {
    validate_only_steps "opencode"
    local opencode_dir="${HOME}/.config/opencode"

    if step_enabled mcp; then
        printf '\n%sopencode: remove MCP servers%s\n' "${BOLD}" "${NC}"
        run_mcp_step opencode
    fi
    if step_enabled rules; then
        printf '\n%sopencode: unlink rules (AGENTS.md)%s\n' "${BOLD}" "${NC}"
        unlink_owned_link "${OPENCODE_PLUGIN_DIR}/AGENTS.md" "${opencode_dir}/AGENTS.md"
    fi
    if step_enabled settings; then
        opencode_settings_paths
        printf '\n%sopencode: remove managed config (%s)%s\n' "${BOLD}" "${OPENCODE_SETTINGS_FILE}" "${NC}"
        config_group_selection opencode "$(config_groups_for_target opencode)"
        # Catalog first: its leaves (agents.<x>.disabled) sit inside bundle-owned
        # agents entries, which the bundle remove only takes back whole.
        opencode_catalog_remove
        remove_settings "opencode-config" "${OPENCODE_PLUGIN_DIR}/opencode.json" \
            "${OPENCODE_SETTINGS_FILE}" "${CONFIG_GROUPS}" "${CONFIG_SELECT[@]}"
        # The guard plugin goes with the `plugins` entry that loads it; an
        # entry kept as a local edit still loads it, so the directory stays.
        if opencode_guard_selected && ! step_enabled base \
            && ! opencode_guard_remains "${opencode_dir}/opencode.json"; then
            remove_mirrored_entries "${OPENCODE_PLUGIN_DIR}/ycc-sensitive-guard" "${opencode_dir}/ycc-sensitive-guard"
        fi
    fi
    remove_slices opencode skills agents commands
    if step_enabled base; then
        printf '\n%sopencode: remove bundle from ~/.config/opencode%s\n' "${BOLD}" "${NC}"
        local unit
        for unit in "${OPENCODE_BUNDLE_UNITS[@]}"; do
            # Keep the guard while opencode.json still loads it (settings kept).
            if [[ "${unit}" == "ycc-sensitive-guard" ]] && opencode_guard_remains "${opencode_dir}/opencode.json"; then
                info "kept ${opencode_dir}/${unit}: opencode.json still loads ./${unit}"
                continue
            fi
            remove_mirrored_entries "${OPENCODE_PLUGIN_DIR}/${unit}" "${opencode_dir}/${unit}"
        done
    fi
    printf '\n%sopencode remove complete.%s\n' "${BOLD}" "${NC}"
}

# opencode_guard_selected — true when this settings run merges (or removes)
# the bundle's "./ycc-sensitive-guard" plugins entry: the plugins group runs
# (CONFIG_GROUPS, set by config_group_selection) and --plugins, if given, names it.
opencode_guard_selected() {
    [[ ",${CONFIG_GROUPS}," == *",plugins,"* ]] || return 1
    [[ -z "${CONFIG_GROUP_ENTRIES[plugins]:-}" || ",${CONFIG_GROUP_ENTRIES[plugins]}," == *",./ycc-sensitive-guard,"* ]]
}

# opencode_config_loads_guard <opencode.json> — true when its `plugins` list
# still names the bundle's "./ycc-sensitive-guard" entry.
opencode_config_loads_guard() {
    opencode_config_loads "$1" ./ycc-sensitive-guard
}

# Preview the post-removal config rather than inspecting unchanged live bytes.
opencode_guard_remains() {
    if [[ "${DRY_RUN:-0}" == "1" ]] && step_enabled settings && opencode_guard_selected; then
        opencode_config_loads_after_remove "$1" ./ycc-sensitive-guard \
            "${OPENCODE_PLUGIN_DIR}/opencode.json" opencode-config "${CONFIG_GROUPS}"
    else
        opencode_config_loads_guard "$1"
    fi
}

# opencode_config_loads <opencode.json> <name> — true when its `plugins` list
# has an item keyed <name> (package name without its version, as the merge
# helper keys list items; a trailing '/' on a local path is ignored). The file
# is read as JSONC, as opencode reads it.
opencode_config_loads() {
    [[ -f "$1" ]] || return 1
    python3 - "$1" "$2" "${SCRIPT_DIR}/scripts" <<'PY'
import json
import sys

sys.path.insert(0, sys.argv[3])
from merge_managed_config import strip_jsonc  # noqa: E402

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        plugins = json.loads(strip_jsonc(handle.read())).get("plugins", [])
except (OSError, ValueError, AttributeError):
    sys.exit(1)


def key(spec: str) -> str:
    cut = spec.find("@", 1)
    return (spec[:cut] if cut > 0 else spec).rstrip("/")


specs = {p if isinstance(p, str) else p.get("package") for p in plugins if isinstance(p, (str, dict))}
sys.exit(0 if sys.argv[2].rstrip("/") in {key(s) for s in specs if isinstance(s, str)} else 1)
PY
}
