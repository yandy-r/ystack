#!/usr/bin/env python3
"""
Generate opencode-native plugin metadata: .opencode-plugin/opencode.json and
.opencode-plugin/AGENTS.md.

opencode has no plugin manifest file analogous to Claude Code's plugin.json
or Codex's .codex-plugin/plugin.json. The bundle's top-level config is the
opencode.json we emit here, and the native rules file is AGENTS.md.

The emitted config targets OpenCode V2 exclusively. Note that
https://opencode.ai/config.json still serves the V1 schema, so it validates the
wrong shapes; scripts/validate_opencode_config.py encodes the V2 field set from
opencode.ai/v2/docs instead. The `$schema` URL is still emitted because editors
use it for autocomplete.

opencode.json contents:
- `$schema`: https://opencode.ai/config.json
- `model`: main model from ycc/settings/models.json (bundle default; users can
  override globally)
- `providers.<provider>.models[<model>]`: reasoningEffort/textVerbosity from the
  models.json main entry, plus a `subagent` variant carrying the sub-agent
  values. opencode resolves variants as `model#subagent`. Only the main model
  gets a local entry; models referenced solely by per-agent pins resolve from
  the provider's own catalog.
- `agents.<id>`: emitted verbatim from targets.opencode.agents in models.json,
  which must map every ycc/agents/*.md basename plus the built-in subagents
  (general, explore) to a full `provider/model` reference.
- `plugins`: shared OpenCode V2 plugins loaded by server/runtime (the ycc
  package itself is registered by install.sh's base step, not here)
- `experimental.subagent_depth`: runtime subagent nesting limit

The opencode model values are placeholders (models.json marks the target with
`placeholder: true`) because the usable catalog depends on the user's provider
subscriptions. Machines that need different models override
~/.config/opencode/opencode.json rather than this generated bundle file.

MCP servers are not emitted: @yandy-r/ycc-opencode registers them from
mcp-configs/mcp.json (scripts/generate_opencode_package.py).

AGENTS.md copies ycc/settings/rules/CLAUDE.md (the tool-neutral user-global
ruleset) verbatim after a generated-file header. No product, path or filename
substitution is applied. It installs to ~/.config/opencode/AGENTS.md, so it
must not source this repo's project-specific contributor instructions.

Source of truth:
- ycc/.claude-plugin/plugin.json (name/version reference, not emitted)
- ycc/settings/models.json
- ycc/settings/rules/CLAUDE.md
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

from generate_opencode_common import (
    OPENCODE_AGENTS_MD_PATH,
    OPENCODE_CONFIG_PATH,
    OPENCODE_PLUGIN_ROOT,
    REPO_ROOT,
    SRC_AGENTS_DIR,
)

# .opencode-plugin/AGENTS.md installs into ~/.config/opencode/AGENTS.md as the
# user-global opencode rules file, so it must source from the generic
# user-global rules tree — not this repo's project-specific CLAUDE.md.
SOURCE_RULES_PATH = REPO_ROOT / "ycc" / "settings" / "rules" / "CLAUDE.md"
SOURCE_MODEL_SETTINGS_PATH = REPO_ROOT / "ycc" / "settings" / "models.json"

# OpenCode V2 `plugins` entries the settings step merges into opencode.json.
# The goal plugin (npm) adds Codex-style goal mode: /goal commands, persistent
# goal state, and the goal tools the user-global AGENTS.md policy references.
# The sensitive-file guard ships inside @yandy-r/ycc-opencode (which the base
# step registers), so no local `./ycc-sensitive-guard` entry is emitted.
DEFAULT_PLUGINS: list[str] = ["@prevalentware/opencode-goal-plugin"]

# Runtime subagent nesting depth limit.
DEFAULT_SUBAGENT_DEPTH: int = 2

# Variant ID applied to the sub-agent reasoning effort. opencode selects it as
# `provider/model#subagent` (see opencode.ai/v2/docs/models §Variants).
SUBAGENT_VARIANT_ID = "subagent"

# Built-in opencode subagents that delegated work runs through.
BUILTIN_SUBAGENTS = ("general", "explore")


def load_model_settings() -> dict[str, object]:
    """Load the opencode entry from the shared model/effort source of truth."""
    if not SOURCE_MODEL_SETTINGS_PATH.is_file():
        raise SystemExit(f"opencode plugin generator cannot find {SOURCE_MODEL_SETTINGS_PATH.relative_to(REPO_ROOT)}")

    payload = json.loads(SOURCE_MODEL_SETTINGS_PATH.read_text(encoding="utf-8"))
    target = payload.get("targets", {}).get("opencode")
    if not isinstance(target, dict):
        raise SystemExit(f"{SOURCE_MODEL_SETTINGS_PATH.relative_to(REPO_ROOT)} is missing targets.opencode")

    for field in ("provider", "main", "subagent", "agents"):
        if field not in target:
            raise SystemExit(
                f"{SOURCE_MODEL_SETTINGS_PATH.relative_to(REPO_ROOT)}: targets.opencode.{field} is required"
            )
    return target


def expected_agent_ids() -> set[str]:
    """Return source agent IDs plus OpenCode's built-in delegated agents."""
    return {path.stem for path in SRC_AGENTS_DIR.glob("*.md")} | set(BUILTIN_SUBAGENTS)


def validate_agent_models(agent_models: object) -> dict[str, str]:
    """Validate exact agent coverage and full OpenCode V2 model references."""
    settings_path = SOURCE_MODEL_SETTINGS_PATH.relative_to(REPO_ROOT)
    if not isinstance(agent_models, dict):
        raise SystemExit(f"{settings_path}: targets.opencode.agents must be an object")

    expected = expected_agent_ids()
    configured = set(agent_models)
    missing = sorted(expected - configured)
    stale = sorted(configured - expected)
    if missing or stale:
        details: list[str] = []
        if missing:
            details.append(f"missing agent IDs: {', '.join(missing)}")
        if stale:
            details.append(f"stale agent IDs: {', '.join(stale)}")
        raise SystemExit(
            f"{settings_path}: targets.opencode.agents must exactly cover "
            f"ycc/agents/*.md plus {', '.join(BUILTIN_SUBAGENTS)}; {'; '.join(details)}"
        )

    validated: dict[str, str] = {}
    for agent_id, reference in agent_models.items():
        if not isinstance(reference, str):
            raise SystemExit(f"{settings_path}: targets.opencode.agents.{agent_id} must be a 'provider/model' string")
        split_model_reference(reference)
        validated[agent_id] = reference
    return validated


def require_model_field(settings: dict[str, object], entry_name: str, field: str) -> object:
    """Read a required main/subagent model setting with a clear error."""
    entry = settings.get(entry_name)
    if not isinstance(entry, dict) or field not in entry:
        raise SystemExit(
            f"{SOURCE_MODEL_SETTINGS_PATH.relative_to(REPO_ROOT)}: targets.opencode.{entry_name}.{field} is required"
        )
    return entry[field]


def split_model_reference(reference: str) -> tuple[str, str]:
    """Split a `provider/model` reference into its two parts."""
    provider, separator, model = reference.partition("/")
    if not separator or not provider or not model:
        raise SystemExit(
            f"{SOURCE_MODEL_SETTINGS_PATH.relative_to(REPO_ROOT)}: expected 'provider/model', got {reference!r}"
        )
    return provider, model


def build_provider_config(settings: dict[str, object]) -> dict[str, object]:
    """Emit provider settings carrying main effort plus a sub-agent variant.

    Only the main model is declared locally. Models referenced solely by
    per-agent pins resolve from the provider's own catalog, and declaring them
    here would force this bundle to restate settings it has no opinion about.
    """
    provider, model = split_model_reference(str(require_model_field(settings, "main", "model")))
    subagent_provider, subagent_model = split_model_reference(str(require_model_field(settings, "subagent", "model")))

    models: dict[str, object] = {
        model: {
            "settings": {
                "reasoningEffort": require_model_field(settings, "main", "effort"),
                "textVerbosity": require_model_field(settings, "main", "textVerbosity"),
            },
            "variants": [
                {
                    "id": SUBAGENT_VARIANT_ID,
                    "settings": {
                        "reasoningEffort": require_model_field(settings, "subagent", "effort"),
                        "textVerbosity": require_model_field(settings, "subagent", "textVerbosity"),
                    },
                }
            ],
        }
    }

    # A distinct sub-agent model needs its own catalog entry carrying the
    # sub-agent effort; the shared case is already covered by the variant above.
    if (subagent_provider, subagent_model) != (provider, model):
        if subagent_provider != provider:
            raise SystemExit(
                f"{SOURCE_MODEL_SETTINGS_PATH.relative_to(REPO_ROOT)}: opencode main and subagent "
                f"models must share a provider (got {provider!r} and {subagent_provider!r})"
            )
        models[subagent_model] = {
            "settings": {
                "reasoningEffort": require_model_field(settings, "subagent", "effort"),
                "textVerbosity": require_model_field(settings, "subagent", "textVerbosity"),
            }
        }

    return {provider: {"models": models}}


def build_agents_config(settings: dict[str, object]) -> dict[str, object]:
    """Emit per-agent model pins verbatim from the shared source of truth."""
    agent_models = validate_agent_models(settings["agents"])
    return {agent_id: {"model": reference} for agent_id, reference in agent_models.items()}


def build_opencode_config() -> dict[str, object]:
    model_settings = load_model_settings()
    # `instructions` is deliberately absent. V2 resolves it, but the bundle's
    # rules install as the global ~/.config/opencode/AGENTS.md, which V2 loads
    # first. A relative entry such as "AGENTS.md" would resolve from the
    # workspace and load the project's AGENTS.md again.
    config: dict[str, object] = {
        "$schema": "https://opencode.ai/config.json",
        "model": model_settings["main"]["model"],
        "plugins": DEFAULT_PLUGINS,
        # Runtime policy, not a model setting, so it stays out of models.json.
        "experimental": {"subagent_depth": DEFAULT_SUBAGENT_DEPTH},
        "agents": build_agents_config(model_settings),
        # OpenCode V2 uses the plural `providers` key (opencode.ai/v2/docs/config).
        "providers": build_provider_config(model_settings),
    }
    # No `mcp` block: the @yandy-r/ycc-opencode package registers the servers.
    return config


def build_agents_md() -> str:
    """Emit the bundle's rules file from ycc/settings/rules/CLAUDE.md.

    The source is tool-neutral, so it is copied verbatim behind a generated-file
    header; no product-name or filename substitution runs over it. Sourcing from
    the repo-root CLAUDE.md would leak this project's contributor guidance into
    every opencode user's global rules.
    """
    if not SOURCE_RULES_PATH.is_file():
        raise SystemExit(f"opencode plugin generator cannot find {SOURCE_RULES_PATH.relative_to(REPO_ROOT)}")

    header = (
        f"<!-- Generated from {SOURCE_RULES_PATH.relative_to(REPO_ROOT)} "
        "by scripts/generate_opencode_plugin.py — do not edit by hand. -->\n\n"
    )
    return header + SOURCE_RULES_PATH.read_text(encoding="utf-8")


def write_json(path: Path, payload: dict, *, dry_run: bool) -> None:
    serialized = json.dumps(payload, indent=2) + "\n"
    if dry_run:
        print(f"Would write {path.relative_to(REPO_ROOT)} ({len(serialized)} bytes)")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text(encoding="utf-8") == serialized:
        return
    path.write_text(serialized, encoding="utf-8")


def write_text(path: Path, content: str, *, dry_run: bool) -> None:
    if dry_run:
        print(f"Would write {path.relative_to(REPO_ROOT)} ({len(content)} bytes)")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text(encoding="utf-8") == content:
        return
    path.write_text(content, encoding="utf-8")


def write_all(dest_root: Path, dry_run: bool) -> dict[str, Path]:
    config_dest = dest_root / OPENCODE_CONFIG_PATH.relative_to(OPENCODE_PLUGIN_ROOT)
    agents_dest = dest_root / OPENCODE_AGENTS_MD_PATH.relative_to(OPENCODE_PLUGIN_ROOT)

    write_json(config_dest, build_opencode_config(), dry_run=dry_run)
    write_text(agents_dest, build_agents_md(), dry_run=dry_run)
    return {"config": config_dest, "rules": agents_dest}


def run_check() -> int:
    diffs: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        temp_root = Path(tmp)
        write_all(temp_root, dry_run=False)
        for rel in (
            OPENCODE_CONFIG_PATH.relative_to(OPENCODE_PLUGIN_ROOT),
            OPENCODE_AGENTS_MD_PATH.relative_to(OPENCODE_PLUGIN_ROOT),
        ):
            generated = temp_root / rel
            committed = OPENCODE_PLUGIN_ROOT / rel
            if not committed.exists():
                diffs.append(f"missing in repo: {rel}")
                continue
            if generated.read_bytes() != committed.read_bytes():
                diffs.append(f"drift: {rel}")

    if diffs:
        print(
            "opencode plugin metadata is out of date. Run: ./scripts/generate-opencode-plugin.sh",
            file=sys.stderr,
        )
        for diff in diffs:
            print(f"  {diff}", file=sys.stderr)
        return 1
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Exit 1 if generated output drifts")
    parser.add_argument("--dry-run", action="store_true", help="Print what would be written")
    args = parser.parse_args()

    if args.check:
        sys.exit(run_check())

    if args.dry_run:
        write_all(OPENCODE_PLUGIN_ROOT, dry_run=True)
        return

    OPENCODE_PLUGIN_ROOT.mkdir(parents=True, exist_ok=True)
    write_all(OPENCODE_PLUGIN_ROOT, dry_run=False)
    print(f"Wrote opencode plugin metadata under {OPENCODE_PLUGIN_ROOT}")


if __name__ == "__main__":
    main()
