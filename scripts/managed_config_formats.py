"""Config parsing for merge_managed_config.py: JSON/JSONC, YAML 1.2, sources and Cursor hooks checks."""

from __future__ import annotations

import json
import re
import tomllib
from collections.abc import Callable
from pathlib import Path
from typing import Any

from managed_config_core import MergeError


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


def load_yaml_destination(destination_path: Path) -> dict[str, Any]:
    if not destination_path.exists():
        return {}
    return load_yaml_config(destination_path.read_text(encoding="utf-8"), destination_path)


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
