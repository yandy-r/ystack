#!/usr/bin/env python3
"""
Generate Cursor-native agent definitions in packages/cursor/ycc/agents from ycc/agents.

Transforms are deterministic and idempotent. Source of truth: ycc/agents/*.md
"""

from __future__ import annotations

import argparse
import filecmp
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = REPO_ROOT / "ycc" / "agents"
DST_DIR = REPO_ROOT / "packages/cursor/ycc/agents"
FAST_ALLOWLIST_PATH = REPO_ROOT / "scripts" / "cursor_fast_agents.json"
MODEL_SETTINGS_PATH = REPO_ROOT / "ycc" / "settings" / "models.json"

# Frontmatter `name:` must match filename stem for Cursor discovery where we fix drift.
NAME_OVERRIDES: dict[str, str] = {
    "feature-researcher": "feature-researcher",
    "turso-database-architect": "turso-database-architect",
    "code-researcher": "code-researcher",
}


def strip_preamble_before_frontmatter(text: str) -> str:
    """Remove stray lines before the first YAML frontmatter opener."""
    if text.startswith("---"):
        return text
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if line.strip() == "---":
            return "".join(lines[i:])
    return text


def fix_mcp_malformed_tokens(s: str) -> str:
    """Fix mcp**server**tool-id style typos to mcp__server__tool-id."""
    prev = None
    out = s
    while prev != out:
        prev = out
        out = re.sub(
            r"mcp\*\*([a-zA-Z0-9]+)\*\*([a-zA-Z0-9][a-zA-Z0-9.-]*)",
            r"mcp__\1__\2",
            out,
        )
    return out


def apply_text_transforms(s: str) -> str:
    s = fix_mcp_malformed_tokens(s)

    # Config / template paths
    s = s.replace("~/.claude/", "~/.cursor/")

    # Slash commands: /ycc:skill -> /skill
    s = re.sub(r"/ycc:([a-zA-Z0-9-]+)", r"/\1", s)

    # Agent namespace references: ycc:agent-name -> agent-name (word boundary)
    s = re.sub(r"\bycc:([a-zA-Z0-9-]+)\b", r"\1", s)

    # Orchestration wording (Claude Code Task tool -> Cursor-native)
    s = re.sub(
        r"(?i)use the Task tool to launch (?:the )?`?([a-zA-Z0-9-]+)`? agent",
        r"invoke the `\1` agent",
        s,
    )
    s = re.sub(
        r"(?i)use the Task tool to launch the ([a-zA-Z0-9-]+) agent",
        r"invoke the `\1` agent",
        s,
    )
    s = s.replace("Task tool to launch", "invoke")
    s = s.replace("the Task tool", "a parallel agent run")

    # Product/session wording
    s = s.replace("main Claude session", "main Cursor session")
    s = s.replace("Claude is running ", "When running ")
    s = re.sub(r"\bClaude API with structured output\b", "LLM API with structured output", s)
    s = s.replace(
        "Focus ONLY on non-obvious information that Claude wouldn't inherently know.",
        "Focus ONLY on non-obvious information that a model wouldn't inherently know.",
    )
    s = s.replace(
        'Ask: "Would Claude make a mistake without this information?"',
        'Ask: "Would a reader make a mistake without this information?"',
    )

    # Paths / ignore lists
    s = s.replace("- /.claude", "- /.cursor")

    return s


def load_fast_allowlist() -> set[str]:
    """Load the Cursor fast-model allowlist from JSON."""
    try:
        raw = json.loads(FAST_ALLOWLIST_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SystemExit(f"Missing fast-agent allowlist: {FAST_ALLOWLIST_PATH}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {FAST_ALLOWLIST_PATH}: {exc}") from exc

    if not isinstance(raw, list):
        raise SystemExit(f"{FAST_ALLOWLIST_PATH} must be a JSON array of agent names")

    allowlist: set[str] = set()
    for item in raw:
        if not isinstance(item, str):
            raise SystemExit(f"{FAST_ALLOWLIST_PATH} entries must be strings: {item!r}")
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*[a-z0-9]|[a-z0-9]", item):
            raise SystemExit(f"Invalid agent name in {FAST_ALLOWLIST_PATH}: {item!r}")
        allowlist.add(item)
    return allowlist


def load_subagent_model() -> str:
    """Read the Cursor sub-agent model from the shared model source of truth.

    Cursor resolves a subagent's model from its own frontmatter, so the
    preferred sub-agent model and effort are expressed per generated agent
    file rather than in cli-config.json (which only carries the main model).
    """
    try:
        payload = json.loads(MODEL_SETTINGS_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SystemExit(f"Missing model settings: {MODEL_SETTINGS_PATH}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in {MODEL_SETTINGS_PATH}: {exc}") from exc

    model = payload.get("targets", {}).get("cursor", {}).get("subagent", {}).get("model")
    if not isinstance(model, str) or not model.strip():
        raise SystemExit(f"{MODEL_SETTINGS_PATH}: targets.cursor.subagent.model must be a non-empty string")
    return model.strip()


def normalize_frontmatter_model(text: str, stem: str, fast_allowlist: set[str], subagent_model: str) -> str:
    """Pin generated Cursor agents to `fast` or the preferred sub-agent model."""
    model_value = "fast" if stem in fast_allowlist else subagent_model
    lines = text.splitlines()
    if len(lines) < 3 or lines[0].strip() != "---":
        return text

    try:
        close_idx = lines.index("---", 1)
    except ValueError:
        return text

    frontmatter = lines[1:close_idx]
    model_idx = next(
        (idx for idx, line in enumerate(frontmatter) if re.match(r"^\s*model\s*:", line)),
        None,
    )
    if model_idx is None:
        frontmatter.append(f"model: {model_value}")
    else:
        frontmatter[model_idx] = f"model: {model_value}"

    rebuilt = ["---", *frontmatter, "---", *lines[close_idx + 1 :]]
    return "\n".join(rebuilt)


def fix_frontmatter_name(text: str, stem: str) -> str:
    """Ensure name: matches filename stem when listed in NAME_OVERRIDES."""
    if stem not in NAME_OVERRIDES:
        return text
    new_name = NAME_OVERRIDES[stem]
    # First `name:` after opening ---
    return re.sub(
        r"(^---\s*\n)(name:\s*)([^\n]+)",
        lambda m: f"{m.group(1)}{m.group(2)}{new_name}",
        text,
        count=1,
        flags=re.MULTILINE,
    )


def transform_file(stem: str, content: str, fast_allowlist: set[str], subagent_model: str) -> str:
    text = strip_preamble_before_frontmatter(content)
    text = apply_text_transforms(text)
    text = fix_frontmatter_name(text, stem)
    text = normalize_frontmatter_model(text, stem, fast_allowlist, subagent_model)
    # Normalize trailing newline
    if text and not text.endswith("\n"):
        text += "\n"
    return text


def write_all(dry_run: bool, dest: Path) -> list[Path]:
    written: list[Path] = []
    if not SRC_DIR.is_dir():
        raise SystemExit(f"Missing source directory: {SRC_DIR}")

    src_files = sorted(SRC_DIR.glob("*.md"))
    source_stems = {src.stem for src in src_files}
    fast_allowlist = load_fast_allowlist()
    subagent_model = load_subagent_model()
    unknown_fast_agents = sorted(fast_allowlist - source_stems)
    if unknown_fast_agents:
        raise SystemExit(
            "Unknown agent name(s) in fast allowlist: "
            + ", ".join(unknown_fast_agents)
            + f" (source directory: {SRC_DIR})"
        )

    source_names: set[str] = set()
    for src in src_files:
        source_names.add(src.name)
        stem = src.stem
        out = transform_file(stem, src.read_text(encoding="utf-8"), fast_allowlist, subagent_model)
        target = dest / src.name
        if dry_run:
            print(f"Would write {target.relative_to(REPO_ROOT)} ({len(out)} bytes)")
            written.append(target)
            continue
        dest.mkdir(parents=True, exist_ok=True)
        target.write_text(out, encoding="utf-8")
        written.append(target)

    # Mirror source exactly: remove generated *.md not present in ycc/agents
    if not dry_run:
        for orphan in sorted(dest.glob("*.md")):
            if orphan.name not in source_names:
                orphan.unlink()
    else:
        for orphan in sorted(dest.glob("*.md")):
            if orphan.name not in source_names:
                print(f"Would remove {orphan.relative_to(REPO_ROOT)} (not in {SRC_DIR.name}/)")

    return written


def run_check() -> int:
    """Generate to a temp dir and compare to DST_DIR."""
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        tpath = Path(tmp)
        write_all(dry_run=False, dest=tpath)
        dcmp = filecmp.dircmp(tpath, DST_DIR, ignore=[])
        diff_files: list[str] = []
        for name in sorted(set(dcmp.left_list) | set(dcmp.right_list)):
            if name.startswith("."):
                continue
            lf, rf = tpath / name, DST_DIR / name
            if not lf.is_file() and rf.is_file():
                diff_files.append(f"extra in repo (remove or regenerate): {name}")
                continue
            if lf.is_file() and not rf.is_file():
                diff_files.append(f"missing in repo: {name}")
                continue
            if not lf.is_file() and not rf.is_file():
                continue
            if lf.read_bytes() != rf.read_bytes():
                diff_files.append(f"drift: {name}")

        if diff_files:
            print(
                "Cursor agents are out of date. Run: ./scripts/generate-cursor-agents.sh",
                file=sys.stderr,
            )
            for line in diff_files:
                print(f"  {line}", file=sys.stderr)
            return 1
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit 1 if packages/cursor/ycc/agents differs from generator output",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print paths that would be written (no writes)",
    )
    args = parser.parse_args()

    if args.check:
        if not DST_DIR.is_dir():
            print(
                f"Missing {DST_DIR}; run generator without --check first.",
                file=sys.stderr,
            )
            sys.exit(1)
        sys.exit(run_check())

    if args.dry_run:
        write_all(dry_run=True, dest=DST_DIR)
        return

    write_all(dry_run=False, dest=DST_DIR)
    print(f"Wrote {len(list(DST_DIR.glob('*.md')))} files to {DST_DIR}")


if __name__ == "__main__":
    main()
