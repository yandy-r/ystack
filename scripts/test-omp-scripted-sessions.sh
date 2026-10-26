#!/usr/bin/env bash
# Opt-in live OMP session checks driven by a scripted model (YAN-1178, YAN-1540, YAN-1546).
# Not part of CI. No credentials, no network inside the sandbox, no real model.
# shellcheck disable=SC2154 # omp_in_dir comes from lib/omp-harness-common.sh
set -euo pipefail
umask 077
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/omp-harness-common.sh"

usage() {
  cat <<'EOF'
Usage: test-omp-scripted-sessions.sh [--keep] [--allow-env-i]

Runs the real ./install.sh --target omp (YCC_INSTALL_SKIP_BUILD=1: the checkout is never
written) and real omp >=18.12.2 sessions (OMP_BIN overrides PATH; default ~/.local/bin/omp)
in a mktemp sandbox under /tmp: env -i, HOME/XDG/TMPDIR inside the sandbox, and bwrap with a
private network namespace, the real home hidden behind a tmpfs and this checkout bind-mounted
read-only. Without bwrap the harness refuses to run unless --allow-env-i accepts the weaker
sandbox. Needs python3, git, timeout and realpath.

scripts/omp_scripted_smoke.py serves a loopback OpenAI-compatible provider (ycc-scripted:
main, slow, task) that answers each request from a fixed tool-call script, so sessions run
real tools, subagents and MCP calls with no inference. Stub stdio MCP servers stand in for
ycc-mcp:context7 and add ycc-mcp:smoke through a user mcp.json override.

S1 scope guard (YAN-1540): a git-cleanup subagent runs `git --version`; a chain with an
   out-of-scope `touch` is blocked with the `ycc scope guard` reason and leaves no file; a
   direct and an xd:// MCP call are blocked. library-docs-writer calls both declared context7
   tools (direct and xd://), is blocked on mcp__ycc_mcp_smoke_ping and has no bash tool. The main
   session runs bash and the smoke MCP tool unguarded.
S2 --plugin-dir packages/omp/ycc in a fresh home (no install) loads the agents but not the
   guard: the same out-of-scope chain runs and writes its file.
S3 TTSR (YAN-1546): writes to first.py, second.py and third.go persist exactly one
   ycc-python-trigger and one ycc-golang-trigger ttsr_injection entry, and the passive
   <system-reminder> follows only the first .py write and the .go write.
S4 agents: one task batch runs every ycc agent to completion; each request uses the model
   its frontmatter role selects (modelRoles slow/task, else default).
S5 skills: /ycc:clean expands to its skill, and every ycc skill reads through skill:// from
   the installed ycc@ycc cache.
S6 modes and permissions: --mode json ends in agent_end; with tools.approvalMode write, -p
   refuses bash without a UI and leaves no file; --mode rpc asks one `Allow tool: bash` select:
   Deny leaves no file, Approve writes it.
S7 offline: a refused provider fails -p with the retry-exhausted error (retry.maxRetries 1);
   retry.fallbackChains.default moves the same prompt to the scripted model.
--keep    Retain the sandbox and transcript (always retained when a check fails).
EOF
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
keep=0
allow_env_i=0
while (($#)); do
  case "$1" in
    --keep) keep=1; shift ;;
    --allow-env-i) allow_env_i=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
for tool in git python3 timeout mktemp realpath; do
  command -v "$tool" >/dev/null || die "missing prerequisite: $tool"
done
omp_h_require_gnu_tools

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
driver=$repo/scripts/omp_scripted_smoke.py
package=$repo/packages/omp/ycc
[[ -d "$package/agents" && -f "$package/extensions/scope-guard.ts" ]] ||
  die "$package is incomplete; run ./scripts/sync.sh first"
omp=${OMP_BIN:-$HOME/.local/bin/omp}
[[ -x "$omp" ]] || omp=$(command -v omp || true)
[[ -n "$omp" && -x "$omp" ]] || die 'set OMP_BIN or install omp at ~/.local/bin/omp or on PATH'
omp=$(realpath "$omp")
python=$(command -v python3)
real_home=$(realpath "${HOME:?HOME must be set}")
root=$(omp_h_mktemp_root omp-scripted-sessions)
[[ "$root" != "$real_home" && "$root" != "$real_home"/* ]] || die 'sandbox must not live under the real HOME'
cleanup() {
  local rc=$?
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
mkdir -p "$root"/{tmp,logs,bin,stub}
ln -s "$omp" "$root/bin/omp"
umask 022
safe_path=$(omp_h_safe_path "$allow_env_i" "$root/bin")
omp_h_check_path_tools "$safe_path" bash git python3 timeout realpath

sandbox=env-i
wrap=()
bwrap_bin=$(command -v bwrap || true)
[[ -z "$bwrap_bin" ]] || bwrap_bin=$(realpath "$bwrap_bin")
if [[ -n "$bwrap_bin" ]] &&
  "$bwrap_bin" --dev-bind / / --tmpfs "$real_home" --unshare-net /bin/true >/dev/null 2>&1; then
  sandbox=bwrap-netns
  wrap=("$bwrap_bin" --dev-bind / / --tmpfs "$real_home" --ro-bind "$omp" "$omp"
    --ro-bind "$repo" "$repo" --unshare-net --)
elif ((!allow_env_i)); then
  die 'bubblewrap with --unshare-net is unavailable; refusing to run without network/home isolation (pass --allow-env-i to override)'
fi

# The current case: its HOME/XDG tree.
case_home=$root/a
home() { realpath -m "$case_home/home"; }
agent_dir() { printf '%s/.omp/agent' "$(home)"; }
clean() {
  local h
  h=$(home)
  [[ "$h" == "$root"/* && "$h" != "$real_home" && "$h" != "$real_home"/* ]] ||
    die "refusing to run with HOME=$h outside $root"
  mkdir -p "$case_home"/{home,config,data,state,cache,runtime}
  chmod 0700 "$case_home/runtime"
  env -i PATH="$safe_path" LANG=C.UTF-8 TERM=dumb NO_COLOR=1 \
    HOME="$h" XDG_CONFIG_HOME="$case_home/config" XDG_DATA_HOME="$case_home/data" \
    XDG_STATE_HOME="$case_home/state" XDG_CACHE_HOME="$case_home/cache" \
    XDG_RUNTIME_DIR="$case_home/runtime" TMPDIR="$root/tmp" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false GIT_ALLOW_PROTOCOL=file \
    PYTHONDONTWRITEBYTECODE=1 YCC_INSTALL_SKIP_BUILD=1 "$@"
}
# Run the HOME guard once with stderr visible: the preflight below discards it.
clean true
clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 30 omp --version >/dev/null 2>&1 ||
  die "OMP_BIN ($omp) does not run inside the $sandbox sandbox: it must be a self-contained binary"
log() { printf '%s\n' "$*" | tee -a "$root/transcript.log"; }
rc=0
record() {
  local label=$1; shift
  {
    printf '\n[%s] argv:' "$label"; printf ' %q' "${@/#"$root"/<SANDBOX>}"
    printf '\nexit=%s\nstdout:\n' "$rc"; head -c 6000 "$root/logs/$label.stdout" | sed "s#$root#<SANDBOX>#g"
    printf '\nstderr:\n'; head -c 3000 "$root/logs/$label.stderr" | sed "s#$root#<SANDBOX>#g"; printf '\n'
  } >>"$root/transcript.log"
}
# run LABEL DIR ARGS: under the sandbox from DIR, recorded. Callers assert the exit status.
run() {
  local label=$1 dir=$2; shift 2
  [[ ! -e "$root/logs/$label.stdout" ]] || die "duplicate label: $label"
  rc=0
  clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 300 "${omp_in_dir[@]}" "$dir" "$@" </dev/null \
    >"$root/logs/$label.stdout" 2>"$root/logs/$label.stderr" || rc=$?
  record "$label" "$@"
}
ok() { ((rc == 0)) || die "$1 exited $rc (see $root/transcript.log)"; }
# session LABEL DIR [DRIVER-OPTS] -- OMP-ARGS: one scripted omp session from DIR; the provider
# runs inside the sandbox's network namespace, so omp reaches it on loopback.
session() {
  local label=$1 dir=$2; shift 2
  local opts=()
  while (($#)) && [[ "$1" != -- ]]; do opts+=("$1"); shift; done
  shift
  run "$label" "$dir" "$python" "$driver" session ${opts[@]+"${opts[@]}"} \
    "$root/logs/$label.json" "$(agent_dir)" "$package" -- omp --no-title "$@"
  ok "$label session"
  log "  $label: $(<"$root/logs/$label.stdout")"
}
# check LABEL SUBCOMMAND ARGS: a driver assertion; its one-line result is logged.
check() {
  local label=$1; shift
  run "$label" "$root" "$python" "$driver" "$@"
  ((rc == 0)) || { cat "$root/logs/$label.stderr" >&2; die "$label failed; see $root/transcript.log"; }
  log "  $(<"$root/logs/$label.stdout")"
}
config() { mkdir -p "$(agent_dir)"; printf '%s' "$1" >"$(agent_dir)/config.yml"; }
base_config=$'async:\n  enabled: false\nmodelRoles:\n  default: ycc-scripted/main\n  slow: ycc-scripted/slow\n  task: ycc-scripted/task\n'
# A stdio MCP stub: argv[1] is its name, the rest are its tool names; calls answer STUB-OK.
cat >"$root/stub/mcp_stub.py" <<'PY'
import json, sys
name, tools = sys.argv[1], sys.argv[2:]
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("id") is None:
        continue
    method = m.get("method")
    if method == "initialize":
        r = {"protocolVersion": m["params"].get("protocolVersion", "2024-11-05"),
             "capabilities": {"tools": {}}, "serverInfo": {"name": name, "version": "0"}}
    elif method == "tools/list":
        r = {"tools": [{"name": t, "description": "stub " + t,
                        "inputSchema": {"type": "object", "properties": {}}} for t in tools]}
    elif method == "tools/call":
        r = {"content": [{"type": "text", "text": "STUB-OK " + name + "/" + m["params"]["name"]}]}
    else:
        r = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}) + "\n")
    sys.stdout.flush()
PY

version=$(clean timeout -k 5 30 "$omp" --version 2>/dev/null)
"$python" - "$version" <<'PY' || die "omp >=18.12.2 required, got: $version"
import re, sys
match = re.search(r"(\d+)\.(\d+)\.(\d+)", sys.argv[1])
sys.exit(0 if match and tuple(map(int, match.groups())) >= (18, 12, 2) else 1)
PY
log "YAN-1178 scripted sessions | $version | sandbox=$sandbox"

# --- Install ycc into the case home ---------------------------------------------------------
run install "$(home)" "$repo/install.sh" install --target omp
ok 'install.sh install --target omp'
work=$root/work
mkdir -p "$work"
run git-init "$work" git init -q
ok 'git init'
config "$base_config"
"$python" - "$(agent_dir)/mcp.json" "$root/stub/mcp_stub.py" <<'PY'
import json, sys
stub = sys.argv[2]
servers = {
    "ycc-mcp:context7": {"command": "python3", "args": [stub, "context7", "resolve-library-id", "query-docs"]},
    "ycc-mcp:smoke": {"command": "python3", "args": [stub, "smoke", "ping"]},
}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps({"mcpServers": servers}, indent=2))
PY

# --- S1. Scope guard (YAN-1540) -------------------------------------------------------------
session s1-guard "$work" -- -p --no-session SCRIPT-main-guard
check s1-proof check-script "$root/logs/s1-guard.json" "$package" \
  SCRIPT-main-guard SCRIPT-guard-git-cleanup SCRIPT-guard-docs-writer
[[ ! -e "$work/guard-side-effect" ]] || die 'S1: the blocked chain segment left guard-side-effect behind'
session s1-main "$work" -- -p --no-session SCRIPT-guard-main
check s1-main-proof check-script "$root/logs/s1-main.json" "$package" SCRIPT-guard-main
[[ -e "$work/main-unguarded" ]] || die 'S1: the unguarded main-session bash call wrote nothing'
log 'PASS S1 scope guard: git-cleanup bash prefixes and MCP denial, library-docs-writer context7 only, main session unguarded'

# --- S2. --plugin-dir alone loads no guard --------------------------------------------------
case_home=$root/b
config "$base_config"
pd_work=$root/pd-work
mkdir -p "$pd_work"
session s2-plugin-dir "$pd_work" -- -p --no-session --plugin-dir "$package" SCRIPT-main-plugin-dir
check s2-proof check-script "$root/logs/s2-plugin-dir.json" "$package" SCRIPT-main-plugin-dir SCRIPT-plugin-dir-git-cleanup
[[ -e "$pd_work/plugin-dir-side-effect" ]] || die 'S2: expected the unguarded --plugin-dir chain to write its file'
log 'PASS S2 --plugin-dir: agents load, the scope guard does not (install ycc@ycc to get it)'
case_home=$root/a

# --- S3. TTSR trigger reminders (YAN-1546) --------------------------------------------------
session s3-ttsr "$work" -- -p --session-dir "$root/sessions" SCRIPT-ttsr
check s3-proof check-script "$root/logs/s3-ttsr.json" "$package" SCRIPT-ttsr
check s3-entries check-ttsr "$root/sessions"
log 'PASS S3 ttsr: ycc-<family>-trigger reminders attach once per session after an edit'

# --- S4. Every agent, on its role model -----------------------------------------------------
session s4-agents "$work" -- -p --no-session SCRIPT-main-agents
check s4-proof check-agents "$root/logs/s4-agents.json" "$package"
log 'PASS S4 agents: every ycc agent runs as a subagent on its role model'

# --- S5. Skills and commands ----------------------------------------------------------------
session s5-skills "$work" -- -p --no-session '/ycc:clean SCRIPT-skills'
check s5-proof check-skills "$root/logs/s5-skills.json" "$package"
log 'PASS S5 skills: /ycc:clean expands; every ycc skill reads from the installed cache'

# --- S6. Modes and permission prompts -------------------------------------------------------
session s6-json "$work" -- --mode json --no-session hello
check s6-json-proof check-json "$root/logs/s6-json.json"
config "$base_config"$'tools:\n  approvalMode: write\n'
session s6-print "$work" -- -p --no-session SCRIPT-permission
has_refusal=$("$python" -c 'import json,sys; r=json.load(open(sys.argv[1]))["requests"]; print(any("requires approval but no interactive UI" in x for q in r for x in q["results"]))' "$root/logs/s6-print.json")
[[ "$has_refusal" == True && ! -e "$work/permission-probe" ]] || die 'S6: -p ran bash under approvalMode write'
session s6-deny "$work" --rpc SCRIPT-permission --approve no -- --mode rpc --no-session
check s6-deny-proof check-rpc "$root/logs/s6-deny.json" --approve no
[[ ! -e "$work/permission-probe" ]] || die 'S6: a denied bash call wrote permission-probe'
session s6-approve "$work" --rpc SCRIPT-permission --approve yes -- --mode rpc --no-session
check s6-approve-proof check-rpc "$root/logs/s6-approve.json" --approve yes
[[ -e "$work/permission-probe" ]] || die 'S6: an approved bash call wrote nothing'
log 'PASS S6 modes: json events; approvalMode write refuses headless bash, rpc Deny blocks and Approve runs'

# --- S7. Offline provider and fallback chain ------------------------------------------------
config $'async:\n  enabled: false\nretry:\n  maxRetries: 1\n  baseDelayMs: 100\n'
run s7-offline "$work" "$python" "$driver" session "$root/logs/s7-offline.json" "$(agent_dir)" "$package" -- \
  omp --no-title -p --no-session --model ycc-down/down hello
ok 's7-offline driver'
"$python" - "$root/logs/s7-offline.json" <<'PY' || die 'S7: an unreachable provider did not fail with the retry error'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d["rc"] != 0 and "Retry budget exhausted" in d["stderr"] and "connection refused" in d["stderr"] else 1)
PY
config $'async:\n  enabled: false\nretry:\n  maxRetries: 1\n  baseDelayMs: 100\n  fallbackChains:\n    default: [ycc-scripted/main]\nmodelRoles:\n  default: ycc-down/down\n'
session s7-fallback "$work" -- -p --no-session hello
"$python" - "$root/logs/s7-fallback.json" <<'PY' || die 'S7: the fallback chain did not reach the scripted model'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d["rc"] == 0 and "DONE" in d["stdout"] and [r["model"] for r in d["requests"]] == ["main"] else 1)
PY
log 'PASS S7 offline: refused provider fails after the retry budget; retry.fallbackChains recovers'
log "PASS all YAN-1178 scripted OMP session checks ($version, sandbox=$sandbox)"
