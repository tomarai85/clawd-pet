#!/usr/bin/env python3
"""Phase 2 art of the pet (spec v2 sections 3.1-3.4, 9b items 2 and 6, Sprint 5): the six sticker looks, the detective's inspect motion,
the four sticker moments and the calm idle motions of the B vocabulary. This is a module of scripts/port-official-art.py (which loads it
by path and calls `build`); it is not run on its own.

Sources (all copied into art/sources/, none fetched; their sha256 goes into the catalog):
  sources/dev/3o01xgcny9qbw.js          the claude.dev page chunk with the 8 pixel sprites (read as text, no JS is run):
                                        sprite 6 = the pool float (39 x 31 cells, 44 frames), sprite 1 = the skateboard (28 x 29, 73 frames)
  sources/persona/Clawd-Magnifier.gif   the official persona GIF: 113 frames of 80 / 90 ms, crisp pixel art at a non-integer scale
  sources/sticker/{happy,dizzy,heart,lightbulb,shiny}.png   the official stickers: the reference of the redraws, the source of shiny's colours
  sources/claude-code/render-core.js    the pose vocabulary of Claude Code (line 3 verbatim from the binary, lines 139-152 its pixel parameters)

Production route of each item (the brief's "fastest first"):
  ported by script    D12 inspect (the whole GIF, sampled at cell centres) and its hat and magnifier (cut from GIF frame 22), the skateboard
                      (board cut from sprite 1 frame 18), the pool float (ring and sunglasses cut from sprite 6 frame 0, the ring cells the
                      sprite's own Clawd hid are filled by a declared rule), D14 ride (sprite 1 frames 23-61, the skateboard's glide)
  official pixels     coffee (the mug of A19) and wand (the wand and its sparks of A25), cut like Sprint 1 cut the sunglasses and headphones
  redrawn             D4 happy, D5 dizzy, D6 heart, D11 lightbulb (pixels drawn on the pet grid, sticker as the reference), D7 shiny (Clawd's
                      own colours unchanged, the sticker's pastel rainbow border as an outline behind the rest silhouette, static sparkles around
                      the body in the sticker's highlight pastels) and the calm idle motions B3 glances, B4 wink and slow blink, B5 foot tap
                      (render-core.js: eyes shifted one unit, closed eyes, wink, one foot up)

K1 for the look classes (this module and the independent checker compute the same rules from the shipped pixels):
  every look   an exact head block in every frame (phase 1's rule, all that a phase 1 costume look needs)
  phase 2 looks (and every look against a phase 2 moment)   a layer drawn in front of the frame never lies on an effect pixel of the motion
                (an effect pixel is any pixel that is not Clawd's own colour, or is Clawd's colour outside the body box: the 24 x 16 cells
                from the torso top to the feet plus one unit on every side; so a prop, a heart, a bulb, a raised arm), and when the motion's point is its eyes (its
                redraw declares `eyes:*`: the D4 chevrons, the D5 swirls, the B3 glances, the B4 wink and slow blink) a front layer never lies on an eye pixel of any frame
  held (mug, wand, magnifier)   also: in every frame at least 4 of the 16 cells of the right arm's rest place are Clawd's own, and every
                arm cell the prop layer lies on or touches (its hand cells) is Clawd's own: the prop never floats off the arm
  under-feet (board)   also: in every frame the eight leg cells of the last row are Clawd's own (Clawd stands on the board)
  hugging border (shiny)  a layer that hugs the rest silhouette is drawn behind the body and shows only outside it, so the whole body must move
                rigidly with the torso: in every frame the cells of Clawd's own colours, moved by the head's offset from the rest head, are exactly
                the rest silhouette (an arm or a foot that moves, a squash or a stretch, refuses the pair); the sparkles are a front layer
                under the effect rule above
  A motion that is the look's own signature draws the prop itself and needs none of these.

Tier 1 (a layered look on a motion that has no exact head block in some frame; a motion with one in every frame keeps the rules above unchanged).
The pair is compatible when it is not in T1_DROPPED (a pair whose GIF review found that it clips or floats, with the verdict and frame numbers) and:
  anchor        every frame has a catalog head (an exact block or the face fallback), and from each frame to the next (no wrap from the last frame to the
                first) the anchor follows the head: two exact blocks pass; otherwise the step of the anchor is within one cell, in x and in y, of the step of
                the eye centre (the mean of the eye pixels in the 4-connected eye components that 4-touch Clawd's body colour), and a frame without an
                eye centre fails
  overhead      in every frame, no overhead cell (a cell above the frame's anchor row whose colour is not one of the motion's body colours) lies on, or
                next to (the 8 neighbours), a cell of any layer of the look, back or front, at any attach, placed at that frame's anchor with the look's lift
  front layers  at every phase: no front layer lies on an effect cell of the motion, nor, when the motion's point is its eyes, on an eye cell
  carried over  the hugging, held-arm, feet and composite baseline rules, per frame at the frame's own anchor
"""
import hashlib
import math
import os
import re
import struct
from collections import deque

CANVAS = 24
HEAD = (12, 8)                      # head anchor of the v1 rest pose: the middle of the torso's top row, in canvas cells
RAISE = 6                           # cells Clawd is lifted by the skateboard
POOL_RAISE = 7                      # and by the pool float: the ring's lower edge lies one cell above the baseline, the one cell of room the composite baseline rule (K1) leaves
                                    # a head that dips (a squash of one cell); at 6 the ring hung below the baseline in nine of its twelve idle motions, 3 left (< 6)
SHADE = (190, 104, 77)
SHADE_B = (191, 105, 77)
DEV_CHUNK = "sources/dev/3o01xgcny9qbw.js"
GIF_PATH = "sources/persona/Clawd-Magnifier.gif"
# The catalog names a reference picture without its `.png` suffix (`picture` plus `ext`): bin/clawd-pet installs every quoted ".png" string
# of the atlas, and a sticker is a reference of the redraw, not art the pet draws.
STICKERS = {"D4": "sources/sticker/happy.png", "D5": "sources/sticker/dizzy.png", "D6": "sources/sticker/heart.png",
            "D7": "sources/sticker/shiny.png", "D11": "sources/sticker/lightbulb.png"}
POSE_SOURCE = "sources/claude-code/render-core.js"      # the B items' source: Claude Code's pose vocabulary (spec 3.2: render-core.js:3 and :139-152, with the pixel rules of :107-125 they feed)
POSE_LINES = ["3", "107-125", "139-152"]
POOL_SPRITE = {"index": 6, "w": 39, "h": 31, "frames": 44}
SKATE_SPRITE = {"index": 1, "w": 28, "h": 29, "frames": 73}
# D14 ride (amendment "the skateboard ride", R2-1 .. R4-3): sprite 1 frames 23-61 as one motion that the skateboard look plays while it glides.
# The look's board layer is cut from frame 18 and the compositor lifts every clip of the look by RAISE cells, so a sprite cell (x, y) is stored at
# (x, y + 1): composed it lies at (x, y - 5), where the rest picture (frame 18) has it. Stored this way the frames reach 3 units below the canvas
# (sprite row 28); that is storage only, the composed frames lie inside the canvas plus 0.5 unit to the right and 2.5 units above it.
RIDE_ID = "D14-ride"
RIDE_REST_FRAME = 18
RIDE_FRAMES = (23, 61)
RIDE_STORE = (0, RAISE - 5)             # added to a sprite cell: the rest placement is y - 5 and the compositor subtracts RAISE again, so the stored y is y - 5 + RAISE
RIDE_BOARD_EDIT = (23, 61)              # R2-1: the board cells of these frames are frame 18's board cells (the first and last frame meet the rest picture)
RIDE_SEGMENTS = [("start", 23, 30), ("cruiseA", 31, 38), ("trick", 39, 44), ("cruiseB", 45, 55), ("push", 56, 58), ("stop", 59, 61)]
GIF_GRID = {"x0": 318, "y0": 281, "cellNum": 173, "cellDen": 8}   # one cell is 173/8 px; the canvas' first cell starts at pixel (318, 281)
GIF_MAP = [{"from": [217, 119, 87], "to": [215, 119, 87]}, {"from": [0, 0, 0], "to": [20, 20, 19]}]
POOL_MAP = [{"from": [216, 118, 86], "to": [215, 119, 87]}, {"from": [0, 0, 0], "to": [20, 20, 19]}]
SKATE_MAP = [{"from": [217, 119, 87], "to": [215, 119, 87]}]
RING = [[249, 248, 244], [193, 217, 239], [105, 154, 203], [71, 108, 145]]
BOARD = [[86, 27, 47], [239, 172, 84]]
HEART = (233, 69, 68)               # the official heart red (A12)
BULB = {"a": (239, 177, 84), "c": (244, 219, 153), "w": (250, 247, 229), "g": (134, 134, 126), "h": (193, 192, 181)}
# Two things are sampled from the sticker (art/sources/sticker/shiny.png) by rules the checker recomputes from the picture alone.
# 1. The sparkles' three highlight pastels, by a histogram rule: a pastel pixel is opaque, has every channel >= 170 and a spread (max - min) >= 24;
#    pastel pixels are counted per 16-level colour bucket; the dominant bucket and the most frequent bucket darker than it (luma 299 r + 587 g +
#    114 b) are set aside, and the highlights are the next three buckets by frequency that are at least 40 apart (sum of channel differences of the
#    bucket centres) from those two and from each other. A bucket's colour is its most frequent exact colour (smallest on a tie); its source pixel is
#    the first pixel of that colour in raster order. All three occur in the die-cut border band (checked).
PASTEL_MIN, PASTEL_SPREAD, PASTEL_APART, PASTEL_HIGHLIGHTS = 170, 24, 40, 3
# 2. The border's pastels, in the order they run round the sticker's outline. The outside of the sticker is the set of pixels that are not fully
#    opaque and connect (4-neighbour) to the picture's edge through such pixels; the sticker's body is the rest. From the centroid of the body, a
#    ray at the centre angle of each of BORDER_SECTORS equal sectors (clockwise from up, angle (k + 0.5) 360 / n) is walked in steps of half a pixel,
#    the pixel of a step being (round(cx + r sin a), round(cy - r cos a)), until it reaches the outside; the border colour of the sector is the pixel
#    BORDER_DEPTH pixels back along the ray (the middle of the die-cut band, which is about 18 pixels wide) and that pixel is its source pixel.
BORDER_SECTORS, BORDER_DEPTH, BORDER_BAND = 24, 9.0, 19
# On the pet the outline is BORDER_CELLS cell thick (the sticker's band measures about 0.67 cell, so one cell is the nearest it can be, and the
# 4-cell notch between the middle legs stays 2 cells open) around the rest silhouette: the cells outside it that lie within the 3 x 3 square of
# some silhouette cell, without that square's four corners (a rounded die-cut corner). Each cell takes the colour of the sector its centre lies
# in, the angle taken clockwise from up about the middle of the rest body (a cell edge: head-relative x 0, y 8).
BORDER_CELLS = 1
BORDER_REACH = [(dx, dy) for dx in range(-BORDER_CELLS, BORDER_CELLS + 1) for dy in range(-BORDER_CELLS, BORDER_CELLS + 1)
                if not (abs(dx) == BORDER_CELLS and abs(dy) == BORDER_CELLS)]
BORDER_CENTRE = (0.0, 8.0)
SHINY_RAISE = BORDER_CELLS          # the outline's lower edge lies on the baseline: Clawd is lifted by its thickness
# The static sparkles: stars drawn on the cell grid around the head, relative to the head anchor (top-left cell of each star), the letters
# naming the three highlight colours in the order the rule above picks them. They lie outside the body box in every pose.
SPARKLES = [{"at": [-12, -7], "rows": ["..c..", "..a..", "cabac", "..a..", "..c.."]},
            {"at": [8, -7], "rows": [".a.", "aca", ".a."]},
            {"at": [-3, -8], "rows": ["b"]}, {"at": [3, -7], "rows": ["c"]}, {"at": [-6, -4], "rows": ["a"]}, {"at": [11, -3], "rows": ["b"]}]
BODY_BOX = (-14, 13, -2, 17)        # x0, x1, y0, y1 relative to the head anchor: the rest body (24 x 16 cells, torso top to feet) plus one unit on every side,
                                    # which holds the squash and stretch of the official motions (at most 2 cells) and not a raised arm (D11: 5 cells)
P_EYE = (20, 20, 19)
OWN = {(215, 119, 87), P_EYE, SHADE, SHADE_B}
LEG_CELLS = [(i, 23) for i in (4, 5, 8, 9, 14, 15, 18, 19)]


class Phase2Error(Exception):
    pass


# ---- the GIF ------------------------------------------------------------------------------------------------------------------
def lzw(data, min_code, npix):
    clear, eoi = 1 << min_code, (1 << min_code) + 1
    size, nxt = min_code + 1, eoi + 1
    table = {i: bytes([i]) for i in range(clear)}
    out, bits, nbits, prev, pos = bytearray(), 0, 0, None, 0
    while len(out) < npix:
        while nbits < size:
            if pos >= len(data):
                return bytes(out)
            bits |= data[pos] << nbits
            pos += 1
            nbits += 8
        code = bits & ((1 << size) - 1)
        bits >>= size
        nbits -= size
        if code == clear:
            size, nxt, table, prev = min_code + 1, eoi + 1, {i: bytes([i]) for i in range(clear)}, None
            continue
        if code == eoi:
            break
        if prev is None:
            entry = table[code]
        else:
            if code in table:
                entry = table[code]
            elif code == nxt:
                entry = prev + prev[:1]
            else:
                raise Phase2Error("bad LZW code")
            if nxt < 4096:
                table[nxt] = prev + entry[:1]
                nxt += 1
                if nxt == (1 << size) and size < 12:
                    size += 1
        out += entry
        prev = entry
    return bytes(out)


def decode_gif(path):
    """(width, height, frames, delays in ms): each frame is the logical screen after drawing it, as rows of RGBA tuples (alpha 0 or 255)."""
    d = open(path, "rb").read()
    if d[:6] not in (b"GIF89a", b"GIF87a"):
        raise Phase2Error("%s: not a GIF" % path)
    w, h, flags = struct.unpack("<HHB", d[6:11])
    pos = 13
    gct = None
    if flags & 0x80:
        n = 2 << (flags & 7)
        gct = [tuple(d[pos + 3 * i:pos + 3 * i + 3]) for i in range(n)]
        pos += 3 * n
    clear_px = (0, 0, 0, 0)
    canvas = [[clear_px] * w for _ in range(h)]
    frames, delays, gce = [], [], None
    prev_disposal, prev_rect, saved = 0, None, None
    while pos < len(d):
        b = d[pos]
        pos += 1
        if b == 0x3B:
            break
        if b == 0x21:
            label = d[pos]
            pos += 1
            if label == 0xF9:
                fl, delay, tidx = struct.unpack("<BHB", d[pos + 1:pos + 5])
                gce = {"disposal": (fl >> 2) & 7, "transparent": tidx if fl & 1 else None, "delay": delay}
            while True:
                ln = d[pos]
                pos += 1
                if ln == 0:
                    break
                pos += ln
            continue
        if b != 0x2C:
            raise Phase2Error("%s: unexpected block %02x" % (path, b))
        x, y, iw, ih, fl = struct.unpack("<HHHHB", d[pos:pos + 9])
        pos += 9
        ct = gct
        if fl & 0x80:
            n = 2 << (fl & 7)
            ct = [tuple(d[pos + 3 * i:pos + 3 * i + 3]) for i in range(n)]
            pos += 3 * n
        mc = d[pos]
        pos += 1
        chunks = bytearray()
        while True:
            ln = d[pos]
            pos += 1
            if ln == 0:
                break
            chunks += d[pos:pos + ln]
            pos += ln
        idx = lzw(bytes(chunks), mc, iw * ih)
        if len(idx) < iw * ih:
            raise Phase2Error("%s: short image data" % path)
        if prev_disposal == 2 and prev_rect:
            px, py, pw, ph = prev_rect
            for yy in range(py, py + ph):
                canvas[yy][px:px + pw] = [clear_px] * pw
        elif prev_disposal == 3 and saved is not None:
            canvas = [row[:] for row in saved]
        g = gce or {"disposal": 0, "transparent": None, "delay": 0}
        if g["disposal"] == 3:
            saved = [row[:] for row in canvas]
        rows = list(range(ih))
        if fl & 0x40:
            rows = list(range(0, ih, 8)) + list(range(4, ih, 8)) + list(range(2, ih, 4)) + list(range(1, ih, 2))
        for k, yy in enumerate(rows):
            line = canvas[y + yy]
            for xx in range(iw):
                v = idx[k * iw + xx]
                if g["transparent"] is not None and v == g["transparent"]:
                    continue
                c = ct[v]
                line[x + xx] = (c[0], c[1], c[2], 255)
        frames.append([row[:] for row in canvas])
        delays.append(g["delay"] * 10)
        prev_disposal, prev_rect, gce = g["disposal"], (x, y, iw, ih), None
    return w, h, frames, delays


def gif_pixel(grid, i, j):
    """The pixel (x, y) at the centre of cell (i, j): x0 + floor((2 i + 1) cellNum / (2 cellDen))."""
    num, den = grid["cellNum"], grid["cellDen"]
    return grid["x0"] + ((2 * i + 1) * num) // (2 * den), grid["y0"] + ((2 * j + 1) * num) // (2 * den)


def gif_cells(frame, w, h, grid, cmap, imin=-12, imax=48, jmin=-12, jmax=36):
    """{(i, j): (r, g, b, 255)} of one decoded frame: the pixel at each cell's centre, after the colour map."""
    mapping = {tuple(e["from"]): tuple(e["to"]) for e in cmap}
    out = {}
    for j in range(jmin, jmax + 1):
        for i in range(imin, imax + 1):
            px, py = gif_pixel(grid, i, j)
            if 0 <= px < w and 0 <= py < h:
                c = frame[py][px]
                if c[3]:
                    out[(i, j)] = mapping.get(c[:3], c[:3]) + (255,)
    return out


def gif_impure(frame, w, h, grid, cells):
    """How many of the cells have a different pixel in the 3 x 3 block around their centre (resampling or anti-aliasing would show here)."""
    bad = 0
    for (i, j) in cells:
        px, py = gif_pixel(grid, i, j)
        ref = frame[py][px]
        if any(frame[py + dy][px + dx] != ref for dy in (-1, 0, 1) for dx in (-1, 0, 1) if 0 <= py + dy < h and 0 <= px + dx < w):
            bad += 1
    return bad


# ---- the claude.dev sprites ---------------------------------------------------------------------------------------------------
SPRITE_RE = re.compile(r'n\(\{w:(\d+),h:(\d+),fps:(\d+),palette:\[([^\]]*)\],base:"([.0-9]*)",deltas:\[(.*?)\]\}\)', re.S)


def parse_sprites(path):
    """The sprites of the chunk as [{w, h, fps, palette, frames}], parsed as text: a base picture of w x h palette indices ('.' = empty)
    and one delta string per following frame, whose tokens are `<base36 cell index><palette index or .>`."""
    src = open(path, encoding="utf-8").read()
    sprites = []
    for m in SPRITE_RE.finditer(src):
        w, h, fps = int(m.group(1)), int(m.group(2)), int(m.group(3))
        pal = [tuple(int(c[k:k + 2], 16) for k in (1, 3, 5)) for c in re.findall(r'"(#[0-9a-fA-F]{6})"', m.group(4))]
        base = m.group(5)
        if len(base) != w * h:
            raise Phase2Error("%s: a sprite base is %d cells, want %d" % (path, len(base), w * h))
        cur = [255 if ch == "." else int(ch) for ch in base]
        frames = [cur[:]]
        for delta in re.findall(r'"([^"]*)"', m.group(6)):
            if delta:
                for tok in delta.split(","):
                    cur[int(tok[:-1], 36)] = 255 if tok[-1] == "." else int(tok[-1])
            frames.append(cur[:])
        sprites.append({"w": w, "h": h, "fps": fps, "palette": pal, "frames": frames})
    return sprites


def sprite_cells(sprite, f, cmap):
    """{(x, y): (r, g, b, 255)} of one sprite frame in sprite coordinates, after the colour map."""
    mapping = {tuple(e["from"]): tuple(e["to"]) for e in cmap}
    w, h, pal = sprite["w"], sprite["h"], sprite["palette"]
    out = {}
    for y in range(h):
        for x in range(w):
            v = sprite["frames"][f][y * w + x]
            if v != 255:
                c = pal[v]
                out[(x, y)] = mapping.get(c, c) + (255,)
    return out


def largest_component(cells):
    """The largest 8-connected group of a set of cells (a tie goes to the group that holds the smallest cell)."""
    left, best = set(cells), []
    for start in sorted(cells):
        if start not in left:
            continue
        stack, group = [start], []
        left.discard(start)
        while stack:
            p = stack.pop()
            group.append(p)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    q = (p[0] + dx, p[1] + dy)
                    if q in left:
                        left.discard(q)
                        stack.append(q)
        if len(group) > len(best):
            best = group
    return set(best)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def head_of_cells(P, cells, colors):
    """(anchor or None, exact) of one frame given as a canvas-cell dict, by the same rule as the port's head_anchor."""
    if not cells:
        return None, False
    i0, i1 = min(p[0] for p in cells), max(p[0] for p in cells)
    j0, j1 = min(p[1] for p in cells), max(p[1] for p in cells)
    w, h = i1 - i0 + 1, j1 - j0 + 1
    grid = [[None] * w for _ in range(h)]
    for (i, j), c in cells.items():
        grid[j - j0][i - i0] = c
    blocks = P.face_blocks(grid, w, h, colors)
    if blocks:
        top = min(j for _, j in blocks)
        row = [i for i, j in blocks if j == top]
        if len(row) == 1:
            return (row[0] + i0 + P.FACE_W // 2, top + j0), True
    fa = P.face_anchor(grid, w, h, colors)
    return (None if fa is None else (fa[0] + i0, fa[1] + j0)), False


def frame_cell_dicts(m):
    """The catalog frames of a motion as canvas-cell dicts (the stage-cropped grids put back on the canvas)."""
    left, _, up, _ = m.stage
    out = []
    for g in m.frames:
        d = {}
        for y, row in enumerate(g):
            for x, c in enumerate(row):
                if c is not None:
                    d[(x - left, y - up)] = c if len(c) == 4 else tuple(c) + (255,)
        out.append(d)
    return out


# ---- D12: the whole persona GIF -----------------------------------------------------------------------------------------------
def build_gif_motion(P, art, rest, gif):
    w, h, frames, delays = gif
    if len(frames) != 113 or sorted(set(delays)) != [80, 90]:
        raise Phase2Error("%s: expected 113 frames of 80 and 90 ms, got %d frames and delays %s" % (GIF_PATH, len(frames), sorted(set(delays))))
    body = [(x, y) for y in range(h) for x in range(w) if frames[0][y][x] == (217, 119, 87, 255)]
    left, top, right = min(x for x, _ in body), min(y for _, y in body), max(x for x, _ in body)
    if (left, right - left + 1, top) != (GIF_GRID["x0"], 519, GIF_GRID["y0"] + 8 * GIF_GRID["cellNum"] // GIF_GRID["cellDen"]):
        raise Phase2Error("%s: the rest body of frame 0 is not on the declared grid (left %d, width %d, top %d)" % (GIF_PATH, left, right - left + 1, top))
    cells = [gif_cells(fr, w, h, GIF_GRID, GIF_MAP) for fr in frames]
    impure = sum(gif_impure(fr, w, h, GIF_GRID, cells[k]) for k, fr in enumerate(frames))
    if cells[0] != rest or cells[-1] != rest:
        raise Phase2Error("D12 inspect: the GIF does not start and end on the rest pose")
    m = P.Motion("D12-inspect", "D12", "ported", ["idle", "signature:detective"])
    m.nsrc = len(frames)
    m.source = {"path": GIF_PATH, "sha256": sha256_file(os.path.join(art, GIF_PATH)), "format": "gif", "grid": dict(GIF_GRID),
                "colorMap": [dict(e) for e in GIF_MAP], "frames": len(frames), "delaysMs": delays}
    m.clawd_colors = {P.PET_BODY, P.PET_EYE, SHADE_B}
    m.src_frames = list(range(len(frames)))
    m.flags = {"restStart": True, "restEnd": True}
    m.stage = P.stage_of(cells)
    m.frames = [P.crop(c, m.stage) for c in cells]
    heads = [head_of_cells(P, c, m.clawd_colors) for c in cells]
    m.head = [hd for hd, _ in heads]
    m.rigid = all(hd is not None and ex for hd, ex in heads)
    body_like = {P.PET_BODY, SHADE_B}
    m.overhead_clear = all(hd is not None and all(c[:3] in body_like for (i, j), c in cells[k].items() if j < hd[1]) for k, (hd, _) in enumerate(heads))
    m.ms = list(delays)
    m.weight = 0.5 if sum(delays) > 8000 else 1
    m.phase = 2
    P.finish_uses(m)
    m.report = {"frames": len(frames), "sizePx": [w, h], "impureCells": impure}
    return m, cells


# ---- the redrawn moments ------------------------------------------------------------------------------------------------------
def ink(pattern, x0, y0, color):
    return {(x0 + c, y0 + r): color for r, row in enumerate(pattern) for c, ch in enumerate(row) if ch != "."}


def palette_ink(pattern, x0, y0, palette):
    return {(x0 + c, y0 + r): palette[ch] + (255,) for r, row in enumerate(pattern) for c, ch in enumerate(row) if ch != "."}


def mirror_x(pattern):
    return [row[::-1] for row in pattern]


def plain_body(P, rest):
    """The rest pose with its eyes painted over by body colour: the base of every frame that draws its own eyes."""
    return {p: ((P.PET_BODY + (255,)) if c[:3] == P.PET_EYE else c) for p, c in rest.items()}


# The eyes are glyphs on the head block's rows 1..4 (canvas rows 9..12); the right eye is the left one mirrored about the cell edge x = 12.
CHEVRON = ["KK..", "..KK", "KK.."]                 # `>` at columns 5..8, rows 10..12; the right eye's `<` is its mirror
SWIRL_A = ["KKKK", "K..K", "K.KK", "KKK."]         # a square spiral at columns 5..8, rows 9..12; the right eye's is mirrored
SWIRL_B = ["KKKK", "K...", "K.K.", "KKKK"]         # the same spiral a quarter turn on
HEART_PATTERN = [".XX..XX.", "XXXXXXXX", "XXXXXXXX", "XXXXXXXX", ".XXXXXX.", "..XXXX..", "...XX..."]
BULB_ON = ["..aaaaa..", ".accccca.", "acccwccca", "acacccaca", "accccccca", ".accccca.", "..accca..", "...hhh...", "...ggg...", "....h...."]
BULB_OFF = ["".join("." if ch in "cw" else ch for ch in row) for row in BULB_ON]


def eyes(P, rest, left_pattern, right_pattern, x_left, x_right, y):
    c = plain_body(P, rest)
    c.update(ink(left_pattern, x_left, y, P.PET_EYE + (255,)))
    c.update(ink(right_pattern, x_right, y, P.PET_EYE + (255,)))
    return c


def raise_arm(cells, left, rows):
    """An arm (4 x 4 cells at the rest place: cells 0..3 for the left, 20..23 for the right, rows 12..15) lifted by `rows` cells."""
    lo, hi = (0, 3) if left else (20, 23)
    out = {p: c for p, c in cells.items() if not (lo <= p[0] <= hi and 12 <= p[1] <= 15)}
    for (i, j), c in cells.items():
        if lo <= i <= hi and 12 <= j <= 15:
            out[(i, j - rows)] = c
    return out


def redrawn_motion(P, art, rest, mid, board, uses, frames, changes, effects):
    """A redrawn item: 12 fps frames (canvas-cell dicts), its reference picture (a sticker, or for a B item Claude Code's pose vocabulary), the
    named changes from the rest pose and the colours of its effect pixels (the heart, the bulb)."""
    m = P.Motion(mid, board, "redrawn", uses)
    m.nsrc = len(frames)
    if board in STICKERS:
        path = STICKERS[board]
        m.source = {"kind": "redrawn", "picture": path[:-4], "ext": "png", "sha256": sha256_file(os.path.join(art, path)), "board": board}
    else:
        m.source = {"kind": "redrawn", "path": POSE_SOURCE, "sha256": sha256_file(os.path.join(art, POSE_SOURCE)), "board": board, "lines": list(POSE_LINES)}
    m.clawd_colors = {P.PET_BODY, P.PET_EYE, SHADE_B}
    m.src_frames = list(range(len(frames)))
    m.flags = {"restStart": frames[0] == rest, "restEnd": frames[-1] == rest}
    m.stage = P.stage_of(frames)
    m.frames = [P.crop(c, m.stage) for c in frames]
    heads = [head_of_cells(P, c, m.clawd_colors) for c in frames]
    m.head = [hd for hd, _ in heads]
    m.rigid = all(hd is not None and ex for hd, ex in heads)
    body_like = {P.PET_BODY, SHADE_B}
    m.overhead_clear = all(hd is not None and all(c[:3] in body_like for (i, j), c in frames[k].items() if j < hd[1]) for k, (hd, _) in enumerate(heads))
    m.ms = P.half_ms(len(frames))
    m.weight = 1
    m.phase = 2
    m.extra = {"redraw": {"base": "idle_0", "changes": changes, "effectColors": sorted(list(c) for c in effects)}}
    P.finish_uses(m)
    return m


# The calm idle motions (round 3). The pose vocabulary is Claude Code's own, drawn on the pet grid the way render-core.js:107-125 and :139-152 map
# it: one unit is 2 x 2 cells, the eyes sit on unit row 5 (cell rows 10..11) at unit columns 3 and 8, `look-left` / `look-right` shift both by one unit,
# `closed` is two 2-unit lines at columns 3-4 and 7-8, `wink` the left eye open and the right one a line, and the foot pose `right` (the left feet
# up) cuts the two left legs (unit columns 2 and 4) to one unit. Every frame is the rest pose with that one change; each motion starts and ends on
# the rest frame, at 12 fps, uses `idle`, weight 1.
EYE_UNITS = {"rest": (3, 8), "left": (2, 7), "right": (4, 9), "closed": (3, 4, 7, 8), "wink": (3, 7, 8)}
LEFT_LEGS_UP = [(i, j) for i in (4, 5, 8, 9) for j in (22, 23)]        # the lower unit of the two left legs
# id, board, declared change, [(state, frame count)]
CALM = [
    ("B3-glance-left", "B3", "eyes:look-left", [("rest", 3), ("left", 14), ("rest", 3)]),
    ("B3-glance-right", "B3", "eyes:look-right", [("rest", 3), ("right", 14), ("rest", 3)]),
    ("B3-glance-left-long", "B3", "eyes:look-left", [("rest", 3), ("left", 22), ("rest", 3)]),
    ("B3-glance-right-long", "B3", "eyes:look-right", [("rest", 3), ("right", 22), ("rest", 3)]),
    ("B4-wink", "B4", "eyes:wink", [("rest", 3), ("wink", 6), ("rest", 3)]),
    ("B4-slow-blink", "B4", "eyes:closed", [("rest", 4), ("closed", 6), ("rest", 4)]),
    ("B5-foot-tap", "B5", "legs:left-up", [("rest", 4), ("up", 3), ("rest", 3), ("up", 3), ("rest", 5)]),
]


def calm_frame(P, rest, state):
    """One frame of a calm motion: the rest pose with its eyes in `state` ("rest", "left", "right", "closed", "wink") or with its left foot "up"."""
    if state == "rest":
        return dict(rest)
    if state == "up":
        return {p: c for p, c in rest.items() if p not in LEFT_LEGS_UP}
    c = plain_body(P, rest)
    for u in EYE_UNITS[state]:
        for dx in (0, 1):
            for dy in (0, 1):
                c[(2 * u + dx, 10 + dy)] = P.PET_EYE + (255,)
    return c


def build_calm(P, art, rest):
    out = []
    for mid, board, change, steps in CALM:
        frames = []
        for state, n in steps:
            frames += [calm_frame(P, rest, state)] * n
        out.append(redrawn_motion(P, art, rest, mid, board, ["idle"], frames, [change], []))
    return out


def build_moments(P, art, rest):
    motions = []
    happy = eyes(P, rest, CHEVRON, mirror_x(CHEVRON), 5, 15, 10)
    motions.append(redrawn_motion(P, art, rest, "D4-happy", "D4", ["touch", "sent"], [rest] + [happy] * 14 + [rest], ["eyes:chevrons"], []))
    a = eyes(P, rest, SWIRL_A, mirror_x(SWIRL_A), 5, 15, 9)
    b = eyes(P, rest, SWIRL_B, mirror_x(SWIRL_B), 5, 15, 9)
    motions.append(redrawn_motion(P, art, rest, "D5-dizzy", "D5", ["multi-touch", "error"], [rest] + [a, a, b, b] * 3 + [rest], ["eyes:spirals"], []))
    # the sticker's heart sits above its raised left arm; here it is mirrored to the right, so that the stage grows to the right only
    # (a touch reaction that grew the stage to the left would move the panel's origin while Clawd stays where he is)
    arm = raise_arm(rest, False, 2)
    lifted = dict(arm)
    lifted.update(palette_ink(HEART_PATTERN, 18, 3, {"X": HEART}))
    motions.append(redrawn_motion(P, art, rest, "D6-heart", "D6", ["touch", "idle"], [rest, arm] + [lifted] * 16 + [arm, rest],
                                  ["arm-right:lifted"], [HEART]))
    up = {p: c for p, c in rest.items() if not (20 <= p[0] <= 23 and 12 <= p[1] <= 15)}
    for j in range(3, 8):
        for i in range(16, 20):
            up[(i, j)] = P.PET_BODY + (255,)
    off, on = dict(up), dict(up)
    off.update(palette_ink(BULB_OFF, 5, -6, BULB))
    on.update(palette_ink(BULB_ON, 5, -6, BULB))
    motions.append(redrawn_motion(P, art, rest, "D11-lightbulb", "D11", ["idle"], [rest, up, off, off] + [on] * 14 + [off, up, rest],
                                  ["arm-right:raised"], list(BULB.values())))
    return motions


# ---- D14 ride: the skateboard's glide ------------------------------------------------------------------------------------------
def ride_cells(sprites, f):
    """{(x, y): rgba} of sprite 1 frame f as stored (RIDE_STORE added). The frames of RIDE_BOARD_EDIT take the board cells of the rest frame (R2-1, an
    edit rule declared in the catalog the way the pool float's `fill` is): their own board cells go and frame 18's come, over whatever Clawd's feet
    drew on those cells, so the first and the last frame carry exactly the rest picture's board."""
    sprite = sprites[SKATE_SPRITE["index"]]
    cells = sprite_cells(sprite, f, SKATE_MAP)
    if f in RIDE_BOARD_EDIT:
        board = {tuple(c) for c in BOARD}
        rest_board = {p: c for p, c in sprite_cells(sprite, RIDE_REST_FRAME, SKATE_MAP).items() if c[:3] in board}
        cells = {p: c for p, c in cells.items() if c[:3] not in board}
        cells.update(rest_board)
    return {(x + RIDE_STORE[0], y + RIDE_STORE[1]): c for (x, y), c in cells.items()}


def build_ride(P, art, sprites, rest):
    sprite = sprites[SKATE_SPRITE["index"]]
    first, last = RIDE_FRAMES
    if sprite["fps"] != P.FPS:
        raise Phase2Error("the skateboard sprite runs at %d fps, the ride is stored at %d" % (sprite["fps"], P.FPS))
    srcs = list(range(first, last + 1))
    cells = [ride_cells(sprites, f) for f in srcs]
    m = P.Motion(RIDE_ID, "D14", "ported", ["ride"])
    m.nsrc = SKATE_SPRITE["frames"]
    m.source = {"kind": "sprite", "path": DEV_CHUNK, "sha256": sha256_file(os.path.join(art, DEV_CHUNK)), "sprite": SKATE_SPRITE["index"],
                "frames": SKATE_SPRITE["frames"], "colorMap": [dict(e) for e in SKATE_MAP], "store": list(RIDE_STORE),
                "boardEdit": {"frames": list(RIDE_BOARD_EDIT), "from": RIDE_REST_FRAME, "keep": [list(c) for c in BOARD]}}
    m.extra = {"segments": [{"name": name, "srcFrames": [a, b], "frames": [a - first, b - first]} for name, a, b in RIDE_SEGMENTS]}
    m.clawd_colors = {P.PET_BODY, P.PET_EYE, SHADE}
    m.src_frames = srcs
    m.flags = {"restStart": cells[0] == rest, "restEnd": cells[-1] == rest, "offRest": True}
    m.stage = P.stage_of(cells)
    m.frames = [P.crop(c, m.stage) for c in cells]
    heads = [head_of_cells(P, c, m.clawd_colors) for c in cells]
    m.head = [hd for hd, _ in heads]
    m.rigid = all(hd is not None and ex for hd, ex in heads)
    body_like = {P.PET_BODY, SHADE}
    m.overhead_clear = all(hd is not None and all(c[:3] in body_like for (i, j), c in cells[k].items() if j < hd[1]) for k, (hd, _) in enumerate(heads))
    m.weight = 1
    m.phase = 2
    P.finish_uses(m)
    return m


# ---- looks: layer derivations (the cut descriptors in the catalog say how each layer is made; the checker derives them again) --------
def derive_sprite_layer(cut, sprites, rest):
    """{(dx, dy): rgba} of a layer cut from a sprite frame. Head anchored layers are relative to the sprite cell `headAt`; feet anchored
    ones (`origin`) are relative to the canvas' bottom-left corner. `fill` paints the sprite's own Clawd cells that the pet's rest body
    does not cover (they hid ring cells the sprite never shows)."""
    cells = sprite_cells(sprites[cut["sprite"]], cut["frame"], cut["colorMap"])
    keep = {tuple(c) for c in cut["keep"]}
    univ = cut.get("universeRows")
    sel = {p for p, c in cells.items() if c[:3] in keep and (univ is None or univ[0] <= p[1] <= univ[1])}
    if cut.get("largestComponent"):
        sel = largest_component(sel)
    if cut.get("rows"):
        sel = {p for p in sel if cut["rows"][0] <= p[1] <= cut["rows"][1]}
    layer = {p: cells[p] for p in sel}
    if cut.get("fill"):
        hx, hy = cut["headAt"]
        covered = {(i + hx - HEAD[0], j + hy - HEAD[1]) for (i, j) in rest}
        of, color = tuple(cut["fill"]["of"]), tuple(cut["fill"]["color"]) + (255,)
        for p, c in cells.items():
            if c[:3] == of and p not in covered:
                layer[p] = color
    if "origin" in cut:
        ox, oy = cut["origin"]
        return {(x - ox, y - oy - CANVAS): c for (x, y), c in layer.items()}
    hx, hy = cut["headAt"]
    return {(x - hx, y - hy): c for (x, y), c in layer.items()}


def derive_gif_layer(cut, gif_cells_of_frame):
    keep = {tuple(c) for c in cut["keep"]}
    rows = cut.get("rows", [-1000, 1000])
    hx, hy = cut["headAt"]
    return {(i - hx, j - hy): c for (i, j), c in gif_cells_of_frame.items() if c[:3] in keep and rows[0] <= j <= rows[1]}


def derive_motion_layer(cut, motion_cells):
    cols = cut["cols"]
    sx, sy = cut["shift"]
    hx, hy = cut["headAt"]
    return {(i + sx - hx, j + sy - hy): c for (i, j), c in motion_cells.items() if cols[0] <= i <= cols[1]}


def sticker_palette(P, art):
    """The sparkles' colours by the histogram rule above: {"body", "shade", "highlights"}, each {"rgb", "pixel"} (the highlights a list of three;
    the dominant bucket and its darker band are only set aside, nothing is recoloured)."""
    w, h, rows = P.read_png(os.path.join(art, STICKERS["D7"]))
    count, exact, first = {}, {}, {}
    for y in range(h):
        row = rows[y]
        for x in range(w):
            r, g, b, a = row[x * 4:x * 4 + 4]
            if a == 255 and min(r, g, b) >= PASTEL_MIN and max(r, g, b) - min(r, g, b) >= PASTEL_SPREAD:
                q = (r >> 4, g >> 4, b >> 4)
                count[q] = count.get(q, 0) + 1
                exact.setdefault(q, {})
                exact[q][(r, g, b)] = exact[q].get((r, g, b), 0) + 1
                first.setdefault((r, g, b), (x, y))
    order = sorted(count, key=lambda q: (-count[q], q))
    if len(order) < 2 + PASTEL_HIGHLIGHTS:
        raise Phase2Error("shiny sticker: only %d pastel buckets" % len(order))

    def centre(q):
        return tuple(16 * v + 8 for v in q)

    def luma(c):
        return 299 * c[0] + 587 * c[1] + 114 * c[2]

    def pick(q):
        best = max(exact[q].values())
        rgb = min(c for c, n in exact[q].items() if n == best)
        return {"rgb": list(rgb), "pixel": list(first[rgb])}

    body = order[0]
    shade = next((q for q in order if luma(centre(q)) < luma(centre(body))), None)
    if shade is None:
        raise Phase2Error("shiny sticker: no pastel bucket is darker than the dominant one")
    chosen, highlights = [body, shade], []
    for q in order:
        if q not in chosen and all(sum(abs(u - v) for u, v in zip(centre(q), centre(o))) >= PASTEL_APART for o in chosen):
            chosen.append(q)
            highlights.append(q)
            if len(highlights) == PASTEL_HIGHLIGHTS:
                break
    if len(highlights) < PASTEL_HIGHLIGHTS:
        raise Phase2Error("shiny sticker: fewer than %d distinct highlight pastels" % PASTEL_HIGHLIGHTS)
    return {"body": pick(body), "shade": pick(shade), "highlights": [pick(q) for q in highlights]}


def sticker_outside(w, h, rows):
    """Per row a bytearray: 1 where a pixel of the sticker picture is outside the die-cut (not fully opaque, and connected by 4-neighbours through
    such pixels to the picture's edge), else 0."""
    outside = [bytearray(w) for _ in range(h)]
    todo = deque()
    for x in range(w):
        for y in (0, h - 1):
            if rows[y][x * 4 + 3] != 255 and not outside[y][x]:
                outside[y][x] = 1
                todo.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if rows[y][x * 4 + 3] != 255 and not outside[y][x]:
                outside[y][x] = 1
                todo.append((x, y))
    while todo:
        x, y = todo.popleft()
        for a, b in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= a < w and 0 <= b < h and rows[b][a * 4 + 3] != 255 and not outside[b][a]:
                outside[b][a] = 1
                todo.append((a, b))
    return outside


def near_outside(outside, w, h, x, y):
    """True when a pixel lies within BORDER_BAND pixels (a square window) of the outside: it is in the die-cut border band."""
    return any(outside[yy][xx] for yy in range(max(0, y - BORDER_BAND), min(h, y + BORDER_BAND + 1))
               for xx in range(max(0, x - BORDER_BAND), min(w, x + BORDER_BAND + 1)))


def sticker_border(P, art, palette):
    """The border pastels in running order, by the rule above: [{"sector", "angle", "rgb", "pixel"}] clockwise from up. The sparkles'
    highlight pastels must lie in the same band."""
    w, h, rows = P.read_png(os.path.join(art, STICKERS["D7"]))
    outside = sticker_outside(w, h, rows)
    sx = sy = n = 0
    for y in range(h):
        for x in range(w):
            if not outside[y][x]:
                sx, sy, n = sx + x, sy + y, n + 1
    cx, cy = sx / n, sy / n
    out = []
    for k in range(BORDER_SECTORS):
        angle = 360.0 * (k + 0.5) / BORDER_SECTORS
        t = math.radians(angle)
        dx, dy = math.sin(t), -math.cos(t)
        r = 0.0
        while True:
            x, y = int(round(cx + r * dx)), int(round(cy + r * dy))
            if not (0 <= x < w and 0 <= y < h) or outside[y][x]:
                break
            r += 0.5
        r -= BORDER_DEPTH
        x, y = int(round(cx + r * dx)), int(round(cy + r * dy))
        red, green, blue, alpha = rows[y][x * 4:x * 4 + 4]
        if alpha != 255 or min(red, green, blue) < PASTEL_MIN or max(red, green, blue) - min(red, green, blue) < PASTEL_SPREAD:
            raise Phase2Error("shiny sticker: the border sample of sector %d at (%d, %d) is not an opaque pastel" % (k, x, y))
        out.append({"sector": k, "angle": angle, "rgb": [red, green, blue], "pixel": [x, y]})
    for hl in palette["highlights"]:
        if not near_outside(outside, w, h, *hl["pixel"]):
            raise Phase2Error("shiny sticker: the highlight pastel at %s is not in the border band" % (hl["pixel"],))
    return out


def border_cells(rest, colours):
    """{(dx, dy): rgba} of the outline behind the rest silhouette, relative to the head anchor: the cells outside the silhouette within the rounded reach
    of one of its cells, each in the colour of the sector its centre lies in."""
    sil = {(x - HEAD[0], y - HEAD[1]) for (x, y) in rest}
    ring = {(x + dx, y + dy) for (x, y) in sil for (dx, dy) in BORDER_REACH} - sil
    out = {}
    for (dx, dy) in ring:
        angle = math.degrees(math.atan2(dx + 0.5 - BORDER_CENTRE[0], -(dy + 0.5 - BORDER_CENTRE[1]))) % 360.0
        k = min(int(angle * BORDER_SECTORS / 360.0), BORDER_SECTORS - 1)
        out[(dx, dy)] = tuple(colours[k]["rgb"]) + (255,)
    return out


def sparkle_cells(palette):
    """{(dx, dy): rgba} of the static sparkles, relative to the head anchor."""
    colors = {role: tuple(palette["highlights"][i]["rgb"]) + (255,) for i, role in enumerate("abc")}
    out = {}
    for star in SPARKLES:
        x0, y0 = star["at"]
        for r, row in enumerate(star["rows"]):
            for c, ch in enumerate(row):
                if ch != ".":
                    out[(x0 + c, y0 + r)] = colors[ch]
    return out


def layer_png(P, cells):
    """(png bytes, (min dx, min dy), (width, height)) of a layer given as {(dx, dy): rgba}."""
    x0, y0 = min(p[0] for p in cells), min(p[1] for p in cells)
    x1, y1 = max(p[0] for p in cells), max(p[1] for p in cells)
    grid = [[None] * (x1 - x0 + 1) for _ in range(y1 - y0 + 1)]
    for (x, y), c in cells.items():
        grid[y - y0][x - x0] = c
    return P.png_bytes(grid), [x0, y0], [x1 - x0 + 1, y1 - y0 + 1]


# ---- looks and K1 -------------------------------------------------------------------------------------------------------------
def own(c):
    return c is not None and c[:3] in OWN


ARM_CELLS = [(x, y) for x in range(8, 12) for y in range(4, 8)]       # the right arm's rest place relative to the head anchor (2 x 2 units)


def hand_cells(cells):
    """The cells of the right arm's rest place that a prop layer lies on or touches (4-neighbour): the cells the prop is anchored to."""
    return [a for a in ARM_CELLS if a in cells or any(q in cells for q in ((a[0] + 1, a[1]), (a[0] - 1, a[1]), (a[0], a[1] + 1), (a[0], a[1] - 1)))]


def laydef(name, z, attach, cells, clicks, cut, png=None, hugs=False):
    d = {"name": name, "z": z, "attach": attach, "cells": cells, "takesClicks": clicks, "cut": cut, "png": png, "hugs": hugs}
    if attach == "arm-right":
        d["hand"] = hand_cells(cells)
        if not d["hand"]:
            raise Phase2Error("layer %s is a held prop but lies on no cell of the arm and touches none" % name)
    return d


def effect_cells(C, hx, hy):
    """The cells of a frame (canvas cells, head at (hx, hy)) that are not Clawd's body: a colour that is not Clawd's own, or Clawd's colour
    outside the body box (a raised arm, not the one unit of squash and stretch the box allows)."""
    x0, x1, y0, y1 = BODY_BOX
    return {p for p, c in C.items() if not (own(c) and x0 <= p[0] - hx <= x1 and y0 <= p[1] - hy <= y1)}


def eye_cells(C, hx, hy):
    """The eye pixels of a frame: the near-black cells inside the torso (the hat of a detective is not an eye)."""
    return {p for p, c in C.items() if c[:3] == P_EYE and -8 <= p[0] - hx < 8 and 0 <= p[1] - hy < 12}


def placed_cells(lay, hx, hy, lift):
    """The cells a layer covers in a frame's coordinates. Head anchored layers sit at (hx + dx, hy + dy); feet anchored ones at the canvas'
    bottom-left plus the offset, and the frame is lifted by `lift` cells under them."""
    if lay["attach"] == "feet":
        return {(dx, CANVAS + dy + lift) for (dx, dy) in lay["cells"]}
    return {(hx + dx, hy + dy) for (dx, dy) in lay["cells"]}


def silhouette_of(C, hx, hy):
    """The cells of Clawd's own colours in a frame (head at (hx, hy)), moved so that the head is at the rest head: relative to the head anchor."""
    return {(x - hx, y - hy) for (x, y), c in C.items() if own(c)}


def eyes_are_the_point(m):
    """A motion whose catalog entry declares an eye expression (`redraw.changes` names `eyes:*`: D4 chevrons, D5 swirls)."""
    return any(c.startswith("eyes:") for c in m.extra.get("redraw", {}).get("changes", []))


BELOW_BASELINE_OK = {("skateboard", "board")}     # spec 3.1 R3: the one layer that may lie below the feet baseline (canvas cell row 23), by (look, layer) name
BASELINE_ROW = CANVAS - 1


def baseline_ok(m, look, lid):
    """K1, the composite baseline (spec 9b item 12): the look's layers placed on every frame of the motion (the frame's head anchor, the look's
    lift) have no cell below the feet baseline; a frame with no head anchor cannot place a head-anchored layer."""
    lift = look.get("raiseCells", 0)
    for lay in look["laydefs"]:
        if (lid, lay.get("name")) in BELOW_BASELINE_OK or not lay["cells"]:
            continue
        lowest = max(dy for (dx, dy) in lay["cells"])
        if lay["attach"] == "feet":
            if CANVAS + lowest > BASELINE_ROW:
                return False
            continue
        if any(h is None or h[1] - lift + lowest > BASELINE_ROW for h in m.head):
            return False
    return True


T1_DROPPED = {}                    # (look id, motion id) -> the GIF verdict that dropped the pair from tier 1 (frame numbers included); the checker holds its own copy
T1_TOUCH = [(dx, dy) for dx in (-1, 0, 1) for dy in (-1, 0, 1)]       # T1-touch-n8
T1_BODY = {(215, 119, 87), SHADE, SHADE_B}


def eye_centroid(C):
    """The mean cell of the eyes of a frame: the 4-connected components of eye pixels that 4-touch a body cell of Clawd; None when there is none."""
    eyes = {p for p, c in C.items() if c[:3] == P_EYE}
    seen, kept = set(), []
    for s in sorted(eyes):
        if s in seen:
            continue
        comp, todo = [], [s]
        seen.add(s)
        while todo:
            i, j = todo.pop()
            comp.append((i, j))
            for n in ((i + 1, j), (i - 1, j), (i, j + 1), (i, j - 1)):
                if n in eyes and n not in seen:
                    seen.add(n)
                    todo.append(n)
        if any((C.get((i + di, j + dj)) or (0, 0, 0))[:3] in T1_BODY for i, j in comp for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1))):
            kept.extend(comp)
    if not kept:
        return None
    return (sum(i for i, _ in kept) / len(kept), sum(j for _, j in kept) / len(kept))


def anchor_follows(m, f):
    """Tier 1, the anchor follows the head from frame f-1 to frame f: two exact head blocks pass; otherwise the anchor's step must be within one cell
    of the step of the eye centre, and a frame without an eye centre fails."""
    if m.exact[f - 1] and m.exact[f]:
        return True
    e0, e1 = m.eyes[f - 1], m.eyes[f]
    if e0 is None or e1 is None:
        return False
    a0, a1 = m.head[f - 1], m.head[f]
    return abs((a1[0] - a0[0]) - (e1[0] - e0[0])) <= 1 and abs((a1[1] - a0[1]) - (e1[1] - e0[1])) <= 1


def hand_broken(C, hx, hy, lay):
    """The held-arm rule failing in one frame: fewer than 4 of the arm's rest place are Clawd's own, or a hand cell of the prop is not."""
    return (sum(1 for x in range(hx + 8, hx + 12) for y in range(hy + 4, hy + 8) if own(C.get((x, y)))) < 4
            or any(not own(C.get((hx + x, hy + y))) for x, y in lay["hand"]))


def tier1_compatible(m, look, lid):
    """K1 for a layered look on a motion without an exact head block in every frame (tier 1, rules in the module docstring): the anchor exists and
    follows the head in every frame, nothing the motion draws above the head lies on or next to a cell of the look, and the carried rules hold at
    the frame's own anchor."""
    if (lid, m.id) in T1_DROPPED:       # T1-dropped
        return False
    lift = look.get("raiseCells", 0)
    d_on = True                         # T1-d
    eyes = d_on and eyes_are_the_point(m)
    for f, C in enumerate(m.cds):
        if m.head[f] is None:
            return False                # T1-a
        if f and m.head[f - 1] is not None and not anchor_follows(m, f):     # T1-b
            return False
        hx, hy = m.head[f]
        effects, eye = (effect_cells(C, hx, hy) if d_on else None), (eye_cells(C, hx, hy) if eyes else None)
        over = {q for q, c in C.items() if q[1] < hy and c[:3] not in m.body_like}
        drawn = set()
        for lay in look["laydefs"]:
            a = lay["attach"]
            placed = placed_cells(lay, hx, hy, lift)
            drawn |= placed
            if lay.get("hugs") and silhouette_of(C, hx, hy) != look["restSilhouette"]:       # T1-hugs
                return False
            if a == "arm-right" and hand_broken(C, hx, hy, lay):       # T1-held
                return False
            if a == "feet" and any(not own(C.get(q)) for q in LEG_CELLS):       # T1-feet
                return False
            if d_on and lay["z"] == "front" and (placed & effects or (eye and placed & eye)):
                return False
        if over & {(x + dx, y + dy) for (x, y) in drawn for dx, dy in T1_TOUCH}:       # T1-c
            return False
    return baseline_ok(m, look, lid)       # T1-baseline


def look_compatible(m, cds, look, lid):
    """K1 for one (motion, look): the rules of the module docstring, from the catalog frames `cds` of the motion. A phase 1 look against a
    phase 1 motion needs an exact head block only (phase 1 stays as it was); any pair with a phase 2 side also keeps front layers off effect
    pixels and, for a motion whose point is its eyes, off eye pixels. A back layer is drawn under the frame and covers nothing. Every pair keeps
    the composite baseline (`baseline_ok`)."""
    if m.id in look["signature"]:
        return look.get("layerOnSignature", True) is False or baseline_ok(m, look, lid)
    if not look["laydefs"]:
        return True                      # a look with no layer (a body colour alone) needs no anchor: its recolour is an exact colour substitution on Clawd's own layers
    if not m.rigid:
        return tier1_compatible(m, look, lid)       # K1-tier1-path
    lift = look.get("raiseCells", 0)
    scope = look.get("phase", 1) >= 2 or m.phase >= 2
    eyes = scope and eyes_are_the_point(m)
    for f, C in enumerate(cds):
        hx, hy = m.head[f]
        effects, eye = (effect_cells(C, hx, hy) if scope else None), (eye_cells(C, hx, hy) if eyes else None)
        for lay in look["laydefs"]:
            a = lay["attach"]
            if lay.get("hugs") and silhouette_of(C, hx, hy) != look["restSilhouette"]:
                return False
            if a == "arm-right" and (sum(1 for x in range(hx + 8, hx + 12) for y in range(hy + 4, hy + 8) if own(C.get((x, y)))) < 4
                                     or any(not own(C.get((hx + x, hy + y))) for x, y in lay["hand"])):
                return False
            if a == "feet" and any(not own(C.get(p)) for p in LEG_CELLS):
                return False
            if scope and lay["z"] == "front":
                placed = placed_cells(lay, hx, hy, lift)
                if placed & effects or (eye and placed & eye):
                    return False
    return baseline_ok(m, look, lid)


def build_looks(P, art, motions, rest, a_cells, gif_cells_all, sprites, gif_motion):
    """The six phase 2 looks: (look entries without compat, layer PNG files, the in-memory laydefs for K1)."""
    chunk_sha, gif_sha = sha256_file(os.path.join(art, DEV_CHUNK)), sha256_file(os.path.join(art, GIF_PATH))
    chunk = {"path": DEV_CHUNK, "sha256": chunk_sha}
    files, looks = {}, {}
    rest_silhouette = {(x - HEAD[0], y - HEAD[1]) for (x, y) in rest}

    def finish(look, laydefs, signature, extra=None):
        entry = {"id": look["id"], "board": look["board"], "class": look["class"], "weight": look["weight"], "signature": signature,
                 "anchor": look["anchor"], "phase": 2}
        if "raiseCells" in look:
            entry["raiseCells"] = look["raiseCells"]
        layers = []
        for lay in laydefs:
            rel = "looks/%s/%s.png" % (look["id"], lay["name"])
            data, offset, size = layer_png(P, lay["cells"])
            files[rel] = data
            e = {"name": lay["name"], "z": lay["z"], "attach": lay["attach"], "png": rel, "offset": offset, "size": size,
                 "takesClicks": lay["takesClicks"], "cut": lay["cut"]}
            if lay["attach"] == "feet":
                e["anchor"] = "feet"
            if lay["hugs"]:
                e["hugs"] = "rest-silhouette"
            layers.append(e)
        entry["layers"] = layers
        entry["layerOnSignature"] = look.get("layerOnSignature", True)
        if extra:
            entry.update(extra)
        entry_signature = entry["signature"]
        looks[look["id"]] = {"entry": entry, "laydefs": laydefs, "signature": entry_signature, "raiseCells": look.get("raiseCells", 0), "phase": 2,
                             "restSilhouette": rest_silhouette, "layerOnSignature": entry["layerOnSignature"]}

    # pool float (D2): the ring behind (rows above the legs' last row) and in front (that row and below), the sunglasses on the face
    ring = {"kind": "sprite", **chunk, "sprite": 6, "frame": 0, "colorMap": POOL_MAP, "keep": RING, "universeRows": [0, 27],
            "largestComponent": True, "headAt": [19, 6]}
    back = dict(ring, rows=[0, 20], fill={"of": [215, 119, 87], "color": [71, 108, 145]})
    front = dict(ring, rows=[21, 27])
    glasses = {"kind": "sprite", **chunk, "sprite": 6, "frame": 0, "colorMap": POOL_MAP, "keep": [[20, 20, 19]], "headAt": [19, 6]}
    finish({"id": "pool-float", "board": "D2", "class": ["torso-overlay", "costume"], "weight": 0.5, "anchor": "head", "raiseCells": POOL_RAISE},
           [laydef("ring-back", "back", "torso", derive_sprite_layer(back, sprites, rest), True, back),
            laydef("ring-front", "front", "torso", derive_sprite_layer(front, sprites, rest), True, front),
            laydef("sunglasses", "front", "head", derive_sprite_layer(glasses, sprites, rest), True, glasses)], [])

    # shiny (D7): Clawd's own colours, the sticker's pastel rainbow as an outline behind the rest silhouette (it shows only outside it), and static
    # sparkles around the body; Clawd is lifted by the outline's thickness so that its lower edge lies on the baseline
    palette = sticker_palette(P, art)
    colours = sticker_border(P, art, palette)
    sticker = {"path": STICKERS["D7"][:-4], "ext": "png", "sha256": sha256_file(os.path.join(art, STICKERS["D7"]))}
    border = {"kind": "border", **sticker, "cells": BORDER_CELLS, "reach": "%dx%d-without-corners" % (2 * BORDER_CELLS + 1, 2 * BORDER_CELLS + 1), "silhouette": "rest", "sectors": BORDER_SECTORS,
              "depth": BORDER_DEPTH, "colors": colours}
    sparkles = {"kind": "sparkle", **sticker, "stars": SPARKLES, "colors": {role: palette["highlights"][i] for i, role in enumerate("abc")}}
    finish({"id": "shiny", "board": "D7", "class": ["torso-overlay"], "weight": 0.5, "anchor": "head", "raiseCells": SHINY_RAISE},
           [laydef("border", "back", "torso", border_cells(rest, colours), False, border, hugs=True),
            laydef("sparkles", "front", "head", sparkle_cells(palette), False, sparkles)], [])

    # coffee (D9): the mug of A19, cut as Sprint 1 cut the other held pixels
    mug = {"motion": "A19-coffee", "frame": 7, "colors": [[114, 114, 107], [47, 47, 45]], "restBody": False}
    a19 = a_cells["A19-coffee"][7]
    hd = a_head(P, a19)
    mug_cells = {(i - hd[0], j - hd[1]): c for (i, j), c in a19.items() if c[:3] in {(114, 114, 107), (47, 47, 45)}}
    finish({"id": "coffee", "board": "D9", "class": ["held"], "weight": 1, "anchor": "arm-right", "layerOnSignature": False},
           [laydef("mug", "front", "arm-right", mug_cells, False, mug)], ["A19-coffee"])

    # detective (D12): the hat and the magnifier of GIF frame 22 (hat on, magnifier raised, everything else the rest pose)
    gif_src = {"kind": "gif", "path": GIF_PATH, "sha256": gif_sha}
    hat = {**gif_src, "frame": 22, "keep": [[20, 20, 19], [97, 56, 10]], "rows": [-1000, 8], "headAt": list(HEAD)}
    lens = {**gif_src, "frame": 22, "keep": [[62, 56, 125]], "headAt": list(HEAD)}
    hat_cells, lens_cells = derive_gif_layer(hat, gif_cells_all[22]), derive_gif_layer(lens, gif_cells_all[22])
    finish({"id": "detective", "board": "D12", "class": ["costume", "held"], "weight": 1, "anchor": "head+arm-right", "layerOnSignature": False},
           [laydef("hat", "front", "head", hat_cells, True, hat), laydef("magnifier", "front", "arm-right", lens_cells, False, lens)],
           ["D12-inspect"], {"restPicture": {"source": "gif", "frame": 22}})

    # wand (D13): the wand and its sparks of A25 frame 24, one row up so the wand is at the rest arm's second row
    wand = {"kind": "motion", "motion": "A25-spark", "frame": 24, "cols": [24, 31], "shift": [0, -1], "headAt": list(HEAD)}
    finish({"id": "wand", "board": "D13", "class": ["held"], "weight": 1, "anchor": "arm-right", "layerOnSignature": False},
           [laydef("wand", "front", "arm-right", derive_motion_layer(wand, a_cells["A25-spark"][24]), False, wand)], ["A25-spark"])

    # skateboard (D14): the board of sprite 1 frame 18 (Clawd raised 6 cells, standing on it), anchored to the baseline. Its glide plays D14-ride, whose
    # frames carry their own board: the look is that motion's signature and leaves its layers off on it (R2-4)
    board = {"kind": "sprite", **chunk, "sprite": 1, "frame": 18, "colorMap": SKATE_MAP, "keep": BOARD, "origin": [0, 5]}
    finish({"id": "skateboard", "board": "D14", "class": ["under-feet"], "weight": 1, "anchor": "feet", "raiseCells": RAISE, "layerOnSignature": False},
           [laydef("board", "front", "feet", derive_sprite_layer(board, sprites, rest), False, board)], [RIDE_ID],
           {"restPicture": {"source": "sprite", "sprite": 1, "frame": 18, "origin": [0, 5], "raise": RAISE}})

    # the rest pictures that must equal the official frames
    verify_rest_pictures(P, looks, rest, gif_cells_all, sprites)
    return looks, files


def a_head(P, cells):
    hd, exact = head_of_cells(P, cells, {P.PET_BODY, P.PET_EYE, SHADE})
    if hd is None or not exact:
        raise Phase2Error("the mug's source frame has no exact head block")
    return hd


def compose_layers(rest, laydefs, raise_by, head_x, head_y):
    """The rest body lifted by raise_by with the layers drawn over it (back layers under the body), as a canvas-cell dict."""
    out = {}
    lifted = {(i, j - raise_by): c for (i, j), c in rest.items()}
    for lay in laydefs:
        if lay["z"] == "back":
            origin = (head_x, head_y - raise_by) if lay["attach"] != "feet" else (0, CANVAS)
            for (dx, dy), c in lay["cells"].items():
                out[(origin[0] + dx, origin[1] + dy)] = c
    out.update(lifted)
    for lay in laydefs:
        if lay["z"] == "front":
            origin = (head_x, head_y - raise_by) if lay["attach"] != "feet" else (0, CANVAS)
            for (dx, dy), c in lay["cells"].items():
                out[(origin[0] + dx, origin[1] + dy)] = c
    return out


def verify_rest_pictures(P, looks, rest, gif_cells_all, sprites):
    det = looks["detective"]
    got = compose_layers(rest, det["laydefs"], 0, HEAD[0], HEAD[1])
    if got != gif_cells_all[22]:
        raise Phase2Error("detective: the rest picture with its hat and magnifier is not GIF frame 22")
    sk = looks["skateboard"]
    got = compose_layers(rest, sk["laydefs"], RAISE, HEAD[0], HEAD[1])
    want = {(x, y - 5): c for (x, y), c in sprite_cells(sprites[1], 18, SKATE_MAP).items()}
    if got != want:
        raise Phase2Error("skateboard: the rest picture with the board is not sprite frame 18")


def set_phase2_compat(P, motions, all_looks):
    """compatibleLooks for every motion: plain, then every look (in catalog order) it is compatible with. `all_looks` is [(look id,
    {laydefs, signature, raiseCells, phase, restSilhouette})]; a phase 1 look has its real layer cells. Returns the K1 floor shortfalls (a look
    with fewer than 6 compatible idle motions is not in rotation): the catalog is still written, and the checker fails it."""
    cds = {m.id: frame_cell_dicts(m) for m in motions}
    by_id = {m.id: m for m in motions}
    problems = []
    for m in motions:
        names = ["plain"]
        if not m.rigid:
            colors = m.clawd_colors or (by_id[m.mirror_of].clawd_colors if m.mirror_of else set()) or {P.PET_BODY, P.PET_EYE, SHADE}
            m.cds = cds[m.id]
            m.exact = [head_of_cells(P, C, colors)[1] for C in m.cds]
            m.eyes = [eye_centroid(C) for C in m.cds]
            m.body_like = colors - {P.PET_EYE}
        for lid, look in all_looks:
            if look_compatible(m, cds[m.id], look, lid):
                names.append(lid)
        m.compatible = names
    for lid, look in all_looks:
        n = sum(1 for m in motions if ("idle" in m.uses or ("signature:" + lid) in m.uses) and lid in m.compatible)
        look["idleCount"] = n
        if n < 6:
            problems.append("look %s has only %d compatible idle motions" % (lid, n))
    return problems


def build(P, art, motions, rest, phase1_looks):
    """Returns (new motions, looks in catalog order as (id, look dict), layer files, reports). `motions` are the phase 1 motions with
    their frames; `phase1_looks` are the phase 1 look entries (dicts)."""
    sprites = parse_sprites(os.path.join(art, DEV_CHUNK))
    for spec, name in ((POOL_SPRITE, "pool"), (SKATE_SPRITE, "skateboard")):
        sp = sprites[spec["index"]]
        if (sp["w"], sp["h"], len(sp["frames"])) != (spec["w"], spec["h"], spec["frames"]):
            raise Phase2Error("the %s sprite is not where the catalog expects it" % name)
    gif = decode_gif(os.path.join(art, GIF_PATH))
    m_gif, gif_cells_all = build_gif_motion(P, art, rest, gif)
    moments = build_moments(P, art, rest)
    new_motions = moments + [m_gif] + build_calm(P, art, rest) + [build_ride(P, art, sprites, rest)]
    a_cells = {m.id: [m.cells[f] for f in range(len(m.cells))] for m in motions if hasattr(m, "cells")}
    looks, files = build_looks(P, art, motions, rest, a_cells, gif_cells_all, sprites, m_gif)
    return new_motions, looks, files, {"gif": m_gif.report}
