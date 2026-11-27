---
name: ycc-common-git-workflow
description: When committing changes or preparing a pull request, use Conventional
  Commits and summarize the full branch diff with an honest test plan. Applies to
  every change.
---

# Git Workflow

## Commits

Use Conventional Commits: `<type>[optional scope]: <description>`.
Types: feat, fix, refactor, docs, test, chore, perf, ci.

## Pull Requests

1. Analyze the full branch history, not just the latest commit.
2. Use `git diff [base-branch]...HEAD` to summarize the complete change.
3. Follow the project PR template and link the related issue.
4. Include an honest test plan, with unperformed checks marked explicitly.
5. Push with `-u` when publishing a new branch.
