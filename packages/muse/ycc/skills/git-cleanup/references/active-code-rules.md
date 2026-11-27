# Active-Code Rules

## Contents

- R1 — Recent tip commit
- R2 — Unpushed commits
- R3 — Dirty worktree or attached stash
- R4 — Head or base of an open PR
- R5 — Referenced in tracked files
- R6 — Linked to an active issue
- R7 — Protected name
- R8 — Recent reflog activity
- R9 — Retired maintenance branch (release model only)
- R10 — Sync-merge anti-pattern (release model only, informational)
- Decision Matrix
- Worktree-specific notes
- PR / Issue–specific notes

Reference for the Phase 2 gate in `ycc/skills/git-cleanup/SKILL.md`. Each rule
below flags a candidate as **active** (must be excluded from the "Stale" list).
A candidate becomes **Stale** only when it matches **none** of these rules.
Candidates with conflicting signals land in **Ambiguous** and are surfaced to
the user per-item.

The rules are ordered by specificity. Evaluate them all — multiple matches
strengthen confidence in the classification.

R9 and R10 apply only when the repo has a `RELEASING.md`
(`~/.local/share/ycc/muse/ycc/ycc-shared/scripts/release-state.sh get` prints
`present=1`). Without one, R1–R8 are the whole rule set. A malformed state block
(exit 2) stops the audit before any rule runs: show the parse error and point at
`/release-model --audit`.

---

## R1 — Recent tip commit

**Signal:** The branch's tip commit date is newer than `stale-days` (default 90).

**How to check:**

```
git for-each-ref refs/heads/<name> --format='%(committerdate:unix)'
```

**Rationale:** Recent commits mean the branch was worked on; even without an
upstream it is probably WIP. Do not pressure-delete someone's fresh work.

**Edge case:** A rebase or `commit --amend` resets committer date. Prefer
`committerdate` over `authordate` — amend recency is the relevant signal.

---

## R2 — Unpushed commits

**Signal:** The local branch has commits that are not in its upstream, or no
upstream is configured **and** the branch has commits not in the default
branch.

**How to check:**

```
# With upstream:
git rev-list --count @{u}..HEAD

# Without upstream:
git rev-list --count <default-branch>..<name>
```

**Rationale:** Losing unpushed work is unrecoverable once the ref is gone
(modulo reflog, which is fragile and expires). Unpushed = active by default.

**Override:** An explicit user-confirmed Ambiguous decision may allow
deletion — but never auto-skip this rule.

---

## R3 — Dirty worktree or attached stash

**Signal:** For a worktree — `git -C <worktree> status --porcelain` returns
any line. OR: a stash entry lists the branch in its message.

**How to check:**

```
git -C <worktree-path> status --porcelain
git stash list --format='%gd %s' | grep -Fw "<branch-name>"
```

**Rationale:** Destroying a dirty worktree drops uncommitted edits — the
most common way tooling silently loses hours of work.

---

## R4 — Head or base of an open PR

**Signal:** The branch is the `headRef` of any open PR (the PR's source
branch), OR the `baseRef` of any open PR (the target branch — doubly
protected).

**How to check (GitHub):**

```
gh pr list --state=open --json number,headRefName,baseRefName \
  --jq '.[] | [.headRefName, .baseRefName] | @tsv'
```

**Rationale:** Deleting a head-ref closes the PR as-if-merged and loses the
branch's distinct history on the server. Deleting a base-ref orphans all PRs
targeting it. Base-refs are **never** eligible even when the user insists —
surface as Protected, not Ambiguous.

---

## R5 — Referenced in tracked files

**Signal:** `git grep -l -w <branch-name>` finds at least one match in the
tracked working tree (CI config, release notes, issue templates, docs, code
comments).

**How to check:**

```
git grep -l -w "<branch-name>" -- \
  ':!*.lock' ':!*.min.*' ':!dist/' ':!build/'
```

**Rationale:** A textual mention in tracked files means the branch is
load-bearing — CI pins a release branch, a migration guide references a
feature branch, etc. Deleting it breaks something off-site.

**Tuning:** Exclude generated output to avoid false positives. The default
excludes above are a safe starting point; repos with unusual build output
directories should extend via `.gitattributes` or per-repo overrides.

---

## R6 — Linked to an active issue

**Signal:** A PR or branch body references an open issue updated within
`stale-days`, OR carries a repo label like `status:in-progress` /
`status:needs-info`.

**How to check (GitHub):**

```
gh pr view <n> --json body,labels,closingIssuesReferences
gh issue list --state=open --label='status:in-progress' --json number
```

**Rationale:** A branch tied to active triage work is not stale, even if its
last commit is old — the issue owner may be waiting on external input.

**Label taxonomy:** Use only labels that exist in the repo. Do not invent
`stale` or `wontfix` labels; fall back to a plain comment if no matching
label exists.

---

## R7 — Protected name

**Signal:** The branch name matches `main`, `master`, `develop`, the
repository's default branch, or any user-supplied `--protect=<pattern>`. With a
`RELEASING.md`, the state's `trunk` and every branch in its `maintenance` list
(local or remote) also match.

**How to check:**

```
git symbolic-ref refs/remotes/origin/HEAD          # default branch
# User-supplied patterns from --protect flags
~/.local/share/ycc/muse/ycc/ycc-shared/scripts/release-state.sh get
# present=1 → protect `trunk` and each entry of `maintenance`
```

**Rationale:** Nothing good comes from deleting `main`. This rule is the
fail-closed backstop; it fires even if every other rule returns "stale".

**Always protected (hardcoded):** `main`, `master`, `develop`, and the
`origin/HEAD` symbolic ref. With a `RELEASING.md`, the state's `trunk` and
`maintenance` branches join this set. Patterns from `--protect` combine with
these, never replace them.

---

## R8 — Recent reflog activity

**Signal:** `git reflog show <branch>` shows a reflog entry newer than
`stale-days`.

**How to check:**

```
git reflog show --date=unix <branch> | head -1 | awk '{print $NF}'
```

**Rationale:** The reflog captures local-only motion — checkouts, rebases,
resets — that Phase 1 collection commands miss. A branch with no new commits
but active reflog motion is probably mid-rebase.

**Caveat:** Reflog expires per `gc.reflogExpire` (default 90d). Treat missing
reflog as "no signal", not "inactive".

---

## R9 — Retired maintenance branch (release model only)

**Signal:** `RELEASING.md` is present and a local or remote `release/*` branch
is not in the state's `maintenance` list, and R4 (base-ref) and R7 did not
protect it. Branches in the state's `frozen` list match too and are flagged
"frozen by RELEASING.md".

**How to check:**

```
~/.local/share/ycc/muse/ycc/ycc-shared/scripts/release-state.sh get   # maintenance=, frozen=
git for-each-ref refs/heads/release/ --format='%(refname:short)'
git for-each-ref refs/remotes/ --format='%(refname:short)' | grep -E '^[^/]+/release/'
```

**Rationale:** Under the release model a `release/X.Y` branch outside the
support window receives no more patches, so it is cleanup material — but it is
also the only branch pointing at that line's last patch. Deleting it without a
tag loses an easy way back.

**Classification:** **Retired maintenance branch** — its own report category,
never Stale and never part of a bulk apply. R9 takes precedence over R1–R3,
R5, R6 and R8: `RELEASING.md` itself names frozen branches, so R5 would
otherwise mark every one of them active. The report suggests
`git tag archive/<branch> <branch>` (and pushing that tag for a remote branch)
before deletion, and each deletion requires explicit per-item confirmation.

---

## R10 — Sync-merge anti-pattern (release model only, informational)

**Signal:** `RELEASING.md` is present and either

- a local or remote branch other than the trunk has a name containing `sync`,
  or
- a merge commit newer than `stale-days` that is not on the trunk, on any
  branch other than the trunk, has a subject matching
  `^Merge (remote-tracking )?branch '?([A-Za-z0-9._-]+/)?(main|master|trunk|develop|<trunk>)'? into`.

**How to check:**

```
git log --merges --since="<stale-days> days ago" --format='%h|%s' -E \
  --grep="^Merge (remote-tracking )?branch '?([A-Za-z0-9._-]+/)?(main|master|trunk|develop|<trunk>)'? into" \
  "origin/<trunk>..<branch>"
```

The optional `<remote>/` prefix catches `Merge remote-tracking branch
'origin/main' into …`, and the GitHub "Update branch" button's
`Merge branch 'main' into …`.

**Rationale:** The branching model forbids merging one long-lived branch into
another to "sync" it; code moves between the trunk and maintenance branches
only by cherry-pick. Sync merges tangle history, drag unreleased trunk work
into maintenance lines, and make backports unreviewable.

**Classification:** Reported under **Anti-patterns (informational)** with the
branch, commit hash and subject. It never changes a candidate's
classification, never blocks a deletion, and never produces a cleanup
command. The suggested fix is to rebase topic branches onto
`origin/<trunk>` and to move fixes between lines with `/backport`.

---

## Decision Matrix

| R1 recent | R2 unpushed | R3 dirty | R4 open-PR | R5 ref'd | R6 issue | R7 protected | R8 reflog | R9 retired | Classification             |
| --------- | ----------- | -------- | ---------- | -------- | -------- | ------------ | --------- | ---------- | -------------------------- |
| any       | any         | any      | any        | any      | any      | ✓            | any       | any        | Protected                  |
| any       | any         | any      | base-ref   | any      | any      | —            | any       | any        | Protected                  |
| any       | any         | any      | head-ref   | any      | any      | —            | any       | ✓          | Retired maintenance branch |
| any       | any         | any      | —          | any      | any      | —            | any       | ✓          | Retired maintenance branch |
| ✓         | any         | any      | any        | any      | any      | —            | any       | —          | Active                     |
| any       | ✓           | any      | any        | any      | any      | —            | any       | —          | Active                     |
| any       | any         | ✓        | any        | any      | any      | —            | any       | —          | Active                     |
| any       | any         | any      | head-ref   | any      | any      | —            | any       | —          | Active                     |
| any       | any         | any      | any        | ✓        | any      | —            | any       | —          | Active                     |
| any       | any         | any      | any        | any      | ✓        | —            | any       | —          | Active                     |
| —         | —           | —        | —          | —        | —        | —            | ✓         | —          | Ambiguous                  |
| —         | —           | —        | —          | —        | —        | —            | —         | —          | **Stale**                  |

Empty row = rule returned no signal. "any" = value doesn't affect outcome once
a higher-priority rule has matched. Classification is the first match reading
top-down. R9 only fires with a `RELEASING.md` and sits directly below the
protected rows, so a retired maintenance branch is never reported as Active or
Stale; one that heads an open PR is still retired, and the report notes the PR. R10 is informational and does not
appear in the matrix.

## Worktree-specific notes

Worktrees attach to branches, so R1–R8 apply transitively via the attached
branch. Additionally, a worktree is **active** if any of:

- The directory path no longer exists on disk (prune candidate — report, but
  prune is a safe cleanup, not a destructive action).
- The attached branch is `[gone]` — upstream deleted. Surface as Ambiguous:
  safe to remove IF R2 (unpushed commits) does not fire.


- The worktree sits under the legacy global ycc root (`~/.claude-worktrees/`)
  instead of a preferred repo-local parent: `.claude/worktrees/`,
  `.opencode/worktrees/`, `.codex/worktrees/`, `.cursor/worktrees/`,
  `.omp/worktrees/` or `.agents/worktrees/` under the repo root. Report and offer
  relocation; do not delete without explicit approval.
- The worktree sits under `~/.omp/wt`. OMP manages that base
  (`omp worktree clear`); report it as active and never delete it.

## PR / Issue–specific notes

For remote-domain candidates (PRs and issues), use the equivalent signals:

- R1 recent → `updatedAt` within `stale-days`.
- R4 open-PR → the PR is open (self-reference) OR its branch is the base of
  another open PR.
- R6 linked issues → `closingIssuesReferences` + referenced issues' status.
- R7 protected → never auto-close a PR or issue whose body contains a
  user-supplied `--protect=<pattern>` match or has the repo's default
  "pinned" / "tracking" label family.
