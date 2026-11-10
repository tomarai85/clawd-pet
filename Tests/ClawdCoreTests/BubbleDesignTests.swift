import Testing
import Foundation
import CoreGraphics
import ClawdCore
@testable import ClawdRendering

private let elements = stageRenderer.elements

@Suite("Bubble pixel language", .serialized)
struct BubbleDesignTests {
    private func text(_ c: BubbleContent, style: Int = 1) -> [BubbleRun] {
        BubbleText.content(c, elements: elements, design: BubbleDesign.resolved(style)).runs
    }
    private func line(_ runs: [BubbleRun]) -> String { runs.map(\.text).joined() }

    @Test func PixelFont_everyCharacterClaudeCodeCanSayHasAGlyph() {
        var missing = Set<Character>()
        for word in elements.present + elements.past + [elements.interrupt, elements.error, elements.ellipsis, "for", "0123456789 ms:h-", elements.promptChar, elements.completeGlyph] {
            for ch in word where ch != "\u{00A0}" && !PixelFont.supports(ch) { missing.insert(ch) }
        }
        for glyph in elements.glyphs { for ch in glyph where !PixelFont.supports(ch) { missing.insert(ch) } }
        #expect(missing.isEmpty, "no glyph for \(missing.sorted())")
    }

    @Test func PixelFont_everyGlyphFitsTheSixRowLineAndFiveColumns() {
        for scalar in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzé0123456789 -'.:\u{2026}\u{276F}\u{23BF}\u{2588}\u{25CF}\u{23FA}\u{00B7}\u{2722}\u{2733}\u{2736}\u{273B}\u{273D}*" {
            let g = PixelFont.glyph(scalar)
            #expect(g.width >= 1 && g.width <= 5, "\(scalar): width \(g.width)")
            #expect(g.top >= 0 && g.top + g.rows.count <= PixelFont.lineRows, "\(scalar): rows \(g.top)..<\(g.top + g.rows.count)")
            for row in g.rows { #expect(row.allSatisfy { $0 == "X" || $0 == "." }, "\(scalar): \(row)") }
        }
        // Capitals and digits are 5 rows from the top; lowercase x-height letters are 4 rows; descenders reach row 5.
        for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" { #expect(PixelFont.glyph(ch).top == 0 && PixelFont.glyph(ch).rows.count == 5, "\(ch)") }
        for ch in "gjpqy" { #expect(PixelFont.glyph(ch).top + PixelFont.glyph(ch).rows.count == 6, "\(ch) must reach the descender row") }
        for ch in "aceimnorsuvwxz" { #expect(PixelFont.glyph(ch).top + PixelFont.glyph(ch).rows.count <= 5, "\(ch) stays on the baseline") }
    }

    @Test func PixelFont_aFontPixelIsOneBubblePixelAndTheDrawnTextHasNoHalfTones() {
        var r = Raster(width: 40, height: 8)
        PixelFont.draw("Aq", into: &r, x: 1, y: 1, color: Pixel(1, 2, 3))
        for y in 0..<r.height { for x in 0..<r.width { #expect(r[x, y].a == 0 || r[x, y] == Pixel(1, 2, 3)) } }
        #expect(r.opaqueBounds != nil)
    }

    @Test func BubbleText_theLinesAreClaudeCodesOwn() {
        #expect(line(text(BubbleContent(scene: .listening))) == "\u{276F} \u{2588}")
        let spinner = elements.spinner(at: 0.7)
        #expect(line(text(BubbleContent(scene: .thinking, elapsed: 0.7, verb: "Cogitating"))) == spinner + " Cogitating\u{2026}")
        #expect(line(text(BubbleContent(scene: .sent, duration: 5, pastVerb: "Cooked"))) == "\u{273B} Cooked for 5s")
        #expect(line(text(BubbleContent(scene: .sent, duration: 72, pastVerb: "Worked"))) == "\u{273B} Worked for 1m 12s")
        #expect(line(text(BubbleContent(scene: .sent, duration: 3 * 3600 + 59 * 60 + 59, pastVerb: "Worked"))) == "\u{273B} Worked for 3h 59m")
        #expect(line(text(BubbleContent(scene: .interrupted))) == "\u{23BF} Interrupted")
        #expect(line(text(BubbleContent(scene: .error))) == "\u{23BF} Error")
        #expect(text(BubbleContent(scene: .error)).allSatisfy { $0.role == .error })
        #expect(text(BubbleContent(scene: .idle)).isEmpty && text(BubbleContent(scene: .sleep)).isEmpty && text(BubbleContent(scene: .drag)).isEmpty)
        // Style 10 shows three typing dots in place of the spinner.
        let typing = BubbleText.content(BubbleContent(scene: .thinking, elapsed: 0.45, verb: "Cogitating"), elements: elements, design: BubbleDesign.resolved(10))
        #expect(typing.dots == BubbleDots(lit: 2) && line(typing.runs) == "Cogitating\u{2026}")
    }

    @Test func BubbleText_theCursorBlinksWithoutMovingTheBox() {
        let design = BubbleDesign.resolved(1)
        let on = BubbleText.content(BubbleContent(scene: .listening, elapsed: 0.1), elements: elements, design: design)
        let off = BubbleText.content(BubbleContent(scene: .listening, elapsed: 0.6), elements: elements, design: design)
        #expect(on.runs.last?.visible == true && off.runs.last?.visible == false)
        #expect(design.boxWidth(runs: on.runs, dots: nil) == design.boxWidth(runs: off.runs, dots: nil))
        let a = design.render(runs: on.runs, opening: .right, connection: .above, variant: .snug)
        let b = design.render(runs: off.runs, opening: .right, connection: .above, variant: .snug)
        #expect(a.raster.width == b.raster.width && a.raster.height == b.raster.height && a.raster != b.raster)
    }

    @Test func BubbleText_reducedMotionIsAStillDotThatPulsesOverTwoSeconds() {
        var levels = Set<Int>()
        for i in 0..<8 {
            let runs = text(BubbleContent(scene: .thinking, elapsed: Double(i) * 0.25, verb: "Cogitating", reduceMotion: true))
            #expect(runs.first?.text == "\u{25CF}")
            levels.insert(runs[0].dimLevel)
        }
        #expect(levels == [0, 1, 2], "three opacity steps within one 2 s period: \(levels)")
        let spinner = text(BubbleContent(scene: .thinking, elapsed: 0, verb: "Cogitating", reduceMotion: true))
        #expect(!spinner.contains { elements.glyphs.contains($0.text) }, "no spinner sequence under Reduce Motion")
        let period = text(BubbleContent(scene: .thinking, elapsed: 2.0, verb: "x", reduceMotion: true))[0].dimLevel
        #expect(period == text(BubbleContent(scene: .thinking, elapsed: 0, verb: "x", reduceMotion: true))[0].dimLevel, "the pulse repeats every 2 s")
    }

    @Test func BubbleText_everyStepOfTheReducedMotionPulseKeepsTheContrastOfTheDot() {
        for design in BubbleDesign.pixelDesigns {
            let fill = design.segment?.fill ?? design.fill, dot = design.segment?.ink ?? design.color(.claude)
            let ratios = (0...2).map { Pixel.contrast(dot.pulsed(level: $0, against: fill), fill) }
            #expect(dot.pulsed(level: 0, against: fill) == dot, "style \(design.id): step 0 is the dot's own colour")
            #expect(ratios[0] >= 4.5, "style \(design.id): the dot's own colour is \(ratios[0]):1")
            #expect(ratios[1] >= ratios[0] && ratios[2] >= ratios[1], "style \(design.id): a step lowers the contrast: \(ratios)")
            #expect(Set((0...2).map { dot.pulsed(level: $0, against: fill) }).count == 3, "style \(design.id): the three steps are not three colours")
            #expect(BubbleChecks.pulseViolations(design).isEmpty, "\(BubbleChecks.pulseViolations(design))")
        }
        // the old rule, a step moved towards the fill, is what the check exists to refuse: style 12's dimmest step was 1.75:1 on its segment
        let twelve = BubbleDesign.resolved(12), segment = twelve.segment!
        let old = Pixel.contrast(segment.ink.mixed(into: segment.fill, third: 2), segment.fill)
        #expect(old < 2, "the old dimmest step: \(old):1")
    }

    @Test func BubbleText_sentFadesOverItsLastFifthOfASecondInFourDitherSteps() {
        #expect(BubbleText.fadeLevel(scene: .sent, elapsed: 0) == 4 && BubbleText.fadeLevel(scene: .sent, elapsed: 1.59) == 4)
        var seen: [Int] = []
        for i in 0...80 { seen.append(BubbleText.fadeLevel(scene: .sent, elapsed: 1.6 + Double(i) * 0.005)) }
        #expect(seen.first == 4 && seen.last == 0)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 >= $1 }, "the fade only ever thins")
        #expect(Set(seen) == [0, 1, 2, 3, 4])
        #expect(BubbleText.fadeLevel(scene: .listening, elapsed: 1.9) == 4, "only SENT fades")
        // each step removes pixels and never invents one
        let design = BubbleDesign.resolved(6)
        let runs = text(BubbleContent(scene: .sent), style: 6)
        var counts: [Int] = []
        for level in [4, 3, 2, 1, 0] {
            let b = design.render(runs: runs, opening: .right, connection: .above, variant: .snug, fadeLevel: level)
            var n = 0
            for y in 0..<b.raster.height { for x in 0..<b.raster.width where b.raster.isOpaque(x, y) { n += 1 } }
            counts.append(n)
        }
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $0 > $1 } && counts.last == 0, "\(counts)")
    }

    @Test func BubbleText_nextChangeIsTheSpinnerTickTheCursorOrTheFadeStep() {
        let d1 = BubbleDesign.resolved(1), d10 = BubbleDesign.resolved(10)
        func next(_ s: Scene, _ t: Double, _ d: BubbleDesign = d1, reduce: Bool = false) -> Double? {
            BubbleText.nextChange(scene: s, elapsed: t, design: d, reduceMotion: reduce, tick: elements.tick)
        }
        #expect(abs((next(.listening, 0.1) ?? 0) - 0.4) < 1e-9)
        #expect(abs((next(.thinking, 0.03) ?? 0) - 0.07) < 1e-9)
        #expect(abs((next(.thinking, 0.05, d10) ?? 0) - 0.15) < 1e-9)
        #expect(abs((next(.thinking, 0.1, reduce: true) ?? 0) - 0.15) < 1e-9)
        #expect(abs((next(.sent, 0.5) ?? 0) - 1.1) < 1e-9, "until the fade starts at 1.6 s")
        #expect(abs((next(.sent, 1.65) ?? 0) - 0.05) < 1e-9)
        #expect(next(.sent, 2.0) == nil && next(.interrupted, 0.1) == nil && next(.error, 0.1) == nil)
    }

    @Test func BubbleDesign_theBoardsTwelveAreDrawnAndAnIdOutsideAllFifteenFallsBackToTheOfficialBlue() throws {
        #expect(BubbleDesign.ids == Array(1...12), "the board's twelve")
        #expect(BubbleDesign.phase2Ids == [2, 3, 4, 5, 7, 8, 9, 11, 12])
        for id in BubbleDesign.ids { #expect(BubbleDesign.resolved(id).id == id, "style \(id) falls back although it is drawn") }
        for id in [0, 16, 99, -1] { #expect(BubbleDesign.resolved(id).id == 1, "\(id)") }
        for id in [7, 99] {
            let frame = Frames.pose("listen", scene: .listening, bubble: BubbleState(style: id, scene: .listening))
            let drawn = try #require(try stageRenderer.compose(StageRequest(frame: frame, now: 0.25, geometry: Screens.geometry())))
            #expect(drawn.bubble?.style == (id == 99 ? 1 : id))
        }
    }

    @Test func BubbleDesign_noTwoStylesDrawTheSamePicture() {
        for scene in [Scene.listening, .thinking, .sent, .error] {
            var seen: [Int: Raster] = [:]
            for design in BubbleDesign.all {
                let t = BubbleText.content(BubbleContent(scene: scene, elapsed: 0.7, duration: 5), elements: elements, design: design)
                let picture = design.render(runs: t.runs, dots: t.dots, opening: .right, connection: .above, variant: .snug).raster
                for (other, raster) in seen { #expect(raster != picture, "styles \(other) and \(design.id) look the same in \(scene)") }
                seen[design.id] = picture
            }
        }
    }

    @Test func BubbleDesign_everyStyleKeepsTheShapeAndColoursOfItsMock() throws {
        func picture(_ id: Int, _ scene: Scene = .thinking, opening: BubbleOpening = .right, connection: BubbleConnection = .above, variant: BubbleVariant = .snug) -> (BubbleBitmap, BubbleDesign) {
            let design = BubbleDesign.resolved(id)
            let t = BubbleText.content(BubbleContent(scene: scene, elapsed: 0.7, verb: "Cogitating"), elements: elements, design: design)
            return (design.render(runs: t.runs, dots: t.dots, opening: opening, connection: connection, variant: variant), design)
        }
        // 2: Claude Code's input box: terminal black, a grey rule on the top and bottom row, nothing on the left and right columns.
        do {
            let (b, d) = picture(2), r = b.raster
            #expect(d.fill == Pixel(rgb: 0x0C0C0C) && d.border == Pixel(rgb: 0x888888))
            for x in 1..<(r.width - 1) { #expect(r[x, 0] == d.border! && r[x, r.height - 1] == d.border!, "rule at \(x)") }
            for y in 1..<(r.height - 1) { #expect(r[0, y] == d.fill && r[r.width - 1, y] == d.fill, "no frame at the sides, row \(y)") }
            #expect(r[0, 0].isClear && r.height == 10 && b.tip.y == r.height - 1, "no connector")
        }
        // 3: no box: the corner is empty, the only fill is the white outline round the words.
        do {
            let (b, d) = picture(3), r = b.raster
            #expect(d.fill == BubbleDesign.white && d.border == nil && r[0, 0].isClear)
            var painted = 0, white = 0, clear = 0
            for y in 0..<r.height { for x in 0..<r.width { if r.isOpaque(x, y) { painted += 1; if r[x, y] == d.fill { white += 1 } } else { clear += 1 } } }
            #expect(white * 2 > painted && clear * 20 > r.width * r.height, "an outline round the words, not a filled box: \(white) white of \(painted) painted, \(clear) clear in \(r.width) x \(r.height)")
            #expect(r[r.width - 1, 0].isClear && r[0, r.height - 1].isClear)
        }
        // 4: NES balloon: white, near-black outline with a notched corner, the stair tail 2 rows under the box.
        do {
            let (b, d) = picture(4), r = b.raster
            #expect(d.fill == BubbleDesign.white && d.border == Pixel(rgb: 0x212529))
            #expect(r[0, 0].isClear && r[1, 0] == d.border! && r[0, 1] == d.border!, "stepped corner")
            #expect(r.height == b.box.height + 2 && r[b.tip.x, b.tip.y] == d.border!, "stair tail ends in an outline cell")
        }
        // 5: papercade window: dark, a cream frame, a dark ring outside it, capitals.
        do {
            let (b, d) = picture(5), r = b.raster
            #expect(d.fill == Pixel(rgb: 0x1B1A17) && d.border == Pixel(rgb: 0xE9E2CF) && d.ring == d.fill && d.uppercase)
            #expect(r[2, 0] == d.ring! && r[1, 1] == d.ring! && r[2, 1] == d.border! && r[1, 2] == d.border! && r[3, 3] == d.fill, "ring, then the frame, then the fill")
            #expect(r[0, 0].isClear && r[1, 0].isClear && r[0, 1].isClear, "the ring has cut corners too")
        }
        // 7: Clippy's balloon: pale yellow, a black outline, a pointed tail.
        do {
            let (b, d) = picture(7), r = b.raster
            #expect(d.fill == Pixel(rgb: 0xFFFFCC) && d.border == Pixel(rgb: 0x000000) && r.height == b.box.height + 2)
            #expect(picture(7, connection: .side).0.raster.width == b.box.width + 4, "the side flag is 4 columns")
        }
        // 8: Dynamic Island: black, no outline, round at both ends.
        do {
            let (b, d) = picture(8), r = b.raster
            #expect(d.fill == Pixel(rgb: 0x000000) && d.border == nil && d.capsule)
            #expect(r[0, 0].isClear && r[0, r.height - 1].isClear && r[r.width - 1, 0].isClear && r[0, r.height / 2] == d.fill, "round ends, full height in the middle")
        }
        // 9: Sonner's toast: white with a pale outline and rounded corners.
        do {
            let (b, d) = picture(9), r = b.raster
            #expect(d.fill == BubbleDesign.white && d.border == Pixel(rgb: 0xCDCDCD) && d.topCorner == [2, 1])
            #expect(r[0, 0].isClear && r[1, 0].isClear && r[2, 0] == d.border!)
        }
        // 11: the comic thought bubble: white oval, navy outline, a trail of three circles that runs out to the side so that it stays 12 rows.
        do {
            let (b, d) = picture(11), r = b.raster
            #expect(d.fill == BubbleDesign.white && d.border == Pixel(rgb: 0x0B2234) && d.aboveLead == 8)
            #expect(r.width == b.box.width + 8 && r.height == b.box.height + 2 && b.box.x == 8, "the box lies right of the trail: \(r.width) x \(r.height), box at \(b.box.x)")
            #expect(b.tip.x == 0 && b.tip.y == r.height - 1 && r[0, r.height - 1] == d.dim, "the smallest circle is the tip")
            var circles = 0
            for y in 0..<r.height { for x in 0..<8 where r.isOpaque(x, y) && r[x, y] == d.dim { circles += 1 } }
            #expect(circles == 9, "three circles: a ring of 4 grey cells round a white eye, a 2 x 2 dot, a single pixel (1 + 2 + 3 + 2 + 1 grey cells in the trail's 5 rows): \(circles)")
            let mirrored = picture(11, opening: .left).0
            #expect(mirrored.tip.x == mirrored.raster.width - 1 && mirrored.box.x == 0)
        }
        // 12: tmux powerline: an orange segment holding the glyph, a slate segment holding the words, arrow joints.
        do {
            let (b, d) = picture(12), r = b.raster
            #expect(d.segment?.fill == Pixel(rgb: 0xD77757) && d.fill == Pixel(rgb: 0x303446))
            #expect(r[0, 0] == d.segment!.fill && r[0, r.height - 1] == d.segment!.fill, "square corners")
            #expect(r[r.width - 1, 0].isClear && r[r.width - 1, r.height - 1].isClear && r[r.width - 1, r.height / 2] == d.fill, "the closing arrow points right")
            #expect(b.box.height == 8)
        }
    }

    @Test func BubbleText_styleFiveSpeaksInCapitalsAndNoOtherStyleDoes() throws {
        let five = BubbleDesign.resolved(5)
        let verb = try #require(elements.present.first { $0.contains("é") })
        let loud = BubbleText.content(BubbleContent(scene: .thinking, verb: verb), elements: elements, design: five).runs.map(\.text).joined()
        #expect(loud == "\(elements.spinner(at: 0)) \(verb.uppercased().replacingOccurrences(of: "É", with: "é"))\(elements.ellipsis)", "the font has no capital É: it keeps the é, which fills the same 5 rows: \(loud)")
        #expect(PixelFont.supports("é") && !PixelFont.supports("É"))
        let sent = BubbleText.content(BubbleContent(scene: .sent, duration: 72, pastVerb: "Worked"), elements: elements, design: five).runs.map(\.text).joined()
        #expect(sent == "\u{273B} WORKED FOR 1M 12S", "\(sent)")
        for design in BubbleDesign.pixelDesigns where design.id != 5 {
            let line = BubbleText.content(BubbleContent(scene: .sent, duration: 72, pastVerb: "Worked"), elements: elements, design: design).runs.map(\.text).joined()
            #expect(line == "\u{273B} Worked for 1m 12s", "style \(design.id): \(line)")
        }
        // 14 and 15 say the same words in their own marks: 14 draws the still asterisk as a shape, 15 sets the glyph in its 12 pt slot
        for design in BubbleDesign.all where design.isSmooth {
            let runs = BubbleText.content(BubbleContent(scene: .sent, duration: 72, pastVerb: "Worked"), elements: elements, design: design).runs
            #expect(runs.count == 2 && runs[1].text == "Worked for 1m 12s", "style \(design.id): \(runs.map(\.text))")
            #expect(design.id == 14 ? runs[0].mark == .asterisk(degrees: 0) : runs[0].text == "\u{273B}", "style \(design.id) opens with the glyph")
        }
    }

    @Test func BubbleDesign_everyStyleDrawsTheReducedMotionDotAndTheCursorWithoutMovingTheBox() {
        for design in BubbleDesign.pixelDesigns {
            var widths = Set<Int>()
            for i in 0..<8 {
                let t = BubbleText.content(BubbleContent(scene: .thinking, elapsed: Double(i) * 0.25, verb: "Cogitating", reduceMotion: true), elements: elements, design: design)
                #expect(t.runs.first?.text == "\u{25CF}" && (t.dots == nil || (design.id == 13 && t.dots == BubbleDots(count: 3))), "style \(design.id) shows the static dot")
                widths.insert(design.boxWidth(runs: t.runs, dots: t.dots))
                let bitmap = design.render(runs: t.runs, dots: t.dots, opening: .right, connection: .above, variant: .snug)
                #expect(bitmap.raster.opaqueBounds != nil)
            }
            #expect(widths.count == 1, "style \(design.id): the pulse changed the box width")
            let on = BubbleText.content(BubbleContent(scene: .listening, elapsed: 0.1), elements: elements, design: design)
            let off = BubbleText.content(BubbleContent(scene: .listening, elapsed: 0.6), elements: elements, design: design)
            #expect(design.boxWidth(runs: on.runs, dots: nil) == design.boxWidth(runs: off.runs, dots: nil), "style \(design.id): the cursor moved the box")
        }
    }

    @Test func BubbleDesign_noTextTouchesAnOutlineARingAnotherSegmentOrTheEdge() {
        // 188 verbs x 12 styles x 8 placements x 2 variants of two renders each: sampled by the longest and the shortest verbs.
        let sample = Array(elements.present.sorted { PixelFont.width(of: $0) > PixelFont.width(of: $1) }.prefix(12)) + Array(elements.present.sorted { PixelFont.width(of: $0) < PixelFont.width(of: $1) }.prefix(4))
        for design in BubbleDesign.pixelDesigns {
            let broken = BubbleChecks.clearanceViolations(design, verbs: sample)
            #expect(broken.isEmpty, "\(broken.prefix(3))")
        }
    }

    @Test func BubbleDesign_theBoxIsEvenRowsTallSoItCentresOnTheBodyAndFitsTheGrid() {
        for design in BubbleDesign.all { for variant in [BubbleVariant.snug, .roomy] {
            #expect(design.boxHeight(variant) % 2 == 0, "style \(design.id) \(variant): \(design.boxHeight(variant)) rows")
        } }
        // at size 1 the whole bubble, connector included, is at most the body's 6 units: 12 rows of 2 pt, or 24 of style 13's 1 pt
        for design in BubbleDesign.all {
            let t = BubbleText.content(BubbleContent(scene: .thinking), elements: elements, design: design)
            #expect(design.extent(runs: t.runs, dots: t.dots, variant: .snug, connection: .above).height <= Int(24 / BubbleChecks.pixelPt(design)), "style \(design.id)")
        }
    }

    @Test func StageRenderer_nextChangeNamesTheNearestPictureChange() throws {
        let geometry = Screens.geometry()
        let still = StageRequest(frame: Frames.rest(), now: 0, geometry: geometry)
        #expect(stageRenderer.nextChange(still) == nil, "a standing Clawd without a bubble never changes by itself")
        let walking = StageRequest(frame: Frames.motion("A5-walking", loops: true), now: 0.01, geometry: geometry)
        let next = try #require(stageRenderer.nextChange(walking))
        #expect(next > 0 && next <= 0.0841, "\(next)")
        // A glide's pose never changes but its position does: it asks for a redraw like any moving picture, not only when another timer fires.
        let glide = SchedulerFrame(playback: MotionPlayback(source: .glide, use: "walk", startedAt: 0, duration: 0.001, loops: true))
        let gliding = try #require(stageRenderer.nextChange(StageRequest(frame: glide, now: 0.5, geometry: geometry)), "a glide names no next change")
        #expect(gliding > 0 && gliding <= 1.0 / 30 + 0.0001, "\(gliding)")
        let thinking = StageRequest(frame: Frames.pose("think", scene: .thinking, bubble: BubbleState(style: 1, scene: .thinking)), now: 0.05, geometry: geometry,
                                    content: BubbleContent(scene: .thinking, elapsed: 0.05))
        #expect(abs((stageRenderer.nextChange(thinking) ?? 9) - 0.05) < 0.0011, "the 100 ms spinner tick comes before the 120 ms pose frame")
        let hidden = StageRequest(frame: SchedulerFrame(visibility: .hidden), now: 0, geometry: geometry)
        #expect(stageRenderer.nextChange(hidden) == nil)
        #expect(try stageRenderer.compose(hidden) == nil)
        let transition = SchedulerFrame(playback: MotionPlayback(source: .transition(from: "plain", to: "helmet"), use: "transition", startedAt: 0, duration: 1.6),
                                        look: "helmet", displayedLook: "plain", transitionProgress: 0.01)
        #expect(abs((stageRenderer.nextChange(StageRequest(frame: transition, now: 0.016, geometry: geometry)) ?? 9) - 0.064) < 1e-9)
    }


    /// D-8 (R2-6): walking t <- t + nextChange(t) from 0 for 2,000 steps, each step is at least the period (less 1e-6 s) and the k-th boundary is within 1e-6 s of
    /// k periods, in every state of the new styles: THINKING with and without Reduce Motion, LISTENING; and through SENT's fade steps. A wake that fires
    /// on a boundary, with the accumulated rounding of the sum, must wait for the next one, not for a float's width.
    @Test func BubbleText_boundariesAdvanceStrictlyOverAccumulatedSteps() {
        let tick = elements.tick
        for design in BubbleDesign.all where design.id >= 13 {
            let states: [(String, Scene, Bool, Double)] = [
                ("thinking", .thinking, false, design.usesDots ? BubbleText.typingStep : tick),
                ("thinking reduced", .thinking, true, BubbleText.reducedMotionStep),
                ("listening", .listening, false, BubbleText.cursorPeriod),
            ]
            for (label, scene, reduce, period) in states {
                var t = 0.0, shortest = Double.infinity
                for k in 1...2000 {
                    guard let next = BubbleText.nextChange(scene: scene, elapsed: t, design: design, reduceMotion: reduce, tick: tick) else {
                        Issue.record("style \(design.id) \(label): no next boundary at step \(k)"); return
                    }
                    shortest = min(shortest, next)
                    t += next
                    if next < period - 1e-6 || abs(t - Double(k) * period) > 1e-6 {
                        Issue.record("style \(design.id) \(label): step \(k) waits \(next) s (period \(period)) and lands at \(t), not at \(Double(k) * period)"); return
                    }
                }
                #expect(shortest >= period - 1e-6, "style \(design.id) \(label)")
            }
            // SENT: the first boundary is the start of the fade, then four equal steps; the bubble ends at SceneMachine.sentDuration
            let start = SceneRenderer.sentFadeStart, step = (SceneMachine.sentDuration - start) / 4
            var t = 0.0
            var boundaries: [Double] = []
            while boundaries.count < 5, let next = BubbleText.nextChange(scene: .sent, elapsed: t, design: design, reduceMotion: false, tick: tick) {
                t += next; boundaries.append(t)
            }
            #expect(boundaries.count == 5, "style \(design.id) SENT: \(boundaries)")
            for (k, boundary) in boundaries.enumerated() { #expect(abs(boundary - (start + Double(k) * step)) < 1e-6, "style \(design.id) SENT boundary \(k): \(boundary)") }
            for (a, b) in zip(boundaries.dropFirst(), boundaries.dropFirst(2)) { #expect(b - a >= step - 1e-6, "style \(design.id) SENT steps") }
        }
    }

    /// The formula at 382758a is the oracle, including floating-point remainders at and just before a boundary.
    @Test func BubbleText_stylesOneToTwelveKeepTheirPreviousBoundarySchedule() {
        func previous(_ scene: Scene, _ elapsed: Double, _ style: Int, _ reduce: Bool, _ tick: Double) -> Double? {
            func untilBoundary(_ period: Double) -> Double { let t = max(0, elapsed); return period - t.truncatingRemainder(dividingBy: period) }
            switch scene {
            case .listening: return untilBoundary(0.5)
            case .thinking:
                if reduce { return untilBoundary(0.25) }
                return untilBoundary(style == 10 ? 0.2 : tick)
            case .sent:
                let start = 2.0 - 0.4, step = (2.0 - start) / 4
                if elapsed < start { return start - elapsed }
                if elapsed >= 2.0 { return nil }
                return step - (elapsed - start).truncatingRemainder(dividingBy: step)
            default: return nil
            }
        }
        for style in 1...12 { for scene in Scene.allCases { for reduce in [false, true] { for tick in [0.1, 0.125] {
            var times = [-1.0, 0, 0.037, 1.69, 1.7, 1.85, 2.0, 4.321, 180]
            let fadeStart = 2.0 - 0.4, fadeStep = (2.0 - fadeStart) / 4
            if scene == .listening || scene == .thinking {
                let period = scene == .listening ? 0.5 : (reduce ? 0.25 : (style == 10 ? 0.2 : tick))
                var accumulated = 0.0
                for index in 1...32 {
                    accumulated += period
                    let boundary = Double(index) * period
                    times += [boundary.nextDown, boundary - 5e-10, boundary, boundary.nextUp, boundary + period / 3, accumulated]
                }
            }
            if scene == .sent {
                for index in 0...4 {
                    let boundary = fadeStart + Double(index) * fadeStep
                    times += [boundary.nextDown, boundary - 5e-10, boundary, boundary.nextUp, boundary + fadeStep / 3]
                }
            }
            for t in times {
                let actual = BubbleText.nextChange(scene: scene, elapsed: t, design: BubbleDesign.resolved(style), reduceMotion: reduce, tick: tick)
                #expect(actual == previous(scene, t, style, reduce, tick), "style \(style), \(scene) at \(t), reduced=\(reduce), tick=\(tick)")
            }
        } } } }
    }
}
