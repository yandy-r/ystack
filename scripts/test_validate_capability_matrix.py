#!/usr/bin/env python3
"""Checked-in capability-matrix test plus self-contained negative fixtures and CLI coverage."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS_DIR))

from validate_capability_matrix import (  # noqa: E402
    CANONICAL_CAPABILITIES,
    CANONICAL_TARGETS,
    DEFAULT_MATRIX_PATH,
    DEFAULT_SCHEMA_PATH,
    MANIFEST_REL,
    REPO_ROOT,
    validate,
)

RUNTIMES = ["claude", "cursor", "codex", "opencode", "omp", "agents", "pi"]
HEADER = "| capability | " + " | ".join(CANONICAL_TARGETS) + " |"
SEPARATOR = "| --- | " + " | ".join("---" for _ in CANONICAL_TARGETS) + " |"
# Every capability is supported except the pi column (the last one), which is all unsupported
# as the fail-closed rule requires while packages/pi/ is absent, so each pi cell needs a note.
NOTE_KEY = "INSTALL_PATH:pi"
PI_NOTES = [line for cap in CANONICAL_CAPABILITIES for line in (f"**{cap}:pi**", "Not shipped yet.", "")]


def row(capability: str, last: str = "unsupported") -> str:
    cells = ["supported"] * (len(CANONICAL_TARGETS) - 1) + [last]
    return f"| {capability} | " + " | ".join(cells) + " |"


def fixture_rows() -> list[str]:
    return [row(cap) for cap in CANONICAL_CAPABILITIES]


def fixture_matrix(
    *,
    header: str = HEADER,
    separator: str = SEPARATOR,
    rows: list[str] | None = None,
    notes: list[str] | None = None,
) -> str:
    table = [header, separator, *(fixture_rows() if rows is None else rows)]
    note_lines = PI_NOTES if notes is None else notes
    return "\n".join(
        [
            "# Matrix",
            "",
            "## Capability Matrix",
            "",
            *table,
            "",
            "## Notes",
            "",
            *note_lines,
            "",
        ]
    )


def fixture_schema(runtimes: list[str] | None = None) -> dict[str, object]:
    enum = RUNTIMES if runtimes is None else runtimes
    return {"$defs": {"Package": {"properties": {"runtimes": {"propertyNames": {"enum": list(enum)}}}}}}


class MatrixFixture(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)

    def write(self, matrix: str, schema: dict[str, object] | None = None) -> tuple[Path, Path]:
        matrix_path = self.root / "target-capability-matrix.md"
        schema_path = self.root / "packages.schema.json"
        matrix_path.write_text(matrix, encoding="utf-8")
        schema_path.write_text(json.dumps(schema or fixture_schema()), encoding="utf-8")
        return matrix_path, schema_path

    def errors(self, matrix: str, schema: dict[str, object] | None = None) -> list[str]:
        # An empty repository root: the fixture must also satisfy the generated-tree rule.
        repo = self.root / "repo"
        repo.mkdir(exist_ok=True)
        return validate(*self.write(matrix, schema), repo)

    def assert_error(self, errors: list[str], needle: str) -> None:
        self.assertTrue(any(needle in error for error in errors), f"{needle!r} not in {errors}")

    def assert_tokens(self, errors: list[str], *tokens: str) -> None:
        self.assertTrue(any(all(t in error for t in tokens) for error in errors), f"{tokens!r} not in {errors}")


class CheckedInMatrixTests(MatrixFixture):
    def test_checked_in_matrix_passes(self) -> None:
        self.assertEqual(validate(DEFAULT_MATRIX_PATH, DEFAULT_SCHEMA_PATH, REPO_ROOT, REPO_ROOT / MANIFEST_REL), [])

    def test_fixture_passes(self) -> None:
        self.assertEqual(self.errors(fixture_matrix()), [])


class NegativeTests(MatrixFixture):
    def test_unknown_target_column_fails(self) -> None:
        header = HEADER.replace("| pi |", "| pie |")
        errors = self.errors(fixture_matrix(header=header))
        self.assert_error(errors, "must be exactly")
        self.assert_error(errors, "target 'pie' is not a runtime")

    def test_reordered_targets_fail(self) -> None:
        header = HEADER.replace("| cursor | codex |", "| codex | cursor |")
        self.assert_error(self.errors(fixture_matrix(header=header)), "must be exactly")

    def test_stale_target_not_in_schema_fails(self) -> None:
        for stale in ("omp", "pi"):
            with self.subTest(target=stale):
                schema = fixture_schema([r for r in RUNTIMES if r != stale])
                self.assert_error(self.errors(fixture_matrix(), schema), f"target '{stale}' is not a runtime")

    def test_missing_note_fails(self) -> None:
        errors = self.errors(fixture_matrix(notes=[]))
        self.assert_error(errors, f"{NOTE_KEY} has no **{NOTE_KEY}** note")

    def test_stale_note_target_fails(self) -> None:
        notes = [*PI_NOTES, "**SKILLS:pie**", "Stale."]
        self.assert_error(self.errors(fixture_matrix(notes=notes)), "unknown target 'pie'")

    def test_stale_note_capability_fails(self) -> None:
        notes = [*PI_NOTES, "**PLUGINS:omp**", "Stale."]
        self.assert_error(self.errors(fixture_matrix(notes=notes)), "unknown capability 'PLUGINS'")

    def test_bad_vocab_fails(self) -> None:
        rows = fixture_rows()
        rows[0] = row("SKILLS", "planned")
        self.assert_error(self.errors(fixture_matrix(rows=rows)), "'planned' is not one of")

    def test_duplicate_capability_fails(self) -> None:
        rows = fixture_rows()
        rows.insert(1, rows[0])
        self.assert_error(self.errors(fixture_matrix(rows=rows)), "duplicate capability row 'SKILLS'")

    def test_deleted_capability_row_fails(self) -> None:
        rows = [r for r in fixture_rows() if not r.startswith("| MODS |")]
        self.assert_error(self.errors(fixture_matrix(rows=rows)), "missing ['MODS']")

    def test_unknown_capability_row_fails(self) -> None:
        rows = [*fixture_rows(), row("PLUGINS")]
        self.assert_error(self.errors(fixture_matrix(rows=rows)), "unknown ['PLUGINS']")

    def test_reordered_capability_rows_fail(self) -> None:
        rows = fixture_rows()
        rows[0], rows[1] = rows[1], rows[0]
        self.assert_error(self.errors(fixture_matrix(rows=rows)), "out of order")

    def test_empty_capability_name_fails(self) -> None:
        rows = fixture_rows()
        rows[0] = row("")
        errors = self.errors(fixture_matrix(rows=rows))
        self.assert_error(errors, "capability row has an empty name")
        self.assert_error(errors, "missing ['SKILLS']")

    def test_alignment_colon_separator_fails(self) -> None:
        # The audit parser treats a colon separator as a data row, so the validator must too.
        separator = "| :-- | " + " | ".join(":-:" for _ in CANONICAL_TARGETS) + " |"
        self.assertNotEqual(self.errors(fixture_matrix(separator=separator)), [])

    def test_table_before_matrix_heading_fails(self) -> None:
        # The audit parsers read the first table in the file, so nothing may precede the matrix.
        matrix = fixture_matrix().replace("# Matrix\n", "# Matrix\n\n  | key | value |\n  | --- | ----- |\n", 1)
        self.assert_error(
            self.errors(matrix), "line 3: table before Capability Matrix would be parsed by audit parsers"
        )

    def test_colonless_note_is_allowed(self) -> None:
        notes = [*PI_NOTES, "**FREE FORM**", "Prose."]
        self.assertEqual(self.errors(fixture_matrix(notes=notes)), [])


class GeneratedTreeTests(MatrixFixture):
    """The pi column fails closed against an installable packages/pi/*/package.json (ADR 0003)."""

    def tree_errors(
        self,
        rows: list[str],
        *,
        tree: bool,
        manifest: dict[str, object] | None = None,
        skills_only: bool = False,
    ) -> list[str]:
        repo = self.root / "repo"
        repo.mkdir(exist_ok=True)
        if tree:
            (repo / "packages/pi/ycc").mkdir(parents=True, exist_ok=True)
            (repo / "packages/pi/ycc/package.json").write_text("{}", encoding="utf-8")
        if skills_only:
            # YAN-1184 generates skills before the package generator writes package.json.
            (repo / "packages/pi/ycc/skills").mkdir(parents=True, exist_ok=True)
        manifest_path = None
        if manifest is not None:
            manifest_path = self.root / "packages.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        matrix_path, schema_path = self.write(fixture_matrix(rows=rows))
        return validate(matrix_path, schema_path, repo, manifest_path)

    @staticmethod
    def manifest(status: str) -> dict[str, object]:
        return {"packages": {"ycc": {"runtimes": {"pi": {"status": status}}}}}

    def test_absent_tree_with_all_unsupported_passes(self) -> None:
        self.assertEqual(self.tree_errors(fixture_rows(), tree=False, manifest=self.manifest("deferred")), [])

    def test_skills_only_tree_counts_as_absent(self) -> None:
        self.assertEqual(self.tree_errors(fixture_rows(), tree=False, skills_only=True), [])
        rows = [row(cap, "partial" if cap == "INSTALL_PATH" else "unsupported") for cap in CANONICAL_CAPABILITIES]
        self.assert_tokens(self.tree_errors(rows, tree=False, skills_only=True), "packages/pi", "INSTALL_PATH:pi")

    def test_absent_tree_with_claimed_support_fails(self) -> None:
        rows = [row(cap, "partial" if cap == "SKILLS" else "unsupported") for cap in CANONICAL_CAPABILITIES]
        self.assert_tokens(self.tree_errors(rows, tree=False), "packages/pi", "SKILLS:pi")

    def test_absent_tree_with_included_pi_row_fails(self) -> None:
        errors = self.tree_errors(fixture_rows(), tree=False, manifest=self.manifest("included"))
        self.assert_tokens(errors, "packages.ycc.runtimes.pi", "packages/pi")

    def test_present_tree_with_unsupported_install_path_fails(self) -> None:
        self.assert_tokens(self.tree_errors(fixture_rows(), tree=True), "packages/pi", "INSTALL_PATH:pi")

    def test_present_tree_with_partial_install_path_passes(self) -> None:
        rows = [row(cap, "partial" if cap == "INSTALL_PATH" else "unsupported") for cap in CANONICAL_CAPABILITIES]
        self.assertEqual(self.tree_errors(rows, tree=True, manifest=self.manifest("included")), [])


class CliTests(MatrixFixture):
    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPTS_DIR / "validate_capability_matrix.py"), *args],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_cli_default_passes(self) -> None:
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

    def test_cli_override_fails_to_stderr(self) -> None:
        matrix_path, schema_path = self.write(fixture_matrix(notes=[]))
        result = self.run_cli("--matrix", str(matrix_path), "--schema", str(schema_path))
        self.assertEqual(result.returncode, 1)
        self.assertIn(NOTE_KEY, result.stderr)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
