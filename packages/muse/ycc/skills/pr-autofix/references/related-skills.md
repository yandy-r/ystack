# Related Skills

| Skill                    | Input                          | Output                                                | Resolves PR threads? | CI loop? |
| ------------------------ | ------------------------------ | ----------------------------------------------------- | -------------------- | -------- |
| `/ycc:pr-autofix` (this) | GitHub PR comments (all)       | Fixes pushed + threads closed + summary comment       | Yes                  | Yes      |
| `/ycc:review-fix`        | `/ycc:code-review` artifact    | Fixes in tree + Status updated + fix report           | No (artifact-driven) | No       |
| `/ycc:quick-fix`         | Inline `quick-review` findings | Fixes in tree (no artifact, no commit)                | No                   | No       |
| `/ycc:prp-pr`            | Branch state                   | PR created (+ optional CI loop)                       | No                   | Yes      |
| `coderabbit:autofix`     | CodeRabbit threads only        | Fixes + summary comment (no CI, no thread resolution) | No                   | No       |

`/ycc:review-fix` consumes `/ycc:code-review` artifacts (review-finding ID + Status fields). `/ycc:pr-autofix` consumes GitHub PR comments directly. Both share the per-finding agent dispatch model and the CI auto-fix loop. `pr-autofix` is the vendor-neutral counterpart to `coderabbit:autofix`.
