#!/usr/bin/env python3
"""Tests for opencode_package.py: the one @yandy-r/ycc-opencode plugins entry."""

from __future__ import annotations

import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import opencode_package


class PackageEntryTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.dest = self.root / "opencode.json"
        state = self.root / "state.json"
        patcher = patch.object(opencode_package, "load_state", lambda: self.read_state())
        patcher.start()
        self.addCleanup(patcher.stop)
        saver = patch.object(opencode_package, "save_state", lambda data: self.write_state(data))
        saver.start()
        self.addCleanup(saver.stop)
        self.state_file = state

    def read_state(self) -> dict[str, object]:
        if not self.state_file.is_file():
            return {}
        data: dict[str, object] = json.loads(self.state_file.read_text(encoding="utf-8"))
        return data

    def write_state(self, data: dict[str, object]) -> None:
        self.state_file.write_text(json.dumps(data), encoding="utf-8")

    def run_cli(self, *args: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = opencode_package.main([*args, "--destination", str(self.dest)])
        return rc, out.getvalue()

    def plugins(self) -> list[object]:
        data = json.loads(self.dest.read_text(encoding="utf-8"))
        plugins: list[object] = data.get("plugins", [])
        return plugins

    def test_local_entry_written_and_rerun_idempotent(self) -> None:
        self.assertEqual(self.run_cli("sync")[0], 0)
        self.assertEqual(self.plugins(), [opencode_package.local_spec()])
        self.assertTrue(opencode_package.local_spec().startswith("file:///"))
        before = self.dest.read_bytes()
        rc, out = self.run_cli("sync")
        self.assertEqual(rc, 0)
        self.assertIn("up-to-date", out)
        self.assertEqual(self.dest.read_bytes(), before)

    def test_repo_entry_pins_the_product_version(self) -> None:
        self.assertEqual(self.run_cli("sync", "--mode", "repo")[0], 0)
        self.assertEqual(self.plugins(), [f"@yandy-r/ycc-opencode@{opencode_package.product_version()}"])

    def test_latest_entry_replaced_in_place_keeping_options_and_backing_up_jsonc(self) -> None:
        original = (
            '{\n  // mine\n  "plugins": ["@user/a", {"package": "@yandy-r/ycc-opencode@latest", "options": {"x": 1}},'
            ' "@user/b"],\n}\n'
        )
        self.dest.write_text(original, encoding="utf-8")
        self.dest.chmod(0o640)
        self.assertEqual(self.run_cli("sync")[0], 0)
        self.assertEqual(
            self.plugins(),
            ["@user/a", {"package": opencode_package.local_spec(), "options": {"x": 1}}, "@user/b"],
        )
        backup = self.dest.with_name("opencode.json.ycc-backup")
        self.assertEqual(backup.read_text(encoding="utf-8"), original)
        self.assertEqual(self.dest.stat().st_mode & 0o777, 0o640)

    def test_user_pinned_or_foreign_entries_are_kept_unless_forced(self) -> None:
        for spec in ("@yandy-r/ycc-opencode@6.0.0", "file:///other/checkout/packages/opencode/ycc-opencode"):
            with self.subTest(spec=spec):
                self.dest.write_text(json.dumps({"plugins": [spec]}), encoding="utf-8")
                before = self.dest.read_bytes()
                rc, out = self.run_cli("sync")
                self.assertEqual(rc, opencode_package.KEPT)
                self.assertIn("not written by ycc", out)
                self.assertEqual(self.dest.read_bytes(), before)
                self.assertEqual(self.read_state(), {})
                self.assertEqual(self.run_cli("sync", "--force")[0], 0)
                self.assertEqual(self.plugins(), [opencode_package.local_spec()])
                self.state_file.unlink()

    def test_present_entry_is_not_rewritten_or_claimed(self) -> None:
        self.dest.write_text(f'{{"plugins": ["{opencode_package.local_spec()}"] , }}', encoding="utf-8")
        before = self.dest.read_bytes()
        rc, out = self.run_cli("sync")
        self.assertEqual(rc, 0)
        self.assertIn("up-to-date", out)
        self.assertEqual(self.dest.read_bytes(), before)
        self.assertEqual(self.read_state(), {})

    def test_symlinked_config_is_refused_with_the_entry_to_add(self) -> None:
        real = self.root / "real.json"
        real.write_text("{}\n", encoding="utf-8")
        self.dest.symlink_to(real)
        rc, out = self.run_cli("sync")
        self.assertEqual(rc, opencode_package.REFUSED)
        self.assertIn(json.dumps(opencode_package.local_spec()), out)
        self.assertEqual(real.read_text(encoding="utf-8"), "{}\n")
        self.assertEqual(self.run_cli("remove")[0], opencode_package.REFUSED)

    def test_rollback_restores_bytes_and_mode(self) -> None:
        self.dest.write_text('{"plugins": []}\n', encoding="utf-8")
        self.dest.chmod(0o600)

        def fail(_: dict[str, object]) -> None:
            raise OSError("state write failed")

        with patch.object(opencode_package, "save_state", fail):
            self.assertEqual(self.run_cli("sync")[0], 1)
        self.assertEqual(self.dest.read_text(encoding="utf-8"), '{"plugins": []}\n')
        self.assertEqual(self.dest.stat().st_mode & 0o777, 0o600)

    def test_check_local_package_and_opencode_floor(self) -> None:
        with patch("shutil.which", lambda _: None):
            self.assertEqual(opencode_package.check("local"), 0)
            self.assertEqual(opencode_package.check("repo"), opencode_package.UNCONFIRMED)
        with patch.object(opencode_package, "PACKAGE_DIR", self.root / "missing"):
            self.assertEqual(opencode_package.check("local"), opencode_package.UNCONFIRMED)

    def test_remove_takes_back_only_the_entry_ycc_wrote(self) -> None:
        self.dest.write_text(json.dumps({"plugins": ["@user/a"], "model": "m"}), encoding="utf-8")
        self.run_cli("sync")
        self.assertEqual(self.run_cli("remove")[0], 0)
        self.assertEqual(json.loads(self.dest.read_text(encoding="utf-8")), {"plugins": ["@user/a"], "model": "m"})

    def test_remove_keeps_a_foreign_entry_without_force(self) -> None:
        self.dest.write_text(json.dumps({"plugins": ["@yandy-r/ycc-opencode@1.0.0"]}), encoding="utf-8")
        rc, out = self.run_cli("remove")
        self.assertEqual(rc, 0)
        self.assertIn("not written by ycc", out)
        self.assertEqual(self.plugins(), ["@yandy-r/ycc-opencode@1.0.0"])
        self.assertEqual(self.run_cli("remove", "--force")[0], 0)
        self.assertFalse(self.dest.exists())

    def test_remove_keeps_an_unowned_object_entry_without_force(self) -> None:
        item = {"package": "@yandy-r/ycc-opencode@6.3.0", "options": {"x": 1}}
        self.dest.write_text(json.dumps({"plugins": [item]}), encoding="utf-8")
        rc, out = self.run_cli("remove")
        self.assertEqual(rc, 0)
        self.assertIn("not written by ycc", out)
        self.assertEqual(self.plugins(), [item])
        self.assertEqual(self.run_cli("remove", "--force")[0], 0)
        self.assertFalse(self.dest.exists())

    def test_dry_run_writes_nothing(self) -> None:
        rc, out = self.run_cli("sync", "--dry-run")
        self.assertEqual(rc, 0)
        self.assertIn("would add", out)
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.state_file.exists())

    def test_is_ycc_package_shapes(self) -> None:
        ours = ("@yandy-r/ycc-opencode", "@yandy-r/ycc-opencode@latest", "npm:@yandy-r/ycc-opencode@6.0.0")
        for spec in ours:
            self.assertTrue(opencode_package.is_ycc_package(spec), spec)
        self.assertTrue(opencode_package.is_ycc_package({"package": opencode_package.local_spec()}))
        for spec in ("@yandy-r/ycc-opencode-extra", "@user/a", "./ycc-sensitive-guard"):
            self.assertFalse(opencode_package.is_ycc_package(spec), spec)


if __name__ == "__main__":
    os.environ.pop("YCC_MANAGED_CONFIG_STATE", None)
    unittest.main()
