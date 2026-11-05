#!/usr/bin/env python3
"""Generate Codex plugin metadata and listing-driven repository catalogs.

The repository flips to the native catalog and payloads only when every
migration package (``MIGRATION_PACKAGES``: ycc and ycc-mcp) is an included
native Codex row with ``listed: true``. Until then the combined legacy ycc and
local-ycc-plugins catalog stay byte-identical, and a partial listing is a
validator error (``partial_codex_listing_error``) rather than a half flip.
Explicit --native-output exports remain opt-in and include unlisted packages.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import sys
import tempfile
from collections.abc import Iterable
from pathlib import Path
from typing import Any

from codex_marketplace import validate_marketplace_catalog
from generate_codex_common import (
    CODEX_PLUGIN_CONTAINER,
    PLUGIN_MANIFEST_PATH,
    PLUGIN_MCP_PATH,
    PLUGIN_ROOT,
    SOURCE_MCP_PATH,
    SOURCE_PLUGIN_PATH,
)
from generate_codex_mcp import CODEX_MCP_PATH, build_codex_mcp_config, write_codex_mcp_config
from generate_codex_skills import write_tree
from package_model import Package, PackageModel, load_package_model

REPOSITORY_URL = "https://github.com/yandy-r/ystack"
REPO_ROOT = CODEX_PLUGIN_CONTAINER.parent
NATIVE_MARKETPLACE = Path(".agents/plugins/marketplace.json")
NATIVE_COMPONENTS = {frozenset({"skills", "shared"}), frozenset({"mcp"})}
# Packages a single listed repository must ship together: the native flip is
# all-or-nothing so the Codex installer and migration never land half of it.
MIGRATION_PACKAGES = ("ycc", "ycc-mcp")


def load_source_plugin() -> dict[str, Any]:
    payload = json.loads(SOURCE_PLUGIN_PATH.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"{SOURCE_PLUGIN_PATH}: expected a JSON object")
    return payload


def build_plugin_manifest() -> dict[str, Any]:
    source = load_source_plugin()
    description = str(source.get("description") or "").replace("Claude Code", "Codex")
    author = source.get("author") or {"name": "yandy-r"}
    version = source.get("version")
    if not isinstance(version, str) or not version.strip():
        raise ValueError(f"{SOURCE_PLUGIN_PATH}: missing nonempty version")
    return {
        "name": "ycc",
        "version": version,
        "description": description,
        "author": author,
        "repository": REPOSITORY_URL,
        "homepage": REPOSITORY_URL,
        "license": "MIT",
        "keywords": ["codex", "skills", "planning", "development"],
        "skills": "./skills/",
        "mcpServers": "./.mcp.json",
        "interface": {
            "displayName": "YCC",
            "shortDescription": "Planning, implementation, review, and workflow skills for Codex.",
            "longDescription": (
                "Yandy's Codex-native workflow bundle with planning, research, implementation, "
                "review, and GitHub-oriented development skills."
            ),
            "developerName": author.get("name", "yandy-r"),
            "category": "Productivity",
            "capabilities": ["Interactive", "Read", "Write"],
            "websiteURL": REPOSITORY_URL,
            "defaultPrompt": [
                "Use YCC to plan a medium-sized feature before implementation.",
                "Use YCC to review my branch and summarize the highest-risk findings.",
                "Use YCC to orchestrate a multi-step refactor across this repository.",
            ],
            "brandColor": "#0F766E",
        },
    }


def build_repo_marketplace() -> dict[str, Any]:
    catalog = {
        "name": "local-ycc-plugins",
        "interface": {
            "displayName": "Local YCC Plugins",
        },
        "plugins": [
            {
                "name": "ycc",
                "source": {
                    "source": "local",
                    "path": "./plugins/ycc",
                },
                "policy": {
                    "installation": "AVAILABLE",
                    "authentication": "ON_INSTALL",
                },
                "category": "Productivity",
            }
        ],
    }
    return validate_marketplace_catalog(catalog)


def native_package_roots(packages: Iterable[Package]) -> tuple[Path, ...]:
    """Own all modeled native Codex roots, including excluded/deferred packages."""
    roots = []
    for package in packages:
        if not any(entry.runtime == "codex" and entry.mechanism == "native" for entry in package.runtimes):
            continue
        if Path(package.key).name != package.key or package.key in {".", ".."}:
            raise ValueError(f"unsafe native Codex package name: {package.key}")
        roots.append(Path(".codex-plugin") / package.key)
    return tuple(roots)


def native_packages(packages: Iterable[Package]) -> tuple[Package, ...]:
    """Select supported included/native Codex payloads, independent of listing."""
    selected: list[Package] = []
    for package in packages:
        runtime = next((entry for entry in package.runtimes if entry.runtime == "codex"), None)
        if runtime is None or runtime.status != "included" or runtime.mechanism != "native":
            continue
        if frozenset(runtime.components) not in NATIVE_COMPONENTS:
            raise ValueError(f"unsupported included native Codex components for {package.key}: {runtime.components}")
        if Path(package.key).name != package.key or package.key in {".", ".."}:
            raise ValueError(f"unsafe native Codex package name: {package.key}")
        selected.append(package)
    return tuple(selected)


def build_native_marketplace(packages: Iterable[Package], *, include_unlisted: bool = False) -> dict[str, Any]:
    """Build the future catalog without reading or modifying the package model."""
    entries = []
    for package in native_packages(packages):
        runtime = next(entry for entry in package.runtimes if entry.runtime == "codex")
        if not include_unlisted and not runtime.listed:
            continue
        entries.append(
            {
                "name": package.key,
                "source": {"source": "local", "path": f"./.codex-plugin/{package.key}"},
                "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
                "category": "Productivity",
            }
        )
    catalog = {"name": "ycc", "interface": {"displayName": "YCC"}, "plugins": entries}
    validate_marketplace_catalog(catalog)
    return catalog


def repository_native_enabled(packages: Iterable[Package]) -> bool:
    """Whether the repository switches to the native catalog and payloads.

    Every migration package must be an included, non-opt-in native row that is
    listed. Partial listing keeps the legacy combined ycc payload and catalog,
    and codex_eligible refuses the native install and legacy cleanup until the
    flip is complete.
    """
    rows = {}
    for package in packages:
        runtime = next((entry for entry in package.runtimes if entry.runtime == "codex"), None)
        if runtime is not None:
            rows[package.key] = runtime
    return all(
        key in rows
        and rows[key].status == "included"
        and rows[key].mechanism == "native"
        and not rows[key].opt_in
        and rows[key].listed
        for key in MIGRATION_PACKAGES
    )


def build_repository_marketplace(packages: Iterable[Package]) -> dict[str, Any]:
    """Return the legacy catalog until every migration package is listed."""
    items = tuple(packages)
    return build_native_marketplace(items) if repository_native_enabled(items) else build_repo_marketplace()


def partial_codex_listing_error(packages: Iterable[Package]) -> str | None:
    """Describe a partial Codex listing, or None when all or none of the flip is listed."""
    packages = tuple(packages)
    if repository_native_enabled(packages):
        return None
    listed = sorted(
        package.key
        for package in native_packages(packages)
        if next(entry for entry in package.runtimes if entry.runtime == "codex").listed
    )
    if not listed:
        return None
    return (
        f"partial Codex listing is not allowed: {listed} listed, but the native flip requires "
        f"{list(MIGRATION_PACKAGES)} to be included, native and listed together"
    )


def native_version(model: PackageModel) -> str:
    source_path = REPO_ROOT / model.version_source
    source = json.loads(source_path.read_text(encoding="utf-8"))
    version = source.get("version")
    if not isinstance(version, str) or not version.strip():
        raise ValueError(f"{source_path}: missing nonempty version")
    return version


def build_native_manifest(package: Package, version: str) -> dict[str, Any]:
    manifest = build_plugin_manifest()
    manifest["name"] = package.key
    manifest["version"] = version
    runtime = next(entry for entry in package.runtimes if entry.runtime == "codex")
    if set(runtime.components) == {"skills", "shared"}:
        del manifest["mcpServers"]
        return manifest
    del manifest["skills"]
    manifest["description"] = package.description
    manifest["keywords"] = ["codex", "mcp", "integrations"]
    manifest["interface"] = {
        "displayName": "YCC MCP",
        "shortDescription": "MCP server connections for Codex.",
        "longDescription": "YCC's independently installable MCP server connections for Codex.",
        "developerName": manifest["author"].get("name", "yandy-r"),
        "category": "Productivity",
        "capabilities": ["Read", "Write"],
        "websiteURL": REPOSITORY_URL,
        "brandColor": "#0F766E",
    }
    return manifest


def native_metadata(model: PackageModel, packages: Iterable[Package]) -> dict[Path, dict[str, Any]]:
    """Resolve all native metadata before starting any filesystem writes."""
    version = native_version(model)
    output: dict[Path, dict[str, Any]] = {}
    for package in packages:
        root = Path(".codex-plugin") / package.key
        output[root / ".codex-plugin/plugin.json"] = build_native_manifest(package, version)
        runtime = next(entry for entry in package.runtimes if entry.runtime == "codex")
        if set(runtime.components) == {"mcp"}:
            output[root / ".mcp.json"] = {"mcpServers": build_codex_mcp_config()["mcp_servers"]}
    return output


def guard_managed_paths(
    dest_root: Path,
    managed_paths: Iterable[Path],
    owned_roots: Iterable[Path],
    selected_roots: Iterable[Path],
) -> None:
    """Reject symlinks on managed paths/owned trees and non-directory selected roots."""
    for rel in (*managed_paths, *owned_roots):
        for depth in range(1, len(rel.parts) + 1):
            prefix = Path(*rel.parts[:depth])
            if (dest_root / prefix).is_symlink():
                raise ValueError(f"managed-path symlink is not allowed: {prefix}")
    for rel in owned_roots:
        root = dest_root / rel
        for directory, dirs, files in os.walk(root, followlinks=False):
            for name in dirs + files:
                path = Path(directory) / name
                if path.is_symlink():
                    raise ValueError(f"managed-path symlink is not allowed: {path.relative_to(dest_root)}")
    for rel in selected_roots:
        if (dest_root / rel).exists() and not (dest_root / rel).is_dir():
            raise ValueError(f"selected package root is not a directory: {rel}")


def selected_roots(inventory: Iterable[Path], roots: tuple[Path, ...]) -> tuple[Path, ...]:
    files = tuple(inventory)
    return tuple(root for root in roots if any(root in path.parents for path in files))


def preflight_native_destination(dest_root: Path, roots: tuple[Path, ...] | None = None) -> Path:
    """Reject checkout overlap and unsafe managed paths before native mutation."""
    dest_root = dest_root.resolve()
    repo_root = REPO_ROOT.resolve()
    if dest_root == Path(dest_root.anchor):
        raise ValueError("native output must not be a filesystem root")
    if dest_root == repo_root or repo_root in dest_root.parents or dest_root in repo_root.parents:
        raise ValueError("native output must not overlap the repository")
    if dest_root.exists() and not dest_root.is_dir():
        raise ValueError("native output must be a directory")
    model = load_package_model()
    if roots is None:
        roots = native_package_roots(model.packages)
    selected = tuple(Path(".codex-plugin") / package.key for package in native_packages(model.packages))
    guard_managed_paths(dest_root, (NATIVE_MARKETPLACE,), roots, selected)
    return dest_root


def native_owned_files(dest_root: Path, roots: tuple[Path, ...]) -> set[Path]:
    return {path.relative_to(dest_root) for rel in roots for path in (dest_root / rel).rglob("*") if path.is_file()}


def native_extras(dest_root: Path, inventory: set[Path], roots: tuple[Path, ...]) -> set[Path]:
    extras = native_owned_files(dest_root, roots) - inventory
    extras.update(
        root for root in roots if (dest_root / root).exists() and not any(root in path.parents for path in inventory)
    )
    return extras


def prune_native_output(dest_root: Path, inventory: set[Path], roots: tuple[Path, ...]) -> None:
    for rel in sorted(native_owned_files(dest_root, roots) - inventory):
        (dest_root / rel).unlink()
    for rel in roots:
        if (dest_root / rel).is_file() and rel not in selected_roots(inventory, roots):
            (dest_root / rel).unlink()
    for rel in roots:
        root = dest_root / rel
        for path in sorted(root.rglob("*"), key=lambda path: len(path.parts), reverse=True):
            if path.is_dir() and not any(path.iterdir()):
                path.rmdir()
        if root.is_dir() and not any(root.iterdir()) and not any(rel in path.parents for path in inventory):
            root.rmdir()


def generate_native_tree(dest_root: Path, dry_run: bool = False) -> set[Path]:
    """Export a complete, opt-in repository-shaped native distribution."""
    model = load_package_model()
    roots = native_package_roots(model.packages)
    dest_root = preflight_native_destination(dest_root, roots)
    packages = native_packages(model.packages)
    metadata = native_metadata(model, packages)
    metadata[NATIVE_MARKETPLACE] = build_native_marketplace(packages, include_unlisted=True)
    inventory = set(metadata)
    for package in packages:
        runtime = next(entry for entry in package.runtimes if entry.runtime == "codex")
        if set(runtime.components) == {"skills", "shared"}:
            root = Path(".codex-plugin") / package.key
            inventory.update(root / path for path in write_tree(dest_root / root, dry_run, native_paths=True))
    if dry_run:
        for rel in sorted(metadata):
            print(f"Would write {rel}")
        for rel in sorted(native_extras(dest_root, inventory, roots)):
            print(f"Would remove {rel}")
    else:
        for rel, payload in metadata.items():
            write_json(dest_root / rel, payload)
        prune_native_output(dest_root, inventory, roots)
    return inventory


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    serialized = json.dumps(payload, indent=2) + "\n"
    if path.exists():
        existing = path.read_text(encoding="utf-8")
        if existing == serialized:
            return
    path.write_text(serialized, encoding="utf-8")


def write_all(dest_root: Path, dry_run: bool) -> set[Path]:
    """Write legacy metadata or complete model-shaped native payloads after listing."""
    model = load_package_model()
    packages = native_packages(model.packages)
    catalog = build_repository_marketplace(packages)
    listed = catalog["name"] == "ycc"
    roots = native_package_roots(model.packages)
    if not listed:
        roots = tuple(root for root in roots if root != Path(".codex-plugin/ycc"))
    metadata = native_metadata(
        model,
        (
            packages
            if listed
            else (
                package
                for package in packages
                if set(next(r for r in package.runtimes if r.runtime == "codex").components) == {"mcp"}
            )
        ),
    )
    manifest_rel = PLUGIN_MANIFEST_PATH.relative_to(REPO_ROOT)
    mcp_rel = PLUGIN_MCP_PATH.relative_to(REPO_ROOT)
    metadata[NATIVE_MARKETPLACE] = catalog
    if not listed:
        metadata[manifest_rel] = build_plugin_manifest()
    announced = set(metadata) | {CODEX_MCP_PATH.relative_to(REPO_ROOT)}
    if not listed:
        announced.add(mcp_rel)
    files = set(announced)
    guard_managed_paths(dest_root, files, roots, (Path(".codex-plugin/ycc"), *selected_roots(files, roots)))

    # Skills normally arrive from generate_codex_skills during sync. Listed
    # output must also own its relocatable skills tree for standalone and
    # --check runs; a previously listed repository is restored to legacy paths.
    restore_legacy = not listed and (dest_root / manifest_rel).is_file() and not (dest_root / mcp_rel).exists()
    if restore_legacy:
        guard_managed_paths(dest_root, (), (Path(".codex-plugin/ycc"),), ())
    if listed:
        for package in packages:
            runtime = next(entry for entry in package.runtimes if entry.runtime == "codex")
            if set(runtime.components) == {"skills", "shared"}:
                root = Path(".codex-plugin") / package.key
                files.update(root / path for path in write_tree(dest_root / root, dry_run, native_paths=True))
    elif restore_legacy:
        write_tree(dest_root / ".codex-plugin/ycc", dry_run, native_paths=False)

    if dry_run:
        for path in sorted(announced):
            print(f"Would write {path}")
        for rel in sorted(native_extras(dest_root, files, roots)):
            print(f"Would remove {rel}")
        return files

    for rel, payload in metadata.items():
        write_json(dest_root / rel, payload)
    if not listed:
        mcp_path = dest_root / mcp_rel
        mcp_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SOURCE_MCP_PATH, mcp_path)
    write_codex_mcp_config(dest_root / CODEX_MCP_PATH.relative_to(REPO_ROOT))
    prune_native_output(dest_root, files, roots)
    return files


def compare_files(
    generated_root: Path, repo_root: Path, files: set[Path], *, compare_executable: bool = False
) -> list[str]:
    diffs: list[str] = []
    for rel in sorted(files):
        generated = generated_root / rel
        repo = repo_root / rel
        if not repo.is_file():
            diffs.append(f"missing file: {rel}")
            continue
        if generated.read_bytes() != repo.read_bytes():
            diffs.append(f"drift: {rel}")
        elif compare_executable and is_owner_executable(generated) != is_owner_executable(repo):
            diffs.append(f"executable-bit drift: {rel}")
    return diffs


def is_owner_executable(path: Path) -> bool:
    """Match Git's tracked executable bit rather than full permission bits."""
    return bool(path.stat().st_mode & stat.S_IXUSR)


def run_check(repo_root: Path | None = None) -> int:
    if repo_root is None:
        repo_root = REPO_ROOT
    model = load_package_model()
    listed = build_repository_marketplace(model.packages)["name"] == "ycc"
    roots = native_package_roots(model.packages)
    if not listed:
        roots = tuple(root for root in roots if root != Path(".codex-plugin/ycc"))
    with tempfile.TemporaryDirectory() as tmp:
        temp_root = Path(tmp)
        files = write_all(temp_root, dry_run=False)
        guard_managed_paths(repo_root, files, roots, (Path(".codex-plugin/ycc"), *selected_roots(files, roots)))
        diffs = compare_files(temp_root, repo_root, files, compare_executable=listed)
        diffs.extend(f"extra in output: {rel}" for rel in sorted(native_extras(repo_root, files, roots)))
        if diffs:
            print(
                "Codex plugin metadata is out of date. Run: ./scripts/generate-codex-plugin.sh",
                file=sys.stderr,
            )
            for diff in diffs:
                print(f"  {diff}", file=sys.stderr)
            return 1
    return 0


def run_native_check(dest_root: Path) -> int:
    roots = native_package_roots(load_package_model().packages)
    dest_root = preflight_native_destination(dest_root, roots)
    with tempfile.TemporaryDirectory() as tmp:
        temp_root = Path(tmp)
        files = generate_native_tree(temp_root)
        diffs = compare_files(temp_root, dest_root, files, compare_executable=True)
        diffs.extend(f"extra in output: {rel}" for rel in sorted(native_extras(dest_root, files, roots)))
    if diffs:
        print("Codex native output is out of date:", file=sys.stderr)
        for diff in diffs:
            print(f"  {diff}", file=sys.stderr)
        return 1
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check", action="store_true", help="Exit 1 if generated output drifts")
    modes.add_argument("--dry-run", action="store_true", help="Print what would be written")
    parser.add_argument(
        "--native-output",
        type=Path,
        help="Export the split native distribution outside the repository",
    )
    args = parser.parse_args()

    try:
        if args.native_output is not None:
            if args.check:
                sys.exit(run_native_check(args.native_output))
            generate_native_tree(args.native_output, args.dry_run)
            if not args.dry_run:
                print(f"Wrote Codex native distribution under {args.native_output.resolve()}")
        elif args.check:
            sys.exit(run_check())
        else:
            write_all(REPO_ROOT, args.dry_run)
            if not args.dry_run:
                print(f"Wrote Codex plugin metadata under {PLUGIN_ROOT}")
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"generate_codex_plugin: {exc}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
