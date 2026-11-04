#!/usr/bin/env bash
# prepare-feature-branch.sh — ensure the current checkout is on the feature
# branch before dispatching implementor agents in --no-worktree mode.
#
# Usage:
#   prepare-feature-branch.sh <feature-slug> [--allow-existing-feature-branch]
#                             [--allow-release-branch]
#
# Behavior:
#   - Rejects an unrelated dirty checkout (only plan-artifact paths allowed:
#     docs/plans/<slug>/*, docs/orchestration/<slug>*,
#     docs/prps/{plans,specs,prds}/<slug>*, from the repo root or the cwd,
#     plus a .gitignore whose only change appends one .ycc/artifacts/ rule
#     line).
#   - On feat/<slug>: idempotent no-op.
#   - On trunk (main/master/trunk/develop, plus the RELEASING.md trunk) and
#     feat/<slug> exists: switch to it.
#   - On trunk and feat/<slug> missing: create it. With a RELEASING.md state
#     block, fetch origin/<state-trunk> first and create the branch from it;
#     if the fetch or that checkout fails, warn and create it from HEAD.
#   - On release/* with a RELEASING.md state block: exit 2 (is this a
#     release-only fix?) unless --allow-release-branch, which treats the
#     release branch as the base: switch to an existing feat/<slug>, else
#     create it from HEAD (no fetch).
#   - On another non-trunk branch + --allow-existing-feature-branch: keep it.
#   - On another non-trunk branch without the flag: exit 2 (caller asks user).
#   - Without RELEASING.md, behavior is exactly as before the release model.
#
# Release state is read with the sibling release-state.sh; the model is
# described in _shared/references/branching-model.md.
#
# Mirrors setup-worktree.sh stdout/stderr discipline:
#   - Branch name on stdout (one line).
#   - All git output and status messages on stderr.
#
# Exit codes:
#   0  branch is prepared (name on stdout)
#   1  hard failure (dirty unrelated tree, git error, missing slug, malformed
#      RELEASING.md state block, ...)
#   2  on a different non-trunk branch and --allow-existing-feature-branch not
#      set, or on release/* and --allow-release-branch not set

set -euo pipefail

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat >&2 <<'EOF'
Usage:
  prepare-feature-branch.sh <feature-slug> [--allow-existing-feature-branch]
                            [--allow-release-branch]

Arguments:
  feature-slug                       Kebab-case feature identifier (e.g. "add-widget")
  --allow-existing-feature-branch    Reuse the current non-trunk branch
  --allow-release-branch             On release/* (RELEASING.md present), branch
                                     feat/<slug> from it for a release-only fix
EOF
}

_error() {
  echo "prepare-feature-branch.sh: error: $*" >&2
}

_info() {
  echo "prepare-feature-branch.sh: $*" >&2
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_STATE_SH="${SCRIPT_DIR}/release-state.sh"

FEATURE_SLUG=""
ALLOW_EXISTING_FEATURE_BRANCH=false
ALLOW_RELEASE_BRANCH=false

set_feature_slug() {
  if [[ -z "$FEATURE_SLUG" ]]; then
    FEATURE_SLUG="$1"
  else
    _error "unexpected positional argument: $1"
    usage
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-existing-feature-branch)
      ALLOW_EXISTING_FEATURE_BRANCH=true
      shift
      ;;
    --allow-release-branch)
      ALLOW_RELEASE_BRANCH=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        set_feature_slug "$1"
        shift
      done
      break
      ;;
    -*)
      _error "unknown flag: $1"
      usage
      exit 1
      ;;
    *)
      set_feature_slug "$1"
      shift
      ;;
  esac
done

if [[ -z "$FEATURE_SLUG" ]]; then
  _error "feature-slug is required"
  usage
  exit 1
fi

if [[ ! "$FEATURE_SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  _error "feature-slug must be kebab-case matching [a-z0-9][a-z0-9-]*"
  usage
  exit 1
fi

# ---------------------------------------------------------------------------
# Git context
# ---------------------------------------------------------------------------

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  _error "not inside a git repository"
  exit 1
fi

CURRENT_BRANCH="$(git branch --show-current)"
if [[ -z "$CURRENT_BRANCH" ]]; then
  _error "detached HEAD is not supported; check out a branch first"
  exit 1
fi

FEATURE_BRANCH="feat/${FEATURE_SLUG}"

if [[ "$CURRENT_BRANCH" == "$FEATURE_BRANCH" ]]; then
  _info "already on ${FEATURE_BRANCH}"
  echo "$FEATURE_BRANCH"
  exit 0
fi

# ---------------------------------------------------------------------------
# Dirty-tree guard
# ---------------------------------------------------------------------------
#
# Allow plan-artifact paths; reject anything else.

# Succeed when content $2 equals $1 or $1 plus exactly one trailing cache rule
# line, as `--ensure` writes it, including after a missing final newline. $1
# may already hold the rule: a later `!` line can void it, so the resolver
# appends another.
is_head_plus_rule() {
  local head="$1" content="$2" rest rule='^/?\.ycc/artifacts/?$'
  [[ "$content" == "$head" ]] && return 0
  if [[ -n "$head" && "$head" != *$'\n' ]]; then head="${head}"$'\n'; fi
  [[ "$content" == "$head"* ]] || return 1
  rest=${content#"$head"}
  rest=${rest%$'\n'}
  [[ "$rest" != *$'\n'* && "$rest" =~ $rule ]]
}

REPO_ROOT="$(git rev-parse --show-toplevel)"
# cwd relative to REPO_ROOT ("" at the root, else ending in "/").
REPO_PREFIX="$(git rev-parse --show-prefix)"

# Accept a .gitignore (path relative to REPO_ROOT) whose working-tree and
# stage-0 contents each equal its HEAD content (empty when new) or HEAD plus
# one cache rule line, and at least one differs from HEAD. The working tree
# must be a regular non-symlink file whose mode matches the index (or HEAD,
# else 100644); the index mode must be 100644 or 100755 and equal HEAD's.
# Refuse conflict stages and staged deletions; no index entry for a path new
# to HEAD counts as equal to HEAD. Blobs are read by oid so a path like
# `0:x/.gitignore` is never parsed as a revision.
is_artifact_gitignore() {
  local path="$1" file head='' index work entry mode type oid stage
  local head_mode='' index_mode='' index_oid='' work_mode
  file="$REPO_ROOT/$path"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  # The x sentinel keeps trailing newlines that command substitution strips.
  work=$(cat -- "$file" && printf x) || return 1
  work=${work%x}
  # ls-tree -z: "<mode> <type> <oid>\t<path>".
  while IFS= read -r -d '' entry; do
    [[ "${entry#*$'\t'}" == "$path" ]] || continue
    read -r mode type oid <<<"${entry%%$'\t'*}"
    [[ "$type" == blob ]] || return 1
    head_mode=$mode
    head=$(git -C "$REPO_ROOT" cat-file blob "$oid" && printf x) || return 1
    head=${head%x}
  done < <(git -C "$REPO_ROOT" --literal-pathspecs ls-tree -z HEAD -- "$path" 2>/dev/null)
  # ls-files -s -z: "<mode> <oid> <stage>\t<path>", one entry per stage.
  while IFS= read -r -d '' entry; do
    [[ "${entry#*$'\t'}" == "$path" ]] || continue
    read -r mode oid stage <<<"${entry%%$'\t'*}"
    [[ "$stage" == 0 && -z "$index_oid" ]] || return 1
    index_mode=$mode index_oid=$oid
  done < <(git -C "$REPO_ROOT" --literal-pathspecs ls-files -s -z -- "$path")
  index=$head
  if [[ -n "$index_oid" ]]; then
    [[ "$index_mode" == 100644 || "$index_mode" == 100755 ]] || return 1
    [[ -z "$head_mode" || "$index_mode" == "$head_mode" ]] || return 1
    index=$(git -C "$REPO_ROOT" cat-file blob "$index_oid" && printf x) || return 1
    index=${index%x}
  elif [[ -n "$head_mode" ]]; then
    return 1
  fi
  # diff-files -z --raw: ":<srcmode> <dstmode> <srcoid> <dstoid> <status>\0".
  if IFS= read -r -d '' entry < <(git -C "$REPO_ROOT" --literal-pathspecs diff-files -z --raw -- "$path"); then
    read -r _ work_mode _ <<<"${entry#:}"
    [[ "$work_mode" == "${index_mode:-${head_mode:-100644}}" ]] || return 1
  fi
  [[ "$work" != "$head" || "$index" != "$head" ]] || return 1
  is_head_plus_rule "$head" "$work" && is_head_plus_rule "$head" "$index"
}

# Plan-artifact paths relative to the directory the plan was written from.
is_plan_path() {
  case "$1" in
    docs/plans/"${FEATURE_SLUG}"/*) return 0 ;;
    docs/orchestration/"${FEATURE_SLUG}"*) return 0 ;;
    docs/prps/plans/"${FEATURE_SLUG}"*) return 0 ;;
    docs/prps/specs/"${FEATURE_SLUG}"*) return 0 ;;
    docs/prps/prds/"${FEATURE_SLUG}"*) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 is root-relative. Plan paths match from the root or, for package-local
# (`scope: local`) plans, from the cwd; .gitignore checks stay root-relative.
is_plan_artifact() {
  local path="$1"
  is_plan_path "$path" && return 0
  if [[ -n "$REPO_PREFIX" && "$path" == "$REPO_PREFIX"* ]]; then
    is_plan_path "${path#"$REPO_PREFIX"}" && return 0
  fi
  case "$path" in
    .gitignore|*/.gitignore) is_artifact_gitignore "$path" ;;
    *) return 1 ;;
  esac
}

UNRELATED_DIRTY=()
# NUL-separated root-relative paths; --no-renames reports both sides of a
# rename so a staged deletion cannot hide behind an allowed new path.
collect_dirty() {
  # Untracked files (file-level — avoids `?? dir/` collapsed entries from
  # `git status --porcelain` and `--untracked-files=all`'s memory cost).
  git -C "$REPO_ROOT" ls-files -z --others --exclude-standard
  # Modified-but-unstaged tracked files.
  git -C "$REPO_ROOT" diff -z --name-only --no-renames
  # Staged tracked files (added/modified/deleted).
  git -C "$REPO_ROOT" diff -z --name-only --no-renames --cached
}

while IFS= read -r -d '' path; do
  [[ -z "$path" ]] && continue
  if ! is_plan_artifact "$path"; then
    UNRELATED_DIRTY+=("$path")
  fi
done < <(collect_dirty | sort -zu)

if (( ${#UNRELATED_DIRTY[@]} > 0 )); then
  _error "working tree has unrelated changes; stash or commit them first:"
  printf '  %s\n' "${UNRELATED_DIRTY[@]}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Branch state machine
# ---------------------------------------------------------------------------

branch_exists() {
  git show-ref --verify --quiet "refs/heads/$1"
}

remote_branch_exists() {
  git show-ref --verify --quiet "refs/remotes/origin/$1"
}

# ---------------------------------------------------------------------------
# Release state (RELEASING.md)
# ---------------------------------------------------------------------------
#
# STATE_TRUNK stays empty when the repo has no RELEASING.md, which keeps every
# branch below on its pre-release-model path.

STATE_TRUNK=""

load_release_state() {
  local out rc=0
  if [[ ! -f "$RELEASE_STATE_SH" ]]; then
    _error "missing helper: ${RELEASE_STATE_SH}"
    exit 1
  fi
  out="$(bash "$RELEASE_STATE_SH" get 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    _error "could not read the RELEASING.md state block:"
    printf '  %s\n' "$out" >&2
    exit 1
  fi
  if [[ "$(sed -n 's/^present=//p' <<<"$out")" == "1" ]]; then
    STATE_TRUNK="$(sed -n 's/^trunk=//p' <<<"$out")"
  fi
}

load_release_state

is_trunk_branch() {
  if [[ -n "$STATE_TRUNK" && "$1" == "$STATE_TRUNK" ]]; then
    return 0
  fi
  case "$1" in
    main|master|trunk|develop) return 0 ;;
    *) return 1 ;;
  esac
}

is_release_branch() {
  [[ -n "$STATE_TRUNK" && "$1" == release/* ]]
}

# create_feature_branch — create FEATURE_BRANCH. With release state, start
# from a freshly fetched origin/<state-trunk>; on any failure fall back to
# HEAD (the pre-release-model behavior) with a warning.
create_feature_branch() {
  local start="origin/${STATE_TRUNK}" out
  if [[ -z "$STATE_TRUNK" ]]; then
    _info "creating ${FEATURE_BRANCH} from ${CURRENT_BRANCH}"
    git checkout -b "$FEATURE_BRANCH" >&2
    return 0
  fi
  if ! out="$(git fetch --quiet origin "+refs/heads/${STATE_TRUNK}:refs/remotes/${start}" 2>&1)"; then
    _info "warning: could not fetch ${STATE_TRUNK} from origin; creating ${FEATURE_BRANCH} from ${CURRENT_BRANCH} instead"
    [[ -n "$out" ]] && printf '  %s\n' "$out" >&2
    git checkout -b "$FEATURE_BRANCH" >&2
    return 0
  fi
  if out="$(git checkout --no-track -b "$FEATURE_BRANCH" "$start" 2>&1)"; then
    [[ -n "$out" ]] && printf '%s\n' "$out" >&2
    _info "created ${FEATURE_BRANCH} from ${start} (RELEASING.md trunk)"
    return 0
  fi
  _info "warning: could not create ${FEATURE_BRANCH} from ${start} with the current working tree; creating it from ${CURRENT_BRANCH} instead"
  printf '  %s\n' "$out" >&2
  git checkout -b "$FEATURE_BRANCH" >&2
}

if is_trunk_branch "$CURRENT_BRANCH"; then
  if branch_exists "$FEATURE_BRANCH"; then
    _info "switching from ${CURRENT_BRANCH} to existing ${FEATURE_BRANCH}"
    git checkout "$FEATURE_BRANCH" >&2
    if ! git merge-base --is-ancestor "$CURRENT_BRANCH" "$FEATURE_BRANCH"; then
      _info "warning: ${FEATURE_BRANCH} is not based on current ${CURRENT_BRANCH}; consider rebasing before dispatch"
    fi
  elif remote_branch_exists "$FEATURE_BRANCH"; then
    _info "switching from ${CURRENT_BRANCH} to existing origin/${FEATURE_BRANCH}"
    git checkout --track "origin/${FEATURE_BRANCH}" >&2
  else
    create_feature_branch
  fi
  echo "$FEATURE_BRANCH"
  exit 0
fi

# A maintenance branch under the release model: work normally lands on the
# trunk first and is backported, so ask before branching from here.
if is_release_branch "$CURRENT_BRANCH"; then
  if [[ "$ALLOW_RELEASE_BRANCH" != true ]]; then
    _error "on maintenance branch '${CURRENT_BRANCH}'; fixes normally land on '${STATE_TRUNK}' first and are backported"
    _error "if this is a release-only fix, re-run with --allow-release-branch; otherwise check out '${STATE_TRUNK}' first"
    exit 2
  fi
  if branch_exists "$FEATURE_BRANCH"; then
    _info "switching from ${CURRENT_BRANCH} to existing ${FEATURE_BRANCH} (--allow-release-branch)"
    git checkout "$FEATURE_BRANCH" >&2
  else
    _info "creating ${FEATURE_BRANCH} from ${CURRENT_BRANCH} (--allow-release-branch)"
    git checkout -b "$FEATURE_BRANCH" >&2
  fi
  echo "$FEATURE_BRANCH"
  exit 0
fi

# Some other branch — already a non-trunk branch, not feat/<slug>.
if [[ "$ALLOW_EXISTING_FEATURE_BRANCH" == true ]]; then
  _info "using current branch ${CURRENT_BRANCH} (--allow-existing-feature-branch)"
  echo "$CURRENT_BRANCH"
  exit 0
fi

_error "on branch '${CURRENT_BRANCH}', expected '${FEATURE_BRANCH}' or a trunk branch"
_error "pass --allow-existing-feature-branch to reuse the current branch, or check out a trunk branch first"
exit 2
