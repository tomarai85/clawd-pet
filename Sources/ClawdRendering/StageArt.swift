import Foundation
import CoreGraphics
import ClawdCore

/// Cell coordinates: one cell is half a Clawd unit (2 pt at size 1). The canvas is 24 x 24 cells with its top-left at (0, 0);
/// anything above or left of it has a negative coordinate.
public struct CellPoint: Equatable, Hashable {
    public var x: Int, y: Int
    public init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
}

public enum StageGeometry {
    public static let canvasCells = 24
    /// Rows of the 6-unit torso, in cells.
    public static let torsoRows = 12
    /// Half the torso: the body's vertical centre sits this far below the torso's top row.
    public static let torsoHalf = 6
    /// The torso is 8 units wide, so 8 cells on each side of the head's centre line.
    public static let torsoHalfWidth = 8
}

/// One picture of Clawd: pixels at cell resolution on the stage of its clip, and where the head is (nil: not front-facing).
public struct ClipFrame {
    public let raster: Raster
    public let head: CellPoint?
    public init(raster: Raster, head: CellPoint?) { self.raster = raster; self.head = head }
}

/// A sequence of pictures with one stage. v1 poses and the ported motions both become clips, so the compositor has one input shape.
public final class Clip {
    public let id: String
    public let frames: [ClipFrame]
    public let ms: [Int]
    /// Extra cells beyond the 24 x 24 canvas.
    public let left: Int, right: Int, up: Int, down: Int
    public let loops: Bool
    public let holds: Bool
    /// The frames before this one (the lead bridge of the art) play once; a looping clip repeats from here.
    public let loopStart: Int
    /// A walk's stepping frames: a looping play of the clip repeats only these (its rest frames inside the cycle are left out). It starts at
    /// `loopEntry`, plays on to the first of these once, then repeats them.
    public var loopRange: Range<Int>?
    public var loopEntry = 0
    public init(id: String, frames: [ClipFrame], ms: [Int], left: Int = 0, right: Int = 0, up: Int = 0, down: Int = 0, loops: Bool = false, holds: Bool = false,
                loopStart: Int = 0) {
        self.id = id; self.frames = frames; self.ms = ms; self.left = left; self.right = right; self.up = up; self.down = down
        self.loops = loops; self.holds = holds; self.loopStart = min(max(0, loopStart), max(0, frames.count - 1))
    }
    public var duration: Double { Double(ms.reduce(0, +)) / 1000 }
    /// Seconds the frames before `loopStart` take.
    private var leadDuration: Double { Double(ms[0..<loopStart].reduce(0, +)) / 1000 }
    /// `elapsed` folded into the clip's own time: a looping clip plays its lead once, then repeats the rest.
    private func clipTime(_ elapsed: Double, looping: Bool) -> Double {
        let t = max(0, elapsed)
        guard looping else { return t }
        if let range = loopRange {
            let from = leadTime(of: range), at = t + Double(ms[0..<min(loopEntry, range.lowerBound)].reduce(0, +)) / 1000
            return at < from ? at : from + (at - from).truncatingRemainder(dividingBy: Double(ms[range].reduce(0, +)) / 1000)
        }
        let lead = leadDuration
        if t < lead { return t }
        return lead + (t - lead).truncatingRemainder(dividingBy: duration - lead)
    }
    private func leadTime(of range: Range<Int>) -> Double { Double(ms[0..<range.lowerBound].reduce(0, +)) / 1000 }
    /// The frame on screen `elapsed` seconds after the clip started.
    public func index(at elapsed: Double, loops looping: Bool? = nil) -> Int {
        let total = duration
        guard frames.count > 1, total > 0 else { return 0 }
        let isLooping = looping ?? loops
        if !isLooping && elapsed >= total { return frames.count - 1 }
        var t = clipTime(elapsed, looping: isLooping)
        for i in frames.indices { t -= Double(ms[i]) / 1000; if t < 0 { return i } }
        return frames.count - 1
    }
    /// Seconds until the picture after the one shown at `elapsed` replaces it; nil when it never changes.
    public func nextChange(after elapsed: Double, loops looping: Bool? = nil) -> Double? {
        let total = duration
        guard frames.count > 1, total > 0 else { return nil }
        let isLooping = looping ?? loops
        if !isLooping && elapsed >= total { return nil }
        let t = clipTime(elapsed, looping: isLooping)
        var end = 0.0
        for m in ms { end += Double(m) / 1000; if end > t { return end - t } }
        return 0.001
    }
}

/// How a look draws and where it is anchored. Layers are placed from the head anchor, the canvas or the feet.
public final class LookArt {
    public enum Z: String { case back, front }
    public enum Anchor: String { case head, canvas, feet }
    public struct Layer {
        public let name: String
        public let z: Z
        public let anchor: Anchor
        public let offset: CellPoint
        public let raster: Raster
        /// The costume pixels take clicks (body pixels plus costume pixels, spec 4.4); held props and boards do not.
        public let takesClicks: Bool
        public let restPoses: [String: [CellPoint]]
        public init(name: String, z: Z, anchor: Anchor = .head, offset: CellPoint, raster: Raster, takesClicks: Bool, restPoses: [String: [CellPoint]] = [:]) {
            self.name = name; self.z = z; self.anchor = anchor; self.offset = offset; self.raster = raster
            self.takesClicks = takesClicks; self.restPoses = restPoses
        }
    }
    public let id: String
    public let classes: Set<String>
    public let layers: [Layer]
    /// A signature motion draws the prop itself: the layers are not composed onto it.
    public let layerOnSignature: Bool
    public let signature: [String]
    /// Exact colour substitution on the body for body-colour looks.
    public let bodyMap: [UInt32: UInt32]
    /// Cells Clawd is lifted by (the under-feet class): the board sits on the baseline, Clawd stands on it.
    public let raise: Int
    public init(id: String, classes: Set<String>, layers: [Layer], layerOnSignature: Bool = true, signature: [String] = [],
                bodyMap: [UInt32: UInt32] = [:], raise: Int = 0) {
        self.id = id; self.classes = classes; self.layers = layers; self.layerOnSignature = layerOnSignature
        self.signature = signature; self.bodyMap = bodyMap; self.raise = raise
    }
    /// The plain look: no layers, no recolouring.
    public static let plain = LookArt(id: "plain", classes: ["plain"], layers: [], layerOnSignature: true, signature: [], bodyMap: [:], raise: 0)
}

/// How a looping walk plays: from `entry` (the last rest picture) through the step-off, then `repeating` over and over.
struct WalkLoop { let entry: Int; let repeating: Range<Int> }

/// The art the stage draws from, read once from `art/clawd-atlas.json`: v1 poses, schema-2 motions and looks.
/// Motion clips are decoded on first use and kept.
public final class ClawdArt {
    public let directory: URL
    public let atlas: ArtAtlas
    public let catalog: PetCatalog
    private let motionEntries: [String: [String: Any]]
    /// The frames of each walk that step, by motion id (`steppingFrames`).
    private let walkLoops: [String: WalkLoop]
    private let lookEntries: [String: [String: Any]]
    /// The in-between pictures (`bridges` of the atlas), by "<kind>:<target id>:<side>".
    private let bridgeEntries: [String: [String: Any]]
    private var poseClips: [String: Clip] = [:]
    private var motionClips: [String: Clip] = [:]
    private var lookCache: [String: LookArt] = [:]
    private let lock = NSLock()

    public init(directory: URL) throws {
        self.directory = directory
        atlas = try ArtAtlas(directory: directory)
        let data = try ReadOnlyFile.data(directory.appendingPathComponent("clawd-atlas.json").path, limit: 8 * 1024 * 1024)
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var motions: [String: [String: Any]] = [:], looks: [String: [String: Any]] = [:]
        for case let entry as [String: Any] in root["motions"] as? [Any] ?? [] { if let id = entry["id"] as? String { motions[id] = entry } }
        for case let entry as [String: Any] in root["looks"] as? [Any] ?? [] { if let id = entry["id"] as? String { looks[id] = entry } }
        motionEntries = motions; lookEntries = looks
        // A walk plays only its stepping frames: its rest frames inside the cycle would show Clawd gliding on one picture. The scheduler sizes a leg
        // in whole cycles, so it is told the shorter cycle. Frames that cannot be read here fail where the motion is drawn, as before.
        var loops: [String: WalkLoop] = [:]
        var sized = PetCatalog(atlasData: data)
        for motion in sized.motions where motion.uses.contains(.walk) {
            guard let entry = motions[motion.id], let walk = (try? Self.steppingFrames(entry, directory: directory)) ?? nil else { continue }
            loops[motion.id] = walk
            let ms = (entry["ms"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            sized = sized.replacingDuration(of: motion.id, with: Double(ms[walk.repeating].reduce(0, +)) / 1000,
                                            leadIn: Double(ms[walk.entry..<walk.repeating.lowerBound].reduce(0, +)) / 1000)
        }
        walkLoops = loops; catalog = sized
        var bridges: [String: [String: Any]] = [:]
        for case let entry as [String: Any] in root["bridges"] as? [Any] ?? [] {
            if let target = entry["target"] as? [String: Any], let kind = target["kind"] as? String, let id = target["id"] as? String,
               let side = entry["side"] as? String, side == "lead" || side == "tail" { bridges["\(kind):\(id):\(side)"] = entry }
        }
        bridgeEntries = bridges
    }

    /// The frames of a bridge (its lead or its tail) laid on a target's stage, or none when the art has no such bridge. A bridge that is not as big as
    /// the target's stage is a broken atlas, not a missing bridge.
    private func bridge(kind: String, id: String, side: String, width: Int, height: Int) throws -> (frames: [ClipFrame], ms: [Int]) {
        guard let entry = bridgeEntries["\(kind):\(id):\(side)"] else { return ([], []) }
        guard let names = entry["frames"] as? [String], !names.isEmpty,
              let ms = (entry["ms"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }), ms.count == names.count, ms.allSatisfy({ $0 > 0 }) else {
            throw ArtError.missingFrame("\(id) \(side)")
        }
        let heads = entry["head"] as? [Any] ?? []
        var frames: [ClipFrame] = []
        for (i, name) in names.enumerated() {
            var head: CellPoint?
            if i < heads.count, let pair = heads[i] as? [Any], pair.count == 2,
               let x = (pair[0] as? NSNumber)?.intValue, let y = (pair[1] as? NSNumber)?.intValue { head = CellPoint(x, y) }
            let raster = try decode(name)
            guard raster.width == width, raster.height == height else { throw ArtError.invalidAtlas }
            frames.append(ClipFrame(raster: raster, head: head))
        }
        return (frames, ms)
    }

    /// How a walk plays in a leg: from the last rest frame at its start, through the step-off, then the stepping period that repeats pixel for
    /// pixel; with no such period, the frames from that rest frame to the first rest frame at its end. No run of rest frames sits in the repeat.
    /// nil when the walk does not start and end on rest, or has no rest run to cut.
    static func steppingFrames(_ entry: [String: Any], directory: URL) throws -> WalkLoop? {
        guard entry["restStart"] as? Bool == true, entry["restEnd"] as? Bool == true, let names = entry["frames"] as? [String], names.count > 2 else { return nil }
        let rasters = try names.map { try Raster.decode(png: ReadOnlyFile.data(directory.appendingPathComponent($0).path)) }
        var lead = 1, trail = 1
        while lead < rasters.count, rasters[lead] == rasters[0] { lead += 1 }
        while trail < rasters.count, rasters[rasters.count - 1 - trail] == rasters[rasters.count - 1] { trail += 1 }
        let range = (lead - 1)..<(rasters.count - trail + 1)
        guard range.count < rasters.count else { return nil }
        // Past the step-off frame the stepping repeats: the smallest period whose pictures come back pixel for pixel, seen at least twice. A leg
        // plays the last rest picture and the step-off once, then only that period, so no rest picture shows while Clawd moves.
        let first = lead + 1, end = rasters.count - trail
        if end - first >= 2 {
            for period in 1...((end - first) / 2) where (first..<(end - period)).allSatisfy({ rasters[$0] == rasters[$0 + period] }) {
                return WalkLoop(entry: lead - 1, repeating: first..<(first + period))
            }
        }
        return WalkLoop(entry: range.lowerBound, repeating: range)
    }

    public var motionIDs: [String] { motionEntries.keys.sorted() }
    public var lookIDs: [String] { lookEntries.keys.sorted() }

    private func decode(_ relative: String) throws -> Raster {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw ArtError.invalidAtlas }
        return try Raster.decode(png: ReadOnlyFile.data(directory.appendingPathComponent(relative).path))
    }

    // MARK: v1 poses

    /// A v1 pose as a clip: 12 x 12 pixels become 24 x 24 cells, the head is where the torso's top row is.
    public func pose(_ name: String) throws -> Clip {
        lock.lock(); defer { lock.unlock() }
        if let clip = poseClips[name] { return clip }
        guard let pose = atlas.poses[name] else { throw ArtError.missingFrame(name) }
        let lead = try bridge(kind: "pose", id: name, side: "lead", width: StageGeometry.canvasCells, height: StageGeometry.canvasCells)
        var frames: [ClipFrame] = lead.frames
        for file in pose.frames {
            let small = try decode(file)
            let raster = small.upscaled(by: 2)
            frames.append(ClipFrame(raster: raster, head: Self.restHead(small)))
        }
        let clip = Clip(id: name, frames: frames, ms: lead.ms + pose.ms.map { Int($0.rounded()) }, left: 0, right: 0, up: 0, down: 0,
                        loops: pose.loop, holds: false, loopStart: lead.frames.count)
        poseClips[name] = clip
        return clip
    }

    /// The head anchor of a 12 x 12 v1 frame: centre of the canvas, the first row whose 8 torso columns are all body colour.
    static func restHead(_ small: Raster) -> CellPoint? {
        for row in 0..<small.height {
            if (2..<10).allSatisfy({ small[$0, row] == Pixel(215, 119, 87) }) { return CellPoint(StageGeometry.canvasCells / 2, row * 2) }
        }
        return nil
    }

    // MARK: motions

    public func hasMotion(_ id: String) -> Bool { motionEntries[id] != nil }

    public func motion(_ id: String) throws -> Clip {
        lock.lock(); defer { lock.unlock() }
        if let clip = motionClips[id] { return clip }
        guard let entry = motionEntries[id], let names = entry["frames"] as? [String], !names.isEmpty,
              let ms = (entry["ms"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }), ms.count == names.count else {
            throw ArtError.missingFrame(id)
        }
        let stage = entry["stage"] as? [String: Any] ?? [:]
        func cells(_ key: String) -> Int { Int(((stage[key] as? NSNumber)?.doubleValue ?? 0) * 2) }
        let heads = entry["head"] as? [Any] ?? []
        var frames: [ClipFrame] = []
        for (i, name) in names.enumerated() {
            var head: CellPoint?
            if i < heads.count, let pair = heads[i] as? [Any], pair.count == 2,
               let x = (pair[0] as? NSNumber)?.intValue, let y = (pair[1] as? NSNumber)?.intValue { head = CellPoint(x, y) }
            frames.append(ClipFrame(raster: try decode(name), head: head))
        }
        let hold: Bool
        if let flag = entry["hold"] as? NSNumber { hold = flag.boolValue } else { hold = entry["hold"] != nil && !(entry["hold"] is NSNull) }
        let width = 24 + cells("left") + cells("right"), height = 24 + cells("up") + cells("down")
        for frame in frames where frame.raster.width != width || frame.raster.height != height { throw ArtError.invalidAtlas }
        // The bridges play before and after the motion's own frames: the clip is lead + frames + tail, one list for the renderer.
        let lead = try bridge(kind: "motion", id: id, side: "lead", width: width, height: height)
        let tail = try bridge(kind: "motion", id: id, side: "tail", width: width, height: height)
        let clip = Clip(id: id, frames: lead.frames + frames + tail.frames, ms: lead.ms + ms + tail.ms, left: cells("left"), right: cells("right"),
                        up: cells("up"), down: cells("down"), loops: false, holds: hold)
        if let walk = walkLoops[id] {
            let shift = lead.frames.count
            clip.loopRange = (walk.repeating.lowerBound + shift)..<(walk.repeating.upperBound + shift)
            clip.loopEntry = walk.entry + shift
        }
        motionClips[id] = clip
        return clip
    }

    // MARK: looks

    public func look(_ id: String) throws -> LookArt {
        if id == PetCatalog.plainLook { return .plain }
        lock.lock(); defer { lock.unlock() }
        if let cached = lookCache[id] { return cached }
        guard let entry = lookEntries[id] else { throw ArtError.missingFrame(id) }
        var classes = Set<String>()
        if let one = entry["class"] as? String { classes.insert(one) }
        for case let name as String in entry["class"] as? [Any] ?? [] { classes.insert(name) }
        if classes.isEmpty { classes = ["plain"] }
        var layers: [LookArt.Layer] = []
        for case let raw as [String: Any] in entry["layers"] as? [Any] ?? [] {
            guard let png = raw["png"] as? String, let pair = raw["offset"] as? [Any], pair.count == 2,
                  let ox = (pair[0] as? NSNumber)?.intValue, let oy = (pair[1] as? NSNumber)?.intValue else { throw ArtError.invalidAtlas }
            var rest: [String: [CellPoint]] = [:]
            for (pose, list) in raw["restPoses"] as? [String: Any] ?? [:] {
                rest[pose] = (list as? [Any] ?? []).compactMap { item in
                    guard let p = item as? [Any], p.count == 2, let x = (p[0] as? NSNumber)?.intValue, let y = (p[1] as? NSNumber)?.intValue else { return nil }
                    return CellPoint(x, y)
                }
            }
            let hits = (raw["takesClicks"] as? NSNumber)?.boolValue ?? (classes.contains("costume") || classes.contains("torso-overlay"))
            layers.append(LookArt.Layer(name: raw["name"] as? String ?? png, z: LookArt.Z(rawValue: raw["z"] as? String ?? "front") ?? .front,
                                        anchor: LookArt.Anchor(rawValue: raw["anchor"] as? String ?? "head") ?? .head,
                                        offset: CellPoint(ox, oy), raster: try decode(png), takesClicks: hits, restPoses: rest))
        }
        var bodyMap: [UInt32: UInt32] = [:]
        if let block = entry["bodyColor"] as? [String: Any] {
            for case let item as [String: Any] in block["map"] as? [Any] ?? [] {
                func rgb(_ value: Any?) -> UInt32? {
                    guard let c = value as? [Any], c.count == 3, let r = (c[0] as? NSNumber)?.intValue, let g = (c[1] as? NSNumber)?.intValue,
                          let b = (c[2] as? NSNumber)?.intValue, (0...255).contains(r), (0...255).contains(g), (0...255).contains(b) else { return nil }
                    return UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
                }
                if let from = rgb(item["from"]), let to = rgb(item["to"]) { bodyMap[from] = to }
            }
        }
        let look = LookArt(id: id, classes: classes, layers: layers, layerOnSignature: (entry["layerOnSignature"] as? NSNumber)?.boolValue ?? true,
                           signature: (entry["signature"] as? [Any])?.compactMap { $0 as? String } ?? [],
                           bodyMap: bodyMap, raise: max(0, (entry["raiseCells"] as? NSNumber)?.intValue ?? 0))
        lookCache[id] = look
        return look
    }
}
