#!/usr/bin/env python3
"""Install, sync and remove the ycc Muse Code plugins.

Muse Code registers plugins with its own CLI and caches each install under a
content digest, so the generated skills cannot name a stable plugin root. This
helper therefore keeps a ycc-owned copy of every ``packages/muse/<name>``
package in ``~/.local/share/ycc/muse/<name>`` (the folder the generated skills
point at for their ``ycc-shared`` helpers) and installs Muse's plugin from that
copy:

- install: place or refresh the owned copy, then ``muse plugins install <copy>
  --scope user`` (``--scope project`` for a project install; idempotent) and, unless ``--no-approve``, ``muse plugins
  approve <name>`` so the ycc agents and MCP servers leave Muse's review queue.
- remove: ``muse plugins remove <name>`` (only a ycc-owned install), then delete
  the owned copy.

Ownership lives in ``~/.config/ycc/muse-install.json``: per plugin, a digest of
the owned copy and of its source. A copy ycc did not place (or one edited since)
is never replaced or removed without ``--force``; an identical copy is adopted.
``YCC_MUSE_PACKAGE_DIR`` moves the owned copies (the copies' helper paths are
rewritten to match) and ``YCC_MUSE_BIN`` selects the ``muse`` binary.
``--dry-run`` prints the plan and changes nothing.

Exit codes: 0 success, 1 a refused or failed package (others still processed
before exiting), 2 usage error.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from owned_tree import place_copy, relocate_tree, remove_tree, tree_digest

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = REPO_ROOT / "packages/muse"
PACKAGES = ("ycc", "ycc-mcp", "ycc-rules")
STATE_VERSION = 1
MANIFESTS = (".claude-plugin/plugin.json", ".muse-plugin/plugin.json")
# The generated skills reach the owned ycc copy through these spellings of the
# default folder (see generate_muse_packages.py INSTALL_ROOT).
DEFAULT_PREFIXES = ("${HOME}/.local/share/ycc/muse/", "~/.local/share/ycc/muse/")


def default_package_dir() -> Path:
    return Path.home() / ".local/share/ycc/muse"


def package_dir() -> Path:
    """Folder of the owned copies (``YCC_MUSE_PACKAGE_DIR`` overrides)."""
    override = os.environ.get("YCC_MUSE_PACKAGE_DIR")
    return Path(override).expanduser() if override else default_package_dir()


def relocated() -> bool:
    return package_dir().resolve() != default_package_dir().resolve()


def state_path() -> Path:
    return Path.home() / ".config/ycc/muse-install.json"


def load_state() -> dict[str, Any]:
    path = state_path()
    if not path.is_file():
        return {"version": STATE_VERSION, "packages": {}}
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"muse: unreadable ownership state {path}: {exc}") from None
    if (
        not isinstance(state, dict)
        or state.get("version") != STATE_VERSION
        or not isinstance(state.get("packages"), dict)
    ):
        raise SystemExit(f"muse: unsupported ownership state in {path}")
    return state


def save_state(state: dict[str, Any]) -> None:
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def resolve_muse() -> str | None:
    return os.environ.get("YCC_MUSE_BIN") or shutil.which("muse")


def source_package(source: Path, name: str) -> Path:
    root = source / name
    for rel in MANIFESTS:
        manifest = root / rel
        if not manifest.is_file():
            continue
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"{manifest}: malformed plugin manifest ({exc})") from None
        if data.get("name") != name:
            raise RuntimeError(f"{manifest}: name {data.get('name')!r} must be {name!r}")
        return root
    raise RuntimeError(f"{root}: no Muse plugin manifest ({' or '.join(MANIFESTS)})")


@dataclass
class Context:
    source: Path
    dry_run: bool
    force: bool
    approve: bool
    muse: str
    scope: str = "user"

    def run_muse(self, *args: str, allow_codes: tuple[str, ...] = ()) -> dict[str, Any]:
        """Run ``muse plugins <args> --json``; tolerate the named error codes."""
        command = [self.muse, "plugins", *args, "--json"]
        if self.dry_run:
            print(f"[dry-run] would run: {' '.join(command)}")
            return {}
        result = subprocess.run(command, check=False, capture_output=True, text=True)
        try:
            payload = json.loads(result.stdout) if result.stdout.strip() else {}
        except json.JSONDecodeError:
            payload = {}
        if result.returncode != 0:
            code = (payload.get("error") or {}).get("code") if isinstance(payload, dict) else None
            if code in allow_codes:
                return payload
            detail = (result.stderr or result.stdout).strip().splitlines()
            raise RuntimeError(f"{' '.join(command)} exited {result.returncode}: {detail[-1] if detail else ''}")
        return payload if isinstance(payload, dict) else {}

    def installed(self) -> set[str]:
        if self.dry_run:
            return set()
        payload = self.run_muse("list")
        return {plugin_id(item) for item in payload.get("plugins", []) if isinstance(item, dict)} - {""}


def plugin_id(item: dict[str, Any]) -> str:
    """The id of one ``muse plugins list --json`` row (``record.id``, else ``plugin.id``)."""
    for key in ("record", "plugin"):
        nested = item.get(key)
        if isinstance(nested, dict) and nested.get("id"):
            return str(nested["id"])
    return str(item.get("id") or "")


def ownership(state: dict[str, Any], name: str, dest: Path, src_digest: str | None) -> tuple[bool, str | None]:
    """Return (owned, reason-if-foreign) for the owned copy at ``dest``."""
    current = tree_digest(dest)
    record = state["packages"].get(name)
    if current is None:
        return (record is not None, None)
    if record is not None:
        if record.get("digest") not in (None, current):
            return (True, f"{dest} was edited since ycc placed it")
        return (True, None)
    if current == src_digest:
        return (True, None)  # an identical copy: adopt it
    return (False, f"{dest} exists and was not placed by ycc")


def copy_rewrite(dest: Path) -> Any:
    if not relocated():
        return None
    target = f"{dest.parent.resolve()}/"
    return lambda staged: relocate_tree(staged, DEFAULT_PREFIXES, target)


def install_one(ctx: Context, state: dict[str, Any], name: str, installed: set[str]) -> None:
    src = source_package(ctx.source, name)
    dest = package_dir() / name
    src_digest = tree_digest(src)
    _owned, problem = ownership(state, name, dest, src_digest)
    if problem and not ctx.force:
        raise RuntimeError(f"refusing to replace {name}: {problem} (re-run with --force)")
    record = state["packages"].get(name)
    current = tree_digest(dest)
    if (
        record is not None
        and current is not None
        and record.get("source_digest") == src_digest
        and record.get("digest") == current
        and record.get("scope", "user") == ctx.scope
        and name in installed
    ):
        print(f"[ok]  muse: {name} is up to date ({dest})")
        return
    if ctx.dry_run:
        print(f"[dry-run] would copy {src} -> {dest}")
    else:
        place_copy(src, dest, copy_rewrite(dest))
    ctx.run_muse("install", str(dest), "--scope", ctx.scope)
    if ctx.approve:
        ctx.run_muse("approve", name)
    if ctx.dry_run:
        return
    state["packages"][name] = {
        "digest": tree_digest(dest),
        "source": str(src.resolve()),
        "source_digest": src_digest,
        "approved": ctx.approve,
        "scope": ctx.scope,
    }
    print(f"[ok]  muse: installed {name} from {dest}" + (" (approved)" if ctx.approve else ""))


def remove_one(ctx: Context, state: dict[str, Any], name: str, installed: set[str]) -> None:
    dest = package_dir() / name
    record = state["packages"].get(name)
    src_digest = tree_digest(ctx.source / name)
    owned, problem = ownership(state, name, dest, src_digest)
    if not dest.exists() and record is None:
        print(f"[ok]  muse: {name} is not installed by ycc; nothing to remove")
        return
    if (not owned or problem) and not ctx.force:
        reason = problem or f"{dest} was not placed by ycc"
        print(f"[!!]  muse: kept {name}: {reason} (re-run with --force to remove it)")
        return
    if name in installed or ctx.dry_run:
        ctx.run_muse("remove", name, allow_codes=("unknown-plugin",))
    if ctx.dry_run:
        if dest.exists():
            print(f"[dry-run] would remove {dest}")
        return
    if dest.exists():
        remove_tree(dest)
    state["packages"].pop(name, None)
    print(f"[ok]  muse: removed {name}")


def parse_packages(value: str | None) -> tuple[str, ...]:
    if not value:
        return PACKAGES
    names = tuple(dict.fromkeys(part.strip() for part in value.split(",") if part.strip()))
    unknown = [name for name in names if name not in PACKAGES]
    if unknown:
        raise SystemExit(f"muse: unknown package(s) {', '.join(unknown)} (known: {', '.join(PACKAGES)})")
    return names


def run(action: str, ctx: Context, names: Sequence[str]) -> int:
    state = load_state()
    print(f"muse: {action} via {ctx.muse} (owned copies in {package_dir()})")
    try:
        installed = ctx.installed()
    except RuntimeError as exc:
        print(f"[err] muse: {exc}", file=sys.stderr)
        return 1
    failed = 0
    for name in names:
        try:
            (install_one if action == "install" else remove_one)(ctx, state, name, installed)
        except RuntimeError as exc:
            print(f"[err] muse: {exc}", file=sys.stderr)
            failed += 1
    if not ctx.dry_run and (state["packages"] or state_path().exists()):
        save_state(state)
    return 1 if failed else 0


def status() -> int:
    state = load_state()
    rows = {}
    for name in PACKAGES:
        dest = package_dir() / name
        record = state["packages"].get(name)
        rows[name] = {
            "path": str(dest),
            "present": dest.is_dir(),
            "owned": record is not None,
            "edited": bool(record and record.get("digest") != tree_digest(dest)),
        }
    print(json.dumps(rows, indent=2))
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    for action in ("install", "remove"):
        cmd = sub.add_parser(action)
        cmd.add_argument("--packages", help=f"comma-separated subset of {', '.join(PACKAGES)} (default: all)")
        cmd.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
        cmd.add_argument("--dry-run", action="store_true")
        cmd.add_argument("--force", action="store_true")
        if action == "install":
            cmd.add_argument("--no-approve", action="store_true", help="leave agents and MCP servers in Muse review")
            cmd.add_argument("--scope", choices=("user", "project"), default="user", help="muse plugins install scope")
    sub.add_parser("status")
    sub.add_parser("available")
    args = parser.parse_args(argv)
    if args.action == "status":
        return status()
    muse = resolve_muse()
    if args.action == "available":
        print(muse or "muse not on PATH")
        return 0 if muse else 1
    if not muse:
        if args.dry_run:
            muse = "muse"
        else:
            print("[err] muse: the muse CLI is not on PATH (install Muse Code, or set YCC_MUSE_BIN)", file=sys.stderr)
            return 1
    approve = action_approve(args)
    scope = getattr(args, "scope", "user")
    ctx = Context(source=args.source, dry_run=args.dry_run, force=args.force, approve=approve, muse=muse, scope=scope)
    return run(args.action, ctx, parse_packages(args.packages))


def action_approve(args: argparse.Namespace) -> bool:
    if args.action != "install" or getattr(args, "no_approve", False):
        return False
    return os.environ.get("YCC_MUSE_APPROVE", "1") != "0"


if __name__ == "__main__":
    sys.exit(main())
