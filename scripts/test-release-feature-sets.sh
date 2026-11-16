#!/usr/bin/env bash
#
# Behavioral tests for the release feature-set helper:
#   ycc/skills/_shared/scripts/release-feature-sets.sh
#
# Every test runs in throwaway git repos under a temp dir with an isolated git
# config, so the caller's repositories and global git settings are never used.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELPER="${REPO_ROOT}/ycc/skills/_shared/scripts/release-feature-sets.sh"

PASS=0
FAIL=0

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

# Clear repo-local git variables a pre-push hook may export.
while IFS= read -r git_var; do
  unset "$git_var"
done < <(git rev-parse --local-env-vars)
unset git_var

SANDBOX_ROOT="$(mktemp -d)"
trap 'rm -rf "${SANDBOX_ROOT}"' EXIT

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${SANDBOX_ROOT}/gitconfig"
cat >"${GIT_CONFIG_GLOBAL}" <<'EOF'
[user]
	name = ycc test
	email = ycc-test@example.invalid
[init]
	defaultBranch = main
[commit]
	gpgsign = false
[tag]
	gpgsign = false
EOF

ok() {
  PASS=$((PASS + 1))
  printf '%s[pass]%s %s\n' "${GREEN}" "${NC}" "$1"
}

ko() {
  FAIL=$((FAIL + 1))
  printf '%s[FAIL]%s %s\n' "${RED}" "${NC}" "$1"
  [[ -n "${2:-}" ]] && printf '       %s\n' "$2"
}

assert_eq() {
  local actual="$1" expected="$2" name="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$name"
  else
    ko "$name" "expected: $(printf '%q' "$expected") got: $(printf '%q' "$actual")"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$name"
  else
    ko "$name" "missing: $(printf '%q' "$needle") in: $(printf '%q' "$haystack")"
  fi
}

# new_repo <name> — repo with one tagged commit; prints its path.
new_repo() {
  local dir="${SANDBOX_ROOT}/$1"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m "chore: initial"
  git -C "$dir" tag v1.0.0
  printf '%s\n' "$dir"
}

commit() {
  git -C "$1" commit -q --allow-empty -m "$2" "${@:3}"
}

# json_field <json> <python-expression over d>
json_field() {
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"
}

run() {
  OUT="$("$HELPER" "$@" 2>"${SANDBOX_ROOT}/err")"
  RC=$?
  ERR="$(cat "${SANDBOX_ROOT}/err")"
}

test_feat_alone_is_patch() {
  local repo
  repo="$(new_repo feat-alone)"
  commit "$repo" "feat(worktree): add prune"
  commit "$repo" "feat(worktree): add list --json"
  commit "$repo" "fix(release): typo"
  run --repo "$repo"
  assert_eq "$RC" 0 "feat alone: exit 0"
  assert_eq "$(json_field "$OUT" 'd["required_bump"]')" "patch" "feat alone: in-progress set needs only a patch"
  assert_eq "$(json_field "$OUT" 'd["from"]')" "v1.0.0" "feat alone: range starts at latest tag"
  assert_eq "$(json_field "$OUT" '[s["name"] for s in d["feature_sets"]]')" "['worktree']" "feat alone: commits grouped by scope"
  assert_eq "$(json_field "$OUT" 'len(d["feature_sets"][0]["commits"])')" "2" "feat alone: both feats in one set"
  assert_eq "$(json_field "$OUT" 'd["counts"]')" "{'feat': 2, 'fix': 1, 'other': 0}" "feat alone: counts"
}

test_complete_set_is_minor() {
  local repo
  repo="$(new_repo complete)"
  commit "$repo" "feat(worktree): add prune"
  commit "$repo" "feat(release): helper"
  run --repo "$repo" --complete worktree
  assert_eq "$(json_field "$OUT" 'd["required_bump"]')" "minor" "complete: a finished set requires a minor"
  assert_eq "$(json_field "$OUT" '[(s["name"], s["complete"]) for s in d["feature_sets"]]')" \
    "[('release', False), ('worktree', True)]" "complete: only the named set is complete"
  run --repo "$repo" --complete all
  assert_eq "$(json_field "$OUT" 'd["complete"]')" "['release', 'worktree']" "complete: 'all' selects every set"
}

test_trailer_and_unscoped() {
  local repo
  repo="$(new_repo trailer)"
  commit "$repo" "feat(cli): add flag" -m "Feature-Set: sync-v2"
  commit "$repo" "feat(installer): wire flag" -m "feature-set: sync-v2"
  commit "$repo" "feat: something"
  run --repo "$repo"
  assert_eq "$(json_field "$OUT" '[(s["name"], len(s["commits"])) for s in d["feature_sets"]]')" \
    "[('sync-v2', 2), ('unscoped', 1)]" "trailer: Feature-Set trailer overrides scope; no scope is unscoped"
}

test_breaking_is_major() {
  local repo
  repo="$(new_repo breaking)"
  commit "$repo" "fix(api)!: drop old flag"
  run --repo "$repo"
  assert_eq "$(json_field "$OUT" 'd["required_bump"]')" "major" "breaking: bang marker is major"
  repo="$(new_repo breaking-footer)"
  commit "$repo" "refactor: move config" -m "BREAKING CHANGE: config path moved"
  run --repo "$repo" --complete ""
  assert_eq "$(json_field "$OUT" 'd["required_bump"]')" "major" "breaking: footer is major"
}

test_empty_and_errors() {
  local repo
  repo="$(new_repo empty)"
  run --repo "$repo"
  assert_eq "$(json_field "$OUT" 'd["required_bump"]')" "none" "empty: no commits needs no release"
  commit "$repo" "feat(a): x"
  run --repo "$repo" --complete nope
  assert_eq "$RC" 1 "errors: unknown set exits 1"
  assert_contains "$ERR" "unknown feature set(s): nope; sets in range: a" "errors: unknown set names the known sets"
  run --repo "${SANDBOX_ROOT}"
  assert_eq "$RC" 1 "errors: non-repo exits 1"
  run --repo "$repo" --from no-such-ref
  assert_eq "$RC" 1 "errors: bad ref exits 1"
}

test_no_tag_and_merges() {
  local repo="${SANDBOX_ROOT}/no-tag"
  git init -q "$repo"
  commit "$repo" "feat(a): first"
  git -C "$repo" checkout -q -b topic
  commit "$repo" "feat(a): second"
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --no-ff topic -m "Merge branch 'topic'"
  run --repo "$repo" --format text
  assert_contains "$OUT" "Range: (root)..HEAD" "no tag: range covers all history"
  assert_contains "$OUT" "a (2 feat, in progress)" "no tag: merge commits are skipped"
  assert_contains "$OUT" "Required bump: patch" "no tag: text format reports the bump"
}

test_breaking_merge_is_major() {
  local repo
  repo="$(new_repo breaking-merge)"
  git -C "$repo" checkout -q -b topic
  commit "$repo" "fix(api): adjust handler"
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --no-ff topic -m "Merge branch 'topic'" -m "BREAKING CHANGE: handler signature changed"
  run --repo "$repo"
  assert_eq "$(json_field "$OUT" 'd["required_bump"]')" "major" "merge: BREAKING CHANGE footer on a merge commit is major"
  assert_eq "$(json_field "$OUT" 'd["counts"]')" "{'feat': 0, 'fix': 1, 'other': 0}" "merge: merge commits stay out of counts"

  repo="$(new_repo breaking-merge-bang)"
  git -C "$repo" checkout -q -b topic
  commit "$repo" "refactor(api): reshape response"
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --no-ff topic -m "refactor(api)!: change response contract"
  run --repo "$repo"
  assert_eq "$(json_field "$OUT" 'd["required_bump"]')" "major" "merge: bang marker in a merge subject is major"
  assert_eq "$(json_field "$OUT" 'd["feature_sets"]')" "[]" "merge: a merge subject never forms a feature set"
}

test_set_completed_after_earlier_release() {
  local repo
  repo="$(new_repo carried)"
  commit "$repo" "feat(sync): add flag"
  git -C "$repo" tag v1.0.1
  commit "$repo" "fix(sync): last blocker"
  run --repo "$repo"
  assert_eq "$(json_field "$OUT" 'd["feature_sets"]')" "[]" "carried: no feat in range means no sets listed"
  run --repo "$repo" --complete sync
  assert_eq "$RC" 0 "carried: a set shipped before the range can be completed"
  assert_eq "$(json_field "$OUT" 'd["required_bump"]')" "minor" "carried: completing it requires a minor"
  assert_eq "$(json_field "$OUT" '[(s["name"], s["earlier"]) for s in d["feature_sets"]]')" "[('sync', True)]" \
    "carried: the set is reported as shipped earlier"
  commit "$repo" "fix(cli): finish" -m "Feature-Set: sync"
  run --repo "$repo" --format text
  assert_contains "$OUT" "sync (0 feat + 1 other, in progress)" "carried: a Feature-Set footer on a fix joins the set"
}

test_feat_alone_is_patch
test_complete_set_is_minor
test_breaking_merge_is_major
test_set_completed_after_earlier_release
test_trailer_and_unscoped
test_breaking_is_major
test_empty_and_errors
test_no_tag_and_merges

echo
echo "release-feature-sets tests: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
