#!/usr/bin/env python3
"""Validate concrete package IDs in live and v6 install documents.

Scan docs/install/*.md and docs/install/v6/*.md, including prose, tables and code
blocks. Native IDs use <package>@ycc; scoped npm IDs use the manifest's exact key.
Runtime guides permit only included packages for that runtime, regardless of
catalog listing. Mention excluded/deferred packages by bare name, not an install
ID. Generic <package>@ycc placeholders and unrelated third-party IDs are ignored.
This checks ID spelling and runtime eligibility, not command availability.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from package_model import DEFAULT_MANIFEST_PATH, REPO_ROOT, PackageModel, load_package_model

INSTALL_DOCS = Path("docs/install")
RUNTIMES = frozenset({"claude", "codex", "cursor", "opencode", "agents", "omp", "pi"})
# Match complete tokens, not a suffix of a scoped npm package or a placeholder.
# A scoped package may have an npm version/tag; its identity is the unversioned key.
ID_PATTERN = re.compile(
    r"(?<![\w@/<>$])(?:"
    r"(?P<npm>@[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:@[A-Za-z0-9_.^~+-]+)?"
    r"|(?P<package>[A-Za-z0-9][A-Za-z0-9_.-]*)@(?P<market>[A-Za-z0-9][A-Za-z0-9_.-]*)"
    r")"
)


def _id_error(package_id: str, mechanism: str, runtime: str | None, model: PackageModel) -> str | None:
    package = next((item for item in model.packages if item.key == package_id), None)
    if package is None:
        return f"unknown package ID {package_id!r}"
    if runtime is not None:
        row = model.lookup(package_id, runtime)
        if row is None:
            return f"{package_id!r} is unsupported on {runtime}"
        if row.status != "included":
            return f"{package_id!r} is {row.status} on {runtime}"
        if row.mechanism != mechanism:
            return f"{package_id!r} is not a {mechanism} package on {runtime}"
    elif not any(row.status == "included" and row.mechanism == mechanism for row in package.runtimes):
        return f"{package_id!r} is not an included {mechanism} package"
    return None


def _token_error(match: re.Match[str], runtime: str | None, model: PackageModel) -> str | None:
    npm = match.group("npm")
    if npm is not None:
        # Other dependencies in install docs are outside the workflow package model.
        scope, name = npm[1:].split("/", 1)
        if scope not in {"yandy-r", "ycc"} and not name.startswith("ycc"):
            return None
        return _id_error(npm, "npm", runtime, model)

    name = match.group("package")
    market = match.group("market").rstrip(".")  # Sentence punctuation is not part of an ID.
    if market == "ycc-mods":
        return None  # Independently versioned mods are explicitly outside this model.
    if market != "ycc" and not name.startswith("ycc") and name != "installer-fallback":
        return None
    if name == "ycc" and market == "local-ycc-plugins" and runtime in {None, "codex"}:
        return None  # The live Codex catalog remains valid until the listing flip.
    if market != "ycc":
        return f"unknown marketplace in {match.group()!r}; native package IDs use <package>@ycc"
    if name == "installer-fallback":
        return "'installer-fallback' is an internal modeling key, not an installable package ID"
    return _id_error(name, "native", runtime, model)


def validate(root: Path, model: PackageModel) -> list[str]:
    """Return path:line diagnostics for concrete IDs in live and v6 install docs."""
    directory = Path(root) / INSTALL_DOCS
    documents = sorted((*directory.glob("*.md"), *(directory / "v6").glob("*.md")))
    if not documents:
        return [f"{INSTALL_DOCS}: no install documents found"]
    errors: list[str] = []
    for path in documents:
        relative = path.relative_to(root)
        runtime = path.stem if path.parent == directory / "v6" and path.stem in RUNTIMES else None
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            errors.append(f"{relative}: cannot read install document: {exc}")
            continue
        for number, line in enumerate(text.splitlines(), 1):
            for match in ID_PATTERN.finditer(line):
                error = _token_error(match, runtime, model)
                if error is not None:
                    errors.append(f"{relative}:{number}: {match.group()!r}: {error}")
    return errors


def main(argv: list[str] | None = None) -> int:
    """Load the canonical package model and report install-document ID errors."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST_PATH)
    args = parser.parse_args(argv)
    try:
        errors = validate(args.root, load_package_model(args.manifest))
    except (OSError, ValueError) as exc:
        print(f"validate_install_doc_ids: {exc}", file=sys.stderr)
        return 1
    for error in errors:
        print(f"validate_install_doc_ids: {error}", file=sys.stderr)
    return int(bool(errors))


if __name__ == "__main__":
    sys.exit(main())
