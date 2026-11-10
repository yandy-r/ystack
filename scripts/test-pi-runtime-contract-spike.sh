#!/usr/bin/env bash
# Opt-in, offline YAN-1182 (GitHub #517) live checks of the Pi (@earendil-works/pi-coding-agent)
# runtime contract. No real auth, no credentials, no model inference.
# Evidence dossier: docs/internal/spikes/pi-runtime-contract.md
# Decision record: docs/internal/adr/0003-pi-runtime-contract.md
# shellcheck disable=SC2154 # sandbox and wrap come from lib/omp-harness-common.sh
set -euo pipefail
umask 077
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/omp-harness-common.sh"

usage() {
  cat <<'EOF'
Usage: test-pi-runtime-contract-spike.sh [--keep] [--output-dir DIR] [--allow-env-i]

Requires PI_BIN (absolute path to the `pi` launcher) or pi on PATH, version >=1.2.0, a Node
that satisfies Pi's engines (>=22.19.0; NODE_BIN overrides `node` on PATH), plus git, python3,
timeout, and standard Linux utilities. No inference.
--keep            Retain the sandbox (otherwise removed by EXIT trap).
--output-dir DIR  Existing parent directory under /tmp; implies --keep.
--allow-env-i     Run without bubblewrap isolation (env -i only; no network
                  namespace, real home not hidden). Without this flag the
                  harness fails closed when bwrap cannot create the sandbox.
-h, --help        Show help. Default sandbox: mktemp -d under /tmp.

Every pi call runs under `env -i` with HOME, XDG_*, TMPDIR, npm and git config isolated
under the sandbox, PI_OFFLINE=1 and npm offline mode. By default each call also runs under
bubblewrap in private network and PID namespaces with the invoking user's real home, /run
and /tmp hidden behind tmpfs (only the Node prefix, Pi's node_modules tree and the sandbox
root are bound back), so the real ~/.pi is unreachable. git: sources with .invalid hosts are
rewritten to local bare repos by git `insteadOf`, and GIT_ALLOW_PROTOCOL=file limits git to
file://. Sessions use a null openai-completions model on 127.0.0.1:9 whose runs the probe
extension aborts before any request, or an in-process scripted provider (pi-ai faux) loaded as
an extension.
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
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
pi_bin=${PI_BIN:-$(command -v pi || true)}
[[ -n "$pi_bin" && -x "$pi_bin" ]] || die 'set PI_BIN or install pi on PATH'
pi_js=$(realpath "$pi_bin")
[[ "$pi_js" == */dist/bundle/cli.js || "$pi_js" == */dist/cli.js ]] ||
  die "PI_BIN must resolve to the npm package launcher (dist/.../cli.js), got $pi_js"
pi_pkg=${pi_js%/dist/*}
[[ -f "$pi_pkg/package.json" ]] || die "no package.json above $pi_js"
# Bind the whole npm node_modules tree that holds Pi: its dependencies are hoisted beside it.
pi_tree=$pi_pkg
[[ "$pi_pkg" != */node_modules/* ]] || pi_tree=${pi_pkg%%/node_modules/*}/node_modules
node_bin=${NODE_BIN:-$(command -v node || true)}
[[ -n "$node_bin" && -x "$node_bin" ]] || die 'set NODE_BIN or install node on PATH'
node_bin=$(realpath "$node_bin")
node_prefix=$(dirname "$(dirname "$node_bin")")
real_home=$(realpath "${HOME:?HOME must be set}")
[[ -d "$parent" ]] || die '--output-dir must exist'
parent=$(realpath "$parent")
omp_h_under_tmp "$parent" || die 'output must be under /tmp'
[[ "$parent" =~ ^[A-Za-z0-9._/-]+$ ]] || die "--output-dir must match [A-Za-z0-9._/-]+, got '$parent'"
root=$(omp_h_mktemp_root pi-runtime-contract-spike "$parent")
[[ "$root" != "$real_home" && "$root" != "$real_home"/* ]] || die 'sandbox must not live under the real HOME'
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3))) || die 'bash >= 4.3 is required'
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
mkdir -p "$root"/{work,tmp,logs,cases,probe}
cd "$root/work"
# Node's bin dir leads the sandbox PATH so pi, npm and the subagent example's child pi resolve.
safe_path=$(omp_h_safe_path "$allow_env_i" "$(dirname "$node_bin")")
omp_h_check_path_tools "$safe_path" node npm git python3 timeout
# Host-side Python (fixtures, sanitize, assertions) runs from the checkout, which sits outside the
# sandbox's writable area. Only the in-sandbox RPC driver uses a copy under $root.
helper_src=$repo/scripts/pi_runtime_spike.py
helper=$root/helper.py
cp "$helper_src" "$helper"
h() { python3 "$helper_src" "$@"; }

# Network/home isolation (bwrap, see omp_h_sandbox): read-only host tree; the real home, /run and
# /tmp hidden behind tmpfs; private network and PID namespaces. Node, Pi's tree and (when outside
# the hidden home) the read-only checkout are bound back; omp_h_sandbox refuses any of them that
# would re-expose the real home. Without bwrap the harness fails closed unless --allow-env-i
# explicitly accepts the weaker env -i-only sandbox.
ro_paths=("$node_prefix" "$pi_tree")
[[ "$repo" == "$real_home"/* ]] || ro_paths+=("$repo")
omp_h_sandbox "$allow_env_i" "$root" "$real_home" "${ro_paths[@]}"

case_home=
agent=
# Select (and create) the isolated HOME/XDG tree for subsequent pi calls; seed the agent dir.
use_case() {
  case_home=$root/cases/$1
  agent=$case_home/home/.pi/agent
  mkdir -p "$case_home"/{home,config,data,state,cache,runtime}
  h seed-home "$agent" "$root"
}
extra_env=()
# Run a command under env -i with isolated HOME/XDG, offline npm, file-only git rewrites, and the wrapper.
clean() {
  local hh
  hh=$(realpath -m "$case_home/home")
  [[ "$hh" == "$root"/* && "$hh" != "$real_home" && "$hh" != "$real_home"/* ]] ||
    die "refusing to run with HOME=$hh outside $root"
  env -i PATH="$safe_path" LANG=C.UTF-8 TERM=dumb NO_COLOR=1 \
    HOME="$hh" XDG_CONFIG_HOME="$case_home/config" XDG_DATA_HOME="$case_home/data" \
    XDG_STATE_HOME="$case_home/state" XDG_CACHE_HOME="$case_home/cache" \
    XDG_RUNTIME_DIR="$case_home/runtime" TMPDIR="$root/tmp" \
    PI_OFFLINE=1 PI_TELEMETRY=0 PI_SKIP_VERSION_CHECK=1 \
    npm_config_offline=true npm_config_update_notifier=false npm_config_fund=false npm_config_audit=false \
    PI_SPIKE_STUB="$root/stub.py" PI_SPIKE_MARKER="$root/hook-ran" PI_SPIKE_PREPARE="$root/prepare-ran" \
    ${extra_env[@]+"${extra_env[@]}"} \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    GIT_ALLOW_PROTOCOL=file GIT_CONFIG_COUNT=4 \
    GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
    GIT_CONFIG_KEY_1="url.file://$root/pkg.git.insteadOf" GIT_CONFIG_VALUE_1=https://pi-spike.invalid/spike/pkg \
    GIT_CONFIG_KEY_2="url.file://$root/mono.git.insteadOf" GIT_CONFIG_VALUE_2=https://pi-spike.invalid/spike/mono \
    GIT_CONFIG_KEY_3="url.file://$root/dep.git.insteadOf" GIT_CONFIG_VALUE_3=https://pi-spike.invalid/spike/dep \
    "$@"
}
# Write a status line to stdout and append it to the transcript.
log() { printf '%s\n' "$*" | tee -a "$root/transcript.log"; }
rc=0
# Execute a command under timeout in the sandbox; sanitize sandbox paths/ANSI; record argv/exit.
run() {
  local label=$1; shift
  local out="$root/logs/$label.stdout" err="$root/logs/$label.stderr"
  rc=0
  clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 120 "$@" </dev/null >"$out" 2>"$err" || rc=$?
  h sanitize "$root" "$real_home" "$out" "$err"
  { printf '\n[%s] case=%s cwd=%s argv:' "$label" "${case_home#"$root"/}" "${PWD/#"$root"/<SANDBOX>}"
    local argv=("${@/#"$root"/<SANDBOX>}")
    printf ' %q' "${argv[@]/#"$real_home"/<HOME>}"; printf '\nexit=%s\nstdout:\n' "$rc"
    head -c 3000 "$out"; printf '\nstderr:\n'; head -c 2000 "$err"; printf '\n'
  } >>"$root/transcript.log"
}
# Run pi with the given label.
p() { local label=$1; shift; run "$label" "$node_bin" "$pi_js" "$@"; }
# Assert that the most recent run() returned the expected exit status.
assert_rc() { [[ "$rc" == "$1" ]] || die "$2: expected rc=$1, got $rc (see $root/transcript.log)"; }
# Assert literal strings are (has) or are not (lacks) in a run's stdout+stderr.
has() {
  local label=$1 tok; shift
  for tok in "$@"; do
    grep -qF -- "$tok" "$root/logs/$label.stdout" "$root/logs/$label.stderr" ||
      die "$label: expected output to contain '$tok' (see $root/transcript.log)"
  done
}
# Probe-file assertions (pi_runtime_spike.py probe/json); FILE may be a label (probe/<label>.json).
chk() {
  local kind=$1 file=$2; shift 2
  [[ "$file" == /* ]] || file=$root/probe/$file.json
  h probe "$kind" "$file" "$@" || die "check $kind on ${file/#"$root"/<SANDBOX>} failed (see $root/transcript.log)"
}
jchk() { h json "$@" || die "json check $1 on ${2/#"$root"/<SANDBOX>} failed"; }
exists() { for x in "$@"; do [[ -e "$x" ]] || die "expected path to exist: ${x/#"$root"/<SANDBOX>}"; done; }
absent() { for x in "$@"; do [[ ! -e "$x" ]] || die "expected path to be absent: ${x/#"$root"/<SANDBOX>}"; done; }
# Feed JSONL frames (one per argument) to `pi --mode rpc`; the probe command is always last.
rpc() {
  local label=$1 frames; shift
  frames=$root/tmp/$label.frames
  : >"$frames"
  while (($#)) && [[ "$1" == '{'* ]]; do printf '%s\n' "$1" >>"$frames"; shift; done
  printf '%s\n' '{"id":"probe","type":"prompt","message":"/spike-probe"}' >>"$frames"
  local prev=(${extra_env[@]+"${extra_env[@]}"})
  extra_env+=(PI_SPIKE_PROBE_OUT="$root/probe/$label.json")
  run "$label" python3 "$helper" rpc "$frames" "$node_bin" "$pi_js" --mode rpc --no-session -e "$root/ext/probe.ts" "$@"
  extra_env=(${prev[@]+"${prev[@]}"})
  assert_rc 0 "$label rpc"
  has "$label" '"id":"probe","type":"response","command":"prompt","success":true'
}
settings() { python3 - "$agent/settings.json" "$1" <<'PY'
import json
import sys

path, patch = sys.argv[1], json.loads(sys.argv[2])
with open(path) as f:
    data = json.load(f)
data.update(patch)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY
}
version_ge() { python3 -c 'import sys; a, b = (tuple(map(int, v.split("."))) for v in sys.argv[1:]); sys.exit(a < b)' "$1" "$2"; }

# ---------------------------------------------------------------------------
# Fixtures (host side): packages, project, extensions, stub MCP; then the isolated bootstrap home.
h fixtures "$root" "$repo/packages/claude/ycc-mcp/.mcp.json" "$repo/ycc/agents/code-reviewer.md"
use_case bootstrap
p version --version
assert_rc 0 version
version=$(tr -d '[:space:]' <"$root/logs/version.stdout")
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! version_ge "$version" 1.2.0; then
  die "pi >=1.2.0 (stable version string) required, got '$version'"
fi
log "YAN-1182 | pi $version | node $("$node_bin" --version) | sandbox=$sandbox | offline fixtures | $(date -u +%F)"
for sub in '' install remove update list config mcp; do
  p "help-${sub:-root}" ${sub:+"$sub"} --help
  assert_rc 0 "pi $sub --help"
done
has help-root 'pi install <source> [-l]' 'pi mcp <command>' '--approve' '--no-approve' '--no-mcp' 'PI_CODING_AGENT_DIR' '--offline'
has help-mcp 'pi mcp list [--json]' 'pi mcp add <server>'

# Three bare git repos served through insteadOf. Fixture git also runs in the sandbox. Each repo
# is tagged v0.0.1, then gains a `main-only` marker commit, so a pinned install must omit it.
g() { clean ${wrap[@]+"${wrap[@]}"} git -c user.name=spike -c user.email=spike@localhost -c commit.gpgsign=false "$@"; }
for name in pkg mono dep; do
  g -C "$root/$name" init -q -b main
  g -C "$root/$name" add -A
  g -C "$root/$name" commit -qm "$name"
  g -C "$root/$name" tag v0.0.1
  : >"$root/$name/main-only"
  g -C "$root/$name" add main-only
  g -C "$root/$name" commit -qm 'after the tag'
  g clone -q --bare "$root/$name" "$root/$name.git"
done
pkg_tag=$(g -C "$root/pkg" rev-parse 'v0.0.1^{commit}')
log "PASS cli: pi $version; install/remove/update/list/config/mcp subcommands; --approve/--no-approve/--no-mcp/--offline; PI_CODING_AGENT_DIR"

# 1. Local package, conventional directories, user scope; prompt templates and skill commands.
use_case local
p install-local install "$root/pkg"
assert_rc 0 'install local'
has install-local 'Installed '
jchk packages-eq "$agent/settings.json" ../../../../../pkg
p list-local list
has list-local 'User packages:' '<SANDBOX>/pkg'
rpc rpc-local '{"id":"tpl","type":"prompt","message":"/spike-tpl alpha \"b c\" d"}' \
  '{"id":"skill","type":"prompt","message":"/skill:ph one two"}' \
  '{"id":"chain","type":"prompt","message":"/ycc:chain x y"}' -e "$root/ext/chain.ts"
chk commands-has rpc-local spike-ext ycc:colon-ext spike-tpl ycc:colon-tpl ycc:chain skill:spike-skill ycc:ext-chain
chk seen-has "$root/probe/rpc-local.json.prompts" 'TPL all=alpha b c d first=alpha rest=b c d' \
  'PHBODY root=${CLAUDE_PLUGIN_ROOT} args=$ARGUMENTS' $'</skill>\n\none two' '/skill:ph x y'
rpc rpc-chain '{"id":"ext","type":"prompt","message":"/ycc:ext-chain z"}' -e "$root/ext/chain.ts"
chk seen-has "$root/probe/rpc-chain.json.prompts" '<skill name="ph"'
# shellcheck disable=SC2016 # literal placeholder names, not expansions
log 'PASS package(local): conventional extensions/skills/prompts load from a user-scope local path (relative entry in settings.json); `ycc:`-prefixed template and extension command names accepted; $ARGUMENTS/$1/${@:2} expand; /skill:<name> appends args and leaves ${CLAUDE_PLUGIN_ROOT}/$ARGUMENTS literal; a template that emits /skill:x is not re-expanded; an extension command using sendUserMessage(..., {expandPromptTemplates:true}) does expand /skill:x'

# 2. package.json#pi manifest replaces conventional discovery; settings filter object.
use_case manifest
p install-manifest install "$root/mpkg"
assert_rc 0 'install manifest package'
rpc rpc-manifest
chk commands-has rpc-manifest man-ext skill:man-skill
chk commands-lacks rpc-manifest conv-tpl skill:conv-skill
p install-pkg install "$root/pkg"
settings '{"packages":["../../../../../mpkg",{"source":"../../../../../pkg","skills":["skills/spike-skill"],"prompts":[],"extensions":[]}]}'
p list-filtered list
has list-filtered '(filtered)'
rpc rpc-filtered
chk commands-has rpc-filtered skill:spike-skill
chk commands-lacks rpc-filtered spike-ext spike-tpl
chk paths-lacks rpc-filtered /pkg/skills/dup/
log 'PASS manifest: package.json#pi (extensions+skills) disables conventional discovery for every type (prompts/ and skills/ ignored); settings package object filters (skills glob, prompts [], extensions []) narrow loading; `pi list` marks (filtered)'

# 3. git packages: pinned ref, update, remove; offline npm failure rolls back; lifecycle scripts; identity.
use_case git
p install-git install git:pi-spike.invalid/spike/pkg@v0.0.1
assert_rc 0 'install git pinned'
has install-git "Note: switching to 'v0.0.1'." 'Installed git:pi-spike.invalid/spike/pkg@v0.0.1'
pkg_dir=$agent/git/pi-spike.invalid/spike/pkg
exists "$pkg_dir/skills/spike-skill/SKILL.md"
absent "$pkg_dir/main-only"
[[ "$(g -C "$pkg_dir" rev-parse HEAD)" == "$pkg_tag" ]] || die 'pinned git install must check out the v0.0.1 commit'
p update-git update git:pi-spike.invalid/spike/pkg@v0.0.1
assert_rc 0 'update git'
p update-ext update --extensions
assert_rc 0 'update --extensions'
has update-ext 'Updated packages'
p install-dep install git:pi-spike.invalid/spike/dep
assert_rc 1 'git package with a runtime dependency, npm offline'
has install-dep 'ENOTCACHED' 'npm install --omit=dev'
absent "$agent/git/pi-spike.invalid/spike/dep"
p install-mono install git:pi-spike.invalid/spike/mono
assert_rc 0 'install git monorepo'
exists "$root/prepare-ran"
settings '{"packages":[{"source":"git:pi-spike.invalid/spike/mono","skills":["packages/pi/ycc-rules/skills/**"]},{"source":"git:pi-spike.invalid/spike/mono","skills":["packages/pi/ycc/skills/**"]}]}'
rpc rpc-mono
chk commands-has rpc-mono skill:rule-skill
chk commands-lacks rpc-mono skill:mono-skill
settings '{"packages":["git:pi-spike.invalid/spike/pkg@v0.0.1"]}'
p remove-git remove git:pi-spike.invalid/spike/pkg@v0.0.1
assert_rc 0 'remove git'
has remove-git 'Removed git:pi-spike.invalid/spike/pkg@v0.0.1'
absent "$pkg_dir"
jchk packages-eq "$agent/settings.json" -
log 'PASS package(git): git:<host>/<path>@<ref> clones to <agentDir>/git/<host>/<path> and checks out the tag commit (a later main-only commit is absent); update/update --extensions rc=0; npm dependency install failure (offline) exits 1 and removes the checkout; npm runs the package `prepare` lifecycle script; two entries for one repo URL load only the first (identity = repo URL); remove deletes checkout and entry'

# 4. Project scope and package identity across scopes.
use_case project
proj=$root/proj
g -C "$proj" init -q
cd "$proj"
p install-project-untrusted install -l "$root/mpkg"
assert_rc 1 'install -l in an untrusted project'
has install-project-untrusted 'Project is not trusted. Use --approve'
p install-project install -l --approve "$root/mpkg"
assert_rc 0 'install -l --approve'
grep -qF '../../mpkg' "$proj/.pi/settings.json" || die 'project settings must carry the package'
p install-user-same install "$root/mpkg"
assert_rc 0 'install the same package at user scope'
jchk packages-eq "$agent/settings.json" ../../../../../mpkg
rpc rpc-project-scope --approve
chk command-scope rpc-project-scope man-ext project package
p remove-project remove -l --approve "$root/mpkg"
assert_rc 0 'remove -l'
cd "$root/work"
log 'PASS scopes: -l writes .pi/settings.json only with --approve (untrusted rc=1); the same local package in user and project settings loads once, from the project entry'

# 5. Project trust: what loads before and after trust, context files, system-prompt files.
use_case trust
cd "$proj"
for mode in default approve no-approve; do
  args=()
  [[ $mode == default ]] || args=(--"$mode")
  extra_env=(PI_SPIKE_WAIT_MCP=1)
  rpc "rpc-trust-$mode" ${args[@]+"${args[@]}"}
  extra_env=()
done
for label in rpc-trust-default rpc-trust-no-approve; do
  chk trusted "$label" false
  chk commands-lacks "$label" proj-ext proj-tpl skill:proj-skill skill:agents-proj
  chk tools-lacks "$label" mcp__projmcp__projmcp_ping
  chk prompt-has "$label" PROJAGENTSMD USERAGENTSMD USERAPPEND
  chk prompt-lacks "$label" PROJAPPEND PROJCLAUDEMD
done
chk trusted rpc-trust-approve true
chk commands-has rpc-trust-approve proj-ext proj-tpl skill:proj-skill skill:agents-proj
chk tools-has rpc-trust-approve mcp__projmcp__projmcp_ping
chk prompt-has rpc-trust-approve PROJAPPEND PROJAGENTSMD
chk prompt-lacks rpc-trust-approve USERAPPEND PROJCLAUDEMD
chk context-has rpc-trust-approve /home/.pi/agent/AGENTS.md /proj/AGENTS.md
settings '{"defaultProjectTrust":"always"}'
rpc rpc-trust-always
chk trusted rpc-trust-always true
chk commands-has rpc-trust-always proj-ext
settings '{"defaultProjectTrust":"ask"}'
p mcp-list-untrusted mcp list --json
has mcp-list-untrusted 'is ignored because the project is not trusted'
p mcp-add-local mcp add -l projx -- python3 "$root/stub.py" projx
assert_rc 0 'mcp add -l'
has mcp-add-local 'The project is not trusted'
cd "$root/ctxonly"
python3 -c 'import json, sys; json.dump({sys.argv[1]: False}, open(sys.argv[2], "w"))' "$root/ctxonly" "$agent/trust.json"
rpc rpc-trust-saved-no
chk prompt-has rpc-trust-saved-no CTXONLYAGENTS
if version_ge "$version" 1.5.0; then
  chk trusted rpc-trust-saved-no false
  saved='a saved "no" for a folder with only AGENTS.md is honoured (isProjectTrusted=false)'
else
  chk trusted rpc-trust-saved-no true
  saved='a saved "no" for a folder with only AGENTS.md is IGNORED before 1.5.0 (isProjectTrusted=true)'
fi
rm "$agent/trust.json"
printf 'USERSYSTEMMARK\n' >"$agent/SYSTEM.md"
rpc rpc-system-md
chk prompt-has rpc-system-md USERSYSTEMMARK USERAPPEND
chk prompt-lacks rpc-system-md 'coding assistant'
rm "$agent/SYSTEM.md"
cd "$root/work"
log "PASS trust: RPC with no decision (ask) and --no-approve skip .pi extensions/prompts/skills/mcp.json/APPEND_SYSTEM.md and .agents/skills; --approve or defaultProjectTrust=always load them; AGENTS.md (user + project) loads regardless; CLAUDE.md is skipped when AGENTS.md is in the same dir; trusted .pi/APPEND_SYSTEM.md replaces the user one; SYSTEM.md replaces the base prompt; pi mcp list/add -l name the untrusted project; $saved"

# 6. Skills: ~/.agents discovery, precedence, collisions, frontmatter limits, overrides.
use_case skills
p install-skills install "$root/pkg"
rpc rpc-skills
chk commands-has rpc-skills skill:agents-user skill:Bad_Name skill:longdesc skill:hidden skill:dup2 skill:dup
chk command-scope rpc-skills skill:agents-user user top-level
chk command-scope rpc-skills skill:spike-skill user package
chk tools-has rpc-skills read bash edit write grep find ls codemode tool_search
chk commands-lacks rpc-skills skill:nodesc
chk prompt-lacks rpc-skills HIDDENSKILL AGENTS-DUP2 PKG-DUP
chk skill-desc rpc-skills dup2 USER-DUP2
chk skill-desc rpc-skills dup AGENTS-DUP
chk prompt-has rpc-skills AGENTSUSER BADNAME LLLLLLLLLL
settings '{"skills":["-~/.agents/skills/dup/SKILL.md"]}'
rpc rpc-skills-override
chk skill-desc rpc-skills-override dup PKG-DUP
rpc rpc-claude-tools --tools Read,Grep,Glob
chk active-tools rpc-claude-tools -
chk tools-lacks rpc-skills subagent task Task
log 'PASS skills: ~/.agents/skills auto-discovered (scope user, origin top-level); precedence ~/.pi/agent/skills > ~/.agents/skills > package skills (first wins, no namespacing); invalid name still loads, missing description skips, >1024-char description loads (load-time warnings are not asserted: RPC does not surface them); disable-model-invocation keeps /skill:<name> but leaves the prompt; settings skills "-~/.agents/skills/<n>/SKILL.md" hides the alias; Claude-cased --tools Read,Grep,Glob activates no tools; built-in tools read/bash/edit/write/grep/find/ls/codemode/tool_search, no subagent/task tool'

# 7. MCP: pi mcp add/list, SSE rejection, the shipped ycc-mcp server set, extension-registered servers.
use_case mcp
p mcp-add mcp add spikemcp -- python3 "$root/stub.py" spikemcp
assert_rc 0 'mcp add'
p mcp-list mcp list --json
assert_rc 0 'mcp list'
jchk mcp-server "$root/logs/mcp-list.stdout" spikemcp connected codemode spikemcp_ping
jchk mcp-errors-none "$root/logs/mcp-list.stdout"
printf '{"mcpServers":{"badsse":{"type":"sse","url":"http://127.0.0.1:9/sse"}}}\n' >"$agent/mcp.json"
p mcp-list-sse mcp list --json
assert_rc 1 'mcp list with an sse entry'
jchk mcp-errors-has "$root/logs/mcp-list-sse.stdout" 'legacy SSE transport is not supported'
cp "$root/ycc-mcp.json" "$agent/mcp.json"
p mcp-list-ycc mcp list --json
assert_rc 0 'mcp list (ycc-mcp servers, enabled:false)'
jchk mcp-states "$root/logs/mcp-list-ycc.stdout" disabled 9
jchk mcp-errors-none "$root/logs/mcp-list-ycc.stdout"
p mcp-add-again mcp add spikemcp -- python3 "$root/stub.py" spikemcp
extra_env=(PI_SPIKE_WAIT_MCP=1)
rpc rpc-mcp -e "$root/ext/hooks.ts"
extra_env=()
chk tools-has rpc-mcp mcp__spikemcp__spikemcp_ping mcp__extmcp__extmcp_ping
has rpc-mcp '"method":"setStatus","statusKey":"ycc","statusText":"STATUSMARK"'
log 'PASS mcp: pi mcp add writes <agentDir>/mcp.json; pi mcp list --json connects stdio (state connected, exposure codemode, tools [spikemcp_ping], errors []); sse entries are rejected (rc=1); the shipped ycc-mcp .mcp.json parses unchanged (9 servers, stdio+http, errors []); pi.registerMcpServer adds a session server; tools are mcp__<server>__<tool>; ctx.ui.setStatus reaches RPC clients'

# 8. Extensions: load failures, tool_call gate, lifecycle events (scripted in-process provider).
use_case hooks
p ext-broken --mode rpc --no-session -e "$root/ext/broken.ts"
assert_rc 1 'broken -e extension'
has ext-broken 'Failed to load extension' 'BROKENEXT'
p install-broken install "$root/bpkg"
p ext-broken-pkg --mode rpc --no-session
assert_rc 1 'broken package extension'
has ext-broken-pkg 'Failed to load extension' 'BROKENPKG'
p remove-broken remove "$root/bpkg"
extra_env=(PI_SPIKE_PROBE_OUT="$root/probe/hooks.json")
printf '%s\n' '{"id":"go","type":"prompt","message":"HOOKTASK"}' >"$root/tmp/hooks.frames"
run rpc-hooks python3 "$helper" rpc "$root/tmp/hooks.frames" "$node_bin" "$pi_js" --mode rpc --no-session \
  --model spike-faux/scripted -e "$root/ext/faux.ts" -e "$root/ext/hooks.ts"
extra_env=()
assert_rc 0 'scripted hook session'
has rpc-hooks 'PARENT-DONE BLOCKED-BY-SPIKE'
absent "$root/hook-ran"
chk seen-has "$root/probe/hooks.json.hooks" session_start tool_call:bash agent_settled
log 'PASS extensions: a throwing extension (-e or package) aborts startup rc=1 (`Failed to load extension`); tool_call returning {block} stops a scripted bash call (no side effect) and the reason reaches the model; session_start/agent_settled fire'

# 9. Subagents: absent by default; the upstream example extension delegates to child pi processes.
use_case subagent
mkdir -p "$agent/extensions"
cp "$root/ext/faux.ts" "$agent/extensions/faux.ts"
subagent=$pi_pkg/examples/extensions/subagent/index.ts
exists "$subagent"
for task in delegate DELEGATE-YCC; do
  printf '{"id":"go","type":"prompt","message":"%s"}\n' "$task" >"$root/tmp/$task.frames"
  run "rpc-subagent-$task" python3 "$helper" rpc "$root/tmp/$task.frames" "$node_bin" "$pi_js" --mode rpc \
    --no-session --model spike-faux/scripted -e "$subagent"
  assert_rc 0 "subagent $task"
done
has rpc-subagent-delegate 'PARENT-DONE CHILD-DONE'
has rpc-subagent-DELEGATE-YCC 'PARENT-DONE Agent failed: No API key found for amazon-bedrock.'
log 'PASS subagents: no built-in subagent tool; examples/extensions/subagent spawns child `pi --mode json -p --no-session` runs from <agentDir>/agents/*.md (scripted scout returns CHILD-DONE to the parent); a verbatim ycc agent fails in the child (`model: sonnet` resolves to amazon-bedrock: `No API key found for amazon-bedrock.`)'

# 10. Agent dir relocation.
use_case agentdir
extra_env=(PI_CODING_AGENT_DIR="$case_home/alt-agent")
p agentdir-install install "$root/pkg"
extra_env=()
assert_rc 0 'install with PI_CODING_AGENT_DIR'
exists "$case_home/alt-agent/settings.json"
grep -qF 'pkg' "$case_home/alt-agent/settings.json" || die 'PI_CODING_AGENT_DIR settings must carry the package'
! grep -qF '"packages"' "$agent/settings.json" || die "$agent/settings.json must stay untouched under PI_CODING_AGENT_DIR"
log 'PASS roots: PI_CODING_AGENT_DIR moves settings.json (and every agent-dir file) out of ~/.pi/agent'

log "PASS all YAN-1182 pi runtime-contract checks (pi $version, sandbox=$sandbox)"
