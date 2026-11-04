# shellcheck shell=bash
# Shared helpers for the opt-in live harnesses (scripts/test-omp-*.sh and
# scripts/test-pi-runtime-contract-spike.sh), sourced after `set -euo pipefail`. They keep the
# harnesses portable to macOS (YAN-1555) without changing Linux behaviour: GNU coreutils are
# required and checked, the sandbox root is resolved (macOS /tmp is a symlink to /private/tmp),
# `env -C` (GNU only) is replaced by a /bin/sh wrapper, and the sandbox PATH can carry
# explicitly named extra directories. They also build the one bubblewrap layout every harness
# uses (YAN-1905).
#
# Provided:
#   omp_h_die MSG...                          print "ERROR: MSG" to stderr, exit 1
#   omp_h_require_gnu_tools                   fail with a reason unless realpath -m and timeout -k work
#   omp_h_mktemp_root PREFIX [PARENT]         mktemp -d PARENT(/tmp)/PREFIX.XXXXXX, symlinks resolved
#   omp_h_under_tmp PATH                      true when PATH is /tmp or below (symlinks resolved)
#   omp_h_safe_path ALLOW_ENV_I [LEAD_DIR]    the sandbox PATH: LEAD_DIR, extras, /usr/local/bin:/usr/bin:/bin
#   omp_h_check_path_tools PATH TOOL...       fail unless every TOOL resolves on PATH
#   omp_in_dir                                array: prefix, then DIR and a command (portable `env -C`)
#   omp_h_sandbox ALLOW_ENV_I ROOT REAL_HOME [RO_PATH...]
#                                             select the sandbox: sets `sandbox` and `wrap`
#   omp_h_sandbox_probe ROOT REAL_HOME [RO_PATH...]
#                                             fail unless the selected bwrap sandbox isolates
#
# YCC_HARNESS_EXTRA_PATH: colon-separated absolute directories placed after LEAD_DIR and before
# /usr/local/bin in the sandbox PATH. It exists for macOS runners, where GNU coreutils and a
# Bash 4+ live outside /usr/bin; it is honoured only with --allow-env-i on Darwin (a Linux
# bwrap sandbox hides everything but the system tree, so extras would be dead or misleading)
# and every entry must be an existing absolute directory.

omp_h_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if ((BASH_VERSINFO[0] < 4)); then
  omp_h_die "bash >= 4 is required (this is ${BASH_VERSION}); on macOS install it with 'brew install bash' and put it first on PATH"
fi

# A command that fails under `set -e` must say why even when no die() ran (a silent exit 1
# is undebuggable in CI). -E makes the trap reach functions and subshells.
omp_h_err_trap() {
  printf 'ERROR: %s: line %s: command failed with exit %s: %s\n' "${0##*/}" "$2" "$1" "$3" >&2
}
set -E
trap 'omp_h_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR

# Portable `env -C DIR CMD...`: run as `"${omp_in_dir[@]}" DIR CMD...`.
# shellcheck disable=SC2016,SC2034 # SC2016: the script is for /bin/sh; SC2034: used by the sourcing harnesses
omp_in_dir=(/bin/sh -c 'cd -- "$1" || exit 1; shift; exec "$@"' ycc-in-dir)

# Probe behaviour, not a vendor string: macOS has no `timeout` and its BSD realpath has no -m;
# uutils or GNU coreutils both satisfy the harnesses.
omp_h_require_gnu_tools() {
  local hint="macOS: brew install coreutils and put \$(brew --prefix coreutils)/libexec/gnubin first on PATH"
  realpath -m /ycc-harness-probe/missing >/dev/null 2>&1 ||
    omp_h_die "'realpath -m' is unavailable: GNU-compatible coreutils are required ($hint)"
  timeout -k 1 5 true >/dev/null 2>&1 ||
    omp_h_die "'timeout -k' is unavailable: GNU-compatible coreutils are required ($hint)"
}

omp_h_mktemp_root() {
  local prefix=$1 parent=${2:-/tmp} dir
  dir=$(mktemp -d "$parent/$prefix.XXXXXX") || omp_h_die "mktemp -d $parent/$prefix.XXXXXX failed"
  realpath "$dir"
}

omp_h_under_tmp() {
  local base
  base=$(realpath /tmp)
  [[ "$1" == "$base" || "$1" == "$base"/* ]]
}

omp_h_safe_path() {
  local allow_env_i=${1:-0} lead=${2:-} path=/usr/local/bin:/usr/bin:/bin extra dir
  extra=${YCC_HARNESS_EXTRA_PATH:-}
  if [[ -n "$extra" ]]; then
    if ! { ((allow_env_i)) && [[ "$(uname -s)" == Darwin ]]; }; then
      omp_h_die 'YCC_HARNESS_EXTRA_PATH is only honoured with --allow-env-i on Darwin; unset it'
    fi
    local dirs=() entry
    IFS=: read -r -a dirs <<<"$extra"
    local joined=
    for entry in "${dirs[@]}"; do
      [[ "$entry" == /* && "$entry" != *[[:space:]]* && -d "$entry" ]] ||
        omp_h_die "YCC_HARNESS_EXTRA_PATH entry is not an existing absolute directory: '$entry'"
      dir=$(realpath "$entry")
      joined=${joined:+$joined:}$dir
    done
    path=$joined:$path
  fi
  printf '%s\n' "${lead:+$lead:}$path"
}

omp_h_check_path_tools() {
  local path=$1 tool
  shift
  for tool in "$@"; do
    PATH=$path command -v "$tool" >/dev/null ||
      omp_h_die "missing prerequisite on the sandbox PATH ($path): $tool"
  done
}

# Bubblewrap layout (YAN-1905). The host tree is read-only; the real home, /run (user runtime
# dir, system bus, container-engine sockets), /tmp and /var/tmp (X11 sockets, other users'
# files) are hidden behind tmpfs; /dev and /proc are fresh; network, PID and IPC are private
# namespaces and the command runs in a new session, so host processes cannot be signalled,
# the caller's terminal cannot be fed keystrokes, and nothing outlives a call. Each RO_PATH
# (binaries, the checkout) is bound back read-only, then ROOT read-write.
#
# Path rules: REAL_HOME, ROOT and every RO_PATH must be absolute and not /. ROOT must not be
# the real home or sit below it. No path may be or contain the real home, /run, /tmp or
# /var/tmp (a later bind would re-expose the hidden host directory), and no RO_PATH may sit
# inside ROOT (the later ROOT bind would make it writable). An RO_PATH below the real home is
# fine: only that subtree becomes visible. With bwrap present every path must also be
# canonical, since these string checks do not hold for //, .. or symlinks.
#
# Sets `sandbox` to bwrap-netns and `wrap` to the bwrap argv ending in `--` when the layout
# works and passes omp_h_sandbox_probe. Without a working bwrap it sets `sandbox=env-i` and an
# empty `wrap` only when ALLOW_ENV_I is 1 (warning when bwrap exists but failed); otherwise it
# fails closed.
omp_h_sandbox() {
  local allow_env_i=$1 root=$2 real_home=$3 bin path hidden binds err=
  shift 3
  [[ "$real_home" == /* && "$real_home" != / ]] ||
    omp_h_die "the real HOME must be an absolute path other than /, got '$real_home'"
  [[ "$root" != "$real_home" && "$root" != "$real_home"/* ]] ||
    omp_h_die "the sandbox root ($root) must not be or live under the real HOME ($real_home)"
  for path in "$root" "$@"; do
    [[ "$path" == /* && "$path" != / ]] ||
      omp_h_die "refusing to bind '$path' into the sandbox: it is not absolute or is /"
    for hidden in "$real_home" /run /tmp /var/tmp; do
      [[ "$path" != "$hidden" && "$hidden" != "$path"/* ]] ||
        omp_h_die "refusing to bind '$path' into the sandbox: it would re-expose $hidden"
    done
  done
  for path in "$@"; do
    [[ "$path" != "$root"/* ]] ||
      omp_h_die "refusing to bind '$path' read-only: it is inside the writable sandbox root ($root)"
  done
  binds=(--ro-bind / / --dev /dev --proc /proc --tmpfs "$real_home" --tmpfs /run --tmpfs /tmp
    --tmpfs /var/tmp)
  for path in "$@"; do binds+=(--ro-bind "$path" "$path"); done
  binds+=(--bind "$root" "$root" --unshare-net --unshare-pid --unshare-ipc --new-session
    --die-with-parent)
  # shellcheck disable=SC2034 # read by the sourcing harnesses
  sandbox=env-i
  wrap=()
  bin=$(command -v bwrap || true)
  if [[ -n "$bin" ]]; then
    bin=$(realpath "$bin")
    for path in "$real_home" "$root" "$@"; do
      [[ "$(realpath -m -- "$path")" == "$path" ]] ||
        omp_h_die "refusing to bind non-canonical path '$path' into the sandbox"
    done
    if err=$(env -i PATH=/usr/bin:/bin "$bin" "${binds[@]}" /bin/true 2>&1 >/dev/null); then
      # shellcheck disable=SC2034 # read by the sourcing harnesses
      sandbox=bwrap-netns
      wrap=("$bin" "${binds[@]}" --)
      omp_h_sandbox_probe "$root" "$real_home" "$@"
      return 0
    fi
    err=${err:-bwrap exited non-zero}
  fi
  ((allow_env_i)) ||
    omp_h_die "bubblewrap with --unshare-net/--unshare-pid is unavailable${err:+ ($err)}; refusing to run without network/home isolation (pass --allow-env-i to override)"
  [[ -z "$err" ]] ||
    printf 'WARNING: the bubblewrap layout failed (%s); --allow-env-i falls back to env -i\n' "$err" >&2
}

# omp_h_sandbox_probe ROOT REAL_HOME [RO_PATH...]: fail unless the selected bwrap sandbox
# isolates. Inside it (bounded to 60 s): no socket or FIFO the sandbox user can write to
# exists outside ROOT (a read-only mount does not stop connect(), so the scan covers the
# whole tree except /proc, /sys, /dev and the large package trees /usr, /opt, /snap, /boot
# and /nix/store, which hold no daemon sockets and take minutes to walk on CI runners), the
# host's runtime dirs are gone, PID 1 is bwrap, the only network interface is lo, and the real
# home holds nothing but the mount points of RO_PATHs below it.
omp_h_sandbox_probe() {
  local root=$1 real_home=$2 out path allowed=
  shift 2
  # First path component below the real home of each RO_PATH that lives there.
  for path in "$@"; do
    [[ "$path" != "$real_home"/* ]] || { path=${path#"$real_home"/}; allowed+=" ${path%%/*}"; }
  done
  # shellcheck disable=SC2016 # the script runs inside the sandbox: $1 = ROOT, $2 = REAL_HOME
  out=$(env -i PATH=/usr/bin:/bin "${wrap[@]}" timeout -k 5 60 /bin/sh -c '
    for t in find awk cat; do
      command -v "$t" >/dev/null || { echo "$t is missing"; exit 1; }
    done
    found=$(find / \( -path /proc -o -path /sys -o -path /dev -o -path /usr -o -path /opt \
      -o -path /snap -o -path /boot -o -path /nix/store \) -prune -o \
      \( -type s -o -type p \) -writable -print 2>/dev/null)
    leaked=$(printf "%s\n" "$found" | awk -v p="$1/" "NF && index(\$0, p) != 1") ||
      { echo "socket scan failed"; exit 1; }
    [ -z "$leaked" ] || { printf "host socket or FIFO visible: %s\n" "$leaked"; exit 1; }
    for d in /run/user /run/dbus /tmp/.X11-unix; do
      [ ! -e "$d" ] || { printf "host path visible: %s\n" "$d"; exit 1; }
    done
    [ "$(cat /proc/1/comm)" = bwrap ] || { echo "no private PID namespace"; exit 1; }
    ifaces=$(awk "NR > 2 { print \$1 }" /proc/net/dev)
    [ "$ifaces" = "lo:" ] || { printf "network not private: %s\n" "$ifaces"; exit 1; }
    for e in "$2"/* "$2"/.[!.]* "$2"/..?*; do
      [ -e "$e" ] || [ -L "$e" ] || continue
      case " $3 " in *" ${e##*/} "*) ;; *) printf "real home not hidden: %s\n" "$e"; exit 1 ;; esac
    done
  ' omp-sandbox-probe "$root" "$real_home" "$allowed" 2>&1) ||
    omp_h_die "bubblewrap sandbox probe failed: ${out:-probe exited non-zero or timed out}"
}
