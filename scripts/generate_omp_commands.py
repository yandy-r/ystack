#!/usr/bin/env python3
"""
Generate OMP (oh-my-pi) command entrypoints under packages/omp/ycc/commands from ycc/skills.

Every public skill gets one thin wrapper, `commands/<skill>.md`, that tells OMP to read
`skill://<skill>` and follow it with the user's `$ARGUMENTS`. OMP registers plugin
commands as `<plugin>:<file stem>`, so the ycc package exposes `/ycc:<skill>`. Public means
the skill directory is not `_`-prefixed and `user-invocable` is not `false`; manual-only
skills (`disable-model-invocation: true`) still get a command. Names that OMP cannot
dispatch fail generation. Source of truth: ycc/skills/
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from generate_codex_common import dump_frontmatter, parse_frontmatter
from generate_omp_skills import (
    SRC_DIR,
    Catalog,
    OmpGenerationError,
    build_catalog,
    compare_trees,
    prune_orphans,
    transform_text,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
DST_DIR = REPO_ROOT / "packages/omp/ycc/commands"

# Plugin name OMP prefixes to every command file stem (`/ycc:<skill>`).
COMMAND_NAMESPACE = "ycc"
COMMAND_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")

# OMP built-in slash command names and aliases, pinned from omp 18.12.3
# packages/coding-agent/src/slash-commands/*.ts (BUILTIN_SLASH_COMMAND_RESERVED_NAMES:
# every top-level `name:` and `aliases:` entry in the builtin-*.ts registries and
# seance.ts). Built-ins dispatch before file commands and parse the name up to the first
# whitespace or colon, so the namespace must not be one of these, and no `ycc:<name>` may
# equal one (the `force:` alias contains a colon). scripts/omp_builtin_commands.py checks
# this pin against a live omp's RPC `get_available_commands` (validate.sh --only omp).
OMP_BUILTIN_COMMANDS: frozenset[str] = frozenset(
    {
        "add-dir",
        "advisor",
        "agents",
        "branch",
        "browser",
        "btw",
        "changelog",
        "cleanse",
        "clear",
        "collab",
        "compact",
        "computer",
        "context",
        "copy",
        "debug",
        "delete",
        "dirs",
        "dump",
        "effort",
        "exit",
        "export",
        "extended-context",
        "extensions",
        "fast",
        "force",
        "force:",
        "forget-approvals",
        "fork",
        "fresh",
        "git",
        "goal",
        "guided-goal",
        "handoff",
        "hotkeys",
        "hub",
        "jobs",
        "join",
        "leave",
        "live",
        "login",
        "logout",
        "loop",
        "marketplace",
        "mcp",
        "memory",
        "model",
        "modelpreset",
        "models",
        "move",
        "new",
        "omfg",
        "open",
        "pause",
        "pin",
        "plan",
        "plan-review",
        "plugin",
        "plugins",
        "prewalk",
        "providers",
        "q",
        "queue",
        "quit",
        "ratchet",
        "record",
        "reload-plugins",
        "remove-dir",
        "rename",
        "restart",
        "resume",
        "retry",
        "rewind",
        "seance",
        "security",
        "session",
        "settings",
        "setup",
        "shake",
        "share",
        "skillful",
        "skills",
        "slow",
        "ssh",
        "stats",
        "status",
        "switch",
        "tan",
        "todo",
        "tools",
        "trace",
        "tree",
        "unpin",
        "usage",
        "vibe",
        "worktree",
        "wt",
    }
)


@dataclass(frozen=True)
class Command:
    """One public skill's command entrypoint."""

    name: str
    description: str
    argument_hint: str | None


def _rel(name: str) -> Path:
    return Path("commands") / f"{name}.md"


def check_namespace(namespace: str, reserved: frozenset[str]) -> None:
    if namespace in reserved:
        raise OmpGenerationError(f"command namespace '{namespace}' is an OMP built-in command name or alias")


def is_public(frontmatter: Mapping[str, Any], directory: str) -> bool:
    """D3: not `_`-prefixed and `user-invocable` not false; manual-only skills are public."""
    if directory.startswith("_"):
        return False
    invocable = frontmatter.get("user-invocable", True)
    if type(invocable) is not bool:
        raise OmpGenerationError(f"skill '{directory}': 'user-invocable' must be a boolean, got {invocable!r}")
    return invocable


def _rewrite(value: str, rel: Path, catalog: Catalog) -> str:
    """The skills generator's text transform, so command and skill text agree (D5)."""
    # transform_text always terminates its output; keep only a newline the value had.
    out = transform_text(value, rel, catalog)
    return out if value.endswith("\n") else out.removesuffix("\n")


def load_commands(
    src: Path,
    catalog: Catalog,
    namespace: str = COMMAND_NAMESPACE,
    reserved: frozenset[str] = OMP_BUILTIN_COMMANDS,
) -> list[Command]:
    """Public skills as commands; fails on anything OMP cannot dispatch (D3, D4)."""
    check_namespace(namespace, reserved)
    commands: list[Command] = []
    seen: dict[str, str] = {}
    for path in sorted(src.glob("*/SKILL.md")):
        directory = path.parent.name
        frontmatter: dict[str, Any] = parse_frontmatter(path.read_text(encoding="utf-8"))[0]
        if not is_public(frontmatter, directory):
            continue
        name = frontmatter.get("name", directory)
        if not isinstance(name, str) or not COMMAND_NAME.match(name):
            raise OmpGenerationError(f"skill '{directory}': command name {name!r} must match {COMMAND_NAME.pattern}")
        rel = _rel(name)
        if name in seen:
            raise OmpGenerationError(f"{rel}: duplicate command name '{name}' (also skill '{seen[name]}')")
        seen[name] = directory
        qualified = f"{namespace}:{name}"
        if qualified in reserved:
            raise OmpGenerationError(f"{rel}: '{qualified}' is an OMP built-in command name or alias")
        description = frontmatter.get("description")
        if not isinstance(description, str) or not description.strip():
            raise OmpGenerationError(f"{rel}: skill '{directory}' needs a non-empty string description")
        hint = frontmatter.get("argument-hint")
        if hint is not None and not isinstance(hint, str):
            raise OmpGenerationError(f"{rel}: 'argument-hint' must be a string, got {hint!r}")
        description = _rewrite(description, rel, catalog)
        commands.append(Command(name, description, None if hint is None else _rewrite(hint, rel, catalog)))
    return commands


def render_command(command: Command) -> str:
    """Thin wrapper: OMP reads the generated skill and passes the arguments through (D2)."""
    output: dict[str, Any] = {"description": command.description}
    if command.argument_hint is not None:
        output["argument-hint"] = command.argument_hint
    lines = [
        dump_frontmatter(output).removesuffix("\n"),
        "",
        f"Read `skill://{command.name}` and follow its instructions with these arguments:",
        "",
        "$ARGUMENTS",
    ]
    return "\n".join(lines) + "\n"


def write_tree(
    dest: Path,
    dry_run: bool,
    *,
    src_root: Path | None = None,
    namespace: str = COMMAND_NAMESPACE,
    reserved: frozenset[str] = OMP_BUILTIN_COMMANDS,
) -> set[Path]:
    """Write the OMP command tree under dest; returns the relative file paths written."""
    src = SRC_DIR if src_root is None else src_root
    if not src.is_dir():
        raise SystemExit(f"Missing source directory: {src}")
    commands = load_commands(src, build_catalog(src), namespace, reserved)
    outputs = {Path(f"{command.name}.md"): render_command(command) for command in commands}

    if dry_run:
        for rel in sorted(outputs):
            print(f"Would write {dest / rel}")
        return set(outputs)

    dest.mkdir(parents=True, exist_ok=True)
    for rel, text in sorted(outputs.items()):
        dst_file = dest / rel
        dst_file.write_text(text, encoding="utf-8")
        dst_file.chmod(0o644)
    prune_orphans(dest, set(outputs))
    return set(outputs)


def run_check(dest: Path = DST_DIR) -> int:
    with tempfile.TemporaryDirectory() as tmp:
        generated = Path(tmp)
        write_tree(generated, dry_run=False)
        diffs = compare_trees(generated, dest)
    if diffs:
        print("OMP commands are out of date. Run: ./scripts/generate-omp-commands.sh", file=sys.stderr)
        for line in diffs:
            print(f"  {line}", file=sys.stderr)
        return 1
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit 1 if packages/omp/ycc/commands differs from generator output (bytes or executable bits)",
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
        print(f"generate_omp_commands.py: {error}", file=sys.stderr)
        sys.exit(1)
    if not args.dry_run:
        print(f"Wrote {len(written)} files under {DST_DIR}")


if __name__ == "__main__":
    main()
