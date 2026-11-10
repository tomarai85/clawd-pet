import Foundation
import CoreGraphics

// Eligibility, weighted choice and the look rotation (spec 6.2, 6.5).
extension PetScheduler {
    // MARK: motions

    /// A motion may play now: not excluded, compatible with the look (K1), its whole stage inside the visible frame at Clawd's
    /// place, and, for idle motions, the pointer outside that stage.
    func eligible(_ m: CatalogMotion, look: String, pointerCheck: Bool) -> Bool {
        if guards.contains(.exclusion), settings.excludes(m) { return false }
        if guards.contains(.compatibility), !catalog.isCompatible(m, with: look) { return false }
        let rect = geometry.stageRect(m.stage, originX: Double(geometry.homeOrigin.x))
        // Clawd dropped over the Dock plays in place: his stage is checked against the drag area, not the visible frame.
        let area = geometry.visibleFrame.contains(geometry.canvasRect(originX: Double(geometry.homeOrigin.x))) ? geometry.visibleFrame : geometry.dragArea
        if guards.contains(.stageFits), !area.contains(rect) { return false }
        if pointerCheck, guards.contains(.pointerOutside), let p = pointer, rect.contains(p) { return false }
        return true
    }

    /// The motion the next automatic idle pick would play (the bag is read, not changed: `planIdleMotion`).
    func pickIdleMotion() -> CatalogMotion? { planIdleMotion()?.motion }

    /// A uniform pick from the motions of one use, never the one this pool played last.
    func pickFromPool(_ use: MotionUse, key: String, pointerCheck: Bool) -> CatalogMotion? {
        let look = lookForMotion
        var pool = catalog.motions.filter { $0.uses.contains(use) && eligible($0, look: look, pointerCheck: pointerCheck) }
        guard !pool.isEmpty else { return nil }
        if guards.contains(.noRepeatMotion), pool.count >= 2, let last = poolHistory[key] { pool.removeAll { $0.id == last } }
        let pick = pool[min(pool.count - 1, Int(random() * Double(pool.count)))]
        poolHistory[key] = pick.id
        return pick
    }

    func pickEntry(_ use: MotionUse) -> CatalogMotion? {
        let look = lookForMotion
        return catalog.motions.first { $0.uses.contains(use) && eligible($0, look: look, pointerCheck: false) }
    }

    // MARK: looks

    func isWearable(_ id: String) -> Bool {
        guard let look = catalog.look(id: id) else { return false }
        if id == PetCatalog.plainLook { return true }
        return !(guards.contains(.exclusion) && settings.excludes(look))
    }

    /// The looks in rotation: wearable and with at least 6 compatible idle motions (spec 3.1 K1).
    func rebuildRotation() {
        rotationLooks = catalog.looks.filter { isWearable($0.id) && catalog.compatibleIdleCount(look: $0.id) >= Self.minimumLookMotions }
    }

    var pinnedLook: String? {
        guard guards.contains(.settingLookPin), let pin = settings.lookPin, isWearable(pin) else { return nil }
        return pin
    }

    /// The shuffle bag (amendment D-2): the looks in rotation, never the worn one (`.noRepeatLook`), never one worn or picked in the current
    /// cycle (`.lookBag`; the worn look is in the bag too, and its exclusion is the other guard's, so each has its own control). A pure read.
    func lookCandidates() -> [CatalogLook] {
        var pool = rotationLooks
        if guards.contains(.noRepeatLook) { pool = pool.filter { $0.id != persisted.look } }
        if guards.contains(.lookBag) { pool = pool.filter { $0.id == persisted.look || !persisted.lookUsed.contains($0.id) } }
        return pool
    }

    /// The cycle ends when every look in rotation is in the bag: it starts again with the worn look alone. Done where a look is worn and
    /// where the rotation changes, never in a read. True when the bag changed.
    @discardableResult
    func rollOverLookBag() -> Bool {
        guard guards.contains(.lookBag), !rotationLooks.isEmpty, rotationLooks.allSatisfy({ persisted.lookUsed.contains($0.id) }),
              persisted.lookUsed != [persisted.look] else { return false }
        persisted.lookUsed = [persisted.look]
        return true
    }

    /// The worn look is always in the bag (a state file of an older build has none), then the rollover check. True when anything changed.
    @discardableResult
    func reconcileLookBag() -> Bool {
        guard guards.contains(.lookBag) else { return false }
        var changed = false
        if !persisted.lookUsed.contains(persisted.look) { persisted.lookUsed.append(persisted.look); changed = true }
        return rollOverLookBag() || changed
    }

    var lookHasCandidate: Bool { !lookCandidates().isEmpty }

    func pickLook() -> String? {
        let pool = lookCandidates()
        guard let index = WeightedChoice.index(weights: pool.map(\.weight), unit: random()) else { return nil }
        return pool[index].id
    }

    // MARK: the interval between look changes (amendment D-3)

    /// A factor in the band for a uniform unit in 0..<1.
    public static func lookFactor(unit: Double) -> Double { lookJitterLow + (lookJitterHigh - lookJitterLow) * min(max(unit, 0), 1) }
    /// The factor when it is finite and inside the band, nil otherwise (a file of an older build has none).
    public static func validLookFactor(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= lookJitterLow - 1e-9, value <= lookJitterHigh + 1e-9 else { return nil }
        return value
    }
    /// A new factor for a new interval (1.0 with `.lookJitter` off). The one place the draw is made.
    func drawLookFactor() -> Double { guards.contains(.lookJitter) ? Self.lookFactor(unit: random()) : 1.0 }
    /// Called wherever `lookSince` is set: a new factor and the absolute due time it gives.
    func renewLookDue() {
        persisted.lookDueFactor = drawLookFactor()
        persisted.lookVarietyFactor = varietyFactorNow(look: persisted.look)
        persisted.lookDueAt = persisted.lookSince + lookDueSpan
    }
    /// When the next rotation change is due, in wall epoch seconds: the stored absolute time, or (a file of an older build) the last change
    /// plus the setting times the factors (`lookDueSpan`). The one formula behind `lookDueMono()` and `nextLookChange`.
    func lookDueWall() -> Double { persisted.lookDueAt ?? (persisted.lookSince + lookDueSpan) }
    /// A wall clock set back by more than a minute behind the last change moves the look clock once, to now, keeping the factor. After it
    /// `lookSince` is not ahead of the clock, so nothing moves it again; a restart reads the rebased values.
    func rebaseLookClock() {
        guard guards.contains(.lookEveryN), wallEpoch < persisted.lookSince - Self.lookClockTolerance else { return }
        persisted.lookSince = wallEpoch
        persisted.lookDueAt = wallEpoch + lookDueSpan
        onPersist?(persisted)
    }

    /// The monotonic time a look change is wanted: -infinity when it is wanted already (a pin that is not worn yet, a worn look that
    /// was switched off), the due time of the rotation otherwise, nil when no change is wanted.
    func lookDueMono() -> TimeInterval? {
        if let pin = pinnedLook { return pin == persisted.look ? nil : -.infinity }
        if !isWearable(persisted.look) { return lookHasCandidate ? -.infinity : nil }
        guard lookHasCandidate else { return nil }
        if !guards.contains(.lookEveryN) { return -.infinity }
        return clock.now + (lookDueWall() - wallEpoch)
    }

    func lookIsDue(at t: TimeInterval) -> Bool { (lookDueMono() ?? .infinity) <= t }

    /// Awake, nothing hidden or quiet, and no scene, motion, walk, reaction or drag (spec 6.5), each rule on its own guard.
    var lookConditionsHold: Bool {
        if guards.contains(.lookNeedsVisible), visibility != .visible { return false }
        if guards.contains(.lookNeedsAwake), asleep { return false }
        if guards.contains(.lookNeedsRest), !(!sceneActive && !dragging && !heldByMenu && pendingWalk == nil && (activityIsRest || asleep)) { return false }
        return true
    }

    /// When the change can start: due, at rest, and, for the rotation's own changes, at least 30 s after the last motion Clawd started by
    /// itself ended. A look the user picked (a pin not worn yet) does not wait for that gap: a pick waited up to 31 s for it (2026-10-27).
    /// The idle wait is restarted when the transition is over, which pushes the next motion at least 30 s behind it.
    func lookChangeDeadline() -> TimeInterval? {
        guard guards.contains(.lookOwnDeadline), lookConditionsHold, let due = lookDueMono() else { return nil }
        var at = max(due, restSince)
        let picked = pinnedLook.map { $0 != persisted.look } ?? false
        if guards.contains(.lookGap30), !picked, let end = lastSelfEnd { at = max(at, end + Self.lookGap) }
        return max(at, lookBackoffUntil)
    }

    @discardableResult
    func startLookChange(at t: TimeInterval) -> Bool {
        let to: String
        if let pin = pinnedLook, pin != persisted.look { to = pin }
        else if let picked = pickLook() { to = picked }
        else { lookBackoffUntil = t + 60; return false }
        nextIdleAt = nil
        if reduceMotion && guards.contains(.reduceMotion) {
            commitLook(to, at: t)      // Reduce Motion: the look changes as a cut
            dirty = true
            return true
        }
        if case .run(let r) = activity { endRunNow(r, at: t) }
        activity = .transition(Transition(from: persisted.look, to: to, start: t, swapAt: t + Self.transitionSink,
                                          end: t + Self.transitionDuration, committed: false))
        lastTransitionEnd = t + Self.transitionDuration
        lookBackoffUntil = t + Self.transitionDuration      // the same change never starts twice
        lastActivityStart = t
        emit(.lookTransition(from: persisted.look, to: to), at: t)
        dirty = true
        return true
    }

    func commitLook(_ to: String, at t: TimeInterval) {
        let from = persisted.look
        persisted.recentLooks = Array(([from] + persisted.recentLooks).prefix(3))
        persisted.look = to
        persisted.lookSince = wall(at: t)
        renewLookDue()
        if from != to { clearIdleBag(for: to) }
        if guards.contains(.lookBag), !persisted.lookUsed.contains(to) { persisted.lookUsed.append(to) }
        rollOverLookBag()
        counters.lookChanges += 1
        emit(.lookChange(from: from, to: to), at: t)
        onPersist?(persisted)
    }

    func swapTransition(at t: TimeInterval) {
        guard case .transition(var tr) = activity, !tr.committed else { return }
        commitLook(tr.to, at: t)
        tr.committed = true
        activity = .transition(tr)
        dirty = true
    }

    func endTransition(at t: TimeInterval) {
        guard case .transition = activity else { return }
        endTransitionNow(at: t)
        syncRest(at: t)
    }

    func endTransitionNow(at t: TimeInterval) {
        activity = .rest
        lastTransitionEnd = min(lastTransitionEnd ?? t, t)
        emit(.lookTransitionEnd, at: t)
        dirty = true
    }

    /// A transition cut before its swap leaves the old look worn; the change is tried again later.
    func abortTransition(_ tr: Transition, at t: TimeInterval) {
        endTransitionNow(at: t)
    }
}
