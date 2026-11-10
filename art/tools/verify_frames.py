"""Check generated frames against the art contract (pure Python PNG decode).

Usage: python3 -I verify_frames.py <art_dir>
Checks: every frame is the same size; 4x copy is exactly 4x nearest-neighbour of the 1x;
atlas lists only existing files; feet baseline fixed (bottom row = canvas bottom) for every
frame that stands on the ground; hop only moves up; every pose is visibly distinct.
"""
import json
import os
import struct
import sys
import zlib

ART = sys.argv[1]


def read_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", path
    i = 8
    idat = b""
    while i < len(d):
        ln, = struct.unpack(">I", d[i:i + 4])
        t = d[i + 4:i + 8]
        body = d[i + 8:i + 8 + ln]
        i += 12 + ln
        if t == b"IHDR":
            w, h, bd, ct = struct.unpack(">IIBB", body[:10])
        elif t == b"IDAT":
            idat += body
    assert bd == 8 and ct == 6, "expected RGBA8"
    raw = zlib.decompress(idat)
    stride = w * 4
    rows, prev, p = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[p]
        p += 1
        cur = bytearray(raw[p:p + stride])
        p += stride
        assert f == 0, "writer uses filter 0"
        rows.append(bytes(cur))
        prev = cur
    return w, h, rows


def px(rows, x, y):
    return rows[y][x * 4:x * 4 + 4]


atlas = json.load(open(os.path.join(ART, "clawd-atlas.json")))
errors = []
sizes = set()
frames = {}
for name, pose in atlas["poses"].items():
    assert len(pose["frames"]) == len(pose["ms"]), name
    for i, fr in enumerate(pose["frames"]):
        p1 = os.path.join(ART, fr)
        p4 = os.path.join(ART, fr.replace("frames/", "frames4x/"))
        if not (os.path.exists(p1) and os.path.exists(p4)):
            errors.append("missing " + fr)
            continue
        w, h, r1 = read_png(p1)
        w4, h4, r4 = read_png(p4)
        sizes.add((w, h))
        if (w4, h4) != (w * 4, h * 4):
            errors.append(f"{fr}: 4x size {w4}x{h4}")
            continue
        ok = all(px(r4, x, y) == px(r1, x // 4, y // 4) for y in range(h4) for x in range(w4))
        if not ok:
            errors.append(f"{fr}: 4x is not a nearest-neighbour copy")
        opaque = [(x, y) for y in range(h) for x in range(w) if px(r1, x, y)[3] > 200]
        ys = [y for _, y in opaque]
        frames[(name, i)] = {"top": min(ys), "bottom": max(ys), "sig": b"".join(r1)}
print("canvas sizes:", sizes, "unit:", atlas["unit"])
print("frame  top  bottom")
for (n, i), v in frames.items():
    print(f"{n}_{i:<2} {v['top']:>4} {v['bottom']:>6}")
H = list(sizes)[0][1]
stand = [k for k in frames if k[0] in ("idle", "blink", "think", "sleep", "helmet-idle", "dangle")]
for k in stand:
    if frames[k]["bottom"] != H - 1:
        errors.append(f"{k}: feet not on baseline (bottom={frames[k]['bottom']})")
hop_bottoms = [frames[("hop", i)]["bottom"] for i in range(len(atlas["poses"]["hop"]["frames"]))]
if any(b > H - 1 for b in hop_bottoms):
    errors.append("hop goes below baseline")
if H - 1 - min(hop_bottoms) != 2:
    errors.append("hop max lift is not 2 units: %s" % hop_bottoms)
print("hop bottoms:", hop_bottoms, "max lift:", H - 1 - min(hop_bottoms))
# distinctness: no two frames inside one pose are identical
dups = []
for name, pose in atlas["poses"].items():
    seen = {}
    for i in range(len(pose["frames"])):
        seen.setdefault(frames[(name, i)]["sig"], []).append(f"{name}_{i}")
    dups += [v for v in seen.values() if len(v) > 1]
if dups:
    errors.append("identical frames inside a pose: %s" % dups)
# each pose's first frame is distinct from every other pose's first frame (idle may equal hop landing)
firsts = {}
for name in atlas["poses"]:
    firsts.setdefault(frames[(name, 0)]["sig"], []).append(name)
cross = [v for v in firsts.values() if len(v) > 1]
if cross:
    errors.append("poses share a first frame: %s" % cross)
print("pose first frames distinct:", not cross)
print("ERRORS:" if errors else "ALL CHECKS PASSED", errors if errors else "")
sys.exit(1 if errors else 0)
