#!/usr/bin/env python3
"""
Merge repo-managed configuration keys into a user's runtime config file.

The installer historically COPIED whole config files into ``~/.claude``,
``~/.codex``, ``~/.config/opencode`` and friends, which forced a choice between
clobbering per-machine edits (``--force``) and refusing to install at all. This
helper replaces that with an additive merge: only the keys this repo declares as
*managed* are written, and every other key in the destination is preserved
byte-for-byte where the format allows.

Ownership tracking
------------------
Each managed leaf records the SHA-256 of the value this tool last applied, in
``~/.config/ycc/managed-config-state.json``. On a later run:

* destination leaf missing            → write the repo value
* destination matches last-applied    → repo value wins (user never touched it)
* destination differs from last-applied → user edit wins, warn, skip
* no recorded state and values differ → user value wins, warn, skip

``--force`` makes the repo value win in every case. State stores hashes only,
never values, so tokens in a user's config never leak into the state file.

``--has-state`` answers whether that state holds anything for
``<profile>[scope]:<destination>`` (exit 0 yes, 1 no) without reading the source
or the destination; installers pass ``--source /dev/null``.

Project scope
-------------
``claude-settings``, ``codex-config`` and ``opencode-config`` carry a
``settings-project`` group: a fail-closed allowlist of their ``settings`` rules
for project files (``.claude/settings.json``, ``.codex/config.toml``,
``opencode.json``). Import fails when the allowlist names a path the
``settings`` group lacks, or a key Codex ignores in project config.

Formats
-------
JSON destinations are parsed, merged and re-serialized. TOML destinations are
patched textually (validated with ``tomllib`` before and after) so comments,
ordering, quoting and unmanaged tables survive — Python ships no TOML writer.
YAML destinations (OMP ``config.yml``) are parsed and re-serialized with the
YAML 1.2 core schema OMP (Bun) uses, then re-parsed before the write.
Re-serializing drops comments and formatting. Before a rewrite that would lose
any (the file is not already ycc's own rendering), the original is saved to
``<dest>.ycc-backup`` (mode 0600), or to the first free ``<dest>.ycc-backup.N``
when an older backup holds different bytes; a backup is never overwritten and
every such rewrite warns. Documents with aliases are refused, since a rewrite
would expand them. PyYAML is imported lazily, only for YAML profiles.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
import tomllib
from pathlib import Path
from typing import Any

from managed_config_core import ADDED_ITEMS_KEY, MergeError, collect_managed_leaves, parse_pointer, pointer, value_hash
from managed_config_entries import (
    available_entries,
    expand_leaf_rules,
    narrow_profile,
    select_source_entries,
    selected_state,
)
from managed_config_formats import load_json_config, load_source, strip_jsonc, validate_cursor_hooks_source
from managed_config_io import (
    atomic_write,
    backup_before_rewrite,
    has_state,
    read_state,
    remove_owns_nothing,
    write_state,
    ycc_backups,
)
from managed_config_merge import adopt_matching_values, merge_json, merge_toml, merge_yaml
from managed_config_profiles import (
    PROFILES,
    PROJECT_GROUP,
    PROJECT_IGNORED_KEYS,
    check_project_ignored_keys,
    project_subset,
)
from managed_config_remove import remove_hook_commands, remove_json, run_remove
from managed_config_toml import delete_toml_entries

# Re-exported for importers (install_migrate.py, codex_install.py, opencode_package.py, ...).
__all__ = [
    "ADDED_ITEMS_KEY",
    "PROFILES",
    "PROJECT_GROUP",
    "PROJECT_IGNORED_KEYS",
    "STATE_PATH",
    "atomic_write",
    "check_project_ignored_keys",
    "delete_toml_entries",
    "load_json_config",
    "load_source",
    "load_state",
    "main",
    "MergeError",
    "parse_pointer",
    "project_subset",
    "remove_hook_commands",
    "remove_json",
    "save_state",
    "strip_jsonc",
    "value_hash",
    "ycc_backups",
]

REPO_ROOT = Path(__file__).resolve().parent.parent

STATE_PATH = Path(
    os.environ.get("YCC_MANAGED_CONFIG_STATE")
    or (Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "ycc" / "managed-config-state.json")
)


def load_state() -> dict[str, Any]:
    """Read the ownership state at ``STATE_PATH`` (``{}`` when missing or corrupt)."""
    return read_state(STATE_PATH)


def save_state(state: dict[str, Any]) -> None:
    """Write the ownership state to ``STATE_PATH`` atomically."""
    write_state(STATE_PATH, state)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, choices=sorted(PROFILES), help="Managed-key profile to apply")
    parser.add_argument("--source", type=Path, help="Repo-managed config file (required unless --has-state)")
    parser.add_argument("--destination", required=True, type=Path, help="User config file to merge into")
    parser.add_argument("--groups", help="Comma-separated managed key groups (required unless --has-state)")
    parser.add_argument("--force", action="store_true", help="Let repo values win over conflicting local edits")
    parser.add_argument("--dry-run", action="store_true", help="Report the merge without writing anything")
    parser.add_argument("--remove", action="store_true", help="Remove managed entries instead of merging them")
    parser.add_argument(
        "--prune-hook-commands",
        action="store_true",
        help="With --remove and claude-settings hooks only, prune proven exact managed hook commands",
    )
    parser.add_argument(
        "--entries",
        help="Comma-separated entry names (e.g. MCP servers) to restrict the run to; other entries are left alone",
    )
    parser.add_argument(
        "--entry-groups",
        help="Comma-separated subset of --groups that --entries and --list-entries apply to (default: all --groups)",
    )
    parser.add_argument(
        "--list-entries",
        action="store_true",
        help="Print the entry names the source manages for the entry groups, one per line, and exit",
    )
    parser.add_argument(
        "--owned-only",
        action="store_true",
        help=(
            "Trust recorded ownership only: --remove never deletes an equal-value key it did not write, "
            "and a sync adopts nothing (project files are committed by the team; matching values prove nothing)"
        ),
    )
    parser.add_argument(
        "--state-scope",
        help="Keep ownership state under '<profile>[NAME]:<destination>' (one scope per opt-in plugin)",
    )
    parser.add_argument(
        "--has-state",
        action="store_true",
        help=(
            "Exit 0 when ownership state exists for '<profile>[scope]:<destination>' (only under --groups rules "
            "when given), else 1; reads nothing else and writes nothing"
        ),
    )
    args = parser.parse_args()

    if args.state_scope is not None and not re.fullmatch(r"[A-Za-z0-9@/._-]+", args.state_scope):
        print(f"merge_managed_config: invalid --state-scope {args.state_scope!r}", file=sys.stderr)
        # --has-state reserves 1 for "no state"; a usage error must not read as one.
        return 2 if args.has_state else 1
    profile = PROFILES[args.profile]
    if args.has_state:
        # Answered from the state file alone: --source (e.g. /dev/null) is never read.
        state_groups = [g.strip() for g in (args.groups or "").split(",") if g.strip()] or None
        try:
            found = has_state(
                args.profile,
                profile,
                args.destination.expanduser(),
                args.state_scope,
                state_groups,
                STATE_PATH,
            )
        except MergeError as error:
            print(f"merge_managed_config: {error}", file=sys.stderr)
            return 2
        except (OSError, UnicodeDecodeError) as error:
            # An unreadable or undecodable state file is not "no state" (exit
            # 1); callers must not treat it as a fresh install.
            print(f"merge_managed_config: cannot read state: {error}", file=sys.stderr)
            return 2
        return 0 if found else 1
    if args.source is None or args.groups is None:
        parser.error("--source and --groups are required (unless --has-state)")

    groups = [group.strip() for group in args.groups.split(",") if group.strip()]
    if not groups:
        print("merge_managed_config: --groups requires at least one group", file=sys.stderr)
        return 1
    entry_groups = groups
    if args.entry_groups is not None:
        entry_groups = [group.strip() for group in args.entry_groups.split(",") if group.strip()]
        outside = [group for group in entry_groups if group not in groups]
        if not entry_groups or outside:
            print(
                f"merge_managed_config: --entry-groups {', '.join(outside) or '(none given)'} "
                f"must name groups from --groups ({', '.join(groups)})",
                file=sys.stderr,
            )
            return 1
    if args.prune_hook_commands and (
        not args.remove or args.profile != "claude-settings" or groups != ["hooks"] or args.force or args.list_entries
    ):
        print(
            "merge_managed_config: --prune-hook-commands requires --remove --profile claude-settings "
            "--groups hooks and cannot be combined with --force or --list-entries",
            file=sys.stderr,
        )
        return 1

    source_path = args.source if args.source.is_absolute() else (REPO_ROOT / args.source)
    destination_path = args.destination.expanduser()

    if not source_path.is_file():
        print(f"merge_managed_config: source not found: {source_path}", file=sys.stderr)
        return 1
    # A removal that owns nothing (no source leaves, no recorded state under the
    # selected rules) never reads or touches the destination, so a symlinked or
    # unparseable config the tool never wrote cannot fail it.
    if (
        args.remove
        and not args.prune_hook_commands
        and not args.list_entries
        and args.entries is None
        and remove_owns_nothing(args.profile, profile, groups, source_path, destination_path, STATE_PATH)
    ):
        print(f"  [ok] nothing to remove: {destination_path} ({args.profile}: {', '.join(groups)})")
        return 0
    # Cursor hooks also refuse symlinked parents. OMP refuses only a symlinked
    # config file (atomic_write would replace the link); a symlinked agent dir
    # or home (/home -> /var/home) is written through normally.
    if (profile.get("strict_hooks") and any(p.is_symlink() for p in destination_path.parents)) or (
        (profile.get("strict_hooks") or profile.get("refuse_symlink")) and destination_path.is_symlink()
    ):
        if profile.get("strict_hooks"):
            print("merge_managed_config: refusing symlinked Cursor hooks destination", file=sys.stderr)
        else:
            snippet = source_path.read_text(encoding="utf-8")
            print(
                f"merge_managed_config: refusing to write through symlinked {destination_path}; "
                f"add these keys yourself:\n{snippet}",
                file=sys.stderr,
            )
        return 1
    try:
        source = load_source(source_path, profile)
        if profile.get("strict_hooks"):
            validate_cursor_hooks_source(source)
            expected = 'bash "${CURSOR_PLUGIN_ROOT}/hooks/herdr-session-start.sh" session'
            if source["hooks"]["sessionStart"][0]["command"] != expected:
                raise MergeError("Cursor hooks source must use the canonical herdr sessionStart command")
            hook_script = Path.home() / ".cursor/hooks/herdr-session-start.sh"
            source["hooks"]["sessionStart"][0]["command"] = f"bash {shlex.quote(str(hook_script))} session"
    except (MergeError, json.JSONDecodeError, tomllib.TOMLDecodeError) as error:
        print(f"merge_managed_config: {error}", file=sys.stderr)
        return 1

    managed_entries = available_entries(profile, entry_groups, source)
    if args.list_entries:
        for name in managed_entries:
            print(name)
        return 0
    entries: list[str] | None = None
    if args.entries is not None:
        entries = [name.strip() for name in args.entries.split(",") if name.strip()]
        unknown = [name for name in entries if name not in managed_entries]
        if not entries or unknown:
            print(
                f"merge_managed_config: unknown entries {', '.join(unknown) or '(none given)'} "
                f"(managed: {', '.join(managed_entries) or 'none'})",
                file=sys.stderr,
            )
            return 1
        # Every planner below reads the selection from the narrowed rules.
        profile = narrow_profile(profile, entry_groups, entries)
        source = select_source_entries(profile, groups, source)

    # Read a symlinked destination through its target but do not mutate it yet.
    # Validation, merge planning, and --dry-run must remain side-effect free.
    replaced_symlink = destination_path.is_symlink()

    state = load_state()
    scope = f"[{args.state_scope}]" if args.state_scope is not None else ""
    state_key = f"{args.profile}{scope}:{destination_path}"
    state_entry = state.get(state_key, {})
    if not isinstance(state_entry, dict):
        state_entry = {}
    profile = expand_leaf_rules(profile, source, [parse_pointer(key) for key in state_entry if key.startswith("/")])
    # Plan against the selected entries only; writes still go to the full entry.
    plan_state = state_entry if entries is None else selected_state(profile, groups, state_entry, parse_pointer)

    if args.remove:
        return run_remove(
            args, profile, groups, source, destination_path, state, state_key, state_entry, plan_state, STATE_PATH
        )

    mergers = {"json": merge_json, "toml": merge_toml, "yaml": merge_yaml}
    merge = mergers[profile["format"]]
    try:
        rendered, updates, conflicts, deletions, owned_lists = merge(
            source, destination_path, profile, groups, plan_state, args.force
        )
    except (MergeError, json.JSONDecodeError, tomllib.TOMLDecodeError) as error:
        print(f"merge_managed_config: {error}", file=sys.stderr)
        return 1

    for conflict in conflicts:
        print(f"  [!!] kept your local value at {conflict} (re-run with --force to take the repo value)")

    if rendered is None:
        if (
            not args.dry_run
            and destination_path.exists()
            and adopt_matching_values(
                profile, groups, source, destination_path, state_entry, owned_only=args.owned_only
            )
        ):
            state[state_key] = state_entry
            save_state(state)
        print(f"  [ok] up-to-date: {destination_path} ({args.profile}: {', '.join(groups)})")
        return 0

    if args.dry_run:
        for path, _ in updates:
            print(f"  would set {pointer(path)}")
        for path in deletions:
            print(f"  would remove {pointer(path)}")
        if replaced_symlink:
            print(f"  would replace symlink with a real file: {destination_path}")
        return 0

    # Prepare state before committing the config. If writing state fails after
    # the config rename, restore the original bytes (or remove the new file),
    # keeping config and ownership metadata consistent.
    managed_keys = {pointer(path) for path, _ in collect_managed_leaves(profile, groups, source)}
    for path, value in updates:
        key = pointer(path)
        if key not in managed_keys:
            # Migration rewrites of user-owned extras (e.g. env_vars) stay user-owned.
            continue
        ownership: dict[str, Any] = {"last_applied_sha256": value_hash(value)}
        if key in owned_lists:
            ownership[ADDED_ITEMS_KEY] = owned_lists[key]
        state_entry[key] = ownership
    for path in deletions:
        state_entry.pop(pointer(path), None)
    state[state_key] = state_entry

    original_bytes = destination_path.read_bytes() if destination_path.exists() else None
    original_mode = destination_path.stat().st_mode & 0o777 if destination_path.exists() else None
    original_link = os.readlink(destination_path) if replaced_symlink else None

    # Only now, after parsing and planning have succeeded, does anything on
    # disk change. atomic_write replaces the symlink itself via rename.
    backup_before_rewrite(profile, destination_path)
    atomic_write(destination_path, rendered)
    try:
        save_state(state)
    except BaseException:
        destination_path.unlink(missing_ok=True)
        if original_link is not None:
            destination_path.symlink_to(original_link)
        elif original_bytes is not None:
            destination_path.write_bytes(original_bytes)
            if original_mode is not None:
                destination_path.chmod(original_mode)
        raise

    if replaced_symlink:
        print(f"  [!!] replaced symlink with a real file: {destination_path}")

    print(
        f"  [ok] applied {len(updates)} managed update(s) and {len(deletions)} removal(s) "
        f"to {destination_path} ({args.profile}: {', '.join(groups)})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
