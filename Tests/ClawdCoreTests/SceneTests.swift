import Testing
import Foundation
import ClawdCore
import ClawdRendering

private let isoParser: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

/// Replays fixture lines on a virtual clock: time moves to each line's own timestamp, then the line is fed.
private func replay(_ text: String, on rig: Rig) throws {
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard raw.hasPrefix("[2"), let end = raw.firstIndex(of: "]"),
              let date = isoParser.date(from: String(raw[raw.index(after: raw.startIndex)..<end])) else { continue }
        let delta = date.timeIntervalSince(rig.clock.wallNow)
        if delta > 0 { rig.advance(delta) }
        rig.feed(String(raw))
    }
}
private func firstTimestamp(_ text: String) throws -> Date {
    let first = try #require(text.split(separator: "\n").first)
    let end = try #require(first.firstIndex(of: "]"))
    return try #require(isoParser.date(from: String(first[first.index(after: first.startIndex)..<end])))
}
private func dedup(_ scenes: [Scene]) -> [Scene] {
    scenes.filter { $0 != .sleep }.reduce(into: [Scene]()) { if $0.last != $1 { $0.append($1) } }
}

// MARK: ScenePlayer

@Suite("Scene player on a virtual clock")
struct ScenePlayerSuite {
    @Test func ScenePlayer_listeningOnStartAcceptedAndOnLockAcceptedAlone() {
        let a = Rig(); a.start(); #expect(a.scene == .listening)
        let b = Rig(); b.lock(); #expect(b.scene == .listening)
    }
    @Test func ScenePlayer_fixtureSessionGivesExactSequenceAndTimes() throws {
        let text = try fixture("session.log")
        let rig = Rig(wall: try firstTimestamp(text))
        try replay(text, on: rig)
        rig.advance(10)
        #expect(rig.scenes == [.idle, .listening, .thinking, .sent, .idle])
        let t0 = rig.at(.listening)!
        #expect(abs(rig.at(.thinking)! - t0 - 2.0) < 1e-6)     // completed at +2.0 s
        #expect(abs(rig.at(.sent)! - t0 - 3.0) < 1e-6)         // ACK at +2.8 s waits for THINKING's 1.0 s minimum
        #expect(abs(rig.changes.last!.at - t0 - 5.0) < 1e-6)   // SENT is gone 2.0 s later
    }
    @Test func ScenePlayer_realFormatLinesFromAquaLogDriveTheScenes() throws {
        let text = try fixture("aqua-real-sequence.log")
        let rig = Rig(wall: try firstTimestamp(text))
        try replay(text, on: rig)
        rig.advance(30)
        #expect(dedup(rig.scenes) == [.idle, .listening, .thinking, .sent, .listening, .idle, .error, .idle])
    }
    @Test func ScenePlayer_thinkingStartsAtCompletedWhenThereIsNoHint() {
        let rig = Rig(); rig.start(); rig.advance(3)
        rig.complete(); #expect(rig.scene == .thinking)
    }
    @Test func ScenePlayer_thinkingStartsAtTheReleaseHintBeforeCompleted() {
        let rig = Rig(sourceB: true); rig.start(); #expect(rig.scene == .listening)
        rig.advance(2); rig.device.fire(running: false)
        #expect(rig.scene == .thinking)
        let hintAt = rig.at(.thinking)!
        rig.advance(0.6); rig.complete()
        #expect(rig.scene == .thinking); #expect(rig.at(.thinking) == hintAt)       // completed keeps THINKING, no restart
        rig.advance(0.5); rig.ack(); rig.advance(1.0)
        #expect(rig.scene == .sent)
    }
    @Test func ScenePlayer_interruptedOnEachCancelFormAndOnEmptyCompletion() {
        let forms = ["dictation.cancel_accepted lease_id=1", "dictation.completed_canceled lease_id=1 session_id=2",
                     "dictation.completed_canceled_stale lease_id=1 session_id=2"]
        for body in forms {
            let rig = Rig(); rig.start(); rig.feed(line(rig.clock, "DictationOrchestrator", body))
            #expect(rig.scene == .interrupted, "\(body)")
        }
        let empty = Rig(); empty.start(); empty.complete(length: 0); #expect(empty.scene == .interrupted)
    }
    @Test func ScenePlayer_errorOnEachOfTheFiveTriggers() {
        let triggers: [(String, String, String)] = [
            ("DictationOrchestrator", "dictation.start_failed lease_id=1 reason=x", "warn"),
            ("DictationRuntimeAdapter", "dictation.native_audio_capture_failed lease_id=1 capture_phase=streaming", "warn"),
            ("DictationOrchestrator", "dictation.owner_lost_during_session lease_id=1", "warn"),
            ("DictationOrchestrator", "dictation.server_stop_received lease_id=1 reason=microphone_stopped", "info"),
            ("", "[NativeAudioCaptureProvider] Audio capture stopped unexpectedly. The microphone may have disconnected.", "error"),
            ("", "Error: Audio capture stopped unexpectedly. The microphone may have disconnected.", "error"),
        ]
        for (source, body, level) in triggers {
            let rig = Rig(); rig.start()
            rig.feed(line(rig.clock, source, body, level: level))
            #expect(rig.scene == .error, "\(body)")
        }
        let calm = Rig(); calm.start()
        calm.feed(line(calm.clock, "DictationOrchestrator", "dictation.server_stop_received lease_id=1 reason=normal"))
        #expect(calm.scene == .listening)
    }
    @Test func ScenePlayer_errorOverridesSent() {
        let rig = Rig(); rig.start(); rig.complete(); rig.advance(1.0); rig.ack()
        #expect(rig.scene == .sent)
        rig.fail(); #expect(rig.scene == .error)
        rig.advance(1.5); #expect(rig.scene == .idle)
    }
    @Test func ScenePlayer_errorPreemptsThinkingAtOnceInsideTheOneSecondMinimum() {
        let rig = Rig(); rig.start(); rig.complete(); #expect(rig.scene == .thinking)
        rig.advance(0.1); rig.fail()
        #expect(rig.scene == .error); #expect(rig.seconds(rig.at(.error)!) < 0.11)
    }
    @Test func ScenePlayer_newLeaseDuringSentGoesStraightToListening() {
        let rig = Rig(); rig.start(1); rig.complete(); rig.advance(1.0); rig.ack(); #expect(rig.scene == .sent)
        rig.advance(0.5); rig.start(2)
        #expect(rig.scene == .listening); #expect(rig.controller.machine.lease == 2)
    }
    @Test func ScenePlayer_newLeaseDuringThinkingWaitsForTheMinimumThenListens() {
        let rig = Rig(); rig.start(1); rig.complete(); rig.advance(0.4); rig.start(2)
        #expect(rig.scene == .thinking)
        rig.advance(0.59); #expect(rig.scene == .thinking)
        rig.advance(0.02); #expect(rig.scene == .listening)
    }
    @Test func ScenePlayer_dragReturnsToThePreviousScene() {
        for setup in 0..<4 {
            let rig = Rig()
            switch setup {
            case 0: break
            case 1: rig.start()
            case 2: rig.start(); rig.complete()
            default: rig.start(); rig.complete(); rig.advance(1.0); rig.ack()
            }
            let before = rig.scene
            rig.controller.mouseDown(); #expect(rig.scene == before)
            rig.controller.mouseDragged(); #expect(rig.scene == .drag)
            rig.controller.mouseDragged(); #expect(rig.scene == .drag)
            rig.controller.mouseUp(); #expect(rig.scene == before, "setup \(setup)")
        }
    }
    @Test func ScenePlayer_dragLeavesTheChipOnTheUnderlyingScene() {
        let rig = Rig(); rig.start(); rig.controller.mouseDown(); rig.controller.mouseDragged()
        let state = rig.controller.state()
        #expect(state.scene == .drag); #expect(state.chipScene == .listening)
    }
    @Test func ScenePlayer_leaseIdsReusedOrExtremeNeverConfuseTheMachine() {
        let rig = Rig()
        for lease in [1, 1, 2, 1, 0, Int.max, 1] {
            rig.start(lease); #expect(rig.controller.machine.lease == lease)
            rig.complete(lease: lease, length: 0); #expect(rig.scene == .interrupted)
            rig.advance(1.5)
        }
        rig.feed(line(rig.clock, "DictationOrchestrator", "dictation.start_accepted lease_id=99999999999999999999999 provider=online"))
        #expect(rig.scene == .idle)
    }
    @Test func ScenePlayer_bootstrapAndShutdownResetLeases() {
        for body in [("Main", "app.bootstrap arch=arm64 pid=2 platform=darwin"), ("SystemBridge", "Shutdown initiated (pid: 5)")] {
            let rig = Rig(); rig.start(4); #expect(rig.controller.machine.lease == 4)
            let generation = rig.controller.machine.generation
            rig.feed(line(rig.clock, body.0, body.1))
            #expect(rig.controller.machine.lease == nil, "\(body.1)"); #expect(rig.scene == .idle)
            #expect(rig.controller.machine.generation == generation + 1)
        }
    }
    @Test func ScenePlayer_noSentWhenTheAckNeverArrives() {
        let rig = Rig(); rig.start(); rig.complete(); rig.advance(60)
        #expect(!rig.scenes.contains(.sent)); #expect(rig.scene == .idle)
        #expect(abs(rig.changes.last!.at - rig.at(.thinking)! - 5.0) < 1e-6)   // THINKING's own 5 s timeout
    }
    @Test func ScenePlayer_pasteFailureIsAnError() {
        let rig = Rig(); rig.start(); rig.complete(); rig.advance(0.3); rig.ack(false)
        #expect(rig.scene == .error)
    }
    @Test func ScenePlayer_ackOutsideTheThreeSecondWindowOrWithoutCompletedIsIgnored() {
        let late = Rig(); late.start(); late.complete(); late.advance(3.5); late.ack()
        #expect(late.scene == .thinking); #expect(!late.scenes.contains(.sent))
        let bare = Rig(); bare.ack(); #expect(bare.scene == .idle)
        let open = Rig(); open.start(1); open.complete(); open.advance(0.5); open.start(2); open.ack()
        #expect(!open.scenes.contains(.sent))
    }
    @Test func ScenePlayer_negativeControl_ackWindowOff() {
        func ackOutsideWindowIsIgnored(_ guards: GuardSet) -> Bool {
            let rig = Rig(); rig.controller.machine.guards = guards
            rig.start(); rig.complete(); rig.advance(3.5); rig.ack()
            return !rig.scenes.contains(.sent)
        }
        #expect(ackOutsideWindowIsIgnored(.all))
        negativeControl("ack-window", expectationHolds: ackOutsideWindowIsIgnored(.all.subtracting(.ackWindow)))
    }
    @Test func ScenePlayer_eventsOlderThanTenSecondsNeverReachTheScene() {
        let rig = Rig(); rig.feed(startLine(rig.clock, lease: 1, age: 10.5)); #expect(rig.scene == .idle)
        rig.feed(startLine(rig.clock, lease: 1, age: 9.5)); #expect(rig.scene == .listening)
    }
    @Test func ScenePlayer_hiddenWhileAquaIsAbsentAndAgainAfterWakeOrLaunch() {
        let rig = Rig(aquaRunning: false)
        #expect(rig.controller.visible == false); #expect(rig.controller.ownedTimers == 0)
        #expect(rig.renders.last?.visible == false)
        rig.controller.setAquaRunning(true); #expect(rig.controller.visible); #expect(rig.controller.ownedTimers == 1)
        rig.controller.systemWillSleep(); #expect(!rig.controller.visible); #expect(rig.controller.ownedTimers == 0)
        rig.controller.systemDidWake(); #expect(rig.controller.visible); #expect(rig.scene == .idle)
        rig.controller.setAquaRunning(false); #expect(rig.controller.ownedTimers == 0)
    }
    @Test func ScenePlayer_realRendererChipTextTracksEachScene() throws {
        let renderer = try SceneRenderer(art: artDirectory)
        let rig = Rig(renderer: renderer)
        rig.start(); rig.advance(1.0)
        let listening = rig.controller.state()
        #expect(renderer.chipText(renderer.frame(from: listening, scale: 1, helmet: false)) == renderer.elements.prompt + " ")
        rig.advance(2.5); rig.complete(length: 5); rig.advance(0.5)
        let thinking = renderer.chipText(renderer.frame(from: rig.controller.state(), scale: 1, helmet: false))
        #expect(thinking.hasSuffix(renderer.elements.ellipsis))
        #expect(renderer.elements.glyphs.contains(String(thinking.first!)))
        #expect(renderer.elements.present.contains(thinking.dropFirst(2).dropLast(renderer.elements.ellipsis.count).description))
        rig.ack(); rig.advance(0.6)
        let sent = renderer.chipText(renderer.frame(from: rig.controller.state(), scale: 1, helmet: false))
        #expect(sent.hasSuffix(" for 3s"))                 // 3.5 s of dictation, shown as whole seconds like Claude Code
        #expect(renderer.elements.past.contains(sent.dropFirst(2).dropLast(" for 3s".count).description))
    }
}

// MARK: SceneTiming

@Suite("Scene timings")
struct SceneTimingSuite {
    @Test func SceneTiming_thinkingIsShownAtLeastOneSecondBeforeSent() {
        let fast = Rig(); fast.start(); fast.complete(); fast.advance(0.2); fast.ack(); fast.advance(2)
        #expect(abs(fast.at(.sent)! - fast.at(.thinking)! - 1.0) < 1e-6)
        let slow = Rig(); slow.start(); slow.complete(); slow.advance(1.5); slow.ack()
        #expect(abs(slow.at(.sent)! - slow.at(.thinking)! - 1.5) < 1e-6)
    }
    @Test func SceneTiming_sentIsGoneAtTwoSeconds() {
        let rig = Rig(); rig.start(); rig.complete(); rig.advance(1.0); rig.ack()
        rig.advance(1.999); #expect(rig.scene == .sent)
        rig.advance(0.002); #expect(rig.scene == .idle)
    }
    @Test func SceneTiming_sentFadeStartGetsItsOwnWakeSoTheFadeIsActuallyRendered() throws {
        let renderer = try SceneRenderer(art: artDirectory)
        let rig = Rig(renderer: renderer)
        rig.start(); rig.complete(); rig.advance(1.0); rig.ack()
        #expect(rig.scene == .sent)
        rig.advance(2.1)
        let elapsed = rig.renders.filter { $0.scene == .sent && $0.chipScene == .sent }.map(\.elapsed)
        let fade = elapsed.filter { $0 >= SceneRenderer.sentFadeStart }
        #expect(!fade.isEmpty, "no frame was rendered during the fade: \(elapsed)")
        #expect((fade.first ?? 9) < SceneRenderer.sentFadeStart + 0.06, "the first fade frame must come at the fade start, not at the 2 s deadline: \(elapsed)")
        #expect(fade.count >= 6, "the fade runs 0.4 s in 0.05 s steps: \(fade)")
        // After the hop (0.34 s) nothing changes until the fade starts, so there is exactly one wake in between, at the fade start.
        #expect(elapsed.filter { $0 > 0.35 && $0 < SceneRenderer.sentFadeStart - 0.001 }.isEmpty, "\(elapsed)")
        #expect(rig.scene == .idle)
    }
    @Test func SceneTiming_theWakeForASentChipCountsDownToTheFadeStartAndThenStepsThroughTheFade() throws {
        let renderer = try SceneRenderer(art: artDirectory)
        let rig = Rig(renderer: renderer)
        rig.start(); rig.complete(); rig.advance(1.0); rig.ack()
        var state = rig.controller.state()
        #expect(state.chipScene == .sent)
        for elapsed in [0.4, 1.0, 1.5, 1.59] {
            state.elapsed = elapsed
            let interval = try #require(renderer.animationInterval(for: state, scale: 1, helmet: false), "no wake at \(elapsed)")
            #expect(abs(interval - (SceneRenderer.sentFadeStart - elapsed)) < 1e-9, "elapsed \(elapsed): \(interval)")
        }
        for elapsed in [1.6, 1.8, 1.99] {
            state.elapsed = elapsed
            #expect(renderer.animationInterval(for: state, scale: 1, helmet: false) == 0.05)
        }
        #expect(SceneRenderer.sentFadeStart == 1.6)
    }
    @Test func SceneTiming_theSentChipIsFullyShownBeforeTheFadeAndFadesLinearlyToNothing() throws {
        let renderer = try SceneRenderer(art: artDirectory)
        func chipAlpha(_ elapsed: Double) throws -> Int {
            let image = try renderer.render(RenderFrame(scene: .sent, elapsed: elapsed, duration: 5))
            let pixels = try SceneRenderer.pixels(image)
            let x = 60, y = image.height - 1 - 12         // inside the chip box, left of its text, above the baseline
            return Int(pixels[(y * image.width + x) * 4 + 3])
        }
        let full = try chipAlpha(1.0)
        #expect(abs(full - 230) <= 2, "the chip fill is 90 % opaque: \(full)")
        #expect(try chipAlpha(1.59) == full)
        #expect(abs(try chipAlpha(1.8) - full / 2) <= 3)
        #expect(try chipAlpha(1.99) < full / 6)
        #expect(try chipAlpha(2.0) == 0)
    }
    @Test func SceneTiming_interruptedAndErrorLastOneAndAHalfSeconds() {
        let interrupted = Rig(); interrupted.start(); interrupted.cancel()
        interrupted.advance(1.499); #expect(interrupted.scene == .interrupted)
        interrupted.advance(0.002); #expect(interrupted.scene == .idle)
        let error = Rig(); error.fail()
        error.advance(1.499); #expect(error.scene == .error)
        error.advance(0.002); #expect(error.scene == .idle)
    }
    @Test func SceneTiming_listeningFallsToIdleAfter180SecondsWithoutEvents() {
        let rig = Rig(); rig.start(); rig.advance(179.9); #expect(rig.scene == .listening)
        rig.advance(0.2); #expect(rig.scene == .idle)
        let renewed = Rig(); renewed.start(); renewed.advance(100); renewed.lock()
        renewed.advance(100); #expect(renewed.scene == .listening)
        renewed.advance(80.1); #expect(renewed.scene == .idle)
    }
    @Test func SceneTiming_thinkingTimesOutAfterFiveSeconds() {
        let rig = Rig(); rig.start(); rig.complete()
        rig.advance(4.99); #expect(rig.scene == .thinking)
        rig.advance(0.02); #expect(rig.scene == .idle)
    }
    @Test func SceneTiming_sleepAfterTenMinutesOwnsNoTimerAndIsDisabledForTheIdleBudget() {
        let rig = Rig(); rig.advance(599); #expect(rig.scene == .idle)
        rig.advance(2); #expect(rig.scene == .sleep); #expect(rig.controller.ownedTimers == 0)
        rig.start(); #expect(rig.scene == .listening)                   // an event wakes it
        let budget = Rig(); budget.controller.machine.sleepEnabled = false; budget.controller.refresh()
        budget.advance(3600); #expect(budget.scene == .idle); #expect(!budget.scenes.contains(.sleep))
    }
    @Test func SceneTiming_falseReleaseHintReturnsToListeningWhenTheDeviceRunsAgain() {
        let rig = Rig(sourceB: true); rig.start(); rig.advance(1); rig.device.fire(running: false)
        #expect(rig.scene == .thinking)
        rig.advance(2); rig.device.fire(running: true)
        rig.advance(2.9); #expect(rig.scene == .thinking)
        rig.advance(0.2); #expect(rig.scene == .listening)
        #expect(rig.controller.machine.lease == 1)
    }
    @Test func SceneTiming_falseReleaseHintReturnsToIdleWhenTheDeviceStaysStopped() {
        let rig = Rig(sourceB: true); rig.start(); rig.advance(1); rig.device.fire(running: false)
        rig.advance(4.9); #expect(rig.scene == .thinking)
        rig.advance(0.2); #expect(rig.scene == .idle); #expect(rig.controller.machine.lease == nil)
    }
    @Test func SceneTiming_coarseVirtualStepAppliesEachDeadlineAtItsOwnTime() {
        let clock = VirtualClock(); let machine = SceneMachine(clock: clock)
        machine.receive(event(clock, .start)); machine.receive(event(clock, .completed(10)))
        let thinking = clock.now
        clock.advance(0.2); machine.receive(event(clock, .pasteAck(true)))
        clock.advance(100); machine.tick()                    // one coarse step over every deadline
        #expect(machine.scene == .idle); #expect(abs(machine.sceneSince - (thinking + 3.0)) < 1e-6)
        #expect(machine.nextDeadline == machine.lastActivity + 600)
    }
    @Test func SceneTiming_blinkEveryThreeToSevenSecondsWithOneSecondLeeway() {
        for (unit, expected) in [(0.0, 3.0), (1.0, 7.0), (0.5, 5.0)] {
            let rig = Rig(); rig.controller.randomUnit = { unit }
            rig.controller.setAquaRunning(true)
            #expect(abs(rig.scheduler.fireAt! - rig.clock.now - expected) < 1e-6)
            #expect(rig.scheduler.leeway == 1.0)
            rig.advance(expected + 0.01); #expect(rig.controller.state().blink)
            rig.advance(0.12); #expect(!rig.controller.state().blink)
        }
    }
    @Test func SceneTiming_dragDoesNotDelayTheUnderlyingDeadlines() {
        let rig = Rig(); rig.start(); rig.complete()
        rig.controller.mouseDragged(); rig.advance(5.01)
        #expect(rig.scene == .drag); rig.controller.mouseUp(); #expect(rig.scene == .idle)
    }
}

// MARK: SceneReachability

@Suite("Scene reachability and timer budget")
struct SceneReachabilitySuite {
    @Test func SceneReachability_allEightScenesAreReachedAndTheTimerBudgetHolds() throws {
        let renderer = try SceneRenderer(art: artDirectory)
        var reached = Set<Scene>()
        func note(_ rig: Rig) { reached.insert(rig.scene); reached.formUnion(rig.scenes) }

        let rig = Rig(renderer: renderer)
        // IDLE: Aqua running, nothing happening: exactly one timer, the blink (leeway 1 s).
        #expect(rig.scene == .idle)
        let idleTimers = rig.controller.ownedTimers
        #expect(idleTimers == 1); #expect(rig.scheduler.leeway == 1.0)
        // LISTENING -> THINKING -> SENT -> IDLE
        rig.start(); rig.advance(2); rig.complete(); rig.advance(0.5); rig.ack(); rig.advance(0.6); note(rig)
        rig.advance(2.1)
        // INTERRUPTED, ERROR
        rig.start(2); rig.cancel(lease: 2); note(rig); rig.advance(1.6)
        rig.fail(); note(rig); rig.advance(1.6)
        // DRAG
        rig.controller.mouseDown(); rig.controller.mouseDragged(); note(rig); rig.controller.mouseUp()
        // SLEEP: no timer
        rig.advance(601); note(rig)
        let sleepTimers = rig.controller.ownedTimers
        #expect(rig.scene == .sleep); #expect(sleepTimers == 0)
        // Aqua not running: hidden, no timer, from any scene
        rig.controller.setAquaRunning(false)
        let absentTimers = rig.controller.ownedTimers
        #expect(absentTimers == 0)
        #expect(reached == Set(Scene.allCases), "unreached: \(Set(Scene.allCases).subtracting(reached))")

        let evidence = [
            "SCENES-REACHED: \(reached.count)/\(Scene.allCases.count)",
            "IDLE-TIMERS: \(idleTimers)", "SLEEP-TIMERS: \(sleepTimers)", "AQUA-ABSENT-TIMERS: \(absentTimers)",
        ].joined(separator: "\n") + "\n"
        try evidenceStore().write(Data(evidence.utf8), to: "scenes-reached.txt")
    }
    @Test func SceneReachability_everySceneNeverOwnsMoreThanOneTimer() throws {
        let renderer = try SceneRenderer(art: artDirectory)
        let rig = Rig(renderer: renderer)
        var maximum = rig.controller.ownedTimers
        func sample() { maximum = max(maximum, rig.controller.ownedTimers); #expect(rig.controller.ownedTimers <= 1) }
        rig.start(); sample(); rig.advance(1); sample(); rig.complete(); sample(); rig.advance(1.2); sample()
        rig.ack(); sample(); rig.advance(1); sample(); rig.advance(5); sample()
        rig.fail(); sample(); rig.advance(2); sample()
        #expect(maximum == 1)
    }
    @Test func SceneReachability_everyNonIdleSceneReturnsToIdleThroughItsTimeoutAlone() throws {
        let renderer = try SceneRenderer(art: artDirectory)
        let cases: [(String, (Rig) -> Void, Double)] = [
            ("listening", { $0.start() }, 180), ("thinking", { $0.start(); $0.complete() }, 5),
            ("sent", { $0.start(); $0.complete(); $0.advance(1); $0.ack() }, 2),
            ("interrupted", { $0.start(); $0.cancel() }, 1.5), ("error", { $0.fail() }, 1.5),
        ]
        for (name, setup, timeout) in cases {
            let rig = Rig(renderer: renderer); setup(rig)
            #expect(rig.scene != .idle, "\(name) setup")
            rig.advance(timeout + 0.05)
            #expect(rig.scene == .idle, "\(name) did not return to IDLE by timeout alone")
        }
    }
}
