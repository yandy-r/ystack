#!/usr/bin/env bash
# test-omp-harness-sandbox.sh — regressions for omp_h_sandbox / omp_h_sandbox_probe in
# scripts/lib/omp-harness-common.sh (YAN-1905), the bubblewrap layout every live OMP harness
# and the Pi harness share.
#
# Path refusals and the fail-closed / --allow-env-i fallback run with bwrap hidden from PATH,
# so they hold on every CI runner. When a working bwrap exists, the suite also checks that the
# layout hides the real home and host runtime dirs, and that the probe rejects a bound socket.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LIB="${REPO_ROOT}/scripts/lib/omp-harness-common.sh"
SCRATCH="$(mktemp -d /tmp/ycc-harness-sandbox.XXXXXX)"
SCRATCH="$(realpath "$SCRATCH")"
trap 'rm -rf "$SCRATCH"' EXIT
REAL_HOME="$(realpath "${HOME:?HOME must be set}")"
ROOT="${SCRATCH}/root"
mkdir -p "$ROOT"
# A PATH with the coreutils the helper needs but no bwrap.
NOBWRAP="${SCRATCH}/nobwrap"
mkdir -p "$NOBWRAP"
for tool in realpath env; do ln -s "$(command -v "$tool")" "${NOBWRAP}/${tool}"; done

pass=0
failures=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

# run_helper PATH ALLOW ROOT HOME [RO...]: call omp_h_sandbox in a fresh bash; prints its
# stdout/stderr and the selected sandbox, returns its exit status.
run_helper() {
  local path=$1
  shift
  PATH="$path" "$BASH" -c '
    set -euo pipefail
    source "$1"; shift
    omp_h_sandbox "$@"
    printf "sandbox=%s wrap=%s\n" "$sandbox" "${#wrap[@]}"
  ' test-sandbox "$LIB" "$@" 2>&1
}

# expect_refused NAME PATTERN ARGS...: the helper (bwrap hidden) exits non-zero with PATTERN.
expect_refused() {
  local name=$1 pattern=$2 out rc=0
  shift 2
  out=$(run_helper "$NOBWRAP" 0 "$@") || rc=$?
  if ((rc != 0)) && grep -qF -- "$pattern" <<<"$out"; then ok "$name"; else
    bad "$name: rc=$rc, expected '$pattern' in: $out"
  fi
}

expect_refused 'relative RO path' 'not absolute or is /' "$ROOT" "$REAL_HOME" relative/bin
expect_refused 'RO path /' 'not absolute or is /' "$ROOT" "$REAL_HOME" /
expect_refused 'RO path is the real home' "re-expose $REAL_HOME" "$ROOT" "$REAL_HOME" "$REAL_HOME"
expect_refused 'RO path contains the real home' "re-expose $REAL_HOME" \
  "$ROOT" "$REAL_HOME" "$(dirname "$REAL_HOME")"
expect_refused 'RO path is /tmp' 're-expose /tmp' "$ROOT" "$REAL_HOME" /tmp
expect_refused 'RO path contains /run' 're-expose /run' "$ROOT" "$REAL_HOME" /run
expect_refused 'RO path contains /var/tmp' 're-expose /var/tmp' "$ROOT" "$REAL_HOME" /var
expect_refused 'RO path inside the writable root' 'inside the writable sandbox root' \
  "$ROOT" "$REAL_HOME" "${ROOT}/bin"
expect_refused 'root under the real home' 'must not be or live under the real HOME' \
  "${REAL_HOME}/sandbox" "$REAL_HOME"
expect_refused 'real home is /' 'absolute path other than /' "$ROOT" /
expect_refused 'no bwrap fails closed' 'refusing to run without network/home isolation' \
  "$ROOT" "$REAL_HOME"

out=$(run_helper "$NOBWRAP" 1 "$ROOT" "$REAL_HOME" /usr/bin) || true
if [[ "$out" == *'sandbox=env-i wrap=0'* ]]; then ok 'no bwrap + --allow-env-i selects env-i'; else
  bad "no bwrap + --allow-env-i: $out"
fi

bwrap_bin=$(command -v bwrap || true)
if [[ -n "$bwrap_bin" ]] &&
  bwrap --ro-bind / / --dev /dev --proc /proc --unshare-net --unshare-pid /bin/true >/dev/null 2>&1; then
  out=$(run_helper "$PATH" 0 "$ROOT" "$REAL_HOME" /usr/bin) || true
  if [[ "$out" == *'sandbox=bwrap-netns'* ]]; then ok 'bwrap layout passes its probe'; else
    bad "bwrap layout: $out"
  fi
  expect_bwrap_refused() {
    local name=$1 pattern=$2 rc=0
    shift 2
    out=$(run_helper "$PATH" 0 "$@") || rc=$?
    if ((rc != 0)) && grep -qF -- "$pattern" <<<"$out"; then ok "$name"; else
      bad "$name: rc=$rc, expected '$pattern' in: $out"
    fi
  }
  expect_bwrap_refused 'non-canonical RO path' 'non-canonical path' \
    "$ROOT" "$REAL_HOME" "${SCRATCH}/../$(basename "$SCRATCH")/root2"
  # A socket bound back into the sandbox must fail the probe.
  mkdir -p "${SCRATCH}/exposed"
  python3 - "${SCRATCH}/exposed/host.sock" <<'PY'
import socket, sys
socket.socket(socket.AF_UNIX).bind(sys.argv[1])
PY
  expect_bwrap_refused 'probe rejects a visible host socket' 'host socket or FIFO visible' \
    "$ROOT" "$REAL_HOME" "${SCRATCH}/exposed"
else
  printf 'note: no working bwrap; skipped the live layout checks\n'
fi

printf '%s passed, %s failed\n' "$pass" "$failures"
((failures == 0))
