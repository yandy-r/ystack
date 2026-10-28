#!/usr/bin/env python3
"""
Generate Codex-native plugin skills under plugins/ycc/skills from ycc/skills.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import stat
import sys
import tempfile
from pathlib import Path

from generate_codex_common import (
    HOME_INSTALL_PLUGIN_ROOT,
    PLUGIN_ROOT,
    PLUGIN_SHARED_DIR,
    PLUGIN_SKILLS_DIR,
    SRC_SKILLS_DIR,
    VERBATIM_SKILL_FILES,
    apply_codex_text_transforms,
    compress_skill_description,
    drop_self_fallbacks,
    dump_frontmatter,
    expand_quoted_home,
    load_agent_aliases,
    model_invocation_disabled,
    parse_frontmatter,
)
from package_model import load_package_model

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
        return PLUGIN_SHARED_DIR / rel.relative_to("_shared")
    return PLUGIN_SKILLS_DIR / rel


def rewrite_plugin_paths(text: str) -> str:
    pattern = r"\$\{CLAUDE_PLUGIN_ROOT\}/skills/([^\"`\s]+)"

    def replace(match: re.Match[str]) -> str:
        path_text = match.group(1)
        if path_text.startswith("_shared/"):
            return f"{HOME_INSTALL_PLUGIN_ROOT}/shared/{path_text[len('_shared/') :]}"
        return f"{HOME_INSTALL_PLUGIN_ROOT}/skills/{path_text}"

    return re.sub(pattern, replace, text)


NATIVE_SHELL_SUFFIXES = frozenset({".sh", ".bash"})
_RESOURCE_TAIL = r"([^\s\"'`()<>]+)"
NATIVE_PROMPT_FILES = frozenset(
    {
        "skills/git-workflow/templates/agent-prompts.md",
        "skills/plan-workflow/references/planning-agents.md",
    }
)
NATIVE_PLUGIN_PLACEHOLDER = "<installed ycc plugin root>"


def prompt_substitution_instruction(text: str, output_path: Path) -> str:
    """Require absolute plugin-root expansion before a bundled prompt is forwarded."""
    root = Path(os.path.relpath(".", output_path.parent)).as_posix()
    return (
        "## Native prompt substitution\n\nBefore forwarding any prompt, replace every `"
        + NATIVE_PLUGIN_PLACEHOLDER
        + "` with the absolute installed ycc plugin root (resolve `"
        + root
        + "` from this document's directory). Forward only absolute resource paths; "
        "keep the user's project as cwd.\n\n" + text
    )


def rewrite_native_paths(text: str, output_path: Path) -> str:
    """Make bundled resources relative to the emitted file instead of the installer symlink.

    Shell code gets ``${SCRIPT_DIR}``-anchored paths so helpers never depend on cwd;
    every caller defines SCRIPT_DIR. Comments and documents get plain relative paths.
    A plugin-root fallback then repeats its script-relative primary, so it is dropped.
    """
    is_shell = output_path.suffix in NATIVE_SHELL_SUFFIXES

    def relative_resource(path: str, executable: bool) -> str:
        if "{{" in path:
            # Scaffold payloads describe the future authored skill, not this template.
            return "${CLAUDE_PLUGIN_ROOT}/" + path
        if path.startswith("skills/_shared/"):
            path = "shared/" + path[len("skills/_shared/") :]
        if output_path.as_posix() in NATIVE_PROMPT_FILES:
            return NATIVE_PLUGIN_PLACEHOLDER + "/" + path
        relative = Path(os.path.relpath(path, output_path.parent)).as_posix()
        if path.endswith("/"):
            relative += "/"
        return "${SCRIPT_DIR}/" + relative if executable else relative

    def rewrite(segment: str, executable: bool) -> str:
        segment = re.sub(
            re.escape(HOME_INSTALL_PLUGIN_ROOT) + "/" + _RESOURCE_TAIL,
            lambda match: relative_resource(match.group(1), executable),
            segment,
        )

        def home_skill(match: re.Match[str]) -> str:
            # Only bundled skills move into the plugin; other user skills stay home-relative.
            if not (SRC_SKILLS_DIR / match.group(1).split("/", 1)[0]).is_dir():
                return match.group(0)
            return relative_resource("skills/" + match.group(1), executable)

        segment = re.sub(r"~/\.codex/skills/" + _RESOURCE_TAIL, home_skill, segment)
        if is_shell:
            return segment
        # Authored Markdown links can use the source-tree sibling `_shared/` directory.
        return re.sub(
            r"(?:\.\./)+_shared/" + _RESOURCE_TAIL,
            lambda match: relative_resource("shared/" + match.group(1), executable),
            segment,
        )

    if not is_shell:
        rendered = rewrite(text, executable=False)
        if output_path.as_posix() in NATIVE_PROMPT_FILES:
            rendered = prompt_substitution_instruction(rendered, output_path)
        if output_path.as_posix() in {
            "skills/git-workflow/SKILL.md",
            "skills/git-workflow/references/commit-phases.md",
        }:
            instruction = (
                " Before Step 14 dispatch, expand every `<installed ycc plugin root>` in "
                "the agent prompt to the absolute plugin root derived from this installed "
                "SKILL.md; send absolute helper/reference paths and retain the project cwd."
            )
            rendered = re.sub(
                r"(?m)^.*(?:Step 14|Step 6.*Step 8.*Step 14).*$",
                lambda match: match.group(0) + instruction,
                rendered,
                count=1,
            )
        return rendered
    return drop_self_fallbacks(
        "".join(rewrite(line, executable=not line.lstrip().startswith("#")) for line in text.splitlines(keepends=True))
    )


_SHARED_REFERENCE_TAIL = re.compile(re.escape(HOME_INSTALL_PLUGIN_ROOT) + r"/(shared/references/[^\s\"'`()<>]+)")


def rewrite_shared_reference_paths(text: str, output_path: Path) -> str:
    """Make Markdown shared-reference links relative so repo and relocated installs resolve."""
    if output_path.suffix != ".md":
        return text

    def relative(match: re.Match[str]) -> str:
        path = match.group(1)
        if output_path.as_posix() in NATIVE_PROMPT_FILES:
            return NATIVE_PLUGIN_PLACEHOLDER + "/" + path
        rel = Path(os.path.relpath(path, output_path.parent)).as_posix()
        return rel + "/" if path.endswith("/") else rel

    rendered = _SHARED_REFERENCE_TAIL.sub(relative, text)
    if rendered != text and output_path.as_posix() in NATIVE_PROMPT_FILES:
        rendered = prompt_substitution_instruction(rendered, output_path)
    return rendered


def transform_skill_markdown(
    raw: str,
    aliases: dict[str, str],
    *,
    native_paths: bool = False,
    output_path: Path | None = None,
) -> str:
    frontmatter, body = parse_frontmatter(raw)
    name = str(frontmatter.get("name") or "skill")
    model_invocation_disabled(frontmatter, name)
    description = str(frontmatter.get("description") or "").strip()
    transformed_description = apply_codex_text_transforms(
        rewrite_plugin_paths(description),
        aliases,
    ).strip()
    resolved_output = output_path or Path("skills") / name / "SKILL.md"
    if native_paths:
        if output_path is None:
            raise ValueError("native skill rendering requires its output path")
        transformed_description = rewrite_native_paths(transformed_description, output_path)
    else:
        transformed_description = rewrite_shared_reference_paths(transformed_description, resolved_output)
    transformed_description = compress_skill_description(transformed_description)
    transformed_body = apply_codex_text_transforms(
        rewrite_plugin_paths(body),
        aliases,
    )
    if native_paths and output_path is not None:
        transformed_body = rewrite_native_paths(transformed_body, output_path)
        transformed_body = (
            "\nBundled paths are relative to this SKILL.md's directory (the installed location "
            "shown by Codex); in reference documents, use that document's directory. Resolve "
            "them to absolute paths and run helpers by absolute path while keeping the user's "
            "project as cwd.\n\n" + transformed_body.lstrip("\n")
        )
    else:
        transformed_body = rewrite_shared_reference_paths(transformed_body, resolved_output)
    payload = {
        "name": name,
        "description": transformed_description,
    }
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
    PLUGIN_SKILLS_DIR.relative_to(PLUGIN_ROOT),
    PLUGIN_SHARED_DIR.relative_to(PLUGIN_ROOT),
)


def prune_orphans(dest_root: Path, expected_files: set[Path]) -> None:
    # Only prune files under subdirectories this generator owns. Other files
    # (e.g. .codex-plugin/plugin.json, .mcp.json) belong to generate_codex_plugin.py
    # and must be left alone.
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


def write_tree(
    dest_root: Path,
    dry_run: bool,
    *,
    native_paths: bool = False,
    expand_home: bool = True,
) -> set[Path]:
    """Render the Codex skill tree under dest_root; return the relative paths written.

    ``native_paths=False`` is the pre-listing legacy render. It now expands
    quoted ``"~/.codex/`` helper fallbacks to ``"${HOME}/.codex/`` (SC2088),
    so the shell-path validator now covers it like every other render.
    ``expand_home=False`` reproduces the pre-fix legacy bytes — the exact form
    older releases installed — and exists only for install_migrate.py's
    ownership proofs; that render is never committed.
    The flag applies to the native render too; it emits no quoted ``"~/.codex/``
    paths, so its output is byte-identical either way.
    """
    aliases = load_agent_aliases()
    written: set[Path] = set()
    manual_skills: list[Path] = []
    for src in sorted(SRC_SKILLS_DIR.glob("*/SKILL.md")):
        frontmatter, _ = parse_frontmatter(src.read_text(encoding="utf-8"))
        if model_invocation_disabled(frontmatter, src.parent.name):
            # ponytail: no authored sidecars yet; add a field-preserving merge when needed.
            if (src.parent / "agents/openai.yaml").exists():
                raise ValueError(
                    f"skill '{src.parent.name}': authored agents/openai.yaml conflicts with generated policy"
                )
            manual_skills.append(src.parent.relative_to(SRC_SKILLS_DIR))

    for rel in manual_skills:
        out = dest_root / "skills" / rel / "agents/openai.yaml"
        written.add(out.relative_to(dest_root))
        if dry_run:
            print(f"Would write {out.relative_to(dest_root)}")
        else:
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text("policy:\n  allow_implicit_invocation: false\n", encoding="utf-8")

    for src in iter_source_files():
        rel = src.relative_to(SRC_SKILLS_DIR)
        dst = plugin_output_path(rel)
        out = dest_root / dst.relative_to(PLUGIN_ROOT)
        written.add(out.relative_to(dest_root))

        if dry_run:
            print(f"Would write {out.relative_to(dest_root)}")
            continue

        out.parent.mkdir(parents=True, exist_ok=True)

        if str(rel.as_posix()) in VERBATIM_SKILL_FILES:
            # Multi-target meta file — copy bytes verbatim; no rewrites.
            out.write_bytes(src.read_bytes())
            copy_mode(src, out)
            continue

        if should_transform_text(src):
            text = src.read_text(encoding="utf-8")
            if rel.as_posix() == "_shared/references/agent-team-dispatch.md":
                transformed = (
                    "# Agent Team Dispatch\n\n"
                    "Agent teams (`--team`) are unsupported in the Codex bundle. Abort if "
                    "requested; rerun without `--team` using standalone dispatch.\n"
                )
            else:
                if rel.parts[0] in {"release-model", "init"}:
                    # These names describe the target repo's layout, not runtime rules.
                    text = text.replace("CLAUDE.md", "\x00RELEASE_MODEL_CLAUDE_FILE\x00")
                    if rel.parts[0] == "init":
                        # Version claims name the real product, not the target runtime.
                        text = text.replace("Claude Code", "\x00INIT_CLAUDE_CODE\x00")
                if src.name == "SKILL.md":
                    transformed = transform_skill_markdown(
                        text,
                        aliases,
                        native_paths=native_paths,
                        output_path=out.relative_to(dest_root),
                    )
                else:
                    transformed = apply_codex_text_transforms(
                        rewrite_plugin_paths(text),
                        aliases,
                    )
                    if native_paths:
                        transformed = rewrite_native_paths(transformed, out.relative_to(dest_root))
                    else:
                        transformed = rewrite_shared_reference_paths(transformed, out.relative_to(dest_root))
                if expand_home:
                    # SC2088: a quoted "~/.codex/" never expands in shell code
                    # or in Markdown shell snippets; native output has none left.
                    transformed = expand_quoted_home(transformed, ".codex/", out.suffix)
                if rel.parts and rel.parts[0] == "bundle-release":
                    transformed = restore_bundle_release_source_paths(transformed)
                transformed = transformed.replace("\x00RELEASE_MODEL_CLAUDE_FILE\x00", "CLAUDE.md")
                transformed = transformed.replace("\x00INIT_CLAUDE_CODE\x00", "Claude Code")
            out.write_text(transformed, encoding="utf-8")
        else:
            shutil.copyfile(src, out)
        copy_mode(src, out)

    if not dry_run:
        prune_orphans(dest_root, written)
    return written


def restore_bundle_release_source_paths(content: str) -> str:
    """Release docs intentionally point at Claude plugin metadata source files."""
    return (
        content.replace("ycc/.codex-plugin/plugin.json", "ycc/.claude-plugin/plugin.json")
        .replace(".codex-plugin/marketplace.json", ".claude-plugin/marketplace.json")
        .replace(".codex-plugin/ && ./scripts/sync.sh", ".opencode-plugin/ && ./scripts/sync.sh")
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
    for sub in OWNED_SUBDIRS:
        for path in sorted((repo_dest / sub).rglob("*")):
            if path.is_file() and path.relative_to(repo_dest) not in expected_files:
                diffs.append(f"extra in repo: {path.relative_to(repo_dest)}")
    return diffs


def repository_native_paths() -> bool:
    """Use relocatable native paths once the repository Codex catalog flips."""
    from generate_codex_plugin import build_repository_marketplace

    return bool(build_repository_marketplace(load_package_model().packages)["name"] == "ycc")


def run_check() -> int:
    native_paths = repository_native_paths()
    with tempfile.TemporaryDirectory() as tmp:
        temp_root = Path(tmp)
        written = write_tree(temp_root, dry_run=False, native_paths=native_paths)
        diffs = compare_trees(temp_root, PLUGIN_ROOT, written)
        if diffs:
            print(
                "Codex plugin skills are out of date. Run: ./scripts/generate-codex-skills.sh",
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
        if not PLUGIN_ROOT.exists():
            print(
                f"Missing {PLUGIN_ROOT}; run generator without --check first.",
                file=sys.stderr,
            )
            sys.exit(1)
        sys.exit(run_check())

    native_paths = repository_native_paths()
    if args.dry_run:
        write_tree(PLUGIN_ROOT, dry_run=True, native_paths=native_paths)
        return

    write_tree(PLUGIN_ROOT, dry_run=False, native_paths=native_paths)
    count = sum(1 for path in PLUGIN_ROOT.rglob("*") if path.is_file())
    print(f"Wrote {count} files under {PLUGIN_ROOT}")


if __name__ == "__main__":
    main()
