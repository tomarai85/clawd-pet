#!/usr/bin/env python3
"""The phase 4 contact sheet for the progress page: art/preview/v2/contact-sheet-phase4.png.

Usage:  python3 -I scripts/port-phase4-sheet.py [--art DIR] [--goldens DIR]

Every pet picture on the sheet is a golden of the production renderer (Tests/Goldens: size 1, pixel scale 1, drawn by StageRenderer.compose). The first row
shows the two new looks at rest, Ultra (B7) and winter (B8), enlarged 6 times, beside the Ultra pose (B7-ultra-wand) in the plain look and in Ultra's
colours (the plain golden with the look's bodyColor map applied, which is what the renderer does to every frame of the look). Then one strip per C motion
with every frame of it (60 ms each), enlarged 3 times: C1 jump, C2 celebrate, C3 skip, C4 look, C5 spin, C6 peekaboo, C7 drop, C8 waddle, C9 peek,
C10 wink, C11 boop, C12 tap, C13 sneeze. The last rows show Ultra and winter on seven v1 poses.
Run it after `scripts/record-stage-goldens`: the goldens must exist. Re-running it rewrites the same bytes.
"""
import argparse
import importlib.util
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCALE = 3
BIG = 6
C_ROWS = [("C1-jump", "C1 JUMP"), ("C2-celebrate", "C2 CELEBRATE"), ("C3-skip", "C3 SKIP"), ("C4-look", "C4 LOOK"), ("C5-spin", "C5 SPIN"),
          ("C6-peekaboo", "C6 PEEKABOO"), ("C7-drop", "C7 DROP"), ("C8-waddle", "C8 WADDLE"), ("C9-peek", "C9 PEEK"), ("C10-wink", "C10 WINK"),
          ("C11-boop", "C11 BOOP"), ("C12-tap", "C12 TAP"), ("C13-sneeze", "C13 SNEEZE")]
LOOKS = [("ultra", "B7 ULTRA"), ("winter", "B8 WINTER")]
POSES = ["idle_0", "blink_0", "listen_0", "think_0", "hop_1", "sleep_0", "dangle_0"]


def load_sheet2():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("port_phase2_sheet", os.path.join(ROOT, "scripts", "port-phase2-sheet.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def recoloured(picture, mapping):
    """The picture (w, h, rows of RGBA bytes) with the exact colours of `mapping` substituted, as the renderer applies a look's bodyColor map."""
    w, h, rows = picture
    out = []
    for row in rows:
        line = bytearray(row)
        for x in range(w):
            rgb = tuple(line[x * 4:x * 4 + 3])
            if line[x * 4 + 3] and rgb in mapping:
                line[x * 4:x * 4 + 3] = bytes(mapping[rgb])
        out.append(bytes(line))
    return w, h, out


def main():
    try:
        sys.stdout.reconfigure(errors="backslashreplace")
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--art", default=os.path.join(ROOT, "art"))
    ap.add_argument("--goldens", default=os.path.join(ROOT, "Tests", "Goldens"))
    args = ap.parse_args()
    art, goldens = os.path.abspath(args.art), os.path.abspath(args.goldens)
    S2 = load_sheet2()
    P = S2.load_main()
    read, paste, BG = S2.read, S2.paste, S2.BG
    try:
        atlas = json.load(open(os.path.join(art, "clawd-atlas.json"), encoding="utf-8"))
        ultra_map = {tuple(i["from"]): tuple(i["to"]) for i in next(l for l in atlas["looks"] if l["id"] == "ultra")["bodyColor"]["map"]}
        rest = [(label, read(P, os.path.join(goldens, "looks", lid, "idle_0.png"))) for lid, label in LOOKS]

        def frames(mid):
            n = len(os.listdir(os.path.join(goldens, "motions", mid)))
            return [read(P, os.path.join(goldens, "motions", mid, "%03d.png" % k)) for k in range(n)]
        pose_k = 10                                                   # a frame of B7's held pose (frames 3 to 20)
        b7 = frames("B7-ultra-wand")
        wand_plain = b7[pose_k]
        wand_ultra = recoloured(b7[pose_k], ultra_map)
        strips = [(label, frames(mid)) for mid, label in C_ROWS] + [("B7 ULTRA POSE EVERY OTHER", b7[::2])]
        poses = [(label, [read(P, os.path.join(goldens, "looks", lid, "%s.png" % name)) for name in POSES]) for lid, label in LOOKS]
    except (OSError, ValueError, StopIteration, KeyError, P.PortError) as e:
        sys.stderr.write("port-phase4-sheet: %s\n" % e)
        return 1
    tile_w = max(f[0] for _, fr in strips for f in fr if f[0] <= 48) * SCALE + 12             # the C strips; B7's frames carry the wand's 4 units of stage
    tile_h = max(f[1] for _, fr in strips for f in fr) * SCALE + 4
    pose_tile_w = max(f[0] for _, fr in poses for f in fr) * SCALE + 12
    big = [p for _, p in rest] + [wand_plain, wand_ultra]
    big_h = max(p[1] for p in big) * BIG
    label_w = 200
    wide_w = max(f[0] for _, fr in strips for f in fr) * SCALE + 12
    width = max(label_w + max(len(fr) for _, fr in strips[:-1]) * tile_w, label_w + len(strips[-1][1]) * wide_w, label_w + len(POSES) * pose_tile_w,
                sum(p[0] * BIG + 40 for p in big)) + 16
    height = 24 + big_h + 40 + len(strips) * (tile_h + 24) + len(poses) * (tile_h + 24) + 16
    sheet = [[BG] * width for _ in range(height)]
    P.draw_text(sheet, 8, 6, "PHASE 4 CLAUDE CODE MOTIONS AND LOOKS - PRODUCTION RENDERER GOLDENS", 2)
    base = 24 + big_h
    x = 8
    for (label, pic), cap in zip(rest + [("B7 POSE", wand_plain), ("B7 POSE IN ULTRA", wand_ultra)], [r[0] for r in rest] + ["B7 POSE PLAIN", "B7 POSE IN ULTRA"]):
        paste(sheet, pic, x, base, BIG)
        P.draw_text(sheet, x, base + 8, cap, 2)
        x += pic[0] * BIG + 40
    y = base + 32
    for label, frs in strips:
        P.draw_text(sheet, 8, y + 4, "%s %d FRAMES" % (label, len(frs)), 2)
        b = y + 8 + tile_h
        step = wide_w if label.startswith("B7") else tile_w
        for k, pic in enumerate(frs):
            paste(sheet, pic, label_w + k * step + (step - pic[0] * SCALE) // 2, b, SCALE)
        y = b + 16
    for label, frs in poses:
        P.draw_text(sheet, 8, y + 4, label + " ON V1 POSES", 2)
        b = y + 8 + tile_h
        for k, pic in enumerate(frs):
            paste(sheet, pic, label_w + k * pose_tile_w + (pose_tile_w - pic[0] * SCALE) // 2, b, SCALE)
        y = b + 16
    out = os.path.join(art, "preview", "v2", "contact-sheet-phase4.png")
    P.write_file(out, P.png_bytes([[c for c in row] for row in sheet]))
    print("wrote %s (%dx%d)" % (os.path.relpath(out, ROOT), width, height))
    return 0


if __name__ == "__main__":
    sys.exit(main())
