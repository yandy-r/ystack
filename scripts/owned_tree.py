#!/usr/bin/env python3
"""Owned-copy primitives shared by the plugin-folder installers.

``antigravity_install.py`` and ``muse_install.py`` both place a ycc-owned copy
of a generated package on disk, fingerprint it so edits are detected, and point
its default home-folder references at a relocated folder when an override is
set. These helpers hold that logic once.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import stat
import tempfile
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any


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


def _make_writable(func: Callable[..., Any], path: str, _exc: object) -> None:
    """rmtree handler: CLIs may stage read-only copies, so grant write and retry."""
    parent = os.path.dirname(path)
    os.chmod(parent, stat.S_IRWXU)
    if os.path.exists(path) and not os.path.islink(path):
        os.chmod(path, stat.S_IRWXU)
    func(path)


def remove_tree(path: Path) -> None:
    # onerror (not onexc) keeps the 3.11 floor; it is deprecated, not removed, in 3.12+.
    shutil.rmtree(path, onerror=_make_writable)


def relocate_tree(root: Path, prefixes: Sequence[str], target: str) -> None:
    """Replace each of ``prefixes`` with ``target`` in ``root``'s UTF-8 text files."""
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        updated = text
        for prefix in prefixes:
            updated = updated.replace(prefix, target)
        if updated != text:
            mode = path.stat().st_mode
            path.write_text(updated, encoding="utf-8")
            path.chmod(mode)


def place_copy(src: Path, dest: Path, rewrite: Callable[[Path], None] | None = None) -> None:
    """Copy ``src`` to ``dest`` through a sibling temp dir, replacing ``dest`` last.

    ``rewrite`` (if given) runs on the staged copy before it replaces ``dest``.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{dest.name}.", dir=dest.parent))
    try:
        shutil.copytree(src, staging / dest.name, symlinks=True)
        if rewrite is not None:
            rewrite(staging / dest.name)
        if dest.exists() or dest.is_symlink():
            remove_tree(dest) if dest.is_dir() and not dest.is_symlink() else dest.unlink()
        (staging / dest.name).rename(dest)
    finally:
        if staging.exists():
            remove_tree(staging)
