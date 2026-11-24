#!/usr/bin/env bash
# install.sh tests — antigravity: the native plugins (owned-copy route and a
# stub 'agy'), the opt-in AGENTS.md link, scope/mode rejections, --package and
# 'all' gating.
#
# Runs alone (bash scripts/tests/install/antigravity.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AG_PACKAGES=(ycc ycc-mcp ycc-rules)

echo "== install.sh sync: antigravity (owned copies, no agy) =="

home="$(new_home)"
plugins="${home}/.gemini/config/plugins"
install_must_succeed "${home}" sync --target antigravity --intent base
for pkg in "${AG_PACKAGES[@]}"; do
    if [[ -f "${plugins}/${pkg}/plugin.json" ]]; then
        ok "antigravity base places ${pkg} in ~/.gemini/config/plugins"
    else
        ko "antigravity base places ${pkg} in ~/.gemini/config/plugins" "${INSTALL_OUT}"
    fi
done
assert_contains "${INSTALL_OUT}" "owned copy" "antigravity without agy reports the owned-copy route"
install_must_succeed "${home}" sync --target antigravity --intent skills,agents,mcp
assert_contains "${INSTALL_OUT}" "ycc is up to date" "antigravity skills/agents/mcp intents map to the idempotent base"

install_must_succeed "${home}" sync --target antigravity --intent rules
if [[ "$(readlink "${home}/.gemini/config/AGENTS.md")" == "${REPO_ROOT}/ycc/settings/rules/AGENTS.md" ]]; then
    ok "antigravity rules links ~/.gemini/config/AGENTS.md"
else
    ko "antigravity rules links ~/.gemini/config/AGENTS.md" "${INSTALL_OUT}"
fi

install_must_succeed "${home}" sync --target antigravity --intent hooks,settings
assert_contains "${INSTALL_OUT}" "antigravity target ran no steps" "antigravity hooks/settings are no-ops"

echo "#mine" > "${plugins}/ycc-rules/notes.md"
install_must_succeed "${home}" remove --target antigravity --intent base,rules
assert_contains "${INSTALL_OUT}" "kept ycc-rules" "antigravity remove keeps an edited plugin"
if [[ ! -e "${plugins}/ycc" && ! -e "${plugins}/ycc-mcp" && -f "${plugins}/ycc-rules/notes.md" ]]; then
    ok "antigravity remove deletes only unedited ycc plugins"
else
    ko "antigravity remove deletes only unedited ycc plugins" "${INSTALL_OUT}"
fi
[[ ! -e "${home}/.gemini/config/AGENTS.md" ]] && ok "antigravity remove unlinks AGENTS.md" || ko "antigravity remove unlinks AGENTS.md" "${INSTALL_OUT}"

echo "== install.sh: antigravity foreign plugin folder =="

home="$(new_home)"
mkdir -p "${home}/.gemini/config/plugins/ycc"
echo '{"name": "ycc", "mine": true}' > "${home}/.gemini/config/plugins/ycc/plugin.json"
out="$(run_install "${home}" sync --target antigravity --intent base)" && rc=0 || rc=$?
[[ ${rc} -ne 0 ]] && ok "antigravity refuses to replace a foreign plugin folder" || ko "antigravity refuses to replace a foreign plugin folder" "${out}"
assert_contains "$(cat "${home}/.gemini/config/plugins/ycc/plugin.json")" '"mine"' "antigravity leaves the foreign folder untouched"
install_must_succeed "${home}" sync --target antigravity --intent base --force
assert_not_contains "$(cat "${home}/.gemini/config/plugins/ycc/plugin.json")" '"mine"' "antigravity --force replaces the foreign folder"

echo "== install.sh: antigravity via a stub agy =="

home="$(new_home)"
mkdir -p "${home}/bin"
cat > "${home}/bin/agy" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HOME}/agy-calls.log"
dir="${HOME}/.gemini/config/plugins"
case "$1 $2" in
    "plugin install")
        name="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]+"/plugin.json"))["name"])' "$3")"
        mkdir -p "${dir}" && cp -R "$3" "${dir}/${name}" ;;
    "plugin uninstall") rm -rf "${dir:?}/$3" ;;
esac
SH
chmod +x "${home}/bin/agy"
export YCC_ANTIGRAVITY_AGY="${home}/bin/agy"
install_must_succeed "${home}" install --target antigravity --package ycc-mcp
calls="$(cat "${home}/agy-calls.log")"
assert_contains "${calls}" "plugin install ${REPO_ROOT}/packages/antigravity/ycc-mcp" "antigravity --package ycc-mcp runs agy plugin install for that plugin"
assert_not_contains "${calls}" "packages/antigravity/ycc-rules" "antigravity --package installs only the named plugin"
install_must_succeed "${home}" remove --target antigravity --intent base
assert_contains "$(cat "${home}/agy-calls.log")" "plugin uninstall ycc-mcp" "antigravity remove runs agy plugin uninstall"
assert_not_contains "$(cat "${home}/agy-calls.log")" "plugin uninstall ycc-rules" "antigravity remove never uninstalls a plugin ycc did not install"
unset YCC_ANTIGRAVITY_AGY

echo "== install.sh: antigravity rejections and dry-run =="

home="$(new_home)"
out="$(run_install "${home}" sync --target antigravity --intent base --project)" && rc=0 || rc=$?
[[ ${rc} -ne 0 ]] && ok "antigravity rejects --project" || ko "antigravity rejects --project" "${out}"
assert_contains "${out}" "--project is not supported by step 'base' for target 'antigravity'" "antigravity --project names the step"
out="$(run_install "${home}" sync --target antigravity --intent base --mode repo)" && rc=0 || rc=$?
[[ ${rc} -ne 0 ]] && ok "antigravity rejects --mode repo" || ko "antigravity rejects --mode repo" "${out}"
install_must_succeed "${home}" sync --target antigravity --intent base,rules --dry-run
assert_contains "${INSTALL_OUT}" "[dry-run] would copy" "antigravity dry-run previews the copies"
[[ ! -e "${home}/.gemini" ]] && ok "antigravity dry-run writes nothing" || ko "antigravity dry-run writes nothing" "${INSTALL_OUT}"

echo "== install.sh: --target all gates antigravity =="

home="$(new_home)"
install_must_succeed "${home}" sync --target all --intent rules --dry-run
assert_contains "${INSTALL_OUT}" "skipping antigravity" "all skips antigravity without agy or ~/.gemini/config"
mkdir -p "${home}/.gemini/config"
install_must_succeed "${home}" sync --target all --intent rules --dry-run
assert_contains "${INSTALL_OUT}" "would link ${home}/.gemini/config/AGENTS.md" "all includes antigravity once ~/.gemini/config exists"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
