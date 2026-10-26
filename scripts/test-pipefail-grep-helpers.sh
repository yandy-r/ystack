#!/usr/bin/env bash
# test-pipefail-grep-helpers.sh — `echo | grep -q` / `| head` pipefail
# regressions (YAN-1587 / GH #472).
#
# Under `set -o pipefail`, `echo "$X" | grep -q PAT` reports a match as a miss
# once the match sits before enough trailing bytes to overflow the 64 KiB pipe
# buffer: grep exits on first match, the echo writer dies with SIGPIPE (141),
# and pipefail fails the condition. The same race aborts `cmd | head -N` under
# `set -e` when cmd has more than N lines to write. The fixed helpers match
# with here-strings (`grep -q PAT <<<"$X"`) or capture the full output before
# trimming, so no writer process exists to SIGPIPE.
#
# Each regression fixture puts the content that must be found FIRST and pads
# with >= 256 KiB of filler AFTER it (well past the pipe buffer plus grep's
# read size), so the early-exiting reader quits while the writer is still
# blocked on a full pipe. Every regression fixture also carries an inline
# CONTROL: the old idiom, run under pipefail against the same fixture, must
# fail. A fixture that stops triggering SIGPIPE therefore fails the suite
# instead of silently turning into a smoke test. Nothing reads pre-fix code
# from git history, so the suite behaves the same before and after the fix is
# committed.
#
# Regression-covered (control proves the old idiom fails on the fixture):
#   - feature-research validate-spec.sh            (required sections)
#   - clean validate-safety.sh                     (protected dirs/files)
#   - git-workflow validate-commit.sh              (BREAKING CHANGE footer and
#     first-line extraction; the message is capped by the kernel's 128 KiB
#     single-argument limit, so the race is probabilistic per run: the control
#     retries until it fires and the helper is run repeatedly)
#   - _shared lib/ci-classify.sh                   (classify_failure)
#   - git-workflow create-pr.sh                    (breaking-change scan;
#     scratch git repo + fake gh on PATH, analyze mode, no network)
#   - write-docs audit-documentation.sh            (find | head -N limits)
#
# Smoke only (these helpers pass on the pre-fix code too; the cases pin the
# converted behavior but are NOT regression tests):
#   - _shared validate-file-paths.sh               (CREATE skip column)
#   - hooks-workflow verify-hooks.sh               (advisory comment, codex)
#   - research-to-issues validate-prerequisites.sh (content-based type detect)
#   - compatibility-audit audit-target-features.sh (--help)
# The old_* control functions are invoked indirectly through control_sigpipes.
# shellcheck disable=SC2317
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ycc-pipefail-grep.XXXXXX")"
trap 'chmod -R u+rwx "$SCRATCH" 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT

# Resolve the real git before any PATH edits (case 9 shadows git with a stub).
REAL_GIT="$(command -v git)"

# Git hooks (pre-push runs validate.sh) export GIT_DIR and friends; left set,
# they would point every scratch `git` call at the caller's repository —
# polluting its refs, worktree registrations, and config. Clear them all before
# any git operation, then pin git to a scratch config so neither system nor
# global config is read or written (same isolation as test-grep-count-helpers.sh).
while IFS= read -r git_var; do
    unset "$git_var"
done < <("$REAL_GIT" rev-parse --local-env-vars)
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

# control_sigpipes <label> <attempts> <fn> — run the OLD idiom <fn> (a shell
# function that ends in the early-exiting reader) under pipefail up to
# <attempts> times; pass as soon as one run fails (SIGPIPE'd writer -> 141).
# If it never fails the fixture does not trigger the race and the regression
# case would be a smoke test, so the suite fails.
control_sigpipes() {
    local label="$1" attempts="$2" fn="$3" i=0
    while (( i < attempts )); do
        if ! ( set -o pipefail; "$fn" ) >/dev/null 2>&1; then
            pass "${label}: old idiom fails under pipefail on this fixture (control)"
            return 0
        fi
        i=$((i + 1))
    done
    fail "${label}: fixture does not trigger SIGPIPE (old idiom still matches)"
}

# marker_lines <n> — n filler lines of 74 bytes each (4000 lines = 296,000
# bytes, past the 256 KiB the regression fixtures put after the match).
marker_lines() {
    awk -v n="$1" 'BEGIN {
        for (i = 0; i < n; i++)
            printf "filler line %06d aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", i
    }'
}

# --- 1. feature-research validate-spec.sh -------------------------------------
# Required sections sit at the top; >256 KiB of filler follows, so the old
# `echo "$CONTENT" | grep -q "^## …"` SIGPIPEs on the very first check.

VS_NEW="${REPO_ROOT}/ycc/skills/feature-research/scripts/validate-spec.sh"
VS_DIR="${SCRATCH}/vs"
mkdir -p "$VS_DIR"
{
    printf '# Feature Spec: Big Fixture\n'
    printf '## Executive Summary\n\nSummary text.\n\n'
    printf '## External Dependencies\n\nDependencies text.\n\n'
    printf '## Business Requirements\n\n### User Stories\n\nStories text.\n\n'
    printf '## Technical Specifications\n\n### Architecture\n\nArchitecture text.\n\n'
    printf '## UX Considerations\n\nUX text.\n\n'
    printf '## Recommendations\n\nRecommendations text.\n\n'
    printf '## Risk Assessment\n\n### Security Considerations\n\nRisk text.\n\n'
    printf '## Task Breakdown Preview\n\nTasks text.\n\n'
    marker_lines 4000
} >"${VS_DIR}/feature-spec.md"
VS_BYTES=$(wc -c <"${VS_DIR}/feature-spec.md")

VS_CONTENT="$(cat "${VS_DIR}/feature-spec.md")"
old_vs() { echo "$VS_CONTENT" | grep -q '^## Executive Summary'; }
control_sigpipes "validate-spec" 5 old_vs

run_capture vs-new -- bash "$VS_NEW" "${VS_DIR}/feature-spec.md"
if [[ "$OUT" == *'Found: ## External Dependencies'* ]] \
    && [[ "$OUT" != *'Missing required section'* ]]; then
    pass "validate-spec: ${VS_BYTES}B spec finds required sections"
else
    fail "validate-spec: required sections missed (rc=$RC err=$ERR)"
fi

# --- 2. clean validate-safety.sh ----------------------------------------------
# The protected node_modules/README rows lead; ~300 KB of 200-byte-path filler
# rows follow, so FLAGGED_FILES carries >256 KiB after the match and the old
# `echo "$FLAGGED_FILES" | grep -q …` SIGPIPEs on both protected-entry scans.
# (Long paths keep the row count, and the helper's per-row path loop, small.)

VSY_NEW="${REPO_ROOT}/ycc/skills/clean/scripts/validate-safety.sh"
VSY_DIR="${SCRATCH}/vsy"
mkdir -p "${VSY_DIR}/report"
{
    printf '# Cleanup Report\n\n'
    printf '| File Path | Reason | Size |\n'
    printf '|---|---|---|\n'
    printf '| node_modules/pkg/index.js | vendor | 1 KB |\n'
    printf '| README.md | doc | 1 KB |\n'
    awk 'BEGIN {
        pad = sprintf("%190s", ""); gsub(/ /, "x", pad)
        for (i = 0; i < 1500; i++)
            printf "| tmp/%s-%05d.log | stale | 1 KB |\n", pad, i
    }'
} >"${VSY_DIR}/report/cleanup-report.md"
VSY_BYTES=$(wc -c <"${VSY_DIR}/report/cleanup-report.md")

# Same extraction pipeline the helper uses to build FLAGGED_FILES.
VSY_FLAGGED="$(grep -E '^\|.*\|.*\|.*\|' "${VSY_DIR}/report/cleanup-report.md" \
    | grep -v '^|---' | grep -v '^| File Path' | cut -d'|' -f2 | tr -d ' ' \
    | grep -v '^$' || true)"
old_vsy_dir() { echo "$VSY_FLAGGED" | grep -q "/node_modules/\|^node_modules/"; }
old_vsy_file() { echo "$VSY_FLAGGED" | grep -qE "(^|/)README.md$"; }
control_sigpipes "validate-safety (directory scan)" 5 old_vsy_dir
control_sigpipes "validate-safety (file scan)" 5 old_vsy_file

run_capture vsy-new -- bash "$VSY_NEW" "${VSY_DIR}/report/cleanup-report.md"
if [[ "$RC" -ne 0 ]] && [[ "$OUT" == *'Protected directory found in removal list: node_modules'* ]] \
    && [[ "$OUT" == *'Protected file found in removal list: README.md'* ]]; then
    pass "validate-safety: ${VSY_BYTES}B report flags protected entries"
else
    fail "validate-safety: protected entries missed (rc=$RC, out=$OUT)"
fi

# --- 3. _shared validate-file-paths.sh (smoke) --------------------------------
# One table row is small, so no SIGPIPE is possible on this site (the old code
# passes too); the case only pins the CREATE-skip behavior on a large section.
# The helper sources resolve-plans-dir.sh, which walks up from the cwd for a
# .plans-config or .git; a local-scope .plans-config in the fixture pins
# PLANS_ROOT to the scratch dir regardless of what exists above $TMPDIR.

VFP_NEW="${REPO_ROOT}/ycc/skills/_shared/scripts/validate-file-paths.sh"
VFP_DIR="${SCRATCH}/vfp"
mkdir -p "${VFP_DIR}/src"
printf 'plans_dir: docs/plans\nscope: local\n' >"${VFP_DIR}/.plans-config"
{
    printf '# Plan\n\n## Files to Change\n\n'
    printf '| File | Action | Notes |\n'
    printf '|---|---|---|\n'
    printf '| %s | EDIT | keep |\n' "\`src/existing.ts\`"
    printf '| %s | create | add |\n' "\`src/new-file.ts\`"
    marker_lines 1100
} >"${VFP_DIR}/plan.md"
printf 'content\n' >"${VFP_DIR}/src/existing.ts"
VFP_BYTES=$(wc -c <"${VFP_DIR}/plan.md")

run_capture vfp-new -- bash -c "cd '$VFP_DIR' && PLANS_ROOT='$VFP_DIR' '$VFP_NEW' plan.md --skip-create"
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == *'SKIP src/new-file.ts'* ]] \
    && [[ "$OUT" == *"VALID=1 INVALID=0 SKIPPED=1"* ]]; then
    pass "validate-file-paths (smoke): ${VFP_BYTES}B table skips CREATE row, validates EDIT row"
else
    fail "validate-file-paths (smoke): CREATE/EDIT handling broke (rc=$RC, out=$OUT)"
fi

# --- 4. git-workflow validate-commit.sh ---------------------------------------
# BREAKING CHANGE footer early in the body, filler after: the old
# `echo "$COMMIT_MSG" | grep -qE 'BREAKING CHANGE:'` SIGPIPEs, and the old
# `SUBJECT=$(echo "$COMMIT_MSG" | head -n1)` aborts outright under errexit.
# The message travels as one argv string, which the kernel caps at 128 KiB
# (MAX_ARG_STRLEN), so it cannot reach the 256 KiB the other fixtures use and
# the race is probabilistic per run (roughly one in four). The controls retry
# until the old idiom fails; the helper is then run many times so a leftover
# old idiom would be caught with overwhelming probability.

VC_NEW="${REPO_ROOT}/ycc/skills/git-workflow/scripts/validate-commit.sh"
{
    printf 'feat: big feature\n'
    printf 'BREAKING CHANGE: the api changed\n'
    marker_lines 1750
} >"${SCRATCH}/vc-msg.txt"
VC_MSG="$(cat "${SCRATCH}/vc-msg.txt")"
VC_BYTES=${#VC_MSG}

old_vc_grep() { echo "$VC_MSG" | grep -qE 'BREAKING CHANGE:'; }
old_vc_head() { local s; s=$(echo "$VC_MSG" | head -n1); }
control_sigpipes "validate-commit (footer grep)" 400 old_vc_grep
control_sigpipes "validate-commit (subject head -n1)" 400 old_vc_head

VC_RUNS=40
vc_ok=1
vc_run=0
while (( vc_run < VC_RUNS )); do
    run_capture vc-new -- bash "$VC_NEW" "$VC_MSG"
    if [[ "$OUT" != *'✓ Format matches conventional commits'* ]] \
        || [[ "$OUT" != *'⚠ Breaking change footer detected'* ]] \
        || [[ "$OUT" != *'✓ BREAKING CHANGE footer is properly formatted'* ]]; then
        vc_ok=0
        break
    fi
    vc_run=$((vc_run + 1))
done
if (( vc_ok )); then
    pass "validate-commit: ${VC_BYTES}B message detects format + early footer (${VC_RUNS} runs)"
else
    fail "validate-commit: footer missed on run $((vc_run + 1)) (rc=$RC, out=$OUT, err=$ERR)"
fi

# --- 5. hooks-workflow verify-hooks.sh (smoke) --------------------------------
# The converted site matches a single `head -1` line, so no SIGPIPE is
# possible (the old code passes too); the case pins the advisory-comment
# detection on a large config.

VH_NEW="${REPO_ROOT}/ycc/skills/hooks-workflow/scripts/verify-hooks.sh"
VH_FILE="${SCRATCH}/advisory.toml"
{
    printf '# Advisory only: hooks are parse-checked, not executed.\n'
    marker_lines 1100 | sed 's/^/# /'
    printf '# end\n'
} >"$VH_FILE"
VH_BYTES=$(wc -c <"$VH_FILE")

run_capture vh-new -- bash "$VH_NEW" "$VH_FILE" --target=codex
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == *'advisory-comment PASS'* ]]; then
    pass "verify-hooks (smoke): ${VH_BYTES}B config still detects advisory comment"
else
    fail "verify-hooks (smoke): advisory comment missed (rc=$RC, out=$OUT, err=$ERR)"
fi

# --- 6. research-to-issues validate-prerequisites.sh (smoke) ------------------
# HEAD_CONTENT is built with `head -40 <file>` (no pipe writer), so the old
# code passes too; the case pins the content-based detection on a large file.

VP_NEW="${REPO_ROOT}/ycc/skills/research-to-issues/scripts/validate-prerequisites.sh"
VP_DIR="${SCRATCH}/vp"
mkdir -p "$VP_DIR"
"$REAL_GIT" -C "$VP_DIR" init -q
{
    printf '## Critically Relevant Files\n\n'
    marker_lines 1100
} >"${VP_DIR}/notes.md"
VP_BYTES=$(wc -c <"${VP_DIR}/notes.md")

run_capture vp-new -- bash -c "cd '$VP_DIR' && '$VP_NEW' notes.md"
if [[ "$OUT" == *'DETECTED_TYPE: parallel-plan'* ]]; then
    pass "validate-prerequisites (smoke): ${VP_BYTES}B source still detected as parallel-plan"
else
    fail "validate-prerequisites (smoke): detection missed (rc=$RC, out=$OUT)"
fi

# --- 7. _shared lib/ci-classify.sh (sourced) ----------------------------------
# The signature line leads the log; the old `printf | grep -qiE` SIGPIPEs on
# the matching category probe and classify_failure falls through to 'unknown'.

CIC_NEW="${REPO_ROOT}/ycc/skills/_shared/scripts/lib/ci-classify.sh"
classify_run() {
    local helper="$1" log_file="$2"
    bash -c 'set -euo pipefail
             source "$1"
             classify_failure "$(cat "$2")"' _ "$helper" "$log_file"
}

# classify_case <tag> <needle> <expected-category>
classify_case() {
    local tag="$1" needle="$2" label="$3"
    local log_file="${SCRATCH}/ci-log-${tag}.txt"
    {
        printf 'job  step  2026-10-25T00:00:00Z  %s\n' "$needle"
        marker_lines 4000
    } >"$log_file"
    local bytes out
    bytes=$(wc -c <"$log_file")
    CIC_CONTENT="$(cat "$log_file")"
    CIC_NEEDLE="$needle"
    control_sigpipes "ci-classify[${tag}]" 5 old_ci
    out="$(classify_run "$CIC_NEW" "$log_file")"
    if [[ "$out" == "$label" ]]; then
        pass "ci-classify[${tag}]: ${bytes}B log classifies as ${label}"
    else
        fail "ci-classify[${tag}]: expected '${label}', got '${out}'"
    fi
}
old_ci() { printf '%s\n' "$CIC_CONTENT" | grep -qiF -- "$CIC_NEEDLE"; }

classify_case lint 'eslint found an error: SC1234' 'lint'
classify_case build 'npm run build failed' 'build'
classify_case integration 'cypress e2e suite crashed' 'integration-test'
classify_case flake 'connection refused ETIMEDOUT' 'flake-suspected'

# --- 8. compatibility-audit audit-target-features.sh (smoke) ------------------
# The converted site is a belt-and-suspenders PARSE_ERROR check on python
# output; a full matrix parse needs the repo layout, so this is a --help smoke.

ATF_NEW="${REPO_ROOT}/ycc/skills/compatibility-audit/scripts/audit-target-features.sh"
run_capture atf-new -- bash "$ATF_NEW" --help
if [[ "$RC" -eq 0 ]] && [[ "$OUT" == *'audit-target-features.sh'* ]]; then
    pass "audit-target-features (smoke): --help after here-string conversion"
else
    fail "audit-target-features (smoke): --help failed (rc=$RC)"
fi

# --- 9. git-workflow create-pr.sh (analyze mode, scratch repo) ----------------
# The breaking-change scan is `git log --format=%B | grep -qE` in the original:
# git log is the writer, the early match makes grep quit, git log dies with
# SIGPIPE and pipefail reports no breaking changes. The fix captures the log
# first. Drive analyze mode with a fake gh on PATH; no network is touched
# (forge detection reads `git remote get-url` only).

CPR_NEW="${REPO_ROOT}/ycc/skills/git-workflow/scripts/create-pr.sh"
CPR_DIR="${SCRATCH}/cpr"
mkdir -p "$CPR_DIR"
# github.com URL so forge detection picks github/gh (stubbed below); the
# pushed-branch probe is a stubbed `git ls-remote`, and origin/main comes from
# update-ref, so nothing touches the network.
"$REAL_GIT" -C "$CPR_DIR" init -q
"$REAL_GIT" -C "$CPR_DIR" remote add origin https://github.com/example/repo.git
"$REAL_GIT" -C "$CPR_DIR" commit -q --allow-empty -m 'feat: seed'
"$REAL_GIT" -C "$CPR_DIR" update-ref refs/remotes/origin/main "$("$REAL_GIT" -C "$CPR_DIR" rev-parse HEAD)"
"$REAL_GIT" -C "$CPR_DIR" checkout -q -b feature
{
    printf 'feat: big change\n'
    printf 'BREAKING CHANGE: behavior changed\n'
    marker_lines 4000
} >"${CPR_DIR}/msg.txt"
"$REAL_GIT" -C "$CPR_DIR" commit -q --allow-empty -F "${CPR_DIR}/msg.txt"
CPR_BYTES=$(wc -c <"${CPR_DIR}/msg.txt")

old_cpr() { "$REAL_GIT" -C "$CPR_DIR" log --format=%B | grep -qE 'BREAKING CHANGE:|^[a-z]+(\([a-z0-9-]+\))?!:'; }
control_sigpipes "create-pr" 5 old_cpr

# Stub gh (auth/status probes succeed) and wrap git so `ls-remote` for the
# pushed-branch probe answers offline with the local HEAD; everything else
# delegates to the real git (resolved before PATH was edited).
FAKE_BIN="${SCRATCH}/bin"
mkdir -p "$FAKE_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' >"${FAKE_BIN}/gh"
chmod +x "${FAKE_BIN}/gh"
cat >"${FAKE_BIN}/git" <<GITSTUB
#!/usr/bin/env bash
if [[ "\$1" == "ls-remote" ]]; then
    # print one head so the pushed-branch gate passes, then stop
    printf '%s\t%s\n' "\$("${REAL_GIT}" -C "\${CPR_DIR}" rev-parse HEAD)" refs/heads/feature
    exit 0
fi
exec "${REAL_GIT}" "\$@"
GITSTUB
chmod +x "${FAKE_BIN}/git"

run_capture cpr-new -- bash -c "cd '$CPR_DIR' && CPR_DIR='$CPR_DIR' PATH='$FAKE_BIN':\$PATH '$CPR_NEW' --analyze --base main"
if [[ "$OUT" == *'Breaking changes detected'* ]] \
    && [[ "$OUT" == *'BREAKING CHANGE: behavior changed'* ]] \
    && [[ "$OUT" != *'No breaking changes detected'* ]]; then
    pass "create-pr: early BREAKING CHANGE in ${CPR_BYTES}B log detected"
else
    fail "create-pr: breaking change missed (rc=$RC, out=$(printf '%s' "$OUT" | tail -c 400), err=$ERR)"
fi

# --- 10. write-docs audit-documentation.sh ------------------------------------
# `find … | head -50` / `| head -100` abort the audit under errexit+pipefail
# once find has more output than head reads. The fixture holds 700 markdown
# and 700 JS files under 400-byte-long paths (≈290 KB of find output each), so
# find is still writing when head exits. A stub `tree` that fails forces the
# `find | head -50` fallback branch regardless of whether tree is installed.

AD_NEW="${REPO_ROOT}/ycc/skills/write-docs/scripts/audit-documentation.sh"
AD_DIR="${SCRATCH}/ad"
AD_LONG1="$(printf '%0200d' 0 | tr 0 d)"
AD_LONG2="$(printf '%0200d' 0 | tr 0 e)"
mkdir -p "${AD_DIR}/docs/${AD_LONG1}/${AD_LONG2}" "${AD_DIR}/src/${AD_LONG1}/${AD_LONG2}"
awk -v d="${AD_DIR}/docs/${AD_LONG1}/${AD_LONG2}" 'BEGIN { for (i = 0; i < 700; i++) printf "%s/f-%04d.md\n", d, i }' | xargs touch
# The JS files carry a JSDoc tag: the helper's `xargs grep -l … | wc -l`
# count aborts under pipefail when no scanned file matches (xargs exits 123),
# which is a separate behavior from the head-limit race under test.
# shellcheck disable=SC2016  # the loop body is expanded by the inner sh
awk -v d="${AD_DIR}/src/${AD_LONG1}/${AD_LONG2}" 'BEGIN { for (i = 0; i < 700; i++) printf "%s/f-%04d.js\n", d, i }' \
    | xargs -n 100 sh -c 'for f; do printf "// @param x\n" >"$f"; done' _
AD_BIN="${SCRATCH}/ad-bin"
mkdir -p "$AD_BIN"
printf '#!/usr/bin/env bash\nexit 1\n' >"${AD_BIN}/tree"
chmod +x "${AD_BIN}/tree"

old_ad_docs() { cd "$AD_DIR" && find docs -type f -name '*.md' | head -n 50 >/dev/null; }
old_ad_js() { cd "$AD_DIR" && find . -type f \( -name '*.js' -o -name '*.ts' \) | head -n 100 >/dev/null; }
control_sigpipes "audit-documentation (docs listing)" 5 old_ad_docs
control_sigpipes "audit-documentation (js scan)" 5 old_ad_js

run_capture ad-new -- bash -c "cd '$AD_DIR' && PATH='$AD_BIN':\$PATH '$AD_NEW'"
if [[ "$RC" -eq 0 ]] \
    && [[ "$OUT" == *'**Total markdown files in docs/**: 700'* ]] \
    && [[ "$OUT" == *'- Files scanned: 100'* ]] \
    && [[ "$OUT" == *'*Audit complete*'* ]]; then
    pass "audit-documentation: >limit files complete the audit and honor the 50/100 caps"
else
    fail "audit-documentation: audit aborted or miscounted (rc=$RC, err=$ERR, out=$(printf '%s' "$OUT" | tail -c 400))"
fi

# --- Summary ------------------------------------------------------------------

echo ""
if [[ "$FAILED" -eq 0 ]]; then
    echo "test-pipefail-grep-helpers: ALL PASSED"
    exit 0
fi
echo "test-pipefail-grep-helpers: FAILURES PRESENT" >&2
exit 1
