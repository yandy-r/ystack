"""Managed-key profiles for merge_managed_config.py: per-runtime rules and the project-scope allowlists."""

from __future__ import annotations

from typing import Any

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
