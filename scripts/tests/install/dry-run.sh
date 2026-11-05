#!/usr/bin/env bash
# install.sh tests — --dry-run previews managed config, rules, native plugin
# calls and base removal without writing config, links, copies, ownership
# state or running a plugin CLI.
# (omp's own dry-run is covered in omp.sh.)
#
# Runs alone (bash scripts/tests/install/dry-run.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# tree_digest <home> — one line per file (path + content hash) under <home>,
# minus the stub CLI log, so any write the run makes shows as a diff.
tree_digest() {
    (cd "$1" && find . -type d -print | sort)
    (cd "$1" && find . -path ./claude-calls.log -prune -o -type f -print0 \
        | sort -z | xargs -0r sha256sum)
    (cd "$1" && find . -type l -print | sort | while IFS= read -r link; do
        printf '%s -> %s\n' "${link}" "$(readlink "${link}")"
    done)
}

assert_home_unchanged() {
    local home="$1" before="$2" label="$3" after
    after="$(tree_digest "${home}")"
    if [[ "${before}" == "${after}" ]]; then
        ok "${label} leaves HOME unchanged"
    else
        ko "${label} leaves HOME unchanged" "$(diff <(echo "${before}") <(echo "${after}"))"
    fi
}

echo "== install.sh --dry-run: remove --target all --only mcp =="

home="$(new_home)"
install_must_succeed "${home}" sync --target all --intent mcp
before="$(tree_digest "${home}")"
# 'omp --version' (the --target all availability probe) is read-only; plugin commands are not.
calls="$(grep ' plugin ' "${home}/claude-calls.log" 2>/dev/null)"
install_must_succeed "${home}" remove --target all --only mcp --dry-run
out="${INSTALL_OUT}"
assert_contains "${out}" "would remove" "remove --dry-run lists what it would remove"
assert_contains "${out}" "ycc-mcp@ycc" "remove --dry-run previews the claude ycc-mcp uninstall"
assert_home_unchanged "${home}" "${before}" "remove --dry-run"
if [[ "$(grep ' plugin ' "${home}/claude-calls.log" 2>/dev/null)" == "${calls}" ]]; then ok "remove --dry-run runs no plugin CLI"; else ko "remove --dry-run runs no plugin CLI"; fi

echo
echo "== install.sh --dry-run: sync previews the plugin install, writes nothing =="

home="$(new_home)"
before="$(tree_digest "${home}")"
install_must_succeed "${home}" sync --target claude,opencode --intent mcp --global --dry-run
out="${INSTALL_OUT}"
assert_contains "${out}" "would run: claude plugin install ycc-mcp@ycc --scope user" "sync --dry-run previews the claude ycc-mcp install"
assert_contains "${out}" "would add the @yandy-r/ycc-opencode plugins entry" "sync --dry-run previews the opencode package entry"
assert_home_unchanged "${home}" "${before}" "sync --dry-run"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin" "sync --dry-run runs no plugin CLI"

echo
echo "== install.sh --dry-run: steps without a preview are skipped =="

home="$(new_home)"
before="$(tree_digest "${home}")"
install_must_succeed "${home}" install --target claude --dry-run
out="${INSTALL_OUT}"
assert_contains "${out}" "dry-run: claude base step has no preview" "install --dry-run says claude base cannot preview"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin" "install --dry-run runs no claude plugin command"

install_must_succeed "${home}" sync --target codex,opencode,cursor,agents --intent skills,settings,rules,mcp --dry-run
out="${INSTALL_OUT}"
assert_contains "${out}" "cursor: settings have no project scope" "cursor default settings dry-run explains the project-scope skip"
assert_not_contains "${out}" "dry-run: cursor settings step has no preview" "skipped cursor settings does not also report a missing preview"
assert_contains "${out}" "would add the @yandy-r/ycc-opencode plugins entry" "sync --dry-run previews opencode skills as the package entry"
for pair in "codex base" "agents skills"; do
    assert_contains "${out}" "dry-run: ${pair% *} ${pair#* } step has no preview" "sync --dry-run skips ${pair}"
done
assert_contains "${out}" "would run: agent plugin marketplace add" "sync --dry-run previews the cursor marketplace step"
assert_contains "${out}" "would set" "sync --dry-run still previews the mcp step alongside skipped steps"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin" "sync --dry-run runs no plugin CLI"
after="$(tree_digest "${home}")"
if [[ "${before}" == "${after}" ]]; then
    ok "skipped dry-run steps write nothing"
else
    ko "skipped dry-run steps write nothing" "$(diff <(echo "${before}") <(echo "${after}"))"
fi

home="$(new_home)"
before="$(tree_digest "${home}")"
install_must_succeed "${home}" install --target claude,cursor --package ycc,ycc-mcp --dry-run
out="${INSTALL_OUT}"
assert_contains "${out}" "dry-run: claude base step has no preview" "install --package --dry-run skips claude base"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin" "install --package --dry-run runs no claude plugin command"
after="$(tree_digest "${home}")"
if [[ "${before}" == "${after}" ]]; then
    ok "install --package --dry-run writes nothing"
else
    ko "install --package --dry-run writes nothing" "$(diff <(echo "${before}") <(echo "${after}"))"
fi


echo
echo "== install.sh --dry-run: default settings previews project destinations =="

for target in claude codex opencode; do
    home="$(new_home)"
    before="$(tree_digest "${home}")"
    install_must_succeed "${home}" sync --target "${target}" --intent settings --dry-run
    out="${INSTALL_OUT}"
    assert_contains "${out}" "would set" "${target} default settings dry-run lists project keys"
    case "${target}" in
        claude) dest="${home}/project/.claude/settings.json" ;;
        codex) dest="${home}/project/.codex/config.toml" ;;
        opencode) dest="${home}/project/opencode.json" ;;
    esac
    assert_contains "${out}" "${dest}" "${target} default settings dry-run names the project destination"
    assert_home_unchanged "${home}" "${before}" "${target} default settings preview"

    install_must_succeed "${home}" sync --target "${target}" --intent settings
    before="$(tree_digest "${home}")"
    install_must_succeed "${home}" remove --target "${target}" --intent settings --dry-run
    assert_contains "${INSTALL_OUT}" "would remove /" "${target} project settings removal previews managed keys"
    assert_contains "${INSTALL_OUT}" "${dest}" "${target} project settings removal names the project destination"
    assert_home_unchanged "${home}" "${before}" "${target} project settings removal preview"
done

home="$(new_home)"
before="$(tree_digest "${home}")"
install_must_succeed "${home}" sync --target omp --intent settings --dry-run
out="${INSTALL_OUT}"
assert_contains "${out}" "omp: settings have no project scope" "omp default settings dry-run explains the project-scope skip"
assert_not_contains "${out}" "dry-run: omp settings step has no preview" "skipped omp settings does not also report a missing preview"
assert_home_unchanged "${home}" "${before}" "omp default settings preview"
echo
echo "== settings, rules, hooks and base previews preserve installed and fresh homes =="
for target in claude cursor codex opencode; do
    home="$(new_home)"
    # Fresh previews must not create even an empty directory.
    rmdir "${home}/.claude" "${home}/.codex" "${home}/.cursor" "${home}/.config/opencode" "${home}/.config"
    before="$(tree_digest "${home}")"
    install_must_succeed "${home}" sync --target "${target}" --intent settings,rules --global --dry-run
    assert_contains "${INSTALL_OUT}" "would set" "${target} fresh settings preview lists keys"
    if [[ "${target}" == claude ]]; then
        assert_contains "${INSTALL_OUT}" "would copy ${REPO_ROOT}/ycc/settings/statusline-command.sh -> ${home}/.claude/statusline-command.sh" "Claude previews statusline copy"
    fi
    assert_home_unchanged "${home}" "${before}" "${target} fresh preview"

    # cursor's rules ride its marketplace (base) step; settings is its only config.
    intents=settings,rules
    [[ "${target}" != cursor ]] || intents=settings
    [[ "${target}" != claude ]] || intents+=,hooks
    install_must_succeed "${home}" sync --target "${target}" --intent "${intents}" --global
    before="$(tree_digest "${home}")"
    calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
    install_must_succeed "${home}" remove --target "${target}" --intent "${intents}" --global --dry-run
    assert_contains "${INSTALL_OUT}" "would remove" "${target} settings removal previews keys"
    if [[ "${target}" == claude ]]; then
        assert_contains "${INSTALL_OUT}" "would remove ${home}/.claude/statusline-command.sh" "Claude previews statusline removal"
        assert_contains "${INSTALL_OUT}" "ycc-hooks@ycc" "Claude previews the ycc-hooks uninstall"
        assert_contains "${INSTALL_OUT}" "would unlink ${home}/.claude/CLAUDE.md" "Claude previews rules unlink"
    fi
    case "${target}" in
        codex) assert_contains "${INSTALL_OUT}" "would unlink ${home}/.codex/rules/default.rules" "Codex previews rules unlink" ;;
        opencode) assert_contains "${INSTALL_OUT}" "would unlink ${home}/.config/opencode/AGENTS.md" "opencode previews rules unlink" ;;
    esac
    assert_home_unchanged "${home}" "${before}" "${target} settings/rules/hooks removal preview"
    if [[ "$(cat "${home}/claude-calls.log" 2>/dev/null)" == "${calls}" ]]; then
        ok "${target} config preview runs no CLI"
    else
        ko "${target} config preview runs no CLI"
    fi

    install_must_succeed "${home}" sync --target "${target}" --intent base --global
    before="$(tree_digest "${home}")"
    calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
    install_must_succeed "${home}" remove --target "${target}" --only base --dry-run
    if [[ "${target}" == claude ]]; then
        assert_contains "${INSTALL_OUT}" "would run: claude plugin uninstall ycc@ycc" "Claude base previews uninstall"
        assert_contains "${INSTALL_OUT}" "would run: claude plugin marketplace remove ycc" "Claude base previews marketplace removal"
    elif [[ "${target}" == cursor ]]; then
        assert_contains "${INSTALL_OUT}" "would run: agent plugin marketplace remove ycc" "Cursor base previews marketplace removal"
    else
        assert_contains "${INSTALL_OUT}" "would remove" "${target} base previews owned entries"
        if [[ "${target}" == opencode ]]; then
            assert_contains "${INSTALL_OUT}" "would remove the file://${REPO_ROOT}/packages/opencode/ycc-opencode plugins entry" "opencode base previews the package entry removal"
        fi
    fi
    assert_home_unchanged "${home}" "${before}" "${target} base removal preview"
    if [[ "$(cat "${home}/claude-calls.log" 2>/dev/null)" == "${calls}" ]]; then
        ok "${target} base preview runs no CLI"
    else
        ko "${target} base preview runs no CLI"
    fi
done

# Project hooks must describe native CLI operations without even a read-only
# CLI lookup, since real CLI commands may refresh their own registry/cache.
home="$(new_home)"
before="$(tree_digest "${home}")"
install_must_succeed "${home}" sync --target claude --intent hooks --project --dry-run
assert_contains "${INSTALL_OUT}" "would run: claude plugin install ycc-hooks@ycc --scope project" "project hook install previews CLI"
install_must_succeed "${home}" remove --target claude --intent hooks --project --dry-run
assert_contains "${INSTALL_OUT}" "would run: claude plugin uninstall ycc-hooks@ycc --scope project" "project hook remove previews CLI"
assert_home_unchanged "${home}" "${before}" "project hooks preview"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin" "project hook preview runs no CLI"

# Exact documented settings/hooks/rules removal command (auto scope).
home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings,hooks,rules
before="$(tree_digest "${home}")"
install_must_succeed "${home}" remove --target claude --intent settings,hooks,rules --dry-run
assert_contains "${INSTALL_OUT}" "would remove /" "combined Claude removal lists managed keys"
assert_contains "${INSTALL_OUT}" "would unlink ${home}/.claude/CLAUDE.md" "combined Claude removal lists rules link"
assert_contains "${INSTALL_OUT}" "would run: claude plugin uninstall ycc-hooks@ycc --scope project" "combined Claude removal lists project hooks removal"
assert_home_unchanged "${home}" "${before}" "exact Claude removal preview"

# Settings can also carry opt-in plugin companions.
home="$(new_home)"
before="$(tree_digest "${home}")"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins oh-my-opencode-slim --global --dry-run
assert_contains "${INSTALL_OUT}" "would copy" "catalog preview lists companion copy"
assert_home_unchanged "${home}" "${before}" "catalog sync preview"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins oh-my-opencode-slim --global
before="$(tree_digest "${home}")"
install_must_succeed "${home}" remove --target opencode --intent plugins --global --dry-run
assert_contains "${INSTALL_OUT}" "would remove ${home}/.config/opencode/oh-my-opencode-slim.json" "catalog removal previews companion"
assert_home_unchanged "${home}" "${before}" "catalog removal preview"

echo
echo "== install.sh --target all --only <step>: targets without the step sit it out =="

home="$(new_home)"
install_must_succeed "${home}" install --target all --only mcp
assert_contains "${INSTALL_OUT}" "step 'mcp' is not supported by target 'agents' — skipping" "--target all --only mcp skips agents"
assert_contains "${INSTALL_OUT}" "step 'mcp' is not supported by target 'opencode' — skipping" "--target all --only mcp skips opencode (MCP ships in its package)"
assert_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin install ycc-mcp@ycc" "--target all --only mcp still runs mcp elsewhere"
if out="$(run_install "${home}" install --target agents --only mcp)"; then
    ko "an explicit target still rejects a step it lacks"
else
    assert_contains "${out}" "--only step 'mcp' is not valid for target 'agents'" "an explicit target still rejects a step it lacks"
fi
if out="$(run_install "${home}" install --target all --only bogus)"; then
    ko "--target all still rejects a step no target has"
else
    assert_contains "${out}" "--only step 'bogus' is not valid" "--target all still rejects a step no target has"
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
