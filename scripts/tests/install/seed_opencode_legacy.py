#!/usr/bin/env python3
"""Seed the pre-v6.3.1 opencode file-copy install for the OMP coexistence harness.

The installer now ships opencode as the ``@yandy-r/ycc-opencode`` npm plugin, so it
no longer writes ``~/.config/opencode/{skills,agents,commands}``. Upgraded machines
still have those copies, recorded in ``installed-units.json``; OMP's dedupe step
must keep hiding their ``opencode/<name>`` aliases. Runs inside the harness
sandbox, so ``$HOME`` and the ledger location come from that environment.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import install_slices  # noqa: E402  (path set above)

UNITS = ("skills", "agents", "commands")


def main() -> int:
    source = Path(sys.argv[1])
    ledger_path = install_slices.state_path()
    ledger = install_slices.load_state(ledger_path)
    for unit in UNITS:
        dest = Path.home() / ".config/opencode" / unit
        dest.mkdir(parents=True, exist_ok=True)
        names: list[str] = []
        for entry in sorted((source / unit).iterdir()):
            if entry.name.startswith("_"):
                continue
            if entry.is_dir():
                shutil.copytree(entry, dest / entry.name)
            else:
                shutil.copy2(entry, dest / entry.name)
            names.append(entry.name)
        ledger[str(dest)] = sorted(set(ledger.get(str(dest), [])) | set(names))
    install_slices.save_state(ledger_path, ledger)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
