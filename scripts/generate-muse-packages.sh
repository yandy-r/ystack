#!/usr/bin/env bash
# Generate the Muse Code plugins under packages/muse/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/generate_muse_packages.py" "$@"
