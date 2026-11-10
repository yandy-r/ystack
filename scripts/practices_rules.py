"""Pure policy checks for root Claude rule docs and `.claude/rules` frontmatter.

Each function returns human-readable error strings; the validator owns I/O and
reporting. This module deliberately imports nothing from runtime/init code.
"""

from __future__ import annotations

import fnmatch
import re
from functools import cache

AGENTS_LIMIT = 150
CLAUDE_LIMIT = 40
COMBINED_LIMIT = AGENTS_LIMIT + CLAUDE_LIMIT
CANONICAL_IMPORT = "AGENTS.md"

_FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
_DIRECTIVE_RE = re.compile(r" {0,3}@(\S+)[ \t]*")


def _scan_imports(text: str) -> tuple[list[str], bool]:
    """Collect imports and whether a live HTML comment remains unclosed."""
    imports: list[str] = []
    fence = ""
    in_comment = False
    for line in text.splitlines():
        marker = _FENCE_RE.match(line)
        if fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = ""
            continue
        if not in_comment:
            if marker:
                fence = marker[1]
                continue
            if line.startswith(("    ", "\t")):
                continue
        live = ""
        while line:
            if in_comment:
                end = line.find("-->")
                if end < 0:
                    break
                line = line[end + 3 :]
                in_comment = False
            else:
                start = line.find("<!--")
                if start < 0:
                    live += line
                    break
                live += line[:start]
                line = line[start + 4 :]
                in_comment = True
        directive = _DIRECTIVE_RE.fullmatch(live)
        if directive and not directive[1].startswith("`"):
            imports.append(directive[1])
    return imports, in_comment


def body_import_errors(text: str) -> list[str]:
    """A scoped rule body may contain no live imports and no unclosed comment."""
    found, unclosed = _scan_imports(text)
    errors = ["unclosed HTML comment"] if unclosed else []
    errors += [f"rule body must not contain standalone import '@{target}'" for target in found]
    return errors


def import_errors(claude_text: str) -> list[str]:
    """CLAUDE.md must have exactly one standalone import: `@AGENTS.md`."""
    found, unclosed = _scan_imports(claude_text)
    errors_pre = ["unclosed HTML comment"] if unclosed else []
    expected = f"@{CANONICAL_IMPORT}"
    errors = errors_pre + [
        f"unexpected import '@{target}'; only a single standalone {expected} is allowed"
        for target in found
        if target != CANONICAL_IMPORT
    ]
    count = found.count(CANONICAL_IMPORT)
    if count == 0:
        errors.append(f"missing standalone {expected} import")
    elif count > 1:
        errors.append(f"duplicate {expected} imports ({count}); keep exactly one")
    return errors


def path_pattern_error(pattern: str) -> str | None:
    """Require a repository-relative POSIX glob; return the problem or None."""
    parts = pattern.split("/")
    if not pattern.strip() or pattern != pattern.strip():
        return "must be a nonempty glob without surrounding whitespace"
    if pattern.startswith("/") or "\\" in pattern or any(p in {"", ".", ".."} for p in parts):
        return "must be a repository-relative POSIX glob without empty, '.' or '..' components"
    if any("**" in p and p != "**" for p in parts):
        return "'**' must occupy an entire path component"
    if "{" in pattern or "}" in pattern:
        return "brace expansion '{...}' is not supported; split it into separate paths list entries"
    return None


def path_matches(pattern: str, path: str) -> bool:
    """Match a whole repo-relative file path against a glob.

    `*`, `?` and `[...]` never cross `/`. A `**` component matches zero or more
    directories, except a trailing `**`, which matches one or more path components
    (everything inside a directory). Unlike Path.match this is never a suffix match.
    """
    parts, names = pattern.split("/"), path.split("/")

    @cache
    def match(i: int, j: int) -> bool:
        if i == len(parts):
            return j == len(names)
        if parts[i] == "**":
            if i == len(parts) - 1:
                return j < len(names)
            return match(i + 1, j) or (j < len(names) and match(i, j + 1))
        return j < len(names) and fnmatch.fnmatchcase(names[j], parts[i]) and match(i + 1, j + 1)

    return match(0, 0)


def rule_path_errors(value: object, files: frozenset[str]) -> list[str]:
    """Validate a rule's `paths` frontmatter; every glob must match a real file."""
    if not isinstance(value, list) or not value:
        return ["paths must be a nonempty list of glob strings"]
    errors: list[str] = []
    for pattern in value:
        if not isinstance(pattern, str):
            errors.append(f"paths entry must be a glob string, got {pattern!r}")
        elif problem := path_pattern_error(pattern):
            errors.append(f"paths entry {pattern!r}: {problem}")
        elif not any(path_matches(pattern, path) for path in files):
            errors.append(f"paths pattern {pattern!r} matches no existing repository files")
    return errors
