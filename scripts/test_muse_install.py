#!/usr/bin/env python3
"""Regressions for scripts/muse_install.py (owned copies, muse CLI calls, ownership)."""

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

import muse_install as helper  # noqa: E402
from owned_tree import place_copy  # noqa: E402

# A fake `muse plugins ...` that logs each call and keeps an installed-id list.
FAKE_MUSE = """#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$HOME/muse.log"
db="$HOME/muse-installed.txt"; touch "$db"
case "$1 $2" in
  "plugins list")
    python3 -c 'import json,sys; ids=[l.strip() for l in open(sys.argv[1]) if l.strip()];
print(json.dumps({"plugins":[{"plugin":{"id":i},"record":{"id":i}} for i in ids]}))' "$db" ;;
  "plugins install")
    name=$(python3 -c 'import json,os,sys
for m in (".claude-plugin/plugin.json",".muse-plugin/plugin.json"):
    p=os.path.join(sys.argv[1],m)
    if os.path.isfile(p): print(json.load(open(p))["name"]); break' "$3")
    grep -qx "$name" "$db" || echo "$name" >> "$db"; echo '{}' ;;
  "plugins approve") echo '{"decision":"approve"}' ;;
  "plugins remove")
    if grep -qx "$3" "$db"; then grep -vx "$3" "$db" > "$db.tmp" || true; mv "$db.tmp" "$db"; echo '{}';
    else echo '{"error":{"code":"unknown-plugin"}}'; exit 1; fi ;;
esac
"""


class InstallHelperTests(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.source = self.home / "src"
        for name, manifest in (("ycc", ".claude-plugin"), ("ycc-mcp", ".muse-plugin"), ("ycc-rules", ".muse-plugin")):
            root = self.source / name
            (root / manifest).mkdir(parents=True)
            (root / "skills/demo").mkdir(parents=True)
            (root / manifest / "plugin.json").write_text(json.dumps({"name": name}) + "\n", encoding="utf-8")
            (root / "skills/demo/SKILL.md").write_text(
                f"---\nname: demo\ndescription: {name}\n---\n"
                'Run "${HOME}/.local/share/ycc/muse/ycc/ycc-shared/run.sh".\n',
                encoding="utf-8",
            )
        fake = self.home / "bin/muse"
        fake.parent.mkdir()
        fake.write_text(FAKE_MUSE, encoding="utf-8")
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        env = {"HOME": str(self.home), "YCC_MUSE_BIN": str(fake)}
        patcher = mock.patch.dict(os.environ, env, clear=False)
        patcher.start()
        self.addCleanup(patcher.stop)
        for var in ("YCC_MUSE_PACKAGE_DIR", "YCC_MUSE_APPROVE"):
            os.environ.pop(var, None)
        self.copies = self.home / ".local/share/ycc/muse"

    def run_helper(self, *args: str) -> tuple[int, str]:
        out = io.StringIO()
        with redirect_stdout(out), redirect_stderr(out):
            code = helper.main([*args, "--source", str(self.source)])
        return code, out.getvalue()

    def log(self) -> list[str]:
        path = self.home / "muse.log"
        return path.read_text(encoding="utf-8").splitlines() if path.exists() else []

    def test_install_places_copies_installs_and_approves(self) -> None:
        code, out = self.run_helper("install")
        self.assertEqual(code, 0, out)
        for name in helper.PACKAGES:
            self.assertTrue((self.copies / name / "skills/demo/SKILL.md").is_file())
            self.assertIn(f"plugins install {self.copies / name} --scope user --json", self.log())
            self.assertIn(f"plugins approve {name} --json", self.log())
        state = json.loads(helper.state_path().read_text(encoding="utf-8"))
        self.assertEqual(set(state["packages"]), set(helper.PACKAGES))

    def test_second_install_is_up_to_date(self) -> None:
        self.run_helper("install")
        calls = len(self.log())
        code, out = self.run_helper("install")
        self.assertEqual(code, 0, out)
        self.assertEqual(out.count("is up to date"), len(helper.PACKAGES))
        self.assertEqual(self.log()[calls:], ["plugins list --json"])

    def test_project_scope_reinstalls_at_that_scope(self) -> None:
        self.run_helper("install", "--packages", "ycc")
        self.run_helper("install", "--packages", "ycc", "--scope", "project")
        self.assertIn(f"plugins install {self.copies / 'ycc'} --scope project --json", self.log())
        state = json.loads(helper.state_path().read_text(encoding="utf-8"))
        self.assertEqual(state["packages"]["ycc"]["scope"], "project")

    def test_no_approve_skips_review_decision(self) -> None:
        self.run_helper("install", "--no-approve")
        self.assertFalse(any("approve" in line for line in self.log()))

    def test_edited_copy_is_kept_without_force(self) -> None:
        self.run_helper("install")
        target = self.copies / "ycc/skills/demo/SKILL.md"
        target.write_text("edited\n", encoding="utf-8")
        code, out = self.run_helper("install", "--packages", "ycc")
        self.assertEqual(code, 1)
        self.assertIn("edited since ycc placed it", out)
        code, out = self.run_helper("remove", "--packages", "ycc")
        self.assertIn("kept ycc", out)
        self.assertTrue(target.exists())
        code, _ = self.run_helper("install", "--packages", "ycc", "--force")
        self.assertEqual(code, 0)
        self.assertNotEqual(target.read_text(encoding="utf-8"), "edited\n")

    def test_foreign_folder_is_refused_and_identical_adopted(self) -> None:
        (self.copies / "ycc").mkdir(parents=True)
        (self.copies / "ycc/mine.txt").write_text("user\n", encoding="utf-8")
        code, out = self.run_helper("install", "--packages", "ycc")
        self.assertEqual(code, 1)
        self.assertIn("not placed by ycc", out)
        place_copy(self.source / "ycc-mcp", self.copies / "ycc-mcp")
        code, out = self.run_helper("install", "--packages", "ycc-mcp")
        self.assertEqual(code, 0, out)

    def test_remove_uninstalls_and_deletes_owned_copies(self) -> None:
        self.run_helper("install")
        code, out = self.run_helper("remove")
        self.assertEqual(code, 0, out)
        for name in helper.PACKAGES:
            self.assertFalse((self.copies / name).exists())
            self.assertIn(f"plugins remove {name} --json", self.log())
        code, out = self.run_helper("remove")
        self.assertIn("nothing to remove", out)

    def test_relocated_copies_rewrite_helper_paths(self) -> None:
        moved = self.home / "elsewhere"
        os.environ["YCC_MUSE_PACKAGE_DIR"] = str(moved)
        self.run_helper("install", "--packages", "ycc")
        text = (moved / "ycc/skills/demo/SKILL.md").read_text(encoding="utf-8")
        self.assertIn(f"{moved.resolve()}/ycc/ycc-shared/run.sh", text)
        self.assertNotIn(".local/share/ycc/muse", text)

    def test_dry_run_changes_nothing(self) -> None:
        code, out = self.run_helper("install", "--dry-run")
        self.assertEqual(code, 0, out)
        self.assertIn("[dry-run] would run:", out)
        self.assertFalse(self.copies.exists())
        self.assertFalse(helper.state_path().exists())
        self.assertEqual(self.log(), [])

    def test_missing_muse_fails_closed(self) -> None:
        os.environ["YCC_MUSE_BIN"] = ""
        with mock.patch("shutil.which", return_value=None):
            code, out = self.run_helper("install")
        self.assertEqual(code, 1)
        self.assertIn("not on PATH", out)

    def test_unknown_package_is_a_usage_error(self) -> None:
        with self.assertRaises(SystemExit):
            helper.parse_packages("ycc,ycc-hooks")

    def test_plugin_id_reads_nested_rows(self) -> None:
        self.assertEqual(helper.plugin_id({"plugin": {"id": "a"}}), "a")
        self.assertEqual(helper.plugin_id({"record": {"id": "b"}, "plugin": {"id": "a"}}), "b")
        self.assertEqual(helper.plugin_id({}), "")


if __name__ == "__main__":
    unittest.main()
