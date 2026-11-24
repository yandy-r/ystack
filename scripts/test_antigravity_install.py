#!/usr/bin/env python3
"""Regressions for scripts/antigravity_install.py (copy and agy routes, ownership)."""

from __future__ import annotations

import io
import json
import os
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import antigravity_install as helper  # noqa: E402

FAKE_AGY = """#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$HOME/agy.log"
dir="$HOME/.gemini/config/plugins"
case "$1 $2" in
  "plugin install")
    name=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]+"/plugin.json"))["name"])' "$3")
    mkdir -p "$dir"; cp -R "$3" "$dir/$name"; chmod -R a-w "$dir/$name" ;;
  "plugin uninstall") chmod -R u+w "$dir/$3"; rm -rf "$dir/$3" ;;
esac
"""


class InstallHelperTests(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.source = self.home / "src"
        for name in helper.PACKAGES:
            root = self.source / name
            (root / "skills/demo").mkdir(parents=True)
            (root / "plugin.json").write_text(json.dumps({"name": name}) + "\n", encoding="utf-8")
            (root / "skills/demo/SKILL.md").write_text(
                f"---\nname: demo\ndescription: {name}\n---\n"
                "Run `${HOME}/.gemini/config/plugins/ycc/ycc-shared/run.sh`.\n",
                encoding="utf-8",
            )
        patcher = mock.patch.dict(os.environ, {"HOME": str(self.home)}, clear=False)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("YCC_ANTIGRAVITY_CONFIG_DIR", None)
        os.environ.pop("YCC_ANTIGRAVITY_AGY", None)
        self.plugins = self.home / ".gemini/config/plugins"

    def run_helper(self, *args: str) -> tuple[int, str]:
        out = io.StringIO()
        with redirect_stdout(out), redirect_stderr(out):
            code = helper.main([*args, "--source", str(self.source)])
        return code, out.getvalue()

    def make_fake_agy(self) -> Path:
        agy = self.home / "bin/agy"
        agy.parent.mkdir()
        agy.write_text(FAKE_AGY, encoding="utf-8")
        agy.chmod(0o755)
        return agy

    def test_copy_install_is_idempotent_and_removable(self) -> None:
        code, _ = self.run_helper("install", "--no-agy")
        self.assertEqual(code, 0)
        for name in helper.PACKAGES:
            self.assertTrue((self.plugins / name / "plugin.json").is_file())
        code, out = self.run_helper("install", "--no-agy")
        self.assertEqual(code, 0)
        self.assertEqual(out.count("is up to date"), len(helper.PACKAGES))
        code, _ = self.run_helper("remove", "--no-agy")
        self.assertEqual(code, 0)
        self.assertEqual(list(self.plugins.iterdir()), [])
        state = json.loads(helper.state_path().read_text(encoding="utf-8"))
        self.assertEqual(state["packages"], {})

    def test_foreign_plugin_folder_is_refused_without_force(self) -> None:
        foreign = self.plugins / "ycc"
        foreign.mkdir(parents=True)
        (foreign / "plugin.json").write_text('{"name": "ycc", "mine": true}\n', encoding="utf-8")
        code, out = self.run_helper("install", "--no-agy", "--packages", "ycc")
        self.assertEqual(code, 1)
        self.assertIn("not installed by ycc", out)
        self.assertIn('"mine"', (foreign / "plugin.json").read_text(encoding="utf-8"))
        code, out = self.run_helper("remove", "--no-agy", "--packages", "ycc")
        self.assertEqual(code, 0)
        self.assertIn("kept ycc", out)
        self.assertTrue(foreign.is_dir())
        code, _ = self.run_helper("install", "--no-agy", "--packages", "ycc", "--force")
        self.assertEqual(code, 0)
        self.assertNotIn('"mine"', (foreign / "plugin.json").read_text(encoding="utf-8"))

    def test_identical_copy_is_adopted(self) -> None:
        self.plugins.mkdir(parents=True)
        helper.place_copy(self.source / "ycc-mcp", self.plugins / "ycc-mcp")
        code, out = self.run_helper("install", "--no-agy", "--packages", "ycc-mcp")
        self.assertEqual(code, 0)
        self.assertIn("installed ycc-mcp", out)

    def test_edited_copy_is_kept_on_remove(self) -> None:
        self.run_helper("install", "--no-agy", "--packages", "ycc-rules")
        (self.plugins / "ycc-rules/notes.md").write_text("mine\n", encoding="utf-8")
        code, out = self.run_helper("remove", "--no-agy", "--packages", "ycc-rules")
        self.assertEqual(code, 0)
        self.assertIn("edited since ycc placed it", out)
        self.assertTrue((self.plugins / "ycc-rules/notes.md").is_file())

    def test_dry_run_changes_nothing(self) -> None:
        code, out = self.run_helper("install", "--no-agy", "--dry-run")
        self.assertEqual(code, 0)
        self.assertIn("[dry-run] would copy", out)
        self.assertFalse(self.plugins.exists())
        self.assertFalse(helper.state_path().exists())

    def test_agy_route_installs_and_uninstalls_read_only_copies(self) -> None:
        os.environ["YCC_ANTIGRAVITY_AGY"] = str(self.make_fake_agy())
        code, _ = self.run_helper("install", "--packages", "ycc")
        self.assertEqual(code, 0)
        staged = self.plugins / "ycc/plugin.json"
        self.assertTrue(staged.is_file())
        self.assertFalse(staged.stat().st_mode & stat.S_IWUSR)
        code, out = self.run_helper("install", "--packages", "ycc")
        self.assertIn("is up to date", out)
        code, _ = self.run_helper("remove", "--packages", "ycc")
        self.assertEqual(code, 0)
        self.assertFalse((self.plugins / "ycc").exists())
        log = (self.home / "agy.log").read_text(encoding="utf-8").splitlines()
        self.assertEqual(log, [f"plugin install {(self.source / 'ycc').resolve()}", "plugin uninstall ycc"])

    def test_edited_agy_install_is_kept_on_remove(self) -> None:
        os.environ["YCC_ANTIGRAVITY_AGY"] = str(self.make_fake_agy())
        self.assertEqual(self.run_helper("install", "--packages", "ycc")[0], 0)
        installed = self.plugins / "ycc"
        installed.chmod(0o755)
        (installed / "notes.md").write_text("mine\n", encoding="utf-8")
        code, out = self.run_helper("remove", "--packages", "ycc")
        self.assertEqual(code, 0)
        self.assertIn("edited since ycc placed it", out)
        self.assertTrue((installed / "notes.md").is_file())
        code, out = self.run_helper("install", "--packages", "ycc")
        self.assertEqual(code, 1)
        self.assertIn("edited since ycc placed it", out)

    def test_unknown_package_is_a_usage_error(self) -> None:
        with self.assertRaises(SystemExit):
            self.run_helper("install", "--packages", "ycc-hooks")

    def test_config_dir_override(self) -> None:
        custom = self.home / "custom-config"
        os.environ["YCC_ANTIGRAVITY_CONFIG_DIR"] = str(custom)
        self.addCleanup(os.environ.pop, "YCC_ANTIGRAVITY_CONFIG_DIR", None)
        code, _ = self.run_helper("install", "--no-agy", "--packages", "ycc")
        self.assertEqual(code, 0)
        self.assertTrue((custom / "plugins/ycc/plugin.json").is_file())
        skill = (custom / "plugins/ycc/skills/demo/SKILL.md").read_text(encoding="utf-8")
        self.assertIn(f"{(custom / 'plugins').resolve()}/ycc/ycc-shared/run.sh", skill)
        self.assertNotIn(".gemini/config", skill)

    def test_config_dir_override_refuses_the_agy_route(self) -> None:
        os.environ["YCC_ANTIGRAVITY_CONFIG_DIR"] = str(self.home / "custom-config")
        self.addCleanup(os.environ.pop, "YCC_ANTIGRAVITY_CONFIG_DIR", None)
        os.environ["YCC_ANTIGRAVITY_AGY"] = str(self.make_fake_agy())
        code, out = self.run_helper("install", "--packages", "ycc")
        self.assertEqual(code, 1)
        self.assertIn("needs the copy route", out)
        self.assertFalse((self.home / "agy.log").exists())


if __name__ == "__main__":
    unittest.main()
