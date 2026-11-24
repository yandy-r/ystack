---
trigger: model_decision
description: When delegating complex work or requesting code review, use registered
  agents and parallelize only independent operations.
---

# Agent Orchestration

- Use runtime-registered agent descriptions as the authority for available agents.
- When registered, use planner for complex implementation and architect for architectural decisions;
  otherwise plan or design in the current session.
- After modifying code, request code-reviewer when registered (rust-reviewer for Rust-specific
  review); otherwise review the diff in the current session.
- Parallelize independent operations only; serialize work with dependencies or overlapping writes.
