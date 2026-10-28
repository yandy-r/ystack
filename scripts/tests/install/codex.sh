#!/usr/bin/env bash
# install.sh tests — codex: config merge, remove, base remove + plugin CLI, slices.
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
install_must_succeed "${home}" sync --target codex --intent settings,mcp --force --global
out="${INSTALL_OUT}"
merged="$(cat "${home}/.codex/config.toml")"
assert_contains "${merged}" "# local machine notes" "TOML comment preserved"
assert_contains "${merged}" '[projects."/home/me/secret-project"]' "trusted project preserved"
assert_contains "${merged}" "[mcp_servers.internal]" "local MCP server preserved"
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

# T9: mcp + settings share one project file, warn once, and remove strips
# only the managed leaves.
home="$(new_home)"
install_must_succeed "${home}" sync --target codex --intent settings,mcp
proj="$(cat "${home}/project/.codex/config.toml")"
assert_contains "${proj}" "[mcp_servers." "codex project file carries the MCP servers"
assert_contains "${proj}" 'model = "gpt-6-astra"' "codex project file carries the settings beside the MCP servers"
count="$(grep -c 'only when the project is trusted' <<< "${INSTALL_OUT}")"
if [[ "${count}" == "1" ]]; then ok "codex settings+mcp warns about trust once"; else ko "codex settings+mcp warns about trust once" "${count}"; fi
cat >> "${home}/project/.codex/config.toml" <<'TOML'

[mine]
keep = true
TOML
install_must_succeed "${home}" remove --target codex --intent settings
proj="$(cat "${home}/project/.codex/config.toml")"
assert_contains "${proj}" "[mine]" "codex project remove keeps an unmanaged table"
assert_contains "${proj}" "[mcp_servers." "codex settings-only remove leaves the MCP servers"
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


echo "== install.sh install: codex base mirrors custom agents =="

home="$(new_home)"
mkdir -p "${home}/.codex/agents"
echo 'name = "mine"' > "${home}/.codex/agents/mine.toml"
install_must_succeed "${home}" install --target codex --only base --skills-home native
out="${INSTALL_OUT}"
if [[ -f "${home}/.codex/agents/mine.toml" ]]; then ok "codex native base install keeps user agents"; else ko "codex native base install keeps user agents"; fi
first_agent="$(find "${REPO_ROOT}/.codex-plugin/agents" -maxdepth 1 -name '*.toml' -printf '%f\n' | sort | head -n 1)"
if [[ -n "${first_agent}" && -f "${home}/.codex/agents/${first_agent}" ]]; then ok "codex native base install populates ~/.codex/agents"; else ko "codex native base install populates ~/.codex/agents" "${out}"; fi
if [[ "$(find "${home}/.codex/agents" -maxdepth 1 -name '*.toml' ! -name mine.toml 2>/dev/null | wc -l)" -eq "$(find "${REPO_ROOT}/.codex-plugin/agents" -maxdepth 1 -name '*.toml' | wc -l)" ]]; then ok "codex native base install mirrors every custom agent"; else ko "codex native base install mirrors every custom agent"; fi
assert_contains "${out}" "Sync custom agents" "codex native base install runs the agents sync step"
assert_contains "${out}" "(skills agents plugin)" "codex native base install runs the agents generator pass"
expected_last_step="[6/6]"
repo_codex_native && expected_last_step="[5/5]"
last_step="$(grep -oE '\[[0-9]+/[0-9]+\]' <<< "${out}" | tail -n 1)"
if [[ "${last_step}" == "${expected_last_step}" ]]; then ok "codex native base install numbers its steps to the total"; else ko "codex native base install numbers its steps to the total" "last step: ${last_step}"; fi

install_must_succeed "${home}" remove --target codex --intent base
if [[ "$(find "${home}/.codex/agents" -mindepth 1 -maxdepth 1 -printf '%f\n')" == "mine.toml" ]]; then ok "codex base remove after install keeps only user agents"; else ko "codex base remove after install keeps only user agents"; fi
assert_not_contains "$(cat "${home}/.config/ycc/installed-units.json" 2>/dev/null)" ".codex/agents" "codex base remove forgets the tracked agents"

# Upgrade over an older untracked mirror (the pre-tracking rsync flow).
home="$(new_home)"
mkdir -p "${home}/.codex/agents"
cp -R "${REPO_ROOT}/.codex-plugin/agents/." "${home}/.codex/agents/"
install_must_succeed "${home}" install --target codex --only base --skills-home native
out="${INSTALL_OUT}"
assert_not_contains "${out}" "refusing to replace" "codex native base install adopts an older untracked mirror"

echo

echo "== install.sh remove: codex base =="

if ! repo_codex_native; then
    home="$(new_home)"
    mkdir -p "${home}/.codex/plugins/cache/local-ycc-plugins/ycc/skills" "${home}/.agents/plugins" "${home}/.codex/agents"
    ln -s "${REPO_REAL}/.codex-plugin/ycc" "${home}/.codex/plugins/ycc"
    ln -s "${REPO_REAL}/.codex-plugin/ycc" "${home}/.agents/plugins/ycc"
    cp -R "${REPO_ROOT}/.codex-plugin/agents/." "${home}/.codex/agents/"
    echo 'name = "mine"' > "${home}/.codex/agents/mine.toml"
    cat > "${home}/.agents/plugins/marketplace.json" <<'JSON'
{
  "name": "local-ycc-plugins",
  "interface": { "displayName": "Local YCC Plugins" },
  "plugins": [{ "name": "ycc", "source": { "source": "local", "path": "./plugins/ycc" } }, { "name": "other" }]
}
JSON
    install_must_succeed "${home}" remove --target codex --intent base
    assert_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "codex plugin remove ycc@local-ycc-plugins" "codex base remove uninstalls through the codex CLI"
    for f in .codex/plugins/ycc .agents/plugins/ycc .codex/plugins/cache/local-ycc-plugins; do
        if [[ ! -e "${home}/${f}" && ! -L "${home}/${f}" ]]; then ok "codex base remove cleans ${f}"; else ko "codex base remove cleans ${f}"; fi
    done
    if [[ "$(find "${home}/.codex/agents" -mindepth 1 -maxdepth 1 -printf '%f\n')" == "mine.toml" ]]; then ok "codex base remove keeps only user agents"; else ko "codex base remove keeps only user agents"; fi
    merged="$(cat "${home}/.agents/plugins/marketplace.json")"
    assert_contains "${merged}" '"other"' "codex base remove keeps other marketplace plugins"
    assert_not_contains "${merged}" '"ycc"' "codex base remove drops the ycc marketplace entry"

    home="$(new_home)"
    mkdir -p "${home}/.agents/plugins"
    cat > "${home}/.agents/plugins/marketplace.json" <<'JSON'
{ "name": "local-ycc-plugins", "interface": { "displayName": "Local YCC Plugins" }, "plugins": [{ "name": "ycc" }] }
JSON
    install_must_succeed "${home}" remove --target codex --intent base
    if [[ ! -e "${home}/.agents/plugins/marketplace.json" ]]; then ok "codex base remove deletes a marketplace left empty"; else ko "codex base remove deletes a marketplace left empty"; fi

    home="$(new_home)"
    mkdir -p "${home}/.codex/plugins"
    ln -s /elsewhere "${home}/.codex/plugins/ycc"
    install_must_succeed "${home}" remove --target codex --intent base
    out="${INSTALL_OUT}"
    if [[ -L "${home}/.codex/plugins/ycc" ]]; then ok "codex base remove keeps a foreign link"; else ko "codex base remove keeps a foreign link"; fi
else
    skip_listed "codex legacy base remove cleanup"
fi

# Codex plugin install through the CLI (lib level; the full base step runs
# the generators). The legacy flat cache must go so Codex's versioned
# snapshot is the only copy.
home="$(new_home)"
mkdir -p "${home}/.codex/plugins/cache/local-ycc-plugins/ycc/.codex-plugin" "${home}/.agents/plugins"
echo '{ "name": "local-ycc-plugins", "plugins": [] }' > "${home}/.agents/plugins/marketplace.json"
out="$(cd "${home}" && HOME="${home}" PATH="${STUB_BIN}:${PATH}" CLAUDE_STUB_LOG="${home}/claude-calls.log" bash -c '
    info() { echo "[ok] $1"; }; warn() { echo "[!!] $1"; }; err() { echo "[err] $1"; }
    SCRIPT_DIR="$1"; source "$1/scripts/lib/install/targets/codex.sh"; install_codex_plugin' _ "${REPO_ROOT}" 2>&1)"
assert_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "codex plugin add ycc@local-ycc-plugins" "codex base installs ycc through the codex CLI"
if [[ ! -e "${home}/.codex/plugins/cache/local-ycc-plugins/ycc" ]]; then ok "codex base drops the legacy flat cache"; else ko "codex base drops the legacy flat cache" "${out}"; fi
assert_contains "$(cat "${REPO_ROOT}/scripts/lib/install/targets/codex.sh")" 'merge_codex_marketplace_json "local" "./.agents/plugins/ycc"' "codex marketplace path resolves from the marketplace root"

echo

echo "== install.sh: codex slices =="

home="$(new_home)"
HOME="${home}" YCC_MANAGED_CONFIG_STATE="${home}/.config/ycc/managed-config-state.json" \
    python3 "${REPO_ROOT}/scripts/install_slices.py" install --target codex --slice skills >/dev/null
if [[ -f "${home}/.codex/skills/git-workflow/SKILL.md" && -d "${home}/.codex/skills/_shared/scripts" ]]; then ok "codex skills slice installs into ~/.codex/skills"; else ko "codex skills slice installs into ~/.codex/skills"; fi
if [[ ! -e "${home}/.codex/plugins" ]]; then ok "codex skills slice links no plugin"; else ko "codex skills slice links no plugin"; fi
assert_contains "$(cat "${home}/.codex/skills/releaser/agents/openai.yaml")" 'allow_implicit_invocation: false' "codex slice copies nested releaser invocation policy"
if [[ ! -e "${home}/.codex/skills/init/agents/openai.yaml" ]]; then ok "codex slice keeps init model-invocable"; else ko "codex slice keeps init model-invocable"; fi
if ! grep -rq '[~]/.codex/plugins/ycc/s' "${home}/.codex/skills"; then ok "codex skills slice re-points plugin paths"; else ko "codex skills slice re-points plugin paths"; fi
if ! grep -rq '\.\./\.\./\.\./shared/' "${home}/.codex/skills"; then ok "codex skills slice re-points relative shared paths"; else ko "codex skills slice re-points relative shared paths"; fi

# Real generated Codex slice resolves top-level, nested, and prompt-template shared references.
if python3 - "${REPO_ROOT}" <<'PY'
import sys, tempfile
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "scripts"))
import generate_codex_skills, install_slices

with tempfile.TemporaryDirectory() as tmp:
    tmp_path = Path(tmp)
    plugin = tmp_path / "plugin"
    home = tmp_path / "home with space"
    generate_codex_skills.write_tree(plugin, dry_run=False)
    entries = {p.name: p for p in sorted((plugin / "skills").iterdir())}
    entries["_shared"] = plugin / "shared"
    rewrites = install_slices.rewrites_for("codex", home)
    pattern = install_slices.namespace_pattern("codex")
    skills = home / ".codex/skills"
    skills.mkdir(parents=True)
    for name, src in entries.items():
        install_slices.stage(name, src, skills, rewrites, pattern)
    prompt = (skills / "plan-workflow/references/planning-agents.md").read_text()
    assert "<installed ycc plugin root>" not in prompt, prompt
    assert "Native prompt substitution" not in prompt, prompt
    expected_ref = skills / "_shared/references/worktree-strategy.md"
    assert str(expected_ref) in prompt and expected_ref.is_file()
    for rel in ("prp-plan/SKILL.md", "orchestrate/references/dispatch-playbook.md"):
        doc = skills / rel
        text = doc.read_text()
        assert "shared/references/" not in text.replace("_shared/references/", ""), rel
        prefix = "../_shared/references/" if rel.endswith("SKILL.md") else "../../_shared/references/"
        assert prefix in text and (doc.parent / prefix / "worktree-strategy.md").resolve().is_file(), rel
PY
then ok "codex slice resolves top-level, nested, and prompt-template shared references"; else ko "codex slice resolves top-level, nested, and prompt-template shared references"; fi

# Codex slices are standalone: removing them never touches the plugin.
home="$(new_home)"
mkdir -p "${home}/.agents/plugins" "${home}/.codex/agents" "${home}/.codex/plugins"
ln -s "${REPO_REAL}/.codex-plugin/ycc" "${home}/.codex/plugins/ycc"
cp -R "${REPO_ROOT}/.codex-plugin/agents/." "${home}/.codex/agents/"
echo 'name = "mine"' > "${home}/.codex/agents/mine.toml"
echo '{ "name": "local-ycc-plugins", "plugins": [{ "name": "ycc" }] }' > "${home}/.agents/plugins/marketplace.json"
install_must_succeed "${home}" remove --target codex --intent agents,skills
if [[ "$(find "${home}/.codex/agents" -mindepth 1 -printf '%f\n')" == "mine.toml" ]]; then ok "codex agents remove keeps only user agents"; else ko "codex agents remove keeps only user agents"; fi
if [[ -L "${home}/.codex/plugins/ycc" ]]; then ok "codex slice remove keeps the plugin link"; else ko "codex slice remove keeps the plugin link"; fi
assert_contains "$(cat "${home}/.agents/plugins/marketplace.json")" '"ycc"' "codex slice remove keeps the marketplace entry"

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
echo "== install.sh: listed Codex base installs both native packages =="

# Flip only a throwaway checkout; production manifest and generated bytes stay
# unlisted. The same full installer harness exercises local/repo and --package.
listed_repo="${SANDBOX_ROOT}/codex-listed-repo"
rsync -a --exclude .git --exclude .omp --exclude node_modules "${REPO_ROOT}/" "${listed_repo}/" || exit 1
python3 - "${listed_repo}/ycc/settings/packages.json" <<'PY' || exit 1
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
model = json.loads(path.read_text())
for package in ("ycc", "ycc-mcp"):
    model["packages"][package]["runtimes"]["codex"]["listed"] = True
path.write_text(json.dumps(model, indent=2) + "\n")
PY
python3 "${listed_repo}/scripts/generate_codex_plugin.py" >/dev/null || exit 1
python3 "${listed_repo}/scripts/validate_codex_native.py" >/dev/null || exit 1
listed_install_saved="${INSTALL}"
listed_stub_saved="${STUB_BIN}"
INSTALL="${listed_repo}/install.sh"
export CODEX_LISTED_FIXTURE="${listed_repo}"
listed_cli_bin="${SANDBOX_ROOT}/listed-cli-bin"
listed_fallback_bin="${SANDBOX_ROOT}/listed-fallback-bin"
mkdir -p "${listed_cli_bin}" "${listed_fallback_bin}"
printf '#!/usr/bin/env bash\nexit 1\n' > "${listed_fallback_bin}/codex"
cat > "${listed_cli_bin}/codex" <<'PY'
#!/usr/bin/env python3
import json
import os
import shutil
import sys
import tomllib
from pathlib import Path
args = sys.argv[1:]
if "--help" in args:
    sys.exit(0)
home = Path.home()
root = Path(os.environ["CODEX_LISTED_FIXTURE"])
with (home / "claude-calls.log").open("a") as log:
    log.write("codex " + " ".join(args) + "\n")
config = home / ".codex/config.toml"
if args[:3] == ["plugin", "marketplace", "add"]:
    text = config.read_text() if config.exists() else ""
    if "ycc" not in tomllib.loads(text).get("marketplaces", {}):
        source = args[3]
        kind = "git" if source.startswith("https:") else "local"
        text += '\n[marketplaces.ycc]\nsource_type = ' + json.dumps(kind) + '\nsource = ' + json.dumps(source) + '\n'
        if kind == "git":
            text += 'ref = "main"\n'
        config.write_text(text)
elif args[:2] == ["plugin", "add"]:
    package = args[2].split("@")[0]
    source = root / ".codex-plugin" / package
    version = json.loads((source / ".codex-plugin/plugin.json").read_text())["version"]
    cache = home / ".codex/plugins/cache/ycc" / package / version
    if cache.exists():
        shutil.rmtree(cache)
    shutil.copytree(source, cache)
    print(json.dumps({"pluginId": args[2], "name": package, "marketplaceName": "ycc", "version": version, "installedPath": str(cache), "authPolicy": "ON_INSTALL"}))
PY
chmod +x "${listed_cli_bin}/codex" "${listed_fallback_bin}/codex"

for delivery in cli fallback; do
    if [[ "${delivery}" == cli ]]; then STUB_BIN="${listed_cli_bin}"; else STUB_BIN="${listed_fallback_bin}"; fi
    for mode in local repo; do
        for selection in base package; do
            home="$(new_home)"
            cat > "${home}/.codex/config.toml" <<'TOML'
# keep my config
[plugins."mine@foreign"]
enabled = false
[marketplaces.foreign]
source_type = "local"
source = "/foreign/source"
TOML
            mkdir -p "${home}/.agents/plugins" "${home}/.codex/plugins/cache/foreign/mine/1"
            printf '{"name":"foreign","plugins":[{"name":"mine","custom":true}]}\n' > "${home}/.agents/plugins/marketplace.json"
            personal_before="$(cat "${home}/.agents/plugins/marketplace.json")"
            printf 'foreign\n' > "${home}/.codex/plugins/cache/foreign/mine/1/sentinel"
            listed_args=(--only "base,settings")
            [[ "${selection}" == package ]] && listed_args=(--package ycc)
            install_must_succeed "${home}" install --target codex "${listed_args[@]}" --mode "${mode}" --skills-home native
            assert_contains "${INSTALL_OUT}" "migrate --target codex" "listed ${delivery}/${mode}/${selection} explains explicit legacy retirement"
            [[ "$(cat "${home}/.agents/plugins/marketplace.json")" == "${personal_before}" ]] && ok "listed ${delivery}/${mode}/${selection} preserves personal catalog" || ko "listed ${delivery}/${mode}/${selection} preserves personal catalog"
            if python3 - "${home}" "${listed_repo}" <<'PY'
import json
import sys
import tomllib
from pathlib import Path
home, root = map(Path, sys.argv[1:])
sys.path.insert(0, str(root / "scripts"))
from codex_install import inventory
config = tomllib.loads((home / ".codex/config.toml").read_text())
assert config["plugins"]["mine@foreign"]["enabled"] is False
assert config["marketplaces"]["foreign"]["source"] == "/foreign/source"
assert "ycc@local-ycc-plugins" not in config["plugins"]
for package in ("ycc", "ycc-mcp"):
    assert config["plugins"][f"{package}@ycc"]["enabled"] is True
    source = root / ".codex-plugin" / package
    manifest = json.loads((source / ".codex-plugin/plugin.json").read_text())
    cache = home / ".codex/plugins/cache/ycc" / package / manifest["version"]
    assert inventory(cache) == inventory(source)
    if package == "ycc-mcp":
        assert manifest["mcpServers"] == "./.mcp.json"
        assert json.loads((cache / ".mcp.json").read_text())["mcpServers"]
assert not (home / ".codex/plugins/ycc").exists()
assert not (home / ".agents/plugins/ycc").exists()
PY
            then ok "listed ${delivery}/${mode}/${selection} enables complete skills + MCP snapshots and keeps foreign config"; else ko "listed ${delivery}/${mode}/${selection} enables complete skills + MCP snapshots and keeps foreign config"; fi
            calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
            if [[ "${delivery}" == cli ]]; then
                assert_contains "${calls}" "codex plugin add ycc@ycc" "listed CLI ${mode}/${selection} adds ycc"
                assert_contains "${calls}" "codex plugin add ycc-mcp@ycc" "listed CLI ${mode}/${selection} adds ycc-mcp"
                if [[ "${mode}" == repo ]]; then
                    assert_contains "${calls}" "marketplace add https://github.com/yandy-r/ystack.git --ref main" "listed CLI repo registers native git marketplace"
                else
                    assert_contains "${calls}" "marketplace add ${listed_repo}" "listed CLI local registers checkout marketplace"
                fi
            else
                assert_not_contains "${calls}" "codex plugin add" "listed fallback never calls plugin CLI"
            fi
            # Already enabled ycc@ycc must not be mistaken for a foreign native
            # install and skip its MCP companion on --package reruns.
            install_must_succeed "${home}" install --target codex "${listed_args[@]}" --mode "${mode}" --skills-home native
            assert_contains "${INSTALL_OUT}" "Install native Codex packages" "listed ${delivery}/${mode}/${selection} refreshes own native pair"
            install_must_succeed "${home}" remove --target codex --only base
            if [[ ! -e "${home}/.codex/plugins/cache/ycc" ]]; then ok "listed ${delivery}/${mode}/${selection} remove retracts both owned caches"; else ko "listed ${delivery}/${mode}/${selection} remove retracts both owned caches"; fi
            assert_not_contains "$(cat "${home}/.codex/config.toml")" 'plugins."ycc@ycc"' "listed ${delivery}/${mode}/${selection} remove retracts ycc enablement"
            assert_not_contains "$(cat "${home}/.codex/config.toml")" 'plugins."ycc-mcp@ycc"' "listed ${delivery}/${mode}/${selection} remove retracts MCP enablement"
            assert_not_contains "$(cat "${home}/.codex/config.toml")" '[marketplaces.ycc]' "listed ${delivery}/${mode}/${selection} remove retracts owned registration"
            assert_contains "$(cat "${home}/.codex/plugins/cache/foreign/mine/1/sentinel")" foreign "listed ${delivery}/${mode}/${selection} remove keeps foreign cache"
            [[ "$(cat "${home}/.agents/plugins/marketplace.json")" == "${personal_before}" ]] && ok "listed remove keeps foreign personal catalog" || ko "listed remove keeps foreign personal catalog"
        done
    done
done

# Native removal retains edits/unknown versions and the registration they need.
STUB_BIN="${listed_fallback_bin}"
home="$(new_home)"
install_must_succeed "${home}" install --target codex --only base --skills-home native
listed_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "${listed_repo}/.codex-plugin/ycc/.codex-plugin/plugin.json")"
printf '\nuser edit\n' >> "${home}/.codex/plugins/cache/ycc/ycc/${listed_version}/skills/git-workflow/SKILL.md"
mkdir -p "${home}/.codex/plugins/cache/ycc/ycc-mcp/foreign-version"
printf 'foreign\n' > "${home}/.codex/plugins/cache/ycc/ycc-mcp/foreign-version/sentinel"
install_must_succeed "${home}" remove --target codex --only base
assert_contains "$(cat "${home}/.codex/plugins/cache/ycc/ycc/${listed_version}/skills/git-workflow/SKILL.md")" 'user edit' "listed remove preserves edited native snapshot"
assert_contains "$(cat "${home}/.codex/plugins/cache/ycc/ycc-mcp/foreign-version/sentinel")" foreign "listed remove preserves unknown native version"
assert_contains "$(cat "${home}/.codex/config.toml")" '[marketplaces.ycc]' "listed remove keeps registration needed by retained native snapshots"

# A closed inline marketplaces table is valid TOML; the no-CLI fallback must
# refuse rather than append text that breaks the whole config file.
STUB_BIN="${listed_fallback_bin}"
home="$(new_home)"
mkdir -p "${home}/.codex"
printf 'marketplaces = { foreign = { source_type = "local", source = "/foreign" } }\n' > "${home}/.codex/config.toml"
inline_before="$(cat "${home}/.codex/config.toml")"
out="$(run_install "${home}" install --target codex --only base --skills-home native)"
if [[ "${out}" == *"closed inline table"* ]]; then ok "listed fallback refuses inline marketplaces table"; else ko "listed fallback refuses inline marketplaces table" "${out}"; fi
[[ "$(cat "${home}/.codex/config.toml")" == "${inline_before}" ]] && ok "listed fallback leaves inline config unchanged" || ko "listed fallback leaves inline config unchanged"
if ! [[ -e "${home}/.config/ycc/codex-native-install.json" ]]; then ok "listed fallback claims no ownership on refusal"; else ko "listed fallback claims no ownership on refusal"; fi

# Native settings removal must forward --force to remove an edited managed leaf.
home="$(new_home)"
install_must_succeed "${home}" sync --target codex --intent settings --global
python3 - "${home}/.codex/config.toml" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
text = "\n".join('model = "user-edited"' if line.startswith("model =") else line for line in text.splitlines()) + "\n"
path.write_text(text)
PY
install_must_succeed "${home}" remove --target codex --intent settings --force --global
assert_not_contains "$(cat "${home}/.codex/config.toml" 2>/dev/null)" 'user-edited' "listed settings removal forwards --force for edited leaf"

# T10: project settings bypass codex_install.py's home-only settings route
# regardless of whether native packages are listed in this checkout.
for native_mode in native legacy; do
    if [[ "${native_mode}" == legacy ]]; then
        python3 - "${listed_repo}/ycc/settings/packages.json" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
model = json.loads(path.read_text())
for package in ("ycc", "ycc-mcp"):
    model["packages"][package]["runtimes"]["codex"]["listed"] = False
path.write_text(json.dumps(model, indent=2) + "\n")
PY
    fi
    home="$(new_home)"
    install_must_succeed "${home}" sync --target codex --intent settings
    assert_contains "$(cat "${home}/project/.codex/config.toml")" 'model = "gpt-6-astra"' "${native_mode} codex project settings use the project destination"
    if [[ ! -e "${home}/.codex/config.toml" ]]; then ok "${native_mode} codex project settings bypass the global settings route"; else ko "${native_mode} codex project settings bypass the global settings route"; fi
done

INSTALL="${listed_install_saved}"
STUB_BIN="${listed_stub_saved}"
unset CODEX_LISTED_FIXTURE

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
if repo_codex_native; then
    assert_not_contains "${codex_names}" "ycc@local-ycc-plugins" "native list plugins drops the legacy selector"
    assert_contains $'\n'"${codex_names}"$'\n' $'\nycc@ycc\n' "native list plugins names ycc@ycc"
fi

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
before="$(cat "${home}/project/.codex/config.toml")"
install_must_succeed "${home}" remove --target codex --intent settings
assert_contains "$(cat "${home}/project/.codex/config.toml")" "${before}" "codex project remove keeps repo-equal keys ycc never wrote"

# The legacy hint counts settings state only: global mcp state must not trigger it.
home="$(new_home)"
install_must_succeed "${home}" sync --target codex --intent mcp --global
install_must_succeed "${home}" sync --target codex --intent settings
assert_not_contains "${INSTALL_OUT}" "settings now default to project scope" "codex: no legacy hint from global mcp-only state"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
