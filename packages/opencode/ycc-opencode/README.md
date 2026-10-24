# @yandy-r/ycc-opencode

Experimental, opt-in [OpenCode](https://opencode.ai) V2 plugin carrying the ycc bundle
(version 6.1.1). It is unlisted and never the default install: the
`install.sh --target opencode` file copy remains the primary path.

Requires OpenCode `>=2.0.30` (V2 plugin API; V1 hook plugins are not supported).

## Enable

Add the package to the V2 `plugins` array in your own `opencode.json`, pinned to an exact release:

```json
{ "plugins": ["@yandy-r/ycc-opencode@6.1.1"] }
```

Pin the version instead of using the bare name. Right after a release, the registry can briefly serve
stale `latest` metadata, and early placeholder versions of this package (`0.0.0-*`) were never
loadable plugins. Bump the pin when you upgrade.

A local checkout loads with a directory entry (`"file:///abs/path/to/packages/opencode/ycc-opencode"`),
not the `index.js` file.

## What it registers

`setup()` awaits one registration per component class, all from package-local assets:

- **Skills** (`skills/<id>/SKILL.md`): at setup the Markdown, scripts, and shared helpers are copied to a
  temporary rendered tree whose absolute root replaces `{{package-root}}` in shell snippets, so a snippet
  runs from any working directory; the tree is removed when the plugin unloads.
- **Agents** (`agents/<id>.md` prompts, permissions, color, model pins from `ycc/settings/models.json`).
- **Commands**: each public skill becomes `/ycc:<id>`; `$ARGUMENTS` is expanded and the result is forwarded
  as a prompt (a workflow command, not an OS process).
- **MCP servers**: plain data from `mcp-configs/mcp.json`; `{env:VAR}` placeholders resolve from the
  environment at setup time.
- **Instructions**: `AGENTS.md` pushed through the session `context` hook.
- **Sensitive-file guard** (`ycc-sensitive-guard/`, the same plugin the file-copy install loads): for the
  restricted specialists in its `policy.json` it checks tool calls against the sensitive-file policy,
  filters search results, and provides their only search tools (`ycc_grep`/`ycc_glob`, shown to them as
  `grep`/`glob`) after checking the caller's own permissions.
- **Restricted-agent floor**: OpenCode appends your own top-level `permissions` after a package agent's
  rules, so for the restricted specialists the package re-applies their packaged rules: a permission request
  those rules deny is denied, and a tool whose permission they deny outright is neither offered nor run. It
  never loosens or re-prompts a decision. Shell interpreters and build tools in their allowlists still run
  project code, which the guard does not bound.

## Coexistence with the file-copy install

Skills, agents, and MCP servers are registered under their source ids. OpenCode applies file-copy config
(`~/.config/opencode`) after user plugins, so a same-id file-copy skill, agent, or command replaces (agents:
field-blends over) the package definition; the package's `editor.get` skip only sees registrations loaded
before it, and MCP config servers genuinely win. Package commands are always `ycc:<skill>` and never collide
with the bare file-copy `/<skill>` commands or host built-ins such as `/init`. The context hook does not push
instructions already present in the request.
Provider and variant settings (`providers`) are user configuration and are not carried by this package.
