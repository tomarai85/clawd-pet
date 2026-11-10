#!/usr/bin/env python3
"""Mutation controls for `scripts/check-art-contract.py --phase 2` (Sprint 5: the sticker looks, the detective's inspect motion, the
redrawn moments; spec v2 section 3.1: P1-P7, R1-R4, K1, G1 and the checks around them).

Usage:  python3 -I Tests/art/phase2_mutations.py [--jobs N] [--list] [--only ID ...]

Every case copies the art tree into a temporary directory, breaks one rule in the copy, runs the checker against the copy and requires that
the named check FAILs. The identity case breaks nothing and requires exit 0. One line per case:
  PASS <ID>
  FAIL <ID> -- <why>
and a last line `phase2-mutations: pass=N fail=M`. The real art tree and the real goldens are never written.
"""
import argparse
import concurrent.futures
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
CASES = []


def case(cid, fails, motions=None, checker_edit=None, goldens=True):
    def wrap(fn):
        CASES.append({"id": cid, "fails": fails, "motions": motions, "fn": fn, "checker_edit": checker_edit, "goldens": goldens})
        return fn
    return wrap


def layer_png(t, lid, name):
    return os.path.join(t.art, next(l for l in t.look(lid)["layers"] if l["name"] == name)["png"])


def flip_first(rows, colour, to):
    x, y = first_pixel(rows, colour)
    rows[y][x] = to


@case("identity", [])
def _identity(t):
    pass


# ---- the persona GIF motion ----------------------------------------------------------------------------------------------------
@case("P1-gif-pixel", ["v2:P1"], ["D12-inspect"])
def _p1_gif_pixel(t):
    t.edit_pixels(t.frame("D12-inspect", 40), lambda rows: flip_first(rows, BODY, EYE))


@case("P1-gif-grid", ["v2:P1"], ["D12-inspect"])
def _p1_gif_grid(t):
    t.motion("D12-inspect")["source"]["grid"]["x0"] += 1
    t.save_atlas()


@case("P1-gif-colormap", ["v2:P5"], ["D12-inspect"])
def _p1_gif_map(t):
    t.motion("D12-inspect")["source"]["colorMap"] = t.motion("D12-inspect")["source"]["colorMap"][:1]
    t.save_atlas()


@case("P2-gif-flag", ["v2:P2"], ["D12-inspect"])
def _p2_gif(t):
    t.motion("D12-inspect")["restEnd"] = False
    t.save_atlas()


@case("P4-gif-stage", ["v2:P4"], ["D12-inspect"])
def _p4_gif(t):
    t.motion("D12-inspect")["stage"]["right"] = 1
    t.save_atlas()


@case("P6-gif-ms", ["v2:P6"], ["D12-inspect"])
def _p6_gif(t):
    t.motion("D12-inspect")["ms"][5] += 10
    t.save_atlas()


@case("P7-gif-sha", ["v2:P7"], ["D12-inspect"])
def _p7_gif(t):
    t.motion("D12-inspect")["source"]["sha256"] = "0" * 64
    t.save_atlas()


@case("P7-gif-bytes", ["v2:P7", "v2:R4-provenance"], ["D12-inspect"])
def _p7_gif_bytes(t):
    with open(os.path.join(t.art, "sources", "persona", "Clawd-Magnifier.gif"), "ab") as f:
        f.write(b"\0")


@case("U1-gif-weight", ["v2:U1"], ["D12-inspect"])
def _u1_gif(t):
    t.motion("D12-inspect")["weight"] = 1
    t.save_atlas()


@case("S1-gif-report", ["v2:S1"], ["D12-inspect"])
def _s1(t):
    path = os.path.join(t.art, "reports", "gif-sampling-report.json")
    rep = json.load(open(path, encoding="utf-8"))
    rep["impureCells"] = 3
    json.dump(rep, open(path, "w", encoding="utf-8"))


# ---- the redrawn moments -------------------------------------------------------------------------------------------------------
@case("P5-redrawn-colour", ["v2:P5", "v2:R1-body"], ["D6-heart"])
def _p5_redrawn(t):
    t.edit_pixels(t.frame("D6-heart", 6), lambda rows: flip_first(rows, (233, 69, 68, 255), (1, 2, 3, 255)))


@case("P6-redrawn-ms", ["v2:P6"], ["D4-happy"])
def _p6_redrawn(t):
    t.motion("D4-happy")["ms"][2] += 1
    t.save_atlas()


@case("P7-sticker-bytes", ["v2:P7", "v2:R4-provenance"], ["D5-dizzy"])
def _p7_sticker(t):
    with open(os.path.join(t.art, "sources", "sticker", "dizzy.png"), "ab") as f:
        f.write(b"\0")


@case("P7-sticker-path", ["v2:P7"], ["D5-dizzy"])
def _p7_path(t):
    t.motion("D5-dizzy")["source"]["picture"] = "sources/sticker/happy"
    t.save_atlas()


@case("H1-redrawn-head", ["v2:H1"], ["D4-happy"])
def _h1_redrawn(t):
    t.motion("D4-happy")["head"][3] = [13, 8]
    t.save_atlas()


@case("U1-redrawn-use", ["v2:U1"], ["D4-happy"])
def _u1_redrawn(t):
    t.motion("D4-happy")["uses"].append("idle")
    t.save_atlas()


@case("R1-body-eye", ["v2:R1-body"], ["D4-happy"])
def _r1_eye(t):
    def move(rows):
        x, y = first_pixel(rows, EYE)
        rows[y][x] = BODY
    t.edit_pixels(t.frame("D4-happy", 5), move)


@case("R1-body-leg", ["v2:R1-body"], ["D6-heart"])
def _r1_leg(t):
    def hole(rows):
        rows[-1][4] = (0, 0, 0, 0)         # D6 has no stage on the left: PNG column 4 is canvas cell 4, the first leg
    t.edit_pixels(t.frame("D6-heart", 5), hole)


@case("R1-body-asymmetric-eyes", ["v2:R1-body"], ["D5-dizzy"])
def _r1_sym(t):
    def mutate(rows):
        x, y = first_pixel(rows, EYE)
        rows[y][x] = BODY
    t.edit_pixels(t.frame("D5-dizzy", 3), mutate)


@case("R1-body-undeclared-change", ["v2:R1-body"], ["D6-heart"])
def _r1_change(t):
    t.motion("D6-heart")["redraw"]["changes"] = ["wings:spread"]
    t.save_atlas()


@case("P1-redrawn-stage", ["v2:P1", "v2:P2"], ["D11-lightbulb"])
def _p1_redrawn_stage(t):
    m = t.motion("D11-lightbulb")
    m["stage"]["up"] = 3.5
    t.save_atlas()


# ---- the looks -----------------------------------------------------------------------------------------------------------------
@case("L1-ring-pixel", ["v2:L1"], ["A12-heart"])
def _l1_ring(t):
    t.edit_pixels(layer_png(t, "pool-float", "ring-back"), lambda rows: flip_first(rows, (105, 154, 203, 255), (1, 2, 3, 255)))


@case("L1-sparkle-pixel", ["v2:L1"], ["A12-heart"])
def _l1_sparkle(t):
    path = layer_png(t, "shiny", "sparkles")
    rows = read_png(path)
    x, y = first_pixel(rows, (217, 196, 224, 255))
    rows[y][x] = (232, 241, 205, 255)
    write_png(path, rows)


@case("L1-shiny-recolour-back", ["v2:L1"], ["A12-heart"])
def _l1_recolour(t):
    # the cream recolour of round 2 put back: Clawd's own colours stay, the pastels are the border
    t.look("shiny")["bodyColor"] = {"map": [{"from": [215, 119, 87], "to": [254, 233, 187]}], "source": {}}
    t.save_atlas()


def border_png(t):
    return layer_png(t, "shiny", "border")


@case("L1-border-pixel-inside", ["v2:L1", "v2:L2"], ["A12-heart"])
def _l1_border_inside(t):
    # one border pixel on a cell of the torso (head-relative cell (0, 5)): the outline would show through the body's place
    path = border_png(t)
    rows = read_png(path)
    off = next(l for l in t.look("shiny")["layers"] if l["name"] == "border")["offset"]
    rows[5 - off[1]][0 - off[0]] = (254, 234, 187, 255)
    write_png(path, rows)


@case("L1-border-pixel-colour", ["v2:L1"], ["A12-heart"])
def _l1_border_colour(t):
    path = border_png(t)
    rows = read_png(path)
    x, y = first_pixel(rows, (254, 234, 187, 255))
    rows[y][x] = (254, 234, 188, 255)
    write_png(path, rows)


@case("L1-border-pixel-missing", ["v2:L1"], ["A12-heart"])
def _l1_border_missing(t):
    path = border_png(t)
    rows = read_png(path)
    x, y = first_pixel(rows, (254, 234, 187, 255))
    rows[y][x] = (0, 0, 0, 0)
    write_png(path, rows)


@case("L1-border-source-pixel", ["v2:L1"], ["A12-heart"])
def _l1_border_source(t):
    cut = next(l for l in t.look("shiny")["layers"] if l["name"] == "border")["cut"]
    cut["colors"][3]["pixel"] = [cut["colors"][3]["pixel"][0] + 1, cut["colors"][3]["pixel"][1]]
    t.save_atlas()


@case("L1-border-order", ["v2:L1"], ["A12-heart"])
def _l1_border_order(t):
    # two sectors swapped: the pastels no longer run round the outline in the sticker's order
    cut = next(l for l in t.look("shiny")["layers"] if l["name"] == "border")["cut"]
    cut["colors"][2], cut["colors"][9] = cut["colors"][9], cut["colors"][2]
    t.save_atlas()


@case("L1-border-thickness", ["v2:L1"], ["A12-heart"])
def _l1_border_thickness(t):
    next(l for l in t.look("shiny")["layers"] if l["name"] == "border")["cut"]["cells"] = 3
    t.save_atlas()


@case("L1-border-not-hugging", ["v2:L1", "v2:K1"], ["B5-foot-tap"])      # A7 and A2 dip the head by a cell: the composite baseline refuses them for shiny's border on its own; the foot tap does not dip
def _l1_border_hugs(t):
    del next(l for l in t.look("shiny")["layers"] if l["name"] == "border")["hugs"]
    t.save_atlas()


@case("L1-sparkle-colour", ["v2:L1"], ["A12-heart"])
def _l1_sparkle_colour(t):
    next(l for l in t.look("shiny")["layers"] if l["name"] == "sparkles")["cut"]["colors"]["a"]["rgb"] = [232, 241, 205]
    t.save_atlas()


@case("L1-sparkle-outside-band", ["v2:L1"], ["A12-heart"])
def _l1_sparkle_band(t):
    # the source pixel of a sparkle colour moved to the middle of the sticker's body: no longer a border pastel
    cut = next(l for l in t.look("shiny")["layers"] if l["name"] == "sparkles")["cut"]
    cut["colors"]["b"]["pixel"] = [300, 232]
    t.save_atlas()


@case("L1-hat-pixel", ["v2:L1"], ["A12-heart"])
def _l1_hat(t):
    t.edit_pixels(layer_png(t, "detective", "hat"), lambda rows: flip_first(rows, (97, 56, 10, 255), (20, 20, 19, 255)))


@case("L1-board-raise", ["v2:L1"], ["A12-heart"])
def _l1_raise(t):
    t.look("skateboard")["raiseCells"] = 5
    t.save_atlas()


@case("R3-border-below-baseline", ["v2:R3-bounds", "v2:L1"], ["A12-heart"])
def _r3_border(t):
    t.look("shiny")["raiseCells"] = 0           # the outline's lower edge would lie 2 rows below the feet baseline
    t.save_atlas()


@case("L1-wand-cols", ["v2:L1"], ["A12-heart"])
def _l1_cols(t):
    t.look("wand")["layers"][0]["cut"]["cols"] = [20, 31]
    t.save_atlas()


@case("L1-mug-offset", ["v2:L1"], ["A12-heart"])
def _l1_mug(t):
    t.look("coffee")["layers"][0]["offset"][0] += 1
    t.save_atlas()


@case("L1-class", ["v2:L1"], ["A12-heart"])
def _l1_class(t):
    t.look("detective")["class"] = ["costume"]
    t.save_atlas()


@case("L1-weight", ["v2:L1"], ["A12-heart"])
def _l1_weight(t):
    t.look("shiny")["weight"] = 1
    t.save_atlas()


@case("L1-signature", ["v2:L1"], ["A12-heart"])
def _l1_signature(t):
    t.look("wand")["signature"] = []
    t.save_atlas()


@case("L1-layer-on-signature", ["v2:L1"], ["A12-heart"])
def _l1_los(t):
    t.look("coffee")["layerOnSignature"] = True
    t.save_atlas()


@case("L1-clicks", ["v2:L1"], ["A12-heart"])
def _l1_clicks(t):
    t.look("pool-float")["layers"][0]["takesClicks"] = False
    t.save_atlas()


@case("L1-cut-source", ["v2:L1"], ["A12-heart"])
def _l1_cut_source(t):
    t.look("detective")["layers"][1]["cut"]["frame"] = 21
    t.save_atlas()


@case("L1-rest-picture", ["v2:L1"], ["A12-heart"])
def _l1_rest(t):
    path = layer_png(t, "skateboard", "board")
    rows = read_png(path)
    for row in rows:
        for x, px in enumerate(row):
            if px[3]:
                row[x] = (0, 0, 0, 0)
                write_png(path, rows)
                return


@case("R3-bounds-below-baseline", ["v2:R3-bounds", "v2:L1"], ["A12-heart"])
def _r3_bounds(t):
    t.look("pool-float")["layers"][1]["offset"][1] += 3
    t.save_atlas()


@case("L2-sparkle-on-body", ["v2:L2"], ["A12-heart"])
def _l2_pose(t):
    # the sparkles moved 8 cells down: onto the head and the torso of every v1 pose
    next(l for l in t.look("shiny")["layers"] if l["name"] == "sparkles")["offset"][1] += 8
    t.save_atlas()


@case("R4-sticker-missing", ["v2:R4-provenance", "v2:L1"], ["A12-heart"])
def _r4_missing(t):
    os.remove(os.path.join(t.art, "sources", "sticker", "shiny.png"))


@case("R4-uncited-source", ["v2:R4-provenance"], ["A12-heart"])
def _r4_uncited(t):
    shutil.copy(os.path.join(t.art, "sources", "sticker", "happy.png"), os.path.join(t.art, "sources", "sticker", "stray.png"))


# ---- compatibility (K1) -------------------------------------------------------------------------------------------------------
@case("K1-held-add", ["v2:K1"], ["A4-waving"])
def _k1_held(t):
    t.motion("A4-waving")["compatibleLooks"].append("coffee")
    t.save_atlas()


@case("K1-skate-remove", ["v2:K1"], ["A2-looking"])
def _k1_skate(t):
    t.motion("A2-looking")["compatibleLooks"].remove("skateboard")
    t.save_atlas()


@case("K1-overlay-add", ["v2:K1", "v2:R2-anchor"], ["A10-breakdancing"])
def _k1_overlay(t):
    t.motion("A10-breakdancing")["compatibleLooks"].append("shiny")
    t.save_atlas()


@case("K1-floor", ["v2:K1"], None, checker_edit=("V2_MIN_IDLE = 6 ", "V2_MIN_IDLE = 99 "))
def _k1_floor(t):
    pass


@case("K1-collision-rule", ["v2:K1"], ["D6-heart", "D11-lightbulb"], checker_edit=("if scope and lay[\"z\"] == \"front\":", "if False and lay[\"z\"] == \"front\":"))
def _k1_collision(t):
    pass


# ---- a held prop never floats off the arm: every hand cell under or touching it is Clawd's in every frame --------------------------------
@case("K1-held-detach-A7-mug", ["v2:K1"], ["A7-swaying"])
def _k1_detach_a7(t):
    t.motion("A7-swaying")["compatibleLooks"].append("coffee")        # A7 moves the arm 4 rows: the mug would hang in the air
    t.save_atlas()


@case("K1-held-detach-A8-wand", ["v2:K1"], ["A8-excited"])
def _k1_detach_a8(t):
    t.motion("A8-excited")["compatibleLooks"].append("wand")          # A8 raises the arm away from the wand
    t.save_atlas()


@case("K1-held-detach-A16-magnifier", ["v2:K1"], ["A16-meditating"])
def _k1_detach_a16(t):
    t.motion("A16-meditating")["compatibleLooks"].append("detective")  # A16 folds the arm in front of the body
    t.save_atlas()


@case("K1-held-keeps-still-arm", ["v2:K1"], ["D4-happy"])
def _k1_keeps_still_arm(t):
    t.motion("D4-happy")["compatibleLooks"].remove("coffee")          # the arm never moves in D4: refusing the pair is wrong too
    t.save_atlas()


@case("K1-held-rule-removed", ["v2:K1"], ["A7-swaying", "A8-excited", "A16-meditating", "A2-looking"],
      checker_edit=("                                     or any(not v2_own(C.get((hx + x, hy + y))) for x, y in v2_hand_cells(lay[\"cells\"]))):",
                    "                                     or False):"))
def _k1_held_rule(t):
    pass


# ---- expressions and effects stay visible under a look (K1 rules a and b) -------------------------------------------------------------
@case("K1-eyes-sunglasses-D4", ["v2:K1"], ["D4-happy"])
def _k1_eyes_d4(t):
    t.motion("D4-happy")["compatibleLooks"].append("sunglasses")      # the lenses lie on D4's `> <`
    t.save_atlas()


@case("K1-eyes-pool-glasses-D5", ["v2:K1"], ["D5-dizzy"])
def _k1_eyes_d5(t):
    t.motion("D5-dizzy")["compatibleLooks"].append("pool-float")      # the pool float's sunglasses lie on D5's swirls
    t.save_atlas()


@case("K1-eyes-rule-removed", ["v2:K1"], ["D4-happy", "D5-dizzy"], checker_edit=("eyes = scope and v2_eyes_are_the_point(e)", "eyes = False"))
def _k1_eyes_rule(t):
    pass


@case("K1-effect-D6-heart", ["v2:K1"], ["D6-heart"])
def _k1_effect_d6(t):
    t.motion("D6-heart")["compatibleLooks"].append("headphones")      # the headband lies on the heart beside the head
    t.save_atlas()


@case("K1-effect-D11-bulb", ["v2:K1"], ["D11-lightbulb"])
def _k1_effect_d11(t):
    t.motion("D11-lightbulb")["compatibleLooks"].append("headphones")  # the headband lies on the raised arm and the bulb
    t.save_atlas()


@case("K1-effect-layer-onto-heart", ["v2:K1"], ["D6-heart"])
def _k1_layer_onto_heart(t):
    t.look("sunglasses")["layers"][0]["offset"][1] -= 6                # the lenses moved 6 rows up: onto D6's heart, which the catalog still lists as compatible
    t.save_atlas()


@case("K1-effect-rule-removed", ["v2:K1"], ["D6-heart", "D11-lightbulb"], checker_edit=("if placed & effects or (eye and placed & eye):", "if False:"))
def _k1_effect_rule(t):
    pass


@case("K1-effect-A-item-prop", ["v2:K1"], ["A1-thinking"])
def _k1_effect_a1(t):
    t.motion("A1-thinking")["compatibleLooks"].append("detective")     # the detective's hat lies on A1's thought bubble
    t.save_atlas()


# ---- the border hugs the rest silhouette: only motions whose whole body moves rigidly with the torso may wear it ----------------------------
@case("K1-hug-A7-swaying", ["v2:K1"], ["A7-swaying"])
def _k1_hug_a7(t):
    t.motion("A7-swaying")["compatibleLooks"].append("shiny")          # A7 moves the arms: the outline would not hug them
    t.save_atlas()


@case("K1-hug-A2-looking", ["v2:K1"], ["A2-looking"])
def _k1_hug_a2(t):
    t.motion("A2-looking")["compatibleLooks"].append("shiny")          # the nearest miss: A2 lifts an arm by one cell in 9 frames
    t.save_atlas()


@case("K1-hug-foot-tap", ["v2:K1"], ["B5-foot-tap"])
def _k1_hug_foot(t):
    t.motion("B5-foot-tap")["compatibleLooks"].append("shiny")         # a lifted foot leaves its outline behind
    t.save_atlas()


@case("K1-hug-keeps-glance", ["v2:K1"], ["B3-glance-left"])
def _k1_hug_keeps(t):
    t.motion("B3-glance-left")["compatibleLooks"].remove("shiny")      # the eyes move inside the body: refusing the pair is wrong too
    t.save_atlas()


@case("K1-hug-rule-removed", ["v2:K1"], ["A7-swaying", "A2-looking", "B5-foot-tap"],
      checker_edit=("if lay[\"hugs\"] == \"rest-silhouette\" and {(q[0] - hx, q[1] - hy) for q, c in C.items() if v2_own(c)} != v2_rest_silhouette(st):",
                    "if False:"))
def _k1_hug_rule(t):
    pass


# ---- the calm idle motions (B3, B4, B5) --------------------------------------------------------------------------------------------------
@case("K1-calm-eyes-sunglasses", ["v2:K1"], ["B3-glance-left"])
def _k1_calm_eyes(t):
    t.motion("B3-glance-left")["compatibleLooks"].append("sunglasses")  # the lenses lie on the eyes: a glance would be hidden
    t.save_atlas()


@case("K1-calm-eyes-pool-glasses", ["v2:K1"], ["B4-wink"])
def _k1_calm_wink(t):
    t.motion("B4-wink")["compatibleLooks"].append("pool-float")        # the pool float's sunglasses lie on the wink
    t.save_atlas()


@case("K1-calm-foot-keeps-sunglasses", ["v2:K1"], ["B5-foot-tap"])
def _k1_calm_foot_glasses(t):
    t.motion("B5-foot-tap")["compatibleLooks"].remove("sunglasses")    # a foot tap is not an eye expression: the lenses hide nothing
    t.save_atlas()


@case("K1-calm-foot-skateboard", ["v2:K1"], ["B5-foot-tap"])
def _k1_calm_foot_board(t):
    t.motion("B5-foot-tap")["compatibleLooks"].append("skateboard")    # a lifted foot leaves the board
    t.save_atlas()


@case("K1-calm-held-keeps-coffee", ["v2:K1"], ["B4-slow-blink"])
def _k1_calm_held(t):
    t.motion("B4-slow-blink")["compatibleLooks"].remove("coffee")      # the arm never moves: the mug stays in the hand
    t.save_atlas()


@case("R1-body-glance-eye", ["v2:R1-body"], ["B3-glance-left"])
def _r1_glance(t):
    def move(rows):
        x, y = first_pixel(rows, EYE)
        rows[y][x] = BODY                       # one cell of one eye missing: not the look-left eyes of render-core.js
    t.edit_pixels(t.frame("B3-glance-left", 6), move)


@case("R1-body-glance-wrong-way", ["v2:R1-body"], ["B3-glance-right"])
def _r1_wrong_way(t):
    t.motion("B3-glance-right")["redraw"]["changes"] = ["eyes:look-left"]   # declared left, drawn right
    t.save_atlas()


@case("R1-body-wink-never-drawn", ["v2:R1-body"], ["B4-wink"])
def _r1_wink_never(t):
    t.motion("B4-wink")["redraw"]["changes"] = ["eyes:closed"]        # declares both eyes closed, only one ever is
    t.save_atlas()


@case("R1-body-foot-third-leg", ["v2:R1-body"], ["B5-foot-tap"])
def _r1_third_leg(t):
    def hole(rows):
        rows[-2][14] = (0, 0, 0, 0)             # a third leg shortened (canvas cell (14, 22)): one foot up means the two left legs only
    t.edit_pixels(t.frame("B5-foot-tap", 5), hole)


@case("R1-body-foot-undeclared", ["v2:R1-body"], ["B3-glance-left"])
def _r1_foot_undeclared(t):
    t.motion("B3-glance-left")["redraw"]["changes"] = ["eyes:look-left", "legs:left-up"]
    t.save_atlas()


@case("P7-pose-sha", ["v2:P7"], ["B4-wink"])
def _p7_pose_sha(t):
    t.motion("B4-wink")["source"]["sha256"] = "0" * 64
    t.save_atlas()


@case("P7-pose-bytes", ["v2:P7", "v2:R4-provenance"], ["B4-wink"])
def _p7_pose_bytes(t):
    with open(os.path.join(t.art, "sources", "claude-code", "render-core.js"), "ab") as f:
        f.write(b"\n")


@case("R4-pose-lines", ["v2:P7", "v2:R4-provenance"], ["B5-foot-tap"])
def _r4_pose_lines(t):
    t.motion("B5-foot-tap")["source"]["lines"] = ["3", "139-152"]      # the pixel rules of lines 107-125 are no longer cited
    t.save_atlas()


@case("R4-pose-vocabulary", ["v2:R4-provenance"], ["B4-slow-blink"])
def _r4_pose_vocabulary(t):
    # the cited file no longer has the `closed` eye glyphs on line 3 (its sha256 is re-recorded, so only the vocabulary check can see it)
    import hashlib
    path = os.path.join(t.art, "sources", "claude-code", "render-core.js")
    text = open(path, encoding="utf-8").read()
    assert 'closed:[{glyphs:"\u2582",lid:!0}' in text
    text = text.replace('closed:[{glyphs:"\u2582",lid:!0}', 'closed:[{glyphs:"X",lid:!0}', 1)
    open(path, "w", encoding="utf-8").write(text)
    sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
    for m in t.atlas["motions"]:
        if m["source"].get("path") == "sources/claude-code/render-core.js":
            m["source"]["sha256"] = sha
    t.save_atlas()


@case("U1-calm-use", ["v2:U1"], ["B3-glance-left"])
def _u1_calm(t):
    t.motion("B3-glance-left")["uses"].append("touch")
    t.save_atlas()


@case("P6-calm-ms", ["v2:P6"], ["B4-wink"])
def _p6_calm(t):
    t.motion("B4-wink")["ms"][3] += 1
    t.save_atlas()


@case("P2-calm-flag", ["v2:P2"], ["B4-slow-blink"])
def _p2_calm(t):
    t.motion("B4-slow-blink")["restEnd"] = False
    t.save_atlas()


# ---- Sprint 7 item 1: the two checker gaps Codex found (spec 9b item 10) -----------------------------------------------------------
# (a) a redrawn motion's first frame, and its last unless the spec justifies a hold, equal the rest frame by pixels: the flags decide nothing.
#     Each construction keeps every flag honest (P2 passes: restStart/restEnd say exactly what the pixels say) so that only v2:P8-redrawn-rest
#     can refuse it; the -rule-removed twin runs the same tree through a checker copy with that line cut out and must exit 0 (the control
#     depends on the rule, not on something else the tree breaks).
def _closed_over(t, mid, src, dst):
    shutil.copyfile(t.frame(mid, src), t.frame(mid, dst))


def _slow_blink_starts_closed(t):
    _closed_over(t, "B4-slow-blink", 6, 0)                 # frame 6 is a closed-eye frame; frame 0 was the rest frame
    t.motion("B4-slow-blink")["restStart"] = False
    t.save_atlas()


def _slow_blink_ends_closed_on_a_hold(t):
    _closed_over(t, "B4-slow-blink", 6, 13)
    m = t.motion("B4-slow-blink")
    m["restEnd"] = False
    m["hold"] = True                                       # a hold nothing in the spec justifies for a redrawn item
    t.save_atlas()


FIRST_FRAME_RULE = ("if v2_frame_cells(st, e, 0) != st[\"rest\"]:", "if False:")
LAST_FRAME_RULE = ("if v2_frame_cells(st, e, last) != st[\"rest\"] and not (e.get(\"hold\") is True and mid in V2_SPEC_HOLDS):", "if False:")


@case("P8-first-frame-closed-eyes", ["v2:P8-redrawn-rest"], ["B4-slow-blink"])
def _p8_first(t):
    _slow_blink_starts_closed(t)


@case("P8-first-frame-rule-removed", [], ["B4-slow-blink"], checker_edit=FIRST_FRAME_RULE)
def _p8_first_removed(t):
    _slow_blink_starts_closed(t)


@case("P8-last-frame-hold", ["v2:P8-redrawn-rest"], ["B4-slow-blink"])
def _p8_last(t):
    _slow_blink_ends_closed_on_a_hold(t)


@case("P8-last-frame-rule-removed", [], ["B4-slow-blink"], checker_edit=LAST_FRAME_RULE)
def _p8_last_removed(t):
    _slow_blink_ends_closed_on_a_hold(t)


# (b) no motion or look pixel below the feet baseline (canvas cell row 23) except the skateboard's board. Codex's construction: a heart pixel
#     seven cells under the baseline, with the stage.down that makes P4 and P1 agree with it.
def _heart_seven_cells_under_the_baseline(t):
    m = t.motion("D6-heart")
    for k in range(len(m["frames"])):
        path = t.frame("D6-heart", k)
        rows = read_png(path)
        w = len(rows[0])
        rows += [[(0, 0, 0, 0)] * w for _ in range(7)]
        if k == 8:
            rows[23 + 7][22] = (233, 69, 68, 255)           # the official heart red, column 22, row 30
        write_png(path, rows)
    m["stage"]["down"] = 3.5
    t.save_atlas()


@case("R3-baseline-heart-below", ["v2:R3-baseline"], ["D6-heart"])
def _r3_heart(t):
    _heart_seven_cells_under_the_baseline(t)


@case("R3-baseline-rule-removed", [], ["D6-heart"], checker_edit=("if q[1] > V2_BASELINE_ROW)", "if False)"))
def _r3_heart_removed(t):
    _heart_seven_cells_under_the_baseline(t)


@case("R3-baseline-layer-offset", ["v2:R3-baseline", "v2:L1"], ["A12-heart"])
def _r3_layer(t):
    t.look("coffee")["layers"][0]["offset"][1] += 14       # the mug 14 cells lower: its lowest cell lies below the baseline at the rest placement
    t.save_atlas()


# ---- catalog and files --------------------------------------------------------------------------------------------------------
@case("C1-motion-missing", ["v2:C1"], ["A12-heart"])
def _c1_missing(t):
    t.atlas["motions"] = [m for m in t.atlas["motions"] if m["id"] != "D5-dizzy"]
    t.save_atlas()


@case("C1-look-missing", ["v2:C1"], ["A12-heart"])
def _c1_look(t):
    t.atlas["looks"] = [l for l in t.atlas["looks"] if l["id"] != "skateboard"]
    t.save_atlas()


@case("C1-phase", ["v2:C1"], ["A12-heart"])
def _c1_phase(t):
    t.motion("D4-happy")["phase"] = 1
    t.save_atlas()


@case("C2-orphan", ["v2:C2"], ["A12-heart"])
def _c2_orphan(t):
    shutil.copy(layer_png(t, "pool-float", "ring-back"), os.path.join(t.art, "looks", "pool-float", "extra.png"))


@case("V5-sheet", ["v2:V5"], ["A12-heart"])
def _v5(t):
    os.remove(os.path.join(t.art, "preview", "v2", "contact-sheet-phase2.png"))


@case("G1-goldens", ["v2:G1"], ["A12-heart"], goldens=False)
def _g1(t):
    pass


# ---- running -------------------------------------------------------------------------------------------------------------------
# ---- D14 ride: the skateboard's glide (amendment "the skateboard ride") ---------------------------------------------------------------
BOARD_DARK, BOARD_GOLD = (86, 27, 47, 255), (239, 172, 84, 255)


@case("D14-ride-first-frame-board-differs", ["v2:D14-ride", "v2:P1"], ["D14-ride"])
def _ride_first_board(t):
    t.edit_pixels(t.frame("D14-ride", 0), lambda rows: flip_first(rows, BOARD_DARK, BOARD_GOLD))      # R2-1: the first frame carries the rest picture's board


@case("D14-ride-last-frame-board-edit-missing", ["v2:D14-ride", "v2:P1"], ["D14-ride"])
def _ride_last_board(t):
    def feet_on_the_deck(rows):
        rows[24][17] = BODY                       # sprite frame 61 has a foot on the deck here; the edit rule gives the rest picture's deck cell back
    t.edit_pixels(t.frame("D14-ride", 38), feet_on_the_deck)


@case("D14-ride-stored-at-the-wrong-height", ["v2:D14-ride"], ["D14-ride"])
def _ride_store(t):
    t.motion("D14-ride")["source"]["store"] = [0, 0]          # R3-2: stored at y - 5 the board would sit six cells high once the compositor lifts it
    t.save_atlas()


@case("D14-ride-segment-misplaced", ["v2:D14-ride"], ["D14-ride"])
def _ride_segment(t):
    t.motion("D14-ride")["segments"][2]["frames"] = [15, 20]
    t.save_atlas()


@case("D14-ride-in-a-pool", ["v2:D14-ride", "v2:U1"], ["D14-ride"])
def _ride_pool(t):
    t.motion("D14-ride")["uses"] = ["ride", "idle"]           # no idle or reaction pool picks the ride
    t.save_atlas()


@case("D14-ride-storage-down-missing", ["v2:P4"], ["D14-ride"])
def _ride_down(t):
    t.motion("D14-ride")["stage"]["down"] = 2                  # R4-1: the frames are stored 3 units below the canvas
    t.save_atlas()


@case("D14-ride-board-layer-on", ["v2:L1", "v2:D14-ride"], ["D14-ride"])
def _ride_layer_on(t):
    t.look("skateboard")["layerOnSignature"] = True            # R2-4: the frames carry their own board, the look's layer would draw a second one
    t.save_atlas()


@case("D14-ride-not-the-looks-signature", ["v2:L1", "v2:D14-ride"], ["D14-ride"])
def _ride_signature(t):
    t.look("skateboard")["signature"] = []
    t.save_atlas()


def run_case(c):
    with tempfile.TemporaryDirectory(prefix="clawd-art-mutation2-") as tmp:
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
            goldens = GOLDENS if c["goldens"] else os.path.join(tmp, "no-goldens")
            if not c["goldens"]:
                os.makedirs(goldens)
            cmd = [sys.executable, "-I", checker, "--art", t.art, "--phase", "2", "--goldens", goldens]
            if c["motions"]:
                cmd += ["--motions", ",".join(c["motions"])]
            r = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT, timeout=600)
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
    print("phase2-mutations: pass=%d fail=%d" % (len(cases) - bad, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
