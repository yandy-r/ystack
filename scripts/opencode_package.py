#!/usr/bin/env python3
"""Merge or remove the one ``@yandy-r/ycc-opencode`` entry in OpenCode's ``plugins`` list.

``install.sh --target opencode`` installs ycc through its native npm plugin: the
``base`` step writes a single V2 ``plugins`` item into the global
``~/.config/opencode/opencode.json``:

- ``--mode local``: ``file:///<checkout>/packages/opencode/ycc-opencode`` (a
  directory entry, as the package README documents);
- ``--mode repo``: ``@yandy-r/ycc-opencode@<version>`` (the lockstep product
  version from ``ycc/.claude-plugin/plugin.json``).

Replaced in place (an object item keeps its other keys, such as ``options``):
an item this helper recorded writing, a bare ``@yandy-r/ycc-opencode`` or
``@yandy-r/ycc-opencode@latest`` (also behind ``npm:``), and this checkout's own
``file://`` entry. Any other ycc-opencode item (an explicitly pinned version,
another checkout's directory) is the user's: it is kept and reported, nothing is
added beside it, and ``--force`` replaces it. Every other item is untouched.

Ownership follows merge_managed_config.py: the hash of the item this helper
wrote is recorded under ``opencode-package:<destination>`` in the managed-config
state file, so ``remove`` takes back only that item, or a plain string spec this
checkout would write; anything else is reported and kept unless ``--force``.
A symlinked opencode.json (or config directory) is refused with the entry to
edit by hand. A JSONC file is backed up to ``<file>.ycc-backup`` before a
rewrite drops its comments. ``--dry-run`` previews without writing config or state.

``check`` confirms the package can load before the installer retires the old
file copy: the local package directory (local mode) or the published version
(repo mode, via ``npm view``), and an ``opencode`` on PATH at the engine floor.

Exit codes: 0 done, 1 error, 2 refused (symlink), 3 not confirmed (``check``),
4 a user-owned ycc-opencode entry was kept (``sync`` without ``--force``).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

from merge_managed_config import (
    MergeError,
    atomic_write,
    load_json_config,
    load_state,
    save_state,
    value_hash,
    ycc_backups,
)

ROOT = Path(__file__).resolve().parent.parent
PACKAGE_NAME = "@yandy-r/ycc-opencode"
PACKAGE_DIR = ROOT / "packages/opencode/ycc-opencode"
VERSION_SOURCE = ROOT / "ycc/.claude-plugin/plugin.json"
STATE_PROFILE = "opencode-package"
OWNED_KEY = "added_item_sha256"
JSONC_PROFILE: dict[str, Any] = {"format": "json", "jsonc": True}
MIN_OPENCODE_VERSION = (2, 0, 30)
REFUSED, UNCONFIRMED, KEPT = 2, 3, 4


def default_destination() -> Path:
    return Path.home() / ".config/opencode/opencode.json"


def product_version() -> str:
    data = json.loads(VERSION_SOURCE.read_text(encoding="utf-8"))
    version = data.get("version") if isinstance(data, dict) else None
    if not isinstance(version, str) or not version.strip():
        raise ValueError(f"{VERSION_SOURCE}: missing nonempty version")
    return version


def local_spec() -> str:
    return PACKAGE_DIR.resolve().as_uri()


def repo_spec() -> str:
    return f"{PACKAGE_NAME}@{product_version()}"


def wanted_spec(mode: str) -> str:
    return local_spec() if mode == "local" else repo_spec()


def item_spec(item: object) -> str | None:
    """The package specifier of a ``plugins`` item (string or ``{"package": ...}``)."""
    if isinstance(item, str):
        return item
    if isinstance(item, dict) and isinstance(item.get("package"), str):
        return str(item["package"])
    return None


def _local_dir(spec: str) -> Path | None:
    if spec.startswith("file:"):
        parsed = urlparse(spec)
        return Path(unquote(parsed.path)) if parsed.path else None
    if spec.startswith(("/", "~")):
        return Path(spec).expanduser()
    return None


def _registry_version(spec: str) -> str | None:
    """``""`` for a bare ``@yandy-r/ycc-opencode``, its version/tag, or None for another spec."""
    spec = spec.strip()
    if spec.startswith("npm:"):
        spec = spec[len("npm:") :]
    if spec == PACKAGE_NAME:
        return ""
    if spec.startswith(f"{PACKAGE_NAME}@"):
        return spec[len(PACKAGE_NAME) + 1 :]
    return None


def _is_local_checkout(spec: str) -> bool:
    local = _local_dir(spec.strip())
    return local is not None and Path(str(local).rstrip("/")) == PACKAGE_DIR.resolve()


def is_ycc_package(item: object) -> bool:
    """True for a ycc-opencode item: the registry package, or a ``packages/opencode/ycc-opencode`` dir."""
    spec = item_spec(item)
    if spec is None:
        return False
    if _registry_version(spec) is not None or _is_local_checkout(spec):
        return True
    local = _local_dir(spec.strip())
    return local is not None and Path(str(local).rstrip("/")).parts[-3:] == ("packages", "opencode", "ycc-opencode")


def replaceable(item: object, owned: set[str]) -> bool:
    """True for a ycc-opencode item sync may replace without --force."""
    spec = item_spec(item)
    if spec is None:
        return False
    if value_hash(item) in owned or _is_local_checkout(spec):
        return True
    return _registry_version(spec) in ("", "latest")


def load_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    data = load_json_config(path.read_text(encoding="utf-8"), path, JSONC_PROFILE)
    if not isinstance(data, dict):
        raise MergeError(f"{path}: expected a JSON object at the root")
    return data


def plugins_of(config: dict[str, Any], path: Path) -> list[Any]:
    plugins = config.get("plugins", [])
    if not isinstance(plugins, list):
        raise MergeError(f"{path}: 'plugins' must be a list")
    return list(plugins)


def loads_package(path: Path) -> bool:
    """True when ``path`` (JSONC) lists a ycc-opencode plugins item; unreadable counts as no."""
    try:
        return any(is_ycc_package(item) for item in plugins_of(load_config(path), path))
    except (OSError, ValueError, MergeError):
        return False


def state_key(path: Path) -> str:
    return f"{STATE_PROFILE}:{path}"


def owned_hashes(state: dict[str, Any], path: Path) -> list[str]:
    entry = state.get(state_key(path), {})
    owned = entry.get(OWNED_KEY, []) if isinstance(entry, dict) else []
    return [digest for digest in owned if isinstance(digest, str)] if isinstance(owned, list) else []


def refusal(path: Path) -> str | None:
    """Why ``path`` cannot be rewritten in place (a symlinked file or config directory)."""
    if path.is_symlink():
        return f"{path} is a symlink"
    if path.parent.is_symlink():
        return f"{path.parent} is a symlink"
    return None


def backup_jsonc(path: Path) -> None:
    """Save ``<file>.ycc-backup`` (first free ``.N``) before a rewrite drops JSONC comments or commas."""
    if not path.is_file():
        return
    raw = path.read_bytes()
    try:
        json.loads(raw.decode("utf-8") or "{}")
        return
    except ValueError:
        pass
    *existing, free = ycc_backups(path)
    backup = next((candidate for candidate in existing if candidate.is_file() and candidate.read_bytes() == raw), None)
    if backup is None:
        backup = free
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(fd, raw)
            os.fsync(fd)
        finally:
            os.close(fd)
    print(f"  [!!] comments and trailing commas in {path} are not preserved; original saved to {backup}")


def write(path: Path, config: dict[str, Any], state: dict[str, Any]) -> None:
    """Write the config (or delete it when nothing is left), then the state; restore the config on failure."""
    original = path.read_bytes() if path.exists() else None
    mode = path.stat().st_mode & 0o777 if path.exists() else None
    backup_jsonc(path)
    if config:
        atomic_write(path, json.dumps(config, indent=2, ensure_ascii=False) + "\n")
    else:
        path.unlink(missing_ok=True)
    try:
        save_state(state)
    except BaseException:
        if original is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(original)
            if mode is not None:
                path.chmod(mode)
        raise


def sync(path: Path, mode: str, force: bool, dry_run: bool) -> int:
    spec = wanted_spec(mode)
    if (why := refusal(path)) is not None:
        print(f'  [!!] refusing to rewrite {path}: {why}; add this item to its "plugins" list by hand:')
        print(f"    {json.dumps(spec)}")
        return REFUSED
    config = load_config(path)
    plugins = plugins_of(config, path)
    state = load_state()
    owned = set(owned_hashes(state, path))
    ycc = [index for index, item in enumerate(plugins) if is_ycc_package(item)]
    foreign = [index for index in ycc if not replaceable(plugins[index], owned)]
    if foreign and not force:
        for index in foreign:
            print(
                f"  [!!] kept {item_spec(plugins[index])} in {path}: not written by ycc; nothing added beside it "
                f"(re-run with --force to replace it with {spec})"
            )
        return KEPT
    if ycc:
        first = plugins[ycc[0]]
        item: Any = {**first, "package": spec} if isinstance(first, dict) else spec
        merged = [plugins[i] if i != ycc[0] else item for i in range(len(plugins)) if i not in ycc[1:]]
    else:
        item = spec
        merged = [*plugins, item]
    if merged == plugins:
        # Already present: record nothing this run did not write; rewrite nothing.
        print(f"  [ok] up-to-date: {path} ({PACKAGE_NAME}: {spec})")
        return 0
    if dry_run:
        verb = "replace" if ycc else "add"
        print(f"  [dry-run] would {verb} the {PACKAGE_NAME} plugins entry in {path}: {spec}")
        return 0
    config["plugins"] = merged
    state[state_key(path)] = {OWNED_KEY: [value_hash(item)]}
    path.parent.mkdir(parents=True, exist_ok=True)
    write(path, config, state)
    replaced = f" (replaced {len(ycc)} existing entr{'y' if len(ycc) == 1 else 'ies'})" if ycc else ""
    print(f"  [ok] {PACKAGE_NAME} plugins entry in {path}: {spec}{replaced}")
    return 0


def remove(path: Path, force: bool, dry_run: bool) -> int:
    if (why := refusal(path)) is not None:
        print(f"  [!!] refusing to rewrite {path}: {why}; remove the {PACKAGE_NAME} plugins item by hand")
        return REFUSED
    state = load_state()
    owned = set(owned_hashes(state, path))
    if not path.exists():
        if owned and not dry_run:
            state.pop(state_key(path), None)
            save_state(state)
        print(f"  [ok] nothing to remove: {path} ({PACKAGE_NAME})")
        return 0
    config = load_config(path)
    plugins = plugins_of(config, path)
    exact = {local_spec(), repo_spec()}
    kept: list[Any] = []
    taken: list[Any] = []
    for item in plugins:
        if not is_ycc_package(item):
            kept.append(item)
        elif value_hash(item) in owned or item in exact or force:
            taken.append(item)
        else:
            kept.append(item)
            print(f"  [!!] kept {item_spec(item)} in {path}: not written by ycc (re-run with --force to remove it)")
    if not taken:
        if owned and not dry_run:
            state.pop(state_key(path), None)
            save_state(state)
        print(f"  [ok] nothing to remove: {path} ({PACKAGE_NAME})")
        return 0
    if dry_run:
        for item in taken:
            print(f"  [dry-run] would remove the {item_spec(item)} plugins entry from {path}")
        return 0
    if kept:
        config["plugins"] = kept
    else:
        config.pop("plugins", None)
    state.pop(state_key(path), None)
    write(path, config, state)
    for item in taken:
        print(f"  [ok] removed the {item_spec(item)} plugins entry from {path}")
    if not config:
        print(f"  [ok] removed empty file {path}")
    return 0


def _version(text: str) -> tuple[int, ...] | None:
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", text)
    return tuple(int(part) for part in match.groups()) if match else None


def check(mode: str) -> int:
    """Confirm the package this run registered can load before the legacy copy is retired."""
    spec = wanted_spec(mode)
    if mode == "local":
        manifest = PACKAGE_DIR / "package.json"
        try:
            name = json.loads(manifest.read_text(encoding="utf-8")).get("name")
        except (OSError, ValueError, AttributeError):
            name = None
        if name != PACKAGE_NAME or not PACKAGE_DIR.resolve().is_dir():
            print(f"  [!!] file-copy install retained: {manifest} is not the {PACKAGE_NAME} package")
            return UNCONFIRMED
    else:
        npm = shutil.which("npm")
        published = False
        if npm is not None:
            try:
                result = subprocess.run(
                    [npm, "view", spec, "version"], capture_output=True, text=True, timeout=60, check=False
                )
                published = result.returncode == 0 and result.stdout.strip() == product_version()
            except (OSError, subprocess.TimeoutExpired):
                published = False
        if not published:
            print(f"  [!!] file-copy install retained: could not confirm {spec} is published")
            return UNCONFIRMED
    opencode = shutil.which("opencode")
    if opencode is None:
        print(f"  [ok] opencode not on PATH: {spec} needs OpenCode >= 2.0.30 when you start it")
        return 0
    try:
        result = subprocess.run([opencode, "--version"], capture_output=True, text=True, timeout=30, check=False)
        found = _version(result.stdout + result.stderr) if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        found = None
    floor = ".".join(map(str, MIN_OPENCODE_VERSION))
    if found is None or found < MIN_OPENCODE_VERSION:
        shown = ".".join(map(str, found)) if found else "unknown"
        print(f"  [!!] file-copy install retained: opencode {shown} cannot load {spec} (needs >= {floor})")
        return UNCONFIRMED
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("action", choices=("sync", "remove", "spec", "check"))
    parser.add_argument("--mode", choices=("local", "repo"), default="local")
    parser.add_argument("--destination", type=Path, default=None)
    parser.add_argument(
        "--force", action="store_true", help="also replace/remove ycc-opencode entries ycc did not write"
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    path = (args.destination or default_destination()).expanduser()
    try:
        if args.action == "spec":
            print(wanted_spec(args.mode))
            return 0
        if args.action == "check":
            return check(args.mode)
        if args.action == "sync":
            return sync(path, args.mode, args.force, args.dry_run)
        return remove(path, args.force, args.dry_run)
    except (OSError, ValueError, MergeError) as error:
        print(f"opencode_package: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
