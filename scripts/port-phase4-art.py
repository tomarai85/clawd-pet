#!/usr/bin/env python3
"""Phase 4 art of the pet (spec v2 sections 3.1-3.4, 6.6, 9b items 7, 10 and 12, Sprint 8): Claude Code's entrance and reaction motions C1-C13, the pose
vocabulary B2-B5 they use, and the looks Ultra (B7) and winter (B8). This is a module of scripts/port-official-art.py (which loads it by path and calls
`build`, after scripts/port-phase3-art.py); it is not run on its own.

Sources (copied into art/sources/claude-code/, none fetched; their sha256 goes into the catalog):
  render-core.js   the reference board's tools/src/render-core.js: Claude Code 2.1.301's pose data (line 3), its entrance motions (line 5: 60 ms per
                   frame), the dust glyphs (line 7), the Ultra pose and colours (lines 9-15), the terminal-to-pet mapping (pixelParamsFor, pixelFrameSVG:
                   lines 139-165) and the pixel rules they use (lines 106-125), and the 2.0.67 winter rows (lines 170-177)
  board-data.js    the reference board's tools/src/data.js: the Ultra card's pet-grid trial (the wand and its star as unit pixels), which B7's pose follows

C1-C13 are TRANSCRIBED (spec 3.1 R5), not drawn. The sequence of each motion is read out of line 5 of render-core.js (a small evaluator for the few
JavaScript forms that line uses); each frame is the pose's pixel parameters (pixelParamsFor) drawn by pixelGrid, moved by round(offset * 8/3) units
down and round(x * 12/9) units across, and clipped to the pet canvas exactly as pixelFrameSVG clips it (rows 4..11, columns 0..11 of the 12 x 12
units): a body below the clip is cut at the baseline, a body to the left of the canvas shows only what is inside it, a body above the torso's top row
is not drawn. Dust glyphs (`dot`, `wave`) are the two or four grey unit pixels of pixelFrameSVG. One unit is 2 x 2 cells; 60 ms per frame.
  Every frame lies inside the canvas (no stage), the first frame of most motions is not the rest pose (R5 pins it to Claude Code's data, and an entrance
  starts from nothing), and C2 celebrate ends sunk by Claude Code's own data.
B2-B5: the poses the C frames use are the pixel rules of S5's calm motions (B3 glances, B4 wink and closed eyes, B5 one foot up) plus B2 (arms up by one
  unit); where a C frame has the same pose as a calm frame the two are the same pixels (the checker compares them).
B7, the Ultra pose (`B7-ultra-wand`): rest, the right arm one unit up holding the wand (three wood pixels rising to a gold star) for 1.5 s, rest. The
  wand and star follow the board's trial for the Ultra card (board-data.js) with the star one unit nearer, so that the star stays inside R3's 4 units
  of stage; the colours are the wood and gold of render-core.js:14.
Looks: Ultra (class body-color, no layer: the body and shade pixels of every frame are mapped to rgb(175,135,255) and its shade; signature A25 Spark and
  B7's pose) and winter (class body-color + a back layer of six white snow pixels at the 2.0.67 rows' '*' cells, mapped by the same terminal-to-pet
  scale; body rgb(173,216,230)). The shade is the body colour scaled by the pet's own shade-to-body ratio, per channel, rounded half up.
"""
import hashlib
import math
import os
import re
from fractions import Fraction

CANVAS = 24
HEAD = (12, 8)
UNITS = 12
PET_BODY = (215, 119, 87)
PET_EYE = (20, 20, 19)
PET_SHADE = (190, 104, 77)
SHADE_B = (191, 105, 77)
SOURCE = "sources/claude-code/render-core.js"
BOARD_DATA = "sources/claude-code/board-data.js"
MS_PER_FRAME = 60

# C items of spec 3.2: id, board, the key of Ho (the sequence in render-core.js), declared uses, frames (spec seconds / 0.06)
C_ITEMS = [
    ("C1-jump", "C1", "jump", ["sent", "touch"], 12),
    ("C2-celebrate", "C2", "celebrate", ["sent"], 15),
    ("C3-skip", "C3", "skip", ["entrance"], 14),
    ("C4-look", "C4", "look", ["listening", "idle"], 11),
    ("C5-spin", "C5", "spin", ["touch"], 10),
    ("C6-peekaboo", "C6", "peekaboo", ["entrance"], 21),
    ("C7-drop", "C7", "drop", ["entrance", "drop"], 13),
    ("C8-waddle", "C8", "waddle", ["entrance"], 19),
    ("C9-peek", "C9", "peek", ["entrance"], 20),
    ("C10-wink", "C10", "wink", ["touch"], 6),
    ("C11-boop", "C11", "boop", ["touch", "interrupted"], 11),
    ("C12-tap", "C12", "tap", ["touch"], 14),
    ("C13-sneeze", "C13", "sneeze", ["idle"], 12),
]
# the lines of render-core.js a C motion transcribes: the pose data, the sequences, the dust colour and pixel rules, the terminal-to-pet mapping
C_LINES = ["3", "5", "106-125", "139-165"]
DUST = (153, 153, 153)


class Phase4Error(Exception):
    pass


# ---- the JavaScript of render-core.js line 3 and line 5, evaluated -----------------------------------------------------------------
def js_lines(path):
    with open(path, encoding="utf-8") as f:
        return f.read().split("\n")


def split_top(text):
    """Split `a=1,b=[2,3],c={d:4}` at the commas outside brackets, braces, parentheses and strings."""
    parts, depth, cur, quote = [], 0, "", None
    for ch in text:
        if quote:
            cur += ch
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
            cur += ch
        elif ch in "([{":
            depth += 1
            cur += ch
        elif ch in ")]}":
            depth -= 1
            cur += ch
        elif ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    return parts


def to_python(expr):
    """The JavaScript expressions of those two lines as Python: spread `...` is `*`, object keys are quoted, `===` is `==`, the one ternary and the one
    `.flatMap` are rewritten in place. Nothing else is accepted: the evaluator then fails on any other construct."""
    out = expr.replace("...", "*").replace("===", "==").replace("$", "_S_")
    out = re.sub(r"([{,])\s*([A-Za-z_]\w*)\s*:", lambda m: '%s"%s":' % (m.group(1), m.group(2)), out)
    out = out.replace('u%2==0?"left":"right"', '("left" if u%2==0 else "right")')
    out = re.sub(r"(\[[-\d,]+\])\.flatMap\(\(u\)=>", r"flat(\1, lambda u: ", out)
    return out


def xe(pose, count, opts=None):
    opts = opts or {}
    return [{"pose": pose, "offset": opts.get("offset", 0), "x": opts.get("x"), "poof": opts.get("poof"), "shadow": opts.get("shadow")} for _ in range(count)]


def uo(eyes, arms="down", feet="both"):
    return {"eyes": eyes, "arms": arms, "feet": feet}


def flat(items, fn):
    return [y for u in items for y in fn(u)]


# the four helper functions of line 5 as the source defines them: the evaluator above implements these bodies, and `check_helpers` refuses a source whose
# text for them differs
HELPERS = [
    'function _r(){return[{pose:"default",offset:1,poof:"dot"},{pose:"default",offset:1,poof:"wave"}]}',
    'function xe(u,d,{offset:m=0,x:p,poof:h,shadow:v}={}){return Array.from({length:d},()=>({pose:u,offset:m,x:p,poof:h,shadow:v}))}',
    'function kr(u,d){return u.flatMap((m)=>xe({facing:m},1,{shadow:d}))}',
    'function uo(u,d="down",m="both"){return{eyes:u,arms:d,feet:m}}',
]


def kr(names, shadow=None):
    return [f for m in names for f in xe({"facing": m}, 1, {"shadow": shadow})]


def underscore_r():
    return [{"pose": "default", "offset": 1, "x": None, "poof": "dot", "shadow": None}, {"pose": "default", "offset": 1, "x": None, "poof": "wave", "shadow": None}]


def declarations(statement):
    """{name: expression text} of a `var a=...,b=...;` statement."""
    body = statement[len("var "):]
    out = []
    for part in split_top(body):
        name, _, expr = part.partition("=")
        out.append((name.strip().replace("$", "_S_"), expr))
    return out


def evaluate(lines):
    """({pose name: parameters}, {motion key: [frame dicts]}, frame ms) read from lines 3 and 5 of render-core.js."""
    line3, line5 = lines[2], lines[4]
    for helper in HELPERS:
        if helper not in line5:
            raise Phase4Error("render-core.js line 5 no longer defines %s" % helper.split("{")[0])
    env = {"__builtins__": {}, "xe": xe, "uo": uo, "kr": kr, "_r": underscore_r, "flat": flat}
    m = re.match(r"var jo=(\{.*?\}),Xe=", line3)
    if not m:
        raise Phase4Error("render-core.js line 3 does not start with the pose table jo")
    jo = eval(to_python(m.group(1)), env)
    stmts = [s for s in re.split(r";(?=var |function )", line5)]
    # statement 1: constants; the function statements are skipped; the last `var` statement holds the sequences and Ho
    first = next(s for s in stmts if s.startswith("var ao="))
    for name, expr in declarations(first):
        env[name] = eval(to_python(expr), env)
    tail = stmts[-1]
    tail = tail[tail.index("var jg="):]
    for name, expr in declarations(tail):
        if name == "yu" or name == "hu":
            continue
        env[name] = eval(to_python(expr), env)
    ho = {k: [{"pose": f["pose"], "offset": f.get("offset", 0), "x": f.get("x"), "poof": f.get("poof"), "shadow": f.get("shadow")} for f in seq]
          for k, seq in env["Ho"].items()}
    return jo, ho, env["Wi"]


# ---- pixelParamsFor, pixelGrid and pixelFrameSVG (render-core.js:106-165) ----------------------------------------------------------
def params_for(pose, jo):
    f = jo[pose] if isinstance(pose, str) else pose
    if "facing" in f:
        return None
    p = {}
    if f["eyes"] == "left":
        p["eyeDx"] = -1
    if f["eyes"] == "right":
        p["eyeDx"] = 1
    if f["eyes"] == "closed":
        p["eyes"] = "closed"
    if f["eyes"] == "wink":
        p["eyes"] = "wink"
    if f["arms"] == "up":
        p["armL"] = -1
        p["armR"] = -1
    if f["arms"] == "one-up":
        p["armR"] = -1
    if f["feet"] == "left":
        p["legs"] = [2, 2, 1, 1]
    if f["feet"] == "right":
        p["legs"] = [1, 1, 2, 2]
    return p


def pixel_grid(p, width=12):
    """{(x, y): 'body' | 'eye'} of the 12 x 12 unit grid of pixelGrid (a wider grid only for the Ultra pose)."""
    g = {}

    def put(x, y, c):
        if 0 <= x < width and 0 <= y < UNITS:
            g[(x, y)] = c

    bt = 4
    arm_l, arm_r = p.get("armL", 0), p.get("armR", 0)
    for yy in range(6):
        for xx in range(2, 10):
            put(xx, bt + yy, "body")
    for dy in range(2):
        put(0, bt + 2 + arm_l + dy, "body")
        put(1, bt + 2 + arm_l + dy, "body")
        put(10, bt + 2 + arm_r + dy, "body")
        put(11, bt + 2 + arm_r + dy, "body")
    legs = p.get("legs", [2, 2, 2, 2])
    for i, lx in enumerate([2, 4, 7, 9]):
        for k in range(legs[i]):
            put(lx, bt + 6 + k, "body")
    ey, dx, eyes = bt + 1, p.get("eyeDx", 0), p.get("eyes", "open")
    if eyes == "open":
        put(3 + dx, ey, "eye")
        put(8 + dx, ey, "eye")
    elif eyes == "closed":
        for x in (3, 4, 7, 8):
            put(x + dx, ey, "eye")
    elif eyes == "wink":
        put(3 + dx, ey, "eye")
        put(7 + dx, ey, "eye")
        put(8 + dx, ey, "eye")
    return g


def js_round(v):
    """Math.round: halves go up."""
    return int(math.floor(Fraction(v) + Fraction(1, 2)))


def entrance_frame(frame, jo):
    """{(cell x, cell y): rgba} of one entrance-motion frame on the 24 x 24 cell canvas (pixelFrameSVG: shifted, clipped to rows 4..11 and columns 0..11,
    dust on top), or None for a side or back view."""
    p = params_for(frame["pose"], jo)
    if p is None:
        return None
    g = pixel_grid(p)
    dy = js_round(Fraction(frame["offset"] or 0) * 8 / 3)
    dx = js_round(Fraction(frame["x"] or 0) * 12 / 9)
    units = {}
    for (x, y), c in g.items():
        sx, sy = x + dx, y + dy
        if sx < 0 or sx >= UNITS or sy < 4 or sy >= UNITS:
            continue
        units[(sx, sy)] = PET_BODY if c == "body" else PET_EYE
    if frame["poof"] and (frame["offset"] or 0) > 0:
        dots = [(0, 11), (11, 11)] if frame["poof"] == "dot" else [(0, 10), (1, 11), (10, 11), (11, 10)]
        for d in dots:
            units[d] = DUST
    cells = {}
    for (x, y), c in units.items():
        for a in (0, 1):
            for b in (0, 1):
                cells[(2 * x + a, 2 * y + b)] = c + (255,)
    return cells


# ---- the C motions -----------------------------------------------------------------------------------------------------------------
def pose_boards(sequence, jo):
    """The board ids of the poses a sequence uses: B2 arms up, B3 eyes left or right, B4 wink or closed, B5 one foot up (B1 the rest pose)."""
    out = set()
    for f in sequence:
        pose = jo[f["pose"]] if isinstance(f["pose"], str) else f["pose"]
        if pose["arms"] == "up":
            out.add("B2")
        if pose["eyes"] in ("left", "right"):
            out.add("B3")
        if pose["eyes"] in ("wink", "closed"):
            out.add("B4")
        if pose["feet"] in ("left", "right"):
            out.add("B5")
    return sorted(out)


def eye_changes(sequence, jo):
    """The eye poses a sequence uses, named as the calm B3 and B4 motions name theirs: K1 refuses a look whose front layer covers an eye in a motion whose point is
    its eyes (spec 9b item 10), and a glance, a wink or closed eyes are exactly that."""
    names = {"left": "eyes:look-left", "right": "eyes:look-right", "wink": "eyes:wink", "closed": "eyes:closed"}
    out = set()
    for f in sequence:
        pose = jo[f["pose"]] if isinstance(f["pose"], str) else f["pose"]
        if pose["eyes"] in names:
            out.add(names[pose["eyes"]])
    return sorted(out)


def c_motion(P, art, rest, mid, board, key, uses, sequence, jo, src_sha):
    frames = []
    for k, f in enumerate(sequence):
        cells = entrance_frame(f, jo)
        if cells is None:
            raise Phase4Error("%s frame %d is a side or back view, which the pet does not draw" % (mid, k))
        frames.append(cells)
    m = P.Motion(mid, board, "redrawn", uses)
    m.nsrc = len(frames)
    m.source = {"kind": "redrawn", "path": SOURCE, "sha256": src_sha, "board": board, "lines": list(C_LINES), "sequence": key}
    m.clawd_colors = {P.PET_BODY, P.PET_EYE, SHADE_B}
    m.src_frames = list(range(len(frames)))
    m.flags = {"restStart": frames[0] == rest, "restEnd": frames[-1] == rest}
    if not m.flags["restStart"] and not m.flags["restEnd"]:
        m.flags["offRest"] = True                     # celebrate ends sunk, by Claude Code's own data (R5 pins it)
    m.stage = P.stage_of(frames)
    m.frames = [P.crop(c, m.stage) for c in frames]
    return m, frames


def c_finish(P, P2, m, frames, jo, sequence):
    heads = [P2.head_of_cells(P, c, m.clawd_colors) for c in frames]
    m.head = [hd for hd, _ in heads]
    m.rigid = all(hd is not None and ex for hd, ex in heads)
    body_like = {P.PET_BODY, SHADE_B}
    m.overhead_clear = all(hd is not None and all(c[:3] in body_like for (i, j), c in frames[k].items() if j < hd[1]) for k, (hd, _) in enumerate(heads))
    m.ms = [MS_PER_FRAME] * len(frames)
    m.weight = 1
    m.phase = 4
    effects = sorted([list(DUST)]) if any(DUST == c[:3] for fr in frames for c in fr.values()) else []
    m.extra = {"redraw": {"base": "render-core.js pixelFrameSVG", "changes": eye_changes(sequence, jo), "poses": pose_boards(sequence, jo), "effectColors": effects}}
    P.finish_uses(m)


# ---- B7, the Ultra pose --------------------------------------------------------------------------------------------------------------
def colours_of(lines):
    """The colours of render-core.js: CC_COLORS (lines 12-14), PX (line 106) and the winter palette (line 171), as rgb tuples."""
    def rgb(text):
        return tuple(int(v) for v in re.search(r"rgb\((\d+),(\d+),(\d+)\)", text).groups())
    out = {"wood": rgb(re.search(r'wood:\s*"[^"]*"', lines[13]).group(0)), "gold": rgb(re.search(r'gold:\s*"[^"]*"', lines[13]).group(0)),
           "ultraDark": rgb(re.search(r'ultraDark:\s*"[^"]*"', lines[12]).group(0)), "dust": rgb(re.search(r'dust:\s*"[^"]*"', lines[105]).group(0))}
    w = lines[170]
    for name in ("T", "I", "K"):
        out["winter" + name] = rgb(re.search(r'\b%s = "[^"]*"' % name, w).group(0))
    return out


# The wand and its star in unit pixels (x, y), y counted from the torso's top row (bt = 4 in the 12 x 12 grid): the board's trial for the Ultra card has the
# wood at (12, bt+1), (13, bt), (14, bt-1) and a gold plus centred at (15, bt-3); here the star is one unit nearer (14, bt-3), so that its right pixel
# (15) is the 4th unit beyond the canvas, the limit of R3, and its foot stands on the wood's end.
WAND_WOOD = [(12, 5), (13, 4), (14, 3)]
WAND_GOLD = [(14, 0), (13, 1), (14, 1), (15, 1), (14, 2)]
ULTRA_REST, ULTRA_POSE_FRAMES = 3, 18


def unit_cells(units, colour):
    return {(2 * x + a, 2 * y + b): colour + (255,) for (x, y) in units for a in (0, 1) for b in (0, 1)}


def ultra_pose_cells(lines):
    col = colours_of(lines)
    cells = {}
    for (x, y), c in pixel_grid({"armR": -1}).items():
        cells.update(unit_cells([(x, y)], PET_BODY if c == "body" else PET_EYE))
    cells.update(unit_cells(WAND_WOOD, col["wood"]))
    cells.update(unit_cells(WAND_GOLD, col["gold"]))
    return cells


def build_ultra_motion(P, P2, art, rest, lines, src_sha):
    pose = ultra_pose_cells(lines)
    frames = [dict(rest)] * ULTRA_REST + [pose] * ULTRA_POSE_FRAMES + [dict(rest)] * ULTRA_REST
    col = colours_of(lines)
    m = P2.redrawn_motion(P, art, rest, "B7-ultra-wand", "B7", ["signature:ultra"], frames, ["arm-right:lifted"], [col["wood"], col["gold"]])
    m.source = {"kind": "redrawn", "path": SOURCE, "sha256": src_sha, "board": "B7", "lines": list(ULTRA_LINES),
                "trial": {"path": BOARD_DATA, "sha256": P.sha256_file(os.path.join(art, BOARD_DATA)), "card": "ultracode header: arms one-up"}}
    m.extra["redraw"]["wand"] = {"wood": [list(p) for p in WAND_WOOD], "gold": [list(p) for p in WAND_GOLD], "armRows": [5, 6],
                                 "note": "the board's trial with the star one unit nearer (R3: the star's right pixel is the 4th unit beyond the canvas)"}
    m.phase = 4
    return m


ULTRA_LINES = ["3", "9", "13-14", "107-125", "139-152"]


# ---- the looks -----------------------------------------------------------------------------------------------------------------------
def shade_of(body, own_body=PET_BODY, own_shade=PET_SHADE):
    """The shade of a body colour: the pet's own shade-to-body ratio per channel, rounded half up."""
    return tuple((body[k] * own_shade[k] * 2 + own_body[k]) // (own_body[k] * 2) for k in range(3))


def body_map(body):
    sh = list(shade_of(body))
    return {"map": [{"from": list(PET_BODY), "to": list(body)}, {"from": list(PET_SHADE), "to": sh}, {"from": list(SHADE_B), "to": sh}]}


def winter_rows(lines):
    """The 2.0.67 rows of render-core.js:170-177 as [[(text, fg, bg), ...], ...] and the colours T, I, K."""
    col = colours_of(lines)
    palette = {"T": "rgb(%d,%d,%d)" % col["winterT"], "I": "rgb(%d,%d,%d)" % col["winterI"], "K": "rgb(%d,%d,%d)" % col["winterK"]}
    text = "[" + "\n".join(lines[172:175]) + "]"
    rows = eval(text, {"__builtins__": {}}, palette)
    return rows, palette


def winter_flakes(lines):
    """[(row, column)] of the '*' cells of the winter rows, and the first and last column of the body (the cells with a glyph in the body colour)."""
    rows, palette = winter_rows(lines)
    flakes, body_cols = [], []
    for r, runs in enumerate(rows):
        col = 0
        for run in runs:
            for ch in run[0]:
                if ch == "*":
                    flakes.append((r, col))
                elif ch != " " and run[1] == palette["I"]:
                    body_cols.append(col)
                col += 1
    return flakes, min(body_cols), max(body_cols)


def flake_cells(row, col, left):
    """The 2 x 2 cells (one unit) of a flake: the centre of its terminal cell under 1 column = 12/9 units, 1 row = 8/3 units, the body's left column at
    unit 0, the torso's top row at unit 4; the unit is the one whose centre is nearest (halves round up)."""
    cx = (Fraction(col - left) + Fraction(1, 2)) * 12 / 9
    cy = 4 + (Fraction(row) + Fraction(1, 2)) * 8 / 3
    x0, y0 = js_round(2 * cx) - 1, js_round(2 * cy) - 1
    return [(x0 + a, y0 + b) for a in (0, 1) for b in (0, 1)]


def snow_cells(lines):
    flakes, left, right = winter_flakes(lines)
    if right - left + 1 != 9:
        raise Phase4Error("the winter body is %d columns wide, the mapping needs the 9 of the 2.1 Clawd" % (right - left + 1))
    white = colours_of(lines)["winterT"] + (255,)
    cells = {}
    for (r, c) in flakes:
        for (x, y) in flake_cells(r, c, left):
            cells[(x - HEAD[0], y - HEAD[1])] = white
    return cells, flakes


def build_looks(P, P2, art, rest, lines, src_sha):
    col = colours_of(lines)
    files, looks = {}, {}
    rest_silhouette = {(x - HEAD[0], y - HEAD[1]) for (x, y) in rest}
    source = {"path": SOURCE[:-3], "ext": "js", "sha256": src_sha}

    ultra = {"id": "ultra", "board": "B7", "class": ["body-color"], "weight": 0.5, "signature": ["A25-spark", "B7-ultra-wand"], "anchor": None, "phase": 4,
             "bodyColor": dict(body_map(col["ultraDark"]), source={"path": SOURCE[:-3], "ext": "js", "sha256": src_sha, "key": "CC_COLORS.ultraDark",
                                                                  "binaryOffset": 199297306}),
             "layers": [], "layerOnSignature": False}
    looks["ultra"] = {"entry": ultra, "laydefs": [], "signature": ultra["signature"], "raiseCells": 0, "phase": 4, "restSilhouette": rest_silhouette,
                      "layerOnSignature": False}

    cells, flakes = snow_cells(lines)
    winter_body = col["winterI"]
    cut = {"kind": "snow", **source, "lines": "170-177", "flakes": [list(f) for f in flakes], "colour": list(col["winterT"]),
           "scale": {"unitsPerColumn": "12/9", "unitsPerRow": "8/3", "torsoTopUnit": 4, "unit": "2 x 2 cells"}}
    data, offset, size = P2.layer_png(P, cells)
    files["looks/winter/snow.png"] = data
    snow = {"name": "snow", "z": "back", "attach": "body", "png": "looks/winter/snow.png", "offset": offset, "size": size, "takesClicks": False, "cut": cut}
    winter = {"id": "winter", "board": "B8", "class": ["body-color"], "weight": 0.5, "signature": [], "anchor": "head", "phase": 4,
              "bodyColor": dict(body_map(winter_body), source={"path": SOURCE[:-3], "ext": "js", "sha256": src_sha, "key": "WINTER_ROWS.I"}),
              "layers": [snow], "layerOnSignature": True}
    laydef = P2.laydef("snow", "back", "body", cells, False, cut)
    looks["winter"] = {"entry": winter, "laydefs": [laydef], "signature": [], "raiseCells": 0, "phase": 4, "restSilhouette": rest_silhouette,
                       "layerOnSignature": True}
    return looks, files


def build(P, P2, art, motions, rest):
    """Returns (new motions, looks in catalog order as {id: look dict}, layer files, reports). `motions` are the earlier phases' motions."""
    for rel in (SOURCE, BOARD_DATA):
        if not os.path.isfile(os.path.join(art, rel)):
            raise Phase4Error("%s is missing" % rel)
    path = os.path.join(art, SOURCE)
    lines = js_lines(path)
    sha = P.sha256_file(path)
    jo, ho, ms = evaluate(lines)
    if ms != MS_PER_FRAME:
        raise Phase4Error("render-core.js gives %r ms per frame, the spec says 60" % ms)
    new = []
    for mid, board, key, uses, count in C_ITEMS:
        sequence = ho[key]
        if len(sequence) != count:
            raise Phase4Error("%s: the sequence %s has %d frames, the spec's duration gives %d" % (mid, key, len(sequence), count))
        m, frames = c_motion(P, art, rest, mid, board, key, uses, sequence, jo, sha)
        c_finish(P, P2, m, frames, jo, sequence)
        new.append(m)
    new.append(build_ultra_motion(P, P2, art, rest, lines, sha))
    looks, files = build_looks(P, P2, art, rest, lines, sha)
    return new, looks, files, {}
