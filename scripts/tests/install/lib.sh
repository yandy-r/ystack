#!/usr/bin/env bash
# Shared harness for the install.sh test suites under scripts/tests/install/:
# sandbox HOMEs, stub claude/codex CLIs, run_install and pass/fail counters.
#
# Every test runs against a throwaway HOME so the caller's real ~/.claude,
# ~/.codex, ~/.cursor and ~/.config/opencode are never touched. Sourced once
# per shell (load guard), so the runner's suites share one sandbox, one EXIT
# trap and one set of counters.
[[ -n "${INSTALL_TESTS_LIB_LOADED:-}" ]] && return 0
INSTALL_TESTS_LIB_LOADED=1
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
INSTALL="${REPO_ROOT}/install.sh"

# Match the installer's package-model gate, not generated catalog contents.
repo_codex_native() {
    python3 "${REPO_ROOT}/scripts/codex_install.py" enabled >/dev/null 2>&1
}

# skip_listed <name> — honest marker for an assertion pinned to the unlisted (legacy) repo state.
skip_listed() {
    printf '[skip] %s (repo listed: legacy-only assertion)\n' "$1"
}

PASS=0
FAIL=0

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

# Per-user dir overrides would escape the sandbox HOME (XDG_CACHE_HOME: the
# opencode --purge-cache tests delete under it).
unset XDG_BIN_HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME BASH_COMPLETION_USER_DIR
# A developer's exported omp agent dir would point a dry-run at the real omp
# config; tests that need one pass PI_CODING_AGENT_DIR=... as a per-call prefix.
unset PI_CODING_AGENT_DIR
# A git hook (lefthook pre-push) exports GIT_DIR and friends; a sandbox 'git init'
# under them would write into this checkout's repository (even set core.bare).
while IFS= read -r git_var; do unset "${git_var}"; done < <(git rev-parse --local-env-vars)
unset git_var

SANDBOX_ROOT="$(mktemp -d)"
INSTALL_TESTS_FINISHED=0
# on_exit — drop the sandbox; a run that exits before install_tests_finish
# (an 'exit' or 'set -u' abort inside a suite) fails instead of passing silently.
on_exit() {
    local rc=$?
    rm -rf "${SANDBOX_ROOT}"
    if [[ ${INSTALL_TESTS_FINISHED} -eq 0 ]]; then
        printf '%s[FAIL]%s install tests aborted before the totals (exit %d)\n' "${RED}" "${NC}" "${rc}" >&2
        [[ ${rc} -eq 0 ]] && rc=1
    fi
    exit "${rc}"
}
trap on_exit EXIT

# new_home — create an isolated HOME and echo its path.
new_home() {
    local home
    home="$(mktemp -d "${SANDBOX_ROOT}/home.XXXXXX")"
    mkdir -p "${home}/.claude" "${home}/.codex" "${home}/.cursor" "${home}/.config/opencode" "${home}/project"
    echo "${home}"
}

# Stub 'claude' and 'codex' CLIs record their arguments, so plugin steps are
# checked without touching a real plugin registry.
STUB_BIN="${SANDBOX_ROOT}/stub-bin"
mkdir -p "${STUB_BIN}"
cat > "${STUB_BIN}/claude" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    printf '%s\n' "${CLAUDE_STUB_VERSION:-2.1.310 (Claude Code)}"
    exit 0
fi
printf '%s\n' "$*" >> "${CLAUDE_STUB_LOG}"
if [[ "$*" == "plugin marketplace list --json" ]]; then
    printf '%s\n' "${CLAUDE_STUB_MARKETPLACES:-[]}"
    exit "${CLAUDE_STUB_MARKETPLACES_STATUS:-0}"
fi
SH
cat > "${STUB_BIN}/codex" <<'SH'
#!/usr/bin/env bash
[[ " $* " == *" --help "* ]] && exit 0
printf 'codex %s\n' "$*" >> "${CLAUDE_STUB_LOG}"
SH
# style.sh needs ruff/black on PATH when install runs its repo-style step;
# the tests assert placement, not formatting, so no-op them.
cat > "${STUB_BIN}/ruff" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "${STUB_BIN}/black" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "${STUB_BIN}/claude" "${STUB_BIN}/codex" "${STUB_BIN}/ruff" "${STUB_BIN}/black"
# Stateful fake omp (fake_omp.py, version 18.12.3 unless FAKE_OMP_VERSION says
# otherwise). It shadows a real omp on PATH; its state lives in FAKE_OMP_HOME
# and every call is logged to CLAUDE_STUB_LOG as 'omp <args>'.
cat > "${STUB_BIN}/omp" <<SH
#!/usr/bin/env bash
exec python3 "${REPO_ROOT}/scripts/tests/install/fake_omp.py" "\$@"
SH
chmod +x "${STUB_BIN}/omp"

# run_install <home> <args...> — run install.sh sandboxed; print output and return the installer status.
# Runs from <home>/project (not a git repo) so project-scoped steps write
# there and never into this checkout. Installs the bundles as committed
# (YCC_INSTALL_SKIP_BUILD=1) unless the caller's environment says otherwise;
# build.sh covers the real generate/validate/format steps once per target.
run_install() {
    local home="$1" out rc=0
    shift
    out="$(
        cd "${home}/project" || exit 1
        # A caller's omp overrides would escape the stub and the sandbox.
        unset OMP_BIN OMP_PROFILE FAKE_OMP_LOG
        HOME="${home}" \
        PATH="${STUB_BIN}:${PATH}" \
        CLAUDE_STUB_LOG="${home}/claude-calls.log" \
        FAKE_OMP_HOME="${home}/.fake-omp" \
        YCC_MANAGED_CONFIG_STATE="${home}/.config/ycc/managed-config-state.json" \
        YCC_INSTALL_SKIP_BUILD="${YCC_INSTALL_SKIP_BUILD:-1}" \
            bash "${INSTALL}" "$@" 2>&1
    )" || rc=$?
    [[ -n "${out}" ]] && printf '%s\n' "${out}"
    return "${rc}"
}

# install_must_succeed <home> <args...> — checked success-path invocation.
# Run in the current shell and leave captured output in INSTALL_OUT. On failure,
# report the original diagnostic and stop before placement assertions, preserving
# the installer status. Expected rejections keep using run_install.
INSTALL_OUT=""
install_must_succeed() {
    local rc=0
    INSTALL_OUT="$(run_install "$@")" || rc=$?
    if [[ ${rc} -ne 0 ]]; then
        printf '%s[FAIL]%s install.sh %s exited %d\n%s\n' "${RED}" "${NC}" "${*:2}" "${rc}" "${INSTALL_OUT}" >&2
        exit "${rc}"
    fi
    return 0
}

# run_install_build <home> <args...> — run_install with the real bundle build
# (generators, validators and the repo style pass run against this checkout).
run_install_build() {
    YCC_INSTALL_SKIP_BUILD=0 run_install "$@"
}

# install_must_succeed_build <home> <args...> — checked real bundle build invocation.
install_must_succeed_build() {
    YCC_INSTALL_SKIP_BUILD=0 install_must_succeed "$@"
}

# checked_failure_probe <stub> <home> <skip_build> <install args...>
# Regression helper: drives a failing stub installer through
# install_must_succeed in a child bash — a cleanup-only EXIT trap keeps the
# child's sandbox from leaking while leaving the parent counters untouched —
# and appends PROBE_RC=<child status> after the child's output.
checked_failure_probe() {
    local stub="$1" home="$2" skip_build="$3"
    shift 3
    YCC_INSTALL_SKIP_BUILD="${skip_build}" bash -c '
        source "$1/scripts/tests/install/lib.sh"
        trap '\''rm -rf "${SANDBOX_ROOT}"'\'' EXIT
        INSTALL="$2"
        install_must_succeed "$3" "${@:4}"
        echo "PLACEMENT_BLOCK_RAN"
    ' _ "${REPO_ROOT}" "${stub}" "${home}" "$@" 2>&1
    echo "PROBE_RC=$?"
}

ok() {
    PASS=$((PASS + 1))
    printf '%s[pass]%s %s\n' "${GREEN}" "${NC}" "$1"
}

ko() {
    FAIL=$((FAIL + 1))
    printf '%s[FAIL]%s %s\n' "${RED}" "${NC}" "$1"
    [[ -n "${2:-}" ]] && printf '       %s\n' "$2"
}

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        ok "${name}"
    else
        ko "${name}" "expected to find: ${needle}"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" name="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        ok "${name}"
    else
        ko "${name}" "unexpectedly found: ${needle}"
    fi
}

# run_install_stubbed — alias kept for the mods tests; run_install already
# puts the stub claude/codex CLIs first on PATH.
run_install_stubbed() {
    run_install "$@"
}

# install_must_succeed_stubbed — checked variant for stubbed callers.
install_must_succeed_stubbed() {
    install_must_succeed "$@"
}

# shellcheck disable=SC2034  # read by the suites.
REPO_REAL="$(realpath "${REPO_ROOT}")"

# source_install_libs — load install.sh's libs (no side effects at source time)
# into the current shell, the same way install.sh does.
# shellcheck disable=SC1090,SC1091,SC2034  # runtime paths; the libs read SCRIPT_DIR.
source_install_libs() {
    SCRIPT_DIR="${REPO_ROOT}"
    eval "$(sed -n 's/^ALL_TARGETS=(\(.*\))$/ALL_TARGETS=(\1)/p' "${INSTALL}")"
    local f
    for f in core steps select bundle cli; do source "${REPO_ROOT}/scripts/lib/install/${f}.sh"; done
    for f in "${ALL_TARGETS[@]}"; do source "${REPO_ROOT}/scripts/lib/install/targets/${f}.sh"; done
}

# install_tests_finish — print the totals line; fail on any failure.
install_tests_finish() {
    INSTALL_TESTS_FINISHED=1
    echo
    printf 'test-install-sync: %d passed, %d failed\n' "${PASS}" "${FAIL}"
    [[ ${FAIL} -eq 0 ]]
}
