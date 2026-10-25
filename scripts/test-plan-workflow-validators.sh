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

if [[ $FAIL -eq 0 ]]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit $FAIL
