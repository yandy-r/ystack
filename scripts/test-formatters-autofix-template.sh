#!/usr/bin/env bash
# Contract tests for the formatters lint-autofix workflow template.
# Renders lint-autofix.yml.tmpl through apply-ci.sh, then checks that the PR-code
# job holds no secrets, that the push job never runs PR code, and runs the push
# job's own scripts against crafted patches and a local bare repository.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." >/dev/null && pwd -P)"
APPLY_CI="${REPO_ROOT}/ycc/skills/formatters/scripts/apply-ci.sh"

[[ -x "$APPLY_CI" ]] || { echo "test-formatters-autofix-template: missing $APPLY_CI" >&2; exit 1; }
command -v python3 >/dev/null || { echo "test-formatters-autofix-template: python3 required" >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || {
  echo "test-formatters-autofix-template: PyYAML required (python3 -m pip install --user pyyaml)" >&2
  exit 1
}

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ycc-autofix-tmpl.XXXXXX")"
SCRATCH="$(CDPATH='' cd -- "$SCRATCH" >/dev/null && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

# Isolate git from the host repository and the user's config (pre-push hooks
# export GIT_DIR and friends).
while IFS= read -r git_var; do unset "$git_var"; done < <(git rev-parse --local-env-vars)
unset git_var
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${SCRATCH}/gitconfig"
export HOME="${SCRATCH}/home" XDG_CONFIG_HOME="${SCRATCH}/config" GIT_CEILING_DIRECTORIES="$SCRATCH"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
  name = ycc test
  email = ycc-test@example.invalid
[commit]
  gpgsign = false
[init]
  defaultBranch = main
EOF

PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }

# --- Render: every language block on, and every block off. ---
render() {
  local name="$1" value="$2" target="${SCRATCH}/render-$1"
  mkdir -p "$target"
  {
    for lang in rust go ts python docs shell; do printf 'detect_%s=%s\n' "$lang" "$value"; done
  } >"${SCRATCH}/profile-${name}"
  "$APPLY_CI" --target "$target" --profile-file "${SCRATCH}/profile-${name}" >/dev/null
  printf '%s\n' "${target}/.github/workflows/lint-autofix.yml"
}
wf_all="$(render all true)"
wf_none="$(render none false)"

# --- Structural contract (parsed YAML). ---
check_structure() {
  python3 - "$1" "$2" <<'PY'
import sys
import yaml

path, label = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(path, encoding="utf-8"))
failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


SAME_REPO = "github.event.pull_request.head.repo.full_name == github.repository"
jobs = doc.get("jobs", {})
check(doc.get("permissions") == {"contents": "read"}, "workflow permissions must be contents: read")
check(set(jobs) == {"format", "push"}, f"expected jobs format+push, got {sorted(jobs)}")
fmt, push = jobs.get("format", {}), jobs.get("push", {})

# Job 1: runs PR code, so no secrets, no App token, read-only token.
fmt_text = yaml.safe_dump(fmt)
check(SAME_REPO in str(fmt.get("if", "")), "format job must skip fork PRs")
check(fmt.get("permissions") == {"contents": "read"}, "format job permissions must be contents: read")
for needle in ("secrets.", "AUTOFIX_APP_PRIVATE_KEY", "create-github-app-token", "permission-workflows",
               "AUTOFIX_APP_CLIENT_ID"):
    check(needle not in fmt_text, f"format job must not mention {needle}")
fmt_steps = fmt.get("steps", [])
checkouts = [s for s in fmt_steps if str(s.get("uses", "")).startswith("actions/checkout@")]
check(len(checkouts) == 1, "format job checks out the PR head once")
for s in checkouts:
    check(s.get("with", {}).get("persist-credentials") is False, "format checkout must set persist-credentials: false")
check(any("style.sh format" in str(s.get("run", "")) for s in fmt_steps), "format job runs style.sh format")
check(any(str(s.get("uses", "")).startswith("actions/upload-artifact@") for s in fmt_steps),
      "format job uploads the patch artifact")
check("has_patch" in str(fmt.get("outputs", {})), "format job exposes has_patch")

# Job 2: holds the App token, never checks out or runs PR code.
check(push.get("needs") in ("format", ["format"]), "push job needs format")
push_if = str(push.get("if", ""))
check(SAME_REPO in push_if, "push job must skip fork PRs")
check("needs.format.outputs.has_patch == 'true'" in push_if, "push job runs only when a patch exists")
perms = push.get("permissions")
check(perms in ({"contents": "read"}, {}), f"push job GITHUB_TOKEN must stay read-only, got {perms}")
allowed_uses = ("actions/download-artifact@", "actions/create-github-app-token@")
forbidden_run = ("style.sh", "npm ", "npm\n", "npx ", "pnpm", "yarn", "pip ", "pip3 ", "cargo", "go install",
                 "go run", "install-shellcheck", "make ", "just ", "./scripts/", "bash ./", "sh ./", "source ",
                 "git checkout", "git switch", "git worktree", "git clone", "checkout-index")
mints = []
for s in push.get("steps", []):
    uses = str(s.get("uses", ""))
    if uses:
        check(uses.startswith(allowed_uses), f"push job must not use {uses}")
        if uses.startswith("actions/create-github-app-token@"):
            mints.append(s)
    run = str(s.get("run", ""))
    for needle in forbidden_run:
        check(needle not in run, f"push job step {s.get('name')!r} must not run {needle.strip()!r}")
    check("${{" not in run, f"push job step {s.get('name')!r} must pass expressions through env, not inline")
check(len(mints) == 1, "push job mints exactly one App token")
for m in mints:
    w = m.get("with", {})
    check(w.get("permission-contents") == "write", "mint requests contents: write")
    check(not any(k.startswith("permission-") and k != "permission-contents" for k in w),
          f"mint must request contents only, got {sorted(w)}")
    check(m.get("continue-on-error") is True, "a failed mint must report, not fail")
check("permission-workflows" not in open(path, encoding="utf-8").read(), "no permission-workflows anywhere")

if failures:
    for f in failures:
        print(f"FAIL: [{label}] {f}", file=sys.stderr)
    sys.exit(1)
PY
}
for pair in "all:$wf_all" "none:$wf_none"; do
  if check_structure "${pair#*:}" "${pair%%:*}"; then pass "structure (${pair%%:*})"; else fail "structure (${pair%%:*})"; fi
done

# Language setup (package installs) belongs to the format job only.
if grep -q 'npm ci' "$wf_all" && ! grep -q 'npm ci' "$wf_none"; then
  pass "language conditionals render"
else
  fail "language conditionals render"
fi

# --- Extract the push job's run scripts by step name. ---
extract_step() {
  python3 - "$wf_all" "$1" "$2" <<'PY'
import sys
import yaml

path, name, out = sys.argv[1:4]
steps = yaml.safe_load(open(path, encoding="utf-8"))["jobs"]["push"]["steps"]
match = [s for s in steps if s.get("name") == name]
if len(match) != 1 or "run" not in match[0]:
    sys.exit(f"push step {name!r} not found")
open(out, "w", encoding="utf-8").write(match[0]["run"])
PY
}
validate_sh="${SCRATCH}/validate-step.sh"
push_sh="${SCRATCH}/push-step.sh"
report_sh="${SCRATCH}/report-step.sh"
extract_step "Validate autofix patch" "$validate_sh" || fail "extract validate step"
extract_step "Commit and push autofix patch" "$push_sh" || fail "extract push step"
extract_step "Report fixes without pushing" "$report_sh" || fail "extract report step"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'test-formatters-autofix-template: %d passed, %d failed (stopping before behavior checks)\n' "$PASS" "$FAIL" >&2
  exit 1
fi
run_step() { # run_step <script> <runner_temp> [env...] — the shell GitHub uses for `run:`
  local script="$1" rt="$2"; shift 2
  (cd "${SCRATCH}/workspace" && env RUNNER_TEMP="$rt" GITHUB_STEP_SUMMARY="${rt}/summary" "$@" \
    bash --noprofile --norc -eo pipefail "$script")
}
mkdir -p "${SCRATCH}/workspace"

# --- Fixture: an origin repo with a PR branch. ---
origin="${SCRATCH}/origin.git"
seed="${SCRATCH}/seed"
git init -q --bare "$origin"
# Server-side hooks in the stand-in origin are not under test; keep them off.
git -C "$origin" config core.hooksPath /dev/null
git init -q "$seed"
mkdir -p "$seed/src" "$seed/.github/workflows" "$seed/.github/actions/setup"
printf 'a  =  1\n' >"$seed/src/app.txt"
printf 'runs:\n  using:  composite\n' >"$seed/.github/actions/setup/action.yml"
ln -s app.txt "$seed/src/link"
mkdir -p "$seed/.GitHub/Workflows"
printf 'on:  push\n' >"$seed/.GitHub/Workflows/odd.yml"
printf 'x\n' >"$seed/src/a"$'\n'"b"
printf '#!/bin/sh\necho hi\n' >"$seed/run.sh"
chmod +x "$seed/run.sh"
printf 'name: ci\non:  push\n' >"$seed/.github/workflows/ci.yml"
git -C "$seed" add -A
git -C "$seed" commit -q -m "base"
git -C "$seed" push -q "$origin" HEAD:refs/heads/main HEAD:refs/heads/feature
head_sha="$(git -C "$seed" rev-parse HEAD)"

# make_patch <name> <mutation...>: apply a mutation in a scratch clone and capture the
# patch the way the format job does (PATCH_FLAGS overrides it to craft other shapes).
# The patch lands where download-artifact puts it, and a staged copy where the
# validate step leaves it, so the push step can also be driven directly.
PROD_FLAGS="--no-color --no-ext-diff --no-textconv --no-renames --full-index"
make_patch() {
  local name="$1"; shift
  local wt="${SCRATCH}/mk-${name}" rt="${SCRATCH}/rt-${name}"
  git clone -q "$origin" "$wt"
  git -C "$wt" checkout -q "$head_sha"
  (cd "$wt" && eval "$*")
  git -C "$wt" add -A
  mkdir -p "${rt}/autofix-artifact"
  # shellcheck disable=SC2086 # word-splitting the flag list is intended
  git -C "$wt" diff --cached ${PATCH_FLAGS:-$PROD_FLAGS} >"${rt}/autofix-artifact/autofix.patch"
  cp "${rt}/autofix-artifact/autofix.patch" "${rt}/staged.patch"
  printf '%s\n' "$rt"
}
stage() { cp "${1}/staged.patch" "${1}/autofix.patch"; } # what the validate step leaves behind

expect_validate() { # expect_validate <label> <0|1> <runner_temp> [expected output substring]
  if run_step "$validate_sh" "$3" >"${SCRATCH}/out" 2>&1; then rc=0; else rc=1; fi
  if [[ "$rc" == "$2" ]] && { [[ -z "${4:-}" ]] || grep -qF -- "$4" "${SCRATCH}/out"; }; then
    pass "validate: $1"
  else
    fail "validate: $1 (exit $rc)"; sed 's/^/    /' "${SCRATCH}/out" >&2
  fi
}
rt_ok="$(make_patch ok "printf 'a = 1\n' > src/app.txt")"
expect_validate "accepts an in-place edit" 0 "$rt_ok"
expect_validate "refuses .github/workflows/" 1 "$(make_patch wf "printf 'name: ci\non: push\n' > .github/workflows/ci.yml")" "under .github/"
expect_validate "refuses mixed patch touching .github/workflows/" 1 \
  "$(make_patch wfmix "printf 'a = 1\n' > src/app.txt; printf 'name: ci\non: push\n' > .github/workflows/ci.yml")" "under .github/"
expect_validate "refuses .github/ outside workflows" 1 \
  "$(make_patch act "printf 'runs:\n  using: composite\n' > .github/actions/setup/action.yml")" "under .github/"
expect_validate "refuses a case-folded .GitHub/Workflows path" 1 \
  "$(make_patch wfcase "printf 'on: push\n' > .GitHub/Workflows/odd.yml")" "under .github/"
expect_validate "refuses a new workflow file" 1 "$(make_patch wfnew "printf 'on: push\n' > .github/workflows/new.yml")" "creates, deletes"
expect_validate "refuses a created file" 1 "$(make_patch new "printf 'x\n' > src/new.txt")" "creates, deletes"
expect_validate "refuses a deleted file" 1 "$(make_patch del "git rm -q src/app.txt")" "creates, deletes"
expect_validate "refuses a mode change" 1 "$(make_patch mode "chmod -x run.sh")" "creates, deletes"
expect_validate "refuses a rename" 1 "$(PATCH_FLAGS="--full-index -M" make_patch ren "git mv src/app.txt src/moved.txt")" "creates, deletes"
expect_validate "refuses a binary change" 1 "$(make_patch bin "printf 'a\0b' > src/app.txt")" "binary file"
expect_validate "refuses a symlink" 1 "$(make_patch sym "rm src/app.txt; ln -s ../run.sh src/app.txt")" "creates, deletes"
rt_empty="${SCRATCH}/rt-empty"; mkdir -p "${rt_empty}/autofix-artifact"; : >"${rt_empty}/autofix-artifact/autofix.patch"
expect_validate "refuses an empty patch" 1 "$rt_empty" "patch is empty"
expect_validate "refuses a missing patch" 1 "${SCRATCH}/rt-missing" "patch is missing"
expect_validate "refuses a newline in a file name" 1 \
  "$(make_patch nl "printf 'y\n' > src/a\$'\n'b")" "control characters"

# A hostile artifact directory (a .git with config, a planted numstat symlink) is ignored:
# only the patch file is copied out, and git runs from an empty directory.
rt_hostile="$(make_patch hostile "printf 'a = 1\n' > src/app.txt")"
git init -q "${rt_hostile}/autofix-artifact"
git -C "${rt_hostile}/autofix-artifact" config core.pager "touch ${SCRATCH}/hostile-ran"
ln -s "${SCRATCH}/hostile-victim" "${rt_hostile}/autofix-artifact/numstat"
expect_validate "ignores a hostile artifact directory" 0 "$rt_hostile" "accepted: 1 file"
if [[ ! -e "${SCRATCH}/hostile-victim" && ! -e "${SCRATCH}/hostile-ran" && ! -e "${rt_hostile}/autofix-artifact" ]]; then
  pass "validate: copies only the patch and drops the artifact directory"
else
  fail "validate: hostile artifact directory had an effect"
fi

# --- Push step end to end against the bare origin. ---
# Route the https remote the step builds to the local bare repo.
url_base="https://x-access-token:test-token@github.example/acme/widget.git"
push_env=(GITHUB_SERVER_URL=https://github.example GITHUB_REPOSITORY=acme/widget
  AUTOFIX_TOKEN=test-token PR_HEAD_REF=feature PR_HEAD_SHA="$head_sha"
  "AUTOFIX_SUBJECT=chore: apply format + lint --fix (autofix workflow)"
  GIT_CONFIG_COUNT=2 "GIT_CONFIG_KEY_0=url.${origin}.insteadOf" "GIT_CONFIG_VALUE_0=${url_base}"
  GIT_CONFIG_KEY_1=init.templateDir "GIT_CONFIG_VALUE_1=${SCRATCH}/git-template"
  GIT_CONFIG_GLOBAL="${SCRATCH}/gitconfig-hooks")

# Offer hooks two ways: an init template (copied into a new repository) and a global
# core.hooksPath. The step's --template= and its own core.hooksPath must stop both.
hook_marker="${SCRATCH}/hook-ran"
mkdir -p "${SCRATCH}/git-template/hooks"
for hook in pre-commit commit-msg post-commit pre-push reference-transaction; do
  printf '#!/bin/sh\necho %s >> "%s"\n' "$hook" "$hook_marker" >"${SCRATCH}/git-template/hooks/${hook}"
  chmod +x "${SCRATCH}/git-template/hooks/${hook}"
done
{ cat "$GIT_CONFIG_GLOBAL"; printf '[core]\n  hooksPath = %s\n' "${SCRATCH}/git-template/hooks"; } >"${SCRATCH}/gitconfig-hooks"
stage "$rt_ok"
if run_step "$push_sh" "$rt_ok" "${push_env[@]}" >"${SCRATCH}/out" 2>&1; then
  new_head="$(git -C "$origin" rev-parse refs/heads/feature)"
  if [[ "$new_head" != "$head_sha" ]] \
    && [[ "$(git -C "$origin" log -1 --format='%an <%ae>|%s' feature)" == "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>|chore: apply format + lint --fix (autofix workflow)" ]] \
    && [[ "$(git -C "$origin" show feature:src/app.txt)" == "a = 1" ]] \
    && [[ "$(git -C "$origin" rev-parse feature^)" == "$head_sha" ]]; then
    pass "push: commits the patch as github-actions[bot] on the PR head"
  else
    fail "push: unexpected result on origin"
  fi
else
  fail "push: step failed"; sed 's/^/    /' "${SCRATCH}/out" >&2
fi
if [[ "$(git -C "$origin" diff --name-status "$head_sha" feature)" == $'M\tsrc/app.txt' ]]; then
  pass "push: commit changes only the patched file"
else
  fail "push: commit changes unexpected files"
fi

if [[ ! -e "$hook_marker" ]]; then pass "push: no git hooks run"; else fail "push: hooks ran: $(tr '\n' ' ' <"$hook_marker")"; fi

# Loop guard: the PR head is now the autofix commit; a second patch is not pushed.
autofix_head="$(git -C "$origin" rev-parse refs/heads/feature)"
rt_loop="${SCRATCH}/rt-loop"; mkdir -p "$rt_loop"
cp "${rt_ok}/staged.patch" "${rt_loop}/autofix.patch"
loop_env=("${push_env[@]}"); loop_env[4]="PR_HEAD_SHA=${autofix_head}"
if run_step "$push_sh" "$rt_loop" "${loop_env[@]}" >"${SCRATCH}/out" 2>&1 \
  && [[ "$(git -C "$origin" rev-parse refs/heads/feature)" == "$autofix_head" ]] \
  && grep -q 'Lint autofix stopped' "${SCRATCH}/out"; then
  pass "push: loop guard stops a second autofix push"
else
  fail "push: loop guard"; sed 's/^/    /' "${SCRATCH}/out" >&2
fi

# Defense in depth: even if validation were bypassed, the push step re-checks the
# applied index and refuses .github/workflows/ without pushing.
git -C "$origin" update-ref refs/heads/feature "$head_sha"
rt_wf2="$(make_patch wf2 "printf 'name: ci\non: push\n' > .github/workflows/ci.yml")"
stage "$rt_wf2"
if run_step "$push_sh" "$rt_wf2" "${push_env[@]}" >"${SCRATCH}/out" 2>&1; then
  fail "push: re-check must refuse .github/workflows/"
elif [[ "$(git -C "$origin" rev-parse refs/heads/feature)" == "$head_sha" ]] \
  && grep -qF 'under .github/' "${SCRATCH}/out"; then
  pass "push: re-check refuses .github/workflows/ without pushing"
else
  fail "push: re-check on a workflow change"; sed 's/^/    /' "${SCRATCH}/out" >&2
fi

# A symlink retarget looks like a plain text edit to the validate step; the push
# step's index re-check must refuse it.
rt_sym2="$(make_patch symedit "ln -sfn ../run.sh src/link")"
expect_validate "passes a symlink retarget on to the re-check" 0 "$rt_sym2"
if run_step "$push_sh" "$rt_sym2" "${push_env[@]}" >"${SCRATCH}/out" 2>&1; then
  fail "push: re-check must refuse a symlink retarget"
elif [[ "$(git -C "$origin" rev-parse refs/heads/feature)" == "$head_sha" ]] \
  && grep -qF 'other than a regular file' "${SCRATCH}/out"; then
  pass "push: re-check refuses a symlink retarget without pushing"
else
  fail "push: symlink re-check"; sed 's/^/    /' "${SCRATCH}/out" >&2
fi

# Report-only path: no token, no push, warning plus job summary.
if run_step "$report_sh" "$rt_ok" >"${SCRATCH}/out" 2>&1 \
  && grep -q '::warning title=Lint autofix not pushed::' "${SCRATCH}/out" \
  && grep -q 'src/app.txt' "${rt_ok}/summary"; then
  pass "report: warns and writes the job summary"
else
  fail "report: missing warning or summary"; sed 's/^/    /' "${SCRATCH}/out" >&2
fi

# --- actionlint, when it is already installed. ---
if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$wf_all" "$wf_none" >"${SCRATCH}/out" 2>&1; then
    pass "actionlint"
  else
    fail "actionlint"; sed 's/^/    /' "${SCRATCH}/out" >&2
  fi
else
  echo "SKIP: actionlint not installed"
fi

printf 'test-formatters-autofix-template: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
