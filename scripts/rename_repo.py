#!/usr/bin/env python3
"""Rewrite this repository's GitHub owner/repo references in a fixed set of source files.

Only file contents are edited. This does NOT rename the repository on GitHub, update git
remotes, or sync/regenerate anything; do those separately (host rename, `git remote set-url`,
generators). Run with --dry-run first to see the full diff without writing.
"""

from __future__ import annotations

import argparse
import difflib
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Source files that carry the owner/repo slug. Generated artifacts and historical docs are
# intentionally excluded; regenerate those after the rename.
ALLOWLIST_FILES: tuple[str, ...] = (
    ".claude-plugin/marketplace.json",
    ".github/ISSUE_TEMPLATE/config.yml",
    "README.md",
    "docs/install/codex.md",
    "install.sh",
    "scripts/codex_install.py",
    "scripts/generate_codex_plugin.py",
    "scripts/generate_opencode_package.py",
    "scripts/test_generate_opencode_package.py",
    "docs/install/v6/README.md",
    "docs/install/v6/claude.md",
    "ycc/skills/_shared/references/target-capability-matrix.md",
    "scripts/lib/install/targets/claude.sh",
    "scripts/lib/install/targets/cursor.sh",
    "ycc/mods/.claude-plugin/marketplace.json",
    "ycc/settings/settings.json",
)

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_PREFLIGHT = 3
EXIT_WRITE = 4

_OWNER_RE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?")
_REPO_RE = re.compile(r"[A-Za-z0-9_.-]{1,100}")

_HELP_EPILOG = """\
Rewrites occurrences of --from in these files (relative to the repository root):
  {files}

Matched forms: https/http/git/ssh GitHub URLs (with or without .git, path, query, fragment),
git@github.com:owner/repo(.git), and standalone owner/repo slugs. Only anchored repository
references are rewritten: bare repo names without the owner (such as `# <repo>` titles) and
longer names such as <repo>-official or <repo>.fork, slugs with a longer owner, and local
filesystem paths are left untouched, as are non-slug identifiers (ycc:, ycc@ycc, ycc-mods,
CLAUDE_PLUGIN_ROOT).

This tool does NOT rename the repository on GitHub, does NOT change git remotes, and does NOT
sync or regenerate generated artifacts. Run those steps separately.

Exit codes: 0 success or no-op, 2 usage/validation, 3 preflight failure, 4 write failure.
"""


class _SingleArgument(argparse.Action):
    def __call__(
        self,
        parser: argparse.ArgumentParser,
        namespace: argparse.Namespace,
        values: object,
        option_string: str | None = None,
    ) -> None:
        if getattr(namespace, self.dest) is not None:
            parser.error(f"duplicate option: {option_string}")
        setattr(namespace, self.dest, values)


def _validate_slug(value: str) -> str:
    owner, sep, repo = value.partition("/")
    ok = (
        bool(sep)
        and "/" not in repo
        and _OWNER_RE.fullmatch(owner) is not None
        and "--" not in owner
        and _REPO_RE.fullmatch(repo) is not None
        and repo not in {".", ".."}
        and not repo.endswith(".git")
    )
    if not ok:
        raise argparse.ArgumentTypeError(f"invalid GitHub slug {value!r}; expected owner/repo")
    return value


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="rename-repo.sh",
        description=__doc__,
        epilog=_HELP_EPILOG.format(files="\n  ".join(ALLOWLIST_FILES)),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        allow_abbrev=False,
    )
    parser.add_argument(
        "--from", dest="old", action=_SingleArgument, required=True, type=_validate_slug, metavar="owner/repo"
    )
    parser.add_argument(
        "--to", dest="new", action=_SingleArgument, required=True, type=_validate_slug, metavar="owner/repo"
    )
    parser.add_argument("--dry-run", action="store_true", help="print the full diff; write nothing")
    return parser


_NAME_CHARS = r"A-Za-z0-9_-"


def _slug_pattern(slug: str) -> re.Pattern[bytes]:
    """Match `slug` as a URL slug, git@ slug or standalone token, never as part of a longer name or local path."""
    url_prefix = (
        r"(?:git\+)?(?:https?|git)://(?:[^/@\s\"'<>]+@)?(?:www\.)?github\.com/"
        r"|ssh://(?:[^/@\s\"'<>]+@)?github\.com(?::\d+)?/"
        r"|[A-Za-z0-9_.-]+@github\.com:"
    )
    # Standalone: not glued to a longer owner or to a path (`/home/.../github.com/owner/repo`).
    standalone = r"(?<![A-Za-z0-9_./~@-])"
    # After the repo: `.git` or sentence punctuation is fine; `-official`, `.fork`, `_x` are other repos.
    tail = rf"(?=\.git(?![{_NAME_CHARS}]|\.[{_NAME_CHARS}])|(?![{_NAME_CHARS}]|\.[{_NAME_CHARS}]))"
    pattern = rf"(?P<pre>{url_prefix})?(?(pre)|{standalone}){re.escape(slug)}{tail}"
    return re.compile(pattern.encode("ascii"))


def _rewrite(data: bytes, old: str, new: str) -> tuple[bytes, int]:
    return _slug_pattern(old).subn(lambda m: (m.group("pre") or b"") + new.encode("ascii"), data)


def _preflight_file(root: Path, rel: str) -> tuple[Path, os.stat_result]:
    """Return path and lstat of a regular file reached without any symlink component."""
    path = root
    for part in Path(rel).parts:
        path = path / part
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            raise ValueError(f"missing file: {rel}") from None
        except OSError as exc:
            raise ValueError(f"cannot stat {rel}: {exc.strerror}") from None
        if stat.S_ISLNK(st.st_mode):
            raise ValueError(f"symlink path component rejected: {rel}")
    if not stat.S_ISREG(st.st_mode):
        raise ValueError(f"not a regular file: {rel}")
    return path, st


def _same_file(a: os.stat_result, b: os.stat_result) -> bool:
    return (a.st_dev, a.st_ino, a.st_size, a.st_mtime_ns) == (b.st_dev, b.st_ino, b.st_size, b.st_mtime_ns)


def _text_lines(data: bytes) -> list[str]:
    text = data.decode("utf-8", errors="surrogateescape")
    return re.findall(r"[^\n]*\n|[^\n]+", text)


def _diff(rel: str, before: bytes, after: bytes) -> str:
    a, b = _text_lines(before), _text_lines(after)
    out: list[str] = []
    for line in difflib.unified_diff(a, b, f"a/{rel}", f"b/{rel}", lineterm="\n"):
        out.append(line if line.endswith("\n") else line + "\n\\ No newline at end of file\n")
    return "".join(out)


def _atomic_write(path: Path, data: bytes, mode: int) -> None:
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def main(argv: list[str] | None = None) -> int:
    try:
        args = _build_parser().parse_args(argv)
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else EXIT_USAGE

    old, new = args.old, args.new
    root = REPO_ROOT

    # Preflight: read and rewrite everything in memory; any problem aborts before a write.
    plans: list[tuple[str, Path, os.stat_result, bytes, bytes, int]] = []
    errors: list[str] = []
    for rel in ALLOWLIST_FILES:
        try:
            path, st = _preflight_file(root, rel)
            data = path.read_bytes()
        except ValueError as exc:
            errors.append(str(exc))
            continue
        except OSError as exc:
            errors.append(f"cannot read {rel}: {exc.strerror}")
            continue
        updated, count = _rewrite(data, old, new) if old != new else (data, 0)
        if updated != data:
            plans.append((rel, path, st, data, updated, count))
    if errors:
        for message in errors:
            sys.stderr.write(f"error: {message}\n")
        return EXIT_PREFLIGHT

    total = sum(plan[5] for plan in plans)
    if not plans:
        sys.stdout.write(f"no changes: no references to {old} in the allowlisted files\n")
        return EXIT_OK

    if args.dry_run:
        sys.stdout.flush()
        for rel, _path, _st, before, after, _count in plans:
            sys.stdout.buffer.write(_diff(rel, before, after).encode("utf-8", errors="surrogateescape"))
        sys.stdout.buffer.flush()
        sys.stderr.write(f"dry run: {total} replacement(s) in {len(plans)} file(s); nothing written\n")
        return EXIT_OK

    written: list[str] = []
    for rel, path, st, _before, after, _count in plans:
        try:
            if not _same_file(st, os.lstat(path)):
                raise OSError("file changed during rename")
            _atomic_write(path, after, stat.S_IMODE(st.st_mode))
        except OSError as exc:
            sys.stderr.write(f"error: failed writing {rel}: {exc.strerror or exc}\n")
            if written:
                sys.stderr.write(f"error: partial rename; already written: {', '.join(written)}\n")
            return EXIT_WRITE
        written.append(rel)
    sys.stdout.write(f"renamed {old} -> {new}: {total} replacement(s) in {len(plans)} file(s)\n")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
