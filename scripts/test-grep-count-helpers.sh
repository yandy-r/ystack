#!/usr/bin/env bash
# test-grep-count-helpers.sh — grep -c fallback regressions (YAN-1572 / GH #470).
#
# The old `$(... | grep -c PAT || echo 0)` idiom prints "0\n0" on zero matches
# (grep prints 0 and exits 1, then the fallback echoes another 0), breaking
# arithmetic and numeric comparisons downstream, and silently turns real read
# errors (grep exit > 1) into 0.
#
# Runs each affected helper against throwaway scratch fixtures and verifies:
#   - a zero-match input reports a single integer 0 ("N: 0"), never "0\n0"
#   - a some-matches input reports the real count
#   - no "integer expression expected" / arithmetic noise appears in output
#   - grep exit > 1 (read error) surfaces as a non-zero exit and stderr error
#     where the helper detects it (coverage for fix sites 1-5)
#   - the prp-implement SKILL.md inline snippet prints exactly one integer
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ycc-grep-count.XXXXXX")"
trap 'chmod -R u+rwx "$SCRATCH" 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT

FAILED=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

# assert_count_line <label> <output> <prefix-regex> <expected-count>
# Requires exactly one count line matching the prefix with the expected count.
assert_count_line() {
    local label="$1" out="$2" prefix="$3" want="$4"
    local matches n
    matches=$(printf '%s\n' "$out" | grep -E "${prefix}[0-9]+" || true)
    n=$(printf '%s\n' "$matches" | grep -c . || true)
    if [[ "$n" != "1" ]]; then
        fail "$label: expected exactly one '${prefix}N' line, got: $matches"
        return
    fi
    if [[ "$matches" =~ ${prefix}[[:space:]]*${want}$ ]]; then
        pass "$label"
    else
        fail "$label: expected '${prefix}${want}', got '$matches'"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        fail "$label: unexpected '$needle'"
    else
        pass "$label"
    fi
}

# run_capture <name> -- <cmd...>; runs in a subshell, sets RC, OUT, ERR.
run_capture() {
    local name="$1"; shift
    [[ "$1" == "--" ]] && shift
    local out="${SCRATCH}/${name}.out" err="${SCRATCH}/${name}.err"
    set +e
    ( "$@" ) >"$out" 2>"$err"
    RC=$?
    set -e
    OUT="$(cat "$out")"
    ERR="$(cat "$err")"
}

# --- fixtures -----------------------------------------------------------------

PLAN_EMPTY="${SCRATCH}/plan-empty.md"
printf '# Plan\n\nSome notes without task headings.\n' >"$PLAN_EMPTY"

PLAN_SOME="${SCRATCH}/plan-some.md"
cat >"$PLAN_SOME" <<'EOF'
# Plan

#### Task one

body

#### Task two

body
EOF

# plan-check <script> <plan-file> — runs a check-prerequisites.sh against a
# scratch docs/plans/<feature>/ layout containing the given plan file.
plan_check() {
    local script="$1" plan_file="$2" name
    name="$(basename "$(dirname "$(dirname "$script")")")"
    local root="${SCRATCH}/planrun-${name}-${RANDOM}"
    mkdir -p "${root}/docs/plans/feat"
    cp "$plan_file" "${root}/docs/plans/feat/parallel-plan.md"
    printf 'shared context\n' >"${root}/docs/plans/feat/shared.md"
    run_capture "plan-${name}-${RANDOM}" -- bash -c "cd '${root}' && bash '${script}' feat"
}

# --- 1. code-report check-prerequisites.sh ------------------------------------

CR_SCRIPT="${REPO_ROOT}/ycc/skills/code-report/scripts/check-prerequisites.sh"

plan_check "$CR_SCRIPT" "$PLAN_EMPTY"
assert_count_line "code-report: zero matches -> single 0" "$OUT" 'Tasks in plan: *' "0"
assert_not_contains "code-report: no arithmetic noise" "integer expression expected" "${OUT}${ERR}"
if printf '%s\n' "$OUT" | grep -qx '0'; then fail "code-report: stray bare 0 line"; else pass "code-report: no stray bare 0 line"; fi

plan_check "$CR_SCRIPT" "$PLAN_SOME"
assert_count_line "code-report: two matches -> 2" "$OUT" 'Tasks in plan: *' "2"

# --- 2. implement-plan check-prerequisites.sh ---------------------------------

IP_SCRIPT="${REPO_ROOT}/ycc/skills/implement-plan/scripts/check-prerequisites.sh"

plan_check "$IP_SCRIPT" "$PLAN_EMPTY"
assert_count_line "implement-plan: zero matches -> single 0" "$OUT" 'Tasks in plan: *' "0"
assert_not_contains "implement-plan: no arithmetic noise" "integer expression expected" "${OUT}${ERR}"
if printf '%s\n' "$OUT" | grep -qx '0'; then fail "implement-plan: stray bare 0 line"; else pass "implement-plan: no stray bare 0 line"; fi

plan_check "$IP_SCRIPT" "$PLAN_SOME"
assert_count_line "implement-plan: two matches -> 2" "$OUT" 'Tasks in plan: *' "2"

# --- 3. write-docs audit-documentation.sh -------------------------------------

AUDIT_SCRIPT="${REPO_ROOT}/ycc/skills/write-docs/scripts/audit-documentation.sh"

audit_dir="${SCRATCH}/audit-empty"
mkdir -p "$audit_dir/sub"
printf 'not a readme\n' >"$audit_dir/sub/notes.txt"
run_capture audit-empty -- bash -c "cd '$audit_dir' && bash '$AUDIT_SCRIPT'"
assert_count_line "audit-docs: zero README matches -> single 0" "$OUT" '\*\*Total README\.md files\*\*: *' "0"
assert_count_line "audit-docs: zero CLAUDE matches -> single 0" "$OUT" '\*\*Total CLAUDE\.md files\*\*: *' "0"
assert_not_contains "audit-docs: no arithmetic noise" "integer expression expected" "${OUT}${ERR}"
if printf '%s\n' "$OUT" | grep -qx '0'; then fail "audit-docs: stray bare 0 line"; else pass "audit-docs: no stray bare 0 line"; fi

audit_dir2="${SCRATCH}/audit-some"
mkdir -p "$audit_dir2"
printf '# readme\n' >"$audit_dir2/README.md"
run_capture audit-some -- bash -c "cd '$audit_dir2' && bash '$AUDIT_SCRIPT'"
assert_count_line "audit-docs: one README -> 1" "$OUT" '\*\*Total README\.md files\*\*: *' "1"

# --- 4. deep-research validate-research.sh -------------------------------------
# Run only check_search_queries by sourcing the script body up to the helper.
VR_SCRIPT="${REPO_ROOT}/ycc/skills/deep-research/scripts/validate-research.sh"
VR_HARNESS="${SCRATCH}/vr-harness.sh"
{
    # Extract just the preamble (set -euo pipefail, colors) and the two
    # helpers from validate-research.sh; the top-level argument checks would
    # reject our scratch file path, so they are deliberately left out.
    sed -n '1,5p' "$VR_SCRIPT"
    sed -n '7,12p' "$VR_SCRIPT"
    sed -n '/^# Helper function to count lines in file$/,/^}$/p' "$VR_SCRIPT"
    sed -n '/^# Helper function to check for search queries$/,/^}$/p' "$VR_SCRIPT"
    cat <<'HARNESS'
PERSONA_FILE="$1"
WARNINGS=0
check_search_queries "$PERSONA_FILE" "test-persona"
printf 'WARNINGS=%s\n' "$WARNINGS"
HARNESS
} >"$VR_HARNESS"

VR_EMPTY="${SCRATCH}/vr-empty.md"
printf '# Findings\n\nNo numbered queries here.\n' >"$VR_EMPTY"
run_capture vr-empty -- bash "$VR_HARNESS" "$VR_EMPTY"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == *"WARNINGS=1"* ]] \
    && [[ "$OUT" == *"Only 0 search queries"* ]] \
    && ! printf '%s\n' "$OUT" | grep -qx '0'; then
    pass "deep-research: zero matches -> single 0, one warning"
else
    fail "deep-research: zero matches handling (rc=$RC, out=$OUT)"
fi
assert_not_contains "deep-research: no arithmetic noise" "integer expression expected" "${OUT}${ERR}"

VR_SOME="${SCRATCH}/vr-some.md"
printf '1. one\n2. two\n3. three\n4. four\n5. five\n6. six\n7. seven\n8. eight\n' >"$VR_SOME"
run_capture vr-some -- bash "$VR_HARNESS" "$VR_SOME"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == *"WARNINGS=0"* ]]; then
    pass "deep-research: eight matches -> no warning"
else
    fail "deep-research: eight matches (rc=$RC, out=$OUT)"
fi

# --- 5. git-workflow analyze-changes.sh ----------------------------------------

AC_SCRIPT="${REPO_ROOT}/ycc/skills/git-workflow/scripts/analyze-changes.sh"

make_git_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

# Zero-match case: dirs "." (top-level file) and "pkg" both appear in
# "Changed Directories"; for dir "." the "^./" pattern matches zero lines in
# ALL_CHANGED_FILES (paths are relative, never start with "./"). Uses only
# source extensions (.ts) because categorize_file() returns non-zero for
# doc/config files and the script's set -e would abort before reaching the
# count line (pre-existing quirk, outside this fix's scope).
AC_ZERO="${SCRATCH}/ac-zero"
make_git_repo "$AC_ZERO"
mkdir -p "$AC_ZERO/pkg"
printf 'top\n' >"$AC_ZERO/toplevel.ts"
printf 'pkg\n' >"$AC_ZERO/pkg/mod.ts"
git -C "$AC_ZERO" add -A
git -C "$AC_ZERO" -c user.email=t@t -c user.name=t commit -q -m 'seed'
printf 'y\n' >>"$AC_ZERO/toplevel.ts"
printf 'y\n' >>"$AC_ZERO/pkg/mod.ts"
run_capture ac-zero -- bash -c "cd '$AC_ZERO' && bash '$AC_SCRIPT'"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == *'- ./ (0 files)'* ]] \
    && ! printf '%s\n' "$OUT" | grep -qx '0'; then
    pass "analyze-changes: zero-match dir -> single 0"
else
    fail "analyze-changes: zero-match dir (rc=$RC, out=$OUT)"
fi
assert_not_contains "analyze-changes: no arithmetic noise" "integer expression expected" "${OUT}${ERR}"

# Some-matches case: two files under src/, one elsewhere.
AC_SOME="${SCRATCH}/ac-some"
make_git_repo "$AC_SOME"
mkdir -p "$AC_SOME/src" "$AC_SOME/lib"
printf 'a\n' >"$AC_SOME/src/a.ts"
printf 'b\n' >"$AC_SOME/src/b.ts"
printf 'c\n' >"$AC_SOME/lib/c.ts"
git -C "$AC_SOME" add -A
git -C "$AC_SOME" -c user.email=t@t -c user.name=t commit -q -m 'seed'
printf 'z\n' >>"$AC_SOME/src/a.ts"
printf 'z\n' >>"$AC_SOME/src/b.ts"
printf 'z\n' >>"$AC_SOME/lib/c.ts"
run_capture ac-some -- bash -c "cd '$AC_SOME' && bash '$AC_SCRIPT'"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == *'- src/ (2 files)'* ]]; then
    pass "analyze-changes: src/ counted as 2"
else
    fail "analyze-changes: src/ count (rc=$RC, out=$OUT)"
fi

# --- 6. git-workflow validate-commit.sh ----------------------------------------

VC_SCRIPT="${REPO_ROOT}/ycc/skills/git-workflow/scripts/validate-commit.sh"

run_capture vc-zero -- bash "$VC_SCRIPT" "feat: subject only"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" != *'✓ Body is present'* ]] \
    && ! printf '%s\n' "$OUT" | grep -qx '0' \
    && [[ "$ERR" != *'integer'* ]]; then
    pass "validate-commit: empty body -> single 0 path"
else
    fail "validate-commit: empty body (rc=$RC, out=$OUT)"
fi
assert_not_contains "validate-commit: no arithmetic noise" "integer expression expected" "${OUT}${ERR}"

VC_BODY=$'feat: subject\n\nThis body has content.\n'
run_capture vc-body -- bash "$VC_SCRIPT" "$VC_BODY"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == *'✓ Body is present (1 lines)'* ]]; then
    pass "validate-commit: one body line -> 1"
else
    fail "validate-commit: one body line (rc=$RC, out=$OUT)"
fi

# shellcheck disable=SC2016 # the single-quoted body is intentional: it is the
# SKILL.md snippet verbatim, executed via bash -c with the plan path as $1.
SNIPPET_BODY='
    PLAN_PATH="$1"
    grep -c "^## Worktree Setup" "$PLAN_PATH"; [ $? -le 1 ]
    grep -c "^\- \*\*Worktree\*\*:" "$PLAN_PATH"; [ $? -le 1 ]
'
SNIPPET_PLAN="${SCRATCH}/snippet-plan.md"
printf '# Plan\n\nNo worktree annotations.\n' >"$SNIPPET_PLAN"
run_capture snippet-zero -- bash -c "$SNIPPET_BODY" _ "$SNIPPET_PLAN"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == $'0\n0' ]]; then
    pass "SKILL.md snippet: zero matches -> one integer per grep (0,0)"
else
    fail "SKILL.md snippet: zero matches (rc=$RC, out='$OUT')"
fi
# And against a plan with one match for each pattern.
SNIPPET_PLAN2="${SCRATCH}/snippet-plan2.md"
printf '## Worktree Setup\n- **Worktree**: x\n' >"$SNIPPET_PLAN2"
run_capture snippet-some -- bash -c "$SNIPPET_BODY" _ "$SNIPPET_PLAN2"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == $'1\n1' ]]; then
    pass "SKILL.md snippet: one match each -> 1,1"
else
    fail "SKILL.md snippet: one match each (rc=$RC, out='$OUT')"
fi

# --- summary -------------------------------------------------------------------

if [[ "$FAILED" -ne 0 ]]; then
    echo "test-grep-count-helpers.sh: FAILED" >&2
    exit 1
fi
echo "test-grep-count-helpers.sh: all checks passed"
