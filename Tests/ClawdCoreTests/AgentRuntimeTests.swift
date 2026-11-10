import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// The desktop runtime (AgentRuntime) wired to the scheduler and the stage renderer, driven with synthetic events and fake displays.
// The panel is never ordered on screen (`present` only counts) and no observer or monitor is installed in the test process.

final class RuntimeMachine {
    var pointer = CGPoint.zero
    var presented = 0, dismissed = 0
    var idle: TimeInterval? = 0
    var sink: QuietSink?
    /// The menu's collaborators (Sprint M): none is real unless a test says so. Without a `home`, a pick would run the CLI of whoever runs the
    /// test, so the default is an empty directory of its own, in which there is no CLI to run.
    var menuTimer: MenuTimerSource?
    var menuSource: MenuOutsideClickSource?
    var home: URL?
    /// A display change is a test setting this and posting the system's notification; `displaysGone` is every display unplugged.
    var display = DisplayInfo(uuid: "D", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                              visibleFrame: CGRect(x: 0, y: 40, width: 1920, height: 1040), backingScaleFactor: 2)
    var displaysGone = false
    /// Further displays beside `display` (the pointer's display for the Settings window).
    var otherDisplays: [DisplayInfo] = []
    /// Whether a LockDown Browser application is running, as the runtime asks for it. No test ever starts the real app.
    var examRunning = false
    /// Whether Aqua Voice is installed, as the `auto` setting asks for it. No test reads the real application list.
    var aquaInstalled = true
    /// The installed Aqua Voice's version as the Voice section reads it (the RE seam; nil: none). No test reads the real application bundle.
    var aquaVersion: String?
    /// The Aqua follow's seams (amendment D-1 to D-5): without a table the runtime builds one from `aquaRunning`.
    var aquaTable: AquaProcessTable?
    var aquaRegistry: AquaExitRegistry?
    var workspaceCenter: NotificationCenter?
    /// What the runtime sees as the workspace's notification centre when a test sets none: a centre of its own, never the system's.
    private let quietWorkspaceCenter = NotificationCenter()
    /// The handler the runtime registered for the application list's observation; a test calls it to say the list changed.
    var listChanged: (() -> Void)?
    var wall: Date?
    /// A virtual clock and its fake timer (`RuntimeRig(virtual: true)`): the runtime then runs on them and only `RuntimeRig.advance` moves time.
    var clock: PetClock?
    var timer: PetFiringTimer?
    /// The chat (Clawd v3): without a session the environment has no chat and a double-click is what it was in v2.
    var chatSession: ((ChatSessionConfig) -> ChatSessionDriving?)?
    /// Every panel the runtime made key, in order (the fake open call), and what each such call also does (a test posts the notification).
    var chatKeys: [ChatPanel] = []
    var onChatKey: ((ChatPanel) -> Void)?
    /// The application's current event as the focus rule asks for it.
    var chatEvent: ChatCurrentEvent?
    var chatTimer: MenuTimerSource?
    /// The chat's focus seams: the do-nothing ones unless a test supplies its own.
    var chatFocus = ChatFocusSeams()
    /// The menu bar icon's seams: no status bar and an exit that does nothing, unless a test supplies its own.
    var statusBar: (() -> StatusItemSurface)?
    var exitProcess: (Int32) -> Void = { _ in }
    /// The Settings window's seams: nothing is shown, made key or picked unless a test supplies its own.
    var settingsPresent: (NSWindow) -> Void = { _ in }
    var settingsDismiss: (NSWindow) -> Void = { _ in }
    var settingsMakeKey: (SettingsWindow) -> Void = { _ in }
    var settingsFolderPicker: () -> SettingsFolderPicking = { InertFolderPicker() }
    /// Where Q6's search for `claude` looks: nowhere unless a test names stubbed folders, so no rig reads the real `/opt/homebrew/bin` or the home folder.
    var claudeSearch: [String] = []
    /// The clocks, the pid and the process table of the `open-settings` request: inert unless a test names them.
    var settingsRequestSeams = SettingsRequestSeams.inert
    func environment(aquaLog: String, aquaRunning: Bool = true) -> RuntimeEnvironment {
        RuntimeEnvironment(displays: { [unowned self] in self.displaysGone ? DisplaySet(all: []) : DisplaySet(all: [self.display] + self.otherDisplays) },
                           pointer: { [unowned self] in self.pointer }, aquaLogPath: { aquaLog }, aquaRunning: { aquaRunning },
                           present: { [unowned self] _ in self.presented += 1 }, dismiss: { [unowned self] _ in self.dismissed += 1 },
                           examBrowserRunning: { [unowned self] in self.examRunning },
                           inputIdle: { [unowned self] in self.idle },
                           observeDesktop: { [unowned self] sink, _ in self.sink = sink; return nil },
                           menuTimer: { [unowned self] in self.menuTimer ?? DispatchPetTimer() },
                           menuOutsideClicks: { [unowned self] in self.menuSource ?? MenuUninstalledSource() },
                           home: { [unowned self] in self.home ?? ((try? artifactStore().root) ?? URL(fileURLWithPath: "/nonexistent-home")) },
                           chatSession: chatSession,
                           chatMakeKey: { [unowned self] panel in self.chatKeys.append(panel); self.onChatKey?(panel) },
                           chatCurrentEvent: { [unowned self] in self.chatEvent },
                           chatTimer: { [unowned self] in self.chatTimer ?? DispatchPetTimer() },
                           chatFocus: chatFocus,
                           statusBar: statusBar, exitProcess: { [unowned self] in self.exitProcess($0) },
                           settingsPresent: { [unowned self] in self.settingsPresent($0) }, settingsDismiss: { [unowned self] in self.settingsDismiss($0) },
                           settingsMakeKey: { [unowned self] in self.settingsMakeKey($0) },
                           settingsFolderPicker: { [unowned self] in self.settingsFolderPicker() },
                           claudeSearch: claudeSearch,
                           settingsRequestSeams: settingsRequestSeams,
                           aquaTable: aquaTable, aquaExitRegistry: aquaRegistry,
                           workspaceCenter: { [unowned self] in self.workspaceCenter ?? self.quietWorkspaceCenter },
                           observeApplicationList: { [unowned self] handler in self.listChanged = handler; return nil },
                           wallClock: { [unowned self] in self.wall ?? Date() },
                           clock: { [unowned self] in self.clock ?? SystemPetClock() },
                           timer: { [unowned self] in self.timer ?? DispatchPetTimer() },
                           aquaInstalled: { [unowned self] in self.aquaInstalled },
                           aquaVersion: { [unowned self] in self.aquaVersion })
    }
}

/// An outside-click source that installs nothing, for every runtime test that is not about the menu's monitor.
final class MenuUninstalledSource: MenuOutsideClickSource {
    func install(_ handler: @escaping (TimeInterval) -> Void) -> AnyObject? { nil }
    func remove(_ token: AnyObject) {}
}

enum RuntimeRigError: Error { case noPointOutsideTheBodyWindow }

@MainActor
final class RuntimeRig {
    let machine = RuntimeMachine()
    let store: OwnState
    let runtime: AgentRuntime
    /// The focus monitor on a notification centre of its own: a test posts the key, main and activation notifications there.
    let monitor: FocusMonitor
    let center = NotificationCenter()
    var view: PetView { runtime.view }
    /// The stage window (the whole picture) and the body window (Clawd's body and costume pixels alone).
    var panel: PetPanel { runtime.panels.stage }
    var bodyPanel: PetPanel { runtime.panels.body }
    var stage: StageRuntime { runtime.stage }
    /// Set by `virtual: true`: the runtime's clock and its one timer, both under the test's hand.
    let virtualClock: VirtualClock?
    let virtualTimer: FakeScheduler?

    init(store existing: OwnState? = nil, state: AgentState? = nil, control: [String: Any]? = nil, aquaRunning: Bool = true, idle: TimeInterval? = 0,
         virtual: Bool = false, settingsRequest: SettingsRequestVerdict = .none, prepare: ((RuntimeMachine) throws -> Void)? = nil) throws {
        machine.idle = idle
        let vclock = virtual ? VirtualClock() : nil
        virtualClock = vclock
        virtualTimer = vclock.map { FakeScheduler(clock: $0) }
        machine.clock = vclock; machine.timer = virtualTimer
        try prepare?(machine)
        store = try existing ?? artifactStore()
        let home = SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1)
        try store.writeJSON(state ?? AgentState(position: home), to: "state.json")
        if let control { try JSONSerialization.data(withJSONObject: control).write(to: try store.url("control.json")) }
        monitor = FocusMonitor(store: store, center: center)
        let aquaLog = try store.url("aqua/main.log").path
        runtime = try AgentRuntime(store: store, monitor: monitor, art: artDirectory, control: AgentControl(),
                                   environment: machine.environment(aquaLog: aquaLog, aquaRunning: aquaRunning), settingsRequest: settingsRequest)
    }
    /// Moves virtual time forward by `seconds`, firing the runtime's one armed timer at its own instant exactly as the dispatch timer would
    /// (a one-shot: it is spent when it fires, and the handler arms the next).
    func advance(_ seconds: TimeInterval) {
        guard let clock = virtualClock else { preconditionFailure("advance needs RuntimeRig(virtual: true)") }
        advance(to: clock.now + seconds)
    }
    /// Moves virtual time to the instant `target` itself (not a sum of steps that may land a rounding error off it), firing the timer on the way.
    /// A target before now leaves the clock where it is: virtual time never runs backwards.
    func advance(to target: TimeInterval) {
        guard let clock = virtualClock, let timer = virtualTimer else { preconditionFailure("advance needs RuntimeRig(virtual: true)") }
        var steps = 0
        while let fire = timer.fireAt, fire <= target {
            guard steps < 200_000 else {
                Issue.record("advance(to: \(target)) gave up after 200000 timer fires with a deadline still due at \(fire): a deadline keeps re-arming at the same instant")
                return
            }
            let from = clock.now; clock.advance(max(0, fire - from)); clock.now = max(from, fire); timer.cancel(); timer.onFire?(); steps += 1
        }
        let from = clock.now; clock.advance(max(0, target - from)); clock.now = max(from, target)
    }
    var log: String { String(decoding: (try? ReadOnlyFile.data(try store.url("agent.log").path)) ?? Data(), as: UTF8.self) }
    func lines(_ prefix: String) -> [String] {
        log.split(separator: "\n").map { String($0.drop { $0 != " " }.dropFirst()) }.filter { $0.hasPrefix(prefix) }
    }
    var state: AgentState { get throws { try store.readJSON(AgentState.self, from: "state.json") } }
    var status: AgentStatus { get throws { try store.readJSON(AgentStatus.self, from: "status.json") } }

    func event(_ type: NSEvent.EventType, at windowPoint: CGPoint, clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }
    /// A global point on Clawd's body in the picture on screen, and one on a transparent pixel of the panel.
    func points() throws -> (body: CGPoint, clear: CGPoint) {
        let frame = try #require(stage.lastFrame, "nothing is on screen")
        let hit = frame.hit
        var body: CGPoint?, clear: CGPoint?
        let panelFrame = frame.panelFrame
        var y = panelFrame.minY + 0.5
        while y < panelFrame.maxY {
            var x = panelFrame.minX + 0.5
            while x < panelFrame.maxX {
                let p = CGPoint(x: x, y: y)
                if hit.containsBody(p) { if body == nil { body = p } } else if clear == nil { clear = p }
                x += 1
            }
            y += 1
        }
        return (try #require(body), try #require(clear))
    }
    /// A global point in the body window's coordinates: the clicks and the drag are delivered to the body window's view.
    /// A global point on the stage window that no window takes a click on: a transparent pixel of the stage outside the body window.
    func pointOutsideTheBodyWindow() throws -> CGPoint {
        let panelFrame = try #require(stage.lastFrame).panelFrame
        var y = panelFrame.maxY - 0.5
        while y > panelFrame.minY {
            var x = panelFrame.minX + 0.5
            while x < panelFrame.maxX {
                let p = CGPoint(x: x, y: y)
                if !bodyPanel.frame.contains(p) { return p }
                x += 1
            }
            y -= 1
        }
        throw RuntimeRigError.noPointOutsideTheBodyWindow
    }
    func window(_ global: CGPoint) -> CGPoint { CGPoint(x: global.x - bodyPanel.frame.minX, y: global.y - bodyPanel.frame.minY) }
    /// The windows that would take a click at a global point: every window of the pet that does not ignore mouse events and holds it.
    func takers(at global: CGPoint) -> [String] {
        let names: [(String, NSPanel)] = [("stage", runtime.panels.stage), ("body", runtime.panels.body)] + (runtime.panels.menu.map { [("menu", $0)] } ?? [])
        return names.filter { !$0.1.ignoresMouseEvents && $0.1.frame.contains(global) }.map(\.0)
    }
    func click(at global: CGPoint, clicks: Int = 1) throws {
        machine.pointer = global
        view.mouseDown(with: try event(.leftMouseDown, at: window(global), clicks: clicks))
        view.mouseUp(with: try event(.leftMouseUp, at: window(global), clicks: clicks))
    }
    /// Gives the main queue back so the file watcher's events (delivered on it) are handled: a main-actor test body is itself a block
    /// of the serial main queue, and a nested run loop cannot run another one.
    func spin(_ seconds: Double = 0.05) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func spin(until condition: () -> Bool, limit: Double = 3) async {
        let deadline = Date().addingTimeInterval(limit)
        while !condition(), Date() < deadline { await spin(0.02) }
    }
}

@Suite("Desktop runtime with the scheduler and the stage", .serialized)
@MainActor
struct AgentRuntimeSuite {
    @Test func Runtime_showsClawdAtHomeAndWritesTheFirstGeometryLine() throws {
        let rig = try RuntimeRig()
        #expect(rig.machine.presented > 0); #expect(!rig.panel.isVisible)
        let frame = try #require(rig.stage.lastFrame)
        #expect(rig.panel.frame == frame.panelFrame)
        let geom = try #require(rig.lines("GEOM t=").first)
        #expect(geom.contains("bubble=none")); #expect(!geom.contains("stage=none")); #expect(!geom.contains("hit=none"))
        #expect(rig.panel.ignoresMouseEvents, "the stage window never takes a click")
        #expect(!rig.bodyPanel.ignoresMouseEvents, "the body window always does")
        #expect(rig.bodyPanel.frame == frame.hit.bounds, "and it is exactly as big as Clawd's body and costume pixels")
        #expect(rig.stage.scheduler.look == "plain"); #expect(!rig.stage.scheduler.asleep)
    }

    @Test func Runtime_onlyTheBodyWindowTakesClicksAndTheBubbleAndTheTransparentStageNeverDo() throws {
        let rig = try RuntimeRig()
        let points = try rig.points()
        #expect(rig.takers(at: points.body) == ["body"], "over the body the body window takes the click, and no other window does")
        let outside = try rig.pointOutsideTheBodyWindow()
        #expect(rig.panel.frame.contains(outside) && rig.takers(at: outside).isEmpty, "over a transparent pixel of the stage no window takes it: it goes to the app behind")
        _ = points.clear
        // A dictation: the bubble appears; its pixels are not part of the hit region and not part of the body window.
        rig.runtime.controller.receive(line: startLine(SystemPetClock()).trimmingCharacters(in: .newlines))
        let frame = try #require(rig.stage.lastFrame)
        let bubble = try #require(frame.bubble, "the bubble is shown while he dictates").rect
        let inBubble = CGPoint(x: bubble.midX, y: bubble.midY)
        #expect(!frame.hit.containsBody(inBubble))
        #expect(rig.panel.frame.contains(inBubble), "the bubble is inside the stage window")
        #expect(rig.takers(at: inBubble).isEmpty, "a click on the bubble goes straight to the app behind")
        #expect(rig.panel.ignoresMouseEvents, "the stage window ignores mouse events while the bubble is up, as it always does")
        let geom = try #require(rig.lines("GEOM t=").last)
        #expect(!geom.contains("bubble=none"), "the GEOM line declares the bubble rectangle: \(geom)")
        #expect(rig.takers(at: try rig.points().body) == ["body"])
    }

    @Test func Runtime_aClickPlaysATouchReactionThreeClicksMakeClawdDizzyAndNoClickIsLostToTheV1ClickCountRule() throws {
        // The dizzy rule counts three clicks within 2 s on the clock the scheduler reads, and how long three clicks take on this machine is not
        // what is tested (the first click of a fresh runtime decodes the touch and multi-touch pictures, which took 8 s on a loaded machine). So
        // the test reads that clock where the scheduler does: every click it takes comes out as a touch or a multi-touch event stamped with the
        // clock's reading, and the rule is asserted on the stamps: the third click is a multi-touch exactly when it came within the window of the
        // first. The sequence is repeated (after the window, so no click of the last run still counts; a run that did not fit played no multi-touch, so nothing is ignored either) until a run fits the window,
        // so the wiring of the multi-touch is exercised whenever the machine allows; a run that did not fit proves the rule from the other side.
        let rig = try RuntimeRig()
        var stamps: [(at: TimeInterval, multi: Bool)] = []
        let original = rig.stage.scheduler.onEvent
        rig.stage.scheduler.onEvent = { at, event in
            if event == .touch { stamps.append((at, false)) } else if event == .multiTouch { stamps.append((at, true)) }
            original?(at, event)
        }
        var fitted = 0, tooSlow = 0
        for _ in 1...6 {
            stamps.removeAll()
            let touches = rig.lines("TOUCH").count, multis = rig.lines("TOUCH multi").count, downs = rig.lines("INPUT kind=mouseDown").count
            try rig.click(at: try rig.points().body)
            #expect(rig.lines("TOUCH").count == touches + 1, "a click on the body is one touch: \(rig.lines("TOUCH"))")
            #expect(rig.stage.lastRequest?.frame.playback?.use == "touch")
            try rig.click(at: try rig.points().body, clicks: 2)
            try rig.click(at: try rig.points().body, clicks: 3)
            #expect(rig.lines("INPUT kind=mouseDown").count == downs + 3, "no click is lost to the v1 click-count rule")
            #expect(stamps.count == 3, "the scheduler took each of the three clicks: \(stamps)")
            guard stamps.count == 3 else { break }
            let span = stamps[2].at - stamps[0].at
            if span <= PetScheduler.multiTouchWindow {
                #expect(stamps[2].multi && rig.lines("TOUCH multi").count == multis + 1, "the third click inside \(PetScheduler.multiTouchWindow) s (\(span) s): \(rig.lines("TOUCH"))")
                #expect(rig.stage.lastRequest?.frame.playback?.use == "multi-touch")
                fitted += 1
            } else {
                #expect(!stamps[2].multi && rig.lines("TOUCH multi").count == multis, "three clicks over \(span) s are not three clicks within \(PetScheduler.multiTouchWindow) s")
                tooSlow += 1
            }
            if fitted > 0 { break }
            Thread.sleep(forTimeInterval: PetScheduler.multiTouchWindow + 0.2)
        }
        if fitted == 0 { emit("NOTE Runtime_aClickPlaysATouchReaction: no run of three clicks fitted the window (\(tooSlow) runs of three clicks took longer than \(PetScheduler.multiTouchWindow) s of the scheduler's clock); the multi-touch was asserted absent in each") }
    }

    @Test func Runtime_aClickOnATransparentPixelIsIgnoredAndPlaysNothing() throws {
        let rig = try RuntimeRig()
        let clear = try rig.points().clear
        try rig.click(at: clear)
        #expect(rig.lines("TOUCH").isEmpty); #expect(rig.lines("INPUT kind=").isEmpty)
        #expect(rig.lines("MOUSE-IGNORED kind=mouseDown").count == 1)
    }

    @Test func Runtime_aDragMovesClawdSavesTheNewHomeOnReleaseAndLandsWithoutATouchReaction() throws {
        let rig = try RuntimeRig()
        let start = try rig.state.position
        let body = try rig.points().body
        rig.machine.pointer = body
        rig.view.mouseDown(with: try rig.event(.leftMouseDown, at: rig.window(body)))
        let to = CGPoint(x: body.x + 300, y: body.y + 120)
        rig.machine.pointer = to
        rig.view.mouseDragged(with: try rig.event(.leftMouseDragged, at: rig.window(body)))
        #expect(rig.stage.lastRequest?.frame.dragging == true); #expect(rig.stage.lastRequest?.frame.playback.map { _ in true } == true)
        let canvas = try #require(rig.stage.lastFrame).canvas
        #expect(abs(canvas.minX - (body.x + 300 - (body.x - (try #require(rig.stage.lastRequest?.geometry.homeOrigin.x ?? nil) ?? 0)))) < 400)
        #expect(try rig.state.position == start, "the position is saved on release, not during the drag")
        rig.view.mouseUp(with: try rig.event(.leftMouseUp, at: rig.window(body)))
        let saved = try rig.state.position
        #expect(saved != start); #expect(saved.xFrac > start.xFrac); #expect(saved.feetFrac > start.feetFrac)
        #expect(rig.stage.lastRequest?.frame.dragging == false)
        #expect(rig.lines("TOUCH").isEmpty, "letting go after a drag is not a click")
        let home = try #require(rig.stage.lastRequest?.geometry.homeOrigin)
        #expect(abs(home.x - (saved.xFrac * 1920 - 24)) < 1)
        let planning = rig.stage.scheduler.geometry.homeOrigin
        #expect(abs(planning.x - home.x) < 0.5 && abs(planning.y - home.y) < 0.5, "the scheduler's home is where Clawd was dropped (a later walk starts there): \(planning) against \(home)")
        #expect(try rig.state.look == "plain", "the look survives the position write")
    }

    @Test func Runtime_aQuietConditionRemovesTheWindowStopsThePointerWatchAndLiftingItShowsClawdAgain() throws {
        let rig = try RuntimeRig()
        let sink = try #require(rig.machine.sink)
        let before = rig.machine.dismissed
        sink.setQuiet(.screenLocked, active: true)
        #expect(rig.machine.dismissed >= before + 2, "both windows are ordered out"); #expect(rig.stage.lastFrame == nil)
        #expect(rig.stage.wake.armedTimers == 0)
        #expect(rig.lines("QUIET on reason=screen-locked").count == 1)
        let shown = rig.machine.presented
        sink.setQuiet(.screenLocked, active: false)
        #expect(rig.machine.presented > shown); #expect(rig.stage.lastFrame != nil)
        #expect(rig.lines("QUIET off").count == 1)
        sink.setReduceMotion(true)
        #expect(rig.stage.scheduler.reduceMotion)
    }

    @Test func Runtime_awayForTenMinutesClawdDozesOffAndAClickWakesIt() throws {
        let rig = try RuntimeRig(idle: 700)
        #expect(rig.stage.scheduler.asleep, "700 s without input at the start: asleep")
        #expect(rig.stage.lastRequest?.frame.asleep == true)
        rig.machine.idle = 0                     // the click is input: the window server's idle counter starts again
        try rig.click(at: try rig.points().body)
        #expect(!rig.stage.scheduler.asleep, "a click wakes Clawd"); #expect(rig.lines("TOUCH").isEmpty, "and only wakes it")
        #expect(rig.lines("SLEEP start").count == 1, "\(rig.log)"); #expect(rig.lines("SLEEP wake").count == 1)
    }

    @Test func Runtime_onAOneXDisplayTheSizePickedIsTheSizeDrawn() async throws {
        // Tom, 2026-11-09: on the 1x monitor 0.75 looked like 0.5 (and 1.5 like 1). The size never depends on the display.
        for (size, side) in [(0.5, 24.0), (0.75, 36.0), (1, 48.0), (1.5, 72.0)] {
            let rig = try RuntimeRig(control: ["scale": size, "generation": 0], prepare: { machine in
                machine.display = DisplayInfo(uuid: "D", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                              visibleFrame: CGRect(x: 0, y: 40, width: 1920, height: 1040), backingScaleFactor: 1)
            })
            await rig.spin(until: { rig.stage.lastFrame != nil })
            let frame = try #require(rig.stage.lastFrame, "size \(size): nothing drawn")
            #expect(frame.canvas.width == side && frame.pixelScale == 1, "size \(size): canvas \(frame.canvas.width) pt at \(frame.pixelScale)x")
            #expect(rig.stage.scheduler.geometry.scale == size, "size \(size): the scheduler plans at \(rig.stage.scheduler.geometry.scale)")
        }
    }

    @Test func Runtime_controlJsonChangesAreAppliedLiveAndConfirmedInStatusJson() async throws {
        let rig = try RuntimeRig(control: ["scale": 1, "generation": 0])
        await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
        #expect(try rig.status.appliedGeneration == 0, "the start confirms the generation it loaded")
        #expect(try rig.status.pid == getpid(), "and names itself, so a CLI that restarted the agent can tell this process from the old one")
        let control = try rig.store.url("control.json")
        try JSONSerialization.data(withJSONObject: ["scale": 1, "walk": false, "motion": "off", "generation": 1]).write(to: control, options: .atomic)
        await rig.spin(until: { (try? rig.status.appliedGeneration) == 1 })
        let status = try rig.status
        #expect(status.appliedGeneration == 1); #expect(status.walk == false); #expect(status.motion == "off"); #expect(status.look == "plain")
        #expect(rig.lines("SETTINGS applied generation=1").count == 1); #expect(rig.lines("WALK disabled").count == 1)
        #expect(!rig.stage.settings.walk); #expect(rig.stage.settings.motion == .off)
        try JSONSerialization.data(withJSONObject: ["scale": 2, "generation": 2]).write(to: control, options: .atomic)
        await rig.spin(until: { (try? rig.status.appliedGeneration) == 2 })
        let frame = try #require(rig.stage.lastFrame)
        #expect(frame.canvas.width == 96, "the size setting applies live: a 96 pt canvas")
        #expect(rig.stage.scheduler.geometry.scale == 2, "and the scheduler plans with the new size too (walk ranges, stage fit)")
        #expect(rig.stage.settings.walk, "a write that leaves walk out reads walk as its default")
    }

    @Test func Runtime_aSideOnlyChangeWithNoBubbleRendersNothing() async throws {
        let still: [String: Any] = ["scale": 1, "walk": false, "motion": "off"]
        let rig = try RuntimeRig(control: still.merging(["generation": 0]) { $1 })
        await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
        #expect(rig.stage.lastFrame != nil && rig.stage.lastFrame?.bubble == nil, "Clawd stands on screen with no bubble")
        let control = try rig.store.url("control.json")
        let renders = rig.stage.renderCount, presented = rig.machine.presented
        // Through the live file watcher and the agent's settingsApplied, as `clawd-pet bubble side left` reaches it.
        try JSONSerialization.data(withJSONObject: still.merging(["bubbleSide": "left", "generation": 1]) { $1 }).write(to: control, options: .atomic)
        await rig.spin(until: { (try? rig.status.appliedGeneration) == 1 })
        #expect(try rig.status.appliedGeneration == 1, "the side-only generation is confirmed")
        #expect(rig.stage.settings.bubbleSide == .left)
        #expect(rig.stage.renderCount == renders && rig.machine.presented == presented, "no bubble on screen: the side change draws nothing")
        // The flag does not stick: the next generation, a size change, is drawn.
        try JSONSerialization.data(withJSONObject: ["scale": 2, "walk": false, "motion": "off", "bubbleSide": "left", "generation": 2]).write(to: control, options: .atomic)
        await rig.spin(until: { (try? rig.status.appliedGeneration) == 2 })
        #expect(rig.stage.renderCount > renders, "a size change is drawn")
    }

    @Test func Runtime_aSavedLookAndItsClockSurviveARestartAndAV1StateFileStillLoads() throws {
        let position = SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1)
        let since = Date().timeIntervalSince1970 - 3600
        let rig = try RuntimeRig(state: AgentState(position: position, look: "sunglasses", lookSince: since, recentLooks: ["plain"], lastBubbleStyle: 6))
        #expect(rig.stage.scheduler.look == "sunglasses"); #expect(rig.stage.scheduler.persisted.lookSince == since)
        #expect(rig.stage.scheduler.persisted.lastBubbleStyle == 6)
        let v1 = try RuntimeRig(state: nil)
        let raw = try JSONSerialization.jsonObject(with: ReadOnlyFile.data(try v1.store.url("state.json").path)) as? [String: Any] ?? [:]
        #expect(raw["xFrac"] != nil && raw["feetFrac"] != nil && raw["displayUUID"] != nil, "v1's SavedPosition keys stay in state.json")
        try v1.store.write(Data(#"{"displayUUID":"D","xFrac":0.25,"feetFrac":0.2,"scale":1}"#.utf8), to: "state.json")
        let again = try RuntimeRig(state: nil)
        _ = again
        let loaded = try #require(try? v1.store.readJSON(SavedPosition.self, from: "state.json"))
        #expect(loaded.xFrac == 0.25)
    }

    @Test func Runtime_aLookChangeIsPersistedWithTheTimeAndThePosition() throws {
        let rig = try RuntimeRig()
        let since = Date().timeIntervalSince1970
        // The scheduler reports every committed look change through the same callback the runtime wired to state.json.
        let onPersist = try #require(rig.stage.scheduler.onPersist)
        onPersist(SchedulerPersisted(look: "headphones", lookSince: since, recentLooks: ["plain"], lastBubbleStyle: 10))
        let state = try rig.state
        #expect(state.look == "headphones"); #expect(state.lookSince == since); #expect(state.recentLooks == ["plain"]); #expect(state.lastBubbleStyle == 10)
        #expect(state.position == SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1), "the home is untouched by a look write")
    }

    @Test func Runtime_aquaQuittingEndsTheDictationAndTheControllerKnowsAquaIsGone() throws {
        let rig = try RuntimeRig()
        rig.runtime.controller.receive(line: startLine(SystemPetClock()).trimmingCharacters(in: .newlines))
        #expect(rig.runtime.controller.machine.scene == .listening)
        rig.stage.setQuiet(.aquaNotRunning, active: true)
        #expect(!rig.runtime.controller.aquaRunning, "v1's rule: Aqua gone, nothing is shown and every lease is dropped")
        #expect(rig.runtime.controller.machine.lease == nil); #expect(rig.runtime.controller.machine.scene == .idle)
        #expect(rig.stage.lastFrame == nil)
        rig.stage.setQuiet(.aquaNotRunning, active: false)
        #expect(rig.runtime.controller.aquaRunning); #expect(rig.stage.lastFrame != nil)
    }

    @Test func Runtime_noAquaNoWindowAndTheLaunchOfAquaShowsClawd() throws {
        let rig = try RuntimeRig(aquaRunning: false)
        #expect(rig.stage.lastFrame == nil); #expect(rig.lines("QUIET on reason=aqua-not-running").count == 1)
        #expect(rig.stage.wake.armedTimers == 0)
        rig.stage.setQuiet(.aquaNotRunning, active: false)
        #expect(rig.stage.lastFrame != nil)
    }

    @Test func Runtime_theInputIdleReaderNeedsNoPermissionAndReturnsASaneNumber() {
        let seconds = InputIdle.seconds()
        #expect(seconds != nil && seconds! >= 0 && seconds! < 10 * 365 * 86400, "got \(String(describing: seconds))")
    }

    /// The restored look times are read on the clock the scheduler compares them with: a look worn since "now" on a virtual clock (whose
    /// wall time is not today's date) is next due a whole interval later on that clock, so no look change is overdue at startup.
    @Test func Runtime_restoredLookTimesUseTheRuntimeClock() throws {
        let home = SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1)
        let wall = VirtualClock().wallNow.timeIntervalSince1970
        let rig = try RuntimeRig(state: AgentState(position: home, look: "plain", lookSince: wall), virtual: true)
        let clock = try #require(rig.virtualClock)
        let state = try rig.state
        #expect(state.lookSince == wall, "the look clock is kept, not moved to today's date")
        let due = try #require(state.lookDueAt)
        #expect(due > clock.wallNow.timeIntervalSince1970 + 3600, "next look change due at \(due), virtual now \(clock.wallNow.timeIntervalSince1970)")
        rig.advance(120)
        #expect(rig.stage.scheduler.look == "plain", "no look change in the first two minutes")
    }
}

@Suite("Geometry lines")
struct GeomLogSuite {
    @Test func Geom_aNewShapeIsWrittenAtOnceAndAWalkOnlyFourTimesASecond() {
        var log = GeomLog()
        let a = GeomSample(bubble: nil, stage: CGRect(x: 100, y: 40, width: 48, height: 48), hit: CGRect(x: 104, y: 40, width: 40, height: 30))
        #expect(log.line(sample: a, at: 0) != nil)
        #expect(log.line(sample: a, at: 0.01) == nil, "nothing changed")
        var moving = a
        var written = 0
        for step in 1...60 {          // 60 animation frames, 1/12 s apart, the whole thing moving 2.5 pt per frame
            moving.stage.origin.x += 2.5; moving.hit.origin.x += 2.5
            if log.line(sample: moving, at: Double(step) / 12) != nil { written += 1 }
        }
        #expect(written >= 4 && written <= 22, "5 s of walking wrote \(written) lines")
        var bubbled = moving; bubbled.bubble = CGRect(x: 90, y: 100, width: 60, height: 20)
        #expect(log.line(sample: bubbled, at: 5.01) != nil, "a bubble appearing is written at once")
        var taller = bubbled; taller.stage.size.height += 10
        #expect(log.line(sample: taller, at: 5.02) != nil, "a change of shape is written at once")
        let line = log.line(sample: nil, at: 6) ?? ""
        #expect(line.contains("bubble=none stage=none hit=none"), "hiding is written: \(line)")
        #expect(line.hasSuffix("body=none menu=none menugen=none chat=none chatgen=none"), "and says there is no body and no menu: \(line)")
    }

    @Test func Geom_theBodyTheMenuAndTheNumberOfItsOpeningAreDeclaredAndTheHitIsTheirUnion() {
        var log = GeomLog()
        let body = CGRect(x: 104, y: 40, width: 40, height: 30), menu = CGRect(x: 160, y: 20, width: 236, height: 257)
        let closed = GeomSample(bubble: nil, stage: CGRect(x: 100, y: 40, width: 48, height: 48), hit: body, body: body)
        let line = log.line(sample: closed, at: 0) ?? ""
        #expect(line.contains("hit=104.0,40.0,40.0,30.0 body=104.0,40.0,40.0,30.0 menu=none menugen=none chat=none chatgen=none"), "\(line)")
        var open = closed; open.hit = body.union(menu); open.menu = menu; open.menuGen = 3
        let openLine = log.line(sample: open, at: 0.01) ?? ""
        #expect(openLine.contains("menu=160.0,20.0,236.0,257.0 menugen=3"), "the line that declares a menu is written at once, even 0.01 s after the last: \(openLine)")
        #expect(openLine.contains("hit=104.0,20.0,292.0,257.0"), "hit is the union of the body and the menu: \(openLine)")
    }

    @Test func Geom_aPureMoveIsDroppedOnlyWhenNeitherSideHasAMenu() {
        let body = CGRect(x: 104, y: 40, width: 40, height: 30), menu = CGRect(x: 160, y: 20, width: 236, height: 257)
        func sample(_ dx: Double, menu: CGRect?, gen: Int?) -> GeomSample {
            GeomSample(bubble: nil, stage: CGRect(x: 100 + dx, y: 40, width: 48, height: 48), hit: body.offsetBy(dx: dx, dy: 0), body: body.offsetBy(dx: dx, dy: 0),
                       menu: menu?.offsetBy(dx: dx, dy: 0), menuGen: gen)
        }
        // no menu on either side: dropped (the walk rate limit is unchanged)
        var plain = GeomLog()
        #expect(plain.line(sample: sample(0, menu: nil, gen: nil), at: 0) != nil)
        #expect(plain.line(sample: sample(2, menu: nil, gen: nil), at: 0.1) == nil)
        // a menu on both samples: a pure move 0.1 s after the last line is written
        var held = GeomLog()
        #expect(held.line(sample: sample(0, menu: menu, gen: 1), at: 0) != nil)
        #expect(held.line(sample: sample(2, menu: menu, gen: 1), at: 0.1) != nil, "a move while a menu is declared is never dropped")
        // a menu appearing, and going, are each written at once
        var edges = GeomLog()
        #expect(edges.line(sample: sample(0, menu: nil, gen: nil), at: 0) != nil)
        #expect(edges.line(sample: sample(2, menu: menu, gen: 1), at: 0.05) != nil, "a menu appearing")
        #expect(edges.line(sample: sample(4, menu: nil, gen: nil), at: 0.06) != nil, "a menu going")
        // a sample that differs only in the opening's number is written, and an unchanged one is not
        var gens = GeomLog()
        #expect(gens.line(sample: sample(0, menu: menu, gen: 1), at: 0) != nil)
        #expect(gens.line(sample: sample(0, menu: menu, gen: 1), at: 0.01) == nil)
        #expect(gens.line(sample: sample(0, menu: menu, gen: 2), at: 0.02) != nil, "a reopened menu at the same place is a new declaration")
        let text = gens.line(sample: sample(0, menu: menu, gen: 3), at: 0.03) ?? ""
        #expect(text.contains(" menugen=3 chat=none chatgen=none"))
        var noMenu = GeomLog()
        #expect((noMenu.line(sample: sample(0, menu: nil, gen: nil), at: 0) ?? "").hasSuffix("menu=none menugen=none chat=none chatgen=none"))
    }
}

@Suite("No pointer watch")
struct NoPointerWatchSourceSuite {
    /// Event monitors, tracking areas and taps are what a pointer watch is made of; each one is a wakeup the CPU budget counts. These are
    /// banned in every file under Sources, with no exception (R-NP: the right-click menu needs a mouse-down monitor and hover areas, and only
    /// those, in the places below).
    static let pointerWatchMarkers = ["addLocalMonitorForEvents", "CGEventTap", "acceptsMouseMovedEvents", "mouseMoved", "ignoresMouseEvents = false",
                                      "tapCreate", "cursorUpdate"]
    /// The two files a global mouse-down monitor may be in: the agent's outside-click source and the attended sampler.
    static let monitorFiles = ["Sources/ClawdDesktop/MenuOutsideClicks.swift", "Sources/ClawdAttendedSampler/main.swift"]
    /// The files tracking areas may be in, each with the one option list it may use:
    /// - the menu's view: entered/exited, active always;
    /// - the chat's `/` picker rows (round D, Q10): entered/exited, active always, and in the visible rect because the rows scroll.
    /// Neither may track mouse moves.
    static let trackingFiles: [String: Set<String>] = [
        "Sources/ClawdDesktop/MenuView.swift": [".mouseEnteredAndExited", ".activeAlways"],
        "Sources/ClawdDesktop/ChatPickerView.swift": [".mouseEnteredAndExited", ".activeAlways", ".inVisibleRect"],
    ]
    /// The masks a global monitor in those files may hold: the mouse-downs of the outside-click rule, and (Orca parity P1, P12) the dragged and up
    /// events of the press that is pending and of the file-drag probe. Nothing that moves without a button down (`.mouseMoved`) is ever allowed.
    static let mouseDownMasks: Set<String> = [".leftMouseDown", ".rightMouseDown", ".otherMouseDown", ".leftMouseDragged", ".rightMouseDragged", ".otherMouseDragged",
                                              ".leftMouseUp", ".rightMouseUp", ".otherMouseUp"]

    /// The comma-separated members of the bracketed list that follows each `label` in `text`; nil for a label that is not followed by a literal list.
    static func literalLists(after label: String, in text: String) -> [[String]?] {
        var lists: [[String]?] = []
        var rest = Substring(text)
        while let range = rest.range(of: label) {
            rest = rest[range.upperBound...]
            let trimmed = rest.drop { $0 == " " || $0 == "\n" }
            guard trimmed.first == "[", let close = trimmed.firstIndex(of: "]") else { lists.append(nil); continue }
            let members = trimmed[trimmed.index(after: trimmed.startIndex)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            lists.append(members)
        }
        return lists
    }
    /// The members of the bracketed literal list that `text` starts with (nil: it does not start with one).
    static func leadingList(_ text: Substring) -> [String]? {
        guard text.first == "[", let close = text.firstIndex(of: "]") else { return nil }
        return text[text.index(after: text.startIndex)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    /// The list a `matching:` argument names: the literal list itself, or the one a local `let name: NSEvent.EventTypeMask = [...]` in the same
    /// text holds. nil for anything else (a computed mask is not read, so it is refused).
    static func matchingLists(in text: String) -> [[String]?] {
        var lists: [[String]?] = []
        var rest = Substring(text)
        while let range = rest.range(of: "matching:") {
            rest = rest[range.upperBound...]
            let trimmed = rest.drop { $0 == " " || $0 == "\n" }
            if trimmed.first == "[" { lists.append(leadingList(trimmed)); continue }
            let name = trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !name.isEmpty, let declaration = text.range(of: "let \(name): NSEvent.EventTypeMask =") else { lists.append(nil); continue }
            lists.append(leadingList(text[declaration.upperBound...].drop { $0 == " " || $0 == "\n" }))
        }
        return lists
    }
    /// Every global monitor in `text` listens to mouse-down, dragged and up events and nothing else (and there is at least one `matching:` list to read).
    static func monitorsListenToMouseDownsOnly(_ text: String) -> Bool {
        let lists = matchingLists(in: text)
        return !lists.isEmpty && lists.allSatisfy { list in list.map { !$0.isEmpty && Set($0).isSubset(of: mouseDownMasks) } ?? false }
    }
    /// Every `NSTrackingArea(` call carries a literal option list of exactly the options `allowed` names.
    static func trackingAreasUseTheOnlyOptions(_ text: String, allowed: Set<String>) -> Bool {
        let calls = text.components(separatedBy: "NSTrackingArea(").dropFirst()
        return calls.allSatisfy { call in
            literalLists(after: "options:", in: String(call)).first.flatMap { $0 }.map { Set($0) == allowed && $0.count == allowed.count } ?? false
        }
    }
    static func found(in text: String, path: String) -> [String] {
        var hits = pointerWatchMarkers.filter { text.contains($0) }
        if text.contains("addGlobalMonitorForEvents"), !(monitorFiles.contains { path.hasSuffix($0) } && monitorsListenToMouseDownsOnly(text)) {
            hits.append("addGlobalMonitorForEvents")
        }
        if text.contains("NSTrackingArea") {
            let allowed = trackingFiles.first { path.hasSuffix($0.key) }?.value
            if !(allowed.map { trackingAreasUseTheOnlyOptions(text, allowed: $0) } ?? false) { hits.append("NSTrackingArea") }
        }
        return hits
    }
    static func found(in text: String) -> [String] { found(in: text, path: "Sources/ClawdDesktop/Nowhere.swift") }

    static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test func NoPointer_theAgentWatchesNoPointerAtAll() throws {
        // Click-through is which window exists where (PanelSet), so nothing needs the pointer: no local monitor, no tap, no mouse-moved
        // events, no cursor-update areas, and no source flips a window's ignoresMouseEvents to false after creation. The two exceptions of
        // R-NP are the only ones: a global mouse-down monitor in the outside-click source (and the attended sampler), and entered/exited
        // tracking areas, active in any app, in the menu's view.
        for file in try swiftSources() {
            let text = Self.code(file.text)
            #expect(Self.found(in: text, path: file.path).isEmpty, "\(file.path) watches the pointer: \(Self.found(in: text, path: file.path))")
        }
        // The detector sees what it should (a negative control: the old pointer watcher is flagged).
        let old = "NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { _ in }); panel.acceptsMouseMovedEvents = true"
        let flagged = Self.found(in: old)
        #expect(flagged.contains("addGlobalMonitorForEvents") && flagged.contains("mouseMoved") && flagged.contains("acceptsMouseMovedEvents"))
        negativeControl("pointer-watch-source-is-flagged", expectationHolds: flagged.isEmpty)
    }

    @Test func NoPointer_theTwoExceptionsAreExactlyWhatTheMenuNeeds() {
        let monitor = "NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { _ in })"
        let area = "NSTrackingArea(rect: r, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)"
        let outside = "Sources/ClawdDesktop/MenuOutsideClicks.swift", sampler = "Sources/ClawdAttendedSampler/main.swift", view = "Sources/ClawdDesktop/MenuView.swift"
        // What is allowed passes (the positive controls: the scan is not a blanket ban the exceptions would have to dodge).
        #expect(Self.found(in: monitor, path: outside).isEmpty); #expect(Self.found(in: monitor, path: sampler).isEmpty)
        #expect(Self.found(in: area, path: view).isEmpty)
        // And each way of widening it is flagged (negative controls).
        let mouseMovedMask = "NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .mouseMoved], handler: { _ in })"
        negativeControl("monitor-with-a-mouse-moved-mask-in-an-allowed-file", expectationHolds: Self.found(in: mouseMovedMask, path: outside).isEmpty)
        negativeControl("mouse-down-monitor-in-any-other-file", expectationHolds: Self.found(in: monitor, path: "Sources/ClawdDesktop/AgentRuntime.swift").isEmpty)
        negativeControl("tracking-area-in-any-other-file", expectationHolds: Self.found(in: area, path: "Sources/ClawdDesktop/PetPanel.swift").isEmpty)
        let cursorOption = "NSTrackingArea(rect: r, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate], owner: self, userInfo: nil)"
        negativeControl("tracking-area-with-cursor-update", expectationHolds: Self.found(in: cursorOption, path: view).isEmpty)
        let variable = "NSTrackingArea(rect: r, options: opts, owner: self, userInfo: nil)"
        negativeControl("tracking-area-options-through-a-variable", expectationHolds: Self.found(in: variable, path: view).isEmpty)
        let keyWindow = "NSTrackingArea(rect: r, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)"
        negativeControl("tracking-area-active-in-key-window", expectationHolds: Self.found(in: keyWindow, path: view).isEmpty)
        let moved = "NSTrackingArea(rect: r, options: [.mouseEnteredAndExited, .activeAlways, .mouseMoved], owner: self, userInfo: nil)"
        negativeControl("tracking-area-with-mouse-moved", expectationHolds: Self.found(in: moved, path: view).isEmpty)
        let tap = "let port = CG" + "Event.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: 0, callback: cb, userInfo: nil)"
        negativeControl("event-tap-in-the-monitor-file", expectationHolds: Self.found(in: tap, path: outside).isEmpty)
        negativeControl("local-monitor-in-the-monitor-file", expectationHolds: Self.found(in: "NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { $0 }", path: outside).isEmpty)
    }

    @Test func NoPointer_thePanelClickThroughAndTheModelAreGone() throws {
        let joined = try swiftSources().map(\.text).joined(separator: "\n")
        for gone in ["PanelClickThrough", "ClickThroughModel", "PointerWatcher", "PointerWatching", "watchPointer"] {
            #expect(!joined.contains(gone), "\(gone) is a flag-driven click-through, which Sprint 4c replaced by windows")
        }
    }
}
