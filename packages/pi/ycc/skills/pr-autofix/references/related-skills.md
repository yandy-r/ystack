# Related Skills

| Skill                    | Input                          | Output                                                | Resolves PR threads? | CI loop? |
| ------------------------ | ------------------------------ | ----------------------------------------------------- | -------------------- | -------- |
| `/skill:pr-autofix` (this) | GitHub PR comments (all)       | Fixes pushed + threads closed + summary comment       | Yes                  | Yes      |
| `/skill:review-fix`        | `/skill:code-review` artifact    | Fixes in tree + Status updated + fix report           | No (artifact-driven) | No       |
| `/skill:quick-fix`         | Inline `quick-review` findings | Fixes in tree (no artifact, no commit)                | No                   | No       |
| `/skill:prp-pr`            | Branch state                   | PR created (+ optional CI loop)                       | No                   | Yes      |
| `coderabbit:autofix`     | CodeRabbit threads only        | Fixes + summary comment (no CI, no thread resolution) | No                   | No       |

`/skill:review-fix` consumes `/skill:code-review` artifacts (review-finding ID + Status fields). `/skill:pr-autofix` consumes GitHub PR comments directly. Both share the per-finding agent dispatch model and the CI auto-fix loop. `pr-autofix` is the vendor-neutral counterpart to `coderabbit:autofix`.
