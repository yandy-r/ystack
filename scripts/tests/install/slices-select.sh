#!/usr/bin/env bash
# install.sh tests — --skills / --agents / --commands selection of the
# standalone opencode and agents slices: narrowing (never pruning), helpers
# ride along, 'base' stays whole, preflight errors, --skills-home agents,
# paired-skill warnings, remove, --with-deps. Native-package targets (claude,
# codex, cursor, omp) take no selection (select.sh covers that rejection).
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

echo "== install.sh list skills / agents =="

home="$(new_home)"
install_must_succeed "${home}" list skills --target opencode
assert_contains "${INSTALL_OUT}" "go-patterns" "list skills names opencode skills"
install_must_succeed "${home}" list skills --target opencode,agents
assert_not_contains "${INSTALL_OUT}" "ycc-shared" "list skills hides ycc-shared"
assert_not_contains "${INSTALL_OUT}" "_shared" "list skills hides the _shared helper"
install_must_succeed "${home}" list agents --target opencode
assert_contains "${INSTALL_OUT}" $'\nimplementor\n' "list agents prints stems"
assert_not_contains "${INSTALL_OUT}" ".md" "list agents drops the .md suffix"
install_must_succeed "${home}" list agents --target agents
if [[ -z "${INSTALL_OUT}" ]]; then ok "agents target lists no agents"; else ko "agents target lists no agents" "${INSTALL_OUT}"; fi

echo
echo "== install.sh --skills: opencode and agents =="

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent skills --skills go-patterns,rust-testing --skills-home native
assert_contains "${INSTALL_OUT}" "Skills: go-patterns, rust-testing" "opencode reports the selected skills"
assert_entries "${home}/.config/opencode/skills" "go-patterns rust-testing" "opencode installs only the selected skills"
if [[ -d "${home}/.config/opencode/shared" ]]; then ok "opencode ships shared/ with a selected skill"; else ko "opencode ships shared/ with a selected skill"; fi

home="$(new_home)"
install_must_succeed "${home}" sync --target agents --intent skills --skills go-patterns
assert_entries "${home}/.agents/skills" "go-patterns" "agents target installs only the selected skill"
if [[ -d "${home}/.agents/ycc-shared" ]]; then ok "agents target ships ycc-shared with a selected skill"; else ko "agents target ships ycc-shared with a selected skill"; fi

echo
echo "== install.sh --agents: opencode =="

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent agents --agents implementor,code-reviewer
assert_contains "${INSTALL_OUT}" "Agents: implementor, code-reviewer" "agents selection is reported"
assert_entries "${home}/.config/opencode/agents" "code-reviewer.md implementor.md" "opencode installs exactly the selected agents"

home="$(new_home)"
install_must_succeed "${home}" sync --target all --intent agents --agents implementor
assert_contains "${INSTALL_OUT}" "agents target ran no steps" "--target all: the agents target reports a no-op"
assert_contains "${INSTALL_OUT}" "--agents: native-package targets" "--target all: native targets skip --agents with a notice"
if [[ ! -e "${home}/.agents/skills" ]]; then ok "--target all --agents writes nothing to ~/.agents"; else ko "--target all --agents writes nothing to ~/.agents"; fi
assert_entries "${home}/.config/opencode/agents" "implementor.md" "--target all: opencode installs exactly implementor"
shipped="$(find "${REPO_ROOT}/.codex-plugin/agents" -maxdepth 1 -name '*.toml' | wc -l)"
got="$(find "${home}/.codex/agents" -maxdepth 1 -name '*.toml' 2>/dev/null | wc -l)"
if [[ "${got}" -eq "${shipped}" ]]; then ok "--target all: codex custom agents ship whole"; else ko "--target all: codex custom agents ship whole" "${got} of ${shipped}"; fi
if [[ ! -e "${home}/.claude/agents" && ! -e "${home}/.cursor/agents" ]]; then ok "--target all: no claude/cursor agents copy"; else ko "--target all: no claude/cursor agents copy"; fi

echo
echo "== install.sh --skills / --agents: preflight =="

home="$(new_home)"
reject "unknown skill exits nonzero" "${home}" sync --target opencode,agents --intent skills --skills go-patterns,no-such-skill --skills-home native
assert_contains "${REJECT_OUT}" "unknown skill 'no-such-skill'" "unknown skill rejected"
assert_contains "${REJECT_OUT}" "list them with: ycc list skills --target <targets>" "unknown skill points at ycc list skills"
if [[ ! -e "${home}/.config/opencode/skills" && ! -e "${home}/.agents/skills" && ! -e "${home}/.config/ycc/installed-units.json" ]]; then
    ok "unknown skill fails before any target writes"
else
    ko "unknown skill fails before any target writes"
fi

home="$(new_home)"
reject "unknown agent exits nonzero" "${home}" sync --target opencode --intent agents --agents implementor.md
assert_contains "${REJECT_OUT}" "unknown agent 'implementor.md'" "agents are selected by stem, not file name"

home="$(new_home)"
reject "--skills with base only exits nonzero" "${home}" sync --target opencode --intent base --skills go-patterns
assert_contains "${REJECT_OUT}" "--skills needs the skills step (it narrows the standalone skills slice; use --intent skills or --only skills)" "--skills with base only is rejected"
reject "agents base + --skills exits nonzero" "${home}" sync --target agents --intent base --skills go-patterns
assert_contains "${REJECT_OUT}" "--skills needs the skills step" "agents base is never filtered: --skills needs its skills step"
reject "--agents on the agents target alone exits nonzero" "${home}" sync --target agents --intent agents --agents implementor
assert_contains "${REJECT_OUT}" "--agents needs the agents step" "--agents on the agents target alone is rejected"

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

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent agents --agents implementor,code-reviewer
install_must_succeed "${home}" remove --target opencode --intent agents --agents implementor
assert_entries "${home}/.config/opencode/agents" "code-reviewer.md" "opencode selective agent remove takes only implementor"

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent skills --skills go-patterns,rust-testing --skills-home native
install_must_succeed "${home}" remove --target opencode --intent skills --skills go-patterns
assert_entries "${home}/.config/opencode/skills" "rust-testing" "opencode selective skill remove takes only the named skill"

echo
echo "== install.sh --skills-home agents: selection follows the skills =="

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent skills --skills go-patterns --skills-home agents
assert_entries "${home}/.agents/skills" "go-patterns" "consolidated skills install only the selection into ~/.agents/skills"
if [[ ! -e "${home}/.config/opencode/skills" ]]; then ok "consolidated selection installs no native skills"; else ko "consolidated selection installs no native skills"; fi

echo
echo "== install.sh --commands =="

home="$(new_home)"
for t in claude codex cursor; do
    install_must_succeed "${home}" list commands --target "${t}"
    if [[ -z "${INSTALL_OUT}" ]]; then ok "${t} lists no commands"; else ko "${t} lists no commands" "${INSTALL_OUT}"; fi
done
install_must_succeed "${home}" list commands --target opencode
assert_contains "${INSTALL_OUT}" $'\nclean\n' "list commands prints opencode command stems"
assert_not_contains "${INSTALL_OUT}" ".md" "list commands drops the .md suffix"

home="$(new_home)"
reject "unknown command exits nonzero" "${home}" sync --target opencode --intent commands --commands clean,no-such-command
assert_contains "${REJECT_OUT}" "unknown command 'no-such-command'" "unknown command rejected"

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent commands --commands clean,plan
assert_entries "${home}/.config/opencode/commands" "clean.md plan.md" "opencode --commands installs only the selected commands"
assert_contains "${INSTALL_OUT}" "opencode: command 'clean' needs skill 'clean', not installed" "opencode warns about the missing paired skill"
if [[ ! -e "${home}/.config/opencode/skills" ]]; then ok "the paired-skill warning installs nothing"; else ko "the paired-skill warning installs nothing"; fi
install_must_succeed "${home}" sync --target opencode --intent commands --commands go-patterns
assert_entries "${home}/.config/opencode/commands" "clean.md go-patterns.md plan.md" "a second --commands selection keeps the earlier ones"
install_must_succeed "${home}" remove --target opencode --intent commands --commands plan
assert_entries "${home}/.config/opencode/commands" "clean.md go-patterns.md" "opencode selective command remove takes only plan"

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent skills,commands --skills clean --commands clean --skills-home native
assert_not_contains "${INSTALL_OUT}" "needs skill" "a skill the same run installs counts as installed"
home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent skills --skills clean --skills-home native
install_must_succeed "${home}" sync --target opencode --intent commands --commands clean
assert_not_contains "${INSTALL_OUT}" "needs skill" "a standalone skill counts as installed"

echo
echo "== install.sh --skills: dependency warning =="

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent skills --skills clean --skills-home native
assert_contains "${INSTALL_OUT}" "is referenced by clean but not installed" "a missing ycc: dependency is reported"
assert_contains "${INSTALL_OUT}" "ycc sync --target opencode --intent" "the warning names the command that adds it"
home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent skills --skills go-patterns --skills-home native
assert_not_contains "${INSTALL_OUT}" "is referenced by" "a self-contained skill warns about nothing"

echo
echo "== install.sh --with-deps =="

home="$(new_home)"
install_must_succeed "${home}" sync --target opencode --intent skills,agents --skills code-review --agents implementor --with-deps --skills-home native
if [[ -d "${home}/.config/opencode/skills/code-review" && -d "${home}/.config/opencode/skills/review-fix" ]]; then ok "--with-deps installs the selected skill and its skill dependencies"; else ko "--with-deps installs the selected skill and its skill dependencies" "$(entries "${home}/.config/opencode/skills")"; fi
if [[ -f "${home}/.config/opencode/agents/code-reviewer.md" && -f "${home}/.config/opencode/agents/implementor.md" ]]; then ok "--with-deps installs the selected agent and the referenced agents"; else ko "--with-deps installs the selected agent and the referenced agents" "$(entries "${home}/.config/opencode/agents")"; fi
assert_contains "${INSTALL_OUT}" "opencode: --with-deps adds" "--with-deps reports what it adds"
assert_not_contains "${INSTALL_OUT}" "is referenced by" "--with-deps leaves no dependency warning"
home="$(new_home)"
reject "remove --with-deps exits nonzero" "${home}" remove --target opencode --intent skills --skills code-review --with-deps
assert_contains "${REJECT_OUT}" "--with-deps is only valid with install or sync" "remove --with-deps is rejected"
reject "--with-deps without a selection exits nonzero" "${home}" sync --target opencode --intent skills --with-deps
assert_contains "${REJECT_OUT}" "--with-deps needs --skills or --agents" "--with-deps without --skills / --agents is rejected"
reject "--with-deps with only --commands exits nonzero" "${home}" sync --target opencode --intent commands --commands clean --with-deps
assert_contains "${REJECT_OUT}" "--with-deps needs --skills or --agents" "--commands alone does not seed --with-deps"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
