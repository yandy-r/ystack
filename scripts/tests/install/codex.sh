#!/usr/bin/env bash
# install.sh tests — codex: config merge, native base/mcp through a stub Codex CLI,
# automatic legacy cleanup, custom agents, rules and --plugins.
#
# Runs alone (bash scripts/tests/install/codex.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== install.sh sync: codex config merge =="

home="$(new_home)"
cat > "${home}/.codex/config.toml" <<'TOML'
# local machine notes
model = "gpt-5.6-sol"

[projects."/home/me/secret-project"]
trust_level = "trusted"

[mcp_servers.internal]
url = "https://internal.example"
TOML
install_must_succeed "${home}" sync --target codex --intent settings --force --global
out="${INSTALL_OUT}"
merged="$(cat "${home}/.codex/config.toml")"
assert_contains "${merged}" "# local machine notes" "TOML comment preserved"
assert_contains "${merged}" '[projects."/home/me/secret-project"]' "trusted project preserved"
assert_contains "${merged}" "[mcp_servers.internal]" "local MCP server preserved"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "codex plugin" "codex settings runs no plugin CLI"
assert_contains "${merged}" 'model = "gpt-6-astra"' "managed model applied"
assert_contains "${merged}" 'default_subagent_model = "gpt-5.6-sol"' "subagent model applied"

if python3 -c "import tomllib,sys,pathlib; tomllib.loads(pathlib.Path(sys.argv[1]).read_text())" "${home}/.codex/config.toml"; then
    ok "merged config.toml still parses"
else
    ko "merged config.toml still parses"
fi

echo

echo "== install.sh sync: codex project scope (default) =="

# T8: the default scope merges the allowlisted settings into
# <project>/.codex/config.toml; posture, provider and plugin keys never land.
home="$(new_home)"
mkdir -p "${home}/project/.codex"
cat > "${home}/project/.codex/config.toml" <<'TOML'
# project notes
[projects."/home/me/other"]
trust_level = "trusted"
TOML
install_must_succeed "${home}" sync --target codex --intent settings
out="${INSTALL_OUT}"
proj="$(cat "${home}/project/.codex/config.toml")"
assert_contains "${proj}" "# project notes" "codex project merge preserves comments"
assert_contains "${proj}" '[projects."/home/me/other"]' "codex project merge preserves a [projects.*] table"
assert_contains "${proj}" 'model = "gpt-6-astra"' "codex project merge applies the managed model"
assert_contains "${proj}" "model_reasoning_effort" "codex project merge applies reasoning effort"
assert_contains "${proj}" "[features]" "codex project merge applies [features]"
assert_contains "${proj}" "[agents]" "codex project merge applies [agents]"
for absent in approval_policy sandbox_mode approvals_reviewer sandbox_workspace_write "[plugins." model_provider model_providers "profile" "profiles" "notify" "otel" openai_base_url chatgpt_base_url; do
    assert_not_contains "${proj}" "${absent}" "codex project file excludes ${absent}"
done
assert_contains "${out}" "only when the project is trusted" "codex project merge prints the trust warning"
if [[ ! -s "${home}/.codex/config.toml" ]]; then ok "default codex settings leaves ~/.codex/config.toml untouched"; else ko "default codex settings leaves ~/.codex/config.toml untouched"; fi

# T9: remove strips only the managed project leaves.
home="$(new_home)"
install_must_succeed "${home}" sync --target codex --intent settings
cat >> "${home}/project/.codex/config.toml" <<'TOML'

[mine]
keep = true
TOML
install_must_succeed "${home}" remove --target codex --intent settings
proj="$(cat "${home}/project/.codex/config.toml")"
assert_contains "${proj}" "[mine]" "codex project remove keeps an unmanaged table"
assert_not_contains "${proj}" 'model = "gpt-6-astra"' "codex project remove strips the managed model"

# The plugins group is global-only: dropped with a notice by default,
# rejected with --project.
home="$(new_home)"
install_must_succeed "${home}" sync --target codex --intent plugins
assert_contains "${INSTALL_OUT}" "the plugins group is global-only" "codex default plugins intent drops the group with a notice"
if [[ ! -e "${home}/project/.codex/config.toml" && ! -s "${home}/.codex/config.toml" ]]; then ok "codex default plugins intent writes nothing"; else ko "codex default plugins intent writes nothing"; fi
out="$(run_install "${home}" sync --target codex --intent plugins --project)"
assert_contains "${out}" "--project cannot carry the plugins group for target 'codex' (global-only)" "codex --project rejects the plugins group"

# T7-style legacy hint.
home="$(new_home)"
install_must_succeed "${home}" sync --target codex --intent settings --global
install_must_succeed "${home}" sync --target codex --intent settings
assert_contains "${INSTALL_OUT}" "settings now default to project scope" "codex legacy hint printed when the global file holds ycc state"

echo

echo "== install.sh remove: codex settings and rules =="

home="$(new_home)"
cat > "${home}/.codex/config.toml" <<'TOML'
# local machine notes
[projects."/home/me/secret-project"]
trust_level = "trusted"
TOML
install_must_succeed "${home}" sync --target codex --intent settings,plugins,rules --global
install_must_succeed "${home}" remove --target codex --intent settings,plugins,rules --global
merged="$(cat "${home}/.codex/config.toml")"
assert_contains "${merged}" "# local machine notes" "codex settings remove keeps comments"
assert_contains "${merged}" '[projects."/home/me/secret-project"]' "codex settings remove keeps trusted projects"
assert_not_contains "${merged}" "model =" "codex settings remove drops managed model"
assert_not_contains "${merged}" "[plugins." "codex plugins remove drops managed plugin tables"
for f in .codex/rules/default.rules .codex/CLAUDE.md .codex/AGENTS.md; do
    if [[ ! -L "${home}/${f}" ]]; then ok "codex remove unlinks ${f}"; else ko "codex remove unlinks ${f}"; fi
done

echo
echo "== install.sh: codex native base (stub Codex CLI) =="

# A stateful Codex CLI stub: 'plugin marketplace add' registers [marketplaces.ycc]
# in config.toml and 'plugin add <pkg>@ycc --json' snapshots this checkout's
# .codex-plugin/<pkg> into the versioned cache, like codex-cli >= 0.160.
codex_native_saved_stub="${STUB_BIN}"
codex_native_bin="${SANDBOX_ROOT}/codex-native-bin"
codex_missing_bin="${SANDBOX_ROOT}/codex-missing-bin"
mkdir -p "${codex_native_bin}" "${codex_missing_bin}"
cp -p "${STUB_BIN}"/* "${codex_native_bin}/"
cp -p "${STUB_BIN}"/* "${codex_missing_bin}/"
# An old Codex (no 'codex plugin') stands in for a missing CLI, so a real
# codex later on PATH can never answer for it.
printf '#!/usr/bin/env bash\nexit 1\n' > "${codex_missing_bin}/codex"
cat > "${codex_native_bin}/codex" <<PY
#!/usr/bin/env python3
import json, os, shutil, sys, tomllib
from pathlib import Path
args = sys.argv[1:]
if "--help" in args:
    sys.exit(0)
with open(os.environ["CLAUDE_STUB_LOG"], "a") as log:
    log.write("codex " + " ".join(args) + "\n")
home = Path.home()
config = home / ".codex/config.toml"
if args[:3] == ["plugin", "marketplace", "add"]:
    text = config.read_text() if config.exists() else ""
    if "ycc" not in tomllib.loads(text).get("marketplaces", {}):
        git = args[3].startswith("https:")
        text += "\n[marketplaces.ycc]\nsource_type = " + json.dumps("git" if git else "local")
        text += "\nsource = " + json.dumps(args[3]) + "\n" + ('ref = "main"\n' if git else "")
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(text)
elif args[:2] == ["plugin", "add"]:
    package = args[2].split("@")[0]
    source = Path("${REPO_ROOT}") / ".codex-plugin" / package
    version = json.loads((source / ".codex-plugin/plugin.json").read_text())["version"]
    cache = home / ".codex/plugins/cache/ycc" / package / version
    if cache.exists():
        shutil.rmtree(cache)
    shutil.copytree(source, cache)
    print(json.dumps({"pluginId": args[2], "name": package, "marketplaceName": "ycc", "version": version, "installedPath": str(cache)}))
PY
chmod +x "${codex_native_bin}/codex" "${codex_missing_bin}/codex"
STUB_BIN="${codex_native_bin}"

# codex_legacy_carriers <home> — print every retired-installer carrier still present.
codex_legacy_carriers() {
    local h="$1" f
    for f in .codex/plugins/ycc .agents/plugins/ycc .agents/plugins/marketplace.json .codex/plugins/cache/local-ycc-plugins .codex/skills; do
        [[ -e "${h}/${f}" || -L "${h}/${f}" ]] && echo "${f}"
    done
    grep -q 'local-ycc-plugins' "${h}/.codex/config.toml" 2>/dev/null && echo "config.toml:ycc@local-ycc-plugins"
    grep -q '^\[mcp_servers\.' "${h}/.codex/config.toml" 2>/dev/null && echo "config.toml:mcp_servers"
    return 0
}

for mode in local repo; do
    home="$(new_home)"
    mkdir -p "${home}/.codex/agents"
    echo 'name = "mine"' > "${home}/.codex/agents/mine.toml"
    install_must_succeed "${home}" install --target codex --only base --mode "${mode}"
    out="${INSTALL_OUT}"
    calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
    if [[ "${mode}" == local ]]; then
        assert_contains "${calls}" "codex plugin marketplace add ${REPO_ROOT}" "codex local base registers this checkout as marketplace ycc"
    else
        assert_contains "${calls}" "codex plugin marketplace add https://github.com/yandy-r/ystack.git --ref main" "codex repo base registers the GitHub marketplace"
    fi
    assert_contains "${calls}" "codex plugin add ycc@ycc --json" "codex ${mode} base adds ycc@ycc"
    assert_contains "${calls}" "codex plugin add ycc-mcp@ycc --json" "codex ${mode} base adds ycc-mcp@ycc"
    assert_not_contains "${calls}" "local-ycc-plugins" "codex ${mode} base never touches local-ycc-plugins"
    legacy="$(codex_legacy_carriers "${home}")"
    if [[ -z "${legacy}" ]]; then ok "codex ${mode} base writes no legacy carrier"; else ko "codex ${mode} base writes no legacy carrier" "${legacy}"; fi
    if python3 - "${home}" <<'PY'
import sys, tomllib
from pathlib import Path
config = tomllib.loads((Path(sys.argv[1]) / ".codex/config.toml").read_text())
assert config["plugins"]["ycc@ycc"]["enabled"] is True
assert config["plugins"]["ycc-mcp@ycc"]["enabled"] is True
assert "ycc" in config["marketplaces"]
PY
    then ok "codex ${mode} base enables ycc@ycc + ycc-mcp@ycc"; else ko "codex ${mode} base enables ycc@ycc + ycc-mcp@ycc"; fi
    if [[ -f "${home}/.codex/agents/mine.toml" ]]; then ok "codex ${mode} base keeps user agents"; else ko "codex ${mode} base keeps user agents"; fi
    shipped_agents="$(find "${REPO_ROOT}/.codex-plugin/agents" -maxdepth 1 -name '*.toml' | wc -l)"
    installed_agents="$(find "${home}/.codex/agents" -maxdepth 1 -name '*.toml' ! -name mine.toml | wc -l)"
    if [[ "${mode}" == local ]]; then
        if [[ "${installed_agents}" -eq "${shipped_agents}" ]]; then ok "codex local base mirrors every custom agent"; else ko "codex local base mirrors every custom agent" "${installed_agents}/${shipped_agents}"; fi
        last_step="$(grep -oE '\[[0-9]+/[0-9]+\]' <<< "${out}" | tail -n 1)"
        if [[ "${last_step}" == "[5/5]" ]]; then ok "codex local base numbers its steps to the total"; else ko "codex local base numbers its steps to the total" "last step: ${last_step}"; fi
    elif [[ "${installed_agents}" -eq 0 ]]; then
        ok "codex repo base installs no custom agents"
    else
        ko "codex repo base installs no custom agents"
    fi

    : > "${home}/claude-calls.log"
    install_must_succeed "${home}" remove --target codex --intent base
    calls="$(cat "${home}/claude-calls.log")"
    assert_contains "${calls}" "codex plugin remove ycc@ycc" "codex ${mode} base remove uninstalls ycc@ycc"
    assert_contains "${calls}" "codex plugin remove ycc-mcp@ycc" "codex ${mode} base remove uninstalls ycc-mcp@ycc"
    assert_contains "${calls}" "codex plugin marketplace remove ycc" "codex ${mode} base remove drops its marketplace"
    if [[ ! -e "${home}/.codex/plugins/cache/ycc" ]]; then ok "codex ${mode} base remove retracts both owned snapshots"; else ko "codex ${mode} base remove retracts both owned snapshots"; fi
    config="$(cat "${home}/.codex/config.toml" 2>/dev/null)"
    assert_not_contains "${config}" 'ycc@ycc' "codex ${mode} base remove retracts the plugin enablement"
    assert_not_contains "${config}" '[marketplaces.ycc]' "codex ${mode} base remove retracts its registration"
    if [[ "$(find "${home}/.codex/agents" -mindepth 1 -maxdepth 1 -printf '%f\n')" == "mine.toml" ]]; then ok "codex ${mode} base remove keeps only user agents"; else ko "codex ${mode} base remove keeps only user agents"; fi
done

# Skills ship only inside ycc@ycc: the skills intent is the base install.
home="$(new_home)"
install_must_succeed "${home}" sync --target codex --intent skills
assert_contains "$(cat "${home}/claude-calls.log")" "codex plugin add ycc@ycc --json" "codex skills intent installs ycc@ycc"
if [[ ! -e "${home}/.codex/skills" ]]; then ok "codex skills intent copies no standalone skills"; else ko "codex skills intent copies no standalone skills"; fi
install_must_succeed "$(new_home)" install --target codex --only skills
assert_contains "${INSTALL_OUT}" "step 'skills' is not supported by target 'codex'" "codex no longer has a standalone skills step"

# The agents step mirrors only the custom agents; nothing native runs.
home="$(new_home)"
install_must_succeed "${home}" sync --target codex --intent agents
if [[ ! -e "${home}/claude-calls.log" ]]; then ok "codex agents intent runs no codex CLI"; else ko "codex agents intent runs no codex CLI"; fi
if [[ -n "$(find "${home}/.codex/agents" -maxdepth 1 -name '*.toml')" ]]; then ok "codex agents intent installs the custom agents"; else ko "codex agents intent installs the custom agents"; fi
install_must_succeed "${home}" remove --target codex --intent agents
if [[ -z "$(find "${home}/.codex/agents" -mindepth 1 2>/dev/null)" ]]; then ok "codex agents remove retracts the tracked agents"; else ko "codex agents remove retracts the tracked agents"; fi

echo
echo "== install.sh: codex native mcp (stub Codex CLI) =="

home="$(new_home)"
install_must_succeed "${home}" sync --target codex --intent mcp
calls="$(cat "${home}/claude-calls.log")"
assert_contains "${calls}" "codex plugin add ycc-mcp@ycc --json" "codex mcp intent adds ycc-mcp@ycc"
assert_not_contains "${calls}" "codex plugin add ycc@ycc" "codex mcp intent does not add ycc@ycc"
config="$(cat "${home}/.codex/config.toml")"
assert_contains "${config}" '[plugins."ycc-mcp@ycc"]' "codex mcp intent enables ycc-mcp@ycc"
assert_not_contains "${config}" '[mcp_servers.' "codex mcp intent merges no [mcp_servers] tables"
if [[ ! -e "${home}/project/.codex" ]]; then ok "codex mcp intent writes nothing at project scope"; else ko "codex mcp intent writes nothing at project scope"; fi
: > "${home}/claude-calls.log"
install_must_succeed "${home}" remove --target codex --intent mcp
calls="$(cat "${home}/claude-calls.log")"
assert_contains "${calls}" "codex plugin remove ycc-mcp@ycc" "codex mcp remove uninstalls ycc-mcp@ycc"
assert_not_contains "${calls}" "codex plugin remove ycc@ycc" "codex mcp remove leaves ycc@ycc alone"
assert_not_contains "$(cat "${home}/.codex/config.toml" 2>/dev/null)" 'ycc-mcp@ycc' "codex mcp remove retracts the enablement"

# The mcp intent beside base is the base install (both packages, once).
home="$(new_home)"
install_must_succeed "${home}" sync --target codex --intent base,mcp
count="$(grep -c 'codex plugin add ycc-mcp@ycc' "${home}/claude-calls.log")"
if [[ "${count}" == "1" ]]; then ok "codex base+mcp adds ycc-mcp@ycc once"; else ko "codex base+mcp adds ycc-mcp@ycc once" "${count}"; fi

out="$(run_install "$(new_home)" sync --target codex --intent mcp --project)"
assert_contains "${out}" "--project is not supported by step 'mcp' for target 'codex'" "codex rejects project-scope mcp"
if run_install "$(new_home)" install --target codex --mcps github >/dev/null; then ko "codex rejects --mcps"; else ok "codex rejects --mcps"; fi

echo
echo "== install.sh: codex without the plugin CLI fails clearly =="

STUB_BIN="${codex_missing_bin}"
for intent in base mcp; do
    home="$(new_home)"
    before="$(find "${home}" | sort)"
    if out="$(run_install "${home}" sync --target codex --intent "${intent}")"; then
        ko "codex ${intent} without the plugin CLI fails"
    else
        ok "codex ${intent} without the plugin CLI fails"
    fi
    assert_contains "${out}" "needs the Codex CLI with 'codex plugin' (Codex >= 0.160)" "codex ${intent} names the missing Codex CLI"
    if [[ "$(find "${home}" | sort)" == "${before}" ]]; then ok "codex ${intent} without the CLI writes nothing"; else ko "codex ${intent} without the CLI writes nothing"; fi
done
STUB_BIN="${codex_native_bin}"

echo
echo "== install.sh: codex base retires the legacy install =="

# codex_legacy_fixture <home> — what the retired local-ycc-plugins installer
# left: links, flat cache, catalog entry, enablement leaf, the managed
# [mcp_servers] group and standalone skills; plus user state that must survive.
codex_legacy_fixture() {
    local h="$1"
    mkdir -p "${h}/.codex/plugins/cache/local-ycc-plugins" "${h}/.agents/plugins" "${h}/.codex/agents"
    ln -s "${REPO_ROOT}/.codex-plugin/ycc" "${h}/.codex/plugins/ycc"
    ln -s "${REPO_ROOT}/.codex-plugin/ycc" "${h}/.agents/plugins/ycc"
    cp -R "${REPO_ROOT}/.codex-plugin/ycc" "${h}/.codex/plugins/cache/local-ycc-plugins/ycc"
    printf 'name = "mine"\n' > "${h}/.codex/agents/mine.toml"
    cat > "${h}/.codex/config.toml" <<'TOML'
# my settings
[plugins."ycc@local-ycc-plugins"]
enabled = true
[plugins."mine@other"]
enabled = true
TOML
    cat > "${h}/.agents/plugins/marketplace.json" <<'JSON'
{
  "name": "local-ycc-plugins",
  "interface": { "displayName": "Local YCC Plugins" },
  "plugins": [
    {
      "name": "ycc",
      "source": { "source": "local", "path": "./.agents/plugins/ycc" },
      "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL" },
      "category": "Productivity"
    }
  ]
}
JSON
    HOME="${h}" YCC_MANAGED_CONFIG_STATE="${h}/.config/ycc/managed-config-state.json" \
        python3 "${REPO_ROOT}/scripts/merge_managed_config.py" --profile codex-config \
        --source "${REPO_ROOT}/.codex-plugin/config/mcp-servers.json" --destination "${h}/.codex/config.toml" --groups mcp >/dev/null \
        || { ko "codex legacy fixture: mcp merge"; exit 1; }
    HOME="${h}" YCC_MANAGED_CONFIG_STATE="${h}/.config/ycc/managed-config-state.json" \
        python3 "${REPO_ROOT}/scripts/install_slices.py" install --target codex --slice skills >/dev/null \
        || { ko "codex legacy fixture: skills slice"; exit 1; }
}

home="$(new_home)"
codex_legacy_fixture "${home}"
legacy="$(codex_legacy_carriers "${home}")"
assert_contains "${legacy}" "config.toml:ycc@local-ycc-plugins" "codex legacy fixture seeds the ycc@local-ycc-plugins leaf"
assert_contains "${legacy}" "config.toml:mcp_servers" "codex legacy fixture seeds the [mcp_servers] group"
printf '\nedited\n' >> "${home}/.codex/skills/git-workflow/SKILL.md"
install_must_succeed "${home}" install --target codex --only base
config="$(cat "${home}/.codex/config.toml")"
assert_not_contains "${config}" 'ycc@local-ycc-plugins' "codex base cleanup retires the legacy ycc@local-ycc-plugins leaf"
assert_not_contains "${config}" '[mcp_servers.' "codex base cleanup retires the legacy [mcp_servers] group"
assert_contains "${config}" "# my settings" "codex base cleanup keeps TOML comments"
assert_contains "${config}" 'mine@other' "codex base cleanup keeps foreign plugin tables"
assert_contains "${config}" '[plugins."ycc@ycc"]' "codex base cleanup keeps the native enablement"
for f in .codex/plugins/ycc .agents/plugins/ycc .codex/plugins/cache/local-ycc-plugins .agents/plugins/marketplace.json .codex/skills/init; do
    if [[ ! -e "${home}/${f}" && ! -L "${home}/${f}" ]]; then ok "codex base cleanup retires ${f}"; else ko "codex base cleanup retires ${f}"; fi
done
assert_contains "$(cat "${home}/.codex/skills/git-workflow/SKILL.md")" "edited" "codex base cleanup keeps an edited standalone skill"
assert_contains "$(cat "${home}/.codex/agents/mine.toml" 2>/dev/null)" 'name = "mine"' "codex base cleanup keeps user agents"
config_before="$(cat "${home}/.codex/config.toml")"
install_must_succeed "${home}" install --target codex --only base
if [[ "$(cat "${home}/.codex/config.toml")" == "${config_before}" ]]; then ok "codex repeated base is config-stable"; else ko "codex repeated base is config-stable"; fi

# An edited catalog entry is user-owned: it stays, with the link it references.
home="$(new_home)"
codex_legacy_fixture "${home}"
python3 - "${home}/.agents/plugins/marketplace.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); data = json.loads(p.read_text())
data["plugins"][0]["policy"]["installation"] = "ENABLED"
p.write_text(json.dumps(data, indent=2) + "\n")
PY
install_must_succeed "${home}" install --target codex --only base
assert_contains "$(cat "${home}/.agents/plugins/marketplace.json")" '"ENABLED"' "codex cleanup keeps an edited catalog entry"
if [[ -L "${home}/.agents/plugins/ycc" ]]; then ok "codex cleanup keeps the link a retained entry references"; else ko "codex cleanup keeps the link a retained entry references"; fi

# An exact pre-rename repo-mode entry is still the installer's own.
home="$(new_home)"
codex_legacy_fixture "${home}"
python3 - "${home}/.agents/plugins/marketplace.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); data = json.loads(p.read_text())
data["plugins"][0]["source"] = {"source": "git-subdir", "url": "https://github.com/yandy-r/claude-plugins.git", "path": "./.codex-plugin/ycc", "ref": "main"}
data["plugins"].append({"name": "other"})
p.write_text(json.dumps(data, indent=2) + "\n")
PY
install_must_succeed "${home}" install --target codex --only base
catalog="$(cat "${home}/.agents/plugins/marketplace.json")"
assert_not_contains "${catalog}" 'yandy-r/claude-plugins' "codex cleanup retires an exact pre-rename repo entry"
assert_contains "${catalog}" '"other"' "codex cleanup keeps other catalog plugins"

# The mcp step alone retires only the legacy [mcp_servers] group.
home="$(new_home)"
codex_legacy_fixture "${home}"
install_must_succeed "${home}" sync --target codex --intent mcp
config="$(cat "${home}/.codex/config.toml")"
assert_not_contains "${config}" '[mcp_servers.' "codex mcp cleanup retires the legacy [mcp_servers] group"
assert_contains "${config}" 'ycc@local-ycc-plugins' "codex mcp cleanup keeps legacy ycc until ycc@ycc is installed"
if [[ -L "${home}/.codex/plugins/ycc" ]]; then ok "codex mcp cleanup keeps the legacy plugin link"; else ko "codex mcp cleanup keeps the legacy plugin link"; fi

# remove --intent base retires the legacy leftovers too (no native proof needed).
home="$(new_home)"
codex_legacy_fixture "${home}"
install_must_succeed "${home}" remove --target codex --intent base
legacy="$(codex_legacy_carriers "${home}")"
if [[ "${legacy}" == ".codex/skills" || -z "${legacy}" ]]; then ok "codex base remove retires the legacy install"; else ko "codex base remove retires the legacy install" "${legacy}"; fi
assert_contains "$(cat "${home}/.codex/config.toml")" 'mine@other' "codex base remove keeps foreign plugin tables"
if [[ -f "${home}/.codex/agents/mine.toml" ]]; then ok "codex base remove keeps user agents beside the legacy cleanup"; else ko "codex base remove keeps user agents beside the legacy cleanup"; fi

# A dry-run base remove previews the cleanup without touching anything.
home="$(new_home)"
codex_legacy_fixture "${home}"
before="$(find "${home}" -printf '%p %s %l\n' | sort)"
install_must_succeed "${home}" remove --target codex --intent base --dry-run
if [[ "$(find "${home}" -printf '%p %s %l\n' | sort)" == "${before}" ]]; then ok "codex dry-run base remove changes nothing"; else ko "codex dry-run base remove changes nothing"; fi
assert_contains "${INSTALL_OUT}" "would remove" "codex dry-run base remove previews the legacy cleanup"

STUB_BIN="${codex_native_saved_stub}"

echo
echo "== install.sh rules: codex links only AGENTS.md, legacy CLAUDE.md link removable =="

home="$(new_home)"
install_must_succeed "${home}" install --target codex --only rules
if [[ -L "${home}/.codex/AGENTS.md" && "$(readlink "${home}/.codex/AGENTS.md")" == "${REPO_ROOT}/ycc/settings/rules/AGENTS.md" ]]; then ok "codex rules links AGENTS.md"; else ko "codex rules links AGENTS.md"; fi
if [[ -L "${home}/.codex/rules/default.rules" ]]; then ok "codex rules still links default.rules"; else ko "codex rules still links default.rules"; fi
if [[ ! -e "${home}/.codex/CLAUDE.md" && ! -L "${home}/.codex/CLAUDE.md" ]]; then ok "codex rules no longer links the unread CLAUDE.md"; else ko "codex rules no longer links the unread CLAUDE.md"; fi
assert_contains "$(readlink -f "${home}/.codex/AGENTS.md" | xargs wc -l | awk '{print ($1 <= 120) ? "within-budget" : "over-budget"}')" "within-budget" "codex AGENTS.md resolves to a within-budget body"

home="$(new_home)"
ln -s "${REPO_ROOT}/ycc/settings/rules/CLAUDE.md" "${home}/.codex/CLAUDE.md"
install_must_succeed "${home}" remove --target codex --intent rules
if [[ ! -e "${home}/.codex/CLAUDE.md" && ! -L "${home}/.codex/CLAUDE.md" ]]; then ok "codex remove unlinks the legacy CLAUDE.md link"; else ko "codex remove unlinks the legacy CLAUDE.md link"; fi

home="$(new_home)"
echo "# mine" > "${home}/.codex/AGENTS.md"
out="$(run_install "${home}" install --target codex --only rules)"
assert_contains "${out}" "refusing to replace user-authored rules file" "codex rules refuses a real AGENTS.md without --force"
assert_contains "$(cat "${home}/.codex/AGENTS.md")" "# mine" "codex rules keeps the real AGENTS.md"

echo
echo "== install.sh --plugins: codex =="

# codex_plugin_tables <config.toml> — the [plugins.*] table names, sorted, comma-joined.
codex_plugin_tables() {
    python3 -c 'import sys, tomllib; print(",".join(sorted(tomllib.load(open(sys.argv[1], "rb")).get("plugins", {}))))' "$1"
}

home="$(new_home)"
install_must_succeed "${home}" list plugins --target codex
codex_names="${INSTALL_OUT}"
assert_contains $'\n'"${codex_names}"$'\n' $'\ncloudflare@openai-curated\n' "list plugins --target codex lists the plugin tables"
assert_not_contains "${codex_names}" "ycc@local-ycc-plugins" "list plugins drops the legacy selector"
assert_contains $'\n'"${codex_names}"$'\n' $'\nycc@ycc\n' "list plugins names ycc@ycc"

home="$(new_home)"
install_must_succeed "${home}" sync --target codex --intent plugins --plugins github@openai-curated --global
tables="$(codex_plugin_tables "${home}/.codex/config.toml")"
if [[ "${tables}" == "github@openai-curated" ]]; then ok "codex --plugins sync writes one plugin table"; else ko "codex --plugins sync writes one plugin table" "${tables}"; fi

home="$(new_home)"
install_must_succeed "${home}" sync --target codex --intent plugins --global
before="$(codex_plugin_tables "${home}/.codex/config.toml")"
install_must_succeed "${home}" remove --target codex --intent plugins --plugins cloudflare@openai-curated --global
after="$(codex_plugin_tables "${home}/.codex/config.toml")"
expected="$(tr ',' '\n' <<< "${before}" | grep -vx 'cloudflare@openai-curated' | paste -sd, -)"
if [[ "${before}" == *cloudflare@openai-curated* && "${after}" == "${expected}" ]]; then
    ok "codex remove --plugins drops only the selected table"
else
    ko "codex remove --plugins drops only the selected table" "before=${before} after=${after}"
fi

# A committed project config whose values equal the repo's must lose nothing
# ycc never recorded writing (scalar and table-child keys alike).
home="$(new_home)"
mkdir -p "${home}/project/.codex"
cat > "${home}/project/.codex/config.toml" <<'TOML'
model = "gpt-6-astra"

[features]
multi_agent = true
TOML
cp "${home}/project/.codex/config.toml" "${home}/before.toml"
install_must_succeed "${home}" remove --target codex --intent settings
if cmp -s "${home}/before.toml" "${home}/project/.codex/config.toml"; then
    ok "codex project remove keeps repo-equal keys ycc never wrote byte-identical"
else
    ko "codex project remove keeps repo-equal keys ycc never wrote byte-identical"
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
