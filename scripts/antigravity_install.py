#!/usr/bin/env python3
"""Install, sync and remove the ycc Google Antigravity plugins.

Antigravity (the App, the IDE and the ``agy`` CLI) loads global plugins from
``~/.gemini/config/plugins/<name>/``. This helper delivers the generated
``packages/antigravity/<name>`` plugins there:

- with ``agy`` on PATH: ``agy plugin uninstall <name>`` (only a ycc-owned
  install), then ``agy plugin install <abs path>``. agy stages a read-only copy
  and updates its own registries.
- without ``agy`` (App/IDE-only machines, or ``--no-agy``): an owned copy is
  placed directly in the plugins folder, which Antigravity also discovers.

Ownership lives in ``~/.config/ycc/antigravity-install.json``: per plugin, the
method used and a content digest of what ycc placed. A plugin folder ycc did not
install (or one edited since) is never replaced or removed without ``--force``;
an identical copy is adopted. ``--dry-run`` prints the plan and changes nothing.

Exit codes: 0 success, 1 a refused or failed package (others still processed
before exiting), 2 usage error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = REPO_ROOT / "packages/antigravity"
PACKAGES = ("ycc", "ycc-mcp", "ycc-rules")
STATE_VERSION = 1


def config_dir() -> Path:
    """The Antigravity global config folder (``YCC_ANTIGRAVITY_CONFIG_DIR`` overrides)."""
    override = os.environ.get("YCC_ANTIGRAVITY_CONFIG_DIR")
    return Path(override) if override else Path.home() / ".gemini/config"


def plugins_dir() -> Path:
    return config_dir() / "plugins"


# The generated plugins reach their helpers through these spellings of the default
# plugins folder (see generate_antigravity_packages.py).
DEFAULT_PLUGIN_PREFIXES = ("${HOME}/.gemini/config/plugins/", "~/.gemini/config/plugins/")


def relocated() -> bool:
    """True when ``YCC_ANTIGRAVITY_CONFIG_DIR`` moves the plugins off the default folder."""
    return config_dir().expanduser().resolve() != (Path.home() / ".gemini/config").resolve()


def relocate_tree(root: Path, plugins: Path) -> None:
    """Point the default plugin-folder references in ``root``'s text files at ``plugins``."""
    target = f"{plugins.expanduser().resolve()}/"
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        updated = text
        for prefix in DEFAULT_PLUGIN_PREFIXES:
            updated = updated.replace(prefix, target)
        if updated != text:
            mode = path.stat().st_mode
            path.write_text(updated, encoding="utf-8")
            path.chmod(mode)


def state_path() -> Path:
    return Path.home() / ".config/ycc/antigravity-install.json"


def tree_digest(root: Path) -> str | None:
    """sha256 over relative paths, contents and exec bits; None when ``root`` is absent."""
    if not root.is_dir():
        return None
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file() or p.is_symlink()):
        rel = path.relative_to(root).as_posix()
        digest.update(rel.encode("utf-8") + b"\0")
        if path.is_symlink():
            digest.update(b"L" + os.readlink(path).encode("utf-8") + b"\0")
            continue
        digest.update(b"X" if path.stat().st_mode & stat.S_IXUSR else b"-")
        digest.update(path.read_bytes() + b"\0")
    return digest.hexdigest()


def load_state() -> dict[str, Any]:
    path = state_path()
    if not path.is_file():
        return {"version": STATE_VERSION, "packages": {}}
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"antigravity: unreadable ownership state {path}: {exc}") from None
    if (
        not isinstance(state, dict)
        or state.get("version") != STATE_VERSION
        or not isinstance(state.get("packages"), dict)
    ):
        raise SystemExit(f"antigravity: unsupported ownership state in {path}")
    return state


def save_state(state: dict[str, Any]) -> None:
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def _make_writable(func: Callable[..., Any], path: str, _exc: object) -> None:
    """rmtree handler: agy stages read-only copies, so grant write and retry."""
    parent = os.path.dirname(path)
    os.chmod(parent, stat.S_IRWXU)
    if os.path.exists(path) and not os.path.islink(path):
        os.chmod(path, stat.S_IRWXU)
    func(path)


def remove_tree(path: Path) -> None:
    # onerror (not onexc) keeps the 3.11 floor; it is deprecated, not removed, in 3.12+.
    shutil.rmtree(path, onerror=_make_writable)


def place_copy(src: Path, dest: Path) -> None:
    """Copy ``src`` to ``dest`` through a sibling temp dir, replacing ``dest`` last."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{dest.name}.", dir=dest.parent))
    try:
        shutil.copytree(src, staging / dest.name, symlinks=True)
        if relocated():
            relocate_tree(staging / dest.name, dest.parent)
        if dest.exists() or dest.is_symlink():
            remove_tree(dest) if dest.is_dir() and not dest.is_symlink() else dest.unlink()
        (staging / dest.name).rename(dest)
    finally:
        if staging.exists():
            remove_tree(staging)


@dataclass
class Context:
    source: Path
    dry_run: bool
    force: bool
    agy: str | None

    def run_agy(self, *args: str) -> None:
        assert self.agy is not None
        command = [self.agy, "plugin", *args]
        if self.dry_run:
            print(f"[dry-run] would run: {' '.join(command)}")
            return
        result = subprocess.run(command, check=False)
        if result.returncode != 0:
            raise RuntimeError(f"{' '.join(command)} exited {result.returncode}")


def resolve_agy(no_agy: bool) -> str | None:
    if no_agy:
        return None
    return os.environ.get("YCC_ANTIGRAVITY_AGY") or shutil.which("agy")


def source_package(source: Path, name: str) -> Path:
    root = source / name
    manifest = root / "plugin.json"
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"{manifest}: missing or malformed plugin manifest ({exc})") from None
    if data.get("name") != name:
        raise RuntimeError(f"{manifest}: name {data.get('name')!r} must be {name!r}")
    return root


def ownership(state: dict[str, Any], name: str, dest: Path, src_digest: str | None) -> tuple[bool, str | None]:
    """Return (owned, reason-if-foreign) for the plugin folder at ``dest``."""
    current = tree_digest(dest)
    record = state["packages"].get(name)
    if current is None:
        return (record is not None, None)
    if record is not None:
        if record.get("digest") not in (None, current):
            return (True, f"{dest} was edited since ycc placed it")
        return (True, None)
    if current == src_digest:
        return (True, None)  # an identical copy: adopt it
    return (False, f"{dest} exists and was not installed by ycc")


def install_one(ctx: Context, state: dict[str, Any], name: str) -> None:
    src = source_package(ctx.source, name)
    dest = plugins_dir() / name
    src_digest = tree_digest(src)
    owned, problem = ownership(state, name, dest, src_digest)
    if problem and not ctx.force:
        raise RuntimeError(f"refusing to replace {name}: {problem} (re-run with --force)")
    record = state["packages"].get(name)
    # Up to date: the source is unchanged since ycc installed it and the installed
    # folder is still what ycc recorded (agy may add its own files to the copy).
    current = tree_digest(dest)
    if (
        record is not None
        and current is not None
        and record.get("source_digest") == src_digest
        and record.get("digest") == current
    ):
        print(f"[ok]  antigravity: {name} is up to date ({dest})")
        return
    if ctx.agy:
        if dest.exists() and (record or {}).get("method") == "agy":
            ctx.run_agy("uninstall", name)
        elif dest.exists() and not ctx.dry_run:
            remove_tree(dest)  # owned copy (or --force): make room for agy's staged copy
        elif dest.exists():
            print(f"[dry-run] would remove {dest}")
        ctx.run_agy("install", str(src.resolve()))
        method = "agy"
    else:
        if ctx.dry_run:
            print(f"[dry-run] would copy {src} -> {dest}")
        else:
            place_copy(src, dest)
        method = "copy"
    if ctx.dry_run:
        return
    state["packages"][name] = {
        "method": method,
        "digest": tree_digest(dest),
        "source": str(src.resolve()),
        "source_digest": src_digest,
    }
    print(f"[ok]  antigravity: installed {name} ({method}) -> {dest}")


def remove_one(ctx: Context, state: dict[str, Any], name: str) -> None:
    dest = plugins_dir() / name
    record = state["packages"].get(name)
    src_digest = tree_digest(ctx.source / name)
    owned, problem = ownership(state, name, dest, src_digest)
    if not dest.exists() and record is None:
        print(f"[ok]  antigravity: {name} is not installed; nothing to remove")
        return
    if (not owned or problem) and not ctx.force:
        reason = problem or f"{dest} was not installed by ycc"
        print(f"[!!]  antigravity: kept {name}: {reason} (re-run with --force to remove it)")
        return
    via_agy = bool(ctx.agy) and (record or {}).get("method") == "agy"
    if via_agy:
        ctx.run_agy("uninstall", name)
    if ctx.dry_run:
        if dest.exists() and not via_agy:
            print(f"[dry-run] would remove {dest}")
        return
    if dest.exists():
        remove_tree(dest)  # an owned copy, or whatever agy left behind
    state["packages"].pop(name, None)
    print(f"[ok]  antigravity: removed {name}")


def parse_packages(value: str | None) -> tuple[str, ...]:
    if not value:
        return PACKAGES
    names = tuple(dict.fromkeys(part.strip() for part in value.split(",") if part.strip()))
    unknown = [name for name in names if name not in PACKAGES]
    if unknown:
        raise SystemExit(f"antigravity: unknown package(s) {', '.join(unknown)} (known: {', '.join(PACKAGES)})")
    return names


def run(action: str, ctx: Context, names: Sequence[str]) -> int:
    if action == "install" and ctx.agy and relocated():
        # agy installs into its own config folder and keeps the generated default paths.
        print(
            f"[err] antigravity: YCC_ANTIGRAVITY_CONFIG_DIR={config_dir()} needs the copy route;"
            " agy installs into its own folder (unset it, or pass --no-agy)",
            file=sys.stderr,
        )
        return 1
    state = load_state()
    route = f"agy plugin ({ctx.agy})" if ctx.agy else f"owned copy in {plugins_dir()}"
    print(f"antigravity: {action} via {route}")
    failed = 0
    for name in names:
        try:
            (install_one if action == "install" else remove_one)(ctx, state, name)
        except RuntimeError as exc:
            print(f"[err] antigravity: {exc}", file=sys.stderr)
            failed += 1
    if not ctx.dry_run and (state["packages"] or state_path().exists()):
        save_state(state)
    return 1 if failed else 0


def status() -> int:
    state = load_state()
    rows = {}
    for name in PACKAGES:
        dest = plugins_dir() / name
        record = state["packages"].get(name)
        rows[name] = {
            "path": str(dest),
            "present": dest.is_dir(),
            "owned": record is not None,
            "method": (record or {}).get("method"),
            "edited": bool(record and record.get("method") == "copy" and record.get("digest") != tree_digest(dest)),
        }
    print(json.dumps(rows, indent=2))
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    for action in ("install", "remove"):
        cmd = sub.add_parser(action)
        cmd.add_argument("--packages", help=f"comma-separated subset of {', '.join(PACKAGES)} (default: all)")
        cmd.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
        cmd.add_argument("--dry-run", action="store_true")
        cmd.add_argument("--force", action="store_true")
        cmd.add_argument("--no-agy", action="store_true", help="place owned copies even when agy is on PATH")
    sub.add_parser("status")
    sub.add_parser("available")
    args = parser.parse_args(argv)
    if args.action == "status":
        return status()
    if args.action == "available":
        found = resolve_agy(False)
        print(found or f"agy not on PATH; plugins are placed in {plugins_dir()}")
        return 0
    ctx = Context(source=args.source, dry_run=args.dry_run, force=args.force, agy=resolve_agy(args.no_agy))
    return run(args.action, ctx, parse_packages(args.packages))


if __name__ == "__main__":
    sys.exit(main())
