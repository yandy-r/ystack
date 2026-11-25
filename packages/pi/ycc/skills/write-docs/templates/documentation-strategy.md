# Documentation Strategy

**Project**: {{PROJECT_NAME}}
**Generated**: {{GENERATED_DATE}}
**Mode**: {{MODE}}

## Audit Summary

### Existing Documentation

{{#if HAS_DOCS_DIR}}

- `docs/` directory exists with {{DOC_COUNT}} markdown files
  {{else}}
- `docs/` directory does not exist
  {{/if}}

{{#if HAS_README}}

- Root README.md exists ({{README_SIZE}} bytes)
  {{else}}
- Root README.md missing
  {{/if}}

{{#if HAS_API_SPEC}}

- API specifications found: {{API_SPEC_FILES}}
  {{else}}
- No API specifications (OpenAPI/GraphQL) found
  {{/if}}

### Code Documentation Coverage

| Language | Files | With Docs | Coverage |
| -------- | ----- | --------- | -------- |

{{#each LANGUAGES}}
| {{this.name}} | {{this.total}} | {{this.documented}} | {{this.percentage}}% |
{{/each}}

## Identified Gaps

### High Priority

{{#each HIGH_PRIORITY_GAPS}}

- [ ] **{{this.area}}**: {{this.description}}
      {{/each}}

### Medium Priority

{{#each MEDIUM_PRIORITY_GAPS}}

- [ ] **{{this.area}}**: {{this.description}}
      {{/each}}

### Low Priority

{{#each LOW_PRIORITY_GAPS}}

- [ ] **{{this.area}}**: {{this.description}}
      {{/each}}

## Agent Assignments

| Agent | Focus Area | Output Location | Priority Files |
| ----- | ---------- | --------------- | -------------- |

{{#each AGENT_ASSIGNMENTS}}
| {{this.agent}} | {{this.focus}} | {{this.output}} | {{this.files}} |
{{/each}}

## Scope

{{#if SCOPE}}
**Focused on**: {{SCOPE}}
{{else}}
**Full codebase** documentation
{{/if}}

## Next Steps

1. Review and approve this strategy
2. Deploy documentation agents in parallel
3. Review generated documentation
4. Verify links and cross-references
5. Update docs/README.md index

---

_Strategy prepared by write-docs skill_
