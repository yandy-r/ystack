#!/usr/bin/env python3
"""Preview or apply the global, ownership-safe native package migrations."""

from __future__ import annotations

import argparse
import functools
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, NamedTuple

from codex_marketplace import build_entry, validate_marketplace_catalog
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
    state_path as slice_state_path,
)
from merge_managed_config import PROFILES, load_state, remove_hook_commands
from package_model import load_package_model
from validate_codex_native import check_catalog, check_package

ROOT = Path(__file__).resolve().parent.parent
PACKAGES = MIGRATION_PACKAGES
# Repo-mode catalog entries written before the GitHub rename pointed at this URL. This literal is
# historical data: install_migrate.py is deliberately not in rename_repo.ALLOWLIST_FILES.
PRE_RENAME_REPO_URL = "https://github.com/yandy-r/claude-plugins.git"


def legacy_repo_entry() -> dict[str, Any]:
    """Return the exact repo-mode catalog entry the installer wrote before the repository rename."""
    entry = build_entry("repo", "")
    entry["source"] = {**entry["source"], "url": PRE_RENAME_REPO_URL}
    return entry


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
                    "run 'git fetch --unshallow' and rerun migrate"
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

    def claude(self) -> None:
        dest = self.home / ".claude/settings.json"
        if dest.is_symlink():
            print(f"[!!] kept {dest}: symlinked config file (hooks, target and ownership state retained)")
            return
        if not safe_parent(dest):
            print(f"[!!] kept {dest}: symlinked parent directory")
            return
        settings = load_json(dest) if dest.exists() else {}
        enabled = settings.get("enabledPlugins", {})
        # Installed registry membership or ycc-all's dependency closure is NOT
        # evidence of explicit enablement at user scope.
        if isinstance(enabled, dict) and enabled.get("ycc-hooks@ycc") is True:
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
        print("Claude migrate complete (global scope only).")

    def retire_cursor_carriers(self) -> None:
        """Retract installer-owned Cursor command wrappers and the sessionStart hook.

        Wrappers reference the file-copy skills and the hook would duplicate the
        native ycc-hooks package, so both must go before skills are removed. The
        slice and merge engines own the ownership proof (recorded names plus
        content hashes); every decision is preflighted with --dry-run before
        any mutation, and a refusal stops the whole Cursor migration closed.
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
        # The strict slice remover intentionally ignores unrecorded user files.
        # Do not delete their referenced skills behind its back: require manual
        # resolution for possible former carriers that lack ownership proof.
        if commands_dir.is_dir() and not commands_dir.is_symlink() and safe_parent(commands_dir / "entry"):
            tracked = set(owned.get(str(commands_dir), []))
            shipped = shipped_entries(SPECS[("cursor", "commands")][0])
            for entry in commands_dir.iterdir():
                if entry.name in tracked:
                    continue
                references_skills = (
                    entry.is_file()
                    and not entry.is_symlink()
                    and any(
                        marker in entry.read_text(encoding="utf-8", errors="replace")
                        for marker in (
                            str(self.home / ".cursor/skills"),
                            str(self.home / ".agents/skills"),
                            "~/.cursor/skills",
                            "~/.agents/skills",
                        )
                    )
                )
                if entry.name in shipped or entry.is_symlink() or references_skills:
                    raise ValueError(
                        f"Cursor command may reference file-copy skills but has no ownership proof: {entry}; "
                        "no Cursor cleanup performed. Back it up and edit or remove it manually, then re-run migrate "
                        "before applying or activating native packages"
                    )
        print(f"[ok] Cursor carriers {'will retire' if self.apply else 'would retire'} before file-copy skills")

        def run(label: str, command: list[str], dry_run: bool) -> None:
            try:
                subprocess.run([*command, *(["--dry-run"] if dry_run else [])], check=True)
            except subprocess.CalledProcessError as error:
                raise ValueError(
                    f"Cursor {label} cleanup refused; no file-copy skills, agents or rules removed. "
                    "Back up and resolve the reported carrier manually, then run "
                    "`./install.sh remove --target cursor --intent commands,hooks` and retry "
                    "`./install.sh migrate --target cursor` before applying or activating native packages"
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

    def cursor(self) -> None:
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
        print("Cursor: open /add-plugin and add the ycc marketplace, then select the native packages.")
        print("Cursor migrate complete; native installation is interactive, not automatic.")

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

    def codex(self, source: Path, eligible: bool) -> None:
        if not eligible:
            print("[!!] Codex native catalog not listed (YAN-1140); legacy ycc@local-ycc-plugins retained")
            return
        if not self.apply:
            print(
                f"Codex: would add marketplace {source}, install ycc@ycc and ycc-mcp@ycc, and verify installed/enabled"
            )
            print(
                "Codex: would retire only proven legacy config, links and cache after successful verification; "
                "~/.codex/agents retained"
            )
            self.codex_skills()
            return

        def cli(*args: str) -> dict[str, Any]:
            print(f"[ok] codex {' '.join(args)}", flush=True)
            result = subprocess.run(["codex", *args, "--json"], check=True, capture_output=True, text=True)
            payload = json.loads(result.stdout)
            if not isinstance(payload, dict):
                raise ValueError("Codex CLI returned a non-object response")
            return payload

        added = cli("plugin", "marketplace", "add", str(source))
        if added.get("marketplaceName") != "ycc":
            raise ValueError("Codex did not register marketplace ycc; legacy retained")
        listing = cli("plugin", "list", "--available")
        # codex-cli 0.161 moves an installed id out of `available` into
        # `installed`, so a rerun finds both ids only there. Eligibility is
        # membership in either list; enablement is still verified below.
        offered = {item.get("pluginId") for item in listing.get("available", [])}
        offered |= {item.get("pluginId") for item in listing.get("installed", [])}
        if not {f"{p}@ycc" for p in PACKAGES}.issubset(offered):
            raise ValueError("native packages missing from Codex marketplace; legacy retained")
        for package in PACKAGES:
            cli("plugin", "add", f"{package}@ycc")
        installed = {item.get("pluginId"): item for item in cli("plugin", "list").get("installed", [])}
        version = native_version(load_package_model())
        for package in PACKAGES:
            item = installed.get(f"{package}@ycc", {})
            if item.get("installed") is not True or item.get("enabled") is not True or item.get("version") != version:
                raise ValueError(f"{package}@ycc not installed/enabled at {version}; legacy retained")
        # No legacy mutation occurs above this point. CLI failures are fatal;
        # there is deliberately no fallback to install_codex_plugin.
        with tempfile.TemporaryDirectory(prefix="ycc-migrate-") as tmp:
            leaf = Path(tmp) / "legacy.toml"
            leaf.write_text('[plugins."ycc@local-ycc-plugins"]\nenabled = true\n', encoding="utf-8")
            self.merge_remove(
                "codex-config", leaf, self.home / ".codex/config.toml", "plugins", "--entries", "ycc@local-ycc-plugins"
            )
        self.merge_remove(
            "codex-config", ROOT / ".codex-plugin/config/mcp-servers.json", self.home / ".codex/config.toml", "mcp"
        )
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
        if catalog_path is not None and catalog is not None and kept is not None:
            catalog["plugins"] = kept
            catalog_path.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print("Codex migrate complete; all ~/.codex/agents retained.")

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
        recognized = [
            build_entry("local", "./.agents/plugins/ycc"),
            build_entry("local", "./plugins/ycc"),
            build_entry("repo", ""),
            legacy_repo_entry(),
        ]
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


def codex_eligible(source: Path, *, external: bool = False) -> None:
    """Gate one marketplace source, defaulting to the repository listing state.

    The repository itself is only eligible once the modeled catalog flips to the
    native distribution (every migration PACKAGES row listed). An explicit
    --marketplace-source export is opt-in and stays eligible while each listed
    entry's payload is present, as before.
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
    if not external and not repository_native_enabled(model.packages):
        raise ValueError("native catalog not listed: all migration packages must be listed together (YAN-1140)")
    for name in PACKAGES:
        runtime = model.lookup(name, "codex")
        if runtime is None or runtime.status != "included" or runtime.mechanism != "native" or runtime.opt_in:
            raise ValueError(f"ineligible native Codex package: {name}")
    check_catalog(source, shipped, include_unlisted=external)
    if not external and catalog != build_repository_marketplace(shipped):
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
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--marketplace-source", type=Path, default=ROOT)
    # The installer's project root (git toplevel, else cwd): omp project installs are recorded there.
    parser.add_argument("--project-root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    targets = args.targets.split(",")
    if not targets or any(target not in {"claude", "codex", "cursor", "omp"} for target in targets):
        print("[err] unsupported migration targets", file=sys.stderr)
        return 1
    migration = Migration(args.apply)
    eligible = True
    try:
        # Preflight the whole selection before applying any target.
        if "codex" in targets:
            try:
                codex_eligible(
                    args.marketplace_source,
                    external=args.marketplace_source.resolve() != ROOT.resolve(),
                )
            except (OSError, ValueError) as error:
                eligible = False
                print(f"[!!] Codex native gate: {error}")
                if args.apply:
                    raise ValueError(f"Codex native gate failed: {error}; legacy retained (YAN-1140)") from error
        if "omp" in targets:
            import omp_install  # Lazy: keeps the claude/codex/cursor paths free of the omp helper.

            try:
                omp_install.available()
            except (OSError, ValueError) as error:
                raise ValueError(f"omp unavailable: {error}") from error
            # Every omp refusal (foreign link, unrecorded export, disabled or non-native legacy install,
            # export build) happens here, before any target mutates.
            migration.omp_plan = omp_install.plan_migrate(args.project_root, apply=args.apply)
        print(f"Migration {'apply' if args.apply else 'dry-run (pass --apply to change files)'}")
        for target in targets:
            if target == "codex":
                migration.codex(args.marketplace_source.resolve(), eligible)
            else:
                getattr(migration, target)()
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"[err] migration stopped: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
