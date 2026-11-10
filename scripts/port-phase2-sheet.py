#!/usr/bin/env python3
"""The phase 2 contact sheet for the progress page: art/preview/v2/contact-sheet-phase2.png.

Usage:  python3 -I scripts/port-phase2-sheet.py [--art DIR] [--goldens DIR]

Every picture on the sheet is a golden of the production renderer (Tests/Goldens: size 1, pixel scale 1, drawn by StageRenderer.compose),
enlarged 3 times without smoothing (6 times for the first row): shiny's rest picture beside the D7 sticker, the rest pose of each new look, the
detective's inspect motion across its 113 frames, shiny on seven v1 poses, the four sticker moments and the calm idle motions (B3 glances, B4 wink
and slow blink, B5 foot tap). The official sticker each redrawn item follows sits at the left of its row, scaled down with a box filter (reference
only).
Run it after `scripts/record-stage-goldens`: the goldens must exist. Re-running it rewrites the same bytes.
"""
import argparse
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BG = (32, 34, 38, 255)
SCALE = 3
LOOKS = [("pool-float", "D2 POOL FLOAT"), ("shiny", "D7 SHINY"), ("coffee", "D9 COFFEE"), ("detective", "D12 DETECTIVE"), ("wand", "D13 WAND"),
         ("skateboard", "D14 SKATEBOARD")]
MOMENTS = [("D4-happy", "D4 HAPPY", "sources/sticker/happy.png"), ("D5-dizzy", "D5 DIZZY", "sources/sticker/dizzy.png"),
           ("D6-heart", "D6 HEART", "sources/sticker/heart.png"), ("D11-lightbulb", "D11 LIGHTBULB", "sources/sticker/lightbulb.png")]
SHINY_STICKER = "sources/sticker/shiny.png"
BIG = 6                                                # the first row: shiny's rest picture and the D7 sticker, side by side, enlarged 6 times
CALM = [("B3-glance-left", "B3 GLANCE LEFT"), ("B3-glance-right", "B3 GLANCE RIGHT"), ("B3-glance-left-long", "B3 GLANCE LEFT LONG"),
        ("B3-glance-right-long", "B3 GLANCE RIGHT LONG"),
        ("B4-wink", "B4 WINK"), ("B4-slow-blink", "B4 SLOW BLINK"), ("B5-foot-tap", "B5 FOOT TAP")]
SHINY_POSES = ["idle_0", "blink_0", "listen_0", "think_0", "hop_1", "sleep_0", "dangle_0"]       # shiny's goldens: its rest pictures on seven v1 poses


def load_main():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("port_official_art", os.path.join(ROOT, "scripts", "port-official-art.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read(P, path):
    w, h, rows = P.read_png(path)
    return w, h, rows


def blend(dst, src):
    a = src[3]
    if a == 255:
        return src
    if a == 0:
        return dst
    return tuple((src[k] * a + dst[k] * (255 - a) + 127) // 255 for k in range(3)) + (255,)


def paste(sheet, picture, x, y_bottom, scale):
    """The picture (w, h, rows of RGBA bytes) enlarged by `scale`, its bottom edge at y_bottom, left edge at x."""
    w, h, rows = picture
    top = y_bottom - h * scale
    for yy in range(h):
        row = rows[yy]
        for xx in range(w):
            px = tuple(row[xx * 4:xx * 4 + 4])
            if px[3] == 0:
                continue
            for dy in range(scale):
                line = sheet[top + yy * scale + dy]
                for dx in range(scale):
                    line[x + xx * scale + dx] = blend(line[x + xx * scale + dx], px)


def thumbnail(P, path, height):
    """The sticker scaled down to about `height` px by a box filter, composited over the sheet colour."""
    w, h, rows = read(P, path)
    f = max(1, -(-h // height))
    tw, th = w // f, h // f
    out = []
    for ty in range(th):
        line = bytearray()
        for tx in range(tw):
            acc, n, alpha = [0, 0, 0], 0, 0
            for yy in range(ty * f, ty * f + f):
                for xx in range(tx * f, tx * f + f):
                    px = rows[yy][xx * 4:xx * 4 + 4]
                    alpha += px[3]
                    for k in range(3):
                        acc[k] += px[k] * px[3]
                    n += 1
            a = alpha // n
            if alpha:
                col = [acc[k] // alpha for k in range(3)]
                col = [(col[k] * a + BG[k] * (255 - a) + 127) // 255 for k in range(3)]
            else:
                col = list(BG[:3])
            line += bytes(col + [255])
        out.append(bytes(line))
    return tw, th, out


def tile_row(P, sheet, y_top, label, pictures, x0, tile_w, tile_h):
    """One labelled row of pictures; returns the next free y."""
    P.draw_text(sheet, 8, y_top + 4, label, 2)
    base = y_top + 16 + tile_h
    for k, pic in enumerate(pictures):
        w, h, _ = pic
        x = x0 + k * tile_w + (tile_w - w * SCALE) // 2
        paste(sheet, pic, max(x0 + k * tile_w, x), base, SCALE)
    return base + 8


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
    P = load_main()
    try:
        looks = [(lid, label, read(P, os.path.join(goldens, "looks", lid, "idle_0.png"))) for lid, label in LOOKS]
        n_inspect = 113
        picks = sorted({round(k * (n_inspect - 1) / 15) for k in range(16)})
        inspect = [read(P, os.path.join(goldens, "motions", "D12-inspect", "%03d.png" % k)) for k in picks]
        moments = []
        for mid, label, sticker in MOMENTS:
            n = len(os.listdir(os.path.join(goldens, "motions", mid)))
            frames = [read(P, os.path.join(goldens, "motions", mid, "%03d.png" % k)) for k in sorted({round(k * (n - 1) / 7) for k in range(8)})]
            moments.append((label, thumbnail(P, os.path.join(art, sticker), 96), frames))
        calm = []
        for mid, label in CALM:
            n = len(os.listdir(os.path.join(goldens, "motions", mid)))
            calm.append((label, None, [read(P, os.path.join(goldens, "motions", mid, "%03d.png" % k)) for k in sorted({round(k * (n - 1) / 7) for k in range(8)})]))
        shiny = [read(P, os.path.join(goldens, "looks", "shiny", "%s.png" % name)) for name in SHINY_POSES]
        moments.insert(0, ("D7 SHINY", thumbnail(P, os.path.join(art, SHINY_STICKER), 96), shiny))
    except (OSError, ValueError, P.PortError) as e:
        sys.stderr.write("port-phase2-sheet: %s\n" % e)
        return 1
    tile_w = max(max(p[0] for _, _, p in looks), max(p[0] for p in inspect), *(max(f[0] for f in fr) for _, _, fr in moments)) * SCALE + 12
    tile_h = max(max(p[1] for _, _, p in looks), max(p[1] for p in inspect), *(max(f[1] for f in fr) for _, _, fr in moments)) * SCALE + 4
    label_w = 200
    cols = max(len(looks), len(inspect), 1 + max(len(fr) for _, _, fr in moments), 1 + max(len(fr) for _, _, fr in calm))
    width = label_w + cols * tile_w + 16
    shiny_rest = shiny[0]
    sticker_big = thumbnail(P, os.path.join(art, SHINY_STICKER), shiny_rest[1] * BIG)
    big_h = max(shiny_rest[1] * BIG, sticker_big[1]) + 28
    calm_h = max(f[1] for _, _, fr in calm for f in fr) * SCALE + 4
    rows_n = 2 + len(moments)
    height = 24 + big_h + rows_n * (tile_h + 40) + len(calm) * (calm_h + 40) + 16
    sheet = [[BG] * width for _ in range(height)]
    P.draw_text(sheet, 8, 6, "PHASE 2 LOOKS AND MOMENTS - PRODUCTION RENDERER GOLDENS X3", 2)
    y = 24
    P.draw_text(sheet, 8, y + 4, "D7 SHINY REST", 2)
    P.draw_text(sheet, 8, y + 24, "X6 BESIDE THE STICKER", 2)
    base = y + 16 + big_h - 28
    paste(sheet, sticker_big, label_w + 4, base, 1)
    paste(sheet, shiny_rest, label_w + sticker_big[0] + 40, base, BIG)
    y = base + 12
    y = tile_row(P, sheet, y, "LOOKS AT REST", [p for _, _, p in looks], label_w, tile_w, tile_h) + 12
    base = y - 20 - 12
    for k, (lid, label, pic) in enumerate(looks):
        P.draw_text(sheet, label_w + k * tile_w + 4, base + 4, label, 2)
    y = tile_row(P, sheet, y, "D12 INSPECT", inspect, label_w, tile_w, tile_h) + 12
    for label, ref, frames in moments:
        P.draw_text(sheet, 8, y + 4, label, 2)
        base = y + 16 + tile_h
        paste(sheet, ref, label_w + 4, base, 1)
        x0 = label_w + tile_w
        for k, pic in enumerate(frames):
            paste(sheet, pic, x0 + k * tile_w + (tile_w - pic[0] * SCALE) // 2, base, SCALE)
        y = base + 20
    for label, _, frames in calm:
        P.draw_text(sheet, 8, y + 4, label, 2)
        base = y + 16 + calm_h
        x0 = label_w + tile_w
        for k, pic in enumerate(frames):
            paste(sheet, pic, x0 + k * tile_w + (tile_w - pic[0] * SCALE) // 2, base, SCALE)
        y = base + 20
    out = os.path.join(art, "preview", "v2", "contact-sheet-phase2.png")
    P.write_file(out, P.png_bytes([[c for c in row] for row in sheet]))
    print("wrote %s (%dx%d)" % (os.path.relpath(out, ROOT), width, height))
    return 0


if __name__ == "__main__":
    sys.exit(main())
