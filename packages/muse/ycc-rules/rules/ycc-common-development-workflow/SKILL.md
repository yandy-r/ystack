---
name: ycc-common-development-workflow
description: When starting a feature or bug fix, check reuse and library behavior,
  then plan, test and review before committing.
---

# Development Workflow

The Feature Implementation Workflow describes the development pipeline: research, planning, TDD, code review, and then committing to git.

## Feature Implementation Workflow

0. **Research & Reuse** _(mandatory before any new implementation)_
   - **Local first:** Search the current repository for existing implementations, helpers, and patterns before writing anything new.
   - **GitHub code search when available:** If the GitHub CLI is installed and authenticated, run `gh search repos` and `gh search code` for existing implementations and templates.
   - **Library docs:** Confirm API behavior, package usage, and version-specific details in primary vendor docs (Context7 when available, otherwise the official docs or installed package sources).
   - **Exa only when the above are insufficient and Exa is available:** Use it for broader web research or discovery.
   - **Check package registries when reachable:** Search npm, PyPI, crates.io, and other registries before writing utility code. Prefer battle-tested libraries over hand-rolled solutions.
   - **Search for adaptable implementations:** Look for open-source projects that solve 80%+ of the problem and can be forked, ported, or wrapped.
   - When a tool or network service is unavailable, note which searches were skipped and continue with the local and primary-doc fallbacks.
   - Prefer adopting or porting a proven approach over writing net-new code when it meets the requirement.

1. **Plan First**
   - Use the **planner** agent, when registered, to create the implementation plan; otherwise plan in the current session
   - Generate planning docs before coding: PRD, architecture, system_design, tech_doc, task_list
   - Identify dependencies and risks
   - Break down into phases

2. **TDD Approach**
   - Write tests first (RED)
   - Implement to pass tests (GREEN)
   - Refactor (IMPROVE)
   - Verify 80%+ coverage

3. **Code Review**
   - Use the **code-reviewer** agent, when registered, immediately after writing code; otherwise review the diff in the current session
   - Address CRITICAL and HIGH issues
   - Fix MEDIUM issues when possible

4. **Prepare for publication**
   - Follow project commit and PR conventions; report verification honestly.

5. **Pre-Review Checks**
   - Verify all automated checks (CI/CD) are passing
   - Resolve any merge conflicts
   - Ensure branch is up to date with target branch
   - Only request review after these checks pass
