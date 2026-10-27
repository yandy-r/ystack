#!/usr/bin/env bash
# Unified validate entrypoint — run every validator that guards the ycc
# source-of-truth directory and its generated Cursor/Codex/opencode/OMP bundles.
#
# Usage:
#   ./scripts/validate.sh                       # all targets
#   ./scripts/validate.sh --only inventory      # single target
#   ./scripts/validate.sh --only cursor,codex   # comma-separated subset
#   ./scripts/validate.sh --changed             # only targets the unpushed changes affect
#   ./scripts/validate.sh --serial              # one target at a time, streamed output
#
# Targets run concurrently by default, each with its output buffered and
# replayed in order. `config` runs last and alone: its install tests regenerate
# the bundles in this checkout, which the other targets read.
#
# Targets: inventory, cursor, codex, opencode, omp, agents, claude, claude-native,
#          cursor-native, codex-native, json, config, packages, release, mods, practices, scope, types
#   - inventory  validates ycc skill frontmatter, the shared inventory, the formatter bundle and
#                plan-workflow regressions, per-runtime worktree roots (scripts/test-worktree-roots.sh) and
#                the clean skill report generator (scripts/test-clean-report.sh), the
#                grep -c fallback regression suite (scripts/test-grep-count-helpers.sh), the
#                pipefail grep regression suite (scripts/test-pipefail-grep-helpers.sh) and
#                artifact-store regressions (scripts/test-artifact-store.sh)
#   - omp        checks generated OMP skill, agent and command drift (bytes and modes), content policy and golden
#                tests, plus native package manifests, catalog listing, lockstep versions and closure, and the
#                built-in command pin against a live omp (warns and skips when omp is absent)
#   - json       validates .claude-plugin/marketplace.json plus ycc/.claude-plugin/plugin.json
#   - claude     tests the generated hidden Claude package generator
#   - *-native   checks generated native package drift, runtime policies and fixtures;
#                Claude additionally runs optional `claude plugin validate`, while Codex
#                checks both the legacy checkout profile and a disposable native export
#   - config     tests the managed-config merge helper and install.sh sync CLI
#   - packages   validates the package manifest (ycc/settings/packages.json) against its schema
#                and invariants, package graph closures, manifest/tree/catalog parity, install doc IDs, and tests
#   - release    runs every scripts/test-release-*.sh (release-model state scripts,
#                RELEASING.md template, signal collector)
#   - mods       validates the Claude Code mods under ycc/mods and their marketplace
#   - practices  ratchets skill/agent/rule authoring practices against
#                scripts/practices-baseline.json (unit tests + validator + optional
#                `claude plugin validate`) and checks standalone agent references
#   - scope      tests the changed-path -> target mapping behind --changed
#   - types      runs `mypy --strict` over the modules listed in pyproject.toml [tool.mypy]
#                (scripts/validate-types.sh; mypy pinned in scripts/requirements-mypy.txt)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/validate-scope.sh
source "${SCRIPT_DIR}/lib/validate-scope.sh"

VALID_TARGETS=("${VALIDATE_TARGETS[@]}")
TARGETS=("${VALID_TARGETS[@]}")
PARALLEL=1
SCOPE_BASE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [--only <targets>] [--changed | --since <ref>] [--serial]

Run every validator for the ycc source-of-truth directory and its generated
Cursor / Codex / opencode / OMP bundles and managed configuration sync.

Options:
  --only <targets>   Comma-separated subset (valid: ${VALID_TARGETS[*]})
  --changed          Run only the targets affected by files changed since the
                     branch's push destination (all targets if none resolves)
  --since <ref>      Like --changed, measured from <ref>
  --serial           Run one target at a time with streamed output
  -h, --help         Show this help

Examples:
  $(basename "$0")
  $(basename "$0") --only inventory
  $(basename "$0") --only cursor,codex
  $(basename "$0") --only json
  $(basename "$0") --only practices
  $(basename "$0") --only types
  $(basename "$0") --changed
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)
            [[ $# -lt 2 ]] && { echo "validate.sh: --only requires an argument" >&2; exit 1; }
            IFS=',' read -r -a TARGETS <<<"$2"
            shift 2
            ;;
        --changed)
            SCOPE_BASE="$(validate_scope_base "${REPO_ROOT}")" \
                || echo "validate.sh: --changed found no push destination; running every target" >&2
            shift
            ;;
        --since)
            [[ $# -lt 2 ]] && { echo "validate.sh: --since requires an argument" >&2; exit 1; }
            SCOPE_BASE="$(git -C "${REPO_ROOT}" rev-parse --verify --quiet "$2^{commit}")" \
                || { echo "validate.sh: --since: not a commit: $2" >&2; exit 1; }
            shift 2
            ;;
        --serial)
            PARALLEL=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "validate.sh: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

for target in "${TARGETS[@]}"; do
    valid=0
    for v in "${VALID_TARGETS[@]}"; do
        [[ "$target" == "$v" ]] && valid=1 && break
    done
    if [[ "$valid" -eq 0 ]]; then
        echo "validate.sh: unknown target '$target' (valid: ${VALID_TARGETS[*]})" >&2
        exit 1
    fi
done

if [[ -n "${SCOPE_BASE}" ]]; then
    mapfile -t affected < <(validate_scope_changed_paths "${REPO_ROOT}" "${SCOPE_BASE}" | validate_scope_select)
    scoped=()
    for target in "${TARGETS[@]}"; do
        [[ " ${affected[*]} " == *" ${target} "* ]] && scoped+=("${target}")
    done
    TARGETS=("${scoped[@]}")
    echo "validate.sh: changes since ${SCOPE_BASE:0:12} affect: ${TARGETS[*]:-nothing}"
    [[ ${#TARGETS[@]} -gt 0 ]] || exit 0
fi

fail() {
    echo "validate.sh: FAILED at '$1'" >&2
    exit 1
}

if [[ "${PARALLEL}" -eq 1 ]]; then
    LOG_ROOT="$(mktemp -d)"
    trap 'rm -rf "${LOG_ROOT}"' EXIT
fi

# run_group <runner> <item>... — run '<runner> <item>' for every item. Serial
# mode streams output and stops at the first failure. Parallel mode runs the
# items concurrently with buffered output, replays each log in argument order,
# then names the failed items and returns 1 if there were any.
run_group() {
    local runner="$1"
    shift
    local item
    if [[ "${PARALLEL}" -eq 0 || $# -le 1 ]]; then
        for item in "$@"; do
            "${runner}" "${item}" || return 1
        done
        return 0
    fi

    local log_dir i=0
    local -a items=("$@") pids=() failed=()
    log_dir="$(mktemp -d "${LOG_ROOT}/group.XXXXXX")"
    for item in "$@"; do
        (
            SECONDS=0
            trap 'echo "-- ${item##*/}: ${SECONDS}s"' EXIT
            "${runner}" "${item}"
        ) >"${log_dir}/${i}.log" 2>&1 &
        pids+=("$!")
        i=$((i + 1))
    done
    for i in "${!pids[@]}"; do
        wait "${pids[i]}" || failed+=("${items[i]##*/}")
        cat "${log_dir}/${i}.log"
    done
    [[ ${#failed[@]} -eq 0 ]] && return 0
    echo "validate.sh: FAILED: ${failed[*]}" >&2
    return 1
}

run_release_test() {
    echo "== validate: $(basename "$1") =="
    "$1" || fail "$(basename "$1")"
}

run_config_part() {
    case "$1" in
        helpers)
            echo "== validate: model/effort declarations =="
            python3 "${REPO_ROOT}/scripts/validate-model-settings.py" || fail "validate-model-settings.py"
            echo "== test: omp model policy =="
            python3 "${REPO_ROOT}/scripts/test_omp_model_policy.py" || fail "test_omp_model_policy.py"
            echo "== validate: managed-config merge helper =="
            python3 "${REPO_ROOT}/scripts/test_merge_managed_config.py" || fail "test_merge_managed_config.py"
            python3 "${REPO_ROOT}/scripts/test_managed_config_entries.py" || fail "test_managed_config_entries.py"
            python3 "${REPO_ROOT}/scripts/test_opencode_plugin_catalog.py" || fail "test_opencode_plugin_catalog.py"
            python3 "${REPO_ROOT}/scripts/test_generate_codex_mcp.py" || fail "test_generate_codex_mcp.py"
            echo "== validate: codex marketplace helper =="
            python3 "${REPO_ROOT}/scripts/test_codex_marketplace.py" || fail "test_codex_marketplace.py"
            python3 "${REPO_ROOT}/scripts/test_codex_install.py" || fail "test_codex_install.py"
            echo "== test: package install plan =="
            python3 "${REPO_ROOT}/scripts/test_package_install_plan.py" || fail "test_package_install_plan.py"
            echo "== test: omp install helper =="
            python3 "${REPO_ROOT}/scripts/test_omp_install.py" || fail "test_omp_install.py"
            echo "== test: install slice selection =="
            python3 "${REPO_ROOT}/scripts/test_install_slices_select.py" || fail "test_install_slices_select.py"
            ;;
        install-sync)
            echo "== validate: install sync CLI =="
            "${REPO_ROOT}/scripts/test-install-sync.sh" || fail "test-install-sync.sh"
            ;;
    esac
}

# Exercise the split native catalog too, without changing the in-repo legacy
# profile. The temporary export is complete and checked before policy validation.
run_codex_native_export() (
    local export_root
    export_root="$(mktemp -d)" || exit 1
    trap 'rm -rf "${export_root}"' EXIT
    python3 "${REPO_ROOT}/scripts/generate_codex_plugin.py" --native-output "${export_root}" || exit 1
    "${REPO_ROOT}/scripts/validate-codex-plugin.sh" --native-output "${export_root}" || exit 1
)

run_target() {
    case "$1" in
        inventory)
            echo "== validate: inventory =="
            "${REPO_ROOT}/scripts/validate-inventory.sh" || fail "validate-inventory.sh"
            echo "== validate: ycc skill frontmatter =="
            "${REPO_ROOT}/scripts/validate-ycc-skills.sh" || fail "validate-ycc-skills.sh"
            echo "== validate: plan-workflow validator regressions =="
            "${REPO_ROOT}/scripts/test-plan-workflow-validators.sh" || fail "test-plan-workflow-validators.sh"
            echo "== validate: per-runtime worktree roots =="
            "${REPO_ROOT}/scripts/test-worktree-roots.sh" || fail "test-worktree-roots.sh"
            echo "== validate: clean report generator =="
            "${REPO_ROOT}/scripts/test-clean-report.sh" || fail "test-clean-report.sh"
            echo "== validate: grep -c fallback regressions =="
            "${REPO_ROOT}/scripts/test-grep-count-helpers.sh" || fail "test-grep-count-helpers.sh"
            echo "== validate: pipefail grep regressions =="
            "${REPO_ROOT}/scripts/test-pipefail-grep-helpers.sh" || fail "test-pipefail-grep-helpers.sh"
            echo "== validate: helper root discovery =="
            "${REPO_ROOT}/scripts/test-helper-root-discovery.sh" || fail "test-helper-root-discovery.sh"
            echo "== validate: artifact store regressions =="
            "${REPO_ROOT}/scripts/test-artifact-store.sh" || fail "test-artifact-store.sh"
            echo "== validate: artifact store pointer helper =="
            "${REPO_ROOT}/scripts/test-artifact-store-pointer.sh" || fail "test-artifact-store-pointer.sh"
            echo "== validate: artifact store pointer and bundle parity =="
            "${REPO_ROOT}/scripts/validate-artifact-store.sh" || fail "validate-artifact-store.sh"
            echo "== validate: Linear key collection regressions =="
            "${REPO_ROOT}/scripts/test-collect-linear-keys.sh" || fail "test-collect-linear-keys.sh"
            echo "== validate: implementation plan scripts =="
            "${REPO_ROOT}/scripts/test-implement-plan-scripts.sh" || fail "test-implement-plan-scripts.sh"
            echo "== validate: artifact body regressions =="
            "${REPO_ROOT}/scripts/test-artifact-body.sh" || fail "test-artifact-body.sh"
            echo "== validate: formatter bundle smoke =="
            "${REPO_ROOT}/scripts/validate-formatters-bundle.sh" || fail "validate-formatters-bundle.sh"
            echo "== validate: style.sh Node CLI resolution =="
            "${REPO_ROOT}/scripts/validate-style-node-tools.sh" || fail "validate-style-node-tools.sh"
            ;;
        cursor)
            echo "== validate: cursor agents =="
            "${REPO_ROOT}/scripts/validate-cursor-agents.sh" || fail "validate-cursor-agents.sh"
            echo "== validate: cursor skills =="
            "${REPO_ROOT}/scripts/validate-cursor-skills.sh" || fail "validate-cursor-skills.sh"
            echo "== validate: cursor rules =="
            "${REPO_ROOT}/scripts/validate-cursor-rules.sh" || fail "validate-cursor-rules.sh"
            echo "== test: cursor rules generator =="
            (cd "${REPO_ROOT}/scripts" && python3 test_generate_cursor_rules.py) \
                || fail "test_generate_cursor_rules.py"
            python3 "${REPO_ROOT}/scripts/test_generate_cursor_skills.py" || fail "test_generate_cursor_skills.py"
            ;;
        codex)
            echo "== validate: codex skills =="
            "${REPO_ROOT}/scripts/validate-codex-skills.sh" || fail "validate-codex-skills.sh"
            echo "== validate: codex agents =="
            "${REPO_ROOT}/scripts/validate-codex-agents.sh" || fail "validate-codex-agents.sh"
            python3 "${REPO_ROOT}/scripts/test_generate_codex_agents.py" || fail "test_generate_codex_agents.py"
            echo "== test: codex skills generator =="
            python3 "${REPO_ROOT}/scripts/test_generate_codex_skills.py" || fail "test_generate_codex_skills.py"
            ;;
        omp)
            echo "== validate: omp skills =="
            "${REPO_ROOT}/scripts/validate-omp-skills.sh" || fail "validate-omp-skills.sh"
            echo "== test: omp skills generator =="
            python3 "${REPO_ROOT}/scripts/test_generate_omp_skills.py" || fail "test_generate_omp_skills.py"
            echo "== validate: omp agents =="
            "${REPO_ROOT}/scripts/validate-omp-agents.sh" || fail "validate-omp-agents.sh"
            echo "== test: omp agents generator =="
            python3 "${REPO_ROOT}/scripts/test_generate_omp_agents.py" || fail "test_generate_omp_agents.py"
            echo "== validate: omp commands =="
            "${REPO_ROOT}/scripts/validate-omp-commands.sh" || fail "validate-omp-commands.sh"
            echo "== test: omp commands generator =="
            python3 "${REPO_ROOT}/scripts/test_generate_omp_commands.py" || fail "test_generate_omp_commands.py"
	    echo "== validate: omp built-in command pin (live omp; skips when absent) =="
	    python3 "${REPO_ROOT}/scripts/test_omp_builtin_commands.py" || fail "test_omp_builtin_commands.py"
	    python3 "${REPO_ROOT}/scripts/omp_builtin_commands.py" || fail "omp_builtin_commands.py"
            echo "== test: omp rules flattener =="
            python3 "${REPO_ROOT}/scripts/test_generate_omp_rules.py" || fail "test_generate_omp_rules.py"
            echo "== validate: omp native packages and catalog =="
            "${REPO_ROOT}/scripts/validate-omp-packages.sh" || fail "validate-omp-packages.sh"
            echo "== test: omp packages generator and policy =="
            python3 "${REPO_ROOT}/scripts/test_generate_omp_packages.py" || fail "test_generate_omp_packages.py"
            echo "== test: omp hook verdicts and code-surface guard =="
            python3 "${REPO_ROOT}/scripts/test_validate_omp_hooks.py" || fail "test_validate_omp_hooks.py"
            echo "== test: omp agent scope guard =="
            python3 "${REPO_ROOT}/scripts/test_omp_scope_guard.py" || fail "test_omp_scope_guard.py"
            echo "== test: omp scripted-session S5 proof =="
            python3 "${REPO_ROOT}/scripts/test_omp_scripted_smoke.py" || fail "test_omp_scripted_smoke.py"
            ;;
        opencode)
            echo "== validate: opencode skills =="
            "${REPO_ROOT}/scripts/validate-opencode-skills.sh" || fail "validate-opencode-skills.sh"
            echo "== validate: opencode agents =="
            "${REPO_ROOT}/scripts/validate-opencode-agents.sh" || fail "validate-opencode-agents.sh"
            echo "== validate: opencode commands =="
            "${REPO_ROOT}/scripts/validate-opencode-commands.sh" || fail "validate-opencode-commands.sh"
            echo "== validate: opencode plugin =="
            "${REPO_ROOT}/scripts/validate-opencode-plugin.sh" || fail "validate-opencode-plugin.sh"
            echo "== validate: opencode install coverage =="
            "${REPO_ROOT}/scripts/validate-opencode-install-coverage.sh" || fail "validate-opencode-install-coverage.sh"
            echo "== validate: compatibility audit (opencode install assumptions) =="
            "${REPO_ROOT}/ycc/skills/compatibility-audit/scripts/audit-install-assumptions.sh" --target=opencode "${REPO_ROOT}" \
                || fail "audit-install-assumptions.sh --target=opencode"
            echo "== validate: opencode V2 config rules =="
            (cd "${REPO_ROOT}/scripts" && python3 test_validate_opencode_config.py) \
                || fail "test_validate_opencode_config.py"
            echo "== validate: opencode V2 agent permission generation =="
            (cd "${REPO_ROOT}/scripts" && python3 test_generate_opencode_agents.py) \
                || fail "test_generate_opencode_agents.py"
            echo "== validate: opencode sensitive-file guard plugin =="
            python3 "${REPO_ROOT}/scripts/test_opencode_sensitive_guard.py" \
                || fail "test_opencode_sensitive_guard.py"
            echo "== validate: experimental opencode npm package =="
            python3 "${REPO_ROOT}/scripts/generate_opencode_package.py" --check \
                || fail "generate_opencode_package.py --check"
            python3 "${REPO_ROOT}/scripts/test_generate_opencode_package.py" \
                || fail "test_generate_opencode_package.py"
            python3 "${REPO_ROOT}/scripts/test_opencode_npm_release.py" \
                || fail "test_opencode_npm_release.py"
            ;;
        agents)
            echo "== validate: agents skills =="
            "${REPO_ROOT}/scripts/validate-agents-skills.sh" || fail "validate-agents-skills.sh"
            echo "== validate: agents install coverage =="
            "${REPO_ROOT}/scripts/validate-agents-install-coverage.sh" || fail "validate-agents-install-coverage.sh"
            ;;
        claude)
            echo "== test: claude packages generator =="
            python3 "${REPO_ROOT}/scripts/test_generate_claude_packages.py" || fail "test_generate_claude_packages.py"
            ;;
        claude-native)
            echo "== validate: claude native packages =="
            "${REPO_ROOT}/scripts/validate-claude-packages.sh" || fail "validate-claude-packages.sh"
            python3 "${REPO_ROOT}/scripts/test_validate_claude_native.py" || fail "test_validate_claude_native.py"
            echo "== validate: hidden v7 split (ycc skills + ycc-agents) =="
            python3 "${REPO_ROOT}/scripts/claude_agents_split.py" --check || fail "claude_agents_split.py --check"
            python3 "${REPO_ROOT}/scripts/test_claude_agents_split.py" || fail "test_claude_agents_split.py"
            ;;
        cursor-native)
            echo "== validate: cursor native packages =="
            "${REPO_ROOT}/scripts/validate-cursor-packages.sh" || fail "validate-cursor-packages.sh"
            python3 "${REPO_ROOT}/scripts/test_generate_cursor_packages.py" || fail "test_generate_cursor_packages.py"
            python3 "${REPO_ROOT}/scripts/test_validate_cursor_native.py" || fail "test_validate_cursor_native.py"
            python3 "${REPO_ROOT}/scripts/test_cursor_live_smoke.py" || fail "test_cursor_live_smoke.py"
            ;;
        codex-native)
            echo "== validate: codex native packages =="
            "${REPO_ROOT}/scripts/validate-codex-plugin.sh" || fail "validate-codex-plugin.sh"
            python3 "${REPO_ROOT}/scripts/test_generate_codex_plugin.py" || fail "test_generate_codex_plugin.py"
            python3 "${REPO_ROOT}/scripts/test_validate_codex_native.py" || fail "test_validate_codex_native.py"
            python3 "${REPO_ROOT}/scripts/test_codex_native_smoke.py" || fail "test_codex_native_smoke.py"
            run_codex_native_export || fail "Codex native export"
            ;;
        config)
            run_group run_config_part helpers install-sync || fail "config"
            ;;
	packages)
		echo "== validate: packages manifest schema & invariants =="
		python3 "${REPO_ROOT}/scripts/package_model.py" --check || fail "package_model.py --check"
		echo "== validate: package model unit tests =="
		python3 "${REPO_ROOT}/scripts/test_package_model.py" || fail "test_package_model.py"
		echo "== validate: package component graph & closures =="
		python3 "${REPO_ROOT}/scripts/build_package_graph.py" --check || fail "build_package_graph.py --check"
		python3 "${REPO_ROOT}/scripts/test_package_graph.py" || fail "test_package_graph.py"
		echo "== validate: package manifest/tree/catalog parity =="
		python3 "${REPO_ROOT}/scripts/validate_packages.py" || fail "validate_packages.py"
		python3 "${REPO_ROOT}/scripts/test_validate_packages.py" || fail "test_validate_packages.py"
		echo "== validate: install document package IDs =="
		python3 "${REPO_ROOT}/scripts/validate_install_doc_ids.py" || fail "validate_install_doc_ids.py"
		python3 "${REPO_ROOT}/scripts/test_validate_install_doc_ids.py" || fail "test_validate_install_doc_ids.py"
		echo "== validate: target capability matrix =="
		python3 "${REPO_ROOT}/scripts/test_validate_capability_matrix.py" || fail "test_validate_capability_matrix.py"
		python3 "${REPO_ROOT}/scripts/validate_capability_matrix.py" || fail "validate_capability_matrix.py"
		;;
        release)
            local -a release_tests=("${REPO_ROOT}"/scripts/test-release-*.sh)
            [[ -e "${release_tests[0]}" ]] || fail "no scripts/test-release-*.sh found"
            run_group run_release_test "${release_tests[@]}" || fail "release"
            ;;
        mods)
            echo "== validate: claude mods =="
            "${REPO_ROOT}/scripts/validate-mods.sh" || fail "validate-mods.sh"
            ;;
        practices)
            echo "== validate: practices unit tests =="
            python3 "${REPO_ROOT}/scripts/test_validate_practices.py" || fail "test_validate_practices.py"
            echo "== validate: standalone agent references =="
            python3 "${REPO_ROOT}/scripts/test_standalone_agent_references.py" || fail "test_standalone_agent_references.py"
            echo "== validate: practices ratchet =="
            "${REPO_ROOT}/scripts/validate-practices.sh" || fail "validate-practices.sh"
            ;;
        json)
            echo "== validate: marketplace and plugin manifests =="
            python3 -m json.tool "${REPO_ROOT}/.claude-plugin/marketplace.json" > /dev/null \
                || fail ".claude-plugin/marketplace.json"
            python3 -m json.tool "${REPO_ROOT}/ycc/.claude-plugin/plugin.json" > /dev/null \
                || fail "ycc/.claude-plugin/plugin.json"
            echo "OK: manifest JSON is valid."
            echo "== validate: hooks symlink =="
            "${REPO_ROOT}/scripts/validate-hooks.sh" || fail "validate-hooks.sh"
            ;;
        scope)
            echo "== validate: changed-path scoping =="
            "${REPO_ROOT}/scripts/test-validate-scope.sh" || fail "test-validate-scope.sh"
            ;;
        types)
            echo "== validate: mypy --strict (pyproject.toml [tool.mypy]) =="
            "${REPO_ROOT}/scripts/validate-types.sh" || fail "validate-types.sh"
            ;;
    esac
}

# `config` rewrites the generated bundles in place, so it never overlaps the
# targets that read them.
shared=()
exclusive=()
for target in "${TARGETS[@]}"; do
    if [[ "${target}" == "config" ]]; then exclusive+=("${target}"); else shared+=("${target}"); fi
done

run_group run_target "${shared[@]}" || exit 1
run_group run_target "${exclusive[@]}" || exit 1

echo "validate.sh: done (${TARGETS[*]})"
