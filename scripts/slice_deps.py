"""``ycc:<name>`` dependencies of selected skills and agents for install_slices.py.

After a selective install, the canonical sources of the selected entries are
scanned for ``ycc:<name>`` references so missing skills and agents can be
reported per target (warn only).

``closure`` (``install_slices.py closure``, behind ``install.sh --with-deps``)
walks the same references from a selection and names the units to add to it.
"""

from __future__ import annotations

import argparse
import os
import re
from collections.abc import Callable, Iterable, Mapping, Sequence
from pathlib import Path

from slice_selection import KINDS, ContextLike, U, parse_entries, selectable

NOUN = {"skills": "skill", "agents": "agent"}
# Agents that only make sense when a dispatching skill is available.
DISPATCHED_AGENTS = frozenset(
    {
        "backport-conflict-resolver",
        "pr-comment-fixer",
        "release-fix-applier",
        "releaser",
        "review-fixer",
        "git-cleanup",
    }
)
# Targets whose skills also resolve from the cross-tool ~/.agents/skills.
AGENTS_SKILLS_READERS = frozenset({"codex", "cursor"})

Ref = tuple[str, bool]  # (referenced name, written as '/ycc:<name>')


def print_dependency_warnings(
    args: argparse.Namespace,
    kind: str,
    conflicts: int,
    repo_root: Path,
    specs: Mapping[tuple[str, str], Sequence[U]],
    ctx: ContextLike,
) -> None:
    """After a clean selective install of ``kind`` on ``args.target``, print its dependency warnings.

    Commands get none: the only command slice is a strict carrier (cursor) that
    already failed closed on a missing skill.
    """
    if conflicts or args.action != "install" or args.entries is None or kind == "commands":
        return
    dests = {k: specs[(args.target, k)][0].dest for k in KINDS if (args.target, k) in specs}
    lines = dependency_warnings(repo_root, ctx.home, args.target, kind, parse_entries(args.entries), ctx.state, dests)
    for line in lines:
        print(line)


class References:
    """``ycc:<name>`` references in the canonical ycc skill and agent sources."""

    def __init__(self, repo_root: Path) -> None:
        self.root = repo_root / "ycc"
        self.names: dict[str, frozenset[str]] = {}
        for kind in KINDS:
            base = self.root / kind
            found = (p.stem for p in base.iterdir() if not p.name.startswith((".", "_"))) if base.is_dir() else ()
            self.names[kind] = frozenset(found)
        everything = self.names["skills"] | self.names["agents"]
        alternation = "|".join(sorted(map(re.escape, everything), key=len, reverse=True)) or "(?!)"
        self.pattern = re.compile(rf"(?<![A-Za-z0-9_-])(/?)ycc:({alternation})(?![A-Za-z0-9_-])")
        self._cache: dict[tuple[str, str], frozenset[Ref]] = {}

    def of(self, kind: str, name: str) -> frozenset[Ref]:
        key = (kind, name)
        if key not in self._cache:
            src = self.root / kind / name if kind == "skills" else self.root / kind / f"{name}.md"
            files = [src] if src.is_file() else sorted(p for p in src.rglob("*") if p.is_file()) if src.is_dir() else []
            refs: set[Ref] = set()
            for path in files:
                try:
                    text = path.read_text(encoding="utf-8")
                except (UnicodeDecodeError, OSError):
                    continue
                refs.update((m.group(2), bool(m.group(1))) for m in self.pattern.finditer(text))
            self._cache[key] = frozenset(refs)
        return self._cache[key]

    def kinds(self, ref: Ref, referrer_kind: str, referrer: str) -> list[str]:
        """Kinds a reference may mean; a name both skill and agent satisfies either."""
        name, slash = ref
        kinds = [kind for kind in KINDS if name in self.names[kind]]
        if name == referrer:
            # A unit naming itself means the other kind of the same name, if any.
            kinds = [kind for kind in kinds if kind != referrer_kind]
        elif slash and "skills" in kinds:
            kinds = ["skills"]  # '/ycc:<name>' is a slash command
        return kinds

    def dispatchers(self, agent: str) -> list[str]:
        """Skills that reference the agent as 'ycc:<agent>' (not as a slash command)."""
        return sorted(s for s in self.names["skills"] if (agent, False) in self.of("skills", s))


class Availability:
    """Whether a skill or agent is usable on one target after the install.

    ``YCC_PENDING_SKILLS`` / ``YCC_PENDING_AGENTS`` (comma-separated, ``*`` for
    every entry; set by the installer) name entries another slice of the same
    run installs on this target; ``pending=False`` ignores them.
    """

    def __init__(
        self,
        home: Path,
        target: str,
        state: Mapping[str, list[str]],
        dests: Mapping[str, str],
        pending: bool = True,
    ) -> None:
        self.home = home
        self.target = target
        self.state = state
        self.dests = dests
        self.pending = {
            kind: set(parse_entries(os.environ.get(f"YCC_PENDING_{kind.upper()}", "") if pending else ""))
            for kind in KINDS
        }
        self.plugin = False
        if target == "claude":
            plugins = home / ".claude/plugins/installed_plugins.json"
            try:
                self.plugin = plugins.is_file() and '"ycc@ycc"' in plugins.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                self.plugin = False
        elif target == "codex":
            self.plugin = (home / ".codex/plugins/ycc").exists()

    def has(self, kind: str, name: str) -> bool:
        if self.plugin or name in self.pending[kind] or "*" in self.pending[kind]:
            return True
        dest = self.home / self.dests[kind]
        recorded = self.state.get(str(dest), [])
        if any(c in recorded or (dest / c).exists() for c in (name, f"{name}.md", f"{name}.toml")):
            return True
        shared_home = self.home / ".agents/skills" / name
        return kind == "skills" and self.target in AGENTS_SKILLS_READERS and shared_home.exists()

    def owned(self, kind: str, name: str) -> bool:
        """True when ycc recorded the unit in installed-units.json for this target's destination."""
        recorded = self.state.get(str(self.home / self.dests[kind]), [])
        return any(c in recorded for c in (name, f"{name}.md", f"{name}.toml"))


def dependency_warnings(
    repo_root: Path,
    home: Path,
    target: str,
    kind: str,
    selected: Iterable[str],
    state: Mapping[str, list[str]],
    dests: Mapping[str, str],
) -> list[str]:
    """Warn lines for references the selected entries make to units missing on the target."""
    if kind not in KINDS:
        return []
    refs = References(repo_root)
    avail = Availability(home, target, state, dests)
    missing: dict[tuple[str, str], set[str]] = {}
    lines: list[str] = []
    for name in sorted(set(selected)):
        dispatched = kind == "agents" and name in DISPATCHED_AGENTS and "skills" in dests
        skills = refs.dispatchers(name) if dispatched else []
        if skills and not any(avail.has("skills", s) for s in skills):
            lines.append(
                f"[!!]  {target}: agent '{name}' is dispatched only by {', '.join(skills)}, none installed"
                f" — add one: ycc sync --target {target} --intent skills --skills {skills[0]}"
            )
        for ref in sorted(refs.of(kind, name)):
            kinds = [k for k in refs.kinds(ref, kind, name) if k in dests]
            if ref[0] in skills and kinds == ["skills"]:
                continue  # covered by the dispatcher warning above
            if kinds and not any(avail.has(k, ref[0]) for k in kinds):
                missing.setdefault((kinds[0], ref[0]), set()).add(name)
    for (ref_kind, ref_name), referrers in sorted(missing.items()):
        lines.append(
            f"[!!]  {target}: {NOUN[ref_kind]} '{ref_name}' is referenced by {', '.join(sorted(referrers))}"
            f" but not installed — add it: ycc sync --target {target} --intent {ref_kind} --{ref_kind} {ref_name}"
        )
    return lines


def closure(
    repo_root: Path,
    avail: Availability,
    seeds: Mapping[str, Iterable[str]],
    shipped: Mapping[str, Iterable[str]],
) -> dict[str, list[str]]:
    """Units to add to each selected kind so its ``ycc:<name>`` references resolve on the target.

    ``seeds`` maps each selected kind to its names; only those kinds grow, and a
    reference to another kind is not followed. Names the target does not ship
    (``shipped``) are ignored. A reachable unit is added when the target ships it
    and it is not available from elsewhere, or when ycc owns it (so a sync
    refreshes it). A unit available from elsewhere is not added, but its own
    references are still walked. With the ycc plugin installed nothing is added.
    """
    ships = {kind: frozenset(names) for kind, names in shipped.items()}
    chosen = {kind: {n for n in names if n in ships.get(kind, ())} for kind, names in seeds.items()}
    added: dict[str, set[str]] = {kind: set() for kind in seeds}
    if avail.plugin:
        return {kind: [] for kind in seeds}
    refs = References(repo_root)
    queue = [(kind, name) for kind in seeds for name in sorted(chosen[kind])]
    visited = set(queue)
    while queue:
        kind, name = queue.pop()
        for ref in sorted(refs.of(kind, name)):
            kinds = [k for k in refs.kinds(ref, kind, name) if k in avail.dests]
            if any(ref[0] in chosen.get(k, ()) for k in kinds):
                continue
            selected = [k for k in kinds if k in chosen]
            if any(avail.has(k, ref[0]) and not avail.owned(k, ref[0]) for k in kinds):
                # Available from elsewhere: never shadow it, but follow its references.
                if not selected:
                    continue
                walk = selected[0]
            else:
                into = [k for k in kinds if ref[0] in ships.get(k, ())]
                if not into:
                    continue
                walk = into[0]
                chosen[walk].add(ref[0])
                added[walk].add(ref[0])
            if (walk, ref[0]) not in visited:
                visited.add((walk, ref[0]))
                queue.append((walk, ref[0]))
    return {kind: sorted(names) for kind, names in added.items()}


def print_closure(
    args: argparse.Namespace,
    repo_root: Path,
    specs: Mapping[tuple[str, str], Sequence[U]],
    entries_of: Callable[[U], Mapping[str, Path]],
    home: Path,
    state: Mapping[str, list[str]],
) -> int:
    """``closure``: print ``<kind>\\t<added names>`` per selected kind the target has a slice for."""
    raw = {"skills": args.skills, "agents": args.agents}
    seeds = {k: parse_entries(raw[k]) for k in KINDS if raw[k] is not None and (args.target, k) in specs}
    shipped = {k: selectable(entries_of(specs[(args.target, k)][0]), specs[(args.target, k)][0].extra) for k in seeds}
    dests = {k: specs[(args.target, k)][0].dest for k in KINDS if (args.target, k) in specs}
    avail = Availability(home, args.target, state, dests, pending=False)
    for kind, names in closure(repo_root, avail, seeds, shipped).items():
        print(f"{kind}\t{','.join(names)}")
    return 0
