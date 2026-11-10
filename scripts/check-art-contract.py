#!/usr/bin/env python3
"""Check the Clawd art contract (spec-clawd-pet-2026-10-16.md section 4) against the files on disk
and against the Claude Code binary bytes at the offsets that art/claude-code-elements.json cites.

Usage:  python3 -I scripts/check-art-contract.py [--art DIR] [--evidence FILE] [--phase N [--motions ID,ID]]

stdlib only (PNG decoding with zlib). One output line per check:  PASS|FAIL <id> <what> [-- detail].
Exit status: 0 when every check passes (a check that could not run is reported NOT RUN, is neither a pass nor a failure, and does not change the
exit status), 1 otherwise.

Evidence: with the default art directory the script writes .evidence/art-verified.txt.
  full success -> the line ART-CONTRACT-OK, plus date, the sha256 of clawd-atlas.json and other lines
  every check that ran passed, but one could not run (node is missing for v2:R5-node) -> ART-CONTRACT-PARTIAL and a `not-run:` line, never OK
  any failure  -> ART-CONTRACT-FAIL instead (a stale OK line can never survive a failing run)
  Lines that start with NEGATIVE-CONTROL (the recorded negative controls) are carried over unchanged.
With --art pointing at another directory (a temp copy), nothing is written unless --evidence is given.

A mismatch is fixed in the art producer (art/tools), never by loosening a check here.

--phase N adds the v2 checks (spec-clawd-pet-v2-2026-10-17.md section 3.1, ids "v2:..."): the schema 2 catalog in clawd-atlas.json, the ported
frames in motions/, the look layers in looks/, the official sources in sources/lottie/. They re-derive everything from the Lottie files and
the shipped PNGs with code of their own (nothing is imported from scripts/port-official-art.py). --motions limits the per-motion checks.
Tests/art/phase1-checks.test.sh breaks one rule at a time in a copy of the art tree and requires the named check to fail.
"""
import argparse
import datetime
import hashlib
import json
import math
import mmap
import os
import re
import struct
import subprocess
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The bytes art/claude-code-elements.json was extracted from: the official Claude Code 2.1.301 build for darwin-arm64 (its sha256 is the
# one in https://downloads.claude.ai/claude-code-releases/2.1.301/manifest.json). The installed Claude Code updates itself and moves every
# offset (2026-10-21: claude-stable/claude-1 became 2.1.306 and E4, E10-E14 failed on an unchanged tree), so the contract is checked against
# this pinned copy. Fetch it with: curl -fsSL -o <BINARY> https://downloads.claude.ai/claude-code-releases/2.1.301/darwin-arm64/claude
REFERENCE_VERSION = "2.1.301"
REFERENCE_SHA256 = "1f04c69e1c24e4d0a716a863af0aad8fc64d49a499334c29701f073700276b99"
BINARY = os.path.expanduser("~/.local/share/clawd-pet-reference/claude-code-2.1.301-darwin-arm64")

# ---- the contract (spec section 4 and the loop task's verify_doc) -------------------------------
POSES = ["idle", "blink", "listen", "think", "hop", "sleep", "dangle", "helmet-idle", "helmet-listen"]
CLOSED_EYE_POSES = {"blink", "sleep"}                        # eyes drawn as 2x1 lines
GROUND_POSES = {"idle", "blink", "think", "sleep", "dangle", "helmet-idle"}   # feet on the baseline in every frame
STANDING_POSES = {"idle", "blink", "think", "sleep", "helmet-idle"}           # body top at body_top_standing_y
MOVING_POSES = {"listen", "helmet-listen", "hop"}            # may rise above the baseline, never below
HELMET_BASE = {"helmet-idle": "idle", "helmet-listen": "listen"}
BODY = (215, 119, 87, 255)                                   # rgb(215,119,87)
BODY_X = tuple(range(2, 10))                                 # body 8 units wide
ARM_COLS = ((0, 1), (10, 11))                                # 2-unit arms
LEG_COLS = (2, 4, 7, 9)                                      # four legs
TORSO_ROWS = 6
EXPECTED_PRESENT_VERBS = 188
EXPECTED_PAST_VERBS = 8
REQUIRED_ELEMENT_KEYS = ["spinner_glyphs", "spinner_timing", "present_verbs", "past_verbs", "interrupt",
                         "error_line", "input_box", "theme_colors_dark", "welcome_clawd_block_art"]
SIG = b"\x89PNG\r\n\x1a\n"

RESULTS = []
NOT_RUN = []    # ids of checks that could not run: neither a pass nor a failure
S = {}          # shared state between checks


def out(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def run(cid, text, fn):
    try:
        problems, info = fn()
    except Exception as e:                                   # a crashing check is a failing check
        problems, info = ["exception %s: %s" % (type(e).__name__, e)], ""
    if problems is None:                                     # the check could not be made (its tool is missing): reported, never counted as a pass
        NOT_RUN.append(cid)
        out("NOT RUN %s %s -- %s" % (cid, text, info))
        return
    ok = not problems
    if ok:
        detail = info
    else:
        detail = "; ".join(problems[:4]) + (" (+%d more)" % (len(problems) - 4) if len(problems) > 4 else "")
    RESULTS.append((ok, cid))
    out("%s %s %s%s" % ("PASS" if ok else "FAIL", cid, text, (" -- " + detail) if detail else ""))


# ---- PNG ----------------------------------------------------------------------------------------
def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != SIG:
        raise ValueError("not a PNG")
    i, idat, ihdr, iend = 8, [], None, False
    while i < len(data):
        if iend:
            raise ValueError("data after IEND")
        if i + 12 > len(data):
            raise ValueError("truncated chunk")
        ln, tag = struct.unpack(">I4s", data[i:i + 8])
        body = data[i + 8:i + 8 + ln]
        crc = data[i + 8 + ln:i + 12 + ln]
        if len(body) != ln or len(crc) != 4:
            raise ValueError("truncated chunk " + tag.decode("latin1"))
        if zlib.crc32(tag + body) & 0xFFFFFFFF != struct.unpack(">I", crc)[0]:
            raise ValueError("bad CRC in " + tag.decode("latin1"))
        i += 12 + ln
        if tag == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif tag == b"IDAT":
            idat.append(body)
        elif tag == b"IEND":
            iend = True
    if ihdr is None or not iend:
        raise ValueError("missing IHDR or IEND")
    w, h, bd, ct, cm, fm, il = ihdr
    if (bd, ct, cm, fm, il) != (8, 6, 0, 0, 0):
        raise ValueError("need RGBA8 non-interlaced, got depth=%d colortype=%d interlace=%d" % (bd, ct, il))
    raw = zlib.decompress(b"".join(idat))
    stride = w * 4
    if len(raw) != h * (stride + 1):
        raise ValueError("pixel data length %d, want %d" % (len(raw), h * (stride + 1)))
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
                left = cur[k - 4] if k >= 4 else 0
                cur[k] = (cur[k] + ((left + prev[k]) >> 1)) & 255
        elif f == 4:
            for k in range(stride):
                a = cur[k - 4] if k >= 4 else 0
                b = prev[k]
                c = prev[k - 4] if k >= 4 else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                cur[k] = (cur[k] + pr) & 255
        elif f != 0:
            raise ValueError("bad PNG filter %d" % f)
        rows.append(bytes(cur))
        prev = cur
    return w, h, rows


def px(rows, x, y):
    return tuple(rows[y][x * 4:x * 4 + 4])


# ---- helpers ------------------------------------------------------------------------------------
def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def css(s):
    m = re.fullmatch(r"\s*rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([0-9.]+)\s*)?\)\s*", s)
    if not m:
        raise ValueError("unparseable colour %r" % s)
    a = 1.0 if m.group(4) is None else float(m.group(4))
    return int(m.group(1)), int(m.group(2)), int(m.group(3)), a


def get(d, path):
    for k in path:
        d = d[k]
    return d


ESC = re.compile(r"\\u([0-9A-Fa-f]{4})|\\x([0-9A-Fa-f]{2})")


def unesc(s):
    return ESC.sub(lambda mo: chr(int(mo.group(1) or mo.group(2), 16)), s)


def js_str_array(text):
    return [unesc(x) for x in re.findall(r'"((?:[^"\\]|\\.)*)"', text)]


def jsesc(s):
    return "".join(c if ord(c) < 128 else "\\u%04X" % ord(c) for c in s)


class Binary:
    def __init__(self, path):
        self.path = path
        self.f = open(path, "rb")
        self.m = mmap.mmap(self.f.fileno(), 0, access=mmap.ACCESS_READ)
        self.size = len(self.m)

    def at(self, off, n):
        if off < 0 or off + n > self.size:
            raise ValueError("range %d+%d outside the %d-byte binary" % (off, n, self.size))
        return self.m[off:off + n]

    def until(self, off, end, maxlen=1 << 21):
        j = self.m.find(end, off, min(self.size, off + maxlen))
        if j < 0:
            raise ValueError("end marker %r not found within %d bytes of %d" % (end, maxlen, off))
        return self.m[off:j + len(end)]


def binary():
    if "bin" not in S:
        S["bin"] = Binary(BINARY)
    return S["bin"]


def text_at(off, end):
    return binary().until(off, end.encode("utf-8")).decode("utf-8")


# ---- ATLAS --------------------------------------------------------------------------------------
def a_load():
    path = os.path.join(S["art"], "clawd-atlas.json")
    S["atlas"] = load_json(path)
    a = S["atlas"]
    keys = set(a)
    want = {"unit", "canvas", "palette", "scale4x_dir", "poses"}
    if "schema" in a:                                        # schema 2 (v2 Interface Contract) adds exactly these three keys, and may add `bridges`
        want |= {"schema", "motions", "looks"}
        if "bridges" in a:
            want.add("bridges")
    p = [] if keys == want else ["top-level keys %s, want %s" % (sorted(keys), sorted(want))]
    return p, "keys: " + ",".join(sorted(keys))


def a_unit():
    a = S["atlas"]
    p = []
    if a.get("unit") != 4 or isinstance(a.get("unit"), bool):
        p.append("unit=%r, want 4" % (a.get("unit"),))
    if a.get("scale4x_dir") != "frames4x":
        p.append("scale4x_dir=%r, want 'frames4x'" % (a.get("scale4x_dir"),))
    return p, "unit 4 pt per unit, scale4x_dir frames4x"


def a_canvas():
    c = S["atlas"].get("canvas", {})
    p = []
    for k, v in (("w", 12), ("h", 12), ("feet_baseline_y", 12), ("body_top_standing_y", 4)):
        if c.get(k) != v or isinstance(c.get(k), bool):
            p.append("canvas.%s=%r, want %d" % (k, c.get(k), v))
    return p, "canvas 12x12 units, feet_baseline_y 12, body_top_standing_y 4"


def a_palette():
    pal = S["atlas"].get("palette", {})
    p = []
    if pal.get("body") != "rgb(215,119,87)":
        p.append("palette.body=%r, want 'rgb(215,119,87)'" % (pal.get("body"),))
    for k in ("body", "eye", "glass", "glass_fill", "glint"):
        if k not in pal:
            p.append("palette.%s missing" % k)
    if not p:
        eye = css(pal["eye"])
        if max(eye[:3]) > 32 or eye[3] != 1.0:
            p.append("palette.eye=%s is not an opaque near-black (each channel <= 32)" % pal["eye"])
        S["pal"] = {"eye": eye[:3] + (255,), "glass": css(pal["glass"])[:3] + (255,),
                    "glint": css(pal["glint"])[:3] + (255,), "fill": css(pal["glass_fill"])}
    return p, "body rgb(215,119,87); eye %s near-black" % pal.get("eye")


def a_poses():
    poses = S["atlas"]["poses"]
    names = list(poses)
    p = []
    missing = [n for n in POSES if n not in names]
    extra = [n for n in names if n not in POSES]
    if missing:
        p.append("missing poses %s" % missing)
    if extra:
        p.append("extra poses %s (R4: nothing beyond the nine)" % extra)
    return p, "%d poses: %s" % (len(names), ",".join(names))


def a_poses_shape():
    p, n = [], 0
    for name, pose in S["atlas"]["poses"].items():
        if set(pose) != {"frames", "ms", "loop"}:
            p.append("%s: keys %s, want frames/ms/loop" % (name, sorted(pose)))
            continue
        fr, ms = pose["frames"], pose["ms"]
        if not fr or len(fr) != len(ms):
            p.append("%s: %d frames vs %d ms" % (name, len(fr), len(ms)))
        if not all(type(v) is int and v > 0 for v in ms):
            p.append("%s: ms must be positive integers, got %r" % (name, ms))
        if type(pose["loop"]) is not bool:
            p.append("%s: loop must be true/false, got %r" % (name, pose["loop"]))
        for i, f in enumerate(fr):
            if f != "frames/%s_%d.png" % (name, i):
                p.append("%s: frame %d is %r, want 'frames/%s_%d.png'" % (name, i, f, name, i))
        n += len(fr)
    hop = S["atlas"]["poses"].get("hop")
    if hop and hop.get("loop") is not False:
        p.append("hop must play once (loop false) -- spec: one small hop")
    return p, "frames[] and ms[] equal length in every pose; %d frames in total" % n


# ---- FILES --------------------------------------------------------------------------------------
def referenced():
    out_ = []
    for name, pose in S["atlas"]["poses"].items():
        for i, f in enumerate(pose["frames"]):
            out_.append((name, i, f))
    return out_


def f_exist():
    art = S["art"]
    d4 = S["atlas"]["scale4x_dir"]
    p = []
    for name, i, f in referenced():
        if not os.path.isfile(os.path.join(art, f)):
            p.append("missing %s" % f)
        f4 = d4 + "/" + os.path.basename(f)
        if not os.path.isfile(os.path.join(art, f4)):
            p.append("missing %s" % f4)
    return p, "%d frames present in frames/ and %d in %s/" % (len(referenced()), len(referenced()), d4)


def f_orphans():
    art = S["art"]
    refs = {os.path.basename(f) for _, _, f in referenced()}
    p = []
    for d in ("frames", S["atlas"]["scale4x_dir"]):
        names = {n for n in os.listdir(os.path.join(art, d)) if not n.startswith(".")}
        for n in sorted(names - refs):
            p.append("%s/%s is not referenced by the atlas" % (d, n))
    return p, "frames/ and %s/ hold exactly the %d atlas frames" % (S["atlas"]["scale4x_dir"], len(refs))


def f_decode():
    art = S["art"]
    d4 = S["atlas"]["scale4x_dir"]
    p = []
    S["png1"], S["png4"] = {}, {}
    for name, i, f in referenced():
        for store, rel in ((S["png1"], f), (S["png4"], d4 + "/" + os.path.basename(f))):
            try:
                store[(name, i)] = read_png(os.path.join(art, rel))
            except Exception as e:
                p.append("%s: %s" % (rel, e))
    return p, "%d PNGs decode (RGBA8, CRC ok)" % (len(S["png1"]) + len(S["png4"]))


def f_canvas():
    c = S["atlas"]["canvas"]
    p = []
    sizes = {}
    for k, (w, h, _) in S["png1"].items():
        sizes.setdefault((w, h), []).append("%s_%d" % k)
    if set(sizes) != {(c["w"], c["h"])}:
        p.append("1x frame sizes %s, want one canvas %dx%d" % ({s: len(v) for s, v in sizes.items()}, c["w"], c["h"]))
    return p, "all %d frames are %dx%d px (1 px per unit)" % (len(S["png1"]), c["w"], c["h"])


def f_4x():
    p = []
    for k, (w, h, r1) in S["png1"].items():
        if k not in S["png4"]:
            continue
        w4, h4, r4 = S["png4"][k]
        tag = "%s_%d" % k
        if (w4, h4) != (4 * w, 4 * h):
            p.append("%s: 4x frame is %dx%d, want exactly %dx%d" % (tag, w4, h4, 4 * w, 4 * h))
            continue
        for y in range(h4):
            want = b"".join(r1[y // 4][x * 4:x * 4 + 4] * 4 for x in range(w))
            if r4[y] != want:
                p.append("%s: 4x row %d is not the nearest-neighbour copy of the 1x row %d" % (tag, y, y // 4))
                break
    return p, "every frames4x PNG is exactly 4x its 1x frame (48x48), nearest-neighbour"


# ---- PIXELS -------------------------------------------------------------------------------------
def analyse():
    pal = S["pal"]
    fill = pal["fill"]
    an = {}
    for k, (w, h, rows) in S["png1"].items():
        body, eye, glass, other = set(), set(), set(), []
        for y in range(h):
            for x in range(w):
                c = px(rows, x, y)
                if c[3] == 0:
                    continue
                if c == BODY:
                    body.add((x, y))
                elif c == pal["eye"]:
                    eye.add((x, y))
                elif c in (pal["glass"], pal["glint"]) or (c[:3] == fill[:3] and abs(c[3] - 255 * fill[3]) < 1.0):
                    glass.add((x, y))
                else:
                    other.append(((x, y), c))
        a = {"body": body, "eye": eye, "glass": glass, "other": other, "w": w, "h": h}
        if body:
            a["bt"] = min(y for _, y in body)
            a["bottom"] = max(y for _, y in body) + 1          # feet edge, in units
        an[k] = a
    S["an"] = an


def tag(k):
    return "%s_%d" % k


def p_colours():
    p = []
    for k, a in S["an"].items():
        helmet = k[0] in HELMET_BASE
        for (x, y), c in a["other"][:3]:
            p.append("%s: pixel (%d,%d)=%s is not in the palette" % (tag(k), x, y, c))
        if a["glass"] and not helmet:
            p.append("%s: glass pixels in a non-helmet pose" % tag(k))
        if helmet and not a["glass"]:
            p.append("%s: helmet pose without glass" % tag(k))
    return p, "every opaque pixel is body, eye%s from the atlas palette" % " or glass (helmet poses only)"


def p_body_colour():
    p = []
    for k, a in S["an"].items():
        w, h, rows = S["png1"][k]
        if not a["body"]:
            p.append("%s: no body pixels" % tag(k))
            continue
        bt = a["bt"]
        # the torso block must be exactly rgb(215,119,87,255), apart from the eye units
        for y in range(bt, bt + TORSO_ROWS):
            for x in BODY_X:
                c = px(rows, x, y)
                if c != BODY and (x, y) not in a["eye"]:
                    p.append("%s: body pixel (%d,%d)=%s, want exactly %s" % (tag(k), x, y, c, BODY))
    return p, "body colour is exactly rgb(215,119,87) in %d frames" % len(S["an"])


def p_torso():
    p = []
    for k, a in S["an"].items():
        if not a["body"]:
            continue
        bt = a["bt"]
        sil = a["body"] | a["eye"]
        top = sorted(x for x, y in a["body"] if y == bt)
        if top != list(BODY_X):
            p.append("%s: top body row %d spans x=%s, want 8 units x=2..9" % (tag(k), bt, top))
        for y in range(bt, bt + TORSO_ROWS):
            miss = [x for x in BODY_X if (x, y) not in sil]
            if miss:
                p.append("%s: torso row %d lacks x=%s" % (tag(k), y, miss))
        if bt < 0 or bt + TORSO_ROWS > a["h"]:
            p.append("%s: torso rows %d..%d leave the canvas" % (tag(k), bt, bt + TORSO_ROWS - 1))
    return p, "body is 8 units wide (x=2..9) and %d rows tall in every frame" % TORSO_ROWS


def p_arms():
    p = []
    for k, a in S["an"].items():
        if not a["body"]:
            continue
        bt = a["bt"]
        for cols in ARM_COLS:
            arm = {(x, y) for x, y in a["body"] if x < 2 or x > 9} & {(x, y) for x in cols for y in range(a["h"])}
            ys = sorted({y for _, y in arm})
            if len(arm) != 4 or sorted({x for x, _ in arm}) != list(cols) or len(ys) != 2 or ys[1] != ys[0] + 1:
                p.append("%s: arm at x=%s is %s, want one 2x2 block" % (tag(k), cols, sorted(arm)))
            elif ys[0] < bt or ys[1] > bt + TORSO_ROWS - 1:
                p.append("%s: arm at x=%s rows %s leave the torso rows %d..%d" % (tag(k), cols, ys, bt, bt + TORSO_ROWS - 1))
    return p, "two 2-unit-wide, 2-unit-tall arms at x=0-1 and x=10-11 on the torso in every frame"


def p_legs():
    p = []
    for k, a in S["an"].items():
        if not a["body"]:
            continue
        bt = a["bt"]
        below = {(x, y) for x, y in a["body"] if y >= bt + TORSO_ROWS}
        stray = sorted(x for x, _ in below if x not in LEG_COLS)
        if stray:
            p.append("%s: body pixels below the torso outside the leg columns, x=%s" % (tag(k), sorted(set(stray))))
        for x in LEG_COLS:
            ys = sorted(y for lx, y in below if lx == x)
            if not ys or ys != list(range(bt + TORSO_ROWS, bt + TORSO_ROWS + len(ys))) or len(ys) > 3:
                p.append("%s: leg at x=%d has rows %s, want 1..3 units hanging from the torso" % (tag(k), x, ys))
    return p, "four legs at x=2,4,7,9, 1..3 units long, attached to the torso in every frame"


def p_eyes():
    p = []
    for k, a in S["an"].items():
        if not a["body"]:
            continue
        eyes = sorted(a["eye"])
        ey = a["bt"] + 1
        if any(y != ey or x not in BODY_X for x, y in eyes):
            p.append("%s: eye pixels %s are not inside the torso on row %d" % (tag(k), eyes, ey))
            continue
        xs = [x for x, _ in eyes]
        if k[0] in CLOSED_EYE_POSES:
            runs = [xs[0:2], xs[2:4]]
            if len(xs) != 4 or any(r[1] != r[0] + 1 for r in runs) or xs[3] - xs[0] != 5 or xs[2] - xs[1] < 2:
                p.append("%s: closed eyes %s, want two separate 2x1 lines spanning the open-eye width (5)" % (tag(k), xs))
        else:
            if len(xs) != 2 or xs[1] - xs[0] != 5:
                p.append("%s: open eyes at x=%s, want two separate 1x1 units 5 apart" % (tag(k), xs))
    return p, "black eyes: two 1x1 units on the torso (blink and sleep: two 2x1 lines)"


def p_strays():
    p = []
    for k, a in S["an"].items():
        if not a["body"]:
            continue
        bt = a["bt"]
        for x, y in sorted(a["body"] | a["eye"]):
            torso = bt <= y < bt + TORSO_ROWS and x in BODY_X
            arm = bt <= y < bt + TORSO_ROWS and (x < 2 or x > 9)
            leg = y >= bt + TORSO_ROWS and x in LEG_COLS
            if not (torso or arm or leg):
                p.append("%s: stray body/eye pixel at (%d,%d)" % (tag(k), x, y))
    return p, "no pixel outside torso, arms and legs (no Zzz, sparkle, droplet, held item)"


def p_baseline():
    base = S["atlas"]["canvas"]["feet_baseline_y"]
    top = S["atlas"]["canvas"]["body_top_standing_y"]
    p = []
    for k, a in S["an"].items():
        if not a["body"]:
            continue
        name = k[0]
        if a["bottom"] > base:
            p.append("%s: feet at %d are below the baseline %d" % (tag(k), a["bottom"], base))
        if name in GROUND_POSES and a["bottom"] != base:
            p.append("%s: feet edge %d, want the baseline %d in every frame of this pose" % (tag(k), a["bottom"], base))
        if name in STANDING_POSES and a["bt"] != top:
            p.append("%s: body top %d, want body_top_standing_y %d" % (tag(k), a["bt"], top))
        if name in MOVING_POSES and not 0 <= base - a["bottom"] <= 2:
            p.append("%s: lift %d units, want 0..2" % (tag(k), base - a["bottom"]))
    for name in MOVING_POSES:
        lifts = [base - a["bottom"] for k, a in S["an"].items() if k[0] == name and a["body"]]
        if lifts and 0 not in lifts:
            p.append("%s: no frame touches the baseline (lifts %s)" % (name, lifts))
    return p, "feet baseline row %d in every pose; only listen/helmet-listen/hop rise above it" % (base - 1)


def p_hop():
    base = S["atlas"]["canvas"]["feet_baseline_y"]
    frames = sorted((k, a) for k, a in S["an"].items() if k[0] == "hop")
    p = []
    lifts = [base - a["bottom"] for _, a in frames]
    if not frames:
        return ["no hop frames"], ""
    if min(lifts) < 0:
        p.append("hop goes below the baseline: lifts %s" % lifts)
    if max(lifts) < 1:
        p.append("hop never leaves the baseline: lifts %s" % lifts)
    if lifts[-1] != 0:
        p.append("hop does not land on the baseline: lifts %s" % lifts)
    cols = {tuple(sorted(x for x, y in a["body"] if y == a["bt"])) for _, a in frames}
    if cols != {BODY_X}:
        p.append("hop moves sideways: top-row columns %s" % sorted(cols))
    return p, "hop lifts per frame %s (up only, back to the baseline, no sideways move)" % lifts


def p_helmet():
    p = []
    atlas = S["atlas"]["poses"]
    for h, b in HELMET_BASE.items():
        if h not in atlas or b not in atlas:
            continue
        for key in ("ms", "loop"):
            if atlas[h][key] != atlas[b][key]:
                p.append("%s: %s differs from %s" % (h, key, b))
        if len(atlas[h]["frames"]) != len(atlas[b]["frames"]):
            p.append("%s has %d frames, %s has %d" % (h, len(atlas[h]["frames"]), b, len(atlas[b]["frames"])))
            continue
        for i in range(len(atlas[h]["frames"])):
            kh, kb = (h, i), (b, i)
            if kh not in S["an"] or kb not in S["an"]:
                continue
            ah, ab = S["an"][kh], S["an"][kb]
            if (ah["body"], ah["eye"]) != (ab["body"], ab["eye"]):
                p.append("%s differs from %s in the body/eye pixels" % (tag(kh), tag(kb)))
            lo, hi = ah["bt"] - 3, ah["bt"] + 6
            bad = [(x, y) for x, y in ah["glass"] if not lo <= y <= hi]
            if bad:
                p.append("%s: glass pixels outside the dome rows %d..%d: %s" % (tag(kh), lo, hi, bad[:3]))
    return p, "helmet-idle/helmet-listen are idle/listen plus glass inside the dome rows"


# ---- ELEMENTS -----------------------------------------------------------------------------------
def e_load():
    S["el"] = load_json(os.path.join(S["art"], "claude-code-elements.json"))
    keys = list(S["el"])
    p = []
    if len(keys) != 13:
        p.append("%d top-level keys, want 13: %s" % (len(keys), keys))
    for k in REQUIRED_ELEMENT_KEYS:
        if k not in S["el"]:
            p.append("missing key %s" % k)
    items = S["el"].get("_meta", {}).get("items")
    if items != [k for k in keys if not k.startswith("_")]:
        p.append("_meta.items %s does not list the 12 element keys in order" % items)
    return p, "13 keys incl. " + ", ".join(REQUIRED_ELEMENT_KEYS)


def e_binary():
    el = S["el"]
    p = []
    if el["_meta"].get("claude_code_version") != REFERENCE_VERSION:
        p.append("_meta.claude_code_version=%r, but the pinned reference is %s" % (el["_meta"].get("claude_code_version"), REFERENCE_VERSION))
    b = binary()
    digest = hashlib.sha256(b.m).hexdigest()
    if digest != REFERENCE_SHA256:
        p.append("%s is not the official %s build (sha256 %s)" % (b.path, REFERENCE_VERSION, digest))
    return p, "%s readable, %d bytes, sha256 %s" % (b.path, b.size, digest[:12])


def offset_paths(d, path=()):
    found = []
    if isinstance(d, dict):
        for k, v in d.items():
            if type(v) is int and ("offset" in k.lower() or (path and path[-1] == "offsets")):
                found.append(path + (k,))
            else:
                found += offset_paths(v, path + (k,))
    elif isinstance(d, list):
        for i, v in enumerate(d):
            found += offset_paths(v, path + (i,))
    return found


# (offset path, cited-source path or None, bytes before the offset where the cited string starts)
FIA = ("spinner_timing", "frame_index_formula")
SIS = ("spinner_timing", "small_inline_spinner")
CITATIONS = [
    (("_meta", "version_offset"), None, 0),
    (("spinner_glyphs", "offset"), ("spinner_glyphs", "source"), 0),
    (("spinner_glyphs", "selector_offset"), ("spinner_glyphs", "selector_source"), 0),
    (("spinner_timing", "clock_tick_ms", "offset"), ("spinner_timing", "clock_tick_ms", "source"), 0),
    (FIA + ("offsets", "Xn"), FIA + ("source", 0), 0),
    (FIA + ("offsets", "aDe"), FIA + ("source", 1), 0),
    (FIA + ("offsets", "qn"), FIA + ("source", 2), 0),
    (FIA + ("offsets", "Rde_index_read"), FIA + ("source", 3), 0),
    (SIS + ("offsets", "ka_120"), SIS + ("source", 0), 0),
    (SIS + ("offsets", "frame_pick"), SIS + ("source", 1), 0),
    (("spinner_timing", "reduced_motion_dot", "offset"), ("spinner_timing", "reduced_motion_dot", "source"), 0),
    (("verb_shimmer", "offsets", "glimmer_formula"), ("verb_shimmer", "source", 0), 60),
    (("verb_shimmer", "offsets", "zn_le"), ("verb_shimmer", "source", 1), 0),
    (("present_verbs", "offset"), ("present_verbs", "source_head"), 0),
    (("ellipsis", "offset"), ("ellipsis", "source"), 0),
    (("past_verbs", "offset"), ("past_verbs", "source"), 0),
    (("past_verbs", "pick_rule_offset"), ("past_verbs", "pick_rule_source"), 0),
    (("turn_complete_line", "prefix_glyph_offset"), ("turn_complete_line", "prefix_glyph_source"), 40),
    (("turn_complete_line", "template_offset"), ("turn_complete_line", "template_source"), 150),
    (("turn_complete_line", "duration_offset"), ("turn_complete_line", "duration_source"), 0),
    (("interrupt", "component_offset"), ("interrupt", "component_source"), 0),
    (("interrupt", "prefix_offset"), ("interrupt", "prefix_source"), 0),
    (("error_line", "offset"), ("error_line", "source"), 330),
    (("input_box", "prompt_prefix_function_offset"), ("input_box", "prompt_prefix_source"), 0),
    (("input_box", "border_function_offset"), ("input_box", "border_function_source"), 0),
    (("input_box", "round_chars_offset"), ("input_box", "round_chars_source"), 0),
    (("input_box", "pointer_unicode_offset"), None, 0),
    (("input_box", "pointer_ascii_offset"), None, 0),
    (("theme_colors_dark", "palette_offset"), None, 0),
    (("theme_colors_dark", "switch_offset"), ("theme_colors_dark", "switch_source"), 400),
    (("theme_colors_dark", "spinner_color_defaults_offset"), ("theme_colors_dark", "spinner_color_defaults_source"), 0),
    (("welcome_clawd_block_art", "offsets", "jo_definition"), ("welcome_clawd_block_art", "source_head"), 0),
    (("welcome_clawd_block_art", "offsets", "component_aAe"), None, 0),
    (("welcome_clawd_block_art", "offsets", "apple_terminal_fallback_wt"), None, 0),
]


def derived_expectation(off_path, el):
    """Bytes that must sit at an offset which has no cited source string of its own."""
    last = off_path[-1]
    if last == "version_offset":
        return ('VERSION:"%s"' % el["_meta"]["claude_code_version"]).encode()
    if last == "pointer_unicode_offset":
        return ('pointer:"%s"' % jsesc(el["input_box"]["prompt_char"])).encode()
    if last == "pointer_ascii_offset":
        return ('pointer:"%s"' % el["input_box"]["prompt_char_fallback_ascii"]).encode()
    if last == "component_aAe":
        return b"function aAe("
    if last == "apple_terminal_fallback_wt":
        return b"function wt("
    if last == "palette_offset":
        # the palette object must open here and hold every cited theme value as key:"value"
        end = binary().until(get(el, off_path), b"}")
        text = end.decode("utf-8")
        want = "".join(['%s:"%s"' % (k, v) for k, v in el["theme_colors_dark"]["values"].items()])
        for k, v in el["theme_colors_dark"]["values"].items():
            if ('%s:"%s"' % (k, v)) not in text:
                raise ValueError("palette at the offset has no %s:\"%s\"" % (k, v))
        return b"p={"
    raise KeyError(last)


def e_coverage():
    el = S["el"]
    found = set(offset_paths(el))
    listed = {c[0] for c in CITATIONS}
    p = ["offset %s is cited in the JSON but not checked here" % ".".join(map(str, x)) for x in sorted(found - listed, key=str)]
    p += ["checker lists %s but the JSON has no such offset" % ".".join(map(str, x)) for x in sorted(listed - found, key=str)]
    return p, "all %d absolute byte offsets in the elements JSON are covered" % len(found)


def make_citation_check(off_path, src_path, before):
    def fn():
        el = S["el"]
        off = get(el, off_path)
        if type(off) is not int or off < 0:
            return ["offset %r is not a non-negative integer" % (off,)], ""
        if src_path is None:
            want = derived_expectation(off_path, el)
            got = binary().at(off, len(want))
            if got != want:
                return ["bytes at %d are %r, want %r" % (off, got[:60], want)], ""
            return [], "@%d the bytes start with %r" % (off, want.decode("utf-8")[:40])
        src = get(el, src_path)
        want = src.encode("utf-8")
        got = binary().at(off - before, len(want))
        if got != want:
            at = next((i for i in range(min(len(got), len(want))) if got[i] != want[i]), min(len(got), len(want)))
            return ["bytes at %d (-%d) differ from the cited string at byte %d: %r vs %r"
                    % (off, before, at, got[max(0, at - 10):at + 20], want[max(0, at - 10):at + 20])], ""
        return [], "@%d%s %d bytes equal the cited string" % (off, "-%d" % before if before else "", len(want))
    return fn


def e_counts():
    el = S["el"]
    p = []
    for key, n in (("present_verbs", EXPECTED_PRESENT_VERBS), ("past_verbs", EXPECTED_PAST_VERBS)):
        e = el[key]
        if e.get("count") != n or len(e.get("values", [])) != n:
            p.append("%s: count=%r, len(values)=%d, want %d" % (key, e.get("count"), len(e.get("values", [])), n))
    return p, "188 present verbs and 8 past verbs in the JSON"


def e_verbs_bytes():
    el = S["el"]
    p = []
    pv = text_at(el["present_verbs"]["offset"], '"Zigzagging"];')
    vals = js_str_array(pv[len("var v="):])
    if vals != el["present_verbs"]["values"]:
        p.append("present verbs in the binary (%d) differ from the JSON values (%d)" % (len(vals), len(el["present_verbs"]["values"])))
    if len(vals) != EXPECTED_PRESENT_VERBS:
        p.append("binary holds %d present verbs, want %d" % (len(vals), EXPECTED_PRESENT_VERBS))
    pa = text_at(el["past_verbs"]["offset"], "];")
    pvals = js_str_array(pa[len("var eg="):])
    if pvals != el["past_verbs"]["values"]:
        p.append("past verbs in the binary %r differ from the JSON %r" % (pvals, el["past_verbs"]["values"]))
    if len(pvals) != EXPECTED_PAST_VERBS:
        p.append("binary holds %d past verbs, want %d" % (len(pvals), EXPECTED_PAST_VERBS))
    rule = text_at(el["past_verbs"]["pick_rule_offset"], "}")
    m = re.match(r'var TN="([^"]*)";function og\(m\)\{let d=\(ede\(m\)>>>0\)%eg\.length', rule)
    if not m or m.group(1) != el["past_verbs"]["default"]:
        p.append("past-verb default/pick rule in the binary does not match default=%r" % el["past_verbs"]["default"])
    return p, "re-parsed from the binary: %d present verbs, %d past verbs, default %s" % (len(vals), len(pvals), el["past_verbs"]["default"])


def e_glyphs_bytes():
    el = S["el"]
    sg = el["spinner_glyphs"]
    txt = text_at(sg["offset"], ";function jbn(")
    named = {}
    for name, body in re.findall(r"(\w+)=\[([^\]]*)\]", txt):
        if "..." not in body:
            named[name] = js_str_array(body)
    p = []
    for name, key in (("p", "default_sequence"), ("l", "ghostty_sequence"), ("T", "other_sequence_T")):
        if named.get(name) != sg[key]:
            p.append("%s: binary array %s=%r differs from the JSON %r" % (key, name, named.get(name), sg[key]))
    if sg["ping_pong_array"] != sg["default_sequence"] + sg["default_sequence"][::-1]:
        p.append("ping_pong_array is not the default sequence followed by its reverse")
    return p, "spinner glyph arrays re-parsed from the binary: %s" % "".join(named.get("p", []))


def e_timing_bytes():
    el = S["el"]
    st = el["spinner_timing"]
    fia = st["frame_index_formula"]
    p = []
    clock = text_at(st["clock_tick_ms"]["offset"], ")")
    m = re.search(r'"requesting"&&!S\?(\d+):(\d+)\)', clock)
    if not m or (int(m.group(1)), int(m.group(2))) != (st["clock_tick_ms"]["requesting_mode_ms"], st["clock_tick_ms"]["value"]):
        p.append("clock tick in the binary %r vs JSON %r/%r" % (m and m.groups(), st["clock_tick_ms"]["requesting_mode_ms"], st["clock_tick_ms"]["value"]))
    qn = text_at(fia["offsets"]["qn"], ",qn=2000,")
    if "qn=%d," % fia["period_ms"] not in qn:
        p.append("period_ms %r is not the qn value in the binary" % fia["period_ms"])
    ka = text_at(st["small_inline_spinner"]["offsets"]["ka_120"], ")")
    if "ka(t?null:%d)" % st["small_inline_spinner"]["frame_ms"] not in ka:
        p.append("small spinner frame_ms %r is not in the binary" % st["small_inline_spinner"]["frame_ms"])
    dot = text_at(st["reduced_motion_dot"]["offset"], "M=2000")
    if not dot.startswith('var _wt="%s"' % jsesc(st["reduced_motion_dot"]["glyph"])) or "M=%d" % st["reduced_motion_dot"]["pulse_period_ms"] not in dot:
        p.append("reduced-motion dot %r / pulse %r not in the binary" % (st["reduced_motion_dot"]["glyph"], st["reduced_motion_dot"]["pulse_period_ms"]))
    glyphs = el["spinner_glyphs"]["default_sequence"]
    if fia["glyph_count"] != len(glyphs):
        p.append("glyph_count %r != %d glyphs" % (fia["glyph_count"], len(glyphs)))
    tl = st["derived_timeline_100ms_ticks"]
    ts = list(range(0, fia["period_ms"], st["clock_tick_ms"]["value"]))
    idx = [int(math.floor(((1 - math.cos(2 * math.pi * t / fia["period_ms"])) / 2) * (len(glyphs) - 1) + 0.5)) for t in ts]
    if tl["t_ms"] != ts or tl["index"] != idx or tl["glyphs"] != [glyphs[i] for i in idx]:
        p.append("derived_timeline_100ms_ticks does not follow from the cosine formula and the glyph array")
    return p, "spinner timing numbers match the binary; timeline recomputed (%d ticks)" % len(ts)


def e_shimmer_bytes():
    el = S["el"]
    vs = el["verb_shimmer"]
    p = []
    gl = text_at(vs["offsets"]["glimmer_formula"], "zn")
    m = re.search(r'J=l==="requesting"\?(\d+):zn', gl)
    if not m or int(m.group(1)) != vs["modes"]["requesting"]["step_ms"]:
        p.append("requesting step_ms %r not in the binary" % vs["modes"]["requesting"]["step_ms"])
    zn = text_at(vs["offsets"]["zn_le"], "le=10")
    m = re.match(r"zn=(\d+),le=(\d+)", zn)
    if not m or int(m.group(1)) != vs["modes"]["other (thinking/responding)"]["step_ms"] or int(m.group(2)) != vs["pad_cols"]:
        p.append("shimmer step/pad %r vs JSON %r/%r" % (m and m.groups(), vs["modes"]["other (thinking/responding)"]["step_ms"], vs["pad_cols"]))
    return p, "shimmer steps 50/200 ms and pad 10 columns match the binary"


def e_strings_bytes():
    el = S["el"]
    p = []
    ell = text_at(el["ellipsis"]["offset"], '",')
    if ell != 'ellipsis:"%s",' % jsesc(el["ellipsis"]["value"]):
        p.append("ellipsis %r not at the offset: %r" % (el["ellipsis"]["value"], ell))
    tc = el["turn_complete_line"]
    ja = text_at(tc["prefix_glyph_offset"], '",')
    if ja != '%s="%s",' % (tc["prefix_glyph_name"], jsesc(tc["prefix_glyph"])):
        p.append("turn-complete glyph %r not at the offset: %r" % (tc["prefix_glyph"], ja))
    tmpl = binary().at(tc["template_offset"], 40).decode("utf-8", "replace")
    if " for " not in tmpl or "${B}" not in tmpl:
        p.append("turn-complete template at the offset is %r" % tmpl)
    want_dur = b"function nn(e,t){if(e<60000)"
    dur = binary().at(tc["duration_offset"], len(want_dur))
    if dur != want_dur:
        p.append("duration function at the offset is %r" % dur)
    pasts = set(el["past_verbs"]["values"])
    for ex in tc["examples"]:
        m = re.fullmatch(r"%s (\S+) for .+" % re.escape(tc["prefix_glyph"]), ex)
        if not m or m.group(1) not in pasts:
            p.append("example %r is not '<glyph> <past verb> for <duration>'" % ex)
    it = el["interrupt"]
    comp = text_at(it["component_offset"], "}")
    if comp != 'function Ka(){return"%s"}' % it["string_with_followup"].split(" \u00b7 ", 1)[1]:
        p.append("follow-up text in the binary is %r" % comp)
    cb = binary().until(it["component_offset"], b"function Qg(){").decode("utf-8")
    if 'children:"%s"}' % it["string"] not in cb:
        p.append("interrupt string %r is not a children:\"...\" literal in the component at %d" % (it["string"], it["component_offset"]))
    if 'children:"%s "}' % it["string"] not in cb or '["\\xB7 ",Ka()]' not in cb:
        p.append("the follow-up form 'Interrupted \\xB7 <Ka()>' is not in the component")
    pre = text_at(it["prefix_offset"], "]")
    m = re.search(r'\["((?:[^"\\]|\\.)*)","((?:[^"\\]|\\.)*)"\]', pre)
    if not m or unesc(m.group(1)) + unesc(m.group(2)) != it["prefix"]:
        p.append("interrupt prefix in the binary is %r, JSON has %r" % (m and (unesc(m.group(1)) + unesc(m.group(2))), it["prefix"]))
    # the binary's prefix ends in a no-break space; rendered shows it as a plain space (same glyph width)
    if it["rendered"] != (it["prefix"] + it["string"]).replace("\u00a0", " "):
        p.append("interrupt.rendered %r is not prefix + string (no-break space shown as a space)" % it["rendered"])
    if it["string_with_followup"] != it["string"] + " \u00b7 " + it["string_with_followup"].split(" \u00b7 ", 1)[1]:
        p.append("string_with_followup does not start with the interrupt string")
    er = el["error_line"]
    ew = binary().at(er["offset"], 40).decode("utf-8", "replace")
    if not ew.startswith("else l=`%s${p}`" % er["text_prefix"]):
        p.append("error prefix %r not at the offset: %r" % (er["text_prefix"], ew))
    if er["form"] != "  \u23bf  %s<message>" % er["text_prefix"]:
        p.append("error_line.form %r does not use the prefix %r" % (er["form"], er["text_prefix"]))
    return p, "ellipsis, turn-complete glyph/template, interrupt (%r), error prefix (%r) match the binary" % (it["string"], er["text_prefix"])


def e_inputbox_bytes():
    el = S["el"]
    ib = el["input_box"]
    p = []
    rc = text_at(ib["round_chars_offset"], "}")
    chars = {k: unesc(v) for k, v in re.findall(r'(\w+):"((?:[^"\\]|\\.)*)"', rc)}
    if chars != ib["border_chars_round"]:
        p.append("round border chars in the binary %r differ from the JSON %r" % (chars, ib["border_chars_round"]))
    bf = text_at(ib["border_function_offset"], "}}")
    if 'borderStyle:"round"' not in bf or "borderLeft:!1,borderRight:!1,borderBottom:!0" not in bf:
        p.append("border function in the binary is not round/left+right off/bottom on")
    pp = binary().at(ib["prompt_prefix_function_offset"], len(ib["prompt_prefix_source"].encode("utf-8")))
    if b")+yzs}" not in pp or b":te.pointer)" not in pp:
        p.append("prompt prefix function does not use te.pointer")
    return p, "input box border chars %s and prompt chars %s/%s match the binary" % ("".join(chars.values()), ib["prompt_char"], ib["prompt_char_fallback_ascii"])


def e_theme_bytes():
    el = S["el"]
    th = el["theme_colors_dark"]
    p = []
    txt = text_at(th["palette_offset"], "}")
    pal = dict(re.findall(r'(\w+):"([^"]*)"', txt))
    for k, v in th["values"].items():
        if pal.get(k) != v:
            p.append("theme %s: binary %r, JSON %r" % (k, pal.get(k), v))
    roles = th["roles"]
    for role, key in (("claude_orange", "claude"), ("spinner_shimmer", "claudeShimmer"), ("dim_inactive_gray", "inactive"),
                      ("input_border_gray", "promptBorder"), ("error_red", "error"), ("success_green", "success")):
        if roles.get(role) != th["values"][key]:
            p.append("roles.%s=%r != values.%s=%r" % (role, roles.get(role), key, th["values"][key]))
    return p, "%d dark-theme colours match the palette object in the binary" % len(th["values"])


def e_body_cross():
    th = S["el"]["theme_colors_dark"]["values"]
    want = S["atlas"]["palette"]["body"]
    p = []
    for k in ("claude", "clawd_body"):
        if th[k] != want:
            p.append("theme %s=%r, atlas palette.body=%r" % (k, th[k], want))
    return p, "atlas body colour == Claude Code theme claude == clawd_body == %s" % want


def parse_welcome():
    el = S["el"]
    w = el["welcome_clawd_block_art"]
    raw = binary().until(w["offsets"]["jo_definition"], b"function FZn(o)").decode("utf-8")[:-len("function FZn(o)")]
    seg = {}
    for part in re.split(r",(?=(?:Xe|Je|Qe|Ze|to)=)", raw):
        m = re.match(r"(?:var )?(jo|Xe|Je|Qe|Ze|to)=", part)
        if m:
            seg[m.group(1)] = unesc(part[m.end():])
    arms = {}
    for k in ("down", "up"):
        m = re.search(r'"?%s"?:\{r1L:"([^"]*)",r1R:"([^"]*)",r2L:"([^"]*)",r2R:"([^"]*)"\}' % k, seg["Xe"])
        arms[k] = dict(zip(("r1L", "r1R", "r2L", "r2R"), m.groups()))
    eyes = {}
    for k in ("open", "left", "right", "closed", "wink"):
        body = re.search(r"(?<![\w-])%s:\[(.*?)\](?:,|\})" % k, seg["Je"]).group(1)
        eyes[k] = re.findall(r'glyphs:"([^"]*)"', body)
    feet = dict(re.findall(r'(\w+):"([^"]*)"', seg["Qe"]))
    poses = {n.strip('"'): (e, a, f) for n, e, a, f in re.findall(r'("[\w-]+"|default):\{eyes:"(\w+)",arms:"(\w+)",feet:"(\w+)"\}', seg["jo"])}
    rows = {n: [arms[a]["r1L"] + "".join(eyes[e]) + arms[a]["r1R"], arms[a]["r2L"] + "\u2588" * 5 + arms[a]["r2R"], feet[f]]
            for n, (e, a, f) in poses.items()}
    return arms, eyes, feet, poses, rows


def e_welcome_bytes():
    w = S["el"]["welcome_clawd_block_art"]
    arms, eyes, feet, poses, rows = parse_welcome()
    p = []
    if w["segments"]["arms"] != arms:
        p.append("arm segments differ from the binary")
    if w["segments"]["eyes"] != eyes:
        p.append("eye segments differ from the binary")
    for k, v in w["segments"]["feet"].items():
        if feet.get(k) != v:
            p.append("feet segment %s: binary %r, JSON %r" % (k, feet.get(k), v))
    if w["assembled_rows_per_pose"] != rows:
        p.append("assembled_rows_per_pose differ from rows rebuilt out of the binary segments")
    if w["assembled_rows_default_pose"] != rows.get("default"):
        p.append("assembled_rows_default_pose is not the rebuilt default pose")
    if {k: (v["eyes"], v["arms"], v["feet"]) for k, v in w["poses_defined"].items()} != poses:
        p.append("poses_defined differ from the binary")
    if len(w["assembled_rows_default_pose"]) != 3:
        p.append("block art must be 3 rows")
    return p, "welcome-screen block art rebuilt from the binary segments: %d poses, default rows %s" % (len(rows), rows.get("default"))


# ---- PREVIEW ------------------------------------------------------------------------------------
def v_load():
    path = os.path.join(S["art"], "preview", "index.html")
    S["html"] = open(path, encoding="utf-8").read()
    p = [] if len(S["html"]) > 1000 else ["preview/index.html is only %d chars" % len(S["html"])]
    return p, "preview/index.html %d chars" % len(S["html"])


def v_poses():
    html = S["html"]
    atlas = S["atlas"]["poses"]
    p = []
    rows = re.findall(r'<div class="name">([^<]+)<small>', html)
    if rows != list(atlas):
        p.append("pose rows in the page %s, atlas poses %s" % (rows, list(atlas)))
    n = 0
    for name, pose in atlas.items():
        for i, f in enumerate(pose["frames"]):
            want = '<img src="frames4x/%s" alt="%s frame %d"><figcaption>%d ms</figcaption>' % (os.path.basename(f), name, i, pose["ms"][i])
            n += 1
            if want not in html:
                p.append("page has no figure for %s frame %d (%s)" % (name, i, os.path.basename(f)))
    alts = set(re.findall(r'alt="(.*?) frame \d+"', html))
    if alts - set(atlas):
        p.append("page shows poses that the atlas does not have: %s" % sorted(alts - set(atlas)))
    return p, "page references all %d poses and %d frames with the atlas ms" % (len(atlas), n)


def v_files():
    art = S["art"]
    pv = os.path.join(art, "preview", "frames4x")
    p = []
    refs = set()
    for _, _, f in referenced():
        b = os.path.basename(f)
        refs.add(b)
        a, c = os.path.join(art, S["atlas"]["scale4x_dir"], b), os.path.join(pv, b)
        if not os.path.isfile(c):
            p.append("preview/frames4x/%s missing" % b)
        elif open(a, "rb").read() != open(c, "rb").read():
            p.append("preview/frames4x/%s differs from %s/%s" % (b, S["atlas"]["scale4x_dir"], b))
    extra = {n for n in os.listdir(pv) if not n.startswith(".")} - refs
    p += ["preview/frames4x/%s is not an atlas frame" % n for n in sorted(extra)]
    return p, "preview/frames4x holds byte-identical copies of the %d 4x frames" % len(refs)


def embedded_data():
    html = S["html"]
    i = html.index("const DATA = ") + len("const DATA = ")
    data, _ = json.JSONDecoder().raw_decode(html, i)
    return data


def v_embedded():
    data = embedded_data()
    el = S["el"]
    p = []
    v1_part = {k: v for k, v in S["atlas"].items() if k in ("unit", "canvas", "palette", "scale4x_dir", "poses")}
    if data["atlas"] != v1_part:
        p.append("atlas embedded in the page differs from the v1 keys of clawd-atlas.json")
    e = data["elements"]
    pairs = [("version", el["_meta"]["claude_code_version"]), ("glyphs", el["spinner_glyphs"]["default_sequence"]),
             ("verbs", el["present_verbs"]["values"]), ("pastVerbs", el["past_verbs"]["values"]),
             ("interrupt", el["interrupt"]["string"]), ("promptChar", el["input_box"]["prompt_char"]),
             ("theme", {k: el["theme_colors_dark"]["values"][k] for k in e["theme"]})]
    for k, want in pairs:
        if e.get(k) != want:
            p.append("page elements.%s differs from claude-code-elements.json" % k)
    return p, "atlas and element data embedded in the page equal the files on disk"


# ---- v2: the schema 2 catalog (spec-clawd-pet-v2 section 3.1 and the Interface Contract) ---------------------------------------------
# Everything below is an independent re-derivation: it reads the official Lottie files and the shipped PNGs and shares no code with
# scripts/port-official-art.py. Check ids are prefixed "v2:" because v1 already uses P1..P10.
V1_KEYS = ["unit", "canvas", "palette", "scale4x_dir", "poses"]
V2_MIN_IDLE = 6                # spec 3.1 K1: a look keeps at least 6 compatible idle motions
V2_KEYS = ["schema", "motions", "looks"]
V2_PET_BODY = (215, 119, 87)
PET_EYE = (20, 20, 19)
CELL = 50                      # source px per cell (a half unit); one PNG pixel of a v2 frame is one cell
CANVAS_CELLS = 24              # 12 units
SRC_W, SRC_H, SRC_Y0 = 2750, 1850, 650
FPS = 12
FACE_W, FACE_H = 16, 6
V2_SCENE_USES = ("listening", "thinking", "sent", "interrupted", "error")
V2_USES = {"idle", "walk", "walk-pause", "listening", "thinking", "sent", "interrupted", "error", "touch", "multi-touch", "drop",
           "entrance", "sleep-entry", "ride"}
V2_LOOK_IDS = ["plain", "helmet", "sunglasses", "headphones", "pool-float", "shiny", "coffee", "detective", "wand", "skateboard",
               "wizard", "cowboy", "scientist", "ultra", "winter"]
# spec 3.2, A items: motion id -> (source file stem, declared uses). A1 and A5 also have the derived entries below.
V2_ITEMS = {
    "A1-thinking": ("Clawd-Thinking", ["idle"]),
    "A1-thinking-nobubble": ("Clawd-Thinking", ["thinking"]),
    "A2-looking": ("clawd-looking", ["idle", "listening", "walk-pause"]),
    "A3-jumping": ("Clawd-Jumping", ["sent", "touch", "idle", "drop"]),
    "A3-jumping-happy": ("Clawd-JumpingHappy", ["sent", "touch", "idle", "drop"]),
    "A4-waving": ("clawd-waving", ["sent", "touch", "idle"]),
    "A5-walking": ("clawd-walking", ["walk"]),
    "A5-walking-mirrored": ("clawd-walking", ["walk"]),
    "A6-turning": ("Clawd-Turning", ["idle", "multi-touch"]),
    "A7-swaying": ("Clawd-Swaying", ["idle"]),
    "A8-excited": ("Clawd-Excited", ["sent", "touch", "idle", "drop"]),
    "A9-dancing": ("Clawd-Dancing", ["idle"]),
    "A9-dancing-happy": ("Clawd-DancingHappy", ["idle"]),
    "A10-breakdancing": ("Clawd-BreakDancing", ["idle"]),
    "A11-confetti": ("Clawd-Confetti", ["idle"]),
    "A11-confetti-happy": ("Clawd-ConfettiHappy", ["idle"]),
    "A12-heart": ("Clawd-Heart", ["touch", "idle"]),
    "A13-rainbow": ("Clawd-Rainbow", ["idle"]),
    "A14-lightbulb": ("Clawd-Lightbulb", ["idle"]),
    "A15-snooze": ("Clawd-Snooze", ["sleep-entry"]),
    "A16-meditating": ("Clawd-Meditating", ["idle"]),
    "A17-sunglasses": ("Clawd-Sunglasses", ["idle"]),
    "A18-headphones": ("Clawd-Headphones", ["idle", "signature:headphones"]),
    "A19-coffee": ("Clawd-Coffee", ["idle", "signature:coffee"]),
    "A20-laptop": ("Clawd-Laptop", ["thinking", "idle"]),
    "A21-desktop": ("Clawd-Desktop", ["idle"]),
    "A22-notebook": ("Clawd-Notebook", ["thinking", "idle"]),
    "A23-phone": ("Clawd-Phone", ["idle"]),
    "A24-watch": ("Clawd-Watch", ["idle"]),
    "A25-spark": ("Clawd-Spark", ["idle", "signature:wand", "signature:ultra"]),
    "A26-juggling": ("Clawd-Juggling", ["idle"]),
    "A27-hulahoop": ("Clawd-HulaHoop", ["idle"]),
    "A28-bubble": ("Clawd-Bubble", ["idle"]),
    "A29-fishing": ("Clawd-Fishing", ["idle"]),
    "A30-watering": ("Clawd-Watering", ["idle"]),
    "A31-blooming": ("Clawd-Blooming", ["idle"]),
    "A32-berrypicking": ("Clawd-BerryPicking", ["idle"]),
    "A33-rose": ("Clawd-Rose", ["touch", "idle"]),
    "A34-arcade": ("Clawd-Arcade", ["idle"]),
}
V2_PHASE1_LOOKS = ["plain", "helmet", "sunglasses", "headphones", "coffee", "wand"]
V2_LOOK_PHASE = {"plain": 1, "helmet": 1, "sunglasses": 1, "headphones": 1, "pool-float": 2, "shiny": 2, "coffee": 2, "detective": 2,
                 "wand": 2, "skateboard": 2, "wizard": 3, "cowboy": 3, "scientist": 3, "ultra": 4, "winter": 4}                     # spec 3.3
# spec 3.2 / 3.4 / 9b: the phase 2 motions: id -> (source kind, board, declared uses)
V2_PHASE2_ITEMS = {
    "D4-happy": ("redrawn", "D4", ["touch", "sent"]),
    "D5-dizzy": ("redrawn", "D5", ["multi-touch", "error"]),
    "D6-heart": ("redrawn", "D6", ["touch", "idle"]),
    "D11-lightbulb": ("redrawn", "D11", ["idle"]),
    "D12-inspect": ("gif", "D12", ["idle", "signature:detective"]),
    # the skateboard's glide (amendment "the skateboard ride"): sprite 1 frames 23-61; a use that no idle or reaction pool picks
    "D14-ride": ("sprite", "D14", ["ride"]),
    # the calm idle motions (round 3): the B vocabulary of spec 3.2 (render-core.js:3, :139-152), redrawn on the pet grid
    "B3-glance-left": ("redrawn", "B3", ["idle"]),
    "B3-glance-right": ("redrawn", "B3", ["idle"]),
    "B3-glance-left-long": ("redrawn", "B3", ["idle"]),
    "B3-glance-right-long": ("redrawn", "B3", ["idle"]),
    "B4-wink": ("redrawn", "B4", ["idle"]),
    "B4-slow-blink": ("redrawn", "B4", ["idle"]),
    "B5-foot-tap": ("redrawn", "B5", ["idle"]),
}
# spec 3.3 / 3.4 / 9b: the phase 3 motion (Sprint 7): id -> (source kind, board, declared uses)
V2_PHASE3_ITEMS = {
    "D19-happy-caret": ("redrawn", "D19", ["touch", "sent"]),
}
# the official plushie pictures (reference board img/official/plush, copied into art/sources/plush): D15 wizard, D16 cowboy, D17 scientist, D18 sunglasses
# (the check of the phase 1 look), D19 happy
V2_PLUSH = {"D15": "sources/plush/wizard.png", "D16": "sources/plush/cowboy.png", "D17": "sources/plush/scientist.png",
            "D18": "sources/plush/sunglasses.png", "D19": "sources/plush/happy.png"}
V2_POSE_BOARDS = {"B3", "B4", "B5", "B7"}
V2_POSE_SOURCE = "sources/claude-code/render-core.js"
V2_POSE_LINES = ["3", "107-125", "139-152"]
# what each change of a B item must find in the cited lines of render-core.js: (line range, text) pairs
V2_POSE_VOCABULARY = {
    "eyes:look-left": [("3", '"look-left":{eyes:"left"'), ("3", 'left:[{glyphs:"▟███▟█"}]'), ("139-152", 'f.eyes === "left") p.eyeDx = -1'),
                       ("107-125", 'put(3 + dx, ey, PX.eye); put(8 + dx, ey, PX.eye)')],
    "eyes:look-right": [("3", '"look-right":{eyes:"right"'), ("3", 'right:[{glyphs:"█▟███▟"}]'), ("139-152", 'f.eyes === "right") p.eyeDx = 1'),
                        ("107-125", 'put(3 + dx, ey, PX.eye); put(8 + dx, ey, PX.eye)')],
    "eyes:wink": [("3", 'wink:[{glyphs:"▛███"},{glyphs:"▂",lid:!0},{glyphs:"█"}]'), ("139-152", 'f.eyes === "wink") p.eyes = "wink"'),
                  ("107-125", 'put(3 + dx, ey, PX.eye); put(7 + dx, ey, PX.eye); put(8 + dx, ey, PX.eye)')],
    "eyes:closed": [("3", 'closed:[{glyphs:"▂",lid:!0},{glyphs:"███"},{glyphs:"▂",lid:!0},{glyphs:"█"}]'), ("139-152", 'f.eyes === "closed") p.eyes = "closed"'),
                    ("107-125", '[3, 4, 7, 8].forEach')],
    "arm-right:lifted": [("3", '"one-up":{r1L:" ▐",r1R:"▄",r2L:"▝▜",r2R:"█▘"}'), ("9", 'arms:"one-up"'), ("139-152", 'f.arms === "one-up") p.armR = -1'),
                         ("107-125", 'put(10, bt + 2 + armR + dy, body)')],
    "legs:left-up": [("3", 'Qe={both:" ▝▝   ▝▝ ",left:" ▝▝      ",right:"      ▝▝ "}'), ("139-152", 'f.feet === "right") p.legs = [1, 1, 2, 2]'),
                     ("107-125", '[2, 4, 7, 9].forEach(function (lx, i) { for (var k = 0; k < legs[i]; k++) put(lx, bt + 6 + k, body); })')],
}
# the unit columns of the eyes (render-core.js:120-122) for each state of a B item's eyes, and the lower unit of the two left legs (:118, :150)
V2_EYE_UNITS = {"rest": (3, 8), "eyes:look-left": (2, 7), "eyes:look-right": (4, 9), "eyes:closed": (3, 4, 7, 8), "eyes:wink": (3, 7, 8)}
V2_EYE_ROW = 10                       # cell row of the eyes' first cell: unit row 5
V2_LEFT_LEGS_UP = {(i, j) for i in (4, 5, 8, 9) for j in (22, 23)}
V2_STICKERS = {"D4": "sources/sticker/happy.png", "D5": "sources/sticker/dizzy.png", "D6": "sources/sticker/heart.png",
               "D7": "sources/sticker/shiny.png", "D11": "sources/sticker/lightbulb.png"}
V2_GIF = "sources/persona/Clawd-Magnifier.gif"
V2_CHUNK = "sources/dev/3o01xgcny9qbw.js"
# spec 3.3 (weights, classes, signatures) for the phase 2 looks, with the layer attachments the producer declares
V2_LOOK_SPEC = {
    "pool-float": {"board": "D2", "class": {"torso-overlay", "costume"}, "weight": 0.5, "signature": [], "raise": 7,
                   "layers": [("ring-back", "back", "torso", True), ("ring-front", "front", "torso", True), ("sunglasses", "front", "head", True)]},
    # the border hugs the rest silhouette (fifth item): it is drawn behind the body, 1 cell (the sticker's band is about 0.67 cell) outside it; Clawd is lifted by its thickness
    "shiny": {"board": "D7", "class": {"torso-overlay"}, "weight": 0.5, "signature": [], "raise": 1,
              "layers": [("border", "back", "torso", False, "rest-silhouette"), ("sparkles", "front", "head", False)]},
    "coffee": {"board": "D9", "class": {"held"}, "weight": 1, "signature": ["A19-coffee"], "raise": 0, "layers": [("mug", "front", "arm-right", False)]},
    "detective": {"board": "D12", "class": {"costume", "held"}, "weight": 1, "signature": ["D12-inspect"], "raise": 0,
                  "layers": [("hat", "front", "head", True), ("magnifier", "front", "arm-right", False)]},
    "wand": {"board": "D13", "class": {"held"}, "weight": 1, "signature": ["A25-spark"], "raise": 0, "layers": [("wand", "front", "arm-right", False)]},
    "skateboard": {"board": "D14", "class": {"under-feet"}, "weight": 1, "signature": ["D14-ride"], "raise": 6, "layers": [("board", "front", "feet", False)]},
    # the plushie looks (Sprint 7). No signatures (spec 9b item 12): the wizard's hat would vanish on A25, and A14 would float the scientist's flask
    "wizard": {"board": "D15", "class": {"costume", "held"}, "weight": 1, "signature": [], "raise": 0, "onSignature": True,
               "layers": [("hat", "front", "head", True), ("wand", "front", "arm-right", False)]},
    "cowboy": {"board": "D16", "class": {"costume"}, "weight": 1, "signature": [], "raise": 0, "onSignature": True,
               "layers": [("hat", "front", "head", True)]},
    "scientist": {"board": "D17", "class": {"costume", "torso-overlay", "held"}, "weight": 1, "signature": [], "raise": 0, "onSignature": True,
                  "layers": [("goggles", "front", "head", True), ("coat", "front", "torso", True), ("flask", "front", "arm-right", False)]},
    # the body-colour looks (Sprint 8): a bodyColor map and, for winter, a static layer of snow behind the body
    "ultra": {"board": "B7", "class": {"body-color"}, "weight": 0.5, "signature": ["A25-spark", "B7-ultra-wand"], "raise": 0, "layers": []},
    "winter": {"board": "B8", "class": {"body-color"}, "weight": 0.5, "signature": [], "raise": 0, "layers": [("snow", "back", "body", False)]},
}
_POOL_MAP = [{"from": [216, 118, 86], "to": [215, 119, 87]}, {"from": [0, 0, 0], "to": [20, 20, 19]}]
_RING = [list(c) for c in [(249, 248, 244), (193, 217, 239), (105, 154, 203), (71, 108, 145)]]
_RING_CUT = {"kind": "sprite", "sprite": 6, "frame": 0, "colorMap": _POOL_MAP, "keep": _RING, "universeRows": [0, 27], "largestComponent": True,
             "headAt": [19, 6]}
# the cut of each layer as the spec's sources declare it (path and sha256 are checked against the files)
V2_CUT_PIN = {
    ("pool-float", "ring-back"): dict(_RING_CUT, rows=[0, 20], fill={"of": [215, 119, 87], "color": [71, 108, 145]}),
    ("pool-float", "ring-front"): dict(_RING_CUT, rows=[21, 27]),
    ("pool-float", "sunglasses"): {"kind": "sprite", "sprite": 6, "frame": 0, "colorMap": _POOL_MAP, "keep": [[20, 20, 19]], "headAt": [19, 6]},
    ("shiny", "border"): {"kind": "border", "cells": 1, "reach": "3x3-without-corners", "silhouette": "rest", "sectors": 24, "depth": 9.0},
    ("shiny", "sparkles"): {"kind": "sparkle", "stars": [
        {"at": [-12, -7], "rows": ["..c..", "..a..", "cabac", "..a..", "..c.."]}, {"at": [8, -7], "rows": [".a.", "aca", ".a."]},
        {"at": [-3, -8], "rows": ["b"]}, {"at": [3, -7], "rows": ["c"]}, {"at": [-6, -4], "rows": ["a"]}, {"at": [11, -3], "rows": ["b"]}]},
    ("coffee", "mug"): {"motion": "A19-coffee", "frame": 7, "colors": [[114, 114, 107], [47, 47, 45]], "restBody": False},
    ("detective", "hat"): {"kind": "gif", "frame": 22, "keep": [[20, 20, 19], [97, 56, 10]], "rows": [-1000, 8], "headAt": [12, 8]},
    ("detective", "magnifier"): {"kind": "gif", "frame": 22, "keep": [[62, 56, 125]], "headAt": [12, 8]},
    ("wand", "wand"): {"kind": "motion", "motion": "A25-spark", "frame": 24, "cols": [24, 31], "shift": [0, -1], "headAt": [12, 8]},
    ("skateboard", "board"): {"kind": "sprite", "sprite": 1, "frame": 18, "colorMap": [{"from": [217, 119, 87], "to": [215, 119, 87]}],
                              "keep": [[86, 27, 47], [239, 172, 84]], "origin": [0, 5]},
}
# the plushie layers as the spec's sources declare them (Sprint 7): the pattern of role letters at its place, and the picture patch each role takes its
# colour from (a `snap` role takes the pet's near-black when the patch is near-black); the colours themselves are recomputed from the pictures
V2_PLUSH_CUT = {
    ("wizard", "hat"): {
        "at": [-11, -8],
        "roles": {"b": {"rect": [237, 104, 244, 111]}, "n": {"rect": [158, 190, 163, 195]}, "s": {"rect": [302, 143, 304, 145]}},
        "rows": [
            "..bbb.................",
            "..bsbbbb..............",
            "..bbbbbbbbb...........",
            "..bbbbbbsbbbbb........",
            "..bbbbbbbbbbbsbbbbb...",
            "...nnnnnnnnnnnnnnnn...",
            "...nnnnnnnnnnnnnnnn...",
            "bbbbbbbbbbbbbbbbbbbbbb",
            ".bbbbsbbbbbbbbbsbbbbb.",
            "...bbbbbbbbbbbbbbbb..."
        ]},
    ("wizard", "wand"): {
        "at": [12, -3],
        "roles": {"g": {"rect": [403, 230, 408, 235]}, "w": {"rect": [314, 335, 316, 337]}},
        "rows": [
            "...g..",
            "..ggg.",
            ".ggggg",
            "..ggg.",
            "..g.g.",
            "..w...",
            ".w....",
            ".w....",
            "w.....",
            "w....."
        ]},
    ("cowboy", "hat"): {
        "at": [-11, -8],
        "roles": {"b": {"rect": [195, 136, 202, 143]}, "g": {"rect": [142, 193, 147, 198]}},
        "rows": [
            "......bbbb..bbbb......",
            ".....bbbbbbbbbbbb.....",
            "....bbbbbbbbbbbbbb....",
            "....bbbbbbbbbbbbbb....",
            "....bbbbbbbbbbbbbb....",
            "....gggggggggggggg....",
            "....gggggggggggggg....",
            "...bbbbbbbbbbbbbbbbbb.",
            ".bbbbbbbbbbbbbbbbbbbbb",
            "bbbbbbbbbbbbbbbbbbbbb."
        ]},
    ("scientist", "goggles"): {
        "at": [-9, -2],
        "roles": {"k": {"rect": [185, 195, 188, 198], "snap": "pet-eye"}, "l": {"rect": [226, 157, 233, 164]}},
        "rows": [
            "..kkkkkkkkkkkkkk..",
            "kkkkllllllllllkkkk",
            "kkkkllllllllllkkkk",
            "..kkkkkk..kkkkkk.."
        ]},
    ("scientist", "coat"): {
        "at": [-8, 5],
        "roles": {"c": {"rect": [157, 285, 164, 292]}, "p": {"rect": [186, 238, 190, 242]}},
        "rows": [
            "ccccpp....ppcccc",
            "ccccpp....ppcccc",
            "cccccp....pccccc",
            "cccccc....cccccc",
            "cccccc....cccccc",
            "cccccc....cccccc",
            "cccccc....cccccc"
        ]},
    ("scientist", "flask"): {
        "at": [11, 0],
        "roles": {"e": {"rect": [388, 190, 391, 193]}, "q": {"rect": [428, 247, 433, 252]}},
        "rows": [
            "..ee..",
            "..ee..",
            "..ee..",
            ".eeee.",
            ".eeee.",
            "eeeeee",
            "qqqqqq",
            "qqqqqq",
            "qqqqqq",
            ".qqqq."
        ]},
}
V2_CUT_SOURCE_PATH = {"sprite": V2_CHUNK, "gif": V2_GIF, "sparkle": V2_STICKERS["D7"][:-4], "border": V2_STICKERS["D7"][:-4]}
V2_STICKER_CUTS = ("sparkle", "border")         # cut kinds whose source is a sticker picture, named without its .png (the catalog's `picture` + `ext` convention)
V2_PASTEL = {"min": 170, "spread": 24, "apart": 40, "highlights": 3}      # the rule the sparkles' colours are sampled by (see v2_sticker_palette)
# the rule the border's pastels are sampled by (see v2_sticker_border) and the shape of the outline round the rest silhouette
V2_BORDER = {"sectors": 24, "depth": 9.0, "band": 19, "cells": 1, "centre": (0.0, 8.0)}
V2_BORDER_REACH = [(dx, dy) for dx in range(-V2_BORDER["cells"], V2_BORDER["cells"] + 1) for dy in range(-V2_BORDER["cells"], V2_BORDER["cells"] + 1)
                   if not (abs(dx) == V2_BORDER["cells"] and abs(dy) == V2_BORDER["cells"])]
# K1: the body box (the rest body, 24 x 16 cells from the torso top to the feet, plus one unit on every side: the squash and stretch of the
# official motions is at most 2 cells, a raised arm in D11 reaches 5) relative to the head anchor: x0, x1, y0, y1
V2_BODY_BOX = (-14, 13, -2, 17)
V2_ANCHOR_OF = {"head": "head", "torso": "head", "body": "head", "arm-right": "arm-right", "feet": "feet"}
V2_OWN = {(215, 119, 87), (20, 20, 19), (190, 104, 77), (191, 105, 77)}
V2_LEG_CELLS = [(i, 23) for i in (4, 5, 8, 9, 14, 15, 18, 19)]
V2_GIF_GRID = {"x0": 318, "y0": 281, "cellNum": 173, "cellDen": 8}
V2_REDRAW_CHANGES = {"eyes:chevrons", "eyes:spirals", "arm-right:lifted", "arm-right:raised", "eyes:look-left", "eyes:look-right", "eyes:wink",
                    "eyes:closed", "legs:left-up", "eyes:carets"}
# D19's `^ ^`: the eye cells of A3 JumpingHappy's frame 7 relative to its head anchor (the official pixels), mirrored about x = 0
V2_CARET_SOURCE = ("A3-jumping-happy", 7)
V2_CARET = {(-6, 3), (-5, 2), (-4, 2), (-3, 3), (2, 3), (3, 2), (4, 2), (5, 3)}


def lot_load(path):
    """The official file as (frame count, rects) with exact coordinates (x100 integers); rect = (layer index, group index, layer name,
    x0, y0, x1, y1, rgb, [visible per frame]). Refuses what this check does not model."""
    from fractions import Fraction
    text = open(path, "rb").read().decode("utf-8")
    head = text.index('"]=') + 3
    j = json.loads(text[head:text.rindex(";")], parse_float=Fraction)
    n = j["op"]
    if j["fr"] != FPS or j["ip"] != 0 or j["w"] != SRC_W or j["h"] != SRC_H:
        raise ValueError("%s: composition is not 12 fps 2750 x 1850" % os.path.basename(path))
    rects = []
    for li, layer in enumerate(j["layers"]):
        for gi, g in enumerate(layer["shapes"]):
            fill = next(i for i in g["it"] if i["ty"] == "fl")
            rgb = tuple(int(round(float(c * 255))) for c in fill["c"]["k"][:3])
            keys = [(k["t"], k["s"][0]) for k in fill["o"]["k"]]
            vis = []
            for f in range(n):
                cur = [v for t, v in keys if t <= f]
                vis.append(cur[-1] == 100)
            for sh in (i for i in g["it"] if i["ty"] == "sh"):
                xs = [int(p[0] * 100) for p in sh["ks"]["k"]["v"]]
                ys = [int(p[1] * 100) for p in sh["ks"]["k"]["v"]]
                if len(set(xs)) != 2 or len(set(ys)) != 2:
                    raise ValueError("%s: shape is not an axis-aligned rectangle" % os.path.basename(path))
                rects.append((li, gi, layer["nm"], min(xs), min(ys), max(xs), max(ys), rgb, vis))
    return n, rects


def lot_cells(rects, f, origin, cmap, omit=()):
    """{(i, j): (r, g, b, 255)} for source frame f: the colour of the topmost visible rectangle that contains the cell's centre,
    for every cell whose centre lies inside the 2750 x 1850 canvas (cell (i, j) starts at origin + 50 (i, j) source px)."""
    claimed = {}
    ox, oy = origin
    for li, gi, layer, x0, y0, x1, y1, rgb, vis in sorted(rects, key=lambda r: (r[0], r[1])):
        if not vis[f]:
            continue
        if any(layer == o["layer"] and ("maxY" not in o or y1 <= o["maxY"] * 100) for o in omit):
            continue
        color = cmap.get(rgb, rgb) + (255,)
        i_lo, i_hi = (x0 // 100 - ox) // CELL - 1, (x1 // 100 - ox) // CELL + 1
        j_lo, j_hi = (y0 // 100 - oy) // CELL - 1, (y1 // 100 - oy) // CELL + 1
        for j in range(j_lo, j_hi + 1):
            cy = (oy + CELL * j + CELL // 2) * 100
            if not (y0 <= cy < y1 and 0 <= cy < SRC_H * 100):
                continue
            for i in range(i_lo, i_hi + 1):
                cx = (ox + CELL * i + CELL // 2) * 100
                if x0 <= cx < x1 and 0 <= cx < SRC_W * 100 and (i, j) not in claimed:
                    claimed[(i, j)] = color
    return claimed


def png_cells(entry_png, left, up):
    """{(i, j): (r, g, b, a)} of a PNG's non-transparent pixels in canvas cell coordinates (pixel (x, y) is cell (x - left, y - up))."""
    w, h, rows = entry_png
    out = {}
    for y in range(h):
        row = rows[y]
        for x in range(w):
            if row[x * 4 + 3]:
                out[(x - left, y - up)] = tuple(row[x * 4:x * 4 + 4])
    return out


def face_block_tops(cells, mine):
    """All (i, j) top-left cells of a 16 x 6 block of `mine` colours with at least two eye cells in its rows 1..4 and none in rows 0 and 5."""
    if not cells:
        return []
    i0, i1 = min(p[0] for p in cells), max(p[0] for p in cells)
    j0, j1 = min(p[1] for p in cells), max(p[1] for p in cells)
    w, h = i1 - i0 + 2, j1 - j0 + 2
    pre_m = [[0] * w for _ in range(h)]
    pre_e = [[0] * w for _ in range(h)]
    for j in range(h - 1):
        for i in range(w - 1):
            c = cells.get((i + i0, j + j0))
            m = 1 if c is not None and c[:3] in mine else 0
            e = 1 if c is not None and c[:3] == PET_EYE else 0
            pre_m[j + 1][i + 1] = m + pre_m[j][i + 1] + pre_m[j + 1][i] - pre_m[j][i]
            pre_e[j + 1][i + 1] = e + pre_e[j][i + 1] + pre_e[j + 1][i] - pre_e[j][i]

    def box(pre, a, b, c, d):          # columns a..b-1, rows c..d-1 in local coordinates
        return pre[d][b] - pre[c][b] - pre[d][a] + pre[c][a]

    out = []
    for j in range(h - FACE_H):
        for i in range(w - FACE_W):
            if box(pre_m, i, i + FACE_W, j, j + FACE_H) != FACE_W * FACE_H:
                continue
            inner = box(pre_e, i, i + FACE_W, j + 1, j + 5)
            edge = box(pre_e, i, i + FACE_W, j, j + 1) + box(pre_e, i, i + FACE_W, j + 5, j + 6)
            if inner >= 2 and edge == 0:
                out.append((i + i0, j + j0))
    return out


def face_fallback(cells, mine):
    """Eye cells in 4-connected groups; the groups that touch a non-eye Clawd cell give x (the cell edge in the middle of their bounding
    box) and the topmost Clawd cell in the columns x-1 and x that is reached without a gap from the topmost eye cell."""
    body = mine - {PET_EYE}
    eyes = {p for p, c in cells.items() if c[:3] == PET_EYE}
    left, kept = set(eyes), []
    while left:
        stack = [left.pop()]
        group = []
        while stack:
            p = stack.pop()
            group.append(p)
            for q in ((p[0] + 1, p[1]), (p[0] - 1, p[1]), (p[0], p[1] + 1), (p[0], p[1] - 1)):
                if q in left:
                    left.discard(q)
                    stack.append(q)
        touches = any((cells.get((p[0] + a, p[1] + b)) or (0, 0, 0, 0))[:3] in body for p in group for a, b in ((1, 0), (-1, 0), (0, 1), (0, -1)))
        if touches:
            kept += group
    if len(kept) < 2:
        return None
    x = (min(p[0] for p in kept) + max(p[0] for p in kept) + 1) // 2
    j = min(p[1] for p in kept)
    while (cells.get((x - 1, j - 1)) or (0, 0, 0, 0))[:3] in body or (cells.get((x, j - 1)) or (0, 0, 0, 0))[:3] in body:
        j -= 1
    return (x, j)


def head_of(cells, mine):
    """(anchor or None, exact) for a frame given as canvas-cell dict; see the port script's docstring for the rule this restates."""
    tops = face_block_tops(cells, mine)
    if tops:
        top = min(j for _, j in tops)
        row = [i for i, j in tops if j == top]
        if len(row) == 1:
            return (row[0] + FACE_W // 2, top), True
    return face_fallback(cells, mine), False


def v2_state():
    """Load the catalog, the vendored sources and the v1 rest pose once; shared by the v2 checks."""
    if "v2" in S:
        return S["v2"]
    art = S["art"]
    st = {"atlas": S["atlas"], "problems": []}
    st["motions"] = {m["id"]: m for m in S["atlas"].get("motions", []) if isinstance(m, dict) and "id" in m}
    st["looks"] = {l["id"]: l for l in S["atlas"].get("looks", []) if isinstance(l, dict) and "id" in l}
    w, h, rows = read_png(os.path.join(art, "frames", "idle_0.png"))
    rest = {}
    for y in range(h):
        for x in range(w):
            px = tuple(rows[y][x * 4:x * 4 + 4])
            if px[3]:
                for dy in (0, 1):
                    for dx in (0, 1):
                        rest[(2 * x + dx, 2 * y + dy)] = px
    st["rest"] = rest
    st["lot"] = {}
    st["src"] = {}
    st["png"] = {}
    st["cells"] = {}
    S["v2"] = st
    return st


def v2_selected(st):
    sel = S.get("only")
    ids = list(st["motions"])
    return [i for i in ids if (not sel or i in sel) and st["motions"][i].get("phase", 1) <= S.get("phase", 1)]


def v2_item(mid):
    """(source kind, board, declared uses) of a motion that is not an A item: the sticker and calm items of phase 2, the plushie item of phase 3."""
    return V2_PHASE2_ITEMS.get(mid) or V2_PHASE3_ITEMS.get(mid) or V2_PHASE4_ITEMS.get(mid) or (None, None, None)


def v2_kind(entry):
    """How a motion's pixels are sourced: lottie (a sources/lottie file), gif (the persona GIF), sprite (a sprite of the claude.dev chunk) or redrawn
    (drawn on the pet grid)."""
    src = entry.get("source", {})
    if src.get("kind") == "redrawn":
        return "redrawn"
    if src.get("kind") == "sprite":
        return "sprite"
    return "gif" if src.get("format") == "gif" else "lottie"


def v2_lottie(st, entry):
    src = entry["source"]
    key = src["path"]
    if key not in st["lot"]:
        st["lot"][key] = lot_load(os.path.join(S["art"], src["path"]))
    return st["lot"][key]


def v2_cmap(entry):
    return {tuple(e["from"]): tuple(e["to"]) for e in entry["source"].get("colorMap", [])}


def v2_expected_cells(st, mid):
    """Canvas-cell dicts of every source frame of a motion, computed once: rasterized from the Lottie file (mirrored when the entry says so),
    sampled from the persona GIF, or, for a redrawn item (it has no source pixels), the shipped frames themselves."""
    entry = st["motions"][mid]
    kind = v2_kind(entry)
    src = entry["source"]
    if kind == "redrawn":
        key = ("redrawn", mid)
        if key not in st["cells"]:
            st["cells"][key] = [v2_frame_cells(st, entry, k) for k in range(len(entry["frames"]))]
        return st["cells"][key]
    if kind == "sprite":
        key = ("sprite", mid)
        if key not in st["cells"]:
            st["cells"][key] = v2_ride_source_cells(st)
        return st["cells"][key]
    if kind == "gif":
        key = ("gif", mid, json.dumps(src.get("colorMap"), sort_keys=True))
        if key not in st["cells"]:
            cm = v2_cmap(entry)
            st["cells"][key] = [{p: cm.get(c, c) + (255,) for p, c in cells.items()} for cells, _ in v2_gif(st)[0]]
        return st["cells"][key]
    key = (src["path"], tuple(src["origin"]), json.dumps(src.get("colorMap"), sort_keys=True), json.dumps(src.get("omit")), src.get("mirror"))
    if key not in st["cells"]:
        n, rects = v2_lottie(st, entry)
        cm = v2_cmap(entry)
        frames = []
        for f in range(n):
            cells = lot_cells(rects, f, tuple(src["origin"]), cm, src.get("omit", ()))
            if src.get("mirror") == "horizontal":
                cells = {(CANVAS_CELLS - 1 - i, j): c for (i, j), c in cells.items()}
            frames.append(cells)
        st["cells"][key] = frames
    return st["cells"][key]


def v2_png(st, rel):
    if rel not in st["png"]:
        st["png"][rel] = read_png(os.path.join(S["art"], rel))
    return st["png"][rel]


def v2_stage_cells(entry):
    s = entry["stage"]
    return (int(round(s["left"] * 2)), int(round(s["right"] * 2)), int(round(s["up"] * 2)), int(round(s["down"] * 2)))


def v2_shade(st, entry):
    kind = v2_kind(entry)
    if kind == "gif":
        return {(191, 105, 77)}
    if kind == "sprite":
        return {V2_SPRITE_SHADE}
    if kind == "redrawn":
        return set()
    n, rects = v2_lottie(st, entry)
    cm = v2_cmap(entry)
    return {cm.get(r[7], r[7]) for r in rects if r[2] == "dark_orange"}


def v2_mine(st, entry):
    return {V2_PET_BODY, PET_EYE} | v2_shade(st, entry)


def v2_frame_cells(st, entry, k):
    """The shipped frame k as a canvas-cell dict, decoded from its PNG."""
    left, right, up, down = v2_stage_cells(entry)
    return png_cells(v2_png(st, entry["frames"][k]), left, up)



# ---- independent decoders for the phase 2 sources: the persona GIF and the claude.dev sprite chunk -----------------------------------
V2_GIF_MAP = {(217, 119, 87): (215, 119, 87), (0, 0, 0): (20, 20, 19)}
V2_POOL_MAP = {(216, 118, 86): (215, 119, 87), (0, 0, 0): (20, 20, 19)}
V2_SKATE_MAP = {(217, 119, 87): (215, 119, 87)}
V2_RING = [(249, 248, 244), (193, 217, 239), (105, 154, 203), (71, 108, 145)]
V2_BOARD = [(86, 27, 47), (239, 172, 84)]
V2_SPRITES = {6: (39, 31, 44), 1: (28, 29, 73)}     # sprite index -> (w, h, frames) in the chunk


def lzw2(chunks, min_code, want):
    """GIF LZW: the colour indices of one image (code table rebuilt from scratch, codes of 3..12 bits, LSB first)."""
    clear = 1 << min_code
    end = clear + 1
    table = None
    size = min_code + 1
    out = bytearray()
    old = None
    acc = nbits = 0
    for byte in chunks:
        acc |= byte << nbits
        nbits += 8
        while nbits >= size:
            code = acc & ((1 << size) - 1)
            acc >>= size
            nbits -= size
            if code == clear:
                table = [bytes([k]) for k in range(clear)] + [b"", b""]
                size = min_code + 1
                old = None
                continue
            if code == end:
                return bytes(out)
            if table is None:
                raise ValueError("GIF data without a clear code")
            if old is None:
                piece = table[code]
            else:
                if code < len(table):
                    piece = table[code]
                elif code == len(table):
                    piece = old + old[:1]
                else:
                    raise ValueError("bad GIF code")
                if len(table) < 4096:
                    table.append(old + piece[:1])
                    if len(table) == (1 << size) and size < 12:
                        size += 1
            out += piece
            old = piece
            if len(out) >= want:
                return bytes(out)
    return bytes(out)


def gif2_samples(path, grid):
    """([(cells, impure)], delays in ms, palette): per frame the colour of the pixel at every cell centre of `grid` as {(i, j): (r, g, b)}
    (opaque pixels only, before any colour map) and how many of those cells have another pixel in the 3 x 3 block around the centre."""
    data = open(path, "rb").read()
    if data[:6] not in (b"GIF89a", b"GIF87a"):
        raise ValueError("%s is not a GIF" % path)
    W, H, flags = struct.unpack("<HHB", data[6:11])
    pos, palette, gct = 13, set(), []
    if flags & 0x80:
        n = 2 << (flags & 7)
        gct = [tuple(data[pos + 3 * k:pos + 3 * k + 3]) for k in range(n)]
        pos += 3 * n
        palette.update(gct)
    num, den = grid["cellNum"], grid["cellDen"]
    spots = []
    for j in range(-12, 37):
        py = grid["y0"] + ((2 * j + 1) * num) // (2 * den)
        for i in range(-12, 49):
            px = grid["x0"] + ((2 * i + 1) * num) // (2 * den)
            if 1 <= px < W - 1 and 1 <= py < H - 1:
                spots.append((i, j, px, py))
    canvas = [bytearray(4 * W) for _ in range(H)]
    results, delays = [], []
    gce, last = None, None
    saved = None
    while pos < len(data):
        block = data[pos]
        pos += 1
        if block == 0x3B:
            break
        if block == 0x21:
            label = data[pos]
            pos += 1
            if label == 0xF9:
                f2, delay, tidx = struct.unpack("<BHB", data[pos + 1:pos + 5])
                gce = ((f2 >> 2) & 7, tidx if f2 & 1 else None, delay)
            while data[pos]:
                pos += 1 + data[pos]
            pos += 1
            continue
        x0, y0, w, h, f3 = struct.unpack("<HHHHB", data[pos:pos + 9])
        pos += 9
        table = gct
        if f3 & 0x80:
            n = 2 << (f3 & 7)
            table = [tuple(data[pos + 3 * k:pos + 3 * k + 3]) for k in range(n)]
            pos += 3 * n
            palette.update(table)
        min_code = data[pos]
        pos += 1
        chunks = bytearray()
        while data[pos]:
            chunks += data[pos + 1:pos + 1 + data[pos]]
            pos += 1 + data[pos]
        pos += 1
        idx = lzw2(bytes(chunks), min_code, w * h)
        if last and last[0] == 2:
            for yy in range(last[2], last[2] + last[4]):
                canvas[yy][4 * last[1]:4 * (last[1] + last[3])] = bytes(4 * last[3])
        elif last and last[0] == 3 and saved is not None:
            canvas = [bytearray(r) for r in saved]
        disposal, transparent, delay = gce if gce else (0, None, 0)
        if disposal == 3:
            saved = [bytearray(r) for r in canvas]
        order = list(range(h))
        if f3 & 0x40:
            order = list(range(0, h, 8)) + list(range(4, h, 8)) + list(range(2, h, 4)) + list(range(1, h, 2))
        for k, yy in enumerate(order):
            row = canvas[y0 + yy]
            for xx in range(w):
                v = idx[k * w + xx]
                if v != transparent:
                    r, g, b = table[v]
                    o = 4 * (x0 + xx)
                    row[o:o + 4] = bytes((r, g, b, 255))
        cells, impure = {}, 0
        for (i, j, px, py) in spots:
            o = 4 * px
            row = canvas[py]
            if row[o + 3]:
                cells[(i, j)] = (row[o], row[o + 1], row[o + 2])
                centre = bytes(row[o:o + 4])
                if any(bytes(canvas[py + dy][4 * (px + dx):4 * (px + dx) + 4]) != centre for dy in (-1, 0, 1) for dx in (-1, 0, 1)):
                    impure += 1
        results.append((cells, impure))
        delays.append(delay * 10)
        last = (disposal, x0, y0, w, h)
        gce = None
    return results, delays, palette


def sprites2(path):
    """The chunk's sprites as {index: {w, h, palette, frames: [[palette index or None per cell]]}}, parsed as text (no JS is run)."""
    text = open(path, encoding="utf-8").read()
    found = {}
    pat = r'n\(\{w:(\d+),h:(\d+),fps:(\d+),palette:\[([^\]]*)\],base:"([.0-9]*)",deltas:\[(.*?)\]\}\)'
    for k, m in enumerate(re.finditer(pat, text, re.S)):
        w, h = int(m.group(1)), int(m.group(2))
        colours = [tuple(int(c[a:a + 2], 16) for a in (1, 3, 5)) for c in re.findall(r'"(#[0-9a-fA-F]{6})"', m.group(4))]
        cur = [None if ch == "." else int(ch) for ch in m.group(5)]
        if len(cur) != w * h:
            raise ValueError("sprite %d: base has %d cells, want %d" % (k, len(cur), w * h))
        frames = [list(cur)]
        for delta in re.findall(r'"([^"]*)"', m.group(6)):
            for tok in (delta.split(",") if delta else []):
                cur[int(tok[:-1], 36)] = None if tok[-1] == "." else int(tok[-1])
            frames.append(list(cur))
        found[k] = {"w": w, "h": h, "palette": colours, "frames": frames}
    return found


def v2_sprite_frame(st, index, frame, cmap):
    """{(x, y): (r, g, b)} of one sprite frame after the colour map."""
    if "sprites" not in st:
        st["sprites"] = sprites2(os.path.join(S["art"], V2_CHUNK))
    sp = st["sprites"][index]
    if (sp["w"], sp["h"], len(sp["frames"])) != V2_SPRITES[index]:
        raise ValueError("sprite %d of the chunk is %dx%d with %d frames, want %s" % (index, sp["w"], sp["h"], len(sp["frames"]), V2_SPRITES[index]))
    out = {}
    for y in range(sp["h"]):
        for x in range(sp["w"]):
            v = sp["frames"][frame][y * sp["w"] + x]
            if v is not None:
                c = sp["palette"][v]
                out[(x, y)] = cmap.get(c, c)
    return out


# ---- D14 ride: the skateboard's glide (amendment "the skateboard ride", R2-1 .. R4-3) -------------------------------------------------
# Sprite 1 frames 23-61 as one motion. The compositor subtracts the look's raise (6 cells) from every clip of the look, the rest placement of a sprite
# cell is y - 5, so a frame is stored at (x, y + 1) (R3-2) and its composed cell is (x, y - 5). The check recomputes the stored frames from the chunk
# alone, then tests the COMPOSED cells: the extent (R2-3), nothing but board cells below the baseline (R3), and the board of the first and last frame
# against the composed rest picture (R2-1).
V2_SPRITE_SHADE = (190, 104, 77)
V2_RIDE = "D14-ride"
V2_RIDE_SPRITE = 1
V2_RIDE_FRAMES = (23, 61)
V2_RIDE_REST_FRAME = 18
V2_RIDE_BOARD_EDIT = (23, 61)
V2_RIDE_SEGMENTS = [("start", 23, 30), ("cruiseA", 31, 38), ("trick", 39, 44), ("cruiseB", 45, 55), ("push", 56, 58), ("stop", 59, 61)]
V2_RIDE_STAGE = {"left": 5.4, "right": 6.5, "up": 6.5}          # units: the stage of the existing motions (spec 3.2: Blooming, Bubble, Confetti and Heart)
V2_RIDE_EXTENT = {"left": 0.5, "right": 0.5, "up": 2.5}         # units, composed: 0.5 beyond the canvas on the leading side (either side over two legs), 2.5 up


def v2_ride_raise():
    return V2_LOOK_SPEC["skateboard"]["raise"]


def v2_ride_store():
    """R3-2: where a sprite cell is stored, relative to its sprite position."""
    return (0, v2_ride_raise() - 5)


def v2_ride_source_cells(st):
    """The stored cells of every sprite frame of the ride, as a list indexed by sprite frame number (frames outside the ride are empty): the chunk's
    pixels after the colour map, moved by the storage offset; the frames of V2_RIDE_BOARD_EDIT have their board cells replaced by frame 18's (R2-1)."""
    ox, oy = v2_ride_store()
    board = set(V2_BOARD)
    rest_board = {q: c for q, c in v2_sprite_frame(st, V2_RIDE_SPRITE, V2_RIDE_REST_FRAME, V2_SKATE_MAP).items() if c in board}
    out = []
    for f in range(V2_SPRITES[V2_RIDE_SPRITE][2]):
        if not V2_RIDE_FRAMES[0] <= f <= V2_RIDE_FRAMES[1]:
            out.append({})
            continue
        cells = v2_sprite_frame(st, V2_RIDE_SPRITE, f, V2_SKATE_MAP)
        if f in V2_RIDE_BOARD_EDIT:
            cells = {q: c for q, c in cells.items() if c not in board}
            cells.update(rest_board)
        out.append({(x + ox, y + oy): c + (255,) for (x, y), c in cells.items()})
    return out


def v2_ride_composed(st, e, k):
    """Frame k of the ride as the compositor lays it on the canvas: the stored cells lifted by the look's raise."""
    lift = v2_ride_raise()
    return {(i, j - lift): c for (i, j), c in v2_frame_cells(st, e, k).items()}


def v2_ride():
    st = v2_state()
    e = st["motions"].get(V2_RIDE)
    if e is None:
        return ["no motion %s" % V2_RIDE], ""
    p = []
    src = e.get("source", {})
    edit = {"frames": list(V2_RIDE_BOARD_EDIT), "from": V2_RIDE_REST_FRAME, "keep": [list(c) for c in V2_BOARD]}
    if (src.get("sprite"), src.get("path"), src.get("store"), src.get("boardEdit")) != (V2_RIDE_SPRITE, V2_CHUNK, list(v2_ride_store()), edit):
        p.append("%s: source sprite/path/store/boardEdit %s, want %s" % (V2_RIDE, (src.get("sprite"), src.get("path"), src.get("store"), src.get("boardEdit")),
                                                                   (V2_RIDE_SPRITE, V2_CHUNK, list(v2_ride_store()), edit)))
    first, last = V2_RIDE_FRAMES
    if e.get("srcFrames") != list(range(first, last + 1)):
        p.append("%s: srcFrames is not %d..%d" % (V2_RIDE, first, last))
    want_segments = [{"name": n, "srcFrames": [a, b], "frames": [a - first, b - first]} for n, a, b in V2_RIDE_SEGMENTS]
    if e.get("segments") != want_segments:
        p.append("%s: segments %s, want %s" % (V2_RIDE, e.get("segments"), want_segments))
    if e.get("uses") != ["ride"]:
        p.append("%s: uses %s, want [ride] (a use that no idle or reaction pool picks)" % (V2_RIDE, e.get("uses")))
    stored = v2_stage_cells(e)
    if stored != (0, 1, 0, 6) or e.get("stage") != {"left": 0, "right": 0.5, "up": 0, "down": 3}:
        p.append("%s: stage %s, want right 0.5 and down 3 units (R4-1: down is storage only, 24 + up + down cells tall)" % (V2_RIDE, e.get("stage")))
    look = st["looks"].get("skateboard", {})
    if look.get("signature") != [V2_RIDE] or look.get("layerOnSignature") is not False:
        p.append("look skateboard: signature %s, layerOnSignature %r, want [%s] and false (R2-4: the frames carry their own board)" % (
            look.get("signature"), look.get("layerOnSignature"), V2_RIDE))
    # the composed cells
    rest = v2_compose(st, v2_look_layers(st, "skateboard"), v2_ride_raise())
    rest_board = {q: c for q, c in rest.items() if c[:3] in V2_BOARD}
    minx = miny = maxx = maxy = None
    below = 0
    for k in range(len(e["frames"])):
        for (i, j), c in v2_ride_composed(st, e, k).items():
            minx = i if minx is None else min(minx, i)
            maxx = i if maxx is None else max(maxx, i)
            miny = j if miny is None else min(miny, j)
            maxy = j if maxy is None else max(maxy, j)
            if j > V2_BASELINE_ROW and c[:3] not in V2_BOARD:
                below += 1
    p_extent = {"left": -minx, "right": maxx - (CANVAS_CELLS - 1), "up": -miny}
    for side, cells in p_extent.items():
        if cells / 2 > V2_RIDE_EXTENT[side] or max(cells, 0) / 2 > V2_RIDE_STAGE.get(side, 99):
            p.append("%s: composed frames reach %g units %s of the canvas, the design allows %g (the stage of the existing motions: %g)" % (
                V2_RIDE, cells / 2, side, V2_RIDE_EXTENT[side], V2_RIDE_STAGE.get(side, 99)))
    if maxy > V2_BASELINE_ROW:
        p.append("%s: composed frames reach row %d, the baseline row is %d (only board cells may lie below)" % (V2_RIDE, maxy, V2_BASELINE_ROW))
    if below:
        p.append("%s: %d composed cell(s) that are not board cells lie below the baseline" % (V2_RIDE, below))
    # R2-1: the first and the last frame carry exactly the rest picture's board (coordinates and RGBA of the visible board-coloured cells)
    for name, k in (("first", 0), ("last", len(e["frames"]) - 1)):
        board = {q: c for q, c in v2_ride_composed(st, e, k).items() if c[:3] in V2_BOARD}
        if board != rest_board:
            p.append("%s: the board cells of the %s frame differ from the composed rest picture's in %d cell(s) (R2-1)" % (
                V2_RIDE, name, len(set(board.items()) ^ set(rest_board.items()))))
    # R4-3: frame 32 is where a cruise without `start` begins; its board is the rest picture's cell for cell
    k32 = 32 - first
    board32 = {q: c for q, c in v2_ride_composed(st, e, k32).items() if c[:3] in V2_BOARD}
    if board32 != rest_board:
        p.append("%s: the board cells of sprite frame 32 differ from the composed rest picture's (R4-3: a cruise starts there)" % V2_RIDE)
    return p, ("%s: %d frames from sprite %d frames %d-%d stored at +%s, segments as designed; composed they reach %g units right, %g left (mirrored: %g left, %g right), %g up, "
               "nothing but board cells below the baseline; the first and last frame carry the rest picture's board (%d cells), as does frame 32" % (
                   V2_RIDE, len(e["frames"]), V2_RIDE_SPRITE, first, last, "%d,%d" % v2_ride_store(), p_extent["right"] / 2, p_extent["left"] / 2,
                   p_extent["right"] / 2, p_extent["left"] / 2, p_extent["up"] / 2, len(rest_board)))


# ---- bridges: the in-between pictures of the five seams (smooth round 2) ---------------------------------------------------------------
# A bridge is a short run of frames played just before (`lead`) or just after (`tail`) the frames of a motion or v1 pose (scripts/port-bridge-art.py). The shipped
# motions and poses are untouched, so P1, R5 and the rest keep meaning what they meant; these checks recompute everything about a bridge from its PNGs:
# its size, its colours, its head anchors, the changed cells of every step of the sequence it sits in (the plain look; the ride in the skateboard look's frame of
# reference, where the rest picture carries the board of the ride's own last frame), and that the looks the target is compatible with still fit it.
V2_BRIDGES = {            # id: (target kind, target id, side, frame count)
    "D14-ride-tail": ("motion", "D14-ride", "tail", 2),
    "dangle-lead": ("pose", "dangle", "lead", 1),
    "hop-lead": ("pose", "hop", "lead", 1),
    "C1-jump-lead": ("motion", "C1-jump", "lead", 1),
    "C2-celebrate-lead": ("motion", "C2-celebrate", "lead", 1),
    "C11-boop-lead": ("motion", "C11-boop", "lead", 1),
    "A34-arcade-lead": ("motion", "A34-arcade", "lead", 3),
    "A34-arcade-tail": ("motion", "A34-arcade", "tail", 3),
}
V2_BRIDGE_REDUCTION = 0.7        # the largest step of a bridge is at most this share of the seam without it
V2_BRIDGE_MS = (40, 100)
V2_BRIDGE_MINE = {V2_PET_BODY, PET_EYE, (190, 104, 77), (191, 105, 77)}


def v2_bridge_target_edge(st, b):
    """(target frame at the seam as cells, rest picture the seam joins) in canvas cells with the target's stage, or None."""
    kind, tid, side = b["target"]["kind"], b["target"]["id"], b["side"]
    if kind == "pose":
        pose = S["atlas"]["poses"][tid]
        edge = v1_cells(S["art"], pose["frames"][0 if side == "lead" else -1])
        rest = dict(st["rest"])
        return edge, rest
    e = st["motions"][tid]
    k = 0 if side == "lead" else len(e["frames"]) - 1
    edge = v2_frame_cells(st, e, k)
    rest = dict(st["rest"])
    if tid == V2_RIDE:
        rest.update({q: c for q, c in edge.items() if c[:3] in V2_BOARD})
    return edge, rest


def v2_bridge_cells(st, b, k, stage):
    left, right, up, down = stage
    return png_cells(v2_png(st, b["frames"][k]), left, up)


def v2_bridge_steps(side, frames, edge, rest):
    flat = lambda cells: {q: c[:3] for q, c in cells.items()}
    seq = [flat(rest)] + [flat(f) for f in frames] + [flat(edge)] if side == "lead" else [flat(edge)] + [flat(f) for f in frames] + [flat(rest)]
    diff = lambda a, c: sum(1 for q in set(a) | set(c) if a.get(q) != c.get(q))
    return [diff(seq[i], seq[i + 1]) for i in range(len(seq) - 1)], diff(seq[0], seq[-1])


def v2_bridge_looks(st, b, cells, heads, target_entry):
    """The looks the target takes still fit the bridge: a motion's compatible looks through K1's own test (the ride's skateboard look through its signature
    rule), a pose's looks through the layer rules of L2 and R3 (the holding arm is present, no front layer lands on a foreign pixel, nothing below the baseline)."""
    p = []
    bid = b["id"]
    exact = all(h is not None for h in heads)
    if b["target"]["kind"] == "motion":
        pseudo = "bridge:" + bid
        e2 = {"frames": b["frames"], "stage": b["stage"], "head": [None if h is None else list(h) for h in heads], "phase": target_entry.get("phase", 1),
              "redraw": target_entry.get("redraw", {})}
        hs = [(h, True) for h in heads]
        for lid in target_entry.get("compatibleLooks", []):
            l = st["looks"].get(lid)
            if l is None or lid == "plain" or l.get("phase", 1) > S.get("phase", 1):
                continue
            l2 = dict(l, signature=[pseudo if x == b["target"]["id"] else x for x in l.get("signature", [])])
            if not v2_look_compat(st, pseudo, e2, l2, hs, exact):
                p.append("%s: the look %s, which %s takes, does not fit the bridge (K1 on the bridge frames)" % (bid, lid, b["target"]["id"]))
        return p
    for lid, l in st["looks"].items():
        if lid == "plain" or l.get("phase", 1) > S.get("phase", 1):
            continue
        lift = l.get("raiseCells", 0)
        for lay in v2_look_layers(st, lid):
            for k, C in enumerate(cells):
                h = heads[k]
                if h is None:
                    p.append("%s frame %d has no head anchor, a worn layer cannot be placed" % (bid, k))
                    continue
                hx, hy = h
                if lay["attach"] == "arm-right" and sum(1 for x in range(hx + 8, hx + 12) for y in range(hy + 4, hy + 8) if v2_own(C.get((x, y)))) < 4:
                    p.append("%s frame %d: the holding arm of look %s is missing" % (bid, k, lid))
                if lay["attach"] != "feet" and lay["z"] == "front" and any(C.get((hx + dx, hy + dy)) is not None and not v2_own(C.get((hx + dx, hy + dy)))
                                                                           for (dx, dy) in lay["cells"]):
                    p.append("%s frame %d: a front layer of look %s lands on a foreign pixel" % (bid, k, lid))
                if (lid, lay["name"]) not in V2_BELOW_BASELINE_OK:
                    rows = [CANVAS_CELLS + dy if lay["attach"] == "feet" else hy - lift + dy for (dx, dy) in lay["cells"]]
                    if rows and max(rows) > V2_BASELINE_ROW:
                        p.append("%s frame %d: a layer of look %s lies below the feet baseline" % (bid, k, lid))
    return p


def v2_bridges():
    st = v2_state()
    art = S["art"]
    bridges = S["atlas"].get("bridges")
    if not isinstance(bridges, list):
        return ["the catalog has no bridges list"], ""
    p = []
    seen = {}
    for b in bridges:
        if isinstance(b, dict) and isinstance(b.get("id"), str):
            if b["id"] in seen:
                p.append("bridge %s is listed twice" % b["id"])
            seen[b["id"]] = b
    for bid in V2_BRIDGES:
        if bid not in seen:
            p.append("bridge %s is missing" % bid)
    for bid in seen:
        if bid not in V2_BRIDGES:
            p.append("bridge %s is not one of the seams this round bridges" % bid)
    frames_n, worst = 0, []
    for bid, (kind, tid, side, count) in V2_BRIDGES.items():
        b = seen.get(bid)
        if b is None:
            continue
        need = ["id", "target", "side", "frames", "ms", "stage", "head", "steps", "direct", "derivation"]
        absent = [k for k in need if k not in b]
        if absent:
            p.append("%s: no %s" % (bid, ", ".join(absent)))
            continue
        if b["target"] != {"kind": kind, "id": tid} or b["side"] != side:
            p.append("%s: target %s side %r, want %s %s" % (bid, b["target"], b["side"], {"kind": kind, "id": tid}, side))
            continue
        if not isinstance(b["derivation"], str) or not b["derivation"]:
            p.append("%s: no derivation text" % bid)
        target = S["atlas"]["poses"].get(tid) if kind == "pose" else st["motions"].get(tid)
        if target is None:
            p.append("%s: the target %s %s does not exist" % (bid, kind, tid))
            continue
        n = len(b["frames"]) if isinstance(b["frames"], list) else -1
        if n != count or not isinstance(b["ms"], list) or len(b["ms"]) != n or not isinstance(b["head"], list) or len(b["head"]) != n:
            p.append("%s: %d frames, %d ms, %d heads, want %d of each" % (bid, n, len(b["ms"]) if isinstance(b["ms"], list) else -1,
                                                                         len(b["head"]) if isinstance(b["head"], list) else -1, count))
            continue
        if any(not isinstance(m, int) or isinstance(m, bool) or not V2_BRIDGE_MS[0] <= m <= V2_BRIDGE_MS[1] for m in b["ms"]):
            p.append("%s: ms %s, want whole milliseconds from %d to %d" % (bid, b["ms"], V2_BRIDGE_MS[0], V2_BRIDGE_MS[1]))
        want_stage = target["stage"] if kind == "motion" else {"left": 0, "right": 0, "up": 0, "down": 0}
        if b["stage"] != want_stage:
            p.append("%s: stage %s, want the target's %s (the frames are laid on the target's stage)" % (bid, b["stage"], want_stage))
            continue
        stage = v2_stage_cells(b)
        want_w, want_h = CANVAS_CELLS + stage[0] + stage[1], CANVAS_CELLS + stage[2] + stage[3]
        cells, bad = [], False
        for k, rel in enumerate(b["frames"]):
            if not os.path.isfile(os.path.join(art, rel)):
                p.append("%s frame %d: %s is missing" % (bid, k, rel))
                bad = True
                continue
            w, h, rows = v2_png(st, rel)
            if (w, h) != (want_w, want_h):
                p.append("%s frame %d is %dx%d px, want %dx%d" % (bid, k, w, h, want_w, want_h))
                bad = True
                continue
            if any(rows[y][x * 4 + 3] not in (0, 255) for y in range(h) for x in range(w)):
                p.append("%s frame %d has a translucent pixel (a bridge is crisp cells: no anti-aliasing)" % (bid, k))
                bad = True
            cells.append(v2_bridge_cells(st, b, k, stage))
        if bad:
            continue
        frames_n += n
        edge, rest = v2_bridge_target_edge(st, b)
        # no colour that the rest picture, Clawd or the target's own frames do not have
        allowed = {c[:3] for c in rest.values()} | {c[:3] for c in edge.values()} | V2_OWN
        if kind == "motion":
            allowed |= {c[:3] for k in range(len(target["frames"])) for c in v2_frame_cells(st, target, k).values()}
        extra = sorted({c[:3] for f in cells for c in f.values()} - allowed)
        if extra:
            p.append("%s: colours %s are neither the rest picture's nor the target frame's" % (bid, extra))
        # the heads, recomputed
        for k, f in enumerate(cells):
            h, _ = head_of(f, V2_BRIDGE_MINE)
            if b["head"][k] != (None if h is None else list(h)):
                p.append("%s frame %d: head %r in the catalog, %r from the pixels" % (bid, k, b["head"][k], h))
                break
        # nothing below the feet baseline (the ride's stored frames are RAISE lower; only board cells may lie below)
        lift = v2_ride_raise() if tid == V2_RIDE else 0
        for k, f in enumerate(cells):
            low = [q for q, c in f.items() if q[1] - lift > V2_BASELINE_ROW and c[:3] not in V2_BOARD]
            if low:
                p.append("%s frame %d: %d pixel(s) below the feet baseline" % (bid, k, len(low)))
                break
        # the steps of the sequence, recomputed
        steps, direct = v2_bridge_steps(side, cells, edge, rest)
        if b["steps"] != steps or b["direct"] != direct:
            p.append("%s: steps %s direct %s in the catalog, %s and %s from the PNGs" % (bid, b["steps"], b["direct"], steps, direct))
        if max(steps) >= direct or max(steps) > V2_BRIDGE_REDUCTION * direct:
            p.append("%s: the largest step is %d of the %d cells the seam changes at once (a bridge must bring it to at most %d%%)" % (
                bid, max(steps), direct, round(V2_BRIDGE_REDUCTION * 100)))
        worst.append("%s %d -> %d" % (bid, direct, max(steps)))
        # the looks
        heads = [None if h is None else tuple(h) for h in b["head"]]
        p += v2_bridge_looks(st, b, cells, heads, target if kind == "motion" else {})
    return p, "%d bridges, %d frames, every one recomputed from its PNG: size on the target's stage, crisp cells, only the seam's own colours, the head anchors, the changed cells of every step (largest step, seam without bridge -> with: %s) and the looks the targets take" % (
        len(seen), frames_n, "; ".join(worst))


def v2_gif(st):
    """The persona GIF sampled once: (frames [(cells, impure)], delays, palette)."""
    if "gif" not in st:
        st["gif"] = gif2_samples(os.path.join(S["art"], V2_GIF), V2_GIF_GRID)
    return st["gif"]


def v2_gif_cells(st, frame):
    """GIF frame k as canvas cells {(i, j): (r, g, b, 255)} after the declared colour map."""
    cells = v2_gif(st)[0][frame][0]
    return {p: V2_GIF_MAP.get(c, c) + (255,) for p, c in cells.items()}


def v2_largest_component(cells):
    left, best = set(cells), set()
    for start in sorted(cells):
        if start not in left:
            continue
        group, todo = set(), [start]
        left.discard(start)
        while todo:
            p = todo.pop()
            group.add(p)
            for q in ((p[0] + a, p[1] + b) for a in (-1, 0, 1) for b in (-1, 0, 1)):
                if q in left:
                    left.discard(q)
                    todo.append(q)
        if len(group) > len(best):
            best = group
    return best


def v2_sticker_palette(st):
    """The shiny colours, recomputed from the sticker alone. A pastel pixel is opaque, has every channel >= 170 and a spread (max - min) >= 24;
    pastel pixels are counted per 16-level colour bucket. Body = the most frequent bucket, shade = the most frequent bucket whose luma
    (299 r + 587 g + 114 b of the bucket centre) is lower than the body's, highlights = the next three by frequency that are at least 40 apart
    (sum of channel differences of the centres) from the body, the shade and each other. A bucket's colour is its most frequent exact colour
    (the smallest on a tie), its source pixel the first pixel of that colour in raster order. Returns {"body", "shade", "highlights"}, each
    {"rgb": [r, g, b], "pixel": [x, y]}."""
    if "palette" in st["cells"]:
        return st["cells"]["palette"]
    w, h, rows = v2_png(st, V2_STICKERS["D7"])
    cfg = V2_PASTEL
    count, exact, first = {}, {}, {}
    for y in range(h):
        row = rows[y]
        for x in range(w):
            r, g, b, a = row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]
            if a == 255 and min(r, g, b) >= cfg["min"] and max(r, g, b) - min(r, g, b) >= cfg["spread"]:
                q = (r >> 4, g >> 4, b >> 4)
                count[q] = count.get(q, 0) + 1
                e = exact.setdefault(q, {})
                e[(r, g, b)] = e.get((r, g, b), 0) + 1
                first.setdefault((r, g, b), (x, y))
    order = sorted(count, key=lambda q: (-count[q], q))
    if len(order) < 2 + cfg["highlights"]:
        raise ValueError("the shiny sticker has only %d pastel colour buckets" % len(order))
    centre = lambda q: tuple(16 * v + 8 for v in q)
    luma = lambda c: 299 * c[0] + 587 * c[1] + 114 * c[2]

    def pick(q):
        top = max(exact[q].values())
        rgb = min(c for c, n in exact[q].items() if n == top)
        return {"rgb": list(rgb), "pixel": list(first[rgb])}

    body = order[0]
    shade = next((q for q in order if luma(centre(q)) < luma(centre(body))), None)
    if shade is None:
        raise ValueError("no pastel bucket of the shiny sticker is darker than its dominant one")
    chosen, highlights = [body, shade], []
    for q in order:
        if q not in chosen and all(sum(abs(u - v) for u, v in zip(centre(q), centre(o))) >= cfg["apart"] for o in chosen):
            chosen.append(q)
            highlights.append(q)
            if len(highlights) == cfg["highlights"]:
                break
    if len(highlights) < cfg["highlights"]:
        raise ValueError("fewer than %d distinct highlight pastels in the shiny sticker" % cfg["highlights"])
    st["cells"]["palette"] = {"body": pick(body), "shade": pick(shade), "highlights": [pick(q) for q in highlights]}
    return st["cells"]["palette"]


def v2_sticker(st):
    """The shiny sticker as (w, h, rows, outside): `outside[y][x]` is True for a pixel that is not fully opaque and reaches the picture's edge through
    such pixels (4-neighbours), computed once."""
    if "sticker" not in st["cells"]:
        w, h, rows = v2_png(st, V2_STICKERS["D7"])
        out = [[False] * w for _ in range(h)]
        todo = [(x, y) for x in range(w) for y in (0, h - 1)] + [(x, y) for y in range(h) for x in (0, w - 1)]
        while todo:
            x, y = todo.pop()
            if 0 <= x < w and 0 <= y < h and not out[y][x] and rows[y][4 * x + 3] != 255:
                out[y][x] = True
                todo += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
        st["cells"]["sticker"] = (w, h, rows, out)
    return st["cells"]["sticker"]


def v2_in_band(st, x, y):
    """True when a sticker pixel lies within the border band: an outside pixel is within `band` pixels of it (a square window)."""
    w, h, _, out = v2_sticker(st)
    r = V2_BORDER["band"]
    return any(out[yy][xx] for yy in range(max(0, y - r), min(h, y + r + 1)) for xx in range(max(0, x - r), min(w, x + r + 1)))


def v2_sticker_border(st):
    """The border pastels of the sticker in running order, recomputed from the picture alone: from the centroid of the sticker's body (the pixels that
    are not outside), a ray at the centre angle of each of `sectors` equal sectors (clockwise from up) is walked in half-pixel steps, the pixel of a step
    being (round(cx + r sin a), round(cy - r cos a)), until it reaches the outside; the sector's colour is the pixel `depth` pixels back along the ray
    and that pixel is its source pixel. Returns [{"sector", "angle", "rgb", "pixel"}]."""
    if "border" in st["cells"]:
        return st["cells"]["border"]
    w, h, rows, out = v2_sticker(st)
    pts = [(x, y) for y in range(h) for x in range(w) if not out[y][x]]
    cx, cy = sum(x for x, _ in pts) / len(pts), sum(y for _, y in pts) / len(pts)
    k_n = V2_BORDER["sectors"]
    res = []
    for k in range(k_n):
        angle = 360.0 * (k + 0.5) / k_n
        sa, ca = math.sin(math.radians(angle)), -math.cos(math.radians(angle))
        r = 0.0
        while True:
            x, y = int(round(cx + r * sa)), int(round(cy + r * ca))
            if not (0 <= x < w and 0 <= y < h) or out[y][x]:
                break
            r += 0.5
        r -= V2_BORDER["depth"]
        x, y = int(round(cx + r * sa)), int(round(cy + r * ca))
        px = rows[y][4 * x:4 * x + 4]
        if px[3] != 255 or min(px[:3]) < V2_PASTEL["min"] or max(px[:3]) - min(px[:3]) < V2_PASTEL["spread"]:
            raise ValueError("the border sample of sector %d at (%d, %d) is %s, not an opaque pastel" % (k, x, y, tuple(px)))
        res.append({"sector": k, "angle": angle, "rgb": list(px[:3]), "pixel": [x, y]})
    st["cells"]["border"] = res
    return res


def v2_rest_silhouette(st):
    """The cells of the v1 rest pose relative to its head anchor (12, 8)."""
    return {(i - 12, j - 8) for (i, j) in st["rest"]}


def v2_border_ring(st):
    """The cells of the outline behind the rest silhouette, head-relative: outside the silhouette, within the rounded reach of one of its cells."""
    sil = v2_rest_silhouette(st)
    return {(x + dx, y + dy) for (x, y) in sil for (dx, dy) in V2_BORDER_REACH} - sil


def v2_border_sector(dx, dy):
    """The sector a cell's centre lies in: the angle clockwise from up about the middle of the rest body (head-relative cell edge x 0, y 8)."""
    cx, cy = V2_BORDER["centre"]
    angle = math.degrees(math.atan2(dx + 0.5 - cx, -(dy + 0.5 - cy))) % 360.0
    return min(int(angle * V2_BORDER["sectors"] / 360.0), V2_BORDER["sectors"] - 1)


def v2_derive_cut(st, look, cut):
    """The layer {(dx, dy): rgba} a catalog cut declares, derived from the sources."""
    kind = cut.get("kind")
    if kind == "sprite":
        idx = cut["sprite"]
        cmap = V2_POOL_MAP if idx == 6 else V2_SKATE_MAP
        if [tuple(e["from"]) for e in cut["colorMap"]] != list(cmap) or [tuple(e["to"]) for e in cut["colorMap"]] != list(cmap.values()):
            raise ValueError("the colour map of the cut is not the sprite's declared one")
        cells = {p: c + (255,) for p, c in v2_sprite_frame(st, idx, cut["frame"], cmap).items()}
        keep = {tuple(c) for c in cut["keep"]}
        univ = cut.get("universeRows")
        sel = {p for p, c in cells.items() if c[:3] in keep and (univ is None or univ[0] <= p[1] <= univ[1])}
        if cut.get("largestComponent"):
            sel = v2_largest_component(sel)
        if cut.get("rows"):
            sel = {p for p in sel if cut["rows"][0] <= p[1] <= cut["rows"][1]}
        layer = {p: cells[p] for p in sel}
        if cut.get("fill"):
            hx, hy = cut["headAt"]
            covered = {(i + hx - 12, j + hy - 8) for (i, j) in st["rest"]}
            for p, c in cells.items():
                if c[:3] == tuple(cut["fill"]["of"]) and p not in covered:
                    layer[p] = tuple(cut["fill"]["color"]) + (255,)
        if "origin" in cut:
            return {(x - cut["origin"][0], y - cut["origin"][1] - CANVAS_CELLS): c for (x, y), c in layer.items()}
        return {(x - cut["headAt"][0], y - cut["headAt"][1]): c for (x, y), c in layer.items()}
    if kind == "gif":
        keep = {tuple(c) for c in cut["keep"]}
        lo, hi = cut.get("rows", [-1000, 1000])
        cells = v2_gif_cells(st, cut["frame"])
        return {(i - cut["headAt"][0], j - cut["headAt"][1]): c for (i, j), c in cells.items() if c[:3] in keep and lo <= j <= hi}
    if kind == "motion":
        cells = v2_expected_cells(st, cut["motion"])[cut["frame"]]
        lo, hi = cut["cols"]
        return {(i + cut["shift"][0] - cut["headAt"][0], j + cut["shift"][1] - cut["headAt"][1]): c for (i, j), c in cells.items() if lo <= i <= hi}
    if kind == "border":
        cols = v2_sticker_border(st)
        if cut.get("colors") != cols:
            raise ValueError("the border colours %s are not the sticker's pastels in running order %s" % (cut.get("colors"), cols))
        return {(dx, dy): tuple(cols[v2_border_sector(dx, dy)]["rgb"]) + (255,) for (dx, dy) in v2_border_ring(st)}
    if kind == "sparkle":
        pal = v2_sticker_palette(st)
        want = {role: pal["highlights"][i] for i, role in enumerate("abc")}
        if cut.get("colors") != want:
            raise ValueError("the sparkle colours %s are not the sticker's highlight pastels %s" % (cut.get("colors"), want))
        for role, c in want.items():
            if not v2_in_band(st, *c["pixel"]):
                raise ValueError("the sparkle colour %s at %s is not in the sticker's border band" % (role, c["pixel"]))
        colors = {role: tuple(c["rgb"]) + (255,) for role, c in want.items()}
        layer = {}
        for star in cut["stars"]:
            for r, row in enumerate(star["rows"]):
                for c, ch in enumerate(row):
                    if ch != ".":
                        layer[(star["at"][0] + c, star["at"][1] + r)] = colors[ch]
        return layer
    if kind == "plush":
        picture = v2_png(st, V2_PLUSH[look["board"]])
        layer = {}
        roles = cut["roles"]
        for letter, spec in roles.items():
            mean = v2_patch_mean(picture, spec["rect"])
            if spec.get("snap") == "pet-eye":
                want = list(PET_EYE)
                if any(abs(mean[k] - PET_EYE[k]) > V2_BLACK_TOLERANCE for k in range(3)):
                    raise ValueError("role %s: the patch %s has mean %s, not within %d of the pet's near-black" % (letter, spec["rect"], mean, V2_BLACK_TOLERANCE))
            else:
                want = list(mean)
            if spec.get("rgb") != want:
                raise ValueError("role %s: colour %s, the mean of the patch %s of %s is %s" % (letter, spec.get("rgb"), spec["rect"], V2_PLUSH[look["board"]], want))
        ax, ay = cut["at"]
        for r, row in enumerate(cut["rows"]):
            for c, ch in enumerate(row):
                if ch != ".":
                    layer[(ax + c, ay + r)] = tuple(roles[ch]["rgb"]) + (255,)
        return layer
    raise ValueError("unknown cut kind %r" % (kind,))


V2_BLACK_TOLERANCE = 8          # a `snap` role takes the pet's near-black when the photograph's patch is within this of it, per channel


def v2_patch_mean(picture, rect):
    """The mean colour of a rectangle (inclusive pixel coordinates) of a decoded picture, rounded half up per channel; every pixel must be opaque."""
    w, h, rows = picture
    x0, y0, x1, y1 = rect
    if not (0 <= x0 <= x1 < w and 0 <= y0 <= y1 < h):
        raise ValueError("the rectangle %s lies outside the %d x %d picture" % (rect, w, h))
    total, n = [0, 0, 0], 0
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            px = rows[y][4 * x:4 * x + 4]
            if px[3] != 255:
                raise ValueError("pixel (%d, %d) of the rectangle %s is not opaque" % (x, y, rect))
            for k in range(3):
                total[k] += px[k]
            n += 1
    return [(v * 2 + n) // (2 * n) for v in total]


# ---- the v2 checks ------------------------------------------------------------------------------------------------------------------
def v2_c1():
    st = v2_state()
    a = st["atlas"]
    p = []
    if set(a) - {"bridges"} != set(V1_KEYS) | set(V2_KEYS):
        p.append("top-level keys %s, want the v1 keys plus schema, motions, looks (and optionally bridges)" % sorted(a))
    if a.get("schema") != 2 or isinstance(a.get("schema"), bool):
        p.append("schema=%r, want 2" % (a.get("schema"),))
    motions, looks = a.get("motions"), a.get("looks")
    if not isinstance(motions, list) or not isinstance(looks, list):
        return p + ["motions and looks must be lists"], ""
    ids = [m.get("id") for m in motions if isinstance(m, dict)]
    if len(ids) != len(set(ids)) or len(ids) != len(motions):
        p.append("motion ids are missing or repeated")
    missing = ([i for i in V2_ITEMS if i not in ids] + [i for i in V2_PHASE2_ITEMS if S.get("phase", 1) >= 2 and i not in ids]
               + [i for i in V2_PHASE3_ITEMS if S.get("phase", 1) >= 3 and i not in ids] + [i for i in V2_PHASE4_ITEMS if S.get("phase", 1) >= 4 and i not in ids])
    if missing:
        p.append("motions missing from the catalog: %s" % ", ".join(missing))
    for m in motions:
        if (isinstance(m, dict) and m.get("id") not in V2_ITEMS and m.get("id") not in V2_PHASE2_ITEMS and m.get("id") not in V2_PHASE3_ITEMS
                and m.get("id") not in V2_PHASE4_ITEMS and m.get("phase", 1) <= S.get("phase", 1)):
            p.append("%s is not an item of spec 3.2 or 3.4" % m.get("id"))
    need = ["id", "board", "kind", "uses", "source", "frames", "srcFrames", "ms", "stage", "head", "restStart", "restEnd",
            "overheadClear", "weight", "phase", "compatibleLooks"]
    for m in motions:
        if not isinstance(m, dict):
            p.append("a motion entry is not an object")
            continue
        for k in need:
            if k not in m:
                p.append("%s: no %s" % (m.get("id"), k))
        if m.get("kind") not in ("ported", "procedural", "redrawn"):
            p.append("%s: kind %r" % (m.get("id"), m.get("kind")))
        if not isinstance(m.get("uses"), list) or not all(isinstance(u, str) and (u in V2_USES or u.startswith("signature:")) for u in m.get("uses", [])):
            p.append("%s: uses %r" % (m.get("id"), m.get("uses")))
        if not isinstance(m.get("stage"), dict) or set(m["stage"]) != {"left", "right", "up", "down"}:
            p.append("%s: stage %r" % (m.get("id"), m.get("stage")))
    lids = [l.get("id") for l in looks if isinstance(l, dict)]
    if len(lids) != len(set(lids)) or len(lids) != len(looks):
        p.append("look ids are missing or repeated")
    for want in (V2_PHASE1_LOOKS if S.get("phase", 1) < 2 else [lid for lid, ph in V2_LOOK_PHASE.items() if ph <= S.get("phase", 1)]):
        if want not in lids:
            p.append("look %s missing" % want)
    for m in motions:
        if isinstance(m, dict) and m.get("id") in V2_ITEMS and m.get("phase") != 1:
            p.append("%s: phase %r, an A item is phase 1 (a later phase would skip it in the other checks)" % (m.get("id"), m.get("phase")))
        if isinstance(m, dict) and m.get("id") in V2_PHASE2_ITEMS and m.get("phase") != 2:
            p.append("%s: phase %r, a sticker item is phase 2 (spec 3.2, 3.3)" % (m.get("id"), m.get("phase")))
        if isinstance(m, dict) and m.get("id") in V2_PHASE3_ITEMS and m.get("phase") != 3:
            p.append("%s: phase %r, a plushie item is phase 3 (spec 3.2, 3.3)" % (m.get("id"), m.get("phase")))
        if isinstance(m, dict) and m.get("id") in V2_PHASE4_ITEMS and m.get("phase") != 4:
            p.append("%s: phase %r, a Claude Code item is phase 4 (spec 3.2, 3.3)" % (m.get("id"), m.get("phase")))
    for l in looks:
        if isinstance(l, dict) and l.get("id") in V2_LOOK_PHASE and l.get("phase") != V2_LOOK_PHASE[l["id"]]:
            p.append("look %s: phase %r, want %d (spec 3.3)" % (l.get("id"), l.get("phase"), V2_LOOK_PHASE[l["id"]]))
    for l in looks:
        for k in ("id", "board", "class", "weight", "signature", "anchor", "phase", "layers"):
            if k not in l:
                p.append("look %s: no %s" % (l.get("id"), k))
        if l.get("id") not in V2_LOOK_IDS:
            p.append("look %s is not a look of spec 3.3" % l.get("id"))
    return p, "schema 2 with %d motions and %d looks, v1 keys present" % (len(motions), len(looks))


def v2_c2():
    st = v2_state()
    art = S["art"]
    refs = set()
    p = []
    for mid, m in st["motions"].items():
        for rel in m["frames"]:
            refs.add(rel)
        if len(set(m["frames"])) != len(m["frames"]):
            p.append("%s: a frame path is listed twice" % mid)
        for k, rel in enumerate(m["frames"]):
            if rel != "motions/%s/%03d.png" % (mid, k):
                p.append("%s: frame %d is %r, want motions/%s/%03d.png" % (mid, k, rel, mid, k))
                break
    for l in st["looks"].values():
        for lay in l.get("layers", []):
            refs.add(lay["png"])
    for b in S["atlas"].get("bridges", []):
        if not isinstance(b, dict) or not isinstance(b.get("frames"), list):
            continue
        for k, rel in enumerate(b["frames"]):
            refs.add(rel)
            if rel != "bridges/%s/%03d.png" % (b.get("id"), k):
                p.append("%s: bridge frame %d is %r, want bridges/%s/%03d.png" % (b.get("id"), k, rel, b.get("id"), k))
    for rel in sorted(refs):
        if not os.path.isfile(os.path.join(art, rel)):
            p.append("missing %s" % rel)
    on_disk = set()
    for top in ("motions", "looks", "bridges"):
        for dirpath, _, names in os.walk(os.path.join(art, top)):
            for n in names:
                if not n.startswith("."):
                    on_disk.add(os.path.relpath(os.path.join(dirpath, n), art))
    for rel in sorted(on_disk - refs):
        p.append("%s is not referenced by the catalog" % rel)
    return p, "%d PNGs referenced, all present, none unreferenced" % len(refs)


def per_motion(fn, what):
    """Run fn(st, id, entry) over the selected motions; it returns a list of problems."""
    st = v2_state()
    p = []
    ids = v2_selected(st)
    for mid in ids:
        p += fn(st, mid, st["motions"][mid])
    return p, "%s in %d motions" % (what, len(ids))


def v2_p1():
    def one(st, mid, e):
        p = []
        kind = v2_kind(e)
        left, right, up, down = v2_stage_cells(e)
        want_w, want_h = CANVAS_CELLS + left + right, CANVAS_CELLS + up + down
        frames = v2_expected_cells(st, mid)
        if kind == "gif" and e["source"].get("grid") != V2_GIF_GRID:
            p.append("%s: source.grid %r is not the grid of the persona GIF %r" % (mid, e["source"].get("grid"), V2_GIF_GRID))
        for k, rel in enumerate(e["frames"]):
            w, h, _ = v2_png(st, rel)
            if (w, h) != (want_w, want_h):
                p.append("%s frame %d is %dx%d px, want %dx%d" % (mid, k, w, h, want_w, want_h))
                continue
            if kind == "redrawn":
                continue                      # a redrawn item has no source pixels: R1-R4 check it
            src = e["srcFrames"][k]
            exp = {c: v for c, v in frames[src].items() if -left <= c[0] < CANVAS_CELLS + right and -up <= c[1] < CANVAS_CELLS + down}
            got = v2_frame_cells(st, e, k)
            if got != exp:
                diff = sorted(set(got) ^ set(exp)) or sorted(c for c in got if got[c] != exp[c])
                p.append("%s frame %d (source frame %d) differs from the rasterized source at cell %s" % (mid, k, src, diff[0]))
                break
        return p
    return per_motion(one, "every frame equals the rasterized source frame (cell centres, declared colour map); redrawn items: the size only")


def v2_rest_equal(st, e, k):
    return v2_frame_cells(st, e, k) == st["rest"]


def v2_p2():
    def one(st, mid, e):
        p = []
        n = len(e["frames"])
        for key, k in (("restStart", 0), ("restEnd", n - 1)):
            real = v2_rest_equal(st, e, k)
            if e.get(key) is not real:
                p.append("%s: %s=%r but frame %d %s the v1 idle_0 at half-unit resolution" % (mid, key, e.get(key), k, "equals" if real else "differs from"))
        return p
    return per_motion(one, "restStart/restEnd are true exactly when the first/last frame equals v1 idle_0 (2x), pixel for pixel")


def v2_p3():
    notes = []

    def one(st, mid, e):
        p = []
        n = len(e["frames"])
        n_src = st["motions"][mid]["source"].get("frames", n)
        if e["restEnd"]:
            if e.get("hold") or e.get("offRest"):
                p.append("%s: ends on the rest frame but declares hold/offRest" % mid)
            if e.get("closeLoop"):
                if e["srcFrames"] != list(range(n_src)) + [0] or n != n_src + 1:
                    p.append("%s: closeLoop must append source frame 0 after all %d source frames" % (mid, n_src))
                if not e["restStart"] or v2_frame_cells(st, e, 0) != v2_frame_cells(st, e, n - 1):
                    p.append("%s: closeLoop needs a rest first frame and a last frame equal to it" % mid)
                if v2_rest_equal(st, e, n - 2):
                    p.append("%s: closeLoop although the source already ends on the rest frame" % mid)
        elif e.get("hold"):
            if e.get("closeLoop") or e.get("offRest") or not e["restStart"]:
                p.append("%s: hold needs a rest start and no closeLoop/offRest" % mid)
        elif e.get("offRest"):
            if e["restStart"] or e.get("closeLoop"):
                p.append("%s: offRest on a motion that starts on rest" % mid)
            notes.append(mid)
        else:
            p.append("%s: ends off the rest frame with no hold, no closeLoop and no offRest declaration" % mid)
        return p
    p, info = per_motion(one, "each motion ends on rest, holds its last frame, or closes the loop with its first frame")
    if notes:
        info += "; OFF-REST (no rest frame at either end, spec gap): " + ", ".join(notes)
    return p, info


def v2_p4():
    def one(st, mid, e):
        p = []
        frames = v2_expected_cells(st, mid)
        used = sorted(set(e["srcFrames"]))
        left = right = up = down = 0
        for f in used:
            for (i, j) in frames[f]:
                left, right = max(left, -i), max(right, i - (CANVAS_CELLS - 1))
                up, down = max(up, -j), max(down, j - (CANVAS_CELLS - 1))
        got = v2_stage_cells(e)
        if got != (left, right, up, down):
            p.append("%s: declared stage (cells l/r/u/d) %s, measured %s" % (mid, got, (left, right, up, down)))
        for k in e["stage"]:
            if e["stage"][k] * 2 != int(e["stage"][k] * 2):
                p.append("%s: stage.%s=%r is not a whole number of half units" % (mid, k, e["stage"][k]))
        return p
    return per_motion(one, "the declared stage equals the measured bounding box of all frames beyond the 12 x 12 canvas")


def v2_p5():
    def one(st, mid, e):
        p = []
        kind = v2_kind(e)
        if kind == "redrawn":
            eff = {tuple(c) for c in e.get("redraw", {}).get("effectColors", [])}
            official = set()
            for lid in ("A12-heart", "A14-lightbulb"):
                official |= {r[7] for r in v2_lottie(st, st["motions"][lid])[1]}
            if e.get("board") in V2_C_BOARDS or mid == V2_B7:
                with open(os.path.join(S["art"], V2_POSE_SOURCE), encoding="utf-8") as f:
                    cc = cc_colours(f.read().split("\n"))
                official |= {cc["dust"], cc["wood"], cc["gold"]}               # render-core.js: the dust (PX.dust) and the wand (CC_COLORS.wood, .gold)
            if not eff <= official:
                p.append("%s: effect colours %s are not colours of the official heart or lightbulb animation" % (mid, sorted(eff - official)[:3]))
            palette = {V2_PET_BODY + (255,), PET_EYE + (255,)} | {c + (255,) for c in eff}
        else:
            cm = v2_cmap(e)
            if kind == "gif":
                if cm != V2_GIF_MAP:
                    p.append("%s: colour map %s is not body -> pet body, black -> pet eye" % (mid, cm))
                palette = {cm.get(c, c) + (255,) for c in v2_gif(st)[2]}
            elif kind == "sprite":
                if cm != V2_SKATE_MAP:
                    p.append("%s: colour map %s is not the sprite's body -> pet body" % (mid, cm))
                v2_sprite_frame(st, V2_RIDE_SPRITE, 0, V2_SKATE_MAP)
                palette = {cm.get(c, c) + (255,) for c in st["sprites"][V2_RIDE_SPRITE]["palette"]}
            else:
                n, rects = v2_lottie(st, e)
                om = e["source"].get("omit", ())
                for frm, to in cm.items():
                    layers = {r[2] for r in rects if r[7] == frm}
                    if to == V2_PET_BODY and layers == {"orange"}:
                        continue
                    if to == PET_EYE and layers == {"black"}:
                        continue
                    p.append("%s: colour map %s -> %s is not body-layer -> pet body or eye-layer -> pet eye (layers %s)" % (mid, frm, to, sorted(layers)))
                palette = {cm.get(r[7], r[7]) + (255,) for r in rects
                           if not any(r[2] == o["layer"] and ("maxY" not in o or r[6] <= o["maxY"] * 100) for o in om)}
        for k, rel in enumerate(e["frames"]):
            w, h, rows = v2_png(st, rel)
            bad = set()
            for y in range(h):
                row = rows[y]
                for x in range(w):
                    px = tuple(row[x * 4:x * 4 + 4])
                    if px[3] == 0:
                        if px != (0, 0, 0, 0):
                            bad.add(px)
                    elif px not in palette:
                        bad.add(px)
            if bad:
                p.append("%s frame %d: pixel colours outside the source palette: %s" % (mid, k, sorted(bad)[:3]))
                break
        return p
    return per_motion(one, "every pixel is transparent or a source palette colour after the colour map (redrawn: the official palette)")


def v2_p6():
    def one(st, mid, e):
        p = []
        kind = v2_kind(e)
        n = len(e["frames"])
        if kind == "gif":
            delays = v2_gif(st)[1]
            if e["source"].get("frames") != len(delays) or e["source"].get("delaysMs") != delays:
                p.append("%s: source.frames/delaysMs differ from the GIF (%d frames)" % (mid, len(delays)))
            if e["srcFrames"] != list(range(len(delays))) or e["ms"] != delays:
                p.append("%s: srcFrames is not 0..%d or ms differs from the GIF's own delays" % (mid, len(delays) - 1))
            if not (len(e["frames"]) == len(e["srcFrames"]) == len(e["ms"]) == len(e["head"])):
                p.append("%s: frames/srcFrames/ms/head lengths differ" % mid)
            return p
        n_src = n if kind == "redrawn" else e["source"]["frames"]
        n_lot = n if kind == "redrawn" else (V2_SPRITES[V2_RIDE_SPRITE][2] if kind == "sprite" else v2_lottie(st, e)[0])
        if kind == "sprite":
            n_src = len(range(V2_RIDE_FRAMES[0], V2_RIDE_FRAMES[1] + 1))
            n_lot = n
            if e["source"]["frames"] != V2_SPRITES[V2_RIDE_SPRITE][2]:
                p.append("%s: source.frames=%r, the sprite has %d" % (mid, e["source"]["frames"], V2_SPRITES[V2_RIDE_SPRITE][2]))
        close = bool(e.get("closeLoop"))
        want_src = list(range(n_src)) + ([0] if close else [])
        if n_src != n_lot:
            p.append("%s: source.frames=%r, the file has %d" % (mid, n_src, n_lot))
        if kind == "sprite":
            want_src = list(range(V2_RIDE_FRAMES[0], V2_RIDE_FRAMES[1] + 1))
        if e["srcFrames"] != want_src:
            p.append("%s: srcFrames is not 0..%d%s" % (mid, n_src - 1, " plus 0" if close else ""))
        if not (len(e["frames"]) == len(e["srcFrames"]) == len(e["ms"]) == len(e["head"])):
            p.append("%s: frames/srcFrames/ms/head lengths %d/%d/%d/%d differ" % (mid, len(e["frames"]), len(e["srcFrames"]), len(e["ms"]), len(e["head"])))
        from fractions import Fraction
        want = [int(Fraction((k + 1) * 1000, FPS) + Fraction(1, 2)) - int(Fraction(k * 1000, FPS) + Fraction(1, 2)) for k in range(n)]
        if e.get("board") in V2_C_BOARDS:
            want = [V2_C_MS] * n                                              # spec 3.1 P6: 60 ms per frame for the C items
        if e["ms"] != want:
            p.append("%s: ms differs from %s per frame" % (mid, "60 ms" if e.get("board") in V2_C_BOARDS else "1000/12 (rounded cumulatively)"))
        return p
    return per_motion(one, "12 fps (the GIF: its own delays): ms per frame, one ms and one source frame per frame")


def v2_p7():
    st = v2_state()
    art = S["art"]
    p = []
    stems = set()
    for mid in v2_selected(st):
        e = st["motions"][mid]
        kind = v2_kind(e)
        s = e["source"]
        if kind == "redrawn" and v2_item(mid)[1] in V2_C_BOARDS:
            if (s.get("path"), s.get("board"), s.get("lines")) != (V2_POSE_SOURCE, v2_item(mid)[1], V2_C_LINES) or e.get("board") != s.get("board"):
                p.append("%s: source %r board %r lines %r, want %s board %s lines %s (spec 3.1 R5)" % (
                    mid, s.get("path"), s.get("board"), s.get("lines"), V2_POSE_SOURCE, v2_item(mid)[1], V2_C_LINES))
                continue
            path = os.path.join(art, V2_POSE_SOURCE)
        elif kind == "redrawn" and v2_item(mid)[1] in V2_POSE_BOARDS:
            want_lines = V2_B7_LINES if v2_item(mid)[1] == "B7" else V2_POSE_LINES
            if (s.get("path"), s.get("board"), s.get("lines")) != (V2_POSE_SOURCE, v2_item(mid)[1], want_lines) or e.get("board") != s.get("board"):
                p.append("%s: source %r board %r lines %r, want %s board %s lines %s (spec 3.2)" % (
                    mid, s.get("path"), s.get("board"), s.get("lines"), V2_POSE_SOURCE, v2_item(mid)[1], want_lines))
                continue
            path = os.path.join(art, V2_POSE_SOURCE)
        elif kind == "redrawn":
            board = v2_item(mid)[1]
            want = V2_STICKERS.get(board) or V2_PLUSH.get(board)
            if want is None or s.get("picture") != want[:-4] or s.get("ext") != "png" or s.get("board") != board or e.get("board") != s.get("board"):
                p.append("%s: source picture %r.%s / board %r, want %s (spec 3.2)" % (mid, s.get("picture"), s.get("ext"), s.get("board"), want))
                continue
            path = os.path.join(art, want)
        elif kind == "gif":
            if s.get("path") != V2_GIF:
                p.append("%s: source.path %r, want %s" % (mid, s.get("path"), V2_GIF))
                continue
            path = os.path.join(art, s["path"])
        elif kind == "sprite":
            if s.get("path") != V2_CHUNK:
                p.append("%s: source.path %r, want %s" % (mid, s.get("path"), V2_CHUNK))
                continue
            path = os.path.join(art, s["path"])
        else:
            stem = V2_ITEMS[mid][0] if mid in V2_ITEMS else None
            if stem and s.get("path") != "sources/lottie/%s.js" % stem:
                p.append("%s: source.path %r, want sources/lottie/%s.js (spec 3.2)" % (mid, s.get("path"), stem))
                continue
            path = os.path.join(art, s.get("path", ""))
        if not os.path.isfile(path):
            p.append("%s: source file %s missing" % (mid, os.path.relpath(path, art)))
        elif sha256_file(path) != s.get("sha256"):
            p.append("%s: sha256 of %s is %s, the catalog says %s" % (mid, os.path.relpath(path, art), sha256_file(path)[:12], str(s.get("sha256"))[:12]))
    for mid, e in st["motions"].items():
        if str(e["source"].get("path", "")).startswith("sources/lottie/"):
            stems.add(e["source"]["path"])
    on_disk = {"sources/lottie/" + n for n in os.listdir(os.path.join(art, "sources", "lottie")) if n.endswith(".js")}
    if stems != on_disk:
        p.append("catalog sources and sources/lottie/*.js differ: missing from the catalog %s, not on disk %s" % (sorted(on_disk - stems)[:3], sorted(stems - on_disk)[:3]))
    if len(on_disk) != 37:
        p.append("%d source files on disk, want the 37 official files" % len(on_disk))
    return p, "%d Lottie sources, each sha256 recorded and equal to the file, all 37 listed; the GIF and the stickers of the selected motions likewise" % len(on_disk)


def v2_heads(st, mid, e):
    """(heads, rigid, overhead_clear) recomputed from the shipped PNGs of motion mid."""
    key = ("heads", mid)
    if key not in st["cells"]:
        mine = v2_mine(st, e)
        body_like = {V2_PET_BODY} | v2_shade(st, e)
        heads, ok_over = [], True
        for k in range(len(e["frames"])):
            cells = v2_frame_cells(st, e, k)
            h, exact = head_of(cells, mine)
            heads.append((h, exact))
            if h is None or any(c[:3] not in body_like for (i, j), c in cells.items() if j < h[1]):
                ok_over = False
        st["cells"][key] = (heads, all(h is not None and x for h, x in heads), ok_over)
    return st["cells"][key]


def v2_h1():
    def one(st, mid, e):
        p = []
        heads, rigid, over = v2_heads(st, mid, e)
        for k, (h, exact) in enumerate(heads):
            if e["head"][k] != (None if h is None else list(h)):
                p.append("%s frame %d: head %r in the catalog, %r from the pixels" % (mid, k, e["head"][k], h))
                break
        if e.get("rigidHead") is not rigid:
            p.append("%s: rigidHead=%r, the pixels give %r" % (mid, e.get("rigidHead"), rigid))
        if e.get("overheadClear") is not over:
            p.append("%s: overheadClear=%r, the pixels give %r" % (mid, e.get("overheadClear"), over))
        return p
    return per_motion(one, "head anchors, rigidHead and overheadClear equal what the shipped pixels give")


def v2_u1():
    def one(st, mid, e):
        p = []
        kind = v2_kind(e)
        if mid in V2_ITEMS:
            declared = V2_ITEMS[mid][1]
        else:
            declared = v2_item(mid)[2]
        dropped = [d.split(":")[0] for d in e.get("usesDropped", [])]
        if declared is not None and sorted(e["uses"] + dropped) != sorted(declared):
            p.append("%s: uses %s plus dropped %s differ from the spec's %s" % (mid, e["uses"], dropped, declared))
        _, _, over = v2_heads(st, mid, e)
        total = sum(e["ms"])
        for u in e["uses"]:
            if u in V2_SCENE_USES and not over:
                p.append("%s: scene use %s but the motion is not overhead-clear" % (mid, u))
            if u == "sent" and total > 2000:
                p.append("%s: sent use but it lasts %d ms (> 2000)" % (mid, total))
            if u.startswith("signature:") and u.split(":", 1)[1] not in V2_LOOK_IDS:
                p.append("%s: %s names no look of spec 3.3" % (mid, u))
        for d in e.get("usesDropped", []):
            use, _, why = d.partition(":")
            ok = (why == "not-overhead-clear" and use in V2_SCENE_USES and not over) or (why == "longer-than-2.0s" and use == "sent" and total > 2000)
            if not ok:
                p.append("%s: %s is dropped without cause" % (mid, d))
        if kind == "lottie":
            want_w = 0.5 if e["source"]["frames"] / FPS > 8 else 1
        elif kind == "gif":
            want_w = 0.5 if total > 8000 else 1
        else:
            want_w = 1
        if e["weight"] != want_w:
            p.append("%s: weight %r, want %r (0.5 over 8 s)" % (mid, e["weight"], want_w))
        want_phase = 1 if mid in V2_ITEMS else (4 if mid in V2_PHASE4_ITEMS else (3 if mid in V2_PHASE3_ITEMS else 2))
        if e["phase"] != want_phase:
            p.append("%s: phase %r, want %d" % (mid, e["phase"], want_phase))
        if mid in V2_ITEMS:
            if (e["kind"] == "procedural") != (mid == "A5-walking-mirrored") or (e.get("mirrorOf") == "A5-walking") != (mid == "A5-walking-mirrored"):
                p.append("%s: kind/mirrorOf do not match the mirrored walk of spec 3.2" % mid)
        elif e["kind"] != ("ported" if kind in ("gif", "sprite") else "redrawn"):
            p.append("%s: kind %r does not match its source (%s)" % (mid, e["kind"], kind))
        if mid in V2_PHASE2_ITEMS | V2_PHASE3_ITEMS | V2_PHASE4_ITEMS and e.get("board") != v2_item(mid)[1]:
            p.append("%s: board %r, want %s" % (mid, e.get("board"), v2_item(mid)[1]))
        return p
    return per_motion(one, "uses follow spec 3.2 and 3.4 minus the scene uses that fail their rule; weights; phase")


def v2_cdicts(st, mid, e):
    """The shipped frames of a motion as canvas-cell dicts, once."""
    key = ("cdicts", mid)
    if key not in st["cells"]:
        st["cells"][key] = [v2_frame_cells(st, e, k) for k in range(len(e["frames"]))]
    return st["cells"][key]


def v2_own(c):
    return c is not None and c[:3] in V2_OWN


def v2_look_layers(st, lid):
    """The layers of a catalog look as dicts {name, z, attach, cells {(dx, dy): rgba}}; a phase 1 layer has no `attach` and sits at the head."""
    key = ("layers", lid)
    if key not in st["cells"]:
        out = []
        for lay in st["looks"][lid].get("layers", []):
            x0, y0 = lay["offset"]
            out.append({"name": lay.get("name"), "z": lay.get("z", "front"), "attach": lay.get("attach", "head"), "hugs": lay.get("hugs"),
                        "cells": png_cells(v2_png(st, lay["png"]), -x0, -y0)})
        st["cells"][key] = out
    return st["cells"][key]


def v2_effect_cells(C, hx, hy):
    """The cells of a frame (head anchor at (hx, hy)) that are not Clawd's body: a colour that is not Clawd's own, or Clawd's colour outside the body
    box (a raised arm; the box holds the squash and stretch of the official motions)."""
    x0, x1, y0, y1 = V2_BODY_BOX
    return {q for q, c in C.items() if not (v2_own(c) and x0 <= q[0] - hx <= x1 and y0 <= q[1] - hy <= y1)}


def v2_eye_cells(C, hx, hy):
    """The eye pixels of a frame: near-black cells inside the torso (a hat is not an eye)."""
    return {q for q, c in C.items() if c[:3] == PET_EYE and -8 <= q[0] - hx < 8 and 0 <= q[1] - hy < 12}


def v2_layer_cells(lay, hx, hy, lift):
    """The cells a layer covers in a frame's coordinates (feet anchored: the canvas' bottom-left plus the offset, the frame lifted by `lift`)."""
    if lay["attach"] == "feet":
        return {(dx, CANVAS_CELLS + dy + lift) for (dx, dy) in lay["cells"]}
    return {(hx + dx, hy + dy) for (dx, dy) in lay["cells"]}


def v2_eyes_are_the_point(e):
    """A motion whose catalog entry marks an eye expression: its redraw declares an `eyes:*` change (D4 chevrons, D5 swirls). R1 checks the
    marking against the pixels (a declared glyph must be drawn, and an undeclared eye change is refused)."""
    return any(c.startswith("eyes:") for c in e.get("redraw", {}).get("changes", []))


V2_ARM_CELLS = [(x, y) for x in range(8, 12) for y in range(4, 8)]       # the right arm's rest place relative to the head anchor


def v2_hand_cells(cells):
    """The arm cells (relative to the head) a prop layer lies on or touches: what the prop is anchored to."""
    return [a for a in V2_ARM_CELLS if a in cells or any(q in cells for q in ((a[0] + 1, a[1]), (a[0] - 1, a[1]), (a[0], a[1] + 1), (a[0], a[1] - 1)))]


def v2_baseline_ok(st, l, heads):
    """K1, the composite baseline (spec 9b item 12): the look's layers placed on the motion's frames (each frame's head anchor, the look's lift) have no
    cell below the feet baseline in any frame; the layers of V2_BELOW_BASELINE_OK (the skateboard's board) are exempt by name. A frame with no head
    anchor cannot place a head-anchored layer, so the pair fails."""
    lift = l.get("raiseCells", 0)
    for lay in v2_look_layers(st, l["id"]):
        if (l["id"], lay["name"]) in V2_BELOW_BASELINE_OK or not lay["cells"]:
            continue
        lowest = max(dy for (dx, dy) in lay["cells"])
        if lay["attach"] == "feet":
            if CANVAS_CELLS + lowest > V2_BASELINE_ROW:
                return False
            continue
        for head, _ in heads:
            if head is None or head[1] - lift + lowest > V2_BASELINE_ROW:
                return False
    return True


def v2_look_compat(st, mid, e, l, heads, rigid):
    """K1 for one (motion, look), from the shipped pixels (rules in scripts/port-phase2-art.py's docstring)."""
    if mid in l.get("signature", []):
        return l.get("layerOnSignature", True) is False or v2_baseline_ok(st, l, heads)       # K1-composite-baseline
    if not l.get("layers"):
        return True                    # a look with no layer (a body colour alone) needs no anchor: its recolour is an exact colour substitution on Clawd's own layers
    if not rigid:
        return v2_tier1_compat(st, mid, e, l, heads)       # K1-tier1-path
    scope = l.get("phase", 1) >= 2 or e.get("phase", 1) >= 2     # phase 1 looks against phase 1 motions are as phase 1 had them
    eyes = scope and v2_eyes_are_the_point(e)
    lift = l.get("raiseCells", 0)
    layers = v2_look_layers(st, l["id"])
    for f, C in enumerate(v2_cdicts(st, mid, e)):
        hx, hy = heads[f][0]
        effects, eye = (v2_effect_cells(C, hx, hy) if scope else None), (v2_eye_cells(C, hx, hy) if eyes else None)
        for lay in layers:
            a = lay["attach"]
            if lay["hugs"] == "rest-silhouette" and {(q[0] - hx, q[1] - hy) for q, c in C.items() if v2_own(c)} != v2_rest_silhouette(st):
                return False                   # the outline behind the rest silhouette would not hug the body: a limb moves, or the body squashes
            if a == "arm-right" and (sum(1 for x in range(hx + 8, hx + 12) for y in range(hy + 4, hy + 8) if v2_own(C.get((x, y)))) < 4
                                     or any(not v2_own(C.get((hx + x, hy + y))) for x, y in v2_hand_cells(lay["cells"]))):
                return False                   # the prop would float off the arm: its hand cells are not Clawd's in this frame
            if a == "feet" and any(not v2_own(C.get(q)) for q in V2_LEG_CELLS):
                return False
            if scope and lay["z"] == "front":          # a back layer is drawn under the frame and covers nothing
                placed = v2_layer_cells(lay, hx, hy, lift)
                if placed & effects or (eye and placed & eye):
                    return False
    return v2_baseline_ok(st, l, heads)       # K1-composite-baseline


V2_T1_DROPPED = {}                    # (look id, motion id) -> the GIF verdict that dropped the pair from tier 1 (frame numbers included); the porter holds its own copy
V2_T1_TOUCH = ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1))       # T1-touch-n8
V2_T1_BODY = {(215, 119, 87), (190, 104, 77), (191, 105, 77)}


def v2_t1_eyes(st, mid, e):
    """The eye centre of every frame of a motion, or None: the mean cell of the 4-connected components of eye pixels that 4-touch a body cell of Clawd."""
    key = ("t1eyes", mid)
    if key not in st["cells"]:
        out = []
        for C in v2_cdicts(st, mid, e):
            eyes = {q for q, c in C.items() if c[:3] == PET_EYE}
            seen, kept = set(), []
            for s in sorted(eyes):
                if s in seen:
                    continue
                comp, todo = [], [s]
                seen.add(s)
                while todo:
                    i, j = todo.pop()
                    comp.append((i, j))
                    for q in ((i + 1, j), (i - 1, j), (i, j + 1), (i, j - 1)):
                        if q in eyes and q not in seen:
                            seen.add(q)
                            todo.append(q)
                if any((C.get((i + di, j + dj)) or (0, 0, 0))[:3] in V2_T1_BODY for i, j in comp for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                    kept.extend(comp)
            out.append((sum(i for i, _ in kept) / len(kept), sum(j for _, j in kept) / len(kept)) if kept else None)
        st["cells"][key] = out
    return st["cells"][key]


def v2_t1_step_follows(heads, eyes, f):
    """The anchor's step from frame f-1 to frame f is within one cell of the eye centre's step; two exact head blocks pass, a frame without an eye centre fails."""
    if heads[f - 1][1] and heads[f][1]:
        return True
    if eyes[f - 1] is None or eyes[f] is None:
        return False
    (x0, y0), (x1, y1) = heads[f - 1][0], heads[f][0]
    return abs((x1 - x0) - (eyes[f][0] - eyes[f - 1][0])) <= 1 and abs((y1 - y0) - (eyes[f][1] - eyes[f - 1][1])) <= 1


def v2_t1_anchored(st, mid, e, heads):
    """Tier 1: every frame has a catalog head, and the head moves with the eyes from each frame to the next (no wrap from the last frame to the first)."""
    eyes = v2_t1_eyes(st, mid, e)
    for f, (h, _) in enumerate(heads):
        if h is None:
            return False                  # T1-a
        if f and heads[f - 1][0] is not None and not v2_t1_step_follows(heads, eyes, f):       # T1-b
            return False
    return True


def v2_tier1_compat(st, mid, e, l, heads):
    """K1 for a layered look on a motion that has no exact head block in some frame (tier 1; rules in scripts/port-phase2-art.py's docstring)."""
    if (l["id"], mid) in V2_T1_DROPPED:       # T1-dropped
        return False
    if not v2_t1_anchored(st, mid, e, heads):
        return False
    scope = l.get("phase", 1) >= 2 or e.get("phase", 1) >= 2       # today's scope of the effect and eye rules
    d_on = True                            # T1-d
    eyes = d_on and v2_eyes_are_the_point(e)
    lift = l.get("raiseCells", 0)
    body_like = {V2_PET_BODY} | v2_shade(st, e)
    layers = v2_look_layers(st, l["id"])
    for f, C in enumerate(v2_cdicts(st, mid, e)):
        if heads[f][0] is None:
            continue
        hx, hy = heads[f][0]
        effects, eye = (v2_effect_cells(C, hx, hy) if d_on else None), (v2_eye_cells(C, hx, hy) if eyes else None)
        over = {q for q, c in C.items() if q[1] < hy and c[:3] not in body_like}
        drawn = set()
        for lay in layers:
            a = lay["attach"]
            placed = v2_layer_cells(lay, hx, hy, lift)
            drawn |= placed
            if lay["hugs"] == "rest-silhouette" and {(q[0] - hx, q[1] - hy) for q, c in C.items() if v2_own(c)} != v2_rest_silhouette(st):       # T1-hugs
                return False
            if a == "arm-right" and v2_t1_hand_broken(C, hx, hy, lay):       # T1-held
                return False
            if a == "feet" and any(not v2_own(C.get(q)) for q in V2_LEG_CELLS):       # T1-feet
                return False
            if d_on and lay["z"] == "front" and (placed & effects or (eye and placed & eye)):
                return False
        if over & {(x + dx, y + dy) for (x, y) in drawn for dx, dy in V2_T1_TOUCH}:       # T1-c
            return False
    return v2_baseline_ok(st, l, heads)       # T1-baseline


def v2_t1_hand_broken(C, hx, hy, lay):
    """The held-arm rule failing in one frame: fewer than 4 of the arm's rest place are Clawd's own, or a hand cell of the prop is not."""
    return (sum(1 for x in range(hx + 8, hx + 12) for y in range(hy + 4, hy + 8) if v2_own(C.get((x, y)))) < 4
            or any(not v2_own(C.get((hx + x, hy + y))) for x, y in v2_hand_cells(lay["cells"])))


def v2_compat(st, mid, e):
    heads, rigid, _ = v2_heads(st, mid, e)
    names = ["plain"]
    for lid, l in st["looks"].items():
        if lid != "plain" and l.get("phase", 1) <= S.get("phase", 1) and v2_look_compat(st, mid, e, l, heads, rigid):
            names.append(lid)
    return names


def v2_t1_porter_dropped():
    """The porter's T1_DROPPED, read from its source text (never imported): the literal assigned at the top level of scripts/port-phase2-art.py, or None
    when it cannot be read; V2_T1_DROPPED when no porter sits beside a checker that is not in a `scripts` directory (the mutation runners run a copy of
    the checker alone in a temporary directory). In a `scripts` directory a missing porter reads as unreadable, so v2:K1 fails closed."""
    import ast
    here = os.path.dirname(os.path.abspath(__file__))
    porter = os.path.join(here, "port-phase2-art.py")
    if not os.path.exists(porter) and os.path.basename(here) != "scripts":
        return V2_T1_DROPPED
    try:
        with open(porter, encoding="utf-8") as f:
            tree = ast.parse(f.read())
        for node in tree.body:
            if isinstance(node, ast.Assign) and any(isinstance(x, ast.Name) and x.id == "T1_DROPPED" for x in node.targets):
                return ast.literal_eval(node.value)
    except (OSError, SyntaxError, ValueError):
        return None
    return None


def v2_k1():
    st = v2_state()
    p = []
    ids = v2_selected(st)
    phase = S.get("phase", 1)
    for mid in ids:
        e = st["motions"][mid]
        want = v2_compat(st, mid, e)
        got = [n for n in e["compatibleLooks"] if n == "plain" or st["looks"].get(n, {}).get("phase", 1) <= phase]
        if got != want:
            p.append("%s: compatibleLooks %s, recomputed %s" % (mid, got, want))
    porter_dropped = v2_t1_porter_dropped()
    if porter_dropped != V2_T1_DROPPED:
        p.append("the tier-1 dropped pairs differ: the checker holds %s, the porter %s" % (sorted(V2_T1_DROPPED), "unreadable" if porter_dropped is None else sorted(porter_dropped)))
    info = ("compatibleLooks equals the recomputation (head anchor present and front-facing in every frame, or (tier 1, a motion without an exact head block in some frame) "
            "present in every frame and moving with the eyes within one cell per frame step, with no overhead pixel of the motion on or next to a cell of the look; the held rules (the arm present, and the hand cells "
            "under or touching the prop are Clawd's in every frame), the feet rule and the hugging rule (Clawd's own cells equal the rest silhouette in every frame); "
            "no front layer on an effect pixel, none on an eye pixel of an eye expression; the composite baseline (the look's layers placed on every frame have no cell "
            "below the feet baseline, the skateboard's board excepted); or the look's own signature) in %d motions" % len(ids))
    if not S.get("only"):
        for lid, l in st["looks"].items():
            if lid == "plain" or l.get("phase", 1) > phase:
                continue
            n = sum(1 for mid in st["motions"] if st["motions"][mid].get("phase", 1) <= phase
                    and ("idle" in st["motions"][mid]["uses"] or ("signature:" + lid) in st["motions"][mid]["uses"])
                    and lid in v2_compat(st, mid, st["motions"][mid]))
            if n < V2_MIN_IDLE:
                p.append("look %s has %d compatible idle motions, at least %d are required (it would not be in rotation)" % (lid, n, V2_MIN_IDLE))
            info += "; %s: %d" % (lid, n)
    return p, info


GLASS_RGBA = {(150, 198, 236, 255), (250, 252, 255, 255), (190, 218, 236, 12)}
# spec 3.2 / 3.3: which official motion supplies each look's pixels, and the colours the cut may take (the frame is free: the checks
# below require that everything else in that frame is the rest pose, or an exact head block)
V2_CUT_SOURCE = {"sunglasses": ("A17-sunglasses", [PET_EYE]), "headphones": ("A18-headphones", [(26, 76, 127)]),
                 "coffee": ("A19-coffee", [(114, 114, 107), (47, 47, 45)]), "wand": ("A25-spark", [PET_EYE])}
V1_POSE_NAMES = ["idle", "blink", "listen", "think", "hop", "sleep", "dangle"]


def v1_cells(art, rel):
    """A 12 x 12 v1 frame as a 24 x 24 half-unit canvas-cell dict."""
    w, h, rows = read_png(os.path.join(art, rel))
    out = {}
    for y in range(h):
        for x in range(w):
            px = tuple(rows[y][x * 4:x * 4 + 4])
            if px[3]:
                for dy in (0, 1):
                    for dx in (0, 1):
                        out[(2 * x + dx, 2 * y + dy)] = px
    return out


def v1_head(cells):
    tops = face_block_tops(cells, {V2_PET_BODY, PET_EYE})
    if not tops:
        return None
    top = min(j for _, j in tops)
    row = [i for i, j in tops if j == top]
    return (row[0] + FACE_W // 2, top) if len(row) == 1 else None


def layer_expected(st, look, cut):
    """The cut-out {(dx, dy): colour} relative to the head anchor of the cut frame, derived from the declared cut alone."""
    art = S["art"]
    if cut.get("source") == "v1":
        if (look["id"], cut.get("pose"), cut.get("frame"), {tuple(c) for c in cut["colors"]}) != ("helmet", "helmet-idle", 0, GLASS_RGBA):
            raise ValueError("the helmet is cut from v1 helmet-idle frame 0, glass colours only")
        poses = S["atlas"]["poses"]
        cells = v1_cells(art, poses[cut["pose"]]["frames"][cut["frame"]])
        head = v1_head(v1_cells(art, poses["idle"]["frames"][0]))
        colors = {tuple(c) for c in cut["colors"]}
        return {(i - head[0], j - head[1]): c for (i, j), c in cells.items() if c in colors}
    mid = cut["motion"]
    want_mid, want_colors = V2_CUT_SOURCE.get(look["id"], (None, None))
    if mid != want_mid or sorted(tuple(c) for c in cut["colors"]) != sorted(want_colors) or bool(cut.get("aboveHead")) != (look["id"] == "wand"):
        raise ValueError("the %s cut must take %s from %s" % (look["id"], want_colors, want_mid))
    e = st["motions"][mid]
    cells = v2_expected_cells(st, mid)[cut["frame"]]
    colors = {tuple(c) for c in cut["colors"]}
    if look["class"] == ["costume"] and cut.get("restBody") is not True:
        raise ValueError("a costume cut must be taken from a frame where everything else is the rest pose (restBody)")
    if cut.get("restBody"):
        head = v1_head(st["rest"])             # everything but the prop is the rest pose: its head is the rest pose's head
    else:
        head, exact = head_of(cells, v2_mine(st, e))
        if head is None or not exact:
            raise ValueError("%s frame %d has no exact head block to anchor the %s cut" % (mid, cut["frame"], look["id"]))
    prop = {c: v for c, v in cells.items() if v[:3] in colors and (not cut.get("aboveHead") or c[1] < head[1])}
    if not prop:
        raise ValueError("the %s cut selects nothing" % look["id"])
    if cut.get("restBody"):
        stray = [c for c in set(cells) | set(st["rest"]) if c not in prop and cells.get(c) != st["rest"].get(c)]
        if stray:
            raise ValueError("%s frame %d: %d cells outside the prop differ from the rest pose" % (mid, cut["frame"], len(stray)))
    return {(i - head[0], j - head[1]): c for (i, j), c in prop.items()}


def v2_compose(st, layers, lift):
    """The rest body lifted by `lift` with the layers drawn in z order (back, body, front) as a canvas-cell dict."""
    out = {}
    for z in ("back", None, "front"):
        if z is None:
            out.update({(i, j - lift): c for (i, j), c in st["rest"].items()})
            continue
        for lay in layers:
            if lay["z"] == z:
                ox, oy = (0, CANVAS_CELLS) if lay["attach"] == "feet" else (12, 8 - lift)
                for (dx, dy), c in lay["cells"].items():
                    out[(ox + dx, oy + dy)] = c
    return out


def v2_check_look_spec(st, lid, look):
    """The spec's facts about one phase 2 look and its layers re-derived from the sources."""
    art = S["art"]
    spec = V2_LOOK_SPEC[lid]
    p = []
    if look.get("board") != spec["board"]:
        p.append("look %s: board %r, want %s" % (lid, look.get("board"), spec["board"]))
    classes = look.get("class")
    if not isinstance(classes, list) or set(classes) != spec["class"] or len(classes) != len(spec["class"]):
        p.append("look %s: class %r, want %s (spec 3.3)" % (lid, classes, sorted(spec["class"])))
    if look.get("weight") != spec["weight"]:
        p.append("look %s: weight %r, want %r (spec 3.3)" % (lid, look.get("weight"), spec["weight"]))
    if look.get("signature") != spec["signature"]:
        p.append("look %s: signature %r, want %s" % (lid, look.get("signature"), spec["signature"]))
    if look.get("raiseCells", 0) != spec["raise"]:
        p.append("look %s: raiseCells %r, want %d" % (lid, look.get("raiseCells"), spec["raise"]))
    want_anchor = "+".join(dict.fromkeys(V2_ANCHOR_OF[l[2]] for l in spec["layers"])) or None
    if look.get("anchor") != want_anchor:
        p.append("look %s: anchor %r, want %s" % (lid, look.get("anchor"), want_anchor))
    if look.get("layerOnSignature") is not spec.get("onSignature", not spec["signature"]):
        p.append("look %s: layerOnSignature %r, want %r (a signature motion that draws the prop itself needs no layer)" % (
            lid, look.get("layerOnSignature"), spec.get("onSignature", not spec["signature"])))
    layers = look.get("layers", [])
    if [l.get("name") for l in layers] != [l[0] for l in spec["layers"]]:
        return p + ["look %s: layers %s, want %s" % (lid, [l.get("name") for l in layers], [l[0] for l in spec["layers"]])]
    for lay, (name, z, attach, clicks, *hugs) in zip(layers, spec["layers"]):
        tag = "look %s layer %s" % (lid, name)
        if (lay.get("z"), lay.get("attach"), lay.get("takesClicks")) != (z, attach, clicks):
            p.append("%s: z/attach/takesClicks %s, want %s" % (tag, (lay.get("z"), lay.get("attach"), lay.get("takesClicks")), (z, attach, clicks)))
        if (lid, name) == ("winter", "snow"):
            if lay.get("png") != "looks/winter/snow.png" or lay.get("anchor") is not None:
                p.append("%s: png %r, anchor %r" % (tag, lay.get("png"), lay.get("anchor")))
            p += v2_check_snow(st, look, lay)
            continue
        if lay.get("hugs") != (hugs[0] if hugs else None):
            p.append("%s: hugs %r, want %r (the outline behind the rest silhouette is the only layer that hugs it)" % (tag, lay.get("hugs"), hugs[0] if hugs else None))
        if lay.get("png") != "looks/%s/%s.png" % (lid, name):
            p.append("%s: png %r" % (tag, lay.get("png")))
        if (lay.get("anchor") == "feet") != (attach == "feet"):
            p.append("%s: runtime anchor %r for attach %s" % (tag, lay.get("anchor"), attach))
        cut = lay.get("cut", {})
        plush = (lid, name) in V2_PLUSH_CUT
        pin = dict(V2_PLUSH_CUT[(lid, name)], kind="plush") if plush else V2_CUT_PIN[(lid, name)]
        free = ("path", "sha256", "ext") + (("colors",) if pin.get("kind") in V2_STICKER_CUTS else ())      # the sampled colours are re-derived below
        shown = {k: v for k, v in cut.items() if k not in free}
        if plush and isinstance(shown.get("roles"), dict):
            shown["roles"] = {r: {k: v for k, v in d.items() if k != "rgb"} for r, d in shown["roles"].items() if isinstance(d, dict)}      # the colours are re-derived below
        if shown != pin:
            p.append("%s: the cut %s is not the spec's %s" % (tag, {k: v for k, v in cut.items() if k not in ("path", "sha256")}, pin))
            continue
        src = V2_PLUSH[spec["board"]][:-4] if plush else V2_CUT_SOURCE_PATH.get(cut.get("kind"))
        if src is not None:
            is_picture = plush or cut.get("kind") in V2_STICKER_CUTS
            full = src + (".png" if is_picture else "")
            if cut.get("path") != src or is_picture != (cut.get("ext") == "png") or sha256_file(os.path.join(art, full)) != cut.get("sha256"):
                p.append("%s: source %r / sha256 %s do not match the file %s" % (tag, cut.get("path"), str(cut.get("sha256"))[:12], full))
        try:
            exp = layer_expected(st, look, cut) if "kind" not in cut else v2_derive_cut(st, look, cut)
        except (ValueError, KeyError, IndexError) as ex:
            p.append("%s: %s" % (tag, ex))
            continue
        x0, y0 = min(c[0] for c in exp), min(c[1] for c in exp)
        x1, y1 = max(c[0] for c in exp), max(c[1] for c in exp)
        if lay["offset"] != [x0, y0] or lay["size"] != [x1 - x0 + 1, y1 - y0 + 1]:
            p.append("%s: offset/size %s/%s, the cut gives %s/%s" % (tag, lay["offset"], lay["size"], [x0, y0], [x1 - x0 + 1, y1 - y0 + 1]))
        got = png_cells(v2_png(st, lay["png"]), -x0, -y0)
        if got != exp:
            p.append("%s: the layer PNG differs from the cut of its source (%d cells shipped, %d derived)" % (tag, len(got), len(exp)))
    if lid in V2_BODY_COLOUR:
        with open(os.path.join(art, V2_POSE_SOURCE), encoding="utf-8") as f:
            p += v2_body_map_problems(lid, look, f.read().split("\n"))
    lay_cells = v2_look_layers(st, lid)
    if lid == "detective" and look.get("restPicture") == {"source": "gif", "frame": 22}:
        if v2_compose(st, lay_cells, 0) != v2_gif_cells(st, 22):
            p.append("look detective: the rest picture with its hat and magnifier is not GIF frame 22")
    elif lid == "detective":
        p.append("look detective: restPicture %r" % (look.get("restPicture"),))
    if lid == "skateboard":
        want = {(x, y - 5): c + (255,) for (x, y), c in v2_sprite_frame(st, 1, 18, V2_SKATE_MAP).items()}
        if look.get("restPicture") != {"source": "sprite", "sprite": 1, "frame": 18, "origin": [0, 5], "raise": 6} or v2_compose(st, lay_cells, 6) != want:
            p.append("look skateboard: the rest picture (Clawd raised 6 cells on the board) is not sprite frame 18")
    if lid == "shiny":
        if "bodyColor" in look:
            p.append("look shiny: a bodyColor block %s (Clawd's own colours stay: the sticker's pastels are the border, not the body)" % sorted(look["bodyColor"]))
        border = [c for c in lay_cells if c["name"] == "border"]
        if border:
            ring = v2_border_ring(st)
            if set(border[0]["cells"]) != ring:
                p.append("look shiny: the border cells are not the 1-cell rounded ring outside the rest silhouette (%d shipped, %d derived)" % (len(border[0]["cells"]), len(ring)))
            inside = set(border[0]["cells"]) & v2_rest_silhouette(st)
            if inside:
                p.append("look shiny: %d border cells lie inside the rest silhouette, e.g. %s (the outline shows only outside the body)" % (len(inside), sorted(inside)[0]))
    return p


def v2_l1():
    st = v2_state()
    art = S["art"]
    p = []
    poses = S["atlas"]["poses"]
    v1 = {n: [v1_cells(art, rel) for rel in poses[n]["frames"]] for n in V1_POSE_NAMES + ["helmet-idle", "helmet-listen"]}
    v1h = {n: [v1_head(c) for c in v1[n]] for n in V1_POSE_NAMES}
    if any(h is None for hs in v1h.values() for h in hs):
        return ["a v1 pose frame has no exact head block"], ""
    count = 0
    for lid, look in st["looks"].items():
        if look.get("phase", 1) > S.get("phase", 1):
            continue
        layers = look.get("layers", [])
        if lid == "plain":
            if layers or look.get("anchor") is not None or look.get("class") != ["plain"]:
                p.append("plain must have no layer, no anchor and class [plain]")
            continue
        count += 1
        if lid in V2_LOOK_SPEC:
            p += v2_check_look_spec(st, lid, look)
            continue
        if len(layers) != 1:
            p.append("look %s: %d layers, want 1" % (lid, len(layers)))
            continue
        lay = layers[0]
        try:
            exp = layer_expected(st, look, lay["cut"])
        except (ValueError, KeyError, IndexError) as ex:
            p.append("look %s: %s" % (lid, ex))
            continue
        x0, y0 = min(c[0] for c in exp), min(c[1] for c in exp)
        x1, y1 = max(c[0] for c in exp), max(c[1] for c in exp)
        if lay["offset"] != [x0, y0] or lay["size"] != [x1 - x0 + 1, y1 - y0 + 1]:
            p.append("look %s: offset/size %s/%s, the cut gives %s/%s" % (lid, lay["offset"], lay["size"], [x0, y0], [x1 - x0 + 1, y1 - y0 + 1]))
        got = png_cells(v2_png(st, lay["png"]), -x0, -y0)
        if got != exp:
            p.append("look %s: the layer PNG differs from the cut-out of its declared source" % lid)
        if lay.get("z") != ("back" if lid == "helmet" else "front"):
            p.append("look %s: layer z is %r" % (lid, lay.get("z")))
        if look["anchor"] == "head":
            want = {n: [[h[0] + x0, h[1] + y0] for h in v1h[n]] for n in V1_POSE_NAMES}
            if lay.get("restPoses") != want:
                p.append("look %s: restPoses differ from the layer placed at each v1 frame's head anchor" % lid)
            if look.get("layerOnSignature") is not False:
                p.append("look %s: layerOnSignature must be false (the signature motion draws the prop itself)" % lid)
        if lid == "helmet":
            for name in ("idle", "listen"):
                for i, base in enumerate(v1[name]):
                    out = dict(base)
                    for (dx, dy), c in exp.items():
                        cell = (v1h[name][i][0] + dx, v1h[name][i][1] + dy)
                        if cell not in out or out[cell][3] != 255:
                            out[cell] = c
                    if out != v1["helmet-" + name][i]:
                        p.append("the cut-out helmet behind v1 %s frame %d does not reproduce v1 helmet-%s" % (name, i, name))
    return p, "%d look layers equal the cuts of their declared sources; costume layers anchor at the head of every v1 rest pose frame; the helmet reproduces v1%s" % (
        count, "; phase 2 looks: class, weight, signature, raise, anchors, cuts, rest pictures, shiny's border (shape and the sticker's pastels in running order) and sparkles re-derived" if S.get("phase", 1) >= 2 else "")


def v2_r1():
    st = v2_state()
    art = S["art"]
    p = []
    path = os.path.join(art, "reports", "resampling-report.json")
    rep = load_json(path)
    files = rep.get("files", {})
    stems = {os.path.basename(e["source"]["path"])[:-3]: (mid, e) for mid, e in st["motions"].items()
             if "omit" not in e["source"] and e["kind"] == "ported" and v2_kind(e) == "lottie"}
    if set(files) != set(stems):
        p.append("the report lists %d files, the catalog has %d ported sources" % (len(files), len(stems)))
    for stem, (mid, e) in sorted(stems.items()):
        if stem not in files:
            continue
        n, rects = v2_lottie(st, e)
        origin = e["source"]["origin"]
        verts = [(x, y) for r in rects for x in (r[3], r[5]) for y in (r[4], r[6])]       # four corners per rectangle, as the spec counts

        def dev(v, o):
            d = (v - o * 100) % 5000
            return min(d, 5000 - d)

        f = files[stem]
        off = sum(1 for x, y in verts if dev(x, origin[0]) > 200 or dev(y, origin[1]) > 200)
        phase = f.get("bestFitPhase", [0, 0])
        best = sum(1 for x, y in verts if dev(x, int(phase[0] * 4) / 4) > 200 or dev(y, int(phase[1] * 4) / 4) > 200)
        lost, thin = 0, 0
        for r in rects:                      # a rectangle no cell centre falls into never reaches a cell
            hit = any(r[3] <= (origin[0] + CELL * i + CELL // 2) * 100 < r[5] and 0 <= origin[0] + CELL * i + CELL // 2 < SRC_W
                      for i in range((r[3] // 100 - origin[0]) // CELL - 1, (r[5] // 100 - origin[0]) // CELL + 2)) and \
                any(r[4] <= (origin[1] + CELL * j + CELL // 2) * 100 < r[6] and 0 <= origin[1] + CELL * j + CELL // 2 < SRC_H
                    for j in range((r[4] // 100 - origin[1]) // CELL - 1, (r[6] // 100 - origin[1]) // CELL + 2))
            if not hit:
                lost += 1
                thin = max(thin, min(r[5] - r[3], r[6] - r[4]) / 100)
        if (f.get("rectanglesLostToSampling"), f.get("lostMaxThinSidePx")) != (lost, thin):
            p.append("%s: report says %s rectangles lost to sampling (thin side up to %s px), recomputed %d (%s px)"
                     % (stem, f.get("rectanglesLostToSampling"), f.get("lostMaxThinSidePx"), lost, thin))
        if (f.get("vertices"), f.get("offGridAtOrigin"), f.get("offGridAtBestFit"), f.get("origin"), f.get("board")) != (len(verts), off, best, origin, e["board"]):
            p.append("%s: report says %s vertices / %s off-grid at origin %s / %s at the best fit, recomputed %d / %d at %s / %d"
                     % (stem, f.get("vertices"), f.get("offGridAtOrigin"), f.get("origin"), f.get("offGridAtBestFit"), len(verts), off, origin, best))
    for stem in ("Clawd-ConfettiHappy", "Clawd-Juggling", "Clawd-Fishing"):
        f = files.get(stem, {})
        for k in ("frames", "ambiguousCellsPerFrame", "centreVsMajorityFlipsPerFrame", "worstFrames"):
            if k not in f:
                p.append("%s: no %s in the report (the partly off-grid files carry the resampling detail)" % (stem, k))
    for rel in ("preview/v2/contact-sheet-phase1.png", "preview/v2/resampling-review.png"):
        try:
            w, h, _ = read_png(os.path.join(art, rel))
            if w < 200 or h < 200:
                p.append("%s is only %dx%d" % (rel, w, h))
        except (OSError, ValueError) as ex:
            p.append("%s: %s" % (rel, ex))
    return p, "resampling report lists %d files (vertex counts recomputed from the sources), detail for ConfettiHappy, Juggling and Fishing; contact sheet and resampling picture decode" % len(files)


# ---- the phase 2 checks: redrawn items (R1-R4), look cuts against the v1 poses, the GIF sampling, goldens, the contact sheet -------------
def v2_arm_variant(own, change):
    if change == "arm-right:lifted":
        return {q for q in own if not (20 <= q[0] <= 23 and 12 <= q[1] <= 15)} | {(i, j - 2) for (i, j) in own if 20 <= i <= 23 and 12 <= j <= 15}
    return {q for q in own if not (20 <= q[0] <= 23 and 12 <= q[1] <= 15)} | {(i, j) for i in range(16, 20) for j in range(3, 8)}


def v2_connected(cells):
    cells = set(cells)
    if not cells:
        return False
    todo, seen = [min(cells)], set()
    while todo:
        q = todo.pop()
        if q in seen:
            continue
        seen.add(q)
        todo += [(q[0] + a, q[1] + b) for a in (-1, 0, 1) for b in (-1, 0, 1) if (q[0] + a, q[1] + b) in cells]
    return seen == cells


def v2_glyph_problem(eyes, variant):
    """Why a set of eye cells is not the declared glyph pair, or None: the right eye mirrors the left about x = 12, both sit in the head
    block's rows 1..4 (canvas rows 9..12) next to their rest place, each is one connected shape."""
    left = {q for q in eyes if q[0] < 12}
    right = {q for q in eyes if q[0] >= 12}
    if {(23 - x, y) for (x, y) in left} != right:
        return "the right eye is not the left one mirrored about x = 12"
    if not left or min(q[1] for q in left) < 9 or max(q[1] for q in left) > 12 or min(q[0] for q in left) < 5 or max(q[0] for q in left) > 8:
        return "an eye lies outside columns 5..8 and rows 9..12"
    if not v2_connected(left):
        return "an eye is not one connected shape"
    lo, hi = (4, 8) if variant == "eyes:chevrons" else (9, 13)
    if not lo <= len(left) <= hi:
        return "an eye has %d cells, want %d..%d" % (len(left), lo, hi)
    height = max(q[1] for q in left) - min(q[1] for q in left) + 1
    if height < (3 if variant == "eyes:chevrons" else 4):
        return "an eye is only %d rows tall" % height
    return None


def v2_caret_eyes(st):
    """D19's `^ ^` as canvas cells: the eye cells of A3 JumpingHappy's frame 7 (the official pixels) relative to that frame's head anchor, put on the
    rest head (12, 8). They must be the 8 cells of V2_CARET."""
    mid, f = V2_CARET_SOURCE
    e = st["motions"][mid]
    h = v2_heads(st, mid, e)[0][f][0]
    C = v2_cdicts(st, mid, e)[f]
    rel = {(i - h[0], j - h[1]) for (i, j), c in C.items() if c[:3] == PET_EYE and 0 <= j - h[1] < 12 and -8 <= i - h[0] < 8}
    if rel != V2_CARET:
        raise ValueError("%s frame %d has the eye cells %s, not the `^ ^` %s" % (mid, f, sorted(rel), sorted(V2_CARET)))
    return {(12 + dx, 8 + dy) for dx, dy in rel}


def v2_unit_cells(units):
    """The eye cells of the given unit columns: 2 x 2 cells each, on the eyes' unit row (render-core.js:119-122)."""
    return {(2 * u + dx, V2_EYE_ROW + dy) for u in units for dx in (0, 1) for dy in (0, 1)}


def v2_r1_body():
    st = v2_state()
    p, n = [], 0
    rest_own = set(st["rest"])
    rest_eyes = {q for q, c in st["rest"].items() if c[:3] == PET_EYE}
    legs = {q for q in rest_own if q[1] >= 20}
    for mid in v2_selected(st):
        e = st["motions"][mid]
        if v2_kind(e) != "redrawn" or e.get("board") in V2_C_BOARDS:          # the C items are checked by v2:R5, frame by frame
            continue
        n += 1
        red = e.get("redraw", {})
        changes = red.get("changes", [])
        if red.get("base") != "idle_0" or not changes or any(c not in V2_REDRAW_CHANGES for c in changes):
            p.append("%s: redraw %r is not a base idle_0 with changes from %s" % (mid, red, sorted(V2_REDRAW_CHANGES)))
            continue
        arms = [c for c in changes if c.startswith("arm")]
        foot = "legs:left-up" in changes
        variants = [rest_own] + [v2_arm_variant(rest_own, c) for c in arms] + ([rest_own - V2_LEFT_LEGS_UP] if foot else [])
        eff = {tuple(c) for c in red.get("effectColors", [])}
        glyph = [c for c in changes if c.startswith("eyes")]
        shown = False
        for k, C in enumerate(v2_cdicts(st, mid, e)):
            own = {q for q, c in C.items() if c[:3] in (V2_PET_BODY, PET_EYE)}
            if own not in variants:
                p.append("%s frame %d: Clawd's cells are not the rest body with the declared arm and foot changes (%d cells, %d differ)" % (
                    mid, k, len(own), min(len(own ^ v) for v in variants)))
                break
            if not all((i, j) in own for i in range(4, 20) for j in range(8, 20)) or not (legs - V2_LEFT_LEGS_UP) <= own or \
                    not (legs <= own or (foot and own == rest_own - V2_LEFT_LEGS_UP)):
                p.append("%s frame %d: the torso (8 x 6 units) or the four legs are not whole" % (mid, k))
                break
            eyes = {q for q, c in C.items() if c[:3] == PET_EYE}
            if eyes != rest_eyes:
                if not glyph:
                    why = "eyes differ from the rest pose with no eyes change declared"
                elif glyph[0] in ("eyes:chevrons", "eyes:spirals"):
                    why = v2_glyph_problem(eyes, glyph[0])
                elif glyph[0] == "eyes:carets":
                    why = None if eyes == v2_caret_eyes(st) and red.get("glyph") == {"motion": V2_CARET_SOURCE[0], "frame": V2_CARET_SOURCE[1]} else (
                        "the eyes are not the `^ ^` of %s frame %d (the official pixels) or the redraw does not name that source" % V2_CARET_SOURCE)
                elif eyes != v2_unit_cells(V2_EYE_UNITS[glyph[0]]):
                    why = "the eyes are not the %s of render-core.js (unit columns %s on unit row 5)" % (glyph[0], V2_EYE_UNITS[glyph[0]])
                else:
                    why = None
                if why:
                    p.append("%s frame %d: %s" % (mid, k, why))
                    break
                shown = True
            other = {c[:3] for c in C.values() if c[:3] not in (V2_PET_BODY, PET_EYE)}
            if not other <= eff:
                p.append("%s frame %d: colours %s are not declared effect colours" % (mid, k, sorted(other - eff)[:3]))
                break
        if glyph and not shown:
            p.append("%s: declares %s but no frame draws it" % (mid, glyph[0]))
        if foot and not any({q for q, c in C.items() if c[:3] in (V2_PET_BODY, PET_EYE)} == rest_own - V2_LEFT_LEGS_UP for C in v2_cdicts(st, mid, e)):
            p.append("%s: declares legs:left-up but no frame lifts the left foot" % mid)
    return p, "%d redrawn motions: Clawd's own cells equal the rest body plus the declared arm and foot changes (8-unit torso, 6 rows, four legs whole or the left foot one unit up), eyes are the rest eyes, the declared mirrored glyph or the declared eye pose of render-core.js, other colours are declared effects" % n


def v2_r2_anchor():
    st = v2_state()
    art = S["art"]
    p, pairs = [], 0
    poses = S["atlas"]["poses"]
    for n in V1_POSE_NAMES:
        for k, rel in enumerate(poses[n]["frames"]):
            if v1_head(v1_cells(art, rel)) is None:
                p.append("v1 pose %s frame %d has no exact head block to anchor a layer at" % (n, k))
    for lid, spec in V2_LOOK_SPEC.items():
        look = st["looks"].get(lid)
        if look is None or look.get("phase", 1) > S.get("phase", 1) or not look.get("layers"):
            continue
        for mid, e in st["motions"].items():
            if e.get("phase", 1) > S.get("phase", 1) or lid not in e["compatibleLooks"] or mid in look.get("signature", []):
                continue
            pairs += 1
            heads, rigid, _ = v2_heads(st, mid, e)
            if not (rigid or v2_t1_anchored(st, mid, e, heads)):       # R2-tier1
                p.append("%s is listed for %s but not every frame has an exact head block, and its head does not follow the eyes in every frame" % (mid, lid))
    return p, ("every layer sits at a constant offset from the head anchor, which is an exact head block in every frame or (tier 1) a catalog head that follows the eyes "
               "from frame to frame: %d (motion, look) pairs and all v1 pose frames" % pairs)


def v2_r3_bounds():
    st = v2_state()
    p, cells_n = [], 0
    for lid, spec in V2_LOOK_SPEC.items():
        look = st["looks"].get(lid)
        if look is None or look.get("phase", 1) > S.get("phase", 1):
            continue
        lift = look.get("raiseCells", 0)
        for lay in v2_look_layers(st, lid):
            a = lay["attach"]
            for (dx, dy) in lay["cells"]:
                cells_n += 1
                row = CANVAS_CELLS + dy if a == "feet" else 8 - lift + dy
                col = dx if a == "feet" else 12 + dx
                if row > CANVAS_CELLS - 1:
                    p.append("look %s layer %s: a cell is %d rows below the feet baseline" % (lid, lay["name"], row - CANVAS_CELLS + 1))
                    break
                if not -8 <= col <= 32:
                    p.append("look %s layer %s: a cell lies %d cells beyond the stage of 4 units" % (lid, lay["name"], col))
                    break
                if a == "head" and "costume" in spec["class"] and dy < -8:
                    p.append("look %s layer %s: a costume rises %d cells above the torso (limit 8 = 4 units)" % (lid, lay["name"], -dy))
                    break
                if a == "arm-right" and not (dx <= 19 and -4 <= dy <= 15):
                    p.append("look %s layer %s: a held cell (%d, %d) is more than 4 units from the holding arm" % (lid, lay["name"], dx, dy))
                    break
    for mid in v2_selected(st):
        e = st["motions"][mid]
        if v2_kind(e) != "redrawn":
            continue
        for k, C in enumerate(v2_cdicts(st, mid, e)):
            for (i, j), c in C.items():
                if c[:3] not in (V2_PET_BODY, PET_EYE) and (j < -8 or not -8 <= i <= 32):
                    p.append("%s frame %d: an effect pixel at (%d, %d) is outside the 4-unit stage" % (mid, k, i, j))
                    break
    return p, "%d look layer cells: nothing below the baseline, costumes up to 4 units above the torso, held props within 4 units of the arm, all inside a 4-unit stage; redrawn effects inside the stage" % cells_n


# Spec 3.1 R3: nothing lies below the feet baseline (canvas cell row 23, the last row of the rest pose's legs) except the skateboard look's board.
# The exception is named here and nowhere else: a layer is exempt only as (look id, layer name).
V2_BELOW_BASELINE_OK = frozenset({("skateboard", "board")})
V2_BASELINE_ROW = CANVAS_CELLS - 1


def v2_v1_heads(st):
    """[(tag, head x, head y)] of the rest placement and of every v1 pose frame, once: the places a look layer is drawn for sure."""
    if "v1heads" not in st:
        art = S["art"]
        out = [("the rest placement", 12, 8)]
        poses = S["atlas"]["poses"]
        for name in V1_POSE_NAMES:
            for k, rel in enumerate(poses[name]["frames"]):
                h = v1_head(v1_cells(art, rel))
                if h is not None:
                    out.append(("v1 pose %s frame %d" % (name, k), h[0], h[1]))
        st["v1heads"] = out
    return st["v1heads"]


def v2_baseline():
    """R3, the rows below the feet: no pixel of any motion frame, recomputed from the shipped PNGs (the declared stage.down is not trusted:
    P4 only makes it equal to what the frames hold), and no cell of a look layer at its rest placement or on any v1 pose frame, with the lift
    of the look applied, except the layers of V2_BELOW_BASELINE_OK."""
    st = v2_state()
    p, frames_n, cells_n = [], 0, 0
    for mid in v2_selected(st):
        e = st["motions"][mid]
        for k in range(len(e["frames"])):
            frames_n += 1
            if v2_kind(e) == "sprite":
                # D14 ride (R4-1): the stored frames reach 3 units below the canvas, that is storage only. What counts is the composed frame, lifted by the
                # look's raise, and below its baseline only board cells may lie.
                lift = v2_ride_raise()
                low = sorted(q for q, c in v2_frame_cells(st, e, k).items() if q[1] - lift > V2_BASELINE_ROW and c[:3] not in V2_BOARD)
            else:
                low = sorted(q for q in v2_frame_cells(st, e, k) if q[1] > V2_BASELINE_ROW)
            if low:
                p.append("%s frame %d: %d pixel(s) below the feet baseline (cell row %d is the last row), the lowest at row %d" % (
                    mid, k, len(low), V2_BASELINE_ROW, max(q[1] for q in low)))
                break
    for lid, look in st["looks"].items():
        if lid == "plain" or look.get("phase", 1) > S.get("phase", 1):
            continue
        lift = look.get("raiseCells", 0)
        for lay in v2_look_layers(st, lid):
            if (lid, lay["name"]) in V2_BELOW_BASELINE_OK:
                continue
            for tag, hx, hy in v2_v1_heads(st):
                cells_n += len(lay["cells"])
                rows = [CANVAS_CELLS + dy if lay["attach"] == "feet" else hy - lift + dy for (dx, dy) in lay["cells"]]
                if max(rows) > V2_BASELINE_ROW:
                    p.append("look %s layer %s: a cell lies %d rows below the feet baseline on %s" % (lid, lay["name"], max(rows) - V2_BASELINE_ROW, tag))
                    break
    return p, ("no pixel below cell row %d in %d motion frames (read from the PNGs) and in the look layers at the rest placement and on the v1 pose frames "
               "(%d cells tested); exempt by name: %s" % (V2_BASELINE_ROW, frames_n, cells_n, ", ".join("%s/%s" % k for k in sorted(V2_BELOW_BASELINE_OK))))


# Spec 9b item 12: how the runtime places a layer is its render `anchor` (StageCompose.swift: head, canvas, feet), while K1 and R3 place layers by `attach`.
# A layer the runtime would draw somewhere else than K1 and R3 assumed passes both, so the anchor is validated: unset or head for every layer, feet
# only for the layer of an under-feet look that is attached to the feet.
V2_RENDER_ANCHORS = (None, "head")


def v2_anchors():
    st = v2_state()
    p, n = [], 0
    for lid, look in st["looks"].items():
        if lid == "plain" or look.get("phase", 1) > S.get("phase", 1):
            continue
        under_feet = "under-feet" in (look.get("class") or [])
        for lay in look.get("layers", []):
            n += 1
            anchor, attach = lay.get("anchor"), lay.get("attach", "head")
            ok = (anchor in V2_RENDER_ANCHORS and attach != "feet") or (anchor == "feet" and attach == "feet" and under_feet)      # L3-anchor-rule
            if not ok:
                p.append("look %s layer %s: render anchor %r with attach %r (the anchor must be unset or head; feet only for the feet-attached layer of an under-feet look)" % (
                    lid, lay.get("name"), anchor, attach))
    return p, "%d look layers: the render anchor is unset or head, and feet only on the feet-attached layer of an under-feet look" % n


# Spec 3.3 / 9b item 12: the looks that declare a body colour (Ultra, winter), and the colours Clawd's body and shade pixels may be mapped from. A look carries a
# `bodyColor` map only if it is named here; a map never touches the eye colour.
V2_BODY_COLOUR = {"ultra": (175, 135, 255), "winter": (173, 216, 230)}
V2_BODY_FROM = ((215, 119, 87), (190, 104, 77), (191, 105, 77))


def v2_body_colours():
    st = v2_state()
    p, n = [], 0
    for lid, look in st["looks"].items():
        if look.get("phase", 1) > S.get("phase", 1) or lid == "plain":
            continue
        if "bodyColor" not in look:
            if lid in V2_BODY_COLOUR:
                p.append("look %s: the spec declares the body colour %s, the look has no bodyColor map" % (lid, V2_BODY_COLOUR[lid]))
            continue
        n += 1
        if lid not in V2_BODY_COLOUR:                                                                                                  # L4-declared-rule
            p.append("look %s carries a bodyColor map but the spec declares no body colour for it (only %s do)" % (lid, ", ".join(sorted(V2_BODY_COLOUR))))
            continue
        block = look["bodyColor"]
        items = block.get("map") if isinstance(block, dict) else None
        if not isinstance(items, list) or not items or not all(isinstance(i, dict) and set(i) == {"from", "to"} for i in items):
            p.append("look %s: bodyColor is not {map: [{from, to}, ...]}" % lid)
            continue
        for i in items:
            for key in ("from", "to"):
                c = i[key]
                if not (isinstance(c, list) and len(c) == 3 and all(isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 255 for v in c)):
                    p.append("look %s: bodyColor %s %r is not an rgb triple" % (lid, key, c))
        if p:
            continue
        for i in items:
            if tuple(i["from"]) == PET_EYE or tuple(i["to"]) == PET_EYE:                                                              # L4-eye-rule
                p.append("look %s: the bodyColor map touches the eye colour %s (%s -> %s)" % (lid, PET_EYE, i["from"], i["to"]))
        for c in V2_BODY_FROM[:1]:
            to = [tuple(i["to"]) for i in items if tuple(i["from"]) == c]
            if to != [V2_BODY_COLOUR[lid]]:
                p.append("look %s: the body colour %s is mapped to %s, the spec declares %s" % (lid, c, to, V2_BODY_COLOUR[lid]))
        stray = [i["from"] for i in items if tuple(i["from"]) not in V2_BODY_FROM]
        if stray:
            p.append("look %s: the bodyColor map takes colours that are not Clawd's body or shade: %s" % (lid, stray))
    return p, "%d looks carry a bodyColor map, each declared by the spec (%s), none touches the eye colour; shiny and every other look carry none" % (n, ", ".join(sorted(V2_BODY_COLOUR)))


# Spec 3.1 P2/P3 for a redrawn item, from the pixels alone. A redrawn item has no source frames to inherit a rest frame from, so its first frame is
# always the rest frame, and its last frame is too unless the spec justifies a hold for that item. Spec 3.1 P3 names one hold, Snooze (A15), which
# is ported; no redrawn item is justified. The restStart/restEnd/hold flags of the catalog never decide this.
V2_SPEC_HOLDS = frozenset()


def v2_redrawn_rest():
    st = v2_state()
    p, n, pinned = [], 0, 0
    for mid in v2_selected(st):
        e = st["motions"][mid]
        if v2_kind(e) != "redrawn":
            continue
        if e.get("board") in V2_C_BOARDS:
            pinned += 1                    # R5 pins every frame of a C item to Claude Code's data: an entrance starts from nothing, celebrate ends sunk
            continue
        n += 1
        last = len(e["frames"]) - 1
        if v2_frame_cells(st, e, 0) != st["rest"]:
            p.append("%s: the first frame is not the v1 idle_0 at half-unit resolution at the anchor (restStart is %r)" % (mid, e.get("restStart")))
        if v2_frame_cells(st, e, last) != st["rest"] and not (e.get("hold") is True and mid in V2_SPEC_HOLDS):
            p.append("%s: the last frame is not the v1 idle_0 at half-unit resolution at the anchor and the spec justifies no hold for it (restEnd is %r, hold is %r)" % (
                mid, e.get("restEnd"), e.get("hold")))
    return p, ("%d redrawn motions: the first frame and, absent a spec-justified hold (%d named), the last frame equal v1 idle_0 (2x) pixel for pixel, recomputed from the PNGs; "
               "%d C motions are pinned frame by frame to Claude Code's data by v2:R5 instead" % (n, len(V2_SPEC_HOLDS), pinned))


def v2_line_range(spec):
    lo, _, hi = spec.partition("-")
    return int(lo), int(hi or lo)


def v2_pose_vocabulary(st):
    """The problems of the B items' provenance: for each declared change of a B item, every (line range, text) of V2_POSE_VOCABULARY is found in
    the lines of the copied render-core.js that the item cites."""
    p = []
    path = os.path.join(S["art"], V2_POSE_SOURCE)
    if not os.path.isfile(path):
        return ["%s is missing" % V2_POSE_SOURCE]
    with open(path, encoding="utf-8") as f:
        text = f.read().split("\n")
    for mid in v2_selected(st):
        e = st["motions"][mid]
        if v2_kind(e) != "redrawn" or e.get("board") not in V2_POSE_BOARDS:
            continue
        cited = e["source"].get("lines", [])
        for change in e.get("redraw", {}).get("changes", []):
            for span, needle in V2_POSE_VOCABULARY.get(change, [("0", None)]):
                if needle is None:
                    p.append("%s: change %r has no entry in the pose vocabulary of render-core.js" % (mid, change))
                    continue
                lo, hi = v2_line_range(span)
                if span not in cited:
                    p.append("%s: the %s change needs lines %s of render-core.js, the entry cites %s" % (mid, change, span, cited))
                elif not any(needle in text[k - 1] for k in range(lo, hi + 1) if k - 1 < len(text)):
                    p.append("%s: render-core.js lines %s do not contain %r (the %s change)" % (mid, span, needle, change))
    return p


def v2_r4_provenance():
    st = v2_state()
    art = S["art"]
    p = []
    want = {}
    for mid, e in st["motions"].items():
        if e.get("phase", 1) <= S.get("phase", 1) and v2_kind(e) != "lottie":
            s = e["source"]
            want[(s["picture"] + "." + s["ext"]) if s.get("picture") else s.get("path")] = s.get("sha256")
    for mid, e in st["motions"].items():
        trial = e["source"].get("trial") if e.get("phase", 1) <= S.get("phase", 1) else None
        if trial:
            want[trial["path"]] = trial.get("sha256")                         # B7's wand follows the board's trial (board-data.js)
    for lid, look in st["looks"].items():
        if look.get("phase", 1) <= S.get("phase", 1):
            for lay in look.get("layers", []):
                c = lay.get("cut", {})
                if c.get("path"):
                    want[c["path"] + ("." + c["ext"] if c.get("ext") else "")] = c.get("sha256")
    for rel, sha in sorted(want.items()):
        path = os.path.join(art, rel)
        if not os.path.isfile(path):
            p.append("%s: source file is missing" % rel)
        elif sha256_file(path) != sha:
            p.append("%s: sha256 %s, the catalog says %s" % (rel, sha256_file(path)[:12], str(sha)[:12]))
    if S.get("phase", 1) >= 3:
        # D18's picture is cited by the comparison report (nothing is built from it); the loop below compares the cited sha256 with the file
        rep = load_json(os.path.join(art, "reports", "plush-sunglasses-comparison.json"))
        if rep.get("picture") != V2_PLUSH["D18"][:-4] or rep.get("ext") != "png":
            p.append("reports/plush-sunglasses-comparison.json does not cite %s" % V2_PLUSH["D18"])
        want[V2_PLUSH["D18"]] = rep.get("sha256")
        if not os.path.isfile(os.path.join(art, V2_PLUSH["D18"])) or sha256_file(os.path.join(art, V2_PLUSH["D18"])) != rep.get("sha256"):
            p.append("%s: sha256 differs from the one reports/plush-sunglasses-comparison.json cites" % V2_PLUSH["D18"])
    need = {V2_GIF, V2_CHUNK, V2_POSE_SOURCE} | set(V2_STICKERS.values()) | (set(V2_PLUSH.values()) if S.get("phase", 1) >= 3 else set())
    if S.get("phase", 1) >= 2 and not need <= set(want):
        p.append("sources the phase 2 items cite but the catalog does not: %s" % sorted(need - set(want)))
    for sub in ("dev", "persona", "sticker", "claude-code") + (("plush",) if S.get("phase", 1) >= 3 else ()):
        for n in os.listdir(os.path.join(art, "sources", sub)):
            if "sources/%s/%s" % (sub, n) not in want and S.get("phase", 1) >= 2 and not (S.get("phase", 1) < 4 and "sources/%s/%s" % (sub, n) == V2_BOARD_DATA):
                p.append("sources/%s/%s is in the tree but no catalog entry cites it" % (sub, n))
    p += v2_pose_vocabulary(st)
    return p, "%d phase 2 sources (GIF, sprite chunk, stickers, Claude Code's pose vocabulary) exist, each sha256 equals the catalog's, none is uncited; " \
        "every B item's change is found in the cited lines of render-core.js" % len(want)


def v2_l2_poses():
    st = v2_state()
    art = S["art"]
    p, n, hugged = [], 0, 0
    poses = S["atlas"]["poses"]
    v1 = [(name, k, v1_cells(art, rel)) for name in V1_POSE_NAMES for k, rel in enumerate(poses[name]["frames"])]
    sil = v2_rest_silhouette(st)
    for lid in V2_LOOK_SPEC:
        look = st["looks"].get(lid)
        if look is None or look.get("phase", 1) > S.get("phase", 1):
            continue
        for lay in v2_look_layers(st, lid):
            x0, x1, y0, y1 = V2_BODY_BOX
            sparkle = lay["name"] == "sparkles"
            if sparkle and any(x0 <= dx <= x1 and y0 <= dy <= y1 for (dx, dy) in lay["cells"]):
                p.append("look %s layer %s: a static pixel lies inside the body box (it must lie around the body)" % (lid, lay["name"]))
            if lay["hugs"] == "rest-silhouette" and set(lay["cells"]) & sil:
                p.append("look %s layer %s: a border pixel lies inside the rest silhouette (it shows only outside the body)" % (lid, lay["name"]))
            for name, k, C in v1:
                hx, hy = v1_head(C)
                n += 1
                if sparkle and any(C.get((hx + dx, hy + dy)) is not None for (dx, dy) in lay["cells"]):
                    p.append("look %s: a static pixel lands on a pixel of v1 pose %s frame %d (sparkles stay off the body and the eyes)" % (lid, name, k))
                if lay["hugs"] == "rest-silhouette" and {(q[0] - hx, q[1] - hy) for q, c in C.items() if v2_own(c)} == sil:
                    hugged += 1
                    if any(C.get((hx + dx, hy + dy)) is not None for (dx, dy) in lay["cells"]):
                        p.append("look %s: a border pixel lands on a pixel of v1 pose %s frame %d, whose body is the rest silhouette" % (lid, name, k))
                if lay["attach"] == "arm-right" and sum(1 for x in range(hx + 8, hx + 12) for y in range(hy + 4, hy + 8) if v2_own(C.get((x, y)))) < 4:
                    p.append("look %s: the holding arm is missing in v1 pose %s frame %d" % (lid, name, k))
                if lay["attach"] != "feet" and lay["z"] == "front":
                    # a held prop or a front layer never lands on a pixel of the pose that is not Clawd's own
                    if any(C.get((hx + dx, hy + dy)) is not None and not v2_own(C.get((hx + dx, hy + dy))) for (dx, dy) in lay["cells"]):
                        p.append("look %s: a front layer lands on a foreign pixel in v1 pose %s frame %d" % (lid, name, k))
    return p, ("the phase 2 look layers fit the %d v1 pose frames (static pixels on empty cells outside the body box, holding arm present, no foreign pixel under a front "
               "layer, the border outside the rest silhouette; it hugs the body in %d of the pose frames: the arms of think, hop, sleep and dangle move)" % (len(v1), hugged))


def v2_s1_gif_report():
    st = v2_state()
    art = S["art"]
    p = []
    frames, delays, _ = v2_gif(st)
    rep = load_json(os.path.join(art, "reports", "gif-sampling-report.json"))
    with open(os.path.join(art, V2_GIF), "rb") as f:
        w, h = struct.unpack("<HH", f.read(10)[6:10])
    impure = sum(i for _, i in frames)
    if (rep.get("frames"), rep.get("sizePx"), rep.get("impureCells")) != (len(frames), [w, h], impure):
        p.append("the report says %s, recomputed %d frames, %dx%d px, %d impure cells" % (rep, len(frames), w, h, impure))
    if impure:
        p.append("%d cells are not crisp (a different pixel within 1 px of their centre): the GIF would need another grid" % impure)
    return p, "the GIF's %d frames sample crisply (0 impure cells in the 3 x 3 block around every cell centre), report equals the recomputation" % len(frames)


def v2_g1_goldens():
    root = S.get("goldens")
    if not root or not os.path.isdir(root):
        return ["no goldens directory (pass --goldens DIR; the default art tree uses Tests/Goldens)"], ""
    st = v2_state()
    p, n = [], 0
    for mid in v2_selected(st):
        e = st["motions"][mid]
        if e.get("phase", 1) < 2:
            continue
        for k in range(len(e["frames"])):
            n += 1
            if not os.path.isfile(os.path.join(root, "motions", mid, "%03d.png" % k)):
                p.append("no golden for %s frame %d" % (mid, k))
    names = [("idle", 1), ("blink", 1), ("listen", 2), ("think", 6), ("hop", 4), ("sleep", 1), ("dangle", 2)]
    for lid in V2_LOOK_SPEC:
        look = st["looks"].get(lid)
        if look is None or look.get("phase", 1) > S.get("phase", 1):
            continue
        rels = ["looks/%s/%s_%d.png" % (lid, nm, k) for nm, c in names for k in range(c)]
        rels += ["transition/%s-down/%03d.png" % (lid, k) for k in range(10)] + ["transition/%s-up/%03d.png" % (lid, k) for k in range(10, 20)]
        for rel in rels:
            n += 1
            if not os.path.isfile(os.path.join(root, rel)):
                p.append("no golden %s" % rel)
    return p, "%d golden PNGs of the phase 2 frames, look rest poses and look-change frames exist (the pixel comparison is `swift test --filter Golden`)" % n


def v2_v5_sheet():
    art = S["art"]
    p = []
    names = ["contact-sheet-phase2.png"] + (["contact-sheet-phase3.png"] if S.get("phase", 1) >= 3 else []) + (
        ["contact-sheet-phase4.png"] if S.get("phase", 1) >= 4 else [])
    for name in names:
        try:
            w, h, _ = read_png(os.path.join(art, "preview", "v2", name))
            if w < 200 or h < 200:
                p.append("%s is only %dx%d" % (name, w, h))
        except (OSError, ValueError) as ex:
            p.append("preview/v2/%s: %s" % (name, ex))
    return p, "preview/v2/%s decode" % ", ".join(names)




# D18: the phase 1 sunglasses (cut from A17) against the plushie's photograph, from the pictures alone. The rules are pinned here; reports/plush-sunglasses-comparison.json
# carries the numbers the producer found and this check recomputes them.
V2_D18 = {"blackMax": 60, "mergePx": 2, "barMin": 0.85, "lensMin": 0.15, "colourTolerance": 12, "gapTolerance": 0.1, "widthTolerance": 0.25,
          "headRowsAbove": 12}


def v2_runs(row, merge):
    runs = []
    for x, v in enumerate(row):
        if v:
            if runs and x - runs[-1][1] - 1 <= merge:
                runs[-1][1] = x
            else:
                runs.append([x, x])
    return [tuple(r) for r in runs]


def v2_glasses_structure(mask, merge):
    """Size, the first full-width bar row, the lens rows below it (two runs of at least lensMin of the width) and the narrowest gap between the lenses
    (the bridge over the nose) as a fraction of the width, of a pair of sunglasses given as rows of booleans."""
    rows = [v2_runs(r, merge) for r in mask]
    xs = [x for r in rows for a, b in r for x in (a, b)]
    width = max(xs) - min(xs) + 1
    bar = next((y for y, r in enumerate(rows) if len(r) == 1 and r[0][1] - r[0][0] + 1 >= V2_D18["barMin"] * width), None)
    lens = [r for y, r in enumerate(rows) if bar is not None and y > bar and len(r) == 2 and all(b - a + 1 >= V2_D18["lensMin"] * width for a, b in r)]
    gaps = [r[1][0] - r[0][1] - 1 for r in lens]
    return {"width": width, "height": len(rows), "barRow": bar, "lensRows": len(lens), "bridgeFraction": None if not gaps else round(min(gaps) / width, 3)}


def v2_d18_recompute(st):
    w, h, rows = v2_png(st, V2_PLUSH["D18"])
    cfg = V2_D18
    black = [[rows[y][4 * x + 3] == 255 and max(rows[y][4 * x:4 * x + 3]) < cfg["blackMax"] for x in range(w)] for y in range(h)]
    ys = [y for y in range(h) if any(black[y])]
    xs = [x for x in range(w) if any(black[y][x] for y in range(h))]
    box = (min(xs), min(ys), max(xs), max(ys))
    plush = v2_glasses_structure([r[box[0]:box[2] + 1] for r in black[box[1]:box[3] + 1]], cfg["mergePx"])
    n = sum(1 for y in range(h) for x in range(w) if black[y][x])
    mean = [(sum(rows[y][4 * x + k] for y in range(h) for x in range(w) if black[y][x]) * 2 + n) // (2 * n) for k in range(3)]
    spans = []
    for y in range(box[1] - cfg["headRowsAbove"], box[1]):
        got = [x for x in range(w) if rows[y][4 * x + 3] == 255 and rows[y][4 * x] > 140 and 30 < rows[y][4 * x + 1] < 150 and rows[y][4 * x + 2] < 100
               and rows[y][4 * x] - rows[y][4 * x + 1] > 50]
        if got:
            spans.append(max(got) - min(got) + 1)
    head = max(spans)
    lay = st["looks"]["sunglasses"]["layers"][0]
    cells = png_cells(v2_png(st, lay["png"]), 0, 0)
    x0, x1, y0, y1 = min(c[0] for c in cells), max(c[0] for c in cells), min(c[1] for c in cells), max(c[1] for c in cells)
    pet = v2_glasses_structure([[(x, y) in cells for x in range(x0, x1 + 1)] for y in range(y0, y1 + 1)], 0)
    colours = sorted({tuple(c[:3]) for c in cells.values()})
    ratios = {"plush": round(plush["width"] / head, 3), "pet": round(pet["width"] / 16, 3)}
    ok = (all(abs(mean[k] - PET_EYE[k]) <= cfg["colourTolerance"] for k in range(3)) and colours == [PET_EYE]
          and plush["barRow"] is not None and pet["barRow"] is not None and plush["lensRows"] > 0 and pet["lensRows"] > 0
          and plush["bridgeFraction"] is not None and pet["bridgeFraction"] is not None
          and abs(plush["bridgeFraction"] - pet["bridgeFraction"]) <= cfg["gapTolerance"] and abs(ratios["plush"] - ratios["pet"]) <= cfg["widthTolerance"])
    return {"blackBox": list(box), "blackMean": mean, "headWidthPx": head, "plush": plush, "pet": pet, "ratios": ratios, "ok": ok,
            "heightOverWidth": {"plush": round(plush["height"] / plush["width"], 3), "pet": round(pet["height"] / pet["width"], 3)}}


def v2_d18():
    st = v2_state()
    rep = load_json(os.path.join(S["art"], "reports", "plush-sunglasses-comparison.json"))
    got = v2_d18_recompute(st)
    p = []
    if rep.get("rules") != V2_D18:
        p.append("the report's rules %s are not the pinned ones %s" % (rep.get("rules"), V2_D18))
    if rep.get("sha256") != sha256_file(os.path.join(S["art"], V2_PLUSH["D18"])):
        p.append("the report cites another picture than %s" % V2_PLUSH["D18"])
    want_plush = dict({"blackBox": got["blackBox"], "blackMean": got["blackMean"], "headWidthPx": got["headWidthPx"]}, **got["plush"])
    if rep.get("plush") != want_plush:
        p.append("the report's plush numbers %s differ from the recomputation %s" % (rep.get("plush"), want_plush))
    want_pet = dict({"cells": [got["pet"]["width"], got["pet"]["height"]], "colours": [list(PET_EYE)], "torsoCells": 16}, **got["pet"])
    if rep.get("pet") != want_pet:
        p.append("the report's pet numbers %s differ from the recomputation %s" % (rep.get("pet"), want_pet))
    if rep.get("widthOverHead") != got["ratios"] or rep.get("heightOverWidth") != got["heightOverWidth"]:
        p.append("the report's ratios differ from the recomputation %s %s" % (got["ratios"], got["heightOverWidth"]))
    if not got["ok"] or rep.get("verdict") != "match":
        p.append("the phase 1 sunglasses do not match the plushie's (verdict %r, recomputed %s)" % (rep.get("verdict"), "match" if got["ok"] else "differ"))
    return p, ("the phase 1 sunglasses match plush/sunglasses.png: colour (plush mean %s, pet %s), a bar over two lenses with a bridge (bridge %.3f of the width in the plush, "
               "%.3f in the pet), width over the head %.3f against %.3f; the plush's lenses are %.2f times taller in proportion to their width, which is a proportion of "
               "the toy, and the look is unchanged" % (got["blackMean"], list(PET_EYE), got["plush"]["bridgeFraction"], got["pet"]["bridgeFraction"], got["ratios"]["plush"],
                                                        got["ratios"]["pet"], got["heightOverWidth"]["plush"] / got["heightOverWidth"]["pet"]))


# ---- phase 4: Claude Code's own motions (R5), the Ultra pose, the looks Ultra and winter (Sprint 8) -------------------------------------
# The C motions are TRANSCRIBED: each frame equals what render-core.js (the board's copy of Claude Code 2.1.301's data and of its pet-grid mapping,
# pixelParamsFor and pixelFrameSVG) gives for that frame of that sequence. The data is read out of render-core.js by a small JavaScript parser of
# this file's own (no eval, no node), and drawn by code of this file's own; Tests/art/cc-render-vs-node.test.sh runs the real render-core.js in node
# and requires its pixelFrameSVG output to equal these pixels.
# spec 3.2 C items: id -> (board, key of Ho in render-core.js, declared uses, frames = the spec's seconds / 0.06)
V2_C_ITEMS = {
    "C1-jump": ("C1", "jump", ["sent", "touch"], 12),
    "C2-celebrate": ("C2", "celebrate", ["sent"], 15),
    "C3-skip": ("C3", "skip", ["entrance"], 14),
    "C4-look": ("C4", "look", ["listening", "idle"], 11),
    "C5-spin": ("C5", "spin", ["touch"], 10),
    "C6-peekaboo": ("C6", "peekaboo", ["entrance"], 21),
    "C7-drop": ("C7", "drop", ["entrance", "drop"], 13),
    "C8-waddle": ("C8", "waddle", ["entrance"], 19),
    "C9-peek": ("C9", "peek", ["entrance"], 20),
    "C10-wink": ("C10", "wink", ["touch"], 6),
    "C11-boop": ("C11", "boop", ["touch", "interrupted"], 11),
    "C12-tap": ("C12", "tap", ["touch"], 14),
    "C13-sneeze": ("C13", "sneeze", ["idle"], 12),
}
V2_C_BOARDS = {v[0] for v in V2_C_ITEMS.values()}
V2_C_LINES = ["3", "5", "106-125", "139-165"]
V2_C_MS = 60
# The upstream file the C motions are transcribed from, pinned (spec 9b item 13, Codex on Sprint 8). The catalog's sha256 fields, the provenance
# checks and R5's own parser all read the vendored copy, so an edited copy with every recorded hash rewritten would agree with itself and pass.
# The pin lives here; it moves only by a reviewed edit of this line.
V2_RENDER_CORE_SHA256 = "a568a16464f394a52eeaffb6a7e429116f1e73fa0231529b9f29083a90720644"
V2_BOARD_DATA = "sources/claude-code/board-data.js"
V2_B7 = "B7-ultra-wand"
V2_B7_LINES = ["3", "9", "13-14", "107-125", "139-152"]
V2_B7_SHAPE = ([3, 18, 3], {"wood": [(12, 5), (13, 4), (14, 3)], "gold": [(14, 0), (13, 1), (14, 1), (15, 1), (14, 2)]})
V2_CC_HELPERS = [
    'function _r(){return[{pose:"default",offset:1,poof:"dot"},{pose:"default",offset:1,poof:"wave"}]}',
    'function xe(u,d,{offset:m=0,x:p,poof:h,shadow:v}={}){return Array.from({length:d},()=>({pose:u,offset:m,x:p,poof:h,shadow:v}))}',
    'function kr(u,d){return u.flatMap((m)=>xe({facing:m},1,{shadow:d}))}',
    'function uo(u,d="down",m="both"){return{eyes:u,arms:d,feet:m}}',
]
V2_PHASE4_ITEMS = dict({mid: ("redrawn", v[0], v[2]) for mid, v in V2_C_ITEMS.items()}, **{V2_B7: ("redrawn", "B7", ["signature:ultra"])})
# a body-colour look's shade colours: the body colour scaled by the pet's own shade-to-body ratio per channel, rounded half up
V2_SHADE_FROM = ((215, 119, 87), (190, 104, 77))
CC_TOKEN = re.compile(r'\s*(?:(\d+)|("(?:[^"\\]|\\.)*")|([A-Za-z_$][\w$]*)|(\.\.\.|===|=>|\?\.|\?\?|[()\[\]{},:;=?.%+\-!*/]))')


def cc_tokens(text):
    out, pos = [], 0
    while pos < len(text):
        if not text[pos:].strip():
            break
        m = CC_TOKEN.match(text, pos)
        if not m:
            raise ValueError("render-core.js: cannot read %r" % text[pos:pos + 24])
        pos = m.end()
        if m.group(1) is not None:
            out.append(("num", int(m.group(1))))
        elif m.group(2) is not None:
            out.append(("str", json.loads(m.group(2))))
        elif m.group(3) is not None:
            out.append(("id", m.group(3)))
        else:
            out.append(("p", m.group(4)))
    return out


class CCParser:
    """Expressions of the JavaScript subset render-core.js lines 3 and 5 use, as nested tuples: numbers, strings, identifiers, arrays with spread, objects,
    calls, member access (also `?.`), `[i]`, `%`, `===`, `??`, unary - and !, the conditional and arrow functions."""

    def __init__(self, toks):
        self.t, self.i = toks, 0

    def peek(self, k=0):
        return self.t[self.i + k] if self.i + k < len(self.t) else ("eof", None)

    def eat(self, val=None):
        tok = self.peek()
        if tok[0] == "eof" or (val is not None and tok != ("p", val)):
            raise ValueError("render-core.js: expected %r, found %r" % (val, tok))
        self.i += 1
        return tok

    def expr(self):
        c = self.nullish()
        if self.peek() == ("p", "?"):
            self.eat("?")
            a = self.expr()
            self.eat(":")
            return ("cond", c, a, self.expr())
        return c

    def nullish(self):
        a = self.equality()
        while self.peek() == ("p", "??"):
            self.eat()
            a = ("bin", "??", a, self.equality())
        return a

    def equality(self):
        a = self.additive()
        while self.peek() == ("p", "==="):
            self.eat()
            a = ("bin", "===", a, self.additive())
        return a

    def additive(self):
        a = self.multiplicative()
        while self.peek() in (("p", "+"), ("p", "-")):
            op = self.eat()[1]
            a = ("bin", op, a, self.multiplicative())
        return a

    def multiplicative(self):
        a = self.unary()
        while self.peek() in (("p", "%"), ("p", "*"), ("p", "/")):
            op = self.eat()[1]
            a = ("bin", op, a, self.unary())
        return a

    def unary(self):
        if self.peek() in (("p", "-"), ("p", "!")):
            op = self.eat()[1]
            return ("un", op, self.unary())
        return self.postfix(self.primary())

    def postfix(self, a):
        while True:
            tok = self.peek()
            if tok == ("p", "("):
                self.eat()
                args = []
                while self.peek() != ("p", ")"):
                    args.append(self.spread_or_expr())
                    if self.peek() == ("p", ","):
                        self.eat()
                self.eat(")")
                a = ("call", a, args)
            elif tok in (("p", "."), ("p", "?.")):
                self.eat()
                a = ("member", a, self.eat_id(), tok[1] == "?.")
            elif tok == ("p", "["):
                self.eat()
                idx = self.expr()
                self.eat("]")
                a = ("index", a, idx)
            else:
                return a

    def eat_id(self):
        tok = self.eat()
        if tok[0] != "id":
            raise ValueError("render-core.js: expected a name, found %r" % (tok,))
        return tok[1]

    def spread_or_expr(self):
        if self.peek() == ("p", "..."):
            self.eat()
            return ("spread", self.expr())
        return self.expr()

    def arrow_ahead(self):
        depth, k = 0, 0
        while True:
            tok = self.peek(k)
            if tok == ("p", "("):
                depth += 1
            elif tok == ("p", ")"):
                depth -= 1
                if depth == 0:
                    return self.peek(k + 1) == ("p", "=>")
            elif tok[0] == "eof":
                return False
            k += 1

    def primary(self):
        tok = self.peek()
        if tok[0] in ("num", "str"):
            self.eat()
            return (tok[0], tok[1])
        if tok[0] == "id":
            self.eat()
            return ("id", tok[1])
        if tok == ("p", "("):
            if self.arrow_ahead():
                self.eat("(")
                params = []
                while self.peek() != ("p", ")"):
                    params.append(self.eat_id())
                    if self.peek() == ("p", ","):
                        self.eat()
                self.eat(")")
                self.eat("=>")
                return ("arrow", params, self.expr())
            self.eat("(")
            a = self.expr()
            self.eat(")")
            return a
        if tok == ("p", "["):
            self.eat()
            items = []
            while self.peek() != ("p", "]"):
                items.append(self.spread_or_expr())
                if self.peek() == ("p", ","):
                    self.eat()
            self.eat("]")
            return ("arr", items)
        if tok == ("p", "{"):
            self.eat()
            pairs = []
            while self.peek() != ("p", "}"):
                key = self.eat()
                if key[0] not in ("id", "str"):
                    raise ValueError("render-core.js: object key %r" % (key,))
                self.eat(":")
                pairs.append((key[1], self.expr()))
                if self.peek() == ("p", ","):
                    self.eat()
            self.eat("}")
            return ("obj", pairs)
        raise ValueError("render-core.js: unexpected %r" % (tok,))


def cc_apply(fn, args):
    return fn(*args)


def cc_eval(node, env):
    kind = node[0]
    if kind in ("num", "str"):
        return node[1]
    if kind == "id":
        if node[1] not in env:
            raise ValueError("render-core.js: %s is not defined" % node[1])
        return env[node[1]]
    if kind == "arr":
        out = []
        for item in node[1]:
            if item[0] == "spread":
                out.extend(cc_eval(item[1], env))
            else:
                out.append(cc_eval(item, env))
        return out
    if kind == "obj":
        return {k: cc_eval(v, env) for k, v in node[1]}
    if kind == "un":
        v = cc_eval(node[2], env)
        return -v if node[1] == "-" else (not v)
    if kind == "bin":
        a, b = cc_eval(node[2], env), cc_eval(node[3], env)
        return {"%": lambda: a % b, "===": lambda: a == b, "??": lambda: a if a is not None else b, "+": lambda: a + b, "-": lambda: a - b,
                "*": lambda: a * b, "/": lambda: a / b}[node[1]]()
    if kind == "cond":
        return cc_eval(node[2], env) if cc_eval(node[1], env) else cc_eval(node[3], env)
    if kind == "arrow":
        params, body = node[1], node[2]
        return lambda *args: cc_eval(body, dict(env, **dict(zip(params, args))))
    if kind == "member":
        base = cc_eval(node[1], env)
        if base is None:
            if node[3]:
                return None
            raise ValueError("render-core.js: .%s of nothing" % node[2])
        if isinstance(base, dict):
            return base.get(node[2])
        if isinstance(base, list) and node[2] in ("flatMap", "map", "filter"):
            return {"flatMap": lambda fn: [y for x in base for y in fn(x)], "map": lambda fn: [fn(x) for x in base],
                    "filter": lambda fn: [x for x in base if fn(x)]}[node[2]]
        raise ValueError("render-core.js: .%s is not supported" % node[2])
    if kind == "index":
        base, idx = cc_eval(node[1], env), cc_eval(node[2], env)
        return base[idx]
    if kind == "call":
        fn = cc_eval(node[1], env)
        args = []
        for a in node[2]:
            args.extend(cc_eval(a[1], env) if a[0] == "spread" else [cc_eval(a, env)])
        return fn(*args)
    raise ValueError("render-core.js: cannot evaluate %r" % (node,))


def cc_skip_balanced(toks, i):
    """Index after the bracketed group that starts at toks[i]."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = [pairs[toks[i][1]]]
    i += 1
    while stack:
        tok = toks[i]
        if tok[0] == "p" and tok[1] in pairs:
            stack.append(pairs[tok[1]])
        elif tok[0] == "p" and tok[1] == stack[-1]:
            stack.pop()
        i += 1
    return i


def cc_declarations(toks, wanted, env):
    """Evaluate the `var` declarators of a token list whose names are in `wanted` (in order; the others are skipped without being read) into env; the
    `function` statements in between are skipped."""
    i = 0
    while i < len(toks):
        tok = toks[i]
        if tok == ("id", "function"):
            i += 2
            i = cc_skip_balanced(toks, i)
            i = cc_skip_balanced(toks, i)
        elif tok == ("id", "var") or tok == ("p", ","):
            i += 1
            name = toks[i][1]
            i += 2                                  # the name and `=`
            if name in wanted:
                parser = CCParser(toks[i:])
                node = parser.expr()
                env[name] = cc_eval(node, env)
                i += parser.i
            else:
                depth = 0
                while i < len(toks):
                    t = toks[i]
                    if t[0] == "p" and t[1] in "([{":
                        depth += 1
                    elif t[0] == "p" and t[1] in ")]}":
                        depth -= 1
                    elif depth == 0 and (t == ("p", ",") or t == ("p", ";") or t == ("id", "function") or t == ("id", "var")):
                        break
                    i += 1
        elif tok == ("p", ";"):
            i += 1
        else:
            raise ValueError("render-core.js: unexpected %r at the top level" % (tok,))


def cc_data(lines):
    """(poses jo, sequences Ho, ms per frame Wi) read from lines 3 and 5 of render-core.js. The four helper functions of line 5 are implemented here and
    their text must be exactly the one below, else the data is refused."""
    for h in V2_CC_HELPERS:
        if h not in lines[4]:
            raise ValueError("render-core.js line 5 no longer defines %s" % h.split("{")[0])

    def xe(u, d, o=None):
        o = o or {}
        return [{"pose": u, "offset": o.get("offset", 0), "x": o.get("x"), "poof": o.get("poof"), "shadow": o.get("shadow")} for _ in range(d)]

    env = {"xe": xe, "_r": lambda: [{"pose": "default", "offset": 1, "x": None, "poof": "dot", "shadow": None},
                                      {"pose": "default", "offset": 1, "x": None, "poof": "wave", "shadow": None}],
           "kr": lambda u, d=None: [f for m in u for f in xe({"facing": m}, 1, {"shadow": d})],
           "uo": lambda u, d="down", m="both": {"eyes": u, "arms": d, "feet": m}}
    cc_declarations(cc_tokens(lines[2]), {"jo"}, env)
    cc_declarations(cc_tokens(lines[4]), {"ao", "io", "Wi", "Oo", "jg", "HT", "gu", "VT", "WT", "jT", "Rs", "$T", "GT", "zT", "KT", "qT", "YT", "XT", "JT", "QT",
                                          "ZT", "Ho"}, env)
    ho = {k: [{"pose": f["pose"], "offset": f.get("offset", 0), "x": f.get("x"), "poof": f.get("poof"), "shadow": f.get("shadow")} for f in seq]
          for k, seq in env["Ho"].items()}
    return env["jo"], ho, env["Wi"]


def cc_round(v):
    """Math.round: halves round up (exact arithmetic)."""
    from fractions import Fraction
    return int(math.floor(Fraction(v) + Fraction(1, 2)))


def cc_units(pose, jo):
    """The unit grid {(x, y): 'b' or 'e'} of pixelGrid for a pose (or None for a side or back view), drawn as filled rectangles."""
    f = jo[pose] if isinstance(pose, str) else pose
    if "facing" in f:
        return None
    dx = {"left": -1, "right": 1}.get(f["eyes"], 0)
    arm_l = -1 if f["arms"] == "up" else 0
    arm_r = -1 if f["arms"] in ("up", "one-up") else 0
    legs = {"left": (2, 2, 1, 1), "right": (1, 1, 2, 2)}.get(f["feet"], (2, 2, 2, 2))
    g = {}

    def fill(x0, y0, w, h, c):
        for x in range(x0, x0 + w):
            for y in range(y0, y0 + h):
                if 0 <= x < 12 and 0 <= y < 12:
                    g[(x, y)] = c
    fill(2, 4, 8, 6, "b")
    fill(0, 6 + arm_l, 2, 2, "b")
    fill(10, 6 + arm_r, 2, 2, "b")
    for lx, n in zip((2, 4, 7, 9), legs):
        fill(lx, 10, 1, n, "b")
    for x in {"open": (3, 8), "closed": (3, 4, 7, 8), "wink": (3, 7, 8)}["open" if f["eyes"] in ("left", "right") else f["eyes"]]:
        fill(x + dx, 5, 1, 1, "e")
    return g


def cc_frame_cells(frame, jo):
    """The canvas cells of one entrance-motion frame as pixelFrameSVG draws it: Clawd moved by round(offset * 8/3) units down and round(x * 12/9) across,
    cut to rows 4..11 and columns 0..11, the dust glyph on top; one unit is 2 x 2 cells. None for a side or back view."""
    from fractions import Fraction
    g = cc_units(frame["pose"], jo)
    if g is None:
        return None
    mx = cc_round(Fraction(frame["x"] or 0) * 12 / 9)
    my = cc_round(Fraction(frame["offset"] or 0) * 8 / 3)
    units = {(x + mx, y + my): V2_PET_BODY if c == "b" else PET_EYE for (x, y), c in g.items() if 0 <= x + mx < 12 and 4 <= y + my < 12}
    if frame["poof"] and (frame["offset"] or 0) > 0:
        for q in ([(0, 11), (11, 11)] if frame["poof"] == "dot" else [(0, 10), (1, 11), (10, 11), (11, 10)]):
            units[q] = (153, 153, 153)
    return {(2 * x + a, 2 * y + b): c + (255,) for (x, y), c in units.items() for a in (0, 1) for b in (0, 1)}


def cc_boards(sequence, jo):
    """The board ids of the poses a sequence uses: B2 arms up, B3 eyes left or right, B4 wink or closed, B5 one foot up."""
    out = set()
    for f in sequence:
        p = jo[f["pose"]] if isinstance(f["pose"], str) else f["pose"]
        if p["arms"] == "up":
            out.add("B2")
        if p["eyes"] in ("left", "right"):
            out.add("B3")
        if p["eyes"] in ("wink", "closed"):
            out.add("B4")
        if p["feet"] in ("left", "right"):
            out.add("B5")
    return sorted(out)


def cc_colours(lines):
    """wood, gold, ultraDark (lines 13-14), dust (line 106) and the winter palette (line 171) of render-core.js as rgb tuples."""
    def rgb(pattern, text):
        m = re.search(pattern + r'\s*=?:?\s*"rgb\((\d+),(\d+),(\d+)\)"', text)
        if not m:
            raise ValueError("render-core.js: no %s" % pattern)
        return tuple(int(v) for v in m.groups())
    return {"wood": rgb("wood", lines[13]), "gold": rgb("gold", lines[13]), "ultraDark": rgb("ultraDark", lines[12]), "dust": rgb("dust", lines[105]),
            "T": rgb(r"\bT", lines[170]), "I": rgb(r"\bI", lines[170]), "K": rgb(r"\bK", lines[170])}


def cc_eye_changes(sequence, jo):
    """The eye poses of a sequence as the calm B3 and B4 items name them (K1: a motion whose point is its eyes keeps front layers off the eyes)."""
    out = set()
    for f in sequence:
        p = jo[f["pose"]] if isinstance(f["pose"], str) else f["pose"]
        if p["eyes"] != "open":
            out.add({"left": "eyes:look-left", "right": "eyes:look-right", "wink": "eyes:wink", "closed": "eyes:closed"}[p["eyes"]])
    return sorted(out)


def v2_pose_frames_of_b_items(st):
    """{frame cells: board item} for the frames of the calm B3/B4/B5 motions, to find the same pose in a C frame."""
    out = {}
    for mid in ("B3-glance-left", "B3-glance-right", "B4-wink", "B4-slow-blink", "B5-foot-tap"):
        e = st["motions"].get(mid)
        if e is None:
            continue
        for k in range(len(e["frames"])):
            out.setdefault(frozenset(v2_frame_cells(st, e, k).items()), mid)
    return out


def v2_r5():
    st = v2_state()
    path = os.path.join(S["art"], V2_POSE_SOURCE)
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    jo, ho, ms = cc_data(lines)
    sha = sha256_file(path)
    p, n, frames_n, reused = [], 0, 0, 0
    if sha != V2_RENDER_CORE_SHA256:
        p.append("%s has sha256 %s, the checker pins the upstream file at %s: the C motions are transcribed from that file only" % (V2_POSE_SOURCE, sha, V2_RENDER_CORE_SHA256))
    if ms != V2_C_MS:
        p.append("render-core.js gives %r ms per frame, the spec says %d" % (ms, V2_C_MS))
    b_frames = v2_pose_frames_of_b_items(st)
    for mid in v2_selected(st):
        if mid not in V2_C_ITEMS:
            continue
        e = st["motions"][mid]
        board, key, uses, count = V2_C_ITEMS[mid]
        n += 1
        seq = ho[key]
        want_source = {"kind": "redrawn", "path": V2_POSE_SOURCE, "sha256": sha, "board": board, "lines": V2_C_LINES, "sequence": key}
        if e["source"] != want_source or e.get("board") != board:
            p.append("%s: source %s, want %s (spec 3.2: render-core.js, the sequence %s)" % (mid, e["source"], want_source, key))
        if len(seq) != count or len(e["frames"]) != count:
            p.append("%s: %d frames in the catalog, the sequence %s has %d and the spec's duration gives %d" % (mid, len(e["frames"]), key, len(seq), count))
            continue
        if e["ms"] != [V2_C_MS] * count or e["srcFrames"] != list(range(count)) or any(e["stage"][k] != 0 for k in e["stage"]):
            p.append("%s: ms, srcFrames or stage are not 60 ms per frame, frames 0..%d and no stage (every frame lies inside the canvas)" % (mid, count - 1))
        for k, frame in enumerate(seq):
            frames_n += 1
            want = cc_frame_cells(frame, jo)
            got = v2_frame_cells(st, e, k)
            if want is None:
                p.append("%s frame %d is a side or back view: the pet does not draw it (spec 3.5)" % (mid, k))
                break
            if got != want:
                diff = sorted(set(got) ^ set(want)) or sorted(c for c in got if got[c] != want[c])
                p.append("%s frame %d (%s, offset %s, x %s, poof %s) differs from render-core.js's pixelFrameSVG at cell %s" % (
                    mid, k, frame["pose"] if isinstance(frame["pose"], str) else frame["pose"], frame["offset"], frame["x"], frame["poof"], diff[0]))
                break
            pose = jo[frame["pose"]] if isinstance(frame["pose"], str) else frame["pose"]
            plain = not (frame["offset"] or frame["x"] or frame["poof"])
            calm = plain and pose["arms"] == "down" and ((pose["eyes"] != "open" and pose["feet"] == "both") or (pose["eyes"] == "open" and pose["feet"] == "right"))
            if calm:
                if frozenset(got.items()) in b_frames:
                    reused += 1
                else:
                    p.append("%s frame %d is the pose %s with nothing else, which the calm B3, B4 or B5 motions draw; it is not their pixels" % (mid, k, pose))
                    break
        redraw = {"base": "render-core.js pixelFrameSVG", "changes": cc_eye_changes(seq, jo), "poses": cc_boards(seq, jo),
                  "effectColors": [[153, 153, 153]] if any(f["poof"] and (f["offset"] or 0) > 0 for f in seq) else []}
        if e.get("redraw") != redraw:
            p.append("%s: redraw %s, want %s" % (mid, e.get("redraw"), redraw))
    return p, ("%d C motions, %d frames: every frame equals the pixelFrameSVG of its frame of render-core.js's sequence (offsets 8/3 units per row and 12/9 per column, "
               "clipped to the canvas as the board clips it), 60 ms per frame, the spec's frame counts; %d frames of a plain B3, B4 or B5 pose are those motions' pixels" % (n, frames_n, reused))


def v2_r5_node():
    """The real render-core.js, run in node, against the shipped C frames (Tests/art/cc_render_vs_node.py: the last shared assumption of R5, because the
    checker and the port script each evaluate the file with code of their own). Skipped when no C motion is selected. When node is not available the
    check is NOT RUN (the test script exits 3), which is never a pass."""
    st = v2_state()
    if not any(mid in V2_C_ITEMS for mid in v2_selected(st)):
        return [], "no C motion is selected"
    script = os.path.join(ROOT, "Tests", "art", "cc_render_vs_node.py")
    if not os.path.isfile(script):
        return ["%s is missing" % os.path.relpath(script, ROOT)], ""
    r = subprocess.run([sys.executable, "-I", script], capture_output=True, text=True, cwd=ROOT, timeout=300, env=dict(os.environ, CLAWD_ART_DIR=S["art"]))
    if r.returncode == 3:
        return None, "node is not available, so the C frames were not compared with the real render-core.js"
    fails = [ln for ln in r.stdout.splitlines() if ln.startswith("FAIL ")]
    summary = [ln for ln in r.stdout.splitlines() if ln.startswith("cc-render-vs-node:")]
    if r.returncode != 0 or fails or not summary:
        return (fails[:4] or ["Tests/art/cc_render_vs_node.py exited %d: %s" % (r.returncode, (r.stdout + r.stderr).strip()[-200:])]), ""
    return [], "run in node: %s" % summary[-1]


def v2_b7():
    """The Ultra pose B7-ultra-wand: three rest frames, 18 frames of the right arm one unit up (render-core.js's `one-up`, `armR = -1`) holding the wand, three
    rest frames. The wand is the board's trial for the Ultra card (board-data.js) with its star one unit nearer, the colours wood and gold of render-core.js."""
    st = v2_state()
    art = S["art"]
    p = []
    e = st["motions"].get(V2_B7)
    if e is None:
        return ["%s is missing" % V2_B7], ""
    with open(os.path.join(art, V2_POSE_SOURCE), encoding="utf-8") as f:
        lines = f.read().split("\n")
    col = cc_colours(lines)
    data_path = os.path.join(art, V2_BOARD_DATA)
    with open(data_path, encoding="utf-8") as f:
        data = f.read()
    # the trial, parsed from the card of board-data.js
    card = data[data.index('ja: "Ultra'):]
    card = card[:card.index("src: [")]
    m = re.search(r"extra: function \(put, bt\) \{(.*?)\} \}", card, re.S)
    trial = {"w": int(re.search(r"\bw: (\d+)", card).group(1)), "armR": int(re.search(r"armR: (-?\d+)", card).group(1)),
             "body": re.search(r'body: "rgb\((\d+),(\d+),(\d+)\)"', card).groups()}
    body = m.group(1)

    def unit_y(expr):
        m2 = re.fullmatch(r"bt(?: ([+-]) (\d+))?", expr)
        return 4 + (0 if m2.group(1) is None else (int(m2.group(2)) if m2.group(1) == "+" else -int(m2.group(2))))
    wood = [(int(a), unit_y(b)) for a, b in re.findall(r"put\((\d+), (bt(?: [+-] \d+)?), wd\)", body)]
    gold = [(int(a), unit_y(b)) for a, b in re.findall(r"\[(\d+), (bt(?: [+-] \d+)?)\]", body)]
    if (trial["w"], trial["armR"], tuple(int(v) for v in trial["body"])) != (17, -1, col["ultraDark"]) or "wd = \"rgb(%d,%d,%d)\"" % col["wood"] not in body or (
            "gd = \"rgb(%d,%d,%d)\"" % col["gold"] not in body):
        p.append("board-data.js: the Ultra card's trial is not a 17-wide grid with one arm up, the body %s and the wood and gold of render-core.js" % (col["ultraDark"],))
    want_wood = sorted(wood)
    want_gold = sorted((x - 1, y) for x, y in gold)
    if sorted(V2_B7_SHAPE[1]["wood"]) != want_wood or sorted(V2_B7_SHAPE[1]["gold"]) != want_gold:
        p.append("the pinned wand %s is not the board's trial (wood %s, gold %s) with the star one unit nearer" % (V2_B7_SHAPE[1], wood, gold))
    rest = st["rest"]

    def units(us, c):
        return {(2 * x + a, 2 * y + b): c + (255,) for x, y in us for a in (0, 1) for b in (0, 1)}
    lifted = v2_arm_variant(set(rest), "arm-right:lifted")
    pose = {q: rest.get(q, (215, 119, 87, 255)) for q in lifted}
    pose.update(units(V2_B7_SHAPE[1]["wood"], col["wood"]))
    pose.update(units(V2_B7_SHAPE[1]["gold"], col["gold"]))
    want = [rest] * V2_B7_SHAPE[0][0] + [pose] * V2_B7_SHAPE[0][1] + [rest] * V2_B7_SHAPE[0][2]
    got = v2_cdicts(st, V2_B7, e)
    if len(got) != len(want) or any(g != w for g, w in zip(got, want)):
        bad = next((k for k, (g, w) in enumerate(zip(got, want)) if g != w), len(got))
        p.append("%s: frame %d is not the rest frame or the pose (the arm one unit up, the wood and gold wand, %d frames in all)" % (V2_B7, bad, len(want)))
    s = e["source"]
    want_source = {"kind": "redrawn", "path": V2_POSE_SOURCE, "sha256": sha256_file(os.path.join(art, V2_POSE_SOURCE)), "board": "B7", "lines": V2_B7_LINES,
                   "trial": {"path": V2_BOARD_DATA, "sha256": sha256_file(data_path), "card": "ultracode header: arms one-up"}}
    if s != want_source:
        p.append("%s: source %s, want %s" % (V2_B7, s, want_source))
    redraw = e.get("redraw", {})
    if redraw.get("changes") != ["arm-right:lifted"] or sorted(map(tuple, redraw.get("effectColors", []))) != sorted([col["wood"], col["gold"]]):
        p.append("%s: redraw %s" % (V2_B7, redraw))
    wand = redraw.get("wand", {})
    if (wand.get("wood"), wand.get("gold")) != ([list(q) for q in V2_B7_SHAPE[1]["wood"]], [list(q) for q in V2_B7_SHAPE[1]["gold"]]):
        p.append("%s: redraw.wand %s differs from the pinned wand" % (V2_B7, wand))
    return p, ("B7-ultra-wand: %d frames, the arm one unit up with the wood wand (%s) and the gold star (%s), the wand the board's trial with the star one unit nearer, "
               "colours from render-core.js" % (len(want), V2_B7_SHAPE[1]["wood"], V2_B7_SHAPE[1]["gold"]))


def v2_shade_of(body):
    return tuple((body[k] * V2_SHADE_FROM[1][k] * 2 + V2_SHADE_FROM[0][k]) // (V2_SHADE_FROM[0][k] * 2) for k in range(3))


def v2_snow_expected(lines):
    """(flakes [(row, column)], the body's first and last column, {(dx, dy): white}) of the winter rows of render-core.js:170-177, drawn by the mapping
    1 column = 12/9 units, 1 row = 8/3 units, the body's first column at unit 0, the torso's top row at unit 4; a flake is the unit (2 x 2 cells) whose
    centre is nearest the centre of its terminal cell."""
    from fractions import Fraction
    col = cc_colours(lines)
    env = {"T": "T", "I": "I", "K": "K"}
    rows = cc_eval(CCParser(cc_tokens("[" + "\n".join(lines[172:175]) + "]")).expr(), env)
    flakes, body_cols = [], []
    for r, runs in enumerate(rows):
        c = 0
        for run in runs:
            for ch in run[0]:
                if ch == "*":
                    flakes.append((r, c))
                elif ch != " " and run[1] == "I":
                    body_cols.append(c)
                c += 1
    left, right = min(body_cols), max(body_cols)
    cells = {}
    for r, c in flakes:
        cx = (Fraction(c - left) + Fraction(1, 2)) * 12 / 9
        cy = 4 + (Fraction(r) + Fraction(1, 2)) * 8 / 3
        x0, y0 = cc_round(2 * cx) - 1, cc_round(2 * cy) - 1
        for a in (0, 1):
            for b in (0, 1):
                cells[(x0 + a - 12, y0 + b - 8)] = col["T"] + (255,)
    return flakes, (left, right), cells


def v2_check_snow(st, look, lay):
    """Winter's snow layer against render-core.js:170-177. Returns the problems."""
    p = []
    art = S["art"]
    with open(os.path.join(art, V2_POSE_SOURCE), encoding="utf-8") as f:
        lines = f.read().split("\n")
    flakes, (left, right), want = v2_snow_expected(lines)
    if right - left + 1 != 9:
        p.append("the winter body is %d columns wide in render-core.js, the pet mapping needs 9" % (right - left + 1))
    cut = lay.get("cut", {})
    want_cut = {"kind": "snow", "path": V2_POSE_SOURCE[:-3], "ext": "js", "sha256": sha256_file(os.path.join(art, V2_POSE_SOURCE)), "lines": "170-177",
                "flakes": [list(q) for q in flakes], "colour": list(cc_colours(lines)["T"]),
                "scale": {"unitsPerColumn": "12/9", "unitsPerRow": "8/3", "torsoTopUnit": 4, "unit": "2 x 2 cells"}}
    if cut != want_cut:
        p.append("look winter layer snow: the cut %s is not %s" % (cut, want_cut))
    x0, y0 = min(c[0] for c in want), min(c[1] for c in want)
    x1, y1 = max(c[0] for c in want), max(c[1] for c in want)
    if lay["offset"] != [x0, y0] or lay["size"] != [x1 - x0 + 1, y1 - y0 + 1]:
        p.append("look winter layer snow: offset/size %s/%s, the rows give %s/%s" % (lay["offset"], lay["size"], [x0, y0], [x1 - x0 + 1, y1 - y0 + 1]))
    got = png_cells(v2_png(st, lay["png"]), -x0, -y0)
    if got != want:
        p.append("look winter layer snow: the PNG differs from the flakes of the 2.0.67 rows (%d cells shipped, %d derived)" % (len(got), len(want)))
    inside = set(want) & v2_rest_silhouette(st)
    if inside:
        p.append("look winter layer snow: %d snow cells lie on the rest silhouette" % len(inside))
    return p


def v2_body_map_problems(lid, look, lines):
    """The bodyColor map of Ultra or winter against the spec's colour, render-core.js and the shade rule."""
    col = cc_colours(lines)
    body = {"ultra": col["ultraDark"], "winter": col["I"]}[lid]
    key = {"ultra": "CC_COLORS.ultraDark", "winter": "WINTER_ROWS.I"}[lid]
    p = []
    if body != V2_BODY_COLOUR[lid]:
        p.append("render-core.js gives the %s body %s, the spec declares %s" % (lid, body, V2_BODY_COLOUR[lid]))
    shade = v2_shade_of(V2_BODY_COLOUR[lid])
    want = [{"from": list(V2_BODY_FROM[0]), "to": list(V2_BODY_COLOUR[lid])}, {"from": list(V2_BODY_FROM[1]), "to": list(shade)},
            {"from": list(V2_BODY_FROM[2]), "to": list(shade)}]
    block = look.get("bodyColor", {})
    if block.get("map") != want:
        p.append("look %s: bodyColor map %s, want %s (the body colour, and its shade by the pet's own shade-to-body ratio)" % (lid, block.get("map"), want))
    src = dict(block.get("source", {}))
    want_src = {"path": V2_POSE_SOURCE[:-3], "ext": "js", "sha256": sha256_file(os.path.join(S["art"], V2_POSE_SOURCE)), "key": key}
    if lid == "ultra":
        want_src["binaryOffset"] = 199297306
    if src != want_src or set(block) != {"map", "source"}:
        p.append("look %s: bodyColor source %s, want %s" % (lid, src, want_src))
    return p


def v2_ultra_binary():
    """Spec 3.3 cites Claude Code's binary for Ultra: its colour at 199297306, its pose at 224834737, its wand glyphs at 195776098."""
    b = binary()
    p = []
    for off, needle in ((199297306, 'effortUltra:"rgb(175,135,255)"'), (224834737, 'arms:"one-up"'), (195776098, 'SNo="\\u2726"'), (195776098, 'bNo="\\u2571"')):
        window = bytes(b.m[off - 80:off + 160])
        if needle.encode("utf-8") not in window:
            p.append("the binary has no %s near offset %d" % (needle, off))
    return p


def v2_recolour_safe():
    """A bodyColor map substitutes colours exactly, on every pixel of a frame. It is safe when only Clawd has those colours: in every Lottie source, the only
    layers that carry Clawd's body or shade colour (after the colour map) are `orange` and `dark_orange`; no redrawn motion has an effect colour that is one
    of them; the persona GIF's palette holds them for Clawd alone (its props have other colours)."""
    st = v2_state()
    p, n = [], 0
    from_set = set(V2_BODY_FROM)
    for mid in v2_selected(st):
        e = st["motions"][mid]
        kind = v2_kind(e)
        n += 1
        if kind == "lottie":
            cm = v2_cmap(e)
            for r in v2_lottie(st, e)[1]:
                c = cm.get(r[7], r[7])
                if c in from_set and r[2] not in ("orange", "dark_orange"):
                    p.append("%s: the layer %s has the colour %s that a body-colour look recolours" % (mid, r[2], c))
                    break
        elif kind == "redrawn":
            eff = {tuple(c) for c in e.get("redraw", {}).get("effectColors", [])}
            if eff & from_set:
                p.append("%s: effect colours %s include a colour a body-colour look recolours" % (mid, sorted(eff & from_set)))
        elif kind == "sprite":
            v2_sprite_frame(st, V2_RIDE_SPRITE, 0, V2_SKATE_MAP)
            extra = ({V2_SKATE_MAP.get(c, c) for c in st["sprites"][V2_RIDE_SPRITE]["palette"]} & from_set) - {V2_PET_BODY, V2_SPRITE_SHADE}
            if extra:
                p.append("%s: the sprite palette has recoloured colours beyond Clawd's body and shade: %s" % (mid, sorted(extra)))
        else:
            cm = v2_cmap(e)
            extra = ({cm.get(c, c) for c in v2_gif(st)[2]} & from_set) - {V2_PET_BODY, (191, 105, 77)}
            if extra:
                p.append("%s: the GIF palette has recoloured colours beyond Clawd's body and shade: %s" % (mid, sorted(extra)))
    return p, "%d motions: the colours a body-colour look recolours belong to Clawd's own layers in every source (Lottie layer names, redrawn effect colours, the GIF's palette)" % n


def run_v2():
    run("v2:C1", "schema 2 catalog: keys, motions, looks", v2_c1)
    run("v2:C2", "catalog and files agree (no missing, no unreferenced PNG)", v2_c2)
    run("v2:P1", "source identity (spec 3.1 P1)", v2_p1)
    run("v2:P2", "rest identity (P2)", v2_p2)
    run("v2:P3", "rest end (P3)", v2_p3)
    run("v2:P4", "stage (P4)", v2_p4)
    run("v2:P5", "palette (P5)", v2_p5)
    run("v2:P6", "timing (P6)", v2_p6)
    run("v2:P7", "provenance (P7)", v2_p7)
    run("v2:H1", "head anchors, rigid head, overhead-clear", v2_h1)
    run("v2:U1", "uses, weights, phase", v2_u1)
    run("v2:K1", "look compatibility (K1)", v2_k1)
    run("v2:L1", "look layers", v2_l1)
    run("v2:R1", "resampling report and previews", v2_r1)
    run("v2:P8-redrawn-rest", "redrawn items start and end on the rest frame (P2/P3 from pixels)", v2_redrawn_rest)
    run("v2:R3-baseline", "nothing below the feet baseline (R3)", v2_baseline)
    run("v2:L3-anchor", "layer render anchors (spec 9b item 12)", v2_anchors)
    run("v2:L4-bodycolor", "bodyColor maps only where the spec declares a body colour (spec 9b item 12)", v2_body_colours)
    if S.get("phase", 1) >= 2:
        run("v2:S1", "persona GIF sampling (crisp cells)", v2_s1_gif_report)
        run("v2:R1-body", "redrawn items keep the v1 body (R1)", v2_r1_body)
        run("v2:R2-anchor", "layers anchor at an exact head (R2)", v2_r2_anchor)
        run("v2:R3-bounds", "look and effect bounds (R3)", v2_r3_bounds)
        run("v2:R4-provenance", "phase 2 sources cited with sha256 (R4, P7)", v2_r4_provenance)
        run("v2:L2", "look layers on the v1 poses", v2_l2_poses)
        run("v2:G1", "golden PNGs exist for every new frame (G1)", v2_g1_goldens)
        run("v2:V5", "contact sheets", v2_v5_sheet)
        run("v2:D14-ride", "the skateboard ride: stored frames, segments, composed extent, the board at both ends (R2-1 .. R4-3)", v2_ride)
    if S.get("phase", 1) >= 3:
        run("v2:D18", "phase 1 sunglasses against the plushie's (D18)", v2_d18)
    if S.get("phase", 1) >= 4:
        run("v2:R5", "Claude Code's C motions transcribed (R5)", v2_r5)
        run("v2:R5-node", "the C frames against the real render-core.js run in node (R5)", v2_r5_node)
        run("v2:B7", "the Ultra pose with the wand (B7)", v2_b7)
        run("v2:B7-binary", "Ultra's colour, pose and wand glyphs are in Claude Code's binary", lambda: (v2_ultra_binary(), "the cited offsets 199297306, 224834737 and 195776098 hold the colour, the pose and the glyphs"))
        run("v2:L5-recolour", "a body-colour look recolours only Clawd's own pixels", v2_recolour_safe)
        run("v2:BR", "the in-between pictures of the five seams (bridges)", v2_bridges)


# ---- main ---------------------------------------------------------------------------------------
def write_evidence(path, ok, failed, not_run=()):
    keep = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            keep = [ln.rstrip("\n") for ln in f if ln.startswith("NEGATIVE-CONTROL")]
    atlas_sha = sha256_file(os.path.join(S["art"], "clawd-atlas.json"))
    lines = ["ART-CONTRACT-FAIL" if not ok else ("ART-CONTRACT-PARTIAL" if not_run else "ART-CONTRACT-OK"),
             "date: " + datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
             "atlas-sha256: " + atlas_sha]
    try:
        lines.append("elements-sha256: " + sha256_file(os.path.join(S["art"], "claude-code-elements.json")))
        lines.append("preview-sha256: " + sha256_file(os.path.join(S["art"], "preview", "index.html")))
    except OSError:
        pass
    lines.append("claude-code-binary: %s (version %s)" % (BINARY, S.get("el", {}).get("_meta", {}).get("claude_code_version")))
    lines.append("checks: %d run, %d passed, %d failed" % (len(RESULTS), len(RESULTS) - len(failed), len(failed)))
    if failed:
        lines.append("failed: " + ", ".join(failed))
    if not_run:
        lines.append("not-run: " + ", ".join(not_run))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines + keep) + "\n")
    os.replace(tmp, path)


def main():
    try:
        sys.stdout.reconfigure(errors="backslashreplace")
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--art", default=os.path.join(ROOT, "art"))
    ap.add_argument("--evidence", default=None)
    ap.add_argument("--phase", type=int, choices=(1, 2, 3, 4), default=None,
                    help="also run the v2 checks (spec 3.1) for the catalog entries of phases up to this one")
    ap.add_argument("--motions", default=None, help="with --phase: limit the per-motion v2 checks to these motion ids (comma separated)")
    ap.add_argument("--goldens", default=None, help="with --phase 2: the Tests/Goldens directory; the golden files of the phase 2 frames must exist there")
    args = ap.parse_args()
    S["art"] = os.path.abspath(args.art)
    S["phase"] = args.phase or 1
    S["only"] = set(args.motions.split(",")) if args.motions else None
    S["goldens"] = os.path.abspath(args.goldens) if args.goldens else (
        os.path.join(ROOT, "Tests", "Goldens") if os.path.abspath(args.art) == os.path.join(ROOT, "art") else None)
    default_art = os.path.abspath(args.art) == os.path.join(ROOT, "art")
    evidence = args.evidence or (os.path.join(ROOT, ".evidence", "art-verified.txt") if default_art else None)
    out("art-contract check: art=%s binary=%s" % (S["art"], BINARY))

    run("A1", "atlas parses, top-level keys", a_load)
    run("A2", "unit 4, scale4x_dir", a_unit)
    run("A3", "one canvas 12x12 units, feet baseline 12", a_canvas)
    run("A4", "palette body rgb(215,119,87), eye near-black", a_palette)
    run("A5", "poses are exactly the nine (no Zzz/sparkle/droplet/throw)", a_poses)
    run("A6", "frames[] and ms[] per pose", a_poses_shape)
    run("F1", "every frame PNG exists in frames/ and frames4x/", f_exist)
    run("F2", "no unreferenced PNG", f_orphans)
    run("F3", "PNGs decode", f_decode)
    run("F4", "1x frames share one canvas (1 px per unit)", f_canvas)
    run("F5", "4x frames are exactly 4x, nearest-neighbour", f_4x)
    try:
        analyse()
    except Exception as e:
        out("FAIL P0 pixel analysis could not run -- %s: %s" % (type(e).__name__, e))
        RESULTS.append((False, "P0"))
        S["an"] = {}
    run("P1", "only palette colours", p_colours)
    run("P2", "body colour exactly rgb(215,119,87)", p_body_colour)
    run("P3", "body 8 units wide", p_torso)
    run("P4", "2-unit arms", p_arms)
    run("P5", "four legs", p_legs)
    run("P6", "black 1x1 eyes", p_eyes)
    run("P7", "no stray pixels", p_strays)
    run("P8", "feet baseline identical in every pose", p_baseline)
    run("P9", "hop only moves up", p_hop)
    run("P10", "helmet variants", p_helmet)
    run("E1", "elements JSON has 13 keys", e_load)
    run("E2", "Claude Code binary is readable", e_binary)
    run("E3", "every offset in the elements JSON is covered", e_coverage)
    for off_path, src_path, before in CITATIONS:
        run("E4:" + ".".join(map(str, off_path)), "bytes at the cited offset", make_citation_check(off_path, src_path, before))
    run("E5", "counts: 188 present verbs, 8 past verbs", e_counts)
    run("E6", "verb arrays re-parsed from the binary", e_verbs_bytes)
    run("E7", "spinner glyph arrays re-parsed from the binary", e_glyphs_bytes)
    run("E8", "spinner timing numbers and timeline", e_timing_bytes)
    run("E9", "verb shimmer numbers", e_shimmer_bytes)
    run("E10", "ellipsis, turn-complete line, interrupt, error strings", e_strings_bytes)
    run("E11", "input box strings", e_inputbox_bytes)
    run("E12", "dark theme colours", e_theme_bytes)
    run("E13", "atlas body colour equals Claude Code's own", e_body_cross)
    run("E14", "welcome-screen block art", e_welcome_bytes)
    run("V1", "preview/index.html exists", v_load)
    run("V2", "preview references every pose and frame", v_poses)
    run("V3", "preview frames are the 4x frames", v_files)
    run("V4", "preview embeds the current atlas and elements", v_embedded)
    if args.phase:
        run_v2()

    failed = [cid for ok, cid in RESULTS if not ok]
    out("RESULT: %d checks, %d passed, %d failed%s%s" % (len(RESULTS), len(RESULTS) - len(failed), len(failed),
                                                         (" (" + ", ".join(sorted(set(failed))) + ")") if failed else "",
                                                         (", %d NOT RUN (%s)" % (len(NOT_RUN), ", ".join(NOT_RUN))) if NOT_RUN else ""))
    if evidence:
        try:
            write_evidence(evidence, not failed, sorted(set(failed)), NOT_RUN)
            out("evidence: %s -> %s" % (evidence, "ART-CONTRACT-FAIL" if failed else ("ART-CONTRACT-PARTIAL" if NOT_RUN else "ART-CONTRACT-OK")))
        except Exception as e:
            out("FAIL evidence file could not be written: %s" % e)
            return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
