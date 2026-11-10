#!/usr/bin/env python3
"""
Generate Cursor-native rules under packages/cursor/ycc-rules/rules from ycc/rules.

Converts nested ycc/rules/**/*.md to **/*.mdc with frontmatter, mirrors tree exactly.
Source of truth: ycc/rules/
"""

from __future__ import annotations

import argparse
import re
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any

import yaml

_SCRIPTS_DIR = Path(__file__).resolve().parent
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))
from generate_cursor_skills import apply_skills_text_transforms  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = REPO_ROOT / "ycc" / "rules"
DST_DIR = REPO_ROOT / "packages/cursor/ycc-rules/rules"


def fix_markdown_links_md_to_mdc(body: str) -> str:
    """Rewrite relative .md links in markdown to .mdc (preserve anchors)."""

    def repl_paren(match: re.Match[str]) -> str:
        url = match.group(1)
        if "://" in url:
            return match.group(0)
        if "#" in url:
            base, frag = url.split("#", 1)
            frag = "#" + frag
        else:
            base, frag = url, ""
        if base.endswith(".md"):
            base = base[:-3] + ".mdc"
        return f"]({base}{frag})"

    out = re.sub(r"\]\(([^)]+)\)", repl_paren, body)

    def repl_full(m: re.Match[str]) -> str:
        text, url = m.group(1), m.group(2)
        if "://" in url:
            return m.group(0)
        if text.endswith(".md"):
            text = text[:-3] + ".mdc"
        if "#" in url:
            base, _, frag = url.partition("#")
            frag = "#" + frag
        else:
            base, frag = url, ""
        if base.endswith(".md"):
            base = base[:-3] + ".mdc"
        return f"[{text}]({base}{frag})"

    out = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", repl_full, out)
    return out


def extract_first_heading(body: str) -> str | None:
    m = re.search(r"^#\s+(.+)$", body, re.MULTILINE)
    return m.group(1).strip() if m else None


def parse_frontmatter(raw: str) -> tuple[bool, dict[str, Any], str]:
    """Returns (has_yaml_block, data, body_without_frontmatter_if_present)."""
    if not raw.startswith("---\n"):
        return False, {}, raw
    end = raw.find("\n---\n", 4)
    if end == -1:
        return False, {}, raw
    fm_text = raw[4:end]
    body = raw[end + 5 :]
    if not fm_text.strip():
        return True, {}, body
    data = yaml.safe_load(fm_text)
    if data is None:
        data = {}
    if not isinstance(data, dict):
        data = {}
    return True, data, body


MAX_DESCRIPTION_CHARS = 200
# Claude-only automation guidance; hooks-workflow reads these sources directly.
SKIPPED_RULE_NAMES = frozenset({"hooks.md"})
ALWAYS_APPLY_MAX_RULES = 2
ALWAYS_APPLY_MAX_BODY_LINES = 60


def validate_description(rel: Path, description: object, body: str) -> str:
    """Return a source description, rejecting titles and over-long text."""
    if not isinstance(description, str) or not description.strip():
        raise SystemExit(f"{rel}: source frontmatter needs a non-empty description")
    text = description.strip()
    if len(text) > MAX_DESCRIPTION_CHARS:
        raise SystemExit(f"{rel}: description exceeds {MAX_DESCRIPTION_CHARS} characters")
    if text == extract_first_heading(body):
        raise SystemExit(f"{rel}: description must explain when/what, not repeat the H1")
    return text


def normalize_rule_frontmatter(
    rel: Path,
    data: dict[str, Any],
    body: str,
) -> dict[str, Any]:
    """Normalize Claude-style rule YAML to Cursor .mdc frontmatter."""
    out = dict(data)
    if "paths" in out and "globs" not in out:
        out["globs"] = out.pop("paths")
    out["description"] = validate_description(rel, out.get("description"), body)
    out["alwaysApply"] = out.get("alwaysApply") is True
    if out["alwaysApply"]:
        out.pop("globs", None)
    elif "globs" not in out and rel.parts[0] != "common":
        raise SystemExit(f"{rel}: non-common rules need paths/globs")
    return out


def dump_frontmatter(data: dict[str, Any]) -> str:
    # Stable key order for Cursor-friendly diffs
    order = ("description", "alwaysApply", "globs")
    ordered: dict[str, Any] = {}
    for k in order:
        if k in data:
            ordered[k] = data[k]
    for k, v in data.items():
        if k not in ordered:
            ordered[k] = v
    lines = yaml.safe_dump(
        ordered,
        sort_keys=False,
        allow_unicode=True,
        default_flow_style=False,
    ).rstrip()
    return f"---\n{lines}\n---\n"


def convert_rule_body(body: str) -> str:
    text = apply_skills_text_transforms(body)
    return fix_markdown_links_md_to_mdc(text)


def build_mdc(rel: Path, raw: str) -> str:
    """rel is relative path under ycc/rules (e.g. common/coding-style.md)."""
    _has_fm, fm_dict, body = parse_frontmatter(raw)
    merged = normalize_rule_frontmatter(rel, fm_dict, body)

    body_out = convert_rule_body(body)
    validate_description(rel, merged["description"], body_out)

    return dump_frontmatter(merged) + body_out


def iter_source_files(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*") if p.is_file())


def copy_mode(src: Path, dst: Path) -> None:
    try:
        st = src.stat()
        dst.chmod(stat.S_IMODE(st.st_mode))
    except OSError:
        pass


def write_tree(dest: Path, dry_run: bool) -> set[Path]:
    if not SRC_DIR.is_dir():
        raise SystemExit(f"Missing source directory: {SRC_DIR}")

    written: set[Path] = set()

    for src in iter_source_files(SRC_DIR):
        rel = src.relative_to(SRC_DIR)
        if rel.name == "README.md":
            dst_file = dest / rel
            written.add(rel)
            if dry_run:
                print(f"Would write {dst_file.relative_to(REPO_ROOT)}")
                continue
            dst_file.parent.mkdir(parents=True, exist_ok=True)
            text = apply_skills_text_transforms(src.read_text(encoding="utf-8"))
            text = fix_markdown_links_md_to_mdc(text)
            dst_file.write_text(text, encoding="utf-8")
            copy_mode(src, dst_file)
            continue

        if rel.suffix.lower() != ".md" or rel.name in SKIPPED_RULE_NAMES:
            continue

        out_rel = rel.with_suffix(".mdc")
        dst_file = dest / out_rel
        written.add(out_rel)

        if dry_run:
            print(f"Would write {dst_file.relative_to(REPO_ROOT)}")
            continue

        dst_file.parent.mkdir(parents=True, exist_ok=True)
        raw = src.read_text(encoding="utf-8")
        mdc = build_mdc(rel, raw)
        dst_file.write_text(mdc, encoding="utf-8")
        # Mode: follow source .md (usually 644)
        copy_mode(src, dst_file)

    if not dry_run:
        prune_orphans(dest, written)

    return written


def prune_orphans(dest: Path, source_rels: set[Path]) -> None:
    all_dest: list[Path] = [p for p in dest.rglob("*") if p.is_file()]
    for p in sorted(all_dest, key=lambda x: len(x.parts), reverse=True):
        try:
            rel = p.relative_to(dest)
        except ValueError:
            continue
        if rel not in source_rels:
            p.unlink()
    dirs = sorted(
        {d for d in dest.rglob("*") if d.is_dir()},
        key=lambda x: len(x.parts),
        reverse=True,
    )
    for d in dirs:
        if d == dest:
            continue
        try:
            next(d.iterdir())
        except StopIteration:
            d.rmdir()


def compare_trees(generated: Path, repo_dst: Path) -> list[str]:
    diffs: list[str] = []
    gen_files: set[Path] = set()
    for p in generated.rglob("*"):
        if p.is_file():
            gen_files.add(p.relative_to(generated))

    dst_files: set[Path] = set()
    if repo_dst.is_dir():
        for p in repo_dst.rglob("*"):
            if p.is_file():
                dst_files.add(p.relative_to(repo_dst))

    for rel in sorted(gen_files | dst_files):
        g = generated / rel
        r = repo_dst / rel
        if rel not in dst_files:
            diffs.append(f"missing in repo: {rel}")
            continue
        if rel not in gen_files:
            diffs.append(f"extra in repo: {rel}")
            continue
        if g.read_bytes() != r.read_bytes():
            diffs.append(f"drift: {rel}")
    return diffs


def lint_rule_policy(path: Path, data: dict[str, Any], body: str) -> int:
    """Return policy errors for one generated rule."""
    errors = 0
    label = path.relative_to(REPO_ROOT)
    try:
        validate_description(path.relative_to(DST_DIR), data.get("description"), body)
    except SystemExit as exc:
        print(f"BAD description: {label}: {exc}", file=sys.stderr)
        errors += 1
    if path.name == "hooks.mdc":
        print(f"CLAUDE-ONLY hooks rule emitted: {label}", file=sys.stderr)
        errors += 1
    if re.search(r"~/.claude/|\.claude/settings\.json|Task execution", body):
        print(f"CLAUDE-ONLY content: {label}", file=sys.stderr)
        errors += 1
    return errors


def lint_generated_rules() -> int:
    """Verify each .mdc has required frontmatter keys and follows policy."""
    errors = 0
    always: list[tuple[Path, int]] = []
    for path in sorted(DST_DIR.rglob("*.mdc")):
        raw = path.read_text(encoding="utf-8")
        if not raw.startswith("---\n"):
            print(f"MISSING frontmatter: {path.relative_to(REPO_ROOT)}", file=sys.stderr)
            errors += 1
            continue
        end = raw.find("\n---\n", 4)
        if end == -1:
            print(f"MALFORMED frontmatter: {path.relative_to(REPO_ROOT)}", file=sys.stderr)
            errors += 1
            continue
        fm_text = raw[4:end]
        data = yaml.safe_load(fm_text) or {}
        if "description" not in data:
            print(f"MISSING description: {path.relative_to(REPO_ROOT)}", file=sys.stderr)
            errors += 1
        if "alwaysApply" not in data:
            print(f"MISSING alwaysApply: {path.relative_to(REPO_ROOT)}", file=sys.stderr)
            errors += 1
        if not data.get("alwaysApply") and "globs" not in data and path.parts[-2] != "common":
            print(
                f"MISSING globs (scoped rule): {path.relative_to(REPO_ROOT)}",
                file=sys.stderr,
            )
            errors += 1
        errors += lint_rule_policy(path, data, raw[end + 5 :])
        if data.get("alwaysApply"):
            always.append((path, len(raw[end + 5 :].splitlines())))
    if len(always) > ALWAYS_APPLY_MAX_RULES:
        print(f"TOO MANY alwaysApply rules: {len(always)} > {ALWAYS_APPLY_MAX_RULES}", file=sys.stderr)
        errors += 1
    if sum(n for _, n in always) > ALWAYS_APPLY_MAX_BODY_LINES:
        print(
            f"alwaysApply body too large: {sum(n for _, n in always)} > {ALWAYS_APPLY_MAX_BODY_LINES}",
            file=sys.stderr,
        )
        errors += 1
    return errors


def run_check() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tpath = Path(tmp)
        write_tree(tpath, dry_run=False)
        diffs = compare_trees(tpath, DST_DIR)
        if diffs:
            print(
                "Cursor rules are out of date. Run: ./scripts/generate-cursor-rules.sh",
                file=sys.stderr,
            )
            for line in diffs:
                print(f"  {line}", file=sys.stderr)
            return 1
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit 1 if packages/cursor/ycc-rules/rules differs from generator output",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print paths that would be written (no writes)",
    )
    parser.add_argument(
        "--lint",
        action="store_true",
        help="Validate frontmatter on existing packages/cursor/ycc-rules/rules (no generation)",
    )
    args = parser.parse_args()

    if args.lint:
        n = lint_generated_rules()
        sys.exit(1 if n else 0)

    if args.check:
        if not DST_DIR.is_dir():
            print(
                f"Missing {DST_DIR}; run generator without --check first.",
                file=sys.stderr,
            )
            sys.exit(1)
        sys.exit(run_check())

    if args.dry_run:
        write_tree(DST_DIR, dry_run=True)
        return

    write_tree(DST_DIR, dry_run=False)
    n = sum(1 for _ in DST_DIR.rglob("*") if _.is_file())
    print(f"Wrote {n} files under {DST_DIR}")


if __name__ == "__main__":
    main()
