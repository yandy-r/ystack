# Data Fetching and Performance

## Contents

- Async gotchas
- Memoization
- Code splitting
- Virtualization

## Async gotchas

- A slow earlier request can overwrite a newer one: use `AbortController` or an `ignore` flag cleaned up by the effect.
- `fetch` does not reject on HTTP 4xx/5xx; check `response.ok`.
- Do not show the previous key's data as the new key's data.
- Debounce input before network calls and cancel superseded requests.
- In Next.js, fetch on the server and pass serializable data to client components.

## Memoization

- `useMemo` fits expensive pure work or stable identity; `useCallback` fits handlers for `React.memo` children or effect dependencies.
- `React.memo` fails when props are unstable: inline objects, arrays, functions, or JSX children.
- Never memoize to hide wrong dependencies; fix state ownership first.
- With React Compiler enabled, drop manual memoization unless profiling shows it helps.

## Code splitting

- Lazy-load heavy, rarely used, or browser-only components (charts, editors, 3D) at route or interaction boundaries.
- Give each `Suspense` a layout-stable fallback; use `next/dynamic` for client-only libraries that break SSR.

## Virtualization

- Use `@tanstack/react-virtual` once hundreds of rows are measurably slow.
- The scroll container needs a bounded height and `overflow: auto`.
- Measure dynamic row heights; offscreen rows are absent from the DOM, so keep list semantics and keyboard access working.
