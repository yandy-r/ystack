#!/usr/bin/env python3
"""Retire proven installer-owned legacy state after a native package install (internal helper)."""

from __future__ import annotations

import argparse
import contextlib
import functools
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path
from typing import Any, NamedTuple

from codex_marketplace import validate_marketplace_catalog
from generate_codex_plugin import (
    MIGRATION_PACKAGES,
    build_repository_marketplace,
    native_packages,
    native_version,
    repository_native_enabled,
)
from install_slices import (
    SPECS,
    namespace_pattern,
    project_cursor_init,
    rewrites_for,
    shipped_entries,
    stage,
)
from install_slices import (
    load_state as load_slice_state,
)
from install_slices import (
    save_state as save_slice_state,
)
from install_slices import (
    state_path as slice_state_path,
)
from merge_managed_config import (
    ADDED_ITEMS_KEY,
    PROFILES,
    load_json_config,
    load_state,
    remove_hook_commands,
    value_hash,
)
from package_model import load_package_model
from validate_codex_native import check_catalog, check_package

ROOT = Path(__file__).resolve().parent.parent
PACKAGES = MIGRATION_PACKAGES
# Repo-mode catalog entries written before the GitHub rename pointed at this URL. This literal is
# historical data: install_migrate.py is deliberately not in rename_repo.ALLOWLIST_FILES.
PRE_RENAME_REPO_URL = "https://github.com/yandy-r/claude-plugins.git"
REPO_URL = "https://github.com/yandy-r/ystack.git"
# File-copy units the retired opencode installer mirrored into ~/.config/opencode (shared/ after
# skills so retained skills keep their helpers), and the guard plugins item it merged.
OPENCODE_UNITS = ("skills", "agents", "commands", "shared", "ycc-sensitive-guard")
GUARD_PLUGIN = "./ycc-sensitive-guard"


def legacy_catalog_entries() -> list[dict[str, Any]]:
    """Return every exact ycc entry the retired installer wrote into ~/.agents/plugins/marketplace.json."""

    def entry(source: dict[str, str]) -> dict[str, Any]:
        return {
            "name": "ycc",
            "source": source,
            "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
            "category": "Productivity",
        }

    def repo(url: str) -> dict[str, str]:
        return {"source": "git-subdir", "url": url, "path": "./.codex-plugin/ycc", "ref": "main"}

    return [
        entry({"source": "local", "path": "./.agents/plugins/ycc"}),
        entry({"source": "local", "path": "./plugins/ycc"}),
        entry(repo(REPO_URL)),
        entry(repo(PRE_RENAME_REPO_URL)),
    ]


def load_json(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"expected JSON object: {path}")
    return data


def trusted_source(path: Path, root: Path) -> None:
    """Reject sources that escape their expected root through symlinks."""
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"untrusted source path escapes root: {path}")


def reject_escaping_symlinks(root: Path, *, any_link: bool = False) -> None:
    """Refuse a source tree whose links escape it (or any link when projecting).

    Projection helpers write through links, so this runs before any staging.
    """
    base = root.resolve()
    paths = [root, *root.rglob("*")] if root.is_dir() else [root]
    for path in paths:
        if path.is_symlink() and (any_link or not path.resolve().is_relative_to(base)):
            raise ValueError(f"untrusted symlink in canonical source: {path}")


def safe_parent(path: Path) -> bool:
    """Never traverse a user's linked configuration directories."""
    return not any(parent.is_symlink() for parent in path.parents)


def identical(left: Path, right: Path) -> bool:
    """Compare bytes and link text recursively, never following interior links."""
    if left.is_symlink() or right.is_symlink():
        return left.is_symlink() and right.is_symlink() and os.readlink(left) == os.readlink(right)
    if left.is_file() and right.is_file():
        return left.read_bytes() == right.read_bytes()
    if left.is_dir() and right.is_dir():
        names = {p.name for p in left.iterdir()}
        return names == {p.name for p in right.iterdir()} and all(identical(left / n, right / n) for n in names)
    return False


def owned_link(path: Path, source: Path) -> bool:
    return path.is_symlink() and path.resolve() == source.resolve()


def _render_combined_codex_bundle(root: Path, *, expand_home: bool) -> Path:
    """Render the pre-listing combined bundle into ``root`` (legacy-path skills)."""
    from generate_codex_common import SOURCE_MCP_PATH
    from generate_codex_plugin import build_plugin_manifest, write_json
    from generate_codex_skills import write_tree

    write_tree(root, dry_run=False, native_paths=False, expand_home=expand_home)
    write_json(root / ".codex-plugin/plugin.json", build_plugin_manifest())
    shutil.copyfile(SOURCE_MCP_PATH, root / ".mcp.json")
    return root


def legacy_codex_baselines(root: Path) -> tuple[Path, ...]:
    """Return combined Codex bundles (current and pre-fix) for ownership comparison.

    Before listing the checkout already holds the current combined form.
    Once a listed row flips the checkout to skills-only native, render it
    (legacy-path skills, combined manifest, original .mcp.json) into
    ``root / "current"``; the checkout itself is never modified. The second
    entry is the pre-home-expansion render (quoted ``"~/.codex/`` fallbacks)
    under ``root / "pre-home"``, matching what releases installed before the
    SC2088 fix shipped.
    """
    live = ROOT / ".codex-plugin/ycc"
    if (live / ".mcp.json").is_file():
        current = live
    else:
        current = _render_combined_codex_bundle(root / "current", expand_home=True)
    return (current, _render_combined_codex_bundle(root / "pre-home", expand_home=False))


def git_tree_id(path: Path, algorithm: str) -> str | None:
    """Return the git tree id `path` would have, without writing objects.

    None when git could not hold the tree byte-identically (empty or special
    entries), so such a tree can never match a committed one.
    """

    def digest(kind: str, body: bytes) -> bytes:
        return hashlib.new(algorithm, f"{kind} {len(body)}\0".encode() + body).digest()

    def tree(directory: Path) -> bytes | None:
        entries: list[tuple[bytes, bytes]] = []
        for child in directory.iterdir():
            name = os.fsencode(child.name)
            if child.is_symlink():
                entries.append((name, b"120000 " + name + b"\0" + digest("blob", os.fsencode(os.readlink(child)))))
            elif child.is_file():
                mode = b"100755" if child.stat().st_mode & 0o100 else b"100644"
                entries.append((name, mode + b" " + name + b"\0" + digest("blob", child.read_bytes())))
            elif child.is_dir():
                sub = tree(child)
                if sub is None:
                    return None
                entries.append((name + b"/", b"40000 " + name + b"\0" + sub))
            else:
                return None
        if not entries:
            return None
        return digest("tree", b"".join(entry for _, entry in sorted(entries)))

    if path.is_symlink() or not path.is_dir():
        return None
    root = tree(path)
    return root.hex() if root is not None else None


class OpencodeHistory(NamedTuple):
    """Committed `.opencode-plugin/<unit>/<entry>` object ids, as ``<kind>:<id>`` per ``<unit>/<entry>``."""

    algorithm: str
    ids: dict[str, frozenset[str]]


def _object_kind(mode: str) -> str:
    return {"040000": "tree", "120000": "link"}.get(mode, "blob")


def object_id(path: Path, algorithm: str) -> str | None:
    """``<kind>:<git object id>`` of a file, symlink or directory, without writing objects."""

    def blob(body: bytes) -> str:
        return hashlib.new(algorithm, f"blob {len(body)}".encode() + b"\0" + body).hexdigest()

    if path.is_symlink():
        return f"link:{blob(os.fsencode(os.readlink(path)))}"
    if path.is_file():
        return f"blob:{blob(path.read_bytes())}"
    tree = git_tree_id(path, algorithm)
    return f"tree:{tree}" if tree is not None else None


@functools.cache
def opencode_history(root: Path) -> OpencodeHistory | None:
    """Every object the file-copy units held at `.opencode-plugin/<unit>/<entry>` in HEAD history.

    The retired installer mirrored those entries verbatim (rsync -a), so an untouched copy of
    any earlier release equals one of them. Read-only; None when git or history is unavailable.
    """
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    paths = [f".opencode-plugin/{unit}" for unit in OPENCODE_UNITS]

    def git(*args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(root), *args], check=True, capture_output=True, text=True, env=env
        ).stdout

    try:
        if Path(git("rev-parse", "--show-toplevel").strip()).resolve() != root.resolve():
            return None
        algorithm = git("rev-parse", "--show-object-format").strip()
        raw = git("log", "--raw", "-t", "-r", "--no-abbrev", "--no-renames", "--format=", "--", *paths)
    except (OSError, subprocess.CalledProcessError):
        return None
    if algorithm not in {"sha1", "sha256"}:
        return None
    null = "0" * (40 if algorithm == "sha1" else 64)
    ids: dict[str, set[str]] = {}
    for line in raw.splitlines():
        meta, _, name = line.partition("\t")
        fields = meta.lstrip(":").split()
        parts = name.split("/")
        if len(fields) < 4 or len(parts) != 3:
            continue
        key = f"{parts[1]}/{parts[2]}"
        for mode, oid in ((fields[0], fields[2]), (fields[1], fields[3])):
            if oid != null:
                ids.setdefault(key, set()).add(f"{_object_kind(mode)}:{oid}")
    return OpencodeHistory(algorithm, {key: frozenset(value) for key, value in ids.items()})


class ReleasedTrees(NamedTuple):
    """Committed `.codex-plugin/ycc` tree ids; `shallow` when older history is missing."""

    algorithm: str
    trees: frozenset[str]
    shallow: bool


def released_codex_trees(root: Path) -> ReleasedTrees | None:
    """Return every `.codex-plugin/ycc` tree id in this checkout's HEAD history.

    A legacy cache is a verbatim copy of the checkout's bundle at install
    time, so an untouched snapshot of an older release equals one of these
    trees. A shallow checkout still matches the releases it holds and reports
    itself shallow. Read-only; None when git or this checkout's history is
    unavailable.
    """

    # Inherited GIT_DIR/GIT_WORK_TREE/... (e.g. from a hook) would point git elsewhere.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}

    def git(*args: str, stdin: str | None = None) -> str:
        return subprocess.run(
            ["git", "-C", str(root), *args], check=True, capture_output=True, text=True, input=stdin, env=env
        ).stdout

    try:
        if Path(git("rev-parse", "--show-toplevel").strip()).resolve() != root.resolve():
            return None
        algorithm = git("rev-parse", "--show-object-format").strip()
        shallow = git("rev-parse", "--is-shallow-repository").strip() == "true"
        commits = git("rev-list", "--full-history", "HEAD", "--", ".codex-plugin/ycc").split()
        if algorithm not in {"sha1", "sha256"} or not commits:
            return None
        lookup = "".join(f"{commit}:.codex-plugin/ycc\n" for commit in commits)
        checked = git("cat-file", "--batch-check=%(objectname) %(objecttype)", stdin=lookup)
    except (OSError, subprocess.CalledProcessError):
        return None
    trees = frozenset(line.split()[0] for line in checked.splitlines() if line.endswith(" tree"))
    return ReleasedTrees(algorithm, trees, shallow)


@functools.cache
def historical_claude_commands(root: Path) -> dict[str, list[bytes]] | None:
    """Every distinct ycc/commands/<name> blob in this checkout's HEAD history.

    The old Claude commands slice copied these files into ~/.claude/commands;
    the directory has since been retired, so ownership proof needs history.
    None when git or this checkout's history is unavailable.
    """
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}

    def git(*args: str) -> bytes:
        return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, env=env).stdout

    try:
        if Path(git("rev-parse", "--show-toplevel").decode().strip()).resolve() != root.resolve():
            return None
        commits = git("rev-list", "--full-history", "HEAD", "--", "ycc/commands").decode().split()
        blobs: dict[str, set[str]] = {}
        for commit in commits:
            for line in git("ls-tree", commit, "ycc/commands/").decode().splitlines():
                meta, _, path = line.partition("\t")
                fields = meta.split()
                if len(fields) == 3 and fields[1] == "blob":
                    blobs.setdefault(Path(path).name, set()).add(fields[2])
        return {name: [git("cat-file", "blob", blob) for blob in sorted(ids)] for name, ids in blobs.items()}
    except (OSError, subprocess.CalledProcessError):
        return None


def codex_rewrite_sets(home: Path) -> tuple[list[tuple[str, str]], ...]:
    """Return the current projected rewrites plus the historical narrow form.

    Before `../../shared/` was broadened, installs projected only the plugin
    roots and shared references into the standalone location.
    """
    historical = [
        ("~/.codex/plugins/ycc/skills/", "~/.codex/skills/"),
        ("~/.codex/plugins/ycc/shared/", "~/.codex/skills/_shared/"),
        ("../../../shared/", "../../_shared/"),
        ("../../shared/references/", "../_shared/references/"),
        ("<installed ycc plugin root>/shared/references/", f"{home}/.codex/skills/_shared/references/"),
    ]
    return rewrites_for("codex", home), historical


class Migration:
    def __init__(self, apply: bool) -> None:
        self.apply = apply
        self.home = Path.home()
        # Native Cursor packages whose legacy carriers this run retired (or would retire).
        self.cursor_retired: set[str] = set()
        # omp_install.MigratePlan, set by main's preflight (omp_install is imported lazily).
        self.omp_plan: Any = None

    @functools.cached_property
    def released_trees(self) -> ReleasedTrees | None:
        """Load released_codex_trees(ROOT) once, reporting when it is unavailable."""
        released = released_codex_trees(ROOT)
        if released is None:
            print(f"[!!] {ROOT}: git history unavailable; older-release snapshots cannot be proven owned")
        return released

    def remove(
        self,
        path: Path,
        sources: tuple[Path, ...],
        *,
        links_only: bool = False,
        history: bool = False,
    ) -> bool:
        """Remove only proven-owned entries; True when removed (or would be).

        With `history`, a real directory is also owned when its tree equals a
        committed `.codex-plugin/ycc` (see released_codex_trees).
        """
        if not path.exists() and not path.is_symlink():
            return False
        if not safe_parent(path):
            print(f"[!!] kept {path}: symlinked parent directory")
            return False
        ours = any(owned_link(path, src) or (not links_only and identical(path, src)) for src in sources)
        released = self.released_trees if not ours and history and not links_only else None
        if released is not None:
            ours = git_tree_id(path, released.algorithm) in released.trees
        if not ours:
            if released is not None and released.shallow:
                print(
                    f"[!!] kept {path}: not in this shallow checkout's history; "
                    "run 'git fetch --unshallow' and rerun the install"
                )
            else:
                print(f"[!!] kept {path}: edited or ownership uncertain")
            return False
        print(f"[ok] {'remove' if self.apply else 'would remove'} {path}")
        if self.apply:
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
        return True

    def merge_remove(self, profile: str, source: Path, dest: Path, groups: str, *extra: str) -> None:
        if dest.is_symlink():
            print(f"[!!] kept {dest}: symlinked config file (target and ownership state retained)")
            return
        if not safe_parent(dest):
            print(f"[!!] kept {dest}: symlinked parent directory")
            return
        command = [
            sys.executable,
            str(ROOT / "scripts/merge_managed_config.py"),
            "--remove",
            "--profile",
            profile,
            "--source",
            str(source),
            "--destination",
            str(dest),
            "--groups",
            groups,
            *extra,
        ]
        if not self.apply:
            command.append("--dry-run")
        subprocess.run(command, check=True)

    def claude(self, *, removing: bool = False) -> None:
        """Retire legacy Claude installer state the enabled native packages replace.

        ``removing`` (from 'install.sh remove --intent base'): ycc@ycc is gone,
        so its standalone copies are retired without the enablement proof.
        """
        claude_dir = self.home / ".claude"
        if claude_dir.is_symlink() or not safe_parent(claude_dir / "entry"):
            print(f"[!!] kept {claude_dir}: symlinked configuration directory (no Claude cleanup)")
            return
        dest = claude_dir / "settings.json"
        settings = load_json(dest) if dest.is_file() else {}
        enabled = settings.get("enabledPlugins", {})
        if not isinstance(enabled, dict):
            enabled = {}
        # Installed registry membership or ycc-all's dependency closure is NOT
        # evidence of explicit enablement at user scope.
        if removing or enabled.get("ycc@ycc") is True:
            self.claude_slices()
        else:
            print("[!!] Claude standalone skills/agents retained: ycc@ycc is not explicitly enabled")
        if dest.is_symlink():
            print(f"[!!] kept {dest}: symlinked config file (hooks, target and ownership state retained)")
            return
        if enabled.get("ycc-hooks@ycc") is True:
            self.merge_remove(
                "claude-settings", ROOT / "ycc/settings/settings.json", dest, "hooks", "--prune-hook-commands"
            )
            current = load_json(dest) if dest.exists() else {}
            if not self.apply:
                # Use the engine's pure plan, including event-hash and wrapper
                # proof. Command-string subtraction would falsely forecast
                # unlinking when ownership or a matcher is uncertain.
                state_entry = load_state().get(f"claude-settings:{dest}", {})
                if not isinstance(state_entry, dict):
                    state_entry = {}
                rendered, _, _, _ = remove_hook_commands(
                    load_json(ROOT / "ycc/settings/settings.json"),
                    dest,
                    PROFILES["claude-settings"],
                    ["hooks"],
                    state_entry,
                    False,
                )
                if rendered is not None:
                    current = json.loads(rendered)

            def commands(value: Any) -> list[str]:
                if isinstance(value, dict):
                    return ([value["command"]] if isinstance(value.get("command"), str) else []) + [
                        c for k, v in value.items() if k != "command" for c in commands(v)
                    ]
                if isinstance(value, list):
                    return [c for v in value for c in commands(v)]
                return []

            remaining = commands(current.get("hooks", {}))
            if any(".claude/hooks" in c for c in remaining):
                print("[!!] kept ~/.claude/hooks: remaining hooks may use it")
            else:
                self.remove(self.home / ".claude/hooks", (ROOT / "ycc/settings/hooks",), links_only=True)
        else:
            print("[!!] Claude hooks retained: ycc-hooks@ycc is not explicitly enabled")
        if isinstance(enabled, dict) and enabled.get("ycc-mcp@ycc") is True:
            self.merge_remove("claude-mcp", ROOT / "mcp-configs/mcp.json", self.home / ".claude.json", "mcp")
        else:
            print("[!!] Claude MCP retained: ycc-mcp@ycc is not explicitly enabled")
        print("Claude legacy cleanup complete (global scope only).")

    def claude_slices(self) -> None:
        """Retire standalone ~/.claude/{skills,agents} copies and legacy command wrappers.

        An entry goes only when its bytes equal what the old installer wrote:
        the canonical source, raw or projected (plugin-root rewrites, ycc:
        namespace stripped). Wrappers are matched against every historical
        ycc/commands version. Recorded names alone never prove ownership, so
        recorded-but-edited entries stay and are reported.
        """
        rewrites = rewrites_for("claude", self.home)
        state_file = slice_state_path()
        state = load_slice_state(state_file)
        retired: dict[str, set[str]] = {}
        with tempfile.TemporaryDirectory(prefix="ycc-cleanup-") as tmp:
            staging = Path(tmp)
            for slice_name in ("skills", "agents"):
                unit = SPECS[("claude", slice_name)][0]
                dest = self.home / unit.dest
                if not dest.is_dir() or dest.is_symlink():
                    continue
                entries = shipped_entries(unit)
                gone: set[str] = set()

                def candidates(name: str, src: Path, slice_name: str = slice_name) -> tuple[Path, ...]:
                    trusted_source(src, ROOT)
                    reject_escaping_symlinks(src)
                    projected = stage(name, src, staging / slice_name, rewrites, namespace_pattern("claude"))
                    return (src, projected)

                for name, src in sorted(entries.items()):
                    if name != "_shared" and self.remove(dest / name, candidates(name, src)):
                        gone.add(name)
                if "_shared" in entries and (dest / "_shared").exists():
                    # Retained skills (edited or foreign) may source the helpers.
                    left = sorted(e.name for e in dest.iterdir() if e.name not in gone | {"_shared"})
                    if left:
                        print(f"[!!] kept {dest / '_shared'}: retained entries may depend on it: {', '.join(left)}")
                    elif self.remove(dest / "_shared", candidates("_shared", entries["_shared"])):
                        gone.add("_shared")
                retired[str(dest)] = gone
                if self.apply and dest.is_dir() and not any(dest.iterdir()):
                    dest.rmdir()
            commands = self.home / ".claude/commands"
            recorded = [n for n in state.get(str(commands), []) if n not in ("", ".", "..") and Path(n).name == n]
            if recorded and commands.is_dir() and not commands.is_symlink():
                retired[str(commands)] = self.claude_wrappers(commands, recorded, staging / "commands")
                if self.apply and not any(commands.iterdir()):
                    commands.rmdir()
        if self.apply and any(retired.values()):
            hashes: dict[str, str] = {}
            if state_file.is_file():
                raw = json.loads(state_file.read_text(encoding="utf-8")).get("sha256", {})
                hashes = raw if isinstance(raw, dict) else {}
            for key, gone in retired.items():
                if key in state:
                    state[key] = [name for name in state[key] if name not in gone]
            save_slice_state(state_file, state, hashes)

    def claude_wrappers(self, commands: Path, recorded: list[str], staging: Path) -> set[str]:
        """Remove recorded wrappers byte-identical to a historical ycc/commands projection."""
        history = historical_claude_commands(ROOT)
        if history is None:
            print(f"[!!] kept {commands}: git history unavailable; legacy command wrappers cannot be proven owned")
            return set()
        names = {Path(n).stem for n in recorded} | {
            p.stem for kind in ("skills", "agents") for p in (ROOT / "ycc" / kind).iterdir()
        }
        alternation = "|".join(sorted(map(re.escape, names), key=len, reverse=True))
        pattern = re.compile(rf"(?<![A-Za-z0-9_-])(/?)ycc:({alternation})(?![A-Za-z0-9_-])")
        rewrites = rewrites_for("claude", self.home)
        gone: set[str] = set()
        for name in sorted(recorded):
            versions = history.get(name, [])
            sources: list[Path] = []
            for index, body in enumerate(versions):
                raw = staging / f"raw-{index}" / name
                raw.parent.mkdir(parents=True, exist_ok=True)
                raw.write_bytes(body)
                sources += [raw, stage(name, raw, staging / f"projected-{index}", rewrites, pattern)]
            target = commands / name
            if not target.exists() and not target.is_symlink():
                gone.add(name)  # already gone: forget the record
            elif sources and self.remove(target, tuple(sources)):
                gone.add(name)
            elif not sources:
                print(f"[!!] kept {target}: no ycc command of that name in history")
        return gone

    def retire_cursor_carriers(self) -> None:
        """Retract installer-owned Cursor command wrappers and the sessionStart hook.

        Wrappers reference the file-copy skills and the hook would duplicate the
        native ycc-hooks package, so both must go before skills are removed. The
        slice and merge engines own the ownership proof (recorded names plus
        content hashes); every decision is preflighted with --dry-run before
        any mutation, and a refusal stops the whole Cursor cleanup closed. Unrecorded
        files in ~/.cursor/commands are the user's: they are kept, never a refusal.
        """
        helper = str(ROOT / "scripts/install_slices.py")
        merge = str(ROOT / "scripts/merge_managed_config.py")
        hooks_source = str(ROOT / "packages/cursor/ycc-hooks/hooks/hooks.json")
        hooks_json = str(self.home / ".cursor/hooks.json")
        steps = [
            ("commands", [sys.executable, helper, "remove", "--target", "cursor", "--slice", "commands"]),
            (
                "hook registration",
                [
                    sys.executable,
                    merge,
                    "--remove",
                    "--profile",
                    "cursor-hooks",
                    "--source",
                    hooks_source,
                    "--destination",
                    hooks_json,
                    "--groups",
                    "hooks",
                ],
            ),
            ("hook script", [sys.executable, helper, "remove", "--target", "cursor", "--slice", "hooks"]),
        ]
        owned = load_slice_state(slice_state_path())
        commands_dir = self.home / ".cursor/commands"
        # The strict slice remover acts only on recorded wrappers; anything unrecorded in
        # ~/.cursor/commands is the user's and stays (it is reported, never a refusal).
        if commands_dir.is_dir() and not commands_dir.is_symlink() and safe_parent(commands_dir / "entry"):
            tracked = set(owned.get(str(commands_dir), []))
            for entry in sorted(commands_dir.iterdir()):
                if entry.name not in tracked:
                    print(f"[!!] kept {entry}: not recorded as installed by ycc")
        merge_owned = load_state()
        retiring: list[str] = []
        if owned.get(str(commands_dir)):
            retiring.append("ycc")
        if owned.get(str(self.home / ".cursor/hooks")) or merge_owned.get(f"cursor-hooks:{hooks_json}"):
            retiring.append("ycc-hooks")
        print(f"[ok] Cursor carriers {'will retire' if self.apply else 'would retire'} before file-copy skills")

        def run(label: str, command: list[str], dry_run: bool) -> None:
            try:
                subprocess.run([*command, *(["--dry-run"] if dry_run else [])], check=True)
            except subprocess.CalledProcessError as error:
                raise ValueError(
                    f"Cursor {label} cleanup refused; no file-copy skills, agents or rules removed. "
                    "Back up and resolve the reported carrier manually, then re-run "
                    "`./install.sh install --target cursor`"
                ) from error

        # Preflight everything first: no step may mutate if any would refuse.
        for label, command in steps:
            run(label, command, True)
        if self.apply:
            for label, command in steps:
                # The strict slice CLI saves state even for an empty removal.
                # Avoid creating unrelated ownership state when no carrier was
                # ever recorded (and keep no-op migration byte-stable).
                key = {"commands": ".cursor/commands", "hook script": ".cursor/hooks"}.get(label)
                if key is not None and not owned.get(str(self.home / key)):
                    continue
                run(label, command, False)
        self.cursor_retired.update(retiring)

    def opencode(self, *, removing: bool = False) -> None:
        """Retire the file-copy opencode install the @yandy-r/ycc-opencode npm plugin replaces.

        After an install the plugins entry must already load the package (``removing``,
        from 'install.sh remove --intent base', drops that proof). An entry under
        ~/.config/opencode/{skills,agents,commands,shared,ycc-sensitive-guard} goes only
        when it is byte-identical to the committed .opencode-plugin source (current or
        any version in this checkout's history); the merged mcp.servers entries and the
        "./ycc-sensitive-guard" plugins item go only with merge-state ownership proof.
        Edited and foreign entries are kept and reported.
        """
        from opencode_package import loads_package

        config_dir = self.home / ".config/opencode"
        config = config_dir / "opencode.json"
        if config_dir.is_symlink() or not safe_parent(config_dir / "entry"):
            print(f"[!!] kept {config_dir}: symlinked configuration directory (no opencode cleanup)")
            return
        # A dry run previews as if the base step had written the entry it only previewed.
        if not removing and self.apply and not loads_package(config):
            print(f"[!!] opencode file-copy install retained: {config} does not load @yandy-r/ycc-opencode")
            return
        self.opencode_config(config)
        self.opencode_units(config_dir, config)
        print("opencode legacy cleanup complete (global scope only).")

    def opencode_config(self, config: Path) -> None:
        """Take back the ycc-written mcp.servers entries and the "./ycc-sensitive-guard" plugins item."""
        if not config.exists() and not config.is_symlink():
            return
        state = load_state().get(f"opencode-config:{config}", {})
        if not isinstance(state, dict):
            return
        with tempfile.TemporaryDirectory(prefix="ycc-migrate-") as tmp:
            if any(key.startswith("/mcp/servers/") for key in state):
                # Ownership comes from the recorded leaf hashes alone: an edited server stays.
                empty = Path(tmp) / "mcp.json"
                empty.write_text("{}\n", encoding="utf-8")
                self.merge_remove("opencode-config", empty, config, "mcp")
            if GUARD_PLUGIN in self.opencode_owned_plugins(state):
                guard = Path(tmp) / "plugins.json"
                guard.write_text(json.dumps({"plugins": [GUARD_PLUGIN]}) + "\n", encoding="utf-8")
                self.merge_remove("opencode-config", guard, config, "plugins", "--entries", GUARD_PLUGIN)

    @staticmethod
    def opencode_owned_plugins(state: dict[str, Any]) -> set[str]:
        """The "./ycc-sensitive-guard" plugins item when the merge engine recorded appending it (by hash)."""
        entry = state.get("/plugins", {})
        owned = entry.get(ADDED_ITEMS_KEY, []) if isinstance(entry, dict) else []
        return {GUARD_PLUGIN} if isinstance(owned, list) and value_hash(GUARD_PLUGIN) in owned else set()

    def opencode_guard_loaded(self, config: Path) -> bool:
        """True when opencode.json still loads "./ycc-sensitive-guard" after this run's removal."""
        # Unparseable config counts as still loading the guard (keep the directory).
        try:
            raw = config.read_text(encoding="utf-8")
            data = load_json_config(raw, config, {"format": "json", "jsonc": True}) if raw.strip() else {}
        except FileNotFoundError:
            return False
        except (OSError, ValueError):
            return True
        plugins = data.get("plugins", []) if isinstance(data, dict) else []
        specs = {p if isinstance(p, str) else p.get("package") for p in plugins if isinstance(p, (str, dict))}
        if GUARD_PLUGIN not in {s.rstrip("/") for s in specs if isinstance(s, str)}:
            return False
        if self.apply:
            return True
        # Dry run: the entry goes when the merge engine recorded writing it (and it is unedited).
        state = load_state().get(f"opencode-config:{config}", {})
        return not (isinstance(state, dict) and GUARD_PLUGIN in self.opencode_owned_plugins(state))

    def opencode_units(self, config_dir: Path, config: Path) -> None:
        """Remove byte-identical file-copy unit entries; keep shared/ and the guard while still needed."""
        bundle = ROOT / ".opencode-plugin"
        history = opencode_history(ROOT)
        if history is None:
            print(f"[!!] {ROOT}: git history unavailable; only copies of the current bundle can be proven owned")
        retired: dict[str, set[str]] = {}
        retained_skills = False
        for unit in OPENCODE_UNITS:
            dest = config_dir / unit
            if dest.is_symlink() or (dest.exists() and not dest.is_dir()):
                print(f"[!!] kept {dest}: {'symlinked unit directory' if dest.is_symlink() else 'not a directory'}")
                # Skills kept as they are may still source shared/ helpers.
                retained_skills = retained_skills or unit == "skills"
                continue
            if not dest.is_dir():
                continue
            source = bundle / unit
            if source.exists():
                trusted_source(source, ROOT)
                reject_escaping_symlinks(source)
            if unit == "shared" and retained_skills:
                print(f"[!!] kept {dest}: retained skills may depend on it")
                continue
            if unit == "ycc-sensitive-guard" and self.opencode_guard_loaded(config):
                print(f"[!!] kept {dest}: {config} still loads ./{unit}")
                continue
            gone: set[str] = set()
            for entry in sorted(dest.iterdir()):
                if self.opencode_entry(entry, source / entry.name, history, f"{unit}/{entry.name}"):
                    gone.add(entry.name)
                elif unit == "skills":
                    retained_skills = True
            retired[str(dest)] = gone
            if self.apply and not any(dest.iterdir()):
                dest.rmdir()
        if self.apply and any(retired.values()):
            state_file = slice_state_path()
            state = load_slice_state(state_file)
            hashes: dict[str, str] = {}
            if state_file.is_file():
                raw = json.loads(state_file.read_text(encoding="utf-8")).get("sha256", {})
                hashes = raw if isinstance(raw, dict) else {}
            changed = False
            for key, gone in retired.items():
                if key in state:
                    state[key] = [name for name in state[key] if name not in gone]
                    changed = True
            if changed:
                save_slice_state(state_file, state, hashes)

    def opencode_entry(self, entry: Path, source: Path, history: OpencodeHistory | None, key: str) -> bool:
        """Remove one unit entry when it equals the current source or a committed version of it."""
        if not entry.exists() and not entry.is_symlink():
            return False
        if not safe_parent(entry):
            print(f"[!!] kept {entry}: symlinked parent directory")
            return False
        ours = source.exists() and identical(entry, source)
        if not ours and history is not None:
            ours = object_id(entry, history.algorithm) in history.ids.get(key, frozenset())
        if not ours:
            known = source.exists() or (history is not None and key in history.ids)
            print(f"[!!] kept {entry}: {'edited or ownership uncertain' if known else 'not shipped by ycc'}")
            return False
        print(f"[ok] {'remove' if self.apply else 'would remove'} {entry}")
        if self.apply:
            if entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry)
            else:
                entry.unlink()
        return True

    def cursor(self) -> None:
        """Retire the file-copy Cursor install: carriers first, then byte-identical unit copies.

        Ownership is proven against the committed packages/cursor sources (raw,
        and as the old installer projected them), never against recorded names.
        """
        units = (("skills", "ycc"), ("agents", "ycc"), ("rules", "ycc-rules"))
        # Validate every canonical source before any removal or projection.
        for unit, package in units:
            source = ROOT / "packages/cursor" / package / unit
            if not source.is_dir():
                raise ValueError(f"canonical Cursor source missing: {source}")
            trusted_source(source, ROOT)
            reject_escaping_symlinks(source)
            if unit == "skills" and (source / "init").exists():
                reject_escaping_symlinks(source / "init", any_link=True)
        # Command wrappers and the sessionStart hook must be retracted before
        # the skills they reference are removed; refusals stop everything.
        self.retire_cursor_carriers()
        for unit, package in units:
            source = ROOT / "packages/cursor" / package / unit
            dest = self.home / ".cursor" / unit
            if not safe_parent(dest / "entry"):
                print(f"[!!] kept {dest}: symlinked parent directory")
                continue
            # The installer projects init back to file-copy resources. Compare
            # both forms; recorded entry names alone never establish ownership.
            gone: set[str] = set()
            shared: Path | None = None
            with tempfile.TemporaryDirectory(prefix="ycc-migrate-") as tmp:
                staging = Path(tmp)
                for src in sorted(source.iterdir()):
                    trusted_source(src, source)
                    if unit == "skills" and src.name == "_shared":
                        shared = src
                        continue
                    projected = stage(src.name, src, staging, rewrites_for("cursor", self.home), None)
                    if unit == "skills" and src.name == "init":
                        legacy = staging / "legacy" / src.name
                        shutil.copytree(src, legacy, symlinks=True)
                        project_cursor_init(src.name, legacy)
                        removed = self.remove(dest / src.name, (src, projected, legacy))
                    else:
                        removed = self.remove(dest / src.name, (src, projected))
                    if removed:
                        gone.add(src.name)
                        self.cursor_retired.add(package)
            if shared is not None:
                # Retained skills (edited or foreign) may source this helper.
                left = [e.name for e in dest.iterdir() if e.name not in gone | {"_shared"}] if dest.is_dir() else []
                if left:
                    print(f"[!!] kept {dest / '_shared'}: retained entries may depend on it: {', '.join(sorted(left))}")
                else:
                    self.remove(dest / "_shared", (shared,))
            if dest.is_dir():
                for entry in sorted(dest.iterdir()):
                    if not (source / entry.name).exists():
                        print(f"[!!] kept {entry}: not shipped by ycc")
        # The old global MCP step merged mcp-configs/mcp.json into ~/.cursor/mcp.json; the merge
        # engine's ownership state takes back only the servers ycc wrote (ycc-mcp now carries them).
        mcp = self.home / ".cursor/mcp.json"
        if (mcp.exists() or mcp.is_symlink()) and load_state().get(f"cursor-mcp:{mcp}"):
            self.merge_remove("cursor-mcp", ROOT / "mcp-configs/mcp.json", mcp, "mcp")
            if not mcp.is_symlink() and safe_parent(mcp):
                self.cursor_retired.add("ycc-mcp")
        # Old installs linked the rules into ~/.cursor; retire only links to this checkout.
        for name in ("CLAUDE.md", "AGENTS.md"):
            link = self.home / ".cursor" / name
            if link.is_symlink() and self.remove(link, (ROOT / "ycc/settings/rules" / name,), links_only=True):
                self.cursor_retired.add("ycc-rules")
        order = ("ycc", "ycc-rules", "ycc-mcp", "ycc-hooks")
        retired = [package for package in order if package in self.cursor_retired]
        if retired:
            # cursor.sh reads this line to name the replacing packages in its /plugins hint.
            print(f"Cursor legacy carriers {'retired' if self.apply else 'to retire'} for: {' '.join(retired)}")
        print("Cursor legacy cleanup complete.")

    def omp(self) -> None:
        import omp_install

        omp_install.apply_migrate(self.omp_plan, self.apply)

    def codex_skills(self, legacy: tuple[Path, ...] | None = None) -> None:
        """Retire exact standalone ~/.codex/skills copies; never ~/.codex/agents.

        An entry is ours when it equals the canonical source or any rendered
        pre-listing combined baseline in `legacy` (current and pre-fix forms),
        raw or projected with either the current or the historical rewrite set.
        """
        unit = SPECS[("codex", "skills")][0]
        dest = self.home / unit.dest
        if not dest.is_dir() or dest.is_symlink():
            return
        if not safe_parent(dest / "entry"):
            print(f"[!!] kept {dest}: symlinked parent directory")
            return
        if not (ROOT / unit.src).is_dir():
            raise ValueError(f"canonical Codex skills source missing: {ROOT / unit.src}")
        entries = shipped_entries(unit)
        for src in entries.values():
            trusted_source(src, ROOT)
            reject_escaping_symlinks(src)
        with tempfile.TemporaryDirectory(prefix="ycc-migrate-") as tmp:
            staging = Path(tmp)
            if legacy is None:
                legacy = legacy_codex_baselines(staging / "legacy")
            gone: set[str] = set()
            rewrite_sets = codex_rewrite_sets(self.home)
            pattern = namespace_pattern("codex")

            def candidates(name: str, src: Path) -> tuple[Path, ...]:
                leaf = "shared" if name == "_shared" else f"skills/{name}"
                found: list[Path] = []
                for base in (src, *(base_root / leaf for base_root in legacy)):
                    if not base.exists() or any(base == existing for existing in found):
                        continue
                    found.append(base)
                    for variant, rewrites in enumerate(rewrite_sets):
                        found.append(stage(name, base, staging / f"{len(found)}-{variant}", rewrites, pattern))
                return tuple(found)

            for name, src in sorted(entries.items()):
                if name != "_shared" and self.remove(dest / name, candidates(name, src)):
                    gone.add(name)
            if "_shared" in entries:
                left = [e.name for e in dest.iterdir() if e.name not in gone | {"_shared"}]
                if left:
                    print(f"[!!] kept {dest / '_shared'}: retained entries may depend on it: {', '.join(sorted(left))}")
                else:
                    self.remove(dest / "_shared", candidates("_shared", entries["_shared"]))

    def codex_native_installed(self, package: str) -> bool:
        """True when ``<package>@ycc`` is enabled in config.toml and has a snapshot Codex installed."""
        config = self.home / ".codex/config.toml"
        try:
            plugins = tomllib.loads(config.read_text(encoding="utf-8")).get("plugins", {})
        except (OSError, tomllib.TOMLDecodeError):
            return False
        entry = plugins.get(f"{package}@ycc") if isinstance(plugins, dict) else None
        if not isinstance(entry, dict) or entry.get("enabled") is not True:
            return False
        root = self.home / ".codex/plugins/cache/ycc" / package
        return root.is_dir() and any((snapshot / ".codex-plugin/plugin.json").is_file() for snapshot in root.iterdir())

    def codex(self, *, removing: bool = False) -> None:
        """Retire proven legacy ycc@local-ycc-plugins state; never installs, never touches ~/.codex/agents.

        After an install, each legacy carrier goes only once its native replacement is
        proven installed and enabled (ycc@ycc: plugin leaf, links, cache, catalog entry,
        standalone skills; ycc-mcp@ycc: the [mcp_servers] group). ``removing`` (from
        ``install.sh remove``) drops that proof: the native packages are going too.
        Ownership proofs (byte-identical, owned link, released tree, exact entry) always apply.
        """
        base = removing or self.codex_native_installed("ycc")
        mcp = removing or self.codex_native_installed("ycc-mcp")
        config = self.home / ".codex/config.toml"
        if mcp:
            self.merge_remove("codex-config", ROOT / ".codex-plugin/config/mcp-servers.json", config, "mcp")
        else:
            print("[!!] ycc-mcp@ycc not installed and enabled; legacy Codex [mcp_servers] retained")
        if not base:
            print("[!!] ycc@ycc not installed and enabled; legacy ycc@local-ycc-plugins retained")
            return
        with tempfile.TemporaryDirectory(prefix="ycc-migrate-") as tmp:
            leaf = Path(tmp) / "legacy.toml"
            leaf.write_text('[plugins."ycc@local-ycc-plugins"]\nenabled = true\n', encoding="utf-8")
            self.merge_remove("codex-config", leaf, config, "plugins", "--entries", "ycc@local-ycc-plugins")
        canonical = ROOT / ".codex-plugin/ycc"
        trusted_source(canonical, ROOT)
        # Decide which user-catalog entries survive before retiring any link
        # they may reference.
        catalog_path, catalog, kept, retained = self.plan_codex_catalog()
        with tempfile.TemporaryDirectory(prefix="ycc-migrate-") as tmp:
            legacies = legacy_codex_baselines(Path(tmp) / "legacy")
            sources = (canonical, *legacies)
            self.codex_skills(legacies)
            for relative in (".codex/plugins/ycc", ".agents/plugins/ycc"):
                link = self.home / relative
                if link in retained:
                    print(f"[!!] kept {link}: referenced by a retained user catalog entry")
                    continue
                self.remove(link, sources, links_only=True)
            cache = self.home / ".codex/plugins/cache/local-ycc-plugins/ycc"
            # A same-checkout upgrade leaves a snapshot of an older release,
            # which nothing rendered from this checkout equals, so ownership
            # is also proven against this checkout's committed history.
            # A versioned cache may hold other versions or user changes. Retire
            # only proven snapshots, never the whole marketplace directory.
            versioned = (
                safe_parent(cache / "entry")
                and cache.is_dir()
                and not cache.is_symlink()
                and not (cache / ".codex-plugin").exists()
            )
            if not versioned:
                self.remove(cache, sources, history=True)
            elif (children := sorted(cache.iterdir())) and all(
                [self.remove(child, sources, history=True) for child in children]
            ):
                # Every snapshot was ours, so the now-empty version directory is too.
                print(f"[ok] {'remove' if self.apply else 'would remove'} {cache}")
                if self.apply:
                    cache.rmdir()
            if self.apply and safe_parent(cache):
                # The local-ycc-plugins marketplace directory, once nothing is left in it.
                with contextlib.suppress(OSError):
                    cache.parent.rmdir()
        if self.apply and catalog_path is not None and catalog is not None and kept is not None:
            scaffold = {"name": "local-ycc-plugins", "interface": {"displayName": "Local YCC Plugins"}}
            if kept or {key: value for key, value in catalog.items() if key != "plugins"} != scaffold:
                catalog["plugins"] = kept
                catalog_path.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            else:
                # Only the installer's scaffold was left.
                catalog_path.unlink()
        print("Codex legacy cleanup complete; all ~/.codex/agents retained.")

    def plan_codex_catalog(self) -> tuple[Path | None, dict[str, Any] | None, list[Any] | None, set[Path]]:
        """Plan the user catalog edit without writing; return links to keep."""
        path = self.home / ".agents/plugins/marketplace.json"
        links = {self.home / ".codex/plugins/ycc", self.home / ".agents/plugins/ycc"}
        if not path.exists() and not path.is_symlink():
            return None, None, None, set()
        try:
            catalog = load_json(path)
            plugins = catalog.get("plugins", [])
            if not isinstance(plugins, list):
                raise ValueError(f"invalid plugins array: {path}")
        except (OSError, ValueError) as error:
            print(f"[!!] kept {path}: unreadable catalog ({error}); legacy links retained")
            return None, None, None, links
        recognized = legacy_catalog_entries()
        writable = catalog.get("name") == "local-ycc-plugins" and not path.is_symlink() and safe_parent(path)
        if not writable:
            print(f"[!!] kept {path}: symlinked or foreign catalog")
        kept: list[Any] = []
        retained: set[Path] = set()
        for entry in plugins:
            if isinstance(entry, dict) and entry.get("name") == "ycc":
                # The installer always writes the complete entry: any added, omitted, or edited field is user-owned.
                ours = writable and entry in recognized
                if ours:
                    print(f"[ok] removed recognized legacy ycc catalog entry from {path}")
                    continue
                print(f"[!!] kept foreign or edited ycc catalog entry in {path}")
                source = entry.get("source")
                if isinstance(source, dict) and source.get("source") == "local" and isinstance(source.get("path"), str):
                    target = Path(os.path.normpath(self.home / source["path"]))
                    retained |= {link for link in links if link == target}
            kept.append(entry)
        if not writable or kept == plugins:
            return None, None, None, retained
        return path, catalog, kept, retained


def codex_eligible(source: Path) -> None:
    """Gate the repository's native Codex listing before any legacy Codex state is retired.

    Eligible only once the modeled catalog flips to the native distribution
    (every migration PACKAGES row listed) and each listed payload is present.
    """
    catalog_path = source / ".agents/plugins/marketplace.json"
    if not source.is_dir() or source.is_symlink():
        raise ValueError(f"untrusted marketplace source: {source}")
    trusted_source(catalog_path, source)
    catalog = validate_marketplace_catalog(load_json(catalog_path))
    if catalog.get("name") != "ycc":
        raise ValueError("native catalog not listed (YAN-1140)")
    entries = {item["name"]: item for item in catalog["plugins"]}
    model = load_package_model()
    shipped = native_packages(model.packages)
    if not repository_native_enabled(model.packages):
        raise ValueError("native catalog not listed: all migration packages must be listed together (YAN-1140)")
    for name in PACKAGES:
        runtime = model.lookup(name, "codex")
        if runtime is None or runtime.status != "included" or runtime.mechanism != "native" or runtime.opt_in:
            raise ValueError(f"ineligible native Codex package: {name}")
    check_catalog(source, shipped, include_unlisted=False)
    if catalog != build_repository_marketplace(shipped):
        raise ValueError("repository catalog has not flipped to the native listing (YAN-1210)")
    for name in PACKAGES:
        if entries.get(name, {}).get("source") != {"source": "local", "path": f"./.codex-plugin/{name}"}:
            raise ValueError(f"missing native source for {name}")
        package_root = source / ".codex-plugin" / name
        if not package_root.resolve().is_relative_to(source.resolve()):
            raise ValueError(f"native payload escapes marketplace: {package_root}")
        for path in package_root.rglob("*"):
            if path.is_symlink() and not path.resolve().is_relative_to(package_root.resolve()):
                raise ValueError(f"native payload symlink escapes package: {path}")
        package = next(p for p in model.packages if p.key == name)
        check_package(source, package, native_version(model))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--targets", required=True)
    parser.add_argument("--dry-run", action="store_true", help="preview the cleanup without changing anything")
    # Set by 'install.sh remove': the native packages are gone, so cleanup must not require them installed.
    parser.add_argument("--removing", action="store_true")
    # The installer's project root (git toplevel, else cwd): omp project installs are recorded there.
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    targets = args.targets.split(",")
    if not targets or any(target not in {"claude", "codex", "cursor", "omp", "opencode"} for target in targets):
        print("[err] unsupported cleanup targets", file=sys.stderr)
        return 1
    apply = not args.dry_run
    migration = Migration(apply)
    try:
        # Preflight the whole selection before cleaning any target.
        if "codex" in targets:
            try:
                codex_eligible(ROOT)
            except (OSError, ValueError) as error:
                raise ValueError(f"Codex native gate failed: {error}; legacy retained (YAN-1140)") from error
        if "omp" in targets:
            import omp_install  # Lazy: keeps the claude/codex/cursor paths free of the omp helper.

            try:
                omp_install.available()
            except (OSError, ValueError) as error:
                raise ValueError(f"omp unavailable: {error}") from error
            # Every omp refusal (foreign link, unrecorded export, disabled or non-native legacy install,
            # export build) happens here, before any target mutates.
            migration.omp_plan = omp_install.plan_migrate(args.project_root, apply=apply)
        print(f"Legacy cleanup {'apply' if apply else 'dry-run (no changes)'}")
        for target in targets:
            if target == "codex":
                migration.codex(removing=args.removing)
            elif target in ("claude", "opencode"):
                getattr(migration, target)(removing=args.removing)
            else:
                getattr(migration, target)()
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"[err] cleanup stopped: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
