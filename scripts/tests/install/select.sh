#!/usr/bin/env bash
# install.sh tests — generic item selection (scripts/lib/install/select.sh):
# --<kind> parsing, preflight, 'list [<kind>]', and the extension contract
# (a new kind is a registry row plus a <kind>_names adapter).
#
# Runs alone (bash scripts/tests/install/select.sh) or from scripts/test-install-sync.sh.
# shellcheck disable=SC2016  # widgets_run snippets expand in the child bash.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== install.sh list =="

home="$(new_home)"
install_must_succeed "${home}" list
if [[ "${INSTALL_OUT}" == $'skills\nplugins\nmods' ]]; then ok "bare list prints the selectable kinds"; else ko "bare list prints the selectable kinds" "${INSTALL_OUT}"; fi
install_must_succeed "${home}" list skills --target agents
assert_contains "${INSTALL_OUT}" "backport" "list skills names the agents target's skills"
for t in claude codex cursor omp opencode; do
    install_must_succeed "${home}" list skills --target "${t}"
    if [[ -z "${INSTALL_OUT}" ]]; then ok "list skills is empty for native ${t}"; else ko "list skills is empty for native ${t}" "${INSTALL_OUT}"; fi
done
for kind in hooks mcps agents commands; do
    out="$(run_install "${home}" list "${kind}")"
    assert_contains "${out}" "unknown kind '${kind}' (valid: skills plugins mods)" "${kind} is not a selectable kind"
done
out="$(run_install "${home}" list widgets)"
assert_contains "${out}" "unknown kind 'widgets' (valid: skills plugins mods)" "list rejects an unknown kind"
out="$(run_install "${home}" list skills --bogus)"
assert_contains "${out}" "Unknown option for list: --bogus" "list rejects unknown options"
out="$(run_install "${home}" list-mcps)"
if [[ "${out}" != *"github"* ]]; then ok "list-mcps is gone"; else ko "list-mcps is gone" "${out}"; fi

echo
echo "== install.sh --<kind>: parsing =="

home="$(new_home)"
install_must_succeed "${home}" sync --target agents --intent skills --skills ' plan , plan,backport'
assert_contains "${INSTALL_OUT}" "Skills: plan, backport" "selection drops spaces and duplicates, keeps order"
if [[ -d "${home}/.agents/skills/backport" && ! -d "${home}/.agents/skills/go-patterns" ]]; then ok "deduped selection writes only the named skills"; else ko "deduped selection writes only the named skills"; fi

home="$(new_home)"
out="$(run_install "${home}" sync --target agents --intent skills --skills ",")"
assert_contains "${out}" "--skills contains an empty value" "empty item rejected"
out="$(run_install "${home}" sync --target agents --intent skills --skills)"
assert_contains "${out}" "--skills requires a comma-separated list of skills" "missing value rejected"
for flag in --widgets --mcps --agents --commands --skills-home; do
    out="$(run_install "${home}" sync --target agents --intent skills "${flag}" x)"
    assert_contains "${out}" "Unknown option: ${flag}" "${flag} is an unknown option"
done

home="$(new_home)"
out="$(run_install "${home}" sync --target agents --intent skills --skills bogus)"
assert_contains "${out}" "unknown skill 'bogus'" "unknown name rejected"
assert_contains "${out}" "list them with: ycc list skills --target <targets>" "unknown name points at ycc list skills"
if [[ ! -e "${home}/.agents/skills" ]]; then ok "unknown name writes nothing"; else ko "unknown name writes nothing"; fi

echo
echo "== install.sh: agents-only selections on native targets =="

# Native-package targets install whole packages: with only native targets the
# selection is an error before anything runs.
for args in "--skills plan --intent skills" "--skills plan --with-deps --intent skills"; do
    for t in claude codex cursor omp opencode claude,codex; do
        home="$(new_home)"
        # shellcheck disable=SC2086  # args split on purpose.
        if out="$(run_install "${home}" sync --target "${t}" ${args})"; then
            ko "${t}: ${args%% *} rejected with only native targets"
        else
            assert_contains "${out}" "narrow only the agents target" "${t}: ${args%% *} rejected with only native targets"
        fi
        if [[ ! -s "${home}/claude-calls.log" ]]; then ok "${t}: ${args%% *} rejection runs nothing"; else ko "${t}: ${args%% *} rejection runs nothing"; fi
    done
done

# Mixed with agents: applies there, one notice for the native targets.
home="$(new_home)"
install_must_succeed "${home}" sync --target claude,agents --intent skills --skills plan
assert_contains "${INSTALL_OUT}" "--skills: native-package targets claude install whole packages — skipped there" "mixed run skips native targets with one notice"
count="$(grep -c "native-package targets" <<< "${INSTALL_OUT}")"
if [[ "${count}" == "1" ]]; then ok "the notice prints once"; else ko "the notice prints once" "printed ${count} times"; fi
if [[ -d "${home}/.agents/skills/plan" && ! -d "${home}/.agents/skills/backport" ]]; then ok "mixed run narrows agents"; else ko "mixed run narrows agents"; fi

echo
echo "== select.sh: extension contract (fake kind) =="

widgets_run() {
    bash -c '
        set -euo pipefail
        err()  { printf "[err] %s\n" "$1"; }
        warn() { printf "[!!] %s\n" "$1"; }
        info() { printf "[ok] %s\n" "$1"; }
        usage() { :; }
        CLI_NAME=ycc PACKAGE="" INTENTS=() TARGETS=()
        resolve_targets() { IFS=, read -r -a TARGETS <<< "${1/all/alpha,beta,gamma}"; }
        valid_steps_for_target() { case "$1" in gamma) echo base ;; *) echo base,widget ;; esac; }
        step_enabled() { [[ "$1" == widget ]]; }
        source "$1/scripts/lib/install/select.sh"
        SELECTABLE_KINDS+=(widgets)
        SELECTION_STEP[widgets]=widget
        SELECTION_NOUN[widgets]=widget
        SELECTION_NOUNS[widgets]=widgets
        SELECTION_STEP_HINT[widgets]="--only widget"
        widgets_names() { case "$1" in alpha) printf "%s\n" a1 shared ;; beta) printf "%s\n" shared b1 ;; gamma) echo g1 ;; esac; }
        eval "$2"
    ' _ "${REPO_ROOT}" "$1" 2>&1
}

out="$(widgets_run 'run_list_command; echo ---; run_list_command widgets; echo ---; run_list_command widgets --target beta')"
expected="$(printf '%s\n' skills plugins mods widgets --- a1 shared b1 --- shared b1)"
if [[ "${out}" == "${expected}" ]]; then ok "list covers a registered kind (union, first-seen, skips targets without the step)"; else ko "list covers a registered kind" "${out}"; fi

out="$(widgets_run 'parse_selection widgets " b1 , shared,b1"; selection_for widgets; has_selection widgets && echo has; has_selection mods || echo none')"
if [[ "${out}" == $'b1,shared\nhas\nnone' ]]; then ok "parse_selection handles a registered kind"; else ko "parse_selection handles a registered kind" "${out}"; fi

out="$(widgets_run 'parse_selection widgets "a1,b1"; TARGETS=(alpha beta); preflight_selections; echo "alpha=$(selection_for_target widgets alpha) beta=$(selection_for_target widgets beta)"')"
assert_contains "${out}" "[!!] alpha does not ship widgets b1 — skipping them there" "name missing on one target warns"
assert_contains "${out}" "[!!] beta does not ship widgets a1 — skipping them there" "warns per target"
assert_contains "${out}" "alpha=a1 beta=b1" "each target gets only the names it ships"

out="$(widgets_run 'parse_selection widgets "a1"; TARGETS=(alpha beta); preflight_selections; echo "beta=[$(selection_for_target widgets beta)]"')"
assert_not_contains "${out}" "[!!]" "a target shipping none of the names skips its step without a preflight warning"
assert_contains "${out}" "beta=[]" "empty selection for a target that ships none"

out="$(widgets_run 'parse_selection widgets "zz"; TARGETS=(alpha); preflight_selections')"
assert_contains "${out}" "unknown widget 'zz' (managed for alpha: a1 shared)" "unknown name rejected for a registered kind"
assert_contains "${out}" "ycc list widgets --target <targets>" "hint names the kind"

out="$(widgets_run 'parse_selection widgets "g1"; TARGETS=(gamma); preflight_selections')"
assert_contains "${out}" "--widgets needs the widget step (--only widget) on a target that has one" "kind without its step rejected"

out="$(widgets_run 'parse_selection widgets ","')"
assert_contains "${out}" "--widgets contains an empty value" "empty item message names the kind"

# A kind that narrows one config group (SELECTION_GROUP) also needs that group.
out="$(widgets_run 'SELECTION_GROUP[widgets]=wgroup; config_groups_for_target() { [[ "$1" == beta ]] && echo settings,wgroup; [[ "$1" == alpha ]] && echo settings; return 0; }
    parse_selection widgets "a1"; TARGETS=(alpha); preflight_selections')"
assert_contains "${out}" "--widgets needs the widget step (--only widget) on a target that has one" "group kind without its group rejected"
out="$(widgets_run 'SELECTION_GROUP[widgets]=wgroup; config_groups_for_target() { [[ "$1" == beta ]] && echo settings,wgroup; [[ "$1" == alpha ]] && echo settings; return 0; }
    parse_selection widgets "b1"; TARGETS=(alpha beta); preflight_selections; echo "beta=$(selection_for_target widgets beta)"')"
assert_contains "${out}" "beta=b1" "group kind passes preflight where the group runs"

echo
echo "== selection completion =="

# A new kind needs no completion edits: a stub ycc whose 'list' adds 'widgets'
# must get a --widgets flag with names from 'ycc list widgets --target <t>'.
widget_bin="${SANDBOX_ROOT}/widget-bin"
mkdir -p "${widget_bin}"
cat > "${widget_bin}/ycc" <<'SH'
#!/usr/bin/env bash
[[ "$1" == list ]] || exit 1
if [[ $# -eq 1 ]]; then printf '%s\n' skills widgets; exit 0; fi
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
    COMP_WORDS=(install.sh sync --target agents --intent skills --skills backport,blu); COMP_CWORD=7; _ycc; echo "${COMPREPLY[*]}"' \
    _ "${REPO_ROOT}/scripts/completions/ycc.bash")"
assert_contains "${out}" "backport,blueprint" "bash completes --skills for the line's --target"
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
