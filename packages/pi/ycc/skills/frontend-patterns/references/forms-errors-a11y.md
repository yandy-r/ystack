# Forms, Errors, and Accessibility

## Contents

- Forms
- Error handling
- Keyboard and ARIA
- Dialogs and focus

## Forms

- Use react-hook-form + Zod (or TanStack Form); derive types with `z.infer` so schema and types cannot drift.
- Link errors with `aria-describedby`, set `aria-invalid`, and focus the first invalid field.
- Every input needs a real `<label>`; a placeholder is not a label.
- Re-validate on the server, map field errors back, and preserve input on failure.

## Error handling

- Error boundaries still need a class component (`getDerivedStateFromError`, `componentDidCatch`) unless a library supplies one.
- Boundaries do not catch event handlers, async callbacks, or server rendering errors; catch those explicitly.
- Wrap independent regions so one failure does not blank the app; reset when the failing input changes.
- In Next.js App Router use `error.tsx` per route and `global-error.tsx` for the root layout.
- Fallbacks offer retry or a path forward and never expose stack traces.

## Keyboard and ARIA

- Native `button`, `a`, `select`, `input`, `dialog` provide semantics and keyboard behavior for free.
- Custom widgets follow the WAI-ARIA Authoring Practices pattern: a combobox needs `aria-controls`, `aria-activedescendant`, option roles, and Arrow/Enter/Escape handling, not just `role="combobox"`.
- Manage composite widgets with roving tabindex or `aria-activedescendant`; never remove focus outlines without a replacement.

## Dialogs and focus

- Prefer Radix or Headless UI: they handle focus trap, scroll lock, portals, ARIA, and nested layers.
- A custom modal needs `role="dialog"`, `aria-modal="true"`, an accessible label, initial focus, Tab containment, Escape, and focus restored to the trigger on close.
- Hide background content from assistive tech while open.
