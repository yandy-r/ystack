#!/usr/bin/env bash
# rules-report.sh [--repo DIR]
# Print the line count of every rules file that exists (AGENTS.md, CLAUDE.md,
# .github/copilot-instructions.md, .cursor/rules/*.mdc) and warn above 200
# lines. Bash 3.2-compatible. Read-only. Exit code is always 0; the warning is
# informational so init never fails on file size.
set -euo pipefail
repo="$PWD"
if [[ "${1:-}" == "--repo" ]]; then
  repo="${2:?--repo requires a directory}"
fi
[[ -d "$repo" ]] || { echo "rules-report: directory not found: $repo" >&2; exit 1; }
found=0
report() {
  local rel="$1" lines
  [[ -f "$repo/$rel" ]] || return 0
  found=1
  lines="$(wc -l <"$repo/$rel" | tr -d ' ')"
  if [[ "$lines" -gt 200 ]]; then
    printf '%s: %s lines  WARNING: over 200 lines (long rules files lose adherence; trim or run --migrate-rules)\n' "$rel" "$lines"
  else
    printf '%s: %s lines\n' "$rel" "$lines"
  fi
}
report AGENTS.md
report CLAUDE.md
report .github/copilot-instructions.md
for f in "$repo"/.cursor/rules/*.mdc; do
  [[ -e "$f" ]] && report ".cursor/rules/$(basename "$f")"
done
[[ "$found" -eq 1 ]] || echo "no rules files found"
