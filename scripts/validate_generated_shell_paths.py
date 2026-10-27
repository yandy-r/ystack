#!/usr/bin/env python3
"""Reject broken helper paths in generated shell code.

Scan the generated bundles (.codex-plugin/, .opencode-plugin/, .agents-plugin/,
packages/; node_modules/ is skipped) and fail on:

- in every ``.sh``/``.bash`` file, a quoted ``~/`` path (``"~/`` or ``'~/``) on a
  non-comment line: the shell never expands a quoted ``~``. A parameter-expansion
  strip pattern such as ``${raw_root#"~/"}`` matches a literal ``~/`` on purpose
  and is allowed;
- in every ``.md`` file, a double-quoted ``"~/`` path on a non-comment line of a
  fenced ``bash``/``sh``/``shell`` block. Single-quoted ``'~/`` is not flagged in
  Markdown: snippets there routinely hand a whole command string to another shell
  (``git rebase -x '~/.../validate-commit.sh ...'``, ``bash -c '...'``), where the
  inner shell does expand the ``~``;
- in every ``.sh``/``.bash`` file, a dead fallback ``[[ -f "$VAR" ]] || VAR="X"``
  directly after ``VAR="X"`` (see generate_codex_common.self_fallbacks).

Exit 0 when clean, 1 on any finding (findings go to stderr).
"""

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Iterable, Iterator, Sequence
from pathlib import Path

from generate_codex_common import self_fallbacks

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ROOTS = tuple(REPO_ROOT / name for name in (".codex-plugin", ".opencode-plugin", ".agents-plugin", "packages"))
SHELL_SUFFIXES = frozenset({".sh", ".bash"})
MARKDOWN_SUFFIX = ".md"
SHELL_FENCE_LANGUAGES = frozenset({"bash", "sh", "shell"})
SKIPPED_DIRS = frozenset({"node_modules"})

QUOTED_TILDE = re.compile(r"[\"']~/")
DOUBLE_QUOTED_TILDE = re.compile(r"\"~/")
# `${name#"~/"}`, `${name##"~/"}`, `${name%"~/"}`, `${name%%"~/"}`: a strip pattern, not a path.
STRIP_PATTERN = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*(?:##?|%%?)([\"'])~/\1\}")
FENCE_OPEN = re.compile(r"^\s*(?P<fence>`{3,}|~{3,})\s*(?P<lang>[A-Za-z0-9_+-]*)")
QUOTED_TILDE_MESSAGE = "quoted '~' is never expanded by the shell"


def _quoted_tildes(lines: Iterable[tuple[int, str]], pattern: re.Pattern[str]) -> list[tuple[int, str]]:
    return [
        (number, QUOTED_TILDE_MESSAGE)
        for number, line in lines
        if not line.lstrip().startswith("#") and pattern.search(STRIP_PATTERN.sub("", line))
    ]


def _report(errors: list[tuple[int, str]]) -> list[str]:
    return [f"line {number}: {message}" for number, message in sorted(errors)]


def check_text(text: str) -> list[str]:
    """Return ``line N: problem`` findings for one shell script."""
    errors = _quoted_tildes(enumerate(text.splitlines(), 1), QUOTED_TILDE)
    errors.extend((index + 1, f"fallback for {var} repeats its primary path") for index, var in self_fallbacks(text))
    return _report(errors)


def shell_fence_lines(text: str) -> Iterator[tuple[int, str]]:
    """Yield ``(line number, line)`` for the body of every fenced shell block."""
    fence: str | None = None
    shell = False
    for number, line in enumerate(text.splitlines(), 1):
        if fence is None:
            opened = FENCE_OPEN.match(line)
            if opened:
                fence = opened["fence"]
                shell = opened["lang"].lower() in SHELL_FENCE_LANGUAGES
            continue
        closing = line.strip()
        if closing.startswith(fence) and not closing.strip(fence[0]):
            fence = None
        elif shell:
            yield number, line


def check_markdown(text: str) -> list[str]:
    """Return ``line N: problem`` findings for the shell blocks of one Markdown file."""
    return _report(_quoted_tildes(shell_fence_lines(text), DOUBLE_QUOTED_TILDE))


def candidate_files(roots: Sequence[Path]) -> Iterator[Path]:
    for root in roots:
        yield from sorted(
            path
            for path in root.rglob("*")
            if (path.suffix in SHELL_SUFFIXES or path.suffix == MARKDOWN_SUFFIX)
            and SKIPPED_DIRS.isdisjoint(path.relative_to(root).parts)
            and path.is_file()
        )


def validate(roots: Sequence[Path]) -> list[str]:
    errors: list[str] = []
    for path in candidate_files(roots):
        text = path.read_text(encoding="utf-8", errors="replace")
        found = check_markdown(text) if path.suffix == MARKDOWN_SUFFIX else check_text(text)
        errors.extend(f"{path}: {error}" for error in found)
    return errors


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else None)
    parser.add_argument(
        "--root",
        dest="roots",
        action="append",
        type=Path,
        help="Directory to scan (repeatable; default: the generated bundles)",
    )
    args = parser.parse_args(argv)
    roots: list[Path] = args.roots or list(DEFAULT_ROOTS)
    missing = [root for root in roots if not root.is_dir()]
    if missing:
        print(f"validate_generated_shell_paths: missing directory: {missing[0]}", file=sys.stderr)
        return 1
    errors = validate(roots)
    for error in errors:
        print(f"validate_generated_shell_paths: {error}", file=sys.stderr)
    if errors:
        return 1
    print("OK: generated shell code carries no quoted '~' path and no dead helper fallback.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
