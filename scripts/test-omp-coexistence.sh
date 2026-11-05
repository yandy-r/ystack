#!/usr/bin/env bash
# Opt-in live checks: ycc on OMP beside the other ycc runtimes (YAN-1176), against real omp.
# Not part of CI. No credentials, no network inside the sandbox, no model inference.
# shellcheck disable=SC2154 # omp_in_dir, sandbox and wrap come from lib/omp-harness-common.sh
set -euo pipefail
umask 077
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/omp-harness-common.sh"

usage() {
  cat <<'EOF'
Usage: test-omp-coexistence.sh [--keep] [--allow-env-i]

Runs the real ./install.sh (YCC_INSTALL_SKIP_BUILD=1: the checkout is never written) and the
real omp >=18.12.2 (OMP_BIN overrides PATH; default ~/.local/bin/omp) in a mktemp sandbox
under /tmp: env -i, HOME/XDG/TMPDIR inside the sandbox, and bwrap with private network and PID
namespaces, a read-only host tree, the real home, /run and /tmp hidden behind tmpfs, and this
checkout bind-mounted read-only. Without bwrap the harness refuses to run unless
--allow-env-i accepts the weaker sandbox.
RPC sessions use a null model at 127.0.0.1:9; no prompt is ever sent. A probe extension
(-e) reports what omp's own loaders resolve: final skill names and collision warnings, task
agents, slash commands, and the MCP, context-file, hook and extension winners/_shadowed.

Cases:
  C1 omp only: 50 skills, 49 ycc: commands, 55 agents, 10 ycc-mcp servers, nothing shadowed
  C2 install --target agents then --target omp: W5, then W1; 50 skills, no agents/<name>
     alias, no collision warning (omp skill list stderr empty)
  C3 a Claude registry ycc@ycc copy (enabledProviders [claude]): no duplicate
  C4 enabledProviders ["*"] + Claude/Codex/Cursor/opencode skills, agents, commands, MCP and
     rules: W4 and W1 (codex/, opencode/); each MCP connection once, one context file, the
     documented winners (Claude skills hold bare names, agents only from ycc)
  C5 --project install + project .omp/skills/plan: bare plan is native:project; the user
     install is shadowed by the project install
  C6 OMP_PROFILE=work sees no ycc (plugins are per profile)
  C7 hostile project (hook, extension, .mcp.json, project plugin MCP, extensions:): every
     marker by default; none under --no-extensions --config <mcp.enableProjectConfig: false>,
     with ycc still loaded
  C8 remove --target omp --only base (--project, then user): no .omp/plugins residue,
     config.yml back to its pre-install bytes, ~/.agents skills bare again
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
for tool in git python3 timeout mktemp realpath sha256sum; do
  command -v "$tool" >/dev/null || die "missing prerequisite: $tool"
done
omp_h_require_gnu_tools

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
omp=${OMP_BIN:-$HOME/.local/bin/omp}
[[ -x "$omp" ]] || omp=$(command -v omp || true)
[[ -n "$omp" && -x "$omp" ]] || die 'set OMP_BIN or install omp at ~/.local/bin/omp or on PATH'
omp=$(realpath "$omp")
python=$(command -v python3)
real_home=$(realpath "${HOME:?HOME must be set}")
root=$(omp_h_mktemp_root omp-coexistence)
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
mkdir -p "$root"/{work,tmp,logs,bin,markers}
ln -s "$omp" "$root/bin/omp"
umask 022
cd "$root/work"
safe_path=$(omp_h_safe_path "$allow_env_i" "$root/bin")
omp_h_check_path_tools "$safe_path" bash git python3 timeout realpath

omp_h_sandbox "$allow_env_i" "$root" "$real_home" "$omp" "$repo"

# The current case: its HOME/XDG tree and extra environment (OMP_PROFILE).
case_home=$root/a
extra_env=()
clean() {
  local h
  h=$(realpath -m "$case_home/home")
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
    PYTHONDONTWRITEBYTECODE=1 YCC_INSTALL_SKIP_BUILD=1 \
    ${extra_env[@]+"${extra_env[@]}"} "$@"
}
# Run the HOME guard once with stderr visible: the preflight below discards it.
clean true
clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 30 omp --version >/dev/null 2>&1 ||
  die "OMP_BIN ($omp) does not run inside the $sandbox sandbox: it must be a self-contained binary"
log() { printf '%s\n' "$*" | tee -a "$root/transcript.log"; }
rc=0
stdin_file=/dev/null
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
  clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 180 "${omp_in_dir[@]}" "$dir" "$@" <"$stdin_file" \
    >"$root/logs/$label.stdout" 2>"$root/logs/$label.stderr" || rc=$?
  record "$label" "$@"
}
o() { local label=$1 dir=$2; shift 2; run "$label" "$dir" omp "$@"; }
# ycc LABEL DIR ARGS: this checkout's install.sh from DIR; it must succeed.
ycc() {
  local label=$1 dir=$2; shift 2
  run "$label" "$dir" "$repo/install.sh" "$@"
  ((rc == 0)) || die "$label: install.sh $* exited $rc (see $root/transcript.log)"
}
host() {
  local label=$1; shift
  [[ ! -e "$root/logs/$label.stdout" ]] || die "duplicate label: $label"
  rc=0
  clean timeout -k 5 300 "$@" >"$root/logs/$label.stdout" 2>"$root/logs/$label.stderr" || rc=$?
  record "$label" "$@"
  ((rc == 0)) || { cat "$root/logs/$label.stderr" >&2; die "$label exited $rc; see $root/transcript.log"; }
}
assert_rc() { [[ "$rc" == "$1" ]] || die "$2: expected rc=$1, got $rc (see $root/transcript.log)"; }
has() {
  local label=$1 tok; shift
  for tok in "$@"; do
    grep -qF -- "$tok" "$root/logs/$label.stdout" "$root/logs/$label.stderr" ||
      die "$label: expected output to contain '$tok' (see $root/transcript.log)"
  done
}
lacks() {
  local label=$1 tok; shift
  for tok in "$@"; do
    ! grep -qF -- "$tok" "$root/logs/$label.stdout" "$root/logs/$label.stderr" ||
      die "$label: output must not contain '$tok' (see $root/transcript.log)"
  done
}
check() { local label=$1; shift; host "$label" "$python" "$root/checks.py" "$@"; log "  $(<"$root/logs/$label.stdout")"; }
h() { realpath -m "$case_home/home"; }
agent_dir() { printf '%s/.omp/agent' "$(h)"; }

# Null model provider (per agent dir): RPC sessions start; no prompt is ever sent.
null_model() {
  mkdir -p "$1"
  cat >"$1/models.yml" <<'EOF'
providers:
  omp-coexistence-null:
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
}

# The probe imports omp's own loaders (discovery.loadCapability, extensibility/skills.loadSkills,
# task/discovery.discoverAgents); an upstream module move fails loudly (PROBEERR).
cat >"$root/probe.ts" <<'EOF'
export default async function (pi) {
  let d;
  try {
    const disc = await import("@oh-my-pi/pi-coding-agent/discovery");
    const sk = await import("@oh-my-pi/pi-coding-agent/extensibility/skills");
    const ag = await import("@oh-my-pi/pi-coding-agent/task/discovery");
    const cwd = process.cwd();
    const item = i => ({ name: i.name ?? i.path, provider: i._source?.provider, level: i._source?.level,
      path: i._source?.path ?? i.path, url: i.url, command: i.command, args: i.args, headers: i.headers });
    const caps = {};
    for (const id of ["context-files", "mcps", "hooks", "extension-modules"]) {
      const r = await disc.loadCapability(id, { cwd });
      caps[id] = { items: r.items.map(item), shadowed: r.all.filter(i => i._shadowed).map(item) };
    }
    // The session's own call (session-tools.ts refreshSkills): skills settings, disabledExtensions.
    const { cfgSkills, cfgDisabledExtensions } = await import("@oh-my-pi/pi-coding-agent/extensibility/settings");
    const { Settings } = await import("@oh-my-pi/pi-coding-agent/config/settings");
    const skills = await sk.loadSkills({ ...cfgSkills.get(Settings.instance), cwd,
      disabledExtensions: cfgDisabledExtensions.get(Settings.instance) });
    const agents = (await ag.discoverAgents(cwd)).agents.filter(a => a.source !== "bundled");
    d = "PROBE " + JSON.stringify({
      caps,
      skills: skills.skills.map(s => ({ name: s.name, source: s.source, path: s.filePath })),
      skillWarnings: skills.warnings.map(w => w.message),
      agents: agents.map(a => ({ name: a.name, source: a.source, path: a.filePath })),
    });
  } catch (e) { d = "PROBEERR " + String(e && e.stack || e); }
  pi.registerCommand("coexist-probe", { description: d, handler: async () => {} });
}
EOF
printf '%s\n' '{"id":"cmds","type":"get_available_commands"}' >"$root/rpc.in"
# rpc LABEL DIR [omp args]: one RPC session with the probe from DIR.
rpc() {
  local label=$1 dir=$2; shift 2
  stdin_file=$root/rpc.in
  o "$label" "$dir" --mode rpc --no-session --no-title --model omp-coexistence-null/null-model \
    -e "$root/probe.ts" "$@"
  stdin_file=/dev/null
  assert_rc 0 "$label rpc"
  has "$label" '"command":"get_available_commands","success":true'
}

cat >"$root/checks.py" <<'PY'
"""Assertions over the coexistence probe (omp's own loaders) and the install outputs."""
import json
import sys
from collections import Counter
from pathlib import Path


def fail(message):
    print(f"checks: {message}", file=sys.stderr)
    sys.exit(1)


def probe(path):
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        try:
            frame = json.loads(line)
        except ValueError:
            continue
        if frame.get("command") == "get_available_commands" and frame.get("success"):
            commands = frame["data"]["commands"]
            text = next((c.get("description", "") for c in commands if c.get("name") == "coexist-probe"), "")
            if not text.startswith("PROBE "):
                fail(f"{path}: probe failed: {text[:600]}")
            return json.loads(text[6:]), [c["name"] for c in commands]
    fail(f"{path}: no get_available_commands response")


def ycc_commands(commands):
    return [name for name in commands if name.startswith("ycc:")]


def aliases(data, *namespaces):
    return sorted(s["name"] for s in data["skills"] if s["name"].split("/", 1)[0] in namespaces and "/" in s["name"])


def connection(item):
    return json.dumps([item.get("url"), item.get("headers"), item.get("command"), item.get("args")], sort_keys=True)


def counts(path, skills, commands, agents, mcp):
    """C1: exactly the ycc package set, nothing aliased, warned or shadowed."""
    data, names = probe(path)
    got = (len(data["skills"]), len(ycc_commands(names)), len(data["agents"]))
    if got != (int(skills), int(commands), int(agents)):
        fail(f"{path}: skills/ycc: commands/agents {got}, expected {(skills, commands, agents)}")
    if [s for s in data["skills"] if "/" in s["name"]] or data["skillWarnings"]:
        fail(f"{path}: aliases or warnings: {data['skillWarnings'][:3]}")
    mcps = data["caps"]["mcps"]
    ycc = [i["name"] for i in mcps["items"] if i["name"].startswith("ycc-mcp:")]
    if len(ycc) != int(mcp) or mcps["shadowed"]:
        fail(f"{path}: ycc-mcp servers {ycc}, shadowed {mcps['shadowed']}")
    return f"{got[0]} skills, {got[1]} ycc: commands, {got[2]} agents, {len(ycc)} ycc-mcp servers, 0 shadowed"


def aliased(path):
    """Before dedupe: the agents/<name> alias count, one collision warning each."""
    data, _ = probe(path)
    found = aliases(data, "agents")
    if not found or len(data["skillWarnings"]) != len(found):
        fail(f"{path}: {len(found)} agents/ aliases vs {len(data['skillWarnings'])} warnings")
    print(len(found))
    sys.exit(0)


def deduped(path, skills):
    """C2: the ycc package set again, no agents/ alias, no warning."""
    data, names = probe(path)
    if len(data["skills"]) != int(skills) or aliases(data, "agents") or data["skillWarnings"]:
        fail(f"{path}: {len(data['skills'])} skills, aliases {aliases(data, 'agents')[:3]}, {data['skillWarnings'][:2]}")
    return f"{len(data['skills'])} skills, 0 agents/ aliases, 0 collision warnings, {len(ycc_commands(names))} ycc: commands"


def omp_cache(path, skills, commands):
    """C3: every skill, command and agent from the omp cache; the Claude registry copy drops."""
    data, names = probe(path)
    foreign = [s["path"] for s in data["skills"] + data["agents"] if "/.claude/plugins/" in s["path"]]
    if foreign or len(data["skills"]) != int(skills) or len(ycc_commands(names)) != int(commands):
        fail(f"{path}: Claude registry copies loaded: {foreign[:3]} ({len(data['skills'])} skills)")
    return f"{len(data['skills'])} skills and {len(data['agents'])} agents, all from the omp cache; the Claude ycc@ycc copy is dropped"


def mixed(path, shipped, agents):
    """C4: opt-in imports: each MCP connection once, one context file, documented winners."""
    data, names = probe(path)
    leftover = aliases(data, "agents", "codex", "opencode")
    if leftover:
        fail(f"{path}: dedupe left {leftover[:5]}")
    by_name = {s["name"]: s for s in data["skills"]}
    if "/.claude/skills/" not in by_name.get("plan", {}).get("path", "") or "ycc/plan" not in by_name:
        fail(f"{path}: expected bare plan from ~/.claude/skills and ycc/plan: {by_name.get('plan')}")
    if any('available as "ycc/' not in w for w in data["skillWarnings"]):
        fail(f"{path}: unexpected warnings {[w for w in data['skillWarnings'] if 'ycc/' not in w][:3]}")
    if len(data["agents"]) != int(agents) or any("/plugins/cache/" not in a["path"] for a in data["agents"]):
        fail(f"{path}: agents not exactly the ycc package set: {len(data['agents'])}")
    contexts = data["caps"]["context-files"]["items"]
    if len([c for c in contexts if c.get("level") == "user"]) != 1 or contexts[0]["provider"] != "native":
        fail(f"{path}: context files {contexts}")
    winners = data["caps"]["mcps"]["items"]
    dupes = [k for k, n in Counter(connection(i) for i in winners).items() if n > 1]
    servers = json.loads(Path(shipped).read_text(encoding="utf-8"))["mcpServers"]
    keys = {connection(i) for i in winners}
    missing = [n for n, s in servers.items() if connection(s) not in keys]
    if dupes or missing:
        fail(f"{path}: duplicate MCP connections {dupes[:2]}, missing {missing}")
    providers = Counter(i["provider"] for i in winners)
    return (f"no agents/codex/opencode alias; bare plan from ~/.claude/skills (ycc/plan kept); {len(data['agents'])} "
            f"agents only from ycc; 1 context file (native); {len(winners)} MCP winners, each connection once "
            f"({dict(providers)})")


def project(path, root):
    data, _ = probe(path)
    plan = next((s for s in data["skills"] if s["name"] == "plan"), None)
    if plan is None or not plan["source"].startswith("native") or not plan["path"].startswith(root):
        fail(f"{path}: bare plan is {plan}")
    if not any(s["name"] == "ycc/plan" for s in data["skills"]):
        fail(f"{path}: the package plan should be ycc/plan")
    return f"bare plan from {plan['source']} ({plan['path']}); the package copy is ycc/plan"


def shadowed(listing):
    items = [i for i in json.loads(Path(listing).read_text())["marketplace"] if i.get("id") == "ycc@ycc"]
    user = [i for i in items if i.get("scope") == "user"]
    if len(user) != 1 or user[0].get("shadowedBy") != "project":
        fail(f"{listing}: user ycc@ycc not shadowed by project: {items}")
    return "user ycc@ycc reports shadowedBy=project"


def no_ycc(path, skills):
    """C6/C8: no ycc at all; the ~/.agents copies load under their bare names."""
    data, names = probe(path)
    leaked = [s["path"] for s in data["skills"] + data["agents"] if "/plugins/cache/" in s["path"]]
    bare = [s for s in data["skills"] if s["source"].startswith("agents") and "/" not in s["name"]]
    if leaked or ycc_commands(names) or len(bare) != int(skills) or data["skillWarnings"]:
        fail(f"{path}: ycc leaked {leaked[:2]}, {len(ycc_commands(names))} ycc:, {len(bare)} bare agents skills")
    return f"no ycc skill, agent or ycc: command; {len(bare)} ~/.agents skills under bare names"


def trusted_safe(path, skills, commands):
    """C7 safe run: ycc still loads (the markers prove nothing from the project ran)."""
    data, names = probe(path)
    ycc = [i["name"] for i in data["caps"]["mcps"]["items"] if i["name"].startswith("ycc-mcp:")]
    if len(data["skills"]) != int(skills) or len(ycc_commands(names)) != int(commands) or not ycc:
        fail(f"{path}: {len(data['skills'])} skills, {len(ycc_commands(names))} ycc:, ycc-mcp {ycc}")
    return f"ycc still loads ({len(data['skills'])} skills, {len(ycc_commands(names))} ycc: commands, {len(ycc)} ycc-mcp servers)"


COMMANDS = {"counts": counts, "aliased": aliased, "deduped": deduped, "omp-cache": omp_cache, "mixed": mixed,
            "project": project, "shadowed": shadowed, "no-ycc": no_ycc, "safe": trusted_safe}
print(COMMANDS[sys.argv[1]](*sys.argv[2:]))
PY

o version "$root/work" --version
assert_rc 0 version
version_text=$(<"$root/logs/version.stdout")
pkg_skills=$(find "$repo/packages/omp/ycc/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d "[:space:]")
pkg_commands=$(find "$repo/packages/omp/ycc/commands" -maxdepth 1 -name '*.md' | wc -l | tr -d "[:space:]")
pkg_agents=$(find "$repo/packages/omp/ycc/agents" -maxdepth 1 -name '*.md' | wc -l | tr -d "[:space:]")
pkg_mcp=$("$python" -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["mcpServers"]))' \
  "$repo/packages/omp/ycc-mcp/.mcp.json")
agents_skills=$(find "$repo/.agents-plugin/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d "[:space:]")
log "omp: $version_text; checkout: $repo; sandbox=$sandbox; package: $pkg_skills skills, $pkg_commands commands, $pkg_agents agents, $pkg_mcp MCP servers"

# --- C1. OMP only -------------------------------------------------------------------------------
home=$(h)
mkdir -p "$home"
null_model "$(agent_dir)"
ycc c1-install "$home" install --target omp
has c1-install "installed (user)"
rpc c1-probe "$home"
check c1-proof counts "$root/logs/c1-probe.stdout" "$pkg_skills" "$pkg_commands" "$pkg_agents" "$pkg_mcp"
log "PASS C1 omp only: the ycc package set loads once"

# --- C2. agents target then omp: W5, W1, once-each ---------------------------------------------
w5='[!!] OMP also loads these skills; run ./install.sh install --target omp --only dedupe to hide the ~/.agents copies in OMP'
ycc c2-agents "$home" install --target agents
has c2-agents "$w5"
rpc c2-before "$home"
host c2-count "$python" "$root/checks.py" aliased "$root/logs/c2-before.stdout"
hidden=$(<"$root/logs/c2-count.stdout")
log "  before dedupe: $hidden agents/<name> aliases, $hidden collision warnings"
ycc c2-omp "$home" install --target omp
has c2-omp "[ok] OMP: hid $hidden ycc duplicate skills (agents/…) via skills.ignoredSkills in $(agent_dir)/config.yml; ./install.sh remove --target omp --only dedupe restores them"
rpc c2-probe "$home"
check c2-proof deduped "$root/logs/c2-probe.stdout" "$pkg_skills"
o c2-skill-list "$home" skill list
assert_rc 0 'omp skill list'
[[ ! -s "$root/logs/c2-skill-list.stderr" ]] || die "c2: omp skill list stderr is not empty: $(head -c 400 "$root/logs/c2-skill-list.stderr")"
lacks c2-skill-list 'agents/'
log "PASS C2 agents then omp: W5 then W1 (hid $hidden); $pkg_skills skills, no agents/ alias, omp skill list stderr empty"

# --- C3. A Claude marketplace ycc@ycc copy never duplicates ----------------------------------
claude_cache=$home/.claude/plugins/cache/ycc
mkdir -p "$claude_cache/ycc" "$claude_cache/ycc-mcp"
host c3-copy cp -R "$repo/ycc" "$claude_cache/ycc/6.0.0"
host c3-copy-mcp cp -R "$repo/packages/claude/ycc-mcp" "$claude_cache/ycc-mcp/6.0.0"
"$python" - "$home/.claude/plugins/installed_plugins.json" "$claude_cache" <<'PY'
import json, sys
cache = sys.argv[2]
entries = {f"{n}@ycc": [{"scope": "user", "installPath": f"{cache}/{n}/6.0.0", "version": "6.0.0"}] for n in ("ycc", "ycc-mcp")}
json.dump({"version": 2, "plugins": entries}, open(sys.argv[1], "w"))
PY
o c3-enable "$home" config set enabledProviders '["claude"]'
assert_rc 0 'config set enabledProviders [claude]'
rpc c3-probe "$home"
check c3-proof omp-cache "$root/logs/c3-probe.stdout" "$pkg_skills" "$pkg_commands"
log 'PASS C3 Claude registry ycc@ycc (enabledProviders [claude]): no duplicate; OMP registry wins per plugin id'
rm -rf -- "$home/.claude/plugins"

# --- C4. enabledProviders ["*"] with every other runtime's files ---------------------------------
for slice in claude:skills claude:agents codex:skills codex:agents opencode:skills opencode:agents \
  opencode:commands cursor:skills cursor:agents cursor:commands; do
  run "c4-slice-${slice/:/-}" "$home" "$python" "$repo/scripts/install_slices.py" install \
    --target "${slice%%:*}" --slice "${slice##*:}"
  assert_rc 0 "install_slices $slice"
done
"$python" - "$repo/mcp-configs/mcp.json" "$home" <<'PY'
import json, sys
from pathlib import Path
servers = json.loads(Path(sys.argv[1]).read_text())["mcpServers"]
home = Path(sys.argv[2])
(home / ".claude.json").write_text(json.dumps({"mcpServers": servers}))
(home / ".cursor").mkdir(exist_ok=True)
(home / ".cursor/mcp.json").write_text(json.dumps({"mcpServers": servers}))
toml = "".join(f'[mcp_servers.{json.dumps(n)}]\nurl = {json.dumps(s["url"])}\n\n' for n, s in servers.items() if "url" in s)
(home / ".codex").mkdir(exist_ok=True)
(home / ".codex/config.toml").write_text(toml)
PY
mkdir -p "$home/.claude" "$home/.codex" "$home/.config/opencode"
cp "$repo/ycc/settings/rules/CLAUDE.md" "$home/.claude/CLAUDE.md"
cp "$repo/ycc/settings/rules/AGENTS.md" "$home/.codex/AGENTS.md"
cp "$repo/ycc/settings/rules/AGENTS.md" "$home/.config/opencode/AGENTS.md"
ycc c4-rules "$home" install --target omp --only rules
o c4-enable "$home" config set enabledProviders '["*"]'
assert_rc 0 'config set enabledProviders [*]'
ycc c4-dedupe "$home" install --target omp --only dedupe
has c4-dedupe '[ok] OMP: hid ' 'agents/…, codex/…, opencode/…' \
  '[!!] enabledProviders includes claude: ' \
  'ycc skills in ~/.claude/skills outrank the OMP package (it shows as ycc/<name>); retire them with ./install.sh sync --target claude --intent base (its legacy cleanup removes ycc-owned ~/.claude/skills copies), or drop claude from enabledProviders'
rpc c4-probe "$home"
check c4-proof mixed "$root/logs/c4-probe.stdout" "$repo/packages/omp/ycc-mcp/.mcp.json" "$pkg_agents"
log 'PASS C4 enabledProviders ["*"]: W4 + W1 (agents/codex/opencode); precedence as documented'

# --- Case B: a fresh home for project, profile, trust and restore ---------------------------
case_home=$root/b
home=$(h)
mkdir -p "$home"
null_model "$(agent_dir)"
ycc b-agents "$home" install --target agents
printf 'skills:\n  ignoredSkills:\n  - my-*\n' >"$(agent_dir)/config.yml"
before=$(sha256sum "$(agent_dir)/config.yml" | cut -d' ' -f1)
ycc b-omp "$home" install --target omp
has b-omp '[ok] OMP: hid '

# --- C5. Project install + project .omp/skills/plan --------------------------------------------
proj=$home/proj
mkdir -p "$proj/.omp/skills/plan"
printf -- '---\nname: plan\ndescription: project-local plan\n---\nproject plan\n' >"$proj/.omp/skills/plan/SKILL.md"
run c5-git "$proj" git init -q
assert_rc 0 'git init'
ycc c5-install "$proj" install --target omp --project
has c5-install 'installed (project)' 'a project install shadows your user install here'
rpc c5-probe "$proj"
check c5-proof project "$root/logs/c5-probe.stdout" "$proj"
o c5-list "$proj" plugin list --json
assert_rc 0 'plugin list --json (project)'
check c5-shadow shadowed "$root/logs/c5-list.stdout"
log 'PASS C5 project: native project skill keeps the bare name; the user install is shadowed by the project install'

# --- C6. Another profile sees no ycc --------------------------------------------------------
extra_env=(OMP_PROFILE=work)
o c6-path "$home" config path
assert_rc 0 'config path (work)'
null_model "$(<"$root/logs/c6-path.stdout")"
rpc c6-probe "$home"
extra_env=()
check c6-proof no-ycc "$root/logs/c6-probe.stdout" "$agents_skills"
log 'PASS C6 OMP_PROFILE=work: plugins are per profile; only the shared ~/.agents skills load'

# --- C7. Hostile project ----------------------------------------------------------------------
evil=$home/evil
marks=$root/markers
mkdir -p "$evil/.claude/hooks/pre" "$evil/.omp/extensions" "$evil/plugin/.claude-plugin" "$evil/.omp/plugins"
marker_ts() { printf 'import { writeFileSync } from "node:fs";\nwriteFileSync(%s, "ran");\nexport default function () {}\n' "\"$marks/$1\""; }
marker_ts hook >"$evil/.claude/hooks/pre/bash.ts"
marker_ts extension >"$evil/.omp/extensions/x.ts"
marker_ts config-extension >"$evil/cfg-ext.ts"
stub() { printf '{"command":"sh","args":["-c","echo ran > %s; exec sleep 20"]}' "$marks/$1"; }
printf '{"mcpServers":{"projstub":%s}}\n' "$(stub mcp)" >"$evil/.mcp.json"
printf '{"mcpServers":{"pluginstub":%s}}\n' "$(stub plugin-mcp)" >"$evil/plugin/.mcp.json"
printf '{"name":"evil","version":"1.0.0","description":"fixture"}\n' >"$evil/plugin/.claude-plugin/plugin.json"
printf '{"version":2,"plugins":{"evil@local":[{"scope":"project","installPath":"%s","version":"1.0.0"}]}}\n' \
  "$evil/plugin" >"$evil/.omp/plugins/installed_plugins.json"
printf 'extensions:\n  - %s\n' "$evil/cfg-ext.ts" >"$evil/.omp/config.yml"
run c7-git "$evil" git init -q
assert_rc 0 'git init (evil)'
all_marks=(hook extension config-extension mcp plugin-mcp)
rpc c7-default "$evil"
sleep 2
for m in "${all_marks[@]}"; do
  [[ -e "$marks/$m" ]] || die "c7: the default session did not run the project $m (fixture not live?)"
done
log "  default session ran every project resource: ${all_marks[*]}"
rm -f -- "$marks"/*
printf 'mcp:\n  enableProjectConfig: false\n' >"$root/untrusted.yml"
rpc c7-safe "$evil" --no-extensions --config "$root/untrusted.yml"
sleep 2
leaked=$(find "$marks" -type f 2>/dev/null | sed 's#.*/##' | tr '\n' ' ')
[[ -z "$leaked" ]] || die "c7: --no-extensions --config <overlay> still ran: $leaked"
check c7-proof safe "$root/logs/c7-safe.stdout" "$pkg_skills" "$pkg_commands"
log 'PASS C7 hostile project: every marker by default; none under omp --no-extensions --config <mcp.enableProjectConfig: false>'

# --- C8. Remove restores the prior state --------------------------------------------------------
ycc c8-remove-project "$proj" remove --target omp --only base --project
has c8-remove-project 'omp: kept the skills.ignoredSkills entries' "[ok] removed the empty omp project state under $proj/.omp"
[[ ! -e "$proj/.omp/plugins" ]] || die "c8: $proj/.omp/plugins remains: $(find "$proj/.omp/plugins")"
[[ -f "$proj/.omp/skills/plan/SKILL.md" ]] || die 'c8: remove --project deleted the user-authored project skill'
ycc c8-remove "$home" remove --target omp --only base
has c8-remove 'take back ycc skills.ignoredSkills entries'
after=$(sha256sum "$(agent_dir)/config.yml" | cut -d' ' -f1)
[[ "$after" == "$before" ]] || die "c8: config.yml differs from its pre-install bytes: $(cat "$(agent_dir)/config.yml")"
rpc c8-probe "$home"
check c8-proof no-ycc "$root/logs/c8-probe.stdout" "$agents_skills"
log 'PASS C8 remove: no .omp/plugins residue in the project; config.yml back to its pre-install bytes; ~/.agents skills bare again'

log "PASS all YAN-1176 OMP coexistence checks ($version_text, sandbox=$sandbox)"
