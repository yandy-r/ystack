#!/usr/bin/env bash
# Validate the generated Google Antigravity plugins under packages/antigravity/:
# generator drift (bytes and modes), plugin.json / skill / agent / rule / MCP
# policy (scripts/test_generate_antigravity_packages.py) and the install helper.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Sync check (generator --check) =="
python3 "${SCRIPT_DIR}/generate_antigravity_packages.py" --check

echo "== Generator policy and golden checks =="
python3 "${SCRIPT_DIR}/test_generate_antigravity_packages.py"

echo "== Install helper (copy and agy routes, ownership) =="
python3 "${SCRIPT_DIR}/test_antigravity_install.py"
