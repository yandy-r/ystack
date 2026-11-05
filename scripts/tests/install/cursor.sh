#!/usr/bin/env bash
# install.sh tests — cursor: native marketplace base step (stub 'agent' CLI),
# /plugins hint, automatic legacy cleanup, and the global-only settings step.
#
# Runs alone (bash scripts/tests/install/cursor.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CURSOR_URL="https://github.com/yandy-r/ystack"

# cursor_legacy_dirs_absent <home> — true when no file-copy carrier exists.
cursor_legacy_dirs_absent() {
    local d
    for d in skills agents rules commands hooks; do
        [[ ! -e "$1/.cursor/${d}" ]] || return 1
    done
    [[ ! -e "$1/.cursor/hooks.json" && ! -e "$1/.cursor/mcp.json" ]]
}

echo "== install.sh sync: cursor settings =="

home="$(new_home)"
install_must_succeed "${home}" sync --target cursor --intent settings
out="${INSTALL_OUT}"
assert_contains "${out}" "settings have no project scope" "cursor default settings explains the project-scope skip"
assert_contains "${out}" "carries permissions only" "cursor default settings prints the scope note"
assert_contains "${out}" "Pass --global to" "cursor default settings names the global recovery flag"
if [[ ! -e "${home}/.cursor/cli-config.json" && ! -e "${home}/.config/ycc/managed-config-state.json" ]]; then
    ok "cursor default settings writes nothing"
else
    ko "cursor default settings writes nothing" "${out}"
fi
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "agent plugin" "cursor settings-only runs no agent CLI"

install_must_succeed "${home}" sync --target cursor --intent settings --global
assert_contains "$(cat "${home}/.cursor/cli-config.json")" '"claude-fable-5-1"' "cursor CLI model applied with --global"

out="$(run_install "${home}" sync --target cursor --intent settings --project)" && rc=0 || rc=$?
if [[ ${rc} -ne 0 ]]; then ok "cursor explicit --project settings is rejected"; else ko "cursor explicit --project settings is rejected" "${out}"; fi
assert_contains "${out}" "--project is not supported by step 'settings' for target 'cursor'" "cursor --project settings reports the unsupported step"
assert_contains "${out}" "carries permissions only" "cursor --project settings prints the scope note"
before="$(cat "${home}/.cursor/cli-config.json")"
install_must_succeed "${home}" remove --target cursor --intent settings
assert_contains "${INSTALL_OUT}" "settings have no project scope" "cursor default remove explains the project-scope skip"
assert_contains "$(cat "${home}/.cursor/cli-config.json")" "${before}" "cursor default remove keeps the global settings"
install_must_succeed "${home}" remove --target cursor --intent settings --global
assert_not_contains "$(cat "${home}/.cursor/cli-config.json" 2>/dev/null)" '"claude-fable-5-1"' "cursor --global remove drops managed settings"

home="$(new_home)"
cat > "${home}/.cursor/cli-config.json" <<'JSON'
{ "privacyMode": 1, "permissions": { "allow": ["Shell(ls)"], "deny": [] } }
JSON
install_must_succeed "${home}" sync --target cursor --intent settings --global
install_must_succeed "${home}" remove --target cursor --intent settings --global
merged="$(cat "${home}/.cursor/cli-config.json")"
assert_contains "${merged}" '"privacyMode": 1' "cursor remove keeps unmanaged keys"
assert_contains "${merged}" '"Shell(ls)"' "cursor remove keeps user permission entries"
assert_not_contains "${merged}" '"modelId"' "cursor remove drops managed model"

echo
echo "== install.sh install: cursor native marketplace =="

home="$(new_home)"
install_must_succeed "${home}" install --target cursor
out="${INSTALL_OUT}"
log="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_contains "${log}" "agent plugin marketplace add ${CURSOR_URL}" "cursor install registers the GitHub marketplace"
assert_contains "${out}" "Cursor rejects filesystem marketplaces" "cursor local mode notes it registers the published catalog"
assert_contains "${out}" "open /plugins" "cursor install prints the /plugins hint"
assert_contains "${out}" "select: ycc" "cursor install hint names the ycc package"
assert_not_contains "${out}" "ycc-mcp" "cursor base hint names only the requested packages"
if cursor_legacy_dirs_absent "${home}"; then ok "cursor install writes no file-copy carriers"; else ko "cursor install writes no file-copy carriers" "$(find "${home}/.cursor" -mindepth 1 -maxdepth 1)"; fi

# Already registered: the add is skipped.
home="$(new_home)"
AGENT_STUB_MARKETPLACES='[{"name":"ycc","source":"https://github.com/yandy-r/ystack"}]' \
    install_must_succeed "${home}" install --target cursor
log="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_not_contains "${log}" "agent plugin marketplace add" "cursor install skips an already-registered marketplace"
assert_contains "${INSTALL_OUT}" "already registered" "cursor install says the marketplace is registered"

# Intents name their native packages; every content intent maps to the one base step.
home="$(new_home)"
install_must_succeed "${home}" sync --target cursor --intent skills,rules,mcp,hooks
out="${INSTALL_OUT}"
assert_contains "${out}" "select: ycc ycc-rules ycc-mcp ycc-hooks" "cursor intents name ycc, ycc-rules, ycc-mcp and ycc-hooks"
count="$(grep -c "agent plugin marketplace add" "${home}/claude-calls.log")"
if [[ "${count}" == "1" ]]; then ok "cursor intents run one marketplace step"; else ko "cursor intents run one marketplace step" "${count}"; fi
if cursor_legacy_dirs_absent "${home}"; then ok "cursor intents write no file-copy carriers"; else ko "cursor intents write no file-copy carriers"; fi

home="$(new_home)"
install_must_succeed "${home}" install --target cursor --package ycc-hooks
assert_contains "${INSTALL_OUT}" "select: ycc-hooks" "cursor --package names that package in the hint"
assert_contains "$(cat "${home}/claude-calls.log")" "agent plugin marketplace add ${CURSOR_URL}" "cursor --package registers the marketplace"

home="$(new_home)"
install_must_succeed "${home}" install --target cursor --mode repo
assert_contains "$(cat "${home}/claude-calls.log")" "agent plugin marketplace add ${CURSOR_URL}" "cursor --mode repo registers the GitHub marketplace"
assert_not_contains "${INSTALL_OUT}" "Cursor rejects filesystem marketplaces" "cursor --mode repo needs no local-mode note"

home="$(new_home)"
install_must_succeed "${home}" install --target cursor --dry-run
assert_contains "${INSTALL_OUT}" "[dry-run] would run: agent plugin marketplace add ${CURSOR_URL}" "cursor dry-run prints the planned command"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "agent plugin marketplace add" "cursor dry-run runs no agent CLI mutation"

echo
echo "== install.sh install: cursor without the agent CLI =="

home="$(new_home)"
# Hide 'agent': the stub dir minus agent, then PATH minus any dir holding an agent binary.
filtered_stub="${SANDBOX_ROOT}/stub-no-agent"
mkdir -p "${filtered_stub}"
for f in "${STUB_BIN}"/*; do [[ "$(basename "${f}")" == agent ]] || ln -sf "${f}" "${filtered_stub}/"; done
system_path=""
IFS=':' read -r -a path_parts <<< "${PATH}"
for part in "${path_parts[@]}"; do
    [[ -x "${part}/agent" ]] && continue
    system_path+="${system_path:+:}${part}"
done
out="$(
    cd "${home}/project" && HOME="${home}" PATH="${filtered_stub}:${system_path}" \
        CLAUDE_STUB_LOG="${home}/claude-calls.log" YCC_INSTALL_SKIP_BUILD=1 \
        YCC_MANAGED_CONFIG_STATE="${home}/.config/ycc/managed-config-state.json" \
        bash "${INSTALL}" install --target cursor 2>&1
)" && rc=0 || rc=$?
if [[ ${rc} -eq 0 ]]; then ok "cursor install without the agent CLI succeeds"; else ko "cursor install without the agent CLI succeeds" "${out}"; fi
assert_contains "${out}" "Cursor 'agent' CLI not found" "cursor install warns when the agent CLI is missing"
assert_contains "${out}" "in the Cursor IDE open /plugins" "missing agent CLI warning gives the IDE steps"
assert_contains "${out}" "${CURSOR_URL}" "missing agent CLI warning names the marketplace URL"

echo
echo "== install.sh: cursor legacy cleanup =="

# A byte-identical file-copy skill goes; an edited one and a user skill stay.
home="$(new_home)"
mkdir -p "${home}/.cursor/skills"
cp -R "${REPO_ROOT}/packages/cursor/ycc/skills/plan" "${home}/.cursor/skills/"
cp -R "${REPO_ROOT}/packages/cursor/ycc/skills/clean" "${home}/.cursor/skills/"
echo "# my edit" >> "${home}/.cursor/skills/clean/SKILL.md"
mkdir -p "${home}/.cursor/skills/my-own-skill"
install_must_succeed "${home}" install --target cursor
if [[ ! -e "${home}/.cursor/skills/plan" ]]; then ok "cursor install retires a byte-identical legacy skill copy"; else ko "cursor install retires a byte-identical legacy skill copy" "${INSTALL_OUT}"; fi
assert_contains "$(cat "${home}/.cursor/skills/clean/SKILL.md" 2>/dev/null)" "# my edit" "cursor install keeps an edited legacy skill copy"
if [[ -d "${home}/.cursor/skills/my-own-skill" ]]; then ok "cursor install keeps user skills"; else ko "cursor install keeps user skills"; fi
assert_contains "${INSTALL_OUT}" "edited or ownership uncertain" "cursor cleanup reports the kept edited copy"

# A dry-run previews the retirement and changes nothing.
home="$(new_home)"
mkdir -p "${home}/.cursor/skills"
cp -R "${REPO_ROOT}/packages/cursor/ycc/skills/plan" "${home}/.cursor/skills/"
install_must_succeed "${home}" install --target cursor --dry-run
assert_contains "${INSTALL_OUT}" "would remove ${home}/.cursor/skills/plan" "cursor dry-run previews the legacy retirement"
if [[ -d "${home}/.cursor/skills/plan" ]]; then ok "cursor dry-run keeps the legacy copy"; else ko "cursor dry-run keeps the legacy copy"; fi

# Old rules links to this checkout go; a foreign file stays.
home="$(new_home)"
ln -s "${REPO_ROOT}/ycc/settings/rules/CLAUDE.md" "${home}/.cursor/CLAUDE.md"
echo mine > "${home}/.cursor/AGENTS.md"
install_must_succeed "${home}" install --target cursor
if [[ ! -e "${home}/.cursor/CLAUDE.md" && ! -L "${home}/.cursor/CLAUDE.md" ]]; then ok "cursor install retires the legacy rules link"; else ko "cursor install retires the legacy rules link"; fi
assert_contains "${INSTALL_OUT}" "select: ycc ycc-rules" "cursor hint names ycc-rules after retiring the legacy rules link"
assert_contains "$(cat "${home}/.cursor/AGENTS.md")" mine "cursor install keeps a user AGENTS.md"

# The old global MCP merge: ycc-written servers go, a user server stays.
home="$(new_home)"
echo '{"mcpServers":{"mine":{"command":"my-server"}}}' > "${home}/.cursor/mcp.json"
HOME="${home}" YCC_MANAGED_CONFIG_STATE="${home}/.config/ycc/managed-config-state.json" \
    python3 "${REPO_ROOT}/scripts/merge_managed_config.py" --profile cursor-mcp \
    --source "${REPO_ROOT}/mcp-configs/mcp.json" --destination "${home}/.cursor/mcp.json" --groups mcp >/dev/null \
    || { ko "cursor legacy fixture: mcp.json"; exit 1; }
ycc_server="$(python3 -c 'import json,sys; print(next(iter(json.load(open(sys.argv[1]))["mcpServers"])))' "${REPO_ROOT}/mcp-configs/mcp.json")"
assert_contains "$(cat "${home}/.cursor/mcp.json")" "\"${ycc_server}\"" "fixture: legacy merge wrote a ycc MCP server"
install_must_succeed "${home}" install --target cursor
merged="$(cat "${home}/.cursor/mcp.json")"
assert_not_contains "${merged}" "\"${ycc_server}\"" "cursor install retires the legacy ycc MCP merge"
assert_contains "${merged}" '"my-server"' "cursor install keeps a user MCP server"
assert_contains "${INSTALL_OUT}" "select: ycc ycc-mcp" "cursor hint names ycc-mcp after retiring the legacy MCP merge"

# A user's own command that mentions ~/.agents/skills is unrecorded: kept, never blocking.
home="$(new_home)"
mkdir -p "${home}/.cursor/commands"
printf 'Run the skill in ~/.agents/skills/plan/SKILL.md\n' > "${home}/.cursor/commands/plan.md"
ln -s "${home}/.cursor/commands/plan.md" "${home}/.cursor/commands/alias.md"
install_must_succeed "${home}" install --target cursor
# shellcheck disable=SC2088  # the literal ~ text the user's command contains.
assert_contains "$(cat "${home}/.cursor/commands/plan.md")" "~/.agents/skills/plan" "cursor install keeps a user command mentioning ~/.agents/skills"
if [[ -L "${home}/.cursor/commands/alias.md" ]]; then ok "cursor install keeps a user command symlink"; else ko "cursor install keeps a user command symlink"; fi
assert_contains "${INSTALL_OUT}" "not recorded as installed by ycc" "cursor cleanup reports the kept user commands"
assert_not_contains "${INSTALL_OUT}" "cleanup kept every file-copy leftover" "a user command does not stop the cleanup"

echo
echo "== install.sh remove: cursor =="

home="$(new_home)"
AGENT_STUB_MARKETPLACES='[{"name":"ycc","source":"https://github.com/yandy-r/ystack"}]' \
    install_must_succeed "${home}" remove --target cursor --intent base
assert_contains "$(cat "${home}/claude-calls.log")" "agent plugin marketplace remove ycc" "cursor remove drops the registered marketplace"

# A content intent on remove never drops the marketplace (that would uninstall every package).
home="$(new_home)"
AGENT_STUB_MARKETPLACES='[{"name":"ycc","source":"https://github.com/yandy-r/ystack"}]' \
    install_must_succeed "${home}" remove --target cursor --intent hooks,mcp
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "agent plugin marketplace remove" "cursor remove --intent hooks,mcp keeps the marketplace"
assert_contains "${INSTALL_OUT}" "uninstall ycc-hooks ycc-mcp from Cursor's /plugins" "cursor remove --intent hooks,mcp names the packages to uninstall in /plugins"
assert_not_contains "${INSTALL_OUT}" "ran no steps" "cursor remove --intent hooks reports the notice as its action"

home="$(new_home)"
mkdir -p "${home}/.cursor/agents"
cp -R "${REPO_ROOT}/packages/cursor/ycc/agents/." "${home}/.cursor/agents/"
install_must_succeed "${home}" remove --target cursor --intent base
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "agent plugin marketplace remove" "cursor remove skips an unregistered marketplace"
if [[ -z "$(ls -A "${home}/.cursor/agents" 2>/dev/null)" ]]; then ok "cursor remove retires byte-identical legacy agents"; else ko "cursor remove retires byte-identical legacy agents" "$(ls -A "${home}/.cursor/agents")"; fi

echo "== install.sh: cursor legacy carriers retire through install =="

# cursor_snapshot <home> — names, bytes, modes and link text of every entry.
cursor_snapshot() {
    python3 - "$1" <<'PY'
import hashlib, os, sys
from pathlib import Path
root = Path(sys.argv[1])
items = []
for path in sorted(root.rglob('*')):
    if path.name == 'claude-calls.log':
        continue
    kind = 'link' if path.is_symlink() else 'dir' if path.is_dir() else 'file'
    content = os.readlink(path).encode() if kind == 'link' else path.read_bytes() if kind == 'file' else b''
    items.append((str(path.relative_to(root)), kind, path.lstat().st_mode, hashlib.sha256(content).hexdigest()))
print(repr(items))
PY
}

# cursor_seed_legacy <home> — what the removed file-copy installer left behind:
# projected skills, commands wrappers and the sessionStart hook (script plus
# hooks.json registration), all recorded in the ycc ownership state.
cursor_seed_legacy() {
    local home="$1" slice
    for slice in skills agents commands hooks; do
        HOME="${home}" YCC_MANAGED_CONFIG_STATE="${home}/.config/ycc/managed-config-state.json" \
            YCC_CURSOR_SKILLS_HOME="${home}/.cursor/skills" \
            python3 "${REPO_ROOT}/scripts/install_slices.py" install --target cursor --slice "${slice}" >/dev/null \
            || { ko "cursor legacy fixture: ${slice}"; exit 1; }
    done
    HOME="${home}" YCC_MANAGED_CONFIG_STATE="${home}/.config/ycc/managed-config-state.json" \
        python3 "${REPO_ROOT}/scripts/merge_managed_config.py" --profile cursor-hooks \
        --source "${REPO_ROOT}/packages/cursor/ycc-hooks/hooks/hooks.json" \
        --destination "${home}/.cursor/hooks.json" --groups hooks >/dev/null \
        || { ko "cursor legacy fixture: hooks.json"; exit 1; }
}

home="$(new_home)"
cursor_seed_legacy "${home}"
printf '\nuser edit\n' >> "${home}/.cursor/skills/git-workflow/SKILL.md"
mkdir -p "${home}/.cursor/skills/mine"
printf 'mine\n' > "${home}/.cursor/skills/mine/SKILL.md"
printf 'my independent command\n' > "${home}/.cursor/commands/mine.md"
python3 - "${home}/.cursor/hooks.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text())
data['hooks']['sessionStart'].append({'command': 'echo my-session-hook'})
path.write_text(json.dumps(data, indent=2) + '\n')
PY
before="$(cursor_snapshot "${home}")"
install_must_succeed "${home}" install --target cursor --dry-run
assert_contains "${INSTALL_OUT}" "would retire" "cursor dry-run previews the carrier retirement"
if [[ "$(cursor_snapshot "${home}")" == "${before}" ]]; then ok "cursor dry-run preserves carriers, skills and state"; else ko "cursor dry-run preserves carriers, skills and state"; fi
install_must_succeed "${home}" install --target cursor
if [[ ! -e "${home}/.cursor/commands/clean.md" && ! -e "${home}/.cursor/skills/clean" ]]; then ok "cursor install retires owned wrappers and their projected skills"; else ko "cursor install retires owned wrappers and their projected skills" "${INSTALL_OUT}"; fi
if [[ ! -e "${home}/.cursor/hooks/herdr-session-start.sh" ]]; then ok "cursor install retires the installer hook script"; else ko "cursor install retires the installer hook script"; fi
assert_not_contains "$(cat "${home}/.cursor/hooks.json")" "herdr-session-start.sh" "cursor install retires the installer sessionStart registration"
assert_contains "${INSTALL_OUT}" "select: ycc ycc-hooks" "cursor hint names ycc-hooks after retiring the legacy hook"
assert_contains "$(cat "${home}/.cursor/hooks.json")" "echo my-session-hook" "cursor install keeps a foreign sessionStart command"
assert_contains "$(cat "${home}/.cursor/commands/mine.md")" "my independent command" "cursor install keeps a foreign command file"
assert_contains "$(cat "${home}/.cursor/skills/git-workflow/SKILL.md")" "user edit" "cursor recorded names never authorize deleting edits"
if [[ -d "${home}/.cursor/skills/mine" && -d "${home}/.cursor/skills/_shared" ]]; then ok "cursor keeps foreign skills and _shared while skills remain"; else ko "cursor keeps foreign skills and _shared while skills remain"; fi
if [[ -z "$(ls -A "${home}/.cursor/agents" 2>/dev/null)" ]]; then ok "cursor install retires projected legacy agents"; else ko "cursor install retires projected legacy agents"; fi
before="$(cursor_snapshot "${home}")"
install_must_succeed "${home}" install --target cursor
if [[ "$(cursor_snapshot "${home}")" == "${before}" ]]; then ok "cursor repeated cleanup is byte-stable"; else ko "cursor repeated cleanup is byte-stable"; fi

# A refusal is reported, removes nothing, and never stops the install or later targets.
for conflict in edited-command edited-script lost-hook-state malformed-hooks; do
    home="$(new_home)"
    cursor_seed_legacy "${home}"
    case "${conflict}" in
        edited-command) printf '\nmy edit\n' >> "${home}/.cursor/commands/clean.md" ;;
        edited-script) printf '\n# my edit\n' >> "${home}/.cursor/hooks/herdr-session-start.sh" ;;
        lost-hook-state) rm "${home}/.config/ycc/managed-config-state.json" ;;
        malformed-hooks) printf '{\n' > "${home}/.cursor/hooks.json" ;;
    esac
    before="$(cursor_snapshot "${home}")"
    install_must_succeed "${home}" install --target cursor
    out="${INSTALL_OUT}"
    assert_contains "${out}" "Cursor legacy cleanup kept every file-copy leftover" "cursor ${conflict} refusal is reported"
    assert_contains "${out}" "./install.sh install --target cursor" "cursor ${conflict} explains how to resolve and retry"
    assert_contains "${out}" "Cursor install complete" "cursor ${conflict} refusal does not stop the install"
    assert_not_contains "${out}" "migrate" "cursor ${conflict} never points at a migrate command"
    if [[ "$(cursor_snapshot "${home}")" == "${before}" ]]; then ok "cursor ${conflict} leaves every carrier and skill intact"; else ko "cursor ${conflict} leaves every carrier and skill intact"; fi
done

# A refused cleanup never skips the targets that run after cursor.
home="$(new_home)"
cursor_seed_legacy "${home}"
printf '{\n' > "${home}/.cursor/hooks.json"
install_must_succeed "${home}" install --target cursor,agents
assert_contains "${INSTALL_OUT}" "Cursor legacy cleanup kept every file-copy leftover" "cursor refusal is reported in a multi-target run"
if [[ -d "${home}/.agents/skills" ]]; then ok "cursor refusal still runs the later agents target"; else ko "cursor refusal still runs the later agents target" "${INSTALL_OUT}"; fi

# A symlinked ~/.cursor/skills parent is never traversed.
home="$(new_home)"
mkdir -p "${home}/foreign-skills/init"
printf 'keep\n' > "${home}/foreign-skills/init/SKILL.md"
ln -s "${home}/foreign-skills" "${home}/.cursor/skills"
before="$(cursor_snapshot "${home}")"
install_must_succeed "${home}" install --target cursor
if [[ "$(cursor_snapshot "${home}")" == "${before}" ]]; then ok "cursor cleanup never traverses symlinked parents"; else ko "cursor cleanup never traverses symlinked parents"; fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
