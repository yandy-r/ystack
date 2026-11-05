#!/usr/bin/env python3
"""Structural validation for Codex marketplace catalogs and plugin sources.

Imported by the Codex generator, validator and legacy cleanup; it has no CLI.
Source tags and fields mirror Codex's marketplace parser.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit

SOURCE_FIELDS: dict[str, frozenset[str]] = {
    "local": frozenset({"path"}),
    "url": frozenset({"url", "path", "ref", "sha"}),
    "git-subdir": frozenset({"url", "path", "ref", "sha"}),
    "npm": frozenset({"package", "version", "registry"}),
}
REQUIRED_SOURCE_FIELDS: dict[str, frozenset[str]] = {
    "local": frozenset({"path"}),
    "url": frozenset({"url"}),
    "git-subdir": frozenset({"url", "path"}),
    "npm": frozenset({"package"}),
}


def _fail(message: str) -> ValueError:
    return ValueError(f"marketplace validation failed: {message}")


def _string_field(source: dict[str, Any], tag: str, field: str) -> str:
    value = source.get(field)
    if not isinstance(value, str) or not value.strip():
        raise _fail(f"{tag}: field '{field}' must be a non-empty string")
    return value


def _validate_relative_path(path: str, *, local: bool) -> None:
    tag = "local" if local else "git"
    if local and path in {".", "./"}:
        return
    if local and not path.startswith("./"):
        raise _fail("local: path must start with ./")
    relative = path.removeprefix("./")
    parts = [part for part in relative.split("/") if part]
    if not parts or "\x00" in path or Path(relative).is_absolute() or any(part in {".", ".."} for part in parts):
        raise _fail(f"{tag}: path must stay within the {'marketplace' if local else 'repository'} root")


def _validate_git_shape(tag: str, source: dict[str, Any]) -> None:
    url = _string_field(source, tag, "url").strip()
    # Classify every relative prefix before considering owner/repo shorthand:
    # ../escape.git otherwise looks like a two-segment GitHub repository.
    relative = url.startswith(("./", ".\\", "../", "..\\"))
    if relative and ".." in url.replace("\\", "/").split("/"):
        raise _fail(f"{tag}: relative url must stay within the marketplace root")
    shorthand = url.split("/")
    github = (
        len(shorthand) == 2
        and all(
            segment and all(ch.isascii() and (ch.isalnum() or ch in "-_.") for ch in segment) for segment in shorthand
        )
        and bool(shorthand[1].removesuffix(".git"))
    )
    prefixes = ("http://", "https://", "./", ".\\", "file://", "/", "ssh://")
    if not (url.startswith(prefixes) or (url.startswith("git@") and ":" in url) or github):
        raise _fail(f"{tag}: url is not a supported git source")
    if source.get("path") is not None:
        _validate_relative_path(_string_field(source, tag, "path").strip(), local=False)
    for selector in ("ref", "sha"):
        if source.get(selector) is not None and not isinstance(source[selector], str):
            raise _fail(f"{tag}: field '{selector}' must be a string")


def _validate_npm_shape(source: dict[str, Any]) -> None:
    package = _string_field(source, "npm", "package").strip()
    scoped = package.startswith("@")
    segments = package[1:].split("/") if scoped else package.split("/")
    valid = len(segments) == (2 if scoped else 1) and all(
        segment
        and segment not in {".", ".."}
        and (scoped or segment[0] not in "._")
        and all(ch.isascii() and (ch.isalnum() or ch in "-_.") for ch in segment)
        for segment in segments
    )
    if not valid:
        raise _fail("npm: invalid package name")
    if source.get("version") is not None:
        version = _string_field(source, "npm", "version").strip()
        if version in {".", ".."} or any(ch in version for ch in "/\\:"):
            raise _fail("npm: version must use the registry")
    if source.get("registry") is not None:
        raw_registry = _string_field(source, "npm", "registry").strip()
        if "?" in raw_registry or "#" in raw_registry:
            raise _fail("npm: registry must be an HTTPS URL without credentials, query or fragment")
        registry = urlsplit(raw_registry)
        authority = raw_registry.partition("//")[2].split("/", 1)[0]
        if any(ch.isspace() or ord(ch) < 32 or ord(ch) == 127 for ch in authority):
            raise _fail("npm: registry must name a valid host")
        host = unquote(registry.hostname or "")
        if any(ch.isspace() or ord(ch) < 32 or ch in " #%/<>?@\\^|" for ch in host):
            raise _fail("npm: registry must name a valid host")
        if registry.scheme != "https" or not registry.hostname or registry.username or registry.password:
            raise _fail("npm: registry must be an HTTPS URL without credentials, query or fragment")
        try:
            _ = registry.port
        except ValueError:
            # urlsplit only raises when the authority is inspected: reject the
            # unparseable ports (``notaport``) and out-of-range ports (``99999``).
            raise _fail("npm: registry port must be a valid port number") from None


def validate_marketplace_source(source: object, *, plugin_name: str = "<unknown>") -> dict[str, Any]:
    """Validate a Codex-supported marketplace source object without changing it."""
    if not isinstance(source, dict):
        raise _fail(f"{plugin_name}: source must be an object")
    tag = source.get("source")
    if not isinstance(tag, str):
        raise _fail(f"{plugin_name}: source tag must be a string")
    allowed = SOURCE_FIELDS.get(tag)
    if allowed is None:
        raise _fail(f"{plugin_name}: unsupported source tag '{tag}'")
    required = REQUIRED_SOURCE_FIELDS[tag]
    missing = sorted(field for field in required if source.get(field) is None)
    if missing:
        raise _fail(f"{plugin_name}: missing required source fields: {missing}")
    unsupported = sorted(set(source) - allowed - {"source"})
    if unsupported:
        raise _fail(f"{plugin_name}: unsupported source fields: {unsupported}")
    if tag == "local":
        _validate_relative_path(_string_field(source, tag, "path"), local=True)
    elif tag in {"url", "git-subdir"}:
        _validate_git_shape(tag, source)
    else:
        _validate_npm_shape(source)
    return source


def validate_marketplace_catalog(catalog: object) -> dict[str, Any]:
    """Validate structural Codex marketplace catalog shape for fixture diagnostics."""
    if not isinstance(catalog, dict):
        raise _fail("catalog must be a JSON object")
    name = catalog.get("name")
    if not isinstance(name, str) or not name.strip():
        raise _fail("catalog: name must be a non-empty string")
    interface = catalog.get("interface")
    if interface is not None and not isinstance(interface, dict):
        raise _fail("catalog: interface must be an object when present")
    if isinstance(interface, dict) and interface.get("displayName") is not None:
        _string_field(interface, "catalog interface", "displayName")
    plugins = catalog.get("plugins")
    if not isinstance(plugins, list):
        raise _fail("catalog: plugins must be a list")
    names: set[str] = set()
    for index, plugin in enumerate(plugins):
        if not isinstance(plugin, dict):
            raise _fail(f"plugins[{index}]: expected an object")
        plugin_name = plugin.get("name")
        if not isinstance(plugin_name, str) or not plugin_name.strip():
            raise _fail(f"plugins[{index}]: name must be a non-empty string")
        if plugin_name in names:
            raise _fail(f"plugins[{index}]: duplicate plugin name '{plugin_name}'")
        names.add(plugin_name)
        if plugin.get("category") is not None:
            _string_field(plugin, plugin_name, "category")
        policy = plugin.get("policy", {})
        if not isinstance(policy, dict):
            raise _fail(f"{plugin_name}: policy must be an object")
        for field, values in (
            ("installation", {"NOT_AVAILABLE", "AVAILABLE", "INSTALLED_BY_DEFAULT"}),
            ("authentication", {"ON_INSTALL", "ON_USE"}),
        ):
            if field in policy and (not isinstance(policy[field], str) or policy[field] not in values):
                raise _fail(f"{plugin_name}: invalid policy {field}")
        validate_marketplace_source(plugin.get("source"), plugin_name=plugin_name)
    return catalog
