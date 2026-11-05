#!/usr/bin/env python3
"""Plan package installs over the validated model without changing catalogs or files."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass

from build_package_graph import package_sets
from package_model import PackageModel, PackageModelError, load_package_model

TARGETS = ("claude", "cursor", "codex", "opencode", "agents", "omp")
STEP_ORDER = ("base", "dedupe", "agents", "settings", "rules", "mcp", "hooks")
CARRIERS: dict[str, dict[str, str]] = {
    "claude": {
        "skills": "base",
        "agents": "base",
        "shared": "base",
        "commands": "base",
        "settings": "settings",
        "statusline": "settings",
        "rules": "rules",
        "instructions": "rules",
        "mcp": "mcp",
        "hooks": "hooks",
    },
    "codex": {
        "skills": "base",
        "shared": "base",
        "agents": "agents",
        "settings": "settings",
        "instructions": "rules",
        "rules": "rules",
        "mcp": "mcp",
    },
    # Cursor installs only through `agent plugin marketplace add` plus the interactive /plugins step,
    # so every packaged component rides that one base step; settings stay the installer fallback.
    "cursor": {
        "skills": "base",
        "agents": "base",
        "shared": "base",
        "rules": "base",
        "commands": "base",
        "hooks": "base",
        "mcp": "base",
        "settings": "settings",
    },
    # Each native OMP package is one `omp plugin install` (ycc-mcp ships its .mcp.json inside
    # the package, ycc-rules its flat rules/). Hooks never get an OMP carrier (ycc-hooks is
    # excluded on OMP: herdr ships its own integration). The installer-fallback payloads
    # (instructions, settings) are opt-in via --rules/--settings, so no package implies them.
    "omp": {
        "skills": "base",
        "agents": "base",
        "commands": "base",
        "shared": "base",
        "mcp": "base",
        "rules": "base",
    },
}


@dataclass(frozen=True)
class TargetPlan:
    """Complete installer steps and reported fallback gaps."""

    target: str
    steps: tuple[str, ...]
    skipped_components: tuple[str, ...] = ()


@dataclass(frozen=True)
class InstallPlan:
    """All targets validated before the shell performs any mutations."""

    targets: tuple[TargetPlan, ...]
    warnings: tuple[str, ...]


def parse_packages(csv: str) -> tuple[str, ...]:
    """Parse a strict CSV, rejecting empty tokens and preserving first occurrence."""
    values = csv.split(",")
    if any(not value.strip() for value in values):
        raise PackageModelError("--package contains an empty value")
    return tuple(dict.fromkeys(value.strip() for value in values))


def plan_install(
    model: PackageModel,
    packages: tuple[str, ...],
    targets: tuple[str, ...],
    *,
    skip_unsupported: bool = False,
) -> InstallPlan:
    """Expand model closures; a package's own components must all be deliverable.

    Explicit unsupported pairs fail before any write. Fallback hooks and MCP
    servers are never inherited: only a package providing them owns that
    native carrier. OMP inherits no fallback components at all (its
    --rules/--settings are opt-in).
    """
    known = {package.key: package for package in model.packages}
    for package in packages:
        if package not in known:
            raise PackageModelError(f"unknown package '{package}'")
        if package == "installer-fallback":
            raise PackageModelError("installer-fallback is an internal modeling key, not an installable package")
        if not any(
            entry.status == "included" and entry.mechanism == "native" and not entry.opt_in
            for entry in known[package].runtimes
        ):
            raise PackageModelError(f"package '{package}' is deferred, excluded, opt-in, or not a native package")
    sets, errors = package_sets(model)
    if errors:
        raise PackageModelError("; ".join(errors))
    plans: list[TargetPlan] = []
    warnings: list[str] = []
    for target in targets:
        if target not in TARGETS:
            raise PackageModelError(f"unknown target '{target}'")
        carriers = CARRIERS.get(target, {})
        components: set[str] = set()
        problem = ""
        for package in packages:
            entry = model.lookup(package, target)
            if entry is None:
                problem = f"package '{package}' is not available for target '{target}'"
            elif entry.status != "included" or entry.opt_in or entry.mechanism != "native":
                problem = f"package '{package}' is {entry.status} or opt-in for target '{target}'"
            else:
                pair = sets[f"{package}@{target}"]
                missing = sorted(set(pair.provides) - carriers.keys())
                if missing:
                    problem = (
                        f"package '{package}' cannot be fully delivered on target '{target}': "
                        f"{', '.join(missing)} have no installer carrier"
                    )
                else:
                    # The installer-fallback package never delivers hooks or MCP servers.
                    selected = set(pair.install_set) - ({"hooks", "mcp"} - set(pair.provides))
                    if target == "omp":
                        # OMP fallback payloads (instructions, settings) are opt-in via
                        # --rules/--settings, never package-implied.
                        selected &= set(pair.provides)
                    components.update(selected)
            if problem:
                break
        if problem:
            if not skip_unsupported:
                raise PackageModelError(problem)
            warnings.append(f"{problem} — skipping target '{target}'")
            continue
        steps = {carriers[component] for component in components if component in carriers}
        if target == "omp" and "skills" in components:
            # The default-on dedupe step hides the ycc skills OMP also loads from
            # other runtimes' dirs; only a package that ships skills can expose them.
            steps.add("dedupe")
        plans.append(
            TargetPlan(
                target,
                tuple(step for step in STEP_ORDER if step in steps),
                tuple(sorted(components - carriers.keys())),
            )
        )
    if not plans:
        raise PackageModelError("no selected target can install the requested packages")
    return InstallPlan(tuple(plans), tuple(warnings))


def main(argv: list[str] | None = None) -> int:
    """Emit JSON for tooling or tab-delimited records for the sourced shell helper."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packages")
    parser.add_argument("--targets")
    parser.add_argument("--skip-unsupported", action="store_true")
    parser.add_argument("--shell", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.packages is None or args.targets is None:
            parser.error("--packages and --targets are required")
        plan = plan_install(
            load_package_model(),
            parse_packages(args.packages),
            tuple(args.targets.split(",")),
            skip_unsupported=args.skip_unsupported,
        )
        if args.shell:
            for warning in plan.warnings:
                print(f"warning\t{warning}")
            for target in plan.targets:
                print(f"target\t{target.target}\t{','.join(target.steps)}")
                if target.skipped_components:
                    print(
                        f"warning\t{target.target}: package components "
                        f"{', '.join(target.skipped_components)} have no installer carrier — skipped"
                    )
        else:
            print(json.dumps(asdict(plan), indent=2))
    except PackageModelError as exc:
        print(f"package install: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
