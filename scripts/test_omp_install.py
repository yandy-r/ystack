#!/usr/bin/env python3
"""Hermetic lifecycle matrix for the native OMP installer (scripts/omp_install.py).

The helper runs in-process against the stateful fake omp (scripts/tests/install/fake_omp.py),
placed on a temporary PATH as ``omp``, with a temporary HOME, isolated XDG variables and no
inherited GIT_* variables. The real ~/.omp is never touched.
"""

from __future__ import annotations

import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Callable, Iterator
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from dataclasses import dataclass
from pathlib import Path
from typing import Any, ClassVar
from unittest.mock import patch

import install_slices
import omp_install
from codex_install import inventory
from generate_omp_packages import omp_mcp_bytes
from omp_native_smoke import bump
from package_install_plan import plan_install
from package_model import PackageModelError, load_package_model

FAKE_OMP = Path(__file__).resolve().parent / "tests/install/fake_omp.py"
REAL_BUILD_EXPORT: Callable[[Path], None] = omp_install.build_export
FIXTURE = ("ycc", "ycc-extra")
BUMPED = "9.9.9"
READ_VERBS = (
    "omp --version",
    "omp config path",
    "omp plugin list --json",
    "omp plugin marketplace list",
    "omp config get enabledProviders --json",
    "omp config get skills.ignoredSkills --json",
)
DRY_RUN_PREVIEW = re.compile(r"^omp plugin (install|uninstall)( --force)? --dry-run( |$)")
Snapshot = dict[str, tuple[str, bytes]]


@dataclass
class Result:
    code: int
    out: str
    err: str
    child: str


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def make_fixture(root: Path, packages: tuple[str, ...], version: str, name: str = "ycc") -> Path:
    """A repository-shaped OMP export (the layout ``generate_omp_packages.py --export`` writes)."""
    write_json(
        root / ".omp-plugin/marketplace.json",
        {
            "name": name,
            "owner": {"name": "test"},
            "metadata": {"description": "fixture", "version": version},
            "plugins": [
                {"name": package, "source": f"./packages/omp/{package}", "description": package, "version": version}
                for package in packages
            ],
        },
    )
    for package in packages:
        base = root / "packages/omp" / package
        manifest = {"name": package, "version": version, "description": package, "author": {"name": "test"}}
        write_json(base / ".omp-plugin/plugin.json", manifest)
        write_json(base / ".claude-plugin/plugin.json", manifest)
        write_json(base / "package.json", {"name": package, "version": version, "private": True})
        skill = base / "skills" / f"{package}-skill" / "SKILL.md"
        skill.parent.mkdir(parents=True, exist_ok=True)
        skill.write_text(f"---\nname: {package}-skill\ndescription: fixture\n---\n", encoding="utf-8")
    return root


def bump_files(packages: tuple[str, ...]) -> list[str]:
    files = [".omp-plugin/marketplace.json"]
    for package in packages:
        base = f"packages/omp/{package}"
        files += [f"{base}/.omp-plugin/plugin.json", f"{base}/.claude-plugin/plugin.json", f"{base}/package.json"]
    return files


class OmpInstallTests(unittest.TestCase):
    cache: ClassVar[Path]
    cached_export: ClassVar[Path]
    model_version: ClassVar[str]

    @classmethod
    def setUpClass(cls) -> None:
        cls.cache = Path(tempfile.mkdtemp(prefix="ycc-omp-test-export."))
        cls.cached_export = cls.cache / "export"
        REAL_BUILD_EXPORT(cls.cached_export)
        cls.model_version = omp_install.package_version(cls.cached_export, "ycc")

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.cache, ignore_errors=True)

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="ycc-omp-test.")
        self.addCleanup(temporary.cleanup)
        self.tmp = Path(temporary.name).resolve()
        self.home = self.tmp / "home"
        self.project = self.tmp / "work/proj"
        (self.project / ".git").mkdir(parents=True)
        self.home.mkdir()
        (self.tmp / "tmp").mkdir()
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        wrapper = bin_dir / "omp"
        wrapper.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{FAKE_OMP}" "$@"\n', encoding="utf-8")
        wrapper.chmod(wrapper.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        self.log = self.tmp / "omp.log"
        self.fake_root = self.home / ".omp"
        env = {
            "HOME": str(self.home),
            "PATH": f"{bin_dir}{os.pathsep}/usr/bin{os.pathsep}/bin",
            "TMPDIR": str(self.tmp / "tmp"),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_DATA_HOME": str(self.home / ".local/share"),
            "XDG_STATE_HOME": str(self.home / ".local/state"),
            "XDG_CACHE_HOME": str(self.home / ".cache"),
            "FAKE_OMP_HOME": str(self.fake_root),
            "FAKE_OMP_LOG": str(self.log),
            "LANG": "C.UTF-8",
        }
        patcher = patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        home_patcher = patch.object(Path, "home", return_value=self.home)
        home_patcher.start()
        self.addCleanup(home_patcher.stop)
        export_patcher = patch.object(omp_install, "build_export", side_effect=self.build_export)
        export_patcher.start()
        self.addCleanup(export_patcher.stop)
        previous = os.getcwd()
        os.chdir(self.home)
        self.addCleanup(os.chdir, previous)

        self.source = self.cached_export
        self.real_export = False
        self.assertTrue(Path.home().is_relative_to(self.tmp), "HOME must be a temporary directory")
        self.assertTrue(Path(os.environ["HOME"]).is_relative_to(self.tmp))
        self.assertTrue(Path(os.environ["FAKE_OMP_HOME"]).is_relative_to(self.tmp))
        self.assertTrue(omp_install.state_path().is_relative_to(self.tmp))
        self.assertTrue(omp_install.export_dir().is_relative_to(self.tmp))
        self.assertFalse(any(key.startswith("GIT_") for key in os.environ))
        self.assertIsNone(os.environ.get("OMP_BIN"))
        self.assertEqual(shutil.which("omp"), str(wrapper))

    # -- harness -------------------------------------------------------------------------------

    def build_export(self, staging: Path) -> None:
        if self.real_export:
            REAL_BUILD_EXPORT(staging)
        else:
            shutil.copytree(self.source, staging, dirs_exist_ok=True)

    def use_fixture(self) -> None:
        self.source = make_fixture(self.tmp / "fixture", FIXTURE, "1.0.0")
        for name, value in (
            ("select_packages", lambda csv: FIXTURE),
            ("package_components", lambda package: ("skills",)),
        ):
            patcher = patch.object(omp_install, name, side_effect=value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def bump(self, packages: tuple[str, ...], version: str = BUMPED) -> None:
        """Lockstep version bump of the export the next install builds (like omp_native_smoke bump)."""
        bumped = Path(tempfile.mkdtemp(dir=self.tmp, prefix=f"source-{version}."))
        shutil.copytree(self.source, bumped, dirs_exist_ok=True)
        bump(bumped, version, bump_files(packages))
        self.source = bumped

    def omp(self, *argv: str) -> Result:
        """Run ``omp_install.main`` in-process; capture its prints and the fake's inherited output."""
        return self.capture(lambda: omp_install.main(list(argv)))

    def capture(self, body: Callable[[], int]) -> Result:
        """Run ``body`` in-process; capture its prints and the fake's inherited output."""
        out, err = io.StringIO(), io.StringIO()
        with tempfile.TemporaryFile() as child_out, tempfile.TemporaryFile() as child_err:
            sys.stdout.flush()
            sys.stderr.flush()
            saved = os.dup(1), os.dup(2)
            os.dup2(child_out.fileno(), 1)
            os.dup2(child_err.fileno(), 2)
            try:
                with redirect_stdout(out), redirect_stderr(err):
                    code = body()
            finally:
                sys.stdout.flush()
                sys.stderr.flush()
                os.dup2(saved[0], 1)
                os.dup2(saved[1], 2)
                os.close(saved[0])
                os.close(saved[1])
            child_out.seek(0)
            child_err.seek(0)
            child = child_out.read().decode() + child_err.read().decode()
        return Result(code, out.getvalue(), err.getvalue(), child)

    def ok(self, *argv: str) -> Result:
        result = self.omp(*argv)
        self.assertEqual(result.code, 0, f"{argv}: {result.err}{result.child}")
        return result

    def refused(self, *argv: str) -> Result:
        result = self.omp(*argv)
        self.assertEqual(result.code, 2, f"{argv}: {result.out}{result.err}")
        self.assertTrue(result.err.splitlines()[-1].startswith("[err] native OMP "), result.err)
        return result

    def root_of(self, scope: str) -> Path:
        return self.project if scope == "project" else self.home

    def install(self, scope: str, *extra: str) -> Result:
        return self.ok("install", "--scope", scope, "--project-root", str(self.root_of(scope)), *extra)

    def remove(self, scope: str, *extra: str) -> Result:
        return self.ok("remove", "--scope", scope, "--project-root", str(self.root_of(scope)), *extra)

    @contextmanager
    def quiet(self, **env: str) -> Iterator[None]:
        """Direct fake calls and helper reads that must not reach the call log."""
        with patch.dict(os.environ, {"FAKE_OMP_LOG": "", **env}):
            yield

    def fake(self, *argv: str, cwd: Path | None = None, **env: str) -> str:
        with self.quiet(**env):
            result = subprocess.run(
                [sys.executable, str(FAKE_OMP), *argv],
                cwd=cwd or self.home,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, f"fake omp {argv}: {result.stderr}")
        return result.stdout

    def listing(self, cwd: Path, **env: str) -> dict[str, Any]:
        with self.quiet(**env):
            return omp_install.OmpCli().installed(cwd)

    def marketplaces(self, **env: str) -> dict[str, str]:
        with self.quiet(**env):
            return omp_install.OmpCli().marketplaces()

    def entry(self, package: str, scope: str, **env: str) -> dict[str, Any] | None:
        return omp_install.scope_entry(self.listing(self.root_of(scope), **env), package, scope)

    def calls(self) -> list[str]:
        try:
            return self.log.read_text(encoding="utf-8").splitlines()
        except FileNotFoundError:
            return []

    def clear_log(self) -> None:
        self.log.unlink(missing_ok=True)

    def agents_skill(self, name: str, *, owned: bool, relative: str = ".agents/skills", text: str = "mine") -> Path:
        """A differing ``<relative>/<name>`` copy; ``owned`` records it in the slice ledger like install_slices."""
        skill = self.home / relative / name / "SKILL.md"
        skill.parent.mkdir(parents=True, exist_ok=True)
        skill.write_text(text, encoding="utf-8")
        if owned:
            ledger = install_slices.state_path()
            units = install_slices.load_state(ledger)
            units.setdefault(str(self.home / relative), []).append(name)
            install_slices.save_state(ledger, units)
        return skill

    def user_config(self, payload: dict[str, Any]) -> None:
        path = self.fake_root / "agent/config.yml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload), encoding="utf-8")

    def mutating(self) -> list[str]:
        return [
            line
            for line in self.calls()
            if line not in READ_VERBS and not line.startswith("omp plugin discover") and not DRY_RUN_PREVIEW.match(line)
        ]

    def snapshot(self) -> Snapshot:
        """Every path under the sandbox (fake omp state, ycc state, export, projects) but the call log."""
        result: Snapshot = {}
        for path in sorted(self.tmp.rglob("*")):
            if path == self.log or path.is_relative_to(self.tmp / "tmp"):
                continue
            rel = str(path.relative_to(self.tmp))
            if path.is_symlink():
                result[rel] = ("link", os.readlink(path).encode())
            elif path.is_dir():
                result[rel] = ("dir", b"")
            else:
                result[rel] = ("file", path.read_bytes())
        return result

    def state(self) -> dict[str, Any]:
        payload: dict[str, Any] = json.loads(omp_install.state_path().read_text(encoding="utf-8"))
        return payload

    def profile_key(self, profile: str | None = None) -> str:
        root = self.fake_root / "profiles" / profile if profile else self.fake_root
        return str(root / "agent")

    def record(self, package: str, scope: str, profile: str | None = None) -> dict[str, Any] | None:
        root = str(self.project.resolve()) if scope == "project" else None
        installs = self.state()["profiles"].get(self.profile_key(profile), {}).get("installs", [])
        return next(
            (
                item
                for item in installs
                if item["package"] == package and item["scope"] == scope and item.get("project_root") == root
            ),
            None,
        )

    def assert_installed(self, packages: tuple[str, ...], scope: str, version: str) -> None:
        for package in packages:
            entry = self.entry(package, scope)
            self.assertIsNotNone(entry, f"{package}@ycc ({scope})")
            assert entry is not None
            self.assertEqual(entry["version"], version)
            self.assertTrue((Path(entry["installPath"]) / ".omp-plugin/plugin.json").is_file())
            record = self.record(package, scope)
            self.assertIsNotNone(record, f"{package} ({scope}) is recorded")
            assert record is not None
            self.assertEqual(record["version"], version)
            self.assertEqual(record["cache_root"], str(Path(entry["installPath"]).parent))

    def assert_dry_run(self, argv: tuple[str, ...]) -> Result:
        before = self.snapshot()
        self.clear_log()
        result = self.ok(*argv)
        self.assertEqual(self.snapshot(), before, f"dry-run mutated: {argv}")
        self.assertEqual(self.mutating(), [], f"dry-run ran mutating omp calls: {argv}")
        return result

    # -- matrix --------------------------------------------------------------------------------

    def lifecycle(self, packages: tuple[str, ...], scope: str, version: str) -> None:
        exported = omp_install.export_dir()
        root = self.root_of(scope)
        base = ("--scope", scope, "--project-root", str(root))

        # Dry-run of a fresh install: nothing is written, no mutating omp call runs.
        preview = self.assert_dry_run(("install", *base, "--dry-run"))
        self.assertIn(f"[dry-run] would export OMP packages → {exported}", preview.out)
        self.assertIn(f"[dry-run] would run: omp plugin marketplace add {exported}", preview.out)
        for package in packages:
            self.assertIn(f"[dry-run] would run: omp plugin install --scope {scope} {package}@ycc", preview.out)
        self.assertFalse(omp_install.state_path().exists())

        # Install.
        self.clear_log()
        result = self.install(scope)
        calls = self.calls()
        self.assertIn(f"omp plugin marketplace add {exported}", calls)
        for package in packages:
            self.assertIn(f"omp plugin install --scope {scope} {package}@ycc", calls)
        self.assert_installed(packages, scope, version)
        self.assertEqual(self.marketplaces(), {"ycc": str(exported)})
        state = self.state()
        self.assertEqual(state["export"], str(exported))
        self.assertEqual(state["export_inventory"], inventory(exported))
        self.assertEqual(state["profiles"][self.profile_key()]["marketplace"], {"name": "ycc", "source": str(exported)})
        self.assertIn(omp_install.TRUST, result.out)
        # A package with agents ships the scope guard extension, which OMP loads only at session start.
        self.assertIn(omp_install.restart_line(packages), result.out)
        shadow = "[ok] a project install shadows your user install here"
        self.assertEqual(shadow in result.out, scope == "project")

        # Idempotent re-run: zero mutating omp calls.
        self.clear_log()
        again = self.install(scope)
        self.assertEqual(self.mutating(), [])
        for package in packages:
            self.assertIn(f"[ok] {package}@ycc {version} up to date ({scope})", again.out)
        self.assertNotIn(omp_install.TRUST, again.out)

        # Dry-run of an update.
        self.bump(packages)
        preview = self.assert_dry_run(("install", *base, "--dry-run"))
        self.assertIn("[dry-run] would run: omp plugin marketplace update ycc", preview.out)
        for package in packages:
            self.assertIn(f"[dry-run] would run: omp plugin upgrade --scope {scope} {package}@ycc", preview.out)

        # Update: marketplace update, then upgrade per package in that scope.
        self.clear_log()
        result = self.install(scope)
        calls = self.calls()
        self.assertIn("omp plugin marketplace update ycc", calls)
        for package in packages:
            self.assertIn(f"omp plugin upgrade --scope {scope} {package}@ycc", calls)
            self.assertIn(f"[ok] {package}@ycc {version} -> {BUMPED} upgraded ({scope})", result.out)
        self.assertFalse(any(" enable " in line or " disable " in line for line in calls))
        self.assert_installed(packages, scope, BUMPED)
        self.assertEqual(self.state()["export_inventory"], inventory(exported))

        # Dry-run of remove.
        preview = self.assert_dry_run(("remove", *base, "--dry-run"))
        calls = self.calls()
        for package in packages:
            self.assertIn(f"omp plugin uninstall --dry-run --scope {scope} {package}@ycc", calls)
            self.assertIn(f"[dry-run] would run: omp plugin uninstall --scope {scope} {package}@ycc", preview.out)
        self.assertIn("[dry-run] would run: omp plugin marketplace remove ycc", preview.out)
        self.assertIn(f"[dry-run] would remove {exported}", preview.out)

        # Remove: everything ycc created goes, and only that.
        self.clear_log()
        self.remove(scope)
        calls = self.calls()
        for package in packages:
            self.assertIn(f"omp plugin uninstall --scope {scope} {package}@ycc", calls)
        self.assertIn("omp plugin marketplace remove ycc", calls)
        self.assertEqual(omp_install.ycc_items(self.listing(root), scope), [])
        self.assertEqual(self.marketplaces(), {})
        self.assertFalse(exported.exists())
        self.assertFalse(omp_install.state_path().exists())

        # Remove again: no state, no-op.
        self.clear_log()
        self.assertIn("[ok] nothing ycc-owned to remove for omp", self.remove(scope).out)
        self.assertEqual(self.calls(), [])
        # The helper never opts omp into XDG routing.
        self.assertFalse((Path(os.environ["XDG_DATA_HOME"]) / "omp").exists())

    def test_matrix_model_packages_user_scope(self) -> None:
        packages = omp_install.select_packages("")
        self.assertEqual(packages, ("ycc", "ycc-mcp", "ycc-rules"))
        self.lifecycle(packages, "user", self.model_version)

    def test_ycc_mcp_installs_its_mcp_config(self) -> None:
        for scope in omp_install.SCOPES:
            with self.subTest(scope=scope):
                self.clear_log()
                result = self.install(scope)
                self.assertIn(f"omp plugin install --scope {scope} ycc-mcp@ycc", self.calls())
                entry = self.entry("ycc-mcp", scope)
                assert entry is not None
                config = Path(entry["installPath"]) / ".mcp.json"
                source = (omp_install.ROOT / "mcp-configs/mcp.json").read_bytes()
                self.assertEqual(config.read_bytes(), omp_mcp_bytes(source))
                self.assertIn("[!!] restart running omp sessions", result.out)
                self.clear_log()
                self.remove(scope)
                self.assertIn(f"omp plugin uninstall --scope {scope} ycc-mcp@ycc", self.calls())
                self.assertIsNone(self.entry("ycc-mcp", scope))

    def test_package_selection_installs_and_removes_only_ycc_mcp(self) -> None:
        self.clear_log()
        self.ok("install", "--packages", "ycc-mcp", "--scope", "user", "--project-root", str(self.home))
        calls = self.calls()
        self.assertIn("omp plugin install --scope user ycc-mcp@ycc", calls)
        self.assertNotIn("omp plugin install --scope user ycc@ycc", calls)
        self.assert_installed(("ycc-mcp",), "user", self.model_version)
        self.assertIsNone(self.entry("ycc", "user"))
        # A later default install adds ycc next to the recorded ycc-mcp; remove drops both.
        self.install("user")
        self.assert_installed(("ycc", "ycc-mcp"), "user", self.model_version)
        self.clear_log()
        self.remove("user")
        calls = self.calls()
        for package in ("ycc", "ycc-mcp"):
            self.assertIn(f"omp plugin uninstall --scope user {package}@ycc", calls)
        self.assertEqual(self.marketplaces(), {})

    def test_matrix_model_packages_project_scope(self) -> None:
        self.lifecycle(omp_install.select_packages(""), "project", self.model_version)

    def test_matrix_two_package_fixture_user_scope(self) -> None:
        self.use_fixture()
        self.lifecycle(FIXTURE, "user", "1.0.0")

    def test_matrix_two_package_fixture_project_scope(self) -> None:
        self.use_fixture()
        self.lifecycle(FIXTURE, "project", "1.0.0")

    def test_real_build_export_end_to_end(self) -> None:
        self.real_export = True
        self.install("user")
        exported = omp_install.export_dir()
        self.assertEqual(inventory(exported), inventory(self.cached_export))
        self.assert_installed(omp_install.select_packages(""), "user", self.model_version)
        self.clear_log()
        self.install("user")
        self.assertEqual(self.mutating(), [])

    # -- disabled, ownership -------------------------------------------------------------------

    def test_disabled_install_is_upgraded_and_kept_disabled(self) -> None:
        for scope in omp_install.SCOPES:
            with self.subTest(scope=scope):
                self.source = self.cached_export
                self.install(scope)
                self.fake("plugin", "disable", "--scope", scope, "ycc@ycc", cwd=self.root_of(scope))
                self.bump(("ycc",))
                self.clear_log()
                result = self.install(scope)
                calls = self.calls()
                self.assertIn(f"omp plugin upgrade --scope {scope} ycc@ycc", calls)
                self.assertFalse(any(" enable" in line for line in calls), calls)
                self.assertIn(f"[ok] ycc@ycc disabled at {scope} scope: kept", result.out)
                entry = self.entry("ycc", scope)
                assert entry is not None
                self.assertIs(entry.get("enabled"), False)
                self.assertEqual(entry["version"], BUMPED)
                self.remove(scope)

    def test_unrecorded_install_is_never_uninstalled_and_keeps_the_marketplace(self) -> None:
        self.install("user")
        state = self.state()
        state["profiles"][self.profile_key()]["installs"] = []
        omp_install.save_state(state)

        self.clear_log()
        result = self.install("user")
        self.assertEqual(self.mutating(), [])
        self.assertIn(
            "[!!] ycc@ycc is already installed (user) and not recorded as ycc-owned; left untouched", result.out
        )
        self.assertIsNone(self.record("ycc", "user"))

        self.clear_log()
        result = self.remove("user")
        self.assertEqual(self.mutating(), [])
        self.assertIn(
            "[!!] kept marketplace ycc: ycc@ycc (user), ycc-mcp@ycc (user), ycc-rules@ycc (user) still installed",
            result.out,
        )
        self.assertIsNotNone(self.entry("ycc", "user"))
        self.assertIn("ycc", self.marketplaces())
        self.assertTrue(omp_install.export_dir().is_dir())

    def test_force_color_install_and_remove_parse_the_marketplace_list(self) -> None:
        """YAN-1558: FORCE_COLOR makes omp colour the piped list; install and remove still parse it."""
        with patch.dict(os.environ, {"FORCE_COLOR": "1"}):
            self.install("user")
            self.assertEqual(self.marketplaces(), {"ycc": str(omp_install.export_dir())})
            self.remove("user")
            self.assertEqual(self.marketplaces(), {})

    def test_coloured_marketplace_list_is_stripped_before_parsing(self) -> None:
        """YAN-1558: SGR sequences that survive the colour-off environment never reach the parser."""
        self.assertEqual(self.marketplaces(FAKE_OMP_COLOR="1"), {})
        other = make_fixture(self.tmp / "other", ("thing",), "1.0.0", name="other")
        self.fake("plugin", "marketplace", "add", str(other))
        self.assertIn("\x1b[", self.fake("plugin", "marketplace", "list", FAKE_OMP_COLOR="1"))
        self.assertEqual(self.marketplaces(FAKE_OMP_COLOR="1"), {"other": str(other)})

    def test_foreign_marketplace_refuses_before_any_mutation(self) -> None:
        foreign = make_fixture(self.tmp / "foreign", ("ycc",), "0.1.0")
        self.fake("plugin", "marketplace", "add", str(foreign))
        before = self.snapshot()
        self.clear_log()
        result = self.refused("install", "--scope", "user", "--project-root", str(self.home))
        self.assertIn(f"marketplace ycc has a different source ({foreign})", result.err)
        self.assertIn("(remove it: omp plugin marketplace remove ycc)", result.err)
        self.assertEqual(self.mutating(), [])
        self.assertEqual(self.snapshot(), before)

    def test_ycc_link_refuses_before_any_mutation(self) -> None:
        self.fake("plugin", "link", str(self.cached_export / "packages/omp/ycc"))
        before = self.snapshot()
        self.clear_log()
        for scope in omp_install.SCOPES:
            result = self.refused("install", "--scope", scope, "--project-root", str(self.root_of(scope)))
            self.assertIn("runtime package ycc is linked (omp plugin link)", result.err)
        self.assertEqual(self.mutating(), [])
        self.assertEqual(self.snapshot(), before)

    def test_unrecorded_export_dir_is_refused_unless_forced(self) -> None:
        exported = omp_install.export_dir()
        exported.mkdir(parents=True)
        (exported / "mine.txt").write_text("user data", encoding="utf-8")
        before = self.snapshot()
        self.clear_log()
        result = self.refused("install", "--scope", "user", "--project-root", str(self.home))
        self.assertIn(f"{exported} exists but is not the recorded ycc export; rerun with --force", result.err)
        self.assertEqual(self.mutating(), [])
        self.assertEqual(self.snapshot(), before)

        self.install("user", "--force")
        self.assertFalse((exported / "mine.txt").exists())
        self.assertEqual(inventory(exported), inventory(self.cached_export))
        self.assert_installed(("ycc",), "user", self.model_version)

    # -- partial failure, GC, profiles -----------------------------------------------------------

    def test_failed_first_install_rolls_back_marketplace_state_and_export(self) -> None:
        exported = omp_install.export_dir()
        with patch.dict(os.environ, {"FAKE_OMP_FAIL": "install"}):
            result = self.refused("install", "--scope", "user", "--project-root", str(self.home))
        self.assertIn("'omp plugin install --scope user ycc@ycc' failed (exit 1)", result.err)
        calls = self.calls()
        self.assertIn(f"omp plugin marketplace add {exported}", calls)
        self.assertIn("omp plugin marketplace remove ycc", calls)
        self.assertEqual(self.marketplaces(), {})
        self.assertIsNone(self.entry("ycc", "user"))
        self.assertFalse(omp_install.state_path().exists())
        self.assertFalse(exported.exists())
        self.assertEqual(list(exported.parent.iterdir()) if exported.parent.exists() else [], [])

    def test_failure_on_second_package_keeps_the_first_and_rerun_completes(self) -> None:
        self.use_fixture()
        with patch.dict(os.environ, {"FAKE_OMP_FAIL": "install:ycc-extra@ycc"}):
            result = self.refused("install", "--scope", "user", "--project-root", str(self.home))
        self.assertIn("'omp plugin install --scope user ycc-extra@ycc' failed (exit 1)", result.err)
        self.assertIsNotNone(self.record("ycc", "user"))
        self.assertIsNone(self.record("ycc-extra", "user"))
        self.assertIsNotNone(self.entry("ycc", "user"))
        self.assertIsNone(self.entry("ycc-extra", "user"))

        self.clear_log()
        self.install("user")
        calls = self.calls()
        self.assertIn("omp plugin install --scope user ycc-extra@ycc", calls)
        self.assertNotIn("omp plugin install --scope user ycc@ycc", calls)
        self.assert_installed(FIXTURE, "user", "1.0.0")
        self.assertEqual(self.marketplaces(), {"ycc": str(omp_install.export_dir())})

    def test_user_upgrade_dangling_a_recorded_project_prints_and_takes_the_repair(self) -> None:
        self.install("project")
        self.install("user")
        self.bump(("ycc",))
        result = self.install("user")
        root = self.project.resolve()
        self.assertIn(f"repair: cd {root} && {omp_install.ROOT}/install.sh install --target omp --project", result.out)
        entry = self.entry("ycc", "project")
        assert entry is not None
        self.assertFalse(Path(entry["installPath"]).exists())

        self.clear_log()
        result = self.install("project")
        self.assertIn("omp plugin install --force --scope project ycc@ycc", self.calls())
        self.assertIn(f"[ok] ycc@ycc {BUMPED} reinstalled (project)", result.out)
        self.assert_installed(("ycc",), "project", BUMPED)
        self.assert_installed(("ycc",), "user", BUMPED)

    def test_dangling_check_still_runs_on_omp_18_13_and_later(self) -> None:
        # omp >= 18.13.0 keeps only caches its own project installs registered (oh-my-pi#16830);
        # a project installed by older omp still loses its cache, so the check must not be version-gated.
        os.environ["FAKE_OMP_VERSION"] = "18.16.0"
        self.install("project")
        self.install("user")
        self.bump(("ycc",))
        result = self.install("user")
        self.assertIn(f"[!!] ycc@ycc project install at {self.project.resolve()} lost its cache (omp GC)", result.out)

    def test_profiles_are_recorded_and_removed_separately(self) -> None:
        with patch.dict(os.environ, {"OMP_PROFILE": "work"}):
            self.install("user")
        work = self.profile_key("work")
        self.assertTrue(work.endswith("/profiles/work/agent"))
        self.assertIn(work, self.state()["profiles"])
        self.assertNotIn(self.profile_key(), self.state()["profiles"])
        self.assertIsNotNone(self.record("ycc", "user", "work"))
        self.assertIsNone(self.entry("ycc", "user"))

        self.install("user")
        self.assertIsNotNone(self.record("ycc", "user"))
        work_before = self.state()["profiles"][work]

        self.remove("user")
        state = self.state()
        self.assertNotIn(self.profile_key(), state["profiles"])
        self.assertEqual(state["profiles"][work], work_before)
        self.assertIsNone(self.entry("ycc", "user"))
        self.assertEqual(self.marketplaces(), {})
        self.assertIsNotNone(self.entry("ycc", "user", OMP_PROFILE="work"))
        self.assertIn("ycc", self.marketplaces(OMP_PROFILE="work"))
        self.assertTrue(omp_install.export_dir().is_dir())

    # -- version and home ----------------------------------------------------------------------

    def test_old_omp_is_unavailable_and_refused(self) -> None:
        with patch.dict(os.environ, {"FAKE_OMP_VERSION": "18.12.1"}):
            result = self.omp("available")
            self.assertEqual(result.code, 1)
            self.assertIn("omp 18.12.1 is older than 18.12.2", result.err)
            before = self.snapshot()
            self.clear_log()
            result = self.refused("install", "--scope", "user", "--project-root", str(self.home))
            self.assertIn("omp 18.12.1 is older than 18.12.2", result.err)
            self.assertEqual(self.mutating(), [])
            self.assertEqual(self.snapshot(), before)
        result = self.omp("available")
        self.assertEqual((result.code, result.out), (0, "18.12.3\n"))

    def test_missing_omp_is_unavailable_and_cleanup_is_a_noop(self) -> None:
        with patch.dict(os.environ, {"PATH": f"/usr/bin{os.pathsep}/bin"}):
            if shutil.which("omp") is not None:
                self.skipTest("an omp binary is installed system-wide")
            result = self.omp("available")
            self.assertEqual((result.code, result.err), (1, "omp not found on PATH\n"))
            self.assertEqual(self.cleanup().out, "[ok] omp: no legacy state to retire (omp not found on PATH)\n")

    def test_project_scope_at_home_is_refused(self) -> None:
        before = self.snapshot()
        result = self.refused("install", "--scope", "project", "--project-root", str(self.home))
        self.assertIn(omp_install.HOME_REFUSAL, result.err)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.snapshot(), before)

    def test_repo_mode_needs_a_listed_package(self) -> None:
        self.assertTrue(omp_install.listed())
        self.assertEqual(self.omp("listed").code, 0)
        with patch.object(omp_install, "listed", return_value=False):
            self.assertEqual(self.omp("listed").code, 1)
            result = self.refused("install", "--scope", "user", "--project-root", str(self.home), "--mode", "repo")
        self.assertIn(omp_install.REPO_REFUSAL, result.err)
        self.assertEqual(self.calls(), [])

    def test_repo_mode_installs_from_the_repository_catalog(self) -> None:
        repo = self.tmp / "repo-catalog"
        shutil.copytree(omp_install.ROOT / ".omp-plugin", repo / ".omp-plugin")
        shutil.copytree(omp_install.ROOT / "packages/omp", repo / "packages/omp")
        with patch.dict(os.environ, {"FAKE_OMP_REPO_CATALOG": str(repo)}):
            self.ok("install", "--scope", "user", "--project-root", str(self.home), "--mode", "repo")
        calls = self.calls()
        self.assertIn(f"omp plugin marketplace add {omp_install.REPOSITORY}", calls)
        self.assertEqual(self.marketplaces(), {"ycc": omp_install.REPOSITORY})
        self.assert_installed(("ycc", "ycc-mcp", "ycc-rules"), "user", self.model_version)
        self.assertFalse(omp_install.export_dir().exists())

    # -- legacy cleanup (install_migrate.py runs it before the installer's native install) ------

    def cleanup(self, *, apply: bool = True) -> Result:
        """Run the legacy cleanup the way install_migrate.py does; exit 2 on a refusal."""

        def body() -> int:
            try:
                omp_install.apply_migrate(omp_install.plan_migrate(self.home, apply=apply), apply)
            except (OSError, ValueError, subprocess.CalledProcessError) as error:
                print(f"[err] native OMP legacy cleanup stopped: {error}", file=sys.stderr)
                return 2
            return 0

        return self.capture(body)

    def cleanup_ok(self, *, apply: bool = True) -> Result:
        result = self.cleanup(apply=apply)
        self.assertEqual(result.code, 0, f"cleanup: {result.err}{result.child}")
        return result

    def cleanup_refused(self, *, apply: bool = True) -> Result:
        result = self.cleanup(apply=apply)
        self.assertEqual(result.code, 2, f"cleanup: {result.out}{result.err}")
        return result

    def cleanup_preview(self) -> Result:
        before = self.snapshot()
        self.clear_log()
        result = self.cleanup_ok(apply=False)
        self.assertEqual(self.snapshot(), before, "cleanup dry-run mutated")
        self.assertEqual(self.mutating(), [], "cleanup dry-run ran mutating omp calls")
        return result

    def test_cleanup_retires_an_in_checkout_link(self) -> None:
        self.fake("plugin", "link", str(omp_install.ROOT / "packages/omp/ycc"))
        self.assertEqual([item["name"] for item in self.listing(self.home)["npm"]], ["ycc"])

        preview = self.cleanup_preview()
        self.assertIn("[dry-run] would run: omp plugin uninstall ycc", preview.out)
        self.assertIn("[ok] would retire the ycc link; the native install follows", preview.out)
        self.assertIn("omp plugin uninstall --dry-run ycc", self.calls())

        self.clear_log()
        result = self.cleanup_ok()
        self.assertIn("omp plugin uninstall ycc", self.calls())
        self.assertIn("[ok] retired the ycc link; the native install follows", result.out)
        self.assertEqual(self.listing(self.home)["npm"], [])

        self.clear_log()
        self.assertIn("[ok] omp: no legacy state to retire", self.cleanup_ok().out)
        self.assertEqual(self.mutating(), [])

    def test_cleanup_retires_the_checkout_root_marketplace_and_leaves_the_install_owed(self) -> None:
        other = make_fixture(self.tmp / "other", ("thing",), "1.0.0", name="other")
        self.fake("plugin", "marketplace", "add", str(other))
        self.legacy_checkout_marketplace("ycc")
        legacy = self.entry("ycc", "user")
        assert legacy is not None
        self.assertFalse((Path(legacy["installPath"]) / ".omp-plugin/plugin.json").exists())
        self.agents_skill("plan", owned=True)

        preview = self.cleanup_preview()
        self.assertIn("[dry-run] would run: omp plugin uninstall --scope user ycc@ycc", preview.out)
        self.assertIn("[dry-run] would run: omp plugin marketplace remove ycc", preview.out)
        self.assertIn("[ok] native OMP install owed (user scope)", preview.out)
        self.assertIn("omp plugin uninstall --dry-run --scope user ycc@ycc", self.calls())
        # The installer's dry-run install previews past the legacy marketplace the cleanup retires.
        install_preview = self.assert_dry_run(
            ("install", "--scope", "user", "--project-root", str(self.home), "--dry-run")
        )
        self.assertIn("is legacy; a real run needs it gone first", install_preview.out)

        self.clear_log()
        self.cleanup_ok()
        calls = self.calls()
        self.assertIn("omp plugin uninstall --scope user ycc@ycc", calls)
        self.assertIn("omp plugin marketplace remove ycc", calls)
        # The cleanup never installs: the installer's native install (its mode and packages) follows.
        self.assertFalse(any(call.startswith(("omp plugin install", "omp plugin marketplace add")) for call in calls))
        self.assertEqual(omp_install.ycc_items(self.listing(self.home), "user"), [])
        self.assertEqual(self.marketplaces(), {"other": str(other)})
        self.assertEqual(
            self.state()["migrate_pending"], {self.profile_key(): [{"scope": "user", "project_root": None}]}
        )

        self.install("user")
        exported = omp_install.export_dir()
        items = omp_install.ycc_items(self.listing(self.home), "user")
        self.assertEqual([item["id"] for item in items], ["ycc@ycc", "ycc-mcp@ycc", "ycc-rules@ycc"])
        self.assertEqual([len(item["entries"]) for item in items], [1, 1, 1])
        self.assert_installed(("ycc", "ycc-mcp", "ycc-rules"), "user", self.model_version)
        self.assertEqual(self.marketplaces(), {"other": str(other), "ycc": str(exported)})
        self.assertEqual(self.state()["migrate_pending"], {})
        self.assertEqual((self.home / ".agents/skills/plan/SKILL.md").read_text(encoding="utf-8"), "mine")

        self.clear_log()
        self.assertIn("[ok] omp: no legacy state to retire", self.cleanup_ok().out)
        self.assertEqual(self.mutating(), [])

    def test_cleanup_then_repo_mode_and_package_selection_install_as_requested(self) -> None:
        repo = self.tmp / "repo-catalog"
        shutil.copytree(omp_install.ROOT / ".omp-plugin", repo / ".omp-plugin")
        shutil.copytree(omp_install.ROOT / "packages/omp", repo / "packages/omp")
        self.legacy_checkout_marketplace("ycc", "ycc-mcp")
        self.cleanup_ok()
        with patch.dict(os.environ, {"FAKE_OMP_REPO_CATALOG": str(repo)}):
            self.ok(
                "install", "--scope", "user", "--project-root", str(self.home), "--mode", "repo", "--packages", "ycc"
            )
        self.assertEqual(self.marketplaces(), {"ycc": omp_install.REPOSITORY})
        items = omp_install.ycc_items(self.listing(self.home), "user")
        self.assertEqual([item["id"] for item in items], ["ycc@ycc"])
        self.assertFalse(omp_install.export_dir().exists())
        self.assertEqual(self.state()["migrate_pending"], {})

    def test_cleanup_keeps_a_foreign_ycc_marketplace(self) -> None:
        foreign = make_fixture(self.tmp / "foreign", ("ycc",), "0.1.0")
        self.fake("plugin", "marketplace", "add", str(foreign))
        self.fake("plugin", "install", "--scope", "user", "ycc@ycc")
        before = self.snapshot()
        self.clear_log()
        for apply in (False, True):
            result = self.cleanup_ok(apply=apply)
            self.assertIn(f"[!!] kept marketplace ycc ({foreign}): foreign", result.out)
            self.assertIn("[ok] omp: no legacy state to retire", result.out)
        self.assertEqual(self.mutating(), [])
        self.assertEqual(self.snapshot(), before)

    def legacy_checkout_marketplace(self, *packages: str) -> None:
        """A checkout-root marketplace and installs from before the OMP catalog was listed (Claude packages)."""
        self.fake("plugin", "marketplace", "add", str(omp_install.ROOT), FAKE_OMP_CLAUDE_CATALOG="1")
        for package in packages:
            self.fake("plugin", "install", "--scope", "user", f"{package}@ycc", FAKE_OMP_CLAUDE_CATALOG="1")

    def test_cleanup_refuses_a_disabled_legacy_install_and_never_toggles_it(self) -> None:
        self.legacy_checkout_marketplace("ycc")
        self.fake("plugin", "disable", "--scope", "user", "ycc@ycc")
        before = self.snapshot()
        self.clear_log()
        for apply in (False, True):
            result = self.cleanup_refused(apply=apply)
            self.assertIn("ycc@ycc is disabled (user) and the native install would reinstall it enabled", result.err)
            self.assertIn("omp plugin uninstall --scope user ycc@ycc", result.err)
            self.assertIn("omp plugin disable --scope user ycc@ycc", result.err)
        self.assertEqual(self.mutating(), [])
        self.assertEqual(self.snapshot(), before)

    def test_cleanup_refuses_a_legacy_install_with_no_native_package(self) -> None:
        self.legacy_checkout_marketplace("ycc", "ycc-hooks")
        before = self.snapshot()
        self.clear_log()
        result = self.cleanup_refused()
        self.assertIn("ycc-hooks@ycc (user) has no native OMP package yet", result.err)
        self.assertEqual(self.mutating(), [])
        self.assertEqual(self.snapshot(), before)

    def test_cleanup_then_install_carries_a_legacy_ycc_and_ycc_mcp_pair_to_native(self) -> None:
        self.legacy_checkout_marketplace("ycc", "ycc-mcp")
        self.clear_log()
        self.cleanup_ok()
        self.install("user")
        calls = self.calls()
        for package in ("ycc", "ycc-mcp"):
            self.assertIn(f"omp plugin uninstall --scope user {package}@ycc", calls)
            self.assertIn(f"omp plugin install --scope user {package}@ycc", calls)
        self.assert_installed(("ycc", "ycc-mcp"), "user", self.model_version)
        self.assertEqual(self.marketplaces(), {"ycc": str(omp_install.export_dir())})

    def test_owed_install_survives_a_failed_native_install_until_one_succeeds(self) -> None:
        self.legacy_checkout_marketplace("ycc")
        self.cleanup_ok()
        owed = {self.profile_key(): [{"scope": "user", "project_root": None}]}
        with patch.dict(os.environ, {"FAKE_OMP_FAIL": "install:ycc@ycc"}):
            result = self.refused("install", "--scope", "user", "--project-root", str(self.home))
        self.assertIn("'omp plugin install --scope user ycc@ycc' failed (exit 1)", result.err)
        self.assertEqual(self.state()["migrate_pending"], owed)
        # A re-run of the cleanup reports the owed install again without retiring anything new.
        self.clear_log()
        self.assertIn("[ok] native OMP install owed (user scope)", self.cleanup_ok().out)
        self.assertEqual(self.mutating(), [])

        self.install("user")
        self.assert_installed(("ycc", "ycc-mcp", "ycc-rules"), "user", self.model_version)
        self.assertEqual(self.state()["migrate_pending"], {})
        self.clear_log()
        self.assertIn("[ok] omp: no legacy state to retire", self.cleanup_ok().out)
        self.assertEqual(self.mutating(), [])

    def test_owed_install_refuses_a_foreign_ycc_marketplace_before_any_change(self) -> None:
        self.legacy_checkout_marketplace("ycc")
        self.cleanup_ok()
        pending = self.state()["migrate_pending"]
        foreign = make_fixture(self.tmp / "foreign", ("ycc",), "0.1.0")
        self.fake("plugin", "marketplace", "add", str(foreign))
        before = self.snapshot()
        self.clear_log()
        self.cleanup_ok()
        result = self.refused("install", "--scope", "user", "--project-root", str(self.home))
        self.assertIn(f"marketplace ycc has a different source ({foreign})", result.err)
        self.assertEqual(self.mutating(), [])
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.state()["migrate_pending"], pending)

    def test_remove_keeps_a_ycc_install_now_served_by_a_foreign_marketplace(self) -> None:
        self.install("user")
        foreign = make_fixture(self.tmp / "foreign", ("ycc",), "0.1.0")
        self.fake("plugin", "marketplace", "remove", "ycc")
        self.fake("plugin", "marketplace", "add", str(foreign))
        self.fake("plugin", "install", "--force", "--scope", "user", "ycc@ycc")

        self.clear_log()
        result = self.remove("user")
        self.assertEqual(self.mutating(), [])
        self.assertIn(f"[!!] kept ycc@ycc (user): marketplace ycc now points at {foreign}", result.out)
        entry = self.entry("ycc", "user")
        assert entry is not None
        self.assertEqual(entry["version"], "0.1.0")
        self.assertEqual(self.marketplaces(), {"ycc": str(foreign)})
        self.assertFalse(omp_install.state_path().exists())

    def test_same_version_export_change_prints_the_force_hint(self) -> None:
        self.install("user")
        changed = Path(tempfile.mkdtemp(dir=self.tmp, prefix="source-edit."))
        shutil.copytree(self.source, changed, dirs_exist_ok=True)
        skill = next((changed / "packages/omp/ycc/skills").iterdir()) / "SKILL.md"
        skill.write_text(skill.read_text(encoding="utf-8") + "\nedited\n", encoding="utf-8")
        self.source = changed

        self.clear_log()
        result = self.install("user")
        self.assertIn("omp plugin marketplace update ycc", self.calls())
        self.assertIn("rerun with --force to reinstall it", result.out)
        self.assertNotIn("up to date", result.out)

        self.clear_log()
        self.install("user", "--force")
        self.assertIn("omp plugin install --force --scope user ycc@ycc", self.calls())

    def test_failed_export_swap_restores_the_previous_export(self) -> None:
        self.install("user")
        exported = omp_install.export_dir()
        previous = inventory(exported)
        self.bump(("ycc",))
        real_replace = os.replace

        def replace(src: Any, dst: Any) -> None:
            if ".staging." in str(src):
                raise OSError("swap interrupted")
            real_replace(src, dst)

        with patch.object(os, "replace", side_effect=replace):
            result = self.refused("install", "--scope", "user", "--project-root", str(self.home))
        self.assertIn("swap interrupted", result.err)
        self.assertEqual(inventory(exported), previous)
        self.assertEqual(self.state()["export_inventory"], previous)

    # -- coexistence (YAN-1176) ----------------------------------------------------------------

    W1 = (
        "[ok] OMP: hid 2 ycc duplicate skills (agents/…, codex/…) via skills.ignoredSkills in {cfg}; "
        "./install.sh remove --target omp --only dedupe restores them"
    )
    W2 = (
        "[!!] OMP also loads 1 ycc skills from ~/.agents/skills as agents/<name>; "
        "run ./install.sh install --target omp --only dedupe to hide them in OMP"
    )
    W3 = (
        "[!!] ~/.agents/skills/clean share ycc skill names but were not installed by ycc; "
        "OMP lists them as agents/<name> (left as is)"
    )
    W4 = (
        "[!!] enabledProviders includes claude: 1 ycc skills in ~/.claude/skills outrank the OMP package "
        "(it shows as ycc/<name>); retire them with ./install.sh sync --target claude --intent base "
        "(its legacy cleanup removes ycc-owned ~/.claude/skills copies), or drop claude from enabledProviders"
    )
    W5 = (
        "[!!] OMP also loads these skills; "
        "run ./install.sh install --target omp --only dedupe to hide the ~/.agents copies in OMP"
    )

    def test_coexistence_plan_hides_only_ledger_owned_differing_copies(self) -> None:
        self.agents_skill("plan", owned=True)
        self.agents_skill("clean", owned=False)  # user-authored: never hidden
        self.agents_skill("backport", owned=True, relative=".codex/skills")
        self.agents_skill("blueprint", owned=True, relative=".config/opencode/skills")
        shipped = (omp_install.ROOT / "packages/omp/ycc/skills/init/SKILL.md").read_text(encoding="utf-8")
        self.agents_skill("init", owned=True, text=shipped)  # identical: OMP drops it silently
        self.agents_skill("ycc-shared", owned=True)

        plan = omp_install.coexistence_plan(("ycc",), frozenset())

        self.assertEqual(plan.entries, ("agents/plan", "codex/backport", "opencode/blueprint"))
        self.assertEqual(plan.unowned, {"~/.agents/skills": ("clean",)})
        self.assertEqual(plan.claude, ())
        destination = self.tmp / "dedupe.yml"
        self.assertEqual(omp_install.coexistence_emit(("ycc",), destination), 3)
        self.assertEqual(
            json.loads(destination.read_text(encoding="utf-8")),
            {"skills": {"ignoredSkills": ["agents/plan", "codex/backport", "opencode/blueprint"]}},
        )

    def test_coexistence_without_a_ledger_or_overlap_writes_nothing(self) -> None:
        self.agents_skill("plan", owned=False)
        destination = self.tmp / "dedupe.yml"

        result = self.ok("coexistence", "--packages", "ycc", "--emit", str(destination))

        self.assertEqual(result.out, "0\n")
        self.assertFalse(destination.exists())

    def test_coexistence_warnings_have_the_exact_text(self) -> None:
        self.agents_skill("plan", owned=True)
        self.agents_skill("backport", owned=True, relative=".codex/skills")
        self.agents_skill("clean", owned=False)
        cfg = str(self.fake_root / "agent/config.yml")

        hidden = self.ok("coexistence", "--packages", "ycc", "--warn", "--hidden", cfg)
        self.assertEqual(hidden.out.splitlines(), [self.W1.format(cfg=cfg), self.W3])

        self.user_config({"skills": {"ignoredSkills": ["codex/*"]}})
        skipped = self.ok("coexistence", "--packages", "ycc", "--warn")
        self.assertEqual(skipped.out.splitlines(), [self.W2, self.W3])

        self.user_config({"skills": {"ignoredSkills": ["agents/plan", "codex/backport"]}, "enabledProviders": ["*"]})
        self.agents_skill("init", owned=True, relative=".claude/skills")
        claude = self.ok("coexistence", "--packages", "ycc", "--warn")
        self.assertEqual(claude.out.splitlines(), [self.W3, self.W4])

    def test_coexistence_dry_run_never_runs_omp(self) -> None:
        self.agents_skill("plan", owned=True)
        self.clear_log()

        result = self.ok("coexistence", "--packages", "ycc", "--warn", "--dry-run")

        self.assertIn(self.W2, result.out)
        self.assertIn("omp config get is not run", result.out)
        self.assertEqual(self.calls(), [])

    def test_agents_hint_only_when_omp_ycc_is_recorded_and_not_hidden(self) -> None:
        self.agents_skill("plan", owned=True)
        self.assertEqual(self.ok("coexistence", "--warn", "--if-installed").out, "")

        self.install("user")
        self.assertEqual(self.ok("coexistence", "--warn", "--if-installed").out, self.W5 + "\n")

        self.user_config({"skills": {"ignoredSkills": ["agents/plan"]}})
        self.assertEqual(self.ok("coexistence", "--warn", "--if-installed").out, "")

    def test_project_remove_deletes_the_empty_omp_residue(self) -> None:
        self.install("project")
        self.assertTrue((self.project / ".omp/plugins/installed_plugins.json").is_file())

        result = self.remove("project")

        self.assertIn(f"[ok] removed the empty omp project state under {self.project / '.omp'}", result.out)
        self.assertFalse((self.project / ".omp").exists())

    def test_project_remove_keeps_a_pre_existing_omp_dir(self) -> None:
        mine = self.project / ".omp/skills/plan/SKILL.md"
        mine.parent.mkdir(parents=True)
        mine.write_text("mine", encoding="utf-8")
        self.install("project")

        self.remove("project")

        self.assertEqual(mine.read_text(encoding="utf-8"), "mine")
        self.assertFalse((self.project / ".omp/plugins").exists())

    def test_project_remove_keeps_a_pre_existing_empty_omp_registry(self) -> None:
        registry = self.project / ".omp/plugins/installed_plugins.json"
        write_json(registry, {"version": 2, "plugins": {}})
        self.install("project")
        self.assertEqual(
            self.state()["project_residue"][str(self.project)],
            [".omp/plugins/omp-plugins.lock.json", ".omp/plugins/node_modules"],
        )

        self.remove("project")

        self.assertEqual(json.loads(registry.read_text(encoding="utf-8")), {"version": 2, "plugins": {}})
        self.assertFalse((self.project / ".omp/plugins/omp-plugins.lock.json").exists())
        self.assertFalse(omp_install.state_path().exists())

    def test_project_remove_after_a_partial_install_rollback_deletes_the_residue_ycc_created(self) -> None:
        self.use_fixture()
        mine = self.project / ".omp/skills/plan/SKILL.md"
        mine.parent.mkdir(parents=True)
        mine.write_text("mine", encoding="utf-8")
        with patch.dict(os.environ, {"FAKE_OMP_FAIL": "install:ycc-extra@ycc"}):
            self.refused("install", "--scope", "project", "--project-root", str(self.project))
        self.assertIsNotNone(self.record("ycc", "project"))
        self.assertEqual(
            self.state()["project_residue"][str(self.project)],
            [
                ".omp/plugins",
                ".omp/plugins/installed_plugins.json",
                ".omp/plugins/omp-plugins.lock.json",
                ".omp/plugins/node_modules",
            ],
        )

        self.remove("project")

        self.assertEqual(mine.read_text(encoding="utf-8"), "mine")
        self.assertFalse((self.project / ".omp/plugins").exists())
        self.assertFalse(omp_install.state_path().exists())

    def test_partial_install_rollback_drops_a_claimed_path_the_run_did_not_create(self) -> None:
        self.use_fixture()
        with patch.dict(os.environ, {"FAKE_OMP_FAIL": "install:ycc-extra@ycc", "FAKE_OMP_NO_NODE_MODULES": "1"}):
            self.refused("install", "--scope", "project", "--project-root", str(self.project))
        self.assertIsNotNone(self.record("ycc", "project"))
        self.assertFalse((self.project / ".omp/plugins/node_modules").exists())
        self.assertEqual(
            self.state()["project_residue"][str(self.project)],
            [
                ".omp",
                ".omp/plugins",
                ".omp/plugins/installed_plugins.json",
                ".omp/plugins/omp-plugins.lock.json",
            ],
        )

    def test_failed_first_project_install_restores_the_residue_record_to_its_prior_state(self) -> None:
        with patch.dict(os.environ, {"FAKE_OMP_FAIL": "install"}):
            self.refused("install", "--scope", "project", "--project-root", str(self.project))
        self.assertFalse(omp_install.state_path().exists())

    def user_skill_and_empty_registry(self) -> Path:
        """A root whose ``.omp`` and registry predate ycc: the first install records only lock and node_modules."""
        mine = self.project / ".omp/skills/plan/SKILL.md"
        mine.parent.mkdir(parents=True)
        mine.write_text("mine", encoding="utf-8")
        write_json(self.project / ".omp/plugins/installed_plugins.json", {"version": 2, "plugins": {}})
        return mine

    def test_a_later_project_install_extends_the_residue_record_with_what_it_recreates(self) -> None:
        mine = self.user_skill_and_empty_registry()
        self.install("project")
        shutil.rmtree(self.project / ".omp/plugins")

        self.install("project")

        self.assertEqual(
            self.state()["project_residue"][str(self.project)],
            [
                ".omp/plugins/omp-plugins.lock.json",
                ".omp/plugins/node_modules",
                ".omp/plugins",
                ".omp/plugins/installed_plugins.json",
            ],
        )
        self.remove("project")
        self.assertEqual(mine.read_text(encoding="utf-8"), "mine")
        self.assertFalse((self.project / ".omp/plugins").exists())

    def test_a_partial_later_project_install_keeps_the_extended_residue_record(self) -> None:
        self.use_fixture()
        mine = self.user_skill_and_empty_registry()
        self.install("project")
        shutil.rmtree(self.project / ".omp/plugins")

        with patch.dict(os.environ, {"FAKE_OMP_FAIL": "install:ycc-extra@ycc"}):
            self.refused("install", "--scope", "project", "--project-root", str(self.project))

        self.assertEqual(
            self.state()["project_residue"][str(self.project)],
            [
                ".omp/plugins/omp-plugins.lock.json",
                ".omp/plugins/node_modules",
                ".omp/plugins",
                ".omp/plugins/installed_plugins.json",
            ],
        )
        self.remove("project")
        self.assertEqual(mine.read_text(encoding="utf-8"), "mine")
        self.assertFalse((self.project / ".omp/plugins").exists())

    def test_a_later_project_install_never_claims_a_path_the_user_created_between_installs(self) -> None:
        self.user_skill_and_empty_registry()
        self.install("project")
        shutil.rmtree(self.project / ".omp/plugins")
        registry = self.project / ".omp/plugins/installed_plugins.json"
        write_json(registry, {"version": 2, "plugins": {}})

        self.install("project")

        self.assertEqual(
            self.state()["project_residue"][str(self.project)],
            [".omp/plugins/omp-plugins.lock.json", ".omp/plugins/node_modules"],
        )
        self.remove("project")
        self.assertEqual(json.loads(registry.read_text(encoding="utf-8")), {"version": 2, "plugins": {}})

    def test_a_no_op_project_install_drops_an_owned_path_it_did_not_recreate(self) -> None:
        self.install("project")
        shutil.rmtree(self.project / ".omp/plugins/node_modules")

        self.install("project")

        self.assertNotIn(".omp/plugins/node_modules", self.state()["project_residue"][str(self.project)])
        self.assertFalse((self.project / ".omp/plugins/node_modules").exists())

    def test_recorded_ignores_a_project_whose_root_was_deleted(self) -> None:
        self.install("project")
        self.install("user")
        self.assertEqual(self.omp("recorded", "--except-scope", "user", "--project-root", str(self.home)).code, 0)

        shutil.rmtree(self.project)

        self.assertEqual(self.omp("recorded", "--except-scope", "user", "--project-root", str(self.home)).code, 3)

    # -- rejection -----------------------------------------------------------------------------

    def test_every_non_included_omp_row_is_rejected_with_the_model_reason(self) -> None:
        model = load_package_model()
        rejected = [
            package.key
            for package in model.packages
            for runtime in package.runtimes
            if runtime.runtime == "omp"
            and not (runtime.status == "included" and runtime.mechanism == "native" and not runtime.opt_in)
        ]
        self.assertTrue({"ycc-hooks", "ycc-all", "installer-fallback"} <= set(rejected))
        self.assertNotIn("ycc-rules", rejected)
        self.assertNotIn("ycc-mcp", rejected)
        before = self.snapshot()
        for package in rejected:
            with self.subTest(package=package):
                with self.assertRaises(PackageModelError) as planned:
                    plan_install(model, (package,), ("omp",))
                result = self.refused(
                    "install", "--packages", package, "--scope", "user", "--project-root", str(self.home)
                )
                self.assertEqual(result.err, f"[err] native OMP install stopped: {planned.exception}\n")
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main()
