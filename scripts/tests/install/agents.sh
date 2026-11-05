#!/usr/bin/env bash
# install.sh tests — agents: ~/.agents/skills install/remove, foreign entries
# survive, plugins/ untouched, OMP dedupe hint, opencode leaves ~/.agents alone.
#
# Runs alone (bash scripts/tests/install/agents.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== install.sh install: agents =="

home="$(new_home)"
install_must_succeed "${home}" install --target agents
assert_not_contains "$(cat "${home}/.agents/skills/releaser/SKILL.md")" 'disable-model-invocation' "agents install omits unsupported releaser invocation policy"
assert_not_contains "$(cat "${home}/.agents/skills/init/SKILL.md")" 'disable-model-invocation' "agents install keeps init unrestricted"
assert_contains "$(cat "${home}/.agents/skills/releaser/SKILL.md")" 'Prepares external-project releases' "agents install keeps releaser description"
skill_count="$(find "${home}/.agents/skills" -mindepth 1 -maxdepth 1 -type d | wc -l)"
bundle_count="$(find "${REPO_ROOT}/.agents-plugin/skills" -mindepth 1 -maxdepth 1 -type d | wc -l)"
if [[ -f "${home}/.agents/skills/backport/SKILL.md" && "${skill_count}" -eq "${bundle_count}" ]]; then
    ok "agents install puts ycc skills into ~/.agents/skills"
else
    ko "agents install puts ycc skills into ~/.agents/skills" "${skill_count} skills, expected ${bundle_count}"
fi
if [[ -d "${home}/.agents/ycc-shared/references" && -d "${home}/.agents/ycc-shared/scripts" ]]; then
    ok "agents install puts shared helpers into ~/.agents/ycc-shared"
else
    ko "agents install puts shared helpers into ~/.agents/ycc-shared"
fi

echo
echo "== install.sh remove: agents keeps foreign entries =="

mkdir -p "${home}/.agents/skills/my-own"
printf 'mine\n' > "${home}/.agents/skills/my-own/SKILL.md"
mkdir -p "${home}/.agents/plugins/ycc"
printf 'foreign\n' > "${home}/.agents/plugins/ycc/plugin.json"
install_must_succeed "${home}" remove --target agents --only skills
if [[ ! -d "${home}/.agents/skills/backport" ]]; then ok "agents remove drops ycc skills"; else ko "agents remove drops ycc skills" "$(ls "${home}/.agents/skills")"; fi
if [[ ! -d "${home}/.agents/ycc-shared" ]]; then ok "agents remove drops ycc-shared"; else ko "agents remove drops ycc-shared"; fi
if [[ -f "${home}/.agents/skills/my-own/SKILL.md" ]]; then ok "agents remove keeps foreign skill my-own"; else ko "agents remove keeps foreign skill my-own"; fi
if [[ -f "${home}/.agents/plugins/ycc/plugin.json" ]]; then ok "agents remove leaves ~/.agents/plugins untouched"; else ko "agents remove leaves ~/.agents/plugins untouched"; fi

echo
echo "== install.sh install: agents prints no stale duplicate hint =="

home="$(new_home)"
mkdir -p "${home}/.config/opencode/skills/backport"
install_must_succeed "${home}" install --target agents
out="${INSTALL_OUT}"
assert_not_contains "${out}" "may list them twice" "agents install no longer warns about opencode native skills"
assert_not_contains "${out}" "OMP also loads these skills" "agents install prints no OMP hint when omp ycc is not installed"

echo
echo "== install.sh install: agents after omp prints the OMP dedupe hint (W5) =="

home="$(new_home)"
install_must_succeed "${home}" install --target omp --only base
install_must_succeed "${home}" install --target agents
assert_contains "${INSTALL_OUT}" "[!!] OMP also loads these skills; run ./install.sh install --target omp --only dedupe to hide the ~/.agents copies in OMP" "agents after omp prints W5"

echo
echo "== install.sh: agents and opencode no longer overlap =="

home="$(new_home)"
install_must_succeed "${home}" install --target agents,opencode --only base
out="${INSTALL_OUT}"
assert_not_contains "${out}" "duplicate" "agents + opencode prints no overlap warning"
assert_not_contains "${out}" "--skills-home" "no --skills-home suggestion"
if [[ -f "${home}/.agents/skills/backport/SKILL.md" ]]; then ok "agents skills still land in ~/.agents/skills"; else ko "agents skills still land in ~/.agents/skills"; fi
if [[ ! -e "${home}/.config/opencode/skills" ]]; then ok "opencode copies no skills"; else ko "opencode copies no skills"; fi

home="$(new_home)"
out="$(run_install "${home}" install --target opencode --only base --skills-home agents)"
assert_contains "${out}" "Unknown option: --skills-home" "--skills-home is gone"

echo
echo "== harness: installer failures surface with their own diagnostic =="

# Regression for the masked-setup-error class: an installer that dies early
# (e.g. missing lockfile-pinned prettier) must surface its own exit status and
# diagnostic instead of letting placement assertions report misleading results.
# A stub installer exits 42; checked_failure_probe drives it through
# install_must_succeed in a child bash so the abort cannot touch this suite.
home="$(new_home)"
stub_install="${home}/fail-install.sh"
cat > "${stub_install}" <<'SH'
#!/usr/bin/env bash
echo "synthetic installer failure: missing lockfile-pinned prettier" >&2
exit 42
SH
chmod +x "${stub_install}"

assert_checked_failure() {
    local label="$1" skip_build="$2" probe
    shift 2
    probe="$(checked_failure_probe "${stub_install}" "${home}" "${skip_build}" "$@")"
    assert_contains "${probe}" "synthetic installer failure: missing lockfile-pinned prettier" "${label}: surfaces the original installer diagnostic"
    assert_contains "${probe}" "install.sh $* exited 42" "${label}: names the invocation and exit status"
    assert_contains "${probe}" "PROBE_RC=42" "${label}: preserves the installer exit status"
    assert_not_contains "${probe}" "PLACEMENT_BLOCK_RAN" "${label}: stops before placement assertions"
}

assert_checked_failure "agents install" 1 install --target agents
assert_checked_failure "claude sync (non-agents suite path)" 1 sync --target claude --intent settings
assert_checked_failure "codex remove (non-agents suite path)" 1 remove --target codex --intent base
assert_checked_failure "cursor base build (build.sh path)" 0 install --target cursor --only base

if [[ ! -e "${home}/.agents/skills" ]]; then ok "failed setup left no placement"; else ko "failed setup left no placement"; fi

# The checked success path stays quiet and still installs.
probe="$(
    bash -c '
        source "$1/scripts/tests/install/lib.sh"
        trap '\''rm -rf "${SANDBOX_ROOT}"'\'' EXIT
        install_must_succeed "$2" install --target agents
        echo "OUT_BYTES=${#INSTALL_OUT}"
    ' _ "${REPO_ROOT}" "${home}" 2>&1
)"
assert_contains "${probe}" "OUT_BYTES=" "checked success path returns to the caller"
assert_not_contains "${probe}" "[FAIL]" "checked success path reports no failure"
if [[ -f "${home}/.agents/skills/backport/SKILL.md" ]]; then ok "checked success path installs"; else ko "checked success path installs"; fi

# Expected-negative cases stay on the unchecked primitive: a rejecting run keeps
# its status and message, and the suite continues past it.
out="$(run_install "${home}" install --target claude --only bogus)"; rc=$?
if [[ ${rc} -ne 0 ]]; then ok "expected rejection keeps its nonzero status"; else ko "expected rejection keeps its nonzero status"; fi
assert_contains "${out}" "is not valid for target" "expected rejection keeps its message"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
