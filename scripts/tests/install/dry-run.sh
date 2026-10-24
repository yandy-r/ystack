#!/usr/bin/env bash
# install.sh tests — --dry-run on every target: the mcp step previews the
# merge (or removal) through merge_managed_config.py --dry-run, every other
# step says it has no preview and is skipped, and nothing is written.
# (omp's own dry-run is covered in omp.sh.)
#
# Runs alone (bash scripts/tests/install/dry-run.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# tree_digest <home> — one line per file (path + content hash) under <home>,
# minus the stub CLI log, so any write the run makes shows as a diff.
tree_digest() {
    (cd "$1" && find . -path ./claude-calls.log -prune -o \( -type f -o -type l \) -print0 \
        | sort -z | xargs -0r sha256sum)
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
for pair in "codex settings" "codex rules" "opencode settings" "cursor rules" "agents skills"; do
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
