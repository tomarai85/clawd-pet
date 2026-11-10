import Testing
import Foundation
import CoreGraphics
@testable import ClawdCore
import ClawdDesktop

// Amendment "scheduler feel", D-3: each interval between look changes is the setting times a factor drawn once in 0.75 to 1.25.

@Suite("Scheduler feel: the look interval", .serialized)
struct SchedulerFeelJitter {
    private func hoursSeconds(_ h: Int) -> Double { Double(h) * 3600 }

    @Test func LookJitter_theFactorStaysInsideTheBand() {
        let (rig, _) = LookFeel.rig(looks: 6, seed: 31)
        var low = Double.infinity, high = -Double.infinity
        for _ in 0..<10_000 {
            let factor = rig.scheduler.drawLookFactor()
            low = min(low, factor); high = max(high, factor)
        }
        #expect(low >= 0.75 && high <= 1.25, "10 000 draws lie in [0.75, 1.25]: \(low) ... \(high)")
        #expect(low < 0.76 && high > 1.24, "and fill the band")
        var unit = 0.0
        while unit < 1 { #expect(PetScheduler.lookFactor(unit: unit) >= 0.75 && PetScheduler.lookFactor(unit: unit) <= 1.25); unit += 0.001 }
    }

    @Test func LookJitter_theMeanIsTheSetting() {
        for hours in [2, 3, 4] {
            let (rig, writes) = LookFeel.rig(looks: 15, hours: hours, seed: UInt64(40 + hours))
            LookFeel.changes(rig, 600)
            let gaps = writes.all.map { ($0.lookDueAt! - $0.lookSince) / hoursSeconds(hours) }
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            #expect(abs(mean - 1.0) < 0.01, "\(hours) h: the mean of \(gaps.count) drawn intervals is \(mean) of the setting")
            #expect(gaps.min()! >= 0.75 && gaps.max()! <= 1.25)
        }
    }

    @Test func LookJitter_aRestartKeepsTheSameDueTime() throws {
        let (rig, writes) = LookFeel.rig(looks: 6, hours: 3, seed: 17)
        LookFeel.changes(rig, 2)
        let last = try #require(writes.all.last)
        let due = try #require(rig.scheduler.nextLookChange)
        var draws = 0
        let loaded = AgentState(position: SavedPosition(), persisted: last)
            .persisted(catalog: LookFeel.catalog(looks: 6), nowEpoch: last.lookSince + 600, lookEveryHours: 3, draw: { draws += 1; return 0.999 })
        #expect(draws == 0, "a factor in the file is read, never redrawn")
        #expect(loaded.lookDueFactor == last.lookDueFactor, "the persisted factor itself is unchanged after the restart")
        let restarted = SchedulerRig(catalog: LookFeel.catalog(looks: 6), settings: LookFeel.settings(hours: 3), seed: 77, persisted: loaded,
                                     startWall: last.lookSince + 600)
        #expect(restarted.scheduler.persisted.lookDueFactor == last.lookDueFactor)
        #expect(restarted.scheduler.nextLookChange == due, "the same absolute due time")
    }

    @Test func LookJitter_aMissingOrBadFactorIsDrawnOnceAndPersisted() throws {
        let position = SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1)
        for (name, factor) in [("missing", nil), ("not finite", Double.nan), ("below the band", 0.1), ("above the band", 3.0), ("infinite", Double.infinity)] as [(String, Double?)] {
            var draws = 0
            let state = AgentState(position: position, look: "plain", lookSince: 1_799_999_000, lookDueFactor: factor)
            let loaded = state.persisted(catalog: LookFeel.catalog(looks: 3), nowEpoch: 1_800_000_000, lookEveryHours: 2, draw: { draws += 1; return 0.5 })
            #expect(draws == 1 && loaded.lookDueFactor == 1.0, "\(name): drawn once")
            #expect(loaded.lookDueAt == 1_799_999_000.0 + 7200.0, "\(name): the absolute due time follows: \(String(describing: loaded.lookDueAt)) \(loaded.lookDueFactor) \(loaded.lookSince)")
        }
    }

    @MainActor
    @Test func LookJitter_aMissingFactorIsPersistedAtOnceByTheRuntime() throws {
        // Through the runtime: the file of an older build is rewritten at once with an in-band factor and a due time.
        let position = SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1)
        let rig = try RuntimeRig(state: AgentState(position: position, look: "plain", lookSince: Date().timeIntervalSince1970 - 100))
        let written = try rig.state
        let factor = try #require(written.lookDueFactor, "the drawn factor is persisted at start")
        #expect(factor >= 0.75 && factor <= 1.25 && written.lookDueAt != nil && written.lookUsed == ["plain"], "\(written)")
    }

    @Test func LookJitter_aChangedLookEverySettingMovesTheDueTimeLive() throws {
        let (rig, writes) = LookFeel.rig(looks: 6, hours: 2, seed: 19)
        LookFeel.changes(rig, 1)
        let last = try #require(writes.all.last)
        let before = try #require(rig.scheduler.nextLookChange)
        rig.scheduler.update(settings: LookFeel.settings(hours: 4))
        let after = try #require(rig.scheduler.nextLookChange)
        #expect(abs(after.timeIntervalSince(before) - 2 * 3600 * last.lookDueFactor) < 1e-6, "the same factor applies to the new setting")
        #expect(rig.scheduler.persisted.lookDueAt == last.lookSince + 4 * 3600 * last.lookDueFactor)
    }

    @Test func LookJitter_schedulerStatusGetterUsesTheDueHelper() throws {
        let (rig, _) = LookFeel.rig(looks: 6, hours: 3, seed: 23)
        LookFeel.changes(rig, 2)
        let mono = try #require(rig.scheduler.lookDueMono())
        let date = try #require(rig.scheduler.nextLookChange)
        let converted = rig.wall + (mono - rig.now)
        #expect(abs(date.timeIntervalSince1970 - converted) < 1e-6, "nextLookChange \(date.timeIntervalSince1970) against the scheduler's own deadline \(converted)")
        #expect(rig.scheduler.persisted.lookDueFactor != 1.0)
    }

    @MainActor
    @Test func LookJitter_agentWritesQuietReasonAndDueEpochToStatus() throws {
        let position = SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1)
        let rig = try RuntimeRig(state: AgentState(position: position, look: "plain", lookSince: Date().timeIntervalSince1970 - 100))
        let due = try #require(rig.stage.scheduler.nextLookChange, "the scheduler has a due time after start").timeIntervalSince1970
        let started = try rig.status
        #expect(started.quiet == "none", "no quiet reason is active at start: \(String(describing: started.quiet))")
        #expect(started.nextLookChange == due, "status.json carries the scheduler's own due epoch: \(String(describing: started.nextLookChange)) against \(due)")
        rig.stage.setQuiet(.examBrowser, active: true)
        let quiet = try rig.status
        #expect(quiet.quiet == "exam-browser", "the raised reason is written: \(String(describing: quiet.quiet))")
        #expect(quiet.nextLookChange == rig.stage.scheduler.nextLookChange?.timeIntervalSince1970)
    }

    @Test func LookJitter_eachCommitAndUnpinDrawsANewFactor() {
        let (rig, writes) = LookFeel.rig(looks: 8, hours: 2, seed: 29)
        LookFeel.changes(rig, 5)
        let factors = writes.all.map(\.lookDueFactor)
        #expect(Set(factors).count == factors.count, "every commit has its own factor: \(factors)")
        rig.scheduler.update(settings: LookFeel.settings { $0.lookPin = "l07" })
        _ = rig.run(upTo: 300) { rig.scheduler.look == "l07" }
        let pinned = rig.scheduler.persisted.lookDueFactor
        rig.scheduler.update(settings: LookFeel.settings())
        let unpinned = rig.scheduler.persisted
        #expect(unpinned.lookDueFactor != pinned && unpinned.lookSince == rig.wall, "unpinning draws a new factor and restarts the interval")
        #expect(unpinned.lookDueAt == unpinned.lookSince + 7200 * unpinned.lookDueFactor)
    }

    @Test func LookJitter_existingFixturesWithFactorOneKeepTheirDueTime() throws {
        let wall = 1_800_000_000.0
        let rig = SchedulerRig(catalog: LookFeel.catalog(looks: 6), settings: LookFeel.settings(hours: 2),
                               persisted: SchedulerPersisted(look: "l00", lookSince: wall - 3600))
        #expect(rig.scheduler.nextLookChange == Date(timeIntervalSince1970: wall - 3600 + 7200), "since + the setting, exactly")
        rig.advance(3500)
        #expect(LookFeel.worn(rig).isEmpty)
        rig.advance(200)
        #expect(LookFeel.worn(rig).count == 1)
    }

    @Test func LookJitter_aBackwardClockJumpRebasesTheDueTimeExactlyOnce() throws {
        let (rig, writes) = LookFeel.rig(looks: 6, hours: 2, seed: 33)
        LookFeel.changes(rig, 1)
        let before = try #require(writes.all.last)
        // a jump of 30 s is inside the tolerance: nothing moves
        rig.clock.wallNow = rig.clock.wallNow.addingTimeInterval(before.lookSince - rig.wall - 30)
        let count = writes.all.count
        rig.scheduler.refresh()
        #expect(writes.all.count == count && rig.scheduler.persisted.lookSince == before.lookSince, "30 s back is not a jump")
        // three hours back
        rig.clock.wallNow = rig.clock.wallNow.addingTimeInterval(-3 * 3600)
        rig.scheduler.refresh()
        let now = rig.wall
        #expect(writes.all.count == count + 1, "one rebase, one write")
        #expect(rig.scheduler.persisted.lookSince == now && rig.scheduler.persisted.lookDueAt == now + 7200 * before.lookDueFactor, "to now, keeping the factor")
        #expect(rig.scheduler.persisted.lookDueFactor == before.lookDueFactor)
        for _ in 0..<5 { rig.advance(60); rig.scheduler.refresh(); _ = rig.scheduler.nextLookChange; _ = rig.scheduler.lookDueMono() }
        #expect(writes.all.count == count + 1, "repeated evaluations do not move it again")
        #expect(rig.scheduler.persisted.lookSince == now)
        #expect(LookFeel.worn(rig).count == 1, "and no change was made by the jump")
    }

    @Test func LookJitter_aRestartAfterABackwardJumpReadsTheRebasedDueTime() throws {
        let (rig, writes) = LookFeel.rig(looks: 6, hours: 2, seed: 35)
        LookFeel.changes(rig, 1)
        rig.clock.wallNow = rig.clock.wallNow.addingTimeInterval(-5 * 3600)
        rig.scheduler.refresh()
        let rebased = try #require(writes.all.last)
        let due = try #require(rig.scheduler.nextLookChange)
        let loaded = AgentState(position: SavedPosition(), persisted: rebased)
            .persisted(catalog: LookFeel.catalog(looks: 6), nowEpoch: rig.wall + 5, lookEveryHours: 2, draw: { 0.5 })
        let restarted = SchedulerRig(catalog: LookFeel.catalog(looks: 6), settings: LookFeel.settings(hours: 2), persisted: loaded, startWall: rig.wall + 5)
        #expect(restarted.scheduler.nextLookChange == due)
        #expect(restarted.scheduler.persisted.lookSince == rebased.lookSince)
    }

    @Test func LookJitter_aRestartRightAfterABackwardJumpKeepsTheFactor() throws {
        let (rig, writes) = LookFeel.rig(looks: 6, hours: 2, seed: 35)
        LookFeel.changes(rig, 1)
        let last = try #require(writes.all.last)
        rig.clock.wallNow = rig.clock.wallNow.addingTimeInterval(-5 * 3600)
        // Restart before refresh() can rebase anything in the old process.
        #expect(rig.scheduler.persisted == last)
        let now = rig.wall
        var draws = 0
        let data = try JSONEncoder().encode(AgentState(position: SavedPosition(), persisted: last))
        let loaded = try JSONDecoder().decode(AgentState.self, from: data)
            .persisted(catalog: LookFeel.catalog(looks: 6), nowEpoch: now, lookEveryHours: 2, draw: { draws += 1; return 0.999 })
        #expect(draws == 0 && loaded.lookDueFactor == last.lookDueFactor)
        #expect(loaded.look == last.look && loaded.lookUsed == last.lookUsed)
        #expect(loaded.lookSince == now && loaded.lookDueAt == now + 7200 * last.lookDueFactor)
        let restarted = SchedulerRig(catalog: LookFeel.catalog(looks: 6), settings: LookFeel.settings(), persisted: loaded, startWall: now)
        var rebases = 0
        restarted.scheduler.onPersist = { _ in rebases += 1 }
        for _ in 0..<5 { restarted.advance(60); restarted.scheduler.refresh() }
        #expect(rebases == 0 && restarted.scheduler.persisted == loaded, "the startup rebase never moves again")
        let again = AgentState(position: SavedPosition(), persisted: loaded)
            .persisted(catalog: LookFeel.catalog(looks: 6), nowEpoch: restarted.wall, lookEveryHours: 2, draw: { draws += 1; return 0 })
        #expect(again == loaded && draws == 0, "another restart reads the same rebased clock and factor")
    }

    @Test func LookJitter_aForwardClockJumpFiresOnceAsOneEarlyChange() throws {
        let (rig, _) = LookFeel.rig(looks: 6, hours: 2, seed: 37)
        LookFeel.changes(rig, 1)
        rig.clock.wallNow = rig.clock.wallNow.addingTimeInterval(10 * 3600)
        rig.scheduler.refresh()
        rig.advance(120)
        #expect(LookFeel.worn(rig).count == 2, "the early change comes once")
        rig.advance(1.4 * 3600)
        #expect(LookFeel.worn(rig).count == 2, "and the next one is a full drawn interval away")
    }

    @Test func LookJitter_aRestartAfterAForwardJumpFiresOnceNotRepeatedly() throws {
        let (rig, writes) = LookFeel.rig(looks: 6, hours: 2, seed: 39)
        LookFeel.changes(rig, 1)
        let last = try #require(writes.all.last)
        let later = last.lookSince + 20 * 3600
        let loaded = AgentState(position: SavedPosition(), persisted: last)
            .persisted(catalog: LookFeel.catalog(looks: 6), nowEpoch: later, lookEveryHours: 2, draw: { 0.5 })
        let restarted = SchedulerRig(catalog: LookFeel.catalog(looks: 6), settings: LookFeel.settings(hours: 2), persisted: loaded, startWall: later)
        restarted.advance(300)
        #expect(LookFeel.worn(restarted).count == 1)
        restarted.advance(1.4 * 3600)
        #expect(LookFeel.worn(restarted).count == 1)
    }
}
