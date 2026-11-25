#!/usr/bin/env python3
"""Generate Cursor-native packages from the package model (YAN-1132).

Writes packages/cursor/<key>/: each with .cursor-plugin/plugin.json validated
against the vendored official cursor/plugins schemas, and the components the
model selects via Cursor's default component folders (skills/, agents/,
commands/, rules/, hooks/hooks.json, mcp.json at package root).

Native payload selection keys on runtime == "cursor", status == "included",
mechanism == "native", independently of `listed`. The root marketplace is
written only when native packages are listed, and contains exactly those packages.

The installer-fallback row (file-copy) is generated separately: its config
stays byte-identical to the hand-maintained ycc/settings/cursor/cli-config.json.

All sources and metadata resolve before any destination mutation; unsupported
component sets, unknown hook events, secret literals, or a missing version
fail before the output tree is touched.
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import tempfile
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

from jsonschema import Draft7Validator, FormatChecker
from mcp_secret_audit import audit_no_secret_literals, collect_variables, load_mcp_config
from package_model import Package, PackageModel, RuntimePackage, load_package_model

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_ROOT = Path("packages/cursor")
MARKETPLACE_PATH = Path(".cursor-plugin/marketplace.json")
SOURCE_PLUGIN_PATH = Path("ycc/.claude-plugin/plugin.json")
SOURCE_MCP_PATH = Path("mcp-configs/mcp.json")
SOURCE_CLI_CONFIG_PATH = Path("ycc/settings/cursor/cli-config.json")
SOURCE_HOOKS_PATH = Path("ycc/settings/cursor/hooks.json")
SOURCE_HOOK_PATH = Path("ycc/settings/cursor/herdr-session-start.sh")

# Tested client floor: Cursor IDE 3.24.12 / agent 2026.10.14 (spike
# YAN-1124). The model's >=2.5 requirement is satisfied by 3.24.12; the spike
# establishes no older minimum.
MIN_CURSOR_VERSION = "3.24.12"

# Allowed component sets, one per supported Cursor package shape.
NATIVE_COMPONENTS = {
    frozenset({"skills", "agents", "commands", "shared"}),
    frozenset({"rules"}),
    frozenset({"mcp"}),
    frozenset({"hooks"}),
}

# Session integrations Cursor supports. Claude's settings.json registrations
# (WorktreeCreate, SessionStart) are Claude-only: a mixed or misspelled event
# name silences the whole hooks.json (spike §3), so the event set is exact.
SUPPORTED_HOOK_EVENTS = {"sessionStart"}

SCHEMA_DIR = Path(__file__).resolve().parent / "vendor" / "cursor"


@dataclass(frozen=True)
class Payload:
    content: bytes
    executable: bool = False


def cursor_runtime(package: Package) -> RuntimePackage | None:
    return next((entry for entry in package.runtimes if entry.runtime == "cursor"), None)


def package_root(package: Package) -> Path:
    if Path(package.key).name != package.key or package.key in {".", ".."}:
        raise ValueError(f"unsafe native Cursor package name: {package.key}")
    return OUTPUT_ROOT / package.key


def native_package_roots(packages: Iterable[Package]) -> tuple[Path, ...]:
    """Own every modeled native Cursor package root, including excluded ones."""
    return tuple(
        package_root(package)
        for package in packages
        if (runtime := cursor_runtime(package)) is not None and runtime.mechanism == "native"
    )


def native_packages(packages: Iterable[Package]) -> tuple[Package, ...]:
    """Select included/native packages independently of catalog visibility."""
    selected: list[Package] = []
    for package in packages:
        runtime = cursor_runtime(package)
        if runtime is None or runtime.status != "included" or runtime.mechanism != "native":
            continue
        if frozenset(runtime.components) not in NATIVE_COMPONENTS:
            raise ValueError(f"unsupported included native Cursor components for {package.key}: {runtime.components}")
        package_root(package)
        selected.append(package)
    return tuple(selected)


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def json_payload(value: Any) -> Payload:
    return Payload((json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))


def native_version(model: PackageModel) -> str:
    source = read_json(REPO_ROOT / model.version_source)
    version = source.get("version") if isinstance(source, dict) else None
    if not isinstance(version, str) or not version.strip():
        raise ValueError(f"{model.version_source}: missing nonempty version")
    return version


def manifest_author() -> dict[str, str]:
    source = read_json(REPO_ROOT / SOURCE_PLUGIN_PATH)
    author = source.get("author") if isinstance(source, dict) else None
    if not isinstance(author, dict) or not isinstance(author.get("name"), str) or not author["name"].strip():
        raise ValueError(f"{SOURCE_PLUGIN_PATH}: missing author name")
    return {"name": author["name"]}


def load_plugin_schema() -> dict[str, Any]:
    return cast(dict[str, Any], read_json(SCHEMA_DIR / "plugin.schema.json"))


def build_marketplace(packages: Iterable[Package]) -> dict[str, Any] | None:
    """Build the schema-valid catalog of listed native packages, or keep it absent."""
    entries = [
        {"name": package.key, "source": f"./{package_root(package).as_posix()}"}
        for package in native_packages(packages)
        if (runtime := cursor_runtime(package)) is not None and runtime.listed
    ]
    if not entries:
        return None
    catalog = {"name": "ycc", "plugins": entries}
    schema = read_json(SCHEMA_DIR / "marketplace.schema.json")
    validator = Draft7Validator(schema, format_checker=FormatChecker())
    errors = sorted(validator.iter_errors(catalog), key=lambda error: str(error.path))
    if errors:
        detail = "; ".join(error.message for error in errors)
        raise ValueError(f"{MARKETPLACE_PATH}: violates the vendored Cursor schema: {detail}")
    return catalog


# --- schema validation (vendored official cursor/plugins schema subset) ----


def validate_manifest(manifest: dict[str, Any], schema: dict[str, Any], name: str) -> None:
    validator = Draft7Validator(schema, format_checker=FormatChecker())
    errors = sorted(validator.iter_errors(manifest), key=lambda error: str(error.path))
    if errors:
        detail = "; ".join(error.message for error in errors)
        raise ValueError(f"packages/cursor/{name}: plugin.json violates the vendored Cursor schema: {detail}")


# --- payload builders (resolve everything before any write) ----------------


def mcp_payload(root: Path) -> dict[Path, Payload]:
    content = (REPO_ROOT / SOURCE_MCP_PATH).read_bytes()
    audit_no_secret_literals(load_mcp_config(content, SOURCE_MCP_PATH.as_posix()), SOURCE_MCP_PATH.as_posix())
    return {root / "mcp.json": Payload(content)}


def hooks_payload(root: Path) -> dict[Path, Payload]:
    """Copy the canonical Cursor registration; never Claude hook events."""
    registration = read_json(REPO_ROOT / SOURCE_HOOKS_PATH)
    if (
        not isinstance(registration, dict)
        or registration.get("version") != 1
        or not isinstance(registration.get("hooks"), dict)
        or set(registration["hooks"]) != SUPPORTED_HOOK_EVENTS
    ):
        raise ValueError(f"{SOURCE_HOOKS_PATH}: unsupported Cursor hook event; expected sessionStart only")
    expected = 'bash "${CURSOR_PLUGIN_ROOT}/hooks/herdr-session-start.sh" session'
    if registration["hooks"]["sessionStart"] != [{"command": expected}]:
        raise ValueError(f"{SOURCE_HOOKS_PATH}: unsupported Cursor sessionStart hook command")
    script_source = REPO_ROOT / SOURCE_HOOK_PATH
    if not script_source.is_file():
        raise ValueError(f"{SOURCE_HOOK_PATH}: missing sessionStart hook script source")
    return {
        root / "hooks/hooks.json": json_payload(registration),
        root
        / "hooks/herdr-session-start.sh": Payload(
            script_source.read_bytes(), bool(script_source.stat().st_mode & stat.S_IXUSR)
        ),
    }


def native_payloads(model: PackageModel, packages: Iterable[Package]) -> dict[Path, Payload]:
    """Resolve every source and metadata value before any destination mutation."""
    version = native_version(model)
    author = manifest_author()
    schema = load_plugin_schema()
    output: dict[Path, Payload] = {}
    for package in packages:
        runtime = cursor_runtime(package)
        assert runtime is not None
        root = package_root(package)
        manifest: dict[str, Any] = {
            "name": package.key,
            "displayName": package.key,
            "version": version,
            "description": package.description,
            "author": author,
            "minClientVersions": {"cursor": MIN_CURSOR_VERSION},
        }
        components = frozenset(runtime.components)
        if components == frozenset({"mcp"}):
            config = load_mcp_config((REPO_ROOT / SOURCE_MCP_PATH).read_bytes(), SOURCE_MCP_PATH.as_posix())
            variables = collect_variables(config)
            if variables:
                manifest["variables"] = {
                    "type": "object",
                    "properties": {name: {"type": "string"} for name in variables},
                }
            manifest["mcpServers"] = "./mcp.json"
        output[root / ".cursor-plugin/plugin.json"] = json_payload(manifest)
        if components == frozenset({"mcp"}):
            output.update(mcp_payload(root))
        elif components == frozenset({"hooks"}):
            output.update(hooks_payload(root))
    for rel, payload in output.items():
        if rel.name == "plugin.json":
            validate_manifest(json.loads(payload.content), schema, rel.parent.parent.name)
    return output


def fallback_payload() -> Payload:
    """installer-fallback config: byte-identical copy of the canonical source."""
    source = REPO_ROOT / SOURCE_CLI_CONFIG_PATH
    if not source.is_file():
        raise ValueError(f"{SOURCE_CLI_CONFIG_PATH}: missing Cursor CLI config source")
    return Payload(source.read_bytes())


# --- output plumbing (guard, write, prune, check) --------------------------


def guard_managed_paths(dest_root: Path, inventory: Iterable[Path], owned_roots: Iterable[Path]) -> None:
    """Reject managed symlinks and file/directory conflicts before writing."""
    if dest_root.is_symlink() or (dest_root.exists() and not dest_root.is_dir()):
        raise ValueError(f"output root must be a non-symlink directory: {dest_root}")
    # The marketplace is managed even in the absent state, before any unlink.
    files = set(inventory) | {MARKETPLACE_PATH}
    roots = tuple(owned_roots)
    for rel in (*files, *roots):
        for depth in range(1, len(rel.parts) + 1):
            prefix = Path(*rel.parts[:depth])
            path = dest_root / prefix
            if path.is_symlink():
                raise ValueError(f"managed-path symlink is not allowed: {prefix}")
            if prefix != rel and path.exists() and not path.is_dir():
                raise ValueError(f"managed parent is not a directory: {prefix}")
        if rel in files and (dest_root / rel).exists() and not (dest_root / rel).is_file():
            raise ValueError(f"managed output is not a regular file: {rel}")
    for rel in roots:
        path = dest_root / rel
        if path.exists() and not path.is_dir():
            raise ValueError(f"managed root is not a directory: {rel}")
        if path.is_dir():
            for directory, dirs, filenames in os.walk(path, followlinks=False):
                for name in dirs + filenames:
                    candidate = Path(directory) / name
                    if candidate.is_symlink():
                        raise ValueError(f"managed-path symlink is not allowed: {candidate.relative_to(dest_root)}")


def native_owned_files(dest_root: Path, roots: Iterable[Path]) -> set[Path]:
    files: set[Path] = {MARKETPLACE_PATH} if (dest_root / MARKETPLACE_PATH).is_file() else set()
    for rel in roots:
        root = dest_root / rel
        if root.is_file():
            files.add(rel)
        if root.is_dir():
            files.update(path.relative_to(dest_root) for path in root.rglob("*") if path.is_file())
    return files


def native_extras(dest_root: Path, inventory: set[Path], roots: Iterable[Path]) -> set[Path]:
    extras = native_owned_files(dest_root, roots) - inventory
    for rel in roots:
        root = dest_root / rel
        if root.exists() and not any(rel in path.parents for path in inventory):
            extras.add(rel)
        if root.is_dir():
            for directory in root.rglob("*"):
                relative = directory.relative_to(dest_root)
                if directory.is_dir() and not any(relative in path.parents for path in inventory):
                    extras.add(relative)
    return extras


def prune_native_output(dest_root: Path, inventory: set[Path], roots: tuple[Path, ...]) -> None:
    for rel in sorted(native_owned_files(dest_root, roots) - inventory):
        (dest_root / rel).unlink()
    for rel in roots:
        root = dest_root / rel
        for path in sorted(root.rglob("*"), key=lambda p: len(p.parts), reverse=True) if root.is_dir() else []:
            if path.is_dir() and not any(path.iterdir()):
                path.rmdir()
        if root.is_dir() and not any(root.iterdir()) and not any(rel in path.parents for path in inventory):
            root.rmdir()


def write_payloads(dest_root: Path, output: dict[Path, Payload], roots: tuple[Path, ...], dry_run: bool) -> set[Path]:
    inventory = set(output)
    guard_managed_paths(dest_root, inventory, roots)
    if dry_run:
        for rel in sorted(output):
            print(f"Would write {rel}")
        for rel in sorted(native_extras(dest_root, inventory, roots)):
            print(f"Would remove {rel}")
        return inventory
    for rel, payload in sorted(output.items()):
        path = dest_root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists() or path.read_bytes() != payload.content:
            path.write_bytes(payload.content)
        path.chmod(0o755 if payload.executable else 0o644)
    prune_native_output(dest_root, inventory, roots)
    return inventory


def check_payloads(dest_root: Path, output: dict[Path, Payload], roots: tuple[Path, ...]) -> list[str]:
    inventory = set(output)
    guard_managed_paths(dest_root, inventory, roots)
    diffs: list[str] = []
    for rel, payload in sorted(output.items()):
        path = dest_root / rel
        if not path.is_file():
            diffs.append(f"missing file: {rel}")
            continue
        if path.read_bytes() != payload.content:
            diffs.append(f"drift: {rel}")
        if bool(path.stat().st_mode & stat.S_IXUSR) != payload.executable:
            diffs.append(f"executable-bit drift: {rel}")
    diffs.extend(f"extra in output: {rel}" for rel in sorted(native_extras(dest_root, inventory, roots)))
    return diffs


# --- unit payloads: reuse the existing generators for components ----------


def unit_output(root: Path, package: Package) -> dict[Path, Payload]:
    """Reuse the existing transforms without mutating the real destination."""
    import generate_cursor_agents as agents
    import generate_cursor_rules as rules
    import generate_cursor_skills as skills

    runtime = cursor_runtime(package)
    assert runtime is not None
    components = frozenset(runtime.components)
    with tempfile.TemporaryDirectory() as tmp:
        staging = Path(tmp)
        if "skills" in components:
            skills.write_tree(staging / "skills", dry_run=False)
        if "agents" in components:
            agents.write_all(dry_run=False, dest=staging / "agents")
        if "rules" in components:
            rules.write_tree(staging / "rules", dry_run=False)
        output = {
            root / path.relative_to(staging): Payload(path.read_bytes(), bool(path.stat().st_mode & stat.S_IXUSR))
            for path in sorted(staging.rglob("*"))
            if path.is_file()
        }
        if package.key == "ycc":
            mcp = (REPO_ROOT / SOURCE_MCP_PATH).read_bytes()
            audit_no_secret_literals(load_mcp_config(mcp, str(SOURCE_MCP_PATH)), str(SOURCE_MCP_PATH))
            helper = REPO_ROOT / "ycc/settings/cursor/select-mcp.py"
            output[root / "resources/mcp/mcp.json"] = Payload(mcp)
            output[root / "resources/mcp/select-mcp.py"] = Payload(helper.read_bytes(), True)
        if "commands" in components:
            from generate_codex_common import parse_frontmatter

            for source in sorted((REPO_ROOT / "ycc/skills").glob("*/SKILL.md")):
                name = source.parent.name
                frontmatter, _ = parse_frontmatter(source.read_text(encoding="utf-8"))
                if name.startswith("_") or frontmatter.get("user-invocable") is False:
                    continue
                description = skills.apply_skills_text_transforms(str(frontmatter.get("description", "")))
                if not description.strip():
                    raise ValueError(f"{source}: missing command description")
                text = (
                    f"---\nname: {name}\ndescription: {json.dumps(description)}\n---\n\n"
                    f"Read `${{CURSOR_PLUGIN_ROOT}}/skills/{name}/SKILL.md` and follow its instructions "
                    "with these arguments:\n\n$ARGUMENTS\n"
                )
                output[root / f"commands/{name}.md"] = Payload(text.encode())
        return output


def build_output() -> tuple[dict[Path, Payload], tuple[Path, ...]]:
    """Build the complete expected output and owned roots before any write."""
    model = load_package_model()
    roots = native_package_roots(model.packages)
    selected = native_packages(model.packages)
    output = native_payloads(model, selected)
    marketplace = build_marketplace(model.packages)
    if marketplace is not None:
        output[MARKETPLACE_PATH] = json_payload(marketplace)
    for package in selected:
        runtime = cursor_runtime(package)
        assert runtime is not None
        if frozenset(runtime.components) & {"skills", "agents", "rules"}:
            output.update(unit_output(package_root(package), package))
    fallback_package = next((p for p in model.packages if p.key == "installer-fallback"), None)
    if fallback_package is not None and (fallback_runtime := cursor_runtime(fallback_package)) is not None:
        fallback_root = package_root(fallback_package)
        roots += (fallback_root,)
        if fallback_runtime.status == "included" and "settings" in fallback_runtime.components:
            output[fallback_root / "config/cli-config.json"] = fallback_payload()
    return output, roots


def write_all(dest_root: Path, dry_run: bool = False) -> set[Path]:
    output, roots = build_output()
    # Retire only the former payload directories, never the manifest directory
    # itself: the marketplace is owned separately from its neighboring files.
    roots += tuple(Path(".cursor-plugin") / unit for unit in ("skills", "agents", "rules", "config"))
    return write_payloads(dest_root, output, roots, dry_run)


def run_check(dest_root: Path = REPO_ROOT) -> int:
    output, roots = build_output()
    roots += tuple(Path(".cursor-plugin") / unit for unit in ("skills", "agents", "rules", "config"))
    diffs = check_payloads(dest_root, output, roots)
    if diffs:
        print("Cursor packages drift; run ./scripts/generate-cursor-packages.sh", file=sys.stderr)
        for diff in diffs:
            print(f"  {diff}", file=sys.stderr)
    return int(bool(diffs))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check", action="store_true", help="Exit 1 if generated output drifts")
    modes.add_argument("--dry-run", action="store_true", help="Print what would be written without mutation")
    args = parser.parse_args(argv)
    try:
        if args.check:
            return run_check()
        write_all(REPO_ROOT, args.dry_run)
        if not args.dry_run:
            print(f"Wrote Cursor native packages under {OUTPUT_ROOT}")
        return 0
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"generate_cursor_packages: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
