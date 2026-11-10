import Testing
import Foundation
import CoreGraphics
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Amendment "scheduler feel", D-1: after a multi-touch starts, clicks are ignored exactly while that reaction is the current activity.

enum FeelFixture {
    /// The fixture catalog with the multi-touch use moved from A6-turning (2.42 s) to a dizzy spell of the catalog's measured length (1.167 s,
    /// D5-dizzy) that every look may play, or with no multi-touch motion at all.
    static func catalog(dizzy: Bool, keepTurning: Bool = false) -> PetCatalog {
        let base = SchedulerFixture.catalog()
        var motions = base.motions.map { m -> CatalogMotion in
            var copy = m
            if m.id == "A6-turning", !keepTurning { copy.uses.remove(.multiTouch) }
            return copy
        }
        if dizzy {
            motions.append(CatalogMotion(id: "D5-dizzy", board: "D5", uses: [.multiTouch], frameCount: 14, duration: 1.167, overheadClear: true,
                                         compatibleLooks: Set(SchedulerFixture.looks)))
        }
        return PetCatalog(motions: motions, looks: base.looks)
    }
    static func calm() -> SchedulerSettings { SchedulerFixture.settings { $0.motion = .off } }
}

@Suite("Scheduler feel: clicks", .serialized)
struct SchedulerFeelClicks {
    /// Three clicks 0.3 s apart. Returns the time the multi-touch started and its length.
    private func dizzy(_ rig: SchedulerRig) -> (start: TimeInterval, end: TimeInterval) {
        rig.scheduler.click(); rig.advance(0.3); rig.scheduler.click(); rig.advance(0.3); rig.scheduler.click()
        let start = rig.now
        let playback = rig.frame.playback
        return (start, start + (playback?.duration ?? 0))
    }
    private func rig(dizzy withDizzy: Bool = true, keepTurning: Bool = false) -> SchedulerRig {
        SchedulerRig(catalog: FeelFixture.catalog(dizzy: withDizzy, keepTurning: keepTurning), settings: FeelFixture.calm())
    }

    @Test func Click_aClickDuringTheMultiTouchRunDoesNothing() {
        let rig = rig()
        let span = dizzy(rig)
        #expect(rig.frame.playback?.motionID == "D5-dizzy" && abs(span.end - span.start - 1.167) < 1e-9)
        let touches = rig.scheduler.counters.touches, events = rig.events.count, before = rig.frame.playback
        rig.advance(0.5); rig.scheduler.click()
        #expect(rig.scheduler.counters.touches == touches, "no touch counted")
        #expect(rig.frame.playback == before, "the reaction goes on unchanged")
        #expect(rig.count { $0 == .multiTouch } == 1 && rig.count { $0 == .touch } == 2)
        let after = rig.eventsSince(events).map(\.event)
        #expect(after == [.clickIgnored(reason: "multi-touch-playing")], "the only event is the log line: \(after)")
    }

    @Test func Click_aClickJustAfterTheMultiTouchRunEndsReacts() {
        let rig = rig()
        let span = dizzy(rig)
        rig.advance(span.end - rig.now + 0.05); rig.scheduler.click()
        #expect(rig.count { $0 == .touch } == 3 && rig.frame.playback?.use == "touch", "end + 50 ms is a touch")
        #expect(rig.count { if case .clickIgnored = $0 { return true } else { return false } } == 0)
    }

    @Test func Click_aClickAtTheExactEndReacts() {
        let rig = rig()
        let span = dizzy(rig)
        rig.clock.advance(span.end - rig.now)
        #expect(rig.now == span.end)
        rig.scheduler.click()
        #expect(rig.count { $0 == .touch } == 3 && rig.frame.playback?.use == "touch", "a click at the exact end reacts")
    }

    @Test func Click_clicksDuringTheRunAreNotCounted() {
        let rig = rig()
        let span = dizzy(rig)
        for _ in 0..<3 { rig.advance(0.25); rig.scheduler.click() }
        #expect(rig.now < span.end, "all three are inside the run")
        rig.advance(span.end - rig.now + 0.1); rig.scheduler.click()
        rig.advance(0.3); rig.scheduler.click()
        #expect(rig.count { $0 == .touch } == 4 && rig.count { $0 == .multiTouch } == 1, "two touches after the run, and no second multi-touch")
    }

    @Test func Click_threeFreshClicksAfterTheRunPlayTheNextMultiTouch() {
        let rig = rig()
        let span = dizzy(rig)
        rig.advance(span.end - rig.now + 0.05)
        rig.scheduler.click(); rig.advance(0.3); rig.scheduler.click(); rig.advance(0.3); rig.scheduler.click()
        #expect(rig.count { $0 == .multiTouch } == 2 && rig.frame.playback?.use == "multi-touch")
    }

    @Test func Click_aClickDuringATouchReactionStillStartsANewTouch() {
        let rig = rig()
        rig.scheduler.click()
        #expect(rig.frame.playback?.use == "touch")
        rig.advance(0.3); rig.scheduler.click()
        #expect(rig.count { $0 == .touch } == 2, "touch runs are never ignored")
        #expect(rig.count { if case .clickIgnored = $0 { return true } else { return false } } == 0)
    }

    @Test func Click_theLongerMultiTouchMotionIsIgnoredForItsWholeLengthOnly() {
        let rig = rig(dizzy: false, keepTurning: true)
        let span = dizzy(rig)
        #expect(rig.frame.playback?.motionID == "A6-turning" && abs(span.end - span.start - 2.42) < 1e-9)
        rig.advance(2.3); rig.scheduler.click()
        #expect(rig.count { $0 == .touch } == 2, "ignored until the end of the 2.42 s turn")
        rig.advance(0.2); rig.scheduler.click()
        #expect(rig.now - span.start < 3 && rig.count { $0 == .touch } == 3, "reacts at 2.5 s, where the old 3 s rule still ignored")
    }

    @Test func Click_aRunCutByADragEndsTheIgnoring() {
        let rig = rig()
        _ = dizzy(rig)
        rig.advance(0.2)
        rig.scheduler.dragStarted(); rig.advance(0.2); rig.scheduler.dragEnded()
        rig.scheduler.click()
        #expect(rig.count { $0 == .touch } == 3, "the multi-touch run ended with the drag: this click reacts")
        #expect(rig.count { if case .clickIgnored = $0 { return true } else { return false } } == 0)
    }

    @Test func Click_anIgnoredClickLogsOneLineAndNoTouch() throws {
        let clock = VirtualClock(now: 1000)
        let timer = FakeScheduler(clock: clock)
        let runtime = try StageRuntime(clock: clock, timer: timer, art: artDirectory, settings: FeelFixture.calm(), geometry: Screens.geometry(),
                                       random: { 0.3 })
        var lines: [String] = []
        runtime.log = { lines.append($0) }
        runtime.hostGeometry = { StageHostGeometry(geometry: Screens.geometry(), pixelScale: 2) }
        runtime.start()
        func click() { runtime.perform { runtime.scheduler.click() } }
        click(); clock.advance(0.3); click(); clock.advance(0.3); click()
        #expect(lines.filter { $0 == "TOUCH multi" }.count == 1)
        #expect(runtime.lastRequest?.frame.playback?.use == "multi-touch")
        let touches = lines.filter { $0 == "TOUCH" }.count
        clock.advance(0.2); click()
        #expect(lines.filter { $0 == "CLICK-IGNORED why=multi-touch-playing" }.count == 1, "one line: \(lines)")
        #expect(lines.filter { $0 == "TOUCH" }.count == touches, "and no TOUCH line")
    }
}
