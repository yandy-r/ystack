#!/usr/bin/env bash
#
# Behavioral tests for the release-model branch and PR helpers:
#   ycc/skills/_shared/scripts/prepare-feature-branch.sh
#   ycc/skills/_shared/scripts/pr-guard.sh
#   ycc/skills/git-workflow/scripts/create-pr.sh (with a stubbed gh)
#
# Every test runs in throwaway git repos under a temp dir with an isolated git
# config, so the caller's repositories and global git settings are never used.
# The harness below is copied from scripts/test-release-model.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHARED="${REPO_ROOT}/ycc/skills/_shared/scripts"
PREP="${SHARED}/prepare-feature-branch.sh"
GUARD="${SHARED}/pr-guard.sh"
CREATE_PR="${REPO_ROOT}/ycc/skills/git-workflow/scripts/create-pr.sh"

PASS=0
FAIL=0

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

# Git hooks (pre-push runs validate.sh) export GIT_DIR, GIT_WORK_TREE,
# GIT_INDEX_FILE and friends. Left set, they would point every sandbox git
# call at the caller's repository, so clear all repo-local git variables.
while IFS= read -r git_var; do
  unset "$git_var"
done < <(git rev-parse --local-env-vars)
unset git_var
unset ARTIFACT_LINEAR_TEAM

SANDBOX_ROOT="$(mktemp -d)"
trap 'rm -rf "${SANDBOX_ROOT}"' EXIT

# Isolated git identity/config for every git call in this script.
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
    ko "$name" "missing: $needle"
  fi
}

assert_exit() {
  local actual="$1" expected="$2" name="$3"
  assert_eq "$actual" "$expected" "$name (exit $expected)"
}

# mkrepo — create a repo with one commit on main and a bare origin; echo path.
mkrepo() {
  local dir origin
  dir="$(mktemp -d "${SANDBOX_ROOT}/repo.XXXXXX")"
  origin="${dir}.origin.git"
  git init -q --bare "$origin"
  git -C "$dir" init -q
  # Refuse to continue if git resolved anything but the sandbox repo.
  if [[ "$(cd "$dir" && git rev-parse --absolute-git-dir)" != "${dir}/.git" ]]; then
    echo "test-release-branch-prep: git did not resolve the sandbox repo; aborting" >&2
    exit 1
  fi
  echo "seed" >"${dir}/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "chore: seed"
  git -C "$dir" remote add origin "$origin"
  git -C "$dir" push -q origin main 2>/dev/null
  git -C "$dir" remote set-head origin main >/dev/null 2>&1
  echo "$dir"
}

# write_releasing <dir> <block-body> [table-and-prose] — write RELEASING.md.
write_releasing() {
  local dir="$1" body="$2" rest="${3:-}"
  {
    echo "# Releasing"
    echo
    echo "<!-- ycc-release-state"
    printf '%s\n' "$body"
    echo "-->"
    [[ -n "$rest" ]] && printf '\n%s\n' "$rest"
  } >"${dir}/RELEASING.md"
}

# get_key <output> <key> — value of key=value in output.
get_key() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# commit_file <repo> <file> <content> <message> — write, add and commit.
commit_file() {
  local repo="$1" file="$2" content="$3" msg="$4"
  mkdir -p "$(dirname "${repo}/${file}")"
  printf '%s\n' "$content" >"${repo}/${file}"
  git -C "$repo" add "$file"
  git -C "$repo" commit -q -m "$msg"
}

# sha <repo> <ref> — full commit id of ref.
sha() {
  git -C "$1" rev-parse "$2"
}

# current_branch <repo>
current_branch() {
  git -C "$1" branch --show-current
}

# run_prep <repo> [args...] — run prepare-feature-branch.sh inside repo;
# stdout to PREP_OUT, stderr to PREP_ERR, exit code to PREP_RC.
run_prep() {
  local repo="$1" errf
  shift
  errf="$(mktemp "${SANDBOX_ROOT}/err.XXXXXX")"
  PREP_RC=0
  PREP_OUT="$(cd "$repo" && bash "$PREP" "$@" 2>"$errf")" || PREP_RC=$?
  PREP_ERR="$(cat "$errf")"
}

# run_guard <repo> [args...] — run pr-guard.sh inside repo; combined output
# to GUARD_OUT, exit code to GUARD_RC.
run_guard() {
  local repo="$1"
  shift
  GUARD_RC=0
  GUARD_OUT="$(cd "$repo" && bash "$GUARD" "$@" 2>&1)" || GUARD_RC=$?
}

# release_repo <block-body> — mkrepo with RELEASING.md committed and pushed.
release_repo() {
  local repo
  repo="$(mkrepo)"
  write_releasing "$repo" "$1"
  git -C "$repo" add RELEASING.md
  git -C "$repo" commit -q -m "docs: add RELEASING.md"
  git -C "$repo" push -q origin main
  echo "$repo"
}

# make_local_trunk_behind <repo> <trunk> — push one commit to origin/<trunk>,
# then rewind both the local branch and origin/<trunk> so only a fetch sees it.
make_local_trunk_behind() {
  local repo="$1" trunk="$2" old
  old="$(sha "$repo" HEAD)"
  commit_file "$repo" "ahead-${trunk}.txt" "ahead" "feat: upstream work on ${trunk}"
  git -C "$repo" push -q origin "$trunk"
  git -C "$repo" reset -q --hard "$old"
  git -C "$repo" update-ref "refs/remotes/origin/${trunk}" "$old"
}

REL_BLOCK="model: release-branches
trunk: main
maintenance: release/0.5"

# ---------------------------------------------------------------------------
# prepare-feature-branch.sh
# ---------------------------------------------------------------------------

test_prep_no_state_unchanged() {
  local repo head
  repo="$(mkrepo)"
  make_local_trunk_behind "$repo" main
  head="$(sha "$repo" HEAD)"
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 0 "prep: no RELEASING.md creates the branch"
  assert_eq "$PREP_OUT" "feat/demo" "prep: no RELEASING.md prints the branch"
  assert_eq "$(sha "$repo" feat/demo)" "$head" "prep: no RELEASING.md branches from HEAD, not origin"
  assert_eq "$PREP_ERR" "prepare-feature-branch.sh: creating feat/demo from main
Switched to a new branch 'feat/demo'" "prep: no RELEASING.md stderr unchanged"

  repo="$(mkrepo)"
  git -C "$repo" checkout -q -b release/0.5
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 2 "prep: no RELEASING.md treats release/* as a feature branch"
  assert_contains "$PREP_ERR" "--allow-existing-feature-branch" "prep: no RELEASING.md keeps the old exit-2 message"

  repo="$(mkrepo)"
  git -C "$repo" checkout -q -b develop2
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 2 "prep: no RELEASING.md does not treat develop2 as a trunk"
}

test_prep_artifact_gitignore() {
  local repo rule staged
  for rule in '.ycc/artifacts/' '/.ycc/artifacts/' '.ycc/artifacts' '/.ycc/artifacts'; do
    for staged in no yes; do
      repo="$(mkrepo)"
      commit_file "$repo" .gitignore 'existing/' 'chore: ignore existing files'
      printf '%s\n' "$rule" >>"${repo}/.gitignore"
      if [[ "$staged" == yes ]]; then git -C "$repo" add .gitignore; fi
      run_prep "$repo" demo
      assert_exit "$PREP_RC" 0 "prep: accepts $staged staged cache-only rule $rule"
      assert_eq "$(current_branch "$repo")" 'feat/demo' 'prep: carries cache ignore onto feature branch'
      assert_eq "$PREP_OUT" 'feat/demo' 'prep: prints feature branch with cache ignore'
    done
    repo="$(mkrepo)"
    printf '%s\n' "$rule" >"${repo}/.gitignore"
    run_prep "$repo" demo
    assert_exit "$PREP_RC" 0 "prep: accepts untracked cache-only rule $rule"
  done

  repo="$(mkrepo)"
  printf 'existing/' >"${repo}/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -q -m 'chore: ignore existing files without final newline'
  (cd "$repo" && bash "${SHARED}/resolve-artifact-store.sh" --store=linear --ensure --kind=parallel-plan --slug=demo) >/dev/null
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 0 'prep: accepts ensured cache rule after missing final newline'
  assert_eq "$(current_branch "$repo")" 'feat/demo' 'prep: switches branch after missing final newline'
  assert_eq "$PREP_OUT" 'feat/demo' 'prep: prints branch after missing final newline'

  repo="$(mkrepo)"
  mkdir -p "${repo}/packages/x"
  printf '%s\n' '.ycc/artifacts/' >"${repo}/packages/x/.gitignore"
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 0 'prep: accepts package-dir cache-only gitignore'
  assert_eq "$(current_branch "$repo")" 'feat/demo' 'prep: switches branch with package-dir cache ignore'
  assert_eq "$PREP_OUT" 'feat/demo' 'prep: prints branch with package-dir cache ignore'

  repo="$(mkrepo)"
  mkdir -p "${repo}/packages/x"
  printf '%s\n' '.ycc/artifacts/' 'unrelated/' >"${repo}/packages/x/.gitignore"
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 1 'prep: rejects package-dir cache rule plus unrelated addition'
  assert_contains "$PREP_ERR" 'packages/x/.gitignore' 'prep: identifies unrelated package-dir gitignore'

  repo="$(mkrepo)"
  commit_file "$repo" .gitignore 'existing/' 'chore: ignore existing files'
  printf '%s\n' '.ycc/artifacts/' 'unrelated/' >>"${repo}/.gitignore"
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 1 'prep: rejects cache rule plus unrelated addition'
  assert_contains "$PREP_ERR" '.gitignore' 'prep: identifies unrelated gitignore'

  repo="$(mkrepo)"
  commit_file "$repo" .gitignore 'existing/' 'chore: ignore existing files'
  printf '%s\n' '.ycc/artifacts/' >"${repo}/.gitignore"
  git -C "$repo" add .gitignore
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 1 'prep: rejects staged deletion plus cache addition'

  repo="$(mkrepo)"
  printf '%s\n' '.ycc/artifacts/' 'unrelated/' >"${repo}/.gitignore"
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 1 'prep: rejects unrelated untracked gitignore rule'
}

test_prep_state_trunk_nonstandard() {
  local repo
  repo="$(mkrepo)"
  git -C "$repo" checkout -q -b develop2
  write_releasing "$repo" "model: trunk-only
trunk: develop2"
  git -C "$repo" add RELEASING.md
  git -C "$repo" commit -q -m "docs: add RELEASING.md"
  git -C "$repo" push -q origin develop2
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 0 "prep: state trunk develop2 is a trunk"
  assert_eq "$(current_branch "$repo")" "feat/demo" "prep: switched to feat/demo from develop2"
  assert_eq "$(sha "$repo" feat/demo)" "$(sha "$repo" origin/develop2)" "prep: feat/demo starts at origin/develop2"
}

test_prep_branches_from_origin_trunk() {
  local repo upstream
  repo="$(release_repo "$REL_BLOCK")"
  make_local_trunk_behind "$repo" main
  upstream="$(git -C "${repo}.origin.git" rev-parse main)"
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 0 "prep: state present creates the branch"
  assert_eq "$PREP_OUT" "feat/demo" "prep: state present prints the branch"
  assert_eq "$(sha "$repo" feat/demo)" "$upstream" "prep: branch starts at freshly fetched origin/main"
  assert_eq "$(git -C "$repo" config --get branch.feat/demo.merge || true)" "" "prep: branch has no upstream to origin/main"
  assert_contains "$PREP_ERR" "from origin/main" "prep: reports origin/<trunk> as the start point"
}

test_prep_from_other_trunk_uses_state_trunk() {
  local repo
  repo="$(mkrepo)"
  git -C "$repo" checkout -q -b develop2
  commit_file "$repo" dev.txt "dev" "feat: develop2 work"
  git -C "$repo" push -q origin develop2
  git -C "$repo" checkout -q main
  write_releasing "$repo" "model: trunk-only
trunk: develop2"
  git -C "$repo" add RELEASING.md
  git -C "$repo" commit -q -m "docs: add RELEASING.md"
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 0 "prep: on main with state trunk develop2"
  assert_eq "$(sha "$repo" feat/demo)" "$(sha "$repo" origin/develop2)" "prep: on main, branch starts at origin/<state trunk>"
}

test_prep_plan_files_carried() {
  local repo
  repo="$(release_repo "$REL_BLOCK")"
  make_local_trunk_behind "$repo" main
  mkdir -p "${repo}/docs/plans/demo"
  echo "plan" >"${repo}/docs/plans/demo/plan.md"
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 0 "prep: plan-only dirty tree is allowed"
  assert_eq "$(sha "$repo" feat/demo)" "$(sha "$repo" origin/main)" "prep: plan-only dirty tree still branches from origin/main"
  assert_eq "$(cat "${repo}/docs/plans/demo/plan.md")" "plan" "prep: untracked plan file carried over"
}

test_prep_plan_conflict_falls_back() {
  local repo head
  repo="$(release_repo "$REL_BLOCK")"
  head="$(sha "$repo" HEAD)"
  commit_file "$repo" docs/plans/demo/plan.md "upstream plan" "docs: upstream plan"
  git -C "$repo" push -q origin main
  git -C "$repo" reset -q --hard "$head"
  mkdir -p "${repo}/docs/plans/demo"
  echo "local plan" >"${repo}/docs/plans/demo/plan.md"
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 0 "prep: conflicting plan file falls back"
  assert_eq "$(sha "$repo" feat/demo)" "$head" "prep: conflicting plan file branches from HEAD"
  assert_eq "$(current_branch "$repo")" "feat/demo" "prep: conflicting plan file ends on feat/demo"
  assert_contains "$PREP_ERR" "warning: could not create feat/demo from origin/main" "prep: conflicting plan file warns"
  assert_eq "$(cat "${repo}/docs/plans/demo/plan.md")" "local plan" "prep: local plan file kept"
}

test_prep_release_branch() {
  local repo release_sha
  repo="$(release_repo "$REL_BLOCK")"
  git -C "$repo" checkout -q -b release/0.5
  commit_file "$repo" patch.txt "patch" "fix: release-only"
  git -C "$repo" push -q origin release/0.5
  release_sha="$(sha "$repo" HEAD)"

  run_prep "$repo" demo
  assert_exit "$PREP_RC" 2 "prep: on release/0.5 without the flag"
  assert_contains "$PREP_ERR" "release-only fix" "prep: release/0.5 asks about a release-only fix"
  assert_contains "$PREP_ERR" "--allow-release-branch" "prep: release/0.5 names the flag"
  assert_eq "$(current_branch "$repo")" "release/0.5" "prep: release/0.5 refusal leaves the branch alone"

  run_prep "$repo" demo --allow-existing-feature-branch
  assert_exit "$PREP_RC" 2 "prep: --allow-existing-feature-branch does not bypass the release check"

  run_prep "$repo" demo --allow-release-branch
  assert_exit "$PREP_RC" 0 "prep: --allow-release-branch proceeds"
  assert_eq "$PREP_OUT" "feat/demo" "prep: --allow-release-branch prints the branch"
  assert_eq "$(sha "$repo" feat/demo)" "$release_sha" "prep: --allow-release-branch branches from the release branch"

  git -C "$repo" checkout -q release/0.5
  run_prep "$repo" demo --allow-release-branch
  assert_exit "$PREP_RC" 0 "prep: --allow-release-branch reuses an existing feat/demo"
  assert_eq "$(current_branch "$repo")" "feat/demo" "prep: --allow-release-branch switched to feat/demo"
}

test_prep_fetch_failure() {
  local repo head
  repo="$(release_repo "$REL_BLOCK")"
  head="$(sha "$repo" HEAD)"
  git -C "$repo" remote remove origin
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 0 "prep: fetch failure still creates the branch"
  assert_eq "$(sha "$repo" feat/demo)" "$head" "prep: fetch failure branches from HEAD"
  assert_contains "$PREP_ERR" "warning: could not fetch main from origin" "prep: fetch failure warns"
}

test_prep_malformed_state() {
  local repo
  repo="$(mkrepo)"
  write_releasing "$repo" "model: trunk-only
trunk: main
flavour: vanilla"
  git -C "$repo" add RELEASING.md
  git -C "$repo" commit -q -m "docs: add RELEASING.md"
  run_prep "$repo" demo
  assert_exit "$PREP_RC" 1 "prep: malformed RELEASING.md"
  assert_contains "$PREP_ERR" "unknown key 'flavour'" "prep: malformed RELEASING.md shows the parse error"
  assert_eq "$(current_branch "$repo")" "main" "prep: malformed RELEASING.md leaves the branch alone"
}

# ---------------------------------------------------------------------------
# pr-guard.sh base
# ---------------------------------------------------------------------------

test_guard_base() {
  local repo
  repo="$(mkrepo)"
  git -C "$repo" checkout -q -b feat/x
  run_guard "$repo" base
  assert_eq "$GUARD_OUT" "main" "guard base: no RELEASING.md -> origin default branch"
  run_guard "$repo" base --base develop
  assert_eq "$GUARD_OUT" "develop" "guard base: --base overrides"

  repo="$(release_repo "$REL_BLOCK")"
  git -C "$repo" checkout -q -b release/0.5
  commit_file "$repo" patch.txt "patch" "fix: release-only"
  git -C "$repo" push -q origin release/0.5
  git -C "$repo" checkout -q -b fix/y
  run_guard "$repo" base
  assert_eq "$GUARD_OUT" "release/0.5" "guard base: branch cut from release/0.5 -> release/0.5"
  git -C "$repo" checkout -q -b feat/z origin/main
  run_guard "$repo" base
  assert_eq "$GUARD_OUT" "main" "guard base: branch cut from the trunk -> trunk"

  repo="$(mkrepo)"
  write_releasing "$repo" "model: nope
trunk: main"
  run_guard "$repo" base
  assert_exit "$GUARD_RC" 2 "guard base: malformed RELEASING.md"
  assert_contains "$GUARD_OUT" "invalid model 'nope'" "guard base: malformed message"
  run_guard "$repo" base --base main
  assert_exit "$GUARD_RC" 2 "guard base: --base does not bypass a malformed RELEASING.md"
}

# ---------------------------------------------------------------------------
# pr-guard.sh sync-check
# ---------------------------------------------------------------------------

# sync_repo — release-branches repo with origin/main ahead of origin/release/0.5.
sync_repo() {
  local repo
  repo="$(release_repo "$REL_BLOCK")"
  git -C "$repo" checkout -q -b release/0.5
  commit_file "$repo" patch.txt "patch" "fix: release-only"
  git -C "$repo" push -q origin release/0.5
  git -C "$repo" checkout -q main
  commit_file "$repo" trunk.txt "trunk" "feat: trunk work"
  git -C "$repo" push -q origin main
  echo "$repo"
}

test_guard_sync_check() {
  local repo
  repo="$(mkrepo)"
  git -C "$repo" checkout -q -b release/0.5
  run_guard "$repo" sync-check --base main
  assert_exit "$GUARD_RC" 0 "sync-check: skipped without RELEASING.md"
  assert_contains "$GUARD_OUT" "result=skipped" "sync-check: reports skipped"

  repo="$(sync_repo)"

  git -C "$repo" checkout -q release/0.5
  run_guard "$repo" sync-check --base main
  assert_exit "$GUARD_RC" 3 "sync-check: release/0.5 -> main refused"
  assert_contains "$GUARD_OUT" "branching-model.md#rules" "sync-check: refusal cites the rule"

  git -C "$repo" checkout -q main
  run_guard "$repo" sync-check --base release/0.5
  assert_exit "$GUARD_RC" 3 "sync-check: main -> release/0.5 refused"

  git -C "$repo" checkout -q -b feat/clean origin/main
  commit_file "$repo" a.txt "a" "feat: clean work"
  run_guard "$repo" sync-check
  assert_exit "$GUARD_RC" 0 "sync-check: clean topic branch passes"
  assert_contains "$GUARD_OUT" "result=ok" "sync-check: clean topic branch ok"

  git -C "$repo" checkout -q -b fix/sneaky origin/release/0.5
  commit_file "$repo" b.txt "b" "fix: something"
  git -C "$repo" merge -q --no-edit --no-ff origin/main >/dev/null
  run_guard "$repo" sync-check --base release/0.5
  assert_exit "$GUARD_RC" 3 "sync-check: merging origin/main into a release PR refused"
  assert_contains "$GUARD_OUT" "brings origin/main" "sync-check: names the merged branch"

  git -C "$repo" checkout -q -b feat/sneaky origin/main
  commit_file "$repo" c.txt "c" "feat: something"
  git -C "$repo" merge -q --no-edit --no-ff origin/release/0.5 >/dev/null
  run_guard "$repo" sync-check --base main
  assert_exit "$GUARD_RC" 3 "sync-check: merging origin/release/0.5 into a trunk PR refused"

  git -C "$repo" checkout -q -b feat/update "$(sha "$repo" origin/main)~1"
  commit_file "$repo" d.txt "d" "feat: behind"
  git -C "$repo" merge -q --no-edit --no-ff origin/main >/dev/null
  run_guard "$repo" sync-check --base main
  assert_exit "$GUARD_RC" 0 "sync-check: merging the base itself passes"

  git -C "$repo" checkout -q -b feat/a origin/main
  commit_file "$repo" e.txt "e" "feat: a"
  git -C "$repo" checkout -q -b feat/b origin/main
  commit_file "$repo" f.txt "f" "feat: b"
  git -C "$repo" merge -q --no-edit --no-ff feat/a >/dev/null
  run_guard "$repo" sync-check --base main
  assert_exit "$GUARD_RC" 0 "sync-check: merging another topic branch passes"

  git -C "$repo" checkout -q -b backport/0.5/clean origin/release/0.5
  git -C "$repo" cherry-pick -x "$(sha "$repo" feat/clean)" >/dev/null
  run_guard "$repo" sync-check --base release/0.5
  assert_exit "$GUARD_RC" 0 "sync-check: cherry-pick backport passes"

  run_guard "$repo" sync-check --base release/9.9
  assert_exit "$GUARD_RC" 1 "sync-check: unfetched base is an error"
}

# ---------------------------------------------------------------------------
# pr-guard.sh backport-label
# ---------------------------------------------------------------------------

test_guard_backport_label() {
  local repo
  repo="$(mkrepo)"
  run_guard "$repo" backport-label --title "fix: x"
  assert_contains "$GUARD_OUT" "backport=0" "backport: no RELEASING.md -> no prompt"

  repo="$(release_repo "model: trunk-only
trunk: main")"
  run_guard "$repo" backport-label --base main --title "fix: x"
  assert_contains "$GUARD_OUT" "reason=model is trunk-only" "backport: trunk-only -> no prompt"

  repo="$(release_repo "model: release-branches
trunk: main")"
  run_guard "$repo" backport-label --base main --title "fix: x"
  assert_contains "$GUARD_OUT" "reason=no maintenance branches" "backport: no maintenance -> no prompt"

  repo="$(release_repo "model: release-branches
trunk: main
maintenance: release/0.6, release/0.5
backport_label: port-to/{X.Y}")"
  git -C "$repo" checkout -q -b feat/x
  commit_file "$repo" x.txt "x" "feat: new thing"
  run_guard "$repo" backport-label --base main --title "fix(api): handle nulls"
  assert_eq "$GUARD_OUT" "backport=1
branch=release/0.6
label=port-to/0.6" "backport: fix(scope) title -> latest maintenance label"
  run_guard "$repo" backport-label --base main --title "feat: new thing"
  assert_eq "$GUARD_OUT" "backport=0
reason=not a fix" "backport: feat title -> no prompt"
  run_guard "$repo" backport-label --base main --title "chore: x" --labels "area:api, type:bug"
  assert_contains "$GUARD_OUT" "backport=1" "backport: type:bug label -> prompt"
  run_guard "$repo" backport-label --base release/0.6 --title "fix: x"
  assert_contains "$GUARD_OUT" "reason=PR targets 'release/0.6'" "backport: PR into a release branch -> no prompt"

  git -C "$repo" push -q origin main
  commit_file "$repo" y.txt "y" "fix: repair a thing"
  run_guard "$repo" backport-label --title "chore: tidy"
  assert_contains "$GUARD_OUT" "backport=1" "backport: fix: commit in the range -> prompt"
}

# delayed_log_git_dir — directory holding a `git` wrapper whose `log --format=%s`
# writes one subject per line with a short fixture delay between writes. Every
# other git command is passed through untouched. The wrapper is its own writer
# (no inner pipeline), so a reader that exits early gives it a real SIGPIPE and
# exit status 141 — the scheduling a slow CI runner can produce on its own.
delayed_log_git_dir() {
  local dir real_git
  dir="$(mktemp -d "${SANDBOX_ROOT}/delaygit.XXXXXX")"
  real_git="$(command -v git)"
  cat >"${dir}/git" <<WRAP
#!/usr/bin/env bash
if [[ "\${1:-}" == log && "\${2:-}" == --format=%s ]]; then
  subjects="\$("${real_git}" "\$@")" || exit \$?
  while IFS= read -r subject; do
    printf '%s\n' "\$subject"
    sleep 0.05
  done <<<"\$subjects"
  exit 0
fi
exec "${real_git}" "\$@"
WRAP
  chmod +x "${dir}/git"
  echo "$dir"
}

# A fix: subject followed (in git log order) by a non-fix subject. A reader that
# stops at the first match must not kill the producer under pipefail.
test_guard_backport_label_slow_log() {
  local repo wrapdir
  repo="$(release_repo "model: release-branches
trunk: main
maintenance: release/0.6, release/0.5
backport_label: port-to/{X.Y}")"
  git -C "$repo" checkout -q -b feat/slow
  commit_file "$repo" a.txt "a" "feat: older non-fix commit"
  commit_file "$repo" b.txt "b" "fix: newer fix commit"
  wrapdir="$(delayed_log_git_dir)"

  GUARD_RC=0
  GUARD_OUT="$(cd "$repo" && PATH="${wrapdir}:${PATH}" bash "$GUARD" backport-label --base main --title "chore: tidy" 2>&1)" || GUARD_RC=$?
  assert_exit "$GUARD_RC" 0 "backport: slow git log, fix first -> guard exits cleanly"
  assert_contains "$GUARD_OUT" "backport=1" "backport: slow git log, fix commit then non-fix -> prompt"

  # The delay must not turn a range without any fix into a prompt.
  git -C "$repo" checkout -q -b feat/slow-nofix main
  commit_file "$repo" c.txt "c" "feat: another thing"
  commit_file "$repo" d.txt "d" "docs: note"
  GUARD_RC=0
  GUARD_OUT="$(cd "$repo" && PATH="${wrapdir}:${PATH}" bash "$GUARD" backport-label --base main --title "chore: tidy" 2>&1)" || GUARD_RC=$?
  assert_eq "$GUARD_OUT" "backport=0
reason=not a fix" "backport: slow git log, no fix in range -> no prompt"
}

# ---------------------------------------------------------------------------
# create-pr.sh (git-workflow) with a stubbed gh
# ---------------------------------------------------------------------------

# stub_gh — install a fake gh that reports auth OK, no existing PR, "main" as
# the default branch, and records `gh pr create` arguments in GH_LOG.
stub_gh() {
  local bin="${SANDBOX_ROOT}/bin"
  mkdir -p "$bin"
  GH_LOG="${SANDBOX_ROOT}/gh.log"
  : >"$GH_LOG"
  cat >"${bin}/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo main ;;
  "pr list") echo "" ;;
  "pr create")
    shift 2
    printf '%s\n' "$@" >>"$GH_LOG"
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --body ]]; then printf '%s\n' "$2" >"${GH_LOG}.body"; break; fi
      shift
    done
    ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "${bin}/gh"
  STUB_PATH="${bin}:${PATH}"
}

# run_create_pr <repo> [args...] — run create-pr.sh with the gh stub; the
# origin path doubles as a configured GitHub host (GH_HOST).
run_create_pr() {
  local repo="$1" origin
  shift
  origin="$(git -C "$repo" remote get-url origin)"
  CREATE_RC=0
  CREATE_OUT="$(cd "$repo" && PATH="$STUB_PATH" GH_HOST="${origin%.git}" GH_LOG="$GH_LOG" \
    bash "$CREATE_PR" "$@" 2>&1)" || CREATE_RC=$?
}

# gh_create_base — the --base value recorded by the last `gh pr create`.
gh_create_base() {
  sed -n '/^--base$/{n;p;}' "$GH_LOG" | tail -1
}

test_create_pr() {
  local repo
  stub_gh

  repo="$(mkrepo)"
  git -C "$repo" checkout -q -b feat/x
  commit_file "$repo" x.txt "x" "feat: x"
  git -C "$repo" push -q origin feat/x
  run_create_pr "$repo" --create
  assert_exit "$CREATE_RC" 0 "create-pr: no RELEASING.md creates the PR"
  assert_eq "$(gh_create_base)" "main" "create-pr: no RELEASING.md targets the forge default branch"

  git -C "$repo" push -q origin main:refs/heads/develop
  git -C "$repo" fetch -q origin
  : >"$GH_LOG"
  run_create_pr "$repo" --create --base develop
  assert_exit "$CREATE_RC" 0 "create-pr: --base creates the PR"
  assert_eq "$(gh_create_base)" "develop" "create-pr: --base overrides the base"

  repo="$(sync_repo)"
  git -C "$repo" checkout -q -b fix/y origin/release/0.5
  commit_file "$repo" y.txt "y" "fix: y"
  git -C "$repo" push -q origin fix/y
  : >"$GH_LOG"
  run_create_pr "$repo" --create
  assert_exit "$CREATE_RC" 0 "create-pr: RELEASING.md base creates the PR"
  assert_eq "$(gh_create_base)" "release/0.5" "create-pr: branch cut from release/0.5 targets it"

  git -C "$repo" merge -q --no-edit --no-ff origin/main >/dev/null
  git -C "$repo" push -q origin fix/y
  : >"$GH_LOG"
  run_create_pr "$repo" --create
  assert_exit "$CREATE_RC" 1 "create-pr: sync merge refused"
  assert_contains "$CREATE_OUT" "sync merge" "create-pr: refusal names the sync merge"
  assert_eq "$(cat "$GH_LOG")" "" "create-pr: no PR created after a refusal"
}

gh_related_issues() {
  awk '/^## Related Issues$/ { related = 1; next }
       related && /^## / { exit }
       related && NF { print }' "${GH_LOG}.body"
}

test_create_pr_related_issues() {
  local repo expected helper_root CLAUDE_PLUGIN_ROOT CREATE_PR="$CREATE_PR"
  local warning='Skipping Linear issue links: no ARTIFACT_LINEAR_TEAM configured and no Linear MCP to verify keys.'
  stub_gh
  repo="$(mkrepo)"
  git -C "$repo" checkout -q -b feat/yan-11-related
  commit_file "$repo" .plans-config $'scope: local\nlinear_team: YAN' 'chore: configure team'
  commit_file "$repo" old.txt old $'fix: older\n\nCloses YAN-12\nCloses #10\nFixes #9'
  commit_file "$repo" new.txt new $'fix: newer\n\nRefs YAN-15\nRefs YAN-12\nCloses YAN-11\nCloses #9\nRefs OTHER-1'
  git -C "$repo" push -q origin HEAD
  run_create_pr "$repo" --create
  assert_exit "$CREATE_RC" 0 'create-pr: related issue collection creates PR'
  expected=$'Closes YAN-11\nRefs YAN-15\nCloses YAN-12\nCloses #9\nCloses #10'
  assert_eq "$(gh_related_issues)" "$expected" 'create-pr: action semantics, dedupe, team filter and commit order'
  if [[ "$CREATE_OUT" != *"$warning"* ]]; then ok 'create-pr: configured team does not warn'; else ko 'create-pr: configured team unexpectedly warns'; fi

  commit_file "$repo" .plans-config 'scope: local' 'chore: remove team'
  git -C "$repo" push -q origin HEAD
  run_create_pr "$repo" --create
  assert_exit "$CREATE_RC" 0 'create-pr: missing team still creates PR'
  assert_eq "$(gh_related_issues)" $'Closes #9\nCloses #10' 'create-pr: no team skips Linear but keeps GitHub refs'
  assert_contains "$CREATE_OUT" "$warning" 'create-pr: candidates without team print canonical warning'

  repo="$(mkrepo)"
  git -C "$repo" checkout -q -b feat/plain
  commit_file "$repo" plain.txt plain 'feat: plain'
  git -C "$repo" push -q origin HEAD
  run_create_pr "$repo" --create
  assert_exit "$CREATE_RC" 0 'create-pr: no candidates creates PR'
  assert_eq "$(gh_related_issues)" 'Closes #' 'create-pr: no links keeps placeholder'
  if [[ "$CREATE_OUT" != *"$warning"* ]]; then ok 'create-pr: no candidates does not warn'; else ko 'create-pr: no candidates unexpectedly warns'; fi
  git -C "$repo" checkout -q -b feat/yan-99-unverified
  git -C "$repo" push -q origin HEAD
  run_create_pr "$repo" --create
  assert_exit "$CREATE_RC" 0 'create-pr: unverified hint still creates PR'
  assert_eq "$(gh_related_issues)" 'Closes #' 'create-pr: unverified-only links keep placeholder'
  assert_contains "$CREATE_OUT" "$warning" 'create-pr: unverified-only hint warns'

  # A copied script tree lets missing/failing optional helpers be tested without
  # changing the source checkout or relying on a configurable production hook.
  export CLAUDE_PLUGIN_ROOT="${SANDBOX_ROOT}/optional-helper"
  helper_root="${CLAUDE_PLUGIN_ROOT}/skills"
  mkdir -p "${helper_root}/git-workflow/scripts" "${helper_root}/_shared"
  cp "$CREATE_PR" "${helper_root}/git-workflow/scripts/create-pr.sh"
  cp -R "$SHARED" "${helper_root}/_shared/scripts"
  CREATE_PR="${helper_root}/git-workflow/scripts/create-pr.sh"
  rm "${helper_root}/_shared/scripts/collect-linear-keys.sh"
  run_create_pr "$repo" --create
  assert_exit "$CREATE_RC" 0 'create-pr: missing collector does not prevent PR'
  assert_eq "$(gh_related_issues)" 'Closes #' 'create-pr: missing collector keeps placeholder'
  printf '#!/usr/bin/env bash\nexit 1\n' >"${helper_root}/_shared/scripts/collect-linear-keys.sh"
  run_create_pr "$repo" --create
  assert_exit "$CREATE_RC" 0 'create-pr: failing collector does not prevent PR'
  assert_eq "$(gh_related_issues)" 'Closes #' 'create-pr: failing collector keeps placeholder'
}

# ---------------------------------------------------------------------------

test_prep_no_state_unchanged
test_prep_artifact_gitignore
test_prep_state_trunk_nonstandard
test_prep_branches_from_origin_trunk
test_prep_from_other_trunk_uses_state_trunk
test_prep_plan_files_carried
test_prep_plan_conflict_falls_back
test_prep_release_branch
test_prep_fetch_failure
test_prep_malformed_state
test_guard_base
test_guard_sync_check
test_guard_backport_label
test_guard_backport_label_slow_log
test_create_pr
test_create_pr_related_issues

echo
echo "release branch-prep tests: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
