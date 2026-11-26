# ycc plugin evals

Trigger and behavior evals for the `ycc` plugin (`claude plugin eval`, Claude Code
2.1.299; requires >= 2.1.269). Runs are real model calls, so they are **not** part of
CI. Run them locally:

```bash
./scripts/eval.sh                                  # default run (39 cases), $8 ceiling
./scripts/eval.sh --suite trigger                  # trigger family only (policy, behavior also valid)
./scripts/eval.sh --case 'plan-near-miss-*'        # one family
./scripts/eval.sh --quarantine                     # quarantined cases (currently none)
```

Results land in `ycc/evals/results/` (gitignored). To reset,
`rm -rf ycc/evals/results/*` (and `ycc/evals-quarantine/results/*`).

## Composition

| Case family            | Count | Directory               | What it proves                                                                            |
| ---------------------- | ----- | ----------------------- | ----------------------------------------------------------------------------------------- |
| Should-trigger prompts | 20    | `trigger/`              | natural language loads the expected skill (`tool_used: Skill`, min 1)                     |
| Near-miss prompts      | 12    | `trigger/`              | a sibling prompt does not load the target skill (min 0, max 0)                            |
| Policy no-autoinvoke   | 4     | `policy/`               | `clean` and `git-cleanup` never auto-load on natural language (manual-only safety policy) |
| Behavior gates         | 3     | `behavior/`             | hard gates hold inside a scratch repo                                                     |
| **Default run**        | 39    |                         | `./scripts/eval.sh` discovers only `ycc/evals/`                                           |
| Quarantined            | 0     | `ycc/evals-quarantine/` | empty; the 3 YAN-1114 cases were promoted to `trigger/` (YAN-1146)                        |

Authored total: 39 cases (20 should-trigger + 12 near-miss + 4 policy + 3 behavior),
all in the default run.
Baseline (Claude Code 2.1.299, `--runs 1`): 32/39 before the restructure; the 4
policy cases and the 3 since-promoted YAN-1114 cases were the 7 failures. The full
39-case default run has not been re-measured with a paid run since then.

Tag filters: `trigger`, `policy`, `behavior`.

## Behavior tests

Each behavior case ships a `scaffold.sh` that builds a disposable git repo
so the skill never touches the repo under test. They assert on file/branch
state and ref content, tool usage, no file creation, and no branch/worktree
deletion. `git-cleanup-deletes-nothing` uses an explicit `/ycc:git-cleanup
--branches --worktrees` invocation without `--apply` or `--dry-run` and grades only on observable state (report present,
branch refs and worktree metadata intact, no files deleted). Report creation is allowed; deletion of seeded resources is not. The negative
`Skill` grader verifies it did not auto-load; slash expansion injects skill content
directly, so a positive `Skill` grader would be incorrect.

## Quarantine

`ycc/evals-quarantine/` holds known-failing cases kept out of the default run. It
is currently empty. `compare-rate-limit-options`, `validate-research-before-planning`,
and `structure-go-packages` failed the 32/39 baseline because the model inspected
files directly instead of loading the skill. YAN-1114 fixed the `plan`,
`plan-workflow`, and `go-patterns` descriptions, and YAN-1146 moved the three cases
into `trigger/` after single runs passed on Claude Code 2.1.332 ($0.70 total, $1
ceiling per case).

To quarantine a case again, move its directory into `ycc/evals-quarantine/`, tag it
`quarantine`, list it here, and run it explicitly:

```bash
./scripts/eval.sh --quarantine --max-cost-usd 1
```

## Frequency-of-use notes

`clean` and `git-cleanup` carry `disable-model-invocation: true`, so the
model cannot select them on its own. Their coverage is the 4
policy/no-autoinvoke cases in `policy/` (assert the skill is not auto-loaded); users
invoke them explicitly. Slash invocation does not call the `Skill` tool, so
behavior of an explicit invocation is graded on observable state only.

## Known flake

`git-cleanup-policy-no-autoinvoke-stale-resources` failed once (`Skill called 1x`)
in a 2-case rerun and passed in the next 4-case policy run (single runs, cause
unconfirmed). Treat a lone red policy case as a rerun candidate before changing
skill metadata; two consecutive failures belong in the quarantine with a tracking issue.

## Follow-ups

- Description-sharpness work for any shaky case that goes red twice in a row.
- Cross-model runs once the suites are stable.

## Cost

The earlier 39-case baseline (`--runs 1`, one arm) cost $4.59; the current 39-case
default run has not been re-measured. The script's ceiling defaults to $8 to leave
headroom. One in-flight run can still overrun the ceiling; see
`claude plugin eval --help`.
