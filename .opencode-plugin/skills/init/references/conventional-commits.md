# Conventional Commits

## Contents

- Commit Types
- Scope Syntax
- Breaking Change Syntax
- Body and Footer Rules
- Internal Docs Convention
- Examples

Condensed Conventional Commits 1.0.0 spec. The generated `AGENTS.md` carries a one-line rule (not the types table); read this when a maintainer asks for the full reference.

---

## Commit Types

| Type       | Purpose                                         | Semver bump (release tooling) |
| ---------- | ----------------------------------------------- | ----------------------------- |
| `feat`     | New user-facing feature                         | **minor** once its set ships  |
| `fix`      | Bug fix                                         | **patch**                     |
| `docs`     | Documentation only                              | none                          |
| `refactor` | Code change that is neither a fix nor a feature | none                          |
| `perf`     | Performance improvement                         | none (patch if policy-set)    |
| `test`     | Adding or correcting tests                      | none                          |
| `build`    | Build system or external dependency changes     | none                          |
| `ci`       | CI/CD configuration changes                     | none                          |
| `chore`    | Maintenance tasks (tooling, housekeeping)       | none                          |
| `style`    | Formatting, whitespace — no logic change        | none                          |
| `revert`   | Reverts a previous commit                       | patch (if reverting a fix)    |

---

## Scope Syntax

```
feat(parser): add JSON streaming support
fix(api): handle null response from upstream
```

Scope is optional, lowercase, parenthesised, and describes the subsystem touched.

---

## Breaking Change Syntax

Two equivalent forms — use either (or both for belt-and-suspenders):

**Inline `!` (preferred for visibility):**

```
feat!: remove deprecated /v1 API endpoints
```

**Footer `BREAKING CHANGE:` (spec-compliant, required to be uppercase):**

```
feat(auth): migrate to OAuth 2.1

BREAKING CHANGE: cookie-based sessions removed; all clients must use bearer tokens.
```

Both forms trigger a **major** version bump in release tooling.

---

## Body and Footer Rules

- Blank line separates subject from body.
- Body is free-form; explain the _why_, not the _what_.
- Footers follow `Token: value` syntax (`BREAKING CHANGE`, `Closes`, `Co-authored-by`).
- `BREAKING CHANGE` footer MUST be uppercase — `breaking change` is not spec-compliant.

### Feature sets

Several `feat` commits often build one feature. Release tooling groups them into a
**feature set** (the commit scope by default, so `feat(sync): …` commits form the `sync`
set) and requires a minor only when a set is complete and user-visible; an in-progress
set ships in a patch. Add a `Feature-Set: <name>` footer when a feature spans scopes.

---

## Internal Docs Convention

Use `docs(internal): …` for documentation commits that should be excluded from release notes
(design docs, ADRs, internal how-tos). Release tooling is typically configured to skip the
`internal` scope.

---

## Examples

```
# simple feature
feat: add dark mode toggle

# fix with scope
fix(auth): prevent session fixation on login

# breaking change (! form)
feat!: drop support for Node 16

# breaking change (footer form)
feat(config): switch to TOML format

BREAKING CHANGE: YAML config files are no longer supported; migrate to config.toml.

# multi-line body
refactor(storage): replace SQLite with PostgreSQL

SQLite could not handle concurrent writes under load.

Closes #142

# revert
revert: feat(api): add rate limiting

Reverts commit abc1234. Rate limiting caused false positives for mobile clients.
```

---
