#!/usr/bin/env bash
# Isolated portable-pointer and bundle-parity regressions.
set -euo pipefail
export BASH_BIN=${BASH_BIN:-bash}
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)"
HELPER="${SCRIPT_DIR}/../ycc/skills/_shared/scripts/artifact-store-pointer.sh"
VALIDATOR="${SCRIPT_DIR}/validate-artifact-store.sh"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/ycc-artifact-pointer.XXXXXX")
SCRATCH=$(CDPATH='' cd -- "$SCRATCH" >/dev/null && pwd -P)
trap 'rm -rf "$SCRATCH"' EXIT
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
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*" >&2; }
assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi
}
assert_ok() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi }
assert_not() { local label="$1"; shift; if "$@"; then fail "$label"; else pass "$label"; fi }
expect_exit() {
  local label="$1" expected="$2" status=0; shift 2
  "$@" >"${SCRATCH}/out" 2>"${SCRATCH}/err" || status=$?
  assert_eq "$label" "$expected" "$status"
}
make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" commit -q --allow-empty -m init
}
linear() { "$BASH_BIN" "$HELPER" --store=linear --linear-workspace=yandy-r --linear-team=YAN --linear-label=repo:ystack "$@"; }
repo="${SCRATCH}/repo with spaces"; make_repo "$repo"
printf 'unrelated\n' >"${repo}/staged"
git -C "$repo" add staged
expect_exit 'create Linear pointer and commit' 0 linear "$repo"
assert_ok 'machine pointer result' grep -qx "pointer=${repo}/.plans-config" "${SCRATCH}/out"
assert_eq 'commit contains only pointer paths' $'.gitignore\n.plans-config' "$(git -C "$repo" show --pretty= --name-only HEAD)"
assert_eq 'other staged path stays staged' staged "$(git -C "$repo" diff --cached --name-only)"
assert_ok 'other staged path is uncommitted' test -z "$(git -C "$repo" ls-tree HEAD -- staged)"
assert_eq 'portable ignore rule' '.ycc/artifacts/' "$(cat "${repo}/.gitignore")"
head_before=$(git -C "$repo" rev-parse HEAD)
expect_exit 'idempotent rerun' 0 linear "$repo"
assert_ok 'unchanged result' grep -qx 'pointer_change=unchanged' "${SCRATCH}/out"
assert_ok 'nothing to commit result' grep -qx 'commit=none' "${SCRATCH}/out"
assert_eq 'idempotence keeps HEAD' "$head_before" "$(git -C "$repo" rev-parse HEAD)"
preserve="${SCRATCH}/preserve"; make_repo "$preserve"
printf '# original comment\nplans_dir: custom plans\nstore: local # keep this\nextra: unchanged\n' >"${preserve}/.plans-config"
expect_exit 'conflicting store refuses' 3 linear "$preserve"
assert_ok 'conflict names key and old/new values' grep -q 'store: local -> linear' "${SCRATCH}/err"
expect_exit 'force changes store' 0 linear --force --no-commit "$preserve"
assert_eq 'unrelated keys and comments preserved' $'# original comment\nplans_dir: custom plans\nstore: linear # keep this\nextra: unchanged\nlinear_workspace: yandy-r\nlinear_team: YAN\nlinear_label: repo:ystack' "$(cat "${preserve}/.plans-config")"
expect_exit 'label and project conflict' 2 linear --linear-project=project "$repo"
expect_exit 'Linear without team refuses' 2 "$BASH_BIN" "$HELPER" --store=linear --linear-workspace=w --linear-label=l "$repo"
mkdir "${SCRATCH}/outside"
expect_exit 'outside Git refuses' 2 linear "${SCRATCH}/outside"
for path in .plans-config .gitignore .ycc; do
  fixture="${SCRATCH}/symlink-${path}"; make_repo "$fixture"
  ln -s "${SCRATCH}/outside" "${fixture}/${path}"
  expect_exit "symlinked ${path} refuses" 2 linear "$fixture"
done
# shellcheck disable=SC2016  # literal $ and quotes are the invalid payloads
for option in --unknown --store=broken '--linear-team=lower' '--linear-workspace=' '--linear-label=:bad' '--linear-label=repo#1' '--linear-label=bad value' "--linear-label=q'uote" '--linear-workspace=bad\nvalue' '--linear-label=foo$bar'; do
  expect_exit "invalid option ${option}" 2 linear "$option" "$repo"
done
edited="${SCRATCH}/edited-ignore"; make_repo "$edited"
printf '# baseline\n' >"${edited}/.gitignore"
git -C "$edited" add .gitignore; git -C "$edited" commit -qm baseline
printf 'unrelated-rule\n' >>"${edited}/.gitignore"
expect_exit 'unrelated ignore edits do not enter commit' 0 linear "$edited"
assert_eq 'only pointer committed with dirty ignore' .plans-config "$(git -C "$edited" show --pretty= --name-only HEAD)"
assert_ok 'dirty ignore warns' grep -q 'WARNING: .gitignore has unrelated changes' "${SCRATCH}/err"
assert_ok 'unrelated ignore remains modified' test -n "$(git -C "$edited" diff -- .gitignore)"
# Contract 2: values outside the safe charset are rejected before any write.
charset="${SCRATCH}/charset"; make_repo "$charset"
expect_exit 'label with hash refuses' 2 linear --linear-label='repo#1' "$charset"
expect_exit 'label with quote refuses' 2 linear "--linear-label=$(printf 'q'"'"'uote')" "$charset"
assert_ok 'rejected value writes no pointer' test ! -e "${charset}/.plans-config"
expect_exit 'accepted charset value passes' 0 linear --linear-label='A0._:/@+-z' "$charset"
assert_ok 'safe charset value written' grep -qx 'linear_label: A0._:/@+-z' "${charset}/.plans-config"
# Contract 3: label <-> project switch is an explicit conflict.
switch="${SCRATCH}/switch"; make_repo "$switch"
expect_exit 'project mapping written' 0 "$BASH_BIN" "$HELPER" --store=linear --linear-workspace=yandy-r --linear-team=YAN --linear-project=p-id --no-commit "$switch"
assert_ok 'project key present' grep -qx 'linear_project: p-id' "${switch}/.plans-config"
expect_exit 'switching project to label refuses' 3 linear "$switch"
assert_ok 'switch refusal names mapping' grep -q 'linear_project mapping' "${SCRATCH}/err"
expect_exit 'forced switch removes project key' 0 linear --force --no-commit "$switch"
assert_not 'project key removed' grep -q '^linear_project' "${switch}/.plans-config"
assert_ok 'switch fixture workspace intact' grep -qx 'linear_workspace: yandy-r' "${switch}/.plans-config"
expect_exit 'switching label to project refuses' 3 "$BASH_BIN" "$HELPER" --store=linear --linear-workspace=yandy-r --linear-team=YAN --linear-project=p2 "$switch"
expect_exit 'forced label-to-project removes label' 0 "$BASH_BIN" "$HELPER" --store=linear --linear-workspace=yandy-r --linear-team=YAN --linear-project=p2 --force --no-commit "$switch"
assert_not 'label key removed by force' grep -q '^linear_label' "${switch}/.plans-config"
# Contract 4: an ignored pointer is refused before any write, for both stores.
ignored_local="${SCRATCH}/ignored-local"; make_repo "$ignored_local"
printf '.plans-config\n' >"${ignored_local}/.gitignore"
git -C "$ignored_local" add .gitignore; git -C "$ignored_local" commit -qm ignore-baseline
expect_exit 'ignored pointer with local store refuses' 4 "$BASH_BIN" "$HELPER" --store=local "$ignored_local"
assert_ok 'local refusal explains ignore' grep -q 'committed artifact-store pointer cannot be ignored' "${SCRATCH}/err"
assert_ok 'local refusal keeps gitignore' test -z "$(git -C "$ignored_local" status --porcelain --untracked-files=all)"
assert_ok 'local refusal writes no pointer' test ! -e "${ignored_local}/.plans-config"
ignored="${SCRATCH}/ignored"; make_repo "$ignored"
printf '.plans-config\n' >"${ignored}/.gitignore"
git -C "$ignored" add .gitignore; git -C "$ignored" commit -qm ignore-baseline
expect_exit 'ignored pointer refuses' 4 linear "$ignored"
assert_ok 'ignored pointer explains committed requirement' grep -q 'committed artifact-store pointer cannot be ignored' "${SCRATCH}/err"
assert_ok 'linear refusal writes no pointer' test ! -e "${ignored}/.plans-config"
assert_ok 'linear refusal leaves ignore bytes' test -z "$(git -C "$ignored" status --porcelain --untracked-files=all)"
crlf="${SCRATCH}/crlf"; make_repo "$crlf"
printf 'store: local\r\nplans_dir: docs/plans\r\n' >"${crlf}/.plans-config"
git -C "$crlf" add .plans-config; git -C "$crlf" commit -qm crlf-baseline
expect_exit 'CRLF pointer refuses' 2 linear "$crlf"
assert_ok 'CRLF refusal names LF conversion' grep -q 'convert .plans-config to LF line endings' "${SCRATCH}/err"
assert_ok 'CRLF refusal keeps bytes' test -z "$(git -C "$crlf" status --porcelain --untracked-files=all)"
dry="${SCRATCH}/dry"; make_repo "$dry"
printf '# no final newline' >"${dry}/.plans-config"
printf 'other-rule' >"${dry}/.gitignore"
git -C "$dry" add .; git -C "$dry" commit -qm baseline
cp "${dry}/.plans-config" "${SCRATCH}/pointer-before"; cp "${dry}/.gitignore" "${SCRATCH}/ignore-before"
cp "${dry}/.git/index" "${SCRATCH}/index-before"
head_before=$(git -C "$dry" rev-parse HEAD)
expect_exit 'dry run succeeds' 0 linear --dry-run "$dry"
assert_ok 'dry run preserves pointer bytes' cmp -s "${SCRATCH}/pointer-before" "${dry}/.plans-config"
assert_ok 'dry run prints planned delimiter' grep -qx -- '--- .plans-config (planned) ---' "${SCRATCH}/out"
assert_ok 'dry run preserves ignore bytes' cmp -s "${SCRATCH}/ignore-before" "${dry}/.gitignore"
assert_eq 'dry run preserves HEAD' "$head_before" "$(git -C "$dry" rev-parse HEAD)"
assert_ok 'dry run creates no cache' test ! -e "${dry}/.ycc"
# Contract 6: identical values with no final newline stay unchanged.
nonl="${SCRATCH}/no-newline"; make_repo "$nonl"
printf 'store: linear\nlinear_workspace: yandy-r\nlinear_team: YAN\nlinear_label: repo:ystack' >"${nonl}/.plans-config"
git --literal-pathspecs -C "$nonl" add -- .plans-config
git -C "$nonl" commit -qm baseline
head_before=$(git -C "$nonl" rev-parse HEAD)
expect_exit 'missing final newline idempotent' 0 linear "$nonl"
assert_ok 'no-newline rerun unchanged' grep -qx 'pointer_change=unchanged' "${SCRATCH}/out"
assert_not 'no-newline rerun no pointer commit' grep -qx 'commit=none' "${SCRATCH}/out"
assert_ok 'no-newline rerun keeps bytes' grep -q 'repo:ystack' "${nonl}/.plans-config"
assert_ok 'no-newline rerun keeps missing final newline' test "$(tail -c 2 "${nonl}/.plans-config" | od -An -c | tr -d ' \n')" = 'ck'
assert_ok 'no-newline rerun commits ignore only' test "$(git -C "$nonl" show --pretty= --name-only HEAD)" == .gitignore
expect_exit 'missing newline changed team conflicts' 3 "$BASH_BIN" "$HELPER" --store=linear --linear-workspace=yandy-r --linear-team=ZAN --linear-label=repo:ystack --no-commit "${nonl}"
expect_exit 'missing newline forced team change writes' 0 "$BASH_BIN" "$HELPER" --store=linear --linear-workspace=yandy-r --linear-team=ZAN --linear-label=repo:ystack --force --no-commit "${nonl}"
assert_ok 'forced team change gains newline' grep -qx 'linear_team: ZAN' "${nonl}/.plans-config"
# Contract 5: pre-existing .plans-config edits preserve the commit boundary.
dirty="${SCRATCH}/dirty-pointer"; make_repo "$dirty"
printf 'plans_dir: docs/plans\n' >"${dirty}/.plans-config"
git -C "$dirty" add .plans-config; git -C "$dirty" commit -qm baseline
printf 'plans_dir: WIP-unrelated\n' >"${dirty}/.plans-config"
head_before=$(git -C "$dirty" rev-parse HEAD)
expect_exit 'dirty pointer still written' 0 linear "$dirty"
assert_ok 'dirty pointer warns' grep -q 'pre-existing uncommitted changes' "${SCRATCH}/err"
assert_ok 'dirty pointer skips commit' grep -qx 'commit=skipped' "${SCRATCH}/out"
assert_eq 'dirty pointer keeps HEAD' "$head_before" "$(git -C "$dirty" rev-parse HEAD)"
assert_ok 'dirty pointer wrote store' grep -qx 'store: linear' "${dirty}/.plans-config"
assert_ok 'dirty pointer keeps WIP value' grep -qx 'plans_dir: WIP-unrelated' "${dirty}/.plans-config"
staged="${SCRATCH}/staged-pointer"; make_repo "$staged"
printf 'plans_dir: docs/plans\n' >"${staged}/.plans-config"
printf 'plans_dir: staged-value\n' >"${SCRATCH}/staged-blob"
git -C "$staged" hash-object -w --stdin <"${SCRATCH}/staged-blob" >/dev/null
git -C "$staged" update-index --add --cacheinfo 100644,"$(git -C "$staged" hash-object -w --stdin <"${SCRATCH}/staged-blob")",.plans-config
head_before=$(git -C "$staged" rev-parse HEAD)
expect_exit 'staged-only pointer edits skip commit' 0 linear "$staged"
assert_ok 'staged-only edits skip commit' grep -qx 'commit=skipped' "${SCRATCH}/out"
assert_eq 'staged-only edits keep HEAD' "$head_before" "$(git -C "$staged" rev-parse HEAD)"
assert_ok 'pointer written despite staged edits' grep -qx 'store: linear' "${staged}/.plans-config"
hook="${SCRATCH}/hook"; make_repo "$hook"
printf '#!/bin/sh\necho intentional-hook-failure >&2\nexit 1\n' >"${hook}/.git/hooks/pre-commit"
chmod +x "${hook}/.git/hooks/pre-commit"
head_before=$(git -C "$hook" rev-parse HEAD)
expect_exit 'failing hook is not bypassed' 5 linear "$hook"
assert_ok 'Git hook error is visible' grep -q intentional-hook-failure "${SCRATCH}/err"
assert_eq 'failed hook leaves HEAD' "$head_before" "$(git -C "$hook" rev-parse HEAD)"
assert_ok 'failed hook leaves pointer written' test -f "${hook}/.plans-config"
assert_ok 'failed hook unstages pointer paths' test -z "$(git -C "$hook" diff --cached --name-only)"
local_repo="${SCRATCH}/local"; make_repo "$local_repo"
expect_exit 'local pointer commit' 0 "$BASH_BIN" "$HELPER" --store=local "$local_repo"
assert_eq 'local commit message' 'chore(ycc): configure local artifact store' "$(git -C "$local_repo" log -1 --pretty=%s)"
assert_ok 'local creates no ignore' test ! -e "${local_repo}/.gitignore"
# Validator fixtures need no bundle trees; absent trees intentionally skip.
fixture="${SCRATCH}/validator"; make_repo "$fixture"
printf 'store: linear\n' >"${fixture}/.plans-config"
expect_exit 'validator rejects untracked Linear pointer' 1 "$BASH_BIN" "$VALIDATOR" "$fixture"
git -C "$fixture" add .plans-config
expect_exit 'validator accepts tracked Linear pointer' 0 "$BASH_BIN" "$VALIDATOR" "$fixture"
printf '.plans-config\n' >"${fixture}/.gitignore"
expect_exit 'validator rejects ignored tracked pointer' 1 "$BASH_BIN" "$VALIDATOR" "$fixture"
rm "${fixture}/.gitignore"
mkdir -p "${fixture}/nested"
printf 'store: local\n' >"${fixture}/nested/.plans-config"
expect_exit 'validator accepts untracked local pointer' 0 "$BASH_BIN" "$VALIDATOR" "$fixture"
printf 'store: linear\n' >"${fixture}/nested/.plans-config"
printf 'nested/\n' >"${fixture}/.gitignore"
expect_exit 'validator discovers ignored untracked pointers' 1 "$BASH_BIN" "$VALIDATOR" "$fixture"
rm -rf "${fixture}/nested" "${fixture}/.gitignore"
mkdir -p "${fixture}/.omp/worktrees/other"
printf 'store: linear\n' >"${fixture}/.omp/worktrees/other/.plans-config"
expect_exit 'validator skips nested runtime worktrees' 0 "$BASH_BIN" "$VALIDATOR" "$fixture"
mkdir -p "${fixture}/ycc/skills/example" "${fixture}/packages/omp/ycc/skills/example"
printf '.ycc/artifacts/ .plans-config\n' >"${fixture}/ycc/skills/example/SKILL.md"
cp "${fixture}/ycc/skills/example/SKILL.md" "${fixture}/packages/omp/ycc/skills/example/SKILL.md"
expect_exit 'validator accepts equal bundle paths' 0 "$BASH_BIN" "$VALIDATOR" "$fixture"
printf 'rewritten/artifacts/ .plans-config\n' >"${fixture}/packages/omp/ycc/skills/example/SKILL.md"
expect_exit 'validator rejects rewritten bundle paths' 1 "$BASH_BIN" "$VALIDATOR" "$fixture"
assert_ok 'parity failure names rewritten file' grep -q 'packages/omp/ycc/skills/example/SKILL.md' "${SCRATCH}/err"
# Parity extends to the exported shared trees beside the skills trees.
rm -rf "${fixture}/packages/omp"
mkdir -p "${fixture}/.codex-plugin/ycc/shared/references" "${fixture}/ycc/skills/_shared/references"
printf '.ycc/artifacts/ .plans-config\n' >"${fixture}/.codex-plugin/ycc/shared/references/artifact-store.md"
printf '.ycc/artifacts/ .plans-config\n' >"${fixture}/ycc/skills/_shared/references/artifact-store.md"
expect_exit 'validator compares exported shared references' 0 "$BASH_BIN" "$VALIDATOR" "$fixture"
printf '.codex/artifacts/ .codex-config\n' >"${fixture}/.codex-plugin/ycc/shared/references/artifact-store.md"
expect_exit 'validator rejects rewritten shared references' 1 "$BASH_BIN" "$VALIDATOR" "$fixture"
assert_ok 'shared parity failure names file' grep -q '.codex-plugin/ycc/shared/references/artifact-store.md' "${SCRATCH}/err"
# A generated helper copy with a syntax error or dropped flags fails parity.
rm -rf "${fixture}/.codex-plugin"
mkdir -p "${fixture}/.opencode-plugin/shared/scripts" "${fixture}/packages/opencode/ycc-opencode/skills/example" "${fixture}/ycc/skills/_shared/scripts"
cp "$HELPER" "${fixture}/ycc/skills/_shared/scripts/artifact-store-pointer.sh"
cp "${fixture}/ycc/skills/example/SKILL.md" "${fixture}/packages/opencode/ycc-opencode/skills/example/SKILL.md"
printf '.ycc/artifacts/ .plans-config\n' >"${fixture}/packages/opencode/ycc-opencode/skills/example/SKILL.md"
expect_exit 'validator accepts intact helper copy' 0 "$BASH_BIN" "$VALIDATOR" "$fixture"
printf 'syntax error(\n' >>"${fixture}/.opencode-plugin/shared/scripts/artifact-store-pointer.sh"
expect_exit 'validator rejects helper syntax error' 1 "$BASH_BIN" "$VALIDATOR" "$fixture"
assert_ok 'syntax failure names helper copy' grep -q '.opencode-plugin/shared/scripts/artifact-store-pointer.sh' "${SCRATCH}/err"
cp "$HELPER" "${fixture}/.opencode-plugin/shared/scripts/artifact-store-pointer.sh"
grep -v -- '--linear-label' "$HELPER" >"${fixture}/.opencode-plugin/shared/scripts/artifact-store-pointer.sh"
expect_exit 'validator rejects dropped linear flags' 1 "$BASH_BIN" "$VALIDATOR" "$fixture"
assert_ok 'flag-count failure names helper copy' grep -q -- '--linear- occurrences' "${SCRATCH}/err"
# Bracketed paths are literal names, not globs, for tracked checks.
rm -rf "${fixture}/.opencode-plugin" "${fixture}/packages/opencode"
bracket="${SCRATCH}/bracket"; make_repo "$bracket"
mkdir -p "${bracket}/a1"
printf 'store: local\n' >"${bracket}/a1/.plans-config"
git -C "$bracket" add a1/.plans-config; git -C "$bracket" commit -qm baseline
mkdir -p "${bracket}/a[1]"
printf 'store: linear\n' >"${bracket}/a[1]/.plans-config"
expect_exit 'bracket path untracked Linear pointer fails' 1 "$BASH_BIN" "$VALIDATOR" "$bracket"
git --literal-pathspecs -C "$bracket" add -- 'a[1]/.plans-config'
expect_exit 'bracket path tracked pointer passes' 0 "$BASH_BIN" "$VALIDATOR" "$bracket"
project_repo="${SCRATCH}/project"; make_repo "$project_repo"
mkdir -p "${project_repo}/nested"
ln -s "$project_repo" "${SCRATCH}/project-link"
printf '# baseline without newline' >"${project_repo}/.gitignore"
git -C "$project_repo" add .gitignore; git -C "$project_repo" commit -qm baseline
expect_exit 'project mapping accepts nested symlink directory' 0 "$BASH_BIN" "$HELPER" --store=linear --linear-workspace=w --linear-team=A --linear-project=project-id "${SCRATCH}/project-link/nested"
assert_ok 'pointer reports physical Git toplevel' grep -qx "pointer=${project_repo}/.plans-config" "${SCRATCH}/out"
assert_ok 'project mapping written' grep -qx 'linear_project: project-id' "${project_repo}/.plans-config"
assert_eq 'newline-only ignore repair joins commit' $'.gitignore\n.plans-config' "$(git -C "$project_repo" show --pretty= --name-only HEAD)"
partial="${SCRATCH}/partial-ignore"; make_repo "$partial"
printf '.ycc/artifacts/probe\n' >"${partial}/.gitignore"
expect_exit 'dry-run catches partially ignored cache' 0 linear --dry-run "$partial"
assert_ok 'partial cache plans full coverage' grep -qx 'gitignore=added' "${SCRATCH}/out"
printf '.ycc/\n' >"${partial}/.gitignore"
expect_exit 'dry-run accepts wider repository coverage' 0 linear --dry-run "$partial"
assert_ok 'wider cache reports present' grep -qx 'gitignore=present' "${SCRATCH}/out"
untracked="${SCRATCH}/untracked-pointer"; make_repo "$untracked"
expect_exit 'no-commit creates untracked pointer' 0 linear --no-commit "$untracked"
expect_exit 'unchanged untracked pointer still commits' 0 linear "$untracked"
assert_ok 'unchanged untracked pointer becomes tracked' git -C "$untracked" ls-files --error-unmatch -- .plans-config
expect_exit 'real worktree bundle parity' 0 "$BASH_BIN" "$VALIDATOR" "${SCRIPT_DIR}/.."
printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
