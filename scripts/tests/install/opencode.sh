#!/usr/bin/env bash
# install.sh tests — opencode: the base step writes the one @yandy-r/ycc-opencode
# plugins entry (local file:// / repo @<version>), replaces stale ycc entries in
# place, retires the legacy file copy, and remove takes back only its entry;
# settings and rules stay on the installer.
#
# Runs alone (bash scripts/tests/install/opencode.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OC_PKG="@yandy-r/ycc-opencode"
OC_LOCAL="file://${REPO_ROOT}/packages/opencode/ycc-opencode"
OC_VERSION="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "${REPO_ROOT}/ycc/.claude-plugin/plugin.json")"
OC_REPO="${OC_PKG}@${OC_VERSION}"

# Stub npm/opencode so the cleanup gate (opencode_package.py check) is
# deterministic: OC_NPM_VIEW is what 'npm view' prints (empty: lookup fails),
# OC_OPENCODE_VERSION what 'opencode --version' prints.
cat > "${STUB_BIN}/npm" <<'SH'
#!/usr/bin/env bash
[[ "$1" == view && -n "${OC_NPM_VIEW:-}" ]] || exit 1
printf '%s\n' "${OC_NPM_VIEW}"
SH
cat > "${STUB_BIN}/opencode" <<'SH'
#!/usr/bin/env bash
printf 'opencode v%s\n' "${OC_OPENCODE_VERSION:-2.2.5}"
SH
chmod +x "${STUB_BIN}/npm" "${STUB_BIN}/opencode"

# oc_seed_legacy <home> — one byte-identical legacy skill copy under ~/.config/opencode.
oc_seed_legacy() {
    mkdir -p "$1/.config/opencode/skills"
    cp -R "${REPO_ROOT}/.opencode-plugin/skills/backport" "$1/.config/opencode/skills/backport"
}

# oc_plugins <opencode.json> — the plugins list, one JSON item per line.
oc_plugins() {
    python3 - "$1" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1], encoding="utf-8")).get("plugins", []):
    print(json.dumps(item, sort_keys=True))
PY
}

# oc_assert_no_copies <home> <label> — no file-copy unit dir under ~/.config/opencode.
oc_assert_no_copies() {
    local unit found=""
    for unit in skills agents commands shared ycc-sensitive-guard; do
        [[ -e "$1/.config/opencode/${unit}" ]] && found+="${unit} "
    done
    if [[ -z "${found}" ]]; then ok "$2"; else ko "$2" "${found}"; fi
}

echo "== install.sh opencode base: local entry =="

home="$(new_home)"
install_must_succeed "${home}" install --target opencode
cfg="${home}/.config/opencode/opencode.json"
if [[ "$(oc_plugins "${cfg}")" == "\"${OC_LOCAL}\"" ]]; then ok "local mode writes the one file:// entry"; else ko "local mode writes the one file:// entry" "$(cat "${cfg}")"; fi
oc_assert_no_copies "${home}" "local install copies nothing under ~/.config/opencode"
assert_not_contains "$(cat "${cfg}")" '"mcp"' "local install merges no MCP servers"
if [[ ! -e "${home}/project/opencode.json" ]]; then ok "base writes no project opencode.json"; else ko "base writes no project opencode.json"; fi
cp "${cfg}" "${home}/first.json"
install_must_succeed "${home}" install --target opencode
if cmp -s "${home}/first.json" "${cfg}"; then ok "a rerun is byte-identical"; else ko "a rerun is byte-identical" "$(diff "${home}/first.json" "${cfg}")"; fi

for intent in skills agents commands mcp; do
    home="$(new_home)"
    install_must_succeed "${home}" sync --target opencode --intent "${intent}"
    assert_contains "$(cat "${home}/.config/opencode/opencode.json" 2>/dev/null)" "${OC_LOCAL}" "sync --intent ${intent} runs the base step"
    oc_assert_no_copies "${home}" "sync --intent ${intent} copies nothing"
done

for flag in --mcps --agents --commands --skills-home; do
    home="$(new_home)"
    out="$(run_install "${home}" install --target opencode "${flag}" x)"
    assert_contains "${out}" "Unknown option: ${flag}" "opencode: ${flag} is gone"
done
home="$(new_home)"
out="$(run_install "${home}" install --target opencode --only mcp)"
assert_contains "${out}" "--only step 'mcp' is not valid for target 'opencode'" "opencode has no mcp step"

echo "== install.sh opencode base: repo entry and stale entries =="

home="$(new_home)"
OC_NPM_VIEW="${OC_VERSION}" install_must_succeed "${home}" install --target opencode --mode repo
cfg="${home}/.config/opencode/opencode.json"
if [[ "$(oc_plugins "${cfg}")" == "\"${OC_REPO}\"" ]]; then ok "repo mode writes ${OC_REPO}"; else ko "repo mode writes ${OC_REPO}" "$(cat "${cfg}")"; fi
assert_not_contains "${INSTALL_OUT}" "generate-opencode-package" "repo mode builds nothing"

home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
printf '{"plugins": ["@user/first", "%s@latest", "@user/last"]}\n' "${OC_PKG}" > "${cfg}"
install_must_succeed "${home}" install --target opencode --mode repo
expected="$(printf '"@user/first"\n"%s"\n"@user/last"' "${OC_REPO}")"
if [[ "$(oc_plugins "${cfg}")" == "${expected}" ]]; then ok "a stale @latest entry is replaced in place"; else ko "a stale @latest entry is replaced in place" "$(cat "${cfg}")"; fi

home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
printf '{"plugins": ["@user/first", {"package": "%s", "options": {"mine": true}}, "@user/last"]}\n' "${OC_PKG}" > "${cfg}"
install_must_succeed "${home}" install --target opencode
expected="$(printf '"@user/first"\n{"options": {"mine": true}, "package": "%s"}\n"@user/last"' "${OC_LOCAL}")"
if [[ "$(oc_plugins "${cfg}")" == "${expected}" ]]; then ok "an object-form entry is replaced in place, keeping its options"; else ko "an object-form entry is replaced in place, keeping its options" "$(cat "${cfg}")"; fi

echo "== install.sh opencode base: entries ycc never wrote =="

for spec in "${OC_PKG}@1.0.0" "file:///elsewhere/packages/opencode/ycc-opencode"; do
    home="$(new_home)"
    cfg="${home}/.config/opencode/opencode.json"
    oc_seed_legacy "${home}"
    printf '{"plugins": ["%s"]}\n' "${spec}" > "${cfg}"
    cp "${cfg}" "${home}/before.json"
    install_must_succeed "${home}" install --target opencode
    if cmp -s "${home}/before.json" "${cfg}"; then ok "a user entry ${spec} is kept byte-identical"; else ko "a user entry ${spec} is kept byte-identical" "$(cat "${cfg}")"; fi
    assert_contains "${INSTALL_OUT}" "kept ${spec}" "the kept ${spec} entry is reported"
    if [[ -d "${home}/.config/opencode/skills/backport" ]]; then ok "a kept user entry keeps the legacy copy"; else ko "a kept user entry keeps the legacy copy"; fi
    install_must_succeed "${home}" install --target opencode --force
    if [[ "$(oc_plugins "${cfg}")" == "\"${OC_LOCAL}\"" ]]; then ok "--force replaces ${spec}"; else ko "--force replaces ${spec}" "$(cat "${cfg}")"; fi
done

home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
printf '{\n  // mine\n  "plugins": ["%s@latest"],\n}\n' "${OC_PKG}" > "${cfg}"
cp "${cfg}" "${home}/before.json"
install_must_succeed "${home}" install --target opencode
if cmp -s "${home}/before.json" "${cfg}.ycc-backup"; then ok "a JSONC config is backed up before the rewrite"; else ko "a JSONC config is backed up before the rewrite"; fi

home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
printf '{ "plugins": [ "%s" ], }\n' "${OC_LOCAL}" > "${cfg}"
cp "${cfg}" "${home}/before.json"
install_must_succeed "${home}" install --target opencode
if cmp -s "${home}/before.json" "${cfg}"; then ok "an already-present entry is never rewritten"; else ko "an already-present entry is never rewritten" "$(cat "${cfg}")"; fi

echo "== install.sh opencode base: symlinked config =="

home="$(new_home)"
oc_seed_legacy "${home}"
printf '{}\n' > "${home}/dotfiles.json"
ln -s "${home}/dotfiles.json" "${home}/.config/opencode/opencode.json"
install_must_succeed "${home}" install --target opencode,agents
assert_contains "${INSTALL_OUT}" "\"${OC_LOCAL}\"" "a symlinked config prints the entry to add by hand"
assert_contains "$(cat "${home}/dotfiles.json")" "{}" "a symlinked config is never written through"
if [[ -L "${home}/.config/opencode/opencode.json" && -d "${home}/.config/opencode/skills/backport" ]]; then ok "a symlinked config skips cleanup and keeps the link"; else ko "a symlinked config skips cleanup and keeps the link"; fi
assert_contains "${INSTALL_OUT}" "agents install complete" "a refused opencode config does not abort later targets"

echo "== install.sh opencode base: cleanup gate =="

home="$(new_home)"
oc_seed_legacy "${home}"
OC_NPM_VIEW="" install_must_succeed "${home}" install --target opencode --mode repo
assert_contains "${INSTALL_OUT}" "could not confirm ${OC_REPO} is published" "repo mode keeps the legacy copy when the release is unconfirmed"
if [[ -d "${home}/.config/opencode/skills/backport" ]]; then ok "unconfirmed release keeps the legacy copy"; else ko "unconfirmed release keeps the legacy copy"; fi
OC_NPM_VIEW="${OC_VERSION}" install_must_succeed "${home}" install --target opencode --mode repo
if [[ ! -e "${home}/.config/opencode/skills/backport" ]]; then ok "a confirmed release retires the legacy copy"; else ko "a confirmed release retires the legacy copy"; fi

home="$(new_home)"
oc_seed_legacy "${home}"
OC_OPENCODE_VERSION="2.0.12" install_must_succeed "${home}" install --target opencode
assert_contains "${INSTALL_OUT}" "opencode 2.0.12 cannot load" "an old opencode keeps the legacy copy"
if [[ -d "${home}/.config/opencode/skills/backport" ]]; then ok "an old opencode skips cleanup"; else ko "an old opencode skips cleanup"; fi

echo "== install.sh opencode: legacy cleanup =="

home="$(new_home)"
oc="${home}/.config/opencode"
mkdir -p "${oc}/skills" "${oc}/agents"
cp -R "${REPO_ROOT}/.opencode-plugin/skills/backport" "${oc}/skills/backport"
cp -R "${REPO_ROOT}/.opencode-plugin/skills/plan" "${oc}/skills/plan"
printf '\nmy edit\n' >> "${oc}/skills/plan/SKILL.md"
cp "${REPO_ROOT}/.opencode-plugin/agents/implementor.md" "${oc}/agents/implementor.md"
# Owned MCP servers: merged by the old installer (recorded state); one foreign server.
# The fixture is the newest committed bundle config that still shipped an mcp block.
old_rev=""
for rev in $(git -C "${REPO_ROOT}" log --format=%H -- .opencode-plugin/opencode.json); do
    if git -C "${REPO_ROOT}" show "${rev}:.opencode-plugin/opencode.json" | grep -q '"mcp"'; then
        old_rev="${rev}"
        break
    fi
done
git -C "${REPO_ROOT}" show "${old_rev}:.opencode-plugin/opencode.json" > "${home}/old-opencode.json"
HOME="${home}" YCC_MANAGED_CONFIG_STATE="${home}/.config/ycc/managed-config-state.json" \
    python3 "${REPO_ROOT}/scripts/merge_managed_config.py" --profile opencode-config \
    --source "${home}/old-opencode.json" --destination "${oc}/opencode.json" --groups mcp >/dev/null
python3 - "${oc}/opencode.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["mcp"]["servers"]["my-server"] = {"type": "local", "command": ["mine"]}
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
install_must_succeed "${home}" install --target opencode
if [[ ! -e "${oc}/skills/backport" ]]; then ok "cleanup removes a byte-identical legacy skill copy"; else ko "cleanup removes a byte-identical legacy skill copy"; fi
if [[ ! -e "${oc}/agents" ]]; then ok "cleanup removes a byte-identical legacy agent and its empty dir"; else ko "cleanup removes a byte-identical legacy agent and its empty dir"; fi
assert_contains "$(cat "${oc}/skills/plan/SKILL.md" 2>/dev/null)" "my edit" "cleanup keeps an edited legacy copy"
assert_contains "${INSTALL_OUT}" "kept ${oc}/skills/plan" "cleanup reports the kept copy"
servers="$(python3 -c 'import json, sys; print(sorted(json.load(open(sys.argv[1])).get("mcp", {}).get("servers", {})))' "${oc}/opencode.json")"
if [[ "${servers}" == "['my-server']" ]]; then ok "cleanup removes owned mcp.servers and keeps a foreign one"; else ko "cleanup removes owned mcp.servers and keeps a foreign one" "${servers}"; fi
assert_contains "$(cat "${oc}/opencode.json")" "${OC_LOCAL}" "cleanup runs after the entry is written"

echo "== install.sh opencode remove =="

home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
printf '{"plugins": ["@user/local-plugin"]}\n' > "${cfg}"
install_must_succeed "${home}" install --target opencode
install_must_succeed "${home}" remove --target opencode --intent skills
assert_contains "${INSTALL_OUT}" "ship inside ${OC_PKG}; removes nothing" "remove --intent skills prints the package notice"
assert_contains "$(cat "${cfg}")" "${OC_LOCAL}" "remove --intent skills removes nothing"
install_must_succeed "${home}" remove --target opencode --intent base
if [[ "$(oc_plugins "${cfg}")" == '"@user/local-plugin"' ]]; then ok "remove --intent base takes the entry back, keeps other plugins"; else ko "remove --intent base takes the entry back, keeps other plugins" "$(cat "${cfg}")"; fi

home="$(new_home)"
cfg="${home}/.config/opencode/opencode.json"
printf '{"plugins": ["%s@0.0.1"]}\n' "${OC_PKG}" > "${cfg}"
install_must_succeed "${home}" remove --target opencode --intent base
assert_contains "$(cat "${cfg}")" "${OC_PKG}@0.0.1" "remove keeps an entry ycc did not write"

echo "== install.sh opencode --dry-run =="

home="$(new_home)"
before="$(cd "${home}" && find . -printf '%p %y\n' | sort)"
install_must_succeed "${home}" install --target opencode --settings --rules --global --dry-run
assert_contains "${INSTALL_OUT}" "would add the ${OC_PKG} plugins entry" "dry-run previews the entry"
if [[ "$(cd "${home}" && find . -printf '%p %y\n' | sort)" == "${before}" ]]; then ok "dry-run writes nothing"; else ko "dry-run writes nothing"; fi

echo "== install.sh opencode settings and rules =="

home="$(new_home)"
cat > "${home}/.config/opencode/opencode.json" <<'JSON'
{
  "provider": { "9router": { "options": { "apiKey": "sk-local-secret" } } },
  "plugins": ["@user/local-plugin"]
}
JSON
install_must_succeed "${home}" sync --target opencode --intent settings,plugins,rules --global
merged="$(cat "${home}/.config/opencode/opencode.json")"
assert_contains "${merged}" "sk-local-secret" "local provider credentials preserved"
assert_contains "${merged}" "@user/local-plugin" "local plugin preserved"
assert_contains "${merged}" '"model"' "settings merges the model"
assert_contains "${merged}" '"agents"' "settings merges the agent pins"
assert_contains "${merged}" '"subagent_depth"' "settings merges experimental.subagent_depth"
assert_contains "${merged}" "@prevalentware/opencode-goal-plugin" "settings merges the goal plugin"
assert_not_contains "${merged}" "ycc-sensitive-guard" "settings merges no guard entry"
assert_not_contains "${merged}" '"mcp"' "settings merges no MCP block"
oc_assert_no_copies "${home}" "settings copies nothing"
if [[ "$(readlink "${home}/.config/opencode/AGENTS.md")" == "${REPO_ROOT}/.opencode-plugin/AGENTS.md" ]]; then ok "rules links AGENTS.md"; else ko "rules links AGENTS.md"; fi
install_must_succeed "${home}" remove --target opencode --intent settings,plugins,rules --global
merged="$(cat "${home}/.config/opencode/opencode.json")"
assert_contains "${merged}" "sk-local-secret" "remove keeps provider credentials"
assert_contains "${merged}" "@user/local-plugin" "remove keeps user plugin"
assert_not_contains "${merged}" "@prevalentware/opencode-goal-plugin" "remove takes back the goal plugin"
if [[ ! -L "${home}/.config/opencode/AGENTS.md" ]]; then ok "remove unlinks AGENTS.md"; else ko "remove unlinks AGENTS.md"; fi

home="$(new_home)"
install_must_succeed "${home}" list plugins --target opencode
if [[ "${INSTALL_OUT}" == $'@prevalentware/opencode-goal-plugin\noh-my-opencode-slim' ]]; then ok "list plugins --target opencode lists package names, then catalog names"; else ko "list plugins --target opencode lists package names, then catalog names" "${INSTALL_OUT}"; fi

echo "== install.sh settings: opencode project scope (default) =="

home="$(new_home)"
cat > "${home}/project/opencode.json" <<'JSON'
{
  "provider": { "mine": { "options": { "apiKey": "sk-project-secret" } } }
}
JSON
install_must_succeed "${home}" sync --target opencode --intent settings
proj="$(cat "${home}/project/opencode.json")"
assert_contains "${proj}" "sk-project-secret" "project merge preserves a foreign provider credential"
assert_contains "${proj}" '"model"' "project merge applies the managed model"
assert_contains "${proj}" '"subagent_depth"' "project merge applies experimental.subagent_depth"
assert_not_contains "${proj}" '"plugins"' "project merge carries no plugins group"
if [[ ! -e "${home}/.config/opencode/opencode.json" ]]; then ok "default opencode settings leaves the global config alone"; else ko "default opencode settings leaves the global config alone"; fi
install_must_succeed "${home}" remove --target opencode --intent settings
proj="$(cat "${home}/project/opencode.json")"
assert_contains "${proj}" "sk-project-secret" "project remove keeps the foreign provider credential"
assert_not_contains "${proj}" '"subagent_depth"' "project remove takes the managed leaves back"

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent settings --global
install_must_succeed "${home}" sync --target opencode --intent settings
assert_contains "${INSTALL_OUT}" "settings now default to project scope" "opencode legacy hint printed when the global file holds ycc state"

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent settings,plugins
assert_contains "${INSTALL_OUT}" "the plugins group is global-only" "opencode default settings,plugins drops the bundle plugins group"

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

# A missing global config directory cannot alias the project destination.
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
