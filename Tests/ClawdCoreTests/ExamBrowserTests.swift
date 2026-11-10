import Testing
import Foundation
import CoreGraphics
import CryptoKit
@testable import ClawdCore
import ClawdRendering
import ClawdDesktop

// Amendment "scheduler feel", D-4: Clawd stands down while a LockDown Browser application runs and for 120 s after the last one quits. No test
// starts the real app: the running applications are a closure the test owns (`RuntimeEnvironment.examBrowserRunning`).

/// The stage runtime on a virtual clock, wired the way AgentRuntime wires it (the stand-down decided before `present` is set), with the
/// running LockDown applications a count the test sets.
final class ExamRig {
    let clock: VirtualClock
    let timer: FakeScheduler
    let runtime: StageRuntime
    var apps: Int
    var running: Bool { apps > 0 }
    private(set) var presented = 0, dismissed = 0
    private(set) var lines: [String] = []
    private(set) var written: [SchedulerPersisted] = []
    let startWall: Double
    let startNow: TimeInterval

    init(wall: Double = 1_800_000_000, now: TimeInterval = 1000, state: SchedulerPersisted? = nil, apps: Int = 0,
         settings: SchedulerSettings = FeelFixture.calm(), inputIdle: TimeInterval? = nil) throws {
        clock = VirtualClock(now: now, wallNow: Date(timeIntervalSince1970: wall))
        timer = FakeScheduler(clock: clock)
        self.apps = apps; startWall = wall; startNow = now
        runtime = try StageRuntime(clock: clock, timer: timer, art: artDirectory, settings: settings, geometry: Screens.geometry(),
                                   persisted: state ?? SchedulerPersisted(look: "plain", lookSince: wall), random: { 0.5 })
        runtime.log = { [unowned self] in self.lines.append($0) }
        runtime.persist = { [unowned self] in self.written.append($0) }
        runtime.scheduler.examBrowserRunning = { [unowned self] in self.running }
        if let inputIdle { runtime.scheduler.inputIdle = { inputIdle } }
        if runtime.examStartup(running: running) { runtime.setQuiet(.examBrowser, active: true) }
        runtime.hostGeometry = { StageHostGeometry(geometry: Screens.geometry(), pixelScale: 2) }
        runtime.present = { [unowned self] _ in self.presented += 1 }
        runtime.dismiss = { [unowned self] in self.dismissed += 1 }
        runtime.start()
    }

    var scheduler: PetScheduler { runtime.scheduler }
    var down: Bool { scheduler.quietReasons.contains(.examBrowser) }
    var shown: Bool { runtime.lastFrame != nil }
    var seconds: TimeInterval { clock.now - startNow }
    var wall: Double { clock.wallNow.timeIntervalSince1970 }
    func advance(_ span: TimeInterval) { advanceVirtual(clock: clock, scheduler: timer, runtime: runtime, by: span) }
    /// A LockDown Browser application launches (its notification is delivered) / quits (its notification is delivered).
    func launch() { apps += 1; runtime.examApplicationLaunched() }
    func quit() { apps -= 1; runtime.examApplicationTerminated() }
    func count(_ prefix: String) -> Int { lines.filter { $0.hasPrefix(prefix) }.count }
    var entrances: Int { lines.filter { $0.hasPrefix("MOTION start") && $0.hasSuffix("use=entrance") }.count }
    /// The state a new process would read from state.json.
    var lastWritten: SchedulerPersisted { written.last ?? scheduler.persisted }
}

@Suite("ExamBrowser: the scheduler and the stage", .serialized)
struct ExamBrowserScheduler {
    @Test func ExamBrowser_aLaunchRemovesWindowsAndStopsTimers() throws {
        let rig = try ExamRig()
        rig.advance(5)
        #expect(rig.shown && rig.presented > 0)
        let renders = rig.runtime.renderCount
        rig.launch()
        #expect(rig.down && !rig.shown && rig.dismissed > 0, "no picture after the launch")
        var maxTimers = 0
        for _ in 0..<60 { rig.advance(10); maxTimers = max(maxTimers, rig.runtime.wake.armedTimers, rig.scheduler.ownedTimers) }
        #expect(rig.runtime.renderCount == renders, "nothing renders while standing down")
        #expect(maxTimers <= 1, "at most one armed timer: the scheduler's own, for the recheck")
    }

    @Test func ExamBrowser_returnsOnlyAfterTheSettleWithAFreshCheck() throws {
        let rig = try ExamRig()
        rig.advance(5)
        rig.launch(); rig.advance(30)
        rig.quit()
        let quitAt = rig.seconds
        rig.advance(60)
        #expect(rig.down && !rig.shown, "60 s after the quit it is still away")
        // A new instance appears without a notification being delivered before the 120 s are up: the fresh check at the end finds it.
        rig.apps = 1
        rig.advance(quitAt + 125 - rig.seconds)
        #expect(rig.down && !rig.shown, "the check at the end of the 120 s asks afresh and finds the application running")
        rig.apps = 0
        rig.advance(15)
        #expect(rig.down, "the wait begins again when the absence is seen")
        rig.advance(106)
        #expect(rig.down && !rig.shown, "119 s after the absence was seen it is still away")
        rig.advance(15)
        #expect(!rig.down && rig.shown, "and it is back after the 120 s")
    }

    @Test func ExamBrowser_aSecondInstanceInsideTheSettleKeepsClawdDown() throws {
        let rig = try ExamRig()
        rig.advance(5)
        rig.launch(); rig.advance(20)
        rig.quit()
        rig.advance(41)                                  // the incident's gap between the two LockDown instances
        rig.launch()
        rig.advance(19)
        rig.quit()
        let secondQuit = rig.seconds
        rig.advance(100)
        #expect(rig.down && !rig.shown, "100 s after the second quit (141 s after the first) it is still away")
        rig.advance(secondQuit + 125 - rig.seconds)
        #expect(!rig.down && rig.shown, "it returns after the 120 s that follow the second quit")
    }

    @Test func ExamBrowser_aBackwardClockJumpRebasesTheExamGrace() throws {
        let rig = try ExamRig()
        rig.advance(5); rig.launch(); rig.advance(5); rig.quit()
        let quitAt = rig.seconds
        let first = try #require(rig.scheduler.persisted.examGraceUntil)
        rig.clock.wallNow = rig.clock.wallNow.addingTimeInterval(-3600)
        rig.advance(10)
        let rebased = try #require(rig.scheduler.persisted.examGraceUntil)
        #expect(rebased < first - 3000 && abs(rebased - (rig.wall + 120)) < 1, "the end moved to 120 s after now, not left an hour away: \(rebased) against \(first)")
        rig.advance(quitAt + 140 - rig.seconds)
        #expect(!rig.down && rig.shown, "back about 120 s after the absence was seen")
    }

    @Test func ExamBrowser_aValidFutureGraceIsKept() throws {
        let rig = try ExamRig()
        rig.advance(5); rig.launch(); rig.advance(5); rig.quit()
        let quitAt = rig.seconds
        let first = try #require(rig.scheduler.persisted.examGraceUntil)
        rig.clock.wallNow = rig.clock.wallNow.addingTimeInterval(-30)          // a small step back, inside the tolerance
        rig.advance(10)
        #expect(rig.scheduler.persisted.examGraceUntil == first, "kept as it was")
        rig.advance(quitAt + 125 - rig.seconds)
        #expect(rig.down && !rig.shown, "the wall condition (30 s behind) is not met yet")
        rig.advance(30)
        #expect(!rig.down && rig.shown)
    }

    @Test func ExamBrowser_aForwardClockJumpTenSecondsIntoTheGraceDoesNotEndItEarly() throws {
        let rig = try ExamRig()
        rig.advance(5); rig.launch(); rig.advance(5); rig.quit()
        let quitAt = rig.seconds
        rig.advance(10)
        rig.clock.wallNow = rig.clock.wallNow.addingTimeInterval(600)
        rig.advance(30)
        #expect(rig.down && !rig.shown, "40 s of monotonic time since the absence: the wall jump alone does not end it")
        rig.advance(quitAt + 125 - rig.seconds)
        #expect(!rig.down && rig.shown, "it ends once 120 s of monotonic time have passed")
    }

    @Test func ExamBrowser_aRestartDuringTheGraceStartsAFresh120Seconds() throws {
        let first = try ExamRig()
        first.advance(5); first.launch(); first.advance(5); first.quit(); first.advance(100)
        let second = try ExamRig(wall: first.wall + 1, now: 20, state: first.lastWritten)
        second.advance(110)
        #expect(second.down && !second.shown, "110 s after the restart it is still away (the 20 s that were left are not used)")
        second.advance(15)
        #expect(!second.down && second.shown)
    }

    @Test func ExamBrowser_aQuitNotificationNeverDeliveredIsHealedByTheTenSecondRecheck() throws {
        let rig = try ExamRig()
        rig.advance(5)
        #expect(rig.scheduler.examCheckAt == nil, "in normal operation there is no recheck armed")
        let before = rig.scheduler.nextDeadline()
        #expect(before?.kind != .examCheck)
        rig.launch()
        #expect(rig.scheduler.examCheckAt != nil, "while standing down there is one")
        rig.apps = 0                                       // the application quit; no notification is delivered
        let quitAt = rig.seconds
        rig.advance(9)
        #expect(rig.down)
        rig.advance(quitAt + 125 - rig.seconds)
        #expect(rig.down && !rig.shown, "120 s after the recheck saw the absence (which came up to 10 s after the quit) it is still away")
        rig.advance(15)
        #expect(!rig.down && rig.shown, "and it is back, with no notification and no command")
        #expect(rig.count("EXAM recheck-healed") == 1 && rig.count("EXAM settle-end") == 1)
        #expect(rig.scheduler.examCheckAt == nil && rig.scheduler.nextDeadline()?.kind != .examCheck, "no recheck is armed again")
    }

    @Test func ExamBrowser_aMissedTerminateNotificationIsHealedByTheRecheck() throws {
        let rig = try ExamRig(apps: 1)                     // started into a running exam; the quit is never reported
        rig.advance(30)
        #expect(rig.down && rig.presented == 0)
        rig.apps = 0
        rig.advance(10)
        #expect(rig.count("EXAM recheck-healed") == 1, "the quit was found by the timer: \(rig.lines.filter { $0.hasPrefix("EXAM") })")
        rig.advance(125)
        #expect(!rig.down && rig.shown)
    }

    @Test func ExamBrowser_aLateCheckAfterSleepStartsTheGraceAtTheObservation() throws {
        let rig = try ExamRig(apps: 1)
        let deadline = try #require(rig.timer.fireAt)
        let renders = rig.runtime.renderCount
        // The clock advances while the main queue cannot deliver the armed check. Only one late callback is delivered.
        rig.clock.advance(300)
        try #require(deadline < rig.clock.now - 120)
        rig.apps = 0 // the last app quits just before delivery, without a terminate notification
        let observedMono = rig.clock.now, observedWall = rig.wall
        rig.timer.cancel()
        rig.runtime.tick()
        #expect(rig.down && !rig.shown && rig.runtime.renderCount == renders)
        #expect(rig.scheduler.examAbsentMono == observedMono)
        #expect(rig.lastWritten.examGraceUntil == observedWall + 120)
        #expect(rig.count("EXAM recheck-healed") == 1 && rig.count("EXAM settle-end") == 0)
        #expect(rig.scheduler.examCheckAt == observedMono + 10)
        // Another callback in the same catch-up batch cannot finish the grace either.
        rig.runtime.tick()
        #expect(rig.down && rig.scheduler.examAbsentMono == observedMono)
        rig.advance(119.9)
        #expect(rig.down && !rig.shown && rig.runtime.renderCount == renders)
        rig.advance(0.1)
        #expect(!rig.down && rig.count("EXAM settle-end") == 1)
        rig.advance(5)
        #expect(rig.shown, "returns only after 120 s from the late observation")
    }

    @Test func ExamBrowser_theLaunchNotificationTurnIsTheBoundary() throws {
        let rig = try ExamRig()
        rig.advance(5)
        let renders = rig.runtime.renderCount, presented = rig.presented
        // A callback is due in the very turn the notification is delivered (the next idle slot, the blink): the notification goes first.
        rig.launch()
        rig.runtime.tick()
        rig.runtime.tick()
        rig.advance(30)
        #expect(rig.runtime.renderCount == renders && rig.presented == presented, "zero renders and no window from that turn on")
        #expect(rig.runtime.lastFrame == nil && rig.scheduler.frame().visibility == .quiet(.examBrowser))
        #expect(rig.scheduler.frame().playback == nil, "and nothing animates")
    }

    @Test func ExamBrowser_hideAndSettleDeadlinesDueTogetherBothApply() throws {
        var settings = FeelFixture.calm()
        settings.hiddenUntil = 1_800_000_000 + 200
        let rig = try ExamRig(settings: settings)
        rig.launch(); rig.advance(80); rig.quit()           // the 120 s end 200 s after the start, exactly when the timed hide does
        let quitAt = rig.seconds
        rig.advance(quitAt + 119.9 - rig.seconds)
        #expect(rig.down && !rig.shown)
        rig.advance(1.2)
        #expect(!rig.down && rig.scheduler.visibility == .visible && rig.shown, "both ended in the same turn: neither was lost and Clawd appears (down \(rig.down), \(rig.scheduler.visibility), t=\(rig.seconds), until \(String(describing: rig.scheduler.persisted.examGraceUntil)), wall \(rig.wall), \(rig.lines.filter { $0.hasPrefix("EXAM") || $0.hasPrefix("QUIET") || $0.hasPrefix("HIDDEN") || $0.hasPrefix("SHOWN") }))")
        #expect(rig.entrances == 1, "with its entrance: \(rig.lines.filter { $0.hasPrefix("MOTION") })")
    }

    @Test func ExamBrowser_anUnexpiredOrIndefiniteHideKeepsClawdHiddenAfterTheGrace() throws {
        for hidden in [1_800_000_000.0 + 3000, -1.0] {
            var settings = FeelFixture.calm()
            settings.hiddenUntil = hidden
            let rig = try ExamRig(settings: settings)
            rig.advance(5); rig.launch(); rig.advance(5); rig.quit(); rig.advance(200)
            #expect(!rig.down && rig.scheduler.visibility == .hidden && !rig.shown && rig.entrances == 0, "hidden until \(hidden): the exam ending shows nothing")
        }
    }

    @Test func ExamBrowser_aHiddenClawdStaysHiddenAfterTheExam() throws {
        var settings = FeelFixture.calm()
        settings.hiddenUntil = -1
        let rig = try ExamRig(settings: settings)
        rig.advance(5)
        #expect(rig.scheduler.visibility == .hidden)
        rig.launch()
        #expect(rig.scheduler.visibility == .hidden, "hidden outranks the quiet condition")
        rig.advance(20); rig.quit(); rig.advance(200)
        #expect(rig.scheduler.visibility == .hidden && rig.presented == 0)
    }

    @Test func ExamBrowser_anAsleepClawdReturnsByTheAppearRules() throws {
        let rig = try ExamRig(inputIdle: 700)
        rig.advance(5)
        #expect(rig.scheduler.asleep, "the user has been away: Clawd sleeps")
        rig.launch()
        #expect(!rig.scheduler.asleep && rig.down, "the stand-down cuts the sleep like any quiet condition")
        rig.advance(20); rig.quit(); rig.advance(125)
        #expect(!rig.down && rig.shown && rig.entrances == 1, "it appears with its entrance: \(rig.lines.filter { $0.hasPrefix("MOTION") })")
    }

    @Test func ExamBrowser_aDragInProgressIsCancelledAndAnOpenMenuIsClosed() throws {
        let drag = try ExamRig()
        drag.advance(5)
        drag.runtime.perform { drag.scheduler.dragStarted() }
        #expect(drag.scheduler.isDragging)
        drag.launch()
        #expect(!drag.scheduler.isDragging, "the press goes away with the window")
        let menu = try ExamRig()
        menu.advance(5)
        menu.runtime.perform { _ = menu.scheduler.menuOpened() }
        #expect(menu.scheduler.menuOpen)
        menu.launch()
        #expect(!menu.scheduler.menuOpen)
    }

    @Test func ExamBrowser_schedulerQuietGetterAndLogUseExamBrowser() throws {
        let rig = try ExamRig()
        rig.advance(5); rig.launch()
        #expect(rig.scheduler.quietReason == .examBrowser && QuietReason.examBrowser.rawValue == "exam-browser")
        #expect(rig.lines.contains("QUIET on reason=exam-browser"))
        rig.advance(10); rig.quit(); rig.advance(130)
        #expect(rig.lines.contains("QUIET off") && rig.lines.contains("EXAM settle-end"))
    }

    @Test func ExamBrowser_settleUsesTheSingleTimer() throws {
        let rig = try ExamRig()
        rig.advance(5)
        var maxScheduler = 0, maxWake = 0
        func watch() { maxScheduler = max(maxScheduler, rig.scheduler.ownedTimers); maxWake = max(maxWake, rig.runtime.wake.armedTimers) }
        rig.launch(); watch()
        for _ in 0..<12 { rig.advance(10); watch() }
        rig.quit(); watch()
        for _ in 0..<15 { rig.advance(10); watch() }
        #expect(!rig.down)
        #expect(maxScheduler <= 1 && maxWake <= 1, "the scheduler's one timer carried the recheck and the 120 s: \(maxScheduler) \(maxWake)")
    }

    @Test func ExamBrowser_unrelatedAppsAndOtherRespondusProductsOutsideThePrefixDoNotMatch() {
        #expect(ExamBrowserRule.matches(bundleIdentifier: "com.Respondus.LockDownBrowser", name: nil))
        #expect(ExamBrowserRule.matches(bundleIdentifier: "com.Respondus.LockDownBrowserOEM", name: "x"))
        #expect(ExamBrowserRule.matches(bundleIdentifier: "com.Respondus.LockDownBrowser.helper", name: nil))
        #expect(ExamBrowserRule.matches(bundleIdentifier: nil, name: "LockDown Browser"))
        #expect(ExamBrowserRule.matches(bundleIdentifier: "edu.example.exam", name: "LockDown Browser OEM"))
        for (id, name) in [("com.Respondus.Monitor", "Respondus Monitor"), ("com.apple.Safari", "Safari"), ("com.example.lockdown", "Lockdown Tool"),
                           ("com.Respondus.StudyMate", nil), (nil, nil), ("com.electron.aqua-voice", "Aqua Voice")] as [(String?, String?)] {
            #expect(!ExamBrowserRule.matches(bundleIdentifier: id, name: name), "\(id ?? "-") \(name ?? "-")")
        }
    }

    /// launcher/ and launchd/ hold exactly the files they held at 67a28a1, byte for byte. Compared by SHA-256 against the values recorded from
    /// 67a28a1, not by `git diff`, because the clean-copy verification runs from a `git archive` tree that has no repository.
    @Test func ExamBrowser_plistAndLauncherAreUnchanged() throws {
        let recorded: [String: String] = [
            "launchd/com.tomtim.clawd-pet.plist.in": "06d8a730c6887b9d3df97d26db1ea67f6b860cb3c2fe7764a70820e42edf72ed",
            "launcher/clawd-pet-launch": "91f345c3591ab6d5b2b678654756028ea7ac5224830ed2f0877cbf2abdfff8c5",
            "launcher/clawd-pet-launch.sha256": "3e93b2b57b75002ced66cd1814ce9c9051017cb4dec1deefd5bffebc5873f11c",
            "launcher/launcher.c": "07f3b35ad000fa2fdd3e1930b814ab3b6dd0388ecacc83883183a0047357495c",
        ]
        var found: [String: String] = [:]
        for directory in ["launcher", "launchd"] {
            let root = repository.appendingPathComponent(directory)
            let names = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
            for name in names {
                var isDirectory: ObjCBool = false
                let url = root.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                found["\(directory)/\(name)"] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
        }
        #expect(found == recorded, "launcher/ and launchd/ are byte-identical to 67a28a1: \(found)")
    }
}

@Suite("ExamBrowser: the desktop runtime", .serialized)
@MainActor
struct ExamBrowserRuntime {
    @Test func ExamBrowser_runningAtStartNeverPresentsAWindow() async throws {
        let rig = try RuntimeRig(prepare: { $0.examRunning = true })
        await rig.spin(0.3)
        #expect(rig.machine.presented == 0 && rig.stage.lastFrame == nil && rig.stage.renderCount == 0, "no window was ever put on screen")
        #expect(rig.stage.scheduler.visibility == .quiet(.examBrowser))
        #expect(rig.lines("QUIET on reason=exam-browser").count == 1)
        #expect(try rig.state.examActive == true, "and the stand-down is on record for a restart")
    }

    @Test func ExamBrowser_startupStandsDownBeforeAnyWindow() async throws {
        let rig = try RuntimeRig(prepare: { $0.examRunning = true })
        // `stage.start()` drew its first picture into a quiet scheduler: dismissed, never presented, and not one render counted.
        #expect(rig.machine.presented == 0 && rig.stage.renderCount == 0 && !rig.panel.isVisible && !rig.bodyPanel.isVisible)
        await rig.spin(0.2)
        #expect(rig.machine.presented == 0)
    }

    @Test func ExamBrowser_repeatedSweepsKeepClawdDownAcrossRelaunches() async throws {
        // Killed, respawned at once, killed again 431 ms later, as in the incident: every new process finds LockDown running.
        for _ in 0..<3 {
            let rig = try RuntimeRig(prepare: { $0.examRunning = true })
            await rig.spin(0.05)
            #expect(rig.machine.presented == 0 && rig.stage.lastFrame == nil)
        }
    }

    @Test func ExamBrowser_aRestartInsideTheSettleStaysDown() async throws {
        // On a virtual clock: the state a process writes inside the 120 s, read by the next one.
        let first = try ExamRig()
        first.advance(5); first.launch(); first.advance(10); first.quit(); first.advance(30)
        let state = first.lastWritten
        #expect(state.examActive && state.examGraceUntil != nil, "the stand-down is in the state a restart reads")
        let second = try ExamRig(wall: first.wall + 2, now: 50, state: state)
        #expect(second.down && !second.shown && second.presented == 0, "the new process comes up already down")
        second.advance(119)
        #expect(second.down && !second.shown)
        second.advance(4)
        #expect(!second.down && second.shown)
        // Through the real runtime start (AgentRuntime): examActive and examGraceUntil in state.json, nothing running.
        let position = SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1)
        let now = Date().timeIntervalSince1970
        let file = AgentState(position: position, look: "plain", lookSince: now - 100, lookUsed: ["plain"], lookDueFactor: 1, examActive: true,
                              examGraceUntil: now + 50)
        let rig = try RuntimeRig(state: file)
        await rig.spin(0.2)
        #expect(rig.machine.presented == 0 && rig.stage.lastFrame == nil, "examActive in state.json and nothing running: still no window")
        let written = try rig.state
        let until = try #require(written.examGraceUntil)
        #expect(written.examActive == true && abs(until - (now + 120)) < 5, "a fresh 120 s from the restart is on record: \(until - now)")
    }

    @Test func ExamBrowser_aRestartWithStaleExamActiveStartsAFreshGraceFromNow() async throws {
        var stale = SchedulerPersisted(look: "plain", lookSince: 1_800_000_000, examActive: true, examGraceUntil: 1_800_000_000 - 7200)
        let quiet = try ExamRig(state: stale)
        #expect(quiet.down && quiet.presented == 0, "SIGKILL lost the quit: still no window")
        quiet.advance(119)
        #expect(quiet.down && !quiet.shown, "the old observation is not trusted: a fresh 120 s from the restart")
        quiet.advance(4)
        #expect(!quiet.down && quiet.shown)
        stale.examGraceUntil = nil
        let running = try ExamRig(state: stale, apps: 1)
        running.advance(600)
        #expect(running.down && running.presented == 0 && running.runtime.renderCount == 0, "with LockDown running now it stands down")
        #expect(running.lastWritten.examActive)
        // Through the real runtime start: an old observation in state.json, then LockDown running now.
        let position = SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1)
        let now = Date().timeIntervalSince1970
        let old = AgentState(position: position, look: "plain", lookSince: now - 100, lookUsed: ["plain"], lookDueFactor: 1, examActive: true,
                             examGraceUntil: now - 5000)
        let stand = try RuntimeRig(state: old)
        await stand.spin(0.2)
        #expect(stand.machine.presented == 0 && stand.stage.lastFrame == nil, "a stale examActive with nothing running: no window before a fresh grace")
        #expect(abs(try #require(try stand.state.examGraceUntil) - (now + 120)) < 5, "the grace counts from the restart, not from the old observation")
        let again = try RuntimeRig(state: old, prepare: { $0.examRunning = true })
        await again.spin(0.2)
        #expect(again.machine.presented == 0 && again.stage.scheduler.examAbsentMono == nil, "with LockDown running now it stands down and no wait has begun")
    }

    @Test func ExamBrowser_twoLockDownAppsReturnOnlyAfterBothQuit() async throws {
        let rig = try RuntimeRig(prepare: { $0.examRunning = true })
        let id = "com.Respondus.LockDownBrowser", other = "com.Respondus.LockDownBrowserOEM"
        rig.runtime.workspaceApplication(launched: true, bundleIdentifier: other, name: "LockDown Browser OEM", pid: 2)
        // The first quits while the second still runs: the notification re-asks the running applications and finds one.
        rig.runtime.workspaceApplication(launched: false, bundleIdentifier: id, name: "LockDown Browser", pid: 1)
        #expect(rig.stage.scheduler.quietReasons.contains(.examBrowser) && rig.stage.scheduler.examAbsentMono == nil, "the second app keeps Clawd down, no wait has begun")
        rig.machine.examRunning = false
        rig.runtime.workspaceApplication(launched: false, bundleIdentifier: other, name: "LockDown Browser OEM", pid: 2)
        #expect(rig.stage.scheduler.quietReasons.contains(.examBrowser) && rig.stage.scheduler.examAbsentMono != nil, "after both quit the 120 s begin; it is not back yet")
        #expect(rig.machine.presented == 0)
        #expect(rig.lines("EXAM quit").count == 2)
    }

    @Test func ExamBrowser_theLaunchNotificationOfTheRuntimeIsTheBoundary() async throws {
        let rig = try RuntimeRig()
        await rig.spin(0.1)
        #expect(rig.machine.presented > 0 && rig.stage.lastFrame != nil)
        let renders = rig.stage.renderCount, presented = rig.machine.presented
        rig.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.Respondus.LockDownBrowser", name: "LockDown Browser", pid: 4242)
        rig.stage.tick(); rig.stage.tick()
        #expect(rig.stage.renderCount == renders && rig.machine.presented == presented, "zero renders from the turn of the notification")
        #expect(rig.stage.lastFrame == nil && rig.machine.dismissed > 0)
        #expect(rig.lines("EXAM seen pid=4242 id=com.Respondus.LockDownBrowser first").count == 1)
    }
}
