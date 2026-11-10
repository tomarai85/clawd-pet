import AppKit
import ClawdCore

/// One display as the placement code sees it. Frames are in AppKit's bottom-left global coordinates.
public struct DisplayInfo: Equatable {
    public var uuid: String?
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var backingScaleFactor: Double
    public init(uuid: String?, frame: CGRect, visibleFrame: CGRect, backingScaleFactor: Double) {
        self.uuid = uuid; self.frame = frame; self.visibleFrame = visibleFrame; self.backingScaleFactor = backingScaleFactor
    }
    public init(screen: NSScreen) {
        var uuid: String?
        if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let value = CGDisplayCreateUUIDFromDisplayID(id.uint32Value)?.takeRetainedValue() {
            uuid = CFUUIDCreateString(nil, value) as String
        }
        self.init(uuid: uuid, frame: screen.frame, visibleFrame: screen.visibleFrame, backingScaleFactor: Double(screen.backingScaleFactor))
    }
}

/// The attached displays, the primary one (the menu bar's, NSScreen.screens[0]) first. The pet's display is the one whose UUID it saved;
/// when that one is not attached it stands on the primary display, which stays the same wherever the user clicks. NSScreen.main is the screen of
/// the window with keyboard focus, so a pet placed on it would jump between screens with every click on another one; it is banned in
/// Sources (scripts/lint_banned.py, focus-following-screen).
public struct DisplaySet {
    public var all: [DisplayInfo]
    public init(all: [DisplayInfo]) { self.all = all }
}

/// Everything `AgentRuntime` takes from the machine it runs on. The production values read the real screens, the real
/// pointer, the real Aqua log and order the panel on screen; a test substitutes each one, so the real input and render
/// code can run against synthetic events and fake displays without a window ever reaching the screen.
public struct RuntimeEnvironment {
    public var displays: () -> DisplaySet
    public var pointer: () -> CGPoint
    public var aquaLogPath: () -> String
    public var aquaRunning: () -> Bool
    /// Whether Aqua Voice is installed (the `auto` setting follows Aqua only then).
    public var aquaInstalled: () -> Bool
    /// The installed dictation app's version (`CFBundleShortVersionString`), read from the app found by its bundle identifier; nil when it is
    /// not installed or has none. Inert by default: only `production` reads an application bundle, so no test reads the real one.
    public var aquaVersion: () -> String?
    /// Aqua's liveness comes from the kernel's process table and a process-exit registration (amendment D-1, D-2). Without them the runtime
    /// builds a table from `aquaRunning` and a registry that never fires, so a test that only says whether Aqua runs never reads the real kernel.
    public var aquaTable: AquaProcessTable?
    public var aquaExitRegistry: AquaExitRegistry?
    /// Where the application launch and quit notifications arrive, and the observation of the system's application list (both only trigger
    /// a reconcile). A test posts and fires its own.
    public var workspaceCenter: () -> NotificationCenter
    public var observeApplicationList: (@escaping () -> Void) -> AnyObject?
    /// The clock the stage, the scheduler and the menu run on, and the one timer that wakes them. Production: the system's uptime and a
    /// dispatch timer; a test supplies a virtual clock and a fake timer and advances time itself.
    public var clock: () -> PetClock
    public var timer: () -> PetFiringTimer
    /// The wall clock the diagnostic window runs on.
    public var wallClock: () -> Date
    /// Whether a LockDown Browser application is running now (`ExamBrowserRule`): asked afresh at the start, on a wake, an unlock, a Space change,
    /// after a quit, and every 10 s while the pet stands down. A test supplies its own; none ever starts the real app.
    public var examBrowserRunning: () -> Bool
    public var present: (NSPanel) -> Void
    public var dismiss: (NSPanel) -> Void
    /// Seconds since the user's last keyboard or mouse input (nil: unreadable). SLEEP is decided from it (spec 6.1).
    public var inputIdle: () -> TimeInterval?
    /// Starts the desktop observers (display sleep, lock, Space, Reduce Motion). A test supplies none.
    public var observeDesktop: (QuietSink, NSPanel) -> AnyObject?
    /// Whether the pet's window is on the Space in front (nil: it is not on screen, which says nothing about the Space). The runtime asks
    /// it whenever the pet has just been put on screen, because the observers only hear the Space change, not a Space that changed
    /// while the pet was away (hidden, locked) or before it started.
    public var onActiveSpace: (NSPanel) -> Bool?
    /// The right-click menu's collaborators (Sprint M). Each is asked for when the runtime starts; none of them does anything until a menu
    /// opens: the timer is armed only while it is open, and the outside-click monitor is installed per opening.
    public var menuTimer: () -> MenuTimerSource
    public var menuOutsideClicks: () -> MenuOutsideClickSource
    /// The agent's HOME: the menu runs `$HOME/bin/clawd-pet` from it.
    public var home: () -> URL
    /// The chat (Clawd v3). `chatSession` builds the bridge to Claude Code on the first double-click; nil means this environment has no chat at
    /// all and a double-click stays what it was in v2 (every test rig starts so). The panel is shown with `present`, made key by
    /// `chatMakeKey`, and hidden with `dismiss`; `chatCurrentEvent` is the application's current event (the cause of a key notification);
    /// `chatTimer` carries the one idle-stop deadline; `chatInstallEditMenu` gives the accessory app its Edit menu.
    public var chatSession: ((ChatSessionConfig) -> ChatSessionDriving?)?
    public var chatMakeKey: (ChatPanel) -> Void
    public var chatCurrentEvent: () -> ChatCurrentEvent?
    public var chatTimer: () -> MenuTimerSource
    public var chatInstallEditMenu: () -> Void
    /// The terminal path's collaborators (R9.2): nil means the environment has no terminal and the stream path is the only one. The default is
    /// nil; the real values (the system pasteboard, a memory-pressure source, the agent binary) exist only in `production`.
    public var chatTerm: ChatTermEnvironment?
    /// The web chat's collaborators (Stage 2): nil means the environment has no web chat and `chatView: chat` opens the stream view. The default is
    /// nil; the real values (the installed page directory, the default browser, the system pasteboard) exist only in `production`.
    public var chatWeb: ChatWebEnvironment?
    /// Focus: how the open chat activates Clawd, reads the frontmost application and hands activation back (Sprint 3e). Every default does
    /// nothing; the real values exist only in `production`.
    public var chatFocus: ChatFocusSeams
    /// Where the terminal panel's size and position are remembered (the agent's own state directory); nil keeps nothing between openings.
    public var chatGeometry: ChatGeometryStoring?
    /// The menu bar icon (Stage SA): builds the one status item. nil means this environment has no status bar and the pet makes no item; the
    /// default is nil, so no rig ever makes a real one. The real value exists only in `production`.
    public var statusBar: (() -> StatusItemSurface)?
    /// Ends the process. The default does nothing, so no rig ever exits; the real value (`exit`) exists only in `production`.
    public var exitProcess: (Int32) -> Void
    /// The Settings window goes on and off screen only through these two, for every open and every close. The defaults do nothing, so no rig
    /// ever shows the window; the real values exist only in `production`.
    public var settingsPresent: (NSWindow) -> Void
    public var settingsDismiss: (NSWindow) -> Void
    /// Makes the Settings window key (production: its own make-key call) and builds the folder picker (default: inert).
    public var settingsMakeKey: (SettingsWindow) -> Void
    public var settingsFolderPicker: () -> SettingsFolderPicking
    /// The folders Q6's search for `claude` looks in while `chatClaude` is not set (`$HOME` stands for the home folder). Production: the one
    /// constant list; a rig points it at stubbed folders or at none.
    public var claudeSearch: [String]
    /// The clocks, the pid and the process table the `open-settings` request is written and judged with. Inert by default; real in `production`.
    public var settingsRequestSeams: SettingsRequestSeams
    public init(displays: @escaping () -> DisplaySet, pointer: @escaping () -> CGPoint, aquaLogPath: @escaping () -> String,
                aquaRunning: @escaping () -> Bool, present: @escaping (NSPanel) -> Void, dismiss: @escaping (NSPanel) -> Void,
                examBrowserRunning: @escaping () -> Bool = { ExamBrowserRule.anyRunning() },
                inputIdle: @escaping () -> TimeInterval? = { InputIdle.seconds() },
                observeDesktop: @escaping (QuietSink, NSPanel) -> AnyObject? = RuntimeEnvironment.productionObservers,
                onActiveSpace: @escaping (NSPanel) -> Bool? = RuntimeEnvironment.panelIsOnActiveSpace,
                menuTimer: @escaping () -> MenuTimerSource = { DispatchPetTimer() },
                menuOutsideClicks: @escaping () -> MenuOutsideClickSource = { GlobalMouseDownSource() },
                home: @escaping () -> URL = { PetHome.url },
                chatSession: ((ChatSessionConfig) -> ChatSessionDriving?)? = nil,
                chatMakeKey: @escaping (ChatPanel) -> Void = { _ in },
                chatCurrentEvent: @escaping () -> ChatCurrentEvent? = { nil },
                chatTimer: @escaping () -> MenuTimerSource = { DispatchPetTimer() },
                chatInstallEditMenu: @escaping () -> Void = {},
                chatTerm: ChatTermEnvironment? = nil,
                chatWeb: ChatWebEnvironment? = nil,
                chatFocus: ChatFocusSeams = ChatFocusSeams(),
                chatGeometry: ChatGeometryStoring? = nil,
                statusBar: (() -> StatusItemSurface)? = nil,
                exitProcess: @escaping (Int32) -> Void = { _ in },
                settingsPresent: @escaping (NSWindow) -> Void = { _ in },
                settingsDismiss: @escaping (NSWindow) -> Void = { _ in },
                settingsMakeKey: @escaping (SettingsWindow) -> Void = { _ in },
                settingsFolderPicker: @escaping () -> SettingsFolderPicking = { InertFolderPicker() },
                claudeSearch: [String] = [],
                settingsRequestSeams: SettingsRequestSeams = .inert,
                aquaTable: AquaProcessTable? = nil, aquaExitRegistry: AquaExitRegistry? = nil,
                workspaceCenter: @escaping () -> NotificationCenter = { NSWorkspace.shared.notificationCenter },
                observeApplicationList: @escaping (@escaping () -> Void) -> AnyObject? = { _ in nil },
                wallClock: @escaping () -> Date = { Date() },
                clock: @escaping () -> PetClock = { SystemPetClock() },
                timer: @escaping () -> PetFiringTimer = { DispatchPetTimer() },
                aquaInstalled: @escaping () -> Bool = { true },
                aquaVersion: @escaping () -> String? = { nil }) {
        self.displays = displays; self.pointer = pointer; self.aquaLogPath = aquaLogPath
        self.aquaRunning = aquaRunning; self.present = present; self.dismiss = dismiss; self.examBrowserRunning = examBrowserRunning
        self.inputIdle = inputIdle; self.observeDesktop = observeDesktop; self.onActiveSpace = onActiveSpace
        self.menuTimer = menuTimer; self.menuOutsideClicks = menuOutsideClicks; self.home = home
        self.chatSession = chatSession; self.chatMakeKey = chatMakeKey; self.chatCurrentEvent = chatCurrentEvent
        self.chatTimer = chatTimer; self.chatInstallEditMenu = chatInstallEditMenu; self.chatTerm = chatTerm; self.chatWeb = chatWeb
        self.chatFocus = chatFocus; self.chatGeometry = chatGeometry
        self.statusBar = statusBar; self.exitProcess = exitProcess
        self.settingsPresent = settingsPresent; self.settingsDismiss = settingsDismiss
        self.settingsMakeKey = settingsMakeKey; self.settingsFolderPicker = settingsFolderPicker; self.claudeSearch = claudeSearch
        self.settingsRequestSeams = settingsRequestSeams
        self.aquaTable = aquaTable; self.aquaExitRegistry = aquaExitRegistry; self.workspaceCenter = workspaceCenter
        self.observeApplicationList = observeApplicationList; self.wallClock = wallClock
        self.clock = clock; self.timer = timer; self.aquaInstalled = aquaInstalled
        self.aquaVersion = aquaVersion
    }
    /// Key-value observation of NSWorkspace.runningApplications; the handler runs on the main queue.
    public static let productionApplicationList: (@escaping () -> Void) -> AnyObject? = { changed in
        NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { _, _ in DispatchQueue.main.async(execute: changed) }
    }
    /// A window that is not on screen reports nothing about the Space.
    public static let panelIsOnActiveSpace: (NSPanel) -> Bool? = { panel in panel.isVisible ? panel.isOnActiveSpace : nil }
    public static let productionObservers: (QuietSink, NSPanel) -> AnyObject? = { sink, panel in
        let observers = DesktopObservers(sink: sink, panelOnActiveSpace: { [weak panel] in
            guard let panel else { return nil }
            return panelIsOnActiveSpace(panel)
        })
        observers.publishInitialState(displayAsleep: DesktopObservers.currentDisplayAsleep(), locked: DesktopObservers.currentScreenLocked())
        return observers
    }
    public static let production = RuntimeEnvironment(
        displays: { DisplaySet(all: NSScreen.screens.map(DisplayInfo.init(screen:))) },
        pointer: { NSEvent.mouseLocation },
        aquaLogPath: { AquaInput.logPath },
        aquaRunning: { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == AgentRuntime.aquaBundleIdentifier } },
        present: { $0.orderFrontRegardless() },
        dismiss: { $0.orderOut(nil) },
        // The bridge to Claude Code: one long-lived `claude` child per conversation, built on the first double-click.
        chatSession: { var config = $0; config.resume = ChatResume.Roots.production(); return ChatSession(config: config) },
        chatMakeKey: { $0.makeKeyForOpening() },
        chatCurrentEvent: { NSApp.currentEvent.map(ChatCurrentEvent.init) },
        chatInstallEditMenu: ChatEditMenu.install,
        chatTerm: ChatTermEnvironment(agent: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path, state: nil,
                                      timers: DispatchChatTimers(), pasteboard: SystemChatPasteboard(),
                                      memoryPressure: { DispatchMemoryPressure(handler: $0) }),
        chatWeb: ChatWebEnvironment(pageDirectory: PetHome.stateRoot.appendingPathComponent("chat-page", isDirectory: true),
                                    openLink: ChatWebOpen.production, pasteboard: SystemChatPasteboard(),
                                    attach: .production, resume: .production()),
        chatFocus: .production(),
        statusBar: StatusMenu.productionSurface,
        exitProcess: { exit($0) },
        settingsPresent: { $0.orderFrontRegardless() },
        settingsDismiss: { $0.orderOut(nil) },
        settingsMakeKey: { $0.makeKeyForOpening() },
        settingsFolderPicker: { SettingsFolderPicker() },
        claudeSearch: ChatSettings.claudeSearchList,
        settingsRequestSeams: .system,
        aquaTable: KernelAquaTable(), aquaExitRegistry: KqueueExitRegistry(),
        observeApplicationList: RuntimeEnvironment.productionApplicationList,
        aquaInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentRuntime.aquaBundleIdentifier) != nil },
        aquaVersion: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentRuntime.aquaBundleIdentifier)
                .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        })
}
