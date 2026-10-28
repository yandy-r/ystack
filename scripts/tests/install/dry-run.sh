#!/usr/bin/env bash
# install.sh tests — --dry-run previews managed config, rules, hooks and
# base removal without writing config, links, copies or ownership state.
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
install_must_succeed "${home}" remove --target all --only mcp --dry-run
out="${INSTALL_OUT}"
assert_contains "${out}" "would remove" "remove --dry-run lists what it would remove"
for f in .mcp.json .cursor/mcp.json .codex/config.toml opencode.json; do
    assert_contains "${out}" "${home}/project/${f}" "remove --dry-run previews ${f}"
done
after="$(tree_digest "${home}")"
if [[ "${before}" == "${after}" ]]; then
    ok "remove --dry-run leaves every file and the ownership state unchanged"
else
    ko "remove --dry-run leaves every file and the ownership state unchanged" "$(diff <(echo "${before}") <(echo "${after}"))"
fi

echo
echo "== install.sh --dry-run: sync previews the merge, writes nothing =="

home="$(new_home)"
before="$(tree_digest "${home}")"
install_must_succeed "${home}" sync --target claude,codex --intent mcp --global --dry-run
out="${INSTALL_OUT}"
assert_contains "${out}" "would set" "sync --dry-run lists what it would set"
after="$(tree_digest "${home}")"
if [[ "${before}" == "${after}" ]]; then
    ok "sync --dry-run creates no config or state file"
else
    ko "sync --dry-run creates no config or state file" "$(diff <(echo "${before}") <(echo "${after}"))"
fi

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
for pair in "codex skills" "opencode skills" "cursor skills" "agents skills"; do
    assert_contains "${out}" "dry-run: ${pair% *} ${pair#* } step has no preview" "sync --dry-run skips ${pair}"
done
assert_contains "${out}" "would set" "sync --dry-run still previews the mcp step alongside skipped steps"
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

    intents=settings,rules
    [[ "${target}" != claude && "${target}" != cursor ]] || intents+=,hooks
    install_must_succeed "${home}" sync --target "${target}" --intent "${intents}" --global
    if [[ "${target}" == cursor ]]; then
        # User rules now live in Settings; legacy owned links still retire.
        ln -s "${REPO_ROOT}/ycc/settings/rules/CLAUDE.md" "${home}/.cursor/CLAUDE.md"
    fi
    before="$(tree_digest "${home}")"
    calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
    install_must_succeed "${home}" remove --target "${target}" --intent "${intents}" --global --dry-run
    assert_contains "${INSTALL_OUT}" "would remove" "${target} settings removal previews keys"
    if [[ "${target}" == claude ]]; then
        assert_contains "${INSTALL_OUT}" "would remove ${home}/.claude/statusline-command.sh" "Claude previews statusline removal"
        assert_contains "${INSTALL_OUT}" "would unlink ${home}/.claude/hooks" "Claude previews hook unlink"
        assert_contains "${INSTALL_OUT}" "would unlink ${home}/.claude/CLAUDE.md" "Claude previews rules unlink"
    fi
    case "${target}" in
        cursor) assert_contains "${INSTALL_OUT}" "would unlink ${home}/.cursor/CLAUDE.md" "Cursor previews legacy rules unlink" ;;
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
    else
        assert_contains "${INSTALL_OUT}" "would remove" "${target} base previews owned entries"
        if [[ "${target}" == cursor || "${target}" == opencode ]]; then
            if [[ "${target}" == cursor ]]; then
                mirror="${home}/.cursor"
                units="skills agents rules"
            else
                mirror="${home}/.config/opencode"
                units="skills agents commands shared"
            fi
            for unit in ${units}; do
                for entry in "${mirror}/${unit}"/* "${mirror}/${unit}"/.[!.]*; do
                    [[ -e "${entry}" || -L "${entry}" ]] || continue
                    assert_contains "${INSTALL_OUT}" "would remove ${entry}" "${target} previews ${unit}/$(basename "${entry}")"
                done
            done
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

# Settings can also carry opt-in plugin companions and the guard directory.
home="$(new_home)"
before="$(tree_digest "${home}")"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins oh-my-opencode-slim --global --dry-run
assert_contains "${INSTALL_OUT}" "would copy" "catalog preview lists companion copy"
assert_home_unchanged "${home}" "${before}" "catalog sync preview"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins ./ycc-sensitive-guard,oh-my-opencode-slim --global
before="$(tree_digest "${home}")"
install_must_succeed "${home}" remove --target opencode --intent plugins --global --dry-run
assert_contains "${INSTALL_OUT}" "would remove ${home}/.config/opencode/oh-my-opencode-slim.json" "catalog removal previews companion"
assert_contains "${INSTALL_OUT}" "would remove ${home}/.config/opencode/ycc-sensitive-guard/index.js" "bundle removal previews guard tree"
assert_home_unchanged "${home}" "${before}" "catalog and guard removal preview"

# Cursor hooks carrier previews its script copy, then its removal.
home="$(new_home)"
before="$(tree_digest "${home}")"
install_must_succeed "${home}" sync --target cursor --intent hooks --dry-run
assert_contains "${INSTALL_OUT}" "would copy ${REPO_ROOT}/packages/cursor/ycc-hooks/hooks/herdr-session-start.sh -> ${home}/.cursor/hooks/herdr-session-start.sh" "cursor hooks sync previews the script copy"
assert_home_unchanged "${home}" "${before}" "cursor hooks sync preview"
copy_lines="$(grep -c "would copy .*herdr-session-start.sh" <<<"${INSTALL_OUT}" || true)"
if [[ "${copy_lines}" == "1" ]]; then ok "cursor hooks dry-run prints the script copy once"; else ko "cursor hooks dry-run prints the script copy once" "${INSTALL_OUT}"; fi
install_must_succeed "${home}" sync --target cursor --intent hooks
assert_not_contains "${INSTALL_OUT}" "[dry-run]" "live cursor hooks sync prints no preview lines"
before="$(tree_digest "${home}")"
install_must_succeed "${home}" remove --target cursor --intent hooks --dry-run
assert_contains "${INSTALL_OUT}" "would remove ${home}/.cursor/hooks/herdr-session-start.sh" "cursor hooks remove previews the script removal"
assert_contains "${INSTALL_OUT}" "would remove empty directory ${home}/.cursor/hooks" "cursor hooks remove previews the emptied hooks dir"
remove_lines="$(grep -c "would remove ${home}/.cursor/hooks/herdr-session-start.sh" <<<"${INSTALL_OUT}" || true)"
if [[ "${remove_lines}" == "1" ]]; then ok "cursor hooks dry-run prints the script removal once"; else ko "cursor hooks dry-run prints the script removal once" "${INSTALL_OUT}"; fi
assert_home_unchanged "${home}" "${before}" "cursor hooks removal preview"
install_must_succeed "${home}" remove --target cursor --intent hooks
assert_not_contains "${INSTALL_OUT}" "[dry-run]" "live cursor hooks remove prints no preview lines"

# Legacy Codex base removal previews the marketplace entry through the helper,
# lists each path once, and forecasts the emptied marketplace cache directory.
if ! repo_codex_native; then
    home="$(new_home)"
    mkdir -p "${home}/.codex/plugins/cache/local-ycc-plugins/ycc/skills" "${home}/.agents/plugins" "${home}/.codex/agents"
    cp -R "${REPO_ROOT}/.codex-plugin/agents/." "${home}/.codex/agents/"
    printf '%s\n' '{ "name": "local-ycc-plugins", "interface": { "displayName": "Local YCC Plugins" }, "plugins": [{ "name": "ycc" }, { "name": "other" }] }' > "${home}/.agents/plugins/marketplace.json"
    before="$(tree_digest "${home}")"
    install_must_succeed "${home}" remove --target codex --only base --dry-run
    assert_contains "${INSTALL_OUT}" "would remove marketplace entry ycc from ${home}/.agents/plugins/marketplace.json" "codex legacy removal previews the marketplace entry"
    assert_contains "${INSTALL_OUT}" "would remove ${home}/.codex/plugins/cache/local-ycc-plugins" "codex legacy removal previews the emptied cache directory"
    first_agent="$(find "${REPO_ROOT}/.codex-plugin/agents" -maxdepth 1 -name '*.toml' -printf '%f\n' | sort | sed -n 1p)"
    agent_lines="$(grep -c "would remove ${home}/.codex/agents/${first_agent}\$" <<<"${INSTALL_OUT}" || true)"
    if [[ "${agent_lines}" == "1" ]]; then ok "codex legacy removal lists each agent once"; else ko "codex legacy removal lists each agent once" "${INSTALL_OUT}"; fi
    assert_home_unchanged "${home}" "${before}" "codex legacy base removal preview"
else
    skip_listed "codex legacy base removal preview"
fi

echo
echo "== install.sh --target all --only <step>: targets without the step sit it out =="

home="$(new_home)"
install_must_succeed "${home}" install --target all --only mcp
assert_contains "${INSTALL_OUT}" "step 'mcp' is not supported by target 'agents' — skipping" "--target all --only mcp skips agents"
if [[ -f "${home}/project/.mcp.json" ]]; then ok "--target all --only mcp still runs mcp elsewhere"; else ko "--target all --only mcp still runs mcp elsewhere"; fi
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
