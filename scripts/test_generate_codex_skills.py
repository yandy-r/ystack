#!/usr/bin/env python3
"""Critical tests for relocatable native Codex skill resources."""

from __future__ import annotations

import os
import re
import shutil
import sys
import tempfile
import unittest
from collections import Counter
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate_codex_skills as skills  # noqa: E402
from generate_codex_common import (  # noqa: E402
    PLUGIN_ROOT,
    SRC_SKILLS_DIR,
    VERBATIM_SKILL_FILES,
    drop_self_fallbacks,
    parse_frontmatter,
    self_fallbacks,
)


def without_dropped_fallbacks(rel: Path, legacy: str) -> str:
    """Remove from the legacy baseline exactly the fallback lines native rendering drops.

    Native shell rendering is line-for-line, so the indices self_fallbacks() reports on the
    undropped native render are the legacy lines that native output no longer carries.
    """
    if rel.suffix not in skills.NATIVE_SHELL_SUFFIXES:
        return legacy
    with patch.object(skills, "drop_self_fallbacks", lambda text: text):
        undropped = skills.rewrite_native_paths(legacy, rel)
    dead = {index for index, _ in self_fallbacks(undropped)}
    return "".join(line for index, line in enumerate(legacy.splitlines(keepends=True)) if index not in dead)


class NativeResourceTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.written = skills.write_tree(cls.root, False, native_paths=True)
        cls.legacy_root = cls.root / "legacy-baseline"
        skills.write_tree(cls.legacy_root, False, native_paths=False)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def test_native_output_has_no_installer_dependency_and_preserves_verbatim_files(self) -> None:
        verbatim_outputs = {
            skills.plugin_output_path(Path(rel)).relative_to(PLUGIN_ROOT): rel for rel in VERBATIM_SKILL_FILES
        }
        for rel in sorted(self.written):
            with self.subTest(path=rel):
                output = (self.root / rel).read_bytes()
                if rel in verbatim_outputs:
                    self.assertEqual(output, (SRC_SKILLS_DIR / verbatim_outputs[rel]).read_bytes())
                else:
                    self.assertNotIn(b"~/.codex/plugins/ycc", output)
                    # A scaffold payload intentionally names the future authored skill.
                    logical = b"${CLAUDE_PLUGIN_ROOT}/skills/{{NAME}}/scripts/<name>.sh"
                    self.assertNotIn(b"CLAUDE_PLUGIN_ROOT", output.replace(logical, b""))
                if rel.name == "SKILL.md":
                    _, body = parse_frontmatter(output.decode())
                    instruction = body.lstrip().split("\n\n", 1)[0]
                    self.assertIn("this SKILL.md's directory", instruction)
                    self.assertIn("absolute path", instruction)
                    self.assertIn("project as cwd", instruction)

    def assert_resource_paths(self, rel: Path, legacy: str, content: str) -> int:
        references = re.findall(r"~/\.codex/plugins/ycc/([a-zA-Z0-9_./{},#-]+)", legacy)
        references += ["shared/" + tail for tail in re.findall(r"(?:\.\./)+_shared/([a-zA-Z0-9_./{},#-]+)", legacy)]
        references += re.findall(r"(?:\.\./)+(shared/references/[a-zA-Z0-9_./{},#-]+)", legacy)
        counts = Counter(ref.split("#", 1)[0].rstrip(".,") for ref in references if "{{" not in ref)
        for reference, count in counts.items():
            if not reference:
                continue
            if rel.as_posix() in skills.NATIVE_PROMPT_FILES:
                prefix = re.escape(skills.NATIVE_PLUGIN_PLACEHOLDER + "/")
                tail = reference
            else:
                # Use only the resource's non-traversal tail to find it, then resolve the
                # traversal actually emitted so an extra ../ cannot false-pass.
                expected = os.path.relpath(reference, rel.parent) + ("/" if reference.endswith("/") else "")
                tail = expected
                while tail.startswith("../"):
                    tail = tail[3:]
                if tail in {"", ".."}:
                    # Ancestor-only directory examples are followed by an angle-bracket template.
                    tail = expected
                    prefix = ""
                else:
                    prefix = r"(?:\$\{SCRIPT_DIR\}/)?(?:\.\./)*"
            ending = r"(?=<)" if tail.startswith("../") and not tail.strip("./") else r"(?=$|[\s\"'`()<>#.,:;])"
            pattern = r"(?<![\w./~${}-])(" + prefix + re.escape(tail) + ")" + ending
            emitted = re.findall(pattern, content)
            already_rewritten = (
                len(re.findall(r"(?:\.\./)+" + re.escape(reference) + ending, legacy))
                if rel.suffix == ".md" and reference.startswith("shared/references/")
                else 0
            )
            self.assertEqual(
                len(emitted), count + len(re.findall(pattern, legacy)) - already_rewritten, (rel, reference, emitted)
            )
            for value in emitted:
                if value.startswith(skills.NATIVE_PLUGIN_PLACEHOLDER + "/"):
                    target = self.root / value.removeprefix(skills.NATIVE_PLUGIN_PLACEHOLDER + "/")
                else:
                    target = self.root / rel.parent / value.removeprefix("${SCRIPT_DIR}/")
                # Expand compact lists in the value actually emitted, not an expected path.
                brace = re.search(r"\{([^{}]+)\}", str(target))
                targets = [str(target)]
                if brace:
                    targets = [
                        str(target)[: brace.start()] + name + str(target)[brace.end() :]
                        for name in brace.group(1).split(",")
                    ]
                for path in targets:
                    resolved = Path(path).resolve()
                    self.assertTrue(resolved.is_relative_to(self.root), (rel, value))
                    self.assertTrue(resolved.exists(), (rel, value, resolved))
        return sum(counts.values())

    def test_rewritten_bundled_resources_resolve_inside_emitted_tree(self) -> None:
        checked = 0
        for rel in sorted(self.written):
            legacy = self.legacy_root / rel
            if not legacy.is_file() or not skills.should_transform_text(legacy):
                continue
            if rel.as_posix() == "shared/references/target-capability-matrix.md":
                continue
            with self.subTest(document=rel):
                content = (self.root / rel).read_text(encoding="utf-8")
                checked += self.assert_resource_paths(rel, without_dropped_fallbacks(rel, legacy.read_text()), content)
        self.assertGreater(checked, 200)

    def test_resource_invariant_rejects_extra_parent_traversal(self) -> None:
        rel = Path("skills/git-workflow/references/commit-phases.md")
        legacy = (self.legacy_root / rel).read_text()
        content = (self.root / rel).read_text()
        # Simulate a bad native renderer in memory; never mutate authored/generated files.
        mutated, changes = re.subn(r"\.\./scripts/analyze-changes\.sh", "../../scripts/analyze-changes.sh", content)
        self.assertGreater(changes, 0)
        with self.assertRaises(AssertionError):
            self.assert_resource_paths(rel, legacy, mutated)

    def test_executable_script_directory_references_have_a_definition(self) -> None:
        checked = 0
        for rel in sorted(self.written):
            if rel.suffix not in {".sh", ".bash"}:
                continue
            defined = False
            for number, line in enumerate((self.root / rel).read_text().splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue
                if re.match(r"^\s*(?:local\s+)?SCRIPT_DIR=", line):
                    defined = True
                if "${SCRIPT_DIR}/" in line:
                    with self.subTest(script=rel, line=number):
                        self.assertTrue(defined)
                        checked += 1
        self.assertGreater(checked, 20)

    def test_forwarded_prompts_require_absolute_substitution(self) -> None:
        for rel in skills.NATIVE_PROMPT_FILES:
            content = (self.root / rel).read_text()
            self.assertIn("Before forwarding any prompt", content)
            references = re.findall(r"<installed ycc plugin root>/([\w./-]+)", content)
            self.assertTrue(references)
            for reference in references:
                self.assertTrue((self.root / reference).is_file())
        for rel in ("skills/git-workflow/SKILL.md", "skills/git-workflow/references/commit-phases.md"):
            self.assertIn("Before Step 14 dispatch, expand every", (self.root / rel).read_text())
        payload = self.root / "skills/bundle-author/references/templates/skill-template.md"
        self.assertIn("${CLAUDE_PLUGIN_ROOT}/skills/{{NAME}}/scripts/<name>.sh", payload.read_text())

    def test_frontmatter_and_legacy_home_references_are_relative_but_user_home_is_not(self) -> None:
        raw = (
            "---\nname: sample\ndescription: 'Read ${CLAUDE_PLUGIN_ROOT}/skills/_shared/"
            "references/branching-model.md'\n---\n"
            "Read ~/.codex/plugins/ycc/shared/references/branching-model.md and "
            "~/.codex/skills/git-workflow/SKILL.md. Keep ~/.codex/settings.json, "
            "~/.codex/session-data/ and ~/.codex/skills/not-a-bundled-skill/SKILL.md.\n"
        )
        rendered = skills.transform_skill_markdown(
            raw, {}, native_paths=True, output_path=Path("skills/sample/SKILL.md")
        )
        frontmatter, body = parse_frontmatter(rendered)
        self.assertIn("../../shared/references/branching-model.md", frontmatter["description"])
        self.assertIn("../../shared/references/branching-model.md", body)
        self.assertIn("../git-workflow/SKILL.md", body)
        self.assertIn("~/.codex/settings.json", body)
        self.assertIn("~/.codex/session-data/", body)
        self.assertIn("~/.codex/skills/not-a-bundled-skill/SKILL.md", body)

    def test_bundle_release_still_names_authored_metadata(self) -> None:
        content = (self.root / "skills/bundle-release/SKILL.md").read_text(encoding="utf-8")
        self.assertIn("ycc/.claude-plugin/plugin.json", content)
        self.assertNotIn("ycc/.codex-plugin/plugin.json", content)


class SharedReferenceRelocationTestCase(unittest.TestCase):
    def test_changed_references_resolve_without_legacy_home_plugin(self) -> None:
        references = {
            "skills/prp-pr/SKILL.md": {"pr-base-and-backport.md": 2, "forge-detection.md": 2},
            "skills/research-to-issues/SKILL.md": {"forge-detection.md": 1},
            "skills/prp-plan/SKILL.md": {"worktree-strategy.md": 3},
            "skills/orchestrate/references/dispatch-playbook.md": {"worktree-strategy.md": 1},
        }
        for native in (False, True):
            with self.subTest(native=native), tempfile.TemporaryDirectory() as tmp:
                sandbox = Path(tmp)
                home = sandbox / "isolated home"
                home.mkdir()
                original = sandbox / "checkout/.codex-plugin/ycc"
                skills.write_tree(original, False, native_paths=native)
                relocated = sandbox / "relocated install with spaces/ycc"
                relocated.parent.mkdir()
                shutil.move(original, relocated)
                self.assertFalse((home / ".codex/plugins/ycc").exists())
                with patch.dict(os.environ, {"HOME": str(home)}):
                    for document, expected in references.items():
                        content = (relocated / document).read_text(encoding="utf-8")
                        for name, count in expected.items():
                            emitted = re.findall(r"([^\s`\"'()<>]+/" + re.escape(name) + r"(?:#[\w-]+)?)", content)
                            self.assertEqual(len(emitted), count, (document, name, emitted))
                            for reference in emitted:
                                path = Path(reference.split("#", 1)[0]).expanduser()
                                target = (relocated / Path(document).parent / path).resolve()
                                self.assertTrue(target.is_relative_to(relocated), (document, reference, target))
                                self.assertTrue(target.is_file(), (document, reference, target))
                forwarded = (relocated / "skills/plan-workflow/references/planning-agents.md").read_text(
                    encoding="utf-8"
                )
                self.assertIn("Before forwarding any prompt", forwarded)
                prompt_root = re.search(r"\(resolve `([^`]+)` from this document's directory\)", forwarded)
                self.assertIsNotNone(prompt_root)
                absolute_root = (relocated / "skills/plan-workflow/references" / prompt_root.group(1)).resolve()
                self.assertEqual(absolute_root, relocated)
                placeholders = re.findall(re.escape(skills.NATIVE_PLUGIN_PLACEHOLDER) + r"/([\w./-]+)", forwarded)
                self.assertIn("shared/references/worktree-strategy.md", placeholders)
                for resource in placeholders:
                    self.assertTrue((absolute_root / resource).is_file(), resource)

    def test_default_markdown_never_depends_on_home_for_shared_references(self) -> None:
        verbatim = {skills.plugin_output_path(Path(rel)).relative_to(PLUGIN_ROOT) for rel in VERBATIM_SKILL_FILES}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            checked = 0
            for rel in sorted(skills.write_tree(root, False)):
                if rel.suffix != ".md" or rel in verbatim:
                    continue
                with self.subTest(path=rel):
                    self.assertNotIn("~/.codex/plugins/ycc/shared/references/", (root / rel).read_text())
                    checked += 1
            self.assertGreater(checked, 100)

    def test_default_preserves_legacy_executables_and_other_resource_paths(self) -> None:
        raw = (
            "---\nname: sample\ndescription: sample\n---\n"
            "Read ${CLAUDE_PLUGIN_ROOT}/skills/_shared/references/forge-detection.md#gitlab.\n"
            "Run ${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/pr-guard.sh.\n"
            "See ${CLAUDE_PLUGIN_ROOT}/skills/git-workflow/templates/commit-types.md.\n"
        )
        rendered = skills.transform_skill_markdown(raw, {})
        self.assertIn("../../shared/references/forge-detection.md#gitlab.", rendered)
        self.assertIn("~/.codex/plugins/ycc/shared/scripts/pr-guard.sh.", rendered)
        self.assertIn("~/.codex/plugins/ycc/skills/git-workflow/templates/commit-types.md.", rendered)


class SelfFallbackTestCase(unittest.TestCase):
    def test_fallback_identical_to_its_primary_is_dropped_but_real_alternatives_stay(self) -> None:
        script = (
            'LIB="${SCRIPT_DIR}/../lib.sh"\n'
            '[[ -f "$LIB" ]] || LIB="${SCRIPT_DIR}/../lib.sh"\n'
            'OTHER="${SCRIPT_DIR}/../other.sh"\n'
            '[[ -f "$OTHER" ]] || OTHER="${HOME}/.agents/ycc-shared/other.sh"\n'
            'LIB="${SCRIPT_DIR}/../moved.sh"\n'
            '[[ -f "$LIB" ]] || LIB="${SCRIPT_DIR}/../lib.sh"\n'
        )
        self.assertEqual(
            drop_self_fallbacks(script),
            'LIB="${SCRIPT_DIR}/../lib.sh"\n'
            'OTHER="${SCRIPT_DIR}/../other.sh"\n'
            '[[ -f "$OTHER" ]] || OTHER="${HOME}/.agents/ycc-shared/other.sh"\n'
            'LIB="${SCRIPT_DIR}/../moved.sh"\n'
            '[[ -f "$LIB" ]] || LIB="${SCRIPT_DIR}/../lib.sh"\n',
        )

    def test_only_the_adjacent_primary_makes_a_fallback_dead(self) -> None:
        branch = (
            'if [[ -n "$X" ]]; then\n'
            '  LIB="${HOME}/b.sh"\n'
            "else\n"
            '  LIB="${SCRIPT_DIR}/a.sh"\n'
            "fi\n"
            '[[ -f "$LIB" ]] || LIB="${SCRIPT_DIR}/a.sh"\n'
        )
        heredoc = 'cat <<EOF\nLIB="${SCRIPT_DIR}/a.sh"\nEOF\n[[ -f "$LIB" ]] || LIB="${SCRIPT_DIR}/a.sh"\n'
        self.assertEqual(drop_self_fallbacks(branch), branch)
        self.assertEqual(drop_self_fallbacks(heredoc), heredoc)
        prefixed = 'local LIB="${SCRIPT_DIR}/a.sh"\n\n# note\n[[ -f "$LIB" ]] || LIB="${SCRIPT_DIR}/a.sh"\n'
        self.assertEqual(drop_self_fallbacks(prefixed), 'local LIB="${SCRIPT_DIR}/a.sh"\n\n# note\n')

    def test_native_scripts_carry_no_dead_fallback(self) -> None:
        rel = Path("skills/research-to-issues/scripts/validate-prerequisites.sh")
        source = (SRC_SKILLS_DIR / "research-to-issues/scripts/validate-prerequisites.sh").read_text(encoding="utf-8")
        rendered = skills.rewrite_native_paths(
            skills.apply_codex_text_transforms(skills.rewrite_plugin_paths(source), {}), rel
        )
        self.assertIn('FORGE_LIB="${SCRIPT_DIR}/../../../shared/scripts/lib/forge.sh"\n# shellcheck', rendered)
        self.assertNotIn("|| FORGE_LIB=", rendered)


class LegacyCompatibilityTestCase(unittest.TestCase):
    def test_default_and_explicit_legacy_trees_match(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            default = Path(tmp) / "default"
            explicit = Path(tmp) / "explicit"
            written = skills.write_tree(default, False)
            self.assertEqual(written, skills.write_tree(explicit, False, native_paths=False))
            for rel in sorted(written):
                with self.subTest(path=rel):
                    self.assertEqual((default / rel).read_bytes(), (explicit / rel).read_bytes())

    def test_repository_tree_matches_its_listing_state(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            written = skills.write_tree(root, False, native_paths=skills.repository_native_paths())
            self.assertEqual(skills.compare_trees(root, PLUGIN_ROOT, written), [])

    def test_repository_native_paths_tracks_codex_listing(self) -> None:
        model = skills.load_package_model()
        expected = all(
            any(
                row.runtime == "codex" and row.status == "included" and row.mechanism == "native" and row.listed
                for row in package.runtimes
            )
            for package in model.packages
            if package.key in {"ycc", "ycc-mcp"}
        )
        self.assertEqual(skills.repository_native_paths(), expected)
        for listed, expected_native in (((), False), (("ycc",), False), (("ycc", "ycc-mcp"), True)):
            fixture = replace(
                model,
                packages=tuple(
                    replace(
                        package,
                        runtimes=tuple(
                            (replace(entry, listed=package.key in listed) if entry.runtime == "codex" else entry)
                            for entry in package.runtimes
                        ),
                    )
                    for package in model.packages
                ),
            )
            with (
                self.subTest(listed=listed),
                patch.object(skills, "load_package_model", return_value=fixture),
            ):
                self.assertEqual(skills.repository_native_paths(), expected_native)


if __name__ == "__main__":
    unittest.main(verbosity=2)
