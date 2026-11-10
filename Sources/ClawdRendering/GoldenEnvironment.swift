import Foundation
import CryptoKit
import ClawdCore

/// Sidecar of the golden PNGs. A golden is valid only on the OS build, font file and rendering contract it was recorded on.
public struct GoldenEnvironment: Codable {
    public let swVers: String
    public let fontPath: String
    public let fontSHA256: String
    public let colorSpace: String
    public let scale: Double
    public let virtualTime: Double
    /// Informational: a changed art directory shows up as a pixel diff, not as an environment mismatch.
    public let artSHA256: String
    private enum CodingKeys: String, CodingKey {
        case swVers = "sw_vers", fontPath = "font_path", fontSHA256 = "font_sha256"
        case colorSpace = "color_space", scale, virtualTime = "virtual_time", artSHA256 = "art_sha256"
    }
    public enum Verdict: Equatable { case match, mismatch([String]) }
    public func compare(to expected: GoldenEnvironment) -> Verdict {
        var differences: [String] = []
        if swVers != expected.swVers { differences.append("sw_vers") }
        if fontPath != expected.fontPath { differences.append("font_path") }
        if fontSHA256 != expected.fontSHA256 { differences.append("font_sha256") }
        if colorSpace != expected.colorSpace { differences.append("color_space") }
        if scale != expected.scale { differences.append("scale") }
        if virtualTime != expected.virtualTime { differences.append("virtual_time") }
        return differences.isEmpty ? .match : .mismatch(differences)
    }
    public init(swVers: String, fontPath: String, fontSHA256: String, colorSpace: String, scale: Double,
                virtualTime: Double, artSHA256: String) {
        self.swVers = swVers; self.fontPath = fontPath; self.fontSHA256 = fontSHA256; self.colorSpace = colorSpace
        self.scale = scale; self.virtualTime = virtualTime; self.artSHA256 = artSHA256
    }
    public static let fixedVirtualTime = 0.25
    public static func current(art: URL) throws -> Self {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
        let pipe = Pipe(); process.standardOutput = pipe; try process.run()
        let version = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ArtError.encoding }
        var hash = SHA256()
        let atlasData = try ReadOnlyFile.data(art.appendingPathComponent("clawd-atlas.json").path)
        hash.update(data: atlasData)
        hash.update(data: try ReadOnlyFile.data(art.appendingPathComponent("claude-code-elements.json").path))
        guard let json = try JSONSerialization.jsonObject(with: atlasData) as? [String: Any],
              let poses = json["poses"] as? [String: [String: Any]] else { throw ArtError.invalidAtlas }
        let frames = Set(poses.values.flatMap { $0["frames"] as? [String] ?? [] }).sorted()
        for file in frames { hash.update(data: try ReadOnlyFile.data(art.appendingPathComponent(file).path)) }
        return Self(swVers: String(decoding: version, as: UTF8.self), fontPath: SceneRenderer.fontPath,
                    fontSHA256: SHA256.hash(data: try ReadOnlyFile.data(SceneRenderer.fontPath, limit: 32 * 1024 * 1024)).map { String(format: "%02x", $0) }.joined(),
                    colorSpace: "sRGB", scale: 1, virtualTime: fixedVirtualTime,
                    artSHA256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    /// Fixed inputs for every golden: verb "Clauding", past verb "Cooked", 5 s dictation, scale 1, virtual time 0.25 s.
    public static func frame(_ scene: Scene) -> RenderFrame {
        RenderFrame(scene: scene, chipScene: scene == .drag ? .listening : scene, elapsed: fixedVirtualTime)
    }
    public static func record(art: URL, destination: URL) throws {
        let environment = try current(art: art)
        let renderer = try SceneRenderer(art: art)
        let state = try OwnState(root: destination)
        for scene in Scene.allCases {
            try state.write(SceneRenderer.png(renderer.render(frame(scene), fixedCanvas: true)), to: scene.rawValue + ".png")
        }
        try state.writeJSON(environment, to: "environment.json")
    }
}


// MARK: families (amendment D-13)

/// Which goldens an environment sidecar speaks for. Each family depends on a different part of the environment, and only that part is compared.
public enum GoldenFamily: Equatable {
    /// The v1 scene goldens: CoreText draws their chip in Menlo, so the OS build, the font file and its hash all count.
    case scene
    /// The pixel stage goldens (motions, looks, transitions, bubble styles 1-13): integer arithmetic over decoded art. The OS enters only through
    /// the PNG decode, which the decode pin checks. Only the rendering contract is compared here.
    case pixelStage
}

extension GoldenEnvironment {
    /// The fields `family` depends on. `.scene` is every field (`compare(to:)`); `.pixelStage` is the rendering contract: colour space, scale and
    /// virtual time, and not sw_vers, font_path or font_sha256.
    public func compare(to expected: GoldenEnvironment, family: GoldenFamily) -> Verdict {
        guard family == .pixelStage else { return compare(to: expected) }
        var differences: [String] = []
        if colorSpace != expected.colorSpace { differences.append("color_space") }
        if scale != expected.scale { differences.append("scale") }
        if virtualTime != expected.virtualTime { differences.append("virtual_time") }
        return differences.isEmpty ? .match : .mismatch(differences)
    }
}

// MARK: the decode pin

/// What `Raster.decode` makes of a few fixed canary PNGs on the Mac the pixel goldens were recorded on (D-13). The pixel goldens depend on the OS only
/// through the PNG decoder (ImageIO into an sRGB premultiplied context), so they pass on any Mac whose decoder gives these bytes and on no other.
public struct DecodePin: Codable, Equatable {
    public struct Canary: Codable, Equatable {
        public let file: String
        public let decodedSHA256: String
        private enum CodingKeys: String, CodingKey { case file, decodedSHA256 = "decoded_sha256" }
        public init(file: String, decodedSHA256: String) { self.file = file; self.decodedSHA256 = decodedSHA256 }
    }
    /// For information only: the OS the pin was written on. It is never compared.
    public let swVers: String
    public let canaries: [Canary]
    private enum CodingKeys: String, CodingKey { case swVers = "sw_vers", canaries }
    public init(swVers: String, canaries: [Canary]) { self.swVers = swVers; self.canaries = canaries }

    /// The SHA-256 of what `Raster.decode` makes of each file of `directory` (its size and its bytes), by file name.
    public static func hashes(canaries directory: URL, files: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for file in files {
            let raster = try Raster.decode(png: try ReadOnlyFile.data(directory.appendingPathComponent(file).path))
            var hash = SHA256()
            hash.update(data: Data("\(raster.width)x\(raster.height)\n".utf8))
            hash.update(data: Data(raster.data))
            result[file] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
    /// The canaries whose decode now differs from the pin (or is missing).
    public func differences(from current: [String: String]) -> [String] {
        canaries.filter { current[$0.file] != $0.decodedSHA256 }.map(\.file)
    }
    /// Writes the pin of `files` as they decode now. Only an explicit run does this (`CLAWD_RECORD_DECODE_PIN=1`); it depends on no golden.
    public static func record(canaries directory: URL, files: [String], destination: OwnState) throws {
        let hashes = try hashes(canaries: directory, files: files)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
        let pipe = Pipe(); process.standardOutput = pipe; try process.run()
        let version = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ArtError.encoding }
        let pin = DecodePin(swVers: String(decoding: version, as: UTF8.self),
                            canaries: files.map { Canary(file: $0, decodedSHA256: hashes[$0] ?? "") })
        try destination.writeJSON(pin, to: "pixel-decode.json")
    }
}

// MARK: the smooth goldens' own sidecar

/// The sidecar of the smooth goldens (styles 14 and 15; D-13): the OS build, the colour space, the version of the fixed drawing flags, every font
/// file they draw with (path and SHA-256, each resolved from the font in use) and a manifest of the PNGs it vouches for. The pixel goldens never read
/// it and it never reads theirs.
public struct SmoothEnvironment: Codable, Equatable {
    public struct FontFile: Codable, Equatable {
        public let role: String
        public let path: String
        public let sha256: String
        public init(role: String, path: String, sha256: String) { self.role = role; self.path = path; self.sha256 = sha256 }
    }
    public let swVers: String
    public let colorSpace: String
    public let drawingFlagsVersion: Int
    public let fonts: [FontFile]
    /// SHA-256 of every PNG this sidecar vouches for, by its path under Tests/Goldens.
    public let manifest: [String: String]
    private enum CodingKeys: String, CodingKey {
        case swVers = "sw_vers", colorSpace = "color_space", drawingFlagsVersion = "drawing_flags_version", fonts, manifest
    }
    public init(swVers: String, colorSpace: String, drawingFlagsVersion: Int, fonts: [FontFile], manifest: [String: String]) {
        self.swVers = swVers; self.colorSpace = colorSpace; self.drawingFlagsVersion = drawingFlagsVersion; self.fonts = fonts; self.manifest = manifest
    }

    /// This Mac: sw_vers, the sRGB space, the drawing flags' version and the font files the smooth styles draw with. `manifest` is what the caller says
    /// it covers (empty when only the environment is wanted).
    public static func current(manifest: [String: String] = [:]) throws -> SmoothEnvironment {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
        let pipe = Pipe(); process.standardOutput = pipe; try process.run()
        let version = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ArtError.encoding }
        return SmoothEnvironment(swVers: String(decoding: version, as: UTF8.self), colorSpace: SmoothBubble.drawingConfiguration(backing: 1).colorSpace,
                                 drawingFlagsVersion: SmoothDrawingConfiguration.version, fonts: try SmoothFonts.fontFiles(), manifest: manifest)
    }

    /// What differs between this Mac and the recorded sidecar: the environment only, never the manifest (that is checked image by image).
    public func compare(to recorded: SmoothEnvironment) -> GoldenEnvironment.Verdict {
        var differences: [String] = []
        if swVers != recorded.swVers { differences.append("sw_vers") }
        if colorSpace != recorded.colorSpace { differences.append("color_space") }
        if drawingFlagsVersion != recorded.drawingFlagsVersion { differences.append("drawing_flags") }
        if fonts.map(\.role) != recorded.fonts.map(\.role) { differences.append("fonts") }
        for (now, then) in zip(fonts, recorded.fonts) where now.role == then.role {
            if now.path != then.path { differences.append("font_path:" + now.role) }
            if now.sha256 != then.sha256 { differences.append("font_sha256:" + now.role) }
        }
        return differences.isEmpty ? .match : .mismatch(differences)
    }

    /// The manifest's entry for `relative` against the stored file: nil when the stored file is the image the sidecar was recorded with.
    public func manifestProblem(for relative: String, storedPNG data: Data) -> String? {
        guard let recorded = manifest[relative] else { return "\(relative) is not in the manifest of this sidecar" }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == recorded ? nil : "\(relative) is not the image this sidecar was recorded with"
    }
}

/// Regenerates the smooth goldens (`CLAWD_RECORD_SMOOTH_GOLDENS=1`). One run renders the whole matrix, compares every image with its stored PNG,
/// writes a report, writes the new PNGs, and writes the sidecar last with the manifest of exactly the PNGs it wrote. It refuses to write the
/// sidecar unless every image of the matrix was rendered and written in this run.
public enum SmoothGoldenRecorder {
    public enum Failure: Error, Equatable { case notRendered([String]), notWritten([String]) }
    public static let sidecarPath = "bubble/smooth-environment.json"

    /// `matrix`: the relative paths under `goldens` of every image. `render` draws one. Returns the report's lines (file, differing pixels, largest
    /// channel difference); a stored PNG that is missing is reported as new.
    @discardableResult
    public static func record(matrix: [String], render: (String) throws -> Raster, goldens: OwnState, evidence: OwnState, environment: SmoothEnvironment,
                              sidecar sidecarFile: String = SmoothGoldenRecorder.sidecarPath, report reportFile: String = "smooth-golden-report.tsv") throws -> [String] {
        var rendered: [String: Raster] = [:], failed: [String] = []
        for relative in matrix {
            do { rendered[relative] = try render(relative) } catch { failed.append(relative) }
        }
        guard failed.isEmpty else { throw Failure.notRendered(failed) }
        var report = ["file\tdiffering pixels\tlargest channel difference"]
        for relative in matrix {
            let raster = rendered[relative]!
            if let stored = try? Raster.decode(png: try ReadOnlyFile.data(goldens.root.appendingPathComponent(relative).path)) {
                if stored.width == raster.width && stored.height == raster.height {
                    var differing = 0, largest = 0
                    for pixel in stride(from: 0, to: raster.data.count, by: 4) {
                        var difference = 0
                        for i in pixel..<(pixel + 4) { difference = max(difference, abs(Int(raster.data[i]) - Int(stored.data[i]))) }
                        if difference > 0 { differing += 1 }
                        largest = max(largest, difference)
                    }
                    report.append("\(relative)\t\(differing)\t\(largest)")
                } else { report.append("\(relative)\tsize \(stored.width)x\(stored.height) -> \(raster.width)x\(raster.height)\t-") }
            } else { report.append("\(relative)\tnew\t-") }
        }
        var manifest: [String: String] = [:], unwritten: [String] = []
        for relative in matrix {
            let png = try SceneRenderer.png(try rendered[relative]!.cgImage())
            do { try goldens.write(png, to: relative); manifest[relative] = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined() } catch { unwritten.append(relative) }
        }
        guard unwritten.isEmpty else { throw Failure.notWritten(unwritten) }
        try evidence.write(Data(report.joined(separator: "\n").utf8), to: reportFile)
        let sidecar = SmoothEnvironment(swVers: environment.swVers, colorSpace: environment.colorSpace, drawingFlagsVersion: environment.drawingFlagsVersion,
                                        fonts: environment.fonts, manifest: manifest)
        try goldens.writeJSON(sidecar, to: sidecarFile)
        return report
    }
}
