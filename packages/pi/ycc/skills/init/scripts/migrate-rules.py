#!/usr/bin/env python3
"""Rules migration engine for /ycc:init --migrate-rules.

Moves a long, canonical-style CLAUDE.md into the tool-neutral AGENTS.md and
leaves CLAUDE.md as ``@AGENTS.md`` plus its clearly Claude-specific sections.

Conservative by design:

* Already-migrated detection uses the shared parser in
  ``ycc/skills/_shared/scripts/rules_pointer.py`` (same semantics as
  release-model's pointer-targets.sh: standalone line only; prose, comments,
  code fences, CRLF and BOM handled).
* Section routing defaults to AGENTS.md. A section is kept in CLAUDE.md only
  when its heading matches the explicit Claude-only allow-list below.
  Headings that merely contain the word "claude" are routed to AGENTS.md and
  reported as ambiguous. Nothing is ever deleted silently: the only dropped
  bytes are a replaced pointer-style AGENTS.md (shown in full) and moved
  sections skipped as duplicates of an existing custom AGENTS.md (reported
  by heading).
* Safety: refuses to run outside git unless --allow-non-git (which first
  writes timestamped backups); refuses uncommitted or git-ignored rules
  files; refuses symlinks; writes via temp file + atomic rename; the pair
  is never partially written (all writes are prepared and pre-checked
  before the first rename).
"""

from __future__ import annotations

import argparse
import difflib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

if sys.version_info < (3, 11):  # noqa: UP036 - runtime guard for older python3
    print(f"migrate-rules: python3 3.11+ required, found {sys.version.split()[0]}", file=sys.stderr)
    raise SystemExit(1)

from datetime import UTC, datetime  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rules_file_lib import (  # noqa: E402
    CLAUDE_SHIM_LINE,
    detect_agents_import,
    detect_eol,
    heading_of,
    is_legacy_agents_pointer,
    read_text_relaxed,
    split_sections,
)

# Exact Claude runtime headings only, never a "claude" substring heuristic.
CLAUDE_ONLY_HEADINGS = {
    "claude-only notes",
    "claude-specific notes",
    "claude-specific repository notes",
    "claude code setup",
    "claude code instructions",
    "claude code hooks",
}
TOOLING_HEADINGS = {"hooks", "skills", "slash commands", "subagents"}
AMBIGUOUS_PATTERN = re.compile(r"\bclaude\b", re.IGNORECASE)


def git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)


def is_git_repo(repo: Path) -> bool:
    return git(repo, "rev-parse", "--git-dir").returncode == 0


def git_ignores(repo: Path, path: str) -> bool:
    return git(repo, "check-ignore", "-q", path).returncode == 0


def git_dirty(repo: Path) -> str:
    res = git(repo, "status", "--porcelain", "--", "CLAUDE.md", "AGENTS.md")
    return res.stdout.strip() if res.returncode == 0 else ""


def classify(heading: str | None, section: list[str] | None = None) -> str:
    """Keep only normative Claude headings or Claude runtime sections."""
    if heading is None:
        return "agents"
    name = re.sub(r"^#+\s*", "", heading).strip().lower()
    if name in CLAUDE_ONLY_HEADINGS:
        return "claude"
    if (
        name in TOOLING_HEADINGS
        and section
        and re.search(
            r"\.claude/(?:settings|hooks|agents|skills)|CLAUDE_PLUGIN_ROOT|claude code hooks", "\n".join(section)
        )
    ):
        return "claude"
    if AMBIGUOUS_PATTERN.search(heading) or name in TOOLING_HEADINGS:
        return "agents-ambiguous"
    return "agents"


def existing_headings(sections: list[list[str]]) -> set[str]:
    out = set()
    for sec in sections:
        h = heading_of(sec)
        if h:
            out.add(re.sub(r"^#+\s*", "", h).strip().lower())
    return out


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True, description="Migrate CLAUDE.md rules to canonical AGENTS.md.")
    ap.add_argument("--repo", default=os.getcwd())
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument(
        "--allow-non-git", action="store_true", help="permit migration outside git (writes timestamped backups first)"
    )
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    if not repo.is_dir():
        print(f"migrate-rules: directory not found: {repo}", file=sys.stderr)
        return 1
    claude_path = repo / "CLAUDE.md"
    agents_path = repo / "AGENTS.md"
    if not claude_path.is_file():
        print(f"migrate-rules: no CLAUDE.md at {repo} — nothing to migrate.", file=sys.stderr)
        return 1
    if agents_path.exists() and not agents_path.is_file():
        print("migrate-rules: AGENTS.md must be a regular file", file=sys.stderr)
        return 1
    if claude_path.is_symlink() or agents_path.is_symlink():
        print("migrate-rules: refusing symlinked rules files", file=sys.stderr)
        return 1
    if not args.dry_run and not args.yes:
        print(
            "migrate-rules: refusing to write without --dry-run or --yes (dry-run first is required).", file=sys.stderr
        )
        return 1

    try:
        claude_text, claude_bom = read_text_relaxed(claude_path)
    except UnicodeDecodeError:
        print("migrate-rules: CLAUDE.md must be UTF-8; refusing lossy conversion", file=sys.stderr)
        return 1
    claude_eol = detect_eol(claude_text)
    if detect_agents_import(claude_text):
        if not agents_path.is_file():
            print("migrate-rules: dangling @AGENTS.md import; repair the missing file first", file=sys.stderr)
            return 1
        print("migrate-rules: CLAUDE.md is already a @AGENTS.md pointer — nothing to do.")
        return 0

    # --- git safety ------------------------------------------------------
    in_git = is_git_repo(repo)
    if in_git:
        root = git(repo, "rev-parse", "--show-toplevel").stdout.strip()
        if Path(root).resolve() != repo:
            print("migrate-rules: --repo must be the git repository root", file=sys.stderr)
            return 1
    ignored = False
    backups: list[Path] = []
    if in_git:
        dirty = git_dirty(repo)
        if dirty and not args.dry_run:
            print(
                "migrate-rules: CLAUDE.md/AGENTS.md have uncommitted changes — commit or stash first "
                "so git can restore them:",
                file=sys.stderr,
            )
            print(dirty, file=sys.stderr)
            return 1
        ignored = git_ignores(repo, "CLAUDE.md") or git_ignores(repo, "AGENTS.md")
    if (not in_git or ignored) and not args.allow_non_git:
        where = "git-ignored" if ignored else "not a git repository"
        print(
            f"migrate-rules: {where} at {repo} — refusing without --allow-non-git "
            "(that mode writes timestamped backups first).",
            file=sys.stderr,
        )
        return 1

    # --- split + classify -------------------------------------------------
    sections = split_sections(claude_text)
    moved: list[list[str]] = []
    kept: list[list[str]] = []
    ambiguous: list[str] = []
    total = len(claude_text.splitlines())
    for sec in sections:
        h = heading_of(sec)
        kind = classify(h, sec)
        if kind == "claude":
            kept.append(sec)
        else:
            moved.append(sec)
            if kind == "agents-ambiguous" and h:
                ambiguous.append(h)

    # --- existing AGENTS.md ----------------------------------------------
    agents_exists = agents_path.is_file()
    agents_text = ""
    agents_original = ""
    agents_bom = False
    agents_eol = claude_eol
    agents_is_pointer = False
    if agents_exists:
        try:
            agents_text, agents_bom = read_text_relaxed(agents_path)
        except UnicodeDecodeError:
            print("migrate-rules: AGENTS.md must be UTF-8; refusing lossy conversion", file=sys.stderr)
            return 1
        agents_original = agents_text
        agents_eol = detect_eol(agents_text)
        agents_is_pointer = is_legacy_agents_pointer(agents_text)

    skipped_dupes: list[str] = []
    dropped_title = False
    conflicts: list[str] = []
    neutralized: list[str] = []
    if agents_exists and not agents_is_pointer:
        # Only exact legacy directives are retired. Mentions of CLAUDE.md in
        # genuine rules are preserved; retired text stays visible as comments.
        retired = {
            "The canonical agent rules for this repository live in [`CLAUDE.md`](CLAUDE.md).",
            (
                "`CLAUDE.md` is the source of truth. Do not edit this file except to add\n"
                "agent-runtime-specific notes. Never duplicate `CLAUDE.md` content here."
            ),
            "- Cursor: also reads `.cursor/rules/project.mdc` (same content, MDC-formatted).",
            "- For deep analysis of this repository, start with `CLAUDE.md` and the stack overview.",
        }
        for directive in sorted(retired):
            if directive in agents_text:
                neutralized.append(directive)
                agents_text = agents_text.replace(
                    directive, "<!-- Retired legacy pointer directive:\n" + directive + "\n-->"
                )

    if agents_exists and not agents_is_pointer:
        existing_sections = split_sections(agents_text)
        names = existing_headings(existing_sections)
        additions: list[list[str]] = []
        for sec in moved:
            h = heading_of(sec)
            if h and h.startswith("# "):
                # Keep the existing document title, retaining its intro text.
                # Mid-file H1 sections become H2, not dangling headingless bodies.
                if sec is sections[0]:
                    dropped_title = True
                    sec = sec[1:]
                else:
                    sec = ["#" + h, *sec[1:]]
                    conflicts.append(f"{h} (promoted to H2 to keep one document title)")
            elif h and re.sub(r"^#+\s*", "", h).strip().lower() in names:
                title = re.sub(r"^#+\s*", "", h).strip().lower()
                matching = next(
                    item
                    for item in existing_sections
                    if heading_of(item) and re.sub(r"^#+\s*", "", heading_of(item) or "").strip().lower() == title
                )
                # Merge content under the existing heading, avoiding a duplicate
                # heading but never silently discarding conflicting body text.
                body = "\n".join(sec[1:]).strip()
                existing_body = "\n".join(matching[1:]).strip()
                if body and body != existing_body:
                    matching.extend(["", *sec[1:]])
                    conflicts.append(h)
                else:
                    skipped_dupes.append(h)
                continue
            if heading_of(sec):
                name = re.sub(r"^#+\s*", "", heading_of(sec) or "").strip().lower()
                duplicate = next(
                    (
                        item
                        for item in additions
                        if heading_of(item) and re.sub(r"^#+\s*", "", heading_of(item) or "").strip().lower() == name
                    ),
                    None,
                )
                if duplicate is not None:
                    duplicate.extend(["", *sec[1:]])
                    conflicts.append(heading_of(sec) or "")
                    continue
            additions.append(sec)
        agents_text = "\n".join("\n".join(sec).rstrip("\n") for sec in existing_sections) + "\n"
        moved = additions

    # --- build outputs ----------------------------------------------------
    def join(sections_list: list[list[str]]) -> str:
        chunks = []
        for sec in sections_list:
            body = "\n".join(sec)
            body = body.rstrip("\n").replace("\r", "")
            if body.strip():
                chunks.append(body)
        return "\n\n".join(chunks) + "\n" if chunks else ""

    moved_text = join(moved)
    if agents_exists and not agents_is_pointer and agents_text.strip():
        new_agents = agents_text.rstrip("\n").replace("\r", "") + "\n\n" + moved_text
    else:
        new_agents = moved_text
    new_claude = CLAUDE_SHIM_LINE + "\n"
    kept_text = join(kept)
    if kept_text:
        new_claude += "\n" + kept_text

    if claude_eol == "\r\n":
        new_claude = new_claude.replace("\n", "\r\n")
    if agents_eol == "\r\n":
        new_agents = new_agents.replace("\n", "\r\n")
    if agents_bom:
        new_agents = "\ufeff" + new_agents
    if claude_bom:
        new_claude = "\ufeff" + new_claude

    # --- report -----------------------------------------------------------
    print(f"Migration plan for {repo}")
    print(f"  CLAUDE.md ({total} lines) -> AGENTS.md canonical")
    print("  Section routing (heading -> destination):")
    for sec in sections:
        h = heading_of(sec) or "(preamble)"
        kind = classify(heading_of(sec), sec)
        dest = {
            "claude": "CLAUDE.md",
            "agents": "AGENTS.md",
            "agents-ambiguous": "AGENTS.md (ambiguous heading, reported)",
        }
        print(f"    {h} -> {dest[kind]}")
    print()
    print(f"New line counts: AGENTS.md={len(new_agents.splitlines())}, " f"CLAUDE.md={len(new_claude.splitlines())}")
    if ambiguous:
        print()
        print("Ambiguous headings routed to AGENTS.md (review): " + "; ".join(ambiguous))
    print()
    print("Content-loss list:")
    for directive in neutralized:
        print("  - Retired legacy directive preserved as an HTML maintainer comment:")
        for line in directive.splitlines():
            print("      | " + line)
    for h in conflicts:
        print(f"  - Merge conflict preserved under one heading: {h} (both bodies retained; review required)")
    if agents_is_pointer:
        print("  - Replaced pointer-style AGENTS.md (full former content):")
        for line in agents_text.rstrip("\n").split("\n"):
            print(f"      | {line.rstrip()}")
    elif not agents_exists:
        print("  - none (AGENTS.md will be created)")
    for h in skipped_dupes:
        print(f"  - Skipped duplicate section (already in AGENTS.md): {h}")
    if dropped_title:
        print("  - Skipped moved H1 title (existing AGENTS.md keeps its own title)")
    if not (agents_is_pointer or skipped_dupes or dropped_title or conflicts or neutralized) and agents_exists:
        print("  - none")
    print()
    print("----- diff: AGENTS.md -----")
    if agents_exists:
        print(
            "".join(
                difflib.unified_diff(
                    agents_original.splitlines(keepends=True),
                    new_agents.splitlines(keepends=True),
                    fromfile="AGENTS.md",
                    tofile="AGENTS.md.new",
                )
            )
            or "(no change)"
        )
    else:
        print(
            "".join(
                difflib.unified_diff([], new_agents.splitlines(keepends=True), fromfile="/dev/null", tofile="AGENTS.md")
            )
        )
    print("----- diff: CLAUDE.md -----")
    print(
        "".join(
            difflib.unified_diff(
                claude_text.splitlines(keepends=True),
                new_claude.splitlines(keepends=True),
                fromfile="CLAUDE.md",
                tofile="CLAUDE.md.new",
            )
        )
    )

    if args.dry_run:
        print("Dry run: no files changed.")
        return 0

    # --- write (atomic, pre-checked) -------------------------------------
    try:
        for p in (claude_path, agents_path):
            if p.exists():
                usable = p.stat().st_mode & 0o222
                if not usable:
                    raise PermissionError(f"{p} is not writable")
            elif not (p.parent.stat().st_mode & 0o222):
                raise PermissionError(f"{p.parent} is not writable")

        # Backups also provide rollback if the second atomic rename fails.
        stamp = datetime.now(UTC).strftime("%Y%m%d-%H%M%S-%f")
        if in_git:
            gitdir = Path(git(repo, "rev-parse", "--absolute-git-dir").stdout.strip())
            backup_dir = gitdir / "ycc-rule-backups" / stamp
        else:
            backup_dir = repo / ".ycc-rule-backups" / stamp
        backup_dir.mkdir(parents=True, exist_ok=False)
        for src in (claude_path, agents_path):
            if src.exists():
                dst = backup_dir / src.name
                shutil.copy2(src, dst)
                backups.append(dst)
        print(f"Backups written: {backup_dir} (keep for recovery)")
        temps: list[tuple[Path, Path]] = []
        try:
            for path, content in ((agents_path, new_agents), (claude_path, new_claude)):
                fd, name = tempfile.mkstemp(prefix=f".{path.name}.migrate-", dir=repo)
                tmp = Path(name)
                temps.append((tmp, path))
                with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
                    handle.write(content)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.chmod(tmp, path.stat().st_mode & 0o777 if path.exists() else 0o644)
            for tmp, path in temps:
                os.replace(tmp, path)
        except OSError:
            # Restore the pair from backups rather than leave a partial migration.
            for path in (agents_path, claude_path):
                original = backup_dir / path.name
                if original.exists():
                    shutil.copy2(original, path)
                elif path.exists():
                    path.unlink()
            raise
        finally:
            for tmp, _ in temps:
                if tmp.exists():
                    tmp.unlink()
    except OSError as exc:
        print(f"migrate-rules: write failed: {exc}", file=sys.stderr)
        return 2

    print(
        f"Applied: AGENTS.md ({len(new_agents.splitlines())} lines) + "
        f"CLAUDE.md ({len(new_claude.splitlines())} lines)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
