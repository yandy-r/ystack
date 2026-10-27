#!/usr/bin/env python3
"""Ownership and TOML preflight regressions for the native Codex installer."""

from __future__ import annotations

import io
import json
import shutil
import sys
import tempfile
import tomllib
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

import codex_install as installer
import merge_managed_config as managed_config

MERGE_CONFIG = installer.merge_config
SHIPPED = (
    'model = "m"\n\n'
    '[plugins."github@openai-curated"]\nenabled = true\n\n'
    '[plugins."ycc@local-ycc-plugins"]\nenabled = true\n\n'
    '[plugins."cloudflare@openai-curated"]\nenabled = true\n'
)


class NativeInstallSafetyTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "repo"
        self.home = Path(temporary.name) / "home"
        self.home.mkdir()
        for name, value in (
            ("ROOT", self.root),
            ("repository_native_enabled", lambda packages: True),
            ("load_package_model", lambda: type("Model", (), {"packages": ()})()),
            ("validate", lambda *args, **kwargs: None),
            ("merge_config", lambda *args, **kwargs: None),
        ):
            patcher = patch.object(installer, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(Path, "home", return_value=self.home)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.version("1.0.0")

    def version(self, version: str) -> None:
        for package in installer.MIGRATION_PACKAGES:
            root = self.root / ".codex-plugin" / package
            (root / ".codex-plugin").mkdir(parents=True, exist_ok=True)
            (root / ".codex-plugin/plugin.json").write_text(json.dumps({"name": package, "version": version}))
            (root / "payload").write_text(version)

    def cli(self, *args: str, **kwargs: object) -> str:
        if args[:2] != ("plugin", "add"):
            return ""
        package = args[2].split("@")[0]
        source = self.root / ".codex-plugin" / package
        version = json.loads((source / ".codex-plugin/plugin.json").read_text())["version"]
        cache = self.home / ".codex/plugins/cache/ycc" / package / version
        if cache.exists():
            shutil.rmtree(cache)
        shutil.copytree(source, cache)
        return self.report(package, version, cache)

    @staticmethod
    def report(package: str, version: str, cache: Path) -> str:
        """Mirror real `codex plugin add <pkg>@ycc --json` stdout (codex-cli 0.163.0)."""
        return json.dumps(
            {
                "pluginId": f"{package}@ycc",
                "name": package,
                "marketplaceName": "ycc",
                "version": version,
                "installedPath": str(cache),
                "authPolicy": "ON_INSTALL",
            }
        )

    def snapshot(self) -> dict[str, bytes]:
        return {str(path.relative_to(self.home)): path.read_bytes() for path in self.home.rglob("*") if path.is_file()}

    def test_cli_upgrade_rejects_edited_old_version_before_any_mutation(self) -> None:
        with patch.object(installer, "cli", side_effect=self.cli):
            installer.install("local", True)
        old = self.home / ".codex/plugins/cache/ycc/ycc/1.0.0/payload"
        old.write_text("my edit")
        self.version("2.0.0")
        before = self.snapshot()
        with patch.object(installer, "cli") as cli:
            with self.assertRaisesRegex(ValueError, "edited or foreign"):
                installer.install("local", True)
            cli.assert_not_called()
        self.assertEqual(self.snapshot(), before)
        installer.remove(False)
        self.assertEqual(old.read_text(), "my edit")

    def test_cli_upgrade_keeps_original_fingerprint_for_untouched_versions(self) -> None:
        with patch.object(installer, "cli", side_effect=self.cli):
            installer.install("local", True)
            original = installer.load_state()["caches"]
            self.version("2.0.0")
            installer.install("local", True)
        current = installer.load_state()["caches"]
        for key, fingerprint in original.items():
            self.assertEqual(current[key], fingerprint)
        self.assertEqual(len(current), 4)

    def test_cli_upgrade_keeps_recorded_snapshot_edited_while_cli_runs(self) -> None:
        """An edit to a recorded older snapshot during `plugin add` is never adopted as ours."""
        old = self.home / ".codex/plugins/cache/ycc/ycc/1.0.0/payload"

        def editing_cli(*args: str, **kwargs: object) -> str:
            output = self.cli(*args, **kwargs)
            if args[:3] == ("plugin", "add", "ycc@ycc"):
                old.write_text("my edit")
            return output

        with patch.object(installer, "cli", side_effect=self.cli):
            installer.install("local", True)
        original = installer.load_state()["caches"]["plugins/cache/ycc/ycc/1.0.0"]
        self.version("2.0.0")
        with patch.object(installer, "cli", side_effect=editing_cli):
            installer.install("local", True)
        self.assertEqual(installer.load_state()["caches"]["plugins/cache/ycc/ycc/1.0.0"], original)
        with patch.object(installer, "cli", return_value=""):
            installer.remove(True)
        self.assertEqual(old.read_text(), "my edit")

    def test_cli_unproven_output_records_no_new_snapshot(self) -> None:
        def silent_cli(*args: str, **kwargs: object) -> str:
            self.cli(*args, **kwargs)
            return "not json"

        with patch.object(installer, "cli", side_effect=silent_cli):
            installer.install("local", True)
        self.assertEqual(installer.load_state()["caches"], {})

    def test_cli_version_differing_from_checkout_refreshes_and_removes_cleanly(self) -> None:
        """`--mode repo` can fetch another version than the checkout; repeated installs must track it."""

        def fetching_cli(*args: str, **kwargs: object) -> str:
            if args[:2] != ("plugin", "add"):
                return ""
            package = args[2].split("@")[0]
            cache = self.home / ".codex/plugins/cache/ycc" / package / "1.0.1"
            if cache.exists():
                shutil.rmtree(cache)
            (cache / ".codex-plugin").mkdir(parents=True)
            (cache / ".codex-plugin/plugin.json").write_text(json.dumps({"name": package, "version": "1.0.1"}))
            (cache / "payload").write_text(self.fetched)
            return self.report(package, "1.0.1", cache)

        with patch.object(installer, "cli", side_effect=fetching_cli):
            for self.fetched in ("first", "second", "third"):
                installer.install("repo", True)
            for package in installer.MIGRATION_PACKAGES:
                key = f"plugins/cache/ycc/{package}/1.0.1"
                self.assertEqual(
                    installer.load_state()["caches"][key],
                    installer.inventory(self.home / ".codex" / key),
                )
            installer.remove(True)
        self.assertFalse((self.home / ".codex/plugins/cache/ycc").exists())
        self.assertFalse(installer.state_path().exists())

    def test_fallback_refuses_closed_inline_marketplaces_without_mutation(self) -> None:
        config = self.home / ".codex/config.toml"
        config.parent.mkdir()
        text = 'marketplaces = { foreign = { source_type = "local", source = "/foreign" } }\n'
        config.write_text(text)
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "closed inline table"):
            installer.install("local", False)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(tomllib.loads(config.read_text())["marketplaces"]["foreign"]["source"], "/foreign")

    def test_verified_toml_rejects_invalid_text_without_writing(self) -> None:
        config = self.home / "config.toml"
        config.write_text("model = 'mine'\n")
        with self.assertRaisesRegex(ValueError, "cannot update"):
            installer.write_verified_toml(config, "[broken")
        self.assertEqual(config.read_text(), "model = 'mine'\n")

    def test_remove_dry_run_previews_owned_caches_and_marketplace_without_writes(self) -> None:
        installer.install("local", False)
        before = self.snapshot()
        paths = set(self.home.rglob("*"))
        out = io.StringIO()
        with (
            patch.object(installer, "cli") as cli,
            patch.object(installer, "merge_config") as merge,
            redirect_stdout(out),
        ):
            installer.remove(True, dry_run=True)
        cli.assert_not_called()
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(set(self.home.rglob("*")), paths)
        for package in installer.MIGRATION_PACKAGES:
            cache = self.home / ".codex/plugins/cache/ycc" / package / "1.0.0"
            self.assertIn(f"would remove native cache {cache}", out.getvalue())
        self.assertIn("would remove /marketplaces/ycc", out.getvalue())
        self.assertIn("would remove ownership state", out.getvalue())
        self.assertTrue(merge.call_args.kwargs["dry_run"])

    def test_remove_dry_run_retains_edited_and_foreign_snapshots(self) -> None:
        installer.install("local", False)
        cache_root = self.home / ".codex/plugins/cache/ycc"
        (cache_root / "ycc/1.0.0/payload").write_text("my edit")
        foreign = cache_root / "ycc-mcp/9.9.9"
        foreign.mkdir()
        (foreign / "payload").write_text("foreign")
        before = self.snapshot()
        out = io.StringIO()
        with patch.object(installer, "merge_config") as merge, redirect_stdout(out):
            installer.remove(False, dry_run=True)
        self.assertEqual(self.snapshot(), before)
        self.assertIn("edited or foreign native snapshot", out.getvalue())
        self.assertIn("kept marketplace ycc", out.getvalue())
        self.assertNotIn("would remove /marketplaces/ycc", out.getvalue())
        merge.assert_not_called()

    def test_remove_dry_run_without_state_creates_nothing(self) -> None:
        with patch.object(installer, "merge_config") as merge, patch.object(installer, "cli") as cli:
            installer.remove(True, dry_run=True)
        merge.assert_not_called()
        cli.assert_not_called()
        self.assertEqual(list(self.home.iterdir()), [])


class NativeSettingsSelectionTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / ".codex-plugin/config").mkdir(parents=True)
        (self.root / ".codex-plugin/config/config.toml").write_text(SHIPPED, encoding="utf-8")
        patcher = patch.object(installer, "ROOT", self.root)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_main(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with (
            patch.object(sys, "argv", ["codex_install.py", *argv]),
            redirect_stdout(out),
            redirect_stderr(err),
        ):
            code = installer.main()
        return code, out.getvalue(), err.getvalue()

    def test_list_entries_prints_native_plugin_keys(self) -> None:
        with patch.object(installer, "merge_config") as merge:
            code, out, _ = self.run_main("settings", "--groups", "plugins", "--list-entries")
        self.assertEqual(code, 0)
        self.assertEqual(out.split(), ["github@openai-curated", "cloudflare@openai-curated", "ycc@ycc", "ycc-mcp@ycc"])
        merge.assert_not_called()

    def test_entries_narrow_only_the_plugins_group(self) -> None:
        with patch.object(installer.subprocess, "run") as run:
            with patch.object(installer, "merge_config", MERGE_CONFIG):
                code, _, err = self.run_main(
                    "settings", "--groups", "settings,plugins", "--remove", "--entries", "cloudflare@openai-curated"
                )
        self.assertEqual(code, 0, err)
        command = run.call_args.args[0]
        self.assertEqual(command[command.index("--groups") + 1], "settings,plugins")
        self.assertEqual(command[command.index("--entry-groups") + 1], "plugins")
        self.assertEqual(command[command.index("--entries") + 1], "cloudflare@openai-curated")
        self.assertIn("--remove", command)

    def test_settings_dry_run_forwards_selection_and_removal(self) -> None:
        for remove in (False, True):
            with self.subTest(remove=remove), patch.object(installer.subprocess, "run") as run:
                with patch.object(installer, "merge_config", MERGE_CONFIG):
                    args = ["settings", "--groups", "plugins", "--entries", "ycc@ycc", "--dry-run"]
                    if remove:
                        args.append("--remove")
                    code, _, err = self.run_main(*args)
                self.assertEqual(code, 0, err)
                command = run.call_args.args[0]
                self.assertIn("--dry-run", command)
                self.assertEqual("--remove" in command, remove)
                self.assertEqual(command[command.index("--entries") + 1], "ycc@ycc")

    def test_settings_dry_run_reports_changes_without_config_state_or_backups(self) -> None:
        home = self.root / "home"
        home.mkdir()
        destination = home / ".codex/config.toml"
        state = home / ".config/ycc/managed-config-state.json"

        def merge_in_process(command: list[str], *, check: bool) -> None:
            with patch.object(sys, "argv", command[1:]), patch.object(managed_config, "STATE_PATH", state):
                self.assertEqual(managed_config.main(), 0)

        with (
            patch.object(Path, "home", return_value=home),
            patch.object(installer, "merge_config", MERGE_CONFIG),
            patch.object(installer.subprocess, "run", side_effect=merge_in_process),
        ):
            code, out, err = self.run_main("settings", "--groups", "settings", "--dry-run")
            self.assertEqual(code, 0, err)
            self.assertIn("would set /model", out)
            self.assertEqual(list(home.iterdir()), [])
            code, _, err = self.run_main("settings", "--groups", "settings")
            self.assertEqual(code, 0, err)
            before = {path: path.read_bytes() for path in home.rglob("*") if path.is_file()}
            paths = set(home.rglob("*"))
            code, out, err = self.run_main("settings", "--groups", "settings", "--remove", "--dry-run")
            self.assertEqual(code, 0, err)
            self.assertIn("would remove /model", out)
        self.assertTrue(destination.is_file())
        self.assertTrue(state.is_file())
        self.assertEqual({path: path.read_bytes() for path in home.rglob("*") if path.is_file()}, before)
        self.assertEqual(set(home.rglob("*")), paths)

    def test_native_install_dry_run_is_rejected_before_installing(self) -> None:
        with patch.object(installer, "install") as install:
            code, _, err = self.run_main("install", "--dry-run")
        self.assertEqual(code, 2)
        self.assertIn("does not support --dry-run", err)
        install.assert_not_called()

    def test_remove_dry_run_is_forwarded(self) -> None:
        with patch.object(installer, "remove") as remove:
            code, _, err = self.run_main("remove", "--dry-run")
        self.assertEqual(code, 0, err)
        remove.assert_called_once_with(False, dry_run=True)

    def test_without_entries_all_native_keys_are_selected(self) -> None:
        with patch.object(installer, "merge_config") as merge:
            installer.settings("settings,plugins", remove=False, force=False)
        groups, text, entries = merge.call_args.args
        self.assertEqual(entries, ["github@openai-curated", "cloudflare@openai-curated", "ycc@ycc", "ycc-mcp@ycc"])
        self.assertNotIn("local-ycc-plugins", text)

    def test_settings_group_alone_passes_no_entries(self) -> None:
        with patch.object(installer, "merge_config") as merge:
            installer.settings("settings", remove=False, force=False)
        self.assertIsNone(merge.call_args.args[2])

    def test_unknown_or_unselectable_plugins_exit_2_without_merging(self) -> None:
        cases = (
            ("--groups", "plugins", "--entries", "ycc@local-ycc-plugins"),
            ("--groups", "settings", "--entries", "ycc@ycc"),
            ("--groups", "plugins", "--entries", ","),
        )
        for args in cases:
            with self.subTest(args=args), patch.object(installer, "merge_config") as merge:
                code, _, err = self.run_main("settings", *args)
                self.assertEqual(code, 2)
                self.assertIn("unknown plugins", err)
                merge.assert_not_called()


if __name__ == "__main__":
    unittest.main()
