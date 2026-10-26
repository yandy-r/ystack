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
#     where the helper detects it (code-report, implement-plan, deep-research,
#     analyze-changes, validate-commit and the prp-implement snippet's
#     missing-file case)
#   - the prp-implement SKILL.md / references/detection.md snippet lines are
#     extracted from the docs and print exactly one integer per line
#   - analyze-changes handles mixed categories under errexit and detects source
#     changes when the changed-file list exceeds the pipe buffer (YAN-1587/1588)
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ycc-grep-count.XXXXXX")"
# Restore permissions first: the unreadable-file scenarios chmod fixtures to 000.
trap 'chmod -R u+rwx "$SCRATCH" 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT

# Git hooks (pre-push runs validate.sh) export GIT_DIR and friends; left set,
# they would point every scratch `git` call at the caller's repository —
# polluting its refs, worktree registrations, and config. Clear them all before
# any git operation, then pin git to a scratch config so neither system nor
# global config is read or written (same isolation as test-worktree-roots.sh).
while IFS= read -r git_var; do
    unset "$git_var"
done < <(git rev-parse --local-env-vars)
unset git_var
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${SCRATCH}/gitconfig"
export GIT_TERMINAL_PROMPT=0
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

# assert_no_bare_zero <label> <output> — no line may be exactly "0" (the old
# fallback printed a second 0 on its own line).
assert_no_bare_zero() {
    if printf '%s\n' "$2" | grep -qx '0'; then
        fail "$1: stray bare 0 line"
    else
        pass "$1: no stray bare 0 line"
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

# can_honor_chmod — root ignores permission bits, so the unreadable-file
# scenarios only run for unprivileged users.
CAN_CHMOD=1
if [[ "$(id -u)" -eq 0 ]]; then
    CAN_CHMOD=0
    printf 'SKIP: unreadable-file scenarios (running as root)\n'
fi

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

# plan_check <script> <plan-file> — runs a check-prerequisites.sh against a
# scratch docs/plans/<feature>/ layout containing the given plan file. The
# scratch root gets a local-scope .plans-config so resolve-plans-dir.sh never
# walks up into a real checkout (TMPDIR may live under one) and redirect
# PLANS_DIR.
plan_check() {
    local script="$1" plan_file="$2" name
    name="$(basename "$(dirname "$(dirname "$script")")")"
    local root="${SCRATCH}/planrun-${name}-${RANDOM}"
    mkdir -p "${root}/docs/plans/feat"
    printf 'plans_dir: docs/plans\nscope: local\n' >"${root}/.plans-config"
    cp "$plan_file" "${root}/docs/plans/feat/parallel-plan.md"
    printf 'shared context\n' >"${root}/docs/plans/feat/shared.md"
    run_capture "plan-${name}-${RANDOM}" -- bash -c "cd '${root}' && bash '${script}' feat"
}

# --- 1. code-report check-prerequisites.sh ------------------------------------

CR_SCRIPT="${REPO_ROOT}/ycc/skills/code-report/scripts/check-prerequisites.sh"

plan_check "$CR_SCRIPT" "$PLAN_EMPTY"
assert_count_line "code-report: zero matches -> single 0" "$OUT" 'Tasks in plan: *' "0"
assert_not_contains "code-report: no arithmetic noise" "integer expression expected" "${OUT}${ERR}"
assert_no_bare_zero "code-report" "$OUT"

plan_check "$CR_SCRIPT" "$PLAN_SOME"
assert_count_line "code-report: two matches -> 2" "$OUT" 'Tasks in plan: *' "2"

# Unreadable plan file: grep exit 2 must surface, not be swallowed into 0.
if [[ "$CAN_CHMOD" -eq 1 ]]; then
    CR_LOCKED="${SCRATCH}/planrun-cr-locked"
    mkdir -p "${CR_LOCKED}/docs/plans/feat"
    printf 'plans_dir: docs/plans\nscope: local\n' >"${CR_LOCKED}/.plans-config"
    cp "$PLAN_SOME" "${CR_LOCKED}/docs/plans/feat/parallel-plan.md"
    printf 'shared context\n' >"${CR_LOCKED}/docs/plans/feat/shared.md"
    chmod 000 "${CR_LOCKED}/docs/plans/feat/parallel-plan.md"
    run_capture cr-unreadable -- bash -c "cd '${CR_LOCKED}' && bash '${CR_SCRIPT}' feat"
    if [[ "$RC" -eq 2 ]] && [[ "$ERR" == *'ERROR: Failed to read'* ]]; then
        pass "code-report: unreadable plan -> exit 2 + stderr error"
    else
        fail "code-report: unreadable plan (rc=$RC, err=$ERR)"
    fi
    chmod 644 "${CR_LOCKED}/docs/plans/feat/parallel-plan.md"
fi

# --- 2. implement-plan check-prerequisites.sh ---------------------------------

IP_SCRIPT="${REPO_ROOT}/ycc/skills/implement-plan/scripts/check-prerequisites.sh"

plan_check "$IP_SCRIPT" "$PLAN_EMPTY"
assert_count_line "implement-plan: zero matches -> single 0" "$OUT" 'Tasks in plan: *' "0"
assert_not_contains "implement-plan: no arithmetic noise" "integer expression expected" "${OUT}${ERR}"
assert_no_bare_zero "implement-plan" "$OUT"

plan_check "$IP_SCRIPT" "$PLAN_SOME"
assert_count_line "implement-plan: two matches -> 2" "$OUT" 'Tasks in plan: *' "2"

# Unreadable plan file: plan_count must fail loudly.
if [[ "$CAN_CHMOD" -eq 1 ]]; then
    IP_LOCKED="${SCRATCH}/planrun-ip-locked"
    mkdir -p "${IP_LOCKED}/docs/plans/feat"
    printf 'plans_dir: docs/plans\nscope: local\n' >"${IP_LOCKED}/.plans-config"
    cp "$PLAN_SOME" "${IP_LOCKED}/docs/plans/feat/parallel-plan.md"
    printf 'shared context\n' >"${IP_LOCKED}/docs/plans/feat/shared.md"
    chmod 000 "${IP_LOCKED}/docs/plans/feat/parallel-plan.md"
    run_capture ip-unreadable -- bash -c "cd '${IP_LOCKED}' && bash '${IP_SCRIPT}' feat"
    if [[ "$RC" -eq 2 ]] && [[ "$ERR" == *'ERROR: Failed to read'* ]]; then
        pass "implement-plan: unreadable plan -> exit 2 + stderr error"
    else
        fail "implement-plan: unreadable plan (rc=$RC, err=$ERR)"
    fi
    chmod 644 "${IP_LOCKED}/docs/plans/feat/parallel-plan.md"
fi

# --- 3. write-docs audit-documentation.sh -------------------------------------

AUDIT_SCRIPT="${REPO_ROOT}/ycc/skills/write-docs/scripts/audit-documentation.sh"

audit_dir="${SCRATCH}/audit-empty"
mkdir -p "$audit_dir/sub"
printf 'not a readme\n' >"$audit_dir/sub/notes.txt"
run_capture audit-empty -- bash -c "cd '$audit_dir' && bash '$AUDIT_SCRIPT'"
assert_count_line "audit-docs: zero README matches -> single 0" "$OUT" '\*\*Total README\.md files\*\*: *' "0"
assert_count_line "audit-docs: zero CLAUDE matches -> single 0" "$OUT" '\*\*Total CLAUDE\.md files\*\*: *' "0"
assert_not_contains "audit-docs: no arithmetic noise" "integer expression expected" "${OUT}${ERR}"
assert_no_bare_zero "audit-docs" "$OUT"

audit_dir2="${SCRATCH}/audit-some"
mkdir -p "$audit_dir2"
printf '# readme\n' >"$audit_dir2/README.md"
run_capture audit-some -- bash -c "cd '$audit_dir2' && bash '$AUDIT_SCRIPT'"
assert_count_line "audit-docs: one README -> 1" "$OUT" '\*\*Total README\.md files\*\*: *' "1"

# --- 4. deep-research validate-research.sh -------------------------------------
# Run only check_search_queries: extract the preamble and the two helpers from
# validate-research.sh; the top-level argument checks would reject our scratch
# file path, so they are deliberately left out.
VR_SCRIPT="${REPO_ROOT}/ycc/skills/deep-research/scripts/validate-research.sh"
VR_HARNESS="${SCRATCH}/vr-harness.sh"
{
    # Everything before the usage() function: shebang, `set -euo pipefail`,
    # color variables. Extracted by pattern, not line numbers.
    sed -n '1,/^usage() {/p' "$VR_SCRIPT" | sed '$d'
    sed -n '/^# Helper function to count lines in file$/,/^}$/p' "$VR_SCRIPT"
    sed -n '/^# Helper function to check for search queries$/,/^}$/p' "$VR_SCRIPT"
    cat <<'HARNESS'
PERSONA_FILE="$1"
WARNINGS=0
check_search_queries "$PERSONA_FILE" "test-persona"
printf 'WARNINGS=%s\n' "$WARNINGS"
HARNESS
} >"$VR_HARNESS"

# The harness must keep the script's strict mode; without it a read error
# would flow differently than in production.
if grep -qx 'set -euo pipefail' "$VR_HARNESS"; then
    pass "deep-research: harness keeps set -euo pipefail"
else
    fail "deep-research: harness lost set -euo pipefail"
fi

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

# Unreadable findings file: grep exit 2 must propagate out of the helper.
if [[ "$CAN_CHMOD" -eq 1 ]]; then
    VR_UNREADABLE="${SCRATCH}/vr-unreadable.md"
    printf '1. one\n' >"$VR_UNREADABLE"
    chmod 000 "$VR_UNREADABLE"
    run_capture vr-unreadable -- bash "$VR_HARNESS" "$VR_UNREADABLE"
    if [[ "$RC" -ne 0 ]] && [[ "$ERR" == *'Failed to read'* ]]; then
        pass "deep-research: unreadable file -> non-zero rc + stderr error"
    else
        fail "deep-research: unreadable file (rc=$RC, err=$ERR)"
    fi
    chmod 644 "$VR_UNREADABLE"
fi

# --- 5. git-workflow analyze-changes.sh ----------------------------------------

AC_SCRIPT="${REPO_ROOT}/ycc/skills/git-workflow/scripts/analyze-changes.sh"

make_git_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" commit -q --allow-empty -m init
}

# Zero-match case: dirs "." (top-level file) and "pkg" both appear in
# "Changed Directories"; for dir "." the fixed-string prefix "./" matches zero
# lines in ALL_CHANGED_FILES (paths are relative, never start with "./").
AC_ZERO="${SCRATCH}/ac-zero"
make_git_repo "$AC_ZERO"
mkdir -p "$AC_ZERO/pkg"
printf 'top\n' >"$AC_ZERO/toplevel.ts"
printf 'pkg\n' >"$AC_ZERO/pkg/mod.ts"
git -C "$AC_ZERO" add -A
git -C "$AC_ZERO" commit -q -m 'seed'
printf 'y\n' >>"$AC_ZERO/toplevel.ts"
printf 'y\n' >>"$AC_ZERO/pkg/mod.ts"
run_capture ac-zero -- bash -c "cd '$AC_ZERO' && bash '$AC_SCRIPT'"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == *'- ./ (0 files)'* ]]; then
    pass "analyze-changes: zero-match dir -> single 0"
else
    fail "analyze-changes: zero-match dir (rc=$RC, out=$OUT)"
fi
assert_not_contains "analyze-changes: no arithmetic noise" "integer expression expected" "${OUT}${ERR}"
assert_no_bare_zero "analyze-changes" "$OUT"

# Some-matches case: two files under src/, one elsewhere.
AC_SOME="${SCRATCH}/ac-some"
make_git_repo "$AC_SOME"
mkdir -p "$AC_SOME/src" "$AC_SOME/lib"
printf 'a\n' >"$AC_SOME/src/a.ts"
printf 'b\n' >"$AC_SOME/src/b.ts"
printf 'c\n' >"$AC_SOME/lib/c.ts"
git -C "$AC_SOME" add -A
git -C "$AC_SOME" commit -q -m 'seed'
printf 'z\n' >>"$AC_SOME/src/a.ts"
printf 'z\n' >>"$AC_SOME/src/b.ts"
printf 'z\n' >>"$AC_SOME/lib/c.ts"
run_capture ac-some -- bash -c "cd '$AC_SOME' && bash '$AC_SCRIPT'"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == *'- src/ (2 files)'* ]]; then
    pass "analyze-changes: src/ counted as 2"
else
    fail "analyze-changes: src/ count (rc=$RC, out=$OUT)"
fi

# Bracketed directory name: `app/[[...slug]]` must be counted literally, not
# treated as a regex (the old grep site aborted with exit 2 on this).
AC_BRACKET="${SCRATCH}/ac-bracket"
make_git_repo "$AC_BRACKET"
mkdir -p "${AC_BRACKET}/app/[[...slug]]"
printf 'page\n' >"${AC_BRACKET}/app/[[...slug]]/page.ts"
printf 'other\n' >"$AC_BRACKET/top.ts"
git -C "$AC_BRACKET" add -A
git -C "$AC_BRACKET" commit -q -m 'seed'
printf 'z\n' >>"${AC_BRACKET}/app/[[...slug]]/page.ts"
printf 'z\n' >>"$AC_BRACKET/top.ts"
run_capture ac-bracket -- bash -c "cd '$AC_BRACKET' && bash '$AC_SCRIPT'"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == *'- app/[[...slug]]/ (1 files)'* ]]; then
    pass "analyze-changes: bracketed dir counted literally"
else
    fail "analyze-changes: bracketed dir (rc=$RC, out=$OUT)"
fi
assert_not_contains "analyze-changes: no bracket regex noise" "Unmatched" "${OUT}${ERR}"

# Non-source category statuses must not trigger errexit at either call site.
AC_MIXED="${SCRATCH}/ac-mixed"
make_git_repo "$AC_MIXED"
mkdir -p "$AC_MIXED/src" "$AC_MIXED/tests" "$AC_MIXED/docs"
printf 'source\n' >"$AC_MIXED/src/a.ts"
printf 'test\n' >"$AC_MIXED/tests/a.test.ts"
printf '# Docs\n' >"$AC_MIXED/docs/x.md"
printf '{}\n' >"$AC_MIXED/config.json"
run_capture ac-mixed -- bash -c "cd '$AC_MIXED' && bash '$AC_SCRIPT'"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == *'=== Recommendations ==='* ]]; then
    pass "analyze-changes: mixed categories complete without errexit"
else
    fail "analyze-changes: mixed categories (rc=$RC, err=$ERR)"
fi
assert_count_line "analyze-changes: mixed source count" "$OUT" '  Source files: *' "1"
assert_count_line "analyze-changes: mixed test count" "$OUT" '  Test files: *' "1"
assert_count_line "analyze-changes: mixed doc count" "$OUT" '  Doc files: *' "1"
assert_count_line "analyze-changes: mixed config count" "$OUT" '  Config files: *' "1"

# src/ sorts first, so `grep -q` matches on the first line while the rest of the
# list is still unwritten. The old `echo "$ALL" | grep -qE` idiom only dies of
# SIGPIPE if >= pipe capacity (64 KiB) plus grep's first read buffer is still
# pending, so keep >= 256 KiB after the first match. Nested 200-char directory
# names (~620-byte paths) keep the file count — and the per-file forks in
# analyze-changes — small. Just two top-level directories avoid unrelated
# head-truncation pipelines in the script.
AC_LARGE="${SCRATCH}/ac-large"
make_git_repo "$AC_LARGE"
mkdir -p "$AC_LARGE/src"
printf 'source\n' >"$AC_LARGE/src/a.ts"
printf -v ac_padding '%0200d' 0
ac_deep="$AC_LARGE/zzz/${ac_padding}/${ac_padding}/${ac_padding}"
mkdir -p "$ac_deep"
for ((ac_i=0; ac_i<500; ac_i++)); do
    printf -v ac_name '%04d.ts' "$ac_i"
    printf 'source\n' >"$ac_deep/$ac_name"
done
ac_list=$(git -C "$AC_LARGE" ls-files --others --exclude-standard | sort -u)
# Parameter expansion, not head/wc pipes: a pipe from printf would itself be
# SIGPIPE-prone under pipefail for a list this large. Names are ASCII, so
# character counts equal byte counts.
ac_first="${ac_list%%$'\n'*}"
ac_after=$((${#ac_list} - ${#ac_first}))
if [[ "$ac_after" -ge 262144 ]] && [[ "$ac_list" == src/a.ts$'\n'* ]]; then
    pass "analyze-changes: >= 256 KiB follows the first src/ match ($ac_after bytes)"
else
    fail "analyze-changes: fixture too small or src/ not first ($ac_after bytes after first match)"
fi
# Control: the pre-fix idiom must really die of SIGPIPE on this exact list, so
# the fixture proves the regression without reading old code from git.
ac_old_rc=0
( set -o pipefail; echo "$ac_list" | grep -qE '^(src/|lib/|app/)' ) || ac_old_rc=$?
if [[ "$ac_old_rc" -gt 128 ]]; then
    pass "analyze-changes: control: old echo|grep -q idiom dies of SIGPIPE on the fixture (rc=$ac_old_rc)"
else
    fail "analyze-changes: control: old echo|grep -q idiom did not SIGPIPE (rc=$ac_old_rc)"
fi
run_capture ac-large -- bash -c "cd '$AC_LARGE' && bash '$AC_SCRIPT'"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == *'Documentation Consideration:'* ]]; then
    pass "analyze-changes: large change set detects early src/ path"
else
    fail "analyze-changes: large change set misses src/ path (rc=$RC, err=$ERR)"
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

# --- 7. prp-implement snippet lines, extracted from the docs -------------------
# The snippet lines live in ycc/skills/prp-implement/SKILL.md and
# references/detection.md. Extract them with grep (never a hand copy) and run
# them exactly as documented. The runner takes the plan path as $1 and the
# extracted snippet file as $2.
# shellcheck disable=SC2016 # single quotes are intentional: $1/$2 are the
# bash -c positional args of the snippet runner, not this script's.
SNIPPET_RUNNER='PLAN_PATH="$1"; source "$2"'
SKILL_MD="${REPO_ROOT}/ycc/skills/prp-implement/SKILL.md"
DETECTION_MD="${REPO_ROOT}/ycc/skills/prp-implement/references/detection.md"
SNIPPET_BODY="${SCRATCH}/snippet-body.sh"

grep -E '^grep -c .*\[ \$\? -le 1 \]$' "$SKILL_MD" >"$SNIPPET_BODY"
grep -E '^grep -c .*\[ \$\? -le 1 \]$' "$DETECTION_MD" >>"$SNIPPET_BODY"

if [[ "$(grep -c . "$SNIPPET_BODY")" -eq 3 ]]; then
    pass "snippet: extracted 3 documented grep lines (2 SKILL.md + 1 detection.md)"
else
    fail "snippet: expected 3 documented grep lines, got: $(cat "$SNIPPET_BODY")"
fi

# Zero matches across all three patterns -> one integer per line, rc 0.
SNIPPET_PLAN="${SCRATCH}/snippet-plan.md"
printf '# Plan\n\nNo worktree or batch annotations.\n' >"$SNIPPET_PLAN"
run_capture snippet-zero -- bash -c "$SNIPPET_RUNNER" _ "$SNIPPET_PLAN" "$SNIPPET_BODY"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == $'0\n0\n0' ]]; then
    pass "snippet: zero matches -> one integer per line (0,0,0)"
else
    fail "snippet: zero matches (rc=$RC, out='$OUT')"
fi

# One match for each pattern.
SNIPPET_PLAN2="${SCRATCH}/snippet-plan2.md"
printf '## Worktree Setup\n- **Worktree**: x\n## Batches\n' >"$SNIPPET_PLAN2"
run_capture snippet-some -- bash -c "$SNIPPET_RUNNER" _ "$SNIPPET_PLAN2" "$SNIPPET_BODY"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == $'1\n1\n1' ]]; then
    pass "snippet: one match each -> 1,1,1"
else
    fail "snippet: one match each (rc=$RC, out='$OUT')"
fi

# Missing plan file: grep exit 2 makes the line fail; no integer on stdout.
run_capture snippet-missing -- bash -c "$SNIPPET_RUNNER" _ "${SCRATCH}/no-such-plan.md" "$SNIPPET_BODY"
if [[ "$RC" -ne 0 ]] && [[ -z "$OUT" ]]; then
    pass "snippet: missing file -> non-zero rc, empty stdout"
else
    fail "snippet: missing file (rc=$RC, out='$OUT')"
fi

# --- summary -------------------------------------------------------------------

if [[ "$FAILED" -ne 0 ]]; then
    echo "test-grep-count-helpers.sh: FAILED" >&2
    exit 1
fi
echo "test-grep-count-helpers.sh: all checks passed"
