# Animation

## Contents

- Framer Motion lists and modals
- Motion safety

## Framer Motion lists and modals

- `exit` animations work only inside `AnimatePresence`; its direct children must carry stable data-ID keys, never indexes.
- Conditional children must be direct children of `AnimatePresence`; a non-motion wrapper hides exits.
- Use `layout` for reordering and `mode="popLayout"` so exiting items release space.
- Keep transitions around 150-300 ms and stagger sparingly.
- Animate modal overlay and content opacity/transform only; click-to-close must ignore clicks inside content.
- Animation does not replace focus trap, Escape handling, or labels.

## Motion safety

- Respect `prefers-reduced-motion` via `useReducedMotion()` or `MotionConfig reducedMotion="user"`; reduce travel and scale, opacity is usually fine.
- Animate `transform` and `opacity`, not layout properties; use `will-change` only for sustained animations.
- Never rely on animation alone to communicate state.
