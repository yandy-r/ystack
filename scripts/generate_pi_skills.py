#!/usr/bin/env python3
"""
Generate Pi skills under packages/pi/ycc/skills from ycc/skills (YAN-1184, ADR 0003).

Every source skill and the single `_shared` closure are emitted exactly once. Pi
discovers `skills/<name>/SKILL.md` natively as `/skill:<name>` and leaves
`${CLAUDE_PLUGIN_ROOT}`, `/ycc:` and `$ARGUMENTS` literal, so bodies are rewritten:

- `${CLAUDE_PLUGIN_ROOT}/skills/<path>` and file-relative `(../)+_shared/<path>` links
  become `../<path>`. Pi tells the model to resolve relative paths against the skill
  directory (the parent of SKILL.md) and to pass absolute paths to tools; every skill
  directory is a sibling of `_shared`, so `../<path>` resolves the same from any skill,
  including when a `_shared` reference is read on behalf of another skill.
- Script fallbacks collapse to their `${SCRIPT_DIR}`-relative primary path.
- `/ycc:<skill>` -> `/skill:<skill>`, `ycc:<agent>` -> `<agent>` (OMP resolver; unknown
  names fail), and Claude file-tool names -> Pi's built-in tools.
- A SKILL.md whose skill uses `$ARGUMENTS` gains a preamble defining it as the text Pi
  appends after the skill block, so shell snippets stay valid.

`_shared` has no SKILL.md and the skills root holds no loose `.md` file, so Pi never
discovers either as a skill. Nothing here is installable until YAN-1188 adds
`packages/pi/ycc/package.json`. Transforms are deterministic and idempotent.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

from generate_codex_common import (
    VERBATIM_SKILL_FILES,
    drop_self_fallbacks,
    dump_frontmatter,
    fix_mcp_malformed_tokens,
    model_invocation_disabled,
    parse_frontmatter,
    protect_marked_verbatim_blocks,
    restore_marked_verbatim_blocks,
)
from generate_omp_skills import (
    _PLUGIN_SKILL_PATH,
    _RELATIVE_SHARED_LINK,
    _SCRIPT_FALLBACK,
    MARKDOWN_SUFFIXES,
    PLUGIN_ROOT_TOKEN,
    REPOSITORY_LAYOUT_FILES,
    SCRIPT_SUFFIXES,
    Catalog,
    OmpGenerationError,
    _check_skill_path,
    build_catalog,
    compare_trees,
    copy_mode,
    iter_source_files,
    prune_orphans,
    rewrite_namespace,
)

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
SRC_DIR = REPO_ROOT / "ycc" / "skills"
DST_DIR = REPO_ROOT / "packages/pi/ycc/skills"

SHARED_DIR_NAME = "_shared"

# The OMP resolvers this module reuses raise OmpGenerationError; one name covers both.
GenerationError = OmpGenerationError

# Frontmatter keys Pi reads (docs/skills.md). `allowed-tools` is experimental in Pi and
# names Claude tools; `argument-hint` applies to prompt templates only (spike §3).
KEPT_FRONTMATTER_KEYS = ("name", "description", "disable-model-invocation")

ARGUMENTS_TOKEN = "$ARGUMENTS"
ARGUMENTS_PREAMBLE = (
    "> **Pi:** `$ARGUMENTS` in this skill means the text typed after `/skill:{name}`, which Pi\n"
    "> appends after this skill block. In shell snippets, set `ARGUMENTS` to that text first.\n"
    "\n"
)

# Claude file tools -> Pi built-in tools (read, bash, edit, write, grep, find, ls).
# Only unambiguous tool phrasing is rewritten ("the Write tool", "Read/Grep/Glob");
# plural "Write tools" and table cells that mean MCP write tools stay untouched.
PI_FILE_TOOLS = {
    "Read": "read",
    "Write": "write",
    "Edit": "edit",
    "MultiEdit": "edit",
    "Grep": "grep",
    "Glob": "find",
    "Bash": "bash",
}
_TOOL_NAME = r"(?:" + "|".join(sorted(PI_FILE_TOOLS, key=len, reverse=True)) + r")"
_TOOL_PHRASE = re.compile(r"\b(" + _TOOL_NAME + r") tool\b")
_TOOL_SLASH_LIST = re.compile(r"\b" + _TOOL_NAME + r"(?:/" + _TOOL_NAME + r")+\b")


def skill_dir_relative(path: str) -> str:
    """A `skills/`-relative path as seen from any skill directory (all are siblings)."""
    return f"../{path}"


def rewrite_plugin_paths(text: str, rel: Path, catalog: Catalog) -> str:
    """`${CLAUDE_PLUGIN_ROOT}/skills/<path>` -> `../<path>` (skill-directory relative)."""

    def replace(match: re.Match[str]) -> str:
        _check_skill_path(match.group(1), rel, match.group(0), catalog)
        return skill_dir_relative(match.group(1))

    return _PLUGIN_SKILL_PATH.sub(replace, text)


def rewrite_relative_shared_links(text: str, rel: Path, catalog: Catalog) -> str:
    """File-relative `(../)+_shared/<path>` links -> skill-directory-relative `../_shared/<path>`."""

    def replace(match: re.Match[str]) -> str:
        path = f"{SHARED_DIR_NAME}/{match.group(1)}"
        _check_skill_path(path, rel, match.group(0), catalog)
        return skill_dir_relative(path)

    return _RELATIVE_SHARED_LINK.sub(replace, text)


_MARKDOWN_PARENT_LINK = re.compile(r"\]\((?P<path>(?:\.\./)+[^)\s#]+)(?P<anchor>#[^)\s]*)?\)")


def rewrite_shared_internal_links(text: str, rel: Path, catalog: Catalog) -> str:
    """Inside `_shared/`, file-relative `](../x)` links that land in `_shared/` -> `../_shared/x`.

    Pi resolves relative paths against the skill directory of whichever skill reads the
    reference, so a `_shared`-internal link must be phrased from a sibling skill directory.
    """
    if rel.parts[0] != SHARED_DIR_NAME:
        return text

    def replace(match: re.Match[str]) -> str:
        target = os.path.normpath(os.path.join(rel.parent.as_posix(), match["path"]))
        if not target.startswith(SHARED_DIR_NAME + "/"):
            return match.group(0)
        _check_skill_path(target, rel, match.group(0), catalog)
        return f"]({skill_dir_relative(target)}{match['anchor'] or ''})"

    return _MARKDOWN_PARENT_LINK.sub(replace, text)


def rewrite_script_plugin_paths(text: str, rel: Path, catalog: Catalog) -> str:
    """Script fallbacks -> `${SCRIPT_DIR}`-relative primaries; any other code use fails.

    Pi sets no plugin-root variable, so `${CLAUDE_PLUGIN_ROOT}` in script code would
    expand empty. A rewritten fallback repeats its primary path and is dropped.
    """

    def fallback(match: re.Match[str]) -> str:
        path = match.group("path")
        _check_skill_path(path, rel, match.group(0), catalog)
        if not re.search(r"^\s*SCRIPT_DIR=", text, re.MULTILINE):
            raise GenerationError(f"{rel}: '{match.group(0)}' needs a SCRIPT_DIR assignment to rewrite")
        relative = Path(os.path.relpath(path, rel.parent.as_posix())).as_posix()
        return f'{match.group("lhs")}"${{SCRIPT_DIR}}/{relative}"'

    text = _SCRIPT_FALLBACK.sub(fallback, text)
    for line in text.splitlines():
        if PLUGIN_ROOT_TOKEN in line and not line.lstrip().startswith("#"):
            raise GenerationError(f"{rel}: unsupported {PLUGIN_ROOT_TOKEN} use in script code: {line.strip()}")
    return rewrite_plugin_paths(drop_self_fallbacks(text), rel, catalog)


def rewrite_tool_names(text: str) -> str:
    """`the Write tool` -> `the write tool`; `Read/Grep/Glob` -> `read/grep/find`."""
    text = _TOOL_PHRASE.sub(lambda m: f"{PI_FILE_TOOLS[m.group(1)]} tool", text)
    return _TOOL_SLASH_LIST.sub(lambda m: "/".join(PI_FILE_TOOLS[n] for n in m.group(0).split("/")), text)


def _check_no_plugin_root(text: str, rel: Path) -> None:
    for line in text.splitlines():
        if PLUGIN_ROOT_TOKEN in line:
            raise GenerationError(f"{rel}: unresolved {PLUGIN_ROOT_TOKEN} reference: {line.strip()}")


def transform_frontmatter(frontmatter: dict[str, Any], rel: Path, rewrite: Callable[[str], str]) -> dict[str, Any]:
    """Keep Pi-meaningful keys; `disable-model-invocation` must be a strict boolean."""
    model_invocation_disabled(frontmatter, rel.parent.name)
    kept: dict[str, Any] = {}
    for key in KEPT_FRONTMATTER_KEYS:
        if key in frontmatter:
            value = frontmatter[key]
            kept[key] = rewrite(value) if isinstance(value, str) else value
    return kept


def transform_text(text: str, rel: Path, catalog: Catalog) -> str:
    """Rewrite one non-verbatim skill-tree text file for Pi."""
    suffix = rel.suffix.lower()
    is_markdown = suffix in MARKDOWN_SUFFIXES
    keeps_plugin_root = rel.as_posix() in REPOSITORY_LAYOUT_FILES

    def body_rewrite(segment: str) -> str:
        segment = fix_mcp_malformed_tokens(segment)
        if keeps_plugin_root:
            pass
        elif suffix in SCRIPT_SUFFIXES:
            segment = rewrite_script_plugin_paths(segment, rel, catalog)
        else:
            segment = rewrite_plugin_paths(segment, rel, catalog)
        if is_markdown:
            segment = rewrite_relative_shared_links(segment, rel, catalog)
            segment = rewrite_shared_internal_links(segment, rel, catalog)
            segment = rewrite_tool_names(segment)
        segment = rewrite_namespace(segment, rel, catalog)
        if not keeps_plugin_root:
            _check_no_plugin_root(segment, rel)
        return segment

    header = ""
    if rel.name == "SKILL.md" and len(rel.parts) == 2:
        frontmatter, text = parse_frontmatter(text)
        if not isinstance(frontmatter.get("description"), str) or not frontmatter["description"].strip():
            raise GenerationError(f"{rel}: Pi skips a skill without a description")
        header = dump_frontmatter(transform_frontmatter(frontmatter, rel, body_rewrite))
        if ARGUMENTS_TOKEN in text:
            header += "\n" + ARGUMENTS_PREAMBLE.format(name=frontmatter.get("name") or rel.parent.name)
            text = text.lstrip("\n")
    protected, blocks = protect_marked_verbatim_blocks(text)
    output = header + restore_marked_verbatim_blocks(body_rewrite(protected), blocks)
    if output and not output.endswith("\n"):
        output += "\n"
    return output


def check_discovery_layout(rels: set[Path]) -> None:
    """Fail when Pi would discover something other than the top-level skills.

    Pi loads every `SKILL.md` under the skills root and, at the root only, loose `.md`
    files; inside a skill directory it stops at `SKILL.md`. `_shared` has no SKILL.md,
    so a SKILL.md anywhere under it, or a loose root `.md`, would become a skill.
    """
    for rel in sorted(rels):
        if len(rel.parts) == 1 and rel.suffix.lower() == ".md":
            raise GenerationError(f"{rel}: a loose .md at the skills root is discovered as a Pi skill")
        if rel.parts[0] == SHARED_DIR_NAME and rel.name == "SKILL.md":
            raise GenerationError(f"{rel}: a SKILL.md under {SHARED_DIR_NAME}/ is discovered as a Pi skill")


def check_arguments_coverage(src: Path, rels: set[Path]) -> None:
    """A file using `$ARGUMENTS` must belong to a skill whose SKILL.md defines it via the preamble."""
    for rel in sorted(rels):
        if rel.name == "SKILL.md" and len(rel.parts) == 2:
            continue
        if rel.as_posix() in VERBATIM_SKILL_FILES or rel.as_posix() in REPOSITORY_LAYOUT_FILES:
            continue
        if rel.suffix.lower() not in MARKDOWN_SUFFIXES | SCRIPT_SUFFIXES:
            continue
        if ARGUMENTS_TOKEN not in (src / rel).read_text(encoding="utf-8", errors="replace"):
            continue
        skill_md = src / rel.parts[0] / "SKILL.md"
        if not skill_md.is_file() or ARGUMENTS_TOKEN not in skill_md.read_text(encoding="utf-8"):
            raise GenerationError(f"{rel}: uses {ARGUMENTS_TOKEN} but its skill's SKILL.md does not define it")


def write_tree(
    dest: Path, dry_run: bool, *, src_root: Path | None = None, aliases: dict[str, str] | None = None
) -> set[Path]:
    """Write the Pi skill tree under dest; returns the relative file paths written."""
    src = SRC_DIR if src_root is None else src_root
    if not src.is_dir():
        raise SystemExit(f"Missing source directory: {src}")
    catalog = build_catalog(src, aliases)
    if src_root is None:
        for listed in sorted(REPOSITORY_LAYOUT_FILES):
            if not (src / listed).is_file():
                raise GenerationError(f"{listed}: listed in REPOSITORY_LAYOUT_FILES but missing from ycc/skills")

    outputs: dict[Path, tuple[bytes, Path]] = {}
    for src_file in iter_source_files(src):
        rel = src_file.relative_to(src)
        data = src_file.read_bytes()
        if rel.as_posix() not in VERBATIM_SKILL_FILES:
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                pass
            else:
                data = transform_text(text, rel, catalog).encode("utf-8")
        outputs[rel] = (data, src_file)
    check_discovery_layout(set(outputs))
    check_arguments_coverage(src, set(outputs))

    if dry_run:
        for rel in sorted(outputs):
            print(f"Would write {dest / rel}")
        return set(outputs)

    for rel, (data, origin) in sorted(outputs.items()):
        dst_file = dest / rel
        dst_file.parent.mkdir(parents=True, exist_ok=True)
        dst_file.write_bytes(data)
        copy_mode(origin, dst_file)
    prune_orphans(dest, set(outputs))
    return set(outputs)


def run_check(dest: Path = DST_DIR) -> int:
    with tempfile.TemporaryDirectory() as tmp:
        generated = Path(tmp)
        write_tree(generated, dry_run=False)
        diffs = compare_trees(generated, dest)
    if diffs:
        print("Pi skills are out of date. Run: ./scripts/generate-pi-skills.sh", file=sys.stderr)
        for line in diffs:
            print(f"  {line}", file=sys.stderr)
        return 1
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit 1 if packages/pi/ycc/skills differs from generator output (bytes or executable bits)",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print paths that would be written (no writes)")
    args = parser.parse_args()

    try:
        if args.check:
            if not DST_DIR.is_dir():
                print(f"Missing {DST_DIR}; run generator without --check first.", file=sys.stderr)
                sys.exit(1)
            sys.exit(run_check())
        written = write_tree(DST_DIR, dry_run=args.dry_run)
    except ValueError as error:
        print(f"generate_pi_skills.py: {error}", file=sys.stderr)
        sys.exit(1)
    if not args.dry_run:
        print(f"Wrote {len(written)} files under {DST_DIR}")


if __name__ == "__main__":
    main()
