#!/usr/bin/env python3
"""Mutation controls for `scripts/check-art-contract.py --phase 1` (spec v2 section 3.1: P1-P7, K1 and the checks around them).

Usage:  python3 -I Tests/art/phase1_mutations.py [--jobs N] [--list] [--only ID ...]

Every case copies the art tree into a temporary directory (a clone on APFS), breaks one rule in the copy, runs the checker against the
copy and requires that the named check FAILs. The identity case breaks nothing and requires exit 0. One line per case:
  PASS <ID>
  FAIL <ID> -- <why>
and a last line `phase1-mutations: pass=N fail=M`. The real art tree is never written.
"""
import argparse
import concurrent.futures
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHECKER = os.path.join(ROOT, "scripts", "check-art-contract.py")
ART = os.path.join(ROOT, "art")
TREE = ["frames", "frames4x", "preview", "motions", "looks", "bridges", "sources", "reports", "clawd-atlas.json", "claude-code-elements.json"]
SIG = b"\x89PNG\r\n\x1a\n"
BODY, EYE = (215, 119, 87, 255), (20, 20, 19, 255)


# ---- PNG and catalog helpers (test-side copies; the checker has its own) ------------------------------------------------------
def read_png(path):
    data = open(path, "rb").read()
    i, idat, w, h = 8, [], 0, 0
    while i < len(data):
        n, tag = struct.unpack(">I4s", data[i:i + 8])
        body = data[i + 8:i + 8 + n]
        i += 12 + n
        if tag == b"IHDR":
            w, h = struct.unpack(">II", body[:8])
        elif tag == b"IDAT":
            idat.append(body)
    raw = zlib.decompress(b"".join(idat))
    stride = w * 4
    rows = []
    for y in range(h):
        if raw[y * (stride + 1)] != 0:
            raise ValueError("%s: this test reads filter 0 only" % path)
        rows.append([tuple(raw[y * (stride + 1) + 1 + x * 4:y * (stride + 1) + 5 + x * 4]) for x in range(w)])
    return rows


def write_png(path, rows):
    h, w = len(rows), len(rows[0])
    raw = b"".join(b"\x00" + b"".join(bytes(px) for px in row) for row in rows)

    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(SIG + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


class Tree:
    """One temporary copy of the art directory with helpers to break it."""

    def __init__(self, root):
        self.root = root
        self.art = os.path.join(root, "art")
        os.makedirs(self.art)
        for name in TREE:
            src, dst = os.path.join(ART, name), os.path.join(self.art, name)
            if subprocess.run(["/bin/cp", "-cR", src, dst], capture_output=True).returncode != 0:
                subprocess.run(["/bin/cp", "-R", src, dst], check=True)
        self.atlas = json.load(open(os.path.join(self.art, "clawd-atlas.json"), encoding="utf-8"))

    def save_atlas(self):
        with open(os.path.join(self.art, "clawd-atlas.json"), "w", encoding="utf-8") as f:
            json.dump(self.atlas, f, indent=2)

    def motion(self, mid):
        return next(m for m in self.atlas["motions"] if m["id"] == mid)

    def look(self, lid):
        return next(l for l in self.atlas["looks"] if l["id"] == lid)

    def frame(self, mid, k):
        return os.path.join(self.art, self.motion(mid)["frames"][k])

    def edit_pixels(self, path, fn):
        rows = read_png(path)
        fn(rows)
        write_png(path, rows)


def first_pixel(rows, colour):
    for y, row in enumerate(rows):
        for x, px in enumerate(row):
            if px == colour:
                return x, y
    raise ValueError("no pixel of colour %r" % (colour,))


# ---- the cases ----------------------------------------------------------------------------------------------------------------
CASES = []


def case(cid, fails, motions=None, checker_edit=None):
    def wrap(fn):
        CASES.append({"id": cid, "fails": fails, "motions": motions, "fn": fn, "checker_edit": checker_edit})
        return fn
    return wrap


def set_pixel(rows, colour):
    x, y = first_pixel(rows, BODY)
    rows[y][x] = colour


@case("identity", [], None)
def _identity(t):
    pass


@case("P1-pixel", ["v2:P1"], ["A12-heart"])
def _p1_pixel(t):
    t.edit_pixels(t.frame("A12-heart", 8), lambda rows: set_pixel(rows, EYE))


@case("P1-shift", ["v2:P1"], ["A7-swaying"])
def _p1_shift(t):
    def shift(rows):
        for i, row in enumerate(rows):
            rows[i] = [(0, 0, 0, 0)] + row[:-1]
    t.edit_pixels(t.frame("A7-swaying", 10), shift)


@case("P1-origin", ["v2:P1"], ["A12-heart"])
def _p1_origin(t):
    t.motion("A12-heart")["source"]["origin"][0] += 50
    t.save_atlas()


@case("P1-colormap", ["v2:P1"], ["A21-desktop"])
def _p1_colormap(t):
    t.motion("A21-desktop")["source"]["colorMap"] = []
    t.save_atlas()


@case("P1-omit", ["v2:P1"], ["A1-thinking-nobubble"])
def _p1_omit(t):
    del t.motion("A1-thinking-nobubble")["source"]["omit"]
    t.save_atlas()


@case("P1-mirror", ["v2:P1"], ["A5-walking-mirrored"])
def _p1_mirror(t):
    del t.motion("A5-walking-mirrored")["source"]["mirror"]
    t.save_atlas()


@case("P2-flag", ["v2:P2"], ["A12-heart"])
def _p2_flag(t):
    t.motion("A12-heart")["restStart"] = False
    t.save_atlas()


@case("P2-pixel", ["v2:P2"], ["A12-heart"])
def _p2_pixel(t):
    def mend(rows):
        x, y = first_pixel(rows, EYE)
        rows[y][x] = BODY
    t.edit_pixels(t.frame("A12-heart", 0), mend)


@case("P3-end-undeclared", ["v2:P3"], ["A4-waving"])
def _p3_end(t):
    m = t.motion("A4-waving")
    del m["closeLoop"]
    m["restEnd"] = False
    t.save_atlas()


@case("P6-closeloop-flag", ["v2:P6"], ["A4-waving"])
def _p6_closeloop(t):
    del t.motion("A4-waving")["closeLoop"]
    t.save_atlas()


@case("P3-hold", ["v2:P3"], ["A15-snooze"])
def _p3_hold(t):
    del t.motion("A15-snooze")["hold"]
    t.save_atlas()


@case("P3-offrest-on-rest", ["v2:P3"], ["A2-looking"])
def _p3_offrest(t):
    t.motion("A2-looking")["offRest"] = True
    t.save_atlas()


@case("P3-offrest-silent", ["v2:P3"], ["A34-arcade"])
def _p3_silent(t):
    del t.motion("A34-arcade")["offRest"]
    t.save_atlas()


@case("P4-stage-shrink", ["v2:P4"], ["A12-heart"])
def _p4_shrink(t):
    t.motion("A12-heart")["stage"]["up"] = 6
    t.save_atlas()


@case("P4-stage-grow", ["v2:P4"], ["A3-jumping"])
def _p4_grow(t):
    t.motion("A3-jumping")["stage"]["left"] = 1
    t.save_atlas()


@case("P5-palette", ["v2:P5"], ["A12-heart"])
def _p5_palette(t):
    t.edit_pixels(t.frame("A12-heart", 8), lambda rows: set_pixel(rows, (1, 2, 3, 255)))


@case("P5-colormap", ["v2:P5"], ["A21-desktop"])
def _p5_colormap(t):
    t.motion("A21-desktop")["source"]["colorMap"][0]["to"] = [10, 10, 10]
    t.save_atlas()


@case("P6-ms", ["v2:P6"], ["A12-heart"])
def _p6_ms(t):
    t.motion("A12-heart")["ms"][3] += 1
    t.save_atlas()


@case("P6-srcframes", ["v2:P6"], ["A12-heart"])
def _p6_src(t):
    m = t.motion("A12-heart")
    m["srcFrames"][3], m["srcFrames"][4] = m["srcFrames"][4], m["srcFrames"][3]
    t.save_atlas()


@case("P7-sha", ["v2:P7"], ["A12-heart"])
def _p7_sha(t):
    t.motion("A12-heart")["source"]["sha256"] = "0" * 64
    t.save_atlas()


@case("P7-source-bytes", ["v2:P7"], ["A12-heart"])
def _p7_bytes(t):
    with open(os.path.join(t.art, "sources", "lottie", "Clawd-Heart.js"), "ab") as f:
        f.write(b"\n")


@case("P7-path", ["v2:P7"], ["A12-heart"])
def _p7_path(t):
    t.motion("A12-heart")["source"]["path"] = "sources/lottie/Clawd-Rainbow.js"
    t.save_atlas()


@case("H1-head", ["v2:H1"], ["A12-heart"])
def _h1_head(t):
    t.motion("A12-heart")["head"][3] = [13, 8]
    t.save_atlas()


@case("H1-overhead", ["v2:H1"], ["A12-heart"])
def _h1_over(t):
    t.motion("A12-heart")["overheadClear"] = True
    t.save_atlas()


@case("H1-rigid", ["v2:H1"], ["A2-looking"])
def _h1_rigid(t):
    t.motion("A2-looking")["rigidHead"] = False
    t.save_atlas()


@case("K1-add", ["v2:K1"], ["A10-breakdancing"])
def _k1_add(t):
    t.motion("A10-breakdancing")["compatibleLooks"].append("helmet")
    t.save_atlas()


@case("K1-remove", ["v2:K1"], ["A2-looking"])
def _k1_remove(t):
    t.motion("A2-looking")["compatibleLooks"].remove("sunglasses")
    t.save_atlas()


@case("K1-floor", ["v2:K1"], None, checker_edit=("V2_MIN_IDLE = 6 ", "V2_MIN_IDLE = 99 "))
def _k1_floor(t):
    pass


# The contract is checked against a pinned copy of the binary the elements came from; a file that is not that build must fail E2.
@case("E2-reference-is-not-the-official-build", ["E2"], None,
      checker_edit=('REFERENCE_SHA256 = "1f04c69e', 'REFERENCE_SHA256 = "0f04c69e'))
def _e2_reference(t):
    pass


@case("U1-use", ["v2:U1"], ["A12-heart"])
def _u1_use(t):
    t.motion("A12-heart")["uses"].append("sent")
    t.save_atlas()


@case("U1-weight", ["v2:U1"], ["A10-breakdancing"])
def _u1_weight(t):
    t.motion("A10-breakdancing")["weight"] = 1
    t.save_atlas()


@case("L1-layer-pixel", ["v2:L1"], ["A12-heart"])
def _l1_pixel(t):
    path = os.path.join(t.art, t.look("sunglasses")["layers"][0]["png"])
    def flip(rows):
        x, y = first_pixel(rows, EYE)
        rows[y][x] = (0, 0, 0, 0)
    t.edit_pixels(path, flip)


@case("L1-offset", ["v2:L1"], ["A12-heart"])
def _l1_offset(t):
    t.look("headphones")["layers"][0]["offset"][0] += 1
    t.save_atlas()


@case("L1-restposes", ["v2:L1"], ["A12-heart"])
def _l1_rest(t):
    t.look("sunglasses")["layers"][0]["restPoses"]["idle"] = [[0, 0]]
    t.save_atlas()


@case("L1-cut-colors", ["v2:L1"], ["A12-heart"])
def _l1_cut(t):
    t.look("sunglasses")["layers"][0]["cut"]["colors"].append([215, 119, 87])
    t.save_atlas()


@case("L1-cut-source", ["v2:L1"], ["A12-heart"])
def _l1_source(t):
    t.look("headphones")["layers"][0]["cut"]["motion"] = "A17-sunglasses"
    t.save_atlas()


@case("L1-signature-flag", ["v2:L1"], ["A12-heart"])
def _l1_sig(t):
    t.look("headphones")["layerOnSignature"] = True
    t.save_atlas()


@case("C1-motion-missing", ["v2:C1"], ["A12-heart"])
def _c1_missing(t):
    t.atlas["motions"] = [m for m in t.atlas["motions"] if m["id"] != "A9-dancing"]
    t.save_atlas()


@case("C1-phase", ["v2:C1"], ["A12-heart"])
def _c1_phase(t):
    t.motion("A9-dancing")["phase"] = 2
    t.save_atlas()


@case("C1-look-phase", ["v2:C1"], ["A12-heart"])
def _c1_look_phase(t):
    t.look("sunglasses")["phase"] = 2
    t.save_atlas()


@case("C1-schema", ["v2:C1"], ["A12-heart"])
def _c1_schema(t):
    t.atlas["schema"] = 3
    t.save_atlas()


@case("C2-orphan", ["v2:C2"], ["A12-heart"])
def _c2_orphan(t):
    shutil.copy(os.path.join(t.art, "motions", "A12-heart", "000.png"), os.path.join(t.art, "motions", "A12-heart", "099.png"))


@case("C2-missing", ["v2:C2"], ["A12-heart"])
def _c2_missing(t):
    os.remove(t.frame("A12-heart", 5))


@case("R1-report", ["v2:R1"], ["A12-heart"])
def _r1_report(t):
    path = os.path.join(t.art, "reports", "resampling-report.json")
    rep = json.load(open(path, encoding="utf-8"))
    rep["files"]["Clawd-ConfettiHappy"]["offGridAtOrigin"] += 1
    json.dump(rep, open(path, "w", encoding="utf-8"), indent=2)


@case("A1-v1-extra-key", ["A1"], ["A12-heart"])
def _a1_extra(t):
    t.atlas["extra"] = 1
    t.save_atlas()


@case("A1-v1-partial-schema", ["A1", "v2:C1"], ["A12-heart"])
def _a1_partial(t):
    del t.atlas["looks"]
    t.save_atlas()


# ---- running ------------------------------------------------------------------------------------------------------------------
def run_case(c):
    with tempfile.TemporaryDirectory(prefix="clawd-art-mutation-") as tmp:
        try:
            t = Tree(tmp)
            c["fn"](t)
            checker = CHECKER
            if c["checker_edit"]:
                text = open(CHECKER, encoding="utf-8").read()
                old, new = c["checker_edit"]
                if old not in text:
                    return c["id"], "the checker text to mutate (%r) is not there" % old
                checker = os.path.join(tmp, "check-art-contract.py")
                open(checker, "w", encoding="utf-8").write(text.replace(old, new, 1))
            cmd = [sys.executable, "-I", checker, "--art", t.art, "--phase", "1"]
            if c["motions"]:
                cmd += ["--motions", ",".join(c["motions"])]
            r = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, timeout=300)
        except Exception as e:                            # a broken case is a failing case
            return c["id"], "case could not run: %s: %s" % (type(e).__name__, e)
    failed = {ln.split()[1] for ln in r.stdout.splitlines() if ln.startswith("FAIL ")}
    if not c["fails"]:
        return c["id"], None if (r.returncode == 0 and not failed) else "the unmutated copy failed: %s (exit %d)" % (sorted(failed), r.returncode)
    missing = [f for f in c["fails"] if f not in failed]
    if r.returncode != 1 or missing:
        return c["id"], "expected FAIL %s, got exit %d and FAIL %s" % (c["fails"], r.returncode, sorted(failed) or "nothing")
    return c["id"], None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--only", nargs="*", default=None)
    args = ap.parse_args()
    cases = [c for c in CASES if not args.only or c["id"] in args.only]
    if args.list:
        for c in CASES:
            print(c["id"], "->", ",".join(c["fails"]) or "exit 0")
        return 0
    unknown = set(args.only or []) - {c["id"] for c in CASES}
    if unknown:
        print("unknown case: %s" % ", ".join(sorted(unknown)))
        return 2
    bad = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for cid, problem in pool.map(run_case, cases):
            if problem:
                bad += 1
                print("FAIL %s -- %s" % (cid, problem))
            else:
                print("PASS %s" % cid)
            sys.stdout.flush()
    print("phase1-mutations: pass=%d fail=%d" % (len(cases) - bad, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
