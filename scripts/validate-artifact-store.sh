#!/usr/bin/env bash
# Check portable Linear pointers and literal artifact paths in generated bundles.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd -P)"
[[ $# -le 1 ]] || { printf 'Usage: validate-artifact-store.sh [<repo-root>]\n' >&2; exit 1; }
ROOT=${1:-${SCRIPT_DIR}/..}
ROOT=$(CDPATH='' cd -- "$ROOT" >/dev/null && pwd -P) || exit 1
[[ "$(git -C "$ROOT" rev-parse --is-inside-work-tree 2>/dev/null || :)" == true ]] || { printf 'ERROR: expected a Git work tree\n' >&2; exit 1; }
# shellcheck source=../ycc/skills/_shared/scripts/resolve-artifact-store.sh
source "${SCRIPT_DIR}/../ycc/skills/_shared/scripts/resolve-artifact-store.sh"
set -euo pipefail
failures=0
fail() { printf 'ERROR: %s\n' "$*" >&2; failures=$((failures + 1)); }
# Scan every pointer in the work tree (tracked, untracked, ignored).
while IFS= read -r -d '' path; do
  case "/${path}" in
    */.claude/worktrees/*|*/.omp/worktrees/*|*/.codex/worktrees/*|*/.opencode/worktrees/*|*/.cursor/worktrees/*|*/node_modules/*) continue ;;
  esac
  [[ "${path##*/}" == .plans-config && -f "${ROOT}/${path}" ]] || continue
  value=$(_artifact_config_value store "${ROOT}/${path}") || value=''
  [[ "$value" == linear ]] || continue
  if ! git --literal-pathspecs -C "$ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then fail "${path}: store: linear pointer must be tracked"; fi
  if git -C "$ROOT" check-ignore -q --no-index -- "$path"; then fail "${path}: committed Linear pointer must not be ignored"; fi
done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard; git -C "$ROOT" ls-files -z --others --ignored --exclude-standard)
count_literal() {
  local literal="$1" tree="$2"
  { grep -I -o -F -- "$literal" "$tree" || :; } | wc -l | tr -d '[:space:]'
}
source_tree="${ROOT}/ycc/skills"
shared_tree="${ROOT}/ycc/skills/_shared"
pointer_helper="${shared_tree}/scripts/artifact-store-pointer.sh"
if [[ ! -d "$source_tree" ]]; then
  printf 'NOTE: ycc/skills absent; skipping bundle parity.\n'
else
  # Skills-tree pairs keep _shared inline (cursor, omp); codex, opencode, and
  # agents export shared assets beside the skills tree, and the OpenCode
  # package ships both trees, so compare each of them explicitly.
  for tree in .codex-plugin/ycc/skills .opencode-plugin/skills .agents-plugin/skills packages/cursor/ycc/skills packages/omp/ycc/skills packages/opencode/ycc-opencode/skills; do
    if [[ ! -d "${ROOT}/${tree}" ]]; then printf 'NOTE: %s absent; skipping parity (run sync to generate it).\n' "$tree"; continue; fi
    # Codex/opencode/agents export shared assets outside the skills tree;
    # cursor/omp include _shared here. Compare common relative files, rather
    # than count omitted shared assets as rewritten paths.
    while IFS= read -r -d '' file; do
      relative=${file#"${ROOT}/${tree}/"}
      [[ -f "${source_tree}/${relative}" ]] || continue
      grep -qE '\.ycc/artifacts|\.plans-config' "${source_tree}/${relative}" "$file" || continue
      for literal in .ycc/artifacts .plans-config; do
        expected=$(count_literal "$literal" "${source_tree}/${relative}")
        actual=$(count_literal "$literal" "$file")
        if [[ "$expected" != "$actual" ]]; then fail "${tree}/${relative}: literal ${literal} count ${actual}, expected ${expected} from ycc/skills"; fi
      done
    done < <(find "${ROOT}/${tree}" -type f -print0)
  done
  if [[ -d "$shared_tree" ]]; then
    for tree in .codex-plugin/ycc/shared .opencode-plugin/shared .agents-plugin/ycc-shared packages/opencode/ycc-opencode/shared; do
      if [[ ! -d "${ROOT}/${tree}" ]]; then printf 'NOTE: %s absent; skipping parity (run sync to generate it).\n' "$tree"; continue; fi
      while IFS= read -r -d '' file; do
        relative=${file#"${ROOT}/${tree}/"}
        [[ -f "${shared_tree}/${relative}" ]] || continue
        grep -qE '\.ycc/artifacts|\.plans-config' "${shared_tree}/${relative}" "$file" || continue
        for literal in .ycc/artifacts .plans-config; do
          expected=$(count_literal "$literal" "${shared_tree}/${relative}")
          actual=$(count_literal "$literal" "$file")
          if [[ "$expected" != "$actual" ]]; then fail "${tree}/${relative}: literal ${literal} count ${actual}, expected ${expected} from ycc/skills/_shared"; fi
        done
      done < <(find "${ROOT}/${tree}" -type f -print0)
    done
    # A dropped command line (for example by an OpenCode transform) also drops
    # its --linear-* flag occurrences; count them so line removal is caught.
    if [[ -f "$pointer_helper" ]]; then
      source_pointer_linear=$(count_literal '--linear-' "$pointer_helper")
      for tree in .codex-plugin/ycc/shared .opencode-plugin/shared .agents-plugin/ycc-shared packages/cursor/ycc/skills/_shared packages/omp/ycc/skills/_shared packages/opencode/ycc-opencode/shared; do
        copy="${ROOT}/${tree}/scripts/artifact-store-pointer.sh"
        [[ -f "$copy" ]] || { printf 'NOTE: %s absent; skipping pointer parity.\n' "${tree}/scripts/artifact-store-pointer.sh"; continue; }
        copy_linear=$(count_literal '--linear-' "$copy")
        if [[ "$copy_linear" != "$source_pointer_linear" ]]; then
          fail "${tree}/scripts/artifact-store-pointer.sh: --linear- occurrences ${copy_linear}, expected ${source_pointer_linear} from ycc/skills/_shared"
        fi
        if ! "${BASH_BIN:-bash}" -n "$copy"; then fail "${tree}/scripts/artifact-store-pointer.sh: bash -n syntax error"; fi
      done
    fi
  fi
fi
if [[ "$failures" != 0 ]]; then printf 'Artifact store validation failed: %s failure(s).\n' "$failures" >&2; exit 1; fi
printf 'Artifact store pointers and bundle parity passed.\n'
