# agents (`~/.agents`) Package Reference

The `agents` target stays **file-copy only** in v6: there is no native
package and no marketplace. `install.sh install --package` does not apply to
it, and `install.sh` runs no legacy cleanup for it. The install how-to is
[agents Install](../agents.md); this page records the `npx skills` evidence.

## Install (skills-only file copy)

```bash
./install.sh install --target agents
./install.sh remove  --target agents --only skills
```

`install.sh install --target agents` generates `.agents-plugin/` from the
`ycc/skills/` tree and installs entries into the shared user skill directory:

| Path                       | Contents                                         |
| -------------------------- | ------------------------------------------------ |
| `~/.agents/skills/<name>/` | one directory per ycc skill (49 today)           |
| `~/.agents/ycc-shared/`    | shared helper scripts/references the skills call |

Rules of the target, unchanged in v6:

- **Skills only.** No tool reads `~/.agents/commands/`, `~/.agents/agents/`,
  or `~/.agents/AGENTS.md`, so this target ships none. Install agents, rules,
  or commands per tool (Claude, Codex, Cursor, or opencode targets).
- **Never writes `~/.agents/plugins/`.** That directory is owned by Codex's
  marketplace; this target never creates, modifies, or deletes anything under
  it. Only entries ycc installed are replaced or removed; your own skills in
  `~/.agents/skills/` are never touched.
- Claude Code does **not** read `~/.agents/skills/`; use the Claude target for
  Claude Code.

## Duplicates

opencode reads `~/.agents/skills` and its own skill directory, so installing
ycc skills natively for opencode **and** via this target lists every skill
twice. The installer detects this and offers:

```bash
./install.sh install --target opencode,agents --only base
# warning: opencode will duplicate the ycc skills in ~/.agents/skills ...
#   [1] Recommended — skills → ~/.agents/skills; opencode get only their
#       non-skill pieces natively  (default)
#   [2] Keep as requested (native skills per tool; duplicates possible)
#   [3] Abort
```

The prompt appears only on a terminal. Answer in advance with
`--skills-home agents` (option 1) or `--skills-home native` (option 2). On a
non-terminal run without the flag, the installer warns and continues as
requested (option 2 semantics). Codex and Cursor also read
`~/.agents/skills`, but their ycc skills come from their native `ycc`
package; installing this target next to them lists the skills twice, so skip
it if you use only those tools.

## `npx skills` evidence (YAN-1126, 2026-10-16)

The spike (`skills@1.7.2`, Node v24.15.0) ran against the public product
repository at commit `f2f3c8a00d0b05d50c0d0aa5f230828fc37773fb` in a throwaway
HOME. Verdict: **`npx skills` cannot replace `install.sh` for the `agents`
target as generated today.**

| Command (`npx -y skills@1.7.2 …`)                                      | Exit | Observed result                                                                                         |
| ---------------------------------------------------------------------- | ---- | ------------------------------------------------------------------------------------------------------- |
| `add yandy-r/claude-plugins -g -s plan -y --json`                      | 1    | Selected `plan`, failed: `Eve does not support global skill installation`; partial install, no rollback |
| `add yandy-r/claude-plugins -g -s plan -a codex -y --json`             | 0    | Installed canonical `ycc/skills/plan` into `~/.agents/skills/plan`; `ref: null`                         |
| `add …/tree/<sha>/.agents-plugin/skills -g -s plan -a codex -y --json` | 0    | Installed generated `.agents-plugin/skills/plan` (`ref` = pinned SHA)                                   |
| `add yandy-r/claude-plugins -l`                                        | 0    | `Found 49 skills`                                                                                       |
| `add …/tree/<sha>/.agents-plugin/skills -l`                            | 0    | `Found 49 skills`; source shown as `@ <sha> (.agents-plugin/skills)`                                    |

Why it cannot replace the installer today:

- **Bare-repo discovery picks the wrong tree.** `add yandy-r/claude-plugins`
  finds the canonical Claude source (`ycc/skills/plan`) — 49 skills, but with
  unrewritten `${CLAUDE_PLUGIN_ROOT}/...` paths that are unresolvable outside
  Claude Code. Only the explicit
  `https://github.com/<owner>/<repo>/tree/<sha>/.agents-plugin/skills` tree URL
  installs the generated `plan` byte-for-byte (SHA-256 manifest match).
- **Shared helpers are not delivered.** The CLI copies only the selected skill
  directory. The generated `plan` references `~/.agents/ycc-shared/...`; that
  directory is never created, so all four direct shared references are missing
  after install (its five `references/` files do resolve).
- **The literal issue command fails.** `add <repo> -g -s plan -y` targets all
  agents and exits 1 because Eve does not support global skill installation.
  There is **no rollback**: the skill, lock entry, and links under dozens of
  agent directories remain. An explicit agent (`-a codex`) installs
  successfully without that all-agent fan-out.
- Post-install layout is only `~/.agents/.skill-lock.json` and
  `~/.agents/skills/plan/{SKILL.md,references/}` — no `~/.agents/ycc-shared/`.

**Unsupported upstream commands:** the `remove`, `check`, and `update`
`npx skills` subcommands were **not exercised** by the spike. No behavior for
them is claimed; do not run them against the ycc install expecting equivalence
with `install.sh remove`, and any upstream `npx skills` CLI change (other CLI
versions, symlink mode) is unverified — only `skills@1.7.2` and the `codex`
agent target were tested.

Per-skill vendoring (rewriting references to skill-relative paths and
duplicating helpers) is one possible remedy; the spike measured a partial
lower-bound cost (32 of 49 skills mention `~/.agents/ycc-shared` literally;
median 2 vendored files / 19 KB per skill) but implemented and live-tested
nothing. Repository-root discovery surfacing the Claude source tree also needs
a manifest or ignore mechanism to hide `ycc/skills/` before `npx skills` could
ever be advertised.

## Moving off the file copy

There is nothing to move to: the file copy is the product, and no `--package`
selection covers this target. If `npx skills` were ever adopted, the
explicit-tree-URL route would still need a dependency mechanism for
`~/.agents/ycc-shared/` first; until that exists, use the commands at the top
of this page.

## Evidence

- `docs/internal/spikes/npx-skills.md` (YAN-1126, 2026-10-16) — actual spike
- `docs/internal/adr/0001-package-model-and-versioning.md` (`agents` row)
- `docs/install/agents.md` (live guide: skills-only, duplicate handling)
