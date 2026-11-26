"""Merge planning and per-format merges for merge_managed_config.py."""

from __future__ import annotations

import copy
import json
import tomllib
from pathlib import Path
from typing import Any

from managed_config_core import (
    ADDED_ITEMS_KEY,
    MergeError,
    collect_managed_leaves,
    delete_nested,
    parse_pointer,
    pointer,
    policy_for,
    read_nested,
    rule_for,
    union_lists,
    value_hash,
    write_nested,
)
from managed_config_entries import plan_keyed_list, selection
from managed_config_formats import (
    check_cursor_hooks_ownership,
    load_json_config,
    load_yaml_config,
    load_yaml_destination,
    render_yaml,
    validate_cursor_hooks_destination,
)
from managed_config_legacy import plan_legacy_migration
from managed_config_toml import apply_toml_updates, repair_duplicate_managed_toml, split_inline_deletions


def adopt_matching_values(
    profile: dict[str, Any],
    groups: list[str],
    source: dict[str, Any],
    destination_path: Path,
    state_entry: dict[str, Any],
    owned_only: bool = False,
) -> bool:
    """Record source values already present in the destination as tool-owned.

    First-run configs often already equal the repo. Recording that equality is
    essential: otherwise a future repo update looks like a local edit and is
    conservatively skipped forever. With ``owned_only`` (project scope, where
    the destination is usually committed and written by the team), equal
    values are NOT adopted: recording them as owned would let a later remove
    delete keys this tool never wrote.
    """
    if owned_only:
        return False
    raw = destination_path.read_text(encoding="utf-8")
    if profile["format"] == "json":
        destination = load_json_config(raw, destination_path, profile)
    elif profile["format"] == "yaml":
        destination = load_yaml_config(raw, destination_path)
    else:
        destination = tomllib.loads(raw)

    changed = False
    for path, source_value in collect_managed_leaves(profile, groups, source):
        if policy_for(profile, groups, path) == "list-union":
            continue
        found, current_value = read_nested(destination, path)
        if found and current_value == source_value:
            key = pointer(path)
            wanted = {"last_applied_sha256": value_hash(source_value)}
            if state_entry.get(key) != wanted:
                state_entry[key] = wanted
                changed = True
    return changed


def plan_merge(
    profile: dict[str, Any],
    groups: list[str],
    source: dict[str, Any],
    destination: dict[str, Any],
    state_entry: dict[str, Any],
    force: bool,
) -> tuple[list[tuple[list[str], Any]], list[str], list[list[str]], dict[str, list[str]]]:
    """Decide, per managed leaf, whether the repo value may be applied.

    Returns updates, conflicts, stale managed leaves to delete, and the complete
    owned-item hash list per updated list-union pointer.
    """
    updates: list[tuple[list[str], Any]] = []
    conflicts: list[str] = []
    managed_now: set[str] = set()
    owned_lists: dict[str, list[str]] = {}

    for path, source_value in collect_managed_leaves(profile, groups, source):
        managed_now.add(pointer(path))
        found, current_value = read_nested(destination, path)
        key = pointer(path)

        rule = rule_for(profile, groups, path)
        if rule is not None and rule["policy"] == "list-union":
            current_list = current_value if found and isinstance(current_value, list) else []
            source_items = source_value if isinstance(source_value, list) else [source_value]
            previous = list(state_entry.get(key, {}).get(ADDED_ITEMS_KEY, []))
            if rule.get("item_key"):
                merged, owned, keyed_conflicts = plan_keyed_list(
                    rule, current_list, source_items, previous, force, value_hash
                )
                conflicts.extend(f"{key}[{item}]" for item in keyed_conflicts)
            else:
                kept = current_list
                if rule.get("prune_owned"):
                    # Take back recorded items the source dropped; user items stay,
                    # and items taken back are no longer owned.
                    kept = [item for item in current_list if item in source_items or value_hash(item) not in previous]
                    kept_hashes = {value_hash(item) for item in kept}
                    previous = [digest for digest in previous if digest in kept_hashes]
                merged = union_lists(kept, source_items)
                added = [value_hash(item) for item in merged if item not in current_list]
                owned = sorted({*previous, *added})
            # A missing destination path still needs the key written, even when
            # the merged list is empty (Cursor requires permissions.allow/deny).
            if merged != current_list or not found:
                updates.append((path, merged))
                owned_lists[key] = owned
            continue

        if not found:
            updates.append((path, source_value))
            continue
        if current_value == source_value:
            continue
        if force:
            updates.append((path, source_value))
            continue

        last_applied = state_entry.get(key, {}).get("last_applied_sha256")
        if last_applied is not None and last_applied == value_hash(current_value):
            # Destination still holds exactly what this tool wrote, so the repo
            # owns it and may update it.
            updates.append((path, source_value))
            continue

        conflicts.append(key)

    deletions: list[list[str]] = []
    for key, ownership in state_entry.items():
        if key in managed_now or not key.startswith("/"):
            continue
        path = parse_pointer(key)
        # Delete only keys inside a selected managed rule and only when the
        # current value still matches what this tool last wrote. User edits and
        # never-managed siblings survive.
        rule = rule_for(profile, groups, path)
        if rule is None:
            continue
        if rule["policy"] == "list-union" and selection(rule) is not None:
            # A selection that leaves a list out says nothing about the list.
            continue
        found, current_value = read_nested(destination, path)
        last_applied = ownership.get("last_applied_sha256") if isinstance(ownership, dict) else None
        if found and last_applied == value_hash(current_value):
            deletions.append(path)

    # Narrow migration: a recognized legacy GitHub MCP entry (this repo's old
    # npm/remote defaults) is repo history, not a user edit, so the native
    # stdio entry wins and its incompatible connection/auth fields are removed.
    migration_updates, migration_deletions, preserved = plan_legacy_migration(
        profile, groups, source, destination, force
    )
    planned = {pointer(path) for path, _ in updates}
    removed = {pointer(path) for path in deletions}
    for path, value in migration_updates:
        key = pointer(path)
        if key not in planned:
            updates.append((path, value))
            planned.add(key)
        if key in conflicts:
            conflicts.remove(key)
    for path in migration_deletions:
        key = pointer(path)
        if key not in removed:
            deletions.append(path)
            removed.add(key)
    # A custom GitHub connection is left wholly untouched (without --force).
    updates = [(p, v) for p, v in updates if not any(p[: len(b)] == b for b in preserved)]
    deletions = [p for p in deletions if not any(p[: len(b)] == b for b in preserved)]

    return updates, conflicts, deletions, owned_lists


def merge_json(
    source: dict[str, Any],
    destination_path: Path,
    profile: dict[str, Any],
    groups: list[str],
    state_entry: dict[str, Any],
    force: bool,
) -> tuple[str | None, list[tuple[list[str], Any]], list[str], list[list[str]], dict[str, list[str]]]:

    if destination_path.exists():
        raw = destination_path.read_text(encoding="utf-8").strip()
        destination = load_json_config(raw, destination_path, profile)
        if not isinstance(destination, dict):
            raise MergeError(f"{destination_path}: expected a JSON object at the root")
        if profile.get("strict_hooks"):
            validate_cursor_hooks_destination(destination)
    else:
        destination = {}
    if profile.get("strict_hooks"):
        check_cursor_hooks_ownership(source, destination)

    updates, conflicts, deletions, additions = plan_merge(profile, groups, source, destination, state_entry, force)
    if not updates and not deletions:
        return None, updates, conflicts, deletions, additions

    merged = json.loads(json.dumps(destination))
    if profile.get("strict_hooks"):
        merged.setdefault("version", 1)
    for path, value in updates:
        write_nested(merged, path, value)
    for path in deletions:
        delete_nested(merged, path)
    return json.dumps(merged, indent=2, ensure_ascii=False) + "\n", updates, conflicts, deletions, additions


def merge_toml(
    source: dict[str, Any],
    destination_path: Path,
    profile: dict[str, Any],
    groups: list[str],
    state_entry: dict[str, Any],
    force: bool,
) -> tuple[str | None, list[tuple[list[str], Any]], list[str], list[list[str]], dict[str, list[str]]]:

    if destination_path.exists():
        destination_text = destination_path.read_text(encoding="utf-8")
        try:
            destination = tomllib.loads(destination_text)
        except tomllib.TOMLDecodeError:
            if not force:
                raise
            managed_paths = [path for path, _ in collect_managed_leaves(profile, groups, source)]
            destination_text = repair_duplicate_managed_toml(destination_text, managed_paths)
            destination = tomllib.loads(destination_text)
    else:
        destination_text = ""
        destination = {}

    updates, conflicts, deletions, additions = plan_merge(profile, groups, source, destination, state_entry, force)
    if not updates and not deletions:
        return None, updates, conflicts, deletions, additions

    plain_deletions, inline_rewrites = split_inline_deletions(destination_text, deletions, destination)
    merged_text = apply_toml_updates(destination_text, [*updates, *inline_rewrites], plain_deletions)

    # Re-parse so a bad patch can never reach the user's config.
    reparsed = tomllib.loads(merged_text)
    for path, value in updates:
        found, actual = read_nested(reparsed, path)
        if not found or actual != value:
            raise MergeError(f"TOML merge verification failed for {pointer(path)}")
    for path in deletions:
        if read_nested(reparsed, path)[0]:
            raise MergeError(f"TOML cannot remove {pointer(path)} (inline table?); edit it by hand")

    return merged_text, updates, conflicts, deletions, additions


def merge_yaml(
    source: dict[str, Any],
    destination_path: Path,
    profile: dict[str, Any],
    groups: list[str],
    state_entry: dict[str, Any],
    force: bool,
) -> tuple[str | None, list[tuple[list[str], Any]], list[str], list[list[str]], dict[str, list[str]]]:
    destination = load_yaml_destination(destination_path)
    updates, conflicts, deletions, additions = plan_merge(profile, groups, source, destination, state_entry, force)
    if not updates and not deletions:
        return None, updates, conflicts, deletions, additions

    merged = copy.deepcopy(destination)
    for path, value in updates:
        write_nested(merged, path, value)
    for path in deletions:
        delete_nested(merged, path)
    return render_yaml(merged, destination_path), updates, conflicts, deletions, additions
