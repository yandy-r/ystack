# HTML wireframe quality — single source of truth

## Contents

The canonical quality bar for HTML wireframe content. Read it in full before
authoring ANY wireframe; do not author wireframes from memory or paraphrase these
rules per mode.

---

**A wireframe is an HTML mockup. The renderer owns the look; you write the
content.** Set `data.html` to a self-contained, semantic HTML fragment of the
screen and set `data.surface`. The renderer owns the surface footprint/aspect, the
dark/light theme, the hand-drawn font, and the sketch overlay — you never write
`<style>` / `<link>` / `<font>` tags or any width/height/coordinates. You write
real HTML layout and real product content; the renderer styles and roughens it.

**A wireframe block's data is an HTML screen plus a surface:**

```json
{
  "surface": "browser",
  "html": "<div style=\"display:flex;flex-direction:column;gap:10px;padding:16px;height:100%\"><h1>Sign in</h1><p class=\"wf-muted\">Use your work email to continue.</p><div class=\"wf-card\" style=\"display:flex;flex-direction:column;gap:10px\"><label>Email<input value=\"jane@acme.co\" /></label><label>Password<input value=\"********\" /></label><label style=\"display:flex;align-items:center;gap:8px\"><input type=\"checkbox\" checked /> Remember me</label><button class=\"primary\">Sign in</button></div><a href=\"#\">Forgot password?</a></div>"
}
```

**Write PLAIN semantic HTML and let the renderer style it.** Bare elements
(`h1`/`h2`/`h3`, `p`, `button`, `input`, `label`, `a`, `hr`) are auto-themed — no
classes needed. Helper classes carry the rest:

- `.wf-card` / `.wf-box` — a bordered, padded container (a panel, a list item).
- `.wf-pill` / `.wf-chip` — a rounded tag or filter; add `.accent` for the
  accent-filled variant.
- `.wf-muted` — secondary/muted text.
- `button.primary` or any element with `[data-primary]` — the accent-filled
  primary button.

**No decorative shadows around mockups.** Do not put `box-shadow`,
`filter: drop-shadow(...)`, Tailwind `shadow-*` classes, or other fake depth on a
wireframe frame, root container, `.wf-card` / `.wf-box`, or canvas artboard.
Mockups should read as flat, bordered surfaces; use spacing, borders, labels, and
annotations for separation. Only show a shadow when the real product UI already
has it and it is essential to the change being reviewed.

**Use renderer icons, not visible icon words.** For icon-only buttons or leading
icons inside fields, chips, menu items, and toolbars, write an empty marker with
`[data-icon]` (e.g. `<span data-icon="search"></span>`). The renderer replaces it
with a Tabler-style SVG and the `.wf-icon` class sizes it to the surrounding text.
Supported names and aliases include: `mail`/`email`, `lock`/`password`, `search`,
`plus`/`add`, `x`/`close`, `check`, `chevronDown`, `chevronUp`, `chevronLeft`,
`chevronRight`, `dots`/`more`, `chevron`/`caret`/`dropdown` (down chevron), `user`,
`settings`, `calendar`, `bell`, `send`, `edit`, `arrowLeft`, and `arrowRight`. Do
not put visible words like "email", "lock", "search", "chevron", or "more" where
the product UI would show an icon; use text only when it is a real label a user
would read.

**Use the `--wf-*` tokens for any custom color, never hex.** The renderer flips
these on light/dark, so referencing tokens is what keeps a mockup correct in both
themes. For any inline border, background, or text color, reference a token:
`style="border:1.4px solid var(--wf-line)"`. The tokens are `--wf-ink` (text),
`--wf-muted` (secondary text), `--wf-line` (borders/dividers), `--wf-paper` (page
background), `--wf-card` (container surface), `--wf-accent` / `--wf-accent-fg` /
`--wf-accent-soft` (brand action), `--wf-warn`, `--wf-ok`, and `--wf-radius`.
**Never hard-code a hex (or rgb/hsl) color and never set `font-family`** — the
renderer owns the sketch/clean font.

**Lay out with inline `style` flex/grid.** You write the real layout —
`display:flex; flex-direction:column; gap:10px; padding:16px` — and the renderer
never repositions anything. Compose the actual product: reproduce the current
screen, then show the modification. Real labels, real counts, real dates, real
button text grounded in the screen you read; not lorem or gray bars.

**Surface presets — match the real footprint, never default to desktop+mobile.**
Pick the `surface` that matches what the user will actually see:

- `browser`: a web page that needs a browser chrome frame around it.
- `desktop`: a full desktop app page or app shell.
- `mobile`: a phone screen, only when the work is genuinely mobile.
- `popover`: a small floating menu, dropdown, or inline popover.
- `panel`: a side panel, inspector, or sidebar widget.

A sidebar popover renders as a small surface, not a desktop page and a phone
frame. Do not emit `desktop` + `mobile` variants unless responsive behavior
actually changes the layout.

**Model the actual component shell for small surfaces.** A rendered UI change
belongs in a wireframe; reserve `diagram` for architecture, dependency, state, or
data-flow relationships. Popovers, dropdown menus, command palettes, and context
menus use `surface: "popover"` unless the surrounding page placement is the point
of the change. Dialogs, sheets, inspectors, sidebars, and long property panels use
the matching `panel` / `desktop` surface. Show the real chrome: trigger/anchor
when it matters, title/header row, top-right actions, separators, fields, options,
selected states, body content, and visible footer actions.

**Modify, don't redesign.** When the task changes an existing screen, reproduce
the current screen's real layout and footprint FIRST, then change only the delta
and call it out with a single annotation. Do not restack the page into a new
layout. For net-new surfaces, compose from the real app shell.

**Keep product screens pure.** A product wireframe shows the app state a user
would actually see. Do not embed file contracts, architecture arrows, repo pills,
mode explanations, or implementation callouts inside the screen just to explain
the plan. Put those in canvas annotations, a separate diagram, or the document
body.

**Zoom in on sub-surfaces, don't redraw the page.** For a small sub-surface (a
popover, menu, dialog, toast), show the full screen once, then add a small
separate artboard whose `html` contains ONLY that sub-surface — do not re-draw the
whole page around it, and do not scale a duplicate up. Pick the matching `surface`
(e.g. `popover`) so the footprint is right; never widen a popover to page width.

**Loading / skeleton states.** Set `data.skeleton: true` on the wireframe and fill
the `html` with neutral, textless placeholder geometry — boxes and bars built as
`<div>`s with `background:var(--wf-line)` and explicit heights/widths, no labels
or copy. The renderer drops borders, sketch, and color into the skeleton register
automatically. Never escape to a `custom-html` document block to fake a loader.

**Editing an existing mockup.** To change one element, text, or color, call
`update-visual-plan` with
`contentPatches: [{ op: "patch-wireframe-html", blockId, edits: [{ find, replace }] }]`.
Each `find` is a unique snippet of the current html (read it first); set
`all: true` on an edit to replace every occurrence. The result is re-sanitized.

**Treat the wireframe border as part of the visible design.** Always wrap HTML
wireframe content in a root container with real inner padding before drawing
cards, fields, pills, labels, or controls. Use at least 14-16px of padding,
`box-sizing: border-box`, `height: 100%`, and `gap` between child rows so the
first row never sits flush against the screen border.

**Lay out children safely so they never collide.** Use HTML flex/grid with `gap`,
`min-width: 0`, and sensible overflow. Avoid negative margins, absolute
positioning, or fixed child widths that can collide across light/dark, sketch/clean,
or zoom levels.

**Do not wrap intentionally single-line labels.** For toolbars, tab rails,
breadcrumbs, chip/filter rows, branch and file names, and code filenames — any
deliberately single-line row — put `white-space: nowrap` on the row (and
`overflow: hidden; text-overflow: ellipsis` on labels that can grow). Use
horizontally scrollable or clipped rails for overflow.

**Fill the frame; keep labels short.** Each artboard is a fixed-size surface —
compose enough realistic HTML to fill it top to bottom with even vertical rhythm;
never leave a large empty band. On desktop/app-shell sidebars, let the nav stack
flex to fill (`flex:1`) and add any persistent bottom action/status after it. On
mobile, flow real rows down the whole screen rather than a header floating above a
gap. Keep every label short enough to sit on one line within its column.

**Persistent chrome bars span the full frame width.** Top bars, app headers,
toolbars, and bottom tab/nav bars are full-width chrome, not centered content. Lay
each one out as a single flex row that fills the frame
(`style="display:flex;align-items:center;width:100%"`) and push trailing actions to
the right edge with a flex spacer (`<div style="flex:1"></div>`) between the
leading and trailing groups — never center a bar inside a narrow block, and never
let it collapse to the width of its contents.

**Pin bottom bars to the bottom of the frame.** For mobile tab bars, footers, and
any persistent bottom action row, make the frame itself a flex column at
`height:100%` (`style="display:flex;flex-direction:column;height:100%"`), give the
scrolling body `flex:1`, and place the bar as the LAST child (or set
`margin-top:auto`). The bar then sits flush at the bottom instead of floating with
an empty band beneath it.

**Before / after must be comparable.** When showing a state change, preserve the
unchanged controls in both states so the reviewer can see exactly what moved or
appeared; do not show an added control as a generic box floating elsewhere. Place
the new/changed affordance where the implementation puts it. Use the same frame
size, scale, outer padding, border radius, and visual density on both sides unless
the change itself alters those properties.

**Name the states with the column header, never inside the frame.** For
document-body wireframes, put the two states in a `columns` block and set each
column's `label` to `Before` and `After` — the renderer draws that label as a
heading above each frame. Do NOT bake a `Before`/`After` pill, title, or heading
into the wireframe `html`. On a canvas, place the two state artboards as neighbors
with frame labels — never encode Before/After inside the html.

**Let the surface choose side-by-side vs. stacked.** For document-body wireframes,
the `columns` renderer lays narrow surfaces (`mobile`, `popover`, `panel`) out
side by side, and automatically stacks wide surfaces (`desktop`, `browser`)
vertically at full document width so a large frame is never crushed into a
half-width column. Author both wireframes with the real `surface` and matching
`Before`/`After` column labels.

**Good example — a contacts list, surface `browser`.** A small, real screen
composed from the helper classes and tokens, layout in inline flex, no fonts or
hex colors:

```html
<div style="display:flex;flex-direction:column;gap:12px;padding:16px;height:100%">
  <div style="display:flex;align-items:center;justify-content:space-between">
    <h1>Contacts</h1>
    <button class="primary">New contact</button>
  </div>
  <div style="display:flex;gap:6px">
    <span class="wf-pill accent">All 128</span>
    <span class="wf-pill">Favorites</span>
    <span class="wf-pill">Archived</span>
  </div>
  <div class="wf-card" style="display:flex;flex-direction:column;gap:0;padding:0">
    <div style="display:flex;align-items:center;gap:10px;padding:10px 12px;border-bottom:1.4px solid var(--wf-line)">
      <div style="width:32px;height:32px;border-radius:999px;background:var(--wf-accent-soft)"></div>
      <div style="flex:1"><strong>Jane Cooper</strong><br /><small>jane@acme.co</small></div>
      <span class="wf-pill">Lead</span>
    </div>
    <div style="display:flex;align-items:center;gap:10px;padding:10px 12px">
      <div style="width:32px;height:32px;border-radius:999px;background:var(--wf-accent-soft)"></div>
      <div style="flex:1"><strong>Marcus Lee</strong><br /><small>marcus@globex.io</small></div>
      <span class="wf-pill">Customer</span>
    </div>
  </div>
</div>
```
