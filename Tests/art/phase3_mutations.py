#!/usr/bin/env python3
"""Mutation controls for `scripts/check-art-contract.py --phase 3` (Sprint 7: the plushie looks wizard, cowboy and scientist, D19's `^ ^`, the D18
comparison of the phase 1 sunglasses; spec v2 section 3.1: P1-P7, R1-R4, K1, G1 and the checks around them).

Usage:  python3 -I Tests/art/phase3_mutations.py [--jobs N] [--list] [--only ID ...]

Every case copies the art tree into a temporary directory, breaks one rule in the copy, runs the checker (--phase 3) against the copy and requires that
the named check FAILs. The identity case breaks nothing and requires exit 0; a case with an empty list and a `checker_edit` runs a tree that breaks a rule
through a checker copy with that rule cut out and requires exit 0 too. One line per case:
  PASS <ID>
  FAIL <ID> -- <why>
and a last line `phase3-mutations: pass=N fail=M`. The real art tree and the real goldens are never written.
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


def layer(t, lid, name):
    return next(l for l in t.look(lid)["layers"] if l["name"] == name)


def layer_png(t, lid, name):
    return os.path.join(t.art, layer(t, lid, name)["png"])


def set_pixel(path, colour, new):
    rows = read_png(path)
    x, y = first_pixel(rows, colour)
    rows[y][x] = new
    write_png(path, rows)


@case("identity", [])
def _identity(t):
    pass


# ---- the three looks: layers re-derived from the photographs --------------------------------------------------------------------
@case("L1-wizard-hat-pixel", ["v2:L1"], ["D19-happy-caret"])
def _l1_hat(t):
    set_pixel(layer_png(t, "wizard", "hat"), (7, 13, 35, 255), (1, 2, 3, 255))        # a band pixel recoloured


@case("L1-wizard-star-colour", ["v2:L1"], ["D19-happy-caret"])
def _l1_star(t):
    set_pixel(layer_png(t, "wizard", "hat"), (216, 197, 0, 255), (216, 198, 0, 255))


@case("L1-wizard-wand-pixel-missing", ["v2:L1"], ["D19-happy-caret"])
def _l1_wand(t):
    set_pixel(layer_png(t, "wizard", "wand"), (165, 96, 53, 255), (0, 0, 0, 0))


@case("L1-cowboy-band-colour", ["v2:L1"], ["D19-happy-caret"])
def _l1_band(t):
    set_pixel(layer_png(t, "cowboy", "hat"), (89, 75, 71, 255), (90, 75, 71, 255))


@case("L1-scientist-flask-pixel", ["v2:L1"], ["D19-happy-caret"])
def _l1_flask(t):
    set_pixel(layer_png(t, "scientist", "flask"), (0, 150, 194, 255), (0, 150, 195, 255))


@case("L1-scientist-coat-pixel", ["v2:L1"], ["D19-happy-caret"])
def _l1_coat(t):
    set_pixel(layer_png(t, "scientist", "coat"), (72, 72, 69, 255), (0, 0, 0, 0))


@case("L1-role-rect", ["v2:L1"], ["D19-happy-caret"])
def _l1_rect(t):
    layer(t, "cowboy", "hat")["cut"]["roles"]["b"]["rect"][0] += 1      # another patch of the photograph than the spec's


@case("L1-role-colour", ["v2:L1"], ["D19-happy-caret"])
def _l1_role(t):
    layer(t, "wizard", "hat")["cut"]["roles"]["b"]["rgb"][2] += 1       # not the mean of its patch


@case("L1-goggle-black-not-pet-eye", ["v2:L1"], ["D19-happy-caret"])
def _l1_black(t):
    layer(t, "scientist", "goggles")["cut"]["roles"]["k"]["rgb"] = [15, 14, 14]     # the photograph's black instead of the pet's near-black


@case("L1-picture-sha", ["v2:L1"], ["D19-happy-caret"])
def _l1_sha(t):
    layer(t, "wizard", "hat")["cut"]["sha256"] = "0" * 64


@case("L1-picture-bytes", ["v2:L1", "v2:R4-provenance"], ["D19-happy-caret"])
def _l1_bytes(t):
    with open(os.path.join(t.art, "sources", "plush", "wizard.png"), "ab") as f:
        f.write(b"\0")


@case("L1-wizard-signature", ["v2:L1"], ["D19-happy-caret"])
def _l1_signature(t):
    t.look("wizard")["signature"] = ["A25-spark"]


@case("L1-scientist-class", ["v2:L1"], ["D19-happy-caret"])
def _l1_class(t):
    t.look("scientist")["class"] = ["costume", "held"]


@case("L1-scientist-on-signature", ["v2:L1"], ["D19-happy-caret"])
def _l1_on(t):
    t.look("scientist")["layerOnSignature"] = False


@case("L1-wizard-on-signature", ["v2:L1"], ["D19-happy-caret"])
def _l1_wizard_on(t):
    t.look("wizard")["layerOnSignature"] = False


@case("L1-cowboy-weight", ["v2:L1"], ["D19-happy-caret"])
def _l1_weight(t):
    t.look("cowboy")["weight"] = 0.5


@case("L1-flask-attach", ["v2:L1"], ["D19-happy-caret"])
def _l1_attach(t):
    layer(t, "scientist", "flask")["attach"] = "head"


@case("L1-rows-edited", ["v2:L1"], ["D19-happy-caret"])
def _l1_rows(t):
    rows = layer(t, "cowboy", "hat")["cut"]["rows"]
    rows[3] = rows[3][:5] + "g" + rows[3][6:]                           # the declared pattern is no longer the spec's


# ---- bounds ----------------------------------------------------------------------------------------------------------------------
@case("R3-cowboy-hat-too-high", ["v2:R3-bounds", "v2:L1"], ["D19-happy-caret"])
def _r3_high(t):
    layer(t, "cowboy", "hat")["offset"][1] -= 2                         # the hat 2 cells higher: 10 cells above the torso, 5 units, the limit is 4


@case("R3-baseline-wizard-hat-below", ["v2:R3-baseline", "v2:L1"], ["D19-happy-caret"])
def _r3_below(t):
    layer(t, "wizard", "hat")["offset"][1] += 16


@case("R3-baseline-flask-below", ["v2:R3-baseline", "v2:L1"], ["D19-happy-caret"])
def _r3_flask(t):
    layer(t, "scientist", "flask")["offset"][1] += 16


# ---- K1: held looks keep the prop in the hand, no layer on the eyes of an eye expression -------------------------------------------
@case("K1-held-detach-A7-wizard", ["v2:K1"], ["A7-swaying"])
def _k1_held(t):
    t.motion("A7-swaying")["compatibleLooks"].append("wizard")          # the arm sways away from the wand's hand


@case("K1-held-detach-A8-scientist", ["v2:K1"], ["A8-excited"])
def _k1_held2(t):
    t.motion("A8-excited")["compatibleLooks"].append("scientist")


@case("K1-cowboy-lost-glance", ["v2:K1"], ["B3-glance-left"])
def _k1_lost(t):
    t.motion("B3-glance-left")["compatibleLooks"].remove("cowboy")       # a compatible pair left out


@case("K1-D19-sunglasses", ["v2:K1"], ["D19-happy-caret"])
def _k1_d19(t):
    t.motion("D19-happy-caret")["compatibleLooks"].append("sunglasses")  # the lenses lie on the `^ ^`


@case("K1-D19-pool-float", ["v2:K1"], ["D19-happy-caret"])
def _k1_d19_pool(t):
    t.motion("D19-happy-caret")["compatibleLooks"].append("pool-float")


@case("K1-floor-plushies", ["v2:K1"], None, checker_edit=("V2_MIN_IDLE = 6 ", "V2_MIN_IDLE = 99 "))
def _k1_floor(t):
    pass


# ---- D19 -------------------------------------------------------------------------------------------------------------------------
@case("R1-caret-eye-moved", ["v2:R1-body"], ["D19-happy-caret"])
def _r1_caret(t):
    def move(rows):
        x, y = first_pixel(rows, EYE)
        rows[y][x] = BODY
    t.edit_pixels(t.frame("D19-happy-caret", 5), move)


@case("R1-caret-source", ["v2:R1-body"], ["D19-happy-caret"])
def _r1_source(t):
    t.motion("D19-happy-caret")["redraw"]["glyph"]["frame"] = 8


@case("R1-caret-declared-as-chevrons", ["v2:R1-body"], ["D19-happy-caret"])
def _r1_chevrons(t):
    t.motion("D19-happy-caret")["redraw"]["changes"] = ["eyes:chevrons"]


@case("P8-D19-first-frame", ["v2:P8-redrawn-rest"], ["D19-happy-caret"])
def _p8_d19(t):
    shutil.copyfile(t.frame("D19-happy-caret", 5), t.frame("D19-happy-caret", 0))
    t.motion("D19-happy-caret")["restStart"] = False


@case("P8-D19-first-frame-rule-removed", [], ["D19-happy-caret"],
      checker_edit=("if v2_frame_cells(st, e, 0) != st[\"rest\"]:", "if False:"))
def _p8_d19_removed(t):
    shutil.copyfile(t.frame("D19-happy-caret", 5), t.frame("D19-happy-caret", 0))
    t.motion("D19-happy-caret")["restStart"] = False


@case("R3-baseline-D19-pixel-below", ["v2:R3-baseline"], ["D19-happy-caret"])
def _r3_d19(t):
    m = t.motion("D19-happy-caret")
    for k in range(len(m["frames"])):
        path = t.frame("D19-happy-caret", k)
        rows = read_png(path)
        rows += [[(0, 0, 0, 0)] * len(rows[0]) for _ in range(7)]
        if k == 8:
            rows[23 + 7][22] = EYE                                       # an eye-coloured pixel seven cells under the baseline
        write_png(path, rows)
    m["stage"]["down"] = 3.5
    t.save_atlas()


@case("P7-D19-source", ["v2:P7"], ["D19-happy-caret"])
def _p7_d19(t):
    t.motion("D19-happy-caret")["source"]["picture"] = "sources/plush/wizard"


@case("P7-D19-bytes", ["v2:P7", "v2:R4-provenance"], ["D19-happy-caret"])
def _p7_bytes(t):
    with open(os.path.join(t.art, "sources", "plush", "happy.png"), "ab") as f:
        f.write(b"\0")


@case("U1-D19-uses", ["v2:U1"], ["D19-happy-caret"])
def _u1_d19(t):
    t.motion("D19-happy-caret")["uses"].append("idle")


@case("C1-D19-phase", ["v2:C1"], ["D19-happy-caret"])
def _c1_phase(t):
    t.motion("D19-happy-caret")["phase"] = 2


@case("H1-D19-head", ["v2:H1"], ["D19-happy-caret"])
def _h1_d19(t):
    t.motion("D19-happy-caret")["head"][4] = [13, 8]


@case("P6-D19-ms", ["v2:P6"], ["D19-happy-caret"])
def _p6_d19(t):
    t.motion("D19-happy-caret")["ms"][2] += 1


# ---- D18: the phase 1 sunglasses against the plushie's -------------------------------------------------------------------------------
@case("D18-report-number", ["v2:D18"], ["D19-happy-caret"])
def _d18_number(t):
    path = os.path.join(t.art, "reports", "plush-sunglasses-comparison.json")
    rep = json.load(open(path, encoding="utf-8"))
    rep["plush"]["width"] += 1
    json.dump(rep, open(path, "w", encoding="utf-8"))


@case("D18-report-verdict", ["v2:D18"], ["D19-happy-caret"])
def _d18_verdict(t):
    path = os.path.join(t.art, "reports", "plush-sunglasses-comparison.json")
    rep = json.load(open(path, encoding="utf-8"))
    rep["verdict"] = "differ"
    json.dump(rep, open(path, "w", encoding="utf-8"))


@case("D18-rules", ["v2:D18"], ["D19-happy-caret"])
def _d18_rules(t):
    path = os.path.join(t.art, "reports", "plush-sunglasses-comparison.json")
    rep = json.load(open(path, encoding="utf-8"))
    rep["rules"]["widthTolerance"] = 5.0                                 # a looser rule than the pinned one
    json.dump(rep, open(path, "w", encoding="utf-8"))


@case("D18-picture-bytes", ["v2:D18", "v2:R4-provenance"], ["D19-happy-caret"])
def _d18_bytes(t):
    with open(os.path.join(t.art, "sources", "plush", "sunglasses.png"), "ab") as f:
        f.write(b"\0")


@case("D18-glasses-not-a-bar", ["v2:D18", "v2:L1"], ["D19-happy-caret"])
def _d18_glasses(t):
    path = layer_png(t, "sunglasses", "lenses")
    rows = read_png(path)
    rows[0] = [(0, 0, 0, 0)] * len(rows[0])                              # the top bar removed: two lenses and no bar
    write_png(path, rows)


# ---- catalog and files ----------------------------------------------------------------------------------------------------------
@case("C1-look-missing", ["v2:C1"], ["D19-happy-caret"])
def _c1_look(t):
    t.atlas["looks"] = [l for l in t.atlas["looks"] if l["id"] != "scientist"]
    t.save_atlas()


@case("C1-motion-missing", ["v2:C1"], ["D19-happy-caret"])
def _c1_motion(t):
    t.atlas["motions"] = [m for m in t.atlas["motions"] if m["id"] != "D19-happy-caret"]
    t.save_atlas()


@case("C2-orphan", ["v2:C2"], ["D19-happy-caret"])
def _c2_orphan(t):
    shutil.copy(layer_png(t, "cowboy", "hat"), os.path.join(t.art, "looks", "cowboy", "extra.png"))


@case("R4-plush-uncited", ["v2:R4-provenance"], ["D19-happy-caret"])
def _r4_uncited(t):
    shutil.copy(os.path.join(t.art, "sources", "plush", "happy.png"), os.path.join(t.art, "sources", "plush", "extra.png"))


@case("V5-sheet-phase3", ["v2:V5"], ["D19-happy-caret"])
def _v5(t):
    os.remove(os.path.join(t.art, "preview", "v2", "contact-sheet-phase3.png"))


@case("G1-goldens", ["v2:G1"], ["D19-happy-caret"], goldens=False)
def _g1(t):
    pass


# ---- Sprint 8 item 1: the three checker rules Codex asked for (spec 9b item 12) ---------------------------------------------------------
# Each rule has constructions that only it can refuse and a `-rule-removed` twin: the same tree through a checker copy with that rule cut out must
# exit 0, so the control depends on the rule and on nothing else the tree breaks.
# (a) a layer's render anchor is unset or head; feet only for an under-feet look. Codex's construction: a "canvas" anchor on the scientist's flask, which
#     K1 and R3 place by `attach` (the hand) while StageCompose.swift would draw it at the layer's offset from the canvas.
ANCHOR_RULE = ("ok = (anchor in V2_RENDER_ANCHORS and attach != \"feet\") or (anchor == \"feet\" and attach == \"feet\" and under_feet)", "ok = True")


@case("L3-anchor-canvas-flask", ["v2:L3-anchor"], ["D19-happy-caret"])
def _l3_flask(t):
    layer(t, "scientist", "flask")["anchor"] = "canvas"


@case("L3-anchor-canvas-flask-rule-removed", [], ["D19-happy-caret"], checker_edit=ANCHOR_RULE)
def _l3_flask_removed(t):
    layer(t, "scientist", "flask")["anchor"] = "canvas"


@case("L3-anchor-canvas-helmet", ["v2:L3-anchor"], ["D19-happy-caret"])
def _l3_helmet(t):
    t.look("helmet")["layers"][0]["anchor"] = "canvas"             # a phase 1 look: no spec table pins its layers, only this rule sees the anchor


@case("L3-anchor-feet-on-a-hat", ["v2:L3-anchor"], ["D19-happy-caret"])
def _l3_feet_hat(t):
    layer(t, "cowboy", "hat")["anchor"] = "feet"                   # feet is for the under-feet look only (and then for the feet-attached layer)


@case("L3-anchor-head-written-out", [], ["D19-happy-caret"])
def _l3_head_ok(t):
    layer(t, "cowboy", "hat")["anchor"] = "head"                   # an explicit head anchor is the same as none: nothing to refuse


# (b) a bodyColor map only where the spec declares a body colour (Ultra and winter, phase 4; shiny does not), never on the eye colour. Codex's
#     construction: a bodyColor on the cowboy that maps the eye colour to the body colour.
BODYCOLOR_RULE = ("def v2_body_colours():\n    st = v2_state()", "def v2_body_colours():\n    return [], \"cut\"\n    st = v2_state()")


def _cowboy_eye_to_body(t):
    t.look("cowboy")["bodyColor"] = {"map": [{"from": [20, 20, 19], "to": [215, 119, 87]}]}


@case("L4-bodycolor-cowboy-eye-to-body", ["v2:L4-bodycolor"], ["D19-happy-caret"])
def _l4_eye(t):
    _cowboy_eye_to_body(t)


@case("L4-bodycolor-cowboy-eye-to-body-rule-removed", [], ["D19-happy-caret"], checker_edit=BODYCOLOR_RULE)
def _l4_eye_removed(t):
    _cowboy_eye_to_body(t)


@case("L4-bodycolor-cowboy-recolour", ["v2:L4-bodycolor"], ["D19-happy-caret"])
def _l4_recolour(t):
    t.look("cowboy")["bodyColor"] = {"map": [{"from": [215, 119, 87], "to": [10, 200, 90]}]}      # the eyes untouched, but the spec declares no body colour for the cowboy


@case("L4-bodycolor-shiny", ["v2:L4-bodycolor"], ["D19-happy-caret"])
def _l4_shiny(t):
    t.look("shiny")["bodyColor"] = {"map": [{"from": [215, 119, 87], "to": [244, 232, 190]}]}     # shiny keeps Clawd's own colours (Sprint 5 round 3)


# (c) the composite baseline: a (look, motion) pair is compatible only if the look's layers placed on the motion's frames reach no cell below the
#     feet baseline. A15 Snooze's head sits 5 rows low, so the helmet's dome, the pool float's ring and the wand hang under the canvas while Clawd falls asleep.
BASELINE_RULE = ("    return v2_baseline_ok(st, l, heads)       # K1-composite-baseline", "    return True")


def _list_look(t, mid, lid):
    m = t.motion(mid)
    m["compatibleLooks"] = list(m["compatibleLooks"]) + [lid]


@case("K1-baseline-helmet-snooze", ["v2:K1"], ["A15-snooze"])
def _k1_helmet(t):
    _list_look(t, "A15-snooze", "helmet")                          # 3 rows of the dome under the baseline


@case("K1-baseline-snooze-rule-removed", [], ["A15-snooze"], checker_edit=BASELINE_RULE)
def _k1_helmet_removed(t):
    # the three looks the rule takes the sleep entry from; without the rule they are compatible (listed in catalog order, which K1 compares)
    t.motion("A15-snooze")["compatibleLooks"] = ["plain", "helmet", "sunglasses", "headphones", "pool-float", "wand", "skateboard"]


@case("K1-baseline-pool-float-snooze", ["v2:K1"], ["A15-snooze"])
def _k1_pool(t):
    _list_look(t, "A15-snooze", "pool-float")


@case("K1-baseline-wand-snooze", ["v2:K1"], ["A15-snooze"])
def _k1_wand(t):
    _list_look(t, "A15-snooze", "wand")                            # one row: the smallest dip is refused too


@case("K1-baseline-pool-float-meditating", ["v2:K1"], ["A16-meditating"])
def _k1_meditating(t):
    _list_look(t, "A16-meditating", "pool-float")                  # a dip of 2 against the ring's room of 1 cell


@case("K1-baseline-pool-float-room-is-one-cell", ["v2:K1", "v2:L1"], ["A2-looking"])
def _k1_room(t):
    t.look("pool-float")["raiseCells"] = 6                         # the ring back on the baseline: A2's dip of 1 hangs it under (L1 pins the lift)


@case("K1-baseline-floor-of-the-lifted-looks-holds", [], None)
def _k1_floor_holds(t):
    pass                                                           # the unmutated tree: every look keeps its 6 compatible idle motions under the new rule


# ---- running -------------------------------------------------------------------------------------------------------------------
def run_case(c):
    with tempfile.TemporaryDirectory(prefix="clawd-art-mutation3-") as tmp:
        try:
            t = Tree(tmp)
            c["fn"](t)
            t.save_atlas()                                    # the cases edit t.atlas in memory; the checker reads the file
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
            cmd = [sys.executable, "-I", checker, "--art", t.art, "--phase", "3", "--goldens", goldens]
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
    print("phase3-mutations: pass=%d fail=%d" % (len(cases) - bad, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
