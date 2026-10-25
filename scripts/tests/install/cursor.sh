#!/usr/bin/env bash
# install.sh tests — cursor: settings, remove, base remove, slices.
#
# Runs alone (bash scripts/tests/install/cursor.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== install.sh sync: cursor =="

home="$(new_home)"
install_must_succeed "${home}" sync --target cursor --intent settings
assert_contains "$(cat "${home}/.cursor/cli-config.json")" '"claude-fable-5-1"' "cursor CLI model applied"

echo

echo "== install.sh remove: cursor settings and rules =="

home="$(new_home)"
cat > "${home}/.cursor/cli-config.json" <<'JSON'
{ "privacyMode": 1, "permissions": { "allow": ["Shell(ls)"], "deny": [] } }
JSON
install_must_succeed "${home}" sync --target cursor --intent settings,rules
install_must_succeed "${home}" remove --target cursor --intent settings,rules
merged="$(cat "${home}/.cursor/cli-config.json")"
assert_contains "${merged}" '"privacyMode": 1' "cursor remove keeps unmanaged keys"
assert_contains "${merged}" '"Shell(ls)"' "cursor remove keeps user permission entries"
assert_contains "${merged}" '"deny": []' "cursor remove keeps required permission keys"
assert_not_contains "${merged}" '"modelId"' "cursor remove drops managed model"
if [[ ! -L "${home}/.cursor/CLAUDE.md" ]]; then ok "cursor remove unlinks rules"; else ko "cursor remove unlinks rules"; fi


echo "== install.sh remove: cursor base =="

home="$(new_home)"
for unit in skills agents rules; do
    src="${REPO_ROOT}/packages/cursor/ycc/${unit}"
    [[ "${unit}" == "rules" ]] && src="${REPO_ROOT}/packages/cursor/ycc-rules/rules"
    mkdir -p "${home}/.cursor/${unit}"
    cp -R "${src}/." "${home}/.cursor/${unit}/"
done
mkdir -p "${home}/.cursor/skills/my-own-skill"
install_must_succeed "${home}" remove --target cursor --intent base
if [[ -d "${home}/.cursor/skills/my-own-skill" ]]; then ok "cursor base remove keeps user skills"; else ko "cursor base remove keeps user skills"; fi
leftover="$(find "${home}/.cursor/skills" -mindepth 1 -maxdepth 1 -printf '%f\n')"
if [[ "${leftover}" == "my-own-skill" ]]; then ok "cursor base remove drops bundle skills"; else ko "cursor base remove drops bundle skills" "${leftover}"; fi
if [[ ! -e "${home}/.cursor/agents" ]]; then ok "cursor base remove drops emptied agents dir"; else ko "cursor base remove drops emptied agents dir"; fi


echo "== install.sh: cursor slices =="

home="$(new_home)"
HOME="${home}" YCC_MANAGED_CONFIG_STATE="${home}/.config/ycc/managed-config-state.json" \
    python3 "${REPO_ROOT}/scripts/install_slices.py" install --target cursor --slice skills >/dev/null
assert_contains "$(cat "${home}/.cursor/skills/releaser/SKILL.md")" 'disable-model-invocation: true' "cursor slice retains releaser manual invocation policy"
assert_not_contains "$(cat "${home}/.cursor/skills/init/SKILL.md")" 'disable-model-invocation' "cursor slice keeps init model-invocable"

# Shared-reference paths resolve in an isolated HOME containing spaces, from a foreign cwd.
home="${SANDBOX_ROOT}/cursor home with spaces"
foreign="${SANDBOX_ROOT}/foreign cwd"
mkdir -p "${home}" "${foreign}"
if (cd "${foreign}" && HOME="${home}" YCC_MANAGED_CONFIG_STATE="${home}/.config/ycc/managed-config-state.json" \
    python3 "${REPO_ROOT}/scripts/install_slices.py" install --target cursor --slice skills >/dev/null); then
    ok "cursor slice installs from foreign cwd with spaced HOME"
else
    ko "cursor slice installs from foreign cwd with spaced HOME"
fi
if python3 - "${home}" "${REPO_ROOT}" <<'PY'
from pathlib import Path
import re
import subprocess
import sys

home, repo = map(Path, sys.argv[1:])
skills = home / ".cursor/skills"
consumers = (
    "orchestrate/references/dispatch-playbook.md",
    "prp-plan/SKILL.md",
    "prp-pr/SKILL.md",
    "research-to-issues/SKILL.md",
)
count = 0
for relative in consumers:
    source = (repo / "packages/cursor/ycc/skills" / relative).read_text()
    installed = (skills / relative).read_text()
    assert "${CURSOR_PLUGIN_ROOT}/skills/_shared/references/" not in installed, relative
    for suffix in re.findall(r"\$\{CURSOR_PLUGIN_ROOT\}/skills/(_shared/references/[\w.-]+\.md)", source):
        resolved = skills / suffix
        assert str(resolved) in installed, (relative, resolved)
        assert resolved.is_file(), resolved
        count += 1
assert count >= 9, count
PY
then ok "cursor installed shared refs resolve"; else ko "cursor installed shared refs resolve"; fi

# A base-installed raw copy remains ycc-owned when the slice rebases references.
home="$(new_home)"
mkdir -p "${home}/.cursor/skills"
cp -R "${REPO_ROOT}/packages/cursor/ycc/skills/prp-pr" "${home}/.cursor/skills/"
if HOME="${home}" YCC_MANAGED_CONFIG_STATE="${home}/.config/ycc/managed-config-state.json" \
    python3 "${REPO_ROOT}/scripts/install_slices.py" install --target cursor --slice skills >/dev/null; then
    ok "cursor slice replaces base copy with rebased references"
else
    ko "cursor slice replaces base copy with rebased references"
fi
assert_contains "$(cat "${home}/.cursor/skills/prp-pr/SKILL.md")" "${home}/.cursor/skills/_shared/references/" "cursor base takeover rebases references"

home="$(new_home)"
for unit in skills agents rules; do
    src="${REPO_ROOT}/packages/cursor/ycc/${unit}"
    [[ "${unit}" == "rules" ]] && src="${REPO_ROOT}/packages/cursor/ycc-rules/rules"
    mkdir -p "${home}/.cursor/${unit}"
    cp -R "${src}/." "${home}/.cursor/${unit}/"
done
mkdir -p "${home}/.cursor/skills/my-own-skill"
install_must_succeed "${home}" remove --target cursor --intent skills
leftover="$(find "${home}/.cursor/skills" -mindepth 1 -maxdepth 1 -printf '%f\n')"
if [[ "${leftover}" == "my-own-skill" ]]; then ok "cursor skills remove drops only bundle skills"; else ko "cursor skills remove drops only bundle skills" "${leftover}"; fi
if [[ -n "$(ls -A "${home}/.cursor/agents")" && -n "$(ls -A "${home}/.cursor/rules")" ]]; then ok "cursor skills remove keeps agents + rules"; else ko "cursor skills remove keeps agents + rules"; fi

echo
echo "== install.sh rules: cursor provisions no global rules files =="

home="$(new_home)"
install_must_succeed "${home}" install --target cursor --only rules
out="${INSTALL_OUT}"
assert_contains "${out}" "Cursor Settings → Rules" "cursor rules prints manual User Rules guidance"
for f in CLAUDE.md AGENTS.md; do
    if [[ ! -e "${home}/.cursor/${f}" && ! -L "${home}/.cursor/${f}" ]]; then ok "cursor rules creates no ~/.cursor/${f}"; else ko "cursor rules creates no ~/.cursor/${f}"; fi
done

home="$(new_home)"
ln -s "${REPO_ROOT}/ycc/settings/rules/CLAUDE.md" "${home}/.cursor/CLAUDE.md"
ln -s "${REPO_ROOT}/ycc/settings/rules/AGENTS.md" "${home}/.cursor/AGENTS.md"
install_must_succeed "${home}" install --target cursor --only rules
if [[ -L "${home}/.cursor/CLAUDE.md" && -L "${home}/.cursor/AGENTS.md" ]]; then ok "cursor install leaves legacy links alone"; else ko "cursor install leaves legacy links alone"; fi
install_must_succeed "${home}" remove --target cursor --intent rules
for f in CLAUDE.md AGENTS.md; do
    if [[ ! -e "${home}/.cursor/${f}" && ! -L "${home}/.cursor/${f}" ]]; then ok "cursor remove unlinks legacy ~/.cursor/${f}"; else ko "cursor remove unlinks legacy ~/.cursor/${f}"; fi
done

echo "== Cursor carrier ownership boundaries =="

# Commands cannot be installed as dangling references; preflight touches nothing.
home="$(new_home)"
out="$(run_install "${home}" sync --target cursor --intent commands 2>&1)" && rc=0 || rc=$?
if [[ ${rc} -ne 0 ]]; then ok "cursor commands reject missing installed skills"; else ko "cursor commands reject missing installed skills" "${out}"; fi
assert_contains "${out}" '--only skills,commands' "cursor missing skills names the recovery command"
if [[ ! -e "${home}/.cursor/commands" && ! -e "${home}/.config/ycc/installed-units.json" ]]; then ok "missing skills preflight writes no carriers or state"; else ko "missing skills preflight writes no carriers or state"; fi

# A commands-only refresh must use the explicitly selected consolidated home.
home="$(new_home)"
install_must_succeed "${home}" install --target cursor --package ycc --skills-home agents
install_must_succeed "${home}" sync --target cursor --intent commands --skills-home agents
assert_contains "$(cat "${home}/.cursor/commands/init.md")" "${home}/.agents/skills/init/SKILL.md" "commands-only refresh honors agents skills home"
if [[ ! -e "${home}/.cursor/skills" ]]; then ok "commands-only agents refresh creates no native skills"; else ko "commands-only agents refresh creates no native skills"; fi

# One collision must abort the whole slice before other wrappers are installed.
home="$(new_home)"
install_must_succeed "${home}" install --target cursor --only skills --skills-home native
mkdir -p "${home}/.cursor/commands"
echo mine > "${home}/.cursor/commands/init.md"
out="$(run_install "${home}" sync --target cursor --intent commands 2>&1)" && rc=0 || rc=$?
if [[ ${rc} -ne 0 && ! -e "${home}/.cursor/commands/clean.md" ]]; then ok "foreign command collision aborts the whole carrier"; else ko "foreign command collision aborts the whole carrier" "${out}"; fi
assert_contains "$(cat "${home}/.cursor/commands/init.md")" mine "foreign colliding command survives"
install_must_succeed "${home}" sync --target cursor --intent commands --force
echo edited >> "${home}/.cursor/commands/init.md"
out="$(run_install "${home}" sync --target cursor --intent commands 2>&1)" && rc=0 || rc=$?
if [[ ${rc} -ne 0 ]]; then ok "locally edited owned command fails closed"; else ko "locally edited owned command fails closed"; fi
assert_contains "$(cat "${home}/.cursor/commands/init.md")" edited "local command edit survives"
out="$(run_install "${home}" remove --target cursor --intent commands 2>&1)" && rc=0 || rc=$?
if [[ ${rc} -ne 0 && -e "${home}/.cursor/commands/clean.md" ]]; then ok "edited command aborts removal before partial deletion"; else ko "edited command aborts removal before partial deletion" "${out}"; fi
install_must_succeed "${home}" remove --target cursor --intent commands --force
if [[ ! -e "${home}/.cursor/commands" ]]; then ok "forced command removal cleans owned entries"; else ko "forced command removal cleans owned entries"; fi

# Hook shape and script collisions are checked before settings, script or state.
for fixture in malformed version collision symlink; do
    home="$(new_home)"
    case "${fixture}" in
        malformed) echo '{' > "${home}/.cursor/hooks.json" ;;
        version) echo '{"version":2,"hooks":{}}' > "${home}/.cursor/hooks.json" ;;
        collision)
            mkdir -p "${home}/.cursor/hooks"
            echo mine > "${home}/.cursor/hooks/herdr-session-start.sh"
            ;;
        symlink)
            mkdir -p "${home}/foreign-hooks"
            echo mine > "${home}/foreign-hooks/keep"
            ln -s "${home}/foreign-hooks" "${home}/.cursor/hooks"
            ;;
    esac
    before="$(find "${home}" -type f -exec sha256sum {} + | sort)"
    out="$(run_install "${home}" install --target cursor --package ycc-hooks 2>&1)" && rc=0 || rc=$?
    after="$(find "${home}" -type f -exec sha256sum {} + | sort)"
    if [[ ${rc} -ne 0 && "${before}" == "${after}" && ! -e "${home}/.cursor/cli-config.json" && ! -e "${home}/.config/ycc/managed-config-state.json" ]]; then ok "cursor hooks ${fixture} preflight fails before writes"; else ko "cursor hooks ${fixture} preflight fails before writes" "${out}"; fi
done

# Installed script edits do not authorize overwrite or removal.
home="$(new_home)"
install_must_succeed "${home}" install --target cursor --only hooks
echo '# edited' >> "${home}/.cursor/hooks/herdr-session-start.sh"
out="$(run_install "${home}" install --target cursor --only hooks 2>&1)" && rc=0 || rc=$?
if [[ ${rc} -ne 0 ]]; then ok "edited owned hook script fails closed"; else ko "edited owned hook script fails closed"; fi
assert_contains "$(cat "${home}/.cursor/hooks/herdr-session-start.sh")" '# edited' "hook script edit survives"

# Never delete a script when its registration was pre-existing or lost ownership.
for fixture in preexisting lost-state; do
    home="$(new_home)"
    if [[ "${fixture}" == "preexisting" ]]; then
        python3 - "${home}" <<'PY'
import json
import pathlib
import shlex
import sys

home = pathlib.Path(sys.argv[1])
script = home / ".cursor/hooks/herdr-session-start.sh"
command = f"bash {shlex.quote(str(script))} session"
(home / ".cursor/hooks.json").write_text(json.dumps({"version": 1, "hooks": {"sessionStart": [{"command": command}]}}))
PY
    fi
    install_must_succeed "${home}" install --target cursor --only hooks
    if [[ "${fixture}" == "lost-state" ]]; then
        rm "${home}/.config/ycc/managed-config-state.json"
    fi
    before="$(cat "${home}/.cursor/hooks.json")"
    out="$(run_install "${home}" remove --target cursor --intent hooks 2>&1)" && rc=0 || rc=$?
    if [[ ${rc} -ne 0 && -x "${home}/.cursor/hooks/herdr-session-start.sh" && "${before}" == "$(cat "${home}/.cursor/hooks.json")" ]]; then ok "${fixture} registration prevents hook script removal"; else ko "${fixture} registration prevents hook script removal" "${out}"; fi
    assert_contains "${out}" 'registration still references the hook script' "${fixture} removal explains registration ownership"
    install_must_succeed "${home}" remove --target cursor --intent hooks --force
    if [[ ! -e "${home}/.cursor/hooks/herdr-session-start.sh" ]]; then ok "${fixture} forced removal retracts script safely"; else ko "${fixture} forced removal retracts script safely"; fi
done

home="$(new_home)"
install_must_succeed "${home}" sync --target cursor --intent base
if [[ ! -e "${home}/.cursor/commands" && ! -e "${home}/.cursor/hooks.json" ]]; then ok "default base installs no optional carriers"; else ko "default base installs no optional carriers"; fi

# --hooks <events> narrows claude's hooks config group; cursor's hooks step
# has no hook-event selection, so it is skipped (warned), never run whole.
home="$(new_home)"
install_must_succeed "${home}" install --target cursor --only hooks
cursor_hooks_before="$(cat "${home}/.cursor/hooks.json"; cat "${home}/.cursor/hooks/herdr-session-start.sh")"
install_must_succeed "${home}" sync --target claude,cursor --intent hooks --hooks WorktreeCreate --global
assert_contains "${INSTALL_OUT}" "cursor has no hook-event selection — skipping its hooks step" "sync --hooks warns that cursor's hooks step is skipped"
assert_contains "$(cat "${home}/.claude/settings.json")" '"WorktreeCreate"' "sync --hooks still merges claude's selected event"
install_must_succeed "${home}" remove --target claude,cursor --intent hooks --hooks WorktreeCreate --global
assert_contains "${INSTALL_OUT}" "cursor has no hook-event selection — skipping its hooks step" "remove --hooks warns that cursor's hooks step is skipped"
if [[ -e "${home}/.cursor/hooks/herdr-session-start.sh" && "${cursor_hooks_before}" == "$(cat "${home}/.cursor/hooks.json"; cat "${home}/.cursor/hooks/herdr-session-start.sh")" ]]; then
    ok "--hooks leaves cursor's hook script and hooks.json entries untouched"
else
    ko "--hooks leaves cursor's hook script and hooks.json entries untouched"
fi
assert_not_contains "$(cat "${home}/.claude/settings.json" 2>/dev/null)" '"WorktreeCreate"' "remove --hooks still takes claude's selected event"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
