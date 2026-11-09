#!/usr/bin/env python3
"""Regression tests for the mcp-parity skill scripts (capability_diff.py, detect-api-surface.sh)."""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # never leave __pycache__ inside the skill source tree

import importlib.util  # noqa: E402
import io  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import unittest  # noqa: E402
from contextlib import redirect_stderr, redirect_stdout  # noqa: E402
from pathlib import Path  # noqa: E402
from types import ModuleType  # noqa: E402
from typing import Any  # noqa: E402

SKILL_SCRIPTS = Path(__file__).resolve().parent.parent / "ycc/skills/mcp-parity/scripts"
SCRIPT = SKILL_SCRIPTS / "capability_diff.py"
OPENAPI = SKILL_SCRIPTS / "openapi_inventory.py"
DETECT = SKILL_SCRIPTS / "detect-api-surface.sh"


def _load(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


cd = _load("capability_diff", SCRIPT)
oi = _load("openapi_inventory", OPENAPI)
EMPTY: dict[str, Any] = cd.empty_manifest()


def cap(cid: str, op: str, **extra: Any) -> dict[str, Any]:
    base: dict[str, Any] = {"id": cid, "kind": "tool", "operation": op, "mutating": False, "destructive": False}
    return {**base, **extra}


def seeded(caps: list[dict[str, Any]], start: int = 1) -> dict[str, Any]:
    """Manifest where every non-covered capability has issue ABC-<n>."""
    issues = {c["id"]: {"issue": f"ABC-{start + i}"} for i, c in enumerate(caps) if not c.get("mcpCovered")}
    manifest: dict[str, Any] = cd.apply(EMPTY, caps, issues, {})
    return manifest


class FingerprintTest(unittest.TestCase):
    def test_ignores_presentation_fields(self) -> None:
        a = cap("users.list", "GET /users", summary="a", source="x.ts:1", area="users")
        b = cap("users.list", "GET /users", summary="b", source="y.ts:9", area="people")
        self.assertEqual(cd.fingerprint(a), cd.fingerprint(b))
        self.assertNotEqual(cd.fingerprint(a), cd.fingerprint(cap("users.list", "GET /users", mutating=True)))

    def test_normalizes_whitespace_key_order_and_defaults(self) -> None:
        a = cap("a", "GET  /a", inputs={"b": "string", "a": "int"}, outputs=None)
        b = cap("a", "GET /a", inputs={"a": "int", "b": " string "}, outputs="")
        self.assertEqual(cd.fingerprint(a), cd.fingerprint(b))


class DiffApplyTest(unittest.TestCase):
    def test_first_run_added_or_covered(self) -> None:
        result = cd.diff(EMPTY, [cap("a.list", "GET /a"), cap("b.list", "GET /b", mcpCovered=True)])
        self.assertEqual([x["id"] for x in result["added"]], ["a.list"])
        self.assertEqual([x["id"] for x in result["covered"]], ["b.list"])
        self.assertFalse(result["noop"])

    def test_rerun_without_changes_is_noop(self) -> None:
        caps = [cap("a.list", "GET /a"), cap("b.list", "GET /b", mcpCovered=True)]
        manifest = seeded(caps)
        result = cd.diff(manifest, caps)
        self.assertTrue(result["noop"])
        self.assertEqual(result["unchanged"], ["a.list", "b.list"])
        self.assertEqual(cd.apply(manifest, caps, {}, {}), manifest)

    def test_delta_classification_and_commit(self) -> None:
        manifest = seeded([cap("a.list", "GET /a"), cap("b.create", "POST /b"), cap("c.get", "GET /c")])
        new = [cap("a.list", "GET /a"), cap("b.create", "POST /b", inputs={"name": "string"}), cap("d.get", "GET /d")]
        result = cd.diff(manifest, new)
        self.assertEqual([x["id"] for x in result["added"]], ["d.get"])
        changed = result["changed"]
        self.assertEqual([(x["id"], x["issue"]) for x in changed], [("b.create", "ABC-2")])
        self.assertEqual(changed[0]["oldContract"]["inputs"], {})
        self.assertEqual(changed[0]["newContract"]["inputs"], {"name": "string"})
        self.assertEqual(result["removed"], [{"id": "c.get", "issue": "ABC-3", "status": "planned"}])
        nxt = cd.apply(
            manifest,
            new,
            {"d.get": {"issue": "ABC-4"}, "b.create": {"applied": True}, "c.get": {"applied": True}},
            {"commit": "abc"},
        )
        self.assertEqual(nxt["capabilities"]["c.get"]["status"], "removed")
        self.assertEqual(nxt["commit"], "abc")
        self.assertTrue(cd.diff(nxt, new)["noop"])

    def test_unrecorded_work_is_retried_next_run(self) -> None:
        manifest = seeded([cap("b.create", "POST /b"), cap("c.get", "GET /c")])
        new = [cap("b.create", "POST /b", inputs={"name": "string"}), cap("d.get", "GET /d")]
        # Run failed: nothing recorded except a status refresh, which must not commit work.
        nxt = cd.apply(manifest, new, {"b.create": {"status": "planned"}}, {}, partial=True)
        self.assertNotIn("d.get", nxt["capabilities"])
        self.assertEqual(nxt["capabilities"]["c.get"]["status"], "planned")
        again = cd.diff(nxt, new)
        self.assertEqual([x["id"] for x in again["changed"]], ["b.create"])
        self.assertEqual([x["id"] for x in again["removed"]], ["c.get"])
        self.assertEqual([x["id"] for x in again["added"]], ["d.get"])

    def test_apply_refuses_new_capability_without_issue(self) -> None:
        with self.assertRaises(cd.InputError):
            cd.apply(EMPTY, [cap("a.get", "GET /a")], {}, {})

    def test_apply_rejects_bad_issue_map(self) -> None:
        caps = [cap("a.get", "GET /a")]
        for issues in ({"typo.get": {"issue": "X-1"}}, {"a.get": {"isue": "X-1"}}, {"a.get": {"status": "nope"}}):
            with self.subTest(issues=issues), self.assertRaises(cd.InputError):
                cd.apply(EMPTY, caps, issues, {})

    def test_removed_then_revived_keeps_history(self) -> None:
        manifest = seeded([cap("a.get", "GET /a")])
        gone = cd.apply(manifest, [], {"a.get": {"applied": True}}, {})
        self.assertEqual(cd.diff(gone, [])["removed"], [])
        back = cd.diff(gone, [cap("a.get", "GET /a")])
        self.assertEqual([x["id"] for x in back["revived"]], ["a.get"])
        revived = cd.apply(gone, [cap("a.get", "GET /a")], {"a.get": {"issue": "ABC-9"}}, {})
        entry = revived["capabilities"]["a.get"]
        self.assertEqual((entry["status"], entry["issue"], entry["history"]), ("planned", "ABC-9", ["ABC-1"]))
        with self.assertRaises(cd.InputError):
            cd.apply(gone, [cap("a.get", "GET /a")], {}, {})

    def test_covered_lifecycle(self) -> None:
        manifest = seeded([cap("a.get", "GET /a", mcpCovered=True)])
        self.assertEqual(manifest["capabilities"]["a.get"]["status"], "covered")
        lost = cd.diff(manifest, [cap("a.get", "GET /a")])
        self.assertEqual([x["id"] for x in lost["added"]], ["a.get"])
        nxt = cd.apply(manifest, [cap("a.get", "GET /a")], {"a.get": {"issue": "ABC-5"}}, {})
        self.assertEqual(nxt["capabilities"]["a.get"]["status"], "planned")
        changed = cd.diff(manifest, [cap("a.get", "GET /a", mutating=True, mcpCovered=True)])
        self.assertEqual([(x["id"], x["issue"], x["status"]) for x in changed["changed"]], [("a.get", None, "covered")])

    def test_declined_preserved(self) -> None:
        caps = [cap("a.get", "GET /a")]
        manifest = cd.apply(seeded(caps), caps, {"a.get": {"status": "declined"}}, {})
        again = cd.apply(manifest, caps, {}, {})
        entry = again["capabilities"]["a.get"]
        self.assertEqual((entry["status"], entry["issue"]), ("declined", "ABC-1"))

    def test_refresh_statuses_feed_diff(self) -> None:
        caps = [cap("a.get", "GET /a"), cap("b.get", "GET /b")]
        manifest = seeded(caps)
        new = [cap("a.get", "GET /a", mutating=True), cap("b.get", "GET /b")]
        result = cd.diff(manifest, new, {"a.get": {"status": "declined"}, "b.get": {"status": "unlinked"}})
        self.assertEqual([(x["id"], x["status"]) for x in result["changed"]], [("a.get", "declined")])
        self.assertEqual([x["id"] for x in result["added"]], ["b.get"])
        nxt = cd.apply(
            manifest,
            new,
            {"a.get": {"status": "declined", "applied": True}, "b.get": {"status": "unlinked", "issue": "ABC-7"}},
            {},
        )
        self.assertEqual(nxt["capabilities"]["a.get"]["status"], "declined")
        b = nxt["capabilities"]["b.get"]
        self.assertEqual((b["issue"], b["history"], b["status"]), ("ABC-7", ["ABC-2"], "planned"))
        self.assertTrue(cd.diff(nxt, new)["noop"])
        partial = cd.apply(manifest, new, {"b.get": {"status": "unlinked"}}, {}, partial=True)
        self.assertNotIn("b.get", partial["capabilities"])
        gone = cd.apply(manifest, [cap("a.get", "GET /a")], {"b.get": {"status": "unlinked"}}, {})
        self.assertEqual(
            (gone["capabilities"]["b.get"]["status"], gone["capabilities"]["b.get"].get("issue")), ("removed", None)
        )

    def test_meta_null_keeps_manifest_value(self) -> None:
        caps = [cap("a.get", "GET /a")]
        manifest = cd.apply(EMPTY, caps, {"a.get": {"issue": "X-1"}}, {"project": "P"})
        self.assertEqual(cd.apply(manifest, caps, {}, {"project": None})["project"], "P")

    def test_repo_guard_case_insensitive(self) -> None:
        cd.check_repo(cd.empty_manifest("Acme/API"), "acme/api")

    def test_cover_normalizes_operations(self) -> None:
        self.assertEqual(cd.operation_key("get  /users/:id/"), "GET /users/{}")
        self.assertEqual(cd.operation_key("GET /users/{userId}"), "GET /users/{}")
        self.assertEqual(cd.operation_key("Query.users"), "Query.users")
        self.assertNotEqual(cd.operation_key("POST /v1/things:cancel"), cd.operation_key("POST /v1/things:archive"))
        self.assertEqual(cd.operation_key("POST /v1/things/:id:cancel"), "POST /v1/things/{}:cancel")
        caps = [cap("u.get", "GET /users/{id}"), cap("u.del", "DELETE /users/{id}"), cap("o.list", "GET /orders")]
        covered = [
            {"operation": "GET /users/:id", "mcpName": "get_user", "inputsMatch": True},
            {"operation": "DELETE /users/<id>", "mcpName": "del_user", "inputsMatch": False},
            {"operation": "POST /legacy", "mcpName": "legacy"},
            {"operation": "none", "mcpName": "compose"},
            {"operation": "none", "mcpName": "preview"},
            {"operation": "GET /orders", "mcpName": "a", "inputsMatch": False},
            {"operation": "GET /orders", "mcpName": "b", "inputsMatch": True},
        ]
        out, mcp_only = cd.cover(caps, covered)
        self.assertEqual([c["mcpCovered"] for c in out], [True, False, True])
        self.assertEqual([e["mcpName"] for e in mcp_only], ["compose", "preview", "legacy"])
        with self.assertRaises(cd.InputError):
            cd.cover(caps, {"operation": "x"})

    def test_possible_renames(self) -> None:
        manifest = seeded([cap("users.get", "GET /users/{id}"), cap("orders.list", "GET /orders")])
        result = cd.diff(manifest, [cap("users.fetch", "GET /users/{id}"), cap("orders.list", "GET /v2/orders")])
        self.assertIn({"from": "users.get", "to": "users.fetch", "reason": "same operation"}, result["possibleRenames"])
        self.assertEqual([x["id"] for x in result["changed"]], ["orders.list"])
        self.assertEqual(result["removedRatio"], 0.5)

    def test_repo_guard(self) -> None:
        manifest = cd.empty_manifest("acme/api")
        cd.check_repo(manifest, "acme/api")
        cd.check_repo(manifest, None)
        with self.assertRaises(cd.InputError):
            cd.check_repo(manifest, "other/api")

    def test_inventory_validation(self) -> None:
        bad: list[Any] = [
            {"capabilities": [cap("Bad Id", "x")]},
            {"capabilities": [cap("a", "x", kind="widget")]},
            {"capabilities": [cap("a", " ")]},
            {"capabilities": [cap("a", "x"), cap("a", "y")]},
            {"capabilities": [{"id": "a", "kind": "tool", "operation": "x"}]},
            {"nope": []},
        ]
        for data in bad:
            with self.subTest(data=data), self.assertRaises(cd.InputError):
                cd.validate_inventory(data)


class CliTest(unittest.TestCase):
    def run_cli(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = cd.main(list(args))
        return code, out.getvalue(), err.getvalue()

    def test_markdown_round_trip_and_cli(self) -> None:
        caps = [cap("a.get", "GET /a|b"), cap("b.get", "GET /b", mcpCovered=True)]
        manifest = cd.apply(
            cd.empty_manifest("r/r"), caps, {"a.get": {"issue": "ABC-1"}, "_foundation": {"scaffold": "ABC-0"}}, {}
        )
        body = cd.render_document(manifest)
        self.assertIn("GET /a\\|b", body)
        self.assertNotIn("<!--", body)
        self.assertEqual(cd.extract_manifest(body), manifest)
        self.assertIsNone(cd.extract_manifest("no manifest here"))
        with tempfile.TemporaryDirectory() as tmp:
            inv = Path(tmp, "inventory.json")
            inv.write_text(json.dumps({"schema": 1, "capabilities": caps}), encoding="utf-8")
            doc = Path(tmp, "manifest.md")
            doc.write_text("Intro\n\n" + body.replace("\n", "\r\n"), encoding="utf-8")
            code, out, _ = self.run_cli("diff", "--manifest", str(doc), "--inventory", str(inv), "--repo", "r/r")
            self.assertEqual(code, 0)
            self.assertTrue(json.loads(out)["noop"])
            code, _, err = self.run_cli("diff", "--manifest", str(doc), "--inventory", str(inv), "--repo", "x/y")
            self.assertEqual(code, 1)
            self.assertIn("wrong Project", err)
            # No-change apply with absent issues/meta files must succeed.
            code, out, _ = self.run_cli(
                "apply", "--manifest", str(doc), "--inventory", str(inv),
                "--issues", str(Path(tmp, "none.json")), "--meta", str(Path(tmp, "none2.json")), "--format", "markdown",
            )  # fmt: skip
            self.assertEqual(code, 0)
            self.assertEqual(cd.extract_manifest(out), manifest)
            code, out, _ = self.run_cli("extract", "--doc", str(doc))
            self.assertEqual(json.loads(out)["foundation"], {"scaffold": "ABC-0"})
            empty = Path(tmp, "empty.json")
            code, out, _ = self.run_cli("init", "--repo", "r/r")
            empty.write_text(out, encoding="utf-8")
            code, out, _ = self.run_cli("diff", "--manifest", str(empty), "--inventory", str(inv))
            self.assertEqual(json.loads(out)["counts"]["added"], 1)
            code, _, err = self.run_cli("diff", "--manifest", str(Path(tmp, "gone.md")), "--inventory", str(inv))
            self.assertEqual(code, 1)
            self.assertIn("not found", err)
            doc.write_text(cd.MANIFEST_HEADING + "\n\n```json\n{bad\n```\n", encoding="utf-8")
            code, _, err = self.run_cli("extract", "--doc", str(doc))
            self.assertEqual(code, 1)
            self.assertIn("invalid", err)


class DetectSurfaceTest(unittest.TestCase):
    FILES = {
        "package.json": "{}",
        "apps/api/go.mod": "module x",
        "openapi.yaml": "openapi: 3.1.0",
        "src/routes.ts": "router.get('/users', h)",
        "src/app/users/route.ts": "export async function GET(req) {}",
        "src/my routes.go": 'r.Get("/x", h)',
        "src/mcp.ts": "import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'",
        "src/cli.rs": "#[derive(Parser)]\nstruct Cli;",
        "node_modules/x/index.js": "app.get('/x', h)",
        "src/routes.test.ts": "router.get('/t', h)",
        "src/api_test.go": 'r.Get("/t", h)',
        "src/test_api.py": "app.get('/t')",
        "src/cache.ts": "const cached = cache.get(key)",
        "src/bin.ts": "import { Command } from 'commander'",
    }
    WANT = (
        "LANG\tnode",
        "LANG\tgo",
        "SPEC\topenapi.yaml",
        "ROUTES\tsrc/routes.ts",
        "ROUTES\tsrc/app/users/route.ts",
        "ROUTES\tsrc/my routes.go",
        "MCP\tsrc/mcp.ts",
        "CLI\tsrc/cli.rs",
        "CLI\tsrc/bin.ts",
    )

    def scan(self, use_git: bool) -> set[str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel, text in self.FILES.items():
                path = root / rel
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            if use_git:
                # Drop hook-exported GIT_* variables so the fixture never touches the outer repo.
                clean = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
                subprocess.run(["git", "init", "-q", str(root)], check=True, env=clean)
                (root / ".gitignore").write_text("node_modules/\n", encoding="utf-8")
            proc = subprocess.run(["bash", str(DETECT), str(root)], capture_output=True, text=True, check=True)
            return set(proc.stdout.splitlines())

    def test_detects_surfaces_with_and_without_git(self) -> None:
        for use_git in (False, True):
            with self.subTest(git=use_git):
                lines = self.scan(use_git)
                for want in self.WANT:
                    self.assertIn(want, lines)
                noise = ("node_modules", "routes.test", "api_test.go", "test_api.py", "cache.ts")
                self.assertFalse([line for line in lines if any(n in line for n in noise)])

    def test_truncation_keeps_later_sections(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for i in range(400):
                (root / f"route_{i:03d}_{'x' * 40}.ts").write_text("router.get('/a', h)", encoding="utf-8")
            (root / "mcp.ts").write_text("new McpServer()", encoding="utf-8")
            env = {**os.environ, "MCP_PARITY_MAX_HITS": "1"}
            proc = subprocess.run(["bash", str(DETECT), str(root)], capture_output=True, text=True, env=env)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("MCP\tmcp.ts", proc.stdout.splitlines())
            self.assertEqual(sum(1 for line in proc.stdout.splitlines() if line.startswith("ROUTES")), 1)
            self.assertIn("showing 1 of 400", proc.stderr)

    def test_rejects_missing_directory(self) -> None:
        proc = subprocess.run(["bash", str(DETECT), "/nonexistent/ycc"], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 1)


SPEC: dict[str, Any] = {
    "openapi": "3.1.0",
    "security": [{"session": []}],
    "components": {
        "parameters": {"Limit": {"name": "limit", "in": "query", "schema": {"type": "integer"}}},
        "schemas": {"User": {"type": "object"}},
    },
    "paths": {
        "/api/v1/users": {
            "get": {
                "operationId": "listUsers",
                "tags": ["users"],
                "summary": "List users\nmore",
                "parameters": [{"$ref": "#/components/parameters/Limit"}],
                "responses": {
                    "200": {
                        "content": {
                            "application/json": {
                                "schema": {"type": "array", "items": {"$ref": "#/components/schemas/User"}}
                            }
                        }
                    }
                },
            },
            "post": {
                "requestBody": {
                    "required": True,
                    "content": {"application/json": {"schema": {"$ref": "#/components/schemas/User"}}},
                },
                "responses": {
                    "201": {"content": {"application/json": {"schema": {"$ref": "#/components/schemas/User"}}}}
                },
            },
        },
        "/api/v1/users/{id}": {
            "parameters": [{"name": "id", "in": "path", "schema": {"type": "string"}}],
            "delete": {"security": [{"adminSession": []}], "responses": {"204": {}}},
            "get": {"deprecated": True, "responses": {"200": {}}},
        },
        "/api/v1/healthz": {"get": {"security": [], "responses": {"200": {}}}},
        "/api/v1/public/info": {"get": {"security": [], "responses": {"200": {}}}},
    },
}


class OpenApiInventoryTest(unittest.TestCase):
    def test_build_inventory(self) -> None:
        inv = oi.build_inventory(SPEC, list(oi.DEFAULT_EXCLUDES), "spec.json")
        caps = {c["id"]: c for c in inv["capabilities"]}
        self.assertEqual(sorted(caps), ["public.info.list", "users.create", "users.delete", "users.list"])
        users = caps["users.list"]
        self.assertEqual(users["inputs"], {"query": {"limit": "integer?"}})
        self.assertEqual(
            (users["outputs"], users["auth"], users["mutating"], users["summary"]),
            ("User[]", "user", False, "List users"),
        )
        self.assertEqual(caps["users.create"]["inputs"], {"body": {"type": "User"}})
        delete = caps["users.delete"]
        self.assertEqual(
            (delete["inputs"], delete["outputs"], delete["auth"], delete["destructive"]),
            ({"path": {"id": "string"}}, "none", "admin", True),
        )
        self.assertEqual(caps["public.info.list"]["auth"], "public")
        reasons = {e["operation"]: e["reason"] for e in inv["excluded"]}
        self.assertEqual(reasons["GET /api/v1/users/{id}"], "deprecated")
        self.assertIn("GET /api/v1/healthz", reasons)
        cd.validate_inventory(inv)  # output is a valid capability_diff inventory
        again = oi.build_inventory(SPEC, list(oi.DEFAULT_EXCLUDES), "spec.json")
        self.assertEqual(
            [cd.fingerprint(c) for c in again["capabilities"]], [cd.fingerprint(c) for c in inv["capabilities"]]
        )

    def test_cli_and_errors(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            spec = Path(tmp, "spec.json")
            spec.write_text(json.dumps(SPEC), encoding="utf-8")
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(oi.main([str(spec), "--exclude", "/public/"]), 0)
            ids = [c["id"] for c in json.loads(out.getvalue())["capabilities"]]
            self.assertNotIn("public.info.list", ids)
            spec.write_text(json.dumps({"swagger": "2.0", "paths": {}}), encoding="utf-8")
            with redirect_stderr(io.StringIO()):
                self.assertEqual(oi.main([str(spec)]), 1)
                self.assertEqual(oi.main([str(Path(tmp, "missing.json"))]), 1)
                self.assertEqual(oi.main([str(spec), "--exclude", "("]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=1)
