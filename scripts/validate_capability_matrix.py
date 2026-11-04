#!/usr/bin/env python3
"""Validate the target capability matrix against the package-model runtimes.

Parse the first table under ``## Capability Matrix`` in
ycc/skills/_shared/references/target-capability-matrix.md and check that:

- the header is ``capability`` followed by the canonical target order;
- the capability rows are exactly the canonical capabilities, in order;
- every header target is a runtime in ycc/settings/packages.schema.json;
- every cell is ``supported``, ``partial``, or ``unsupported``;
- no capability row repeats or has an empty name;
- every ``partial``/``unsupported`` cell has a ``**CAP:target**`` note in Notes;
- every ``**X:target**`` note names a known capability and target;
- with a repository root, a target in ``GENERATED_TREES`` agrees with its tree: until the
  tree holds an installable package (``<tree>/*/package.json``) every cell for that target is
  ``unsupported`` and (with a package manifest) no ``packages.*.runtimes.<target>`` row is
  ``included``; once it does, ``INSTALL_PATH`` for that target is not ``unsupported``.

Notes without a colon (for example ``**INVOCATION POLICY**``) are free-form.
Exit 0 when valid, 1 on any error (errors go to stderr).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MATRIX_PATH = REPO_ROOT / "ycc/skills/_shared/references/target-capability-matrix.md"
DEFAULT_SCHEMA_PATH = REPO_ROOT / "ycc/settings/packages.schema.json"
MANIFEST_REL = Path("ycc/settings/packages.json")

CANONICAL_TARGETS = ("claude", "cursor", "codex", "opencode", "omp", "pi")
# Targets modeled before any installer ships, keyed to their generated tree. The tree counts as
# present only once it holds an installable package (``<tree>/*/package.json``): skills land under
# packages/pi/ycc/skills (YAN-1184) before the package generator writes package.json (YAN-1188).
# The check fails closed both ways, like PI1 in audit-install-assumptions.sh: no installable
# package means every verdict is `unsupported` and no package row for the target is `included`,
# and an installable package means INSTALL_PATH can no longer be `unsupported` (ADR 0003).
GENERATED_TREES = {"pi": Path("packages/pi")}
INSTALLABLE_MARKER = "*/package.json"
# Pinned row order. Adding a capability requires updating this tuple and the
# capability detection in ycc/skills/compatibility-audit/scripts/audit-target-features.sh.
CANONICAL_CAPABILITIES = (
    "SKILLS",
    "COMMANDS",
    "AGENTS",
    "HOOKS.PreToolUse",
    "HOOKS.PostToolUse",
    "HOOKS.Stop",
    "MCP",
    "INSTALL_PATH",
    "DANGEROUS_MODE",
    "WORKTREE",
    "MODS",
)
VOCABULARY = frozenset({"supported", "partial", "unsupported"})
NOTED_VERDICTS = frozenset({"partial", "unsupported"})
MATRIX_HEADING = "## Capability Matrix"
NOTES_HEADING = "## Notes"
NOTE_KEY = re.compile(r"^\*\*(?P<key>[^*]+)\*\*\s*$")
# Matches the audit-target-features.sh parser: separator cells are dashes only, no colons.
SEPARATOR_CELL = re.compile(r"^-+$")


@dataclass(frozen=True)
class Matrix:
    targets: tuple[str, ...]
    rows: tuple[tuple[str, tuple[str, ...]], ...]


class MatrixError(Exception):
    """The matrix file cannot be parsed far enough to validate it."""


def _section(lines: Sequence[str], heading: str) -> list[tuple[int, str]]:
    """Return (lineno, text) pairs between ``heading`` and the next ``## `` heading."""
    out: list[tuple[int, str]] = []
    inside = False
    for lineno, line in enumerate(lines, 1):
        if line.strip() == heading:
            inside = True
            continue
        if inside and line.startswith("## "):
            break
        if inside:
            out.append((lineno, line))
    if not inside:
        raise MatrixError(f"missing section {heading!r}")
    return out


def _cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def parse_matrix(lines: Sequence[str], errors: list[str]) -> Matrix:
    header: list[str] | None = None
    rows: list[tuple[str, tuple[str, ...]]] = []
    in_table = False
    for lineno, line in enumerate(lines, 1):
        if line.strip() == MATRIX_HEADING:
            break
        if line.lstrip().startswith("|"):
            errors.append(f"line {lineno}: table before Capability Matrix would be parsed by audit parsers")
    for lineno, line in _section(lines, MATRIX_HEADING):
        if not line.strip().startswith("|"):
            if in_table:
                break
            continue
        in_table = True
        cells = _cells(line)
        if all(SEPARATOR_CELL.match(cell) for cell in cells):
            continue
        if header is None:
            header = cells
            continue
        if len(cells) != len(header):
            errors.append(f"line {lineno}: expected {len(header)} cells, found {len(cells)}")
            continue
        rows.append((cells[0], tuple(cells[1:])))
    if header is None:
        raise MatrixError(f"no table under {MATRIX_HEADING!r}")
    if not header or header[0] != "capability":
        errors.append(f"header must start with 'capability', got {header[:1]}")
    return Matrix(targets=tuple(header[1:]), rows=tuple(rows))


def load_schema_runtimes(schema_path: Path) -> frozenset[str]:
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    try:
        enum = schema["$defs"]["Package"]["properties"]["runtimes"]["propertyNames"]["enum"]
    except (KeyError, TypeError) as exc:
        raise MatrixError(f"{schema_path}: no runtimes propertyNames enum") from exc
    if not isinstance(enum, list) or not all(isinstance(item, str) for item in enum):
        raise MatrixError(f"{schema_path}: runtimes propertyNames enum is not a string list")
    return frozenset(enum)


def note_keys(lines: Sequence[str]) -> list[tuple[int, str]]:
    keys: list[tuple[int, str]] = []
    for lineno, line in _section(lines, NOTES_HEADING):
        match = NOTE_KEY.match(line.strip())
        if match:
            keys.append((lineno, match.group("key").strip()))
    return keys


def _included_rows(manifest_path: Path, target: str) -> list[str]:
    """Return ``packages.<key>.runtimes.<target>`` labels whose status is ``included``."""
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    packages = data.get("packages") if isinstance(data, dict) else None
    if not isinstance(packages, dict):
        raise MatrixError(f"{manifest_path}: expected a packages object")
    labels: list[str] = []
    for key, package in packages.items():
        runtimes = package.get("runtimes") if isinstance(package, dict) else None
        entry = runtimes.get(target) if isinstance(runtimes, dict) else None
        if isinstance(entry, dict) and entry.get("status") == "included":
            labels.append(f"packages.{key}.runtimes.{target}")
    return labels


def generated_tree_errors(matrix: Matrix, repo_root: Path, manifest_path: Path | None = None) -> list[str]:
    """Fail closed when a GENERATED_TREES target's verdicts or package rows disagree with its tree."""
    errors: list[str] = []
    for target, tree in GENERATED_TREES.items():
        present = any(path.is_file() for path in (repo_root / tree).glob(INSTALLABLE_MARKER))
        marker = f"{tree}/{INSTALLABLE_MARKER}"
        if not present and manifest_path is not None:
            errors.extend(
                f"{label} is included but {marker} does not exist" for label in _included_rows(manifest_path, target)
            )
        if target not in matrix.targets:
            continue
        column = matrix.targets.index(target)
        verdicts = {capability: cells[column] for capability, cells in matrix.rows if len(cells) > column}
        if not present:
            claimed = [f"{cap}:{target}={verdict}" for cap, verdict in verdicts.items() if verdict != "unsupported"]
            if claimed:
                errors.append(f"{marker} does not exist but the matrix claims {', '.join(claimed)}")
        elif verdicts.get("INSTALL_PATH") == "unsupported":
            errors.append(f"{marker} exists but the matrix marks INSTALL_PATH:{target} unsupported")
    return errors


def validate(
    matrix_path: Path, schema_path: Path, repo_root: Path | None = None, manifest_path: Path | None = None
) -> list[str]:
    errors: list[str] = []
    lines = matrix_path.read_text(encoding="utf-8").splitlines()
    matrix = parse_matrix(lines, errors)
    runtimes = load_schema_runtimes(schema_path)

    if matrix.targets != CANONICAL_TARGETS:
        errors.append(f"header targets {list(matrix.targets)} must be exactly {list(CANONICAL_TARGETS)}")
    for target in matrix.targets:
        if target not in runtimes:
            errors.append(f"target {target!r} is not a runtime in {schema_path.name}")

    capabilities: set[str] = set()
    needed: list[str] = []
    for capability, verdicts in matrix.rows:
        if not capability:
            errors.append("capability row has an empty name")
        elif capability in capabilities:
            errors.append(f"duplicate capability row {capability!r}")
        capabilities.add(capability)
        for target, verdict in zip(matrix.targets, verdicts, strict=True):
            if verdict not in VOCABULARY:
                errors.append(f"{capability}:{target} = {verdict!r} is not one of {sorted(VOCABULARY)}")
            elif verdict in NOTED_VERDICTS:
                needed.append(f"{capability}:{target}")

    names = tuple(capability for capability, _ in matrix.rows)
    if names != CANONICAL_CAPABILITIES:
        missing = [name for name in CANONICAL_CAPABILITIES if name not in capabilities]
        unknown = sorted(name for name in capabilities if name and name not in CANONICAL_CAPABILITIES)
        detail: list[str] = []
        if missing:
            detail.append(f"missing {missing}")
        if unknown:
            detail.append(f"unknown {unknown}")
        if not missing and not unknown:
            detail.append(f"out of order: {list(names)}")
        errors.append(f"capability rows must be exactly {list(CANONICAL_CAPABILITIES)} in order; " + "; ".join(detail))

    present: set[str] = set()
    targets = set(matrix.targets)
    for lineno, key in note_keys(lines):
        if ":" not in key:
            continue
        present.add(key)
        capability, _, target = key.rpartition(":")
        if capability not in capabilities:
            errors.append(f"line {lineno}: note **{key}** names unknown capability {capability!r}")
        if target not in targets:
            errors.append(f"line {lineno}: note **{key}** names unknown target {target!r}")

    for key in needed:
        if key not in present:
            errors.append(f"partial/unsupported cell {key} has no **{key}** note")
    if repo_root is not None:
        errors.extend(generated_tree_errors(matrix, repo_root, manifest_path))
    return errors


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else None)
    parser.add_argument("--matrix", type=Path, default=DEFAULT_MATRIX_PATH)
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA_PATH)
    parser.add_argument("--manifest", type=Path, default=None, help="Default: <repo-root>/" + str(MANIFEST_REL))
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT, help="Root holding the generated trees.")
    args = parser.parse_args(argv)
    matrix_path: Path = args.matrix
    schema_path: Path = args.schema
    repo_root: Path = args.repo_root
    manifest_path: Path = args.manifest if args.manifest is not None else repo_root / MANIFEST_REL
    try:
        errors = validate(matrix_path, schema_path, repo_root, manifest_path)
    except (OSError, ValueError, MatrixError) as exc:
        print(f"validate_capability_matrix: {exc}", file=sys.stderr)
        return 1
    for error in errors:
        print(f"validate_capability_matrix: {matrix_path.name}: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"OK: {matrix_path.name} matches {schema_path.name} runtimes and has every required note.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
