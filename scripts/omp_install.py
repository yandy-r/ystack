#!/usr/bin/env python3
"""Install, update, remove and migrate the native OMP (oh-my-pi) packages through ``omp plugin``.

The shell (scripts/lib/install/targets/omp.sh) owns flag and step selection. This helper owns:

- the ycc-owned marketplace export (``generate_omp_packages.py --export``, validated, swapped
  atomically only when its bytes change) under ``${XDG_DATA_HOME:-~/.local/share}/ycc``;
- the ``ycc`` marketplace registration and each ``<pkg>@ycc`` install per scope;
- the ownership record ``~/.config/ycc/omp-native-install.json`` (keyed by ``omp config path``),
  so ``remove`` acts only on what this helper created;
- ``--dry-run``: omp 18.12.3 honours ``--dry-run`` only for ``install`` and ``uninstall``
  (``upgrade``, ``enable`` and ``marketplace add`` mutate), so every plan comes from read-only
  queries and previews print ``[dry-run] would run: omp …``.

It never edits omp's own registry or lock files, never calls ``enable``/``disable`` (a user's
disabled install stays disabled), and never touches installs or marketplaces it did not create.
``migrate`` retires proven-ycc legacy state: ``omp plugin link`` of a ycc package and a ``ycc``
marketplace registered at this checkout root (which falls back to the Claude catalog).
"""

from __future__ import annotations

import argparse
import copy
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import install_slices
from codex_install import guarded, inventory
from generate_omp_packages import MIN_OMP_VERSION
from merge_managed_config import atomic_write
from package_install_plan import parse_packages, plan_install
from package_model import load_package_model

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "https://github.com/yandy-r/ystack.git"
MARKETPLACE = "ycc"
SCOPES = ("user", "project")
# OMP loads extensions only at session start (`/reload-plugins` skips them). A package with OMP
# agents ships the ycc scope guard extension (YAN-1250), so running sessions must restart too.
RESTART_COMPONENTS = frozenset({"hooks", "extensions", "agents"})
NO_MARKETPLACES = ("No marketplaces configured", "", "Add one with: omp plugin marketplace add <source>")
MARKETPLACE_LINE = re.compile(r"^  (\S+)  (.+)$")
# omp colours piped output when FORCE_COLOR is set (it beats NO_COLOR), so queries drop it
# and strip any SGR sequence that still slips through before parsing.
FORCE_COLOR_VARS = ("FORCE_COLOR",)
ANSI_SGR = re.compile(r"\x1b\[[0-9;]*m")
HOME_REFUSAL = "--project at $HOME: omp project scope needs a project directory (cd into a project, or use --global)"
REPO_REFUSAL = "--mode repo needs a listed OMP package"
TRUST = "[!!] OMP has no trust prompt: installed plugin code runs with your user privileges."
# The omp project state a project install may create; remove deletes only the paths ycc's install created.
PROJECT_RESIDUE = (
    ".omp",
    ".omp/plugins",
    ".omp/plugins/installed_plugins.json",
    ".omp/plugins/omp-plugins.lock.json",
    ".omp/plugins/node_modules",
)


# ---------------------------------------------------------------------------
# Environment, versions and paths
# ---------------------------------------------------------------------------


def omp_bin() -> str:
    return os.environ.get("OMP_BIN") or "omp"


def clean_env() -> dict[str, str]:
    """The environment without inherited GIT_* (a pre-push hook exports GIT_DIR)."""
    return {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


def query_env() -> dict[str, str]:
    """The environment for parsed omp queries: colour off (YAN-1558)."""
    env = {key: value for key, value in os.environ.items() if key not in FORCE_COLOR_VARS}
    env["NO_COLOR"] = "1"
    return env


def version_key(version: str) -> tuple[int, ...]:
    match = re.match(r"(\d+(?:\.\d+)*)", version)
    if match is None:
        raise ValueError(f"unparseable version: {version!r}")
    return tuple(int(part) for part in match.group(1).split("."))


def older(installed: str, target: str) -> bool:
    try:
        return version_key(installed) < version_key(target)
    except ValueError:
        return installed != target


def state_path() -> Path:
    return Path.home() / ".config/ycc/omp-native-install.json"


def export_dir() -> Path:
    """The ycc-owned marketplace export. Never ``$XDG_DATA_HOME/omp``: that opts omp into XDG routing."""
    data = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local/share")
    return Path(data) / "ycc/omp-marketplace"


def same_source(left: str, right: str) -> bool:
    if "://" in left or "://" in right:
        return left == right
    return os.path.realpath(left) == os.path.realpath(right)


def within(child: str, parent: str) -> bool:
    child_path, parent_path = Path(os.path.realpath(child)), Path(os.path.realpath(parent))
    return child_path == parent_path or parent_path in child_path.parents


def selector(package: str) -> str:
    return f"{package}@{MARKETPLACE}"


# ---------------------------------------------------------------------------
# Package model
# ---------------------------------------------------------------------------


def listed() -> bool:
    """True iff some package has an included, native, listed omp row."""
    return any(
        runtime.runtime == "omp" and runtime.status == "included" and runtime.mechanism == "native" and runtime.listed
        for package in load_package_model().packages
        for runtime in package.runtimes
    )


def select_packages(csv: str) -> tuple[str, ...]:
    """The requested packages (default: every included native omp row), validated by the planner."""
    model = load_package_model()
    if csv.strip():
        packages = parse_packages(csv)
    else:
        packages = tuple(
            package.key
            for package in model.packages
            for runtime in package.runtimes
            if runtime.runtime == "omp"
            and runtime.status == "included"
            and runtime.mechanism == "native"
            and not runtime.opt_in
        )
        if not packages:
            raise ValueError("the package model has no included native OMP package")
    plan_install(model, packages, ("omp",))
    return packages


def package_components(package: str) -> tuple[str, ...]:
    runtime = load_package_model().lookup(package, "omp")
    return runtime.components if runtime is not None else ()


def omp_package_keys() -> frozenset[str]:
    return frozenset(
        package.key
        for package in load_package_model().packages
        if any(runtime.runtime == "omp" for runtime in package.runtimes)
    )


def package_version(root: Path, package: str) -> str:
    """The lockstep version omp installs: the package's ``.claude-plugin/plugin.json``."""
    manifest = root / "packages/omp" / package / ".claude-plugin/plugin.json"
    try:
        version = json.loads(manifest.read_text(encoding="utf-8")).get("version")
    except FileNotFoundError as error:
        raise ValueError(f"OMP package {package} is missing from {root}") from error
    if not isinstance(version, str) or not version or Path(version).name != version or version in {".", ".."}:
        raise ValueError(f"unsafe OMP package version for {package}: {version!r}")
    return version


# ---------------------------------------------------------------------------
# Coexistence (YAN-1176): ycc skills other targets put where OMP also reads them
# ---------------------------------------------------------------------------

# (home-relative skills dir, OMP alias namespace) that OMP can load beside the native package.
COEXISTENCE_DIRS = ((".agents/skills", "agents"), (".codex/skills", "codex"), (".config/opencode/skills", "opencode"))
CLAUDE_SKILLS = ".claude/skills"
CLAUDE_PROVIDERS = frozenset({"claude", "*", "all"})
DEDUPE_HINT = "./install.sh install --target omp --only dedupe"


@dataclass(frozen=True)
class CoexistencePlan:
    """What OMP would load twice: owned aliases to hide, unowned copies and Claude opt-in overlaps."""

    entries: tuple[str, ...]
    owned: dict[str, tuple[str, ...]]
    unowned: dict[str, tuple[str, ...]]
    claude: tuple[str, ...]


def package_skills(packages: tuple[str, ...]) -> dict[str, Path]:
    """name → the package's SKILL.md for every skill the selected OMP packages ship (not ``_shared``)."""
    skills: dict[str, Path] = {}
    for package in packages:
        root = ROOT / "packages/omp" / package / "skills"
        if root.is_dir():
            for path in sorted(root.iterdir()):
                if (path / "SKILL.md").is_file() and not path.name.startswith("_") and path.name != "ycc-shared":
                    skills.setdefault(path.name, path / "SKILL.md")
    return skills


def aliased(directory: Path, name: str, shipped: Path) -> bool:
    """True when OMP would alias ``directory/name``: a skill there whose SKILL.md differs from ycc's.

    Byte-identical copies are dropped silently by OMP, so they need neither an entry nor a warning.
    """
    skill = directory / name / "SKILL.md"
    try:
        return skill.is_file() and skill.read_bytes() != shipped.read_bytes()
    except OSError:
        return False


def coexistence_plan(packages: tuple[str, ...], enabled_providers: frozenset[str]) -> CoexistencePlan:
    """Classify every ycc-named skill OMP also reads, by the slice ledger (installed-units.json)."""
    home = Path.home()
    shipped = package_skills(packages)
    ledger = install_slices.load_state(install_slices.state_path())
    owned: dict[str, tuple[str, ...]] = {}
    unowned: dict[str, tuple[str, ...]] = {}
    for relative, namespace in COEXISTENCE_DIRS:
        directory = home / relative
        recorded = set(ledger.get(str(directory), []))
        present = [name for name, source in shipped.items() if aliased(directory, name, source)]
        mine = tuple(sorted(name for name in present if name in recorded))
        theirs = tuple(sorted(name for name in present if name not in recorded))
        if mine:
            owned[namespace] = mine
        if theirs:
            unowned[f"~/{relative}"] = theirs
    claude: tuple[str, ...] = ()
    if enabled_providers & CLAUDE_PROVIDERS:
        directory = home / CLAUDE_SKILLS
        recorded = set(ledger.get(str(directory), []))
        claude = tuple(
            sorted(name for name, source in shipped.items() if name in recorded and aliased(directory, name, source))
        )
    entries = tuple(sorted(f"{namespace}/{name}" for namespace, names in owned.items() for name in names))
    return CoexistencePlan(entries, owned, unowned, claude)


def ignored(entry: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(entry, pattern) for pattern in patterns)


def omp_setting(key: str) -> Any:
    """The user-level effective value of ``key`` (``omp config get --json`` from $HOME); None when unreadable."""
    try:
        return OmpCli().setting(key)
    except (OSError, ValueError):
        return None


def string_list(value: Any) -> list[str]:
    return [item for item in value if isinstance(item, str)] if isinstance(value, list) else []


def coexistence_lines(plan: CoexistencePlan, pending: tuple[str, ...], hidden: str | None, dry_run: bool) -> list[str]:
    """The W1–W4 lines for ``plan``; ``pending`` are entries not yet ignored, ``hidden`` the config just merged."""
    lines: list[str] = []
    if hidden is not None and plan.entries:
        namespaces = ", ".join(f"{namespace}/…" for namespace in plan.owned)
        verb = "[dry-run] OMP: would hide" if dry_run else "[ok] OMP: hid"
        lines.append(
            f"{verb} {len(plan.entries)} ycc duplicate skills ({namespaces}) via skills.ignoredSkills in {hidden}; "
            "./install.sh remove --target omp --only dedupe restores them"
        )
    elif pending:
        for relative, namespace in COEXISTENCE_DIRS:
            count = sum(1 for entry in pending if entry.startswith(f"{namespace}/"))
            if count:
                lines.append(
                    f"[!!] OMP also loads {count} ycc skills from ~/{relative} as {namespace}/<name>; "
                    f"run {DEDUPE_HINT} to hide them in OMP"
                )
    for directory, names in plan.unowned.items():
        namespace = next(ns for relative, ns in COEXISTENCE_DIRS if directory == f"~/{relative}")
        lines.append(
            f"[!!] {directory}/{', '.join(names)} share ycc skill names but were not installed by ycc; "
            f"OMP lists them as {namespace}/<name> (left as is)"
        )
    if plan.claude:
        lines.append(
            f"[!!] enabledProviders includes claude: {len(plan.claude)} ycc skills in ~/{CLAUDE_SKILLS} outrank the "
            "OMP package (it shows as ycc/<name>); remove them with ./install.sh remove --target claude --intent "
            "skills, or drop claude from enabledProviders"
        )
    return lines


def coexistence_warn(packages: tuple[str, ...], *, hidden: str | None = None, dry_run: bool = False) -> None:
    """Print W1–W4. A dry-run never runs omp (``omp config get`` creates agent.db): settings read as []."""
    if dry_run:
        providers: list[str] = []
        current: list[str] = []
    else:
        providers = string_list(omp_setting("enabledProviders"))
        current = string_list(omp_setting("skills.ignoredSkills"))
    plan = coexistence_plan(packages, frozenset(providers))
    pending = tuple(entry for entry in plan.entries if not ignored(entry, current))
    if dry_run and pending and hidden is None:
        print("[dry-run] enabledProviders and skills.ignoredSkills read as [] (omp config get is not run)")
    for line in coexistence_lines(plan, pending, hidden, dry_run):
        print(line)


def coexistence_emit(packages: tuple[str, ...], destination: Path) -> int:
    """Write the dedupe merge source (``skills.ignoredSkills``) when there is anything to hide."""
    plan = coexistence_plan(packages, frozenset())
    if plan.entries:
        # JSON is YAML: merge_managed_config reads this as the omp-config source.
        atomic_write(destination, json.dumps({"skills": {"ignoredSkills": list(plan.entries)}}, indent=2) + "\n")
    return len(plan.entries)


def recorded_packages() -> tuple[str, ...]:
    """Packages ycc recorded as installed (any scope) for the active omp profile; () when none or unknown."""
    if not state_path().is_file() or shutil.which(omp_bin()) is None:
        return ()
    try:
        state = load_state()
        profile = state["profiles"].get(OmpCli().profile_key())
    except (OSError, ValueError):
        return ()
    if profile is None:
        return ()
    return tuple(dict.fromkeys(str(record["package"]) for record in profile["installs"]))


def recorded_elsewhere(except_scope: str, project_root: Path) -> list[str]:
    """ycc installs recorded for the active profile, without the one at ``except_scope`` (this run's).

    ``remove --target omp`` keeps the dedupe entries while any remain (a project removal must not
    unhide duplicates the user install still exposes). A recorded project whose root no longer
    exists does not count (as in ``remaining_installs``). Raises ValueError when the record is unreadable.
    """
    guarded(state_path())
    if not state_path().exists():
        return []
    profile = load_state()["profiles"].get(OmpCli().profile_key())
    if profile is None:
        return []
    excluded_root = str(project_root.resolve()) if except_scope == "project" else None
    return [
        f"{record['package']} ({record['scope']}{' ' + record['project_root'] if record.get('project_root') else ''})"
        for record in profile["installs"]
        if not (record["scope"] == except_scope and record.get("project_root") == excluded_root)
        and not (record["scope"] == "project" and not Path(str(record.get("project_root") or "")).is_dir())
    ]


def coexistence_installed_hint() -> None:
    """W5: the agents target ran while ycc is installed in OMP and its ~/.agents copies are not hidden."""
    packages = recorded_packages()
    if not packages:
        return
    plan = coexistence_plan(packages, frozenset())
    current = string_list(omp_setting("skills.ignoredSkills"))
    if any(entry.startswith("agents/") and not ignored(entry, current) for entry in plan.entries):
        print(f"[!!] OMP also loads these skills; run {DEDUPE_HINT} to hide the ~/.agents copies in OMP")


# ---------------------------------------------------------------------------
# omp CLI
# ---------------------------------------------------------------------------


class OmpCli:
    """Read-only omp queries; every unknown output shape fails closed."""

    def _query(self, *argv: str, cwd: Path | None = None) -> str:
        try:
            result = subprocess.run(
                [omp_bin(), *argv],
                cwd=cwd,
                env=query_env(),
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                check=False,
            )
        except FileNotFoundError as error:
            raise ValueError("omp not found on PATH") from error
        if result.returncode:
            detail = ANSI_SGR.sub("", result.stderr.strip() or result.stdout.strip()).splitlines()
            raise ValueError(
                f"'omp {' '.join(argv)}' failed (exit {result.returncode})" + (f": {detail[-1]}" if detail else "")
            )
        return ANSI_SGR.sub("", result.stdout)

    def version(self) -> str:
        output = self._query("--version").strip()
        match = re.fullmatch(r"omp/(\d+\.\d+\.\d+)\S*", output)
        if match is None:
            raise ValueError(f"unrecognized 'omp --version' output: {output!r}")
        return match.group(1)

    def profile_key(self) -> str:
        key = self._query("config", "path").strip()
        if not key or "\n" in key:
            raise ValueError(f"unrecognized 'omp config path' output: {key!r}")
        return key

    def installed(self, cwd: Path) -> dict[str, Any]:
        """``plugin list --json`` from ``cwd`` (project items appear only inside that project)."""
        output = self._query("plugin", "list", "--json", cwd=cwd)
        try:
            listing = json.loads(output)
        except json.JSONDecodeError as error:
            raise ValueError(f"unparseable 'omp plugin list --json' output ({error})") from error
        if (
            not isinstance(listing, dict)
            or not isinstance(listing.get("npm"), list)
            or not isinstance(listing.get("marketplace"), list)
            or not all(isinstance(item, dict) for item in (*listing["npm"], *listing["marketplace"]))
        ):
            raise ValueError("'omp plugin list --json' is not an object with 'npm' and 'marketplace' lists")
        return listing

    def setting(self, key: str) -> Any:
        """``config get <key> --json`` from $HOME: the user-level effective value (project config excluded)."""
        output = self._query("config", "get", key, "--json", cwd=Path.home())
        try:
            payload = json.loads(output)
        except json.JSONDecodeError as error:
            raise ValueError(f"unparseable 'omp config get {key} --json' output ({error})") from error
        if not isinstance(payload, dict) or payload.get("key") != key or "value" not in payload:
            raise ValueError(f"unrecognized 'omp config get {key} --json' output")
        return payload["value"]

    def marketplaces(self) -> dict[str, str]:
        """name → source from ``plugin marketplace list`` (text only, even with --json)."""
        lines = self._query("plugin", "marketplace", "list").rstrip().splitlines()
        if tuple(lines) == NO_MARKETPLACES:
            return {}
        if len(lines) < 3 or lines[0] != "Configured Marketplaces:" or lines[1] != "":
            raise ValueError("unrecognized 'omp plugin marketplace list' output")
        result: dict[str, str] = {}
        for line in lines[2:]:
            match = MARKETPLACE_LINE.match(line)
            if match is None or match.group(1) in result:
                raise ValueError(f"unrecognized 'omp plugin marketplace list' line: {line!r}")
            result[match.group(1)] = match.group(2)
        return result


def available() -> str:
    """The omp version when omp runs and meets MIN_OMP_VERSION; else ValueError(reason)."""
    if shutil.which(omp_bin()) is None:
        raise ValueError("omp not found on PATH")
    version = OmpCli().version()
    if version_key(version) < version_key(MIN_OMP_VERSION):
        raise ValueError(f"omp {version} is older than {MIN_OMP_VERSION}")
    return version


def run(*argv: str, cwd: Path, dry_run: bool = False) -> None:
    """Run a mutating omp call (echoed first); in dry-run only print it."""
    text = " ".join(argv)
    if dry_run:
        print(f"[dry-run] would run: omp {text}", flush=True)
        return
    print(f"[ok] omp {text}", flush=True)
    try:
        code = subprocess.run([omp_bin(), *argv], cwd=cwd, stdin=subprocess.DEVNULL, check=False).returncode
    except FileNotFoundError as error:
        raise ValueError("omp not found on PATH") from error
    if code:
        raise ValueError(f"'omp {text}' failed (exit {code})")


def preview(*argv: str, cwd: Path) -> None:
    """Run omp's own ``--dry-run`` (install/uninstall only) as dry-run validation."""
    print(f"[dry-run] omp {' '.join(argv)}", flush=True)
    try:
        code = subprocess.run([omp_bin(), *argv], cwd=cwd, stdin=subprocess.DEVNULL, check=False).returncode
    except FileNotFoundError as error:
        raise ValueError("omp not found on PATH") from error
    if code:
        raise ValueError(f"'omp {' '.join(argv)}' failed (exit {code})")


def scope_entry(listing: dict[str, Any], package: str, scope: str) -> dict[str, Any] | None:
    """The ``plugin list --json`` entry for ``<package>@ycc`` at exactly ``scope``."""
    for item in listing["marketplace"]:
        if item.get("id") != selector(package) or item.get("scope") != scope:
            continue
        entries = item.get("entries")
        if not isinstance(entries, list) or not entries or not all(isinstance(e, dict) for e in entries):
            raise ValueError(f"'omp plugin list --json': {selector(package)} ({scope}) has no entries")
        chosen: dict[str, Any] = next((entry for entry in entries if entry.get("scope") == scope), entries[0])
        return chosen
    return None


def ycc_items(listing: dict[str, Any], scope: str) -> list[dict[str, Any]]:
    return [
        item
        for item in listing["marketplace"]
        if isinstance(item.get("id"), str) and item["id"].endswith(f"@{MARKETPLACE}") and item.get("scope") == scope
    ]


def entry_version(entry: dict[str, Any]) -> str:
    version = entry.get("version")
    return version if isinstance(version, str) else "unknown"


def entry_path(entry: dict[str, Any]) -> str | None:
    path = entry.get("installPath")
    return path if isinstance(path, str) and path else None


def linked_names(listing: dict[str, Any]) -> set[str]:
    return {item["name"] for item in listing["npm"] if isinstance(item.get("name"), str)}


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------


def fresh_state() -> dict[str, Any]:
    return {
        "version": 1,
        "export": None,
        "export_inventory": {},
        "profiles": {},
        "migrate_pending": {},
        "project_residue": {},
    }


def load_state() -> dict[str, Any]:
    path = state_path()
    guarded(path)
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return fresh_state()
    if not isinstance(state, dict) or state.get("version") != 1:
        raise ValueError(f"{path}: expected a version 1 JSON object")
    state.setdefault("export", None)
    state.setdefault("export_inventory", {})
    profiles = state.setdefault("profiles", {})
    pending = state.setdefault("migrate_pending", {})
    residue = state.setdefault("project_residue", {})
    if not isinstance(profiles, dict) or not isinstance(state["export_inventory"], dict):
        raise ValueError(f"{path}: malformed profiles or export_inventory")
    if not isinstance(pending, dict) or not all(
        isinstance(entries, list) and all(isinstance(entry, dict) and entry.get("scope") in SCOPES for entry in entries)
        for entries in pending.values()
    ):
        raise ValueError(f"{path}: malformed migrate_pending")
    if not isinstance(residue, dict) or not all(
        isinstance(paths, list) and all(isinstance(item, str) for item in paths) for paths in residue.values()
    ):
        raise ValueError(f"{path}: malformed project_residue")
    for key, profile in profiles.items():
        if not isinstance(profile, dict):
            raise ValueError(f"{path}: profile {key!r} must be an object")
        profile.setdefault("marketplace", None)
        installs = profile.setdefault("installs", [])
        marketplace = profile["marketplace"]
        if marketplace is not None and not (
            isinstance(marketplace, dict) and isinstance(marketplace.get("source"), str)
        ):
            raise ValueError(f"{path}: profile {key!r} has a malformed marketplace record")
        if not isinstance(installs, list) or not all(
            isinstance(item, dict) and isinstance(item.get("package"), str) and item.get("scope") in SCOPES
            for item in installs
        ):
            raise ValueError(f"{path}: profile {key!r} has malformed installs")
    return state


def save_state(state: dict[str, Any]) -> None:
    path = state_path()
    guarded(path)
    previous = os.umask(0o077)
    try:
        atomic_write(path, json.dumps(state, indent=2) + "\n")
    finally:
        os.umask(previous)


def write_or_delete_state(state: dict[str, Any]) -> None:
    if state["profiles"] or state.get("export") or state.get("migrate_pending") or state.get("project_residue"):
        save_state(state)
    else:
        guarded(state_path())
        state_path().unlink(missing_ok=True)


def profile_state(state: dict[str, Any], key: str) -> dict[str, Any]:
    profile: dict[str, Any] = state["profiles"].setdefault(key, {"marketplace": None, "installs": []})
    return profile


def find_record(profile: dict[str, Any], package: str, scope: str, root: str | None) -> dict[str, Any] | None:
    return next(
        (
            record
            for record in profile["installs"]
            if record["package"] == package and record["scope"] == scope and record.get("project_root") == root
        ),
        None,
    )


def prune_profiles(state: dict[str, Any]) -> None:
    state["profiles"] = {
        key: profile for key, profile in state["profiles"].items() if profile["marketplace"] or profile["installs"]
    }


def drop_pending(state: dict[str, Any], profile_key: str, scope: str, root: str | None) -> bool:
    """Forget a native install ``migrate --apply`` still owed (scope, project root); True if one was owed."""
    entries = state["migrate_pending"].get(profile_key)
    if not entries:
        return False
    kept = [entry for entry in entries if not (entry["scope"] == scope and entry.get("project_root") == root)]
    if len(kept) == len(entries):
        return False
    if kept:
        state["migrate_pending"][profile_key] = kept
    else:
        del state["migrate_pending"][profile_key]
    return True


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------


def build_export(staging: Path) -> None:
    """Generate the repository-shaped OMP export into ``staging`` and validate it."""
    for script in ("generate_omp_packages.py", "validate_omp_native.py"):
        subprocess.run(
            [sys.executable, str(ROOT / "scripts" / script), "--export", str(staging)],
            cwd=ROOT,
            env=clean_env(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            check=True,
        )


# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------


@dataclass
class Step:
    package: str
    action: str  # install | upgrade | force | current | unowned
    target: str
    installed: str | None
    disabled: bool


def plan_step(
    package: str,
    scope: str,
    entry: dict[str, Any] | None,
    record: dict[str, Any] | None,
    target: str,
    force: bool,
) -> Step:
    if entry is None:
        return Step(package, "install", target, None, False)
    installed = entry_version(entry)
    disabled = entry.get("enabled") is False
    if record is None:
        return Step(package, "unowned", target, installed, disabled)
    path = entry_path(entry)
    if force or path is None or not Path(path).exists():
        return Step(package, "force", target, installed, disabled)
    if older(installed, target):
        return Step(package, "upgrade", target, installed, disabled)
    return Step(package, "current", target, installed, disabled)


def restart_line(packages: tuple[str, ...]) -> str:
    rules = (
        "; rules apply to new sessions (/new or restart)"
        if any("rules" in package_components(package) for package in packages)
        else ""
    )
    restart = [package for package in packages if RESTART_COMPONENTS & set(package_components(package))]
    if restart:
        return f"[!!] restart running omp sessions: {', '.join(restart)} ship hooks or extensions{rules}"
    mcp = [package for package in packages if "mcp" in package_components(package)]
    if mcp:
        return (
            "[ok] running omp sessions: run /reload-plugins (skills, commands, agents, MCP) or restart them; "
            f"MCP servers from {', '.join(mcp)} start only after a reload or restart{rules}"
        )
    return f"[ok] running omp sessions: run /reload-plugins (skills, commands, agents, MCP){rules}"


def check_dangling_projects(cli: OmpCli, profile: dict[str, Any]) -> None:
    """A user-scope upgrade GCs caches that project installs elsewhere still point at."""
    for record in profile["installs"]:
        root = record.get("project_root")
        if record["scope"] != "project" or not isinstance(root, str) or not Path(root).is_dir():
            continue
        entry = scope_entry(cli.installed(Path(root)), record["package"], "project")
        path = entry_path(entry) if entry is not None else None
        if entry is not None and (path is None or not Path(path).exists()):
            print(
                f"[!!] {selector(record['package'])} project install at {root} lost its cache (omp GC); "
                f"repair: cd {root} && {ROOT}/install.sh install --target omp --project"
            )


def present(path: Path) -> bool:
    return path.exists() or path.is_symlink()


def install(
    packages_csv: str,
    scope: str,
    project_root: Path,
    mode: str = "local",
    *,
    dry_run: bool = False,
    force: bool = False,
) -> None:
    if scope not in SCOPES or mode not in ("local", "repo"):
        raise ValueError(f"invalid scope/mode: {scope}/{mode}")
    home = Path.home()
    root = project_root.resolve()
    if scope == "project" and root == home.resolve():
        raise ValueError(HOME_REFUSAL)
    if mode == "repo" and not listed():
        raise ValueError(REPO_REFUSAL)
    packages = select_packages(packages_csv)
    available()
    cli = OmpCli()
    profile_key = cli.profile_key()
    state = load_state()
    snapshot = copy.deepcopy(state)
    cwd = root if scope == "project" else home
    record_root = str(root) if scope == "project" else None

    # Read-only plan; every refusal happens before any mutation.
    listing = cli.installed(cwd)
    user_listing = listing if scope == "user" else cli.installed(home)
    for package in packages:
        if package in linked_names(listing) | linked_names(user_listing):
            raise ValueError(
                f"runtime package {package} is linked (omp plugin link); run ./install.sh migrate --target omp"
            )
    exported = export_dir()
    source = REPOSITORY if mode == "repo" else str(exported)
    registered = cli.marketplaces().get(MARKETPLACE)
    if registered is not None and not same_source(registered, source):
        raise ValueError(
            f"marketplace ycc has a different source ({registered}); retained "
            "(run ./install.sh migrate --target omp or remove it)"
        )
    current_inventory: dict[str, list[Any]] | None = None
    if mode == "local":
        guarded(exported)
        recorded = state["export_inventory"] if state.get("export") == str(exported) else None
        if exported.exists() or exported.is_symlink():
            current_inventory = inventory(exported)
            if current_inventory != recorded and not force:
                raise ValueError(
                    f"{exported} exists but is not the recorded ycc export; rerun with --force to replace it"
                )

    staging: Path | None = None
    backup: Path | None = None
    try:
        new_inventory: dict[str, list[Any]] = {}
        export_changed = False
        if mode == "local":
            if dry_run:
                staging = Path(tempfile.mkdtemp(prefix="ycc-omp-export."))
            else:
                exported.parent.mkdir(parents=True, exist_ok=True)
                staging = Path(tempfile.mkdtemp(dir=exported.parent, prefix=f".{exported.name}.staging."))
            build_export(staging)
            new_inventory = inventory(staging)
            export_changed = new_inventory != current_inventory
            versions = {package: package_version(staging, package) for package in packages}
        else:
            versions = {package: package_version(ROOT, package) for package in packages}

        profile = copy.deepcopy(state["profiles"].get(profile_key) or {"marketplace": None, "installs": []})
        steps = [
            plan_step(
                package,
                scope,
                scope_entry(listing, package, scope),
                find_record(profile, package, scope, record_root),
                versions[package],
                force,
            )
            for package in packages
        ]
        changes = [step for step in steps if step.action in ("install", "upgrade", "force")]
        if registered is None:
            marketplace_action = "add"
        elif export_changed or (mode == "repo" and any(step.action in ("upgrade", "force") for step in changes)):
            marketplace_action = "update"
        else:
            marketplace_action = ""

        # A same-version export change is not reinstalled (omp upgrades by version only).
        stale = mode == "local" and export_changed
        if dry_run:
            dry_run_install(steps, scope, cwd, source, exported, export_changed, marketplace_action, registered, stale)
            return

        # Mutations, ownership recorded before each create.
        created_marketplace = False
        moved_out = False
        swapped = False
        succeeded: list[dict[str, Any]] = []
        unconfirmed: list[str] = []
        try:
            if scope == "project" and record_root is not None:
                # The omp project state this root lacks now is ycc's to delete once emptied on remove;
                # a later install adds what is missing again to the root's existing record. Owned entries
                # absent now (left by a killed run) are unconfirmed too, kept only if this run creates them.
                owned = state["project_residue"].setdefault(record_root, [])
                added = [rel for rel in PROJECT_RESIDUE if rel not in owned and not present(root / rel)]
                unconfirmed = [rel for rel in owned if not present(root / rel)] + added
                if added or record_root not in snapshot["project_residue"]:
                    owned.extend(added)
                    save_state(state)
            if mode == "local" and staging is not None:
                if export_changed:
                    if exported.exists():
                        backup = Path(tempfile.mkdtemp(dir=exported.parent, prefix=f".{exported.name}.previous."))
                        os.replace(exported, backup)
                        moved_out = True
                    os.replace(staging, exported)
                    staging = None
                    swapped = True
                    print(f"[ok] exported OMP packages → {exported} (ycc {versions[packages[0]]})")
                if state.get("export") != str(exported) or state["export_inventory"] != new_inventory:
                    state["export"] = str(exported)
                    state["export_inventory"] = new_inventory
                    save_state(state)
            live = profile_state(state, profile_key)
            if marketplace_action == "add":
                live["marketplace"] = {"name": MARKETPLACE, "source": source}
                save_state(state)
                run("plugin", "marketplace", "add", source, cwd=home)
                created_marketplace = True
            elif marketplace_action == "update":
                run("plugin", "marketplace", "update", MARKETPLACE, cwd=home)
            for step in steps:
                apply_step(cli, state, live, step, scope, cwd, record_root, succeeded, stale)
        except BaseException:
            rollback(
                state_snapshot=snapshot,
                live_residue=state["project_residue"],
                unconfirmed=unconfirmed,
                profile_key=profile_key,
                succeeded=succeeded,
                created_marketplace=created_marketplace,
                moved_out=moved_out,
                swapped=swapped,
                backup=backup,
                exported=exported,
                home=home,
            )
            backup = None
            raise

        pruned = False
        if unconfirmed and record_root is not None:
            # Paths claimed but never created stay unowned; the user may create them later.
            owned = state["project_residue"][record_root]
            kept = [rel for rel in owned if rel not in unconfirmed or present(root / rel)]
            pruned = kept != owned
            owned[:] = kept
        if drop_pending(state, profile_key, scope, record_root) or pruned:
            save_state(state)
        for step in steps:
            if step.disabled and step.action != "unowned":
                print(f"[ok] {selector(step.package)} disabled at {scope} scope: kept")
        mutated = bool(changes) or bool(marketplace_action)
        if changes:
            # omp < 18.13.0, and project installs made before upgrading omp to 18.13.0, can lose their
            # cache on upgrade and forced reinstall (oh-my-pi#16827); recorded projects elsewhere may now dangle.
            check_dangling_projects(cli, live)
        if mutated:
            print(restart_line(packages))
            print(TRUST)
        if scope == "project":
            for step in changes:
                print(
                    "[ok] a project install shadows your user install here; "
                    f"omp plugin disable --scope project {selector(step.package)} returns to the user copy"
                )
    finally:
        if staging is not None and staging.exists():
            shutil.rmtree(staging)
        if backup is not None and backup.exists():
            shutil.rmtree(backup)


def dry_run_install(
    steps: list[Step],
    scope: str,
    cwd: Path,
    source: str,
    exported: Path,
    export_changed: bool,
    marketplace_action: str,
    registered: str | None,
    stale: bool,
) -> None:
    if export_changed:
        print(f"[dry-run] would export OMP packages → {exported}")
    home = Path.home()
    if marketplace_action == "add":
        run("plugin", "marketplace", "add", source, cwd=home, dry_run=True)
    elif marketplace_action == "update":
        run("plugin", "marketplace", "update", MARKETPLACE, cwd=home, dry_run=True)
    for step in steps:
        name = selector(step.package)
        if step.action == "install":
            run("plugin", "install", "--scope", scope, name, cwd=cwd, dry_run=True)
            # Without the ycc marketplace omp would only warn that --scope is ignored.
            if registered is not None:
                preview("plugin", "install", "--dry-run", "--scope", scope, name, cwd=cwd)
        elif step.action == "upgrade":
            run("plugin", "upgrade", "--scope", scope, name, cwd=cwd, dry_run=True)
        elif step.action == "force":
            run("plugin", "install", "--force", "--scope", scope, name, cwd=cwd, dry_run=True)
            if registered is not None:
                preview("plugin", "install", "--force", "--dry-run", "--scope", scope, name, cwd=cwd)
        elif step.action == "current":
            print(current_line(name, step.installed, scope, stale))
        else:
            print(f"[!!] {name} is already installed ({scope}) and not recorded as ycc-owned; left untouched")
        if step.disabled and step.action != "unowned":
            print(f"[ok] {name} disabled at {scope} scope: kept")


def current_line(name: str, installed: str | None, scope: str, stale: bool) -> str:
    if stale:
        return (
            f"[!!] {name} {installed} ({scope}): the export changed but its version did not, so omp keeps the "
            "installed copy; rerun with --force to reinstall it"
        )
    return f"[ok] {name} {installed} up to date ({scope})"


def apply_step(
    cli: OmpCli,
    state: dict[str, Any],
    profile: dict[str, Any],
    step: Step,
    scope: str,
    cwd: Path,
    record_root: str | None,
    succeeded: list[dict[str, Any]],
    stale: bool,
) -> None:
    name = selector(step.package)
    if step.action == "current":
        print(current_line(name, step.installed, scope, stale))
        return
    if step.action == "unowned":
        print(f"[!!] {name} is already installed ({scope}) and not recorded as ycc-owned; left untouched")
        return
    record = find_record(profile, step.package, scope, record_root)
    if step.action == "install":
        if record is None:
            record = {
                "package": step.package,
                "scope": scope,
                "project_root": record_root,
                "version": step.target,
                "cache_root": None,
            }
            profile["installs"].append(record)
            save_state(state)
        run("plugin", "install", "--scope", scope, name, cwd=cwd)
    elif step.action == "upgrade":
        run("plugin", "upgrade", "--scope", scope, name, cwd=cwd)
    else:
        run("plugin", "install", "--force", "--scope", scope, name, cwd=cwd)
    entry = scope_entry(cli.installed(cwd), step.package, scope)
    if entry is None or record is None:
        raise ValueError(f"omp reported success but {name} is not listed ({scope})")
    version = entry_version(entry)
    path = entry_path(entry)
    record["version"] = version
    record["cache_root"] = str(Path(path).parent) if path else None
    save_state(state)
    succeeded.append(copy.deepcopy(record))
    if step.action == "install":
        print(f"[ok] {name} {version} installed ({scope})")
    elif step.action == "upgrade":
        print(f"[ok] {name} {step.installed} -> {version} upgraded ({scope})")
    else:
        print(f"[ok] {name} {version} reinstalled ({scope})")
        print(f"[ok] the {name} {version} cache is shared by its user and project installs")


def rollback(
    *,
    state_snapshot: dict[str, Any],
    live_residue: dict[str, list[str]],
    unconfirmed: list[str],
    profile_key: str,
    succeeded: list[dict[str, Any]],
    created_marketplace: bool,
    moved_out: bool,
    swapped: bool,
    backup: Path | None,
    exported: Path,
    home: Path,
) -> None:
    """Undo only what this run created; the failing item's record reverts, earlier successes stay.

    A kept project install keeps the residue record written or extended for its root, merged into the
    restored one, so remove can still delete the ``.omp`` state ycc created there; ``unconfirmed``
    entries (absent when the run started) that still do not exist are dropped. With no success the
    record reverts with the rest.
    """
    if created_marketplace:
        try:
            run("plugin", "marketplace", "remove", MARKETPLACE, cwd=home)
        except (OSError, ValueError) as error:
            print(f"[!!] rollback could not remove marketplace ycc: {error}", file=sys.stderr)
    if swapped:
        shutil.rmtree(exported, ignore_errors=True)
    if moved_out and backup is not None:
        # The previous export was moved aside; put it back whether or not the new one landed.
        os.replace(backup, exported)
        print(f"[!!] restored the previous export {exported}", file=sys.stderr)
    elif backup is not None and backup.exists():
        shutil.rmtree(backup)
    restored = copy.deepcopy(state_snapshot)
    if succeeded:
        profile = profile_state(restored, profile_key)
        for record in succeeded:
            existing = find_record(profile, record["package"], record["scope"], record.get("project_root"))
            if existing is not None:
                existing.update(record)
            else:
                profile["installs"].append(record)
            root = record.get("project_root")
            if record["scope"] == "project" and isinstance(root, str) and root in live_residue:
                merged = restored["project_residue"].get(root, [])
                merged += [rel for rel in live_residue[root] if rel not in merged]
                restored["project_residue"][root] = [
                    rel for rel in merged if rel not in unconfirmed or present(Path(root) / rel)
                ]
    write_or_delete_state(restored)


# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------


def remove(scope: str, project_root: Path, *, dry_run: bool = False) -> None:
    if scope not in SCOPES:
        raise ValueError(f"invalid scope: {scope}")
    guarded(state_path())
    if not state_path().exists():
        print("[ok] nothing ycc-owned to remove for omp")
        return
    state = load_state()
    available()
    cli = OmpCli()
    home = Path.home()
    root = project_root.resolve()
    record_root = str(root) if scope == "project" else None
    cwd = root if scope == "project" else home
    profile_key = cli.profile_key()
    profile = state["profiles"].get(profile_key)
    acted = False
    mutated = False
    planned: set[tuple[str, str, str | None]] = set()

    def persist() -> None:
        if not dry_run:
            save_state(state)

    if profile is not None:
        listing = cli.installed(cwd) if cwd.is_dir() else None
        # A `ycc` marketplace now pointing elsewhere serves someone else's ycc@ycc: never uninstall that.
        current = cli.marketplaces().get(MARKETPLACE)
        owned_sources = [
            source
            for source in (
                (profile["marketplace"] or {}).get("source"),
                state.get("export") if isinstance(state.get("export"), str) else None,
                REPOSITORY,
            )
            if source
        ]
        foreign = current is not None and not any(same_source(current, source) for source in owned_sources)
        for record in [r for r in profile["installs"] if r["scope"] == scope and r.get("project_root") == record_root]:
            acted = True
            name = selector(record["package"])
            if foreign:
                print(
                    f"[!!] kept {name} ({scope}): marketplace ycc now points at {current}, not ycc's export; "
                    "dropped from the ycc record"
                )
            elif listing is not None and scope_entry(listing, record["package"], scope) is not None:
                if dry_run:
                    run("plugin", "uninstall", "--scope", scope, name, cwd=cwd, dry_run=True)
                    preview("plugin", "uninstall", "--dry-run", "--scope", scope, name, cwd=cwd)
                else:
                    run("plugin", "uninstall", "--scope", scope, name, cwd=cwd)
                    mutated = True
            else:
                print(f"[ok] {name} is no longer installed ({scope}); dropped from the ycc record")
            planned.add((record["package"], scope, record_root))
            profile["installs"].remove(record)
            persist()

        marketplace = profile["marketplace"]
        if marketplace is not None:
            if current is None:
                profile["marketplace"] = None
            elif not same_source(current, marketplace["source"]):
                print(f"[!!] kept marketplace ycc: its source changed to {current}; no longer ycc-owned")
                profile["marketplace"] = None
            else:
                remaining = remaining_installs(cli, profile, record_root, planned)
                if remaining:
                    acted = True
                    print(f"[!!] kept marketplace ycc: {', '.join(remaining)} still installed")
                else:
                    acted = True
                    run("plugin", "marketplace", "remove", MARKETPLACE, cwd=home, dry_run=dry_run)
                    mutated = mutated or not dry_run
                    profile["marketplace"] = None
            persist()
    prune_profiles(state)

    recorded_export = state.get("export")
    if isinstance(recorded_export, str) and not state["profiles"]:
        acted = True
        exported = Path(recorded_export)
        if exported.exists() or exported.is_symlink():
            try:
                ours = inventory(exported) == state["export_inventory"]
            except ValueError:
                ours = False
            if not ours:
                print(f"[!!] kept {exported}: edited since ycc exported it")
            elif dry_run:
                print(f"[dry-run] would remove {exported}")
            else:
                shutil.rmtree(exported)
                print(f"[ok] removed {exported}")
        state["export"] = None
        state["export_inventory"] = {}
    if not dry_run:
        owned: frozenset[str] = frozenset()
        if scope == "project" and record_root is not None:
            owned = frozenset(state["project_residue"].get(record_root, ()))
            if not any(
                record["scope"] == "project" and record.get("project_root") == record_root
                for kept in state["profiles"].values()
                for record in kept["installs"]
            ):
                state["project_residue"].pop(record_root, None)
        write_or_delete_state(state)
        if scope == "project" and acted:
            remove_project_residue(root, owned)
    if not acted:
        print("[ok] nothing ycc-owned to remove for omp")
    if mutated:
        if profile is not None and not dry_run:
            # omp < 18.13.0, and project installs made before upgrading omp to 18.13.0, can lose their
            # cache on uninstall too (oh-my-pi#16827); recorded projects elsewhere may now dangle.
            check_dangling_projects(cli, profile)
        print("[ok] running omp sessions: run /reload-plugins (skills, commands, agents, MCP)")


def json_equals(path: Path, expected: Any) -> bool:
    try:
        return bool(json.loads(path.read_text(encoding="utf-8")) == expected)
    except (OSError, ValueError):
        return False


def remove_project_residue(root: Path, owned: frozenset[str]) -> None:
    """Delete the empty ``.omp/plugins`` state ycc's project install created, after its last uninstall.

    ``owned`` are the ``PROJECT_RESIDUE`` paths (relative to ``root``) that the ycc install which
    first claimed each one found absent and created; anything else, including a legacy root with no
    ownership record, is kept. Of those,
    only omp's exact empty forms go (registry ``{"version": 2, "plugins": {}}``, lock with empty
    ``plugins`` and ``settings``, an empty ``node_modules/``), then the emptied dirs. Never $HOME's own.
    """
    omp_dir = root / ".omp"
    plugins = omp_dir / "plugins"
    if root.resolve() == Path.home().resolve() or omp_dir.is_symlink() or plugins.is_symlink() or not plugins.is_dir():
        return
    removed = False
    registry = plugins / "installed_plugins.json"
    if (
        ".omp/plugins/installed_plugins.json" in owned
        and registry.is_file()
        and json_equals(registry, {"version": 2, "plugins": {}})
    ):
        registry.unlink()
        removed = True
    lock = plugins / "omp-plugins.lock.json"
    if (
        ".omp/plugins/omp-plugins.lock.json" in owned
        and lock.is_file()
        and json_equals(lock, {"plugins": {}, "settings": {}})
    ):
        lock.unlink()
        removed = True
    for directory in (plugins / "node_modules", plugins, omp_dir):
        if (
            directory.relative_to(root).as_posix() in owned
            and directory.is_dir()
            and not directory.is_symlink()
            and not any(directory.iterdir())
        ):
            directory.rmdir()
            removed = True
    if removed:
        print(f"[ok] removed the empty omp project state under {omp_dir}")


def remaining_installs(
    cli: OmpCli,
    profile: dict[str, Any],
    current_root: str | None,
    planned: set[tuple[str, str, str | None]],
) -> list[str]:
    """``*@ycc`` installs still present in user scope, any recorded project, or this run's project.

    ``planned`` uninstalls are excluded, so a dry-run preview reaches the same decision.
    """
    remaining: list[str] = []
    for item in ycc_items(cli.installed(Path.home()), "user"):
        package = str(item["id"]).rsplit("@", 1)[0]
        if (package, "user", None) not in planned:
            remaining.append(f"{item['id']} (user)")
    roots = {r["project_root"] for r in profile["installs"] if r["scope"] == "project" and r.get("project_root")}
    if current_root is not None:
        roots.add(current_root)
    for root in sorted(root for root in roots if Path(root).is_dir()):
        for item in ycc_items(cli.installed(Path(root)), "project"):
            package = str(item["id"]).rsplit("@", 1)[0]
            if (package, "project", root) not in planned:
                remaining.append(f"{item['id']} (project {root})")
    return remaining


# ---------------------------------------------------------------------------
# Migrate
# ---------------------------------------------------------------------------


@dataclass
class LegacyLink:
    name: str
    cwd: Path


@dataclass
class MigratePlan:
    """What ``migrate`` changes, decided read-only before any mutation."""

    profile_key: str
    packages: tuple[str, ...]
    links: list[LegacyLink]
    retire_marketplace: bool
    retire_scopes: list[tuple[str, Path, list[str]]]
    # Native installs owed: this run's retired scopes plus any an interrupted migrate left behind.
    owed: list[tuple[str, Path]]


def install_hint(scope: str, cwd: Path) -> str:
    if scope == "user":
        return f"{ROOT}/install.sh install --target omp"
    return f"cd {cwd} && {ROOT}/install.sh install --target omp --project"


def plan_migrate(project_root: Path, *, apply: bool) -> MigratePlan | None:
    """Find proven-ycc legacy omp state; every refusal happens here. None when omp is absent.

    ``project_root`` is the installer's project root (git toplevel, else the working directory),
    the same root ``install``/``remove --project`` record, so a migrated project install stays removable.
    """
    if shutil.which(omp_bin()) is None:
        return None
    available()
    cli = OmpCli()
    home = Path.home()
    state = load_state()
    profile_key = cli.profile_key()
    recorded_export = state.get("export") if isinstance(state.get("export"), str) else None
    keys = omp_package_keys()
    packages = select_packages("")
    root = project_root.resolve()
    project = root if root.is_dir() and root != home.resolve() else None
    user_listing = cli.installed(home)
    project_listing = cli.installed(project) if project is not None else None

    # Links: an npm entry named after a ycc OMP package that resolves into this checkout or the export.
    links: list[LegacyLink] = []
    foreign_links: set[str] = set()
    seen: set[str] = set()
    for listing, cwd in ((user_listing, home), (project_listing, project)):
        if listing is None or cwd is None:
            continue
        for item in listing["npm"]:
            name, path = item.get("name"), item.get("path")
            if not isinstance(name, str) or name not in keys or name in seen:
                continue
            seen.add(name)
            target = os.path.realpath(path) if isinstance(path, str) else ""
            owned = bool(target) and (
                within(target, str(ROOT / "packages/omp" / name))
                or (recorded_export is not None and within(target, recorded_export))
            )
            if owned:
                links.append(LegacyLink(name, cwd))
            else:
                foreign_links.add(name)
                print(
                    f"[!!] kept omp link {name} → {target or path}: foreign (not this checkout's packages/omp/{name})"
                )

    # A `ycc` marketplace at this checkout root added before the OMP catalog was listed served the
    # Claude packages: its installs carry no .omp-plugin/plugin.json. Those legacy installs retire it;
    # a native install, or no install while the checkout serves an OMP catalog, keeps it.
    retire_scopes: list[tuple[str, Path, list[str]]] = []
    retire_marketplace = False
    # Legacy installs migrate cannot carry over as-is: disabled ones (a fresh install is enabled, and
    # ycc never calls enable/disable) and ones with no native OMP package (they would just vanish).
    keep: list[str] = []
    source = cli.marketplaces().get(MARKETPLACE)
    if source is not None and same_source(source, str(ROOT)):
        found: list[tuple[str, Path, list[str]]] = []
        native = False
        for scope, listing, cwd in (("user", user_listing, home), ("project", project_listing, project)):
            if listing is None or cwd is None:
                continue
            ids: list[str] = []
            for item in ycc_items(listing, scope):
                plugin_id = str(item["id"])
                package = plugin_id.rsplit("@", 1)[0]
                entry = scope_entry(listing, package, scope)
                path = entry_path(entry) if entry is not None else None
                if path is not None and (Path(path) / ".omp-plugin/plugin.json").is_file():
                    native = True
                where = f"--scope {scope} {plugin_id}"
                if package not in packages:
                    keep.append(
                        f"{plugin_id} ({scope}) has no native OMP package yet; "
                        f"uninstall it yourself (omp plugin uninstall {where}) to let migrate retire the marketplace"
                    )
                elif entry is not None and entry.get("enabled") is False:
                    keep.append(
                        f"{plugin_id} is disabled ({scope}) and migrate would reinstall it enabled; "
                        f"uninstall it yourself (omp plugin uninstall {where}), re-run, "
                        f"then omp plugin disable {where}"
                    )
                ids.append(plugin_id)
            if ids:
                found.append((scope, cwd, ids))
        if native or (not found and (ROOT / ".omp-plugin/marketplace.json").is_file()):
            print(f"[!!] kept marketplace ycc at {ROOT}: it serves native OMP packages")
        elif keep:
            raise ValueError(f"kept marketplace ycc at {ROOT} and its installs: " + "; ".join(keep))
        else:
            retire_marketplace = True
            retire_scopes = found
    elif source is not None and not (recorded_export is not None and same_source(source, recorded_export)):
        print(f"[!!] kept marketplace ycc ({source}): foreign")

    owed: list[tuple[str, Path]] = [(scope, cwd) for scope, cwd, _ in retire_scopes]
    for entry in state["migrate_pending"].get(profile_key, []):
        scope, pending_root = entry["scope"], entry.get("project_root")
        cwd = home if scope == "user" else Path(str(pending_root))
        if scope == "project" and not cwd.is_dir():
            print(f"[!!] dropped the pending native install at {cwd}: the directory is gone")
        elif (scope, cwd) not in owed:
            owed.append((scope, cwd))

    if owed:
        # Preflight the native reinstall before any mutation.
        blocked = sorted(foreign_links & set(packages))
        if blocked:
            raise ValueError(
                f"runtime package {', '.join(blocked)} is linked from a foreign source; "
                "unlink it before migrating the checkout-root marketplace"
            )
        exported = export_dir()
        # install() refuses a `ycc` marketplace at any other source; this run removes only the checkout root's.
        if source is not None and not retire_marketplace and not same_source(source, str(exported)):
            raise ValueError(
                f"marketplace ycc has a different source ({source}); retained "
                "(remove it before migrating: omp plugin marketplace remove ycc)"
            )
        guarded(exported)
        if exported.exists():
            recorded = state["export_inventory"] if recorded_export == str(exported) else None
            if inventory(exported) != recorded:
                raise ValueError(
                    f"{exported} exists but is not the recorded ycc export; move it aside, "
                    f"run {ROOT}/install.sh install --target omp --force, then re-run migrate"
                )
        if apply:
            # Build and validate the export the native install needs before anything is uninstalled.
            staging = Path(tempfile.mkdtemp(prefix="ycc-omp-migrate."))
            try:
                build_export(staging)
                for package in packages:
                    package_version(staging, package)
            finally:
                shutil.rmtree(staging, ignore_errors=True)

    return MigratePlan(profile_key, packages, links, retire_marketplace, retire_scopes, owed)


def apply_migrate(plan: MigratePlan | None, apply: bool) -> None:
    """Carry out ``plan`` (dry-run unless ``apply``); foreign state is never touched."""
    if plan is None:
        print("[ok] omp: nothing to migrate (omp not found on PATH)")
        return
    home = Path.home()
    if apply:
        # Record the native installs owed before the first uninstall, so a re-run can finish them.
        state = load_state()
        pending = [
            {"scope": scope, "project_root": str(cwd) if scope == "project" else None} for scope, cwd in plan.owed
        ]
        if state["migrate_pending"].get(plan.profile_key, []) != pending:
            if pending:
                state["migrate_pending"][plan.profile_key] = pending
            else:
                del state["migrate_pending"][plan.profile_key]
            write_or_delete_state(state)

    # migrate has no dedupe step: report the overlap (W2–W4) so the user can run it.
    coexistence_warn(plan.packages, dry_run=not apply)
    if not plan.links and not plan.retire_marketplace and not plan.owed:
        print("[ok] omp: nothing to migrate")
        return

    for link in plan.links:
        run("plugin", "uninstall", link.name, cwd=link.cwd, dry_run=not apply)
        if not apply:
            preview("plugin", "uninstall", "--dry-run", link.name, cwd=link.cwd)
        print("[ok] run ./install.sh install --target omp to reinstall natively")
    if not apply:
        for scope, cwd, ids in plan.retire_scopes:
            for plugin_id in ids:
                run("plugin", "uninstall", "--scope", scope, plugin_id, cwd=cwd, dry_run=True)
                preview("plugin", "uninstall", "--dry-run", "--scope", scope, plugin_id, cwd=cwd)
        if plan.retire_marketplace:
            run("plugin", "marketplace", "remove", MARKETPLACE, cwd=home, dry_run=True)
        for scope, cwd in plan.owed:
            where = "" if scope == "user" else f" at {cwd}"
            print(f"[ok] would install the native OMP packages ({scope} scope{where})")
        return

    finished = 0
    try:
        for scope, cwd, ids in plan.retire_scopes:
            for plugin_id in ids:
                run("plugin", "uninstall", "--scope", scope, plugin_id, cwd=cwd)
        if plan.retire_marketplace:
            run("plugin", "marketplace", "remove", MARKETPLACE, cwd=home)
        for scope, cwd in plan.owed:
            install("", scope, cwd)  # Clears its migrate_pending entry on success.
            finished += 1
    except BaseException:
        left = plan.owed[finished:]
        print(
            "[!!] migrate stopped before the native install finished; "
            "re-run ./install.sh migrate --target omp --apply, or install directly:",
            file=sys.stderr,
        )
        for scope, cwd in left:
            print(f"[!!]   {install_hint(scope, cwd)}", file=sys.stderr)
        raise


def migrate(apply: bool, project_root: Path) -> None:
    """Retire proven-ycc legacy omp state (dry-run unless ``apply``); foreign state is kept."""
    apply_migrate(plan_migrate(project_root, apply=apply), apply)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("available", help="exit 0 and print the version when a supported omp is on PATH")
    commands.add_parser("agent-dir", help="print the active profile's agent directory ('omp config path')")
    commands.add_parser("listed", help="exit 0 iff an included native omp row is listed")
    install_parser = commands.add_parser("install", help="install or update the selected packages")
    install_parser.add_argument("--packages", default="")
    install_parser.add_argument("--mode", choices=("local", "repo"), default="local")
    install_parser.add_argument("--force", action="store_true")
    remove_parser = commands.add_parser("remove", help="remove the ycc-owned installs in one scope")
    for sub in (install_parser, remove_parser):
        sub.add_argument("--scope", choices=SCOPES, default="user")
        sub.add_argument("--project-root", type=Path, default=Path.cwd())
        sub.add_argument("--dry-run", action="store_true")
    migrate_parser = commands.add_parser("migrate", help="retire legacy omp links and checkout-root marketplaces")
    migrate_parser.add_argument("--apply", action="store_true")
    migrate_parser.add_argument("--project-root", type=Path, default=Path.cwd())
    coexistence_parser = commands.add_parser(
        "coexistence", help="hide (--emit) or report (--warn) ycc skills OMP also loads from other runtimes' dirs"
    )
    coexistence_parser.add_argument("--packages", default="")
    action = coexistence_parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--emit", type=Path, metavar="PATH", help="write the dedupe merge source; print the count")
    action.add_argument("--warn", action="store_true", help="print the coexistence warnings")
    coexistence_parser.add_argument("--hidden", metavar="CONFIG", help="with --warn: the dedupe step merged CONFIG")
    coexistence_parser.add_argument(
        "--if-installed", action="store_true", help="with --warn: only the agents-target hint, when OMP ycc is recorded"
    )
    coexistence_parser.add_argument("--dry-run", action="store_true")
    recorded_parser = commands.add_parser(
        "recorded", help="exit 0 if ycc keeps a recorded install in this profile besides one scope, else 3"
    )
    recorded_parser.add_argument("--except-scope", choices=SCOPES, required=True)
    recorded_parser.add_argument("--project-root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)

    if args.command == "coexistence":
        try:
            if args.if_installed:
                coexistence_installed_hint()
            elif args.emit is not None:
                print(coexistence_emit(select_packages(args.packages), args.emit))
            else:
                coexistence_warn(select_packages(args.packages), hidden=args.hidden, dry_run=args.dry_run)
        except (OSError, ValueError) as error:
            print(f"[err] OMP coexistence check stopped: {error}", file=sys.stderr)
            return 2
        return 0
    if args.command == "recorded":
        try:
            remaining = recorded_elsewhere(args.except_scope, args.project_root)
        except (OSError, ValueError) as error:
            print(f"[err] OMP install record unreadable: {error}", file=sys.stderr)
            return 2
        print("\n".join(remaining))
        return 0 if remaining else 3

    if args.command == "available":
        try:
            print(available())
        except (OSError, ValueError) as error:
            print(error, file=sys.stderr)
            return 1
        return 0
    if args.command == "agent-dir":
        try:
            available()
            print(OmpCli().profile_key())
        except (OSError, ValueError) as error:
            print(f"[err] omp agent directory unavailable: {error}", file=sys.stderr)
            return 2
        return 0
    if args.command == "migrate":
        try:
            migrate(args.apply, args.project_root)
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            print(f"[err] native OMP migration stopped: {error}", file=sys.stderr)
            return 2
        return 0
    try:
        if args.command == "listed":
            return 0 if listed() else 1
        if args.command == "install":
            install(args.packages, args.scope, args.project_root, args.mode, dry_run=args.dry_run, force=args.force)
        else:
            remove(args.scope, args.project_root, dry_run=args.dry_run)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"[err] native OMP install stopped: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
