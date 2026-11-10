import Testing
import Foundation
import CoreGraphics
import ClawdCore
@testable import ClawdRendering

/// Golden PNGs of the bubble under Clawd's feet (amendment D-3): every style x {listening, thinking} x pixel scale 1 and 2, Clawd at rest with room
/// all round, the default side. They are new files; the existing above and beside goldens stay as they are (`git diff --name-only --diff-filter=MD
/// <base> -- Tests/Goldens` prints nothing).
///
/// Styles 1-13 follow the pixel family's rule (Tests/Goldens/environment.json and the decode pin). Styles 14 and 15 are drawn by CoreGraphics and
/// CoreText and follow a smooth sidecar of their own, `Tests/Goldens/bubble/smooth-environment-below.json` (the existing smooth sidecar vouches for the
/// existing images and is not touched), in Light and Dark.
///
/// To record: `CLAWD_RECORD_STAGE_GOLDENS=1 swift test --filter BubbleStyleGolden_below` (styles 1-13), `CLAWD_RECORD_SMOOTH_GOLDENS=1 swift test --filter
/// BubbleStyleGolden_below` (styles 14 and 15 and their sidecar, with a report under .evidence/v2/).
@Suite("BubbleStyleGolden_below", .serialized)
struct BubbleSideGoldenTests {
    struct Moment { let name: String; let scene: Scene; let elapsed: Double }
    static let moments = [Moment(name: "listening", scene: .listening, elapsed: 0.1), Moment(name: "thinking", scene: .thinking, elapsed: 0.7)]
    static let pixelScales: [Double] = [1, 2]
    static let sidecar = "bubble/smooth-environment-below.json"
    static var recordingSmooth: Bool { ProcessInfo.processInfo.environment["CLAWD_RECORD_SMOOTH_GOLDENS"] == "1" }

    static func appearances(_ style: Int) -> [BubbleAppearance?] { style >= 14 ? [.light, .dark] : [nil] }
    static func name(_ style: Int, _ m: Moment, _ px: Double, _ appearance: BubbleAppearance?) -> String {
        "bubble/style\(style)-\(m.name)-below-px\(Int(px))\(appearance.map { $0 == .light ? "-light" : "-dark" } ?? "").png"
    }
    static func request(_ m: Moment, style: Int, pixelScale: Double, appearance: BubbleAppearance?) -> StageRequest {
        let pose = m.scene == .listening ? "listen" : "think"
        let frame = Frames.pose(pose, scene: m.scene, bubble: BubbleState(style: style, scene: m.scene))
        return StageRequest(frame: frame, now: 0.1, geometry: Screens.geometry(homeX: 576, homeY: 300), pixelScale: pixelScale,
                            content: BubbleContent(scene: m.scene, elapsed: m.elapsed, duration: 5, verb: "Cogitating", pastVerb: "Cooked", appearance: appearance ?? .light))
    }
    static func matrix(_ style: Int) -> [(file: String, draw: () throws -> Raster)] {
        var files: [(String, () throws -> Raster)] = []
        for appearance in appearances(style) { for m in moments { for px in pixelScales {
            files.append((name(style, m, px, appearance), {
                let stage = try #require(try stageRenderer.compose(request(m, style: style, pixelScale: px, appearance: appearance)))
                #expect(stage.bubble?.plan.side == .below && stage.bubble?.plan.connection == .below, "style \(style) \(m.name): not below")
                return stage.pixels
            }))
        } } }
        return files
    }

    private func smoothCheck(_ raster: Raster, _ relative: String) throws -> BubbleNewStyleGoldenTests.SmoothVerdict {
        guard let data = try? ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent(Self.sidecar).path),
              let recorded = try? JSONDecoder().decode(SmoothEnvironment.self, from: data) else { emit("MISSING-GOLDEN: \(Self.sidecar)"); return .missing(Self.sidecar) }
        if case .mismatch(let differences) = try SmoothEnvironment.current().compare(to: recorded) { emit("ENV-MISMATCH: \(differences.joined(separator: ","))"); return .envMismatch(differences) }
        guard let png = try? ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent(relative).path) else { emit("MISSING-GOLDEN: \(relative)"); return .missing(relative) }
        if let problem = recorded.manifestProblem(for: relative, storedPNG: png) { return .notTheRecordedImage(problem) }
        let expected = try Raster.decode(png: png)
        guard expected.width == raster.width, expected.height == raster.height else { return .sizeDiff(relative) }
        var differing = 0
        for i in 0..<raster.data.count where raster.data[i] != expected.data[i] { differing += 1 }
        return differing == 0 ? .pass : .pixelDiff(relative, differing)
    }

    @Test("a pixel style under Clawd's feet matches its golden", arguments: Array(1...13))
    func BubbleStyleGolden_below_pixelStyles(style: Int) throws {
        var failures: [String] = []
        for (file, draw) in Self.matrix(style) {
            let verdict = try StageGoldens.check(try draw(), file)
            if verdict != .pass && verdict != .recorded { failures.append("\(file): \(verdict)") }
        }
        #expect(failures.isEmpty, "style \(style): \(failures.prefix(5))")
    }

    @Test("a smooth style under Clawd's feet matches its golden", arguments: [14, 15])
    func BubbleStyleGolden_below_smoothStyles(style: Int) throws {
        guard !Self.recordingSmooth, !StageGoldens.recording else { return }
        var failures: [String] = []
        for (file, draw) in Self.matrix(style) {
            let verdict = try smoothCheck(try draw(), file)
            if verdict != .pass { failures.append("\(file): \(verdict)") }
        }
        #expect(failures.isEmpty, "style \(style): \(failures.prefix(5))")
    }

    /// The recording run of the below goldens of 14 and 15 (their own sidecar). Without `CLAWD_RECORD_SMOOTH_GOLDENS=1` it checks the sidecar vouches for
    /// exactly the images the tests read.
    @Test func BubbleStyleGolden_below_recordTheSmoothGoldens() throws {
        let files = [14, 15].flatMap { style in Self.matrix(style).map { (style, $0.file, $0.draw) } }
        if Self.recordingSmooth {
            var draws: [String: () throws -> Raster] = [:]
            for (_, file, draw) in files { draws[file] = draw }
            let report = try SmoothGoldenRecorder.record(matrix: files.map { $0.1 }, render: { try draws[$0]!() }, goldens: try OwnState(root: StageGoldens.directory),
                                                         evidence: try evidenceStore("v2"), environment: try SmoothEnvironment.current(),
                                                         sidecar: Self.sidecar, report: "smooth-golden-report-below.tsv")
            emit("RECORDED: \(files.count) smooth below goldens and \(Self.sidecar); report .evidence/v2/smooth-golden-report-below.tsv (\(report.count - 1) rows)")
            return
        }
        guard !StageGoldens.recording else { return }
        let sidecar = try JSONDecoder().decode(SmoothEnvironment.self, from: try ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent(Self.sidecar).path))
        #expect(Set(sidecar.manifest.keys) == Set(files.map { $0.1 }), "the sidecar vouches for exactly the images the tests read")
    }

    /// 13 pixel styles x 2 moments x 2 scales, 2 smooth styles x 2 appearances x 2 moments x 2 scales: 52 + 16 = 68 files, and no other file of the below
    /// family under Tests/Goldens/bubble.
    @Test func BubbleStyleGolden_below_theFilesAreExactlyTheOnesTheTestsRead() throws {
        guard !StageGoldens.recording, !Self.recordingSmooth else { return }
        let wanted = Set(BubbleDesign.allIds.flatMap { style in Self.matrix(style).map { $0.file } })
        let directory = StageGoldens.directory.appendingPathComponent("bubble")
        let found = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("-below-px") }.map { "bubble/" + $0 })
        #expect(found == wanted, "orphan: \(found.subtracting(wanted).sorted().prefix(3)), missing: \(wanted.subtracting(found).sorted().prefix(3))")
        #expect(wanted.count == 68, "\(wanted.count) files")
    }

    /// The existing above and beside goldens are untouched by this change: a style that was drawn above Clawd is drawn the same pixel for pixel when
    /// the chosen side is above (the existing golden tests assert it file by file; this is the quick check on one picture of each kind).
    @Test func BubbleStyleGolden_below_theAboveAndBesideGoldensAreStillTheirOwnPictures() throws {
        guard !StageGoldens.recording else { return }
        var request = BubbleStyleGoldenTests.request(BubbleStyleGoldenTests.moments[1], style: 7, placement: BubbleStyleGoldenTests.placements[0], pixelScale: 1)
        let above = try #require(try stageRenderer.compose(request))
        #expect(above.bubble?.plan.connection == .above)
        #expect(try StageGoldens.check(above.pixels, "bubble/style7-thinking-above-px1.png") == .pass)
        // a beside picture: Clawd flush against the top, the chosen side right (Clippy's side connector is not symmetric, so a turned one would show)
        let beside = try #require(try stageRenderer.compose(BubbleStyleGoldenTests.request(BubbleStyleGoldenTests.moments[1], style: 7, placement: BubbleStyleGoldenTests.placements[2], pixelScale: 1)))
        #expect(beside.bubble?.plan.connection == .side)
        #expect(try StageGoldens.check(beside.pixels, "bubble/style7-thinking-side-right-px1.png") == .pass)
        request.bubbleSide = .below
        request.geometry = Screens.geometry(homeY: 300)            // room under his feet (at home he is too near the bottom band)
        let below = try #require(try stageRenderer.compose(request))
        #expect(below.bubble?.plan.connection == .below && below.pixels != above.pixels)
    }
}
