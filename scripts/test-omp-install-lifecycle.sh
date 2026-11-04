#!/usr/bin/env bash
# Opt-in live checks for `./install.sh --target omp` against real omp (YAN-1172).
# Not part of CI. No credentials, no network inside the sandbox, no model inference.
# shellcheck disable=SC2154 # omp_in_dir comes from lib/omp-harness-common.sh
set -euo pipefail
umask 077
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/omp-harness-common.sh"

usage() {
  cat <<'EOF'
Usage: test-omp-install-lifecycle.sh [--keep] [--allow-env-i]

Runs the real ./install.sh --target omp (YCC_INSTALL_SKIP_BUILD=1: no generator, validator
or formatter touches the checkout) against real omp >=18.12.2 (OMP_BIN overrides PATH;
default ~/.local/bin/omp). Requires git, python3 with the repository's generator
dependencies, timeout, tar, and bubblewrap with a working --unshare-net.

Every command runs under env -i with HOME/XDG/TMPDIR inside a mktemp sandbox under /tmp
and PATH=<sandbox>/bin:/usr/local/bin:/usr/bin:/bin (<sandbox>/bin/omp links to OMP_BIN),
and under bwrap with a private network namespace, the real home hidden behind a tmpfs,
and this checkout bind-mounted read-only (an installer write into the repo fails).
Without bwrap the harness refuses to run unless --allow-env-i accepts the weaker env -i
sandbox. OMP_BIN must be a self-contained binary (a Bun-installed script fails the
preflight). The upgrade and migration steps use a sandbox copy of this checkout (tracked
and untracked, non-ignored files) with a bumped version source, so nothing writes the repo.

Checks: install --dry-run writes nothing; user install and idempotent re-run; --project
install shadows the user install; a project-scope disable survives a re-run; a newer
checkout upgrades the user install, then a --project re-run repairs the GC'd project
cache (omp <18.13.0) or upgrades the intact project install (omp >=18.13.0) with disabled
kept; remove --project then remove leave no plugin, registry, lock, link, cache, marketplace,
state or export; migrate retires an `omp plugin link` of this checkout (dry-run keeps it);
the core matrix again with OMP_PROFILE=work and with an XDG data root ($XDG_DATA_HOME/omp).
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
for tool in git python3 timeout mktemp realpath tar; do
  command -v "$tool" >/dev/null || die "missing prerequisite: $tool"
done
omp_h_require_gnu_tools

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
smoke=$repo/scripts/omp_native_smoke.py
omp=${OMP_BIN:-$HOME/.local/bin/omp}
[[ -x "$omp" ]] || omp=$(command -v omp || true)
[[ -n "$omp" && -x "$omp" ]] || die 'set OMP_BIN or install omp at ~/.local/bin/omp or on PATH'
omp=$(realpath "$omp")
python=$(command -v python3)
real_home=$(realpath "${HOME:?HOME must be set}")
root=$(omp_h_mktemp_root omp-install-lifecycle)
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

# The current case: its HOME/XDG tree and extra environment (OMP_PROFILE).
case_home=$root/case
extra_env=()
# Run a command with no inherited environment, an isolated HOME/XDG tree, and file-only git.
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
# bwrap works on its own; a failure here is omp needing files the sandbox hides.
# Run the HOME guard once with stderr visible: the preflight below discards it.
clean true
clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 30 omp --version >/dev/null 2>&1 ||
  die "OMP_BIN ($omp) does not run inside the $sandbox sandbox: it must be a self-contained binary outside \$HOME's dependencies (env -i PATH=$safe_path, real home hidden)"
log() { printf '%s\n' "$*" | tee -a "$root/transcript.log"; }
rc=0
# Record argv, exit status and (sandbox-relative) output of one command in the transcript.
record() {
  local label=$1; shift
  {
    printf '\n[%s] argv:' "$label"; printf ' %q' "${@/#"$root"/<SANDBOX>}"
    printf '\nexit=%s\nstdout:\n' "$rc"; head -c 6000 "$root/logs/$label.stdout" | sed "s#$root#<SANDBOX>#g"
    printf '\nstderr:\n'; head -c 3000 "$root/logs/$label.stderr" | sed "s#$root#<SANDBOX>#g"; printf '\n'
  } >>"$root/transcript.log"
}
# Run under the sandbox from directory $1 and record. Callers assert the exit status.
run() {
  local label=$1 dir=$2; shift 2
  [[ ! -e "$root/logs/$label.stdout" ]] || die "duplicate label: $label"
  rc=0
  clean ${wrap[@]+"${wrap[@]}"} timeout -k 5 180 "${omp_in_dir[@]}" "$dir" "$@" </dev/null \
    >"$root/logs/$label.stdout" 2>"$root/logs/$label.stderr" || rc=$?
  record "$label" "$@"
}
# o LABEL DIR ARGS: omp from DIR.  ycc LABEL DIR CHECKOUT ARGS: CHECKOUT/install.sh from DIR.
o() { local label=$1 dir=$2; shift 2; run "$label" "$dir" omp "$@"; }
ycc() { local label=$1 dir=$2 checkout=$3; shift 3; run "$label" "$dir" "$checkout/install.sh" "$@"; }
# Host-side helper (fixture copy, Python assertions): env -i, no sandbox wrapper.
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
  local label=$1 re; shift
  for re in "$@"; do
    ! grep -qE -- "$re" "$root/logs/$label.stdout" "$root/logs/$label.stderr" ||
      die "$label: output must not match /$re/ (see $root/transcript.log)"
  done
}
# check LABEL SCRIPT ARGS: a Python assertion (omp_native_smoke.py or the local checks).
check() { local label=$1; shift; host "$label" "$python" "$@"; log "  $(<"$root/logs/$label.stdout")"; }
listing() { local label=$1 dir=$2; o "$label" "$dir" plugin list --json; assert_rc 0 "$label: plugin list --json"; }
# Paths of the current case.
h() { realpath -m "$case_home/home"; }
state_file() { printf '%s/.config/ycc/omp-native-install.json' "$(h)"; }
export_root() { printf '%s/data/ycc/omp-marketplace' "$case_home"; }

cat >"$root/checks.py" <<'PY'
"""Assertions over captured `omp plugin list --json` output and the ycc ownership state."""
import json
import sys
from pathlib import Path


def fail(message):
    print(f"checks: {message}", file=sys.stderr)
    sys.exit(1)


def items(path, plugin_id):
    return [item for item in json.loads(Path(path).read_text())["marketplace"] if item.get("id") == plugin_id]


def item(path, plugin_id, scope, *pairs):
    """An item for PLUGIN_ID at SCOPE whose item or first entry has each key=json-value (key^=prefix)."""
    found = [i for i in items(path, plugin_id) if i.get("scope") == scope]
    if len(found) != 1:
        fail(f"{path}: expected one {plugin_id} ({scope}) item, got {found}")
    entry = found[0]["entries"][0]
    for pair in pairs:
        prefix = "^=" in pair
        key, value = pair.split("^=" if prefix else "=", 1)
        actual = found[0].get(key, entry.get(key))
        if prefix:
            if not isinstance(actual, str) or not actual.startswith(value):
                fail(f"{path}: {plugin_id} ({scope}) {key}={actual!r} does not start with {value}")
        elif actual != json.loads(value):
            fail(f"{path}: {plugin_id} ({scope}) {key}={actual!r}, expected {value}")
    return f"{plugin_id} ({scope}) {' '.join(pairs)}".rstrip()


def count(path, plugin_id, expected):
    found = items(path, plugin_id)
    if len(found) != int(expected):
        fail(f"{path}: expected {expected} {plugin_id} item(s), got {found}")
    return f"{expected} {plugin_id} item(s)"


def npm(path, name, want):
    present = any(i.get("name") == name for i in json.loads(Path(path).read_text())["npm"])
    if present != (want == "present"):
        fail(f"{path}: npm link {name} expected {want}")
    return f"npm link {name} {want}"


def profiles(path, *keys):
    actual = sorted(json.loads(Path(path).read_text())["profiles"])
    if actual != sorted(keys):
        fail(f"{path}: profiles {actual}, expected {sorted(keys)}")
    return f"state profiles: {', '.join(actual)}"


def profile(path, key):
    return json.dumps(json.loads(Path(path).read_text())["profiles"][key], sort_keys=True)


def cache(path, plugin_id, scope):
    """The single PLUGIN_ID item at SCOPE has an existing installPath directory (its cache survived)."""
    found = [i for i in items(path, plugin_id) if i.get("scope") == scope]
    if len(found) != 1:
        fail(f"{path}: expected one {plugin_id} ({scope}) item, got {found}")
    install_path = found[0]["entries"][0].get("installPath")
    if not isinstance(install_path, str) or not Path(install_path).is_dir():
        fail(f"{path}: {plugin_id} ({scope}) cache {install_path!r} is not an existing directory")
    return f"{plugin_id} ({scope}) cache present: {install_path}"


COMMANDS = {"item": item, "count": count, "npm": npm, "profiles": profiles, "profile": profile, "cache": cache}
print(COMMANDS[sys.argv[1]](*sys.argv[2:]))
PY
checks=$root/checks.py

# Absent: no plugin/registry/lock/link/cache (smoke `absent`), no ycc marketplace, no state, no export.
assert_absent() {
  local tag=$1 dir=$2 omp_home=$3
  listing "$tag-list" "$dir"
  check "$tag-proof" "$smoke" absent "$root/logs/$tag-list.stdout" "$omp_home"
  o "$tag-mkt" "$dir" plugin marketplace list
  assert_rc 0 "$tag: marketplace list"
  lacks "$tag-mkt" '^  ycc  '
  [[ ! -e "$(state_file)" ]] || die "$tag: state file remains: $(state_file)"
  [[ ! -e "$(export_root)" ]] || die "$tag: export remains: $(export_root)"
}

o version "$root/work" --version
assert_rc 0 version
version_text=$(<"$root/logs/version.stdout")
"$python" - "$version_text" <<'PY' || die "omp >=18.12.2 required, got: $version_text"
import re, sys
match = re.search(r"(\d+)\.(\d+)\.(\d+)", sys.argv[1])
sys.exit(0 if match and tuple(map(int, match.groups())) >= (18, 12, 2) else 1)
PY
# omp >=18.13.0 keeps the cache dirs of project installs it made itself (oh-my-pi#16827, fixed by
# #16830); older omp GCs them on a user-scope upgrade. The harness installs the project with this omp.
keeps_linked_cache=0
if "$python" - "$version_text" <<'PY'; then keeps_linked_cache=1; fi
import re, sys
match = re.search(r"(\d+)\.(\d+)\.(\d+)", sys.argv[1])
sys.exit(0 if match and tuple(map(int, match.groups())) >= (18, 13, 0) else 1)
PY
version=$("$python" -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
  "$repo/ycc/.claude-plugin/plugin.json")
IFS=. read -r v_major v_minor v_patch <<<"${version%%[-+]*}"
next=$v_major.$v_minor.$((v_patch + 1))
log "omp: $version_text; checkout: $repo (ycc $version); sandbox=$sandbox"

# --- 1. Dry run writes nothing ------------------------------------------------------------
home=$(h)
mkdir -p "$home"
ycc dry "$home" "$repo" install --target omp --dry-run
assert_rc 0 'install --dry-run'
has dry "[dry-run] would export OMP packages → $(export_root)" \
  "[dry-run] would run: omp plugin marketplace add $(export_root)" \
  '[dry-run] would run: omp plugin install --scope user ycc@ycc'
lacks dry '^\[ok\] omp '
for path in "$(state_file)" "$case_home/data/ycc" "$home/.omp/marketplaces.json" \
  "$home/.omp/plugins/installed_plugins.json" "$case_home/data/omp"; do
  [[ ! -e "$path" ]] || die "install --dry-run wrote $path"
done
log 'PASS dry-run: previews marketplace add + install; no state, export, marketplaces.json, registry or XDG omp dir written'

# --- 2. User install, idempotent re-run -----------------------------------------------------
ycc install "$home" "$repo" install --target omp
assert_rc 0 install
has install "[ok] exported OMP packages → $(export_root) (ycc $version)" \
  "[ok] omp plugin marketplace add $(export_root)" '[ok] omp plugin install --scope user ycc@ycc' \
  "[ok] ycc@ycc $version installed (user)" 'OMP has no trust prompt'
listing list-user "$home"
check user-proof "$smoke" installed "$root/logs/list-user.stdout" "$(export_root)" "$version"
[[ -f "$(state_file)" ]] || die 'install recorded no ownership state'
ycc rerun "$home" "$repo" install --target omp
assert_rc 0 're-run install'
has rerun "[ok] ycc@ycc $version up to date (user)"
lacks rerun '^\[ok\] omp ' '^\[ok\] exported '
log "PASS install: user scope ycc@ycc $version from the export; re-run 'up to date (user)' with no omp mutation or re-export"

# --- 3. Project install shadows the user install ---------------------------------------------
proj=$home/proj
mkdir -p "$proj"
run git-init "$proj" git init -q
assert_rc 0 'git init'
ycc install-project "$proj" "$repo" install --target omp --project
assert_rc 0 'install --project'
has install-project '[ok] omp plugin install --scope project ycc@ycc' "[ok] ycc@ycc $version installed (project)" \
  'a project install shadows your user install here'
lacks install-project 'marketplace add'
listing list-project "$proj"
check project-proof "$checks" item "$root/logs/list-project.stdout" ycc@ycc project "version=\"$version\""
check shadow-proof "$checks" item "$root/logs/list-project.stdout" ycc@ycc user 'shadowedBy="project"'
log 'PASS project: --project installs ycc@ycc at project scope; the user item reports "shadowedBy": "project"'

# --- 4. A project-scope disable survives a re-run ---------------------------------------------
o disable "$proj" plugin disable --scope project ycc@ycc
assert_rc 0 'disable --scope project'
ycc rerun-project "$proj" "$repo" install --target omp --project
assert_rc 0 're-run install --project'
has rerun-project "[ok] ycc@ycc $version up to date (project)" '[ok] ycc@ycc disabled at project scope: kept'
lacks rerun-project '^\[ok\] omp ' 'Enabled'
listing list-disabled "$proj"
check disabled-proof "$checks" item "$root/logs/list-disabled.stdout" ycc@ycc project 'enabled=false'
log "PASS disabled: re-run keeps the project install disabled ('disabled at project scope: kept', \"enabled\": false)"

# --- 5. A newer checkout upgrades -----------------------------------------------------------
# A copy of this checkout with the version source bumped: exactly what pulling a release does.
# The helper re-exports from its checkout and swaps the export only when its bytes change.
checkout=$root/checkout
mkdir -p "$checkout"
host ls-files git -C "$repo" ls-files -z -co --exclude-standard
# --ignore-failed-read is GNU tar only; bsdtar (macOS) has no equivalent.
tar_opts=(--null)
if [[ "$(tar --version 2>/dev/null)" == *GNU* ]]; then tar_opts+=(--ignore-failed-read); fi
host copy tar "${tar_opts[@]}" -C "$repo" -T "$root/logs/ls-files.stdout" -cf "$root/tmp/checkout.tar"
host untar tar -C "$checkout" -xf "$root/tmp/checkout.tar"
check bump "$smoke" bump "$checkout" "$next" ycc/.claude-plugin/plugin.json
ycc upgrade "$home" "$checkout" install --target omp
assert_rc 0 'install (newer checkout)'
has upgrade "[ok] exported OMP packages → $(export_root) (ycc $next)" '[ok] omp plugin marketplace update ycc' \
  '[ok] omp plugin upgrade --scope user ycc@ycc' "Upgraded ycc@ycc (user) to $next" \
  "[ok] ycc@ycc $version -> $next upgraded (user)"
listing list-upgraded "$home"
check upgraded-proof "$smoke" installed "$root/logs/list-upgraded.stdout" "$(export_root)" "$next"
listing list-upgraded-project "$proj"
check upgraded-disabled "$checks" item "$root/logs/list-upgraded-project.stdout" ycc@ycc project 'enabled=false'
if ((keeps_linked_cache)); then
  # The user upgrade leaves the project install's cache alone: it still lists the old version.
  check upgraded-cache "$checks" cache "$root/logs/list-upgraded-project.stdout" ycc@ycc project
  check upgraded-kept "$checks" item "$root/logs/list-upgraded-project.stdout" ycc@ycc project "version=\"$version\""
  lacks upgrade 'lost its cache'
  ycc upgrade-project "$proj" "$checkout" install --target omp --project
  assert_rc 0 'upgrade install --project'
  has upgrade-project '[ok] omp plugin upgrade --scope project ycc@ycc' \
    "[ok] ycc@ycc $version -> $next upgraded (project)" '[ok] ycc@ycc disabled at project scope: kept'
  lacks upgrade-project 'install --force'
  project_outcome="keeps the project cache ($version, no GC report); a --project re-run upgrades it to $next"
else
  has upgrade "[!!] ycc@ycc project install at $proj lost its cache (omp GC)"
  ycc repair "$proj" "$checkout" install --target omp --project
  assert_rc 0 'repair install --project'
  has repair '[ok] omp plugin install --force --scope project ycc@ycc' "[ok] ycc@ycc $next reinstalled (project)" \
    '[ok] ycc@ycc disabled at project scope: kept'
  project_outcome="GCs the project cache and the installer reports it; a --project re-run repairs it at $next"
fi
listing list-repaired "$proj"
check repaired-proof "$checks" item "$root/logs/list-repaired.stdout" ycc@ycc project "version=\"$next\"" 'enabled=false'
log "PASS upgrade: a $next checkout re-exports, updates the marketplace and upgrades user $version -> $next; omp $project_outcome, and it stays disabled"

# --- 6. Remove --project, then remove ---------------------------------------------------------
ycc remove-project "$proj" "$repo" remove --target omp --only base --project
assert_rc 0 'remove --project'
has remove-project '[ok] omp plugin uninstall --scope project ycc@ycc' \
  '[!!] kept marketplace ycc: ycc@ycc (user), ycc-mcp@ycc (user), ycc-rules@ycc (user) still installed'
ycc remove-user "$home" "$repo" remove --target omp --only base
assert_rc 0 'remove'
has remove-user '[ok] omp plugin uninstall --scope user ycc@ycc' '[ok] omp plugin marketplace remove ycc' \
  "[ok] removed $(export_root)"
assert_absent absent "$home" "$home/.omp"
listing list-absent-project "$proj"
check absent-project "$checks" count "$root/logs/list-absent-project.stdout" ycc@ycc 0
log 'PASS remove: --project keeps the marketplace for the user install; remove leaves no plugin, registry, lock, link, cache, ycc marketplace, state or export'

# --- 7. Migrate an `omp plugin link` of this checkout ------------------------------------------
# The link points into the sandbox checkout copy, so omp can never write the real repo.
o link "$home" plugin link "$checkout/packages/omp/ycc"
assert_rc 0 'plugin link'
has link "Linked ycc from $checkout/packages/omp/ycc"
ycc install-linked "$home" "$checkout" install --target omp
[[ "$rc" != 0 ]] || die 'install over an omp plugin link must refuse'
has install-linked 'runtime package ycc is linked (omp plugin link); run ./install.sh migrate --target omp'
[[ ! -e "$(state_file)" ]] || die 'refused install wrote state'
ycc migrate-dry "$home" "$checkout" migrate --target omp
assert_rc 0 'migrate (dry-run)'
has migrate-dry '[dry-run] would run: omp plugin uninstall ycc' '[dry-run] Would uninstall ycc'
listing list-linked "$home"
check linked-proof "$checks" npm "$root/logs/list-linked.stdout" ycc present
ycc migrate-apply "$home" "$checkout" migrate --target omp --apply
assert_rc 0 'migrate --apply'
has migrate-apply '[ok] omp plugin uninstall ycc' 'Uninstalled ycc' \
  '[ok] run ./install.sh install --target omp to reinstall natively'
listing list-unlinked "$home"
check unlinked-proof "$checks" npm "$root/logs/list-unlinked.stdout" ycc absent
ycc install-migrated "$home" "$repo" install --target omp
assert_rc 0 'install after migrate'
has install-migrated "[ok] ycc@ycc $version installed (user)"
listing list-migrated "$home"
check migrated-one "$checks" count "$root/logs/list-migrated.stdout" ycc@ycc 1
check migrated-npm "$checks" npm "$root/logs/list-migrated.stdout" ycc absent
log 'PASS migrate: install refuses over a checkout link; dry-run keeps the link; --apply unlinks it; install leaves exactly one ycc@ycc and no npm ycc'

# --- 8a. OMP_PROFILE=work: separate state, default profile untouched ---------------------------
default_key=$home/.omp/agent
work_key=$home/.omp/profiles/work/agent
check default-before "$checks" profile "$(state_file)" "$default_key"
extra_env=(OMP_PROFILE=work)
ycc work-install "$home" "$repo" install --target omp
assert_rc 0 'install (OMP_PROFILE=work)'
has work-install "[ok] omp plugin marketplace add $(export_root)" "[ok] ycc@ycc $version installed (user)"
lacks work-install '^\[ok\] exported '
listing work-list "$home"
check work-proof "$checks" item "$root/logs/work-list.stdout" ycc@ycc user \
  "installPath^=$home/.omp/profiles/work/plugins/cache/plugins/ycc___ycc___$version"
check work-profiles "$checks" profiles "$(state_file)" "$default_key" "$work_key"
ycc work-rerun "$home" "$repo" install --target omp
assert_rc 0 're-run install (OMP_PROFILE=work)'
has work-rerun "[ok] ycc@ycc $version up to date (user)"
lacks work-rerun '^\[ok\] omp '
ycc work-remove "$home" "$repo" remove --target omp --only base
assert_rc 0 'remove (OMP_PROFILE=work)'
has work-remove '[ok] omp plugin uninstall --scope user ycc@ycc' '[ok] omp plugin marketplace remove ycc'
lacks work-remove '^\[ok\] removed '
listing work-absent-list "$home"
check work-absent "$smoke" absent "$root/logs/work-absent-list.stdout" "$home/.omp/profiles/work"
extra_env=()
check default-after "$checks" profile "$(state_file)" "$default_key"
[[ "$(<"$root/logs/default-before.stdout")" == "$(<"$root/logs/default-after.stdout")" ]] ||
  die 'OMP_PROFILE=work changed the default profile state'
check work-gone "$checks" profiles "$(state_file)" "$default_key"
listing default-list "$home"
check default-kept "$checks" item "$root/logs/default-list.stdout" ycc@ycc user "version=\"$version\""
[[ -d "$(export_root)" ]] || die 'OMP_PROFILE=work remove deleted the export the default profile uses'
ycc default-remove "$home" "$repo" remove --target omp --only base
assert_rc 0 'remove (default profile)'
assert_absent default-absent "$home" "$home/.omp"
log "PASS profile: OMP_PROFILE=work installs under profiles/work, state keyed by $work_key, idempotent, removed; the default profile's install, state and the shared export stay until its own remove"

# --- 8b. XDG data root: omp routes plugins under $XDG_DATA_HOME/omp ---------------------------
case_home=$root/xdg
home=$(h)
mkdir -p "$home" "$case_home/data/omp"
ycc xdg-install "$home" "$repo" install --target omp
assert_rc 0 'install (XDG data root)'
has xdg-install "[ok] omp plugin marketplace add $(export_root)" "[ok] ycc@ycc $version installed (user)"
listing xdg-list "$home"
check xdg-proof "$checks" item "$root/logs/xdg-list.stdout" ycc@ycc user \
  "installPath^=$case_home/data/omp/plugins/cache/plugins/ycc___ycc___$version"
check xdg-bytes "$smoke" installed "$root/logs/xdg-list.stdout" "$(export_root)" "$version"
[[ ! -e "$home/.omp/marketplaces.json" ]] || die 'XDG data root: marketplaces.json written under ~/.omp'
ycc xdg-rerun "$home" "$repo" install --target omp
assert_rc 0 're-run install (XDG data root)'
has xdg-rerun "[ok] ycc@ycc $version up to date (user)"
lacks xdg-rerun '^\[ok\] omp '
ycc xdg-remove "$home" "$repo" remove --target omp --only base
assert_rc 0 'remove (XDG data root)'
has xdg-remove '[ok] omp plugin uninstall --scope user ycc@ycc' '[ok] omp plugin marketplace remove ycc' \
  "[ok] removed $(export_root)"
assert_absent xdg-absent "$home" "$case_home/data/omp"
log 'PASS xdg: with XDG_DATA_HOME/omp present the install lands under it, re-run is idempotent, remove leaves nothing'

log "PASS all YAN-1172 omp install lifecycle checks ($version_text, sandbox=$sandbox)"
