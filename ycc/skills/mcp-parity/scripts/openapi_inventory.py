#!/usr/bin/env python3
"""Build an mcp-parity capability inventory from an OpenAPI 3.x document.

Usage: openapi_inventory.py SPEC [--exclude REGEX ...] [--no-default-excludes]

SPEC is JSON, or YAML when PyYAML is installed. Prints inventory JSON on stdout:
``{"schema": 1, "source": SPEC, "capabilities": [...], "excluded": [...]}``.
Operations are deterministic and sorted, so repeated runs on an unchanged spec
produce identical fingerprints. Exit 0 on success, 1 on invalid input.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

METHODS = ("get", "put", "post", "delete", "patch", "head", "options")
DEFAULT_EXCLUDES = (
    r"^/(api/)?(v\d+/)?(health|healthz|livez|readyz?|ping|metrics|status)/?$",
    r"/(oauth2?|\.well-known)(/|$)",
    r"/auth/(login|logout|callback|refresh|token)(/|$)",
    r"/webhooks?(/|$)",
)
ID_CLEAN_RE = re.compile(r"[^a-z0-9]+")
CAMEL_RE = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")
LEADING_VERBS = frozenset(
    "list get create update delete remove add set search patch replace upsert send run start stop".split()
)


class InputError(ValueError):
    """Raised for unreadable or non-OpenAPI input."""


def load_spec(path: Path) -> dict[str, Any]:
    """Load an OpenAPI document from JSON or YAML."""
    if not path.is_file():
        raise InputError(f"spec not found: {path}")
    text = path.read_text(encoding="utf-8")
    data: Any
    if path.suffix == ".json":
        try:
            data = json.loads(text)
        except json.JSONDecodeError as exc:
            raise InputError(f"{path} is not valid JSON: {exc}") from exc
    else:
        try:
            import yaml
        except ImportError as exc:
            raise InputError("PyYAML is required for YAML specs (python3 -m pip install --user pyyaml)") from exc
        try:
            data = yaml.safe_load(text)
        except yaml.YAMLError as exc:
            raise InputError(f"{path} is not valid YAML: {exc}") from exc
    if not isinstance(data, dict) or not isinstance(data.get("paths"), dict):
        raise InputError(f"{path} has no OpenAPI 'paths' object")
    if not str(data.get("openapi", "")).startswith("3"):
        raise InputError(f"{path} is not OpenAPI 3.x (swagger 2 is unsupported; convert it first)")
    return data


def _ref_name(ref: str) -> str:
    return ref.rsplit("/", 1)[-1]


def type_name(schema: Any, depth: int = 0) -> str:
    """Return a short, stable type spelling for a schema."""
    if not isinstance(schema, dict):
        return "any"
    if "$ref" in schema:
        return _ref_name(str(schema["$ref"]))
    for combo in ("oneOf", "anyOf", "allOf"):
        if isinstance(schema.get(combo), list) and depth < 3:
            sep = " & " if combo == "allOf" else " | "
            return sep.join(type_name(s, depth + 1) for s in schema[combo])
    kind = schema.get("type")
    if isinstance(kind, list):
        kind = "|".join(str(k) for k in kind)
    if kind == "array":
        return f"{type_name(schema.get('items'), depth + 1)}[]"
    if kind == "object" or (kind is None and "properties" in schema):
        return "object"
    if "enum" in schema and isinstance(schema["enum"], list):
        return "enum(" + ",".join(str(v) for v in schema["enum"]) + ")"
    return str(kind or "any")


def _resolve(spec: dict[str, Any], obj: Any) -> Any:
    """Resolve one local $ref (parameters, requestBodies, responses)."""
    if isinstance(obj, dict) and isinstance(obj.get("$ref"), str) and obj["$ref"].startswith("#/"):
        node: Any = spec
        for part in obj["$ref"][2:].split("/"):
            node = node.get(part) if isinstance(node, dict) else None
        return node if node is not None else obj
    return obj


def make_id(method: str, path: str, op: dict[str, Any]) -> str:
    """Derive a durable capability id: operationId when present, else area.verb from the path."""
    op_id = op.get("operationId")
    if isinstance(op_id, str) and op_id.strip():
        words = [w for w in ID_CLEAN_RE.sub(".", CAMEL_RE.sub(".", op_id.strip()).lower()).split(".") if w]
        if len(words) > 1 and words[0] in LEADING_VERBS:
            words = [*words[1:], words[0]]  # listActivity -> activity.list
        return ".".join(words)[:128] or "op"
    segments = [s for s in path.strip("/").split("/") if s and not s.startswith("{")]
    segments = [s for s in segments if not re.fullmatch(r"(api|v\d+)", s)]
    by_id = path.rstrip("/").endswith("}")
    verb = {
        "get": "get" if by_id else "list",
        "post": "create",
        "put": "replace",
        "patch": "update",
        "delete": "delete",
    }.get(method, method)
    base = ".".join(ID_CLEAN_RE.sub("-", s.lower()).strip("-") for s in segments) or "root"
    return f"{base}.{verb}"[:128]


def _inputs(spec: dict[str, Any], path_item: dict[str, Any], op: dict[str, Any]) -> dict[str, Any]:
    params: dict[tuple[str, str], Any] = {}
    for raw in [*path_item.get("parameters", []), *op.get("parameters", [])]:
        param = _resolve(spec, raw)
        if isinstance(param, dict) and isinstance(param.get("name"), str):
            params[(str(param.get("in", "query")), param["name"])] = param
    inputs: dict[str, dict[str, str]] = {}
    for (where, name), param in sorted(params.items()):
        if where == "header" or where == "cookie":
            continue
        optional = "" if param.get("required") or where == "path" else "?"
        inputs.setdefault(where, {})[name] = type_name(param.get("schema")) + optional
    body = _resolve(spec, op.get("requestBody"))
    if isinstance(body, dict) and isinstance(body.get("content"), dict):
        media: Any = body["content"].get("application/json") or next(iter(body["content"].values()), {})
        optional = "" if body.get("required") else "?"
        inputs["body"] = {"type": type_name(media.get("schema") if isinstance(media, dict) else None) + optional}
    return inputs


def _outputs(spec: dict[str, Any], op: dict[str, Any]) -> str:
    responses = op.get("responses")
    if not isinstance(responses, dict):
        return ""
    for code in sorted(str(c) for c in responses):
        if not code.startswith("2"):
            continue
        resp = _resolve(spec, responses.get(code) or responses.get(int(code) if code.isdigit() else code))
        content = resp.get("content") if isinstance(resp, dict) else None
        if not isinstance(content, dict) or not content:
            return "none" if code == "204" else ""
        media = content.get("application/json") or next(iter(content.values()))
        return type_name(media.get("schema") if isinstance(media, dict) else None)
    return ""


def auth_schemes(spec: dict[str, Any], op: dict[str, Any]) -> list[str] | None:
    """Security scheme names for an operation; None when the spec declares none."""
    security = op.get("security", spec.get("security"))
    if not isinstance(security, list):
        return None
    return sorted({name for req in security if isinstance(req, dict) for name in req})


def auth_class(schemes: list[str] | None) -> str:
    """Collapse scheme names to the inventory auth classes."""
    if schemes is None:
        return "unspecified"
    if not schemes:
        return "public"
    if any("admin" in name.lower() for name in schemes):
        return "admin"
    return "user"


def build_inventory(spec: dict[str, Any], excludes: list[str], source: str = "") -> dict[str, Any]:
    """Return inventory JSON for every non-excluded, non-deprecated operation."""
    patterns = [re.compile(p) for p in excludes]
    caps: list[dict[str, Any]] = []
    excluded: list[dict[str, str]] = []
    seen: dict[str, int] = {}
    for path in sorted(spec["paths"]):
        path_item = spec["paths"][path]
        if not isinstance(path_item, dict):
            continue
        for method in METHODS:
            op = path_item.get(method)
            if not isinstance(op, dict):
                continue
            operation = f"{method.upper()} {path}"
            if method in ("head", "options"):
                excluded.append({"operation": operation, "reason": "protocol method"})
                continue
            if op.get("deprecated") is True:
                excluded.append({"operation": operation, "reason": "deprecated"})
                continue
            hit = next((p.pattern for p in patterns if p.search(path)), None)
            if hit:
                excluded.append({"operation": operation, "reason": f"matches {hit}"})
                continue
            cid = make_id(method, path, op)
            seen[cid] = seen.get(cid, 0) + 1
            if seen[cid] > 1:
                cid = f"{cid}.{seen[cid]}"
            tags = op.get("tags") if isinstance(op.get("tags"), list) else []
            segments = [s for s in path.strip("/").split("/") if s and not s.startswith("{")]
            area = str(tags[0]) if tags else (segments[-1] if segments else "root")
            caps.append(
                {
                    "id": cid,
                    "kind": "tool",
                    "operation": operation,
                    "summary": str(op.get("summary") or op.get("description") or "").strip().split("\n")[0][:200],
                    "area": ID_CLEAN_RE.sub("-", area.lower()).strip("-") or "root",
                    "inputs": _inputs(spec, path_item, op),
                    "outputs": _outputs(spec, op),
                    "mutating": method != "get",
                    "destructive": method == "delete",
                    "auth": auth_class(auth_schemes(spec, op)),
                    "authSchemes": auth_schemes(spec, op) or [],
                    "surface": "rest",
                    "source": source,
                }
            )
    return {"schema": 1, "source": source, "capabilities": caps, "excluded": excluded}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("spec", help="OpenAPI 3.x document (.json, or .yaml/.yml with PyYAML)")
    parser.add_argument("--exclude", action="append", default=[], help="extra path regex to exclude (repeatable)")
    parser.add_argument("--no-default-excludes", action="store_true", help="keep health/auth/webhook paths")
    args = parser.parse_args(argv)
    try:
        excludes = [*([] if args.no_default_excludes else DEFAULT_EXCLUDES), *args.exclude]
        for pattern in excludes:
            try:
                re.compile(pattern)
            except re.error as exc:
                raise InputError(f"invalid --exclude regex {pattern!r}: {exc}") from exc
        spec = load_spec(Path(args.spec))
        print(json.dumps(build_inventory(spec, excludes, args.spec), indent=2))
        return 0
    except InputError as exc:
        print(f"openapi_inventory: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
