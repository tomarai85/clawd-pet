import Testing
import Foundation
import CoreGraphics
import CoreText
import ClawdCore
@testable import ClawdRendering

/// Bubble styles 13, 14 and 15 (the board's mock B, C and D; amendment R-BUBBLES). Style 13 is the pixel path at 1 pt pixels; 14 and 15 are drawn
/// smooth at device pixels.
private let elements = stageRenderer.elements
private let thirteen = BubbleDesign.resolved(13)

private func thinking(_ style: Int, verb: String = "Cogitating", scale: Double = 1, pixelScale: Double = 1, homeX: Double = 576) -> StageRequest {
    StageRequest(frame: Frames.pose("think", scene: .thinking, bubble: BubbleState(style: style, scene: .thinking)), now: 0.1,
                 geometry: Screens.geometry(scale: scale, homeX: homeX), pixelScale: pixelScale,
                 content: BubbleContent(scene: .thinking, elapsed: 0.7, duration: 5, verb: verb, pastVerb: "Cooked"))
}

@Suite("Style 13 and the new styles", .serialized)
struct BubbleNewStyleTests {
    // MARK: style 13 at 1 pt pixels (D-3)

    @Test func Style13_stepsInOnePointPixelsOnTheHalfCellGrid() throws {
        // In the default placements the picture's left edge is H.x minus whole points: 13's pixels lie on Clawd's half-cell grid (1 pt at size 1).
        for homeX in [576.0, 1000.0] { for scale in [1.0, 1.5, 2.0] {
            let layout = try #require(try stageRenderer.layout(thinking(13, scale: scale, homeX: homeX)))
            let plan = try #require(layout.bubble).plan
            #expect(plan.connection == .above, "size \(scale) at \(homeX)")
            let offset = layout.headTop.x - plan.rect.minX
            #expect(offset == offset.rounded(), "size \(scale) at \(homeX): the left edge is \(offset) pt left of H")
            #expect(plan.rect.width == plan.rect.width.rounded() && plan.rect.height == plan.rect.height.rounded())
        } }
    }

    @Test func Style13_rowBudgetCountsItsOwnPixels() {
        // 24, 36 and 48 rows at sizes 1, 1.5 and 2 and up; the 2 pt styles keep 12, 18 and 24.
        #expect(thirteen.pixelPt == 1)
        for (scale, rows) in [(1.0, 24), (1.5, 36), (2.0, 48), (3.0, 48), (4.0, 48)] {
            #expect(BubbleLayout.rowBudget(scale: scale, pixelPt: thirteen.pixelPt) == rows, "size \(scale)")
        }
        for (scale, rows) in [(1.0, 12), (1.5, 18), (2.0, 24), (3.0, 24)] {
            #expect(BubbleLayout.rowBudget(scale: scale, pixelPt: BubbleDesign.resolved(6).pixelPt) == rows, "size \(scale)")
        }
    }

    @Test func Style13_isSnugAtSizeOneAndRoomyFromOnePointFive() {
        let text = BubbleText.content(BubbleContent(scene: .thinking, elapsed: 0.7, verb: "Cogitating"), elements: elements, design: thirteen)
        for (scale, variant) in [(1.0, BubbleVariant.snug), (1.5, .roomy), (2.0, .roomy), (3.0, .roomy), (4.0, .roomy)] {
            #expect(BubbleLayout.variant(design: thirteen, runs: text.runs, dots: text.dots, scale: scale) == variant, "size \(scale)")
        }
        // The shapes of the two forms: the mock's 28 rows (22 box + 6 tail) and the snug 23 (18 + 5).
        #expect(thirteen.extent(runs: text.runs, dots: text.dots, variant: .roomy, connection: .above).height == 28)
        #expect(thirteen.extent(runs: text.runs, dots: text.dots, variant: .snug, connection: .above).height == 23)
        #expect(thirteen.pictureExtent(runs: text.runs, dots: text.dots, variant: .roomy, connection: .above).height == 29)
        #expect(thirteen.pictureExtent(runs: text.runs, dots: text.dots, variant: .snug, connection: .above).height == 24)
    }

    @Test func Style13_placementStepsInItsOwnPixels() throws {
        for scale in [1.0, 2.0] {
            let layout = try #require(try stageRenderer.layout(thinking(13, scale: scale)))
            let bubble = try #require(layout.bubble), plan = bubble.plan
            let text = BubbleText.content(BubbleContent(scene: .thinking, elapsed: 0.7, verb: "Cogitating"), elements: elements, design: thirteen)
            let picture = thirteen.pictureExtent(runs: text.runs, dots: text.dots, variant: plan.variant, connection: .above)
            // the picture is its extent in 1 pt pixels, and the tip cell's left edge is H.x
            #expect(plan.rect.width == Double(picture.width) && plan.rect.height == Double(picture.height), "size \(scale): \(plan.rect.size) for \(picture)")
            #expect(plan.rect.minX == layout.headTop.x - Double(try #require(plan.tipColumn)), "size \(scale): the tip sits at H.x minus its column in 1 pt pixels")
            #expect(bubble.bitmap.raster.width == picture.width && bubble.bitmap.raster.height == picture.height)
        }
    }

    @Test func Style13_theWidthCapIsTwoHundredPoints() {
        // 27 letters 'a' (6 columns each with its gap) make a box of about 175 columns: under the cap, so it is not shortened. 40 of them are not.
        let fits = [BubbleRun(String(repeating: "a", count: 27), .shimmer)]
        let box = thirteen.boxWidth(runs: fits, dots: nil)
        #expect(box > 150 && box < 190, "\(box)")
        #expect(BubbleText.fitted(fits, dots: nil, design: thirteen) == fits, "a text 150 columns and more wide is not shortened under 200 pt")
        let tooLong = [BubbleRun(String(repeating: "a", count: 40), .shimmer)]
        let shortened = BubbleText.fitted(tooLong, dots: nil, design: thirteen)
        #expect(shortened != tooLong && thirteen.boxWidth(runs: shortened, dots: nil) <= 200 - thirteen.connectorColumns())
        #expect(BubbleText.widthCap(for: thirteen) == 200 && BubbleText.widthCap(for: BubbleDesign.resolved(6)) == 100)
    }

    @Test func Style13_composeEnlargesEachPixelByItsOwnSize() throws {
        // A bubble pixel is 1 x 1 device pixels at 1x and 2 x 2 at 2x: the stage picture holds the bubble raster enlarged by its own pixel size.
        for backing in [1.0, 2.0] {
            let stage = try #require(try stageRenderer.compose(thinking(13, pixelScale: backing)))
            let bubble = try #require(stage.bubble)
            let factor = Int(backing)
            let expected = bubble.bitmap.raster.upscaled(by: factor)
            let x0 = Int(((bubble.rect.minX - stage.panelFrame.minX) * backing).rounded()), y0 = Int(((stage.panelFrame.maxY - bubble.rect.maxY) * backing).rounded())
            var differing = 0
            for y in 0..<expected.height { for x in 0..<expected.width where stage.pixels[x0 + x, y0 + y] != expected[x, y] { differing += 1 } }
            #expect(expected.width == bubble.bitmap.raster.width * factor && differing == 0, "backing \(backing): \(differing) pixels differ")
        }
    }

    @Test func Style13_theDefaultsKeepStylesOneToTwelveUnchanged() throws {
        // D-3 item 3: every new field of BubbleDesign is today's behaviour for the twelve styles ...
        for design in BubbleDesign.all where design.id <= 12 {
            #expect(design.pixelPt == 2 && design.face == .classic && design.padSkew == 0 && design.snugSprite == nil && design.tipDefault == nil
                    && design.tipClamp == nil && design.minWidth == 12 && design.runGap == 1 && design.dropShadow == nil && !design.keepsOffTheBodyWindow,
                    "style \(design.id)")
            #expect(design.margins == (0, 0, 0) && design.padTop(.snug) == design.padYSnug && design.padBottom(.roomy) == design.padYRoomy, "style \(design.id)")
        }
        // ... and their stored goldens are unchanged files that still match, pixel for pixel.
        guard !StageGoldens.recording else { return }
        var checked = 0
        for style in 1...12 {
            for (name, scale, backing) in [("size2-retina", 2.0, 2.0), ("size1.5", 1.5, 1.0)] {
                let stage = try #require(try stageRenderer.compose(thinking(style, scale: scale, pixelScale: backing)))
                let verdict = try StageGoldens.check(stage.pixels, "bubble/style\(style)-\(name).png")
                #expect(verdict == .pass, "style \(style) \(name): \(verdict)")
                checked += 1
            }
        }
        #expect(checked == 24)
    }

    // MARK: the fine pixel font (D-3 item 2)

    @Test func Style13_everyCharacterClaudeCodeCanSayHasAFineGlyph() {
        var missing = Set<Character>()
        let words = elements.present + elements.past + [elements.interrupt, elements.error, elements.ellipsis, "for", "0123456789 ms:h-", elements.promptChar, elements.completeGlyph,
                                                        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz\u{00E9}0123456789 -'.:,*\u{25CF}\u{23FA}\u{2588}\u{23BF}\u{276F}"]
        for word in words { for ch in word where ch != "\u{00A0}" && !FinePixelFont.supports(ch) { missing.insert(ch) } }
        for glyph in elements.glyphs { for ch in glyph where !FinePixelFont.supports(ch) { missing.insert(ch) } }
        #expect(missing.isEmpty, "no fine glyph for \(missing.sorted())")
        // every glyph the plain pixel font has, the fine one has
        for scalar in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz\u{00E9}0123456789 -'.:\u{2026}\u{276F}\u{23BF}\u{2588}\u{25CF}\u{23FA}\u{00B7}\u{2722}\u{2733}\u{2736}\u{273B}\u{273D}*" {
            #expect(PixelFont.supports(scalar) == FinePixelFont.supports(scalar), "\(scalar)")
        }
    }

    @Test func Style13_everyFineGlyphFitsTheTenRowLine() {
        for scalar in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz\u{00E9}0123456789 -'.:,\u{2026}\u{276F}\u{23BF}\u{2588}\u{25CF}\u{23FA}\u{00B7}\u{2722}\u{2733}\u{2736}\u{273B}\u{273D}*" {
            let g = FinePixelFont.glyph(scalar)
            #expect(g.width >= 1 && g.width <= 8, "\(scalar): width \(g.width)")
            #expect(g.top >= 0 && g.top + g.rows.count <= FinePixelFont.lineRows, "\(scalar): rows \(g.top)..<\(g.top + g.rows.count)")
            for row in g.rows { #expect(row.allSatisfy { $0 == "X" || $0 == "." }, "\(scalar): \(row)") }
        }
        // Capitals and digits: 8 rows from the top; x-height letters rows 2-7; descenders rows 8-9.
        for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" { #expect(FinePixelFont.glyph(ch).top == 0 && FinePixelFont.glyph(ch).rows.count == 8, "\(ch)") }
        for ch in "aceimnorsuvwxz" where ch != "i" { #expect(FinePixelFont.glyph(ch).top == 2 && FinePixelFont.glyph(ch).rows.count == 6, "\(ch) is an x-height letter") }
        for ch in "gpqy" { #expect(FinePixelFont.glyph(ch).top == 2 && FinePixelFont.glyph(ch).rows.count == 8, "\(ch) reaches the descender rows") }
        for ch in "bdfhkl" { #expect(FinePixelFont.glyph(ch).top == 0 && FinePixelFont.glyph(ch).rows.count == 8, "\(ch) is an ascender") }
        // The widths of the mock: lowercase 5, m 7, i and l 1, k 4; capitals 5, I 3, M and W 7.
        #expect(FinePixelFont.glyph("m").width == 7 && FinePixelFont.glyph("i").width == 1 && FinePixelFont.glyph("l").width == 1 && FinePixelFont.glyph("k").width == 4)
        #expect(FinePixelFont.glyph("I").width == 3 && FinePixelFont.glyph("M").width == 7 && FinePixelFont.glyph("W").width == 7 && FinePixelFont.glyph("A").width == 5)
        // The mock's own glyphs, as drawn.
        #expect(FinePixelFont.glyph("C").rows == [".XXX.", "X...X", "X....", "X....", "X....", "X....", "X...X", ".XXX."])
        #expect(FinePixelFont.glyph("\u{276F}").rows == ["XX...", ".XX..", "..XX.", "...XX", "..XX.", ".XX..", "XX..."] && FinePixelFont.glyph("\u{276F}").top == 1)
        #expect(FinePixelFont.glyph("\u{2588}").rows.count == 9 && FinePixelFont.glyph("\u{2588}").width == 4)
        #expect(FinePixelFont.glyph("g").rows == [".XXXX", "X...X", "X...X", "X...X", "X...X", ".XXXX", "....X", ".XXX."])
        for glyph in elements.glyphs { #expect(FinePixelFont.glyph(Character(glyph)).width == 7 && FinePixelFont.glyph(Character(glyph)).rows.count == 7, "spinner glyph \(glyph)") }
    }

    @Test func Style13_paintsOnlyItsPaletteAndOneShadowTone() {
        let allowed = thirteen.palette
        let shadow = Pixel(4, 4, 4, 56)
        #expect(thirteen.dropShadow == shadow, "rgba(20,20,19,0.22) premultiplied")
        var shadowPixels = 0
        for scene in BubbleContent.shownScenes { for elapsed in [0.0, 0.3, 0.7, 1.8] { for connection in [BubbleConnection.above, .side] { for opening in [BubbleOpening.right, .left] {
            for variant in [BubbleVariant.snug, .roomy] { for reduce in [false, true] {
                let text = BubbleText.content(BubbleContent(scene: scene, elapsed: elapsed, reduceMotion: reduce), elements: elements, design: thirteen)
                let raster = thirteen.render(runs: text.runs, dots: text.dots, opening: opening, connection: connection, variant: variant).raster
                for y in 0..<raster.height { for x in 0..<raster.width {
                    let p = raster[x, y]
                    if p.a == 0 { continue }
                    if p == shadow {
                        shadowPixels += 1
                        // the shadow lies only in the row directly under a bottom-edge pixel of the shape
                        let above = raster[x, y - 1]
                        if above.a != 255 || above == shadow { Issue.record("\(scene) \(connection) \(opening) \(variant): a shadow pixel at (\(x),\(y)) is not under the shape"); return }
                    } else if p.a != 255 || !allowed.contains(p) {
                        Issue.record("\(scene) \(connection) \(opening) \(variant): pixel \(p) at (\(x),\(y)) is not in the palette"); return
                    }
                } }
            } }
        } } } }
        #expect(shadowPixels > 0)
        // the fade of 1-12 keeps every pixel whole or gone: so does 13's
        let text = BubbleText.content(BubbleContent(scene: .sent, elapsed: 1.0), elements: elements, design: thirteen)
        for level in 1...3 {
            let raster = thirteen.render(runs: text.runs, dots: nil, opening: .right, connection: .above, variant: .roomy, fadeLevel: level).raster
            for y in 0..<raster.height { for x in 0..<raster.width where raster.isOpaque(x, y) { #expect(raster[x, y] == shadow || allowed.contains(raster[x, y])) } }
        }
    }


    // MARK: the three styles together (D-2, D-4, D-6, D-8, D-9)

    private static let drawn = BubbleDesign.allIds.filter { $0 >= 13 }
    private static let smooth = BubbleDesign.allIds.filter { $0 >= 14 }
    private static let appearances: [BubbleAppearance] = [.light, .dark]

    private static func content(_ style: Int, _ scene: Scene, _ elapsed: Double, verb: String = "Cogitating", reduce: Bool = false, past: String = "Cooked",
                                duration: Double = 5, appearance: BubbleAppearance = .light) -> (runs: [BubbleRun], dots: BubbleDots?) {
        BubbleText.content(BubbleContent(scene: scene, elapsed: elapsed, duration: duration, verb: verb, pastVerb: past, reduceMotion: reduce, appearance: appearance),
                           elements: elements, design: BubbleDesign.resolved(style))
    }
    private static func picture(_ style: Int, _ scene: Scene, _ elapsed: Double, verb: String = "Cogitating", reduce: Bool = false, backing: Double = 2,
                                appearance: BubbleAppearance = .light, connection: BubbleConnection = .above, opening: BubbleOpening = .right,
                                variant: BubbleVariant = .roomy, fade: Int = 4, past: String = "Cooked") -> BubbleBitmap {
        let design = BubbleDesign.resolved(style)
        let text = content(style, scene, elapsed, verb: verb, reduce: reduce, past: past, appearance: appearance)
        return design.render(runs: text.runs, dots: text.dots, opening: opening, connection: connection, variant: variant, fadeLevel: fade, backing: backing, appearance: appearance)
    }
    /// The colours a smooth style may paint in an appearance, whole: the fill, the border, every text and mark colour, the cursor's.
    private static func colours(_ style: Int, _ appearance: BubbleAppearance) -> [Pixel] {
        let d = BubbleDesign.resolved(style).appearing(appearance)
        return [d.fill] + [d.border].compactMap { $0 } + d.roles.map { d.color($0) } + [d.cursorColour].compactMap { $0 }
    }
    /// Whether an opaque pixel lies on a blend of `fill` with one of `others` (anti-aliasing, the dots' pulse), within 2 per channel.
    private static func isBlend(_ p: Pixel, of fill: Pixel, with others: [Pixel]) -> Bool {
        for other in others {
            let channels: [(Int, Int, Int)] = [(Int(p.r), Int(fill.r), Int(other.r)), (Int(p.g), Int(fill.g), Int(other.g)), (Int(p.b), Int(fill.b), Int(other.b))]
            guard let widest = channels.max(by: { abs($0.2 - $0.1) < abs($1.2 - $1.1) }), widest.2 != widest.1 else { if p == fill { return true }; continue }
            let t = Double(widest.0 - widest.1) / Double(widest.2 - widest.1)
            guard t >= -0.01, t <= 1.01 else { continue }
            if channels.allSatisfy({ abs(Double($0.0) - (Double($0.1) + t * Double($0.2 - $0.1))) <= 2.01 }) { return true }
        }
        return false
    }

    @Test func SmoothStyles_followTheSystemAppearance() throws {
        let fills: [Int: [BubbleAppearance: Pixel]] = [14: [.light: Pixel(rgb: 0xFFFFFF), .dark: Pixel(rgb: 0x2F2F31)], 15: [.light: Pixel(rgb: 0xF6F2E8), .dark: Pixel(rgb: 0x181816)]]
        for style in Self.smooth {
            let light = Self.picture(style, .thinking, 0.7, appearance: .light), dark = Self.picture(style, .thinking, 0.7, appearance: .dark)
            #expect(light.raster != dark.raster, "style \(style) looks the same in Light and Dark")
            for appearance in Self.appearances {
                let bitmap = appearance == .light ? light : dark
                // the box's own corner-free interior: left of the first item, in the middle of the box
                let x = Int(Double(bitmap.box.x + 2) * bitmap.pixelsPerUnit), y = Int(Double(bitmap.box.y + bitmap.box.height / 2) * bitmap.pixelsPerUnit)
                #expect(bitmap.raster[x, y] == fills[style]![appearance], "style \(style) \(appearance): the fill is \(bitmap.raster[x, y])")
            }
        }
        // the pixel styles have one palette: the appearance changes nothing
        for style in [1, 6, 10, 13] {
            #expect(Self.picture(style, .thinking, 0.7, backing: 1, appearance: .light).raster == Self.picture(style, .thinking, 0.7, backing: 1, appearance: .dark).raster, "style \(style)")
        }
    }

    @Test func SmoothStyles_areDrawnAtTheDisplaysBackingScale() {
        for style in Self.smooth {
            let design = BubbleDesign.resolved(style)
            let text = Self.content(style, .thinking, 0.7)
            let picture = design.pictureExtent(runs: text.runs, dots: text.dots, variant: .roomy, connection: .above)
            let one = Self.picture(style, .thinking, 0.7, backing: 1), two = Self.picture(style, .thinking, 0.7, backing: 2)
            #expect(one.raster.width == picture.width && one.raster.height == picture.height, "style \(style) at 1x: \(one.raster.width) x \(one.raster.height) for \(picture)")
            #expect(two.raster.width == 2 * picture.width && two.raster.height == 2 * picture.height, "style \(style) at 2x")
            // drawn at 2x, not the 1x picture enlarged: its pixels are not 2 x 2 blocks
            let enlarged = one.raster.upscaled(by: 2)
            #expect(two.raster != enlarged, "style \(style): the 2x picture is the 1x picture enlarged")
            var blocks = 0
            for y in stride(from: 0, to: two.raster.height - 1, by: 2) { for x in stride(from: 0, to: two.raster.width - 1, by: 2) {
                let a = two.raster[x, y]
                if two.raster[x + 1, y] != a || two.raster[x, y + 1] != a || two.raster[x + 1, y + 1] != a { blocks += 1 }
            } }
            #expect(blocks > 100, "style \(style): only \(blocks) 2 x 2 blocks of the 2x picture are not flat")
        }
    }

    /// D-2 a and b, on unfaded pictures: every fully opaque pixel is one of the style's colours or a blend of the fill with one of them; the only partly
    /// transparent pixels inside the shape are within a device pixel of its outline; outside it the only paint is the shadow, black and never opaque.
    @Test func SmoothStyles_paintOnlyTheirFillBorderTextColoursAndTheBlendsBetween() throws {
        for style in Self.smooth { for appearance in Self.appearances { for backing in [1.0, 2.0] {
            let design = BubbleDesign.resolved(style).appearing(appearance)
            let own = Self.colours(style, appearance)
            var others = own.filter { $0 != design.fill }
            // 14 Dark's rim: the fill blended with white at 13% or less
            if let rim = design.rim { others.append(rim.colour) }
            // the reduced-motion dot pulses: the claude colour moved one and two thirds away from the fill (the same rule the pixel styles' palette uses)
            for level in 1...2 { others.append(design.color(.claude).pulsed(level: level, against: design.fill)) }
            var checked = 0
            for (scene, elapsed, reduce) in [(Scene.listening, 0.1, false), (.listening, 0.6, false), (.thinking, 0.7, false), (.thinking, 1.3, false), (.thinking, 0.5, true),
                                             (.sent, 1.0, false), (.sent, 1.5, false), (.interrupted, 0.2, false), (.error, 0.2, false)] {
                for (connection, opening, variant) in [(BubbleConnection.above, BubbleOpening.right, BubbleVariant.roomy), (.above, .left, .snug), (.side, .right, .roomy), (.side, .left, .snug)] {
                    let bitmap = Self.picture(style, scene, elapsed, reduce: reduce, backing: backing, appearance: appearance, connection: connection, opening: opening, variant: variant)
                    let mask = try SmoothChecks.shapeCoverage(style: style, bitmap: bitmap, appearance: appearance, connection: connection, opening: opening, variant: variant, backing: backing,
                                                              scene: scene, elapsed: elapsed, reduce: reduce)
                    for y in 0..<bitmap.raster.height { for x in 0..<bitmap.raster.width {
                        let p = bitmap.raster[x, y]
                        if p.a == 0 { continue }
                        let cover = mask.coverage(x, y)
                        if p.a == 255 {
                            if !Self.isBlend(p, of: design.fill, with: others) {
                                Issue.record("style \(style) \(appearance) \(scene)@\(elapsed) \(connection) \(backing)x: the opaque pixel \(p) at (\(x),\(y)) is no colour of the style nor a blend of the fill with one")
                                return
                            }
                        } else if cover == 0 {
                            if p.r != 0 || p.g != 0 || p.b != 0 { Issue.record("style \(style) \(appearance) \(scene): paint \(p) outside the shape at (\(x),\(y)) is not shadow"); return }
                        } else if cover >= 255, !mask.touchesTheOutline(x, y) {
                            Issue.record("style \(style) \(appearance) \(scene) \(connection) \(backing)x: a translucent pixel \(p) at (\(x),\(y)) lies inside the shape, more than a pixel from its outline")
                            return
                        }
                        checked += 1
                    } }
                }
            }
            #expect(checked > 1000)
        } } }
    }

    @Test func SmoothStyles_theShadowStaysInsideThePictureAndFadesOutAtItsEdge() throws {
        for style in Self.smooth { for appearance in Self.appearances { for backing in [1.0, 2.0] { for connection in [BubbleConnection.above, .side] {
            for variant in [BubbleVariant.roomy, .snug] {
                let bitmap = Self.picture(style, .thinking, 0.7, backing: backing, appearance: appearance, connection: connection, variant: variant)
                let mask = try SmoothChecks.shapeCoverage(style: style, bitmap: bitmap, appearance: appearance, connection: connection, opening: .right, variant: variant, backing: backing,
                                                          scene: .thinking, elapsed: 0.7, reduce: false)
                let raster = bitmap.raster
                // the shape's bounds in device pixels, then what the shadow reaches beyond them: 1 pt above, 2 pt beside, 3 pt below at most
                let bounds = try #require(mask.shapeBounds, "style \(style)")
                var reach = (above: 0, left: 0, right: 0, below: 0)
                for y in 0..<raster.height { for x in 0..<raster.width where raster[x, y].a > 0 && mask.coverage(x, y) == 0 {
                    reach.above = max(reach.above, bounds.minY - y); reach.below = max(reach.below, y - bounds.maxY)
                    reach.left = max(reach.left, bounds.minX - x); reach.right = max(reach.right, x - bounds.maxX)
                } }
                #expect(Double(reach.above) <= 1 * backing && Double(reach.below) <= 3 * backing && Double(reach.left) <= 2 * backing && Double(reach.right) <= 2 * backing,
                        "style \(style) \(appearance) \(connection) \(backing)x \(variant): the shadow reaches \(reach) device pixels")
                // the outermost ring of the picture is clear (at most 1/255), so no window edge clips visible paint
                var ring = 0
                for x in 0..<raster.width { ring = max(ring, Int(raster[x, 0].a), Int(raster[x, raster.height - 1].a)) }
                for y in 0..<raster.height { ring = max(ring, Int(raster[0, y].a), Int(raster[raster.width - 1, y].a)) }
                #expect(ring <= 1, "style \(style) \(appearance) \(connection) \(backing)x \(variant): the outermost ring has alpha \(ring)")
                #expect(reach.below > 0, "style \(style): there is a shadow")
            }
        } } } }
    }

    @Test func SmoothStyles_theSentFadeScalesEveryPixelShadowIncluded() {
        // The fade level over 4 is the opacity: 0.75, 0.5 and 0.25 from 1.7 s on, in steps of 0.1 s, and nothing from 2.0 s.
        #expect([1.65, 1.75, 1.85, 1.95].map { BubbleText.fadeLevel(scene: .sent, elapsed: $0) } == [4, 3, 2, 1])
        #expect(BubbleText.fadeLevel(scene: .sent, elapsed: 2.0) == 0 && BubbleText.nextChange(scene: .sent, elapsed: 2.0, design: BubbleDesign.resolved(14), reduceMotion: false, tick: 0.1) == nil)
        for style in Self.smooth { for appearance in Self.appearances { for backing in [1.0, 2.0] {
            let full = Self.picture(style, .sent, 1.0, backing: backing, appearance: appearance)
            for (level, opacity) in [(3, 0.75), (2, 0.5), (1, 0.25)] {
                let faded = Self.picture(style, .sent, 1.0, backing: backing, appearance: appearance, fade: level)
                #expect(faded.raster.width == full.raster.width && faded.raster.height == full.raster.height)
                var worst = 0, shadowPixels = 0
                for i in 0..<full.raster.data.count {
                    let expected = Int((Double(full.raster.data[i]) * opacity).rounded())
                    worst = max(worst, abs(Int(faded.raster.data[i]) - expected))
                }
                for y in 0..<full.raster.height { for x in 0..<full.raster.width where full.raster[x, y].a > 0 && full.raster[x, y].a < 255 && full.raster[x, y].r == 0 { shadowPixels += 1 } }
                #expect(worst <= 1, "style \(style) \(appearance) \(backing)x level \(level): a pixel is \(worst) off the unfaded one times \(opacity)")
                #expect(shadowPixels > 0)
            }
        } } }
    }

    @Test func SmoothStyles_drawEveryCharacterFromTheirNamedFontsOrAsShapes() throws {
        var characters = Set<Character>()
        for text in elements.present + elements.past + [elements.interrupt, elements.error, elements.ellipsis, "for", "0123456789 ms:h-", ClaudeElements.specDefaultTable["sent"]!,
                                                       "Interrupted", "Error", elements.promptChar, elements.completeGlyph, "\u{23BF}\u{25CF}\u{23FA}\u{276F}\u{273B}..."] {
            for ch in text where ch != "\u{00A0}" { characters.insert(ch) }
        }
        for glyph in elements.glyphs { for ch in glyph { characters.insert(ch) } }
        for style in Self.smooth {
            let design = BubbleDesign.resolved(style)
            let named = Set([SmoothFonts.name(SmoothFonts.primary(design))] + (style == 15 ? [SmoothFonts.name(SmoothFonts.marks)] : []))
            var missing: [Character] = [], elsewhere: [String] = []
            for ch in characters {
                switch SmoothFonts.source(of: ch, design: design) {
                case .missing: missing.append(ch)
                case .font(let name): if !named.contains(name) { elsewhere.append("\(ch) in \(name)") }
                case .shape: break
                }
            }
            #expect(missing.isEmpty, "style \(style): no glyph and no shape for \(missing.sorted())")
            #expect(elsewhere.isEmpty, "style \(style): drawn in a font it does not name: \(elsewhere)")
            // every CTRun of every line drawn uses one of the named fonts, never a cascade substitute
            for (scene, elapsed) in [(Scene.listening, 0.1), (.thinking, 0.0), (.thinking, 0.5), (.thinking, 0.8), (.sent, 1.0), (.interrupted, 0.2), (.error, 0.2)] {
                for verb in ["Cogitating", "Sautéing", elements.present.first!] {
                    for run in Self.content(style, scene, elapsed, verb: verb).runs where run.mark == nil && !run.text.isEmpty {
                        let line = CTLineCreateWithAttributedString(SmoothFonts.attributed(run.text, design: design, colour: nil))
                        for glyphRun in CTLineGetGlyphRuns(line) as! [CTRun] {
                            let attributes = CTRunGetAttributes(glyphRun) as NSDictionary
                            let font = attributes[kCTFontAttributeName as String] as! CTFont
                            #expect(named.contains(SmoothFonts.name(font)), "style \(style) \(scene) \(run.text): a run is set in \(SmoothFonts.name(font))")
                        }
                    }
                }
            }
        }
    }

    /// R3-3: the drawing configuration of 14 and 15 is one value, built by one function, and its flags are asserted here directly.
    @Test func SmoothStyles_theDrawingConfigurationIsFixed() {
        for backing in [1.0, 2.0, 3.0] {
            let c = SmoothBubble.drawingConfiguration(backing: backing)
            #expect(c.antialiasing == true, "shapes and text are anti-aliased")
            #expect(c.fontSmoothing == false, "font smoothing (stem darkening) is off, whatever the user's setting")
            #expect(c.fontSubpixelPositioning == true && c.fontSubpixelQuantization == false, "subpixel positioning on, quantization off")
            #expect(c.interpolation == CGInterpolationQuality.none, "nothing is resampled")
            #expect(c.colorSpace == CGColorSpace.sRGB as String, "colours are sRGB")
            #expect(c.scale == backing, "the drawing scale is the display's backing")
        }
        #expect(SmoothBubble.drawingConfiguration(backing: 0.2).scale == 1 && SmoothBubble.drawingConfiguration(backing: 9).scale == 4, "clamped to 1...4 like the stage")
        #expect(SmoothDrawingConfiguration.version == 1)
    }

    @Test func NewStyles_everyTextColourHasAtLeastFourPointFiveToOne() throws {
        for style in Self.drawn { for appearance in Self.appearances {
            let design = BubbleDesign.resolved(style).appearing(appearance)
            // nominal: every role and the cursor against the fill, in each appearance
            for pair in design.textPairs { #expect(Pixel.contrast(pair.foreground, pair.background) >= 4.5, "style \(style) \(appearance) \(pair.name): \(Pixel.contrast(pair.foreground, pair.background)):1") }
            if let cursor = design.cursorColour { #expect(Pixel.contrast(cursor, design.fill) >= 4.5, "style \(style) \(appearance): the cursor") }
            // the pulsing dot at every step, against the fill
            for level in 0...2 { #expect(Pixel.contrast(design.color(.claude).pulsed(level: level, against: design.fill), design.fill) >= 4.5, "style \(style) \(appearance) pulse step \(level)") }
            if style == 13 && appearance == .dark { continue }
            // rendered, at 2x: each run reaches its own colour in at least one pixel (a run drawn translucent or blended wrongly fails)
            for (scene, elapsed, reduce) in [(Scene.listening, 0.1, false), (.thinking, 0.7, false), (.thinking, 0.5, true), (.sent, 1.0, false), (.interrupted, 0.2, false), (.error, 0.2, false)] {
                let text = Self.content(style, scene, elapsed, reduce: reduce, appearance: appearance)
                let bitmap = Self.picture(style, scene, elapsed, reduce: reduce, backing: 2, appearance: appearance)
                var wanted: [(String, Pixel)] = text.runs.filter { $0.visible && ($0.mark != nil || !$0.text.trimmingCharacters(in: .whitespaces).isEmpty) }
                    .map { run in
                        // the block cursor has its own colour where the style names one (15 in Dark Mode)
                        let own = run.mark == .block ? (design.cursorColour ?? design.color(run.role)) : design.color(run.role)
                        return ("\(run.role) \(run.text.isEmpty ? "mark" : run.text)", own.pulsed(level: run.dimLevel, against: design.fill))
                    }
                if let glint = text.runs.first(where: { $0.glint != nil }), glint.glint != nil { wanted.append(("shimmer", design.color(.shimmer))) }
                for (name, colour) in wanted {
                    var reached = false
                    outer: for y in 0..<bitmap.raster.height { for x in 0..<bitmap.raster.width {
                        let p = bitmap.raster[x, y]
                        if p.a == 255, abs(Int(p.r) - Int(colour.r)) <= 2, abs(Int(p.g) - Int(colour.g)) <= 2, abs(Int(p.b) - Int(colour.b)) <= 2 { reached = true; break outer }
                    } }
                    #expect(reached, "style \(style) \(appearance) \(scene): the run \(name) never reaches its colour \(colour)")
                }
            }
        } }
    }

    @Test func NewStyles_theBoxNeverChangesWidthWhileItAnimates() {
        for style in Self.drawn {
            let design = BubbleDesign.resolved(style)
            for verb in ["Cogitating", "Flibbertigibbeting", "Clauding"] {
                var forms: [String: Set<Int>] = [:]
                for step in 0..<80 {
                    let t = Double(step) * 0.05
                    for (name, scene, reduce) in [("thinking", Scene.thinking, false), ("reduced", .thinking, true)] {
                        let text = Self.content(style, scene, t, verb: verb, reduce: reduce)
                        forms[name, default: []].insert(design.boxWidth(runs: text.runs, dots: text.dots))
                    }
                    if step < 40 { forms["listening", default: []].insert(design.boxWidth(runs: Self.content(style, .listening, t).runs, dots: nil)) }
                }
                for (name, widths) in forms { #expect(widths.count == 1, "style \(style) \(verb) \(name): the box takes widths \(widths.sorted())") }
            }
        }
    }

    /// D-8's grid rule: every boundary (elapsed + nextChange) lies on its state's scene-clock grid, from any starting elapsed.
    @Test func NewStyles_everyScheduledWakeLandsOnItsSceneGrid() {
        for style in Self.drawn {
            let design = BubbleDesign.resolved(style)
            func boundary(_ scene: Scene, _ t: Double, reduce: Bool = false) -> Double? {
                BubbleText.nextChange(scene: scene, elapsed: t, design: design, reduceMotion: reduce, tick: elements.tick).map { t + $0 }
            }
            func onGrid(_ value: Double, _ period: Double, origin: Double = 0) -> Bool {
                let k = ((value - origin) / period).rounded()
                return abs(origin + k * period - value) <= 1e-9
            }
            for start in [0.0, 0.09, 0.249, 0.51, 0.7, 1.234, 13.37, 179.99] {
                #expect(boundary(.thinking, start).map { onGrid($0, 0.1) } == true, "style \(style) thinking from \(start)")
                #expect(boundary(.thinking, start, reduce: true).map { onGrid($0, 0.25) } == true, "style \(style) reduced motion from \(start)")
                #expect(boundary(.listening, start).map { onGrid($0, 0.5) } == true, "style \(style) listening from \(start)")
            }
            for start in [0.0, 0.5, 1.59, 1.6, 1.64, 1.7, 1.85, 1.99] {
                let next = boundary(.sent, start)
                #expect(next.map { b in [1.6, 1.7, 1.8, 1.9, 2.0].contains { abs($0 - b) <= 1e-9 } } == true, "style \(style) SENT from \(start): \(String(describing: next))")
            }
            #expect(boundary(.interrupted, 0.1) == nil && boundary(.error, 0.1) == nil)
        }
    }

    /// D-8's cadence rule: walking the boundaries from the scene start, consecutive boundaries are at least the state's period apart.
    @Test func NewStyles_consecutiveBoundariesAreAtLeastTheirCadenceApart() {
        for style in Self.drawn {
            let design = BubbleDesign.resolved(style)
            for (scene, reduce, period) in [(Scene.thinking, false, 0.1), (.thinking, true, 0.25), (.listening, false, 0.5)] {
                var t = 0.0, last = 0.0
                for step in 0..<400 {
                    guard let next = BubbleText.nextChange(scene: scene, elapsed: t, design: design, reduceMotion: reduce, tick: elements.tick) else { break }
                    #expect(next > 1e-9, "style \(style) \(scene): a boundary \(next) s after \(t)")
                    t += next
                    if step > 0 { #expect(t - last >= period - 1e-6, "style \(style) \(scene) reduce \(reduce): boundaries \(t - last) s apart, under \(period)") }
                    last = t
                }
            }
        }
    }

    @Test func NewStyles_reducedMotionIsTheStillPulsingDot() throws {
        for style in Self.drawn {
            let design = BubbleDesign.resolved(style)
            var seen: [Int: BubbleBitmap] = [:]
            for step in 0..<16 {
                let t = Double(step) * 0.125
                let text = Self.content(style, .thinking, t, reduce: true)
                let dot = try #require(text.runs.first, "style \(style)")
                #expect(dot.glint == nil && text.runs.allSatisfy { if case .asterisk? = $0.mark { return false }; return true }, "style \(style): nothing turns or shimmers under Reduce Motion")
                if style == 14 { #expect(text.dots?.opacities == [1, 1, 1], "all three dots still at full colour") } else if style == 13 { #expect(text.dots == BubbleDots(count: 3)) }
                if style == 15 { #expect(text.dots == BubbleDots(count: 3)) }
                // the frames at one pulse step are the same picture; the pictures differ only in the dot
                let level = dot.dimLevel
                let picture = Self.picture(style, .thinking, t, reduce: true, backing: 1)
                if let earlier = seen[level] { #expect(earlier.raster == picture.raster, "style \(style) step \(level) at \(t)") } else { seen[level] = picture }
            }
            #expect(seen.count == 3, "style \(style): the pulse shows steps \(seen.keys.sorted())")
            _ = design
        }
    }

    @Test func NewStyles_aLeaseThatEndsInsideTheFadeLeavesNoFadedPaintOnTheNext() throws {
        for style in Self.drawn {
            let design = BubbleDesign.resolved(style)
            // lease A's SENT is at 1.85 s (level 2) when lease B opens; B ends with the same past verb and duration
            let text = Self.content(style, .sent, 1.0)
            let a = design.render(runs: text.runs, dots: nil, opening: .right, connection: .above, variant: .roomy, fadeLevel: BubbleText.fadeLevel(scene: .sent, elapsed: 1.85), backing: 2)
            let b = design.render(runs: text.runs, dots: nil, opening: .right, connection: .above, variant: .roomy, fadeLevel: BubbleText.fadeLevel(scene: .sent, elapsed: 1.0), backing: 2)
            #expect(a.raster != b.raster, "style \(style): the faded and the whole picture differ")
            let fresh = design.isSmooth
                ? SmoothBubble.draw(design: design, runs: text.runs, dots: nil, opening: .right, connection: .above, variant: .roomy, tipColumn: nil, fadeLevel: 4, backing: 2, appearance: .light)
                : design.render(runs: text.runs, dots: nil, opening: .right, connection: .above, variant: .roomy, fadeLevel: 4)
            #expect(b.raster == fresh.raster, "style \(style): the new lease's first SENT frame is a fresh render at full opacity")
        }
    }

    @Test func NewStyles_theLinesAreTodaysWordsInEachStylesOwnMarks() {
        func words(_ style: Int, _ scene: Scene, _ elapsed: Double = 0.7, reduce: Bool = false) -> String { Self.content(style, scene, elapsed, reduce: reduce).runs.map(\.text).joined() }
        // 13: the words of every style, with the fine font's marks and the dots after the verb
        #expect(words(13, .listening) == "\u{276F} \u{2588}" && words(13, .sent) == "\u{273B} Cooked for 5s" && words(13, .interrupted) == "\u{23BF} Interrupted" && words(13, .error) == "\u{23BF} Error")
        #expect(words(13, .thinking) == "\(elements.spinner(frame: BubbleText.phaseIndex(0.7, period: elements.tick))) Cogitating" && Self.content(13, .thinking, 0.7).dots == BubbleDots(count: 2))
        #expect(words(13, .thinking, 0.5, reduce: true) == "\u{25CF} Cogitating" && Self.content(13, .thinking, 0.5, reduce: true).dots == BubbleDots(count: 3))
        // 14 draws its marks as shapes: chevron and caret, the asterisk and the wave, the L-shaped hook; its words are the words
        let listening14 = Self.content(14, .listening, 0.1).runs
        #expect(listening14.map(\.mark) == [.chevron, .caret] && listening14[1].visible && !Self.content(14, .listening, 0.6).runs[1].visible)
        let thinking14 = Self.content(14, .thinking, 0.7)
        #expect(thinking14.runs.count == 2 && thinking14.runs[1].text == "Cogitating" && thinking14.runs[1].role == .ink && thinking14.dots?.opacities.count == 3)
        if case .asterisk(let degrees)? = thinking14.runs[0].mark { #expect(degrees == 84, "7 steps of 12 degrees at 0.7 s") } else { Issue.record("14's thinking line starts with the asterisk") }
        let sent14 = Self.content(14, .sent, 1.0).runs
        #expect(sent14.map(\.mark) == [.asterisk(degrees: 0), nil] && sent14[1].text == "Cooked for 5s" && sent14.allSatisfy { $0.role == .dim }, "the still asterisk, dim")
        #expect(Self.content(14, .interrupted, 0.2).runs.map(\.mark) == [.hook, nil] && Self.content(14, .interrupted, 0.2).runs[1].text == "Interrupted")
        #expect(Self.content(14, .error, 0.2).runs.map(\.role) == [.error, .error] && Self.content(14, .error, 0.2).runs[1].text == "Error")
        // 15 is text in a monospaced font: the prompt, the block, the spinner in its slot, the verb with the shimmer, the dots counted
        let listening15 = Self.content(15, .listening, 0.1).runs
        #expect(listening15.map(\.text) == ["\u{276F}", ""] && listening15[1].mark == .block)
        let thinking15 = Self.content(15, .thinking, 0.7)
        #expect(thinking15.runs[0].slot == 12 && thinking15.runs[1].text == "Cogitating" && thinking15.runs[1].glint != nil && thinking15.dots == BubbleDots(count: 2))
        // 15 draws the hook as a shape too (no font it names has it), in the spinner's slot
        #expect(Self.content(15, .sent, 1.0).runs.map(\.text) == ["\u{273B}", "Cooked for 5s"])
        let interrupted15 = Self.content(15, .interrupted, 0.2).runs, error15 = Self.content(15, .error, 0.2).runs
        #expect(interrupted15.map(\.mark) == [.hook, nil] && interrupted15[0].slot == 12 && interrupted15[1].text == "Interrupted")
        #expect(error15.map(\.mark) == [.hook, nil] && error15[0].slot == 12 && error15[1].text == "Error")
        // no "…" after any verb: the dots are each style's own, 15's are periods
        for style in Self.drawn { #expect(!Self.content(style, .thinking, 0.7).runs.contains { $0.text.contains("\u{2026}") }, "style \(style)") }
    }

    @Test func NewStyles_theLongestTextFitsEverySizeWithoutShortening() throws {
        for style in Self.drawn {
            let design = BubbleDesign.resolved(style)
            var widest = (width: 0, verb: "")
            func check(_ content: BubbleContent, _ label: String) {
                let text = BubbleText.content(content, elements: elements, design: design)
                #expect(BubbleText.fitted(text.runs, dots: text.dots, design: design) == text.runs, "style \(style) \(label): the text needed shortening")
                for connection in [BubbleConnection.above, .side] { for variant in [BubbleVariant.snug, .roomy] {
                    let e = design.pictureExtent(runs: text.runs, dots: text.dots, variant: variant, connection: connection)
                    let pt = BubbleChecks.pixelPt(design)
                    #expect(Double(e.width) * pt <= 200 && Double(e.height) * pt <= 48, "style \(style) \(label) \(connection) \(variant): \(Double(e.width) * pt) x \(Double(e.height) * pt) pt")
                    if connection == .above, variant == .roomy, Int(Double(e.width) * pt) > widest.width { widest = (Int(Double(e.width) * pt), label) }
                } }
            }
            for verb in elements.present { check(BubbleContent(scene: .thinking, elapsed: 0.7, verb: verb), "thinking \(verb)") }
            check(BubbleContent(scene: .sent, duration: BubbleChecks.longestDuration, pastVerb: "Cogitated"), "sent Cogitated 3h 59m")
            let sent = BubbleText.content(BubbleContent(scene: .sent, duration: BubbleChecks.longestDuration, pastVerb: "Cogitated"), elements: elements, design: design)
            let sentWidth = Double(design.pictureExtent(runs: sent.runs, dots: nil, variant: .roomy, connection: .above).width) * BubbleChecks.pixelPt(design)
            emit("WIDTH style \(style): widest of the 188 verbs \(widest.verb) \(widest.width) pt; the longest SENT line \(sentWidth) pt (above, roomy; the picture, shadow included)")
        }
    }

    @Test func NewStyles_aTooLongTextIsShortenedAndStaysInsideTheCap() {
        let long = String(repeating: "Whatchamacalliting", count: 4)
        for style in Self.drawn {
            let design = BubbleDesign.resolved(style)
            let text = BubbleText.content(BubbleContent(scene: .thinking, elapsed: 0.7, verb: long), elements: elements, design: design)
            let fitted = BubbleText.fitted(text.runs, dots: text.dots, design: design)
            #expect(fitted != text.runs, "style \(style): a \(long.count)-letter verb is shortened")
            for connection in [BubbleConnection.above, .side] { for variant in [BubbleVariant.snug, .roomy] {
                let e = design.pictureExtent(runs: fitted, dots: text.dots, variant: variant, connection: connection)
                #expect(Double(e.width) * BubbleChecks.pixelPt(design) <= 200, "style \(style) \(connection) \(variant): \(Double(e.width) * BubbleChecks.pixelPt(design)) pt")
            } }
            #expect(fitted.first { $0.text.hasPrefix("Whatcha") }.map { $0.text.count < long.count } == true)
        }
    }

    // MARK: animation as a pure function of scene time (D-8, R3-1)

    /// The shared index (R3-1): a time short of a boundary by under a nanosecond is on it; the instant before is still the step before.
    @Test func BubbleText_phaseIndexIsToleranceAwareAtEveryBoundary() {
        for period in [0.1, 0.2, 0.25, 0.4, 0.5] {
            for k in 1...400 {
                let boundary = Double(k) * period
                #expect(BubbleText.phaseIndex(boundary, period: period) == k, "at \(boundary) (period \(period))")
                #expect(BubbleText.phaseIndex(boundary + 1e-6, period: period) == k)
                #expect(BubbleText.phaseIndex(boundary - 1e-6, period: period) == k - 1, "the instant before \(boundary) (period \(period))")
            }
        }
        // accumulated boundaries: a clock that adds 0.1 s a hundred times is on step 100 at 10 s, as a plain floor would not say
        var t = 0.0
        for _ in 0..<100 { t += 0.1 }
        #expect(BubbleText.phaseIndex(t, period: 0.1) == 100)
        #expect(BubbleText.phaseIndex(1.2, period: 0.4) == 3, "1.2 s is the third 0.4 s step (count 1 of the next cycle)")
        #expect(BubbleAnimation.dotCount(at: 1.2) == 1 && BubbleAnimation.dotCount(at: 1.2 - 1e-6) == 3 && BubbleAnimation.dotCount(at: 1.2 + 1e-6) == 1)
        #expect(BubbleText.phaseIndex(-3, period: 0.1) == 0)
    }

    @Test func NewStyles_theAsteriskTurnsOnceEveryThreeSeconds() throws {
        let angles = (0...60).map { BubbleAnimation.asteriskDegrees(at: Double($0) * 0.1) }
        #expect(angles[0] == 0 && angles[1] == 12 && angles[2] == 24 && angles[29] == 348 && angles[30] == 0 && angles[60] == 0, "12 degrees a step, 3 s a turn")
        #expect(NewAnimationChecks.asteriskPeriodViolations(BubbleAnimation.asteriskDegrees(at:)).isEmpty)
        // in-suite control: the same checker fed the asterisk at half speed reports the wrong period
        negativeControl("asteriskHalfSpeed", expectationHolds: NewAnimationChecks.asteriskPeriodViolations { BubbleAnimation.asteriskDegrees(at: $0 / 2) }.isEmpty)
        // every rendered frame in [0, 3) s differs from the one 0.1 s later, and the frame at t is the frame drawn from the state at t
        for appearance in Self.appearances {
            var previous: Raster?
            for step in 0..<30 {
                let t = Double(step) * 0.1
                let picture = Self.picture(14, .thinking, t, backing: 1, appearance: appearance).raster
                if let previous { #expect(previous != picture, "the frame at \(t) s equals the one before it") }
                previous = picture
                let drawn = BubbleDesign.resolved(14).render(runs: [BubbleRun("", .claude, mark: .asterisk(degrees: BubbleAnimation.asteriskDegrees(at: t))), BubbleRun("Cogitating", .ink)],
                                                              dots: BubbleDots(opacities: BubbleAnimation.dotOpacities(at: t)), opening: .right, connection: .above, variant: .roomy, backing: 1,
                                                              appearance: appearance).raster
                #expect(drawn == picture, "the frame at \(t) s is not the frame drawn from the state")
            }
        }
    }

    @Test func NewStyles_theDotWaveRepeatsEveryOnePointTwoSecondsWithItsDelays() {
        #expect(NewAnimationChecks.dotWaveViolations(BubbleAnimation.dotOpacities(at:)).isEmpty, "\(NewAnimationChecks.dotWaveViolations(BubbleAnimation.dotOpacities(at:)))")
        negativeControl("dotWaveHalfSpeed", expectationHolds: NewAnimationChecks.dotWaveViolations { BubbleAnimation.dotOpacities(at: $0 / 2) }.isEmpty)
        // keyframes: 0.28 at 0%, 1.0 at 40% (0.48 s), 0.28 at 100%
        #expect(abs(BubbleAnimation.dotOpacity(tenthsIntoCycle: 0) - 0.28) < 1e-9 && BubbleAnimation.dotOpacity(tenthsIntoCycle: 5) > 0.99)
        let frame = (0..<12).map { BubbleAnimation.dotOpacities(at: Double($0) * 0.1) }
        #expect(frame.flatMap { $0 }.max()! >= 0.95 && frame.flatMap { $0 }.min()! <= 0.35)
        // the picture follows the state: with the dots held at 1.0 it differs from the wave's low points
        let low = BubbleDesign.resolved(14).render(runs: [BubbleRun("", .claude, mark: .asterisk(degrees: 0)), BubbleRun("Cogitating", .ink)], dots: BubbleDots(opacities: BubbleAnimation.dotOpacities(at: 0)),
                                                   opening: .right, connection: .above, variant: .roomy, backing: 2).raster
        let held = BubbleDesign.resolved(14).render(runs: [BubbleRun("", .claude, mark: .asterisk(degrees: 0)), BubbleRun("Cogitating", .ink)], dots: BubbleDots(opacities: [1, 1, 1]),
                                                    opening: .right, connection: .above, variant: .roomy, backing: 2).raster
        #expect(low != held)
    }

    @Test func NewStyles_theDotCounterStepsEveryFourTenthsOfASecond() {
        #expect([0.0, 0.4, 0.8, 1.2, 1.6, 2.0].map(BubbleAnimation.dotCount(at:)) == [1, 2, 3, 1, 2, 3], "1, 2, 3, 1 at 0, 0.4, 0.8 and 1.2 s")
        #expect(NewAnimationChecks.counterViolations(BubbleAnimation.dotCount(at:)).isEmpty)
        negativeControl("counterHalfSpeed", expectationHolds: NewAnimationChecks.counterViolations { BubbleAnimation.dotCount(at: $0 / 2) }.isEmpty)
        for style in [13, 15] {
            let design = BubbleDesign.resolved(style)
            for (t, count) in [(0.1, 1), (0.5, 2), (0.9, 3), (1.3, 1)] {
                let text = Self.content(style, .thinking, t)
                #expect(text.dots == BubbleDots(count: count), "style \(style) at \(t) s")
                // the rendered cells shown equal the count: the picture with fewer dots is a different picture, with more dots than shown it is not
                let shown = design.render(runs: text.runs, dots: text.dots, opening: .right, connection: .above, variant: .roomy, backing: 1).raster
                let other = design.render(runs: text.runs, dots: BubbleDots(count: count % 3 + 1), opening: .right, connection: .above, variant: .roomy, backing: 1).raster
                #expect(shown != other, "style \(style) at \(t) s: the dots shown do not follow the count")
            }
        }
    }

    @Test func NewStyles_theShimmerStartsOnTheVerbsLastLetter() {
        for verb in ["Cooking", "Flibbertigibbeting", "Hmm", "Imagining"] {
            #expect(BubbleAnimation.shimmerIndex(at: 0, letters: verb.count) == verb.count - 1, "g(0) = n - 1 for \(verb)")
        }
        // the letters at g-1, g and g+1 that lie inside the word, and only those, are in the shimmer colour
        let design = BubbleDesign.resolved(15)
        for appearance in Self.appearances {
            let d = design.appearing(appearance)
            let bitmap = Self.picture(15, .thinking, 0.0, verb: "Cooking", backing: 2, appearance: appearance)
            let base = Self.picture(15, .thinking, 0.0, verb: "Cooking", backing: 2, appearance: appearance)
            _ = base
            let shimmer = d.color(.shimmer)
            var count = 0
            for y in 0..<bitmap.raster.height { for x in 0..<bitmap.raster.width where abs(Int(bitmap.raster[x, y].r) - Int(shimmer.r)) <= 2 && abs(Int(bitmap.raster[x, y].g) - Int(shimmer.g)) <= 2
                && abs(Int(bitmap.raster[x, y].b) - Int(shimmer.b)) <= 2 && bitmap.raster[x, y].a == 255 { count += 1 } }
            #expect(count > 0, "\(appearance): at 0 s the last letters of the verb are in the shimmer colour")
        }
        #expect(BubbleText.nextChange(scene: .thinking, elapsed: 0.0, design: design, reduceMotion: false, tick: elements.tick) == 0.1)
    }

    @Test func NewStyles_theShimmerMovesOneLetterEveryFifthOfASecond() {
        let n = 7
        let indices = (0...60).map { BubbleAnimation.shimmerIndex(at: Double($0) * 0.2, letters: n) }
        #expect(indices[0] == 6 && indices[1] == 5 && indices[2] == 4, "one letter every 0.2 s, towards the first")
        #expect(NewAnimationChecks.shimmerViolations(letters: n, BubbleAnimation.shimmerIndex(at:letters:)).isEmpty, "\(NewAnimationChecks.shimmerViolations(letters: n, BubbleAnimation.shimmerIndex(at:letters:)))")
        negativeControl("shimmerHalfSpeed", expectationHolds: NewAnimationChecks.shimmerViolations(letters: n) { BubbleAnimation.shimmerIndex(at: $0 / 2, letters: $1) }.isEmpty)
        // the picture moves with it: the shimmer-coloured pixels sit further left a step later
        let design = BubbleDesign.resolved(15)
        func glintColumns(_ t: Double) -> (min: Int, max: Int)? {
            let bitmap = Self.picture(15, .thinking, t, verb: "Cooking", backing: 2)
            let shimmer = design.color(.shimmer)
            var columns: [Int] = []
            for y in 0..<bitmap.raster.height { for x in 0..<bitmap.raster.width where bitmap.raster[x, y].a == 255 && abs(Int(bitmap.raster[x, y].r) - Int(shimmer.r)) <= 2 &&
                abs(Int(bitmap.raster[x, y].g) - Int(shimmer.g)) <= 2 && abs(Int(bitmap.raster[x, y].b) - Int(shimmer.b)) <= 2 { columns.append(x) } }
            guard let low = columns.min(), let high = columns.max() else { return nil }
            return (low, high)
        }
        if let a = glintColumns(0.0), let b = glintColumns(0.4) { #expect(b.max < a.max, "the glint moved left: \(a) then \(b)") } else { Issue.record("no shimmer-coloured pixel at 0 s or 0.4 s") }
    }

    @Test func NewStyles_theSpinnerFollowsClaudeCodesClock() {
        for style in [13, 15] {
            for step in 0..<60 {
                let t = Double(step) * 0.1 + 0.05                  // the middle of a tick: no float edge
                let expected = elements.spinner(at: t)
                let glyph = Self.content(style, .thinking, t).runs[0].text
                #expect(glyph == expected, "style \(style) at \(t) s: \(glyph) against Claude Code's \(expected)")
            }
            // on the tick itself the state steps with the shared index, not a tick late
            #expect(BubbleAnimation.spinnerGlyph(at: 0.3, elements: elements) == elements.spinner(at: 0.35))
        }
        #expect(NewAnimationChecks.spinnerViolations { BubbleAnimation.spinnerGlyph(at: $0, elements: elements) }.isEmpty)
        negativeControl("spinnerHalfSpeed", expectationHolds: NewAnimationChecks.spinnerViolations { BubbleAnimation.spinnerGlyph(at: $0 / 2, elements: elements) }.isEmpty)
    }

    @Test func NewStyles_fifteenStylesAreDrawnAndAnIdOutsideThemFallsBackToTheOfficialBlue() throws {
        #expect(BubbleDesign.allIds == Array(1...15) && BubbleDesign.all.map(\.id) == BubbleDesign.allIds)
        for id in BubbleDesign.allIds { #expect(BubbleDesign.resolved(id).id == id, "style \(id) falls back although it is drawn") }
        for id in [0, 16, 99, -1] { #expect(BubbleDesign.resolved(id).id == 1, "\(id)") }
        for id in [13, 14, 15] {
            let frame = Frames.pose("listen", scene: .listening, bubble: BubbleState(style: id, scene: .listening))
            let drawn = try #require(try stageRenderer.compose(StageRequest(frame: frame, now: 0.25, geometry: Screens.geometry())))
            #expect(drawn.bubble?.style == id)
        }
    }
}
