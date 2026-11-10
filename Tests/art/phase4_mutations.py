#!/usr/bin/env python3
"""Mutation controls for `scripts/check-art-contract.py --phase 4` (Sprint 8: Claude Code's motions C1-C13 transcribed from render-core.js (spec 3.1 R5), the
Ultra pose B7, the body-colour looks Ultra and winter; the three checker rules of spec 9b item 12 on the phase 4 tree).

Usage:  python3 -I Tests/art/phase4_mutations.py [--jobs N] [--list] [--only ID ...]

Every case copies the art tree into a temporary directory, breaks one rule in the copy, runs the checker (--phase 4) against the copy and requires that the
named check FAILs. The identity case breaks nothing and requires exit 0; a case with an empty list and a `checker_edit` runs a tree that breaks a rule through
a checker copy with that rule cut out and requires exit 0 too. A case with `node=True` runs Tests/art/cc_render_vs_node.py (the C frames against the real
render-core.js in node) on the copy and requires the named line to FAIL; a case with `env` runs the checker with those variables, and one with `notrun` requires that
check to be reported NOT RUN (never PASS) with exit 0; `checker_edit` may be a list of (old, new) pairs. A case with `passes` names checks that must print PASS
(with `fails` too, when it names both; checks named in neither are ignored). A case with `porter_edit` (a list of (file, old, new): the first occurrence in that
scripts/port-*.py copy is replaced) or `porter=True` runs a copy of the porter scripts on the art copy before the checker (the atlas is not re-serialised first, because
the porter refuses any text but its own); with no edit the regenerated atlas must be the committed file, byte for byte. One line per case:
  PASS <ID>
  FAIL <ID> -- <why>
and a last line `phase4-mutations: pass=N fail=M`. The real art tree and the real goldens are never written.
"""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CHECKER = os.path.join(ROOT, "scripts", "check-art-contract.py")
NODE_TEST = os.path.join(HERE, "cc_render_vs_node.py")
GOLDENS = os.path.join(ROOT, "Tests", "Goldens")


def load(path, name):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


base = load(os.path.join(HERE, "phase1_mutations.py"), "phase1_mutations")
Tree, first_pixel, read_png, write_png = base.Tree, base.first_pixel, base.read_png, base.write_png
BODY, EYE = base.BODY, base.EYE
DUST = (153, 153, 153, 255)
B7 = "B7-ultra-wand"
CASES = []


def case(cid, fails, motions=None, checker_edit=None, goldens=True, node=False, env=None, notrun=None, passes=None, porter_edit=None, porter=False, omit=None):
    def wrap(fn):
        CASES.append({"id": cid, "fails": fails, "motions": motions, "fn": fn, "checker_edit": checker_edit, "goldens": goldens, "node": node,
                      "env": env, "notrun": notrun, "passes": passes, "porter_edit": porter_edit, "porter": porter or porter_edit is not None,
                      "omit": omit})
        return fn
    return wrap


def layer(t, lid, name):
    return next(l for l in t.look(lid)["layers"] if l["name"] == name)


def clear_first(rows, colour):
    x, y = first_pixel(rows, colour)
    rows[y][x] = (0, 0, 0, 0)


def set_first(rows, colour, new):
    x, y = first_pixel(rows, colour)
    rows[y][x] = new


@case("identity", [])
def _identity(t):
    pass


# ---- R5: the C motions are Claude Code's own data, frame by frame ------------------------------------------------------------------------
R5_RULE = ("def v2_r5():\n    st = v2_state()", "def v2_r5():\n    return [], \"cut\"\n    st = v2_state()")
R5_NODE_RULE = ("def v2_r5_node():\n    \"\"\"", "def v2_r5_node():\n    return [], \"cut\"\n    \"\"\"")
R5_PIN_RULE = ("    if sha != V2_RENDER_CORE_SHA256:\n", "    if False:\n")


def _c1_dust_cell_gone(t):
    t.edit_pixels(t.frame("C1-jump", 0), lambda rows: clear_first(rows, DUST))


@case("R5-C1-dust-cell-missing", ["v2:R5"], ["C1-jump"])
def _r5_dust(t):
    _c1_dust_cell_gone(t)


@case("R5-C1-dust-cell-missing-rule-removed", ["v2:R5-node"], ["C1-jump"], checker_edit=R5_RULE)
def _r5_dust_removed(t):
    _c1_dust_cell_gone(t)                                  # with R5 cut, the node cross-check run from the checker still catches it (spec 9b item 13)


@case("R5-C1-dust-cell-missing-both-rules-removed", [], ["C1-jump"], checker_edit=[R5_RULE, R5_NODE_RULE])
def _r5_dust_both_removed(t):
    _c1_dust_cell_gone(t)
    restep(t, "C1-jump-lead")                              # the bridge's recorded steps follow the edited first frame, so only R5 and R5-node are in question                                  # and with both cut it passes: each of the two is what catches this tree


@case("R5-C1-body-pixel", ["v2:R5"], ["C1-jump"])
def _r5_body(t):
    t.edit_pixels(t.frame("C1-jump", 5), lambda rows: set_first(rows, BODY, EYE))


@case("R5-C7-frame-shifted-one-row", ["v2:R5"], ["C7-drop"])
def _r5_shift(t):
    def shift(rows):
        rows.insert(0, [(0, 0, 0, 0)] * len(rows[0]))
        rows.pop()
    t.edit_pixels(t.frame("C7-drop", 6), shift)


@case("R5-C9-a-pixel-above-the-clip", ["v2:R5"], ["C9-peek"])
def _r5_unclipped(t):
    t.edit_pixels(t.frame("C9-peek", 1), lambda rows: rows[2].__setitem__(5, BODY))        # the board clips every frame to rows 4..11 of the units: nothing is drawn above the torso's top row


@case("R5-C2-celebrate-made-to-end-on-rest", ["v2:R5"], ["C2-celebrate"])
def _r5_c2(t):
    shutil.copyfile(t.frame("C1-jump", 5), t.frame("C2-celebrate", 14))                      # a rest pose in place of the sunk last frame: the flags below are made honest
    m = t.motion("C2-celebrate")
    m["restEnd"] = True
    m.pop("offRest", None)


@case("R5-C3-skip-made-to-start-on-rest", ["v2:R5"], ["C3-skip"])
def _r5_c3(t):
    shutil.copyfile(t.frame("C1-jump", 5), t.frame("C3-skip", 0))                            # the P8-style repair: the first frame becomes the rest pose
    t.motion("C3-skip")["restStart"] = True


@case("R5-C13-a-frame-short", ["v2:R5"], ["C13-sneeze"])
def _r5_count(t):
    m = t.motion("C13-sneeze")
    os.remove(t.frame("C13-sneeze", 11))
    for key in ("frames", "srcFrames", "ms", "head"):
        m[key].pop()


@case("R5-C4-twelve-fps", ["v2:R5", "v2:P6"], ["C4-look"])
def _r5_ms(t):
    t.motion("C4-look")["ms"] = [83, 84, 83, 84, 83, 83, 84, 83, 84, 83, 83]


@case("R5-C5-source-lines", ["v2:R5", "v2:P7"], ["C5-spin"])
def _r5_lines(t):
    t.motion("C5-spin")["source"]["lines"] = ["3", "107-125", "139-152"]


@case("R5-C10-another-sequence", ["v2:R5"], ["C10-wink"])
def _r5_key(t):
    t.motion("C10-wink")["source"]["sequence"] = "boop"


@case("R5-C12-poses-declared", ["v2:R5"], ["C12-tap"])
def _r5_poses(t):
    t.motion("C12-tap")["redraw"]["poses"] = ["B3"]


@case("R5-C4-eye-changes-undeclared", ["v2:R5", "v2:K1"], ["C4-look"])
def _r5_changes(t):
    t.motion("C4-look")["redraw"]["changes"] = []                                          # a glance is a motion whose point is its eyes: sunglasses would cover it


@case("R5-C11-stage-grown", ["v2:R5", "v2:P4"], ["C11-boop"])
def _r5_stage(t):
    t.motion("C11-boop")["stage"]["right"] = 1


@case("R5-C4-calm-pose-is-the-B3-pixels", ["v2:R5"], ["C4-look"])
def _r5_reuse(t):
    def move_eye(rows):                                                                    # the glance the B3 motions draw, one cell off: C4's own frames follow Claude Code
        x, y = first_pixel(rows, EYE)
        rows[y][x] = BODY
    for mid, frames in (("B3-glance-left", range(3, 17)), ("B3-glance-left-long", range(3, 25))):
        for k in frames:
            t.edit_pixels(t.frame(mid, k), move_eye)


@case("R5-render-core-bytes", ["v2:R5", "v2:P7", "v2:R4-provenance"], ["C1-jump"])
def _r5_bytes(t):
    with open(os.path.join(t.art, "sources", "claude-code", "render-core.js"), "ab") as f:
        f.write(b"\n")


def _core_edited_and_every_hash_rewritten(t):
    """A deliberately edited vendored render-core.js with every recorded hash rewritten to match: the file, the catalog and R5's own parser agree."""
    rel = "sources/claude-code/render-core.js"
    path = os.path.join(t.art, rel)
    with open(path, "ab") as f:
        f.write(b"\n")
    with open(path, "rb") as f:
        new = hashlib.sha256(f.read()).hexdigest()
    old = hashlib.sha256(open(os.path.join(ROOT, "art", rel), "rb").read()).hexdigest()
    text = json.dumps(t.atlas)
    assert text.count(old) >= 13 + 3, "the catalog records the hash of render-core.js only %d times" % text.count(old)       # the C and B motions, the looks Ultra and winter
    t.atlas = json.loads(text.replace(old, new))


@case("R5-render-core-edited-and-every-hash-rewritten", ["v2:R5"], ["C1-jump"])
def _r5_pin(t):
    _core_edited_and_every_hash_rewritten(t)


@case("R5-render-core-pin-removed", [], ["C1-jump"], checker_edit=R5_PIN_RULE)
def _r5_pin_removed(t):
    _core_edited_and_every_hash_rewritten(t)               # with the pin cut, nothing else notices the rewritten file: the pin is what catches it


@case("NODE-absent-is-not-run", [], ["C1-jump"], env={"CLAWD_NODE": "/nonexistent/clawd-no-node"}, notrun="v2:R5-node")
def _n_absent(t):
    pass


@case("R5-render-core-helper", ["v2:R5"], ["C1-jump"])
def _r5_helper(t):
    path = os.path.join(t.art, "sources", "claude-code", "render-core.js")
    text = open(path, encoding="utf-8").read()
    open(path, "w", encoding="utf-8").write(text.replace("function _r(){return[{pose:\"default\",offset:1,poof:\"dot\"}", "function _r(){return[{pose:\"default\",offset:2,poof:\"dot\"}", 1))


# the exemption of the C items from P8 and R1 is by the spec's ids and boards only
@case("C-board-label-does-not-exempt", ["v2:U1"], ["D19-happy-caret"])
def _c_label(t):
    t.motion("D19-happy-caret")["board"] = "C1"
    t.motion("D19-happy-caret")["source"]["board"] = "C1"


@case("P8-B4-first-frame-still-binds", ["v2:P8-redrawn-rest"], ["B4-slow-blink"])
def _p8_b4(t):
    shutil.copyfile(t.frame("B4-slow-blink", 6), t.frame("B4-slow-blink", 0))
    t.motion("B4-slow-blink")["restStart"] = False


@case("P3-C2-offrest-removed", ["v2:P3"], ["C2-celebrate"])
def _p3_c2(t):
    t.motion("C2-celebrate").pop("offRest")


@case("U1-C1-uses", ["v2:U1"], ["C1-jump"])
def _u1(t):
    t.motion("C1-jump")["uses"] = ["sent", "touch", "idle"]


@case("U1-C3-scene-use-of-a-motion-that-is-not-overhead-clear", ["v2:U1"], ["C3-skip"])
def _u1_scene(t):
    t.motion("C3-skip")["uses"] = ["entrance", "listening"]


@case("H1-C4-head", ["v2:H1"], ["C4-look"])
def _h1(t):
    t.motion("C4-look")["head"][0] = [11, 8]


@case("C1-C13-missing", ["v2:C1"], ["C4-look"])
def _c1_missing(t):
    t.atlas["motions"] = [m for m in t.atlas["motions"] if m["id"] != "C13-sneeze"]


@case("C1-C13-phase", ["v2:C1"], ["C13-sneeze"])
def _c1_phase(t):
    t.motion("C13-sneeze")["phase"] = 3


@case("C2-orphan-frame", ["v2:C2"], ["C1-jump"])
def _c2(t):
    shutil.copyfile(t.frame("C1-jump", 0), os.path.join(t.art, "motions", "C1-jump", "012.png"))


@case("P5-C-an-unofficial-colour", ["v2:P5"], ["C1-jump"])
def _p5(t):
    t.edit_pixels(t.frame("C1-jump", 0), lambda rows: set_first(rows, DUST, (154, 153, 153, 255)))


# ---- B7, the Ultra pose --------------------------------------------------------------------------------------------------------------
@case("B7-wand-pixel-missing", ["v2:B7"], [B7])
def _b7_pixel(t):
    t.edit_pixels(t.frame(B7, 10), lambda rows: clear_first(rows, (208, 162, 100, 255)))


@case("B7-star-one-unit-further", ["v2:B7"], [B7])
def _b7_star(t):
    def move(rows):
        for row in rows:                                                                   # every gold cell two cells to the right, as the board's trial has it
            xs = [x for x, px in enumerate(row) if px == (255, 204, 104, 255)]
            for x in reversed(xs):
                if x + 2 < len(row):
                    row[x + 2], row[x] = row[x], (0, 0, 0, 0)
    for k in range(3, 21):
        t.edit_pixels(t.frame(B7, k), move)


@case("B7-arm-down", ["v2:B7"], [B7])
def _b7_arm(t):
    shutil.copyfile(t.frame(B7, 0), t.frame(B7, 12))


@case("B7-wand-colour", ["v2:B7", "v2:P5"], [B7])
def _b7_colour(t):
    t.edit_pixels(t.frame(B7, 10), lambda rows: set_first(rows, (255, 204, 104, 255), (255, 204, 105, 255)))


@case("B7-trial-text", ["v2:B7", "v2:R4-provenance"], [B7])
def _b7_trial(t):
    path = os.path.join(t.art, "sources", "claude-code", "board-data.js")
    text = open(path, encoding="utf-8").read()
    open(path, "w", encoding="utf-8").write(text.replace("[[15, bt - 4], [14, bt - 3]", "[[15, bt - 5], [14, bt - 3]", 1))


@case("B7-trial-uncited", ["v2:B7", "v2:R4-provenance"], [B7])
def _b7_uncited(t):
    t.motion(B7)["source"].pop("trial")


@case("B7-binary-offset", ["v2:B7-binary"], [B7], checker_edit=("(199297306, 'effortUltra", "(199297806, 'effortUltra"))
def _b7_binary(t):
    pass


@case("B7-signature-of-ultra-dropped", ["v2:L1"], [B7])
def _b7_signature(t):
    t.look("ultra")["signature"] = ["A25-spark"]


# ---- the looks Ultra and winter --------------------------------------------------------------------------------------------------------
@case("L1-ultra-body-colour", ["v2:L1", "v2:L4-bodycolor"], [B7])
def _l1_ultra_body(t):
    t.look("ultra")["bodyColor"]["map"][0]["to"] = [175, 135, 254]


@case("L1-ultra-shade-rule", ["v2:L1"], [B7])
def _l1_ultra_shade(t):
    t.look("ultra")["bodyColor"]["map"][1]["to"] = [190, 104, 77]               # the shade left as it was: the body violet, the shade orange


@case("L4-winter-map-removed", ["v2:L4-bodycolor", "v2:L1"], [B7])
def _l4_winter_missing(t):
    del t.look("winter")["bodyColor"]


@case("L4-ultra-eye-colour-in-the-map", ["v2:L4-bodycolor"], [B7],
      checker_edit=("    if block.get(\"map\") != want:", "    if False:"))
def _l4_ultra_eye(t):
    t.look("ultra")["bodyColor"]["map"].append({"from": [20, 20, 19], "to": [175, 135, 255]})      # the eye would turn violet; L1's map equality is cut so that only L4 can refuse it


@case("L4-ultra-stray-from-colour", ["v2:L4-bodycolor"], [B7])
def _l4_ultra_stray(t):
    t.look("ultra")["bodyColor"]["map"].append({"from": [217, 119, 87], "to": [175, 135, 255]})


@case("L1-winter-map-source-key", ["v2:L1"], [B7])
def _l1_winter_src(t):
    t.look("winter")["bodyColor"]["source"]["key"] = "WINTER_ROWS.K"


@case("L1-winter-flake-moved", ["v2:L1"], [B7])
def _l1_flake(t):
    def move(rows):
        x, y = first_pixel(rows, (255, 255, 255, 255))
        rows[y][x] = (0, 0, 0, 0)
        rows[y][x + 1 if x + 1 < len(rows[0]) and rows[y][x + 1] == (0, 0, 0, 0) else x - 1] = (255, 255, 255, 255)
    t.edit_pixels(os.path.join(t.art, layer(t, "winter", "snow")["png"]), move)


@case("L1-winter-snow-colour", ["v2:L1"], [B7])
def _l1_snow_colour(t):
    t.edit_pixels(os.path.join(t.art, layer(t, "winter", "snow")["png"]), lambda rows: set_first(rows, (255, 255, 255, 255), (250, 252, 255, 255)))


@case("L1-winter-flakes-declared", ["v2:L1"], [B7])
def _l1_flakes(t):
    layer(t, "winter", "snow")["cut"]["flakes"].pop()


@case("L1-winter-snow-over-the-body", ["v2:L1"], [B7])
def _l1_over_body(t):
    layer(t, "winter", "snow")["offset"][0] += 14                 # the flakes moved onto the torso


@case("L1-ultra-with-a-layer", ["v2:L1"], [B7])
def _l1_ultra_layer(t):
    t.look("ultra")["layers"].append(dict(layer(t, "winter", "snow")))


@case("L3-anchor-canvas-snow", ["v2:L3-anchor"], [B7])
def _l3_snow(t):
    layer(t, "winter", "snow")["anchor"] = "canvas"


@case("L4-bodycolor-on-the-skateboard", ["v2:L4-bodycolor"], [B7])
def _l4_board(t):
    t.look("skateboard")["bodyColor"] = {"map": [{"from": [215, 119, 87], "to": [10, 10, 10]}]}


@case("L5-recolour-effect-colour-of-the-body", ["v2:L5-recolour"], ["D6-heart"])
def _l5_effect(t):
    t.motion("D6-heart")["redraw"]["effectColors"].append([190, 104, 77])


@case("L5-recolour-lottie-layer", ["v2:L5-recolour", "v2:P5"], ["A4-waving"])
def _l5_lottie(t):
    path = os.path.join(t.art, "sources", "lottie", "clawd-waving.js")
    text = open(path, encoding="utf-8").read()
    assert '"nm":"orange"' in text
    open(path, "w", encoding="utf-8").write(text.replace('"nm":"orange"', '"nm":"prop"'))


# ---- K1 for the new looks --------------------------------------------------------------------------------------------------------------
@case("K1-ultra-lost-a-motion", ["v2:K1"], ["C3-skip"])
def _k1_ultra(t):
    t.motion("C3-skip")["compatibleLooks"].remove("ultra")


@case("K1-winter-on-an-entrance", ["v2:K1"], ["C3-skip"])
def _k1_entrance(t):
    t.motion("C3-skip")["compatibleLooks"].append("winter")                 # frames without a head cannot carry the snow


@case("K1-winter-below-the-baseline", ["v2:K1"], ["C1-jump"])
def _k1_dip(t):
    m = t.motion("C1-jump")
    m["compatibleLooks"].append("winter")                                    # the jump's crouch puts the snow under the feet baseline


@case("K1-baseline-rule-on-the-new-looks", ["v2:K1"], ["C1-jump"], checker_edit=("    return v2_baseline_ok(st, l, heads)       # K1-composite-baseline", "    return True"))
def _k1_baseline_cut(t):
    pass                                                                     # the unmutated tree through a checker without the composite baseline: winter's snow pairs differ


@case("K1-floor-new-looks", ["v2:K1"], None, checker_edit=("V2_MIN_IDLE = 6 ", "V2_MIN_IDLE = 99 "))
def _k1_floor(t):
    pass


@case("K1-C13-sneeze-helmet", ["v2:K1"], ["C13-sneeze"])
def _k1_c13(t):
    t.motion("C13-sneeze")["compatibleLooks"].append("helmet")


# ---- catalog, goldens, sheet -----------------------------------------------------------------------------------------------------------
@case("C1-look-missing-winter", ["v2:C1"], ["C4-look"])
def _c1_look(t):
    t.atlas["looks"] = [l for l in t.atlas["looks"] if l["id"] != "winter"]


@case("G1-goldens-phase4", ["v2:G1"], ["C4-look"], goldens=False)
def _g1(t):
    pass


@case("V5-sheet-phase4", ["v2:V5"], ["C4-look"])
def _v5(t):
    os.remove(os.path.join(t.art, "preview", "v2", "contact-sheet-phase4.png"))


# ---- the C frames against the real render-core.js, run in node ---------------------------------------------------------------------------
@case("NODE-C1-pixel", ["C1-jump"], node=True)
def _n1(t):
    t.edit_pixels(t.frame("C1-jump", 5), lambda rows: set_first(rows, BODY, EYE))


@case("NODE-C6-frame-count", ["C6-peekaboo"], node=True)
def _n2(t):
    m = t.motion("C6-peekaboo")
    for key in ("frames", "srcFrames", "ms", "head"):
        m[key].pop()


@case("NODE-render-core-sequence", ["C1-jump"], node=True)
def _n3(t):
    path = os.path.join(t.art, "sources", "claude-code", "render-core.js")
    text = open(path, encoding="utf-8").read()
    old = "var jg=[..._r(),...xe(\"arms-up\",3),"
    assert old in text
    open(path, "w", encoding="utf-8").write(text.replace(old, "var jg=[..._r(),...xe(\"arms-up\",4),", 1))


@case("NODE-identity", [], node=True)
def _n4(t):
    pass


# ---- running -------------------------------------------------------------------------------------------------------------------
# ---- the bridges: the in-between pictures of the five seams (smooth round 2; scripts/port-bridge-art.py) -----------------------------------
def bridge(t, bid):
    return next(b for b in t.atlas["bridges"] if b["id"] == bid)


def bridge_frame(t, bid, k):
    return os.path.join(t.art, bridge(t, bid)["frames"][k])


def stage_cells(t, rel, left, up):
    """{(x, y): rgb} of a PNG's opaque pixels (stored coordinates)."""
    return {(x, y): tuple(px[:3]) for y, row in enumerate(read_png(os.path.join(t.art, rel))) for x, px in enumerate(row) if px[3]}


def restep(t, bid):
    """Writes into the catalog the steps and the seam the PNGs now give, so that a case that edits a picture trips only the rule it is about."""
    b = bridge(t, bid)
    kind, tid, side = b["target"]["kind"], b["target"]["id"], b["side"]
    left, up = int(b["stage"]["left"] * 2), int(b["stage"]["up"] * 2)
    rest = {(2 * x + a + left, 2 * y + c + up): tuple(px[:3]) for y, row in enumerate(read_png(os.path.join(t.art, "frames", "idle_0.png")))
            for x, px in enumerate(row) if px[3] for a in (0, 1) for c in (0, 1)}
    if kind == "pose":
        pose = t.atlas["poses"][tid]
        edge_png = pose["frames"][0 if side == "lead" else -1]
        edge = {(2 * x + a, 2 * y + c): tuple(px[:3]) for y, row in enumerate(read_png(os.path.join(t.art, edge_png))) for x, px in enumerate(row) if px[3]
                for a in (0, 1) for c in (0, 1)}
    else:
        m = t.motion(tid)
        edge = stage_cells(t, m["frames"][0 if side == "lead" else -1], left, up)
        if tid == "D14-ride":
            rest.update({q: c for q, c in edge.items() if c in ((86, 27, 47), (239, 172, 84))})
    frames = [stage_cells(t, rel, left, up) for rel in b["frames"]]
    seq = [rest] + frames + [edge] if side == "lead" else [edge] + frames + [rest]
    diff = lambda a, c: sum(1 for q in set(a) | set(c) if a.get(q) != c.get(q))
    b["steps"] = [diff(seq[i], seq[i + 1]) for i in range(len(seq) - 1)]
    b["direct"] = diff(seq[0], seq[-1])


@case("BR-a-colour-the-seam-does-not-have", ["v2:BR"])
def _br_colour(t):
    t.edit_pixels(bridge_frame(t, "dangle-lead", 0), lambda rows: set_first(rows, EYE, (12, 200, 99, 255)))
    restep(t, "dangle-lead")


@case("BR-a-cell-with-half-alpha", ["v2:BR"])
def _br_alpha(t):
    t.edit_pixels(bridge_frame(t, "hop-lead", 0), lambda rows: set_first(rows, BODY, BODY[:3] + (128,)))
    restep(t, "hop-lead")


@case("BR-the-lead-is-the-first-frame-itself", ["v2:BR"])
def _br_no_bridge(t):
    shutil.copyfile(t.frame("C1-jump", 0), bridge_frame(t, "C1-jump-lead", 0))                  # a bridge that changes nothing leaves the whole step to the next frame
    restep(t, "C1-jump-lead")


@case("BR-the-arcade-cabinet-jumps-in-one-frame", ["v2:BR"])
def _br_arcade_jump(t):
    for k in range(3):
        shutil.copyfile(t.frame("A34-arcade", 0), bridge_frame(t, "A34-arcade-lead", k))     # three copies of frame 0: the step from rest is the whole 524 cells again
    restep(t, "A34-arcade-lead")


@case("BR-the-head-anchor-is-not-where-the-pixels-put-it", ["v2:BR"])
def _br_head(t):
    bridge(t, "dangle-lead")["head"] = [[12, 8]]


@case("BR-steps-declared-better-than-they-are", ["v2:BR"])
def _br_steps(t):
    bridge(t, "D14-ride-tail")["steps"] = [10, 10, 10]


@case("BR-the-seam-without-a-bridge-misstated", ["v2:BR"])
def _br_direct(t):
    bridge(t, "A34-arcade-tail")["direct"] = 1000


@case("BR-a-bridge-removed", ["v2:BR", "v2:C2"])
def _br_removed(t):
    t.atlas["bridges"] = [b for b in t.atlas["bridges"] if b["id"] != "A34-arcade-tail"]


@case("BR-a-bridge-frame-missing-on-disk", ["v2:BR", "v2:C2"])
def _br_file(t):
    os.remove(bridge_frame(t, "hop-lead", 0))


@case("BR-a-png-no-bridge-lists", ["v2:C2"])
def _br_orphan(t):
    os.makedirs(os.path.join(t.art, "bridges", "stray"))
    shutil.copyfile(bridge_frame(t, "hop-lead", 0), os.path.join(t.art, "bridges", "stray", "000.png"))


@case("BR-a-frame-of-another-size", ["v2:BR"])
def _br_size(t):
    t.edit_pixels(bridge_frame(t, "D14-ride-tail", 0), lambda rows: rows.pop())


@case("BR-the-stage-is-not-the-targets", ["v2:BR"])
def _br_stage(t):
    bridge(t, "A34-arcade-lead")["stage"]["right"] = 0


@case("BR-a-frame-time-of-zero", ["v2:BR"])
def _br_ms(t):
    bridge(t, "C11-boop-lead")["ms"] = [0]


@case("BR-the-wrong-side", ["v2:BR"])
def _br_side(t):
    bridge(t, "D14-ride-tail")["side"] = "lead"


@case("BR-the-holding-arm-gone-from-the-hop-lead", ["v2:BR"])
def _br_arm(t):
    def arm_off(rows):                                  # the wand look's holding arm: the cells right of the torso, rows 4..7 under the head anchor
        for y in range(11, 15):
            for x in range(20, 24):
                rows[y][x] = (0, 0, 0, 0)
    t.edit_pixels(bridge_frame(t, "hop-lead", 0), arm_off)
    restep(t, "hop-lead")


# ---- tier 1: a look rides on a motion whose head is found by the face fallback -----------------------------------------------------------
PORTER2 = os.path.join(ROOT, "scripts", "port-phase2-art.py")


def marked(path, marker, edit):
    """(old, new) for a checker_edit or porter_edit: the one line of `path` whose comment is exactly `# <marker>` (never a longer marker that starts the same
    way), rewritten by `edit` and matched whole, from its indentation to its newline."""
    lines = [ln for ln in open(path, encoding="utf-8").read().split("\n") if ln.rstrip().endswith("# " + marker) and ln.rstrip().split("# ")[-1] == marker]
    assert len(lines) == 1, "%s: %d lines end with the marker %s" % (os.path.basename(path), len(lines), marker)
    return lines[0] + "\n", edit(lines[0]) + "\n"


def cond_false(line):
    head, _, comment = line.partition(":")
    assert head.lstrip().startswith("if "), line
    return head[:len(head) - len(head.lstrip())] + "if False:" + line[len(head) + 1:]


def with_text(new):
    return lambda line: line[:len(line) - len(line.lstrip())] + new


def add_look(t, mid, lid):
    names = t.motion(mid)["compatibleLooks"]
    order = [l["id"] for l in t.atlas["looks"]]
    names.append(lid)
    names.sort(key=lambda n: -1 if n == "plain" else order.index(n))


def drop_look(t, mid, lid):
    t.motion(mid)["compatibleLooks"].remove(lid)


@case("K1-tier1-admit-anchor", ["v2:K1"], ["A4-waving"])
def _t1_admit_anchor(t):
    drop_look(t, "A4-waving", "sunglasses")                     # an overhead-clear motion whose head is found by the fallback: the anchor alone admits it


@case("K1-tier1-admit-touch", ["v2:K1"], ["A14-lightbulb"])
def _t1_admit_touch(t):
    drop_look(t, "A14-lightbulb", "sunglasses")                 # admitted only because the bulb does not touch the lenses


@case("K1-tier1-refuse-touch", ["v2:K1"], ["A13-rainbow"])
def _t1_refuse_touch(t):
    add_look(t, "A13-rainbow", "helmet")                        # the rainbow crosses the helmet's dome


@case("R2-tier1-anchor-jump", ["v2:K1", "v2:R2-anchor"], ["A22-notebook"])
def _t1_anchor_jump(t):
    add_look(t, "A22-notebook", "winter")                       # the anchor jumps away from the eyes: T1-b refuses it, and R2 must too


def diagonal_cell(t):
    t.edit_pixels(os.path.join(t.art, "motions", "A11-confetti", "010.png"), lambda rows: rows[19].__setitem__(14, (105, 154, 203, 255)))      # PNG pixel (14, 19) is canvas cell (5, 6)


@case("K1-tier1-touch-diagonal", ["v2:P1", "v2:K1"], ["A11-confetti"])
def _t1_diagonal(t):
    diagonal_cell(t)                                            # diagonal to a headband cell, 4-touching none: the 8-neighbour touch refuses headphones x A11-confetti


@case("K1-tier1-touch-diagonal-4n", ["v2:P1"], ["A11-confetti"], passes=["v2:K1"],
      checker_edit=marked(CHECKER, "T1-touch-n8", with_text("V2_T1_TOUCH = ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1))       # T1-touch-n8")))
def _t1_diagonal_4n(t):
    diagonal_cell(t)                                            # the control: with the 4-neighbourhood the same picture is admitted, so only the diagonal reading refuses it


def hug_winter_snow(t):
    layer(t, "winter", "snow")["hugs"] = "rest-silhouette"


@case("K1-tier1-hugs", ["v2:K1"], ["A13-rainbow"])
def _t1_hugs(t):
    hug_winter_snow(t)                                          # a fixture: with the flag, the winter pairs leave the rest silhouette in their frames


@case("NC-T1-hugs", [], ["A13-rainbow"], passes=["v2:K1"], checker_edit=marked(CHECKER, "T1-hugs", cond_false))
def _t1_hugs_off(t):
    hug_winter_snow(t)


GATE_CONTROLS = [
    ("NC-T1-path", "K1-tier1-path", with_text("return False       # K1-tier1-path")),
    ("NC-R2-tier1", "R2-tier1", with_text("if not rigid:       # R2-tier1")),
    ("NC-T1-a", "T1-a", with_text("continue                  # T1-a")),
    ("NC-T1-b", "T1-b", cond_false),
    ("NC-T1-c", "T1-c", cond_false),
    ("NC-T1-d", "T1-d", with_text("d_on = scope                            # T1-d")),
    ("NC-T1-held", "T1-held", cond_false),
    ("NC-T1-feet", "T1-feet", cond_false),
    ("NC-T1-baseline", "T1-baseline", with_text("return True       # T1-baseline")),
]
for _cid, _marker, _edit in GATE_CONTROLS:
    case(_cid, ["v2:R2-anchor" if _marker == "R2-tier1" else "v2:K1"], None, checker_edit=marked(CHECKER, _marker, _edit))(lambda t: None)


def _dropped_pairs():
    text = open(PORTER2, encoding="utf-8").read()
    return not any(ln.startswith("T1_DROPPED = {}") for ln in text.split("\n"))


if _dropped_pairs():
    case("NC-T1-dropped", ["v2:K1"], None, checker_edit=marked(CHECKER, "T1-dropped", cond_false))(lambda t: None)

# The checker's and the porter's dropped sets are compared (D12). T1-c refuses helmet x A13-rainbow anyway, so only the comparison can turn K1 red here.
case("NC-T1-dropped-sets-differ", ["v2:K1"], ["A13-rainbow"],
     checker_edit=("V2_T1_DROPPED = {}", 'V2_T1_DROPPED = {("helmet", "A13-rainbow"): "probe"}'))(lambda t: None)
# A checker in a `scripts` directory with no porter beside it fails closed (review r1 finding 1): the porter reads as unreadable.
case("NC-T1-porter-missing", ["v2:K1"], ["A13-rainbow"], omit=["port-phase2-art.py"])(lambda t: None)


@case("T-P1", [], None, porter=True)
def _t1_porter_identity(t):
    pass                                                        # the unedited porter regenerates the committed atlas byte for byte, and the checker is green


@case("NC-P", ["v2:K1"], None, porter_edit=[("port-phase2-art.py",) + marked(PORTER2, "K1-tier1-path", with_text("return False       # K1-tier1-path"))])
def _t1_porter_path_off(t):
    pass                                                        # the porter without the tier-1 path writes an atlas that lacks the pairs the checker admits


def run_porter(c, t, tmp):
    """Run a copy of scripts/port-*.py (with the case's edits) on the art copy; the atlas must still be the committed bytes. A problem text, or None."""
    scripts = os.path.join(tmp, "porter")
    os.makedirs(scripts)
    for name in os.listdir(os.path.join(ROOT, "scripts")):
        if name.startswith("port-") and name.endswith(".py"):
            shutil.copyfile(os.path.join(ROOT, "scripts", name), os.path.join(scripts, name))
    for name, old, new in c["porter_edit"] or []:
        path = os.path.join(scripts, name)
        text = open(path, encoding="utf-8").read()
        if old not in text:
            return "the porter text to mutate (%r) is not in %s" % (old, name)
        open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
    r = subprocess.run([sys.executable, "-B", "-I", os.path.join(scripts, "port-official-art.py"), "--art", t.art], capture_output=True, text=True, cwd=tmp, timeout=600)
    if r.returncode != 0:
        return "the porter exited %d: %s" % (r.returncode, (r.stderr or r.stdout)[-300:])
    if not c["porter_edit"] and open(os.path.join(t.art, "clawd-atlas.json"), "rb").read() != open(os.path.join(ROOT, "art", "clawd-atlas.json"), "rb").read():
        return "the unedited porter wrote an atlas that is not the committed file"
    return None


def run_case(c):
    with tempfile.TemporaryDirectory(prefix="clawd-art-mutation4-") as tmp:
        try:
            t = Tree(tmp)
            c["fn"](t)
            if c["porter"]:
                problem = run_porter(c, t, tmp)
                if problem:
                    return c["id"], problem
            else:
                t.save_atlas()                                # the cases edit t.atlas in memory; the checker reads the file
            if c["node"]:
                env = dict(os.environ, CLAWD_ART_DIR=t.art)
                r = subprocess.run([sys.executable, "-I", NODE_TEST], capture_output=True, text=True, cwd=ROOT, timeout=600, env=env)
                failed = {ln.split()[1] for ln in r.stdout.splitlines() if ln.startswith("FAIL ")}
                if not c["fails"]:
                    return c["id"], None if (r.returncode == 0 and not failed) else "the unmutated copy failed: %s (exit %d)" % (sorted(failed), r.returncode)
                missing = [f for f in c["fails"] if f not in failed]
                if r.returncode != 1 or missing:
                    return c["id"], "expected FAIL %s, got exit %d and FAIL %s" % (c["fails"], r.returncode, sorted(failed) or "nothing")
                return c["id"], None
            checker = CHECKER
            if c["checker_edit"] or c["omit"]:
                text = open(CHECKER, encoding="utf-8").read()
                edits = c["checker_edit"] or []
                edits = edits if isinstance(edits, list) else [edits]
                for old, new in edits:
                    if old not in text:
                        return c["id"], "the checker text to mutate (%r) is not there" % old
                    text = text.replace(old, new, 1)
                # The edited checker sits in a copy of the repo layout (the other scripts and the tests linked in), because the checker finds
                # Tests/art/cc_render_vs_node.py from its own place and that script loads the checker and the port script from its own.
                layout = os.path.join(tmp, "repo")
                os.makedirs(os.path.join(layout, "scripts"))
                for name in os.listdir(os.path.join(ROOT, "scripts")):
                    if name not in ("check-art-contract.py", "__pycache__") + tuple(c["omit"] or ()):
                        os.symlink(os.path.join(ROOT, "scripts", name), os.path.join(layout, "scripts", name))
                os.symlink(os.path.join(ROOT, "Tests"), os.path.join(layout, "Tests"))
                checker = os.path.join(layout, "scripts", "check-art-contract.py")
                open(checker, "w", encoding="utf-8").write(text)
            goldens = GOLDENS if c["goldens"] else os.path.join(tmp, "no-goldens")
            if not c["goldens"]:
                os.makedirs(goldens)
            cmd = [sys.executable, "-I", checker, "--art", t.art, "--phase", "4", "--goldens", goldens]
            if c["motions"]:
                cmd += ["--motions", ",".join(c["motions"])]
            r = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, timeout=600, env=dict(os.environ, **(c["env"] or {})))
        except Exception as e:                            # a broken case is a failing case
            return c["id"], "case could not run: %s: %s" % (type(e).__name__, e)
    if c["notrun"]:
        lines = r.stdout.splitlines()
        reported = any(ln.startswith("NOT RUN %s " % c["notrun"]) for ln in lines)
        passed = any(ln.startswith("PASS %s " % c["notrun"]) for ln in lines)
        if r.returncode != 0 or not reported or passed:
            return c["id"], "expected exit 0 and %s reported NOT RUN and never PASS, got exit %d, reported=%s, passed=%s" % (c["notrun"], r.returncode, reported, passed)
        return c["id"], None
    failed = {ln.split()[1] for ln in r.stdout.splitlines() if ln.startswith("FAIL ")}
    if c["passes"] is not None:
        passed = {ln.split()[1] for ln in r.stdout.splitlines() if ln.startswith("PASS ")}
        missing = [f for f in c["fails"] if f not in failed]
        not_passed = [f for f in c["passes"] if f not in passed]
        if (c["fails"] and r.returncode != 1) or missing or not_passed:
            return c["id"], "expected FAIL %s and PASS %s, got exit %d, FAIL %s, and PASS missing for %s" % (c["fails"], c["passes"], r.returncode, sorted(failed) or "nothing", not_passed)
        return c["id"], None
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
    print("phase4-mutations: pass=%d fail=%d" % (len(cases) - bad, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
