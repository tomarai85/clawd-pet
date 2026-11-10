import Foundation

/// Where a motion may play. The strings are the `uses` values of the schema-2 catalog (Interface Contract).
public struct MotionUse: Hashable {
    public let name: String
    public init(_ name: String) { self.name = name }
    public static let idle = MotionUse("idle")
    public static let walk = MotionUse("walk")
    public static let walkPause = MotionUse("walk-pause")
    public static let listening = MotionUse("listening")
    public static let thinking = MotionUse("thinking")
    public static let sent = MotionUse("sent")
    public static let interrupted = MotionUse("interrupted")
    public static let error = MotionUse("error")
    public static let touch = MotionUse("touch")
    public static let multiTouch = MotionUse("multi-touch")
    public static let drop = MotionUse("drop")
    public static let entrance = MotionUse("entrance")
    public static let sleepEntry = MotionUse("sleep-entry")
    /// The skateboard's glide (`D14-ride`). No pool picks it: it plays only while a skateboard walks.
    public static let ride = MotionUse("ride")
    public static func signature(_ look: String) -> MotionUse { MotionUse("signature:" + look) }
    /// The look this use is the signature of, when it is a `signature:<look>` use.
    public var signatureLook: String? {
        name.hasPrefix("signature:") ? String(name.dropFirst("signature:".count)) : nil
    }
}

/// Extra units a motion draws beyond the 12 x 12 canvas (spec 3.2 "extra L/R/U", Interface Contract `stage`).
public struct StageExtent: Equatable {
    public var left: Double, right: Double, up: Double, down: Double
    public init(left: Double = 0, right: Double = 0, up: Double = 0, down: Double = 0) {
        self.left = left; self.right = right; self.up = up; self.down = down
    }
    public static let none = StageExtent()
}

public struct CatalogMotion: Equatable {
    public var id: String
    public var board: String
    public var kind: String
    public var uses: Set<MotionUse>
    public var frameCount: Int
    /// Playing time in seconds: the sum of the per-frame `ms`.
    public var duration: TimeInterval
    public var stage: StageExtent
    /// No non-body pixel above the head anchor in any frame (spec 6.3). Absent in the file means false: scene pools fail closed.
    public var overheadClear: Bool
    public var weight: Double
    public var phase: Int
    /// The computed compatible looks (K1). `nil` means the key is absent: only the plain look is assumed.
    public var compatibleLooks: Set<String>?
    /// Walk motions only: units of travel per full cycle, so the feet do not slide (spec 6.2). `nil` means the art has not declared it.
    public var strideUnits: Double?
    /// The last frame stays on screen after the motion ends (Snooze).
    public var holdsLastFrame: Bool
    /// A procedural horizontal mirror of another entry (`A5-walking-mirrored` of `A5-walking`): never scheduled on its own.
    public var mirrorOf: String?
    /// Walk motions only: seconds a leg plays before its cycle repeats (the rest picture and the step-off). A leg is this plus whole `duration`s.
    public var leadIn: TimeInterval

    public init(id: String, board: String = "", kind: String = "ported", uses: Set<MotionUse>, frameCount: Int = 1,
                duration: TimeInterval, stage: StageExtent = .none, overheadClear: Bool = false, weight: Double = 1,
                phase: Int = 1, compatibleLooks: Set<String>? = nil, strideUnits: Double? = nil, holdsLastFrame: Bool = false,
                mirrorOf: String? = nil, leadIn: TimeInterval = 0) {
        self.leadIn = leadIn
        self.id = id; self.board = board; self.kind = kind; self.uses = uses; self.frameCount = frameCount
        self.duration = duration; self.stage = stage; self.overheadClear = overheadClear; self.weight = weight
        self.phase = phase; self.compatibleLooks = compatibleLooks; self.strideUnits = strideUnits
        self.holdsLastFrame = holdsLastFrame; self.mirrorOf = mirrorOf
    }

    /// The item name inside the id (`A12-heart` -> `heart`).
    public var name: String {
        guard let dash = id.firstIndex(of: "-") else { return id }
        return String(id[id.index(after: dash)...])
    }
}

public struct CatalogLook: Equatable {
    public var id: String
    public var board: String
    /// A look may combine classes: plain, costume, held, under-feet, torso-overlay, body-color.
    public var classes: Set<String>
    public var weight: Double
    public var signature: [String]
    public var phase: Int
    public init(id: String, board: String = "", classes: Set<String> = ["plain"], weight: Double = 1,
                signature: [String] = [], phase: Int = 1) {
        self.id = id; self.board = board; self.classes = classes; self.weight = weight
        self.signature = signature; self.phase = phase
    }
    /// An under-feet look (the skateboard) glides in the rest pose instead of stepping (spec 3.3).
    public var glides: Bool { classes.contains("under-feet") }
    public var name: String {
        guard let dash = id.firstIndex(of: "-") else { return id }
        return String(id[id.index(after: dash)...])
    }
}

/// The scheduler's view of `art/clawd-atlas.json` schema 2: `motions` and `looks`. The v1 keys (poses, palette) are not read here.
/// A malformed entry is skipped and named in `issues`; it never takes the other entries down with it.
public struct PetCatalog: Equatable {
    public static let plainLook = "plain"
    /// 1 pet unit = 4 pt at size 1 (atlas `unit`).
    public static let pointsPerUnit = 4.0
    public static let canvasUnits = 12.0

    public private(set) var motions: [CatalogMotion]
    public private(set) var looks: [CatalogLook]
    public private(set) var issues: [String]

    public init(motions: [CatalogMotion] = [], looks: [CatalogLook] = [], issues: [String] = []) {
        var seen = Set<String>()
        self.motions = motions.filter { seen.insert($0.id).inserted }
        var seenLooks = Set<String>()
        var ordered = looks.filter { seenLooks.insert($0.id).inserted }
        if !seenLooks.contains(Self.plainLook) { ordered.insert(CatalogLook(id: Self.plainLook, board: "B1"), at: 0) }
        self.looks = ordered
        self.issues = issues
    }

    /// The same catalog with one motion's playing time replaced (a walk that plays only its stepping frames), and the lead-in a leg plays before it.
    public func replacingDuration(of id: String, with duration: TimeInterval, leadIn: TimeInterval = 0) -> PetCatalog {
        PetCatalog(motions: motions.map { var m = $0; if m.id == id { m.duration = duration; m.leadIn = leadIn }; return m }, looks: looks, issues: issues)
    }

    public func motion(id: String) -> CatalogMotion? { motions.first { $0.id == id } }
    public func look(id: String) -> CatalogLook? { looks.first { $0.id == id } }

    /// K1: the pair is listed. A missing `compatibleLooks` key means plain only.
    public func isCompatible(_ motion: CatalogMotion, with look: String) -> Bool {
        (motion.compatibleLooks ?? [Self.plainLook]).contains(look)
    }

    /// How many idle motions the look can wear (spec 3.1 K1: at least 6, else the look is not in rotation).
    public func compatibleIdleCount(look: String) -> Int {
        motions.reduce(0) { count, m in
            let idle = m.uses.contains(.idle) || m.uses.contains(.signature(look))
            return count + (idle && isCompatible(m, with: look) ? 1 : 0)
        }
    }

    // MARK: reading schema 2

    public init(atlasData: Data) {
        var motions: [CatalogMotion] = [], looks: [CatalogLook] = [], issues: [String] = []
        guard let root = (try? JSONSerialization.jsonObject(with: atlasData)) as? [String: Any] else {
            self.init(motions: [], looks: [], issues: ["atlas is not a JSON object"]); return
        }
        if let list = root["motions"] as? [Any] {
            for (index, raw) in list.enumerated() {
                switch Self.readMotion(raw) {
                case .success(let motion): motions.append(motion)
                case .failure(let problem): issues.append("motions[\(index)]: \(problem.text)")
                }
            }
        }
        if let list = root["looks"] as? [Any] {
            for (index, raw) in list.enumerated() {
                switch Self.readLook(raw) {
                case .success(let look): looks.append(look)
                case .failure(let problem): issues.append("looks[\(index)]: \(problem.text)")
                }
            }
        }
        // The in-between pictures of the art (`bridges`) play before and after a motion's own frames, so they are part of its playing time and its
        // frame count. A pose's bridge (the drag, the sent scene) is no catalog motion and adds nothing here.
        var extra: [String: (frames: Int, seconds: TimeInterval)] = [:]
        for case let bridge as [String: Any] in root["bridges"] as? [Any] ?? [] {
            guard let target = bridge["target"] as? [String: Any], target["kind"] as? String == "motion", let id = target["id"] as? String,
                  let list = bridge["ms"] as? [Any] else { continue }
            let values = list.compactMap { Self.number($0) }
            guard !values.isEmpty, values.count == list.count, values.allSatisfy({ $0 > 0 }) else {
                issues.append("bridges: \(bridge["id"] as? String ?? id) holds a bad ms value"); continue
            }
            let soFar = extra[id] ?? (0, 0)
            extra[id] = (soFar.frames + values.count, soFar.seconds + values.reduce(0, +) / 1000)
        }
        for index in motions.indices { if let more = extra[motions[index].id] {
            motions[index].frameCount += more.frames; motions[index].duration += more.seconds
        } }
        self.init(motions: motions, looks: looks, issues: issues)
    }

    struct ReadProblem: Error { let text: String }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func flag(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private static func readStage(_ value: Any?) -> StageExtent {
        if let dict = value as? [String: Any] {
            return StageExtent(left: max(0, number(dict["left"]) ?? 0), right: max(0, number(dict["right"]) ?? 0),
                               up: max(0, number(dict["up"]) ?? 0), down: max(0, number(dict["down"]) ?? 0))
        }
        if let list = value as? [Any], list.count == 4 {
            let n = list.map { max(0, number($0) ?? 0) }
            return StageExtent(left: n[0], right: n[1], up: n[2], down: n[3])
        }
        return .none
    }

    static func readMotion(_ raw: Any) -> Result<CatalogMotion, ReadProblem> {
        guard let d = raw as? [String: Any] else { return .failure(ReadProblem(text: "not an object")) }
        guard let id = d["id"] as? String, !id.isEmpty else { return .failure(ReadProblem(text: "no id")) }
        guard let usesRaw = d["uses"] as? [Any] else { return .failure(ReadProblem(text: "\(id): no uses list")) }
        let uses = Set(usesRaw.compactMap { ($0 as? String).map(MotionUse.init) })
        var frameCount = 0
        if let frames = d["frames"] as? [Any] { frameCount = frames.count }
        else if let count = number(d["frames"]) { frameCount = max(0, Int(count)) }
        var duration = 0.0
        if let list = d["ms"] as? [Any] {
            let values = list.compactMap { number($0) }
            guard values.count == list.count, values.allSatisfy({ $0 > 0 }) else {
                return .failure(ReadProblem(text: "\(id): ms holds a bad value"))
            }
            duration = values.reduce(0, +) / 1000
            if frameCount == 0 { frameCount = values.count }
        } else if let each = number(d["ms"]), each > 0, frameCount > 0 {
            duration = each * Double(frameCount) / 1000
        }
        guard duration > 0 else { return .failure(ReadProblem(text: "\(id): no playing time")) }
        let weight = number(d["weight"]) ?? 1
        guard weight > 0 else { return .failure(ReadProblem(text: "\(id): weight must be positive")) }
        let hold: Bool
        if let h = flag(d["hold"]) { hold = h } else { hold = d["hold"] != nil && !(d["hold"] is NSNull) }
        var compatible: Set<String>?
        if let list = d["compatibleLooks"] as? [Any] { compatible = Set(list.compactMap { $0 as? String }) }
        var stride = number(d["strideUnits"])
        if let s = stride, s <= 0 { stride = nil }
        return .success(CatalogMotion(
            id: id, board: d["board"] as? String ?? "", kind: d["kind"] as? String ?? "unknown", uses: uses,
            frameCount: frameCount, duration: duration, stage: readStage(d["stage"]),
            overheadClear: flag(d["overheadClear"]) ?? false, weight: weight, phase: Int(number(d["phase"]) ?? 1),
            compatibleLooks: compatible, strideUnits: stride, holdsLastFrame: hold,
            mirrorOf: (d["mirrorOf"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
    }

    static func readLook(_ raw: Any) -> Result<CatalogLook, ReadProblem> {
        guard let d = raw as? [String: Any] else { return .failure(ReadProblem(text: "not an object")) }
        guard let id = d["id"] as? String, !id.isEmpty else { return .failure(ReadProblem(text: "no id")) }
        var classes = Set<String>()
        if let one = d["class"] as? String { classes.insert(one) }
        if let many = d["class"] as? [Any] { classes.formUnion(many.compactMap { $0 as? String }) }
        if classes.isEmpty { classes = ["plain"] }
        let weight = number(d["weight"]) ?? 1
        guard weight > 0 else { return .failure(ReadProblem(text: "\(id): weight must be positive")) }
        let signature = (d["signature"] as? [Any])?.compactMap { $0 as? String } ?? []
        return .success(CatalogLook(id: id, board: d["board"] as? String ?? "", classes: classes, weight: weight,
                                    signature: signature, phase: Int(number(d["phase"]) ?? 1)))
    }
}
