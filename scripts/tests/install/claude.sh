#!/usr/bin/env bash
# install.sh tests — claude: settings merge, mods, native plugins, remove, legacy cleanup.
#
# Runs alone (bash scripts/tests/install/claude.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== install.sh sync: claude settings merge =="

home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{
  "tui": "fullscreen",
  "editorMode": "vim",
  "env": { "MY_LOCAL_TOKEN": "keep-me" }
}
JSON
# Default scope is project: the merge lands in <project>/.claude/settings.json
# (settings-project allowlist), never in the user file.
install_must_succeed "${home}" sync --target claude --intent settings
out="${INSTALL_OUT}"
merged="$(cat "${home}/project/.claude/settings.json")"
assert_contains "${merged}" '"editorMode": "vim"' "project merge preserves an unmanaged local key"
assert_contains "${merged}" '"MY_LOCAL_TOKEN": "keep-me"' "project merge preserves an unmanaged env leaf"
assert_contains "${merged}" '"claude-fable-5-1"' "project merge applies the managed model"
assert_contains "${merged}" '"effortLevel"' "project merge applies the managed effort level"
assert_contains "${merged}" '"CLAUDE_CODE_SUBAGENT_MODEL": "opus[1m]"' "project merge applies the subagent model"
for absent in statusLine permissions skipDangerousModePermissionPrompt skipAutoPermissionPrompt enabledPlugins extraKnownMarketplaces pluginMarketplaces hooks; do
    assert_not_contains "${merged}" "\"${absent}\"" "project settings excludes ${absent}"
done
if [[ ! -e "${home}/.claude/settings.json" && ! -e "${home}/.claude/statusline-command.sh" ]]; then
    ok "default claude settings writes neither the global file nor the statusline"
else
    ko "default claude settings writes neither the global file nor the statusline"
fi

# The same merge at --global is exactly the pre-change behavior.
home="$(new_home)"
cat > "${home}/.claude/settings.json" <<'JSON'
{
  "tui": "fullscreen",
  "editorMode": "vim",
  "env": { "MY_LOCAL_TOKEN": "keep-me" }
}
JSON
install_must_succeed "${home}" sync --target claude --intent settings --global
out="${INSTALL_OUT}"
merged="$(cat "${home}/.claude/settings.json")"
assert_contains "${merged}" '"editorMode": "vim"' "unmanaged local key preserved"
assert_contains "${merged}" '"MY_LOCAL_TOKEN": "keep-me"' "unmanaged env leaf preserved"
assert_contains "${merged}" '"claude-fable-5-1"' "managed model applied"
assert_contains "${merged}" '"statusLine"' "--global keeps the statusLine key"
assert_contains "${merged}" '"permissions"' "--global keeps the permissions key"
assert_contains "${merged}" '"skipDangerousModePermissionPrompt"' "--global keeps the prompt key"
if [[ -x "${home}/.claude/statusline-command.sh" ]]; then ok "--global copies the statusline script"; else ko "--global copies the statusline script"; fi
if [[ ! -e "${home}/project/.claude/settings.json" ]]; then ok "--global writes no project settings"; else ko "--global writes no project settings"; fi

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
install_must_succeed "${home}" sync --target claude --intent settings,plugins --global
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
echo "== install.sh sync: local edits are respected (project scope) =="

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings
python3 - "${home}/project/.claude/settings.json" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
data["model"] = "my-own-model"
data.setdefault("extraKnownMarketplaces", {})["mine"] = {"source": {"source": "github", "repo": "someone/else"}}
p.write_text(json.dumps(data, indent=2) + "\n")
PY
install_must_succeed "${home}" sync --target claude --intent settings
out="${INSTALL_OUT}"
assert_contains "${out}" "kept your local value at /model" "local edit preserved with warning"
assert_contains "$(cat "${home}/project/.claude/settings.json")" '"my-own-model"' "local model value intact"
assert_contains "$(cat "${home}/project/.claude/settings.json")" '"mine"' "project merge keeps a CLI-written extraKnownMarketplaces entry"

install_must_succeed "${home}" sync --target claude --intent settings --force
out="${INSTALL_OUT}"
assert_contains "$(cat "${home}/project/.claude/settings.json")" '"claude-fable-5-1"' "--force restores repo value"
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
assert_contains "${INSTALL_OUT}" "re-registering would rewrite that declaration" "an unrecognised declaration shape warns"

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

# A lossy declaration is never re-registered: `marketplace add` rewrites the
# entry from its arguments, so extra keys (autoUpdate) would be dropped and a
# relative directory path would become a machine-specific absolute one.
home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "github", "repo": "yandy-r/ystack", "ref": "v6.1.0" }, "autoUpdate": true } } }
JSON
before="$(cat "${home}/project/.claude/settings.json")"
install_must_succeed "${home}" sync --target claude --intent hooks
calls="$(cat "${home}/claude-calls.log")"
assert_not_contains "${calls}" "plugin marketplace add" "a declaration with extra keys is never re-registered"
assert_not_contains "${calls}" "plugin install" "a declaration with extra keys skips the install"
assert_contains "${INSTALL_OUT}" "ycc is declared in .claude/settings.json but not registered on this machine; re-registering would rewrite that declaration" "a declaration with extra keys warns"
assert_contains "${INSTALL_OUT}" "'claude plugin marketplace add yandy-r/ystack#v6.1.0 --scope project' would drop the declaration's other keys" "a declaration with extra keys warns that the manual add drops them"
assert_contains "$(cat "${home}/project/.claude/settings.json")" "${before}" "a declaration with extra keys is left untouched"

home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "directory", "path": "./vendor/ystack" } } } }
JSON
install_must_succeed "${home}" sync --target claude --intent hooks
calls="$(cat "${home}/claude-calls.log")"
assert_not_contains "${calls}" "plugin marketplace add" "a relative directory declaration is never re-registered"
assert_not_contains "${calls}" "plugin install" "a relative directory declaration skips the install"
assert_contains "${INSTALL_OUT}" "re-registering would rewrite that declaration" "a relative directory declaration warns"

# A git url the CLI would rewrite (it appends .git) is not lossless.
home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "git", "url": "https://github.com/yandy-r/ystack" } } } }
JSON
install_must_succeed "${home}" sync --target claude --intent hooks
assert_not_contains "$(cat "${home}/claude-calls.log")" "plugin marketplace add" "a git url the CLI would rewrite is never re-registered"
assert_contains "${INSTALL_OUT}" "re-registering would rewrite that declaration" "a rewritable git url warns"

# The CLI only accepts a project/local add that matches the user declaration
# (directory sources aside): repo mode adds the user declaration's own source.
home="$(new_home)"
# Seed the legacy user declaration explicitly; project settings no longer
# installs global plugin enablement or marketplace declarations.
install_must_succeed "${home}" sync --target claude --intent plugins --global
install_must_succeed "${home}" install --target claude --only settings,hooks --mode repo
calls="$(cat "${home}/claude-calls.log")"
assert_contains "${calls}" "plugin marketplace add yandy-r/ystack#main --scope project" "repo-mode settings,hooks adds the user declaration's source at project scope"
assert_contains "${calls}" "plugin install ycc-hooks@ycc --scope project" "repo-mode settings,hooks installs ycc-hooks"

# A project declaration that differs from the user declaration cannot be
# re-registered (the CLI rejects the add): warn and skip.
home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "github", "repo": "yandy-r/ystack", "ref": "v6.1.0" } } } }
JSON
install_must_succeed "${home}" install --target claude --only settings --mode repo --global
: > "${home}/claude-calls.log"
install_must_succeed "${home}" sync --target claude --intent hooks --mode repo
calls="$(cat "${home}/claude-calls.log")"
assert_not_contains "${calls}" "plugin marketplace add" "a project declaration differing from the user declaration is not re-registered"
assert_not_contains "${calls}" "plugin install" "a project declaration differing from the user declaration skips the install"
assert_contains "${INSTALL_OUT}" "declares a different ycc source" "a differing project declaration warns"

# A rejected add warns with the CLI's reason and skips the install; it never
# aborts the run.
for add_mode in "" "--mode repo"; do
    home="$(new_home)"
    CLAUDE_STUB_ADD_FAIL='Failed to add marketplace: stub rejection' \
        install_must_succeed "${home}" sync --target claude --intent hooks ${add_mode}
    calls="$(cat "${home}/claude-calls.log")"
    assert_contains "${calls}" "plugin marketplace add" "a rejected add was attempted (${add_mode:-local mode})"
    assert_not_contains "${calls}" "plugin install" "a rejected add skips the install (${add_mode:-local mode})"
    assert_contains "${INSTALL_OUT}" "failed: Failed to add marketplace: stub rejection" "a rejected add warns with the CLI's reason (${add_mode:-local mode})"
done

home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "extraKnownMarketplaces": { "ycc": { "source": { "source": "github", "repo": "yandy-r/ystack", "ref": "v6.1.0" } } } }
JSON
CLAUDE_STUB_ADD_FAIL='Failed to add marketplace: stub rejection' \
    install_must_succeed "${home}" sync --target claude --intent hooks
assert_not_contains "$(cat "${home}/claude-calls.log")" "plugin install" "a rejected re-registration skips the install"
assert_contains "${INSTALL_OUT}" "failed: Failed to add marketplace: stub rejection" "a rejected re-registration warns with the CLI's reason"

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings,hooks
calls="$(cat "${home}/claude-calls.log")"
assert_contains "${calls}" "plugin install ycc-hooks@ycc --scope project" "settings,hooks at default scope installs project hooks"
merged="$(cat "${home}/project/.claude/settings.json")"
assert_contains "${merged}" '"claude-fable-5-1"' "settings merge into the project file beside project hooks"
assert_not_contains "${merged}" '"hooks"' "the project settings file carries no hooks group"
assert_not_contains "$(cat "${home}/project/.claude/settings.json")" '"enabledPlugins"' "project settings carry no plugin enablement"
if [[ ! -e "${home}/.claude/settings.json" && ! -e "${home}/.claude/statusline-command.sh" ]]; then
    ok "settings,hooks default writes no global settings or statusline"
else
    ko "settings,hooks default writes no global settings or statusline"
fi

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

# Repo mode copies the user declaration's pinned upstream source into the
# project; remove recognizes that copy as installer-written. A different pin stays.
for pin in main v6.1.0; do
    home="$(new_home)"
    mkdir -p "${home}/project/.claude"
    printf '{"extraKnownMarketplaces":{"ycc":{"source":{"source":"github","repo":"yandy-r/ystack","ref":"main"}}}}\n' > "${home}/.claude/settings.json"
    printf '{"extraKnownMarketplaces":{"ycc":{"source":{"source":"github","repo":"yandy-r/ystack","ref":"%s"}}},"enabledPlugins":{"ycc-hooks@ycc":true}}\n' "${pin}" > "${home}/project/.claude/settings.json"
    install_must_succeed "${home}" remove --target claude --intent hooks
    calls="$(cat "${home}/claude-calls.log")"
    if [[ "${pin}" == main ]]; then
        assert_contains "${calls}" "plugin marketplace remove ycc --scope project" "project hooks remove retracts the user-pinned upstream copy repo mode wrote"
    else
        assert_not_contains "${calls}" "plugin marketplace remove" "project hooks remove keeps a pin that differs from the user declaration"
    fi
done

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
out="$(CLAUDE_STUB_VERSION='2.1.200 (Claude Code)' run_install "${home}" sync --target claude --intent hooks)"
assert_contains "${out}" "ycc-hooks needs Claude Code 2.1.300 or later (found 2.1.200)" "project hooks rejects an old Claude CLI"
if [[ ! -e "${home}/.claude/settings.json" && ! -e "${home}/.claude/hooks" && ! -e "${home}/project/.claude" ]]; then
    ok "old Claude CLI rejection writes nothing"
else
    ko "old Claude CLI rejection writes nothing"
fi
home="$(new_home)"
CLAUDE_STUB_VERSION='2.1.200 (Claude Code)' install_must_succeed "${home}" sync --target all --intent hooks
assert_contains "${INSTALL_OUT}" "Skipping Claude hooks: ycc-hooks needs Claude Code 2.1.300" "all-target sync warns and skips old Claude project hooks"
assert_contains "${INSTALL_OUT}" "Cursor sync complete" "all-target sync still completes other targets with old Claude"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin install ycc-hooks" "all-target old Claude does not install project hooks"
CLAUDE_STUB_VERSION='2.1.200 (Claude Code)' install_must_succeed "${home}" remove --target all --intent hooks
assert_contains "${INSTALL_OUT}" "Skipping Claude hooks: ycc-hooks needs Claude Code 2.1.300" "all-target remove warns and skips old Claude project hooks"
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
out="$(CLAUDE_STUB_VERSION='2.1.200 (Claude Code)' run_install "${home}" sync --target claude --intent hooks --dry-run)"
assert_not_contains "${out}" "ycc-hooks needs Claude Code" "project hooks dry-run skips the Claude version check"
assert_contains "${out}" "would run: claude plugin install ycc-hooks@ycc --scope project" "project hooks dry-run previews the native install"
assert_not_contains "$(cat "${home}/claude-calls.log" 2>/dev/null)" "plugin install" "project hooks dry-run calls no native install"

echo "== install.sh remove: settings, rules, hooks, plugins =="

home="$(new_home)"
cat > "${home}/.claude/settings.json" <<'JSON'
{ "editorMode": "vim", "env": { "MY_LOCAL_TOKEN": "keep-me" } }
JSON
install_must_succeed "${home}" sync --target claude --intent settings,rules,plugins --global
install_must_succeed "${home}" remove --target claude --intent settings,rules,plugins --global
out="${INSTALL_OUT}"
assert_contains "${out}" "Claude remove complete" "claude remove of every config intent completes"
merged="$(cat "${home}/.claude/settings.json")"
assert_contains "${merged}" '"editorMode": "vim"' "claude remove keeps unmanaged keys"
assert_contains "${merged}" '"MY_LOCAL_TOKEN": "keep-me"' "claude remove keeps unmanaged env leaf"
assert_not_contains "${merged}" '"claude-fable-5-1"' "claude remove drops managed model"
assert_not_contains "${merged}" '"pluginMarketplaces"' "claude remove takes back appended list items"
for f in CLAUDE.md AGENTS.md statusline-command.sh; do
    if [[ ! -e "${home}/.claude/${f}" && ! -L "${home}/.claude/${f}" ]]; then ok "claude remove cleans ~/.claude/${f}"; else ko "claude remove cleans ~/.claude/${f}"; fi
done

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings,plugins --global
python3 - "${home}/.claude/settings.json" <<'PY2'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
data["model"] = "my-own-model"
p.write_text(json.dumps(data, indent=2) + "\n")
PY2
install_must_succeed "${home}" remove --target claude --intent settings --global
out="${INSTALL_OUT}"
assert_contains "${out}" "kept your local value at /model" "remove keeps an edited managed value"
assert_contains "$(cat "${home}/.claude/settings.json")" '"enabledPlugins"' "remove --intent settings leaves the plugins group"
install_must_succeed "${home}" remove --target claude --intent settings,plugins --force --global
if [[ ! -e "${home}/.claude/settings.json" ]]; then ok "remove --force takes edited values too"; else ko "remove --force takes edited values too" "$(cat "${home}/.claude/settings.json")"; fi

# The same remove at project scope strips only the project-allowed managed
# leaves, keeps unmanaged keys and foreign env leaves, never touches the
# global file or the statusline.
home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings,plugins --global
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{ "editorMode": "vim", "env": { "MY_LOCAL_TOKEN": "keep-me" } }
JSON
install_must_succeed "${home}" sync --target claude --intent settings
python3 - "${home}/project/.claude/settings.json" <<'PY3'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
data["model"] = "my-own-model"
p.write_text(json.dumps(data, indent=2) + "\n")
PY3
install_must_succeed "${home}" remove --target claude --intent settings
out="${INSTALL_OUT}"
merged="$(cat "${home}/project/.claude/settings.json")"
assert_contains "${merged}" '"editorMode": "vim"' "project remove keeps unmanaged keys"
assert_contains "${merged}" '"MY_LOCAL_TOKEN": "keep-me"' "project remove keeps a foreign env leaf"
assert_contains "${out}" "kept your local value at /model" "project remove keeps an edited managed value"
assert_not_contains "${merged}" '"effortLevel"' "project remove strips the managed effort leaf"
assert_contains "$(cat "${home}/.claude/settings.json")" '"claude-fable-5-1"' "project remove never touches the global file"
if [[ -x "${home}/.claude/statusline-command.sh" ]]; then ok "project remove leaves the statusline script"; else ko "project remove leaves the statusline script"; fi
# --force also takes the edited model, so only the unmanaged keys remain.
install_must_succeed "${home}" remove --target claude --intent settings --force
merged="$(cat "${home}/project/.claude/settings.json")"
assert_not_contains "${merged}" '"my-own-model"' "project remove --force takes the edited managed value"
assert_not_contains "${merged}" '"effortLevel"' "project remove --force strips every managed leaf"
assert_contains "${merged}" '"editorMode": "vim"' "project remove --force keeps the unmanaged key"
assert_contains "${merged}" '"MY_LOCAL_TOKEN": "keep-me"' "project remove --force keeps the foreign env leaf"

home="$(new_home)"
echo "# mine" > "${home}/.claude/CLAUDE.md"
echo "custom" > "${home}/.claude/statusline-command.sh"
install_must_succeed "${home}" remove --target claude --intent rules,settings --force --global
out="${INSTALL_OUT}"
assert_contains "$(cat "${home}/.claude/CLAUDE.md")" "# mine" "remove never deletes a real rules file"
assert_contains "${out}" "not installed by ycc" "remove reports foreign rules file"
if [[ ! -e "${home}/.claude/statusline-command.sh" ]]; then ok "remove --force takes an edited statusline"; else ko "remove --force takes an edited statusline"; fi

home="$(new_home)"
echo "custom" > "${home}/.claude/statusline-command.sh"
install_must_succeed "${home}" remove --target claude --intent settings --global
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
    --plugins superpowers@claude-plugins-official,context7@claude-plugins-official --global
assert_contains "${INSTALL_OUT}" "Plugins: superpowers@claude-plugins-official, context7@claude-plugins-official" "--plugins names the selection"
keys="$(claude_plugin_keys "${home}/.claude/settings.json")"
if [[ "${keys}" == "enabledPlugins=context7@claude-plugins-official,superpowers@claude-plugins-official markets=claude-plugins-official lists=claude-plugins-official" ]]; then
    ok "--plugins writes exactly the selected plugins plus their marketplace"
else
    ko "--plugins writes exactly the selected plugins plus their marketplace" "${keys}"
fi
assert_not_contains "$(cat "${home}/.claude/settings.json")" '"model"' "--intent plugins --plugins leaves settings alone"

install_must_succeed "${home}" remove --target claude --intent plugins --plugins context7@claude-plugins-official --global
keys="$(claude_plugin_keys "${home}/.claude/settings.json")"
if [[ "${keys}" == "enabledPlugins=superpowers@claude-plugins-official markets=claude-plugins-official lists=claude-plugins-official" ]]; then
    ok "remove --plugins takes one plugin and keeps the marketplace another still uses"
else
    ko "remove --plugins takes one plugin and keeps the marketplace another still uses" "${keys}"
fi

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings,plugins --plugins ycc@ycc --global
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

# Default scope: the plugins group is global-only, so an unscoped plugins
# intent is dropped with a notice and writes nothing; --project rejects it.
home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent plugins
assert_contains "${INSTALL_OUT}" "the plugins group is global-only" "default plugins intent drops the group with a notice"
assert_contains "${INSTALL_OUT}" "Pass --global to merge it" "the notice names the --global command"
if [[ ! -e "${home}/.claude/settings.json" && ! -e "${home}/project/.claude/settings.json" ]]; then
    ok "default plugins intent writes nothing"
else
    ko "default plugins intent writes nothing"
fi
out="$(run_install "${home}" sync --target claude --intent plugins --project)"
assert_contains "${out}" "--project cannot carry the plugins group for target 'claude' (global-only)" "--project rejects the plugins group"
if [[ ! -e "${home}/.claude/settings.json" && ! -e "${home}/project/.claude/settings.json" ]]; then
    ok "the --project plugins rejection writes nothing"
else
    ko "the --project plugins rejection writes nothing"
fi

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


# The legacy-user hint: a home whose global settings file still holds
# ycc-managed keys from an earlier sync is told that settings now default to
# project scope; a fresh home never sees it.
home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings --global
install_must_succeed "${home}" sync --target claude --intent settings
assert_contains "${INSTALL_OUT}" "settings now default to project scope" "legacy hint printed when the global file holds ycc state"
assert_contains "${INSTALL_OUT}" "still holds ycc-managed keys from earlier syncs" "legacy hint names the global destination"

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings
assert_not_contains "${INSTALL_OUT}" "settings now default to project scope" "no legacy hint on a fresh home"

# A committed project file whose values equal the repo's must lose nothing ycc
# never recorded writing: remove (and sync adoption) is owned-only at project
# scope, scalar and object-child keys alike.
home="$(new_home)"
mkdir -p "${home}/project/.claude"
cat > "${home}/project/.claude/settings.json" <<'JSON'
{
  "alwaysThinkingEnabled": true,
  "effortLevel": "high",
  "env": { "FORCE_AUTOUPDATE_PLUGINS": "1" }
}
JSON
before="$(cat "${home}/project/.claude/settings.json")"
install_must_succeed "${home}" remove --target claude --intent settings
assert_contains "$(cat "${home}/project/.claude/settings.json")" "${before}" "project remove keeps repo-equal keys ycc never wrote"
install_must_succeed "${home}" sync --target claude --intent settings
install_must_succeed "${home}" remove --target claude --intent settings
assert_not_contains "$(cat "${home}/project/.claude/settings.json" 2>/dev/null)" '"CLAUDE_CODE_SUBAGENT_MODEL"' "project remove still takes back keys ycc wrote"
assert_contains "$(cat "${home}/project/.claude/settings.json" 2>/dev/null)" '"alwaysThinkingEnabled": true' "project remove keeps the repo-equal key a sync did not need to write"

# The legacy hint counts settings state only: global state from another
# config group (here hooks) must not trigger it.
home="$(new_home)"
install_must_succeed_stubbed "${home}" sync --target claude --intent hooks --global
install_must_succeed "${home}" sync --target claude --intent settings
assert_not_contains "${INSTALL_OUT}" "settings now default to project scope" "no legacy hint from non-settings global state"

echo
echo "== install.sh: claude native mcp / hooks scopes =="

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent mcp
calls="$(cat "${home}/claude-calls.log")"
assert_contains "${calls}" "plugin install ycc-mcp@ycc --scope project" "mcp installs ycc-mcp@ycc at project scope by default"
if [[ ! -e "${home}/project/.mcp.json" && ! -e "${home}/.claude.json" ]]; then ok "native mcp merges no MCP config"; else ko "native mcp merges no MCP config"; fi

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent mcp --global
calls="$(cat "${home}/claude-calls.log")"
assert_contains "${calls}" "plugin marketplace add ${REPO_REAL} --scope user" "global mcp registers the marketplace at user scope"
assert_contains "${calls}" "plugin install ycc-mcp@ycc --scope user" "global mcp installs ycc-mcp@ycc at user scope"
if [[ ! -e "${home}/.claude.json" ]]; then ok "global mcp writes no ~/.claude.json servers"; else ko "global mcp writes no ~/.claude.json servers"; fi
install_must_succeed "${home}" remove --target claude --intent mcp --global
assert_contains "$(cat "${home}/claude-calls.log")" "plugin uninstall ycc-mcp@ycc --scope user" "global mcp remove uninstalls at user scope"

home="$(new_home)"
mkdir -p "${home}/project/.claude"
printf '{ "enabledPlugins": { "ycc-mcp@ycc": true } }\n' > "${home}/project/.claude/settings.json"
install_must_succeed "${home}" remove --target claude --intent mcp
assert_contains "$(cat "${home}/claude-calls.log")" "plugin uninstall ycc-mcp@ycc --scope project" "project mcp remove uninstalls at project scope"

# A real ~/.claude/hooks directory holding the user's own script is never touched.
home="$(new_home)"
mkdir -p "${home}/.claude/hooks"
echo "user hook" > "${home}/.claude/hooks/herdr-agent-state.sh"
install_must_succeed "${home}" sync --target claude --intent hooks --global
calls="$(cat "${home}/claude-calls.log")"
assert_contains "${calls}" "plugin install ycc-hooks@ycc --scope user" "global hooks installs ycc-hooks@ycc at user scope"
if [[ -d "${home}/.claude/hooks" && ! -L "${home}/.claude/hooks" ]] \
    && [[ "$(cat "${home}/.claude/hooks/herdr-agent-state.sh")" == "user hook" ]]; then
    ok "global hooks leaves a real ~/.claude/hooks directory untouched"
else
    ko "global hooks leaves a real ~/.claude/hooks directory untouched"
fi
assert_not_contains "$(cat "${home}/.claude/settings.json" 2>/dev/null)" '"WorktreeCreate"' "global hooks merges no settings hooks group"
install_must_succeed "${home}" remove --target claude --intent hooks --global
assert_contains "$(cat "${home}/claude-calls.log")" "plugin uninstall ycc-hooks@ycc --scope user" "global hooks remove uninstalls at user scope"
if [[ -f "${home}/.claude/hooks/herdr-agent-state.sh" ]]; then ok "global hooks remove keeps the user's hooks dir"; else ko "global hooks remove keeps the user's hooks dir"; fi

home="$(new_home)"
out="$(CLAUDE_STUB_VERSION='2.1.200 (Claude Code)' run_install "${home}" sync --target claude --intent hooks --global)"
assert_contains "${out}" "ycc-hooks needs Claude Code 2.1.300 or later" "global hooks keeps the Claude version gate"

home="$(new_home)"
install_must_succeed "${home}" sync --target claude --intent settings --global
assert_not_contains "$(cat "${home}/.claude/settings.json")" '"hooks"' "global settings merge no longer writes hooks"

# Legacy cleanup after a user-scope native install: an installer-owned
# WorktreeCreate entry is pruned and the owned ~/.claude/hooks link goes once
# ycc-hooks@ycc is enabled.
home="$(new_home)"
state="${home}/.config/ycc/managed-config-state.json"
mkdir -p "$(dirname "${state}")"
printf '{ "enabledPlugins": { "ycc-hooks@ycc": true } }\n' > "${home}/.claude/settings.json"
HOME="${home}" YCC_MANAGED_CONFIG_STATE="${state}" python3 "${REPO_ROOT}/scripts/merge_managed_config.py" \
    --profile claude-settings --source "${REPO_ROOT}/ycc/settings/settings.json" \
    --destination "${home}/.claude/settings.json" --groups hooks >/dev/null
assert_contains "$(cat "${home}/.claude/settings.json")" "worktree-create.sh" "seeded installer-owned WorktreeCreate entry"
ln -s "${REPO_ROOT}/ycc/settings/hooks" "${home}/.claude/hooks"
install_must_succeed "${home}" sync --target claude --intent hooks --global
assert_not_contains "$(cat "${home}/.claude/settings.json")" "worktree-create.sh" "cleanup prunes the installer-owned WorktreeCreate entry"
if [[ ! -e "${home}/.claude/hooks" && ! -L "${home}/.claude/hooks" ]]; then ok "cleanup removes the owned ~/.claude/hooks link"; else ko "cleanup removes the owned ~/.claude/hooks link" "${INSTALL_OUT}"; fi

# Standalone copies as the old slice step wrote them (projected and recorded),
# plus a recorded-but-edited copy, a user skill and recorded legacy wrappers.
# seed_claude_slices <home> <enabledPlugins json>
seed_claude_slices() {
    local h="$1"
    mkdir -p "${h}/.config/ycc" "${h}/.claude/skills/my-own-skill"
    HOME="${h}" YCC_MANAGED_CONFIG_STATE="${h}/.config/ycc/managed-config-state.json" \
        python3 "${REPO_ROOT}/scripts/install_slices.py" install --target claude --slice skills >/dev/null
    HOME="${h}" YCC_MANAGED_CONFIG_STATE="${h}/.config/ycc/managed-config-state.json" \
        python3 "${REPO_ROOT}/scripts/install_slices.py" install --target claude --slice agents >/dev/null
    echo "# my edit" >> "${h}/.claude/skills/clean/SKILL.md"
    echo "mine" > "${h}/.claude/skills/my-own-skill/SKILL.md"
    mkdir -p "${h}/.claude/commands"
    git -C "${REPO_ROOT}" show 7410693f^:ycc/commands/clean.md > "${h}/.claude/commands/clean.md"
    git -C "${REPO_ROOT}" show 7410693f^:ycc/commands/plan.md > "${h}/.claude/commands/plan.md"
    echo "# my edit" >> "${h}/.claude/commands/plan.md"
    python3 - "${h}/.config/ycc/installed-units.json" "${h}/.claude/commands" <<'PY'
import json, sys
p = sys.argv[1]; data = json.load(open(p))
data["units"][sys.argv[2]] = ["clean.md", "plan.md"]
json.dump(data, open(p, "w"), indent=2)
PY
    printf '{ "enabledPlugins": %s }\n' "$2" > "${h}/.claude/settings.json"
}

# Installing only ycc-mcp never retires the standalone copies ycc@ycc replaces.
home="$(new_home)"
seed_claude_slices "${home}" '{ "ycc-mcp@ycc": true }'
install_must_succeed "${home}" sync --target claude --intent mcp --global
if [[ -d "${home}/.claude/skills/git-workflow" && -e "${home}/.claude/agents/codebase-advisor.md" && -e "${home}/.claude/commands/clean.md" ]]; then
    ok "cleanup keeps standalone copies while ycc@ycc is not enabled"
else
    ko "cleanup keeps standalone copies while ycc@ycc is not enabled" "${INSTALL_OUT}"
fi
assert_contains "${INSTALL_OUT}" "ycc@ycc is not explicitly enabled" "cleanup says why standalone copies stay"

# With ycc@ycc enabled: exact copies go; edited, foreign and user entries stay.
home="$(new_home)"
seed_claude_slices "${home}" '{ "ycc@ycc": true }'
install_must_succeed "${home}" sync --target claude --intent mcp --global
if [[ ! -e "${home}/.claude/skills/git-workflow" && ! -e "${home}/.claude/agents" ]]; then
    ok "cleanup retires byte-identical standalone skills and agents"
else
    ko "cleanup retires byte-identical standalone skills and agents" "${INSTALL_OUT}"
fi
assert_contains "$(cat "${home}/.claude/skills/clean/SKILL.md" 2>/dev/null)" "# my edit" "cleanup keeps a recorded but edited skill"
assert_contains "${INSTALL_OUT}" "kept ${home}/.claude/skills/clean: edited or ownership uncertain" "cleanup reports the edited skill"
if [[ -d "${home}/.claude/skills/_shared" ]]; then ok "cleanup keeps _shared while a retained skill may use it"; else ko "cleanup keeps _shared while a retained skill may use it"; fi
assert_contains "$(cat "${home}/.claude/skills/my-own-skill/SKILL.md" 2>/dev/null)" "mine" "cleanup keeps a user skill"
if [[ ! -e "${home}/.claude/commands/clean.md" ]]; then ok "cleanup retires a byte-identical legacy wrapper"; else ko "cleanup retires a byte-identical legacy wrapper" "${INSTALL_OUT}"; fi
assert_contains "$(cat "${home}/.claude/commands/plan.md" 2>/dev/null)" "# my edit" "cleanup keeps a recorded but edited wrapper"
units="$(cat "${home}/.config/ycc/installed-units.json")"
assert_not_contains "${units}" '"git-workflow"' "cleanup forgets retired skills"
assert_contains "${units}" '"clean"' "cleanup keeps the record of a retained skill"
assert_contains "${units}" '"plan.md"' "cleanup keeps the record of a retained wrapper"

# remove --intent base: ycc@ycc is gone, so its exact copies are retired anyway.
home="$(new_home)"
seed_claude_slices "${home}" '{}'
install_must_succeed "${home}" remove --target claude --intent base
if [[ ! -e "${home}/.claude/skills/git-workflow" && -e "${home}/.claude/skills/clean" ]]; then
    ok "remove base retires exact standalone copies and keeps edited ones"
else
    ko "remove base retires exact standalone copies and keeps edited ones" "${INSTALL_OUT}"
fi

# A symlinked ~/.claude is never traversed.
home="$(new_home)"
mv "${home}/.claude" "${home}/claude-real"
ln -s "${home}/claude-real" "${home}/.claude"
seed_claude_slices "${home}" '{ "ycc@ycc": true }'
install_must_succeed "${home}" sync --target claude --intent mcp --global
assert_contains "${INSTALL_OUT}" "symlinked configuration directory" "cleanup skips a symlinked ~/.claude"
if [[ -d "${home}/claude-real/skills/git-workflow" ]]; then ok "cleanup leaves a symlinked ~/.claude untouched"; else ko "cleanup leaves a symlinked ~/.claude untouched"; fi

# A cleanup refusal after the native install is reported, never fatal.
home="$(new_home)"
echo '{ not json' > "${home}/.claude/settings.json"
install_must_succeed "${home}" sync --target claude --intent mcp --global
assert_contains "$(cat "${home}/claude-calls.log")" "plugin install ycc-mcp@ycc --scope user" "native install runs before a failing cleanup"
assert_contains "${INSTALL_OUT}" "legacy cleanup skipped: see above; rerun after resolving" "a failing cleanup warns instead of aborting"

# Project-scope mcp has the same $HOME guard as hooks.
home="$(new_home)"
for args in "sync --target claude --intent mcp" "install --target claude --mcp"; do
    # shellcheck disable=SC2086  # args is a word list.
    out="$(cd "${home}" && HOME="${home}" PATH="${STUB_BIN}:${PATH}" CLAUDE_STUB_LOG="${home}/claude-calls.log" \
        YCC_INSTALL_SKIP_BUILD=1 bash "${INSTALL}" ${args} 2>&1)"
    assert_contains "${out}" "claude project scope needs a project directory" "project mcp rejects \$HOME (${args})"
done
if [[ ! -e "${home}/claude-calls.log" ]]; then ok "project mcp HOME rejection calls no CLI"; else ko "project mcp HOME rejection calls no CLI"; fi


# Ported migrate fixtures: legacy state as an earlier release recorded it,
# retired automatically by a user-scope native install.
# seed_legacy_claude <home> <groups-csv: hooks,mcp> — record managed hooks/MCP and the hooks link.
seed_legacy_claude() {
    local h="$1" groups="$2"
    local state="${h}/.config/ycc/managed-config-state.json"
    mkdir -p "$(dirname "${state}")"
    [[ -f "${h}/.claude/settings.json" ]] || echo '{}' > "${h}/.claude/settings.json"
    if [[ ",${groups}," == *",hooks,"* ]]; then
        HOME="${h}" YCC_MANAGED_CONFIG_STATE="${state}" python3 "${REPO_ROOT}/scripts/merge_managed_config.py" \
            --profile claude-settings --source "${REPO_ROOT}/ycc/settings/settings.json" \
            --destination "${h}/.claude/settings.json" --groups hooks >/dev/null
        ln -s "${REPO_ROOT}/ycc/settings/hooks" "${h}/.claude/hooks"
    fi
    if [[ ",${groups}," == *",mcp,"* ]]; then
        HOME="${h}" YCC_MANAGED_CONFIG_STATE="${state}" python3 "${REPO_ROOT}/scripts/merge_managed_config.py" \
            --profile claude-mcp --source "${REPO_ROOT}/mcp-configs/mcp.json" \
            --destination "${h}/.claude.json" --groups mcp >/dev/null
    fi
}
# set_enabled <settings.json> <python dict literal>
set_enabled() {
    python3 - "$1" "$2" <<'PY'
import ast, json, sys
from pathlib import Path
p = Path(sys.argv[1]); data = json.loads(p.read_text())
data['enabledPlugins'] = ast.literal_eval(sys.argv[2])
p.write_text(json.dumps(data, indent=2) + '\n')
PY
}

home="$(new_home)"
seed_legacy_claude "${home}" hooks,mcp
set_enabled "${home}/.claude/settings.json" "{'ycc-hooks@ycc': True, 'ycc-mcp@ycc': True}"
python3 - "${home}" <<'PY'
import json, sys
from pathlib import Path
home = Path(sys.argv[1])
p = home / '.claude/settings.json'
data = json.loads(p.read_text())
data['hooks']['WorktreeCreate'][0]['hooks'].append({'type': 'command', 'command': 'echo my-hook'})
data['editorMode'] = 'vim'
p.write_text(json.dumps(data, indent=2) + '\n')
p = home / '.claude.json'
data = json.loads(p.read_text())
first = next(iter(data['mcpServers']))
data['mcpServers'][first] = {'url': 'https://edited.example'}
data['mcpServers']['mine'] = {'url': 'https://mine.example'}
p.write_text(json.dumps(data, indent=2) + '\n')
PY
install_must_succeed "${home}" sync --target claude --intent mcp --global
settings="$(cat "${home}/.claude/settings.json")"
assert_contains "${settings}" "echo my-hook" "cleanup keeps a user hook inside the managed wrapper"
assert_not_contains "${settings}" "worktree-create.sh" "cleanup prunes only the managed hook command"
assert_contains "${settings}" '"editorMode": "vim"' "cleanup keeps unrelated settings"
assert_contains "$(cat "${home}/.claude.json")" "edited.example" "cleanup keeps an edited managed MCP server"
assert_contains "$(cat "${home}/.claude.json")" "mine.example" "cleanup keeps a foreign MCP server"
if [[ ! -L "${home}/.claude/hooks" ]]; then ok "cleanup removes the owned unused hooks link"; else ko "cleanup removes the owned unused hooks link"; fi

home="$(new_home)"
seed_legacy_claude "${home}" hooks,mcp
set_enabled "${home}/.claude/settings.json" "{'ycc-all@ycc': True, 'ycc-hooks@ycc': False, 'ycc-mcp@ycc': False}"
before="$(cat "${home}/.claude/settings.json" "${home}/.claude.json")"
install_must_succeed "${home}" sync --target claude --intent mcp --global
if [[ "$(cat "${home}/.claude/settings.json" "${home}/.claude.json")" == "${before}" && -L "${home}/.claude/hooks" ]]; then
    ok "disabled native plugins and the aggregate do not authorize cleanup"
else
    ko "disabled native plugins and the aggregate do not authorize cleanup"
fi

home="$(new_home)"
seed_legacy_claude "${home}" hooks
set_enabled "${home}/.claude/settings.json" "{'ycc-hooks@ycc': True}"
rm -f "${home}/.config/ycc/managed-config-state.json"
install_must_succeed "${home}" sync --target claude --intent hooks --global
assert_contains "$(cat "${home}/.claude/settings.json")" "worktree-create.sh" "cleanup without ownership state retains the hook"
if [[ -L "${home}/.claude/hooks" ]]; then ok "cleanup without ownership state retains the hooks link"; else ko "cleanup without ownership state retains the hooks link"; fi


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
