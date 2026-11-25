#!/usr/bin/env bash
# release-feature-sets.sh — group feat commits since the last tag into feature
# sets and compute the minimum semver bump. A feat commit alone does not force a
# minor: only feature sets the maintainer names complete (--complete) do.
#
# Usage:
#   release-feature-sets.sh [--repo DIR] [--from REF] [--to REF]
#                           [--complete SET[,SET...]|all] [--format json|text]
#
# Feature set = `Feature-Set:` trailer, else the commit scope, else `unscoped`.
# Required bump: major (breaking) > minor (a set is complete) > patch > none.
# Requires python3 3.11+. Exit codes: 0 ok, 1 usage error, git error or unknown set.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=require-python.sh
. "${SCRIPT_DIR}/require-python.sh"
export PYTHONDONTWRITEBYTECODE=1
exec python3 "${SCRIPT_DIR}/release_feature_sets.py" "$@"
