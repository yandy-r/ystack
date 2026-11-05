#!/usr/bin/env bash
# install.sh tests — automatic legacy cleanup plumbing: there is no 'migrate'
# subcommand; run_legacy_cleanup (scripts/lib/install/cleanup.sh) drives the
# internal scripts/install_migrate.py helper, which applies by default and
# previews with --dry-run. Target-specific cleanup fixtures live in each
# target's suite (claude.sh, codex.sh, cursor.sh, omp.sh).
#
# Runs alone (bash scripts/tests/install/cleanup.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== install.sh: no migrate subcommand =="
home="$(new_home)"
if out="$(run_install "${home}" migrate --target claude)"; then
    ko "migrate is rejected"
else
    assert_contains "${out}" "'migrate' was removed in v6.3.0" "migrate is rejected with the removal notice"
    assert_contains "${out}" "install --target claude" "migrate rejection points at install"
fi
help="$(bash "${INSTALL}" --help)"
assert_not_contains "${help}" "migrate" "help never mentions migrate"

echo
echo "== run_legacy_cleanup: helper invocation =="
# A stand-in install_migrate.py records its argv, so the flags are checked
# without touching HOME or a plugin CLI.
cleanup_root="$(mktemp -d "${SANDBOX_ROOT}/cleanup.XXXXXX")"
mkdir -p "${cleanup_root}/scripts"
cat > "${cleanup_root}/scripts/install_migrate.py" <<'PY'
import sys
print("ARGV " + " ".join(sys.argv[1:]))
sys.exit(int(__import__("os").environ.get("FAKE_CLEANUP_RC", "0")))
PY
# cleanup_call <env assignments...> -- <target> — run run_legacy_cleanup in a
# child shell with the stand-in helper; prints its output and returns its status.
# shellcheck disable=SC2016  # the snippet expands in the child bash.
cleanup_call() {
    local -a assigns=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do assigns+=("$1"); shift; done
    shift
    env "${assigns[@]}" bash -c '
        set -euo pipefail
        SCRIPT_DIR="$1"
        source "$2/scripts/lib/install/core.sh"
        source "$2/scripts/lib/install/cleanup.sh"
        SCRIPT_DIR="$3"
        run_legacy_cleanup "$4"
    ' _ "${REPO_ROOT}" "${REPO_ROOT}" "${cleanup_root}" "$1" 2>&1
}

out="$(cleanup_call COMMAND=install DRY_RUN=0 -- claude)"
assert_contains "${out}" "ARGV --targets claude" "install applies by default"
assert_not_contains "${out}" "--dry-run" "install passes no --dry-run"
assert_not_contains "${out}" "--removing" "install passes no --removing"
out="$(cleanup_call COMMAND=sync DRY_RUN=1 -- codex)"
assert_contains "${out}" "ARGV --targets codex --dry-run" "--dry-run previews the cleanup"
out="$(cleanup_call COMMAND=remove DRY_RUN=0 -- cursor)"
assert_contains "${out}" "ARGV --targets cursor --removing" "remove marks the cleanup as removing"
proj="$(mktemp -d "${SANDBOX_ROOT}/proj.XXXXXX")"
out="$(cd "${proj}" && cleanup_call COMMAND=install DRY_RUN=0 -- omp)"
assert_contains "${out}" "--project-root ${proj}" "omp cleanup uses the installer's project root"
out="$(cleanup_call COMMAND=install DRY_RUN=0 -- claude)"
assert_not_contains "${out}" "--project-root" "only omp passes the project root"
if out="$(cleanup_call COMMAND=install DRY_RUN=0 FAKE_CLEANUP_RC=1 -- claude)"; then
    ko "a refused cleanup fails the caller"
else
    ok "a refused cleanup fails the caller"
fi
if out="$(cleanup_call COMMAND=install DRY_RUN=0 -- opencode)"; then
    ko "cleanup rejects targets without a native route"
else
    assert_contains "${out}" "not supported for target 'opencode'" "cleanup rejects targets without a native route"
fi

echo
echo "== install_migrate.py: arguments =="
helper="${REPO_ROOT}/scripts/install_migrate.py"
for target in opencode agents bogus; do
    if out="$(HOME="${home}" python3 "${helper}" --targets "${target}" --dry-run 2>&1)"; then
        ko "helper rejects ${target}"
    else
        assert_contains "${out}" "unsupported cleanup targets" "helper rejects ${target}"
    fi
done
for flag in --apply "--marketplace-source ${REPO_ROOT}"; do
    # shellcheck disable=SC2086  # the flag and its value split on purpose.
    if HOME="${home}" python3 "${helper}" --targets claude ${flag} >/dev/null 2>&1; then
        ko "helper rejects removed ${flag%% *}"
    else
        ok "helper rejects removed ${flag%% *}"
    fi
done

# A dry-run on an empty HOME writes nothing (not even ownership state).
home="$(new_home)"
before="$(cd "${home}" && find . -printf '%p %y %m\n' | sort)"
out="$(HOME="${home}" python3 "${helper}" --targets claude --dry-run 2>&1)"
assert_contains "${out}" "Legacy cleanup dry-run" "helper --dry-run announces a preview"
if [[ "$(cd "${home}" && find . -printf '%p %y %m\n' | sort)" == "${before}" ]]; then
    ok "helper --dry-run writes nothing"
else
    ko "helper --dry-run writes nothing"
fi

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then install_tests_finish; fi
