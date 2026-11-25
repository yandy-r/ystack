#!/usr/bin/env python3
"""YAN-1121 lab driver and loopback-only fake Messages API (no real inference)."""

from __future__ import annotations

import argparse
import http.server
import json
import os
import re
import secrets
import signal
import subprocess
import threading
from pathlib import Path
from typing import Any

from claude_namespace_checks import (
    changed_entries,
    check,
    digest,
    negative_self_test,
    present,
    snapshot,
    tool_descriptions,
    verify_matrix,
)


def save(path: Path, data: Any) -> None:
    """Write deterministic, readable JSON evidence."""
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


class Lab:
    """Run bounded CLI probes; all child processes inherit the scrubbed lab env."""

    def __init__(self, root: Path, binary: str, version: str) -> None:
        self.root = root
        self.binary = binary
        self.version = version
        self.token = secrets.token_hex(5)
        self.prefix = "ns-" + self.token
        self.home = root / "bootstrap"
        self.results: list[dict[str, Any]] = []
        self.plan: dict[str, str] = {}
        self.requests: list[dict[str, Any]] = []
        self.lock = threading.Lock()
        self.installed: dict[str, str] = {}
        self.install_diagnostics: list[str] = []
        self.listing: list[dict[str, Any]] = []
        self.commands: dict[str, dict[str, Any]] = {}
        self.child: subprocess.Popen[str] | None = None
        (root / "logs").mkdir(parents=True)
        (root / "work").mkdir()
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), self.handler())
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def env(self) -> dict[str, str]:
        """Select fresh per-scenario config/cache; never consult the real HOME."""
        env = dict(os.environ)
        for var, part in {
            "HOME": "home",
            "CLAUDE_CONFIG_DIR": "claude",
            "XDG_CONFIG_HOME": "config",
            "XDG_DATA_HOME": "data",
            "XDG_CACHE_HOME": "cache",
            "XDG_STATE_HOME": "state",
            "XDG_RUNTIME_DIR": "runtime",
            "TMPDIR": "tmp",
        }.items():
            target = self.home / part
            target.mkdir(parents=True, exist_ok=True)
            env[var] = str(target)
        env.update(ANTHROPIC_BASE_URL=self.base, ANTHROPIC_API_KEY="sk-ant-dummy-namespace-spike")
        return env

    def run(self, label: str, args: list[str]) -> tuple[int, str]:
        """Capture argv/exit/stdout/stderr with a hard timeout and path sanitization."""
        p = subprocess.Popen(
            [self.binary, *args],
            cwd=self.root / "work",
            env=self.env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        self.child = p
        try:
            out, err = p.communicate(timeout=75)
            code = p.returncode
        except subprocess.TimeoutExpired:
            self.kill_child()
            out, err = p.communicate()
            code, err = 124, err + "\nTIMEOUT"
        except BaseException:
            self.kill_child()
            p.communicate()
            raise
        finally:
            self.kill_child()
            self.child = None
        self.commands[label] = {"exit": code, "stdout": out, "stderr": err}
        text = f"argv={json.dumps(args)}\nexit={code}\nstdout:\n{out}\nstderr:\n{err}\n"
        text = self.sanitize(text)
        (self.root / "logs" / f"{label}.log").write_text(text)
        with (self.root / "transcript.log").open("a") as handle:
            handle.write(f"\n[{label}]\n{text}")
        return code, out

    def kill_child(self) -> None:
        """Kill the CLI session process group, including inherited descendants."""
        if self.child is not None:
            try:
                os.killpg(self.child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def sanitize(self, text: str) -> str:
        """Remove ephemeral absolute paths and terminal escapes, never log headers."""
        return re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text.replace(str(self.root), "<LAB>"))

    def handler(self) -> type[http.server.BaseHTTPRequestHandler]:
        """Bind an HTTP handler to this lab; log bodies, NOT credential headers."""
        lab = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, _format: str, *args: Any) -> None:
                """Silence HTTP access logging (request bodies are recorded separately)."""

            def do_POST(self) -> None:
                """Respond with deterministic tools; never synthesize fixture markers."""
                self.connection.settimeout(10)
                try:
                    size = int(self.headers.get("Content-Length", ""))
                    if not 0 < size <= 32 * 1024 * 1024:
                        raise ValueError("invalid request size")
                    body = json.loads(self.rfile.read(size))
                    if not isinstance(body, dict):
                        raise ValueError("request must be an object")
                except (ValueError, OSError):
                    self.send_error(400, "Invalid request length or JSON")
                    return
                with lab.lock:
                    lab.requests.append({"path": self.path, "body": body})
                if "count_tokens" in self.path:
                    response = {"input_tokens": 100}
                else:
                    response = lab.response(body)
                raw = json.dumps(response).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

        return Handler

    def response(self, body: dict[str, Any]) -> dict[str, Any]:
        """Script parent Skill -> Agent/Task; subagent just ends with fixed text."""
        messages = body.get("messages", [])
        encoded = json.dumps(messages)
        plan = self.plan
        content: list[dict[str, Any]] = [{"type": "text", "text": "FAKE-END (not marker evidence)"}]
        parent = "HARNESS:" + plan.get("id", "never") in encoded
        if parent:
            stage = 0
            if '"id": "toolu_ns_agent"' in encoded:
                stage = 2
            elif '"id": "toolu_ns_skill"' in encoded:
                stage = 1
            if stage == 0:
                content = [
                    {"type": "tool_use", "id": "toolu_ns_skill", "name": "Skill", "input": {"skill": plan["skill"]}}
                ]
            elif stage == 1 and plan.get("agent"):
                names = [tool["name"] for tool in body.get("tools", [])]
                tool = "Agent" if "Agent" in names else "Task"
                content = [
                    {
                        "type": "tool_use",
                        "id": "toolu_ns_agent",
                        "name": tool,
                        "input": {
                            "description": "Namespace regression probe",
                            "prompt": "SUBAGENT:" + plan["id"],
                            "subagent_type": plan["agent"],
                        },
                    }
                ]
        return {
            "id": "msg_namespace_fake",
            "type": "message",
            "role": "assistant",
            "model": body.get("model", "fake"),
            "content": content,
            "stop_reason": "tool_use" if content[0]["type"] == "tool_use" else "end_turn",
            "usage": {"input_tokens": 100, "output_tokens": 10},
        }

    def plugin(self, directory: Path, name: str, payload: str) -> None:
        """Create markdown/JSON fixtures only, with body-only random marker bytes."""
        (directory / ".claude-plugin").mkdir(parents=True)
        save(directory / ".claude-plugin/plugin.json", {"name": name, "version": "0.0.1"})
        self.skill(directory, "probe", payload)
        (directory / "agents").mkdir()
        (directory / "agents/worker.md").write_text(
            "---\nname: worker\ndescription: Namespace payload probe\n---\n" + payload + "\n"
        )

    def skill(self, directory: Path, name: str, body: str) -> None:
        """Create one discoverable skill; marker is not in its description."""
        target = directory / "skills" / name
        target.mkdir(parents=True)
        (target / "SKILL.md").write_text(f"---\nname: {name}\ndescription: Namespace regression probe\n---\n{body}\n")

    def market(self, label: str, entries: list[tuple[str, str, str]]) -> Path:
        """Create local catalog; entry name and manifest name may intentionally differ."""
        directory = self.root / label
        (directory / ".claude-plugin").mkdir(parents=True)
        plugins = []
        for index, (entry, manifest, marker) in enumerate(entries):
            self.plugin(directory / f"p{index}", manifest, marker)
            plugins.append({"name": entry, "source": f"./p{index}"})
        save(
            directory / ".claude-plugin/marketplace.json",
            {
                "name": self.prefix + "-" + label,
                "owner": {"name": "spike"},
                "plugins": plugins,
            },
        )
        return directory

    def install(self, market: Path, entries: list[str], label: str) -> bool:
        """Use explicit user scope, local directory catalog, never plugin-dir shortcuts."""
        args = ["plugin", "marketplace", "add", str(market)]
        if "--scope" in self.add_help:
            args += ["--scope", "user"]
        code, _ = self.run(label + "-add", args)
        check(label + " marketplace add", 0, code)
        self.record_diagnostics(label + "-add")
        catalog = json.loads((market / ".claude-plugin/marketplace.json").read_text())
        sources = {p["name"]: p["source"] for p in catalog["plugins"]}
        for index, entry in enumerate(entries):
            plugin_id = entry + "@" + self.prefix + "-" + market.name
            code, _ = self.run(label + f"-install-{index}", ["plugin", "install", plugin_id, "--scope", "user"])
            check(label + f" install {index}", 0, code)
            self.record_diagnostics(label + f"-install-{index}")
            manifest = json.loads((market / sources[entry] / ".claude-plugin/plugin.json").read_text())
            self.installed[plugin_id] = manifest["name"]
        code, listing = self.run(label + "-list", ["plugin", "list", "--json"])
        check(label + " plugin list", 0, code)
        self.listing = json.loads(listing)
        return True

    def record_diagnostics(self, label: str) -> None:
        """Retain raw install/startup text for collision-diagnostic assertions."""
        self.install_diagnostics.append(self.commands[label]["stdout"] + self.commands[label]["stderr"])

    def probe(self, label: str, skill: str, agent: str = "", markers: dict[str, str] | None = None) -> None:
        """Inspect CLI-supplied tool results and subagent prompts, not fake model prose."""
        self.plan = {"id": label, "skill": skill, "agent": agent}
        self.requests = []
        code, out = self.run(
            label,
            [
                "-p",
                "HARNESS:" + label,
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
                "Skill,Task,Agent",
                "--allowedTools",
                "Skill,Task,Agent",
                "--permission-mode",
                "dontAsk",
            ],
        )
        bodies = list(self.requests)
        save(self.root / "logs" / f"{label}.requests.json", json.loads(self.sanitize(json.dumps(bodies))))
        events: list[dict[str, Any]] = []
        for line in out.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                continue
        init: dict[str, Any] = next((e for e in events if e.get("subtype") == "init"), {})
        parents: list[dict[str, Any]] = []
        children: list[dict[str, Any]] = []
        results: list[dict[str, Any]] = []
        for request in bodies:
            body = request["body"]
            if "count_tokens" in request["path"]:
                continue
            encoded = json.dumps(body.get("messages", []))
            (parents if "HARNESS:" + label in encoded else children).append(body)
            for message in body.get("messages", []):
                content = message.get("content", [])
                if isinstance(content, list):
                    results.extend(b for b in content if isinstance(b, dict) and b.get("type") == "tool_result")
        # Repeated conversation snapshots contain the same result multiple times.
        results = list({json.dumps(r, sort_keys=True): r for r in results}.values())
        marker_map = markers or {}
        evidence = {
            "label": label,
            "exit": code,
            "init": init,
            "parent_requests": len(parents),
            "subagent_requests": len(children),
            "tool_results": results,
            "markers_in_parent_messages": {
                k: v in json.dumps([b.get("messages", []) for b in parents]) for k, v in (markers or {}).items()
            },
            "markers_in_subagent_prompt": {
                k: v in json.dumps([{x: b.get(x) for x in ("system", "messages")} for b in children])
                for k, v in (markers or {}).items()
            },
            "expected_plugins": dict(self.installed),
            "plugin_list": self.listing,
            "install_diagnostics": list(self.install_diagnostics),
            "startup_diagnostics": self.commands[label]["stdout"] + self.commands[label]["stderr"],
            "first_parent_markers": present(json.dumps(parents[0]) if parents else "", marker_map),
            "tool_description_markers": present(tool_descriptions([r["body"] for r in bodies]), marker_map),
            "child_system_markers": present(json.dumps([b.get("system") for b in children]), marker_map),
            "child_messages_markers": present(json.dumps([b.get("messages") for b in children]), marker_map),
            "absent_name": agent if label == "missing-dispatch" else "",
            "status": "observed" if code == 0 and parents and init else "inconclusive",
        }
        self.results.append(evidence)
        save(self.root / "results.json", json.loads(self.sanitize(json.dumps(self.results))))
        print(
            self.version,
            label,
            evidence["status"],
            "parent=",
            evidence["markers_in_parent_messages"],
            "child=",
            evidence["markers_in_subagent_prompt"],
            flush=True,
        )

    def execute(self) -> None:
        """Exercise collision orders, distinct controls, cross dispatch and preloads."""
        _, help_text = self.run("help", ["--help"])
        _, self.add_help = self.run("help-add", ["plugin", "marketplace", "add", "--help"])
        _, install_help = self.run("help-install", ["plugin", "install", "--help"])
        self.run("help-list", ["plugin", "list", "--help"])
        required = [
            "--tools",
            "--allowedTools",
            "--permission-mode",
            "--setting-sources",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--output-format",
        ]
        if any(flag not in help_text for flag in required) or "--scope" not in install_help:
            save(self.root / "results.json", {"status": "inconclusive", "reason": "unsupported CLI flags"})
            raise SystemExit("INCONCLUSIVE: unsupported CLI flags")
        a, b, shared = [self.prefix + "-" + suffix for suffix in ("caller", "worker", "shared")]
        ma, mb = "PAYLOAD_A_" + secrets.token_hex(12), "PAYLOAD_B_" + secrets.token_hex(12)
        for kind in ("mismatched", "distinct", "shared-markets"):
            for order in ("ab", "ba"):
                label = kind + "-" + order
                self.home = self.root / ("config-" + label)
                self.installed, self.install_diagnostics = {}, []
                if kind == "shared-markets":
                    markets = [
                        self.market(label + "-" + tag, [(shared, shared, marker)])
                        for tag, marker in (("a", ma), ("b", mb))
                    ]
                    for i in ([0, 1] if order == "ab" else [1, 0]):
                        check(label + str(i) + " install", True, self.install(markets[i], [shared], label + str(i)))
                    names = [shared]
                else:
                    names = [a, b] if kind == "distinct" else [shared]
                    manifests = [a, b] if kind == "distinct" else [shared, shared]
                    market = self.market(label, [(a, manifests[0], ma), (b, manifests[1], mb)])
                    check(label + " install", True, self.install(market, [a, b] if order == "ab" else [b, a], label))
                for name in names:
                    self.probe(label + "-" + name, name + ":probe", name + ":worker", {"a": ma, "b": mb})
        # Anti-masking: caller has NO agents; worker has NO copy of caller preload.
        self.home = self.root / "config-cross"
        self.installed, self.install_diagnostics = {}, []
        market = self.market("cross", [(a, a, ma), (b, b, mb)])
        caller, worker = market / "p0", market / "p1"
        (caller / "agents/worker.md").unlink()
        (caller / "agents").rmdir()
        preload = "PRELOAD_" + secrets.token_hex(12)
        local = "LOCAL_PRELOAD_" + secrets.token_hex(12)
        self.skill(caller, "cross-preload", preload)
        self.skill(worker, "local-preload", local)
        for name, target in (
            ("same", "local-preload"),
            ("qualified", a + ":cross-preload"),
            ("bare", "cross-preload"),
            ("missing", a + ":absent"),
        ):
            (worker / f"agents/{name}.md").write_text(
                f"---\nname: {name}\ndescription: Namespace preload probe\nskills:\n  - {target}\n---\n" + mb + "\n"
            )
        for name, owner, agent in (
            ("cross-dispatch", caller, b + ":worker"),
            ("same-dispatch", worker, b + ":worker"),
            ("missing-dispatch", caller, self.prefix + ":absent"),
        ):
            self.skill(owner, name, f"Dispatch {agent} with the Agent/Task tool.\n" + ma)
        check("caller has no agents", False, (caller / "agents").exists())
        check("worker has no copied preload", False, (worker / "skills/cross-preload").exists())
        check("cross install", True, self.install(market, [a, b], "cross"))
        save(
            self.root / "fixture-proof.json",
            {
                "caller_has_agents": False,
                "worker_has_cross_preload": False,
                "names": {"caller": a, "worker": b},
                "markers": {"a": ma, "b": mb, "preload": preload, "local": local},
                "files": {str(p.relative_to(market)): digest(p) for p in sorted(market.rglob("*")) if p.is_file()},
            },
        )
        markers = {"caller": ma, "worker": mb, "preload": preload, "local": local}
        for name, plugin, agent in (
            ("cross-dispatch", a, b + ":worker"),
            ("same-dispatch", b, b + ":worker"),
            ("missing-dispatch", a, self.prefix + ":absent"),
        ):
            self.probe(name, plugin + ":" + name, agent, markers)
        for name in ("same", "qualified", "bare", "missing"):
            self.probe("preload-" + name, b + ":probe", b + ":" + name, markers)
        verify_matrix(self.results, self.version, self.prefix)
        marker = f"{self.version} assert_matrix: all expectations verified"
        with (self.root / "transcript.log").open("a") as handle:
            handle.write(f"\n{marker}\n")
        print(marker, flush=True)


def main() -> None:
    """Snapshot real config, compare snapshots, or execute one pinned CLI matrix."""
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    snap = sub.add_parser("snapshot")
    snap.add_argument("output", type=Path)
    snap.add_argument("paths", nargs="+")
    compare = sub.add_parser("compare")
    compare.add_argument("before", type=Path)
    compare.add_argument("after", type=Path)
    run = sub.add_parser("run")
    run.add_argument("root", type=Path)
    run.add_argument("binary")
    run.add_argument("version")
    args = parser.parse_args()
    if args.command == "snapshot":
        save(args.output, snapshot(args.paths))
    elif args.command == "compare":
        before, after = json.loads(args.before.read_text()), json.loads(args.after.read_text())
        changed = changed_entries(before, after)
        print("real-config hash/mtime unchanged:", not changed, "guarded entries:", len(before))
        if changed:
            raise SystemExit("Real config changed (possibly concurrent use): " + str(changed))
    else:
        os.setsid()
        (args.root.parent / "driver.pid").write_text(str(os.getpid()))
        negative_self_test()
        lab = Lab(args.root, args.binary, args.version)

        def terminate(signum: int, _frame: Any) -> None:
            """Unwind on outer timeout/signal; run() finally kills the CLI group."""
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
