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

opencode, Codex and Cursor also read `~/.agents/skills`, but their ycc skills
come from their native packages (`@yandy-r/ycc-opencode` on opencode, `ycc@ycc`
on Codex and Cursor). Installing this target next to them lists each skill a
second time; skip it if you use only those tools. The installer neither copies
opencode skills nor deduplicates against this directory any more, so there is
no prompt and no flag for it.

`--skills <names>` narrows this target's `skills` step (`--intent skills` or
`--only skills`) and `--with-deps` adds the selected skills' `ycc:<name>`
dependencies. Both apply to this target only:

```bash
./install.sh sync   --target agents --intent skills --skills prp-plan
./install.sh sync   --target agents --intent skills --skills code-review --with-deps
./install.sh remove --target agents --intent skills --skills prp-plan
```

See [Selecting Skills](README.md#selecting-skills).

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

A new target that ships files into `~/.agents/skills` installs them through the
slice helper (`scripts/install_slices.py`), which records ownership in
`~/.config/ycc/installed-units.json` and never touches entries it did not
install.
