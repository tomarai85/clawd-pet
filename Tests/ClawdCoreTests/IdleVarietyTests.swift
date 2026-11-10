import Testing
import Foundation
import CoreGraphics
@testable import ClawdCore

// Amendment "variety": idle motions play by family in a per-look bag (D-1 to D-3), and a look that offers few families is due sooner (D-4, D-5).

enum Variety {
    /// Idle motions whose family sets differ per look: plain 11 families, coffee 3 (B3 x4, B4 x2, A19), winter 7 (A10 never fits the display).
    static func catalog() -> PetCatalog {
        func motion(_ id: String, _ seconds: Double = 2.5, uses: [String] = ["idle"], stage: StageExtent = .none, looks: Set<String>) -> CatalogMotion {
            CatalogMotion(id: id, board: String(id.prefix { $0 != "-" }), uses: Set(uses.map(MotionUse.init)), frameCount: Int(seconds * 12),
                          duration: seconds, stage: stage, overheadClear: true, weight: 1, compatibleLooks: looks, strideUnits: nil, holdsLastFrame: false)
        }
        let all: Set<String> = ["plain", "coffee", "winter"], rich: Set<String> = ["plain", "winter"]
        var motions: [CatalogMotion] = []
        for id in ["B3-glance-left", "B3-glance-right", "B3-glance-left-long", "B3-glance-right-long", "B4-wink", "B4-slow-blink"] {
            motions.append(motion(id, looks: all))
        }
        motions.append(motion("A19-coffee", uses: ["idle", "signature:coffee"], looks: ["plain", "coffee"]))
        for id in ["B5-foot-tap", "C4-look", "A9-dancing", "A9-dancing-happy", "A1-thinking"] { motions.append(motion(id, looks: rich)) }
        for id in ["A2-looking", "A7-swaying", "A8-excited"] { motions.append(motion(id, looks: ["plain"])) }
        motions.append(motion("A10-huge", stage: StageExtent(left: 1000), looks: rich))
        let looks = [CatalogLook(id: "plain", board: "B1", classes: ["plain"]),
                     CatalogLook(id: "coffee", board: "D9", classes: ["held"], signature: ["A19-coffee"]),
                     CatalogLook(id: "winter", board: "D2", classes: ["costume"])]
        return PetCatalog(motions: motions, looks: looks)
    }
    static let winterFamilies: Set<String> = ["B3", "B4", "B5", "C4", "A9", "A1"]      // eligible (A10 does not fit)
    static let coffeeFamilies: Set<String> = ["B3", "B4", "A19"]
    static let wall = 1_800_000_000.0

    static func settings(hours: Int = 4, pin: String? = nil, _ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
        var s = SchedulerSettings(); s.motion = .lively; s.walk = false; s.lookEveryHours = hours; s.lookPin = pin; edit(&s); return s
    }
    static func family(_ id: String) -> String { String(id.prefix { $0 != "-" }) }

    /// A rig wearing `look` (the factor as the host would load it), with the persisted writes captured. `pin` holds the look for the whole run.
    static func rig(look: String = "winter", seed: UInt64 = 1, pin: Bool = true, catalog: PetCatalog = catalog(),
                    persisted: SchedulerPersisted? = nil, startWall: Double = wall, settings edit: (inout SchedulerSettings) -> Void = { _ in })
        -> (rig: SchedulerRig, writes: LookFeel.Writes) {
        var state = persisted ?? SchedulerPersisted(look: look, lookSince: startWall)
        if persisted == nil { state.lookVarietyFactor = PetScheduler.varietyFactor(look: look, catalog: catalog) }
        let rig = SchedulerRig(catalog: catalog, settings: settings(pin: pin ? state.look : nil, edit), seed: seed, persisted: state, refresh: false,
                               startWall: startWall)
        let writes = LookFeel.Writes()
        rig.scheduler.onPersist = { writes.all.append($0) }
        rig.scheduler.refresh()
        return (rig, writes)
    }
    /// The families of the automatic idle motions started so far, in order.
    static func plays(_ rig: SchedulerRig) -> [String] {
        rig.events.compactMap {
            if case .motionStart(let id, let use) = $0.event, use == "idle" || use.hasPrefix("signature") { return family(id) } else { return nil }
        }
    }
    @discardableResult
    static func playUntil(_ rig: SchedulerRig, plays count: Int) -> Bool {
        rig.run(upTo: 3600 * 24 * 3) { plays(rig).count >= count }
    }
    /// The state as a restart finds it: written to state.json and read back through the catalog.
    static func reload(_ state: SchedulerPersisted, catalog: PetCatalog = catalog(), after seconds: Double = 600) throws -> SchedulerPersisted {
        let data = try JSONEncoder().encode(AgentState(position: SavedPosition(), persisted: state))
        return try JSONDecoder().decode(AgentState.self, from: data)
            .persisted(catalog: catalog, nowEpoch: state.lookSince + seconds, lookEveryHours: 4)
    }
    static func chunks(_ list: [String], _ size: Int) -> [[String]] {
        stride(from: 0, to: list.count - size + 1, by: size).map { Array(list[$0..<$0 + size]) }
    }
}

@Suite("Variety: the idle family bag", .serialized)
struct IdleBagTests {
    @Test func IdleBag_noFamilyRepeatsWithinACycle() {
        for look in ["coffee", "winter"] {
            let n = look == "coffee" ? 3 : 6
            let (rig, _) = Variety.rig(look: look, seed: 4)
            Variety.playUntil(rig, plays: n * 20)
            let plays = Variety.plays(rig)
            #expect(plays.count >= n * 20, "\(look): twenty cycles were played")
            for (i, cycle) in Variety.chunks(plays, n).enumerated() {
                #expect(Set(cycle).count == n, "\(look): cycle \(i + 1) repeats a family: \(cycle)")
            }
        }
    }

    @Test func IdleBag_everyFamilyEligibleForTheWholeCyclePlaysOnce() {
        let (rig, _) = Variety.rig(look: "winter", seed: 7)
        Variety.playUntil(rig, plays: 2)
        let unplayed = Variety.winterFamilies.subtracting(Variety.plays(rig)).sorted()
        let removed = unplayed[0]
        rig.scheduler.update(settings: Variety.settings(pin: "winter") { $0.excluded = [removed.lowercased()] })
        Variety.playUntil(rig, plays: 5)
        let cycle = Array(Variety.plays(rig).prefix(5))
        #expect(Set(cycle) == Variety.winterFamilies.subtracting([removed]) && cycle.count == 5, "the five that stayed eligible once each, \(removed) none: \(cycle)")
        // The next cycle too, with the same eligibility.
        Variety.playUntil(rig, plays: 10)
        #expect(Set(Variety.plays(rig)[5..<10]).count == 5 && !Variety.plays(rig)[5..<10].contains(removed))
    }

    @Test func IdleBag_theFourGlancesCountAsOneFamily() {
        let (rig, _) = Variety.rig(look: "coffee", seed: 9)
        Variety.playUntil(rig, plays: 90)
        let plays = Array(Variety.plays(rig).prefix(90))
        let ids = rig.ids("idle").prefix(90)
        #expect(Set(ids.filter { $0.hasPrefix("B3") }).count > 1, "the glances vary inside their family")
        #expect(plays.filter { $0 == "B3" }.count * 3 == plays.count, "B3 is exactly 1/3 of the plays of complete cycles: \(plays.filter { $0 == "B3" }.count) of \(plays.count)")
        #expect(plays.filter { $0 == "B4" }.count * 3 == plays.count)
    }

    @Test func IdleBag_theSignatureFamilyIsWeightedThreeTimesInTheFirstDrawOfACycleOnly() {
        let (rig, _) = Variety.rig(look: "coffee", seed: 11)
        var draws: [[String: Double]] = []
        rig.scheduler.onIdleFamilyWeights = { families, weights in
            draws.append(Dictionary(uniqueKeysWithValues: zip(families, weights)))
        }
        // Stable eligibility, three families per cycle, and no preemption: every automatic draw starts its motion.
        // Observe the weights used by the real picker, including the boundary draw of each new cycle.
        #expect(Variety.playUntil(rig, plays: 3 * 300))
        #expect(draws.count == 3 * 300, "one observed draw for every committed idle start")
        var sawFirstSignature = false, sawLaterSignature = false
        for (index, weights) in draws.enumerated() {
            let firstDraw = index.isMultiple(of: 3)
            if let signatureWeight = weights["A19"] {
                #expect(signatureWeight == (firstDraw ? 3 : 1), "draw \(index + 1): signature weight is x3 only at a cycle's first draw")
                if firstDraw { sawFirstSignature = true } else { sawLaterSignature = true }
            }
            if let glances = weights["B3"] { #expect(glances == 3, "four members, capped at 3, no multiplier") }
            if let blinks = weights["B4"] { #expect(blinks == 2, "two members, no multiplier") }
        }
        #expect(sawFirstSignature && sawLaterSignature, "the actual picker considered the signature in both first and later draws")
        // It is not "always first": the signature leads some cycles and plays later in the others.
        let cycles = Variety.chunks(Variety.plays(rig), 3)
        let leads = cycles.filter { $0[0] == "A19" }.count
        #expect(leads > cycles.count / 6 && leads < cycles.count / 2, "A19 leads \(leads) of \(cycles.count) cycles")
        #expect(cycles.contains { $0[0] != "A19" && $0.contains("A19") })
    }

    @Test func IdleBag_aLookChangeClearsTheBag() {
        let (rig, writes) = Variety.rig(look: "coffee", seed: 5, pin: false)
        Variety.playUntil(rig, plays: 2)
        #expect(rig.scheduler.persisted.idleFamiliesUsed.count == 2 && rig.scheduler.persisted.idleBagLook == "coffee")
        rig.scheduler.update(settings: Variety.settings(pin: "winter"))
        _ = rig.run(upTo: 600) { rig.scheduler.persisted.look == "winter" }
        let p = rig.scheduler.persisted
        #expect(p.look == "winter" && p.idleFamiliesUsed.isEmpty && p.idleLastFamily == nil && p.idleBagLook == "winter", "cleared with the look: \(p)")
        #expect(p.idleLastMembers.isEmpty, "the previous look's member history is cleared with its bag")
        let last = writes.all.last
        #expect(last?.look == "winter" && last?.idleFamiliesUsed == [] && last?.idleBagLook == "winter", "and written in the same step as the look clock")
        #expect(last?.idleLastMembers == [:], "the cleared member history is written in the same step")
    }

    @Test func IdleBag_aToBToAWithNoIdlePickStartsAWithAnEmptyBag() {
        let (rig, _) = Variety.rig(look: "coffee", seed: 6, pin: false)
        Variety.playUntil(rig, plays: 2)
        rig.scheduler.update(settings: Variety.settings(pin: "winter") { $0.motion = .off })
        _ = rig.run(upTo: 600) { rig.scheduler.persisted.look == "winter" }
        rig.scheduler.update(settings: Variety.settings(pin: "coffee") { $0.motion = .off })
        _ = rig.run(upTo: 600) { rig.scheduler.persisted.look == "coffee" }
        let p = rig.scheduler.persisted
        #expect(Variety.plays(rig).count == 2, "no idle motion between the two changes")
        #expect(p.look == "coffee" && p.idleFamiliesUsed.isEmpty && p.idleLastFamily == nil, "A starts with an empty bag: \(p.idleFamiliesUsed)")
        #expect(p.idleLastMembers.isEmpty, "A starts with empty member history too")
    }

    @Test func IdleBag_motionLevelWalkExclusionAndSameLookPinKeepTheBag() {
        let (rig, _) = Variety.rig(look: "winter", seed: 8)
        Variety.playUntil(rig, plays: 3)
        let before = rig.scheduler.persisted
        #expect(before.idleFamiliesUsed.count == 3)
        func same(_ what: String) {
            let p = rig.scheduler.persisted
            #expect(p.idleFamiliesUsed == before.idleFamiliesUsed && p.idleBagLook == before.idleBagLook && p.idleLastFamily == before.idleLastFamily,
                    "\(what) keeps the bag: \(p.idleFamiliesUsed)")
            #expect(p.idleLastMembers == before.idleLastMembers, "\(what) keeps every family's last member")
        }
        rig.scheduler.update(settings: Variety.settings(pin: "winter") { $0.motion = .normal }); same("a motion level change")
        rig.scheduler.update(settings: Variety.settings(pin: "winter") { $0.walk = true }); same("walk on")
        rig.scheduler.update(settings: Variety.settings(pin: "winter") { $0.walk = false }); same("walk off")
        rig.scheduler.update(settings: Variety.settings(pin: "winter") { $0.excluded = ["b5"] }); same("an exclusion")
        rig.scheduler.update(settings: Variety.settings(pin: "winter")); same("the exclusion removed")
        rig.scheduler.update(settings: Variety.settings(pin: nil)); same("an unpin")
        rig.scheduler.update(settings: Variety.settings(pin: "winter")); same("a pin of the look already worn")
    }

    @Test func IdleBag_aPreemptedBoundaryDrawLeavesTheBag() {
        let (rig, writes) = Variety.rig(look: "winter", seed: 12)
        Variety.playUntil(rig, plays: 6)
        let full = rig.scheduler.persisted
        #expect(full.idleFamiliesUsed.count == 6, "the cycle is complete")
        let before = writes.all.count
        for _ in 0..<3 {
            let pick = rig.scheduler.planIdleMotion()
            #expect(pick?.startsNewCycle == true && pick?.family != full.idleLastFamily, "the boundary choice, never the last family")
        }
        #expect(rig.scheduler.persisted == full && writes.all.count == before, "the choice changed and wrote nothing")
        rig.dictate()
        #expect(rig.scheduler.persisted.idleFamiliesUsed == full.idleFamiliesUsed, "a scene pre-empted the draw: the bag is as it was")
        let plays = Variety.plays(rig).count
        Variety.playUntil(rig, plays: plays + 1)
        #expect(rig.scheduler.persisted.idleFamiliesUsed.count == 1, "the motion that does start commits the reset and is the first of the new cycle")
    }

    @Test func IdleBag_anEmptyEligiblePoolChangesNothing() {
        let (rig, writes) = Variety.rig(look: "winter", seed: 13)
        Variety.playUntil(rig, plays: 2)
        let before = rig.scheduler.persisted
        rig.scheduler.update(settings: Variety.settings(pin: "winter") { $0.excluded = ["b3", "b4", "b5", "c4", "a9", "a1", "a10"] })
        let written = writes.all.count, played = Variety.plays(rig).count
        rig.advance(900)
        #expect(Variety.plays(rig).count == played && writes.all.count == written, "no pick, no write")
        #expect(rig.scheduler.persisted.idleFamiliesUsed == before.idleFamiliesUsed && rig.scheduler.persisted.idleLastFamily == before.idleLastFamily)
        rig.scheduler.update(settings: Variety.settings(pin: "winter"))
        Variety.playUntil(rig, plays: played + 1)
        #expect(!before.idleFamiliesUsed.contains(Variety.plays(rig).last!), "the cycle goes on where it was")
    }

    @Test func IdleBag_aRestartBeforeTheStartDoesNotConsumeAndAfterItDoes() throws {
        let (rig, writes) = Variety.rig(look: "winter", seed: 14)
        Variety.playUntil(rig, plays: 2)
        let two = try #require(writes.all.last)
        // A restart between the choice and the start: the choice is not consumed.
        let (b, _) = Variety.rig(look: "winter", seed: 15, persisted: try Variety.reload(two), startWall: two.lookSince + 600)
        #expect(b.scheduler.planIdleMotion() != nil)
        let between = try Variety.reload(b.scheduler.persisted)
        #expect(between.idleFamiliesUsed == two.idleFamiliesUsed && between.idleLastFamily == two.idleLastFamily, "the chosen family is not in the file: \(between.idleFamiliesUsed)")
        #expect(between.idleLastMembers == two.idleLastMembers, "a choice that has not started leaves member history unchanged")
        // A restart after the start: the family is used.
        Variety.playUntil(rig, plays: 3)
        let three = try #require(writes.all.last)
        let loaded = try Variety.reload(three)
        #expect(loaded.idleFamiliesUsed == three.idleFamiliesUsed && loaded.idleFamiliesUsed.count == 3, "the bag comes back from the file: \(loaded.idleFamiliesUsed)")
        #expect(loaded.idleLastMembers == three.idleLastMembers && loaded.idleLastMembers.count == 3, "every family's last member comes back")
        let (c, cWrites) = Variety.rig(look: "winter", seed: 16, persisted: loaded, startWall: three.lookSince + 600)
        Variety.playUntil(c, plays: 1)
        let next = Variety.plays(c)[0]
        #expect(!three.idleFamiliesUsed.contains(next), "the restarted agent plays a family not yet used: \(next) after \(three.idleFamiliesUsed)")
        #expect(cWrites.all.last?.idleFamiliesUsed.count == 4)
    }

    @Test func IdleBag_theLastFamilyIsKeptAcrossTheBoundaryAndARestart() throws {
        for seed in UInt64(1)...12 {
            let (rig, writes) = Variety.rig(look: "winter", seed: seed)
            Variety.playUntil(rig, plays: 6)
            let full = try #require(writes.all.last)
            let last = try #require(full.idleLastFamily)
            let loaded = try Variety.reload(full)
            #expect(loaded.idleLastFamily == last, "seed \(seed): the last family comes back from the file")
            let (restarted, _) = Variety.rig(look: "winter", seed: seed &+ 100, persisted: loaded, startWall: full.lookSince + 600)
            Variety.playUntil(restarted, plays: 1)
            #expect(Variety.plays(restarted)[0] != last, "seed \(seed): the first draw of the new cycle is not \(last)")
        }
        let (rig, _) = Variety.rig(look: "winter", seed: 3)
        Variety.playUntil(rig, plays: 6 * 30)
        let cycles = Variety.chunks(Variety.plays(rig), 6)
        for i in 1..<cycles.count { #expect(cycles[i][0] != cycles[i - 1][5], "cycle \(i + 1) does not start with the family that ended cycle \(i)") }
    }

    @Test func IdleBag_aSingletonPoolStillPlaysAcrossTheBoundary() {
        let (rig, _) = Variety.rig(look: "coffee", seed: 17) { $0.excluded = ["b3", "b4"] }
        let held = Variety.playUntil(rig, plays: 6)
        #expect(held, "with one eligible family the picks go on: \(Variety.plays(rig))")
        #expect(Set(Variety.plays(rig)) == ["A19"])
    }

    @Test func IdleBag_theLastMemberOfAFamilyIsKeptAcrossARestart() throws {
        for seed in UInt64(1)...12 {
            // Only B4's two members are eligible. Stop at the committed start of wink, before its playback ends.
            let (rig, writes) = Variety.rig(look: "coffee", seed: seed) { $0.excluded = ["b3", "a19"] }
            try #require(Variety.playUntil(rig, plays: 1))
            if rig.ids("idle").last != "B4-wink" { try #require(Variety.playUntil(rig, plays: 2)) }
            try #require(rig.ids("idle").last == "B4-wink", "seed \(seed): wink has started")
            let saved = try #require(writes.all.last)
            #expect(saved.idleFamiliesUsed == ["B4"] && saved.idleLastFamily == "B4")
            #expect(saved.idleLastMembers == ["B4": "B4-wink"], "the start writes the member with the family bag")
            let loaded = try Variety.reload(saved)
            #expect(loaded.idleLastMembers == ["B4": "B4-wink"], "seed \(seed): member history survives state.json")
            let (restarted, restartWrites) = Variety.rig(seed: seed &+ 100, persisted: loaded, startWall: saved.lookSince + 600) {
                $0.excluded = ["b3", "a19"]
            }
            try #require(Variety.playUntil(restarted, plays: 1))
            #expect(restarted.ids("idle").first == "B4-slow-blink", "seed \(seed): the automatic boundary draw cannot repeat wink")
            #expect(restartWrites.all.last?.idleLastMembers == ["B4": "B4-slow-blink"], "the next start updates the saved member")
        }
    }

    @Test func IdleBag_missingOrMalformedMemberHistoryDoesNotLoseTheBag() throws {
        let saved = AgentState(position: SavedPosition(), look: "coffee", lookSince: Variety.wall,
                               idleBagLook: "coffee", idleFamiliesUsed: ["B4"], idleLastFamily: "B4")
        let data = try JSONEncoder().encode(saved)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Absent on older builds, or present with a wrong value: only this field is lost.
        let malformed: [Any?] = [nil, NSNull(), 42, "B4-wink", ["B4-wink"], ["B4": 42], ["B4": "B3-glance-left"], ["": ""]]
        for value in malformed {
            var altered = object
            altered["idleLastMembers"] = value
            let bytes = try JSONSerialization.data(withJSONObject: altered)
            let decoded = try JSONDecoder().decode(AgentState.self, from: bytes)
            let loaded = decoded.persisted(catalog: Variety.catalog(), nowEpoch: Variety.wall + 60)
            #expect(loaded.idleLastMembers.isEmpty)
            #expect(loaded.look == "coffee" && loaded.idleBagLook == "coffee" && loaded.idleFamiliesUsed == ["B4"] && loaded.idleLastFamily == "B4")
            #expect(decoded.position == saved.position)
        }
        var mixed = object
        mixed["idleLastMembers"] = ["B4": "B4-wink", "B3": 42] as [String: Any]
        let bytes = try JSONSerialization.data(withJSONObject: mixed)
        let decoded = try JSONDecoder().decode(AgentState.self, from: bytes)
        #expect(decoded.persisted(catalog: Variety.catalog(), nowEpoch: Variety.wall).idleLastMembers == ["B4": "B4-wink"])
        var anotherLook = decoded
        anotherLook.idleBagLook = "winter"
        let loaded = anotherLook.persisted(catalog: Variety.catalog(), nowEpoch: Variety.wall)
        #expect(loaded.idleLastMembers.isEmpty && loaded.idleFamiliesUsed.isEmpty && loaded.idleLastFamily == nil,
                "member history is discarded with a bag from a different look")
    }

    @Test func IdleBag_aFamilyThatReturnsMidCycleIsACandidate() {
        let (rig, _) = Variety.rig(look: "winter", seed: 19) { $0.excluded = ["b5"] }
        Variety.playUntil(rig, plays: 3)
        #expect(!Variety.plays(rig).contains("B5"))
        rig.scheduler.update(settings: Variety.settings(pin: "winter"))
        Variety.playUntil(rig, plays: 6)
        let cycle = Array(Variety.plays(rig).prefix(6))
        #expect(Set(cycle) == Variety.winterFamilies && Variety.plays(rig)[3...].contains("B5"), "B5 came back and is owed in this cycle: \(cycle)")
    }

    @Test func IdleBag_exclusionsAndStageFitStillApply() {
        let (rig, _) = Variety.rig(look: "winter", seed: 21) { $0.excluded = ["b5"] }
        Variety.playUntil(rig, plays: 5 * 20)
        let plays = Variety.plays(rig)
        #expect(!plays.contains("B5"), "an excluded family never plays")
        #expect(!plays.contains("A10"), "a family whose stage does not fit never plays")
        for cycle in Variety.chunks(plays, 5) { #expect(Set(cycle).count == 5) }
    }

    @Test func IdleBag_aPreemptedChoiceConsumesNothing() {
        let (rig, writes) = Variety.rig(look: "winter", seed: 22)
        Variety.playUntil(rig, plays: 2)
        let before = rig.scheduler.persisted, written = writes.all.count
        for _ in 0..<5 { _ = rig.scheduler.planIdleMotion() }
        #expect(rig.scheduler.persisted == before && writes.all.count == written, "a choice that never starts consumes nothing")
        let played = Variety.plays(rig).count
        rig.dictate()
        #expect(Variety.plays(rig).count == played && rig.scheduler.persisted.idleFamiliesUsed == before.idleFamiliesUsed)
    }
}

@Suite("Variety: the look interval", .serialized)
struct LookVarietyTests {
    private func loaded(_ look: String, draw: Double = 0.0) throws -> SchedulerPersisted {
        let state = AgentState(position: SavedPosition(), look: look, lookSince: Variety.wall)
        return state.persisted(catalog: Variety.catalog(), nowEpoch: Variety.wall, lookEveryHours: 2, draw: { draw })
    }
    private func expectedVariety(_ look: String) -> Double {
        switch look { case "coffee": return 1.0 / 3.0; case "winter": return 7.0 / 11.0; default: return 1 }
    }

    @Test func LookVariety_dueIntervalIsSettingTimesJitterTimesVariety() throws {
        for look in ["plain", "coffee", "winter"] {
            let state = try loaded(look)
            #expect(abs(state.lookVarietyFactor - expectedVariety(look)) < 1e-12, "\(look): \(state.lookVarietyFactor)")
            let expected = 7200 * 0.75 * expectedVariety(look)
            #expect(abs((state.lookDueAt ?? 0) - Variety.wall - expected) < 1e-6, "\(look): the due interval is 2 h x 0.75 x variety")
            var s = Variety.settings(hours: 2) { $0.motion = .off }; s.lookPin = nil
            let rig = SchedulerRig(catalog: Variety.catalog(), settings: s, seed: 3, persisted: state)
            #expect(rig.scheduler.nextLookChange == Date(timeIntervalSince1970: Variety.wall + expected), "\(look): the status date is the due time")
            _ = rig.run(upTo: 7200 * 2) { !LookFeel.worn(rig).isEmpty }
            let start = rig.events.compactMap { e -> TimeInterval? in if case .lookTransition = e.event { return e.t - rig.started } else { return nil } }.first
            #expect(start != nil && start! >= expected - 1e-6 && start! < expected + 45, "\(look): the change starts at the due time: \(String(describing: start)) vs \(expected)")
        }
    }

    @Test func LookVariety_theFactorIsPersistedAndStatusReportsTheDueTime() throws {
        var s = Variety.settings(hours: 2) { $0.motion = .off }; s.lookPin = nil
        let writes = LookFeel.Writes()
        let rig = SchedulerRig(catalog: Variety.catalog(), settings: s, seed: 4, persisted: try loaded("plain", draw: 0.5), refresh: false)
        rig.scheduler.onPersist = { writes.all.append($0) }
        rig.scheduler.refresh()
        _ = rig.run(upTo: 7200 * 2) { !LookFeel.worn(rig).isEmpty }
        let worn = try #require(LookFeel.worn(rig).first)
        let last = try #require(writes.all.last)
        #expect(last.look == worn && abs(last.lookVarietyFactor - expectedVariety(worn)) < 1e-12, "\(worn): the factor of the new look is written: \(last.lookVarietyFactor)")
        let json = String(decoding: try JSONEncoder().encode(AgentState(position: SavedPosition(), persisted: last)), as: UTF8.self)
        #expect(json.contains("lookVarietyFactor"))
        let reloaded = try Variety.reload(last, after: 60)
        #expect(abs(reloaded.lookVarietyFactor - last.lookVarietyFactor) < 1e-12 && reloaded.lookDueAt != nil)
        let due = last.lookSince + 7200 * last.lookDueFactor * last.lookVarietyFactor
        #expect(rig.scheduler.nextLookChange == Date(timeIntervalSince1970: due), "status reports the due time the scheduler uses")
    }

    @Test func LookVariety_aPinnedLookIsNotShortened() throws {
        // A pin that makes the worn look change: worn with the full interval and no due change.
        var open = Variety.settings(hours: 2) { $0.motion = .off }; open.lookPin = nil
        let writes = LookFeel.Writes()
        let rig = SchedulerRig(catalog: Variety.catalog(), settings: open, seed: 5, persisted: try loaded("plain", draw: 0.5), refresh: false)
        rig.scheduler.onPersist = { writes.all.append($0) }
        rig.scheduler.refresh()
        rig.scheduler.update(settings: Variety.settings(hours: 2, pin: "coffee") { $0.motion = .off })
        _ = rig.run(upTo: 600) { rig.scheduler.persisted.look == "coffee" }
        let pinned = rig.scheduler.persisted
        #expect(pinned.look == "coffee" && pinned.lookVarietyFactor == 1, "a pinned costume keeps the full interval: \(pinned.lookVarietyFactor)")
        #expect(abs((pinned.lookDueAt ?? 0) - pinned.lookSince - 7200 * pinned.lookDueFactor) < 1e-6)
        #expect(rig.scheduler.nextLookChange == nil, "a pinned look has no due change")
        // A pin of the look already worn.
        let rig2 = SchedulerRig(catalog: Variety.catalog(), settings: open, seed: 6, persisted: try loaded("coffee", draw: 0.5))
        #expect(rig2.scheduler.persisted.lookVarietyFactor < 0.34)
        rig2.scheduler.update(settings: Variety.settings(hours: 2, pin: "coffee") { $0.motion = .off })
        #expect(rig2.scheduler.persisted.lookVarietyFactor == 1, "pinning the worn look lifts the shortening")
        // The pin ends: the look is in rotation again, with its own factor from now.
        rig2.scheduler.update(settings: Variety.settings(hours: 2) { $0.motion = .off })
        #expect(abs(rig2.scheduler.persisted.lookVarietyFactor - 1.0 / 3.0) < 1e-12)
    }

    @Test func LookVariety_rollbackAndForwardRecomputeTheFactorOnce() throws {
        var state = try loaded("coffee", draw: 0.5)
        state.idleBagLook = "coffee"; state.idleFamiliesUsed = ["B3"]; state.idleLastFamily = "B3"
        state.idleLastMembers = ["B3": "B3-glance-left"]
        let current = try JSONEncoder().encode(AgentState(position: SavedPosition(), persisted: state))
        // The previous build reads the file and writes it again without the keys of this amendment.
        var object = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
        for key in ["lookVarietyFactor", "idleBagLook", "idleFamiliesUsed", "idleLastFamily", "idleLastMembers"] {
            #expect(object[key] != nil, "\(key) is written")
            object[key] = nil
        }
        let older = try JSONSerialization.data(withJSONObject: object)
        let forward = try JSONDecoder().decode(AgentState.self, from: older).persisted(catalog: Variety.catalog(), nowEpoch: Variety.wall + 60, lookEveryHours: 2)
        #expect(abs(forward.lookVarietyFactor - 1.0 / 3.0) < 1e-12, "recomputed from the worn look: \(forward.lookVarietyFactor)")
        #expect(forward.idleFamiliesUsed.isEmpty && forward.idleBagLook == nil && forward.idleLastFamily == nil, "the bag starts empty")
        #expect(forward.idleLastMembers.isEmpty, "an older build drops member history along with the bag")
        let again = try Variety.reload(forward, after: 60)
        #expect(abs(again.lookVarietyFactor - forward.lookVarietyFactor) < 1e-12 && again.idleBagLook == nil, "and it is stable from then on")
    }
}

@Suite("Variety: measured", .serialized)
struct IdleVarietyMeasured {
    /// Seeded rig, the user's settings (lively, walk on, look every 2 h), six hours of virtual time on the real catalog, Clawd mid-display on 1920 x 1080.
    private func run(guards: SchedulerGuards) throws -> (rig: SchedulerRig, stints: [(look: String, plays: [String])]) {
        let atlas = try Data(contentsOf: repository.appendingPathComponent("art/clawd-atlas.json"))
        let catalog = PetCatalog(atlasData: atlas)
        let geometry = PetGeometry(scale: 1, homeOrigin: CGPoint(x: 960 - 20, y: 100),
                                   displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 80, width: 1920, height: 1000))
        var s = SchedulerSettings(); s.motion = .lively; s.walk = true; s.lookEveryHours = 2
        var state = SchedulerPersisted(look: "plain", lookSince: Variety.wall)
        state.lookVarietyFactor = PetScheduler.varietyFactor(look: "plain", catalog: catalog)
        let rig = SchedulerRig(catalog: catalog, settings: s, geometry: geometry, seed: 5, guards: guards, persisted: state)
        rig.advance(6 * 3600)
        var stints: [(look: String, plays: [String])] = [("plain", [])]
        for e in rig.events {
            switch e.event {
            case .lookChange(_, let to): stints.append((to, []))
            case .motionStart(let id, let use) where use == "idle" || use.hasPrefix("signature"): stints[stints.count - 1].plays.append(Variety.family(id))
            default: break
            }
        }
        return (rig, stints)
    }
    private func share(_ family: String, _ plays: [String]) -> Double { plays.isEmpty ? 0 : Double(plays.filter { $0 == family }.count) / Double(plays.count) }

    @Test func IdleBag_sixHoursAtLivelyMeasured() throws {
        let (rig, stints) = try run(guards: .all)
        let catalog = rig.scheduler.catalog
        var completeNew: [String: [String]] = [:], whole: [String: [String]] = [:]
        for stint in stints {
            let eligible = Set(catalog.idlePool(look: stint.look).filter { rig.scheduler.eligible($0, look: stint.look, pointerCheck: false) }.map { PetScheduler.family(of: $0) })
            #expect(eligible == catalog.idleFamilies(look: stint.look), "\(stint.look): every family of the look fits at mid-display")
            whole[stint.look, default: []] += stint.plays
            for cycle in Variety.chunks(stint.plays, eligible.count) {
                #expect(Set(cycle).count == eligible.count, "\(stint.look): a complete cycle has every family once: \(cycle)")
                completeNew[stint.look, default: []] += cycle
            }
        }
        let (_, oldStints) = try run(guards: SchedulerGuards.all.subtracting(.idleBag))
        var oldWhole: [String: [String]] = [:]
        for stint in oldStints { oldWhole[stint.look, default: []] += stint.plays }
        print("IDLE-SHARES looks worn (new): \(stints.map(\.look)); (old): \(oldStints.map(\.look))")
        var lines: [String] = []
        var newB3 = 0.0, oldB3 = 0.0, counted = 0
        for look in completeNew.keys.sorted() {
            let n = catalog.idleFamilies(look: look).count, cycles = completeNew[look]!
            let old = oldWhole[look] ?? []
            lines.append("IDLE-SHARES \(look) (\(n) families): B3 old \(String(format: "%.3f", share("B3", old))) (\(old.count) plays) new \(String(format: "%.3f", share("B3", cycles))) (\(cycles.count) plays in complete cycles, 1/n = \(String(format: "%.3f", 1.0 / Double(n)))); B4 old \(String(format: "%.3f", share("B4", old))) new \(String(format: "%.3f", share("B4", cycles)))")
            for family in ["B3", "B4"] where catalog.idleFamilies(look: look).contains(family) {
                #expect(cycles.filter { $0 == family }.count * n == cycles.count, "\(look): \(family) is 1/\(n) of the complete cycles")
            }
            if catalog.idleFamilies(look: look).contains("B3"), !old.isEmpty { newB3 += share("B3", cycles); oldB3 += share("B3", old); counted += 1 }
        }
        for line in lines { print(line) }
        let allOld = oldWhole.values.flatMap { $0 }, allNew = whole.values.flatMap { $0 }
        print("IDLE-SHARES all plays: old B3 \(String(format: "%.3f", share("B3", allOld))) B4 \(String(format: "%.3f", share("B4", allOld))) (\(allOld.count) plays); new B3 \(String(format: "%.3f", share("B3", allNew))) B4 \(String(format: "%.3f", share("B4", allNew))) (\(allNew.count) plays)")
        #expect(counted > 0, "at least one look completed a cycle")
        #expect(newB3 < oldB3, "the glances lose share against today's picker: \(newB3) vs \(oldB3)")
    }
}
