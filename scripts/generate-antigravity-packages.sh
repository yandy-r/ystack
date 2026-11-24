#!/usr/bin/env bash
# Generate the Google Antigravity plugins under packages/antigravity/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/generate_antigravity_packages.py" "$@"
