# Provenance: the slug values in ChatResumeTests

`ChatResume_slugIsTheCLIsRuleWithTheLongPathHash` compares `ChatResume.slug` with values computed by hand (a short Python script run once,
not part of the suite) from Claude Code 2.1.316's rule, read as text from `~/.local/share/claude/versions/2.1.316` (the binary was never run):

- cc@252201431, `EL(e)`: `n = k(e)` (every character outside `[a-zA-Z0-9]` becomes `-`); a result of 200 units or fewer is the folder name; longer,
  the first 200 units, `-`, then `Pe(e)` (base 36 of the absolute value of the hash below).
- cc@251225573, `Zhe(t)`: `e = 0; for each UTF-16 unit c of t: e = (e << 5) - e + c | 0` (32-bit wrap).
- JavaScript counts UTF-16 units, so a character outside the BMP becomes two `-`.

Values: `/Users/tomtim` -> `-Users-tomtim`; `/Users/tomtim/` -> `-Users-tomtim-`; `/Users/tomtim/.claude` -> `-Users-tomtim--claude`;
`/Users/tomtim/` + 236 `a` (250 units) -> first 200 units + `-52ty5v`; `/x/` + 83 x `ab_` (252 units) -> first 200 units + `-4cvp6w`.
`Pe` itself was not re-read here; its base-36 absolute value is the design's F5 reading (design-clawd-chat-sessions.md).
