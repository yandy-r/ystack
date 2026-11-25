# TypeScript Development Patterns: Async, Runtimes, and Tooling

## Contents

- Async and Concurrency
- Iterators and Higher-Order Functions
- Runtimes
- Tooling (Vite + Vitest Stack)

## Async and Concurrency

### Promise Combinators

```ts
// Good: parallel fetches, fail fast on any rejection
const [user, orders, prefs] = await Promise.all([fetchUser(id), fetchOrders(id), fetchPrefs(id)]);

// Good: collect all results including failures
const results = await Promise.allSettled([task1(), task2(), task3()]);
for (const r of results) {
  if (r.status === 'fulfilled') handle(r.value);
  else logError(r.reason);
}

// Good: race with timeout — abort the loser so it stops running
const taskController = new AbortController();
let timeout: ReturnType<typeof setTimeout>;
try {
  await Promise.race([
    longRunningTask(taskController.signal),
    new Promise<never>((_, reject) => {
      timeout = setTimeout(() => {
        reject(new Error('timeout'));
        taskController.abort();
      }, 5000);
    }),
  ]);
} finally {
  clearTimeout(timeout!);
  taskController.abort();
}

// Good: `Promise.any` — first success wins, all failures aggregate
const fastest = await Promise.any([
  fetch('https://mirror1.example.com/data'),
  fetch('https://mirror2.example.com/data'),
  fetch('https://mirror3.example.com/data'),
]);

// Bad: sequential awaits when parallel is possible
const userBad = await fetchUser(id);
const ordersBad = await fetchOrders(id); // waits unnecessarily
const prefsBad = await fetchPrefs(id);
```

### `AbortController` for Cancellation

```ts
// Good: cancellable fetch with timeout
async function fetchWithTimeout(url: string, ms: number): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try {
    return await fetch(url, { signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

// Good: thread an external signal through every async boundary
async function fetchUsers(signal?: AbortSignal): Promise<User[]> {
  const res = await fetch('/api/users', { signal });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

// Good: combine signals with `AbortSignal.any` (modern)
const combined = AbortSignal.any([userSignal, timeoutSignal]);
await fetchUsers(combined);
```

### Async Iterators for Streaming

```ts
// Good: stream large datasets without buffering everything in memory
async function* paginate<T>(
  fetchPage: (cursor: string | null) => Promise<{ items: T[]; next: string | null }>
): AsyncGenerator<T> {
  let cursor: string | null = null;
  do {
    const { items, next } = await fetchPage(cursor);
    for (const item of items) yield item;
    cursor = next;
  } while (cursor !== null);
}

// Usage
for await (const user of paginate(fetchUserPage)) {
  process(user);
  if (shouldStop()) break; // iterator cleans up automatically
}
```

## Iterators and Higher-Order Functions

### Prefer `map` / `filter` / `reduce` Over Imperative Loops

```ts
// Good: declarative and composable
const activeEmails = users.filter((u) => u.isActive).map((u) => u.email);

// Good: reduce for aggregation with explicit accumulator type
const byId = users.reduce<Record<string, User>>((acc, u) => {
  acc[u.id] = u;
  return acc;
}, {});

// Good: group with `reduce` on the ES2022 baseline
// (`Object.groupBy` needs an ES2024 lib and runtime)
const byRole = users.reduce<Record<string, User[]>>((acc, u) => {
  (acc[u.role] ??= []).push(u);
  return acc;
}, {});

// Bad: mutable accumulator with an imperative loop
const activeEmailsBad: string[] = [];
for (const u of users) {
  if (u.isActive) activeEmailsBad.push(u.email);
}
```

### Generators for Lazy Iteration

```ts
// Good: lazy range without allocating an array
function* range(start: number, end: number, step = 1): Generator<number> {
  if (!Number.isFinite(step) || step <= 0) throw new Error('step must be a positive finite number');
  for (let i = start; i < end; i += step) yield i;
}

for (const n of range(0, 1_000_000)) {
  if (n > 100) break; // only 101 numbers produced
}
```

### Immutability by Default

```ts
// Good: `readonly` signals intent and prevents accidental mutation
function total(items: readonly { price: number }[]): number {
  return items.reduce((sum, item) => sum + item.price, 0);
}

// Good: return new objects rather than mutating
function addItem(cart: readonly Item[], item: Item): readonly Item[] {
  return [...cart, item];
}

// Good: use `Readonly<T>` and `ReadonlyArray<T>` at API boundaries
function render(props: Readonly<{ name: string; items: ReadonlyArray<Item> }>): void {
  /* can't mutate props.items */
}
```

## Runtimes

TypeScript runs on many runtimes; pick based on deployment model, cold-start
tolerance, API surface needs, and operational complexity.

### Node (primary)

```ts
// Primary tooling host — Vite, Vitest, tsc, ESLint all run on Node
// Primary deploy target for servers, CLIs, scripts, build tools
// Use `node:` prefix for built-ins — forces Node resolver, avoids shadowing
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { setTimeout } from 'node:timers/promises';

await setTimeout(100);
const data = await readFile('config.json', 'utf8');
const hash = createHash('sha256').update(data).digest('hex');
```

### Deno

```ts
// Secure by default — explicit permissions at run time
// $ deno run --allow-read --allow-net script.ts
// Single-file tooling: deno fmt, deno lint, deno test, deno bundle
// npm compat: `import pkg from 'npm:pkg@1.0.0'`

const data = await Deno.readTextFile('config.json');
```

### Bun

```ts
// Fast install + run; Jest-compatible test runner; native bundler
// Drop-in Node compatibility for most packages
// $ bun install && bun run dev
// $ bun test

import { file } from 'bun';
const text = await file('config.json').text();
```

### Browser

```ts
// Use Web standards only — no Node built-ins
// Bundle for target browsers via Vite (`vite build`)
const res = await fetch('/api/config');
const config = await res.json();
```

### Edge (Cloudflare Workers, Vercel Edge, Deno Deploy)

```ts
// V8 isolates — cold starts measured in milliseconds
// Web standard APIs only; no `fs`, no long-lived processes
// Rely on fetch, URL, Request/Response, crypto.subtle, streams

export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    return new Response(`hello from ${url.pathname}`);
  },
};
```

## Tooling (Vite + Vitest Stack)

### Strict `tsconfig` Baseline

```jsonc
// tsconfig.json — recommended strict baseline
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "isolatedModules": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "verbatimModuleSyntax": true,
    "noEmit": true,
  },
  "include": ["src/**/*", "tests/**/*"],
  "exclude": ["dist", "node_modules"],
}
```

### Vite for Apps

```ts
// vite.config.ts — dev server + production bundle
import { defineConfig } from 'vite';
import { resolve } from 'node:path';

export default defineConfig({
  build: {
    target: 'es2022',
    sourcemap: true,
    rollupOptions: {
      input: { main: resolve(__dirname, 'index.html') },
    },
  },
  server: { port: 5173 },
});
```

### Vite for Libraries (`vite build --lib`)

```ts
// vite.config.ts — dual-publish library build
import { defineConfig } from 'vite';
import dts from 'vite-plugin-dts';
import { resolve } from 'node:path';

export default defineConfig({
  plugins: [dts({ rollupTypes: true })],
  build: {
    lib: {
      entry: resolve(__dirname, 'src/index.ts'),
      formats: ['es', 'cjs'],
      fileName: (format) => `index.${format === 'es' ? 'mjs' : 'cjs'}`,
    },
    rollupOptions: {
      // Don't bundle peer dependencies
      external: ['react', 'react-dom'],
    },
    sourcemap: true,
    minify: false, // let downstream bundlers minify
  },
});
```

### `vitest.config.ts` Sharing Vite's Pipeline

```ts
// vitest.config.ts — reuse dev/build transform pipeline for tests
import { defineConfig, mergeConfig } from 'vitest/config';
import viteConfig from './vite.config';

export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      globals: false,
      environment: 'node',
      coverage: {
        provider: 'v8',
        reporter: ['text', 'html', 'lcov'],
      },
    },
  })
);
```

### pnpm Workspaces for Monorepos

```yaml
# pnpm-workspace.yaml
packages:
  - 'packages/*'
  - 'apps/*'
```

```jsonc
// turbo.json — coordinate builds across workspaces
{
  "pipeline": {
    "build": { "dependsOn": ["^build"], "outputs": ["dist/**"] },
    "test": { "dependsOn": ["build"] },
    "lint": {},
  },
}
```

### Linting and Formatting

```jsonc
// biome.json — all-in-one formatter + linter (fastest option in 2026)
{
  "linter": {
    "enabled": true,
    "rules": { "recommended": true },
  },
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
  },
}
```

### When to Reach for Something Other Than Vite

- **tsup** — Node libraries with dozens of entry points; tsup's multi-entry support
  is simpler than Vite's lib mode for this shape.
- **esbuild directly** — custom build scripts where raw bundle speed matters and
  you want minimal config.
- **Rollup directly** — maximum control over output; Vite already uses Rollup for
  production builds, so you can drop into config-level Rollup when needed.
- **webpack** — legacy projects with loaders that haven't been ported to Vite.
