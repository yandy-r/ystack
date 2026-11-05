#!/usr/bin/env bash
# Verify the generated opencode npm package (packages/opencode/ycc-opencode)
# matches its generator output.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "${REPO_ROOT}/scripts/generate_opencode_package.py" --check "$@"
