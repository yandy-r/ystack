#!/usr/bin/env python3
"""Compatibility imports from the shared canonical rules-pointer implementation."""

from __future__ import annotations

import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_CANDIDATES = (
    _HERE.parent.parent / ("_shared") / "scripts",
    _HERE.parent.parent.parent / "shared" / "scripts",
    _HERE.parent.parent.parent / "ycc-shared" / "scripts",
)
for _directory in _CANDIDATES:
    if (_directory / "rules_pointer.py").is_file():
        sys.path.insert(0, str(_directory))
        break
else:
    print("rules_file_lib: shared rules_pointer.py not found (broken ycc install)", file=sys.stderr)
    raise SystemExit(1)

from rules_pointer import (  # noqa: E402, F401
    CLAUDE_SHIM_LINE,
    detect_agents_import,
    detect_eol,
    heading_of,
    is_legacy_agents_pointer,
    read_text_relaxed,
    split_sections,
)

__all__ = [
    "CLAUDE_SHIM_LINE",
    "detect_agents_import",
    "detect_eol",
    "heading_of",
    "is_legacy_agents_pointer",
    "read_text_relaxed",
    "split_sections",
]
