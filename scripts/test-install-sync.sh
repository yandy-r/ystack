#!/usr/bin/env bash
# Behavioral tests for install.sh argument parsing, intent mapping and the
# per-target install/sync/remove steps.
#
# Runs every suite under scripts/tests/install/ in one shell (shared sandbox
# and counters). A single suite also runs alone, e.g.
#   bash scripts/tests/install/codex.sh
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tests/install"
# shellcheck source=scripts/tests/install/lib.sh
source "${TESTS_DIR}/lib.sh"

for suite in core mcps select slices-select claude cursor codex opencode opencode-catalog agents omp dry-run packages migrate build; do
    # shellcheck source=/dev/null
    source "${TESTS_DIR}/${suite}.sh" || ko "suite ${suite}.sh ran to the end" "source returned $?"
done

install_tests_finish
