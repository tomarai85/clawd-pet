import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop

// The Aqua follow (amendment D-1 to D-5) at the AgentRuntime level: an injectable kernel process table, an injectable exit registration,
// an injectable application list and notification center. The real Aqua, the real kernel's Aqua and the real kqueue are never involved.

/// A pretend kernel process table.
final class FakeAquaTable: AquaProcessTable {
    struct Proc { var start: UInt64; var zombie = false; var aqua = true; var pathReadable = true }
    var processes: [Int32: Proc] = [:]
    var scanFails = false
    var scans = 0
    func scan() -> [AquaCandidate]? {
        scans += 1
        if scanFails { return nil }
        return processes.filter { $0.value.aqua && $0.value.pathReadable }
            .map { AquaCandidate(generation: AquaGeneration(pid: $0.key, start: $0.value.start), zombie: $0.value.zombie) }
    }
    func facts(of pid: Int32) -> AquaProcessFacts? { processes[pid].map { AquaProcessFacts(start: $0.start, zombie: $0.zombie) } }
    func isAqua(pid: Int32) -> Bool { processes[pid].map { $0.aqua && $0.pathReadable } ?? false }
    func start(_ pid: Int32, at start: UInt64 = 1000) { processes[pid] = Proc(start: start) }
    func exit(_ pid: Int32) { processes[pid] = nil }
}

/// A pretend exit registration: the test decides what each registration returns and when an exit is delivered.
final class FakeExitRegistry: AquaExitRegistry {
    var onExit: ((Int32) -> Void)?
    var available = true
    private(set) var registrations: Set<Int32> = []
    private(set) var watchCalls = 0
    var result: (Int32) -> AquaExitWatch = { _ in .registered }
    /// The next this-many registrations are refused (EPERM) before `result` is asked.
    var refuseNext = 0
    private(set) var recreations = 0
    /// Runs after a registration succeeded and before `watch` returns: the moment between the registration and the check.
    var afterRegistering: ((Int32) -> Void)?
    func watch(pid: Int32) -> AquaExitWatch {
        watchCalls += 1
        let outcome: AquaExitWatch
        if refuseNext > 0 { refuseNext -= 1; outcome = .failed(EPERM) } else { outcome = result(pid) }
        if outcome == .registered { registrations.insert(pid); afterRegistering?(pid) }
        return outcome
    }
    func unwatch(pid: Int32) { registrations.remove(pid) }
    func holds(pid: Int32) -> Bool { registrations.contains(pid) }
    func recreate() -> Bool { recreations += 1; registrations.removeAll(); return true }
    /// The kernel delivers the exit of a registered process (one-shot), or fires an old callback explicitly when `force`.
    func deliverExit(_ pid: Int32, force: Bool = false) {
        guard force || registrations.contains(pid) else { return }
        if !force { registrations.remove(pid) }      // a one-shot event releases its own registration; an old callback leaves the current one
        onExit?(pid)
    }
}

let aquaBundle = "com.electron.aqua-voice"

@MainActor
struct AquaRig {
    let rig: RuntimeRig
    let table: FakeAquaTable
    let registry: FakeExitRegistry
    let center: NotificationCenter
    var runtime: AgentRuntime { rig.runtime }
    var shown: Bool { rig.stage.lastFrame != nil }

    init(running: Bool = true, table existing: FakeAquaTable? = nil, registry existingRegistry: FakeExitRegistry? = nil,
         setup: ((FakeAquaTable, FakeExitRegistry) -> Void)? = nil, store: OwnState? = nil, state: AgentState? = nil, wall: Date? = nil, control: [String: Any]? = nil, virtual: Bool = false) throws {
        let table = existing ?? FakeAquaTable()
        let registry = existingRegistry ?? FakeExitRegistry()
        let center = NotificationCenter()
        if running, existing == nil { table.start(500) }
        setup?(table, registry)
        self.table = table; self.registry = registry; self.center = center
        rig = try RuntimeRig(store: store, state: state, control: control, aquaRunning: false, virtual: virtual, prepare: { machine in
            machine.aquaTable = table; machine.aquaRegistry = registry; machine.workspaceCenter = center; machine.wall = wall
        })
    }
    /// The kernel ends the process and delivers its exit event.
    func quit(_ pid: Int32 = 500) { table.exit(pid); registry.deliverExit(pid) }
    func listChanged() { rig.machine.listChanged?() }
    func appendAquaLog(_ text: String) throws {
        if !FileManager.default.fileExists(atPath: try rig.store.url("aqua/main.log").path) { try rig.store.write(Data(), to: "aqua/main.log") }
        try rig.store.append(text, to: "aqua/main.log")
    }
    func bootstrapLine() -> String { "[\(stamp(Date()))] [info]  (Main)  app.bootstrap version=0.21.4\n" }
    func shutdownLine() -> String { "[\(stamp(Date()))] [info]  (SystemBridge)  Shutdown initiated\n" }
    func diag() -> [String] {
        let text = String(decoding: (try? ReadOnlyFile.data(try rig.store.url("aqua-diag.log").path)) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n").map(String.init)
    }
    var quietReasons: [String] { rig.stage.scheduler.quietReasons.map(\.rawValue).sorted() }
}

@Suite("Aqua follow", .serialized)
@MainActor
struct AquaFollowSuite {
    @Test func AquaFollow_anExitWithNoNotificationAndNoShutdownLineHidesClawd() throws {
        let aqua = try AquaRig()
        #expect(aqua.shown); #expect(aqua.registry.registrations == [500], "start-up armed the exit source of the live Aqua")
        #expect(aqua.runtime.controller.aquaRunning)
        aqua.quit()
        #expect(!aqua.shown, "Clawd has no window the moment Aqua's process is gone")
        #expect(!aqua.runtime.controller.aquaRunning); #expect(aqua.quietReasons == ["aqua-not-running"])
        #expect(aqua.rig.lines("AQUA exit pid=500").count == 1); #expect(aqua.rig.lines("QUIET on reason=aqua-not-running").count == 1)
        #expect(aqua.registry.registrations.isEmpty, "no registration is left while Aqua is gone")
    }

    @Test func AquaFollow_anExitWhileTheListStillShowsTheOldProcessHidesClawd() throws {
        let aqua = try AquaRig()
        aqua.registry.deliverExit(500)      // the kernel table (and the application list) still show the pid, live
        #expect(!aqua.shown, "an exited generation is never live again, whatever the table still lists")
        aqua.listChanged()
        aqua.runtime.workspaceApplication(launched: true, bundleIdentifier: aquaBundle, name: "Aqua Voice", pid: 500)
        #expect(!aqua.shown)
        aqua.table.processes[500]?.zombie = true      // and the zombie entry the kernel keeps until the parent reaps it
        aqua.listChanged()
        #expect(!aqua.shown); #expect(aqua.registry.registrations.isEmpty)
    }

    @Test func AquaFollow_anExitLongAfterTheShutdownLineStillHidesClawd() throws {
        let aqua = try AquaRig()
        aqua.runtime.controller.receive(line: aqua.shutdownLine().trimmingCharacters(in: .newlines))
        #expect(aqua.shown, "the shutdown line alone does not hide: the process is still alive")
        let timers = aqua.rig.stage.wake.armedTimers
        for _ in 0..<5 { aqua.listChanged() }
        #expect(aqua.shown); #expect(aqua.rig.stage.wake.armedTimers == timers, "waiting arms nothing")
        aqua.quit()      // however long after the line
        #expect(!aqua.shown); #expect(aqua.quietReasons == ["aqua-not-running"])
    }

    @Test func AquaFollow_aRestartBetweenShutdownAndExitStillHidesClawd() throws {
        let first = try AquaRig()
        first.runtime.controller.receive(line: first.shutdownLine().trimmingCharacters(in: .newlines))
        // The agent restarts here: a new process, a new registry, the same kernel.
        let second = try AquaRig(table: first.table, registry: FakeExitRegistry())
        #expect(second.shown); #expect(second.registry.registrations == [500], "the new agent reconciles at start-up and arms the live Aqua")
        second.quit()
        #expect(!second.shown); #expect(second.quietReasons == ["aqua-not-running"])
    }

    @Test func AquaFollow_anExitBetweenTheScanAndTheRegistrationIsCaught() throws {
        let aqua = try AquaRig(setup: { table, registry in registry.result = { _ in table.exit(500); return .gone } })
        #expect(!aqua.shown, "ESRCH: the process was gone before the registration, the generation is exited")
        #expect(!aqua.runtime.controller.aquaRunning); #expect(aqua.registry.registrations.isEmpty)
        #expect(aqua.registry.watchCalls == 1, "an exited generation is not tried again")
    }

    @Test func AquaFollow_anExitAfterRegistrationBeforeVerificationIsDelivered() throws {
        // The process ends after the registration succeeded and before the check: the check sees it gone ...
        let gone = try AquaRig(setup: { table, registry in registry.afterRegistering = { table.exit($0) } })
        #expect(!gone.shown); #expect(gone.registry.registrations.isEmpty)
        // ... or a zombie; the exit event that follows is stale and changes nothing.
        let zombie = try AquaRig(setup: { table, registry in registry.afterRegistering = { table.processes[$0]?.zombie = true } })
        #expect(!zombie.shown)
        zombie.registry.deliverExit(500, force: true)
        #expect(!zombie.shown); #expect(zombie.rig.lines("AQUA exit stale pid=500").count == 1)
    }

    @Test func AquaFollow_aZombieNeverCountsAsLive() throws {
        let atStart = try AquaRig(setup: { table, _ in table.processes[500]?.zombie = true })
        #expect(!atStart.shown, "a zombie at start-up is an Aqua that already exited")
        let later = try AquaRig()
        #expect(later.shown)
        later.table.processes[500]?.zombie = true      // exited, not yet reaped, and no event arrived
        later.listChanged()
        #expect(!later.shown); #expect(later.quietReasons == ["aqua-not-running"])
    }

    @Test func AquaFollow_aPidReusedAtTheAttachIsNotTracked() throws {
        // Another process took the pid between the scan and the check: same pid, another start time.
        let reused = try AquaRig(setup: { table, registry in
            registry.afterRegistering = { table.processes[$0]?.start = 7777; table.processes[$0]?.pathReadable = false }
        })
        #expect(!reused.shown); #expect(reused.registry.registrations.isEmpty, "the registration of the wrong process is deleted")
        // The same pid, now a process that is not Aqua at all.
        let other = try AquaRig(setup: { table, registry in registry.afterRegistering = { table.processes[$0]?.aqua = false } })
        #expect(!other.shown)
    }

    @Test func AquaFollow_aTrackedAquaStaysTrackedWhenAnUpdateMakesItsPathUnreadable() throws {
        let aqua = try AquaRig()
        aqua.table.processes[500]?.pathReadable = false      // the bundle was replaced under the running process
        aqua.listChanged(); aqua.runtime.workspaceApplication(launched: false, bundleIdentifier: "com.example.x", name: "X", pid: 9)
        aqua.rig.machine.sink?.setQuiet(.screenLocked, active: false)
        #expect(aqua.shown, "identity is needed only to find a generation, not to keep one"); #expect(aqua.registry.registrations == [500])
        aqua.quit()
        #expect(!aqua.shown)
    }

    @Test func AquaFollow_theBootstrapLineShowsClawdBeforeTheListKnowsAqua() async throws {
        // The kernel has no Aqua yet; the application list (the runtime's own answer) never learns of it, no notification arrives.
        let aqua = try AquaRig(running: false)
        #expect(!aqua.shown); #expect(aqua.quietReasons == ["aqua-not-running"])
        try aqua.appendAquaLog("")
        await aqua.rig.spin(0.3)
        aqua.table.start(600, at: 2000)
        try aqua.appendAquaLog(aqua.bootstrapLine())
        await aqua.rig.spin(until: { aqua.shown })
        #expect(aqua.shown, "the log watch's kernel file event runs the reconcile, which finds Aqua in the kernel")
        #expect(aqua.runtime.controller.aquaRunning); #expect(aqua.registry.registrations == [600])
        #expect(aqua.diag().contains { $0.contains("trigger=bootstrap") })
    }

    @Test func AquaFollow_aStaleExitCallbackDoesNotReconcile() throws {
        let aqua = try AquaRig()
        aqua.quit(500)
        aqua.table.start(600, at: 2000)
        aqua.runtime.workspaceApplication(launched: true, bundleIdentifier: aquaBundle, name: "Aqua Voice", pid: 600)
        #expect(aqua.shown); #expect(aqua.registry.registrations == [600])
        let before = aqua.runtime.aquaReconcileCount
        aqua.registry.deliverExit(500, force: true)      // the old generation's callback, fired late
        #expect(aqua.runtime.aquaReconcileCount == before, "a stale callback reconciles nothing")
        #expect(aqua.rig.lines("AQUA exit stale pid=500").count == 1); #expect(aqua.shown)
    }

    @Test func AquaFollow_aStaleLaunchNotificationAfterTheExitKeepsClawdHidden() throws {
        let aqua = try AquaRig()
        aqua.quit()
        #expect(!aqua.shown)
        // The launch notification of the old run arrives after the exit: it carries a claim, the kernel has the facts.
        aqua.runtime.workspaceApplication(launched: true, bundleIdentifier: aquaBundle, name: "Aqua Voice", pid: 500)
        #expect(!aqua.shown); #expect(!aqua.runtime.controller.aquaRunning)
        aqua.center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)      // no payload at all
        #expect(!aqua.shown)
    }

    @Test func AquaFollow_anUpdateReplacingTheProcessKeepsTheNewOneShown() throws {
        let aqua = try AquaRig()
        aqua.table.start(600, at: 2000)      // the updated Aqua starts while the old one is still running
        aqua.runtime.controller.receive(line: aqua.bootstrapLine().trimmingCharacters(in: .newlines))
        #expect(aqua.shown); #expect(aqua.registry.registrations == [500], "the tracked generation is kept while it is live")
        aqua.quit(500)
        #expect(aqua.shown, "the exit of the old one finds the new one"); #expect(aqua.registry.registrations == [600])
        #expect(aqua.runtime.controller.aquaRunning)
        aqua.quit(600)
        #expect(!aqua.shown)
        aqua.table.start(700, at: 3000)
        aqua.runtime.controller.receive(line: aqua.bootstrapLine().trimmingCharacters(in: .newlines))
        #expect(aqua.shown); #expect(aqua.registry.registrations == [700])
    }

    @Test func AquaFollow_quitAndStartWhileLockedAsleepHiddenDraggedOrDictating() throws {
        let sinkRig = try AquaRig()
        let sink = try #require(sinkRig.rig.machine.sink)
        // Locked: Aqua quits and starts again while the screen is locked; the unlock shows Clawd only because Aqua runs.
        sink.setQuiet(.screenLocked, active: true)
        sinkRig.quit(500); sinkRig.table.start(510, at: 1500)
        sinkRig.runtime.controller.receive(line: sinkRig.bootstrapLine().trimmingCharacters(in: .newlines))
        #expect(!sinkRig.shown, "locked: nothing shows")
        sink.setQuiet(.screenLocked, active: false)
        #expect(sinkRig.shown); #expect(sinkRig.registry.registrations == [510])
        // Locked, and Aqua is gone at the unlock: it stays hidden.
        sink.setQuiet(.screenLocked, active: true)
        sinkRig.quit(510)
        sink.setQuiet(.screenLocked, active: false)
        #expect(!sinkRig.shown)

        // Asleep: Aqua quits during sleep; the wake reconciles before it lifts its own reason.
        let asleep = try AquaRig()
        asleep.rig.stage.setQuiet(.systemAsleep, active: true)
        asleep.table.exit(500)      // the exit event is lost with the sleep
        asleep.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!asleep.shown); #expect(asleep.quietReasons == ["aqua-not-running"])
        asleep.table.start(510, at: 1500)
        asleep.runtime.controller.receive(line: asleep.bootstrapLine().trimmingCharacters(in: .newlines))
        #expect(asleep.shown)

        // Hidden from the menu: Aqua's quit and start leave the hide alone.
        let menuHidden = try AquaRig(control: ["hiddenUntil": -1])
        #expect(!menuHidden.shown); #expect(menuHidden.rig.stage.scheduler.visibility == .hidden)
        menuHidden.quit()
        menuHidden.table.start(510, at: 1500)
        menuHidden.runtime.controller.receive(line: menuHidden.bootstrapLine().trimmingCharacters(in: .newlines))
        #expect(!menuHidden.shown); #expect(menuHidden.rig.stage.scheduler.visibility == .hidden, "the hide still holds after Aqua's quit and start")
        #expect(menuHidden.runtime.controller.aquaRunning)

        // Dictating: the scene ends with Aqua.
        let dictating = try AquaRig()
        dictating.runtime.controller.receive(line: startLine(SystemPetClock()).trimmingCharacters(in: .newlines))
        #expect(dictating.runtime.controller.machine.scene == .listening)
        dictating.quit()
        #expect(!dictating.shown); #expect(dictating.runtime.controller.machine.lease == nil)

        // Mid-drag: a press on Clawd is in progress when Aqua quits; the window goes and nothing is left half-pressed.
        let dragged = try AquaRig()
        let body = try dragged.rig.points().body
        dragged.rig.machine.pointer = body
        dragged.rig.view.mouseDown(with: try dragged.rig.event(.leftMouseDown, at: dragged.rig.window(body)))
        dragged.quit()
        #expect(!dragged.shown)
        dragged.table.start(510, at: 1500)
        dragged.runtime.controller.receive(line: dragged.bootstrapLine().trimmingCharacters(in: .newlines))
        #expect(dragged.shown, "Aqua started again: Clawd comes back")
    }

    @Test func AquaFollow_exactlyOneExitSourceWhileAquaRunsAndNoTimer() throws {
        let aqua = try AquaRig()
        #expect(aqua.registry.registrations == [500])
        let timers = aqua.rig.stage.wake.armedTimers
        for index in 0..<20 {
            aqua.listChanged()
            aqua.runtime.workspaceApplication(launched: index % 2 == 0, bundleIdentifier: "com.example.app\(index)", name: "App", pid: Int32(index + 10))
            aqua.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        }
        #expect(aqua.registry.registrations == [500]); #expect(aqua.registry.watchCalls == 1, "triggers never register again while Aqua is tracked")
        #expect(aqua.rig.stage.wake.armedTimers == timers, "no timer is armed by any of this")
        #expect(aqua.rig.stage.scheduler.aquaRetryAt == nil, "with Aqua watched no retry deadline is armed")
        // The count above cannot see a timer the follower made for itself; the source can: the only retry path is the scheduler's deadline.
        for name in ["AquaFollower.swift", "AquaKernel.swift", "AquaDiag.swift"] {
            let source = try String(contentsOf: repository.appendingPathComponent("Sources/ClawdCore/" + name), encoding: .utf8)
            for token in ["makeTimerSource", "Timer(", "Timer.scheduledTimer", "asyncAfter", "afterDelay"] {
                #expect(!source.contains(token), "\(name) must not contain \(token)")
            }
        }
        aqua.quit()
        #expect(aqua.registry.registrations.isEmpty); #expect(aqua.rig.stage.wake.armedTimers == 0)
        let before = aqua.table.scans
        for _ in 0..<5 { aqua.listChanged() }
        #expect(aqua.table.scans == before + 5, "while Aqua is gone each trigger scans the kernel once, and nothing scans on a clock")
        #expect(aqua.rig.stage.wake.armedTimers == 0)
    }

    @Test func AquaFollow_aFailedRegistrationStillTracksByVerificationAndRecordsIt() throws {
        // Every registration is refused; nothing (no notification, no list change) is sent that could rescue the case.
        let aqua = try AquaRig(setup: { _, registry in registry.result = { _ in .failed(EPERM) } })
        #expect(aqua.shown, "the process is verified live, so Clawd shows although it is unwatched")
        #expect(aqua.runtime.controller.aquaRunning)
        #expect(aqua.registry.recreations == 1, "the first refusal closes and recreates the kqueue once, then tries again at once")
        #expect(aqua.registry.watchCalls == 2)
        #expect(aqua.registry.registrations.isEmpty, "no registration exists, so the generation is not tracked")
        #expect(aqua.rig.lines("AQUA unwatched pid=500 errno=\(EPERM)").count == 1)
        #expect(aqua.diag().filter { $0.contains("trigger=unwatched") && $0.contains("pid=500 errno=\(EPERM)") }.count == 1)
        #expect(aqua.rig.stage.scheduler.aquaRetryAt != nil, "a retry deadline is armed on the scheduler's timer")
        #expect(aqua.rig.stage.wake.armedTimers <= 1, "and no second timer")
    }

    @Test func AquaFollow_aFailedRegistrationRetriesUntilWatched() throws {
        // EV_ADD is refused twice (the first attempt and its immediate retry); the retry one second later succeeds. The runtime runs on a
        // virtual clock, so "one second later" is exact.
        let aqua = try AquaRig(setup: { _, registry in registry.refuseNext = 2 }, virtual: true)
        #expect(aqua.shown); #expect(aqua.registry.registrations.isEmpty); #expect(aqua.rig.stage.scheduler.aquaRetryAt != nil)
        aqua.rig.advance(0.99)
        #expect(aqua.registry.registrations.isEmpty, "no retry before its deadline")
        #expect(aqua.registry.watchCalls == 2)
        aqua.rig.advance(0.01)
        #expect(aqua.registry.registrations == [500], "the retry registered the generation at +1.00 s of virtual time")
        #expect(aqua.shown); #expect(aqua.rig.stage.scheduler.aquaRetryAt == nil, "a successful registration ends the retries")
        #expect(aqua.registry.watchCalls == 3)
        #expect(aqua.rig.lines("AQUA unwatched pid=500").count == 1, "one line when it became unwatched, none per retry")
        aqua.rig.advance(10)
        #expect(aqua.registry.watchCalls == 3, "and no retry afterwards")
        // Watched now: the exit is delivered like any other.
        aqua.quit()
        #expect(!aqua.shown); #expect(aqua.quietReasons == ["aqua-not-running"])
        #expect(aqua.rig.stage.scheduler.aquaRetryAt == nil)
    }

    /// The same retry on the system clock and the dispatch timer, with a generous bound: it keeps the production wiring (the real timer
    /// that wakes the stage) covered while the tests around it run on virtual time.
    @Test func AquaFollow_smoke_aFailedRegistrationRetriesOnTheSystemClock() async throws {
        let aqua = try AquaRig(setup: { _, registry in registry.refuseNext = 2 })
        #expect(aqua.shown); #expect(aqua.registry.registrations.isEmpty)
        await aqua.rig.spin(until: { aqua.registry.registrations == [500] }, limit: 10)
        #expect(aqua.registry.registrations == [500], "the real timer fired the retry")
        #expect(aqua.rig.stage.scheduler.aquaRetryAt == nil)
    }

    @Test func AquaFollow_aSilentExitWhileUnwatchedHidesClawdWithinTwoSeconds() throws {
        // EV_ADD keeps failing; Aqua then exits with no notification, no log line and no list change.
        let aqua = try AquaRig(setup: { _, registry in registry.result = { _ in .failed(EPERM) } }, virtual: true)
        #expect(aqua.shown)
        aqua.table.exit(500)
        #expect(aqua.shown, "nothing told the runtime: until the retry looks, Clawd still shows")
        aqua.rig.advance(0.99)
        #expect(aqua.shown, "the retry deadline (1.00 s) has not come yet")
        aqua.rig.advance(0.01)
        #expect(!aqua.shown, "hidden by +1.00 s of virtual time: the retry finds Aqua gone and Clawd has no window")
        #expect(aqua.diag().contains { $0.contains("trigger=retry") && $0.contains("changed=yes") })
        #expect(!aqua.runtime.controller.aquaRunning); #expect(aqua.quietReasons == ["aqua-not-running"])
        #expect(aqua.rig.stage.scheduler.aquaRetryAt == nil, "nothing is retried once no Aqua generation is unwatched")
    }

    @Test func AquaFollow_aKernelScanFailureHidesAndTheNextTriggerRecovers() throws {
        let aqua = try AquaRig(setup: { table, _ in table.scanFails = true })
        #expect(!aqua.shown); #expect(aqua.diag().contains { $0.contains("scan=failed") })
        aqua.table.scanFails = false
        aqua.listChanged()
        #expect(aqua.shown)
    }

    @Test func AquaFollow_diagnosticsRecordEveryNotificationWithItsIdentityAndThePayloadState() throws {
        let aqua = try AquaRig()
        let first = aqua.diag()
        #expect(first.first?.contains("observers workspace=installed kvo=installed logwatch=") == true)
        #expect(first.first?.contains("kqueue=ok") == true)
        aqua.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.example.other", name: "Other App", pid: 77)
        aqua.center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        aqua.listChanged()
        aqua.quit()
        let lines = aqua.diag()
        func line(_ text: String) -> String? { lines.first { $0.contains(text) } }
        let other = try #require(line("bundle=com.example.other"))
        #expect(other.contains("trigger=launch")); #expect(other.contains("name=Other_App")); #expect(other.contains("pid=77")); #expect(other.contains("payload=present"))
        #expect(other.contains("live=500:1000")); #expect(other.contains("changed=no")); #expect(other.contains("controller_aqua=yes")); #expect(other.contains("window=presented"))
        let missing = try #require(line("payload=missing"))
        #expect(missing.contains("trigger=terminate")); #expect(missing.contains("bundle=nil")); #expect(missing.contains("pid=nil"))
        #expect(line("trigger=kvo") != nil)
        let exit = try #require(line("trigger=exit"))
        #expect(exit.contains("pid=500 gen=1 stale=no")); #expect(exit.contains("live=none")); #expect(exit.contains("exited=1"))
        #expect(exit.contains("quiet=aqua-not-running")); #expect(exit.contains("controller_aqua=no")); #expect(exit.contains("window=none")); #expect(exit.contains("changed=yes"))
        // One line per record, sequence numbers consecutive from 1.
        let numbers = lines.compactMap { Int($0.dropFirst().prefix { $0.isNumber }) }
        #expect(numbers == Array(1...numbers.count)); #expect(numbers.count == lines.count)
    }

    @Test func AquaFollow_diagnosticsArePairedBoundedAndSurviveRotationAndRestart() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try AquaRig(wall: start)
        let store = first.rig.store
        let opening = first.diag().count
        #expect(opening >= 2, "the observers line and the start-up reconcile")
        // agent.log rotating does not touch aqua-diag.log.
        let filler = String(repeating: "x", count: 100 * 1024) + "\n"
        for _ in 0..<7 { try store.appendAgentLogUnmanaged(filler, rotatingAt: 512 * 1024) }   // a rotation, without writing 3 MiB
        #expect(FileManager.default.fileExists(atPath: try store.url("agent.log.1").path), "agent.log did rotate")
        #expect(first.diag().count == opening, "and the diagnostics did not move")
        // A restart continues the sequence.
        let state = try first.rig.state
        #expect(state.aquaDiagUntil == start.timeIntervalSince1970 + 7 * 86400, "the window is written once, at the first start")
        let second = try AquaRig(table: first.table, registry: FakeExitRegistry(), store: store, state: state, wall: start.addingTimeInterval(3600))
        let afterRestart = second.diag()
        #expect(afterRestart.count > opening); #expect(afterRestart.last?.hasPrefix("#\(afterRestart.count) ") == true)
        // Inside the window every trigger is one line; at the cap writing stops with one last line and nothing is ever truncated.
        // (Notifications of other apps fill it: unchanged list changes would only be counted.) The fill yields every 100 rounds, so the other
        // main-actor tests of the full suite are not starved while 1 MB is written.
        var sent = 0
        while sent < 6000 {
            second.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.example.fill\(sent)", name: nil, pid: Int32(200 + sent % 100))
            second.listChanged(); sent += 1
            if sent % 100 == 0 { await Task.yield() }
        }
        let capped = second.diag()
        let size = try ReadOnlyFile.data(try store.url("aqua-diag.log").path).count
        #expect(size <= AquaDiag.defaultCap, "the file never passes its cap: \(size)")
        #expect(capped.last?.contains(" CAP ") == true, "one last line says the cap was reached")
        #expect(capped.filter { $0.contains(" CAP ") }.count == 1)
        let numbers = capped.compactMap { Int($0.dropFirst().prefix { $0.isNumber }) }
        #expect(numbers == Array(1...numbers.count), "consecutive, paired, never truncated")
        #expect(capped.starts(with: Array(afterRestart.prefix(opening))), "earlier lines are untouched")
        // Past seven days nothing is written (a fresh file would show it; here the cap line is final already, so use a new store).
        let late = try AquaRig(running: true, wall: start)
        let lateState = try late.rig.state
        let beyond = try AquaRig(table: late.table, registry: FakeExitRegistry(), store: late.rig.store, state: lateState, wall: start.addingTimeInterval(8 * 86400))
        let before = beyond.diag().count
        beyond.listChanged(); beyond.quit()
        #expect(beyond.diag().count == before, "past the window nothing is written")
    }

    @Test func AquaFollow_aStaleEventForTheSamePidOfAnOlderGenerationIsIgnored() throws {
        let aqua = try AquaRig()
        // The first generation is gone and its pid was reused by the updated Aqua (same pid, another start time); a trigger found it.
        aqua.table.start(500, at: 2000)
        aqua.listChanged()
        #expect(aqua.shown); #expect(aqua.registry.registrations == [500])
        let before = aqua.runtime.aquaReconcileCount
        aqua.registry.deliverExit(500, force: true)      // the first generation's exit event, delivered late: the pid is the same
        #expect(aqua.runtime.aquaReconcileCount == before, "a stale event for the same pid reconciles nothing")
        #expect(aqua.shown); #expect(aqua.runtime.controller.aquaRunning); #expect(aqua.registry.registrations == [500])
        #expect(aqua.rig.lines("AQUA exit stale pid=500").count == 1)
        // The real exit of the new generation is still seen.
        aqua.quit(500)
        #expect(!aqua.shown)
    }

    @Test func AquaFollow_anExamStandDownAndAnAquaRestartKeepBothReasonsRight() throws {
        // The Aqua follow beside the exam stand-down on the virtual clock (the stage runtime wired as AgentRuntime wires the follower).
        for restarts in [true, false] {
            let exam = try ExamRig()
            let table = FakeAquaTable(); table.start(500)
            let registry = FakeExitRegistry()
            var follower: AquaFollower!
            let state = { exam.scheduler.quietReasons.map(\.rawValue).sorted() }
            follower = AquaFollower(
                table: table, registry: registry,
                agrees: { notRunning in exam.scheduler.quietReasons.contains(.aquaNotRunning) == notRunning && exam.runtime.controller.aquaRunning == !notRunning },
                apply: { notRunning in exam.runtime.setQuiet(.aquaNotRunning, active: notRunning) },
                log: { _ in }, diag: nil, snapshot: { AquaPetSnapshot(quiet: "none", controllerAqua: true, window: true) },
                setRetry: { exam.runtime.setAquaRetry($0) })
            exam.runtime.onAquaRetry = { follower.reconcile(.retry) }
            follower.reconcile(.startup)
            exam.advance(5)
            #expect(exam.shown); #expect(state() == [])
            exam.launch(); exam.advance(20)
            #expect(exam.down && !exam.shown); #expect(state() == ["exam-browser"])
            // Aqua quits while the exam holds Clawd down: both reasons hold.
            table.exit(500); registry.deliverExit(500)
            #expect(state() == ["aqua-not-running", "exam-browser"])
            if restarts {
                // Aqua starts again: only the exam's reason is left, and Clawd is still away.
                table.start(510, at: 1500); follower.reconcile(.bootstrap)
                #expect(state() == ["exam-browser"]); #expect(!exam.shown); #expect(registry.registrations == [510])
            }
            exam.quit(); exam.advance(125)
            #expect(!exam.down, "the exam stand-down ended")
            if restarts {
                #expect(state() == []); #expect(exam.shown, "Aqua runs, so Clawd shows when the exam ends")
            } else {
                #expect(state() == ["aqua-not-running"]); #expect(!exam.shown, "Aqua does not run, so Clawd stays away when the exam ends")
                table.start(520, at: 1600); follower.reconcile(.bootstrap)
                #expect(state() == []); #expect(exam.shown)
            }
        }
    }

    /// The follower marks an unchanged list record as repeatable (amendment aqua-diag-coalesce D-2): ten list changes that change nothing
    /// are one full kvo line and one count of the other nine, written before the next notification.
    @Test func AquaFollow_unchangedListChangesAreCountedThroughTheFollower() throws {
        let aqua = try AquaRig()
        let opening = aqua.diag().count
        for _ in 0..<10 { aqua.listChanged() }
        aqua.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.example.flush", name: nil, pid: 99)
        let added = Array(aqua.diag().dropFirst(opening))
        try #require(added.count == 3, "\(added)")
        #expect(added[0].contains("trigger=kvo ") && added[0].contains("changed=no"), "\(added[0])")
        #expect(added[1].contains(" kvo-repeat count=9 "), "\(added[1])")
        #expect(added[2].contains("trigger=launch "), "\(added[2])")
    }

    @Test func AquaFollow_diagnosticsHoldExactlyOneRecordPerEventAndNothingAfterTheCap() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let aqua = try AquaRig(wall: start)
        let store = aqua.rig.store
        func sequence(_ lines: [String]) -> [Int] { lines.compactMap { Int($0.dropFirst().prefix { $0.isNumber }) } }
        func size() throws -> Int { (try FileManager.default.attributesOfItem(atPath: try store.url("aqua-diag.log").path)[.size] as? Int) ?? 0 }
        /// One notification of the kind `index` says: another app's launch, another app's quit, Aqua's own launch, a payload-less post.
        func notify(_ index: Int) {
            switch index % 4 {
            case 0: aqua.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.example.app\(index)", name: "App \(index)", pid: Int32(100 + index))
            case 1: aqua.runtime.workspaceApplication(launched: false, bundleIdentifier: "com.example.app\(index)", name: nil, pid: 9)
            case 2: aqua.runtime.workspaceApplication(launched: true, bundleIdentifier: aquaBundle, name: "Aqua Voice", pid: 500)
            default: aqua.center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
            }
        }
        // N notifications of mixed apps and M list changes, interleaved: exactly N + M new lines, consecutive sequence numbers.
        let opening = aqua.diag().count
        let notifications = 12, listChanges = 7
        for index in 0..<max(notifications, listChanges) {
            if index < notifications { notify(index) }
            if index < listChanges { aqua.listChanged() }
        }
        // Every notification is a line of its own; every list change is either a line of its own or counted in a kvo-repeat line (amendment
        // aqua-diag-coalesce), so none is dropped and none doubled.
        aqua.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.example.flush", name: nil, pid: 99)
        let lines = aqua.diag()
        #expect(sequence(lines) == Array(1...lines.count))
        let added = lines.dropFirst(opening)
        #expect(added.filter { $0.contains("trigger=launch") || $0.contains("trigger=terminate") }.count == notifications + 1)
        let repeated = added.compactMap { line -> Int? in
            guard let range = line.range(of: " kvo-repeat count=") else { return nil }
            return Int(line[range.upperBound...].prefix { $0.isNumber })
        }.reduce(0, +)
        #expect(added.filter { $0.contains("trigger=kvo") }.count + repeated == listChanges, "\(Array(added))")

        // Fill to within a few lines of the cap with notifications and list changes (an unchanged list change is counted and its count written
        // before the next notification), then send notifications one at a time: each is one line, and the one that no longer fits is the cap
        // line; nothing follows it.
        var filler = 0
        while try size() < AquaDiag.defaultCap - 1400 {
            notify(filler); filler += 1; aqua.listChanged()
            if filler % 100 == 0 { await Task.yield() }      // the other main-actor tests of the full suite run while 1 MB is written
        }
        notify(filler); filler += 1          // writes the count pending from the last list change, so each notification below is one line
        var sent = 0, hitCap = false
        while !hitCap, sent < 20 {
            let count = aqua.diag().count
            notify(sent); sent += 1
            let after = aqua.diag()
            #expect(after.count == count + 1, "a notification near the cap gets its own line or the cap line: \(after.suffix(3))")
            hitCap = after.last?.contains(" CAP ") == true
        }
        #expect(hitCap, "the cap line came within a few notifications")
        let capped = aqua.diag()
        let cappedSize = try size()
        #expect(cappedSize <= AquaDiag.defaultCap); #expect(capped.filter { $0.contains(" CAP ") }.count == 1)
        for index in 0..<4 { notify(index); aqua.listChanged() }
        aqua.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(aqua.diag() == capped, "nothing after the cap"); #expect(try size() == cappedSize)
        // A restart after the cap appends nothing either (not even its observers line).
        let state = try aqua.rig.state
        let second = try AquaRig(table: aqua.table, registry: FakeExitRegistry(), store: store, state: state, wall: start.addingTimeInterval(3600))
        second.listChanged()
        #expect(second.diag() == capped, "a restart after the cap appends nothing"); #expect(try size() == cappedSize)

        // Past seven days nothing is written, whatever happens.
        let early = try AquaRig(wall: start)
        let earlyState = try early.rig.state
        let late = try AquaRig(table: early.table, registry: FakeExitRegistry(), store: early.rig.store, state: earlyState, wall: start.addingTimeInterval(8 * 86400))
        let before = late.diag()
        late.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.example.late", name: "Late", pid: 5)
        late.listChanged(); late.quit()
        #expect(late.diag() == before, "past the window nothing is written")
    }
}
