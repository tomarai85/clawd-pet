import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ClawdCore
import ClawdRendering

// Everything here renders through the same SceneRenderer.render that sets `layer.contents`, into a bitmap. No window.

private let goldenDirectory = repository.appendingPathComponent("Tests/Goldens")

private func decodePNG(_ data: Data) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

enum GoldenVerdict: Equatable {
    case pass, envMismatch([String]), pixelDiff(Int), sizeDiff, missing(String)
}

/// Compares one scene against its checked-in PNG. An environment mismatch prints ENV-MISMATCH and is never a pass.
func goldenVerdict(_ scene: Scene, goldens: URL = goldenDirectory, currentEnvironment: GoldenEnvironment? = nil) throws -> GoldenVerdict {
    guard let sidecar = try? ReadOnlyFile.data(goldens.appendingPathComponent("environment.json").path),
          let recorded = try? JSONDecoder().decode(GoldenEnvironment.self, from: sidecar) else {
        emit("MISSING-GOLDEN: environment.json"); return .missing("environment.json")
    }
    let current = try currentEnvironment ?? GoldenEnvironment.current(art: artDirectory)
    if case .mismatch(let differences) = current.compare(to: recorded) {
        emit("ENV-MISMATCH: \(differences.joined(separator: ","))"); return .envMismatch(differences)
    }
    let renderer = try SceneRenderer(art: artDirectory)
    let actual = try renderer.render(GoldenEnvironment.frame(scene), fixedCanvas: true)
    try evidenceStore("goldens-actual").write(SceneRenderer.png(actual), to: scene.rawValue + ".png")
    guard let expectedData = try? ReadOnlyFile.data(goldens.appendingPathComponent(scene.rawValue + ".png").path) else {
        emit("MISSING-GOLDEN: \(scene.rawValue).png"); return .missing(scene.rawValue + ".png")
    }
    let expected = try decodePNG(expectedData)
    guard actual.width == expected.width, actual.height == expected.height else { return .sizeDiff }
    let a = try SceneRenderer.pixels(actual), b = try SceneRenderer.pixels(expected)
    let differing = zip(a, b).filter { $0 != $1 }.count
    return differing == 0 ? .pass : .pixelDiff(differing)
}

private struct Pixel: Equatable { var r: UInt8, g: UInt8, b: UInt8, a: UInt8 }
private struct Raster {
    let width: Int, height: Int, data: Data
    init(_ image: CGImage) throws { width = image.width; height = image.height; data = try SceneRenderer.pixels(image) }
    func rgba(_ x: Int, _ y: Int) -> Pixel {
        let i = (y * width + x) * 4; return Pixel(r: data[i], g: data[i + 1], b: data[i + 2], a: data[i + 3])
    }
    func count(inX xs: Range<Int>, _ ys: Range<Int>, where match: (Pixel) -> Bool) -> Int {
        var n = 0
        for y in ys { for x in xs where match(rgba(x, y)) { n += 1 } }
        return n
    }
}
private func isOrange(_ p: Pixel) -> Bool { p.r == 215 && p.g == 119 && p.b == 87 && p.a == 255 }
private func isEye(_ p: Pixel) -> Bool { p.r == 20 && p.g == 20 && p.b == 19 && p.a == 255 }

/// Connected groups of eye-coloured pixels inside the 48 x 48 body, as their pixel counts.
private func eyeComponents(_ r: Raster) -> [Int] {
    var seen = Set<Int>(), sizes: [Int] = []
    for y in 0..<min(48, r.height) { for x in 0..<48 where isEye(r.rgba(x, y)) && !seen.contains(y * 1000 + x) {
        var stack = [(x, y)], size = 0
        seen.insert(y * 1000 + x)
        while let (cx, cy) = stack.popLast() {
            size += 1
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = cx + dx, ny = cy + dy
                if nx >= 0, nx < 48, ny >= 0, ny < min(48, r.height), isEye(r.rgba(nx, ny)), seen.insert(ny * 1000 + nx).inserted { stack.append((nx, ny)) }
            }
        }
        sizes.append(size)
    } }
    return sizes.sorted()
}

private func normalRender(_ scene: Scene) throws -> Raster {
    let renderer = try SceneRenderer(art: artDirectory)
    return try Raster(renderer.render(GoldenEnvironment.frame(scene)))
}

@Suite("Golden PNGs and render content")
struct GoldenSuite {
    private func matches(_ scene: Scene) throws {
        let verdict = try goldenVerdict(scene)
        #expect(verdict == .pass, "golden \(scene.rawValue): \(verdict)")
    }
    @Test func Golden_idleMatchesPixelForPixel() throws { try matches(.idle) }
    @Test func Golden_listeningMatchesPixelForPixel() throws { try matches(.listening) }
    @Test func Golden_thinkingMatchesPixelForPixel() throws { try matches(.thinking) }
    @Test func Golden_sentMatchesPixelForPixel() throws { try matches(.sent) }
    @Test func Golden_interruptedMatchesPixelForPixel() throws { try matches(.interrupted) }
    @Test func Golden_errorMatchesPixelForPixel() throws { try matches(.error) }
    @Test func Golden_sleepMatchesPixelForPixel() throws { try matches(.sleep) }
    @Test func Golden_dragMatchesPixelForPixel() throws { try matches(.drag) }

    @Test func Golden_aMismatchedEnvironmentPrintsEnvMismatchAndNeverPasses() throws {
        let real = try GoldenEnvironment.current(art: artDirectory)
        let doctored = GoldenEnvironment(swVers: real.swVers + "BuildVersion: other\n", fontPath: "/Library/Fonts/Other.ttf",
                                         fontSHA256: real.fontSHA256, colorSpace: real.colorSpace, scale: real.scale,
                                         virtualTime: real.virtualTime, artSHA256: real.artSHA256)
        let verdict = try goldenVerdict(.idle, currentEnvironment: doctored)
        #expect(verdict == .envMismatch(["sw_vers", "font_path"]))
        #expect(verdict != .pass)
        // A changed art directory alone is not an environment problem: it shows as a pixel diff instead.
        let artOnly = GoldenEnvironment(swVers: real.swVers, fontPath: real.fontPath, fontSHA256: real.fontSHA256,
                                        colorSpace: real.colorSpace, scale: real.scale, virtualTime: real.virtualTime, artSHA256: "changed")
        #expect(artOnly.compare(to: real) == .match)
    }
    @Test func Golden_aMissingGoldenFailsInsteadOfPassing() throws {
        // The real comparison function, pointed at a directory that holds the sidecar but no PNG, and at one that holds nothing.
        let sidecarOnly = try artifactStore()
        try sidecarOnly.write(try ReadOnlyFile.data(goldenDirectory.appendingPathComponent("environment.json").path), to: "environment.json")
        let noPNG = try goldenVerdict(.idle, goldens: sidecarOnly.root)
        #expect(noPNG == .missing("idle.png"), "\(noPNG)")
        #expect(noPNG != .pass)
        let nothing = try goldenVerdict(.idle, goldens: try artifactStore().root.appendingPathComponent("does-not-exist"))
        #expect(nothing == .missing("environment.json"), "\(nothing)")
        #expect(nothing != .pass)
        // Every scene fails the same way, and the shipped directory still passes through this very function.
        for scene in Scene.allCases { #expect(try goldenVerdict(scene, goldens: sidecarOnly.root) == .missing(scene.rawValue + ".png")) }
        #expect(try goldenVerdict(.idle) == .pass)
    }
    @Test func Golden_sidecarRecordsTheOSBuildAndTheFixedFontFile() throws {
        let text = String(decoding: try ReadOnlyFile.data(goldenDirectory.appendingPathComponent("environment.json").path), as: UTF8.self)
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect((object["sw_vers"] as? String)?.contains("ProductVersion") == true)
        #expect((object["sw_vers"] as? String)?.contains("BuildVersion") == true)
        #expect(object["font_path"] as? String == "/System/Library/Fonts/Menlo.ttc")
        #expect(object["color_space"] as? String == "sRGB")
        #expect(FileManager.default.fileExists(atPath: "/System/Library/Fonts/Menlo.ttc"))
    }
    @Test func Golden_rendersAreByteForByteDeterministic() throws {
        for scene in Scene.allCases {
            let renderer = try SceneRenderer(art: artDirectory)
            let a = try SceneRenderer.pixels(renderer.render(GoldenEnvironment.frame(scene), fixedCanvas: true))
            let b = try SceneRenderer.pixels(renderer.render(GoldenEnvironment.frame(scene), fixedCanvas: true))
            #expect(a == b, "\(scene)")
        }
    }
    @Test func Golden_allEightGoldenFilesExistWithTheSameCanvas() throws {
        var sizes = Set<String>()
        for scene in Scene.allCases {
            let image = try decodePNG(try ReadOnlyFile.data(goldenDirectory.appendingPathComponent(scene.rawValue + ".png").path))
            sizes.insert("\(image.width)x\(image.height)")
        }
        #expect(sizes.count == 1, "\(sizes)")
    }
    @Test func Golden_bodyIs48PointsWideAtScaleOneAndMadeOfOrangeBlocks() throws {
        let renderer = try SceneRenderer(art: artDirectory)
        #expect(Double(renderer.atlas.width) * renderer.atlas.unit == 48)
        #expect(Double(renderer.atlas.height) * renderer.atlas.unit == 48)
        for scene in Scene.allCases {
            let r = try normalRender(scene)
            #expect(r.count(inX: 0..<48, 0..<min(48, r.height), where: isOrange) > 500, "\(scene) body orange")
            // nearest-neighbour: every aligned 4 x 4 block is one colour
            var uniform = true
            for by in stride(from: 0, to: min(48, r.height), by: 4) { for bx in stride(from: 0, to: 48, by: 4) {
                let first = r.rgba(bx, by)
                for y in by..<by + 4 { for x in bx..<bx + 4 where r.rgba(x, y) != first { uniform = false } }
            } }
            #expect(uniform, "\(scene) blocks are not uniform")
        }
    }
    @Test func Golden_eyesAreBlackSingleUnitBlocksInEveryOpenEyedSceneAndClosedInSleep() throws {
        for scene in Scene.allCases where scene != .sleep {
            let sizes = eyeComponents(try normalRender(scene))
            #expect(sizes == [16, 16], "\(scene): \(sizes)")
        }
        let sleep = eyeComponents(try normalRender(.sleep))
        #expect(sleep.allSatisfy { $0 > 16 } || sleep.isEmpty, "sleep eyes: \(sleep)")
        #expect(sleep != [16, 16])
    }
    @Test func Golden_aRetinaRenderHasTwiceThePixelsAndKeepsEveryBlockUniform() throws {
        let renderer = try SceneRenderer(art: artDirectory)
        for scene in [Scene.idle, .listening, .thinking, .error] {
            let one = try Raster(renderer.render(RenderFrame(scene: scene, elapsed: 0.25, pixelScale: 1)))
            let two = try Raster(renderer.render(RenderFrame(scene: scene, elapsed: 0.25, pixelScale: 2)))
            #expect(two.width == one.width * 2); #expect(two.height == one.height * 2)
            #expect(two.count(inX: 0..<96, 0..<96, where: isOrange) == one.count(inX: 0..<48, 0..<48, where: isOrange) * 4)
            var uniform = true
            for by in stride(from: 0, to: 96, by: 8) { for bx in stride(from: 0, to: 96, by: 8) {
                let first = two.rgba(bx, by)
                for y in by..<by + 8 { for x in bx..<bx + 8 where two.rgba(x, y) != first { uniform = false } }
            } }
            #expect(uniform, "\(scene) at 2x")
        }
    }
    @Test func Golden_chipIsHiddenForIdleSleepAndDragOnlyAndItsWidthShowsIt() throws {
        for scene in Scene.allCases {
            let r = try normalRender(scene)
            switch scene {
            case .idle, .sleep: #expect(r.width == 48, "\(scene) must be Clawd only")
            default: #expect(r.width > 48 + 60, "\(scene) must carry a chip")
            }
        }
    }
    @Test func Golden_chipColoursFollowClaudeCode() throws {
        func chipCount(_ scene: Scene, _ rgb: (UInt8, UInt8, UInt8)) throws -> Int {
            let r = try normalRender(scene)
            return r.count(inX: 56..<r.width, 0..<r.height) { $0.r == rgb.0 && $0.g == rgb.1 && $0.b == rgb.2 && $0.a == 255 }
        }
        #expect(try chipCount(.listening, (136, 136, 136)) > 20)        // promptBorder
        #expect(try chipCount(.thinking, (215, 119, 87)) > 5)           // claude orange spinner and verb
        #expect(try chipCount(.error, (255, 107, 128)) > 5)             // error red
        #expect(try chipCount(.interrupted, (153, 153, 153)) > 5)       // dim gray
        #expect(try chipCount(.sent, (153, 153, 153)) > 5)
        #expect(try chipCount(.interrupted, (255, 107, 128)) == 0)
        #expect(try chipCount(.interrupted, (215, 119, 87)) == 0)
    }
    @Test func Golden_everyChipStringComesFromTheExtractedElementsFile() throws {
        let data = try ReadOnlyFile.data(artDirectory.appendingPathComponent("claude-code-elements.json").path)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func object(_ key: String) -> [String: Any] { json[key] as? [String: Any] ?? [:] }
        let glyphs = try #require(object("spinner_glyphs")["default_sequence"] as? [String])
        let present = try #require(object("present_verbs")["values"] as? [String])
        let past = try #require(object("past_verbs")["values"] as? [String])
        let interrupt = try #require(object("interrupt")["rendered"] as? String)
        let prefix = try #require(object("interrupt")["prefix"] as? String)
        let prompt = try #require(object("input_box")["prompt_char"] as? String)
        let ellipsis = try #require(object("ellipsis")["value"] as? String)
        let complete = try #require(object("turn_complete_line")["prefix_glyph"] as? String)
        let renderer = try SceneRenderer(art: artDirectory)
        #expect(prompt == "\u{276F}")         // Claude Code's own prompt character, not the ASCII stand-in
        #expect(renderer.chipText(RenderFrame(scene: .listening)) == prompt + " ")
        let thinking = renderer.chipText(RenderFrame(scene: .thinking, elapsed: 0, verb: present[3]))
        #expect(thinking == glyphs[0] + " " + present[3] + ellipsis)
        #expect(renderer.chipText(RenderFrame(scene: .interrupted)) == interrupt)
        #expect(renderer.chipText(RenderFrame(scene: .error)) == prefix + "Error")
        #expect(renderer.chipText(RenderFrame(scene: .sent, duration: 5, pastVerb: past[4])) == complete + " " + past[4] + " for 5s")
        #expect(renderer.chipText(RenderFrame(scene: .sent, duration: 72, pastVerb: "Worked")) == complete + " Worked for 1m 12s")
        #expect(renderer.chipText(RenderFrame(scene: .idle)).isEmpty); #expect(renderer.chipText(RenderFrame(scene: .sleep)).isEmpty)
    }
    @Test func Golden_theListeningPromptIsClaudeCodesCharacterWhenTheFontCanDrawItAndAsciiOnlyWhenItCannot() throws {
        let renderer = try SceneRenderer(art: artDirectory)
        let data = try ReadOnlyFile.data(artDirectory.appendingPathComponent("claude-code-elements.json").path)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let box = try #require(json["input_box"] as? [String: Any])
        #expect(box["prompt_char"] as? String == "\u{276F}"); #expect(box["prompt_char_fallback_ascii"] as? String == ">")
        #expect(SceneRenderer.canRender("\u{276F}", in: renderer.font))
        #expect(renderer.elements.prompt == "\u{276F}")
        #expect(renderer.chipText(RenderFrame(scene: .listening)) == "\u{276F} ")
        // The lookup is not a rubber stamp: an unassigned code point only gets CoreText's LastResort placeholder, an empty string nothing.
        #expect(!SceneRenderer.canRender("\u{10FFFF}", in: renderer.font)); #expect(!SceneRenderer.canRender("\u{E000}", in: renderer.font))
        #expect(!SceneRenderer.canRender("", in: renderer.font)); #expect(SceneRenderer.canRender(">", in: renderer.font))
        #expect(SceneRenderer.resolvePrompt(preferred: "\u{10FFFF}", fallback: ">", font: renderer.font) == ">")
        #expect(SceneRenderer.resolvePrompt(preferred: "\u{276F}", fallback: ">", font: renderer.font) == "\u{276F}")
        // And the glyph really is drawn: the chip is not blank where the prompt goes.
        let chip = try Raster(renderer.render(GoldenEnvironment.frame(.listening), fixedCanvas: true))
        #expect(chip.count(inX: 60..<90, 42..<72, where: { $0.r > 100 && $0.g > 100 && $0.b > 100 && $0.a == 255 }) > 10)
    }
    @Test func Golden_theSpinnerFollowsClaudeCodesCosineSequenceOverTwoSeconds() throws {
        let renderer = try SceneRenderer(art: artDirectory)
        let ticks = (0..<20).map { renderer.elements.spinner(at: Double($0) * 0.1) }
        let expected = ["·", "·", "·", "✢", "✳", "✳", "✶", "✻", "✽", "✽", "✽", "✽", "✽", "✻", "✶", "✶", "✳", "✢", "·", "·"]
        #expect(ticks == expected)
    }
    @Test func Golden_optionalHelmetPosesExistAndAreOffByDefault() throws {
        let renderer = try SceneRenderer(art: artDirectory)
        #expect(renderer.pose(for: RenderFrame(scene: .idle)) == "idle")
        #expect(renderer.pose(for: RenderFrame(scene: .idle, helmet: true)) == "helmet-idle")
        #expect(renderer.pose(for: RenderFrame(scene: .listening, helmet: true)) == "helmet-listen")
        #expect(renderer.pose(for: RenderFrame(scene: .sleep, helmet: true)) == "sleep")   // no helmet variant: falls back
    }
    @Test func Golden_contactSheetOfAllScenesIsWrittenForReading() throws {
        let renderer = try SceneRenderer(art: artDirectory)
        let images = try Scene.allCases.map { try renderer.render(GoldenEnvironment.frame($0), fixedCanvas: true) }
        let cell = (w: images[0].width, h: images[0].height)
        let columns = 2, rows = (images.count + 1) / 2, pad = 8, scale = 2
        let width = (cell.w * scale + pad) * columns + pad, height = (cell.h * scale + pad) * rows + pad
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        for (i, image) in images.enumerated() {
            let x = pad + (i % columns) * (cell.w * scale + pad), y = height - (pad + (i / columns + 1) * (cell.h * scale + pad)) + pad
            context.draw(image, in: CGRect(x: x, y: y, width: cell.w * scale, height: cell.h * scale))
        }
        try evidenceStore().write(SceneRenderer.png(try #require(context.makeImage())), to: "contact-sheet.png")
    }
}
