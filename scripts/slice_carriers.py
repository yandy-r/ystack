"""Entry primitives and ownership-tracked carriers for install_slices.py.

Strict filesystem carriers (Cursor commands and hooks) track bytes per entry,
reject local edits and preflight the whole selection before changing anything.
Claude command wrappers an older ycc installed under ``~/.claude/commands`` are
retired by ownership: only names recorded in ``installed-units.json`` go.
"""

from __future__ import annotations

import filecmp
import hashlib
import os
import re
import shutil
import sys
import tempfile
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Optional, Protocol, TypeVar

# Claude has no commands slice of its own: skills are the slash commands, so
# 'commands' aliases 'skills' there. Wrappers an older ycc installed under this
# directory are retired by ownership (see retire_legacy_commands).
LEGACY_COMMANDS_DEST = ".claude/commands"

Rewrites = list[tuple[str, str]]
# Optional, not ``X | None``: a runtime alias must evaluate on older python3.
Stage = Callable[[str, Path, Path, Rewrites, Optional["re.Pattern[str]"]], Path]  # noqa: UP045


class CarrierUnit(Protocol):
    """The install_slices.Unit fields a strict carrier reads."""

    @property
    def dest(self) -> str: ...


U = TypeVar("U", bound=CarrierUnit)


class CarrierContext(Protocol):
    """The install_slices.Context fields carriers read (state and hashes are updated in place)."""

    @property
    def home(self) -> Path: ...

    @property
    def force(self) -> bool: ...

    @property
    def state(self) -> dict[str, list[str]]: ...

    @property
    def hashes(self) -> dict[str, str]: ...

    @property
    def dry_run(self) -> bool: ...

    @property
    def skills_dir(self) -> Path | None: ...

    @property
    def skills_pending(self) -> bool: ...


def same_entry(a: Path, b: Path) -> bool:
    """True when two files or trees have identical names and contents."""
    if a.is_symlink() or b.is_symlink():
        return a.is_symlink() and b.is_symlink() and os.readlink(a) == os.readlink(b)
    if a.is_file() and b.is_file():
        return filecmp.cmp(a, b, shallow=False)
    if not (a.is_dir() and b.is_dir()):
        return False
    cmp = filecmp.dircmp(a, b)
    if cmp.left_only or cmp.right_only or cmp.funny_files:
        return False
    _, mismatch, errors = filecmp.cmpfiles(a, b, cmp.common_files, shallow=False)
    if mismatch or errors:
        return False
    return all(same_entry(a / d, b / d) for d in cmp.common_dirs)


def delete_entry(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()


def exists(path: Path) -> bool:
    return path.exists() or path.is_symlink()


def entry_hash(path: Path) -> str:
    """Fingerprint the bytes and executable bit of strict carrier files."""
    return hashlib.sha256(path.read_bytes() + str(path.stat().st_mode & 0o111).encode()).hexdigest()


def missing_command_skills(entries: Mapping[str, Path], skills_dir: Path) -> list[str]:
    """Command entries whose same-named skill is not installed under skills_dir."""
    return [name for name in entries if not (skills_dir / Path(name).stem / "SKILL.md").is_file()]


def strict_unit(
    unit: U,
    ctx: CarrierContext,
    install: bool,
    pick: frozenset[str] | None,
    entries_of: Callable[[U], Mapping[str, Path]],
    stage: Stage,
) -> int:
    """Plan all ownership decisions before mutating a Cursor carrier directory.

    With pick, only those entries are checked and changed: install merges state
    and hashes (never prunes), remove takes back only picked owned entries.
    """
    dest = ctx.home / unit.dest
    key = str(dest)
    for parent in (dest, *dest.parents):
        if parent.is_symlink():
            print(f"[err] refusing symlinked Cursor carrier destination: {parent}", file=sys.stderr)
            return 1
        if parent == ctx.home:
            break
    entries = {name: src for name, src in entries_of(unit).items() if pick is None or name in pick}
    owned = set(ctx.state.get(key, []))
    scope = owned if pick is None else owned & pick
    with tempfile.TemporaryDirectory() as tmp:
        staging = Path(tmp)
        skills_dir = ctx.skills_dir or ctx.home / ".cursor/skills"
        rewrites = [("${CURSOR_PLUGIN_ROOT}/skills/", f"{skills_dir}/")] if unit.dest == ".cursor/commands" else []
        if install and unit.dest == ".cursor/commands" and not ctx.skills_pending:
            missing = missing_command_skills(entries, skills_dir)
            if missing:
                print(
                    f"[err] Cursor commands require installed skills at {skills_dir}: {', '.join(missing)}; "
                    "run install.sh install --target cursor --only skills,commands first",
                    file=sys.stderr,
                )
                return 1
        staged = {name: stage(name, src, staging, rewrites, None) for name, src in entries.items()}
        actions: list[str] = []
        for name in sorted((set(entries) | scope) if install else scope):
            if not name or Path(name).name != name or name in {".", ".."}:
                print("[err] invalid Cursor carrier ownership state", file=sys.stderr)
                return 1
            target = dest / name
            if exists(target):
                wanted = staged.get(name)
                plain = target.is_file() and not target.is_symlink()
                matches = wanted is not None and plain and same_entry(wanted, target)
                recorded = ctx.hashes.get(str(target))
                unchanged = target.is_file() and not target.is_symlink() and recorded == entry_hash(target)
                if not (matches and install or unchanged or ctx.force):
                    print(
                        f"[err] Cursor carrier ownership collision: {target}; "
                        "not owned or locally edited (use --force)",
                        file=sys.stderr,
                    )
                    return 1
                actions.append(name)
            elif install and name in entries:
                actions.append(name)
        if ctx.dry_run:
            for name in actions:
                if install and name in staged:
                    print(f"[dry-run] would copy {entries[name]} -> {dest / name}")
                else:
                    print(f"[dry-run] would remove {dest / name}")
            if not install and dest.is_dir() and set(os.listdir(dest)) <= set(actions):
                print(f"[dry-run] would remove empty directory {dest}")
            return 0
        if install:
            dest.mkdir(parents=True, exist_ok=True)
        for name in actions:
            target = dest / name
            if exists(target):
                delete_entry(target)
            ctx.hashes.pop(str(target), None)
            if install and name in staged:
                shutil.move(str(staged[name]), str(target))
                ctx.hashes[str(target)] = entry_hash(target)
        left = sorted((owned - scope) | set(entries)) if install else sorted(owned - scope)
        if left:
            ctx.state[key] = left
        else:
            ctx.state.pop(key, None)
        if not install and dest.is_dir() and not any(dest.iterdir()):
            dest.rmdir()
    print(f"[ok] Cursor {unit.dest} {'installed' if install else 'removed'}")
    return 0


def retire_legacy_commands(ctx: CarrierContext, pick: frozenset[str] | None = None) -> None:
    """Delete the command wrappers ycc recorded under ~/.claude/commands.

    Only names recorded in installed-units.json go (with pick, only those of
    them); foreign or unrecorded entries (even with --force) stay, and the
    directory goes only when this leaves it empty.
    """
    dest = ctx.home / LEGACY_COMMANDS_DEST
    key = str(dest)
    removed = 0
    left: list[str] = []
    for name in ctx.state.get(key, []):
        if name in ("", ".", "..") or Path(name).name != name:
            continue  # state is user-editable; a recorded name is a plain entry
        if pick is not None and name not in pick:
            left.append(name)
            continue
        target = dest / name
        if not exists(target):
            continue
        # ycc only ever wrote wrapper files; a directory here is user data.
        if not (target.is_symlink() or target.is_file()):
            print(f"[!!]  kept {target}: not a ycc wrapper file")
            continue
        try:
            target.unlink()
            removed += 1
        except OSError as err:
            print(f"[!!]  could not retire {target}: {err}", file=sys.stderr)
            left.append(name)
    if left:
        ctx.state[key] = left
    else:
        ctx.state.pop(key, None)
    if not removed:
        return
    print(f"[ok]  retired {removed} legacy command wrapper{'' if removed == 1 else 's'} from {dest}")
    if not dest.is_symlink() and dest.is_dir() and not any(dest.iterdir()):
        dest.rmdir()
        print(f"[ok]  removed empty directory {dest}")
