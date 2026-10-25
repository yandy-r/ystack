#!/usr/bin/env bash
# install.sh tests — claude: settings merge, mods, local edits, remove, slices.
#
# Runs alone (bash scripts/tests/install/claude.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== install.sh sync: claude settings merge =="

home="$(new_home)"
cat > "${home}/.claude/settings.json" <<'JSON'
{
  "tui": "fullscreen",
  "editorMode": "vim",
  "env": { "MY_LOCAL_TOKEN": "keep-me" }
}
JSON
install_must_succeed "${home}" sync --target claude --intent settings
out="${INSTALL_OUT}"
merged="$(cat "${home}/.claude/settings.json")"
assert_contains "${merged}" '"editorMode": "vim"' "unmanaged local key preserved"
assert_contains "${merged}" '"MY_LOCAL_TOKEN": "keep-me"' "unmanaged env leaf preserved"
assert_contains "${merged}" '"claude-fable-5-1"' "managed model applied"
assert_contains "${merged}" '"CLAUDE_CODE_SUBAGENT_MODEL": "opus[1m]"' "subagent model applied"

# The marketplace entry the Claude CLI writes must survive a settings sync;
# this is the regression the old copy-based flow could not avoid.
home="$(new_home)"
cat > "${home}/.claude/settings.json" <<'JSON'
{
  "extraKnownMarketplaces": {
    "cli-written": { "source": { "source": "github", "repo": "someone/else" } }
  }
}
JSON
install_must_succeed "${home}" sync --target claude --intent settings,plugins
merged="$(cat "${home}/.claude/settings.json")"
assert_contains "${merged}" '"cli-written"' "CLI-written marketplace entry preserved"
assert_contains "${merged}" '"ycc"' "repo marketplace entry added"

echo
echo "== install.sh sync: claude mods =="

home="$(new_home)"
install_must_succeed_stubbed "${home}" sync --target claude --intent mods
out="${INSTALL_OUT}"
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_contains "${calls}" "plugin marketplace add $(realpath "${REPO_ROOT}/ycc/mods") --scope user" "mods registers the ycc-mods marketplace from the checkout"
assert_contains "${calls}" "plugin install status-bar@ycc-mods --scope user" "mods installs each listed mod"
assert_not_contains "${calls}" "ycc@ycc" "mods does not run base"
assert_not_contains "${out}" "merge settings" "mods does not merge settings"
assert_contains "${out}" "Claude sync complete" "mods sync completes"

home="$(new_home)"
cat > "${home}/.claude/settings.json" <<'JSON'
{ "env": { "CLAUDE_CODE_PLUGIN_DIRS": "~/.claude/mods/status-bar" } }
JSON
install_must_succeed_stubbed "${home}" sync --target claude --intent mods
out="${INSTALL_OUT}"
assert_contains "${out}" "also loads a 'status-bar' folder" "sideloaded copy of a mod is flagged"

home="$(new_home)"
install_must_succeed_stubbed "${home}" sync --target codex,cursor,opencode --intent mods
out="${INSTALL_OUT}"
assert_contains "${out}" "intent 'mods' is not supported by target 'codex'" "codex mods is a no-op"
assert_contains "${out}" "intent 'mods' is not supported by target 'opencode'" "opencode mods is a no-op"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin" "non-claude targets never call the claude CLI"

home="$(new_home)"
install_must_succeed_stubbed "${home}" install --target claude --only mods
out="${INSTALL_OUT}"
assert_not_contains "${out}" "is not valid for target 'claude'" "--only mods is valid for claude"
assert_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "status-bar@ycc-mods" "install --only mods installs the mods"

echo
echo "== install.sh sync: local edits are respected =="

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings
python3 - "${home}/.claude/settings.json" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
data["model"] = "my-own-model"
p.write_text(json.dumps(data, indent=2) + "\n")
PY
install_must_succeed "${home}" sync --target claude --intent settings
out="${INSTALL_OUT}"
assert_contains "${out}" "kept your local value at /model" "local edit preserved with warning"
assert_contains "$(cat "${home}/.claude/settings.json")" '"my-own-model"' "local model value intact"

install_must_succeed "${home}" sync --target claude --intent settings --force
out="${INSTALL_OUT}"
assert_contains "$(cat "${home}/.claude/settings.json")" '"claude-fable-5-1"' "--force restores repo value"

echo

echo "== install.sh sync: claude project hooks =="

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent hooks
calls="$(cat "${home}/claude-calls.log")"
assert_contains "${calls}" "plugin marketplace add ${REPO_REAL} --scope local" "local project hooks registers the machine path at local scope"
assert_contains "${calls}" "plugin install ycc-hooks@ycc --scope project" "project hooks installs the native plugin"
if [[ ! -e "${home}/.claude/settings.json" && ! -e "${home}/.claude/hooks" && ! -L "${home}/.claude/hooks" ]]; then
    ok "project hooks writes no global settings or hooks link"
else
    ko "project hooks writes no global settings or hooks link"
fi

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent hooks --mode repo
assert_contains "$(cat "${home}/claude-calls.log")" "plugin marketplace add yandy-r/ystack --scope project" "repo project hooks registers the portable source at project scope"

for marketplace_output in '[]' 'not JSON'; do
    home="$(new_home)"
    if [[ "${marketplace_output}" == '[]' ]]; then
        CLAUDE_STUB_MARKETPLACES_STATUS=1 install_must_succeed "${home}" sync --target claude --intent hooks
    else
        CLAUDE_STUB_MARKETPLACES="${marketplace_output}" install_must_succeed "${home}" sync --target claude --intent hooks
    fi
    calls="$(cat "${home}/claude-calls.log")"
    assert_not_contains "${calls}" "plugin marketplace add" "unreadable marketplace list never declares ycc (${marketplace_output})"
    assert_not_contains "${calls}" "plugin install" "unreadable marketplace list skips the install (${marketplace_output})"
    assert_contains "${INSTALL_OUT}" "marketplace list could not be read" "unreadable marketplace list warns (${marketplace_output})"
    assert_contains "${INSTALL_OUT}" "Skipped the plugin install" "unreadable marketplace list explains the skip (${marketplace_output})"
done

# Two projects, one machine: project A's settings.local.json declaration is
# what the machine list shows as registered; this project (B) is undeclared,
# so it adds its own declaration instead of borrowing A's invisibly.
home="$(new_home)"
CLAUDE_STUB_MARKETPLACES="[{\"name\":\"ycc\",\"source\":\"directory\",\"path\":\"${REPO_REAL}\"}]" \
    install_must_succeed "${home}" sync --target claude --intent hooks
calls="$(cat "${home}/claude-calls.log")"
assert_contains "${calls}" "plugin marketplace add ${REPO_REAL} --scope local" "another project's registration does not satisfy this project's declaration"
assert_contains "${calls}" "plugin install ycc-hooks@ycc --scope project" "a same-source registration still installs ycc-hooks"

# A registration from a different source must not be repointed by declaring it.
home="$(new_home)"
CLAUDE_STUB_MARKETPLACES='[{"name":"ycc","source":"directory","path":"/fork/ystack"}]' \
    install_must_succeed "${home}" sync --target claude --intent hooks
calls="$(cat "${home}/claude-calls.log")"
assert_not_contains "${calls}" "plugin marketplace add" "a foreign-source registration is never repointed"
assert_not_contains "${calls}" "plugin install" "a foreign-source registration skips the install"
assert_contains "${INSTALL_OUT}" "registered from a different source" "a foreign-source registration warns"
assert_contains "${INSTALL_OUT}" "Skipped the plugin install" "a foreign-source registration explains the skip"

# A committed pinned declaration is reused, never repointed, while the machine
# registration is live: no add runs, and remove keeps the declaration (the pin
# makes it user-owned).
home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "github", "repo": "yandy-r/ystack", "ref": "v6.1.0" } } }, "enabledPlugins": { "ycc-hooks@ycc": true } }
JSON
CLAUDE_STUB_MARKETPLACES='[{"name":"ycc","source":"github","repo":"yandy-r/ystack","ref":"v6.1.0"}]' \
    install_must_succeed "${home}" sync --target claude --intent hooks
calls="$(cat "${home}/claude-calls.log")"
assert_not_contains "${calls}" "plugin marketplace add" "a pinned project declaration is never rewritten"
assert_contains "${calls}" "plugin install ycc-hooks@ycc --scope project" "a pinned project declaration still installs ycc-hooks"
assert_contains "${INSTALL_OUT}" "reusing the ycc marketplace declared in project settings" "a pinned project declaration is reused"
install_must_succeed "${home}" remove --target claude --intent hooks
assert_not_contains "$(cat "${home}/claude-calls.log")" "plugin marketplace remove" "remove keeps a pinned (ref) project declaration"

# A fresh clone: the committed pinned declaration is visible but the CLI has no
# registration yet, so it is registered from the declaration's own source,
# ref and scope (adding never rewrites the file).
home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "github", "repo": "yandy-r/ystack", "ref": "v6.1.0" } } } }
JSON
install_must_succeed "${home}" sync --target claude --intent hooks
calls="$(cat "${home}/claude-calls.log")"
assert_contains "${calls}" "plugin marketplace add yandy-r/ystack#v6.1.0 --scope project" "a pinned project declaration with no registration is registered from its own source"
assert_contains "${calls}" "plugin install ycc-hooks@ycc --scope project" "a registered pinned declaration installs ycc-hooks"

# Other declaration shapes rebuild their own source; unknown shapes skip.
home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.local.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "directory", "path": "/fork/ystack" } } } }
JSON
install_must_succeed "${home}" sync --target claude --intent hooks
assert_contains "$(cat "${home}/claude-calls.log")" "plugin marketplace add /fork/ystack --scope local" "a local directory declaration is registered from its own path"

home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "git", "url": "https://example.com/ystack.git", "ref": "main" } } } }
JSON
install_must_succeed "${home}" sync --target claude --intent hooks
assert_contains "$(cat "${home}/claude-calls.log")" "plugin marketplace add https://example.com/ystack.git#main --scope project" "a git declaration is registered from its own url and ref"

home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "settings", "plugins": [] } } } }
JSON
install_must_succeed "${home}" sync --target claude --intent hooks
calls="$(cat "${home}/claude-calls.log")"
assert_not_contains "${calls}" "plugin marketplace add" "an unrecognised declaration shape is never re-registered"
assert_not_contains "${calls}" "plugin install" "an unrecognised declaration shape skips the install"
assert_contains "${INSTALL_OUT}" "cannot re-register" "an unrecognised declaration shape warns"

# A pinned registration is not the installer's unpinned source: an undeclared
# project must not repoint it.
home="$(new_home)"
CLAUDE_STUB_MARKETPLACES='[{"name":"ycc","source":"github","repo":"yandy-r/ystack","ref":"v6.1.0"}]' \
    install_must_succeed "${home}" sync --target claude --intent hooks --mode repo
calls="$(cat "${home}/claude-calls.log")"
assert_not_contains "${calls}" "plugin marketplace add" "a pinned registration is never repointed"
assert_not_contains "${calls}" "plugin install" "a pinned registration skips the install"
assert_contains "${INSTALL_OUT}" "registered from a different source" "a pinned registration warns"

# A user-scope declaration (the settings merge writes one) is not a
# registration: settings,hooks on a fresh home still adds and installs.
home="$(new_home)"
install_must_succeed "${home}" install --target claude --only settings,hooks
calls="$(cat "${home}/claude-calls.log")"
assert_contains "${calls}" "plugin marketplace add ${REPO_REAL} --scope local" "settings,hooks on a fresh home registers the marketplace"
assert_contains "${calls}" "plugin install ycc-hooks@ycc --scope project" "settings,hooks on a fresh home installs ycc-hooks"

# The machine registration can vanish while this project still declares ycc
# (another project's remove does that): an installer-shaped declaration is
# re-added at its own scope, which re-registers the machine without rewriting
# the file. A fresh clone with the committed project declaration heals too.
for mode_args in "" "--mode repo"; do
    home="$(new_home)"
    mkdir -p "${home}/project/.claude"
    if [[ -z "${mode_args}" ]]; then
        printf '{"extraKnownMarketplaces":{"ycc":{"source":{"source":"directory","path":"%s"}}}}\n' "${REPO_REAL}" \
            > "${home}/project/.claude/settings.local.json"
        expected="plugin marketplace add ${REPO_REAL} --scope local"
    else
        printf '{"extraKnownMarketplaces":{"ycc":{"source":{"source":"github","repo":"yandy-r/ystack"}}}}\n' \
            > "${home}/project/.claude/settings.json"
        expected="plugin marketplace add yandy-r/ystack --scope project"
    fi
    install_must_succeed "${home}" sync --target claude --intent hooks ${mode_args}
    calls="$(cat "${home}/claude-calls.log")"
    assert_contains "${calls}" "${expected}" "an owned declaration with no machine registration re-registers (${mode_args:-local mode})"
    assert_contains "${calls}" "plugin install ycc-hooks@ycc --scope project" "re-registration still installs ycc-hooks (${mode_args:-local mode})"
done

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings,hooks
merged="$(cat "${home}/.claude/settings.json")"
assert_contains "${merged}" '"claude-fable-5-1"' "settings still merge beside project hooks"
assert_not_contains "${merged}" '"hooks"' "project hooks writes no global hook activation"

home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "enabledPlugins": { "ycc-hooks@ycc": true } }
JSON
install_must_succeed "${home}" remove --target claude --intent hooks
calls="$(cat "${home}/claude-calls.log")"
assert_contains "${calls}" "plugin uninstall ycc-hooks@ycc --scope project" "project hooks remove without a project declaration uninstalls only the plugin"
assert_not_contains "${calls}" "plugin marketplace remove ycc --scope project" "project hooks remove leaves a user-scope marketplace declaration alone"

home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "github", "repo": "yandy-r/ystack" } } }, "enabledPlugins": { "ycc-hooks@ycc": true } }
JSON
install_must_succeed "${home}" remove --target claude --intent hooks
calls="$(cat "${home}/claude-calls.log")"
assert_contains "${calls}" "plugin uninstall ycc-hooks@ycc --scope project" "project hooks remove uninstalls the native plugin"
assert_contains "${calls}" "plugin marketplace remove ycc --scope project" "project hooks remove retracts its unused marketplace"

home="$(new_home)"
mkdir -p "${home}/project/.claude"
printf '{"extraKnownMarketplaces":{"ycc":{"source":{"source":"directory","path":"%s"}}}}\n' "${REPO_REAL}" > "${home}/project/.claude/settings.local.json"
install_must_succeed "${home}" remove --target claude --intent hooks
assert_contains "$(cat "${home}/claude-calls.log")" "plugin marketplace remove ycc --scope local" "project hooks remove retracts its matching local declaration"

# Removing the declaration drops the CLI's machine-wide registration, so a
# ycc install in another project (or at user scope) keeps it in place.
home="$(new_home)"
mkdir -p "${home}/project/.claude" "${home}/.claude/plugins"
printf '{"extraKnownMarketplaces":{"ycc":{"source":{"source":"directory","path":"%s"}}}}\n' "${REPO_REAL}" > "${home}/project/.claude/settings.local.json"
printf '{"version":2,"plugins":{"ycc-hooks@ycc":[{"scope":"project","projectPath":"%s/project"},{"scope":"project","projectPath":"/other/project"}]}}\n' \
    "$(cd "${home}" && pwd -P)" > "${home}/.claude/plugins/installed_plugins.json"
install_must_succeed "${home}" remove --target claude --intent hooks
assert_not_contains "$(cat "${home}/claude-calls.log")" "plugin marketplace remove" "project hooks remove keeps the marketplace another project's install still uses"
assert_contains "${INSTALL_OUT}" "other ycc installs still use it: ycc-hooks@ycc (/other/project)" "project hooks remove names the install that keeps the marketplace"

home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.local.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "directory", "path": "/foreign/checkout" } } } }
JSON
install_must_succeed "${home}" remove --target claude --intent hooks
assert_not_contains "$(cat "${home}/claude-calls.log")" "plugin marketplace remove" "project hooks remove preserves a foreign local directory declaration"
assert_contains "${INSTALL_OUT}" "source does not match the installer source" "foreign declaration retention explains ownership"

home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "git", "url": "https://github.com/yandy-r/ystack.git" } } } }
JSON
install_must_succeed "${home}" remove --target claude --intent hooks
assert_not_contains "$(cat "${home}/claude-calls.log")" "plugin marketplace remove" "project hooks remove keeps a git-url declaration it never wrote"
assert_contains "${INSTALL_OUT}" "source does not match the installer source" "git-url declaration retention explains ownership"

home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "github", "repo": "yandy-r/ystack" } } } }
JSON
cat > "${home}/project/.claude/settings.local.json" <<'JSON'
{ "enabledPlugins": { "another@ycc": true } }
JSON
install_must_succeed "${home}" remove --target claude --intent hooks
assert_not_contains "$(cat "${home}/claude-calls.log")" "plugin marketplace remove" "locally enabled plugin retains the project marketplace"
assert_contains "${INSTALL_OUT}" "other ycc plugins are still enabled: another@ycc" "local plugin retention explains its dependency"

home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "github", "repo": "yandy-r/ystack" } } }, "enabledPlugins": { "ycc-hooks@ycc": true, "ycc@ycc": true } }
JSON
install_must_succeed "${home}" remove --target claude --intent hooks
calls="$(cat "${home}/claude-calls.log")"
assert_contains "${calls}" "plugin uninstall ycc-hooks@ycc --scope project" "project hooks remove leaves other ycc plugins alone"
assert_not_contains "${calls}" "plugin marketplace remove ycc --scope project" "project hooks keeps a marketplace another plugin uses"
assert_contains "${INSTALL_OUT}" "other ycc plugins are still enabled" "project hooks explains marketplace retention"

home="$(new_home)"
out="$(run_install "${home}" sync --target claude --intent hooks --hooks WorktreeCreate)"
assert_contains "${out}" "--hooks <events> narrows settings.json hook events" "project hooks rejects event selection"
assert_contains "${out}" "use --global, or drop --hooks" "project hooks selection error suggests global scope"
if [[ ! -e "${home}/.claude/settings.json" && ! -e "${home}/.claude/hooks" && ! -e "${home}/project/.claude" && ! -e "${home}/claude-calls.log" ]]; then
    ok "project hooks selection rejection writes nothing and calls no CLI"
else
    ko "project hooks selection rejection writes nothing and calls no CLI"
fi

home="$(new_home)"
out="$(CLAUDE_STUB_VERSION='2.1.200 (Claude Code)' run_install "${home}" sync --target claude --intent hooks)"
assert_contains "${out}" "ycc-hooks needs Claude Code 2.1.300 or later (found 2.1.200)" "project hooks rejects an old Claude CLI"
if [[ ! -e "${home}/.claude/settings.json" && ! -e "${home}/.claude/hooks" && ! -e "${home}/project/.claude" ]]; then
    ok "old Claude CLI rejection writes nothing"
else
    ko "old Claude CLI rejection writes nothing"
fi
home="$(new_home)"
CLAUDE_STUB_VERSION='2.1.200 (Claude Code)' install_must_succeed "${home}" sync --target all --intent hooks
assert_contains "${INSTALL_OUT}" "Skipping Claude project hooks: ycc-hooks needs Claude Code 2.1.300" "all-target sync warns and skips old Claude project hooks"
assert_contains "${INSTALL_OUT}" "Cursor sync complete" "all-target sync still completes other targets with old Claude"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin install ycc-hooks" "all-target old Claude does not install project hooks"
CLAUDE_STUB_VERSION='2.1.200 (Claude Code)' install_must_succeed "${home}" remove --target all --intent hooks
assert_contains "${INSTALL_OUT}" "Skipping Claude project hooks: ycc-hooks needs Claude Code 2.1.300" "all-target remove warns and skips old Claude project hooks"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin uninstall ycc-hooks" "all-target old Claude does not uninstall project hooks"


# run_install starts below HOME; exercise the same installer from HOME itself
# to verify the default and explicit project-scope guard before any writes.
home="$(new_home)"
for scope_flag in "" "--project"; do
    out="$(
        cd "${home}" || exit 1
        HOME="${home}" PATH="${STUB_BIN}:${PATH}" CLAUDE_STUB_LOG="${home}/claude-calls.log" \
            YCC_INSTALL_SKIP_BUILD=1 bash "${INSTALL}" sync --target claude --intent hooks ${scope_flag} 2>&1
    )"
    assert_contains "${out}" "--project at \$HOME: claude project scope needs a project directory" "project hooks rejects HOME ${scope_flag:-by default}"
done
if [[ ! -e "${home}/.claude/settings.json" && ! -e "${home}/.claude/hooks" && ! -e "${home}/claude-calls.log" ]]; then
    ok "HOME rejection writes nothing and calls no CLI"
else
    ko "HOME rejection writes nothing and calls no CLI"
fi

home="$(new_home)"
ln -s "${REPO_ROOT}/ycc/settings/hooks" "${home}/.claude/hooks"
install_must_succeed "${home}" sync --target claude --intent hooks
assert_contains "${INSTALL_OUT}" "WorktreeCreate would run twice" "project hooks warns about a global hooks link"
assert_contains "${INSTALL_OUT}" "remove --target claude --intent hooks --global" "project hooks warning gives the global removal command"
if [[ -L "${home}/.claude/hooks" && ! -e "${home}/.claude/settings.json" ]]; then
    ok "project hooks leaves the global hooks link and settings untouched"
else
    ko "project hooks leaves the global hooks link and settings untouched"
fi
install_must_succeed "${home}" remove --target claude --intent hooks
assert_contains "${INSTALL_OUT}" "global installer-managed hooks are still active" "project hooks removal warns about global hooks left active"
assert_contains "${INSTALL_OUT}" "remove --target claude --intent hooks --global" "project hooks removal gives the global removal command"


home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent hooks --global
install_must_succeed "${home}" remove --target claude --only settings
assert_not_contains "$(cat "${home}/.claude/settings.json" 2>/dev/null)" '"hooks"' "settings-only removal still takes legacy hook activation"

home="$(new_home)"
out="$(CLAUDE_STUB_VERSION='2.1.200 (Claude Code)' run_install "${home}" sync --target claude --intent hooks --dry-run)"
assert_not_contains "${out}" "ycc-hooks needs Claude Code" "project hooks dry-run skips the Claude version check"
assert_contains "${out}" "dry-run: claude hooks step has no preview" "project hooks dry-run skips the native install"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin install" "project hooks dry-run calls no native install"

echo "== install.sh remove: settings, rules, hooks, plugins =="

home="$(new_home)"
cat > "${home}/.claude/settings.json" <<'JSON'
{ "editorMode": "vim", "env": { "MY_LOCAL_TOKEN": "keep-me" } }
JSON
install_must_succeed "${home}" sync --target claude --intent settings,rules,hooks,plugins --global
install_must_succeed "${home}" remove --target claude --intent settings,rules,hooks,plugins --global
out="${INSTALL_OUT}"
assert_contains "${out}" "Claude remove complete" "claude remove of every config intent completes"
merged="$(cat "${home}/.claude/settings.json")"
assert_contains "${merged}" '"editorMode": "vim"' "claude remove keeps unmanaged keys"
assert_contains "${merged}" '"MY_LOCAL_TOKEN": "keep-me"' "claude remove keeps unmanaged env leaf"
assert_not_contains "${merged}" '"claude-fable-5-1"' "claude remove drops managed model"
assert_not_contains "${merged}" '"pluginMarketplaces"' "claude remove takes back appended list items"
assert_not_contains "${merged}" '"hooks"' "claude remove drops managed hooks"
for f in CLAUDE.md AGENTS.md hooks statusline-command.sh; do
    if [[ ! -e "${home}/.claude/${f}" && ! -L "${home}/.claude/${f}" ]]; then ok "claude remove cleans ~/.claude/${f}"; else ko "claude remove cleans ~/.claude/${f}"; fi
done

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings,plugins
python3 - "${home}/.claude/settings.json" <<'PY2'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
data["model"] = "my-own-model"
p.write_text(json.dumps(data, indent=2) + "\n")
PY2
install_must_succeed "${home}" remove --target claude --intent settings
out="${INSTALL_OUT}"
assert_contains "${out}" "kept your local value at /model" "remove keeps an edited managed value"
assert_contains "$(cat "${home}/.claude/settings.json")" '"enabledPlugins"' "remove --intent settings leaves the plugins group"
install_must_succeed "${home}" remove --target claude --intent settings,plugins --force
if [[ ! -e "${home}/.claude/settings.json" ]]; then ok "remove --force takes edited values too"; else ko "remove --force takes edited values too" "$(cat "${home}/.claude/settings.json")"; fi

home="$(new_home)"
echo "# mine" > "${home}/.claude/CLAUDE.md"
echo "custom" > "${home}/.claude/statusline-command.sh"
install_must_succeed "${home}" remove --target claude --intent rules,settings --force
out="${INSTALL_OUT}"
assert_contains "$(cat "${home}/.claude/CLAUDE.md")" "# mine" "remove never deletes a real rules file"
assert_contains "${out}" "not installed by ycc" "remove reports foreign rules file"
if [[ ! -e "${home}/.claude/statusline-command.sh" ]]; then ok "remove --force takes an edited statusline"; else ko "remove --force takes an edited statusline"; fi

home="$(new_home)"
echo "custom" > "${home}/.claude/statusline-command.sh"
install_must_succeed "${home}" remove --target claude --intent settings
out="${INSTALL_OUT}"
assert_contains "${out}" "kept ${home}/.claude/statusline-command.sh" "remove keeps an edited statusline"

echo "== install.sh remove: base and mods =="


home="$(new_home)"
install_must_succeed_stubbed "${home}" remove --target claude --intent base,mods
out="${INSTALL_OUT}"
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_contains "${calls}" "plugin uninstall ycc@ycc --scope user" "claude base remove uninstalls ycc"
assert_contains "${calls}" "plugin marketplace remove ycc --scope user" "claude base remove drops the ycc marketplace"
assert_contains "${calls}" "plugin uninstall status-bar@ycc-mods --scope user" "claude mods remove uninstalls each mod"
assert_contains "${calls}" "plugin marketplace remove ycc-mods --scope user" "claude mods remove drops the ycc-mods marketplace"
assert_contains "${out}" "Claude remove complete" "claude base/mods remove completes"

# Base installs are simulated (copies + links shaped like the real step) so
# the test never runs the generators.
echo "== install.sh: skills / agents / commands slices =="

# Claude slices need no generation, so they run for real in the sandbox.
home="$(new_home)"
mkdir -p "${home}/.claude/skills/my-own-skill"
install_must_succeed "${home}" install --target claude --only skills,agents,commands
out="${INSTALL_OUT}"
assert_not_contains "${out}" "register repo checkout" "claude slices do not run base"
for d in skills/git-workflow skills/clean skills/_shared agents/codebase-advisor.md; do
    if [[ -e "${home}/.claude/${d}" ]]; then ok "claude slice installs ~/.claude/${d}"; else ko "claude slice installs ~/.claude/${d}"; fi
done
if [[ ! -e "${home}/.claude/commands" ]]; then ok "claude commands slice installs no wrapper files"; else ko "claude commands slice installs no wrapper files"; fi
assert_contains "$(grep -c 'install standalone' <<<"${out}")" "2" "claude skills+commands install skills once (plus agents)"
if [[ ! -e "${home}/.claude/plugins" ]]; then ok "claude slices register no plugin"; else ko "claude slices register no plugin"; fi
skill="$(cat "${home}/.claude/skills/git-workflow/SKILL.md")"
assert_not_contains "${skill}" 'CLAUDE_PLUGIN_ROOT}/skills' "claude slice rewrites plugin-root paths"
assert_contains "${skill}" "${home}/.claude/skills/" "claude slice points paths at ~/.claude/skills"
assert_not_contains "$(cat "${home}/.claude/skills/clean/SKILL.md")" '/ycc:clean' "claude slice strips the ycc: namespace"
assert_contains "$(cat "${home}/.claude/skills/releaser/SKILL.md")" 'disable-model-invocation: true' "claude slice retains releaser manual invocation policy"
assert_not_contains "$(cat "${home}/.claude/skills/init/SKILL.md")" 'disable-model-invocation' "claude slice keeps init model-invocable"
if [[ -d "${home}/.claude/skills/my-own-skill" ]]; then ok "claude slice leaves user skills alone"; else ko "claude slice leaves user skills alone"; fi
install_must_succeed "${home}" install --target claude --only skills
out="${INSTALL_OUT}"
assert_contains "${out}" "entries up to date" "claude slice rerun is idempotent"

home="$(new_home)"
mkdir -p "${home}/.claude/skills/git-workflow" && echo "# mine" > "${home}/.claude/skills/git-workflow/SKILL.md"
out="$(run_install "${home}" install --target claude --only skills)"
assert_contains "${out}" "refusing to replace ${home}/.claude/skills/git-workflow" "claude slice refuses a foreign entry"
assert_contains "$(cat "${home}/.claude/skills/git-workflow/SKILL.md")" "# mine" "claude slice keeps the foreign entry"
install_must_succeed "${home}" install --target claude --only skills --force
assert_not_contains "$(cat "${home}/.claude/skills/git-workflow/SKILL.md")" "# mine" "claude slice --force replaces it"

install_must_succeed "${home}" remove --target claude --intent skills
if [[ ! -e "${home}/.claude/skills" ]]; then ok "claude skills remove takes back every entry"; else ko "claude skills remove takes back every entry" "$(ls "${home}/.claude/skills")"; fi

home="$(new_home)"
install_must_succeed "${home}" sync --target codex --intent commands
out="${INSTALL_OUT}"
assert_contains "${out}" "intent 'commands' is not supported by target 'codex'" "codex skips commands intent"
assert_not_contains "${out}" "Generate" "unsupported commands intent generates nothing"

home="$(new_home)"
install_must_succeed "${home}" install --target claude,cursor --only skills,commands --skills-home native
if [[ -e "${home}/.claude/skills/clean" && -e "${home}/.cursor/commands/clean.md" ]]; then ok "install --only commands runs on both supported targets"; else ko "install --only commands runs on both supported targets" "${INSTALL_OUT}"; fi

# Legacy wrappers: only names recorded in installed-units.json are retired,
# and only after the skills install succeeded.
echo "== install.sh: legacy claude command wrappers =="

legacy_home() {
    local h
    h="$(new_home)"
    mkdir -p "${h}/.claude/commands" "${h}/.config/ycc"
    echo "wrapper" > "${h}/.claude/commands/clean.md"
    echo "mine" > "${h}/.claude/commands/my-own.md"
    echo "mine too" > "${h}/.claude/commands/plan.md"   # unrecorded, same name as a skill
    printf '{"version": 1, "units": {"%s/.claude/commands": ["clean.md", "../escape.md"]}}\n' "${h}" \
        > "${h}/.config/ycc/installed-units.json"
    echo "outside" > "${h}/.claude/escape.md"
    echo "${h}"
}

home="$(legacy_home)"
install_must_succeed "${home}" install --target claude --only commands
out="${INSTALL_OUT}"
assert_contains "${out}" "retired 1 legacy command wrapper" "commands install retires recorded wrappers"
if [[ ! -e "${home}/.claude/commands/clean.md" ]]; then ok "recorded wrapper removed"; else ko "recorded wrapper removed"; fi
assert_contains "$(cat "${home}/.claude/commands/my-own.md" "${home}/.claude/commands/plan.md")" "mine too" "unrecorded command files kept"
if [[ -e "${home}/.claude/escape.md" ]]; then ok "recorded path traversal ignored"; else ko "recorded path traversal ignored"; fi
if [[ -e "${home}/.claude/skills/clean/SKILL.md" ]]; then ok "skills installed by commands alias"; else ko "skills installed by commands alias"; fi
assert_not_contains "$(cat "${home}/.config/ycc/installed-units.json")" ".claude/commands" "state forgets retired wrapper dir"

home="$(legacy_home)"
mkdir -p "${home}/.claude/skills/clean" && echo "# mine" > "${home}/.claude/skills/clean/SKILL.md"
out="$(run_install "${home}" install --target claude --only skills)"
assert_contains "${out}" "refusing to replace" "skills conflict reported"
if [[ -e "${home}/.claude/commands/clean.md" ]]; then ok "no wrapper cleanup after failed skills install"; else ko "no wrapper cleanup after failed skills install"; fi

home="$(legacy_home)"
rm -f "${home}/.claude/commands/my-own.md" "${home}/.claude/commands/plan.md"
install_must_succeed "${home}" install --target claude --only skills
if [[ ! -e "${home}/.claude/commands" ]]; then ok "emptied legacy commands dir removed"; else ko "emptied legacy commands dir removed"; fi

home="$(legacy_home)"
install_must_succeed "${home}" remove --target claude --only commands
out="${INSTALL_OUT}"
if [[ ! -e "${home}/.claude/commands/clean.md" && -e "${home}/.claude/commands/my-own.md" ]]; then ok "commands remove retires only recorded wrappers"; else ko "commands remove retires only recorded wrappers" "${out}"; fi

home="$(legacy_home)"
install_must_succeed "${home}" install --target claude --only agents
out="${INSTALL_OUT}"
if [[ -e "${home}/.claude/commands/clean.md" ]]; then ok "agents-only install leaves wrappers"; else ko "agents-only install leaves wrappers" "${out}"; fi
assert_contains "$(cat "${home}/.config/ycc/installed-units.json")" ".claude/commands" "agents-only install keeps wrapper state"

# A recorded name that is now a directory is user data: never removed.
home="$(legacy_home)"
rm -f "${home}/.claude/commands/clean.md"
mkdir "${home}/.claude/commands/clean.md"
echo "precious" > "${home}/.claude/commands/clean.md/user.txt"
install_must_succeed "${home}" install --target claude --only commands
out="${INSTALL_OUT}"
assert_contains "$(cat "${home}/.claude/commands/clean.md/user.txt" 2>/dev/null)" "precious" "recorded name replaced by a directory is preserved"
assert_contains "${out}" "kept ${home}/.claude/commands/clean.md: not a ycc wrapper file" "directory replacement reported"

# A recorded wrapper that is a symlink: only the link goes, never its target.
home="$(legacy_home)"
rm -f "${home}/.claude/commands/clean.md"
echo "external" > "${home}/external.md"
ln -s "${home}/external.md" "${home}/.claude/commands/clean.md"
install_must_succeed "${home}" install --target claude --only commands
if [[ ! -L "${home}/.claude/commands/clean.md" ]]; then ok "recorded symlink wrapper unlinked"; else ko "recorded symlink wrapper unlinked"; fi
assert_contains "$(cat "${home}/external.md" 2>/dev/null)" "external" "symlink wrapper target untouched"

# A symlinked commands dir is never removed or replaced; foreign files inside stay.
home="$(legacy_home)"
mv "${home}/.claude/commands" "${home}/ext-commands"
ln -s "${home}/ext-commands" "${home}/.claude/commands"
install_must_succeed "${home}" install --target claude --only commands
if [[ -L "${home}/.claude/commands" && -d "${home}/ext-commands" ]]; then ok "symlinked commands dir kept"; else ko "symlinked commands dir kept"; fi
assert_contains "$(cat "${home}/ext-commands/my-own.md" 2>/dev/null)" "mine" "symlinked commands dir keeps user files"

home="$(legacy_home)"
rm -f "${home}/.claude/commands/my-own.md" "${home}/.claude/commands/plan.md"
mv "${home}/.claude/commands" "${home}/ext-commands"
ln -s "${home}/ext-commands" "${home}/.claude/commands"
install_must_succeed "${home}" install --target claude --only commands
out="${INSTALL_OUT}"
if [[ -L "${home}/.claude/commands" && -d "${home}/ext-commands" && ! -e "${home}/ext-commands/clean.md" ]]; then ok "emptied symlinked commands dir kept"; else ko "emptied symlinked commands dir kept" "${out}"; fi

# Failed unlink retention: deterministic mock-based unit test (chmod is unreliable as root).
if out="$(python3 "${REPO_ROOT}/scripts/test_install_slices_legacy.py" 2>&1)"; then ok "failed unlink keeps name recorded, others removed"; else ko "failed unlink keeps name recorded, others removed" "${out}"; fi

# A copy the 'base' step mirrored is identical to the bundle, so a slice
# remove takes it back even without a recorded install.

echo
echo "== install.sh rules: claude links only CLAUDE.md, legacy links removable =="

home="$(new_home)"
install_must_succeed "${home}" install --target claude --only rules
if [[ -L "${home}/.claude/CLAUDE.md" && "$(readlink "${home}/.claude/CLAUDE.md")" == "${REPO_ROOT}/ycc/settings/rules/CLAUDE.md" ]]; then ok "claude rules links CLAUDE.md"; else ko "claude rules links CLAUDE.md"; fi
if [[ ! -e "${home}/.claude/AGENTS.md" && ! -L "${home}/.claude/AGENTS.md" ]]; then ok "claude rules no longer links the unread AGENTS.md"; else ko "claude rules no longer links the unread AGENTS.md"; fi

# A legacy AGENTS.md link survives install and is removed by remove; a real file never is.
home="$(new_home)"
ln -s "${REPO_ROOT}/ycc/settings/rules/AGENTS.md" "${home}/.claude/AGENTS.md"
install_must_succeed "${home}" install --target claude --only rules
if [[ -L "${home}/.claude/AGENTS.md" ]]; then ok "claude install leaves a legacy AGENTS.md link alone"; else ko "claude install leaves a legacy AGENTS.md link alone"; fi
install_must_succeed "${home}" remove --target claude --intent rules
if [[ ! -e "${home}/.claude/AGENTS.md" && ! -L "${home}/.claude/AGENTS.md" ]]; then ok "claude remove unlinks the legacy AGENTS.md link"; else ko "claude remove unlinks the legacy AGENTS.md link"; fi

home="$(new_home)"
echo "# mine" > "${home}/.claude/AGENTS.md"
install_must_succeed "${home}" remove --target claude --intent rules --force
assert_contains "$(cat "${home}/.claude/AGENTS.md" 2>/dev/null)" "# mine" "claude remove keeps a real AGENTS.md even with --force"

echo
echo "== install.sh --plugins: claude =="

# claude_plugin_keys <settings.json> — 'enabledPlugins=<keys> markets=<keys> lists=<names>' (sorted, comma-joined).
claude_plugin_keys() {
    python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
join = lambda xs: ",".join(sorted(xs))
print("enabledPlugins=" + join(d.get("enabledPlugins", {})),
      "markets=" + join(d.get("extraKnownMarketplaces", {})),
      "lists=" + join(i.get("name", "") for i in d.get("pluginMarketplaces", [])))
PY
}

home="$(new_home)"
install_must_succeed "${home}" list plugins --target claude
assert_contains $'\n'"${INSTALL_OUT}"$'\n' $'\nsuperpowers@claude-plugins-official\n' "list plugins --target claude lists enabledPlugins keys"
assert_not_contains $'\n'"${INSTALL_OUT}"$'\n' $'\nclaude-plugins-official\n' "list plugins never lists a bare marketplace"

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent plugins \
    --plugins superpowers@claude-plugins-official,context7@claude-plugins-official
assert_contains "${INSTALL_OUT}" "Plugins: superpowers@claude-plugins-official, context7@claude-plugins-official" "--plugins names the selection"
keys="$(claude_plugin_keys "${home}/.claude/settings.json")"
if [[ "${keys}" == "enabledPlugins=context7@claude-plugins-official,superpowers@claude-plugins-official markets=claude-plugins-official lists=claude-plugins-official" ]]; then
    ok "--plugins writes exactly the selected plugins plus their marketplace"
else
    ko "--plugins writes exactly the selected plugins plus their marketplace" "${keys}"
fi
assert_not_contains "$(cat "${home}/.claude/settings.json")" '"model"' "--intent plugins --plugins leaves settings alone"

install_must_succeed "${home}" remove --target claude --intent plugins --plugins context7@claude-plugins-official
keys="$(claude_plugin_keys "${home}/.claude/settings.json")"
if [[ "${keys}" == "enabledPlugins=superpowers@claude-plugins-official markets=claude-plugins-official lists=claude-plugins-official" ]]; then
    ok "remove --plugins takes one plugin and keeps the marketplace another still uses"
else
    ko "remove --plugins takes one plugin and keeps the marketplace another still uses" "${keys}"
fi

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings,plugins --plugins ycc@ycc
merged="$(cat "${home}/.claude/settings.json")"
assert_contains "${merged}" '"claude-fable-5-1"' "--intent settings,plugins --plugins still merges settings whole"
keys="$(claude_plugin_keys "${home}/.claude/settings.json")"
if [[ "${keys}" == "enabledPlugins=ycc@ycc markets=ycc lists=" ]]; then ok "--plugins ycc@ycc writes no pluginMarketplaces item"; else ko "--plugins ycc@ycc writes no pluginMarketplaces item" "${keys}"; fi

home="$(new_home)"
out="$(run_install "${home}" sync --target claude --intent settings --plugins ycc@ycc)"
assert_contains "${out}" "--plugins needs the settings step (it narrows the plugins config group; use --intent plugins, or install --only settings)" "--plugins without the plugins group rejected"
if [[ ! -e "${home}/.claude/settings.json" ]]; then ok "--plugins rejection writes nothing"; else ko "--plugins rejection writes nothing"; fi
out="$(run_install "${home}" sync --target claude --intent plugins --plugins claude-plugins-official)"
assert_contains "${out}" "unknown plugin 'claude-plugins-official'" "a marketplace name is not a plugin"
if [[ ! -e "${home}/.claude/settings.json" ]]; then ok "unknown plugin writes nothing"; else ko "unknown plugin writes nothing"; fi

echo
echo "== install.sh --mods: claude =="

# A two-mod fixture marketplace (status-bar plus a fake second mod) so the
# selection is exercised; YCC_MODS_ROOT points the installer at it.
mods_fixture="${SANDBOX_ROOT}/mods-fixture"
mkdir -p "${mods_fixture}/.claude-plugin" "${mods_fixture}/status-bar" "${mods_fixture}/pane-glow"
python3 - "${REPO_ROOT}/ycc/mods/.claude-plugin/marketplace.json" "${mods_fixture}/.claude-plugin/marketplace.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["plugins"] = [p for p in data["plugins"] if p["name"] == "status-bar"]
data["plugins"].append({"name": "pane-glow", "description": "fixture mod", "version": "0.0.1",
                        "author": {"name": "test"}, "source": "./pane-glow"})
json.dump(data, open(sys.argv[2], "w"), indent=2)
PY

home="$(new_home)"
YCC_MODS_ROOT="${mods_fixture}" install_must_succeed "${home}" list mods --target claude
if [[ "${INSTALL_OUT}" == $'status-bar\npane-glow' ]]; then ok "list mods --target claude lists the marketplace's mods"; else ko "list mods --target claude lists the marketplace's mods" "${INSTALL_OUT}"; fi
install_must_succeed "${home}" list mods --target codex,cursor,opencode,omp,agents
if [[ -z "${INSTALL_OUT}" ]]; then ok "list mods is empty for targets without a mods step"; else ko "list mods is empty for targets without a mods step" "${INSTALL_OUT}"; fi

home="$(new_home)"
YCC_MODS_ROOT="${mods_fixture}" install_must_succeed_stubbed "${home}" sync --target claude --intent mods --mods pane-glow
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_contains "${calls}" "plugin marketplace add $(realpath "${mods_fixture}") --scope user" "--mods registers the YCC_MODS_ROOT marketplace"
assert_contains "${calls}" "plugin install pane-glow@ycc-mods --scope user" "--mods installs the selected mod"
assert_not_contains "${calls}" "status-bar@ycc-mods" "--mods installs nothing else"
assert_contains "${INSTALL_OUT}" "Installed 1 mod(s)" "--mods counts only the selected mod"

home="$(new_home)"
cat > "${home}/.claude/settings.json" <<'JSON'
{ "env": { "CLAUDE_CODE_PLUGIN_DIRS": "~/.claude/mods/status-bar" } }
JSON
YCC_MODS_ROOT="${mods_fixture}" install_must_succeed_stubbed "${home}" sync --target claude --intent mods --mods pane-glow
assert_not_contains "${INSTALL_OUT}" "also loads a 'status-bar' folder" "--mods checks sideloads only for the selected mods"

home="$(new_home)"
cat > "${home}/.claude/settings.json" <<'JSON'
{ "enabledPlugins": { "status-bar@ycc-mods": true, "pane-glow@ycc-mods": true } }
JSON
YCC_MODS_ROOT="${mods_fixture}" install_must_succeed_stubbed "${home}" remove --target claude --intent mods --mods status-bar
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_contains "${calls}" "plugin uninstall status-bar@ycc-mods --scope user" "remove --mods uninstalls the selected mod"
assert_not_contains "${calls}" "pane-glow@ycc-mods" "remove --mods leaves the other mod installed"
assert_not_contains "${calls}" "plugin marketplace remove ycc-mods" "remove --mods keeps the marketplace while another mod is enabled"
assert_contains "${INSTALL_OUT}" "kept the ycc-mods marketplace" "remove --mods says why the marketplace stays"

home="$(new_home)"
cat > "${home}/.claude/settings.json" <<'JSON'
{ "enabledPlugins": { "status-bar@ycc-mods": true, "other@elsewhere": true } }
JSON
YCC_MODS_ROOT="${mods_fixture}" install_must_succeed_stubbed "${home}" remove --target claude --intent mods --mods status-bar
calls="$(cat "${home}/claude-calls.log" 2>/dev/null)"
assert_contains "${calls}" "plugin marketplace remove ycc-mods --scope user" "remove --mods drops the marketplace once no ycc mod remains"

home="$(new_home)"
out="$(run_install_stubbed "${home}" sync --target codex --intent mods --mods status-bar)"
assert_contains "${out}" "--mods needs the mods step" "--mods without a mods step rejected"
out="$(YCC_MODS_ROOT="${mods_fixture}" run_install_stubbed "${home}" sync --target claude --intent mods --mods bogus)"
assert_contains "${out}" "unknown mod 'bogus'" "unknown mod rejected"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin" "rejected --mods calls no claude CLI"

echo
echo "== install.sh --hooks: claude =="

home="$(new_home)"
install_must_succeed "${home}" list hooks --target claude
if [[ "${INSTALL_OUT}" == "WorktreeCreate" ]]; then ok "list hooks --target claude lists managed hook events"; else ko "list hooks --target claude lists managed hook events" "${INSTALL_OUT}"; fi
install_must_succeed "${home}" list hooks --target codex,cursor,opencode,omp,agents
if [[ -z "${INSTALL_OUT}" ]]; then ok "list hooks is empty for targets without a hooks group"; else ko "list hooks is empty for targets without a hooks group" "${INSTALL_OUT}"; fi

# An unselected managed event (SessionStart) with its ownership state, as an
# earlier release would have recorded it.
home="$(new_home)"
state="${home}/.config/ycc/managed-config-state.json"
mkdir -p "$(dirname "${state}")"
cat > "${home}/.claude/settings.json" <<'JSON'
{ "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "bash ~/.claude/hooks/old.sh" } ] } ] } }
JSON
printf '{ "claude-settings:%s": { "/hooks/SessionStart": { "last_applied_sha256": "pinned" } } }\n' \
    "${home}/.claude/settings.json" > "${state}"
# hook_state <state> <settings> — the recorded '/hooks/...' pointers and their sha, sorted.
hook_state() {
    python3 - "$1" "claude-settings:$2" <<'PY'
import json, sys
entry = json.load(open(sys.argv[1])).get(sys.argv[2], {})
print(" ".join(f"{k}={v.get('last_applied_sha256')}" for k, v in sorted(entry.items()) if k.startswith("/hooks/")))
PY
}
install_must_succeed "${home}" sync --target claude --intent hooks --hooks WorktreeCreate --global
assert_contains "${INSTALL_OUT}" "Hook events: WorktreeCreate" "--hooks names the selection"
merged="$(cat "${home}/.claude/settings.json")"
assert_contains "${merged}" '"WorktreeCreate"' "--hooks merges the selected event"
assert_contains "${merged}" 'old.sh' "--hooks leaves the unselected managed event alone"
assert_contains "$(hook_state "${state}" "${home}/.claude/settings.json")" "/hooks/SessionStart=pinned" "--hooks leaves the unselected event's ownership state untouched"
if [[ -L "${home}/.claude/hooks" ]]; then ok "sync --hooks links ~/.claude/hooks"; else ko "sync --hooks links ~/.claude/hooks"; fi

# A trailing slash in HOME must still find the recorded state key (the
# helper keys it by a normalised path).
install_must_succeed "${home}/" remove --target claude --intent hooks --hooks WorktreeCreate --global
merged="$(cat "${home}/.claude/settings.json")"
assert_not_contains "${merged}" '"WorktreeCreate"' "remove --hooks takes the selected event"
assert_contains "${merged}" 'old.sh' "remove --hooks keeps the unselected event"
if [[ "$(hook_state "${state}" "${home}/.claude/settings.json")" == "/hooks/SessionStart=pinned" ]]; then
    ok "remove --hooks drops only the selected event's ownership state"
else
    ko "remove --hooks drops only the selected event's ownership state" "$(hook_state "${state}" "${home}/.claude/settings.json")"
fi
if [[ -L "${home}/.claude/hooks" ]]; then ok "remove --hooks keeps the hooks link while an unselected event remains"; else ko "remove --hooks keeps the hooks link while an unselected event remains"; fi
assert_contains "${INSTALL_OUT}" "managed hook events outside --hooks still use it" "remove --hooks says why the link stays"

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent hooks --global
install_must_succeed "${home}" remove --target claude --intent hooks --hooks WorktreeCreate --global
if [[ ! -e "${home}/.claude/hooks" && ! -L "${home}/.claude/hooks" ]]; then ok "remove --hooks unlinks ~/.claude/hooks once no managed event remains"; else ko "remove --hooks unlinks ~/.claude/hooks once no managed event remains"; fi

home="$(new_home)"
out="$(run_install "${home}" sync --target claude --intent settings --hooks WorktreeCreate)"
assert_contains "${out}" "--hooks needs the settings step (it narrows the hooks config group" "--hooks without the hooks group rejected"
if [[ ! -e "${home}/.claude/settings.json" ]]; then ok "--hooks rejection writes nothing"; else ko "--hooks rejection writes nothing"; fi
out="$(run_install "${home}" sync --target claude --intent hooks --hooks Bogus --global)"
assert_contains "${out}" "unknown hook event 'Bogus'" "unknown hook event rejected"
install_must_succeed_stubbed "${home}" install --target claude --hooks --global
if [[ -L "${home}/.claude/hooks" ]]; then ok "install --hooks stays the boolean 'also run hooks' flag"; else ko "install --hooks stays the boolean 'also run hooks' flag" "${INSTALL_OUT}"; fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
