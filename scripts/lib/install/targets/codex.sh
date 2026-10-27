# shellcheck shell=bash
# codex.sh — the Codex target: implements the per-target contract that install.sh
# dispatches through (see scripts/lib/install/steps.sh):
#   codex_valid_steps, codex_intent_steps <intent>, codex_config_groups,
#   codex_supports_repo_mode, codex_reads_agents_skills, sync_codex_target, remove_codex_target
#
# Sourced by install.sh (never run directly); inherits SCRIPT_DIR and the
# shared helpers from core.sh / steps.sh / bundle.sh.

CODEX_PLUGIN_DIR="${SCRIPT_DIR}/.codex-plugin/ycc"
CODEX_AGENTS_DIR="${SCRIPT_DIR}/.codex-plugin/agents"

# codex_valid_steps — comma-separated steps Codex accepts for --only.
codex_valid_steps() { echo "base,skills,agents,settings,rules,mcp"; }

# codex_dry_run_steps — base preview is removal-only; installs need native builds/CLI.
codex_dry_run_steps() {
    if [[ "${COMMAND:-}" == remove ]]; then
        echo "base,settings,rules,mcp"
    else
        echo "settings,rules,mcp"
    fi
}

# codex_intent_steps <intent> — steps <intent> maps to; empty means no-op.
codex_intent_steps() {
    case "$1" in
        skills|agents) echo "$1" ;;
        # Codex has no command layer.
        commands) echo "" ;;
        # Mods are Claude Code only for now (see cursor_intent_steps).
        mods) echo "" ;;
        # MCP has its own scope-aware step; plugin enablement lives in
        # config.toml.
        base|settings|rules|mcp) echo "$1" ;;
        plugins) echo "settings" ;;
        hooks) echo "" ;;
        *) echo "" ;;
    esac
}

# codex_config_groups — default managed config groups for config.toml.
# MCP servers are owned by the scope-aware 'mcp' step.
codex_config_groups() { echo "settings,plugins"; }

codex_supports_repo_mode() { return 0; }

# Codex reads ~/.agents/skills plus its own skills; installing both duplicates them.
codex_reads_agents_skills() { return 0; }
# codex_native_skills_dirs — where this target installs ycc skills natively.
codex_native_skills_dirs() { printf '%s\n' "${HOME}/.codex/plugins/ycc/skills" "${HOME}/.codex/skills"; }

# ---------------------------------------------------------------------------
# Codex plugin CLI
# ---------------------------------------------------------------------------
# Codex 0.160+ ships a plugin CLI: 'codex plugin add ycc@<marketplace>'
# snapshots the plugin into ~/.codex/plugins/cache/<marketplace>/ycc/<version>/
# and enables it in config.toml. Older Codex builds have no such command; for
# them the installer still writes the flat enabled-plugin cache by hand.

CODEX_MARKETPLACE_JSON="${HOME}/.agents/plugins/marketplace.json"
CODEX_PLUGIN_CACHE="${HOME}/.codex/plugins/cache/local-ycc-plugins/ycc"

# codex_plugin_cli_supported — true when the codex CLI has 'plugin add'.
codex_plugin_cli_supported() {
    command -v codex >/dev/null 2>&1 && codex plugin add --help >/dev/null 2>&1
}

# Keep the shell route on the generator's exact model gate, not catalog names.
codex_repository_native_enabled() {
    python3 "${SCRIPT_DIR}/scripts/codex_install.py" enabled
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

run_native_codex_install() {
    local -a command=(python3 "${SCRIPT_DIR}/scripts/codex_install.py" "$1" --mode "${MODE:-local}")
    [[ "${DRY_RUN:-0}" == 1 ]] && command+=(--dry-run)
    codex_plugin_cli_supported && command+=(--cli)
    "${command[@]}"
}

# codex_marketplace_name — the name of the marketplace holding ycc (the
# installer keeps an existing name when it merges its entry).
codex_marketplace_name() {
    python3 - "${CODEX_MARKETPLACE_JSON}" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        name = json.load(handle).get("name")
except (OSError, ValueError, AttributeError):
    name = None
print(name if isinstance(name, str) and name.strip() else "local-ycc-plugins")
PY
}

# remove_legacy_codex_cache — drop the flat cache older installers wrote at
# cache/local-ycc-plugins/ycc/ (plugin files directly inside, no version
# directory). Codex's own versioned cache lives in the same directory, so the
# flat copy would shadow it.
remove_legacy_codex_cache() {
    local cache="${CODEX_PLUGIN_CACHE}"
    if [[ -L "${cache}" ]]; then
        rm "${cache}"
        info "removed legacy Codex cache link ${cache}"
    elif [[ -d "${cache}/.codex-plugin" ]]; then
        rm -rf "${cache}"
        info "removed legacy flat Codex cache ${cache}"
    fi
}

# refresh_legacy_codex_cache — pre-CLI Codex: mirror the bundle into the
# enabled-plugin cache root and write its skills compatibility manifest.
refresh_legacy_codex_cache() {
    local cache="${CODEX_PLUGIN_CACHE}"
    if [[ -L "${cache}" ]]; then
        rm "${cache}"
    elif [[ -e "${cache}" && ! -d "${cache}" ]]; then
        err "Stale Codex plugin cache path at ${cache}."
        err "Remove it with:  rm -f ${cache}"
        exit 1
    fi
    mkdir -p "${cache}"
    rsync -a --delete "${CODEX_PLUGIN_DIR}/" "${cache}/"
    info "Synced Codex enabled-plugin cache → ${cache}"
    python3 - "${cache}" <<'PY'
import json
import sys
from pathlib import Path

cache_root = Path(sys.argv[1])
source_manifest = cache_root / ".codex-plugin" / "plugin.json"
skills_manifest = cache_root / "skills" / ".codex-plugin" / "plugin.json"
skills_index = cache_root / "skills" / "_skills"
payload = json.loads(source_manifest.read_text(encoding="utf-8"))
payload["skills"] = "./_skills/"
skills_manifest.parent.mkdir(parents=True, exist_ok=True)
skills_manifest.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
skills_index.mkdir(exist_ok=True)
for child in sorted((cache_root / "skills").iterdir()):
    if not child.is_dir() or child.name in {".codex-plugin", "_skills"}:
        continue
    link = skills_index / child.name
    if link.exists() or link.is_symlink():
        link.unlink()
    link.symlink_to(child, target_is_directory=True)
PY
    info "Wrote Codex cache compatibility manifest → ${cache}/skills/.codex-plugin/plugin.json"
}

# install_codex_plugin — install + enable ycc from its registered marketplace.
# Re-running refreshes Codex's snapshot of the plugin.
install_codex_plugin() {
    if ! codex_plugin_cli_supported; then
        warn "'codex plugin add' is unavailable (codex CLI missing or older than 0.160); writing the legacy cache instead."
        refresh_legacy_codex_cache
        return 0
    fi
    remove_legacy_codex_cache
    local selector
    selector="ycc@$(codex_marketplace_name)"
    info "Running: codex plugin add ${selector}"
    codex plugin add "${selector}" || warn "'codex plugin add ${selector}' returned non-zero — check 'codex plugin list'"
}

# enable_local_codex_plugin_leaf — enable only the installer-owned legacy cache.
# Passing a one-leaf source to the existing managed merge preserves comments,
# foreign plugin tables, and unrelated enablement from the machine's config.
enable_local_codex_plugin_leaf() {
    [[ -n "${PACKAGE:-}" ]] || return 0
    codex_plugin_cli_supported && return 0
    [[ -z "${PACKAGE_CODEX_FOREIGN_MARKETPLACE:-}" ]] || return 0
    local source rc=0
    source="$(mktemp)"
    printf '[plugins."ycc@local-ycc-plugins"]\nenabled = true\n' > "${source}"
    merge_settings_config codex-config "${source}" "${HOME}/.codex/config.toml" plugins \
        --entries ycc@local-ycc-plugins --force || rc=$?
    rm -f "${source}"
    return "${rc}"
}

# uninstall_codex_plugin — undo install_codex_plugin through the CLI; a
# plugin that is not installed is reported, not fatal.
uninstall_codex_plugin() {
    codex_plugin_cli_supported || return 0
    [[ -f "${CODEX_MARKETPLACE_JSON}" ]] || return 0
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        dry_run_note "run codex plugin remove" "ycc@$(codex_marketplace_name)"
        return 0
    fi
    local selector
    selector="ycc@$(codex_marketplace_name)"
    info "Running: codex plugin remove ${selector}"
    codex plugin remove "${selector}" || warn "'codex plugin remove ${selector}' returned non-zero — check 'codex plugin list'"
}

# ---------------------------------------------------------------------------
# Codex marketplace (~/.agents/plugins/marketplace.json)
# Registers ycc as a marketplace source for Codex.
#
#   local mode: registers ./.agents/plugins/ycc. Codex resolves local paths
#               against the marketplace root — the directory that holds
#               .agents/plugins/marketplace.json, i.e. $HOME — not against the
#               JSON file. ~/.agents/plugins/ycc is a symlink to the generated
#               bundle.
#   repo  mode: registers a git-subdir source pointing at
#               https://github.com/yandy-r/ystack.git subdirectory
#               ./.codex-plugin/ycc on branch main. Codex clones the repo at
#               that ref and resolves the bundle from the subdirectory.
# ---------------------------------------------------------------------------
merge_codex_marketplace_json() {
    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }

    local mode="${1:-}"
    if [[ ! "$mode" =~ ^(local|repo)$ ]]; then
        err "merge_codex_marketplace_json: invalid or missing mode '${mode}' (expected local|repo)"
        exit 1
    fi

    local plugin_src="${2:-}"
    if [[ "$mode" == "local" && -z "${plugin_src}" ]]; then
        err "merge_codex_marketplace_json: local mode requires a plugin source path"
        exit 1
    fi

    local dest="${HOME}/.agents/plugins/marketplace.json"
    python3 "${SCRIPT_DIR}/scripts/codex_marketplace.py" merge "$dest" "$mode" "$plugin_src"
    info "Merged ycc into ${dest}"
}

# ---------------------------------------------------------------------------
# Codex sync (base: plugin + agents + marketplace; settings: config link)
# ---------------------------------------------------------------------------
sync_codex_target() {
    validate_only_steps "codex"

    local codex_plugin_dest="${HOME}/.codex/plugins/ycc"
    local codex_marketplace_plugin_dest="${HOME}/.agents/plugins/ycc"
    local scripts_dir="${SCRIPT_DIR}/scripts"

    # 'base' registers the whole plugin and mirrors the custom agents (repo
    # mode: the marketplace entry only, as Codex pulls the bundle from the
    # git-subdir source of https://github.com/yandy-r/ystack.git).
    # The 'skills' / 'agents' slices install standalone entries into
    # ~/.codex/skills/<name> and ~/.codex/agents/<name>.toml — no plugin.
    local do_plugin=0 do_agents=0 do_settings=0 do_rules=0 do_mcp=0
    local native_codex=0
    codex_repository_native_enabled && native_codex=1
    step_enabled base && do_plugin=1
    if [[ -n "${PACKAGE:-}" && ${do_plugin} -eq 1 ]]; then
        # Only the existing local catalog may be refreshed. A foreign native
        # plugin already delivers skills/shared; retain its enablement and
        # deliver the installer-owned agents/settings/instructions gap below.
        codex_native_plugin_detected || true
        if [[ -n "${PACKAGE_CODEX_FOREIGN_MARKETPLACE:-}" ]]; then
            info "native ycc already installed as ycc@${PACKAGE_CODEX_FOREIGN_MARKETPLACE}; not re-registering local-ycc-plugins — delivering agents, settings and rules only"
            do_plugin=0
        fi
    fi
    local -a slices=()
    read -r -a slices <<< "$(skills_filter codex "$(selected_slices skills agents)")"
    # Choice 1 (skills → ~/.agents/skills): drop plugin registration; install
    # the agents slice (~/.codex/agents) instead.
    # base_agents=1: 'base' syncs every custom agent this run, so the agents
    # slice stays whole even when --agents narrows the agents step.
    local base_agents=0
    if skills_consolidated codex && [[ $do_plugin -eq 1 ]]; then
        warn "codex skills consolidated into ~/.agents/skills — skipped plugin registration"
        [[ " ${slices[*]} " == *" agents "* ]] || slices+=(agents)
        do_plugin=0
        base_agents=1
    fi
    # Local base mirrors the custom agents, unless the agents slice already
    # installs them (explicit --only agents, or the consolidated branch above).
    if [[ $do_plugin -eq 1 && "${MODE:-local}" == "local" ]]; then
        base_agents=1
        [[ " ${slices[*]} " != *" agents "* ]] && do_agents=1
    fi
    if [[ ${base_agents} -eq 1 ]] && has_selection agents && step_enabled agents; then
        warn "codex base syncs every custom agent into ~/.codex/agents; --agents does not narrow this run"
    fi
    step_enabled settings && do_settings=1
    step_enabled rules && do_rules=1
    step_enabled mcp && do_mcp=1

    if [[ $do_plugin -eq 0 && ${#slices[@]} -eq 0 && $do_settings -eq 0 && $do_rules -eq 0 && $do_mcp -eq 0 ]]; then
        warn "Codex target ran no steps"
        printf '\n%sCodex %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
        return 0
    fi

    # The local plugin, the mirrored agents and the slices are built from this
    # checkout; repo-mode plugin registration only writes JSON.
    local do_local_plugin=0 do_build=0
    [[ $do_plugin -eq 1 && "${MODE:-local}" == "local" ]] && do_local_plugin=1
    if [[ $do_plugin -eq 1 && $native_codex -eq 1 ]] && ! codex_plugin_cli_supported; then
        do_local_plugin=1
    fi
    [[ $do_local_plugin -eq 1 || $do_agents -eq 1 || ${#slices[@]} -gt 0 ]] && do_build=1

    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    if [[ $do_build -eq 1 ]]; then
        command -v rsync >/dev/null 2>&1 || { err "rsync is required but not found"; exit 1; }
        command -v realpath >/dev/null 2>&1 || { err "realpath is required but not found"; exit 1; }
    fi

    local total=0
    [[ $do_build -eq 1 ]] && total=$((total + 3))
    [[ $do_local_plugin -eq 1 && $native_codex -eq 0 ]] && total=$((total + 1))
    [[ $do_agents -eq 1 ]] && total=$((total + 1))
    [[ $do_plugin -eq 1 ]] && total=$((total + 1))
    total=$((total + ${#slices[@]}))
    [[ $do_settings -eq 1 ]] && total=$((total + 1))
    [[ $do_rules -eq 1 ]] && total=$((total + 1))
    [[ $do_mcp -eq 1 ]] && total=$((total + 1))
    local step=0

    if [[ $do_build -eq 1 ]]; then
        if [[ ! -d "${SCRIPT_DIR}/.codex-plugin" ]]; then
            err "Codex plugin source directory not found: ${SCRIPT_DIR}/.codex-plugin"
            exit 1
        fi
        if [[ ! -d "${CODEX_PLUGIN_DIR}" ]]; then
            err "Codex plugin bundle root not found: ${CODEX_PLUGIN_DIR}"
            exit 1
        fi
        if [[ ! -d "${CODEX_AGENTS_DIR}" ]]; then
            err "Codex agent source directory not found: ${CODEX_AGENTS_DIR}"
            exit 1
        fi

        # Generator/validator passes: generate-codex-<pass>.sh.
        local -a passes=()
        if [[ $do_local_plugin -eq 1 || " ${slices[*]} " == *" skills "* ]]; then
            passes+=(skills)
        fi
        if [[ $do_agents -eq 1 || " ${slices[*]} " == *" agents "* ]]; then
            passes+=(agents)
        fi
        [[ $do_local_plugin -eq 1 ]] && passes+=(plugin)
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

    if [[ $do_local_plugin -eq 1 && $native_codex -eq 0 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] Link plugin tree%s\n' "${BOLD}" "$step" "$total" "${NC}"
        # Symlink (not rsync) the plugin tree so edits in .codex-plugin/ycc/ are
        # live for Codex after regeneration. Generated skill bodies reference
        # ~/.codex/plugins/ycc/... as absolute paths; the symlink keeps those
        # references valid.
        if [[ -d "${codex_plugin_dest}" && ! -L "${codex_plugin_dest}" ]]; then
            err "Stale Codex plugin copy at ${codex_plugin_dest} (left over from the pre-symlink rsync flow)."
            err "Remove it with:  rm -rf ${codex_plugin_dest}"
            err "Then re-run this command. The symlink will be created in its place."
            exit 1
        fi
        if [[ -d "${codex_marketplace_plugin_dest}" && ! -L "${codex_marketplace_plugin_dest}" ]]; then
            err "Stale Codex marketplace plugin copy at ${codex_marketplace_plugin_dest}."
            err "Remove it with:  rm -rf ${codex_marketplace_plugin_dest}"
            err "Then re-run this command. The symlink will be created in its place."
            exit 1
        fi
        link_file "${CODEX_PLUGIN_DIR}" "${codex_plugin_dest}"
        link_file "${CODEX_PLUGIN_DIR}" "${codex_marketplace_plugin_dest}"
    fi

    if [[ $do_agents -eq 1 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] Sync custom agents%s\n' "${BOLD}" "$step" "$total" "${NC}"
        # Ownership-tracked, like the agents slice: only ycc's agents are
        # replaced or retired; the user's own agents are never touched.
        run_slice codex agents
    fi

    if [[ $do_plugin -eq 1 ]]; then
        step=$((step + 1))
        if [[ $native_codex -eq 1 ]]; then
            printf '\n%s[%d/%d] Install native Codex packages (ycc + ycc-mcp)%s\n' "${BOLD}" "$step" "$total" "${NC}"
            run_native_codex_install install
        elif [[ "${MODE:-local}" == "repo" ]]; then
            # Repo mode: Codex clones https://github.com/yandy-r/ystack.git
            # at main and resolves the bundle from ./.codex-plugin/ycc on install.
            # Bundle regeneration stays out-of-band via ./scripts/sync.sh --only codex.
            printf '\n%s[%d/%d] Register git-subdir marketplace source (https://github.com/yandy-r/ystack.git ./.codex-plugin/ycc @main)%s\n' "${BOLD}" "$step" "$total" "${NC}"
            merge_codex_marketplace_json "repo"
        else
            printf '\n%s[%d/%d] Register repo as local marketplace source + install ycc%s\n' "${BOLD}" "$step" "$total" "${NC}"
            # Codex resolves local sources against the marketplace root (the
            # directory holding .agents/plugins/marketplace.json, here $HOME),
            # so the path names the ~/.agents/plugins/ycc link from there.
            merge_codex_marketplace_json "local" "./.agents/plugins/ycc"
        fi
        if [[ $native_codex -eq 0 ]]; then
            install_codex_plugin
            enable_local_codex_plugin_leaf
        fi
    fi

    local slice
    for slice in "${slices[@]}"; do
        step=$((step + 1))
        printf '\n%s[%d/%d] Install standalone %s into ~/.codex/%s%s\n' "${BOLD}" "$step" "$total" "${slice}" "${slice}" "${NC}"
        # Only the slice STEP narrows: when 'base' also runs, the agents
        # slice ships every agent, like base itself.
        if step_enabled "${slice}" && [[ "${slice}" != agents || ${base_agents} -eq 0 ]]; then
            run_slice codex "${slice}" select
        else
            run_slice codex "${slice}"
        fi
    done

    if [[ $do_settings -eq 1 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] Merge Codex config (config.toml)%s\n' "${BOLD}" "$step" "$total" "${NC}"
        # Merge managed keys only: trusted-project entries, MCP tokens,
        # connector IDs and comments in the user's config.toml are preserved.
        config_group_selection codex "$(config_groups_for_target codex)"
        if [[ -n "${CONFIG_GROUPS}" ]]; then
            if [[ $native_codex -eq 1 ]]; then
                codex_native_settings
            else
                merge_settings_config \
                    "codex-config" \
                    "${SCRIPT_DIR}/.codex-plugin/config/config.toml" \
                    "${HOME}/.codex/config.toml" \
                    "${CONFIG_GROUPS}" "${CONFIG_SELECT[@]}"
            fi
        fi
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

    if [[ $do_mcp -eq 1 ]]; then
        step=$((step + 1))
        printf '\n%s[%d/%d] %s MCP servers%s\n' "${BOLD}" "$step" "$total" "${COMMAND}" "${NC}"
        run_mcp_step codex
    fi

    printf '\n%sCodex %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
    if [[ ${#slices[@]} -gt 0 ]]; then
        warn "Restart Codex to pick up the standalone ${slices[*]}."
        if [[ " ${slices[*]} " == *" skills "* && -L "${codex_plugin_dest}" ]]; then
            warn "The ycc plugin is also linked at ${codex_plugin_dest}; its skills will appear twice. Remove it with: ${CLI_NAME} remove --target codex --intent base"
        fi
    fi
    if [[ $do_plugin -eq 1 ]]; then
        if [[ $native_codex -eq 1 ]]; then
            warn "Restart Codex; ycc@ycc and ycc-mcp@ycc are installed. Rerun this base step to refresh their snapshots."
        elif [[ "${MODE:-local}" == "repo" ]]; then
            warn "Restart Codex; the 'local-ycc-plugins' marketplace in ~/.agents/plugins/marketplace.json now tracks the git-subdir source https://github.com/yandy-r/ystack.git at ./.codex-plugin/ycc on main."
            warn "Updates: rerun this step (or use the Codex /plugins UI) to pull the latest published commit. No local symlink, no custom agents install."
            warn "If you also want to iterate on ycc/ source locally, regenerate the bundle with ./scripts/sync.sh --only codex and switch back to --mode local."
        else
            local codex_plugin_src_msg
            codex_plugin_src_msg="$(realpath "${CODEX_PLUGIN_DIR}")"
            warn "Restart Codex; ycc is installed from the 'local-ycc-plugins' marketplace (${codex_marketplace_plugin_dest} -> ${codex_plugin_src_msg})."
            warn "Codex runs a snapshot of the plugin: after editing ycc/, rerun ${CLI_NAME} sync --target codex --intent base to refresh it."
            warn "If you move or rename this repo, rerun ./install.sh install --target codex --only base to refresh the symlinks."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Codex remove
# ---------------------------------------------------------------------------
# remove_codex_marketplace_entry — drop the ycc entry from
# ~/.agents/plugins/marketplace.json; delete the file if the installer's
# scaffold is all that is left.
remove_codex_marketplace_entry() {
    local dest="${HOME}/.agents/plugins/marketplace.json"
    [[ -f "${dest}" ]] || { info "nothing to remove: ${dest}"; return 0; }
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        python3 - "${dest}" "${SCRIPT_DIR}/scripts" <<'PY'
import json
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from codex_marketplace import SCAFFOLD, _is_ycc

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
plugins = data.get("plugins") if isinstance(data, dict) else None
if not isinstance(plugins, list) or not any(_is_ycc(p) for p in plugins):
    print(f"  [ok] nothing to remove: {path}")
else:
    data["plugins"] = [p for p in plugins if not _is_ycc(p)]
    if data == SCAFFOLD:
        print(f"[dry-run] would remove {path} (only the ycc entry was left)")
    else:
        print(f"[dry-run] would remove marketplace entry ycc from {path}")
PY
        return 0
    fi
    python3 "${SCRIPT_DIR}/scripts/codex_marketplace.py" remove "${dest}"
}

remove_codex_target() {
    validate_only_steps "codex"
    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    local codex_dir="${HOME}/.codex"

    if step_enabled mcp; then
        printf '\n%sCodex: remove MCP servers%s\n' "${BOLD}" "${NC}"
        run_mcp_step codex
    fi
    if step_enabled rules; then
        printf '\n%sCodex: unlink rules (default.rules + CLAUDE.md + AGENTS.md)%s\n' "${BOLD}" "${NC}"
        unlink_owned_link "${SCRIPT_DIR}/.codex-plugin/config/default.rules" "${codex_dir}/rules/default.rules"
        unlink_owned_link "${SCRIPT_DIR}/ycc/settings/rules/CLAUDE.md" "${codex_dir}/CLAUDE.md"
        unlink_owned_link "${SCRIPT_DIR}/ycc/settings/rules/AGENTS.md" "${codex_dir}/AGENTS.md"
    fi
    if step_enabled settings; then
        printf '\n%sCodex: remove managed config (config.toml)%s\n' "${BOLD}" "${NC}"
        config_group_selection codex "$(config_groups_for_target codex)"
        if codex_repository_native_enabled; then
            if [[ -n "${CONFIG_GROUPS}" ]]; then
                codex_native_settings --remove
            fi
        else
            remove_settings "codex-config" "${SCRIPT_DIR}/.codex-plugin/config/config.toml" \
                "${codex_dir}/config.toml" "${CONFIG_GROUPS}" "${CONFIG_SELECT[@]}"
        fi
    fi
    remove_slices codex skills agents
    if step_enabled base; then
        if codex_repository_native_enabled || [[ -f "${HOME}/.config/ycc/codex-native-install.json" ]]; then
            printf '\n%sCodex: remove owned native packages + marketplace%s\n' "${BOLD}" "${NC}"
            run_native_codex_install remove
            { step_enabled agents && ! has_selection agents; } || run_slice codex agents
            printf '\n%sCodex remove complete.%s\n' "${BOLD}" "${NC}"
            return 0
        fi
        printf '\n%sCodex: remove plugin links, cache, custom agents + marketplace entry%s\n' "${BOLD}" "${NC}"
        uninstall_codex_plugin
        unlink_owned_link "${CODEX_PLUGIN_DIR}" "${codex_dir}/plugins/ycc"
        unlink_owned_link "${CODEX_PLUGIN_DIR}" "${HOME}/.agents/plugins/ycc"
        # Whatever cache is left (the legacy hand-written copy, or a snapshot
        # the CLI could not remove) belongs to this marketplace entry.
        if [[ -e "${CODEX_PLUGIN_CACHE}" || -L "${CODEX_PLUGIN_CACHE}" ]]; then
            if ! dry_run_note remove "${CODEX_PLUGIN_CACHE}"; then
                rm -rf "${CODEX_PLUGIN_CACHE}"
                info "removed ${CODEX_PLUGIN_CACHE}"
            fi
        fi
        if [[ "${DRY_RUN:-0}" != 1 ]]; then
            rmdir "$(dirname "${CODEX_PLUGIN_CACHE}")" 2>/dev/null || true
        fi
        # The tracked agents first (unless the agents step just removed all of
        # them; base is never narrowed by --agents),
        # then whatever an older untracked mirror left under shipped names.
        { step_enabled agents && ! has_selection agents; } || run_slice codex agents
        remove_mirrored_entries "${CODEX_AGENTS_DIR}" "${codex_dir}/agents"
        remove_codex_marketplace_entry
    fi
    printf '\n%sCodex remove complete.%s\n' "${BOLD}" "${NC}"
}
