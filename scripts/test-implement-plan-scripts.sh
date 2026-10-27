#!/usr/bin/env bash
# Implementation plan path and body-only parsing regressions.
set -euo pipefail
BASH_BIN=${BASH_BIN:-bash}
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)"
IMPL="${SCRIPT_DIR}/../ycc/skills/implement-plan/scripts"
CHECK="${IMPL}/check-prerequisites.sh"
PARSE="${IMPL}/parse-dependencies.sh"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ycc-implement-scripts.XXXXXX")"
SCRATCH="$(CDPATH='' cd -- "$SCRATCH" >/dev/null && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT
while IFS= read -r git_var; do unset "$git_var"; done < <(git rev-parse --local-env-vars)
unset git_var
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${SCRATCH}/gitconfig"
export HOME="${SCRATCH}/home" XDG_CONFIG_HOME="${SCRATCH}/config" GIT_CEILING_DIRECTORIES="$SCRATCH"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
printf '[init]\n  defaultBranch = main\n' >"$GIT_CONFIG_GLOBAL"
PASS=0 FAIL=0
assert_eq() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1";
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s: expected <%s>, got <%s>\n' "$1" "$2" "$3" >&2; fi
}
run_check() { (CDPATH='' cd -- "$repo" >/dev/null && "$BASH_BIN" "$CHECK" "$@"); }
repo="${SCRATCH}/repo with space"
mkdir -p "$repo"
git -C "$repo" init -q -b main
printf 'scope: local\nplans_dir: custom plans\n' >"${repo}/.plans-config"
local_dir="${repo}/custom plans/example"
linear_dir="${repo}/.ycc/artifacts/example"
mkdir -p "$local_dir" "$linear_dir"
cat >"${SCRATCH}/body.md" <<'EOF'
# Example plan
## Worktree Setup
- **Parent**: /tmp/repo-example/ (branch: feat/example)
## Implementation Plan
### Phase 1: Build
#### Task 1.1: First Depends on [none]
#### Task 1.2: Second Depends on [1.1]
### Batch 2: Wire
#### Task T0: Third
- **Dependencies**: None
EOF
# A tasks map may contain multiline descriptions resembling plan body sections.
{
  cat <<'EOF'
---
linear:
  document: 00000000-0000-4000-8000-000000000000
tasks:
  '1.1':
    issue: YAN-1
    description: |
## Worktree Setup
- **Parent**: /wrong/frontmatter/
### Phase 99: Identity only
#### Task 99.1: Identity only Depends on [none]
---
EOF
  cat "${SCRATCH}/body.md"
} >"${SCRATCH}/frontmatter.md"
expected_parse=$'WT_PARENT_PATH=/tmp/repo-example/\nWT_FEATURE_SLUG=repo-example\n1.1|First|none\n1.2|Second|1.1\nT0|Third|none'
assert_eq 'plain dependency output unchanged' "$expected_parse" "$("$BASH_BIN" "$PARSE" "${SCRATCH}/body.md")"
assert_eq 'tasks identity cannot emit headers or tasks' "$expected_parse" "$("$BASH_BIN" "$PARSE" "${SCRATCH}/frontmatter.md")"
if [[ "$(id -u)" != 0 ]]; then
  cp "${SCRATCH}/body.md" "${SCRATCH}/unreadable.md"
  chmod 000 "${SCRATCH}/unreadable.md"
  if out=$("$BASH_BIN" "$PARSE" "${SCRATCH}/unreadable.md" 2>"${SCRATCH}/err"); then rc=0; else rc=$?; fi
  chmod 600 "${SCRATCH}/unreadable.md"
  assert_eq 'unreadable plan exits 1' 1 "$rc"
  assert_eq 'unreadable plan emits no task graph' '' "$out"
  assert_eq 'unreadable plan explains read failure' "ERROR: Cannot read: ${SCRATCH}/unreadable.md" "$(cat "${SCRATCH}/err")"
else
  printf 'SKIP: unreadable plan permission check (root)\n'
fi
cp "${SCRATCH}/body.md" "${local_dir}/parallel-plan.md"
printf '# Shared\n' >"${local_dir}/shared.md"
expected_local="Prerequisites satisfied
  Found: ${local_dir}/parallel-plan.md
  Found: ${local_dir}/shared.md
  Tasks in plan: 3
  Phases/Batches in plan: 2
  Independent tasks: 2"
assert_eq 'local prerequisite output unchanged' "$expected_local" "$(run_check example)"
assert_eq 'explicit local store output unchanged' "$expected_local" "$(run_check example --store=local)"
cp "${SCRATCH}/frontmatter.md" "${linear_dir}/parallel-plan.md"
printf '# Shared\n' >"${linear_dir}/shared.md"
expected_linear="Prerequisites satisfied
  Found: ${linear_dir}/parallel-plan.md
  Found: ${linear_dir}/shared.md
  Tasks in plan: 3
  Phases/Batches in plan: 2
  Independent tasks: 2"
assert_eq 'linear flag resolves cache and counts body only' "$expected_linear" "$(run_check --store=linear example)"
printf 'scope: local\nplans_dir: custom plans\nstore: linear\n' >"${repo}/.plans-config"
assert_eq 'linear config resolves cache' "$expected_linear" "$(run_check example)"
assert_eq 'local flag overrides linear config' "$expected_local" "$(run_check example --store=local)"
mkdir -p "${repo}/hydrated"
cp "${SCRATCH}/frontmatter.md" "${repo}/hydrated/chosen.md"
printf '# Shared\n' >"${repo}/hydrated/shared.md"
expected_explicit="Prerequisites satisfied
  Found: ${repo}/hydrated/chosen.md
  Found: ${repo}/hydrated/shared.md
  Tasks in plan: 3
  Phases/Batches in plan: 2
  Independent tasks: 2"
assert_eq 'explicit plan uses its filename and sibling shared' "$expected_explicit" "$(run_check --plan="${repo}/hydrated/chosen.md" --store=linear)"
assert_eq 'explicit plan also accepts feature name' "$expected_explicit" "$(run_check example --plan="${repo}/hydrated/chosen.md" --store=linear)"
rm "${repo}/hydrated/shared.md"
out=$(run_check example --plan="${repo}/hydrated/chosen.md")
if [[ "$out" == "WARNING: ${repo}/hydrated/shared.md not found"* ]]; then
  PASS=$((PASS + 1)); printf 'PASS: explicit plan warns about missing sibling context\n'
else FAIL=$((FAIL + 1)); printf 'FAIL: missing sibling warning\n' >&2; fi
cp "${SCRATCH}/body.md" "${repo}/plan.md"
out=$(run_check --plan=plan.md --store=local)
if [[ "$out" == *"Found: ${repo}/plan.md"* && "$out" == *'Consider running /shared-context repo with space first.'* ]]; then
  PASS=$((PASS + 1)); printf 'PASS: bare relative plan uses absolute dirname and feature name\n'
else FAIL=$((FAIL + 1)); printf 'FAIL: bare relative plan path or guidance\n' >&2; fi
if out=$(run_check --plan=missing.md --store=local); then rc=0; else rc=$?; fi
assert_eq 'bare missing plan exits 1' 1 "$rc"
if [[ "$out" == *"ERROR: ${repo}/missing.md not found"* && "$out" == *'Run: /parallel-plan repo with space'* ]]; then
  PASS=$((PASS + 1)); printf 'PASS: bare missing plan guidance uses dirname basename\n'
else FAIL=$((FAIL + 1)); printf 'FAIL: bare missing plan guidance\n' >&2; fi
if out=$(run_check missing --store=local); then rc=0; else rc=$?; fi
assert_eq 'missing local directory exit unchanged' 1 "$rc"
assert_eq 'missing local directory guidance unchanged' "ERROR: Plan directory not found: ${repo}/custom plans/missing

Create the planning documents first:
  1. Run /shared-context missing
  2. Run /parallel-plan missing" "$out"
mkdir -p "${repo}/custom plans/missing"
if out=$(run_check missing --store=local); then rc=0; else rc=$?; fi
assert_eq 'missing local plan exit unchanged' 1 "$rc"
assert_eq 'missing local plan guidance unchanged' "ERROR: ${repo}/custom plans/missing/parallel-plan.md not found

The implementation requires a parallel plan to be created first.
Run: /parallel-plan missing

This will create parallel-plan.md with detailed implementation tasks." "$out"
for kind in directory file; do
  if [[ "$kind" == file ]]; then mkdir -p "${repo}/.ycc/artifacts/missing"; fi
  if out=$(run_check missing --store=linear); then rc=0; else rc=$?; fi
  assert_eq "missing linear ${kind} exits 1" 1 "$rc"
  if [[ "$out" == *'Run Lookup and hydrate the plan from Linear'* && "$out" != *'Run: /parallel-plan'* ]]; then
    PASS=$((PASS + 1)); printf 'PASS: missing linear %s suggests Lookup/hydrate\n' "$kind"
  else FAIL=$((FAIL + 1)); printf 'FAIL: missing linear %s guidance\n' "$kind" >&2; fi
done
for args in '--store=broken' '--plan=' '--unknown'; do
  if run_check example "$args" >"${SCRATCH}/out" 2>"${SCRATCH}/err"; then
    FAIL=$((FAIL + 1)); printf 'FAIL: invalid option %s succeeded\n' "$args" >&2
  else PASS=$((PASS + 1)); printf 'PASS: invalid option %s fails\n' "$args"; fi
done
printf 'test-implement-plan-scripts.sh: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
