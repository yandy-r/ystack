# hooks-workflow: per-target support notes

## Contents

- Overview
- Claude Code
- Cursor
- Codex
- Why we refuse to fabricate unsupported config
- Template placeholders
- How to update this doc

## Overview

This document records the per-target hook maturity for the three deployment targets
supported by the `ycc` bundle: Claude Code, Cursor, and Codex. The verdicts here are
derived from the authoritative source at
`ycc/skills/_shared/references/target-capability-matrix.md`; this file provides the
prose rationale and link context that the matrix table cannot. The core stance is that
the `hooks-workflow` skill refuses to fabricate config for an unsupported target.
Cross-platform hook parity does not exist, and this document explains why rather than
papering over the gaps.

## Claude Code

Hook support on Claude Code is production-grade and is the primary target for this skill.

- **PreToolUse**
  - Status: supported
  - Documentation: Anthropic hooks guide — <https://docs.anthropic.com/en/docs/claude-code/hooks-guide>
  - Config location: `~/.claude/settings.json` (global) or `.claude/settings.json` in the
    repo root (project-local). Project-local settings take precedence when both exist.
  - Execution model: Claude Code invokes the hook command as a subprocess with the tool
    invocation JSON serialized to stdin. The hook may exit non-zero to block the tool call.

- **PostToolUse**
  - Status: supported
  - Documentation: see PreToolUse link above; the same hooks guide covers all event types.
  - Config location: same as PreToolUse — `~/.claude/settings.json` or `.claude/settings.json`.
  - Execution model: Claude Code invokes the hook command after the tool returns. The hook
    receives the tool result on stdin. A non-zero exit does not roll back the tool result but
    is surfaced as a warning.

- **Stop**
  - Status: supported
  - Documentation: see PreToolUse link above.
  - Config location: same as above.
  - Execution model: Claude Code invokes the Stop hook when the model signals it has finished
    a turn. The hook command receives a JSON summary on stdin. A non-zero exit causes Claude
    Code to surface the error before terminating the turn.

## Cursor

Status: **partial**

Cursor does not run hooks natively. There is no execution surface equivalent to Claude
Code's `~/.claude/settings.json` hooks runner. The `hooks-workflow` skill therefore
cannot produce executable hook config for a Cursor target. Instead, the skill emits
`.mdc` rule fragments that embed advisory text describing what the hook would do if
Cursor had native hook support. These fragments are written to
`ycc/rules/<language>/hooks-cursor.mdc` and are intended as reference documentation for
Cursor users, not as runtime configuration.

The `partial` status for all three hook events reflects the fact that the advisory
fragments are useful documentation artifacts even though they are not executed. See the
matrix notes for each event at
`ycc/skills/_shared/references/target-capability-matrix.md`.

## Codex

Status: **unsupported**

The OpenAI Codex config reference documents `features.codex_hooks` as under development.
As of the April 2026 research audit, no primary source confirms that Codex hook execution
is in general availability. The contradiction between "hooks are referenced in the config
docs" and "no GA announcement exists" was logged at
`research/plugin-additions/evidence/verification-log.md` under the "Hook adoption timing"
contradiction entry. The resolution adopted there — and enforced by this skill — is to
treat Codex hooks as `unsupported` pending a verified GA announcement.

The `hooks-workflow` skill emits advisory-only TOML fragments for Codex targets to
document hook intent for future use. These fragments are printed to stdout by default
and require `--force` to write to disk. Writing them to disk signals deliberate intent
and acknowledges that the fragments are not executable today.

## Why we refuse to fabricate unsupported config

Emitting configuration that a target cannot execute creates a false sense of security.
A developer who finds a `[hooks.PreToolUse]` block in their Codex config may believe
the hook is running when it is not. Silent failures are harder to debug than explicit
refusals. The `hooks-workflow` skill adopts a fail-loud stance: if the matrix marks a
target as `unsupported` for a given event, the skill stops and says so rather than
emitting config that will be silently ignored.

Advisory-only output (Cursor `.mdc` fragments and Codex TOML fragments) is acceptable
because it carries a mandatory leading comment that makes the non-executable nature
unambiguous. Removing or suppressing that comment is not supported.

## Template placeholders

The three output templates under `ycc/skills/hooks-workflow/references/templates/` share
a common placeholder set. Build scripts substitute these values at generation time.

- `{{LANGUAGE}}` — the language slug passed as the first positional argument to the
  skill, e.g. `python`, `typescript`, `go`. Resolves to the `ycc/rules/<language>/`
  directory name.

- `{{EVENT}}` — the hook event name, one of `PreToolUse`, `PostToolUse`, or `Stop`.
  Matches the key used in the Claude Code `settings.json` hooks object and in the
  capability matrix row prefix.

- `{{COMMAND}}` — the shell command string extracted from the resolved rules file. This
  is the literal command that will be passed to `build-hook-config.sh` and written into
  the emitted artifact. For Cursor and Codex targets, this command is advisory; it is
  not executed by the target runtime.

- `{{MATCHER}}` — the Claude Code tool matcher string (e.g. a tool name like `Bash` or
  a glob pattern). May be an empty string for events that do not scope to a specific
  tool. On Cursor and Codex targets, the matcher is written as a comment only.

## How to update this doc

Before editing capability verdicts here, update the matrix first:

1. Revise the relevant cell in
   `ycc/skills/_shared/references/target-capability-matrix.md`.
2. Update the corresponding Notes entry in the same file.
3. Update the prose section in this document to reflect the new verdict and its
   rationale.
4. Re-run the compatibility audit via `ycc:compatibility-audit` to confirm no
   downstream assertions are broken.

Do not change the status labels in this document without first changing the matrix. The
matrix is the parser-facing source of truth; this file is the human-readable companion.
