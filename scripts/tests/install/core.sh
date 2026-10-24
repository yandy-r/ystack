#!/usr/bin/env bash
# install.sh tests — core: argument parsing, intents, --only, scope, remove validation, cli/completion, contract and completion drift.
#
# Runs alone (bash scripts/tests/install/core.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== install.sh: command is required =="

home="$(new_home)"
out="$(run_install "${home}" --target claude --only rules)"
assert_contains "${out}" "missing or unknown command '--target'" "bare --target rejected"
assert_contains "${out}" "install --target claude --only rules" "bare --target suggests install"
assert_not_contains "${out}" "link rules" "bare --target runs nothing"

home="$(new_home)"
out="$(run_install "${home}")"
assert_contains "${out}" "Usage:" "no command prints usage"

home="$(new_home)"
out="$(run_install "${home}" bogus --target claude)"
assert_contains "${out}" "missing or unknown command 'bogus'" "unknown command rejected"

home="$(new_home)"
out="$(run_install "${home}" install --target claude --intent settings)"
assert_contains "${out}" "--intent requires the 'sync' or 'remove' subcommand" "install rejects --intent"

echo
echo "== install.sh sync: argument validation =="

home="$(new_home)"
out="$(run_install "${home}" sync --target claude)"
assert_contains "${out}" "sync requires --intent" "sync without --intent fails"

home="$(new_home)"
out="$(run_install "${home}" sync --target claude --intent settings,bogus)"
assert_contains "${out}" "unknown intent 'bogus'" "unknown intent rejected"

home="$(new_home)"
out="$(run_install "${home}" sync --target claude --intent "settings,,mcp")"
assert_contains "${out}" "--intent contains an empty value" "empty intent token rejected"

home="$(new_home)"
out="$(run_install "${home}" sync --target claude --intent settings --only settings)"
assert_contains "${out}" "cannot be combined with --only" "sync rejects --only"

home="$(new_home)"
out="$(run_install "${home}" sync --target claude --intent settings --mcp)"
assert_contains "${out}" "cannot be combined with --only" "sync rejects additive flags"
out="$(run_install "${home}" sync --target claude --intent settings --hooks)"
assert_contains "${out}" "--hooks requires a comma-separated list of hook events on sync (install --hooks is the boolean step flag)" "sync --hooks is the hook-event selector (needs a value)"
out="$(run_install "${home}" sync --target claude --intent hooks --hooks --force)"
assert_contains "${out}" "--hooks requires a comma-separated list of hook events on sync" "sync --hooks never swallows a following flag"
out="$(run_install "${home}" remove --hooks --target claude --intent hooks)"
assert_contains "${out}" "--hooks requires a comma-separated list of hook events on remove" "remove --hooks never swallows --target"

home="$(new_home)"
out="$(run_install "${home}" install --target claude --intent settings)"
assert_contains "${out}" "--intent requires the 'sync' or 'remove' subcommand" "--intent rejected by install"

home="$(new_home)"
out="$(run_install "${home}" sync --intent settings)"
assert_contains "${out}" "Missing required --target" "sync still requires --target"

echo
echo "== install.sh: multiple targets =="

home="$(new_home)"
install_must_succeed "${home}" sync --target codex,claude,opencode --intent mcp
out="${INSTALL_OUT}"
assert_contains "${out}" "Codex sync complete" "multi-target runs codex"
assert_contains "${out}" "Claude sync complete" "multi-target runs claude"
assert_contains "${out}" "opencode sync complete" "multi-target runs opencode"
assert_not_contains "${out}" "Cursor sync complete" "multi-target skips unlisted cursor"
assert_contains "$(cat "${home}/project/.mcp.json")" '"mcpServers"' "multi-target merges claude MCP into project scope"

home="$(new_home)"
install_must_succeed "${home}" sync --target claude,claude --intent mcp
out="${INSTALL_OUT}"
count="$(grep -c "Claude sync complete" <<< "${out}")"
if [[ "${count}" == "1" ]]; then ok "duplicate targets run once"; else ko "duplicate targets run once" "ran ${count} times"; fi

home="$(new_home)"
out="$(run_install "${home}" sync --target claude,bogus --intent mcp)"
assert_contains "${out}" "Unknown target: bogus" "unknown target in list rejected"
assert_not_contains "${out}" "Claude sync complete" "unknown target fails before any target runs"

home="$(new_home)"
out="$(run_install "${home}" sync --target "claude,,codex" --intent mcp)"
assert_contains "${out}" "--target contains an empty value" "empty target token rejected"

home="$(new_home)"
out="$(run_install "${home}" sync --target all,claude --intent mcp)"
assert_contains "${out}" "'all' cannot be combined" "all must stand alone"

home="$(new_home)"
out="$(run_install "${home}" sync --target claude,cursor --intent mcp --mode repo)"
assert_contains "${out}" "--mode repo is not supported by the cursor target" "repo mode rejects listed cursor"
assert_not_contains "${out}" "Claude sync complete" "repo-mode rejection happens before any target runs"

home="$(new_home)"
out="$(run_install "${home}" install --target claude,codex --only hooks)"
assert_contains "${out}" "--only step 'hooks' is not valid for target 'codex'" "install --only validated across all targets"
assert_not_contains "${out}" "Claude sync complete" "--only rejection happens before any target runs"

echo
echo "== install.sh sync: no implicit base =="

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings
out="${INSTALL_OUT}"
assert_not_contains "${out}" "register repo checkout as local marketplace" "sync --intent settings does not run base"

home="$(new_home)"
install_must_succeed "${home}" sync --target cursor --intent plugins
out="${INSTALL_OUT}"
assert_contains "${out}" "intent 'plugins' is not supported by target 'cursor'" "unsupported intent reported"
assert_not_contains "${out}" "Generate Cursor-native bundle" "unsupported-only intent does not fall back to base"

home="$(new_home)"
install_must_succeed "${home}" sync --target codex --intent hooks
out="${INSTALL_OUT}"
assert_contains "${out}" "intent 'hooks' is not supported by target 'codex'" "codex hooks is a no-op"

echo
echo "== install.sh install (step flags) =="

home="$(new_home)"
install_must_succeed "${home}" install --target claude --only rules
out="${INSTALL_OUT}"
assert_contains "${out}" "link rules" "install --only rules runs"
assert_not_contains "${out}" "register repo checkout" "install --only stays exclusive"

home="$(new_home)"
out="$(run_install "${home}" install --target claude --only bogus)"
assert_contains "${out}" "is not valid for target" "install --only validates steps"

echo
echo "== install.sh: --project / --global MCP scope =="

home="$(new_home)"
out="$(run_install "${home}" install --target claude --project --global)"
assert_contains "${out}" "mutually exclusive" "--project and --global rejected together"

home="$(new_home)"
out="$(run_install "${home}" install --target claude --only settings,mcp --project)"
assert_contains "${out}" "--project is not supported by step 'settings'" "--project rejects non-project steps"
assert_not_contains "${out}" "Claude sync complete" "--project rejection happens before any target runs"

home="$(new_home)"
install_must_succeed "${home}" sync --target all --intent mcp
for f in .mcp.json .cursor/mcp.json .codex/config.toml opencode.json; do
    if [[ -f "${home}/project/${f}" ]]; then ok "project MCP written: ${f}"; else ko "project MCP written: ${f}"; fi
done
if [[ ! -e "${home}/.claude.json" && ! -e "${home}/.cursor/mcp.json" ]]; then
    ok "project scope leaves global MCP files alone"
else
    ko "project scope leaves global MCP files alone"
fi

home="$(new_home)"
install_must_succeed "${home}" install --target claude --only mcp --global
assert_contains "$(cat "${home}/.claude.json")" '"mcpServers"' "--global writes ~/.claude.json"
if [[ ! -e "${home}/project/.mcp.json" ]]; then ok "--global leaves project alone"; else ko "--global leaves project alone"; fi

echo
echo "== install.sh remove =="

home="$(new_home)"
out="$(run_install "${home}" remove --target claude)"
assert_contains "${out}" "remove requires --only <steps> or --intent <intents>" "remove requires a selection"

home="$(new_home)"
out="$(run_install "${home}" remove --target claude --mcp)"
assert_contains "${out}" "remove does not accept --settings" "remove rejects additive flags"

home="$(new_home)"
out="$(run_install "${home}" remove --target claude --only mcp --mode repo)"
assert_contains "${out}" "remove does not accept --mode" "remove rejects --mode"

home="$(new_home)"
out="$(run_install "${home}" remove --target claude --only settings --project)"
assert_contains "${out}" "--project is not supported by step 'settings'" "remove keeps the --project guard"

home="$(new_home)"
cat > "${home}/project/.mcp.json" <<'JSON'
{ "mcpServers": { "mine": { "url": "https://mine" } } }
JSON
install_must_succeed "${home}" install --target claude --only mcp
install_must_succeed "${home}" remove --target claude --only mcp
out="${INSTALL_OUT}"
assert_contains "${out}" "Claude remove complete" "remove runs for claude"
merged="$(cat "${home}/project/.mcp.json")"
assert_contains "${merged}" '"mine"' "remove keeps user-added server"
assert_not_contains "${merged}" '"playwright"' "remove drops managed server"

home="$(new_home)"
install_must_succeed "${home}" sync --target all --intent mcp --global
install_must_succeed "${home}" remove --target all --intent mcp --global
for f in .claude.json .cursor/mcp.json .codex/config.toml .config/opencode/opencode.json; do
    if [[ ! -e "${home}/${f}" ]]; then ok "global remove cleans ${f}"; else ko "global remove cleans ${f}"; fi
done

home="$(new_home)"
cat > "${home}/.codex/config.toml" <<'TOML'
# keep me
[mcp_servers.internal]
url = "https://internal.example"
TOML
install_must_succeed "${home}" install --target codex --only mcp --global
install_must_succeed "${home}" remove --target codex --only mcp --global
merged="$(cat "${home}/.codex/config.toml")"
assert_contains "${merged}" "# keep me" "codex remove keeps comments"
assert_contains "${merged}" "[mcp_servers.internal]" "codex remove keeps user server"
assert_not_contains "${merged}" "[mcp_servers.playwright]" "codex remove drops managed server"

echo
echo "== install.sh cli / completion =="

home="$(new_home)"
bin="${home}/.local/bin"
PATH="${bin}:${PATH}" install_must_succeed "${home}" cli
out="${INSTALL_OUT}"
if [[ "$(readlink "${bin}/ycc")" == "${INSTALL}" ]]; then ok "cli links ycc into ~/.local/bin"; else ko "cli links ycc into ~/.local/bin" "${out}"; fi
PATH="${bin}:${PATH}" install_must_succeed "${home}" cli
out="${INSTALL_OUT}"
assert_contains "${out}" "link up-to-date" "cli rerun is a no-op"

# The regression: a linked command run outside the repo must find its helpers
# and write project MCP into the caller's directory.
out="$(cd "${home}/project" && HOME="${home}" YCC_MANAGED_CONFIG_STATE="${home}/state.json" "${bin}/ycc" sync --target claude --intent mcp 2>&1)"
assert_contains "$(cat "${home}/project/.mcp.json" 2>/dev/null)" '"mcpServers"' "linked ycc merges project MCP from outside the repo"

home="$(new_home)"
mkdir -p "${home}/mybin" && echo "mine" > "${home}/mybin/ycc"
out="$(run_install "${home}" cli --dir "${home}/mybin")"
assert_contains "${out}" "refusing to replace existing" "cli refuses foreign file without --force"
install_must_succeed "${home}" cli --dir "${home}/mybin" --force
if [[ "$(readlink "${home}/mybin/ycc")" == "${INSTALL}" ]]; then ok "cli --dir --force replaces"; else ko "cli --dir --force replaces"; fi

home="$(new_home)"
install_must_succeed "${home}" cli --dir "${home}/offpath"
out="${INSTALL_OUT}"
assert_contains "${out}" "is not on PATH" "cli warns when dir is off PATH"

home="$(new_home)"
for sh in bash zsh fish; do
    install_must_succeed "${home}" completion --shell "${sh}"
    out="${INSTALL_OUT}"
    assert_contains "${out}" "ycc" "completion prints ${sh} script"
done
out="$(run_install "${home}" completion --shell tcsh)"
assert_contains "${out}" "unsupported shell 'tcsh'" "completion rejects unknown shell"

home="$(new_home)"
install_must_succeed "${home}" completion --shell bash --install
install_must_succeed "${home}" completion --shell zsh --install
install_must_succeed "${home}" completion --shell fish --install
for f in .local/share/bash-completion/completions/ycc .local/share/zsh/site-functions/_ycc .config/fish/completions/ycc.fish; do
    if [[ -L "${home}/${f}" ]]; then ok "completion installed: ${f}"; else ko "completion installed: ${f}"; fi
done
rm "${home}/.local/share/zsh/site-functions/_ycc" && echo "mine" > "${home}/.local/share/zsh/site-functions/_ycc"
out="$(run_install "${home}" completion --shell zsh --install)"
assert_contains "${out}" "refusing to replace existing" "completion --install refuses real file without --force"
install_must_succeed "${home}" completion --shell zsh --install --force
if [[ -L "${home}/.local/share/zsh/site-functions/_ycc" ]]; then ok "completion --install --force replaces"; else ko "completion --install --force replaces"; fi

if bash -n "${REPO_ROOT}/scripts/completions/ycc.bash"; then ok "bash completion parses"; else ko "bash completion parses"; fi
if ! command -v zsh >/dev/null || zsh -n "${REPO_ROOT}/scripts/completions/_ycc"; then ok "zsh completion parses"; else ko "zsh completion parses"; fi
if ! command -v fish >/dev/null || fish -n "${REPO_ROOT}/scripts/completions/ycc.fish"; then ok "fish completion parses"; else ko "fish completion parses"; fi
out="$(bash -c 'source "$1"; COMP_WORDS=(ycc sync --target claude,co); COMP_CWORD=3; _ycc; echo "${COMPREPLY[*]}"' _ "${REPO_ROOT}/scripts/completions/ycc.bash")"
assert_contains "${out}" "claude,codex" "bash completion completes comma lists"
# bash completion behaviour: omp is a --target value (migrate too) and the
# --dry-run is offered for install, sync and remove.
complete_bash() {
    bash -c 'source "$1"; shift; COMP_WORDS=("$@"); COMP_CWORD=$(($# - 1)); _ycc; echo "${COMPREPLY[*]}"' \
        _ "${REPO_ROOT}/scripts/completions/ycc.bash" "$@"
}
assert_contains " $(complete_bash ycc install --target o) " " omp " "bash completion offers --target omp"
assert_contains " $(complete_bash ycc migrate --target o) " " omp " "bash completion offers migrate --target omp"
for sub in install sync remove; do
    assert_contains " $(complete_bash ycc "${sub}" --dry) " " --dry-run " "bash completion offers ${sub} --dry-run"
done
assert_not_contains "$(complete_bash ycc migrate --dry)" "--dry-run" "bash completion keeps --dry-run off migrate"
# zsh and fish: the static target lists and the --dry-run option.
for f in _ycc ycc.fish; do
    script="$(cat "${REPO_ROOT}/scripts/completions/${f}")"
    assert_contains "${script}" "claude cursor codex opencode agents omp all" "${f} completes --target omp"
    assert_contains "${script}" "dry-run" "${f} completes --dry-run"
done

# Every target in ALL_TARGETS implements the per-target lib contract.
missing="$(bash -c 'REPO_ROOT="$1"; INSTALL="$2"; '"$(declare -f source_install_libs)"'
    source_install_libs
    for t in "${ALL_TARGETS[@]}"; do
        for fn in "${t}_valid_steps" "${t}_intent_steps" "${t}_config_groups" "${t}_supports_repo_mode" \
            "sync_${t}_target" "remove_${t}_target"; do
            declare -F "${fn}" >/dev/null || printf " %s" "${fn}"
        done
    done' _ "${REPO_ROOT}" "${INSTALL}" 2>&1)"
if [[ -z "${missing}" ]]; then ok "every target defines the lib contract"; else ko "every target defines the lib contract" "missing:${missing}"; fi

# Completion lists must track install.sh: every intent, and every step any
# target accepts for --only.
intents="$(bash -c 'REPO_ROOT="$1"; INSTALL="$2"; '"$(declare -f source_install_libs)"'
    source_install_libs; echo "${VALID_INTENTS[*]}"' _ "${REPO_ROOT}" "${INSTALL}")"
steps="$(bash -c 'REPO_ROOT="$1"; INSTALL="$2"; '"$(declare -f source_install_libs)"'
    source_install_libs; for t in "${ALL_TARGETS[@]}"; do valid_steps_for_target "$t"; done' _ "${REPO_ROOT}" "${INSTALL}" \
    | tr ',' '\n' | awk '!seen[$0]++' | tr '\n' ' ')"
for f in _ycc ycc.bash ycc.fish; do
    assert_contains "$(cat "${REPO_ROOT}/scripts/completions/${f}")" "${intents}" "${f} completes every intent"
    only_line="$(grep -E -- 'only' "${REPO_ROOT}/scripts/completions/${f}" | grep -E 'base' | head -1)"
    missing=""
    for word in ${steps}; do
        [[ " ${only_line//[\"\']/ } " == *" ${word} "* ]] || missing+=" ${word}"
    done
    if [[ -z "${missing}" ]]; then ok "${f} --only completes every step"; else ko "${f} --only completes every step" "missing:${missing}"; fi
done

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
