#!/usr/bin/env bash
# Regression checks for validate-workflow-plan.sh and validate-shared.sh
# Usage: scripts/test-plan-workflow-validators.sh
# - temp fixtures via mktemp, trap cleanup; no test framework
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../ycc/skills/plan-workflow/scripts" && pwd)"
VAL_PLAN="${SCRIPT_DIR}/validate-workflow-plan.sh"
VAL_SHARED="${SCRIPT_DIR}/validate-shared.sh"
FAIL=0

ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- structurally complete plan fixture ---
cat > "${TMP}/good.md" <<'EOF'
# Feature X

This overview sentence one. Sentence two here. Sentence three here. Sentence four here. Sentence five here. Sentence six here. Sentence seven here. Sentence eight here.

## Critically Relevant Files

- src/a.ts
- src/b.ts

## Worktree Setup

- **Parent**: repo/.claude/worktrees/repo-x/ (branch: feat/x)

## Implementation Plan

### Phase 1: Foundation

#### Task 1.1: Build

Depends on [none]

READ THESE BEFORE TASK

Files to Create

Files to Modify

#### Task 1.2: Wire

Depends on [1.1]

READ THESE BEFORE TASK

Files to Create

Files to Modify

## Advice

- keep it simple
EOF

out="$("${VAL_PLAN}" "${TMP}/good.md" 2>&1)"
rc=$?
if [[ $rc -eq 0 ]]; then ok "valid plan exits 0"; else bad "valid plan exits 0 (got $rc)"; printf '%s\n' "$out"; fi
if grep -qiE "syntax error|command not found|unbound variable|bad substitution" <<<"$out"; then
  bad "stderr has shell/arithmetic syntax errors"
  printf '%s\n' "$out"
else
  ok "no arithmetic/syntax errors in stderr"
fi

# --- large valid plan (YAN-1285 / GH #469) ---
# Content larger than a pipe buffer: an early-exiting reader (grep -q, head -5)
# used to SIGPIPE the `echo "$CONTENT"` writer, and pipefail turned a present
# section into "missing". Small plans only lost the race under load.
{
  cat "${TMP}/good.md"
  for i in $(seq 1 20000); do echo "- advice line ${i}"; done
} > "${TMP}/large.md"
out_large="$("${VAL_PLAN}" "${TMP}/large.md" 2>&1)"
rc_large=$?
if [[ $rc_large -eq 0 ]]; then
  ok "large valid plan exits 0"
else
  bad "large valid plan exits 0 (got $rc_large)"
  printf '%s\n' "$out_large" | grep -vE '^- advice line' || true
fi

# --- missing ### Phase ---
sed '/^### Phase/d' "${TMP}/good.md" > "${TMP}/nophase.md"
"${VAL_PLAN}" "${TMP}/nophase.md" >/dev/null 2>&1
if [[ $? -ne 0 ]]; then ok "missing ### Phase exits nonzero"; else bad "missing ### Phase exits nonzero"; fi

# --- missing #### Task ---
sed '/^#### Task/d; s/Depends on \[[^]]*\]/Depends on [none]/g' "${TMP}/good.md" > "${TMP}/notask.md"
"${VAL_PLAN}" "${TMP}/notask.md" >/dev/null 2>&1
if [[ $? -ne 0 ]]; then ok "missing #### Task exits nonzero"; else bad "missing #### Task exits nonzero"; fi

# --- zero-match counts still compute (regression for the || echo "0" bug) ---
sed '/^- src/d' "${TMP}/good.md" > "${TMP}/nofiles.md"
out2="$("${VAL_PLAN}" "${TMP}/nofiles.md" 2>&1)"
if grep -qiE "syntax error|command not found|unbound variable|bad substitution" <<<"$out2"; then
  bad "zero-match counts still compute"
  printf '%s\n' "$out2"
else
  ok "zero-match counts still compute"
fi

# --- validate-shared zero-warning path ---
cat > "${TMP}/shared.md" <<'EOF'
# Shared X

Overview sentence one. Sentence two here. Sentence three here. Sentence four here and more words here.

## Relevant Files

- src/a.ts - core module

## Relevant Patterns

- **Repo**: the repo pattern (/src/a.ts) — see [code](src/a.ts)

## Relevant Docs

- You _must_ read this doc first.
EOF
out3="$("${VAL_SHARED}" "${TMP}/shared.md" 2>&1)"
rc3=$?
if grep -qiE "syntax error|command not found|unbound variable|bad substitution" <<<"$out3"; then
  bad "validate-shared zero-warning path errors"
  printf '%s\n' "$out3"
else
  ok "validate-shared zero-warning path clean (exit $rc3)"
fi

# --- large shared doc (YAN-1285): same SIGPIPE race in validate-shared.sh ---
{
  cat "${TMP}/shared.md"
  for i in $(seq 1 20000); do echo "- doc note ${i}"; done
} > "${TMP}/shared-large.md"
out4="$("${VAL_SHARED}" "${TMP}/shared-large.md" 2>&1)"
if grep -qE "Missing (required section|document title)" <<<"$out4"; then
  bad "large shared doc keeps its title and sections"
  grep -E "Missing" <<<"$out4" || true
else
  ok "large shared doc keeps its title and sections"
fi

# --- identity frontmatter skipped by plan/shared validators ---
plan_fm="${TMP}/good-fm.md"
{
  printf -- '---\nlinear:\n  workspace: yandy-r\n  document: 00000000-0000-4000-8000-000000000000\nsyncedAt: 2026-10-26T00:00:00.000Z\n---\n'
  cat "${TMP}/good.md"
} >"$plan_fm"
out_fm="$("${VAL_PLAN}" "$plan_fm" 2>&1)"
rc_fm=$?
if [[ $rc_fm -eq 0 ]] && ! grep -q "Missing title" <<<"$out_fm"; then
  ok "plan with identity frontmatter validates (title in body)"
else
  bad "plan with identity frontmatter validates (rc=$rc_fm)"
  printf '%s\n' "$out_fm"
fi

shared_fm="${TMP}/shared-fm.md"
{
  printf -- '---\nlinear:\n  workspace: yandy-r\n  document: 00000000-0000-4000-8000-000000000000\nsyncedAt: 2026-10-26T00:00:00.000Z\n---\n'
  cat "${TMP}/shared.md"
} >"$shared_fm"
out_sfm="$("${VAL_SHARED}" "$shared_fm" 2>&1)"
rc_sfm=$?
if [[ $rc_sfm -eq 0 ]] && ! grep -qE "Missing (required section|document title)" <<<"$out_sfm"; then
  ok "shared.md with identity frontmatter validates"
else
  bad "shared.md with identity frontmatter validates (rc=$rc_sfm)"
  printf '%s\n' "$out_sfm"
fi

# --- prp-plan frontmatter: title within first five BODY lines ---
VAL_PRP="${SCRIPT_DIR%/plan-workflow/scripts}/prp-plan/scripts/validate-prp-plan.sh"
prp_fm="${TMP}/prp-fm.md"
{
  printf -- '---\nlinear:\n  workspace: yandy-r\n  document: 00000000-0000-4000-8000-000000000000\nsyncedAt: 2026-10-26T00:00:00.000Z\n---\n'
  cat <<'PRPEOF'
# Feature plan

## Summary

Summary body.

## Files to Change

| File | Action | Description |
|------|--------|-------------|
| `src/a.ts` | MODIFY | change it |

## Step-by-Step Tasks

### Task 1: do it

**ACTION**: the action
**IMPLEMENT**: the implementation
**MIRROR**: the mirror
**VALIDATE**: the validation

## Validation Commands

- npm test

## Acceptance Criteria

- it works
PRPEOF
} >"$prp_fm"
out_prp="$(bash "$VAL_PRP" "$prp_fm" 2>&1)"
rc_prp=$?
if [[ $rc_prp -eq 0 ]] && grep -q "Title present" <<<"$out_prp"; then
  ok "prp-plan with identity frontmatter validates"
else
  bad "prp-plan with identity frontmatter validates (rc=$rc_prp)"
  printf '%s\n' "$out_prp"
fi

# --- research files under research/ pass validate-research-artifacts ---
VAL_RESEARCH="${SCRIPT_DIR}/validate-research-artifacts.sh"
featdir="${TMP}/feat-sub"
mkdir -p "${featdir}/research"
make_research() {
  local dir="$1" name="$2" i
  {
    printf -- '---\nlinear:\n  document: 00000000-0000-4000-8000-000000000000\nsyncedAt: 2026-10-26T00:00:00.000Z\n---\n'
    printf '# Research %s\n\n' "$name"
    printf 'Overview text for the %s research document with enough words to count.\n\n' "$name"
    case "$name" in
      architecture) printf '## System Overview\n\nComponents listed here.\n\n## Integration Points\n\nPoints listed here.\n\n' ;;
      patterns) printf '## Architectural Patterns\n\nPatterns listed here.\n\n' ;;
      integration) printf '## API Endpoints\n\nEndpoints listed here.\n\n' ;;
      docs) printf '## Must-Read Documents\n\nDocs listed here.\n\n' ;;
    esac
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
      printf 'filler line %s for the %s document so the file exceeds the short-content warning threshold in bytes.\n' "$i" "$name"
    done
  } >"${dir}/research-${name}.md"
}
for lens in architecture patterns integration docs; do
  make_research "${featdir}/research" "$lens"
done
out_rsub="$(bash "$VAL_RESEARCH" "$featdir" 2>&1)"
rc_rsub=$?
if [[ $rc_rsub -eq 0 ]] && ! grep -q "file not found" <<<"$out_rsub"; then
  ok "research files under research/ pass validate-research-artifacts"
else
  bad "research files under research/ pass validate-research-artifacts (rc=$rc_rsub)"
  printf '%s\n' "$out_rsub"
fi

# --- L1: research/ wins over a stale flat copy when both layouts exist ---
bothdir="${TMP}/feat-both"
mkdir -p "${bothdir}/research"
for lens in architecture patterns integration docs; do
  make_research "$bothdir" "$lens"
  make_research "${bothdir}/research" "$lens"
done
printf '# Broken\n\nNo required headings here.\n' >"${bothdir}/research/research-patterns.md"
out_both="$(bash "$VAL_RESEARCH" "$bothdir" 2>&1)"
rc_both=$?
if [[ $rc_both -ne 0 ]] && grep -q "research-patterns.md: missing" <<<"$out_both"; then
  ok "research/ entry is validated even when a valid flat copy exists"
else
  bad "research/ entry is validated even when a valid flat copy exists (rc=$rc_both)"
  printf '%s\n' "$out_both"
fi

# --- H2: optimized mode requires all five analysis files ---
VAL_ANALYSIS="${SCRIPT_DIR}/validate-analysis-artifacts.sh"
make_analysis() {
  local dir="$1" name="$2" i
  {
    printf '# Analysis %s\n\n## Executive Summary\n\nSummary text.\n\n' "$name"
    case "$name" in
      architecture) printf '## Architecture Context\n\nContext.\n\n' ;;
      patterns) printf '## Implementation Patterns\n\nPatterns.\n\n' ;;
      integration) printf '## Integration Points\n\nPoints.\n\n' ;;
      docs) printf '## Must-Read Documents\n\nDocs.\n\n' ;;
      tasks) printf '## Recommended Phase Structure\n\nPhases.\n\n' ;;
    esac
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      printf 'filler line %s for the %s analysis document so it passes the size threshold.\n' "$i" "$name"
    done
  } >"${dir}/analysis-${name}.md"
}
optdir="${TMP}/feat-opt"
mkdir -p "$optdir"
for name in architecture patterns integration docs tasks; do make_analysis "$optdir" "$name"; done
bash "$VAL_RESEARCH" "$optdir" --optimized >/dev/null 2>&1
rc_opt=$?
if [[ $rc_opt -eq 0 ]]; then ok "optimized research gate passes with all five analysis files"; else bad "optimized research gate passes with all five analysis files (rc=$rc_opt)"; fi
for missing_name in docs tasks; do
  rm -f "${optdir}/analysis-${missing_name}.md"
  out_miss="$(bash "$VAL_RESEARCH" "$optdir" --optimized 2>&1)"
  rc_miss=$?
  if [[ $rc_miss -ne 0 ]] && grep -q "analysis-${missing_name}.md: file not found" <<<"$out_miss"; then
    ok "optimized research gate fails when analysis-${missing_name}.md is missing"
  else
    bad "optimized research gate fails when analysis-${missing_name}.md is missing (rc=$rc_miss)"
  fi
  make_analysis "$optdir" "$missing_name"
done

# --- H1: large bodies must not trip SIGPIPE under pipefail ---
# A grep -q fed by a pipe from artifact_body exits early and kills the writer
# (status 141 under pipefail). Whether that shows depends on the cat build
# (GNU/BSD cat write in 64 KB chunks, uutils splices 1 MiB), so run with a
# chunked cat shim first on PATH to make the check deterministic.
SHIM_BIN="${TMP}/shim-bin"
mkdir -p "$SHIM_BIN"
cat >"${SHIM_BIN}/cat" <<'SHIMEOF'
#!/usr/bin/env bash
[[ "${1:-}" == -- ]] && shift
if [[ $# -gt 0 ]]; then exec dd if="$1" bs=4096 status=none; fi
exec dd bs=4096 status=none
SHIMEOF
chmod +x "${SHIM_BIN}/cat"
export PATH="${SHIM_BIN}:${PATH}"
largedir="${TMP}/feat-large"
mkdir -p "${largedir}/research"
for lens in architecture patterns integration docs; do
  make_research "${largedir}/research" "$lens"
  # Drop the 5-line identity frontmatter: only the unstripped (plain cat) path
  # propagates the writer's SIGPIPE status through artifact_body.
  sed -i.bak '1,5d' "${largedir}/research/research-${lens}.md" && rm -f "${largedir}/research/research-${lens}.md.bak"
  {
    head -c 1048576 /dev/zero | tr '\0' 'x' | fold -w 100
    echo
  } >>"${largedir}/research/research-${lens}.md"
done
for run_n in 1 2 3; do
  out_large="$(bash "$VAL_RESEARCH" "$largedir" 2>&1)"
  rc_large=$?
  if [[ $rc_large -eq 0 ]]; then
    ok "large (1 MiB) research files validate (run ${run_n})"
  else
    bad "large (1 MiB) research files validate (run ${run_n}, rc=$rc_large)"
    printf '%s\n' "$out_large" | grep -E "ERROR|missing" || true
  fi
done
largeana="${TMP}/feat-large-analysis"
mkdir -p "$largeana"
for name in context code tasks; do
  case "$name" in
    context) make_analysis "$largeana" architecture; mv "${largeana}/analysis-architecture.md" "${largeana}/analysis-context.md" ;;
    code) make_analysis "$largeana" patterns; mv "${largeana}/analysis-patterns.md" "${largeana}/analysis-code.md" ;;
    tasks) make_analysis "$largeana" tasks ;;
  esac
  head -c 1048576 /dev/zero | tr '\0' 'x' | fold -w 100 >>"${largeana}/analysis-${name}.md"
  echo >>"${largeana}/analysis-${name}.md"
done
out_la="$(bash "$VAL_ANALYSIS" "$largeana" 2>&1)"
rc_la=$?
if [[ $rc_la -eq 0 ]]; then ok "large analysis files validate"; else bad "large analysis files validate (rc=$rc_la)"; printf '%s\n' "$out_la" | grep -E "ERROR" || true; fi

VAL_FRESEARCH="${SCRIPT_DIR%/plan-workflow/scripts}/feature-research/scripts/validate-research.sh"
frdir="${TMP}/feat-fr"
mkdir -p "${frdir}/research"
for lens in external business technical ux security practices recommendations; do
  {
    printf '# Research %s\n\n## Executive Summary\n\nSummary.\n\n' "$lens"
    case "$lens" in
      external) printf '## Primary APIs\n\nx\n\n## Integration Patterns\n\nx\n\n' ;;
      business) printf '## User Stories\n\nx\n\n## Business Rules\n\nx\n\n' ;;
      technical) printf '## Architecture Design\n\nx\n\n## Data Models\n\nx\n\n' ;;
      ux) printf '## User Workflows\n\nx\n\n## Performance UX\n\nx\n\n' ;;
      security) printf '## Findings by Severity\n\nx\n\n## Dependency Security\n\nx\n\n' ;;
      practices) printf '## Existing Reusable Code\n\nx\n\n## Modularity\n\nx\n\n' ;;
      recommendations) printf '## Implementation Recommendations\n\nx\n\n## Risk Assessment\n\nx\n\n' ;;
    esac
    head -c 1048576 /dev/zero | tr '\0' 'x' | fold -w 100
    echo
  } >"${frdir}/research/research-${lens}.md"
done
out_fr="$(bash "$VAL_FRESEARCH" "$frdir" 2>&1)"
rc_fr=$?
if [[ $rc_fr -eq 0 ]]; then ok "large feature-research files validate"; else bad "large feature-research files validate (rc=$rc_fr)"; printf '%s\n' "$out_fr" | grep -E "ERROR" || true; fi

# --- A required-looking heading inside frontmatter must not count ---
fmdir="${TMP}/feat-fm-heading"
mkdir -p "$fmdir"
for lens in architecture patterns integration docs; do make_research "$fmdir" "$lens"; done
{
  printf -- '---\n## System Overview\n## Integration Points\n---\n'
  printf '# Research architecture\n\nBody without the required headings.\n'
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do printf 'filler line %s to get past the size warning in this fixture.\n' "$i"; done
} >"${fmdir}/research-architecture.md"
out_fmh="$(bash "$VAL_RESEARCH" "$fmdir" 2>&1)"
rc_fmh=$?
if [[ $rc_fmh -ne 0 ]] && grep -q "research-architecture.md: missing system/components section" <<<"$out_fmh"; then
  ok "heading inside frontmatter does not satisfy the check"
else
  bad "heading inside frontmatter does not satisfy the check (rc=$rc_fmh)"
  printf '%s\n' "$out_fmh"
fi

# --- L4: validate-prp-plan prints usage without an argument ---
out_usage="$(bash "$VAL_PRP" 2>&1)"
rc_usage=$?
if [[ $rc_usage -ne 0 ]] && grep -q "^Usage: validate-prp-plan.sh" <<<"$out_usage"; then
  ok "validate-prp-plan prints usage without an argument"
else
  bad "validate-prp-plan prints usage without an argument (rc=$rc_usage)"
fi

# --- L2: validate-spec checks the linear research link form ---
VAL_SPEC="${SCRIPT_DIR%/plan-workflow/scripts}/feature-research/scripts/validate-spec.sh"
specdir="${TMP}/spec-links"
mkdir -p "${specdir}/research"
printf '# Research\n' >"${specdir}/research/research-ux.md"
cat >"${specdir}/feature-spec.md" <<'SPECEOF'
# Spec

See [ux](./research/research-ux.md) and [ext](./research/research-external.md) and [flat](./research-gone.md).
SPECEOF
out_spec="$(bash "$VAL_SPEC" "${specdir}/feature-spec.md" 2>&1)"
if grep -q "Research file not found: ./research/research-external.md" <<<"$out_spec" \
  && grep -q "Research file not found: ./research-gone.md" <<<"$out_spec" \
  && ! grep -q "Research file not found: ./research/research-ux.md" <<<"$out_spec"; then
  ok "validate-spec reports missing research links in both layouts"
else
  bad "validate-spec reports missing research links in both layouts"
  printf '%s\n' "$out_spec"
fi

# --- M1: check-prerequisites / check-state agree on feature names ---
CHECK_PREREQ="${SCRIPT_DIR}/check-prerequisites.sh"
CHECK_STATE_M1="${SCRIPT_DIR}/check-state.sh"
locroot="${TMP}/loc-repo"
mkdir -p "${locroot}/docs/plans/team/auth" "${locroot}/docs/plans/My Feature"
"${GIT:-git}" -C "$locroot" init -q 2>/dev/null || true
printf 'store: local\nplans_dir: docs/plans\n' >"${locroot}/.plans-config"
for nm in "team/auth" "My Feature"; do
  printf '# shared\n' >"${locroot}/docs/plans/${nm}/shared.md"
  out_pr="$( cd "$locroot" && bash "$CHECK_PREREQ" "$nm" 2>&1)"; rc_pr=$?
  out_st="$( cd "$locroot" && bash "$CHECK_STATE_M1" "$nm" 2>&1)"
  if [[ $rc_pr -eq 0 ]] && grep -q "SHARED_EXISTS=true" <<<"$out_st"; then
    ok "local mode accepts feature name '${nm}' in both scripts"
  else
    bad "local mode accepts feature name '${nm}' in both scripts (rc=$rc_pr)"
    printf '%s\n' "$out_pr"
  fi
done
for nm in ".." "../x"; do
  ( cd "$locroot" && bash "$CHECK_PREREQ" "$nm" >/dev/null 2>&1 ); rc_a=$?
  ( cd "$locroot" && bash "$CHECK_STATE_M1" "$nm" >/dev/null 2>&1 ); rc_b=$?
  if [[ $rc_a -ne 0 && $rc_b -ne 0 ]]; then ok "both scripts reject '${nm}'"; else bad "both scripts reject '${nm}' (rc=$rc_a/$rc_b)"; fi
done
mkdir -p "${locroot}/docs/plans/Bad Name"
printf '# shared\n' >"${locroot}/docs/plans/Bad Name/shared.md"
out_ln="$( cd "$locroot" && bash "$CHECK_STATE_M1" "Bad Name" --store=linear 2>&1)"; rc_ln=$?
if [[ $rc_ln -ne 0 ]] && ! grep -q "SHARED_EXISTS=true" <<<"$out_ln"; then
  ok "check-state never falls back to docs/plans in linear mode"
else
  bad "check-state never falls back to docs/plans in linear mode (rc=$rc_ln)"
  printf '%s\n' "$out_ln"
fi
out_nu="$( cd "$locroot" && bash "$CHECK_STATE_M1" 2>&1)"; rc_nu=$?
if [[ $rc_nu -ne 0 ]] && grep -q "^Usage: check-state.sh" <<<"$out_nu" && ! grep -qi "invalid" <<<"$out_nu"; then
  ok "check-state without a name prints usage only"
else
  bad "check-state without a name prints usage only (rc=$rc_nu)"
fi
# L6: invalid store config is reported as such, not as an invalid feature name.
printf 'store: bogus\n' >"${locroot}/.plans-config"
out_bs="$( cd "$locroot" && bash "$CHECK_PREREQ" shared-x 2>&1)"; rc_bs=$?
if [[ $rc_bs -ne 0 ]] && ! grep -q "invalid feature name" <<<"$out_bs"; then
  ok "invalid store config is not reported as an invalid feature name"
else
  bad "invalid store config is not reported as an invalid feature name (rc=$rc_bs)"
  printf '%s\n' "$out_bs"
fi

# --- check-state reads the linear store via .plans-config / --store ---
CHECK_STATE="${SCRIPT_DIR}/check-state.sh"
linroot="${TMP}/lin-repo"
mkdir -p "${linroot}/.ycc/artifacts/feat-x/research"
printf 'store: linear\nplans_dir: docs/plans\n' >"${linroot}/.plans-config"
"${GIT:-git}" -C "$linroot" init -q 2>/dev/null || true
printf '# shared\n' >"${linroot}/.ycc/artifacts/feat-x/shared.md"
printf '# plan\n' >"${linroot}/.ycc/artifacts/feat-x/parallel-plan.md"
printf '# r1\n' >"${linroot}/.ycc/artifacts/feat-x/research/research-architecture.md"
out_cs="$( cd "$linroot" && bash "$CHECK_STATE" feat-x 2>&1)"
rc_cs=$?
if [[ $rc_cs -eq 0 ]] \
  && grep -q "Directory: ${linroot}/.ycc/artifacts/feat-x" <<<"$out_cs" \
  && grep -q "RESEARCH_COUNT=1" <<<"$out_cs" \
  && grep -q "DIR_EXISTS=true" <<<"$out_cs"; then
  ok "check-state resolves feature dir via linear .plans-config"
else
  bad "check-state resolves feature dir via linear .plans-config (rc=$rc_cs)"
  printf '%s\n' "$out_cs"
fi

out_csf="$( cd "$linroot" && bash "$CHECK_STATE" feat-x --store=local 2>&1)"
rc_csf=$?
if [[ $rc_csf -eq 0 ]] && grep -q "DIR_EXISTS=false" <<<"$out_csf"; then
  ok "check-state --store=local overrides config to docs/plans"
else
  bad "check-state --store=local overrides config (rc=$rc_csf)"
  printf '%s\n' "$out_csf"
fi

if [[ $FAIL -eq 0 ]]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit $FAIL
