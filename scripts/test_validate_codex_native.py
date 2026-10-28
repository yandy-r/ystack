#!/usr/bin/env python3
"""Fixture-based structural checks for Codex catalogs, without running Codex."""

from __future__ import annotations

import contextlib
import copy
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import codex_marketplace as marketplace
import generate_codex_plugin as generator
import install_migrate as migrate
import install_slices as slices
import validate_codex_native as validator
from generate_codex_skills import write_tree
from package_model import PackageModel, load_package_model


class CodexMarketplaceSchemaTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.path = self.root / generator.NATIVE_MARKETPLACE

    @staticmethod
    def catalog(source: object | None = None) -> dict:
        return {
            "name": "fixture",
            "plugins": [{"name": "fixture-plugin", "source": source or {"source": "local", "path": "./plugin"}}],
        }

    def write_catalog(self, catalog: object) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(catalog), encoding="utf-8")

    def assert_invalid_catalog(self, catalog: object, message: str) -> None:
        with self.assertRaisesRegex(ValueError, message):
            validator.check_catalog_structure(catalog, self.path)

    def test_supported_source_shapes_are_read_only(self) -> None:
        sources = (
            {"source": "local", "path": "./.codex-plugin/native"},
            {"source": "url", "url": "https://example.invalid/plugin.git"},
            {"source": "url", "url": "owner/repo", "path": "plugin", "sha": "immutable"},
            {"source": "git-subdir", "url": "https://example.invalid/fixture.git", "path": "./plugin", "ref": "main"},
            {
                "source": "npm",
                "package": "@fixture/plugin",
                "version": "^1.0.0",
                "registry": "https://registry.npmjs.org",
            },
        )
        for source in sources:
            with self.subTest(source=source):
                before = copy.deepcopy(source)
                self.assertIs(marketplace.validate_marketplace_source(source), source)
                validator.check_catalog_structure(self.catalog(source), self.path)
                self.assertEqual(source, before)

    def test_source_tag_and_shape_failures(self) -> None:
        cases = (
            ("./plugin", "source must be an object"),
            ({}, "source tag must be a string"),
            ({"source": []}, "source tag must be a string"),
            ({"source": "github", "repo": "owner/repo"}, "unsupported source tag 'github'"),
            ({"source": "local"}, "missing required source fields"),
            ({"source": "local", "path": None}, "missing required source fields"),
            ({"source": "local", "path": 7}, "path.*non-empty string"),
            ({"source": "local", "path": " "}, "path.*non-empty string"),
            ({"source": "local", "path": "/absolute"}, "path must start with"),
            ({"source": "local", "path": "./../escape"}, "marketplace root"),
            ({"source": "local", "path": "./plugin", "url": "https://example.invalid"}, "unsupported source fields"),
            ({"source": "url"}, "missing required source fields"),
            ({"source": "url", "url": False}, "url.*non-empty string"),
            ({"source": "url", "url": "not-a-git-source"}, "supported git source"),
            ({"source": "url", "url": "./../escape.git"}, "relative url.*marketplace root"),
            ({"source": "url", "url": "../escape.git"}, "relative url.*marketplace root"),
            ({"source": "url", "url": "..\\escape.git"}, "relative url.*marketplace root"),
            ({"source": "git-subdir", "url": "../escape.git", "path": "plugin"}, "relative url.*marketplace root"),
            ({"source": "url", "url": "https://example.invalid/plugin.git", "ref": []}, "ref.*must be a string"),
            ({"source": "git-subdir", "url": "https://example.invalid/fixture.git"}, "missing required source fields"),
            (
                {"source": "git-subdir", "url": "https://example.invalid/fixture.git", "path": []},
                "path.*non-empty",
            ),
            (
                {"source": "git-subdir", "url": "https://example.invalid/fixture.git", "path": "../escape"},
                "repository root",
            ),
            ({"source": "npm"}, "missing required source fields"),
            ({"source": "npm", "package": "@scope"}, "invalid package name"),
            ({"source": "npm", "package": "plugin", "version": "file:./local"}, "version must use the registry"),
            (
                {"source": "npm", "package": "plugin", "registry": "http://registry.example.invalid"},
                "registry must be an HTTPS URL",
            ),
            (
                {"source": "npm", "package": "plugin", "registry": "https://registry.example.invalid?next=1"},
                "registry must be an HTTPS URL",
            ),
            (
                {"source": "npm", "package": "plugin", "registry": "https://registry.example.invalid#readme"},
                "registry must be an HTTPS URL",
            ),
            ({"source": "npm", "package": "plugin", "registry": "https://registry.example.invalid?"}, "registry"),
            ({"source": "npm", "package": "plugin", "registry": "https://registry.example.invalid#"}, "registry"),
            (
                {"source": "npm", "package": "plugin", "registry": "https://host:notaport"},
                "registry port must be a valid port number",
            ),
            (
                {"source": "npm", "package": "plugin", "registry": "https://registry.example.invalid:99999"},
                "registry port must be a valid port number",
            ),
            (
                {"source": "npm", "package": "plugin", "registry": "https://registry.example .invalid"},
                "registry must name a valid host",
            ),
            (
                {"source": "npm", "package": "plugin", "registry": "https://host:notaport/99999/space"},
                "registry port must be a valid port number",
            ),
            ({"source": "url", "url": "owner/.git"}, "supported git source"),
            ({"source": "url", "url": "owner/"}, "supported git source"),
            ({"source": "git-subdir", "url": "owner/.git", "path": "plugin"}, "supported git source"),
            (
                {"source": "npm", "package": "plugin", "registry": "https://registry.example%20.invalid"},
                "registry must name a valid host",
            ),
        )
        for source, message in cases:
            with self.subTest(source=source):
                # Do not use the fixture's default source for the deliberately empty object.
                catalog = {"name": "fixture", "plugins": [{"name": "fixture-plugin", "source": source}]}
                self.assert_invalid_catalog(catalog, message)

    def test_catalog_structural_failures(self) -> None:
        entry = self.catalog()["plugins"][0]
        cases = (
            ([], "catalog must be a JSON object"),
            ({"plugins": []}, "name must be a non-empty string"),
            ({"name": [], "plugins": []}, "name must be a non-empty string"),
            ({"name": "fixture"}, "plugins must be a list"),
            ({"name": "fixture", "plugins": {}}, "plugins must be a list"),
            ({"name": "fixture", "plugins": [None]}, "expected an object"),
            ({"name": "fixture", "plugins": [{"name": []}]}, "name must be a non-empty string"),
            ({"name": "fixture", "plugins": [entry, entry]}, "duplicate plugin name"),
            ({"name": "fixture", "plugins": [], "interface": []}, "interface must be an object"),
            ({"name": "fixture", "plugins": [], "interface": {"displayName": 2}}, "displayName.*non-empty string"),
            ({"name": "fixture", "plugins": [{**entry, "policy": []}]}, "policy must be an object"),
            (
                {"name": "fixture", "plugins": [{**entry, "policy": {"installation": []}}]},
                "invalid policy installation",
            ),
            (
                {"name": "fixture", "plugins": [{**entry, "policy": {"authentication": "INVALID"}}]},
                "invalid policy authentication",
            ),
            ({"name": "fixture", "plugins": [{**entry, "category": []}]}, "category.*non-empty string"),
        )
        for catalog, message in cases:
            with self.subTest(catalog=catalog):
                self.assert_invalid_catalog(catalog, message)

    def test_catalog_diagnostic_includes_path(self) -> None:
        with self.assertRaises(ValueError) as caught:
            validator.check_catalog_structure({"name": "fixture", "plugins": [{"name": "bad"}]}, self.path)
        self.assertIn(str(self.path), str(caught.exception))
        self.assertIn("bad", str(caught.exception))

    def test_emitted_builders_remain_valid_and_unchanged(self) -> None:
        model = load_package_model()
        legacy = generator.build_repo_marketplace()
        self.assertEqual(legacy["plugins"][0]["source"], {"source": "local", "path": "./plugins/ycc"})
        native = generator.build_native_marketplace(model.packages, include_unlisted=True)
        repository = generator.build_repository_marketplace(model.packages)
        unlisted = self.model_with_listed()
        self.assertEqual(generator.build_native_marketplace(unlisted.packages)["plugins"], [])
        self.assertEqual(generator.build_repository_marketplace(unlisted.packages), legacy)
        for catalog in (legacy, native, repository):
            before = copy.deepcopy(catalog)
            validator.check_catalog_structure(catalog, self.path)
            self.assertEqual(catalog, before)
        for mode, path in (("local", "./.agents/plugins/ycc"), ("repo", "")):
            with self.subTest(mode=mode):
                entry = marketplace.build_entry(mode, path)
                self.assertEqual(entry["source"]["source"], "local" if mode == "local" else "git-subdir")
                validator.check_catalog_structure({"name": "fixture", "plugins": [entry]}, self.path)

    def test_installer_builder_rejects_traversing_source_before_writes(self) -> None:
        with self.assertRaisesRegex(ValueError, "marketplace root"):
            marketplace.merge(self.path, "local", "./../escape")
        self.assertFalse(self.path.exists())

    def test_native_gate_checks_structure_before_model_equality(self) -> None:
        self.write_catalog({"name": "ycc", "plugins": [{"name": [], "source": {"source": "github"}}]})
        with self.assertRaisesRegex(ValueError, "name must be a non-empty string"):
            validator.check_catalog(self.root, ())

    def test_native_gate_still_requires_exact_model_catalog(self) -> None:
        self.write_catalog({"name": "ycc", "plugins": [], "unexpected": "drift"})
        with self.assertRaisesRegex(ValueError, "model-driven native catalog"):
            validator.check_catalog(self.root, ())

    def test_legacy_gate_checks_structure_and_preserves_exact_equality(self) -> None:
        manifest_path = self.root / ".codex-plugin/ycc/.codex-plugin/plugin.json"
        manifest_path.parent.mkdir(parents=True)
        manifest = {"name": "ycc", "version": "1.0.0"}
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        mcp_path = self.root / ".codex-plugin/ycc/.mcp.json"
        mcp_path.write_text('{"mcpServers": {}}', encoding="utf-8")
        with (
            patch.object(validator, "load_package_model", return_value=SimpleNamespace(packages=())),
            patch.object(generator, "native_version", return_value="1.0.0"),
            patch.object(generator, "build_plugin_manifest", return_value=manifest),
        ):
            catalog = generator.build_repo_marketplace()
            self.write_catalog(catalog)
            validator.validate(self.root, native=False)
            broken = copy.deepcopy(catalog)
            broken["plugins"][0]["source"] = {"source": "github", "repo": "owner/repo"}
            self.write_catalog(broken)
            with self.assertRaisesRegex(ValueError, "unsupported source tag 'github'"):
                validator.validate(self.root, native=False)
            catalog["interface"]["displayName"] = "Changed but structurally valid"
            self.write_catalog(catalog)
            with self.assertRaisesRegex(ValueError, "legacy discovered catalog changed"):
                validator.validate(self.root, native=False)

    @staticmethod
    def model_with_listed(*names: str) -> PackageModel:
        model = load_package_model()
        listed = set(names)
        packages = tuple(
            replace(
                package,
                runtimes=tuple(
                    replace(entry, listed=package.key in listed) if entry.runtime == "codex" else entry
                    for entry in package.runtimes
                ),
            )
            for package in model.packages
        )
        return replace(model, packages=packages)

    def test_repository_validator_and_migration_gate_follow_listing_state(self) -> None:
        for listed in (("ycc", "ycc-mcp"),):
            with self.subTest(listed=listed), tempfile.TemporaryDirectory() as tmp:
                repo, export = Path(tmp) / "repo", Path(tmp) / "export"
                model = self.model_with_listed(*listed)
                with (
                    patch.object(generator, "load_package_model", return_value=model),
                    patch.object(validator, "load_package_model", return_value=model),
                    patch.object(migrate, "load_package_model", return_value=model),
                ):
                    generator.write_all(repo, dry_run=False)
                    self.assertEqual(generator.run_check(repo), 0)
                    validator.validate(repo, native=False)
                    migrate.codex_eligible(repo)
                    # An explicit external export includes unlisted packages and stays eligible.
                    generator.generate_native_tree(export)
                    validator.validate(export, native=True)
                    migrate.codex_eligible(export, external=True)

    def test_partial_listing_is_rejected_and_never_flips_the_repository(self) -> None:
        for listed in (("ycc",), ("ycc-mcp",)):
            with self.subTest(listed=listed), tempfile.TemporaryDirectory() as tmp:
                repo, export = Path(tmp) / "repo", Path(tmp) / "export"
                model = self.model_with_listed(*listed)
                with (
                    patch.object(generator, "load_package_model", return_value=model),
                    patch.object(validator, "load_package_model", return_value=model),
                    patch.object(migrate, "load_package_model", return_value=model),
                ):
                    generator.write_all(repo, dry_run=False)
                    # Legacy output survives, including the combined ycc payload with MCP.
                    self.assertEqual(
                        validator.load_json(repo / generator.NATIVE_MARKETPLACE), generator.build_repo_marketplace()
                    )
                    self.assertTrue((repo / ".codex-plugin/ycc/.mcp.json").is_file())
                    with self.assertRaisesRegex(ValueError, "partial Codex listing is not allowed"):
                        validator.validate(repo, native=False)
                    with self.assertRaisesRegex(ValueError, "native catalog not listed"):
                        migrate.codex_eligible(repo)
                    # An explicit export stays opt-in and eligible regardless of listing.
                    generator.generate_native_tree(export)
                    validator.validate(export, native=True)
                    migrate.codex_eligible(export, external=True)
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            unlisted = self.model_with_listed()
            with (
                patch.object(generator, "load_package_model", return_value=unlisted),
                patch.object(validator, "load_package_model", return_value=unlisted),
                patch.object(migrate, "load_package_model", return_value=unlisted),
            ):
                generator.write_all(repo, dry_run=False)
                validator.validate(repo, native=False)
                with self.assertRaisesRegex(ValueError, "native catalog not listed"):
                    migrate.codex_eligible(repo)


class CodexListedMigrationTransitionTests(unittest.TestCase):
    """Preflip combined artifacts must be retired against a listed, skills-only canonical tree."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        self.home, self.legacy_repo, self.repo = base / "home", base / "legacy", base / "repo"
        self.home.mkdir()
        real_root = migrate.ROOT
        unlisted = CodexMarketplaceSchemaTests.model_with_listed()
        self.listed = CodexMarketplaceSchemaTests.model_with_listed(*migrate.PACKAGES)
        # Exact preflip bytes: combined manifest, MCP payload, legacy-path skills.
        with patch.object(generator, "load_package_model", return_value=unlisted):
            generator.write_all(self.legacy_repo, dry_run=False)
        write_tree(self.legacy_repo / ".codex-plugin/ycc", False, native_paths=False)
        self.legacy = self.legacy_repo / ".codex-plugin/ycc"
        self.canonical = self.repo / ".codex-plugin/ycc"
        self.canonical.parent.mkdir(parents=True)
        shutil.copytree(self.legacy, self.canonical, symlinks=True)
        (self.repo / "ycc").symlink_to(real_root / "ycc")
        self.flipped = False

        real_run = subprocess.run

        def fake_codex(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
            if command[0] != "codex":
                return real_run(command, **kwargs)  # type: ignore[call-overload]
            args = command[1:-1]
            version = generator.native_version(self.listed)
            rows = [
                {"pluginId": f"{package}@ycc", "installed": True, "enabled": True, "version": version}
                for package in migrate.PACKAGES
            ]
            if args[:3] == ["plugin", "marketplace", "add"]:
                payload: dict = {"marketplaceName": "ycc"}
            elif args[:2] == ["plugin", "list"]:
                payload = {"available": [], "installed": rows}
            else:
                payload = {}
            return subprocess.CompletedProcess(command, 0, stdout=json.dumps(payload), stderr="")

        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch.object(migrate, "ROOT", self.repo))
        stack.enter_context(patch.object(slices, "REPO_ROOT", self.repo))
        git_env = {
            "HOME": str(self.home),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }
        # Drop inherited GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE/... (exported by hooks) so
        # fixture git commands can never reach an outer repository; restored on exit.
        isolated = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        stack.enter_context(patch.dict(os.environ, {**isolated, **git_env}, clear=True))
        stack.enter_context(patch.object(migrate, "load_package_model", return_value=self.listed))
        stack.enter_context(patch.object(migrate.Migration, "merge_remove"))
        stack.enter_context(patch.object(migrate.subprocess, "run", side_effect=fake_codex))

    @property
    def skills(self) -> Path:
        return self.home / ".codex/skills"

    @property
    def cache(self) -> Path:
        return self.home / ".codex/plugins/cache/local-ycc-plugins/ycc"

    def install_standalone(self) -> list[str]:
        """Install every skill as a preflip installer would, in all recognized forms."""
        self.flip_listing()
        historical = [
            ("~/.codex/plugins/ycc/skills/", "~/.codex/skills/"),
            ("~/.codex/plugins/ycc/shared/", "~/.codex/skills/_shared/"),
            ("../../../shared/", "../../_shared/"),
            ("../../shared/references/", "../_shared/references/"),
            ("<installed ycc plugin root>/shared/references/", f"{self.home}/.codex/skills/_shared/references/"),
        ]
        pattern = slices.namespace_pattern("codex")
        self.skills.mkdir(parents=True)
        names = sorted(path.name for path in (self.legacy / "skills").iterdir())
        raw_canonical, raw_legacy = names[0], names[1]
        shutil.copytree(self.canonical / "skills" / raw_canonical, self.skills / raw_canonical, symlinks=True)
        shutil.copytree(self.legacy / "skills" / raw_legacy, self.skills / raw_legacy, symlinks=True)
        for name in names[2:]:
            slices.stage(name, self.legacy / "skills" / name, self.skills, historical, pattern)
        slices.stage("_shared", self.legacy / "shared", self.skills, historical, pattern)
        return names

    def install_legacy_plugin(self) -> None:
        for relative in (".codex/plugins/ycc", ".agents/plugins/ycc"):
            link = self.home / relative
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(self.canonical)

    @staticmethod
    def snapshot(root: Path) -> dict[str, bytes | str]:
        return {
            str(path.relative_to(root)): os.readlink(path) if path.is_symlink() else path.read_bytes()
            for path in sorted(root.rglob("*"))
            if path.is_symlink() or path.is_file()
        }

    def flip_listing(self) -> None:
        if self.flipped:
            return
        with patch.object(generator, "load_package_model", return_value=self.listed):
            generator.write_all(self.repo, dry_run=False)
        self.flipped = True
        self.assertTrue((self.legacy / ".mcp.json").is_file())
        self.assertFalse((self.canonical / ".mcp.json").exists())
        self.assertNotEqual(
            (self.legacy / ".codex-plugin/plugin.json").read_bytes(),
            (self.canonical / ".codex-plugin/plugin.json").read_bytes(),
        )

    def migrate_codex(self, *, apply: bool = True) -> str:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.flip_listing()
            migrate.Migration(apply).codex(self.repo, True)
        return out.getvalue()

    def older_release(self, version: str = "5.3.0") -> Path:
        """Return a preflip tree from an older release the current checkout can no longer render."""
        old = self.home.parent / f"release-{version}"
        shutil.copytree(self.legacy, old, symlinks=True)
        manifest = old / ".codex-plugin/plugin.json"
        data = json.loads(manifest.read_text(encoding="utf-8"))
        data["version"] = version
        manifest.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        skill = sorted((old / "skills").iterdir())[0] / "SKILL.md"
        with skill.open("a", encoding="utf-8") as handle:
            handle.write(f"\nrelease {version} wording\n")
        return old

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True, text=True).stdout

    def commit_release(self, *trees: Path) -> None:
        """Record each tree, in order, as a past .codex-plugin/ycc commit, keeping the work tree."""
        aside = self.home.parent / "aside"
        self.canonical.rename(aside)
        self.git("init", "-q")
        for tree in trees:
            shutil.copytree(tree, self.canonical, symlinks=True)
            # An empty index forces re-hashing: copytree keeps mtimes and same-size
            # releases may reuse inodes, so a stat-clean index could skip changes.
            self.git("read-tree", "--empty")
            self.git("add", "-f", ".codex-plugin/ycc")
            self.git("commit", "-q", "-m", f"release {tree.name}")
            committed = self.git("rev-parse", "HEAD:.codex-plugin/ycc").strip()
            self.assertEqual(committed, migrate.git_tree_id(tree, "sha1"))
            shutil.rmtree(self.canonical)
        aside.rename(self.canonical)

    def test_same_checkout_upgrade_retires_untouched_older_snapshot_and_rerun_is_stable(self) -> None:
        # YAN-1216: `codex plugin add` cached 5.3.0 before the flip; the checkout has since moved on.
        old = self.older_release()
        self.commit_release(old)
        self.cache.mkdir(parents=True)
        shutil.copytree(old, self.cache / "5.3.0", symlinks=True)
        out = self.migrate_codex()
        self.assertNotIn("kept", out)
        self.assertIn(f"remove {self.cache / '5.3.0'}", out)
        self.assertIn(f"remove {self.cache}\n", out)
        self.assertFalse(self.cache.exists())
        before = self.snapshot(self.home)
        rerun = self.migrate_codex()
        self.assertNotIn("kept", rerun)
        self.assertNotIn(str(self.cache), rerun)
        self.assertEqual(self.snapshot(self.home), before)

    def test_edited_older_snapshot_and_its_cache_are_kept_on_every_run(self) -> None:
        old = self.older_release()
        self.commit_release(old)
        edited = self.cache / "5.3.0"
        self.cache.mkdir(parents=True)
        shutil.copytree(old, edited, symlinks=True)
        (edited / "skills/mine.md").write_text("mine\n", encoding="utf-8")
        before = self.snapshot(self.home)
        for _ in range(2):
            out = self.migrate_codex()
            self.assertIn(f"kept {edited}: edited or ownership uncertain", out)
            self.assertNotIn(f"remove {self.cache}\n", out)
            self.assertEqual(self.snapshot(self.home), before)

    def test_older_snapshot_is_kept_when_git_history_is_unavailable(self) -> None:
        old = self.older_release()
        self.cache.mkdir(parents=True)
        shutil.copytree(old, self.cache / "5.3.0", symlinks=True)
        out = self.migrate_codex()
        self.assertTrue((self.cache / "5.3.0/.codex-plugin/plugin.json").is_file())
        self.assertIn("git history unavailable", out)
        self.assertIn(f"kept {self.cache / '5.3.0'}", out)

    def test_pre_boundary_snapshot_in_shallow_checkout_is_kept_with_unshallow_hint(self) -> None:
        # Only the newest release is inside a depth-1 clone; the older one is beyond its boundary.
        older, newer = self.older_release("5.3.0"), self.older_release("5.4.0")
        self.commit_release(older, newer)
        clone = self.home.parent / "shallow"
        self.git("clone", "-q", "--depth", "1", f"file://{self.repo}", str(clone))
        real_released = migrate.released_codex_trees
        self.assertTrue(real_released(clone).shallow)
        self.cache.mkdir(parents=True)
        shutil.copytree(older, self.cache / "5.3.0", symlinks=True)
        shutil.copytree(newer, self.cache / "5.4.0", symlinks=True)
        with patch.object(migrate, "released_codex_trees", lambda _root: real_released(clone)):
            out = self.migrate_codex()
        self.assertIn(
            f"kept {self.cache / '5.3.0'}: not in this shallow checkout's history; "
            "run 'git fetch --unshallow' and rerun migrate",
            out,
        )
        self.assertTrue((self.cache / "5.3.0/.codex-plugin/plugin.json").is_file())
        self.assertIn(f"remove {self.cache / '5.4.0'}", out)
        self.assertFalse((self.cache / "5.4.0").exists())
        self.assertNotIn(f"remove {self.cache}\n", out)

    def test_exact_preflip_flat_cache_links_and_standalone_skills_retire(self) -> None:
        names = self.install_standalone()
        self.install_legacy_plugin()
        self.cache.parent.mkdir(parents=True)
        shutil.copytree(self.legacy, self.cache, symlinks=True)
        self.assertEqual(sorted(path.name for path in self.skills.iterdir()), sorted([*names, "_shared"]))
        before = self.snapshot(self.home)
        self.migrate_codex(apply=False)
        self.assertEqual(self.snapshot(self.home), before)
        out = self.migrate_codex()
        self.assertNotIn("kept", out)
        self.assertEqual(list(self.skills.iterdir()), [])
        self.assertFalse(self.cache.exists())
        for relative in (".codex/plugins/ycc", ".agents/plugins/ycc"):
            self.assertFalse((self.home / relative).is_symlink())
        self.assertTrue(migrate.Migration.merge_remove.called)

    def test_versioned_cache_retires_exact_snapshots_and_keeps_edited_or_foreign(self) -> None:
        exact, edited = self.cache / "exact", self.cache / "edited"
        self.cache.mkdir(parents=True)
        shutil.copytree(self.legacy, exact, symlinks=True)
        shutil.copytree(self.legacy, edited, symlinks=True)
        (edited / ".mcp.json").write_text('{"mcpServers": {"mine": {}}}\n', encoding="utf-8")
        (self.cache / "foreign").mkdir()
        (self.cache / "foreign/README").write_text("mine\n", encoding="utf-8")
        out = self.migrate_codex()
        self.assertFalse(exact.exists())
        self.assertTrue((edited / ".mcp.json").is_file())
        self.assertTrue((self.cache / "foreign/README").is_file())
        self.assertIn(f"kept {edited}", out)
        self.assertIn(f"kept {self.cache / 'foreign'}", out)

    def test_canonical_skills_only_cache_retires_and_combined_snapshot_missing_mcp_is_kept(self) -> None:
        # The canonical skills-only tree stays recognized (post-flip caches), and a
        # combined tree missing .mcp.json is a user edit that must be kept.
        trimmed = self.cache / "trimmed"
        current = self.cache / "current"
        self.cache.mkdir(parents=True)
        shutil.copytree(self.legacy, trimmed, symlinks=True)
        (trimmed / ".mcp.json").unlink()
        self.flip_listing()
        shutil.copytree(self.canonical, current, symlinks=True)
        self.migrate_codex()
        self.assertTrue(trimmed.is_dir())
        self.assertFalse(current.exists())

    def test_pre_fix_legacy_installs_retire_with_current_fixture(self) -> None:
        # Releases before the SC2088 quoted-home fix installed the expand_home=False
        # render (quoted "~/.codex/" fallbacks). Those standalone copies and the flat
        # cache must still be recognized and retired by migrate.
        pre_fix = self.home.parent / "pre-fix"
        write_tree(pre_fix, False, native_paths=False, expand_home=False)
        for relative in (".codex-plugin/plugin.json",):
            source = self.legacy / relative
            target = pre_fix / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
        shutil.copyfile(self.legacy / ".mcp.json", pre_fix / ".mcp.json")
        names = sorted(path.name for path in (pre_fix / "skills").iterdir())
        self.skills.mkdir(parents=True)
        # Older installers projected the plugin paths: alternate the current and the
        # historical rewrite sets, as install_standalone does.
        rewrite_sets = migrate.codex_rewrite_sets(self.home)
        pattern = slices.namespace_pattern("codex")
        for index, name in enumerate(names):
            slices.stage(name, pre_fix / "skills" / name, self.skills, rewrite_sets[index % 2], pattern)
        slices.stage("_shared", pre_fix / "shared", self.skills, rewrite_sets[0], pattern)
        projected = (self.skills / "git-workflow/scripts/create-pr.sh").read_text(encoding="utf-8")
        self.assertIn('"~/.codex/skills/_shared/scripts/lib/forge.sh"', projected)
        self.cache.parent.mkdir(parents=True)
        shutil.copytree(pre_fix, self.cache, symlinks=True)
        out = self.migrate_codex()
        self.assertNotIn("kept", out)
        self.assertEqual(list(self.skills.iterdir()), [])
        self.assertFalse(self.cache.exists())

    def test_edited_and_foreign_standalone_skills_are_kept_with_shared_helpers(self) -> None:
        names = self.install_standalone()
        edited = names[2]
        with (self.skills / edited / "SKILL.md").open("a", encoding="utf-8") as handle:
            handle.write("\nlocal edit\n")
        (self.skills / "mine").mkdir()
        (self.skills / "mine/SKILL.md").write_text("mine\n", encoding="utf-8")
        out = self.migrate_codex()
        self.assertIn("local edit", (self.skills / edited / "SKILL.md").read_text(encoding="utf-8"))
        self.assertTrue((self.skills / "mine/SKILL.md").is_file())
        self.assertTrue((self.skills / "_shared").is_dir())
        self.assertIn(f"kept {self.skills / edited}", out)
        self.assertIn("retained entries may depend on it", out)
        self.assertEqual(sorted(path.name for path in self.skills.iterdir()), sorted([edited, "mine", "_shared"]))

    def test_symlinked_skills_parent_and_foreign_links_are_never_traversed(self) -> None:
        self.install_legacy_plugin()
        (self.home / ".codex/plugins/ycc").unlink()
        (self.home / ".codex/plugins/ycc").symlink_to(self.home / "foreign")
        real = self.home / "real-skills"
        real.mkdir()
        shutil.copytree(self.legacy / "skills", real / "all", symlinks=True)
        (self.home / ".codex").mkdir(exist_ok=True)
        self.skills.symlink_to(real)
        before = self.snapshot(real)
        out = self.migrate_codex()
        self.assertEqual(self.snapshot(real), before)
        self.assertTrue((self.home / ".codex/plugins/ycc").is_symlink())
        self.assertIn("kept", out)
        self.assertFalse((self.home / ".agents/plugins/ycc").is_symlink())


if __name__ == "__main__":
    unittest.main()
