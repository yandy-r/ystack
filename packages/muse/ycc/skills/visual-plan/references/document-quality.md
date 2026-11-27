# Plan document quality — single source of truth

## Contents

- Block families (resolve exact tags via `get-plan-blocks`)
- Decisions
- Diagram primitives
- Open questions live at the bottom as a form
- `custom-html` is a bounded escape hatch only
- Verification must exercise the real workflow

The canonical quality bar for the plan document below the canvas: how it reads,
which block families to use, how open questions are surfaced, and the pre-handoff
check. Read it in full before authoring the plan document. Resolve exact tag
names and field shapes against the live catalog (`get-plan-blocks` for hosted
sharing or the pinned local-files CLI catalog) — the families below are the bar,
the catalog is the authority.

---

**The document is a serious technical plan, not marketing.** Write it the way a
strong implementation plan reads: outcome-first, prose-first, self-contained, and
specific. State the objective and what "done" means, the scope and non-goals, the
proposed approach with key decisions and their rationale, ordered steps that name
real files / symbols / actions / data shapes, the risks, and a closing
verification step (tests, build, or a checkable behavior). Replace vague prose
with specifics; never ship a step like "make it work." No hero art, gradients,
logos, nav bars, slogans, value props, giant landing-page headings, or marketing
cards unless the user explicitly asks.

**Every published plan must stand alone.** Even when revising an existing plan,
the output is a plan to do the work, not a changelog of the conversation. Do not
write phrases like "preserve the previous plan", "do not drop the old idea", "as
discussed above", "this revision", "unlike the prior version", or "correction
from the earlier plan". Fold the right decisions into the plan as normal
objective, architecture, scope, and roadmap prose. A reviewer who opens the plan
from a link with no chat history should understand it. Avoid negative framing
that only makes sense against absent context ("not the old mode", "not just X")
unless the contrast is defined in the plan and genuinely helps; state the
positive model directly.

**Make abstract plans instantly legible.** If the idea is broad, strategic, or
intended for a third-party reviewer, put one concrete product snapshot near the
top before dense architecture, mode tables, manifests, or roadmaps. For
UI-capable concepts, that snapshot is usually a top-canvas app state plus a short
paragraph that says what the user sees and what changes under the hood. Then put
mechanics, data flow, sync boundaries, and implementation detail in separate
diagrams or document sections.

**Preserve the user's level of abstraction.** A motivating use case is not
automatically the architecture. When the prompt describes a broader framework,
product mode, or reusable primitive, separate the reusable core from specific
apps, providers, customers, scripts, or launch examples. Use the concrete example
to make the plan understandable, then make clear which parts are core, which are
app-specific adapters, and which are future examples.

**When top visuals exist, they and the document never duplicate each other.** For
UI work, the UI story lives in the top visual surface: canvas artboards for static
inspection, plus prototype tabs when the flow should be functional. The document
carries the technical depth the visuals cannot show — concrete file/symbol maps,
API and data contracts, code snippets, migration or implementation phases, risks,
and validation. For architecture/code reviews, invert that: the document is the
visual surface, and each recommendation carries its own nearby inline `diagram`
block plus file evidence. Repeat a wireframe in the document only for a genuinely
new detail view or comparison. Skip the visual surface entirely for non-visual
work and write a clean rich document.

## Block families (resolve exact tags via `get-plan-blocks`)

Use the right block, and make it carry substance:

- **`rich-text`** — plan prose with real bold/italic/code/links and nested lists.
- **`annotated-code`** — the file map: for a load-bearing file, prefer the
  annotated walkthrough over a bare `code` block. Carry the real,
  syntax-highlighted code AND anchor short margin notes to the lines that
  actually change (the new action, the changed schema, the wiring point). Each
  annotation is `{ lines: "12" | "12-18"; label?; note }`; keep a few high-signal
  notes per file, not one per line. Highlight only files worth reading.
- **`code`** — a throwaway snippet with nothing to call out. When more than one
  file matters, group blocks in a vertical `tabs` block rather than a bespoke
  container.
- **`tabs`** — multiple states, directions, or comparisons. A tab that reveals
  only prose usually means the plan is under-specified — include a relevant visual
  unless the tab is intentionally document-only.
- **`columns`** — side-by-side before/after or current/target comparisons where
  each side needs real nested blocks; label the columns clearly.
- **`diagram`** — two-dimensional architecture, dependency, data-flow, or state
  relationships, only when it clarifies something real. See **Diagram primitives**
  below.
- **`table`** — scannable structured data.
- **`checklist`** — copy the catalog example verbatim: items need `id` and
  `label`.
- **`callout`** — for a decision you have committed to, use `tone="decision"`
  (optionally with a `columns` block weighing the options). Use other tones for
  concise assumptions or risks in the relevant section.
- **`question-form`** — the bottom-only Open Questions block (see below).
- **`custom-html`** — a bounded escape hatch only (see below).

## Decisions

- If the reviewer must still pick between a genuinely-open either/or, put it in
  the bottom Open Questions `question-form` as a `single` question — one option
  per real alternative, each with a short detail and `recommended: true` on the
  one you would choose. Do not also restate the same choice elsewhere.
- If you have already committed to an approach, state it as settled prose or a
  `callout` with `tone="decision"` — never as a confusing mid-document form for a
  question you have already answered.

## Diagram primitives

For architecture/code diagrams, prefer `data.html` / `data.css` with semantic
HTML and inline SVG so the diagram can use panels, layers, matrices, arrows,
annotations, and responsive layout directly. Author with renderer-owned
primitives: `.diagram-panel`, `.diagram-card`, `.diagram-node`, `.diagram-box`,
`.diagram-pill`, `.diagram-muted`, and `[data-rough]` for sketchy mode. They map
to the theme variables `--wf-ink`, `--wf-muted`, `--wf-line`, `--wf-paper`,
`--wf-card`, `--wf-accent`, `--wf-accent-soft`, `--wf-warn`, and `--wf-ok`, and
switch to the sketch font plus rough.js outlines in sketchy mode.

- Do NOT set `font-family` and do NOT hard-code hex, rgb, or hsl colors in
  diagram HTML or CSS.
- Prefer standard two-dimensional layouts — paired before/after panels, layered
  diagrams, swimlanes, dependency maps, matrices, or grouped regions; do not
  default to left-to-right chains, and use a line only when the relationship is
  truly a sequence.
- Leave room for the sketch font: keep labels short, give nodes generous width,
  and place boundary/annotation labels in unused space — labels must not overlap
  nodes, connectors, or each other.
- For small text/SVG changes to an existing HTML diagram, use **`patch-diagram-html`**
  with a unique `find`/`replace` snippet instead of resending the whole
  `data.html` string. Use legacy `nodes` / `edges` only for small previews or
  truly sequential flows.

## Open questions live at the bottom as a form

Surface answerable unresolved decisions in a final `question-form` block titled
"Open Questions" so the renderer presents it as a distinct section. That bottom
form is the ONLY place that enumerates the open questions: never add a second
"Open Questions" heading, list, or recap of the same questions earlier in the
document. A one-line pointer in the overview prose ("a few decisions are still
open — see Open Questions below") is fine.

- Use `single` or `multi` for clear choices, `freeform` for constraints,
  `recommended: true` for the default you would pick. `single`/`multi` questions
  always render a write-in field, so never add an explicit "Other" option
  yourself; set `allowOther: false` only when a free-text answer makes no sense.
- Copy the catalog example verbatim for required fields: each question needs
  `id`, `title`, and `mode`; each option needs `id` and `label`.
- Keep non-answerable assumptions or risks as concise `callout` blocks in the
  relevant section. Never bury a questions/decisions wall inside the plan
  narrative, and never ask the same question twice.

For complex plans, do not end without an open-question audit. If architecture,
scope, UX, data shape, rollout, provider mapping, or ownership still depends on a
choice, either commit to a recommendation with rationale or add it to the bottom
form with a recommended default.

## `custom-html` is a bounded escape hatch only

A single complete fragment inside a block, never `html`/`head`/`body`/`script`
tags, never a generic placeholder, density demo, or proof that custom HTML works.
Prefer native blocks for normal plans. For architecture/code reviews, use
`diagram` `data.html` / `data.css` for rich local HTML/SVG diagrams instead of
`custom-html`. For UI/product work, `custom-html` is never the primary home for a
requested mockup, UI state, or visual comparison.

## Verification must exercise the real workflow

The final verification section should go beyond typecheck/unit tests when the
plan changes UI, local files, sync, providers, browser behavior, or multi-app
flows. Include at least one end-to-end smoke that matches the user journey — a
fresh repo/folder, real manifest or data fixture, browser interaction, save/sync
action, and an on-disk or database assertion. Name the command or manual browser
path when it is known.

**Before handoff, open the plan and check it.** Fix overlap, excessive
whitespace, clipped fragments, misleading inactive controls, poor contrast, and
unreadable diagrams before asking for approval.
