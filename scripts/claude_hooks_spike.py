#!/usr/bin/env python3
"""YAN-1122 isolated hook matrix; reuse only neutral Lab runner/loopback transport."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
from pathlib import Path
from typing import Any

from claude_hooks_checks import negative_self_test, verify_matrix
from claude_namespace_checks import check, digest
from claude_namespace_fake_api import Lab, save

# Entirely new safe fixture: no production hook contents, sockets, or Git actions.
# O_APPEND single writes keep concurrent hook records independently parseable.
STUB = """#!/usr/bin/env python3
import hashlib, json, os, sys
from pathlib import Path
p = Path(__file__).resolve()
lab = Path(os.environ["HOOKS_LAB"]).resolve()
if not p.is_relative_to(lab):
    raise SystemExit("fixture outside lab")
if any(k.startswith("HERDR_") for k in os.environ):
    raise SystemExit("HERDR environment must be absent")
x = json.load(sys.stdin)
event = x.get("hook_event_name")
if event not in ("SessionStart", "WorktreeCreate"):
    raise SystemExit("unexpected hook event")
root = os.environ.get("CLAUDE_PLUGIN_ROOT", "")
if root and Path(root).resolve() != p.parent:
    raise SystemExit("plugin root does not identify expanded script path")
record = dict(event=event, marker=(p.parent / "marker").read_text().strip(),
    cwd=os.getcwd(), input_cwd=x.get("cwd"), session=x.get("session_id"),
    plugin_root=root, script=str(p), script_in_lab=True,
    sha256=hashlib.sha256(p.read_bytes()).hexdigest(), action=sys.argv[1:])
fd = os.open(os.environ["HOOKS_RECORDS"], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
os.write(fd, (json.dumps(record) + "\\n").encode())
os.close(fd)
if event == "WorktreeCreate":
    target = Path(os.environ["HOOKS_TARGET"]).resolve()
    if not target.is_relative_to(lab) or not (target / ".git").is_file():
        raise SystemExit("invalid fixture worktree")
    print(target)
"""


def git(cwd: Path, *args: str) -> None:
    """Run only explicit fixture Git operations with a hard timeout."""
    subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, timeout=20)


def hooks(command: str) -> dict[str, Any]:
    """Use the legacy SessionStart '*' matcher and unmatched WorktreeCreate shape."""
    return {
        "SessionStart": [{"matcher": "*", "hooks": [{"type": "command", "command": command + " session"}]}],
        "WorktreeCreate": [{"hooks": [{"type": "command", "command": command + " worktree"}]}],
    }


class HooksLab(Lab):
    """Hook-specific fixtures and checks, independent of namespace assertions."""

    def __init__(self, root: Path, binary: str, version: str) -> None:
        super().__init__(root, binary, version)
        self.record_file = root / "unused.jsonl"
        self.target = root / "unused"
        self.stub_hash = ""
        self.fixture_hashes: dict[str, str] = {}

    def env(self) -> dict[str, str]:
        """Add lab-only hook destinations; parent process is already env -i scrubbed."""
        env = super().env()
        env.update(HOOKS_LAB=str(self.root), HOOKS_RECORDS=str(self.record_file), HOOKS_TARGET=str(self.target))
        check("no HERDR inherited", [], sorted(key for key in env if key.startswith("HERDR_")))
        return env

    def response(self, body: dict[str, Any]) -> dict[str, Any]:
        """No tools or model inference: constant terminal reply, no evidence markers."""
        return {
            "id": "msg_hooks_fake",
            "type": "message",
            "role": "assistant",
            "model": body.get("model", "fake"),
            "content": [{"type": "text", "text": "FAKE-END"}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 100, "output_tokens": 10},
        }

    def fixture(self, directory: Path, marker: str) -> None:
        """Write and fingerprint the only executable hook in the lab."""
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "record.py").write_text(STUB)
        (directory / "marker").write_text(marker + "\n")
        for path in (directory / "record.py", directory / "marker"):
            self.fixture_hashes[str(path)] = digest(path)
        self.stub_hash = digest(directory / "record.py")

    def probe_hooks(self, scenario: str, kind: str) -> dict[str, Any]:
        """Launch a fresh session and record hook counts plus actual init cwd."""
        label = scenario + "-" + kind
        self.record_file = self.root / "logs" / (label + ".records.jsonl")
        self.requests = []
        args = [
            "-p",
            "HOOKS-PROBE:" + label,
            "--output-format",
            "stream-json",
            "--verbose",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--mcp-config",
            '{"mcpServers":{}}',
            "--setting-sources",
            "user",
            "--tools",
            "",
            "--permission-mode",
            "dontAsk",
        ]
        if kind == "wt":
            args += ["--worktree", label]
        code, out = self.run(label, args)
        records: list[dict[str, Any]] = []
        if self.record_file.exists():
            records = [json.loads(line) for line in self.record_file.read_text().splitlines()]
        events: list[dict[str, Any]] = []
        for line in out.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                continue
        init: dict[str, Any] = next((e for e in events if e.get("subtype") == "init"), {})
        cwd = Path(str(init.get("cwd", "/missing")))
        default = self.root / "work" / ".claude/worktrees" / label
        # Verify hook input/event/cwd and source immutability, not fake response text.
        for record in records:
            check(label + " immutable executable", self.stub_hash, record["sha256"])
            check(label + " input cwd matches executed cwd", record["cwd"], record["input_cwd"])
            action = "worktree" if record["event"] == "WorktreeCreate" else "session"
            check(label + " hook argv", [action], record["action"])
            check(label + " session matches init", init.get("session_id"), record["session"])
            if record["event"] == "WorktreeCreate":
                check(label + " WorktreeCreate runs in repo", str(self.root / "work"), record["cwd"])
            elif record["event"] == "SessionStart":
                check(label + " SessionStart cwd matches init", str(cwd), record["cwd"])
        row = {
            "exit": code,
            "records": records,
            "init": init,
            "requests": len([r for r in self.requests if "count_tokens" not in r["path"]]),
            "cwd": str(cwd),
            "cwd_is_repo": cwd == self.root / "work",
            "cwd_is_stub": cwd == self.target,
            "cwd_is_default_wt": cwd == default,
        }
        # Persist sanitized records and request summaries, never headers/full prompts.
        save(
            self.root / "logs" / (label + ".requests.json"),
            [
                {"path": r["path"], "model": r["body"].get("model"), "tools": len(r["body"].get("tools", []))}
                for r in self.requests
            ],
        )
        if self.record_file.exists():
            self.record_file.write_text(self.sanitize(self.record_file.read_text()))
        print(
            self.version,
            label,
            "exit",
            code,
            "records",
            [(r["event"], r["marker"]) for r in records],
            "cwd",
            self.sanitize(str(cwd)),
            flush=True,
        )
        return row

    def execute(self) -> None:
        """Install a real local-marketplace plugin in fresh configs for every row."""
        check("supported version", True, self.version in ("2.1.143", "2.1.300"))
        _, help_text = self.run("help", ["--help"])
        _, self.add_help = self.run("help-add", ["plugin", "marketplace", "add", "--help"])
        for flag in ("--worktree", "--tools", "--no-session-persistence", "--strict-mcp-config", "--setting-sources"):
            check("required flag " + flag, True, flag in help_text)
        git(self.root / "work", "init", "--initial-branch=fixture")
        (self.root / "work/fixture.txt").write_text("disposable fixture only\n")
        git(self.root / "work", "add", "fixture.txt")
        git(
            self.root / "work",
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "-m",
            "fixture",
        )
        for scenario in (
            "baseline",
            "settings-only",
            "plugin-only",
            "coexist-distinct",
            "coexist-exact",
            "post-migration",
            "disabled-plugin",
        ):
            self.home = self.root / ("config-" + scenario)
            self.env()
            self.target = self.root / ("target-" + scenario)
            git(self.root / "work", "worktree", "add", "--detach", str(self.target), "HEAD")
            legacy = self.root / ("legacy-" + scenario)
            self.fixture(legacy, "settings")
            market = self.root / ("market-" + scenario)
            plugin = market / "plugin"
            self.fixture(plugin, "plugin")
            (plugin / ".claude-plugin").mkdir()
            save(plugin / ".claude-plugin/plugin.json", {"name": "hooks-probe", "version": "0.0.1"})
            (plugin / "hooks").mkdir()
            save(plugin / "hooks/hooks.json", {"hooks": hooks('python3 "${CLAUDE_PLUGIN_ROOT}/record.py"')})
            (market / ".claude-plugin").mkdir()
            market_name = "hooks-spike-" + scenario
            save(
                market / ".claude-plugin/marketplace.json",
                {
                    "name": market_name,
                    "owner": {"name": "spike"},
                    "plugins": [{"name": "hooks-probe", "source": "./plugin"}],
                },
            )
            settings = Path(self.env()["CLAUDE_CONFIG_DIR"]) / "settings.json"
            plugin_id = "hooks-probe@" + market_name
            if scenario not in ("baseline", "settings-only"):
                args = ["plugin", "marketplace", "add", str(market)]
                if "--scope" in self.add_help:
                    args += ["--scope", "user"]
                code, _ = self.run(scenario + "-add", args)
                check(scenario + " marketplace add", 0, code)
                code, _ = self.run(scenario + "-install", ["plugin", "install", plugin_id, "--scope", "user"])
                check(scenario + " install", 0, code)
                if scenario == "disabled-plugin":
                    code, _ = self.run(scenario + "-disable", ["plugin", "disable", plugin_id, "--scope", "user"])
                    check(scenario + " disable", 0, code)
                code, listing = self.run(scenario + "-list", ["plugin", "list", "--json"])
                check(scenario + " list exit", 0, code)
                items = json.loads(listing)
                check(scenario + " listed plugin count", 1, len(items))
                check(scenario + " plugin ID", plugin_id, items[0].get("id"))
                check(scenario + " scope", "user", items[0].get("scope"))
                check(scenario + " enabled", scenario != "disabled-plugin", items[0].get("enabled"))
            config = json.loads(settings.read_text()) if settings.exists() else {}
            legacy_command = f'python3 "{legacy}/record.py"'
            plugin_command = f'python3 "{plugin}/record.py"'
            if scenario in ("settings-only", "coexist-distinct"):
                config["hooks"] = hooks(legacy_command)
            elif scenario == "coexist-exact":
                # Literal expansion of the plugin command to the installed source
                # path. Same script, args, marker; origin cannot be counted by marker.
                config["hooks"] = hooks(plugin_command)
            elif scenario == "post-migration":
                # Simulate removal, not just a second plugin-only label.
                config["hooks"] = hooks(legacy_command)
                save(settings, config)
                del config["hooks"]
            save(settings, config)
            before = {str(p): digest(p) for p in market.rglob("*") if p.is_file()}
            row = {"scenario": scenario, "ss": self.probe_hooks(scenario, "ss"), "wt": self.probe_hooks(scenario, "wt")}
            self.results.append(row)
            save(self.root / "results.json", json.loads(self.sanitize(json.dumps(self.results))))
            after = {str(p): digest(p) for p in market.rglob("*") if p.is_file()}
            check(scenario + " plugin files immutable", before, after)
        check("stubs immutable", self.fixture_hashes, {path: digest(Path(path)) for path in self.fixture_hashes})
        save(
            self.root / "fixture-proof.json",
            json.loads(
                self.sanitize(
                    json.dumps(
                        {
                            "only_hook_executable": "record.py (new safe stub)",
                            "stub_sha256": self.stub_hash,
                            "files": self.fixture_hashes,
                            "production_hooks_executed": False,
                        }
                    )
                )
            ),
        )
        verify_matrix(self.results, self.version)
        with (self.root / "transcript.log").open("a") as handle:
            handle.write(f"\n{self.version} assert_matrix: all expectations verified\n")


def main() -> None:
    """Run only beneath a fresh lab root; publish process group for outer cleanup."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("binary")
    parser.add_argument("version", choices=("2.1.143", "2.1.300"))
    args = parser.parse_args()
    check("root under /tmp/opencode", True, args.root.resolve().is_relative_to(Path("/tmp/opencode")))
    os.setsid()
    (args.root.parent / "driver.pid").write_text(str(os.getpid()))
    negative_self_test()
    lab = HooksLab(args.root, args.binary, args.version)

    def terminate(signum: int, _frame: Any) -> None:
        """Unwind on outer timeout/signal; Lab.run finally kills CLI process groups."""
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    try:
        lab.execute()
    finally:
        lab.kill_child()
        lab.server.shutdown()
        lab.server.server_close()


if __name__ == "__main__":
    main()
