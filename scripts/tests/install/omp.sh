#!/usr/bin/env bash
# install.sh tests — omp: native install/re-run/remove through scripts/omp_install.py
# against the stateful fake omp (fake_omp.py), user and project scope, dry-run,
# package and mode gates, --target all skip, version preflight and intents.
#
# Runs alone (bash scripts/tests/install/omp.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# omp_state <home> — the helper's ownership state file.
omp_state() { printf '%s/.config/ycc/omp-native-install.json' "$1"; }
# omp_export <home> — the helper's local marketplace export.
omp_export() { printf '%s/.local/share/ycc/omp-marketplace' "$1"; }
# omp_log <home> — the shared stub call log (fake omp logs 'omp <args>').
omp_log() { cat "$1/claude-calls.log" 2>/dev/null || true; }
# omp_mutations <log text> — the mutating omp calls in a log excerpt.
omp_mutations() {
    grep -E '^omp plugin (marketplace (add|update|remove)|install|upgrade|uninstall|link)( |$)' <<< "$1" || true
}

echo "== install.sh install: omp user scope =="

home="$(new_home)"
install_must_succeed "${home}" install --target omp
out="${INSTALL_OUT}"
log="$(omp_log "${home}")"
assert_contains "${log}" "omp plugin install --scope user ycc@ycc" "omp install installs ycc@ycc at user scope"
assert_contains "${log}" "omp plugin marketplace add $(omp_export "${home}")" "omp install registers the local export marketplace"
assert_contains "${log}" "omp plugin install --scope user ycc-mcp@ycc" "omp install installs ycc-mcp@ycc at user scope"
assert_contains "${log}" "omp plugin install --scope user ycc-rules@ycc" "omp install installs ycc-rules@ycc at user scope by default"
assert_contains "${out}" "rules apply to new sessions (/new or restart)" "omp install says rules apply to new sessions"
assert_contains "$(cat "${home}/.fake-omp/plugins/installed_plugins.json" 2>/dev/null)" "ycc-rules@ycc" "fake omp registry holds ycc-rules@ycc"
if [[ -f "$(omp_export "${home}")/packages/omp/ycc-rules/.omp-plugin/plugin.json" ]]; then
    ok "omp export ships the ycc-rules package"
else
    ko "omp export ships the ycc-rules package"
fi
assert_contains "${out}" "restart running omp sessions: ycc ship hooks or extensions" "omp install tells running sessions to restart for the ycc scope guard"
assert_contains "${out}" " installed (user)" "omp install reports the installed package"
assert_contains "${out}" "OMP has no trust prompt" "omp install warns that OMP has no trust prompt"
assert_contains "${out}" "omp install complete." "omp install completes"
assert_contains "$(cat "$(omp_state "${home}")" 2>/dev/null)" '"package": "ycc"' "omp install records the ycc-owned install"
assert_contains "$(cat "${home}/.fake-omp/plugins/installed_plugins.json" 2>/dev/null)" "ycc@ycc" "fake omp registry holds ycc@ycc"
if [[ -f "$(omp_export "${home}")/packages/omp/ycc/.omp-plugin/plugin.json" ]]; then
    ok "omp install writes the local export"
else
    ko "omp install writes the local export" "$(find "$(omp_export "${home}")" -maxdepth 3 2>/dev/null | head -5)"
fi
omp_mcp_expected="$(cd "${REPO_ROOT}/scripts" && python3 -c 'import sys; from generate_omp_packages import omp_mcp_bytes; sys.stdout.buffer.write(omp_mcp_bytes(open("../mcp-configs/mcp.json", "rb").read()))')"
if [[ "$(cat "$(omp_export "${home}")/packages/omp/ycc-mcp/.mcp.json")" == "${omp_mcp_expected}" ]] \
    && grep -q '"url": "https://mcp.linear.app/mcp?ycc-server=linear-personal"' "$(omp_export "${home}")/packages/omp/ycc-mcp/.mcp.json"; then
    ok "omp export ships the OMP rendering of mcp-configs/mcp.json (linear-personal ?ycc-server=)"
else
    ko "omp export ships the OMP rendering of mcp-configs/mcp.json (linear-personal ?ycc-server=)"
fi

before="$(omp_log "${home}")"
install_must_succeed "${home}" install --target omp
after="$(omp_log "${home}")"
rerun_log="${after#"${before}"}"
assert_contains "${INSTALL_OUT}" " up to date (user)" "omp re-run reports up to date"
added="$(omp_mutations "${rerun_log}")"
if [[ -z "${added}" ]]; then ok "omp re-run makes no mutating omp calls"; else ko "omp re-run makes no mutating omp calls" "${added}"; fi
assert_not_contains "${INSTALL_OUT}" "exported OMP packages" "omp re-run keeps the unchanged export"

install_must_succeed "${home}" remove --target omp --only base
out="${INSTALL_OUT}"
log="$(omp_log "${home}")"
assert_contains "${log}" "omp plugin uninstall --scope user ycc@ycc" "omp remove uninstalls the user install"
assert_contains "${log}" "omp plugin uninstall --scope user ycc-mcp@ycc" "omp remove uninstalls the user ycc-mcp install"
assert_contains "${log}" "omp plugin uninstall --scope user ycc-rules@ycc" "omp remove uninstalls the user ycc-rules install"
assert_contains "${log}" "omp plugin marketplace remove ycc" "omp remove drops the ycc marketplace"
assert_contains "${out}" "[ok] removed $(omp_export "${home}")" "omp remove reports the export removal"
assert_not_contains "$(cat "${home}/.fake-omp/plugins/installed_plugins.json" 2>/dev/null)" "ycc@ycc" "omp remove empties the fake registry"
assert_not_contains "$(cat "${home}/.fake-omp/marketplaces.json" 2>/dev/null)" '"ycc"' "omp remove empties the fake marketplace registry"
if [[ ! -e "$(omp_export "${home}")" ]]; then ok "omp remove deletes the export"; else ko "omp remove deletes the export"; fi
if [[ ! -e "$(omp_state "${home}")" ]]; then ok "omp remove deletes the state file"; else ko "omp remove deletes the state file"; fi

echo
echo "== install.sh install: omp project scope =="

home="$(new_home)"
git -C "${home}/project" init -q
install_must_succeed "${home}" install --target omp --project
log="$(omp_log "${home}")"
assert_contains "${log}" "omp plugin install --scope project ycc@ycc" "omp --project installs at project scope"
assert_not_contains "${log}" "omp plugin install --scope user" "omp --project leaves user scope alone"
assert_contains "${INSTALL_OUT}" "a project install shadows your user install here" "omp --project explains the shadowing"
assert_contains "${log}" "omp plugin install --scope project ycc-mcp@ycc" "omp --project installs ycc-mcp at project scope"
registry="$(cat "${home}/project/.omp/plugins/installed_plugins.json" 2>/dev/null)"
assert_contains "${registry}" "ycc@ycc" "omp --project writes ycc to the fake project registry"
assert_contains "${registry}" "ycc-mcp@ycc" "omp --project writes ycc-mcp to the fake project registry"
assert_contains "${registry}" "ycc-rules@ycc" "omp --project writes ycc-rules to the fake project registry"
assert_contains "$(cat "$(omp_state "${home}")" 2>/dev/null)" '"scope": "project"' "omp --project records the project install"

install_must_succeed "${home}" remove --target omp --only base --project
log="$(omp_log "${home}")"
assert_contains "${log}" "omp plugin uninstall --scope project ycc@ycc" "omp remove --project uninstalls the project install"
assert_contains "${log}" "omp plugin marketplace remove ycc" "omp remove --project drops the ycc marketplace"
assert_not_contains "$(cat "${home}/project/.omp/plugins/installed_plugins.json" 2>/dev/null)" "ycc@ycc" "omp remove --project empties the project registry"
assert_contains "${log}" "omp plugin uninstall --scope project ycc-mcp@ycc" "omp remove --project uninstalls the project ycc-mcp install"
assert_contains "${log}" "omp plugin uninstall --scope project ycc-rules@ycc" "omp remove --project uninstalls the project ycc-rules install"
if [[ ! -e "$(omp_export "${home}")" && ! -e "$(omp_state "${home}")" ]]; then
    ok "omp remove --project deletes the export and state"
else
    ko "omp remove --project deletes the export and state"
fi

home="$(new_home)"
if out="$(run_install "${home}" install --target cursor --only base --project)"; then
    ko "--project still rejects cursor base"
else
    assert_contains "${out}" "project scope currently supports: mcp; claude: hooks; omp: base" "--project still rejects cursor base"
fi

echo
echo "== install.sh: --dry-run =="

home="$(new_home)"
install_must_succeed "${home}" install --target omp --dry-run
out="${INSTALL_OUT}"
assert_contains "${out}" "[dry-run] would export OMP packages" "omp dry-run previews the export"
assert_contains "${out}" "[dry-run] would run: omp plugin marketplace add" "omp dry-run previews the marketplace add"
assert_contains "${out}" "[dry-run] would run: omp plugin install --scope user ycc@ycc" "omp dry-run previews the install"
assert_contains "${out}" "dry-run: skipping the OMP package build" "omp dry-run skips the package build"
added="$(omp_mutations "$(omp_log "${home}")")"
if [[ -z "${added}" ]]; then ok "omp dry-run makes no mutating omp calls"; else ko "omp dry-run makes no mutating omp calls" "${added}"; fi
if [[ ! -e "$(omp_state "${home}")" && ! -e "$(omp_export "${home}")" && ! -e "${home}/.fake-omp/marketplaces.json" ]]; then
    ok "omp dry-run writes no state, export or marketplace registry"
else
    ko "omp dry-run writes no state, export or marketplace registry"
fi

# Other targets now dry-run too (dry-run.sh); omp still makes no omp call.
home="$(new_home)"
install_must_succeed "${home}" install --target codex --dry-run
assert_contains "${INSTALL_OUT}" "dry-run: codex base step has no preview" "--target codex --dry-run skips the codex base step"
assert_not_contains "$(omp_log "${home}")" "omp plugin" "--target codex --dry-run runs no omp plugin call"

echo
echo "== install.sh: omp package, mode and --target all gates =="

home="$(new_home)"
install_must_succeed "${home}" install --target omp --package ycc
assert_contains "$(omp_log "${home}")" "omp plugin install --scope user ycc@ycc" "omp --package ycc installs ycc@ycc"

home="$(new_home)"
install_must_succeed "${home}" install --target omp --package ycc-mcp
log="$(omp_log "${home}")"
assert_contains "${log}" "omp plugin install --scope user ycc-mcp@ycc" "omp --package ycc-mcp installs ycc-mcp@ycc"
assert_not_contains "${log}" "omp plugin install --scope user ycc@ycc" "omp --package ycc-mcp leaves ycc alone"
install_must_succeed "${home}" remove --target omp --only base
assert_contains "$(omp_log "${home}")" "omp plugin uninstall --scope user ycc-mcp@ycc" "omp remove uninstalls the ycc-mcp-only install"

home="$(new_home)"
if out="$(run_install "${home}" install --target omp --package ycc-hooks)"; then
    ko "omp --package ycc-hooks rejected as excluded"
else
    assert_contains "${out}" "package 'ycc-hooks' is excluded or opt-in for target 'omp'" "omp --package ycc-hooks rejected as excluded"
fi
assert_not_contains "$(omp_log "${home}")" "omp plugin install" "excluded package installs nothing"

# --mode repo registers the upstream repository catalog (listed since YAN-1180). The fake
# omp "clones" any git source from FAKE_OMP_REPO_CATALOG: a copy of this checkout's catalog
# and packages, so a missing or unlisted root catalog fails the clone.
home="$(new_home)"
repo_catalog="${home}/repo-catalog"
mkdir -p "${repo_catalog}/packages"
cp -R "${REPO_ROOT}/.omp-plugin" "${repo_catalog}/"
cp -R "${REPO_ROOT}/packages/omp" "${repo_catalog}/packages/"
FAKE_OMP_REPO_CATALOG="${repo_catalog}" install_must_succeed "${home}" install --target omp --mode repo
log="$(omp_log "${home}")"
assert_contains "${log}" "omp plugin marketplace add https://github.com/yandy-r/ystack.git" "--mode repo registers the repository catalog"
for package in ycc ycc-mcp ycc-rules; do
    assert_contains "${log}" "omp plugin install --scope user ${package}@ycc" "--mode repo installs ${package}@ycc from the repository catalog"
done
if [[ ! -e "$(omp_export "${home}")" ]]; then
    ok "--mode repo writes no local export"
else
    ko "--mode repo writes no local export"
fi
if out="$(run_install "${home}" install --target omp)"; then
    ko "--mode local after --mode repo refuses the other ycc marketplace"
else
    assert_contains "${out}" "marketplace ycc has a different source (https://github.com/yandy-r/ystack.git)" "--mode local after --mode repo refuses the other ycc marketplace"
fi

home="$(new_home)"
install_must_succeed "${home}" sync --target all --intent plugins
assert_not_contains "${INSTALL_OUT}" "--target all: skipping omp" "--target all includes omp once its packages are listed"
assert_contains "${INSTALL_OUT}" "omp sync complete" "--target all runs the omp target"
assert_contains "$(omp_log "${home}")" "omp plugin install --scope user ycc@ycc" "--target all installs ycc@ycc into omp"

home="$(new_home)"
FAKE_OMP_VERSION=18.12.1 install_must_succeed "${home}" sync --target all --intent mcp
assert_contains "${INSTALL_OUT}" "--target all: skipping omp (needs omp >= 18.12.2 on PATH" "--target all skips omp below the version floor"
assert_not_contains "$(omp_log "${home}")" "omp plugin" "--target all with an old omp makes no omp plugin call"

echo
echo "== install.sh: omp version preflight =="

home="$(new_home)"
if out="$(FAKE_OMP_VERSION=18.12.1 run_install "${home}" install --target claude,omp --only base)"; then
    ko "old omp fails --target claude,omp"
else
    assert_contains "${out}" "omp >= 18.12.2 is required for --target omp" "old omp fails --target claude,omp"
    assert_contains "${out}" "omp 18.12.1 is older than 18.12.2" "old omp preflight names the version"
fi
assert_not_contains "${out}" "Claude sync complete" "omp preflight fails before claude runs"
log="$(omp_log "${home}")"
assert_not_contains "${log}" "plugin marketplace add" "omp preflight runs before any claude plugin call"
assert_not_contains "${log}" "omp plugin" "omp preflight makes no omp plugin call"

echo
echo "== install.sh sync: omp intents =="

home="$(new_home)"
install_must_succeed "${home}" sync --target omp --intent plugins
assert_contains "$(omp_log "${home}")" "omp plugin install --scope user ycc@ycc" "omp plugins intent maps to base"

echo
echo "== install.sh: omp settings and rules (user scope) =="

# omp_agent <home> — the fake omp agent dir ('omp config path').
omp_agent() { printf '%s/.fake-omp/agent' "$1"; }
omp_rules_src="${REPO_ROOT}/ycc/settings/rules/AGENTS.md"

# Dry-run previews settings and rules without 'omp config path' (it writes).
home="$(new_home)"
PI_CODING_AGENT_DIR="${home}/pi-agent" install_must_succeed "${home}" install --target omp --only settings,rules --dry-run
assert_contains "${INSTALL_OUT}" "would set /tools/approvalMode" "omp settings dry-run previews the merge"
assert_contains "${INSTALL_OUT}" "[dry-run] would link ${home}/pi-agent/AGENTS.md" "omp rules dry-run previews the link in the assumed agent dir"
assert_contains "${INSTALL_OUT}" "assuming the default omp agent dir" "omp dry-run labels the assumed agent dir"
assert_not_contains "$(omp_log "${home}")" "omp config path" "omp settings/rules dry-run never runs omp config path"
if [[ ! -e "${home}/pi-agent" && ! -e "$(omp_agent "${home}")" && ! -e "${home}/.config/ycc/managed-config-state.json" ]]; then
    ok "omp settings/rules dry-run writes nothing"
else
    ko "omp settings/rules dry-run writes nothing"
fi

# I1: --settings merges the managed leaves without any omp plugin call.
home="$(new_home)"
install_must_succeed "${home}" sync --target omp --intent settings
config="$(cat "$(omp_agent "${home}")/config.yml" 2>/dev/null)"
assert_contains "${config}" "approvalMode: write" "omp --settings writes tools.approvalMode"
for role in default slow task; do
    assert_contains "${config}" "  ${role}: " "omp --settings writes modelRoles.${role}"
    assert_contains "${config}" "    ${role}:
    - openai/gpt-5.6-sol" "omp --settings writes retry.fallbackChains.${role}"
done
assert_not_contains "${config}" "- openai/gpt-5.6-sol:" "omp --settings writes bare chain entries (the turn's thinking level carries over)"
assert_contains "${INSTALL_OUT}" "applied 7 managed update(s)" "omp --settings reports the merged leaves"
assert_not_contains "$(omp_log "${home}")" "omp plugin" "omp --settings makes no omp plugin call"

# I2: a user edit to a managed leaf survives a re-run.
agent="$(omp_agent "${home}")"
python3 - "${agent}/config.yml" <<'PY'
import sys, yaml
path = sys.argv[1]
data = yaml.safe_load(open(path, encoding="utf-8"))
data["modelRoles"]["slow"] = "openai/gpt-5.6-sol:low"
open(path, "w", encoding="utf-8").write(yaml.safe_dump(data, sort_keys=False))
PY
install_must_succeed "${home}" install --target omp --only settings
assert_contains "${INSTALL_OUT}" "kept your local value at /modelRoles/slow" "omp --settings re-run reports the kept edit"
assert_contains "$(cat "${agent}/config.yml")" "slow: openai/gpt-5.6-sol:low" "omp --settings re-run keeps the user edit"

# I3: --rules links AGENTS.md; a real file is refused and left unchanged.
install_must_succeed "${home}" install --target omp --only rules
if [[ -L "${agent}/AGENTS.md" && "$(readlink "${agent}/AGENTS.md")" == "${omp_rules_src}" ]]; then
    ok "omp --rules links AGENTS.md into the agent dir"
else
    ko "omp --rules links AGENTS.md into the agent dir"
fi
home2="$(new_home)"
mkdir -p "$(omp_agent "${home2}")"
printf 'mine\n' > "$(omp_agent "${home2}")/AGENTS.md"
if out="$(run_install "${home2}" install --target omp --only rules)"; then
    ko "omp --rules refuses a real AGENTS.md" "${out}"
else
    assert_contains "${out}" "refusing to replace user-authored rules file" "omp --rules refuses a real AGENTS.md"
fi
if [[ ! -L "$(omp_agent "${home2}")/AGENTS.md" && "$(cat "$(omp_agent "${home2}")/AGENTS.md")" == "mine" ]]; then
    ok "omp --rules leaves the real AGENTS.md unchanged"
else
    ko "omp --rules leaves the real AGENTS.md unchanged"
fi

# I4: --project with settings or rules is rejected before any write.
for flag in --settings --rules; do
    home2="$(new_home)"
    git -C "${home2}/project" init -q
    if out="$(run_install "${home2}" install --target omp --project "${flag}")"; then
        ko "omp --project ${flag} is rejected" "${out}"
    else
        assert_contains "${out}" "--project is not supported by step '${flag#--}' for target 'omp'" "omp --project ${flag} is rejected"
    fi
    if [[ ! -e "${home2}/project/.omp" && ! -e "$(omp_agent "${home2}")" ]]; then
        ok "omp --project ${flag} writes nothing"
    else
        ko "omp --project ${flag} writes nothing"
    fi
done

# Without PyYAML, the omp preflight fails with an install hint before any write.
home2="$(new_home)"
mkdir -p "${home2}/no-yaml"
printf 'raise ImportError("No module named yaml")\n' > "${home2}/no-yaml/yaml.py"
if out="$(PYTHONPATH="${home2}/no-yaml" run_install "${home2}" install --target omp --settings)"; then
    ko "omp without PyYAML fails" "${out}"
else
    assert_contains "${out}" "python3 -m pip install --user pyyaml" "omp without PyYAML names the install command"
    assert_not_contains "${out}" "Traceback" "omp without PyYAML prints no traceback"
fi
if [[ ! -e "$(omp_agent "${home2}")/config.yml" && -z "$(omp_log "${home2}")" ]]; then
    ok "omp without PyYAML writes nothing and makes no omp call"
else
    ko "omp without PyYAML writes nothing and makes no omp call"
fi

# --package never implies the opt-in settings or rules steps.
home2="$(new_home)"
install_must_succeed "${home2}" install --target omp --package ycc
if [[ ! -e "$(omp_agent "${home2}")/config.yml" && ! -e "$(omp_agent "${home2}")/AGENTS.md" ]]; then
    ok "omp --package ycc runs no settings or rules step"
else
    ko "omp --package ycc runs no settings or rules step"
fi

# I5: remove drops the unchanged leaves and the owned link, keeping the edit.
install_must_succeed "${home}" remove --target omp --intent settings,rules
config="$(cat "${agent}/config.yml" 2>/dev/null)"
assert_contains "${config}" "slow: openai/gpt-5.6-sol:low" "omp remove keeps the user-edited leaf"
assert_not_contains "${config}" "approvalMode" "omp remove drops the unchanged approvalMode leaf"
assert_not_contains "${config}" "default:" "omp remove drops the unchanged modelRoles.default leaf"
assert_not_contains "${config}" "fallbackChains" "omp remove drops the unchanged retry.fallbackChains leaves"
if [[ ! -e "${agent}/AGENTS.md" && ! -L "${agent}/AGENTS.md" ]]; then ok "omp remove unlinks AGENTS.md"; else ko "omp remove unlinks AGENTS.md"; fi
assert_not_contains "$(omp_log "${home}")" "omp plugin" "omp settings/rules remove makes no omp plugin call"

echo
echo "== install.sh: omp dedupe (YAN-1176) =="

w5="[!!] OMP also loads these skills; run ./install.sh install --target omp --only dedupe to hide the ~/.agents copies in OMP"

# agents then omp: the default dedupe step hides the ledger-owned ~/.agents copies.
home="$(new_home)"
install_must_succeed "${home}" install --target agents
agent="$(omp_agent "${home}")"
mkdir -p "${agent}"
printf 'skills:\n  ignoredSkills:\n  - my-*\n' > "${agent}/config.yml"
# --dry-run previews the merge and writes nothing. A dry-run never asks omp for
# its agent dir (it assumes ${PI_CODING_AGENT_DIR:-~/.omp/agent}), so point it
# at the fake agent dir. --only dedupe: the base step's helper keys its record
# by 'omp config path' even in a dry-run.
cp "${agent}/config.yml" "${home}/config.before"
state="${home}/.config/ycc/managed-config-state.json"
state_before="$(cat "${state}" 2>/dev/null || echo '<absent>')"
# The agents install above may already have logged omp calls; start clean.
: > "${home}/claude-calls.log"
PI_CODING_AGENT_DIR="${agent}" install_must_succeed "${home}" install --target omp --only dedupe --dry-run
assert_contains "${INSTALL_OUT}" "would set /skills/ignoredSkills" "omp dedupe dry-run previews the merge"
assert_contains "${INSTALL_OUT}" "[dry-run] OMP: would hide" "omp dedupe dry-run reports the planned hide"
if cmp -s "${home}/config.before" "${agent}/config.yml"; then ok "omp dedupe dry-run leaves config.yml unchanged"; else ko "omp dedupe dry-run leaves config.yml unchanged" "$(cat "${agent}/config.yml")"; fi
if [[ "$(cat "${state}" 2>/dev/null || echo '<absent>')" == "${state_before}" ]]; then ok "omp dedupe dry-run leaves the managed-config state unchanged"; else ko "omp dedupe dry-run leaves the managed-config state unchanged"; fi
assert_not_contains "$(omp_log "${home}")" "omp config path" "omp dedupe dry-run never runs omp config path"
install_must_succeed "${home}" install --target omp
config="$(cat "${agent}/config.yml")"
assert_contains "${config}" "agents/backport" "omp dedupe hides agents/backport"
assert_contains "${config}" "my-*" "omp dedupe keeps the user's ignoredSkills item"
hidden="$(grep -c '^  - agents/' "${agent}/config.yml")"
assert_contains "${INSTALL_OUT}" "[ok] OMP: hid ${hidden} ycc duplicate skills (agents/…) via skills.ignoredSkills in ${agent}/config.yml; ./install.sh remove --target omp --only dedupe restores them" "omp dedupe prints W1"
# The agents target after omp: hidden already, so no W5.
install_must_succeed "${home}" install --target agents
assert_not_contains "${INSTALL_OUT}" "${w5}" "agents after a deduped omp prints no W5"
# remove --only dedupe takes back only ycc's entries.
install_must_succeed "${home}" remove --target omp --only dedupe
config="$(cat "${agent}/config.yml")"
assert_not_contains "${config}" "agents/" "omp remove --only dedupe takes back the entries"
assert_contains "${config}" "my-*" "omp remove --only dedupe keeps the user item"
# W5: agents after omp while the copies are not hidden.
install_must_succeed "${home}" install --target agents
assert_contains "${INSTALL_OUT}" "${w5}" "agents after omp prints W5"
# remove --only base (the last install) takes the entries back too.
install_must_succeed "${home}" install --target omp --only dedupe
assert_contains "$(cat "${agent}/config.yml")" "agents/backport" "omp --only dedupe hides again"
# Remove dry-runs preview the take-back and leave config.yml as it is.
cp "${agent}/config.yml" "${home}/config.before"
for only in dedupe base; do
    PI_CODING_AGENT_DIR="${agent}" install_must_succeed "${home}" remove --target omp --only "${only}" --dry-run
    assert_contains "${INSTALL_OUT}" "would remove /skills/ignoredSkills" "omp remove --only ${only} dry-run previews the take-back"
    if cmp -s "${home}/config.before" "${agent}/config.yml"; then ok "omp remove --only ${only} dry-run leaves config.yml unchanged"; else ko "omp remove --only ${only} dry-run leaves config.yml unchanged" "$(cat "${agent}/config.yml")"; fi
done
install_must_succeed "${home}" remove --target omp --only base
if [[ "$(cat "${agent}/config.yml")" == "$(printf 'skills:\n  ignoredSkills:\n  - my-*')" ]]; then ok "omp remove --only base restores config.yml"; else ko "omp remove --only base restores config.yml" "$(cat "${agent}/config.yml")"; fi

# --only base skips dedupe and prints W2 instead; no config is written.
home="$(new_home)"
install_must_succeed "${home}" install --target agents
install_must_succeed "${home}" install --target omp --only base
assert_contains "${INSTALL_OUT}" "ycc skills from ~/.agents/skills as agents/<name>; run ./install.sh install --target omp --only dedupe to hide them in OMP" "omp --only base prints W2"
if [[ ! -e "$(omp_agent "${home}")/config.yml" ]]; then ok "omp --only base writes no config.yml"; else ko "omp --only base writes no config.yml"; fi

# --target omp,agents in one run: agents runs first, so dedupe hides its copies.
home="$(new_home)"
install_must_succeed "${home}" install --target omp,agents
assert_contains "$(cat "$(omp_agent "${home}")/config.yml" 2>/dev/null)" "agents/backport" "omp,agents in one run hides this run's ~/.agents copies"
assert_not_contains "${INSTALL_OUT}" "${w5}" "omp,agents in one run prints no W5"

# --package ycc runs dedupe like the default install.
home="$(new_home)"
install_must_succeed "${home}" install --target agents
install_must_succeed "${home}" install --target omp --package ycc
assert_contains "$(cat "$(omp_agent "${home}")/config.yml" 2>/dev/null)" "agents/backport" "omp --package ycc runs dedupe"
assert_contains "${INSTALL_OUT}" "[ok] OMP: hid" "omp --package ycc prints W1"

# A re-run takes back the aliases whose ycc copies are gone; the user item stays.
home="$(new_home)"
install_must_succeed "${home}" install --target agents
agent="$(omp_agent "${home}")"
mkdir -p "${agent}"
printf 'skills:\n  ignoredSkills:\n  - my-*\n' > "${agent}/config.yml"
install_must_succeed "${home}" install --target omp
assert_contains "$(cat "${agent}/config.yml")" "agents/backport" "omp dedupe hides before the agents removal"
install_must_succeed "${home}" remove --target agents --only skills
install_must_succeed "${home}" install --target omp --only dedupe
if [[ "$(cat "${agent}/config.yml")" == "$(printf 'skills:\n  ignoredSkills:\n  - my-*')" ]]; then ok "omp dedupe re-run takes back the aliases of removed ycc copies"; else ko "omp dedupe re-run takes back the aliases of removed ycc copies" "$(cat "${agent}/config.yml")"; fi

# A symlinked config.yml ycc never wrote does not fail the removal.
home="$(new_home)"
install_must_succeed "${home}" install --target omp --only base
agent="$(omp_agent "${home}")"
mkdir -p "${agent}"
printf 'theme: dark\n' > "${home}/dotfiles-config.yml"
ln -s "${home}/dotfiles-config.yml" "${agent}/config.yml"
install_must_succeed "${home}" remove --target omp --only base
if [[ -L "${agent}/config.yml" && "$(cat "${home}/dotfiles-config.yml")" == "theme: dark" ]]; then ok "omp remove leaves a symlinked config.yml it never wrote"; else ko "omp remove leaves a symlinked config.yml it never wrote"; fi
assert_not_contains "$(cat "$(omp_state "${home}")" 2>/dev/null)" '"package": "ycc"' "omp remove with a symlinked config.yml still removes the install"

# A refused config.yml (ycc entries present, then symlinked) stops the removal
# before any package is uninstalled.
home="$(new_home)"
install_must_succeed "${home}" install --target agents
install_must_succeed "${home}" install --target omp
agent="$(omp_agent "${home}")"
mv "${agent}/config.yml" "${home}/dotfiles-config.yml"
ln -s "${home}/dotfiles-config.yml" "${agent}/config.yml"
if run_install "${home}" remove --target omp --only base >/dev/null 2>&1; then ko "omp remove refuses a symlinked config.yml holding ycc entries"; else ok "omp remove refuses a symlinked config.yml holding ycc entries"; fi
assert_contains "$(cat "$(omp_state "${home}")" 2>/dev/null)" '"package": "ycc"' "omp remove refusal leaves the packages installed"

# --project: dedupe writes the user config; removing the project install while
# the user install remains keeps the entries; then the project residue is gone.
home="$(new_home)"
git -C "${home}/project" init -q
install_must_succeed "${home}" install --target agents
install_must_succeed "${home}" install --target omp
install_must_succeed "${home}" install --target omp --project
assert_contains "$(cat "$(omp_agent "${home}")/config.yml")" "agents/backport" "omp --project dedupe writes the user config.yml"
install_must_succeed "${home}" remove --target omp --only base --project
assert_contains "$(cat "$(omp_agent "${home}")/config.yml")" "agents/backport" "omp remove --project keeps entries the user install needs"
if [[ ! -e "${home}/project/.omp" ]]; then ok "omp remove --project deletes the empty .omp residue"; else ko "omp remove --project deletes the empty .omp residue" "$(find "${home}/project/.omp")"; fi
install_must_succeed "${home}" remove --target omp --only base
if [[ ! -e "$(omp_agent "${home}")/config.yml" ]]; then ok "omp remove of the last install deletes the ycc-only config.yml"; else ko "omp remove of the last install deletes the ycc-only config.yml" "$(cat "$(omp_agent "${home}")/config.yml")"; fi

# remove --intent base --project follows the same last-install rule as --only base.
home="$(new_home)"
git -C "${home}/project" init -q
install_must_succeed "${home}" install --target agents
install_must_succeed "${home}" install --target omp
install_must_succeed "${home}" install --target omp --project
install_must_succeed "${home}" remove --target omp --intent base --project
assert_contains "$(cat "$(omp_agent "${home}")/config.yml")" "agents/backport" "omp remove --intent base --project keeps entries the user install needs"
assert_contains "${INSTALL_OUT}" "omp: kept the skills.ignoredSkills entries" "omp remove --intent base --project says it kept the entries"
install_must_succeed "${home}" remove --target omp --intent plugins
if [[ ! -e "$(omp_agent "${home}")/config.yml" ]]; then ok "omp remove --intent plugins of the last install takes the entries back"; else ko "omp remove --intent plugins of the last install takes the entries back" "$(cat "$(omp_agent "${home}")/config.yml")"; fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
