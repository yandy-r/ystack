#!/usr/bin/env bash
# install.sh tests — MCP server selection: --mcps narrows opencode's MCP merge
# for sync/install/remove (claude, codex and cursor ship the whole ycc-mcp
# package), list-mcps (alias of list mcps), and the --mcps completions.
#
# Runs alone (bash scripts/tests/install/mcps.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== install.sh list-mcps =="

home="$(new_home)"
install_must_succeed "${home}" list-mcps
out="${INSTALL_OUT}"
assert_contains "${out}" "github" "list-mcps lists shared servers"
assert_contains "${out}" "vercel" "list-mcps includes vercel"
all_names="${out}"
install_must_succeed "${home}" list-mcps --target opencode
if [[ "${INSTALL_OUT}" == "${all_names}" ]]; then ok "opencode manages every MCP server"; else ko "opencode manages every MCP server" "${INSTALL_OUT}"; fi
for t in claude cursor codex omp agents; do
    install_must_succeed "${home}" list-mcps --target "${t}"
    if [[ -z "${INSTALL_OUT}" ]]; then ok "list-mcps lists nothing selectable for ${t}"; else ko "list-mcps lists nothing selectable for ${t}" "${INSTALL_OUT}"; fi
done
out="$(run_install "${home}" list-mcps --target bogus)"
assert_contains "${out}" "Unknown target: bogus" "list-mcps validates targets"

echo
echo "== install.sh --mcps: validation =="

home="$(new_home)"
out="$(run_install "${home}" sync --target opencode --intent settings --mcps github)"
assert_contains "${out}" "--mcps needs the mcp step" "--mcps without the mcp intent rejected"

home="$(new_home)"
out="$(run_install "${home}" sync --target opencode --intent mcp --mcps github,bogus)"
assert_contains "${out}" "unknown MCP server 'bogus'" "unknown --mcps name rejected"
if [[ ! -e "${home}/project/opencode.json" ]]; then ok "rejected --mcps writes nothing"; else ko "rejected --mcps writes nothing"; fi

home="$(new_home)"
out="$(run_install "${home}" sync --target opencode --intent mcp --mcps "github,,linear")"
assert_contains "${out}" "--mcps contains an empty value" "empty --mcps item rejected"

home="$(new_home)"
out="$(run_install "${home}" sync --target claude --intent mcp --mcps github)"
assert_contains "${out}" "narrow only the opencode and agents targets" "--mcps with only native targets is rejected"

echo
echo "== install.sh --mcps: opencode narrows, native targets install the package =="

home="$(new_home)"
install_must_succeed "${home}" sync --target all --intent mcp --mcps github,vercel
merged="$(cat "${home}/project/opencode.json" 2>/dev/null)"
assert_contains "${merged}" '"github"' "--mcps writes github to opencode.json"
assert_contains "${merged}" '"vercel"' "--mcps writes vercel to opencode.json"
assert_not_contains "${merged}" '"stripe"' "--mcps skips unselected servers in opencode.json"
assert_contains "${INSTALL_OUT}" "--mcps: native-package targets" "--target all names the skipped native targets once"
for f in .mcp.json .cursor/mcp.json .codex/config.toml; do
    if [[ ! -e "${home}/project/${f}" ]]; then ok "--target all writes no legacy MCP merge to ${f}"; else ko "--target all writes no legacy MCP merge to ${f}"; fi
done

home="$(new_home)"
install_must_succeed "${home}" install --target opencode --only mcp --global --mcps github
assert_not_contains "$(cat "${home}/.config/opencode/opencode.json")" '"playwright"' "install --only mcp honors --mcps"

echo
echo "== install.sh --mcps: partial sync and remove =="

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent mcp
install_must_succeed "${home}" sync --target opencode --intent mcp --mcps github
assert_contains "$(cat "${home}/project/opencode.json")" '"stripe"' "partial sync keeps other managed servers"
install_must_succeed "${home}" remove --target opencode --intent mcp --mcps stripe
merged="$(cat "${home}/project/opencode.json")"
assert_not_contains "${merged}" '"stripe"' "remove --mcps drops the selected server"
assert_contains "${merged}" '"github"' "remove --mcps keeps the others"

echo
echo "== --mcps completion =="

# A new kind needs no completion edits: a stub ycc whose 'list' adds 'widgets'
# must get a --widgets flag with names from 'ycc list widgets --target <t>'.
widget_bin="${SANDBOX_ROOT}/widget-bin"
mkdir -p "${widget_bin}"
cat > "${widget_bin}/ycc" <<'SH'
#!/usr/bin/env bash
[[ "$1" == list ]] || exit 1
if [[ $# -eq 1 ]]; then printf '%s\n' mcps widgets; exit 0; fi
[[ "$2" == widgets && "$3" == --target ]] && printf '%s\n' "w-$4" w-shared
SH
chmod +x "${widget_bin}/ycc"
out="$(PATH="${widget_bin}:${PATH}" bash -c 'source "$1"; COMP_WORDS=(ycc sync --wid); COMP_CWORD=2; _ycc; echo "${COMPREPLY[*]}"' \
    _ "${REPO_ROOT}/scripts/completions/ycc.bash")"
assert_contains "${out}" "--widgets" "bash offers the selector flag of a new kind"
out="$(PATH="${widget_bin}:${PATH}" bash -c 'source "$1"; COMP_WORDS=(ycc sync --target codex --widgets w-shared,w); COMP_CWORD=5; _ycc; echo "${COMPREPLY[*]}"' \
    _ "${REPO_ROOT}/scripts/completions/ycc.bash")"
assert_contains "${out}" "w-shared,w-codex" "bash completes a new kind's names for the line's --target"
if command -v zsh >/dev/null; then
    # Stub the completion builtins, then run the --widgets action the way
    # _arguments does: with '-J -default-' prepended to its words.
    out="$(PATH="${widget_bin}:${PATH}" zsh -f -c '
        _arguments() { specs=("$@"); }
        _values() { print -r -- "VALUES $*"; }
        compdef() { :; }
        source "$1"
        words=(ycc sync --target codex --widgets ""); CURRENT=6
        _ycc
        for s in "${specs[@]}"; do [[ "${s}" == --widgets* ]] && action="${s##*:}"; done
        [[ -n "${action:-}" ]] || { print "no --widgets spec"; exit 1; }
        _ycc_cmd=ycc
        local -a act=(${(z)action})
        "${act[1]}" -J -default- "${act[@]:1}"
    ' _ "${REPO_ROOT}/scripts/completions/_ycc" 2>&1)"
    assert_contains "${out}" "VALUES -s , widgets w-codex w-shared" "zsh completes a new kind's names for the line's --target"
else
    printf '[skip] zsh completion behavior (zsh not installed)\n'
fi
out="$(PATH="${REPO_ROOT}:${PATH}" bash -c 'source "$1"
    COMP_WORDS=(install.sh sync --target opencode --intent mcp --mcps github,ve); COMP_CWORD=7; _ycc; echo "${COMPREPLY[*]}"' \
    _ "${REPO_ROOT}/scripts/completions/ycc.bash")"
assert_contains "${out}" "github,vercel" "bash completes --mcps for the line's --target"
# Readline splits 'name@mkt' at '@' (default COMP_WORDBREAKS): feed the words
# and COMP_LINE the way a real shell does. It then replaces the current word
# together with a '@' right before it (a bash special prefix), so replies
# start at that '@'.
# complete_split <line> <words...> — COMPREPLY for <line> with the cursor at its end.
complete_split() {
    PATH="${REPO_ROOT}:${PATH}" bash -c 'source "$1"; COMP_LINE="$2"; COMP_POINT=${#COMP_LINE}
        COMP_WORDS=("${@:3}"); COMP_CWORD=$((${#COMP_WORDS[@]} - 1)); _ycc; printf "%s\n" "${COMPREPLY[@]}"' \
        _ "${REPO_ROOT}/scripts/completions/ycc.bash" "$@"
}
out="$(complete_split "install.sh sync --target opencode --intent plugins --plugins @prev" \
    install.sh sync --target opencode --intent plugins --plugins @ prev)"
if [[ "${out}" == "@prevalentware/opencode-goal-plugin" ]]; then ok "bash completes a '@'-split --plugins name"; else ko "bash completes a '@'-split --plugins name" "${out}"; fi
out="$(complete_split "install.sh sync --target codex --intent plugins --plugins github@openai-curated,clo" \
    install.sh sync --target codex --intent plugins --plugins github @ openai-curated,clo)"
if [[ "${out}" == "@openai-curated,cloudflare@openai-curated" ]]; then ok "bash completes a --plugins comma list after a name@mkt item"; else ko "bash completes a --plugins comma list after a name@mkt item" "${out}"; fi
out="$(complete_split "install.sh sync --target codex --intent plugins --plugins github@openai-curated,cloudflare@" \
    install.sh sync --target codex --intent plugins --plugins github @ openai-curated,cloudflare @)"
if [[ "${out}" == "@openai-curated" ]]; then ok "bash completes after a trailing '@'"; else ko "bash completes after a trailing '@'" "${out}"; fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
