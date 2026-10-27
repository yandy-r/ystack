#!/usr/bin/env bash
# Print an artifact without its complete leading frontmatter block.
# Frontmatter starts and ends with exact --- lines (ignoring CR), and its first
# non-blank line must be a top-level YAML key (^[A-Za-z_][A-Za-z0-9_.-]*: then
# whitespace or end of line); blank-only blocks qualify. Otherwise preserve the
# whole file, including a leading Markdown thematic break or comment line.
# Source for artifact_body, or execute with one file argument.
# shellcheck disable=SC2094 # fallbacks re-read the whole file by name
_artifact_body() {
  local file="$1"
  # Read through a redirect on a brace group instead of exec so the caller's
  # file descriptors stay untouched. After read, a regular file's offset sits
  # just past the consumed line, so cat prints the rest of the body.
  {
    local line first stripped
    local first_key=0 key_pattern='^[A-Za-z_][A-Za-z0-9_.-]*:([[:space:]]|$)' blank_pattern='^[[:space:]]*$'
    IFS= read -r first || { command cat -- "$file"; return; }
    first=${first%$'\r'}
    if [[ "$first" != '---' ]]; then
      command cat -- "$file"
      return
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      stripped=${line%$'\r'}
      if [[ "$stripped" == '---' ]]; then
        command cat
        return 0
      fi
      if [[ "$first_key" == 0 && ! "$stripped" =~ $blank_pattern ]]; then
        if [[ ! "$stripped" =~ $key_pattern ]]; then
          command cat -- "$file"
          return
        fi
        first_key=1
      fi
    done
    command cat -- "$file"
  } <"$file"
}

artifact_body() {
  if [[ $# -ne 1 || -z "$1" || ! -f "$1" ]]; then
    printf 'ERROR: artifact_body expects one readable file\n' >&2
    return 1
  fi
  if [[ ! -r "$1" ]]; then
    printf 'ERROR: Artifact body is not readable: %s\n' "$1" >&2
    return 1
  fi
  _artifact_body "$1"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  artifact_body "$@"
fi
