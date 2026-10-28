# shellcheck shell=bash
# steps.sh — step and intent selection, target resolution and preflight.
#
# Per-target data comes from scripts/lib/install/targets/<t>.sh; the
# *_for_target functions and supports_repo_mode dispatch to them by name.
#
# Sourced by install.sh (never run directly); reads its arg globals (INTENTS,
# ONLY_STEPS, EXCLUSIVE_STEPS, SETTINGS, RULES, MCP, HOOKS, SCOPE, MODE) and
# ALL_TARGETS at call time.

# shellcheck disable=SC2034  # VALID_INTENTS is read by install.sh's arg validation.
VALID_INTENTS=(base skills agents commands settings rules mcp hooks plugins mods)

# shellcheck source=scripts/lib/install/packages.sh
source "${SCRIPT_DIR}/scripts/lib/install/packages.sh"

# ---------------------------------------------------------------------------
# Step selection
# ---------------------------------------------------------------------------
# step_enabled <step> <target_valid_steps_csv>
# Decides whether <step> should run for the current target.
# - If --only was passed: run iff <step> is in the --only list.
# - Else: 'base' and 'dedupe' (omp) always run; 'settings'/'mcp' run only if
#   their flag is set.
# The target's valid steps are used for validation by validate_only_steps().
step_enabled() {
    local step="$1"
    if [[ "${EXCLUSIVE_STEPS:-0}" == "1" ]]; then
        # Exclusive mode: nothing runs unless it was explicitly selected, so a
        # target whose intents are all no-ops must not silently fall back to
        # 'base'.
        local s
        for s in "${ONLY_STEPS[@]}"; do
            [[ "$s" == "$step" ]] && return 0
        done
        return 1
    fi
    if [[ ${#ONLY_STEPS[@]} -gt 0 ]]; then
        local s
        for s in "${ONLY_STEPS[@]}"; do
            [[ "$s" == "$step" ]] && return 0
        done
        return 1
    fi
    case "$step" in
        base)     return 0 ;;
        dedupe)   return 0 ;;
        settings) [[ "${SETTINGS:-0}" == "1" ]] ;;
        rules)    [[ "${RULES:-0}" == "1" ]] ;;
        mcp)      [[ "${MCP:-0}" == "1" ]] ;;
        hooks)    [[ "${HOOKS:-0}" == "1" ]] ;;
        *)        return 1 ;;
    esac
}

# valid_steps_for_target <target>
# Echo the comma-separated steps <target> supports for --only.
valid_steps_for_target() {
    if ! is_known_target "$1"; then
        err "valid_steps_for_target: unknown target '$1'"
        exit 1
    fi
    "${1}_valid_steps"
}

# step_valid_for_any_target <step> — true when a resolved target accepts <step>.
step_valid_for_any_target() {
    local t
    for t in "${TARGETS[@]}"; do
        [[ ",$(valid_steps_for_target "${t}")," == *",$1,"* ]] && return 0
    done
    return 1
}

# validate_only_steps <target> [quiet]
# If --only was passed, ensure every requested step is valid for the target.
# A slice step (skills/agents/commands) the target has no home for is skipped
# with a notice instead, so '--target all --only commands' still works; so is
# any step under --target all that another resolved target accepts. Pass
# 'quiet' to suppress that notice (preflight).
validate_only_steps() {
    local target="$1"
    local quiet="${2:-}"
    # The agents target added by resolve_skills_home only acts on base/skills;
    # the rest of the run's --only list belongs to the other targets.
    [[ "${target}" == "agents" && "${AGENTS_AUTO_ADDED:-0}" == "1" ]] && return 0
    local valid_csv
    valid_csv="$(valid_steps_for_target "${target}")"
    if [[ "${EXCLUSIVE_STEPS:-0}" != "1" && ${#ONLY_STEPS[@]} -eq 0 ]]; then
        return 0
    fi

    local -a valid
    IFS=',' read -r -a valid <<< "$valid_csv"
    local requested found v
    for requested in "${ONLY_STEPS[@]}"; do
        found=0
        for v in "${valid[@]}"; do
            [[ "$v" == "$requested" ]] && { found=1; break; }
        done
        if [[ $found -eq 0 && " skills agents commands " == *" ${requested} "* ]]; then
            [[ -n "${quiet}" ]] || warn "step '${requested}' is not supported by target '${target}' — skipping"
        elif [[ $found -eq 0 && "${TARGET:-}" == "all" ]] && step_valid_for_any_target "${requested}"; then
            # '--target all --only mcp': the targets without the step sit it out.
            [[ -n "${quiet}" ]] || warn "step '${requested}' is not supported by target '${target}' — skipping"
        elif [[ $found -eq 0 ]]; then
            err "--only step '${requested}' is not valid for target '${target}' (valid: ${valid_csv})"
            exit 1
        fi
    done
}

# ---------------------------------------------------------------------------
# Intent mapping ('sync' subcommand)
# ---------------------------------------------------------------------------
# Intents describe WHAT the user wants synced; each target maps them onto the
# steps it actually supports. An intent a target cannot execute is reported and
# skipped rather than silently falling back to another step.

# intent_steps_for_target <target> <intent>
# Echo the comma-separated steps <intent> maps to for <target>. Empty output
# means the intent is a no-op there.
intent_steps_for_target() {
    is_known_target "$1" || { echo ""; return 0; }
    "${1}_intent_steps" "$2"
}

# configure_intents_for_target <target>
# Translate INTENTS into ONLY_STEPS for <target> and enable exclusive mode.
configure_intents_for_target() {
    local target="$1"
    local -a steps=()
    local intent mapped step

    for intent in "${INTENTS[@]}"; do
        mapped="$(intent_steps_for_target "${target}" "${intent}")"
        if [[ -z "${mapped}" ]]; then
            # The auto-added agents target only carries skills; its other
            # intents belong to the other targets.
            [[ "${target}" == "agents" && "${AGENTS_AUTO_ADDED:-0}" == "1" ]] && continue
            warn "intent '${intent}' is not supported by target '${target}' — skipping"
            continue
        fi
        local -a mapped_steps=()
        IFS=',' read -r -a mapped_steps <<< "${mapped}"
        for step in "${mapped_steps[@]}"; do
            local seen=0 existing
            for existing in "${steps[@]:-}"; do
                [[ "${existing}" == "${step}" ]] && seen=1 && break
            done
            [[ ${seen} -eq 0 ]] && steps+=("${step}")
        done
    done

    ONLY_STEPS=("${steps[@]:-}")
    # Drop the empty element bash leaves behind when expanding an empty array.
    if [[ ${#ONLY_STEPS[@]} -eq 1 && -z "${ONLY_STEPS[0]}" ]]; then
        ONLY_STEPS=()
    fi
    EXCLUSIVE_STEPS=1
}

intent_requested() {
    local requested="$1"
    local intent
    for intent in "${INTENTS[@]:-}"; do
        [[ "${intent}" == "${requested}" ]] && return 0
    done
    return 1
}

# config_groups_for_target <target>
# Return managed config groups selected for a structured settings file.
config_groups_for_target() {
    local target="$1"
    is_known_target "${target}" || return 0
    local defaults
    defaults="$("${target}_config_groups")"
    if [[ -n "${PACKAGE:-}" ]]; then
        # Registration owns enablement; settings-only must not enable an
        # unregistered or foreign plugin. The Codex legacy-cache path writes
        # exactly the local ycc enablement leaf itself (see codex.sh).
        if [[ "${target}" == "claude" ]] && step_enabled hooks; then
            echo "settings,hooks"
        else
            echo "settings"
        fi
        return 0
    fi
    local groups_csv="${defaults}"
    # The native project plugin carries its own hook activation; never write
    # the global hooks group alongside it. Settings-only removal still owns
    # that legacy group because its hooks step is not enabled.
    if [[ "${target}" == "claude" ]] && step_enabled hooks \
        && [[ "$(step_scope claude hooks)" == "project" ]]; then
        groups_csv="${defaults//,hooks/}"
    fi
    defaults="${groups_csv}"
    if [[ ${#INTENTS[@]} -eq 0 ]]; then
        echo "${defaults}"
        return 0
    fi

    # Filtered order is always settings,plugins,hooks (kept from the original
    # table); only groups the target manages by default are eligible.
    local -a groups=()
    local group
    for group in settings plugins hooks; do
        intent_requested "${group}" || continue
        [[ ",${defaults}," == *",${group},"* ]] && groups+=("${group}")
    done
    local IFS=','
    echo "${groups[*]}"
}

# run_target <target> <function>
# Configure intent mapping (sync mode only), drop steps a --<kind> selection
# cannot narrow on <target> (select.sh), then run the target.
run_target() {
    local target="$1"
    local fn="$2"
    if [[ -n "${PACKAGE:-}" ]]; then
        package_configure_steps "$(package_steps_csv "${target}")"
    elif [[ ${#INTENTS[@]} -gt 0 ]]; then
        configure_intents_for_target "${target}"
    fi
    # --only steps are shared by every target: the skip must not leak.
    local -a only_saved=(${ONLY_STEPS[@]+"${ONLY_STEPS[@]}"})
    local exclusive_saved="${EXCLUSIVE_STEPS:-0}"
    skip_unselectable_steps "${target}"
    skip_unscoped_settings "${target}"
    skip_dry_run_steps "${target}"
    # --with-deps extends the selection for this target only (select.sh).
    local skills_saved="${SELECTION[skills]:-}" agents_saved="${SELECTION[agents]:-}" commands_saved="${SELECTION[commands]:-}"
    expand_with_deps "${target}"
    "${fn}"
    SELECTION[skills]="${skills_saved}"
    SELECTION[agents]="${agents_saved}"
    SELECTION[commands]="${commands_saved}"
    ONLY_STEPS=(${only_saved[@]+"${only_saved[@]}"})
    EXCLUSIVE_STEPS="${exclusive_saved}"
}
# skip_unscoped_settings <target> — no-op unless the settings step would run
# at the default scope (no --project/--global, no --package). Targets without
# <t>_project_groups (cursor, omp) then have no project settings file to
# write, so the step is dropped with a notice naming the --global command
# that restores the old behavior; the same skip applies when the project
# root is $HOME. Rewrites ONLY_STEPS (exclusive mode), like
# skip_unselectable_steps.
skip_unscoped_settings() {
    local target="$1" step
    [[ -z "${SCOPE}" && -z "${PACKAGE:-}" ]] || return 0
    # Only a target with a settings step can skip it: with the flag form
    # (or --only settings) step_enabled is true for targets like agents that
    # have no settings step at all.
    [[ ",$(valid_steps_for_target "${target}")," == *",settings,"* ]] || return 0
    step_enabled settings || return 0
    local reason="" note="" dest=""
    if declare -F "${target}_settings_scope_note" >/dev/null; then
        note="$("${target}_settings_scope_note")"
    fi
    if declare -F "${target}_settings_global_dest" >/dev/null; then
        dest="$("${target}_settings_global_dest")"
    fi
    local verb="write"
    [[ "${COMMAND}" == "remove" ]] && verb="remove from"
    if [[ -z "$(target_project_groups "${target}")" ]]; then
        reason="${target}: settings have no project scope — skipped (nothing written)."
        [[ -n "${note}" ]] && reason+=" ${note}"
        [[ -n "${dest}" ]] && reason+=" Pass --global to ${verb} ${dest}."
    else
        reason="$(project_home_conflict "settings project scope")"
        if [[ -n "${reason}" ]]; then
            reason="${target}: settings default to project scope, but the project root is \$HOME — skipped. cd into a project, or pass --global."
        fi
    fi
    [[ -n "${reason}" ]] || return 0
    warn "${reason}"
    local -a kept=()
    for step in $(valid_steps_for_target "${target}" | tr ',' ' '); do
        step_enabled "${step}" || continue
        [[ "${step}" == "settings" ]] || kept+=("${step}")
    done
    ONLY_STEPS=(${kept[@]+"${kept[@]}"})
    # shellcheck disable=SC2034  # EXCLUSIVE_STEPS is read by step_enabled.
    EXCLUSIVE_STEPS=1
}

# skip_dry_run_steps <target> — with --dry-run, keep only the steps <target>
# can preview (<target>_dry_run_steps, which may depend on COMMAND; none when
# undefined) and say so for every other selected step. Rewrites ONLY_STEPS
# (exclusive mode), like skip_unselectable_steps.
skip_dry_run_steps() {
    local target="$1" step previewable=""
    [[ "${DRY_RUN:-0}" == "1" ]] || return 0
    declare -F "${target}_dry_run_steps" >/dev/null && previewable="$("${target}_dry_run_steps")"
    local -a kept=()
    for step in $(valid_steps_for_target "${target}" | tr ',' ' '); do
        step_enabled "${step}" || continue
        if [[ ",${previewable}," == *",${step},"* ]]; then
            kept+=("${step}")
        else
            info "dry-run: ${target} ${step} step has no preview — skipped (nothing written)"
        fi
    done
    ONLY_STEPS=(${kept[@]+"${kept[@]}"})
    # shellcheck disable=SC2034  # EXCLUSIVE_STEPS is read by step_enabled.
    EXCLUSIVE_STEPS=1
}

# ---------------------------------------------------------------------------
# Target selection
# ---------------------------------------------------------------------------

# is_known_target <target>
is_known_target() {
    local known
    for known in "${ALL_TARGETS[@]}"; do
        [[ "${known}" == "$1" ]] && return 0
    done
    return 1
}

# supports_repo_mode <target>
# Whether <target> can install from the GitHub repo (--mode repo).
supports_repo_mode() {
    is_known_target "$1" && "${1}_supports_repo_mode"
}

# resolve_targets <csv>
# Populate TARGETS from a comma-separated --target value. 'all' expands to
# every target (minus repo-incapable ones under --mode repo) and must stand
# alone. Duplicates are dropped; order is preserved.
resolve_targets() {
    local csv="$1"
    local -a requested=()
    local target existing seen
    IFS=',' read -r -a requested <<< "${csv// /}"
    TARGETS=()

    if [[ ${#requested[@]} -eq 0 ]]; then
        err "--target requires at least one target"
        exit 1
    fi

    if [[ " ${requested[*]} " == *" all "* ]]; then
        if [[ ${#requested[@]} -ne 1 ]]; then
            err "--target 'all' cannot be combined with other targets"
            exit 1
        fi
        local reason
        local -a skipped=()
        for target in "${ALL_TARGETS[@]}"; do
            # Optional <t>_in_all: a target that cannot install here yet is
            # skipped; install/sync/remove say why (on stderr). Queries such as
            # 'list' run before COMMAND is set and skip silently.
            if declare -F "${target}_in_all" >/dev/null && ! "${target}_in_all"; then
                if [[ -n "${COMMAND:-}" ]]; then
                    reason="not available here"
                    declare -F "${target}_all_skip_reason" >/dev/null && reason="$("${target}_all_skip_reason")"
                    info "--target all: skipping ${target} (${reason})" >&2
                fi
                continue
            fi
            if [[ "${MODE}" == "repo" ]] && ! supports_repo_mode "${target}"; then
                skipped+=("${target}")
                continue
            fi
            TARGETS+=("${target}")
        done
        if [[ ${#skipped[@]} -gt 0 ]]; then
            local n=${#skipped[@]} list="${skipped[0]}" slashed="${skipped[0]}" i
            for ((i = 1; i < n; i++)); do
                if ((i == n - 1)); then list+=" and ${skipped[i]}"; else list+=", ${skipped[i]}"; fi
                slashed+=" / ${skipped[i]}"
            done
            local noun="targets"
            [[ ${n} -eq 1 ]] && noun="target"
            warn "--mode repo: skipping ${list} ${noun} (no remote-source concept)."
            warn "  use --target ${slashed} (default --mode local) to install those bundles."
        fi
        return 0
    fi

    for target in "${requested[@]}"; do
        if [[ -z "${target}" ]]; then
            err "--target contains an empty value"
            exit 1
        fi
        if ! is_known_target "${target}"; then
            err "Unknown target: ${target} (supported: ${ALL_TARGETS[*]}, all)"
            exit 1
        fi
        seen=0
        for existing in "${TARGETS[@]:-}"; do
            [[ "${existing}" == "${target}" ]] && { seen=1; break; }
        done
        if [[ ${seen} -eq 0 ]]; then
            TARGETS+=("${target}")
        fi
    done
}

# ---------------------------------------------------------------------------
# Skill overlap (--skills-home)
# ---------------------------------------------------------------------------
# codex, opencode and cursor read ~/.agents/skills AND their own skills dir, so
# installing ycc skills natively for several of them (or for one of them next
# to the agents target) lists every skill twice. resolve_skills_home offers to
# install the skills once into ~/.agents/skills instead: it records the
# affected targets in SKILLS_CONSOLIDATED (the target scripts then drop their
# own skill install, see skills_consolidated) and adds the agents target.
# Reads SKILLS_HOME ('', agents or native), COMMAND, MODE, TARGETS.

SKILLS_CONSOLIDATED=()

# reads_agents_skills <target> — true when <target>'s tool also reads
# ~/.agents/skills. Every target declares <t>_reads_agents_skills (contract);
# new targets opt in there, nothing here is hardcoded.
reads_agents_skills() {
    [[ "$1" != "agents" ]] && is_known_target "$1" && "${1}_reads_agents_skills"
}
AGENTS_AUTO_ADDED=0

# skills_consolidated <target> — true when <target>'s skills go to ~/.agents/skills.
skills_consolidated() {
    [[ " ${SKILLS_CONSOLIDATED[*]:-} " == *" $1 "* ]]
}

# skills_filter <target> "<words>" — echo <words> (bundle units or slices)
# minus the skill-bearing ones (skills, shared) when <target>'s skills were
# consolidated into ~/.agents/skills; unchanged otherwise.
skills_filter() {
    local word
    local -a kept=()
    for word in $2; do
        if skills_consolidated "$1" && [[ "${word}" == "skills" || "${word}" == "shared" ]]; then
            continue
        fi
        kept+=("${word}")
    done
    echo "${kept[*]:-}"
}

# target_has_native_skills <target> — true when the run installs ycc skills
# into <target>'s own dir (base ships them for codex/opencode/cursor too).
# Subshell: intent/package mapping rewrites ONLY_STEPS. Package mode must stay
# closure-aware: a package whose cursor units exclude skills (ycc-rules,
# ycc-mcp) never installs native skills, so it cannot trigger the
# skills-consolidation flow or auto-add the agents target.
target_has_native_skills() {
    if [[ -n "${PACKAGE:-}" && "$1" == "cursor" ]]; then
        [[ " ${PACKAGE_CURSOR_UNITS:-} " == *" skills "* ]]
        return $?
    fi
    if [[ -n "${PACKAGE:-}" && "$1" == "codex" ]]; then
        # A positively detected enabled foreign native ycc already supplies the
        # skills, and base will not register; consolidation would only duplicate.
        codex_native_plugin_detected || true
        [[ -z "${PACKAGE_CODEX_FOREIGN_MARKETPLACE:-}" ]] || return 1
    fi
    (
        if [[ -n "${PACKAGE:-}" ]]; then
            package_configure_steps "$(package_steps_csv "$1")"
        elif [[ ${#INTENTS[@]} -gt 0 ]]; then
            configure_intents_for_target "$1" >/dev/null
        fi
        step_enabled base || step_enabled skills
    )
}

# resolve_skills_home
# For install/sync, detect duplicate-skill overlap and apply the user's choice
# (flag, prompt on a TTY, else warn and proceed as requested).
resolve_skills_home() {
    [[ "${COMMAND}" == "remove" || "${MODE}" == "repo" || "${SKILLS_HOME:-}" == "native" ]] && return 0

    local -a sharing=()
    local t
    for t in "${TARGETS[@]}"; do
        reads_agents_skills "${t}" || continue
        target_has_native_skills "${t}" && sharing+=("${t}")
    done
    local n=${#sharing[@]}
    [[ ${n} -ge 1 ]] || return 0

    local list="${sharing[0]}" i
    for ((i = 1; i < n; i++)); do
        if ((i == n - 1)); then list+=" and ${sharing[i]}"; else list+=", ${sharing[i]}"; fi
    done

    if [[ "${SKILLS_HOME:-}" != "agents" ]]; then
        local agents_present=0
        [[ " ${TARGETS[*]} " == *" agents "* ]] && agents_present=1
        if [[ ${agents_present} -eq 0 ]] && agents_skills_present; then agents_present=1; fi
        [[ ${n} -ge 2 || ${agents_present} -eq 1 ]] || return 0

        if [[ ${n} -ge 2 ]]; then
            local both="all"
            [[ ${n} -eq 2 ]] && both="both"
            warn "${list} will produce duplicate ycc skills (${both} read ~/.agents/skills plus their own dir)."
        else
            warn "${list} will duplicate the ycc skills in ~/.agents/skills (it reads that dir plus its own)."
        fi
        warn "Recommended: install skills once to ~/.agents/skills (agents target) and install everything else (agents, commands, tool-specific config) into each tool's own directory."

        if [[ -t 0 && -t 2 ]]; then
            {
                printf '  [1] Recommended — skills → ~/.agents/skills; %s get only their non-skill pieces natively  (default)\n' "${list}"
                printf '  [2] Keep as requested (native skills per tool; duplicates possible)\n'
                printf '  [3] Abort\n'
            } >&2
            local reply
            while true; do
                printf 'Choice [1]: ' >&2
                read -r reply || reply=3
                case "${reply:-1}" in
                    1) break ;;
                    2) return 0 ;;
                    3) err "aborted"; exit 1 ;;
                esac
            done
        else
            warn "pass --skills-home agents to consolidate (or --skills-home native to keep native skills and silence this)."
            return 0
        fi
    fi

    SKILLS_CONSOLIDATED=("${sharing[@]}")
    if [[ " ${TARGETS[*]} " != *" agents "* ]]; then
        TARGETS+=(agents)
        AGENTS_AUTO_ADDED=1
    fi
    info "skills → ~/.agents/skills; ${list} keep only their non-skill pieces"
}

# order_targets
# When both agents and omp are in TARGETS, move agents to just before omp
# (other targets keep their relative order) so omp's dedupe step sees the
# ~/.agents/skills copies this run installs. agents_omp_hint relies on this.
order_targets() {
    [[ " ${TARGETS[*]:-} " == *" agents "* && " ${TARGETS[*]:-} " == *" omp "* ]] || return 0
    local target
    local -a ordered=()
    for target in "${TARGETS[@]}"; do
	case "${target}" in
	    agents) ;;
	    omp) ordered+=(agents omp) ;;
	    *) ordered+=("${target}") ;;
	esac
    done
    TARGETS=("${ordered[@]}")
}

# preflight_targets
# Reject every invalid target/mode/--only combination before any target runs,
# so a multi-target invocation never stops half-applied.
preflight_targets() {
    local target
    for target in "${TARGETS[@]}"; do
        if [[ "${MODE}" == "repo" ]] && ! supports_repo_mode "${target}"; then
            err "--mode repo is not supported by the ${target} target"
            if declare -F "${target}_repo_mode_hint" >/dev/null; then
                err "  $("${target}_repo_mode_hint")"
            else
                err "  ${target} has no remote-source concept; it reads bundles from local directories."
            fi
            err "  use --mode local (default), or --target all to skip it automatically."
            exit 1
        fi
        # Optional <t>_preflight: target-specific checks (tool versions, scope
        # sanity) that must pass before any target runs.
        if declare -F "${target}_preflight" >/dev/null; then
            "${target}_preflight"
        fi
        if [[ -n "${PACKAGE:-}" ]]; then
            package_configure_steps "$(package_steps_csv "${target}")"
            validate_only_steps "${target}" quiet
        elif [[ ${#INTENTS[@]} -gt 0 ]]; then
            # Warnings for unsupported intents are printed when the target runs.
            configure_intents_for_target "${target}" >/dev/null
        else
            validate_only_steps "${target}" quiet
        fi
        preflight_step_support "${target}"
    done
    preflight_selections
}

# preflight_step_support <target>
# Every step selected for <target> must support project scope (explicit
# --project), a project-capable settings step never runs from $HOME, and an
# explicitly requested global-only config group cannot ride --project.
preflight_step_support() {
    local target="$1"
    local step valid_csv
    valid_csv="$(valid_steps_for_target "${target}")"
    for step in ${valid_csv//,/ }; do
        step_enabled "${step}" || continue
        if [[ "${SCOPE}" == "project" ]] && ! step_allows_project "${target}" "${step}"; then
            err "--project is not supported by step '${step}' for target '${target}' (project scope currently supports: mcp; settings (claude, codex, opencode); claude: hooks; omp: base, dedupe)"
            err "  use --global, or select only project-capable steps with --only / --intent."
            if [[ "${step}" == "settings" ]] && declare -F "${target}_settings_scope_note" >/dev/null; then
                err "  $("${target}_settings_scope_note")"
            fi
            exit 1
        fi
    done
    [[ "${SCOPE}" == "project" ]] || return 0
    step_enabled settings || return 0
    step_allows_project "${target}" settings || return 0
    local home_conflict
    home_conflict="$(project_home_conflict "settings project scope")"
    if [[ -n "${home_conflict}" ]]; then
        err "${home_conflict}"
        exit 1
    fi
    # An explicitly requested global-only group (--intent plugins/hooks,
    # --plugins/--hooks) cannot ride --project; the default (implicit) groups
    # are dropped with a notice by config_group_selection instead.
    local allowed group
    allowed="$(target_project_groups "${target}")"
    for group in $(config_groups_for_target "${target}" | tr ',' ' '); do
        [[ -n "${group}" ]] || continue
        [[ ",${allowed}," == *",${group},"* ]] && continue
        local group_asked=0
        intent_requested "${group}" && group_asked=1
        if [[ "${group}" == plugins ]] && has_selection plugins; then
            group_asked=1
            # A catalog-only selection (opencode's opt-in catalog) is
            # project-capable; bundle names are rejected by <t>_preflight.
            if declare -F "${target}_catalog_names" >/dev/null; then
                local -a catalog=()
                local name only_catalog=1
                mapfile -t catalog < <("${target}_catalog_names")
                for name in $(selection_for_target plugins "${target}" | tr ',' ' '); do
                    [[ " ${catalog[*]} " == *" ${name} "* ]] || only_catalog=0
                done
                [[ ${only_catalog} -eq 1 ]] && group_asked=0
            fi
        elif [[ "${group}" == hooks ]] && has_selection hooks; then
            group_asked=1
        fi
        if [[ ${group_asked} -eq 1 ]]; then
            err "--project cannot carry the ${group} group for target '${target}' (global-only)"
            err "  use --global, or drop the ${group} selection."
            exit 1
        fi
    done
}
