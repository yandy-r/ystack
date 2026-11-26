#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
usage() {
  printf '%s\n' \
    'Usage: scripts/eval.sh [--suite trigger|policy|behavior] [--case GLOB]' \
    '                       [--quarantine] [--max-cost-usd USD] [--model MODEL]' \
    '                       [--keep-temp]' \
    "Runs one arm once, with a suite-wide \$8 cost ceiling by default" \
    "(the earlier 39-case baseline measured \$4.59). --quarantine runs whatever cases" \
    'are in ycc/evals-quarantine/ instead of ycc/evals/. Paid, local-only; not part of CI.' \
    'See ycc/evals/README.md.'
}
fail() { echo "eval.sh: $*" >&2; exit 1; }

budget=8
quarantine=0
options=()
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --suite)
      (($# >= 2)) || fail '--suite needs a value'
      case "$2" in trigger|policy|behavior) ;; *) fail 'suite must be trigger, policy or behavior' ;; esac
      options+=(--tag "$2"); shift 2 ;;
    --case|--model)
      if (($# < 2)) || [[ -z "$2" ]]; then fail "$1 needs a value"; fi
      options+=("$1" "$2"); shift 2 ;;
    --max-cost-usd)
      (($# >= 2)) || fail '--max-cost-usd needs a value'
      budget="$2"; shift 2 ;;
    --keep-temp) options+=(--keep-temp); shift ;;
    --quarantine) options+=(--eval-dir evals-quarantine); quarantine=1; shift ;;
    *) fail "unknown option: $1" ;;
  esac
done
[[ "$budget" =~ ^[0-9]+([.][0-9]+)?$ && "$budget" =~ [1-9] ]] || fail 'cost ceiling must be a positive number'
[[ -f "$ROOT/ycc/.claude-plugin/plugin.json" && -d "$ROOT/ycc/evals/trigger" && -d "$ROOT/ycc/evals/policy" && -d "$ROOT/ycc/evals/behavior" ]] || fail 'plugin manifest or eval suite missing'
if ! command -v claude >/dev/null 2>&1; then
  echo 'SKIP: claude is not on PATH; install Claude Code >= 2.1.269 to run paid evals.'
  exit 0
fi
command -v python3 >/dev/null 2>&1 || fail 'python3 is needed to print the per-case summary'
command -v git >/dev/null 2>&1 || fail 'git is needed to scaffold scratch repositories'

results="$ROOT/ycc/evals/results"
((quarantine)) && results="$ROOT/ycc/evals-quarantine/results"
mkdir -p "$results"
output="$(mktemp -d "$results/run-XXXXXXXX")"
echo "Claude: $(claude --version)"
echo "Local results: $output"
echo "Cost ceiling: \$$budget (one in-flight run can overrun it; see README)"

# One invocation: the budget applies to BOTH suites, not to each case separately.
# These are our authored scaffolds; trust-plugin only asserts trust for this run,
# never disables tool permissions. Bash is intentionally NOT granted: it needs a
# bubblewrap+socat sandbox, and no case here needs it.
status=0
claude plugin eval "$ROOT/ycc" \
  --runs 1 --ablation none --no-publish --max-cost-usd "$budget" \
  --trust-plugin --scaffold --mocks record --concurrency 1 \
  --output-dir "$output" --json "$output/aggregate-result.json" \
  "${options[@]}" --allow-tools Write Edit || status=$?

if [[ ! -f "$output/aggregate-result.json" ]]; then
  echo 'FAIL: Claude did not write a result document' >&2
  exit 1
fi
python3 - "$output/aggregate-result.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
for case in result.get("cases", []):
    runs = case.get("arms", {}).get("with", [])
    if not runs:
        print(f"SKIP {case['name']}: no run (budget/credential/interruption)")
        continue
    score = case.get("aggregates", {}).get("score", 0)
    verdict = "PASS" if score >= 1 and not any(run.get("error") for run in runs) else "FAIL"
    print(f"{verdict} {case['name']}: score={score:.2f}")
    for run in runs:
        if run.get("error"):
            print(f"  error: {run['error']}")
aggregates = result.get("aggregates", {})
print(f"Cases: {aggregates.get('casesPassed', 0)}/{aggregates.get('casesTotal', 0)} passed")
print(f"Estimated cost: ${result.get('costUsd', 0):.4f}")
if result.get("partial"):
    print(f"PARTIAL: {result.get('partialReason', 'unknown')}")
PY
exit "$status"
