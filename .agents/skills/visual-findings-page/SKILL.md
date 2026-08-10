---
name: visual-findings-page
description: >-
  Agent-only procedure for presenting visual and UI defect findings as one self-contained annotated evidence page.
  Load before presenting a screen-visible defect to the captain or to a reviewer, before writing any HTML that rings a region of a screenshot, and before deciding a visual finding is ready to relay.
  Owns region-coordinate capture, the evidence pairing, verdict honesty, and the mandatory open-and-check verification.
user-invocable: false
metadata:
  internal: true
---

# visual-findings-page

A visual defect is invisible in a screenshot alone and unconvincing as prose alone.
What makes it actionable to someone who was not there is the pairing: see the screen, then see the line that causes it.
`bin/fm-visual-findings.sh` renders that pairing as one self-contained page and owns every mechanic - the input contract, the ring math, the styling, and the file's guarantees.
Read its `--help` for the schema; this skill owns only the judgment and the verification.

## When this applies

Use it when a finding is about something on a screen: wrong copy, a mislabelled control, a broken layout, a missing accessibility label, an element that is not where the user is told it will be.
A finding with no visual surface at all belongs in the scout report as prose, and the report stays the deliverable of record either way.
A page is worth building when a reader would otherwise have to reproduce the screen themselves to believe the claim.
Do not build one to decorate a finding that a single sentence already settles.

## Procedure

1. Capture the screen with `chrome-devtools-axi screenshot`, at the viewport the defect actually appears at.
2. Take each region from the live page rather than from the picture, using `chrome-devtools-axi eval` and `getBoundingClientRect()` on the offending element.
   Reading coordinates off an image by eye is what makes rings land in the wrong place; the browser already knows the exact box.
3. Write the findings JSON, then render it with `bin/fm-visual-findings.sh <findings.json>`.
4. Open the rendered page and look at it.
   This step is not optional and is covered below.

### Getting the coordinates right

The screenshot and the boxes must come from the same coordinate space, and `getBoundingClientRect()` always returns viewport coordinates.
So capture the viewport: a `--full-page` capture is in the scrollable page's space and a `--uid` capture is cropped to one element, and either shifts the origin while the rects stay viewport-relative, which puts every ring off by that shift without the script noticing.
If a full-page capture is genuinely what the finding needs, declare that space and add the scroll offset to every region yourself.

Regions default to the screenshot's own pixels, so a device pixel ratio above 1 is the other trap: a 390x844 viewport captured at ratio 2 produces a 780x1688 image, and bounding boxes from that page are in the 390x844 space.
Declare that space on the finding when the two differ, and the conversion is exact; the script refuses a region that falls outside the space rather than drawing a wrong ring.
Bounding boxes hug their content, so give a ring `pad` of roughly 6 to 10 to make it read as a ring rather than a border.
An inline phrase that wraps returns a union box covering both lines: take `getClientRects()` and ring one line, or ring the whole element and say which words matter in the evidence column.

### Writing the finding

One ring per claim, and every ring earns its number by having something in the evidence column that explains it.
Pair each ring with the `file` and `line` that produces it; an unpaired ring is an assertion, and the pairing is the whole point of the page.
Say how strong the finding actually is in the verdict, including when the answer is "cosmetic" or "may already be known upstream" - a page that oversells its weakest finding costs the reader trust in the strong ones.
A finding with no screenshot is a first-class case: use it when the defect is real but has no visible surface, such as a duplicated test id, and say in the summary why there is nothing to show.

The page is an argument, so let it read like one.
Record what the finding was reproduced on in the document's `meta` line - a commit, a build, a device - because a reader who cannot tell which build this was cannot act on it.
Put the identifier that carries the claim in a code span and the load-bearing clause in bold, rather than flattening the argument into uniform grey prose.
Reach for an evidence `body` when the order matters, which is usually output first and the reading of it after, and for bullets when two independent faults compound into one defect.
Use `level` for the reader's triage, not for emphasis: it colours the chip, so raising every finding to `high` tells them nothing.

## Verification, before you relay anything

Render the page, open it, and confirm each ring sits on the region it claims.
An unverified page is worse than prose because it looks authoritative while pointing at the wrong pixels.
Check the second axis too when the finding relies on the screenshot's colours or contrast: the page reads in both light and dark, and the rings must stay visible over the captured screen in both.
If a ring is off, fix the region and re-render; the output is deterministic, so the same input always produces the same page and a diff means something really changed.

## Placement and safety

Write the JSON, the screenshot and the page where the task's evidence already lives - in the task's data directory beside the scout report for an investigation, which is exactly what the scout brief's write rule enumerates, or in the worker's own worktree otherwise - and never inside a cloned project or a live working copy.
Keep the page publishable: it holds a defect and its evidence, never captain preferences, fleet posture, private paths, or credentials.
Relay it to the captain the way section 9 requires, as the finding and its consequence with a pointer to the page, not as a description of how the page was built.
`docs/examples/visual-findings/` is a complete worked example, screenshot included, and is the fastest way to start: copy it and replace the content.

Lavish is a separate surface with its own review loop and is deliberately not wired into this page; keep the page a plain local file unless the captain asks for a review surface.
