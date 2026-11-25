#!/usr/bin/env bash
# Opt-in YAN-1121: isolated npm installs + loopback fake inference, no real auth.
set -euo pipefail
umask 077

# Print opt-in usage; running this script is the explicit network/install consent.
usage() {
  cat <<'EOF'
Usage: test-claude-namespace-spike.sh [--keep] [--output-dir DIR] [--versions LIST]

Default versions: 2.1.143,latest (latest is resolved then installed exactly).
A resolved version without expected-behavior entries exits INCONCLUSIVE (nonzero).
Requires npm, node, python3, timeout and Linux utilities. npm registry network is
used only for lab-local pinned installs (no global install/update). Claude uses a
127.0.0.1 fake Messages API and dummy key; no real credentials are inherited.
--keep            Retain sandbox/evidence (otherwise removed even on failure).
--output-dir DIR  Existing parent under /tmp/opencode; implies --keep.
--versions LIST   Comma-separated exact stable versions and/or latest, no repeats.
-h, --help        Show help. Default sandbox: mktemp under /tmp/opencode.

Fail-closed: exit 0 only if EVERY requested version verified all matrix
expectations (look for "assert_matrix: all expectations verified" per version).
Inconclusive or unsupported paths exit nonzero. Fresh HOME/CLAUDE_CONFIG_DIR/
XDG/TMPDIR/npm prefix and empty non-git cwd; no repo plugins, executable fixture
hooks, real user settings, or credentials are copied. Nonessential traffic and
updates are disabled; egress is NOT OS-firewalled (see doc best-effort boundary).
Real settings/plugin config hashes must match before/after; live-session state
(sessions, backups, stamps, caches) is skipped, so concurrent Claude use is OK.
EOF
}
# Emit fatal diagnostics without printing inherited environment values.
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
keep=0
parent=/tmp/opencode
versions=2.1.143,latest
while (($#)); do
  case "$1" in
    --keep) keep=1; shift ;;
    --output-dir) (($# >= 2)) || die '--output-dir requires DIR'; parent=$2; keep=1; shift 2 ;;
    --versions) (($# >= 2)) || die '--versions requires LIST'; versions=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
for tool in npm node python3 timeout mktemp realpath sha256sum; do
  command -v "$tool" >/dev/null || die "missing prerequisite: $tool"
done
[[ "$versions" =~ ^(latest|[0-9]+\.[0-9]+\.[0-9]+)(,(latest|[0-9]+\.[0-9]+\.[0-9]+))*$ ]] || die 'invalid version list'
IFS=, read -r -a requested_versions <<<"$versions"
((${#requested_versions[@]} == $(printf '%s\n' "${requested_versions[@]}" | sort -u | wc -l))) ||
  die "duplicate requested versions: $versions"
[[ -d "$parent" ]] || die 'output parent must exist'
parent=$(realpath "$parent")
[[ "$parent" == /tmp/opencode || "$parent" == /tmp/opencode/* ]] || die 'output must be under /tmp/opencode'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
helper=$script_dir/claude_namespace_fake_api.py
[[ -f "$helper" ]] || die 'missing fake API helper'
real_home=$(realpath -m -- "${HOME:?HOME required for read-only config snapshot}")
real_config=$(realpath -m -- "${CLAUDE_CONFIG_DIR:-$real_home/.claude}")
# Run scrubbed children: no inherited credentials, proxies, NODE_OPTIONS or Git config.
clean() {
  env -i PATH="$safe_path" LANG=C.UTF-8 TERM=dumb NO_COLOR=1 \
    HOME="$root/bootstrap" CLAUDE_CONFIG_DIR="$root/bootstrap/claude" \
    XDG_CONFIG_HOME="$root/bootstrap/config" XDG_DATA_HOME="$root/bootstrap/data" \
    XDG_STATE_HOME="$root/bootstrap/state" XDG_CACHE_HOME="$root/bootstrap/cache" \
    XDG_RUNTIME_DIR="$root/bootstrap/runtime" TMPDIR="$root/tmp" \
    npm_config_cache="$root/bootstrap/npm-cache" npm_config_userconfig="$root/bootstrap/user.npmrc" \
    npm_config_globalconfig="$root/bootstrap/global.npmrc" npm_config_registry=https://registry.npmjs.org \
    DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    GIT_ALLOW_PROTOCOL=file PYTHONDONTWRITEBYTECODE=1 "$@"
}
# Always verify real config unchanged, even on early errors/signals; remove only our root.
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -f "$root/driver.pid" ]]; then
    local pgid
    pgid=$(<"$root/driver.pid")
    if [[ "$pgid" =~ ^[0-9]+$ ]]; then
      kill -TERM -- "-$pgid" 2>/dev/null || true
      sleep 1
      kill -KILL -- "-$pgid" 2>/dev/null || true
    fi
    [[ -z "${driver_pid:-}" ]] || wait "$driver_pid" 2>/dev/null || true
  fi
  if [[ -f "$root/config-before.json" ]]; then
    clean python3 "$helper" snapshot "$root/config-after.json" "$real_config" "$real_home/.claude.json" || rc=1
    clean python3 "$helper" compare "$root/config-before.json" "$root/config-after.json" \
      >"$root/config-proof.log" 2>&1 || rc=1
    cat "$root/config-proof.log"
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
safe_path="$(dirname "$(command -v node)"):$(dirname "$(command -v npm)"):/usr/local/bin:/usr/bin:/bin"
root=$(mktemp -d "$parent/claude-namespace-spike.XXXXXX")
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$root"/{bootstrap,work,tmp,logs}
: >"$root/bootstrap/user.npmrc"
: >"$root/bootstrap/global.npmrc"

clean python3 "$helper" snapshot "$root/config-before.json" "$real_config" "$real_home/.claude.json"
cd "$root/work"
verified=0
declare -A seen_resolved
printf 'YAN-1121 | %s | requested=%s\n' "$(date -u +%F)" "$versions" | tee "$root/transcript.log"
for requested in "${requested_versions[@]}"; do
  # Resolve latest exactly once; strict version guard prevents injecting npm arguments.
  resolved=$(clean timeout -k 5 60 npm view "@anthropic-ai/claude-code@$requested" version 2>"$root/logs/resolve-$requested.stderr") || die "npm resolution failed: $requested"
  [[ "$resolved" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected npm version: $resolved"
  [[ -z "${seen_resolved[$resolved]:-}" ]] || die "duplicate resolved version: $resolved (requested: $requested)"
  seen_resolved[$resolved]=1
  prefix=$root/npm-$resolved
  printf 'requested=%s resolved=%s\n' "$requested" "$resolved" | tee -a "$root/transcript.log"
  clean timeout -k 5 180 npm install --prefix "$prefix" --no-audit --no-fund --loglevel=error \
    "@anthropic-ai/claude-code@$resolved" >"$root/logs/install-$requested.log" 2>&1 || die "lab npm install failed: $resolved"
  binary=$prefix/node_modules/.bin/claude
  actual=$(clean timeout -k 5 30 "$binary" --version 2>&1) || actual=
  # Some npm versions/configurations omit the linking postinstall step. The pinned
  # optional native package is a safe lab-local fallback, never the global CLI.
  if [[ "$actual" != "$resolved (Claude Code)" ]]; then
    case "$(uname -m)" in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; *) die 'unsupported Linux architecture' ;; esac
    binary=$prefix/node_modules/@anthropic-ai/claude-code-linux-$arch/claude
    [[ -x "$binary" ]] || die "missing pinned native CLI: $resolved"
    actual=$(clean timeout -k 5 30 "$binary" --version)
  fi
  [[ "$actual" == "$resolved (Claude Code)" ]] || die "version mismatch: $actual"
  printf 'CLI=%s binary_sha256=%s\n' "$actual" "$(sha256sum "$binary" | cut -d ' ' -f1)" | tee -a "$root/transcript.log"
  # Run in its own process group so timeout can kill the python driver AND the claude
  # children it spawns; the driver also kills each claude session group (best effort).
  clean timeout -k 10 1500 python3 "$helper" run "$root/run-$requested" "$binary" "$resolved" \
    >"$root/logs/driver-$requested.log" 2>&1 &
  driver_pid=$!
  driver_rc=0
  wait "$driver_pid" || driver_rc=$?
  driver_pid=
  rm -f -- "$root/driver.pid"
  tee -a "$root/transcript.log" <"$root/logs/driver-$requested.log"
  ((driver_rc == 0)) || die "matrix verification failed: $resolved (look for CHECK FAILED above)"
  grep -q "$resolved assert_matrix: all expectations verified" "$root/run-$requested/transcript.log" \
    || die "missing verification marker: $resolved"
  verified=$((verified + 1))
done
((verified == ${#requested_versions[@]})) || die "verified $verified of ${#requested_versions[@]} versions"
printf 'VERIFIED: %s of %s requested versions; matrix assertions passed.\n' "$verified" "${#requested_versions[@]}" | tee -a "$root/transcript.log"
