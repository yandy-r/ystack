# TypeScript Testing Patterns: Advanced Testing

## Contents

- Parameterized Tests with `test.each`
- Property-Based Testing with fast-check
- Mocking
- Type-Level Testing
- Benchmarks
- CI Integration
- Alternatives to Vitest

## Parameterized Tests with `test.each`

### Table of Cases

```ts
import { describe, it, expect } from 'vitest';

describe('add', () => {
  it.each([
    { a: 2, b: 3, expected: 5 },
    { a: -1, b: -2, expected: -3 },
    { a: 0, b: 0, expected: 0 },
    { a: -1, b: 1, expected: 0 },
    { a: 1_000_000, b: 2_000_000, expected: 3_000_000 },
  ])('add($a, $b) → $expected', ({ a, b, expected }) => {
    expect(add(a, b)).toBe(expected);
  });
});
```

### Running a Whole Suite Against Multiple Configs

```ts
import { describe, it, expect, beforeEach } from 'vitest';

describe.each([{ db: 'postgres' as const }, { db: 'sqlite' as const }])('storage with $db', ({ db }) => {
  let store: Store;

  beforeEach(() => {
    store = makeStore(db);
  });

  it('writes and reads', async () => {
    await store.set('key', 'value');
    expect(await store.get('key')).toBe('value');
  });

  it('enforces constraints', async () => {
    await expect(store.set('', 'value')).rejects.toThrow();
  });
});
```

## Property-Based Testing with fast-check

### Basic Properties

```ts
import { describe } from 'vitest';
import { fc, test } from '@fast-check/vitest';
import { encode, decode } from './codec';

describe('codec', () => {
  test.prop([fc.string()])('encode then decode returns input', (input) => {
    const encoded = encode(input);
    const decoded = decode(encoded);
    return decoded === input;
  });

  test.prop([fc.array(fc.integer(), { maxLength: 100 })])('sort preserves length and is ordered', (arr) => {
    const sorted = [...arr].sort((a, b) => a - b);
    if (sorted.length !== arr.length) return false;
    for (let i = 1; i < sorted.length; i++) {
      if (sorted[i - 1]! > sorted[i]!) return false;
    }
    return true;
  });
});
```

### Custom Arbitraries

```ts
import { fc, test } from '@fast-check/vitest';
import { expect } from 'vitest';
import { User } from './user';

const validEmail = fc
  .tuple(fc.stringMatching(/^[a-z]{1,10}$/), fc.stringMatching(/^[a-z]{1,5}$/))
  .map(([user, domain]) => `${user}@${domain}.com`);

test.prop([validEmail])('accepts valid emails', (email) => {
  expect(() => new User('Test', email)).not.toThrow();
});
```

## Mocking

### `vi.fn()` — a Fresh Spy

```ts
import { describe, it, expect, vi } from 'vitest';

describe('processItems', () => {
  it('invokes the callback for each item', () => {
    const cb = vi.fn();
    processItems([1, 2, 3], cb);
    expect(cb).toHaveBeenCalledTimes(3);
    expect(cb).toHaveBeenNthCalledWith(1, 1);
    expect(cb).toHaveBeenLastCalledWith(3);
  });

  it('returns configured values on sequential calls', async () => {
    const loader = vi.fn<(id: string) => Promise<User>>();
    loader
      .mockResolvedValueOnce({ id: '1', name: 'Alice', email: 'a@x.com' })
      .mockRejectedValueOnce(new Error('not found'));

    await expect(loader('1')).resolves.toMatchObject({ name: 'Alice' });
    await expect(loader('2')).rejects.toThrow('not found');
  });
});
```

### `vi.spyOn()` — Wrap an Existing Method

```ts
import { describe, it, expect, vi, afterEach } from 'vitest';
import { UserService } from './user-service';

describe('UserService.saveUser', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('logs before saving', async () => {
    const logger = { info: vi.fn(), error: vi.fn() };
    const service = new UserService({ logger });
    const saveSpy = vi.spyOn(service, 'save');

    await service.saveUser({ id: '1', name: 'Alice', email: 'a@x.com' });

    expect(logger.info).toHaveBeenCalledWith(expect.stringContaining('saving user'));
    expect(saveSpy).toHaveBeenCalled();
  });
});
```

### `vi.mock()` — Module-Level Mock

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { sendEmail } from './mailer';
import { registerUser } from './auth';

vi.mock('./mailer', () => ({
  sendEmail: vi.fn().mockResolvedValue({ id: 'msg_1' }),
}));

describe('registerUser', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('sends a welcome email on success', async () => {
    await registerUser({ name: 'Alice', email: 'alice@example.com' });
    expect(sendEmail).toHaveBeenCalledWith(
      expect.objectContaining({
        to: 'alice@example.com',
        subject: expect.stringMatching(/welcome/i),
      })
    );
  });
});
```

### Dependency Injection > Module Mocks

```ts
// Good: inject an interface — no vi.mock() needed, fully type-checked
interface UserRepository {
  findById(id: string): Promise<User | null>;
  save(user: User): Promise<void>;
}

class UserService {
  constructor(private readonly repo: UserRepository) {}

  async getUser(id: string): Promise<User> {
    const user = await this.repo.findById(id);
    if (!user) throw new NotFoundError('user', id);
    return user;
  }
}

// Test with a plain fake — type-checked, no runner magic
it('throws when user is missing', async () => {
  const fakeRepo: UserRepository = {
    findById: async () => null,
    save: async () => {},
  };
  const service = new UserService(fakeRepo);
  await expect(service.getUser('missing')).rejects.toThrow(NotFoundError);
});
```

## Type-Level Testing

### `expectTypeOf` (Built Into Vitest)

```ts
import { describe, it, expectTypeOf } from 'vitest';
import { parseJSON, type JsonValue } from './json';

describe('parseJSON types', () => {
  it('returns JsonValue', () => {
    expectTypeOf(parseJSON).returns.toEqualTypeOf<JsonValue>();
  });

  it('accepts string input', () => {
    expectTypeOf(parseJSON).parameter(0).toEqualTypeOf<string>();
  });
});
```

### `expect-type` (Standalone Library)

```ts
import { expectTypeOf } from 'expect-type';
import type { User } from './user';

expectTypeOf<User>().toHaveProperty('email').toEqualTypeOf<string>();
expectTypeOf<User>().toHaveProperty('name').toEqualTypeOf<string>();
```

### `tsd` (Separate Type-Only Test Suite)

```ts
// test-d/user.test-d.ts
import { expectType, expectError } from 'tsd';
import { makeUser } from '..';

expectType<{ id: string; name: string }>(makeUser('alice'));
expectError(makeUser(42)); // should fail type check
```

**When to test types vs runtime:**

- Test **types** when authoring a library whose public API makes type-level
  guarantees (inference, conditional return types, branded outputs).
- Test **runtime** for everything else — types catch compile-time bugs; runtime
  tests catch the rest.

## Benchmarks

```ts
// src/join.bench.ts
import { bench, describe } from 'vitest';

const parts = ['hello', 'world', 'foo', 'bar', 'baz'];

describe('string join', () => {
  bench('plus operator', () => {
    let s = '';
    for (const p of parts) s += p;
  });

  bench('Array.join', () => {
    const _ = parts.join('');
  });

  bench('template literal', () => {
    const _ = `${parts[0]}${parts[1]}${parts[2]}${parts[3]}${parts[4]}`;
  });
});

// $ vitest bench
// BenchmarkJoin
//   plus operator      12,345,678 ops/sec
//   Array.join         18,765,432 ops/sec
//   template literal   22,109,876 ops/sec
```

For heavier, standalone benchmarks (stats, multiple runs, comparison reports),
reach for `tinybench` or `mitata` directly.

## CI Integration

```yaml
# .github/workflows/test.yml
name: test
on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
        with: { version: 10 }
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: 'pnpm'

      - run: pnpm install --frozen-lockfile

      - name: Type check
        run: pnpm exec tsc --noEmit

      - name: Lint
        run: pnpm exec biome ci .

      - name: Run tests with coverage
        run: pnpm exec vitest run --coverage

      - uses: codecov/codecov-action@v4
        with:
          files: ./coverage/lcov.info
```

## Alternatives to Vitest

The ecosystem has several other runners; reach for them when the constraints fit.

- **Jest** — legacy-common, large plugin ecosystem. Vitest's `describe` / `it` /
  `expect` / `vi.fn` / `vi.mock` surface is intentionally Jest-compatible, so
  migration usually means aliasing imports and adjusting config. Prefer Vitest for
  new projects — it's faster, has native ESM/TS, and shares config with Vite.
- **`node:test`** — Node's built-in test runner (Node 18+). Zero dependencies.
  Good fit for small libraries or when avoiding bundler/transform deps. Lacks
  Vitest's mocking ergonomics, snapshot polish, and watch-mode UI.
- **`bun test`** — Bun's built-in runner, Jest-compatible API, very fast
  install-plus-run cycle. Good on Bun-first projects; some Vitest plugins don't
  have Bun equivalents.
- **`deno test`** — Deno's built-in runner using the standard `@std/assert`
  module. Good for Deno-native code. Permissions model means integration tests
  need explicit flags.
- **Playwright** — end-to-end browser testing. _Complements_ Vitest rather than
  replacing it — use Vitest for unit and integration, Playwright for real-browser
  e2e flows.

**Remember**: Tests are documentation. They show how your code is meant to be used.
Keep them clear, fast, and strict-mode-compliant. The best test is one that fails
loudly when the behavior it describes breaks — and stays silent the rest of the time.
