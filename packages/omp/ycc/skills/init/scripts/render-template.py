#!/usr/bin/env python3
"""Render a bundled /ycc:init template to stdout. Never writes files.

Usage:
  render-template.py --template <bundled-relative-or-absolute> [--profile FILE|-]
                     [--set KEY=VALUE]... [--keep BLOCK]...

* --template must resolve (after symlink resolution) inside the bundled
  templates directory next to this script (../templates). Anything else is
  rejected.
* --profile is key=value output from profile-project.sh; "-" or piped stdin
  reads it from stdin. Regular files, FIFOs and /dev/fd paths are accepted.
* --set KEY=VALUE overrides the profile. --keep BLOCK keeps a block that is
  not computed automatically (IF_RELEASE_MODEL, IF_ARTIFACT_STORE, IF_LABELS,
  IF_CONTRIBUTING, IF_CLAUDE_ONLY).

Blocks:
  {{#NAME}} ... {{/NAME}} markers must be alone on their line. Blocks nest,
  and a closer must match the innermost opener or rendering fails.
  Computed automatically:
    IF_RUST / IF_TS / IF_GO / IF_PYTHON / IF_TERRAFORM - language blocks.
      Single-language profile: that language only. Mixed profile: every
      component language in secondary_languages. gitignore.tmpl always keeps
      primary + secondary languages.
    IF_TEST_CMD / IF_LINT_CMD / IF_BUILD_CMD - kept only when that command was
      detected (value other than "unknown").
    IF_NO_TEST_CMD / IF_NO_LINT_CMD / IF_NO_BUILD_CMD - the inverse.

Undetected commands render as "# not detected" (safe in fenced shell blocks).
A rendered line of the form `run: # ...` fails the render: templates that put
a command into YAML must guard it with IF_*_CMD blocks.

Requires Python 3.11+. Exit codes: 0 ok, 1 usage or render error.
"""

from __future__ import annotations

import argparse
import os
import re
import stat
import sys
from pathlib import Path

if sys.version_info < (3, 11):  # noqa: UP036 - runtime guard for older python3
    print(f"render-template: python3 3.11+ required, found {sys.version.split()[0]}", file=sys.stderr)
    raise SystemExit(1)

NOT_DETECTED = "# not detected"
LANG_BLOCKS = {
    "rust": "IF_RUST",
    "typescript": "IF_TS",
    "javascript": "IF_TS",
    "go": "IF_GO",
    "python": "IF_PYTHON",
    "terraform": "IF_TERRAFORM",
}
OPEN_RE = re.compile(r"^\{\{#([A-Z0-9_]+)\}\}\s*$")
CLOSE_RE = re.compile(r"^\{\{/([A-Z0-9_]+)\}\}\s*$")
PLACEHOLDER_RE = re.compile(r"\{\{([A-Z0-9_]+)\}\}")
KEY_RE = re.compile(r"^[a-z_][a-z0-9_]*$")


def fail(msg: str) -> None:
    print(f"render-template: {msg}", file=sys.stderr)
    sys.exit(1)


def bundled_templates_dir() -> Path:
    return (Path(__file__).resolve().parent.parent / "templates").resolve()


def resolve_template(arg: str) -> Path:
    root = bundled_templates_dir()
    candidate = Path(arg)
    if not candidate.is_absolute():
        cwd_candidate = candidate.resolve()
        try:
            cwd_candidate.relative_to(root)
            candidate = cwd_candidate
        except ValueError:
            candidate = root / candidate
    resolved = candidate.resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        fail(f"template must live under the bundled templates dir ({root}): {arg}")
    if not resolved.is_file():
        fail(f"template not found: {arg}")
    return resolved


def read_profile(arg: str | None) -> dict[str, str]:
    if arg is None:
        if sys.stdin.isatty():
            return {}
        arg = "-"
    if arg == "-":
        raw = sys.stdin.buffer.read().decode("utf-8-sig", errors="replace")
    else:
        p = Path(arg)
        try:
            mode = p.stat().st_mode
        except OSError:
            fail(f"profile not found: {arg}")
        if stat.S_ISDIR(mode) or not os.access(p, os.R_OK):
            fail(f"profile is not a readable file: {arg}")
        raw = p.read_bytes().decode("utf-8-sig", errors="replace")
    prof: dict[str, str] = {}
    for line in raw.replace("\r", "").split("\n"):
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        if KEY_RE.match(key):
            prof[key] = value
    return prof


def language_blocks(prof: dict[str, str], template: Path, overrides: dict[str, str]) -> set[str]:
    primary = overrides.get("PRIMARY_LANG", prof.get("primary_language", "unknown"))
    secondary = [s for s in prof.get("secondary_languages", "").split(",") if s and s != "none"]
    langs: set[str] = set()
    if primary == "mixed" or template.name == "gitignore.tmpl":
        langs.update(secondary)
    if primary != "mixed":
        langs.add(primary)
    return {LANG_BLOCKS[language] for language in langs if language in LANG_BLOCKS}


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--template", required=True)
    ap.add_argument("--profile")
    ap.add_argument("--set", dest="sets", action="append", default=[])
    ap.add_argument("--keep", action="append", default=[])
    args = ap.parse_args()

    template = resolve_template(args.template)
    prof = read_profile(args.profile)
    overrides: dict[str, str] = {}
    for item in args.sets:
        if "=" not in item:
            fail("--set needs KEY=VALUE")
        k, _, v = item.partition("=")
        overrides[k] = v

    def command(name: str, key: str) -> tuple[str, bool]:
        value = overrides.get(name, prof.get(key, ""))
        if not value or value == "unknown":
            return NOT_DETECTED, False
        return value, True

    test_cmd, has_test = command("TEST_CMD", "test_cmd")
    lint_cmd, has_lint = command("LINT_CMD", "lint_cmd")
    build_cmd, has_build = command("BUILD_CMD", "build_cmd")

    values = {
        "PROJECT_NAME": prof.get("project_name", ""),
        "PROJECT_PURPOSE": prof.get("project_purpose", ""),
        "PROJECT_CONVENTIONS": prof.get("project_conventions", "")
        or "No additional project-specific conventions detected.",
        "PRIMARY_LANG": prof.get("primary_language", "unknown"),
        "SECONDARY_LANGS": prof.get("secondary_languages", "none"),
        "PACKAGE_MANAGER": prof.get("package_manager", "unknown"),
        "TEST_CMD": test_cmd,
        "LINT_CMD": lint_cmd,
        "BUILD_CMD": build_cmd,
    }
    values.update(overrides)
    if template.name == "CLAUDE.md.tmpl":
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from rules_file_lib import CLAUDE_SHIM_LINE

        values["CLAUDE_MD_SHIM"] = CLAUDE_SHIM_LINE
    # Command overrides are normalised too, never raw 'unknown' in YAML.
    values.update(TEST_CMD=test_cmd, LINT_CMD=lint_cmd, BUILD_CMD=build_cmd)

    keep = set(args.keep) | language_blocks(prof, template, overrides)
    for flag, name in ((has_test, "TEST_CMD"), (has_lint, "LINT_CMD"), (has_build, "BUILD_CMD")):
        keep.add(f"IF_{name}" if flag else f"IF_NO_{name}")

    out: list[str] = []
    stack: list[tuple[str, bool]] = []  # (name, parent_active_and_kept)

    def active() -> bool:
        return all(kept for _, kept in stack)

    for line in template.read_bytes().decode("utf-8-sig").split("\n"):
        m_open = OPEN_RE.match(line)
        if m_open:
            stack.append((m_open.group(1), m_open.group(1) in keep))
            continue
        m_close = CLOSE_RE.match(line)
        if m_close:
            if not stack:
                fail(f"closer {{{{/{m_close.group(1)}}}}} without opener in {template.name}")
            if stack[-1][0] != m_close.group(1):
                fail(
                    f"mismatched closer {{{{/{m_close.group(1)}}}}} for opener "
                    f"{{{{#{stack[-1][0]}}}}} in {template.name}"
                )
            stack.pop()
            continue
        if not active():
            continue
        out.append(PLACEHOLDER_RE.sub(lambda m: values.get(m.group(1), m.group(0)), line))
    if stack:
        fail(f"unterminated block {{{{#{stack[-1][0]}}}}} in {template.name}")

    # Drop the trailing empty element created by the final newline split.
    if out and out[-1] == "":
        out.pop()
    rendered = "\n".join(out) + "\n"

    leftover = sorted(set(PLACEHOLDER_RE.findall(rendered)))
    if leftover:
        fail("unresolved placeholders: " + " ".join("{{" + n + "}}" for n in leftover))
    for line in rendered.split("\n"):
        if re.match(r"^\s*run:\s*#", line):
            fail("rendered an invalid YAML `run:` from an undetected command; guard it with IF_*_CMD blocks")
    sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
