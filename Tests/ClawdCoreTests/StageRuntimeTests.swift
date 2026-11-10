import Testing
import Foundation
import CoreGraphics
import ClawdCore
import ClawdRendering
import ClawdDesktop

// MARK: one real timer for every wake

@Suite("Merged wake")
struct MergedWakeSuite {
    @Test func Merged_oneRealTimerServesEverySourceAndTheEarliestWins() {
        let clock = VirtualClock(), timer = FakeScheduler(clock: clock)
        let wake = MergedWake(timer: timer, clock: clock)
        let a = wake.makeSlot(), b = wake.makeSlot(), c = wake.makeSlot()
        a.arm(after: 5, leeway: 1); b.arm(after: 2, leeway: 0.005); c.arm(after: 9, leeway: 0)
        #expect(timer.fireAt == 2); #expect(timer.leeway == 0.005); #expect(wake.armedTimers == 1)
        b.cancel()
        #expect(timer.fireAt == 5, "the next earliest takes over when the earliest is cancelled")
        a.cancel(); c.cancel()
        #expect(timer.fireAt == nil); #expect(wake.armedTimers == 0)
        #expect(wake.maxArmedTimers == 1, "never more than one armed timer")
    }
    @Test func Merged_theTimerLeewayNeverLetsALaterSlotWaitPastItsOwnLeeway() {
        let clock = VirtualClock(), timer = FakeScheduler(clock: clock)
        let wake = MergedWake(timer: timer, clock: clock)
        let blink = wake.makeSlot(), frame = wake.makeSlot()
        blink.arm(after: 1.000, leeway: 1)
        #expect(timer.leeway == 1, "a blink alone keeps its long leeway: the idle wake-ups stay cheap")
        frame.arm(after: 1.010, leeway: 0.005)
        #expect(timer.fireAt == 1.000)
        #expect(timer.leeway <= 0.015 + 1e-9, "the frame slot behind the blink is at most 15 ms late, not 1 s")
        #expect(timer.leeway >= 0)
        frame.cancel()
        #expect(timer.leeway == 1)
    }
    @Test func Merged_aBatchRearmsOnce() {
        let clock = VirtualClock(), timer = FakeScheduler(clock: clock)
        let wake = MergedWake(timer: timer, clock: clock)
        let a = wake.makeSlot(), b = wake.makeSlot()
        wake.batch { a.arm(after: 3, leeway: 0); b.arm(after: 1, leeway: 0); a.cancel(); a.arm(after: 7, leeway: 0) }
        #expect(timer.armCount == 1, "four slot changes inside a batch cost one re-arm")
        #expect(timer.fireAt == 1)
    }
    @Test func Merged_aSlotThatIsNotAllowedIsIgnoredAndAFiredDeadlineIsForgotten() {
        let clock = VirtualClock(), timer = FakeScheduler(clock: clock)
        let wake = MergedWake(timer: timer, clock: clock)
        let a = wake.makeSlot(), b = wake.makeSlot()
        var allowed = false
        a.allowed = { allowed }
        a.arm(after: 1, leeway: 0)
        #expect(timer.fireAt == nil, "a quiet condition: the slot arms nothing")
        allowed = true; a.arm(after: 1, leeway: 0); b.arm(after: 4, leeway: 0)
        clock.advance(1.5); timer.cancel(); wake.fired()
        #expect(a.armedAt == nil, "a deadline that has passed is forgotten, so a source that does not re-arm cannot fire the timer again")
        #expect(b.armedAt != nil)
    }
}

// MARK: the integrated runtime on a virtual clock

private final class Probe {
    let clock = VirtualClock()
    let timer: FakeScheduler
    let run: IdleRenderRun
    var frames: [(at: Double, frame: StageFrame)] = []
    var playbacks: [MotionPlayback?] = []
    var blinkFrames = 0
    var lines: [String] = []
    init(motion: MotionLevel = .lively, seed: UInt64 = 7, walk: Bool = true, lookDueIn: Double? = nil, quiet: QuietReason? = nil,
         inputIdle: (() -> TimeInterval?)? = nil, pixelScale: Double = 2) throws {
        timer = FakeScheduler(clock: clock)
        var options = HeadlessOptions(); options.motion = motion; options.seed = seed; options.walk = walk; options.lookDueIn = lookDueIn
        run = try IdleRenderRun(clock: clock, scheduler: timer, art: artDirectory, options: options, pixelScale: pixelScale)
        let original = run.runtime.present
        run.runtime.present = { [unowned self] stage in
            self.frames.append((self.clock.now, stage)); self.playbacks.append(self.run.runtime.lastRequest?.frame.playback)
            if self.run.runtime.lastRequest?.blink == true { self.blinkFrames += 1 }
            original(stage)
        }
        run.runtime.log = { [unowned self] line in self.lines.append(line) }
        run.controller.machine.onChange = { [unowned self] _ in self.run.runtime.sceneChanged() }
        if let inputIdle { run.runtime.scheduler.inputIdle = inputIdle }
        run.runtime.setQuiet(.aquaNotRunning, active: false)
        run.runtime.start()
        if let quiet { run.runtime.setQuiet(quiet, active: true) }
    }
    var runtime: StageRuntime { run.runtime }
    func advance(_ seconds: Double) { advanceVirtual(clock: clock, scheduler: timer, runtime: runtime, by: seconds) }
    func advance(until condition: () -> Bool, limit: Double = 400, step: Double = 0.25) {
        var spent = 0.0
        while !condition(), spent < limit { advance(step); spent += step }
    }
    func lines(_ prefix: String) -> [String] { lines.filter { $0.hasPrefix(prefix) } }
}

@Suite("Stage runtime", .serialized)
struct StageRuntimeSuite {
    @Test func Runtime_aWalkMovesTheCanvasAlongTheBottomAtTheDeclaredSpeedAndComesHome() throws {
        let probe = try Probe()
        probe.advance(until: { !probe.lines("WALK start").isEmpty })
        #expect(!probe.lines("WALK start").isEmpty, "seed 7 at lively starts a walk in its first slot")
        let geometry = HeadlessStage.geometry()
        let home = geometry.homeOrigin
        probe.advance(until: { !probe.lines("WALK end").isEmpty }, limit: 120, step: 0.5)
        #expect(!probe.lines("WALK end").isEmpty)
        let homeY = try #require(probe.frames.first).frame.canvas.minY
        let moved = probe.frames.filter { abs($0.frame.canvas.minX - home.x) > 0.1 }
        #expect(moved.count > 10, "the canvas moved along x on many frames")
        for (_, frame) in probe.frames {
            #expect(frame.canvas.minY == homeY, "a walk never changes the height")
            #expect(geometry.visibleFrame.contains(frame.panelFrame), "the window stays inside the visible frame")
            #expect(frame.canvas.minX <= home.x + 0.01, "from Aqua's default spot, which sits at the keep-out band, walks go away from it")
        }
        // Speed over the outbound leg: from the first frame that moved to the first frame at the farthest point.
        let first = try #require(probe.frames.first { abs($0.frame.canvas.minX - home.x) > 0.1 })
        let farthest = try #require(probe.frames.map { abs($0.frame.canvas.minX - home.x) }.max())
        let arrival = try #require(probe.frames.first { abs(abs($0.frame.canvas.minX - home.x) - farthest) < 0.01 })
        let seconds = arrival.at - first.at
        #expect(seconds > 1)
        let speed = farthest / seconds
        // The leg is sized to whole step cycles: the declared speed changes by at most 15 % (3 pt/s of measuring noise on top).
        #expect(abs(speed - StageRuntime.walkSpeedWhenStrideUndeclared) < 0.15 * StageRuntime.walkSpeedWhenStrideUndeclared + 3, "outbound speed \(speed) pt/s against \(StageRuntime.walkSpeedWhenStrideUndeclared)")
        let last = try #require(probe.frames.last)
        #expect(abs(last.frame.canvas.minX - home.x) <= 0.25, "back at home when the walk is over (on the device grid)")
    }
    @Test func Runtime_aDictationStartingDuringAWalkStopsItWhereItStandsAndShowsTheBubbleAtOnce() throws {
        let probe = try Probe()
        probe.advance(until: { !probe.lines("WALK start").isEmpty })
        probe.advance(until: { (probe.frames.last?.frame.canvas.minX ?? 0) < HeadlessStage.geometry().homeOrigin.x - 20 }, limit: 20, step: 0.1)
        let before = try #require(probe.frames.last).frame.canvas.minX
        probe.run.controller.receive(line: startLine(probe.clock).trimmingCharacters(in: .newlines))
        let after = try #require(probe.frames.last)
        #expect(abs(after.frame.canvas.minX - before) <= 3, "Clawd stops where it is (at most one frame step on): \(before) -> \(after.frame.canvas.minX)")
        #expect(after.frame.bubble != nil, "the bubble shows at once")
        let stopped = after.frame.canvas.minX
        probe.advance(3)
        #expect(try #require(probe.frames.last).frame.canvas.minX == stopped, "and stays there for the whole dictation")
    }
    @Test func Runtime_aClickPlaysATouchReactionAndThreeQuickClicksMakeClawdDizzy() throws {
        let probe = try Probe(motion: .off)
        probe.advance(1)
        probe.runtime.perform { probe.runtime.scheduler.click() }
        #expect(probe.lines("TOUCH").count == 1); #expect(probe.lines("TOUCH multi").isEmpty)
        #expect(probe.runtime.lastRequest?.frame.playback?.use == "touch")
        probe.advance(0.3); probe.runtime.perform { probe.runtime.scheduler.click() }
        probe.advance(0.3); probe.runtime.perform { probe.runtime.scheduler.click() }
        #expect(probe.lines("TOUCH multi").count == 1, "the third click inside 2 s is the multi-touch reaction")
        #expect(probe.runtime.lastRequest?.frame.playback?.use == "multi-touch")
    }
    @Test func Runtime_aQuietConditionStopsEveryRenderAndEveryTimer() throws {
        let probe = try Probe()
        probe.advance(5)
        let renders = probe.runtime.renderCount
        probe.runtime.setQuiet(.screenLocked, active: true)
        #expect(probe.lines("QUIET on reason=screen-locked").count == 1)
        let rendersWhenQuiet = probe.runtime.renderCount
        #expect(probe.runtime.lastFrame == nil)
        #expect(probe.runtime.wake.armedTimers == 0, "nothing armed while the screen is locked")
        probe.advance(1000)
        #expect(probe.runtime.renderCount == rendersWhenQuiet, "no render for 1000 s of quiet (\(renders) before)")
        #expect(probe.timer.fireAt == nil)
        probe.runtime.setQuiet(.screenLocked, active: false)
        #expect(probe.runtime.lastFrame != nil); #expect(probe.runtime.wake.armedTimers == 1)
        #expect(probe.runtime.wake.maxArmedTimers == 1)
        probe.advance(30)
        #expect(probe.runtime.renderCount > rendersWhenQuiet)
    }
    @Test func Runtime_reduceMotionStopsIdleLifeWalksAndTransitions() throws {
        let probe = try Probe(lookDueIn: 5)
        probe.runtime.setReduceMotion(true)
        probe.advance(300)
        #expect(probe.lines("MOTION start").isEmpty); #expect(probe.lines("WALK start").isEmpty)
        #expect(probe.lines("LOOK change").count == 1, "the look still changes, as a cut")
        #expect(!probe.playbacks.contains { playback in
            if case .transition? = playback?.source { return true } else { return false }
        })
    }
    @Test func Runtime_onlyTheDrawnBubbleStylesAreEverOffered() throws {
        let probe = try Probe(motion: .off)
        for lease in 1...120 {
            probe.run.controller.receive(line: startLine(probe.clock, lease: lease).trimmingCharacters(in: .newlines))
            probe.advance(0.2)
            probe.run.controller.receive(line: line(probe.clock, "DictationOrchestrator", "dictation.cancel_accepted lease_id=\(lease)").trimmingCharacters(in: .newlines))
            probe.advance(2.2)
        }
        let styles = Set(probe.lines("BUBBLE style=").compactMap { Int($0.dropFirst("BUBBLE style=".count)) })
        #expect(styles == StageRuntime.drawnBubbleStyles, "styles drawn from \(styles.sorted())")
        // The user's own exclusions still apply on top: with 2 to 15 excluded only style 1 is left.
        var settings = SchedulerSettings(); settings.bubbleExcluded = Set(2...15)
        probe.runtime.apply(settings: settings)
        let count = probe.lines("BUBBLE style=").count
        for lease in 300...330 {
            probe.run.controller.receive(line: startLine(probe.clock, lease: lease).trimmingCharacters(in: .newlines))
            probe.advance(0.2)
            probe.run.controller.receive(line: line(probe.clock, "DictationOrchestrator", "dictation.cancel_accepted lease_id=\(lease)").trimmingCharacters(in: .newlines))
            probe.advance(2.2)
        }
        let later = Set(probe.lines("BUBBLE style=").dropFirst(count).compactMap { Int($0.dropFirst("BUBBLE style=".count)) })
        #expect(later == [1])
    }
    @Test func Runtime_sleepIsDecidedByInputIdleTimeNotBySceneEvents() throws {
        var idle: TimeInterval = 700
        let probe = try Probe(motion: .quiet, inputIdle: { idle })
        probe.advance(2)
        #expect(probe.lines("SLEEP start").count == 1, "the user has been away 700 s: Clawd dozes off")
        #expect(probe.runtime.lastRequest?.frame.asleep == true)
        probe.advance(700)
        #expect(probe.lines("SLEEP wake").isEmpty, "still away: still asleep, and no idle motion ran")
        #expect(probe.lines("MOTION start").filter { !$0.contains("use=sleep-entry") }.isEmpty)
        idle = 5
        probe.advance(61)
        #expect(probe.lines("SLEEP wake").count == 1, "input is seen within the 60 s re-read")
    }
    @Test func Runtime_v1sOwnSleepTimerIsOffSoClawdStillBlinksAfterTenMinutesWithoutAquaEvents() throws {
        let probe = try Probe(motion: .off)
        probe.advance(8)
        let early = probe.blinkFrames
        #expect(early > 0, "Clawd blinks while it stands")
        probe.advance(700)
        #expect(probe.run.controller.machine.scene == .idle, "the scene machine never goes to its own SLEEP (that is the scheduler's, by input idle time)")
        let before = probe.blinkFrames
        probe.advance(30)
        #expect(probe.blinkFrames > before, "and it is still blinking more than ten minutes after the last Aqua event")
        #expect(!probe.runtime.scheduler.asleep)
    }
    @Test func Runtime_theLookChangeHappensOnceItIsDueAndIsLoggedForTheInstruments() throws {
        let probe = try Probe(motion: .quiet, lookDueIn: 20)
        probe.advance(120)
        let changes = probe.lines("LOOK change")
        #expect(changes.count == 1, "\(changes)")
        #expect(changes.first?.hasPrefix("LOOK change from=plain to=") == true)
        #expect(probe.runtime.wake.maxArmedTimers == 1)
    }
    @Test func Runtime_helmetOnPinsTheHelmetWithinSixtySecondsAndHelmetOffGoesBackToPlainAndRotationResumes() throws {
        let probe = try Probe(motion: .off)
        probe.runtime.hostGeometry = { nil }                         // only the schedule matters here: nothing is drawn
        let live = LiveSettings(runtime: probe.runtime, initial: AppliedSettings())
        var deferred: [() -> Void] = []
        live.deferred = { deferred.append($0) }
        probe.runtime.onEvent = { event in live.schedulerEvent(event) }
        var scheduler = SchedulerSettings(); scheduler.lookEveryHours = 2
        var control = AgentControl(); control.helmet = true
        live.apply(AppliedSettings(control: control, scheduler: scheduler))
        probe.advance(61)
        #expect(probe.lines("LOOK change from=plain to=helmet").count == 1, "helmet on: the helmet look within 60 s: \(probe.lines("LOOK"))")
        probe.advance(3600 * 3)
        #expect(probe.lines("LOOK change").count == 1, "pinned: the rotation stays still for three hours")
        control.helmet = false
        live.apply(AppliedSettings(control: control, scheduler: scheduler))
        probe.advance(61)
        #expect(probe.lines("LOOK change from=helmet to=plain").count == 1, "helmet off: back to plain within 60 s")
        #expect(deferred.count == 1, "the one-shot is dropped on the next turn of the run loop")
        deferred.forEach { $0() }
        #expect(live.effective.lookPin == nil)
        probe.advance(3600 * 2 + 120)
        #expect(probe.lines("LOOK change").count == 3, "rotation resumes after the pin is gone: \(probe.lines("LOOK change"))")
    }
    @Test func Runtime_theWholeSeededScheduleIsReproducible() throws {
        func schedule() throws -> [String] {
            let probe = try Probe(motion: .lively, seed: 11, lookDueIn: 100)
            probe.advance(400)
            return probe.lines.filter { $0.hasPrefix("MOTION start") || $0.hasPrefix("WALK start") || $0.hasPrefix("LOOK change") }
        }
        let first = try schedule(), second = try schedule()
        #expect(!first.isEmpty); #expect(first == second)
    }


    // MARK: the bubble's wake follows the picture, and the appearance (amendment D-6, D-8)

    /// Only style `style` is enabled (the user's exclusions on top of the drawn set), so a dictation always gets it.
    private func only(_ style: Int, _ probe: Probe) {
        var settings = SchedulerSettings(); settings.motion = .off
        settings.bubbleExcluded = Set(SchedulerSettings.bubbleStyles).subtracting([style])
        probe.runtime.apply(settings: settings)
    }
    private func thinking(_ probe: Probe, lease: Int = 1) {
        probe.run.controller.receive(line: startLine(probe.clock, lease: lease).trimmingCharacters(in: .newlines))
        probe.advance(0.2)
        probe.run.controller.receive(line: completedLine(probe.clock, lease: lease).trimmingCharacters(in: .newlines))
    }

    /// The host moves Clawd to a display too small for any placement clear of him: the bubble is still in the scheduler's frame, but nothing is drawn.
    private static func tiny() -> PetGeometry {
        let frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        return PetGeometry(scale: 1, homeOrigin: CGPoint(x: 8, y: 24), displayFrame: frame, visibleFrame: frame)
    }

    /// Walks `seconds` of virtual time firing the one timer at its own instants; returns the armed intervals and the renders it caused.
    private func walk(_ probe: Probe, _ seconds: Double) -> (renders: Int, armed: [Double], bubbleFrames: Int) {
        let before = probe.runtime.renderCount
        var armed: [Double] = [], bubbleSeen = 0
        let target = probe.clock.now + seconds
        var steps = 0
        while let fire = probe.timer.fireAt, fire <= target, steps < 20_000 {
            armed.append(((fire - probe.clock.now) * 1000).rounded() / 1000)
            probe.clock.advance(max(0, fire - probe.clock.now)); probe.timer.cancel(); probe.runtime.tick(); steps += 1
            if probe.runtime.lastFrame?.bubble != nil { bubbleSeen += 1 }
        }
        probe.clock.advance(max(0, target - probe.clock.now))
        return (probe.runtime.renderCount - before, armed, bubbleSeen)
    }

    /// D-8 (R1-3): the renderer's wake is armed from the picture just composed. A bubble that placement drops arms no wake, from its first frame or from the
    /// render after the host moved Clawd away. In both cases the next two seconds cost what the same run with the bubble switched off costs.
    @Test func StageRuntime_aBubbleThatPlacementDropsArmsNoBubbleWake() throws {
        for (case_, moveAfterShown) in [("no clear placement from the first frame", false), ("moved to a display too small after it was shown", true)] {
            func run(bubbleOn: Bool) throws -> (renders: Int, armed: [Double], bubbleShown: Bool) {
                let probe = try Probe(motion: .off, walk: false)
                only(13, probe)
                var settings = probe.runtime.settings; settings.bubble = bubbleOn; probe.runtime.apply(settings: settings)
                if !moveAfterShown { probe.runtime.hostGeometry = { StageHostGeometry(geometry: Self.tiny(), pixelScale: 2) } }
                thinking(probe)
                probe.advance(0.3)
                let shownBefore = probe.runtime.lastFrame?.bubble != nil
                if moveAfterShown {
                    #expect(!bubbleOn || shownBefore, "\(case_): the bubble was shown on the normal display")
                    probe.runtime.hostGeometry = { StageHostGeometry(geometry: Self.tiny(), pixelScale: 2) }
                    probe.runtime.renderNow()
                }
                #expect(probe.runtime.lastFrame?.bubble == nil, "\(case_): no bubble is drawn on the small display")
                let result = walk(probe, 2)
                #expect(result.bubbleFrames == 0, "\(case_): a bubble was drawn in \(result.bubbleFrames) frames of the walk, so the premise (nothing fits) does not hold")
                return (result.renders, result.armed, shownBefore)
            }
            let on = try run(bubbleOn: true), off = try run(bubbleOn: false)
            #expect(on.renders == off.renders, "\(case_): \(on.renders) renders over 2 s with the dropped bubble, \(off.renders) with the bubble off")
            #expect(on.armed == off.armed, "\(case_): armed intervals \(on.armed.prefix(8)) against \(off.armed.prefix(8))")
        }
    }

    /// D-6: an appearance change renders once when a bubble is shown, so the new palette is drawn from that frame on, and renders nothing and arms nothing
    /// otherwise, in a quiet condition included.
    @Test func StageRuntime_anAppearanceChangeRendersOnlyWhileABubbleIsShown() throws {
        let probe = try Probe(motion: .off, walk: false)
        only(13, probe)
        probe.advance(1)
        // no bubble on screen
        let rendersIdle = probe.runtime.renderCount, armedIdle = probe.timer.armCount
        probe.runtime.setAppearance(.dark)
        #expect(probe.runtime.renderCount == rendersIdle && probe.timer.armCount == armedIdle, "no bubble: no render and no timer")
        probe.runtime.setAppearance(.light)
        #expect(probe.runtime.renderCount == rendersIdle && probe.timer.armCount == armedIdle)
        // a bubble is shown
        probe.run.controller.receive(line: startLine(probe.clock).trimmingCharacters(in: .newlines))
        probe.advance(0.3)
        #expect(probe.runtime.lastFrame?.bubble != nil)
        let before = probe.runtime.renderCount
        probe.runtime.setAppearance(.dark)
        #expect(probe.runtime.renderCount == before + 1, "a bubble is shown: one render")
        #expect(probe.runtime.lastRequest?.content.appearance == .dark, "the new appearance is in the content of that render")
        probe.runtime.setAppearance(.dark)
        #expect(probe.runtime.renderCount == before + 1, "the same value again costs nothing")
        // a quiet condition: nothing is shown, nothing runs
        probe.runtime.setQuiet(.screenLocked, active: true)
        let rendersQuiet = probe.runtime.renderCount, armedQuiet = probe.timer.armCount
        probe.runtime.setAppearance(.light)
        #expect(probe.runtime.renderCount == rendersQuiet && probe.timer.armCount == armedQuiet && probe.runtime.wake.armedTimers == 0, "a quiet condition: 0 renders, 0 timers")
        probe.runtime.setQuiet(.screenLocked, active: false)
        #expect(probe.runtime.lastRequest?.content.appearance == .light, "and the value is the one the runtime holds when it shows again")
    }


    // MARK: the bubble's side (amendment D-1, D-5, E5)

    /// The side of the setting reaches the live bubble: a change while a bubble is shown draws that bubble on the new side in the next committed frame.
    @Test func StageRuntime_aSideChangeRedrawsTheShownBubbleWithinOneCommittedFrame() throws {
        for style in [1, 13, 15] {
            let probe = try Probe(motion: .off, walk: false, pixelScale: 2)
            only(style, probe)
            probe.runtime.hostGeometry = { StageHostGeometry(geometry: Screens.geometry(homeX: 640, homeY: 300), pixelScale: 2) }
            thinking(probe)
            probe.advance(0.3)
            #expect(probe.runtime.lastFrame?.bubble?.plan.side == .below, "style \(style): the default is below")
            var settings = probe.runtime.settings
            for side in [BubbleSide.left, .above, .right, .below] {
                let before = probe.runtime.renderCount
                settings.bubbleSide = side
                probe.runtime.apply(settings: settings)
                #expect(probe.runtime.renderCount == before + 1, "style \(style) \(side): one render")
                #expect(probe.runtime.lastRequest?.bubbleSide == side)
                #expect(probe.runtime.lastFrame?.bubble?.plan.side == side, "style \(style): chosen \(side), shown \(String(describing: probe.runtime.lastFrame?.bubble?.plan.side))")
                #expect(probe.runtime.bubbleMemory?.shown.side == side && probe.runtime.bubbleMemory?.context.side == side)
            }
        }
    }

    /// The menu action of the Side row moves the live bubble: the pick runs `bubble side X`, which lands in control.json and in LiveSettings; here the
    /// action's arguments are applied through LiveSettings as the agent applies a generation, without the CLI.
    @Test func StageRuntime_aMenuSideSelectionMovesTheLiveBubbleWithinOneCommittedFrame() throws {
        let probe = try Probe(motion: .off, walk: false, pixelScale: 2)
        only(1, probe)
        probe.runtime.hostGeometry = { StageHostGeometry(geometry: Screens.geometry(homeX: 640, homeY: 300), pixelScale: 2) }
        thinking(probe)
        probe.advance(0.3)
        let live = LiveSettings(runtime: probe.runtime, initial: AppliedSettings(control: AgentControl(), scheduler: probe.runtime.settings))
        let layout = MenuLayout(looks: ["plain"], drawnStyles: StageRuntime.drawnBubbleStyles)
        var written = AppliedSettings(control: AgentControl(), scheduler: probe.runtime.settings)
        for value in ["right", "left", "above", "below"] {
            let item = try #require(layout.items.first { $0.key == "side" && $0.value == value })
            let action = try #require(MenuSelection(settings: written).action(for: item))
            #expect(action.arguments == ["bubble", "side", value])
            // the CLI writes bubbleSide; the watcher reads it into the scheduler settings; LiveSettings applies them
            written.scheduler.bubbleSide = try #require(BubbleSide(rawValue: action.arguments[2]))
            let before = probe.runtime.renderCount
            live.apply(written)
            #expect(probe.runtime.renderCount == before + 1, "\(value): one committed frame")
            #expect(probe.runtime.lastFrame?.bubble?.plan.side.rawValue == value, "\(value): shown \(String(describing: probe.runtime.lastFrame?.bubble?.plan.side))")
            #expect(MenuSelection(settings: written).isSelected(item))
        }
    }

    /// With no bubble shown a side change renders nothing and arms nothing.
    @Test func StageRuntime_aSideChangeWithNoBubbleRendersNothing() throws {
        let probe = try Probe(motion: .off, walk: false)
        only(1, probe)
        probe.advance(1)
        let renders = probe.runtime.renderCount, armed = probe.timer.armCount
        var settings = probe.runtime.settings
        settings.bubbleSide = .left
        probe.runtime.apply(settings: settings)
        #expect(probe.runtime.renderCount == renders && probe.timer.armCount == armed, "no bubble: no render and no timer")
        settings.bubbleSide = .below
        probe.runtime.apply(settings: settings)
        #expect(probe.runtime.renderCount == renders && probe.timer.armCount == armed)
        // a quiet condition: nothing at all
        probe.runtime.setQuiet(.screenLocked, active: true)
        let quiet = probe.runtime.renderCount
        settings.bubbleSide = .right
        probe.runtime.apply(settings: settings)
        #expect(probe.runtime.renderCount == quiet && probe.runtime.wake.armedTimers == 0)
        // the next dictation draws on the chosen side
        probe.runtime.setQuiet(.screenLocked, active: false)
        thinking(probe)
        probe.advance(0.3)
        #expect(probe.runtime.lastFrame?.bubble?.plan.side == .right)
    }

    /// E5: the memory is committed from presented frames only. A layout nobody presented commits nothing; one presented frame commits once; the memory is
    /// cleared when the bubble ends.
    @Test func StageRuntime_memoryCommitsOnlyFromPresentedFrames() throws {
        let probe = try Probe(motion: .off, walk: false, pixelScale: 2)
        only(1, probe)
        probe.runtime.hostGeometry = { StageHostGeometry(geometry: Screens.geometry(homeX: 640, homeY: 300), pixelScale: 2) }
        #expect(probe.runtime.bubbleMemory == nil, "no bubble yet")
        thinking(probe)
        probe.advance(0.3)
        let committed = try #require(probe.runtime.bubbleMemory)
        let renders = probe.runtime.renderCount
        // layouts of requests nobody presents: the renderer is pure and the memory does not move
        var other = try #require(probe.runtime.lastRequest)
        other.bubbleSide = .left
        for _ in 0..<5 { _ = try probe.runtime.renderer.layout(other) }
        _ = try probe.runtime.renderer.compose(other)
        #expect(probe.runtime.bubbleMemory == committed && probe.runtime.renderCount == renders, "unpresented layouts commit nothing")
        // one presented frame: one commit, of that frame's layout
        var settings = probe.runtime.settings
        settings.bubbleSide = .left
        probe.runtime.apply(settings: settings)
        #expect(probe.runtime.renderCount == renders + 1)
        #expect(probe.runtime.bubbleMemory == probe.runtime.lastFrame?.layout.memory && probe.runtime.bubbleMemory?.shown.side == .left)
        // the dictation ends and the bubble with it: the memory is cleared
        probe.run.controller.receive(line: ackLine(probe.clock).trimmingCharacters(in: .newlines))
        probe.advance(6)
        #expect(probe.runtime.lastFrame?.bubble == nil && probe.runtime.bubbleMemory == nil, "the memory ends with the bubble")
    }

    /// E3 through the runtime's own timer: a still bubble (INTERRUPTED, no wake of its own) falls back while the open menu covers the below place, and
    /// after the menu closes it returns below half a second later, on the wake the runtime armed. The test renders nothing itself.
    @Test func StageRuntime_aStaticFallbackBubbleReturnsBelowByTheRuntimesOwnWake() throws {
        let probe = try Probe(motion: .off, walk: false, pixelScale: 2)
        only(1, probe)
        probe.run.controller.randomUnit = { 0.5 }
        probe.runtime.hostGeometry = { StageHostGeometry(geometry: Screens.geometry(homeX: 640, homeY: 300), pixelScale: 2) }
        probe.run.controller.receive(line: startLine(probe.clock).trimmingCharacters(in: .newlines))
        probe.advance(0.2)
        probe.run.controller.receive(line: completedLine(probe.clock, length: 0).trimmingCharacters(in: .newlines))
        // INTERRUPTED shows for SceneMachine.noticeDuration (1.5 s): the whole sequence below runs inside it.
        probe.advance(0.05)
        let shownAt = probe.clock.now
        #expect(probe.runtime.lastScene == .interrupted)
        let free = try #require(probe.runtime.lastFrame?.bubble, "a still bubble is shown")
        #expect(free.plan.side == .below)
        // the menu opens over the below place: the bubble changes at once (a safety change)
        probe.runtime.menuRect = CGRect(x: free.rect.minX + 6, y: free.rect.minY - 20, width: 60, height: free.rect.height + 30)
        probe.runtime.renderNow()
        #expect(probe.runtime.lastFrame?.bubble?.plan.side != .below, "the open menu pushes the bubble off below")
        probe.advance(0.1)
        // the menu closes; below fits again, but the return waits 0.5 s of continuous fit
        probe.runtime.menuRect = nil
        probe.runtime.renderNow()
        let closed = probe.clock.now
        #expect(probe.runtime.lastFrame?.bubble?.plan.side != .below, "no return at the close itself")
        probe.advance(0.45)
        #expect(probe.runtime.lastFrame?.bubble?.plan.side != .below, "still held 0.45 s after the close")
        probe.advance(0.15)
        #expect(probe.runtime.lastFrame?.bubble?.plan.side == .below, "returned below by 0.6 s after the close")
        let back = try #require(probe.frames.first { $0.at > closed && $0.frame.bubble?.plan.side == .below })
        #expect(abs(back.at - (closed + 0.5)) < 0.01, "the return frame came from the wake at 0.5 s, not from another render: \(back.at - closed)")
        #expect(probe.clock.now - shownAt < SceneMachine.noticeDuration, "the notice was still on screen for the whole sequence")
    }

    /// D-5: a display or scale change while a bubble shows. The render after the change draws the shown bubble at the new backing, a still bubble
    /// (INTERRUPTED, no wake of its own) included: no picture is reused across backing.
    @Test func StageRuntime_aStillBubbleIsRedrawnAtTheNewBackingWhenTheDisplayChanges() throws {
        for style in [13, 14, 15] {
            let probe = try Probe(motion: .off, walk: false, pixelScale: 1)
            only(style, probe)
            var backing = 1.0
            probe.runtime.hostGeometry = { StageHostGeometry(geometry: Screens.geometry(), pixelScale: backing) }
            probe.run.controller.receive(line: startLine(probe.clock).trimmingCharacters(in: .newlines))
            probe.advance(0.2)
            probe.run.controller.receive(line: completedLine(probe.clock, length: 0).trimmingCharacters(in: .newlines))
            probe.advance(0.3)
            #expect(probe.runtime.lastScene == .interrupted, "style \(style)")
            let before = try #require(probe.runtime.lastFrame?.bubble, "style \(style): a bubble is shown at 1x")
            #expect(before.bitmap.pixelsPerUnit == 1)
            let pixelsAt1x = try #require(probe.runtime.lastFrame).pixels.width
            // the display changes: Clawd is dragged onto a display of twice the density, and the host renders
            backing = 2
            probe.runtime.renderNow()
            let after = try #require(probe.runtime.lastFrame?.bubble, "style \(style): a bubble is shown at 2x")
            if style == 13 {
                // a pixel style's picture is the same bitmap; the compositor enlarges it by twice the factor
                #expect(after.bitmap.raster == before.bitmap.raster && probe.runtime.lastFrame?.pixels.width == 2 * pixelsAt1x, "style 13 at 2x")
            } else {
                #expect(after.bitmap.pixelsPerUnit == 2, "style \(style): the picture is drawn at the new backing")
                #expect(after.bitmap.raster.width == 2 * before.bitmap.raster.width && after.bitmap.raster.height == 2 * before.bitmap.raster.height,
                        "style \(style): \(before.bitmap.raster.width) x \(before.bitmap.raster.height) at 1x, \(after.bitmap.raster.width) x \(after.bitmap.raster.height) at 2x")
            }
        }
    }
}
