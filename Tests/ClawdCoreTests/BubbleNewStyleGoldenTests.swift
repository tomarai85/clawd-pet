import Testing
import Foundation
import CoreGraphics
import CryptoKit
import ClawdCore
@testable import ClawdRendering

/// Golden PNGs of bubble styles 13, 14 and 15 (the board's mock B, C and D): every style x eight moments x the four placements of BubbleStyleGoldenTests x
/// pixel scale 1 and 2 (x Light and Dark for 14 and 15; 13 has one palette: its Dark render is asserted equal to its Light one, not stored), plus the larger
/// sizes. All through `StageRenderer.compose`, compared with a pixel diff of 0.
///
/// Style 13 is a pixel style and follows the pixel family's rule (Tests/Goldens/environment.json's contract fields and the decode pin). Styles 14 and 15 are
/// drawn by CoreGraphics and CoreText, so their goldens follow the smooth sidecar's rule (Tests/Goldens/bubble/smooth-environment.json: the OS build, the
/// colour space, the drawing flags, every font file with its hash, and a manifest of the PNGs): all of the sidecar matches this Mac, the stored PNG is
/// the image the sidecar was recorded with, and the pixels equal it.
///
/// To record 13: `CLAWD_RECORD_STAGE_GOLDENS=1 swift test --filter BubbleNewStyleGoldenTests`. To record 14 and 15 and their sidecar (one run does it all, and writes a report
/// under .evidence/v2/): `CLAWD_RECORD_SMOOTH_GOLDENS=1 swift test --filter BubbleNewStyleGoldenTests`.
@Suite("BubbleNewStyleGoldenTests", .serialized)
struct BubbleNewStyleGoldenTests {
    struct Moment { let name: String; let scene: Scene; let elapsed: Double; var reduce = false }
    static let moments: [Moment] = [
        Moment(name: "listening", scene: .listening, elapsed: 0.1), Moment(name: "thinking", scene: .thinking, elapsed: 0.7),
        Moment(name: "thinking-late", scene: .thinking, elapsed: 1.3), Moment(name: "thinking-reduced", scene: .thinking, elapsed: 0.5, reduce: true),
        Moment(name: "sent", scene: .sent, elapsed: 1.0), Moment(name: "sent-fading", scene: .sent, elapsed: 1.85),
        Moment(name: "interrupted", scene: .interrupted, elapsed: 0.2), Moment(name: "error", scene: .error, elapsed: 0.2),
    ]
    static let placements = BubbleStyleGoldenTests.placements
    static let pixelScales: [Double] = [1, 2]
    static let larger: [(name: String, scale: Double, backing: Double)] = [("size1.5", 1.5, 1), ("size2-retina", 2, 2), ("size4-retina", 4, 2)]

    static func appearances(_ style: Int) -> [BubbleAppearance?] { style == 13 ? [nil] : [.light, .dark] }
    static func suffix(_ appearance: BubbleAppearance?) -> String { appearance.map { $0 == .light ? "-light" : "-dark" } ?? "" }
    static func name(_ style: Int, _ m: Moment, _ p: BubbleStyleGoldenTests.Placement, _ px: Double, _ appearance: BubbleAppearance?) -> String {
        "bubble/style\(style)-\(m.name)-\(p.name)-px\(Int(px))\(suffix(appearance)).png"
    }
    static func largerName(_ style: Int, _ size: String, _ appearance: BubbleAppearance?) -> String { "bubble/style\(style)-thinking-\(size)\(suffix(appearance)).png" }

    static func request(_ m: Moment, style: Int, geometry: PetGeometry, pixelScale: Double, appearance: BubbleAppearance?, side: BubbleSide = .above) -> StageRequest {
        let pose = m.scene == .listening ? "listen" : m.scene == .thinking ? "think" : m.scene == .sent ? "hop" : "idle"
        let frame = pose == "idle" ? Frames.rest(bubble: BubbleState(style: style, scene: m.scene), scene: m.scene)
                                   : Frames.pose(pose, scene: m.scene, bubble: BubbleState(style: style, scene: m.scene))
        return StageRequest(frame: frame, now: pose == "hop" ? 0.34 : 0.1, geometry: geometry, pixelScale: pixelScale,
                            content: BubbleContent(scene: m.scene, elapsed: m.elapsed, duration: 5, verb: "Cogitating", pastVerb: "Cooked", reduceMotion: m.reduce,
                                                   appearance: appearance ?? .light), bubbleSide: side)
    }

    /// Every file of the matrix of a style, with how to draw it.
    static func matrix(_ style: Int) -> [(file: String, draw: () throws -> Raster)] {
        var files: [(String, () throws -> Raster)] = []
        for appearance in appearances(style) {
            for m in moments { for p in placements { for px in pixelScales {
                files.append((name(style, m, p, px, appearance), {
                    try #require(try stageRenderer.compose(request(m, style: style, geometry: p.geometry, pixelScale: px, appearance: appearance, side: BubbleStyleGoldenTests.side(p)))).pixels
                }))
            } } }
            for size in larger {
                files.append((largerName(style, size.name, appearance), {
                    try #require(try stageRenderer.compose(request(moments[1], style: style, geometry: Screens.geometry(scale: size.scale), pixelScale: size.backing, appearance: appearance))).pixels
                }))
            }
        }
        return files
    }

    private static var recordingSmooth: Bool { ProcessInfo.processInfo.environment["CLAWD_RECORD_SMOOTH_GOLDENS"] == "1" }

    /// The smooth sidecar's verdict for one image of 14 or 15 (D-13): the environment, then the manifest, then the pixels.
    enum SmoothVerdict: Equatable {
        case pass
        case envMismatch([String])
        case notTheRecordedImage(String)
        case missing(String)
        case sizeDiff(String)
        case pixelDiff(String, Int)
    }
    static func smoothCheck(_ raster: Raster, _ relative: String, goldens: URL = StageGoldens.directory, sidecar override: SmoothEnvironment? = nil,
                            current: SmoothEnvironment? = nil) throws -> SmoothVerdict {
        guard let data = try? ReadOnlyFile.data(goldens.appendingPathComponent(SmoothGoldenRecorder.sidecarPath).path),
              let recorded = try? JSONDecoder().decode(SmoothEnvironment.self, from: data) else {
            emit("MISSING-GOLDEN: \(SmoothGoldenRecorder.sidecarPath)"); return .missing(SmoothGoldenRecorder.sidecarPath)
        }
        let sidecar = override ?? recorded
        let now = try current ?? SmoothEnvironment.current()
        if case .mismatch(let differences) = now.compare(to: sidecar) { emit("ENV-MISMATCH: \(differences.joined(separator: ","))"); return .envMismatch(differences) }
        guard let png = try? ReadOnlyFile.data(goldens.appendingPathComponent(relative).path) else { emit("MISSING-GOLDEN: \(relative)"); return .missing(relative) }
        if let problem = sidecar.manifestProblem(for: relative, storedPNG: png) { return .notTheRecordedImage(problem) }
        let expected = try Raster.decode(png: png)
        guard expected.width == raster.width, expected.height == raster.height else { return .sizeDiff(relative) }
        var differing = 0
        for i in 0..<raster.data.count where raster.data[i] != expected.data[i] { differing += 1 }
        return differing == 0 ? .pass : .pixelDiff(relative, differing)
    }

    // MARK: style 13: the pixel family

    @Test("style 13 in every scene, placement and pixel scale matches its golden")
    func Golden_newStyleTimesScenesTimesPlacements13() throws {
        var failures: [String] = []
        for (file, draw) in Self.matrix(13) where !file.contains("thinking-size") && !file.contains("-size") {
            let verdict = try StageGoldens.check(try draw(), file)
            if verdict != .pass && verdict != .recorded { failures.append("\(file): \(verdict)") }
        }
        #expect(failures.isEmpty, "style 13: \(failures.prefix(5))")
        // its Dark render is its Light render: one palette, asserted equal and not stored
        for m in Self.moments {
            let light = try #require(try stageRenderer.compose(Self.request(m, style: 13, geometry: Screens.geometry(), pixelScale: 1, appearance: .light))).pixels
            let dark = try #require(try stageRenderer.compose(Self.request(m, style: 13, geometry: Screens.geometry(), pixelScale: 1, appearance: .dark))).pixels
            #expect(light == dark, "13 \(m.name)")
        }
    }

    @Test("style 13 at the larger sizes draws its roomy form and matches its golden")
    func Golden_newStyleAtTheLargerSizes13() throws {
        var failures: [String] = []
        for size in Self.larger {
            let stage = try #require(try stageRenderer.compose(Self.request(Self.moments[1], style: 13, geometry: Screens.geometry(scale: size.scale), pixelScale: size.backing, appearance: nil)))
            if stage.bubble?.plan.variant != .roomy { failures.append("\(size.name): the \(String(describing: stage.bubble?.plan.variant)) variant") }
            let verdict = try StageGoldens.check(stage.pixels, Self.largerName(13, size.name, nil))
            if verdict != .pass && verdict != .recorded { failures.append("\(size.name): \(verdict)") }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    // MARK: styles 14 and 15: the smooth sidecar

    @Test("a smooth style in every scene, placement, pixel scale and appearance matches its golden", arguments: [14, 15])
    func Golden_newStyleTimesScenesTimesPlacementsSmooth(style: Int) throws {
        guard BubbleDesign.allIds.contains(style), !Self.recordingSmooth, !StageGoldens.recording else { return }
        var failures: [String] = []
        for (file, draw) in Self.matrix(style) {
            let verdict = try Self.smoothCheck(try draw(), file)
            if verdict != .pass { failures.append("\(file): \(verdict)") }
        }
        #expect(failures.isEmpty, "style \(style): \(failures.prefix(5))")
    }

    @Test("the smooth styles at the larger sizes draw their roomy form", arguments: [14, 15])
    func Golden_newStyleAtTheLargerSizesSmooth(style: Int) throws {
        guard BubbleDesign.allIds.contains(style) else { return }
        for appearance in [BubbleAppearance.light, .dark] { for size in Self.larger {
            let stage = try #require(try stageRenderer.compose(Self.request(Self.moments[1], style: style, geometry: Screens.geometry(scale: size.scale), pixelScale: size.backing, appearance: appearance)))
            #expect(stage.bubble?.plan.variant == .roomy, "style \(style) \(size.name) \(appearance)")
        } }
    }

    /// The recording run of the smooth goldens: it renders the whole matrix, compares each image with its stored PNG, writes a report under .evidence/v2/,
    /// writes the PNGs and writes the sidecar last. Without `CLAWD_RECORD_SMOOTH_GOLDENS=1` it only checks that the sidecar is well formed.
    @Test func Golden_recordTheSmoothGoldens() throws {
        let styles = [14, 15].filter { BubbleDesign.allIds.contains($0) }
        let files = styles.flatMap { style in Self.matrix(style).map { (style, $0.file, $0.draw) } }
        if Self.recordingSmooth {
            var draws: [String: () throws -> Raster] = [:]
            for (_, file, draw) in files { draws[file] = draw }
            let report = try SmoothGoldenRecorder.record(matrix: files.map { $0.1 }, render: { try draws[$0]!() }, goldens: try OwnState(root: StageGoldens.directory),
                                                         evidence: try evidenceStore("v2"), environment: try SmoothEnvironment.current())
            emit("RECORDED: \(files.count) smooth goldens and \(SmoothGoldenRecorder.sidecarPath); report .evidence/v2/smooth-golden-report.tsv (\(report.count - 1) rows)")
            return
        }
        guard !styles.isEmpty, !StageGoldens.recording else { return }
        let sidecar = try JSONDecoder().decode(SmoothEnvironment.self, from: try ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent(SmoothGoldenRecorder.sidecarPath).path))
        #expect(Set(sidecar.manifest.keys) == Set(files.map { $0.1 }), "the sidecar vouches for exactly the images the tests read")
    }

    /// 64 + 128 + 128 + 3 + 6 + 6 = 335 files plus the smooth sidecar, and no other file under Tests/Goldens/bubble is named for 13, 14 or 15.
    @Test func Golden_newStyleGoldenFilesAreExactlyTheOnesTheTestsRead() throws {
        guard !StageGoldens.recording, !Self.recordingSmooth else { return }
        let styles = BubbleDesign.allIds.filter { $0 >= 13 }
        let wanted = Set(styles.flatMap { style in Self.matrix(style).map { "bubble/" + $0.file.dropFirst("bubble/".count) } })
        let directory = StageGoldens.directory.appendingPathComponent("bubble")
        let found = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { file in [13, 14, 15].contains { file.hasPrefix("style\($0)-") } && !file.contains("-below-px") }.map { "bubble/" + $0 })
        #expect(found.subtracting(wanted).isEmpty, "orphan goldens: \(found.subtracting(wanted).sorted().prefix(5))")
        #expect(wanted.subtracting(found).isEmpty, "missing goldens: \(wanted.subtracting(found).sorted().prefix(5))")
        if styles.count == 3 { #expect(wanted.count == 335, "\(wanted.count) files") }
    }

    // MARK: the smooth sidecar's rules (D-13), on synthetic goldens

    @Test func Golden_theSmoothReportCountsPixelsRatherThanChannels() throws {
        let goldens = try artifactStore(), evidence = try artifactStore()
        let environment = SmoothEnvironment(swVers: "synthetic", colorSpace: "sRGB", drawingFlagsVersion: 1, fonts: [], manifest: [:])
        let file = "bubble/style14-synthetic.png"
        var original = Raster(width: 3, height: 2); original[1, 1] = Pixel(10, 20, 30)
        try SmoothGoldenRecorder.record(matrix: [file], render: { _ in original }, goldens: goldens, evidence: evidence, environment: environment)
        let same = try SmoothGoldenRecorder.record(matrix: [file], render: { _ in original }, goldens: goldens, evidence: evidence, environment: environment)
        #expect(same.last == "\(file)\t0\t0")
        var changed = original; changed[1, 1] = Pixel(0, 0, 0, 0)
        let report = try SmoothGoldenRecorder.record(matrix: [file], render: { _ in changed }, goldens: goldens, evidence: evidence, environment: environment)
        #expect(report.last == "\(file)\t1\t255", "four changed channels belong to one pixel")
        #expect(try String(contentsOf: evidence.root.appendingPathComponent("smooth-golden-report.tsv"), encoding: .utf8) == report.joined(separator: "\n"))
    }

    /// A temporary goldens directory with one smooth golden and its sidecar, recorded by the recorder itself.
    private func recordedDirectory(raster: Raster = Raster(width: 6, height: 6)) throws -> (state: OwnState, root: URL, environment: SmoothEnvironment) {
        let goldens = try artifactStore(), evidence = try artifactStore()
        let environment = try SmoothEnvironment.current()
        var image = raster; image[1, 1] = Pixel(9, 8, 7)
        try SmoothGoldenRecorder.record(matrix: ["bubble/style14-synthetic.png"], render: { _ in image }, goldens: goldens, evidence: evidence, environment: environment)
        return (goldens, goldens.root, environment)
    }

    /// An OS or font update between recording and checking: a doctored font hash never passes a smooth golden.
    @Test func Golden_aChangedSystemFontNeverPassesASmoothGolden() throws {
        let (_, root, environment) = try recordedDirectory()
        var image = Raster(width: 6, height: 6); image[1, 1] = Pixel(9, 8, 7)
        #expect(try Self.smoothCheck(image, "bubble/style14-synthetic.png", goldens: root) == .pass, "the recorded Mac passes its own golden")
        let font = try #require(environment.fonts.first)
        let doctored = SmoothEnvironment(swVers: environment.swVers, colorSpace: environment.colorSpace, drawingFlagsVersion: environment.drawingFlagsVersion,
                                         fonts: [SmoothEnvironment.FontFile(role: font.role, path: font.path, sha256: "0")] + environment.fonts.dropFirst(),
                                         manifest: environment.manifest)
        let verdict = try Self.smoothCheck(image, "bubble/style14-synthetic.png", goldens: root, current: doctored)
        #expect(verdict == .envMismatch(["font_sha256:" + font.role]), "\(verdict)")
        #expect(verdict != .pass)
        let otherOS = SmoothEnvironment(swVers: environment.swVers + "BuildVersion: other\n", colorSpace: environment.colorSpace, drawingFlagsVersion: environment.drawingFlagsVersion,
                                        fonts: environment.fonts, manifest: environment.manifest)
        #expect(try Self.smoothCheck(image, "bubble/style14-synthetic.png", goldens: root, current: otherOS) == .envMismatch(["sw_vers"]))
    }

    /// The sidecar vouches for exactly the images its run wrote: a stored PNG replaced by any other PNG fails by its hash, with the environment matching,
    /// and a run that did not render every image of its matrix writes no sidecar.
    @Test func Golden_theSmoothSidecarCoversExactlyTheImagesItsRunRendered() throws {
        let (state, root, _) = try recordedDirectory()
        var image = Raster(width: 6, height: 6); image[1, 1] = Pixel(9, 8, 7)
        // the stored PNG replaced by another, which is also what the renderer draws today: the pixels agree and the hash does not
        var other = image; other[2, 2] = Pixel(1, 1, 1)
        try state.write(SceneRenderer.png(try other.cgImage()), to: "bubble/style14-synthetic.png")
        let verdict = try Self.smoothCheck(other, "bubble/style14-synthetic.png", goldens: root)
        guard case .notTheRecordedImage = verdict else { Issue.record("a replaced stored PNG gave \(verdict)"); return }
        // a file the sidecar never vouched for
        try state.write(SceneRenderer.png(try image.cgImage()), to: "bubble/style14-unlisted.png")
        guard case .notTheRecordedImage = try Self.smoothCheck(image, "bubble/style14-unlisted.png", goldens: root) else { Issue.record("an unlisted file passed"); return }
        // an incomplete run: one image of the matrix cannot be rendered, so no sidecar is written and the old one is untouched
        let before = try ReadOnlyFile.data(root.appendingPathComponent(SmoothGoldenRecorder.sidecarPath).path)
        struct Failed: Error {}
        do {
            try SmoothGoldenRecorder.record(matrix: ["bubble/style14-a.png", "bubble/style14-b.png"], render: { name in if name.hasSuffix("b.png") { throw Failed() }; return image },
                                            goldens: state, evidence: try artifactStore(), environment: try SmoothEnvironment.current())
            Issue.record("the recorder wrote a sidecar for an incomplete matrix")
        } catch let failure as SmoothGoldenRecorder.Failure { #expect(failure == .notRendered(["bubble/style14-b.png"])) }
        #expect(try ReadOnlyFile.data(root.appendingPathComponent(SmoothGoldenRecorder.sidecarPath).path) == before, "the sidecar of the last complete run stands")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bubble/style14-a.png").path), "nothing of an incomplete run is written")
    }

    /// The pixel goldens never read the smooth sidecar: a doctored smooth sidecar leaves the verdict of a pixel golden unchanged.
    @Test func Golden_thePixelGoldensIgnoreTheSmoothSidecar() throws {
        guard !StageGoldens.recording else { return }
        let goldens = try artifactStore()
        for file in ["environment.json", "pixel-decode.json"] { try goldens.write(try ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent(file).path), to: file) }
        let stage = try #require(try stageRenderer.compose(StageRequest(frame: Frames.rest(look: "helmet"), now: 0, geometry: Screens.geometry())))
        try goldens.write(try ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent("looks/helmet/idle_0.png").path), to: "looks/helmet/idle_0.png")
        let without = try StageGoldens.check(stage.pixels, "looks/helmet/idle_0.png", goldens: goldens.root)
        try goldens.write(Data(#"{"sw_vers":"nonsense","color_space":"x","drawing_flags_version":99,"fonts":[],"manifest":{}}"#.utf8), to: SmoothGoldenRecorder.sidecarPath)
        let with = try StageGoldens.check(stage.pixels, "looks/helmet/idle_0.png", goldens: goldens.root)
        #expect(without == .pass && with == without, "\(without) then \(with)")
    }
}
