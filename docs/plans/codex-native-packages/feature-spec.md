# Feature Spec: Codex native packages (YAN-1131)

## Executive Summary

Generate independently installable Codex workflow and MCP packages from the canonical package model and authored ycc sources. Preserve today's legacy combined plugin and discovered catalog until the v6.0.0 flip. An explicit `--native-output DIR` produces the complete future repository-shaped distribution outside the checkout for verification. Native resources must resolve from installed cache documents, and MCP credentials must use Codex pass-through variables rather than literal Claude interpolation.

## External Dependencies

### APIs and Services

Codex CLI 0.161.0 was tested against the local Git fixture, satisfying the requested run on “0.160 or later”; that run alone did not establish 0.160.0 as the minimum compatible version. YAN-1163 subsequently ran the exact `codex-cli 0.160.0` official binary against an anonymous public GitHub HTTPS fixture, full and sparse, with both packages installed independently (payload version 5.3.0); see [public fork install evidence](../../internal/spikes/codex-public-fork-install.md). Later runtimes, authenticated/private transports, and final v6.0.0 payload bytes were not tested. Native catalog discovery prefers `.agents/plugins/marketplace.json`; source paths are root-relative local paths. No new library dependency.

- [Plugin loader](https://github.com/openai/codex/blob/rust-v0.161.0/codex-rs/core-plugins/src/loader.rs): default `.mcp.json` is discovered even without a manifest declaration.
- [MCP parser](https://github.com/openai/codex/blob/rust-v0.161.0/codex-rs/codex-mcp/src/plugin_config.rs): `mcpServers` wrapper accepts Codex server fields.
- [Skill path semantics](https://github.com/openai/codex/blob/rust-v0.161.0/codex-rs/ext/skills/src/catalog_prompt.rs): resources resolve relative to expanded SKILL.md.

## Business Requirements

### User Stories

As a maintainer, I want to generate and install the complete future Codex distribution without activating it for current users. As a future v6 user, I want workflow skills and MCP connections independently selectable as `ycc@ycc` and `ycc-mcp@ycc`.

### Business Rules

1. Default legacy manifest, MCP and discovered `local-ycc-plugins` catalog remain byte-identical while native packages are unlisted.
2. New default `ycc-mcp` files are dormant and unreferenced by any catalog or installer.
3. Included native Codex packages derive from packages.json; excluded hooks emit nothing.
4. Version comes from ycc/.claude-plugin/plugin.json.
5. Native output includes the eligible unlisted set only through explicit opt-in; production listing remains YAN-1140.
6. No actual credentials enter generated output. Native MCP uses the existing Codex translator and overrides under a `mcpServers` wrapper.

### Success Criteria

- A Git-fork fixture installs both package IDs on Codex 0.161.0, satisfying the requested “0.160 or later” run, with complete independent cache payloads and usable helper paths under clean HOME. YAN-1163 additionally observed the same full/sparse independent installs, helper execution, and MCP metadata assertions on exact Codex 0.160.0 over anonymous public GitHub HTTPS ([evidence](../../internal/spikes/codex-public-fork-install.md)). Production listing (YAN-1140) and migration/dedupe (YAN-1139) remain closed gates.
- Codex validator passes.
- Default behavior remains unchanged; no hooks are generated.

## Technical Specifications

### Architecture

Extend scripts/generate_codex_plugin.py; reuse package_model.load_package_model and generate_codex_skills.write_tree. Default generation adds only unlisted MCP manifest/config. Explicit native output emits `.codex-plugin/ycc/{skills,shared,.codex-plugin/plugin.json}`, `.codex-plugin/ycc-mcp/{.codex-plugin/plugin.json,.mcp.json}`, and `.agents/plugins/marketplace.json` named `ycc`.

### Data Models

Native skills manifest declares `skills: ./skills/`, no MCP field/file. MCP-only manifest declares `mcpServers: ./.mcp.json`, no skills payload. Catalog entries have local sources `./.codex-plugin/<package>`, AVAILABLE/ON_INSTALL policy. Never serialize `listed` into runtime metadata. Native MCP payload is `{mcpServers: build_codex_mcp_config()[mcp_servers]}`.

### API Design

`generate-codex-plugin.sh --native-output DIR [--check|--dry-run]`: output is a dedicated external repository-shaped directory. Reject filesystem root, checkout overlap in either direction, and managed-path symlinks before mutation. Check is read-only; dry-run creates nothing. Reuse owned-tree pruning; remove stale native ycc MCP and reject forbidden hooks. Preserve unrelated neighboring files.

Native skill generation adds an opt-in path policy. Replace authored plugin-root and transformed legacy-home resource references with document-relative paths calculated from their emitted document. Add a short instruction to resolve bundled resources from the installed document path, retain user's repository cwd, and execute resolved absolute helper paths. Legacy rendering stays unchanged.

## UX Considerations

### User Workflows

Current users see no change. Maintainer creates external output, verifies it, commits it into an isolated Git fixture and registers that fixture in fresh HOME/CODEX_HOME. After installation, cache contains two independently enabled package IDs. Native skills expose installed paths; resource instructions do not assume shell cwd is the plugin.

Existing local-ycc-plugins migration/dedupe is YAN-1139, not this issue. Public install guides stay unwired until the docs flip.

## Recommendations

### Implementation Approach

Keep the existing generator rather than introducing another pipeline or duplicate checked-in skills tree. Use explicit native export because renaming/emptying the existing catalog is observable even when no entries are listed. Keep the future catalog builder listed-aware, with explicit export opting into included candidates. Defer actual production listing/routing to YAN-1140.

### Technology Decisions

Use Python standard library plus existing dependencies. Native MCP translates `${XERO_*}` references into `env_vars`; legacy MCP bytes remain unchanged. Document-relative skill resource paths follow verified Codex loader semantics; no invented CODEX_PLUGIN_ROOT variable.

## Risk Assessment

### Technical Risks

| Risk                                   | Mitigation                                                           |
| -------------------------------------- | -------------------------------------------------------------------- |
| Early visible cutover                  | Preserve legacy catalog and combined ycc by default                  |
| Installed-cache helper path breaks     | Native path policy and cache-based helper execution proof            |
| MCP secrets passed literally           | Reuse Codex env_vars translation                                     |
| Generator overwrites source/user files | External output confinement and owned-only pruning/check             |
| Hooks accidentally emitted             | Filter included/native model entries; no hooks files or declarations |

### Security Considerations

No literal secrets found. Preserve credential references/pass-through names, never materialize values from generation environment. Git fixture uses isolated HOME/CODEX_HOME and pinned commit; file-only transport avoids remote authentication. Do not claim OS-level network isolation or public GitHub transport proof from that fixture.

## Task Breakdown Preview

1. Native path policy and critical resource tests; in parallel, native metadata/export generation and output safety; shared interface fixed before dispatch.
2. Validator, unit coverage and hermetic install harness after generator contract is settled.
3. Scoped generation/lint/tests and actual Codex install/helper/MCP inspection; adversarial review; documentation evidence.

## Decisions Needed

None awaiting user input. Safe choices above preserve existing users and keep activation gated. A genuine API limitation or contradictory acceptance criterion must be reported, not silently reduced.
