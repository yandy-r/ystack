#!/usr/bin/env bash
# Opt-in live checks for the OMP ycc-rules package and the opt-in --settings merge (YAN-1175).
# Not part of CI. No credentials, no network inside the sandbox, no model inference.
# shellcheck disable=SC2154 # omp_in_dir comes from lib/omp-harness-common.sh
set -euo pipefail
umask 077
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/omp-harness-common.sh"

usage() {
  cat <<'EOF'
Usage: test-omp-rules-settings.sh [--keep] [--allow-env-i]

Requires omp >=18.12.2 (OMP_BIN overrides PATH; default ~/.local/bin/omp) and python3 with
PyYAML and the repository's generator dependencies; without either the harness prints SKIP
and exits 0. Also needs timeout, realpath and bubblewrap with a working --unshare-net.

Every command runs under env -i with HOME/XDG/TMPDIR inside a mktemp sandbox under /tmp and
PATH=<sandbox>/bin:/usr/local/bin:/usr/bin:/bin (<sandbox>/bin/omp links to OMP_BIN), and
under bwrap with a private network namespace, the real home hidden behind a tmpfs, and this
checkout bind-mounted read-only. Without bwrap the harness refuses to run unless
--allow-env-i accepts the weaker env -i sandbox. The only reachable model is a null provider
on 127.0.0.1:9 (spike-null/null-model, spike-null/null-two); no prompt is ever sent. RPC
sessions (omp --mode rpc --no-session --no-title) are read through get_state.

L1  --plugin-dir packages/omp/ycc-rules: <generic-rules> holds the ycc-common-security and
    ycc-common-git-workflow bodies, <domain-rules> lists every other rule (Go globs shown)
    except the ycc-<family>-trigger TTSR rules, no hooks rule; after ./install.sh install
    --target omp --settings the same rules load from the installed ycc-rules@ycc export with
    no --plugin-dir.
L1T omp ttsr test -r ycc-python-trigger.md: fires on edit/write of *.py, not on a *.go path,
    the read tool or assistant text.
L2  A project <cwd>/.omp/rules/ycc-common-security.md replaces the package body at that cwd;
    the package body returns from a subdirectory.
L3  install --target omp --settings (YCC_INSTALL_SKIP_BUILD=1, YCC_MANAGED_CONFIG_STATE in the
    sandbox): omp config get shows the managed modelRoles, retry.fallbackChains and
    tools.approvalMode, a seeded user key survives; an edited modelRoles.slow survives a re-run.
L4  A project .omp/config.yml (modelRoles.default: spike-null/null-two, tools.approvalMode:
    always-ask) beats the managed user values; both revert from a non-project cwd.
--keep    Retain the sandbox and transcript (always retained when a check fails).
EOF
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
skip() { printf 'SKIP: %s\n' "$*"; exit 0; }
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

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
omp=${OMP_BIN:-$HOME/.local/bin/omp}
[[ -x "$omp" ]] || omp=$(command -v omp || true)
[[ -n "$omp" && -x "$omp" ]] || skip 'omp not found (set OMP_BIN or install omp on PATH); opt-in live harness not run'
python=$(command -v python3 || true)
[[ -n "$python" ]] || skip 'python3 not found; opt-in live harness not run'
"$python" -c 'import yaml' 2>/dev/null || skip 'python3 has no PyYAML; opt-in live harness not run'
for tool in timeout mktemp realpath; do
  command -v "$tool" >/dev/null || die "missing prerequisite: $tool"
done
omp_h_require_gnu_tools
omp=$(realpath "$omp")
rules_pkg=$repo/packages/omp/ycc-rules
[[ -d "$rules_pkg/rules" ]] || die "$rules_pkg/rules is missing; run ./scripts/sync.sh first"
real_home=$(realpath "${HOME:?HOME must be set}")
root=$(omp_h_mktemp_root omp-rules-settings)
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
mkdir -p "$root"/{work,tmp,logs,bin}
ln -s "$omp" "$root/bin/omp"
umask 022
cd "$root/work"
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

case_home=$root/case
home=$(realpath -m "$case_home/home")
agent_dir=$home/.omp/agent
managed_state=$case_home/config/ycc/managed-config-state.json
# Run a command with no inherited environment and an isolated HOME/XDG tree.
clean() {
  [[ "$home" == "$root"/* && "$home" != "$real_home" && "$home" != "$real_home"/* ]] ||
    die "refusing to run with HOME=$home outside $root"
  mkdir -p "$case_home"/{home,config,data,state,cache,runtime}
  chmod 0700 "$case_home/runtime"
  env -i PATH="$safe_path" LANG=C.UTF-8 TERM=dumb NO_COLOR=1 \
    HOME="$home" XDG_CONFIG_HOME="$case_home/config" XDG_DATA_HOME="$case_home/data" \
    XDG_STATE_HOME="$case_home/state" XDG_CACHE_HOME="$case_home/cache" \
    XDG_RUNTIME_DIR="$case_home/runtime" TMPDIR="$root/tmp" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false GIT_ALLOW_PROTOCOL=file \
    PYTHONDONTWRITEBYTECODE=1 YCC_INSTALL_SKIP_BUILD=1 YCC_MANAGED_CONFIG_STATE="$managed_state" \
    "$@"
}
# bwrap works on its own; a failure here is omp needing files the sandbox hides.
# Run the HOME guard once with stderr visible: the preflight below discards it.
clean true
clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 30 omp --version >/dev/null 2>&1 ||
  die "OMP_BIN ($omp) does not run inside the $sandbox sandbox: it must be a self-contained binary outside \$HOME's dependencies (env -i PATH=$safe_path, real home hidden)"
log() { printf '%s\n' "$*" | tee -a "$root/transcript.log"; }
rc=0
stdin_file=/dev/null
# Record argv, exit status and (sandbox-relative) output of one command in the transcript.
record() {
  local label=$1; shift
  {
    printf '\n[%s] argv:' "$label"; printf ' %q' "${@/#"$root"/<SANDBOX>}"
    printf '\nexit=%s\nstdout:\n' "$rc"; head -c 6000 "$root/logs/$label.stdout" | sed "s#$root#<SANDBOX>#g"
    printf '\nstderr:\n'; head -c 3000 "$root/logs/$label.stderr" | sed "s#$root#<SANDBOX>#g"; printf '\n'
  } >>"$root/transcript.log"
}
# Run under the sandbox from directory $2 and record. Callers assert the exit status.
run() {
  local label=$1 dir=$2; shift 2
  [[ ! -e "$root/logs/$label.stdout" ]] || die "duplicate label: $label"
  rc=0
  clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 180 "${omp_in_dir[@]}" "$dir" "$@" <"$stdin_file" \
    >"$root/logs/$label.stdout" 2>"$root/logs/$label.stderr" || rc=$?
  record "$label" "$@"
}
# o LABEL DIR ARGS: omp from DIR.  ycc LABEL DIR ARGS: this checkout's install.sh from DIR.
o() { local label=$1 dir=$2; shift 2; run "$label" "$dir" omp "$@"; }
ycc() { local label=$1 dir=$2; shift 2; run "$label" "$dir" "$repo/install.sh" "$@"; }
assert_rc() { [[ "$rc" == "$1" ]] || die "$2: expected rc=$1, got $rc (see $root/transcript.log)"; }
has() {
  local label=$1 tok; shift
  for tok in "$@"; do
    grep -qF -- "$tok" "$root/logs/$label.stdout" "$root/logs/$label.stderr" ||
      die "$label: expected output to contain '$tok' (see $root/transcript.log)"
  done
}
# check LABEL ARGS: a Python assertion over captured output; its one-line result is logged.
check() {
  local label=$1; shift
  [[ ! -e "$root/logs/$label.stdout" ]] || die "duplicate label: $label"
  rc=0
  clean timeout -k 5 60 "$python" "$root/checks.py" "$@" >"$root/logs/$label.stdout" 2>"$root/logs/$label.stderr" || rc=$?
  record "$label" "$python" checks.py "$@"
  ((rc == 0)) || { cat "$root/logs/$label.stderr" >&2; die "$label failed; see $root/transcript.log"; }
  log "  $(<"$root/logs/$label.stdout")"
}
# rpc LABEL DIR [ARGS]: one RPC session from DIR that answers get_state.
rpc() {
  local label=$1 dir=$2; shift 2
  printf '%s\n' '{"id":"state","type":"get_state"}' >"$root/tmp/$label.rpc.in"
  stdin_file="$root/tmp/$label.rpc.in"
  o "$label" "$dir" --mode rpc --no-session --no-title "$@"
  stdin_file=/dev/null
  assert_rc 0 "$label rpc"
  has "$label" '"command":"get_state","success":true'
}
state() { printf '%s/logs/%s.stdout' "$root" "$1"; }
# value LABEL EXPECTED: `omp config get <scalar>` printed exactly EXPECTED.
value() {
  local actual
  actual=$(tr -d '[:space:]' <"$root/logs/$1.stdout")
  [[ "$actual" == "$2" ]] || die "$1: expected '$2', got '$actual' (see $root/transcript.log)"
}

cat >"$root/checks.py" <<'PY'
"""Assertions over captured omp RPC get_state output, omp config get and the ycc rule files."""
import json
import re
import sys
from pathlib import Path

import yaml


def fail(message):
    print(f"checks: {message}", file=sys.stderr)
    sys.exit(1)


def get_state(path):
    for line in Path(path).read_text().splitlines():
        try:
            frame = json.loads(line)
        except json.JSONDecodeError:
            continue
        if frame.get("command") == "get_state" and frame.get("success"):
            return frame["data"]
    fail(f"{path}: no successful get_state response")


def prompt(path):
    value = get_state(path)["systemPrompt"]
    return "\n".join(value) if isinstance(value, list) else value


def block(text, tag):
    match = re.search(rf"<{tag}>(.*?)</{tag}>", text, re.S)
    return match.group(1) if match else ""


def rule_files(rules_dir):
    rules = {}
    for path in sorted(Path(rules_dir).glob("*.md")):
        _, front, body = path.read_text().split("---", 2)
        rules[path.stem] = (yaml.safe_load(front) or {}, body.strip())
    if not rules:
        fail(f"{rules_dir}: no rule files")
    return rules


def rules(state_path, rules_dir):
    """Every package rule loads: alwaysApply bodies in <generic-rules>, the rest listed in <domain-rules>;
    TTSR trigger rules (a `condition`) stay out of both."""
    text = prompt(state_path)
    generic, domain = block(text, "generic-rules"), block(text, "domain-rules")
    files = rule_files(rules_dir)
    if any("hooks" in name for name in files) or re.search(r"ycc-[a-z]+-hooks", text):
        fail("a hooks rule is shipped or loaded")
    for name in ("ycc-common-security", "ycc-common-git-workflow"):
        if name not in files or not files[name][0].get("alwaysApply"):
            fail(f"{name} is missing or not alwaysApply")
    always = sorted(name for name, (front, _) in files.items() if front.get("alwaysApply") is True)
    triggers = sorted(name for name, (front, _) in files.items() if "condition" in front)
    if triggers != [f"ycc-{f}-trigger" for f in ("golang", "python", "rust", "typescript", "web")]:
        fail(f"trigger rules {triggers}")
    if any(name in generic or name in domain for name in triggers):
        fail("a TTSR trigger rule leaked into <generic-rules> or <domain-rules>")
    for name in always:
        if files[name][1] not in generic:
            fail(f"<generic-rules> lacks the {name} body")
    listed = dict(re.findall(r"^- (ycc-[\w-]+) \(([^)]*)\):", domain, re.M))
    expected = sorted(set(files) - set(always) - set(triggers))
    if sorted(listed) != expected:
        fail(f"<domain-rules> lists {sorted(listed)}, expected {expected}")
    go = listed.get("ycc-golang-coding-style")
    if go != "**/*.go, **/go.mod, **/go.sum":
        fail(f"ycc-golang-coding-style globs {go!r}")
    return (f"{len(always)} always rules in <generic-rules> ({', '.join(always)}), "
            f"{len(listed)} in <domain-rules> incl. ycc-golang-coding-style ({go}), no hooks rule, "
            f"{len(triggers)} TTSR triggers kept out of the prompt")


def ttsr(path, name, expected):
    """`omp ttsr test --json` triggered NAME ('yes') or did not ('no')."""
    report = json.loads(Path(path).read_text())
    hit = name in {rule["name"] for rule in report["triggered"]}
    if hit != (expected == "yes"):
        fail(f"{name} triggered={hit} for source={report['source']} tool={report.get('tool')} "
             f"path={report.get('filePath')}, expected {expected}")
    return f"{name} {'fires' if hit else 'silent'} on {report['source']}:{report.get('tool')} {report.get('filePath')}"


def shadow(state_path, rules_dir, marker, shadowed):
    """MARKER replaces the package body of SHADOWED ('yes') or the package body is back ('no')."""
    text = prompt(state_path)
    generic = block(text, "generic-rules")
    files = rule_files(rules_dir)
    body = files["ycc-common-security"][1]
    other = files["ycc-common-git-workflow"][1]
    if other not in generic:
        fail("<generic-rules> lost the ycc-common-git-workflow body")
    if shadowed == "yes":
        if marker not in generic or body in text:
            fail(f"project rule did not replace the package body (marker={marker in generic}, package={body in text})")
        return f"project .omp/rules/ycc-common-security.md ({marker}) replaced the package body"
    if marker in text or body not in generic:
        fail(f"package body not restored (marker={marker in text}, package={body in generic})")
    return "package ycc-common-security body loaded, no project marker"


def model(state_path, expected, negate="no"):
    actual = get_state(state_path)["model"]
    selector = f"{actual.get('provider')}/{actual.get('id')}"
    if (selector == expected) == (negate == "yes"):
        fail(f"get_state.model {selector}, expected {'not ' if negate == 'yes' else ''}{expected}")
    return f"get_state.model {selector}"


def config(path, expected_json):
    actual = json.loads(Path(path).read_text())["value"]
    expected = json.loads(expected_json)
    if actual != expected:
        fail(f"{path}: config value {actual!r}, expected {expected!r}")
    return f"config {json.dumps(actual, sort_keys=True)}"


def roles(source, path, overrides_json="{}"):
    """omp config get modelRoles --json equals the managed source roles with OVERRIDES applied."""
    expected = dict(yaml.safe_load(Path(source).read_text())["modelRoles"])
    expected.update(json.loads(overrides_json))
    return config(path, json.dumps(expected))


def chains(source, path):
    """omp config get retry.fallbackChains --json equals the managed source chains."""
    return config(path, json.dumps(yaml.safe_load(Path(source).read_text())["retry"]["fallbackChains"]))


def edit(config_path, key, value):
    data = yaml.safe_load(Path(config_path).read_text())
    data["modelRoles"][key] = value
    Path(config_path).write_text(yaml.safe_dump(data, sort_keys=False))
    return f"edited modelRoles.{key} = {value} in config.yml"


def seeded(config_path):
    data = yaml.safe_load(Path(config_path).read_text())
    if data.get("mcp", {}).get("startupTimeoutMs") != 0:
        fail(f"{config_path}: seeded user key mcp.startupTimeoutMs lost: {data}")
    return "user key mcp.startupTimeoutMs: 0 kept"


def installed(list_path, *plugin_ids):
    found = {item.get("id") for item in json.loads(Path(list_path).read_text()).get("marketplace", [])}
    missing = sorted(set(plugin_ids) - found)
    if missing:
        fail(f"{list_path}: {missing} not installed (found {sorted(found)})")
    return f"installed {', '.join(plugin_ids)}"


COMMANDS = {
    "rules": rules, "shadow": shadow, "model": model, "config": config, "roles": roles,
    "chains": chains,
    "edit": edit, "seeded": seeded, "installed": installed, "ttsr": ttsr,
}
print(COMMANDS[sys.argv[1]](*sys.argv[2:]))
PY

o version "$root/work" --version
assert_rc 0 version
version_text=$(<"$root/logs/version.stdout")
"$python" - "$version_text" <<'PY' || die "omp >=18.12.2 required, got: $version_text"
import re, sys
match = re.search(r"(\d+)\.(\d+)\.(\d+)", sys.argv[1])
sys.exit(0 if match and tuple(map(int, match.groups())) >= (18, 12, 2) else 1)
PY
log "YAN-1175 | $version_text | sandbox=$sandbox | checkout $repo"

# Null model provider (two ids for L4) and no MCP startup wait; no prompt is ever sent.
mkdir -p "$agent_dir"
cat >"$agent_dir/models.yml" <<'EOF'
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
      - id: null-two
        name: Null Two
        api: openai-completions
        reasoning: false
        input: [text]
EOF
printf 'mcp:\n  startupTimeoutMs: 0\n' >"$agent_dir/config.yml"
null=(--model spike-null/null-model)
proj=$home/proj
mkdir -p "$proj/sub"
managed_src=$repo/ycc/settings/omp/config.yml

# --- L1. Package rules load from --plugin-dir --------------------------------------------
rpc l1-plugin-dir "$home" "${null[@]}" --plugin-dir "$rules_pkg"
check l1-proof rules "$(state l1-plugin-dir)" "$rules_pkg/rules"
log 'PASS L1 (plugin-dir): packages/omp/ycc-rules loads; alwaysApply bodies in <generic-rules>, the rest on demand in <domain-rules>'

# --- L1T. A trigger fires only on edit/write of a matching path (no model needed) -----------
trigger=$rules_pkg/rules/ycc-python-trigger.md
for probe in edit:src/x.py:yes write:a/b/x.pyi:yes edit:src/x.go:no read:src/x.py:no; do
  IFS=: read -r tool path want <<<"$probe"
  o "l1t-$tool-${path//\//_}" "$home" ttsr test --json -r "$trigger" --source tool --tool "$tool" --path "$path" 'x = 1'
  assert_rc 0 "ttsr test $probe"
  check "l1t-$tool-${path//\//_}-proof" ttsr "$(state "l1t-$tool-${path//\//_}")" ycc-python-trigger "$want"
done
o l1t-text "$home" ttsr test --json -r "$trigger" --source text --path src/x.py 'x = 1'
assert_rc 0 'ttsr test text'
check l1t-text-proof ttsr "$(state l1t-text)" ycc-python-trigger no
log 'PASS L1T: ycc-python-trigger fires on edit/write of *.py/*.pyi only'

# --- L2. A project rule shadows the package rule at its cwd only ------------------------------
mkdir -p "$proj/.omp/rules"
cat >"$proj/.omp/rules/ycc-common-security.md" <<'EOF'
---
description: Project security override.
alwaysApply: true
---

PROJSECMARK project security override.
EOF
rpc l2-project "$proj" "${null[@]}" --plugin-dir "$rules_pkg"
check l2-shadow shadow "$(state l2-project)" "$rules_pkg/rules" PROJSECMARK yes
rpc l2-subdir "$proj/sub" "${null[@]}" --plugin-dir "$rules_pkg"
check l2-restored shadow "$(state l2-subdir)" "$rules_pkg/rules" PROJSECMARK no
rm -rf -- "$proj/.omp/rules"
log 'PASS L2: project .omp/rules/ycc-common-security.md wins at its cwd; the package body returns from a subdirectory'

# --- L3. install --target omp --settings: managed values, installed rules, local edit kept ---
ycc l3-install "$home" install --target omp --settings --global
assert_rc 0 'install --target omp --settings'
has l3-install '[ok] ycc-rules@ycc' 'rules apply to new sessions (/new or restart)' \
  "omp: merge ycc settings into $agent_dir/config.yml (user scope)"
[[ -f "$managed_state" ]] || die "install recorded no managed-config state at $managed_state"
o l3-list "$home" plugin list --json
assert_rc 0 'plugin list --json'
check l3-installed installed "$(state l3-list)" ycc@ycc ycc-mcp@ycc ycc-rules@ycc
rpc l3-installed-rules "$home" "${null[@]}"
check l3-installed-proof rules "$(state l3-installed-rules)" "$rules_pkg/rules"
log 'PASS L1 (install): ./install.sh install --target omp loads the same rules from the installed ycc-rules@ycc export (no --plugin-dir)'
o l3-roles "$home" config get modelRoles --json
assert_rc 0 'config get modelRoles'
check l3-roles-proof roles "$managed_src" "$(state l3-roles)"
o l3-chains "$home" config get retry.fallbackChains --json
assert_rc 0 'config get retry.fallbackChains'
check l3-chains-proof chains "$managed_src" "$(state l3-chains)"
o l3-approval "$home" config get tools.approvalMode
assert_rc 0 'config get tools.approvalMode'
value l3-approval write
check l3-seeded seeded "$agent_dir/config.yml"
log '  config get tools.approvalMode: write'
check l3-edit edit "$agent_dir/config.yml" slow spike-null/null-two
ycc l3-rerun "$home" install --target omp --settings --global
assert_rc 0 're-run install --target omp --settings'
has l3-rerun '[!!] kept your local value at /modelRoles/slow'
o l3-roles-after "$home" config get modelRoles --json
assert_rc 0 'config get modelRoles (after re-run)'
check l3-kept roles "$managed_src" "$(state l3-roles-after)" '{"slow": "spike-null/null-two"}'
log 'PASS L3: --settings writes the managed modelRoles, retry.fallbackChains and tools.approvalMode, keeps user keys, and a re-run keeps the edited modelRoles.slow'

# --- L4. Project .omp/config.yml beats the managed user values -------------------------------
cat >"$proj/.omp/config.yml" <<'EOF'
modelRoles:
  default: spike-null/null-two
tools:
  approvalMode: always-ask
EOF
rpc l4-project "$proj"
check l4-model model "$(state l4-project)" spike-null/null-two
o l4-approval "$proj" config get tools.approvalMode
assert_rc 0 'config get tools.approvalMode (project)'
value l4-approval always-ask
log '  config get tools.approvalMode: always-ask (project)'
rpc l4-subdir "$proj/sub"
check l4-model-revert model "$(state l4-subdir)" spike-null/null-two yes
o l4-approval-revert "$proj/sub" config get tools.approvalMode
assert_rc 0 'config get tools.approvalMode (subdir)'
value l4-approval-revert write
log '  config get tools.approvalMode: write (non-project cwd)'
log 'PASS L4: project .omp/config.yml modelRoles.default and tools.approvalMode beat the managed user values; both revert outside the project cwd'
log "PASS all YAN-1175 OMP rules/settings checks ($version_text, sandbox=$sandbox)"
