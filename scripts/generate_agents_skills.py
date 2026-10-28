#!/usr/bin/env python3
"""
Generate agentskills.io skills under .agents-plugin/skills from ycc/skills.

Install.sh (agents target) mirrors .agents-plugin/skills into
~/.agents/skills/ and the sibling .agents-plugin/ycc-shared/ into
~/.agents/ycc-shared/ — the flat layout read by Zed, Codex, opencode,
Cursor, Gemini CLI, VS Code/Copilot, Amp, Goose and Windsurf.

Source of truth: ycc/skills/. Transforms are deterministic and idempotent.
"""

from __future__ import annotations

import argparse
import shutil
import stat
import sys
import tempfile
from pathlib import Path

from generate_agents_common import (
    AGENTS_PLUGIN_ROOT,
    AGENTS_SHARED_DST,
    AGENTS_SKILLS_DST,
    AGENTS_VERBATIM_EXCLUDE,
    SRC_SKILLS_DIR,
    VERBATIM_SKILL_FILES,
    apply_agents_text_transforms,
    load_agent_aliases,
    rewrite_agents_plugin_paths,
    transform_skill_markdown,
)

TEXT_SUFFIXES = frozenset(
    {
        ".md",
        ".mdc",
        ".sh",
        ".bash",
        ".py",
        ".json",
        ".yaml",
        ".yml",
        ".txt",
        ".toml",
        ".gitignore",
        ".tmpl",
    }
)

TEXT_NAMES = frozenset({"SKILL.md", "LICENSE", "Makefile"})


def should_transform_text(path: Path) -> bool:
    if path.name in TEXT_NAMES:
        return True
    return path.suffix.lower() in TEXT_SUFFIXES


def plugin_output_path(rel: Path) -> Path:
    if rel.parts and rel.parts[0] == "_shared":
        return AGENTS_SHARED_DST / rel.relative_to("_shared")
    return AGENTS_SKILLS_DST / rel


def copy_mode(src: Path, dst: Path) -> None:
    try:
        mode = stat.S_IMODE(src.stat().st_mode)
        dst.chmod(mode)
    except OSError:
        pass


def iter_source_files() -> list[Path]:
    return sorted(path for path in SRC_SKILLS_DIR.rglob("*") if path.is_file())


OWNED_SUBDIRS = (
    AGENTS_SKILLS_DST.relative_to(AGENTS_PLUGIN_ROOT),
    AGENTS_SHARED_DST.relative_to(AGENTS_PLUGIN_ROOT),
)


def prune_orphans(dest_root: Path, expected_files: set[Path]) -> None:
    # Only prune files under subdirectories this generator owns.
    owned_roots = [dest_root / sub for sub in OWNED_SUBDIRS if (dest_root / sub).is_dir()]

    existing_files = sorted(
        (path for root in owned_roots for path in root.rglob("*") if path.is_file()),
        key=lambda path: len(path.parts),
        reverse=True,
    )
    for path in existing_files:
        rel = path.relative_to(dest_root)
        if rel not in expected_files:
            path.unlink()

    existing_dirs = sorted(
        (path for root in owned_roots for path in root.rglob("*") if path.is_dir()),
        key=lambda path: len(path.parts),
        reverse=True,
    )
    for path in existing_dirs:
        if path in owned_roots:
            continue
        try:
            next(path.iterdir())
        except StopIteration:
            path.rmdir()


BUNDLE_RELEASE_RESTORE = (
    # Release docs intentionally point at Claude plugin metadata files.
    ("ycc/.agents-plugin/plugin.json", "ycc/.claude-plugin/plugin.json"),
    (".agents-plugin/marketplace.json", ".claude-plugin/marketplace.json"),
    (".agents-plugin/skills/bundle-release", "ycc/skills/bundle-release"),
)


def write_tree(dest_root: Path, dry_run: bool) -> set[Path]:
    aliases = load_agent_aliases()
    written: set[Path] = set()
    for src in iter_source_files():
        rel = src.relative_to(SRC_SKILLS_DIR)
        dst = plugin_output_path(rel)
        out = dest_root / dst.relative_to(AGENTS_PLUGIN_ROOT)
        written.add(out.relative_to(dest_root))

        if dry_run:
            print(f"Would write {out.relative_to(dest_root)}")
            continue

        out.parent.mkdir(parents=True, exist_ok=True)

        if str(rel.as_posix()) in (VERBATIM_SKILL_FILES - AGENTS_VERBATIM_EXCLUDE):
            out.write_bytes(src.read_bytes())
            copy_mode(src, out)
            continue

        if should_transform_text(src):
            text = src.read_text(encoding="utf-8")
            if rel.parts[0] in {"release-model", "init"}:
                # These names describe the target repo's layout, not runtime rules.
                text = text.replace("CLAUDE.md", "\x00RELEASE_MODEL_CLAUDE_FILE\x00")
                if rel.parts[0] == "init":
                    # Version claims name the real product, not the target runtime.
                    text = text.replace("Claude Code", "\x00INIT_CLAUDE_CODE\x00")
            if src.name == "SKILL.md":
                transformed = transform_skill_markdown(text, aliases)
            else:
                transformed = apply_agents_text_transforms(
                    rewrite_agents_plugin_paths(text),
                    aliases,
                    output_suffix=out.suffix,
                )
            if rel.parts and rel.parts[0] == "bundle-release":
                for old, new in BUNDLE_RELEASE_RESTORE:
                    transformed = transformed.replace(old, new)
            out.write_text(
                transformed.replace("\x00RELEASE_MODEL_CLAUDE_FILE\x00", "CLAUDE.md").replace(
                    "\x00INIT_CLAUDE_CODE\x00", "Claude Code"
                ),
                encoding="utf-8",
            )
        else:
            shutil.copyfile(src, out)
        copy_mode(src, out)

    if not dry_run:
        prune_orphans(dest_root, written)
    return written


def compare_trees(generated: Path, repo_dest: Path, expected_files: set[Path]) -> list[str]:
    diffs: list[str] = []
    for rel in sorted(expected_files):
        left = generated / rel
        right = repo_dest / rel
        if not right.exists():
            diffs.append(f"missing in repo: {rel}")
            continue
        if left.read_bytes() != right.read_bytes():
            diffs.append(f"drift: {rel}")
    return diffs


def run_check() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        temp_root = Path(tmp)
        written = write_tree(temp_root, dry_run=False)
        diffs = compare_trees(temp_root, AGENTS_PLUGIN_ROOT, written)
        if diffs:
            print(
                "agents plugin skills are out of date. Run: ./scripts/generate-agents-skills.sh",
                file=sys.stderr,
            )
            for diff in diffs:
                print(f"  {diff}", file=sys.stderr)
            return 1
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Exit 1 if generated output drifts")
    parser.add_argument("--dry-run", action="store_true", help="Print what would be written")
    args = parser.parse_args()

    if args.check:
        if not AGENTS_PLUGIN_ROOT.exists():
            print(
                f"Missing {AGENTS_PLUGIN_ROOT}; run generator without --check first.",
                file=sys.stderr,
            )
            sys.exit(1)
        sys.exit(run_check())

    if args.dry_run:
        write_tree(AGENTS_PLUGIN_ROOT, dry_run=True)
        return

    AGENTS_PLUGIN_ROOT.mkdir(parents=True, exist_ok=True)
    write_tree(AGENTS_PLUGIN_ROOT, dry_run=False)
    count = sum(
        1
        for path in AGENTS_PLUGIN_ROOT.rglob("*")
        if path.is_file()
        and path.relative_to(AGENTS_PLUGIN_ROOT).parts
        and path.relative_to(AGENTS_PLUGIN_ROOT).parts[0] in {"skills", "ycc-shared"}
    )
    print(f"Wrote {count} files under {AGENTS_PLUGIN_ROOT} (skills + ycc-shared)")


if __name__ == "__main__":
    main()
