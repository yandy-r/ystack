#!/usr/bin/env bash
# Validate the generated Muse Code plugins under packages/muse/: generator drift
# (bytes and modes), manifest / skill / agent / MCP policy plus a live
# `muse plugins validate` when muse is on PATH
# (scripts/test_generate_muse_packages.py) and the install helper.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Sync check (generator --check) =="
python3 "${SCRIPT_DIR}/generate_muse_packages.py" --check

echo "== Generator policy, golden and live muse validate checks =="
python3 "${SCRIPT_DIR}/test_generate_muse_packages.py"

echo "== Install helper (owned copies, muse plugin calls, ownership) =="
python3 "${SCRIPT_DIR}/test_muse_install.py"
