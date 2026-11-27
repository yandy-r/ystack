#!/usr/bin/env bash
# install.sh tests — muse: the owned copies registered through a stub 'muse'
# CLI, the opt-in AGENTS.md link, project scope, mode rejections, --package and 'all'
# gating.
#
# Runs alone (bash scripts/tests/install/muse.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MUSE_PACKAGES=(ycc ycc-mcp ycc-rules)

# stub_muse <home> — a fake 'muse plugins ...' that logs calls and keeps an
# installed-id list, exported through YCC_MUSE_BIN.
stub_muse() {
    local home="$1"
    mkdir -p "${home}/bin"
    cat > "${home}/bin/muse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HOME}/muse-calls.log"
db="${HOME}/muse-installed.txt"; touch "${db}"
case "$1 $2" in
    "plugins list")
        python3 -c 'import json,sys; ids=[l.strip() for l in open(sys.argv[1]) if l.strip()]
print(json.dumps({"plugins": [{"record": {"id": i}} for i in ids]}))' "${db}" ;;
    "plugins install")
        name="$(basename "$3")"; grep -qx "${name}" "${db}" || echo "${name}" >> "${db}"; echo '{}' ;;
    "plugins approve") echo '{"decision": "approve"}' ;;
    "plugins remove") grep -vx "$3" "${db}" > "${db}.tmp" || true; mv "${db}.tmp" "${db}"; echo '{}' ;;
esac
SH
    chmod +x "${home}/bin/muse"
    export YCC_MUSE_BIN="${home}/bin/muse"
}

echo "== install.sh sync: muse (owned copies + muse plugins install) =="

home="$(new_home)"
stub_muse "${home}"
copies="${home}/.local/share/ycc/muse"
install_must_succeed "${home}" sync --target muse --intent base
for pkg in "${MUSE_PACKAGES[@]}"; do
    if [[ -d "${copies}/${pkg}" ]]; then
        ok "muse base places ${pkg} in ~/.local/share/ycc/muse"
    else
        ko "muse base places ${pkg} in ~/.local/share/ycc/muse" "${INSTALL_OUT}"
    fi
    assert_contains "$(cat "${home}/muse-calls.log")" "plugins install ${copies}/${pkg} --scope user --json" "muse base installs ${pkg} from its owned copy"
    assert_contains "$(cat "${home}/muse-calls.log")" "plugins approve ${pkg} --json" "muse base approves ${pkg}"
done
[[ -f "${copies}/ycc/.claude-plugin/plugin.json" && -f "${copies}/ycc-mcp/.muse-plugin/plugin.json" ]] \
    && ok "muse copies carry their manifest families" || ko "muse copies carry their manifest families" "${INSTALL_OUT}"
install_must_succeed "${home}" sync --target muse --intent skills,agents,mcp
assert_contains "${INSTALL_OUT}" "ycc is up to date" "muse skills/agents/mcp intents map to the idempotent base"

install_must_succeed "${home}" sync --target muse --intent rules
if [[ "$(readlink "${home}/.config/muse/AGENTS.md")" == "${REPO_ROOT}/ycc/settings/rules/AGENTS.md" ]]; then
    ok "muse rules links ~/.config/muse/AGENTS.md"
else
    ko "muse rules links ~/.config/muse/AGENTS.md" "${INSTALL_OUT}"
fi

install_must_succeed "${home}" sync --target muse --intent hooks,settings
assert_contains "${INSTALL_OUT}" "muse target ran no steps" "muse hooks/settings are no-ops"

echo "#mine" > "${copies}/ycc-mcp/notes.md"
install_must_succeed "${home}" remove --target muse --intent base,rules
assert_contains "${INSTALL_OUT}" "kept ycc-mcp" "muse remove keeps an edited copy"
assert_contains "$(cat "${home}/muse-calls.log")" "plugins remove ycc --json" "muse remove uninstalls ycc"
assert_not_contains "$(cat "${home}/muse-calls.log")" "plugins remove ycc-mcp" "muse remove leaves the edited plugin registered"
if [[ ! -e "${copies}/ycc" && -f "${copies}/ycc-mcp/notes.md" ]]; then
    ok "muse remove deletes only unedited ycc copies"
else
    ko "muse remove deletes only unedited ycc copies" "${INSTALL_OUT}"
fi
[[ ! -e "${home}/.config/muse/AGENTS.md" ]] && ok "muse remove unlinks AGENTS.md" || ko "muse remove unlinks AGENTS.md" "${INSTALL_OUT}"
unset YCC_MUSE_BIN

echo "== install.sh: muse --package and a missing CLI =="

home="$(new_home)"
stub_muse "${home}"
install_must_succeed "${home}" install --target muse --package ycc-mcp
assert_contains "$(cat "${home}/muse-calls.log")" "plugins install ${home}/.local/share/ycc/muse/ycc-mcp" "muse --package ycc-mcp installs that plugin"
assert_not_contains "$(cat "${home}/muse-calls.log")" "muse/ycc --scope" "muse --package installs only the named plugin"
unset YCC_MUSE_BIN
out="$(YCC_MUSE_BIN="" without_command muse run_install "${home}" sync --target muse --intent base)" && rc=0 || rc=$?
[[ ${rc} -ne 0 ]] && ok "muse base fails without the muse CLI" || ko "muse base fails without the muse CLI" "${out}"
assert_contains "${out}" "not on PATH" "muse names the missing CLI"

echo "== install.sh: muse rejections and dry-run =="

home="$(new_home)"
stub_muse "${home}"
install_must_succeed "${home}" sync --target muse --intent base --project
assert_contains "$(cat "${home}/muse-calls.log")" "--scope project --json" "muse --project installs at Muse's project scope"
out="$(run_install "${home}" sync --target muse --intent rules --project)" && rc=0 || rc=$?
[[ ${rc} -ne 0 ]] && ok "muse rejects --project for rules" || ko "muse rejects --project for rules" "${out}"
assert_contains "${out}" "--project is not supported by step 'rules' for target 'muse'" "muse --project names the rules step"
unset YCC_MUSE_BIN
out="$(run_install "${home}" sync --target muse --intent base --mode repo)" && rc=0 || rc=$?
[[ ${rc} -ne 0 ]] && ok "muse rejects --mode repo" || ko "muse rejects --mode repo" "${out}"
home="$(new_home)"
YCC_MUSE_BIN="" without_command muse install_must_succeed "${home}" sync --target muse --intent base,rules --dry-run
assert_contains "${INSTALL_OUT}" "[dry-run] would copy" "muse dry-run previews the copies"
assert_contains "${INSTALL_OUT}" "[dry-run] would run: muse plugins install" "muse dry-run previews the muse calls"
[[ ! -e "${home}/.local/share/ycc" && ! -e "${home}/.config/muse" ]] && ok "muse dry-run writes nothing" || ko "muse dry-run writes nothing" "${INSTALL_OUT}"

echo "== install.sh: --target all gates muse =="

home="$(new_home)"
YCC_MUSE_BIN="" without_command muse install_must_succeed "${home}" sync --target all --intent rules --dry-run
assert_contains "${INSTALL_OUT}" "skipping muse" "all skips muse without the muse CLI"
stub_muse "${home}"
PATH="${home}/bin:${PATH}" install_must_succeed "${home}" sync --target all --intent rules --dry-run
assert_contains "${INSTALL_OUT}" "would link ${home}/.config/muse/AGENTS.md" "all includes muse once muse is on PATH"
unset YCC_MUSE_BIN

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
