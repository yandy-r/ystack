#!/usr/bin/env bash
# test-worktree-roots.sh — per-runtime repo-local worktree roots (YAN-1111 / GH #271).
#
# Verifies, against every generated bundle's own worktree-paths.sh /
# setup-worktree.sh / list-worktrees.sh, using throwaway scratch repos:
#   - default root per bundle (claude/codex/cursor/opencode/omp/agents)
#   - agents bundle runtime selection + .agents fallback (nested/unknown);
#     OMPCODE=1 wins over the CLAUDECODE=1 marker OMP also sets (YAN-1170)
#   - YCC_WORKTREE_ROOT override (absolute, relative, ~, spaces)
#   - setup-worktree.sh parent + idempotency + list-worktrees.sh
#   - paths with spaces
#   - home rewrites preserved (~/.claude/ -> per-target home) next to worktree roots
#   - gitignore template and generated bundles ignore every root
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ycc-worktree-roots.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# Git hooks (pre-push runs validate.sh) export GIT_DIR and friends; left set,
# they would point every scratch `git` call at the caller's repository —
# polluting its refs, worktree registrations, and config. Clear them all before
# any git operation, then pin git to a scratch config so neither system nor
# global config is read or written.
while IFS= read -r git_var; do
  unset "$git_var"
done < <(git rev-parse --local-env-vars)
unset git_var
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${SCRATCH}/gitconfig"
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

FAILED=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label: expected '$expected' got '$actual'"; fi
}

# bundle-name -> shared scripts dir
declare -A BUNDLES=(
  [claude]="${REPO_ROOT}/ycc/skills/_shared/scripts"
  [codex]="${REPO_ROOT}/.codex-plugin/ycc/shared/scripts"
  [cursor]="${REPO_ROOT}/packages/cursor/ycc/skills/_shared/scripts"
  [opencode]="${REPO_ROOT}/.opencode-plugin/shared/scripts"
  [omp]="${REPO_ROOT}/packages/omp/ycc/skills/_shared/scripts"
  [agents]="${REPO_ROOT}/.agents-plugin/ycc-shared/scripts"
)
# bundle-name -> expected default root dir name
declare -A EXPECTED=([claude]=.claude [codex]=.codex [cursor]=.cursor [opencode]=.opencode [omp]=.omp [agents]=.agents)

CLEAN_ENV=(env -u YCC_WORKTREE_ROOT -u OPENCODE -u OMPCODE -u CLAUDECODE -u CODEX_THREAD_ID)

make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
}

default_root() { # <bundle> <repo> [extra env assignments...]
  local bundle="$1" repo="$2"
  shift 2
  (cd "$repo" && "${CLEAN_ENV[@]}" "$@" bash -c 'source "$1"; ycc_worktree_root' _ "${BUNDLES[$bundle]}/worktree-paths.sh")
}

for bundle in claude codex cursor opencode omp agents; do
  [[ -f "${BUNDLES[$bundle]}/worktree-paths.sh" ]] || { fail "$bundle: worktree-paths.sh missing"; continue; }
  repo="${SCRATCH}/repo-${bundle}"
  make_repo "$repo"
  canon="$(cd "$repo" && pwd -P)"
  assert_eq "$bundle default root" "${canon}/${EXPECTED[$bundle]}/worktrees" "$(default_root "$bundle" "$repo")"
done

# Agents bundle: runtime selection with .agents fallback.
repo="${SCRATCH}/repo-agents"
canon="$(cd "$repo" && pwd -P)"
assert_eq "agents: OPENCODE=1 -> .opencode" "${canon}/.opencode/worktrees" "$(default_root agents "$repo" OPENCODE=1)"
assert_eq "agents: CLAUDECODE=1 -> .claude" "${canon}/.claude/worktrees" "$(default_root agents "$repo" CLAUDECODE=1)"
assert_eq "agents: CODEX_THREAD_ID -> .codex" "${canon}/.codex/worktrees" "$(default_root agents "$repo" CODEX_THREAD_ID=t1)"
assert_eq "agents: OMPCODE=1 CLAUDECODE=1 -> .omp" "${canon}/.omp/worktrees" "$(default_root agents "$repo" OMPCODE=1 CLAUDECODE=1)"
assert_eq "agents: OMPCODE=1 -> .omp" "${canon}/.omp/worktrees" "$(default_root agents "$repo" OMPCODE=1)"
assert_eq "agents: OMPCODE=0 ignored -> .claude" "${canon}/.claude/worktrees" "$(default_root agents "$repo" OMPCODE=0 CLAUDECODE=1)"
assert_eq "agents: OMPCODE+OPENCODE -> .agents" "${canon}/.agents/worktrees" "$(default_root agents "$repo" OMPCODE=1 CLAUDECODE=1 OPENCODE=1)"
assert_eq "agents: OMPCODE+CODEX_THREAD_ID -> .agents" "${canon}/.agents/worktrees" "$(default_root agents "$repo" OMPCODE=1 CODEX_THREAD_ID=t1)"
assert_eq "agents: nested markers -> .agents" "${canon}/.agents/worktrees" "$(default_root agents "$repo" OPENCODE=1 CLAUDECODE=1)"
assert_eq "agents: OPENCODE=0 ignored -> .agents" "${canon}/.agents/worktrees" "$(default_root agents "$repo" OPENCODE=0)"
assert_eq "agents: empty CODEX_THREAD_ID -> .agents" "${canon}/.agents/worktrees" "$(default_root agents "$repo" CODEX_THREAD_ID=)"
assert_eq "agents: unsupported CURSOR_AGENT -> .agents" "${canon}/.agents/worktrees" "$(default_root agents "$repo" CURSOR_AGENT=1)"

# Non-agents bundles must NOT be influenced by runtime markers.
for bundle in claude codex cursor opencode omp; do
  [[ -f "${BUNDLES[$bundle]}/worktree-paths.sh" ]] || continue
  repo="${SCRATCH}/repo-${bundle}"
  canon="$(cd "$repo" && pwd -P)"
  assert_eq "$bundle ignores runtime markers" "${canon}/${EXPECTED[$bundle]}/worktrees" "$(default_root "$bundle" "$repo" OPENCODE=1 OMPCODE=1 CLAUDECODE=1)"
done

# setup-worktree.sh / list-worktrees.sh / override / spaces / idempotency.
for bundle in claude codex cursor opencode omp agents; do
  scripts="${BUNDLES[$bundle]}"
  [[ -f "${scripts}/setup-worktree.sh" ]] || { fail "$bundle: setup-worktree.sh missing"; continue; }
  repo="${SCRATCH}/with space/repo-${bundle}"
  make_repo "$repo"
  canon="$(cd "$repo" && pwd -P)"
  name="$(basename "$repo")"
  expected_path="${canon}/${EXPECTED[$bundle]}/worktrees/${name}-feat-one"

  got="$(cd "$repo" && "${CLEAN_ENV[@]}" bash "${scripts}/setup-worktree.sh" parent "$name" feat-one 2>/dev/null)"
  assert_eq "$bundle setup parent path (spaces)" "$expected_path" "$got"
  [[ -e "${expected_path}/.git" ]] && pass "$bundle worktree created" || fail "$bundle worktree not created"

  again="$(cd "$repo" && "${CLEAN_ENV[@]}" bash "${scripts}/setup-worktree.sh" parent "$name" feat-one 2>/dev/null)"
  assert_eq "$bundle setup idempotent" "$expected_path" "$again"

  listed="$(cd "$repo" && "${CLEAN_ENV[@]}" bash "${scripts}/list-worktrees.sh" "$name" feat-one)"
  grep -qF "${EXPECTED[$bundle]}/worktrees/${name}-feat-one" <<<"$listed" \
    && pass "$bundle list-worktrees sees root" || fail "$bundle list-worktrees missing root: $listed"

  # Absolute override
  override="${SCRATCH}/override root/${bundle}"
  got="$(cd "$repo" && env -u OPENCODE -u OMPCODE -u CLAUDECODE -u CODEX_THREAD_ID YCC_WORKTREE_ROOT="$override" bash "${scripts}/setup-worktree.sh" parent "$name" feat-two 2>/dev/null)"
  assert_eq "$bundle absolute override" "${override}/${name}-feat-two" "$got"

  # Relative override resolves against repo root
  got="$(cd "$repo" && env -u OPENCODE -u OMPCODE -u CLAUDECODE -u CODEX_THREAD_ID YCC_WORKTREE_ROOT="rel/wt" bash "${scripts}/setup-worktree.sh" parent "$name" feat-three 2>/dev/null)"
  assert_eq "$bundle relative override" "${canon}/rel/wt/${name}-feat-three" "$got"

  # ~ override
  got="$(cd "$repo" && env -u OPENCODE -u OMPCODE -u CLAUDECODE -u CODEX_THREAD_ID HOME="${SCRATCH}/home" YCC_WORKTREE_ROOT="~/wt" bash -c 'source "$1"; ycc_worktree_root' _ "${scripts}/worktree-paths.sh")"
  assert_eq "$bundle ~ override" "${SCRATCH}/home/wt" "$got"
done

# Home rewrites preserved: ~/.claude/ still retargets to each runtime's user-global home.
check_home() { # <label> <file> <expected-substring> <forbidden-substring>
  local label="$1" file="$2" want="$3" bad="$4"
  if [[ ! -f "$file" ]]; then fail "$label: missing $file"; return; fi
  grep -qF -- "$want" "$file" && pass "$label has '$want'" || fail "$label lacks '$want'"
  if grep -qF -- "$bad" "$file"; then fail "$label contains forbidden '$bad'"; else pass "$label free of '$bad'"; fi
}
check_home "opencode home rewrite" "${REPO_ROOT}/.opencode-plugin/shared/references/worktree-strategy.md" ".opencode/worktrees" ".config/opencode/.opencode"
check_home "opencode worktree-paths" "${REPO_ROOT}/.opencode-plugin/shared/scripts/worktree-paths.sh" ".opencode/worktrees" ".config/opencode/worktrees"
if grep -rqF '~''/.config/opencode/' "${REPO_ROOT}/.opencode-plugin/skills" 2>/dev/null; then
  pass "opencode ~/.config/opencode/ home rewrite preserved"
else
  fail "opencode ~/.config/opencode/ home rewrite lost"
fi
if grep -rqF '~''/.cursor/' "${REPO_ROOT}/packages/cursor/ycc/skills" 2>/dev/null; then pass "cursor ~/.cursor/ home rewrite preserved"; else fail "cursor home rewrite lost"; fi
if grep -rqF '~''/.codex/' "${REPO_ROOT}/.codex-plugin/ycc/skills" 2>/dev/null; then pass "codex ~/.codex/ home rewrite preserved"; else fail "codex home rewrite lost"; fi

# No generated bundle may contain the retired opencode root as a live default.
if grep -rn 'config/opencode/worktrees' "${REPO_ROOT}/.opencode-plugin" "${REPO_ROOT}/.codex-plugin" "${REPO_ROOT}/packages/cursor" "${REPO_ROOT}/packages/omp" "${REPO_ROOT}/.agents-plugin" \
  | grep -v 'worktree-strategy.md' | grep -q .; then
  fail "retired .config/opencode/worktrees default still present in a bundle"
else
  pass "no live .config/opencode/worktrees default in bundles"
fi

# Claude WorktreeCreate hook (ycc/settings/hooks/worktree-create.sh) direct smoke tests.
HOOK_SH="${REPO_ROOT}/ycc/settings/hooks/worktree-create.sh"
hook_repo="${SCRATCH}/with space/hook-repo"
make_repo "$hook_repo"
hook_canon="$(cd "$hook_repo" && pwd -P)"
hook_name="$(basename "$hook_repo")"

run_hook() { # <slug> [extra env assignments...]
  local slug="$1"
  shift
  printf '{"name":"%s","cwd":"%s","session_id":"s1","hook_event_name":"WorktreeCreate"}' "$slug" "$hook_canon" \
    | "${CLEAN_ENV[@]}" "$@" bash "$HOOK_SH" 2>/dev/null
}

assert_eq "hook default root (spaces in cwd)" \
  "${hook_canon}/.claude/worktrees/${hook_name}-hook-default" \
  "$(run_hook hook-default)"
[[ -e "${hook_canon}/.claude/worktrees/${hook_name}-hook-default/.git" ]] \
  && pass "hook default created worktree" || fail "hook default missing .git"

assert_eq "hook ~ override" \
  "${SCRATCH}/hook-home/wt/${hook_name}-hook-tilde" \
  "$(run_hook hook-tilde HOME="${SCRATCH}/hook-home" YCC_WORKTREE_ROOT="~/wt")"
assert_eq "hook bare ~ override" \
  "${SCRATCH}/hook-bare-home/${hook_name}-hook-bare" \
  "$(run_hook hook-bare HOME="${SCRATCH}/hook-bare-home" YCC_WORKTREE_ROOT="~")"
assert_eq "hook relative override (with space)" \
  "${hook_canon}/rel wt/${hook_name}-hook-rel" \
  "$(run_hook hook-rel YCC_WORKTREE_ROOT="rel wt")"
assert_eq "hook absolute override (with space)" \
  "${SCRATCH}/hook abs root/${hook_name}-hook-abs" \
  "$(run_hook hook-abs YCC_WORKTREE_ROOT="${SCRATCH}/hook abs root")"

# Regression: without jq, the grep fallback must treat missing optional fields
# (here base_ref) as empty success instead of aborting under pipefail.
nojq_bin="${SCRATCH}/nojq-bin"
mkdir -p "$nojq_bin"
for tool in bash git grep sed head cat tr basename dirname mkdir env rm; do
  ln -sf "$(command -v "$tool")" "${nojq_bin}/${tool}"
done
nojq_out="$(printf '{"name":"hook-nojq","cwd":"%s","session_id":"s1"}' "$hook_canon" \
  | env -u YCC_WORKTREE_ROOT PATH="$nojq_bin" "${nojq_bin}/bash" "$HOOK_SH" 2>/dev/null)" || nojq_out="<exit $?>"
assert_eq "hook without jq tolerates missing base_ref" \
  "${hook_canon}/.claude/worktrees/${hook_name}-hook-nojq" "$nojq_out"

# Regression: an ordinary directory at the target path (inside the source repo,
# so parent git discovery succeeds) must be rejected, not reused as a worktree.
plain_dir="${hook_canon}/.claude/worktrees/${hook_name}-hook-plain"
mkdir -p "$plain_dir"
if run_hook hook-plain >/dev/null; then
  fail "hook accepted ordinary nested directory as worktree"
else
  pass "hook rejects ordinary nested directory"
fi

# Existing registered worktree is still reused idempotently.
assert_eq "hook reuses existing worktree" \
  "${hook_canon}/.claude/worktrees/${hook_name}-hook-default" \
  "$(run_hook hook-default)"

# worktree-strategy.md: outside the protected evidence block, target rewrites apply.
for strat in \
  "${REPO_ROOT}/.codex-plugin/ycc/shared/references/worktree-strategy.md" \
  "${REPO_ROOT}/packages/cursor/ycc/skills/_shared/references/worktree-strategy.md" \
  "${REPO_ROOT}/.opencode-plugin/shared/references/worktree-strategy.md" \
  "${REPO_ROOT}/packages/omp/ycc/skills/_shared/references/worktree-strategy.md" \
  "${REPO_ROOT}/.agents-plugin/ycc-shared/references/worktree-strategy.md"; do
  if grep -qE 'ycc:|ycc/skills/|Agent\(isolation|<!-- ycc:verbatim-block' "$strat"; then
    fail "${strat#"$REPO_ROOT"/} leaked unrewritten source token or marker"
  else
    pass "${strat#"$REPO_ROOT"/} rewritten cleanly outside verbatim block"
  fi
done

# Gitignore coverage: repo .gitignore + init template (source and every bundle).
ROOTS=(.claude/worktrees/ .opencode/worktrees/ .codex/worktrees/ .cursor/worktrees/ .omp/worktrees/ .agents/worktrees/)
for f in \
  "${REPO_ROOT}/.gitignore" \
  "${REPO_ROOT}/ycc/skills/init/templates/git/gitignore.tmpl" \
  "${REPO_ROOT}/.codex-plugin/ycc/skills/init/templates/git/gitignore.tmpl" \
  "${REPO_ROOT}/packages/cursor/ycc/skills/init/templates/git/gitignore.tmpl" \
  "${REPO_ROOT}/.opencode-plugin/skills/init/templates/git/gitignore.tmpl" \
  "${REPO_ROOT}/packages/omp/ycc/skills/init/templates/git/gitignore.tmpl" \
  "${REPO_ROOT}/.agents-plugin/skills/init/templates/git/gitignore.tmpl"; do
  for r in "${ROOTS[@]}"; do
    grep -qxF "$r" "$f" && pass "$(basename "$(dirname "$f")")/$(basename "$f") ignores $r" || fail "${f#"$REPO_ROOT"/} missing $r"
  done
done

# Regression (YAN-1111 push incident): when this suite runs inside a git hook,
# GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR point at a foreign repository. Re-invoke
# the full suite with those vars aimed at a disposable sentinel repo and assert
# the sentinel's git state is byte-identical afterwards. The sentinel is a
# scratch repo under this run's temp dir — never a real checkout.
if [[ -z "${YCC_WT_ROOTS_SELFTEST:-}" ]]; then
  SENTINEL="${SCRATCH}/sentinel repo"
  make_repo "$SENTINEL"
  git -C "$SENTINEL" worktree add -q -b sentinel-peer "${SCRATCH}/sentinel peer"
  snapshot_git_state() { # <repo> -> deterministic listing+digest of .git
    find "$1/.git" -mindepth 1 | sort | while IFS= read -r path; do
      if [[ -d "$path" ]]; then
        printf 'd %s\n' "${path#"$1"/}"
      else
        printf 'f %s %s\n' "${path#"$1"/}" "$(sha256sum "$path" | cut -d' ' -f1)"
      fi
    done
  }
  before="$(snapshot_git_state "$SENTINEL")"

  nested_output="$(cd / && YCC_WT_ROOTS_SELFTEST=1 \
    GIT_DIR="${SENTINEL}/.git" \
    GIT_WORK_TREE="$SENTINEL" \
    GIT_COMMON_DIR="${SENTINEL}/.git" \
    GIT_INDEX_FILE="${SENTINEL}/.git/index" \
    GIT_OBJECT_DIRECTORY="${SENTINEL}/.git/objects" \
    GIT_PREFIX="sentinel-prefix/" \
    bash "$SELF" 2>&1)" || nested_output="${nested_output}
(nested run exited nonzero)"

  after="$(snapshot_git_state "$SENTINEL")"
  assert_eq "hook-env selftest leaves foreign repo untouched" "$before" "$after"
  if grep -q 'test-worktree-roots.sh: all checks passed' <<<"$nested_output"; then
    pass "hook-env selftest nested suite passed"
  else
    fail "hook-env selftest nested suite failed: ${nested_output##*$'\n'}"
  fi
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "test-worktree-roots.sh: FAILED" >&2
  exit 1
fi
echo "test-worktree-roots.sh: all checks passed"
