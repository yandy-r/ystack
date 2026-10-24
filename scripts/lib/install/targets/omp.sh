# shellcheck shell=bash
# omp.sh — the OMP (oh-my-pi) target: implements the per-target contract that install.sh
# dispatches through (see scripts/lib/install/steps.sh):
#   omp_valid_steps, omp_intent_steps <intent>, omp_config_groups,
#   omp_supports_repo_mode, omp_reads_agents_skills, sync_omp_target, remove_omp_target
# plus the optional hooks the generic shell calls when they exist:
#   omp_preflight, omp_in_all, omp_all_skip_reason, omp_repo_mode_hint, omp_project_steps,
#   omp_dry_run_steps
#
# Sourced by install.sh (never run directly); inherits SCRIPT_DIR and the
# shared helpers from core.sh / steps.sh / bundle.sh.
#
# The native OMP packages are delivered only through 'omp plugin' (marketplace
# add + install/upgrade/uninstall); scripts/omp_install.py owns every omp call,
# the ownership state and the dry-run previews. This file maps the installer's
# flags onto that helper. The default-on 'dedupe' step (owned skills.ignoredSkills
# aliases of ycc skills OMP also reads from ~/.agents, ~/.codex or opencode) and
# the opt-in user-scope 'settings' (managed leaves in <agentDir>/config.yml) and
# 'rules' (<agentDir>/AGENTS.md symlink) steps use the shared
# merge_settings_config / link_rules_file helpers.

OMP_INSTALL_HELPER="${SCRIPT_DIR}/scripts/omp_install.py"

# omp_valid_steps — comma-separated steps omp accepts for --only.
omp_valid_steps() { echo "base,dedupe,settings,rules"; }

# omp_dry_run_steps — every omp step previews itself under --dry-run.
omp_dry_run_steps() { omp_valid_steps; }

# omp_intent_steps <intent> — steps <intent> maps to; empty means no-op.
omp_intent_steps() {
    case "$1" in
        # One native package carries skills, agents and commands together;
        # plugin enablement is the 'omp plugin install' itself. dedupe hides
        # the duplicate ycc skills that install exposes.
        base|plugins) echo "base,dedupe" ;;
        settings) echo "settings" ;;
        rules) echo "rules" ;;
        *) echo "" ;;
    esac
}

# omp_config_groups — the one managed group in <agentDir>/config.yml
# (modelRoles.{default,slow,task}, retry.fallbackChains.{default,slow,task},
# tools.approvalMode); config_groups_for_target
# filters by intent name, so it must be 'settings'.
omp_config_groups() { echo "settings"; }

# omp_supports_repo_mode — the upstream repo carries an OMP catalog only while a
# package row is listed in ycc/settings/packages.json (listed since YAN-1180).
omp_supports_repo_mode() {
    python3 "${OMP_INSTALL_HELPER}" listed >/dev/null 2>&1
}

# OMP reads ~/.agents/skills too, but the native package cannot shed its skills,
# so skills consolidation cannot apply; the dedupe step hides ycc's own copies.
omp_reads_agents_skills() { return 1; }

# omp_project_steps — steps that honour --project (a project-scope install).
# settings and rules stay user scope only: ycc never writes .omp/config.yml,
# .omp/rules or .omp/AGENTS.md, so the generic gate rejects them with --project.
# dedupe always writes the USER config.yml: the ~/.agents duplicate is
# user-level, and a project install sees it too.
omp_project_steps() { echo "base,dedupe"; }

# omp_available_reason — empty when omp >= MIN_OMP_VERSION is on PATH, else the
# helper's reason.
omp_available_reason() {
    local reason
    command -v python3 >/dev/null 2>&1 || { echo "python3 not found on PATH"; return 0; }
    if reason="$(python3 "${OMP_INSTALL_HELPER}" available 2>&1 >/dev/null)"; then
        return 0
    fi
    echo "${reason:-omp is unavailable}"
}

# omp_in_all — '--target all' includes omp only when it can install there.
omp_in_all() {
    [[ -z "$(omp_available_reason)" ]] && omp_supports_repo_mode
}

# omp_all_skip_reason — why '--target all' skipped omp.
omp_all_skip_reason() { echo "needs omp >= 18.12.2 on PATH and a listed OMP package"; }

# omp_repo_mode_hint — why --mode repo is refused when no OMP row is listed.
omp_repo_mode_hint() { echo "omp needs a listed OMP package"; }

# omp_preflight — fail before any target runs when omp cannot be driven. Every
# omp step runs python helpers that import PyYAML (the package build and
# omp_install.py through the shared generators, and the config.yml merge).
omp_preflight() {
    local reason
    if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import yaml' >/dev/null 2>&1; then
        err "--target omp needs PyYAML for python3; install it with: python3 -m pip install --user pyyaml"
        exit 1
    fi
    reason="$(omp_available_reason)"
    if [[ -n "${reason}" ]]; then
        err "omp >= 18.12.2 is required for --target omp"
        err "  ${reason}"
        exit 1
    fi
    if [[ "$(omp_scope)" == "project" ]]; then
        local root home
        root="$(cd "$(project_root)" && pwd -P)"
        home="$(cd "${HOME}" && pwd -P)"
        if [[ "${root}" == "${home}" ]]; then
            err "--project at \$HOME: omp project scope needs a project directory (cd into a project, or use --global)"
            exit 1
        fi
    fi
}

# omp_scope — 'user' or 'project' for omp's --scope (step_scope says 'global').
omp_scope() {
    if [[ "$(step_scope omp base)" == "project" ]]; then echo "project"; else echo "user"; fi
}

# run_native_omp_install <install|remove> — dispatch to the helper with the
# run's scope, project root, mode and dry-run/force flags.
run_native_omp_install() {
    local -a command=(python3 "${OMP_INSTALL_HELPER}" "$1")
    [[ "$1" == "install" ]] && command+=(--packages "${PACKAGE:-}")
    command+=(--scope "$(omp_scope)" --project-root "$(project_root)")
    if [[ "$1" == "install" ]]; then
        command+=(--mode "${MODE:-local}")
        [[ "${FORCE:-0}" == "1" ]] && command+=(--force)
    fi
    [[ "${DRY_RUN:-0}" == "1" ]] && command+=(--dry-run)
    "${command[@]}"
}

# omp_agent_dir — the active profile's agent directory ('omp config path').
# 'omp config path' is not read-only (it creates agent.db and config.yml and
# migrates settings.json), so a dry-run never calls omp: it previews against the
# default agent dir (${PI_CODING_AGENT_DIR:-~/.omp/agent}) and says so.
omp_agent_dir() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        local dir="${PI_CODING_AGENT_DIR:-${HOME}/.omp/agent}"
        info "[dry-run] assuming the default omp agent dir ${dir} (omp config path is not run)" >&2
        echo "${dir}"
        return 0
    fi
    python3 "${OMP_INSTALL_HELPER}" agent-dir || exit 1
}

# omp_config_dest <agent_dir> — the user config file to merge into: an existing
# config.yaml when it alone exists, else config.yml.
omp_config_dest() {
    if [[ -e "$1/config.yaml" && ! -e "$1/config.yml" && ! -L "$1/config.yml" ]]; then
        echo "$1/config.yaml"
    else
        echo "$1/config.yml"
    fi
}

# omp_merge_settings <agent_dir> [helper-args...] — merge (or with --remove,
# strip) the ycc-owned config.yml leaves; --dry-run reports without writing.
omp_merge_settings() {
    local agent_dir="$1"
    local groups
    groups="$(config_groups_for_target omp)"
    [[ -n "${groups}" ]] || return 0
    local -a extra=("${@:2}")
    merge_settings_config omp-config "${SCRIPT_DIR}/ycc/settings/omp/config.yml" \
        "$(omp_config_dest "${agent_dir}")" "${groups}" "${extra[@]}"
}

# omp_settings_step <agent_dir> / omp_rules_step <agent_dir> — the opt-in
# user-scope steps; --dry-run prints the planned merge and link only.
omp_settings_step() {
    printf '\n%somp: merge ycc settings into %s (user scope)%s\n' "${BOLD}" "$(omp_config_dest "$1")" "${NC}"
    omp_merge_settings "$1"
}

omp_rules_step() {
    local src="${SCRIPT_DIR}/ycc/settings/rules/AGENTS.md" dest="$1/AGENTS.md"
    printf '\n%somp: link rules (AGENTS.md) into %s (user scope)%s\n' "${BOLD}" "$1" "${NC}"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        info "[dry-run] would link ${dest} -> ${src}"
        return 0
    fi
    mkdir -p "$1"
    link_rules_file "${src}" "${dest}"
}

# omp_dedupe_step <agent_dir> [--remove] — merge (or take back) the owned
# skills.ignoredSkills aliases, then print the coexistence warnings (W1–W4).
# The merge source is a temp file 'omp_install.py coexistence --emit' writes.
# The merge also takes back owned aliases the emit no longer lists, and an
# empty emit takes back every owned alias (nothing is read or written when ycc
# owns none). A removal needs no source entries: list-union takes back exactly
# the items it recorded.
omp_dedupe_step() {
    local agent_dir="$1" mode="${2:-}" dest tmp rc=0
    dest="$(omp_config_dest "${agent_dir}")"
    tmp="$(mktemp "${TMPDIR:-/tmp}/ycc-omp-dedupe.XXXXXX")"
    # merge_settings_config can exit outright (missing helper/python3); the
    # scoped EXIT trap still deletes <tmp> then.
    trap 'rm -f "${tmp}"' EXIT
    omp_dedupe_apply "${dest}" "${tmp}" "${mode}" || rc=$?
    rm -f "${tmp}"
    trap - EXIT
    [[ ${rc} -eq 0 ]] || exit 1
}

# omp_dedupe_apply <dest> <tmp> [--remove] — omp_dedupe_step's body; its own
# failures return non-zero so the caller deletes <tmp> before exiting.
omp_dedupe_apply() {
    local dest="$1" tmp="$2" mode="$3"
    local -a extra=()
    if [[ "${mode}" == "--remove" ]]; then
        printf '\n%somp: take back ycc skills.ignoredSkills entries from %s%s\n' "${BOLD}" "${dest}" "${NC}"
        printf '{}\n' >"${tmp}" || return 1
        merge_settings_config omp-config "${tmp}" "${dest}" dedupe --remove "${extra[@]}" || return 1
        return 0
    fi
    printf '\n%somp: hide duplicate ycc skills via skills.ignoredSkills in %s (user scope)%s\n' "${BOLD}" "${dest}" "${NC}"
    local count
    count="$(python3 "${OMP_INSTALL_HELPER}" coexistence --packages "${PACKAGE:-}" --emit "${tmp}")" || return 1
    if [[ "${count}" == "0" ]]; then
        info "no ycc skills from other runtimes' dirs to hide"
        # Aliases hidden by an earlier run whose ycc copies are gone come back.
        printf '{}\n' >"${tmp}" || return 1
        merge_settings_config omp-config "${tmp}" "${dest}" dedupe --remove "${extra[@]}" || return 1
        omp_coexistence_warn || return 1
        return 0
    fi
    merge_settings_config omp-config "${tmp}" "${dest}" dedupe "${extra[@]}" || return 1
    omp_coexistence_warn --hidden "${dest}" || return 1
}

# omp_coexistence_warn [--hidden <config>] — W1 (with --hidden), else W2; W3, W4.
omp_coexistence_warn() {
    local -a command=(python3 "${OMP_INSTALL_HELPER}" coexistence --packages "${PACKAGE:-}" --warn "$@")
    [[ "${DRY_RUN:-0}" == "1" ]] && command+=(--dry-run)
    "${command[@]}" || return 1
}

# ---------------------------------------------------------------------------
# omp sync (base: build the OMP packages, then install them natively)
# ---------------------------------------------------------------------------
sync_omp_target() {
    validate_only_steps "omp"
    local ran=0
    if step_enabled base || step_enabled dedupe || step_enabled settings || step_enabled rules; then
        command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    fi
    if step_enabled base; then
        sync_omp_base
        ran=1
    fi
    if step_enabled dedupe || step_enabled settings || step_enabled rules; then
        local agent_dir
        agent_dir="$(omp_agent_dir)" || exit 1
        if step_enabled dedupe; then
            omp_dedupe_step "${agent_dir}"
            ran=1
        fi
        if step_enabled settings; then
            omp_settings_step "${agent_dir}"
            ran=1
        fi
        if step_enabled rules; then
            omp_rules_step "${agent_dir}"
            ran=1
        fi
    fi
    # base without dedupe (--only base): still say what OMP loads twice (W2–W4).
    if step_enabled base && ! step_enabled dedupe; then
        omp_coexistence_warn || exit 1
    fi
    [[ ${ran} -eq 1 ]] || warn "omp target ran no steps"
    printf '\n%somp %s complete.%s\n' "${BOLD}" "${COMMAND}" "${NC}"
}

# sync_omp_base — build the OMP packages, then install them natively.
sync_omp_base() {
    # A dry-run never regenerates repo files, and --mode repo installs from the
    # upstream catalog, so neither needs the local package build.
    local do_build=1
    [[ "${DRY_RUN:-0}" == "1" || "${MODE:-local}" == "repo" ]] && do_build=0

    local scripts_dir="${SCRIPT_DIR}/scripts"
    local -a passes=(skills agents commands packages)
    local total=1 step=0 pass
    [[ ${do_build} -eq 1 ]] && total=3

    if [[ ${do_build} -eq 1 ]]; then
        # Generator/validator passes: generate-omp-<pass>.sh.
        for pass in "${passes[@]}"; do
            require_scripts "${scripts_dir}/generate-omp-${pass}.sh" "${scripts_dir}/validate-omp-${pass}.sh"
        done

        step=$((step + 1))
        printf '\n%s[%d/%d] Generate OMP-native packages (%s)%s\n' "${BOLD}" "$step" "$total" "${passes[*]}" "${NC}"
        for pass in "${passes[@]}"; do
            run_build_script "${scripts_dir}/generate-omp-${pass}.sh"
        done

        step=$((step + 1))
        printf '\n%s[%d/%d] Validate generated packages%s\n' "${BOLD}" "$step" "$total" "${NC}"
        for pass in "${passes[@]}"; do
            run_build_script "${scripts_dir}/validate-omp-${pass}.sh"
        done
    elif [[ "${DRY_RUN:-0}" == "1" ]]; then
        info "dry-run: skipping the OMP package build"
    fi

    step=$((step + 1))
    printf '\n%s[%d/%d] Install native OMP packages (%s scope)%s\n' "${BOLD}" "$step" "$total" "$(omp_scope)" "${NC}"
    run_native_omp_install install
}

# omp_dedupe_unneeded — true when, after this run's 'base' removal, ycc has no
# recorded install left in the active omp profile (other scopes and projects
# count). The scope being removed is excluded, so a dry-run, which leaves the
# record untouched, reaches the same answer. 'recorded' exits 0 when installs
# remain, 3 when none do, 2 on errors (the entries are then kept).
omp_dedupe_unneeded() {
    local rc=0
    python3 "${OMP_INSTALL_HELPER}" recorded --except-scope "$(omp_scope)" \
        --project-root "$(project_root)" >/dev/null || rc=$?
    [[ ${rc} -eq 3 ]]
}

# ---------------------------------------------------------------------------
# omp remove (base: uninstall the ycc-owned native installs, and take back the
# dedupe entries; dedupe: only those entries; settings: strip the unchanged ycc
# leaves; rules: drop the owned AGENTS.md symlink)
# ---------------------------------------------------------------------------
remove_omp_target() {
    validate_only_steps "omp"
    local ran=0
    if step_enabled base || step_enabled dedupe || step_enabled settings || step_enabled rules; then
        command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found"; exit 1; }
    fi
    # The dedupe entries go with the last ycc install of this profile (so
    # 'remove --only base' restores the prior state, and removing a project
    # install keeps them while the user install still needs them). Only a
    # dedupe-only removal ('--only dedupe') takes them back unconditionally;
    # with base (also '--intent base|plugins') the last-install rule decides.
    # They go before the packages, so a refused config.yml stops the removal
    # before anything changed.
    local take_back=0
    if step_enabled base; then
        omp_dedupe_unneeded && take_back=1
    elif step_enabled dedupe; then
        take_back=1
    fi
    if [[ ${take_back} -eq 1 ]]; then
        local dedupe_dir
        dedupe_dir="$(omp_agent_dir)" || exit 1
        omp_dedupe_step "${dedupe_dir}" --remove
        ran=1
    elif step_enabled base; then
        info "omp: kept the skills.ignoredSkills entries (ycc is still installed in another omp scope)"
    fi
    if step_enabled base; then
        printf '\n%somp: remove native OMP packages (%s scope)%s\n' "${BOLD}" "$(omp_scope)" "${NC}"
        run_native_omp_install remove
        ran=1
    fi
    if step_enabled settings || step_enabled rules; then
        local agent_dir
        agent_dir="$(omp_agent_dir)" || exit 1
        if step_enabled settings; then
            printf '\n%somp: remove ycc settings from %s%s\n' "${BOLD}" "$(omp_config_dest "${agent_dir}")" "${NC}"
            omp_merge_settings "${agent_dir}" --remove
            ran=1
        fi
        if step_enabled rules; then
            local src="${SCRIPT_DIR}/ycc/settings/rules/AGENTS.md" dest="${agent_dir}/AGENTS.md"
            printf '\n%somp: unlink rules (AGENTS.md)%s\n' "${BOLD}" "${NC}"
            if [[ "${DRY_RUN:-0}" == "1" ]]; then
                info "[dry-run] would unlink ${dest} if it links to ${src}"
            else
                unlink_owned_link "${src}" "${dest}"
            fi
            ran=1
        fi
    fi
    [[ ${ran} -eq 1 ]] || warn "omp target ran no steps"
    printf '\n%somp remove complete.%s\n' "${BOLD}" "${NC}"
}
