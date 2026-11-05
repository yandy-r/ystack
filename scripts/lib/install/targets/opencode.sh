# shellcheck shell=bash
# opencode.sh — the opencode target: implements the per-target contract that
# install.sh dispatches through (see scripts/lib/install/steps.sh):
#   opencode_valid_steps, opencode_intent_steps <intent>, opencode_config_groups,
#   opencode_project_groups, opencode_settings_global_dest, opencode_preflight,
#   opencode_catalog_names, opencode_supports_repo_mode, sync_opencode_target,
#   remove_opencode_target
#
# Sourced by install.sh (never run directly); inherits SCRIPT_DIR and the
# shared helpers from core.sh / steps.sh / bundle.sh / cleanup.sh. The opt-in
# third-party plugin catalog lives in opencode-catalog.sh.
#
# opencode installs ycc only through its native npm plugin
# @yandy-r/ycc-opencode (packages/opencode/ycc-opencode): its V2 setup hook
# registers the skills, agents, ycc:<skill> commands, shared helpers, MCP
# servers, the sensitive-file guard and the AGENTS.md instructions. The base
# step writes that one `plugins` entry into ~/.config/opencode/opencode.json
# (scripts/opencode_package.py), then retires the installer-owned file-copy
# leftovers (run_legacy_cleanup opencode). settings, rules and the opt-in
# catalog stay on the installer.

# shellcheck source=scripts/lib/install/targets/opencode-catalog.sh
source "${SCRIPT_DIR}/scripts/lib/install/targets/opencode-catalog.sh"

# shellcheck disable=SC2034  # read by core.sh (plugins_source) and the catalog.
OPENCODE_PLUGIN_DIR="${SCRIPT_DIR}/.opencode-plugin"
OPENCODE_PACKAGE_HELPER="${SCRIPT_DIR}/scripts/opencode_package.py"
OPENCODE_PACKAGE_NAME="@yandy-r/ycc-opencode"

# opencode_valid_steps — comma-separated steps opencode accepts for --only.
opencode_valid_steps() { echo "base,settings,rules"; }

# Every step previews itself under --dry-run (base skips the local build).
opencode_dry_run_steps() { opencode_valid_steps; }

# opencode_intent_steps <intent> — steps <intent> maps to; empty means no-op.
# On install/sync every component the package carries runs the one base step.
# On remove only 'base' takes the package entry back: it carries every
# component, so a content intent just says so (opencode_remove_package_notice).
opencode_intent_steps() {
    if [[ "${COMMAND:-}" == "remove" ]]; then
        case "$1" in
            base|settings|rules) echo "$1" ;;
            plugins) echo "settings" ;;
            *) echo "" ;;
        esac
        return 0
    fi
    case "$1" in
        base|skills|agents|commands|mcp) echo "base" ;;
        settings|rules) echo "$1" ;;
        # Plugin enablement (goal plugin, opt-in catalog) lives in opencode.json.
        plugins) echo "settings" ;;
        # Hooks and mods are Claude Code (and Cursor) only.
        *) echo "" ;;
    esac
}

# opencode_remove_package_notice — on remove, one notice for the content
# intents the package carries (they remove nothing on their own).
opencode_remove_package_notice() {
    local intent
    local -a named=()
    for intent in "${INTENTS[@]:-}"; do
        case "${intent}" in
            skills|agents|commands|mcp) named+=("${intent}") ;;
        esac
    done
    [[ ${#named[@]} -gt 0 ]] || return 0
    info "opencode: ${named[*]// /, } ship inside ${OPENCODE_PACKAGE_NAME}; removes nothing (remove --intent base drops the whole package entry)"
}

# opencode_config_groups — default managed config groups for opencode.json.
opencode_config_groups() { echo "settings,plugins"; }

# opencode_project_groups — settings-file config groups mergeable at project
# scope (<project>/opencode.json): 'settings' only, through the helper's
# settings-project allowlist. The bundle plugins group is global-only; the
# opt-in catalog plugins stay project-capable and ride PLUGINS_CATALOG_SELECT
# (config_group_selection, opencode_preflight and preflight_step_support allow
# a catalog-only --plugins selection with --project).
opencode_project_groups() { echo "settings"; }

# opencode_settings_global_dest — the user-scope opencode.json (base step
# destination, settings legacy-hint target).
opencode_settings_global_dest() { echo "${HOME}/.config/opencode/opencode.json"; }

# local: a file:// directory entry for this checkout's package; repo: the
# published @yandy-r/ycc-opencode@<version>.
opencode_supports_repo_mode() { return 0; }

# opencode_package <action> [args...] — run the package-entry helper.
opencode_package() {
    local -a command=(python3 "${OPENCODE_PACKAGE_HELPER}" "$@")
    [[ "${DRY_RUN:-0}" == "1" ]] && command+=(--dry-run)
    "${command[@]}"
}

# opencode_build_package — local mode: regenerate, validate and format the
# package the file:// entry loads. Skipped in repo mode (the registry serves
# the published release) and under --dry-run (the build writes the checkout).
opencode_build_package() {
    [[ "${MODE:-local}" == "local" ]] || return 0
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        info "[dry-run] would regenerate and validate ${SCRIPT_DIR}/packages/opencode/ycc-opencode"
        return 0
    fi
    local scripts_dir="${SCRIPT_DIR}/scripts"
    require_scripts "${scripts_dir}/generate-opencode-package.sh" "${scripts_dir}/validate-opencode-package.sh"
    printf '\n%sopencode: generate the native package (%s)%s\n' "${BOLD}" "${OPENCODE_PACKAGE_NAME}" "${NC}"
    run_build_script "${scripts_dir}/generate-opencode-package.sh"
    run_build_script "${scripts_dir}/validate-opencode-package.sh"
    run_repo_style_format_modified
}

# opencode_legacy_cleanup — retire the installer-owned file-copy leftovers. A
# refusal is reported and never fatal: the package route does not depend on it.
opencode_legacy_cleanup() {
    printf '\n%sopencode: retire installer-owned legacy copies%s\n' "${BOLD}" "${NC}"
    if ! run_legacy_cleanup opencode; then
        warn "opencode legacy cleanup kept every file-copy leftover (see above); resolve it, then re-run: ${CLI_NAME:-./install.sh} ${COMMAND} --target opencode"
    fi
}

# opencode_base_step — build (local mode), merge the plugins entry, then
# retire the file-copy leftovers once the package is confirmed loadable
# (opencode_package.py check). A refused (symlinked) config, a user-owned
# ycc-opencode entry, or an unconfirmed package keeps the legacy copy and
# warns; only a real error aborts.
opencode_base_step() {
    opencode_build_package
    local dest rc=0
    dest="$(opencode_settings_global_dest)"
    printf '\n%sopencode: register %s in %s%s\n' "${BOLD}" "${OPENCODE_PACKAGE_NAME}" "${dest}" "${NC}"
    [[ "${DRY_RUN:-0}" == "1" || -L "$(dirname "${dest}")" ]] || mkdir -p "$(dirname "${dest}")"
    local -a force=()
    [[ "${FORCE:-0}" == "1" ]] && force=(--force)
    opencode_package sync --mode "${MODE:-local}" --destination "${dest}" "${force[@]}" || rc=$?
    case "${rc}" in
        0) ;;
        2|4)
            warn "opencode: ${OPENCODE_PACKAGE_NAME} not registered (see above); file-copy install retained"
            return 0
            ;;
        *)
            err "could not write the ${OPENCODE_PACKAGE_NAME} plugins entry into ${dest}"
            exit 1
            ;;
    esac
    rc=0
    python3 "${OPENCODE_PACKAGE_HELPER}" check --mode "${MODE:-local}" || rc=$?
    if [[ ${rc} -eq 0 ]]; then
        opencode_legacy_cleanup
    else
        warn "opencode: legacy cleanup skipped until ${OPENCODE_PACKAGE_NAME} is confirmed loadable (see above)"
    fi
    info "Restart opencode (>= 2.0.30) to load ${OPENCODE_PACKAGE_NAME}; its commands are /ycc:<skill>."
}

# opencode_settings_step — merge (or remove) the managed opencode.json keys
# and the opt-in catalog plugins at the settings scope.
opencode_settings_step() {
    opencode_settings_paths
    config_group_selection opencode "$(config_groups_for_target opencode)"
    if [[ "${COMMAND}" == "remove" ]]; then
        printf '\n%sopencode: remove managed config (%s)%s\n' "${BOLD}" "${OPENCODE_SETTINGS_FILE}" "${NC}"
        # Catalog first: its leaves (agents.<x>.disabled) sit inside bundle-owned
        # agents entries, which the bundle remove only takes back whole.
        opencode_catalog_remove
        remove_settings "opencode-config" "${OPENCODE_PLUGIN_DIR}/opencode.json" \
            "${OPENCODE_SETTINGS_FILE}" "${CONFIG_GROUPS}" "${CONFIG_SELECT[@]}"
    else
        printf '\n%sopencode: merge config into %s%s\n' "${BOLD}" "${OPENCODE_SETTINGS_FILE}" "${NC}"
        [[ "${DRY_RUN:-0}" == "1" ]] || mkdir -p "$(dirname "${OPENCODE_SETTINGS_FILE}")"
        # Merge managed keys only: per-machine model overrides, provider
        # credentials and unknown keys in the user's opencode.json are kept.
        if [[ -n "${CONFIG_GROUPS}" ]]; then
            merge_settings_config "opencode-config" "${OPENCODE_PLUGIN_DIR}/opencode.json" \
                "${OPENCODE_SETTINGS_FILE}" "${CONFIG_GROUPS}" "${CONFIG_SELECT[@]}"
        fi
    fi
    if [[ "${OPENCODE_SETTINGS_FILE}" != "$(opencode_settings_global_dest)" ]]; then
        settings_legacy_hint opencode opencode-config "$(opencode_settings_global_dest)"
    fi
    opencode_catalog_legacy_hint "${COMMAND}"
    [[ "${COMMAND}" == "remove" ]] || opencode_catalog_sync
}

# opencode_rules_step — link (or unlink) the global AGENTS.md. The package's
# context hook pushes the same text only when the request does not already
# carry it, so the linked file is never injected twice.
opencode_rules_step() {
    local src="${OPENCODE_PLUGIN_DIR}/AGENTS.md" dest="${HOME}/.config/opencode/AGENTS.md"
    if [[ "${COMMAND}" == "remove" ]]; then
        printf '\n%sopencode: unlink rules (AGENTS.md)%s\n' "${BOLD}" "${NC}"
        unlink_owned_link "${src}" "${dest}"
    else
        printf '\n%sopencode: link rules (AGENTS.md)%s\n' "${BOLD}" "${NC}"
        # Native global rules path: https://opencode.ai/docs/rules
        link_rules_file "${src}" "${dest}"
    fi
}

# ---------------------------------------------------------------------------
# opencode sync (base: the npm plugin entry + legacy cleanup; settings; rules)
# ---------------------------------------------------------------------------
sync_opencode_target() {
    validate_only_steps "opencode"
    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    local ran=0
    if step_enabled base; then opencode_base_step; ran=1; fi
    if step_enabled settings; then opencode_settings_step; ran=1; fi
    if step_enabled rules; then opencode_rules_step; ran=1; fi
    [[ ${ran} -eq 1 ]] || warn "opencode target ran no steps"
    printf '\n%sopencode %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
}

# ---------------------------------------------------------------------------
# opencode remove (base: take the entry back + legacy cleanup; settings; rules)
# ---------------------------------------------------------------------------
remove_opencode_target() {
    validate_only_steps "opencode"
    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    local ran=0 notice
    notice="$(opencode_remove_package_notice)"
    [[ -n "${notice}" ]] && { printf '%s\n' "${notice}"; ran=1; }
    if step_enabled rules; then opencode_rules_step; ran=1; fi
    if step_enabled settings; then opencode_settings_step; ran=1; fi
    if step_enabled base; then
        local dest rc=0
        dest="$(opencode_settings_global_dest)"
        printf '\n%sopencode: remove %s from %s%s\n' "${BOLD}" "${OPENCODE_PACKAGE_NAME}" "${dest}" "${NC}"
        local -a force=()
        [[ "${FORCE:-0}" == "1" ]] && force=(--force)
        opencode_package remove --destination "${dest}" "${force[@]}" || rc=$?
        if [[ ${rc} -eq 2 ]]; then
            warn "opencode: ${dest} left unchanged (see above); legacy cleanup skipped"
        elif [[ ${rc} -ne 0 ]]; then
            err "could not remove the ${OPENCODE_PACKAGE_NAME} plugins entry from ${dest}"
            exit 1
        else
            opencode_legacy_cleanup
        fi
        ran=1
    fi
    [[ ${ran} -eq 1 ]] || warn "opencode target ran no steps"
    printf '\n%sopencode remove complete.%s\n' "${BOLD}" "${NC}"
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
