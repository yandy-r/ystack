#!/usr/bin/env bash
# Source-tree PR key collection regressions; no Linear access required.
set -euo pipefail
BASH_BIN=${BASH_BIN:-bash}
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)"
HELPER="${SCRIPT_DIR}/../ycc/skills/_shared/scripts/collect-linear-keys.sh"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ycc-collect-keys.XXXXXX")"
SCRATCH="$(CDPATH='' cd -- "$SCRATCH" >/dev/null && pwd -P)"
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
assert_eq() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1";
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s: expected <%s>, got <%s>\n' "$1" "$2" "$3" >&2; fi
}
assert_bad() {
  local label=$1; shift
  if "$BASH_BIN" "$HELPER" "$@" >"${SCRATCH}/out" 2>"${SCRATCH}/err"; then
    FAIL=$((FAIL + 1)); printf 'FAIL: %s unexpectedly succeeded\n' "$label" >&2
  else
    PASS=$((PASS + 1)); printf 'PASS: %s\n' "$label"
  fi
}
repo="${SCRATCH}/repo with space"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" commit -q --allow-empty -m init
base=$(git -C "$repo" rev-parse HEAD)
printf 'scope: local\nlinear_team: YAN\n' >"${repo}/.plans-config"
git -C "$repo" checkout -q -b feat/yan-11-example
assert_eq 'branch hint uppercased' $'YAN-11\tbranch\tcloses' "$("$BASH_BIN" "$HELPER" --base "$base" "$repo")"
git -C "$repo" commit -q --allow-empty -m $'fix: first\n\nCloses YAN-11\nFixes: yan-12\nRESOLVES YAN-13\nrefs: Other-14\nRefs YAN-12'
git -C "$repo" commit -q --allow-empty -m $'fix: second\n\nrEfS: yan-15\nRefs YAN-12\nNotRefs YAN-999\nRefs YAN-99suffix'
expected=$'YAN-11\tbranch\tcloses\nYAN-15\tcommit\trefs\nYAN-12\tcommit\tcloses\nYAN-13\tcommit\tcloses'
assert_eq 'keywords, refs upgrade, case, dedupe and log order' "$expected" "$("$BASH_BIN" "$HELPER" --base "$base" "$repo")"
assert_eq 'default base falls back to main' "$expected" "$("$BASH_BIN" "$HELPER" "$repo")"
assert_eq 'team override filters branch and commits' $'OTHER-14\tcommit\trefs' "$("$BASH_BIN" "$HELPER" --team other --base "$base" "$repo")"
expected_all=$'YAN-11\tbranch\tcloses\nYAN-15\tcommit\trefs\nYAN-12\tcommit\tcloses\nYAN-13\tcommit\tcloses\nOTHER-14\tcommit\trefs'
assert_eq 'empty team override collects all candidates' "$expected_all" "$("$BASH_BIN" "$HELPER" --team '' --base "$base" "$repo")"
printf 'scope: local\n' >"${repo}/.plans-config"
assert_eq 'no configured team collects all candidates' "$expected_all" "$("$BASH_BIN" "$HELPER" --base "$base" "$repo")"
printf 'scope: local\nlinear_team: YAN\n' >"${repo}/.plans-config"
git -C "$repo" checkout -q -B fix/utf-8-thing
assert_eq 'configured team rejects utf-8 branch false positive' '' "$("$BASH_BIN" "$HELPER" --base HEAD "$repo")"
git -C "$repo" checkout -q --detach
assert_eq 'detached branch has no hint' '' "$("$BASH_BIN" "$HELPER" --base HEAD "$repo")"
git -C "$repo" checkout -q -b feat/YAN-21-no-base
git -C "$repo" branch -D main >/dev/null
assert_eq 'no available default base keeps hint only' $'YAN-21\tbranch\tcloses' "$("$BASH_BIN" "$HELPER" "$repo" 2>"${SCRATCH}/err")"
assert_eq 'missing default base warns' 'Warning: skipping Linear commit scan: no resolvable base.' "$(cat "${SCRATCH}/err")"
assert_eq 'unresolved explicit base skips commits' $'YAN-21\tbranch\tcloses' "$("$BASH_BIN" "$HELPER" --base missing-ref "$repo" 2>"${SCRATCH}/err")"
assert_eq 'missing explicit base warns' 'Warning: skipping Linear commit scan: no resolvable base.' "$(cat "${SCRATCH}/err")"
mkdir -p "${SCRATCH}/outside"
assert_eq 'non-repository succeeds with empty output' '' "$("$BASH_BIN" "$HELPER" "${SCRATCH}/outside")"
prefix_base=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q -b feat/prefixes
git -C "$repo" commit -q --allow-empty -m $'test: key shapes\n\nRefs A-1\nRefs AB-2\nRefs A123456789-3\nRefs A1234567890-4\nRefs 1A-5\nRefs AB-6suffix'
assert_eq 'commit prefix length matches branch hints' $'AB-2\tcommit\trefs\nA123456789-3\tcommit\trefs' "$("$BASH_BIN" "$HELPER" --base "$prefix_base" --team '' "$repo")"
remote_repo="${SCRATCH}/remote-base"
mkdir -p "$remote_repo"
git -C "$remote_repo" init -q -b main
git -C "$remote_repo" commit -q --allow-empty -m init
git -C "$remote_repo" checkout -q -b feat/remote-base
git -C "$remote_repo" commit -q --allow-empty -m $'fix: upstream\n\nCloses YAN-90'
git -C "$remote_repo" update-ref refs/remotes/origin/main HEAD
git -C "$remote_repo" commit -q --allow-empty -m $'fix: branch\n\nRefs YAN-91'
assert_eq 'bare base prefers remote over stale local main' $'YAN-91\tcommit\trefs' "$("$BASH_BIN" "$HELPER" --base main "$remote_repo")"
assert_bad 'unknown option fails' --wat
assert_bad 'missing base fails' --base
assert_bad 'empty base fails' --base ''
assert_bad 'missing team fails' --team
assert_bad 'invalid team fails' --team 'Y.N' "$repo"
assert_bad 'extra positional argument fails' "$repo" "$repo"
assert_bad 'missing directory fails' "${SCRATCH}/missing"
if [[ -x "$HELPER" ]]; then PASS=$((PASS + 1)); printf 'PASS: helper executable\n'; else FAIL=$((FAIL + 1)); fi
printf 'test-collect-linear-keys.sh: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
