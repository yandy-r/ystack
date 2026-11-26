#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# install.sh — sync plugin assets to target IDE config directories
# ---------------------------------------------------------------------------

# Resolve symlinks so the linked `ycc` command (see 'cli') still finds the repo.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CLI_NAME="ycc"
# shellcheck disable=SC2034  # read by steps.sh (target resolution).
ALL_TARGETS=(claude cursor codex opencode agents omp antigravity)

# shellcheck source=scripts/lib/install/core.sh
source "${SCRIPT_DIR}/scripts/lib/install/core.sh"
# shellcheck source=scripts/lib/install/steps.sh
source "${SCRIPT_DIR}/scripts/lib/install/steps.sh"
# shellcheck source=scripts/lib/install/select.sh
source "${SCRIPT_DIR}/scripts/lib/install/select.sh"
# shellcheck source=scripts/lib/install/bundle.sh
source "${SCRIPT_DIR}/scripts/lib/install/bundle.sh"
# shellcheck source=scripts/lib/install/cli.sh
source "${SCRIPT_DIR}/scripts/lib/install/cli.sh"
# shellcheck source=scripts/lib/install/cleanup.sh
source "${SCRIPT_DIR}/scripts/lib/install/cleanup.sh"
# Each target implements the contract described in its targets/<t>.sh header.
for _target in "${ALL_TARGETS[@]}"; do
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/scripts/lib/install/targets/${_target}.sh"
done
unset _target

# shellcheck source=scripts/lib/install/usage.sh
source "${SCRIPT_DIR}/scripts/lib/install/usage.sh"
# shellcheck source=scripts/lib/install/args.sh
source "${SCRIPT_DIR}/scripts/lib/install/args.sh"

# shellcheck disable=SC2153  # TARGET is set by args.sh.
resolve_targets "${TARGET}"
# Before any target preflight: agents-only selections never reach a native target.
preflight_native_selections
if [[ -n "${PACKAGE}" ]]; then
    # shellcheck disable=SC2034  # read by the package preflight in packages.sh.
    [[ "${TARGET}" == "all" ]] && PACKAGE_ALL_TARGETS_REQUESTED=1
    package_preflight_targets
    order_targets
    run_package_targets
else
    order_targets
    preflight_targets
    action="sync"
    [[ "${COMMAND}" == "remove" ]] && action="remove"
    for target in "${TARGETS[@]}"; do
        run_target "${target}" "${action}_${target}_target"
    done
fi
