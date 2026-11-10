import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Amendment "scheduler feel", D-1, through the real PetPanel input path (button-down of a repeated click, button-up of the first click of a
// series). The tests run the runtime on a virtual clock and a fake timer (`RuntimeRig(virtual: true)`), so time moves only by `rig.advance` and
// every bound is an exact virtual-time check; one smoke test per area runs on the system clock with a generous bound, to keep the production wiring covered.

@MainActor
private final class Stamps {
    enum Kind: Equatable { case touch, multi, ignored }
    var all: [(at: TimeInterval, kind: Kind)] = []
    func attach(to rig: RuntimeRig) {
        let original = rig.stage.scheduler.onEvent
        rig.stage.scheduler.onEvent = { [unowned self] at, event in
            switch event {
            case .touch: self.all.append((at, .touch))
            case .multiTouch: self.all.append((at, .multi))
            case .clickIgnored: self.all.append((at, .ignored))
            default: break
            }
            original?(at, event)
        }
    }
}

/// A global point on Clawd's body in the picture on screen, or nil (RuntimeRig.points() records an issue when there is none).
@MainActor
private func bodyPoint(_ rig: RuntimeRig) -> CGPoint? {
    guard let frame = rig.stage.lastFrame else { return nil }
    var y = frame.panelFrame.minY + 0.5
    while y < frame.panelFrame.maxY {
        var x = frame.panelFrame.minX + 0.5
        while x < frame.panelFrame.maxX {
            let p = CGPoint(x: x, y: y)
            if frame.hit.containsBody(p) { return p }
            x += 1
        }
        y += 1
    }
    return nil
}

@Suite("Scheduler feel: clicks through the runtime", .serialized)
@MainActor
struct SchedulerFeelClickRuntime {
    /// Three clicks as the real input path takes them (first on button-up, the repeats on button-down). Returns the scheduler-clock time the
    /// multi-touch reaction ends, or nil when this machine was too slow to fit three clicks in the 2 s window in any of the tries.
    private func makeDizzy(_ rig: RuntimeRig, _ stamps: Stamps) throws -> TimeInterval? {
        for _ in 1...6 {
            stamps.all.removeAll()
            for n in 1...3 {
                guard let point = bodyPoint(rig) else {
                    Issue.record("click \(n): no body pixel (playback \(String(describing: rig.stage.lastRequest?.frame.playback)), frame \(rig.stage.lastFrame == nil ? "none" : "some"), stamps \(stamps.all))")
                    return nil
                }
                try rig.click(at: point, clicks: n)
            }
            if stamps.all.last?.kind == .multi, let playback = rig.stage.lastRequest?.frame.playback, playback.use == "multi-touch" {
                return playback.startedAt + playback.duration
            }
            Thread.sleep(forTimeInterval: PetScheduler.multiTouchWindow + 0.2)
        }
        return nil
    }

    @Test func Click_runtime_smoke_aMashOnTheSystemClock() throws {
        let rig = try plainRig(virtual: false)
        let stamps = Stamps(); stamps.attach(to: rig)
        // One quick repeat (button-down path) inside the reaction; then, past its end, a quick repeat and a first click (button-up path). Two
        // clicks after the end are no new dizzy spell. A machine too slow to get the first one in before the end tries the whole run again;
        // when every try is used up without the case being set up, the test fails.
        for attempt in 1...6 {
            guard let end = try makeDizzy(rig, stamps) else {
                Issue.record("Click_runtime_aMash: no run of three clicks fitted the 2 s window, so no dizzy reaction ever started")
                return
            }
            let touchLines = rig.lines("TOUCH").count, ignoredLines = rig.lines("CLICK-IGNORED").count
            stamps.all.removeAll()
            try rig.click(at: try #require(bodyPoint(rig)), clicks: 2)
            guard stamps.all.last.map({ $0.at < end }) == true else {
                // Slow machine: the click came after the reaction had ended. Try the whole run again.
                Thread.sleep(forTimeInterval: PetScheduler.multiTouchWindow + 0.2)
                if attempt == 6 { Issue.record("Click_runtime_aMash: in all 6 attempts the repeat click landed after the reaction had ended, so no click was ever delivered inside it") }
                continue
            }
            while rig.stage.clock.now < end + 0.05 { Thread.sleep(forTimeInterval: 0.02) }
            try rig.click(at: try #require(bodyPoint(rig)), clicks: 2)
            try rig.click(at: try #require(bodyPoint(rig)))
            let clicks = stamps.all
            #expect(clicks.map(\.kind) == [.ignored, .touch, .touch], "the click inside the run is dropped, the two after its end react: \(clicks)")
            #expect(rig.lines("CLICK-IGNORED").count - ignoredLines == 1, "one CLICK-IGNORED line for the dropped click")
            #expect(rig.lines("TOUCH").count - touchLines == 2, "and a TOUCH line for each click that reacted, none for the dropped one")
            return
        }
    }

    /// The runtime wearing plain, with its look clock just started: these tests name the multi-touch motions (D5-dizzy, A6-turning), which plain
    /// can play, while a random worn look (wizard, say) has neither and plays a touch motion in their place. "Just started" is read on the clock the
    /// runtime runs on: a virtual clock's wall time is not today's date, and a lookSince from Date() would make the next look change due at once.
    private func plainRig(virtual: Bool, control: [String: Any]? = nil) throws -> RuntimeRig {
        let home = SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1)
        let since = (virtual ? VirtualClock().wallNow : Date()).timeIntervalSince1970
        return try RuntimeRig(state: AgentState(position: home, look: "plain", lookSince: since), control: control, virtual: virtual)
    }

    /// Three clicks as the real input path takes them, at one virtual instant: the third one starts the multi-touch reaction. Returns the
    /// scheduler-clock time the reaction ends. Nothing here can be too slow, so there is no retry.
    private func makeDizzyVirtual(_ rig: RuntimeRig, _ stamps: Stamps) throws -> TimeInterval {
        stamps.all.removeAll()
        // The entrance plays when Clawd first shows and takes no click; it is over well within this much virtual time.
        rig.advance(3)
        stamps.all.removeAll()
        for n in 1...3 { try rig.click(at: try #require(bodyPoint(rig), "click \(n): no body pixel"), clicks: n) }
        try #require(stamps.all.last?.kind == .multi, "the third click inside the window starts the reaction: \(stamps.all)")
        let playback = try #require(rig.stage.lastRequest?.frame.playback)
        try #require(playback.use == "multi-touch")
        return playback.startedAt + playback.duration
    }

    /// The boundary itself, through the real input path: one clock tick (the next smaller Double) before the reaction's end a click is
    /// still dropped, and a click at the end instant itself reacts, so an ignoring window any amount longer or shorter than the reaction fails here.
    @Test func Click_runtime_aClickJustBeforeTheEndIsDroppedAndOneAtTheExactEndReacts() throws {
        let rig = try plainRig(virtual: true)
        let stamps = Stamps(); stamps.attach(to: rig)
        let end = try makeDizzyVirtual(rig, stamps)
        stamps.all.removeAll()
        rig.advance(to: end.nextDown)
        #expect(rig.stage.clock.now == end.nextDown)
        try rig.click(at: try #require(bodyPoint(rig)))
        #expect(stamps.all.map(\.kind) == [.ignored], "one tick before the end the click is dropped: \(stamps.all)")
        stamps.all.removeAll()
        rig.advance(to: end)
        #expect(rig.stage.clock.now == end)
        try rig.click(at: try #require(bodyPoint(rig)))
        #expect(stamps.all.map(\.kind) == [.touch], "at the exact end the click reacts: \(stamps.all)")
    }

    @Test func Click_runtime_aMashAcrossTheReactionBoundaryDropsExactlyTheClicksInsideIt() throws {
        let rig = try plainRig(virtual: true)
        let stamps = Stamps(); stamps.attach(to: rig)
        let end = try makeDizzyVirtual(rig, stamps)
        let touchLines = rig.lines("TOUCH").count, ignoredLines = rig.lines("CLICK-IGNORED").count
        // One quick repeat (button-down path) inside the reaction; then, past its end, a quick repeat and a first click (button-up path). Two
        // clicks after the end are no new dizzy spell.
        stamps.all.removeAll()
        rig.advance(0.5)
        #expect(rig.stage.clock.now < end, "the reaction is still running 0.5 s of virtual time after it began")
        try rig.click(at: try #require(bodyPoint(rig)), clicks: 2)
        #expect(stamps.all.map(\.kind) == [.ignored], "the repeat inside the run is dropped: \(stamps.all)")
        rig.advance(end - rig.stage.clock.now + 0.05)
        try rig.click(at: try #require(bodyPoint(rig)), clicks: 2)
        try rig.click(at: try #require(bodyPoint(rig)))
        let clicks = stamps.all
        #expect(clicks.map(\.kind) == [.ignored, .touch, .touch], "the click inside the run is dropped, the two after its end react: \(clicks)")
        #expect(rig.lines("CLICK-IGNORED").count - ignoredLines == 1, "one CLICK-IGNORED line for the dropped click")
        #expect(rig.lines("TOUCH").count - touchLines == 2, "and a TOUCH line for each click that reacted, none for the dropped one")
    }

    @Test func Click_runtime_aSceneASleepOrAMenuInterruptingTheReactionEndsTheIgnoring() throws {
        // Each reaction (A6-turning 2.42 s, D5-dizzy 1.167 s) is interrupted by a scene and by the menu; a sleep only interrupts the long one,
        // because the entrance after a sleep plays before Clawd can be clicked again and outlasts what the short one has left.
        let cases = [("scene", "A6-turning"), ("scene", "D5-dizzy"), ("menu", "A6-turning"), ("menu", "D5-dizzy"), ("sleep", "A6-turning")]
        for (how, motion) in cases {
            let other = motion == "A6-turning" ? "d5-dizzy" : "a6-turning"
            let rig = try plainRig(virtual: true, control: ["excluded": [other], "generation": 0])
            let stamps = Stamps(); stamps.attach(to: rig)
            let end = try makeDizzyVirtual(rig, stamps)
            #expect(rig.stage.lastRequest?.frame.playback?.motionID == motion, "\(how): \(motion) plays")
            #expect(rig.stage.clock.now < end - 0.3, "\(how): the reaction has more than 0.3 s left when it is interrupted")
            switch how {
            case "scene":
                rig.stage.perform { rig.stage.scheduler.sceneChanged(.listening, lease: 1) }
                rig.stage.perform { rig.stage.scheduler.sceneChanged(.idle, lease: nil) }
            case "sleep":
                rig.stage.setQuiet(.systemAsleep, active: true)
                rig.stage.setQuiet(.systemAsleep, active: false)
            default:
                rig.stage.perform { _ = rig.stage.scheduler.menuOpened() }
                rig.stage.perform { rig.stage.scheduler.menuClosed() }
            }
            let ignored = rig.lines("CLICK-IGNORED").count
            stamps.all.removeAll()
            // After a sleep the entrance plays first and has no body pixel to hit for a moment: the pictures come from the runtime's own
            // timer, which the test fires by advancing (at most 5 s of virtual time, in 20 ms steps).
            var waited = 0.0
            while (bodyPoint(rig) == nil || rig.stage.lastRequest?.frame.playback?.use == "entrance") && waited < 5 { rig.advance(0.02); waited += 0.02 }
            let point = try #require(bodyPoint(rig), "\(how): no body pixel on screen after the interruption (playback \(String(describing: rig.stage.lastRequest?.frame.playback)))")
            try rig.click(at: point)
            let delivered = try #require(stamps.all.last?.at)
            #expect(delivered < end, "\(how): the interrupting click lands before the reaction's original end (\(delivered) < \(end)), so it proves the interruption")
            #expect(stamps.all.map(\.kind) == [.touch], "\(how): the reaction was cut, so the next click is judged by the new activity: \(stamps.all)")
            #expect(rig.lines("CLICK-IGNORED").count == ignored, "\(how): no ignored click")
        }
    }
}
