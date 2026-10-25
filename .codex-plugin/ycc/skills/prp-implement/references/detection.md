# PRP Detection Details

## Package Manager Detection

| File Exists                            | Package Manager | Runner                  |
| -------------------------------------- | --------------- | ----------------------- |
| `bun.lockb`                            | bun             | `bun run`               |
| `pnpm-lock.yaml`                       | pnpm            | `pnpm run`              |
| `yarn.lock`                            | yarn            | `yarn`                  |
| `package-lock.json`                    | npm             | `npm run`               |
| `pyproject.toml` or `requirements.txt` | uv / pip        | `uv run` or `python -m` |
| `Cargo.toml`                           | cargo           | `cargo`                 |
| `go.mod`                               | go              | `go`                    |

### Validation Scripts

Check `package.json` (or equivalent) for available scripts:

```bash
cat package.json | grep -A 20 '"scripts"'
```

Note available commands for: type-check, lint, test, build.

### Parallel-Capable Detection

After reading the plan, check whether it was written in parallel mode by looking for a `## Batches` section:

```bash
# grep -c prints the count itself; exit 1 only means zero matches. Exit codes 0 and 1
# both leave exactly one integer on stdout; anything higher is a real read error.
grep -c "^## Batches" "$PLAN_PATH"; [ $? -le 1 ]
```

- **Count > 0** → Plan is **parallel-capable**. Parse the `Batches` table to extract batch ordering and `BATCH:` fields from tasks.
- **Count = 0** → Plan is **sequential only**.

### Execution Mode Decision

Decide between **Path A (Sequential)**, **Path B (Parallel sub-agents)**, and **Path C (Agent team)** based on the flags and plan capability:

| Flags        | Parallel-capable plan | Action                                                                                                                                                                                                                                                     |
| ------------ | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--team`     | Yes                   | Proceed with **Path C** (agent-team batch execution) — no prompt                                                                                                                                                                                           |
| `--team`     | No                    | **Abort** with: _"`--team` requires a parallel-capable plan (with `## Batches` section). This plan is sequential — re-run with `--parallel` to fall back to standalone sub-agents, or omit the flag for sequential execution."_ Do not silently fall back. |
| `--parallel` | Yes                   | Proceed with **Path B** (parallel sub-agent batch execution) — no prompt                                                                                                                                                                                   |
| `--parallel` | No                    | Warn: _"Plan has no `Batches` section — cannot run in parallel. Falling back to sequential execution."_ → **Path A**                                                                                                                                       |
| (none)       | Yes                   | Use `ask the user` to prompt: _"This plan is parallel-capable ({N} tasks in {M} batches, max width {X}). Run sequential / parallel sub-agents / agent team?"_. Accept user's choice → **Path A**, **Path B**, or **Path C**.                            |
| (none)       | No                    | Proceed with **Path A** (sequential) — default, no prompt                                                                                                                                                                                                  |

Record the chosen mode as `EXECUTION_MODE=sequential|parallel|agent_team` for use in Phase 3.

**CHECKPOINT**: Plan loaded. All sections identified. Tasks extracted. Parallel capability detected. Execution mode chosen.
