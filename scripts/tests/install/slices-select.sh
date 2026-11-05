#!/usr/bin/env bash
# install.sh tests — --skills selection of the agents target's standalone
# skills slice: narrowing (never pruning), helpers ride along, 'base' stays
# whole, preflight errors, remove, --with-deps. Native-package targets
# (claude, codex, cursor, omp, opencode) take no selection (select.sh covers
# that rejection).
#
# Runs alone (bash scripts/tests/install/slices-select.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# entries <dir> — the dir's top-level entry names, sorted, space-separated.
entries() {
    find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}

# assert_entries <dir> <expected> <name>
assert_entries() {
    local got
    got="$(entries "$1")"
    if [[ "${got}" == "$2" ]]; then ok "$3"; else ko "$3" "got: ${got:-<none>}"; fi
}

# reject <name> <home> <install args...> — an expected rejection: the
# installer must exit nonzero. Leaves its output in REJECT_OUT.
REJECT_OUT=""
reject() {
    local name="$1" rc=0
    shift
    REJECT_OUT="$(run_install "$@")" || rc=$?
    if [[ ${rc} -ne 0 ]]; then ok "${name} (exit ${rc})"; else ko "${name} (exit 0)" "${REJECT_OUT}"; fi
}

echo "== install.sh list skills =="

home="$(new_home)"
install_must_succeed "${home}" list skills --target agents
assert_contains "${INSTALL_OUT}" "go-patterns" "list skills names agents skills"
assert_not_contains "${INSTALL_OUT}" "ycc-shared" "list skills hides ycc-shared"
assert_not_contains "${INSTALL_OUT}" "_shared" "list skills hides the _shared helper"

echo
echo "== install.sh --skills: agents =="

home="$(new_home)"
install_must_succeed "${home}" sync --target agents --intent skills --skills go-patterns,rust-testing
assert_contains "${INSTALL_OUT}" "Skills: go-patterns, rust-testing" "agents reports the selected skills"
assert_entries "${home}/.agents/skills" "go-patterns rust-testing" "agents target installs only the selected skills"
if [[ -d "${home}/.agents/ycc-shared" ]]; then ok "agents target ships ycc-shared with a selected skill"; else ko "agents target ships ycc-shared with a selected skill"; fi
if [[ ! -e "${home}/.config/opencode/skills" ]]; then ok "agents --skills writes nothing under opencode"; else ko "agents --skills writes nothing under opencode"; fi

home="$(new_home)"
install_must_succeed "${home}" sync --target all --intent skills --skills go-patterns
assert_contains "${INSTALL_OUT}" "--skills: native-package targets" "--target all: native targets skip --skills with a notice"
assert_entries "${home}/.agents/skills" "go-patterns" "--target all: agents installs exactly the selection"
if [[ ! -e "${home}/.config/opencode/skills" ]]; then ok "--target all: no opencode skills copy"; else ko "--target all: no opencode skills copy"; fi

echo
echo "== install.sh --skills: preflight =="

home="$(new_home)"
reject "unknown skill exits nonzero" "${home}" sync --target agents --intent skills --skills go-patterns,no-such-skill
assert_contains "${REJECT_OUT}" "unknown skill 'no-such-skill'" "unknown skill rejected"
assert_contains "${REJECT_OUT}" "list them with: ycc list skills --target <targets>" "unknown skill points at ycc list skills"
if [[ ! -e "${home}/.agents/skills" && ! -e "${home}/.config/ycc/installed-units.json" ]]; then
    ok "unknown skill writes nothing"
else
    ko "unknown skill writes nothing"
fi

home="$(new_home)"
reject "agents base + --skills exits nonzero" "${home}" sync --target agents --intent base --skills go-patterns
assert_contains "${REJECT_OUT}" "--skills needs the skills step (it narrows the agents target's skills slice; use --intent skills or --only skills)" "agents base is never filtered: --skills needs its skills step"

home="$(new_home)"
install_must_succeed "${home}" sync --target agents --intent base,skills --skills go-patterns
assert_contains "${INSTALL_OUT}" "agents base installs every skill into ~/.agents/skills; --skills does not narrow this run" "agents base + skills warns that --skills does not narrow"
if [[ "$(entries "${home}/.agents/skills" | wc -w)" -gt 1 ]]; then ok "agents base still installs every skill under --skills"; else ko "agents base still installs every skill under --skills" "$(entries "${home}/.agents/skills")"; fi

echo
echo "== install.sh --skills: narrowing, re-sync, remove =="

home="$(new_home)"
install_must_succeed "${home}" sync --target agents --intent skills --skills go-patterns
install_must_succeed "${home}" sync --target agents --intent skills --skills rust-testing
assert_entries "${home}/.agents/skills" "go-patterns rust-testing" "a second selection keeps the earlier selected skill"
state="$(cat "${home}/.config/ycc/installed-units.json")"
assert_contains "${state}" '"go-patterns"' "state still records the earlier selected skill"
before="$(cksum < "${home}/.config/ycc/installed-units.json")"
install_must_succeed "${home}" sync --target agents --intent skills --skills rust-testing
if [[ "$(cksum < "${home}/.config/ycc/installed-units.json")" == "${before}" ]]; then ok "re-sync of the same selection leaves state unchanged"; else ko "re-sync of the same selection leaves state unchanged"; fi
assert_entries "${home}/.agents/skills" "go-patterns rust-testing" "re-sync of the same selection changes nothing"

install_must_succeed "${home}" remove --target agents --intent skills --skills go-patterns
assert_entries "${home}/.agents/skills" "rust-testing" "agents target selective remove takes only the named skill"
if [[ -d "${home}/.agents/ycc-shared" ]]; then ok "agents target keeps ycc-shared while a ycc skill remains"; else ko "agents target keeps ycc-shared while a ycc skill remains"; fi
install_must_succeed "${home}" remove --target agents --intent skills --skills rust-testing
if [[ -z "$(entries "${home}/.agents/skills")" && ! -e "${home}/.agents/ycc-shared" ]]; then ok "agents target: removing the last selected skill takes ycc-shared too"; else ko "agents target: removing the last selected skill takes ycc-shared too" "$(entries "${home}/.agents/skills")"; fi

echo
echo "== install.sh --skills: dependency warning =="

home="$(new_home)"
install_must_succeed "${home}" sync --target agents --intent skills --skills clean
assert_contains "${INSTALL_OUT}" "is referenced by clean but not installed" "a missing ycc: dependency is reported"
assert_contains "${INSTALL_OUT}" "ycc sync --target agents --intent" "the warning names the command that adds it"
home="$(new_home)"
install_must_succeed "${home}" sync --target agents --intent skills --skills go-patterns
assert_not_contains "${INSTALL_OUT}" "is referenced by" "a self-contained skill warns about nothing"

echo
echo "== install.sh --with-deps =="

home="$(new_home)"
install_must_succeed "${home}" sync --target agents --intent skills --skills code-review --with-deps
if [[ -d "${home}/.agents/skills/code-review" && -d "${home}/.agents/skills/review-fix" ]]; then ok "--with-deps installs the selected skill and its skill dependencies"; else ko "--with-deps installs the selected skill and its skill dependencies" "$(entries "${home}/.agents/skills")"; fi
assert_contains "${INSTALL_OUT}" "agents: --with-deps adds" "--with-deps reports what it adds"
assert_not_contains "${INSTALL_OUT}" "is referenced by" "--with-deps leaves no dependency warning"
home="$(new_home)"
reject "remove --with-deps exits nonzero" "${home}" remove --target agents --intent skills --skills code-review --with-deps
assert_contains "${REJECT_OUT}" "--with-deps is only valid with install or sync" "remove --with-deps is rejected"
reject "--with-deps without a selection exits nonzero" "${home}" sync --target agents --intent skills --with-deps
assert_contains "${REJECT_OUT}" "--with-deps needs --skills" "--with-deps without --skills is rejected"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
