import Testing
import Foundation
import CoreGraphics
import ClawdCore
import ClawdRendering

/// Golden PNGs of the stage: every ported motion frame in the plain look, each look's rest poses, every look-change frame, and the
/// bubble styles in every scene. All of them go through `StageRenderer.compose` (size 1, pixel scale 1 unless the name says otherwise)
/// and are compared with a pixel diff of 0. They follow the pixel family's rule (amendment D-13): what they depend on is the rendering contract
/// (colour space, scale and virtual time, from Tests/Goldens/environment.json) and the PNG decode, which Tests/Goldens/pixel-decode.json pins with a
/// few fixed canary PNGs. Not the OS build and not the Menlo file: integer arithmetic over decoded art draws no text through the OS. Any other
/// outcome is ENV-MISMATCH, never a pass.
///
/// To record: `CLAWD_RECORD_STAGE_GOLDENS=1 swift test --filter StageGoldens` (writes the files, never passes silently: it says RECORDED).
enum StageGoldens {
    static let directory = repository.appendingPathComponent("Tests/Goldens")
    static let canaryDirectory = repository.appendingPathComponent("Tests/Fixtures/decode-canary")
    static var recording: Bool { ProcessInfo.processInfo.environment["CLAWD_RECORD_STAGE_GOLDENS"] == "1" }
    static var recordingDecodePin: Bool { ProcessInfo.processInfo.environment["CLAWD_RECORD_DECODE_PIN"] == "1" }
    /// The six canaries, one per decode class (D-13): untagged opaque art, untagged art with partial alpha, the sRGB-tagged art file, an art file with
    /// eXIf, pHYs and zTXt chunks, a stored golden with sRGB, eXIf and partial alpha and one with sRGB and eXIf, opaque.
    static let canaries = ["art-untagged-opaque.png", "art-untagged-partial-alpha.png", "art-srgb-tagged.png", "art-exif-phys-ztxt.png",
                           "golden-srgb-exif-partial-alpha.png", "golden-srgb-exif-opaque.png"]

    enum Verdict: Equatable {
        case pass, recorded
        case envMismatch([String])
        case missing(String)
        case sizeDiff(String)
        case pixelDiff(String, Int)
    }

    /// nil when this Mac is the one the pixel goldens were recorded on as far as they depend on it: the contract fields match and every canary
    /// decodes to its pinned bytes. `decode` replaces what the canaries decode to now (a test doctors it).
    static func environment(_ current: GoldenEnvironment? = nil, decode: [String: String]? = nil, goldens: URL = directory) throws -> Verdict? {
        guard let sidecar = try? ReadOnlyFile.data(goldens.appendingPathComponent("environment.json").path),
              let recorded = try? JSONDecoder().decode(GoldenEnvironment.self, from: sidecar) else {
            emit("MISSING-GOLDEN: environment.json"); return .missing("environment.json")
        }
        let now = try current ?? GoldenEnvironment.current(art: artDirectory)
        if case .mismatch(let differences) = now.compare(to: recorded, family: .pixelStage) {
            emit("ENV-MISMATCH: \(differences.joined(separator: ","))"); return .envMismatch(differences)
        }
        guard let pinData = try? ReadOnlyFile.data(goldens.appendingPathComponent("pixel-decode.json").path),
              let pin = try? JSONDecoder().decode(DecodePin.self, from: pinData) else {
            emit("MISSING-GOLDEN: pixel-decode.json"); return .missing("pixel-decode.json")
        }
        let decoded = try decode ?? DecodePin.hashes(canaries: canaryDirectory, files: pin.canaries.map(\.file))
        if !pin.differences(from: decoded).isEmpty {
            emit("ENV-MISMATCH: decode"); return .envMismatch(["decode"])
        }
        return nil
    }

    /// The sidecar is read once per run: nil when it matches this Mac, else the verdict every comparison then returns.
    private static let checkedEnvironment: Verdict? = {
        do { return try environment() } catch { return .missing("environment") }
    }()

    /// Compares one rendered picture with its golden, or records it.
    static func check(_ raster: Raster, _ relative: String, goldens: URL = directory, environment override: GoldenEnvironment? = nil,
                      decode: [String: String]? = nil) throws -> Verdict {
        if recording {
            try OwnState(root: goldens).write(SceneRenderer.png(try raster.cgImage()), to: relative)
            return .recorded
        }
        if override != nil || decode != nil { if let verdict = try environment(override, decode: decode, goldens: goldens) { return verdict } }
        else if let verdict = goldens == directory ? checkedEnvironment : try environment(goldens: goldens) { return verdict }
        guard let data = try? ReadOnlyFile.data(goldens.appendingPathComponent(relative).path) else {
            emit("MISSING-GOLDEN: \(relative)"); return .missing(relative)
        }
        let expected = try Raster.decode(png: data)
        guard expected.width == raster.width, expected.height == raster.height else { return .sizeDiff(relative) }
        var differing = 0
        for i in 0..<raster.data.count where raster.data[i] != expected.data[i] { differing += 1 }
        return differing == 0 ? .pass : .pixelDiff(relative, differing)
    }
}

/// The time at which frame `k` of a clip is on screen (the middle of its slot).
func middleOf(frame k: Int, in clip: Clip) -> Double {
    Double(clip.ms[0..<k].reduce(0, +)) / 1000 + Double(clip.ms[k]) / 2000
}

func numbered(_ k: Int) -> String { String(format: "%03d", k) }

private let motionIDs: [String] = stageRenderer.art.motionIDs
/// Every look of the catalog but the plain one: phase 1 shipped three, each later phase adds its looks to the atlas and so to these goldens.
private let costumeLooks: [String] = stageRenderer.art.lookIDs.filter { $0 != "plain" }
private let restPoseNames = ["idle", "blink", "listen", "think", "hop", "sleep", "dangle"]

@Suite("Golden stage frames", .serialized)
struct GoldenStageSuite {
    private func pass(_ verdict: StageGoldens.Verdict, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(verdict == .pass || verdict == .recorded, "\(verdict)", sourceLocation: sourceLocation)
    }

    @Test("every frame of a ported motion matches its golden in the plain look", arguments: motionIDs)
    func Golden_motionFramesInThePlainLook(id: String) throws {
        let clip = try stageRenderer.art.motion(id)
        var failures: [String] = []
        for k in clip.frames.indices {
            let stage = try #require(try stageRenderer.compose(StageRequest(frame: Frames.motion(id), now: middleOf(frame: k, in: clip), geometry: Screens.geometry())))
            let verdict = try StageGoldens.check(stage.pixels, "motions/\(id)/\(numbered(k)).png")
            if verdict != .pass && verdict != .recorded { failures.append("\(k): \(verdict)") }
        }
        #expect(failures.isEmpty, "\(id): \(failures.prefix(5))")
    }

    @Test("each costume look's rest poses match their goldens", arguments: costumeLooks)
    func Golden_lookRestPoses(look: String) throws {
        var failures: [String] = []
        for name in restPoseNames {
            let clip = try stageRenderer.art.pose(name)
            for k in clip.frames.indices {
                let blink = name == "blink"
                let atRest = name == "idle" || blink
                let frame = atRest ? Frames.rest(look: look) : Frames.pose(name, scene: .idle, look: look)
                let now = atRest ? 0 : middleOf(frame: k, in: clip)
                let stage = try #require(try stageRenderer.compose(StageRequest(frame: frame, now: now, blink: blink, geometry: Screens.geometry())))
                let verdict = try StageGoldens.check(stage.pixels, "looks/\(look)/\(name)_\(k).png")
                if verdict != .pass && verdict != .recorded { failures.append("\(name)_\(k): \(verdict)") }
            }
        }
        #expect(failures.isEmpty, "\(look): \(failures.prefix(5))")
    }

    @Test("the look change frames match their goldens", arguments: ["plain"] + costumeLooks)
    func Golden_lookTransitionFrames(look: String) throws {
        var failures: [String] = []
        for k in 0..<LookTransition.frameCount {
            let rising = k >= LookTransition.sinkFrames
            let from = rising ? "plain" : look, to = rising ? look : "plain"
            let progress = (Double(k) + 0.5) / Double(LookTransition.frameCount)
            let frame = SchedulerFrame(playback: MotionPlayback(source: .transition(from: from, to: to), use: "transition", startedAt: 0, duration: 1.6),
                                       look: to, displayedLook: rising ? to : from, transitionProgress: progress)
            let stage = try #require(try stageRenderer.compose(StageRequest(frame: frame, now: progress * 1.6, geometry: Screens.geometry())))
            let verdict = try StageGoldens.check(stage.pixels, "transition/\(look)-\(rising ? "up" : "down")/\(numbered(k)).png")
            if verdict != .pass && verdict != .recorded { failures.append("\(k): \(verdict)") }
        }
        #expect(failures.isEmpty, "\(look): \(failures.prefix(5))")
    }

    /// One bubble in its scene at a fixed moment: Clawd at home on a 1440 x 900 display, size 1, pixel scale 1.
    private struct Moment { let name: String; let scene: Scene; let elapsed: Double; var verb = "Cogitating"; var past = "Cooked"; var duration = 5.0; var reduce = false }
    private static let moments: [Moment] = [
        Moment(name: "listening-cursor-on", scene: .listening, elapsed: 0.1), Moment(name: "listening-cursor-off", scene: .listening, elapsed: 0.6),
        Moment(name: "thinking-glyph0", scene: .thinking, elapsed: 0.0), Moment(name: "thinking-glyph1", scene: .thinking, elapsed: 0.3),
        Moment(name: "thinking-glyph2", scene: .thinking, elapsed: 0.4), Moment(name: "thinking-glyph3", scene: .thinking, elapsed: 0.6),
        Moment(name: "thinking-glyph4", scene: .thinking, elapsed: 0.7), Moment(name: "thinking-glyph5", scene: .thinking, elapsed: 0.8),
        Moment(name: "thinking-reduced-motion-0", scene: .thinking, elapsed: 0.0, reduce: true),
        Moment(name: "thinking-reduced-motion-1", scene: .thinking, elapsed: 0.5, reduce: true),
        Moment(name: "thinking-reduced-motion-2", scene: .thinking, elapsed: 1.0, reduce: true),
        Moment(name: "thinking-longest-verb", scene: .thinking, elapsed: 0.7, verb: "Flibbertigibbeting"),
        Moment(name: "sent", scene: .sent, elapsed: 1.0), Moment(name: "sent-fade3", scene: .sent, elapsed: 1.72),
        Moment(name: "sent-fade2", scene: .sent, elapsed: 1.84), Moment(name: "sent-fade1", scene: .sent, elapsed: 1.96),
        Moment(name: "sent-longest", scene: .sent, elapsed: 1.0, past: "Cogitated", duration: 3599),
        Moment(name: "interrupted", scene: .interrupted, elapsed: 0.2), Moment(name: "error", scene: .error, elapsed: 0.2),
    ]
    private static func request(_ m: Moment, style: Int, geometry: PetGeometry = Screens.geometry(), pixelScale: Double = 1, side: BubbleSide = .above) -> StageRequest {
        let pose = m.scene == .listening ? "listen" : m.scene == .thinking ? "think" : m.scene == .sent ? "hop" : "idle"
        let frame = pose == "idle" ? Frames.rest(bubble: BubbleState(style: style, scene: m.scene), scene: m.scene)
                                   : Frames.pose(pose, scene: m.scene, bubble: BubbleState(style: style, scene: m.scene))
        return StageRequest(frame: frame, now: pose == "hop" ? 0.34 : 0.1, geometry: geometry, pixelScale: pixelScale,
                            content: BubbleContent(scene: m.scene, elapsed: m.elapsed, duration: m.duration, verb: m.verb, pastVerb: m.past, reduceMotion: m.reduce),
                            bubbleSide: side)
    }

    @Test("a bubble style in every scene matches its golden", arguments: BubbleDesign.ids)
    func Golden_bubbleStyleTimesScenes(style: Int) throws {
        var failures: [String] = []
        for m in Self.moments {
            let stage = try #require(try stageRenderer.compose(Self.request(m, style: style)))
            #expect(stage.bubble != nil, "style \(style) \(m.name) drew no bubble")
            let verdict = try StageGoldens.check(stage.pixels, "bubble/style\(style)-\(m.name).png")
            if verdict != .pass && verdict != .recorded { failures.append("\(m.name): \(verdict)") }
        }
        #expect(failures.isEmpty, "style \(style): \(failures.prefix(5))")
    }

    @Test("a bubble beside the head and at the larger sizes matches its golden", arguments: BubbleDesign.ids)
    func Golden_bubbleSideAndLargerSizes(style: Int) throws {
        var failures: [String] = []
        let thinking = Moment(name: "thinking", scene: .thinking, elapsed: 0.7)
        // beside the head: Clawd flush against the top edge, once in the left half (the bubble opens right) and once in the right half
        for (name, x) in [("right", 300.0), ("left", 1000.0)] {
            let geometry = PetGeometry(scale: 1, homeOrigin: CGPoint(x: x, y: Screens.visible.maxY - 48), displayFrame: Screens.display, visibleFrame: Screens.visible)
            let stage = try #require(try stageRenderer.compose(Self.request(thinking, style: style, geometry: geometry, side: name == "right" ? .right : .left)))
            #expect(stage.bubble?.plan.connection == .side && stage.bubble?.plan.opening == (name == "right" ? .right : .left))
            let verdict = try StageGoldens.check(stage.pixels, "bubble/style\(style)-side-opens-\(name).png")
            if verdict != .pass && verdict != .recorded { failures.append("side \(name): \(verdict)") }
        }
        // Clawd on the right: the bubble opens to the left, above the head
        let right = Screens.geometry(homeX: 1000)
        let opened = try #require(try stageRenderer.compose(Self.request(thinking, style: style, geometry: right)))
        let v1 = try StageGoldens.check(opened.pixels, "bubble/style\(style)-above-opens-left.png")
        if v1 != .pass && v1 != .recorded { failures.append("above left: \(v1)") }
        // size 2 on a Retina display (device scale 2) and size 1.5 on the ultrawide
        for (name, scale, backing) in [("size2-retina", 2.0, 2.0), ("size1.5", 1.5, 1.0)] {
            let stage = try #require(try stageRenderer.compose(Self.request(thinking, style: style, geometry: Screens.geometry(scale: scale), pixelScale: backing)))
            let verdict = try StageGoldens.check(stage.pixels, "bubble/style\(style)-\(name).png")
            if verdict != .pass && verdict != .recorded { failures.append("\(name): \(verdict)") }
        }
        #expect(failures.isEmpty, "style \(style): \(failures.prefix(5))")
    }

    @Test func Golden_aMismatchedEnvironmentPrintsEnvMismatchAndNeverPasses() throws {
        // The fields a pixel golden depends on: the rendering contract. (Another OS build or Menlo file is not one of them: see
        // `Golden_aPixelGoldenPassesUnderAnotherOSBuildAndFontButNotAnotherDecode`.)
        let real = try GoldenEnvironment.current(art: artDirectory)
        let doctored = GoldenEnvironment(swVers: real.swVers, fontPath: real.fontPath, fontSHA256: real.fontSHA256, colorSpace: "Display P3",
                                         scale: real.scale + 1, virtualTime: real.virtualTime, artSHA256: real.artSHA256)
        let stage = try #require(try stageRenderer.compose(StageRequest(frame: Frames.rest(), now: 0, geometry: Screens.geometry())))
        let verdict = try StageGoldens.check(stage.pixels, "looks/helmet/idle_0.png", environment: doctored)
        guard !StageGoldens.recording else { return }
        #expect(verdict == .envMismatch(["color_space", "scale"]), "\(verdict)")
        #expect(verdict != .pass)
    }

    // MARK: the pixel family's environment (D-13)

    /// The OS build and the Menlo file are not what a pixel golden depends on; the PNG decode is. A pixel golden passes under another sw_vers and another
    /// font hash, and reports ENV-MISMATCH `decode`, never a pass, when a canary decodes to other bytes. The two sidecars are byte-identical afterwards.
    @Test func Golden_aPixelGoldenPassesUnderAnotherOSBuildAndFontButNotAnotherDecode() throws {
        guard !StageGoldens.recording, !StageGoldens.recordingDecodePin else { return }
        let real = try GoldenEnvironment.current(art: artDirectory)
        let doctored = GoldenEnvironment(swVers: real.swVers + "BuildVersion: other\n", fontPath: real.fontPath + ".other", fontSHA256: "0", colorSpace: real.colorSpace,
                                         scale: real.scale, virtualTime: real.virtualTime, artSHA256: real.artSHA256)
        let before = (try ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent("environment.json").path),
                      try ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent("pixel-decode.json").path))
        let pin = try JSONDecoder().decode(DecodePin.self, from: before.1)
        var wrong = try DecodePin.hashes(canaries: StageGoldens.canaryDirectory, files: pin.canaries.map(\.file))
        wrong[pin.canaries[0].file] = "0000"
        let goldens: [(String, StageRequest)] = [
            ("bubble/style7-thinking-above-px1.png", StageRequest(frame: Frames.pose("think", scene: .thinking, bubble: BubbleState(style: 7, scene: .thinking)), now: 0.1,
                                                                    geometry: Screens.geometry(), pixelScale: 1,
                                                                    content: BubbleContent(scene: .thinking, elapsed: 0.7, duration: 5, verb: "Cogitating", pastVerb: "Cooked"),
                                                                    bubbleSide: .above)),
            ("motions/A5-walking/000.png", StageRequest(frame: Frames.motion("A5-walking"), now: middleOf(frame: 0, in: try stageRenderer.art.motion("A5-walking")), geometry: Screens.geometry())),
        ]
        for (name, request) in goldens {
            let stage = try #require(try stageRenderer.compose(request))
            let other = try StageGoldens.check(stage.pixels, name, environment: doctored)
            #expect(other == .pass, "\(name) under another OS build and font: \(other)")
            let notDecode = try StageGoldens.check(stage.pixels, name, environment: doctored, decode: wrong)
            #expect(notDecode == .envMismatch(["decode"]), "\(name) with a canary decoded to other bytes: \(notDecode)")
            #expect(notDecode != .pass)
        }
        let after = (try ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent("environment.json").path),
                     try ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent("pixel-decode.json").path))
        #expect(before.0 == after.0 && before.1 == after.1, "neither sidecar is touched")
    }

    /// The canaries stand for every input of a pixel golden: every art PNG and every stored golden is 8-bit RGBA, not interlaced, with a colour chunk
    /// from {none, sRGB}, and in a (colour chunk, alpha) class one of the canaries is in. A new class fails here until a canary for it is added.
    @Test func Golden_everyPixelGoldenInputIsInADecodeClassTheCanariesCover() throws {
        func classify(_ url: URL) throws -> String {
            let data = try ReadOnlyFile.data(url.path)
            let bytes = [UInt8](data)
            guard bytes.count > 33, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { return "not a PNG: \(url.lastPathComponent)" }
            var position = 8, colourChunk = "none"
            var header: (depth: UInt8, colourType: UInt8, interlace: UInt8)?
            while position + 8 <= bytes.count {
                let length = Int(bytes[position]) << 24 | Int(bytes[position + 1]) << 16 | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
                let kind = String(decoding: bytes[(position + 4)..<(position + 8)], as: UTF8.self)
                if kind == "IHDR" { header = (bytes[position + 16], bytes[position + 17], bytes[position + 20]) }
                if ["sRGB", "iCCP", "gAMA", "cHRM"].contains(kind) { colourChunk = colourChunk == "none" || kind == "sRGB" ? kind : colourChunk + "+" + kind }
                if kind == "IEND" { break }
                position += 12 + length
            }
            guard let header, header.depth == 8, header.colourType == 6, header.interlace == 0 else { return "not 8-bit RGBA, non-interlaced" }
            let raster = try Raster.decode(png: data)
            var partial = false
            for i in stride(from: 3, to: raster.data.count, by: 4) where raster.data[i] != 0 && raster.data[i] != 255 { partial = true; break }
            return "\(colourChunk)/\(partial ? "partial alpha" : "binary alpha")"
        }
        let covered = Set(try StageGoldens.canaries.map { try classify(StageGoldens.canaryDirectory.appendingPathComponent($0)) })
        #expect(covered == ["none/binary alpha", "none/partial alpha", "sRGB/binary alpha", "sRGB/partial alpha"], "\(covered)")
        var uncovered: [String: String] = [:], count = 0
        for root in [artDirectory, StageGoldens.directory] {
            let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walker where url.pathExtension == "png" {
                let kind = try classify(url)
                count += 1
                if !covered.contains(kind) { uncovered[url.path] = kind }
            }
        }
        #expect(uncovered.isEmpty, "inputs outside the canaries' classes: \(uncovered.prefix(3))")
        #expect(count > 7000, "\(count) PNGs read")
    }

    /// `CLAWD_RECORD_DECODE_PIN=1 swift test --filter Golden_recordTheDecodePin` writes Tests/Goldens/pixel-decode.json from the canaries as they decode
    /// on this Mac. It depends on no golden, so it relabels nothing. Without the variable it only reads the pin and checks it is well formed.
    @Test func Golden_recordTheDecodePin() throws {
        if StageGoldens.recordingDecodePin {
            try DecodePin.record(canaries: StageGoldens.canaryDirectory, files: StageGoldens.canaries, destination: try OwnState(root: StageGoldens.directory))
            emit("RECORDED: Tests/Goldens/pixel-decode.json")
            return
        }
        let pin = try JSONDecoder().decode(DecodePin.self, from: try ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent("pixel-decode.json").path))
        #expect(pin.canaries.map(\.file) == StageGoldens.canaries && pin.canaries.allSatisfy { $0.decodedSHA256.count == 64 })
    }

    @Test func Golden_aMissingStageGoldenFailsInsteadOfPassing() throws {
        guard !StageGoldens.recording else { return }
        let stage = try #require(try stageRenderer.compose(StageRequest(frame: Frames.rest(), now: 0, geometry: Screens.geometry())))
        let sidecarOnly = try artifactStore()
        try sidecarOnly.write(try ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent("environment.json").path), to: "environment.json")
        try sidecarOnly.write(try ReadOnlyFile.data(StageGoldens.directory.appendingPathComponent("pixel-decode.json").path), to: "pixel-decode.json")
        let verdict = try StageGoldens.check(stage.pixels, "motions/none/000.png", goldens: sidecarOnly.root)
        #expect(verdict == .missing("motions/none/000.png"), "\(verdict)")
        #expect(verdict != .pass)
    }

    @Test func Golden_aChangedPixelFailsTheComparison() throws {
        guard !StageGoldens.recording else { return }
        var stage = try #require(try stageRenderer.compose(StageRequest(frame: Frames.rest(look: "helmet"), now: 0, geometry: Screens.geometry()))).pixels
        let before = try StageGoldens.check(stage, "looks/helmet/idle_0.png")
        #expect(before == .pass, "\(before)")
        // One pixel of the golden's own picture, flipped: the diff must see exactly it.
        stage[10, 30] = stage[10, 30] == Pixel(1, 2, 3) ? Pixel(4, 5, 6) : Pixel(1, 2, 3)
        let after = try StageGoldens.check(stage, "looks/helmet/idle_0.png")
        #expect(after != .pass, "\(after)")
        if case .pixelDiff(_, let count) = after { #expect(count > 0) } else { Issue.record("expected a pixel diff, got \(after)") }
    }
}
