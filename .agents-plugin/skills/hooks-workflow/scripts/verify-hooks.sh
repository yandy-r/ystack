#!/usr/bin/env bash
# verify-hooks.sh — Parse-only verification of emitted hook config files.
#
# Usage: verify-hooks.sh <config-file> --target=<claude|cursor|codex>
#                        [--probe-binaries] [--format=<human|json>] [--help]
#
# Exit codes:
#   0  all checks PASS (WARN does not fail)
#   1  at least one check FAIL
#   2  usage error or missing file

set -euo pipefail

CONFIG_FILE=""
TARGET=""
PROBE_BINARIES=false
FORMAT="human"

usage() {
  cat <<'EOF'
Usage: verify-hooks.sh <config-file> --target=<claude|cursor|codex>
                       [--probe-binaries] [--format=<human|json>] [--help]

Parse-only checks on an emitted hook config file.
--probe-binaries (claude only): probe command binaries via --help/--version
  with a 3s timeout. Never executes the full hook body.

Exit codes: 0 all PASS, 1 any FAIL, 2 usage/missing-file
EOF
}

for arg in "$@"; do
  case "$arg" in
    --help|-h)         usage; exit 0 ;;
    --target=*)        TARGET="${arg#--target=}" ;;
    --probe-binaries)  PROBE_BINARIES=true ;;
    --format=*)        FORMAT="${arg#--format=}" ;;
    --*)               echo "verify-hooks.sh: unknown flag: $arg" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -z "$CONFIG_FILE" ]]; then
        CONFIG_FILE="$arg"
      else
        echo "verify-hooks.sh: unexpected argument: $arg" >&2; usage >&2; exit 2
      fi ;;
  esac
done

[[ -z "$TARGET" ]] && { echo "verify-hooks.sh: --target is required (claude|cursor|codex)" >&2; usage >&2; exit 2; }
case "$TARGET" in claude|cursor|codex) ;; *)
  echo "verify-hooks.sh: unknown --target: $TARGET" >&2; usage >&2; exit 2 ;;
esac
case "$FORMAT" in human|json) ;; *)
  echo "verify-hooks.sh: unknown --format: $FORMAT" >&2; usage >&2; exit 2 ;;
esac
[[ -z "$CONFIG_FILE" ]] && { echo "verify-hooks.sh: config-file is required" >&2; usage >&2; exit 2; }
[[ ! -f "$CONFIG_FILE" ]] && { echo "verify-hooks.sh: file not found: $CONFIG_FILE" >&2; exit 2; }

# Preflight: required binaries.
if ! command -v python3 >/dev/null 2>&1; then
  echo "verify-hooks.sh: python3 not found in PATH" >&2
  exit 2
fi

if [[ "$PROBE_BINARIES" == "true" ]] && ! command -v timeout >/dev/null 2>&1; then
  echo "verify-hooks.sh: 'timeout' not found in PATH but required for --probe-binaries" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Check tracking
# ---------------------------------------------------------------------------

CHECK_IDS=(); CHECK_STATUSES=(); CHECK_DETAILS=()

add_check() { CHECK_IDS+=("$1"); CHECK_STATUSES+=("$2"); CHECK_DETAILS+=("$3"); }

# ---------------------------------------------------------------------------
# Per-target verification
# ---------------------------------------------------------------------------

verify_claude() {
  local parse_out
  if ! parse_out="$(python3 -m json.tool "$CONFIG_FILE" 2>&1)"; then
    add_check "json-parse" "FAIL" "JSON parse error: $parse_out"; return
  fi
  add_check "json-parse" "PASS" "file is valid JSON"

  local commands_raw
  commands_raw="$(python3 - "$CONFIG_FILE" <<'PYEOF'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"ERROR:{e}"); sys.exit(1)
idx = 0
for event, event_hooks in data.get("hooks", {}).items():
    if not isinstance(event_hooks, list): continue
    for entry in event_hooks:
        if not isinstance(entry, dict): continue
        for hook in entry.get("hooks", []):
            if not isinstance(hook, dict): continue
            cmd = hook.get("command", "")
            if cmd:
                print(f"{idx}:{event}:{cmd}"); idx += 1
PYEOF
)" || true

  if [[ -z "$commands_raw" ]]; then
    add_check "hook-commands" "WARN" "no hook command entries found in file"; return
  fi

  local hook_idx=1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local rest event command token check_id probe_detail resolved
    rest="${line#*:}"; event="${rest%%:*}"; command="${rest#*:}"
    token="$(echo "$command" | awk '{print $1}')"
    check_id="hook#${hook_idx}"; hook_idx=$((hook_idx + 1))
    if [[ "$PROBE_BINARIES" == "true" ]]; then
      resolved="$(command -v "$token" 2>/dev/null || true)"
      if [[ -z "$resolved" ]]; then
        add_check "$check_id" "FAIL" "event=${event} command=\`${command}\` | probe: command not found"
      else
        if timeout 3s "$token" --help >/dev/null 2>&1; then
          probe_detail="$token --help OK"
        elif timeout 3s "$token" --version >/dev/null 2>&1; then
          probe_detail="$token --version OK"
        else
          probe_detail="$token resolved (nonzero exit on --help/--version; binary present)"
        fi
        add_check "$check_id" "PASS" "event=${event} command=\`${command}\` | probe: $probe_detail"
      fi
    else
      add_check "$check_id" "PASS" "event=${event} command=\`${command}\` (no probe; --probe-binaries not set)"
    fi
  done <<< "$commands_raw"
}

verify_cursor() {
  local file_content
  file_content="$(cat "$CONFIG_FILE")"
  if [[ "$file_content" == "---"* ]]; then
    local fm_out
    fm_out="$(python3 - "$CONFIG_FILE" <<'PYEOF'
import sys
try:
    import yaml
except ImportError:
    print("WARN:yaml unavailable; install PyYAML for frontmatter validation"); sys.exit(0)
content = open(sys.argv[1]).read()
parts = content.split("---", 2)
if len(parts) < 3:
    print("ERROR:malformed frontmatter (no closing ---)"); sys.exit(1)
try:
    yaml.safe_load(parts[1]); print("PASS:frontmatter parses as valid YAML")
except yaml.YAMLError as e:
    print(f"ERROR:{e}"); sys.exit(1)
PYEOF
)" || true
    if   [[ "$fm_out" == PASS:* ]]; then add_check "frontmatter-parse" "PASS" "${fm_out#PASS:}"
    elif [[ "$fm_out" == WARN:* ]]; then add_check "frontmatter-parse" "WARN" "${fm_out#WARN:}"
    else add_check "frontmatter-parse" "FAIL" "${fm_out#ERROR:}"; return
    fi
  else
    add_check "frontmatter-parse" "PASS" "no frontmatter block; plain .mdc fragment (acceptable)"
  fi
  if grep -qE "(advisory|Advisory|ADVISORY|hooks.*not.*supported|partial.*support)" "$CONFIG_FILE" 2>/dev/null; then
    add_check "advisory-marker" "PASS" "capability advisory marker found"
  else
    add_check "advisory-marker" "WARN" "no advisory marker detected; consider adding capability notice"
  fi
}

verify_codex() {
  local toml_out
  toml_out="$(python3 - "$CONFIG_FILE" <<'PYEOF'
import sys
path = sys.argv[1]
try:
    import tomllib
    with open(path, "rb") as f: tomllib.load(f)
    print("PASS:parsed with tomllib"); sys.exit(0)
except ModuleNotFoundError: pass
except Exception as e: print(f"ERROR:{e}"); sys.exit(1)
try:
    import tomli
    with open(path, "rb") as f: tomli.load(f)
    print("PASS:parsed with tomli"); sys.exit(0)
except ModuleNotFoundError:
    print("WARN:neither tomllib nor tomli available; skipping TOML parse check"); sys.exit(0)
except Exception as e: print(f"ERROR:{e}"); sys.exit(1)
PYEOF
)" || true
  if   [[ "$toml_out" == PASS:* ]]; then add_check "toml-parse" "PASS" "${toml_out#PASS:}"
  elif [[ "$toml_out" == WARN:* ]]; then add_check "toml-parse" "WARN" "${toml_out#WARN:}"
  else add_check "toml-parse" "FAIL" "${toml_out#ERROR:}"
  fi
  local first_line
  first_line="$(head -1 "$CONFIG_FILE")"
  if grep -q "Advisory only" <<<"$first_line"; then
    add_check "advisory-comment" "PASS" "file leads with advisory comment"
  else
    add_check "advisory-comment" "FAIL" "file must lead with '# Advisory only ...' comment; got: ${first_line}"
  fi
}

case "$TARGET" in
  claude) verify_claude ;;
  cursor) verify_cursor ;;
  codex)  verify_codex  ;;
esac

# ---------------------------------------------------------------------------
# Tally results
# ---------------------------------------------------------------------------

OVERALL_RC=0; PASS_COUNT=0; FAIL_COUNT=0; WARN_COUNT=0
for status in "${CHECK_STATUSES[@]}"; do
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)); OVERALL_RC=1 ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
  esac
done
TOTAL_COUNT=${#CHECK_IDS[@]}
AS_OF="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ---------------------------------------------------------------------------
# Emit report
# ---------------------------------------------------------------------------

if [[ "$FORMAT" == "human" ]]; then
  local_i=0
  while [[ $local_i -lt ${#CHECK_IDS[@]} ]]; do
    echo "[${TARGET}] ${CHECK_IDS[$local_i]} ${CHECK_STATUSES[$local_i]} (${CHECK_DETAILS[$local_i]})"
    local_i=$((local_i + 1))
  done
  echo "summary: ${TOTAL_COUNT} checks / ${PASS_COUNT} PASS / ${FAIL_COUNT} FAIL / ${WARN_COUNT} WARN"
else
  python3 - "$AS_OF" "$TARGET" "$OVERALL_RC" \
    "${CHECK_IDS[@]+"${CHECK_IDS[@]}"}" \
    "---statuses---" \
    "${CHECK_STATUSES[@]+"${CHECK_STATUSES[@]}"}" \
    "---details---" \
    "${CHECK_DETAILS[@]+"${CHECK_DETAILS[@]}"}" <<'PYEOF'
import json, sys
args = sys.argv[1:]
as_of, target, overall_rc = args[0], args[1], int(args[2])
rest = args[3:]
sep1, sep2 = rest.index("---statuses---"), rest.index("---details---")
ids, statuses, details = rest[:sep1], rest[sep1+1:sep2], rest[sep2+1:]
checks = [{"id": ids[i], "status": statuses[i], "detail": details[i]} for i in range(len(ids))]
print(json.dumps({"as_of": as_of, "target": target, "checks": checks, "ok": overall_rc == 0}, indent=2))
PYEOF
fi

exit $OVERALL_RC
