"""Shared primitives for merge_managed_config.py: errors, hashing, pointers and rule lookup."""

from __future__ import annotations

import hashlib
import json
from typing import Any


class MergeError(RuntimeError):
    """Raised for user-facing failures that must abort before any write."""


# State field listing the hashes of list-union items this tool appended.
ADDED_ITEMS_KEY = "added_item_sha256"


def value_hash(value: Any) -> str:
    """Stable hash of a value; identity only, never the value itself."""
    serialized = json.dumps(value, sort_keys=True, ensure_ascii=False, default=str)
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


def pointer(path: list[str]) -> str:
    """Render a leaf path as a slash-delimited pointer for state and logs."""
    return "/" + "/".join(str(part).replace("~", "~0").replace("/", "~1") for part in path)


def flatten_leaves(path: list[str], value: Any, policy: str) -> list[tuple[list[str], Any]]:
    """Expand one managed rule into the concrete leaves it governs."""
    if policy in {"object", "deep"} and isinstance(value, dict) and value:
        leaves: list[tuple[list[str], Any]] = []
        for key, child in value.items():
            leaves.extend(flatten_leaves([*path, key], child, policy))
        return leaves
    if policy == "map-entries" and isinstance(value, dict):
        return [([*path, key], child) for key, child in value.items()]
    return [(path, value)]


def read_nested(data: Any, path: list[str]) -> tuple[bool, Any]:
    """Return ``(found, value)`` for a nested path within parsed data."""
    current = data
    for part in path:
        if not isinstance(current, dict) or part not in current:
            return False, None
        current = current[part]
    return True, current


def write_nested(data: dict[str, Any], path: list[str], value: Any) -> None:
    """Set a nested path, creating intermediate objects as needed."""
    current = data
    for part in path[:-1]:
        existing = current.get(part)
        if not isinstance(existing, dict):
            existing = {}
            current[part] = existing
        current = existing
    current[path[-1]] = value


def union_lists(destination: list[Any], source: list[Any]) -> list[Any]:
    """Append missing source entries, preserving destination order."""
    merged = list(destination)
    for item in source:
        if item not in merged:
            merged.append(item)
    return merged


def collect_managed_leaves(
    profile: dict[str, Any],
    groups: list[str],
    source: dict[str, Any],
) -> list[tuple[list[str], Any]]:
    """Resolve the requested groups into concrete managed leaves."""
    available = profile["groups"]
    leaves: list[tuple[list[str], Any]] = []
    for group in groups:
        rules = available.get(group)
        if rules is None:
            raise MergeError(f"unknown group '{group}' (valid: {', '.join(sorted(available))})")
        for rule in rules:
            found, value = read_nested(source, rule["path"])
            if not found:
                continue
            if rule["policy"] == "list-union":
                leaves.append((rule["path"], value))
                continue
            leaves.extend(flatten_leaves(rule["path"], value, rule["policy"]))
    return leaves


def parse_pointer(key: str) -> list[str]:
    """Inverse of ``pointer``."""
    return [part.replace("~1", "/").replace("~0", "~") for part in key.lstrip("/").split("/")]


def delete_nested(data: dict[str, Any], path: list[str]) -> None:
    """Remove a nested key, pruning parent objects that become empty."""
    parents: list[tuple[dict[str, Any], str]] = []
    current: Any = data
    for part in path[:-1]:
        if not isinstance(current, dict) or part not in current:
            return
        parents.append((current, part))
        current = current[part]
    if not isinstance(current, dict) or path[-1] not in current:
        return
    del current[path[-1]]
    for parent, key in reversed(parents):
        if isinstance(parent.get(key), dict) and not parent[key]:
            del parent[key]


def rule_for(profile: dict[str, Any], groups: list[str], path: list[str]) -> dict[str, Any] | None:
    """The selected-group rule whose path prefixes this leaf."""
    for group in groups:
        rules: list[dict[str, Any]] = profile["groups"].get(group, [])
        for rule in rules:
            if path[: len(rule["path"])] == rule["path"]:
                return rule
    return None


def policy_for(profile: dict[str, Any], groups: list[str], path: list[str]) -> str:
    """Find the policy whose rule path prefixes this leaf."""
    rule = rule_for(profile, groups, path)
    return "scalar" if rule is None else str(rule["policy"])


def entry_policy_rules(profile: dict[str, Any], groups: list[str]) -> list[dict[str, Any]]:
    """All rules of the selected groups; unknown groups are an error."""
    available = profile["groups"]
    rules: list[dict[str, Any]] = []
    for group in groups:
        group_rules = available.get(group)
        if group_rules is None:
            raise MergeError(f"unknown group '{group}' (valid: {', '.join(sorted(available))})")
        rules.extend(group_rules)
    return rules
