import Foundation

// Variety (amendment "variety"): idle motions play by family in a per-look bag, and a look that offers few families is due sooner.

/// One automatic idle choice: the motion, its family, and whether the choice starts a new cycle (the bag is cleared when the motion starts).
struct IdlePick {
    var motion: CatalogMotion
    var family: String
    var startsNewCycle: Bool
}

extension PetCatalog {
    /// The idle pool of a look as the picker builds it, before exclusions and stage fit (D-1).
    func idlePool(look: String) -> [CatalogMotion] {
        let signature = self.look(id: look)?.signature ?? []
        return motions.filter { m in
            (m.uses.contains(.idle) || m.uses.contains(.signature(look)) || signature.contains(m.id)) && !m.uses.contains(.ride) && isCompatible(m, with: look)
        }
    }

    /// The families a look offers (D-1).
    func idleFamilies(look: String) -> Set<String> { Set(idlePool(look: look).map { PetScheduler.family(of: $0) }) }
}

extension PetScheduler {
    /// A motion's family: its id up to the first "-" (B3-glance-left is B3). Computed, never stored (D-1).
    static func family(of motion: CatalogMotion) -> String { family(ofID: motion.id) }
    static func family(ofID id: String) -> String { String(id.prefix { $0 != "-" }) }

    static let varietyFloor = 1.0 / 3.0
    /// The family threshold: the families of plain (the largest set when a catalog has no plain look); 0 when the catalog has no idle family.
    static func varietyThreshold(catalog: PetCatalog) -> Int {
        if catalog.look(id: PetCatalog.plainLook) != nil { return catalog.idleFamilies(look: PetCatalog.plainLook).count }
        return catalog.looks.map { catalog.idleFamilies(look: $0.id).count }.max() ?? 0
    }
    /// `min(1, max(1/3, families(look) / families(plain)))` (D-4).
    static func varietyFactor(look: String, catalog: PetCatalog) -> Double {
        let threshold = varietyThreshold(catalog: catalog)
        guard threshold > 0 else { return 1 }
        return min(1, max(varietyFloor, Double(catalog.idleFamilies(look: look).count) / Double(threshold)))
    }
    /// The factor when it is finite and inside 1/3...1, nil otherwise (a file of an older build has none).
    static func validVarietyFactor(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= varietyFloor - 1e-9, value <= 1 + 1e-9 else { return nil }
        return value
    }

    /// The factor for `look` worn now: 1 while the setting pins it (a pin is never shortened), the look's own factor otherwise.
    func varietyFactorNow(look: String) -> Double {
        if let pin = pinnedLook, pin == look { return 1 }
        return Self.varietyFactor(look: look, catalog: catalog)
    }

    // MARK: the idle family bag (D-2, D-3)

    /// A family's weight: the sum of its eligible members' base weights (0.5 for items over 8 s), capped at 3; the worn look's signature
    /// family has it multiplied by 3 in the first draw of a cycle only (D-3).
    func familyWeight(_ family: String, members: [CatalogMotion], look: String, firstDraw: Bool) -> Double {
        let base = min(3, members.reduce(0) { $0 + ($1.duration > 8 ? min($1.weight, 0.5) : $1.weight) })
        let signature = catalog.look(id: look)?.signature ?? []
        let isSignature = members.contains { $0.uses.contains(.signature(look)) || signature.contains($0.id) }
        return firstDraw && isSignature ? base * 3 : base
    }

    /// Chooses the next automatic idle motion and changes nothing: the bag is committed by `commitIdlePick` when the motion starts (D-2a).
    func planIdleMotion() -> IdlePick? {
        let look = lookForMotion
        let pool = catalog.idlePool(look: look).filter { eligible($0, look: look, pointerCheck: true) }
        guard !pool.isEmpty else { return nil }
        guard guards.contains(.idleBag) else { return planLegacyIdleMotion(pool, look: look) }
        var groups: [String: [CatalogMotion]] = [:]
        for m in pool { groups[Self.family(of: m), default: []].append(m) }
        let families = groups.keys.sorted()
        let bagIsOurs = persisted.idleBagLook == look
        var used = Set(bagIsOurs ? persisted.idleFamiliesUsed : [])
        let last = bagIsOurs ? persisted.idleLastFamily : nil
        var candidates = families.filter { !used.contains($0) }
        var newCycle = false
        if candidates.isEmpty {
            newCycle = true
            used = []
            candidates = families.filter { $0 != last }
            if candidates.isEmpty { candidates = families }      // the only family in the pool plays again
        }
        let weights = candidates.map { familyWeight($0, members: groups[$0] ?? [], look: look, firstDraw: used.isEmpty) }
        onIdleFamilyWeights?(candidates, weights)
        guard let fi = WeightedChoice.index(weights: weights, unit: random()) else { return nil }
        let family = candidates[fi]
        var members = groups[family] ?? []
        if guards.contains(.noRepeatMotion), bagIsOurs, members.count >= 2, let lastMember = persisted.idleLastMembers[family] {
            members.removeAll { $0.id == lastMember }
        }
        let motion = members[min(members.count - 1, Int(random() * Double(members.count)))]
        return IdlePick(motion: motion, family: family, startsNewCycle: newCycle)
    }

    /// The picker before the bag: never one of the last three played (one when fewer than 5 are eligible), weighted by the motion's weight
    /// (0.5 for items over 8 s, x3 for the worn look's signature). Kept behind `.idleBag` so the six-hour measurement can print today's shares.
    private func planLegacyIdleMotion(_ eligiblePool: [CatalogMotion], look: String) -> IdlePick? {
        var pool = eligiblePool
        if guards.contains(.noRepeatMotion) {
            let recent = pool.count >= 5 ? Array(idleHistory.prefix(3)) : Array(idleHistory.prefix(1))
            pool.removeAll { recent.contains($0.id) }
        }
        let signature = catalog.look(id: look)?.signature ?? []
        let weights = pool.map { m -> Double in
            let weight = m.duration > 8 ? min(m.weight, 0.5) : m.weight
            return m.uses.contains(.signature(look)) || signature.contains(m.id) ? weight * 3 : weight
        }
        guard let index = WeightedChoice.index(weights: weights, unit: random()) else { return nil }
        return IdlePick(motion: pool[index], family: Self.family(of: pool[index]), startsNewCycle: false)
    }

    /// The motion starts: the family is used, its last member is kept, and the state is written in the same step (D-2a).
    func commitIdlePick(_ pick: IdlePick) {
        let look = lookForMotion
        guard guards.contains(.idleBag) else { return }
        if persisted.idleBagLook != look { clearIdleBag(for: look) }
        if pick.startsNewCycle { persisted.idleFamiliesUsed = [] }
        if !persisted.idleFamiliesUsed.contains(pick.family) { persisted.idleFamiliesUsed.append(pick.family) }
        persisted.idleLastFamily = pick.family
        persisted.idleBagLook = look
        persisted.idleLastMembers[pick.family] = pick.motion.id
        onPersist?(persisted)
    }

    /// The worn look changed: the bag starts empty (D-2b).
    func clearIdleBag(for look: String) {
        persisted.idleBagLook = look
        persisted.idleFamiliesUsed = []
        persisted.idleLastFamily = nil
        persisted.idleLastMembers = [:]
    }

    /// The worn look's factor again (a pin on the worn look, a catalog that changed its families); the due time follows, and the host persists.
    func refreshVarietyFactor() {
        let factor = varietyFactorNow(look: persisted.look)
        guard abs(factor - persisted.lookVarietyFactor) > 1e-12 else { return }
        persisted.lookVarietyFactor = factor
        if persisted.lookDueAt != nil { persisted.lookDueAt = persisted.lookSince + lookDueSpan }
        onPersist?(persisted)
    }

    /// The due interval of the current look in seconds: setting x jitter factor x variety factor (D-4). The one product.
    var lookDueSpan: Double { Self.lookDueSeconds(hours: settings.lookEveryHours, jitter: persisted.lookDueFactor, variety: persisted.lookVarietyFactor) }
    static func lookDueSeconds(hours: Int, jitter: Double, variety: Double) -> Double { Double(hours) * 3600 * jitter * variety }
}
