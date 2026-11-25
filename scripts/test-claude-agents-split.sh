#!/usr/bin/env bash
# Opt-in live dispatch proof for the hidden v7 Claude split (YAN-1142).
#
# Builds the split tree (skills-only ycc + agents-only ycc-agents) into a disposable
# lab with scripts/claude_agents_split.py, installs only ycc@ycc-split-lab with the
# local Claude CLI, and asserts ycc-agents arrives through ycc's dependencies. Then,
# for every dispatching skill in the package graph, a loopback fake Messages API
# scripts Skill(ycc:<skill>) -> Agent(ycc-agents:<agent>) and the child request must
# carry that agent's own prompt. Plus a negative control (ycc-agents:absent errors)
# and one recorded bare-name dispatch. No real inference, credentials or user config.
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: scripts/test-claude-agents-split.sh [--keep]

Explicit opt-in (never run by validate.sh). Uses CLAUDE_BIN or `claude` on PATH in
an env -i lab with isolated HOME/CLAUDE_CONFIG_DIR/XDG/TMPDIR and a 127.0.0.1 fake
API. Real ~/.claude settings/plugin config is snapshotted before and after and must not
change; live-session state is skipped, so concurrent Claude sessions are OK.
--keep     Retain the lab, transcripts and request logs.
-h, --help Show this text.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

keep=0
while (($#)); do
  case "$1" in
    --keep) keep=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for tool in python3 timeout mktemp realpath; do
  command -v "$tool" >/dev/null 2>&1 || die "missing prerequisite: $tool"
done

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
split=$repo/scripts/claude_agents_split.py
smoke=$repo/scripts/claude_agents_split_smoke.py
helper=$repo/scripts/claude_namespace_fake_api.py
for file in "$split" "$smoke" "$helper"; do
  [[ -f "$file" ]] || die "missing harness file: $file"
done
claude=${CLAUDE_BIN:-$(command -v claude || true)}
[[ -n "$claude" && -x "$claude" ]] || die 'install Claude Code or set CLAUDE_BIN'
claude=$(realpath "$claude")
python=$(command -v python3)
real_home=$(realpath -m -- "${HOME:?HOME required for the read-only config snapshot}")
real_config=$(realpath -m -- "${CLAUDE_CONFIG_DIR:-$real_home/.claude}")

work_parent=${VERIFY_TEMP_DIR:-/tmp}
[[ -d "$work_parent" ]] || die 'VERIFY_TEMP_DIR must exist'
work_parent=$(realpath "$work_parent")
root=$(mktemp -d "$work_parent/claude-agents-split.XXXXXX")
mkdir -p "$root"/{home,tmp,logs,market}

safe_path="$(dirname "$python"):$(dirname "$claude"):$(dirname "$(command -v node || command -v python3)"):/usr/local/bin:/usr/bin:/bin"
clean() {
  env -i PATH="$safe_path" LANG=C.UTF-8 LC_ALL=C.UTF-8 TERM=dumb NO_COLOR=1 \
    HOME="$root/home" CLAUDE_CONFIG_DIR="$root/home/claude" \
    XDG_CONFIG_HOME="$root/home/config" XDG_DATA_HOME="$root/home/data" \
    XDG_STATE_HOME="$root/home/state" XDG_CACHE_HOME="$root/home/cache" \
    XDG_RUNTIME_DIR="$root/home/runtime" TMPDIR="$root/tmp" \
    DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    PYTHONDONTWRITEBYTECODE=1 "$@"
}

# Always prove the real config is unchanged, even on early failure; remove only our root.
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -f "$root/config-before.json" ]]; then
    clean "$python" "$helper" snapshot "$root/config-after.json" "$real_config" "$real_home/.claude.json" || rc=1
    clean "$python" "$helper" compare "$root/config-before.json" "$root/config-after.json" || rc=1
  else
    printf 'real-config proof skipped: no before-snapshot (early failure)\n'
    rc=1
  fi
  if ((keep)); then
    printf 'Retained evidence: %s (exit=%s)\n' "$root" "$rc"
  else
    printf 'Removed evidence: %s (use --keep; exit=%s)\n' "$root" "$rc"
    rm -rf -- "$root"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

clean "$python" "$helper" snapshot "$root/config-before.json" "$real_config" "$real_home/.claude.json"
version=$(clean timeout -k 5 30 "$claude" --version | awk '{print $1}')
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected claude --version: $version"
printf 'claude CLI: %s (%s)\n' "$version" "$claude" | tee "$root/transcript.log"

clean "$python" "$split" --out "$root/market" | tee -a "$root/transcript.log"
for package in market/ycc market/ycc-agents market; do
  clean timeout -k 5 60 "$claude" plugin validate "$root/$package" >>"$root/transcript.log" 2>&1 ||
    die "claude plugin validate failed: $package"
done

clean timeout -k 10 1800 "$python" "$smoke" "$root/run" "$claude" "$version" "$root/market" \
  2>&1 | tee -a "$root/transcript.log"
grep -q "^$version split dispatch: \([0-9]*\)/\1 skills verified$" "$root/transcript.log" ||
  die 'split dispatch verification marker missing (look for CHECK FAILED above)'
printf 'PASS Claude agents split: dependency install, every dispatching skill, negative control\n' |
  tee -a "$root/transcript.log"
