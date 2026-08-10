#!/usr/bin/env bash
# Behavior tests for the annotated visual-findings renderer.
#
# Covers the page's four load-bearing guarantees - self-containment (no network,
# no sibling asset, no script), determinism, correct pixel-to-percent ring
# geometry across every supported coordinate space, and the code-only finding -
# plus the input-contract refusals that keep a wrong ring from being drawn
# silently. Everything is asserted through the executable and its rendered
# output; nothing reads the renderer's own source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RENDER="$ROOT/bin/fm-visual-findings.sh"
TMP_ROOT=$(fm_test_tmproot fm-visual-findings)

# A real, minimal PNG of the requested size, so header sniffing is exercised for
# what it is rather than stubbed.
make_png() {  # <path> <width> <height>
  python3 - "$@" <<'PY'
import struct, sys, zlib

path, width, height = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
raw = b"".join(b"\x00" + b"\x80\x80\x80" * width for _ in range(height))


def chunk(tag, payload):
    body = tag + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))


with open(path, "wb") as handle:
    handle.write(b"\x89PNG\r\n\x1a\n")
    handle.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
    handle.write(chunk(b"IDAT", zlib.compress(raw, 9)))
    handle.write(chunk(b"IEND", b""))
PY
}

# Sets OUT (combined output) and RC. Deliberately not a command substitution:
# a subshell could not report the exit code back to the caller.
OUT=
RC=0
render() {  # <args...>
  OUT=$("$RENDER" "$@" 2>&1) && RC=0 || RC=$?
}

# --- the shipped worked example ---------------------------------------------
#
# The example is documentation an agent is told to copy, so it must render.

EXAMPLE_OUT="$TMP_ROOT/example.html"
render "$ROOT/docs/examples/visual-findings/findings.json" --out "$EXAMPLE_OUT"
expect_code 0 "$RC" "the shipped example renders"$'\n'"$OUT"
assert_present "$EXAMPLE_OUT" "the shipped example wrote a page"
assert_grep "data:image/png;base64," "$EXAMPLE_OUT" "the example screenshot is inlined"
pass "the shipped worked example renders"

# Self-contained: opening this file off disk, offline, must need nothing else.
# A URL inside a code excerpt is escaped page text, not a reference, so the
# assertions target the attributes a browser would actually go and fetch.
assert_no_grep 'src="http' "$EXAMPLE_OUT" "no element loads over the network"
assert_no_grep 'href="http' "$EXAMPLE_OUT" "no link resource loads over the network"
assert_no_grep "<script" "$EXAMPLE_OUT" "the page ships no script"
assert_no_grep "<link" "$EXAMPLE_OUT" "the page ships no external stylesheet"
assert_no_grep "@import" "$EXAMPLE_OUT" "the page imports no external CSS"
if grep -o 'src="[^"]*"' "$EXAMPLE_OUT" | grep -qv '^src="data:'; then
  fail "every src must be a data: URI"
fi
pass "the page is self-contained: no network, no sibling asset, no script"

# --- determinism -------------------------------------------------------------

SECOND_OUT="$TMP_ROOT/example-again.html"
render "$ROOT/docs/examples/visual-findings/findings.json" --out "$SECOND_OUT"
expect_code 0 "$RC" "the second render succeeds"$'\n'"$OUT"
cmp -s "$EXAMPLE_OUT" "$SECOND_OUT" || fail "the same input must render byte-identical output"
pass "identical input renders byte-identical output"

# --- ring geometry across every coordinate space -----------------------------
#
# One region, three ways of describing the same half-size box centred in a
# 200x100 image. All three must land on the same percentages, because that is
# the whole reason coordinates are not hand-tuned by eye.

SHOT="$TMP_ROOT/shot.png"
make_png "$SHOT" 200 100

geometry_case() {  # <name> <finding-json-body>
  local name=$1 body=$2 file="$TMP_ROOT/$1.json" page="$TMP_ROOT/$1.html"
  cat > "$file" <<JSON
{ "title": "geometry", "findings": [ { "title": "ring", "screenshot": "shot.png", $body } ] }
JSON
  render "$file" --out "$page"
  expect_code 0 "$RC" "$name renders"$'\n'"$OUT"
  assert_grep 'left:25%;top:25%;width:50%;height:50%' "$page" \
    "$name puts the ring at the same computed position"
}

geometry_case image-pixels '"regions": [ { "x": 50, "y": 25, "w": 100, "h": 50 } ]'
geometry_case declared-space \
  '"space": { "width": 100, "height": 50 }, "regions": [ { "x": 25, "y": 12.5, "w": 50, "h": 25 } ]'
geometry_case percent-units \
  '"units": "percent", "regions": [ { "x": 25, "y": 25, "w": 50, "h": 50 } ]'
pass "image pixels, a declared coordinate space, and percent units agree"

# Padding grows the ring symmetrically in the finding's own units.
geometry_case padded '"regions": [ { "x": 60, "y": 35, "w": 80, "h": 30, "pad": 10 } ]'
pass "pad grows a bounding box symmetrically"

# An element flush against the screenshot edge is the case that most needs pad, so
# the pad is clamped to the image rather than pushing the ring out of the space.
cat > "$TMP_ROOT/edge-pad.json" <<'JSON'
{
  "title": "edge",
  "findings": [ { "title": "full-bleed button", "screenshot": "shot.png",
    "regions": [ { "x": 0, "y": 90, "w": 200, "h": 10, "pad": 8 } ] } ]
}
JSON
render "$TMP_ROOT/edge-pad.json" --out "$TMP_ROOT/edge-pad.html"
expect_code 0 "$RC" "a full-bleed region with pad renders"$'\n'"$OUT"
assert_grep 'left:0%;top:82%;width:100%;height:18%' "$TMP_ROOT/edge-pad.html" \
  "the padded ring is clamped to the image edges"
pass "pad never pushes an edge-flush region out of the coordinate space"

# --- tag placement flips away from the bottom edge ---------------------------

cat > "$TMP_ROOT/tags.json" <<'JSON'
{
  "title": "tags",
  "findings": [ { "title": "two rings", "screenshot": "shot.png", "regions": [
    { "label": "high", "x": 10, "y": 10, "w": 20, "h": 10 },
    { "label": "low", "x": 10, "y": 88, "w": 20, "h": 10 }
  ] } ]
}
JSON
render "$TMP_ROOT/tags.json" --out "$TMP_ROOT/tags.html"
expect_code 0 "$RC" "the tag-placement page renders"$'\n'"$OUT"
assert_grep 'class="tag below"' "$TMP_ROOT/tags.html" "a ring with room below is tagged below"
assert_grep 'class="tag above"' "$TMP_ROOT/tags.html" "a ring against the bottom edge is tagged above"
pass "ring tags flip away from the bottom edge"

# The vertical axis owes the same guarantee as the horizontal one: a tag stays
# attached to its ring AND inside the frame. A ring against the TOP edge has no
# room above it, so an explicit "above" flips below rather than rendering over the
# text that precedes the figure.
cat > "$TMP_ROOT/top-edge-tag.json" <<'JSON'
{
  "title": "top edge",
  "findings": [ { "title": "ring against the top edge", "screenshot": "shot.png", "regions": [
    { "label": "header", "x": 0, "y": 0, "w": 200, "h": 40, "tag": "above" }
  ] } ]
}
JSON
render "$TMP_ROOT/top-edge-tag.json" --out "$TMP_ROOT/top-edge-tag.html"
expect_code 0 "$RC" "a top-edge ring renders"$'\n'"$OUT"
assert_no_grep 'class="tag above"' "$TMP_ROOT/top-edge-tag.html" \
  "an above tag with no room above it does not stay above"
assert_grep 'class="tag below" style="left:0%;top:min(calc(40% + var(--tag-gap))' \
  "$TMP_ROOT/top-edge-tag.html" "it flips to sit just under the ring's own bottom edge"
pass "a tag with no room on its edge flips to the opposite edge"

# A ring spanning almost the whole screenshot leaves no room on either edge, so
# the tag goes inside the ring rather than outside the frame.
cat > "$TMP_ROOT/full-height-tag.json" <<'JSON'
{
  "title": "full height",
  "findings": [ { "title": "ring spanning the screenshot", "screenshot": "shot.png", "regions": [
    { "label": "the whole column", "x": 0, "y": 0, "w": 200, "h": 90 }
  ] } ]
}
JSON
render "$TMP_ROOT/full-height-tag.json" --out "$TMP_ROOT/full-height-tag.html"
expect_code 0 "$RC" "a full-height ring renders"$'\n'"$OUT"
assert_grep 'class="tag above" style="left:0%;bottom:min(calc(100% - 90% + var(--tag-gap))' \
  "$TMP_ROOT/full-height-tag.html" \
  "a ring with room on neither edge hangs its tag from its own bottom edge, inside itself"
pass "a frame-spanning ring keeps its tag inside the frame"

# A side tag anchors on the ring's edge and centre, not its top-left corner.
cat > "$TMP_ROOT/side-tags.json" <<'JSON'
{
  "title": "side tags",
  "findings": [ { "title": "narrow rings", "screenshot": "shot.png", "regions": [
    { "label": "beside", "x": 20, "y": 20, "w": 40, "h": 20, "tag": "right" },
    { "label": "before", "x": 100, "y": 60, "w": 40, "h": 20, "tag": "left" }
  ] } ]
}
JSON
render "$TMP_ROOT/side-tags.json" --out "$TMP_ROOT/side-tags.html"
expect_code 0 "$RC" "the side-tag page renders"$'\n'"$OUT"
assert_grep 'class="tag right" style="left:calc(30% + var(--tag-gap));top:clamp(0px,calc(30% - var(--tag-h) / 2)' \
  "$TMP_ROOT/side-tags.html" "a right tag sits off the ring's right edge, centred on the ring"
assert_grep 'class="tag left" style="right:calc(50% + var(--tag-gap));top:clamp(0px,calc(70% - var(--tag-h) / 2)' \
  "$TMP_ROOT/side-tags.html" "a left tag sits off the ring's left edge, centred on the ring"
pass "left and right tags sit beside the ring and centre on it"

# Every offset above is anchored on the RING and bounded against the tag's own
# height, so the two guarantees cannot compete: the placement follows the ring
# rather than a frame edge, and the bound resolves at whatever size the figure
# renders. A tag pinned to a frame edge regardless of its ring - the defect this
# replaced - fails the assertions above, because the ring's own percentage no
# longer appears in the offset.
assert_grep 'calc(100% - var(--tag-h))' "$TMP_ROOT/side-tags.html" \
  "the vertical offset is bounded by the tag's own height"
assert_grep '--tag-h: 22px;' "$TMP_ROOT/side-tags.html" \
  "the tag's height is declared once, in the units the bound needs"
assert_no_grep 'transform: translate' "$TMP_ROOT/side-tags.html" \
  "no tag is offset past its anchor by an unabsorbable pixel translation"
assert_no_grep 'tag-slot' "$TMP_ROOT/side-tags.html" \
  "no tag is laid out by a container that can reflow it away from its ring"
pass "tag placement follows the ring and is bounded in the tag's own units"

# A tag is laid out inside the frame, so in every placement its slot and the
# spacers inside it must stay within the image - otherwise a long label spills
# out of the frame and the page grows a horizontal scrollbar.
cat > "$TMP_ROOT/clamped-tags.json" <<'JSON'
{
  "title": "clamped tags",
  "findings": [ { "title": "rings against both edges", "screenshot": "shot.png", "regions": [
    { "label": "a very long label indeed", "x": 180, "y": 10, "w": 18, "h": 10 },
    { "label": "a very long label indeed", "x": 180, "y": 40, "w": 18, "h": 10, "tag": "right" },
    { "label": "a very long label indeed", "x": 2, "y": 70, "w": 18, "h": 10, "tag": "left" }
  ] } ] }
JSON
render "$TMP_ROOT/clamped-tags.json" --out "$TMP_ROOT/clamped-tags.html"
expect_code 0 "$RC" "the clamped-tag page renders"$'\n'"$OUT"
assert_grep 'class="tag below" style="left:74%' "$TMP_ROOT/clamped-tags.html" \
  "a below tag near the right edge is held back to the room it has left"
assert_grep 'class="tag right" style="left:calc(74% + var(--tag-gap))' \
  "$TMP_ROOT/clamped-tags.html" "a right tag near the right edge is held back too"
assert_grep 'class="tag left" style="right:calc(74% + var(--tag-gap))' \
  "$TMP_ROOT/clamped-tags.html" "a left tag near the left edge is held away from the frame edge"
python3 - "$TMP_ROOT/clamped-tags.html" <<'PY' || fail "no tag may extend past the frame"
import re, sys

page = open(sys.argv[1], encoding="utf-8").read()
tags = re.findall(r'class="tag (\w+)[^"]*" style="([^"]+)"', page)
assert tags, "no tags were rendered"
for placement, style in tags:
    side = "right" if placement == "left" else "left"
    assert style.startswith(side + ":"), (placement, style)
    # The offset leaves the label a readable share of the frame to grow into, and
    # its max-width closes that share off before the opposite edge, so a long
    # label cannot reach outside the image however wide it wants to be.
    anchor = float(re.search(r"^\w+:(?:calc\()?([\d.]+)%", style).group(1))
    assert 26.0 <= 100.0 - anchor <= 100.0, (placement, style)
    assert "max-width:calc(" in style, (placement, style)
    # Every vertical offset is bounded against the tag's own height rather than a
    # bare percentage, which is what holds it inside a short-rendered frame.
    assert "var(--tag-h)" in style, (placement, style)
PY
pass "every tag placement stays inside the image frame"

# --- the code-only finding ---------------------------------------------------

cat > "$TMP_ROOT/code-only.json" <<'JSON'
{
  "title": "no screenshot",
  "findings": [ { "title": "duplicate test id", "evidence": [
    { "file": "src/a.tsx", "line": "88-96", "code": "<Input data-testid=\"dup\" />" }
  ], "verdict": "real but invisible" } ]
}
JSON
render "$TMP_ROOT/code-only.json" --out "$TMP_ROOT/code-only.html"
expect_code 0 "$RC" "a finding with no screenshot renders"$'\n'"$OUT"
assert_no_grep "<img" "$TMP_ROOT/code-only.html" "a code-only finding draws no image"
assert_grep "src/a.tsx:88-96" "$TMP_ROOT/code-only.html" "the file and line range are shown"
assert_grep "code-only" "$TMP_ROOT/code-only.html" "the layout drops the screenshot column"
pass "a finding with no screenshot is a first-class case"

# --- ordered evidence bodies -------------------------------------------------
#
# The argument often needs the code FIRST and the commentary after it, or a list
# mid-paragraph, which the short note/code form cannot express.

cat > "$TMP_ROOT/body.json" <<'JSON'
{
  "title": "ordered evidence",
  "meta": "commit 0000000 · reproduced on a mock build",
  "findings": [ { "title": "two faults compound", "severity": "breaks the suite", "level": "high",
    "evidence": [ { "heading": "cause", "body": [
      { "code": "data-testid={`${id}-${title}`}", "file": "src/a.tsx", "line": 99 },
      { "text": "Two faults compound:" },
      { "bullets": [ "the title is optional", "the index restarts" ] },
      { "text": "The sibling heading gets this right." }
    ] } ] } ],
  "footer": "fuller evidence lives beside this page"
}
JSON
render "$TMP_ROOT/body.json" --out "$TMP_ROOT/body.html"
expect_code 0 "$RC" "an ordered evidence body renders"$'\n'"$OUT"
python3 - "$TMP_ROOT/body.html" <<'PY' || fail "code must render before the commentary that follows it"
import sys
page = open(sys.argv[1], encoding="utf-8").read()
assert page.index("src/a.tsx:99") < page.index("Two faults compound:")
assert page.index("Two faults compound:") < page.index("the title is optional")
assert page.index("the index restarts") < page.index("The sibling heading gets this right.")
PY
assert_grep "<li>the title is optional</li>" "$TMP_ROOT/body.html" "bullets render as a list"
assert_grep '<p class="meta">' "$TMP_ROOT/body.html" "the provenance line renders"
assert_grep "<footer>fuller evidence lives beside this page</footer>" "$TMP_ROOT/body.html" \
  "the footer renders"
assert_grep '<span class="chip high">' "$TMP_ROOT/body.html" "the severity level colours the chip"
pass "ordered bodies, bullets, provenance, footer and severity level render"

# --- inline markup -----------------------------------------------------------

cat > "$TMP_ROOT/inline.json" <<'JSON'
{
  "title": "inline markup",
  "findings": [ { "title": "emphasis",
    "summary": "the *identical* `data-testid`, and **`title` is optional**",
    "evidence": [ { "note": "an unmatched * marker and a **bold <script>alert(1)</script>** span" } ],
    "verdict": "**Strongest of the three.** Provable in one line." } ]
}
JSON
render "$TMP_ROOT/inline.json" --out "$TMP_ROOT/inline.html"
expect_code 0 "$RC" "inline markup renders"$'\n'"$OUT"
assert_grep "<em>identical</em>" "$TMP_ROOT/inline.html" "emphasis renders"
assert_grep "<code>data-testid</code>" "$TMP_ROOT/inline.html" "a code span renders"
assert_grep "<strong><code>title</code> is optional</strong>" "$TMP_ROOT/inline.html" \
  "a code span nests inside bold"
assert_grep "<strong>Strongest of the three.</strong>" "$TMP_ROOT/inline.html" "the verdict takes markup"
assert_grep "an unmatched * marker" "$TMP_ROOT/inline.html" "an unmatched marker stays literal"
assert_no_grep "<script>alert" "$TMP_ROOT/inline.html" "markup never smuggles a tag through"
assert_grep "&lt;script&gt;" "$TMP_ROOT/inline.html" "the escaped text survives inside the emphasis"
pass "inline markup renders and cannot smuggle markup"

# --- markup safety -----------------------------------------------------------

cat > "$TMP_ROOT/escape.json" <<'JSON'
{
  "title": "escaping",
  "findings": [ { "title": "a <script>alert(1)</script> title",
    "evidence": [ { "code": "<img src=x onerror=alert(1)>" } ] } ]
}
JSON
render "$TMP_ROOT/escape.json" --out "$TMP_ROOT/escape.html"
expect_code 0 "$RC" "content with markup renders"$'\n'"$OUT"
assert_no_grep "<script>alert" "$TMP_ROOT/escape.html" "finding text is escaped, not executed"
assert_no_grep "<img src=x" "$TMP_ROOT/escape.html" "code excerpts are escaped, not executed"
assert_grep "&lt;script&gt;" "$TMP_ROOT/escape.html" "the escaped text is still readable"
pass "finding text and code excerpts are escaped"

# --- refusals: a wrong ring must never be drawn quietly ----------------------

refuses() {  # <name> <expected-message-fragment> <json>
  local name=$1 needle=$2 file="$TMP_ROOT/refuse-$1.json"
  printf '%s\n' "$3" > "$file"
  render "$file" --out "$TMP_ROOT/refuse-$1.html"
  expect_code 1 "$RC" "$name is refused"
  assert_contains "$OUT" "$needle" "$name explains what is wrong"
  assert_absent "$TMP_ROOT/refuse-$1.html" "$name writes no page"
}

refuses out-of-bounds "outside the 200x100 coordinate space" \
  '{ "title": "t", "findings": [ { "title": "f", "screenshot": "shot.png", "regions": [ { "x": 150, "y": 10, "w": 100, "h": 10 } ] } ] }'
refuses unknown-key "unknown key(s) regoins" \
  '{ "title": "t", "findings": [ { "title": "f", "regoins": [] } ] }'
refuses dangling-region "has no matching ring" \
  '{ "title": "t", "findings": [ { "title": "f", "screenshot": "shot.png", "regions": [ { "x": 1, "y": 1, "w": 2, "h": 2 } ], "evidence": [ { "region": 2, "note": "n" } ] } ] }'
refuses regions-without-screenshot "regions but no screenshot" \
  '{ "title": "t", "findings": [ { "title": "f", "regions": [ { "x": 1, "y": 1, "w": 2, "h": 2 } ] } ] }'
refuses missing-screenshot "cannot read screenshot" \
  '{ "title": "t", "findings": [ { "title": "f", "screenshot": "absent.png" } ] }'
refuses empty-findings "findings must be a non-empty array" '{ "title": "t", "findings": [] }'
refuses no-title "title is required" '{ "findings": [ { "title": "f", "summary": "s" } ] }'
refuses empty-evidence "needs content: note, file, code, or a body" \
  '{ "title": "t", "findings": [ { "title": "f", "evidence": [ { "heading": "h" } ] } ] }'
refuses mixed-body "mixes body with note" \
  '{ "title": "t", "findings": [ { "title": "f", "evidence": [ { "note": "n", "body": [ { "text": "t" } ] } ] } ] }'
refuses two-kinds-in-block "exactly one of text, bullets or code" \
  '{ "title": "t", "findings": [ { "title": "f", "evidence": [ { "body": [ { "text": "t", "code": "c" } ] } ] } ] }'
refuses empty-block "exactly one of text, bullets or code" \
  '{ "title": "t", "findings": [ { "title": "f", "evidence": [ { "body": [ { "caption": "c" } ] } ] } ] }'
refuses bad-level "level must be one of high, medium, low, none" \
  '{ "title": "t", "findings": [ { "title": "f", "level": "critical", "summary": "s" } ] }'
# `level` only colours the severity chip, so accepting it without a severity would
# make the key a silent no-op.
refuses level-without-severity "findings[0].level needs a non-empty findings[0].severity" \
  '{ "title": "t", "findings": [ { "title": "f", "level": "high", "summary": "s" } ] }'
# caption, alt, units and space describe the screenshot, so on a code-only finding
# the renderer would drop every one of them: the same silent no-op, refused the
# same way.
refuses caption-without-screenshot "findings[0].caption needs a findings[0].screenshot" \
  '{ "title": "t", "findings": [ { "title": "f", "caption": "under the shot", "summary": "s" } ] }'
refuses describers-without-screenshot \
  "findings[0].alt, findings[0].caption, findings[0].space, findings[0].units need a findings[0].screenshot" \
  '{ "title": "t", "findings": [ { "title": "f", "alt": "a", "caption": "c", "units": "percent", "space": { "width": 10, "height": 10 }, "summary": "s" } ] }'
# Percent regions already name their own coordinate space; letting `space` win
# silently divides them a second time and draws a wrong ring.
# JSON's bare NaN parses into a float that compares False against every bound, so
# without an explicit refusal it would slip past all the geometry checks and draw
# a ring at nowhere in particular.
refuses nan-coordinate "findings[0].regions[0].x must be a finite number" \
  '{ "title": "t", "findings": [ { "title": "f", "screenshot": "shot.png", "regions": [ { "x": NaN, "y": 10, "w": 20, "h": 20 } ] } ] }'
refuses infinite-coordinate "findings[0].regions[0].w must be a finite number" \
  '{ "title": "t", "findings": [ { "title": "f", "screenshot": "shot.png", "regions": [ { "x": 10, "y": 10, "w": Infinity, "h": 20 } ] } ] }'
refuses percent-with-space 'declares both "units": "percent" and "space"' \
  '{ "title": "t", "findings": [ { "title": "f", "screenshot": "shot.png", "units": "percent", "space": { "width": 200, "height": 100 }, "regions": [ { "x": 10, "y": 10, "w": 20, "h": 20 } ] } ] }'
pass "malformed input and out-of-space regions are refused with an actionable message"

printf 'not json\n' > "$TMP_ROOT/bad.json"
render "$TMP_ROOT/bad.json" --out "$TMP_ROOT/bad.html"
expect_code 1 "$RC" "invalid JSON is refused"
assert_contains "$OUT" "is not valid JSON" "invalid JSON names the problem"
pass "invalid JSON is refused"

# An unreadable image size with regions is a refusal, not a guessed ring.
printf 'not an image\n' > "$TMP_ROOT/fake.webp"
cat > "$TMP_ROOT/unsized.json" <<'JSON'
{ "title": "t", "findings": [ { "title": "f", "screenshot": "fake.webp",
  "regions": [ { "x": 1, "y": 1, "w": 2, "h": 2 } ] } ] }
JSON
render "$TMP_ROOT/unsized.json" --out "$TMP_ROOT/unsized.html"
expect_code 1 "$RC" "an unreadable image size with regions is refused"
assert_contains "$OUT" "declare \"space\"" "the refusal names the way out"
pass "an unknown coordinate space is refused rather than guessed"

# 0xFF fill bytes are legal padding before a JPEG marker. Misreading them as a
# segment resolves to a bogus offset, which is how a screenshot silently reports
# the wrong size and scales every ring on it wrong.
python3 - "$TMP_ROOT/padded.jpg" 200 100 <<'PY'
import struct, sys

path, width, height = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
sof0 = (b"\xff\xc0" + struct.pack(">H", 17) + b"\x08" + struct.pack(">HH", height, width)
        + b"\x03\x01\x11\x00\x02\x11\x01\x03\x11\x01")
with open(path, "wb") as handle:
    handle.write(b"\xff\xd8" + app0 + b"\xff\xff" + sof0 + b"\xff\xd9")
PY
cat > "$TMP_ROOT/padded-jpeg.json" <<'JSON'
{ "title": "padded jpeg", "findings": [ { "title": "ring", "screenshot": "padded.jpg",
  "regions": [ { "x": 50, "y": 25, "w": 100, "h": 50 } ] } ] }
JSON
render "$TMP_ROOT/padded-jpeg.json" --out "$TMP_ROOT/padded-jpeg.html"
expect_code 0 "$RC" "a JPEG padded with fill bytes renders"$'\n'"$OUT"
assert_grep 'left:25%;top:25%;width:50%;height:50%' "$TMP_ROOT/padded-jpeg.html" \
  "the padded JPEG's true 200x100 size drives the ring geometry"
pass "fill-byte padding never resolves to a wrong image size"

# --- output paths ------------------------------------------------------------

render "$TMP_ROOT/code-only.json" --stdout
expect_code 0 "$RC" "--stdout renders"
assert_contains "$OUT" "<!doctype html>" "--stdout writes the page to stdout"
pass "--stdout writes the page without touching disk"

# A fresh input path, so the assertion cannot be satisfied by a page an earlier
# --out case already wrote.
cp "$TMP_ROOT/code-only.json" "$TMP_ROOT/default-path.json"
assert_absent "$TMP_ROOT/default-path.html" "the default output path starts out unwritten"
render "$TMP_ROOT/default-path.json"
expect_code 0 "$RC" "the default output path renders"
assert_present "$TMP_ROOT/default-path.html" "the default output is the input path with .html"
assert_contains "$OUT" "default-path.html" "the written path is reported on stdout"

cp "$TMP_ROOT/code-only.json" "$TMP_ROOT/self.html"
render "$TMP_ROOT/self.html" --out "$TMP_ROOT/self.html"
expect_code 1 "$RC" "overwriting the input is refused"
assert_contains "$OUT" "refusing to overwrite the input" "the refusal says why"
pass "output paths behave, and the input is never overwritten"

render --help
expect_code 0 "$RC" "--help exits 0"
assert_contains "$OUT" "INPUT CONTRACT" "--help carries the input contract"
pass "--help documents the input contract"
