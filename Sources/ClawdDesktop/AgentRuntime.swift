import AppKit
import QuartzCore
import ClawdCore
import ClawdRendering
import ClawdAudio

public final class AgentRuntime {
    public static let aquaBundleIdentifier = DictationSources.aqua.bundleIdentifier
    /// The v1 scene controller (scenes, blink); the stage runtime owns it.
    public var controller: PetController { stage.controller }
    public let stage: StageRuntime
    private let store: OwnState
    private var control: AgentControl
    /// The `chat*` keys as last applied: a new `claude` child reads them at its spawn.
    private var chatSettings = ChatSettings()
    /// control.json as this process started with it: the restart-only keys (`AgentControl.restartKeyNames`) are compared with it.
    private let bootControl: AgentControl
    /// What the agent takes a missing control.json to mean: the `control` it was built with.
    private let defaultControl: AgentControl
    /// Test seam: called with the generation just before status.json is told the settings are in effect, when everything the settings
    /// change live has already changed.
    public var willConfirm: ((Int) -> Void)?
    private let monitor: FocusMonitor
    private let environment: RuntimeEnvironment
    /// The windows that show the stage: the body window (takes clicks), the stage window (never does) and, later, the menu's.
    public let panels: PanelSet
    public var view: PetView { panels.view }
    private let timer: PetFiringTimer
    private let settingsWatcher: SettingsWatcher
    private let live: LiveSettings
    /// The Aqua log's reader and its file watch; both nil while `aquaReact` is off (nothing reads the log then).
    private var reader: LogTailer?
    private var watch: LogWatch?
    /// Follows Aqua's main process through the kernel (amendment D-1 to D-4); every trigger below only asks it to reconcile.
    private var follower: AquaFollower!
    private var aquaDiagUntil: Double = 0
    /// The mode the Aqua setting resolved to when this process started (ignore whenever React is off).
    private var aquaModeAtStart = AquaMode.ignore
    private var applicationList: AnyObject?
    private var position: SavedPosition
    /// The position as last saved (the start, then each mouse-up): a drag in progress is not saved.
    private var committedPosition: SavedPosition
    private var persistedLook: SchedulerPersisted
    public var currentPosition: SavedPosition { position }
    /// Reconciles of Aqua's liveness run so far (a test reads it to prove a stale exit callback reconciles nothing).
    public var aquaReconcileCount: Int { follower.reconcileCount }
    /// Whether this process reads Aqua's log at all (a tailer or a watch exists): never with `aquaReact` off.
    public var aquaLogIsRead: Bool { reader != nil || watch != nil }
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var keepAlive: [AnyObject] = []
    private var mouseOffset = CGPoint.zero
    private var downPoint = CGPoint.zero
    private var dragging = false
    /// A press that began on Clawd and has not been released: the body window must not go away while it lasts.
    private var pressed = false
    /// The opening a left press began under (the live menu's number at its mouse-down; nil when no menu was open) and the time stamp of that
    /// mouse-down: a press that ends without a drag closes that opening, and only that one (amendment R-BODY).
    private var pressMenuGen: Int?
    private var pressDownEt: TimeInterval = 0
    /// The pet is on screen: set when a picture is shown after nothing was, cleared when the windows go.
    private var onScreen = false
    private var geom = GeomLog()
    /// The right-click menu (Sprint M): its rules and, through its writer, the one thing it runs (the installed CLI).
    private var menu: MenuController!
    /// The one writer of the right-click menu and the menu bar icon (and, later, the Settings window): one CLI child at a time, the newest
    /// pick of each queue key wins.
    private var menuWriter: MenuWriter!
    /// The menu bar icon; nil only while the runtime is being built.
    private var statusMenu: StatusMenuController?
    /// The Settings window's rules; closed, it holds no window, view, observer or timer.
    private var settings: SettingsController!
    private var menuLayoutCache: [MenuChatRow: MenuLayout] = [:]
    private var menuThumbnailCache: [String: Raster]?
    /// The chat panel's rules and the bridge to Claude Code (Clawd v3); inert when the environment supplies no chat.
    private var chat: ChatController!
    /// The press of the current click series began under an open menu (R-BODY): that series never toggles the chat.
    private var seriesClosedMenu = false

    public init(store: OwnState, monitor: FocusMonitor, art: URL, control: AgentControl,
                environment: RuntimeEnvironment, settingsRequest: SettingsRequestVerdict = .none) throws {
        self.store = store; self.monitor = monitor; self.environment = environment
        timer = environment.timer()

        // The settings: control.json as the one component that reads it sees it (the `control` argument is what a missing file means).
        let watcher = SettingsWatcher(store: store, defaults: AppliedSettings(control: control))
        let initial = watcher.load()
        settingsWatcher = watcher
        defaultControl = control
        self.control = initial.control; bootControl = initial.control; chatSettings = Self.searching(initial.chat, in: environment.claudeSearch)

        // The saved position (v1) and look state.
        let saved = try? store.readJSON(AgentState.self, from: "state.json")
        var start = saved?.position ?? SavedPosition()
        if !FileManager.default.fileExists(atPath: try store.url("state.json").path) {
            start = Self.initialPosition(displays: environment.displays())
            try store.writeJSON(AgentState(position: start), to: "state.json")
        }
        position = start; committedPosition = start
        let catalog = PetCatalog(atlasData: try ReadOnlyFile.data(art.appendingPathComponent("clawd-atlas.json").path))
        let hours = initial.effectiveScheduler(helmetOffPending: false).lookEveryHours
        // One clock for the restored look times and the scheduler that compares against them (the environment's; the system clock in production).
        let clock = environment.clock()
        let look = (saved ?? AgentState(position: start)).persisted(catalog: catalog, nowEpoch: clock.wallNow.timeIntervalSince1970,
                                                                    lookEveryHours: hours, draw: { Double.random(in: 0..<1) })
        persistedLook = look
        // `helmet off` that was applied but not yet carried out when the last process ended: the switch to plain is still owed, unless the
        // helmet is on again or Clawd already wears plain.
        let helmetOffOwed = saved?.helmetOffPending == true && !initial.control.helmet && look.look != PetCatalog.plainLook

        panels = PanelSet(overFullScreen: initial.control.overFullScreen)
        let first = Self.hostGeometry(environment: environment, position: start, control: initial.control)
        stage = try StageRuntime(clock: clock, timer: timer, art: art, settings: initial.effectiveScheduler(helmetOffPending: helmetOffOwed),
                                 geometry: first?.geometry ?? PetGeometry(scale: 1, homeOrigin: .zero, displayFrame: .zero, visibleFrame: .zero),
                                 persisted: look)
        live = LiveSettings(runtime: stage, initial: initial, helmetOffPending: helmetOffOwed)
        // What loading changed (a factor drawn for a file of an older build, a bag settled against this catalog) is written at once.
        persistedLook = stage.scheduler.persisted
        // The Aqua diagnostics window opens at the first start of a build that has it and is written once (amendment D-5).
        aquaDiagUntil = saved?.aquaDiagUntil ?? environment.wallClock().timeIntervalSince1970 + AquaDiag.window
        let wanted = AgentState(position: start, persisted: persistedLook, helmetOffPending: live.helmetOffPending, aquaDiagUntil: aquaDiagUntil)
        if saved?.aquaDiagUntil == nil || (saved != nil && saved != wanted) { saveState() }
        let controller = stage.controller

        // The right-click menu. Everything it needs from the machine comes through the environment, so a test supplies its own.
        menuWriter = MenuWriter(home: environment.home(), log: { [weak self] in self?.monitor.log($0) },
                                restartPending: { [weak self] in self?.restartPending() ?? false })
        menu = MenuController(host: self, clock: stage.clock, timer: environment.menuTimer(), source: environment.menuOutsideClicks(),
                              writer: menuWriter, log: { [weak self] in self?.monitor.log($0) })
        // The terminal path keeps its tokens and its child in chat-state.json through the agent's own store.
        var chatEnvironment = environment
        if chatEnvironment.chatTerm?.state == nil { chatEnvironment.chatTerm?.state = ChatTermState(store: store) }
        if chatEnvironment.chatGeometry == nil { chatEnvironment.chatGeometry = FileChatGeometry(store: store) }
        // The drop copies and the pasted images live under the agent's own state directory.
        if chatEnvironment.chatWeb?.attach.state == nil { chatEnvironment.chatWeb?.attach.state = store }
        chat = ChatController(host: self, environment: chatEnvironment, enabled: { [weak self] in self?.control.chat ?? false },
                              settings: { [weak self] in self?.chatSettings ?? ChatSettings() }, presses: panels.presses,
                              log: { [weak self] in self?.monitor.log($0) })
        chat.sweepStorage()
        settings = SettingsController(host: self, environment: environment, claimed: { [weak self] in self?.monitor.activationClaimed ?? false },
                                      log: { [weak self] in self?.monitor.log($0) })
        statusMenu = StatusMenuController(factory: environment.statusBar, state: { [weak self] in self?.statusMenuState() ?? StatusMenuState() },
                                          image: { [weak self] in self?.statusMenuImage() }, pick: { [weak self] in self?.statusPick($0) },
                                          log: { [weak self] in self?.monitor.log($0) },
                                          event: { environment.chatCurrentEvent() }, now: { [weak self] in self?.stage.clock.now ?? 0 },
                                          fields: { [weak self] in self?.traceFields() ?? StatusTraceFields(settings: "closed", chat: "closed", active: false) })
        monitor.statusTrace = { [weak self] note, window in self?.statusMenu?.trace(note, window: window) }
        // Settings is asked first, then the chat (design 4.5, H1); the chat's activation verdict is its two halves.
        monitor.settingsKeyExemption = { [weak self] window in self?.settings.keyVerdict(for: window) }
        monitor.settingsActivationClaim = { [weak self] in self?.settings.activationClaim() ?? false }
        monitor.settingsActivationClaimedElsewhere = { [weak self] in self?.settings.activationClaimedElsewhere() }
        monitor.settingsActivationUnclaimed = { [weak self] in self?.settings.activationUnclaimed() }
        monitor.keyExemption = { [weak self] window in self?.chat.keyVerdict(for: window) }
        monitor.keyResigned = { [weak self] window in self?.chat.resigned(window) }
        monitor.chatActivationClaim = { [weak self] in self?.chat.activationClaim() ?? false }
        monitor.chatActivationClaimedElsewhere = { [weak self] in self?.chat.activationClaimedElsewhere() }
        monitor.chatUnclaimedActivation = { [weak self] in self?.chat.closeUnclaimedActivation() ?? .violation }
        monitor.appWillBecomeActive = { [weak self] in self?.chat.appWillBecomeActive(); self?.settings.appWillBecomeActive() }
        monitor.appResigned = { [weak self] in self?.chat.appResigned(); self?.settings.appResigned() }
        chat.lateViolation = { [weak self] in self?.monitor.record(NSWindow.didBecomeKeyNotification, answeredByClose: true) }
        chat.claimedActivation = { [weak self] in self?.monitor.activationClaimed ?? false }
        chat.activationStepRunning = { [weak self] in self?.monitor.activationStepRunning ?? false }
        chat.willBeginActivation = { [weak self] in self?.settings.cancelHandBack() }
        settings.lateViolation = { [weak self] in self?.monitor.record(NSWindow.didBecomeKeyNotification) }
        settings.activationStepRunning = { [weak self] in self?.monitor.activationStepRunning ?? false }
        panels.menuFactory = { [weak self] gen in self?.makeMenuView(gen: gen) ?? MenuView(layout: MenuLayout(looks: [], drawnStyles: []), gen: gen) }

        // Source B stays off unless control.json asks for it AND the probe report passed; then, and only then, CoreAudio is touched.
        let report = try? store.readJSON(ProbeReport.self, from: "probe/probe-release.json")
        controller.sourceBEnabled = SourceBPolicy.enabled(control: initial.control, report: report)
        if controller.sourceBEnabled { controller.device = SelectedDeviceListener() }
        controller.selectedUID = { AquaInput.selectedUID(keyPath: initial.control.selectedInputKeyPath) }
        monitor.status.sourceBEnabled = controller.sourceBEnabled
        monitor.status.idleBudgetMode = initial.control.idleBudgetMode
        stage.scheduler.inputIdle = initial.control.idleBudgetMode ? { nil } : environment.inputIdle
        // The pointer, read by the scheduler itself on the ticks of a walk and before an idle motion is committed (spec 9b item 16): one
        // call of NSEvent.mouseLocation, no monitor, no tracking area, no timer.
        stage.scheduler.pointerSource = { environment.pointer() }

        controller.machine.onChange = { [weak self] scene in
            guard let self else { return }
            self.monitor.status.scene = scene.rawValue
            self.monitor.log("STATE scene=\(scene.rawValue)")
            self.monitor.persist()
            // A dictation outranks the menu: it closes first, in the batch that starts the scene, so one picture shows both changes.
            self.stage.perform {
                if self.controller.machine.baseScene != .idle { self.menu.closeForDictation() }
                self.stage.sceneChanged()
            }
        }
        controller.onAccepted = { [weak self] event in
            guard let self else { return }
            self.monitor.status.lastEvent = event.timestamp; self.monitor.persist()
            self.monitor.log("EVENT key=\(event.key) lease=\(event.lease.map(String.init) ?? "none")")
        }
        stage.log = { [weak self] text in self?.monitor.log(text) }
        stage.persist = { [weak self] persisted in self?.persistLook(persisted) }
        stage.onEvent = { [weak self] event in self?.schedulerEvent(event) }
        stage.onUpdate = { [weak self] in self?.updateSchedulerStatus() }
        // A LockDown Browser application running now (or a stand-down an earlier process left owed) means no window at all: this is decided before
        // `present` is wired, so nothing can be shown, and the first picture the start draws finds the quiet reason already raised.
        stage.scheduler.examBrowserRunning = { [environment] in environment.examBrowserRunning() }
        if stage.examStartup(running: environment.examBrowserRunning()) {
            monitor.log("EXAM startup standing-down")
            stage.setQuiet(.examBrowser, active: true)
        }
        // The icon is made after the exam check: a stand-down in force means no item at all.
        if !stage.scheduler.examActive { statusMenu?.build() }
        stage.hostGeometry = { [weak self] in self?.currentHostGeometry() }
        stage.present = { [weak self] frame in self?.show(frame) }
        stage.dismiss = { [weak self] in self?.hide() }
        timer.onFire = { [weak self] in self?.stage.tick() }
        view.input = { [weak self] kind, event in self?.input(kind, event) }
        view.ignored = { [weak self] kind, event, why in
            guard let self else { return }
            self.monitor.log("MOUSE-IGNORED kind=\(kind) \(InputProvenance.fields(of: event)) why=\(why)\(Self.downStamp(kind, event))")
            self.ignoredDown(kind, event)
        }
        view.menuRequest = { [weak self] event, how in self?.menuRequested(event, how: how) ?? false }
        view.opaqueBody = { [weak self] point in self?.isOpaque(point) ?? false }
        view.repeatedClick = { [weak self] event in self?.repeatedClick(event) }
        view.dropRefusal = { [weak self] in self?.chat.petDropRefusal() }
        view.fileDragEntered = { [weak self] in self?.chat.fileDragEntered() }
        view.dropRefused = { [weak self] reason in self?.monitor.log("CHAT pet-drop refused reason=\(reason)") }
        view.fileDrop = { [weak self] paths, promise, time in
            guard let self else { return }
            self.stage.perform {
                self.chat.petDrop(paths: paths, carriedPromise: promise, eventTime: time)
                self.stage.renderNow()
            }
        }
        live.log = { [weak self] text in self?.monitor.log(text) }
        live.helmetOffPendingChanged = { [weak self] in self?.saveState() }
        live.didApply = { [weak self] generation, settings, effective in self?.settingsApplied(generation, settings, effective) }

        // Resolved once. In ignore mode the follower is told, by a table that always answers "running", that Aqua runs: it never raises
        // `aquaNotRunning`, and its logic is the same as in follow mode.
        // With `aquaReact` off Clawd reads no log and follows nothing: the mode is ignore whatever `aqua` says, and nothing is written.
        let reacting = initial.control.aquaReact
        let installed = environment.aquaInstalled()
        let aquaMode = reacting ? AquaMode.resolve(initial.control.aqua, installed: installed) : AquaMode.ignore
        monitor.status.aquaMode = aquaMode.rawValue
        aquaModeAtStart = aquaMode
        monitor.log("AQUA mode=\(aquaMode.rawValue) setting=\(initial.control.aqua.rawValue) installed=\(installed ? "yes" : "no")" + (reacting ? "" : " react=off"))
        let ignoringAqua = aquaMode == .ignore
        follower = AquaFollower(
            table: ignoringAqua ? AnswerAquaTable(running: { true }) : environment.aquaTable ?? AnswerAquaTable(running: environment.aquaRunning),
            registry: ignoringAqua ? SilentExitRegistry() : environment.aquaExitRegistry ?? SilentExitRegistry(),
            agrees: { [weak self] notRunning in
                guard let self else { return true }
                return self.stage.scheduler.quietReasons.contains(.aquaNotRunning) == notRunning && self.controller.aquaRunning == !notRunning
            },
            apply: { [weak self] notRunning in self?.stage.setQuiet(.aquaNotRunning, active: notRunning) },
            log: { [weak self] text in self?.monitor.log(text) },
            diag: ignoringAqua ? nil : AquaDiag(store: store, until: Date(timeIntervalSince1970: aquaDiagUntil), now: environment.wallClock),
            snapshot: { [weak self] in
                guard let self else { return AquaPetSnapshot(quiet: "none", controllerAqua: false, window: false) }
                let reasons = self.stage.scheduler.quietReasons.map(\.rawValue).sorted().joined(separator: ",")
                return AquaPetSnapshot(quiet: reasons.isEmpty ? "none" : reasons, controllerAqua: self.controller.aquaRunning, window: self.onScreen)
            },
            setRetry: { [weak self] armed in self?.stage.setAquaRetry(armed) })
        stage.onAquaRetry = { [weak self] in self?.follower.reconcile(.retry) }
        controller.onParsed = { [weak self] event in
            // Aqua's own lifecycle lines are triggers that do not depend on LaunchServices: the log is watched by kernel file events.
            if event.kind == .bootstrap { self?.follower.reconcile(.bootstrap) } else if event.kind == .shutdown { self?.follower.reconcile(.shutdown) }
        }
        if reacting {
            let tailer = LogTailer(path: environment.aquaLogPath()) { [weak self] line in self?.stage.controller.receive(line: line) }
            tailer.onBoundary = { [weak self] in
                self?.stage.controller.parser.reset()
                self?.follower.reconcile(.logfile)
            }
            tailer.onDiagnostic = { [weak self] key in self?.monitor.log("TAIL \(key)") }
            reader = tailer
            watch = LogWatch(reader: tailer)
        }
        observeWorkspace()
        applicationList = environment.observeApplicationList { [weak self] in self?.follower.reconcile(.kvo) }
        // An unlock reconciles before it lifts its own quiet reason, so Aqua's liveness is read before the window may come back.
        let unlockSink = AquaReconcilingSink(stage: stage) { [weak self] in self?.follower.reconcile(.unlock) }
        keepAlive.append(unlockSink)
        if let observers = environment.observeDesktop(unlockSink, panels.stage) { keepAlive.append(observers) }
        monitor.status.scene = "idle"; monitor.log("STATE scene=idle"); monitor.persist()
        follower.recordObservers(logWatch: watch?.isArmed ?? false)
        follower.reconcile(.startup)
        stage.start()
        settingsWatcher.start(sink: live)
        actOnSettingsRequest(settingsRequest)
    }
    deinit { timer.cancel(); settingsWatcher.stop(); tokens.forEach { $0.0.removeObserver($0.1) } }

    // MARK: placement

    /// Only when no position was ever saved (a fresh install). Without a display point from Aqua the pet starts on the primary display;
    /// until 2026-10-21 it started on the screen that had keyboard focus, which at a launchd start is whatever happened to be in front.
    private static func initialPosition(displays: DisplaySet) -> SavedPosition {
        guard let display = displays.all.first else { return SavedPosition() }
        guard let initial = AquaInput.initialPosition() else {
            var fallback = Placement.fallbackPosition(display: display.frame, visible: display.visibleFrame)
            fallback.displayUUID = display.uuid
            return fallback
        }
        // Aqua stores display coordinates with the top-left desktop convention.
        let primaryHeight = displays.all.first?.frame.height ?? display.frame.height
        let inherited = initial.displayPoint.flatMap { point in
            displays.all.first { $0.frame.contains(CGPoint(x: point.x, y: primaryHeight - point.y)) }
        } ?? display
        return SavedPosition(displayUUID: inherited.uuid, xFrac: initial.x, feetFrac: initial.feet)
    }
    /// The saved display when it is attached, else the primary one (DisplaySet); nil while no display is attached (all asleep or
    /// unplugged): the panel is hidden instead of crashing. The saved UUID is kept, so the pet goes back when its display returns.
    private static func display(environment: RuntimeEnvironment, position: SavedPosition) -> DisplayInfo? {
        let displays = environment.displays()
        guard let fallback = displays.all.first else { return nil }
        return Placement.resolveDisplay(saved: position.displayUUID, displays: displays.all.map { ($0.uuid, $0) }, fallback: fallback)
    }
    private static func hostGeometry(environment: RuntimeEnvironment, position: SavedPosition, control: AgentControl) -> StageHostGeometry? {
        guard let display = display(environment: environment, position: position) else { return nil }
        let scale = Placement.effectiveScale(control.scale)
        let side = PetCatalog.canvasUnits * PetCatalog.pointsPerUnit * scale
        let home = Placement.origin(position: position, display: display.frame, visible: Placement.dragArea(display: display.frame, visible: display.visibleFrame),
                                 size: CGSize(width: side, height: side))
        return StageHostGeometry(geometry: PetGeometry(scale: scale, homeOrigin: home, displayFrame: display.frame, visibleFrame: display.visibleFrame),
                                 pixelScale: display.backingScaleFactor)
    }
    private func currentHostGeometry() -> StageHostGeometry? { Self.hostGeometry(environment: environment, position: position, control: control) }
    private var display: DisplayInfo? { Self.display(environment: environment, position: position) }
    private var backing: Double { display?.backingScaleFactor ?? 1 }
    private var scale: Double { Placement.effectiveScale(control.scale) }
    private var bodySize: CGSize {
        let side = PetCatalog.canvasUnits * PetCatalog.pointsPerUnit * scale
        return CGSize(width: side, height: side)
    }

    // MARK: observers

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
        tokens.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: handler)))
    }
    private func observeWorkspace() {
        let center = environment.workspaceCenter()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observe(center, name) { [weak self] note in
                guard let self else { return }
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let launched = name == NSWorkspace.didLaunchApplicationNotification
                notified(launched: launched, bundleIdentifier: app?.bundleIdentifier, name: app?.localizedName,
                         pid: app?.processIdentifier, payload: app != nil)
            }
        }
        observe(center, NSWorkspace.willSleepNotification) { [weak self] _ in self?.stage.setQuiet(.systemAsleep, active: true) }
        observe(center, NSWorkspace.didWakeNotification) { [weak self] _ in
            guard let self else { return }
            self.monitor.context = "wake"; self.monitor.status.wakeCount += 1; self.monitor.persist()
            self.reader?.poll(); self.follower.reconcile(.wake); self.stage.setQuiet(.systemAsleep, active: false)
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            guard let self else { return }
            self.monitor.context = "display"; self.monitor.status.displayChangeCount += 1; self.monitor.persist()
            self.syncGeometry()
            self.stage.controller.refresh()
        }
    }

    /// An application launched or quit (the NSWorkspace notification, delivered on the main queue).
    public func workspaceApplication(launched: Bool, bundleIdentifier: String?, name: String?, pid: Int32) {
        notified(launched: launched, bundleIdentifier: bundleIdentifier, name: name, pid: pid, payload: true)
    }

    /// Any application's launch or quit asks the Aqua follower to reconcile with the kernel (it sets nothing from the notification's own
    /// content, which can be missing or late); a LockDown Browser application's launch stands Clawd down in this very turn, its quit asks the
    /// running applications again.
    private func notified(launched: Bool, bundleIdentifier: String?, name: String?, pid: Int32?, payload: Bool) {
        follower.reconcile(launched ? .launch : .terminate,
                           source: "bundle=\(AquaDiag.field(bundleIdentifier)) name=\(AquaDiag.field(name)) pid=\(pid.map(String.init) ?? "nil") " +
                                   "payload=\(payload ? "present" : "missing")")
        guard ExamBrowserRule.matches(bundleIdentifier: bundleIdentifier, name: name) else { return }
        let pid = pid ?? 0
        if launched {
            let phase = stage.scheduler.examActive ? "again" : "first"
            monitor.log("EXAM seen pid=\(pid) id=\(bundleIdentifier ?? "none") \(phase)")
            stage.examApplicationLaunched()
        } else {
            monitor.log("EXAM quit pid=\(pid) id=\(bundleIdentifier ?? "none")")
            stage.examApplicationTerminated()
        }
    }

    // MARK: settings

    /// The live part of a generation has been applied (LiveSettings.apply ran the scheduler's settings first); this applies the size, draws
    /// the result and only then tells status.json. A key that only a restart applies is not in effect, so it is reported as
    /// `restartRequired` and the generation is not confirmed.
    /// The chat's settings with the places Q6's search looks in: the environment's (production: the constant list; a rig: its own folders).
    private static func searching(_ chat: ChatSettings, in folders: [String]) -> ChatSettings {
        var made = chat
        made.claudeSearch = folders
        return made
    }

    private func settingsApplied(_ generation: Int, _ settings: AppliedSettings, _ effective: SchedulerSettings) {
        control = settings.control
        chatSettings = Self.searching(settings.chat, in: environment.claudeSearch)
        syncGeometry()
        stage.renderAfterSettings()
        willConfirm?(generation)
        let pending = settings.control.restartKeys(since: bootControl)
        monitor.status.settingsApplied(generation: generation, restartKeys: pending)
        monitor.status.walk = effective.walk; monitor.status.motion = effective.motion.rawValue; monitor.status.bubble = effective.bubble
        monitor.status.look = stage.scheduler.look
        monitor.persist()
        if !pending.isEmpty { monitor.log("SETTINGS restart-required generation=\(generation) keys=\(pending.joined(separator: ","))") }
        menu.settingsApplied()
        chat.settingsApplied()
        // A key that only a restart applies: the CLI restarts the agent next, so the window closes (picker first) before the process ends.
        self.settings.restartApplied(keys: pending)
        statusMenu?.batchEnded(standDown: stage.scheduler.examActive)
    }

    /// The request read at boot, acted on at the end of `init`, after the exam check. A stand-down drops it; a `frontdoor` request is dropped in
    /// this stage (nothing writes one before S1); a passing `settings-restart` request opens Settings at its section without key and arms no cause.
    private func actOnSettingsRequest(_ verdict: SettingsRequestVerdict) {
        switch verdict {
        case .none: return
        case .dropped(let reason): monitor.log("SETTINGS request dropped reason=\(reason)")
        case .pass(let origin, let section):
            if settingsExamBlocked() {
                monitor.log("SETTINGS request dropped reason=exam")
            } else if origin != SettingsRequest.originSettingsRestart {
                monitor.log("SETTINGS request dropped reason=origin")
            } else {
                monitor.log("SETTINGS request kept")
                settings.begin(cause: .request, section: section.flatMap(SettingsSection.init(rawValue:)) ?? .general)
            }
        }
    }

    /// Re-reads where Clawd lives after a display change or an applied setting. An open menu was placed beside the old geometry and Clawd is
    /// about to move (the walk it froze ends at home): it closes first, with reason geometry, before anything is drawn in the new geometry
    /// (amendment R-GEOM). A change that leaves the geometry as it was closes nothing. `loseGesture()` calls `stage.syncGeometry()` itself:
    /// a drag has already closed the menu.
    private func syncGeometry() {
        if menu.isOpen, stage.geometryWillChange() { menu.close(.geometry) }
        stage.syncGeometry()
        chat.replace()
        settings.displayChanged()
    }

    private func schedulerEvent(_ event: SchedulerEvent) {
        live.schedulerEvent(event)
        if case .lookChange(_, let to) = event { monitor.status.look = to; monitor.persist() }
    }

    private func updateSchedulerStatus() {
        // The end of every scheduler batch is where an exam stand-down stops the chat, whichever path raised it (spec section 6).
        chat?.batchEnded()
        // Settings closes where the chat stops for a stand-down; otherwise its state line follows the scheduler (no timer: a hide's end is a deadline).
        settings?.batchEnded(standDown: stage.scheduler.examActive)
        statusMenu?.batchEnded(standDown: stage.scheduler.examActive)
        let quiet = stage.scheduler.quietReason?.rawValue ?? "none"
        let due = stage.scheduler.nextLookChange?.timeIntervalSince1970
        guard monitor.status.quiet != quiet || monitor.status.nextLookChange != due else { return }
        monitor.status.quiet = quiet
        monitor.status.nextLookChange = due
        monitor.persist()
    }

    private func persistLook(_ persisted: SchedulerPersisted) {
        persistedLook = persisted
        saveState()
    }
    private func saveState() {
        try? store.writeJSON(AgentState(position: committedPosition, persisted: persistedLook, helmetOffPending: live.helmetOffPending, aquaDiagUntil: aquaDiagUntil), to: "state.json")
    }

    // MARK: mouse

    private func isOpaque(_ point: CGPoint) -> Bool {
        guard let frame = stage.lastFrame else { return false }
        return frame.hit.containsBody(CGPoint(x: panels.body.frame.minX + point.x, y: panels.body.frame.minY + point.y))
    }
    /// The second and third click of a quick series: each one is a click for the scheduler (three within 2 s make Clawd dizzy).
    private func repeatedClick(_ event: NSEvent) {
        monitor.context = "click"
        monitor.log("INPUT kind=mouseDown \(InputProvenance.fields(of: event))\(Self.downStamp("mouseDown", event))")
        // A mouse-down on Clawd while the menu is open is a click outside it: it closes the menu and is not a touch (amendment R-BODY).
        stage.perform {
            if menu.isOpen { menu.close(.toggle, et: event.timestamp) }
            else {
                stage.scheduler.click()
                // The second click of a series toggles the chat; a third or later never does, and neither does a series whose first press
                // closed the menu. It stays a scheduler click as above.
                if event.clickCount == 2, !seriesClosedMenu { chat.toggle(eventTime: event.timestamp) }
            }
            stage.renderNow()
        }
    }
    private func input(_ kind: String, _ event: NSEvent) {
        monitor.context = kind == "mouseDragged" ? "drag" : "click"
        monitor.log("INPUT kind=\(kind) \(InputProvenance.fields(of: event))\(Self.downStamp(kind, event))")
        let point = environment.pointer()
        switch kind {
        case "mouseDown":
            let canvas = stage.lastFrame?.canvas.origin ?? panels.stage.frame.origin
            mouseOffset = CGPoint(x: point.x - canvas.x, y: point.y - canvas.y)
            downPoint = point; pressed = true; controller.mouseDown()
            seriesClosedMenu = false
            pressMenuGen = menu.liveGeneration; pressDownEt = event.timestamp
        case "mouseDragged":
            guard hypot(point.x - downPoint.x, point.y - downPoint.y) >= 3 else { return }
            guard let destination = environment.displays().all.first(where: { $0.frame.contains(point) }) ?? display else { return }
            let origin = Placement.clamp(CGPoint(x: point.x - mouseOffset.x, y: point.y - mouseOffset.y),
                                         visible: Placement.dragArea(display: destination.frame, visible: destination.visibleFrame), size: bodySize)
            stage.perform {
                if !dragging { dragging = true; menu.closeForDrag(); chat.closeForDrag(); pressMenuGen = nil; stage.scheduler.dragStarted() }
                stage.dragOrigin = origin
                position = Placement.fractions(origin: origin, size: bodySize, display: destination.frame,
                                               uuid: destination.uuid, scale: control.scale)
                controller.mouseDragged()
                stage.renderNow()
            }
        case "mouseUp":
            let wasDragging = dragging
            let dropped = stage.dragOrigin
            let owner = pressMenuGen, downEt = pressDownEt
            seriesClosedMenu = owner != nil
            pressMenuGen = nil
            committedPosition = position
            pressed = false
            saveState()
            stage.perform {
                dragging = false; stage.dragOrigin = nil
                controller.mouseUp()
                if wasDragging { stage.scheduler.dragEnded(newHome: dropped) }
                // A press that began under an open menu ends that opening, if it is still the live one, and is never a touch (R-BODY 3a).
                else if let owner { menu.closeIfLive(gen: owner, .toggle, et: downEt) }
                else { stage.scheduler.click() }
                stage.renderNow()
            }
            // A drop on another display moves where Clawd lives: the scheduler (its walk bounds, and the menu, which is placed inside its
            // visible frame) must read the new display now, not at the next display change or setting (the user, 2026-10-21: the menu opened on
            // the display Clawd had been dragged from).
            if wasDragging { stage.syncGeometry() }
        default: break
        }
    }

    // MARK: drawing

    private func show(_ frame: StageFrame) {
        guard let pictures = try? PanelPictures(frame) else {
            monitor.log("RENDER failed")
            hide()
            return
        }
        panels.show(pictures, holdBody: pressed, environment: environment)
        chat.replace()
        logGeometry(frame)
        if !onScreen { onScreen = true; confirmSpace() }
    }
    private func hide() {
        menu.closeForHidden()
        // An exam stand-down is a quiet reason too, but its close is named for what it is.
        if stage.scheduler.examActive { chat.close(.exam) } else { chat.closeForHidden() }
        loseGesture()
        panels.hide(environment: environment)
        onScreen = false
        logGeometry(nil)
        // The controller's own drag ends the way a button-up ends it (no new home is saved), and last: left set, its scene stays DRAG for good, a
        // scene that is not idle arms no blink, and nothing wakes the pet again to look at a pointer that has left. Ending it renders once more;
        // that render must find the windows already gone.
        if controller.machine.dragging { controller.mouseUp() }
    }

    /// Every window goes, and with the body window a press in progress: its button-up can never arrive. A drag that was going on ends
    /// here, without a landing, with Clawd back at the home it had before the press: the release is what saves a new home and plays the
    /// landing, and a gesture that never finished decided nothing (state.json still holds the old home; a restart would show the same).
    private func loseGesture() {
        if pressed { view.cancelPress() }
        pressed = false
        pressMenuGen = nil
        guard dragging else { return }
        dragging = false
        stage.dragOrigin = nil
        position = committedPosition
        stage.cancelDrag()
        // A display change or a settings write during the drag planned the scheduler with the dragged place as home: tell it where home is.
        stage.syncGeometry()
    }

    /// The window has just been put on screen: asks once whether it is on the Space in front. The Space observer hears a Space CHANGE,
    /// and a window that is not on screen reports nothing, so a pet that was hidden or locked away while the user moved to a full-screen
    /// Space, or that started in one, would otherwise be drawn and animated where it cannot be seen. If it is not on the Space the
    /// quiet reason is raised, which orders the windows out again; the Space observer lifts it when the Space changes.
    private func confirmSpace() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.onScreen, self.environment.onActiveSpace(self.panels.stage) == false else { return }
            self.stage.setQuiet(.notOnActiveSpace, active: true)
        }
    }

    private func logGeometry(_ frame: StageFrame?) {
        let now = stage.clock.now
        let sample = frame.map { f -> GeomSample in
            let body = f.hit.bounds, menuRect = f.layout.menuRect
            // `hit=` is where a click is taken: the body and costume pixels' bounds and, while the menu is open, its rectangle.
            var hit = CGRect.zero
            if let body, let menuRect { hit = body.union(menuRect) } else if let body { hit = body } else if let menuRect { hit = menuRect }
            // The open chat panel takes clicks too (it is a window of its own); its rectangle joins `hit=` while it is open.
            let chatRect = chat.rect
            if let chatRect { hit = hit == .zero ? chatRect : hit.union(chatRect) }
            return GeomSample(bubble: f.bubble?.rect, stage: f.clawdRect, hit: hit, body: body, menu: menuRect, menuGen: menuRect == nil ? nil : panels.menu?.gen,
                              chat: chatRect, chatGen: chatRect == nil ? nil : chat.liveGeneration)
        }
        guard let line = geom.line(sample: sample, at: now) else { return }
        monitor.log(line)
    }
}

/// What a GEOM line declares at one moment: the bubble rectangle, the stage rectangle, where a click is taken (`hit`: the body and costume
/// bounds, plus the menu's rectangle while it is open), the body and costume bounds alone (`body`), the open menu's rectangle (`menu`) and
/// the number of its opening (`menuGen`, nil exactly when `menu` is), and the open chat panel's rectangle and opening (`chat`, `chatGen`).
public struct GeomSample: Equatable {
    public var bubble: CGRect?
    public var stage: CGRect
    public var hit: CGRect
    public var body: CGRect?
    public var menu: CGRect?
    public var menuGen: Int?
    /// The open chat panel's rectangle and the number of its opening (nil exactly when no chat is open).
    public var chat: CGRect?
    public var chatGen: Int?
    public init(bubble: CGRect?, stage: CGRect, hit: CGRect, body: CGRect? = nil, menu: CGRect? = nil, menuGen: Int? = nil,
                chat: CGRect? = nil, chatGen: Int? = nil) {
        self.bubble = bubble; self.stage = stage; self.hit = hit; self.body = body; self.menu = menu; self.menuGen = menuGen
        self.chat = chat; self.chatGen = chatGen
    }
}

/// The agent's `GEOM` lines (Interface Contract): the bubble rect, the stage rect and the hit region's bounds, in global AppKit
/// coordinates, stamped with the monotonic clock the attended sampler uses for its `CLICK` lines. A rect is valid from its line
/// until the next one. A bubble appearing or going, and any rectangle that changes shape, is written at once; a rectangle that only
/// moves (a walk) at most four times a second, so a walk does not fill the log. While a menu is declared, on either side of a change,
/// nothing is dropped: the line that declares a menu, every change while one is declared, and the line that removes it are written at once.
public struct GeomLog {
    private var last: GeomSample??
    private var lastAt = -Double.infinity
    public static let moveInterval = 0.25
    public init() {}

    private static func text(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return String(format: "%.1f,%.1f,%.1f,%.1f", rect.minX, rect.minY, rect.width, rect.height)
    }

    /// nil sample: nothing is shown.
    public mutating func line(sample: GeomSample?, at now: TimeInterval) -> String? {
        if let previous = last {
            if previous == sample { return nil }
            if let before = previous, let after = sample, before.bubble == after.bubble, before.menu == nil, after.menu == nil, before.chat == after.chat,
               before.stage.size == after.stage.size, before.hit.size == after.hit.size, before.body?.size == after.body?.size,
               now - lastAt < Self.moveInterval { return nil }
        }
        last = .some(sample); lastAt = now
        let t = String(format: "%.3f", now)
        guard let sample else { return "GEOM t=\(t) bubble=none stage=none hit=none body=none menu=none menugen=none chat=none chatgen=none" }
        return "GEOM t=\(t) bubble=\(Self.text(sample.bubble)) stage=\(Self.text(sample.stage)) hit=\(Self.text(sample.hit)) body=\(Self.text(sample.body)) "
            + "menu=\(Self.text(sample.menu)) menugen=\(sample.menuGen.map(String.init) ?? "none") "
            + "chat=\(Self.text(sample.chat)) chatgen=\(sample.chatGen.map(String.init) ?? "none")"
    }
}

// MARK: the right-click menu

extension AgentRuntime {
    /// A mouse-down's own time stamp, the last field of its INPUT and MOUSE-IGNORED lines: the attended menu check pairs the agent's lines
    /// with its own click log by it. Drags, ups and scrolls carry none.
    fileprivate static func downStamp(_ kind: String, _ event: NSEvent) -> String {
        ["mouseDown", "rightMouseDown", "otherMouseDown"].contains(kind) ? String(format: " et=%.6f", event.timestamp) : ""
    }

    /// A right-click or a control-click on Clawd: opens the menu, or closes it when it is open. False: a higher state holds, and the view
    /// logs the click as ignored (why=busy).
    fileprivate func menuRequested(_ event: NSEvent, how: MenuOpenHow) -> Bool {
        monitor.context = "click"
        return menu.request(how: how, eventTime: event.timestamp) != .busy
    }

    /// A mouse-down of the body window that the ordinary gesture handler ignored (a middle click, a transparent pixel, a click count on one)
    /// is still a click outside the open menu: it closes it, after its MOUSE-IGNORED line. Ups, drags and scrolls close nothing.
    fileprivate func ignoredDown(_ kind: String, _ event: NSEvent) {
        guard ["mouseDown", "rightMouseDown", "otherMouseDown"].contains(kind), menu.isOpen else { return }
        menu.close(.toggle, et: event.timestamp)
    }

    fileprivate func menuLayout() -> MenuLayout {
        // The chat row exists only while chat is on and the runtime has a chat; its words follow the panel.
        let row: MenuChatRow = chat.isAvailable && control.chat ? (chat.isOpen ? .open : .closed) : .absent
        if let cached = menuLayoutCache[row] { return cached }
        let layout = MenuLayout(looks: stage.renderer.art.catalog.looks.map(\.id), drawnStyles: StageRuntime.drawnBubbleStyles, chat: row)
        menuLayoutCache[row] = layout
        return layout
    }

    fileprivate func menuThumbnails() -> [String: Raster] {
        if let cached = menuThumbnailCache { return cached }
        let pictures = MenuThumbnails.all(looks: stage.renderer.art.catalog.looks.map(\.id), art: stage.renderer.art)
        menuThumbnailCache = pictures
        return pictures
    }

    fileprivate func makeMenuView(gen: Int) -> MenuView {
        let view = MenuView(layout: menuLayout(), gen: gen, selection: MenuSelection(settings: live.current), thumbnails: menuThumbnails(), pixelScale: backing)
        view.delegate = menu
        return view
    }
}

// MARK: the menu bar icon

extension AgentRuntime {
    fileprivate func statusMenuState() -> StatusMenuState {
        var state = StatusMenuState(chatAvailable: chat.isAvailable && control.chat, chatOpen: chat.isOpen)
        switch stage.scheduler.visibility {
        case .hidden: state.hiddenByUser = true
        case .quiet: state.quiet = true
        case .visible: break
        }
        return state
    }

    /// The idle frame of the plain look as a template image, made from the art the pet draws with (no art file of its own).
    fileprivate func statusMenuImage() -> NSImage? {
        guard let idle = try? MenuThumbnails.thumbnail(look: PetCatalog.plainLook, art: stage.renderer.art) else { return nil }
        return StatusMenu.templateImage(from: idle)
    }

    /// A pick of the icon's menu, made by AppKit after the menu has closed. Hide, Show and Quit activate nothing and make nothing key.
    fileprivate func statusPick(_ row: StatusMenuRowKind) {
        monitor.context = "status-menu"
        // Each chat face acts only when the chat is still as its label said at the pick: a stale "Close Chat" never opens the chat.
        let stale = (row == .openChat && chat.isOpen) || (row == .closeChat && !chat.isOpen)
        monitor.log("STATUS pick row=\(row.rawValue)\(stale ? " stale" : "")")
        guard !stale else { return }
        let time = environment.chatCurrentEvent()?.timestamp ?? stage.clock.now
        switch row {
        case .openChat, .closeChat: menuToggleChat(eventTime: time)
        case .settings: settings.begin(cause: .statusMenu, at: environment.pointer())
        case .hide: statusWrite(StatusMenu.hideAction)
        case .show: statusWrite(StatusMenu.showAction)
        case .quit: quit()
        }
    }

    /// Stops the chat child, then ends the process. A hide or show still queued behind the running write is dropped by the exit: the line is what
    /// is left of it. Activates nothing and makes nothing key.
    fileprivate func quit() {
        monitor.log("STATUS quit queued=\(menuWriter.queuedCount)")
        shutdownChat()
        environment.exitProcess(0)
    }

    /// What the trace line says of the other surfaces.
    fileprivate func traceFields() -> StatusTraceFields {
        let settingsState: String
        if let window = settings.window { settingsState = window.isKeyWindow ? "key" : "open" } else { settingsState = "closed" }
        let chatState: String
        if let panel = chat.livePanel { chatState = panel.isKeyWindow ? "key" : "open" } else { chatState = "closed" }
        return StatusTraceFields(settings: settingsState, chat: chatState, active: environment.chatFocus.isActive())
    }

    private func statusWrite(_ action: MenuAction) {
        menuWriter.submit(MenuPick(id: menu.takePickID(), action: action, gen: 0))
    }
}

extension AgentRuntime: MenuHost {
    public func menuSelection() -> MenuSelection { MenuSelection(settings: live.current) }

    public func menuPlacement() -> CGRect? {
        guard let frame = stage.lastFrame else { return nil }
        return MenuPlacement.rect(size: menuLayout().size, canvas: frame.canvas, visible: stage.scheduler.geometry.visibleFrame)
    }

    public func menuShow(gen: Int, rect: CGRect) -> MenuSurface? {
        panels.pendingMenuGen = gen
        var opened = false
        stage.perform {
            opened = stage.scheduler.menuOpened()
            // A menu that will open takes the chat with it, in this batch (F1.1); a menu that is refused leaves the chat as it is.
            if opened { stage.menuRect = rect; chat.closeForMenu() }
            stage.renderNow()
        }
        guard opened else { return nil }
        guard let window = panels.menu, window.gen == gen else {
            // The picture could not be made: nothing of the menu may stay.
            menuHide(render: false)
            return nil
        }
        return window
    }

    public func menuOpenSettings(eventTime: TimeInterval) { settings.begin(cause: .rightClick) }
    public func menuQuit() { quit() }

    public func menuToggleChat(eventTime: TimeInterval) {
        stage.perform {
            chat.toggle(eventTime: eventTime)
            stage.renderNow()
        }
    }

    public func menuHide(render: Bool) {
        guard render else {
            stage.menuRect = nil
            stage.scheduler.menuClosed()
            return
        }
        stage.perform {
            stage.scheduler.menuClosed()
            stage.menuRect = nil
            stage.renderNow()
        }
    }
}

// MARK: the Settings window

extension AgentRuntime: SettingsHost {
    public func settingsVisibleFrame(around point: CGPoint?) -> CGRect? {
        let displays = environment.displays()
        if let point, let under = displays.all.first(where: { $0.frame.contains(point) }) { return under.visibleFrame }
        return display?.visibleFrame ?? displays.all.first?.visibleFrame
    }

    public func settingsExamBlocked() -> Bool { stage.scheduler.examActive || environment.examBrowserRunning() }

    public func settingsValues() -> SettingsValues {
        let wall = stage.clock.wallNow
        let setting = stage.settings
        return SettingsValues(stateLine: SettingsStateLine.text(hiddenUntil: setting.hiddenUntil, wall: wall, quiet: stage.scheduler.quietReason),
                              hiddenByUser: setting.hidden(atWall: wall.timeIntervalSince1970), chatFolder: chatSettings.folder,
                              selection: MenuSelection(settings: live.current), chatEnabled: chatSettings.enabled,
                              chatModel: chatSettings.model ?? "", chatPermissions: chatSettings.permissions,
                              aquaReact: bootControl.aquaReact, aquaFollow: aquaModeAtStart == .follow, aquaAutomatic: control.aqua == .auto,
                              overFullScreen: bootControl.overFullScreen)
    }

    public func settingsVoiceStatus() -> SettingsVoiceStatus {
        let installed = environment.aquaInstalled()
        return SettingsVoiceStatus(installed: installed, version: installed ? environment.aquaVersion() : nil)
    }

    public func settingsClaudeLocation() -> ChatSettings.ClaudeLocation { chatSettings.claudeLocation() }

    public func settingsSubmit(_ action: MenuAction, restarts: Bool, onStart: (() -> Bool)?,
                               completion: @escaping (MenuResult) -> Void) -> (id: Int, refusal: MenuRefusal?) {
        let id = menu.takePickID()
        let refusal = menuWriter.submit(MenuPick(id: id, action: action, gen: 0, restarts: restarts), onStart: onStart, completion: completion)
        return (id, refusal)
    }

    /// Whether any verb's child would restart the agent now: control.json as it is on disk (not the applied control) holds a restart-only key
    /// that differs from boot. A missing file reads as the control the agent was built with; any other read failure, an oversized file and a
    /// parse failure count as true.
    public func restartPending() -> Bool {
        let path: String
        do { path = try store.url(SettingsWatcher.fileName).path } catch { return true }
        do {
            let data = try ReadOnlyFile.data(path, limit: 1024 * 1024)
            guard let parsed = AppliedSettings.parse(data) else { return true }
            return !parsed.control.restartKeys(since: bootControl).isEmpty
        } catch FileFailure.system(let code) where code == ENOENT {
            return !defaultControl.restartKeys(since: bootControl).isEmpty
        } catch {
            return true
        }
    }

    public func settingsHolds(_ pick: Int) -> Bool { menuWriter.holds(pick) }

    public func settingsChatPanelForKey() -> ChatPanel? {
        guard let panel = chat.livePanel, panel.isKeyAllowed else { return nil }
        return panel
    }

    public func settingsWillOpen() { chat.cancelHandBack() }

    public func settingsIcon() -> NSImage? {
        guard let idle = try? MenuThumbnails.thumbnail(look: PetCatalog.plainLook, art: stage.renderer.art), let cg = try? idle.cgImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: idle.width * 2, height: idle.height * 2))
    }

    public func settingsLooks() -> [SettingsLookTile] {
        let pictures = menuThumbnails()
        return stage.renderer.art.catalog.looks.map { SettingsLookTile(id: $0.id, picture: pictures[$0.id]) }
    }

    public func settingsStateFolder() -> String { store.root.path }

    public func settingsQuit() { quit() }

    public func settingsWriteRestartRequest(section: SettingsSection) -> String? {
        SettingsRequestFile.leave(store: store, origin: SettingsRequest.originSettingsRestart, section: section.rawValue, seams: environment.settingsRequestSeams)
    }

    public func settingsRemoveRestartRequest(ifLine line: String) { SettingsRequestFile.remove(store: store, ifLine: line) }
}

// MARK: the chat

extension AgentRuntime {
    /// The agent is quitting (SIGTERM): the panel goes and the child is hard-stopped.
    public func shutdownChat() { chat.shutdown() }
    /// The Settings window's controller, for the tests and the attended checks.
    public var settingsController: SettingsController { settings }
    /// The chat's turn state, for status.json and the tests.
    public var chatTurn: ChatTurnState { chat.session?.turn ?? .none }
    public var chatPanelIsOpen: Bool { chat.isOpen }
    /// The open chat panel (nil when closed): for the tests and the attended checks.
    public var chatPanel: ChatPanel? { chat.livePanel }
    public var chatController: ChatController { chat }
}

extension AgentRuntime: ChatHost {
    public func chatRefusal() -> ChatRefusal? {
        if stage.scheduler.examActive { return .exam }
        if dragging { return .drag }
        switch stage.scheduler.visibility {
        case .hidden: return .hidden
        case .quiet: return .quiet
        case .visible: break
        }
        if display == nil { return .noDisplay }
        return stage.lastFrame == nil ? .hidden : nil
    }

    public func chatPlacement() -> CGRect? {
        guard let frame = stage.lastFrame else { return nil }
        return ChatPanelPlacement.rect(canvas: frame.canvas, bubbleSide: stage.settings.bubbleSide, visible: stage.scheduler.geometry.visibleFrame)
    }

    public func chatTerminalPlacement(size: CGSize?) -> CGRect? {
        guard let frame = stage.lastFrame else { return nil }
        return ChatPanelPlacement.rect(canvas: frame.canvas, bubbleSide: stage.settings.bubbleSide, visible: stage.scheduler.geometry.visibleFrame,
                                       width: size?.width ?? ChatPanelPlacement.terminalWidth, maxHeight: size?.height ?? ChatPanelPlacement.terminalMaxHeight)
    }

    public func chatVisibleFrame() -> CGRect? { stage.lastFrame == nil ? nil : stage.scheduler.geometry.visibleFrame }

    /// Every display, for the chat panel's own display (it follows the pointer onto another one). Clawd's display alone when none is listed.
    public func chatPetBodyFrame() -> CGRect? { panels.body.isVisible ? panels.body.frame : nil }
    public func chatScreens() -> [ChatScreen] {
        let all = environment.displays().all.enumerated().map { index, display in
            ChatScreen(id: display.uuid ?? "display-\(index)", frame: display.frame, visible: display.visibleFrame)
        }
        return all.isEmpty ? chatVisibleFrame().map { [ChatScreen(frame: $0, visible: $0)] } ?? [] : all
    }

    public var chatOverFullScreen: Bool { control.overFullScreen }

    public func chatDidOpen() {
        stage.perform {
            stage.scheduler.chatOpened()
            stage.renderNow()
        }
    }

    public func chatDidClose(render: Bool) {
        guard render else { stage.scheduler.chatClosed(); return }
        stage.perform {
            stage.scheduler.chatClosed()
            stage.renderNow()
        }
    }

    public func chatCloseMenu() { menu.close(.chat) }
    public func chatExamActive() -> Bool { stage.scheduler.examActive }
    public func chatExamBrowserRunning() -> Bool { environment.examBrowserRunning() }
    public func chatTurnStarted() { stage.perform { controller.chatTurnStarted() } }
    public func chatTurnEnded(_ outcome: ChatTurnOutcome) { stage.perform { controller.chatTurnEnded(outcome) } }
}

/// The sink the desktop observers drive: it forwards everything to the stage and reconciles Aqua first when a screen unlock is about to
/// lift its quiet reason (amendment D-3).
final class AquaReconcilingSink: QuietSink {
    private let stage: StageRuntime
    private let reconcile: () -> Void
    init(stage: StageRuntime, reconcile: @escaping () -> Void) { self.stage = stage; self.reconcile = reconcile }
    func setQuiet(_ reason: QuietReason, active: Bool) {
        if reason == .screenLocked, !active { reconcile() }
        stage.setQuiet(reason, active: active)
    }
    func setReduceMotion(_ on: Bool) { stage.setReduceMotion(on) }
    func setAppearance(_ appearance: BubbleAppearance) { stage.setAppearance(appearance) }
}
