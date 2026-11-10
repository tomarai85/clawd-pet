import Testing
import Foundation
import CoreGraphics
import ClawdCore
@testable import ClawdRendering

/// The rules every bubble style must keep, each as a function that lists what a design breaks. The suites assert the list is empty
/// for the real styles; the negative controls hand the same function a design with one value broken and assert the list is not.
enum BubbleChecks {
    static let elements = stageRenderer.elements
    static let longestDuration = 3 * 3600 + 59 * 60 + 59.0
    static let reasonableScenes = BubbleContent.shownScenes

    /// Spec 4.1: every text colour is at least 4.5:1 against the colour it sits on (style 3 against its outline, style 12's glyph against its segment).
    static func contrastViolations(_ design: BubbleDesign) -> [String] {
        design.textPairs.compactMap { pair in
            let ratio = Pixel.contrast(pair.foreground, pair.background)
            return ratio >= 4.5 ? nil : "style \(design.id) \(pair.name): \(String(format: "%.2f", ratio)):1 against the colour under it"
        }
    }

    /// Spec 4.1 and 9b item 11b: the reduced-motion pulse paints the dot in three colours over its 2 s, and every one of them is at least 4.5:1
    /// against the colour under it. The colours are read from the pixels the renderer paints (the dot's pixels are the ones that appear when its
    /// run is shown), at every quarter second of the period; the three steps must all be seen, and must differ, or there would be no pulse.
    static func pulseViolations(_ design: BubbleDesign) -> [String] {
        var broken: [String] = []
        var levels = Set<Int>(), colours = Set<Pixel>()
        for i in 0..<8 {
            let content = BubbleContent(scene: .thinking, elapsed: Double(i) * 0.25, verb: "Cogitating", reduceMotion: true)
            let text = BubbleText.content(content, elements: elements, design: design)
            guard let dot = text.runs.first else { return ["style \(design.id): no reduced-motion line"] }
            levels.insert(dot.dimLevel)
            var without = text.runs; without[0].visible = false
            for variant in [BubbleVariant.snug, .roomy] {
                let drawn = design.render(runs: text.runs, opening: .right, connection: .above, variant: variant).raster
                let base = design.render(runs: without, opening: .right, connection: .above, variant: variant).raster
                var painted = 0
                for y in 0..<drawn.height { for x in 0..<drawn.width where drawn[x, y] != base[x, y] && drawn[x, y] != design.fill {
                    // the dot's own pixel (the halo style also draws the dot's outline, which is the fill colour and is skipped above)
                    let under = base[x, y].a == 255 ? base[x, y] : design.fill
                    painted += 1
                    colours.insert(drawn[x, y])
                    let ratio = Pixel.contrast(drawn[x, y], under)
                    if ratio < 4.5 { broken.append("style \(design.id) pulse step \(dot.dimLevel) (\(variant)): the dot's pixel (\(x),\(y)) is \(String(format: "%.2f", ratio)):1 against the colour under it"); return broken }
                } }
                if painted == 0 { broken.append("style \(design.id) pulse step \(dot.dimLevel): the dot paints nothing"); return broken }
            }
        }
        if levels != [0, 1, 2] { broken.append("style \(design.id): the pulse shows steps \(levels.sorted()), not 0, 1 and 2") }
        if colours.count != 3 { broken.append("style \(design.id): the pulse paints \(colours.count) colours, not 3: it would not pulse") }
        return broken
    }

    /// One bubble pixel in points. Written out here, not read from the production constant, so that changing that constant cannot move the rule:
    /// the twelve styles step in 2 pt, style 13 in 1 pt.
    static func pixelPt(_ design: BubbleDesign) -> Double { design.id >= 13 ? 1 : 2 }

    /// The body-height rule of 9b item 1 at size 1: a shape of `rows` rows of `pixelPt` points is at most the body's 6 units, 24 pt, tall.
    static func exceedsTheBodyAtSizeOne(rows: Int, pixelPt: Double) -> Bool { Double(rows) * pixelPt > 6 * 4 }

    /// Spec 4.4 cap X and 9b item 1: the picture at most 200 x 48 pt, the shape at most 12 rows (24 pt, the body's 6 units) at size 1; no text
    /// ever shortened to fit.
    static func capViolations(_ design: BubbleDesign) -> [String] {
        var broken: [String] = []
        func check(_ content: BubbleContent, _ label: String) {
            let text = BubbleText.content(content, elements: elements, design: design)
            if BubbleText.fitted(text.runs, dots: text.dots, design: design) != text.runs { broken.append("style \(design.id) \(label): the text needed shortening") }
            for connection in [BubbleConnection.above, .side] {
                for variant in [BubbleVariant.snug, .roomy] {
                    // the cap's numbers are written out here, not read from BubbleLayout, so that changing the production constant cannot move the rule
                    let pt = pixelPt(design)
                    let shape = design.extent(runs: text.runs, dots: text.dots, variant: variant, connection: connection)
                    let picture = design.pictureExtent(runs: text.runs, dots: text.dots, variant: variant, connection: connection)
                    if Double(picture.width) * pt > 200 { broken.append("style \(design.id) \(label) \(connection) \(variant): \(Double(picture.width) * pt) pt wide") }
                    if Double(picture.height) * pt > 48 { broken.append("style \(design.id) \(label) \(connection) \(variant): \(Double(picture.height) * pt) pt tall") }
                    if variant == .snug, exceedsTheBodyAtSizeOne(rows: shape.height, pixelPt: pt) {
                        broken.append("style \(design.id) \(label) \(connection): \(Double(shape.height) * pt) pt, over the body's 6 units at size 1")
                    }
                }
            }
        }
        for verb in elements.present { check(BubbleContent(scene: .thinking, verb: verb), "thinking \(verb)") }
        for verb in elements.present { check(BubbleContent(scene: .thinking, verb: verb, reduceMotion: true), "reduced \(verb)") }
        for past in elements.past { check(BubbleContent(scene: .sent, duration: longestDuration, pastVerb: past), "sent \(past)") }
        for scene in [Scene.listening, .interrupted, .error] { check(BubbleContent(scene: scene), "\(scene)") }
        return broken
    }

    /// No text pixel sits next to the outline, the ring, the other segment or the edge of the picture: the cell around every letter, glyph
    /// and cursor (the diagonals too) is the colour the text sits on.
    static func clearanceViolations(_ design: BubbleDesign, verbs: [String]? = nil) -> [String] {
        var broken: [String] = []
        let backgrounds: Set<Pixel> = Set([design.fill] + (design.segment.map { [$0.fill] } ?? []))
        func check(_ content: BubbleContent, _ label: String) {
            let text = BubbleText.content(content, elements: elements, design: design)
            let hidden = text.runs.map { run -> BubbleRun in var run = run; run.visible = false; return run }
            for connection in [BubbleConnection.above, .side] { for opening in [BubbleOpening.right, .left] { for variant in [BubbleVariant.snug, .roomy] {
                let drawn = design.render(runs: text.runs, dots: text.dots, opening: opening, connection: connection, variant: variant).raster
                var base = design.render(runs: hidden, dots: text.dots, opening: opening, connection: connection, variant: variant).raster
                if design.form == .halo {
                    // No box to take away: the words are every pixel that is not the outline, and the outline is what must surround them.
                    base = drawn
                    for y in 0..<drawn.height { for x in 0..<drawn.width where drawn.isOpaque(x, y) && drawn[x, y] != design.fill { base[x, y] = design.fill } }
                }
                var count = 0
                for y in 0..<drawn.height { for x in 0..<drawn.width where drawn[x, y] != base[x, y] {
                    for dy in -1...1 { for dx in -1...1 where (dx, dy) != (0, 0) {
                        let n = base[x + dx, y + dy]
                        let ownText = drawn[x + dx, y + dy] != base[x + dx, y + dy]
                        if !ownText, !backgrounds.contains(n), count == 0 { count += 1; broken.append("style \(design.id) \(label) \(connection) \(opening) \(variant): a text pixel at (\(x),\(y)) touches \(n) at (\(x + dx),\(y + dy))") }
                    } }
                } }
            } } }
        }
        for verb in verbs ?? elements.present { check(BubbleContent(scene: .thinking, verb: verb), "thinking \(verb)") }
        for scene in [Scene.listening, .sent, .interrupted, .error] { check(BubbleContent(scene: scene, duration: 71, pastVerb: "Cogitated"), "\(scene)") }
        return broken
    }

    /// The colours every painted pixel may have: the style's own palette, whole and fully opaque, and for style 13 its one named exception, the drop
    /// shadow's single translucent tone.
    static func paletteViolations(_ design: BubbleDesign) -> [String] {
        var broken: [String] = []
        let allowed = design.palette
        for scene in BubbleContent.shownScenes { for elapsed in [0.0, 0.3, 0.7, 1.8] { for connection in [BubbleConnection.above, .side] { for opening in [BubbleOpening.right, .left] {
            for variant in [BubbleVariant.snug, .roomy] { for reduce in [false, true] {
                let text = BubbleText.content(BubbleContent(scene: scene, elapsed: elapsed, reduceMotion: reduce), elements: elements, design: design)
                let bitmap = design.render(runs: text.runs, dots: text.dots, opening: opening, connection: connection, variant: variant,
                                           fadeLevel: BubbleText.fadeLevel(scene: scene, elapsed: elapsed))
                for y in 0..<bitmap.raster.height { for x in 0..<bitmap.raster.width {
                    let p = bitmap.raster[x, y]
                    if p.a == 0 { continue }
                    if p == design.dropShadow { continue }
                    if p.a != 255 || !allowed.contains(p) { broken.append("style \(design.id) \(scene): pixel \(p) at (\(x),\(y)) is not crisp or not in the palette"); return broken }
                } }
            } }
        } } } }
        return broken
    }
}
