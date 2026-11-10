#!/usr/bin/env bash
# Backticks in single-quoted strings are literal Markdown code spans.
# shellcheck disable=SC2016
#
# Behavioral tests for the ycc release-model scripts:
#   ycc/skills/_shared/scripts/release-state.sh
#   ycc/skills/_shared/scripts/release-state-update.sh
#   ycc/skills/release-model/templates/RELEASING.md.tmpl
#
# Every test runs in throwaway git repos under a temp dir with an isolated git
# config, so the caller's repositories and global git settings are never used.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHARED="${REPO_ROOT}/ycc/skills/_shared/scripts"
STATE="${SHARED}/release-state.sh"
UPDATE="${SHARED}/release-state-update.sh"
TEMPLATE="${REPO_ROOT}/ycc/skills/release-model/templates/RELEASING.md.tmpl"

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
    echo "test-release-model: git did not resolve the sandbox repo; aborting" >&2
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
# release-state.sh get
# ---------------------------------------------------------------------------

test_get_missing() {
  local repo out rc
  repo="$(mkrepo)"
  out="$(bash "$STATE" --repo "$repo" get)"
  rc=$?
  assert_eq "$out" "present=0" "get: no RELEASING.md prints present=0"
  assert_exit "$rc" 0 "get: no RELEASING.md"
}

test_get_full() {
  local repo out
  repo="$(mkrepo)"
  write_releasing "$repo" "model: release-branches
trunk: master
maintenance: release/0.6 , release/0.5
frozen: release/0.4
tracker: linear-labels
tracker_ref: tokenhop release"
  out="$(bash "$STATE" --repo "$repo")"
  assert_eq "$(get_key "$out" present)" "1" "get: present=1"
  assert_eq "$(get_key "$out" model)" "release-branches" "get: model"
  assert_eq "$(get_key "$out" trunk)" "master" "get: trunk"
  assert_eq "$(get_key "$out" maintenance)" "release/0.6,release/0.5" "get: maintenance list normalized"
  assert_eq "$(get_key "$out" latest_maintenance)" "release/0.6" "get: latest_maintenance"
  assert_eq "$(get_key "$out" frozen)" "release/0.4" "get: frozen"
  assert_eq "$(get_key "$out" support)" "latest-minor" "get: support default"
  assert_eq "$(get_key "$out" backport_label)" "backport:{X.Y}" "get: backport_label default"
  assert_eq "$(get_key "$out" tracker)" "linear-labels" "get: tracker"
  assert_eq "$(get_key "$out" tracker_ref)" "tokenhop release" "get: tracker_ref with spaces"
  assert_eq "$(get_key "$out" file)" "${repo}/RELEASING.md" "get: file path"
}

test_get_key_order() {
  local repo keys
  repo="$(mkrepo)"
  write_releasing "$repo" "model: trunk-only
trunk: main"
  keys="$(bash "$STATE" --repo "$repo" | cut -d= -f1 | tr '\n' ' ')"
  assert_eq "$keys" "present file model trunk maintenance latest_maintenance frozen support backport_label tracker tracker_ref " "get: key order is stable"
}

test_get_trunk_only_minimal() {
  local repo out
  repo="$(mkrepo)"
  write_releasing "$repo" "model: trunk-only
trunk: main"
  out="$(bash "$STATE" --repo "$repo")"
  assert_eq "$(get_key "$out" maintenance)" "" "get: trunk-only has empty maintenance"
  assert_eq "$(get_key "$out" latest_maintenance)" "" "get: trunk-only has empty latest_maintenance"
  assert_eq "$(get_key "$out" tracker)" "none" "get: tracker default"
}

test_get_crlf() {
  local repo lf crlf
  repo="$(mkrepo)"
  write_releasing "$repo" "model: release-branches
trunk: main
maintenance: release/1.2"
  lf="$(bash "$STATE" --repo "$repo")"
  sed -i.bak 's/$/\r/' "${repo}/RELEASING.md" && rm -f "${repo}/RELEASING.md.bak"
  crlf="$(bash "$STATE" --repo "$repo")"
  assert_eq "$crlf" "$lf" "get: CRLF block parses identically to LF"
}

test_get_from_subdirectory() {
  local repo out
  repo="$(mkrepo)"
  mkdir -p "${repo}/src/deep"
  write_releasing "$repo" "model: trunk-only
trunk: main"
  out="$(cd "${repo}/src/deep" && bash "$STATE")"
  assert_eq "$(get_key "$out" present)" "1" "get: finds RELEASING.md from a subdirectory"
}

expect_malformed() {
  local name="$1" body="$2" needle="$3" repo out rc
  repo="$(mkrepo)"
  write_releasing "$repo" "$body"
  out="$(bash "$STATE" --repo "$repo" 2>&1)"
  rc=$?
  assert_exit "$rc" 2 "malformed: $name"
  assert_contains "$out" "$needle" "malformed: $name message"
}

test_get_malformed() {
  local repo out rc
  expect_malformed "unknown key" "model: trunk-only
trunk: main
flavour: vanilla" "unknown key 'flavour'"
  expect_malformed "missing trunk" "model: trunk-only" "missing required key 'trunk'"
  expect_malformed "missing model" "trunk: main" "missing required key 'model'"
  expect_malformed "invalid model" "model: weird
trunk: main" "invalid model 'weird'"
  expect_malformed "maintenance under trunk-only" "model: trunk-only
trunk: main
maintenance: release/0.5" "trunk-only cannot have maintenance"
  expect_malformed "bad maintenance entry" "model: release-branches
trunk: main
maintenance: hotfix" "not of the form release/X.Y"
  expect_malformed "duplicate key" "model: trunk-only
trunk: main
trunk: dev" "duplicate key 'trunk'"
  expect_malformed "not key: value" "model: trunk-only
trunk: main
just some words" "malformed line"
  expect_malformed "invalid tracker" "model: trunk-only
trunk: main
tracker: jira" "invalid tracker"
  expect_malformed "label without placeholder" "model: trunk-only
trunk: main
backport_label: backport" "must contain {X.Y}"

  repo="$(mkrepo)"
  printf '# Releasing\n\nHand-written, no block.\n' >"${repo}/RELEASING.md"
  out="$(bash "$STATE" --repo "$repo" 2>&1)"
  rc=$?
  assert_exit "$rc" 2 "malformed: RELEASING.md without a block"
  assert_contains "$out" "no ycc state block" "malformed: RELEASING.md without a block message"
  assert_contains "$out" "/ycc:release-model --audit" "malformed: message points at the audit"

  repo="$(mkrepo)"
  printf '# Releasing\n\n<!-- ycc-release-state\nmodel: trunk-only\ntrunk: main\n' >"${repo}/RELEASING.md"
  out="$(bash "$STATE" --repo "$repo" 2>&1)"
  rc=$?
  assert_exit "$rc" 2 "malformed: unclosed block"
}

test_get_comments_and_blank_lines() {
  local repo out
  repo="$(mkrepo)"
  write_releasing "$repo" "# comment line

model: trunk-only
trunk: main"
  out="$(bash "$STATE" --repo "$repo")"
  assert_eq "$(get_key "$out" model)" "trunk-only" "get: comment and blank lines ignored"
}

# ---------------------------------------------------------------------------
# release-state.sh base
# ---------------------------------------------------------------------------

test_base() {
  local repo out
  repo="$(mkrepo)"
  write_releasing "$repo" "model: release-branches
trunk: main
maintenance: release/0.5"
  git -C "$repo" add RELEASING.md
  git -C "$repo" commit -q -m "docs: add RELEASING.md"
  git -C "$repo" push -q origin main
  git -C "$repo" checkout -q -b release/0.5
  echo "patch" >"${repo}/patch.txt"
  git -C "$repo" add patch.txt
  git -C "$repo" commit -q -m "fix: release-only patch"
  git -C "$repo" push -q origin release/0.5
  git -C "$repo" checkout -q main
  echo "trunk" >"${repo}/trunk.txt"
  git -C "$repo" add trunk.txt
  git -C "$repo" commit -q -m "feat: trunk work"
  git -C "$repo" push -q origin main

  git -C "$repo" checkout -q -b feat/x main
  out="$(bash "$STATE" --repo "$repo" base)"
  assert_eq "$out" "main" "base: branch cut from the trunk -> trunk"

  git -C "$repo" checkout -q -b fix/y origin/release/0.5
  out="$(bash "$STATE" --repo "$repo" base)"
  assert_eq "$out" "release/0.5" "base: branch cut from release/0.5 -> release/0.5"

  out="$(bash "$STATE" --repo "$repo" base --head feat/x)"
  assert_eq "$out" "main" "base: --head selects the ref"
}

test_base_missing_file() {
  local repo out
  repo="$(mkrepo)"
  out="$(bash "$STATE" --repo "$repo" base)"
  assert_eq "$out" "main" "base: no RELEASING.md -> origin/HEAD branch"

  repo="$(mktemp -d "${SANDBOX_ROOT}/plain.XXXXXX")"
  git -C "$repo" init -q
  out="$(bash "$STATE" --repo "$repo" base)"
  assert_eq "$out" "main" "base: no origin at all -> main"
}

test_base_trunk_not_fetched() {
  local repo out
  repo="$(mktemp -d "${SANDBOX_ROOT}/nofetch.XXXXXX")"
  git -C "$repo" init -q
  write_releasing "$repo" "model: release-branches
trunk: develop
maintenance: release/2.0"
  out="$(bash "$STATE" --repo "$repo" base)"
  assert_eq "$out" "develop" "base: trunk not fetched -> state trunk, no error"
}

# ---------------------------------------------------------------------------
# release-state-update.sh
# ---------------------------------------------------------------------------

PROSE='## Notes

Human-owned prose.  Two spaces, trailing space here:
- a list item'

test_update_render_and_prose() {
  local repo before_prose after_prose out
  repo="$(mkrepo)"
  write_releasing "$repo" "model: release-branches
trunk: main
maintenance: release/0.5" "<!-- ycc-release-state:table:begin -->
stale table
<!-- ycc-release-state:table:end -->

${PROSE}"
  before_prose="$(sed -n '/^## Notes/,$p' "${repo}/RELEASING.md")"
  git -C "$repo" push -q origin main:refs/heads/release/0.5
  bash "$UPDATE" --repo "$repo" --render
  after_prose="$(sed -n '/^## Notes/,$p' "${repo}/RELEASING.md")"
  assert_eq "$after_prose" "$before_prose" "update: prose after the table is unchanged"
  out="$(cat "${repo}/RELEASING.md")"
  assert_contains "$out" '| Maintenance | `release/0.5` | Patches via `backport:0.5`' "update: render writes the maintenance row"
  if bash "$STATE" --repo "$repo" check >/dev/null 2>&1; then
    ok "update: check passes after render"
  else
    ko "update: check passes after render" "$(bash "$STATE" --repo "$repo" check 2>&1)"
  fi
}

test_update_inserts_missing_table() {
  local repo out
  repo="$(mkrepo)"
  write_releasing "$repo" "model: trunk-only
trunk: main" "${PROSE}"
  bash "$UPDATE" --repo "$repo" --render
  out="$(cat "${repo}/RELEASING.md")"
  assert_contains "$out" "<!-- ycc-release-state:table:begin -->" "update: missing table is inserted"
  assert_contains "$out" "Human-owned prose." "update: prose kept when inserting the table"
}

test_update_add_maintenance_window() {
  local repo out
  repo="$(mkrepo)"
  write_releasing "$repo" "model: release-branches
trunk: main
maintenance: release/0.5"
  bash "$UPDATE" --repo "$repo" --add-maintenance release/0.6
  out="$(bash "$STATE" --repo "$repo")"
  assert_eq "$(get_key "$out" maintenance)" "release/0.6" "update: latest-minor keeps one maintenance branch"
  assert_eq "$(get_key "$out" frozen)" "release/0.5" "update: previous branch moves to frozen"

  write_releasing "$repo" "model: release-branches
trunk: main
maintenance: release/0.5
support: latest-two-minors"
  bash "$UPDATE" --repo "$repo" --add-maintenance release/0.6
  bash "$UPDATE" --repo "$repo" --add-maintenance release/0.7
  out="$(bash "$STATE" --repo "$repo")"
  assert_eq "$(get_key "$out" maintenance)" "release/0.7,release/0.6" "update: latest-two-minors keeps two"
  assert_eq "$(get_key "$out" frozen)" "release/0.5" "update: third branch moves to frozen"
}

test_update_ops() {
  local repo out rc
  repo="$(mkrepo)"
  write_releasing "$repo" "model: release-branches
trunk: main
maintenance: release/0.6,release/0.5
support: latest-two-minors"
  bash "$UPDATE" --repo "$repo" --freeze release/0.5
  out="$(bash "$STATE" --repo "$repo")"
  assert_eq "$(get_key "$out" maintenance)" "release/0.6" "update: freeze removes from maintenance"
  assert_eq "$(get_key "$out" frozen)" "release/0.5" "update: freeze adds to frozen"

  bash "$UPDATE" --repo "$repo" --set-trunk develop
  out="$(bash "$STATE" --repo "$repo")"
  assert_eq "$(get_key "$out" trunk)" "develop" "update: set-trunk"

  bash "$UPDATE" --repo "$repo" --set-model trunk-only >/dev/null 2>&1
  rc=$?
  assert_exit "$rc" 1 "update: trunk-only refused while maintenance branches exist"

  write_releasing "$repo" "model: trunk-only
trunk: main"
  bash "$UPDATE" --repo "$repo" --add-maintenance release/1.0 >/dev/null 2>&1
  rc=$?
  assert_exit "$rc" 1 "update: add-maintenance refused under trunk-only"

  bash "$UPDATE" --repo "$repo" --set-model release-branches
  bash "$UPDATE" --repo "$repo" --add-maintenance release/1.0
  out="$(bash "$STATE" --repo "$repo")"
  assert_eq "$(get_key "$out" maintenance)" "release/1.0" "update: upgrade then add-maintenance"
}

test_update_dry_run() {
  local repo before after out
  repo="$(mkrepo)"
  write_releasing "$repo" "model: release-branches
trunk: main
maintenance: release/0.5"
  before="$(cat "${repo}/RELEASING.md")"
  out="$(bash "$UPDATE" --repo "$repo" --dry-run --add-maintenance release/0.6)"
  after="$(cat "${repo}/RELEASING.md")"
  assert_eq "$after" "$before" "update: --dry-run leaves the file unchanged"
  assert_contains "$out" "+maintenance: release/0.6" "update: --dry-run prints a diff"
}

test_update_crlf_preserved() {
  local repo
  repo="$(mkrepo)"
  write_releasing "$repo" "model: trunk-only
trunk: main" "${PROSE}"
  sed -i.bak 's/$/\r/' "${repo}/RELEASING.md" && rm -f "${repo}/RELEASING.md.bak"
  bash "$UPDATE" --repo "$repo" --render
  if grep -qv $'\r$' "${repo}/RELEASING.md"; then
    ko "update: CRLF file stays CRLF"
  else
    ok "update: CRLF file stays CRLF"
  fi
}

test_update_errors() {
  local repo rc
  repo="$(mkrepo)"
  bash "$UPDATE" --repo "$repo" --render >/dev/null 2>&1
  rc=$?
  assert_exit "$rc" 1 "update: no RELEASING.md"
  printf '# Releasing\n' >"${repo}/RELEASING.md"
  bash "$UPDATE" --repo "$repo" --render >/dev/null 2>&1
  rc=$?
  assert_exit "$rc" 2 "update: malformed state"
  bash "$UPDATE" --repo "$repo" --render --freeze release/1.0 >/dev/null 2>&1
  rc=$?
  assert_exit "$rc" 1 "update: two ops rejected"
}

test_print_block() {
  local out
  out="$(bash "$UPDATE" --print-block --model trunk-only --trunk main)"
  assert_contains "$out" "<!-- ycc-release-state" "print-block: prints a block"
  assert_contains "$out" "| Trunk | \`main\` |" "print-block: prints the table"
}

# ---------------------------------------------------------------------------
# release-state.sh check
# ---------------------------------------------------------------------------

test_check() {
  local repo out rc
  repo="$(mkrepo)"
  write_releasing "$repo" "model: release-branches
trunk: main
maintenance: release/0.5"
  bash "$UPDATE" --repo "$repo" --render
  out="$(bash "$STATE" --repo "$repo" check 2>&1)"
  rc=$?
  assert_exit "$rc" 1 "check: missing release/0.5 on origin is a finding"
  assert_contains "$out" "branch 'release/0.5'" "check: names the missing branch"

  git -C "$repo" push -q origin main:refs/heads/release/0.5
  out="$(bash "$STATE" --repo "$repo" check 2>&1)"
  rc=$?
  assert_exit "$rc" 0 "check: clean state"

  sed -i.bak 's/Patches via/Fixes via/' "${repo}/RELEASING.md" && rm -f "${repo}/RELEASING.md.bak"
  out="$(bash "$STATE" --repo "$repo" check 2>&1)"
  rc=$?
  assert_exit "$rc" 1 "check: hand-edited table is a finding"
  assert_contains "$out" "does not match the state block" "check: table drift message"
}

# ---------------------------------------------------------------------------
# prettier keeps the rendered table stable (skipped when prettier is absent)
# ---------------------------------------------------------------------------

test_prettier_stable() {
  local repo prettier
  prettier="${REPO_ROOT}/node_modules/.bin/prettier"
  if [[ ! -x "$prettier" ]]; then
    echo "[skip] prettier not installed; table formatting check skipped"
    return 0
  fi
  repo="$(mkrepo)"
  write_releasing "$repo" "model: release-branches
trunk: master
maintenance: release/0.6
frozen: release/0.5, release/0.4"
  bash "$UPDATE" --repo "$repo" --render
  if "$prettier" --check "${repo}/RELEASING.md" >/dev/null 2>&1; then
    ok "prettier: rendered RELEASING.md is already formatted"
  else
    ko "prettier: rendered RELEASING.md is already formatted" "$("$prettier" "${repo}/RELEASING.md" | diff "${repo}/RELEASING.md" - | head -20)"
  fi
}

# ---------------------------------------------------------------------------
# RELEASING.md template renders into a valid state (Task 1.4)
# ---------------------------------------------------------------------------

# render_template <model> <out> — minimal renderer for the template's
# placeholders and conditional blocks (the skill does this with the model).
render_template() {
  local model="$1" out="$2" block keep drop
  block="$(bash "$UPDATE" --print-block --model "$model" --trunk main | sed '/^$/,$d')"
  if [[ "$model" == "release-branches" ]]; then
    keep="IF_RELEASE_BRANCHES"
    drop="IF_TRUNK_ONLY"
  else
    keep="IF_TRUNK_ONLY"
    drop="IF_RELEASE_BRANCHES"
  fi
  awk -v keep="$keep" -v drop="$drop" -v block="$block" '
    $0 ~ "^\\{\\{#" drop "\\}\\}$" { skipping = 1; next }
    $0 ~ "^\\{\\{/" drop "\\}\\}$" { skipping = 0; next }
    $0 ~ "^\\{\\{[#/]" keep "\\}\\}$" { next }
    skipping { next }
    $0 == "{{STATE_BLOCK}}" { print block; next }
    { print }
  ' "$TEMPLATE" | sed \
    -e 's/{{PROJECT_NAME}}/demo/g' \
    -e 's/{{TRUNK}}/main/g' \
    -e 's/{{TAG_PATTERN}}/v*/g' \
    -e 's/{{VERSION_FILES}}/`package.json`/g' \
    -e 's/{{CHANGELOG_FILE}}/`CHANGELOG.md`/g' \
    -e 's/{{PUBLISH_STEP}}/The publish workflow runs on the tag./g' \
    -e 's/{{TRACKER_SECTION}}/Targets are GitHub milestones./g' >"$out"
}

test_template() {
  local repo model out leftover
  if [[ ! -f "$TEMPLATE" ]]; then
    ko "template: RELEASING.md.tmpl exists"
    return
  fi
  for model in trunk-only release-branches; do
    repo="$(mkrepo)"
    render_template "$model" "${repo}/RELEASING.md"
    bash "$UPDATE" --repo "$repo" --render
    out="$(bash "$STATE" --repo "$repo" 2>&1)"
    assert_eq "$(get_key "$out" model)" "$model" "template: renders a valid $model state"
    leftover="$(grep -o '{{[^}]*}}' "${repo}/RELEASING.md" | sort -u | tr '\n' ' ')"
    assert_eq "$leftover" "" "template: no placeholders left for $model"
  done
  if grep -q "Backporting" "${repo}/RELEASING.md"; then
    ok "template: release-branches includes the backporting section"
  else
    ko "template: release-branches includes the backporting section"
  fi
}

# ---------------------------------------------------------------------------

# Generated Cursor/Codex/opencode/OMP copies must parse the same files as the
# source: the generators rewrite ycc:<name> and /ycc:<name> references.
test_generated_copies() {
  local copy repo out rc
  for copy in \
    "${REPO_ROOT}/packages/cursor/ycc/skills/_shared/scripts/release-state.sh" \
    "${REPO_ROOT}/.codex-plugin/ycc/shared/scripts/release-state.sh" \
    "${REPO_ROOT}/.opencode-plugin/shared/scripts/release-state.sh" \
    "${REPO_ROOT}/packages/omp/ycc/skills/_shared/scripts/release-state.sh"; do
    if [[ ! -f "$copy" ]]; then
      ko "generated copy exists: ${copy#"${REPO_ROOT}/"}" "run ./scripts/sync.sh"
      continue
    fi
    repo="$(mkrepo)"
    bash "$UPDATE" --print-block --model release-branches --trunk main | sed '/^$/,$d' >"${repo}/RELEASING.md"
    out="$(bash "$copy" --repo "$repo" 2>&1)"
    assert_eq "$(get_key "$out" model)" "release-branches" "generated copy parses the source format: ${copy#"${REPO_ROOT}/"}"
    printf '# Releasing\n' >"${repo}/RELEASING.md"
    out="$(bash "$copy" --repo "$repo" 2>&1)"
    rc=$?
    assert_exit "$rc" 2 "generated copy reports a malformed block: ${copy#"${REPO_ROOT}/"}"
    assert_contains "$out" "no ycc state block" "generated copy prints the parse error: ${copy#"${REPO_ROOT}/"}"
  done
}

test_get_missing
test_get_full
test_get_key_order
test_get_trunk_only_minimal
test_get_crlf
test_get_from_subdirectory
test_get_malformed
test_get_comments_and_blank_lines
test_base
test_base_missing_file
test_base_trunk_not_fetched
test_update_render_and_prose
test_update_inserts_missing_table
test_update_add_maintenance_window
test_update_ops
test_update_dry_run
test_update_crlf_preserved
test_update_errors
test_print_block
test_check
test_prettier_stable
test_template
test_generated_copies

echo
echo "release-model tests: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
