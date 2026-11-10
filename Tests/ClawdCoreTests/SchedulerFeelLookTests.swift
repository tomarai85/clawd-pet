import Testing
import Foundation
import CoreGraphics
@testable import ClawdCore

// Amendment "scheduler feel", D-2 (the shuffle bag over the rotation looks) and D-3 (the drawn interval between look changes).

enum LookFeel {
    /// The fixture motions, every look compatible with everything, and `count` looks l00, l01, ... (weight `weightOf` gives).
    static func catalog(looks count: Int, weightOf: (Int) -> Double = { _ in 1 }) -> PetCatalog {
        let base = SchedulerFixture.catalog()
        let ids = (0..<count).map { String(format: "l%02d", $0) }
        let motions = base.motions.map { m -> CatalogMotion in
            var copy = m; copy.compatibleLooks = Set(ids); return copy
        }
        let looks = ids.enumerated().map { CatalogLook(id: $0.element, board: "D\($0.offset)", classes: ["costume"], weight: weightOf($0.offset)) }
        return PetCatalog(motions: motions, looks: looks)
    }
    static func settings(hours: Int = 2, _ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
        var s = SchedulerSettings(); s.motion = .off; s.walk = false; s.lookEveryHours = hours; edit(&s); return s
    }
    /// A rig on a catalog of `count` looks wearing l00, with the persisted writes captured.
    static func rig(looks count: Int = 6, hours: Int = 2, seed: UInt64 = 1, weightOf: (Int) -> Double = { _ in 1 }, persisted: SchedulerPersisted? = nil,
                    settings edit: (inout SchedulerSettings) -> Void = { _ in }) -> (rig: SchedulerRig, writes: Writes) {
        let wall = 1_800_000_000.0
        let rig = SchedulerRig(catalog: catalog(looks: count, weightOf: weightOf), settings: settings(hours: hours, edit), seed: seed,
                               persisted: persisted ?? SchedulerPersisted(look: "l00", lookSince: wall), refresh: false)
        let writes = Writes()
        rig.scheduler.onPersist = { writes.all.append($0) }
        rig.scheduler.refresh()
        return (rig, writes)
    }
    final class Writes { var all: [SchedulerPersisted] = [] }
    /// The looks worn, in order, as the log tells them.
    static func worn(_ rig: SchedulerRig) -> [String] {
        rig.events.compactMap { if case .lookChange(_, let to) = $0.event { return to } else { return nil } }
    }
    /// Runs until `count` more automatic changes have been made (or `limit` seconds pass).
    static func changes(_ rig: SchedulerRig, _ count: Int, limit: TimeInterval = 3600 * 24 * 365 * 3) {
        let target = worn(rig).count + count
        _ = rig.run(upTo: limit) { worn(rig).count >= target }
    }
}

@Suite("Scheduler feel: the look bag", .serialized)
struct SchedulerFeelLookBag {
    /// Follows the bag from outside: every automatic change must be to a look not yet in `used`; the cycle restarts with the worn look when
    /// all `ids` are used. Returns the problems found.
    private func cycleProblems(_ worn: [String], start: String, ids: [String]) -> [String] {
        var used: Set<String> = [start], problems: [String] = []
        for (n, look) in worn.enumerated() {
            if used.contains(look) { problems.append("change \(n + 1) to \(look) repeats a look of the cycle") }
            used.insert(look)
            if used.count == ids.count { used = [look] }
        }
        return problems
    }

    @Test func LookBag_noLookRepeatsWithinACycle() {
        let (rig, _) = LookFeel.rig(looks: 15, hours: 2, seed: 11)
        LookFeel.changes(rig, 50 * 14)
        let worn = LookFeel.worn(rig)
        #expect(worn.count >= 50 * 14, "fifty cycles of fourteen changes were made")
        #expect(cycleProblems(worn, start: "l00", ids: (0..<15).map { String(format: "l%02d", $0) }).isEmpty)
    }

    @Test func LookBag_everyRotationLookIsWornOncePerCycle() {
        let (rig, writes) = LookFeel.rig(looks: 7, hours: 2, seed: 5)
        LookFeel.changes(rig, 7 * 14)
        // At each rollover the bag held every look of the rotation.
        let ids = Set((0..<7).map { String(format: "l%02d", $0) })
        var cycles = 0, previous: [String] = []
        for write in writes.all {
            if write.lookUsed == [write.look], previous.count > 1 {
                #expect(Set(previous).union([write.look]) == ids, "the cycle ended with every look worn once: \(previous) + \(write.look)")
                cycles += 1
            }
            previous = write.lookUsed
        }
        #expect(cycles >= 10, "\(cycles) cycles were completed")
    }

    @Test func LookBag_aMenuPickMarksItsLookUsed() {
        let (rig, _) = LookFeel.rig(looks: 6, seed: 3)
        rig.scheduler.update(settings: LookFeel.settings { $0.lookPin = "l04" })
        _ = rig.run(upTo: 60) { rig.scheduler.look == "l04" }
        #expect(rig.scheduler.look == "l04" && rig.scheduler.persisted.lookUsed.contains("l04"), "a pin is worn and marked: \(rig.scheduler.persisted.lookUsed)")
        rig.scheduler.update(settings: LookFeel.settings())
        LookFeel.changes(rig, 4)
        let worn = LookFeel.worn(rig)
        #expect(!worn.dropFirst().prefix(4).contains("l04"), "the picked look is not worn again by the next automatic changes: \(worn)")
    }

    @Test func LookPin_aMenuPickDoesNotWaitForTheGapAfterClawdsOwnMotion() {
        // 2026-10-27 09:21: a pick waited 9 s for the 30 s gap after Clawd's own foot tap (the rotation's rule), and it can wait 31 s.
        let (rig, _) = LookFeel.rig(looks: 6, seed: 3)
        rig.advance(60)
        rig.scheduler.lastSelfEnd = rig.now - 2           // Clawd's own motion ended 2 s ago
        let picked = rig.now
        rig.scheduler.update(settings: LookFeel.settings { $0.lookPin = "l04" })
        _ = rig.run(upTo: 60) { rig.scheduler.look == "l04" }
        let at = rig.events.first { if case .lookChange(_, "l04") = $0.event { return true } else { return false } }?.t
        #expect(rig.scheduler.look == "l04" && at != nil, "the picked look is worn")
        #expect((at ?? .infinity) - picked <= PetScheduler.transitionSink + 0.05, "it changes at once, not 28 s later: \(String(describing: at.map { $0 - picked }))")
        // The rotation's own change, due now, still waits for the gap.
        let (auto, _) = LookFeel.rig(looks: 6, hours: 2, seed: 3)
        auto.advance(60)
        auto.scheduler.persisted.lookDueAt = auto.scheduler.wallEpoch - 1
        auto.scheduler.lastSelfEnd = auto.now - 2
        let deadline = auto.scheduler.lookChangeDeadline()
        #expect(deadline.map { $0 >= auto.now + 27 && $0 <= auto.now + 29 } == true, "a due rotation change keeps the 30 s gap: \(String(describing: deadline.map { $0 - auto.now }))")
    }

    @Test func LookBag_aManualPickOfAUsedLookAlwaysApplies() {
        let (rig, _) = LookFeel.rig(looks: 8, seed: 9)
        LookFeel.changes(rig, 2)                                   // l00 -> A -> B, both marked
        let worn = LookFeel.worn(rig), a = worn[0]
        rig.scheduler.update(settings: LookFeel.settings { $0.lookPin = a })
        _ = rig.run(upTo: 120) { rig.scheduler.look == a }
        #expect(rig.scheduler.look == a, "a manual pick of a look worn this cycle is worn")
        #expect(rig.scheduler.persisted.lookUsed.contains(a) && rig.scheduler.persisted.lookUsed.contains(worn[1]))
        rig.scheduler.update(settings: LookFeel.settings())
        LookFeel.changes(rig, 1)
        let next = LookFeel.worn(rig).last
        #expect(next != a && next != worn[1] && next != "l00", "the next automatic pick excludes A, B and the first look: \(String(describing: next))")
    }

    @Test func LookBag_aPinnedLookThenLookRandomDoesNotRepeatIt() {
        let (rig, _) = LookFeel.rig(looks: 5, seed: 21)
        rig.scheduler.update(settings: LookFeel.settings { $0.lookPin = "l03" })
        _ = rig.run(upTo: 120) { rig.scheduler.look == "l03" }
        rig.scheduler.update(settings: LookFeel.settings())
        LookFeel.changes(rig, 3)
        #expect(!LookFeel.worn(rig).dropFirst().contains("l03"), "l03 is not worn again before the cycle ends: \(LookFeel.worn(rig))")
    }

    @Test func LookBag_theBoundaryNeverRepeatsTheWornLook() {
        let (rig, _) = LookFeel.rig(looks: 3, seed: 2)
        LookFeel.changes(rig, 60)
        let worn = ["l00"] + LookFeel.worn(rig)
        for pair in zip(worn, worn.dropFirst()) { #expect(pair.0 != pair.1, "\(pair.0) was worn twice in a row") }
    }

    @Test func LookBag_severalCompleteCyclesThroughRealSchedulerDeadlines() {
        let (rig, writes) = LookFeel.rig(looks: 4, seed: 8)
        var problems: [String] = []
        let target = 4 * 3 + 1
        var guardSteps = 0
        while LookFeel.worn(rig).count < target, guardSteps < 100_000, !rig.runaway {
            guardSteps += 1
            if rig.scheduler.lookCandidates().isEmpty { problems.append("no candidate with 4 looks in rotation at change \(LookFeel.worn(rig).count)") }
            if rig.scheduler.lookDueMono() == nil { problems.append("lookDueMono() is nil at change \(LookFeel.worn(rig).count)") }
            let before = rig.scheduler.persisted
            _ = rig.scheduler.nextLookChange; _ = rig.scheduler.lookCandidates(); _ = rig.scheduler.lookDueMono()
            if rig.scheduler.persisted != before { problems.append("a read changed the persisted state") }
            let count = LookFeel.worn(rig).count
            _ = rig.run(upTo: 3600 * 8) { LookFeel.worn(rig).count > count }
        }
        #expect(problems.isEmpty, "\(problems.prefix(5))")
        #expect(LookFeel.worn(rig).count >= target)
        // The reset is in the same persisted write as the commit that completed the cycle.
        let ids = Set((0..<4).map { String(format: "l%02d", $0) })
        for (n, write) in writes.all.enumerated() where write.lookUsed == [write.look] && n > 0 && writes.all[n - 1].look != write.look {
            #expect(Set(writes.all[n - 1].lookUsed).union([write.look]) == ids, "the write that rolls over is the commit that completed the cycle")
        }
        #expect(writes.all.contains { $0.lookUsed.count == 1 })
    }

    @Test func LookBag_weightHalfLooksComeLaterOnAverage() {
        // l00 is worn at the start; the odd looks weigh 0.5. Mean position in the cycle (1 = first pick after the reset).
        let (rig, _) = LookFeel.rig(looks: 11, seed: 4, weightOf: { $0 % 2 == 1 ? 0.5 : 1 })
        LookFeel.changes(rig, 10 * 150)
        let worn = LookFeel.worn(rig)
        var light: [Double] = [], heavy: [Double] = []
        for (n, look) in worn.enumerated() {
            let position = Double(n % 10 + 1)
            if Int(look.dropFirst())! % 2 == 1 { light.append(position) } else { heavy.append(position) }
        }
        let lightMean = light.reduce(0, +) / Double(light.count), heavyMean = heavy.reduce(0, +) / Double(heavy.count)
        #expect(lightMean - heavyMean > 0.6, "half-weight looks come later: mean position \(lightMean) against \(heavyMean)")
    }

    @Test func LookBag_aRestartKeepsTheBag() throws {
        let (rig, writes) = LookFeel.rig(looks: 8, seed: 6)
        LookFeel.changes(rig, 3)
        let last = try #require(writes.all.last)
        #expect(last.lookUsed.count == 4, "the first look and three changes: \(last.lookUsed)")
        let state = AgentState(position: SavedPosition(), persisted: last)
        let data = try JSONEncoder().encode(state)
        let loaded = try JSONDecoder().decode(AgentState.self, from: data).persisted(catalog: LookFeel.catalog(looks: 8), nowEpoch: last.lookSince + 600)
        #expect(loaded.lookUsed == last.lookUsed, "the bag comes back from the file")
        let restarted = SchedulerRig(catalog: LookFeel.catalog(looks: 8), settings: LookFeel.settings(), seed: 99, persisted: loaded,
                                     startWall: last.lookSince + 600)
        #expect(restarted.scheduler.persisted.lookUsed == last.lookUsed)
        let candidates = Set(restarted.scheduler.lookCandidates().map(\.id))
        #expect(candidates.isDisjoint(with: last.lookUsed) && candidates.count == 4)
    }

    @Test func LookBag_excludeThenIncludeMidCycleKeepsTheUsedLookUsed() throws {
        let (rig, writes) = LookFeel.rig(looks: 6, seed: 12)
        LookFeel.changes(rig, 1)
        let a = try #require(LookFeel.worn(rig).first)
        rig.scheduler.update(settings: LookFeel.settings { $0.excluded = [a] })
        #expect(!rig.scheduler.rotationLooks.map(\.id).contains(a))
        let last = try #require(writes.all.last)
        // restart with the exclusion, then include the look again
        let loaded = AgentState(position: SavedPosition(), persisted: last).persisted(catalog: LookFeel.catalog(looks: 6), nowEpoch: last.lookSince + 600)
        let restarted = SchedulerRig(catalog: LookFeel.catalog(looks: 6), settings: LookFeel.settings { $0.excluded = [a] }, seed: 3, persisted: loaded,
                                     startWall: last.lookSince + 600)
        restarted.scheduler.update(settings: LookFeel.settings())
        #expect(restarted.scheduler.rotationLooks.map(\.id).contains(a))
        #expect(!restarted.scheduler.lookCandidates().map(\.id).contains(a), "the look worn this cycle is not a candidate when it returns")
    }

    @Test func LookBag_removingAndRestoringALookInTheCatalogMidCycleKeepsItUsed() throws {
        let (rig, _) = LookFeel.rig(looks: 6, seed: 14)
        LookFeel.changes(rig, 1)
        let a = try #require(LookFeel.worn(rig).first)
        let full = LookFeel.catalog(looks: 6)
        let without = PetCatalog(motions: full.motions, looks: full.looks.filter { $0.id != a })
        rig.scheduler.update(catalog: without)
        rig.scheduler.update(catalog: full)
        #expect(rig.scheduler.persisted.lookUsed.contains(a) && !rig.scheduler.lookCandidates().map(\.id).contains(a))
    }

    @Test func LookBag_aNeverWornLookAddedMidCycleIsACandidateAtOnce() {
        let (rig, _) = LookFeel.rig(looks: 4, seed: 15)
        LookFeel.changes(rig, 2)
        rig.scheduler.update(catalog: LookFeel.catalog(looks: 5))
        #expect(rig.scheduler.lookCandidates().map(\.id).contains("l04"))
    }

    @Test func LookBag_oneLookInRotationChangesNothing() {
        let (rig, _) = LookFeel.rig(looks: 1, seed: 1)
        rig.advance(3600 * 30)
        #expect(LookFeel.worn(rig).isEmpty && rig.scheduler.lookDueMono() == nil && rig.scheduler.nextLookChange == nil)
    }

    @Test func LookBag_aCatalogContractionAtStartupStillChangesAutomatically() throws {
        // rotation {A,B,C}: A and B worn, then a restart into a catalog without C.
        let (rig, writes) = LookFeel.rig(looks: 3, seed: 7)
        LookFeel.changes(rig, 1)
        let last = try #require(writes.all.last)
        #expect(last.lookUsed.count == 2)
        let missing = (0..<3).map { String(format: "l%02d", $0) }.first { !last.lookUsed.contains($0) }!
        let full = LookFeel.catalog(looks: 3)
        let contracted = PetCatalog(motions: full.motions, looks: full.looks.filter { $0.id != missing })
        let loaded = AgentState(position: SavedPosition(), persisted: last).persisted(catalog: contracted, nowEpoch: last.lookSince + 600)
        let restarted = SchedulerRig(catalog: contracted, settings: LookFeel.settings(), seed: 5, persisted: loaded, refresh: false,
                                     startWall: last.lookSince + 600)
        var startupWrites: [SchedulerPersisted] = []
        restarted.scheduler.onPersist = { startupWrites.append($0) }
        // The reset is part of the state the host writes at start: the scheduler's persisted state is the reset one.
        #expect(restarted.scheduler.persisted.lookUsed == [restarted.scheduler.look], "the bag is reset to the worn look: \(restarted.scheduler.persisted.lookUsed)")
        restarted.scheduler.refresh()
        #expect(restarted.scheduler.lookHasCandidate && restarted.scheduler.lookDueMono() != nil)
        LookFeel.changes(restarted, 1, limit: 3600 * 24 * 2)
        #expect(LookFeel.worn(restarted).count == 1, "an automatic change still comes due and happens")
    }

    @Test func LookBag_aRestartAfterTheWornLookLeftTheCatalogKeepsTheCycle() throws {
        let (rig, writes) = LookFeel.rig(looks: 4, seed: 7)
        LookFeel.changes(rig, 1) // A (l00), then B; C and D have never been worn.
        let last = try #require(writes.all.last)
        try #require(last.look != "l00" && last.lookUsed.count == 2)
        let full = LookFeel.catalog(looks: 4)
        let contracted = PetCatalog(motions: full.motions, looks: full.looks.filter { $0.id != last.look })
        // Plain is the fallback look worn after the restart, so it joins the bag at once: the two looks never worn (C and D) are what is left.
        let unused = Set(full.looks.map(\.id)).subtracting(last.lookUsed).subtracting([PetCatalog.plainLook])
        try #require(unused.count == 2)
        let data = try JSONEncoder().encode(AgentState(position: SavedPosition(), persisted: last))
        var draws = 0
        let loaded = try JSONDecoder().decode(AgentState.self, from: data)
            .persisted(catalog: contracted, nowEpoch: last.lookSince + 600, lookEveryHours: 2, draw: { draws += 1; return 0.99 })
        #expect(loaded.look == PetCatalog.plainLook)
        #expect(loaded.lookUsed.contains("l00"), "removing B must not erase A from this cycle")
        #expect(loaded.lookDueFactor == last.lookDueFactor && draws == 0)
        let restarted = SchedulerRig(catalog: contracted, settings: LookFeel.settings(), seed: 5, persisted: loaded,
                                     startWall: last.lookSince + 600)
        #expect(Set(restarted.scheduler.lookCandidates().map(\.id)) == unused)
        LookFeel.changes(restarted, 2)
        #expect(LookFeel.worn(restarted).count == 2)
        #expect(Set(LookFeel.worn(restarted)) == unused, "both C and D are worn before A can return")
    }

    // MARK: rollback

    /// A copy of AgentState as the previous build had it (before the scheduler feel amendment).
    private struct PreviousAgentState: Codable, Equatable {
        var displayUUID: String?
        var xFrac: Double
        var feetFrac: Double
        var scale: Double
        var look: String?
        var lookSince: Double?
        var recentLooks: [String]?
        var lastBubbleStyle: Int?
        var helmetOffPending: Bool?
    }

    @Test func LookBag_aPreviousBuildDecodesTheNewStateFile() throws {
        let state = AgentState(position: SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1), look: "l02", lookSince: 1_799_990_000,
                               recentLooks: ["l01"], lookUsed: ["l00", "l02"], lookDueFactor: 1.1, lookDueAt: 1_800_010_000, examActive: true,
                               examGraceUntil: 1_800_000_500)
        let data = try JSONEncoder().encode(state)
        let old = try JSONDecoder().decode(PreviousAgentState.self, from: data)
        #expect(old.look == "l02" && old.lookSince == 1_799_990_000, "the old reader sees the look and the value of lookSince unchanged")
        #expect(old.xFrac == 0.4 && old.recentLooks == ["l01"])
    }

    @Test func LookBag_aRollbackDropsTheNewKeysAndTheNewBuildRestartsGracefully() throws {
        let state = AgentState(position: SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1), look: "l02", lookSince: 1_799_990_000,
                               recentLooks: ["l01"], lookUsed: ["l00", "l02"], lookDueFactor: 1.1, lookDueAt: 1_800_010_000, examActive: true,
                               examGraceUntil: 1_800_000_500)
        let written = try JSONEncoder().encode(state)
        // The previous build reads and rewrites the file: every key it does not know is gone.
        let rewritten = try JSONEncoder().encode(try JSONDecoder().decode(PreviousAgentState.self, from: written))
        let object = try #require(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        for key in ["lookUsed", "lookDueFactor", "lookDueAt", "examActive", "examGraceUntil"] { #expect(object[key] == nil, "\(key) is dropped by the previous build") }
        // The new build reads it back.
        let back = try JSONDecoder().decode(AgentState.self, from: rewritten)
        var calls = 0
        let loaded = back.persisted(catalog: LookFeel.catalog(looks: 6), nowEpoch: 1_800_000_000, lookEveryHours: 2, draw: { calls += 1; return 0.0 })
        #expect(loaded.look == "l02" && loaded.lookSince == 1_799_990_000 && loaded.recentLooks == ["l01"], "look and lookSince survive")
        #expect(calls == 1 && loaded.lookDueFactor == PetScheduler.lookJitterLow, "the factor is redrawn, once")
        #expect(!loaded.examActive && loaded.examGraceUntil == nil, "an exam hold in progress is lost")
        let rig = SchedulerRig(catalog: LookFeel.catalog(looks: 6), settings: LookFeel.settings(), persisted: loaded)
        #expect(rig.scheduler.persisted.lookUsed == ["l02"], "the bag restarts as the worn look: \(rig.scheduler.persisted.lookUsed)")
        // The pin survives: it lives in control.json, not in state.json.
        let pinned = SchedulerRig(catalog: LookFeel.catalog(looks: 6), settings: LookFeel.settings { $0.lookPin = "l02" }, persisted: loaded)
        #expect(pinned.scheduler.look == "l02" && pinned.scheduler.lookDueMono() == nil)
    }
}
