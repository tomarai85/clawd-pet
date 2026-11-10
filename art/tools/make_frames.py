"""Generate pixel Clawd frames (1 px per unit, plus 4x previews) and clawd-atlas.json.

Usage: python3 -I make_frames.py <art_dir>

Pure Python (no Pillow). Official grid, measured from the sticker mark
(693x527, 58 px unit): body 8 wide (cols 2..9), body rows 0..5, black 1x1 eyes
at cols 3 and 8 on row 1, 2x2 arms at cols 0-1 and 10-11 on rows 2-3, four 1x2
legs at cols 2,4,7,9 on rows 6-7.

Canvas is the same for every frame: 12 x 12 units. Feet baseline = bottom edge
of the canvas (y = 12). The body top is at y = 4 when standing, which leaves 4
units above for the 2-unit hop and the 3-unit helmet dome (plus a 1-unit bob).
The helmet dome encloses the whole body block (see DOME_* below); legs poke out of its base.
"""
import json
import os
import struct
import sys
import zlib

ART = sys.argv[1]
W, H = 12, 12
BASE_TOP = 4  # body top row when standing (canvas y)
UNIT_PT = 4

BODY = (215, 119, 87, 255)       # claude orange, rgb(215,119,87)
EYE = (20, 20, 19, 255)          # near-black, sampled from the official mark
GLASS = (150, 198, 236, 255)     # helmet rim: thin light-blue outline
GLASS_FILL = (190, 218, 236, 12)  # ~5 % tint inside the dome: the interior reads as clear
GLINT = (250, 252, 255, 255)     # static highlight on the glass (part of the drawing, not an effect)

# Helmet dome (optional variant). Clawd's head is the whole 8 x 6 body block, so the dome is a
# closed, round glass bubble around that block, 12 units wide (the full canvas), from 3 units
# above the body top to the row above the feet. Rows are relative to the body top (bt).
# The glass is drawn BEHIND the body, arms and legs: head and eyes are never covered, the
# arms and the legs poke through the glass wall, and only the rim shows around the head.
DOME_FILL_SPANS = {-3: (4, 7), -2: (2, 9), -1: (1, 10), 0: (0, 11), 1: (0, 11), 2: (0, 11),
                   3: (0, 11), 4: (1, 10), 5: (2, 9), 6: (4, 7)}
DOME_RIM = ([(4, -3), (5, -3), (6, -3), (7, -3), (2, -2), (3, -2), (8, -2), (9, -2), (1, -1), (10, -1)]
            + [(0, y) for y in (0, 1, 2, 3)] + [(11, y) for y in (0, 1, 2, 3)]
            + [(1, 4), (10, 4), (2, 5), (3, 5), (8, 5), (9, 5), (4, 6), (5, 6), (6, 6), (7, 6)])
DOME_GLINT = [(3, -2), (2, -2), (1, -1)]

LEG_X = (2, 4, 7, 9)


def blank():
    return [[None] * W for _ in range(H)]


def put(g, x, y, c):
    if 0 <= x < W and 0 <= y < H:
        g[y][x] = c


def draw(lift=0, eyes="open", eye_dx=0, arm_l=0, arm_r=0, legs=None, leg_len=2,
         leg_sway=0, helmet=False, body_top=None):
    """Return a W x H grid of RGBA tuples / None.

    lift: whole sprite rises by this many units (feet leave the baseline).
    eyes: 'open' | 'closed'.
    arm_l / arm_r: vertical arm offset in units (-1 raised, +1 drooped).
    legs: list of 4 leg heights (0..leg_len); default all full.
    leg_len: full leg height in units (2 standing, 3 dangling).
    leg_sway: horizontal shift (units) applied to the bottom unit of each leg.
    """
    g = blank()
    bt = (BASE_TOP - lift) if body_top is None else body_top
    if helmet:  # glass first, so everything below is drawn in front of it
        for y, (x0, x1) in DOME_FILL_SPANS.items():
            for x in range(x0, x1 + 1):
                put(g, x, bt + y, GLASS_FILL)
        for (x, y) in DOME_RIM:
            put(g, x, bt + y, GLASS)
        for (x, y) in DOME_GLINT:
            put(g, x, bt + y, GLINT)
    # body 8 x 6
    for y in range(6):
        for x in range(2, 10):
            put(g, x, bt + y, BODY)
    # arms 2 x 2
    for dy in range(2):
        for x in (0, 1):
            put(g, x, bt + 2 + arm_l + dy, BODY)
        for x in (10, 11):
            put(g, x, bt + 2 + arm_r + dy, BODY)
    # legs
    heights = legs if legs is not None else [leg_len] * 4
    for lx, hgt in zip(LEG_X, heights):
        for k in range(hgt):
            x = lx
            if leg_sway and k == hgt - 1 and hgt >= 2:
                x = lx + leg_sway
            put(g, x, bt + 6 + k, BODY)
    # eyes
    ey = bt + 1
    if eyes == "open":
        put(g, 3 + eye_dx, ey, EYE)
        put(g, 8 + eye_dx, ey, EYE)
    else:  # closed: short horizontal lines, 2 units wide
        for x in (3, 4, 7, 8):
            put(g, x + eye_dx, ey, EYE)
    return g


# ------------------------------------------------------------------ poses
def pose_frames():
    P = {}
    # idle: still
    P["idle"] = ([draw()], [1000], True)
    # blink: closed line eyes, one short frame
    P["blink"] = ([draw(eyes="closed")], [120], False)
    # listen: eyes toward the right (chip side), gentle 1-unit bob
    P["listen"] = ([draw(eye_dx=1), draw(eye_dx=1, lift=1)], [450, 450], True)
    # think: legs / arms shuffle, 6-frame cycle (120 ms, same as Claude Code's small spinner)
    full = [2, 2, 2, 2]
    A = [1, 2, 2, 1]   # legs 0 and 3 lifted
    B = [2, 1, 1, 2]   # legs 1 and 2 lifted
    think = [
        draw(legs=A, arm_l=-1),
        draw(legs=full, arm_l=-1),
        draw(legs=B, arm_r=-1),
        draw(legs=full, arm_l=-1, arm_r=-1),
        draw(legs=full, arm_r=-1),
        draw(legs=full),
    ]
    P["think"] = (think, [120] * 6, True)
    # hop: up 2 units and back (no squash), plays once
    hop = [draw(lift=1, arm_l=-1, arm_r=-1), draw(lift=2, arm_l=-1, arm_r=-1),
           draw(lift=1), draw()]
    P["hop"] = (hop, [60, 150, 70, 60], False)
    # sleep: eyes closed as short lines, arms drooped, one frame
    P["sleep"] = ([draw(eyes="closed", arm_l=1, arm_r=1)], [1000], True)
    # dangle: held up, arms raised, legs hanging (3 tall, alternating pairs), longest feet stay on the baseline
    dang = [draw(arm_l=-1, arm_r=-1, legs=[3, 2, 3, 2], body_top=BASE_TOP - 1),
            draw(arm_l=-1, arm_r=-1, legs=[2, 3, 2, 3], body_top=BASE_TOP - 1)]
    P["dangle"] = (dang, [300, 300], True)
    # helmet variants (optional, off by default)
    P["helmet-idle"] = ([draw(helmet=True)], [1000], True)
    P["helmet-listen"] = ([draw(eye_dx=1, helmet=True), draw(eye_dx=1, lift=1, helmet=True)], [450, 450], True)
    return P


# ------------------------------------------------------------------ PNG writer
def png_bytes(grid, scale=1):
    w, h = len(grid[0]) * scale, len(grid) * scale
    raw = bytearray()
    for row in grid:
        line = bytearray()
        for c in row:
            px = bytes(c) if c else b"\x00\x00\x00\x00"
            line += px * scale
        for _ in range(scale):
            raw.append(0)
            raw += line

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def ascii_dump(grid):
    out = []
    for row in grid:
        s = ""
        for c in row:
            if c is None:
                s += "."
            elif c == BODY:
                s += "#"
            elif c == EYE:
                s += "@"
            elif c == GLASS_FILL:
                s += ":"
            elif c == GLASS:
                s += "o"
            else:
                s += "*"
        out.append(s)
    return "\n".join(out)


def main():
    poses = pose_frames()
    atlas = {
        "unit": UNIT_PT,
        "canvas": {"w": W, "h": H, "feet_baseline_y": H, "body_top_standing_y": BASE_TOP},
        "palette": {"body": "rgb(215,119,87)", "eye": "rgb(20,20,19)", "glass": "rgb(150,198,236)", "glass_fill": "rgba(190,218,236,0.05)", "glint": "rgb(250,252,255)"},
        "scale4x_dir": "frames4x",
        "poses": {},
    }
    sheet_cells = []
    for name, (frames, ms, loop) in poses.items():
        files = []
        for i, g in enumerate(frames):
            fn = f"{name}_{i}.png"
            write(os.path.join(ART, "frames", fn), png_bytes(g, 1))
            write(os.path.join(ART, "frames4x", fn), png_bytes(g, 4))
            files.append("frames/" + fn)
            sheet_cells.append((name, i, g))
        atlas["poses"][name] = {"frames": files, "ms": ms, "loop": loop}
        print(f"== {name} ({len(frames)} frames, ms={ms}, loop={loop})")
        for i, g in enumerate(frames):
            print(f"-- frame {i}")
            print(ascii_dump(g))
    with open(os.path.join(ART, "clawd-atlas.json"), "w", encoding="utf-8") as f:
        json.dump(atlas, f, indent=2)

    # contact sheet (6x), labelled by order, for review only
    cols = 7
    scale = 8
    pad = 2
    rows = (len(sheet_cells) + cols - 1) // cols
    cw, ch = W + pad * 2, H + pad * 2
    sheet = [[(32, 34, 38, 255)] * (cw * cols) for _ in range(ch * rows)]
    for idx, (_, _, g) in enumerate(sheet_cells):
        ox, oy = (idx % cols) * cw + pad, (idx // cols) * ch + pad
        for y in range(H):
            for x in range(W):
                c = g[y][x]
                if c:
                    a = c[3] / 255.0
                    bg = sheet[oy + y][ox + x]
                    sheet[oy + y][ox + x] = tuple(int(round(bg[k] * (1 - a) + c[k] * a)) for k in range(3)) + (255,)
    write(os.path.join(ART, "preview", "contact-sheet.png"), png_bytes(sheet, scale))
    print("order:", [(n, i) for n, i, _ in sheet_cells])


main()
