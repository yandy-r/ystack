#!/usr/bin/env bash
# install.sh tests — --package: each package id maps onto its target's native
# route (claude/codex plugin installs, cursor marketplace step, omp packages),
# installer-fallback settings/rules ride along, no legacy carrier is written,
# rejections fail before mutations, and the --intent regression spot-check.
#
# Runs alone (bash scripts/tests/install/packages.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codex_first_agent="$(find "${REPO_ROOT}/.codex-plugin/agents" -maxdepth 1 -name '*.toml' -printf '%f\n' 2>/dev/null | sort | head -n 1)"

# no_claude_legacy <home> — none of the pre-native Claude carriers exist.
no_claude_legacy() {
    local h="$1"
    [[ ! -e "${h}/.claude/hooks" && ! -L "${h}/.claude/hooks" && ! -e "${h}/.claude/skills" \
        && ! -e "${h}/.claude.json" && ! -e "${h}/project/.mcp.json" ]] \
        && ! grep -q '"hooks"' "${h}/.claude/settings.json" 2>/dev/null
}

echo "== install.sh install --package: claude native routes =="

home="$(new_home)"
install_must_succeed "${home}" install --target claude --package ycc
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_contains "${calls}" "plugin marketplace add" "claude ycc registers the marketplace"
assert_contains "${calls}" "plugin install ycc@ycc --scope user" "claude ycc installs ycc@ycc"
assert_not_contains "${calls}" "ycc-mcp@ycc" "claude ycc installs no ycc-mcp"
assert_not_contains "${calls}" "ycc-hooks@ycc" "claude ycc installs no ycc-hooks"
assert_contains "$(cat "${home}/.claude/settings.json" 2>/dev/null)" '"claude-fable-5-1"' "claude ycc merges fallback settings"
if [[ -L "${home}/.claude/CLAUDE.md" ]]; then ok "claude ycc links fallback rules"; else ko "claude ycc links fallback rules" "${INSTALL_OUT}"; fi
if no_claude_legacy "${home}"; then ok "claude ycc writes no legacy carrier"; else ko "claude ycc writes no legacy carrier"; fi

home="$(new_home)"
install_must_succeed "${home}" install --target claude --package ycc-mcp
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_contains "${calls}" "plugin install ycc-mcp@ycc --scope user" "claude ycc-mcp installs ycc-mcp@ycc at user scope"
assert_not_contains "${calls}" "plugin install ycc@ycc" "claude ycc-mcp installs no ycc@ycc"
assert_contains "$(cat "${home}/.claude/settings.json" 2>/dev/null)" '"claude-fable-5-1"' "claude ycc-mcp includes fallback settings"
if [[ -L "${home}/.claude/CLAUDE.md" ]]; then ok "claude ycc-mcp includes fallback rules"; else ko "claude ycc-mcp includes fallback rules"; fi
if no_claude_legacy "${home}"; then ok "claude ycc-mcp merges no MCP config"; else ko "claude ycc-mcp merges no MCP config"; fi

home="$(new_home)"
install_must_succeed "${home}" install --target claude --package ycc-hooks
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_contains "${calls}" "plugin install ycc-hooks@ycc --scope user" "claude ycc-hooks installs ycc-hooks@ycc at user scope"
assert_contains "$(cat "${home}/.claude/settings.json" 2>/dev/null)" '"claude-fable-5-1"' "claude ycc-hooks includes fallback settings"
if no_claude_legacy "${home}"; then ok "claude ycc-hooks links no hooks dir and merges no hook group"; else ko "claude ycc-hooks links no hooks dir and merges no hook group"; fi

home="$(new_home)"
install_must_succeed "${home}" install --target claude --package ycc-all
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
for pkg in ycc ycc-mcp ycc-hooks; do
    assert_contains "${calls}" "plugin install ${pkg}@ycc --scope user" "claude ycc-all installs ${pkg}@ycc"
done
if no_claude_legacy "${home}"; then ok "claude ycc-all writes no legacy carrier"; else ko "claude ycc-all writes no legacy carrier"; fi

echo
echo "== install.sh install --package: codex native routes =="

home="$(new_home)"
install_must_succeed "${home}" install --target codex --package ycc --mode local
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_contains "${calls}" "codex plugin marketplace add" "codex ycc registers the native marketplace"
assert_contains "${calls}" "codex plugin add ycc@ycc" "codex ycc installs ycc@ycc"
assert_contains "${calls}" "codex plugin add ycc-mcp@ycc" "codex ycc installs its MCP companion"
assert_not_contains "${calls}" "local-ycc-plugins" "codex ycc never uses the legacy catalog"
assert_contains "$(cat "${home}/.codex/config.toml" 2>/dev/null)" 'model = "gpt-6-astra"' "codex ycc merges fallback settings"
assert_not_contains "$(cat "${home}/.codex/config.toml" 2>/dev/null)" "[mcp_servers." "codex ycc merges no MCP servers"
if [[ -L "${home}/.codex/AGENTS.md" && -L "${home}/.codex/rules/default.rules" ]]; then ok "codex ycc links fallback rules"; else ko "codex ycc links fallback rules" "${INSTALL_OUT}"; fi
if [[ -n "${codex_first_agent}" && -f "${home}/.codex/agents/${codex_first_agent}" ]]; then ok "codex ycc (local) copies custom agents"; else ko "codex ycc (local) copies custom agents" "${INSTALL_OUT}"; fi
if [[ ! -e "${home}/.codex/plugins/ycc" && ! -e "${home}/.agents/plugins/marketplace.json" && ! -e "${home}/.codex/skills" ]]; then
    ok "codex ycc writes no legacy link, catalog or skills copy"
else
    ko "codex ycc writes no legacy link, catalog or skills copy"
fi

home="$(new_home)"
install_must_succeed "${home}" install --target codex --package ycc --mode repo
assert_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "codex plugin marketplace add https://github.com/yandy-r/ystack.git --ref main" "codex ycc (repo) registers the git marketplace"
if [[ -n "${codex_first_agent}" && -f "${home}/.codex/agents/${codex_first_agent}" ]]; then ok "codex ycc (repo) still copies custom agents"; else ko "codex ycc (repo) still copies custom agents" "${INSTALL_OUT}"; fi

home="$(new_home)"
install_must_succeed "${home}" install --target codex --package ycc-mcp
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_contains "${calls}" "codex plugin add ycc-mcp@ycc" "codex ycc-mcp installs ycc-mcp@ycc"
assert_not_contains "${calls}" "codex plugin add ycc@ycc" "codex ycc-mcp installs no ycc@ycc"
assert_contains "$(cat "${home}/.codex/config.toml" 2>/dev/null)" 'model = "gpt-6-astra"' "codex ycc-mcp includes fallback settings"
if [[ ! -e "${home}/project/.codex/config.toml" ]] && ! grep -q '\[mcp_servers\.' "${home}/.codex/config.toml" 2>/dev/null; then
    ok "codex ycc-mcp merges no [mcp_servers] table"
else
    ko "codex ycc-mcp merges no [mcp_servers] table"
fi
if [[ -L "${home}/.codex/AGENTS.md" && -f "${home}/.codex/agents/${codex_first_agent}" ]]; then ok "codex ycc-mcp includes fallback rules and agents"; else ko "codex ycc-mcp includes fallback rules and agents"; fi

echo
echo "== install.sh install --package: cursor marketplace step =="

for pkg in ycc ycc-rules ycc-mcp ycc-hooks; do
    home="$(new_home)"
    install_must_succeed "${home}" install --target cursor --package "${pkg}"
    assert_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "agent plugin marketplace add https://github.com/yandy-r/ystack" "cursor ${pkg} registers the marketplace"
    assert_contains "${INSTALL_OUT}" "/plugins" "cursor ${pkg} prints the /plugins step"
    assert_contains "${INSTALL_OUT}" "${pkg}" "cursor ${pkg} hint names the package"
    assert_contains "$(cat "${home}/.cursor/cli-config.json" 2>/dev/null)" '"claude-fable-5-1"' "cursor ${pkg} includes fallback settings"
    left=""
    for f in skills agents rules commands hooks hooks.json mcp.json; do
        [[ -e "${home}/.cursor/${f}" ]] && left+=" ${f}"
    done
    [[ -e "${home}/project/.cursor/mcp.json" ]] && left+=" project/.cursor/mcp.json"
    if [[ -z "${left}" ]]; then ok "cursor ${pkg} copies no file carrier"; else ko "cursor ${pkg} copies no file carrier" "found:${left}"; fi
done

echo
echo "== install.sh install --package: CSV, --target all, regressions =="

home="$(new_home)"
install_must_succeed "${home}" install --target claude --package ycc,ycc,ycc-mcp
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
count="$(grep -c "plugin install ycc@ycc" <<< "${calls}")"
if [[ "${count}" == "1" ]]; then ok "package CSV dedups base registration"; else ko "package CSV dedups base registration" "ran ${count} times"; fi
assert_contains "${calls}" "plugin install ycc-mcp@ycc" "package CSV expands every unique package"

home="$(new_home)"
install_must_succeed "${home}" install --target all --package ycc
out="${INSTALL_OUT}"
for target in opencode agents; do
    assert_contains "${out}" "package 'ycc' is not available for target '${target}' — skipping target '${target}'" "--package --target all warns and skips ${target}"
done
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_contains "${calls}" "plugin install ycc@ycc" "--package --target all installs claude ycc@ycc"
assert_contains "${calls}" "codex plugin add ycc@ycc" "--package --target all installs codex ycc@ycc"
assert_contains "${calls}" "agent plugin marketplace add" "--package --target all registers the cursor marketplace"
for f in .claude/CLAUDE.md .codex/AGENTS.md; do
    if [[ -e "${home}/${f}" ]]; then ok "--package --target all still delivers ${f}"; else ko "--package --target all still delivers ${f}" "${out}"; fi
done
if [[ ! -e "${home}/project/opencode.json" && ! -e "${home}/.agents/skills" ]]; then ok "--package --target all skips unsupported target delivery"; else ko "--package --target all skips unsupported target delivery"; fi

# ycc-hooks under --target all: excluded Codex is skipped; Claude and Cursor run.
home="$(new_home)"
install_must_succeed "${home}" install --target all --package ycc-hooks
out="${INSTALL_OUT}"
assert_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin install ycc-hooks@ycc" "--package ycc-hooks --target all installs claude ycc-hooks@ycc"
assert_contains "${out}" "skipping target 'codex'" "--package ycc-hooks --target all skips codex"
assert_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "agent plugin marketplace add" "--package ycc-hooks --target all registers the cursor marketplace"

# Every unsupported target: nothing deliverable fails.
home="$(new_home)"
out="$(run_install "${home}" install --target opencode,agents --package ycc 2>&1)" && rc=0 || rc=$?
if [[ ${rc} -ne 0 ]]; then ok "--package with only unsupported targets fails"; else ko "--package with only unsupported targets fails"; fi

# The opencode npm package installs through --package: one plugins entry.
home="$(new_home)"
install_must_succeed "${home}" install --target opencode --package "@yandy-r/ycc-opencode"
assert_contains "$(cat "${home}/.config/opencode/opencode.json" 2>/dev/null)" "file://${REPO_ROOT}/packages/opencode/ycc-opencode" "--package @yandy-r/ycc-opencode writes the local plugins entry"
assert_contains "${INSTALL_OUT}" "opencode install complete" "--package @yandy-r/ycc-opencode runs the opencode base step"
if [[ ! -e "${home}/.config/opencode/skills" && ! -e "${home}/project/opencode.json" ]]; then ok "--package @yandy-r/ycc-opencode copies no files and writes no settings"; else ko "--package @yandy-r/ycc-opencode copies no files and writes no settings"; fi

home="$(new_home)"
install_must_succeed "${home}" install --target all --package "@yandy-r/ycc-opencode"
assert_contains "$(cat "${home}/.config/opencode/opencode.json" 2>/dev/null)" "ycc-opencode" "--package @yandy-r/ycc-opencode --target all installs on opencode"
assert_contains "${INSTALL_OUT}" "skipping target 'claude'" "--package @yandy-r/ycc-opencode --target all skips the other targets"

# --intent keeps working after --package support (representative regressions).
home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings
out="${INSTALL_OUT}"
assert_contains "$(cat "${home}/project/.claude/settings.json" 2>/dev/null)" '"claude-fable-5-1"' "--intent settings defaults to the project after --package support"
assert_not_contains "${out}" "--package" "--intent sync prints no --package diagnostics"
assert_not_contains "${out}" "package components" "--intent sync reports no package component skips"

home="$(new_home)"
install_must_succeed "${home}" install --target claude --only rules
if [[ -L "${home}/.claude/CLAUDE.md" ]]; then ok "install --only path unchanged by --package support"; else ko "install --only path unchanged by --package support"; fi

echo
echo "== install.sh install --package: rejections fail before mutations =="

# tree_snapshot <home> — sorted listing of every path (with link targets), for no-mutation checks.
tree_snapshot() {
    (cd "$1" && find . -mindepth 1 -printf '%p %y %l\n' | sort)
}

# assert_package_rejected <name> <needle> <install args...> — fresh HOME, expect
# non-zero exit, the diagnostic, and an identical HOME tree afterwards.
assert_package_rejected() {
    local name="$1" needle="$2" home before after out rc=0
    shift 2
    home="$(new_home)"
    before="$(tree_snapshot "${home}")"
    out="$(run_install "${home}" "$@")" || rc=$?
    if [[ ${rc} -ne 0 ]]; then ok "${name} exits non-zero"; else ko "${name} exits non-zero" "${out}"; fi
    assert_contains "${out}" "${needle}" "${name} reports its reason"
    after="$(tree_snapshot "${home}")"
    if [[ "${before}" == "${after}" ]]; then ok "${name} mutates nothing"; else ko "${name} mutates nothing" "$(diff <(echo "${before}") <(echo "${after}"))"; fi
}

assert_package_rejected "ycc on opencode" "package 'ycc' is not available for target 'opencode'" install --target opencode --package ycc
assert_package_rejected "ycc on agents" "package 'ycc' is not available for target 'agents'" install --target agents --package ycc
assert_package_rejected "ycc-hooks on codex" "package 'ycc-hooks'" install --target codex --package ycc-hooks
assert_package_rejected "ycc-all on codex" "package 'ycc-all' is not available for target 'codex'" install --target codex --package ycc-all
assert_package_rejected "ycc-rules on claude" "package 'ycc-rules' is not available for target 'claude'" install --target claude --package ycc-rules
assert_package_rejected "unknown package" "unknown package 'bogus'" install --target claude --package bogus
assert_package_rejected "installer-fallback" "installer-fallback is an internal modeling key" install --target claude --package installer-fallback
assert_package_rejected "ycc-agents" "package 'ycc-agents' is deferred, excluded, opt-in, or not an installable package" install --target claude --package ycc-agents
assert_package_rejected "npm opencode package on claude" "package '@yandy-r/ycc-opencode' is not available for target 'claude'" install --target claude --package "@yandy-r/ycc-opencode"
assert_package_rejected "valid plus invalid package" "unknown package 'bogus'" install --target claude --package ycc,bogus
assert_package_rejected "valid target plus unsupported explicit target" "package 'ycc' is not available for target 'opencode'" install --target claude,opencode --package ycc
assert_package_rejected "multi-target unsupported hooks" "package 'ycc-hooks'" install --target claude,codex --package ycc-hooks
assert_package_rejected "empty package token" "--package contains an empty value" install --target claude --package "ycc,,ycc-mcp"
assert_package_rejected "missing package argument" "--package requires an argument" install --target claude --package
assert_package_rejected "--package with --intent" "--package cannot be combined with --intent, --only, --settings, --rules, --mcp, or --hooks" install --target claude --package ycc --intent settings
assert_package_rejected "--package with --only" "--package cannot be combined with --intent, --only, --settings, --rules, --mcp, or --hooks" install --target claude --package ycc --only base
for flag in --settings --rules --mcp --hooks; do
    assert_package_rejected "--package with ${flag}" "--package cannot be combined with --intent, --only, --settings, --rules, --mcp, or --hooks" install --target claude --package ycc "${flag}"
done
assert_package_rejected "--package with --skills on claude" "narrow only the agents target" install --target claude --package ycc-mcp --skills plan
assert_package_rejected "sync --package" "--package is only supported by the 'install' subcommand" sync --target claude --intent settings --package ycc
assert_package_rejected "remove --package" "--package is only supported by the 'install' subcommand" remove --target claude --only base --package ycc
assert_package_rejected "cli --package" "--package is only supported by the 'install' subcommand" cli --package ycc
assert_package_rejected "completion --package" "--package is only supported by the 'install' subcommand" completion --shell bash --package ycc
assert_package_rejected "list --package" "--package is only supported by the 'install' subcommand" list skills --package ycc

# Package runs keep settings global even though unscoped settings default to the project.
for target in claude codex cursor; do
    home="$(new_home)"
    install_must_succeed "${home}" install --target "${target}" --package ycc,ycc-mcp
    case "${target}" in
        claude) global_dest="${home}/.claude/settings.json"; project_dest="${home}/project/.claude/settings.json" ;;
        codex) global_dest="${home}/.codex/config.toml"; project_dest="${home}/project/.codex/config.toml" ;;
        cursor) global_dest="${home}/.cursor/cli-config.json"; project_dest="${home}/project/.cursor/cli-config.json" ;;
    esac
    if [[ -f "${global_dest}" ]]; then ok "${target} package run keeps settings global"; else ko "${target} package run keeps settings global" "${INSTALL_OUT}"; fi
    if [[ ! -e "${project_dest}" ]]; then ok "${target} package run writes no project settings"; else ko "${target} package run writes no project settings"; fi
done

# Explicit failures leave a pre-existing environment untouched too (not only empty HOMEs).
home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings --global
before="$(tree_snapshot "${home}")"
out="$(run_install "${home}" install --target claude,opencode --package ycc)" && rc=0 || rc=$?
after="$(tree_snapshot "${home}")"
if [[ ${rc} -ne 0 && "${before}" == "${after}" ]]; then ok "rejected package install leaves an existing HOME untouched"; else ko "rejected package install leaves an existing HOME untouched" "rc=${rc} ${out}"; fi

echo
echo "== --package completions =="

for f in _ycc ycc.bash ycc.fish; do
    assert_contains "$(cat "${REPO_ROOT}/scripts/completions/${f}")" "ycc ycc-mcp ycc-hooks ycc-rules ycc-all" "${f} lists the installable package ids"
    assert_not_contains "$(grep -- 'package' "${REPO_ROOT}/scripts/completions/${f}")" "installer-fallback" "${f} keeps installer-fallback out of --package"
done
out="$(bash -c 'source "$1"; COMP_WORDS=(ycc install --package ycc-m); COMP_CWORD=3; _ycc; echo "${COMPREPLY[*]}"' \
    _ "${REPO_ROOT}/scripts/completions/ycc.bash")"
assert_contains "${out}" "ycc-mcp" "bash completes package ids for install"
out="$(bash -c 'source "$1"; COMP_WORDS=(ycc install --package ycc,ycc-h); COMP_CWORD=3; _ycc; echo "${COMPREPLY[*]}"' \
    _ "${REPO_ROOT}/scripts/completions/ycc.bash")"
assert_contains "${out}" "ycc,ycc-hooks" "bash completes package CSV items"
out="$(bash -c 'source "$1"; COMP_WORDS=(ycc install --pack); COMP_CWORD=2; _ycc; echo "${COMPREPLY[*]}"' \
    _ "${REPO_ROOT}/scripts/completions/ycc.bash")"
assert_contains "${out}" "--package" "bash completes the --package flag for install"
for sub in sync remove; do
    out="$(bash -c 'source "$1"; COMP_WORDS=(ycc "$2" --pack); COMP_CWORD=2; _ycc; echo "${COMPREPLY[*]}"' \
        _ "${REPO_ROOT}/scripts/completions/ycc.bash" "${sub}")"
    assert_not_contains "${out}" "--package" "bash keeps --package out of ${sub}"
    out="$(bash -c 'source "$1"; COMP_WORDS=(ycc "$2" --package ycc-m); COMP_CWORD=3; _ycc; echo "${COMPREPLY[*]}"' \
        _ "${REPO_ROOT}/scripts/completions/ycc.bash" "${sub}")"
    assert_not_contains "${out}" "ycc-mcp" "bash offers no package ids for ${sub}"
done

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
