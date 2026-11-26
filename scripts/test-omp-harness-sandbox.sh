#!/usr/bin/env bash
# test-omp-harness-sandbox.sh — regressions for omp_h_sandbox / omp_h_sandbox_probe in
# scripts/lib/omp-harness-common.sh (YAN-1905), the bubblewrap layout every live OMP harness
# and the Pi harness share.
#
# Path refusals and the fail-closed / --allow-env-i fallback run with bwrap hidden from PATH,
# so they hold on every CI runner. When a working bwrap exists, the suite also checks that the
# layout hides the real home and host runtime dirs, and that the probe rejects a bound socket.
# Off CI, a host whose probe exits or times out without naming a cause skips those two cases.
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

# Exercise both Python selections without needing bubblewrap: the caller's explicit
# interpreter (coexistence/scripted sessions) and the interpreter on the sandbox PATH.
python_home="$SCRATCH/real home"
python_outside="$SCRATCH/real home-sibling"
mkdir -p "$python_home/.venv/bin" "$python_outside" "$SCRATCH/shims"
cp /bin/true "$python_outside/python3"
cp /bin/true "$python_home/python3"
ln -s "$python_outside/python3" "$python_home/.venv/bin/python3"
ln -s "$python_home/.venv/bin" "$SCRATCH/alias-bin"
ln -s "$python_home/python3" "$SCRATCH/shims/python3"

check_python_home() {
  local name=$1 want=$2 mode=$3 path=$4 out rc=0
  shift 4
  out=$( (
    # shellcheck source=lib/omp-harness-common.sh
    source "$LIB"
    sandbox=$mode
    omp_h_check_python_home "$python_home" "$path:$NOBWRAP" "$@"
  ) 2>&1) || rc=$?
  if [[ $want == allow && $rc == 0 ]] ||
    [[ $want == reject && $rc == 1 && $out == 'ERROR: '* &&
      $out == *'put the system python3 first on PATH'* ]]; then
    ok "$name"
  else
    bad "$name: wanted $want, rc=$rc: $out"
  fi
}

check_python_home 'explicit venv symlink to system Python is hidden' reject bwrap-netns \
  "$python_outside" "$python_home/.venv/bin/python3"
check_python_home 'venv on sandbox PATH is hidden' reject bwrap-netns "$python_home/.venv/bin:$python_outside"
check_python_home 'symlinked bin directory under the real home is hidden' reject bwrap-netns "$SCRATCH/alias-bin"
check_python_home 'outside shim targets Python under the real home' reject bwrap-netns "$SCRATCH/shims"
check_python_home 'Python outside the real home passes (including same-prefix sibling)' allow bwrap-netns "$python_outside"
check_python_home 'env-i does not hide the real home' allow env-i "$python_home/.venv/bin" "$python_home/.venv/bin/python3"

bwrap_bin=$(command -v bwrap || true)
if [[ -n "$bwrap_bin" ]] &&
  bwrap --ro-bind / / --dev /dev --proc /proc --unshare-net --unshare-pid /bin/true >/dev/null 2>&1; then
  out=$(run_helper "$PATH" 0 "$ROOT" "$REAL_HOME" /usr/bin) || true
  # A probe that dies without a diagnostic (a host that can't finish it: user-namespace
  # limits, or a scan past its 60 s bound) says nothing about the layout. Skip the probe
  # cases there, as when bwrap is missing; a probe that names a leak still fails. CI
  # (CI=true) never skips: its runners complete the probe, so a failure there is real.
  probe_runs=1
  if [[ "$out" == *'sandbox=bwrap-netns'* ]]; then ok 'bwrap layout passes its probe'
  elif [[ "${CI:-}" != true && "$out" == *'probe failed: probe exited non-zero or timed out'* ]]; then
    probe_runs=0
    printf 'SKIP bwrap layout: the probe cannot run on this host (exited non-zero or timed out without a reason)\n'
  else
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
  if ((probe_runs)); then
    expect_bwrap_refused 'probe rejects a visible host socket' 'host socket or FIFO visible' \
      "$ROOT" "$REAL_HOME" "${SCRATCH}/exposed"
  else
    printf 'SKIP probe rejects a visible host socket: the probe cannot run on this host\n'
  fi
else
  printf 'note: no working bwrap; skipped the live layout checks\n'
fi

printf '%s passed, %s failed\n' "$pass" "$failures"
((failures == 0))
