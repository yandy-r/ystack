"""On-disk effects for merge_managed_config.py: atomic writes, ownership state and YAML backups."""

from __future__ import annotations

import json
import os
import tempfile
import tomllib
from pathlib import Path
from typing import Any

from managed_config_core import MergeError, collect_managed_leaves, entry_policy_rules, parse_pointer
from managed_config_formats import load_source, load_yaml_config, render_yaml


def atomic_write(path: Path, text: str) -> None:
    """Write via a temp file in the same directory, then rename into place.

    A symlink at ``path`` is replaced by the rename, so the link target (often
    a repo file) is never written through. The target's permission bits are
    carried over so a restrictive mode on a credential-bearing config survives.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else None
    handle = tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    )
    try:
        with handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        if mode is not None:
            os.chmod(handle.name, mode)
        os.replace(handle.name, path)
    except BaseException:
        Path(handle.name).unlink(missing_ok=True)
        raise


def read_state(state_path: Path) -> dict[str, Any]:
    if not state_path.is_file():
        return {}
    try:
        payload = json.loads(state_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        # A corrupt state file must not block installs; ownership simply falls
        # back to the conservative "preserve the user's value" branch.
        return {}
    return payload if isinstance(payload, dict) else {}


def write_state(state_path: Path, state: dict[str, Any]) -> None:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(state_path, json.dumps(state, indent=2, sort_keys=True) + "\n")


def yaml_rewrite_is_lossless(raw: bytes) -> bool:
    """True when re-rendering the file reproduces it byte for byte (ycc's own output).

    Anything else (comments, other formatting, key styles) would be dropped.
    """
    try:
        text = raw.decode("utf-8")
        return not text.strip() or render_yaml(load_yaml_config(text, "config"), "config") == text
    except (UnicodeDecodeError, MergeError):
        return False


def ycc_backups(destination_path: Path) -> list[Path]:
    """``<dest>.ycc-backup`` then ``<dest>.ycc-backup.1``, ``.2``, … up to the first free name.

    The last entry does not exist yet; it is where a new backup goes.
    """
    base = destination_path.with_name(f"{destination_path.name}.ycc-backup")
    names = [base]
    while names[-1].exists() or names[-1].is_symlink():
        names.append(base.with_name(f"{base.name}.{len(names)}"))
    return names


def backup_before_rewrite(profile: dict[str, Any], destination_path: Path) -> None:
    """Save the current file before a rewrite drops its comments or formatting.

    A file that is already ycc's own rendering loses nothing and is not saved.
    Otherwise the bytes go to ``<dest>.ycc-backup``, or to the first free
    ``<dest>.ycc-backup.N`` when the existing backups hold different bytes.
    A backup is never overwritten, and every lossy rewrite warns.
    """
    if not profile.get("backup_original") or not destination_path.is_file():
        return
    original = destination_path.read_bytes()
    if yaml_rewrite_is_lossless(original):
        return
    *existing, free = ycc_backups(destination_path)
    backup = next((path for path in existing if path.is_file() and path.read_bytes() == original), None)
    if backup is None:
        backup = free
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.fchmod(fd, 0o600)
            os.write(fd, original)
            os.fsync(fd)
        finally:
            os.close(fd)
    print(f"  [!!] comments and formatting in {destination_path} are not preserved; original saved to {backup}")


def drop_ycc_only_backups(profile: dict[str, Any], destination_path: Path) -> None:
    """After removing an emptied file, delete the backups ycc itself wrote.

    A backup that is only ycc's own rendering holds no user content; backups
    with comments or other formatting are kept.
    """
    if not profile.get("backup_original"):
        return
    for backup in ycc_backups(destination_path)[:-1]:
        if backup.is_file() and not backup.is_symlink() and yaml_rewrite_is_lossless(backup.read_bytes()):
            backup.unlink()
            print(f"  [ok] removed ycc backup {backup}")


def remove_owns_nothing(
    profile_name: str,
    profile: dict[str, Any],
    groups: list[str],
    source_path: Path,
    destination_path: Path,
    state_path: Path,
) -> bool:
    """True when ``--remove`` has nothing to act on: no managed source leaf and no recorded state.

    Without either, every remover returns "nothing to remove", so the destination need not be read.
    """
    try:
        if collect_managed_leaves(profile, groups, load_source(source_path, profile)):
            return False
    except (MergeError, json.JSONDecodeError, tomllib.TOMLDecodeError):
        return False
    entry = read_state(state_path).get(f"{profile_name}:{destination_path}", {})
    if not isinstance(entry, dict):
        return True
    rules = entry_policy_rules(profile, groups)
    return not any(
        key.startswith("/") and any(parse_pointer(key)[: len(rule["path"])] == rule["path"] for rule in rules)
        for key in entry
    )


def has_state(
    profile_name: str,
    profile: dict[str, Any],
    destination_path: Path,
    state_scope: str | None,
    groups: list[str] | None,
    state_path: Path,
) -> bool:
    """Whether ``<profile>[scope]:<destination>`` has recorded ownership state.

    With ``groups``, only state under those groups' rules counts (unknown
    groups raise ``MergeError``); without, any recorded leaf does.
    """
    scope = f"[{state_scope}]" if state_scope is not None else ""
    entry = read_state(state_path).get(f"{profile_name}{scope}:{destination_path}")
    if not isinstance(entry, dict) or not entry:
        return False
    if groups is None:
        return True
    rules = entry_policy_rules(profile, groups)
    return any(
        key.startswith("/") and any(parse_pointer(key)[: len(rule["path"])] == rule["path"] for rule in rules)
        for key in entry
    )
