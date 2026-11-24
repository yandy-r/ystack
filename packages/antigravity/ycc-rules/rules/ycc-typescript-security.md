---
trigger: glob
description: When working on TypeScript/JavaScript files, apply secret management,
  input boundaries and security checks.
globs: '**/*.ts,**/*.tsx,**/*.js,**/*.jsx'
---

# TypeScript/JavaScript Security

## Secret Management

```typescript
// NEVER: Hardcoded secrets
const apiKey = 'sk-proj-xxxxx';

// ALWAYS: Environment variables
const apiKey = process.env.OPENAI_API_KEY;

if (!apiKey) {
  throw new Error('OPENAI_API_KEY not configured');
}
```

## Agent Support

- Use the `code-review` skill for security-focused reviews; validate external inputs, parameterize queries and avoid sensitive error responses
