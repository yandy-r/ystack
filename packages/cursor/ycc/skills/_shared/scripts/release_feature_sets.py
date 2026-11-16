#!/usr/bin/env python3
"""Group release commits into feature sets and compute the required semver bump.

A single ``feat:`` commit does not force a minor release. ``feat`` commits are
grouped into feature sets: the ``Feature-Set:`` trailer when present, otherwise
the Conventional Commits scope (``feat(worktree): ...`` -> ``worktree``),
otherwise ``unscoped``. A commit of any other type joins a set only through a
``Feature-Set:`` trailer. The maintainer names the sets that are complete and
user-visible with ``--complete``; only those require a minor.

A set whose ``feat`` commits shipped in an earlier (patch) release can still be
completed: name it with ``--complete`` and the helper finds it in the history
before the range (or add a ``Feature-Set:`` trailer to the finishing commit).

Required bump, first match wins:

- ``major``: any breaking change (``type!:``, ``type(scope)!:``, or a
  ``BREAKING CHANGE:`` / ``BREAKING-CHANGE:`` footer, merge commits included).
- ``minor``: at least one feature set is named complete.
- ``patch``: any other non-merge commit in the range.
- ``none``: the range has no non-merge commits.

The bump is a floor computed from commit markers only. Release policies may
require more (for example a renamed or removed public surface); apply those too.
Standard library only; the file is copied verbatim into every runtime bundle.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Any

HEADER_RE = re.compile(r"^(?P<type>[A-Za-z]+)(?:\((?P<scope>[^)]*)\))?(?P<bang>!)?:\s*(?P<desc>.+)$")
BREAKING_RE = re.compile(r"^BREAKING[ -]CHANGE:", re.MULTILINE)
TRAILER_RE = re.compile(r"^Feature-Set:\s*(?P<name>\S.*?)\s*$", re.MULTILINE | re.IGNORECASE)
UNSCOPED = "unscoped"
FIELD_SEP = "\x1f"
RECORD_SEP = "\x1e"


@dataclass
class Commit:
    sha: str
    subject: str
    kind: str
    breaking: bool
    feature_set: str | None


@dataclass
class Report:
    from_ref: str | None
    to_ref: str
    commits: list[Commit] = field(default_factory=list)
    complete: list[str] = field(default_factory=list)
    earlier: list[str] = field(default_factory=list)

    def feature_sets(self) -> dict[str, list[Commit]]:
        sets: dict[str, list[Commit]] = {}
        for commit in self.commits:
            if commit.feature_set is not None:
                sets.setdefault(commit.feature_set, []).append(commit)
        return sets

    def required_bump(self) -> str:
        if any(c.breaking for c in self.commits):
            return "major"
        if not any(c.kind != "merge" for c in self.commits):
            return "none"
        if self.complete:
            return "minor"
        return "patch"


def classify(sha: str, subject: str, body: str, *, merge: bool = False) -> Commit:
    """Classify one commit; a merge commit only contributes its breaking markers."""
    match = HEADER_RE.match(subject)
    breaking = bool(match and match.group("bang")) or bool(BREAKING_RE.search(body))
    if merge:
        return Commit(sha=sha, subject=subject, kind="merge", breaking=breaking, feature_set=None)
    kind = match.group("type").lower() if match else "other"
    trailer = TRAILER_RE.search(body)
    feature_set: str | None = trailer.group("name") if trailer else None
    if kind == "feat" and feature_set is None:
        feature_set = ((match.group("scope") or "").strip() if match else "") or UNSCOPED
    return Commit(sha=sha, subject=subject, kind=kind, breaking=breaking, feature_set=feature_set)


def git(repo: str, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=False)


def latest_tag(repo: str, to_ref: str) -> str | None:
    result = git(repo, "describe", "--tags", "--abbrev=0", to_ref)
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def read_commits(repo: str, rev_range: str) -> list[Commit]:
    fmt = f"%H{FIELD_SEP}%P{FIELD_SEP}%s{FIELD_SEP}%b{RECORD_SEP}"
    result = git(repo, "log", f"--format={fmt}", rev_range)
    if result.returncode != 0:
        raise ValueError(f"git log {rev_range} failed: {result.stderr.strip()}")
    commits: list[Commit] = []
    for record in result.stdout.split(RECORD_SEP):
        record = record.strip("\n")
        if not record:
            continue
        sha, parents, subject, body = (record.split(FIELD_SEP) + ["", "", ""])[:4]
        commits.append(classify(sha, subject, body, merge=len(parents.split()) > 1))
    return commits


def resolve_complete(
    requested: list[str], sets: dict[str, list[Commit]], earlier: set[str]
) -> tuple[list[str], list[str]]:
    """Validate ``--complete`` names. Return (complete, completed-from-earlier-releases).

    ``all`` selects every set in the range. A name not in the range is accepted
    when a set of that name shipped before the range start.
    """
    if requested == ["all"]:
        return sorted(sets), []
    unknown = [name for name in requested if name not in sets and name not in earlier]
    if unknown:
        known = ", ".join(sorted(sets)) or "(none)"
        raise ValueError(
            f"unknown feature set(s): {', '.join(unknown)}; sets in range: {known}; "
            "no set of that name before the range either"
        )
    names = sorted(set(requested))
    return names, [name for name in names if name not in sets]


def earlier_sets(repo: str, from_ref: str | None) -> set[str]:
    """Feature-set names from commits reachable from the range start."""
    if from_ref is None:
        return set()
    return {c.feature_set for c in read_commits(repo, from_ref) if c.feature_set is not None}


def to_json(report: Report) -> dict[str, Any]:
    def brief(c: Commit) -> dict[str, str]:
        return {"sha": c.sha[:12], "kind": c.kind, "subject": c.subject}

    counts: dict[str, int] = {"feat": 0, "fix": 0, "other": 0}
    for c in report.commits:
        if c.kind != "merge":
            counts[c.kind if c.kind in counts else "other"] += 1
    sets = [
        {"name": name, "complete": name in report.complete, "earlier": False, "commits": [brief(c) for c in commits]}
        for name, commits in sorted(report.feature_sets().items())
    ]
    sets += [{"name": name, "complete": True, "earlier": True, "commits": []} for name in report.earlier]
    return {
        "from": report.from_ref,
        "to": report.to_ref,
        "counts": counts,
        "breaking": [brief(c) for c in report.commits if c.breaking],
        "feature_sets": sets,
        "complete": report.complete,
        "required_bump": report.required_bump(),
    }


def to_text(report: Report) -> str:
    data = to_json(report)
    lines = [f"Range: {data['from'] or '(root)'}..{data['to']}"]
    counts = data["counts"]
    lines.append(f"Commits: {counts['feat']} feat, {counts['fix']} fix, {counts['other']} other")
    for item in data["breaking"]:
        lines.append(f"BREAKING {item['sha']} {item['subject']}")
    if data["feature_sets"]:
        lines.append("Feature sets:")
        for fs in data["feature_sets"]:
            if fs["earlier"]:
                lines.append(f"  {fs['name']} (shipped in earlier releases, complete)")
                continue
            feats = sum(1 for c in fs["commits"] if c["kind"] == "feat")
            mark = "complete" if fs["complete"] else "in progress"
            extra = len(fs["commits"]) - feats
            other = f" + {extra} other" if extra else ""
            lines.append(f"  {fs['name']} ({feats} feat{other}, {mark})")
            lines.extend(f"    {c['sha']} {c['subject']}" for c in fs["commits"])
    else:
        lines.append("Feature sets: none")
    lines.append(f"Required bump: {data['required_bump']}")
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="release-feature-sets.sh", description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=".", help="repository path (default: .)")
    parser.add_argument("--from", dest="from_ref", help="range start (default: latest tag reachable from --to)")
    parser.add_argument("--to", dest="to_ref", default="HEAD", help="range end (default: HEAD)")
    parser.add_argument(
        "--complete",
        default="",
        help="comma-separated feature sets that are complete and user-visible, or 'all'",
    )
    parser.add_argument("--format", choices=("json", "text"), default="json")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if git(args.repo, "rev-parse", "--git-dir").returncode != 0:
        print(f"release-feature-sets: not a git repository: {args.repo}", file=sys.stderr)
        return 1
    from_ref = args.from_ref or latest_tag(args.repo, args.to_ref)
    rev_range = f"{from_ref}..{args.to_ref}" if from_ref else args.to_ref
    try:
        report = Report(from_ref=from_ref, to_ref=args.to_ref, commits=read_commits(args.repo, rev_range))
        requested = [n.strip() for n in args.complete.split(",") if n.strip()]
        sets = report.feature_sets()
        earlier = earlier_sets(args.repo, from_ref) if any(n not in sets for n in requested) else set()
        report.complete, report.earlier = resolve_complete(requested, sets, earlier)
    except ValueError as exc:
        print(f"release-feature-sets: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(to_json(report), indent=2) if args.format == "json" else to_text(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
