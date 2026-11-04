#!/usr/bin/env python3
"""Opt-in YAN-1125: isolated OpenCode V2 registration and instruction evidence."""

from __future__ import annotations

import base64
import hashlib
import json
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from opencode_config_hook_checks import PASSWORD, Loopback, check, fixtures, free_port, snapshot, stop, track


class Api:
    """Direct HTTP equivalent of `opencode api --server <private URL>`."""

    def __init__(self, port: int, directory: Path) -> None:
        """Bind to the private server port and the resolved scenario location."""
        self.base = f"http://127.0.0.1:{port}"
        self.directory = directory
        self.headers = {"Authorization": "Basic " + base64.b64encode(f"opencode:{PASSWORD}".encode()).decode()}

    def request(
        self, path: str, body: dict[str, Any] | None = None, scoped: bool = False, method: str | None = None
    ) -> Any:
        """Fetch JSON or submit a JSON body to the private OpenCode server.

        The method defaults to GET, or POST when a body is given.
        """
        query = "?" + urllib.parse.urlencode({"location[directory]": str(self.directory)}) if scoped else ""
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(
            self.base + path + query,
            data=data,
            headers={**self.headers, "Content-Type": "application/json"},
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            raise SystemExit(f"FAIL {path}: HTTP {error.code}: {error.read()[:500]!r}") from error

    def items(self, component: str) -> list[dict[str, Any]]:
        """List one registry from the location-scoped response envelope."""
        response = self.request(f"/api/{component}", scoped=True)
        if response.get("location", {}).get("directory") != str(self.directory):
            raise SystemExit(f"FAIL wrong location: {response.get('location')}")
        if not isinstance(response.get("data"), list):
            raise SystemExit(f"FAIL invalid {component} envelope")
        return response["data"]


def run_env(lab: Path) -> dict[str, str]:
    """Return the allowlisted environment for CLI probes and scenario servers."""
    env = {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "HOME": str(lab / "home"),
        "TMPDIR": str(lab / "tmp"),
        "OPENCODE_DB": str(lab / "data/opencode.db"),
        "OPENCODE_SERVER_PASSWORD": PASSWORD,
        "OPENCODE_DISABLE_MODELS_FETCH": "1",
        "OPENCODE_DISABLE_FFF": "1",
        "OPENCODE_FILEWATCHER_DISABLE": "1",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
    }
    for name in ("CONFIG", "DATA", "STATE", "CACHE", "RUNTIME"):
        env[f"XDG_{name}_HOME" if name != "RUNTIME" else "XDG_RUNTIME_DIR"] = str(lab / name.lower())
    return env


class Scenario:
    """Fresh process/config/project for each scenario; bounded process group."""

    def __init__(self, lab: Path, binary: str, name: str, config: dict[str, Any]) -> None:
        """Write scenario config files and start its private server process group."""
        self.lab, self.name = lab, name
        self.work = lab / "work" / name
        self.work.mkdir(parents=True)
        target = lab / "config/opencode/opencode.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps({"update": "disable", "snapshots": False, **config}, indent=2))
        # Retain a fixture-only config copy; no user config is copied.
        (self.work / "config-used.json").write_text(target.read_text())
        self.api = Api(free_port(), self.work)
        self.log = (lab / f"server-{name}.log").open("wb")
        self.process = subprocess.Popen(
            [
                "timeout",
                "-k",
                "3",
                "120",
                binary,
                "serve",
                "--hostname",
                "127.0.0.1",
                "--port",
                self.api.base.rsplit(":", 1)[1],
                "--print-logs",
            ],
            cwd=self.work,
            env=run_env(lab),
            stdout=self.log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        track(lab, self.process.pid, True)

    def ready(self) -> None:
        """Wait for the scenario's built-in skill config plugin to appear."""
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise SystemExit(f"FAIL {self.name} server exited")
            try:
                # HTTP readiness is not plugin readiness. V2 initially serves empty arrays.
                plugins = self.api.items("plugin")
                if any(p.get("id") == "opencode.config.skill" for p in plugins):
                    return
            except (OSError, TimeoutError):
                pass
            time.sleep(0.25)
        raise SystemExit(f"FAIL {self.name}: runtime did not finish booting")

    def close(self) -> None:
        """Terminate the scenario process group and close its server log."""
        stop(self.lab, self.process)
        self.log.close()

    def capture(self) -> dict[str, Any]:
        """Capture plugin, agent, command, skill, and MCP inventories."""
        data = {key: self.api.items(key) for key in ("plugin", "agent", "command", "skill", "mcp")}
        (self.lab / f"{self.name}.json").write_text(json.dumps(data, indent=2))
        return data


def has_marker(data: Any, marker: str) -> bool:
    """Return whether the encoded payload contains the run's marker."""
    return marker in json.dumps(data)


def matrix(lab: Path, binary: str) -> dict[str, Any]:
    """Execute and verify the V2 registration, skills, and V1 negative scenarios."""
    marker = "yan1125-" + secrets.token_hex(6)
    print(f"marker={marker}")
    fx = fixtures(lab, marker)
    loop = Loopback(fx["catalog"])
    loop.start()
    results: dict[str, Any] = {"marker": marker}
    configs: dict[str, dict[str, Any]] = {
        "baseline": {},
        "configured-file-negative": {"plugins": [(fx["plugin"] / "index.js").as_uri()]},
        "v2-plugin": {"plugins": [fx["plugin"].as_uri()]},
        "config-skills-dir": {"skills": [str(fx["skill"].parent.parent)]},
        "config-skills-url": {"skills": [loop.url + "/"]},
        "v1-negative": {"plugins": [{"package": fx["v1"].as_uri(), "options": {}}]},
    }
    try:
        for name, config in configs.items():
            sc = Scenario(lab, binary, name, config)
            try:
                sc.ready()
                if name == "baseline":
                    spec = sc.api.request("/openapi.json")
                    (lab / "openapi.json").write_text(json.dumps(spec, indent=2))
                    for component in ("plugin", "agent", "command", "skill", "mcp"):
                        params = spec["paths"][f"/api/{component}"]["get"]["parameters"]
                        check(
                            f"{component} location deepObject",
                            True,
                            any(p.get("name") == "location" and p.get("style") == "deepObject" for p in params),
                        )
                data = sc.capture()
                custom = [p for p in data["plugin"] if p["source"]["type"] != "builtin"]
                if name in ("baseline", "configured-file-negative"):
                    expected = "baseline" if name == "baseline" else "bare file plugin"
                    check(f"{expected} custom plugins absent", [], custom)
                    for key in data:
                        check(f"{expected} {key} marker absent", False, has_marker(data[key], marker))
                    results[name] = {"custom_plugins": 0, "markers": 0}
                elif name == "v2-plugin":
                    check(
                        "V2 plugin active",
                        ["active"],
                        [p["state"]["status"] for p in custom if p.get("id") == "yan1125.probe"],
                    )
                    agent = [a for a in data["agent"] if a["id"] == "yan1125-agent"]
                    check(
                        "V2 agent exact",
                        [("Yan1125 Agent", marker + " agent", "subagent")],
                        [(a["name"], a["description"], a["mode"]) for a in agent],
                    )
                    command = [c for c in data["command"] if c["name"] == "yan1125-cmd"]
                    check("V2 command exact", [marker + " command"], [c["description"] for c in command])
                    check("V2 skill listed", 1, len([s for s in data["skill"] if s["id"] == "yan1125-skill"]))
                    check("V2 skill marker", True, has_marker(data["skill"], marker + " skill"))
                    check("V2 mcp listed", 1, len([m for m in data["mcp"] if m["name"] == marker + "-mcp"]))
                    skill = next(s for s in data["skill"] if s["id"] == "yan1125-skill")
                    check("plugin skill path", str(fx["skill"]), skill["path"])
                    check(
                        "inline content",
                        marker + " inline; Read support.md relative to the skill base.",
                        skill["content"],
                    )
                    check("relative support exists", True, (Path(skill["path"]).parent / "support.md").is_file())
                    mcp = next(m for m in data["mcp"] if m["name"] == marker + "-mcp")
                    check("MCP status observed", True, mcp["status"]["status"] in ("connected", "pending", "failed"))
                    results[name] = {
                        "plugin": "active",
                        "agent": True,
                        "command": True,
                        "skill": True,
                        "mcp": mcp["status"],
                    }
                elif name.startswith("config-skills"):
                    skill_id = "dir-skill" if name.endswith("dir") else "yan1125-url"
                    selected = [s for s in data["skill"] if s["id"] == skill_id]
                    check(name + " listed", 1, len(selected))
                    check(name + " marker", True, has_marker(selected, marker))
                    path = Path(selected[0]["path"])
                    if name.endswith("url"):
                        # Cache root is hashed per source URL, not named for the skill.
                        check("catalog cache under lab", True, path.is_relative_to(lab / "cache/opencode/skills"))
                        check(
                            "cached support content",
                            marker + " cached support\n",
                            (path.parent / "support.md").read_text(),
                        )
                    results[name] = {"skill": skill_id, "path": str(path.relative_to(lab))}
                else:
                    check("V1 failed inventory", 1, len(custom))
                    check("V1 status failed", "failed", custom[0]["state"]["status"])
                    error = custom[0]["state"]["error"]
                    check("V1 definition error", True, "default definition" in error)
                    for key in ("agent", "command", "skill", "mcp"):
                        check(f"V1 {key} marker absent", False, has_marker(data[key], marker))
                    results[name] = {"state": custom[0]["state"], "markers": 0}
                print(f"observed: {name} {json.dumps(results[name])}")
            finally:
                sc.close()
        results["instructions"] = instructions(lab, binary, marker, fx, loop)
        (lab / "catalog-requests.json").write_text(json.dumps(loop.gets, indent=2))
        return results
    finally:
        loop.close()


def instructions(lab: Path, binary: str, marker: str, fx: dict[str, Path], loop: Loopback) -> dict[str, Any]:
    """Verify hook/discovered instructions and absent config instructions via a fake provider."""
    file = lab / "fixtures/instructions.md"
    file.write_text(marker + " config-instruction\n")
    config = {
        "instructions": [str(file)],
        "plugins": [fx["plugin"].as_uri()],
        "model": "spike/probe",
        "providers": {
            "spike": {
                "package": "@ai-sdk/openai-compatible",
                "settings": {"baseURL": loop.url + "/v1", "apiKey": "dummy-spike-key"},
                "models": {
                    "probe": {
                        "name": "Probe",
                        "limit": {"context": 32000, "output": 512},
                        "capabilities": {"tools": False, "input": ["text"], "output": ["text"]},
                    }
                },
            }
        },
    }
    sc = Scenario(lab, binary, "instructions", config)
    try:
        # Positive control distinguishes a missing instruction entry from no instructions pipeline.
        (sc.work / "AGENTS.md").write_text(marker + " discovered-agents\n")
        sc.ready()
        sc.capture()
        created = sc.api.request(
            "/api/session",
            {
                "title": "Spike",
                "location": {"directory": str(sc.work)},
                "model": {"providerID": "spike", "id": "probe"},
            },
        )
        sid = created["data"]["id"]
        check("session location", str(sc.work), created["data"]["location"]["directory"])
        sc.api.request(f"/api/session/{sid}/prompt", {"text": "Reply OK only.", "skills": [{"id": "yan1125-skill"}]})
        deadline = time.monotonic() + 25
        while not loop.bodies and time.monotonic() < deadline:
            time.sleep(0.25)
        check("fake provider captured request", True, bool(loop.bodies))
        bodies = list(loop.bodies)
        (lab / "provider-bodies.json").write_text(json.dumps(bodies, indent=2))
        # One request must carry the hook and discovered-AGENTS positives in its own system message.
        primary = [
            b
            for b in bodies
            if any(
                m.get("role") in ("system", "developer")
                and marker + " hook-instruction" in str(m.get("content"))
                and marker + " discovered-agents" in str(m.get("content"))
                for m in b.get("messages", [])
            )
        ]
        check("one request has hook + discovered AGENTS in system", True, bool(primary))
        # Absence is asserted over EVERY captured request body, not just the positive one.
        check("config instructions ignored (all bodies)", False, has_marker(bodies, marker + " config-instruction"))
        check(
            "skill base output", True, has_marker(primary, "Base directory for this skill: " + str(fx["skill"].parent))
        )
        check("skill inline body reached request", True, has_marker(primary, marker + " inline;"))
        return {
            "requests": len(bodies),
            "hook_system": True,
            "discovered_AGENTS": True,
            "config_instructions": False,
            "skill_base": True,
        }
    finally:
        sc.close()


def main() -> None:
    """Run all scenarios and verify installed binary and untouched runtime surfaces."""
    lab, binary, home = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    before = snapshot(home)
    try:
        # Explicit negative self-test, then verify the supported installed version.
        try:
            check("negative self-test", "expected", "wrong")
        except SystemExit:
            print("ok: check() negative self-test failed closed")
        else:
            raise SystemExit("FAIL check() did not terminate")
        for args in (["--version"], ["serve", "--help"], ["api", "--help"]):
            proc = subprocess.run(
                [binary, *args],
                env=run_env(lab),
                cwd=lab / "work",
                timeout=15,
                text=True,
                capture_output=True,
                check=True,
            )
            (lab / (args[0].strip("-") + "-help.txt")).write_text(proc.stdout)
            if args == ["--version"]:
                check("installed version", "opencode v2.0.29", proc.stdout.strip())
        result = matrix(lab, binary)
        result["binary_sha256"] = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
        (lab / "results.json").write_text(json.dumps(result, indent=2))
    finally:
        check("real config metadata/hash unchanged", before, snapshot(home))
    print("assert_matrix: all expectations verified")


if __name__ == "__main__":
    main()
