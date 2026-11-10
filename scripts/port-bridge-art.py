#!/usr/bin/env python3
"""Phase 5 art of the pet (smooth round 2): the in-between pictures at five seams where one frame changes too many cells at once.

This is a module of scripts/port-official-art.py (which loads it by path and calls `build`, after scripts/port-phase4-art.py); it is not run on its
own. The shipped motions and poses are NOT edited: each in-between picture is a bridge, a short run of frames the stage plays just before (`lead`)
or just after (`tail`) the frames of its target, so the checks of the ported and transcribed frames keep their meaning (P1 source identity, R5 the
render-core.js transcription). A bridge has no source pixels; it is derived here from the shipped target frames and the v1 rest picture, cell by
cell, by the rules below, and scripts/check-art-contract.py (v2:BR) recomputes its constraints from the PNGs alone.

The seams (cells = changed cells of the composed picture in the plain look; "before" is the one frame that changed them all at once):
  1. D14-ride tail, 2 frames: the skateboard stop's crouch (frame 38) rises to the rest picture. The crouch is the rest body lowered 2 rows with the
     eyes 5-6 rows low and the right arm hanging; the two frames raise the head top, the eyes, the right arm and the legs by turns.
  2. dangle lead, 1 frame (the drag pick-up): the rest picture to dangle#0 (head 2 cells up, arms 4 up, legs 2 longer), halfway on every feature.
  3. C1-jump, C2-celebrate, C11-boop lead, 1 frame each (the crouch start): the rest body sunk 3 cells (half of the 6 the first frame sinks it),
     clipped at the baseline as render-core.js's pixelFrameSVG clips it, with no dust (the dust arrives with the squash proper).
  4. hop lead, 1 frame (the sent scene): the rest picture to hop#0 (head 2 cells up, arms 4 up, feet 2 up), halfway on every feature.
  5. A34-arcade lead and tail, 3 frames each: the cabinet slides in from the right edge (12, 7 and 3 cells from home) while Clawd turns from the
     rest picture through a three-quarter view (A6-turning's own turn shading, then the same two-run silhouette interpolated towards frame 0) to
     frame 0's side view; the tail plays the same three pictures backwards.
The cabinet's own cells are frame 0's non-Clawd cells; where Clawd hides the cabinet in every frame (its left edge) the cells come from the other
frames of the motion, and a few cells at the left edge that no frame shows are filled from the neighbouring rows (FILL below).

Every cell of a bridge has a colour of the target's own frames; nothing is blended or anti-aliased.
"""
import os

CANVAS = 24
BODY = (215, 119, 87)
SHADE = (190, 104, 77)
SHADE_B = (191, 105, 77)
EYE = (20, 20, 19)
CLAWD = {BODY, SHADE, SHADE_B, EYE}
RAISE = 6                     # the skateboard look's raise in cells: D14-ride is stored this much lower than it is composed
MS_C = 60                     # a C item's frame time (render-core.js)
MS_POSE = 60                  # the lead of dangle and hop
BRIDGE_DIR = "bridges"


class BridgeError(Exception):
    pass


# ---- cells and grids ---------------------------------------------------------------------------------------------------------
def rgb(c):
    return tuple(c[:3])


def grid_to_cells(grid, left, up):
    """{(i, j): (r, g, b)} in canvas cell coordinates of a stage grid whose cell (x, y) is canvas cell (x - left, y - up)."""
    out = {}
    for y, row in enumerate(grid):
        for x, c in enumerate(row):
            if c is not None:
                if len(c) == 4 and c[3] != 255:
                    raise BridgeError("a translucent cell in a source frame at %r" % ((x, y),))
                out[(x - left, y - up)] = rgb(c)
    return out


def cells_to_grid(cells, stage):
    left, right, up, down = stage
    w, h = CANVAS + left + right, CANVAS + up + down
    grid = [[None] * w for _ in range(h)]
    for (i, j), c in cells.items():
        x, y = i + left, j + up
        if not (0 <= x < w and 0 <= y < h):
            raise BridgeError("cell %r lies outside the stage %r" % ((i, j), stage))
        grid[y][x] = rgb(c) + (255,)
    return grid


def changed(a, b):
    return sum(1 for k in set(a) | set(b) if a.get(k) != b.get(k))


def head_of(P, cells, stage):
    """The head anchor of a frame by the rule of scripts/port-official-art.py (the exact head block, else the face fallback), in canvas cells."""
    left, right, up, down = stage
    grid = cells_to_grid(cells, stage)
    w, h = len(grid[0]), len(grid)
    blocks = P.face_blocks(grid, w, h, CLAWD)
    if blocks:
        top = min(j for _, j in blocks)
        row = [i for i, j in blocks if j == top]
        if len(row) == 1:
            return (row[0] + P.FACE_W // 2 - left, top - up)
    fa = P.face_anchor(grid, w, h, CLAWD)
    return None if fa is None else (fa[0] - left, fa[1] - up)


def row_fill(cells, y, x0, x1, colour):
    for x in range(x0, x1 + 1):
        cells[(x, y)] = colour


# ---- 2 and 4: the pose frames of the drag pick-up and the sent scene ---------------------------------------------------------------
def upright(top, arm_top, leg_top, leg_rows, last_pair):
    """The v1 pose's body at cell resolution: the 16-wide torso from row `top` for 12 rows, the eyes two rows below the top, 4-row arms (24 wide)
    from `arm_top`, four 2-wide legs from `leg_top` (`leg_rows` full rows, then `last_pair` rows with only the legs at x 4 and 14: the swing of the
    dangle). Rest is (8, 12, 20, 4, 0), dangle#0 (6, 8, 18, 4, 2), hop#0 (6, 8, 18, 4, 0)."""
    p = {}
    for y in range(top, top + 12):
        row_fill(p, y, 4, 19, BODY)
    for y in range(arm_top, arm_top + 4):
        row_fill(p, y, 0, 23, BODY)
    for y in (top + 2, top + 3):
        for x in (6, 7, 16, 17):
            p[(x, y)] = EYE
    for y in range(leg_top, leg_top + leg_rows):
        for lx in (4, 8, 14, 18):
            row_fill(p, y, lx, lx + 1, BODY)
    for y in range(leg_top + leg_rows, leg_top + leg_rows + last_pair):
        for lx in (4, 14):
            row_fill(p, y, lx, lx + 1, BODY)
    return p


def lead_pose(P, rest, kind, stage_cells):
    """The lead frame of the dangle (the drag) or the hop (the sent scene): every feature of the pose half way between the rest picture and the pose's
    first frame (head and torso 1 up, arms 2 up, legs 1 longer or the feet 1 up). The builders reproduce the three shipped pictures cell for cell."""
    if upright(8, 12, 20, 4, 0) != {k: rgb(v) for k, v in rest.items()}:
        raise BridgeError("the pose builder does not reproduce the rest picture")
    if upright(6, 8, 18, 4, 2 if kind == "dangle" else 0) != stage_cells:
        raise BridgeError("the pose builder does not reproduce %s#0" % kind)
    if kind == "dangle":
        return upright(7, 10, 19, 4, 1)
    return upright(7, 10, 19, 4, 0)


# ---- 3: the C items' crouch start ---------------------------------------------------------------------------------------------
def lead_squash(rest, first, sink_first):
    """The rest picture sunk by half of the first frame's sink, clipped at the baseline (render-core.js's pixelFrameSVG clips the body the same way),
    without the dust. Checks that the first frame is the rest body sunk by `sink_first` plus nothing but the dust."""
    def sunk(n):
        return {(x, y + n): c for (x, y), c in rest.items() if y + n < CANVAS}
    body = {k: c for k, c in first.items() if c in CLAWD}
    if body != sunk(sink_first):
        # the closed eyes of the boop are the rest body with its eyes replaced: only the eyes may differ
        diff = {k for k in set(body) | set(sunk(sink_first)) if body.get(k) != sunk(sink_first).get(k)}
        if any(body.get(k, EYE) != EYE and sunk(sink_first).get(k, EYE) != EYE for k in diff):
            raise BridgeError("the first frame is not the rest body sunk by %d" % sink_first)
    return sunk(sink_first // 2)


# ---- 1: the skateboard's stop rises to the rest picture ---------------------------------------------------------------------------
def ride_body(board, top, bottom, eye_l, eye_r, arm_top, hand, tilt):
    """The ride's body in composed rows (the skateboard look; the stored frame is RAISE rows lower): the 16-wide core from `top` to `bottom`, the left
    arm at rows 6-9, the right arm (4 x 4 from `arm_top`) or the low hand, 2x2 eyes at x 6 and 16, four legs from row bottom + 1 to the board, the
    first leg row shaded when the legs are shorter than at rest."""
    p = dict(board)
    for y in range(top, bottom + 1):
        row_fill(p, y, 4, 16 if (tilt and y == top) else 19, BODY)
    for y in range(6, 10):
        row_fill(p, y, 0, 3, BODY)
    if arm_top is not None:
        for y in range(arm_top, arm_top + 4):
            row_fill(p, y, 20, 23, BODY)
    leg_top = bottom + 1
    for lx in (4, 8, 14, 18):
        if lx == 18 and hand:
            continue
        for y in range(leg_top, 18):
            row_fill(p, y, lx, lx + 1, BODY)
        if leg_top > 14:
            row_fill(p, leg_top, lx, lx + 1, SHADE)
    if hand:
        p[(20, 15)] = BODY
        row_fill(p, 16, 17, 20, BODY)
        row_fill(p, 17, 17, 19, BODY)
    for ex, ey in ((6, eye_l), (16, eye_r)):
        for dx in (0, 1):
            for dy in (0, 1):
                p[(ex + dx, ey + dy)] = EYE
    return p


def ride_tail(stored_last, rest):
    """The two frames after D14-ride's last frame (the stop's crouch): the head top, the eyes, the right arm and the legs rise by turns. Returns the
    two frames in stored coordinates (RAISE rows lower than composed)."""
    board = {(x, y - RAISE): c for (x, y), c in stored_last.items() if c not in CLAWD}
    f38 = ride_body(board, 4, 15, 9, 10, None, True, True)
    if {(x, y + RAISE): c for (x, y), c in f38.items()} != stored_last:
        raise BridgeError("the ride builder does not reproduce D14-ride's last frame")
    at_rest = ride_body(board, 2, 13, 4, 4, 6, False, False)
    if {k: c for k, c in at_rest.items() if c in CLAWD} != {(x, y - RAISE): rgb(c) for (x, y), c in rest.items() if rgb(c) in CLAWD}:
        raise BridgeError("the ride builder does not reproduce the rest body")
    a = ride_body(board, 3, 15, 7, 8, 11, False, True)
    b = ride_body(board, 3, 13, 6, 5, 9, False, False)
    return [{(x, y + RAISE): c for (x, y), c in f.items()} for f in (a, b)]


# ---- 5: the arcade ----------------------------------------------------------------------------------------------------------------
# cabinet cells that no frame of the motion shows (Clawd covers them in all 49): the left border of the screen on rows 12 and 13, the panel's first
# cell on row 14 and the base's two dark cells on rows 20-23 (the border post at x 14 is shown)
ARC_BORDER, ARC_DARK, ARC_PANEL, ARC_BASE = (87, 80, 161), (20, 17, 51), (145, 139, 214), (39, 35, 89)
FILL = dict([((16, 12), ARC_BORDER), ((17, 12), ARC_DARK), ((16, 13), ARC_BORDER), ((17, 13), ARC_DARK), ((17, 14), ARC_PANEL)]
            + [((x, y), ARC_BASE) for y in range(20, 24) for x in (15, 16)])
SLIDE = (12, 7, 3)            # cells the cabinet is right of home in the three lead frames
TURN = (0.0, 0.35, 0.55)      # how far Clawd has turned in them: 0 the rest picture, then A6-turning's shading, then the side view
ARC_TURN_FRAME = 8            # A6-turning's frame whose silhouette is the first step of the turn


def rnd(v):
    return int(v + 0.5) if v >= 0 else -int(-v + 0.5)


def lerp(a, b, t):
    return a + (b - a) * t


def turned(t, shade):
    """Clawd between A6-turning's three-quarter view (t = 0: the left three columns shaded, eyes at x 9 and 17) and the arcade's side view (t = 1: 13
    columns shaded, no eyes, the legs at 1, 5, 11, 15): the same two runs of every row (shade, lit) with their ends interpolated."""
    p = {}
    for y in range(8, 20):
        arm = 12 <= y <= 15
        a0 = (0, 22) if arm else (4, 19)
        a1 = (1, 20) if arm else (1, 16)
        x0, x1 = rnd(lerp(a0[0], a1[0], t)), rnd(lerp(a0[1], a1[1], t))
        edge = rnd(lerp(2 if arm else 6, 17 if arm else 13, t))
        for x in range(x0, x1 + 1):
            p[(x, y)] = shade if x <= edge else BODY
        if y in (10, 11) and not arm and t < 1:
            for ex in (9, 17):
                xe = rnd(lerp(ex, ex - 3, t))
                if xe > edge and xe + 1 <= x1 and (ex == 17 or t < 0.5):
                    p[(xe, y)] = EYE
                    p[(xe + 1, y)] = EYE
    for y in range(20, 24):
        for i, (tx, fx) in enumerate(((5, 1), (9, 5), (13, 11), (17, 15))):
            x = rnd(lerp(tx, fx, t))
            colour = shade if (i == 0 or (i in (1, 2) and t >= 0.5)) else BODY
            row_fill(p, y, x, x + 1, colour)
    return p


def arcade_lead(rest, frames, turn_frame):
    """The three lead frames of A34-arcade in canvas cells (no stage beyond the motion's 7 cells on the right)."""
    first = frames[0]
    clawd0 = {k: c for k, c in first.items() if c in CLAWD}
    cabinet = {k: c for k, c in first.items() if c not in CLAWD}
    for f in frames:
        for k, c in f.items():
            if c not in CLAWD and k not in cabinet:
                cabinet[k] = c
    for k, c in FILL.items():
        if k in cabinet:
            raise BridgeError("the arcade fill cell %r is shown by a frame" % (k,))
        cabinet[k] = c
    if turned(1.0, SHADE_B) != clawd0:
        raise BridgeError("the turn does not end on the arcade's side view")
    if turned(0.0, SHADE) != turn_frame:
        raise BridgeError("the turn does not start on A6-turning's three-quarter view")
    clawd = [{k: rgb(v) for k, v in rest.items()}, turned(TURN[1], SHADE), turned(TURN[2], SHADE_B)]
    out = []
    for dx, body in zip(SLIDE, clawd):
        p = {(x + dx, y): c for (x, y), c in cabinet.items() if x + dx < CANVAS + 7}
        p.update(body)
        out.append(p)
    return out


# ---- the entries --------------------------------------------------------------------------------------------------------------------
def png_path(bid, k):
    return "%s/%s/%03d.png" % (BRIDGE_DIR, bid, k)


def steps_of(side, frames, edge, rest_pic):
    """(steps, direct): the changed cells between consecutive pictures of the sequence the bridge sits in, [seam, ..., seam] (a lead: the rest picture,
    the bridge frames, the target's first frame; a tail: the target's last frame, the bridge frames, the rest picture), and the changed cells of the
    seam without the bridge. The contract recomputes both from the PNGs."""
    seq = [rest_pic] + frames + [edge] if side == "lead" else [edge] + frames + [rest_pic]
    steps = [changed(seq[i], seq[i + 1]) for i in range(len(seq) - 1)]
    return steps, changed(seq[0], seq[-1])


def entry(P, bid, kind, target, side, frames, ms, stage, heads, derivation, edge, rest_pic, files):
    paths = []
    for k, cells in enumerate(frames):
        rel = png_path(bid, k)
        files[rel] = P.png_bytes(cells_to_grid(cells, stage))
        paths.append(rel)
    left, right, up, down = stage
    steps, direct = steps_of(side, frames, edge, rest_pic)
    return {"id": bid, "target": {"kind": kind, "id": target}, "side": side, "frames": paths, "ms": ms,
            "stage": {"left": P.fmt_units(left), "right": P.fmt_units(right), "up": P.fmt_units(up), "down": P.fmt_units(down)},
            "head": [None if h is None else list(h) for h in heads], "steps": steps, "direct": direct, "derivation": derivation}


def half_ms(count, base=0):
    """12 fps in whole ms, continuing the motion's own 83/84 pattern from frame `base`."""
    t = lambda k: (k * 1000 + 6) // 12
    return [t(base + k + 1) - t(base + k) for k in range(count)]


def build(P, art, motions):
    """Returns (bridges, files): the catalog entries in a fixed order and {relative path: PNG bytes}. `motions` are the port script's Motion objects."""
    by_id = {m.id: m for m in motions}
    rest = P.rest_cells(art)
    rest3 = {k: rgb(v) for k, v in rest.items()}
    poses = P.v1_pose_grids(art)
    bridges, files = [], {}
    no_stage = (0, 0, 0, 0)

    # 1. the skateboard stop
    ride = by_id["D14-ride"]
    stage = ride.stage
    last = grid_to_cells(ride.frames[-1], stage[0], stage[2])
    tail = ride_tail(last, rest)
    heads = [head_of(P, f, stage) for f in tail]
    rest_pic = dict(rest3)
    rest_pic.update({k: c for k, c in last.items() if c not in CLAWD})
    bridges.append(entry(P, "D14-ride-tail", "motion", "D14-ride", "tail", tail, half_ms(2, ride.count), stage, heads,
                         "the stop's crouch rises: head top and eyes up, the hand lifts to the arm, the legs lengthen (ride_tail)", last, rest_pic, files))

    # 2 and 4. the drag pick-up and the sent scene
    for kind, bid in (("dangle", "dangle-lead"), ("hop", "hop-lead")):
        first = {k: rgb(c) for k, c in grid_to_cells(poses[kind][0], 0, 0).items()}
        frame = lead_pose(P, rest, kind, first)
        bridges.append(entry(P, bid, "pose", kind, "lead", [frame], [MS_POSE], no_stage, [head_of(P, frame, no_stage)],
                             "half way between the rest picture and %s#0 on every feature (lead_pose)" % kind, first, rest3, files))

    # 3. the crouch starts
    for mid in ("C1-jump", "C2-celebrate", "C11-boop"):
        m = by_id[mid]
        first = grid_to_cells(m.frames[0], m.stage[0], m.stage[2])
        frame = lead_squash(rest3, first, 6)
        bridges.append(entry(P, mid + "-lead", "motion", mid, "lead", [frame], [MS_C], m.stage, [head_of(P, frame, m.stage)],
                             "the rest body sunk 3 cells, clipped at the baseline, no dust (lead_squash)", first, rest3, files))

    # 5. the arcade
    arc = by_id["A34-arcade"]
    frames = [grid_to_cells(g, arc.stage[0], arc.stage[2]) for g in arc.frames]
    turn_frame = grid_to_cells(by_id["A6-turning"].frames[ARC_TURN_FRAME], 0, 0)
    lead = arcade_lead(rest, frames, turn_frame)
    bridges.append(entry(P, "A34-arcade-lead", "motion", "A34-arcade", "lead", lead, half_ms(3), arc.stage, [head_of(P, f, arc.stage) for f in lead],
                         "the cabinet slides in from the right edge (12, 7, 3 cells from home) while Clawd turns through A6-turning's shading to the side view "
                         "(arcade_lead)", frames[0], rest3, files))
    bridges.append(entry(P, "A34-arcade-tail", "motion", "A34-arcade", "tail", list(reversed(lead)), half_ms(3, arc.count), arc.stage, [head_of(P, f, arc.stage) for f in reversed(lead)],
                         "the lead's three pictures backwards: Clawd turns back and the cabinet slides out", frames[-1], rest3, files))
    return bridges, files
