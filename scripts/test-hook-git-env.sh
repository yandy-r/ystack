#!/usr/bin/env bash
# test-hook-git-env.sh — fixture suites must not inherit a git hook's GIT_DIR.
#
# A pre-push hook started from a linked worktree exports
# GIT_DIR=<repo>/.git/worktrees/<name>. Any fixture `git init` (even
# `git -C <tmp> init`) run under it reinitializes the caller's repository and
# writes core.bare=true into its shared config, leaving the main checkout bare.
#
# 1. Replay: run fixture suites from a scratch linked worktree with that
#    GIT_DIR exported, and assert the scratch repository stays non-bare.
# 2. Static: every scripts/test* or scripts/validate-* file that runs
#    `git ... init` must clear or replace the inherited git environment.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ycc-hook-git-env.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

while IFS= read -r git_var; do unset "$git_var"; done < <(git rev-parse --local-env-vars)
unset git_var
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

FAIL=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=1; }

# --- 1. Replay the linked-worktree hook environment --------------------------
# Suites that create git fixtures with a path-less `git -C <dir> init`.
REPLAY_SUITES=(test-plan-workflow-validators.sh)

repo="${SCRATCH}/repo"
git init -q -b main "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init
git -C "$repo" worktree add -q -b hook "${repo}/.wt/hook"
hook_git_dir="$(git -C "${repo}/.wt/hook" rev-parse --absolute-git-dir)"

for suite in "${REPLAY_SUITES[@]}"; do
  if ! (cd "${repo}/.wt/hook" && GIT_DIR="$hook_git_dir" GIT_PREFIX='' \
    "${REPO_ROOT}/scripts/${suite}" >"${SCRATCH}/${suite}.log" 2>&1); then
    fail "${suite} failed under a hook GIT_DIR (see output below)"
    sed 's/^/  | /' "${SCRATCH}/${suite}.log" >&2
  fi
  bare="$(git -C "$repo" config --type=bool core.bare 2>/dev/null || echo unset)"
  if [[ "$bare" == true ]]; then
    fail "${suite} set core.bare=true on the repository named by GIT_DIR"
    git -C "$repo" config core.bare false
  else
    pass "${suite} leaves the hook repository non-bare"
  fi
done

# --- 2. Static: fixture git init call sites must isolate the environment -----
# Accepted isolation: clear the local env vars, run under env -i, unset GIT_DIR,
# or (Python) drop GIT_* keys from the child env.
isolates() {
  grep -qE 'local-env-vars|env -i|unset GIT_DIR|startswith\(.GIT_.\)' "$1"
}

cd "$REPO_ROOT"
checked=0
while IFS= read -r file; do
  grep -qE '(\bgit\b|\$\{GIT[:}]|["'\'']git["'\''])[^#]*\binit\b' "$file" || continue
  checked=$((checked + 1))
  guard="$file"
  # Install suites are sourced by scripts/tests/install/lib.sh, which isolates.
  [[ "$file" == scripts/tests/install/* ]] && guard=scripts/tests/install/lib.sh
  if isolates "$guard"; then
    pass "${file} isolates the git environment"
  else
    fail "${file} runs git init without clearing hook-exported GIT_* variables"
  fi
done < <(git ls-files 'scripts/test-*.sh' 'scripts/test_*.py' 'scripts/validate-*.sh' 'scripts/tests/**/*.sh')

[[ "$checked" -gt 0 ]] || fail "static scan matched no git init call sites"

if [[ "$FAIL" -ne 0 ]]; then
  echo "test-hook-git-env: FAILED" >&2
  exit 1
fi
echo "test-hook-git-env: ALL PASS"
