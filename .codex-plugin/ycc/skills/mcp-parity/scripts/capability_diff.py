#!/usr/bin/env python3
"""Diff an app's capability inventory against a stored MCP parity manifest.

Deterministic core of the mcp-parity skill: the research phase writes a
capability inventory (JSON), the Linear manifest Document holds the previous
run's manifest, and this script decides what changed so a re-run only touches
the delta.

Subcommands:
  init     Print an empty manifest (create mode).
  extract  Print the manifest JSON embedded in a manifest Document body.
  cover    Set inventory mcpCovered flags from researcher coverage results.
  diff     Classify inventory capabilities against the manifest.
  apply    Merge the inventory and this run's recorded Linear results into the
           next manifest, emitted as JSON or as a complete Document body.

Exit 0 on success, 1 on invalid input. Results go to stdout, errors to stderr.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

SCHEMA = 1
KINDS = frozenset({"tool", "resource", "prompt"})
STATUSES = frozenset({"planned", "done", "covered", "removed", "declined"})
# Issue-map only: the tracked issue was deleted or archived; forget its key.
MAP_STATUSES = STATUSES | {"unlinked"}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
# Visible heading, not an HTML comment: tracker markdown round-trips may drop comments.
MANIFEST_HEADING = "## Manifest data"
FENCE_RE = re.compile(r"```json[ \t]*\r?\n(.*?)\r?\n```", re.DOTALL)
# Fields whose change means the MCP contract must change. Summary, source
# location, area, and surface are presentation-only.
CONTRACT_FIELDS = ("kind", "operation", "inputs", "outputs", "mutating", "destructive", "auth")
ISSUE_FIELDS = frozenset({"issue", "milestone", "priority", "status", "applied"})


class InputError(ValueError):
    """Raised for malformed inventory, manifest, or issue-map input."""


def _normalize(value: Any) -> Any:
    if isinstance(value, str):
        return " ".join(value.split())
    if isinstance(value, dict):
        return {str(k).strip(): _normalize(v) for k, v in sorted(value.items())}
    if isinstance(value, list):
        return [_normalize(v) for v in value]
    return value


def contract(cap: dict[str, Any]) -> dict[str, Any]:
    """Return the normalized contract fields of a capability."""
    out = {k: _normalize(cap.get(k)) for k in CONTRACT_FIELDS}
    out["mutating"] = bool(out["mutating"])
    out["destructive"] = bool(out["destructive"])
    out["auth"] = out["auth"] or "unspecified"
    out["inputs"] = out["inputs"] if out["inputs"] is not None else {}
    out["outputs"] = out["outputs"] if out["outputs"] is not None else ""
    return out


def fingerprint(cap: dict[str, Any]) -> str:
    """Return a stable 16-hex fingerprint of a capability's normalized contract."""
    canonical = json.dumps(contract(cap), sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16]


def _shape_key(cap: dict[str, Any]) -> str:
    """Fingerprint without the operation, used to spot moved routes."""
    return fingerprint({**contract(cap), "operation": "-"})


def empty_manifest(repo: str | None = None) -> dict[str, Any]:
    manifest: dict[str, Any] = {"schema": SCHEMA, "foundation": {}, "capabilities": {}}
    if repo:
        manifest["repo"] = repo
    return manifest


def validate_inventory(data: Any) -> list[dict[str, Any]]:
    """Validate an inventory document and return its capability list."""
    if not isinstance(data, dict) or not isinstance(data.get("capabilities"), list):
        raise InputError("inventory must be an object with a 'capabilities' array")
    seen: set[str] = set()
    caps: list[dict[str, Any]] = []
    for i, cap in enumerate(data["capabilities"]):
        if not isinstance(cap, dict):
            raise InputError(f"capability #{i} is not an object")
        cid = cap.get("id")
        if not isinstance(cid, str) or not ID_RE.match(cid):
            raise InputError(f"capability #{i} has invalid id {cid!r} (want {ID_RE.pattern})")
        if cid in seen:
            raise InputError(f"duplicate capability id {cid!r}")
        seen.add(cid)
        if cap.get("kind") not in KINDS:
            raise InputError(f"capability {cid!r} kind must be one of {sorted(KINDS)}")
        if not isinstance(cap.get("operation"), str) or not cap["operation"].strip():
            raise InputError(f"capability {cid!r} needs a non-empty 'operation'")
        for flag in ("mutating", "destructive"):
            if not isinstance(cap.get(flag), bool):
                raise InputError(f"capability {cid!r} needs boolean {flag!r}")
        caps.append(cap)
    return caps


PARAM_RE = re.compile(r"\{[^}/]*\}|:[A-Za-z_][A-Za-z0-9_]*|<[^>/]*>|\[[^\]/]*\]")


def operation_key(operation: str) -> str:
    """Normalize an operation for matching: method case, path-param syntax, trailing slash."""
    parts = operation.split()
    if len(parts) >= 2 and parts[0].isalpha():
        method, path = parts[0].upper(), " ".join(parts[1:])
    else:
        method, path = "", " ".join(parts)
    path = PARAM_RE.sub("{}", path)
    if len(path) > 1:
        path = path.rstrip("/")
    return f"{method} {path}".strip()


def cover(caps: list[dict[str, Any]], covered: Any) -> tuple[list[dict[str, Any]], list[Any]]:
    """Set mcpCovered from researcher 2's {operation, mcpName, inputsMatch} entries."""
    if not isinstance(covered, list):
        raise InputError("coverage must be a JSON array of {operation, mcpName, inputsMatch}")
    by_key: dict[str, dict[str, Any]] = {}
    unmapped: list[Any] = []
    for entry in covered:
        if not isinstance(entry, dict) or not isinstance(entry.get("operation"), str):
            raise InputError(f"coverage entry {entry!r} needs a string 'operation'")
        key = operation_key(entry["operation"])
        if key.lower() in ("", "none", "n/a"):
            unmapped.append(entry)  # MCP-only tool with no app operation
            continue
        prior = by_key.get(key)
        # Several tools on one operation: covered if any of them matches.
        if prior is None or (entry.get("inputsMatch") is True and prior.get("inputsMatch") is not True):
            by_key[key] = entry
    used: set[str] = set()
    out: list[dict[str, Any]] = []
    for cap in caps:
        key = operation_key(cap["operation"])
        hit = by_key.get(key)
        if hit:
            used.add(key)
        out.append({**cap, "mcpCovered": bool(hit and hit.get("inputsMatch") is True)})
    mcp_only = unmapped + [e for k, e in by_key.items() if k not in used]
    return out, mcp_only


def validate_manifest(data: Any) -> dict[str, Any]:
    """Validate a manifest and return it with defaults filled in."""
    if not isinstance(data, dict):
        raise InputError("manifest must be a JSON object")
    if data.get("schema") != SCHEMA:
        raise InputError(f"unsupported manifest schema {data.get('schema')!r} (want {SCHEMA})")
    caps = data.get("capabilities", {})
    if not isinstance(caps, dict):
        raise InputError("manifest 'capabilities' must be an object keyed by id")
    for cid, entry in caps.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("fingerprint"), str):
            raise InputError(f"manifest entry {cid!r} needs a string 'fingerprint'")
        if entry.get("status") not in STATUSES:
            raise InputError(f"manifest entry {cid!r} has invalid status {entry.get('status')!r}")
    foundation = data.get("foundation", {})
    if not isinstance(foundation, dict):
        raise InputError("manifest 'foundation' must be an object")
    return {**data, "capabilities": caps, "foundation": foundation}


def extract_manifest(body: str) -> dict[str, Any] | None:
    """Return the manifest under the Manifest data heading of a Document body, if any."""
    start = body.find(MANIFEST_HEADING)
    if start < 0:
        return None
    match = FENCE_RE.search(body, start)
    if match is None:
        raise InputError(f"'{MANIFEST_HEADING}' has no ```json block after it")
    try:
        parsed = json.loads(match.group(1))
    except json.JSONDecodeError as exc:
        raise InputError(f"manifest JSON is invalid: {exc}") from exc
    return validate_manifest(parsed)


def check_repo(manifest: dict[str, Any], repo: str | None) -> None:
    """Refuse to diff a manifest that belongs to a different repository."""
    stored = manifest.get("repo")
    if repo and stored and str(stored).lower() != repo.lower():
        raise InputError(f"manifest belongs to {stored!r}, not {repo!r}; wrong Project?")


def refreshed(manifest: dict[str, Any], issues: dict[str, Any] | None) -> dict[str, Any]:
    """Return manifest capabilities with this run's State refresh statuses applied."""
    known: dict[str, Any] = {k: dict(v) for k, v in manifest["capabilities"].items()}
    for cid, update in (issues or {}).items():
        if cid == "_foundation" or not isinstance(update, dict) or cid not in known:
            continue
        status = update.get("status")
        if status == "unlinked":
            known.pop(cid)  # its issue is gone; plan it like a new capability
        elif status in STATUSES:
            known[cid]["status"] = status
    return known


def diff(manifest: dict[str, Any], caps: list[dict[str, Any]], issues: dict[str, Any] | None = None) -> dict[str, Any]:
    """Classify each inventory capability against the (refreshed) manifest."""
    known = refreshed(manifest, issues)
    result: dict[str, list[Any]] = {
        "added": [],
        "changed": [],
        "removed": [],
        "revived": [],
        "unchanged": [],
        "covered": [],
    }
    current: set[str] = set()
    for cap in caps:
        cid = cap["id"]
        current.add(cid)
        fp = fingerprint(cap)
        entry = known.get(cid)
        item: dict[str, Any] = {"id": cid, "fingerprint": fp, "capability": cap}
        if entry is None:
            result["covered" if cap.get("mcpCovered") is True else "added"].append(item)
        elif entry["status"] == "covered" and cap.get("mcpCovered") is not True and not entry.get("issue"):
            # A pre-existing MCP server no longer covers it.
            result["added"].append(item)
        elif entry["status"] == "removed":
            result["revived"].append({**item, "issue": entry.get("issue")})
        elif entry["fingerprint"] != fp:
            result["changed"].append(
                {
                    **item,
                    "issue": entry.get("issue"),
                    "status": entry["status"],
                    "oldFingerprint": entry["fingerprint"],
                    "oldContract": entry.get("contract"),
                    "newContract": contract(cap),
                }
            )
        else:
            result["unchanged"].append(cid)
    for cid in sorted(known):
        if cid not in current and known[cid]["status"] != "removed":
            entry = known[cid]
            result["removed"].append({"id": cid, "issue": entry.get("issue"), "status": entry["status"]})
    for key in ("added", "changed", "revived", "covered"):
        result[key].sort(key=lambda x: x["id"])
    result["unchanged"].sort()
    renames = _possible_renames(known, result["removed"], result["added"] + result["covered"])
    counts = {k: len(v) for k, v in result.items()}
    tracked = sum(1 for e in known.values() if e["status"] != "removed")
    return {
        "schema": SCHEMA,
        "counts": counts,
        "noop": not any(n for k, n in counts.items() if k != "unchanged"),
        "removedRatio": round(counts["removed"] / tracked, 3) if tracked else 0.0,
        "possibleRenames": renames,
        **result,
    }


def _possible_renames(
    known: dict[str, Any], removed: list[dict[str, Any]], fresh: list[dict[str, Any]]
) -> list[dict[str, str]]:
    """Pair removed and new ids that look like the same capability."""
    pairs: list[dict[str, str]] = []
    for gone in removed:
        old = known[gone["id"]].get("contract")
        if not isinstance(old, dict):
            continue
        for new in fresh:
            cap = new["capability"]
            if _normalize(cap["operation"]) == old.get("operation"):
                pairs.append({"from": gone["id"], "to": new["id"], "reason": "same operation"})
            elif (old.get("inputs") or old.get("outputs")) and _shape_key(cap) == _shape_key(old):
                pairs.append({"from": gone["id"], "to": new["id"], "reason": "same contract, new operation"})
    return pairs


def apply(
    manifest: dict[str, Any],
    caps: list[dict[str, Any]],
    issues: dict[str, Any],
    meta: dict[str, Any],
    partial: bool = False,
) -> dict[str, Any]:
    """Return the next manifest after this run's Linear writes.

    Only work recorded in ``issues`` is committed: a changed contract keeps its
    old fingerprint and a vanished capability keeps its status until the map
    records it (``applied``, a new ``issue``, or a ``status``). With ``partial``,
    new capabilities without an issue key are left out so they re-diff as added.
    """
    known: dict[str, Any] = manifest["capabilities"]
    current = {cap["id"] for cap in caps}
    for key, value in issues.items():
        if key == "_foundation":
            if not isinstance(value, dict):
                raise InputError("issue map '_foundation' must be an object")
            continue
        if not isinstance(value, dict):
            raise InputError(f"issue map entry {key!r} must be an object")
        if key not in current and key not in known:
            raise InputError(f"issue map entry {key!r} is not a known capability id")
        unknown = set(value) - ISSUE_FIELDS
        if unknown:
            raise InputError(f"issue map entry {key!r} has unknown fields {sorted(unknown)}")
        if "status" in value and value["status"] not in MAP_STATUSES:
            raise InputError(f"issue map entry {key!r} has invalid status {value['status']!r}")

    out_caps: dict[str, Any] = {}
    for cap in caps:
        cid = cap["id"]
        prev: dict[str, Any] = dict(known.get(cid, {}))
        update: dict[str, Any] = issues.get(cid, {})
        if update.get("status") == "unlinked":
            prev, update = {"history": _unlink(prev).get("history", [])}, _without_status(update)
        recorded = _recorded(update)
        entry = _merge_issue(prev, update)
        if not prev.get("fingerprint"):
            if cap.get("mcpCovered") is True and not entry.get("issue"):
                entry.setdefault("status", "covered")
            elif not entry.get("issue"):
                if partial:
                    continue
                raise InputError(f"new capability {cid!r} has no issue key in the issue map")
            entry.setdefault("status", "planned")
        elif prev["status"] in ("removed", "covered") and "status" not in update:
            if prev["status"] == "covered" and cap.get("mcpCovered") is True and not update.get("issue"):
                pass  # still covered
            elif update.get("issue"):
                entry["status"] = "planned"
            elif partial:
                out_caps[cid] = prev  # revived or uncovered, issue not created yet
                continue
            else:
                raise InputError(f"capability {cid!r} needs a new issue key in the issue map")
        fp = fingerprint(cap)
        if not prev.get("fingerprint") or fp == prev.get("fingerprint") or recorded:
            entry["fingerprint"] = fp
            entry["contract"] = contract(cap)
        entry["operation"] = cap["operation"]
        if cap.get("area"):
            entry["area"] = cap["area"]
        out_caps[cid] = {k: entry[k] for k in sorted(entry) if entry[k] not in (None, [])}
    for cid, prev in known.items():
        if cid in current:
            continue
        update = issues.get(cid, {})
        unlinked = update.get("status") == "unlinked"
        if unlinked:
            prev, update = _unlink(prev), _without_status(update)
        entry = _merge_issue(dict(prev), update)
        if unlinked or _recorded(update) or update.get("status") == "removed" or prev["status"] == "removed":
            entry["status"] = "removed"
        out_caps[cid] = {k: entry[k] for k in sorted(entry) if entry[k] not in (None, [])}

    foundation = {**manifest.get("foundation", {}), **issues.get("_foundation", {})}
    nxt: dict[str, Any] = {"schema": SCHEMA}
    for key in ("project", "repo", "commit", "generatedAt"):
        value = meta.get(key) if meta.get(key) is not None else manifest.get(key)
        if value is not None:
            nxt[key] = value
    nxt["foundation"] = dict(sorted(foundation.items()))
    nxt["capabilities"] = dict(sorted(out_caps.items()))
    return nxt


def _unlink(prev: dict[str, Any]) -> dict[str, Any]:
    """Drop a deleted/archived issue key, keeping it in history."""
    entry = {k: v for k, v in prev.items() if k != "issue"}
    if prev.get("issue"):
        entry["history"] = [*prev.get("history", []), prev["issue"]]
    return entry


def _without_status(update: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in update.items() if k != "status"}


def _recorded(update: dict[str, Any]) -> bool:
    """True when this run's Linear action for the id succeeded (status refreshes do not count)."""
    return update.get("applied") is True or bool(update.get("issue"))


def _merge_issue(prev: dict[str, Any], update: dict[str, Any]) -> dict[str, Any]:
    entry = dict(prev)
    new_issue = update.get("issue")
    if new_issue and prev.get("issue") and new_issue != prev["issue"]:
        entry["history"] = [*prev.get("history", []), prev["issue"]]
    for field in ("issue", "milestone", "priority", "status"):
        if field in update:
            entry[field] = update[field]
    return entry


def render_document(manifest: dict[str, Any]) -> str:
    """Render the manifest Document body: a readable table plus the JSON block."""
    caps: dict[str, Any] = manifest["capabilities"]
    live = {k: v for k, v in caps.items() if v.get("status") != "removed"}
    exposed = sum(1 for v in live.values() if v.get("status") in ("covered", "done"))
    lines = [
        "# MCP parity manifest",
        "",
        "Maintained by the mcp-parity skill. Do not edit the JSON block by hand; re-run the skill instead.",
        "",
        f"- Repository: {manifest.get('repo', 'unknown')}",
        f"- Commit: {manifest.get('commit', 'unknown')}",
        f"- Generated: {manifest.get('generatedAt', 'unknown')}",
        f"- Parity: {exposed}/{len(live)} capabilities exposed over MCP",
        "",
        "| Capability | Operation | Status | Issue |",
        "| --- | --- | --- | --- |",
    ]
    for cid, entry in caps.items():
        op = str(entry.get("operation", "")).replace("|", "\\|")
        lines.append(f"| `{cid}` | {op} | {entry.get('status', '')} | {entry.get('issue', '')} |")
    lines += ["", MANIFEST_HEADING, "", "```json", json.dumps(manifest, indent=2), "```", ""]
    return "\n".join(lines)


def _load_json(path: str, what: str) -> Any:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise InputError(f"{what} file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise InputError(f"{what} {path} is not valid JSON: {exc}") from exc


def _load_manifest(path: str) -> dict[str, Any]:
    """Load a manifest from a .json file or a Document body (any other suffix)."""
    p = Path(path)
    if not p.is_file():
        raise InputError(f"manifest file not found: {path}")
    if p.suffix == ".json":
        return validate_manifest(_load_json(path, "manifest"))
    found = extract_manifest(p.read_text(encoding="utf-8"))
    if found is None:
        raise InputError(f"{path} has no '{MANIFEST_HEADING}' section")
    return found


def _optional_object(path: str | None, what: str) -> dict[str, Any]:
    if path is None or not Path(path).exists():
        return {}
    data = _load_json(path, what)
    if not isinstance(data, dict):
        raise InputError(f"{what} must be a JSON object")
    return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_init = sub.add_parser("init", help="print an empty manifest")
    p_init.add_argument("--repo", help="owner/repo the manifest belongs to")
    p_cover = sub.add_parser("cover", help="set mcpCovered on an inventory from coverage results")
    p_cover.add_argument("--inventory", required=True, help="capability inventory JSON")
    p_cover.add_argument("--covered", required=True, help="JSON array of {operation, mcpName, inputsMatch}")
    p_extract = sub.add_parser("extract", help="print the manifest JSON from a Document body")
    p_extract.add_argument("--doc", required=True, help="Document body (markdown) file")
    for name in ("diff", "apply"):
        p = sub.add_parser(name)
        p.add_argument("--manifest", required=True, help="previous manifest: .json or a Document body")
        p.add_argument("--inventory", required=True, help="current capability inventory JSON")
        p.add_argument("--repo", help="owner/repo; refuses a manifest recorded for another repo")
        p.add_argument("--adopt-repo", action="store_true", help="accept a renamed/transferred repo and re-key")
        p.add_argument("--issues", help="JSON map of capability id (or _foundation) to recorded results")
        if name == "apply":
            p.add_argument("--meta", help="JSON object with project/repo/commit/generatedAt")
            p.add_argument("--partial", action="store_true", help="leave unrecorded new capabilities out")
            p.add_argument("--format", choices=("json", "markdown"), default="json")
    args = parser.parse_args(argv)
    try:
        if args.cmd == "init":
            print(json.dumps(empty_manifest(args.repo), indent=2))
            return 0
        if args.cmd == "cover":
            data = _load_json(args.inventory, "inventory")
            caps, mcp_only = cover(validate_inventory(data), _load_json(args.covered, "coverage"))
            print(json.dumps({**data, "capabilities": caps, "mcpOnly": mcp_only}, indent=2))
            return 0
        if args.cmd == "extract":
            doc = Path(args.doc)
            if not doc.is_file():
                raise InputError(f"file not found: {args.doc}")
            found = extract_manifest(doc.read_text(encoding="utf-8"))
            if found is None:
                raise InputError(f"{args.doc} has no '{MANIFEST_HEADING}' section")
            print(json.dumps(found, indent=2))
            return 0
        manifest = _load_manifest(args.manifest)
        if not args.adopt_repo:
            check_repo(manifest, args.repo)
        caps = validate_inventory(_load_json(args.inventory, "inventory"))
        issues = _optional_object(args.issues, "issue map")
        if args.cmd == "diff":
            print(json.dumps(diff(manifest, caps, issues), indent=2))
            return 0
        meta = _optional_object(args.meta, "meta")
        if args.repo and (args.adopt_repo or meta.get("repo") is None):
            meta["repo"] = args.repo
        nxt = apply(manifest, caps, issues, meta, partial=args.partial)
        print(render_document(nxt) if args.format == "markdown" else json.dumps(nxt, indent=2))
        return 0
    except InputError as exc:
        print(f"capability_diff: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
