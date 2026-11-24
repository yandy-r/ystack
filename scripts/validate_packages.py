#!/usr/bin/env python3
"""Check package-model parity with native manifests, component trees and catalogs.

Included native packages must exist even while unlisted. Codex retains its
legacy combined ycc payload and catalog while no native Codex package is listed.
Listed rows drive the native Codex and Cursor catalogs; file-copy/npm rows do not.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import generate_codex_plugin as codex
import generate_cursor_packages as cursor
from package_model import PackageModel, load_package_model

REPO_ROOT = Path(__file__).resolve().parent.parent
ROOTS = {
    "claude": Path("packages/claude"),
    "cursor": Path("packages/cursor"),
    "codex": Path(".codex-plugin"),
    "antigravity": Path("packages/antigravity"),
}
# Antigravity reads plugin.json at the plugin root (no dot-folder).
MANIFESTS = {
    runtime: Path("plugin.json") if runtime == "antigravity" else Path(f".{runtime}-plugin/plugin.json")
    for runtime in ROOTS
}
CLAUDE_CATALOG = Path(".claude-plugin/marketplace.json")
CURSOR_CATALOG = Path(".cursor-plugin/marketplace.json")


def load_object(path: Path) -> dict:
    """Load a JSON object; raise ValueError (with the path) when unreadable or malformed."""
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"{path}: unreadable or malformed JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return payload


# Every schema Component the validator can locate in a native tree. A recognized
# component present on disk but absent from the modeled row is drift.
RECOGNIZED_COMPONENTS = (
    "skills",
    "agents",
    "commands",
    "shared",
    "mcp",
    "hooks",
    "rules",
    "instructions",
    "settings",
    "statusline",
)
# Pre-existing, intentionally unmodeled content of the canonical source package
# (ycc/rules, ycc/settings) and the legacy combined Codex export (.mcp.json).
UNMODELED_COMPONENT_EXCEPTIONS: dict[tuple[str, str], frozenset[str]] = {
    ("ycc", "claude"): frozenset({"rules", "settings"}),
    ("ycc", "codex"): frozenset({"mcp"}),
}


def package_root(key: str, runtime: str) -> Path:
    return Path("ycc") if (key, runtime) == ("ycc", "claude") else ROOTS[runtime] / key


def component_path(component: str, runtime: str) -> str:
    if component == "mcp":
        return {"cursor": "mcp.json", "antigravity": "mcp_config.json"}.get(runtime, ".mcp.json")
    if component == "shared":
        return {"codex": "shared", "antigravity": "ycc-shared"}.get(runtime, "skills/_shared")
    return component


def _native_tree_errors(root: Path, model: PackageModel) -> list[str]:
    errors: list[str] = []
    for runtime, container in ROOTS.items():
        included = {
            package.key: entry
            for package in model.packages
            for entry in package.runtimes
            if entry.runtime == runtime and entry.mechanism == "native" and entry.status == "included"
        }
        expected = {package_root(key, runtime) / MANIFESTS[runtime] for key in included}
        actual = {
            path.relative_to(root) for path in (root / container).glob(f"*/{MANIFESTS[runtime]}") if path.is_file()
        }
        if runtime == "claude" and (root / "ycc" / MANIFESTS[runtime]).is_file():
            actual.add(Path("ycc") / MANIFESTS[runtime])
        for path in sorted(expected - actual):
            errors.append(f"{path}: missing included native manifest")
        for path in sorted(actual - expected):
            errors.append(f"{path}: unexpected or ineligible native package")
        for key, entry in included.items():
            rel = package_root(key, runtime)
            manifest = root / rel / MANIFESTS[runtime]
            if manifest.is_file():
                try:
                    if load_object(manifest).get("name") != key:
                        errors.append(f"{rel}: manifest name must match package key {key!r}")
                except ValueError as exc:
                    errors.append(str(exc))
            for component in entry.components:
                target = root / rel / component_path(component, runtime)
                exists = target.is_file() if component == "mcp" else target.is_dir()
                if not exists:
                    errors.append(f"{rel}: missing modeled {component} component ({target.relative_to(root)})")
            modeled = set(entry.components)
            allowed_extra = UNMODELED_COMPONENT_EXCEPTIONS.get((key, runtime), frozenset())
            if (key, runtime) == ("ycc", "codex") and codex.repository_native_enabled(model.packages):
                allowed_extra = frozenset()
            for component in RECOGNIZED_COMPONENTS:
                if component in modeled or component in allowed_extra:
                    continue
                target = root / rel / component_path(component, runtime)
                present = target.is_file() if component == "mcp" else target.is_dir()
                if present:
                    errors.append(f"{rel}: unmodeled {component} component present ({target.relative_to(root)})")
    return errors


def _claude_catalog_errors(root: Path, model: PackageModel) -> list[str]:
    path = root / CLAUDE_CATALOG
    try:
        entries = load_object(path).get("plugins")
    except ValueError as exc:
        return [str(exc)]
    if not isinstance(entries, list) or not all(isinstance(entry, dict) for entry in entries):
        return [f"{path}: expected a plugins array of objects"]
    errors: list[str] = []
    names = [entry.get("name") for entry in entries]
    expected_names = {
        package.key
        for package in model.packages
        for entry in package.runtimes
        if entry.runtime == "claude" and entry.listed
    }
    names_valid = all(isinstance(name, str) for name in names)
    if not names_valid or len(names) != len(expected_names) or set(names) != expected_names:
        errors.append(f"{path}: expected exactly listed Claude packages {sorted(expected_names)}")
    for entry in entries:
        name = entry.get("name")
        if names_valid and name in expected_names and entry.get("source") != f"./{package_root(name, 'claude')}":
            errors.append(f"{path}: {name}: source must point at its modeled package root")
    return errors


def validate(root: Path, model: PackageModel) -> list[str]:
    """Return every parity violation between ``model`` and the trees/catalogs under ``root``."""
    errors = _native_tree_errors(root, model)
    errors.extend(_claude_catalog_errors(root, model))

    try:
        expected_cursor = cursor.build_marketplace(model.packages)
        cursor_path = root / CURSOR_CATALOG
        if cursor_path.is_symlink() or cursor_path.parent.is_symlink():
            errors.append(f"{CURSOR_CATALOG}: managed-path symlink is not allowed")
        elif expected_cursor is None:
            if cursor_path.exists():
                errors.append(".cursor-plugin/marketplace.json must not exist when no Cursor packages are listed")
        elif load_object(cursor_path) != expected_cursor:
            errors.append(f"{cursor_path}: catalog must match exactly the listed Cursor packages and sources")
    except ValueError as exc:
        errors.append(str(exc))

    # The unlisted legacy catalog discovers the installed combined ycc, not a
    # repository tree. Once listed, compare against the model-driven native roots.
    codex_catalog = root / codex.NATIVE_MARKETPLACE
    try:
        listing_error = codex.partial_codex_listing_error(model.packages)
        if listing_error is not None:
            errors.append(listing_error)
        if load_object(codex_catalog) != codex.build_repository_marketplace(model.packages):
            errors.append(f"{codex_catalog}: catalog must match the Codex package listing state")
    except ValueError as exc:
        errors.append(str(exc))
    return errors


def main(root: Path = REPO_ROOT, model: PackageModel | None = None) -> int:
    """Validate ``root`` (default: this repository); print diagnostics, exit 1 on any error."""
    try:
        checked_model = model if model is not None else load_package_model()
        errors = validate(Path(root), checked_model)
    except (OSError, ValueError) as exc:
        print(f"validate_packages: {exc}", file=sys.stderr)
        return 1
    for error in errors:
        print(f"validate_packages: {error}", file=sys.stderr)
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
