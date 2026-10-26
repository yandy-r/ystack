#!/usr/bin/env python3
"""Regression tests for the S5 proof in scripts/omp_scripted_smoke.py (YAN-1606).

A compaction request in the middle of the whole-package skill read batch can replace late
results with "No result provided". check-skills must reject any session record holding a
request beyond the two scripted S5 turns, and the scripted models must declare a context
window large enough that the batch never triggers compaction. No omp binary is needed.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import omp_scripted_smoke as smoke  # noqa: E402

CACHE = "/home/u/.omp/plugins/cache/plugins/ycc___ycc___1.0.0"


class CheckSkillsTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.package = self.root / "package"
        for directory, name in (("alpha", "alpha"), ("beta", "beta")):
            skill = self.package / "skills" / directory
            skill.mkdir(parents=True)
            (skill / "SKILL.md").write_text(f"---\nname: {name}\n---\nbody\n", encoding="utf-8")
        self.out = self.root / "s5.json"

    def request(self, key: str, step: int, results: list[str], expanded: list[str]) -> dict[str, Any]:
        return {"key": key, "step": step, "results": results, "expanded": expanded}

    def record(self, *extra: dict[str, Any], expanded: list[str] | None = None) -> None:
        reads = [
            f"[Skill file: {CACHE}/skills/{name}/SKILL.md]\n---\nname: {name}\n---\n" for name in ("alpha", "beta")
        ]
        requests = [
            self.request("SCRIPT-skills", 0, [], ["clean"] if expanded is None else expanded),
            self.request("SCRIPT-skills", 1, reads, ["clean"]),
            *extra,
        ]
        self.out.write_text(json.dumps({"requests": requests}), encoding="utf-8")

    def test_two_scripted_turns_pass(self) -> None:
        self.record()
        self.assertIn("all 2 ycc skills", smoke.check_skills(self.out, self.package))

    def test_unmarked_compaction_request_fails(self) -> None:
        # The pre-fix record: the batch returned, then omp sent a marker-less handoff request.
        self.record(self.request("", 1, [], []), self.request("", 2, [], []))
        with self.assertRaisesRegex(smoke.SmokeError, "<unmarked>"):
            smoke.check_skills(self.out, self.package)

    def test_extra_marked_request_fails(self) -> None:
        # A future omp could copy the prompt (and its marker) into the compaction request.
        self.record(self.request("SCRIPT-skills", 1, [], ["clean"]))
        with self.assertRaisesRegex(smoke.SmokeError, "steps 0 and 1 only"):
            smoke.check_skills(self.out, self.package)

    def test_unexpanded_command_fails(self) -> None:
        self.record(expanded=[])
        with self.assertRaisesRegex(smoke.SmokeError, "did not expand"):
            smoke.check_skills(self.out, self.package)

    def test_no_result_provided_fails(self) -> None:
        self.record()
        data = json.loads(self.out.read_text(encoding="utf-8"))
        data["requests"][1]["results"][1] = "No result provided"
        self.out.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(smoke.SmokeError, "No result provided"):
            smoke.check_skills(self.out, self.package)


class ModelsYmlTest(unittest.TestCase):
    def test_every_model_declares_a_large_window(self) -> None:
        providers = json.loads(smoke.models_yml(1234))["providers"]
        models = [m for p in providers.values() for m in p["models"]]
        self.assertEqual(len(models), len(smoke.MODELS) + 1)
        # omp otherwise assumes 128k tokens, which a whole-package read batch overflows.
        for model in models:
            self.assertGreaterEqual(model["contextWindow"], 1_000_000, model["id"])
            self.assertGreater(model["maxTokens"], 0, model["id"])


if __name__ == "__main__":
    unittest.main()
