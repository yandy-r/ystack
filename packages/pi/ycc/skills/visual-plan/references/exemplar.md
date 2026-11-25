# Good vs. bad exemplar — single source of truth

## Contents

- A worked example — UI-first plan MDX
- GOOD — the bar
- BAD — never produce this

The canonical worked example of a great plan (and the anti-patterns to avoid).
Read it alongside `document-quality.md` and `canvas.md` before authoring a plan;
it is the bar these plans must clear. Resolve exact block tags against the live
catalog (`get-plan-blocks` for hosted sharing or the pinned local-files CLI catalog)
before emitting MDX.

---

## A worked example — UI-first plan MDX

The following sketch shows the _shape_ of a strong UI-first plan: a top canvas
with one real `desktop` artboard, plain-text designer notes off the frame, then a
serious document below it. Treat the tags as families — confirm exact names/props
against the catalog.

```mdx
---
title: Inbox triage redesign
mode: ui-first
---

{/* canvas.mdx — the top review surface */}

<DesignBoard>
  <Section label="Triage view">
    <Artboard id="inbox-default" surface="desktop" label="Inbox — default">
      {/* data.html is a real flex layout: a sidebar of links
          (Inbox 12, Today 4, Done), a main column headed "Today",
          accent .wf-pill filters, a muted "OVERDUE" section label,
          and .wf-card task rows with real titles, due dates, and a
          button.primary — styled only via bare elements, helper
          classes, and --wf-* tokens. */}
    </Artboard>
    <Annotation targetId="inbox-default" placement="right">
      Overdue items float to the top; the primary action stays in the header so triage never scrolls.
    </Annotation>
  </Section>
</DesignBoard>

{/* plan.mdx — the document body */}
<rich-text>

## Objective

Cut inbox triage from many clicks to one. "Done" means an overdue item
can be deferred or completed from the row without opening it.
</rich-text>

<tabs>
  {/* one `code` / `annotated-code` block per load-bearing file:
      the new defer action, the changed query, the row component */}
</tabs>

<callout tone="decision">
  Defer writes a `snoozedUntil` timestamp rather than moving the row to a separate table — see the columns block for the
  two options weighed.
</callout>

<question-form title="Open Questions">
  {/* single/multi questions for genuinely-open decisions, each option
      with id + label, recommended: true on the default */}
</question-form>
```

If the task also changes a multi-step completion flow, the same top area gains a
Prototype tab whose screens reuse the canvas labels and states.

## GOOD — the bar

- **UI-first todo/inbox plan.** A canvas `desktop` artboard whose `data.html` is a
  real flex layout (sidebar links, a "Today" heading, accent `.wf-pill` filters, a
  muted `OVERDUE` label, `.wf-card` task rows with real titles/dates and a
  `button.primary`), styled only through bare elements, helper classes, and
  `--wf-*` tokens. Plain-text designer notes sit spaced off the frame, pointing
  only at controls that need explanation. Below it, a strong document: objective
  and done-criteria, a few `code` blocks (grouped in a vertical `tabs` block when
  more than one) showing the real shape of load-bearing files, a `callout` with
  `tone="decision"` stating the chosen approach with a `columns` block weighing the
  two real options, and a validation step — none of it repeating the canvas.
- **Broad product-architecture plan.** Opens with a plain recommendation and one
  concrete app state before the abstraction. The first canvas artboard is pure
  product UI that matches the current app shell; nearby notes explain the
  user-visible delta. A separate `diagram` below shows the mechanics. The document
  separates the reusable core from app/provider adapters and examples, covers
  contracts and schema shape, roadmap, non-goals, a bottom Open Questions form, and
  a verification section with at least one realistic end-to-end smoke.
- **Backend architecture review.** No top canvas. The document opens with context
  and a legend, then repeats recommendation cards: title, confidence/category
  badges, a monospace grid of real file paths, one inline two-dimensional
  before/after or layered architecture `diagram` (using space to show boundaries
  and ownership, not a default left-to-right chain), and terse
  Problem/Solution/Why bullets in the codebase's vocabulary. Ends with a top
  recommendation and a bottom `question-form` only if the next direction is
  genuinely open.

## BAD — never produce this

- A `data.html` with hard-coded hex colors, a `font-family`, or fixed pixel
  width/height.
- Gray placeholder bars "insinuating" text on a non-skeleton frame.
- A forced `desktop` + `mobile` pair for a popover.
- Floating bordered annotation cards hugging the frames.
- A multi-step UI flow with only static frames and no prototype tab.
- A mockup escaped into a document `custom-html` block.
- A marketing-style document with a hero heading and value props that just
  restates what the canvas already shows.
- An architecture-only plan forced into a top canvas of labeled boxes with
  overlapping text, where the real code evidence lives elsewhere.
- A product wireframe that mixes a real screen with repo names, file-contract
  arrows, architecture explanations, or a made-up permanent inspector.
- A plan that describes itself as a revision of a prior conversation instead of a
  standalone proposal.
