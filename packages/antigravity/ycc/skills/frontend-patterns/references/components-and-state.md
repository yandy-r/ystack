# Components and State

## Contents

- Composition
- Custom hooks
- State placement
- Context and reducers

## Composition

- Compound components share implicit state through a private context; parts throw a descriptive error outside their parent.
- Use render props only when the caller must render with component-owned data; otherwise use a hook.
- Model variants as a union (`'default' | 'outlined'`), not unrelated booleans.

## Custom hooks

- Use functional updates (`setValue((v) => !v)`) to avoid stale closures.
- Inline callbacks or option objects in effect dependencies rerun the effect each render. Keep the latest callback in a ref or require memoized input.
- Debounce with `setTimeout` plus cleanup; trigger side effects from the debounced value.
- Prefer TanStack Query or SWR to a custom `useQuery`: they handle caching, dedupe, retries, and cancellation.

## State placement

| Need                           | Use                       |
| ------------------------------ | ------------------------- |
| Local state                    | `useState` / `useReducer` |
| Small shared state             | Context + `useReducer`    |
| Larger client state            | Zustand                   |
| Large app, devtools, RTK Query | Redux Toolkit             |
| Server state                   | TanStack Query or SWR     |

Do not lift state higher than needed or store server data in Redux/Zustand.

## Context and reducers

- Split state and dispatch contexts so dispatch-only consumers skip state rerenders.
- Memoize provider values when parents rerender often.
- Keep reducers pure with exhaustive typed actions; wrap context access in a hook that throws without a provider.
- Keep fast-changing values (pointer, input text) out of app-wide context.
