# shellcheck shell=bash
# agents.sh — the cross-tool agents target: implements the per-target contract
# that install.sh dispatches through (see scripts/lib/install/steps.sh):
#   agents_valid_steps, agents_intent_steps <intent>, agents_config_groups,
#   agents_supports_repo_mode, sync_agents_target, remove_agents_target
#
# Sourced by install.sh (never run directly); inherits SCRIPT_DIR and the
# shared helpers from core.sh / steps.sh / bundle.sh.
#
# Ships ycc SKILLS ONLY into ~/.agents/skills/, the flat cross-tool user skill
# directory read by Zed, Codex, opencode, Cursor, Gemini CLI, VS Code/Copilot,
# Amp, Goose and Windsurf. Shared helpers land in the sibling
# ~/.agents/ycc-shared/ (a flat skills dir cannot hold a _shared/ entry).
# Slices (install_slices.py entry mirroring) are used so pre-existing foreign
# skills in ~/.agents/skills/ are never touched; ~/.agents/plugins/ (owned by
# Codex) is never touched either.

# shellcheck disable=SC2034  # read by the agents sync/remove steps.
AGENTS_PLUGIN_DIR="${SCRIPT_DIR}/.agents-plugin"

# Bundle units 'base' mirrors plus the slice sizes. `ycc-shared` carries the
# cross-skill scripts and references that ycc/skills/_shared/... is rewritten
# to at generation time (~/.agents/ycc-shared/...). It MUST stay in this list:
# scripts/validate-agents-install-coverage.sh parses this line and checks
# every <dir> the bundle references is either listed here or explicitly
# allowlisted.
AGENTS_BUNDLE_UNITS=(skills ycc-shared)

# agents_valid_steps — comma-separated steps agents accepts for --only.
agents_valid_steps() { echo "base,skills"; }

# agents_intent_steps <intent> — steps <intent> maps to; empty means no-op.
# base and skills both install the whole skills slice; they stay distinct
# steps so --skills narrows only the skills step (base is never filtered).
agents_intent_steps() {
    case "$1" in
        skills|base) echo "$1" ;;
        *) echo "" ;;
    esac
}

# agents_config_groups — no managed config file for this target.
agents_config_groups() { echo ""; }

# ~/.agents/skills/ is a local directory (no marketplace behind it).
agents_supports_repo_mode() { return 1; }

# agents_omp_hint — W5: OMP's native ycc package is recorded installed and OMP
# would also load these ~/.agents copies; point at the omp dedupe step. Silent
# when omp is absent, nothing is recorded, or the copies are already hidden.
agents_omp_hint() {
    [[ "${COMMAND}" == "remove" || "${DRY_RUN:-0}" == "1" ]] && return 0
    # omp always runs after agents in one run (order_targets), so its dedupe
    # step hides these copies or says so.
    [[ " ${TARGETS[*]:-} " == *" omp "* ]] && return 0
    local helper="${SCRIPT_DIR}/scripts/omp_install.py"
    [[ -f "${helper}" ]] && command -v python3 >/dev/null 2>&1 || return 0
    local line
    line="$(python3 "${helper}" coexistence --warn --if-installed 2>/dev/null)" || return 0
    [[ -z "${line}" ]] || printf '%s\n' "${line}" >&2
}

# ---------------------------------------------------------------------------
# agents sync (skills (+ sibling ycc-shared/) — the only thing this target ships)
# ---------------------------------------------------------------------------
sync_agents_target() {
    validate_only_steps "agents"

    local agents_dir="${HOME}/.agents"
    local scripts_dir="${SCRIPT_DIR}/scripts"

    local do_bundle=0
    step_enabled base && do_bundle=1
    step_enabled skills && do_bundle=1

    if [[ $do_bundle -eq 0 ]]; then
        warn "agents target ran no steps"
        printf '\n%sagents %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
        return 0
    fi

    command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }

    if [[ ! -d "${AGENTS_PLUGIN_DIR}" ]]; then
        err "agents plugin source directory not found: ${AGENTS_PLUGIN_DIR}"
        exit 1
    fi

    require_scripts "${scripts_dir}/generate-agents-skills.sh" "${scripts_dir}/validate-agents-skills.sh"

    mkdir -p "${agents_dir}"

    printf '\n%s[1/3] Generate agents-native bundle (skills)%s\n' "${BOLD}" "${NC}"
    run_build_script "${scripts_dir}/generate-agents-skills.sh"

    printf '\n%s[2/3] Validate generated bundle%s\n' "${BOLD}" "${NC}"
    run_build_script "${scripts_dir}/validate-agents-skills.sh"

    printf '\n%s[3/3] Sync skills to ~/.agents/skills (+ ycc-shared/)%s\n' "${BOLD}" "${NC}"
    # Per-entry slice installs, never rsync --delete: ~/.agents/skills is
    # shared with other tools and user-authored skills.
    agents_skills_slice

    agents_omp_hint

    printf '\n%sagents %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
}

# agents_skills_slice — run the skills slice: whole for 'base' (this
# target's base IS the skills slice, never filtered), else narrowed by --skills.
agents_skills_slice() {
    if step_enabled base; then
        if step_enabled skills && has_selection skills; then
            if [[ "${COMMAND}" == "remove" ]]; then
                warn "agents base removes every skill from ~/.agents/skills; --skills does not narrow this run"
            else
                warn "agents base installs every skill into ~/.agents/skills; --skills does not narrow this run"
            fi
        fi
        run_slice agents skills
    else
        run_slice agents skills select
    fi
}

# ---------------------------------------------------------------------------
# agents remove
# ---------------------------------------------------------------------------
remove_agents_target() {
    validate_only_steps "agents"
    if step_enabled base || step_enabled skills; then
        printf '\n%sagents: remove standalone skills%s\n' "${BOLD}" "${NC}"
        agents_skills_slice
    else
        warn "agents target ran no steps"
    fi
    printf '\n%sagents remove complete.%s\n' "${BOLD}" "${NC}"
}
