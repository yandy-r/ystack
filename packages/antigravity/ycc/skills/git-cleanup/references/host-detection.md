# Host Detection and Client Selection

## Contents

- Selection priority
- Host inference from `origin`
- Detecting MCP availability
- CLI availability probes
- Read operations used in Phase 1
- Write operations (only with `--apply` + user approval)
- Rate-limit awareness
- Logging

> **Canonical source of truth:** the bundle-wide forge-detection contract lives at
> `~/.gemini/config/plugins/ycc/ycc-shared/references/forge-detection.md`
> (provider values `github` / `forgejo` / `gitea` / `gitlab` / `unknown`; CLIs
> `gh` / `tea` / `glab`; the `forge_detect_provider`, `forge_cli`, `forge_auth_ok`
> detection law implemented in `_shared/scripts/lib/forge.sh`). Prefer that document
> and library for detection. This file is the **git-cleanup-specific supplement**:
> it maps the resolved provider to the concrete read/write cleanup operations this
> skill performs. When the two disagree on detection, the canonical reference wins.

Reference for Phase 0 of `ycc/skills/git-cleanup/SKILL.md`. Given a repository,
determine (1) which remote host the audit should query and (2) which client
library / CLI / MCP server to use for each operation.

## Selection priority

For GitHub repositories, pick the first available:

1. **MCP GitHub tools** (`mcp__github__*`) — loaded into the current session.
2. **`gh` CLI** — authenticated (`gh auth status` returns 0).
3. **Local-only mode** — skip `--prs` and `--issues` with a loud notice.

For GitLab repositories, pick the first available:

1. **`glab` CLI** — authenticated (`glab auth status` returns 0).
2. **Local-only mode** — skip `--prs` and `--issues` with a loud notice.

For Forgejo / Gitea repositories (provider `forgejo` or `gitea` — same tooling
family, both driven by `tea`), pick the first available:

1. **`tea` CLI** — a configured login (`tea login list` shows a `://` entry).
2. **Local-only mode** — skip `--prs` and `--issues` with a loud notice.

Never mix clients within a single audit. Decide once in Phase 0 and log the
decision in `.git-cleanup/report.md` under "Host-API notes".

## Host inference from `origin`

When `--host=auto` (default), parse `git remote get-url origin`:

| Pattern match                                 | Inferred host   |
| --------------------------------------------- | --------------- |
| `github.com:`, `github.com/`, `*.github.com/` | GitHub          |
| `gitlab.com:`, `gitlab.com/`, `/api/v4/`      | GitLab          |
| Self-hosted GitHub Enterprise (`GHE_HOST`)    | GitHub          |
| Self-hosted GitLab                            | GitLab          |
| Self-hosted Forgejo / Gitea                   | Forgejo / Gitea |
| Anything else                                 | Unknown         |

Accept SSH, HTTPS, and `git://` URLs. Strip any `.git` suffix before matching.

**Self-hosted GitHub Enterprise:** look for `GH_HOST` / `GITHUB_HOST` in the
user's environment, or a match in `~/.config/gh/hosts.yml`. If found, treat
as GitHub and route `gh` calls to that host.

**Self-hosted GitLab:** `glab` reads its host list from `~/.config/glab-cli/`.
If the `origin` host matches one of its configured hosts, treat as GitLab.

**Self-hosted Forgejo / Gitea:** `tea` reads its login list from
`~/.config/tea/`. If the `origin` host matches a configured `tea login list`
entry, treat as the Gitea family and route `tea` calls to that host. The two are
the same tooling family (`forge_cli` maps both to `tea`); the canonical reference
distinguishes `forgejo` from `gitea` only for messaging.

## Detecting MCP availability

MCP tools are exposed through the session's tool list, not via shell commands.
Look for any tool whose name starts with `mcp__github__`. If found, prefer
those over `gh` — they avoid subprocess spawn cost and sidestep shell-quoting
hazards.

Representative MCP tools for this skill:

- `mcp__github__list_pull_requests` / `mcp__github__pull_request_read`
- `mcp__github__list_issues` / `mcp__github__issue_read`
- `mcp__github__issue_write` (for closing stale issues in Phase 5)

When MCP tools are unavailable (standalone execution, alternate harness),
fall back to `gh` without warning — both are equally valid.

## CLI availability probes

Run probes once in Phase 0 and cache the result for the rest of the audit:

```bash
command -v gh   >/dev/null && gh auth status   >/dev/null 2>&1 && echo "gh: ok"   || echo "gh: unavailable"
command -v glab >/dev/null && glab auth status >/dev/null 2>&1 && echo "glab: ok" || echo "glab: unavailable"
```

**Do not call the host API during probing.** `auth status` is a local check
and does not burn rate-limit budget.

## Read operations used in Phase 1

### GitHub (`gh` fallbacks)

```bash
# Stale open PRs authored by current user
gh pr list --state=open --author=@me \
  --json number,title,state,headRefName,baseRefName,updatedAt,isDraft

# Merged PRs whose local branch still exists
gh pr list --state=merged --author=@me \
  --json number,headRefName,mergedAt --limit 200

# Stale open issues
gh issue list --state=open --author=@me \
  --json number,title,updatedAt,labels
```

Use `--limit` to bound output; GitHub defaults to 30 which is too small for
long-lived accounts. 200 is a reasonable upper bound for per-user queries.

### GitLab (`glab` fallbacks)

```bash
glab mr list    --state=opened --assignee=@me --per-page=100
glab issue list --state=opened --assignee=@me --per-page=100
```

GitLab's "Merge Request" maps to GitHub's "Pull Request" one-for-one for this
skill's purposes. Both concepts share the same R-rules (see
`active-code-rules.md`).

### Forgejo / Gitea (`tea` fallbacks)

```bash
# Open PRs ("pulls") for the current repo
tea pull list --state open

# Merged/closed PRs (filter the list output for merged state)
tea pull list --state closed

# Open issues
tea issues list --state open
```

`tea` operates on the repo bound to the current directory's `origin` remote (it
reads `.git/config`); pass `--repo owner/name` only when overriding. Forgejo's
"Pull Request" maps to GitHub's one-for-one and shares the same R-rules (see
`active-code-rules.md`). `tea` paginates with `--limit` (alias for page size);
bound large lists the same way `--limit` bounds `gh` output.

## Write operations (only with `--apply` + user approval)

### GitHub

| Action                 | MCP tool                                                            | `gh` fallback                       |
| ---------------------- | ------------------------------------------------------------------- | ----------------------------------- |
| Close a PR             | `mcp__github__pull_request_review_write` (dismiss) or `issue_write` | `gh pr close <n>`                   |
| Close an issue         | `mcp__github__issue_write`                                          | `gh issue close <n>`                |
| Add a label            | `mcp__github__issue_write`                                          | `gh issue edit <n> --add-label ...` |
| Delete a remote branch | (n/a — use git)                                                     | `git push origin --delete <name>`   |

### GitLab

| Action         | `glab` command                        |
| -------------- | ------------------------------------- |
| Close an MR    | `glab mr close <iid>`                 |
| Close an issue | `glab issue close <iid>`              |
| Add a label    | `glab issue update <iid> --label ...` |

### Forgejo / Gitea

| Action                 | `tea` command                                     |
| ---------------------- | ------------------------------------------------- |
| Close a PR             | `tea pull close <n>`                              |
| Close an issue         | `tea issues close <n>`                            |
| Add a label            | `tea issues edit <n> --add-labels ...`            |
| Delete a remote branch | (n/a — use git) `git push origin --delete <name>` |

## Rate-limit awareness

Both GitHub (5,000 req/hr authenticated) and GitLab (600 req/min default for
Cloud) have generous budgets for a cleanup audit, but list calls can balloon
fast if `--limit` is omitted. The audit should:

- Page responses rather than repeat unfiltered list calls.
- Reuse fetched data across R-rules — fetch PRs once, evaluate R4 / R6 against
  the cached result.
- Respect `x-ratelimit-remaining` when close to zero: surface a notice and
  pause rather than fail mid-audit.

`gh` exposes the remaining budget via `gh api rate_limit`. Check before the
first list call in a large repo.

## Logging

Record host decisions in `.git-cleanup/report.md` under **Host-API notes**:

```
host:         github
client:       mcp__github__ (preferred)
fallback:     gh (available, unused)
pr-limit:     4,812 / 5,000 remaining
skipped:      none
```

If the host was unknown or both clients were unavailable:

```
host:         unknown (origin = git@example.com:me/repo.git)
client:       none
skipped:      --prs, --issues (no compatible CLI found)
```
