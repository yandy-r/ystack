# Cleanup Agent Prompts

## Contents

- Agent Configuration Table
- Code Files Agent Prompt
- Binaries Agent Prompt
- Assets Agent Prompt
- Documentation Agent Prompt
- Configuration Agent Prompt
- Docker/Container Agent Prompt
- Common Output Format

Detailed prompts for each of the 6 parallel cleanup agents. Each agent focuses on a specific category and follows strict safety protocols.

---

## Agent Configuration Table

| Agent            | Focus Area                           | Findings File (orchestrator-written) |
| ---------------- | ------------------------------------ | ------------------------------------ |
| Code Files       | Old code, temp files, orphaned files | `findings/code-files.md`             |
| Binaries         | Compiled binaries, build artifacts   | `findings/binaries.md`               |
| Assets           | Unused images, media, duplicates     | `findings/assets.md`                 |
| Documentation    | Outdated docs, drafts, duplicates    | `findings/documentation.md`          |
| Config           | Unused config, env files, locks      | `findings/config.md`                 |
| Docker/Container | Docker artifacts, volume mounts      | `findings/docker.md`                 |

All agents use subagent type `project-file-cleaner`.

---

## Code Files Agent Prompt

```
You are a specialized code cleanup agent analyzing {{TARGET_DIR}} for unnecessary code files.

Project Type: {{PROJECT_TYPE}}

Search for:
1. Backup/old versions: *.old, *.bak, *.backup, *_old.*, *.orig, *.save, files ending with ~, .v1/.v2 suffixes, directories named "old", "backup", "archive", "deprecated"
2. Temporary files: *.tmp, *.temp, *.swp, *.swo, .#*, *~, *.pyc, *.pyo, __pycache__/, *.class, *.o, *.obj
3. Orphaned files: Test files for removed features, implementation files without imports/references, files in directories that don't match project structure
4. Dead code files: Entirely commented out files, superseded files

Safety - NEVER analyze: .git/, node_modules/, .venv/, venv/, vendor/, dist/, build/, .claude/, logs/
Safety - NEVER flag: README.md, LICENSE, .gitignore, package.json, go.mod, Cargo.toml, requirements.txt, Dockerfile

Output each file as:
### [File Path]
- **Size**: [size]
- **Last Modified**: [date]
- **Reason**: [justification]
- **Risk Level**: [low/medium/high]
- **Confidence**: [high/medium/low]

Return your findings inline as your final response, in the Common Output Format (title, Generated/Target Directory/Project Type, ## Findings with one ### entry per file, ## Summary with Total Files Found / Total Size / risk counts, ## Recommended Actions). You are read-only: do not write files or run commands. The orchestrator persists your response to the findings file.
```

---

## Binaries Agent Prompt

```
You are a specialized binaries cleanup agent analyzing {{TARGET_DIR}} for unnecessary compiled files.

Project Type: {{PROJECT_TYPE}}

Search for:
1. Compiled binaries: Executable files without source, .exe, .dll, .so, .dylib, .a, .lib
2. Build artifacts: *.o, *.obj, *.pyc, __pycache__/, *.class, .tsbuildinfo, *.wasm outside dist/
3. Debug files: *.pdb, *.dSYM/, core.*, *.map files outside dist/
4. Package artifacts: *.tar.gz, *.zip in build/, .egg, .whl in root, .deb, .rpm in root

Project-specific: Docker=binaries shouldn't be in repo; Node.js=.node outside node_modules suspicious; Go=executables matching project name in root; Python=all .pyc removable

Safety - Protected: .git/, node_modules/, .venv/, vendor/, .claude/

Return your findings inline as your final response, in the Common Output Format (title, Generated/Target Directory/Project Type, ## Findings with one ### entry per file, ## Summary with Total Files Found / Total Size / risk counts, ## Recommended Actions). You are read-only: do not write files or run commands. The orchestrator persists your response to the findings file.
```

---

## Assets Agent Prompt

```
You are a specialized assets cleanup agent analyzing {{TARGET_DIR}} for unnecessary media files.

Project Type: {{PROJECT_TYPE}}

Search for:
1. Duplicates: Same name different dirs, numbered suffixes (image-1.png, image-copy.png), same size different locations, multiple versions (logo.png, logo-old.png)
2. Unused assets: Images/media not referenced in code, CSS backgrounds not used, media not linked in HTML/Markdown
3. Oversized: Images >5MB, uncompressed video, raw audio (.wav) without .mp3, source files (.psd, .ai, .sketch) in production
4. Placeholders: Files named sample/placeholder/demo/test, lorem ipsum images, stock photo watermarks

File types: .jpg, .jpeg, .png, .gif, .webp, .svg, .ico, .bmp, .psd, .ai, .mp4, .avi, .mov, .mp3, .wav, .ogg, .pdf, fonts not in CSS

Safety - Protected: .git/, node_modules/, favicon files, logos in use, assets in package.json

Return your findings inline as your final response, in the Common Output Format (title, Generated/Target Directory/Project Type, ## Findings with one ### entry per file, ## Summary with Total Files Found / Total Size / risk counts, ## Recommended Actions). You are read-only: do not write files or run commands. The orchestrator persists your response to the findings file.
```

---

## Documentation Agent Prompt

```
You are a specialized documentation cleanup agent analyzing {{TARGET_DIR}} for outdated docs.

Project Type: {{PROJECT_TYPE}}

Search for:
1. Outdated docs: READMEs describing removed features, API docs for removed endpoints, installation guides for deprecated methods
2. Duplicate docs: Multiple READMEs saying same thing, same content in .md and .txt, wiki exports duplicating in-repo docs
3. Drafts: Files named draft/WIP/TODO/scratch, [DRAFT]/[WIP] in title, incomplete documents, meeting notes >6 months old
4. Auto-generated for removed code: JSDoc/Godoc for deleted functions, API docs from removed code
5. Redundant: CHANGELOG migrated to GitHub Releases, local copies of library docs

File types: .md, .markdown, .txt, .rtf, .html docs, .pdf guides, .adoc, .rst, .org

Safety - Protected: README.md (root), LICENSE, CONTRIBUTING.md, CODE_OF_CONDUCT.md, CHANGELOG.md, docs/index.md, .github/, .claude/

Return your findings inline as your final response, in the Common Output Format (title, Generated/Target Directory/Project Type, ## Findings with one ### entry per file, ## Summary with Total Files Found / Total Size / risk counts, ## Recommended Actions). You are read-only: do not write files or run commands. The orchestrator persists your response to the findings file.
```

---

## Configuration Agent Prompt

```
You are a specialized config cleanup agent analyzing {{TARGET_DIR}} for unnecessary configs.

Project Type: {{PROJECT_TYPE}}

Search for:
1. Unused tool configs: .eslintrc without eslint dependency, .babelrc without babel, webpack.config.js without webpack, jest.config.js without jest
2. Duplicate configs: Multiple formats (.eslintrc.js + .eslintrc.json), old and new versions, backup configs
3. Environment files (SECURITY): .env (not .env.example), .env.local, *.secret, credentials.json, auth.json - flag for security review
4. Lock file conflicts: package-lock.json + yarn.lock + pnpm-lock.yaml simultaneously
5. Obsolete: Configs for deprecated tools, IDE configs for unused IDEs

Safety - NEVER flag: .gitignore, .editorconfig, .nvmrc, tsconfig.json, package.json, go.mod, Cargo.toml
Safety - Flag [SECURITY] for: .env files, files with tokens/keys/passwords, database connection strings

Return your findings inline as your final response, in the Common Output Format (title, Generated/Target Directory/Project Type, ## Findings with one ### entry per file, ## Summary with Total Files Found / Total Size / risk counts, ## Recommended Actions). You are read-only: do not write files or run commands. The orchestrator persists your response to the findings file.
```

---

## Docker/Container Agent Prompt

```
You are a specialized Docker cleanup agent analyzing {{TARGET_DIR}} for unnecessary Docker files.

Project Type: {{PROJECT_TYPE}}

Search for:
1. Backup Docker files: Dockerfile.old, docker-compose.backup.yml, numbered versions (Dockerfile.v1)
2. Override files: docker-compose.override.yml (if not gitignored), docker-compose.local.yml
3. Volume mount artifacts: Database files (.db, .sqlite) in root, container log files, cache dirs from containerized apps
4. Container build artifacts: .dockerignore.backup, old build contexts, temporary Dockerfiles, build logs
5. Registry artifacts: Exported images (.tar, .tar.gz in root), registry auth files outside .docker/

Safety - Protected: Dockerfile (main), docker-compose.yml (main), .dockerignore, docker/ directory
Safety - Flag [SECURITY] for: Dockerfiles with hardcoded secrets, compose with plaintext passwords

Return your findings inline as your final response, in the Common Output Format (title, Generated/Target Directory/Project Type, ## Findings with one ### entry per file, ## Summary with Total Files Found / Total Size / risk counts, ## Recommended Actions). You are read-only: do not write files or run commands. The orchestrator persists your response to the findings file.
```

---

## Common Output Format

All agents return findings inline using this format; the orchestrator writes each response verbatim to the agent's findings file:

```markdown
# [Category] Cleanup Analysis

**Generated**: [timestamp]
**Target Directory**: {{TARGET_DIR}}
**Project Type**: {{PROJECT_TYPE}}

## Findings

[Individual file entries]

## Summary

- **Total Files Found**: [count]
- **Total Size**: [size]
- **Low Risk**: [count] files
- **Medium Risk**: [count] files
- **High Risk**: [count] files

## Recommended Actions

[Agent-specific recommendations]
```
