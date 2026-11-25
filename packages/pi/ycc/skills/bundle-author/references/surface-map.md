# Surface Map

## Contents

- Surfaces
- Post-Scaffold Required Commands
- Never Edit — Generated Targets
- Quick Reference

Reference for every source-of-truth location a new skill or agent occupies in
the `ycc/` tree. Use this when scaffolding to know exactly what to create and where.

---

## Surfaces

### Skill

| Field                | Value                                                                          |
| -------------------- | ------------------------------------------------------------------------------ |
| Path                 | `ycc/skills/<kebab-name>/SKILL.md`                                             |
| Required frontmatter | `name`, `description`                                                          |
| Optional frontmatter | `argument-hint`, `allowed-tools`, `disable-model-invocation`, `user-invocable` |
| Subdirs              | `references/` (static content), `scripts/` (bash helpers)                      |

Skills are user-invocable as native slash commands by default.
Set `user-invocable: false` for passive guidance that should not appear in the
slash menu. Set `disable-model-invocation: true` for explicitly user-triggered
workflows. Both fields must be booleans. `scripts/validate-ycc-skills.sh`
validates frontmatter and rejects the retired `ycc/commands/` directory.

The `description` field is the trigger surface for Claude Code — include plain-language
phrasing that describes when the skill should activate.

Script and reference paths inside the skill body use the plugin root variable:

```
${CLAUDE_PLUGIN_ROOT}/skills/<kebab-name>/scripts/<name>.sh
${CLAUDE_PLUGIN_ROOT}/skills/<kebab-name>/references/<name>.md
```

The skill body is freeform markdown organized into phases.

---

### Agent

| Field                | Value                                |
| -------------------- | ------------------------------------ |
| Path                 | `ycc/agents/<kebab-name>.md`         |
| Required frontmatter | `name`, `description`                |
| Optional frontmatter | `tools`, `model`                     |
| Invocation           | Invoked by skills via the Agent tool |

The agent body is the system prompt. Agents are invoked by skills, not
directly by users. Always ensure a skill will consume the agent before
adding it.

---

### Shared Helper Script

| Field       | Value                                                    |
| ----------- | -------------------------------------------------------- |
| Path        | `ycc/skills/_shared/scripts/<kebab-name>.sh`             |
| Sourced via | `${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/<name>.sh` |
| Threshold   | Only create when two or more distinct skills need it     |

All scripts must start with `#!/usr/bin/env bash` and use `set -euo pipefail`. Write
output to stdout and errors to stderr. Exit 0 on success, 1 on error.

---

## Post-Scaffold Required Commands

After scaffolding any surface, always run these in order:

```sh
# 1. Regenerate inventory + Cursor + Codex + opencode bundles from source
./scripts/sync.sh

# 2. Run the full validator sweep
./scripts/validate.sh

# 3. If scripts were scaffolded, make them executable
chmod +x ycc/skills/<name>/scripts/*.sh
```

Do not skip `./scripts/sync.sh`. The generated bundles under `.cursor-plugin/`,
`.codex-plugin/`, and `.opencode-plugin/` go stale immediately when `ycc/` changes.

---

## Never Edit — Generated Targets

The following paths are **regenerated** by `./scripts/sync.sh`. Do not hand-edit them:

- `.cursor-plugin/**`
- `.codex-plugin/**`
- `.opencode-plugin/**`
- `docs/inventory.json`

Make all source changes under `ycc/` and let the generators produce the bundles.

---

## Quick Reference

```
ycc/
├── skills/
│   ├── _shared/
│   │   └── scripts/        ← shared bash helpers
│   └── <kebab-name>/
│       ├── SKILL.md         ← required (add `user-invocable: false` for passive guidance)
│       ├── references/      ← static reference docs
│       └── scripts/         ← skill-scoped bash helpers
└── agents/
    └── <kebab-name>.md      ← agent system prompt
```

Invocation policy: workflow, arguments, examples, and tool permissions live in
`SKILL.md`; no wrapper command is created. Enforced by
`scripts/validate-ycc-skills.sh`.

---

See also: `when-not-to-scaffold.md` (this directory), `CLAUDE.md` (repo root).
