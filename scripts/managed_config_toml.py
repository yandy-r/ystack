"""TOML text patching for merge_managed_config.py: in-place assignment updates and deletions."""

from __future__ import annotations

import json
import re
import tomllib
from typing import Any

from managed_config_core import MergeError, delete_nested, read_nested

# ---------------------------------------------------------------------------
# TOML text patching
#
# tomllib parses but cannot serialize, and a hand-rolled writer would destroy
# comments, ordering and quoting. Instead we locate the exact byte span of each
# managed assignment and replace only that span.
# ---------------------------------------------------------------------------

TOML_TABLE_RE = re.compile(r"^\s*\[\[?([^\]]+)\]\]?\s*(?:#.*)?$")
TOML_KEY_RE = re.compile(
    r"^\s*((?:[A-Za-z0-9_-]+|\"[^\"]*\"|'[^']*')(?:\s*\.\s*(?:[A-Za-z0-9_-]+|\"[^\"]*\"|'[^']*'))*)\s*="
)


def split_toml_key(raw: str) -> list[str]:
    """Split a possibly dotted, possibly quoted TOML key into segments."""
    parts: list[str] = []
    for chunk in re.findall(r"\"[^\"]*\"|'[^']*'|[^.\s]+", raw):
        if chunk[:1] in {'"', "'"}:
            parts.append(chunk[1:-1])
        else:
            parts.append(chunk)
    return parts


def format_toml_value(value: Any) -> str:
    """Render a Python value as TOML. Mirrors the JSON subset we manage."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return json.dumps(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ", ".join(format_toml_value(item) for item in value) + "]"
    if isinstance(value, dict):
        return "{ " + ", ".join(f"{format_toml_key(k)} = {format_toml_value(v)}" for k, v in value.items()) + " }"
    raise MergeError(f"cannot render TOML value of type {type(value).__name__}")


def format_toml_key(key: str) -> str:
    return key if re.fullmatch(r"[A-Za-z0-9_-]+", key) else json.dumps(key, ensure_ascii=False)


def format_toml_path(path: list[str]) -> str:
    return ".".join(format_toml_key(part) for part in path)


def scan_toml_assignments(lines: list[str]) -> dict[tuple[str, ...], tuple[int, int]]:
    """Map each assignment's full key path to its ``[start, end)`` line span.

    Multi-line values (arrays, multi-line strings) are handled by extending the
    span until the accumulated text parses as TOML again.
    """
    spans: dict[tuple[str, ...], tuple[int, int]] = {}
    table: list[str] = []
    index = 0

    while index < len(lines):
        line = lines[index]
        stripped = line.strip()

        if not stripped or stripped.startswith("#"):
            index += 1
            continue

        table_match = TOML_TABLE_RE.match(line)
        if table_match:
            table = split_toml_key(table_match.group(1))
            index += 1
            continue

        key_match = TOML_KEY_RE.match(line)
        if not key_match:
            index += 1
            continue

        end = index + 1
        while end <= len(lines):
            candidate = "".join(lines[index:end])
            try:
                tomllib.loads(candidate)
                break
            except tomllib.TOMLDecodeError:
                end += 1
        else:
            raise MergeError(f"could not determine the end of the TOML assignment starting at line {index + 1}")

        spans[tuple(table + split_toml_key(key_match.group(1)))] = (index, end)
        index = end

    return spans


def repair_duplicate_managed_toml(text: str, managed_paths: list[list[str]]) -> str:
    """Remove duplicate managed assignments/tables so ``--force`` can recover.

    Recovery is intentionally narrow: only paths supplied by the selected
    profile groups are eligible, and a duplicated table is removed only when
    every assignment in each occurrence is managed. The normal merge then
    writes the source-of-truth values back atomically. Unrelated malformed TOML
    remains an error.
    """
    lines = text.splitlines(keepends=True)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"

    managed = {tuple(path) for path in managed_paths}
    occurrences: dict[tuple[str, ...], list[tuple[int, int]]] = {}
    table_headers: dict[tuple[str, ...], list[int]] = {}
    table: tuple[str, ...] = ()
    covered_assignment_lines: set[int] = set()
    index = 0

    while index < len(lines):
        line = lines[index]
        table_match = TOML_TABLE_RE.match(line)
        if table_match:
            table = tuple(split_toml_key(table_match.group(1)))
            table_headers.setdefault(table, []).append(index)
            index += 1
            continue

        key_match = TOML_KEY_RE.match(line)
        if not key_match:
            index += 1
            continue

        end = index + 1
        while end <= len(lines):
            try:
                tomllib.loads("".join(lines[index:end]))
                break
            except tomllib.TOMLDecodeError:
                end += 1
        else:
            return text

        path = (*table, *split_toml_key(key_match.group(1)))
        occurrences.setdefault(path, []).append((index, end))
        covered_assignment_lines.update(range(index, end))
        index = end

    duplicate_paths = {path for path, spans in occurrences.items() if len(spans) > 1 and path in managed}
    if not duplicate_paths:
        return text

    duplicate_tables = {
        table_path
        for table_path, headers in table_headers.items()
        if len(headers) > 1 and any(path[:-1] == table_path for path in duplicate_paths)
    }

    header_indexes = sorted(index for indexes in table_headers.values() for index in indexes)
    remove_lines: set[int] = set()

    for table_path in duplicate_tables:
        for header_index in table_headers[table_path]:
            next_header = next((candidate for candidate in header_indexes if candidate > header_index), len(lines))
            for line_index in range(header_index + 1, next_header):
                stripped = lines[line_index].strip()
                if not stripped or stripped.startswith("#") or line_index in covered_assignment_lines:
                    continue
                return text

            section_paths = {
                path
                for path, spans in occurrences.items()
                if any(header_index < start < next_header for start, _ in spans)
            }
            if not section_paths.issubset(managed):
                return text

            remove_lines.add(header_index)
            for path in section_paths:
                for start, end in occurrences[path]:
                    if header_index < start < next_header:
                        remove_lines.update(range(start, end))

    for path in duplicate_paths:
        if path[:-1] in duplicate_tables:
            continue
        for start, end in occurrences[path]:
            remove_lines.update(range(start, end))

    return "".join(line for line_index, line in enumerate(lines) if line_index not in remove_lines)


def table_end_line(lines: list[str], table: list[str]) -> int | None:
    """Return the insertion point at the end of an existing table's body."""
    target = tuple(table)
    in_table = False
    last_content = None

    for index, line in enumerate(lines):
        table_match = TOML_TABLE_RE.match(line)
        if table_match:
            if in_table:
                return (last_content + 1) if last_content is not None else index
            in_table = tuple(split_toml_key(table_match.group(1))) == target
            if in_table:
                last_content = index
            continue
        if in_table and line.strip() and not line.strip().startswith("#"):
            last_content = index

    if in_table:
        return (last_content + 1) if last_content is not None else len(lines)
    return None


def split_inline_deletions(
    text: str, deletions: list[list[str]], destination: dict[str, Any]
) -> tuple[list[list[str]], list[tuple[list[str], Any]]]:
    """Turn deletions inside an inline-table assignment into a rewrite of that assignment.

    Siblings stay; a table left empty is deleted whole. Other deletions pass through.
    """
    spans = scan_toml_assignments(text.splitlines(keepends=True))
    plain: list[list[str]] = []
    holders: dict[tuple[str, ...], dict[str, Any]] = {}
    for path in deletions:
        parent = next((tuple(path[:n]) for n in range(len(path) - 1, 0, -1) if tuple(path[:n]) in spans), None)
        value = read_nested(destination, list(parent))[1] if parent else None
        if parent is None or not isinstance(value, dict):
            plain.append(path)
            continue
        holder = holders.setdefault(parent, {"v": json.loads(json.dumps(value))})
        delete_nested(holder, ["v", *path[len(parent) :]])
    rewrites: list[tuple[list[str], Any]] = []
    for parent, holder in holders.items():
        if "v" in holder:
            rewrites.append((list(parent), holder["v"]))
        else:
            plain.append(list(parent))
    return plain, rewrites


def apply_toml_updates(
    text: str,
    updates: list[tuple[list[str], Any]],
    deletions: list[list[str]] | None = None,
) -> str:
    """Patch managed assignments in place, leaving all other bytes untouched.

    Deletions drop the assignment or whole table subtree at each path.
    """
    if deletions:
        text = delete_toml_entries(text, deletions)
    lines = text.splitlines(keepends=True)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"

    # Apply bottom-up so earlier spans keep their indices valid.
    replacements: list[tuple[int, int, str]] = []
    root_appends: list[str] = []
    appends: dict[tuple[str, ...], list[str]] = {}
    new_tables: dict[tuple[str, ...], list[str]] = {}

    spans = scan_toml_assignments(lines)

    for path, value in updates:
        key = tuple(path)
        rendered = f"{format_toml_key(path[-1])} = {format_toml_value(value)}\n"

        if key in spans:
            start, end = spans[key]
            replacements.append((start, end, rendered))
            continue

        table = key[:-1]
        if not table:
            root_appends.append(rendered)
            continue

        if table_end_line(lines, list(table)) is not None:
            appends.setdefault(table, []).append(rendered)
        else:
            new_tables.setdefault(table, []).append(rendered)

    if root_appends:
        # Root keys must land above the first table header, otherwise TOML
        # would read them as members of the last table in the file.
        insert_at = next(
            (index for index, line in enumerate(lines) if TOML_TABLE_RE.match(line)),
            len(lines),
        )
        replacements.append((insert_at, insert_at, "".join(root_appends)))

    for table, rendered_lines in appends.items():
        table_end = table_end_line(lines, list(table))
        assert table_end is not None
        replacements.append((table_end, table_end, "".join(rendered_lines)))

    for start, end, rendered in sorted(replacements, key=lambda item: item[0], reverse=True):
        lines[start:end] = [rendered] if rendered else []

    tail = ""
    for table, rendered_lines in new_tables.items():
        tail += f"\n[{format_toml_path(list(table))}]\n" + "".join(rendered_lines)

    return "".join(lines) + tail


def delete_toml_entries(text: str, entries: list[list[str]]) -> str:
    """Drop every table and assignment at or below the given paths.

    A path inside an inline-table value is one assignment, so callers route
    those through split_inline_deletions first.
    """
    lines = text.splitlines(keepends=True)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    prefixes = [tuple(entry) for entry in entries]

    def under(path: tuple[str, ...]) -> bool:
        return any(path[: len(prefix)] == prefix for prefix in prefixes)

    headers = [
        (index, tuple(split_toml_key(match.group(1))))
        for index, line in enumerate(lines)
        if (match := TOML_TABLE_RE.match(line))
    ]
    bounds = [index for index, _ in headers] + [len(lines)]
    remove: set[int] = set()
    for position, (index, table) in enumerate(headers):
        if under(table):
            remove.update(range(index, bounds[position + 1]))
    for path, (start, end) in scan_toml_assignments(lines).items():
        if under(path):
            remove.update(range(start, end))
    return "".join(line for index, line in enumerate(lines) if index not in remove)
