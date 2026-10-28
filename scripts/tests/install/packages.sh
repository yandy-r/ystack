#!/usr/bin/env bash
# install.sh tests — --package: closures per target, delivery routes,
# rejections, and the --intent regression spot-check.
#
# Runs alone (bash scripts/tests/install/packages.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codex_first_agent="$(find "${REPO_ROOT}/.codex-plugin/agents" -maxdepth 1 -name '*.toml' -printf '%f\n' 2>/dev/null | sort | head -n 1)"

echo "== install.sh install --package: claude closures =="

home="$(new_home)"
install_must_succeed_stubbed "${home}" install --target claude --package ycc --skills-home native
out="${INSTALL_OUT}"
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_contains "${calls}" "plugin marketplace add" "claude ycc package registers the marketplace"
assert_contains "${calls}" "plugin install ycc@ycc" "claude ycc package installs ycc@ycc"
assert_contains "$(cat "${home}/.claude/settings.json" 2>/dev/null)" '"claude-fable-5-1"' "claude ycc package merges settings"
if [[ -L "${home}/.claude/CLAUDE.md" ]]; then ok "claude ycc package links rules"; else ko "claude ycc package links rules" "${out}"; fi
if [[ ! -e "${home}/.claude/hooks" && ! -L "${home}/.claude/hooks" && ! -e "${home}/.claude/skills" ]]; then ok "claude ycc package installs neither hooks nor standalone skills"; else ko "claude ycc package installs neither hooks nor standalone skills"; fi

home="$(new_home)"
install_must_succeed "${home}" install --target claude --package ycc-mcp --mcps github
assert_contains "$(cat "${home}/project/.mcp.json" 2>/dev/null)" '"github"' "claude ycc-mcp delivers the selected MCP server"
assert_not_contains "$(cat "${home}/project/.mcp.json" 2>/dev/null)" '"playwright"' "claude ycc-mcp honors --mcps"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin install ycc" "claude ycc-mcp registers no plugin"
assert_contains "$(cat "${home}/.claude/settings.json" 2>/dev/null)" '"claude-fable-5-1"' "claude ycc-mcp includes fallback settings"
if [[ -L "${home}/.claude/CLAUDE.md" ]]; then ok "claude ycc-mcp includes fallback rules"; else ko "claude ycc-mcp includes fallback rules"; fi

home="$(new_home)"
install_must_succeed "${home}" install --target claude --package ycc-hooks
out="${INSTALL_OUT}"
if [[ -L "${home}/.claude/hooks" ]]; then ok "claude ycc-hooks links hooks"; else ko "claude ycc-hooks links hooks"; fi
assert_contains "$(cat "${home}/.claude/settings.json" 2>/dev/null)" '"hooks"' "claude ycc-hooks merges hook activation"
assert_contains "$(cat "${home}/.claude/settings.json" 2>/dev/null)" '"claude-fable-5-1"' "claude ycc-hooks includes fallback settings"
if [[ -L "${home}/.claude/CLAUDE.md" ]]; then ok "claude ycc-hooks includes fallback rules"; else ko "claude ycc-hooks includes fallback rules"; fi
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin install" "claude ycc-hooks does not register an unlisted package"

echo
echo "== install.sh install --package: codex closures =="

home="$(new_home)"
install_must_succeed "${home}" install --target codex --package ycc --mode local --skills-home native
out="${INSTALL_OUT}"
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
if repo_codex_native; then
    assert_contains "${calls}" "codex plugin add ycc@ycc" "codex ycc package installs the listed selector"
    assert_contains "${calls}" "codex plugin add ycc-mcp@ycc" "codex ycc package installs its listed MCP companion"
    assert_contains "${calls}" "codex plugin marketplace add ${REPO_ROOT}" "codex ycc package registers the native marketplace"
else
    assert_contains "${calls}" "codex plugin add ycc@local-ycc-plugins" "codex ycc package installs ycc through the codex CLI"
    assert_contains "$(cat "${home}/.agents/plugins/marketplace.json" 2>/dev/null)" '"ycc"' "codex ycc package registers the marketplace"
fi
assert_contains "$(cat "${home}/.codex/config.toml" 2>/dev/null)" 'model = "gpt-6-astra"' "codex ycc package merges settings"
if [[ -L "${home}/.codex/AGENTS.md" && -L "${home}/.codex/rules/default.rules" ]]; then ok "codex ycc package links rules"; else ko "codex ycc package links rules" "${out}"; fi
if [[ -n "${codex_first_agent}" && -f "${home}/.codex/agents/${codex_first_agent}" ]]; then ok "codex ycc package (local) copies agents"; else ko "codex ycc package (local) copies agents" "${out}"; fi

# Repo mode registers the marketplace; the agents slice still lands.
home="$(new_home)"
install_must_succeed "${home}" install --target codex --package ycc --mode repo --skills-home native
out="${INSTALL_OUT}"
if repo_codex_native; then
    assert_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "codex plugin marketplace add https://github.com/yandy-r/ystack.git --ref main" "codex ycc package (repo) registers the native marketplace"
else
assert_contains "$(cat "${home}/.agents/plugins/marketplace.json" 2>/dev/null)" '"ycc"' "codex ycc package (repo) registers the marketplace"
fi
if [[ -n "${codex_first_agent}" && -f "${home}/.codex/agents/${codex_first_agent}" ]]; then ok "codex ycc package (repo) still copies agents"; else ko "codex ycc package (repo) still copies agents" "${out}"; fi

home="$(new_home)"
install_must_succeed "${home}" install --target codex --package ycc-mcp --mcps github
merged="$(cat "${home}/project/.codex/config.toml" 2>/dev/null)"
assert_contains "${merged}" "[mcp_servers.github]" "codex ycc-mcp writes the server table"
assert_not_contains "${merged}" "[mcp_servers.playwright]" "codex ycc-mcp honors --mcps"
assert_contains "$(cat "${home}/.codex/config.toml" 2>/dev/null)" 'model = "gpt-6-astra"' "codex ycc-mcp includes fallback settings"
if [[ -L "${home}/.codex/AGENTS.md" && -f "${home}/.codex/agents/${codex_first_agent}" ]]; then ok "codex ycc-mcp includes fallback rules and agents"; else ko "codex ycc-mcp includes fallback rules and agents"; fi
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin add" "codex ycc-mcp does not register an unlisted package"

# codex_deliveries_ok <home> — agents, settings and rules landed (the gaps a native plugin never fills).
codex_deliveries_ok() {
    local h="$1"
    [[ -f "${h}/.codex/agents/${codex_first_agent}" && -L "${h}/.codex/AGENTS.md" && -L "${h}/.codex/rules/default.rules" ]] \
        && grep -q 'model = "gpt-6-astra"' "${h}/.codex/config.toml" 2>/dev/null
}

# The literal (unexpanded) legacy plugin root that generated skill bodies reference.
LEGACY_PLUGIN_ROOT='~''/.codex/plugins/ycc'
# A native install requires enabled TOML plus a valid versioned payload.
# Relocatable native payload: guidance and helper references stay inside the
# versioned cache; no text may point at the legacy flat plugin path.
codex_native_cache_fixture() {
    local cache="$1/.codex/plugins/cache/other-marketplace/ycc/1.0.0"
    mkdir -p "${cache}/.codex-plugin" "${cache}/skills/example" "${cache}/shared/scripts"
    echo '{"name":"ycc","version":"1.0.0"}' > "${cache}/.codex-plugin/plugin.json"
    cat > "${cache}/skills/example/SKILL.md" <<'MD'
# Example native skill

Bundled paths are relative to this SKILL.md's directory (the installed location shown by Codex); resolve them while retaining the user's project as cwd.
Run `../../shared/scripts/helper.sh` for the bundled helper.
MD
    echo '#!/usr/bin/env bash' > "${cache}/shared/scripts/helper.sh"
    echo keep > "${cache}/sentinel"
}

for mode in local repo; do
    if ! repo_codex_native; then
    for skills_home in native agents; do
        home="$(new_home)"
        cat > "${home}/.codex/config.toml" <<'TOML'
[plugins."ycc@other-marketplace"]
enabled = true
TOML
        codex_native_cache_fixture "${home}"
        install_must_succeed "${home}" install --target codex --package ycc --mode "${mode}" --skills-home "${skills_home}"
        out="${INSTALL_OUT}"
        assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "codex plugin add" "codex foreign native (${mode}, ${skills_home}) skips registration"
        if [[ ! -e "${home}/.agents/plugins/marketplace.json" && ! -L "${home}/.agents/plugins/ycc" ]]; then ok "codex foreign native (${mode}, ${skills_home}) registers no marketplace"; else ko "codex foreign native (${mode}, ${skills_home}) registers no marketplace"; fi
        if [[ ! -e "${home}/.agents/skills" && ! -e "${home}/.codex/skills" ]]; then ok "codex foreign native (${mode}, ${skills_home}) installs no duplicate skills"; else ko "codex foreign native (${mode}, ${skills_home}) installs no duplicate skills"; fi
        assert_contains "${out}" "other-marketplace" "codex foreign native (${mode}, ${skills_home}) names the foreign marketplace"
        if codex_deliveries_ok "${home}"; then ok "codex foreign native (${mode}, ${skills_home}) still delivers agents, settings and rules"; else ko "codex foreign native (${mode}, ${skills_home}) still delivers agents, settings and rules" "${out}"; fi
        assert_contains "$(cat "${home}/.codex/config.toml")" '[plugins."ycc@other-marketplace"]' "codex foreign native (${mode}, ${skills_home}) keeps the foreign plugin table"
        assert_contains "$(cat "${home}/.codex/plugins/cache/other-marketplace/ycc/1.0.0/sentinel" 2>/dev/null)" "keep" "codex foreign native (${mode}, ${skills_home}) keeps the foreign cache"
        if grep -rqF -- "${LEGACY_PLUGIN_ROOT}" "${home}/.codex/plugins/cache/other-marketplace/ycc/1.0.0"; then ko "codex foreign native (${mode}, ${skills_home}) payload has no legacy flat-path references"; else ok "codex foreign native (${mode}, ${skills_home}) payload has no legacy flat-path references"; fi
        if [[ -f "${home}/.codex/plugins/cache/other-marketplace/ycc/1.0.0/shared/scripts/helper.sh" ]]; then ok "codex foreign native (${mode}, ${skills_home}) keeps its relocatable shared helper"; else ko "codex foreign native (${mode}, ${skills_home}) keeps its relocatable shared helper"; fi
    done
    else
        skip_listed "codex foreign-native detection (${mode}, native/agents)"
    fi

    # Not a native install: a cache alone, a disabled entry, or a stale
    # marketplace entry never suppress registration.
    for fixture in config-only cache-only disabled disabled+cache stale-marketplace; do
        home="$(new_home)"
        case "${fixture}" in
            cache-only | disabled+cache)
                codex_native_cache_fixture "${home}"
                ;;
        esac
        case "${fixture}" in
            disabled | disabled+cache)
                cat > "${home}/.codex/config.toml" <<'TOML'
[plugins."ycc@other-marketplace"]
enabled = false
TOML
                ;;
            config-only)
                cat > "${home}/.codex/config.toml" <<'TOML'
[plugins."ycc@other-marketplace"]
enabled = true
TOML
                ;;
            stale-marketplace)
                mkdir -p "${home}/.agents/plugins"
                echo '{"name":"other-marketplace","plugins":[{"name":"ycc","source":"stale"}]}' > "${home}/.agents/plugins/marketplace.json"
                ;;
        esac
        install_must_succeed "${home}" install --target codex --package ycc --mode "${mode}" --skills-home native
        out="${INSTALL_OUT}"
        assert_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "codex plugin add ycc@" "codex ${fixture} (${mode}) still registers ycc"
        assert_not_contains "${out}" "not re-registering" "codex ${fixture} (${mode}) is not treated as a native install"
        if repo_codex_native; then
            assert_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "codex plugin marketplace add" "codex ${fixture} (${mode}) registers the native marketplace"
        else
        if [[ -f "${home}/.agents/plugins/marketplace.json" ]]; then ok "codex ${fixture} (${mode}) writes the marketplace"; else ko "codex ${fixture} (${mode}) writes the marketplace" "${out}"; fi
        fi
        if codex_deliveries_ok "${home}"; then ok "codex ${fixture} (${mode}) delivers agents, settings and rules"; else ko "codex ${fixture} (${mode}) delivers agents, settings and rules" "${out}"; fi
        case "${fixture}" in
            cache-only | disabled+cache)
                assert_contains "$(cat "${home}/.codex/plugins/cache/other-marketplace/ycc/1.0.0/sentinel" 2>/dev/null)" "keep" "codex ${fixture} (${mode}) keeps the foreign cache"
                ;;
        esac
        case "${fixture}" in
            disabled | disabled+cache)
                if python3 - "${home}/.codex/config.toml" <<'PY'
import pathlib
import sys
import tomllib

config = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
sys.exit(config["plugins"]["ycc@other-marketplace"]["enabled"] is not False)
PY
                then ok "codex ${fixture} (${mode}) preserves foreign disabled state"; else ko "codex ${fixture} (${mode}) preserves foreign disabled state" "$(cat "${home}/.codex/config.toml" 2>/dev/null)"; fi
                ;;
        esac
    done
done

if ! repo_codex_native; then
# A copied legacy bundle is not a relocatable native export: its payload text
# points back at ~/.codex/plugins/ycc, and there is no local plugin symlink to
# satisfy those references. Enabled TOML plus that cache must not suppress
# registration.
home="$(new_home)"
cat > "${home}/.codex/config.toml" <<'TOML'
[plugins."ycc@other-marketplace"]
enabled = true
TOML
mkdir -p "${home}/.codex/plugins/cache/other-marketplace/ycc/1.0.0"
cp -R "${REPO_ROOT}/.codex-plugin/ycc/." "${home}/.codex/plugins/cache/other-marketplace/ycc/1.0.0/"
if grep -rqF -- "${LEGACY_PLUGIN_ROOT}" "${home}/.codex/plugins/cache/other-marketplace/ycc/1.0.0"; then ok "legacy foreign cache fixture carries legacy flat-path references"; else ko "legacy foreign cache fixture carries legacy flat-path references"; fi
if [[ ! -L "${home}/.codex/plugins/ycc" ]]; then ok "legacy foreign cache fixture has no local plugin symlink"; else ko "legacy foreign cache fixture has no local plugin symlink"; fi
install_must_succeed "${home}" install --target codex --package ycc --mode local --skills-home native
out="${INSTALL_OUT}"
assert_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "codex plugin add ycc@local-ycc-plugins" "legacy foreign cache does not suppress registration"
assert_not_contains "${out}" "not re-registering" "legacy foreign cache is not reported as a native install"
assert_contains "$(cat "${home}/.agents/plugins/marketplace.json" 2>/dev/null)" '"ycc"' "legacy foreign cache install writes the marketplace"
if [[ -f "${home}/.codex/plugins/cache/other-marketplace/ycc/1.0.0/.codex-plugin/plugin.json" ]]; then ok "legacy foreign cache payload is preserved"; else ko "legacy foreign cache payload is preserved"; fi
else
    skip_listed "legacy foreign cache registration"
fi

if ! repo_codex_native; then
# A REAL generate_codex_skills.write_tree(native_paths=True) export is the
# relocatable payload. It intentionally keeps one legacy-layout sentence in the
# verbatim target-capability-matrix doc; that documentation must not make the
# installer re-register a second ycc over a working foreign native install.
home="$(new_home)"
cat > "${home}/.codex/config.toml" <<'TOML'
[plugins."ycc@other-marketplace"]
enabled = true
TOML
real_export="${home}/.codex/plugins/cache/other-marketplace/ycc/9.9.9"
mkdir -p "${real_export}/.codex-plugin"
REAL_EXPORT="${real_export}" REPO_ROOT="${REPO_ROOT}" python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

root = Path(os.environ["REPO_ROOT"])
sys.path.insert(0, str(root / "scripts"))
from generate_codex_skills import write_tree

dest = Path(os.environ["REAL_EXPORT"])
write_tree(dest, False, native_paths=True)
version = json.loads((root / "ycc/.claude-plugin/plugin.json").read_text(encoding="utf-8"))
(dest / ".codex-plugin/plugin.json").write_text(
    json.dumps({"name": version["name"], "version": version["version"]}), encoding="utf-8"
)
PY
if grep -qF -- "${LEGACY_PLUGIN_ROOT}" "${real_export}/shared/references/target-capability-matrix.md"; then ok "real native export keeps its verbatim legacy-layout documentation"; else ko "real native export keeps its verbatim legacy-layout documentation"; fi
install_must_succeed "${home}" install --target codex --package ycc --mode local --skills-home native
out="${INSTALL_OUT}"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "codex plugin add" "real native export skips registration"
assert_contains "${out}" "other-marketplace" "real native export names the foreign marketplace"
if [[ ! -e "${home}/.agents/plugins/marketplace.json" && ! -L "${home}/.agents/plugins/ycc" ]]; then ok "real native export registers no local ycc"; else ko "real native export registers no local ycc"; fi
if codex_deliveries_ok "${home}"; then ok "real native export still delivers agents, settings and rules"; else ko "real native export still delivers agents, settings and rules" "${out}"; fi
else
    skip_listed "real native export foreign detection"
fi
if ! repo_codex_native; then
# Own already-enabled native install must refresh rather than hit the foreign
# marketplace skip. A stale marketplace entry makes the refresh observable.
home="$(new_home)"
mkdir -p "${home}/.agents/plugins" "${home}/.codex/plugins/cache/local-ycc-plugins/ycc/1.0.0"
cat > "${home}/.codex/config.toml" <<'TOML'
[plugins."ycc@local-ycc-plugins"]
enabled = true
TOML
echo '{"name":"local-ycc-plugins","plugins":[{"name":"ycc","source":"stale"}]}' > "${home}/.agents/plugins/marketplace.json"
install_must_succeed "${home}" install --target codex --package ycc --mode local --skills-home native
out="${INSTALL_OUT}"
assert_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "codex plugin add ycc@local-ycc-plugins" "codex own native install refreshes through the CLI"
assert_not_contains "$(cat "${home}/.agents/plugins/marketplace.json" 2>/dev/null)" "stale" "codex own native install refreshes the marketplace"
if [[ -L "${home}/.agents/plugins/ycc" && -f "${home}/.codex/agents/${codex_first_agent}" ]]; then ok "codex own native install refreshes the link and agents"; else ko "codex own native install refreshes the link and agents" "${out}"; fi
assert_not_contains "${out}" "not re-registering" "codex own native install is not skipped as foreign"
else
    skip_listed "codex own legacy-native refresh"
fi

if ! repo_codex_native; then
# Legacy / missing Codex plugin CLI: 'codex plugin add --help' fails, so the
# installer writes the plugin enablement itself. Only the exact own table is
# enabled — never unrelated plugins from the shipped source config — and
# unrelated foreign disabled tables survive.
home="$(new_home)"
legacy_bin="${home}/legacy-bin"
mkdir -p "${legacy_bin}"
printf '#!/usr/bin/env bash\nexit 1\n' > "${legacy_bin}/codex"
chmod +x "${legacy_bin}/codex"
cat > "${home}/.codex/config.toml" <<'TOML'
[plugins."ycc@other-marketplace"]
enabled = false

[plugins."github@openai-curated"]
enabled = false
TOML
out="$(cd "${home}/project" && HOME="${home}" PATH="${legacy_bin}:${STUB_BIN}:${PATH}" CLAUDE_STUB_LOG="${home}/claude-calls.log" \
    YCC_MANAGED_CONFIG_STATE="${home}/.config/ycc/managed-config-state.json" YCC_INSTALL_SKIP_BUILD=1 \
    bash "${INSTALL}" install --target codex --package ycc --mode local --skills-home native 2>&1)" && rc=0 || rc=$?
if [[ ${rc} -eq 0 ]]; then ok "codex legacy CLI package install succeeds"; else ko "codex legacy CLI package install succeeds" "${out}"; fi
if python3 - "${home}/.codex/config.toml" <<'PY'
import pathlib
import sys
import tomllib

plugins = tomllib.loads(pathlib.Path(sys.argv[1]).read_text()).get("plugins", {})
ok = (
    plugins.get("ycc@local-ycc-plugins", {}).get("enabled") is True
    and plugins.get("ycc@other-marketplace", {}).get("enabled") is False
    and plugins.get("github@openai-curated", {}).get("enabled") is False
    and "cloudflare@openai-curated" not in plugins
)
sys.exit(0 if ok else 1)
PY
then ok "codex legacy CLI enables only ycc@local-ycc-plugins and keeps foreign disabled tables"; else ko "codex legacy CLI enables only ycc@local-ycc-plugins and keeps foreign disabled tables" "$(cat "${home}/.codex/config.toml")"; fi
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "codex plugin add" "codex legacy CLI never calls plugin add"
if [[ -f "${home}/.codex/agents/${codex_first_agent}" && -L "${home}/.codex/AGENTS.md" ]]; then ok "codex legacy CLI still delivers agents and rules"; else ko "codex legacy CLI still delivers agents and rules" "${out}"; fi

# Stateful regression: an ordinary managed settings install first records
# github/cloudflare enablement as managed; the later legacy-CLI package install
# must add ycc without retiring those earlier managed entries.
home="$(new_home)"
install_must_succeed "${home}" install --target codex --only settings --global
out="$(cd "${home}/project" && HOME="${home}" PATH="${legacy_bin}:${STUB_BIN}:${PATH}" CLAUDE_STUB_LOG="${home}/claude-calls.log" \
    YCC_MANAGED_CONFIG_STATE="${home}/.config/ycc/managed-config-state.json" YCC_INSTALL_SKIP_BUILD=1 \
    bash "${INSTALL}" install --target codex --package ycc --mode local --skills-home native 2>&1)" && rc=0 || rc=$?
if [[ ${rc} -eq 0 ]]; then ok "codex legacy CLI package install after managed settings succeeds"; else ko "codex legacy CLI package install after managed settings succeeds" "${out}"; fi
if python3 - "${home}/.codex/config.toml" <<'PY'
import pathlib
import sys
import tomllib

plugins = tomllib.loads(pathlib.Path(sys.argv[1]).read_text()).get("plugins", {})
ok = (
    plugins.get("ycc@local-ycc-plugins", {}).get("enabled") is True
    and plugins.get("github@openai-curated", {}).get("enabled") is True
    and plugins.get("cloudflare@openai-curated", {}).get("enabled") is True
)
sys.exit(0 if ok else 1)
PY
then ok "codex legacy CLI keeps earlier managed github/cloudflare enablement true"; else ko "codex legacy CLI keeps earlier managed github/cloudflare enablement true" "$(cat "${home}/.codex/config.toml")"; fi
else
    skip_listed "codex legacy CLI enablement and managed-settings preservation"
fi

echo
echo "== install.sh install --package: cursor closures =="

# Cursor packages deliver only their own filesystem carriers, never activate a plugin.

home="$(new_home)"
mkdir -p "${home}/.cursor/commands"
echo foreign > "${home}/.cursor/commands/foreign.md"
install_must_succeed "${home}" install --target cursor --package ycc --skills-home native
assert_contains "$(cat "${home}/.cursor/commands/init.md")" "${home}/.cursor/skills/init/SKILL.md" "cursor ycc commands reference installed skills"
assert_not_contains "$(cat "${home}/.cursor/commands/init.md")" 'CURSOR_PLUGIN_ROOT' "cursor user commands have no plugin-root dependency"
assert_contains "$(cat "${home}/.cursor/commands/foreign.md")" foreign "cursor ycc preserves foreign commands"
if [[ -f "${home}/.cursor/skills/init/SKILL.md" && ! -e "${home}/.cursor/hooks.json" && ! -e "${home}/.cursor/plugins" ]]; then ok "cursor ycc installs skills without implicit hooks or native activation"; else ko "cursor ycc installs skills without implicit hooks or native activation"; fi

home="$(new_home)"
install_must_succeed "${home}" install --target cursor --package ycc --skills-home agents
assert_contains "$(cat "${home}/.cursor/commands/init.md")" "${home}/.agents/skills/init/SKILL.md" "cursor consolidated commands reference actual skills home"
if [[ -f "${home}/.agents/skills/init/SKILL.md" && ! -e "${home}/.cursor/skills" ]]; then ok "cursor ycc consolidation installs one skills home"; else ko "cursor ycc consolidation installs one skills home"; fi

home="$(new_home)"
echo '{"version":1,"hooks":{"sessionStart":[{"command":"echo foreign"}],"afterShellExecution":[{"command":"echo other"}]},"custom":true}' > "${home}/.cursor/hooks.json"
install_must_succeed "${home}" install --target cursor --package ycc-hooks
assert_contains "$(cat "${home}/.cursor/hooks.json")" 'echo foreign' "cursor hooks package preserves foreign sessionStart"
assert_contains "$(cat "${home}/.cursor/hooks.json")" 'afterShellExecution' "cursor hooks package preserves unrelated events"
assert_contains "$(cat "${home}/.cursor/hooks.json")" 'herdr-session-start.sh' "cursor hooks package activates canonical script"
assert_not_contains "$(cat "${home}/.cursor/hooks.json")" 'WorktreeCreate' "cursor hooks never register unsupported WorktreeCreate"
if [[ -x "${home}/.cursor/hooks/herdr-session-start.sh" && ! -e "${home}/.cursor/skills" && ! -e "${home}/.cursor/commands" && ! -e "${home}/.cursor/plugins" ]]; then ok "cursor hooks package owns only hook payload plus settings"; else ko "cursor hooks package owns only hook payload plus settings"; fi
install_must_succeed "${home}" install --target cursor --package ycc-hooks
if [[ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["hooks"]["sessionStart"]))' "${home}/.cursor/hooks.json")" == 2 ]]; then ok "cursor hooks install is idempotent"; else ko "cursor hooks install is idempotent"; fi
install_must_succeed "${home}" remove --target cursor --intent hooks
assert_contains "$(cat "${home}/.cursor/hooks.json")" 'echo foreign' "cursor hooks removal preserves user hooks"
assert_not_contains "$(cat "${home}/.cursor/hooks.json")" 'herdr-session-start.sh' "cursor hooks removal retracts only own activation"
if [[ ! -e "${home}/.cursor/hooks/herdr-session-start.sh" ]]; then ok "cursor hooks removal retracts own script"; else ko "cursor hooks removal retracts own script"; fi

home="$(new_home)"
install_must_succeed "${home}" install --target cursor --package ycc-mcp --mcps github
out="${INSTALL_OUT}"
assert_contains "$(cat "${home}/project/.cursor/mcp.json" 2>/dev/null)" '"github"' "cursor ycc-mcp delivers the selected MCP server"
assert_not_contains "$(cat "${home}/project/.cursor/mcp.json" 2>/dev/null)" '"playwright"' "cursor ycc-mcp honors --mcps"
assert_contains "$(cat "${home}/.cursor/cli-config.json" 2>/dev/null)" '"claude-fable-5-1"' "cursor ycc-mcp includes fallback settings"
if [[ ! -e "${home}/.cursor/skills" && ! -e "${home}/.cursor/agents" && ! -e "${home}/.cursor/rules" && ! -e "${home}/.cursor/commands" ]]; then ok "cursor ycc-mcp copies no bundle content"; else ko "cursor ycc-mcp copies no bundle content"; fi

# ycc-rules: rules + settings only — no skills, agents, plugin registration or MCP.
home="$(new_home)"
install_must_succeed "${home}" install --target cursor --package ycc-rules --skills-home agents
out="${INSTALL_OUT}"
if cmp -s "${REPO_ROOT}/packages/cursor/ycc-rules/rules/common/security.mdc" "${home}/.cursor/rules/common/security.mdc"; then ok "cursor ycc-rules delivers the source rule content"; else ko "cursor ycc-rules delivers the source rule content" "${out}"; fi
assert_contains "$(cat "${home}/.cursor/cli-config.json" 2>/dev/null)" '"claude-fable-5-1"' "cursor ycc-rules includes fallback settings"
if [[ ! -e "${home}/.cursor/skills" && ! -e "${home}/.cursor/agents" && ! -e "${home}/.agents/skills" ]]; then ok "cursor ycc-rules delivers no skills or agents even with --skills-home agents"; else ko "cursor ycc-rules delivers no skills or agents even with --skills-home agents"; fi
if [[ ! -e "${home}/project/.cursor/mcp.json" && ! -e "${home}/.cursor/mcp.json" ]]; then ok "cursor ycc-rules writes no MCP config"; else ko "cursor ycc-rules writes no MCP config"; fi
if [[ ! -e "${home}/.cursor/plugins" ]]; then ok "cursor ycc-rules registers no plugin"; else ko "cursor ycc-rules registers no plugin"; fi
if [[ ! -e "${home}/.cursor/hooks.json" ]]; then ok "cursor ycc-rules does not inherit fallback hooks"; else ko "cursor ycc-rules does not inherit fallback hooks"; fi

echo
echo "== install.sh install --package: CSV, --target all, regressions =="

home="$(new_home)"
install_must_succeed "${home}" install --target claude --package ycc,ycc,ycc-mcp --mcps github --skills-home native
out="${INSTALL_OUT}"
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
count="$(grep -c "plugin install ycc@ycc" <<< "${calls}")"
if [[ "${count}" == "1" ]]; then ok "package CSV dedups base registration"; else ko "package CSV dedups base registration" "ran ${count} times"; fi
assert_contains "$(cat "${home}/project/.mcp.json" 2>/dev/null)" '"github"' "package CSV expands every unique package"

home="$(new_home)"
install_must_succeed "${home}" install --target all --package ycc --skills-home native
out="${INSTALL_OUT}"
for target in opencode agents; do
    assert_contains "${out}" "package 'ycc' is not available for target '${target}' — skipping target '${target}'" "--package --target all warns and skips ${target}"
done
if [[ -f "${home}/.cursor/commands/init.md" ]]; then ok "--package --target all delivers cursor commands"; else ko "--package --target all delivers cursor commands"; fi
for f in .claude/CLAUDE.md .codex/AGENTS.md; do
    if [[ -e "${home}/${f}" ]]; then ok "--package --target all still delivers ${f}"; else ko "--package --target all still delivers ${f}" "${out}"; fi
done
if [[ ! -e "${home}/project/opencode.json" && ! -e "${home}/.agents/skills" ]]; then ok "--package --target all skips unsupported target delivery"; else ko "--package --target all skips unsupported target delivery"; fi

# ycc-hooks under --target all: excluded Codex is skipped; Claude and Cursor run.
home="$(new_home)"
install_must_succeed "${home}" install --target all --package ycc-hooks --skills-home native
out="${INSTALL_OUT}"
if [[ -L "${home}/.claude/hooks" ]]; then ok "--package ycc-hooks --target all still links claude hooks"; else ko "--package ycc-hooks --target all still links claude hooks" "${out}"; fi
assert_contains "${out}" "skipping target 'codex'" "--package ycc-hooks --target all skips codex"
if [[ -x "${home}/.cursor/hooks/herdr-session-start.sh" ]]; then ok "--package ycc-hooks --target all delivers cursor hook"; else ko "--package ycc-hooks --target all delivers cursor hook"; fi

# Every unsupported target: --target all with nothing deliverable fails.
home="$(new_home)"
out="$(run_install "${home}" install --target opencode,agents --package ycc 2>&1)" && rc=0 || rc=$?
if [[ ${rc} -ne 0 ]]; then ok "--package with only unsupported targets fails"; else ko "--package with only unsupported targets fails"; fi

# --intent keeps working after --package support (representative regressions).
home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings
out="${INSTALL_OUT}"
assert_contains "$(cat "${home}/project/.claude/settings.json" 2>/dev/null)" '"claude-fable-5-1"' "--intent settings defaults to the project after --package support"
assert_not_contains "${out}" "--package" "--intent sync prints no --package diagnostics"
assert_not_contains "${out}" "package components" "--intent sync reports no package component skips"

home="$(new_home)"
install_must_succeed "${home}" install --target claude --only rules
if [[ -L "${home}/.claude/CLAUDE.md" ]]; then ok "install --only path unchanged by --package support"; else ko "install --only path unchanged by --package support"; fi

echo
echo "== install.sh install --package: rejections fail before mutations =="

# tree_snapshot <home> — sorted listing of every path (with link targets), for no-mutation checks.
tree_snapshot() {
    (cd "$1" && find . -mindepth 1 -printf '%p %y %l\n' | sort)
}

# assert_package_rejected <name> <needle> <install args...> — fresh HOME, expect
# non-zero exit, the diagnostic, and an identical HOME tree afterwards.
assert_package_rejected() {
    local name="$1" needle="$2" home before after out rc=0
    shift 2
    home="$(new_home)"
    before="$(tree_snapshot "${home}")"
    out="$(run_install "${home}" "$@")" || rc=$?
    if [[ ${rc} -ne 0 ]]; then ok "${name} exits non-zero"; else ko "${name} exits non-zero" "${out}"; fi
    assert_contains "${out}" "${needle}" "${name} reports its reason"
    after="$(tree_snapshot "${home}")"
    if [[ "${before}" == "${after}" ]]; then ok "${name} mutates nothing"; else ko "${name} mutates nothing" "$(diff <(echo "${before}") <(echo "${after}"))"; fi
}

assert_package_rejected "ycc on opencode" "package 'ycc' is not available for target 'opencode'" install --target opencode --package ycc
assert_package_rejected "ycc on agents" "package 'ycc' is not available for target 'agents'" install --target agents --package ycc
assert_package_rejected "ycc-hooks on codex" "package 'ycc-hooks'" install --target codex --package ycc-hooks
assert_package_rejected "unknown package" "unknown package 'bogus'" install --target claude --package bogus
assert_package_rejected "ycc-all" "ycc-all is gated on automatic dependency installation proof" install --target claude --package ycc-all
assert_package_rejected "installer-fallback" "installer-fallback is an internal modeling key" install --target claude --package installer-fallback
assert_package_rejected "ycc-agents" "package 'ycc-agents' is deferred, excluded, opt-in, or not a native package" install --target claude --package ycc-agents
assert_package_rejected "npm opencode package" "package '@yandy-r/ycc-opencode' is deferred, excluded, opt-in, or not a native package" install --target opencode --package "@yandy-r/ycc-opencode"
assert_package_rejected "valid plus invalid package" "unknown package 'bogus'" install --target claude --package ycc,bogus
assert_package_rejected "valid target plus unsupported explicit target" "package 'ycc' is not available for target 'opencode'" install --target claude,opencode --package ycc
assert_package_rejected "multi-target unsupported hooks" "package 'ycc-hooks'" install --target claude,codex --package ycc-hooks
assert_package_rejected "empty package token" "--package contains an empty value" install --target claude --package "ycc,,ycc-mcp"
assert_package_rejected "missing package argument" "--package requires an argument" install --target claude --package
assert_package_rejected "--package with --intent" "--package cannot be combined with --intent, --only, --settings, --rules, --mcp, or --hooks" install --target claude --package ycc --intent settings
assert_package_rejected "--package with --only" "--package cannot be combined with --intent, --only, --settings, --rules, --mcp, or --hooks" install --target claude --package ycc --only base
for flag in --settings --rules --mcp --hooks; do
    assert_package_rejected "--package with ${flag}" "--package cannot be combined with --intent, --only, --settings, --rules, --mcp, or --hooks" install --target claude --package ycc "${flag}"
done
assert_package_rejected "sync --package" "--package is only supported by the 'install' subcommand" sync --target claude --intent settings --package ycc
assert_package_rejected "remove --package" "--package is only supported by the 'install' subcommand" remove --target claude --only base --package ycc
assert_package_rejected "cli --package" "--package is only supported by the 'install' subcommand" cli --package ycc
assert_package_rejected "completion --package" "--package is only supported by the 'install' subcommand" completion --shell bash --package ycc
assert_package_rejected "list-mcps --package" "--package is only supported by the 'install' subcommand" list-mcps --package ycc

# Package runs keep settings global even though unscoped settings default to the project.
for target in claude codex cursor; do
    home="$(new_home)"
    install_must_succeed "${home}" install --target "${target}" --package ycc,ycc-mcp --skills-home native
    case "${target}" in
        claude) global_dest="${home}/.claude/settings.json"; project_dest="${home}/project/.claude/settings.json" ;;
        codex) global_dest="${home}/.codex/config.toml"; project_dest="${home}/project/.codex/config.toml" ;;
        # ycc-mcp still writes project MCP config; only the settings destination stays global.
        cursor) global_dest="${home}/.cursor/cli-config.json"; project_dest="${home}/project/.cursor/cli-config.json" ;;
    esac
    if [[ -f "${global_dest}" ]]; then ok "${target} package run keeps settings global"; else ko "${target} package run keeps settings global" "${INSTALL_OUT}"; fi
    if [[ "${target}" == codex ]]; then
        assert_not_contains "$(cat "${project_dest}" 2>/dev/null)" 'model = "gpt-6-astra"' "codex package project MCP file carries no settings"
    elif [[ ! -e "${project_dest}" ]]; then
        ok "${target} package run writes no project settings"
    else
        ko "${target} package run writes no project settings"
    fi
done

# Explicit failures leave a pre-existing environment untouched too (not only empty HOMEs).
home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings --global
before="$(tree_snapshot "${home}")"
out="$(run_install "${home}" install --target claude,opencode --package ycc)" && rc=0 || rc=$?
after="$(tree_snapshot "${home}")"
if [[ ${rc} -ne 0 && "${before}" == "${after}" ]]; then ok "rejected package install leaves an existing HOME untouched"; else ko "rejected package install leaves an existing HOME untouched" "rc=${rc} ${out}"; fi

echo
echo "== --package completions =="

for f in _ycc ycc.bash ycc.fish; do
    assert_contains "$(cat "${REPO_ROOT}/scripts/completions/${f}")" "ycc ycc-mcp ycc-hooks ycc-rules" "${f} lists the installable package ids"
    assert_not_contains "$(grep -- '--package\|package' "${REPO_ROOT}/scripts/completions/${f}")" "ycc-all" "${f} keeps ycc-all out of --package"
    assert_not_contains "$(grep -- 'package' "${REPO_ROOT}/scripts/completions/${f}")" "installer-fallback" "${f} keeps installer-fallback out of --package"
done
out="$(bash -c 'source "$1"; COMP_WORDS=(ycc install --package ycc-m); COMP_CWORD=3; _ycc; echo "${COMPREPLY[*]}"' \
    _ "${REPO_ROOT}/scripts/completions/ycc.bash")"
assert_contains "${out}" "ycc-mcp" "bash completes package ids for install"
out="$(bash -c 'source "$1"; COMP_WORDS=(ycc install --package ycc,ycc-h); COMP_CWORD=3; _ycc; echo "${COMPREPLY[*]}"' \
    _ "${REPO_ROOT}/scripts/completions/ycc.bash")"
assert_contains "${out}" "ycc,ycc-hooks" "bash completes package CSV items"
out="$(bash -c 'source "$1"; COMP_WORDS=(ycc install --pack); COMP_CWORD=2; _ycc; echo "${COMPREPLY[*]}"' \
    _ "${REPO_ROOT}/scripts/completions/ycc.bash")"
assert_contains "${out}" "--package" "bash completes the --package flag for install"
for sub in sync remove; do
    out="$(bash -c 'source "$1"; COMP_WORDS=(ycc "$2" --pack); COMP_CWORD=2; _ycc; echo "${COMPREPLY[*]}"' \
        _ "${REPO_ROOT}/scripts/completions/ycc.bash" "${sub}")"
    assert_not_contains "${out}" "--package" "bash keeps --package out of ${sub}"
    out="$(bash -c 'source "$1"; COMP_WORDS=(ycc "$2" --package ycc-m); COMP_CWORD=3; _ycc; echo "${COMPREPLY[*]}"' \
        _ "${REPO_ROOT}/scripts/completions/ycc.bash" "${sub}")"
    assert_not_contains "${out}" "ycc-mcp" "bash offers no package ids for ${sub}"
done

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
