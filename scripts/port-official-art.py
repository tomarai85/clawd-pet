#!/usr/bin/env python3
"""Port the official claude.dev Clawd animations (Lottie) onto the pet's half-unit grid.

Spec: .harness/spec-clawd-pet-v2-2026-10-17.md sections 3.0-3.2, 3.5-3.6 and the Interface Contract (catalog schema 2).

Usage:  python3 -I scripts/port-official-art.py [--art DIR]

Reads    <art>/sources/lottie/*.js   the 37 official files, byte-identical copies of the reference board's img/official/lottie
                                     (claude.dev/shared/video[/acts]/<name>.json wrapped for the page); their sha256 goes into the catalog
         <art>/frames/idle_0.png     the v1 rest pose that every ported rest frame must equal
Writes   <art>/motions/<motion id>/NNN.png    frames at 2 px per unit (one pixel = one half-unit cell), cropped to the motion's stage
         <art>/looks/<look id>/layer.png      cut-out costume and prop layers
         <art>/clawd-atlas.json               schema 2: the v1 text stays byte-identical, `schema`, `motions`, `looks` are appended
         <art>/reports/resampling-report.json, <art>/preview/v2/contact-sheet-phase1.png, resampling-review.png
Re-running it rewrites the same bytes; it refuses to run when motions/ or looks/ hold files it did not write.

How a source frame becomes a pet frame
  Every Lottie file is 12 fps, 2750 x 1850 px, with layers of filled axis-aligned rectangles whose fill opacity is keyed (0 or 100) per
  frame; nothing animates a transform or a path (the parser refuses a file that does). One pet unit is 100 source px and the pet canvas
  is 12 x 12 units, so a source cell is 50 px (a half unit). Cell (i, j) starts at (X0 + 50 i, Y0 + 50 j) in source px; its colour is
  the colour of the topmost visible rectangle that contains the cell's centre (half-open: left and top edges in), for cells whose
  centre lies inside the source canvas.
  Origin: Y0 = 650 (the feet baseline is the bottom edge of the source canvas, 1850). X0 is the lattice point (the lattice phase is the
  integer that puts most rectangle edges within 2 px of the 50 px lattice) at which the file's first frame that shows the v1 rest
  pose lands in the pet canvas. A34 has no such frame (a side view throughout): its X0 is the lattice point nearest its leftmost edge.
  Colours: the body layer is mapped to the pet's rgb(215,119,87) and the eye layer to the pet's rgb(20,20,19). The spec names only
  217,119,87 -> 215,119,87, but nine files carry other values for Clawd himself (body 216,118,86 or 218,126,95; eyes 0,0,0), which would
  break the rest identity P2; every other colour is kept. The map is declared per entry.
  Rest and loops: `restStart` / `restEnd` say whether the first / last frame equals the v1 idle_0 (whole canvas, nothing else drawn). A
  motion that starts on rest and does not end on it appends its first frame (`closeLoop`); Snooze holds its last frame (`hold`); a motion
  with no rest frame at either end (A10 break dance, A34 arcade) declares `offRest`.
  Head anchor `head` (per frame, canvas cells, x = cell edge at the middle of the head, y = top row): the topmost 16 x 6 cell block of
  Clawd's own colours whose eyes sit in its rows 1..4 (exact; `rigidHead` when every frame has one); without such a block the face
  fallback uses the eyes that touch Clawd's body; null when there are none (side view). `overheadClear`: nothing but body colours above
  the anchor in any frame. `compatibleLooks` (K1): `plain`, plus every head-anchored look whose anchor is exact in every frame or whose
  signature the motion is (the motion draws the prop itself), or, for a motion without an exact head block in some frame (tier 1), whose
  anchor exists in every frame and follows the eyes, with nothing the motion draws above the head on or next to a cell of the look (rules in
  scripts/port-phase2-art.py). Scene uses that fail overhead-clear (or SENT longer than 2.0 s) are dropped.
"""
import argparse
import hashlib
import json
import os
import re
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CELL = 50                      # source px per cell (a half unit)
CANVAS = 24                    # the pet canvas, 12 units = 24 cells
SOURCE_W, SOURCE_H = 2750, 1850
Y0 = 650                       # feet baseline: the bottom edge of the source canvas (1850) minus 12 units
PET_BODY = (215, 119, 87)
PET_EYE = (20, 20, 19)
FPS = 12
FACE_W, FACE_H = 16, 6         # the head block: 8 x 3 units in cells
SCENE_USES = ("listening", "thinking", "sent", "interrupted", "error")
SENT_MAX_MS = 2000
SIG = b"\x89PNG\r\n\x1a\n"
LOTTIE_RE = re.compile(r'window\.CLAWD_LOTTIE=window\.CLAWD_LOTTIE\|\|\{\};window\.CLAWD_LOTTIE\["([^"]+)"\]=(.*);\s*', re.S)

# The A items of spec 3.2: motion id, board id, source file stem, declared uses. A1 and A5 also yield a derived entry (below).
# `uses` are the spec's candidates; scene uses that fail their rule are dropped by the computed catalog.
A_ITEMS = [
    ("A1-thinking", "A1", "Clawd-Thinking", ["idle"]),
    ("A2-looking", "A2", "clawd-looking", ["idle", "listening", "walk-pause"]),
    ("A3-jumping", "A3", "Clawd-Jumping", ["sent", "touch", "idle", "drop"]),
    ("A3-jumping-happy", "A3", "Clawd-JumpingHappy", ["sent", "touch", "idle", "drop"]),
    ("A4-waving", "A4", "clawd-waving", ["sent", "touch", "idle"]),
    ("A5-walking", "A5", "clawd-walking", ["walk"]),
    ("A6-turning", "A6", "Clawd-Turning", ["idle", "multi-touch"]),
    ("A7-swaying", "A7", "Clawd-Swaying", ["idle"]),
    ("A8-excited", "A8", "Clawd-Excited", ["sent", "touch", "idle", "drop"]),
    ("A9-dancing", "A9", "Clawd-Dancing", ["idle"]),
    ("A9-dancing-happy", "A9", "Clawd-DancingHappy", ["idle"]),
    ("A10-breakdancing", "A10", "Clawd-BreakDancing", ["idle"]),
    ("A11-confetti", "A11", "Clawd-Confetti", ["idle"]),
    ("A11-confetti-happy", "A11", "Clawd-ConfettiHappy", ["idle"]),
    ("A12-heart", "A12", "Clawd-Heart", ["touch", "idle"]),
    ("A13-rainbow", "A13", "Clawd-Rainbow", ["idle"]),
    ("A14-lightbulb", "A14", "Clawd-Lightbulb", ["idle"]),
    ("A15-snooze", "A15", "Clawd-Snooze", ["sleep-entry"]),
    ("A16-meditating", "A16", "Clawd-Meditating", ["idle"]),
    ("A17-sunglasses", "A17", "Clawd-Sunglasses", ["idle"]),
    ("A18-headphones", "A18", "Clawd-Headphones", ["idle", "signature:headphones"]),
    ("A19-coffee", "A19", "Clawd-Coffee", ["idle", "signature:coffee"]),
    ("A20-laptop", "A20", "Clawd-Laptop", ["thinking", "idle"]),
    ("A21-desktop", "A21", "Clawd-Desktop", ["idle"]),
    ("A22-notebook", "A22", "Clawd-Notebook", ["thinking", "idle"]),
    ("A23-phone", "A23", "Clawd-Phone", ["idle"]),
    ("A24-watch", "A24", "Clawd-Watch", ["idle"]),
    ("A25-spark", "A25", "Clawd-Spark", ["idle", "signature:wand", "signature:ultra"]),
    ("A26-juggling", "A26", "Clawd-Juggling", ["idle"]),
    ("A27-hulahoop", "A27", "Clawd-HulaHoop", ["idle"]),
    ("A28-bubble", "A28", "Clawd-Bubble", ["idle"]),
    ("A29-fishing", "A29", "Clawd-Fishing", ["idle"]),
    ("A30-watering", "A30", "Clawd-Watering", ["idle"]),
    ("A31-blooming", "A31", "Clawd-Blooming", ["idle"]),
    ("A32-berrypicking", "A32", "Clawd-BerryPicking", ["idle"]),
    ("A33-rose", "A33", "Clawd-Rose", ["touch", "idle"]),
    ("A34-arcade", "A34", "Clawd-Arcade", ["idle"]),
]
# A1's variant without the official blue speech bubble: the `light_blue` layer and the black dots that sit inside the bubble
# (black rectangles lying entirely above source y 1050, the torso top; the eyes never do).
A1_NOBUBBLE = ("A1-thinking-nobubble", "A1", "Clawd-Thinking", ["thinking"],
               [{"layer": "light_blue"}, {"layer": "black", "maxY": 1050}])
A5_MIRRORED = ("A5-walking-mirrored", "A5", "A5-walking", ["walk"])
DETAIL_STEMS = {"Clawd-ConfettiHappy", "Clawd-Juggling", "Clawd-Fishing"}  # the spec's two partly off-grid files, plus the one measured off-grid
HOLD_STEMS = {"Clawd-Snooze"}  # the last (asleep) frame stays on screen until the wake (spec 3.1 P3)


class PortError(Exception):
    pass


# ---- PNG ----------------------------------------------------------------------------------------------------------------
def read_png(path):
    """Decode an RGBA8, non-interlaced PNG into (w, h, rows) with each row a bytes object of w*4 bytes."""
    data = open(path, "rb").read()
    if data[:8] != SIG:
        raise PortError("%s: not a PNG" % path)
    i, idat, ihdr = 8, [], None
    while i + 12 <= len(data):
        ln, tag = struct.unpack(">I4s", data[i:i + 8])
        body = data[i + 8:i + 8 + ln]
        if len(body) != ln or zlib.crc32(tag + body) & 0xFFFFFFFF != struct.unpack(">I", data[i + 8 + ln:i + 12 + ln])[0]:
            raise PortError("%s: bad chunk %r" % (path, tag))
        i += 12 + ln
        if tag == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif tag == b"IDAT":
            idat.append(body)
    if ihdr is None or ihdr[2:] != (8, 6, 0, 0, 0):
        raise PortError("%s: need RGBA8 non-interlaced" % path)
    w, h = ihdr[0], ihdr[1]
    raw = zlib.decompress(b"".join(idat))
    stride = w * 4
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        cur = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if f == 1:
            for k in range(4, stride):
                cur[k] = (cur[k] + cur[k - 4]) & 255
        elif f == 2:
            for k in range(stride):
                cur[k] = (cur[k] + prev[k]) & 255
        elif f == 3:
            for k in range(stride):
                cur[k] = (cur[k] + (((cur[k - 4] if k >= 4 else 0) + prev[k]) >> 1)) & 255
        elif f == 4:
            for k in range(stride):
                a = cur[k - 4] if k >= 4 else 0
                b = prev[k]
                c = prev[k - 4] if k >= 4 else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                cur[k] = (cur[k] + (a if (pa <= pb and pa <= pc) else (b if pb <= pc else c))) & 255
        elif f != 0:
            raise PortError("%s: bad PNG filter %d" % (path, f))
        rows.append(bytes(cur))
        prev = cur
    return w, h, rows


def png_bytes(grid):
    """Encode a grid (list of rows; each cell None or an (r, g, b) / (r, g, b, a) tuple) as an RGBA8 PNG, deterministic."""
    h, w = len(grid), len(grid[0])
    raw = bytearray()
    for row in grid:
        raw.append(0)
        for c in row:
            if c is None:
                raw += b"\x00\x00\x00\x00"
            else:
                raw += bytes(c) if len(c) == 4 else bytes(c) + b"\xff"

    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    return (SIG + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def write_file(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


# ---- the Lottie file ----------------------------------------------------------------------------------------------------
class Rect:
    """One visible-or-not rectangle: source px times 100 (exact integers), its colour, its layer name and its per-frame opacity."""
    __slots__ = ("li", "gi", "layer", "x0", "y0", "x1", "y1", "rgb", "vis", "cells")

    def __init__(self, li, gi, layer, x0, y0, x1, y1, rgb, vis):
        self.li, self.gi, self.layer = li, gi, layer
        self.x0, self.y0, self.x1, self.y1, self.rgb, self.vis = x0, y0, x1, y1, rgb, vis
        self.cells = None


def _int100(v, where):
    r = round(v * 100)
    if abs(v * 100 - r) > 1e-6:
        raise PortError("%s: coordinate %r has more than two decimals" % (where, v))
    return r


def _color(c, where):
    if not (isinstance(c, list) and len(c) == 4 and c[3] == 1):
        raise PortError("%s: fill colour %r is not an opaque rgb(a) list" % (where, c))
    out = []
    for v in c[:3]:
        if abs(v * 255 - round(v * 255)) > 1e-3:
            raise PortError("%s: colour channel %r is not a whole 8-bit value" % (where, v))
        out.append(round(v * 255))
    return tuple(out)


def parse_lottie(path):
    """Parse one official file into (frame count, [Rect]); refuse anything this port does not model (transforms, curves, partial opacity)."""
    text = open(path, "rb").read().decode("utf-8")
    m = LOTTIE_RE.fullmatch(text)
    if not m:
        raise PortError("%s: not a CLAWD_LOTTIE wrapper" % path)
    j = json.loads(m.group(2))
    where = os.path.basename(path)
    if j.get("fr") != FPS or j.get("ip") != 0 or j.get("w") != SOURCE_W or j.get("h") != SOURCE_H or j.get("assets") != [] or j.get("ddd") != 0:
        raise PortError("%s: composition is not 12 fps, 2750 x 1850, ip 0, no assets" % where)
    n = j["op"]
    if type(n) is not int or n < 1:
        raise PortError("%s: bad op %r" % (where, n))
    ident = {"a": {"a": 0, "k": [0, 0, 0]}, "o": {"a": 0, "k": 100}, "p": {"a": 0, "k": [0, 0, 0]}, "r": {"a": 0, "k": 0},
             "s": {"a": 0, "k": [100, 100, 100]}}
    ident_tr = {"a": {"a": 0, "k": [0, 0]}, "o": {"a": 0, "k": 100}, "p": {"a": 0, "k": [0, 0]}, "r": {"a": 0, "k": 0},
                "s": {"a": 0, "k": [100, 100]}, "ty": "tr"}
    rects = []
    for li, layer in enumerate(j["layers"]):
        lw = "%s layer %s" % (where, layer.get("nm"))
        if layer.get("ty") != 4 or layer.get("ks") != ident or layer.get("ip") != 0 or layer.get("op") != n or layer.get("st") != 0:
            raise PortError("%s: not a plain shape layer with an identity transform over the whole composition" % lw)
        for gi, g in enumerate(layer["shapes"]):
            if g.get("ty") != "gr":
                raise PortError("%s: shape %d is not a group" % (lw, gi))
            fills = [it for it in g["it"] if it["ty"] == "fl"]
            trs = [it for it in g["it"] if it["ty"] == "tr"]
            shs = [it for it in g["it"] if it["ty"] == "sh"]
            if len(fills) != 1 or len(trs) != 1 or len(shs) + 2 != len(g["it"]) or trs[0] != ident_tr:
                raise PortError("%s group %d: expected paths, one fill and an identity transform" % (lw, gi))
            fl = fills[0]
            if fl["c"]["a"] != 0 or fl["o"]["a"] != 1:
                raise PortError("%s group %d: fill colour must be static and opacity keyed" % (lw, gi))
            rgb = _color(fl["c"]["k"], lw)
            keys = fl["o"]["k"]
            vis, cur, ki = [], None, 0
            if not keys or keys[0]["t"] != 0:
                raise PortError("%s group %d: opacity has no key at frame 0" % (lw, gi))
            for t in range(n):
                while ki < len(keys) and keys[ki]["t"] <= t:
                    k = keys[ki]
                    if k.get("h") != 1 or len(k["s"]) != 1 or k["s"][0] not in (0, 100):
                        raise PortError("%s group %d: opacity key %r is not a hold of 0 or 100" % (lw, gi, k))
                    cur = k["s"][0]
                    ki += 1
                vis.append(cur)
            for s in shs:
                p = s["ks"]
                if p["a"] != 0:
                    raise PortError("%s group %d: animated path" % (lw, gi))
                v = p["k"]
                if v["c"] is not True or len(v["v"]) != 4 or any(any(t) for t in v["i"]) or any(any(t) for t in v["o"]):
                    raise PortError("%s group %d: path is not a closed 4-vertex polygon without curves" % (lw, gi))
                xs = sorted({_int100(x, lw) for x, _ in v["v"]})
                ys = sorted({_int100(y, lw) for _, y in v["v"]})
                corners = {(_int100(x, lw), _int100(y, lw)) for x, y in v["v"]}
                if len(xs) != 2 or len(ys) != 2 or corners != {(a, b) for a in xs for b in ys}:
                    raise PortError("%s group %d: polygon is not an axis-aligned rectangle" % (lw, gi))
                rects.append(Rect(li, gi, layer["nm"], xs[0], ys[0], xs[1], ys[1], rgb, vis))
    return n, rects


def apply_omit(rects, omit):
    """Drop the rectangles a variant declares away: every rectangle of a layer, or of a layer lying entirely at or above maxY."""
    out = []
    for r in rects:
        drop = False
        for rule in omit:
            if r.layer == rule["layer"] and ("maxY" not in rule or r.y1 <= rule["maxY"] * 100):
                drop = True
        if not drop:
            out.append(r)
    return out


def color_map_for(rects, where):
    """The declared colour map: body-layer colours -> the pet body, eye-layer colours -> the pet eye (only where they differ)."""
    cmap = []
    for layer, target in (("orange", PET_BODY), ("black", PET_EYE)):
        colors = sorted({r.rgb for r in rects if r.layer == layer})
        for c in colors:
            if c != target:
                others = sorted({r.layer for r in rects if r.rgb == c} - {layer})
                if others:
                    raise PortError("%s: colour %r of layer %s also occurs in layers %s; refusing to map it" % (where, c, layer, others))
                cmap.append({"from": list(c), "to": list(target)})
    return cmap


def ceil_div(a, b):
    return -((-a) // b)


def lattice_phase(rects):
    """The integer phase (0..49) that puts the most rectangle edges within 2 px of the 50 px lattice; ties go to the phase nearest the
    left edge of the body layer."""
    xs = [v for r in rects for v in (r.x0, r.x1)]
    body_left = min(r.x0 for r in rects if r.layer == "orange")
    near = round(body_left / 100) % CELL

    def off(phase):
        return sum(1 for v in xs if min((v - phase * 100) % 5000, 5000 - (v - phase * 100) % 5000) > 200)

    return min(range(CELL), key=lambda ph: (off(ph), min((ph - near) % CELL, (near - ph) % CELL)))


def register_origin(n, rects, cmap, rest):
    """(X0, Y0): Y0 is fixed. X0 is the lattice point (spacing 50 px, the lattice phase above) that puts the first frame whose body layer
    reproduces the v1 rest pose into the pet canvas; for a file without any such frame (a side view throughout) it is the lattice
    point nearest the leftmost body edge over all frames."""
    phase = lattice_phase(rects)
    for f in range(n):
        left = [r.x0 for r in rects if r.layer == "orange" and r.vis[f] == 100]
        if not left:
            continue
        x0 = phase + CELL * round((min(left) / 100 - phase) / CELL)
        probe = Raster(n, rects, (x0, Y0), cmap, only=[f])
        if grid_cells(probe, f) == rest:
            return x0, Y0
    first = min(r.x0 for r in rects)
    return phase + CELL * round((first / 100 - phase) / CELL), Y0


def window_for(origin):
    """Cell index ranges (inclusive) whose centres lie inside the 2750 x 1850 source canvas."""
    x0, y0 = origin
    return (ceil_div(-(x0 + 25), CELL), (SOURCE_W - 1 - x0 - 25) // CELL, ceil_div(-(y0 + 25), CELL), (SOURCE_H - 1 - y0 - 25) // CELL)


def cell_span(lo100, hi100, origin_px, i_lo, i_hi):
    """Cells (clipped to [i_lo, i_hi]) whose centre lies in the half-open interval [lo100, hi100) of source px times 100."""
    base = (origin_px + 25) * 100
    a = max(i_lo, ceil_div(lo100 - base, CELL * 100))
    b = min(i_hi, ceil_div(hi100 - base, CELL * 100) - 1)
    return (a, b) if a <= b else None


class Raster:
    """All frames of one source rasterized over the whole source canvas, as grids indexed [j - jmin][i - imin] of None / (r,g,b,a)."""

    def __init__(self, nframes, rects, origin, cmap, only=None):
        self.n, self.origin = nframes, origin
        self.imin, self.imax, self.jmin, self.jmax = window_for(origin)
        self.w, self.h = self.imax - self.imin + 1, self.jmax - self.jmin + 1
        mapping = {tuple(e["from"]): tuple(e["to"]) for e in cmap}
        order = sorted(rects, key=lambda r: (r.li, r.gi))                 # top first
        spans = []
        for r in order:
            sx = cell_span(r.x0, r.x1, origin[0], self.imin, self.imax)
            sy = cell_span(r.y0, r.y1, origin[1], self.jmin, self.jmax)
            color = mapping.get(r.rgb, r.rgb) + (255,)
            spans.append((r, sx, sy, color))
        self.grids = [None] * nframes
        for f in (range(nframes) if only is None else only):
            g = [[None] * self.w for _ in range(self.h)]
            for r, sx, sy, color in reversed(spans):                       # paint bottom to top
                if r.vis[f] == 100 and sx and sy:
                    width = sx[1] - sx[0] + 1
                    fill = [color] * width
                    for j in range(sy[0] - self.jmin, sy[1] - self.jmin + 1):
                        g[j][sx[0] - self.imin:sx[1] - self.imin + 1] = fill
            self.grids[f] = g

    def cell(self, f, i, j):
        """Colour of canvas-relative cell (i, j) in source frame f (None outside the source canvas or when transparent)."""
        ii, jj = i - self.imin, j - self.jmin
        if 0 <= ii < self.w and 0 <= jj < self.h:
            return self.grids[f][jj][ii]
        return None


def rest_cells(art):
    """The v1 idle_0 pose at half-unit resolution: {(i, j): (r,g,b,a)} on the 24 x 24 canvas."""
    w, h, rows = read_png(os.path.join(art, "frames", "idle_0.png"))
    if (w, h) != (12, 12):
        raise PortError("idle_0.png is %dx%d, want 12x12" % (w, h))
    out = {}
    for y in range(12):
        for x in range(12):
            px = tuple(rows[y][x * 4:x * 4 + 4])
            if px[3]:
                for dy in (0, 1):
                    for dx in (0, 1):
                        out[(2 * x + dx, 2 * y + dy)] = px
    return out


def grid_cells(rast, f):
    """Non-transparent cells of source frame f as {(i, j): colour} in canvas-relative cell coordinates."""
    out = {}
    g = rast.grids[f]
    for jj, row in enumerate(g):
        for ii, c in enumerate(row):
            if c is not None:
                out[(ii + rast.imin, jj + rast.jmin)] = c
    return out


# ---- anatomy: head anchor, rest, overhead -------------------------------------------------------------------------------------
def face_blocks(grid, w, h, clawd_colors):
    """Top-left (column, row) of every 16 x 6 cell block (the head: 8 x 3 units) that is made only of Clawd's own colours and holds at
    two eye cells, all of them in its rows 1..4 (at rest the eyes are in rows 2 and 3). The torso below may be squashed, stretched or leaning."""
    mine = [[(c is not None and c[:3] in clawd_colors) for c in row] for row in grid]
    run = [[0] * (w + 1) for _ in range(h)]
    for j in range(h):
        for i in range(w - 1, -1, -1):
            run[j][i] = run[j][i + 1] + 1 if mine[j][i] else 0
    found = []
    for i in range(w - FACE_W + 1):
        streak = 0
        for j in range(h):
            streak = streak + 1 if run[j][i] >= FACE_W else 0
            if streak >= FACE_H:
                top = j - FACE_H + 1
                inner = sum(1 for jj in range(top + 1, top + 5) for ii in range(i, i + FACE_W)
                            if grid[jj][ii] is not None and grid[jj][ii][:3] == PET_EYE)
                edge = sum(1 for jj in (top, top + FACE_H - 1) for ii in range(i, i + FACE_W)
                           if grid[jj][ii] is not None and grid[jj][ii][:3] == PET_EYE)
                if inner >= 2 and edge == 0:
                    found.append((i, top))
    return found


def face_anchor(grid, w, h, clawd_colors):
    """Fallback for a frame whose torso is not the exact block (squashed, stretched, leaning): x is the cell edge in the middle of the
    eye cells that touch Clawd's body, y is the topmost Clawd cell in the two columns around x, reached without a gap from the eyes."""
    eyes = {(i, j) for j in range(h) for i in range(w) if grid[j][i] is not None and grid[j][i][:3] == PET_EYE}

    def mine(i, j):
        return 0 <= i < w and 0 <= j < h and grid[j][i] is not None and grid[j][i][:3] in clawd_colors - {PET_EYE}

    kept, seen = [], set()
    for start in sorted(eyes):
        if start in seen:
            continue
        comp, stack = [], [start]
        seen.add(start)
        while stack:
            i, j = stack.pop()
            comp.append((i, j))
            for n in ((i + 1, j), (i - 1, j), (i, j + 1), (i, j - 1)):
                if n in eyes and n not in seen:
                    seen.add(n)
                    stack.append(n)
        if any(mine(i + di, j + dj) for i, j in comp for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1))):
            kept.extend(comp)
    if len(kept) < 2:
        return None
    x = (min(i for i, _ in kept) + max(i for i, _ in kept) + 1) // 2
    j = min(j for _, j in kept)
    while mine(x - 1, j - 1) or mine(x, j - 1):
        j -= 1
    return x, j


def head_anchor(rast, f, clawd_colors):
    """(anchor, exact): anchor is (x, y) in canvas cells or None when the head is not front-facing; x is the cell edge at the middle of the
    head, y its top row. exact is True when the frame holds a head block (16 x 6 cells of Clawd's colours with the eyes inside): the
    topmost one gives x = the middle of its top row and y = its top row; two blocks in that top row are ambiguous (not exact).
    Otherwise the face fallback gives the anchor from the eyes."""
    grid, w, h = rast.grids[f], rast.w, rast.h
    blocks = face_blocks(grid, w, h, clawd_colors)
    if blocks:
        top = min(j for _, j in blocks)
        row = [i for i, j in blocks if j == top]
        if len(row) == 1:
            return (row[0] + rast.imin + FACE_W // 2, top + rast.jmin), True
    fa = face_anchor(grid, w, h, clawd_colors)
    return (None if fa is None else (fa[0] + rast.imin, fa[1] + rast.jmin)), False


def half_ms(count):
    """Per-frame durations of `count` frames at 12 fps in whole ms: frame k ends at round(1000 (k + 1) / 12), so the sum is exact."""
    t = lambda k: (k * 1000 + 6) // FPS
    return [t(k + 1) - t(k) for k in range(count)]


def fmt_units(cells):
    v = cells / 2
    return int(v) if v == int(v) else v


class Motion:
    """One catalog motion with its pixels: `frames` are the grids cropped to the stage window, one per catalog frame."""

    def __init__(self, mid, board, kind, uses):
        self.id, self.board, self.kind, self.declared_uses = mid, board, kind, list(uses)
        self.source = {}
        self.src_frames, self.frames, self.head = [], [], []
        self.stage = (0, 0, 0, 0)
        self.flags = {}
        self.overhead_clear = False
        self.weight = 1
        self.uses, self.dropped = [], []
        self.mirror_of = None
        self.rigid = False
        self.clawd_colors = set()
        self.nsrc = 0
        self.ms = None          # per-frame durations when they are not 12 fps (the persona GIF carries its own)
        self.phase = 1
        self.extra = {}         # catalog keys written after `source` (a redrawn item's `redraw`)

    @property
    def count(self):
        return len(self.src_frames)


def stage_of(cell_dicts):
    """Cells beyond the 24 x 24 canvas on each side over all frames: (left, right, up, down)."""
    left = right = up = down = 0
    for cells in cell_dicts:
        for (i, j) in cells:
            left, right = max(left, -i), max(right, i - (CANVAS - 1))
            up, down = max(up, -j), max(down, j - (CANVAS - 1))
    return left, right, up, down


def crop(cells, stage):
    left, right, up, down = stage
    w, h = CANVAS + left + right, CANVAS + up + down
    grid = [[None] * w for _ in range(h)]
    for (i, j), c in cells.items():
        grid[j + up][i + left] = c
    return grid


def build_ported(mid, board, stem, uses, srcdir, rest, omit=None):
    path = os.path.join(srcdir, stem + ".js")
    n, rects = parse_lottie(path)
    cmap = color_map_for(rects, stem)
    origin = register_origin(n, rects, cmap, rest)
    shown = apply_omit(rects, omit) if omit else rects
    rast = Raster(n, shown, origin, cmap)
    m = Motion(mid, board, "ported", uses)
    m.nsrc = n
    m.source = {"path": "sources/lottie/%s.js" % stem, "sha256": sha256_file(path), "origin": list(origin), "colorMap": cmap, "frames": n}
    if omit:
        m.source["omit"] = omit
    shade = {tuple(r.rgb) for r in shown if r.layer == "dark_orange"}
    mapping = {tuple(e["from"]): tuple(e["to"]) for e in cmap}
    m.clawd_colors = {PET_BODY, PET_EYE} | {mapping.get(c, c) for c in shade}
    cells = [grid_cells(rast, f) for f in range(n)]
    rest_start, rest_end = cells[0] == rest, cells[n - 1] == rest
    hold = stem in HOLD_STEMS
    close = rest_start and not rest_end and not hold
    m.src_frames = list(range(n)) + ([0] if close else [])
    m.flags = {"restStart": rest_start, "restEnd": rest_start if close else rest_end}
    if hold:
        m.flags["hold"] = True
    if close:
        m.flags["closeLoop"] = True
    if not rest_start and not rest_end and not hold:
        m.flags["offRest"] = True
    full = [cells[f] for f in m.src_frames]
    m.stage = stage_of(full)
    m.frames = [crop(c, m.stage) for c in full]
    heads = [head_anchor(rast, f, m.clawd_colors) for f in m.src_frames]
    m.head = [h for h, _ in heads]
    m.rigid = all(h is not None and exact for h, exact in heads)
    body_like = {PET_BODY} | {mapping.get(c, c) for c in shade}
    m.overhead_clear = all(h is not None and all(c[:3] in body_like for (i, j), c in cells[f].items() if j < h[1])
                           for f, h in zip(m.src_frames, m.head))
    m.weight = 0.5 if n / FPS > 8 else 1
    finish_uses(m)
    m.rast, m.cells = rast, cells
    return m


def finish_uses(m):
    """Scene uses are candidates: a motion that is not overhead-clear drops them, and SENT also needs at most 2.0 s."""
    total = sum(m.ms if m.ms else half_ms(m.count))
    for u in m.declared_uses:
        if u in SCENE_USES and not m.overhead_clear:
            m.dropped.append("%s:not-overhead-clear" % u)
        elif u == "sent" and total > SENT_MAX_MS:
            m.dropped.append("sent:longer-than-2.0s")
        else:
            m.uses.append(u)


def build_mirrored(base, mid, board, uses):
    m = Motion(mid, board, "procedural", uses)
    m.mirror_of = base.id
    m.source = dict(base.source)
    m.source["mirror"] = "horizontal"
    m.nsrc, m.src_frames, m.flags, m.weight = base.nsrc, list(base.src_frames), dict(base.flags), base.weight
    l, r, u, d = base.stage
    m.stage = (r, l, u, d)
    m.frames = [[row[::-1] for row in g] for g in base.frames]
    m.head = [None if h is None else (CANVAS - h[0], h[1]) for h in base.head]
    m.overhead_clear, m.rigid = base.overhead_clear, base.rigid
    finish_uses(m)
    return m


def build_all_motions(srcdir, art):
    rest = {p: c for p, c in rest_cells(art).items()}
    motions = []
    for mid, board, stem, uses in A_ITEMS:
        motions.append(build_ported(mid, board, stem, uses, srcdir, rest))
    by_id = {m.id: m for m in motions}
    mid, board, stem, uses, omit = A1_NOBUBBLE
    motions.insert(1, build_ported(mid, board, stem, uses, srcdir, rest, omit))
    base = by_id["A5-walking"]
    mid, board, _, uses = A5_MIRRORED
    motions.insert(motions.index(base) + 1, build_mirrored(base, mid, board, uses))
    return motions, rest


# ---- looks: costume layers cut out of the official frames ---------------------------------------------------------------------
V1_POSES = ["idle", "blink", "listen", "think", "hop", "sleep", "dangle"]
GLASS_COLORS = {(150, 198, 236, 255), (250, 252, 255, 255), (190, 218, 236, 12)}
HEADPHONE_BLUE = (26, 76, 127)
# look id -> cut definition (phase 1: the costume looks; the six phase 2 looks are built by scripts/port-phase2-art.py)
CUTS = {
    "sunglasses": {"motion": "A17-sunglasses", "frame": 39, "colors": [PET_EYE], "restBody": True},
    "headphones": {"motion": "A18-headphones", "frame": 21, "colors": [HEADPHONE_BLUE], "restBody": True},
}
LOOKS = [
    # id, board, classes, anchor, signature motions, phase
    ("plain", "B1+D3", ["plain"], None, [], 1),
    ("helmet", "D1", ["costume"], "head", [], 1),
    ("sunglasses", "D18", ["costume"], "head", [], 1),
    ("headphones", "D10", ["costume"], "head", ["A18-headphones"], 1),
]


def upscale(rows, w, h):
    """A decoded 1 px per unit PNG as a half-unit grid (each pixel becomes 2 x 2 cells) of None / (r, g, b, a)."""
    grid = [[None] * (2 * w) for _ in range(2 * h)]
    for y in range(h):
        for x in range(w):
            px = tuple(rows[y][x * 4:x * 4 + 4])
            if px[3]:
                for dy in (0, 1):
                    for dx in (0, 1):
                        grid[2 * y + dy][2 * x + dx] = px
    return grid


def v1_pose_grids(art):
    """{pose: [24 x 24 grid per frame]} for the v1 poses (helmet-* included), straight from the atlas."""
    atlas = json.load(open(os.path.join(art, "clawd-atlas.json"), encoding="utf-8"))
    out = {}
    for name, pose in atlas["poses"].items():
        out[name] = []
        for rel in pose["frames"]:
            w, h, rows = read_png(os.path.join(art, rel))
            if (w, h) != (12, 12):
                raise PortError("%s is %dx%d, want 12x12" % (rel, w, h))
            out[name].append(upscale(rows, w, h))
    return out


def grid_head(grid):
    """Exact head anchor (x, y) of a plain 24 x 24 grid (a v1 pose frame), or None."""
    blocks = face_blocks(grid, len(grid[0]), len(grid), {PET_BODY, PET_EYE})
    if not blocks:
        return None
    top = min(j for _, j in blocks)
    row = [i for i, j in blocks if j == top]
    return (row[0] + FACE_W // 2, top) if len(row) == 1 else None


def rest_grid(rest):
    grid = [[None] * CANVAS for _ in range(CANVAS)]
    for (i, j), c in rest.items():
        grid[j][i] = c
    return grid


def head_is_exact(m, f):
    return head_anchor(m.rast, f, m.clawd_colors)[1]


def compose(base, layer, at, behind):
    """Draw layer {(dx, dy): colour} with its origin at `at` onto a copy of the grid `base`; `behind` keeps opaque base cells on top."""
    out = [row[:] for row in base]
    for (dx, dy), c in layer.items():
        x, y = at[0] + dx, at[1] + dy
        if 0 <= y < len(out) and 0 <= x < len(out[0]) and not (behind and out[y][x] is not None and out[y][x][3] == 255):
            out[y][x] = c
    return out


def layer_bbox(cells):
    xs = [p[0] for p in cells]
    ys = [p[1] for p in cells]
    return min(xs), min(ys), max(xs), max(ys)


def layer_png_grid(cells):
    x0, y0, x1, y1 = layer_bbox(cells)
    grid = [[None] * (x1 - x0 + 1) for _ in range(y1 - y0 + 1)]
    for (x, y), c in cells.items():
        grid[y - y0][x - x0] = c
    return grid


def cut_layer(motions, cut, rest):
    """The prop pixels of one source frame as {(dx, dy): colour} relative to a head anchor, per the declared cut. A cut with `restBody`
    is taken from a frame where everything but the prop is the rest pose, so its anchor is the rest pose's head (the prop may cover
    the face block); any other cut needs the frame's own exact head block."""
    m = next(x for x in motions if x.id == cut["motion"])
    f = cut["frame"]
    colors = {tuple(c) for c in cut["colors"]}
    cells = m.cells[f]
    if cut["restBody"]:
        head = grid_head(rest_grid(rest))
    else:
        head = m.head[f]
        if head is None or not head_is_exact(m, f):
            raise PortError("%s frame %d has no exact head block to anchor the cut" % (m.id, f))
    prop = {p: c for p, c in cells.items() if c[:3] in colors and (not cut.get("aboveHead") or p[1] < head[1])}
    if not prop:
        raise PortError("%s frame %d: the cut %r selects nothing" % (m.id, f, cut))
    if cut["restBody"]:
        stray = [p for p in set(cells) | set(rest) if p not in prop and cells.get(p) != rest.get(p)]
        if stray:
            raise PortError("%s frame %d: %d cells outside the prop differ from the rest pose, e.g. %r" % (m.id, f, len(stray), stray[:3]))
    return {(x - head[0], y - head[1]): c for (x, y), c in prop.items()}


def build_looks(art, motions, rest):
    """Look entries and their layer grids. Returns (looks, files, layers) where files maps a path under art/ to PNG bytes and layers maps a
    look id to its layer as (z, {(dx, dy): colour}) relative to the head anchor."""
    poses = v1_pose_grids(art)
    pose_heads = {}
    for name in V1_POSES:
        pose_heads[name] = [grid_head(g) for g in poses[name]]
        if any(h is None for h in pose_heads[name]):
            raise PortError("v1 pose %s has a frame without an exact head block" % name)
    files, looks, layers = {}, [], {}
    for lid, board, classes, anchor, signature, phase in LOOKS:
        look = {"id": lid, "board": board, "class": classes, "weight": 1, "signature": signature, "anchor": anchor, "phase": phase}
        if lid == "plain":
            look["layers"] = []
            looks.append(look)
            continue
        if lid == "helmet":
            cut = {"source": "v1", "pose": "helmet-idle", "frame": 0, "colors": sorted(list(c) for c in GLASS_COLORS)}
            base_head = pose_heads["idle"][0]
            layer = {}
            for y, row in enumerate(poses["helmet-idle"][0]):
                for x, c in enumerate(row):
                    if c in GLASS_COLORS:
                        layer[(x - base_head[0], y - base_head[1])] = c
            z = "back"
        else:
            cut = dict(CUTS[lid])
            cut["colors"] = [list(c) for c in cut["colors"]]
            layer = cut_layer(motions, CUTS[lid], rest)
            z = "front"
        layers[lid] = (z, layer)
        x0, y0, x1, y1 = layer_bbox(layer)
        rel = "looks/%s/layer.png" % lid
        files[rel] = png_bytes(layer_png_grid(layer))
        entry = {"name": "dome" if lid == "helmet" else {"sunglasses": "lenses", "headphones": "headphones"}[lid],
                 "z": z, "png": rel, "offset": [x0, y0], "size": [x1 - x0 + 1, y1 - y0 + 1], "cut": cut}
        if anchor == "head":
            entry["restPoses"] = {name: [[h[0] + x0, h[1] + y0] for h in pose_heads[name]] for name in V1_POSES}
        else:
            entry["offsetFrom"] = "head of the cut frame (the arm anchor is defined with the phase 2 looks)"
        look["layers"] = [entry]
        if lid in ("sunglasses", "headphones", "helmet"):
            look["layerOnSignature"] = False
        looks.append(look)
        if lid == "helmet":
            for name, v1 in (("listen", "helmet-listen"), ("idle", "helmet-idle")):
                for i, base in enumerate(poses[name]):
                    got = compose(base, layer, (pose_heads[name][i][0], pose_heads[name][i][1]), True)
                    if got != poses[v1][i]:
                        raise PortError("the cut-out helmet on v1 %s frame %d does not reproduce %s" % (name, i, v1))
    return looks, files, layers


def load_module(name, file):
    import importlib.util
    sys.dont_write_bytecode = True
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), file)
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_phase2():
    """scripts/port-phase2-art.py: the six sticker looks, the detective's inspect motion and the four sticker moments."""
    return load_module("port_phase2_art", "port-phase2-art.py")


def load_phase3():
    """scripts/port-phase3-art.py: the three plushie looks and the plushie's happy face."""
    return load_module("port_phase3_art", "port-phase3-art.py")


def load_phase4():
    """scripts/port-phase4-art.py: Claude Code's motions C1-C13, the Ultra pose and the looks Ultra and winter."""
    return load_module("port_phase4_art", "port-phase4-art.py")


def load_bridges():
    """scripts/port-bridge-art.py: the in-between pictures (bridges) played just before or after a motion or pose."""
    return load_module("port_bridge_art", "port-bridge-art.py")


# ---- catalog ------------------------------------------------------------------------------------------------------------------
V1_KEYS = ["unit", "canvas", "palette", "scale4x_dir", "poses"]
SCHEMA_MARK = ',\n  "schema": 2,\n  "motions": '


def motion_entry(m):
    frames = ["motions/%s/%03d.png" % (m.id, i) for i in range(m.count)]
    left, right, up, down = m.stage
    e = {"id": m.id, "board": m.board, "kind": m.kind, "uses": m.uses}
    if m.dropped:
        e["usesDropped"] = m.dropped
    if m.mirror_of:
        e["mirrorOf"] = m.mirror_of
    e["source"] = m.source
    e.update(m.extra)
    e["frames"] = frames
    e["srcFrames"] = m.src_frames
    e["ms"] = list(m.ms) if m.ms else half_ms(m.count)
    e["stage"] = {"left": fmt_units(left), "right": fmt_units(right), "up": fmt_units(up), "down": fmt_units(down)}
    e["head"] = [None if h is None else list(h) for h in m.head]
    for key in ("restStart", "restEnd", "hold", "closeLoop", "offRest"):
        if key in m.flags:
            e[key] = m.flags[key]
    e["overheadClear"] = m.overhead_clear
    e["rigidHead"] = m.rigid
    e["weight"] = m.weight
    e["phase"] = m.phase
    e["compatibleLooks"] = m.compatible
    return e


def jscalar(v):
    return json.dumps(v)


def jdump(o, level=0):
    """JSON for the catalog: dicts one key per line, lists of scalars (or of short scalar lists) on wrapped lines."""
    pad, pad2 = "  " * level, "  " * (level + 1)
    if isinstance(o, dict):
        if not o:
            return "{}"
        return "{\n" + ",\n".join("%s%s: %s" % (pad2, jscalar(k), jdump(v, level + 1)) for k, v in o.items()) + "\n" + pad + "}"
    if isinstance(o, list):
        if not o:
            return "[]"
        flat = all(not isinstance(x, (dict, list)) or (isinstance(x, list) and all(not isinstance(y, (dict, list)) for y in x)) for x in o)
        if flat:
            items = [json.dumps(x, separators=(", ", ": ")) for x in o]
            lines, cur = [], ""
            for it in items:
                if cur and len(pad2) + len(cur) + len(it) + 2 > 118:
                    lines.append(cur)
                    cur = ""
                cur = (cur + ", " if cur else "") + it
            lines.append(cur)
            if len(lines) == 1 and len(pad2) + len(lines[0]) < 100:
                return "[" + lines[0] + "]"
            return "[\n" + ",\n".join(pad2 + ln for ln in lines) + "\n" + pad + "]"
        return "[\n" + ",\n".join(pad2 + jdump(x, level + 1) for x in o) + "\n" + pad + "]"
    return jscalar(o)


def atlas_text(art, motions, looks, bridges=()):
    """The v1 text of clawd-atlas.json untouched (the file is json.dumps(indent=2) of the v1 keys) with the schema 2 keys appended."""
    path = os.path.join(art, "clawd-atlas.json")
    text = open(path, encoding="utf-8").read()
    atlas = json.loads(text)
    v1 = {k: atlas[k] for k in V1_KEYS}
    canonical = json.dumps(v1, indent=2)
    if not (text == canonical or text.startswith(canonical[:-2] + SCHEMA_MARK)):
        raise PortError("clawd-atlas.json is not the canonical v1 text plus schema 2 keys; refusing to rewrite it")
    body = {"motions": [motion_entry(m) for m in motions], "looks": looks}
    text = canonical[:-2] + SCHEMA_MARK + jdump(body["motions"], 1) + ',\n  "looks": ' + jdump(body["looks"], 1)
    if bridges:
        text += ',\n  "bridges": ' + jdump(list(bridges), 1)
    return text + "\n}"


def write_outputs(art, motions, looks, files, bridges=()):
    written = set()
    for m in motions:
        for i, g in enumerate(m.frames):
            rel = "motions/%s/%03d.png" % (m.id, i)
            write_file(os.path.join(art, rel), png_bytes(g))
            written.add(rel)
    for rel, data in files.items():
        write_file(os.path.join(art, rel), data)
        written.add(rel)
    stale = []
    for top in ("motions", "looks", "bridges"):
        for dirpath, _, names in os.walk(os.path.join(art, top)):
            for n in names:
                rel = os.path.relpath(os.path.join(dirpath, n), art)
                if rel not in written and not n.startswith("."):
                    stale.append(rel)
    if stale:
        raise PortError("files under motions/ or looks/ that this run did not write (remove them by hand): %s" % ", ".join(sorted(stale)[:6]))
    write_file(os.path.join(art, "clawd-atlas.json"), atlas_text(art, motions, looks, bridges).encode("utf-8"))
    return len(written)


# ---- reports: resampling and the contact sheet --------------------------------------------------------------------------------
FONT = {  # 3 x 5 pixel glyphs
    "0": "111101101101111", "1": "010110010010111", "2": "111001111100111", "3": "111001111001111", "4": "101101111001001",
    "5": "111100111001111", "6": "111100111101111", "7": "111001001001001", "8": "111101111101111", "9": "111101111001111",
    "A": "010101111101101", "B": "110101110101110", "C": "011100100100011", "D": "110101101101110", "E": "111100110100111",
    "F": "111100110100100", "G": "011100101101011", "H": "101101111101101", "I": "111010010010111", "J": "001001001101010",
    "K": "101101110101101", "L": "100100100100111", "M": "101111111101101", "N": "110101101101101", "O": "010101101101010",
    "P": "110101110100100", "Q": "010101101110011", "R": "110101110101101", "S": "011100010001110", "T": "111010010010010",
    "U": "101101101101111", "V": "101101101101010", "W": "101101111111101", "X": "101101010101101", "Y": "101101010010010",
    "Z": "111001010100111", "-": "000000111000000", " ": "000000000000000",
}
SHEET_BG = (32, 34, 38, 255)
SHEET_FG = (214, 218, 226, 255)
SHEET_GUIDE = (74, 80, 92, 255)


def draw_text(sheet, x, y, text, scale=2, color=SHEET_FG):
    for ch in text.upper():
        glyph = FONT.get(ch, FONT[" "])
        for k, bit in enumerate(glyph):
            if bit == "1":
                gx, gy = k % 3, k // 3
                for dy in range(scale):
                    for dx in range(scale):
                        sheet[y + gy * scale + dy][x + gx * scale + dx] = color
        x += 4 * scale


def contact_sheet(motions, per_row=10, scale=2):
    tile_w, tile_h = 48 * scale + 8, 38 * scale + 8
    label_w = 118
    width, height = label_w + per_row * tile_w, len(motions) * tile_h + 8
    sheet = [[SHEET_BG] * width for _ in range(height)]
    for r, m in enumerate(motions):
        y0 = 4 + r * tile_h
        draw_text(sheet, 6, y0 + 4, m.id.split("-")[0], 2)
        draw_text(sheet, 6, y0 + 16, "-".join(m.id.split("-")[1:])[:22], 1)
        n = m.count
        picks = sorted({round(k * (n - 1) / (per_row - 1)) for k in range(per_row)}) if n > 1 else [0]
        left, right, up, down = m.stage
        for t, f in enumerate(picks):
            x0 = label_w + t * tile_w + 4
            # every tile outlines the 12 x 12 unit canvas at the same place: room for 6 units on the left and 7 above it
            base_x, base_y = x0 + 12 * scale, y0 + 14 * scale
            for k in range(CANVAS * scale + 1):
                sheet[base_y][base_x + k] = SHEET_GUIDE
                sheet[base_y + CANVAS * scale][base_x + k] = SHEET_GUIDE
                sheet[base_y + k][base_x] = SHEET_GUIDE
                sheet[base_y + k][base_x + CANVAS * scale] = SHEET_GUIDE
            grid = m.frames[f]
            for j, row in enumerate(grid):
                for i, c in enumerate(row):
                    px, py = base_x + (i - left) * scale, base_y + (j - up) * scale
                    if c is not None and 0 <= px <= width - scale and 0 <= py <= height - scale:
                        for dy in range(scale):
                            for dx in range(scale):
                                sheet[py + dy][px + dx] = c if len(c) == 4 else c + (255,)
        draw_text(sheet, label_w + 4, y0 + tile_h - 8, "%d FR" % n, 1)
    return png_bytes(sheet)


def exact_pixel(rects, f, x100, y100):
    for r in sorted(rects, key=lambda r: (r.li, r.gi)):
        if r.vis[f] == 100 and r.x0 <= x100 < r.x1 and r.y0 <= y100 < r.y1:
            return r.rgb + (255,)
    return None


def lost_rectangles(rects, origin):
    """The rectangles no cell centre falls into: the half-unit grid cannot show them."""
    imin, imax, jmin, jmax = window_for(origin)
    return [r for r in rects if not (cell_span(r.x0, r.x1, origin[0], imin, imax) and cell_span(r.y0, r.y1, origin[1], jmin, jmax))]


def lattice_stats(rects, origin):
    """How the rectangle corners (four per rectangle, as the spec counts vertices) sit on the 50 px lattice of the declared origin and on
    the best-fitting lattice (phases in quarter pixels, x and y fitted separately)."""
    verts = [(x, y) for r in rects for x in (r.x0, r.x1) for y in (r.y0, r.y1)]

    def dev(v, o):
        d = (v - round(o * 100)) % 5000
        return min(d, 5000 - d) / 100

    at_origin = sum(1 for x, y in verts if dev(x, origin[0]) > 2 or dev(y, origin[1]) > 2)

    def best_phase(vals):
        return min(((sum(1 for v in vals if dev(v, k / 4) > 2), k / 4) for k in range(200)), key=lambda t: (t[0], t[1]))

    bx, by = best_phase([x for x, _ in verts]), best_phase([y for _, y in verts])
    at_best = sum(1 for x, y in verts if dev(x, bx[1]) > 2 or dev(y, by[1]) > 2)
    worst = max(max(dev(x, origin[0]), dev(y, origin[1])) for x, y in verts)
    lost = lost_rectangles(rects, origin)
    thin = max((min(r.x1 - r.x0, r.y1 - r.y0) / 100 for r in lost), default=0)
    return {"vertices": len(verts), "offGridAtOrigin": at_origin, "bestFitPhase": [bx[1], by[1]], "offGridAtBestFit": at_best,
            "worstDeviationPx": round(worst, 2), "rectanglesLostToSampling": len(lost), "lostMaxThinSidePx": thin}


def frame_ambiguity(rects, origin, rast, f):
    """Cells whose area coverage is between 25 and 75 percent (the cell-centre rule decides them) and cells where the centre rule and an
    area-majority rule disagree, for source frame f."""
    cover = {}
    for r in rects:
        if r.vis[f] != 100:
            continue
        i0, i1 = (r.x0 - (origin[0] * 100)) // 5000, (r.x1 - 1 - (origin[0] * 100)) // 5000
        j0, j1 = (r.y0 - (origin[1] * 100)) // 5000, (r.y1 - 1 - (origin[1] * 100)) // 5000
        for j in range(j0, j1 + 1):
            oy = min(r.y1, (origin[1] + CELL * (j + 1)) * 100) - max(r.y0, (origin[1] + CELL * j) * 100)
            for i in range(i0, i1 + 1):
                ox = min(r.x1, (origin[0] + CELL * (i + 1)) * 100) - max(r.x0, (origin[0] + CELL * i) * 100)
                if ox > 0 and oy > 0:
                    cover[(i, j)] = cover.get((i, j), 0) + ox * oy / (5000 * 5000)
    ambiguous = sum(1 for v in cover.values() if 0.25 <= min(v, 1) <= 0.75)
    flips = 0
    for (i, j), v in cover.items():
        filled = rast.cell(f, i, j) is not None
        if filled != (min(v, 1) >= 0.5):
            flips += 1
    return ambiguous, flips


def resampling_report(art, srcdir, rest, motions, only):
    """JSON-able report for every source file (lattice fit) plus per-frame ambiguity for the `only` stems; and the review picture."""
    report = {"cellPx": CELL, "files": {}}
    pictures = []
    by_stem = {}
    for m in motions:
        if m.kind == "ported" and "omit" not in m.source:
            by_stem[os.path.basename(m.source["path"])[:-3]] = m
    for stem, m in sorted(by_stem.items()):
        n, rects = parse_lottie(os.path.join(srcdir, stem + ".js"))
        origin = tuple(m.source["origin"])
        entry = lattice_stats(rects, origin)
        entry["board"], entry["origin"] = m.board, list(origin)
        if stem in only:
            amb = [frame_ambiguity(rects, origin, m.rast, f) for f in range(n)]
            lost = lost_rectangles(rects, origin)
            lost_vis = [sum(1 for r in lost if r.vis[f] == 100) for f in range(n)]
            entry["frames"] = n
            entry["lostRectanglesVisiblePerFrame"] = {"max": max(lost_vis), "mean": round(sum(lost_vis) / n, 2)}
            entry["ambiguousCellsPerFrame"] = {"max": max(a for a, _ in amb), "mean": round(sum(a for a, _ in amb) / n, 2)}
            entry["centreVsMajorityFlipsPerFrame"] = {"max": max(b for _, b in amb), "mean": round(sum(b for _, b in amb) / n, 2),
                                                      "framesWithAnyFlip": sum(1 for _, b in amb if b)}
            worst = sorted(range(n), key=lambda f: (-amb[f][1], -amb[f][0], -lost_vis[f], f))[:3]
            entry["worstFrames"] = worst
            pictures.append((stem, m, rects, origin, worst))
        report["files"][stem] = entry
    return report, pictures


def resampling_picture(pictures):
    """Per listed file and worst frame: the exact rectangles (10 source px per pixel) next to the half-unit cells (5 px per cell)."""
    pw, ph = SOURCE_W // 10, SOURCE_H // 10
    gap = 12
    cols = len(pictures)
    rows = max(len(p[4]) for p in pictures)
    width, height = cols * (2 * pw + 3 * gap), rows * (ph + 14) + 8
    sheet = [[SHEET_BG] * width for _ in range(height)]
    for c, (stem, m, rects, origin, worst) in enumerate(pictures):
        for r, f in enumerate(worst):
            x0, y0 = gap + c * (2 * pw + 3 * gap), 4 + r * (ph + 14)
            draw_text(sheet, x0, y0, "%s FRAME %d  EXACT | CELLS" % (m.board, f), 1)
            y0 += 8
            for v in range(ph):
                for u in range(pw):
                    px = exact_pixel(rects, f, (u * 10 + 5) * 100, (v * 10 + 5) * 100)
                    sheet[y0 + v][x0 + u] = px if px else (46, 49, 56, 255)
            xo = x0 + pw + gap
            for v in range(ph):
                for u in range(pw):
                    sheet[y0 + v][xo + u] = (46, 49, 56, 255)
            for j, row in enumerate(m.rast.grids[f]):
                for i, col in enumerate(row):
                    if col is None:
                        continue
                    sx = (origin[0] + CELL * (i + m.rast.imin)) / 10
                    sy = (origin[1] + CELL * (j + m.rast.jmin)) / 10
                    for dy in range(5):
                        for dx in range(5):
                            yy, xx = int(round(sy)) + dy, int(round(sx)) + dx
                            if 0 <= yy < ph and 0 <= xx < pw:
                                sheet[y0 + yy][xo + xx] = col
    return png_bytes(sheet)


def main():
    try:
        sys.stdout.reconfigure(errors="backslashreplace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(description="Port the official claude.dev Clawd animations onto the pet grid (spec v2 section 3.1).")
    ap.add_argument("--art", default=os.path.join(ROOT, "art"))
    args = ap.parse_args()
    art = os.path.abspath(args.art)
    srcdir = os.path.join(art, "sources", "lottie")
    try:
        motions, rest = build_all_motions(srcdir, art)
        looks1, look_files, layers1 = build_looks(art, motions, rest)
        phase2 = load_phase2()
        new_motions, looks2, files2, reports2 = phase2.build(sys.modules[__name__], art, motions, rest, looks1)
        phase3 = load_phase3()
        new_motions3, looks3, files3, reports3 = phase3.build(sys.modules[__name__], phase2, art, motions, rest, layers1["sunglasses"][1])
        phase4 = load_phase4()
        new_motions4, looks4, files4, reports4 = phase4.build(sys.modules[__name__], phase2, art, motions, rest)
        motions = motions + new_motions + new_motions3 + new_motions4
        all_looks = [(l["id"], {"laydefs": [{"attach": "head", "z": layers1[l["id"]][0], "cells": layers1[l["id"]][1]}], "signature": l["signature"],
                                "raiseCells": 0, "phase": 1,
                                "layerOnSignature": l.get("layerOnSignature", True)})
                     for l in looks1 if l["id"] != "plain"] + list(looks2.items()) + list(looks3.items()) + list(looks4.items())
        shortfall = phase2.set_phase2_compat(sys.modules[__name__], motions, all_looks)
        looks = looks1 + [d["entry"] for d in looks2.values()] + [d["entry"] for d in looks3.values()] + [d["entry"] for d in looks4.values()]
        look_files.update(files2)
        look_files.update(files3)
        look_files.update(files4)
        bridges, bridge_files = load_bridges().build(sys.modules[__name__], art, motions)
        look_files.update(bridge_files)
        count = write_outputs(art, motions, looks, look_files, bridges)
        phase1 = [m for m in motions if m.phase == 1]
        report, pictures = resampling_report(art, srcdir, rest, phase1, DETAIL_STEMS)
        write_file(os.path.join(art, "reports", "resampling-report.json"), (jdump(report) + "\n").encode("utf-8"))
        write_file(os.path.join(art, "reports", "gif-sampling-report.json"), (jdump(reports2["gif"]) + "\n").encode("utf-8"))
        write_file(os.path.join(art, "reports", "plush-sunglasses-comparison.json"), (jdump(reports3["d18"]) + "\n").encode("utf-8"))
        write_file(os.path.join(art, "preview", "v2", "resampling-review.png"), resampling_picture(pictures))
        write_file(os.path.join(art, "preview", "v2", "contact-sheet-phase1.png"), contact_sheet(phase1))
    except (PortError, OSError, ValueError, KeyError) as e:
        sys.stderr.write("port-official-art: %s\n" % e)
        return 1
    frames = sum(m.count for m in motions)
    print("ported %d motions (%d frames), %d looks, %d files written" % (len(motions), frames, len(looks), count))
    for m in motions:
        print("  %-22s %3d frames  stage L%s R%s U%s  head %d/%d  rigid=%s  uses=%s" % (
            m.id, m.count, fmt_units(m.stage[0]), fmt_units(m.stage[1]), fmt_units(m.stage[2]),
            sum(1 for h in m.head if h is not None), m.count, m.rigid, ",".join(m.uses)))
    print("compatible idle motions per look (K1): %s" % ", ".join("%s %d" % (lid, look["idleCount"]) for lid, look in all_looks))
    for line in shortfall:
        sys.stderr.write("port-official-art: K1 floor not met: %s\n" % line)
    return 1 if shortfall else 0


if __name__ == "__main__":
    sys.exit(main())
