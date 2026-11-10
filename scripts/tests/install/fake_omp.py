#!/usr/bin/env python3
"""Stateful fake of the oh-my-pi `omp` CLI (18.12.3) for the install test suites.

It emulates the plugin lifecycle that scripts/omp_install.py drives, with the messages, stdout/stderr
split, exit codes and on-disk layout of the real binary (checked against omp 18.12.3 by a parity run):

  omp --version                               omp/$FAKE_OMP_VERSION (default 18.12.3)
  omp [--profile N] config path               <root>/agent or <root>/profiles/N/agent
  omp [--profile N] config get <key> --json   {"key","value","type","description"} from <agent>/config.yml
                                              (array keys only: enabledProviders, skills.ignoredSkills, ...)
  omp [--profile N] plugin <action> ...       install uninstall upgrade enable disable list link
                                              doctor discover marketplace (add|remove|update|list)

Environment:
  FAKE_OMP_HOME            state root (default $HOME/.fake-omp); stands in for ~/.omp
  OMP_PROFILE / --profile  profile root <root>/profiles/<N> (config and data)
  XDG_DATA_HOME            when $XDG_DATA_HOME/omp exists (and no profile) data lives there
  FAKE_OMP_LOG             append `omp <args>` per call (falls back to CLAUDE_STUB_LOG)
  FAKE_OMP_VERSION         version reported by --version
  FAKE_OMP_FAIL            <verb>[:<target>]; the first matching call exits 1 with
                           `✘ Failed to <verb> <target>: Error: injected failure`. Verbs are the
                           plugin actions, or marketplace-add / marketplace-remove / marketplace-update
  FAKE_OMP_REPO_CATALOG    directory that a git/GitHub marketplace source "clones" from
  FAKE_OMP_NO_NODE_MODULES when set, marketplace installs skip the node_modules runtime link (and
                           the node_modules dir) so a test can leave that residue path uncreated
  FORCE_COLOR              colours `plugin marketplace list` like omp 18.12.6 (NO_COLOR does not win)
  FAKE_OMP_COLOR           colours `plugin marketplace list` whatever the colour environment
  FAKE_OMP_CLAUDE_CATALOG  when set, catalog lookups skip .omp-plugin/marketplace.json, like a
                           checkout from before the OMP packages were listed (legacy installs)

Unsupported commands exit 2 with a usage line on stderr.
"""

from __future__ import annotations

import json
import os
import posixpath
import re
import shutil
import sys
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

JsonObj = dict[str, Any]

DEFAULT_VERSION = "18.12.3"
PLUGIN_ACTIONS = (
    "install",
    "uninstall",
    "list",
    "link",
    "doctor",
    "features",
    "config",
    "enable",
    "disable",
    "marketplace",
    "discover",
    "upgrade",
)
CONFIG_ACTIONS = ("list", "get", "set", "reset", "path", "init-xdg")
PLUGIN_USAGE = "USAGE\n  $ omp plugin [ACTION] [TARGETS...] [FLAGS]\n\nRun `omp plugin --help` for details."
CONFIG_USAGE = "USAGE\n  $ omp config [ACTION] [KEY] [VALUE...] [FLAGS]\n\nRun `omp config --help` for details."
FAKE_USAGE = "usage: omp [--profile NAME] (--version | config path | plugin <action> [flags] [targets])"
BOOL_FLAGS = {"--json", "--fix", "--force", "--dry-run", "-l", "--local"}
VALUE_FLAGS = {"--enable", "--disable", "--set", "--scope"}
CATALOG_FILES = (".omp-plugin/marketplace.json", ".claude-plugin/marketplace.json")
MARKETPLACE_NAME = re.compile(r"^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$")
PACKAGE_NAME = re.compile(r"^(?:@[a-zA-Z0-9][a-zA-Z0-9._~-]*/)?[a-zA-Z0-9][a-zA-Z0-9._~-]*$")
CACHE_VERSION = re.compile(r"^[a-zA-Z0-9._+-]+$")
GITHUB_SHORTHAND = re.compile(r"^[a-z0-9-]+/[a-z0-9._-]+$", re.IGNORECASE)
WINDOWS_PATH = re.compile(r"^[A-Za-z]:[/\\]|^\\\\")
SEMVER = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$")
DIST_TAGS = {"latest", "next", "beta", "alpha", "canary", "rc", "dev", "stable", "nightly", "experimental"}
FAIL_MARKER = ".fake-omp-fail-consumed"
SCOPE_WARNING = "Warning: --scope is only supported for marketplace installs (name@marketplace)."


class OmpError(Exception):
    """An error omp reports as `<Kind>: <message>`."""

    def __init__(self, message: str, kind: str = "Error") -> None:
        super().__init__(message)
        self.message = message
        self.kind = kind

    def __str__(self) -> str:
        return f"{self.kind}: {self.message}"


@dataclass
class Flags:
    json: bool = False
    force: bool = False
    dry_run: bool = False
    scope: str | None = None


def out(text: str) -> None:
    print(text)


def err(text: str) -> None:
    print(text, file=sys.stderr)


def now_iso() -> str:
    stamp = datetime.now(UTC)
    return stamp.strftime("%Y-%m-%dT%H:%M:%S.") + f"{stamp.microsecond // 1000:03d}Z"


def dumps(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False)


def norm(path: Path | str) -> str:
    return os.path.realpath(path)


def inside(base: str, target: str) -> bool:
    rel = os.path.relpath(target, base)
    return not (rel == ".." or rel.startswith(".." + os.sep) or os.path.isabs(rel))


def valid_name(name: str) -> bool:
    return 0 < len(name) <= 64 and MARKETPLACE_NAME.match(name) is not None


def parse_plugin_id(value: str) -> tuple[str, str] | None:
    at = value.rfind("@")
    if at <= 0 or at == len(value) - 1:
        return None
    name, marketplace = value[:at], value[at + 1 :]
    if not valid_name(name) or not valid_name(marketplace):
        return None
    return name, marketplace


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def write_atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(dumps(value) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def read_json_file(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def coalesce(*values: Any) -> Any:
    for value in values:
        if value is not None:
            return value
    return None


def semver_newer(candidate: str, current: str) -> bool:
    a, b = SEMVER.match(candidate), SEMVER.match(current)
    if a is None or b is None:
        return candidate != current
    core_a = tuple(int(a.group(i)) for i in (1, 2, 3))
    core_b = tuple(int(b.group(i)) for i in (1, 2, 3))
    if core_a != core_b:
        return core_a > core_b
    pre_a: str | None = a.group(4)
    pre_b: str | None = b.group(4)
    if pre_a == pre_b:
        return False
    if pre_a is None or pre_b is None:
        return pre_a is None
    for x, y in zip(pre_a.split("."), pre_b.split("."), strict=False):
        if x == y:
            continue
        if x.isdigit() and y.isdigit():
            return int(x) > int(y)
        if x.isdigit() != y.isdigit():
            return not x.isdigit()
        return bool(x > y)
    return len(pre_a.split(".")) > len(pre_b.split("."))


def validate_catalog(text: str, display: str) -> JsonObj:
    def require(ok: bool, field: str) -> None:
        if not ok:
            raise OmpError(f'Missing or invalid field "{field}" in catalog: {display}')

    try:
        catalog = json.loads(text)
    except ValueError as exc:
        raise OmpError(f"Failed to parse marketplace catalog at {display}: {exc}") from exc
    if not isinstance(catalog, dict):
        raise OmpError(f"Marketplace catalog at {display} must be a JSON object")
    name = catalog.get("name")
    require(isinstance(name, str) and valid_name(name), "name")
    owner = catalog.get("owner")
    require(isinstance(owner, dict), "owner")
    assert isinstance(owner, dict)
    require(isinstance(owner.get("name"), str), "owner.name")
    plugins = catalog.get("plugins")
    require(isinstance(plugins, list), "plugins")
    assert isinstance(plugins, list)
    kept: list[Any] = []
    seen: set[str] = set()
    for plugin in plugins:
        if not isinstance(plugin, dict):
            continue
        plugin_name = plugin.get("name")
        if not isinstance(plugin_name, str) or not valid_name(plugin_name):
            continue
        source = plugin.get("source")
        if isinstance(source, str):
            if not source.startswith("./"):
                continue
        elif isinstance(source, dict) and isinstance(source.get("source"), str):
            variant = source["source"]
            if variant == "github" and not (isinstance(source.get("repo"), str) and source["repo"]):
                continue
            if variant in ("url", "git-subdir") and not (isinstance(source.get("url"), str) and source["url"]):
                continue
            if variant == "git-subdir" and not (isinstance(source.get("path"), str) and source["path"]):
                continue
            if variant == "npm" and not (isinstance(source.get("package"), str) and source["package"]):
                continue
            if variant not in ("github", "url", "git-subdir", "npm"):
                continue
        else:
            continue
        if plugin_name.lower() in seen:
            continue
        seen.add(plugin_name.lower())
        kept.append(plugin)
    catalog["plugins"] = kept
    return catalog


def source_type(source: str) -> str:
    if source.startswith(("https://", "http://")):
        path = re.sub(r"^https?://[^/]*", "", source).split("?", 1)[0].split("#", 1)[0]
        return "url" if path.endswith(".json") else "git"
    if source.startswith(("git@", "ssh://")):
        return "git"
    if GITHUB_SHORTHAND.match(source):
        return "github"
    if source.startswith(("./", "~/")) or os.path.isabs(source) or WINDOWS_PATH.match(source):
        return "local"
    raise OmpError(f"Unrecognized source format. Did you mean './{source}' (local) or 'owner/repo' (GitHub)?")


def find_catalog(directory: Path, relative_display: bool) -> tuple[str, str]:
    tried: list[str] = []
    skip = (CATALOG_FILES[0],) if os.environ.get("FAKE_OMP_CLAUDE_CATALOG") else ()
    for rel in CATALOG_FILES:
        if rel in skip:
            continue
        path = directory.joinpath(*rel.split("/"))
        tried.append(rel if relative_display else str(path))
        try:
            return path.read_text(encoding="utf-8"), (rel if relative_display else str(path))
        except (FileNotFoundError, NotADirectoryError):
            continue
    listed = " or ".join(f'"{p}"' for p in tried)
    raise OmpError(
        f"Marketplace catalog not found at {listed}. Ensure the directory exists and contains one of: "
        f"{', '.join(CATALOG_FILES)}."
    )


class Omp:
    """State roots and registries of one omp profile, seen from the current directory."""

    def __init__(self, profile: str | None) -> None:
        self.home = Path.home()
        self.root = Path(os.environ.get("FAKE_OMP_HOME") or self.home / ".fake-omp")
        self.config_root = self.root / "profiles" / profile if profile else self.root
        xdg_data = Path(os.environ.get("XDG_DATA_HOME") or self.home / ".local/share") / "omp"
        if profile:
            self.data_root = self.config_root
        elif xdg_data.is_dir():
            self.data_root = xdg_data
        else:
            self.data_root = self.root
        self.cwd = Path(os.getcwd())
        self.plugins_dir = self.data_root / "plugins"
        self.marketplaces_registry = self.data_root / "marketplaces.json"
        self.user_registry = self.plugins_dir / "installed_plugins.json"
        self.marketplaces_cache = self.plugins_dir / "cache" / "marketplaces"
        self.plugins_cache = self.plugins_dir / "cache" / "plugins"
        self.node_modules = self.plugins_dir / "node_modules"
        self.package_json = self.plugins_dir / "package.json"
        self.project_registry = self._project_registry()

    # -- project detection ---------------------------------------------------------------------

    def _stop_dirs(self) -> set[str]:
        tmp = os.environ.get("TMPDIR") or "/tmp"
        return {norm(self.home), norm(tmp), norm("/tmp"), norm("/var/tmp")}

    def _is_config_home(self, directory: Path) -> bool:
        target = norm(directory / ".omp")
        return target in {norm(self.home / ".omp"), norm(self.root), norm(self.data_root)}

    def _is_other_omp_home(self, directory: Path) -> bool:
        agent = directory / ".omp" / "agent"
        return agent.is_dir() and norm(agent) != norm(self.config_root / "agent")

    def _find_project(self, stops: set[str]) -> Path | None:
        git_first: Path | None = None
        git_root: Path | None = None
        current = self.cwd
        while norm(current) not in stops:
            if (current / ".git").exists():
                git_first = git_first or current
                if not self._is_config_home(current):
                    git_root = current
                    break
            if current.parent == current:
                break
            current = current.parent
        passed_git = git_first is None
        current = self.cwd
        while norm(current) not in stops:
            omp_dir = current / ".omp"
            if (
                omp_dir.is_dir()
                and not self._is_config_home(current)
                and (not passed_git or not self._is_other_omp_home(current))
            ):
                return omp_dir / "plugins" / "installed_plugins.json"
            if current == git_first:
                passed_git = True
            if current.parent == current:
                break
            current = current.parent
        return git_root / ".omp" / "plugins" / "installed_plugins.json" if git_root else None

    def _project_registry(self) -> Path | None:
        stops = self._stop_dirs()
        found = self._find_project(stops)
        if found:
            return found
        if norm(self.cwd) in stops or self._is_config_home(self.cwd) or self._is_other_omp_home(self.cwd):
            return None
        return self.cwd / ".omp" / "plugins" / "installed_plugins.json"

    # -- registries ----------------------------------------------------------------------------

    def read_marketplaces(self) -> JsonObj:
        try:
            data = read_json_file(self.marketplaces_registry)
        except FileNotFoundError:
            return {"version": 1, "marketplaces": []}
        except ValueError:
            return {"version": 1, "marketplaces": []}
        if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("marketplaces"), list):
            return {"version": 1, "marketplaces": []}
        return data

    def marketplace(self, name: str) -> JsonObj | None:
        for entry in self.read_marketplaces()["marketplaces"]:
            if isinstance(entry, dict) and entry.get("name") == name:
                return entry
        return None

    @staticmethod
    def read_installed(path: Path | None) -> JsonObj:
        if path is None:
            return {"version": 2, "plugins": {}}
        try:
            data = read_json_file(path)
        except FileNotFoundError:
            return {"version": 2, "plugins": {}}
        except ValueError:
            return {"version": 2, "plugins": {}}
        if (
            not isinstance(data, dict)
            or not isinstance(data.get("version"), int)
            or not isinstance(data.get("plugins"), dict)
        ):
            return {"version": 2, "plugins": {}}
        data["version"] = 2
        return data

    def registry_path(self, scope: str) -> Path:
        if scope == "project":
            if self.project_registry is None:
                raise OmpError("project-scoped install requires running inside a project directory")
            return self.project_registry
        return self.user_registry

    def scope_dir(self, scope: str) -> Path:
        return self.registry_path(scope).parent

    def lock_path(self, scope: str) -> Path:
        return self.scope_dir(scope) / "omp-plugins.lock.json"

    @staticmethod
    def read_lock(path: Path) -> JsonObj:
        try:
            data = read_json_file(path)
        except (FileNotFoundError, ValueError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        plugins = data.get("plugins")
        settings = data.get("settings")
        return {
            "plugins": plugins if isinstance(plugins, dict) else {},
            "settings": settings if isinstance(settings, dict) else {},
        }

    @staticmethod
    def write_lock(path: Path, lock: JsonObj) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(dumps(lock), encoding="utf-8")

    def scope_entries(self, plugin_id: str) -> tuple[list[JsonObj], list[JsonObj], JsonObj, JsonObj]:
        user = self.read_installed(self.user_registry)
        project = self.read_installed(self.project_registry)
        return list(user["plugins"].get(plugin_id) or []), list(project["plugins"].get(plugin_id) or []), user, project

    def list_installed(self) -> list[JsonObj]:
        user = self.read_installed(self.user_registry)
        project = self.read_installed(self.project_registry) if self.project_registry else None
        shadowing = set()
        items: list[JsonObj] = []
        if project is not None:
            for plugin_id, entries in project["plugins"].items():
                if entries and entries[0].get("enabled") is not False:
                    shadowing.add(plugin_id)
                items.append({"id": plugin_id, "scope": "project", "entries": entries})
        for plugin_id, entries in user["plugins"].items():
            item: JsonObj = {"id": plugin_id, "scope": "user", "entries": entries}
            if plugin_id in shadowing:
                item["shadowedBy"] = "project"
            items.append(item)
        return items

    # -- marketplaces --------------------------------------------------------------------------

    def _clone(self, url: str, display: str) -> tuple[JsonObj, Path]:
        stamp = int(time.time() * 1000)
        clone = self.marketplaces_cache / f".tmp-clone-{stamp}"
        repo = os.environ.get("FAKE_OMP_REPO_CATALOG")
        if not repo or not Path(repo).is_dir():
            raise OmpError(
                f"Cloning into '{clone}'...\nfatal: repository '{url}' not found"
                " (fake omp: FAKE_OMP_REPO_CATALOG unset)",
                kind="VcsError",
            )
        self.marketplaces_cache.mkdir(parents=True, exist_ok=True)
        shutil.copytree(repo, clone, symlinks=True, ignore=shutil.ignore_patterns(".git"))
        try:
            text, display_path = find_catalog(clone, relative_display=True)
            return validate_catalog(text, display_path), clone
        except OmpError as exc:
            shutil.rmtree(clone, ignore_errors=True)
            raise OmpError(f"Cloned repository {url}: {exc.message} (source: {display})") from exc

    def fetch_catalog(self, source: str) -> tuple[JsonObj, Path | None]:
        kind = source_type(source)
        if kind == "local":
            directory = Path(os.path.abspath(os.path.expanduser(source) if source.startswith("~/") else source))
            text, display = find_catalog(directory, relative_display=False)
            return validate_catalog(text, display), None
        if kind == "github":
            return self._clone(f"https://github.com/{source}.git", source)
        if kind == "git":
            return self._clone(source, source)
        raise OmpError(f"Failed to fetch marketplace catalog from {source}: HTTP 404 Not Found")

    def _adopt_clone(self, clone: Path, name: str) -> None:
        target = self.marketplaces_cache / name
        remove_path(target)
        os.replace(clone, target)

    def add_marketplace(self, source: str) -> None:
        registry = self.read_marketplaces()
        catalog, clone = self.fetch_catalog(source)
        name = str(catalog["name"])
        clash = next(
            (m["name"] for m in registry["marketplaces"] if str(m.get("name", "")).lower() == name.lower()), None
        )
        if clash is not None:
            if clone is not None:
                shutil.rmtree(clone, ignore_errors=True)
            if clash == name:
                raise OmpError(f'Marketplace "{name}" already exists')
            raise OmpError(
                f'Marketplace "{name}" conflicts with existing marketplace "{clash}" on case-insensitive filesystems'
            )
        if clone is not None:
            self._adopt_clone(clone, name)
        kind = source_type(source)
        source_uri = os.path.abspath(os.path.expanduser(source)) if kind == "local" else source
        catalog_path = Path(os.path.abspath(self.marketplaces_cache / name / "marketplace.json"))
        catalog_path.parent.mkdir(parents=True, exist_ok=True)
        catalog_path.write_text(dumps(catalog) + "\n", encoding="utf-8")
        stamp = now_iso()
        registry["marketplaces"] = [
            *registry["marketplaces"],
            {
                "name": name,
                "sourceType": kind,
                "sourceUri": source_uri,
                "catalogPath": str(catalog_path),
                "addedAt": stamp,
                "updatedAt": stamp,
            },
        ]
        write_atomic(self.marketplaces_registry, registry)

    def remove_marketplace(self, name: str) -> None:
        registry = self.read_marketplaces()
        kept = [m for m in registry["marketplaces"] if m.get("name") != name]
        if len(kept) == len(registry["marketplaces"]):
            raise OmpError(f'Marketplace "{name}" not found')
        registry["marketplaces"] = kept
        write_atomic(self.marketplaces_registry, registry)
        remove_path(self.marketplaces_cache / name)

    def update_marketplace(self, name: str) -> None:
        registry = self.read_marketplaces()
        entry = next((m for m in registry["marketplaces"] if m.get("name") == name), None)
        if entry is None:
            raise OmpError(f'Marketplace "{name}" not found')
        catalog, clone = self.fetch_catalog(str(entry["sourceUri"]))
        if catalog["name"] != name:
            if clone is not None:
                shutil.rmtree(clone, ignore_errors=True)
            raise OmpError(
                f'Marketplace catalog name changed from "{name}" to "{catalog["name"]}". '
                "Remove and re-add the marketplace to update."
            )
        if clone is not None:
            self._adopt_clone(clone, name)
        catalog_path = Path(os.path.abspath(str(entry["catalogPath"])))
        catalog_path.parent.mkdir(parents=True, exist_ok=True)
        catalog_path.write_text(dumps(catalog) + "\n", encoding="utf-8")
        updated = {**entry, "catalogPath": str(catalog_path), "updatedAt": now_iso()}
        registry["marketplaces"] = [updated if m.get("name") == name else m for m in registry["marketplaces"]]
        write_atomic(self.marketplaces_registry, registry)

    def read_catalog(self, entry: JsonObj) -> JsonObj:
        path = os.path.abspath(str(entry["catalogPath"]))
        try:
            text = Path(path).read_text(encoding="utf-8")
        except FileNotFoundError as exc:
            raise OmpError(
                f"Marketplace catalog not found at {path}. Try: /marketplace update {entry['name']}"
            ) from exc
        return validate_catalog(text, path)

    def available_plugins(self, name: str | None) -> list[JsonObj]:
        registry = self.read_marketplaces()
        if name is not None:
            entry = next((m for m in registry["marketplaces"] if m.get("name") == name), None)
            if entry is None:
                raise OmpError(f'Marketplace "{name}" not found')
            return list(self.read_catalog(entry)["plugins"])
        plugins: list[JsonObj] = []
        for entry in registry["marketplaces"]:
            plugins.extend(self.read_catalog(entry)["plugins"])
        return plugins

    # -- plugin sources ------------------------------------------------------------------------

    @staticmethod
    def clone_root(entry: JsonObj) -> str:
        if entry.get("sourceType") == "local":
            return os.path.abspath(os.path.expanduser(str(entry["sourceUri"])))
        return os.path.dirname(os.path.abspath(str(entry["catalogPath"])))

    @staticmethod
    def relative_source(source: str, clone: str, metadata: Any) -> str:
        if not source.startswith("./"):
            raise OmpError(f'Relative plugin source paths must start with "./" \u2014 got: "{source}"')
        plugin_root = metadata.get("pluginRoot") if isinstance(metadata, dict) else None
        rel = "./" + posixpath.join(str(plugin_root), source[2:]) if plugin_root else source
        resolved = os.path.normpath(os.path.join(clone, rel))
        if not inside(clone, resolved):
            raise OmpError(f'Plugin source "{source}" resolves outside marketplace root ("{clone}")')
        return resolved

    def source_dir(self, plugin: JsonObj, clone: str, catalog: JsonObj, *, for_install: bool) -> Path | None:
        source = plugin.get("source")
        if isinstance(source, str):
            resolved = self.relative_source(source, clone, catalog.get("metadata"))
            if not os.path.isdir(resolved):
                raise OmpError(f'Plugin source directory does not exist: "{resolved}"')
            return Path(resolved)
        variant = source.get("source") if isinstance(source, dict) else None
        if variant == "npm":
            raise OmpError("npm plugin sources are not yet supported. Use git-based sources instead.")
        if for_install:
            raise OmpError(f'fake omp: only relative plugin sources are supported (got "{variant}")')
        return None

    @staticmethod
    def plugin_version(plugin: JsonObj, directory: Path | None) -> str | None:
        declared = plugin.get("version")
        if not isinstance(plugin.get("source"), str) and declared:
            return str(declared)
        if directory is None:
            return None

        def read(rel: str) -> str | None:
            try:
                data = read_json_file(directory / rel)
            except (OSError, ValueError):
                return None
            version = data.get("version") if isinstance(data, dict) else None
            return version if isinstance(version, str) and version else None

        found = read(".claude-plugin/plugin.json") or read("plugin.json")
        if found:
            return found
        if declared:
            return str(declared)
        return read("package.json")

    @staticmethod
    def runtime_name(directory: Path, fallback: str) -> str:
        try:
            data = read_json_file(directory / "package.json")
        except (FileNotFoundError, NotADirectoryError):
            data = None
        name = data.get("name") if isinstance(data, dict) else None
        chosen = name if isinstance(name, str) and name else fallback
        if len(chosen) > 214 or not PACKAGE_NAME.match(chosen):
            raise OmpError(f"Invalid marketplace plugin package name: {json.dumps(chosen)}")
        return chosen

    def runtime_path(self, scope: str, name: str) -> Path:
        base = os.path.abspath(self.scope_dir(scope) / "node_modules")
        target = os.path.abspath(os.path.join(base, name))
        rel = os.path.relpath(target, base)
        if rel in ("", ".") or rel.startswith("..") or os.path.isabs(rel):
            raise OmpError(f"Marketplace plugin package path escapes node_modules: {json.dumps(name)}")
        return Path(target)

    def remove_runtime(self, scope: str, name: str) -> tuple[Any, Any]:
        remove_path(self.runtime_path(scope, name))
        lock_path = self.lock_path(scope)
        lock = self.read_lock(lock_path)
        state = lock["plugins"].pop(name, None)
        settings = lock["settings"].pop(name, None)
        self.write_lock(lock_path, lock)
        return state, settings

    def link_runtime(
        self, scope: str, name: str, target: Path, version: str, enabled: bool | None, prior: tuple[Any, Any] | None
    ) -> None:
        link = self.runtime_path(scope, name)
        if not os.environ.get("FAKE_OMP_NO_NODE_MODULES"):
            link.parent.mkdir(parents=True, exist_ok=True)
            remove_path(link)
            os.symlink(target, link, target_is_directory=True)
        lock_path = self.lock_path(scope)
        lock = self.read_lock(lock_path)
        previous = lock["plugins"].get(name)
        previous = previous if isinstance(previous, dict) else {}
        prior_state = prior[0] if prior and isinstance(prior[0], dict) else {}
        lock["plugins"][name] = {
            "version": version,
            "enabledFeatures": coalesce(previous.get("enabledFeatures"), prior_state.get("enabledFeatures")),
            "enabled": coalesce(enabled, previous.get("enabled"), prior_state.get("enabled"), True),
        }
        if prior is not None and prior[1] is not None and name not in lock["settings"]:
            lock["settings"][name] = prior[1]
        self.write_lock(lock_path, lock)

    # -- marketplace installs ------------------------------------------------------------------

    def _prepare_install(self, name: str, marketplace: str, force: bool, scope: str | None) -> JsonObj:
        chosen = scope or "user"
        registry_path = self.registry_path(chosen)
        entry = self.marketplace(marketplace)
        if entry is None:
            raise OmpError(f'Marketplace "{marketplace}" not found')
        catalog = self.read_catalog(entry)
        plugin = next((p for p in catalog["plugins"] if p.get("name") == name), None)
        if plugin is None:
            raise OmpError(f'Plugin "{name}" not found in marketplace "{marketplace}"')
        version = plugin.get("version")
        if isinstance(version, str) and version and not self.cache_version_ok(version):
            raise OmpError(f'Invalid version for cache: "{version}"')
        clone = self.clone_root(entry)
        if entry.get("sourceType") == "url" and isinstance(plugin.get("source"), str):
            raise OmpError(
                f'Plugin "{name}" uses a relative source path but marketplace "{marketplace}" was added via URL. '
                "Relative sources require a git or local marketplace. Re-add the marketplace using its git URL."
            )
        directory = self.source_dir(plugin, clone, catalog, for_install=False)
        if directory is not None:
            for field in ("lspServers", "dapAdapters"):
                ref = plugin.get(field)
                if isinstance(ref, str) and ref:
                    resolved = os.path.normpath(os.path.join(directory, ref))
                    if not inside(str(directory), resolved):
                        raise OmpError(f'Plugin "{name}" {field} path escapes the plugin directory')
                    if not os.path.isfile(resolved):
                        raise OmpError(f'Plugin "{name}" {field} file does not exist')
        if not valid_name(name):
            raise OmpError(f'Invalid plugin name: "{name}"')
        plugin_id = f"{name}@{marketplace}"
        existing = self.read_installed(registry_path)["plugins"].get(plugin_id)
        if existing and not force:
            raise OmpError(f'Plugin "{plugin_id}" is already installed. Use force option to reinstall.')
        return {
            "scope": chosen,
            "registry": registry_path,
            "catalog": catalog,
            "clone": clone,
            "plugin": plugin,
            "id": plugin_id,
            "existing": list(existing or []),
        }

    @staticmethod
    def cache_version_ok(version: str) -> bool:
        return 0 < len(version) <= 128 and CACHE_VERSION.match(version) is not None and ".." not in version

    def validate_install(self, name: str, marketplace: str, force: bool, scope: str | None) -> None:
        self._prepare_install(name, marketplace, force, scope)

    def _check_runtime_conflict(
        self, scope: str, runtime: str, registry: JsonObj, plugin_id: str, owned: list[str]
    ) -> None:
        lowered = runtime.lower()
        for other_id, entries in registry["plugins"].items():
            if other_id == plugin_id:
                continue
            parsed = parse_plugin_id(other_id)
            fallback = parsed[0] if parsed else other_id
            for entry in entries:
                if self.runtime_name(Path(entry["installPath"]), fallback).lower() == lowered:
                    raise OmpError(f'Runtime package name "{runtime}" conflicts with installed plugin "{other_id}"')
        owned_lower = {name.lower() for name in owned}
        names: list[str] = []
        try:
            package = read_json_file(self.scope_dir(scope) / "package.json")
        except FileNotFoundError:
            package = {}
        deps = package.get("dependencies") if isinstance(package, dict) else None
        if isinstance(deps, dict):
            names.extend(deps)
        names.extend(self.read_lock(self.lock_path(scope))["plugins"])
        for name in names:
            if name.lower() == lowered and lowered not in owned_lower:
                raise OmpError(f'Runtime package name "{runtime}" conflicts with installed package "{name}"')

    def _copy_to_cache(self, source: Path, marketplace: str, name: str, version: str) -> Path:
        if not valid_name(marketplace):
            raise OmpError(f'Invalid marketplace name for cache: "{marketplace}"')
        if not valid_name(name):
            raise OmpError(f'Invalid plugin name for cache: "{name}"')
        if not self.cache_version_ok(version):
            raise OmpError(f'Invalid version for cache: "{version}"')
        target = self.plugins_cache / f"{marketplace}___{name}___{version}"
        self.plugins_cache.mkdir(parents=True, exist_ok=True)
        staging = target.with_name(f"{target.name}.staging-{int(time.time() * 1000)}")
        try:
            shutil.copytree(source, staging, symlinks=True)
            remove_path(target)
            os.replace(staging, target)
        except OSError:
            shutil.rmtree(staging, ignore_errors=True)
            raise
        return target

    @staticmethod
    def _write_tool_configs(plugin: JsonObj, cache: Path) -> None:
        lsp = plugin.get("lspServers")
        if isinstance(lsp, str):
            (cache / ".lsp.json").write_text((cache / lsp).read_text(encoding="utf-8"), encoding="utf-8")
        elif lsp:
            (cache / ".lsp.json").write_text(dumps({"servers": lsp}) + "\n", encoding="utf-8")
        dap = plugin.get("dapAdapters")
        if isinstance(dap, str):
            suffix = Path(dap).suffix.lower()
            target = f".dap{suffix}" if suffix in (".yaml", ".yml") else ".dap.json"
            (cache / target).write_text((cache / dap).read_text(encoding="utf-8"), encoding="utf-8")
        elif dap:
            (cache / ".dap.json").write_text(dumps({"adapters": dap}) + "\n", encoding="utf-8")

    def install_plugin(self, name: str, marketplace: str, force: bool, scope: str | None) -> JsonObj:
        prep = self._prepare_install(name, marketplace, force, scope)
        chosen: str = prep["scope"]
        registry_path: Path = prep["registry"]
        plugin: JsonObj = prep["plugin"]
        plugin_id: str = prep["id"]
        existing: list[JsonObj] = prep["existing"]
        source = self.source_dir(plugin, prep["clone"], prep["catalog"], for_install=True)
        assert source is not None
        other = "project" if chosen == "user" else "user"
        other_path = self.project_registry if other == "project" else self.user_registry
        other_entries = list(self.read_installed(other_path)["plugins"].get(plugin_id) or []) if other_path else []
        other_names = {str(e["installPath"]): self.runtime_name(Path(e["installPath"]), name) for e in other_entries}
        version = self.plugin_version(plugin, source) or "0.0.0"
        runtime = self.runtime_name(source, name)
        owned = list(dict.fromkeys(self.runtime_name(Path(e["installPath"]), name) for e in existing))
        registry = self.read_installed(registry_path)
        self._check_runtime_conflict(chosen, runtime, registry, plugin_id, owned)
        cache_target = str(self.plugins_cache / f"{marketplace}___{name}___{version}").lower()
        registries = [registry]
        if other_path and other_path != registry_path:
            registries.append(self.read_installed(other_path))
        for reg in registries:
            for other_id, entries in reg["plugins"].items():
                if other_id == plugin_id:
                    continue
                for entry in entries:
                    if str(entry["installPath"]).lower() == cache_target:
                        raise OmpError(
                            f'Plugin cache path for "{plugin_id}" case-collides with installed plugin "{other_id}" '
                            f'on case-insensitive filesystems. Uninstall "{other_id}" first.'
                        )
        cache = self._copy_to_cache(source, marketplace, name, version)
        self._write_tool_configs(plugin, cache)
        if existing:
            current = self.read_installed(registry_path)
            if plugin_id not in current["plugins"]:
                raise OmpError(f'Plugin "{plugin_id}" not found in registry')
            del current["plugins"][plugin_id]
            write_atomic(registry_path, current)
            referenced = self._referenced_paths()
            for entry in existing:
                path = str(entry["installPath"])
                if path != str(cache) and path not in referenced:
                    remove_path(Path(path))
        stamp = now_iso()
        disabled = any(e.get("enabled") is False for e in existing)
        record: JsonObj = {
            "scope": chosen,
            "installPath": str(cache),
            "version": version,
            "installedAt": stamp,
            "lastUpdated": stamp,
        }
        if disabled:
            record["enabled"] = False
        current = self.read_installed(registry_path)
        current["plugins"][plugin_id] = [*(current["plugins"].get(plugin_id) or []), record]
        write_atomic(registry_path, current)
        prior: tuple[Any, Any] | None = None
        for old in owned:
            if old != runtime:
                removed = self.remove_runtime(chosen, old)
                prior = prior or removed
        self.link_runtime(chosen, runtime, cache, version, False if disabled else None, prior)
        for entry in other_entries:
            if str(entry["installPath"]) != str(cache):
                continue
            other_runtime = other_names.get(str(entry["installPath"]))
            if other_runtime is None or other_runtime == runtime:
                continue
            removed = self.remove_runtime(other, other_runtime)
            self.link_runtime(
                other, runtime, cache, str(entry["version"]), False if entry.get("enabled") is False else None, removed
            )
        return record

    def _referenced_paths(self) -> set[str]:
        paths: set[str] = set()
        for registry in (self.read_installed(self.user_registry), self.read_installed(self.project_registry)):
            for entries in registry["plugins"].values():
                paths.update(str(e["installPath"]) for e in entries)
        return paths

    def _pick_scope(
        self, plugin_id: str, scope: str | None, verb: str
    ) -> tuple[str, list[JsonObj], list[JsonObj], JsonObj, JsonObj]:
        user_entries, project_entries, user, project = self.scope_entries(plugin_id)
        if not user_entries and not project_entries:
            raise OmpError(f'Plugin "{plugin_id}" is not installed')
        if user_entries and project_entries:
            if not scope:
                raise OmpError(
                    f'Plugin "{plugin_id}" is installed in both user and project scope. '
                    f"Use --scope user or --scope project to specify which to {verb}."
                )
            chosen = scope
        elif project_entries:
            if scope == "user":
                raise OmpError(f'Plugin "{plugin_id}" is not installed in user scope')
            chosen = "project"
        else:
            if scope == "project":
                raise OmpError(f'Plugin "{plugin_id}" is not installed in project scope')
            chosen = "user"
        return chosen, user_entries, project_entries, user, project

    def uninstall_plugin(self, plugin_id: str, scope: str | None, dry_run: bool) -> None:
        parsed = parse_plugin_id(plugin_id)
        if parsed is None:
            raise OmpError(f'Invalid plugin ID format: "{plugin_id}". Expected "name@marketplace".')
        chosen, user_entries, project_entries, user, project = self._pick_scope(plugin_id, scope, "remove")
        entries = project_entries if chosen == "project" else user_entries
        registry = project if chosen == "project" else user
        registry_path = self.registry_path(chosen)
        names = list(dict.fromkeys(self.runtime_name(Path(e["installPath"]), parsed[0]) for e in entries))
        if dry_run:
            return
        del registry["plugins"][plugin_id]
        write_atomic(registry_path, registry)
        referenced = self._referenced_paths()
        for entry in entries:
            if str(entry["installPath"]) not in referenced:
                remove_path(Path(entry["installPath"]))
        for name in names:
            self.remove_runtime(chosen, name)

    def set_plugin_enabled(self, plugin_id: str, enabled: bool, scope: str | None) -> None:
        chosen, user_entries, project_entries, user, project = self._pick_scope(plugin_id, scope, "modify")
        registry = project if chosen == "project" else user
        entries = project_entries if chosen == "project" else user_entries
        registry["plugins"][plugin_id] = [{**e, "enabled": enabled} for e in entries]
        write_atomic(self.registry_path(chosen), registry)
        parsed = parse_plugin_id(plugin_id)
        fallback = parsed[0] if parsed else plugin_id
        lock_path = self.lock_path(chosen)
        for name in dict.fromkeys(self.runtime_name(Path(e["installPath"]), fallback) for e in entries):
            lock = self.read_lock(lock_path)
            state = lock["plugins"].get(name)
            if isinstance(state, dict):
                state["enabled"] = enabled
                self.write_lock(lock_path, lock)

    def upgrade_plugin(self, plugin_id: str, scope: str | None) -> JsonObj:
        parsed = parse_plugin_id(plugin_id)
        if parsed is None:
            raise OmpError(f'Invalid plugin ID: "{plugin_id}". Expected "name@marketplace".')
        chosen = self._pick_scope(plugin_id, scope, "upgrade")[0]
        return self.install_plugin(parsed[0], parsed[1], True, chosen)

    def upgrade_across_scopes(self, plugin_id: str) -> list[JsonObj]:
        parsed = parse_plugin_id(plugin_id)
        if parsed is None:
            raise OmpError(f'Invalid plugin ID: "{plugin_id}". Expected "name@marketplace".')
        user_entries, project_entries, _, _ = self.scope_entries(plugin_id)
        if not user_entries and not project_entries:
            raise OmpError(f'Plugin "{plugin_id}" is not installed')
        results: list[JsonObj] = []
        if project_entries:
            results.append(self.install_plugin(parsed[0], parsed[1], True, "project"))
        if user_entries:
            results.append(self.install_plugin(parsed[0], parsed[1], True, "user"))
        return results

    def check_for_updates(self) -> list[JsonObj]:
        registry = self.read_marketplaces()
        updates: list[JsonObj] = []
        scopes: list[tuple[Path, str]] = [(self.user_registry, "user")]
        if self.project_registry:
            scopes.append((self.project_registry, "project"))
        for path, scope in scopes:
            for plugin_id, entries in self.read_installed(path)["plugins"].items():
                parsed = parse_plugin_id(plugin_id)
                if parsed is None or not entries:
                    continue
                current = entries[0]
                entry = next((m for m in registry["marketplaces"] if m.get("name") == parsed[1]), None)
                if entry is None:
                    continue
                try:
                    catalog = self.read_catalog(entry)
                    plugin = next((p for p in catalog["plugins"] if p.get("name") == parsed[0]), None)
                    if plugin is None:
                        continue
                    directory = self.source_dir(plugin, self.clone_root(entry), catalog, for_install=False)
                    latest = self.plugin_version(plugin, directory)
                except (OmpError, OSError):
                    continue
                if not latest or latest == current.get("version"):
                    continue
                if semver_newer(latest, str(current.get("version"))):
                    updates.append(
                        {"pluginId": plugin_id, "scope": scope, "from": current.get("version"), "to": latest}
                    )
        return updates

    def upgrade_all(self) -> list[JsonObj]:
        done: list[JsonObj] = []
        for update in self.check_for_updates():
            try:
                record = self.upgrade_plugin(update["pluginId"], update["scope"])
            except (OmpError, OSError):
                continue
            done.append({**update, "to": record["version"]})
        return done

    # -- npm (linked) plugins ------------------------------------------------------------------

    def ensure_package_json(self) -> None:
        if not self.package_json.exists():
            self.package_json.parent.mkdir(parents=True, exist_ok=True)
            self.package_json.write_text(
                dumps({"name": "omp-plugins", "private": True, "dependencies": {}}), encoding="utf-8"
            )

    def npm_dependencies(self) -> JsonObj:
        try:
            data = read_json_file(self.package_json)
        except FileNotFoundError:
            return {}
        deps = data.get("dependencies") if isinstance(data, dict) else None
        return deps if isinstance(deps, dict) else {}

    def _marketplace_runtime_paths(self) -> dict[str, set[str]]:
        mapping: dict[str, set[str]] = {}
        for plugin_id, entries in self.read_installed(self.user_registry)["plugins"].items():
            for entry in entries:
                if (entry.get("scope") or "user") != "user":
                    continue
                parsed = parse_plugin_id(plugin_id)
                name = parsed[0] if parsed else plugin_id
                try:
                    package = read_json_file(Path(entry["installPath"]) / "package.json")
                    if isinstance(package, dict) and isinstance(package.get("name"), str) and package["name"]:
                        name = package["name"]
                except (FileNotFoundError, NotADirectoryError):
                    pass
                except ValueError:
                    continue
                if os.path.exists(entry["installPath"]):
                    mapping.setdefault(name, set()).add(norm(entry["installPath"]))
        return mapping

    def _is_marketplace_link(self, name: str, deps: JsonObj, mapping: dict[str, set[str]], path: Path) -> bool:
        if name in deps or name not in mapping:
            return False
        return path.exists() and norm(path) in mapping[name]

    def _npm_entry(self, key: str, path: Path, lock: JsonObj) -> JsonObj | None:
        try:
            package = read_json_file(path / "package.json")
        except (FileNotFoundError, NotADirectoryError):
            return None
        if not isinstance(package, dict):
            return None
        name = package["name"] if isinstance(package.get("name"), str) and package["name"] else key
        manifest_src = package.get("omp") or package.get("pi")
        manifest: JsonObj = dict(manifest_src) if isinstance(manifest_src, dict) else {}
        if "version" in package:
            manifest["version"] = package["version"]
        else:
            manifest.pop("version", None)
        state = lock["plugins"].get(name)
        if not isinstance(state, dict):
            state = {"version": package.get("version"), "enabledFeatures": None, "enabled": True}
        item: JsonObj = {"name": name}
        if "version" in package:
            item["version"] = package["version"]
        item.update(
            {
                "path": str(path),
                "manifest": manifest,
                "enabledFeatures": state.get("enabledFeatures"),
                "enabled": state.get("enabled"),
            }
        )
        return item

    def npm_names(self) -> tuple[JsonObj, JsonObj, list[str]]:
        deps = self.npm_dependencies()
        lock = self.read_lock(self.plugins_dir / "omp-plugins.lock.json")
        return deps, lock, list(dict.fromkeys([*deps, *lock["plugins"]]))

    def npm_list(self) -> list[JsonObj]:
        deps, lock, names = self.npm_names()
        mapping = self._marketplace_runtime_paths()
        items: list[JsonObj] = []
        for name in names:
            path = self.node_modules / name
            if self._is_marketplace_link(name, deps, mapping, path):
                continue
            item = self._npm_entry(name, path, lock)
            if item is not None:
                items.append(item)
        return items

    def link(self, target: str) -> JsonObj:
        directory = Path(os.path.abspath(os.path.join(self.cwd, target)))
        try:
            package = read_json_file(directory / "package.json")
        except (FileNotFoundError, NotADirectoryError) as exc:
            raise OmpError(f"package.json not found at {directory}") from exc
        name = package.get("name") if isinstance(package, dict) else None
        if not name:
            raise OmpError("package.json must have a name field")
        name = str(name)
        self.plugins_dir.mkdir(parents=True, exist_ok=True)
        self.node_modules.mkdir(parents=True, exist_ok=True)
        link = self.node_modules / name
        if name.startswith("@"):
            (self.node_modules / name.split("/")[0]).mkdir(parents=True, exist_ok=True)
        remove_path(link)
        os.symlink(directory, link, target_is_directory=True)
        lock_path = self.plugins_dir / "omp-plugins.lock.json"
        lock = self.read_lock(lock_path)
        lock["plugins"][name] = {"version": package.get("version"), "enabledFeatures": None, "enabled": True}
        self.write_lock(lock_path, lock)
        manifest_src = package.get("omp") or package.get("pi")
        manifest: JsonObj = dict(manifest_src) if isinstance(manifest_src, dict) else {}
        manifest["version"] = package.get("version")
        return {
            "name": name,
            "version": package.get("version"),
            "path": str(directory),
            "manifest": manifest,
            "enabledFeatures": None,
            "enabled": True,
        }

    def npm_uninstall(self, name: str) -> None:
        self.ensure_package_json()
        remove_path(self.node_modules / name)
        lock_path = self.plugins_dir / "omp-plugins.lock.json"
        lock = self.read_lock(lock_path)
        lock["plugins"].pop(name, None)
        lock["settings"].pop(name, None)
        self.write_lock(lock_path, lock)

    def npm_set_enabled(self, name: str, enabled: bool) -> None:
        lock_path = self.plugins_dir / "omp-plugins.lock.json"
        lock = self.read_lock(lock_path)
        state = lock["plugins"].get(name)
        if not isinstance(state, dict):
            raise OmpError(f"Plugin {name} not found in runtime config")
        state["enabled"] = enabled
        self.write_lock(lock_path, lock)

    def doctor(self) -> list[JsonObj]:
        checks: list[JsonObj] = []
        found_dir = self.plugins_dir.exists()
        checks.append(
            {
                "name": "plugins_directory",
                "status": "ok" if found_dir else "warning",
                "message": f"Found at {self.plugins_dir}" if found_dir else "Not created yet",
            }
        )
        has_manifest = self.package_json.exists()
        checks.append(
            {
                "name": "package_manifest",
                "status": "ok" if has_manifest else "warning",
                "message": "Found" if has_manifest else "Not created yet",
            }
        )
        has_modules = self.node_modules.exists()
        checks.append(
            {
                "name": "node_modules",
                "status": "ok" if has_modules else ("error" if has_manifest else "warning"),
                "message": "Found" if has_modules else "Missing (run npm install in plugins dir)",
            }
        )
        deps, lock, names = self.npm_names()
        mapping = self._marketplace_runtime_paths()
        for name in names:
            path = self.node_modules / name
            if self._is_marketplace_link(name, deps, mapping, path):
                continue
            declared = name in deps
            try:
                package = read_json_file(path / "package.json")
            except (FileNotFoundError, NotADirectoryError):
                if not path.exists():
                    if declared:
                        checks.append(
                            {
                                "name": f"plugin:{name}",
                                "status": "error",
                                "message": "Missing from node_modules",
                                "fixed": False,
                            }
                        )
                    else:
                        checks.append(
                            {
                                "name": f"orphan:{name}",
                                "status": "warning",
                                "message": "Plugin in config but not installed",
                                "fixed": False,
                            }
                        )
                else:
                    checks.append({"name": f"plugin:{name}", "status": "error", "message": "Missing package.json"})
                continue
            if not isinstance(package, dict):
                package = {}
            version = package.get("version")
            shown = "undefined" if version is None else str(version)
            state = lock["plugins"].get(name)
            locked = state.get("version") if isinstance(state, dict) else None
            if declared and locked and version and locked != version:
                checks.append(
                    {
                        "name": f"plugin:{name}:version",
                        "status": "error",
                        "message": f"Version drift: lock records v{locked} but node_modules has v{version} "
                        f"(run `omp plugin install {name} --force`)",
                        "fixed": False,
                    }
                )
            manifest = package.get("omp") or package.get("pi")
            if manifest:
                description = package.get("description")
                message = f"v{shown}" + (f" - {description}" if description else "")
            else:
                message = f"v{shown} - No omp/pi manifest (not an omp plugin)"
            checks.append({"name": f"plugin:{name}", "status": "ok" if manifest else "warning", "message": message})
            if not isinstance(manifest, dict):
                continue
            for key in ("tools", "hooks"):
                entry = manifest.get(key)
                if entry and not (path / str(entry)).exists():
                    checks.append(
                        {
                            "name": f"plugin:{name}:{key}",
                            "status": "error",
                            "message": f'{key.capitalize()} entry "{entry}" not found',
                        }
                    )
            for extension in manifest.get("extensions") or []:
                if not (path / str(extension)).exists():
                    checks.append(
                        {
                            "name": f"plugin:{name}:extension:{extension}",
                            "status": "error",
                            "message": f'Extension entry "{extension}" not found',
                        }
                    )
            features = manifest.get("features")
            enabled_features = state.get("enabledFeatures") if isinstance(state, dict) else None
            if enabled_features and isinstance(features, dict):
                for feature in enabled_features:
                    if feature not in features:
                        checks.append(
                            {
                                "name": f"plugin:{name}:feature:{feature}",
                                "status": "warning",
                                "message": f'Enabled feature "{feature}" not in manifest',
                                "fixed": False,
                            }
                        )
        return checks


# -- CLI -----------------------------------------------------------------------------------------


def classify_target(target: str, marketplaces: set[str]) -> tuple[str, str, str]:
    """(kind, name, marketplace) per omp's classify-install-target: local | npm | marketplace."""
    if target in (".", "..", "~") or target.startswith(("./", "../", ".\\", "..\\", "~/", "~\\", "/", "\\\\")):
        return "local", target, ""
    if re.match(r"^[A-Za-z]:[\\/]", target):
        return "local", target, ""
    if target.startswith("@"):
        return "npm", target, ""
    at = target.rfind("@")
    if at > 0:
        suffix = target[at + 1 :]
        if suffix in DIST_TAGS or re.match(r"^[\d~^>=<]", suffix):
            return "npm", target, ""
        if suffix in marketplaces:
            return "marketplace", target[:at], suffix
    return "npm", target, ""


def bun_install_failure(spec: str) -> str:
    """bun's resolver error for a spec that is not a registered marketplace (the real npm lookup is not emulated:
    every `name@tag` is reported as an existing package without that tag, every bare name as a 404)."""
    package = re.sub(r"^npm:", "", spec, flags=re.IGNORECASE)
    package = re.sub(r"\[[^\]]*\]$", "", package)
    at = package.rfind("@")
    if at > 0:
        name, tag = package[:at], package[at + 1 :]
        shown = name if name == tag else package
        return (
            "bun install failed: Resolving dependencies\nResolved, downloaded and extracted [2]\n"
            f'error: Package "{name}" with tag "{tag}" not found, but package exists\n'
            f"error: {shown} failed to resolve\n"
        )
    return (
        "bun install failed: Resolving dependencies\nResolved, downloaded and extracted [1]\n"
        f"error: GET https://registry.npmjs.org/{package} - 404\n"
    )


def cmd_install(omp: Omp, targets: list[str], flags: Flags) -> int:
    if not targets:
        err("Usage: omp plugin install <source>[features] ...")
        err("Examples:")
        err("  omp plugin install @oh-my-pi/exa")
        err("  omp plugin install name@marketplace")
        err("  omp plugin install github:user/repo")
        err("  omp plugin install https://github.com/user/repo#v1.0")
        err("  omp plugin install ./path/to/local/plugin")
        return 1
    marketplaces = {str(m.get("name")) for m in omp.read_marketplaces()["marketplaces"]}
    for target in targets:
        kind, name, marketplace = classify_target(target, marketplaces)
        if kind == "marketplace":
            try:
                if flags.dry_run:
                    omp.validate_install(name, marketplace, flags.force, flags.scope)
                    if flags.json:
                        out(dumps({"dryRun": True, "action": "install", "plugin": name, "marketplace": marketplace}))
                    else:
                        out(f"[dry-run] Would install {target}")
                    continue
            except (OmpError, OSError) as exc:
                err(f"✘ Failed to install {target}: {exc}")
                return 1
            try:
                record = omp.install_plugin(name, marketplace, flags.force, flags.scope)
            except (OmpError, OSError) as exc:
                err(f"✘ Failed to install {target}: {exc}")
                return 1
            out(f"✔ Installed {name} from {marketplace} ({record['version']})")
            continue
        if kind == "local":
            if flags.scope:
                err(f"{SCOPE_WARNING} Ignoring for {target}.")
            if flags.force:
                err(
                    "Warning: --force has no effect for local path installs (link is already idempotent)."
                    f" Ignoring for {target}."
                )
            if flags.dry_run:
                print_link_dry_run(target, flags.json)
                continue
            try:
                result = omp.link(target)
            except (OmpError, OSError) as exc:
                err(f"✘ Failed to install {target}: {exc}")
                return 1
            if flags.json:
                out(dumps(result))
            else:
                out(f"✔ Linked {result['name']} from {target}")
                if result["manifest"].get("description"):
                    out(f"  {result['manifest']['description']}")
            continue
        if flags.scope:
            err(f"{SCOPE_WARNING} Ignoring for {target}.")
        omp.ensure_package_json()
        if flags.dry_run:
            if flags.json:
                out(
                    dumps(
                        {
                            "name": re.sub(r"\[[^\]]*\]$", "", target),
                            "version": "0.0.0-dryrun",
                            "path": "",
                            "manifest": {"version": "0.0.0-dryrun"},
                            "enabledFeatures": None,
                            "enabled": True,
                        }
                    )
                )
            else:
                out(f"[dry-run] Would install {target}")
            continue
        err(f"✘ Failed to install {target}: {OmpError(bun_install_failure(target))}")
        return 1
    return 0


def print_link_dry_run(path: str, as_json: bool) -> None:
    if as_json:
        out(dumps({"dryRun": True, "action": "link", "path": path}))
    else:
        out(f"[dry-run] Would link {path}")


def cmd_uninstall(omp: Omp, targets: list[str], flags: Flags) -> int:
    if not targets:
        err("Usage: omp plugin uninstall <package> ...")
        return 1
    ids = [item["id"] for item in omp.list_installed()]
    known = set(ids)
    for raw in targets:
        target = raw
        if target not in known:
            matches = [i for i in ids if i[: i.rfind("@")] == target]
            if len(matches) == 1:
                target = matches[0]
            elif len(matches) > 1:
                err(f"✘ {raw} is installed from {len(matches)} marketplaces. Qualify it: {', '.join(matches)}")
                return 1
        is_marketplace = target in known
        if flags.dry_run:
            if is_marketplace:
                try:
                    omp.uninstall_plugin(target, flags.scope, dry_run=True)
                except (OmpError, OSError) as exc:
                    err(f"✘ Failed to uninstall {target}: {exc}")
                    return 1
            if flags.json:
                payload = {
                    "dryRun": True,
                    "action": "uninstall",
                    "plugin": target,
                    "source": "marketplace" if is_marketplace else "npm",
                }
                out(json.dumps(payload, separators=(",", ":"), ensure_ascii=False))
            else:
                out(f"[dry-run] Would uninstall {target}")
            continue
        if is_marketplace:
            try:
                omp.uninstall_plugin(target, flags.scope, dry_run=False)
            except (OmpError, OSError) as exc:
                err(f"✘ Failed to uninstall {target}: {exc}")
                return 1
            out(f"✔ Uninstalled {target}")
            continue
        if not any(item["name"] == target for item in omp.npm_list()):
            err(f"✘ {raw} is not installed")
            return 1
        omp.npm_uninstall(target)
        if flags.json:
            out(json.dumps({"uninstalled": target}, separators=(",", ":"), ensure_ascii=False))
        else:
            out(f"✔ Uninstalled {target}")
    return 0


def cmd_upgrade(omp: Omp, targets: list[str], flags: Flags) -> int:
    target = targets[0] if targets else None
    if target and parse_plugin_id(target) is None:
        matches = list(dict.fromkeys(i["id"] for i in omp.list_installed() if i["id"][: i["id"].rfind("@")] == target))
        if len(matches) > 1:
            err(f"{target} is installed from {len(matches)} marketplaces. Qualify it: {', '.join(matches)}")
            return 1
        if len(matches) == 1:
            target = matches[0]
        else:
            if flags.scope == "project":
                err(
                    "Warning: --scope is only supported for marketplace plugins (name@marketplace)."
                    f" Ignoring for {target}."
                )
            lock = omp.read_lock(omp.plugins_dir / "omp-plugins.lock.json")
            if target in lock["plugins"]:
                err(f"Failed to upgrade {target}: {target} is linked from a local path; there is nothing to upgrade")
            else:
                err(f"Failed to upgrade {target}: {target} is not installed")
            return 1
    try:
        if target:
            if flags.scope:
                record = omp.upgrade_plugin(target, flags.scope)
                out(f"Upgraded {target} ({flags.scope}) to {record['version']}")
            else:
                for record in omp.upgrade_across_scopes(target):
                    out(f"Upgraded {target} ({record['scope']}) to {record['version']}")
            return 0
        if flags.scope:
            err(
                "Warning: --scope is ignored when upgrading all plugins. "
                f"Use 'omp plugin upgrade <id> --scope {flags.scope}' to target a specific plugin and scope."
            )
        done = omp.upgrade_all()
        if not done:
            out("All marketplace plugins are up to date.")
        for update in done:
            out(f"  {update['pluginId']} ({update['scope']}): {update['from']} -> {update['to']}")
        return 0
    except (OmpError, OSError) as exc:
        err(f"Failed to upgrade: {exc}")
        return 1


def cmd_toggle(omp: Omp, targets: list[str], flags: Flags, enabled: bool) -> int:
    verb, past, key = ("enable", "Enabled", "enabled") if enabled else ("disable", "Disabled", "disabled")
    if not targets:
        err(f"Usage: omp plugin {verb} <plugin> ...")
        return 1
    ids = {item["id"] for item in omp.list_installed()}
    for target in targets:
        try:
            if target in ids:
                omp.set_plugin_enabled(target, enabled, flags.scope)
            else:
                omp.npm_set_enabled(target, enabled)
        except (OmpError, OSError) as exc:
            err(f"✘ Failed to {verb} {target}: {exc}")
            return 1
        if flags.json:
            out(json.dumps({key: target}, separators=(",", ":"), ensure_ascii=False))
        else:
            out(f"✔ {past} {target}")
    return 0


def cmd_list(omp: Omp, flags: Flags) -> int:
    npm = omp.npm_list()
    marketplace = omp.list_installed()
    if flags.json:
        out(dumps({"npm": npm, "marketplace": marketplace}))
        return 0
    if not npm and not marketplace:
        out("No plugins installed")
        out("\nInstall plugins with: omp plugin install <package>")
        return 0
    if npm:
        out("npm Plugins:\n")
        for item in npm:
            mark = "●" if item.get("enabled") else "⦸"
            out(f"{mark} {item['name']}@{item.get('version', 'undefined')}")
            manifest = item["manifest"]
            if manifest.get("description"):
                out(f"  {manifest['description']}")
            if item.get("enabledFeatures"):
                out(f"  Features: {', '.join(item['enabledFeatures'])}")
            features = manifest.get("features")
            if isinstance(features, dict) and features:
                out(f"  Available: [{', '.join(features)}]")
    if marketplace:
        if npm:
            out("")
        out("Marketplace Plugins:\n")
        for item in marketplace:
            entries = item["entries"]
            version = entries[0].get("version", "unknown") if entries else "unknown"
            shadow = " [shadowed]" if item.get("shadowedBy") else ""
            out(f"  {item['id']} ({version}) ({item['scope']}){shadow}")
    return 0


def cmd_link(omp: Omp, targets: list[str], flags: Flags) -> int:
    if not targets:
        err("Usage: omp plugin link <path>")
        return 1
    if flags.dry_run:
        print_link_dry_run(targets[0], flags.json)
        return 0
    try:
        result = omp.link(targets[0])
    except (OmpError, OSError) as exc:
        err(f"✘ Failed to link: {exc}")
        return 1
    if flags.json:
        out(dumps(result))
    else:
        out(f"✔ Linked {result['name']} from {targets[0]}")
    return 0


def cmd_doctor(omp: Omp, flags: Flags) -> int:
    checks = omp.doctor()
    if flags.json:
        out(dumps(checks))
        return 0
    out("Plugin Health Check\n")
    icons = {"ok": "✔", "warning": "⚠", "error": "✘"}
    for check in checks:
        out(f"{icons.get(check['status'], '✘')} {check['name']}: {check['message']}")
    errors = sum(1 for c in checks if c["status"] == "error")
    warnings = sum(1 for c in checks if c["status"] == "warning")
    ok = sum(1 for c in checks if c["status"] == "ok")
    out("")
    out(f"Summary: {ok} ok, {warnings} warnings, {errors} errors")
    if errors:
        out("\nRun with --fix to attempt automatic repair")
        return 1
    return 0


def cmd_discover(omp: Omp, targets: list[str]) -> int:
    name = targets[0] if targets else None
    try:
        plugins = omp.available_plugins(name)
    except (OmpError, OSError) as exc:
        err(f"✘ Failed to discover plugins: {exc}")
        return 1
    if not plugins:
        out(f"No plugins found in {name}" if name else "No plugins available")
        return 0
    out(f"Available Plugins{f' ({name})' if name else ''}:\n")
    for plugin in plugins:
        version = plugin.get("version")
        out(f"  {plugin['name']}{f'@{version}' if version else ''}")
        if plugin.get("description"):
            out(f"    {plugin['description']}")
    return 0


def cmd_marketplace(omp: Omp, targets: list[str]) -> int:
    sub = targets[0] if targets else "list"
    if sub == "add":
        if len(targets) < 2:
            err("Usage: omp plugin marketplace add <source>")
            return 1
        try:
            omp.add_marketplace(targets[1])
        except (OmpError, OSError) as exc:
            err(f"✘ Failed to add marketplace: {exc}")
            return 1
        out(f"✔ Added marketplace: {targets[1]}")
        return 0
    if sub in ("remove", "rm"):
        if len(targets) < 2:
            err("Usage: omp plugin marketplace remove <name>")
            return 1
        try:
            omp.remove_marketplace(targets[1])
        except (OmpError, OSError) as exc:
            err(f"✘ Failed to remove marketplace: {exc}")
            return 1
        out(f"✔ Removed marketplace: {targets[1]}")
        return 0
    if sub == "update":
        try:
            if len(targets) > 1:
                omp.update_marketplace(targets[1])
                out(f"✔ Updated marketplace: {targets[1]}")
            else:
                names = [str(m["name"]) for m in omp.read_marketplaces()["marketplaces"]]
                for name in names:
                    omp.update_marketplace(name)
                out(f"✔ Updated {len(names)} marketplace(s)")
        except (OmpError, OSError) as exc:
            err(f"✘ Failed to update marketplace: {exc}")
            return 1
        return 0
    if sub != "list":
        err(f"Unknown marketplace subcommand: {sub}")
        err("Valid subcommands: add, remove, update, list")
        return 1
    marketplaces = omp.read_marketplaces()["marketplaces"]
    # omp 18.12.6 colours this listing even when piped if FORCE_COLOR is set (NO_COLOR loses).
    coloured = os.environ.get("FORCE_COLOR", "") not in ("", "0", "false") or bool(os.environ.get("FAKE_OMP_COLOR"))

    def sgr(on: int, off: int, text: str) -> str:
        return f"\x1b[{on}m{text}\x1b[{off}m" if coloured else text

    if not marketplaces:
        out(sgr(2, 22, "No marketplaces configured"))
        out(sgr(2, 22, ""))
        out(sgr(2, 22, "Add one with: omp plugin marketplace add <source>"))
        return 0
    out(sgr(1, 22, "Configured Marketplaces:"))
    out(sgr(1, 22, ""))
    for entry in marketplaces:
        out(f"  {sgr(36, 39, str(entry['name']))}  {sgr(2, 22, str(entry['sourceUri']))}")
    return 0


def option_error(message: str) -> int:
    err(f"error: {message}\n\n{PLUGIN_USAGE}")
    return 1


def parse_plugin_args(argv: list[str]) -> tuple[str, list[str], Flags] | int:
    """Parse `plugin ...` like omp: options are validated before the action; an int is an exit code."""
    flags = Flags()
    positionals: list[str] = []
    index = 0
    while index < len(argv):
        token = argv[index]
        index += 1
        if not token.startswith("-") or token == "-":
            positionals.append(token)
            continue
        if token == "--":
            positionals.extend(argv[index:])
            break
        name, has_inline, inline = token.partition("=")
        if name in BOOL_FLAGS and not has_inline:
            if name == "--json":
                flags.json = True
            elif name == "--force":
                flags.force = True
            elif name == "--dry-run":
                flags.dry_run = True
            continue
        if name not in VALUE_FLAGS:
            return option_error(
                f"Unknown option '{token}'. To specify a positional argument starting with a '-', place it at "
                f"the end of the command after '--', as in '-- \"{token}\""
            )
        if has_inline:
            value = inline
        elif index >= len(argv):
            return option_error(f"Option '{name} <value>' argument missing")
        elif argv[index].startswith("-"):
            return option_error(
                f"Option '{name}' argument is ambiguous.\nDid you forget to specify the option argument for "
                f"'{name}'?\nTo specify an option argument starting with a dash use '{name}=-XYZ'."
            )
        else:
            value = argv[index]
            index += 1
        if name == "--scope":
            if value not in ("user", "project"):
                return option_error(f'Expected --scope to be one of: user, project; got "{value}"')
            flags.scope = value
    if not positionals:
        return "list", [], flags
    action = positionals[0]
    if action not in PLUGIN_ACTIONS:
        return option_error(f'Expected action to be one of: {", ".join(PLUGIN_ACTIONS)}; got "{action}"')
    return action, positionals[1:], flags


def injected_failure(omp: Omp, verb: str, target: str | None) -> bool:
    spec = os.environ.get("FAKE_OMP_FAIL")
    if not spec:
        return False
    want_verb, _, want_target = spec.partition(":")
    if want_verb != verb or (want_target and want_target != target):
        return False
    marker = omp.root / FAIL_MARKER
    try:
        if marker.read_text(encoding="utf-8") == spec:
            return False
    except FileNotFoundError:
        pass
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(spec, encoding="utf-8")
    err(f"✘ Failed to {verb}{f' {target}' if target else ''}: Error: injected failure")
    return True


def run_plugin(omp: Omp, argv: list[str]) -> int:
    parsed = parse_plugin_args(argv)
    if isinstance(parsed, int):
        return parsed
    action, args, flags = parsed
    if action in ("features", "config"):
        return unsupported(["plugin", *argv])
    if action == "marketplace":
        sub = args[0] if args else "list"
        verb = f"marketplace-{'remove' if sub == 'rm' else sub}"
        target = args[1] if len(args) > 1 else None
    else:
        verb, target = action, (args[0] if args else None)
    if injected_failure(omp, verb, target):
        return 1
    if action == "install":
        return cmd_install(omp, args, flags)
    if action == "uninstall":
        return cmd_uninstall(omp, args, flags)
    if action == "upgrade":
        return cmd_upgrade(omp, args, flags)
    if action in ("enable", "disable"):
        return cmd_toggle(omp, args, flags, action == "enable")
    if action == "list":
        return cmd_list(omp, flags)
    if action == "link":
        return cmd_link(omp, args, flags)
    if action == "doctor":
        return cmd_doctor(omp, flags)
    if action == "discover":
        return cmd_discover(omp, args)
    return cmd_marketplace(omp, args)


def unsupported(argv: list[str]) -> int:
    err(f"fake omp: unsupported command: omp {' '.join(argv)}")
    err(FAKE_USAGE)
    return 2


def log_call(argv: list[str]) -> None:
    target = os.environ.get("FAKE_OMP_LOG") or os.environ.get("CLAUDE_STUB_LOG")
    if target:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write("omp " + " ".join(argv) + "\n")


# The array settings the fake knows (omp 18.12.5 defaults them to []).
CONFIG_ARRAYS = ("enabledProviders", "disabledProviders", "disabledExtensions", "skills.ignoredSkills")


def config_get(agent: Path, key: str) -> int:
    """``config get <key> --json``: the value from <agent>/config.yml (YAML; JSON parses too), else []."""
    if key not in CONFIG_ARRAYS:
        err(f"Unknown setting: {key}\n\nRun 'omp config list' to see available keys")
        return 1
    value: Any = []
    path = agent / "config.yml"
    if path.is_file():
        import yaml  # lazy: only this action needs PyYAML

        node: Any = yaml.safe_load(path.read_text(encoding="utf-8"))
        for part in key.split("."):
            node = node.get(part) if isinstance(node, dict) else None
        if isinstance(node, list):
            value = node
    out(dumps({"key": key, "value": value, "type": "array", "description": ""}))
    return 0


def main(argv: list[str]) -> int:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(encoding="utf-8")
    log_call(argv)
    rest = list(argv)
    profile = os.environ.get("OMP_PROFILE") or None
    while rest and rest[0].startswith("--profile"):
        if rest[0] == "--profile" and len(rest) > 1:
            profile, rest = rest[1], rest[2:]
        elif rest[0].startswith("--profile="):
            profile, rest = rest[0].split("=", 1)[1], rest[1:]
        else:
            return unsupported(argv)
    if rest == ["--version"]:
        out(f"omp/{os.environ.get('FAKE_OMP_VERSION') or DEFAULT_VERSION}")
        return 0
    if not rest:
        return unsupported(argv)
    omp = Omp(profile)
    if rest[0] == "config":
        action = rest[1] if len(rest) > 1 else None
        if action == "path":
            out(str(omp.config_root / "agent"))
            return 0
        if action == "get" and len(rest) == 4 and rest[3] == "--json":
            return config_get(omp.config_root / "agent", rest[2])
        if action is not None and action not in CONFIG_ACTIONS and not action.startswith("-"):
            err(f'error: Expected action to be one of: {", ".join(CONFIG_ACTIONS)}; got "{action}"\n\n{CONFIG_USAGE}')
            return 1
        return unsupported(argv)
    if rest[0] == "plugin":
        return run_plugin(omp, rest[1:])
    return unsupported(argv)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
