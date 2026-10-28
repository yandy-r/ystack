#!/usr/bin/env python3
"""
Generate opencode-native skills under .opencode-plugin/skills from ycc/skills.

opencode reads skills from <workspace>/.opencode/skills/<name>/SKILL.md or
~/.config/opencode/skills/<name>/SKILL.md. The bundle we emit mirrors that
native layout: install.sh install --target opencode rsyncs .opencode-plugin/skills
into ~/.config/opencode/skills (or a project's .opencode/skills).

Source of truth: ycc/skills/. Transforms are deterministic and idempotent.
"""

from __future__ import annotations

import argparse
import shutil
import stat
import sys
import tempfile
from pathlib import Path

from generate_codex_common import model_invocation_disabled
from generate_opencode_common import (
    OPENCODE_PLUGIN_ROOT,
    SRC_SKILLS_DIR,
    VERBATIM_SKILL_FILES,
    apply_opencode_text_transforms,
    compress_skill_description,
    dump_frontmatter,
    load_agent_aliases,
    parse_frontmatter,
    rewrite_plugin_paths,
)
from generate_opencode_dispatch import (
    project_opencode_dispatch,
    project_opencode_dispatch_description,
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

# Under the generated opencode bundle, skills live at the top level
# (.opencode-plugin/skills/<name>/SKILL.md) and the _shared helpers move to
# .opencode-plugin/shared/ so skill bodies can reference them without a
# special ${PLUGIN_ROOT} variable.
OPENCODE_SKILLS_DST = OPENCODE_PLUGIN_ROOT / "skills"
OPENCODE_SHARED_DST = OPENCODE_PLUGIN_ROOT / "shared"

# OpenCode V2 has no Claude agent-team lifecycle. The standalone projection
# removes every operational reference, so shipping this reference would only
# advertise unsupported tools.
OPENCODE_OMITTED_FILES = frozenset({"_shared/references/agent-team-dispatch.md"})


def should_transform_text(path: Path) -> bool:
    if path.name in TEXT_NAMES:
        return True
    return path.suffix.lower() in TEXT_SUFFIXES


def plugin_output_path(rel: Path) -> Path:
    if rel.parts and rel.parts[0] == "_shared":
        return OPENCODE_SHARED_DST / rel.relative_to("_shared")
    return OPENCODE_SKILLS_DST / rel


def transform_skill_markdown(raw: str, aliases: dict[str, str], source_path: str | Path = "SKILL.md") -> str:
    """Rewrite a SKILL.md with opencode-strict frontmatter (`name` + required
    `description`, plus optional `license`, `compatibility`, `metadata`).

    Any other frontmatter keys the Claude source carries (e.g. `allowed-tools`)
    are dropped — opencode ignores unknown keys silently, but we keep the
    output minimal.
    """
    frontmatter, body = parse_frontmatter(raw)
    name = str(frontmatter.get("name") or "skill")
    description = str(frontmatter.get("description") or "").strip()
    transformed_description = apply_opencode_text_transforms(
        rewrite_plugin_paths(description),
        aliases,
    ).strip()
    transformed_description = project_opencode_dispatch_description(transformed_description)
    transformed_description = compress_skill_description(transformed_description)
    transformed_body = apply_opencode_text_transforms(
        rewrite_plugin_paths(body),
        aliases,
    )
    transformed_body = project_opencode_dispatch(transformed_body, source_path)

    payload: dict[str, object] = {
        "name": name,
        "description": transformed_description,
    }
    for optional_key in ("license", "compatibility"):
        if optional_key in frontmatter and frontmatter[optional_key] not in (None, "", {}):
            payload[optional_key] = frontmatter[optional_key]

    disabled = model_invocation_disabled(frontmatter, name)
    metadata = frontmatter.get("metadata", {})
    if not isinstance(metadata, dict):
        raise ValueError(f"skill '{name}': metadata must be a mapping")
    metadata = dict(metadata)
    key = "opencode/autoinvoke"
    if key in metadata and (not disabled or metadata[key] != "false"):
        raise ValueError(f"skill '{name}': conflicting reserved metadata key '{key}'")
    if disabled:
        metadata[key] = "false"
    if metadata:
        payload["metadata"] = metadata

    return dump_frontmatter(payload) + transformed_body


def copy_mode(src: Path, dst: Path) -> None:
    try:
        mode = stat.S_IMODE(src.stat().st_mode)
        dst.chmod(mode)
    except OSError:
        pass


def iter_source_files() -> list[Path]:
    return sorted(path for path in SRC_SKILLS_DIR.rglob("*") if path.is_file())


OWNED_SUBDIRS = (
    OPENCODE_SKILLS_DST.relative_to(OPENCODE_PLUGIN_ROOT),
    OPENCODE_SHARED_DST.relative_to(OPENCODE_PLUGIN_ROOT),
)


def prune_orphans(dest_root: Path, expected_files: set[Path]) -> None:
    # Only prune files under subdirectories this generator owns. Other files
    # (opencode.json, AGENTS.md, agents/, commands/) are owned by sibling
    # generators and must be left alone.
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


def write_tree(dest_root: Path, dry_run: bool) -> set[Path]:
    aliases = load_agent_aliases()
    written: set[Path] = set()
    for src in iter_source_files():
        rel = src.relative_to(SRC_SKILLS_DIR)
        if rel.as_posix() in OPENCODE_OMITTED_FILES:
            continue
        dst = plugin_output_path(rel)
        out = dest_root / dst.relative_to(OPENCODE_PLUGIN_ROOT)
        written.add(out.relative_to(dest_root))

        if dry_run:
            print(f"Would write {out.relative_to(dest_root)}")
            continue

        out.parent.mkdir(parents=True, exist_ok=True)

        if str(rel.as_posix()) in VERBATIM_SKILL_FILES:
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
                transformed = transform_skill_markdown(text, aliases, rel)
            else:
                transformed = apply_opencode_text_transforms(
                    rewrite_plugin_paths(text),
                    aliases,
                    output_suffix=out.suffix,
                )
                transformed = project_opencode_dispatch(transformed, rel)
            if rel.parts and rel.parts[0] == "bundle-release":
                transformed = restore_bundle_release_source_paths(transformed)
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


def restore_bundle_release_source_paths(content: str) -> str:
    """Release docs intentionally point at Claude plugin metadata source files."""
    return (
        content.replace("ycc/.opencode-plugin/plugin.json", "ycc/.claude-plugin/plugin.json")
        .replace(".opencode-plugin/marketplace.json", ".claude-plugin/marketplace.json")
        .replace(".opencode-plugin/skills/bundle-release", "ycc/skills/bundle-release")
        # release_versions.py discovers Claude manifests by directory name.
        .replace('MANIFEST_SUBDIRS = (".opencode-plugin",', 'MANIFEST_SUBDIRS = (".claude-plugin",')
        .replace(
            'OMP_MANIFEST_SUBDIRS = (".omp-plugin", ".opencode-plugin")',
            'OMP_MANIFEST_SUBDIRS = (".omp-plugin", ".claude-plugin")',
        )
        .replace(
            "``.opencode-plugin/plugin.json`` and ``package.json`` under",
            "``.claude-plugin/plugin.json`` and ``package.json`` under",
        )
    )


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
        diffs = compare_trees(temp_root, OPENCODE_PLUGIN_ROOT, written)
        if diffs:
            print(
                "opencode plugin skills are out of date. Run: ./scripts/generate-opencode-skills.sh",
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
        if not OPENCODE_PLUGIN_ROOT.exists():
            print(
                f"Missing {OPENCODE_PLUGIN_ROOT}; run generator without --check first.",
                file=sys.stderr,
            )
            sys.exit(1)
        sys.exit(run_check())

    if args.dry_run:
        write_tree(OPENCODE_PLUGIN_ROOT, dry_run=True)
        return

    OPENCODE_PLUGIN_ROOT.mkdir(parents=True, exist_ok=True)
    write_tree(OPENCODE_PLUGIN_ROOT, dry_run=False)
    count = sum(
        1
        for path in OPENCODE_PLUGIN_ROOT.rglob("*")
        if path.is_file()
        and path.relative_to(OPENCODE_PLUGIN_ROOT).parts
        and path.relative_to(OPENCODE_PLUGIN_ROOT).parts[0] in {"skills", "shared"}
    )
    print(f"Wrote {count} files under {OPENCODE_PLUGIN_ROOT} (skills + shared)")


if __name__ == "__main__":
    main()
