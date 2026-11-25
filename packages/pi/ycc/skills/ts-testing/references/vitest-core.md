# TypeScript Testing Patterns: Vitest Core

## Contents

- TDD Workflow for TypeScript
- Unit Tests
- Assertions
- Error and Rejection Testing
- Integration Tests
- Async Tests and Fake Timers

## TDD Workflow for TypeScript

### The RED-GREEN-REFACTOR Cycle

```
RED      → Write a failing test first
GREEN    → Write minimal code to pass the test
REFACTOR → Improve code while keeping tests green
REPEAT   → Continue with next requirement
```

### Step-by-Step TDD in TypeScript

```ts
// calculator.ts — RED: stub with a placeholder that throws
export function add(a: number, b: number): number {
  throw new Error('not yet implemented');
}
```

```ts
// calculator.test.ts — write the test first
import { describe, it, expect } from 'vitest';
import { add } from './calculator';

describe('add', () => {
  it('sums two numbers', () => {
    expect(add(2, 3)).toBe(5);
  });
});

// $ vitest
// FAIL  calculator.test.ts > add > sums two numbers
//   Error: not yet implemented
```

```ts
// GREEN: minimal implementation
export function add(a: number, b: number): number {
  return a + b;
}
// $ vitest → PASS, then REFACTOR while tests stay green
```

## Unit Tests

### Colocated Unit Tests

```ts
// src/user.ts
export class User {
  constructor(
    public readonly name: string,
    public readonly email: string
  ) {
    if (!email.includes('@')) {
      throw new Error(`invalid email: ${email}`);
    }
  }

  get displayName(): string {
    return this.name;
  }
}
```

```ts
// src/user.test.ts — colocated with the source
import { describe, it, expect } from 'vitest';
import { User } from './user';

describe('User', () => {
  it('creates a user with a valid email', () => {
    const user = new User('Alice', 'alice@example.com');
    expect(user.displayName).toBe('Alice');
    expect(user.email).toBe('alice@example.com');
  });

  it('rejects invalid emails', () => {
    expect(() => new User('Bob', 'not-an-email')).toThrow('invalid email');
  });
});
```

**File conventions:**

- `.test.ts` or `.spec.ts` are picked up by Vitest by default.
- Colocation (`src/user.ts` + `src/user.test.ts`) or a `__tests__/` directory both
  work — colocation is more common and easier to navigate.
- Configure via `test.include` in `vitest.config.ts`.

## Assertions

```ts
import { expect } from 'vitest';

expect(2 + 2).toBe(4); // strict equality
expect({ a: 1 }).toEqual({ a: 1 }); // deep equality
expect([1, 2, 3]).toContain(2); // array contains
expect('hello world').toMatch(/world/); // regex match
expect(value).toBeDefined(); // not undefined
expect(value).toBeNull(); // strict null
expect(value).toBeTruthy(); // JS truthy
expect(0.1 + 0.2).toBeCloseTo(0.3); // float compare
expect({ a: 1, b: 2, c: 3 }).toMatchObject({ a: 1 }); // partial deep equal
expect(fn).toHaveBeenCalledWith('expected-arg'); // spy assertion

// Snapshots
expect(result).toMatchInlineSnapshot(`
  {
    "items": [1, 2, 3],
    "status": "ok",
  }
`);
```

### Custom Matchers

```ts
import { expect } from 'vitest';

expect.extend({
  toBeValidEmail(received: string) {
    const pass = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(received);
    return {
      pass,
      message: () => `expected ${received} ${pass ? 'not ' : ''}to be a valid email`,
    };
  },
});

// Extend Vitest's type surface
declare module 'vitest' {
  interface Assertion<T = unknown> {
    toBeValidEmail(): T;
  }
}

expect('alice@example.com').toBeValidEmail();
```

## Error and Rejection Testing

```ts
import { describe, it, expect } from 'vitest';

describe('parseConfig', () => {
  it('throws on invalid input', () => {
    expect(() => parseConfig('}{invalid')).toThrow();
    expect(() => parseConfig('}{invalid')).toThrow(/invalid JSON/);
    expect(() => parseConfig('}{invalid')).toThrow(SyntaxError);
  });
});

describe('fetchUser', () => {
  it('rejects for missing users', async () => {
    await expect(fetchUser('missing')).rejects.toThrow('not found');
    await expect(fetchUser('missing')).rejects.toBeInstanceOf(NotFoundError);
  });

  it('resolves for valid users', async () => {
    await expect(fetchUser('alice')).resolves.toMatchObject({ name: 'Alice' });
  });
});
```

## Integration Tests

### File Layout

```text
my-pkg/
├── src/
│   ├── app.ts
│   └── app.test.ts        # unit tests colocated
├── tests/                 # integration tests
│   ├── api.test.ts
│   ├── helpers.ts
│   └── setup.ts           # global setup/teardown
├── vitest.config.ts
```

### Global Setup and Teardown

```ts
// tests/setup.ts
import { afterAll, beforeAll } from 'vitest';
import { startTestServer, stopTestServer } from './helpers';

beforeAll(async () => {
  await startTestServer();
});

afterAll(async () => {
  await stopTestServer();
});
```

```ts
// vitest.config.ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    setupFiles: ['./tests/setup.ts'],
    include: ['src/**/*.test.ts', 'tests/**/*.test.ts'],
  },
});
```

### Writing an Integration Test

```ts
// tests/api.test.ts
import { describe, it, expect, beforeEach } from 'vitest';
import { App, Config } from '../src/app';

describe('full request lifecycle', () => {
  let app: App;

  beforeEach(() => {
    app = new App(Config.testDefault());
  });

  it('handles /health', async () => {
    const res = await app.handleRequest('/health');
    expect(res.status).toBe(200);
    expect(await res.text()).toBe('OK');
  });

  it('returns 404 for unknown paths', async () => {
    const res = await app.handleRequest('/nope');
    expect(res.status).toBe(404);
  });
});
```

## Async Tests and Fake Timers

### Native Async Tests

```ts
import { describe, it, expect } from 'vitest';

describe('async operations', () => {
  it('resolves after fetching', async () => {
    const data = await fetchData('/api');
    expect(data.items).toHaveLength(3);
  });

  it('races against a timeout', async () => {
    // Abort the loser so slowOp stops running after the timeout wins
    const controller = new AbortController();
    let timeout: ReturnType<typeof setTimeout>;
    try {
      await expect(
        Promise.race([
          slowOp(controller.signal),
          new Promise<never>((_, reject) => {
            timeout = setTimeout(() => {
              reject(new Error('timeout'));
              controller.abort();
            }, 100);
          }),
        ])
      ).rejects.toThrow('timeout');
    } finally {
      clearTimeout(timeout!);
      controller.abort();
    }
  });
});
```

### Fake Timers

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

describe('debounce', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('delays execution by the wait period', () => {
    const cb = vi.fn();
    const debounced = debounce(cb, 1000);

    debounced();
    expect(cb).not.toHaveBeenCalled();

    vi.advanceTimersByTime(1000);
    expect(cb).toHaveBeenCalledTimes(1);
  });

  it('advances all pending timers', async () => {
    const spy = vi.fn();
    setTimeout(spy, 5000);
    await vi.runAllTimersAsync();
    expect(spy).toHaveBeenCalled();
  });
});
```
