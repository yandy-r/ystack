#!/usr/bin/env python3
"""Opt-in catalog of third-party opencode plugins (ycc/settings/opencode-plugins.json).

Each catalog entry pins one npm plugin (``<name>@<X.Y.Z>``) that ``--plugins
<name>`` adds to opencode.json, plus the extra opencode.json keys it needs
(``managed_keys``) and companion config files copied beside opencode.json.
The installer drives everything through this CLI:

    names                                        catalog names, one per line
    validate                                     check the catalog; exit 1 on errors
    source --names CSV --out FILE                merge-helper source for the entries
    companions sync|remove --names CSV --dest-dir DIR [--force] [--dry-run]
    purge-cache --names CSV [--cache-dir DIR] [--dry-run]
    notes --names CSV [--remove]                 print the entries' manual steps

Every subcommand accepts ``--catalog PATH``. Unknown names exit 2.
Companion and cache dry runs report their changes without writing files or state.

Companion files are owned by hash in ``opencode-plugin-files.json`` beside the
managed-config state: ycc replaces or deletes a companion only when it is
unchanged since ycc wrote it, unless ``--force``. Sync adopts a file that
already equals the shipped copy; remove deletes only a recorded one.
"""

from __future__ import annotations

import argparse
import copy
import glob
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

from managed_config_entries import item_key
from validate_opencode_config import validate_config

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = REPO_ROOT / "ycc" / "settings" / "opencode-plugins.json"
BUNDLE_DIR = REPO_ROOT / ".opencode-plugin"
BUNDLE_CONFIG_PATH = BUNDLE_DIR / "opencode.json"
STATE_NAME = "opencode-plugin-files.json"

ENTRY_KEYS = frozenset(
    {"package", "description", "homepage", "default", "options", "config_files", "managed_keys", "notes"}
)
MANAGED_KEYS = frozenset({"agents"})
CONFIG_FILE_KEYS = frozenset({"source", "destination"})
EXACT_VERSION = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z][0-9A-Za-z.-]*)?")
# An npm package name: optional @scope/, lowercase npm charset, no segment that
# is empty or starts with "." (so no "." / ".." path segments).
NPM_NAME = re.compile(r"(@[a-z0-9~-][a-z0-9._~-]*/)?[a-z0-9~-][a-z0-9._~-]*")
# opencode's own files beside a companion; bundle unit dirs are added at runtime.
RESERVED_DESTINATIONS = frozenset({"opencode.json", "opencode.jsonc", "tui.json", "tui.jsonc", "cli.json", "agents.md"})
PACKAGE_RULE: dict[str, Any] = {"item_key": "package"}
RC_LINE = re.compile(r"`(export [A-Za-z_][A-Za-z0-9_]*=[^`]*)`")
LSP_NOTE = re.compile(r"\blsp\b")

Entry = dict[str, Any]
Catalog = dict[str, Entry]


class CatalogError(Exception):
    """A catalog that cannot be loaded at all."""


def load_catalog(path: Path) -> Catalog:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CatalogError(f"cannot read catalog {path}: {error}") from error
    plugins = data.get("plugins") if isinstance(data, dict) else None
    if not isinstance(plugins, dict):
        raise CatalogError(f'{path}: top level must be {{"plugins": {{<name>: {{…}}}}}}')
    if not all(isinstance(entry, dict) for entry in plugins.values()):
        raise CatalogError(f"{path}: every plugins entry must be an object")
    return {str(name): entry for name, entry in plugins.items()}


def select(catalog: Catalog, csv: str) -> list[str]:
    """Catalog names from a CSV; an unknown name exits 2."""
    names = list(dict.fromkeys(part.strip() for part in csv.split(",") if part.strip()))
    for name in names:
        if name not in catalog:
            print(f"[err] unknown catalog plugin '{name}' (catalog: {', '.join(catalog)})", file=sys.stderr)
            raise SystemExit(2)
    if not names:
        print("[err] --names requires at least one catalog plugin", file=sys.stderr)
        raise SystemExit(2)
    return names


def plugin_item(entry: Entry) -> Any:
    """The opencode.json ``plugins`` item: the spec, or ``{package, options}``."""
    if "options" in entry:
        return {"package": entry["package"], "options": entry["options"]}
    return entry["package"]


def deep_merge(target: dict[str, Any], extra: dict[str, Any]) -> None:
    for key, value in extra.items():
        current = target.get(key)
        if isinstance(current, dict) and isinstance(value, dict):
            deep_merge(current, value)
        else:
            target[key] = copy.deepcopy(value)


def config_files(entry: Entry) -> list[dict[str, str]]:
    files = entry.get("config_files", [])
    return [item for item in files if isinstance(item, dict)] if isinstance(files, list) else []


def bundle_plugin_names() -> set[str]:
    data = json.loads(BUNDLE_CONFIG_PATH.read_text(encoding="utf-8"))
    names = {item_key(PACKAGE_RULE, item) for item in data.get("plugins", [])}
    return {name for name in names if name}


def reserved_destinations() -> set[str]:
    """Names a companion must never take: opencode's files and the bundle's units."""
    units = {path.name.casefold() for path in BUNDLE_DIR.iterdir()} if BUNDLE_DIR.is_dir() else set()
    return set(RESERVED_DESTINATIONS) | units


# --- validate -----------------------------------------------------------------


def validate_package(name: str, entry: Entry) -> list[str]:
    package = entry.get("package")
    if not isinstance(package, str) or not package:
        return ["package must be a non-empty string"]
    if not NPM_NAME.fullmatch(name):
        return [f"name {name!r} is not a valid npm package name"]
    key = item_key(PACKAGE_RULE, package)
    if key != name:
        return [f"name must equal the package name {key!r} (got {name!r})"]
    version = package[len(name) + 1 :] if package.startswith(f"{name}@") else ""
    if not EXACT_VERSION.fullmatch(version):
        return [f"package {package!r} must pin an exact version: {name}@X.Y.Z (no range, tag or missing version)"]
    return []


def validate_files(entry: Entry, settings_dir: Path) -> list[str]:
    files = entry.get("config_files", [])
    if not isinstance(files, list):
        return ["config_files must be a list"]
    errors: list[str] = []
    reserved = reserved_destinations()
    for index, item in enumerate(files):
        where = f"config_files[{index}]"
        if not isinstance(item, dict) or set(item) != CONFIG_FILE_KEYS:
            errors.append(f"{where} must have exactly the keys source and destination")
            continue
        source, destination = item["source"], item["destination"]
        source_path = settings_dir / source if isinstance(source, str) and source else None
        if source_path is None or not source_path.is_file():
            errors.append(f"{where}.source {source!r} is not a file under {settings_dir}")
        elif not source_path.resolve().is_relative_to(settings_dir.resolve()):
            errors.append(f"{where}.source {source!r} escapes {settings_dir}")
        if not isinstance(destination, str) or destination in ("", ".", "..") or re.search(r"[/\\]", destination):
            errors.append(f"{where}.destination {destination!r} must be a plain file name")
        elif destination.startswith(".") or destination.casefold() in reserved:
            errors.append(f"{where}.destination {destination!r} is reserved (an opencode or bundle file, or a dotfile)")
    return errors


def validate_entry(name: str, entry: Entry, settings_dir: Path, base: dict[str, Any]) -> list[str]:
    errors = [f"unknown key {key!r}" for key in sorted(set(entry) - ENTRY_KEYS)]
    errors += validate_package(name, entry)
    if entry.get("default") is not False:
        errors.append("default must be false (catalog plugins are opt-in)")
    for key in ("description", "homepage"):
        if key in entry and not isinstance(entry[key], str):
            errors.append(f"{key} must be a string")
    if "options" in entry and not isinstance(entry["options"], dict):
        errors.append("options must be an object")
    notes = entry.get("notes", [])
    if not isinstance(notes, list) or not all(isinstance(note, str) and note for note in notes):
        errors.append("notes must be a list of non-empty strings")
    errors += validate_files(entry, settings_dir)
    managed = entry.get("managed_keys", {})
    if not isinstance(managed, dict):
        errors.append("managed_keys must be an object")
        managed = {}
    errors += [f"managed_keys.{key} is not allowed (only: agents)" for key in sorted(set(managed) - MANAGED_KEYS)]
    if errors:
        return errors
    # V2 validity in the bundle context: the bundle's own findings are not ours.
    candidate = copy.deepcopy(base)
    candidate["plugins"] = [plugin_item(entry)]
    deep_merge(candidate, managed)
    known = set(validate_config(base))
    return [f"opencode V2: {message}" for message in validate_config(candidate) if message not in known]


def validate_catalog(path: Path) -> list[str]:
    try:
        catalog = load_catalog(path)
        base = json.loads(BUNDLE_CONFIG_PATH.read_text(encoding="utf-8"))
        bundle = bundle_plugin_names()
    except (CatalogError, OSError, json.JSONDecodeError) as error:
        return [str(error)]
    base["plugins"] = []
    errors: list[str] = []
    seen: dict[str, str] = {}
    for name, entry in catalog.items():
        problems = validate_entry(name, entry, path.parent, base)
        if name in bundle:
            problems.append("collides with a bundle plugin name")
        for item in config_files(entry):
            destination = item.get("destination")
            if isinstance(destination, str) and destination in seen:
                problems.append(f"companion {destination!r} is also shipped by {seen[destination]!r}")
            elif isinstance(destination, str):
                seen[destination] = name
        errors += [f"{name}: {problem}" for problem in problems]
    return errors


# --- source -------------------------------------------------------------------


def build_source(catalog: Catalog, names: list[str]) -> dict[str, Any]:
    managed: dict[str, Any] = {}
    for name in names:
        deep_merge(managed, catalog[name].get("managed_keys", {}))
    return {"plugins": [plugin_item(catalog[name]) for name in names], **managed}


# --- companions ---------------------------------------------------------------


def state_path() -> Path:
    """opencode-plugin-files.json beside the managed-config state file."""
    managed = os.environ.get("YCC_MANAGED_CONFIG_STATE")
    if managed:
        return Path(managed).expanduser().parent / STATE_NAME
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return config / "ycc" / STATE_NAME


def load_hashes(path: Path) -> dict[str, str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    hashes = data.get("sha256") if isinstance(data, dict) else None
    if not isinstance(hashes, dict):
        return {}
    return {str(k): v for k, v in hashes.items() if isinstance(v, str)}


def atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def save_hashes(path: Path, hashes: dict[str, str]) -> None:
    payload = {"version": 1, "sha256": dict(sorted(hashes.items()))}
    atomic_write(path, (json.dumps(payload, indent=2) + "\n").encode("utf-8"))


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sync_companion(source: bytes, dest: Path, hashes: dict[str, str], force: bool, dry_run: bool) -> None:
    key = str(dest)
    wanted = sha256(source)
    if not dest.exists() and not dest.is_symlink():
        if dry_run:
            print(f"  would copy {dest}")
            return
        atomic_write(dest, source)
        hashes[key] = wanted
        print(f"  [ok] wrote {dest}")
        return
    # A symlink or non-file is the user's: compare only a regular file's bytes.
    current = sha256(dest.read_bytes()) if dest.is_file() and not dest.is_symlink() else None
    if current == wanted:
        if not dry_run:
            hashes[key] = wanted
        print(f"  [ok] up to date: {dest}")
    elif (current is not None and current == hashes.get(key)) or force:
        if dest.is_dir() and not dest.is_symlink():
            print(f"  [!!] kept {dest}: a directory is in the way")
            return
        if dry_run:
            print(f"  would copy {dest}")
            return
        atomic_write(dest, source)
        hashes[key] = wanted
        print(f"  [ok] updated {dest}")
    else:
        print(f"  [!!] kept {dest}: local edits (re-run with --force to replace it)")


def remove_companion(source: bytes, dest: Path, hashes: dict[str, str], force: bool, dry_run: bool) -> None:
    key = str(dest)
    if not dest.exists() and not dest.is_symlink():
        if not dry_run:
            hashes.pop(key, None)
        return
    current = sha256(dest.read_bytes()) if dest.is_file() and not dest.is_symlink() else None
    # Only a recorded hash proves ycc wrote it: a file that merely equals the
    # shipped copy may be the plugin's own installer output.
    owned = current is not None and current == hashes.get(key)
    if dest.is_dir() and not dest.is_symlink():
        print(f"  [!!] kept {dest}: not a file")
    elif owned or force:
        if dry_run:
            print(f"  would remove {dest}")
            return
        dest.unlink()
        hashes.pop(key, None)
        print(f"  [ok] removed {dest}")
    else:
        print(f"  [!!] kept {dest}: local edits (re-run with --force to remove it)")


def run_companions(catalog: Catalog, catalog_path: Path, args: argparse.Namespace) -> int:
    names = select(catalog, args.names)
    dest_dir = Path(os.path.abspath(args.dest_dir.expanduser()))
    path = state_path()
    hashes = load_hashes(path)
    before = dict(hashes)
    for name in names:
        for item in config_files(catalog[name]):
            source = (catalog_path.parent / item["source"]).read_bytes()
            dest = dest_dir / item["destination"]
            action = sync_companion if args.action == "sync" else remove_companion
            action(source, dest, hashes, args.force, args.dry_run)
    if not args.dry_run and hashes != before:
        save_hashes(path, hashes)
    return 0


# --- purge-cache --------------------------------------------------------------


def default_cache_dir() -> Path:
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "opencode"


def inside(path: Path, root: Path) -> bool:
    """``path`` resolves (symlinks followed) to ``root`` or below it."""
    return Path(os.path.realpath(path)).is_relative_to(root)


def contained(path: Path, layout_dir: Path, root: Path) -> bool:
    """``path`` itself is strictly below its layout dir (``cache/npm`` …) with no
    ``..`` segment, and still below the cache once every directory above it is
    resolved; the entry itself is not followed (a symlink is unlinked)."""
    if ".." in path.parts or path == layout_dir or not path.is_relative_to(layout_dir):
        return False
    real = Path(os.path.realpath(path.parent)) / path.name
    return real != root and real.is_relative_to(root)


def purge_package(package: str, cache: Path, root: Path, dry_run: bool) -> int:
    """Remove one package's cached copies; returns 1 when something was refused."""
    if not NPM_NAME.fullmatch(package):
        print(f"  [!!] refused {package!r}: not a valid npm package name")
        return 1
    scope, _, base = package.rpartition("/")
    candidates: list[tuple[Path, Path]] = []
    refused = 0
    for layout in ("npm", "packages"):
        parent = cache / layout / scope if scope else cache / layout
        if not parent.is_dir():
            continue
        if not inside(parent, root):
            print(f"  [!!] refused {parent}: resolves outside {root}")
            refused = 1
            continue
        candidates += [(path, cache / layout) for path in sorted(parent.glob(f"{glob.escape(base)}@*"))]
    legacy = cache / "node_modules" / package
    if legacy.exists() or legacy.is_symlink():
        candidates.append((legacy, cache / "node_modules"))
    for path, layout_dir in candidates:
        if not contained(path, layout_dir, root):
            print(f"  [!!] refused {path}: resolves outside {root}")
            refused = 1
        elif path.is_symlink() or not path.is_dir():
            if dry_run:
                print(f"  would remove {path}")
            else:
                path.unlink()  # a symlink is removed itself, never followed
                print(f"  [ok] removed {path}")
        elif dry_run:
            print(f"  would remove {path}")
        else:
            shutil.rmtree(path)
            print(f"  [ok] removed {path}")
    if not candidates and not refused:
        print(f"  [ok] no cached copies of {package}")
    return refused


def run_purge(catalog: Catalog, args: argparse.Namespace) -> int:
    names = select(catalog, args.names)
    cache = Path(os.path.abspath((args.cache_dir or default_cache_dir()).expanduser()))
    if not cache.is_dir():
        for name in names:
            print(f"  [ok] no cached copies of {name}")
        return 0
    root = Path(os.path.realpath(cache))
    refused = 0
    for name in names:
        package = item_key(PACKAGE_RULE, catalog[name]["package"]) or name
        refused |= purge_package(package, cache, root, args.dry_run)
    return refused


# --- notes --------------------------------------------------------------------


def run_notes(catalog: Catalog, args: argparse.Namespace) -> int:
    for name in select(catalog, args.names):
        notes = catalog[name].get("notes", [])
        if not args.remove:
            for note in notes:
                print(f"  [i] {note}")
            continue
        rc_lines = [line for note in notes for line in RC_LINE.findall(note)]
        if rc_lines:
            print(f"  [i] {name} removed; you may delete these lines from your shell rc if you added them:")
            for line in rc_lines:
                print(f"        {line}")
        if any(LSP_NOTE.search(note) for note in notes):
            print(f'  [i] {name} removed; you may also delete "lsp": true from opencode.json if you set it for {name}.')
    return 0


# --- projected removal --------------------------------------------------------


def run_loads_after_remove(args: argparse.Namespace) -> int:
    """Whether a name remains after the same removal the merge helper would apply."""
    from managed_config_entries import expand_leaf_rules
    from merge_managed_config import PROFILES, MergeError, load_source, load_state, parse_pointer, remove_json

    destination = args.destination.expanduser()
    profile = PROFILES[args.profile]
    groups = [group.strip() for group in args.groups.split(",") if group.strip()]
    valid_scope = args.state_scope is None or re.fullmatch(r"[A-Za-z0-9@/._-]+", args.state_scope)
    if not groups or profile["format"] != "json" or not valid_scope:
        return 0
    try:
        source = load_source(args.source, profile)
        state = load_state()
        scope = f"[{args.state_scope}]" if args.state_scope is not None else ""
        state_entry = state.get(f"{args.profile}{scope}:{destination}", {})
        if not isinstance(state_entry, dict):
            state_entry = {}
        profile = expand_leaf_rules(profile, source, [parse_pointer(key) for key in state_entry if key.startswith("/")])
        rendered, _, _, _, _, _ = remove_json(source, destination, profile, groups, state_entry, args.force)
        projected = destination if rendered is None else json.loads(rendered)
        if not isinstance(projected, dict):
            return 0
        plugins = projected.get("plugins", [])
        if not isinstance(plugins, list):
            return 0
        specs = [
            item if isinstance(item, str) else item.get("package") for item in plugins if isinstance(item, (str, dict))
        ]
        return 0 if args.name in {item_key(PACKAGE_RULE, spec) for spec in specs if isinstance(spec, str)} else 1
    except (MergeError, OSError, ValueError, KeyError, TypeError, AttributeError):
        return 0


# --- CLI ----------------------------------------------------------------------


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--catalog", type=Path, default=CATALOG_PATH, help="Catalog JSON (default: ycc/settings)")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("names", parents=[common], help="Print catalog names, one per line")
    sub.add_parser("validate", parents=[common], help="Validate the catalog")
    source = sub.add_parser("source", parents=[common], help="Write the merge-helper source JSON")
    source.add_argument("--names", required=True)
    source.add_argument("--out", required=True, type=Path)
    companions = sub.add_parser("companions", parents=[common], help="Sync or remove companion config files")
    companions.add_argument("action", choices=("sync", "remove"))
    companions.add_argument("--names", required=True)
    companions.add_argument("--dest-dir", required=True, type=Path)
    companions.add_argument("--force", action="store_true")
    companions.add_argument("--dry-run", action="store_true", help="Preview companion changes without writing")
    purge = sub.add_parser("purge-cache", parents=[common], help="Delete cached package copies")
    purge.add_argument("--names", required=True)
    purge.add_argument("--cache-dir", type=Path)
    purge.add_argument("--dry-run", action="store_true", help="Preview cache removal without writing")
    loads = sub.add_parser(
        "loads-after-remove", parents=[common], help="Query plugin membership after a read-only removal projection"
    )
    loads.add_argument("--destination", required=True, type=Path)
    loads.add_argument("--name", required=True)
    loads.add_argument("--source", required=True, type=Path)
    loads.add_argument("--profile", required=True, choices=("opencode-config", "opencode-catalog"))
    loads.add_argument("--groups", required=True)
    loads.add_argument("--state-scope")
    loads.add_argument("--force", action="store_true")
    notes = sub.add_parser("notes", parents=[common], help="Print manual follow-up notes")
    notes.add_argument("--names", required=True)
    notes.add_argument("--remove", action="store_true", help="Print what the user may undo after removal")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.command == "loads-after-remove":
        return run_loads_after_remove(args)
    catalog_path: Path = args.catalog
    if args.command == "validate":
        errors = validate_catalog(catalog_path)
        for error in errors:
            print(f"[err] {error}", file=sys.stderr)
        if errors:
            return 1
        print(f"  [ok] {catalog_path} is a valid opencode plugin catalog")
        return 0
    try:
        catalog = load_catalog(catalog_path)
    except CatalogError as error:
        print(f"[err] {error}", file=sys.stderr)
        return 1
    if args.command == "names":
        for name in catalog:
            print(name)
        return 0
    if args.command == "source":
        payload = json.dumps(build_source(catalog, select(catalog, args.names)), indent=2) + "\n"
        atomic_write(args.out, payload.encode("utf-8"))
        return 0
    if args.command == "companions":
        return run_companions(catalog, catalog_path, args)
    if args.command == "purge-cache":
        return run_purge(catalog, args)
    return run_notes(catalog, args)


if __name__ == "__main__":
    sys.exit(main())
