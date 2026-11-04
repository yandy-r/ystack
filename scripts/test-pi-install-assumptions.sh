#!/usr/bin/env bash
# test-pi-install-assumptions.sh — PI1 fixture coverage for
# ycc/skills/compatibility-audit/scripts/audit-install-assumptions.sh (YAN-1183).
#
# PI1 ties the matrix `pi` column to the generated packages/pi/ tree and fails
# closed both ways (ADR 0003): with no tree every pi verdict must be
# `unsupported`; with a tree INSTALL_PATH:pi must not be `unsupported`.
# Each case builds a throwaway repo root holding .claude-plugin/marketplace.json
# and a copy of the checked-in matrix with the pi column rewritten.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="${REPO_ROOT}/ycc/skills/compatibility-audit/scripts/audit-install-assumptions.sh"
MATRIX_REL="ycc/skills/_shared/references/target-capability-matrix.md"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ycc-pi1.XXXXXX")"
trap 'rm -rf "${SCRATCH}"' EXIT

FAILED=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

# make_root <name> <tree:package|skills|no> <capability=verdict>... — print a
# fixture root whose pi column is `unsupported` except for the listed overrides.
# `package` writes packages/pi/ycc/package.json (installable); `skills` writes
# only packages/pi/ycc/skills (YAN-1184 output, which PI1 must treat as absent).
make_root() {
    local root="${SCRATCH}/$1" tree="$2"
    shift 2
    mkdir -p "${root}/.claude-plugin" "$(dirname "${root}/${MATRIX_REL}")"
    printf '{"name":"fixture","plugins":[]}\n' >"${root}/.claude-plugin/marketplace.json"
    python3 - "${REPO_ROOT}/${MATRIX_REL}" "${root}/${MATRIX_REL}" "$@" <<'PY' || return 1
import sys

source, dest, *overrides = sys.argv[1:]
wanted = dict(item.split("=", 1) for item in overrides)
out, header, done = [], None, False
for raw in open(source, encoding="utf-8").read().split("\n"):
    s = raw.strip()
    if done or not s.startswith("|"):
        done = done or header is not None
        out.append(raw)
        continue
    cells = [c.strip() for c in s.strip("|").split("|")]
    if header is None:
        header = cells
    elif not all(c and set(c) == {"-"} for c in cells):
        cells[header.index("pi")] = wanted.get(cells[0], "unsupported")
    out.append("| " + " | ".join(cells) + " |")
open(dest, "w", encoding="utf-8").write("\n".join(out))
PY
    case "${tree}" in
        package) mkdir -p "${root}/packages/pi/ycc" && printf '{}\n' >"${root}/packages/pi/ycc/package.json" ;;
        skills) mkdir -p "${root}/packages/pi/ycc/skills" ;;
        no) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "${root}"
}

# expect <label> <want-rc> <want-status> <root> <token>... — PI1 must report
# want-status with every stable token in its detail line.
expect() {
    local label="$1" want_rc="$2" want="$3" root="$4" out rc=0 line token
    shift 4
    out="$(bash "${AUDIT}" --target=pi "${root}" 2>&1)" || rc=$?
    line="$(grep -F "[pi] PI1 ${want}" <<<"${out}" || true)"
    if [[ "${rc}" -ne "${want_rc}" || -z "${line}" ]]; then
        fail "${label} (rc=${rc}, want ${want_rc} ${want}): ${out}"
        return
    fi
    for token in "$@"; do
        if [[ "${line}" != *"${token}"* ]]; then
            fail "${label}: missing ${token@Q} in ${line}"
            return
        fi
    done
    pass "${label}"
}

root="$(make_root absent-ok no)" || exit 1
expect "no tree, every pi verdict unsupported passes" 0 PASS "${root}" "packages/pi"
root="$(make_root absent-claim no SKILLS=partial)" || exit 1
expect "no tree, a partial pi verdict fails" 1 FAIL "${root}" "SKILLS" "does not exist"
root="$(make_root skills-only skills INSTALL_PATH=partial)" || exit 1
expect "skills-only tree (no package.json) counts as absent" 1 FAIL "${root}" "INSTALL_PATH" "does not exist"
root="$(make_root present-unsupported package)" || exit 1
expect "installable tree, INSTALL_PATH:pi unsupported fails" 1 FAIL "${root}" "INSTALL_PATH:pi" "exists"
root="$(make_root present-ok package INSTALL_PATH=partial)" || exit 1
expect "installable tree, INSTALL_PATH:pi partial passes" 0 PASS "${root}"

[[ "${FAILED}" -eq 0 ]] && echo "test-pi-install-assumptions: all passed"
exit "${FAILED}"
