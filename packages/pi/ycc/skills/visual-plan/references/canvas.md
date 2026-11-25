# Canvas & artboard placement — single source of truth

## Contents

- Canvas block families
- Emitted files
- The coordinate rule
- Lay out mixed canvases in lanes
- Annotations are designer notes on the artboard
- Patching
- Never emit a titled artboard with no interior wireframe content
- UI mockups belong in the top visual review area

The canonical guide for how the visual-plan canvas works: artboard placement,
lane layout, annotations, patching, and emitted files. Read it in full before
authoring or editing any canvas/artboard content; do not author canvas layouts
from memory. Resolve exact block/component tag names against the live catalog
(`get-plan-blocks` for hosted sharing or the pinned local-files CLI catalog).

---

## Canvas block families

A plan canvas is composed from these block families (resolve exact tag names and
props via the catalog):

- **`<DesignBoard>`** — the canvas root that holds the artboards and annotations.
- **`<Section>`** — groups related artboards into a labeled region/lane.
- **`<Artboard>`** — a single fixed-footprint frame; its size/aspect is locked by
  `surface` (see `wireframe.md`). Carries an `html` wireframe or references a
  wireframe block via `blockId`.
- **`<Screen>`** — a product screen surface inside the board (a UI state under
  review).
- **`<Annotation>`** — a plain-text designer note anchored to a frame by
  `targetId` + `placement`.
- **`<Connector>`** — an arrow between neighboring steps of a real sequence.

## Emitted files

- `plan.mdx` — frontmatter plus markdown/document blocks (the plan body).
- `canvas.mdx` — the `<DesignBoard>` / `<Section>` / `<Artboard>` / `<Screen>` /
  `<Annotation>` / `<Connector>` tree.
- `prototype.mdx` — present only for prototype plans (the functional flow).

JSON is the canonical runtime shape; MDX is the repo-friendly authoring/export
surface. Both live under the derived `visual/` directory.

## The coordinate rule

The `surface` locks each artboard's footprint and aspect — **never** set artboard
width/height and **never** use coordinates inside the wireframe HTML. Board-level
artboard `x`/`y` IS allowed when it creates clear lanes. Let canvas
auto-placement handle simple one-row boards. Sizing is always via `surface`, not
explicit pixels.

## Lay out mixed canvases in lanes

When a canvas contains broad `browser` / `desktop` frames plus compact `mobile`,
`popover`, or `panel` surfaces, do not put everything in one horizontal strip.
Use board-level artboard `x`/`y` to reserve lanes with generous empty space: main
flow on one row, compact surfaces in their own column or row, loading/error
states in a lower row. Keep at least **96px** between rendered artboard rectangles
plus room for annotation gutters. Connect only neighboring steps; never draw a
long connector that skips across unrelated frames. Before handoff, inspect the
top canvas at default zoom and move any frame whose label, connector, or
annotation crosses another frame.

## Annotations are designer notes on the artboard

When a top canvas is present, sprinkle Figma-style notes near the frames they
explain: a short heading, supporting text, and bullets — plain text layers, never
bordered or shadowed cards, and never a box around a frame. The renderer spaces
notes away from frames, so place each note by the frame it describes. Use an
arrow (`<Connector>`) only to point at one specific control or transition; for a
broad frame-level note, write text beside the frame with no connector.

**Do not create overlapping annotations.** Anchor each ordinary note to the frame
it explains with `targetId` + `placement` (top/right/bottom/left), and omit
`type` or use `type: "note"`. The renderer parks notes in a gutter beside the
frame and lays them out automatically. Do not use `type: "callout"`,
`type: "text"`, `type: "arrow"`, x/y, or points for ordinary notes; those are
freeform review-markup layers reserved for intentional markup in open canvas
space. Connectors are for real sequences only — never fake "Step 1 → Step 2"
lines between independent states.

## Patching

Edit one wireframe, canvas annotation, diagram, or block with targeted
`contentPatches` rather than regenerating the whole plan:

- `patch-wireframe-html` — edit the HTML of one artboard's wireframe.
- `patch-diagram-html` — edit the HTML/SVG of one diagram.
- `update-block` / `replace-blocks` — replace a block by stable id.
- `update-canvas-annotation` — edit one annotation.
- `read-visual-plan-source` / `patch-visual-plan-source` — granular MDX AST
  patches by stable block, artboard, annotation, component, or wireframe-node id
  when working from exported source files.
- `update-rich-text` — prose edits (agents use this or source patches; humans
  edit prose inline in the browser).

`contentPatches` are part of the public MCP action schema, so every host can make
surgical edits. **Never** send a partial top-level `content` object as a shortcut
to add a canvas, frame, or block: `content` is a full structured replacement, so
omitted blocks or surfaces disappear. If a full replacement is truly unavoidable,
read the complete source/JSON first, include every existing block and surface in
the new payload, and verify the source/export immediately after the update.

## Never emit a titled artboard with no interior wireframe content

Every artboard must carry an `html` wireframe or reference a wireframe block via
`blockId`; when using `blockId`, the referenced wireframe block must remain in the
plan. If you remove a duplicate wireframe from the document body, first move its
`data` inline onto the corresponding canvas frame. A label-only frame or a frame
pointing at a deleted block renders empty and is rejected at parse time. If you
only have a title, write it as a section header or annotation, not an empty
artboard.

## UI mockups belong in the top visual review area

Static UI/product visuals live on the canvas; multi-step UI flows get both canvas
wireframes and a `prototype`. When the user asks for a mockup, UI state, loading
state, layout, screen, or visual comparison, make the canvas the primary home for
that static visual. Architecture/code diagrams stay inline in the document
(`document-quality.md` owns that rule) unless the user explicitly asks for a
spatial board. A skeleton/loading mockup also lives in a canvas artboard — never
move a mockup out of the canvas into a `custom-html` document block.

For abstract product concepts, use the canvas to create the first "I get it"
moment: one real app state near the top showing how the concept appears to a
user, followed by separate annotations or diagrams for mechanics. Do not make the
first artboard a hybrid of app UI and architecture notes; the app screen should be
inspectable as product UI on its own.
