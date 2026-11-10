#!/usr/bin/env python3
"""Phase 3 art of the pet (spec v2 sections 3.1-3.4, 9b items 2 and 10, Sprint 7): the three plushie looks and the plushie's happy face. This is a
module of scripts/port-official-art.py (which loads it by path and calls `build`, after scripts/port-phase2-art.py); it is not run on its own.

Sources (copied into art/sources/plush/, none fetched; their sha256 goes into the catalog): the five official plushie pictures of the reference
board (claude.dev/terminal /plushies), 480 x 480 RGBA photographs of 3D plush toys:
  wizard.png (D15)   a blue slouch hat with yellow stars and a navy band, and a star wand held at the right
  cowboy.png (D16)   a brown hat with a grey-brown band
  scientist.png (D17) black goggles with a grey lens, a grey open lab coat, a blue flask held at the right
  happy.png (D19)    the `^ ^` face
  sunglasses.png (D18) the check of the phase 1 sunglasses (nothing is built from it)

Production route (the brief's "front-view pixel outfits only"; the photos are 3D, so shapes are translated and shading is not):
  The body is the pet's own rest pose, so only the outfit is drawn. Each look is a set of layers of cells relative to the head anchor, drawn by hand
  as rows of letters (below), in the colours of the photograph:
    shape     the registration is the plush's own: the body of each photograph (the orange torso with its arms) is 24 cells wide, so one cell is
              about 13 to 14 px; the brim of a hat and the width of the goggles and of the coat keep their proportion to that body (a brim 22 cells,
              a torso 16). Vertically a hat sits with its lower edge on the cell row above the eyes (the photographs show the eyes right under
              the brim) and is squashed to the 4 units R3 allows above the torso: the photographed crown is 7 to 9 rows tall, the pet's 5 to 6.
              The wizard's crown keeps the lean and the bent tip of the photograph, the cowboy's its pinched crown and tilted brim, the
              scientist's goggles keep the strap that runs past the head, the lens and the dip over the nose, the coat its two panels with
              the open front and the lighter lapels, and the flask its neck, shoulder and the darker liquid.
    colour    each letter names a role, and a role's colour is the mean colour of a rectangle of the photograph (recorded in the catalog, recomputed
              by the checker): a flat patch whose mean is the median colour of that part of the plush, so the shading of the photograph is
              not drawn. The goggles' black is the pet's own near-black rgb(20,20,19) (the photograph's frame is within 8 of it), as A17's glasses are.
  The goggles sit above the eyes (rows -2 to +1 of the head, the eyes are rows +2 and +3), like goggles pushed up on the forehead: a lens over the
  eyes would hide them, and K1 refuses an eye-covering look every motion whose point is the eyes (D4, D19, the glances, the winks), so the scientist
  would keep 2 compatible idle motions. The coat's sleeves are not drawn: an arm moves in most motions and a sleeve at its rest place
  would hang in the air, and the held flask needs the arm.
  D18 sunglasses: the phase 1 look is cut from A17 and is not redrawn; `d18_report` compares its layer with the photograph (colour, width against the head,
  a full-width bar over a pair of lenses with a bridge between them) and records the numbers in reports/plush-sunglasses-comparison.json, which
  the checker recomputes. The photograph's lenses are about 2.2 times taller in proportion to their width than A17's; that is a difference in
  proportion of the plush, not of the design, and the look is unchanged.
  D19 happy `^ ^`: the eyes are the `^ ^` of A3 JumpingHappy (frames 7 to 10, the official pixels, kept as they are relative to the head), drawn on
  the rest pose like D4: rest, 14 frames of the face, rest.

K1 for these looks is the rules of scripts/port-phase2-art.py (held props never leave the hand, no front layer on an effect pixel or on the eyes
of an eye expression); this module only declares the layers.
"""
import hashlib
import os

CANVAS = 24
HEAD = (12, 8)
PET_EYE = (20, 20, 19)
PLUSH = {"D15": "sources/plush/wizard.png", "D16": "sources/plush/cowboy.png", "D17": "sources/plush/scientist.png",
         "D18": "sources/plush/sunglasses.png", "D19": "sources/plush/happy.png"}
OFFICIAL_BLACK_TOLERANCE = 8        # a `black` role takes the pet's near-black when the photograph's patch is within this of it, per channel
CARET_MOTION, CARET_FRAME = "A3-jumping-happy", 7      # frames 7 to 10 of A3 JumpingHappy show the `^ ^`


class Phase3Error(Exception):
    pass


# role letter -> {"rect": [x0, y0, x1, y1] (inclusive, picture pixels), "snap": "pet-eye" (optional)}; the catalog adds "rgb"
ROLES = {
    "wizard": {"b": {"rect": [237, 104, 244, 111]},       # the hat: the median blue of the hat
              "n": {"rect": [158, 190, 163, 195]},         # the band
              "s": {"rect": [302, 143, 304, 145]},         # a star on the hat
              "g": {"rect": [403, 230, 408, 235]},         # the star of the wand
              "w": {"rect": [314, 335, 316, 337]}},        # the stick of the wand
    "cowboy": {"b": {"rect": [195, 136, 202, 143]},       # the hat
               "g": {"rect": [142, 193, 147, 198]}},       # the band
    "scientist": {"k": {"rect": [185, 195, 188, 198], "snap": "pet-eye"},    # goggle frame and strap
                  "l": {"rect": [226, 157, 233, 164]},     # the lens
                  "c": {"rect": [157, 285, 164, 292]},     # the coat
                  "p": {"rect": [186, 238, 190, 242]},     # the lapels
                  "e": {"rect": [388, 190, 391, 193]},     # the flask's neck
                  "q": {"rect": [428, 247, 433, 252]}},    # the flask's liquid
}

# Layer patterns: rows of role letters, "." transparent, the top-left cell at `at` = (dx, dy) from the head anchor (the middle of the torso's top
# row, canvas cell (12, 8)); the torso is dx -8..7, dy 0..11, the eyes dy 2..3, the right arm's rest place dx 8..11, dy 4..7.
LAYERS = {
    "wizard": {
        # a slouch hat leaning left with its tip bent over, a navy band, a brim that curls up at both ends; stars in the photograph's yellow
        "hat": {"at": (-11, -8), "rows": [
            "..bbb.................",
            "..bsbbbb..............",
            "..bbbbbbbbb...........",
            "..bbbbbbsbbbbb........",
            "..bbbbbbbbbbbsbbbbb...",
            "...nnnnnnnnnnnnnnnn...",
            "...nnnnnnnnnnnnnnnn...",
            "bbbbbbbbbbbbbbbbbbbbbb",
            ".bbbbsbbbbbbbbbsbbbbb.",
            "...bbbbbbbbbbbbbbbb..."]},
        # the star wand: the stick from the hand up to a star beside the brim (A25 draws its own wand, so this layer is not drawn on it)
        "wand": {"at": (12, -3), "rows": [
            "...g..",
            "..ggg.",
            ".ggggg",
            "..ggg.",
            "..g.g.",
            "..w...",
            ".w....",
            ".w....",
            "w.....",
            "w....."]},
    },
    "cowboy": {
        # a pinched crown, a grey-brown band, a brim that rises at the right
        "hat": {"at": (-11, -8), "rows": [
            "......bbbb..bbbb......",
            ".....bbbbbbbbbbbb.....",
            "....bbbbbbbbbbbbbb....",
            "....bbbbbbbbbbbbbb....",
            "....bbbbbbbbbbbbbb....",
            "....gggggggggggggg....",
            "....gggggggggggggg....",
            "...bbbbbbbbbbbbbbbbbb.",
            ".bbbbbbbbbbbbbbbbbbbbb",
            "bbbbbbbbbbbbbbbbbbbbb."]},
    },
    "scientist": {
        # goggles pushed up on the forehead: the strap runs past the head, a two-row lens between black frames, a dip over the nose
        "goggles": {"at": (-9, -2), "rows": [
            "..kkkkkkkkkkkkkk..",
            "kkkkllllllllllkkkk",
            "kkkkllllllllllkkkk",
            "..kkkkkk..kkkkkk.."]},
        # an open coat: a grey panel at each side, lighter lapels at the top, the front open over the belly
        "coat": {"at": (-8, 5), "rows": [
            "ccccpp....ppcccc",
            "ccccpp....ppcccc",
            "cccccp....pccccc",
            "cccccc....cccccc",
            "cccccc....cccccc",
            "cccccc....cccccc",
            "cccccc....cccccc"]},
        # an Erlenmeyer flask held at the right hand: neck, shoulder, liquid
        "flask": {"at": (11, 0), "rows": [
            "..ee..",
            "..ee..",
            "..ee..",
            ".eeee.",
            ".eeee.",
            "eeeeee",
            "qqqqqq",
            "qqqqqq",
            "qqqqqq",
            ".qqqq."]},
    },
}


# ---- the pixels ----------------------------------------------------------------------------------------------------------------
def patch_mean(P, art, picture, rect):
    """The mean colour of a rectangle of a photograph, rounded per channel; every pixel of the rectangle must be opaque."""
    w, h, rows = P.read_png(os.path.join(art, picture))
    x0, y0, x1, y1 = rect
    if not (0 <= x0 <= x1 < w and 0 <= y0 <= y1 < h):
        raise Phase3Error("%s: the rectangle %s lies outside the %d x %d picture" % (picture, rect, w, h))
    total, n = [0, 0, 0], 0
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            r, g, b, a = rows[y][x * 4:x * 4 + 4]
            if a != 255:
                raise Phase3Error("%s: pixel (%d, %d) of the rectangle %s is not opaque" % (picture, x, y, rect))
            total[0] += r
            total[1] += g
            total[2] += b
            n += 1
    return tuple((v * 2 + n) // (2 * n) for v in total)


def role_colours(P, art, board, look):
    """{letter: {"rect", "rgb"[, "snap"]}} of one look: the mean of each photograph patch, or the pet's near-black for a `snap` role."""
    picture = PLUSH[board]
    out = {}
    for letter, spec in ROLES[look].items():
        mean = patch_mean(P, art, picture, spec["rect"])
        entry = dict(spec)
        if spec.get("snap") == "pet-eye":
            if any(abs(mean[k] - PET_EYE[k]) > OFFICIAL_BLACK_TOLERANCE for k in range(3)):
                raise Phase3Error("%s: the patch %s of role %s has mean %s, not within %d of the pet's near-black" % (
                    picture, spec["rect"], letter, mean, OFFICIAL_BLACK_TOLERANCE))
            entry["rgb"] = list(PET_EYE)
        else:
            entry["rgb"] = list(mean)
        out[letter] = entry
    return out


def pattern_cells(at, rows, colours):
    """{(dx, dy): rgba} of a pattern of role letters; the rows must be as wide as the first."""
    if len({len(r) for r in rows}) != 1:
        raise Phase3Error("pattern rows differ in width: %s" % sorted({len(r) for r in rows}))
    out = {}
    for r, row in enumerate(rows):
        for c, ch in enumerate(row):
            if ch != ".":
                if ch not in colours:
                    raise Phase3Error("pattern letter %r names no role" % ch)
                out[(at[0] + c, at[1] + r)] = tuple(colours[ch]["rgb"]) + (255,)
    return out


def layer_cut(P, art, board, look, name, colours):
    """The catalog's cut of one layer: where the colours come from and the pattern itself."""
    lay = LAYERS[look][name]
    used = sorted({ch for row in lay["rows"] for ch in row if ch != "."})
    picture = PLUSH[board]
    return {"kind": "plush", "path": picture[:-4], "ext": "png", "sha256": P.sha256_file(os.path.join(art, picture)),
            "at": list(lay["at"]), "roles": {k: colours[k] for k in used}, "rows": list(lay["rows"])}


# ---- the looks -----------------------------------------------------------------------------------------------------------------
# id, board, classes, weight, anchor, signature, layerOnSignature, [(layer name, z, attach, takesClicks)]
LOOKS = [
    # no signature (main session, spec 9b item 12): A25 draws its own wand but no hat, and a look is all layers or none, so the hat would vanish on it
    ("wizard", "D15", ["costume", "held"], 1, "head+arm-right", [], True,
     [("hat", "front", "head", True), ("wand", "front", "arm-right", False)]),
    ("cowboy", "D16", ["costume"], 1, "head", [], True, [("hat", "front", "head", True)]),
    # no signature (main session, spec 9b item 12): A14 raises the arm away from the flask in 38 of 50 frames, and a held prop never floats
    ("scientist", "D17", ["costume", "torso-overlay", "held"], 1, "head+arm-right", [], True,
     [("goggles", "front", "head", True), ("coat", "front", "torso", True), ("flask", "front", "arm-right", False)]),
]


def build_looks(P, P2, art, rest):
    files, looks = {}, {}
    rest_silhouette = {(x - HEAD[0], y - HEAD[1]) for (x, y) in rest}
    for lid, board, classes, weight, anchor, signature, on_signature, layers in LOOKS:
        colours = role_colours(P, art, board, lid)
        laydefs, entries = [], []
        for name, z, attach, clicks in layers:
            lay = LAYERS[lid][name]
            cells = pattern_cells(lay["at"], lay["rows"], colours)
            laydefs.append(P2.laydef(name, z, attach, cells, clicks, layer_cut(P, art, board, lid, name, colours)))
        entry = {"id": lid, "board": board, "class": classes, "weight": weight, "signature": signature, "anchor": anchor, "phase": 3}
        for lay in laydefs:
            rel = "looks/%s/%s.png" % (lid, lay["name"])
            data, offset, size = P2.layer_png(P, lay["cells"])
            files[rel] = data
            e = {"name": lay["name"], "z": lay["z"], "attach": lay["attach"], "png": rel, "offset": offset, "size": size,
                 "takesClicks": lay["takesClicks"], "cut": lay["cut"]}
            entries.append(e)
        entry["layers"] = entries
        entry["layerOnSignature"] = on_signature
        looks[lid] = {"entry": entry, "laydefs": laydefs, "signature": signature, "raiseCells": 0, "phase": 3, "restSilhouette": rest_silhouette, "layerOnSignature": on_signature}
    return looks, files


# ---- D18: the phase 1 sunglasses against the plushie's ------------------------------------------------------------------------------
D18 = {"blackMax": 60, "mergePx": 2, "barMin": 0.85, "lensMin": 0.15, "colourTolerance": 12, "gapTolerance": 0.1, "widthTolerance": 0.25,
       "headRowsAbove": 12}


def runs_of(row, merge):
    """[(first, last)] of the runs of True in a row of booleans; a gap of at most `merge` entries does not split a run."""
    runs = []
    for x, v in enumerate(row):
        if v:
            if runs and x - runs[-1][1] - 1 <= merge:
                runs[-1][1] = x
            else:
                runs.append([x, x])
    return [tuple(r) for r in runs]


def glasses_structure(mask, merge):
    """The shape of a pair of sunglasses given as rows of booleans: its size, the first row of a bar (one run of at least D18.barMin of the width), the
    lens rows below it (two runs of at least D18.lensMin of the width each) and the narrowest gap between the lenses over those rows (the bridge over the nose)
    as a fraction of the width."""
    rows = [runs_of(r, merge) for r in mask]
    xs = [x for r in rows for a, b in r for x in (a, b)]
    width = max(xs) - min(xs) + 1
    bar = next((y for y, r in enumerate(rows) if len(r) == 1 and r[0][1] - r[0][0] + 1 >= D18["barMin"] * width), None)
    lens = [r for y, r in enumerate(rows) if bar is not None and y > bar and len(r) == 2 and all(b - a + 1 >= D18["lensMin"] * width for a, b in r)]
    gaps = [r[1][0] - r[0][1] - 1 for r in lens]
    gap = None if not gaps else round(min(gaps) / width, 3)
    return {"width": width, "height": len(rows), "barRow": bar, "lensRows": len(lens), "bridgeFraction": gap}


def d18_report(P, art, sunglasses_cells):
    """The comparison of the phase 1 sunglasses layer (cells relative to the head, as {(dx, dy): colour}) with the plushie photograph."""
    w, h, rows = P.read_png(os.path.join(art, PLUSH["D18"]))
    black = [[rows[y][x * 4 + 3] == 255 and max(rows[y][x * 4:x * 4 + 3]) < D18["blackMax"] for x in range(w)] for y in range(h)]
    ys = [y for y in range(h) if any(black[y])]
    xs = [x for x in range(w) if any(black[y][x] for y in range(h))]
    box = (min(xs), min(ys), max(xs), max(ys))
    plush = glasses_structure([r[box[0]:box[2] + 1] for r in black[box[1]:box[3] + 1]], D18["mergePx"])
    n = sum(1 for y in range(h) for x in range(w) if black[y][x])
    mean = [(sum(rows[y][x * 4 + k] for y in range(h) for x in range(w) if black[y][x]) * 2 + n) // (2 * n) for k in range(3)]
    spans = []
    for y in range(box[1] - D18["headRowsAbove"], box[1]):
        got = [x for x in range(w) if rows[y][x * 4 + 3] == 255 and rows[y][x * 4] > 140 and 30 < rows[y][x * 4 + 1] < 150
               and rows[y][x * 4 + 2] < 100 and rows[y][x * 4] - rows[y][x * 4 + 1] > 50]
        if got:
            spans.append(max(got) - min(got) + 1)
    head = max(spans)
    x0, x1 = min(c[0] for c in sunglasses_cells), max(c[0] for c in sunglasses_cells)
    y0, y1 = min(c[1] for c in sunglasses_cells), max(c[1] for c in sunglasses_cells)
    pet = glasses_structure([[(x, y) in sunglasses_cells for x in range(x0, x1 + 1)] for y in range(y0, y1 + 1)], 0)
    pet_colour = sorted({tuple(c[:3]) for c in sunglasses_cells.values()})
    torso = 16
    ratios = {"plush": round(plush["width"] / head, 3), "pet": round(pet["width"] / torso, 3)}
    ok = (all(abs(mean[k] - PET_EYE[k]) <= D18["colourTolerance"] for k in range(3)) and pet_colour == [PET_EYE]
          and plush["barRow"] is not None and pet["barRow"] is not None and plush["lensRows"] > 0 and pet["lensRows"] > 0
          and plush["bridgeFraction"] is not None and pet["bridgeFraction"] is not None
          and abs(plush["bridgeFraction"] - pet["bridgeFraction"]) <= D18["gapTolerance"] and abs(ratios["plush"] - ratios["pet"]) <= D18["widthTolerance"])
    return {"picture": PLUSH["D18"][:-4], "ext": "png", "sha256": P.sha256_file(os.path.join(art, PLUSH["D18"])), "rules": D18,
            "plush": {"blackBox": list(box), "blackMean": mean, "headWidthPx": head, **plush},
            "pet": {"cells": [x1 - x0 + 1, y1 - y0 + 1], "colours": [list(c) for c in pet_colour], "torsoCells": torso, **pet},
            "widthOverHead": ratios, "heightOverWidth": {"plush": round(plush["height"] / plush["width"], 3), "pet": round(pet["height"] / pet["width"], 3)},
            "verdict": "match" if ok else "differ"}


# ---- D19: the plushie's `^ ^` ----------------------------------------------------------------------------------------------------
def caret_eyes(motions):
    """The eye cells of A3 JumpingHappy's `^ ^` frame relative to its head anchor: {(dx, dy)}."""
    m = next(x for x in motions if x.id == CARET_MOTION)
    hx, hy = m.head[CARET_FRAME]
    cells = m.cells[CARET_FRAME]
    eyes = {(i - hx, j - hy) for (i, j), c in cells.items() if c[:3] == PET_EYE and 0 <= j - hy < 12 and -8 <= i - hx < 8}
    if len(eyes) != 8:
        raise Phase3Error("%s frame %d: %d eye cells, want the 8 of the `^ ^`" % (CARET_MOTION, CARET_FRAME, len(eyes)))
    return eyes


def build_caret(P, P2, art, motions, rest):
    eyes = caret_eyes(motions)
    face = P2.plain_body(P, rest)
    for (dx, dy) in eyes:
        face[(HEAD[0] + dx, HEAD[1] + dy)] = PET_EYE + (255,)
    m = P2.redrawn_motion(P, art, rest, "D19-happy-caret", "D19", ["touch", "sent"], [rest] + [face] * 14 + [rest], ["eyes:carets"], [])
    picture = PLUSH["D19"]
    m.source = {"kind": "redrawn", "picture": picture[:-4], "ext": "png", "sha256": P.sha256_file(os.path.join(art, picture)), "board": "D19"}
    m.extra["redraw"]["glyph"] = {"motion": CARET_MOTION, "frame": CARET_FRAME}
    m.phase = 3
    return m


def build(P, P2, art, motions, rest, sunglasses_cells):
    """Returns (new motions, looks in catalog order as {id: look dict}, layer files, reports). `motions` are the phase 1 motions with their cells,
    `sunglasses_cells` the phase 1 sunglasses layer {(dx, dy): colour}."""
    for board, rel in PLUSH.items():
        if not os.path.isfile(os.path.join(art, rel)):
            raise Phase3Error("%s is missing" % rel)
    looks, files = build_looks(P, P2, art, rest)
    report = d18_report(P, art, sunglasses_cells)
    if report["verdict"] != "match":
        raise Phase3Error("D18: the phase 1 sunglasses do not match the plushie's by the recorded rules: %s" % report)
    return [build_caret(P, P2, art, motions, rest)], looks, files, {"d18": report}
