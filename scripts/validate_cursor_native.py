#!/usr/bin/env python3
"""Validate Cursor-native payloads and the listed catalog against vendored schemas."""

from __future__ import annotations

import json
import re
import stat
import sys
from collections.abc import Iterable
from pathlib import Path
from typing import Any

from generate_cursor_packages import (
    MARKETPLACE_PATH,
    MIN_CURSOR_VERSION,
    OUTPUT_ROOT,
    REPO_ROOT,
    SCHEMA_DIR,
    SUPPORTED_HOOK_EVENTS,
    build_marketplace,
    cursor_runtime,
    native_packages,
)
from jsonschema import Draft7Validator, FormatChecker
from package_model import PackageModel, load_package_model

ROOT_REF = re.compile(r"\$\{CURSOR_PLUGIN_ROOT\}/([^\s\"'`)>\]\\]+)")
HOME_REF = re.compile(r"(?:~|\$\{?HOME\}?)/\.cursor/([A-Za-z0-9_./-]+)")
INSTALLER_ONLY_HOME = ("agents/", "skills/", "mcp-library", "plugins/")


class ValidationInputError(ValueError):
    """An unreadable or malformed validation input."""


def load(path: Path) -> dict[str, Any]:
    """Load a JSON object from ``path``, raising ValidationInputError when malformed."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValidationInputError(f"{path}: unreadable or malformed JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise ValidationInputError(f"{path}: expected a JSON object, got {type(data).__name__}")
    return data


def _resource_target(ref: str) -> str:
    """Cut a reference to its literal prefix before any glob/brace/placeholder."""
    target = ref.split("#")[0].split(":")[0].rstrip(".,;/")
    literal = re.split(r"[*?[{<]", target, maxsplit=1)[0].rstrip("/")
    return literal


def resource_errors(root: Path) -> list[str]:
    errors: list[str] = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        for ref in ROOT_REF.findall(text):
            target = _resource_target(ref)
            if not target:
                continue
            resolved = (root / target).resolve()
            if not resolved.is_relative_to(root.resolve()):
                errors.append(f"{path}: plugin reference escapes its package: {ref}")
                continue
            if resolved.exists():
                continue
            errors.append(f"{path}: unresolved ${{CURSOR_PLUGIN_ROOT}}/{target}")
        # HOME rules cover instruction-bearing files the runtime executes or
        # follows as commands (scripts, SKILL.md, agents, commands). Reference
        # docs that merely describe the file-copy installer contract are exempt.
        if not path.name.endswith((".sh", ".mdc")) and path.name not in {"SKILL.md"}:
            continue
        if "/_shared/references/" in path.as_posix():
            continue
        for ref in HOME_REF.findall(text):
            if ref.startswith(INSTALLER_ONLY_HOME):
                errors.append(f"{path}: installer-only $HOME/.cursor/{ref} cannot be the required native resource")
    return errors


def plugin_schema_validator() -> Draft7Validator:
    """Draft-7 validator for plugin manifests (vendored cursor/plugins schema)."""
    return Draft7Validator(load(SCHEMA_DIR / "plugin.schema.json"), format_checker=FormatChecker())


def marketplace_schema_validator() -> Draft7Validator:
    """Draft-7 validator for the root marketplace file (vendored cursor schema)."""
    return Draft7Validator(load(SCHEMA_DIR / "marketplace.schema.json"), format_checker=FormatChecker())


def _plugin_errors(
    package_key: str,
    runtime_components: Iterable[str],
    manifest_path: Path,
    manifest: dict[str, Any],
    version: str | None,
    validator: Draft7Validator,
) -> list[str]:
    errors: list[str] = []
    package_dir = manifest_path.parent.parent
    components = set(runtime_components)
    errors.extend(f"{manifest_path}: {error.message}" for error in validator.iter_errors(manifest))
    if manifest.get("name") != package_key or (version is not None and manifest.get("version") != version):
        errors.append(f"{manifest_path}: name/version must follow the package model")
    if manifest.get("minClientVersions") != {"cursor": MIN_CURSOR_VERSION}:
        errors.append(f"{manifest_path}: minClientVersions.cursor must be {MIN_CURSOR_VERSION}")
    if components == {"hooks"}:
        hooks = load(package_dir / "hooks/hooks.json").get("hooks", {})
        if not isinstance(hooks, dict) or set(hooks) != SUPPORTED_HOOK_EVENTS:
            errors.append(f"{package_key}: hooks must register {sorted(SUPPORTED_HOOK_EVENTS)} only")
        script = package_dir / "hooks/herdr-session-start.sh"
        if not script.is_file() or not script.stat().st_mode & stat.S_IXUSR:
            errors.append(f"{script}: must exist and be executable")
    if components == {"mcp"}:
        variables = manifest.get("variables")
        properties = variables.get("properties") if isinstance(variables, dict) else None
        declared = set(properties) if isinstance(properties, dict) else set()
        try:
            mcp = load(package_dir / "mcp.json")
        except ValidationInputError as exc:
            errors.append(str(exc))
        else:
            used = set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", json.dumps(mcp)))
            if declared != used:
                errors.append(f"{package_key}: MCP placeholders must all be declared variables")
        if manifest.get("mcpServers") != "./mcp.json":
            errors.append(f"{package_key}: mcpServers must point at ./mcp.json")
    return errors


def cursor_native_errors(root: Path, model: PackageModel) -> list[str]:
    """Validate the generated Cursor-native packages rooted at ``root``.

    A root marketplace exists exactly when included native packages are listed,
    matches that selection and its package-root sources exactly, and satisfies
    the vendored schema. Package manifests, hooks, MCP wiring, and resource
    references are checked for every included native package in ``model``,
    independently of listing. Malformed inputs become diagnostics, not tracebacks.
    """
    errors: list[str] = []
    validator = plugin_schema_validator()
    version: str | None = None
    try:
        source = load(root / model.version_source)
        raw_version = source.get("version")
        if not isinstance(raw_version, str) or not raw_version.strip():
            raise ValidationInputError(f"{root / model.version_source}: missing nonempty version")
        version = raw_version
    except ValidationInputError as exc:
        errors.append(str(exc))
    expected_marketplace = build_marketplace(model.packages)
    marketplace = root / MARKETPLACE_PATH
    marketplace_present = marketplace.exists() or marketplace.is_symlink()
    if expected_marketplace is None and marketplace_present:
        errors.append(".cursor-plugin/marketplace.json must not exist when no Cursor packages are listed")
    if marketplace.is_symlink() or marketplace.parent.is_symlink():
        errors.append(f"{MARKETPLACE_PATH}: managed-path symlink is not allowed")
    elif marketplace_present or expected_marketplace is not None:
        try:
            data = load(marketplace)
        except ValidationInputError as exc:
            errors.append(str(exc))
        else:
            errors.extend(
                f"{marketplace}: {error.message}" for error in marketplace_schema_validator().iter_errors(data)
            )
            if expected_marketplace is not None and data != expected_marketplace:
                errors.append(f"{MARKETPLACE_PATH}: catalog must match exactly the listed Cursor packages and sources")
    for package in native_packages(model.packages):
        runtime = cursor_runtime(package)
        assert runtime is not None
        package_root = root / OUTPUT_ROOT / package.key
        manifest_path = package_root / ".cursor-plugin/plugin.json"
        if not manifest_path.is_file():
            errors.append(f"{manifest_path.relative_to(root)}: missing")
            continue
        try:
            manifest = load(manifest_path)
            errors.extend(_plugin_errors(package.key, runtime.components, manifest_path, manifest, version, validator))
        except ValidationInputError as exc:
            errors.append(str(exc))
        errors.extend(resource_errors(package_root))
    return errors


def main(root: Path = REPO_ROOT, model: PackageModel | None = None) -> int:
    """Validate ``root`` and print diagnostics; exit 1 on any error."""
    try:
        root = Path(root)
        checked_model = model
        if checked_model is None:
            checked_model = load_package_model(root / "ycc/settings/packages.json", repo_root=root)
        errors = cursor_native_errors(root, checked_model)
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"validate_cursor_native: {exc}", file=sys.stderr)
        return 1
    for error in errors:
        print(f"validate_cursor_native: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
