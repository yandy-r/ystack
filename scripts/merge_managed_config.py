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
import copy
import hashlib
import json
import os
import re
import shlex
import sys
import tempfile
import tomllib
from collections.abc import Callable
from pathlib import Path
from typing import Any

from managed_config_entries import (
    available_entries,
    expand_leaf_rules,
    is_derived,
    narrow_profile,
    plan_keyed_list,
    plan_keyed_list_removal,
    retained_marketplaces,
    select_source_entries,
    selected_state,
    selection,
)
from managed_config_hooks import prune_event
from managed_config_legacy import plan_legacy_migration

REPO_ROOT = Path(__file__).resolve().parent.parent

STATE_PATH = Path(
    os.environ.get("YCC_MANAGED_CONFIG_STATE")
    or (Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "ycc" / "managed-config-state.json")
)

# Merge policies:
#   scalar       — one managed leaf (``model``, ``effortLevel``, ...)
#   object       — every leaf of the source object is managed individually;
#                  unknown sibling leaves in the destination are preserved
#   map-entries  — named scalar entries; unknown entries are preserved
#   deep         — recursively manage leaves inside named entries (MCP servers,
#                  providers, plugin tables) while preserving unknown siblings
#   list-union   — append missing source values, preserve destination order.
#                  Items this tool appended are recorded (by hash) so --remove
#                  can take back exactly those; ``keep_empty`` keeps the key as
#                  ``[]`` after removal for tools that require it, and
#                  ``prune_owned`` makes a merge also take back recorded items
#                  the source no longer lists.
#
# Entry metadata (see managed_config_entries.py):
#   item_key     — ``package`` | ``name``: list-union items are keyed, so
#                  ``--entries`` can select them and a new version of an item
#                  this tool added replaces it instead of being appended.
#   entry_key    — ``marketplace``: a derived rule selected through the
#                  marketplace of each selected ``plugin@marketplace`` entry;
#                  never listed, and kept on removal while still in use.
Rule = dict[str, Any]
RulePath = tuple[str, ...]

CLAUDE_SETTINGS_RULES: list[Rule] = [
    {"path": ["env"], "policy": "object"},
    {"path": ["attribution"], "policy": "object"},
    {"path": ["permissions"], "policy": "object"},
    {"path": ["statusLine"], "policy": "object"},
    {"path": ["model"], "policy": "scalar"},
    {"path": ["modelSettings"], "policy": "object"},
    {"path": ["alwaysThinkingEnabled"], "policy": "scalar"},
    {"path": ["effortLevel"], "policy": "scalar"},
    {"path": ["skipDangerousModePermissionPrompt"], "policy": "scalar"},
    {"path": ["skipAutoPermissionPrompt"], "policy": "scalar"},
]

# [projects.*] and [apps.*] are deliberately unmanaged: they hold machine-local
# trust decisions and account-specific connector IDs.
CODEX_SETTINGS_RULES: list[Rule] = [
    {"path": ["personality"], "policy": "scalar"},
    {"path": ["model"], "policy": "scalar"},
    {"path": ["model_reasoning_effort"], "policy": "scalar"},
    {"path": ["model_context_window"], "policy": "scalar"},
    {"path": ["model_auto_compact_token_limit"], "policy": "scalar"},
    {"path": ["plan_mode_reasoning_effort"], "policy": "scalar"},
    {"path": ["approval_policy"], "policy": "scalar"},
    {"path": ["approvals_reviewer"], "policy": "scalar"},
    {"path": ["sandbox_mode"], "policy": "scalar"},
    {"path": ["sandbox_workspace_write"], "policy": "object"},
    {"path": ["service_tier"], "policy": "scalar"},
    {"path": ["agents"], "policy": "object"},
    {"path": ["features"], "policy": "object"},
]

OPENCODE_SETTINGS_RULES: list[Rule] = [
    {"path": ["$schema"], "policy": "scalar"},
    {"path": ["model"], "policy": "scalar"},
    {"path": ["agents"], "policy": "deep"},
    {"path": ["providers"], "policy": "deep"},
    # Scoped to the one leaf the bundle sets so other user-owned
    # `experimental` toggles are never adopted or deleted.
    {"path": ["experimental", "subagent_depth"], "policy": "scalar"},
]

# Project-scope settings (install.sh `settings` step without --global) merge the
# ``settings-project`` group: a fail-closed allowlist of ``settings`` rules. A
# rule added to ``settings`` stays global-only until it is listed here.
PROJECT_GROUP = "settings-project"

# Claude: statusLine points at a script only the global step installs;
# permissions.defaultMode "auto" and skip*PermissionPrompt do not take effect
# from a project's shared .claude/settings.json.
CLAUDE_PROJECT_PATHS: tuple[RulePath, ...] = (
    ("env",),
    ("attribution",),
    ("model",),
    ("modelSettings",),
    ("alwaysThinkingEnabled",),
    ("effortLevel",),
)

# Codex: approval/sandbox posture stays global so a committed .codex/config.toml
# never widens it for every contributor.
CODEX_PROJECT_PATHS: tuple[RulePath, ...] = (
    ("personality",),
    ("model",),
    ("model_reasoning_effort",),
    ("model_context_window",),
    ("model_auto_compact_token_limit",),
    ("plan_mode_reasoning_effort",),
    ("service_tier",),
    ("agents",),
    ("features",),
)

OPENCODE_PROJECT_PATHS: tuple[RulePath, ...] = (
    ("$schema",),
    ("model",),
    ("agents",),
    ("providers",),
    ("experimental", "subagent_depth"),
)

# Top-level keys Codex ignores (with a startup warning) in project config files;
# none may ever enter a project group.
PROJECT_IGNORED_KEYS: dict[str, frozenset[str]] = {
    "codex-config": frozenset(
        {
            "openai_base_url",
            "chatgpt_base_url",
            "apps_mcp_product_sku",
            "model_provider",
            "model_providers",
            "notify",
            "profile",
            "profiles",
            "experimental_realtime_ws_base_url",
            "otel",
        }
    ),
}


def project_subset(rules: list[Rule], allowed_paths: tuple[RulePath, ...], label: str) -> list[Rule]:
    """The ``rules`` whose path is allowlisted for project scope, in base order.

    Raises ``ValueError`` (at import, via PROFILES) when an allowlisted path
    names no base rule, so a renamed or dropped rule breaks loudly instead of
    silently shrinking the project group.
    """
    known = {tuple(rule["path"]) for rule in rules}
    missing = ["/".join(path) for path in allowed_paths if path not in known]
    if missing:
        raise ValueError(f"{label}: {PROJECT_GROUP} allowlist names paths missing from settings: {', '.join(missing)}")
    allowed = set(allowed_paths)
    return [rule for rule in rules if tuple(rule["path"]) in allowed]


def check_project_ignored_keys(profiles: dict[str, dict[str, Any]], ignored: dict[str, frozenset[str]]) -> None:
    """Raise ``ValueError`` when a project group manages a key its runtime ignores at project level."""
    for name, keys in ignored.items():
        rules: list[Rule] = profiles[name]["groups"][PROJECT_GROUP]
        leaked = sorted({str(rule["path"][0]) for rule in rules} & keys)
        if leaked:
            raise ValueError(f"{name}: {PROJECT_GROUP} manages keys ignored at project level: {', '.join(leaked)}")


PROFILES: dict[str, dict[str, Any]] = {
    "claude-settings": {
        "format": "json",
        "groups": {
            "settings": CLAUDE_SETTINGS_RULES,
            PROJECT_GROUP: project_subset(CLAUDE_SETTINGS_RULES, CLAUDE_PROJECT_PATHS, "claude-settings"),
            "hooks": [
                {"path": ["hooks"], "policy": "map-entries"},
            ],
            "plugins": [
                {"path": ["enabledPlugins"], "policy": "map-entries"},
                {"path": ["extraKnownMarketplaces"], "policy": "map-entries", "entry_key": "marketplace"},
                {
                    "path": ["pluginMarketplaces"],
                    "policy": "list-union",
                    "item_key": "name",
                    "entry_key": "marketplace",
                },
            ],
        },
    },
    "claude-mcp": {
        "format": "json",
        "groups": {
            "mcp": [
                {"path": ["mcpServers"], "policy": "deep"},
            ],
        },
    },
    # Cursor's mcp.json uses the same mcpServers shape as Claude Code.
    "cursor-mcp": {
        "format": "json",
        "groups": {
            "mcp": [
                {"path": ["mcpServers"], "policy": "deep"},
            ],
        },
    },
    "cursor-cli": {
        "format": "json",
        "groups": {
            "settings": [
                {"path": ["version"], "policy": "scalar"},
                {"path": ["model"], "policy": "object"},
                {"path": ["hasChangedDefaultModel"], "policy": "scalar"},
                {"path": ["editor"], "policy": "object"},
                # Cursor treats permissions.allow/deny as required; seed them
                # without managing their contents (list-union never removes).
                {"path": ["permissions", "allow"], "policy": "list-union", "keep_empty": True},
                {"path": ["permissions", "deny"], "policy": "list-union", "keep_empty": True},
            ],
        },
    },
    # Cursor loads user sessionStart hooks from hooks.json. Only that event is managed;
    # list-union preserves every foreign hook command and unrelated event entry.
    "cursor-hooks": {
        "format": "json",
        "strict_hooks": True,
        "groups": {
            "hooks": [
                {"path": ["hooks", "sessionStart"], "policy": "list-union", "keep_empty": True},
            ],
        },
    },
    "codex-config": {
        "format": "toml",
        "groups": {
            "settings": CODEX_SETTINGS_RULES,
            PROJECT_GROUP: project_subset(CODEX_SETTINGS_RULES, CODEX_PROJECT_PATHS, "codex-config"),
            "mcp": [
                {"path": ["mcp_servers"], "policy": "deep"},
            ],
            "plugins": [
                {"path": ["plugins"], "policy": "deep"},
            ],
        },
    },
    "opencode-config": {
        "format": "json",
        # opencode parses its config as JSONC (comments, trailing commas).
        "jsonc": True,
        "groups": {
            "settings": OPENCODE_SETTINGS_RULES,
            PROJECT_GROUP: project_subset(OPENCODE_SETTINGS_RULES, OPENCODE_PROJECT_PATHS, "opencode-config"),
            "mcp": [
                {"path": ["mcp", "servers"], "policy": "deep"},
            ],
            "plugins": [
                {"path": ["plugins"], "policy": "list-union", "item_key": "package"},
            ],
        },
    },
    # Opt-in third-party catalog plugins (opencode_plugin_catalog.py source),
    # run once per plugin with --state-scope so each owns its own state.
    "opencode-catalog": {
        "format": "json",
        "jsonc": True,
        "groups": {
            "plugins": [{"path": ["plugins"], "policy": "list-union", "item_key": "package"}],
            # Owned per leaf (expand_leaf_rules): the bundle shares these entries.
            "agents": [{"path": ["agents"], "policy": "deep", "leaf_rules": True}],
        },
    },
    # OMP's user config.yml. Only these ycc-owned leaves are managed; other
    # modelRoles and retry.fallbackChains entries and every other key (other
    # retry.* settings included) stay the user's; each role's chain is one
    # owned leaf. A symlinked
    # config.yml (dotfiles) is refused: atomic_write would replace the link.
    # The default-on ``dedupe`` group appends the ``<ns>/<name>`` aliases of
    # ledger-owned ycc skills that OMP also reads from ~/.agents, ~/.codex or
    # opencode to skills.ignoredSkills; user items are kept, a re-run takes back
    # the aliases it no longer emits, and --remove takes back only the items this
    # tool appended.
    "omp-config": {
        "format": "yaml",
        "refuse_symlink": True,
        "backup_original": True,
        "groups": {
            "settings": [
                {"path": ["modelRoles"], "policy": "map-entries"},
                {"path": ["retry", "fallbackChains"], "policy": "map-entries"},
                {"path": ["tools", "approvalMode"], "policy": "scalar"},
            ],
            "dedupe": [
                {"path": ["skills", "ignoredSkills"], "policy": "list-union", "prune_owned": True},
            ],
        },
    },
}
check_project_ignored_keys(PROFILES, PROJECT_IGNORED_KEYS)


# State field listing the hashes of list-union items this tool appended.
ADDED_ITEMS_KEY = "added_item_sha256"


def _scan_outside_strings(text: str, handle: Callable[[str, int], tuple[str, int]]) -> str:
    """Copy text, letting handle(text, i) rewrite spans that start outside strings."""
    out: list[str] = []
    i, n = 0, len(text)
    in_string = False
    while i < n:
        ch = text[i]
        if in_string:
            if ch == "\\" and i + 1 < n:
                out.append(text[i : i + 2])
                i += 2
                continue
            in_string = ch != '"'
            out.append(ch)
            i += 1
        elif ch == '"':
            in_string = True
            out.append(ch)
            i += 1
        else:
            emitted, i = handle(text, i)
            out.append(emitted)
    return "".join(out)


def _drop_comment(text: str, i: int) -> tuple[str, int]:
    if text.startswith("//", i):
        newline = text.find("\n", i)
        return "", len(text) if newline < 0 else newline
    if text.startswith("/*", i):
        end = text.find("*/", i + 2)
        if end < 0:
            raise MergeError("unterminated /* comment */")
        return "", end + 2
    return text[i], i + 1


def _drop_trailing_comma(text: str, i: int) -> tuple[str, int]:
    if text[i] == "," and text[i + 1 :].lstrip()[:1] in ("}", "]"):
        return "", i + 1
    return text[i], i + 1


def strip_jsonc(text: str) -> str:
    """Drop // and /* */ comments, then trailing commas, outside JSON strings."""
    return _scan_outside_strings(_scan_outside_strings(text, _drop_comment), _drop_trailing_comma)


def load_json_config(raw: str, path: Path, profile: dict[str, Any]) -> Any:
    """Parse a destination config; JSONC profiles accept comments + trailing commas."""
    if not raw.strip():
        return {}
    if not profile.get("jsonc"):
        return json.loads(raw)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        pass
    data = json.loads(strip_jsonc(raw))
    print(f"  [!!] {path} is JSONC (comments or trailing commas); they are dropped when it is rewritten")
    return data


def validate_cursor_hooks_source(source: Any) -> dict[str, Any]:
    """Return the generated sessionStart payload after an exact shape check."""
    if not isinstance(source, dict) or set(source) != {"version", "hooks"} or source.get("version") != 1:
        raise MergeError("Cursor hooks source must be {version: 1, hooks: {sessionStart: [...]}}")
    hooks = source.get("hooks")
    if not isinstance(hooks, dict) or set(hooks) != {"sessionStart"}:
        raise MergeError("Cursor hooks source may register sessionStart only")
    entries = hooks.get("sessionStart")
    if not isinstance(entries, list) or len(entries) != 1 or not isinstance(entries[0], dict):
        raise MergeError("Cursor hooks source must contain exactly one sessionStart command")
    entry = entries[0]
    if set(entry) != {"command"} or not isinstance(entry.get("command"), str) or not entry["command"]:
        raise MergeError("Cursor hooks sessionStart entry must contain one non-empty command")
    return source


def validate_cursor_hooks_destination(destination: Any) -> None:
    """Reject generated-hook rewrites that could silence Cursor's hooks file."""
    hooks = destination.get("hooks") if isinstance(destination, dict) else None
    if (
        not isinstance(destination, dict)
        or destination.get("version") != 1
        or not isinstance(hooks, dict)
        or any(not isinstance(entries, list) for entries in hooks.values())
        or "sessionStart" in hooks
        and any(not isinstance(e, dict) or not isinstance(e.get("command"), str) for e in hooks["sessionStart"])
    ):
        raise MergeError(
            "invalid Cursor hooks.json (expected version 1 and event lists of command objects); "
            "fix it before installing ycc-hooks"
        )


def check_cursor_hooks_ownership(source: dict[str, Any], destination: dict[str, Any]) -> None:
    """Fail closed when a different herdr sessionStart command already exists."""
    wanted = source["hooks"]["sessionStart"][0]
    for entry in destination.get("hooks", {}).get("sessionStart", []):
        if "herdr-session-start.sh" in entry["command"] and entry != wanted:
            raise MergeError(
                "Cursor sessionStart ownership collision: existing herdr command differs; resolve it first"
            )


class MergeError(RuntimeError):
    """Raised for user-facing failures that must abort before any write."""


# OMP parses config.yml with Bun's YAML 1.2 core schema. PyYAML's default 1.1
# schema would read user values such as `off`, `12:30` or `1_000` as booleans
# and numbers and write them back changed. These resolvers implement 1.2 core.
YAML12_RESOLVERS: list[tuple[str, str, str]] = [
    ("tag:yaml.org,2002:null", r"^(?:~|null|Null|NULL|)$", "~nN"),
    ("tag:yaml.org,2002:bool", r"^(?:true|True|TRUE|false|False|FALSE)$", "tTfF"),
    ("tag:yaml.org,2002:int", r"^[-+]?(?:[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+)$", "-+0123456789"),
    (
        "tag:yaml.org,2002:float",
        r"^(?:[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$",
        "-+.0123456789",
    ),
]
YAML12_TAGS = {tag for tag, _, _ in YAML12_RESOLVERS}


def _yaml12() -> tuple[Any, type[Any], type[Any]]:
    """Return ``(yaml, Loader, Dumper)`` for the YAML 1.2 core schema.

    The loader resolves plain scalars like Bun does. The dumper keeps PyYAML's
    1.1 resolvers and adds the 1.2 ones, so any string either reader would
    misread (``off``, ``0755``, ``1e3``, ``0o17``) is written quoted.
    """
    try:
        import yaml  # Lazy: JSON and TOML profiles never need PyYAML.
    except ImportError as error:
        raise MergeError(
            "PyYAML is required to merge OMP config.yml; install it with: python3 -m pip install --user pyyaml"
        ) from error

    dropped = YAML12_TAGS | {"tag:yaml.org,2002:timestamp", "tag:yaml.org,2002:value"}

    def resolvers(base: dict[Any, Any], keep_tags: bool) -> dict[Any, Any]:
        table: dict[Any, Any] = {
            ch: [entry for entry in entries if keep_tags or entry[0] not in dropped] for ch, entries in base.items()
        }
        for tag, pattern, first in YAML12_RESOLVERS:
            # PyYAML looks up the empty scalar under the "" key.
            for ch in [*first, ""] if tag.endswith(":null") else first:
                table.setdefault(ch, []).append((tag, re.compile(pattern)))
        return table

    def construct_int(loader: Any, node: Any) -> int:
        value = str(loader.construct_scalar(node))
        sign = -1 if value.startswith("-") else 1
        digits = value.lstrip("+-")
        if digits.startswith(("0o", "0x")):
            return sign * int(digits[2:], 8 if digits[1] == "o" else 16)
        return sign * int(digits, 10)

    class Loader(yaml.SafeLoader):
        yaml_implicit_resolvers = resolvers(yaml.SafeLoader.yaml_implicit_resolvers, keep_tags=False)

    Loader.add_constructor("tag:yaml.org,2002:int", construct_int)

    class Dumper(yaml.SafeDumper):
        yaml_implicit_resolvers = resolvers(yaml.SafeDumper.yaml_implicit_resolvers, keep_tags=True)

        def ignore_aliases(self, data: Any) -> bool:
            # Never emit anchors/aliases: shared objects are written out in full.
            return True

    return yaml, Loader, Dumper


def load_yaml_config(raw: str, label: str | Path) -> dict[str, Any]:
    """Parse YAML 1.2 into a mapping; empty means ``{}``, anything else is refused.

    Aliases (including ``<<: *anchor`` merge keys) are refused: a rewrite would
    expand them into copies and silently break the sharing.
    """
    yaml, loader, _ = _yaml12()
    try:
        if any(isinstance(event, yaml.AliasEvent) for event in yaml.parse(raw, Loader=loader)):
            raise MergeError(
                f"{label}: not a valid OMP config for ycc (YAML aliases are not supported); "
                "replace them with plain values first, no changes made"
            )
        data = yaml.load(raw, Loader=loader)
    except yaml.YAMLError as error:
        detail = " ".join(str(error).split())
        raise MergeError(f"{label}: not a valid OMP config ({detail}); fix it first, no changes made") from error
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise MergeError(f"{label}: not a valid OMP config (expected a mapping)")
    return data


def render_yaml(data: dict[str, Any], label: str | Path) -> str:
    """Serialize a merged mapping, refusing output that does not round-trip under YAML 1.2."""
    yaml, loader, dumper = _yaml12()
    rendered = str(yaml.dump(data, Dumper=dumper, sort_keys=False, allow_unicode=True, default_flow_style=False))
    # repr, not ==: a user `.nan` value never equals itself.
    if repr(yaml.load(rendered, Loader=loader)) != repr(data):
        raise MergeError(f"{label}: YAML merge verification failed (rendered config does not round-trip)")
    return rendered


def load_source(path: Path, profile: dict[str, Any]) -> dict[str, Any]:
    """Parse the repo-managed source config (format by suffix, else the profile's format)."""
    text = path.read_text(encoding="utf-8")
    suffix_format = {".json": "json", ".toml": "toml", ".yml": "yaml", ".yaml": "yaml"}
    source_format = suffix_format.get(path.suffix, profile["format"])
    if source_format == "yaml":
        source: Any = load_yaml_config(text, path)
    elif source_format == "json":
        source = json.loads(text)
    else:
        source = tomllib.loads(text)
    if not isinstance(source, dict):
        raise MergeError(f"{path}: expected an object at the root")
    return source


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


def load_state() -> dict[str, Any]:
    if not STATE_PATH.is_file():
        return {}
    try:
        payload = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        # A corrupt state file must not block installs; ownership simply falls
        # back to the conservative "preserve the user's value" branch.
        return {}
    return payload if isinstance(payload, dict) else {}


def save_state(state: dict[str, Any]) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(STATE_PATH, json.dumps(state, indent=2, sort_keys=True) + "\n")


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


def atomic_write(path: Path, text: str) -> None:
    """Write via a temp file in the same directory, then rename into place.

    A symlink at ``path`` is replaced by the rename, so the link target (often
    a repo file) is never written through. The target's permission bits are
    carried over so a restrictive mode on a credential-bearing config survives.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else None
    handle = tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    )
    try:
        with handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        if mode is not None:
            os.chmod(handle.name, mode)
        os.replace(handle.name, path)
    except BaseException:
        Path(handle.name).unlink(missing_ok=True)
        raise


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


# ---------------------------------------------------------------------------
# TOML text patching
#
# tomllib parses but cannot serialize, and a hand-rolled writer would destroy
# comments, ordering and quoting. Instead we locate the exact byte span of each
# managed assignment and replace only that span.
# ---------------------------------------------------------------------------

TOML_TABLE_RE = re.compile(r"^\s*\[\[?([^\]]+)\]\]?\s*(?:#.*)?$")
TOML_KEY_RE = re.compile(
    r"^\s*((?:[A-Za-z0-9_-]+|\"[^\"]*\"|'[^']*')(?:\s*\.\s*(?:[A-Za-z0-9_-]+|\"[^\"]*\"|'[^']*'))*)\s*="
)


def split_toml_key(raw: str) -> list[str]:
    """Split a possibly dotted, possibly quoted TOML key into segments."""
    parts: list[str] = []
    for chunk in re.findall(r"\"[^\"]*\"|'[^']*'|[^.\s]+", raw):
        if chunk[:1] in {'"', "'"}:
            parts.append(chunk[1:-1])
        else:
            parts.append(chunk)
    return parts


def format_toml_value(value: Any) -> str:
    """Render a Python value as TOML. Mirrors the JSON subset we manage."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return json.dumps(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ", ".join(format_toml_value(item) for item in value) + "]"
    if isinstance(value, dict):
        return "{ " + ", ".join(f"{format_toml_key(k)} = {format_toml_value(v)}" for k, v in value.items()) + " }"
    raise MergeError(f"cannot render TOML value of type {type(value).__name__}")


def format_toml_key(key: str) -> str:
    return key if re.fullmatch(r"[A-Za-z0-9_-]+", key) else json.dumps(key, ensure_ascii=False)


def format_toml_path(path: list[str]) -> str:
    return ".".join(format_toml_key(part) for part in path)


def scan_toml_assignments(lines: list[str]) -> dict[tuple[str, ...], tuple[int, int]]:
    """Map each assignment's full key path to its ``[start, end)`` line span.

    Multi-line values (arrays, multi-line strings) are handled by extending the
    span until the accumulated text parses as TOML again.
    """
    spans: dict[tuple[str, ...], tuple[int, int]] = {}
    table: list[str] = []
    index = 0

    while index < len(lines):
        line = lines[index]
        stripped = line.strip()

        if not stripped or stripped.startswith("#"):
            index += 1
            continue

        table_match = TOML_TABLE_RE.match(line)
        if table_match:
            table = split_toml_key(table_match.group(1))
            index += 1
            continue

        key_match = TOML_KEY_RE.match(line)
        if not key_match:
            index += 1
            continue

        end = index + 1
        while end <= len(lines):
            candidate = "".join(lines[index:end])
            try:
                tomllib.loads(candidate)
                break
            except tomllib.TOMLDecodeError:
                end += 1
        else:
            raise MergeError(f"could not determine the end of the TOML assignment starting at line {index + 1}")

        spans[tuple(table + split_toml_key(key_match.group(1)))] = (index, end)
        index = end

    return spans


def repair_duplicate_managed_toml(text: str, managed_paths: list[list[str]]) -> str:
    """Remove duplicate managed assignments/tables so ``--force`` can recover.

    Recovery is intentionally narrow: only paths supplied by the selected
    profile groups are eligible, and a duplicated table is removed only when
    every assignment in each occurrence is managed. The normal merge then
    writes the source-of-truth values back atomically. Unrelated malformed TOML
    remains an error.
    """
    lines = text.splitlines(keepends=True)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"

    managed = {tuple(path) for path in managed_paths}
    occurrences: dict[tuple[str, ...], list[tuple[int, int]]] = {}
    table_headers: dict[tuple[str, ...], list[int]] = {}
    table: tuple[str, ...] = ()
    covered_assignment_lines: set[int] = set()
    index = 0

    while index < len(lines):
        line = lines[index]
        table_match = TOML_TABLE_RE.match(line)
        if table_match:
            table = tuple(split_toml_key(table_match.group(1)))
            table_headers.setdefault(table, []).append(index)
            index += 1
            continue

        key_match = TOML_KEY_RE.match(line)
        if not key_match:
            index += 1
            continue

        end = index + 1
        while end <= len(lines):
            try:
                tomllib.loads("".join(lines[index:end]))
                break
            except tomllib.TOMLDecodeError:
                end += 1
        else:
            return text

        path = (*table, *split_toml_key(key_match.group(1)))
        occurrences.setdefault(path, []).append((index, end))
        covered_assignment_lines.update(range(index, end))
        index = end

    duplicate_paths = {path for path, spans in occurrences.items() if len(spans) > 1 and path in managed}
    if not duplicate_paths:
        return text

    duplicate_tables = {
        table_path
        for table_path, headers in table_headers.items()
        if len(headers) > 1 and any(path[:-1] == table_path for path in duplicate_paths)
    }

    header_indexes = sorted(index for indexes in table_headers.values() for index in indexes)
    remove_lines: set[int] = set()

    for table_path in duplicate_tables:
        for header_index in table_headers[table_path]:
            next_header = next((candidate for candidate in header_indexes if candidate > header_index), len(lines))
            for line_index in range(header_index + 1, next_header):
                stripped = lines[line_index].strip()
                if not stripped or stripped.startswith("#") or line_index in covered_assignment_lines:
                    continue
                return text

            section_paths = {
                path
                for path, spans in occurrences.items()
                if any(header_index < start < next_header for start, _ in spans)
            }
            if not section_paths.issubset(managed):
                return text

            remove_lines.add(header_index)
            for path in section_paths:
                for start, end in occurrences[path]:
                    if header_index < start < next_header:
                        remove_lines.update(range(start, end))

    for path in duplicate_paths:
        if path[:-1] in duplicate_tables:
            continue
        for start, end in occurrences[path]:
            remove_lines.update(range(start, end))

    return "".join(line for line_index, line in enumerate(lines) if line_index not in remove_lines)


def table_end_line(lines: list[str], table: list[str]) -> int | None:
    """Return the insertion point at the end of an existing table's body."""
    target = tuple(table)
    in_table = False
    last_content = None

    for index, line in enumerate(lines):
        table_match = TOML_TABLE_RE.match(line)
        if table_match:
            if in_table:
                return (last_content + 1) if last_content is not None else index
            in_table = tuple(split_toml_key(table_match.group(1))) == target
            if in_table:
                last_content = index
            continue
        if in_table and line.strip() and not line.strip().startswith("#"):
            last_content = index

    if in_table:
        return (last_content + 1) if last_content is not None else len(lines)
    return None


def split_inline_deletions(
    text: str, deletions: list[list[str]], destination: dict[str, Any]
) -> tuple[list[list[str]], list[tuple[list[str], Any]]]:
    """Turn deletions inside an inline-table assignment into a rewrite of that assignment.

    Siblings stay; a table left empty is deleted whole. Other deletions pass through.
    """
    spans = scan_toml_assignments(text.splitlines(keepends=True))
    plain: list[list[str]] = []
    holders: dict[tuple[str, ...], dict[str, Any]] = {}
    for path in deletions:
        parent = next((tuple(path[:n]) for n in range(len(path) - 1, 0, -1) if tuple(path[:n]) in spans), None)
        value = read_nested(destination, list(parent))[1] if parent else None
        if parent is None or not isinstance(value, dict):
            plain.append(path)
            continue
        holder = holders.setdefault(parent, {"v": json.loads(json.dumps(value))})
        delete_nested(holder, ["v", *path[len(parent) :]])
    rewrites: list[tuple[list[str], Any]] = []
    for parent, holder in holders.items():
        if "v" in holder:
            rewrites.append((list(parent), holder["v"]))
        else:
            plain.append(list(parent))
    return plain, rewrites


def apply_toml_updates(
    text: str,
    updates: list[tuple[list[str], Any]],
    deletions: list[list[str]] | None = None,
) -> str:
    """Patch managed assignments in place, leaving all other bytes untouched.

    Deletions drop the assignment or whole table subtree at each path.
    """
    if deletions:
        text = delete_toml_entries(text, deletions)
    lines = text.splitlines(keepends=True)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"

    # Apply bottom-up so earlier spans keep their indices valid.
    replacements: list[tuple[int, int, str]] = []
    root_appends: list[str] = []
    appends: dict[tuple[str, ...], list[str]] = {}
    new_tables: dict[tuple[str, ...], list[str]] = {}

    spans = scan_toml_assignments(lines)

    for path, value in updates:
        key = tuple(path)
        rendered = f"{format_toml_key(path[-1])} = {format_toml_value(value)}\n"

        if key in spans:
            start, end = spans[key]
            replacements.append((start, end, rendered))
            continue

        table = key[:-1]
        if not table:
            root_appends.append(rendered)
            continue

        if table_end_line(lines, list(table)) is not None:
            appends.setdefault(table, []).append(rendered)
        else:
            new_tables.setdefault(table, []).append(rendered)

    if root_appends:
        # Root keys must land above the first table header, otherwise TOML
        # would read them as members of the last table in the file.
        insert_at = next(
            (index for index, line in enumerate(lines) if TOML_TABLE_RE.match(line)),
            len(lines),
        )
        replacements.append((insert_at, insert_at, "".join(root_appends)))

    for table, rendered_lines in appends.items():
        table_end = table_end_line(lines, list(table))
        assert table_end is not None
        replacements.append((table_end, table_end, "".join(rendered_lines)))

    for start, end, rendered in sorted(replacements, key=lambda item: item[0], reverse=True):
        lines[start:end] = [rendered] if rendered else []

    tail = ""
    for table, rendered_lines in new_tables.items():
        tail += f"\n[{format_toml_path(list(table))}]\n" + "".join(rendered_lines)

    return "".join(lines) + tail


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


def delete_toml_entries(text: str, entries: list[list[str]]) -> str:
    """Drop every table and assignment at or below the given paths.

    A path inside an inline-table value is one assignment, so callers route
    those through split_inline_deletions first.
    """
    lines = text.splitlines(keepends=True)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    prefixes = [tuple(entry) for entry in entries]

    def under(path: tuple[str, ...]) -> bool:
        return any(path[: len(prefix)] == prefix for prefix in prefixes)

    headers = [
        (index, tuple(split_toml_key(match.group(1))))
        for index, line in enumerate(lines)
        if (match := TOML_TABLE_RE.match(line))
    ]
    bounds = [index for index, _ in headers] + [len(lines)]
    remove: set[int] = set()
    for position, (index, table) in enumerate(headers):
        if under(table):
            remove.update(range(index, bounds[position + 1]))
    for path, (start, end) in scan_toml_assignments(lines).items():
        if under(path):
            remove.update(range(start, end))
    return "".join(line for index, line in enumerate(lines) if index not in remove)


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


def load_yaml_destination(destination_path: Path) -> dict[str, Any]:
    if not destination_path.exists():
        return {}
    return load_yaml_config(destination_path.read_text(encoding="utf-8"), destination_path)


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


def yaml_rewrite_is_lossless(raw: bytes) -> bool:
    """True when re-rendering the file reproduces it byte for byte (ycc's own output).

    Anything else (comments, other formatting, key styles) would be dropped.
    """
    try:
        text = raw.decode("utf-8")
        return not text.strip() or render_yaml(load_yaml_config(text, "config"), "config") == text
    except (UnicodeDecodeError, MergeError):
        return False


def ycc_backups(destination_path: Path) -> list[Path]:
    """``<dest>.ycc-backup`` then ``<dest>.ycc-backup.1``, ``.2``, … up to the first free name.

    The last entry does not exist yet; it is where a new backup goes.
    """
    base = destination_path.with_name(f"{destination_path.name}.ycc-backup")
    names = [base]
    while names[-1].exists() or names[-1].is_symlink():
        names.append(base.with_name(f"{base.name}.{len(names)}"))
    return names


def backup_before_rewrite(profile: dict[str, Any], destination_path: Path) -> None:
    """Save the current file before a rewrite drops its comments or formatting.

    A file that is already ycc's own rendering loses nothing and is not saved.
    Otherwise the bytes go to ``<dest>.ycc-backup``, or to the first free
    ``<dest>.ycc-backup.N`` when the existing backups hold different bytes.
    A backup is never overwritten, and every lossy rewrite warns.
    """
    if not profile.get("backup_original") or not destination_path.is_file():
        return
    original = destination_path.read_bytes()
    if yaml_rewrite_is_lossless(original):
        return
    *existing, free = ycc_backups(destination_path)
    backup = next((path for path in existing if path.is_file() and path.read_bytes() == original), None)
    if backup is None:
        backup = free
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.fchmod(fd, 0o600)
            os.write(fd, original)
            os.fsync(fd)
        finally:
            os.close(fd)
    print(f"  [!!] comments and formatting in {destination_path} are not preserved; original saved to {backup}")


def drop_ycc_only_backups(profile: dict[str, Any], destination_path: Path) -> None:
    """After removing an emptied file, delete the backups ycc itself wrote.

    A backup that is only ycc's own rendering holds no user content; backups
    with comments or other formatting are kept.
    """
    if not profile.get("backup_original"):
        return
    for backup in ycc_backups(destination_path)[:-1]:
        if backup.is_file() and not backup.is_symlink() and yaml_rewrite_is_lossless(backup.read_bytes()):
            backup.unlink()
            print(f"  [ok] removed ycc backup {backup}")


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
            save_state(state)
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
        save_state(state)
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


def remove_owns_nothing(
    profile_name: str, profile: dict[str, Any], groups: list[str], source_path: Path, destination_path: Path
) -> bool:
    """True when ``--remove`` has nothing to act on: no managed source leaf and no recorded state.

    Without either, every remover returns "nothing to remove", so the destination need not be read.
    """
    try:
        if collect_managed_leaves(profile, groups, load_source(source_path, profile)):
            return False
    except (MergeError, json.JSONDecodeError, tomllib.TOMLDecodeError):
        return False
    entry = load_state().get(f"{profile_name}:{destination_path}", {})
    if not isinstance(entry, dict):
        return True
    rules = entry_policy_rules(profile, groups)
    return not any(
        key.startswith("/") and any(parse_pointer(key)[: len(rule["path"])] == rule["path"] for rule in rules)
        for key in entry
    )


def has_state(
    profile_name: str,
    profile: dict[str, Any],
    destination_path: Path,
    state_scope: str | None,
    groups: list[str] | None,
) -> bool:
    """Whether ``<profile>[scope]:<destination>`` has recorded ownership state.

    With ``groups``, only state under those groups' rules counts (unknown
    groups raise ``MergeError``); without, any recorded leaf does.
    """
    scope = f"[{state_scope}]" if state_scope is not None else ""
    entry = load_state().get(f"{profile_name}{scope}:{destination_path}")
    if not isinstance(entry, dict) or not entry:
        return False
    if groups is None:
        return True
    rules = entry_policy_rules(profile, groups)
    return any(
        key.startswith("/") and any(parse_pointer(key)[: len(rule["path"])] == rule["path"] for rule in rules)
        for key in entry
    )


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
            found = has_state(args.profile, profile, args.destination.expanduser(), args.state_scope, state_groups)
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
        and remove_owns_nothing(args.profile, profile, groups, source_path, destination_path)
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
        return run_remove(args, profile, groups, source, destination_path, state, state_key, state_entry, plan_state)

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
