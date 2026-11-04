#!/usr/bin/env bash
# Opt-in live install checks for the generated OMP native packages (YAN-1171) and the
# ycc-mcp package's MCP servers (YAN-1173: list, start, disable/override, removal).
# Not part of CI. No credentials, no network inside the sandbox, no model inference.
# shellcheck disable=SC2154 # sandbox and wrap come from lib/omp-harness-common.sh
set -euo pipefail
umask 077
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/omp-harness-common.sh"

usage() {
  cat <<'EOF'
Usage: test-omp-native-packages.sh [--keep] [--allow-env-i]
       test-omp-native-packages.sh --public URL --ref SHA [--keep] [--allow-env-i]

Requires omp >=18.12.2 (OMP_BIN overrides PATH), git, python3 with the repository's
generator dependencies, timeout, and bubblewrap with working --unshare-net/--unshare-pid.
OMP_BIN must be a self-contained binary that runs without anything under $HOME, /run or /tmp
or on a PATH beyond /usr/local/bin:/usr/bin:/bin: the sandbox hides those behind tmpfs, so a
Bun-installed `omp` (a script under ~/.bun run by `bun`) fails the preflight.

Default: export the packages with `generate_omp_packages.py --export` (the catalog then
also lists unlisted included packages), commit them to a fixture repo, and serve the
pinned commit from a bare "fork" whose only branch is that commit.
--public URL --ref SHA: fetch exactly the full 40-hex commit SHA from an
https://github.com/OWNER/REPO.git fork (the only networked step; it runs outside the
sandbox), check the fetched packages match a fresh export, and serve that commit the
same way. The fork must contain .omp-plugin/marketplace.json at SHA (a listed release).

omp only ever sees https://omp-native.invalid/fork.git, rewritten by git insteadOf to the
local bare repo with GIT_ALLOW_PROTOCOL=file. Every omp call runs under env -i with
HOME/XDG/TMPDIR inside a mktemp sandbox, and under bwrap with private network and PID
namespaces, a read-only host tree, and the real home, /run and /tmp hidden behind tmpfs.
Without bwrap the harness refuses to run unless
--allow-env-i accepts the weaker env -i sandbox. The only model is a null provider on
127.0.0.1:9 and no prompt is sent.

Checks: marketplace add, discover, install --dry-run (writes nothing), user install,
plugin list --json (lockstep version, installPath, cache bytes and modes), doctor, RPC
get_available_commands (every ycc:<skill> command and skill:<name>), agent models kept
(probe extension calling omp's agent discovery), upgrade detection (.omp-plugin-only bump
is ignored; .claude-plugin + catalog + package.json bump upgrades), uninstall cleanup.

ycc-mcp (YAN-1173; skipped, and logged, when the catalog does not list it): --dry-run then
install with a byte-identical cache; list (a probe extension calls omp's loadAllMCPConfigs:
every server in the shipped .mcp.json is ycc-mcp:<server> with none shadowed by an equivalent
connection and a distinct OAuth credential id per distinct http/sse url (YAN-1291), the browser
filter drops exactly playwright, unset ${VAR} env stays literal);
start (a stdio stub's tool reaches RPC get_state); user mcp.json disabledServers hides a
server and enabledServers revives one shipped with enabled: false; plugin disable/enable;
a native user mcp.json entry with the same ycc-mcp:<server> name overrides the package;
uninstall leaves no install, cache, link or server. Local mode appends fixture-only
python3 stub servers (smoke; smokeoff with enabled: false; both run
${OMP_PLUGIN_ROOT}/mcp_stub.py) to the fixture copy's ycc-mcp/.mcp.json before the commit
and leaves the shipped servers unchanged. --public has no stub: the start and
enabledServers checks are skipped (logged), and disabledServers and the override target
ycc-mcp:context7 instead.
--keep    Retain the sandbox and transcript (always retained when a check fails).
EOF
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
keep=0
allow_env_i=0
public=0
public_url=
public_ref=
while (($#)); do
  case "$1" in
    --keep) keep=1; shift ;;
    --allow-env-i) allow_env_i=1; shift ;;
    --public)
      [[ $# -ge 2 && -n "$2" && "$public" == 0 ]] || die '--public requires one URL'
      public=1; public_url=$2; shift 2 ;;
    --ref)
      [[ $# -ge 2 && -n "$2" && -z "$public_ref" ]] || die '--ref requires one full commit SHA'
      public_ref=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
if ((public)); then
  [[ "$public_url" =~ ^https://github\.com/[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9_][A-Za-z0-9_.-]*\.git$ ]] ||
    die '--public requires https://github.com/OWNER/REPO.git (no credentials, query, or fragment)'
  [[ "$public_ref" =~ ^[[:xdigit:]]{40}$ ]] || die '--ref requires a full 40-hex commit SHA'
  public_ref=${public_ref,,}
else
  [[ -z "$public_ref" ]] || die '--ref requires --public URL'
fi
for tool in git python3 timeout mktemp realpath; do
  command -v "$tool" >/dev/null || die "missing prerequisite: $tool"
done
omp_h_require_gnu_tools

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
checks=$repo/scripts/omp_native_smoke.py
omp=${OMP_BIN:-$(command -v omp || true)}
[[ -n "$omp" && -x "$omp" ]] || die 'set OMP_BIN or install omp on PATH'
omp=$(realpath "$omp")
python=$(command -v python3)
real_home=$(realpath "${HOME:?HOME must be set}")
root=$(omp_h_mktemp_root omp-native-packages)
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
mkdir -p "$root"/{work,tmp,logs,case}
# Git keeps only the regular-file type and executable bit; a normal umask keeps payload modes.
umask 022
cd "$root/work"
safe_path=$(omp_h_safe_path "$allow_env_i")
omp_h_check_path_tools "$safe_path" bash git python3 timeout realpath
url=https://omp-native.invalid/fork.git
fork=$root/fork.git
case_home=$root/case
omp_home=$case_home/home/.omp

omp_h_sandbox "$allow_env_i" "$root" "$real_home" "$omp"

# Run a command with no inherited environment, an isolated HOME/XDG tree, and file-only git.
clean() {
  local h
  h=$(realpath -m "$case_home/home")
  [[ "$h" == "$root"/* && "$h" != "$real_home" && "$h" != "$real_home"/* ]] ||
    die "refusing to run with HOME=$h outside $root"
  mkdir -p "$case_home"/{home,config,data,state,cache,runtime}
  env -i PATH="$safe_path" LANG=C.UTF-8 TERM=dumb NO_COLOR=1 \
    HOME="$h" XDG_CONFIG_HOME="$case_home/config" XDG_DATA_HOME="$case_home/data" \
    XDG_STATE_HOME="$case_home/state" XDG_CACHE_HOME="$case_home/cache" \
    XDG_RUNTIME_DIR="$case_home/runtime" TMPDIR="$root/tmp" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false GIT_ALLOW_PROTOCOL=file GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
    GIT_CONFIG_KEY_1="url.file://$fork.insteadOf" GIT_CONFIG_VALUE_1="$url" \
    "$@"
}
# bwrap works on its own; a failure here is omp needing files the sandbox hides.
# Run the HOME guard once with stderr visible: the preflight below discards it.
clean true
clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 30 "$omp" --version >/dev/null 2>&1 ||
  die "OMP_BIN ($omp) does not run inside the $sandbox sandbox: it must be a self-contained binary outside \$HOME's dependencies (env -i PATH=$safe_path, real home hidden)"
log() { printf '%s\n' "$*" | tee -a "$root/transcript.log"; }
rc=0
stdin_file=/dev/null
# Record argv, exit status and (sandbox-relative) output of one command in the transcript.
record() {
  local label=$1; shift
  {
    printf '\n[%s] argv:' "$label"; printf ' %q' "${@/#"$root"/<SANDBOX>}"
    printf '\nexit=%s\nstdout:\n' "$rc"; head -c 4000 "$root/logs/$label.stdout" | sed "s#$root#<SANDBOX>#g"
    printf '\nstderr:\n'; head -c 2000 "$root/logs/$label.stderr" | sed "s#$root#<SANDBOX>#g"; printf '\n'
  } >>"$root/transcript.log"
}
# Run under the sandbox and record; `o` runs omp. Callers assert the exit status.
run() {
  local label=$1; shift
  rc=0
  clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 90 "$@" <"$stdin_file" >"$root/logs/$label.stdout" 2>"$root/logs/$label.stderr" || rc=$?
  record "$label" "$@"
}
o() { local label=$1; shift; run "$label" "$omp" "$@"; }
# Host-side helper (git fixture, Python assertions): env -i, no sandbox wrapper.
host() {
  local label=$1; shift
  rc=0
  clean timeout -k 5 300 "$@" >"$root/logs/$label.stdout" 2>"$root/logs/$label.stderr" || rc=$?
  record "$label" "$@"
  ((rc == 0)) || { cat "$root/logs/$label.stderr" >&2; die "$label exited $rc; see $root/transcript.log"; }
}
assert_rc() { [[ "$rc" == "$1" ]] || die "$2: expected rc=$1, got $rc (see $root/transcript.log)"; }
has() {
  local label=$1; shift
  for tok in "$@"; do
    grep -qF -- "$tok" "$root/logs/$label.stdout" "$root/logs/$label.stderr" ||
      die "$label: expected output to contain '$tok' (see $root/transcript.log)"
  done
}
check() { local label=$1; shift; host "$label" "$python" "$checks" "$@"; log "  $(<"$root/logs/$label.stdout")"; }
commit() { host "commit-$2" git -C "$source_root" -c user.name=omp-native -c user.email=omp-native@localhost \
  -c commit.gpgsign=false commit -qam "$1"; }
# Serve exactly one commit: the fork's only branch (its HEAD) points at it.
pin() {
  host "pin-$2" git -C "$fork" update-ref refs/heads/fixture "$1"
  host "pin-head-$2" git -C "$fork" symbolic-ref HEAD refs/heads/fixture
}

o version --version
assert_rc 0 version
version_text=$(<"$root/logs/version.stdout")
"$python" - "$version_text" <<'PY' || die "omp >=18.12.2 required, got: $version_text"
import re, sys
match = re.search(r"(\d+)\.(\d+)\.(\d+)", sys.argv[1])
sys.exit(0 if match and tuple(map(int, match.groups())) >= (18, 12, 2) else 1)
PY

# --- Fixture: the generated export at a pinned commit -------------------------------------
host export "$python" "$repo/scripts/generate_omp_packages.py" --export "$root/export"
source_root=$root/source
if ((public)); then
  log "public | $version_text | sandbox=$sandbox | fork $public_url @ $public_ref"
  # The only networked step, outside the sandbox; omp itself never leaves the netns.
  host fetch-init git init -q --bare "$fork"
  rc=0
  env -i PATH="$safe_path" HOME="$root/tmp" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false GIT_ALLOW_PROTOCOL=https \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
    timeout -k 5 300 git -C "$fork" fetch -q --no-tags --depth=1 "$public_url" "$public_ref" \
    >"$root/logs/fetch.stdout" 2>"$root/logs/fetch.stderr" || rc=$?
  record fetch git fetch "$public_url" "$public_ref"
  assert_rc 0 'fetch pinned public commit'
  host fetch-verify git -C "$fork" cat-file -e "$public_ref^{commit}"
  commit_sha=$public_ref
  pin "$commit_sha" v1
  host checkout git clone -q "$fork" "$source_root"
  [[ "$(git -C "$source_root" rev-parse HEAD)" == "$commit_sha" ]] || die 'fetched fixture SHA mismatch'
  [[ -f "$source_root/.omp-plugin/marketplace.json" ]] ||
    die 'the pinned fork commit has no .omp-plugin/marketplace.json (no OMP package is listed at that ref)'
  # The fork's packages must be exactly what this checkout generates (catalog may list a subset).
  host fixture-proof diff -r "$root/export/packages/omp" "$source_root/packages/omp"
else
  log "YAN-1171/YAN-1173 | $version_text | sandbox=$sandbox | local pinned fixture (generated export)"
  cp -a "$root/export" "$source_root"
  # Fixture-only stdio stubs in the ycc-mcp copy (never in the export): the shipped servers
  # cannot connect offline, so these prove a server from the installed package starts.
  check mcp-fixture mcp-fixture "$source_root"
  host init git -C "$source_root" init -q -b fixture
  host stage git -C "$source_root" add -A
  host commit-v1 git -C "$source_root" -c user.name=omp-native -c user.email=omp-native@localhost \
    -c commit.gpgsign=false commit -qm 'generated OMP packages'
  host fork git clone -q --bare "$source_root" "$fork"
  commit_sha=$(git -C "$source_root" rev-parse HEAD)
  pin "$commit_sha" v1
fi
version=$("$python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
  "$source_root/packages/omp/ycc/.omp-plugin/plugin.json")
log "Pinned commit: $commit_sha (lockstep version $version)"
if "$python" -c 'import json,sys; sys.exit("ycc-mcp" not in {p["name"] for p in json.load(open(sys.argv[1]))["plugins"]})' \
  "$source_root/.omp-plugin/marketplace.json"; then
  mcp_listed=1
else
  mcp_listed=0
fi

# Null model provider: lets RPC sessions start; no prompt is ever sent.
mkdir -p "$omp_home/agent"
cat >"$omp_home/agent/models.yml" <<'EOF'
providers:
  omp-native-null:
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
# The probe imports omp's own agent discovery and reports each non-bundled agent's resolved
# model as a command description. An upstream module move fails loudly (PROBEERR).
cat >"$root/probe.ts" <<'EOF'
export default async function (pi) {
  let d;
  try {
    const m = await import("@oh-my-pi/pi-coding-agent/task/discovery");
    const agents = (await m.discoverAgents(process.cwd())).agents.filter(a => a.source !== "bundled");
    d = "PROBE " + JSON.stringify(agents.map(a => [a.name, a.model ? [].concat(a.model).join(",") : null, a.filePath ?? null]));
  } catch (e) { d = "PROBEERR " + String(e).replace(/"/g, "'"); }
  pi.registerCommand("probe", { description: d, handler: async () => {} });
}
EOF
rpc() {
  local label=$1; shift
  printf '%s\n' '{"id":"cmds","type":"get_available_commands"}' >"$root/tmp/$label.rpc.in"
  stdin_file="$root/tmp/$label.rpc.in"
  o "$label" --mode rpc --no-session --no-title --model omp-native-null/null-model "$@"
  stdin_file=/dev/null
  assert_rc 0 "$label rpc"
  has "$label" '"command":"get_available_commands","success":true'
}
# The MCP probe imports omp's own MCP config loader (mcp/config.ts loadAllMCPConfigs, the
# function a session's MCP manager discovers with) and capability dedupe. It reports every
# discovered server with its source and OAuth credential id (mcp/oauth-flow.ts
# mcpOAuthCredentialId, the auth-storage row an http/sse login lands in), the servers left
# after the browser filter a session applies (shouldFilterBrowserMCPForPrelude with the live
# browser.enabled setting; eval is a default tool) and the servers an equivalent connection shadows.
cat >"$root/mcp-probe.ts" <<'EOF'
export default async function (pi) {
  let d;
  try {
    const cfg = await import("@oh-my-pi/pi-coding-agent/mcp/config");
    const disc = await import("@oh-my-pi/pi-coding-agent/discovery");
    const { mcpOAuthCredentialId } = await import("@oh-my-pi/pi-coding-agent/mcp/oauth-flow");
    const { Settings } = await import("@oh-my-pi/pi-coding-agent/config/settings");
    const { cfgBrowserEnabled } = await import("@oh-my-pi/pi-coding-agent/tools/browser/settings");
    const browserEnabled = cfgBrowserEnabled.get(Settings.instance);
    const filter = cfg.shouldFilterBrowserMCPForPrelude({
      restrictToolNames: false, browserEnabled, evalRegistered: true, evalActive: true });
    const r = await cfg.loadAllMCPConfigs(process.cwd(), { filterBrowser: false });
    const kept = await cfg.loadAllMCPConfigs(process.cwd(), { filterBrowser: filter });
    const all = await disc.loadCapability("mcps", { cwd: process.cwd() });
    d = "PROBE " + JSON.stringify({
      browserEnabled,
      servers: Object.fromEntries(Object.entries(r.configs).map(([k, v]) => [k, {
        type: v.type, args: v.args, url: v.url, env: v.env, enabled: v.enabled,
        provider: r.sources[k]?.provider ?? null, path: r.sources[k]?.path ?? null }])),
      credentialIds: Object.fromEntries(Object.entries(r.configs)
        .filter(([, v]) => typeof v.url === "string").map(([k, v]) => [k, mcpOAuthCredentialId(v.url)])),
      browserKept: Object.keys(kept.configs),
      shadowed: all.all.filter(s => s._shadowed).map(s => s.name),
    });
  } catch (e) { d = "PROBEERR " + String(e).replace(/"/g, "'"); }
  pi.registerCommand("mcp-probe", { description: d, handler: async () => {} });
}
EOF
# One RPC session with the MCP probe: get_available_commands (probe) then get_state (prompt).
mcp_rpc() {
  local label=$1; shift
  printf '%s\n' '{"id":"cmds","type":"get_available_commands"}' '{"id":"state","type":"get_state"}' \
    >"$root/tmp/$label.rpc.in"
  stdin_file="$root/tmp/$label.rpc.in"
  o "$label" --mode rpc --no-session --no-title --model omp-native-null/null-model -e "$root/mcp-probe.ts" "$@"
  stdin_file=/dev/null
  assert_rc 0 "$label rpc"
  has "$label" '"command":"get_available_commands","success":true' '"command":"get_state","success":true'
}
# mcp_state LABEL SERVER STATE TOOLS: a fresh MCP RPC session, then the omp_native_smoke assertion.
mcp_state() { mcp_rpc "$1"; check "$1-proof" mcp-state "$root/logs/$1.stdout" "$2" "$3" "$4"; }
user_mcp=$omp_home/agent/mcp.json

# --- 1. Catalog, dry run, install ----------------------------------------------------------
o mkt-add plugin marketplace add "$url"
assert_rc 0 'marketplace add'
has mkt-add 'Added marketplace'
o discover plugin discover ycc
assert_rc 0 discover
has discover "ycc@$version"
o install-dry plugin install --dry-run ycc@ycc
assert_rc 0 'install --dry-run'
has install-dry '[dry-run] Would install ycc@ycc'
[[ ! -e "$omp_home/plugins/installed_plugins.json" && ! -e "$omp_home/plugins/node_modules/ycc" ]] ||
  die 'install --dry-run wrote plugin state'
log "PASS catalog: .omp-plugin/marketplace.json from the pinned fork registers ycc@$version; --dry-run writes nothing"
o install plugin install ycc@ycc
assert_rc 0 install
has install "Installed ycc from ycc ($version)"
o list plugin list --json
assert_rc 0 'plugin list --json'
check list-proof installed "$root/logs/list.stdout" "$source_root" "$version"
o doctor plugin doctor
assert_rc 0 doctor
has doctor plugins_directory node_modules
[[ -L "$omp_home/plugins/node_modules/ycc" ]] || die 'runtime link node_modules/ycc missing (package.json#name)'
log 'PASS install: user scope, lockstep version, cache matches the package root, doctor clean, runtime link ycc'

# --- 2. Runtime discovery without inference ---------------------------------------------------
rpc rpc-commands
check commands-proof commands "$root/logs/rpc-commands.stdout" "$source_root"
rpc rpc-agents -e "$root/probe.ts"
check agents-proof agents "$root/logs/rpc-agents.stdout" "$source_root"
log 'PASS discovery: every ycc:<skill> command, skill:<name> skill and agent loads from the install; agent models kept'

# --- 3. ycc-mcp: install, list, start, disable/override, removal (YAN-1173) -----------------
# Runs before the upgrade checks, which then see only ycc installed again.
if ((mcp_listed)); then
  # 0 waits for the initial connection attempts, so the first get_state carries MCP tools.
  printf 'mcp:\n  startupTimeoutMs: 0\n' >"$omp_home/agent/config.yml"
  if ((public)); then
    target=ycc-mcp:context7
    target_tool=
    log 'SKIP --public: no fixture stub, so the start and enabledServers checks are skipped; disabledServers and the override use ycc-mcp:context7'
  else
    target=ycc-mcp:smoke
    target_tool=mcp__ycc_mcp_smoke_smoke_ping
  fi
  # The generated ycc-mcp package is the committed one; the fixture only appends stub servers.
  host mcp-export-proof diff -r "$root/export/packages/omp/ycc-mcp" "$repo/packages/omp/ycc-mcp"
  o mcp-install-dry plugin install --dry-run ycc-mcp@ycc
  assert_rc 0 'ycc-mcp install --dry-run'
  has mcp-install-dry '[dry-run] Would install ycc-mcp@ycc'
  if [[ -e "$omp_home/plugins/node_modules/ycc-mcp" ]] ||
    grep -qF 'ycc-mcp@ycc' "$omp_home/plugins/installed_plugins.json"; then
    die 'ycc-mcp install --dry-run wrote plugin state'
  fi
  o mcp-install plugin install ycc-mcp@ycc
  assert_rc 0 'ycc-mcp install'
  has mcp-install "Installed ycc-mcp from ycc ($version)"
  o mcp-list plugin list --json
  assert_rc 0 'plugin list --json (ycc-mcp)'
  check mcp-list-proof mcp-installed "$root/logs/mcp-list.stdout" "$source_root" "$version"
  [[ -L "$omp_home/plugins/node_modules/ycc-mcp" ]] || die 'runtime link node_modules/ycc-mcp missing (package.json#name)'
  log "PASS ycc-mcp install: export matches the committed packages/omp/ycc-mcp; --dry-run writes nothing; user scope at $version, cache byte-identical to the pinned packages/omp/ycc-mcp$( ((public)) || printf ' (plus fixture stubs)'), runtime link ycc-mcp"

  shipped_mcp=$root/export/packages/omp/ycc-mcp/.mcp.json
  mcp_rpc mcp-servers
  check mcp-servers-proof mcp-listed "$root/logs/mcp-servers.stdout" "$shipped_mcp" "$root/logs/mcp-list.stdout"
  printf 'mcp:\n  startupTimeoutMs: 0\nbrowser:\n  enabled: false\n' >"$omp_home/agent/config.yml"
  mcp_rpc mcp-servers-nobrowser
  check mcp-servers-nobrowser-proof mcp-listed "$root/logs/mcp-servers-nobrowser.stdout" "$shipped_mcp" "$root/logs/mcp-list.stdout"
  printf 'mcp:\n  startupTimeoutMs: 0\n' >"$omp_home/agent/config.yml"
  # shellcheck disable=SC2016 # literal ${VAR} placeholder in a log line
  log 'PASS ycc-mcp list: omp discovers every shipped server as ycc-mcp:<server> from the install, none shadowed, each http server with its own OAuth credential id; browser.enabled drops exactly playwright and browser.enabled: false keeps it; unset ${XERO_*} env stays literal'

  if ((public)); then
    log 'SKIP ycc-mcp start (--public): no fixture stub server; the shipped servers cannot connect offline'
  else
    check mcp-start-proof mcp-state "$root/logs/mcp-servers.stdout" ycc-mcp:smoke plugin \
      'mcp__ycc_mcp_smoke_smoke_ping,!mcp__ycc_mcp_smokeoff_'
    # shellcheck disable=SC2016 # literal ${OMP_PLUGIN_ROOT} placeholder in a log line
    log 'PASS ycc-mcp start: the packaged stdio server ycc-mcp:smoke (${OMP_PLUGIN_ROOT}/mcp_stub.py) spawned; mcp__ycc_mcp_smoke_smoke_ping in RPC get_state; the enabled: false stub did not start'
  fi

  printf '{"disabledServers": ["%s"]}\n' "$target" >"$user_mcp"
  mcp_state mcp-user-disabled "$target" absent "${target_tool:--}"
  rm -f -- "$user_mcp"
  mcp_state mcp-user-restored "$target" plugin "${target_tool:--}"
  if ((!public)); then
    printf '{"enabledServers": ["ycc-mcp:smokeoff"]}\n' >"$user_mcp"
    mcp_state mcp-user-enabled ycc-mcp:smokeoff plugin mcp__ycc_mcp_smokeoff_smokeoff_ping
    printf '{"disabledServers": ["ycc-mcp:smokeoff"], "enabledServers": ["ycc-mcp:smokeoff"]}\n' >"$user_mcp"
    mcp_state mcp-user-both ycc-mcp:smokeoff absent mcp__ycc_mcp_smokeoff_smokeoff_ping
    rm -f -- "$user_mcp"
  fi
  log "PASS ycc-mcp disabledServers: user mcp.json [\"$target\"] hides it; removing the list restores it$( ((public)) || printf '; enabledServers revives ycc-mcp:smokeoff (enabled: false) and disabledServers beats it')"

  o mcp-disable plugin disable ycc-mcp@ycc
  assert_rc 0 'plugin disable ycc-mcp@ycc'
  has mcp-disable 'Disabled ycc-mcp@ycc'
  mcp_state mcp-plugin-disabled 'ycc-mcp:*' absent '!mcp__ycc_mcp_'
  o mcp-enable plugin enable ycc-mcp@ycc
  assert_rc 0 'plugin enable ycc-mcp@ycc'
  mcp_state mcp-plugin-enabled "$target" plugin "${target_tool:--}"
  log 'PASS ycc-mcp plugin disable/enable: disable removes every ycc-mcp:<server> (no mcp__ycc_mcp_ tool); enable restores them'

  override_tool=mcp__ycc_mcp_${target#ycc-mcp:}_override_ping
  check mcp-override-stub mcp-stub "$root/override_stub.py"
  printf '{"mcpServers": {"%s": {"command": "python3", "args": ["%s", "override"]}}}\n' \
    "$target" "$root/override_stub.py" >"$user_mcp"
  mcp_state mcp-override "$target" native "$override_tool${target_tool:+,!$target_tool}"
  rm -f -- "$user_mcp"
  mcp_state mcp-override-removed "$target" plugin "${target_tool:-!$override_tool}"
  log "PASS ycc-mcp override: a native user mcp.json entry named $target wins over the package (started $override_tool); removing it restores the package server"

  o mcp-uninstall plugin uninstall --scope user ycc-mcp@ycc
  assert_rc 0 'uninstall ycc-mcp@ycc'
  o mcp-list-after plugin list --json
  assert_rc 0 'plugin list --json (after ycc-mcp uninstall)'
  check mcp-absent-proof mcp-absent "$root/logs/mcp-list-after.stdout" "$omp_home"
  mcp_state mcp-after 'ycc-mcp:*' absent '!mcp__ycc_mcp_'
  check mcp-ycc-kept installed "$root/logs/mcp-list-after.stdout" "$source_root" "$version"
  rm -f -- "$omp_home/agent/config.yml"
  log 'PASS ycc-mcp removal: uninstall leaves no ycc-mcp install, registry or lock entry, runtime link, cache or ycc-mcp:<server>; ycc stays installed'
else
  log 'SKIP ycc-mcp (YAN-1173): the pinned catalog does not list ycc-mcp; no MCP checks ran'
fi

# --- 4. Upgrade detection ----------------------------------------------------------------------
# A version only in .omp-plugin/plugin.json is invisible: OMP reads .claude-plugin/plugin.json,
# then root plugin.json, then the catalog entry, then package.json (manager.ts #resolveCatalogVersion).
IFS=. read -r v_major v_minor v_patch <<<"${version%%[-+]*}"
bump_one=$v_major.$v_minor.$((v_patch + 1))
host bump-omp-only "$python" "$checks" bump "$source_root" "$bump_one" packages/omp/ycc/.omp-plugin/plugin.json
commit "omp-plugin only $bump_one" omp-only
host push-omp-only git -C "$source_root" push -q "$fork" HEAD:refs/heads/fixture
o mkt-update-1 plugin marketplace update ycc
assert_rc 0 'marketplace update (omp-only bump)'
o upgrade-1 plugin upgrade
assert_rc 0 'upgrade (omp-only bump)'
has upgrade-1 'All marketplace plugins are up to date.'
bump_two=$v_major.$v_minor.$((v_patch + 2))
host bump-lockstep "$python" "$checks" bump "$source_root" "$bump_two" packages/omp/ycc/.omp-plugin/plugin.json \
  packages/omp/ycc/.claude-plugin/plugin.json packages/omp/ycc/package.json .omp-plugin/marketplace.json
commit "lockstep $bump_two" lockstep
host push-lockstep git -C "$source_root" push -q "$fork" HEAD:refs/heads/fixture
o mkt-update-2 plugin marketplace update ycc
assert_rc 0 'marketplace update (lockstep bump)'
o upgrade-2 plugin upgrade
assert_rc 0 'upgrade (lockstep bump)'
has upgrade-2 "$version -> $bump_two"
o list-upgraded plugin list --json
assert_rc 0 'plugin list --json (upgraded)'
check upgraded-proof installed "$root/logs/list-upgraded.stdout" "$source_root" "$bump_two"
log "PASS upgrade: .omp-plugin-only bump ignored ('All marketplace plugins are up to date.'); lockstep bump upgrades $version -> $bump_two"

# --- 5. Uninstall ----------------------------------------------------------------------------
o uninstall plugin uninstall --scope user ycc@ycc
assert_rc 0 uninstall
o list-after plugin list --json
assert_rc 0 'plugin list --json (after uninstall)'
check absent-proof absent "$root/logs/list-after.stdout" "$omp_home"
rpc rpc-after
"$python" - "$root/logs/rpc-after.stdout" <<'PY' || die 'ycc commands still registered after uninstall'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    frame = json.loads(line) if line.strip() else {}
    if frame.get("command") == "get_available_commands":
        names = [c["name"] for c in frame["data"]["commands"]]
        sys.exit(1 if any(n.startswith("ycc:") for n in names) else 0)
sys.exit(1)
PY
log 'PASS uninstall: no ycc plugin, registry, lock entry, runtime link, cache or ycc: command remains'
log "PASS all YAN-1171/YAN-1173 OMP native package checks ($version_text, sandbox=$sandbox)"
