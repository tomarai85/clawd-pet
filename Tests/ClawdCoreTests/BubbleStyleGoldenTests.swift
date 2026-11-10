import Testing
import Foundation
import CoreGraphics
import ClawdCore
@testable import ClawdRendering

/// Golden PNGs of the nine phase-2 bubble styles (2, 3, 4, 5, 7, 8, 9, 11, 12; styles 1, 6 and 10 keep StageGoldenTests' files): every
/// style x six moments (cursor, spinner, Reduce Motion's still dot, SENT, interrupted, error) x four placements (above the head opening
/// right, above opening left, beside the head with the bubble to the right and to the left) x pixel scale 1 and 2, at size 1, plus the roomy
/// variant at size 1.5 and size 2 (Retina), through
/// `StageRenderer.compose`, compared with a pixel diff of 0. They follow the same environment sidecar rule as every golden
/// (Tests/Goldens/environment.json must match this Mac, else ENV-MISMATCH and no pass).
///
/// To record: `CLAWD_RECORD_STAGE_GOLDENS=1 swift test --filter BubbleStyleGoldenTests` (writes Tests/Goldens/bubble/style<N>-<moment>-<placement>-px<1|2>.png).
@Suite("BubbleStyleGoldenTests", .serialized)
struct BubbleStyleGoldenTests {
    struct Moment { let name: String; let scene: Scene; let elapsed: Double; var reduce = false }
    struct Placement { let name: String; let geometry: PetGeometry; let connection: BubbleConnection; let opening: BubbleOpening }

    static let moments: [Moment] = [
        Moment(name: "listening", scene: .listening, elapsed: 0.1), Moment(name: "thinking", scene: .thinking, elapsed: 0.7),
        Moment(name: "thinking-reduced", scene: .thinking, elapsed: 0.5, reduce: true), Moment(name: "sent", scene: .sent, elapsed: 1.0),
        Moment(name: "interrupted", scene: .interrupted, elapsed: 0.2), Moment(name: "error", scene: .error, elapsed: 0.2),
    ]
    static let top = Screens.visible.maxY - 48
    static let placements: [Placement] = [
        Placement(name: "above", geometry: Screens.geometry(), connection: .above, opening: .right),
        Placement(name: "above-opens-left", geometry: Screens.geometry(homeX: 1000), connection: .above, opening: .left),
        // Clawd flush against the top edge: no room above his head, so the bubble goes beside it, centred on his body
        Placement(name: "side-right", geometry: PetGeometry(scale: 1, homeOrigin: CGPoint(x: 300, y: top), displayFrame: Screens.display, visibleFrame: Screens.visible), connection: .side, opening: .right),
        Placement(name: "side-left", geometry: PetGeometry(scale: 1, homeOrigin: CGPoint(x: 1000, y: top), displayFrame: Screens.display, visibleFrame: Screens.visible), connection: .side, opening: .left),
    ]
    static let pixelScales: [Double] = [1, 2]

    /// The side the placement stands for: above is chosen for the two above pictures, and left and right for the two beside ones (absolute directions).
    static func side(_ p: Placement) -> BubbleSide { p.connection == .side ? (p.opening == .right ? .right : .left) : .above }

    static func name(_ style: Int, _ m: Moment, _ p: Placement, _ px: Double) -> String { "bubble/style\(style)-\(m.name)-\(p.name)-px\(Int(px)).png" }

    static func request(_ m: Moment, style: Int, placement p: Placement, pixelScale: Double) -> StageRequest {
        let pose = m.scene == .listening ? "listen" : m.scene == .thinking ? "think" : m.scene == .sent ? "hop" : "idle"
        let frame = pose == "idle" ? Frames.rest(bubble: BubbleState(style: style, scene: m.scene), scene: m.scene)
                                   : Frames.pose(pose, scene: m.scene, bubble: BubbleState(style: style, scene: m.scene))
        return StageRequest(frame: frame, now: pose == "hop" ? 0.34 : 0.1, geometry: p.geometry, pixelScale: pixelScale,
                            content: BubbleContent(scene: m.scene, elapsed: m.elapsed, duration: 5, verb: "Cogitating", pastVerb: "Cooked", reduceMotion: m.reduce),
                            bubbleSide: side(p))
    }

    private func pass(_ verdict: StageGoldens.Verdict) -> Bool { verdict == .pass || verdict == .recorded }

    @Test("a phase-2 style in every scene, placement and pixel scale matches its golden", arguments: BubbleDesign.phase2Ids)
    func Golden_phase2StyleTimesScenesTimesPlacements(style: Int) throws {
        var failures: [String] = []
        for m in Self.moments { for p in Self.placements { for px in Self.pixelScales {
            let stage = try #require(try stageRenderer.compose(Self.request(m, style: style, placement: p, pixelScale: px)))
            let label = "\(m.name) \(p.name) px\(Int(px))"
            guard let placed = stage.bubble else { failures.append("\(label): no bubble"); continue }
            if placed.plan.connection != p.connection || placed.plan.opening != p.opening {
                failures.append("\(label): placed \(placed.plan.connection) \(placed.plan.opening), expected \(p.connection) \(p.opening)")
            }
            let verdict = try StageGoldens.check(stage.pixels, Self.name(style, m, p, px))
            if !pass(verdict) { failures.append("\(label): \(verdict)") }
        } } }
        #expect(failures.isEmpty, "style \(style): \(failures.prefix(5))")
    }

    /// The roomy variant (one more row of air above and below the text) once the body is tall enough: size 1.5 on the ultrawide and size 2 on a
    /// Retina display, as phase 1's `size1.5` and `size2-retina` goldens.
    static let larger: [(name: String, scale: Double, backing: Double)] = [("size1.5", 1.5, 1), ("size2-retina", 2, 2)]
    @Test("every phase-2 style at the larger sizes draws its roomy variant and matches its golden", arguments: BubbleDesign.phase2Ids)
    func Golden_phase2StyleAtTheLargerSizes(style: Int) throws {
        var failures: [String] = []
        let m = Self.moments[1]
        for (name, scale, backing) in Self.larger {
            let placement = Placement(name: name, geometry: Screens.geometry(scale: scale), connection: .above, opening: .right)
            let stage = try #require(try stageRenderer.compose(Self.request(m, style: style, placement: placement, pixelScale: backing)))
            guard let placed = stage.bubble else { failures.append("\(name): no bubble"); continue }
            if placed.plan.variant != .roomy { failures.append("\(name): the \(placed.plan.variant) variant") }
            let verdict = try StageGoldens.check(stage.pixels, "bubble/style\(style)-thinking-\(name).png")
            if !pass(verdict) { failures.append("\(name): \(verdict)") }
        }
        #expect(failures.isEmpty, "style \(style): \(failures.prefix(5))")
    }

    /// 9b item 1: beside the head the bubble is at most the body's 6 units tall and its centre is the centre of the body's 6 rows.
    @Test("every phase-2 style beside the head is at most 6 units tall and centred on the body", arguments: BubbleDesign.phase2Ids)
    func Golden_phase2SideRatioAndCentre(style: Int) throws {
        for m in Self.moments { for p in Self.placements where p.connection == .side { for px in Self.pixelScales {
            let layout = try #require(try stageRenderer.layout(Self.request(m, style: style, placement: p, pixelScale: px)))
            let plan = try #require(layout.bubble).plan, unit = p.geometry.unit
            #expect(plan.rect.height <= 6 * unit + 0.01 && plan.boxRect.height <= 6 * unit + 0.01, "style \(style) \(m.name) \(p.name): \(plan.rect.height) pt against \(6 * unit)")
            let centre = layout.canvas.maxY - Double(layout.composed.bodyCentreRow ?? 0) * layout.cellPt
            #expect(abs(plan.boxRect.midY - centre) <= 0.51, "style \(style) \(m.name) \(p.name): box centre \(plan.boxRect.midY), body centre \(centre)")
        } } }
    }

    /// Every file under Tests/Goldens/bubble named for a phase-2 style is one of these tests' pictures, and each of their pictures exists.
    @Test func Golden_phase2GoldenFilesAreExactlyTheOnesTheTestsRead() throws {
        guard !StageGoldens.recording else { return }
        let matrix = Set(BubbleDesign.phase2Ids.flatMap { style in Self.moments.flatMap { m in Self.placements.flatMap { p in Self.pixelScales.map { Self.name(style, m, p, $0) } } } })
        let wanted = matrix.union(BubbleDesign.phase2Ids.flatMap { style in Self.larger.map { "bubble/style\(style)-thinking-\($0.name).png" } })
        let directory = StageGoldens.directory.appendingPathComponent("bubble")
        let phase2 = Set(BubbleDesign.phase2Ids.map { "style\($0)-" })
        let found = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { file in (file.hasSuffix("-px1.png") || file.hasSuffix("-px2.png") || file.contains("-thinking-size")) ? phase2.contains { file.hasPrefix($0) } && !file.contains("-below-px") : false }
            .map { "bubble/" + $0 })
        #expect(matrix.count == BubbleDesign.phase2Ids.count * Self.moments.count * Self.placements.count * Self.pixelScales.count)
        #expect(wanted.count == matrix.count + BubbleDesign.phase2Ids.count * Self.larger.count)
        #expect(found.subtracting(wanted).isEmpty, "orphan goldens: \(found.subtracting(wanted).sorted().prefix(5))")
        #expect(wanted.subtracting(found).isEmpty, "missing goldens: \(wanted.subtracting(found).sorted().prefix(5))")
    }

    /// D-13, deliberately rewritten: a pixel golden no longer depends on the OS build or the Menlo file. The same doctored environment (another sw_vers,
    /// another font hash) now passes a style 7 golden; a doctored canary decode is ENV-MISMATCH `decode`; and a v1 scene golden, which does draw CoreText text
    /// in Menlo, is still ENV-MISMATCH under the doctored sw_vers.
    @Test func Golden_aMismatchedEnvironmentNeverPassesAPhase2Golden() throws {
        guard !StageGoldens.recording else { return }
        let real = try GoldenEnvironment.current(art: artDirectory)
        let doctored = GoldenEnvironment(swVers: real.swVers + "BuildVersion: other\n", fontPath: real.fontPath, fontSHA256: "0", colorSpace: real.colorSpace,
                                         scale: real.scale, virtualTime: real.virtualTime, artSHA256: real.artSHA256)
        let m = Self.moments[1], p = Self.placements[0]
        let stage = try #require(try stageRenderer.compose(Self.request(m, style: 7, placement: p, pixelScale: 1)))
        #expect(try StageGoldens.check(stage.pixels, Self.name(7, m, p, 1), environment: doctored) == .pass, "another OS build and Menlo file do not matter to a pixel golden")
        let pin = try JSONDecoder().decode(DecodePin.self, from: try ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent("pixel-decode.json").path))
        var wrong = try DecodePin.hashes(canaries: StageGoldens.canaryDirectory, files: pin.canaries.map(\.file))
        wrong[pin.canaries[1].file] = "0000"
        let verdict = try StageGoldens.check(stage.pixels, Self.name(7, m, p, 1), environment: doctored, decode: wrong)
        #expect(verdict == .envMismatch(["decode"]), "\(verdict)")
        #expect(verdict != .pass)
        // the v1 scene golden is checked against the whole sidecar
        #expect(try goldenVerdict(.idle, currentEnvironment: doctored) == .envMismatch(["sw_vers", "font_sha256"]))
    }

    @Test func Golden_aChangedColourOfAPhase2StyleFailsItsGolden() throws {
        guard !StageGoldens.recording else { return }
        let m = Self.moments[3], p = Self.placements[0]
        var stage = try #require(try stageRenderer.compose(Self.request(m, style: 9, placement: p, pixelScale: 1))).pixels
        #expect(pass(try StageGoldens.check(stage, Self.name(9, m, p, 1))))
        // the bubble's own pixels: flip the first opaque pixel that is not Clawd's colour
        var flipped = false
        outer: for y in 0..<stage.height { for x in 0..<stage.width where stage[x, y] == BubbleDesign.white { stage[x, y] = Pixel(rgb: 0xFEFEFE); flipped = true; break outer } }
        #expect(flipped)
        let verdict = try StageGoldens.check(stage, Self.name(9, m, p, 1))
        if case .pixelDiff(_, let count) = verdict { #expect(count > 0) } else { Issue.record("expected a pixel diff, got \(verdict)") }
    }
}
