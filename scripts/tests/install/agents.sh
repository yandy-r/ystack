#!/usr/bin/env bash
# install.sh tests — agents: ~/.agents/skills install/remove, foreign entries
# survive, plugins/ untouched, duplicate hint, --skills-home choice.
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
echo "== install.sh install: agents duplicate hint =="

home="$(new_home)"
mkdir -p "${home}/.config/opencode/skills/backport"
install_must_succeed "${home}" install --target agents
out="${INSTALL_OUT}"
assert_contains "${out}" "may list them twice" "agents install warns when opencode native skills already hold ycc entries"
assert_not_contains "${out}" "OMP also loads these skills" "agents install prints no OMP hint when omp ycc is not installed"

echo
echo "== install.sh install: agents after omp prints the OMP dedupe hint (W5) =="

home="$(new_home)"
install_must_succeed "${home}" install --target omp --only base
install_must_succeed "${home}" install --target agents
assert_contains "${INSTALL_OUT}" "[!!] OMP also loads these skills; run ./install.sh install --target omp --only dedupe to hide the ~/.agents copies in OMP" "agents after omp prints W5"

echo
echo "== install.sh: --skills-home agents consolidates shared skills =="

home="$(new_home)"
install_must_succeed "${home}" install --target opencode --only base --skills-home agents
if [[ -f "${home}/.agents/skills/backport/SKILL.md" ]]; then ok "consolidated: skills land in ~/.agents/skills"; else ko "consolidated: skills land in ~/.agents/skills"; fi
if [[ ! -d "${home}/.config/opencode/skills" ]]; then ok "consolidated: no skills under ~/.config/opencode"; else ko "consolidated: no skills under ~/.config/opencode"; fi
if [[ ! -d "${home}/.config/opencode/shared" ]]; then ok "consolidated: no shared/ under ~/.config/opencode"; else ko "consolidated: no shared/ under ~/.config/opencode"; fi
if [[ -d "${home}/.config/opencode/agents" && -d "${home}/.config/opencode/commands" ]]; then
    ok "consolidated: opencode keeps its agents + commands"
else
    ko "consolidated: opencode keeps its agents + commands" "$(ls "${home}/.config/opencode" 2>/dev/null)"
fi

echo
echo "== install.sh: --skills-home native keeps per-tool skills =="

home="$(new_home)"
install_must_succeed "${home}" install --target opencode --only base --skills-home native
out="${INSTALL_OUT}"
if [[ -d "${home}/.config/opencode/skills" ]]; then ok "native: opencode skills land in ~/.config/opencode/skills"; else ko "native: opencode skills land in ~/.config/opencode/skills"; fi
if [[ ! -e "${home}/.agents/skills" ]]; then ok "native: nothing under ~/.agents/skills"; else ko "native: nothing under ~/.agents/skills"; fi
assert_not_contains "${out}" "Recommended:" "native: no consolidation prompt text"

echo
echo "== install.sh: non-TTY overlap warning =="

home="$(new_home)"
install_must_succeed "${home}" install --target agents,opencode --only base
out="${INSTALL_OUT}"
assert_contains "${out}" "opencode will duplicate the ycc skills in ~/.agents/skills" "non-TTY overlap warning names opencode"
assert_contains "${out}" "pass --skills-home agents to consolidate" "non-TTY overlap warning suggests --skills-home agents"

echo
echo "== install.sh: native-package targets stay out of the overlap check =="

home="$(new_home)"
install_must_succeed "${home}" install --target agents,cursor,codex --only base
assert_not_contains "${INSTALL_OUT}" "duplicate" "native-package targets ship no skill copies to overlap"

echo
echo "== contract: every target declares ~/.agents/skills readership =="

(
    source_install_libs
    for t in "${ALL_TARGETS[@]}"; do
        declare -F "${t}_reads_agents_skills" >/dev/null || { echo "missing ${t}_reads_agents_skills"; continue; }
        if [[ "${t}" != agents ]] && "${t}_reads_agents_skills"; then
            declare -F "${t}_native_skills_dirs" >/dev/null || echo "missing ${t}_native_skills_dirs"
        fi
    done
) > "${SANDBOX_ROOT}/contract.out" 2>&1
contract="$(cat "${SANDBOX_ROOT}/contract.out")"
if [[ -z "${contract}" ]]; then ok "every target declares reads_agents_skills (+ native_skills_dirs)"; else ko "every target declares reads_agents_skills (+ native_skills_dirs)" "${contract}"; fi

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
