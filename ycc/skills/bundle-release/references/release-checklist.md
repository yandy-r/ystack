# Bundle Release Checklist

## Contents

- Phase 0: Pre-flight
- Phase 1: Decide Bump
- Phase 2: Bump Version
- Phase 3: Regenerate Derived Bundles
- Phase 4: Validate
- Phase 5: Draft Release Notes
- Phase 6: Commit and Tag (Manual)
- Phase 7: Publish (Optional)
- Rollback

This checklist is the artifact of record for a `ycc:bundle-release` run. It documents
every ordered step the skill performs, plus manual recovery instructions if a step fails.
Run it whenever you are preparing a new versioned release of the `ycc` plugin bundle.
The completed checklist for each release is saved to `docs/releases/<version>.md`.

---

## Phase 0: Pre-flight

- [ ] Working tree is clean (no uncommitted changes). `git status --porcelain` must return empty output.
- [ ] Currently on `main` branch (or a dedicated release branch with intent).
- [ ] Version fields are in parity: `ycc/settings/packages.json` is valid, every participating marketplace `plugins[]` entry and versioned package manifest agrees with `ycc/.claude-plugin/plugin.json` (`ycc-mods` excluded), and every included native manifest exists with a version regardless of `listed` (Claude `ycc` canonical, other Claude packages under `packages/claude/<key>/`, Codex under `.codex-plugin/<key>/`, Cursor under `packages/cursor/<key>/`).
- [ ] Deferred/excluded paths are suppressed from the bounded backstop, file-copy entries are skipped, and the included opencode npm manifest (`packages/opencode/<unscoped-key>/package.json`) exists and is in parity; unmodeled manifests remain covered by the bounded scan.
- [ ] `./scripts/validate.sh` passes on the pre-release tree.

Run: `ycc/skills/bundle-release/scripts/preflight.sh`

If pre-flight fails: resolve all failing conditions before proceeding. Do not skip.

---

## Phase 1: Decide Bump

- [ ] Review commits since the last tag:

  ```
  git log $(git describe --tags --abbrev=0)..HEAD --oneline
  ```

- [ ] Select the semver bump level (major / minor / patch) per `references/version-policy.md`.
- [ ] Record the chosen new version: `<new-version>`

---

## Phase 2: Bump Version

Run: `ycc/skills/bundle-release/scripts/bump-version.sh <new-version>`

- [ ] `ycc/.claude-plugin/plugin.json` — `version` field updated.
- [ ] `.claude-plugin/marketplace.json` — `metadata.version` and every `plugins[].version` updated.
- [ ] Versioned `ycc/package.json` updated; generated `packages/**` is check-only until regeneration.
- [ ] A missing or malformed `ycc/settings/packages.json` model fails the bump before any writes; an included native manifest missing or versionless does the same.
- [ ] Versionless marketplace entries and unmodeled optional manifests stay versionless; `ycc/mods` untouched.
- [ ] Diff reviewed: only version values and JSON formatting normalization (2-space indent, trailing newline) changed; unrelated fields preserved.

Malformed inputs cause no writes (all inputs are validated first); write errors have
best-effort rollback only, not crash-atomicity. Investigate the reported diagnostics. To undo a successful
bump, restore the modified files listed by `git status --short` with `git checkout --` (see Rollback).

---

## Phase 3: Regenerate Derived Bundles

Run: `./scripts/sync.sh`

- [ ] Generated `packages/`, `.agents/plugins/marketplace.json`, and `.agents-plugin/` regenerated when present.
- [ ] `.cursor-plugin/` fully regenerated.
- [ ] `.codex-plugin/` fully regenerated.
- [ ] `.opencode-plugin/` fully regenerated.
- [ ] No unexpected file changes (inspect with `git status`).

Do not hand-edit generated manifests; sync must finish before post-bump parity
checks can pass (`preflight.sh` also requires a clean committed tree).

If unexpected files appear: diff them before proceeding. Do not commit unreviewed generated output.

---

## Phase 4: Validate

Run: `./scripts/validate.sh`

- [ ] `validate-inventory.sh` passes.
- [ ] `validate-cursor-agents.sh` passes.
- [ ] `validate-cursor-skills.sh` passes.
- [ ] `validate-cursor-rules.sh` passes.
- [ ] `validate-codex-agents.sh` passes.
- [ ] `validate-codex-skills.sh` passes.
- [ ] `validate-codex-plugin.sh` passes.
- [ ] `validate-opencode-agents.sh` passes.
- [ ] `validate-opencode-skills.sh` passes.
- [ ] `validate-opencode-commands.sh` passes.
- [ ] `validate-opencode-plugin.sh` passes.
- [ ] Manifest JSON check passes.

If validation fails: do not proceed to Phase 5. Fix the reported error, re-run `./scripts/sync.sh` if needed, then re-run `./scripts/validate.sh`.

---

## Phase 5: Draft Release Notes

Run: `ycc/skills/bundle-release/scripts/draft-notes.sh <new-version>`

- [ ] `docs/releases/<new-version>.md` created from template.
- [ ] `Summary` section edited to describe the release in 1–3 sentences.
- [ ] `Upgrade Notes` section reviewed and updated (delete if not applicable).
- [ ] `Added`, `Changed`, `Removed`, and `Fixed` bullet sections reflect the actual changes from Phase 1.
- [ ] `Packages` section present with the generated table (Package, Runtime, Status, Mechanism, Listed, Version or target, Notes): included packages at the release version, deferred/excluded at their target, experimental/opt-in markers from the package model, and the file-copy fallback noted.
- [ ] Commit log section at the bottom preserved as-is (auto-populated by the script).

---

## Phase 6: Commit and Tag (Manual)

The skill does NOT auto-commit. After reviewing all changes, run:

```
for path in ycc/.claude-plugin/plugin.json .claude-plugin/marketplace.json \
            ycc/package.json \
            packages .agents/plugins/marketplace.json .agents-plugin \
            .cursor-plugin .codex-plugin .opencode-plugin .omp-plugin docs/inventory.json \
            docs/releases/<new-version>.md; do
  if [ -e "$path" ] || git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
    git add -A -- "$path"
  fi
done
git commit -m "chore(release): v<new-version>"
git tag v<new-version>
```

Omit `docs/releases/<new-version>.md` from the loop when `--skip-notes` was passed.
Absent paths are skipped; review additions/deletions in each generated directory.

- [ ] Commit authored with message `chore(release): v<new-version>`.
- [ ] Annotated or lightweight tag `v<new-version>` created.
- [ ] `git log --oneline -3` confirms the commit is on the expected branch.

---

## Phase 7: Publish (Optional)

The skill emits the following commands but does NOT execute them. Run them manually
when ready to publish:

```
git push origin main --tags
gh release create v<new-version> --notes-file docs/releases/<new-version>.md --title "v<new-version>"
```

- [ ] Push to origin executed (including tags).
- [ ] GitHub release created with the correct notes file.

---

## Rollback

If anything fails after Phase 1:

1. Restore tracked source and generated changes using this explicit allowlist
   (skips absent optional paths safely; also restores deleted tracked files):

   ```
   for path in ycc/.claude-plugin/plugin.json .claude-plugin/marketplace.json \
               ycc/package.json \
               packages .agents/plugins/marketplace.json .agents-plugin \
               .cursor-plugin .codex-plugin .opencode-plugin .omp-plugin docs/inventory.json; do
     if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
       git checkout -- "$path"
     fi
   done
   ```

   Review/remove any newly generated untracked files separately; the loop never
   deletes untracked files.

2. Restore generated bundles to pre-release state:

   ```
   ./scripts/sync.sh
   ```

3. Remove the draft release notes if they were created:

   ```
   rm -f docs/releases/<new-version>.md
   ```

4. Investigate the root cause, then restart from Phase 0.

---

See also: `references/version-policy.md`, `references/release-notes-template.md`, `AGENTS.md` (Testing Changes).
