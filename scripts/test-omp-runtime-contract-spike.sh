#!/usr/bin/env bash
# Opt-in, offline YAN-1165 (GitHub #365) live checks of the oh-my-pi (omp) plugin
# runtime contract. No real auth, no credentials, no model inference.
# Evidence dossier: docs/internal/spikes/omp-runtime-contract.md
# Decision record: docs/internal/adr/0002-omp-runtime-contract.md
# shellcheck disable=SC2154 # sandbox and wrap come from lib/omp-harness-common.sh
set -euo pipefail
umask 077
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/omp-harness-common.sh"

# Print CLI usage and exit.
usage() {
  cat <<'EOF'
Usage: test-omp-runtime-contract-spike.sh [--keep] [--output-dir DIR] [--allow-env-i]

Requires OMP_BIN (absolute executable path) or omp on PATH, version >=18.12.2,
plus git, python3, timeout, and standard Linux utilities. No inference.
--keep            Retain the sandbox (otherwise removed by EXIT trap).
--output-dir DIR  Existing parent directory under /tmp; implies --keep.
--allow-env-i     Run without bubblewrap isolation (env -i only; no network
                  namespace, real home not hidden). Without this flag the
                  harness fails closed when bwrap cannot create the sandbox.
-h, --help        Show help. Default sandbox: mktemp -d under /tmp.

Every omp call runs under `env -i` with HOME, XDG_*, TMPDIR, and git config
isolated under the sandbox. By default each call also runs under bubblewrap with
private network and PID namespaces, a read-only host tree, and the invoking
user's real home, /run and /tmp hidden behind tmpfs (only the omp binary and
the sandbox are bound back), so the real ~/.omp
is unreachable. HTTPS-shaped .invalid URLs are rewritten to local bare repos by
git `insteadOf`, and GIT_ALLOW_PROTOCOL=file limits git to file://. The only
"model" is a null openai-completions provider on 127.0.0.1:9; no prompt is ever
sent, so no request is made.
EOF
}
# Emit a fatal error message to stderr and exit 1.
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
keep=0
allow_env_i=0
parent=/tmp
while (($#)); do
  case "$1" in
    --keep) keep=1; shift ;;
    --allow-env-i) allow_env_i=1; shift ;;
    --output-dir)
      (($# >= 2)) || die '--output-dir needs an existing directory'
      parent=$2; keep=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
for tool in git python3 timeout mktemp realpath; do
  command -v "$tool" >/dev/null || die "missing prerequisite: $tool"
done
omp_h_require_gnu_tools
omp=${OMP_BIN:-$(command -v omp || true)}
[[ -n "$omp" && -x "$omp" ]] || die 'set OMP_BIN or install omp on PATH'
omp=$(realpath "$omp")
real_home=$(realpath "${HOME:?HOME must be set}")
[[ -d "$parent" ]] || die '--output-dir must exist'
parent=$(realpath "$parent")
omp_h_under_tmp "$parent" || die 'output must be under /tmp'
root=$(omp_h_mktemp_root omp-runtime-contract-spike "$parent")
[[ "$root" != "$real_home" && "$root" != "$real_home"/* ]] || die 'sandbox must not live under the real HOME'
# EXIT trap: report the transcript path and remove the sandbox unless --keep.
cleanup() {
  local rc=$?
  if ((keep)); then
    printf 'Retained transcript: %s/transcript.log (exit=%s)\n' "$root" "$rc"
  else
    printf 'Transcript: %s/transcript.log (removed; use --keep to retain; exit=%s)\n' "$root" "$rc"
    rm -rf -- "$root"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$root"/{work,tmp,logs,cases}
cd "$root/work"
safe_path=$(omp_h_safe_path "$allow_env_i")
# clean() runs every command under env -i with safe_path; fail early if a prerequisite lives elsewhere.
for tool in git python3 timeout; do
  PATH=$safe_path command -v "$tool" >/dev/null || die "missing prerequisite on $safe_path: $tool"
done
url_omp=https://omp-spike.invalid/omp.git
url_cl=https://omp-spike.invalid/claude.git
bare_omp=$root/omp.git
bare_cl=$root/claude.git

# Network/home isolation: bwrap (see omp_h_sandbox) is required unless --allow-env-i
# explicitly accepts the weaker env -i-only sandbox. Only the omp binary is bound back.
omp_h_sandbox "$allow_env_i" "$root" "$real_home" "$omp"

case_home=
# Select (and create) the isolated HOME/XDG tree for subsequent omp calls.
use_case() {
  case_home=$root/cases/$1
  mkdir -p "$case_home"/{home,config,data,state,cache,runtime}
}
use_case bootstrap
# Run a command under env -i with isolated HOME/XDG, file-only Git rewrites, and the sandbox wrapper.
clean() {
  local h
  h=$(realpath -m "$case_home/home")
  # Hard guard: never let omp see a HOME outside this run's temp dir.
  [[ "$h" == "$root"/* && "$h" != "$real_home" && "$h" != "$real_home"/* ]] ||
    die "refusing to run with HOME=$h outside $root"
  env -i PATH="$safe_path" LANG=C.UTF-8 TERM=dumb NO_COLOR=1 \
    HOME="$h" XDG_CONFIG_HOME="$case_home/config" XDG_DATA_HOME="$case_home/data" \
    XDG_STATE_HOME="$case_home/state" XDG_CACHE_HOME="$case_home/cache" \
    XDG_RUNTIME_DIR="$case_home/runtime" TMPDIR="$root/tmp" \
    ${extra_env[@]+"${extra_env[@]}"} \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    GIT_ALLOW_PROTOCOL=file GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
    GIT_CONFIG_KEY_1="url.file://$bare_omp.insteadOf" GIT_CONFIG_VALUE_1="$url_omp" \
    GIT_CONFIG_KEY_2="url.file://$bare_cl.insteadOf" GIT_CONFIG_VALUE_2="$url_cl" \
    "$@"
}
extra_env=()
# Fail early, with a reason, when omp needs anything the sandbox hides (e.g. a Bun script).
clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 30 "$omp" --version >/dev/null 2>&1 ||
  die "OMP_BIN ($omp) does not run inside the $sandbox sandbox: it must be a self-contained binary"
# Write a status line to stdout and append it to the transcript.
log() { printf '%s\n' "$*" | tee -a "$root/transcript.log"; }
rc=0
stdin_file=/dev/null
# Execute omp (or any command) under timeout; sanitize sandbox paths/ANSI in logs; record argv/exit.
run() {
  local label=$1; shift
  local out="$root/logs/$label.stdout" err="$root/logs/$label.stderr"
  rc=0
  clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 60 "$@" <"$stdin_file" >"$out" 2>"$err" || rc=$?
  python3 - "$root" "$out" "$err" <<'PY'
import re
import sys
from pathlib import Path
root, *paths = sys.argv[1:]
for name in paths:
    path = Path(name)
    text = path.read_text(errors="replace").replace(root, "<SANDBOX>")
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    path.write_text(text)
PY
  { printf '\n[%s] case=%s cwd=%s argv:' "$label" "${case_home#"$root"/}" "${PWD/#"$root"/<SANDBOX>}"
    printf ' %q' "${@/#"$root"/<SANDBOX>}"; printf '\nexit=%s\nstdout:\n' "$rc"
    # Capture files only; RPC frames are large, keep the head.
    head -c 4000 "$out"; printf '\nstderr:\n'; head -c 2000 "$err"; printf '\n'
  } >>"$root/transcript.log"
}
# Run omp with the given label.
o() { local label=$1; shift; run "$label" "$omp" "$@"; }
# Assert that the most recent run() returned the expected exit status.
assert_rc() { [[ "$rc" == "$1" ]] || die "$2: expected rc=$1, got $rc (see $root/transcript.log)"; }
# Assert a literal string is (has) or is not (lacks) in a run's stdout+stderr.
has() {
  local label=$1; shift
  for tok in "$@"; do
    grep -qF -- "$tok" "$root/logs/$label.stdout" "$root/logs/$label.stderr" ||
      die "$label: expected output to contain '$tok' (see $root/transcript.log)"
  done
}
lacks() {
  local label=$1; shift
  for tok in "$@"; do
    ! grep -qF -- "$tok" "$root/logs/$label.stdout" "$root/logs/$label.stderr" ||
      die "$label: expected output NOT to contain '$tok' (see $root/transcript.log)"
  done
}
# Append a sandbox-relative file listing (no .git, natives, logs, cache payloads) to the transcript.
layout() {
  local label=$1 dir=$2
  { printf '\n[layout %s] %s\n' "$label" "${dir/#"$root"/<SANDBOX>}"
    (cd "$dir" && find . -mindepth 1 \( -name .git -o -name natives -o -name logs \
      -o -path '*/cache/marketplaces/*' -o -path '*/cache/plugins/*/*' \) -prune -o -print | LC_ALL=C sort)
  } >>"$root/transcript.log"
}
# Fail unless every given path exists.
exists() { for p in "$@"; do [[ -e "$p" || -L "$p" ]] || die "expected path to exist: ${p/#"$root"/<SANDBOX>}"; done; }
absent() { for p in "$@"; do [[ ! -e "$p" && ! -L "$p" ]] || die "expected path to be absent: ${p/#"$root"/<SANDBOX>}"; done; }
# Seed the null provider (no inference) and a 0ms-free MCP startup wait into the case agent dir.
seed_agent() {
  local agent=$case_home/home/.omp/agent
  mkdir -p "$agent"
  cat >"$agent/models.yml" <<'EOF'
providers:
  spike-null:
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
  printf 'mcp:\n  startupTimeoutMs: 0\n' >"$agent/config.yml"
}
# Feed get_available_commands + get_state (and optional extra frames) to `omp --mode rpc`.
rpc() {
  local label=$1; shift
  printf '%s\n' "${rpc_pre[@]}" '{"id":"cmds","type":"get_available_commands"}' '{"id":"state","type":"get_state"}' >"$root/tmp/$label.rpc.in"
  stdin_file="$root/tmp/$label.rpc.in"
  o "$label" --mode rpc --no-session --no-title --model spike-null/null-model "$@"
  stdin_file=/dev/null
  assert_rc 0 "$label rpc"
  has "$label" '"command":"get_available_commands","success":true' '"command":"get_state","success":true'
}
rpc_pre=()

# ---------------------------------------------------------------------------
o version --version
assert_rc 0 version
version=$(<"$root/logs/version.stdout")
python3 - "$version" <<'PY'
import re
import sys
match = re.fullmatch(r"omp/(\d+)\.(\d+)\.(\d+)\s*", sys.argv[1])
if not match or tuple(map(int, match.groups())) < (18, 12, 2):
    raise SystemExit("omp >=18.12.2 (stable version string) required")
PY
log "YAN-1165 | $version | sandbox=$sandbox | offline git fixture | $(date -u +%F)"
for help in '' plugin install agents config ttsr; do
  read -r -a args <<<"$help"
  o "help-${args[0]:-root}" ${args[@]+"${args[@]}"} --help
  assert_rc 0 "omp $help --help"
done
has help-root '--profile' '--plugin-dir' 'PI_CODING_AGENT_DIR' 'OMP_PROFILE' '--no-extensions'
has help-plugin 'install|uninstall|list|link|doctor|features|config|enable|disable|marketplace|discover|upgrade' '--dry-run' '--scope'

# ---------------------------------------------------------------------------
# Fixtures: one plugin tree with every ycc-relevant surface, a dual-catalog
# repo (.omp-plugin + .claude-plugin with different names), and a Claude-only
# repo with relative, git-subdir, and npm entries.
python3 - "$root" <<'PY'
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
mcp = '''import json, sys
name = sys.argv[1]
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("id") is None:
        continue
    if m.get("method") == "initialize":
        r = {"protocolVersion": m["params"].get("protocolVersion", "2024-11-05"),
             "capabilities": {"tools": {}}, "serverInfo": {"name": name, "version": "0"}}
    elif m.get("method") == "tools/list":
        r = {"tools": [{"name": name + "_ping", "description": "marker " + name,
                        "inputSchema": {"type": "object", "properties": {}}}]}
    else:
        r = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}) + "\\n")
    sys.stdout.flush()
'''
(root / "mcp_stub.py").write_text(mcp)
p = root / "plugin-src"
files = {
    "skills/spike-skill/SKILL.md": "---\nname: spike-skill\ndescription: Spike skill SKILLMARK\n---\nbody\n",
    "commands/spike-cmd.md": "---\ndescription: Spike command CMDMARK\n---\nDo it\n",
    "agents/spike-agent.md": "---\nname: spike-agent\ndescription: Spike agent AGENTMARK\ntools: read, grep\nmodel: smol\n---\nYou are spike.\n",
    "rules/spike-rule.md": "---\ndescription: Spike rule\nalwaysApply: true\n---\nALWAYSRULEMARK always spike.\n",
    "rules/spike-ttsr.md": "---\ndescription: TTSR rule\ncondition: \"SPIKEFORBIDDEN\"\n---\nDo not write SPIKEFORBIDDEN.\n",
    "hooks/pre/bash.sh": f"#!/bin/sh\ntouch '{root}/hook-ran'\nexit 0\n",
    "hooks/pre/spike-hook.ts": "export default function (pi) { pi.registerCommand(\"spike-hook-cmd\", { description: \"HOOKMARK\", handler: async () => {} }); }\n",
    "tools/spike_tool.ts": "export default (pi) => ({ name: \"spike_tool\", label: \"Spike\", description: \"TOOLMARK\", parameters: pi.zod.object({}), async execute() { return { content: [{ type: \"text\", text: \"ok\" }] }; } });\n",
    "ext/index.ts": "export default function (pi) { pi.registerCommand(\"spike-ext\", { description: \"EXTMARK\", handler: async () => {} }); }\n",
    "mcp_stub.py": mcp,
    ".mcp.json": json.dumps({"mcpServers": {
        "spikemcp": {"command": "python3", "args": ["${OMP_PLUGIN_ROOT}/mcp_stub.py", "spikemcp"]},
        "spikeclaude": {"command": "python3", "args": ["${CLAUDE_PLUGIN_ROOT}/mcp_stub.py", "spikeclaude"]}}}),
    ".claude-plugin/plugin.json": json.dumps({"name": "ycc-spike", "version": "0.0.1", "description": "spike"}),
    "package.json": json.dumps({"name": "ycc-spike", "version": "0.0.1", "omp": {"extensions": ["./ext/index.ts"]}}),
}
for rel, text in files.items():
    f = p / rel
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(text)
(p / "hooks/pre/bash.sh").chmod(0o755)

def tree(dst):
    import shutil
    shutil.copytree(p, dst)

dual = root / "src-omp"
tree(dual / "plugins/ycc-spike")
(dual / ".omp-plugin").mkdir(parents=True)
(dual / ".claude-plugin").mkdir(parents=True)
(dual / ".omp-plugin/marketplace.json").write_text(json.dumps({
    "name": "spike-omp", "owner": {"name": "spike"}, "metadata": {"pluginRoot": "plugins"},
    "plugins": [{"name": "ycc-spike", "source": "./ycc-spike", "version": "0.0.1",
                 "lspServers": {"spike-lsp": {"command": "true", "fileTypes": [".spk"]}}}]}))
(dual / ".claude-plugin/marketplace.json").write_text(json.dumps({
    "name": "spike-claude-shadow", "owner": {"name": "spike"},
    "plugins": [{"name": "shadow-plugin", "source": "./plugins/ycc-spike"}]}))
cl = root / "src-claude"
tree(cl / "ycc-spike")
(cl / ".claude-plugin").mkdir(parents=True)
(cl / ".claude-plugin/marketplace.json").write_text(json.dumps({
    "name": "spike-claude", "owner": {"name": "spike"},
    "plugins": [
        {"name": "rel-spike", "source": "./ycc-spike"},
        {"name": "sub-spike", "source": {"source": "git-subdir", "url": "https://omp-spike.invalid/omp.git",
                                          "path": "plugins/ycc-spike", "ref": "fixture"}},
        {"name": "npm-spike", "source": {"source": "npm", "package": "ycc-spike", "version": "0.0.1"}}]}))
PY
# Commit a fixture tree (unsigned) and clone it into a bare repo.
fixture_commit() {
  clean git -C "$1" init -q -b fixture
  clean git -C "$1" add -A
  clean git -C "$1" -c user.name=spike -c user.email=spike@localhost -c commit.gpgsign=false commit -qm "$3"
  [[ -d "$2" ]] || clean git clone -q --bare "$1" "$2"
}
fixture_commit "$root/src-omp" "$bare_omp" 'v0.0.1'
fixture_commit "$root/src-claude" "$bare_cl" 'claude-only'
log "Fixtures: dual=$(clean git -C "$root/src-omp" rev-parse HEAD) claude-only=$(clean git -C "$root/src-claude" rev-parse HEAD)"

# ---------------------------------------------------------------------------
# 1. Marketplace catalog selection and source types.
use_case user
seed_agent
omp_home=$case_home/home/.omp
o mkt-add-dual plugin marketplace add "$url_omp"
assert_rc 0 'marketplace add dual'
o mkt-list plugin marketplace list
assert_rc 0 'marketplace list'
has mkt-list spike-omp
lacks mkt-list spike-claude-shadow
o mkt-add-claude plugin marketplace add "$url_cl"
assert_rc 0 'marketplace add claude-only'
o mkt-add-nocatalog plugin marketplace add "$root/plugin-src"
assert_rc 1 'marketplace add dir without catalog'
has mkt-add-nocatalog '.omp-plugin/marketplace.json' '.claude-plugin/marketplace.json'
o discover plugin discover
assert_rc 0 discover
has discover 'ycc-spike@0.0.1'
o discover-claude plugin discover spike-claude
assert_rc 0 'discover spike-claude'
has discover-claude rel-spike sub-spike npm-spike
exists "$omp_home/marketplaces.json" "$omp_home/plugins/cache/marketplaces/spike-omp/.omp-plugin/marketplace.json"
log 'PASS catalog: .omp-plugin/marketplace.json preferred over .claude-plugin (dual repo -> spike-omp); .claude-plugin-only repo accepted; dir without catalog rc=1'

# 2. Dry-run, real user-scope install, list/doctor, on-disk layout.
o install-dry plugin install --dry-run ycc-spike@spike-omp
assert_rc 0 'install --dry-run'
has install-dry '[dry-run] Would install ycc-spike@spike-omp'
absent "$omp_home/plugins/installed_plugins.json" "$omp_home/plugins/node_modules/ycc-spike"
o install-user plugin install ycc-spike@spike-omp
assert_rc 0 'install user'
has install-user 'Installed ycc-spike from spike-omp (0.0.1)'
cache=$omp_home/plugins/cache/plugins/spike-omp___ycc-spike___0.0.1
exists "$omp_home/plugins/installed_plugins.json" "$omp_home/plugins/omp-plugins.lock.json" \
  "$omp_home/plugins/node_modules/ycc-spike" "$cache/.lsp.json" "$cache/skills/spike-skill/SKILL.md"
[[ "$(readlink "$omp_home/plugins/node_modules/ycc-spike")" == "$cache" ]] || die 'node_modules link must point at cache dir'
layout install-user "$case_home"
o list-json plugin list --json
assert_rc 0 'list --json'
has list-json '"id": "ycc-spike@spike-omp"' '"scope": "user"' '"version": "0.0.1"'
o doctor plugin doctor
assert_rc 0 doctor
has doctor 'plugins_directory' 'node_modules'
o npm-src plugin install npm-spike@spike-claude
assert_rc 1 'npm marketplace source'
has npm-src 'npm plugin sources are not yet supported'
o rel-conflict plugin install rel-spike@spike-claude
assert_rc 1 'second install with same package.json name'
has rel-conflict 'conflicts with installed plugin'
log 'PASS install: dry-run writes nothing; user install -> cache/plugins/<mkt>___<name>___<ver> + node_modules symlink + lock; npm source rc=1; package-name collision rc=1'

# 3. Runtime discovery without inference (RPC introspection, TTSR).
rpc rpc-user
has rpc-user '"name":"skill:spike-skill"' '"name":"ycc-spike:spike-cmd"' '"name":"spike-ext"' \
  '"name":"spike-hook-cmd"' 'AGENTMARK' 'ALWAYSRULEMARK' 'TOOLMARK' 'spike-agent` (READ-ONLY' \
  'mcp__ycc_spike_spikemcp_spikemcp_ping' 'mcp__ycc_spike_spikeclaude_spikeclaude_ping'
# Load-time guard only: no tool call runs in this RPC session, so a pre-hook could not
# fire here even if shell hooks were supported. The unsupported verdict is doc-sourced.
absent "$root/hook-ran"
o ttsr-plugin-dir ttsr list --plugin-dir "$root/plugin-src"
assert_rc 1 'ttsr list --plugin-dir (root-only flag)'
has ttsr-plugin-dir 'Unknown option'
o ttsr-list ttsr list --json
assert_rc 0 'ttsr list'
has ttsr-list '"name":"spike-ttsr"' '"provider":"claude-plugins"'
o ttsr-hit ttsr test 'x SPIKEFORBIDDEN y'
assert_rc 0 'ttsr test hit'
has ttsr-hit 'Triggered (1)' spike-ttsr
o agents-unpack agents unpack --dir "$root/unpacked" --json
assert_rc 0 'agents unpack'
has agents-unpack task.md scout.md
# shellcheck disable=SC2016 # literal placeholder names, not expansions
log 'PASS discovery: skill, namespaced command, ext command (omp.extensions), TS pre-hook, agent, alwaysApply rule, TTSR rule, custom tool, MCP (${OMP_PLUGIN_ROOT} and ${CLAUDE_PLUGIN_ROOT}) all surfaced'

# 4. disable/enable and /reload-plugins.
o disable plugin disable ycc-spike@spike-omp
assert_rc 0 disable
has "disable" 'Disabled ycc-spike@spike-omp'
o ttsr-disabled ttsr list --json
assert_rc 0 'ttsr list (disabled)'
lacks ttsr-disabled '"name":"spike-ttsr"'
rpc rpc-disabled
lacks rpc-disabled '"name":"skill:spike-skill"' 'AGENTMARK' 'spikemcp_ping'
o enable plugin enable ycc-spike@spike-omp
assert_rc 0 enable
rpc_pre=('{"id":"reload","type":"prompt","message":"/reload-plugins"}')
rpc rpc-reload
rpc_pre=()
has rpc-reload 'Plugins reloaded.' '"agentInvoked":false' '"name":"skill:spike-skill"'
log 'PASS toggle: disable hides skill/agent/MCP/TTSR; enable restores; /reload-plugins over RPC is a builtin command (agentInvoked=false)'

# 5. Upgrade: catalog-only bump is ignored when plugin.json carries a version.
python3 - "$root/src-omp/.omp-plugin/marketplace.json" 0.0.2 <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["plugins"][0]["version"] = sys.argv[2]
json.dump(d, open(sys.argv[1], "w"))
PY
clean git -C "$root/src-omp" -c user.name=spike -c user.email=spike@localhost -c commit.gpgsign=false commit -qam 'catalog 0.0.2'
clean git -C "$root/src-omp" push -q "$bare_omp" fixture
o mkt-update plugin marketplace update
assert_rc 0 'marketplace update'
o upgrade-catalog-only plugin upgrade
assert_rc 0 'upgrade (catalog-only bump)'
has upgrade-catalog-only 'All marketplace plugins are up to date.'
python3 - "$root/src-omp/plugins/ycc-spike" 0.0.2 <<'PY'
import json, sys
from pathlib import Path
for rel in (".claude-plugin/plugin.json", "package.json"):
    f = Path(sys.argv[1]) / rel; d = json.loads(f.read_text()); d["version"] = sys.argv[2]; f.write_text(json.dumps(d))
PY
clean git -C "$root/src-omp" -c user.name=spike -c user.email=spike@localhost -c commit.gpgsign=false commit -qam 'plugin 0.0.2'
clean git -C "$root/src-omp" push -q "$bare_omp" fixture
o mkt-update2 plugin marketplace update spike-omp
assert_rc 0 'marketplace update spike-omp'
o upgrade plugin upgrade
assert_rc 0 upgrade
o list-upgraded plugin list --json
has list-upgraded '"version": "0.0.2"' 'spike-omp___ycc-spike___0.0.2'
log 'PASS upgrade: catalog version is ignored for relative sources when .claude-plugin/plugin.json has a version; plugin.json bump + marketplace update + upgrade -> 0.0.2'

# 6. Project scope, shadowing, scope ambiguity, plugin-overrides.json.
proj=$case_home/proj
mkdir -p "$proj"
clean git -C "$proj" init -q
cd "$proj"
o install-project plugin install --scope project ycc-spike@spike-omp
assert_rc 0 'install --scope project'
exists "$proj/.omp/plugins/installed_plugins.json" "$proj/.omp/plugins/omp-plugins.lock.json" "$proj/.omp/plugins/node_modules/ycc-spike"
layout install-project "$proj"
o list-project plugin list --json
has list-project '"scope": "project"' '"shadowedBy": "project"'
o uninstall-ambiguous plugin uninstall ycc-spike@spike-omp
assert_rc 1 'uninstall without --scope when in both scopes'
has uninstall-ambiguous 'installed in both user and project scope'
o uninstall-dry plugin uninstall --dry-run --scope project ycc-spike@spike-omp
assert_rc 0 'uninstall --dry-run'
exists "$proj/.omp/plugins/node_modules/ycc-spike"
o disable-project plugin disable --scope project ycc-spike@spike-omp
assert_rc 0 'disable --scope project'
o list-project-disabled plugin list --json
assert_rc 0 'list --json (project disabled)'
lacks list-project-disabled '"shadowedBy": "project"'
o ttsr-project-disabled ttsr list --json
has ttsr-project-disabled '"name":"spike-ttsr"'
o enable-project plugin enable --scope project ycc-spike@spike-omp
assert_rc 0 'enable --scope project'
printf '{"disabled":["ycc-spike"]}\n' >"$proj/.omp/plugin-overrides.json"
o ttsr-overrides-mkt ttsr list --json
assert_rc 0 'ttsr list (overrides, marketplace)'
has ttsr-overrides-mkt '"name":"spike-ttsr"'
# Same overrides file: claude-plugins provider surfaces stay, omp.extensions are filtered.
rpc rpc-overrides-mkt
has rpc-overrides-mkt '"name":"skill:spike-skill"' '"name":"ycc-spike:spike-cmd"' 'AGENTMARK' 'spikemcp_ping'
lacks rpc-overrides-mkt '"name":"spike-ext"'
rm "$proj/.omp/plugin-overrides.json"
o uninstall-project plugin uninstall --scope project ycc-spike@spike-omp
assert_rc 0 'uninstall --scope project'
absent "$proj/.omp/plugins/node_modules/ycc-spike"
cd "$root/work"
log 'PASS scopes: project install under <git-root>/.omp/plugins shadows user; disabled project does not shadow; uninstall needs --scope when ambiguous; plugin-overrides.json leaves marketplace skills/commands/agents/rules/MCP loaded but filters its omp.extensions'

# 7. Marketplace remove leaves installs; user uninstall cleans runtime links.
o mkt-remove plugin marketplace remove spike-claude
assert_rc 0 'marketplace remove'
o mkt-list-after plugin marketplace list
assert_rc 0 'marketplace list after remove'
lacks mkt-list-after spike-claude
o uninstall-user plugin uninstall --scope user ycc-spike@spike-omp
assert_rc 0 'uninstall user'
absent "$omp_home/plugins/node_modules/ycc-spike"
[[ ! -e "$omp_home/plugins/installed_plugins.json" ]] ||
  ! grep -qF '"ycc-spike@spike-omp"' "$omp_home/plugins/installed_plugins.json" ||
  die 'installed_plugins.json still lists ycc-spike@spike-omp after uninstall'
layout uninstall-user "$case_home"
log 'PASS remove/uninstall: marketplace remove drops catalog only; uninstall removes node_modules link and registry entry'

# 8. git-subdir marketplace source.
use_case subdir
o sub-add plugin marketplace add "$url_cl"
assert_rc 0 'subdir marketplace add'
o sub-dry plugin install --dry-run sub-spike@spike-claude
assert_rc 0 'git-subdir dry-run'
o sub-install plugin install sub-spike@spike-claude
assert_rc 0 'git-subdir install'
# ref=fixture now points at the 0.0.2 commit pushed in section 5.
exists "$case_home/home/.omp/plugins/cache/plugins/spike-claude___sub-spike___0.0.2/skills/spike-skill/SKILL.md"
sub_home=$case_home/home/.omp
o sub-mkt-remove plugin marketplace remove spike-claude
assert_rc 0 'remove marketplace with an installed plugin'
o sub-list-after-remove plugin list --json
assert_rc 0 'list --json after marketplace remove'
has sub-list-after-remove '"id": "sub-spike@spike-claude"'
exists "$sub_home/plugins/node_modules/ycc-spike" "$sub_home/plugins/cache/plugins/spike-claude___sub-spike___0.0.2"
grep -qF '"sub-spike@spike-claude"' "$sub_home/plugins/installed_plugins.json" ||
  die 'marketplace remove must leave installed_plugins.json entries'
log 'PASS git-subdir: {source:git-subdir,url,path,ref} installs offline via insteadOf; version from the ref tip plugin.json (0.0.2); marketplace remove keeps the install, registry entry, and node_modules link'

# 9. link (npm-style runtime package) and plugin-overrides.json.
use_case link
seed_agent
o link-dry plugin link --dry-run "$root/plugin-src"
assert_rc 0 'link --dry-run'
absent "$case_home/home/.omp/plugins/node_modules/ycc-spike"
o link plugin link "$root/plugin-src"
assert_rc 0 link
[[ "$(readlink "$case_home/home/.omp/plugins/node_modules/ycc-spike")" == "$root/plugin-src" ]] || die 'link must symlink the source dir'
o link-list plugin list --json
has link-list '"npm": [' '"extensions": [' './ext/index.ts'
rpc rpc-link
has rpc-link '"name":"skill:spike-skill"' '"name":"spike-ext"' '"name":"spike-cmd"' 'AGENTMARK' 'spikemcp_ping'
lproj=$case_home/proj
mkdir -p "$lproj/.omp"
clean git -C "$lproj" init -q
printf '{"disabled":["ycc-spike"]}\n' >"$lproj/.omp/plugin-overrides.json"
cd "$lproj"
rpc rpc-link-overrides
lacks rpc-link-overrides '"name":"skill:spike-skill"' '"name":"spike-ext"'
cd "$root/work"
o link-disable plugin disable ycc-spike
assert_rc 0 'disable linked'
o link-uninstall plugin uninstall ycc-spike
assert_rc 0 'uninstall linked'
absent "$case_home/home/.omp/plugins/node_modules/ycc-spike"
layout link "$case_home"
rpc rpc-plugin-dir --plugin-dir "$root/plugin-src"
has rpc-plugin-dir '"name":"skill:spike-skill"' '"name":"ycc-spike:spike-cmd"'
log 'PASS link: symlink into ~/.omp/plugins/node_modules, omp.extensions loaded; project plugin-overrides.json disables linked plugins; --plugin-dir loads a tree with no install'

# 10. Named profiles, XDG data root, PI_CODING_AGENT_DIR.
use_case profile
o prof-add --profile work plugin marketplace add "$url_omp"
assert_rc 0 'profile marketplace add'
o prof-install --profile work plugin install ycc-spike@spike-omp
assert_rc 0 'profile install'
exists "$case_home/home/.omp/profiles/work/plugins/node_modules/ycc-spike" "$case_home/home/.omp/profiles/work/marketplaces.json"
o prof-default-list plugin list
has prof-default-list 'No plugins installed'
extra_env=(OMP_PROFILE=work)
o prof-env-list plugin list
extra_env=()
has prof-env-list 'ycc-spike@spike-omp'
o xdg-init config init-xdg
assert_rc 0 'config init-xdg'
o xdg-add plugin marketplace add "$url_omp"
assert_rc 0 'xdg marketplace add'
o xdg-install plugin install ycc-spike@spike-omp
assert_rc 0 'xdg install'
exists "$case_home/data/omp/marketplaces.json" "$case_home/data/omp/plugins/node_modules/ycc-spike"
absent "$case_home/home/.omp/marketplaces.json"
layout profile "$case_home"
extra_env=(PI_CODING_AGENT_DIR="$case_home/agentdir")
o agentdir-path config path
extra_env=()
has agentdir-path '<SANDBOX>/cases/profile/agentdir'
# shellcheck disable=SC2016 # literal variable name, not an expansion
log 'PASS roots: --profile/OMP_PROFILE -> ~/.omp/profiles/<name>/; init-xdg -> $XDG_DATA_HOME/omp/{marketplaces.json,plugins}; PI_CODING_AGENT_DIR moves the agent dir'

# 11. Cross-harness auto-import (skills + MCP) in the isolated home.
use_case foreign
seed_agent
fh=$case_home/home
python3 - "$fh" "$root/mcp_stub.py" <<'PY'
import json
import sys
from pathlib import Path
home, stub = Path(sys.argv[1]), sys.argv[2]
def skill(base, name, desc=None):
    d = home / base / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "SKILL.md").write_text(f"---\nname: {name}\ndescription: {desc or 'marker ' + name}\n---\nb\n")
for base, name in ((".claude/skills", "claude-home-skill"), (".codex/skills", "codex-home-skill"),
                   (".cursor/skills", "cursor-home-skill"), (".agents/skills", "agents-home-skill"),
                   (".config/opencode/skills", "opencode-home-skill"), (".agents/skills", "dup-skill")):
    skill(base, name)
skill(".omp/agent/skills", "dup-skill", "NATIVE-WINS")
srv = lambda n: {"command": "python3", "args": [stub, n]}
(home / ".claude.json").write_text(json.dumps({"mcpServers": {"claudejson": srv("claudejson"), "claudeonly": srv("claudeonly")}}))
(home / ".codex/config.toml").write_text(f'[mcp_servers.codextoml]\ncommand = "python3"\nargs = ["{stub}", "codextoml"]\n')
(home / ".cursor/mcp.json").write_text(json.dumps({"mcpServers": {"cursormcp": srv("cursormcp")}}))
(home / ".config/opencode/opencode.json").write_text(json.dumps({"mcp": {"opencodemcp": {"type": "local", "command": ["python3", stub, "opencodemcp"]}}}))
(home / ".omp/agent/mcp.json").write_text(json.dumps({"mcpServers": {"nativemcp": srv("nativemcp"), "claudejson": srv("nativeclaudejson")}}))
PY
rpc rpc-foreign-default
has rpc-foreign-default 'skill:agents-home-skill' 'mcp__nativemcp_ping' 'NATIVE-WINS' 'nativeclaudejson_ping'
lacks rpc-foreign-default 'skill:claude-home-skill' 'skill:codex-home-skill' 'skill:opencode-home-skill' \
  'skill:cursor-home-skill' 'mcp__codextoml_ping' 'mcp__cursormcp_ping' 'mcp__opencodemcp_ping' 'claudeonly_ping'
o optin config set enabledProviders '["*"]'
assert_rc 0 'config set enabledProviders'
rpc rpc-foreign-all
has rpc-foreign-all 'skill:claude-home-skill' 'skill:codex-home-skill' 'skill:opencode-home-skill' \
  'mcp__codextoml_ping' 'mcp__cursormcp_ping' 'mcp__opencodemcp_ping' 'NATIVE-WINS' 'nativeclaudejson_ping' \
  'claudeonly_ping'
lacks rpc-foreign-all 'skill:cursor-home-skill' 'mcp__claudejson_ping'
o optin-claude config set enabledProviders '["claude"]'
assert_rc 0 'config set enabledProviders claude'
rpc rpc-foreign-claude
has rpc-foreign-claude 'skill:claude-home-skill' 'claudeonly_ping'
lacks rpc-foreign-claude 'skill:codex-home-skill' 'mcp__codextoml_ping' 'mcp__cursormcp_ping' 'mcp__claudejson_ping'
log 'PASS import: default loads only ~/.agents + native; enabledProviders opt-in loads ~/.claude, ~/.codex, ~/.config/opencode skills and ~/.claude.json (non-shadowed claudeonly)/~/.codex/config.toml/~/.cursor/mcp.json/opencode.json MCP; ~/.cursor/skills never; same-name native skill/MCP wins'

# 12. Agent `model:` dialect and registration without package.json.
# A probe extension (`-e`) calls omp's own task-agent discovery (internal module
# @oh-my-pi/pi-coding-agent/task/discovery, a spike-only probe) and publishes the
# resolved `model` of `model-agent` as its command description, so no inference runs.
use_case dialect
seed_agent
python3 - "$root" <<'PY'
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
agent = "---\nname: model-agent\ndescription: Model agent MODELAGENT\nmodel: \"@smol\"\n---\nx\n"
skill = "---\nname: nopkg-skill\ndescription: No package.json NOPKGMARK\n---\nb\n"
for name, manifest in (("dialect-claude", ".claude-plugin"), ("dialect-omp", ".omp-plugin"),
                       ("mkt-local/nopkg", ".omp-plugin")):
    d = root / name
    for rel, text in (("agents/model-agent.md", agent), ("skills/nopkg-skill/SKILL.md", skill),
                      (manifest + "/plugin.json", json.dumps({"name": d.name, "version": "0.0.1"}))):
        (d / rel).parent.mkdir(parents=True, exist_ok=True)
        (d / rel).write_text(text)
(root / "mkt-local/.omp-plugin").mkdir(parents=True)
(root / "mkt-local/.omp-plugin/marketplace.json").write_text(json.dumps({
    "name": "spike-local", "owner": {"name": "spike"},
    "plugins": [{"name": "nopkg", "source": "./nopkg", "version": "0.0.1"}]}))
(root / "probe.ts").write_text("""export default async function (pi) {
  let d;
  try {
    const m = await import("@oh-my-pi/pi-coding-agent/task/discovery");
    const a = (await m.discoverAgents(process.cwd())).agents.find(x => x.name === "model-agent");
    d = "PROBE model-agent model=" + (a ? (a.model ? [].concat(a.model).join(",") : "none") : "absent");
  } catch (e) { d = "PROBEERR " + String(e).replace(/"/g, "'"); }
  pi.registerCommand("probe", { description: d, handler: async () => {} });
}
""")
PY
rpc rpc-dialect-claude -e "$root/probe.ts" --plugin-dir "$root/dialect-claude"
has rpc-dialect-claude 'PROBE model-agent model=none'
rpc rpc-dialect-omp -e "$root/probe.ts" --plugin-dir "$root/dialect-omp"
has rpc-dialect-omp 'PROBE model-agent model=@smol'
o nopkg-add plugin marketplace add "$root/mkt-local"
assert_rc 0 'local marketplace add'
o nopkg-install plugin install nopkg@spike-local
assert_rc 0 'install plugin without package.json'
has nopkg-install 'Installed nopkg from spike-local (0.0.1)'
nopkg_cache=$case_home/home/.omp/plugins/cache/plugins/spike-local___nopkg___0.0.1
absent "$nopkg_cache/package.json"
[[ "$(readlink "$case_home/home/.omp/plugins/node_modules/nopkg")" == "$nopkg_cache" ]] ||
  die 'plugin without package.json must still link node_modules/<plugin name>'
rpc rpc-nopkg -e "$root/probe.ts"
has rpc-nopkg '"name":"skill:nopkg-skill"' 'PROBE model-agent model=@smol'
log 'PASS dialect: .claude-plugin root drops agent model (none); .omp-plugin root keeps @smol; plugin without package.json installs, links node_modules/<plugin name>, and loads skills and agents'

log "PASS all YAN-1165 omp runtime-contract checks ($version, sandbox=$sandbox)"
