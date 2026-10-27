#!/usr/bin/env bash
# Verifies that every ~/.config/opencode/<root>/... reference (or its
# ${HOME}/$HOME spelling) inside
# the .opencode-plugin/ bundle is either:
#   (a) installable: <root> is in OPENCODE_BUNDLE_UNITS
#       (scripts/lib/install/targets/opencode.sh) AND
#       the backing file exists under .opencode-plugin/<root>/...
#   (b) intentionally not bundle-shipped (a user-global or runtime path
#       on the explicit allowlist).
#
# This is the regression guard for bugs where the generator emits a
# reference but the install step never copies the backing dir, or vice
# versa. Run after the other validate-opencode-*.sh scripts so structural
# problems surface first.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_ROOT="${REPO_ROOT}/.opencode-plugin"
INSTALL_SCRIPT="${REPO_ROOT}/scripts/lib/install/targets/opencode.sh"

if [[ ! -d "${BUNDLE_ROOT}" ]]; then
    echo "validate-opencode-install-coverage: ${BUNDLE_ROOT} not found" >&2
    exit 1
fi
if [[ ! -f "${INSTALL_SCRIPT}" ]]; then
    echo "validate-opencode-install-coverage: ${INSTALL_SCRIPT} not found" >&2
    exit 1
fi

echo "== Install-coverage check (~/.config/opencode/... references) =="
python3 - "${BUNDLE_ROOT}" "${INSTALL_SCRIPT}" <<'PY'
import json
import re
import sys
from pathlib import Path

bundle_root = Path(sys.argv[1])
install_script = Path(sys.argv[2])

# Single source of truth: OPENCODE_BUNDLE_UNITS in the opencode target lib
# (the full list is what 'base' rsyncs; sync and remove both read it).
text = install_script.read_text(encoding="utf-8")
match = re.search(r"^OPENCODE_BUNDLE_UNITS=\(([a-z_ -]+)\)$", text, re.M)
if not match:
    print(
        f"FAIL: could not find OPENCODE_BUNDLE_UNITS=(...) in {install_script} — "
        "validator cannot determine what the installer actually copies.",
        file=sys.stderr,
    )
    sys.exit(1)
MANAGED_UNITS = set(match.group(1).split())

# Roots intentionally NOT bundle-shipped: user-global directories that
# the user maintains outside the plugin, or runtime/state paths the
# plugin only reads/writes at runtime.
ALLOWLIST_ROOTS = {
    "sessions",         # runtime session state
    "session-data",     # runtime session state
    "plugins",          # opencode's own plugin install/cache location (read at runtime, not bundle-shipped)
    "mcp-library",      # user-maintained MCP library (read by init, never bundle-shipped)
}
# Top-level files installed directly (bypassing the bundle-unit
# rsync). These exist at .opencode-plugin/<file> as plain top-level
# files; install.sh copies / symlinks them in dedicated steps.
ALLOWLIST_FILES = {
    "opencode.json",
    "AGENTS.md",
    "settings.json",                # user opencode settings, not shipped
    "settings-hooks-fragment.json", # generated hook fragment, not shipped
}

# Match ~/.config/opencode/<root>(/<rest>)? and the ${HOME}/$HOME spellings
# that generated shell scripts use (a quoted ~ is never expanded).
# - <root> is one path segment of normal name characters
# - <rest> is greedy across path-safe characters; may include trailing /
PATH_RE = re.compile(
    r"(?:~|\$\{HOME\}|\$HOME)/\.config/opencode/([A-Za-z0-9._-]+)(?:/([A-Za-z0-9._/-]*))?"
)

unknown_roots: dict[str, str] = {}    # root -> first .opencode-plugin file referencing it
missing_targets: list[tuple[str, str, str]] = []  # (src, raw_ref, expected_path)

for path in sorted(bundle_root.rglob("*")):
    if not path.is_file():
        continue
    try:
        body = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    for m in PATH_RE.finditer(body):
        root = m.group(1)
        rest = m.group(2) or ""
        if root in ALLOWLIST_FILES or root in ALLOWLIST_ROOTS:
            continue
        if root not in MANAGED_UNITS:
            unknown_roots.setdefault(root, str(path.relative_to(bundle_root)))
            continue
        # Strip a trailing slash so "skills/init/templates/" resolves to
        # the directory rather than a non-existent path with empty tail.
        rest_clean = rest.rstrip("/")
        if rest_clean:
            target = bundle_root / root / rest_clean
        else:
            target = bundle_root / root
        if not target.exists():
            missing_targets.append(
                (
                    str(path.relative_to(bundle_root)),
                    m.group(0),
                    str(target.relative_to(bundle_root.parent)),
                )
            )

failed = False

if unknown_roots:
    failed = True
    print(
        "FAIL: bundle references roots that are neither in "
        "OPENCODE_BUNDLE_UNITS nor on the allowlist:",
        file=sys.stderr,
    )
    for root, src in sorted(unknown_roots.items()):
        print(
            f"  ~/.config/opencode/{root}/... "
            f"(first seen in .opencode-plugin/{src})",
            file=sys.stderr,
        )
    print(
        "  Fix: either add the dir to OPENCODE_BUNDLE_UNITS in "
        "scripts/lib/install/targets/opencode.sh "
        "(if the plugin should ship it) or add it to ALLOWLIST_ROOTS / "
        "ALLOWLIST_FILES in this validator (if it is user-global).",
        file=sys.stderr,
    )

if missing_targets:
    failed = True
    print(
        "FAIL: bundle references files that do not exist in "
        ".opencode-plugin/:",
        file=sys.stderr,
    )
    for src, ref, expected in missing_targets:
        print(f"  .opencode-plugin/{src}", file=sys.stderr)
        print(f"    references: {ref}", file=sys.stderr)
        print(f"    expected:   {expected}", file=sys.stderr)
    print(
        "  Fix: regenerate the bundle (./scripts/sync.sh --only opencode) "
        "or update the source skill/agent/command to point at a path that "
        "actually ships.",
        file=sys.stderr,
    )

# Every bundle directory must be a unit 'base' mirrors, and every local
# `./<dir>` plugins entry in opencode.json must name one (OpenCode resolves it
# from ~/.config/opencode and only logs a warning when it is missing).
unshipped_dirs = sorted(
    path.name for path in bundle_root.iterdir() if path.is_dir() and path.name not in MANAGED_UNITS
)
if unshipped_dirs:
    failed = True
    print(
        "FAIL: .opencode-plugin/ directories missing from OPENCODE_BUNDLE_UNITS: " + ", ".join(unshipped_dirs),
        file=sys.stderr,
    )

config = json.loads((bundle_root / "opencode.json").read_text(encoding="utf-8"))
for entry in config.get("plugins", []):
    spec = entry if isinstance(entry, str) else entry.get("package") if isinstance(entry, dict) else None
    if not isinstance(spec, str) or not spec.startswith("./"):
        continue
    name = spec[2:].rstrip("/")
    if "/" in name or name not in MANAGED_UNITS or not (bundle_root / name).is_dir():
        failed = True
        print(
            f"FAIL: opencode.json plugins entry {spec!r} must name a top-level bundle unit "
            "listed in OPENCODE_BUNDLE_UNITS with a backing .opencode-plugin/ directory",
            file=sys.stderr,
        )

if failed:
    sys.exit(1)

print(
    f"OK: every ~/.config/opencode/<root>/... reference in "
    f"{bundle_root.name}/ resolves to a backing file or an allowlisted "
    f"user-global path."
)
PY
