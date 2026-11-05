#!/usr/bin/env python3
"""Regression tests for OpenCode V2 agent permission generation."""

from __future__ import annotations

import json
import re
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from generate_opencode_agents import convert_tools_to_permissions, transform_agent
from generate_opencode_common import load_agent_aliases, parse_frontmatter

DENY_ALL = {"action": "*", "resource": "*", "effect": "deny"}
ENV_READ_GUARDS = [
    {"action": "read", "resource": "*.env", "effect": "ask"},
    {"action": "read", "resource": "*.env.*", "effect": "ask"},
    {"action": "read", "resource": "*.env.example", "effect": "allow"},
]
EXTERNAL_DIRECTORY_ASK = {"action": "external_directory", "resource": "*", "effect": "ask"}
REPO_ROOT = Path(__file__).resolve().parent.parent
RESTRICTED_AGENTS = (
    "backport-conflict-resolver",
    "db-modifier",
    "pr-comment-fixer",
    "release-fix-applier",
    "review-fixer",
)


def wildcard_match(value: str, pattern: str) -> bool:
    """Port of OpenCode v2.0.32 core/src/util/wildcard.ts (POSIX hosts)."""
    escaped = re.sub(r"[.+^${}()|\[\]\\]", lambda m: "\\" + m.group(0), pattern.replace("\\", "/"))
    escaped = escaped.replace("*", ".*").replace("?", ".")
    if escaped.endswith(" .*"):
        escaped = escaped[:-3] + "( .*)?"
    return re.fullmatch(escaped, value.replace("\\", "/"), re.DOTALL) is not None


def evaluate(rules: list[dict[str, str]], action: str, resource: str) -> str:
    """Last matching rule wins; no match asks (core/src/permission.ts evaluate)."""
    for rule in reversed(rules):
        if wildcard_match(action, rule["action"]) and wildcard_match(resource, rule["resource"]):
            return rule["effect"]
    return "ask"


def generated_permissions(stem: str) -> list[dict[str, str]]:
    source = (REPO_ROOT / "ycc" / "agents" / f"{stem}.md").read_text(encoding="utf-8")
    frontmatter, _ = parse_frontmatter(transform_agent(stem, source, load_agent_aliases()))
    permissions = frontmatter["permissions"]
    assert isinstance(permissions, list)
    return permissions


SENSITIVE_RESOURCES = (
    ".env",
    "app/.env",
    ".env.local",
    "prod.env",
    "config/app.env",
    "app.env.local",
    ".envrc",
    ".env-prod",
    "deploy/server.pem",
    "certs/tls.key",
    "id_rsa",
    "keys/id_ed25519",
    "credentials.json",
    "ops/service-account-prod.json",
    ".ssh/config",
    "/home/user/.aws/credentials",
    "/home/user/.kube/config",
    ".netrc",
    ".git-credentials",
    ".npmrc",
    ".pypirc",
    ".pgpass",
    ".ssh/backup.env.example",
    "id_rsa.env.example",
    "keys/id_ed25519.prod.env.example",
)
ALLOWED_RESOURCES = (
    "src/app.ts",
    "README.md",
    ".env.example",
    "app/.env.example",
    ".env.local.example",
    "app.env.example",
)


class OpenCodeAgentGenerationTestCase(unittest.TestCase):
    def test_translates_native_actions_and_preserves_sensitive_read_guards(self) -> None:
        permissions = convert_tools_to_permissions(
            ["Read", "Write", "Edit", "Glob", "Grep", "Bash", "WebFetch", "WebSearch"]
        )

        self.assertEqual(
            permissions,
            [
                DENY_ALL,
                {"action": "read", "resource": "*", "effect": "allow"},
                {"action": "edit", "resource": "*", "effect": "allow"},
                {"action": "glob", "resource": "*", "effect": "allow"},
                {"action": "grep", "resource": "*", "effect": "allow"},
                {"action": "shell", "resource": "*", "effect": "allow"},
                {"action": "webfetch", "resource": "*", "effect": "allow"},
                {"action": "websearch", "resource": "*", "effect": "allow"},
                EXTERNAL_DIRECTORY_ASK,
                *ENV_READ_GUARDS,
            ],
        )

    def test_preserves_scoped_bash_as_shell_rules(self) -> None:
        permissions = convert_tools_to_permissions(["Read", "Bash(ls:*)", "Bash(git status:*)", "Bash(npm:*)"])

        self.assertIn({"action": "shell", "resource": "ls *", "effect": "allow"}, permissions)
        self.assertIn({"action": "shell", "resource": "git status *", "effect": "allow"}, permissions)
        self.assertIn({"action": "shell", "resource": "npm *", "effect": "allow"}, permissions)
        self.assertNotIn({"action": "read", "resource": "ls *", "effect": "allow"}, permissions)
        self.assertIn(EXTERNAL_DIRECTORY_ASK, permissions)

    def test_git_c_scopes_use_native_shell_workdir(self) -> None:
        permissions = convert_tools_to_permissions(["Bash(git -C * show:*)", "Bash(git -C * diff:*)"])

        self.assertIn({"action": "shell", "resource": "git show *", "effect": "allow"}, permissions)
        self.assertIn({"action": "shell", "resource": "git diff *", "effect": "allow"}, permissions)
        self.assertFalse(any(rule["action"] == "shell" and "git -C" in rule["resource"] for rule in permissions))

    def test_preserves_commas_inside_one_bash_scope(self) -> None:
        permissions = convert_tools_to_permissions('Bash(python:-c "a,b")')

        self.assertIn(
            {"action": "shell", "resource": 'python -c "a,b"', "effect": "allow"},
            permissions,
        )
        self.assertEqual(sum(rule["action"] == "shell" for rule in permissions), 1)

    def test_restores_external_directory_approval_after_broad_deny(self) -> None:
        permissions = convert_tools_to_permissions(["Read"])

        self.assertLess(permissions.index(DENY_ALL), permissions.index(EXTERNAL_DIRECTORY_ASK))
        self.assertEqual(permissions[-4], EXTERNAL_DIRECTORY_ASK)

        web_only = convert_tools_to_permissions(["WebFetch"])
        self.assertNotIn(EXTERNAL_DIRECTORY_ASK, web_only)

    def test_supports_comma_string_and_native_mcp_actions(self) -> None:
        permissions = convert_tools_to_permissions(
            "Read, LS, Task, AskUserQuestion, mcp__maps-mcp__places-search, "
            "mcp__convex__functionSpec, mcp__github__*, TodoWrite"
        )

        self.assertIn({"action": "glob", "resource": "*", "effect": "allow"}, permissions)
        self.assertIn({"action": "subagent", "resource": "*", "effect": "allow"}, permissions)
        self.assertIn({"action": "question", "resource": "*", "effect": "allow"}, permissions)
        self.assertIn(
            {"action": "maps-mcp_places-search", "resource": "*", "effect": "allow"},
            permissions,
        )
        self.assertIn({"action": "convex_functionSpec", "resource": "*", "effect": "allow"}, permissions)
        self.assertIn({"action": "github_*", "resource": "*", "effect": "allow"}, permissions)
        self.assertFalse(any(rule["action"] == "todowrite" for rule in permissions))

    def test_boolean_mapping_uses_native_case_insensitive_aliases(self) -> None:
        permissions = convert_tools_to_permissions(
            {"read": True, "write": True, "bash": True, "task": True, "websearch": False}
        )

        self.assertIn({"action": "read", "resource": "*", "effect": "allow"}, permissions)
        self.assertIn({"action": "edit", "resource": "*", "effect": "allow"}, permissions)
        self.assertIn({"action": "shell", "resource": "*", "effect": "allow"}, permissions)
        self.assertIn({"action": "subagent", "resource": "*", "effect": "allow"}, permissions)
        self.assertFalse(any(rule["action"] in {"write", "bash", "task", "websearch"} for rule in permissions))

    def test_rejects_non_bash_scopes_instead_of_broadening_them(self) -> None:
        for tool in ("Read(src/**)", "Edit(docs/**)"):
            with self.subTest(tool=tool):
                with self.assertRaisesRegex(ValueError, "only Bash scopes can be translated"):
                    convert_tools_to_permissions([tool])

    def test_explicit_empty_tools_denies_all(self) -> None:
        self.assertEqual(convert_tools_to_permissions([]), [DENY_ALL])

    def test_omitted_tools_inherits_host_defaults(self) -> None:
        output = transform_agent("reader", "---\ndescription: Reader\n---\nRead files.\n", {})
        frontmatter, _ = parse_frontmatter(output)

        self.assertNotIn("permissions", frontmatter)

    def test_transform_emits_only_v2_permission_metadata(self) -> None:
        raw = """---
description: Reviewer
tools: [Read, Grep, Glob]
permission:
  edit: deny
prompt: legacy
temperature: 0.2
top_p: 0.5
disable: true
---
Review code.
"""

        output = transform_agent("reviewer", raw, {})
        frontmatter, _ = parse_frontmatter(output)

        self.assertIn("permissions", frontmatter)
        self.assertTrue(frontmatter["disabled"])
        for legacy in ("tools", "permission", "prompt", "temperature", "top_p", "disable"):
            self.assertNotIn(legacy, frontmatter)

    def test_transform_allows_skill_only_for_agents_that_reference_one(self) -> None:
        with_skill = "---\ndescription: Typed\ntools: [Read]\n---\nUse `skill: python-patterns`.\n"
        without_skill = "---\ndescription: Reader\ntools: [Read]\n---\nRead the relevant code.\n"

        skill_frontmatter, _ = parse_frontmatter(transform_agent("typed", with_skill, {}))
        reader_frontmatter, _ = parse_frontmatter(transform_agent("reader", without_skill, {}))

        skill_rule = {"action": "skill", "resource": "python-patterns", "effect": "allow"}
        self.assertIn(skill_rule, skill_frontmatter["permissions"])
        self.assertNotIn(skill_rule, reader_frontmatter["permissions"])

    def test_sensitive_agents_use_narrow_source_shell_allowlists(self) -> None:
        source_agents = REPO_ROOT / "ycc" / "agents"

        backport, _ = parse_frontmatter((source_agents / "backport-conflict-resolver.md").read_text(encoding="utf-8"))
        code_finder, _ = parse_frontmatter((source_agents / "code-finder.md").read_text(encoding="utf-8"))
        fixer, _ = parse_frontmatter((source_agents / "pr-comment-fixer.md").read_text(encoding="utf-8"))

        self.assertNotIn("Bash(git:*)", backport["tools"])
        self.assertTrue(all(tool.startswith("Bash(git -C * ") for tool in backport["tools"] if tool.startswith("Bash")))
        self.assertNotIn("Bash", code_finder["tools"])
        for broad in ("Bash(cat:*)", "Bash(git:*)", "Bash(ls:*)", "Bash(test:*)"):
            self.assertNotIn(broad, fixer["tools"])

        for stem in RESTRICTED_AGENTS:
            with self.subTest(agent=stem):
                frontmatter, _ = parse_frontmatter((source_agents / f"{stem}.md").read_text(encoding="utf-8"))
                tools = frontmatter["tools"]
                for broad in ("Bash", "Bash(*)", "Bash(cat:*)", "Bash(git:*)", "Bash(head:*)", "Bash(tail:*)"):
                    self.assertNotIn(broad, tools)

        release, _ = parse_frontmatter((source_agents / "release-fix-applier.md").read_text(encoding="utf-8"))
        self.assertFalse(any(tool.startswith("Bash(git") for tool in release["tools"]))
        review, _ = parse_frontmatter((source_agents / "review-fixer.md").read_text(encoding="utf-8"))
        self.assertEqual(
            sorted(tool for tool in review["tools"] if tool.startswith("Bash(git")),
            ["Bash(git diff:*)", "Bash(git log:*)", "Bash(git status:*)"],
        )

    def test_restricted_agents_deny_sensitive_paths_for_read_and_edit(self) -> None:
        for stem in RESTRICTED_AGENTS:
            permissions = generated_permissions(stem)
            for action in ("read", "edit"):
                for resource in SENSITIVE_RESOURCES:
                    with self.subTest(agent=stem, action=action, resource=resource):
                        self.assertEqual(evaluate(permissions, action, resource), "deny")
                for resource in ALLOWED_RESOURCES:
                    with self.subTest(agent=stem, action=action, resource=resource):
                        self.assertEqual(evaluate(permissions, action, resource), "allow")

    def test_restricted_shell_agents_deny_git_diff_no_index(self) -> None:
        for stem in ("backport-conflict-resolver", "review-fixer"):
            with self.subTest(agent=stem):
                permissions = generated_permissions(stem)
                self.assertEqual(evaluate(permissions, "shell", "git diff --no-index . /tmp/x"), "deny")
                self.assertEqual(evaluate(permissions, "shell", "git diff --stat --no-index a b"), "deny")
                self.assertEqual(evaluate(permissions, "shell", "git diff HEAD~1 -- src"), "allow")

    def test_fixer_agents_allow_only_validation_commands(self) -> None:
        denied = (
            'python3 -c "print(1)"',
            "python -c x",
            "npm exec x",
            "npm run anything",
            "npx node -e x",
            "bun -e x",
            "go run x.go",
            "cargo run",
            "make",
            "make all",
            "yarn node x",
            "pnpm exec x",
        )
        allowed = ("pytest -q", "pnpm typecheck", "cargo check", "go vet ./...", "npx tsc --noEmit")
        build = ("pnpm build", "cargo build")
        for stem in ("pr-comment-fixer", "review-fixer", "release-fix-applier"):
            permissions = generated_permissions(stem)
            build_effect = "allow" if stem == "release-fix-applier" else "deny"
            expected = {**dict.fromkeys(denied, "deny"), **dict.fromkeys(allowed, "allow")}
            expected |= dict.fromkeys(build, build_effect)
            for command, effect in expected.items():
                with self.subTest(agent=stem, command=command):
                    self.assertEqual(evaluate(permissions, "shell", command), effect)

    def test_restricted_agent_sensitive_rules_come_after_every_allow(self) -> None:
        for stem in RESTRICTED_AGENTS:
            with self.subTest(agent=stem):
                permissions = generated_permissions(stem)
                first_deny = next(
                    index
                    for index, rule in enumerate(permissions)
                    if rule["effect"] == "deny" and rule["action"] in {"read", "edit"}
                )
                broad_allows = [
                    index
                    for index, rule in enumerate(permissions)
                    if rule["effect"] == "allow" and rule["resource"] == "*"
                ]
                self.assertLess(max(broad_allows), first_deny)
                self.assertFalse(any(rule["effect"] == "ask" and rule["action"] == "read" for rule in permissions))

    def test_unrestricted_agents_keep_host_sensitive_read_defaults(self) -> None:
        permissions = generated_permissions("code-finder")

        self.assertEqual(permissions[-3:], ENV_READ_GUARDS)
        self.assertEqual(evaluate(permissions, "read", ".envrc"), "allow")
        self.assertFalse(any(rule["effect"] == "deny" and rule["action"] in {"read", "edit"} for rule in permissions))

    def test_restricted_agents_search_only_through_guarded_tools(self) -> None:
        from opencode_sensitive_policy import GUARDED_SEARCH_TOOLS

        for stem in RESTRICTED_AGENTS:
            with self.subTest(agent=stem):
                permissions = generated_permissions(stem)
                actions = {rule["action"] for rule in permissions}
                self.assertFalse(actions & set(GUARDED_SEARCH_TOOLS), permissions)
                for base, guarded in GUARDED_SEARCH_TOOLS.items():
                    self.assertEqual(evaluate(permissions, base, "*"), "deny")
                    self.assertEqual(evaluate(permissions, guarded, "*"), "allow")
                self.assertEqual(evaluate(permissions, "external_directory", "/elsewhere/*"), "ask")

    def test_guarded_search_mapping_keeps_external_directory_approval(self) -> None:
        from opencode_sensitive_policy import load_policy

        permissions = convert_tools_to_permissions(["Grep"], sensitive_policy=load_policy())
        self.assertEqual(
            permissions,
            [DENY_ALL, {"action": "ycc_grep", "resource": "*", "effect": "allow"}, EXTERNAL_DIRECTORY_ASK],
        )

    def test_unrestricted_agents_keep_builtin_search_actions(self) -> None:
        permissions = generated_permissions("code-finder")
        self.assertEqual(evaluate(permissions, "grep", "*"), "allow")
        self.assertEqual(evaluate(permissions, "glob", "*"), "allow")
        self.assertFalse(any(rule["action"].startswith("ycc_") for rule in permissions))

    def test_backport_open_code_prompt_uses_shell_workdir(self) -> None:
        source = (REPO_ROOT / "ycc" / "agents" / "backport-conflict-resolver.md").read_text(encoding="utf-8")

        output = transform_agent("backport-conflict-resolver", source, {})
        frontmatter, body = parse_frontmatter(output)

        self.assertIn("shell call's `workdir` set to `WORKTREE`", body)
        self.assertNotIn("git -C <WORKTREE>", body)
        self.assertFalse(
            any(rule["action"] == "shell" and " -C " in rule["resource"] for rule in frontmatter["permissions"])
        )


class SensitiveFilePolicyTestCase(unittest.TestCase):
    def test_registry_names_exactly_the_restricted_agents(self) -> None:
        from opencode_sensitive_policy import load_policy

        policy = load_policy()
        self.assertEqual(sorted(policy.restricted_agents), list(RESTRICTED_AGENTS))
        self.assertIn("*.env.example", policy.allow)

    def test_registry_rejects_unknown_agent_and_malformed_entries(self) -> None:
        from opencode_sensitive_policy import POLICY_PATH, load_policy

        valid = json.loads(POLICY_PATH.read_text(encoding="utf-8"))
        cases = {
            "unknown agent": {**valid, "restricted_agents": ["no-such-agent"]},
            "duplicate pattern": {**valid, "patterns": ["*.pem", "*.pem"]},
            "unexpected key": {**valid, "extra": True},
            "empty pattern": {**valid, "patterns": [""]},
            "absolute pattern": {**valid, "patterns": ["/etc/shadow"]},
        }
        with tempfile.TemporaryDirectory() as tmp:
            for label, payload in cases.items():
                with self.subTest(case=label):
                    path = Path(tmp) / "policy.json"
                    path.write_text(json.dumps(payload), encoding="utf-8")
                    with self.assertRaises(ValueError):
                        load_policy(path)

    def test_guard_template_must_register_the_granted_search_tools(self) -> None:
        import opencode_sensitive_policy as policy

        with tempfile.TemporaryDirectory() as tmp:
            template = Path(tmp) / "sensitive-guard.js"
            text = policy.GUARD_TEMPLATE_PATH.read_text(encoding="utf-8")
            template.write_text(text.replace('glob: "ycc_glob"', 'glob: "other_glob"'), encoding="utf-8")
            with patch.object(policy, "GUARD_TEMPLATE_PATH", template):
                with self.assertRaisesRegex(ValueError, "ycc_glob"):
                    policy.guard_payloads()

    def test_generated_guard_policy_matches_registry(self) -> None:
        from opencode_sensitive_policy import GUARD_DIR, POLICY_PATH, guard_drift, guard_payloads

        payloads = guard_payloads()
        self.assertEqual(
            json.loads(payloads[Path("policy.json")]),
            json.loads(POLICY_PATH.read_text(encoding="utf-8")),
        )
        self.assertEqual(json.loads(payloads[Path("package.json")])["main"], "index.js")
        self.assertEqual(GUARD_DIR, REPO_ROOT / ".opencode-plugin" / "ycc-sensitive-guard")
        self.assertEqual(guard_drift(), [])

    def test_guard_writer_prunes_stray_files_and_check_reports_them(self) -> None:
        from opencode_sensitive_policy import guard_drift, guard_payloads, write_guard

        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "ycc-sensitive-guard"
            (dest / "old").mkdir(parents=True)
            (dest / "old" / "stale.js").write_text("x", encoding="utf-8")
            self.assertIn("extra in repo: ycc-sensitive-guard/old/stale.js", guard_drift(dest))
            self.assertEqual(write_guard(dest, dry_run=False), set(guard_payloads()))
            self.assertEqual(guard_drift(dest), [])
            self.assertFalse((dest / "old").exists())

    def test_bundle_config_leaves_the_guard_to_the_package(self) -> None:
        from generate_opencode_plugin import build_opencode_config

        plugins = build_opencode_config()["plugins"]
        self.assertIsInstance(plugins, list)
        # @yandy-r/ycc-opencode ships and loads the guard; the merged settings
        # carry no local plugin path that would point at nothing.
        self.assertFalse([p for p in plugins if isinstance(p, str) and p.startswith("./")])


if __name__ == "__main__":
    unittest.main(verbosity=2)
