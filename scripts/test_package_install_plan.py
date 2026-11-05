#!/usr/bin/env python3
"""Regression tests for model-derived package install plans."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from package_install_plan import parse_packages, plan_install
from package_model import PackageModelError, load_package_model

MODEL = load_package_model()
ROOT = Path(__file__).resolve().parent


def expect_error(packages: tuple[str, ...], target: str, needle: str) -> None:
    try:
        plan_install(MODEL, packages, (target,))
    except PackageModelError as exc:
        assert needle in str(exc), str(exc)
        return
    raise AssertionError("expected package rejection")


def test_closures() -> None:
    # Native routes: claude base/mcp/hooks are the ycc, ycc-mcp and ycc-hooks plugin installs;
    # codex base/mcp are ycc@ycc and ycc-mcp@ycc; cursor's base is the marketplace step; omp base
    # installs its native packages. settings/rules (and codex agents) are the installer fallback.
    for package, target, expected in (
        ("ycc", "claude", ("base", "settings", "rules")),
        ("ycc-mcp", "claude", ("settings", "rules", "mcp")),
        ("ycc-hooks", "claude", ("settings", "rules", "hooks")),
        ("ycc-all", "claude", ("base", "settings", "rules", "mcp", "hooks")),
        ("ycc", "codex", ("base", "agents", "settings", "rules")),
        ("ycc-mcp", "codex", ("agents", "settings", "rules", "mcp")),
        ("ycc", "cursor", ("base", "settings")),
        ("ycc-rules", "cursor", ("base", "settings")),
        ("ycc-mcp", "cursor", ("base", "settings")),
        ("ycc-hooks", "cursor", ("base", "settings")),
        ("ycc", "omp", ("base", "dedupe")),
        ("ycc-mcp", "omp", ("base",)),
        ("ycc-rules", "omp", ("base",)),
    ):
        plan = plan_install(MODEL, (package,), (target,)).targets[0]
        assert plan.steps == expected, (package, target, plan.steps)
        assert plan.skipped_components == (), (package, target, plan.skipped_components)
    assert parse_packages("ycc,ycc-mcp,ycc") == ("ycc", "ycc-mcp")
    both = plan_install(MODEL, ("ycc", "ycc-mcp", "ycc-rules"), ("omp",)).targets[0]
    assert (both.steps, both.skipped_components) == (("base", "dedupe"), ())


def test_fallback_never_delivers_hooks_or_mcp() -> None:
    # installer-fallback lists hooks on cursor; only a package providing hooks/mcp may select
    # their native carrier, so ycc alone never runs claude's hooks/mcp plugin installs.
    for target in ("claude", "codex"):
        steps = plan_install(MODEL, ("ycc",), (target,)).targets[0].steps
        assert "hooks" not in steps and "mcp" not in steps, (target, steps)


def test_rejections() -> None:
    for package, target, needle in (
        ("unknown", "claude", "unknown package"),
        ("installer-fallback", "claude", "internal modeling key"),
        ("ycc-agents", "claude", "deferred"),
        ("@yandy-r/ycc-opencode", "opencode", "opt-in"),
        ("ycc", "opencode", "not available"),
        ("ycc", "agents", "not available"),
        ("ycc-hooks", "codex", "excluded"),
        ("ycc-all", "codex", "not available"),
        ("ycc-mcp", "agents", "not available"),
        ("ycc-hooks", "omp", "is excluded or opt-in for target 'omp'"),
        ("ycc-all", "omp", "is excluded or opt-in for target 'omp'"),
        ("installer-fallback", "omp", "internal modeling key"),
    ):
        expect_error((package,), target, needle)
    all_plan = plan_install(MODEL, ("ycc",), ("claude", "cursor", "codex", "opencode", "agents"), skip_unsupported=True)
    assert tuple(t.target for t in all_plan.targets) == ("claude", "cursor", "codex")
    assert not any("carrier" in warning for warning in all_plan.warnings)


def test_parse_rejects_empty() -> None:
    for bad in ("", "ycc,", ",ycc", "ycc,,ycc-mcp"):
        try:
            parse_packages(bad)
        except PackageModelError:
            continue
        raise AssertionError(f"expected rejection of {bad!r}")


def test_cli() -> None:
    def shell(packages: str, targets: str) -> str:
        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "package_install_plan.py"),
                "--packages",
                packages,
                "--targets",
                targets,
                "--shell",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, result.stderr
        return result.stdout.strip()

    assert shell("ycc", "claude") == "target\tclaude\tbase,settings,rules"
    assert shell("ycc-rules", "cursor") == "target\tcursor\tbase,settings"


if __name__ == "__main__":
    test_closures()
    test_fallback_never_delivers_hooks_or_mcp()
    test_rejections()
    test_parse_rejects_empty()
    test_cli()
    print("test_package_install_plan: 5 tests passed")
