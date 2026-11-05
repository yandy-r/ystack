#!/usr/bin/env bash
# worktree-create.sh — WorktreeCreate hook for Claude Code
#
# CONTRACT (verified against https://code.claude.com/docs/en/hooks):
#   stdin  : JSON object with at minimum:
#              { "name":          "feature-auth",
#                "cwd":           "/repo",
#                "session_id":    "...",
#                "hook_event_name": "WorktreeCreate" }
#   stdout : A single line containing the replacement worktree path (plain text, NOT JSON).
#   exit 0 : Worktree creation succeeds using the path on stdout.
#   exit ≠0: Worktree creation FAILS (unlike other hooks where only exit 2 blocks).
#
# PURPOSE:
#   A WorktreeCreate hook replaces Claude Code's default git behavior. This hook
#   creates the git worktree itself, keeps it under the Claude-managed repo-local
#   root (<repo-root>/.claude/worktrees/), and returns the created path.
#
# INSTALL:
#   Shipped by the native ycc-hooks Claude package, which registers it via
#   ${CLAUDE_PLUGIN_ROOT}/hooks/worktree-create.sh. Install it with:
#     ./install.sh sync --target claude --intent hooks [--global]
#   (project scope by default; --global installs ycc-hooks@ycc at user scope).

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Read the full stdin payload once.
INPUT="$(cat)"

# Try to extract a field value from the JSON input.
# Uses jq when available; falls back to a simple grep-based extraction.
json_get() {
  local field="$1"
  if command -v jq &>/dev/null; then
    printf '%s' "$INPUT" | jq -r --arg f "$field" '.[$f] // empty'
  else
    # Fallback: extract "field": "value" (handles most well-formed JSON).
    # A missing field makes grep exit 1; under pipefail that would abort, so
    # swallow it and return an empty value.
    printf '%s' "$INPUT" \
      | { grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" || true; } \
      | head -1 \
      | sed 's/.*: *"\(.*\)"/\1/'
  fi
}

# ---------------------------------------------------------------------------
# Parse input
# ---------------------------------------------------------------------------

CWD="$(json_get cwd)"
BASE_REF="$(json_get base_ref)"
WORKTREE_NAME="$(json_get name)"

if [[ -z "$WORKTREE_NAME" ]]; then
  WORKTREE_NAME="$(json_get worktree_name)"
fi

if [[ -z "$WORKTREE_NAME" ]]; then
  INTENDED_PATH="$(json_get worktree_path)"
  if [[ -n "$INTENDED_PATH" ]]; then
    WORKTREE_NAME="$(basename "$INTENDED_PATH")"
  fi
fi

if [[ -z "$WORKTREE_NAME" ]]; then
  WORKTREE_NAME="$(json_get session_id)"
fi

# ---------------------------------------------------------------------------
# Compute target path
# ---------------------------------------------------------------------------

REPO_ROOT="${CWD:-$PWD}"
if command -v git &>/dev/null; then
  REPO_ROOT="$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$REPO_ROOT")"
fi
REPO_NAME="$(basename "$REPO_ROOT")"

sanitize_slug() {
  local raw="$1"
  local slug
  slug="$(printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  printf '%s\n' "${slug:-worktree}"
}

SLUG="$(sanitize_slug "$WORKTREE_NAME")"
BRANCH="$SLUG"

if ! git -C "$REPO_ROOT" check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  BRANCH="worktree/${SLUG}"
fi

WORKTREE_ROOT="${YCC_WORKTREE_ROOT:-$REPO_ROOT/.claude/worktrees}"
case "$WORKTREE_ROOT" in
  "~")
    WORKTREE_ROOT="$HOME"
    ;;
  "~"/*)
    WORKTREE_ROOT="$HOME/${WORKTREE_ROOT#"~/"}"
    ;;
  /*)
    ;;
  *)
    WORKTREE_ROOT="$REPO_ROOT/$WORKTREE_ROOT"
    ;;
esac

WORKTREE_PATH="$WORKTREE_ROOT/${REPO_NAME}-${SLUG}"

# ---------------------------------------------------------------------------
# Create and emit worktree path
# ---------------------------------------------------------------------------

mkdir -p "$WORKTREE_ROOT"

if [[ -d "$WORKTREE_PATH" ]]; then
  # Reuse only a path that git itself lists as a worktree of this repository;
  # an ordinary directory nested inside the repo would otherwise pass via
  # parent .git discovery.
  existing_canon="$(cd "$WORKTREE_PATH" && pwd -P)"
  while IFS= read -r wt_line; do
    if [[ "$wt_line" == "worktree ${existing_canon}" ]]; then
      printf '%s\n' "$WORKTREE_PATH"
      exit 0
    fi
  done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null || true)

  echo "worktree-create.sh: error: target exists but is not a git worktree: $WORKTREE_PATH" >&2
  exit 1
fi

START_POINT="${BASE_REF:-HEAD}"

if git -C "$REPO_ROOT" rev-parse --verify "refs/heads/$BRANCH" >/dev/null 2>&1; then
  git -C "$REPO_ROOT" worktree add "$WORKTREE_PATH" "$BRANCH" >&2
else
  git -C "$REPO_ROOT" worktree add -b "$BRANCH" "$WORKTREE_PATH" "$START_POINT" >&2
fi

printf '%s\n' "$WORKTREE_PATH"
exit 0
