#!/usr/bin/env python3
"""Behavioral tests for scripts/rename-repo.sh and scripts/rename_repo.py.

Most tests copy the wrapper and engine into a disposable root, populate the
fixed allowlist plus decoy files outside it, and drive the real CLI. One test
runs the checkout's own CLI in dry-run mode to prove every allowlisted file is
covered, and asserts it changes nothing.

Run directly (``python3 scripts/test_rename_repo.py``) or through
``./scripts/validate.sh --only inventory``.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

SCRIPTS_DIR = Path(__file__).resolve().parent
WRAPPER_SRC = SCRIPTS_DIR / "rename-repo.sh"
ENGINE_SRC = SCRIPTS_DIR / "rename_repo.py"

OLD = "yandy-r/claude-plugins"
NEW = "yandy-r/ystack"
TOKEN = "@@SLUG@@"

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_PREFLIGHT = 3

# (relative path, file mode, line ending, trailing newline, extra raw bytes line)
ALLOWLIST_SPECS: list[tuple[str, int, str, bool, bytes | None]] = [
    ("README.md", 0o644, "\r\n", True, None),
    (".claude-plugin/marketplace.json", 0o644, "\n", True, None),
    (".github/ISSUE_TEMPLATE/config.yml", 0o644, "\n", True, None),
    ("docs/install/codex.md", 0o644, "\n", True, b"# raw \xff\xfe bytes, not UTF-8"),
    ("install.sh", 0o755, "\n", False, None),
    ("scripts/codex_install.py", 0o755, "\r\n", False, None),
    ("scripts/generate_codex_plugin.py", 0o755, "\n", True, None),
    ("scripts/generate_opencode_package.py", 0o644, "\n", True, None),
    ("scripts/test_generate_opencode_package.py", 0o644, "\n", True, None),
    ("docs/install/v6/README.md", 0o644, "\n", True, None),
    ("docs/install/v6/claude.md", 0o644, "\n", True, None),
    ("ycc/skills/_shared/references/target-capability-matrix.md", 0o644, "\n", True, None),
    ("scripts/lib/install/targets/claude.sh", 0o750, "\n", True, None),
    ("scripts/lib/install/targets/cursor.sh", 0o755, "\n", True, None),
    ("ycc/mods/.claude-plugin/marketplace.json", 0o640, "\n", True, None),
    ("ycc/settings/settings.json", 0o600, "\n", True, None),
]
ALLOWLIST = [spec[0] for spec in ALLOWLIST_SPECS]

# Lines the rename must rewrite.
POSITIVE = [
    f"https://github.com/{TOKEN}",
    f"https://github.com/{TOKEN}.git",
    f"https://github.com/{TOKEN}/issues/304?q=1#frag",
    f"git@github.com:{TOKEN}.git",
    f"ssh://git@github.com/{TOKEN}.git",
    f'"repo": "{TOKEN}",',
    f"gh repo clone {TOKEN}",
    f"marketplace add ({TOKEN})",
]

# Lines the rename must leave byte-identical.
NEGATIVE = [
    "official marketplace: yandy-r/claude-plugins-official",
    "fork: yandy-r/claude-plugins.fork",
    "partial owner: xyandy-r/claude-plugins and yandy-r2/claude-plugins",
    "longer: yandy-r/claude-plugins2 yandy-r/claude-plugins_x yandy-r/claude-pluginsX",
    "https://github.com/yandy-r/claude-plugins-official.git",
    "local path: /home/yandy/Projects/github.com/yandy-r/claude-plugins",
    "local worktree: /home/yandy/Projects/github.com/yandy-r/claude-plugins/.claude/worktrees/claude-plugins-x",
    "preserved: ycc:init ycc@ycc ycc-mods ${CLAUDE_PLUGIN_ROOT}",
    "# claude-plugins",
    "claude-plugins/",
]

# Files outside the allowlist that mention the slug; none may change.
OUTSIDE_FILES = [
    "docs/releases/5.0.0.md",
    "docs/plans/rename/plan.md",
    "docs/inventory.json",
    ".codex-plugin/ycc/README.md",
    ".agents/plugins/marketplace.json",
    "packages/claude/ycc/.claude-plugin/plugin.json",
    "ycc/skills/init/SKILL.md",
    "ycc/mods/README.md",
    "scripts/other_tool.py",
    "CONTRIBUTING.md",
    ".git/config",
    ".claude/worktrees/foo/README.md",
    ".claude/worktrees/foo/install.sh",
    ".claude/worktrees/foo/.claude-plugin/marketplace.json",
]


def tok(text: str, slug: str) -> str:
    return text.replace(TOKEN, slug)


def allowlist_lines(path: str, slug: str) -> list[str]:
    own = f"{path}: https://github.com/{slug}.git"
    return [f"# fixture {path}", own, *[tok(line, slug) for line in POSITIVE], *NEGATIVE]


def render(spec: tuple[str, int, str, bool, bytes | None], slug: str) -> bytes:
    path, _mode, eol, final_nl, raw = spec
    chunks = [line.encode() for line in allowlist_lines(path, slug)]
    if raw is not None:
        chunks.insert(2, raw)
    data = eol.encode().join(chunks)
    return data + eol.encode() if final_nl else data


def outside_text(path: str, slug: str) -> bytes:
    lines = [f"# decoy {path}", *[tok(line, slug) for line in POSITIVE], *NEGATIVE]
    return ("\n".join(lines) + "\n").encode()


Snapshot = dict[str, tuple[Any, ...]]


def snapshot(root: Path) -> Snapshot:
    """Record every entry under root, without following symlinks."""
    result: Snapshot = {}

    def walk(directory: Path) -> None:
        with os.scandir(directory) as it:
            entries = sorted(it, key=lambda e: e.name)
        for entry in entries:
            rel = str(Path(entry.path).relative_to(root))
            st = entry.stat(follow_symlinks=False)
            mode = stat.S_IMODE(st.st_mode)
            if entry.is_symlink():
                result[rel] = ("link", os.readlink(entry.path))
            elif entry.is_dir(follow_symlinks=False):
                result[rel] = ("dir", mode)
                walk(Path(entry.path))
            elif entry.is_file(follow_symlinks=False):
                result[rel] = ("file", mode, Path(entry.path).read_bytes())
            else:
                result[rel] = ("other", stat.S_IFMT(st.st_mode))

    walk(root)
    return result


def write_file(path: Path, data: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)


def diff_lines(stdout: str) -> list[str]:
    return [line.rstrip("\r") for line in stdout.split("\n")]


class RenameRepoTestCase(unittest.TestCase):
    def make_root(self, slug: str = OLD, populate: bool = True) -> Path:
        tmp = tempfile.TemporaryDirectory(prefix="rename-repo-test-")
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name).resolve() / "repo"
        (root / "scripts").mkdir(parents=True)
        shutil.copy2(WRAPPER_SRC, root / "scripts" / "rename-repo.sh")
        shutil.copy2(ENGINE_SRC, root / "scripts" / "rename_repo.py")
        (root / "scripts" / "rename-repo.sh").chmod(0o755)
        if populate:
            for spec in ALLOWLIST_SPECS:
                write_file(root / spec[0], render(spec, slug), spec[1])
            for rel in OUTSIDE_FILES:
                write_file(root / rel, outside_text(rel, slug))
        return root

    def run_cli(
        self,
        root: Path,
        *args: str,
        cwd: Path | None = None,
        env_extra: dict[str, str] | None = None,
        umask: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = {k: v for k, v in os.environ.items() if k not in {"REPO_ROOT", "ROOT"}}
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env.update(env_extra or {})

        def set_umask() -> None:
            if umask is not None:
                os.umask(umask)

        return subprocess.run(
            [str(root / "scripts" / "rename-repo.sh"), *args],
            cwd=str(cwd or root.parent),
            env=env,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=60,
            preexec_fn=set_umask,
        )

    def rename(self, root: Path, *extra: str, frm: str = OLD, to: str = NEW, **kwargs: Any):
        return self.run_cli(root, "--from", frm, "--to", to, *extra, **kwargs)

    def expected_snapshot(self, before: Snapshot, slug: str) -> Snapshot:
        """The pre-run snapshot with every allowlist file rewritten for slug."""
        expected = dict(before)
        for spec in ALLOWLIST_SPECS:
            old = before[spec[0]]
            expected[spec[0]] = ("file", old[1], render(spec, slug))
        return expected

    def assert_snapshot_equal(self, actual: Snapshot, expected: Snapshot) -> None:
        self.assertEqual(sorted(actual), sorted(expected))
        for rel in expected:
            self.assertEqual(actual[rel], expected[rel], rel)


class DryRunTests(RenameRepoTestCase):
    def test_dry_run_prints_full_diff_and_writes_nothing(self) -> None:
        root = self.make_root()
        before = snapshot(root)
        result = self.rename(root, "--dry-run")
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)
        self.assert_snapshot_equal(snapshot(root), before)

        lines = diff_lines(result.stdout)
        line_set = set(lines)
        missing = []
        for path in ALLOWLIST:
            self.assertTrue(any(path in line for line in lines), f"no diff mentions {path}")
            for pos in POSITIVE:
                if f"+{tok(pos, NEW)}" not in line_set:
                    missing.append((path, "+", pos))
                if f"-{tok(pos, OLD)}" not in line_set:
                    missing.append((path, "-", pos))
        self.assertEqual(missing, [])
        for neg in NEGATIVE:
            self.assertNotIn(f"+{neg}", line_set)
            self.assertNotIn(f"-{neg}", line_set)
        for rel in OUTSIDE_FILES:
            self.assertNotIn(rel, result.stdout)

    def test_dry_run_with_nothing_to_rename_is_a_silent_noop(self) -> None:
        root = self.make_root()
        self.assertEqual(self.rename(root).returncode, EXIT_OK)
        before = snapshot(root)
        result = self.rename(root, "--dry-run")
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)
        self.assert_snapshot_equal(snapshot(root), before)
        for line in diff_lines(result.stdout):
            self.assertFalse(line.startswith(("---", "+++", "@@")), line)


class ApplyTests(RenameRepoTestCase):
    def test_apply_rewrites_exactly_the_allowlist(self) -> None:
        root = self.make_root()
        before = snapshot(root)
        result = self.rename(root, umask=0o077)
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)
        after = snapshot(root)
        # Exact bytes, preserved modes (incl. executable bits) and no stray temp files.
        self.assert_snapshot_equal(after, self.expected_snapshot(before, NEW))
        for spec in ALLOWLIST_SPECS:
            self.assertEqual(after[spec[0]][1], spec[1], f"mode of {spec[0]}")
        for rel in OUTSIDE_FILES:
            self.assertEqual(after[rel], before[rel], rel)

    def test_apply_preserves_newline_conventions(self) -> None:
        root = self.make_root()
        self.assertEqual(self.rename(root).returncode, EXIT_OK)
        readme = (root / "README.md").read_bytes()
        self.assertIn(b"\r\n", readme)
        self.assertEqual(readme.count(b"\n"), readme.count(b"\r\n"))
        self.assertFalse((root / "install.sh").read_bytes().endswith(b"\n"))
        self.assertFalse((root / "scripts/codex_install.py").read_bytes().endswith(b"\n"))
        self.assertIn(b"\xff\xfe", (root / "docs/install/codex.md").read_bytes())
        self.assertTrue(os.access(root / "install.sh", os.X_OK))

    def test_apply_is_idempotent_and_reversible(self) -> None:
        root = self.make_root()
        before = snapshot(root)
        self.assertEqual(self.rename(root).returncode, EXIT_OK)
        renamed = snapshot(root)
        again = self.rename(root)
        self.assertEqual(again.returncode, EXIT_OK, again.stderr)
        self.assert_snapshot_equal(snapshot(root), renamed)

        back = self.rename(root, frm=NEW, to=OLD)
        self.assertEqual(back.returncode, EXIT_OK, back.stderr)
        self.assert_snapshot_equal(snapshot(root), before)

    def test_apply_does_not_follow_hardlink_to_outside_alias(self) -> None:
        root = self.make_root()
        target_spec = ALLOWLIST_SPECS[0]
        target = root / target_spec[0]
        original = target.read_bytes()
        alias = root / "docs" / "hardlink-alias.md"
        os.link(target, alias)

        result = self.rename(root)

        self.assertEqual(result.returncode, EXIT_OK, result.stderr)
        self.assertEqual(alias.read_bytes(), original)
        self.assertEqual(target.read_bytes(), render(target_spec, NEW))
        self.assertNotEqual(os.stat(target).st_ino, os.stat(alias).st_ino)

    def test_apply_can_change_owner(self) -> None:
        root = self.make_root()
        before = snapshot(root)
        result = self.rename(root, to="acme/ystack")
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)
        expected = self.expected_snapshot(before, "acme/ystack")
        self.assert_snapshot_equal(snapshot(root), expected)

    def test_root_comes_from_script_location_not_environment_or_cwd(self) -> None:
        root = self.make_root()
        decoy = self.make_root()
        decoy_before = snapshot(decoy)
        before = snapshot(root)
        env = {name: str(decoy) for name in ("REPO_ROOT", "ROOT", "PROJECT_ROOT", "CLAUDE_PROJECT_DIR")}
        env["PWD"] = str(decoy)
        result = self.rename(root, cwd=decoy, env_extra=env)
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)
        self.assert_snapshot_equal(snapshot(root), self.expected_snapshot(before, NEW))
        self.assert_snapshot_equal(snapshot(decoy), decoy_before)


class BoundaryTests(RenameRepoTestCase):
    def run_cases(self, cases: list[tuple[str, str]], frm: str = OLD, to: str = NEW) -> None:
        """Each case is (input line, expected line) for a rename of frm -> to."""
        root = self.make_root(populate=True)
        # Replace README with the case lines; everything else stays slug-free.
        for spec in ALLOWLIST_SPECS:
            if spec[0] != "README.md":
                write_file(root / spec[0], b"# nothing to rename\n", spec[1])
        write_file(root / "README.md", ("\n".join(raw for raw, _ in cases) + "\n").encode())
        result = self.rename(root, frm=frm, to=to)
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)
        actual = (root / "README.md").read_text().split("\n")[:-1]
        self.assertEqual(len(actual), len(cases))
        for got, (raw, expected) in zip(actual, cases, strict=True):
            with self.subTest(line=raw):
                self.assertEqual(got, expected)

    def test_urls_and_slugs_are_rewritten_at_exact_boundaries(self) -> None:
        cases_raw = [
            "https://github.com/{}",
            "https://github.com/{}/",
            "https://github.com/{}.git",
            "https://github.com/{}/tree/main",
            "https://github.com/{}?tab=readme",
            "https://github.com/{}#readme",
            "git+https://github.com/{}.git",
            "[repo](https://github.com/{})",
            "git@github.com:{}",
            "git@github.com:{}.git",
            "ssh://git@github.com/{}.git",
            '"repo": "{}"',
            "'{}'",
            "`{}`",
            "({})",
            "--repo {}",
            "repo={}",
            "{},",
            "\t{}\t",
            "{}",
        ]
        cases = [(frame.format(OLD), frame.format(NEW)) for frame in cases_raw]
        self.run_cases(cases)

    def test_lookalikes_are_left_alone(self) -> None:
        untouched = [
            "yandy-r/claude-plugins-official",
            "yandy-r/claude-plugins-official/",
            "https://github.com/yandy-r/claude-plugins-official",
            "https://github.com/yandy-r/claude-plugins-official.git",
            "git@github.com:yandy-r/claude-plugins-official.git",
            "ssh://git@github.com/yandy-r/claude-plugins-official.git",
            "yandy-r/claude-plugins.fork",
            "https://github.com/yandy-r/claude-plugins.fork",
            "yandy-r/claude-plugins2",
            "yandy-r/claude-plugins_x",
            "yandy-r/claude-pluginsX",
            "yandy-r/claude-plugins-extra",
            "xyandy-r/claude-plugins",
            "foo-yandy-r/claude-plugins",
            "https://github.com/xyandy-r/claude-plugins",
            "https://github.com/foo-yandy-r/claude-plugins.git",
            "yandy_r/claude-plugins",
            "/home/yandy/Projects/github.com/yandy-r/claude-plugins",
            "/home/yandy/Projects/github.com/yandy-r/claude-plugins/.claude/worktrees/x",
            "/tmp/work/yandy-r/claude-plugins/scripts",
            "ycc:init",
            "ycc@ycc",
            "ycc-mods",
            "${CLAUDE_PLUGIN_ROOT}/hooks",
            "claude-plugins-official",
        ]
        untouched.append("github.com/yandy-r/claude-plugins/raw/main/install.sh")
        self.run_cases([(line, line) for line in untouched])

    def test_mixed_line_rewrites_only_the_exact_matches(self) -> None:
        mixed = (
            "{slug} yandy-r/claude-plugins-official xyandy-r/claude-plugins "
            "https://github.com/{slug}.git yandy-r/claude-plugins.fork"
        )
        self.run_cases([(mixed.format(slug=OLD), mixed.format(slug=NEW))])

    def test_other_slugs_use_the_same_boundaries(self) -> None:
        cases = [
            ("https://github.com/acme/widgets.git", "https://github.com/acme/gadgets.git"),
            ("git@github.com:acme/widgets.git", "git@github.com:acme/gadgets.git"),
            ("acme/widgets", "acme/gadgets"),
            ("acme/widgets-official", "acme/widgets-official"),
            ("acme/widgets.fork", "acme/widgets.fork"),
            ("big-acme/widgets", "big-acme/widgets"),
            ("/home/u/Projects/github.com/acme/widgets", "/home/u/Projects/github.com/acme/widgets"),
            ("yandy-r/claude-plugins", "yandy-r/claude-plugins"),
        ]
        self.run_cases(cases, "acme/widgets", "acme/gadgets")


class InvalidArgumentTests(RenameRepoTestCase):
    def test_invalid_arguments_exit_2_without_writing(self) -> None:
        bad_slugs = [
            "",
            "yandy-r",
            "yandy-r/",
            "/claude-plugins",
            "a/b/c",
            "https://github.com/yandy-r/claude-plugins",
            "git@github.com:yandy-r/claude-plugins.git",
            "yandy-r/claude plugins",
            "-yandy/claude-plugins",
            "yandy-/claude-plugins",
            "yandy-r/..",
            "yandy-r/.",
            "../claude-plugins",
            "--from",
            "--dry-run",
        ]
        argvs: list[list[str]] = [
            [],
            ["--from", OLD],
            ["--to", NEW],
            ["--dry-run"],
            ["--from", OLD, "--to"],
            ["--from", "--to", NEW],
            ["--from", OLD, "--to", NEW, "--bogus"],
            ["--from", OLD, "--to", NEW, "extra"],
            ["--dry-run", "--from", OLD],
            ["--from", OLD, "--from", OLD, "--to", NEW],
            ["--from", OLD, "--to", NEW, "--to", NEW],
        ]
        for slug in bad_slugs:
            argvs.append(["--from", slug, "--to", NEW])
            argvs.append(["--from", OLD, "--to", slug])
        root = self.make_root()
        before = snapshot(root)
        for argv in argvs:
            with self.subTest(argv=argv):
                result = self.run_cli(root, *argv)
                self.assertEqual(result.returncode, EXIT_USAGE, result.stdout + result.stderr)
                self.assertTrue(result.stderr.strip())
                self.assert_snapshot_equal(snapshot(root), before)
                dry = self.run_cli(root, *argv, "--dry-run")
                self.assertEqual(dry.returncode, EXIT_USAGE)
                self.assert_snapshot_equal(snapshot(root), before)

    def test_help_explains_scope_and_writes_nothing(self) -> None:
        root = self.make_root()
        before = snapshot(root)
        for flag in ("--help", "-h"):
            with self.subTest(flag=flag):
                result = self.run_cli(root, flag)
                self.assertEqual(result.returncode, EXIT_OK, result.stderr)
                text = result.stdout.lower()
                for needle in ("--from", "--to", "--dry-run", "remote", "sync", "rename"):
                    self.assertIn(needle, text)
                self.assert_snapshot_equal(snapshot(root), before)


class PreflightTests(RenameRepoTestCase):
    def assert_preflight_rejected(self, root: Path) -> None:
        before = snapshot(root)
        for extra in ((), ("--dry-run",)):
            with self.subTest(extra=extra):
                result = self.rename(root, *extra)
                self.assertEqual(result.returncode, EXIT_PREFLIGHT, result.stdout + result.stderr)
                self.assertTrue(result.stderr.strip())
                self.assert_snapshot_equal(snapshot(root), before)

    def test_each_missing_allowlist_file_aborts_before_any_write(self) -> None:
        for path in ALLOWLIST:
            with self.subTest(missing=path):
                root = self.make_root()
                (root / path).unlink()
                self.assert_preflight_rejected(root)

    def test_symlinked_allowlist_file_aborts_before_any_write(self) -> None:
        for path in ALLOWLIST:
            with self.subTest(symlink=path):
                root = self.make_root()
                target = root / "outside-target.txt"
                write_file(target, outside_text("outside-target", OLD))
                (root / path).unlink()
                os.symlink(target, root / path)
                self.assert_preflight_rejected(root)

    def test_dangling_symlink_aborts_before_any_write(self) -> None:
        root = self.make_root()
        (root / "README.md").unlink()
        os.symlink("does-not-exist", root / "README.md")
        self.assert_preflight_rejected(root)

    def test_symlinked_directory_component_aborts_before_any_write(self) -> None:
        for real, link in (
            ("docs/install-real", "docs/install"),
            ("ycc/mods/real-plugin", "ycc/mods/.claude-plugin"),
            ("scripts/lib-real", "scripts/lib"),
        ):
            with self.subTest(link=link):
                root = self.make_root()
                os.rename(root / link, root / real)
                os.symlink(Path(real).name, root / link)
                self.assert_preflight_rejected(root)

    def test_directory_in_place_of_file_aborts_before_any_write(self) -> None:
        root = self.make_root()
        (root / "ycc/settings/settings.json").unlink()
        (root / "ycc/settings/settings.json").mkdir()
        self.assert_preflight_rejected(root)

    def test_fifo_in_place_of_file_aborts_before_any_write(self) -> None:
        root = self.make_root()
        (root / "docs/install/codex.md").unlink()
        os.mkfifo(root / "docs/install/codex.md")
        self.assert_preflight_rejected(root)


class PythonApiTests(RenameRepoTestCase):
    def load_engine(self, root: Path) -> Any:
        name = f"rename_repo_under_test_{len(sys.modules)}"
        spec = importlib.util.spec_from_file_location(name, root / "scripts" / "rename_repo.py")
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        self.addCleanup(sys.modules.pop, name, None)
        spec.loader.exec_module(module)
        return module

    def call_main(self, module: Any, argv: list[str]) -> tuple[int, str]:
        raw = io.BytesIO()
        out = io.TextIOWrapper(raw, encoding="utf-8", errors="surrogateescape")
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            try:
                code = module.main(argv)
            except SystemExit as exc:  # argparse-style help/usage exits
                code = exc.code
        out.flush()
        text = raw.getvalue().decode("utf-8", "replace")
        return int(code or 0), text

    def test_main_uses_root_from_file_and_matches_cli(self) -> None:
        root = self.make_root()
        module = self.load_engine(root)
        self.assertEqual(Path(module.REPO_ROOT).resolve(), root)
        self.assertEqual(sorted(module.ALLOWLIST_FILES), sorted(ALLOWLIST))

        before = snapshot(root)
        code, out = self.call_main(module, ["--from", OLD, "--to", NEW, "--dry-run"])
        self.assertEqual(code, EXIT_OK)
        self.assertIn("+https://github.com/yandy-r/ystack.git", out)
        self.assert_snapshot_equal(snapshot(root), before)

        code, _ = self.call_main(module, ["--from", OLD, "--to", NEW])
        self.assertEqual(code, EXIT_OK)
        self.assert_snapshot_equal(snapshot(root), self.expected_snapshot(before, NEW))

        code, _ = self.call_main(module, ["--from", "nonsense", "--to", NEW])
        self.assertEqual(code, EXIT_USAGE)


class RealCheckoutTests(RenameRepoTestCase):
    def test_real_checkout_dry_run_covers_every_allowlisted_file(self) -> None:
        before = {rel: (SCRIPTS_DIR.parent / rel).read_bytes() for rel in ALLOWLIST}
        modes = {
            rel: stat.S_IMODE(os.stat(SCRIPTS_DIR.parent / rel, follow_symlinks=False).st_mode) for rel in ALLOWLIST
        }
        # Before a flip the checkout carries OLD; once the rename lands it carries NEW (the
        # current slug). Preview the transformation that is still possible so coverage survives.
        pre_flip = any(OLD.encode() in data for data in before.values())
        source, target = (OLD, NEW) if pre_flip else (NEW, OLD)
        result = subprocess.run(
            [str(WRAPPER_SRC), "--from", source, "--to", target, "--dry-run"],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=60,
        )
        self.assertEqual(result.returncode, EXIT_OK, result.stderr)
        headers = {line.removeprefix("--- a/") for line in diff_lines(result.stdout) if line.startswith("--- a/")}
        self.assertEqual(headers, set(ALLOWLIST))
        after = {rel: (SCRIPTS_DIR.parent / rel).read_bytes() for rel in ALLOWLIST}
        after_modes = {
            rel: stat.S_IMODE(os.stat(SCRIPTS_DIR.parent / rel, follow_symlinks=False).st_mode) for rel in ALLOWLIST
        }
        self.assertEqual(after, before)
        self.assertEqual(after_modes, modes)


if __name__ == "__main__":
    unittest.main()
