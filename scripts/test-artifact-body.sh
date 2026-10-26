#!/usr/bin/env bash
# Frontmatter body regressions (YAN-1154). No generated bundles required.
# shellcheck disable=SC2016 # Inner-shell programs must stay literal.
set -euo pipefail
export BASH_BIN=${BASH_BIN:-bash}
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)"
HELPER="${SCRIPT_DIR}/../ycc/skills/_shared/scripts/artifact-body.sh"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ycc-artifact-body.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*" >&2; }
assert_same() {
  local label="$1" expected="$2" actual="$3"
  if cmp -s "$expected" "$actual"; then
    pass "$label"
  else
    fail "$label: output differs"
  fi
}
assert_bad() {
  local label="$1"; shift
  if "$@" >"${SCRATCH}/out" 2>"${SCRATCH}/err"; then
    fail "$label: unexpectedly succeeded"
  else
    pass "$label"
    if [[ -s "${SCRATCH}/err" ]]; then pass "$label diagnoses on stderr"; else fail "$label has no diagnostic"; fi
  fi
}
check_both_forms() {
  local label="$1" fixture="$2" expected="$3"
  "$BASH_BIN" "$HELPER" "$fixture" >"${SCRATCH}/actual"
  assert_same "$label executed" "$expected" "${SCRATCH}/actual"
  "$BASH_BIN" -c 'source "$1" || exit 1; artifact_body "$2"' _ "$HELPER" "$fixture" >"${SCRATCH}/actual"
  assert_same "$label sourced" "$expected" "${SCRATCH}/actual"
}

: >"${SCRATCH}/empty"
check_both_forms 'empty file' "${SCRATCH}/empty" "${SCRATCH}/empty"
printf 'not frontmatter\n---\nbody\n' >"${SCRATCH}/plain"
check_both_forms 'plain file unchanged' "${SCRATCH}/plain" "${SCRATCH}/plain"
printf -- '---' >"${SCRATCH}/marker-no-newline"
check_both_forms 'unterminated marker without newline unchanged' "${SCRATCH}/marker-no-newline" "${SCRATCH}/marker-no-newline"
printf -- '---\nkey: value\nno closing marker\n' >"${SCRATCH}/unterminated"
check_both_forms 'unterminated block unchanged' "${SCRATCH}/unterminated" "${SCRATCH}/unterminated"
printf -- '---\r\nkey: value\r\nnot the end\r\n' >"${SCRATCH}/unterminated-crlf"
check_both_forms 'unterminated CRLF block unchanged' "${SCRATCH}/unterminated-crlf" "${SCRATCH}/unterminated-crlf"
printf -- '---\nkey: value\n---\n# Title\nbody\n---\n' >"${SCRATCH}/frontmatter"
printf '# Title\nbody\n---\n' >"${SCRATCH}/frontmatter-expected"
check_both_forms 'leading block removed only' "${SCRATCH}/frontmatter" "${SCRATCH}/frontmatter-expected"
printf -- '---\r\nkey: value\r\n---\r\n# Title\r\nbody without newline' >"${SCRATCH}/crlf"
printf '# Title\r\nbody without newline' >"${SCRATCH}/crlf-expected"
check_both_forms 'CRLF delimiters and body bytes' "${SCRATCH}/crlf" "${SCRATCH}/crlf-expected"
printf -- '---\nkey: value\n---\n' >"${SCRATCH}/only-frontmatter"
check_both_forms 'complete block produces empty body' "${SCRATCH}/only-frontmatter" "${SCRATCH}/empty"
printf -- '---\nkey: value\n---' >"${SCRATCH}/closing-no-newline"
check_both_forms 'closing delimiter without newline' "${SCRATCH}/closing-no-newline" "${SCRATCH}/empty"
printf -- '---\nkey: value\n--- \nbody\n' >"${SCRATCH}/spaced-closing"
check_both_forms 'spaced delimiter is body text' "${SCRATCH}/spaced-closing" "${SCRATCH}/spaced-closing"
printf -- '---\nkey: value\n---\n---\n' >"${SCRATCH}/empty-body-marker"
printf -- '---\n' >"${SCRATCH}/empty-body-marker-expected"
check_both_forms 'second delimiter remains body' "${SCRATCH}/empty-body-marker" "${SCRATCH}/empty-body-marker-expected"
assert_bad 'missing file fails' "$BASH_BIN" "$HELPER" "${SCRATCH}/missing"
assert_bad 'directory fails' "$BASH_BIN" "$HELPER" "$SCRATCH"
assert_bad 'missing argument fails' "$BASH_BIN" "$HELPER"
assert_bad 'extra argument fails' "$BASH_BIN" "$HELPER" "${SCRATCH}/plain" "${SCRATCH}/plain"
assert_bad 'sourced missing file fails' "$BASH_BIN" -c 'source "$1" || exit 1; artifact_body "$2"' _ "$HELPER" "${SCRATCH}/missing"
options="$("$BASH_BIN" -c 'source "$1" || exit 1; case $- in *e*) printf on;; *) printf off;; esac' _ "$HELPER")"
if [[ "$options" == off ]]; then pass 'source does not enable errexit'; else fail 'source enabled errexit'; fi
strict="$("$BASH_BIN" -ec 'source "$1"; printf survived' _ "$HELPER")"
if [[ "$strict" == survived ]]; then pass 'strict caller survives source'; else fail 'strict caller did not survive source'; fi
if "$BASH_BIN" -uc 'source "$1"; printf survived' _ "$HELPER" >"${SCRATCH}/source-check" 2>"${SCRATCH}/err"; then
  pass 'nounset caller survives source'
else
  fail 'nounset caller failed source'
fi
"$BASH_BIN" -c 'source "$1"' _ "$HELPER" >"${SCRATCH}/source-output"
assert_same 'sourcing produces no output' "${SCRATCH}/empty" "${SCRATCH}/source-output"
# The caller's fd 3 must survive artifact_body (no exec on shared descriptors).
fd3="$("$BASH_BIN" -c 'source "$1" || exit 1; exec 3<"$2"; artifact_body "$3" >/dev/null; IFS= read -r -u3 line; printf %s "$line"' _ "$HELPER" "${SCRATCH}/plain" "${SCRATCH}/frontmatter")"
if [[ "$fd3" == 'not frontmatter' ]]; then pass 'caller fd 3 is left untouched'; else fail "caller fd 3 clobbered: '$fd3'"; fi
# Large body consumed by an early-exiting reader through process substitution.
{ printf -- '---\nk: v\n---\n# Title\n'; head -c 1048576 /dev/zero | tr '\0' x | fold -w 100; echo; } >"${SCRATCH}/large"
if "$BASH_BIN" -c 'set -o pipefail; source "$1" || exit 1; grep -q "^# Title" < <(artifact_body "$2")' _ "$HELPER" "${SCRATCH}/large"; then pass 'large body with early-exit reader'; else fail 'large body with early-exit reader'; fi
if [[ -x "$HELPER" ]]; then pass 'helper executable'; else fail 'helper is not executable'; fi
printf 'test-artifact-body.sh: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
