#!/usr/bin/env bash
# install.sh tests — bundle build: every target that installs a locally
# generated bundle (codex, opencode's npm package, agents, omp) regenerates, validates and
# formats it before syncing, and YCC_INSTALL_SKIP_BUILD=1 installs the
# committed bundle instead. cursor builds nothing: it registers the published
# marketplace.
#
# Runs alone (bash scripts/tests/install/build.sh) or from scripts/test-install-sync.sh.
# shellcheck source=scripts/tests/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Generator/validator passes a native base install runs, per target.
declare -A BUILD_PASSES=(
    [codex]="skills plugin"
    [opencode]="package"
    [agents]="skills"
    [omp]="skills agents commands packages"
)

# codex_bundle_landed <home> — ycc@ycc installed through the (stubbed) Codex CLI.
codex_bundle_landed() {
    grep -q "codex plugin add ycc@ycc" "$1/claude-calls.log" 2>/dev/null
}

# cursor_marketplace_landed <home> — the (stubbed) agent CLI registered the marketplace.
cursor_marketplace_landed() {
    grep -q "agent plugin marketplace add" "$1/claude-calls.log" 2>/dev/null
}

# opencode_package_landed <home> — the base step wrote the file:// plugins entry.
opencode_package_landed() {
    grep -q "file://${REPO_ROOT}/packages/opencode/ycc-opencode" "$1/.config/opencode/opencode.json" 2>/dev/null
}

# omp_bundle_landed <home> — the native OMP install (fake omp) ran from the export.
omp_bundle_landed() {
    grep -q "omp plugin install --scope user ycc@ycc" "$1/claude-calls.log" 2>/dev/null
}

echo "== install.sh install: base builds each bundle before syncing =="

home="$(new_home)"
install_must_succeed_build "${home}" install --target cursor,codex,opencode,agents,omp --only base
out="${INSTALL_OUT}"
ok "base install with the real build succeeds"
for target in codex opencode agents omp; do
    for pass in ${BUILD_PASSES[${target}]}; do
        assert_contains "${out}" "Running generate-${target}-${pass}.sh" "${target} build runs generate-${target}-${pass}.sh"
        assert_contains "${out}" "Running validate-${target}-${pass}.sh" "${target} build runs validate-${target}-${pass}.sh"
    done
done
assert_contains "${out}" "Running scripts/style.sh format --modified" "build formats modified repository files"
assert_not_contains "${out}" "Skipping" "real build skips nothing"
assert_not_contains "${out}" "generate-cursor-" "cursor builds no bundle"
if [[ -f "${home}/.agents/skills/backport/SKILL.md" ]] && opencode_package_landed "${home}" \
    && codex_bundle_landed "${home}" && omp_bundle_landed "${home}" && cursor_marketplace_landed "${home}"; then
    ok "built bundles land in every target"
else
    ko "built bundles land in every target"
fi

echo
echo "== install.sh install: YCC_INSTALL_SKIP_BUILD=1 installs the committed bundle =="

home="$(new_home)"
YCC_INSTALL_SKIP_BUILD=1 install_must_succeed "${home}" install --target cursor,codex,opencode,agents,omp --only base
out="${INSTALL_OUT}"
for target in codex opencode agents omp; do
    for pass in ${BUILD_PASSES[${target}]}; do
        assert_contains "${out}" "Skipping generate-${target}-${pass}.sh" "skip-build skips generate-${target}-${pass}.sh"
        assert_contains "${out}" "Skipping validate-${target}-${pass}.sh" "skip-build skips validate-${target}-${pass}.sh"
    done
done
assert_contains "${out}" "Skipping repository formatting" "skip-build skips the repo style pass"
assert_not_contains "${out}" "Running " "skip-build runs no build script"
if [[ -f "${home}/.agents/skills/backport/SKILL.md" ]] && opencode_package_landed "${home}" \
    && codex_bundle_landed "${home}" && omp_bundle_landed "${home}" && cursor_marketplace_landed "${home}"; then
    ok "skip-build still syncs every target"
else
    ko "skip-build still syncs every target"
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_tests_finish; fi
