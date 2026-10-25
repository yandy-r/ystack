#!/usr/bin/env bash
# test-clean-report.sh — clean skill report generation regressions (YAN-1290 / GH #464).
#
# Runs ycc/skills/clean/scripts/generate-report.sh against throwaway scratch
# targets and verifies:
#   - an empty findings file (no `###` entries) counts as 0 and does not abort
#     the category loop (the old `grep -c ... || echo 0` printed "0\n0")
#   - populated and mixed (empty + populated) categories sum into the total
#   - per-category rows and the executive-summary total in the report
#   - a missing category file is skipped
#   - unreadable findings (grep exit > 1) fail with exit 2, no success banner, no partial report
#   - a failed placeholder rewrite (read-only output dir) fails with exit 2, no success banner
#   - usage errors keep exit 1
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
SCRIPT="${REPO_ROOT}/ycc/skills/clean/scripts/generate-report.sh"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ycc-clean-report.XXXXXX")"
# Restore permissions first: the failure scenarios chmod scratch paths read-only.
trap 'chmod -R u+rwx "$SCRATCH" 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT

FAILED=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label: expected '$expected' got '$actual'"; fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$label"; else fail "$label: missing '$needle'"; fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$label"; else fail "$label: unexpected '$needle'"; fi
}

[[ -x "$SCRIPT" ]] || { printf 'FAIL: %s is not executable\n' "$SCRIPT" >&2; exit 1; }

# new_target <name> -> echoes the scratch target dir with an empty findings dir
new_target() {
  local dir="${SCRATCH}/$1"
  mkdir -p "${dir}/.cleanup-analysis/findings"
  printf '%s' "$dir"
}

EMPTY_FINDINGS=$'# Code\n\n## x\n'
ONE_FINDING=$'# B\n\n## x\n### junk.tmp\n- **Total Size**: 1 B\n'
TWO_FINDINGS=$'# A\n\n## x\n### a.png\n### b.png\n- **Total Size**: 2 KB\n'

# run <target> -> sets RC, OUT, ERR
run() {
  RC=0
  OUT="$("$SCRIPT" "$1" 2>"${SCRATCH}/stderr")" || RC=$?
  ERR="$(cat "${SCRATCH}/stderr" 2>/dev/null || true)"
}

# --- 1. empty and populated categories (issue repro) -------------------------
# Categories are visited in associative-array order, not a fixed order, so the
# empty file may be counted before or after the populated one.
t="$(new_target repro)"
printf '%s' "$EMPTY_FINDINGS" >"${t}/.cleanup-analysis/findings/code-files.md"
printf '%s' "$ONE_FINDING" >"${t}/.cleanup-analysis/findings/binaries.md"
run "$t"
report="$(cat "${t}/.cleanup-analysis/cleanup-report.md" 2>/dev/null || true)"
assert_eq "repro: exit 0" "0" "$RC"
assert_contains "repro: stdout total is 1" "Total files identified: 1" "$OUT"
assert_contains "repro: code-files counted as 0" "code-files: 0 files" "$OUT"
assert_contains "repro: binaries counted as 1" "binaries: 1 files" "$OUT"
assert_contains "repro: report header total" "**Total Files Analyzed**: 1" "$report"
assert_contains "repro: report summary total" "identified **1** unnecessary files" "$report"
assert_contains "repro: binaries row in stats table" "| Binaries       | 1     |" "$report"
assert_contains "repro: code-files row in stats table" "| Code Files     | 0     |" "$report"
assert_contains "repro: binaries section included" "### junk.tmp" "$report"

# --- 2. only empty findings --------------------------------------------------
t="$(new_target all-empty)"
printf '%s' "$EMPTY_FINDINGS" >"${t}/.cleanup-analysis/findings/code-files.md"
printf '%s' "$EMPTY_FINDINGS" >"${t}/.cleanup-analysis/findings/docker.md"
run "$t"
assert_eq "all-empty: exit 0" "0" "$RC"
assert_contains "all-empty: total is 0" "Total files identified: 0" "$OUT"
assert_contains "all-empty: success banner" "Report generated successfully" "$OUT"

# --- 3. populated categories sum --------------------------------------------
t="$(new_target populated)"
printf '%s' "$TWO_FINDINGS" >"${t}/.cleanup-analysis/findings/assets.md"
printf '%s' "$ONE_FINDING" >"${t}/.cleanup-analysis/findings/binaries.md"
printf '%s' "$EMPTY_FINDINGS" >"${t}/.cleanup-analysis/findings/config.md"
printf '%s' "$TWO_FINDINGS" >"${t}/.cleanup-analysis/findings/documentation.md"
run "$t"
report="$(cat "${t}/.cleanup-analysis/cleanup-report.md" 2>/dev/null || true)"
assert_eq "populated: exit 0" "0" "$RC"
assert_contains "populated: total is 5" "Total files identified: 5" "$OUT"
assert_contains "populated: report header total" "**Total Files Analyzed**: 5" "$report"
assert_contains "populated: assets row" "| Assets         | 2     | 2 KB  |" "$report"
assert_contains "populated: config row (empty)" "| Config         | 0     | 0 B   |" "$report"

# --- 4. missing categories are skipped --------------------------------------
t="$(new_target missing)"
printf '%s' "$ONE_FINDING" >"${t}/.cleanup-analysis/findings/binaries.md"
run "$t"
assert_eq "missing: exit 0" "0" "$RC"
assert_contains "missing: total is 1" "Total files identified: 1" "$OUT"
assert_not_contains "missing: absent category not listed" "docker:" "$OUT"

# --- 5. unreadable findings fail with exit 2 --------------------------------
t="$(new_target unreadable)"
printf '%s' "$ONE_FINDING" >"${t}/.cleanup-analysis/findings/binaries.md"
# An unreadable regular file makes grep exit 2. Skipped when running as root
# (the read still succeeds). A stale report from an earlier run must not
# survive the failure.
printf 'stale\n' >"${t}/.cleanup-analysis/cleanup-report.md"
chmod 000 "${t}/.cleanup-analysis/findings/binaries.md"
if [[ -r "${t}/.cleanup-analysis/findings/binaries.md" ]]; then
  printf 'SKIP: unreadable findings (file still readable, running as root?)\n'
else
  run "$t"
  assert_eq "unreadable: exit 2" "2" "$RC"
  assert_not_contains "unreadable: no success banner" "Report generated successfully" "$OUT"
  assert_contains "unreadable: stderr explains failure" "Failed to generate report" "$ERR"
  assert_eq "unreadable: no report left behind" "no" "$([[ -e "${t}/.cleanup-analysis/cleanup-report.md" ]] && echo yes || echo no)"
fi
chmod 644 "${t}/.cleanup-analysis/findings/binaries.md"

# --- 6. failed placeholder rewrite fails with exit 2 -------------------------
# A pre-created writable report lets the initial `cat >` succeed while the
# read-only directory makes the `.tmp` write in replace_in_file fail. Skipped
# when running as root (permissions are not enforced).
t="$(new_target readonly-dir)"
printf '%s' "$ONE_FINDING" >"${t}/.cleanup-analysis/findings/binaries.md"
: >"${t}/.cleanup-analysis/cleanup-report.md"
chmod 555 "${t}/.cleanup-analysis"
if (: >"${t}/.cleanup-analysis/probe") 2>/dev/null; then
  rm -f "${t}/.cleanup-analysis/probe"
  printf 'SKIP: read-only output dir (permissions not enforced, running as root?)\n'
else
  run "$t"
  assert_eq "readonly-dir: exit 2" "2" "$RC"
  assert_not_contains "readonly-dir: no success banner" "Report generated successfully" "$OUT"
  assert_contains "readonly-dir: stderr explains failure" "Failed to generate report" "$ERR"
fi
chmod 755 "${t}/.cleanup-analysis"

# --- 7. usage errors keep exit 1 --------------------------------------------
run "${SCRATCH}/does-not-exist"
assert_eq "usage: missing target dir exits 1" "1" "$RC"
mkdir -p "${SCRATCH}/no-findings"
run "${SCRATCH}/no-findings"
assert_eq "usage: missing findings dir exits 1" "1" "$RC"

if [[ "$FAILED" -ne 0 ]]; then
  echo "test-clean-report.sh: FAILED" >&2
  exit 1
fi
echo "test-clean-report.sh: all checks passed"
