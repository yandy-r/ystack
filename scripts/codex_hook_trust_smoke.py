#!/usr/bin/env python3
"""Opt-in YAN-1149 hook trust transitions; recording hooks and loopback SSE only.

Run with an explicit official 0.160.0 CODEX_BIN:
    CODEX_BIN=/absolute/path/to/codex python3 scripts/codex_hook_trust_smoke.py

Retains a private sandbox under /tmp/opencode and sanitized evidence.json there,
including failures. Never reads host Codex configuration, auth, hooks, or sockets.
SessionStart is an adapted reporter probe, NOT a WorktreeCreate substitute.
The model endpoint is a local deterministic stub, not a real inference service.
No OS network namespace is imposed; only the provider URL is loopback-constrained.
"""

from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import os
import queue
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
from pathlib import Path
from typing import Any

PINNED_VERSION = "codex-cli 0.160.0"
# Official rust-v0.160.0 Linux x86_64 musl executable; also npm's native payload.
OFFICIAL_SHA256 = "12eb3e81114588aca3b7998f4f19e8997b056aca08e57a7ca7c8a3ec8c652aad"
PLUGIN_ID = "recording@hook-trust-spike"
EVENTS = {"sessionStart": "SessionStart", "userPromptSubmit": "UserPromptSubmit"}
STUB_TEXT = "YAN-1149 deterministic loopback response; no inference."
TIMEOUT = 45


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def dump(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def clean_env(root: Path) -> dict[str, str]:
    names = ("home", "codex", "config", "data", "state", "cache", "runtime", "tmp", "work")
    for name in names:
        (root / name).mkdir(mode=0o700)
    return {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "TERM": "dumb",
        "NO_COLOR": "1",
        "HOME": str(root / "home"),
        "CODEX_HOME": str(root / "codex"),
        "XDG_CONFIG_HOME": str(root / "config"),
        "XDG_DATA_HOME": str(root / "data"),
        "XDG_STATE_HOME": str(root / "state"),
        "XDG_CACHE_HOME": str(root / "cache"),
        "XDG_RUNTIME_DIR": str(root / "runtime"),
        "TMPDIR": str(root / "tmp"),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ALLOW_PROTOCOL": "file",
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "credential.helper",
        "GIT_CONFIG_VALUE_0": "",
    }


def command(binary: Path, args: list[str], root: Path, env: dict[str, str], evidence: dict[str, Any]) -> str:
    result = subprocess.run(
        [str(binary), *args], cwd=root / "work", env=env, capture_output=True, text=True, timeout=TIMEOUT
    )
    entry = {"argv": [str(binary), *args], "exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
    evidence.setdefault("commands", []).append(entry)
    require(result.returncode == 0, f"command failed: {args}: {result.stderr}")
    return result.stdout


def inspect_schema(schema: Path) -> dict[str, Any]:
    """Fail closed if this binary's generated API differs from the used contract."""
    required = {
        "v1/InitializeParams.json": {"clientInfo", "capabilities"},
        "v2/HooksListParams.json": {"cwds"},
        "v2/ConfigBatchWriteParams.json": {"edits", "reloadUserConfig"},
        "v2/ThreadStartParams.json": {
            "cwd",
            "model",
            "modelProvider",
            "approvalPolicy",
            "sandbox",
            "sessionStartSource",
        },
        "v2/TurnStartParams.json": {"threadId", "input"},
    }
    result: dict[str, Any] = {}
    for name, fields in required.items():
        raw = (schema / name).read_bytes()
        data = json.loads(raw)
        require(fields <= data["properties"].keys(), f"schema lacks required fields in {name}")
        result[name] = {"sha256": hashlib.sha256(raw).hexdigest(), "fieldsUsed": sorted(fields)}
    hooks = json.loads((schema / "v2/HooksListResponse.json").read_text(encoding="utf-8"))
    names = hooks["definitions"]["HookEventName"]["enum"]
    require(set(EVENTS) <= set(names), f"recording events unavailable: {names}")
    require("worktreeCreate" not in names, "WorktreeCreate appeared; revisit the adapted-reporter conclusion")
    require(
        {"untrusted", "trusted", "modified"} <= set(hooks["definitions"]["HookTrustStatus"]["enum"]),
        "trust status schema changed",
    )
    edits = json.loads((schema / "v2/ConfigBatchWriteParams.json").read_text(encoding="utf-8"))
    require(
        {"keyPath", "mergeStrategy", "value"} <= edits["definitions"]["ConfigEdit"]["properties"].keys(),
        "config edit schema changed",
    )
    require("upsert" in edits["definitions"]["MergeStrategy"]["enum"], "upsert schema changed")
    result["hookEvents"] = names
    return result


class Stub(http.server.ThreadingHTTPServer):
    """Only one fixed SSE response, never tools, external forwarding, or auth."""

    daemon_threads = True

    def __init__(self) -> None:
        self.requests: list[dict[str, Any]] = []
        self.failures: list[str] = []
        super().__init__(("127.0.0.1", 0), StubHandler)


class StubHandler(http.server.BaseHTTPRequestHandler):
    server: Stub

    def log_message(self, format: str, *args: Any) -> None:
        pass

    def do_POST(self) -> None:
        size = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(size)
        authorized = self.headers.get("Authorization") is not None
        self.server.requests.append(
            {
                "method": "POST",
                "path": self.path,
                "bodyBytes": len(body),
                "bodySha256": hashlib.sha256(body).hexdigest(),
                "authorizationPresent": authorized,
            }
        )
        if self.path != "/v1/responses" or authorized or len(self.server.requests) > 3:
            self.server.failures.append(f"unexpected request: path={self.path}, authorization={authorized}")
            self.send_error(400)
            return
        # Same minimal events as upstream app-server MockResponsesConfig tests.
        events = [
            {"type": "response.created", "response": {"id": "resp-hook-trust"}},
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "message",
                    "role": "assistant",
                    "id": "msg-hook-trust",
                    "content": [{"type": "output_text", "text": STUB_TEXT}],
                },
            },
            {
                "type": "response.completed",
                "response": {
                    "id": "resp-hook-trust",
                    "usage": {
                        "input_tokens": 0,
                        "input_tokens_details": None,
                        "output_tokens": 0,
                        "output_tokens_details": None,
                        "total_tokens": 0,
                    },
                },
            },
        ]
        payload = "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_HEAD(self) -> None:
        self.server.failures.append(f"unexpected HEAD: {self.path}")
        self.send_error(400)

    def do_GET(self) -> None:
        self.server.failures.append(f"unexpected GET: {self.path}")
        self.send_error(400)


class Rpc:
    def __init__(self, binary: Path, root: Path, env: dict[str, str], label: str, evidence: dict[str, Any]) -> None:
        self.messages: list[dict[str, Any]] = []
        evidence.setdefault("rpc", {})[label] = self.messages
        self.pending: queue.Queue[str | None] = queue.Queue()
        self.stderr = (root / f"{label}.stderr").open("w", encoding="utf-8")
        try:
            self.process = subprocess.Popen(
                [str(binary), "app-server", "--stdio"],
                env=env,
                cwd=root / "work",
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=self.stderr,
                text=True,
            )
            self.next_id = 0
            self.reader = threading.Thread(target=self.read_lines, daemon=True)
            self.reader.start()
        except BaseException:
            if hasattr(self, "process"):
                self.process.kill()
                self.process.wait()
            self.stderr.close()
            raise

    def __enter__(self) -> Rpc:
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.close(check=exc_type is None)

    def read_lines(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            self.pending.put(line)
        self.pending.put(None)

    def send(self, message: dict[str, Any]) -> None:
        assert self.process.stdin is not None
        self.messages.append({"direction": "sent", **message})
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def receive(self, deadline: float) -> dict[str, Any]:
        try:
            line = self.pending.get(timeout=max(0.001, deadline - time.monotonic()))
        except queue.Empty as exc:
            raise TimeoutError("app-server response/notification timeout") from exc
        if line is None:
            raise RuntimeError(f"app-server closed unexpectedly: {self.process.poll()}")
        message: dict[str, Any] = json.loads(line)
        self.messages.append({"direction": "received", **message})
        require(
            not ("method" in message and "id" in message),
            f"unexpected server request (no tools/approvals permitted): {message}",
        )
        require(message.get("method") != "error", f"app-server error notification: {message}")
        return message

    def request(self, method: str, params: dict[str, Any]) -> Any:
        self.next_id += 1
        request_id = self.next_id
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + TIMEOUT
        while True:
            message = self.receive(deadline)
            if message.get("id") == request_id:
                require("error" not in message, f"{method}: {message.get('error')}")
                return message["result"]

    def initialize(self) -> None:
        self.request(
            "initialize",
            {"clientInfo": {"name": "yan1149-hook-trust", "version": "0"}, "capabilities": {"experimentalApi": True}},
        )
        self.send({"method": "initialized"})

    def turn(self, cwd: Path) -> dict[str, Any]:
        thread = self.request(
            "thread/start",
            {
                "cwd": str(cwd),
                "model": "mock-model",
                "modelProvider": "hook_stub",
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "sessionStartSource": "startup",
            },
        )
        require(thread.get("modelProvider") == "hook_stub", f"unexpected resolved provider: {thread}")
        thread_id = thread["thread"]["id"]
        start_index = len(self.messages)
        turn = self.request(
            "turn/start",
            {
                "threadId": thread_id,
                "input": [{"type": "text", "text": "Record hook trust only. Do not call tools.", "text_elements": []}],
            },
        )
        turn_id = turn["turn"]["id"]
        deadline = time.monotonic() + TIMEOUT
        # Notifications may precede the turn/start reply: inspect retained messages too.
        index = start_index
        while True:
            while index < len(self.messages):
                message = self.messages[index]
                index += 1
                if message.get("method") == "turn/completed" and message["params"].get("threadId") == thread_id:
                    completed = message["params"]["turn"]
                    require(
                        completed["id"] == turn_id
                        and completed["status"] == "completed"
                        and not completed.get("error"),
                        f"turn failed: {completed}",
                    )
                    require(
                        any(
                            m.get("method") == "item/completed"
                            and m.get("params", {}).get("item", {}).get("type") == "agentMessage"
                            and m["params"]["item"].get("text") == STUB_TEXT
                            for m in self.messages[start_index:]
                        ),
                        "fixed stub assistant output not observed",
                    )
                    return {"threadId": thread_id, "turnId": turn_id, "status": completed["status"]}
            self.receive(deadline)

    def close(self, *, check: bool = True) -> None:
        assert self.process.stdin is not None
        self.process.stdin.close()
        timed_out = False
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            timed_out = True
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        finally:
            self.reader.join(timeout=2)
            self.stderr.close()
        if check:
            require(not timed_out, "app-server graceful shutdown timed out")
            require(self.process.returncode == 0, f"app-server exited unsuccessfully: {self.process.returncode}")


def write_hooks(path: Path, revision: str) -> None:
    groups = {}
    for event in EVENTS.values():
        command_text = (
            f'/usr/bin/python3 "${{PLUGIN_ROOT}}/hooks/record.py"' f" {shlex.quote(event)} {shlex.quote(revision)}"
        )
        item: dict[str, Any] = {"hooks": [{"type": "command", "command": command_text, "timeout": 5}]}
        if event == "SessionStart":
            item["matcher"] = "startup"
        groups[event] = [item]
    dump(path, {"hooks": groups})


def list_hooks(rpc: Rpc, root: Path, expected: str) -> list[dict[str, Any]]:
    result = rpc.request("hooks/list", {"cwds": [str(root / "work")]})
    require(len(result["data"]) == 1 and not result["data"][0]["errors"], f"hook discovery failed: {result}")
    hooks: list[dict[str, Any]] = result["data"][0]["hooks"]
    require(len(hooks) == 2 and {h["eventName"] for h in hooks} == set(EVENTS), f"unexpected hooks: {hooks}")
    for hook in hooks:
        require(
            hook["source"] == "plugin"
            and hook["pluginId"] == PLUGIN_ID
            and hook["enabled"] is True
            and hook["trustStatus"] == expected
            and hook["currentHash"].startswith("sha256:"),
            f"unexpected hook identity/trust: {hook}",
        )
        require(
            Path(hook["sourcePath"]).is_relative_to(root / "codex/plugins/cache"),
            f"hook outside isolated cache: {hook}",
        )
    return hooks


def records(path: Path) -> list[dict[str, Any]]:
    try:
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    except FileNotFoundError:
        return []


def exercise(binary: Path, root: Path, env: dict[str, str], evidence: dict[str, Any]) -> None:
    # Release builds still load system config; debug override env vars are ineffective.
    require(
        not Path("/etc/codex").exists() and not Path("/etc/codex").is_symlink(),
        "refusing host /etc/codex configuration; use a clean isolated host",
    )
    evidence["systemConfigAbsent"] = True
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    require(
        digest == OFFICIAL_SHA256,
        "CODEX_BIN must be the pinned official Linux x86_64 musl native executable (not a shim)",
    )
    version = command(binary, ["--version"], root, env, evidence).strip()
    require(version == PINNED_VERSION, f"expected {PINNED_VERSION}, got {version}")
    evidence["runtime"] = {"version": version, "binarySha256": digest}
    schema = root / "schema"
    command(binary, ["app-server", "generate-json-schema", "--experimental", "--out", str(schema)], root, env, evidence)
    evidence["schema"] = inspect_schema(schema)
    record_path = root / "records.jsonl"
    marketplace = root / "fixture"
    payload = marketplace / "recording"
    (payload / ".codex-plugin").mkdir(parents=True)
    (payload / "hooks").mkdir()
    (marketplace / ".agents/plugins").mkdir(parents=True)
    (marketplace / ".git").mkdir()
    dump(
        payload / ".codex-plugin/plugin.json",
        {"name": "recording", "version": "0.0.1", "description": "Isolated recording-only hook trust probe"},
    )
    dump(
        marketplace / ".agents/plugins/marketplace.json",
        {
            "name": "hook-trust-spike",
            "plugins": [{"name": "recording", "source": {"source": "local", "path": "./recording"}}],
        },
    )
    (payload / "hooks/record.py").write_text(
        "import json, os, sys\nfrom pathlib import Path\n"
        "payload = json.load(sys.stdin)\n"
        f"with Path({str(record_path)!r}).open('a', encoding='utf-8') as handle:\n"
        "    handle.write(json.dumps({'event': sys.argv[1], 'revision': sys.argv[2],"
        " 'plugin_root': os.environ.get('PLUGIN_ROOT'),"
        " 'payload_keys': sorted(payload)}) + '\\n')\n",
        encoding="utf-8",
    )
    write_hooks(payload / "hooks/hooks.json", "original")
    with Stub() as stub:
        server_thread = threading.Thread(target=stub.serve_forever, daemon=True)
        server_thread.start()
        try:
            (root / "codex/config.toml").write_text(
                f"""model = "mock-model"
model_provider = "hook_stub"
approval_policy = "never"
sandbox_mode = "read-only"
[features]
plugins = true
hooks = true
[analytics]
enabled = false
[model_providers.hook_stub]
name = "YAN-1149 loopback no-inference stub"
base_url = "http://127.0.0.1:{stub.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
stream_idle_timeout_ms = 10000
""",
                encoding="utf-8",
            )
            command(binary, ["plugin", "marketplace", "add", str(marketplace), "--json"], root, env, evidence)
            command(binary, ["plugin", "add", PLUGIN_ID, "--json"], root, env, evidence)
            phases = evidence["phases"] = []
            with Rpc(binary, root, env, "untrusted-and-grant", evidence) as rpc:
                rpc.initialize()
                original = list_hooks(rpc, root, "untrusted")
                result = rpc.turn(root / "work")
                require(records(record_path) == [], "untrusted hooks executed")
                require(
                    len(stub.requests) == 1 and not stub.failures, "untrusted turn did not complete solely against stub"
                )
                phases.append(
                    {"phase": "untrusted", "hooks": original, "recordsBefore": 0, "recordsAfter": 0, "turn": result}
                )
                rpc.request(
                    "config/batchWrite",
                    {
                        "edits": [
                            {
                                "keyPath": "hooks.state",
                                "mergeStrategy": "upsert",
                                "value": {h["key"]: {"trusted_hash": h["currentHash"]} for h in original},
                            }
                        ],
                        "reloadUserConfig": True,
                    },
                )
                reloaded = list_hooks(rpc, root, "trusted")
                require(
                    {h["key"]: h["currentHash"] for h in reloaded} == {h["key"]: h["currentHash"] for h in original},
                    "in-session reload changed hook identities",
                )
            config = tomllib.loads((root / "codex/config.toml").read_text(encoding="utf-8"))
            require(
                all(config["hooks"]["state"][h["key"]]["trusted_hash"] == h["currentHash"] for h in original),
                "trust grant not persisted in isolated config",
            )
            evidence["trustPersisted"] = True
            evidence["inSessionReloadTrusted"] = True
            with Rpc(binary, root, env, "trusted-restarted", evidence) as rpc:
                rpc.initialize()
                trusted = list_hooks(rpc, root, "trusted")
                require(
                    {h["key"]: h["currentHash"] for h in trusted} == {h["key"]: h["currentHash"] for h in original},
                    "trusted identities changed",
                )
                result = rpc.turn(root / "work")
                observed = records(record_path)
                require(
                    len(observed) == 2
                    and [r["event"] for r in observed] == list(EVENTS.values())
                    and all(
                        r["revision"] == "original"
                        and bool(r.get("plugin_root"))
                        and Path(r["plugin_root"]).is_relative_to(root / "codex/plugins/cache")
                        and bool(r.get("payload_keys"))
                        for r in observed
                    ),
                    f"trusted recording hooks did not execute expected payloads: {observed}",
                )
                require(
                    len(stub.requests) == 2 and not stub.failures, "trusted turn did not complete solely against stub"
                )
                phases.append(
                    {"phase": "trusted", "hooks": trusted, "recordsBefore": 0, "recordsAfter": 2, "turn": result}
                )
            hook_files = {Path(h["sourcePath"]) for h in trusted}
            require(len(hook_files) == 1, f"unexpected installed hook paths: {hook_files}")
            write_hooks(hook_files.pop(), "modified")
            with Rpc(binary, root, env, "modified-restarted", evidence) as rpc:
                rpc.initialize()
                modified = list_hooks(rpc, root, "modified")
                old = {h["key"]: h["currentHash"] for h in original}
                require(
                    {h["key"] for h in modified} == set(old)
                    and all(old[h["key"]] != h["currentHash"] for h in modified),
                    "modified hook keys/hashes not as expected",
                )
                result = rpc.turn(root / "work")
                require(records(record_path) == observed, "modified hooks executed")
                require(
                    len(stub.requests) == 3 and not stub.failures, "modified turn did not complete solely against stub"
                )
                phases.append(
                    {"phase": "modified", "hooks": modified, "recordsBefore": 2, "recordsAfter": 2, "turn": result}
                )
            require(not (root / "codex/auth.json").exists(), "unexpected auth file")
            evidence["records"] = observed
            evidence["verdict"] = {
                "trustTransitions": "PASS",
                "adaptedReporter": "GO for recording-only SessionStart/UserPromptSubmit",
                "worktreeCreate": "NO-GO: event absent; SessionStart is not a substitute",
            }
        finally:
            stub.shutdown()
            server_thread.join(timeout=5)
            evidence["stub"] = {
                "address": "127.0.0.1",
                "port": stub.server_port,
                "requests": stub.requests,
                "failures": stub.failures,
            }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("/tmp/opencode"),
        help="existing parent under /tmp/opencode; sandbox is always retained",
    )
    args = parser.parse_args()
    binary_text = os.environ.get("CODEX_BIN")
    if not binary_text:
        raise RuntimeError(
            "set CODEX_BIN to an explicit official 0.160.0 native executable; no auto-download or PATH fallback"
        )
    binary = Path(binary_text).resolve(strict=True)
    require(binary.is_file() and os.access(binary, os.X_OK), "CODEX_BIN must be executable")
    parent = args.output_dir.resolve(strict=True)
    require(
        parent == Path("/tmp/opencode") or parent.is_relative_to("/tmp/opencode"), "output must be under /tmp/opencode"
    )
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix="codex-hook-trust.", dir=parent))
    evidence: dict[str, Any] = {
        "status": "FAIL",
        "isolation": {
            "freshHome": True,
            "freshCodexHome": True,
            "inheritedEnvironment": False,
            "copiedCredentialsOrHooks": False,
            "provider": "loopback deterministic SSE",
            "osNetworkIsolation": False,
            "productionScriptsOrSockets": "not configured or referenced",
            "fixture": "generated recording-only plugin; transport is separate",
        },
    }
    try:
        exercise(binary, root, clean_env(root), evidence)
        evidence["status"] = "PASS"
    except (OSError, ValueError, KeyError, RuntimeError, TimeoutError, subprocess.SubprocessError) as exc:
        evidence["failure"] = f"{type(exc).__name__}: {exc}"
    finally:
        stderr = {path.name: path.read_text(encoding="utf-8", errors="replace") for path in root.glob("*.stderr")}
        evidence["stderr"] = stderr
        # Only generated fixture data is captured; replace ephemeral paths for a shareable dossier input.
        sanitized = json.loads(json.dumps(evidence).replace(str(root), "<SANDBOX>").replace(str(binary), "<CODEX_BIN>"))
        dump(root / "evidence.json", sanitized)
        print(f"{evidence['status']}: {root / 'evidence.json'}")
        if "failure" in evidence:
            print(evidence["failure"], file=sys.stderr)
    return 0 if evidence["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
