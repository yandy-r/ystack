#!/usr/bin/env bash
# Ensure docs/inventory.json and README generated regions match generator output.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INVENTORY_JSON="${REPO_ROOT}/docs/inventory.json"

if [[ ! -f "${INVENTORY_JSON}" ]]; then
  echo "validate-inventory.sh: ${INVENTORY_JSON} missing — run ./scripts/generate-inventory.sh first." >&2
  exit 1
fi

echo "== Sync check (generator --check) =="
python3 "${REPO_ROOT}/scripts/generate_inventory.py" --check

echo "== Purpose summary unit tests =="
python3 "${REPO_ROOT}/scripts/test_generate_inventory.py"

echo "== JSON validity =="
python3 -m json.tool "${INVENTORY_JSON}" > /dev/null
echo "OK: docs/inventory.json is valid JSON."

echo "== rename-repo regressions =="
"${REPO_ROOT}/scripts/test-rename-repo.sh"

echo "OK: inventory is in sync with source tree."
