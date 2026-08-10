#!/usr/bin/env bash
# fm-visual-findings.sh - render visual defect findings as one self-contained
# annotated evidence page: screenshots with red rings over the exact defective
# regions, paired with the source lines that cause them.
#
# Usage:
#   fm-visual-findings.sh <findings.json> [--out <path>] [--base-dir <dir>] [--stdout]
#   fm-visual-findings.sh --help
#
# Flags:
#   --out <path>       write the page here (default: <input dir>/<input stem>.html)
#   --base-dir <dir>   resolve relative screenshot paths against this directory
#                      (default: the directory holding the input file)
#   --stdout           write the page to stdout instead of a file
#   -h, --help         print this usage and the complete input contract
#
# Output guarantees:
#   - ONE file, no sibling assets: every image is inlined as a data: URI.
#   - No network, no CDN, no script, no install: it opens straight off disk.
#   - Deterministic: identical input bytes render identical output bytes. Nothing
#     dated, random, host-specific, or path-dependent is embedded.
#   - Light and dark both legible, and no horizontal page scroll at any width:
#     wide code and long paths scroll or wrap inside their own box.
#
# Ring geometry is computed here, not tuned by eye. Regions are given in the
# coordinate space the automation already knows - an element bounding box from
# chrome-devtools-axi, or the screenshot's own pixels - and this script converts
# them to percentages of the rendered image, so the overlay survives any display
# size. `space` exists because a screenshot is often captured at a device pixel
# ratio above 1: declare the CSS-pixel viewport the boxes came from and the
# conversion is exact.
#
# This script owns mechanics only. The judgment - what makes a finding worth
# ringing, how to word an honest verdict, how to verify the rings landed - is
# owned by the `visual-findings-page` skill.
set -eu

exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import base64
import html
import json
import math
import os
import re
import struct
import sys
from pathlib import Path

PROG = "fm-visual-findings"

ALLOWED_TOP = {"title", "subtitle", "meta", "findings", "footer"}
ALLOWED_FINDING = {
    "id", "title", "severity", "level", "summary", "screenshot", "alt", "caption",
    "space", "units", "regions", "evidence", "verdict", "confidence",
}
ALLOWED_SPACE = {"width", "height"}
ALLOWED_REGION = {"label", "x", "y", "w", "h", "shape", "tag", "pad"}
ALLOWED_EVIDENCE = {"region", "heading", "note", "file", "line", "code", "caption", "body"}
ALLOWED_BLOCK = {"text", "bullets", "code", "caption", "file", "line"}

SHAPES = ("ellipse", "rect")
TAG_PLACEMENTS = ("auto", "above", "below", "left", "right")
# A tag is positioned inside the image frame and must stay there. These two decide
# only which SIDE of the ring it hangs from: TAG_MIN_ROOM of frame width for a tag
# that grows sideways, TAG_ROW_ROOM of frame height for one that grows up or down,
# which flips to the opposite edge when the requested one is short. Staying inside
# the frame is bounded separately, in the tag's own units - see tag_style().
TAG_MIN_ROOM = 26.0
TAG_ROW_ROOM = 16.0
UNITS = ("pixels", "percent")
LEVELS = ("high", "medium", "low", "none")

MIME_BY_SUFFIX = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".svg": "image/svg+xml",
}

SCHEMA = """
INPUT CONTRACT (JSON)

{
  "title":    "Onboarding: the connect screen contradicts itself",   required
  "subtitle": "one line of context",                                 optional
  "meta":     "commit 8387039 · debug build · Android emulator",     optional; what
                                                                     this was
                                                                     reproduced on
  "findings": [ <finding>, ... ]                                     required, >= 1
  "footer":   "fuller evidence lives beside this page"               optional
}

<finding>
  "title":      "what is wrong, in the reader's words"       required
  "id":         "connect-copy"                               optional anchor slug
                                                             ([a-z0-9-], unique)
  "severity":   "cosmetic"                                   optional free-text chip
  "level":      "high" | "medium" | "low" | "none"           optional; colours the
                                                             severity chip, so it
                                                             needs "severity" too.
                                                             Default none.
  "summary":    "lead paragraph"                             optional
  "screenshot": "connect-screen.png"                         optional; omit for a
                                                             code-only finding.
                                                             The four keys below
                                                             describe it, so each
                                                             one needs it.
  "alt":        "what the screenshot shows"                  optional, recommended;
                                                             needs "screenshot"
  "caption":    "text under the screenshot"                  optional; needs
                                                             "screenshot"
  "units":      "pixels" | "percent"                         optional, default
                                                             pixels; needs
                                                             "screenshot"
  "space":      {"width": 390, "height": 844}                optional; needs
                                                             "screenshot". The
                                                             coordinate
                                                             space the regions are
                                                             expressed in. Default:
                                                             the image's own pixel
                                                             size. Required when the
                                                             image size cannot be
                                                             read (see below).
                                                             Refused with "units":
                                                             "percent", which already
                                                             names its own space.
  "regions":    [ <region>, ... ]                            optional, needs screenshot
  "evidence":   [ <evidence>, ... ]                          optional
  "verdict":    "how strong this finding actually is"        optional
  "confidence": "high" | "medium" | ... free text            optional

<region>                one ring on the screenshot, numbered in array order
  "x", "y", "w", "h":   required. Top-left plus size, in the finding's units.
                        With "units": "percent" they are percentages of the image.
  "label":  "the actual button"      optional short text next to the ring number
  "shape":  "ellipse" | "rect"       optional, default ellipse
  "pad":    8                        optional; grow the ring by this much on every
                                     side, in the finding's units. Element bounding
                                     boxes hug their content, so 6-10 px of pad is
                                     usually what makes a ring read as a ring. The
                                     region itself must fit the coordinate space;
                                     pad past an edge is clamped, never refused.
  "tag":    "auto" | "above" | "below" | "left" | "right"
                                     optional, default auto. auto hangs the tag
                                     below the ring, or above it near the bottom
                                     edge; left and right centre it on the ring's
                                     side, which reads better beside a narrow ring.
                                     A tag always stays inside the frame: one with
                                     no room on the edge it was given flips to the
                                     opposite edge, a ring that spans the frame
                                     carries its tag inside the ring, and a tag
                                     taller than the room left for it is held
                                     against that frame edge, never past it.

<evidence>              one column entry; needs content from note/code/file or body
  "region":  1                       optional 1-based region number this explains
  "heading": "what the button actually says"   optional
  "note":    "prose"                 optional
  "file":    "src/locales/en/en.json"          optional
  "line":    421  or  "421-425"      optional; needs "file"
  "code":    "the offending lines"   optional
  "caption": "override the file:line caption"  optional
  "body":    [ <block>, ... ]        optional; use INSTEAD of note/code/file/caption
                                     when the order matters - code first and the
                                     commentary after it, or a list mid-argument.
                                     Mixing body with those keys is refused.

<block>                 exactly one of text, bullets or code
  "text":    "a paragraph"
  "bullets": [ "first point", "second point" ]
  "code":    "the offending lines", with optional "caption", or "file" + "line"

INLINE MARKUP, in every prose field (subtitle, meta, summary, note, text,
bullets, caption, verdict, footer):

  `literal`     a code span      **strong**    bold      *emphasis*    italic

Everything else is escaped, so a finding can quote markup safely. An unmatched
marker stays literal.

Image sizes are read from PNG and JPEG headers. Any other image type (or an
unreadable header) is still embedded, but then the finding must declare "space"
explicitly, or use "units": "percent".
""".strip()


class InputError(Exception):
    """One actionable input-contract failure."""


def fail(message: str) -> None:
    raise InputError(message)


# --- input validation -------------------------------------------------------


def obj(value: object, where: str, allowed: set[str]) -> dict:
    if not isinstance(value, dict):
        fail(f"{where} must be an object")
    unknown = sorted(set(value) - allowed)
    if unknown:
        fail(f"{where} has unknown key(s) {', '.join(unknown)}; allowed: {', '.join(sorted(allowed))}")
    return value


def text(value: object, where: str, *, required: bool = False, default: str = "") -> str:
    if value is None:
        if required:
            fail(f"{where} is required")
        return default
    if not isinstance(value, str) or not value.strip():
        fail(f"{where} must be a non-empty string")
    return value


def number(value: object, where: str) -> float:
    # JSON's bare NaN and Infinity parse into floats, and NaN compares False
    # against every bound, so a non-finite coordinate would slip past all the
    # geometry checks below and render a ring at nowhere in particular.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail(f"{where} must be a number")
    number_value = float(value)
    if not math.isfinite(number_value):
        fail(f"{where} must be a finite number")
    return number_value


def choice(value: object, where: str, options: tuple[str, ...], default: str) -> str:
    if value is None:
        return default
    if value not in options:
        fail(f"{where} must be one of {', '.join(options)}")
    return str(value)


def slug_ok(value: str) -> bool:
    return bool(value) and all(c.isascii() and (c.isdigit() or c.islower() or c == "-") for c in value)


def string_list(value: object, where: str) -> list[str]:
    if not isinstance(value, list) or not value:
        fail(f"{where} must be a non-empty array of strings")
    return [text(item, f"{where}[{i}]", required=True) for i, item in enumerate(value)]


# --- image handling ---------------------------------------------------------


def png_size(data: bytes) -> tuple[int, int] | None:
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", data[16:24])
    return (width, height) if width and height else None


def jpeg_size(data: bytes) -> tuple[int, int] | None:
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        return None
    i = 2
    end = len(data)
    while i + 3 < end:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker == 0xFF:
            # Legal fill padding before a marker. Reading a segment length from
            # here would land on the real marker's own bytes and jump to a bogus
            # offset - which can resolve to a wrong image size, not just None.
            i += 1
            continue
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        if i + 4 > end:
            return None
        seglen = struct.unpack(">H", data[i + 2:i + 4])[0]
        if seglen < 2:
            return None
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            if i + 9 > end:
                return None
            height, width = struct.unpack(">HH", data[i + 5:i + 9])
            return (width, height) if width and height else None
        i += 2 + seglen
    return None


def image_size(data: bytes) -> tuple[int, int] | None:
    return png_size(data) or jpeg_size(data)


def load_image(path: Path, where: str) -> tuple[str, tuple[int, int] | None]:
    try:
        data = path.read_bytes()
    except OSError as exc:
        fail(f"{where}: cannot read screenshot {path}: {exc}")
    suffix = path.suffix.lower()
    mime = MIME_BY_SUFFIX.get(suffix)
    if mime is None:
        fail(f"{where}: unsupported image type '{suffix or path.name}'; "
             f"supported: {', '.join(sorted(MIME_BY_SUFFIX))}")
    uri = "data:%s;base64,%s" % (mime, base64.b64encode(data).decode("ascii"))
    return uri, image_size(data)


# --- geometry ---------------------------------------------------------------


def pct(value: float) -> str:
    formatted = f"{value:.4f}".rstrip("0").rstrip(".")
    return formatted if formatted else "0"


def ring_box(region: dict, where: str, space: tuple[float, float]) -> dict:
    """The ring's box as percentages of the image.

    The REGION is what the finding claims, so the region is what is checked
    against the coordinate space. `pad` is presentation - it only grows the ring
    so a content-hugging bounding box reads as a ring - and an element flush
    against an edge is exactly the case that needs it, so the padded ring is
    clamped to the space rather than refused.
    """
    span_w, span_h = space
    pad = number(region.get("pad", 0), f"{where}.pad")
    if pad < 0:
        fail(f"{where}.pad must not be negative")
    x = number(region.get("x"), f"{where}.x")
    y = number(region.get("y"), f"{where}.y")
    w = number(region.get("w"), f"{where}.w")
    h = number(region.get("h"), f"{where}.h")
    if w <= 0 or h <= 0:
        fail(f"{where} has a non-positive size: w={pct(w)} h={pct(h)}")
    if x < 0 or y < 0 or x + w > span_w or y + h > span_h:
        fail(f"{where} falls outside the {pct(span_w)}x{pct(span_h)} coordinate space "
             f"(x={pct(x)} y={pct(y)} w={pct(w)} h={pct(h)}); "
             f"check the finding's units and space")
    left = max(0.0, x - pad)
    top = max(0.0, y - pad)
    right = min(span_w, x + w + pad)
    bottom = min(span_h, y + h + pad)
    return {
        "left": left / span_w * 100.0,
        "top": top / span_h * 100.0,
        "width": (right - left) / span_w * 100.0,
        "height": (bottom - top) / span_h * 100.0,
    }


def tag_anchor(box: dict, placement: str) -> tuple[str, float, float]:
    """A ring tag's final placement and anchor, as percentages of the image.

    This function chooses the SIDE and the anchor only. A side tag's anchor is
    clamped to leave TAG_MIN_ROOM of width for it to grow into. A tag that grows
    up or down uses the requested edge only when TAG_ROW_ROOM of frame is left
    there; otherwise it flips to the opposite edge, which is also what `auto`
    chooses between. When neither edge has room - a ring spanning nearly the whole
    screenshot - the tag hangs INSIDE the ring, from the edge with the most space
    outside it.

    Staying inside the frame is NOT this function's job, because a tag's height is
    a pixel count that no percentage of the frame can predict: the same 16% is
    130px on a tall screenshot and 10px on a wide-short one. These tests choose
    the side that reads best; `tag_style` then bounds the resulting offset in the
    tag's own units so it cannot leave the frame at any rendered size.
    """
    top, height = box["top"], box["height"]
    bottom = top + height
    if placement in ("left", "right"):
        if placement == "left":
            anchor_left = max(box["left"], TAG_MIN_ROOM)
        else:
            anchor_left = min(box["left"] + box["width"], 100.0 - TAG_MIN_ROOM)
        return placement, anchor_left, top + height / 2.0

    anchor_left = min(box["left"], 100.0 - TAG_MIN_ROOM)
    room = {"above": top, "below": 100.0 - bottom}
    if placement == "auto":
        placement = "below" if room["below"] >= TAG_ROW_ROOM else "above"
    if room[placement] < TAG_ROW_ROOM:
        placement = "above" if placement == "below" else "below"
    if room[placement] < TAG_ROW_ROOM:
        # Neither edge has room, so the tag hangs inside the ring instead: from
        # its top edge downwards when the space above is the larger of the two,
        # from its bottom edge upwards otherwise.
        placement = "below" if room["above"] >= room["below"] else "above"
        return placement, anchor_left, top if placement == "below" else bottom
    return placement, anchor_left, bottom if placement == "below" else top


def code_caption(source: dict, where: str) -> str:
    """The line above a code block: an explicit caption, else file[:line]."""
    caption = text(source.get("caption"), f"{where}.caption")
    path = text(source.get("file"), f"{where}.file")
    line = source.get("line")
    if line is not None:
        if isinstance(line, bool) or not isinstance(line, (int, str)) or (
                isinstance(line, str) and not line.strip()):
            fail(f"{where}.line must be a number or a non-empty string")
        if not path:
            fail(f"{where}.line needs a file to point into")
        path = f"{path}:{line}"
    return caption or path


def parse_blocks(item: dict, where: str) -> list[dict]:
    """One evidence entry's ordered content.

    The short form (note/code/file/caption) covers the common entry; `body` takes
    over when the ORDER matters - code first and the commentary after it, or a
    list mid-argument. They are alternatives, never a mixture, so an entry always
    has exactly one owner for its ordering.
    """
    short_keys = {"note", "code", "file", "line", "caption"} & set(item)
    if "body" in item:
        if short_keys:
            fail(f"{where} mixes body with {', '.join(sorted(short_keys))}; "
                 f"use body alone when the order matters")
        raw_blocks = item["body"]
        if not isinstance(raw_blocks, list) or not raw_blocks:
            fail(f"{where}.body must be a non-empty array of blocks")
        blocks = []
        for b_index, raw_block in enumerate(raw_blocks):
            b_where = f"{where}.body[{b_index}]"
            block = obj(raw_block, b_where, ALLOWED_BLOCK)
            kinds = {"text", "bullets", "code"} & set(block)
            if len(kinds) != 1:
                fail(f"{b_where} must carry exactly one of text, bullets or code")
            if "text" in block:
                blocks.append({"kind": "text", "text": text(block["text"], f"{b_where}.text", required=True)})
            elif "bullets" in block:
                blocks.append({"kind": "bullets", "items": string_list(block["bullets"], f"{b_where}.bullets")})
            else:
                blocks.append({
                    "kind": "code",
                    "code": text(block["code"], f"{b_where}.code", required=True),
                    "caption": code_caption(block, b_where),
                })
        return blocks

    blocks = []
    note = text(item.get("note"), f"{where}.note")
    if note:
        blocks.append({"kind": "text", "text": note})
    caption = code_caption(item, where)
    if "code" in item:
        blocks.append({
            "kind": "code",
            "code": text(item["code"], f"{where}.code", required=True),
            "caption": caption,
        })
    elif caption:
        blocks.append({"kind": "code", "code": "", "caption": caption})
    if not blocks:
        fail(f"{where} needs content: note, file, code, or a body")
    return blocks


def parse_finding(raw: object, index: int, base_dir: Path, seen_ids: set[str]) -> dict:
    where = f"findings[{index}]"
    data = obj(raw, where, ALLOWED_FINDING)

    severity = text(data.get("severity"), f"{where}.severity")
    level = choice(data.get("level"), f"{where}.level", LEVELS, "none")
    if data.get("level") is not None and not severity:
        fail(f"{where}.level needs a non-empty {where}.severity: level only colours the "
             f"severity chip, and without a severity there is no chip to colour")

    finding: dict = {
        "title": text(data.get("title"), f"{where}.title", required=True),
        "severity": severity,
        "level": level,
        "summary": text(data.get("summary"), f"{where}.summary"),
        "caption": text(data.get("caption"), f"{where}.caption"),
        "alt": text(data.get("alt"), f"{where}.alt"),
        "verdict": text(data.get("verdict"), f"{where}.verdict"),
        "confidence": text(data.get("confidence"), f"{where}.confidence"),
        "number": index + 1,
    }

    anchor = text(data.get("id"), f"{where}.id", default=f"finding-{index + 1}")
    if not slug_ok(anchor):
        fail(f"{where}.id must be lowercase letters, digits and dashes")
    if anchor in seen_ids:
        fail(f"{where}.id '{anchor}' is used by an earlier finding; ids must be unique")
    seen_ids.add(anchor)
    finding["anchor"] = anchor

    units = choice(data.get("units"), f"{where}.units", UNITS, "pixels")
    raw_regions = data.get("regions") or []
    if not isinstance(raw_regions, list):
        fail(f"{where}.regions must be an array")

    screenshot = text(data.get("screenshot"), f"{where}.screenshot")
    if raw_regions and not screenshot:
        fail(f"{where} has regions but no screenshot to draw them on")
    if not screenshot:
        # Every one of these describes the screenshot or the space its regions are
        # measured in, so on a code-only finding the renderer would drop them all.
        orphans = [key for key in ("alt", "caption", "space", "units")
                   if data.get(key) is not None]
        if orphans:
            named = ", ".join(f"{where}.{key}" for key in orphans)
            fail(f"{named} {'needs' if len(orphans) == 1 else 'need'} a "
                 f"{where}.screenshot: {'it describes' if len(orphans) == 1 else 'they describe'} "
                 f"the screenshot, and without one there is nothing to describe")

    natural: tuple[int, int] | None = None
    if screenshot:
        path = Path(screenshot)
        if not path.is_absolute():
            path = base_dir / path
        finding["image"], natural = load_image(path, where)
    if not finding.get("alt") and screenshot:
        finding["alt"] = finding["title"]

    space = data.get("space")
    if space is not None:
        if units == "percent":
            fail(f"{where} declares both \"units\": \"percent\" and \"space\"; percent regions "
                 f"are already percentages of the image, so drop one of the two")
        space_obj = obj(space, f"{where}.space", ALLOWED_SPACE)
        span = (number(space_obj.get("width"), f"{where}.space.width"),
                number(space_obj.get("height"), f"{where}.space.height"))
        if span[0] <= 0 or span[1] <= 0:
            fail(f"{where}.space must have a positive width and height")
    elif units == "percent":
        span = (100.0, 100.0)
    elif natural is not None:
        span = (float(natural[0]), float(natural[1]))
    elif raw_regions:
        fail(f"{where}: the screenshot's pixel size could not be read, so the "
             f"coordinate space is unknown; declare \"space\" or use \"units\": \"percent\"")
    else:
        span = (100.0, 100.0)

    regions = []
    for r_index, raw_region in enumerate(raw_regions):
        r_where = f"{where}.regions[{r_index}]"
        region = obj(raw_region, r_where, ALLOWED_REGION)
        box = ring_box(region, r_where, span)
        placement, anchor_left, anchor_top = tag_anchor(
            box, choice(region.get("tag"), f"{r_where}.tag", TAG_PLACEMENTS, "auto"))
        regions.append({
            "number": r_index + 1,
            "label": text(region.get("label"), f"{r_where}.label"),
            "shape": choice(region.get("shape"), f"{r_where}.shape", SHAPES, "ellipse"),
            "placement": placement,
            "anchor": (anchor_left, anchor_top),
            "box": box,
        })
    finding["regions"] = regions

    raw_evidence = data.get("evidence") or []
    if not isinstance(raw_evidence, list):
        fail(f"{where}.evidence must be an array")
    evidence = []
    for e_index, raw_item in enumerate(raw_evidence):
        e_where = f"{where}.evidence[{e_index}]"
        item = obj(raw_item, e_where, ALLOWED_EVIDENCE)
        entry = {
            "heading": text(item.get("heading"), f"{e_where}.heading"),
            "blocks": parse_blocks(item, e_where),
            "region": None,
        }
        ref = item.get("region")
        if ref is not None:
            if isinstance(ref, bool) or not isinstance(ref, int):
                fail(f"{e_where}.region must be a region number")
            if not 1 <= ref <= len(regions):
                fail(f"{e_where}.region {ref} has no matching ring "
                     f"(this finding has {len(regions)})")
            entry["region"] = ref
        evidence.append(entry)
    finding["evidence"] = evidence

    if not (finding["regions"] or finding["evidence"] or finding["summary"] or finding["verdict"]):
        fail(f"{where} has nothing to show: add a region, evidence, a summary or a verdict")
    return finding


def parse_document(raw: object, base_dir: Path) -> dict:
    data = obj(raw, "the document", ALLOWED_TOP)
    findings_raw = data.get("findings")
    if not isinstance(findings_raw, list) or not findings_raw:
        fail("findings must be a non-empty array")
    seen_ids: set[str] = set()
    return {
        "title": text(data.get("title"), "title", required=True),
        "subtitle": text(data.get("subtitle"), "subtitle"),
        "meta": text(data.get("meta"), "meta"),
        "footer": text(data.get("footer"), "footer"),
        "findings": [parse_finding(f, i, base_dir, seen_ids) for i, f in enumerate(findings_raw)],
    }


# --- rendering --------------------------------------------------------------

STYLE = """
:root {
  color-scheme: light dark;
  --bg: #f4f5f8;
  --surface: #ffffff;
  --sunken: #eef0f5;
  --text: #16181d;
  --muted: #565b6b;
  --border: #dfe2ea;
  --accent: #c50f3c;
  --ring: #e0113f;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14151a;
    --surface: #1b1d24;
    --sunken: #22242c;
    --text: #e8e8ea;
    --muted: #a6aab7;
    --border: #2c2f39;
    --accent: #ff5c7c;
    --ring: #ff2d55;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0;
  padding: 32px 24px 64px;
  background: var(--bg);
  color: var(--text);
  font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  overflow-wrap: break-word;
}
.page { max-width: 1120px; margin: 0 auto; }
h1 { font-size: 23px; line-height: 1.3; margin: 0 0 6px; letter-spacing: -0.2px; }
.subtitle { margin: 0; color: var(--muted); max-width: 78ch; }
.meta {
  margin: 12px 0 0; color: var(--muted);
  font: 12.5px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace;
}
.page > footer {
  margin: 30px 0 0; padding-top: 18px; border-top: 1px solid var(--border);
  color: var(--muted); font-size: 13.5px;
}
.index { margin: 26px 0 0; padding: 14px 18px; background: var(--surface);
  border: 1px solid var(--border); border-radius: 12px; }
.index ol { margin: 0; padding-left: 22px; }
.index li { margin: 3px 0; }
.index a { color: inherit; }
.finding {
  margin: 26px 0 0; padding: 22px; background: var(--surface);
  border: 1px solid var(--border); border-radius: 14px;
}
.finding-head { margin: 0 0 16px; }
.eyebrow {
  display: inline-block; font-size: 12px; font-weight: 700; letter-spacing: 0.8px;
  text-transform: uppercase; color: var(--accent);
}
.chip {
  display: inline-block; margin-left: 8px; padding: 1px 9px; border-radius: 999px;
  border: 1px solid var(--border); background: var(--sunken);
  font-size: 11.5px; font-weight: 600; letter-spacing: 0.4px;
  text-transform: uppercase; color: var(--muted); vertical-align: 1px;
}
.chip.high { background: var(--ring); border-color: var(--ring); color: #fff; }
.chip.medium { background: #f0a020; border-color: #f0a020; color: #241a00; }
.chip.low { background: #6b7180; border-color: #6b7180; color: #fff; }
.finding-head h2 { font-size: 19px; line-height: 1.35; margin: 8px 0 0; letter-spacing: -0.15px; }
.summary { margin: 10px 0 0; color: var(--muted); }
.body { display: grid; gap: 28px; grid-template-columns: minmax(0, 380px) minmax(0, 1fr); align-items: start; }
.body.code-only { grid-template-columns: minmax(0, 1fr); }
@media (max-width: 860px) { .body { grid-template-columns: minmax(0, 1fr); } }
figure { margin: 0; min-width: 0; }
.frame { position: relative; display: block; border-radius: 12px; background: var(--sunken); }
.frame img { display: block; width: 100%; height: auto; border-radius: 12px; }
figcaption { margin-top: 10px; font-size: 13px; color: var(--muted); }
.ring {
  position: absolute; border: 3px solid var(--ring); pointer-events: none;
  box-shadow: 0 0 0 2px rgba(255,255,255,0.65), 0 0 16px rgba(224,17,63,0.45);
}
.ring.ellipse { border-radius: 999px; }
.ring.rect { border-radius: 7px; }
.frame {
  /* --tag-h is this tag's own height: 12px text at line-height 1.5, plus 2px of
     padding top and bottom. Containment is bounded against it, so a change to
     the tag's font, line-height or padding must change it too. --tag-gap is the
     space the tag keeps off its ring. */
  --tag-h: 22px;
  --tag-gap: 7px;
}
.tag {
  position: absolute;
  display: inline-flex; align-items: center; gap: 6px;
  padding: 2px 9px 2px 3px; border-radius: 999px; overflow: hidden;
  background: var(--ring); color: #fff; font-size: 12px; font-weight: 600;
  line-height: 1.5; pointer-events: none;
}
.tag .text { min-width: 0; overflow-wrap: anywhere; }
.tag .num, .ev .num {
  display: inline-flex; align-items: center; justify-content: center;
  width: 18px; height: 18px; border-radius: 999px; flex: 0 0 auto;
  background: rgba(0,0,0,0.28); font-size: 11.5px; font-weight: 700;
}
.tag.bare { padding-right: 3px; }
.evidence { min-width: 0; }
.ev { margin: 0 0 22px; min-width: 0; }
.ev:last-child { margin-bottom: 0; }
.ev h3 {
  display: flex; align-items: center; gap: 8px; margin: 0 0 8px;
  font-size: 13px; font-weight: 700; letter-spacing: 0.5px; text-transform: uppercase;
  color: var(--accent);
}
.ev .num { background: var(--ring); color: #fff; }
.ev p { margin: 0 0 10px; color: var(--muted); }
.ev ul { margin: 0 0 10px; padding-left: 20px; color: var(--muted); }
.ev li { margin: 0 0 5px; }
.ev p:last-child, .ev ul:last-child { margin-bottom: 0; }
.ev strong, .summary strong, .verdict strong { color: var(--text); font-weight: 700; }
:not(pre) > code {
  padding: 1px 5px; border-radius: 5px; background: var(--sunken);
  border: 1px solid var(--border);
  font: 12.5px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
  overflow-wrap: anywhere;
}
.block { margin: 0 0 10px; }
.block:last-child { margin-bottom: 0; }
.src {
  font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
  color: var(--muted); margin-bottom: 5px; overflow-wrap: anywhere;
}
pre {
  margin: 0; padding: 12px 14px; border-radius: 10px; overflow-x: auto;
  background: var(--sunken); border-left: 3px solid var(--ring);
  font: 12.5px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
}
pre code { white-space: pre; }
.verdict {
  margin-top: 20px; padding: 14px 16px; border-radius: 10px;
  background: var(--sunken); border: 1px solid var(--border); color: var(--muted);
}
.verdict .label { display: block; margin-bottom: 4px; font-size: 12px; font-weight: 700;
  letter-spacing: 0.6px; text-transform: uppercase; color: var(--text); }
""".strip()


def esc(value: str) -> str:
    return html.escape(value, quote=True)


# Inline markup runs AFTER escaping, so every capture is already-escaped text and
# the only tags that can reach the page are the three this function writes.
# Emphasis content may not begin or end with whitespace, so a lone asterisk in
# prose ("an unmatched * marker and a **bold** span") cannot pair with the opener
# of a later run and swallow the text between them.
_EMPHASIS = r"\S(?:[^*\n]*\S)?"
INLINE_RE = re.compile(r"`([^`\n]+)`|\*\*(%s)\*\*|\*(%s)\*" % (_EMPHASIS, _EMPHASIS))


def markup(escaped: str) -> str:
    """Apply inline markup to already-escaped text.

    Emphasis recurses so a code span nests inside bold - `**`title` is optional**`
    is the shape a finding actually needs. A code span itself never recurses: its
    content is literal by definition. Recursion terminates because each captured
    group is strictly shorter than its match.
    """
    def replace(match: re.Match[str]) -> str:
        if match.group(1) is not None:
            return "<code>%s</code>" % match.group(1)
        if match.group(2) is not None:
            return "<strong>%s</strong>" % markup(match.group(2))
        return "<em>%s</em>" % markup(match.group(3))

    return INLINE_RE.sub(replace, escaped)


def inline(value: str) -> str:
    return markup(esc(value))


def tag_style(placement: str, anchor_left: float, anchor_top: float) -> str:
    """One tag's absolute position, bounded so it cannot leave the frame.

    The tag is positioned against the ring's own edge, and every offset is then
    bounded with CSS min/max/clamp against `--tag-h`, the tag's declared height.
    That is what keeps the two guarantees from competing: the browser resolves
    the bound at whatever size the figure renders, so a wide-short screenshot
    holds the tag at the frame edge it is attached to instead of pushing it out,
    and nothing here relies on the frame clipping a badly placed tag.

    A percentage cannot do this job alone - a tag's height is a pixel count, and
    the same 16% of frame height is 130px on a tall screenshot and 10px on a
    wide-short one - which is why the bound is expressed in the tag's own units.
    """
    left, right = pct(anchor_left), pct(100.0 - anchor_left)
    top = pct(anchor_top)
    if placement == "below":
        return ("left:%s%%;top:min(calc(%s%% + var(--tag-gap)),calc(100%% - var(--tag-h)));"
                "max-width:calc(100%% - %s%% - 4px)" % (left, top, left))
    if placement == "above":
        return ("left:%s%%;bottom:min(calc(100%% - %s%% + var(--tag-gap)),calc(100%% - var(--tag-h)));"
                "max-width:calc(100%% - %s%% - 4px)" % (left, top, left))
    centred = ("top:clamp(0px,calc(%s%% - var(--tag-h) / 2),calc(100%% - var(--tag-h)))" % top)
    if placement == "right":
        return ("left:calc(%s%% + var(--tag-gap));%s;"
                "max-width:calc(100%% - %s%% - var(--tag-gap) - 4px)" % (left, centred, left))
    return ("right:calc(%s%% + var(--tag-gap));%s;"
            "max-width:calc(%s%% - var(--tag-gap) - 4px)" % (right, centred, left))


def render_regions(finding: dict, out: list[str]) -> None:
    for region in finding["regions"]:
        box = region["box"]
        style = "left:%s%%;top:%s%%;width:%s%%;height:%s%%" % (
            pct(box["left"]), pct(box["top"]), pct(box["width"]), pct(box["height"]))
        out.append('      <div class="ring %s" style="%s"></div>' % (region["shape"], style))
        placement = region["placement"]
        anchor_left, anchor_top = region["anchor"]
        classes = "tag %s%s" % (placement, "" if region["label"] else " bare")
        label = ('<span class="text">%s</span>' % esc(region["label"])) if region["label"] else ""
        out.append('      <div class="%s" style="%s"><span class="num">%d</span>%s</div>'
                   % (classes, tag_style(placement, anchor_left, anchor_top),
                      region["number"], label))


def render_blocks(blocks: list[dict], out: list[str], indent: str) -> None:
    for block in blocks:
        if block["kind"] == "text":
            out.append("%s<p>%s</p>" % (indent, inline(block["text"])))
        elif block["kind"] == "bullets":
            out.append("%s<ul>" % indent)
            for item in block["items"]:
                out.append("%s  <li>%s</li>" % (indent, inline(item)))
            out.append("%s</ul>" % indent)
        else:
            out.append('%s<div class="block">' % indent)
            if block["caption"]:
                out.append('%s  <div class="src">%s</div>' % (indent, inline(block["caption"])))
            if block["code"]:
                out.append("%s  <pre><code>%s</code></pre>" % (indent, esc(block["code"].rstrip("\n"))))
            out.append("%s</div>" % indent)


def render_evidence(finding: dict, out: list[str]) -> None:
    for entry in finding["evidence"]:
        out.append('      <section class="ev">')
        if entry["heading"] or entry["region"] is not None:
            out.append("        <h3>")
            if entry["region"] is not None:
                out.append('          <span class="num">%d</span>' % entry["region"])
            if entry["heading"]:
                out.append("          <span>%s</span>" % esc(entry["heading"]))
            out.append("        </h3>")
        render_blocks(entry["blocks"], out, "        ")
        out.append("      </section>")


def render(doc: dict) -> str:
    out: list[str] = []
    out.append("<!doctype html>")
    out.append('<html lang="en">')
    out.append("<head>")
    out.append('<meta charset="utf-8">')
    out.append('<meta name="viewport" content="width=device-width, initial-scale=1">')
    out.append("<title>%s</title>" % esc(doc["title"]))
    out.append("<style>")
    out.append(STYLE)
    out.append("</style>")
    out.append("</head>")
    out.append("<body>")
    out.append('<div class="page">')
    out.append("<header>")
    out.append("<h1>%s</h1>" % esc(doc["title"]))
    if doc["subtitle"]:
        out.append('<p class="subtitle">%s</p>' % inline(doc["subtitle"]))
    if doc["meta"]:
        out.append('<p class="meta">%s</p>' % inline(doc["meta"]))
    out.append("</header>")

    findings = doc["findings"]
    if len(findings) > 1:
        out.append('<nav class="index"><ol>')
        for finding in findings:
            out.append('  <li><a href="#%s">%s</a></li>' % (esc(finding["anchor"]), esc(finding["title"])))
        out.append("</ol></nav>")

    for finding in findings:
        out.append('<article class="finding" id="%s">' % esc(finding["anchor"]))
        out.append('  <header class="finding-head">')
        eyebrow = "Finding %d" % finding["number"]
        chip = ""
        if finding["severity"]:
            chip = '<span class="chip %s">%s</span>' % (finding["level"], esc(finding["severity"]))
        out.append('    <span class="eyebrow">%s</span>%s' % (esc(eyebrow), chip))
        out.append("    <h2>%s</h2>" % esc(finding["title"]))
        if finding["summary"]:
            out.append('    <p class="summary">%s</p>' % inline(finding["summary"]))
        out.append("  </header>")

        has_shot = "image" in finding
        out.append('  <div class="body%s">' % ("" if has_shot else " code-only"))
        if has_shot:
            out.append("    <figure>")
            out.append('      <div class="frame">')
            out.append('        <img src="%s" alt="%s">' % (finding["image"], esc(finding["alt"])))
            render_regions(finding, out)
            out.append("      </div>")
            if finding["caption"]:
                out.append("      <figcaption>%s</figcaption>" % inline(finding["caption"]))
            out.append("    </figure>")
        out.append('    <div class="evidence">')
        render_evidence(finding, out)
        if finding["verdict"] or finding["confidence"]:
            out.append('      <div class="verdict">')
            label = "Verdict" if not finding["confidence"] else "Verdict - confidence: %s" % finding["confidence"]
            out.append('        <span class="label">%s</span>' % esc(label))
            if finding["verdict"]:
                out.append("        %s" % inline(finding["verdict"]))
            out.append("      </div>")
        out.append("    </div>")
        out.append("  </div>")
        out.append("</article>")

    if doc["footer"]:
        out.append("<footer>%s</footer>" % inline(doc["footer"]))
    out.append("</div>")
    out.append("</body>")
    out.append("</html>")
    return "\n".join(out) + "\n"


# --- entry point ------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog=PROG, add_help=False,
        description="Render visual defect findings as one self-contained annotated evidence page.",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=SCHEMA)
    parser.add_argument("input", nargs="?", help="findings JSON described below")
    parser.add_argument("--out", metavar="PATH",
                        help="write the page here (default: the input path with a .html suffix)")
    parser.add_argument("--base-dir", metavar="DIR",
                        help="resolve relative screenshot paths against DIR "
                             "(default: the directory holding the input)")
    parser.add_argument("--stdout", action="store_true",
                        help="write the page to stdout instead of a file")
    parser.add_argument("-h", "--help", action="store_true", help="print this usage and exit")
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return 2

    if args.help or args.input is None:
        parser.print_help()
        return 0 if args.help else 2
    if args.stdout and args.out:
        print(f"{PROG}: --stdout and --out are mutually exclusive", file=sys.stderr)
        return 2

    source = Path(args.input)
    try:
        raw = json.loads(source.read_text(encoding="utf-8"))
    except OSError as exc:
        print(f"{PROG}: cannot read {source}: {exc}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as exc:
        print(f"{PROG}: {source} is not valid JSON: {exc}", file=sys.stderr)
        return 1

    base_dir = Path(args.base_dir) if args.base_dir else source.parent
    try:
        page = render(parse_document(raw, base_dir))
    except InputError as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        return 1

    if args.stdout:
        sys.stdout.write(page)
        return 0

    target = Path(args.out) if args.out else source.with_suffix(".html")
    if target.resolve() == source.resolve():
        print(f"{PROG}: refusing to overwrite the input file {source}", file=sys.stderr)
        return 1
    try:
        target.write_text(page, encoding="utf-8")
    except OSError as exc:
        print(f"{PROG}: cannot write {target}: {exc}", file=sys.stderr)
        return 1
    print(os.path.abspath(target))
    return 0


try:
    sys.exit(main(sys.argv[1:]))
except BrokenPipeError:
    sys.exit(0)
PY
