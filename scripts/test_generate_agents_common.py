#!/usr/bin/env python3
"""Regressions for the agents-target text transforms' quoted-home rewrite."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from generate_agents_common import apply_agents_text_transforms  # noqa: E402


class QuotedHomeSuffixTestCase(unittest.TestCase):
    def test_python_output_keeps_quoted_tilde(self) -> None:
        # Python (or JSON/YAML/...) must keep the literal "~/" string:
        # os.path.expanduser would not expand "${HOME}".
        # The input reaches the gate: the agents pass only rewrites "~/.agents/".
        raw = 'location = os.path.expanduser("~/.agents/state.json")\n'
        transformed = apply_agents_text_transforms(raw, {}, output_suffix=".py")
        self.assertIn('os.path.expanduser("~/.agents/state.json")', transformed)
        self.assertNotIn("${HOME}", transformed)

    def test_shell_output_expands_quoted_home(self) -> None:
        raw = '[[ -f "$LIB" ]] || LIB="~/.agents/ycc-shared/scripts/lib/forge.sh"\n'
        transformed = apply_agents_text_transforms(raw, {}, output_suffix=".sh")
        self.assertIn('"${HOME}/.agents/ycc-shared/scripts/lib/forge.sh"', transformed)
        self.assertNotIn('"~/.agents/', transformed)


if __name__ == "__main__":
    unittest.main()
