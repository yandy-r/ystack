#!/usr/bin/env bash
# Opt-in live checks for OMP herdr session reporting (YAN-1174): herdr's own OMP integration
# (`herdr integration install omp`) reports sessions; ycc ships no OMP hook code. Not part of CI.
# No credentials, no network inside the sandbox, no model inference, never the real herdr.
# shellcheck disable=SC2154 # sandbox and wrap come from lib/omp-harness-common.sh
set -euo pipefail
umask 077
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/omp-harness-common.sh"

usage() {
  cat <<'EOF'
Usage: test-omp-herdr-hooks.sh [--keep] [--allow-env-i] [--herdr-pane]

Requires omp >=18.12.2 (OMP_BIN overrides PATH), herdr (HERDR_BIN overrides PATH), git,
python3 with the repository's generator dependencies, timeout, and bubblewrap with working
--unshare-net/--unshare-pid. Both binaries must be self-contained: the sandbox hides the real
home, /run and /tmp behind tmpfs and runs with PATH=/usr/local/bin:/usr/bin:/bin. Missing omp
or herdr prints SKIP and exits 2 (this harness is opt-in).

Every omp and herdr call runs under env -i with HOME/XDG/TMPDIR inside a mktemp sandbox, and
under bwrap with private network and PID namespaces and a read-only host tree. Without bwrap the
harness refuses to run unless --allow-env-i accepts the weaker env -i sandbox. Every HERDR_*
variable of the calling shell is dropped; the only herdr sockets are a Python fake recorder
and (with --herdr-pane) an isolated `herdr server`, both inside the sandbox. The only model is
a null provider on 127.0.0.1:9 and no prompt is sent.

Setup: herdr's integration is installed into the sandbox HOME (`herdr integration install
omp`; `herdr integration status` must report `omp: current`). Sessions run `omp --mode rpc`
(hasUI true, so the integration's root-session gate passes) and send get_state, new_session.

Cases:
  L1 trigger      one report_agent_session with session_start_source startup, one with new
  L2 payload      pane_id, source herdr:omp, agent omp, integer seq strictly increasing in
                  connection-accept order, absolute agent_session_path naming the RPC
                  sessionId, schema-required keys
  L3 fail-closed  recorder at herdr's default socket, HERDR_SOCKET_PATH and HERDR_PANE_ID set,
                  HERDR_ENV unset: zero connections, session ready
  L4 error        socket missing (refused): no extension_error, get_state answered
  L5 timeout      stalled socket: get_state within 5 s of ready, exit within hold + 3 s
  L6 cancel       stalled socket (at least one connection), stdin closed after get_state:
                  exit within 3 s
  L7 duplicates   with ycc@ycc and ycc-mcp@ycc installed from a local marketplace fixture
                  (generate_omp_packages.py --export): only herdr:omp, one session+state pair
                  per event, no ycc package extension carries a herdr reporter marker
  L8 real herdr   (--herdr-pane) an isolated herdr server runs omp in pane w1:p1; the pane
                  reports agent omp with a herdr:omp session, and a ycc:omp
                  report_agent_session leaves it unchanged

--keep        Retain the sandbox and transcript (always retained when a case fails).
--herdr-pane  Also run L8 against an isolated herdr server.
EOF
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
skip() { printf 'SKIP: %s (opt-in harness: install it or set OMP_BIN/HERDR_BIN)\n' "$*" >&2; exit 2; }
keep=0
allow_env_i=0
herdr_pane=0
while (($#)); do
  case "$1" in
    --keep) keep=1; shift ;;
    --allow-env-i) allow_env_i=1; shift ;;
    --herdr-pane) herdr_pane=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
# HERDR_BIN is the only HERDR_* value read; then every inherited HERDR_* is dropped so a live
# herdr session (this harness may run inside a herdr pane) never reaches a sandboxed process.
herdr=${HERDR_BIN:-$(command -v herdr || true)}
while IFS= read -r var; do unset "$var"; done < <(compgen -A export -X '!HERDR_*' || true)
for tool in git python3 timeout mktemp realpath setsid; do
  command -v "$tool" >/dev/null || die "missing prerequisite: $tool"
done

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
checks=$repo/scripts/omp_herdr_smoke.py
omp=${OMP_BIN:-$(command -v omp || true)}
[[ -n "$omp" && -x "$omp" ]] || skip 'omp not found'
omp=$(realpath "$omp")
[[ -n "$herdr" && -x "$herdr" ]] || skip 'herdr not found'
herdr=$(realpath "$herdr")
python=$(command -v python3)
real_home=$(realpath "${HOME:?HOME must be set}")
root=$(omp_h_mktemp_root omp-herdr-hooks)
[[ "$root" != "$real_home" && "$root" != "$real_home"/* ]] || die 'sandbox must not live under the real HOME'
pids=()
herdr_pgid=
cleanup() {
  local rc=$?
  if [[ -n "$herdr_pgid" ]]; then
    kill -TERM -- "-$herdr_pgid" 2>/dev/null || true
    sleep 0.3
    kill -KILL -- "-$herdr_pgid" 2>/dev/null || true
  fi
  for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
  if ((keep || rc != 0)); then
    if ((rc != 0)) && [[ -s "$root/transcript.log" ]]; then
      printf '\n--- last 40 transcript lines (%s/transcript.log) ---\n' "$root" >&2
      tail -n 40 -- "$root/transcript.log" >&2
    fi
    printf 'Retained sandbox and transcript: %s/transcript.log (exit=%s)\n' "$root" "$rc"
  else
    printf 'Sandbox removed (use --keep for evidence; exit=%s): %s\n' "$rc" "$root"
    rm -rf -- "$root"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$root"/{work,tmp,logs,case,s}
umask 022
cd "$root/work"
safe_path=/usr/local/bin:/usr/bin:/bin
url=https://omp-herdr.invalid/fork.git
fork=$root/fork.git
case_home=$root/case
home=$(realpath -m "$case_home/home")
omp_home=$home/.omp
[[ "$home" == "$root"/* && "$home" != "$real_home" && "$home" != "$real_home"/* ]] ||
  die "refusing to run with HOME=$home outside $root"
mkdir -p "$case_home"/{home,config,data,state,cache,runtime}
# Empty shell rc files: `herdr pane run` types into the pane's interactive shell.
: >"$home/.zshrc"
: >"$home/.profile"

omp_h_sandbox "$allow_env_i" "$root" "$real_home" "$omp" "$herdr"

# No inherited environment; isolated HOME/XDG tree; file-only git. Callers may append
# NAME=VALUE assignments (env parses them) before the command.
clean_env=(env -i PATH="$safe_path" LANG=C.UTF-8 TERM=dumb NO_COLOR=1 SHELL=/bin/sh
  HOME="$home" XDG_CONFIG_HOME="$case_home/config" XDG_DATA_HOME="$case_home/data"
  XDG_STATE_HOME="$case_home/state" XDG_CACHE_HOME="$case_home/cache"
  XDG_RUNTIME_DIR="$case_home/runtime" TMPDIR="$root/tmp"
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
  GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false GIT_ALLOW_PROTOCOL=file GIT_CONFIG_COUNT=2
  GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=
  GIT_CONFIG_KEY_1="url.file://$fork.insteadOf" GIT_CONFIG_VALUE_1="$url")
clean() { "${clean_env[@]}" "$@"; }
for bin in "$omp" "$herdr"; do
  clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 30 "$bin" --version >/dev/null 2>&1 ||
    die "$bin does not run inside the $sandbox sandbox: it must be a self-contained binary (env -i PATH=$safe_path, real home hidden)"
done
log() { printf '%s\n' "$*" | tee -a "$root/transcript.log"; }
rc=0
# Record argv, exit status and (sandbox-relative) output of one command in the transcript.
record() {
  local label=$1; shift
  {
    printf '\n[%s] argv:' "$label"; printf ' %q' "${@/#"$root"/<SANDBOX>}"
    printf '\nexit=%s\nstdout:\n' "$rc"; head -c 4000 "$root/logs/$label.stdout" | sed "s#$root#<SANDBOX>#g"
    printf '\nstderr:\n'; head -c 2000 "$root/logs/$label.stderr" | sed "s#$root#<SANDBOX>#g"; printf '\n'
  } >>"$root/transcript.log"
}
# Run under the sandbox and record. Callers check $rc.
run() {
  local label=$1; shift
  rc=0
  clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 90 "$@" </dev/null >"$root/logs/$label.stdout" 2>"$root/logs/$label.stderr" || rc=$?
  record "$label" "$@"
}
o() { local label=$1; shift; run "$label" "$omp" "$@"; }
h() { local label=$1; shift; run "$label" "$herdr" "$@"; }
# Host-side helper (git fixture, Python checks): env -i, no sandbox wrapper.
host() {
  local label=$1; shift
  rc=0
  clean timeout -k 5 300 "$@" >"$root/logs/$label.stdout" 2>"$root/logs/$label.stderr" || rc=$?
  record "$label" "$@"
  return "$rc"
}
# py LABEL SUBCOMMAND ARGS...: one omp_herdr_smoke check; its message goes to the transcript.
py() {
  local label=$1; shift
  if host "$label" "$python" "$checks" "$@"; then
    log "  $(<"$root/logs/$label.stdout")"
  else
    log "  $(<"$root/logs/$label.stderr")"
    return 1
  fi
}
# herdr_env SOCKET PANE: the HERDR_* assignments for one session; the socket stays in $root.
herdr_env() {
  local sock
  sock=$(realpath -m "$1")
  [[ "$sock" == "$root"/* ]] || die "HERDR_SOCKET_PATH=$sock resolves outside $root"
  henv=(HERDR_ENV=1 "HERDR_SOCKET_PATH=$sock" "HERDR_PANE_ID=$2")
}
# start_recorder NAME MODE [SOCKET]: a fake herdr socket (default $root/s/NAME.sock) logging to $rec_log.
start_recorder() {
  rec_sock=${3:-$root/s/$1.sock}
  rec_log=$root/logs/$1.rec.jsonl
  mkdir -p "${rec_sock%/*}"
  "${clean_env[@]}" "$python" "$checks" recorder "$rec_sock" "$2" "$rec_log" \
    >"$root/logs/$1.recorder.log" 2>&1 &
  rec_pid=$!
  pids+=("$rec_pid")
  for _ in {1..50}; do [[ -e "$rec_log.ready" ]] && return 0; sleep 0.1; done
  return 1
}
stop_recorder() { kill "$rec_pid" 2>/dev/null || true; wait "$rec_pid" 2>/dev/null || true; }
model='omp-herdr-null/null-model'
# session LABEL [session options] -- [NAME=VALUE...]: one `omp --mode rpc` run.
session() {
  local label=$1; shift
  local opts=()
  while (($#)) && [[ "$1" != -- ]]; do opts+=("$1"); shift; done
  shift
  host "$label" "$python" "$checks" session ${opts[@]+"${opts[@]}"} "$root/logs/$label.session.json" -- \
    env "$@" ${wrap[@]+"${wrap[@]}"} timeout -k 5 90 "$omp" --mode rpc --no-title --model "$model"
}
pane=w1:p1
results=()
failed=0
# run_case NAME DESCRIPTION FUNCTION: PASS/FAIL line; failures do not stop later cases.
run_case() {
  log "--- $1: $2"
  if "$3"; then
    results+=("PASS $1 $2"); log "PASS $1"
  else
    results+=("FAIL $1 $2"); log "FAIL $1"; failed=1
  fi
}

# --- Preflight -----------------------------------------------------------------------------
o version --version
((rc == 0)) || die 'omp --version failed inside the sandbox'
omp_version=$(<"$root/logs/version.stdout")
"$python" - "$omp_version" <<'PY' || die "omp >=18.12.2 required, got: $omp_version"
import re, sys
match = re.search(r"(\d+)\.(\d+)\.(\d+)", sys.argv[1])
sys.exit(0 if match and tuple(map(int, match.groups())) >= (18, 12, 2) else 1)
PY
h herdr-version --version
((rc == 0)) || die 'herdr --version failed inside the sandbox'
herdr_version=$(<"$root/logs/herdr-version.stdout")
log "YAN-1174 | $omp_version | $herdr_version | sandbox=$sandbox | root=$root"

# Null model provider: lets RPC sessions start; no prompt is ever sent.
mkdir -p "$omp_home/agent/extensions"
cat >"$omp_home/agent/models.yml" <<'EOF'
providers:
  omp-herdr-null:
    baseUrl: http://127.0.0.1:9/v1
    apiKey: none
    api: openai-completions
    auth: none
    models:
      - id: null-model
        name: Null Model
        api: openai-completions
        reasoning: false
        input: [text]
EOF

# herdr's own OMP integration, installed into the sandbox HOME only.
h integration-install integration install omp
((rc == 0)) || die "herdr integration install omp failed: $(<"$root/logs/integration-install.stderr")"
h integration-status integration status
grep -Eq '^omp: current \(v[0-9]+\) \(.*/\.omp/agent/extensions/herdr-omp-agent-state\.ts\)$' \
  "$root/logs/integration-status.stdout" || die "herdr integration status does not report omp: current (see $root/transcript.log)"
[[ -f "$omp_home/agent/extensions/herdr-omp-agent-state.ts" ]] || die 'herdr integration file missing from the sandbox HOME'
log "  $(grep '^omp:' "$root/logs/integration-status.stdout" | sed "s#$root#<SANDBOX>#g")"
h schema api schema --json
((rc == 0)) || die 'herdr api schema --json failed'
cp "$root/logs/schema.stdout" "$root/schema.json"

# --- Cases ---------------------------------------------------------------------------------
case_l3() {
  # The recorder sits at herdr's default socket ($XDG_CONFIG_HOME/herdr/herdr.sock) and
  # HERDR_SOCKET_PATH/HERDR_PANE_ID point at it: only the missing HERDR_ENV=1 keeps it silent.
  local sock=$case_home/config/herdr/herdr.sock status=0
  start_recorder l3 ok "$sock" || return 1
  herdr_env "$rec_sock" "$pane"
  session l3 --new --hold 1 -- "${henv[@]:1}" || status=1
  stop_recorder
  rm -f "$sock" # L8 starts a real herdr server on this path.
  ((status == 0)) || return 1
  py l3-proof assert-silent "$rec_log" "$root/logs/l3.session.json"
}
case_l4() {
  herdr_env "$root/s/missing.sock" "$pane"
  session l4 --new --hold 1 -- "${henv[@]}" || return 1
  py l4-proof assert-isolated "$root/logs/l4.session.json"
}
case_l5() {
  start_recorder l5 stall || return 1
  herdr_env "$rec_sock" "$pane"
  session l5 --new --hold 1 -- "${henv[@]}" || { stop_recorder; return 1; }
  stop_recorder
  py l5-proof assert-stall "$rec_log" "$root/logs/l5.session.json" 1
}
case_l6() {
  start_recorder l6 stall || return 1
  herdr_env "$rec_sock" "$pane"
  session l6 --hold 0 -- "${henv[@]}" || { stop_recorder; return 1; }
  stop_recorder
  py l6-proof assert-cancel "$rec_log" "$root/logs/l6.session.json"
}
case_l1() {
  start_recorder l1 ok || return 1
  herdr_env "$rec_sock" "$pane"
  # 1 s hold: the idle state report after new_session is debounced (250 ms) and retried.
  session l1 --new --hold 1 -- "${henv[@]}" || { stop_recorder; return 1; }
  stop_recorder
  l1_rec=$rec_log
  py l1-proof assert-trigger "$rec_log" "$root/logs/l1.session.json"
}
case_l2() {
  [[ -n "${l1_rec:-}" ]] || return 1
  py l2-proof assert-payload "$l1_rec" "$root/logs/l1.session.json" "$root/schema.json" "$pane"
}
case_l7() {
  local version
  host export "$python" "$repo/scripts/generate_omp_packages.py" --export "$root/export" || return 1
  cp -a "$root/export" "$root/source"
  host init git -C "$root/source" init -q -b fixture || return 1
  host stage git -C "$root/source" add -A || return 1
  host commit git -C "$root/source" -c user.name=omp-herdr -c user.email=omp-herdr@localhost \
    -c commit.gpgsign=false commit -qm 'generated OMP packages' || return 1
  host fork git clone -q --bare "$root/source" "$fork" || return 1
  version=$("$python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
    "$root/source/packages/omp/ycc/.omp-plugin/plugin.json")
  o mkt-add plugin marketplace add "$url"; ((rc == 0)) || return 1
  o install plugin install --scope user ycc@ycc ycc-mcp@ycc; ((rc == 0)) || return 1
  o list plugin list --json; ((rc == 0)) || return 1
  log "  installed ycc@ycc and ycc-mcp@ycc $version from the local marketplace fixture"
  py l7-extensions assert-no-extensions "$root/logs/list.stdout" || return 1
  start_recorder l7 ok || return 1
  herdr_env "$rec_sock" "$pane"
  session l7 --new --hold 1 -- "${henv[@]}" || { stop_recorder; return 1; }
  stop_recorder
  py l7-proof assert-single-source "$rec_log" "$root/logs/l7.session.json"
}
case_l8() {
  local sock=$case_home/config/herdr/herdr.sock hrc=0 pid
  # herdr derives its socket from XDG_CONFIG_HOME; it must stay inside the sandbox.
  herdr_env "$sock" "$pane"
  setsid "${clean_env[@]}" TERM=xterm-256color ${wrap[@]+"${wrap[@]}"} "$herdr" server \
    >"$root/logs/herdr-server.log" 2>&1 </dev/null &
  pid=$!
  herdr_pgid=$pid
  pids+=("$pid")
  for _ in {1..50}; do [[ -S "$sock" ]] && break; sleep 0.1; done
  [[ -S "$sock" ]] || { log '  herdr server socket did not appear'; return 1; }
  h l8-workspace workspace create --cwd "$root/work" --label ycc-smoke --no-focus; ((rc == 0)) || return 1
  grep -qF "\"pane_id\":\"$pane\"" "$root/logs/l8-workspace.stdout" || { log "  no pane $pane"; return 1; }
  # The pane shell inherits the server's clean env; herdr adds its own HERDR_* for the pane.
  h l8-run pane run "$pane" "exec $omp --no-title --model $model"; ((rc == 0)) || return 1
  py l8-proof herdr-pane "$sock" "$pane" "$root/logs/l8.pane.json" || hrc=1
  h l8-stop server stop
  return "$hrc"
}

cd "$root/work"
run_case L3 'fail-closed env: socket and pane set, no HERDR_ENV=1, zero connections' case_l3
run_case L4 'error: refused socket, no extension_error' case_l4
run_case L5 'timeout: stalled socket, bounded ready and exit' case_l5
run_case L6 'cancellation: stdin close with a stalled socket' case_l6
run_case L1 'trigger: startup and new session reports' case_l1
run_case L2 'payload: herdr:omp schema, seq, session path' case_l2
run_case L7 'duplicates: ycc packages add no reporter' case_l7
if ((herdr_pane)); then
  run_case L8 'real herdr: ycc:omp report is inert' case_l8
else
  results+=("SKIP L8 real herdr (pass --herdr-pane)")
fi

log ''
log "Summary ($omp_version, $herdr_version, sandbox=$sandbox):"
for line in "${results[@]}"; do log "  $line"; done
((failed == 0)) || die 'one or more cases failed'
log 'PASS all YAN-1174 OMP herdr session reporting checks'
