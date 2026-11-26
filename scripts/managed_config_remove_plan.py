"""Remove planning for merge_managed_config.py: which owned entries and list items may be taken back."""

from __future__ import annotations

from typing import Any

from managed_config_core import (
    ADDED_ITEMS_KEY,
    entry_policy_rules,
    flatten_leaves,
    parse_pointer,
    pointer,
    read_nested,
    value_hash,
)
from managed_config_entries import is_derived, plan_keyed_list_removal, retained_marketplaces


class ListRemovalPlan:
    """List-union removal result: rewrites, deletes, conflicts, ownership and notes."""

    def __init__(self) -> None:
        self.rewrites: list[tuple[list[str], list[Any]]] = []
        self.deletes: list[list[str]] = []
        self.conflicts: list[str] = []
        self.spent: list[str] = []
        # Owned-item hashes that remain per list pointer whose state survives.
        self.owned_after: dict[str, list[str]] = {}
        self.notes: list[str] = []


def plan_list_removals(
    rules: list[dict[str, Any]],
    source: dict[str, Any],
    destination: dict[str, Any],
    state_entry: dict[str, Any],
    force: bool,
    retained: dict[str, str],
) -> ListRemovalPlan:
    """Take back list-union items this tool appended.

    Items are owned when their hash was recorded at merge time; ``force`` also
    takes every item that equals a repo value (keyed rules: shares a repo
    item's key). Keyed rules honor their selection and, when derived, keep
    items whose key is in ``retained``. A list left empty is deleted unless
    its rule says ``keep_empty``.
    """
    plan = ListRemovalPlan()
    for rule in rules:
        path = rule["path"]
        key = pointer(path)
        found, current = read_nested(destination, path)
        if not found or not isinstance(current, list):
            if key in state_entry:
                plan.spent.append(key)
            continue
        _, source_value = read_nested(source, path)
        source_items = source_value if isinstance(source_value, list) else []
        owned = list(state_entry.get(key, {}).get(ADDED_ITEMS_KEY, []))
        if rule.get("item_key"):
            kept, owned_left, keyed_conflicts, kept_notes = plan_keyed_list_removal(
                rule, current, source_items, owned, force, retained if is_derived(rule) else {}, value_hash
            )
            plan.conflicts.extend(key if item is None else f"{key}[{item}]" for item in keyed_conflicts)
            plan.notes.extend(f"{key}[{name}] (still used by {user})" for name, user in kept_notes)
        else:
            owned_hashes = set(owned)
            kept = [
                item
                for item in current
                if value_hash(item) not in owned_hashes and not (force and item in source_items)
            ]
            owned_left = []
            if any(item in source_items for item in kept):
                plan.conflicts.append(key)
        if key in state_entry:
            if owned_left:
                plan.owned_after[key] = owned_left
            else:
                plan.spent.append(key)
        keep_key = bool(kept) or bool(rule.get("keep_empty"))
        # An empty list is dropped only when this tool emptied or seeded it.
        if kept == current and (keep_key or key not in state_entry):
            continue
        if keep_key:
            plan.rewrites.append((path, kept))
        else:
            plan.deletes.append(path)
    return plan


def plan_remove(
    profile: dict[str, Any],
    groups: list[str],
    source: dict[str, Any],
    destination: dict[str, Any],
    state_entry: dict[str, Any],
    force: bool,
    owned_only: bool = False,
) -> tuple[list[list[str]], list[tuple[list[str], list[Any]]], list[str], list[str], dict[str, list[str]], list[str]]:
    """Decide which managed entries can be deleted from the destination.

    Returns entry paths to delete, list-union rewrites, conflicts, the state
    keys that no longer track anything, the owned-item hashes left per list
    pointer, and notes for marketplaces kept because a plugin still uses them.
    With ``owned_only``, only entries recorded in ``state_entry`` count as
    owned — an equal repo value alone never does (project files are usually
    committed by the team, so matching values prove nothing there).
    """
    rules = entry_policy_rules(profile, groups)
    list_rules = [rule for rule in rules if rule["policy"] == "list-union"]
    managed = [rule for rule in rules if rule["policy"] != "list-union"]

    candidates: dict[tuple[str, ...], dict[str, Any]] = {}
    for rule in managed:
        found, value = read_nested(source, rule["path"])
        if not found:
            continue
        if rule["policy"] == "scalar":
            candidates[tuple(rule["path"])] = {
                "path": list(rule["path"]),
                "source_value": value,
                "policy": rule["policy"],
                "derived": False,
                "owned_only": owned_only or bool(rule.get("owned_only")),
            }
        elif isinstance(value, dict) and value:
            for child_key, child_value in value.items():
                entry = [*rule["path"], child_key]
                candidates[tuple(entry)] = {
                    "path": entry,
                    "source_value": child_value,
                    "policy": rule["policy"],
                    "derived": is_derived(rule),
                    # --owned-only applies to children of object/deep rules
                    # too (the rule field only reaches scalar rules).
                    "owned_only": owned_only,
                }

    for key in state_entry:
        if not key.startswith("/"):
            continue
        path = parse_pointer(key)
        best: dict[str, Any] | None = None
        for rule in managed:
            if path[: len(rule["path"])] == rule["path"] and (best is None or len(rule["path"]) > len(best["path"])):
                best = rule
        if best is None:
            continue
        if len(path) <= len(best["path"]):
            entry = list(best["path"])
        else:
            entry = [*best["path"], path[len(best["path"])]]
        candidates.setdefault(
            tuple(entry),
            {"path": entry, "source_value": None, "policy": best["policy"], "derived": is_derived(best)},
        )

    to_remove: list[list[str]] = []
    conflicts: list[str] = []
    stale_keys: list[str] = []
    notes: list[str] = []
    # Primary entries first: whether a derived marketplace is still in use
    # depends on which plugins this run removes.
    ordered = sorted(candidates, key=lambda parts: (bool(candidates[parts]["derived"]), pointer(list(parts))))
    retained: dict[str, str] | None = None
    for entry_key in ordered:
        candidate = candidates[entry_key]
        entry_path = candidate["path"]
        if candidate["derived"] and retained is None:
            retained = retained_marketplaces(profile, groups, destination, {tuple(path) for path in to_remove})
        under = [
            key for key in state_entry if key.startswith("/") and parse_pointer(key)[: len(entry_path)] == entry_path
        ]
        found, dest_value = read_nested(destination, entry_path)
        if not found:
            stale_keys.extend(under)
            continue
        if candidate["derived"] and retained is not None and entry_path[-1] in retained:
            notes.append(f"{pointer(entry_path)} (still used by {retained[entry_path[-1]]})")
            continue
        source_value = candidate["source_value"]
        if source_value is not None and dest_value == source_value and not candidate.get("owned_only"):
            owned = True
        else:
            leaves = flatten_leaves(entry_path, dest_value, str(candidate["policy"]))
            owned = bool(leaves) and all(
                state_entry.get(pointer(leaf_path), {}).get("last_applied_sha256") == value_hash(leaf_value)
                for leaf_path, leaf_value in leaves
            )
        if owned or force:
            to_remove.append(entry_path)
            stale_keys.extend(under)
        else:
            conflicts.append(pointer(entry_path))

    if retained is None:
        retained = retained_marketplaces(profile, groups, destination, {tuple(path) for path in to_remove})
    lists = plan_list_removals(list_rules, source, destination, state_entry, force, retained)
    to_remove.extend(lists.deletes)
    conflicts.extend(lists.conflicts)
    stale_keys.extend(lists.spent)
    notes.extend(lists.notes)
    return to_remove, lists.rewrites, conflicts, sorted(set(stale_keys)), lists.owned_after, notes
