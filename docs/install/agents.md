# Install: `~/.agents` (cross-tool skills)

The `agents` target installs the ycc **skills only** into `~/.agents/skills/`, the
shared user skill directory read by Zed, Codex, opencode, Cursor, Gemini CLI,
VS Code/Copilot, Amp, Goose, and Windsurf. Claude Code does **not** read it; use
the `claude` target for Claude Code.

```bash
./install.sh install --target agents
./install.sh remove  --target agents --only skills
```

Layout:

| Path                       | Contents                                           |
| -------------------------- | -------------------------------------------------- |
| `~/.agents/skills/<name>/` | one directory per ycc skill (flat, agentskills.io) |
| `~/.agents/ycc-shared/`    | shared helper scripts/references the skills call   |

The bundle is generated from `ycc/skills/` into `.agents-plugin/`
(`./scripts/sync.sh --only agents`). Only entries ycc installed are replaced or
removed; your own skills in `~/.agents/skills/` and Codex's `~/.agents/plugins/`
are never touched.

## Invocation policy limit

agentskills.io has no portable model-invocation flag. Skills marked
`disable-model-invocation: true` in `ycc/skills/` (for example `releaser`) are
installed here without that key and keep their normal description, so tools that
read `~/.agents/skills` may still select them automatically. Use a native target
(`claude`, `cursor`, `codex`, `opencode`) when manual-only invocation matters.

## Commands, agents, rules

No tool reads `~/.agents/commands`, `~/.agents/agents`, or `~/.agents/AGENTS.md`,
so this target ships none of them. Install those per tool (`--target opencode`,
`--target codex`, ...).

## Duplicate skills

opencode reads `~/.agents/skills` and its own skill directory, so installing ycc
skills natively for opencode alongside `agents` lists every skill twice. The
installer detects this:

```bash
./install.sh install --target opencode,agents --only base
# warning: opencode will duplicate the ycc skills in ~/.agents/skills (it reads that dir plus its own).
#   [1] Recommended — skills → ~/.agents/skills; opencode get only their non-skill pieces natively  (default)
#   [2] Keep as requested (native skills per tool; duplicates possible)
#   [3] Abort
```

The prompt appears only on a terminal. Answer it in advance with
`--skills-home agents` (option 1) or `--skills-home native` (option 2). Without a
terminal or the flag, the installer warns and continues as requested. With
option 1, opencode installs `agents/` and `commands/` only (no `skills/`,
`shared/`); its settings, rules and MCP are unchanged.

Codex and Cursor also read `~/.agents/skills`, but their ycc skills come from
the native `ycc@ycc` package, so `--skills-home` does not apply to them.
Installing this target next to them lists each skill twice; skip it if you use
only those tools.

### OMP

OMP (oh-my-pi) also reads `~/.agents/skills` by default. With ycc installed on
OMP, it lists each ycc skill copied here a second time as `agents/<name>`. The
OMP target hides those copies inside OMP only, so the other tools keep them:
`./install.sh install --target omp` does it by default (the `dedupe` step).
When you install this target after OMP, the installer prints:

```text
[!!] OMP also loads these skills; run ./install.sh install --target omp --only dedupe to hide the ~/.agents copies in OMP
```

Run `./install.sh install --target omp --only dedupe` to hide them. Do not
delete `~/.agents/skills` for OMP's sake. See
[OMP coexistence](omp.md#coexistence-with-other-runtimes).

### Pi

Pi (`@earendil-works/pi-coding-agent`) also reads `~/.agents/skills` by default.
A copy here outranks a Pi package skill with the same name, and Pi loads it
unadapted (Pi does not namespace skills). ycc has no Pi target yet: the planned
one (ADR 0003) hides these copies inside Pi with owned
`-~/.agents/skills/<name>/SKILL.md` overrides (YAN-1193).

## Adding a target

Each `scripts/lib/install/targets/<t>.sh` declares `<t>_reads_agents_skills`
(return 0 if the tool reads `~/.agents/skills`). Targets that return 0 must also
declare `<t>_native_skills_dirs` and pass their skill units through
`skills_filter <t>` so option 1 can drop them. The install tests fail if a
target omits the declaration.
