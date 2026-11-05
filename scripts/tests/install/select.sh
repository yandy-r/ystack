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
if [[ "${INSTALL_OUT}" == $'mcps\nskills\nagents\ncommands\nplugins\nmods' ]]; then ok "bare list prints the selectable kinds"; else ko "bare list prints the selectable kinds" "${INSTALL_OUT}"; fi
install_must_succeed "${home}" list mcps --target opencode
list_out="${INSTALL_OUT}"
install_must_succeed "${home}" list-mcps --target opencode
if [[ -n "${list_out}" && "${list_out}" == "${INSTALL_OUT}" ]]; then ok "list-mcps is an alias of list mcps"; else ko "list-mcps is an alias of list mcps" "${INSTALL_OUT}"; fi
# Only opencode manages selectable MCP servers (native targets ship the ycc-mcp package).
install_must_succeed "${home}" list mcps
if [[ -n "${INSTALL_OUT}" && "${INSTALL_OUT}" == "${list_out}" ]]; then ok "list mcps names only opencode's servers"; else ko "list mcps names only opencode's servers" "${INSTALL_OUT}"; fi
for t in claude codex cursor omp; do
    install_must_succeed "${home}" list skills --target "${t}"
    if [[ -z "${INSTALL_OUT}" ]]; then ok "list skills is empty for native ${t}"; else ko "list skills is empty for native ${t}" "${INSTALL_OUT}"; fi
done
out="$(run_install "${home}" list hooks)"
assert_contains "${out}" "unknown kind 'hooks' (valid: mcps skills agents commands plugins mods)" "hooks is no longer a selectable kind"
out="$(run_install "${home}" list widgets)"
assert_contains "${out}" "unknown kind 'widgets' (valid: mcps skills agents commands plugins mods)" "list rejects an unknown kind"
out="$(run_install "${home}" list mcps --bogus)"
assert_contains "${out}" "Unknown option for list: --bogus" "list rejects unknown options"
out="$(run_install "${home}" list-mcps --bogus)"
assert_contains "${out}" "Unknown option for list-mcps: --bogus" "list-mcps keeps its unknown-option error"
out="$(run_install "${home}" list-mcps extra)"
assert_contains "${out}" "Unknown option for list-mcps: extra" "list-mcps rejects a positional argument"

echo
echo "== install.sh --<kind>: parsing =="

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent mcp --mcps ' github , github,vercel'
assert_contains "${INSTALL_OUT}" "MCP servers: github, vercel" "selection drops spaces and duplicates, keeps order"
merged="$(cat "${home}/project/opencode.json")"
assert_contains "${merged}" '"vercel"' "deduped selection writes every named server"
assert_not_contains "${merged}" '"stripe"' "deduped selection writes nothing else"

home="$(new_home)"
out="$(run_install "${home}" sync --target opencode --intent mcp --mcps ",")"
assert_contains "${out}" "--mcps contains an empty value" "empty item rejected"
out="$(run_install "${home}" sync --target opencode --intent mcp --mcps)"
assert_contains "${out}" "--mcps requires a comma-separated list of MCP servers" "missing value rejected"
out="$(run_install "${home}" sync --target opencode --intent mcp --widgets x)"
assert_contains "${out}" "Unknown option: --widgets" "unregistered kind is an unknown option"

home="$(new_home)"
out="$(run_install "${home}" sync --target opencode --intent mcp --mcps bogus)"
assert_contains "${out}" "unknown MCP server 'bogus'" "unknown name rejected"
assert_contains "${out}" "list them with: ycc list mcps --target <targets>" "unknown name points at ycc list mcps"
if [[ ! -e "${home}/project/opencode.json" ]]; then ok "unknown name writes nothing"; else ko "unknown name writes nothing"; fi

home="$(new_home)"
out="$(run_install "${home}" remove --target opencode --intent settings --mcps github)"
assert_contains "${out}" "--mcps needs the mcp step (sync/remove --intent mcp, install --mcp or --only mcp)" "selector without its step rejected"

echo
echo "== install.sh: opencode/agents-only selections on native targets =="

# Native-package targets install whole packages: with only native targets the
# selection is an error before anything runs.
for args in "--mcps github --intent mcp" "--skills plan --intent skills" "--agents implementor --intent agents" \
    "--commands clean --intent commands" "--skills plan --with-deps --intent skills" "--skills-home agents --intent base"; do
    for t in claude codex cursor omp claude,codex; do
        home="$(new_home)"
        # shellcheck disable=SC2086  # args split on purpose.
        if out="$(run_install "${home}" sync --target "${t}" ${args})"; then
            ko "${t}: ${args%% *} rejected with only native targets"
        else
            assert_contains "${out}" "narrow only the opencode and agents targets" "${t}: ${args%% *} rejected with only native targets"
        fi
        if [[ ! -s "${home}/claude-calls.log" ]]; then ok "${t}: ${args%% *} rejection runs nothing"; else ko "${t}: ${args%% *} rejection runs nothing"; fi
    done
done

# Mixed with opencode: applies there, one notice for the native targets.
home="$(new_home)"
install_must_succeed "${home}" sync --target claude,opencode --intent mcp --mcps github
assert_contains "${INSTALL_OUT}" "--mcps: native-package targets claude install whole packages — skipped there" "mixed run skips native targets with one notice"
count="$(grep -c "native-package targets" <<< "${INSTALL_OUT}")"
if [[ "${count}" == "1" ]]; then ok "the notice prints once"; else ko "the notice prints once" "printed ${count} times"; fi
assert_contains "$(cat "${home}/project/opencode.json")" '"github"' "mixed run narrows opencode"
assert_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin install ycc-mcp@ycc" "mixed run still installs claude's whole ycc-mcp package"

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
expected="$(printf '%s\n' mcps skills agents commands plugins mods widgets --- a1 shared b1 --- shared b1)"
if [[ "${out}" == "${expected}" ]]; then ok "list covers a registered kind (union, first-seen, skips targets without the step)"; else ko "list covers a registered kind" "${out}"; fi

out="$(widgets_run 'parse_selection widgets " b1 , shared,b1"; selection_for widgets; has_selection widgets && echo has; has_selection mcps || echo none')"
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
