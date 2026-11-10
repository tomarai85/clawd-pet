import Foundation

/// `state.json`: v1's saved position (Clawd's home) plus the look state that survives restarts (Interface Contract). The position
/// keys are v1's, unchanged, so a reader of `SavedPosition` still decodes this file; the look keys are optional so a v1 file decodes.
/// A build that does not know a key ignores it on read and drops it on its next write (the rollback exception, amendment D-2).
public struct AgentState: Codable, Equatable {
    public var displayUUID: String?
    public var xFrac: Double
    public var feetFrac: Double
    public var scale: Double
    public var look: String?
    /// Epoch seconds of the last look change.
    public var lookSince: Double?
    public var recentLooks: [String]?
    public var lastBubbleStyle: Int?
    /// `helmet off` was applied while the helmet was worn and the one-shot switch back to plain has not happened yet. It lives here, not
    /// only in memory, so a restart in between still takes the helmet off. Written only while it is true.
    public var helmetOffPending: Bool?
    /// The shuffle bag of the rotation: the looks worn or picked in the current cycle (amendment D-2).
    public var lookUsed: [String]?
    /// The factor, drawn once per interval, that the look-every setting is multiplied by (amendment D-3), and the absolute due time of the
    /// next rotation change in epoch seconds (`lookSince` plus the setting times the factor).
    public var lookDueFactor: Double?
    public var lookDueAt: Double?
    /// The variety factor of the worn look and the idle family bag (amendment variety D-2, D-4). An older build ignores these keys.
    public var lookVarietyFactor: Double?
    public var idleBagLook: String?
    public var idleFamiliesUsed: [String]?
    public var idleLastFamily: String?
    public var idleLastMembers: [String: String]?
    /// A LockDown Browser application was seen and the stand-down has not ended (amendment D-4), and the wall time the 120 s after the last
    /// one quit end. Written only while they hold.
    public var examActive: Bool?
    public var examGraceUntil: Double?
    /// Epoch seconds when the Aqua diagnostics window ends (`aqua-diag.log`, amendment D-5); written once, at the first start of a build that has them.
    public var aquaDiagUntil: Double?

    private enum CodingKeys: String, CodingKey {
        case displayUUID, xFrac, feetFrac, scale, look, lookSince, recentLooks, lastBubbleStyle, helmetOffPending
        case lookUsed, lookDueFactor, lookDueAt, examActive, examGraceUntil, aquaDiagUntil
        case lookVarietyFactor, idleBagLook, idleFamiliesUsed, idleLastFamily, idleLastMembers
    }

    public init(position: SavedPosition, look: String? = nil, lookSince: Double? = nil, recentLooks: [String]? = nil,
                lastBubbleStyle: Int? = nil, helmetOffPending: Bool? = nil, lookUsed: [String]? = nil, lookDueFactor: Double? = nil,
                lookDueAt: Double? = nil, examActive: Bool? = nil, examGraceUntil: Double? = nil, aquaDiagUntil: Double? = nil,
                lookVarietyFactor: Double? = nil, idleBagLook: String? = nil, idleFamiliesUsed: [String]? = nil, idleLastFamily: String? = nil,
                idleLastMembers: [String: String]? = nil) {
        displayUUID = position.displayUUID; xFrac = position.xFrac; feetFrac = position.feetFrac; scale = position.scale
        self.look = look; self.lookSince = lookSince; self.recentLooks = recentLooks; self.lastBubbleStyle = lastBubbleStyle
        self.helmetOffPending = helmetOffPending
        self.lookUsed = lookUsed; self.lookDueFactor = lookDueFactor; self.lookDueAt = lookDueAt
        self.examActive = examActive; self.examGraceUntil = examGraceUntil; self.aquaDiagUntil = aquaDiagUntil
        self.lookVarietyFactor = lookVarietyFactor; self.idleBagLook = idleBagLook
        self.idleFamiliesUsed = idleFamiliesUsed; self.idleLastFamily = idleLastFamily
        self.idleLastMembers = idleLastMembers
    }
    public init(position: SavedPosition, persisted: SchedulerPersisted, helmetOffPending: Bool = false, aquaDiagUntil: Double? = nil) {
        self.init(position: position, look: persisted.look, lookSince: persisted.lookSince, recentLooks: persisted.recentLooks,
                  lastBubbleStyle: persisted.lastBubbleStyle, helmetOffPending: helmetOffPending ? true : nil, lookUsed: persisted.lookUsed,
                  lookDueFactor: persisted.lookDueFactor, lookDueAt: persisted.lookDueAt,
                  examActive: persisted.examActive ? true : nil, examGraceUntil: persisted.examActive ? persisted.examGraceUntil : nil,
                  aquaDiagUntil: aquaDiagUntil,
                  lookVarietyFactor: persisted.lookVarietyFactor, idleBagLook: persisted.idleBagLook,
                  idleFamiliesUsed: persisted.idleBagLook == nil ? nil : persisted.idleFamiliesUsed, idleLastFamily: persisted.idleLastFamily,
                  idleLastMembers: persisted.idleBagLook == nil ? nil : persisted.idleLastMembers)
    }

    /// The v1 keys decode as before. The keys of the scheduler feel amendment are read one by one and leniently: a wrong type in one of them
    /// (a number in `lookUsed`, a string for the factor) loses that key alone, never the position or the look.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayUUID = try c.decodeIfPresent(String.self, forKey: .displayUUID)
        xFrac = try c.decode(Double.self, forKey: .xFrac)
        feetFrac = try c.decode(Double.self, forKey: .feetFrac)
        scale = try c.decode(Double.self, forKey: .scale)
        look = try c.decodeIfPresent(String.self, forKey: .look)
        lookSince = try c.decodeIfPresent(Double.self, forKey: .lookSince)
        recentLooks = try c.decodeIfPresent([String].self, forKey: .recentLooks)
        lastBubbleStyle = try c.decodeIfPresent(Int.self, forKey: .lastBubbleStyle)
        helmetOffPending = try c.decodeIfPresent(Bool.self, forKey: .helmetOffPending)
        lookUsed = (try? c.decodeIfPresent([LenientString].self, forKey: .lookUsed)).map { $0.compactMap(\.value) }
        lookDueFactor = (try? c.decodeIfPresent(Double.self, forKey: .lookDueFactor)) ?? nil
        lookDueAt = (try? c.decodeIfPresent(Double.self, forKey: .lookDueAt)) ?? nil
        examActive = (try? c.decodeIfPresent(Bool.self, forKey: .examActive)) ?? nil
        examGraceUntil = (try? c.decodeIfPresent(Double.self, forKey: .examGraceUntil)) ?? nil
        aquaDiagUntil = (try? c.decodeIfPresent(Double.self, forKey: .aquaDiagUntil)) ?? nil
        lookVarietyFactor = (try? c.decodeIfPresent(Double.self, forKey: .lookVarietyFactor)) ?? nil
        idleBagLook = (try? c.decodeIfPresent(String.self, forKey: .idleBagLook)) ?? nil
        idleFamiliesUsed = (try? c.decodeIfPresent([LenientString].self, forKey: .idleFamiliesUsed)).map { $0.compactMap(\.value) }
        idleLastFamily = (try? c.decodeIfPresent(String.self, forKey: .idleLastFamily)) ?? nil
        idleLastMembers = (try? c.decodeIfPresent([String: LenientString].self, forKey: .idleLastMembers)).map { $0.compactMapValues(\.value) }
    }
    private struct LenientString: Decodable {
        let value: String?
        init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(String.self) }
    }

    public var position: SavedPosition { SavedPosition(displayUUID: displayUUID, xFrac: xFrac, feetFrac: feetFrac, scale: scale) }

    /// Validates the worn look, clock, bag and factor independently. A missing look falls back to plain without losing the cycle.
    /// `lookEveryHours` is the setting in effect (the absolute due time is rebuilt from it, so a setting changed while the agent was down
    /// counts); `draw` (uniform in 0..<1) is the production random source: a missing, non-finite or out-of-band factor is drawn once here and
    /// the host writes the state at once. Without `draw` such a factor is 1.0.
    public func persisted(catalog: PetCatalog, nowEpoch: Double, lookEveryHours: Int? = nil, draw: (() -> Double)? = nil) -> SchedulerPersisted {
        let style = lastBubbleStyle.flatMap { SchedulerSettings.bubbleStyles.contains($0) ? $0 : nil }
        func drawn() -> Double { draw.map { PetScheduler.lookFactor(unit: $0()) } ?? 1.0 }
        let worn = look.flatMap { catalog.look(id: $0) != nil ? $0 : nil } ?? PetCatalog.plainLook
        // The same backward-jump rule as rebaseLookClock(): move the clock once, retaining the interval's factor.
        let since = lookSince.flatMap {
            $0.isFinite && $0 > 0 && $0 <= nowEpoch + PetScheduler.lookClockTolerance ? $0 : nil
        } ?? nowEpoch
        let recent = (recentLooks ?? []).filter { catalog.look(id: $0) != nil }
        // Only non-strings (not decodable) and duplicates are dropped: ids that left the rotation or the catalog stay until the next rollover.
        var seen = Set<String>()
        let used = (lookUsed ?? []).filter { seen.insert($0).inserted }
        let factor = PetScheduler.validLookFactor(lookDueFactor) ?? drawn()
        let variety = PetScheduler.validVarietyFactor(lookVarietyFactor) ?? PetScheduler.varietyFactor(look: worn, catalog: catalog)
        func due(_ since: Double) -> Double? { lookEveryHours.map { since + PetScheduler.lookDueSeconds(hours: $0, jitter: factor, variety: variety) } }
        // The bag belongs to the look it was written for: any other look starts with an empty one (a state of an older build has none).
        let bagKept = idleBagLook == worn
        var seenFamilies = Set<String>()
        let families = bagKept ? (idleFamiliesUsed ?? []).filter { seenFamilies.insert($0).inserted } : []
        let lastMembers = bagKept ? (idleLastMembers ?? [:]).filter { !$0.key.isEmpty && PetScheduler.family(ofID: $0.value) == $0.key } : [:]
        return SchedulerPersisted(look: worn, lookSince: since, recentLooks: recent, lastBubbleStyle: style, lookUsed: used,
                                  lookDueFactor: factor, lookDueAt: due(since),
                                  examActive: examActive == true, examGraceUntil: examGraceUntil.flatMap { $0.isFinite ? $0 : nil },
                                  lookVarietyFactor: variety, idleBagLook: bagKept ? worn : nil, idleFamiliesUsed: families,
                                  idleLastFamily: bagKept ? idleLastFamily : nil, idleLastMembers: lastMembers)
    }
}
