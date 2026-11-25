#!/usr/bin/env bash
# build-hook-config.sh — Produce a target-appropriate hook configuration by reading
# repo guidance under ycc/rules/<language>/hooks.md (and ycc/rules/common/hooks.md)
# and applying target-specific templates.
#
# Template files are referenced by path (not inlined):
#   ${REPO_ROOT}/ycc/skills/hooks-workflow/references/templates/claude-settings.json.tmpl
#   ${REPO_ROOT}/ycc/skills/hooks-workflow/references/templates/cursor-rule-fragment.mdc.tmpl
#   ${REPO_ROOT}/ycc/skills/hooks-workflow/references/templates/codex-config-fragment.toml.tmpl
#
# Templates use these placeholders (replaced via sed chains):
#   {{LANGUAGE}}  — the resolved language name (e.g. python, golang, typescript)
#   {{EVENT}}     — the hook event name (PreToolUse, PostToolUse, Stop)
#   {{COMMAND}}   — the command string extracted from the rules file
#   {{MATCHER}}   — the tool/file matcher pattern (empty string if none)
#
# Exit codes: 0 success, 1 unsupported event/target, 2 usage error.

set -euo pipefail

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: build-hook-config.sh --language=<lang>
                             [--target=claude|cursor|codex]
                             [--event=PreToolUse|PostToolUse|Stop|all]
                             [--out=<path>]
                             [--repo-root=<path>]
                             [--dry-run]
                             [--force]
                             [--help]

Produces a target-appropriate hook configuration from ycc/rules/<language>/hooks.md
(and ycc/rules/common/hooks.md). Requires a ycc/ystack source checkout
containing canonical ycc/rules/*/hooks.md, the capability matrix, and the
hooks-workflow templates (installed Cursor .mdc rules are not hook inputs).

  --language=<lang>    Required. Language under ycc/rules/. Use "common" for common only.
  --target=<t>         Output target: claude (default), cursor, or codex.
  --event=<e>          Hook event: PreToolUse, PostToolUse, Stop, or all (default).
  --out=<path>         Write output to this path (atomic). Prints to stdout if absent.
  --repo-root=<path>   Source checkout (or subdirectory) to search; authoritative if given.
  --dry-run            Print to stdout; never write even if --out is set.
  --force              Required when --target=codex and writing to disk (not dry-run).
  --help               Show this message and exit 0.

Exit codes: 0 success, 1 unsupported event/target, 2 usage error.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

LANGUAGE=""
TARGET="claude"
EVENT="all"
OUT_PATH=""
DRY_RUN=false
FORCE=false
REPO_ROOT_INPUT=""

for arg in "$@"; do
  case "$arg" in
    --language=*)  LANGUAGE="${arg#--language=}" ;;
    --target=*)    TARGET="${arg#--target=}" ;;
    --event=*)     EVENT="${arg#--event=}" ;;
    --out=*)       OUT_PATH="${arg#--out=}" ;;
    --repo-root=*) REPO_ROOT_INPUT="${arg#--repo-root=}" ;;
    --dry-run)     DRY_RUN=true ;;
    --force)       FORCE=true ;;
    --help|-h)     usage; exit 0 ;;
    *)
      echo "build-hook-config.sh: unknown flag: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate flags
# ---------------------------------------------------------------------------

if [[ -z "$LANGUAGE" ]]; then
  echo "build-hook-config.sh: --language is required" >&2
  usage >&2
  exit 2
fi

case "$TARGET" in
  claude|cursor|codex) ;;
  *)
    echo "build-hook-config.sh: --target must be claude, cursor, or codex (got: $TARGET)" >&2
    usage >&2; exit 2 ;;
esac

case "$EVENT" in
  PreToolUse|PostToolUse|Stop|all) ;;
  *)
    echo "build-hook-config.sh: --event must be PreToolUse, PostToolUse, Stop, or all (got: $EVENT)" >&2
    usage >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Resolve REPO_ROOT — must be a ycc source checkout with canonical hook rules,
# the capability matrix, and the hooks-workflow templates. Order:
#   1. explicit --repo-root=PATH (authoritative: no fallthrough if unsuitable)
#   2. CLAUDE_PLUGIN_ROOT and its ancestors (when set)
#   3. the script's own directory and its ancestors
#   4. PWD and its ancestors
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT=""

is_source_root() {
  local dir="$1"
  [[ -f "${dir}/ycc/rules/common/hooks.md" && \
     -f "${dir}/ycc/skills/_shared/references/target-capability-matrix.md" && \
     -d "${dir}/ycc/skills/hooks-workflow/references/templates" ]]
}

resolve_repo_root_from() {
  local candidate="${1%/}"
  [[ -z "$candidate" ]] && candidate="/"
  while [[ "$candidate" != "/" ]]; do
    if is_source_root "$candidate"; then
      REPO_ROOT="$candidate"
      return 0
    fi
    candidate="$(dirname "$candidate")"
  done
  is_source_root "/" && REPO_ROOT="/"
}

die_no_source_root() {
  echo "build-hook-config.sh: no ycc/ystack source checkout found${1:+ (searched from $1)}." >&2
  echo "This helper needs canonical ycc/rules/*/hooks.md, ycc/skills/_shared/references/target-capability-matrix.md," >&2
  echo "and ycc/skills/hooks-workflow/references/templates/ (installed Cursor .mdc rules are not hook inputs)." >&2
  echo "Run it from a source checkout or pass --repo-root=/path/to/checkout." >&2
  exit 2
}

if [[ -n "$REPO_ROOT_INPUT" ]]; then
  if [[ ! -d "$REPO_ROOT_INPUT" ]]; then
    echo "build-hook-config.sh: --repo-root path is not a directory: $REPO_ROOT_INPUT" >&2
    exit 2
  fi
  resolve_repo_root_from "$(cd "$REPO_ROOT_INPUT" && pwd)" || die_no_source_root "$REPO_ROOT_INPUT"
fi

if [[ -z "$REPO_ROOT" && -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "${CLAUDE_PLUGIN_ROOT}" ]]; then
  resolve_repo_root_from "$(cd "$CLAUDE_PLUGIN_ROOT" && pwd)" || true
fi

if [[ -z "$REPO_ROOT" ]]; then
  resolve_repo_root_from "$SCRIPT_DIR" || true
fi

if [[ -z "$REPO_ROOT" ]]; then
  resolve_repo_root_from "$PWD" || true
fi

if [[ -z "$REPO_ROOT" ]]; then
  die_no_source_root "$SCRIPT_DIR"
fi
echo "build-hook-config.sh: repo root is $REPO_ROOT" >&2

RULES_DIR="${REPO_ROOT}/ycc/rules"
MATRIX_FILE="${REPO_ROOT}/ycc/skills/_shared/references/target-capability-matrix.md"
TMPL_DIR="${REPO_ROOT}/ycc/skills/hooks-workflow/references/templates"
CLAUDE_TMPL="${TMPL_DIR}/claude-settings.json.tmpl"
CURSOR_TMPL="${TMPL_DIR}/cursor-rule-fragment.mdc.tmpl"
CODEX_TMPL="${TMPL_DIR}/codex-config-fragment.toml.tmpl"

# ---------------------------------------------------------------------------
# Validate language
# ---------------------------------------------------------------------------

if [[ "$LANGUAGE" != "common" && ! -f "${RULES_DIR}/${LANGUAGE}/hooks.md" ]]; then
  valid=""
  if [[ -d "$RULES_DIR" ]]; then
    while IFS= read -r p; do
      n="$(basename "$(dirname "$p")")"
      [[ "$n" != "common" ]] && valid="${valid:+$valid, }$n"
    done < <(find "$RULES_DIR" -name "hooks.md" | sort)
  fi
  echo "build-hook-config.sh: unknown language \"${LANGUAGE}\". Valid values: ${valid:-none found}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Resolve source files
# ---------------------------------------------------------------------------

LANG_HOOKS_FILE=""
COMMON_HOOKS_FILE=""
[[ "$LANGUAGE" != "common" && -f "${RULES_DIR}/${LANGUAGE}/hooks.md" ]] && \
  LANG_HOOKS_FILE="${RULES_DIR}/${LANGUAGE}/hooks.md"
[[ -f "${RULES_DIR}/common/hooks.md" ]] && COMMON_HOOKS_FILE="${RULES_DIR}/common/hooks.md"

if [[ -z "$LANG_HOOKS_FILE" && -z "$COMMON_HOOKS_FILE" ]]; then
  echo "build-hook-config.sh: no hooks.md found under ycc/rules/${LANGUAGE}/ or ycc/rules/common/" >&2
  exit 2
fi

echo "build-hook-config.sh: lang=${LANG_HOOKS_FILE:-<none>} common=${COMMON_HOOKS_FILE:-<none>}" >&2

# ---------------------------------------------------------------------------
# Matrix lookup — returns supported|partial|unsupported for capability+target
# ---------------------------------------------------------------------------

matrix_cell() {
  local capability="$1" tgt="$2" col
  case "$tgt" in
    claude) col=2 ;; cursor) col=3 ;; codex) col=4 ;;
  esac
  local raw
  # Tolerate variable column-alignment whitespace in the matrix table
  # (e.g. "| HOOKS.PreToolUse  |" padded for the widest row).
  raw="$(grep -m1 -E "^\| *${capability} +\|" "$MATRIX_FILE" 2>/dev/null || true)"
  [[ -z "$raw" ]] && { echo ""; return; }
  echo "$raw" | awk -F'|' -v c="$((col + 1))" '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $c); print $c }'
}

# Determine event set
if [[ "$EVENT" == "all" ]]; then
  EVENTS=(PreToolUse PostToolUse Stop)
else
  EVENTS=("$EVENT")
fi

# Collect matrix verdicts
declare -A EVENT_VERDICT
unsupported_events=()

for ev in "${EVENTS[@]}"; do
  verdict="$(matrix_cell "HOOKS.${ev}" "$TARGET")"
  if [[ -z "$verdict" ]]; then
    echo "build-hook-config.sh: could not find HOOKS.${ev} in capability matrix" >&2
    exit 1
  fi
  EVENT_VERDICT["$ev"]="$verdict"
  [[ "$verdict" == "unsupported" ]] && unsupported_events+=("$ev")
done

# For codex, output is always advisory-only regardless of verdict — skip hard stop.
if [[ ${#unsupported_events[@]} -gt 0 && "$TARGET" != "codex" ]]; then
  matrix_date="$(grep -m1 "^As of " "$MATRIX_FILE" | sed 's/As of //' | tr -d '\r' || echo "2026-04-16")"
  for ev in "${unsupported_events[@]}"; do
    echo "HOOKS.${ev} is unsupported on target ${TARGET} as of ${matrix_date}."
    echo "See ycc/skills/_shared/references/target-capability-matrix.md for the supported set."
  done
  [[ "$DRY_RUN" == "true" ]] && exit 0
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse hook recommendations from rules files
# Output: tab-separated lines of  <event>\t<type>:<body>
#   type = "command" (fenced code line) or "advisory" (section header text)
# ---------------------------------------------------------------------------

parse_hooks_file() {
  local filepath="$1"
  local current_event="" in_fence=false fence_buf="" header_text=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^##[[:space:]]+(PreToolUse|PostToolUse|Stop)([[:space:]].*)?$ ]]; then
      # Flush previous event that had no fenced commands
      if [[ -n "$current_event" && -z "$fence_buf" && -n "$header_text" ]]; then
        printf '%s\tadvisory:%s\n' "$current_event" "$header_text"
      fi
      current_event="${BASH_REMATCH[1]}"
      header_text="${line#\#\# }"
      fence_buf=""
      in_fence=false
      continue
    fi

    [[ -z "$current_event" ]] && continue

    if [[ "$line" =~ ^\`\`\` ]]; then
      if [[ "$in_fence" == "false" ]]; then
        in_fence=true
        fence_buf=""
      else
        # Emit non-empty fence lines as commands
        while IFS= read -r cmd || [[ -n "$cmd" ]]; do
          cmd="${cmd#"${cmd%%[![:space:]]*}"}"   # ltrim
          cmd="${cmd%"${cmd##*[![:space:]]}"}"   # rtrim
          [[ -n "$cmd" ]] && printf '%s\tcommand:%s\n' "$current_event" "$cmd"
        done <<< "$fence_buf"
        fence_buf="nonempty"   # sentinel: fence was closed
        in_fence=false
      fi
      continue
    fi

    [[ "$in_fence" == "true" ]] && fence_buf="${fence_buf}${line}"$'\n'
  done < "$filepath"

  # Trailing event with no fenced commands
  if [[ -n "$current_event" && "$fence_buf" != "nonempty" && -n "$header_text" ]]; then
    printf '%s\tadvisory:%s\n' "$current_event" "$header_text"
  fi
}

declare -a ALL_RECS=()
for src in "$COMMON_HOOKS_FILE" "$LANG_HOOKS_FILE"; do
  [[ -z "$src" ]] && continue
  while IFS= read -r rec || [[ -n "$rec" ]]; do
    [[ -n "$rec" ]] && ALL_RECS+=("$rec")
  done < <(parse_hooks_file "$src")
done

echo "build-hook-config.sh: extracted ${#ALL_RECS[@]} recommendation(s)" >&2

declare -a FILTERED_RECS=()
for rec in "${ALL_RECS[@]}"; do
  rec_event="${rec%%$'\t'*}"
  [[ "$EVENT" == "all" || "$rec_event" == "$EVENT" ]] && FILTERED_RECS+=("$rec")
done

# ---------------------------------------------------------------------------
# Template rendering: apply {{PLACEHOLDER}} substitutions via sed chains
# ---------------------------------------------------------------------------

render_template() {
  local tmpl_file="$1" lang="$2" ev="$3" cmd="$4" matcher="$5"
  python3 - "$tmpl_file" "$lang" "$ev" "$cmd" "$matcher" <<'PYEOF'
import sys
tmpl_file, lang, ev, cmd, matcher = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
with open(tmpl_file, 'r') as f:
    text = f.read()
text = text.replace('{{LANGUAGE}}', lang)
text = text.replace('{{EVENT}}', ev)
text = text.replace('{{COMMAND}}', cmd)
text = text.replace('{{MATCHER}}', matcher)
sys.stdout.write(text)
PYEOF
}

# Collect per-event command/advisory lines into a single string
collect_ev_block() {
  local target_ev="$1" entry_type entry_body rec rev_val
  local block=""
  for rec in "${FILTERED_RECS[@]}"; do
    [[ "${rec%%$'\t'*}" != "$target_ev" ]] && continue
    rev_val="${rec#*$'\t'}"
    entry_type="${rev_val%%:*}"
    entry_body="${rev_val#*:}"
    case "$entry_type" in
      command)  block="${block}${entry_body}"$'\n' ;;
      advisory) block="${block}# ${entry_body}"$'\n' ;;
    esac
  done
  printf '%s' "$block"
}

# ---------------------------------------------------------------------------
# Build output per target
# ---------------------------------------------------------------------------

build_claude_output() {
  if [[ ! -f "$CLAUDE_TMPL" ]]; then
    echo "build-hook-config.sh: template missing: $CLAUDE_TMPL" >&2
    exit 2
  fi

  declare -A ev_json
  for ev in "${EVENTS[@]}"; do
    ev_json["$ev"]=""
  done

  for rec in "${FILTERED_RECS[@]}"; do
    rev_event="${rec%%$'\t'*}"
    rev_val="${rec#*$'\t'}"
    entry_type="${rev_val%%:*}"
    entry_body="${rev_val#*:}"
    [[ "$entry_type" != "command" ]] && continue

    local escaped_cmd
    escaped_cmd="$(printf '%s' "$entry_body" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    local rendered
    rendered="$(render_template "$CLAUDE_TMPL" "$LANGUAGE" "$rev_event" "$escaped_cmd" "")"
    ev_json["$rev_event"]+="${rendered}"$'\n'
  done

  printf '{\n'
  printf '  "hooks": {\n'
  local first_ev=true
  for ev in "${EVENTS[@]}"; do
    [[ "${EVENT_VERDICT[$ev]}" == "unsupported" ]] && continue
    [[ "$first_ev" == "false" ]] && printf ',\n'
    first_ev=false
    printf '    "%s": [\n' "$ev"
    local entries="${ev_json[$ev]:-}"
    local first_entry=true
    if [[ -n "$entries" ]]; then
      while IFS= read -r entry_line || [[ -n "$entry_line" ]]; do
        [[ -z "$entry_line" ]] && continue
        [[ "$first_entry" == "false" ]] && printf ',\n'
        first_entry=false
        printf '%s' "$entry_line"
      done <<< "$entries"
      printf '\n'
    fi
    printf '    ]'
  done
  printf '\n  }\n'
  printf '}\n'
}

build_cursor_output() {
  if [[ ! -f "$CURSOR_TMPL" ]]; then
    echo "build-hook-config.sh: template missing: $CURSOR_TMPL" >&2
    exit 2
  fi

  printf '<!-- hooks-workflow: advisory — Cursor does not execute hooks natively. See target-capability-matrix.md -->\n'
  for ev in "${EVENTS[@]}"; do
    local verdict="${EVENT_VERDICT[$ev]}"
    if [[ "$verdict" == "unsupported" ]]; then
      printf '<!-- HOOKS.%s is unsupported on cursor. No config emitted. -->\n' "$ev"
      continue
    fi
    render_template "$CURSOR_TMPL" "$LANGUAGE" "$ev" "$(collect_ev_block "$ev")" ""
  done
}

build_codex_output() {
  if [[ ! -f "$CODEX_TMPL" ]]; then
    echo "build-hook-config.sh: template missing: $CODEX_TMPL" >&2
    exit 2
  fi

  printf '# Advisory only — Codex hooks are under development; verify support in the installed CLI.\n'
  printf '# See research/plugin-additions/evidence/verification-log.md for sourcing.\n\n'
  for ev in "${EVENTS[@]}"; do
    render_template "$CODEX_TMPL" "$LANGUAGE" "$ev" "$(collect_ev_block "$ev")" ""
    printf '\n'
  done
}

# ---------------------------------------------------------------------------
# Generate output
# ---------------------------------------------------------------------------

case "$TARGET" in
  claude) GENERATED_OUTPUT="$(build_claude_output)" ;;
  cursor) GENERATED_OUTPUT="$(build_cursor_output)" ;;
  codex)  GENERATED_OUTPUT="$(build_codex_output)" ;;
esac

# ---------------------------------------------------------------------------
# Force guard for codex writes
# ---------------------------------------------------------------------------

if [[ "$TARGET" == "codex" && "$DRY_RUN" == "false" && -n "$OUT_PATH" && "$FORCE" == "false" ]]; then
  echo "Codex output requires --force to write to disk. Re-run with --force to confirm. Output printed to stdout:" >&2
  printf '%s\n' "$GENERATED_OUTPUT"
  exit 1
fi

# ---------------------------------------------------------------------------
# Output dispatch
# ---------------------------------------------------------------------------

if [[ "$DRY_RUN" == "true" || -z "$OUT_PATH" ]]; then
  printf '%s\n' "$GENERATED_OUTPUT"
  exit 0
fi

# Atomic write via mktemp + mv
TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

printf '%s\n' "$GENERATED_OUTPUT" > "$TMP_FILE"
mv "$TMP_FILE" "$OUT_PATH"

echo "build-hook-config.sh: wrote output to $OUT_PATH" >&2
exit 0
