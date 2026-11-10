"""Build art/preview/index.html from the extracted elements + atlas.

Usage: python3 -I build_preview.py <art_dir>

Reads  <art>/claude-code-elements.json, <art>/clawd-atlas.json,
       <art>/tools/preview_template.html
Writes <art>/preview/index.html and copies the 4x PNGs to <art>/preview/frames4x/.
The page embeds the data inline; the only external files are the PNGs next to it.
"""
import json
import os
import shutil
import sys

ART = sys.argv[1]
el = json.load(open(os.path.join(ART, "claude-code-elements.json"), encoding="utf-8"))
atlas = json.load(open(os.path.join(ART, "clawd-atlas.json"), encoding="utf-8"))
# schema 2 appends `schema`, `motions` and `looks`; the v1 preview shows and embeds the v1 keys only
atlas = {k: atlas[k] for k in ("unit", "canvas", "palette", "scale4x_dir", "poses")}
tpl = open(os.path.join(ART, "tools", "preview_template.html"), encoding="utf-8").read()

resp = next(c for c in el["interrupt"]["prefix"] if ord(c) == 0x23BF)
theme_keys = ["claude", "claudeShimmer", "promptBorder", "inactive", "error", "text", "subtle"]
slim = {
    "version": el["_meta"]["claude_code_version"],
    "glyphs": el["spinner_glyphs"]["default_sequence"],
    "glyphOffset": el["spinner_glyphs"]["offset"],
    "clockTickMs": el["spinner_timing"]["clock_tick_ms"]["value"],
    "periodMs": el["spinner_timing"]["frame_index_formula"]["period_ms"],
    "shimmerStepMs": el["verb_shimmer"]["modes"]["requesting"]["step_ms"],
    "shimmerPad": el["verb_shimmer"]["pad_cols"],
    "verbs": el["present_verbs"]["values"],
    "verbsOffset": el["present_verbs"]["offset"],
    "pastVerbs": el["past_verbs"]["values"],
    "pastOffset": el["past_verbs"]["offset"],
    "doneGlyph": el["turn_complete_line"]["prefix_glyph"],
    "respGlyph": resp,
    "interrupt": el["interrupt"]["string"],
    "promptChar": el["input_box"]["prompt_char"],
    "theme": {k: el["theme_colors_dark"]["values"][k] for k in theme_keys},
}
data = {"atlas": atlas, "elements": slim}
blob = json.dumps(data, ensure_ascii=False).replace("</", "<\\/").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
assert "/*__DATA__*/null" in tpl
html = tpl.replace("/*__DATA__*/null", blob)
rows = []
for pname, pose in atlas["poses"].items():
    figs = "".join(
        '<figure><img src="frames4x/%s" alt="%s frame %d"><figcaption>%d ms</figcaption></figure>'
        % (os.path.basename(fr), pname, i, pose["ms"][i])
        for i, fr in enumerate(pose["frames"])
    )
    rows.append('<div class="frow"><div class="name">%s<small>%d frame%s, %s</small></div>%s</div>'
                % (pname, len(pose["frames"]), "" if len(pose["frames"]) == 1 else "s", "loop" if pose["loop"] else "plays once", figs))
assert "<!--__FRAMES__-->" in html
html = html.replace("<!--__FRAMES__-->", "".join(rows))

pv = os.path.join(ART, "preview")
os.makedirs(os.path.join(pv, "frames4x"), exist_ok=True)
copied = 0
for pose in atlas["poses"].values():
    for fr in pose["frames"]:
        name = os.path.basename(fr)
        shutil.copyfile(os.path.join(ART, "frames4x", name), os.path.join(pv, "frames4x", name))
        copied += 1
with open(os.path.join(pv, "index.html"), "w", encoding="utf-8") as f:
    f.write(html)
print("wrote", os.path.join(pv, "index.html"), len(html), "bytes;", copied, "PNGs copied")
