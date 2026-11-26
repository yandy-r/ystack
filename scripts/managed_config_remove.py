"""Per-format removal and the ``--remove`` run for merge_managed_config.py."""

from __future__ import annotations

import argparse
import copy
import json
import os
import sys
import tomllib
from pathlib import Path
from typing import Any

from managed_config_core import (
    ADDED_ITEMS_KEY,
    MergeError,
    delete_nested,
    parse_pointer,
    pointer,
    read_nested,
    value_hash,
    write_nested,
)
from managed_config_formats import (
    check_cursor_hooks_ownership,
    load_json_config,
    load_yaml_config,
    load_yaml_destination,
    render_yaml,
    validate_cursor_hooks_destination,
)
from managed_config_hooks import prune_event
from managed_config_io import atomic_write, backup_before_rewrite, drop_ycc_only_backups, write_state
from managed_config_remove_plan import plan_remove
from managed_config_toml import TOML_TABLE_RE, apply_toml_updates, delete_toml_entries

# Rendered text (None: unchanged), changed paths, conflicts, spent state keys,
# owned-item hashes left per list pointer, and retention notes.
RemoveOutcome = tuple[str | None, list[list[str]], list[str], list[str], dict[str, list[str]], list[str]]


def remove_json(
    source: dict[str, Any],
    destination_path: Path,
    profile: dict[str, Any],
    groups: list[str],
    state_entry: dict[str, Any],
    force: bool,
    owned_only: bool = False,
) -> RemoveOutcome:
    if not destination_path.exists():
        return None, [], [], [], {}, []
    raw = destination_path.read_text(encoding="utf-8").strip()
    destination = load_json_config(raw, destination_path, profile)
    if not isinstance(destination, dict):
        raise MergeError(f"{destination_path}: expected a JSON object at the root")
    if profile.get("strict_hooks"):
        validate_cursor_hooks_destination(destination)
        check_cursor_hooks_ownership(source, destination)

    to_remove, rewrites, conflicts, stale_keys, owned_after, notes = plan_remove(
        profile, groups, source, destination, state_entry, force, owned_only=owned_only
    )
    if profile.get("strict_hooks") and conflicts:
        raise MergeError(
            "Cursor sessionStart registration still references the hook script; "
            "refusing removal without ownership (resolve it or re-run with --force)"
        )
    if not to_remove and not rewrites:
        return None, [], conflicts, stale_keys, owned_after, notes

    pruned = json.loads(json.dumps(destination))
    for path in to_remove:
        delete_nested(pruned, path)
    for path, items in rewrites:
        write_nested(pruned, path, items)
    changed = to_remove + [path for path, _ in rewrites]
    rendered = json.dumps(pruned, indent=2, ensure_ascii=False) + "\n"
    return rendered, changed, conflicts, stale_keys, owned_after, notes


def remove_hook_commands(
    source: dict[str, Any],
    destination_path: Path,
    profile: dict[str, Any],
    groups: list[str],
    state_entry: dict[str, Any],
    force: bool,
) -> tuple[str | None, list[list[str]], list[str], list[str]]:
    """Prune exact source hook commands only with legacy event-hash proof.

    This opt-in path never calls the generic event-array removal planner.
    A removal retires the event proof; conflicts retain it only without changes.
    """
    if not destination_path.exists():
        return None, [], [], [key for key in state_entry if key.startswith("/hooks/")]
    destination = load_json_config(destination_path.read_text(encoding="utf-8"), destination_path, profile)
    if not isinstance(destination, dict):
        raise MergeError(f"{destination_path}: expected a JSON object at the root")
    hooks = destination.get("hooks", {})
    if not isinstance(hooks, dict):
        return None, [], ["/hooks"], []
    source_hooks = source.get("hooks", {})
    if not isinstance(source_hooks, dict):
        source_hooks = {}
    events = set(source_hooks)
    events.update(
        path[1]
        for key in state_entry
        if key.startswith("/") and len(path := parse_pointer(key)) == 2 and path[0] == "hooks"
    )
    kept_events = dict(hooks)
    changed: list[list[str]] = []
    conflicts: list[str] = []
    stale_keys: list[str] = []
    for event in sorted(events):
        path = ["hooks", event]
        key = pointer(path)
        if event not in hooks:
            if key in state_entry:
                stale_keys.append(key)
            continue
        ownership = state_entry.get(key)
        state_sha = ownership.get("last_applied_sha256") if isinstance(ownership, dict) else None
        result = prune_event(source_hooks.get(event), hooks[event], state_sha, value_hash)
        if not result.proven:
            conflicts.append(key)
            continue
        if result.uncertain:
            conflicts.append(key)
        if not result.removed:
            continue
        # Any actual removal spends the event's ownership proof, even with
        # uncertain leftovers (those need manual cleanup). Keeping it would let a
        # repeat run consume retained byte-identical user copies.
        if key in state_entry:
            stale_keys.append(key)
        changed.append(path)
        if not result.remaining:
            kept_events.pop(event)
        else:
            kept_events[event] = result.remaining
    if not changed:
        return None, [], conflicts, stale_keys
    if kept_events:
        destination["hooks"] = kept_events
    else:
        destination.pop("hooks", None)
    return json.dumps(destination, indent=2, ensure_ascii=False) + "\n", changed, conflicts, stale_keys


def remove_toml(
    source: dict[str, Any],
    destination_path: Path,
    profile: dict[str, Any],
    groups: list[str],
    state_entry: dict[str, Any],
    force: bool,
    owned_only: bool = False,
) -> RemoveOutcome:
    if not destination_path.exists():
        return None, [], [], [], {}, []
    destination_text = destination_path.read_text(encoding="utf-8")
    destination = tomllib.loads(destination_text)

    to_remove, rewrites, conflicts, stale_keys, owned_after, notes = plan_remove(
        profile, groups, source, destination, state_entry, force, owned_only=owned_only
    )
    if not to_remove and not rewrites:
        return None, [], conflicts, stale_keys, owned_after, notes

    rendered = delete_toml_entries(destination_text, to_remove)
    if rewrites:
        rendered = apply_toml_updates(rendered, list(rewrites))
    # Re-parse so a bad patch can never reach the user's config.
    reparsed = tomllib.loads(rendered)
    for path in to_remove:
        if read_nested(reparsed, path)[0]:
            raise MergeError(f"TOML remove verification failed for {pointer(path)}")
    for path, items in rewrites:
        if read_nested(reparsed, path) != (True, items):
            raise MergeError(f"TOML remove verification failed for {pointer(path)}")
    return rendered, to_remove + [path for path, _ in rewrites], conflicts, stale_keys, owned_after, notes


def remove_yaml(
    source: dict[str, Any],
    destination_path: Path,
    profile: dict[str, Any],
    groups: list[str],
    state_entry: dict[str, Any],
    force: bool,
    owned_only: bool = False,
) -> RemoveOutcome:
    if not destination_path.exists():
        return None, [], [], [], {}, []
    destination = load_yaml_destination(destination_path)
    to_remove, rewrites, conflicts, stale_keys, owned_after, notes = plan_remove(
        profile, groups, source, destination, state_entry, force, owned_only=owned_only
    )
    if not to_remove and not rewrites:
        return None, [], conflicts, stale_keys, owned_after, notes

    pruned = copy.deepcopy(destination)
    for path in to_remove:
        delete_nested(pruned, path)
    for path, items in rewrites:
        write_nested(pruned, path, items)
    changed = to_remove + [path for path, _ in rewrites]
    return render_yaml(pruned, destination_path), changed, conflicts, stale_keys, owned_after, notes


def is_empty_config(value: Any) -> bool:
    """True for a dict containing nothing but (recursively) empty dicts."""
    return isinstance(value, dict) and all(is_empty_config(child) for child in value.values())


def rendered_is_empty(profile: dict[str, Any], rendered: str) -> bool:
    """Whether a post-removal file holds nothing worth keeping on disk.

    Empty ``keep_empty`` lists are tool scaffolding, not content.
    """
    if profile["format"] == "json":
        data = json.loads(rendered)
        for rules in profile["groups"].values():
            for rule in rules:
                if rule.get("keep_empty") and read_nested(data, rule["path"]) == (True, []):
                    delete_nested(data, rule["path"])
        return isinstance(data, dict) and not data
    if profile["format"] == "yaml":
        return not load_yaml_config(rendered, "rendered config")
    # Only bare (now empty) table headers may remain; comments are user content.
    only_headers = all(not line.strip() or TOML_TABLE_RE.match(line) for line in rendered.splitlines())
    return only_headers and is_empty_config(tomllib.loads(rendered))


def run_remove(
    args: argparse.Namespace,
    profile: dict[str, Any],
    groups: list[str],
    source: dict[str, Any],
    destination_path: Path,
    state: dict[str, Any],
    state_key: str,
    state_entry: dict[str, Any],
    plan_state: dict[str, Any],
    state_path: Path,
) -> int:
    """Remove tool-owned managed entries; user-edited entries need --force."""
    label = f"({args.profile}: {', '.join(groups)})"

    try:
        if args.prune_hook_commands:
            rendered, removed, conflicts, stale_keys = remove_hook_commands(
                source, destination_path, profile, groups, plan_state, args.force
            )
            owned_after: dict[str, list[str]] = {}
            notes: list[str] = []
        else:
            removers = {"json": remove_json, "toml": remove_toml, "yaml": remove_yaml}
            remove = removers[profile["format"]]
            rendered, removed, conflicts, stale_keys, owned_after, notes = remove(
                source, destination_path, profile, groups, plan_state, args.force, owned_only=args.owned_only
            )
    except (MergeError, json.JSONDecodeError, tomllib.TOMLDecodeError) as error:
        print(f"merge_managed_config: {error}", file=sys.stderr)
        return 1

    for conflict in conflicts:
        if args.prune_hook_commands:
            print(f"  [!!] kept uncertain or locally modified hook commands at {conflict} (edit by hand to remove)")
        else:
            print(f"  [!!] kept your local value at {conflict} (re-run with --force to remove it)")
    for note in notes:
        print(f"  [ok] kept {note}")

    if args.dry_run:
        for path in removed:
            print(f"  would remove {pointer(path)}")
        if rendered is not None and rendered_is_empty(profile, rendered):
            print(f"  would remove {destination_path}")
        return 0

    for key in stale_keys:
        state_entry.pop(key, None)
    # A selective list removal keeps ownership of the items it left in place.
    owned_changed = False
    for key, owned in owned_after.items():
        ownership = state_entry.get(key)
        if isinstance(ownership, dict) and ownership.get(ADDED_ITEMS_KEY) != owned:
            state_entry[key] = {**ownership, ADDED_ITEMS_KEY: owned}
            owned_changed = True
    if state_entry:
        state[state_key] = state_entry
    else:
        state.pop(state_key, None)

    if rendered is None:
        if stale_keys or owned_changed:
            write_state(state_path, state)
        print(f"  [ok] nothing to remove: {destination_path} {label}")
        return 0

    original_bytes = destination_path.read_bytes()
    original_mode = destination_path.stat().st_mode & 0o777
    original_link = os.readlink(destination_path) if destination_path.is_symlink() else None
    empty = rendered_is_empty(profile, rendered)
    backup_before_rewrite(profile, destination_path)
    if empty:
        destination_path.unlink()
    else:
        atomic_write(destination_path, rendered)
    try:
        write_state(state_path, state)
    except BaseException:
        destination_path.unlink(missing_ok=True)
        if original_link is not None:
            destination_path.symlink_to(original_link)
        else:
            destination_path.write_bytes(original_bytes)
            destination_path.chmod(original_mode)
        raise

    noun = "entry" if len(removed) == 1 else "entries"
    print(f"  [ok] removed {len(removed)} managed {noun} from {destination_path} {label}")
    if empty:
        print(f"  [ok] removed empty file {destination_path}")
        drop_ycc_only_backups(profile, destination_path)
    return 0
