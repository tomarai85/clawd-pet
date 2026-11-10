import Testing
import Foundation
import CoreGraphics
import ClawdCore
@testable import ClawdRendering

/// The review sheet of the nine phase-2 bubble styles for the progress page (spec 9b item 3): the layout of the phase-1 bubble sheet
/// (StagePreviewTests' `sheet-bubbles-2x.png`: two columns, a dark and a light made-up desktop, one row per style and scene, each tile
/// labelled in the pet's own pixel font), at 2x, drawn by the production renderer.
///
/// The test always writes `.evidence/v2/previews/sheet-bubbles-phase2-2x.png`. The committed copy is `art/preview/v2/sheet-bubbles-phase2-2x.png`;
/// `CLAWD_WRITE_REVIEW_SHEET=1 swift test --filter BubbleReviewSheetTests` replaces it. A second test decodes the committed copy and, when the goldens'
/// environment sidecar matches this Mac, requires it to equal what the renderer draws today.
@Suite("BubbleReviewSheetTests", .serialized)
struct BubbleReviewSheetTests {
    static let names = [2: "terminal input box", 3: "sticker", 4: "NES balloon", 5: "RPG dialogue", 7: "Clippy", 8: "Dynamic Island",
                        9: "toast", 11: "thought bubble", 12: "powerline"]
    static let backing = 2
    static let crop = CGRect(x: 548, y: 84, width: 300, height: 110)      // around Clawd at home (576, 100), as the phase-1 sheet
    static let committed = repository.appendingPathComponent("art/preview/v2/sheet-bubbles-phase2-2x.png")

    private static func label(_ text: String, width: Int) -> Raster {
        var strip = Raster(width: width / (2 * backing), height: 10)
        strip.fill(x: 0, y: 0, width: strip.width, height: strip.height, Pixel(rgb: 0x2A2A27))
        PixelFont.draw(text, into: &strip, x: 2, y: 2, color: Pixel(rgb: 0xE8E6DC))
        return strip.upscaled(by: 2 * backing)
    }

    static func tile(style: Int, scene: Scene, light: Bool) throws -> Raster {
        let pose = scene == .listening ? "listen" : scene == .thinking ? "think" : scene == .sent ? "hop" : "idle"
        let elapsed: Double = scene == .thinking ? 0.7 : scene == .sent ? 0.5 : 0.1
        let frame = Frames.pose(pose, scene: scene, bubble: BubbleState(style: style, scene: scene))
        let content = BubbleContent(scene: scene, elapsed: elapsed, duration: 5, verb: "Cogitating", pastVerb: "Cooked")
        let stage = try #require(try stageRenderer.compose(StageRequest(frame: frame, now: pose == "hop" ? 0.34 : 0.1, geometry: Screens.geometry(), pixelScale: Double(backing), content: content)))
        let picture = Desktop.crop(stage, around: crop, light: light, backing: backing)
        var out = Raster(width: picture.width, height: picture.height + 10 * 2 * backing)
        out.blit(label("style \(style) \(names[style] ?? "") \(scene.rawValue) \(light ? "light" : "dark")", width: picture.width), x: 0, y: 0)
        out.blit(picture, x: 0, y: 10 * 2 * backing)
        return out
    }

    static func sheet() throws -> Raster {
        var tiles: [Raster] = []
        for style in BubbleDesign.phase2Ids { for scene in BubbleContent.shownScenes { for light in [false, true] {
            tiles.append(try tile(style: style, scene: scene, light: light))
        } } }
        let columns = 2, pad = 6 * backing
        let w = tiles[0].width, h = tiles[0].height, rows = (tiles.count + columns - 1) / columns
        var out = Raster(width: columns * (w + pad) + pad, height: rows * (h + pad) + pad)
        out.fill(x: 0, y: 0, width: out.width, height: out.height, Pixel(rgb: 0x111110))
        for (i, t) in tiles.enumerated() { out.blit(t, x: pad + (i % columns) * (w + pad), y: pad + (i / columns) * (h + pad)) }
        return out
    }

    @Test func Sheet_theNineStylesInTheFiveScenesOnDarkAndLightAreWrittenForTheProgressPage() throws {
        let sheet = try Self.sheet()
        let png = try SceneRenderer.png(try sheet.cgImage())
        try evidenceStore("v2/previews").write(png, to: "sheet-bubbles-phase2-2x.png")
        #expect(sheet.width == 2 * (300 * Self.backing + 6 * Self.backing) + 6 * Self.backing && sheet.width == 1236, "same width as the phase-1 sheet: \(sheet.width)")
        #expect(sheet.height == BubbleDesign.phase2Ids.count * 5 * ((110 * Self.backing + 20 * Self.backing) + 6 * Self.backing) + 6 * Self.backing, "\(sheet.height)")
        if ProcessInfo.processInfo.environment["CLAWD_WRITE_REVIEW_SHEET"] == "1" {
            try OwnState(root: repository.appendingPathComponent("art/preview/v2")).write(png, to: "sheet-bubbles-phase2-2x.png")
            emit("RECORDED: art/preview/v2/sheet-bubbles-phase2-2x.png \(sheet.width) x \(sheet.height)")
        }
    }

    @Test func Sheet_theCommittedReviewSheetDecodesAndShowsWhatTheRendererDrawsToday() throws {
        guard ProcessInfo.processInfo.environment["CLAWD_WRITE_REVIEW_SHEET"] != "1" else { return }
        let data = try ReadOnlyFile.data(Self.committed.path)
        let decoded = try Raster.decode(png: data)
        #expect(decoded.width == 1236 && decoded.height > 10_000, "\(decoded.width) x \(decoded.height)")
        // every phase-2 style's fill shows up in it, so no style is missing from the sheet
        var seen = Set<Pixel>()
        for y in stride(from: 0, to: decoded.height, by: 3) { for x in stride(from: 0, to: decoded.width, by: 3) { seen.insert(decoded[x, y]) } }
        for design in BubbleDesign.all where BubbleDesign.phase2Ids.contains(design.id) { #expect(seen.contains(design.fill), "style \(design.id)'s fill is not in the sheet") }
        let environment = try StageGoldens.environment()
        #expect(environment == nil, "\(String(describing: environment)): the sheet cannot be compared on this Mac")
        guard environment == nil else { return }
        let fresh = try Self.sheet()
        #expect(fresh.width == decoded.width && fresh.height == decoded.height && fresh == decoded, "the committed review sheet is out of date: re-run with CLAWD_WRITE_REVIEW_SHEET=1")
    }
}


// MARK: the sheets of styles 13, 14 and 15 (amendment R-BUBBLES, section 3)

/// The review sheets of the board's mock B, C and D for the progress page: every scene, 14 and 15 in Light on the light desktop and in Dark on the dark one,
/// 13 (one palette) on both. A 2x sheet and a 1x real-size sheet, drawn by the production renderer.
///
/// The test always writes `.evidence/v2/previews/sheet-bubbles-13-15-{2x,1x}.png`. The committed copies are `art/preview/v2/sheet-bubbles-13-15-{2x,1x}.png`;
/// `CLAWD_WRITE_REVIEW_SHEET=1 swift test --filter BubbleReviewSheetTests` replaces them.
@Suite("BubbleReviewSheetTests new styles", .serialized)
struct BubbleReviewSheetNewStylesTests {
    static let names = [13: "pixel art", 14: "macOS", 15: "CC panel"]
    static func committed(_ backing: Int) -> URL { repository.appendingPathComponent("art/preview/v2/sheet-bubbles-13-15-\(backing)x.png") }

    private static func label(_ text: String, width: Int, backing: Int) -> Raster {
        var strip = Raster(width: width / (2 * backing), height: 10)
        strip.fill(x: 0, y: 0, width: strip.width, height: strip.height, Pixel(rgb: 0x2A2A27))
        PixelFont.draw(text, into: &strip, x: 2, y: 2, color: Pixel(rgb: 0xE8E6DC))
        return strip.upscaled(by: 2 * backing)
    }

    static func tile(style: Int, scene: Scene, light: Bool, backing: Int) throws -> Raster {
        let pose = scene == .listening ? "listen" : scene == .thinking ? "think" : scene == .sent ? "hop" : "idle"
        let elapsed: Double = scene == .thinking ? 0.7 : scene == .sent ? 0.5 : 0.1
        let frame = Frames.pose(pose, scene: scene, bubble: BubbleState(style: style, scene: scene))
        let content = BubbleContent(scene: scene, elapsed: elapsed, duration: 5, verb: "Cogitating", pastVerb: "Cooked", appearance: light ? .light : .dark)
        let stage = try #require(try stageRenderer.compose(StageRequest(frame: frame, now: pose == "hop" ? 0.34 : 0.1, geometry: Screens.geometry(), pixelScale: Double(backing), content: content)))
        let picture = Desktop.crop(stage, around: BubbleReviewSheetTests.crop, light: light, backing: backing)
        var out = Raster(width: picture.width, height: picture.height + 10 * 2 * backing)
        out.blit(label("style \(style) \(names[style] ?? "") \(scene.rawValue) \(light ? "light" : "dark")", width: picture.width, backing: backing), x: 0, y: 0)
        out.blit(picture, x: 0, y: 10 * 2 * backing)
        return out
    }

    static func sheet(backing: Int) throws -> Raster {
        var tiles: [Raster] = []
        for style in [13, 14, 15] { for scene in BubbleContent.shownScenes { for light in [false, true] { tiles.append(try tile(style: style, scene: scene, light: light, backing: backing)) } } }
        let columns = 2, pad = 6 * backing
        let w = tiles[0].width, h = tiles[0].height, rows = (tiles.count + columns - 1) / columns
        var out = Raster(width: columns * (w + pad) + pad, height: rows * (h + pad) + pad)
        out.fill(x: 0, y: 0, width: out.width, height: out.height, Pixel(rgb: 0x111110))
        for (i, t) in tiles.enumerated() { out.blit(t, x: pad + (i % columns) * (w + pad), y: pad + (i / columns) * (h + pad)) }
        return out
    }

    @Test func Sheet_theNewStylesInTheFiveScenesOnDarkAndLightAreWrittenForTheProgressPage() throws {
        for backing in [2, 1] {
            let sheet = try Self.sheet(backing: backing)
            let png = try SceneRenderer.png(try sheet.cgImage())
            try evidenceStore("v2/previews").write(png, to: "sheet-bubbles-13-15-\(backing)x.png")
            #expect(sheet.width == 2 * (300 * backing + 6 * backing) + 6 * backing, "\(sheet.width)")
            #expect(sheet.height == 15 * ((110 * backing + 20 * backing) + 6 * backing) + 6 * backing, "\(sheet.height)")
            if ProcessInfo.processInfo.environment["CLAWD_WRITE_REVIEW_SHEET"] == "1" {
                try OwnState(root: repository.appendingPathComponent("art/preview/v2")).write(png, to: "sheet-bubbles-13-15-\(backing)x.png")
                emit("RECORDED: art/preview/v2/sheet-bubbles-13-15-\(backing)x.png \(sheet.width) x \(sheet.height)")
            }
        }
    }

    @Test func Sheet_theCommittedNewReviewSheetsDecodeAndShowWhatTheRendererDrawsToday() throws {
        guard ProcessInfo.processInfo.environment["CLAWD_WRITE_REVIEW_SHEET"] != "1" else { return }
        for backing in [2, 1] {
            let decoded = try Raster.decode(png: try ReadOnlyFile.data(Self.committed(backing).path))
            #expect(decoded.width == 2 * (300 * backing + 6 * backing) + 6 * backing && decoded.height == 15 * ((110 * backing + 20 * backing) + 6 * backing) + 6 * backing, "\(decoded.width) x \(decoded.height)")
            var seen = Set<Pixel>()
            for y in stride(from: 0, to: decoded.height, by: 3) { for x in stride(from: 0, to: decoded.width, by: 3) { seen.insert(decoded[x, y]) } }
            for style in [13, 14, 15] { #expect(seen.contains(BubbleDesign.resolved(style).fill), "style \(style)'s Light fill is not in the sheet") }
            // the sheet can be compared where both the pixel goldens' environment and the smooth sidecar match this Mac
            let pixelEnvironment = try StageGoldens.environment()
            let recorded = try JSONDecoder().decode(SmoothEnvironment.self, from: try ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent(SmoothGoldenRecorder.sidecarPath).path))
            let smooth = try SmoothEnvironment.current().compare(to: recorded)
            #expect(pixelEnvironment == nil && smooth == .match, "\(String(describing: pixelEnvironment)) \(smooth): the sheet cannot be compared on this Mac")
            guard pixelEnvironment == nil, smooth == .match else { continue }
            let fresh = try Self.sheet(backing: backing)
            #expect(fresh == decoded, "the committed \(backing)x review sheet is out of date: re-run with CLAWD_WRITE_REVIEW_SHEET=1")
        }
    }
}


// MARK: the sheet of the four sides (amendment D-6)

/// One bubble on all four sides of Clawd, for the progress page: a few styles (the stair, the dots, the thought trail, the pixel art, the macOS bubble and
/// Claude Code's panel), each on its own row with below, above, left and right, on a made-up dark desktop. A 2x sheet drawn by the production renderer.
///
/// The test always writes `.evidence/v2/previews/sheet-bubble-sides-2x.png`. The committed copy is `art/preview/v2/sheet-bubble-sides-2x.png`;
/// `CLAWD_WRITE_REVIEW_SHEET=1 swift test --filter BubbleReviewSheetTests` replaces it.
@Suite("BubbleReviewSheetTests sides", .serialized)
struct BubbleReviewSheetSidesTests {
    static let styles = [1, 4, 6, 11, 13, 14, 15]
    static let backing = 2
    static let crop = CGRect(x: 436, y: 226, width: 408, height: 178)
    static let committed = repository.appendingPathComponent("art/preview/v2/sheet-bubble-sides-2x.png")

    private static func label(_ text: String, width: Int) -> Raster {
        var strip = Raster(width: width / (2 * backing), height: 10)
        strip.fill(x: 0, y: 0, width: strip.width, height: strip.height, Pixel(rgb: 0x2A2A27))
        PixelFont.draw(text, into: &strip, x: 2, y: 2, color: Pixel(rgb: 0xE8E6DC))
        return strip.upscaled(by: 2 * backing)
    }

    static func tile(style: Int, side: BubbleSide, light: Bool) throws -> Raster {
        let frame = Frames.pose("think", scene: .thinking, bubble: BubbleState(style: style, scene: .thinking))
        let content = BubbleContent(scene: .thinking, elapsed: 0.7, duration: 5, verb: "Cogitating", pastVerb: "Cooked", appearance: light ? .light : .dark)
        let request = StageRequest(frame: frame, now: 0.1, geometry: Screens.geometry(homeY: 300), pixelScale: Double(backing), content: content, bubbleSide: side)
        let stage = try #require(try stageRenderer.compose(request))
        #expect(stage.bubble?.plan.side == side, "style \(style): chosen \(side), shown \(String(describing: stage.bubble?.plan.side))")
        let picture = Desktop.crop(stage, around: crop, light: light, backing: backing)
        var out = Raster(width: picture.width, height: picture.height + 10 * 2 * backing)
        out.blit(label("style \(style) \(side.rawValue)", width: picture.width), x: 0, y: 0)
        out.blit(picture, x: 0, y: 10 * 2 * backing)
        return out
    }

    static func sheet() throws -> Raster {
        var tiles: [Raster] = []
        for style in styles { for side in BubbleSide.allCases { tiles.append(try tile(style: style, side: side, light: false)) } }
        let columns = 4, pad = 6 * backing
        let w = tiles[0].width, h = tiles[0].height, rows = (tiles.count + columns - 1) / columns
        var out = Raster(width: columns * (w + pad) + pad, height: rows * (h + pad) + pad)
        out.fill(x: 0, y: 0, width: out.width, height: out.height, Pixel(rgb: 0x111110))
        for (i, t) in tiles.enumerated() { out.blit(t, x: pad + (i % columns) * (w + pad), y: pad + (i / columns) * (h + pad)) }
        return out
    }

    @Test func Sheet_theFourSidesOfSevenStylesAreWrittenForTheProgressPage() throws {
        let sheet = try Self.sheet()
        let png = try SceneRenderer.png(try sheet.cgImage())
        try evidenceStore("v2/previews").write(png, to: "sheet-bubble-sides-2x.png")
        #expect(sheet.width == 4 * (408 * Self.backing + 6 * Self.backing) + 6 * Self.backing, "\(sheet.width)")
        if ProcessInfo.processInfo.environment["CLAWD_WRITE_REVIEW_SHEET"] == "1" {
            try OwnState(root: repository.appendingPathComponent("art/preview/v2")).write(png, to: "sheet-bubble-sides-2x.png")
            emit("RECORDED: art/preview/v2/sheet-bubble-sides-2x.png \(sheet.width) x \(sheet.height)")
        }
    }

    @Test func Sheet_theCommittedSidesSheetDecodesAndShowsWhatTheRendererDrawsToday() throws {
        guard ProcessInfo.processInfo.environment["CLAWD_WRITE_REVIEW_SHEET"] != "1" else { return }
        let decoded = try Raster.decode(png: try ReadOnlyFile.data(Self.committed.path))
        let fresh = try Self.sheet()
        #expect(decoded.width == fresh.width && decoded.height == fresh.height, "\(decoded.width) x \(decoded.height)")
        let pixelEnvironment = try StageGoldens.environment()
        let recorded = try JSONDecoder().decode(SmoothEnvironment.self, from: try ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent(SmoothGoldenRecorder.sidecarPath).path))
        let smooth = try SmoothEnvironment.current().compare(to: recorded)
        #expect(pixelEnvironment == nil && smooth == .match, "\(String(describing: pixelEnvironment)) \(smooth): the sheet cannot be compared on this Mac")
        guard pixelEnvironment == nil, smooth == .match else { return }
        #expect(fresh == decoded, "the committed sides sheet is out of date: re-run with CLAWD_WRITE_REVIEW_SHEET=1")
    }
}
