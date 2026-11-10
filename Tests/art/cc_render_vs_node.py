#!/usr/bin/env python3
"""Cross-check of the C motions against the real render-core.js, run in node (spec 3.1 R5).

Usage:  python3 -I Tests/art/cc_render_vs_node.py

scripts/check-art-contract.py (v2:R5) re-derives every C frame with a JavaScript parser and a pixel routine of its own, and scripts/port-phase4-art.py
draws the frames with another. This test removes the last shared assumption: it runs the real art/sources/claude-code/render-core.js in node, takes
the SVG that its pixelFrameSVG returns for every frame of every sequence, and requires
  - the sequences (Ho, the pose table jo, the frame time Wi) that both Python evaluators read to equal the ones node evaluates,
  - every shipped C frame (art/motions/C*/NNN.png) to equal that SVG's rectangles, one unit = 2 x 2 cells, the dust on top.
One line per motion: PASS <id> / FAIL <id> -- <why>, and a last line `cc-render-vs-node: pass=N fail=M`. Exit 0 when all pass, 1 on a failure, 3 (NOT RUN, never a
pass) when node is not available. The art tree is only read.
"""
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ART = os.environ.get("CLAWD_ART_DIR") or os.path.join(ROOT, "art")          # the mutation suite points it at a broken copy
CORE = os.path.join(ART, "sources", "claude-code", "render-core.js")
NODE = os.environ.get("CLAWD_NODE") or shutil.which("node") or os.path.expanduser("~/.local/node/bin/node")      # CLAWD_NODE: the mutation suite points it at nothing to prove NOT RUN


def load(path, name):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


JS = r'''
const fs = require("fs"), vm = require("vm");
const src = fs.readFileSync(process.argv[1], "utf8");
const ctx = {};
vm.createContext(ctx);
vm.runInContext(src, ctx);
const out = {jo: ctx.jo, Wi: ctx.Wi, Ho: ctx.Ho, svg: {}};
for (const key of Object.keys(ctx.Ho)) {
  out.svg[key] = ctx.Ho[key].map((f) => ctx.pixelFrameSVG(f));
}
console.log(JSON.stringify(out));
'''


def rects(svg):
    """{(x, y): fill} of the unit rectangles of a pixelFrameSVG (the last one drawn wins)."""
    out = {}
    for x, y, w, h, fill in re.findall(r'<rect x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)" fill="([^"]+)"/>', svg):
        assert (w, h) == ("1", "1"), "a rectangle that is not one unit"
        out[(int(x), int(y))] = tuple(int(v) for v in re.match(r"rgb\((\d+),(\d+),(\d+)\)", fill).groups())
    return out


def main():
    if not os.path.isfile(NODE):
        print("NOT RUN cc-render-vs-node: node is not available")
        return 3
    chk = load(os.path.join(ROOT, "scripts", "check-art-contract.py"), "chk")
    p4 = load(os.path.join(ROOT, "scripts", "port-phase4-art.py"), "p4")
    r = subprocess.run([NODE, "-e", JS, CORE], capture_output=True, text=True)
    if r.returncode != 0:
        print("FAIL node -- %s" % r.stderr.strip()[:300])
        print("cc-render-vs-node: pass=0 fail=1")
        return 1
    node = json.loads(r.stdout)
    with open(CORE, encoding="utf-8") as f:
        lines = f.read().split("\n")
    chk_jo, chk_ho, chk_ms = chk.cc_data(lines)
    p4_jo, p4_ho, p4_ms = p4.evaluate(lines)

    def norm(seq):
        return [{"pose": f["pose"], "offset": f.get("offset", 0), "x": f.get("x"), "poof": f.get("poof"), "shadow": f.get("shadow")} for f in seq]
    node_ho = {k: norm(v) for k, v in node["Ho"].items()}
    results = []
    ok = (chk_jo == node["jo"] == p4_jo) and (chk_ms == node["Wi"] == p4_ms == 60) and (chk_ho == node_ho == p4_ho)
    results.append(("evaluators", None if ok else "the sequences, poses or frame time of the two Python evaluators differ from node's"))
    atlas = json.load(open(os.path.join(ART, "clawd-atlas.json"), encoding="utf-8"))
    motions = {m["id"]: m for m in atlas["motions"]}
    for mid, (board, key, uses, count) in sorted(chk.V2_C_ITEMS.items(), key=lambda kv: int(kv[1][0][1:])):
        e = motions.get(mid)
        if e is None:
            results.append((mid, "not in the catalog"))
            continue
        svgs = node["svg"][key]
        problem = None
        if len(svgs) != len(e["frames"]):
            problem = "%d frames in the catalog, node's sequence has %d" % (len(e["frames"]), len(svgs))
        else:
            for k, svg in enumerate(svgs):
                units = rects(svg)
                want = {}
                for (x, y), c in units.items():
                    for a in (0, 1):
                        for b in (0, 1):
                            want[(2 * x + a, 2 * y + b)] = c + (255,)
                w, h, rows = chk.read_png(os.path.join(ART, e["frames"][k]))
                got = {}
                for y in range(h):
                    for x in range(w):
                        px = tuple(rows[y][x * 4:x * 4 + 4])
                        if px[3]:
                            got[(x, y)] = px
                if got != want:
                    diff = sorted(set(got) ^ set(want)) or sorted(c for c in got if got[c] != want[c])
                    problem = "frame %d differs from pixelFrameSVG at cell %s" % (k, diff[0])
                    break
        results.append((mid, problem))
    bad = 0
    for name, problem in results:
        if problem:
            bad += 1
            print("FAIL %s -- %s" % (name, problem))
        else:
            print("PASS %s" % name)
    print("cc-render-vs-node: pass=%d fail=%d" % (len(results) - bad, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
