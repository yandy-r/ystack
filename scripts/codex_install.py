#!/usr/bin/env python3
"""Install the listed Codex pair (ycc + ycc-mcp) without touching legacy carriers.

The shell owns build/step selection. This helper owns native marketplace
registration, the versioned cache fallback for a missing plugin CLI, scoped
plugin enablement, and the ownership record that makes base removal safe.
Legacy links, caches and config are retired only by ``install.sh migrate``.
Settings and removal accept ``--dry-run`` to report ownership-aware changes
without updating config, native caches, backups, or ownership state.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path
from typing import Any

from generate_codex_plugin import MIGRATION_PACKAGES, repository_native_enabled
from merge_managed_config import atomic_write, delete_toml_entries
from package_model import load_package_model
from validate_codex_native import validate

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "https://github.com/yandy-r/ystack.git"
SELECTORS = tuple(f"{package}@ycc" for package in MIGRATION_PACKAGES)
LEGACY_SELECTOR = "ycc@local-ycc-plugins"
UNSAFE_VERSIONS = {".", ".."}


def guarded(path: Path) -> None:
    if path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
        raise ValueError(f"refusing symlinked native install path: {path}")


def inventory(root: Path) -> dict[str, list[Any]]:
    """Fingerprint a complete snapshot: bytes, executable bits and empty directories."""
    guarded(root)
    if not root.is_dir():
        raise ValueError(f"native package is not a directory: {root}")
    result: dict[str, list[Any]] = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"native package contains a symlink: {path}")
        if path.is_dir():
            result[str(path.relative_to(root))] = ["dir"]
        else:
            executable = bool(path.stat().st_mode & 0o111)
            result[str(path.relative_to(root))] = [hashlib.sha256(path.read_bytes()).hexdigest(), executable]
    return result


def config(path: Path) -> dict[str, Any]:
    guarded(path)
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}


def state_path() -> Path:
    return Path.home() / ".config/ycc/codex-native-install.json"


def load_state() -> dict[str, Any]:
    guarded(state_path())
    try:
        state = json.loads(state_path().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"caches": {}, "packages": []}
    if not isinstance(state, dict):
        raise ValueError(f"{state_path()}: expected a JSON object")
    state.setdefault("caches", {})
    state.setdefault("packages", [])
    return state


def save_state(state: dict[str, Any]) -> None:
    guarded(state_path())
    atomic_write(state_path(), json.dumps(state, indent=2) + "\n")


def cli(*args: str, check: bool = True, capture: bool = False) -> str:
    """Run ``codex``; with ``capture``, return its stdout (stderr still reaches the user)."""
    print(f"[ok] codex {' '.join(args)}", flush=True)
    result = subprocess.run(["codex", *args], check=check, stdout=subprocess.PIPE if capture else None, text=True)
    if result.returncode:
        print(f"[!!] 'codex {' '.join(args)}' returned non-zero — check 'codex plugin list'")
    return result.stdout or ""


def safe_version(version: object, package: str) -> str:
    if not isinstance(version, str) or not version or Path(version).name != version or version in UNSAFE_VERSIONS:
        raise ValueError(f"unsafe native package version for {package}: {version!r}")
    return version


def cli_written_snapshot(package_root: Path, package: str, output: str) -> Path:
    """Resolve the snapshot ``codex plugin add --json`` reports writing; raise unless proven."""
    try:
        report = json.loads(output)
    except json.JSONDecodeError as error:
        raise ValueError(f"unparseable 'codex plugin add' output ({error})") from error
    if not isinstance(report, dict):
        raise ValueError("'codex plugin add' output is not a JSON object")
    snapshot = package_root / safe_version(report.get("version"), package)
    installed = report.get("installedPath")
    if not isinstance(installed, str) or Path(installed).resolve() != snapshot.resolve():
        raise ValueError(f"reported installedPath {installed!r} is not {snapshot}")
    guarded(snapshot)
    if not snapshot.is_dir():
        raise ValueError(f"reported snapshot is missing: {snapshot}")
    manifest = snapshot / ".codex-plugin/plugin.json"
    guarded(manifest)
    try:
        payload = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"unreadable {manifest} ({error})") from error
    if not isinstance(payload, dict) or payload.get("version") != snapshot.name:
        raise ValueError(f"{manifest} does not declare the reported version {snapshot.name!r}")
    return snapshot


def merge_config(
    groups: str, source_text: str, entries: list[str] | None, *, remove: bool, force: bool, dry_run: bool = False
) -> None:
    """Run the managed TOML merge for ``source_text``, narrowed to ``entries``."""
    with tempfile.TemporaryDirectory(prefix="ycc-codex-config-") as temporary:
        source = Path(temporary) / "config.toml"
        source.write_text(source_text, encoding="utf-8")
        command = [
            sys.executable,
            str(ROOT / "scripts/merge_managed_config.py"),
            "--profile",
            "codex-config",
            "--source",
            str(source),
            "--destination",
            str(Path.home() / ".codex/config.toml"),
            "--groups",
            groups,
        ]
        if entries is not None:
            # Only the plugins group is entry-selected; settings stay whole.
            command += ["--entry-groups", "plugins", "--entries", ",".join(entries)]
        if remove:
            command.append("--remove")
        if force:
            command.append("--force")
        if dry_run:
            command.append("--dry-run")
        subprocess.run(command, check=True)


def enablement_text() -> str:
    return "".join(f'[plugins."{selector}"]\nenabled = true\n' for selector in SELECTORS)


def snapshot_key(home: Path, snapshot: Path) -> str:
    return str(snapshot.relative_to(home))


def validate_cache_path(relative: str) -> Path:
    rel = Path(relative)
    if rel.is_absolute() or ".." in rel.parts or len(rel.parts) < 5 or rel.parts[:3] != ("plugins", "cache", "ycc"):
        raise ValueError(f"unsafe native cache ownership path: {relative}")
    return rel


def validate_recorded_snapshots(home: Path, state: dict[str, Any]) -> None:
    """Reject local edits in any previously owned snapshot before mutating."""
    for relative, expected in state["caches"].items():
        cache = home / validate_cache_path(relative)
        guarded(cache)
        if cache.exists() and inventory(cache) != expected:
            raise ValueError(f"native cache is edited or foreign; retained: {cache}")


def write_verified_toml(destination: Path, text: str, expected_marketplace: dict[str, Any] | None = None) -> None:
    """Parse and verify ``text`` with tomllib before touching ``destination``."""
    guarded(destination)
    try:
        parsed = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        raise ValueError(
            f"cannot update {destination} (for example, 'marketplaces' is a closed inline table); "
            f"convert it to a '[marketplaces.<name>]' section and retry ({error})"
        ) from error
    if expected_marketplace is not None:
        marketplaces = parsed.get("marketplaces")
        if not isinstance(marketplaces, dict) or marketplaces.get("ycc") != expected_marketplace:
            raise ValueError(f"failed to register [marketplaces.ycc] in {destination}")
    atomic_write(destination, text)


def install(mode: str, use_cli: bool) -> None:
    if not repository_native_enabled(load_package_model().packages):
        raise ValueError("repository native Codex packages are not listed together")
    # A skipped build may leave a stale pre-listing tree: never register it.
    validate(ROOT, native=False)
    home = Path.home() / ".codex"
    destination = home / "config.toml"
    state = load_state()
    git_source = use_cli and mode == "repo"
    expected = (
        {"source_type": "git", "source": REPOSITORY, "ref": "main"}
        if git_source
        else {"source_type": "local", "source": str(ROOT)}
    )
    marketplaces = config(destination).get("marketplaces", {})
    if not isinstance(marketplaces, dict):
        raise ValueError(f"marketplaces in {destination} must be a table")
    registered = marketplaces.get("ycc")
    if registered is not None and registered != expected:
        raise ValueError("marketplace ycc has a different source; retained (remove it or change source explicitly)")

    validate_recorded_snapshots(home, state)

    sources = {package: ROOT / ".codex-plugin" / package for package in MIGRATION_PACKAGES}
    versions: dict[str, str] = {}
    for package, source in sources.items():
        version = safe_version(
            json.loads((source / ".codex-plugin/plugin.json").read_text(encoding="utf-8")).get("version"), package
        )
        versions[package] = version
        cache = home / "plugins/cache/ycc" / package / version
        guarded(cache)
        if cache.exists():
            actual = inventory(cache)
            if actual != inventory(source) and actual != state["caches"].get(snapshot_key(home, cache)):
                raise ValueError(f"native cache is edited or foreign; retained: {cache}")

    fallback_text: str | None = None
    if not use_cli and registered is None:
        current_text = destination.read_text(encoding="utf-8") if destination.exists() else ""
        fallback_text = (
            current_text + f'\n[marketplaces.ycc]\nsource_type = "local"\nsource = {json.dumps(str(ROOT))}\n'
        )
        # Verify the resulting TOML before saving ownership state or mutating disk.
        try:
            parsed = tomllib.loads(fallback_text)
        except tomllib.TOMLDecodeError as error:
            raise ValueError(
                f"cannot append [marketplaces.ycc] to {destination} (for example, 'marketplaces' is a closed "
                f"inline table); convert it to '[marketplaces.<name>]' and retry ({error})"
            ) from error
        if parsed.get("marketplaces", {}).get("ycc") != expected:
            raise ValueError(f"failed to register [marketplaces.ycc] in {destination}")

    # Record registration ownership before a CLI that can partially succeed
    # runs; a registration the user already had is never claimed.
    if registered is None:
        state["marketplace"] = expected
        save_state(state)

    if use_cli:
        target = REPOSITORY if git_source else str(ROOT)
        cli("plugin", "marketplace", "add", target, *(["--ref", "main"] if git_source else []))
    else:
        if mode == "repo":
            print("[!!] Codex plugin CLI unavailable; using this checkout's native snapshot instead of fetching main.")
        if fallback_text is not None:
            write_verified_toml(destination, fallback_text, expected)

    for package, source in sources.items():
        package_root = home / "plugins/cache/ycc" / package
        cache = package_root / versions[package]
        key = snapshot_key(home, cache)
        owned = not cache.exists() or key in state["caches"] or package in state["packages"]
        before = set(package_root.iterdir()) if package_root.is_dir() else set()
        if use_cli:
            output = cli("plugin", "add", f"{package}@ycc", "--json", capture=True)
            # Re-fingerprint only the snapshot the CLI reports writing, and only if
            # it is ours (new, or already recorded); other versions — including a
            # recorded one the user edited while the CLI ran — keep their fingerprints.
            try:
                written = cli_written_snapshot(package_root, package, output)
            except ValueError as error:
                print(f"[!!] {package}: cannot prove the snapshot 'codex plugin add' wrote ({error}); not recording it")
            else:
                written_key = snapshot_key(home, written)
                if written not in before or written_key in state["caches"]:
                    state["caches"][written_key] = inventory(written)
        else:
            if not cache.exists() or inventory(cache) != inventory(source):
                if cache.exists():
                    shutil.rmtree(cache)
                cache.parent.mkdir(parents=True, exist_ok=True)
                shutil.copytree(source, cache)
                print(f"[ok] Synced Codex native cache → {cache}")
            if owned:
                state["caches"][key] = inventory(cache)
        if owned and package not in state["packages"]:
            state["packages"].append(package)
        save_state(state)
    merge_config("plugins", enablement_text(), list(SELECTORS), remove=False, force=True)
    print(
        "[!!] Legacy ycc@local-ycc-plugins links, cache and config are untouched; "
        "run ./install.sh migrate --target codex (then --apply) to retire them."
    )


def remove(use_cli: bool, *, dry_run: bool = False) -> None:
    """Remove owned native packages, or preview the same ownership decisions without writes."""
    if not state_path().exists():
        return
    state = load_state()
    home = Path.home() / ".codex"
    destination = home / "config.toml"
    config(destination)
    kept: dict[str, Any] = {}
    kept_packages: set[str] = set()
    removed_paths: set[Path] = set()
    for relative, expected in state["caches"].items():
        rel = validate_cache_path(relative)
        cache = home / rel
        if not cache.exists() and not cache.is_symlink():
            continue
        try:
            ours = inventory(cache) == expected
        except ValueError:
            ours = False
        if not ours:
            print(f"[!!] kept {cache}: edited or foreign native snapshot")
            kept[relative] = expected
            kept_packages.add(rel.parts[3])
            continue
        if dry_run:
            print(f"[dry-run] would remove native cache {cache}")
        else:
            shutil.rmtree(cache)
            print(f"[ok] removed native cache {cache}")
        removed_paths.add(cache)
        # Only empty package/marketplace containers; never foreign versions.
        for parent in (cache.parent, cache.parent.parent):
            if dry_run:
                if any(child not in removed_paths for child in parent.iterdir()):
                    break
                removed_paths.add(parent)
            else:
                try:
                    parent.rmdir()
                except OSError:
                    break
    plugins = config(destination).get("plugins", {})
    for package in state["packages"]:
        selector = f"{package}@ycc"
        package_root = home / "plugins/cache/ycc" / package
        if package_root.exists() and package_root not in removed_paths:
            kept_packages.add(package)
        elif use_cli and plugins.get(selector, {"enabled": True}) == {"enabled": True}:
            if dry_run:
                print(f"[dry-run] would run codex plugin remove {selector}")
            else:
                cli("plugin", "remove", selector, check=False)
    removable = [f"{package}@ycc" for package in MIGRATION_PACKAGES if package not in kept_packages]
    if removable:
        merge_config("plugins", enablement_text(), removable, remove=True, force=False, dry_run=dry_run)
    registered = config(destination).get("marketplaces", {}).get("ycc")
    owned_marketplace = state.get("marketplace")
    cache_root = home / "plugins/cache/ycc"
    retained_caches = bool(kept or kept_packages or (cache_root.exists() and cache_root not in removed_paths))
    if (
        owned_marketplace is not None
        and not retained_caches
        and (registered == owned_marketplace or (registered is None and use_cli))
    ):
        if use_cli:
            if dry_run:
                print("[dry-run] would run codex plugin marketplace remove ycc")
            else:
                cli("plugin", "marketplace", "remove", "ycc")
        if registered == owned_marketplace and destination.exists():
            if dry_run:
                print(f"[dry-run] would remove /marketplaces/ycc from {destination}")
            else:
                updated = delete_toml_entries(destination.read_text(encoding="utf-8"), [["marketplaces", "ycc"]])
                if updated.strip():
                    write_verified_toml(destination, updated)
                else:
                    destination.unlink()
        state.pop("marketplace", None)
    elif registered is None and not retained_caches:
        state.pop("marketplace", None)
    elif owned_marketplace is not None:
        print("[!!] kept marketplace ycc: edited registration or retained native snapshots")
    state["caches"] = kept
    state["packages"] = [package for package in state["packages"] if package in kept_packages]
    if dry_run:
        action = "update" if kept or state["packages"] or "marketplace" in state else "remove"
        print(f"[dry-run] would {action} ownership state {state_path()}")
        return
    if kept or state["packages"] or "marketplace" in state:
        save_state(state)
    else:
        state_path().unlink()


def native_plugin_keys() -> tuple[str, list[str]]:
    """Shipped settings text with the native pair swapped in, and its plugin keys."""
    shipped = (ROOT / ".codex-plugin/config/config.toml").read_text(encoding="utf-8")
    text = delete_toml_entries(shipped, [["plugins", LEGACY_SELECTOR]]) + "\n" + enablement_text()
    return text, [str(key) for key in tomllib.loads(text).get("plugins", {})]


def settings(
    groups: str,
    *,
    remove: bool,
    force: bool,
    entries: list[str] | None = None,
    list_only: bool = False,
    dry_run: bool = False,
) -> None:
    """Merge shipped settings, swapping the legacy plugin selector for the native pair.

    ``entries`` narrows the plugins group to those plugin keys; ``list_only``
    prints the plugin keys the native settings manage and changes nothing.
    """
    text, keys = native_plugin_keys()
    if list_only:
        for key in keys:
            print(key)
        return
    if not groups:
        return
    with_plugins = "plugins" in groups.split(",")
    if entries is not None:
        unknown = [name for name in entries if name not in keys]
        if not with_plugins or not entries or unknown:
            raise ValueError(
                f"unknown plugins {', '.join(unknown) or '(none given)'} for --groups {groups} "
                f"(managed: {', '.join(keys) or 'none'})"
            )
    selected = (entries if entries is not None else keys) if with_plugins else None
    merge_config(groups, text, selected, remove=remove, force=force, dry_run=dry_run)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("enabled", "install", "remove", "settings"))
    parser.add_argument("--mode", choices=("local", "repo"), default="local")
    parser.add_argument("--cli", action="store_true")
    parser.add_argument("--groups", default="settings,plugins")
    parser.add_argument("--remove", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--entries", help="Comma-separated plugin keys to restrict the plugins group to")
    parser.add_argument("--list-entries", action="store_true", help="Print the managed plugin keys and exit")
    parser.add_argument("--dry-run", action="store_true", help="Preview settings or removal without writing")
    args = parser.parse_args()
    entries = None if args.entries is None else [name.strip() for name in args.entries.split(",") if name.strip()]
    try:
        if args.command == "enabled":
            return 0 if repository_native_enabled(load_package_model().packages) else 1
        if args.command == "install":
            if args.dry_run:
                raise ValueError("native base installation does not support --dry-run")
            install(args.mode, args.cli)
        elif args.command == "remove":
            remove(args.cli, dry_run=args.dry_run)
        else:
            settings(
                args.groups,
                remove=args.remove,
                force=args.force,
                entries=entries,
                list_only=args.list_entries,
                dry_run=args.dry_run,
            )
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"[err] native Codex install stopped: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
