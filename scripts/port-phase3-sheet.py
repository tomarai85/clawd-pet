#!/usr/bin/env python3
"""The phase 3 contact sheet for the progress page: art/preview/v2/contact-sheet-phase3.png.

Usage:  python3 -I scripts/port-phase3-sheet.py [--art DIR] [--goldens DIR]

Every pet picture on the sheet is a golden of the production renderer (Tests/Goldens: size 1, pixel scale 1, drawn by StageRenderer.compose). The first
row puts each plushie's official photograph (reference only, scaled down with a box filter) beside the pet's rest pose in that look, both at the same
height: the wizard (D15), the cowboy (D16), the scientist (D17), the phase 1 sunglasses beside plush/sunglasses.png (D18, the comparison) and D19's `^ ^`
face. The next three rows show each new look on seven v1 poses, the last row D19 across its 16 frames.
Run it after `scripts/record-stage-goldens`: the goldens must exist. Re-running it rewrites the same bytes.
"""
import argparse
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCALE = 3
BIG = 6
LOOKS = [("wizard", "D15 WIZARD", "sources/plush/wizard.png"), ("cowboy", "D16 COWBOY", "sources/plush/cowboy.png"),
         ("scientist", "D17 SCIENTIST", "sources/plush/scientist.png")]
POSES = ["idle_0", "blink_0", "listen_0", "think_0", "hop_1", "sleep_0", "dangle_0"]
FACE_FRAME = 5                                   # a frame of D19's `^ ^` (frames 1 to 14)


def load_sheet2():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("port_phase2_sheet", os.path.join(ROOT, "scripts", "port-phase2-sheet.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


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
    read, paste, thumbnail, BG = S2.read, S2.paste, S2.thumbnail, S2.BG
    try:
        pairs = [(label, picture, read(P, os.path.join(goldens, "looks", lid, "idle_0.png"))) for lid, label, picture in LOOKS]
        pairs.append(("D18 SUNGLASSES - PHASE 1 LOOK", "sources/plush/sunglasses.png", read(P, os.path.join(goldens, "looks", "sunglasses", "idle_0.png"))))
        pairs.append(("D19 HAPPY", "sources/plush/happy.png", read(P, os.path.join(goldens, "motions", "D19-happy-caret", "%03d.png" % FACE_FRAME))))
        poses = [(label, [read(P, os.path.join(goldens, "looks", lid, "%s.png" % name)) for name in POSES]) for lid, label, _ in LOOKS]
        n = len(os.listdir(os.path.join(goldens, "motions", "D19-happy-caret")))
        face = [read(P, os.path.join(goldens, "motions", "D19-happy-caret", "%03d.png" % k)) for k in range(n)]
    except (OSError, ValueError, P.PortError) as e:
        sys.stderr.write("port-phase3-sheet: %s\n" % e)
        return 1
    big_h = max(p[1] for _, _, p in pairs) * BIG
    thumbs = [thumbnail(P, os.path.join(art, picture), big_h) for _, picture, _ in pairs]
    pair_w = max(t[0] for t in thumbs) + max(p[0] for _, _, p in pairs) * BIG + 48
    label_w = 200
    tile_w = max(max(f[0] for f in fr) for _, fr in poses) * SCALE + 12
    tile_h = max(max(f[1] for f in fr) for _, fr in poses) * SCALE + 4
    width = max(label_w + len(POSES) * tile_w, len(pairs) * pair_w, label_w + len(face) * tile_w) + 16
    height = 24 + big_h + 56 + len(poses) * (tile_h + 40) + (tile_h + 40) + 16
    sheet = [[BG] * width for _ in range(height)]
    P.draw_text(sheet, 8, 6, "PHASE 3 PLUSHIE LOOKS - PRODUCTION RENDERER GOLDENS, PHOTOGRAPHS FOR REFERENCE", 2)
    y = 24
    base = y + big_h
    for k, ((label, _, pet), thumb) in enumerate(zip(pairs, thumbs)):
        x = 8 + k * pair_w
        paste(sheet, thumb, x, base, 1)
        paste(sheet, pet, x + thumb[0] + 24, base, BIG)
        P.draw_text(sheet, x, base + 8, label, 2)
    y = base + 40
    for label, frames in poses:
        P.draw_text(sheet, 8, y + 4, label, 2)
        b = y + 16 + tile_h
        for k, pic in enumerate(frames):
            paste(sheet, pic, label_w + k * tile_w + (tile_w - pic[0] * SCALE) // 2, b, SCALE)
        y = b + 20
    P.draw_text(sheet, 8, y + 4, "D19 FACE", 2)
    b = y + 16 + tile_h
    for k, pic in enumerate(face):
        paste(sheet, pic, label_w + k * tile_w + (tile_w - pic[0] * SCALE) // 2, b, SCALE)
    out = os.path.join(art, "preview", "v2", "contact-sheet-phase3.png")
    P.write_file(out, P.png_bytes([[c for c in row] for row in sheet]))
    print("wrote %s (%dx%d)" % (os.path.relpath(out, ROOT), width, height))
    return 0


if __name__ == "__main__":
    sys.exit(main())
