import Foundation
import QuartzCore
import ClawdCore
import ClawdRendering
import Darwin

/// The knobs of the headless render mode (`key=value` arguments after the positional ones). Defaults are the production defaults.
public struct HeadlessOptions: Equatable {
    public var motion: MotionLevel = .quiet
    public var walk = true
    /// A fixed seed makes the whole schedule reproducible (spec 6.7); nil seeds from the system.
    public var seed: UInt64?
    /// A quiet condition raised right after the start (B3).
    public var quiet: QuietReason?
    /// Seconds after the start at which the first look change is due (B2 and B4 need one inside their window).
    public var lookDueIn: TimeInterval?
    public init() {}

    /// nil when an argument is not a known `key=value`.
    public static func parse(_ arguments: [String]) -> HeadlessOptions? {
        var options = HeadlessOptions()
        for argument in arguments {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "motion": guard let level = MotionLevel(rawValue: parts[1]) else { return nil }; options.motion = level
            case "walk": guard ["on", "off"].contains(parts[1]) else { return nil }; options.walk = parts[1] == "on"
            case "seed": guard let value = UInt64(parts[1]) else { return nil }; options.seed = value
            case "quiet": guard let reason = QuietReason(rawValue: parts[1]) else { return nil }; options.quiet = reason
            case "look-due": guard let value = Double(parts[1]), value >= 0, value <= 86_400 else { return nil }; options.lookDueIn = value
            default: return nil
            }
        }
        return options
    }
    public var settings: SchedulerSettings {
        var settings = SchedulerSettings(); settings.motion = motion; settings.walk = walk
        return settings
    }
}

/// A fixed fake display for the headless modes: the ultrawide of the done-bar's machine, Clawd at Aqua's default spot.
public enum HeadlessStage {
    public static let display = DisplayInfo(uuid: "headless", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                            visibleFrame: CGRect(x: 0, y: 24, width: 1920, height: 1032), backingScaleFactor: 2)
    public static func geometry(scale: Double = 1) -> PetGeometry {
        let position = Placement.fallbackPosition(display: display.frame, visible: display.visibleFrame)
        let side = PetCatalog.canvasUnits * PetCatalog.pointsPerUnit * scale
        let home = Placement.origin(position: position, display: display.frame, visible: Placement.dragArea(display: display.frame, visible: display.visibleFrame),
                                 size: CGSize(width: side, height: side))
        return PetGeometry(scale: scale, homeOrigin: home, displayFrame: display.frame, visibleFrame: display.visibleFrame)
    }
}

/// The windowless IDLE entry that runs the production stage: the same `StageRuntime` the desktop agent runs (controller,
/// scheduler, stage renderer, one merged timer), with the picture put in a layer that belongs to no window, so nothing is
/// ordered front and the window server's on-screen list is never touched. Each finished picture goes through the layer update
/// the desktop path performs. The scheduler runs at the options' level (the production default unless told otherwise); the
/// SLEEP transition is off (no input idle is read).
public final class IdleRenderRun {
    public static let modeName = "test-idle-render-no-window"
    public static let counterFile = "renders.count"
    public static let timersFile = "timers.armed"
    public static let timersMaxFile = "timers.max"
    public let runtime: StageRuntime
    public var controller: PetController { runtime.controller }
    /// The two layers the desktop path has: the stage window's (everything that takes no click) and the body window's (the pixels that do).
    public let layer = CALayer()
    public let bodyLayer = CALayer()
    public var renderCount: Int { runtime.renderCount }
    public let pixelScale: Double
    private let counter: FileCounter?
    private let timers: (now: FileCounter, max: FileCounter)?

    /// The last picture as the v1 pipeline reported it (the pixels are copied on demand).
    public var lastFrame: PreparedFrame? {
        guard let stage = runtime.lastFrame else { return nil }
        return PreparedFrame(image: stage.image, pixels: Data(stage.pixels.data), size: stage.panelFrame.size, pixelScale: stage.pixelScale)
    }

    /// `scheduler` is the one real timer.
    public init(clock: PetClock, scheduler: PetTimerScheduler, art: URL, control: AgentControl = AgentControl(),
                options: HeadlessOptions = HeadlessOptions(), pixelScale: Double = 2, counter: FileCounter? = nil,
                timers: (now: FileCounter, max: FileCounter)? = nil) throws {
        self.pixelScale = pixelScale; self.counter = counter; self.timers = timers
        let scale = Placement.effectiveScale(control.scale)
        let geometry = HeadlessStage.geometry(scale: scale)
        let random = options.seed.map { SeededRandom(seed: $0) } ?? SeededRandom.fromSystem()
        var persisted: SchedulerPersisted?
        if let due = options.lookDueIn {
            // lookSince such that the first change is due `due` seconds from now.
            persisted = SchedulerPersisted(look: PetCatalog.plainLook,
                                           lookSince: clock.wallNow.timeIntervalSince1970 - Double(options.settings.lookEveryHours) * 3600 + due)
        }
        runtime = try StageRuntime(clock: clock, timer: scheduler, art: art, settings: options.settings, geometry: geometry,
                                   persisted: persisted, random: { random.unit() })
        runtime.hostGeometry = { StageHostGeometry(geometry: geometry, pixelScale: pixelScale) }
        runtime.present = { [unowned self] stage in
            // The cut and the two layer updates of the desktop path: what a shown agent does for each picture.
            guard let pictures = try? PanelPictures(stage) else { return }
            RenderPipeline.apply(pictures.stage, to: self.layer)
            if let body = pictures.body { RenderPipeline.apply(body, to: self.bodyLayer) }
            self.counter?.increment()
        }
        runtime.wake.onArmedChange = { [weak self] count in
            guard let timers = self?.timers else { return }
            timers.now.set(UInt64(count))
            if UInt64(count) > timers.max.value { timers.max.set(UInt64(count)) }
        }
    }
}

/// The `--test-*` entry points. They run before the launchd guard, never create NSApplication,
/// never touch the window server, and exist so that tests and sampled checks can drive the real code headlessly.
public enum HeadlessModes {
    private static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    public static func run(_ args: [String]) -> Int32 {
        switch (args.first ?? "", args.count) {
        case ("--test-entrypoint", 1):
            say("HEADLESS entrypoint"); return 0
        case ("--test-record-goldens", 3):
            do {
                try GoldenEnvironment.record(art: URL(fileURLWithPath: args[1]), destination: URL(fileURLWithPath: args[2]))
                say("Offscreen goldens recorded"); return 0
            } catch { fputs("Offscreen rendering failed: \(error)\n", stderr); return 2 }
        case ("--test-hold", 2...3):
            guard let seconds = Double(args[1]), seconds > 0, seconds <= 3600 else { fputs("bad seconds\n", stderr); return 2 }
            if args.count == 3 {
                guard args[2] == "ignore-term" else { fputs("bad option\n", stderr); return 2 }
                signal(SIGTERM, SIG_IGN)
            }
            say("HOLDING \(getpid())")
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.05) }
            return 0
        case ("--test-chat-quit", 4):
            guard ["child", "none", "hung", "left", "draft"].contains(args[3]) else { fputs("bad option\n", stderr); return 2 }
            return chatQuit(claude: args[1], folder: args[2], mode: args[3])
        case ("--test-chat-tool-line", 2):
            return chatToolLine(secondsText: args[1])
        case ("--test-replay", 2):
            guard let seconds = Double(args[1]), seconds >= 1, seconds <= 600 else { fputs("bad seconds\n", stderr); return 2 }
            replay(seconds: seconds)
            return 0
        case ("--test-idle", 3):
            guard let seconds = Double(args[1]), seconds >= 1, seconds <= 7200 else { fputs("bad seconds\n", stderr); return 2 }
            return idle(seconds: seconds, stateDirectory: URL(fileURLWithPath: args[2]))
        case ("--test-idle-render", 4...16):
            guard let seconds = Double(args[1]), seconds >= 1, seconds <= 7200 else { fputs("bad seconds\n", stderr); return 2 }
            var pixelScale = 2.0
            var rest = Array(args.dropFirst(4))
            if let first = rest.first, !first.contains("=") {
                guard let value = Double(first), value >= 1, value <= 4 else { fputs("bad pixel scale\n", stderr); return 2 }
                pixelScale = value; rest.removeFirst()
            }
            guard let options = HeadlessOptions.parse(rest) else { fputs("bad option\n", stderr); return 2 }
            return idleRender(seconds: seconds, stateDirectory: URL(fileURLWithPath: args[2]), art: URL(fileURLWithPath: args[3]),
                              pixelScale: pixelScale, options: options)
        case ("--test-settings", 4):
            guard let seconds = Double(args[1]), seconds >= 1, seconds <= 600 else { fputs("bad seconds\n", stderr); return 2 }
            return SettingsRun.run(seconds: seconds, stateDirectory: URL(fileURLWithPath: args[2]), art: URL(fileURLWithPath: args[3]))
        default:
            fputs("Unknown headless test mode\n", stderr); return 2
        }
    }

    /// The agent's quit path without the window server: the real bridge, the real SIGTERM handler, no panel. With `withChild` a turn is started
    /// on `claude` and the line `CHATQUIT-READY pid=<agent> child=<pid> token=<token>` says where to look; SIGTERM must then stop the child and
    /// everything it started before this process dies of that signal. Without a child it must die of SIGTERM at once (mode "none"; "hung" also blocks the main queue).
    /// Mode "left" starts a turn like "child" and expects the child to leave on its own: SIGTERM during the sweep that follows must wait for it.
    /// Runs for 60 s at most.
    private static func chatQuit(claude: String, folder: String, mode: String) -> Int32 {
        if mode == "draft" { return chatQuitWithDraft(stateRoot: folder) }
        let withChild = mode == "child" || mode == "left"
        let session = ChatSession(config: ChatSessionConfig(settings: {
            var settings = ChatSettings(home: folder)
            settings.claude = claude; settings.folder = folder; settings.permissions = .bypass
            return settings
        }))
        guard ChatQuit.install(onQuit: { session.quit() }) else { fputs("handler not installed\n", stderr); return 2 }
        var token = "none", child = "none"
        if withChild {
            guard session.send("hello"), let spawned = session.spawnedForTests else { fputs("no child\n", stderr); return 2 }
            token = spawned.token; child = String(spawned.pid)
        }
        say("CHATQUIT-READY pid=\(getpid()) child=\(child) token=\(token)")
        let end = ProcessInfo.processInfo.systemUptime + 60
        // "hung": the main queue never runs again, so only a handler that kills the agent by itself can end it.
        if mode == "hung" { Thread.sleep(forTimeInterval: 60); return 0 }
        while ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        return 0
    }

    /// Mode "draft": no chat child, only a composer draft that is owed a write (its timer never fires, as if SIGTERM came inside the 250 ms). The
    /// store's hold on the quit makes SIGTERM go through `onQuit`, which flushes it, before the agent dies of SIGTERM. `stateRoot` is the state root.
    private static func chatQuitWithDraft(stateRoot: String) -> Int32 {
        final class Never: ChatTimers {
            struct Handle: ChatTimerHandle { func cancel() {} }
            func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) -> ChatTimerHandle { Handle() }
        }
        guard let state = try? OwnState(root: URL(fileURLWithPath: stateRoot)) else { fputs("no state\n", stderr); return 2 }
        let store = ChatComposerStore(state: state, timers: Never(), log: { _ in })
        guard ChatQuit.install(onQuit: { store.flush() }) else { fputs("handler not installed\n", stderr); return 2 }
        store.setDraft("typed just before the quit")
        say("CHATQUIT-READY pid=\(getpid()) child=none token=none")
        let end = ProcessInfo.processInfo.systemUptime + 60
        while ProcessInfo.processInfo.systemUptime < end { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        return 0
    }

    /// Feeds a Bash tool_use and a tool_progress line carrying `secondsText` (JSON number text, verbatim) through the real parser and transcript,
    /// and prints the panel's one-line rendering of the tool as `TOOLLINE <line>`.
    private static func chatToolLine(secondsText: String) -> Int32 {
        let use = #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"sleep 5"}}]},"parent_tool_use_id":null}"#
        let progress = #"{"type":"tool_progress","tool_use_id":"t1","tool_name":"Bash","elapsed_time_seconds":"# + secondsText + #","parent_tool_use_id":null}"#
        var transcript = ChatTranscript()
        for line in [use, progress] { for event in ChatStreamParser.parse(line: line) { transcript.apply(event) } }
        guard let entry = transcript.entries.first(where: { $0.kind == .tool }) else { fputs("no tool entry\n", stderr); return 2 }
        say("TOOLLINE " + ChatPanelRender.toolLine(entry))
        return 0
    }

    /// Tails the log under $HOME (read-only, vnode sources, no polling), runs the real controller on the real
    /// clock, prints each scene change, and exits after `seconds`. Used by the sampled lsof check.
    private static func replay(seconds: Double) {
        let timer = DispatchPetTimer()
        let controller = PetController(clock: SystemPetClock(), scheduler: timer)
        controller.machine.onChange = { say("STATE scene=\($0.rawValue)") }
        timer.onFire = { controller.refresh() }
        let reader = LogTailer(path: AquaInput.logPath) { controller.receive(line: $0) }
        reader.onBoundary = { controller.parser.reset() }
        let watch = LogWatch(reader: reader)
        controller.setAquaRunning(true)
        say("REPLAY-READY pid=\(getpid())")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            withExtendedLifetime(watch) { say("REPLAY-DONE"); exit(0) }
        }
        dispatchMain()
    }

    /// Windowless IDLE for the CPU budget: the real controller, tailer and timer with the SLEEP transition disabled.
    /// It writes status.json and agent.log in `stateDirectory`; clawd-measure-cpu reads them to prove IDLE for the whole window.
    private static func idle(seconds: Double, stateDirectory: URL) -> Int32 {
        do {
            let store = try OwnState(root: stateDirectory)
            var status = AgentStatus(); status.idleBudgetMode = true; status.mode = "test-idle-no-window"
            func log(_ text: String) { try? store.appendAgentLogUnmanaged("\(Date().timeIntervalSince1970) \(text)\n", rotatingAt: nil) }
            try store.writeJSON(status, to: "status.json"); log("STATE scene=idle")
            let timer = DispatchPetTimer()
            let controller = PetController(clock: SystemPetClock(), scheduler: timer)
            controller.machine.sleepEnabled = false
            controller.machine.onChange = { scene in
                status.scene = scene.rawValue; try? store.writeJSON(status, to: "status.json"); log("STATE scene=\(scene.rawValue)")
            }
            controller.onAccepted = { event in log("EVENT key=\(event.key)") }
            timer.onFire = { controller.refresh() }
            let reader = LogTailer(path: AquaInput.logPath) { controller.receive(line: $0) }
            reader.onBoundary = { controller.parser.reset() }
            let watch = LogWatch(reader: reader)
            controller.setAquaRunning(true)
            say("IDLE-READY pid=\(getpid())")
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { withExtendedLifetime(watch) { say("IDLE-DONE"); exit(0) } }
            dispatchMain()
        } catch { fputs("idle mode failed: \(error)\n", stderr); return 2 }
    }

    /// Windowless IDLE with the production stage: the real controller, scheduler, stage renderer, tailer and one merged timer, the SLEEP
    /// transition disabled. It writes status.json (mode `test-idle-render-no-window`) and agent.log in `stateDirectory`, one pwrite per
    /// render into `renders.count` and the armed-timer gauge into `timers.armed` / `timers.max`; clawd-measure-cpu reads those to prove
    /// IDLE, that renders happened inside the measured window, and that at most one timer was ever armed.
    private static func idleRender(seconds: Double, stateDirectory: URL, art: URL, pixelScale: Double, options: HeadlessOptions) -> Int32 {
        do {
            let store = try OwnState(root: stateDirectory)
            var status = AgentStatus(); status.idleBudgetMode = true; status.mode = IdleRenderRun.modeName
            status.walk = options.walk; status.motion = options.motion.rawValue
            func log(_ text: String) { try? store.appendAgentLogUnmanaged("\(Date().timeIntervalSince1970) \(text)\n", rotatingAt: 8 * 1024 * 1024) }
            let counter = try store.counter(IdleRenderRun.counterFile)
            let timers = (now: try store.counter(IdleRenderRun.timersFile), max: try store.counter(IdleRenderRun.timersMaxFile))
            let timer = DispatchPetTimer()
            let run = try IdleRenderRun(clock: SystemPetClock(), scheduler: timer, art: art, options: options, pixelScale: pixelScale,
                                        counter: counter, timers: timers)
            let controller = run.controller, runtime = run.runtime
            runtime.log = log
            controller.machine.onChange = { scene in
                status.scene = scene.rawValue; try? store.writeJSON(status, to: "status.json"); log("STATE scene=\(scene.rawValue)")
                runtime.sceneChanged()
            }
            controller.onAccepted = { event in log("EVENT key=\(event.key)") }
            timer.onFire = { runtime.tick() }
            try store.writeJSON(status, to: "status.json"); log("STATE scene=idle")
            let reader = LogTailer(path: AquaInput.logPath) { controller.receive(line: $0) }
            reader.onBoundary = { controller.parser.reset() }
            let watch = LogWatch(reader: reader)
            runtime.setQuiet(.aquaNotRunning, active: false)
            runtime.start()
            if let reason = options.quiet { runtime.setQuiet(reason, active: true) }
            say("IDLE-READY pid=\(getpid())")
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                withExtendedLifetime((watch, run)) { say("IDLE-DONE renders=\(run.renderCount)"); exit(0) }
            }
            dispatchMain()
        } catch { fputs("idle-render mode failed: \(error)\n", stderr); return 2 }
    }
}
