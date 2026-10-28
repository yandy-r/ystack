#!/usr/bin/env bash
# install.sh tests — opencode: settings merge, remove, base remove, slices.
#
# Runs alone (bash scripts/tests/install/opencode.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== install.sh sync: opencode + cursor =="

home="$(new_home)"
cat > "${home}/.config/opencode/opencode.json" <<'JSON'
{
  "model": "9router/Frontier",
  "provider": { "9router": { "options": { "apiKey": "sk-local-secret" } } },
  "plugins": ["@user/local-plugin"]
}
JSON
install_must_succeed "${home}" sync --target opencode --intent settings,plugins --global
merged="$(cat "${home}/.config/opencode/opencode.json")"
assert_contains "${merged}" "sk-local-secret" "local provider credentials preserved"
assert_contains "${merged}" "@user/local-plugin" "local plugin preserved"
assert_contains "${merged}" "@prevalentware/opencode-goal-plugin" "repo plugin added"
assert_contains "${merged}" "./ycc-sensitive-guard" "sensitive-file guard plugin entry added"
if [[ -f "${home}/.config/opencode/ycc-sensitive-guard/index.js" && -f "${home}/.config/opencode/ycc-sensitive-guard/policy.json" ]]; then
    ok "plugins group installs the guard directory its entry loads"
else
    ko "plugins group installs the guard directory its entry loads"
fi


echo "== install.sh remove: opencode settings and rules =="

home="$(new_home)"
cat > "${home}/.config/opencode/opencode.json" <<'JSON'
{
  "provider": { "9router": { "options": { "apiKey": "sk-local-secret" } } },
  "plugins": ["@user/local-plugin"]
}
JSON
install_must_succeed "${home}" sync --target opencode --intent settings,plugins,rules --global
install_must_succeed "${home}" remove --target opencode --intent settings,plugins,rules --global
merged="$(cat "${home}/.config/opencode/opencode.json")"
assert_contains "${merged}" "sk-local-secret" "opencode remove keeps provider credentials"
assert_contains "${merged}" "@user/local-plugin" "opencode remove keeps user plugin"
assert_not_contains "${merged}" "@prevalentware/opencode-goal-plugin" "opencode remove takes back repo plugin"
assert_not_contains "${merged}" "./ycc-sensitive-guard" "opencode remove takes back the guard plugin entry"
if [[ ! -e "${home}/.config/opencode/ycc-sensitive-guard" ]]; then ok "opencode remove takes back the guard directory"; else ko "opencode remove takes back the guard directory"; fi
if [[ ! -L "${home}/.config/opencode/AGENTS.md" ]]; then ok "opencode remove unlinks AGENTS.md"; else ko "opencode remove unlinks AGENTS.md"; fi

echo "== install.sh settings: opencode project scope (default) =="

# T11: the default scope merges the settings group into <project>/opencode.json
# and never ships the bundle plugins group or the guard directory.
home="$(new_home)"
mkdir -p "${home}/project"
cat > "${home}/project/opencode.json" <<'JSON'
{
  "provider": { "mine": { "options": { "apiKey": "sk-project-secret" } } }
}
JSON
install_must_succeed "${home}" sync --target opencode --intent settings
proj="$(cat "${home}/project/opencode.json")"
assert_contains "${proj}" "sk-project-secret" "project merge preserves a foreign provider credential"
assert_contains "${proj}" '"model"' "project merge applies the managed model"
assert_contains "${proj}" '"agents"' "project merge applies the managed agents"
assert_contains "${proj}" '"subagent_depth"' "project merge applies experimental.subagent_depth"
assert_not_contains "${proj}" '"plugins"' "project merge carries no plugins group"
if [[ ! -e "${home}/.config/opencode/opencode.json" && ! -e "${home}/.config/opencode/ycc-sensitive-guard" ]]; then
    ok "default opencode settings leaves the global config and guard alone"
else
    ko "default opencode settings leaves the global config and guard alone"
fi

# T12: remove at project scope strips managed leaves only.
install_must_succeed "${home}" remove --target opencode --intent settings
proj="$(cat "${home}/project/opencode.json")"
assert_contains "${proj}" "sk-project-secret" "project remove keeps the foreign provider credential"
assert_not_contains "${proj}" '"subagent_depth"' "project remove takes the managed leaves back"

# The legacy hint: a global file with ycc state earns the N4 notice.
home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent settings --global
install_must_succeed "${home}" sync --target opencode --intent settings
assert_contains "${INSTALL_OUT}" "settings now default to project scope" "opencode legacy hint printed when the global file holds ycc state"

# Default bundle plugins at project scope is dropped (global-only).
home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent settings,plugins
assert_contains "${INSTALL_OUT}" "the plugins group is global-only" "opencode default settings,plugins drops the bundle plugins group"
if [[ ! -e "${home}/.config/opencode/ycc-sensitive-guard" ]]; then ok "opencode default settings,plugins ships no guard dir"; else ko "opencode default settings,plugins ships no guard dir"; fi

echo "== install.sh --plugins: opencode =="

home="$(new_home)"
install_must_succeed "${home}" list plugins --target opencode
if [[ "${INSTALL_OUT}" == $'@prevalentware/opencode-goal-plugin\n./ycc-sensitive-guard\noh-my-opencode-slim' ]]; then ok "list plugins --target opencode lists package names, then catalog names";  else ko "list plugins --target opencode lists package names, then catalog names" "${INSTALL_OUT}"; fi

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins @prevalentware/opencode-goal-plugin --global
merged="$(cat "${home}/.config/opencode/opencode.json")"
assert_contains "${merged}" "@prevalentware/opencode-goal-plugin" "opencode --plugins writes the selected item"
assert_not_contains "${merged}" "./ycc-sensitive-guard" "opencode --plugins skips the unselected guard entry"
if [[ ! -e "${home}/.config/opencode/ycc-sensitive-guard" ]]; then ok "opencode --plugins without the guard ships no guard dir"; else ko "opencode --plugins without the guard ships no guard dir"; fi

home="$(new_home)"
cat > "${home}/.config/opencode/opencode.json" <<'JSON'
{"plugins":["@user/local-plugin"]}
JSON
install_must_succeed "${home}" sync --target opencode --intent plugins --global
install_must_succeed "${home}" remove --target opencode --intent plugins --plugins @prevalentware/opencode-goal-plugin --global
merged="$(cat "${home}/.config/opencode/opencode.json")"
assert_not_contains "${merged}" "@prevalentware/opencode-goal-plugin" "opencode remove --plugins takes the selected item"
assert_contains "${merged}" "@user/local-plugin" "opencode remove --plugins keeps a user plugin"
assert_contains "${merged}" "./ycc-sensitive-guard" "opencode remove --plugins keeps the unselected guard entry"
if [[ -d "${home}/.config/opencode/ycc-sensitive-guard" ]]; then ok "opencode remove --plugins keeps the guard dir"; else ko "opencode remove --plugins keeps the guard dir"; fi
install_must_succeed "${home}" remove --target opencode --intent plugins --plugins ./ycc-sensitive-guard --global
assert_not_contains "$(cat "${home}/.config/opencode/opencode.json")" "./ycc-sensitive-guard" "opencode remove --plugins ./ycc-sensitive-guard takes the entry"
if [[ ! -e "${home}/.config/opencode/ycc-sensitive-guard" ]]; then ok "selecting the guard entry removes its dir"; else ko "selecting the guard entry removes its dir"; fi

# A guard entry the user wrote survives remove as a local conflict and still
# loads the directory, so the directory stays with it.
home="$(new_home)"
cat > "${home}/.config/opencode/opencode.json" <<'JSON'
{"plugins":[{"package":"./ycc-sensitive-guard","options":{"mine":true}}]}
JSON
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins ./ycc-sensitive-guard --global
install_must_succeed "${home}" remove --target opencode --intent plugins --plugins ./ycc-sensitive-guard --global
assert_contains "$(cat "${home}/.config/opencode/opencode.json")" '"mine"' "opencode remove keeps a user-written guard entry"
if [[ -f "${home}/.config/opencode/ycc-sensitive-guard/index.js" ]]; then ok "opencode remove keeps the guard dir a kept entry loads"; else ko "opencode remove keeps the guard dir a kept entry loads"; fi

echo

echo "== install.sh remove: opencode base =="

home="$(new_home)"
for unit in skills agents commands shared ycc-sensitive-guard; do
    mkdir -p "${home}/.config/opencode/${unit}"
    cp -R "${REPO_ROOT}/.opencode-plugin/${unit}/." "${home}/.config/opencode/${unit}/"
done
install_must_succeed "${home}" remove --target opencode --intent base
leftover="$(find "${home}/.config/opencode" -mindepth 1 | head -3)"
if [[ -z "${leftover}" ]]; then ok "opencode base remove drops the bundle"; else ko "opencode base remove drops the bundle" "${leftover}"; fi

echo "== install.sh: opencode guard under --skills-home agents =="

home="$(new_home)"
install_must_succeed "${home}" install --target opencode --only base,settings --skills-home agents --global
merged="$(cat "${home}/.config/opencode/opencode.json")"
assert_contains "${merged}" "./ycc-sensitive-guard" "consolidated: opencode.json loads the guard"
if [[ ! -d "${home}/.config/opencode/shared" && -f "${home}/.config/opencode/ycc-sensitive-guard/index.js" ]]; then
    ok "consolidated: guard installed although shared/ is not"
else
    ko "consolidated: guard installed although shared/ is not" "$(ls "${home}/.config/opencode" 2>/dev/null | tr '\n' ' ')"
fi
install_must_succeed "${home}" remove --target opencode --only base --skills-home agents
if [[ -f "${home}/.config/opencode/ycc-sensitive-guard/index.js" ]]; then
    ok "base remove keeps the guard while opencode.json still loads it"
else
    ko "base remove keeps the guard while opencode.json still loads it"
fi
install_must_succeed "${home}" remove --target opencode --only settings --skills-home agents --global
assert_not_contains "$(cat "${home}/.config/opencode/opencode.json" 2>/dev/null || true)" "./ycc-sensitive-guard" "consolidated: settings remove takes back the guard entry"
if [[ ! -e "${home}/.config/opencode/ycc-sensitive-guard" ]]; then ok "consolidated: settings remove takes back the guard"; else ko "consolidated: settings remove takes back the guard"; fi


echo "== install.sh: opencode slices =="

home="$(new_home)"
HOME="${home}" YCC_MANAGED_CONFIG_STATE="${home}/.config/ycc/managed-config-state.json" \
    python3 "${REPO_ROOT}/scripts/install_slices.py" install --target opencode --slice skills >/dev/null
assert_contains "$(cat "${home}/.config/opencode/skills/releaser/SKILL.md")" "opencode/autoinvoke: 'false'" "opencode slice retains releaser manual invocation policy"
assert_not_contains "$(cat "${home}/.config/opencode/skills/init/SKILL.md")" 'opencode/autoinvoke' "opencode slice keeps init model-invocable"

home="$(new_home)"
for unit in skills agents commands shared; do
    mkdir -p "${home}/.config/opencode/${unit}"
    cp -R "${REPO_ROOT}/.opencode-plugin/${unit}/." "${home}/.config/opencode/${unit}/"
done
install_must_succeed "${home}" remove --target opencode --intent agents,commands
leftover="$(find "${home}/.config/opencode" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' ')"
if [[ "${leftover}" == "shared skills " ]]; then ok "opencode agents,commands remove keeps skills + shared"; else ko "opencode agents,commands remove keeps skills + shared" "${leftover}"; fi
install_must_succeed "${home}" remove --target opencode --intent skills
leftover="$(find "${home}/.config/opencode" -mindepth 1 | head -3)"
if [[ -z "${leftover}" ]]; then ok "opencode skills remove takes shared/ too"; else ko "opencode skills remove takes shared/ too" "${leftover}"; fi

# The slice helper directly (no generators): Codex skills land in
# ~/.codex/skills with plugin paths re-pointed there.

# A committed project opencode.json whose values equal the repo's must lose
# nothing ycc never recorded writing.
home="$(new_home)"
cat > "${home}/project/opencode.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "experimental": { "subagent_depth": 2 }
}
JSON
before="$(cat "${home}/project/opencode.json")"
install_must_succeed "${home}" remove --target opencode --intent settings
assert_contains "$(cat "${home}/project/opencode.json")" "${before}" "opencode project remove keeps repo-equal keys ycc never wrote"

# A catalog-only global install also earns the legacy hint.
home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent plugins --plugins oh-my-opencode-slim --global
install_must_succeed "${home}" sync --target opencode --intent settings
assert_contains "${INSTALL_OUT}" "settings now default to project scope" "opencode legacy hint also fires for catalog-only global state"

# When the project root's opencode.json IS the global file, the project run
# targets the global paths, not a nested .opencode/ companion directory.
home="$(new_home)"
git -C "${home}/.config/opencode" init -q
install_must_succeed_in "${home}" "${home}/.config/opencode" sync --target opencode --intent plugins --plugins oh-my-opencode-slim
if [[ ! -e "${home}/.config/opencode/.opencode" ]]; then ok "opencode project root equal to the global dir writes no nested .opencode/"; else ko "opencode project root equal to the global dir writes no nested .opencode/"; fi
assert_contains "$(cat "${home}/.config/opencode/opencode.json")" "oh-my-opencode-slim" "opencode project/global fallback writes the global settings file"
assert_not_contains "${INSTALL_OUT}" "settings now default to project scope" "opencode project/global fallback prints no false legacy hint"

# The same fallback must hold when HOME is a symlink into the physical home.
home="$(new_home)"
git -C "${home}/.config/opencode" init -q
ln -s "${home}" "${SANDBOX_ROOT}/linked-home"
install_must_succeed_in "${SANDBOX_ROOT}/linked-home" "${home}/.config/opencode" sync --target opencode --intent plugins --plugins oh-my-opencode-slim
assert_contains "$(cat "${home}/.config/opencode/opencode.json")" "oh-my-opencode-slim" "opencode project/global fallback resolves physical HOME paths"
assert_not_contains "${INSTALL_OUT}" "settings now default to project scope" "opencode physical-path fallback prints no false legacy hint"
if [[ ! -e "${home}/.config/opencode/.opencode" ]]; then ok "opencode physical-path fallback writes no nested .opencode/"; else ko "opencode physical-path fallback writes no nested .opencode/"; fi

# A missing global config directory cannot alias the project destination;
# its physical-path probe must not abort a normal or dry-run project sync.
home="$(new_home)"
rmdir "${home}/.config/opencode"
install_must_succeed "${home}" sync --target opencode --intent settings
assert_contains "$(cat "${home}/project/opencode.json")" '"model"' "opencode project sync succeeds without a global config directory"
if [[ ! -e "${home}/.config/opencode" ]]; then ok "opencode project sync creates no global config directory"; else ko "opencode project sync creates no global config directory"; fi

home="$(new_home)"
rmdir "${home}/.config/opencode"
install_must_succeed "${home}" sync --target opencode --intent settings --dry-run
assert_contains "${INSTALL_OUT}" "would set /model" "opencode project dry-run succeeds without a global config directory"
if [[ ! -e "${home}/project/opencode.json" && ! -e "${home}/.config/opencode" ]]; then ok "opencode project dry-run without a global config directory writes nothing"; else ko "opencode project dry-run without a global config directory writes nothing"; fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
