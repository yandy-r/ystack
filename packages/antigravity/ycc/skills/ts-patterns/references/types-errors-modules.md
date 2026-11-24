# TypeScript Development Patterns: Types, Errors, and Modules

## Contents

- Type System
- Error Handling
- Modules and Packaging

## Type System

### Discriminated Unions with Exhaustiveness

```ts
// Good: Impossible states unrepresentable; compiler enforces exhaustive handling
type ConnectionState =
  | { kind: 'disconnected' }
  | { kind: 'connecting'; attempt: number }
  | { kind: 'connected'; sessionId: string }
  | { kind: 'failed'; reason: string; retries: number };

function handle(state: ConnectionState): void {
  switch (state.kind) {
    case 'disconnected':
      return connect();
    case 'connecting':
      return state.attempt > 3 ? abort() : wait();
    case 'connected':
      return useSession(state.sessionId);
    case 'failed':
      return state.retries < 5 ? retry() : logFailure(state.reason);
    default: {
      // Adding a new variant forces handling here — `never` check
      const _exhaustive: never = state;
      throw new Error(`unhandled state: ${String(_exhaustive)}`);
    }
  }
}

// Bad: Optional fields create 2^N invalid combinations
interface BadState {
  disconnected?: boolean;
  connecting?: boolean;
  sessionId?: string;
  reason?: string;
}
```

### Generic Inference Flow

```ts
// Good: caller doesn't pass type arguments — inference does the work
function first<T>(items: readonly T[]): T | undefined {
  return items[0];
}
const n = first([1, 2, 3]); // n: number | undefined

// Good: `const` type parameter preserves literal types
function tuple<const T extends readonly unknown[]>(...items: T): T {
  return items;
}
const t = tuple('a', 1, true); // t: readonly ['a', 1, true]

// Good: `NoInfer` blocks inference from a specific position
function fill<T>(length: number, value: NoInfer<T>): T[] {
  return Array.from({ length }, () => value);
}

// Bad: type parameter never flows — always requires annotation
function first_bad<T>(): T {
  return null as T; // useless generic
}
```

### `satisfies` for Literal Preservation

```ts
// Good: type-checks against a wider shape but keeps literal types at use sites
const routes = {
  home: { path: '/', method: 'GET' },
  users: { path: '/users', method: 'GET' },
  createUser: { path: '/users', method: 'POST' },
} as const satisfies Record<string, { path: string; method: 'GET' | 'POST' }>;

// routes.home.method is still the literal 'GET', not string
type HomeMethod = typeof routes.home.method; // 'GET'

// Bad: annotation widens literals
const routesBad: Record<string, { path: string; method: string }> = {
  home: { path: '/', method: 'GET' },
};
type HomeMethodBad = (typeof routesBad)['home']['method']; // string — too wide
```

### Branded Types for Nominal Safety

```ts
// Good: Distinct nominal types prevent mixing up arguments
declare const UserIdBrand: unique symbol;
declare const OrderIdBrand: unique symbol;
type UserId = string & { readonly [UserIdBrand]: true };
type OrderId = string & { readonly [OrderIdBrand]: true };

function getOrder(user: UserId, order: OrderId): Promise<Order> {
  return db.orders.find({ user, id: order });
}

const u = 'u_123' as UserId;
const o = 'o_456' as OrderId;
getOrder(u, o); // ok
// getOrder(o, u); // ERROR — arguments swapped, compiler catches it

// Bad: naked primitives — swap compiles silently
function getOrderBad(userId: string, orderId: string): Promise<Order> {
  return db.orders.find({ userId, id: orderId });
}
```

### Conditional and Mapped Types

```ts
// Good: key remapping to build typed variants
type Getters<T> = {
  [K in keyof T as `get${Capitalize<K & string>}`]: () => T[K];
};

interface User {
  id: string;
  name: string;
}
type UserGetters = Getters<User>;
// { getId: () => string; getName: () => string }

// Good: conditional distribution over unions
type NonNull<T> = T extends null | undefined ? never : T;
type A = NonNull<string | null | number>; // string | number

// Bad: returning `any` from a conditional defeats the purpose
type BadReturn<T> = T extends string ? any : number; // `any` leaks to callers
```

### Narrowing with Type Guards and Assertion Functions

```ts
// Good: user-defined type guard
function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((v) => typeof v === 'string');
}

function join(value: unknown): string {
  if (isStringArray(value)) {
    return value.join(','); // value narrowed to string[]
  }
  throw new TypeError('expected string[]');
}

// Good: assertion function narrows after the call
function assertDefined<T>(value: T | null | undefined, msg: string): asserts value is T {
  if (value === null || value === undefined) throw new Error(msg);
}

const user = findUser(id);
assertDefined(user, `user ${id} not found`);
// user is now T, not T | null | undefined

// Bad: `as` cast hides runtime errors
function process(value: unknown) {
  const arr = value as string[]; // crashes if not actually string[]
  return arr.join(',');
}
```

## Error Handling

### `unknown` in `catch` — Narrow Explicitly

```ts
// Good: `useUnknownInCatchVariables` (strict) forces narrowing
try {
  await fetchUser(id);
} catch (err: unknown) {
  if (err instanceof FetchError) {
    logger.warn(err.message, { code: err.code });
  } else if (err instanceof Error) {
    logger.error(err.message, { stack: err.stack });
  } else {
    logger.error('non-Error thrown', { raw: String(err) });
  }
}

// Bad: assuming `err` is `Error` (only works without strict settings)
try {
  await fetchUser(id);
} catch (err) {
  console.log((err as Error).message); // runtime crash if err is a string
}
```

### Typed Error Classes for Boundaries

```ts
// Good: domain-specific errors carry structured data
class ValidationError extends Error {
  override readonly name = 'ValidationError';
  constructor(
    readonly field: string,
    message: string
  ) {
    super(`${field}: ${message}`);
  }
}

class NotFoundError extends Error {
  override readonly name = 'NotFoundError';
  constructor(
    readonly resource: string,
    readonly id: string
  ) {
    super(`${resource} ${id} not found`);
  }
}

function handleApiError(err: unknown): Response {
  if (err instanceof ValidationError) {
    return Response.json({ field: err.field, message: err.message }, { status: 400 });
  }
  if (err instanceof NotFoundError) {
    return new Response(null, { status: 404 });
  }
  logger.error('unhandled', { err });
  return new Response('Internal error', { status: 500 });
}
```

### `Result<T, E>` for Expected Failures

```ts
// Good: errors as values when failure is part of the contract
type Result<T, E> = { ok: true; value: T } | { ok: false; error: E };

function ok<T>(value: T): Result<T, never> {
  return { ok: true, value };
}
function err<E>(error: E): Result<never, E> {
  return { ok: false, error };
}

async function parseConfig(text: string): Promise<Result<Config, string>> {
  try {
    const data: unknown = JSON.parse(text);
    if (typeof data !== 'object' || data === null) return err('config must be an object');
    if (!('port' in data) || typeof data.port !== 'number') {
      return err('port must be a number');
    }
    return ok(data as Config);
  } catch (e) {
    return err(e instanceof Error ? e.message : String(e));
  }
}

const result = await parseConfig(text);
if (!result.ok) {
  console.error(result.error);
  return;
}
useConfig(result.value); // narrowed to Config
```

**When to throw vs return a `Result`:**

- **Throw** for truly exceptional/unexpected failures (programmer bugs, invariant violations, corrupted state).
- **Return** `Result`, `null`, or `undefined` for expected/handled failures (validation, missing resources, cache misses).
- At module boundaries, throw typed errors so callers can `instanceof`-narrow them.

## Modules and Packaging

### ESM-First with Dual-Publish `exports` Map

```jsonc
// package.json for a dual-publish library
{
  "name": "my-lib",
  "type": "module",
  "main": "./dist/index.cjs",
  "module": "./dist/index.mjs",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "types": "./dist/index.d.ts",
      "import": "./dist/index.mjs",
      "require": "./dist/index.cjs",
      "default": "./dist/index.mjs",
    },
    "./utils": {
      "types": "./dist/utils.d.ts",
      "import": "./dist/utils.mjs",
      "require": "./dist/utils.cjs",
    },
    "./package.json": "./package.json",
  },
  "files": ["dist"],
  "sideEffects": false,
}
```

### Module Augmentation

```ts
// Good: extend a third-party type without forking
import 'express';

declare module 'express' {
  interface Request {
    user?: { id: string; email: string };
  }
}

// Now `req.user` is typed across every handler
```

### `import.meta` and Top-Level Await

```ts
// Good: ESM-only `import.meta.url` for resolving sibling files
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const configPath = join(__dirname, 'config.json');

// Good at entry points: top-level await is fine in the root module
const config = await loadConfig();
startServer(config);

// Bad: top-level await inside a library module — forces every consumer to
// become async and blocks the module graph. Export an `init()` function instead.
```
