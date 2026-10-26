#!/usr/bin/env bash
# audit-target-features.sh — Cross-reference ycc source surfaces against the
# target capability matrix and report verdict per (surface, capability, target).
#
# Usage:
#   audit-target-features.sh [--target=<t>|all] [--format=human|json] [--strict] [--help]
#
# Flags:
#   --target=<t>|all      Restrict findings to one target: claude, cursor, codex,
#                         opencode, omp, or all (default: all). `--target <t>` also works.
#   --format=human|json   Output format (default: human)
#   --strict              Exit 1 if any verdict is "unsupported"
#   --help                Show this help and exit 0
#
# Exit codes:
#   0  No unsupported verdicts (or --strict not set and no parse errors)
#   1  --strict AND at least one unsupported verdict
#   2  Usage error or matrix parse failure
#
# ---------------------------------------------------------------------------
# Parser Grammar (narrow — do not widen without updating the Python block below)
#
# The parser reads ONE markdown table from the matrix file. Rules:
#   - The header row must be exactly (after per-cell whitespace trim):
#       capability | claude | cursor | codex | opencode | omp
#   - Separator rows (cells of dashes) are skipped.
#   - Each data cell must be one of: supported | partial | unsupported
#   - The "As of <date>" line is expected anywhere in the file as:
#       As of <anything>
#   - Rows with empty or non-vocabulary cells trigger exit 2 with a pointer to
#     the Parser Grammar section of the matrix file.
# ---------------------------------------------------------------------------

set -euo pipefail

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: audit-target-features.sh [--target=<t>|all] [--format=human|json] [--strict] [--help]

Parse the target capability matrix and cross-reference every ycc source surface
(skills, agents) against it to emit per-(surface, capability, target)
verdict lines.

Flags:
  --target=<t>|all      Restrict findings to one target: claude, cursor, codex,
                        opencode, omp, or all (default: all). `--target <t>` also works.
  --format=human|json   Output format (default: human)
  --strict              Exit 1 if any verdict is "unsupported"
  --help                Show this help and exit 0

Exit codes:
  0  No unsupported verdicts (or --strict not set and no parse errors)
  1  --strict AND at least one unsupported verdict
  2  Usage error or matrix parse failure
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

# Canonical target order; must match the matrix header after `capability`.
ALL_TARGETS=("claude" "cursor" "codex" "opencode" "omp")

FORMAT="human"
STRICT=0
TARGET="all"

while [[ $# -gt 0 ]]; do
  arg="$1"
  case "$arg" in
    --format=*)
      FORMAT="${arg#--format=}"
      ;;
    --target=*)
      TARGET="${arg#--target=}"
      ;;
    --target)
      if [[ $# -lt 2 ]]; then
        echo "audit-target-features.sh: --target requires a value" >&2
        usage >&2
        exit 2
      fi
      TARGET="$2"
      shift
      ;;
    --strict)
      STRICT=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "audit-target-features.sh: unknown flag: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

case "$FORMAT" in
  human|json) ;;
  *)
    echo "audit-target-features.sh: unknown --format value: $FORMAT" >&2
    usage >&2
    exit 2
    ;;
esac

case "$TARGET" in
  all|claude|cursor|codex|opencode|omp) ;;
  *)
    echo "audit-target-features.sh: unknown --target value: $TARGET" >&2
    usage >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# Resolve MATRIX_FILE and REPO_ROOT
#
# MATRIX_FILE: prefer ${CLAUDE_PLUGIN_ROOT} (installed plugin layout) where the
#   matrix lives at ${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/...
#   Fall back to locating the repo root via upward walk and resolving under
#   ycc/skills/_shared/references/.
#
# REPO_ROOT: always resolved via the upward walk (independent of MATRIX_FILE),
#   so downstream surface walkers (SKILLS_DIR, AGENTS_DIR) work
#   correctly regardless of which MATRIX_FILE path was chosen.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

MATRIX_FILE=""
MATRIX_REL="ycc/skills/_shared/references/target-capability-matrix.md"

# Prefer runtime-injected CLAUDE_PLUGIN_ROOT (installed plugin). Under that layout,
# the matrix lives at "${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/...".
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  cand_matrix="${CLAUDE_PLUGIN_ROOT%/}/skills/_shared/references/target-capability-matrix.md"
  if [[ -f "$cand_matrix" ]]; then
    MATRIX_FILE="$cand_matrix"
    MATRIX_REL="${cand_matrix#${CLAUDE_PLUGIN_ROOT%/}/}"
  fi
fi

# Always resolve REPO_ROOT via upward walk so that surface walkers
# (SKILLS_DIR, AGENTS_DIR) resolve correctly under ${REPO_ROOT}/ycc/.
REPO_ROOT=""
candidate="$SCRIPT_DIR"
while [[ "$candidate" != "/" ]]; do
  if [[ -f "$candidate/.claude-plugin/marketplace.json" ]]; then
    REPO_ROOT="$candidate"
    break
  fi
  candidate="$(dirname "$candidate")"
done

if [[ -z "$REPO_ROOT" ]]; then
  echo "audit-target-features.sh: cannot locate repo root (no .claude-plugin/marketplace.json above $SCRIPT_DIR)" >&2
  exit 2
fi

# Fallback: resolve matrix under repo when CLAUDE_PLUGIN_ROOT was absent or
# did not contain the matrix file.
if [[ -z "$MATRIX_FILE" ]]; then
  MATRIX_FILE="${REPO_ROOT}/ycc/skills/_shared/references/target-capability-matrix.md"
  MATRIX_REL="ycc/skills/_shared/references/target-capability-matrix.md"
fi

if [[ ! -f "$MATRIX_FILE" ]]; then
  echo "audit-target-features.sh: matrix file not found: $MATRIX_FILE" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Parse the capability matrix via Python
# Outputs: one line per capability row in the form:
#   <capability>|<claude>|<cursor>|<codex>|<opencode>|<omp>
# First line is the "As of ..." date (prefixed with "AS_OF:").
# ---------------------------------------------------------------------------

PARSE_RESULT="$(python3 - "$MATRIX_FILE" "$MATRIX_REL" <<'PYEOF'
import sys, re

matrix_path = sys.argv[1]
matrix_rel  = sys.argv[2]

VOCABULARY = {"supported", "partial", "unsupported"}
EXPECTED_HEADER = ["capability", "claude", "cursor", "codex", "opencode", "omp"]

lines = open(matrix_path).read().splitlines()

# Extract "As of" date line
as_of = ""
for line in lines:
    m = re.match(r'^\s*As of\s+(.+)', line)
    if m:
        as_of = line.strip()
        break

print(f"AS_OF:{as_of}")

# Locate the table
in_table = False
header_found = False
error_pointer = (
    f"  See 'Parser Grammar' section in {matrix_rel} for formatting rules."
)

for lineno, raw in enumerate(lines, 1):
    stripped = raw.strip()
    if not stripped.startswith("|"):
        if in_table:
            break
        continue

    in_table = True
    cells = [c.strip() for c in stripped.strip("|").split("|")]

    # Skip separator rows (all dashes)
    if all(re.match(r'^-+$', c) for c in cells):
        continue

    if not header_found:
        if cells != EXPECTED_HEADER:
            print(
                f"PARSE_ERROR:Line {lineno}: expected header "
                f"'| {' | '.join(EXPECTED_HEADER)} |' "
                f"but got: {raw!r}\n{error_pointer}",
                file=sys.stderr
            )
            sys.exit(2)
        header_found = True
        continue

    # Data row — validate and emit
    if len(cells) != len(EXPECTED_HEADER):
        print(
            f"PARSE_ERROR:Line {lineno}: expected {len(EXPECTED_HEADER)} cells but found {len(cells)}: {raw!r}\n{error_pointer}",
            file=sys.stderr
        )
        sys.exit(2)

    cap = cells[0]
    for col_name, val in zip(EXPECTED_HEADER[1:], cells[1:]):
        if val not in VOCABULARY:
            print(
                f"PARSE_ERROR:Line {lineno}: cell '{col_name}={val}' is not in vocabulary "
                f"{sorted(VOCABULARY)}\n{error_pointer}",
                file=sys.stderr
            )
            sys.exit(2)

    print("|".join(cells))

if not header_found:
    print(
        f"PARSE_ERROR: no capability table found in {matrix_path}\n{error_pointer}",
        file=sys.stderr
    )
    sys.exit(2)
PYEOF
)" || {
  # Python exited non-zero; stderr was already printed by Python
  exit 2
}

# Check for PARSE_ERROR prefix in stdout (belt-and-suspenders)
if grep -q "^PARSE_ERROR:" <<<"$PARSE_RESULT"; then
  echo "$PARSE_RESULT" | grep "^PARSE_ERROR:" | sed 's/^PARSE_ERROR://' >&2
  exit 2
fi

AS_OF_LINE="$(echo "$PARSE_RESULT" | grep "^AS_OF:" | sed 's/^AS_OF://')"

# Build parallel arrays: CAPS, VERDICTS_CLAUDE, VERDICTS_CURSOR, VERDICTS_CODEX,
# VERDICTS_OPENCODE, VERDICTS_OMP
declare -a CAPS=()
declare -a VERDICTS_CLAUDE=()
declare -a VERDICTS_CURSOR=()
declare -a VERDICTS_CODEX=()
declare -a VERDICTS_OPENCODE=()
declare -a VERDICTS_OMP=()

while IFS='|' read -r cap cl cu co oc om; do
  [[ "$cap" == AS_OF:* ]] && continue
  [[ -z "$cap" ]] && continue
  CAPS+=("$cap")
  VERDICTS_CLAUDE+=("$cl")
  VERDICTS_CURSOR+=("$cu")
  VERDICTS_CODEX+=("$co")
  VERDICTS_OPENCODE+=("$oc")
  VERDICTS_OMP+=("$om")
done < <(echo "$PARSE_RESULT" | grep -v "^AS_OF:")

# ---------------------------------------------------------------------------
# Feature detection helpers
# ---------------------------------------------------------------------------

# Check if a file references hook events (case-insensitive)
file_uses_hook() {
  local file="$1"
  local event="$2"   # PreToolUse | PostToolUse | Stop
  grep -qiE "$event" "$file" 2>/dev/null
}

# Check if a file references MCP configuration
file_uses_mcp() {
  local file="$1"
  grep -qiE '\.mcp\.json|"mcp"|mcp[[:space:]]+server' "$file" 2>/dev/null
}

# Check if a file references dangerous permission mode
file_uses_dangerous_mode() {
  local file="$1"
  grep -qiE 'dangerously-skip-permissions|dangerous.*permission|dangerous.*mode' "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Collect surfaces: (surface_path, capability_list)
# Each entry: "surface_path:CAP1,CAP2,..."
# ---------------------------------------------------------------------------

declare -a SURFACE_PATHS=()
declare -a SURFACE_CAPS=()

add_surface() {
  local path="$1"
  local caps="$2"
  SURFACE_PATHS+=("$path")
  SURFACE_CAPS+=("$caps")
}

# Walk ycc/skills/*/  (each skill directory → SKILLS capability)
SKILLS_DIR="${REPO_ROOT}/ycc/skills"
for skill_dir in "${SKILLS_DIR}"/*/; do
  skill_name="$(basename "$skill_dir")"
  # Skip infrastructure and directories without a skill entrypoint.
  [[ "$skill_name" == _* ]] && continue
  [[ -f "${skill_dir}/SKILL.md" ]] || continue

  rel_path="ycc/skills/${skill_name}"
  caps="SKILLS"

  # Scan all .md and .sh files in the skill for optional capabilities
  while IFS= read -r -d '' scan_file; do
    file_uses_hook  "$scan_file" "PreToolUse"  && caps="${caps},HOOKS.PreToolUse"  || true
    file_uses_hook  "$scan_file" "PostToolUse" && caps="${caps},HOOKS.PostToolUse" || true
    file_uses_hook  "$scan_file" "Stop"        && caps="${caps},HOOKS.Stop"        || true
    file_uses_mcp   "$scan_file"               && caps="${caps},MCP"               || true
    file_uses_dangerous_mode "$scan_file"      && caps="${caps},DANGEROUS_MODE"    || true
  done < <(find "$skill_dir" -type f \( -name "*.md" -o -name "*.sh" \) -print0 2>/dev/null)

  # De-duplicate capability list while preserving order
  caps="$(echo "$caps" | tr ',' '\n' | awk '!seen[$0]++' | tr '\n' ',' | sed 's/,$//')"
  add_surface "$rel_path" "$caps"
done

# Walk ycc/agents/*.md → AGENTS surface
AGENTS_DIR="${REPO_ROOT}/ycc/agents"
if [[ -d "$AGENTS_DIR" ]]; then
  for agent_file in "${AGENTS_DIR}"/*.md; do
    [[ -f "$agent_file" ]] || continue
    agent_name="$(basename "$agent_file")"
    rel_path="ycc/agents/${agent_name}"
    caps="AGENTS"

    file_uses_hook  "$agent_file" "PreToolUse"  && caps="${caps},HOOKS.PreToolUse"  || true
    file_uses_hook  "$agent_file" "PostToolUse" && caps="${caps},HOOKS.PostToolUse" || true
    file_uses_hook  "$agent_file" "Stop"        && caps="${caps},HOOKS.Stop"        || true
    file_uses_mcp   "$agent_file"               && caps="${caps},MCP"               || true
    file_uses_dangerous_mode "$agent_file"      && caps="${caps},DANGEROUS_MODE"    || true

    caps="$(echo "$caps" | tr ',' '\n' | awk '!seen[$0]++' | tr '\n' ',' | sed 's/,$//')"
    add_surface "$rel_path" "$caps"
  done
fi

# ---------------------------------------------------------------------------
# Build findings: for each (surface, capability, target) emit verdict
# ---------------------------------------------------------------------------

# findings_* arrays: parallel — index matches
declare -a FIND_SURFACE=()
declare -a FIND_CAP=()
declare -a FIND_TARGET=()
declare -a FIND_VERDICT=()

if [[ "$TARGET" == "all" ]]; then
  TARGETS=("${ALL_TARGETS[@]}")
else
  TARGETS=("$TARGET")
fi

lookup_verdict() {
  local cap="$1"
  local target="$2"
  local i=0
  while [[ $i -lt ${#CAPS[@]} ]]; do
    if [[ "${CAPS[$i]}" == "$cap" ]]; then
      case "$target" in
        claude)   echo "${VERDICTS_CLAUDE[$i]}";   return ;;
        cursor)   echo "${VERDICTS_CURSOR[$i]}";   return ;;
        codex)    echo "${VERDICTS_CODEX[$i]}";    return ;;
        opencode) echo "${VERDICTS_OPENCODE[$i]}"; return ;;
        omp)      echo "${VERDICTS_OMP[$i]}";      return ;;
        *)
          echo "audit-target-features.sh: lookup_verdict: unknown target '$target'" >&2
          exit 2
          ;;
      esac
    fi
    i=$((i + 1))
  done
  # Capability not in matrix — treat as unsupported (should not happen with
  # the current detection set, but guard defensively)
  echo "unsupported"
}

si=0
while [[ $si -lt ${#SURFACE_PATHS[@]} ]]; do
  surf_path="${SURFACE_PATHS[$si]}"
  surf_caps="${SURFACE_CAPS[$si]}"

  IFS=',' read -ra cap_list <<< "$surf_caps"
  for cap in "${cap_list[@]}"; do
    # Skip INSTALL_PATH — it is implicit from the target, not used by surfaces
    [[ "$cap" == "INSTALL_PATH" ]] && continue
    for target in "${TARGETS[@]}"; do
      verdict="$(lookup_verdict "$cap" "$target")"
      FIND_SURFACE+=("$surf_path")
      FIND_CAP+=("$cap")
      FIND_TARGET+=("$target")
      FIND_VERDICT+=("$verdict")
    done
  done
  si=$((si + 1))
done

# ---------------------------------------------------------------------------
# Compute summary counts
# ---------------------------------------------------------------------------

COUNT_SUPPORTED=0
COUNT_PARTIAL=0
COUNT_UNSUPPORTED=0
TOTAL_FINDINGS=${#FIND_VERDICT[@]}

for v in "${FIND_VERDICT[@]}"; do
  case "$v" in
    supported)   COUNT_SUPPORTED=$((COUNT_SUPPORTED + 1))   ;;
    partial)     COUNT_PARTIAL=$((COUNT_PARTIAL + 1))       ;;
    unsupported) COUNT_UNSUPPORTED=$((COUNT_UNSUPPORTED + 1)) ;;
  esac
done

SURFACES_AUDITED=${#SURFACE_PATHS[@]}

# ---------------------------------------------------------------------------
# Determine exit code
# ---------------------------------------------------------------------------

FINAL_RC=0
if [[ $STRICT -eq 1 && $COUNT_UNSUPPORTED -gt 0 ]]; then
  FINAL_RC=1
fi

# ---------------------------------------------------------------------------
# Human output
# ---------------------------------------------------------------------------

emit_human() {
  if [[ -n "$AS_OF_LINE" ]]; then
    echo "$AS_OF_LINE"
    echo ""
  fi

  echo "=== supported ==="
  local i=0
  while [[ $i -lt $TOTAL_FINDINGS ]]; do
    if [[ "${FIND_VERDICT[$i]}" == "supported" ]]; then
      echo "surface=${FIND_SURFACE[$i]} capability=${FIND_CAP[$i]} target=${FIND_TARGET[$i]} verdict=supported"
    fi
    i=$((i + 1))
  done

  echo ""
  echo "=== partial ==="
  i=0
  while [[ $i -lt $TOTAL_FINDINGS ]]; do
    if [[ "${FIND_VERDICT[$i]}" == "partial" ]]; then
      echo "surface=${FIND_SURFACE[$i]} capability=${FIND_CAP[$i]} target=${FIND_TARGET[$i]} verdict=partial"
    fi
    i=$((i + 1))
  done

  echo ""
  echo "=== unsupported ==="
  i=0
  while [[ $i -lt $TOTAL_FINDINGS ]]; do
    if [[ "${FIND_VERDICT[$i]}" == "unsupported" ]]; then
      echo "surface=${FIND_SURFACE[$i]} capability=${FIND_CAP[$i]} target=${FIND_TARGET[$i]} verdict=unsupported"
    fi
    i=$((i + 1))
  done

  echo ""
  echo "summary: ${SURFACES_AUDITED} surfaces audited"
  echo "- supported:   ${COUNT_SUPPORTED}"
  echo "- partial:     ${COUNT_PARTIAL} (WARN)"
  if [[ $STRICT -eq 1 && $COUNT_UNSUPPORTED -gt 0 ]]; then
    echo "- unsupported: ${COUNT_UNSUPPORTED} (ERROR)"
  else
    echo "- unsupported: ${COUNT_UNSUPPORTED}"
  fi
}

# ---------------------------------------------------------------------------
# JSON output — delegate serialization to Python
# ---------------------------------------------------------------------------

emit_json() {
  local as_of_line="$1"
  # Single Python invocation: pass all findings as argv (n surfaces, then n caps,
  # then n targets, then n verdicts). No temp files, no per-finding subshells.
  python3 - \
    "$MATRIX_REL" \
    "$SURFACES_AUDITED" \
    "$COUNT_SUPPORTED" \
    "$COUNT_PARTIAL" \
    "$COUNT_UNSUPPORTED" \
    "$FINAL_RC" \
    "$as_of_line" \
    "$TOTAL_FINDINGS" \
    "${FIND_SURFACE[@]+"${FIND_SURFACE[@]}"}" \
    "${FIND_CAP[@]+"${FIND_CAP[@]}"}" \
    "${FIND_TARGET[@]+"${FIND_TARGET[@]}"}" \
    "${FIND_VERDICT[@]+"${FIND_VERDICT[@]}"}" \
    <<'PYEOF'
import json, sys
from datetime import datetime, timezone

matrix_rel    = sys.argv[1]
total_surfs   = int(sys.argv[2])
cnt_supported = int(sys.argv[3])
cnt_partial   = int(sys.argv[4])
cnt_unsupp    = int(sys.argv[5])
final_rc      = int(sys.argv[6])
as_of_matrix  = sys.argv[7]
n             = int(sys.argv[8])

rest     = sys.argv[9:]
surfs    = rest[0:n]
caps     = rest[n:2*n]
targets  = rest[2*n:3*n]
verdicts = rest[3*n:4*n]

findings = [
    {"surface": surfs[i], "capability": caps[i], "target": targets[i], "verdict": verdicts[i]}
    for i in range(n)
]

print(json.dumps({
    "as_of_matrix": as_of_matrix,
    "as_of_run":    datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "matrix_source": matrix_rel,
    "findings":     findings,
    "summary": {
        "total":       len(findings),
        "supported":   cnt_supported,
        "partial":     cnt_partial,
        "unsupported": cnt_unsupp,
    },
    "ok": final_rc == 0,
}, indent=2))
PYEOF
}

# ---------------------------------------------------------------------------
# Emit report
# ---------------------------------------------------------------------------

if [[ "$FORMAT" == "human" ]]; then
  emit_human
else
  emit_json "$AS_OF_LINE"
fi

exit $FINAL_RC
