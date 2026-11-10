#!/usr/bin/env bash
# Opt-in, offline YAN-1123 live checks. No real auth, hooks, or inference.
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: test-codex-marketplace-spike.sh [--keep] [--output-dir DIR]

Requires CODEX_BIN (absolute executable path) or codex on PATH, version >=0.160.0,
plus git, python3, timeout, and standard Linux utilities. No inference.
--keep            Retain the sandbox (otherwise removed by EXIT trap).
--output-dir DIR  Existing parent under /tmp/opencode; implies --keep.
-h, --help        Show help. Default sandbox: mktemp under /tmp/opencode.

HTTPS-shaped .invalid URLs are rewritten to local file:// bare repos by isolated
Git configuration. GIT_ALLOW_PROTOCOL=file restricts Git transport to file://,
and the exercised CLI/RPC code paths require no network access (non-Git process
egress is not OS-sandboxed). Every command runs from an empty work directory
outside the repository.
EOF
}
# Emit a fatal error message to stderr and exit 1.
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
keep=0
parent=/tmp/opencode
while (($#)); do
  case "$1" in
    --keep) keep=1; shift ;;
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
codex=${CODEX_BIN:-$(command -v codex || true)}
[[ -n "$codex" && -x "$codex" ]] || die 'set CODEX_BIN or install codex on PATH'
codex=$(realpath -s "$codex")
[[ -d "$parent" ]] || die '--output-dir must exist (default /tmp/opencode)'
parent=$(realpath "$parent")
[[ "$parent" == /tmp/opencode || "$parent" == /tmp/opencode/* ]] || die 'output must be under /tmp/opencode'
root=$(mktemp -d "$parent/codex-marketplace-spike.XXXXXX")
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
mkdir -p "$root"/{work,tmp,bootstrap,logs}
cd "$root/work"
# An explicit safe PATH still permits a Node-backed Codex shim. No inherited env
# (including keys, proxies, SSH agents, Git settings, or Node preload options).
safe_path="$(dirname "$codex"):$(dirname "$(command -v node || command -v python3)"):/usr/local/bin:/usr/bin:/bin"
case_home=$root/bootstrap
bare=$root/fixture.git
bare2=$root/claude.git
url=https://codex-spike.invalid/fixture.git
url2=https://codex-spike.invalid/claude.git
# Run a command in an env -i sandbox with isolated HOME, CODEX_HOME, XDG, and file-only Git rewrites.
clean() {
  mkdir -p "$case_home"/{home,codex,config,data,state,cache,runtime}
  env -i PATH="$safe_path" LANG=C.UTF-8 TERM=dumb NO_COLOR=1 \
    HOME="$case_home/home" CODEX_HOME="$case_home/codex" \
    XDG_CONFIG_HOME="$case_home/config" XDG_DATA_HOME="$case_home/data" \
    XDG_STATE_HOME="$case_home/state" XDG_CACHE_HOME="$case_home/cache" \
    XDG_RUNTIME_DIR="$case_home/runtime" TMPDIR="$root/tmp" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    GIT_ALLOW_PROTOCOL=file GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
    GIT_CONFIG_KEY_1="url.file://$bare.insteadOf" GIT_CONFIG_VALUE_1="$url" \
    GIT_CONFIG_KEY_2="url.file://$bare2.insteadOf" GIT_CONFIG_VALUE_2="$url2" \
    "$@"
}
# No exec tee/process-substitution race: each command's sanitized output is
# appended synchronously, with argv and exit code. Only ephemeral paths exist.
# Write a status line to stdout and append it to the retained transcript.
log() { printf '%s\n' "$*" | tee -a "$root/transcript.log"; }
# Execute a command under timeout, sanitize sandbox paths/ANSI in logs, and record the result.
run() {
  local label=$1; shift
  local out="$root/logs/$label.stdout" err="$root/logs/$label.stderr"
  rc=0
  clean timeout -k 5 60 "$@" >"$out" 2>"$err" || rc=$?
  clean python3 - "$root" "$out" "$err" <<'PY'
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
  { printf '\n[%s] argv:' "$label"; printf ' %q' "$@"; printf '\nexit=%s\nstdout:\n' "$rc"
    # These are capture files, not source code.
    cat "$out"; printf '\nstderr:\n'; cat "$err"; printf '\n'
  } >>"$root/transcript.log"
}
# Assert that the most recent run() call returned the expected exit status.
assert_rc() { [[ "$rc" == "$1" ]] || die "$2: expected rc=$1, got $rc (see $root/transcript.log)"; }
run version "$codex" --version
assert_rc 0 version
version=$(<"$root/logs/version.stdout")
clean python3 - "$version" <<'PY'
import re
import sys
match = re.fullmatch(r"codex-cli (\d+)\.(\d+)\.(\d+)\s*", sys.argv[1])
if not match or tuple(map(int, match.groups())) < (0, 160, 0):
    raise SystemExit("Codex >=0.160.0 (stable version string) required")
PY
log "YAN-1123 | $version | offline Git fixture | $(date -u +%F)"
for help in plugin 'plugin marketplace add' debug; do
  read -r -a args <<<"$help"
  run "help-${args[0]}-${args[1]:-root}" "$codex" "${args[@]}" --help
  assert_rc 0 "$help help"
done

# Minimal plugin manifest based on .codex-plugin/ycc/.codex-plugin/plugin.json.
# Both catalogs use distinct names AND distinct marker bytes.
src=$root/source
mkdir -p "$src/.agents/plugins" "$src/.claude-plugin"
clean python3 - "$src" <<'PY'
import json
import sys
from pathlib import Path
src = Path(sys.argv[1])
for kind, path in (("native", ".codex-plugin/native"), ("claude", "claude-plugin-payload")):
    p = src / path
    (p / ".codex-plugin").mkdir(parents=True)
    (p / "skills/marker").mkdir(parents=True)
    (p / "hooks").mkdir()
    (p / ".codex-plugin/plugin.json").write_text(json.dumps({
        "name": kind + "-plugin", "version": "0.0.1", "description": "Offline spike",
        "skills": "./skills/"}))
    (p / "skills/marker/SKILL.md").write_text(
        "---\nname: marker\ndescription: Offline spike marker\n---\n" + kind.upper() + "-MARKER\n")
    # Recording/no-op only. Listing never dispatches these commands. No ycc hooks.
    (p / "hooks/hooks.json").write_text(json.dumps({"hooks": {
        "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "printf 'session-start\\n'"}]}],
        "WorktreeCreate": [{"hooks": [{"type": "command", "command": "printf 'worktree-create\\n'"}]}]}}))
(src / ".agents/plugins/marketplace.json").write_text(json.dumps({
    "name": "spike-native", "plugins": [{"name": "native-plugin",
    "source": {"source": "local", "path": "./.codex-plugin/native"}}]}))
(src / ".claude-plugin/marketplace.json").write_text(json.dumps({
    "name": "spike-claude", "owner": {"name": "spike"},
    "plugins": [{"name": "claude-plugin", "source": "./claude-plugin-payload"}]}))
PY
# Initialize a fixture source tree, create an unsigned commit, and clone it into a bare repo.
fixture_commit() {
  clean git -C "$1" init -q -b fixture
  clean git -C "$1" add -A
  clean git -C "$1" -c user.name=spike -c user.email=spike@localhost \
    -c commit.gpgsign=false commit -qm 'immutable offline fixture'
  clean git clone -q --bare "$1" "$2"
}
fixture_commit "$src" "$bare"
commit=$(clean git -C "$src" rev-parse HEAD)
mkdir -p "$root/claude-source/.claude-plugin"
cp "$src/.claude-plugin/marketplace.json" "$root/claude-source/.claude-plugin/"
cp -R "$src/claude-plugin-payload" "$root/claude-source/"
fixture_commit "$root/claude-source" "$bare2"
commit2=$(clean git -C "$root/claude-source" rev-parse HEAD)
log "Immutable fixture commits: dual=$commit claude-only=$commit2"

# Explicit negative control: marketplace URL parser does NOT accept file://.
run file-url "$codex" plugin marketplace add "file://$bare" --json
assert_rc 1 file-url
grep -q 'invalid marketplace source format' "$root/logs/file-url.stderr" || die 'unexpected file:// failure'
log 'PASS file:// marketplace URL rejected; HTTPS-shaped alias uses file-only Git transport'

# Run one marketplace discovery/list/install test case and verify the installed cache marker.
matrix_case() {
  local name=$1 source=$2 ref=$3 market=$4 plugin=$5 expected=$6 marker=$7; shift 7
  case_home=$root/$name
  run "$name-add" "$codex" plugin marketplace add "$source" --ref "$ref" "$@" --json
  assert_rc 0 "$name marketplace add"
  run "$name-markets" "$codex" plugin marketplace list --json
  assert_rc 0 "$name marketplace list"
  run "$name-list" "$codex" plugin list --available --json
  assert_rc 0 "$name list"
  clean python3 - "$root/logs/$name-add.stdout" "$root/logs/$name-list.stdout" "$market" "$plugin" <<'PY'
import json
import sys
add, listing, market, plugin = sys.argv[1:]
assert json.load(open(add))["marketplaceName"] == market
items = json.load(open(listing))["available"]
assert len(items) == 1, items
assert items[0]["pluginId"] == f"{plugin}@{market}", items
PY
  run "$name-install" "$codex" plugin add "$plugin@$market" --json
  assert_rc "$expected" "$name install"
  if [[ "$expected" == 1 ]]; then
    grep -Eq 'plugin source path is not a directory|missing plugin.json' "$root/logs/$name-install.stderr" || die 'unexpected install failure'
    [[ ! -d "$case_home/codex/plugins/cache/$market/$plugin" ]] || die 'failed install left cache payload'
    log "PASS $name | selected=$market | available=$plugin | install=1 (expected missing sparse payload) | marker=absent"
  else
    local installed="$case_home/codex/plugins/cache/$market/$plugin/0.0.1"
    clean python3 - "$installed" "$root/source/$marker/skills/marker/SKILL.md" >>"$root/transcript.log" <<'PY'
import hashlib
import sys
from pathlib import Path
installed, original = map(Path, sys.argv[1:])
a = (installed / "skills/marker/SKILL.md").read_bytes()
assert a == original.read_bytes(), "cache marker mismatch"
print("Installed cache marker:", a.decode().splitlines()[-1], "sha256=" + hashlib.sha256(a).hexdigest())
PY
    log "PASS $name | selected=$market | available=$plugin | install=0 | cache marker/hash verified"
  fi
}
matrix_case full "$url" "$commit" spike-native native-plugin 0 .codex-plugin/native
matrix_case sparse-catalog "$url" "$commit" spike-native native-plugin 1 .codex-plugin/native --sparse .agents/plugins
matrix_case sparse-payload "$url" "$commit" spike-native native-plugin 0 .codex-plugin/native --sparse .agents/plugins --sparse .codex-plugin/native
matrix_case claude-only "$url2" "$commit2" spike-claude claude-plugin 0 claude-plugin-payload

# Additional git-subdir control uses an HTTPS-shaped catalog entry; the
# file-only Git transport rewrite means this exercised path needs no network.
mkdir -p "$root/subdir-catalog/.agents/plugins"
clean python3 - "$root/subdir-catalog/.agents/plugins/marketplace.json" "$url" "$commit" <<'PY'
import json
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({"name": "spike-subdir", "plugins": [{
    "name": "native-plugin", "source": {"source": "git-subdir", "url": sys.argv[2],
    "path": "./.codex-plugin/native", "ref": sys.argv[3]}}]}))
PY
# --ref on a local catalog is rejected, so this control is separate.
case_home=$root/git-subdir
run subdir-add "$codex" plugin marketplace add "$root/subdir-catalog" --json
assert_rc 0 subdir-add
run subdir-markets "$codex" plugin marketplace list --json
assert_rc 0 subdir-markets
run subdir-list "$codex" plugin list --available --json
assert_rc 0 subdir-list
run subdir-install "$codex" plugin add native-plugin@spike-subdir --json
assert_rc 0 subdir-install
clean python3 - "$case_home/codex/plugins/cache/spike-subdir/native-plugin/0.0.1/skills/marker/SKILL.md" "$src/.codex-plugin/native/skills/marker/SKILL.md" >>"$root/transcript.log" <<'PY'
import hashlib
import sys
from pathlib import Path
a, b = (Path(p).read_bytes() for p in sys.argv[1:])
assert a == b
print("git-subdir installed cache marker sha256=" + hashlib.sha256(a).hexdigest())
PY
log 'PASS git-subdir | selected=spike-subdir | available=native-plugin | install=0 | cache marker/hash verified'

# Generate schema offline; hooks/list is metadata, NOT hook dispatch/trust grant.
case_home=$root/full
run features "$codex" features list
assert_rc 0 features
# Version-specific expectations for codex-cli 0.161.x; a change here is a signal
# to revisit the hook decision, not necessarily a harness bug.
grep -Eq '^plugin_hooks[[:space:]]+removed[[:space:]]+false$' "$root/logs/features.stdout" ||
  die 'features: expected plugin_hooks removed false (version-specific)'
grep -Eq '^hooks[[:space:]]+stable[[:space:]]+true$' "$root/logs/features.stdout" ||
  die 'features: expected hooks stable true (version-specific)'
run schema-help "$codex" app-server generate-json-schema --help
assert_rc 0 schema-help
run schema "$codex" app-server generate-json-schema --experimental --out "$root/schema"
assert_rc 0 schema
clean python3 - "$root/schema/v2/HooksListResponse.json" >>"$root/transcript.log" <<'PY'
import json
import sys
d = json.load(open(sys.argv[1]))["definitions"]
events = d["HookEventName"]["enum"]
assert "sessionStart" in events and "worktreeCreate" not in events, events
print("Installed CLI HookEventName enum:", ", ".join(events))
print("Installed CLI HookTrustStatus enum:", d["HookTrustStatus"]["enum"])
PY
# Bounded app-server stdio client: initialize + hooks/list only; no sessions or
# turns created, no auth loaded, no inference, no command dispatch requested.
clean timeout -k 5 30 python3 - "$codex" "$root/work" "$root/logs/hooks-rpc.json" "$root/logs/hooks-rpc.stderr" <<'PY'
import json
import subprocess
import sys
binary, cwd, output, stderr = sys.argv[1:]
with open(stderr, "w") as err:
    p = subprocess.Popen([binary, "app-server", "--stdio"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=err, text=True)
    def request(payload):
        """Send a JSON-RPC request over stdio and return the matching response."""
        p.stdin.write(json.dumps(payload) + "\n")
        p.stdin.flush()
        while line := p.stdout.readline():
            message = json.loads(line)
            if message.get("id") == payload["id"]:
                assert "error" not in message, message
                return message
        raise RuntimeError("app-server closed before responding")
    try:
        init = request({"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "yan1123-spike", "version": "0"}}})
        p.stdin.write('{"method":"initialized"}\n')
        p.stdin.flush()
        result = request({"id": 2, "method": "hooks/list", "params": {"cwds": [cwd]}})
        entries = result["result"]["data"]
        hooks = [h for entry in entries for h in entry["hooks"]]
        assert len(hooks) == 1, hooks
        h = hooks[0]
        assert h["eventName"] == "sessionStart" and h["source"] == "plugin", h
        assert h["trustStatus"] == "untrusted" and h["currentHash"].startswith("sha256:"), h
        with open(output, "w") as handle:
            json.dump({"initialize": init, "hooks/list": result}, handle, indent=2)
    finally:
        p.terminate()
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
PY
# Sanitize RPC evidence just like command output, without rewriting cache data.
clean python3 - "$root" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
with (root / "transcript.log").open("a") as out:
    for name in ("hooks-rpc.json", "hooks-rpc.stderr"):
        path = root / "logs" / name
        text = path.read_text(errors="replace").replace(str(root), "<SANDBOX>")
        path.write_text(text)
        out.write("\n" + name + " (RPC client exit=0):\n" + text + "\n")
PY
log 'PASS hooks metadata | SessionStart discovered untrusted + sha256 | WorktreeCreate absent'
log 'NO-GO hooks runtime: trust grant and trusted/untrusted dispatch unverified; no inference/session started'
log 'PASS: 5 marketplace matrix cases + file:// rejection + installed hook schema/discovery'
log "Transcript: $root/transcript.log"
