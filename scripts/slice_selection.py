"""Per-entry selection for install_slices.py (``--entries`` and ``list``).

Selector names are what users type: the entry name for directories, the file
stem for files (``implementor.md`` / ``implementor.toml`` -> ``implementor``).
Helper entries (``_shared``, ``shared``, ``ycc-shared``, a unit's ``extra``
entries and every entry of a slice's later units) are never selectable; they
ship with any selection and leave only with the last owned entry.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Callable, Iterable, Mapping, Sequence
from pathlib import Path
from typing import NoReturn, Protocol, TypeVar

HELPER_NAMES = frozenset({"_shared", "ycc-shared"})
KINDS = ("skills", "agents")


class UnitLike(Protocol):
    """The install_slices.Unit fields selection reads."""

    @property
    def dest(self) -> str: ...

    @property
    def extra(self) -> Mapping[str, str]: ...

    @property
    def strict(self) -> bool: ...


U = TypeVar("U", bound=UnitLike)


class ContextLike(Protocol):
    """The install_slices.Context fields selection reads."""

    @property
    def home(self) -> Path: ...

    @property
    def state(self) -> dict[str, list[str]]: ...


def selector(name: str, src: Path) -> str:
    return Path(name).stem if src.is_file() else name


def selectable(entries: Mapping[str, Path], extra: Iterable[str]) -> dict[str, str]:
    """Selector name -> entry name for the user-pickable entries of a slice's first unit."""
    hidden = HELPER_NAMES | set(extra)
    return {selector(name, src): name for name, src in entries.items() if name not in hidden}


def parse_entries(raw: str) -> list[str]:
    names: list[str] = []
    for part in raw.split(","):
        name = part.strip()
        if name and name not in names:
            names.append(name)
    return names


def pick_entries(
    entries: Mapping[str, Path], extra: Iterable[str], raw: str, where: tuple[str, str]
) -> frozenset[str] | str:
    """Entry names ``raw`` selects among a unit's selectable entries, or an error line for unknown names."""
    names = selectable(entries, extra)
    wanted = parse_entries(raw)
    unknown = [name for name in wanted if name not in names] or ([] if wanted else ["(none)"])
    if unknown:
        noun = "entry" if len(unknown) == 1 else "entries"
        valid = ", ".join(sorted(names))
        return f"[err] unknown {where[0]} {noun} for {where[1]}: {', '.join(unknown)} (valid: {valid})"
    return frozenset(names[name] for name in wanted)


def plan_selection(
    units_entries: Sequence[Mapping[str, Path]],
    extra: Iterable[str],
    raw: str,
    owned_first: Iterable[str],
    present_first: Iterable[str],
    install: bool,
    where: tuple[str, str],
) -> list[frozenset[str] | None] | str:
    """Entry names each unit acts on for ``--entries`` (None = the whole unit), or an error line.

    Install ships the chosen entries plus every helper. Remove takes the chosen
    entries; helpers go only when no other non-helper entry remains in the first
    unit's destination, recorded in state or present on disk (a 'base' mirror
    records nothing). ``where`` is (slice, target) for the message.
    """
    hidden = HELPER_NAMES | set(extra)
    chosen = pick_entries(units_entries[0], extra, raw, where)
    if isinstance(chosen, str):
        return chosen
    helpers = frozenset(n for n in units_entries[0] if n in hidden)
    rest = len(units_entries) - 1
    if install:
        return [chosen | helpers, *(frozenset(entries) for entries in units_entries[1:])]
    if {n for n in (*owned_first, *present_first) if n not in hidden} - chosen:
        return [chosen, *([frozenset()] * rest)]
    owned_helpers = frozenset(n for n in owned_first if n in hidden)
    return [chosen | helpers | owned_helpers, *([None] * rest)]


def print_selectable(
    args: argparse.Namespace,
    specs: Mapping[tuple[str, str], Sequence[U]],
    entries_of: Callable[[U], Mapping[str, Path]],
) -> int:
    """``list``: print the user-selectable names of a slice's first unit, sorted, one per line.

    Claude has no commands slice of its own: ``commands`` lists its skills.
    """
    slice_name = "skills" if (args.target, args.slice) == ("claude", "commands") else args.slice
    units = specs.get((args.target, slice_name))
    if units:
        for name in sorted(selectable(entries_of(units[0]), units[0].extra)):
            print(name)
    return 0


def plan_run(
    args: argparse.Namespace,
    units: Sequence[U],
    entries_of: Callable[[U], Mapping[str, Path]],
    home: Path,
    state: Mapping[str, list[str]],
    fail: Callable[[str], NoReturn],
) -> list[tuple[U, frozenset[str] | None]] | None:
    """(unit, pick) pairs one install_slices run acts on (pick None = the whole unit); None after an error.

    Without ``--entries`` (or without units: claude commands remove, see
    legacy_wrapper_pick) every unit runs whole. ``fail`` rejects ``--entries``
    on the hooks slice, which ships one fixed entry.
    """
    if args.entries is None or not units:
        return [(unit, None) for unit in units]
    if args.slice == "hooks":
        fail("--entries is not supported for the hooks slice")
    entries = [entries_of(unit) for unit in units]
    first = home / units[0].dest
    present = [n for n in entries[0] if (first / n).exists() or (first / n).is_symlink()]
    owned = state.get(str(first), [])
    where = (args.slice, args.target)
    plan = plan_selection(entries, units[0].extra, args.entries, owned, present, args.action == "install", where)
    if isinstance(plan, str):
        print(plan, file=sys.stderr)
        return None
    return [(unit, pick) for unit, pick in zip(units, plan, strict=True) if pick is None or pick]


def legacy_wrapper_pick(
    args: argparse.Namespace, skills: U, entries_of: Callable[[U], Mapping[str, Path]]
) -> frozenset[str] | None:
    """Claude ``remove --slice commands --entries``: the legacy wrapper names (``<name>.md``) to retire.

    Names are claude skills (its commands); None after printing an unknown-name error.
    """
    chosen = pick_entries(entries_of(skills), skills.extra, args.entries, ("commands", args.target))
    if isinstance(chosen, str):
        print(chosen, file=sys.stderr)
        return None
    return frozenset(f"{name}.md" for name in chosen)
