# shellcheck shell=bash
# validate-scope.sh — the validate.sh target list plus the changed-path scoping
# behind `validate.sh --changed`. Sourced by scripts/validate.sh and
# scripts/test-validate-scope.sh (never run directly).
#
# Scoping is deliberately conservative: a path maps to a narrow target set only
# when it is listed here, and every unlisted path selects every target. CI runs
# the unscoped validate.sh, so a rule that is too narrow is caught there.

# shellcheck disable=SC2034  # read by validate.sh and the scope tests.
VALIDATE_TARGETS=(inventory cursor codex opencode omp agents claude claude-native cursor-native codex-native json config packages release mods practices scope types)

# validate_scope_targets_for_path <path> — print the targets a changed
# repo-relative path affects: a space-separated list, `all`, or nothing.
# mypy follows imports from the modules in pyproject.toml [tool.mypy], so any
# non-test script can join their import closure: each one also selects `types`.
validate_scope_targets_for_path() {
    local targets
    targets="$(validate_scope_owned_targets "$1")"
    case "$1" in
        scripts/test_*.py) ;;
        scripts/*.py) [[ "${targets}" == "all" ]] || targets="${targets:+${targets} }types" ;;
    esac
    [[ -z "${targets}" ]] || echo "${targets}"
}

# validate_scope_owned_targets <path> — the targets that own <path> itself.
validate_scope_owned_targets() {
    case "$1" in
        # The type-check pins and runner. pyproject.toml (the mypy config)
        # stays on the catch-all, which includes `types`.
        scripts/requirements-mypy.txt | scripts/validate-types.sh) echo "types" ;;

        # Generated artifacts and docs owned by a single target.
        docs/inventory.json | README.md) echo "inventory" ;;
        .cursor-plugin/*) echo "cursor cursor-native packages" ;;
        .codex-plugin/*) echo "codex codex-native packages" ;;
        .opencode-plugin/*) echo "opencode" ;;
        .agents-plugin/* | .agents/plugins/marketplace.json) echo "agents codex-native packages" ;;
        .claude-plugin/marketplace.json) echo "claude-native json packages" ;;
        packages/cursor/installer-fallback/*) echo "cursor cursor-native config" ;;
        packages/cursor/*) echo "cursor cursor-native packages" ;;
        packages/claude/*) echo "claude claude-native packages" ;;
        packages/opencode/*) echo "opencode release packages" ;;
        packages/omp/*) echo "omp" ;;
        .omp-plugin/*) echo "omp" ;;

        # The package manifest and its model feed the packages validators and
        # per-runtime package generators, so they must match before the
        # catch-all settings rule.
        ycc/settings/packages.json | ycc/settings/packages.schema.json) echo "cursor codex opencode omp claude claude-native cursor-native codex-native packages" ;;
        scripts/package_model.py | scripts/test_package_model.py) echo "cursor codex opencode omp claude claude-native cursor-native codex-native packages" ;;
        # The graph extractor also drives the hidden v7 Claude split check in claude-native.
        scripts/build_package_graph.py | scripts/package_graph_extract.py) echo "claude-native packages" ;;
        scripts/test_package_graph.py) echo "packages" ;;
        scripts/validate_packages.py | scripts/test_validate_packages.py) echo "packages" ;;
        scripts/validate_install_doc_ids.py | scripts/test_validate_install_doc_ids.py) echo "packages" ;;
        scripts/validate_capability_matrix.py | scripts/test_validate_capability_matrix.py) echo "packages" ;;
        # Generated shell helper-path check; its tests are in the [tool.mypy] file list.
        scripts/validate_generated_shell_paths.py) echo "packages" ;;
        scripts/test_validate_generated_shell_paths.py) echo "packages types" ;;
        # Claude package generator, validator and tests.
        scripts/generate_claude_packages.py | scripts/generate-claude-packages.sh | scripts/validate-claude-packages.sh | scripts/validate_claude_native.py | scripts/test_validate_claude_native.py | scripts/test_generate_claude_packages.py | scripts/test-claude-native-packages.sh | scripts/claude_native_smoke.py) echo "claude claude-native" ;;
        # Hidden v7 Claude split (ycc + ycc-agents): builder/validator, tests and opt-in live harness.
        # Its unit tests are in the [tool.mypy] file list, so they also select types.
        scripts/claude_agents_split.py | scripts/claude_agents_split_smoke.py | scripts/test-claude-agents-split.sh) echo "claude-native" ;;
        scripts/test_claude_agents_split.py) echo "claude-native types" ;;

        # Cursor native package generator, validator and tests. The component
        # generators (skills/agents/rules) stay on the catch-all: install tests
        # and other targets import or regenerate them.
        scripts/generate_cursor_packages.py | scripts/cursor_native_resources.py | scripts/generate-cursor-packages.sh | scripts/validate-cursor-packages.sh | scripts/validate_cursor_native.py | scripts/test_validate_cursor_native.py | scripts/test_generate_cursor_packages.py | scripts/vendor/cursor/*) echo "cursor cursor-native config" ;;
        scripts/cursor_live_smoke.py | scripts/test_cursor_live_smoke.py) echo "cursor-native" ;;
        # The MCP secret-literal audit shared by the Cursor and OMP package generators (typed,
        # so it also selects `types` through the scripts/*.py rule).
        scripts/mcp_secret_audit.py) echo "cursor cursor-native omp config" ;;

        # OMP skill, agent and command generators, validators and golden tests. The golden
        # tests are in pyproject.toml [tool.mypy] files, so they also select `types`.
        scripts/generate_omp_skills.py | scripts/generate-omp-skills.sh | scripts/validate-omp-skills.sh) echo "omp" ;;
        scripts/generate_omp_agents.py | scripts/generate-omp-agents.sh | scripts/validate-omp-agents.sh) echo "omp" ;;
        scripts/generate_omp_commands.py | scripts/generate-omp-commands.sh | scripts/validate-omp-commands.sh) echo "omp" ;;
        scripts/test_generate_omp_skills.py | scripts/test_generate_omp_agents.py | scripts/test_generate_omp_commands.py) echo "omp types" ;;
        # Live-omp drift guard for the built-in command pin (skips without omp) and its tests.
        scripts/omp_builtin_commands.py) echo "omp" ;;
        scripts/test_omp_builtin_commands.py) echo "omp types" ;;
        # OMP native packages: generator and policy (typed, so they also select `types`; the
        # install helper imports both, so they also select `config` for its tests), wrappers,
        # golden tests, and the opt-in live harness with its smoke driver.
        scripts/generate_omp_packages.py | scripts/validate_omp_native.py) echo "omp config" ;;
        scripts/omp_native_smoke.py) echo "omp" ;;
        scripts/generate-omp-packages.sh | scripts/validate-omp-packages.sh | scripts/test-omp-native-packages.sh) echo "omp" ;;
        scripts/test_generate_omp_packages.py) echo "omp types" ;;
        # OMP hook verdicts and code-surface guard (YAN-1174): golden tests (mypy files) and the
        # opt-in herdr harness with its typed smoke driver.
        scripts/test_validate_omp_hooks.py) echo "omp types" ;;
        scripts/omp_herdr_smoke.py | scripts/test-omp-herdr-hooks.sh) echo "omp" ;;
        # OMP install lifecycle (install.sh --target omp): the helper and its unit
        # tests (both in [tool.mypy] files, so they select `types`) and the opt-in
        # live harness.
        scripts/omp_install.py) echo "omp config" ;;
        scripts/test_omp_install.py) echo "omp config types" ;;
        scripts/test-omp-install-lifecycle.sh) echo "omp" ;;
        # OMP coexistence with the other runtimes (YAN-1176): the opt-in live harness.
        scripts/test-omp-coexistence.sh) echo "omp" ;;
        # OMP rules and model policy (YAN-1175): the rules flattener (feeds the ycc-rules
        # package, which the config target's real OMP export test builds) and the model
        # policy (imported by the agent generator and by validate-model-settings.py) also
        # select `config`; their unit tests (mypy files, so they select `types`) and the
        # opt-in live harness.
        scripts/generate_omp_rules.py) echo "omp config" ;;
        scripts/test_generate_omp_rules.py) echo "omp types" ;;
        scripts/omp_model_policy.py) echo "omp config" ;;
        scripts/test_omp_model_policy.py) echo "omp config types" ;;
        scripts/test-omp-rules-settings.sh) echo "omp" ;;
        # OMP scripted-model live sessions (YAN-1178): the typed driver and its opt-in harness.
        scripts/omp_scripted_smoke.py | scripts/test-omp-scripted-sessions.sh) echo "omp" ;;

        # Install docs contain model-validated public package identifiers; the OMP hook-verdict
        # check (validate_omp_native.py) also reads the OMP install doc, the ADR and the spike.
        docs/install/*) echo "packages omp" ;;
        docs/internal/spikes/omp-runtime-contract.md | docs/internal/adr/0002-omp-runtime-contract.md) echo "omp" ;;
        # Experimental OpenCode npm package source and boundary tests.
        scripts/generate_opencode_package.py | scripts/generate-opencode-package.sh | scripts/opencode_package* | scripts/test_generate_opencode_package.py | scripts/test-opencode-npm-package.sh | scripts/opencode_npm_release.py | scripts/test_opencode_npm_release.py) echo "opencode release" ;;

        # Docs and repo meta that no validator reads.
        docs/* | CONTRIBUTING.md | RELEASING.md | LICENSE | .github/*) ;;
        .gitignore | .gitmessage | .graphifyignore | commitlint.config.cjs) ;;
        .markdownlint.json | .markdownlintignore | mise.toml) ;;
        package-lock.json | pnpm-lock.yaml | pnpm-workspace.yaml) ;;


        # Plugin source. Settings and the plugin manifest feed the generators,
        # the install tests and the manifest checks, so they select everything.
        ycc/settings/* | ycc/.claude-plugin/*) echo "all" ;;
        ycc/mods/*) echo "config mods" ;;
        ycc/*) echo "inventory cursor codex opencode omp agents claude-native cursor-native codex-native packages release practices" ;;

        # install.sh and its tests. The install-coverage validators in the
        # agents and opencode targets parse the per-target install libs.
        scripts/lib/install/*) echo "opencode agents config" ;;
        install.sh | scripts/tests/install/* | scripts/test-install-sync.sh | scripts/completions/*) echo "config" ;;
        scripts/install_slices.py | scripts/slice_selection.py | scripts/slice_deps.py | scripts/slice_carriers.py | scripts/test_install_slices_legacy.py) echo "config" ;;
        # In the [tool.mypy] file list, so it also selects types.
        scripts/test_install_slices_select.py) echo "config types" ;;
        scripts/install_migrate.py | scripts/package_install_plan.py | scripts/test_package_install_plan.py) echo "config" ;;
        scripts/merge_managed_config.py | scripts/managed_config_*.py) echo "config" ;;
        scripts/test_merge_managed_config.py | scripts/test_managed_config_entries.py) echo "config" ;;
        scripts/codex_marketplace.py | scripts/test_codex_marketplace.py) echo "config codex-native" ;;
        scripts/generate_codex_plugin.py | scripts/validate-codex-plugin.sh | scripts/validate_codex_native.py | scripts/test_validate_codex_native.py | scripts/test_generate_codex_plugin.py) echo "codex codex-native config" ;;

        # Single-target tests and validators.
        scripts/test-release-*.sh) echo "release" ;;
        scripts/test-plan-workflow-validators.sh) echo "inventory" ;;
        scripts/test-helper-root-discovery.sh | scripts/test-artifact-store.sh | scripts/test-artifact-body.sh) echo "inventory" ;;
        scripts/test-artifact-store-pointer.sh | scripts/validate-artifact-store.sh) echo "inventory" ;;
        scripts/test-collect-linear-keys.sh | scripts/test-implement-plan-scripts.sh) echo "inventory" ;;
        scripts/test-clean-report.sh | scripts/test-grep-count-helpers.sh | scripts/test-pipefail-grep-helpers.sh) echo "inventory" ;;
        scripts/rename-repo.sh | scripts/rename_repo.py | scripts/test-rename-repo.sh | scripts/test_rename_repo.py) echo "inventory" ;;
        scripts/validate-mods.sh) echo "mods" ;;
        scripts/validate-practices.sh | scripts/validate_practices.py) echo "practices" ;;
        .claude/rules/*) echo "practices" ;;
        scripts/practices_parse.py | scripts/practices_rules.py | scripts/practices-baseline.json) echo "practices" ;;
        scripts/test_validate_practices.py | scripts/test_standalone_agent_references.py) echo "practices" ;;
        scripts/test-validate-scope.sh) echo "scope" ;;

        # Generators, shared libs, validate.sh itself, anything unrecognised.
        *) echo "all" ;;
    esac
}

# validate_scope_select — read changed paths on stdin (one per line) and print
# the affected targets, one per line, in VALIDATE_TARGETS order.
validate_scope_select() {
    local path target affected
    local selected=" "
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        affected="$(validate_scope_targets_for_path "${path}")"
        if [[ "${affected}" == "all" ]]; then
            printf '%s\n' "${VALIDATE_TARGETS[@]}"
            return 0
        fi
        selected+="${affected} "
    done
    for target in "${VALIDATE_TARGETS[@]}"; do
        [[ "${selected}" == *" ${target} "* ]] && printf '%s\n' "${target}"
    done
    return 0
}

# validate_scope_base <repo> — print the commit the current branch was last in
# sync with its push destination (falling back to its upstream, then the
# remote default branch). Returns 1 when none of them resolves.
validate_scope_base() {
    local repo="$1" ref base
    for ref in '@{push}' '@{upstream}' origin/HEAD origin/main; do
        if base="$(git -C "${repo}" merge-base HEAD "${ref}" 2>/dev/null)" && [[ -n "${base}" ]]; then
            printf '%s\n' "${base}"
            return 0
        fi
    done
    return 1
}

# validate_scope_changed_paths <repo> <base> — print the tracked paths that
# differ between <base> and the working tree (validators read the working
# tree, so uncommitted edits count). Renames list both the old and new path.
validate_scope_changed_paths() {
    git -C "$1" diff --name-only --no-renames "$2" --
}
