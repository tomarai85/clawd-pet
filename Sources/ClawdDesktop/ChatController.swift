import AppKit
import ClawdCore

/// Why the chat panel does not open (F1.1); the raw value is the `reason=` of the `CHAT refuse` line.
public enum ChatRefusal: String, Equatable { case off, quiet, hidden, exam, drag, noDisplay = "no-display" }

/// Why the panel closed (F1.3); the raw value is the `reason=` of the `CHAT close` line.
public enum ChatCloseReason: String, CaseIterable {
    case esc, toggle, button, menu, drag, hidden, exam, off, contract, quit
    /// The terminal and web kinds: Cmd+W; a `chatView` change.
    case shortcut, view
    /// The user clicked elsewhere (a plain click in another application, decided at its mouse-up), or the panel was left without the user's cause
    /// (an activation or a key of the panel that nothing the user did explains). The panel is closed rather than left stale or inactive. Another
    /// application's activation alone never closes it (Orca closes nothing on a blur).
    case outside
    /// A panel that a file drag brought back (P12) and that the drag then left without dropping on it.
    case recall
}

/// What a key notification of a window is, for the focus monitor: the live opening's panel with the user's cause is exempt, the same
/// panel without one is a violation that the controller has already named in the log. nil: not the chat panel at all.
public enum ChatKeyVerdict: Equatable {
    case exempt, uncaused
    /// The key came between `willBecomeActive` and `didBecomeActive`: the controller judges it with that activation and records it itself if it
    /// turns out uncaused.
    case deferred
}

/// What the controller makes of an application activation (Sprint 3e item 6).
public enum ChatActivationVerdict: Equatable { case exempt, answeredByClose, violation }

/// What the controller needs from the runtime that owns the scheduler and the picture.
public protocol ChatHost: AnyObject {
    /// Why the chat cannot open now; nil when it can (the `chat` setting included).
    func chatRefusal() -> ChatRefusal?
    /// Where the panel goes now, in global points; nil when Clawd is not on screen.
    func chatPlacement() -> CGRect?
    /// The same for the terminal panel, beside Clawd at `size` (nil: the default size, 360 x 240 at most), capped to Clawd's visible frame.
    func chatTerminalPlacement(size: CGSize?) -> CGRect?
    /// The visible frame of the display Clawd is on (the terminal panel's size and position are kept inside it); nil when unknown.
    func chatVisibleFrame() -> CGRect?
    /// Every display (frame and visible frame), for the panel's own display. The default is Clawd's display alone.
    func chatScreens() -> [ChatScreen]
    /// Clawd's body window while it is on screen (the file drag that brings the chat back may be near it); nil when it is not.
    func chatPetBodyFrame() -> CGRect?
    var chatOverFullScreen: Bool { get }
    /// The panel opened: the scheduler's `chatHold` and one render (the GEOM line).
    func chatDidOpen()
    /// The panel closed, whatever the reason; `render` is false when the windows are already going.
    func chatDidClose(render: Bool)
    /// An open right-click menu closes before the chat opens.
    func chatCloseMenu()
    /// The exam stand-down is active (the scheduler's state).
    func chatExamActive() -> Bool
    /// The exam browser is running right now (asked afresh; the spawn site's own question).
    func chatExamBrowserRunning() -> Bool
    /// The scenes (F4).
    func chatTurnStarted()
    func chatTurnEnded(_ outcome: ChatTurnOutcome)
}

public extension ChatHost {
    func chatTerminalPlacement(size: CGSize?) -> CGRect? {
        chatPlacement().map { rect in size.map { CGRect(origin: rect.origin, size: $0) } ?? rect }
    }
    func chatVisibleFrame() -> CGRect? { nil }
    func chatScreens() -> [ChatScreen] { chatVisibleFrame().map { [ChatScreen(frame: $0, visible: $0)] } ?? [] }
    func chatPetBodyFrame() -> CGRect? { nil }
}

/// The chat panel's rules: when it opens and closes, which opening a notification belongs to, what Enter and Esc do, and when the child is
/// stopped. It owns one `ChatSessionDriving` (the bridge; a fake in tests) and one panel per opening.
///
/// Every opening has a number, `gen`, from 1 in the process; a refused open takes none. Everything it logs carries ids, counts and reasons
/// only: never chat text, never a folder path (F6).
public final class ChatController {
    /// How long the panel stays closed with no turn before the child is stopped gracefully (F2.2).
    public static let idleStop: TimeInterval = 600

    public private(set) var generation = 0
    public var isOpen: Bool { live != nil }
    public var liveGeneration: Int? { live?.gen }
    public var livePanel: ChatPanel? { live?.panel }
    /// The panel's frame while open, in global points.
    public var rect: CGRect? { live?.panel.frame }
    public private(set) var session: ChatSessionDriving?
    /// The text of the input as the last close left it: it survives close and reopen.
    public private(set) var draft = ""
    /// What was sent from the composer, for the Up and Down keys (Q7). Lives as long as the agent.
    public private(set) var history = ChatComposerHistory()
    /// The draft and its chips saved in chat-private/chat-composer.json (Q8); nil in an environment that keeps no state directory.
    public private(set) var composerStore: ChatComposerStore?
    /// The `/` catalog a session last reported (Q9, D3), saved in chat-private/chat-catalog.json; a fresh start offers the saved one.
    public private(set) var catalog = ChatCatalog()
    private var catalogStore: ChatCatalogStore?
    /// The queued messages, the queue's pause and the sends written and not yet settled (Q12, Q13). Mirrored into chat-private/chat-composer.json by
    /// every change (`queueChanged`).
    public private(set) var queue = ChatQueue()
    /// A card whose Steer was pressed while the turn was stopping: it goes first when the turn is none (Q13).
    private var steerAfterStop: String?
    /// A send is being handed to the session: nothing else is drained meanwhile (the session's own change callbacks run inside it).
    private var transmitting = false
    /// The image sends reading their files (Q16), by origin: "draft", or the card's id. A second press on the same origin does nothing until its read
    /// ends, and one origin's read ending never unlocks the other.
    private var imageReads: Set<String> = []
    /// How long an image read may take before the send is refused (the drop copy's 120 s: Orca's attachment read has no deadline of its own,
    /// claude-structured-dispatch-content.ts:70-110).
    public static let imageReadSeconds = DragTempCopier.dropTimeout
    /// A recall is setting the input's text: that change is not an edit.
    private var recalling = false

    /// Test seam: runs on each new panel after it is built and before the audit.
    public var panelPrepared: ((ChatPanel) -> Void)?

    /// `terminal` is true for every opening that has the container's chrome (the title bar, the resize handles, geometry kept): the terminal kind
    /// and the web kind. `web` is the web kind's body; its session is the stream bridge's, so it has the stream kind's draft and idle stop.
    private final class Opening {
        let gen: Int; let panel: ChatPanel; let terminal: Bool; let web: ChatWebBody?
        /// The terminal panel's geometry belongs to the user (restored or changed by hand): a re-measure keeps it instead of following Clawd.
        var custom = false
        var maximized = false
        var restoreRect: CGRect?
        var customBeforeMaximize = false
        /// The size this opening was placed with (the saved dimensions, nil: the default) before the display cap: replace() and Restore of a
        /// panel that still follows Clawd use it.
        var placedSize: CGSize?
        var gestureStart: CGRect?
        /// `custom` as the gesture found it: a press that does not move the panel gives it back.
        var customBeforeGesture = false
        /// The visible frame of the panel's screen when the gesture began (a resize is clamped to it for the whole gesture), and what the gesture is.
        var gestureVisible: CGRect?
        var gestureKind: String?
        /// The display (ChatScreen.id) the panel was maximized on, and, for an id built from an index, the displays' signature when it was taken:
        /// that id is used only until the next display change (Q20 c).
        var maximizedScreen: String?
        var maximizedSignature: String?
        /// The corner anchor committed by the last gesture or read from the file (Q26); nil: none, and today's clamp applies.
        var anchor: ChatAnchor?
        /// The display the anchor was committed on (or migrated onto) and, for an id built from an index, the displays' signature then: the anchor
        /// resolves there while that holds, so a pet frame does not pull the panel onto Clawd's display. The file stores neither (N19).
        var anchorScreen: String?
        var anchorSignature: String?
        /// The opening's file attachments (drops, picks, pastes), the picker that is up, and whether a file drag brought the panel back (P12): it
        /// takes no key until the user's own drop or press promotes it.
        var attach: ChatAttachmentSession?
        var picker: ChatAttachHandle?
        /// The picker is being shown (`present` has not returned): its own key and activation come inside that call, before `picker` is set.
        var pickerPresenting = false
        var recalled = false
        /// The link popover's status line ("Copied link" or its failure) and the deadline that clears it.
        var linkStatus: String?
        var linkStatusDeadline: ChatTimerHandle?
        /// The reader's place as this opening's page last reported it (Q18); copied to the controller at close.
        var latestView: ChatViewState?
        init(gen: Int, panel: ChatPanel, terminal: Bool, web: ChatWebBody? = nil) { self.gen = gen; self.panel = panel; self.terminal = terminal; self.web = web }
        /// The opening's child is the stream bridge's (the stream kind and the web kind), not the terminal path's.
        var usesSession: Bool { !terminal || web != nil }
    }
    private var live: Opening?
    /// The reader's place in the transcript page, kept across a close (Q18, D2): memory only, dropped at a /clear. The page itself goes at close.
    private var savedView: ChatViewState?

    /// What a click-close leaves for the next 30 s (P12): the closed panel's place, the drag probe and its deadline; during a recall also the
    /// deadlines that end it. One object, so a stale timer of an earlier one finds `recall` is no longer it.
    private final class Recall {
        let frame: CGRect, maximized: Bool, restoreRect: CGRect?, custom: Bool, customBeforeMaximize: Bool, maximizedScreen: String?
        let maximizedSignature: String?, anchor: ChatAnchor?, anchorScreen: String?, anchorSignature: String?
        let gen: Int
        let placedSize: CGSize?
        /// The drag pasteboard's change count that a drag must differ from: the one at the click-close, and again after every probe `.up` with no recall.
        var changeCount: Int
        var lastRead = -TimeInterval.infinity
        var probe: ChatTimerHandle?, probeDeadline: ChatTimerHandle?, entryDeadline: ChatTimerHandle?, checkDeadline: ChatTimerHandle?
        var upDeadline: ChatTimerHandle?
        var recalledGen: Int?
        var entered = false
        /// A file drag is inside the recalled body now: entered, and no exit or end since.
        var inside = false
        init(opening: Opening, changeCount: Int) {
            frame = opening.panel.frame; maximized = opening.maximized; restoreRect = opening.restoreRect; custom = opening.custom
            customBeforeMaximize = opening.customBeforeMaximize; maximizedScreen = opening.maximizedScreen; gen = opening.gen; self.changeCount = changeCount
            placedSize = opening.placedSize
            maximizedSignature = opening.maximizedSignature; anchor = opening.anchor
            anchorScreen = opening.anchorScreen; anchorSignature = opening.anchorSignature
        }
        func cancelAll() {
            for handle in [probe, probeDeadline, entryDeadline, checkDeadline, upDeadline] { handle?.cancel() }
            probe = nil; probeDeadline = nil; entryDeadline = nil; checkDeadline = nil; upDeadline = nil
        }
    }
    private var recall: Recall?
    /// How long after a click-close a file drag may bring the panel back, how near (in points) it must be, how long a recalled panel waits to be
    /// entered, and how long before the left button is looked at again.
    public static let recallWindow: TimeInterval = 30
    public static let recallDistance: CGFloat = 120
    public static let recallEntry: TimeInterval = 3
    public static let recallCheck: TimeInterval = 10
    public static let recallReadInterval: TimeInterval = 0.05
    /// How long a recalled panel that holds the drag waits for its drop after the global mouse-up (the up reaches the probe before the drop).
    public static let recallDropGrace: TimeInterval = 0.5
    private unowned let host: ChatHost
    private let environment: RuntimeEnvironment
    private let makeSession: ((ChatSessionConfig) -> ChatSessionDriving?)?
    private let timer: MenuTimerSource
    private let enabled: () -> Bool
    private let settings: () -> ChatSettings
    private let log: (String) -> Void
    private var handlingAcceptedClick = false
    private var examStopped = false
    private var wasEnabled = true
    /// The terminal path (spec R9.2): nil when the environment supplies none.
    public private(set) var termPath: ChatTermPath?
    private var lastView: ChatView
    private var editMenuInstalled = false

    /// How long the open's activation token lasts (Sprint 3e item 2), how long each hand-back step waits (item 7), how soon after the panel's
    /// own mouse-down an activation counts as its click (item 3), and how far apart two mouse-downs must be to be different presses (item 2).
    public static let activationDeadline: TimeInterval = 1
    public static let handbackDeadline: TimeInterval = 0.5
    public static let clickWindow: TimeInterval = 1
    public static let pressMargin: TimeInterval = 0.05
    private let focus: ChatFocusSeams
    private let geometry: ChatGeometryStoring?
    private let clock: PetClock
    /// The mouse-downs Clawd's windows received; the runtime hands the same log to the pet and menu windows.
    public let windowPresses: WindowPressLog
    /// Records a violation the controller judged late (a key that waited for its activation); wired by the runtime.
    public var lateViolation: (() -> Void)?
    /// Whether Clawd's current activation is claimed by any surface (the focus monitor's claim record): a key on the open panel inside it is a return.
    public var claimedActivation: () -> Bool = { false }
    /// Whether the focus monitor's activation step is running now; wired by the runtime.
    public var activationStepRunning: () -> Bool = { false }
    /// Told when a new opening begins its activation, so another surface's hand-back in flight ends (it would deactivate Clawd under this panel).
    public var willBeginActivation: (() -> Void)?

    /// What one opening knows about the activation it asked for.
    private final class Activation {
        let gen: Int
        var target: ChatAppRef?
        var requestedAt: TimeInterval = 0
        var tokenOpen = false
        /// Clawd became active through an exempt activation of this opening and has not resigned since.
        var active = false
        var willBecome = false
        var pendingKeys = 0
        var refused = false
        var pressSpent = false
        /// When the activation record began, and when Clawd last resigned (L7: a press newer than both is a click into Clawd).
        var beganAt: TimeInterval = 0
        var lastResign: TimeInterval?
        var otherAppSeen = false
        var closeQueued = false
        /// The `eventTime` of the double-click that opened this chat.
        var openEventTime: TimeInterval = 0
        /// An exempt surface (the screenshot UI, an input method, dictation) took the activation: the activation that gives it back to the
        /// application that was in front before is its return. `exemptReturnPid` is that application (nil: Clawd itself, whose return goes
        /// through `activationVerdict`). Any other application's activation is an ordinary click elsewhere.
        var exemptReturnPending = false
        var exemptReturnPid: Int32?
        /// Clawd was the application in front when the latest exempt surface took the activation (it was active, and no other application has
        /// been activated since): kept apart from `active`, which `didResignActive` clears whichever notification comes first.
        var frontIsClawd = false
        /// What the close line says closed the panel: `press:<owner>`, `app:<owner>` or `uncaused`.
        var closeBy: String?
        var pressObserver: ChatTimerHandle?
        /// The press elsewhere that waits for its mouse-up (P1). All of it dies with the opening.
        var press: PendingPress?
        var followUp: ChatTimerHandle?
        var pressDeadline: ChatTimerHandle?
        /// The close was caused by a press in another application: that press's own application takes the activation.
        var clickedElsewhere = false
        var deadline: ChatTimerHandle?
        var observer: ChatTimerHandle?
        init(gen: Int) { self.gen = gen }
    }
    /// A press in another application that has not ended: where it went down, whose it is, and whether it has moved 4 pt (or a file drag came
    /// to Clawd) since.
    private struct PendingPress {
        var button: ChatPressButton
        var down: CGPoint
        var owner: String
        var pid: Int32?
        /// An activation opened it, so the down that follows (the monitor saw it late) is merged into it.
        var fromActivation: Bool
        var moved = false
    }
    /// Orca's FLOATING_TERMINAL_TRIGGER_DRAG_THRESHOLD (FloatingTerminalToggleButton.tsx:25, 163), and how long a press may wait for its up.
    public static let dragThreshold: CGFloat = 4
    public static let pressDeadline: TimeInterval = 10
    private var act: Activation?
    private var handbackSteps: ChatTimerHandle?
    /// The application the close will hand activation back to (nil: none recorded).
    public var handBackTarget: ChatAppRef? { act?.target }

    public init(host: ChatHost, environment: RuntimeEnvironment, enabled: @escaping () -> Bool,
                settings: @escaping () -> ChatSettings = { ChatSettings() }, presses: WindowPressLog = WindowPressLog(),
                log: @escaping (String) -> Void) {
        self.host = host; self.environment = environment; self.enabled = enabled; self.settings = settings; self.log = log
        focus = environment.chatFocus; clock = environment.clock(); windowPresses = presses; geometry = environment.chatGeometry
        makeSession = environment.chatSession
        timer = environment.chatTimer()
        wasEnabled = enabled()
        lastView = settings().view
        timer.onFire = { [weak self] in self?.idleTimerFired() }
        if let termEnvironment = environment.chatTerm {
            termPath = ChatTermPath(environment: termEnvironment, settings: settings, log: log,
                                    currentEvent: { environment.chatCurrentEvent() }, close: { [weak self] in self?.close($0) })
        }
        if let web = environment.chatWeb, let state = web.attach.state {
            let store = ChatComposerStore(state: state, timers: web.composerTimers, log: log)
            composerStore = store
            draft = store.draft
            store.onSaveStateChanged = { [weak self] in self?.live?.web?.setDraftWarning(self?.composerStore?.saveFailed == true) }
            let saved = ChatCatalogStore(state: state, log: log)
            catalogStore = saved
            if let rows = saved.load() { catalog = ChatCatalog(saved: rows) }
            // Cards left from a run that ended wait under the `restarted` pause, and every send that was in flight comes back as a held doubt card.
            queue = ChatQueue(restoring: store.content)
            persistQueue()
        }
    }

    /// False in every test rig that does not supply a session: the double-click is then a plain scheduler click, as in v2.
    public var isAvailable: Bool { makeSession != nil || termPath != nil }

    /// The surface an opening now would show.
    private var usesTerminal: Bool { settings().view == .terminal && termPath != nil }
    /// The web chat: `chatView: chat`, an environment that has one and a page directory that holds every file of the page. An install that
    /// predates the page opens the stream view instead (and says so once per open).
    private var web: ChatWebEnvironment? {
        guard settings().view == .chat, let web = environment.chatWeb else { return nil }
        if web.isInstalled() { return web }
        log("CHAT web-page-missing")
        return nil
    }

    private static func stamp(_ time: TimeInterval) -> String { String(format: "%.6f", time) }

    // MARK: opening and closing

    /// The accepted double-click (clickCount 2): opens the chat, or closes it when it is open. `eventTime` is the event's own time stamp.
    public func toggle(eventTime: TimeInterval) {
        guard isAvailable else { return }
        if live != nil { close(.toggle); return }
        openChat(eventTime: eventTime)
    }

    private func openChat(eventTime: TimeInterval, cause: String? = nil) {
        if !enabled() { log("CHAT refuse reason=\(ChatRefusal.off.rawValue)"); return }
        if let refusal = host.chatRefusal() { log("CHAT refuse reason=\(refusal.rawValue)"); return }
        if host.chatExamBrowserRunning() { log("CHAT refuse reason=\(ChatRefusal.exam.rawValue)"); return }
        // Any open ends the drag probe of a click-close (P12).
        disarmRecall()
        if usesTerminal { openTerminal(eventTime: eventTime); return }
        if let web = self.web { openWeb(eventTime: eventTime, web: web, cause: cause); return }
        guard let rect = host.chatPlacement() else { log("CHAT refuse reason=\(ChatRefusal.noDisplay.rawValue)"); return }
        guard let session = ensureSession() else { return }

        let view = ChatPanelView(height: rect.height)
        let panel = ChatPanel(overFullScreen: host.chatOverFullScreen, gen: generation + 1, view: view)
        panelPrepared?(panel)
        let violations = ChatPanelAudit.violations(of: panel, overFullScreenAllowed: host.chatOverFullScreen)
        if let first = violations.first {
            log("CHAT contract-violation \(first)")
            return
        }
        // An open right-click menu closes before the chat opens (it cannot be open here: a double-click with the menu open only closes it).
        host.chatCloseMenu()
        generation += 1
        wire(panel, surface: view)
        view.onClose = { [weak self] in self?.close(.button) }
        view.inputText = draft
        view.setConversation(session.transcript.entries, turn: session.turn)
        panel.setFrame(rect, display: false)
        live = Opening(gen: generation, panel: panel, terminal: false)
        timer.cancel()
        if !editMenuInstalled { environment.chatInstallEditMenu(); editMenuInstalled = true }
        log("CHAT open et=\(Self.stamp(eventTime)) gen=\(generation)")
        let activation = beginActivation(gen: generation, panel: panel, eventTime: eventTime)
        // Present, then make key: both inside this accepted double-click, which is the cause the focus rule asks for.
        handlingAcceptedClick = true
        panel.allowKey()
        environment.present(panel)
        environment.chatMakeKey(panel)
        panel.focusInput()
        requestActivation(activation)
        handlingAcceptedClick = false
        host.chatDidOpen()
    }

    /// What the file gave an opening: the rect inside a screen, and the corner anchor it came from (nil: a version 1 rect that stayed absolute).
    private struct Restored { var rect: CGRect; var anchor: ChatAnchor?; var screen: String? = nil }

    /// The v1 migration and its backup, run at every non-recall open (chat-near-pet R1: its returned rect, anchor and screen reach no open; an open
    /// takes only `savedDimensions()` and Clawd's placement). A version 2 file is resolved against its display, else
    /// Clawd's. A version 1 file is migrated here, at open and nowhere else (Q26): to the present screen its rect overlaps most, once; with no
    /// screen known, a rect on no present screen, or a screen too small to anchor, the file is left as it is and read as absolute, as before.
    private func restoredGeometry() -> Restored? {
        guard let geometry else { return nil }
        if let anchor = geometry.loadAnchor() {
            guard let rect = resolved(anchor) else { return nil }
            return Restored(rect: rect, anchor: anchor, screen: anchor.display)
        }
        guard let saved = geometry.load() else { return nil }
        let absolute = Restored(rect: ChatPanelGeometry.clamp(saved, in: visibleFrame(of: saved)), anchor: nil)
        guard host.chatVisibleFrame() != nil else { log("CHAT panel-geometry migrate=later reason=no-screen"); return absolute }
        guard let screen = ChatPanelGeometry.screen(of: saved, in: screens()) else { log("CHAT panel-geometry migrate=later reason=away"); return absolute }
        let clamped = ChatPanelGeometry.clamp(saved, in: screen.visible)
        guard let anchor = ChatPanelGeometry.anchor(of: clamped, in: screen.visible, display: screen.id) else {
            log("CHAT panel-geometry migrate=later reason=small"); return absolute
        }
        guard geometry.migrate(to: anchor) else { log("CHAT panel-geometry migrate=later reason=write"); return absolute }
        log("CHAT panel-geometry migrated=1")
        return Restored(rect: ChatPanelGeometry.resolve(anchor, in: screen.visible), anchor: anchor, screen: screen.id)
    }

    /// (Called before the placement guard on purpose, as R1 requires the file's dimensions first; FileChatGeometry.read() backs up before it removes, so an
    /// open refused for no display loses nothing, and the next open repeats the same read.)
    /// The width and height the file holds, as it holds them (a version 2 anchor's, else a version 1 rect's), each raised to the minimum; nil when
    /// none is readable. Read before restoredGeometry() resolves or migrates anything, so a smaller display never shrinks what is remembered.
    private func savedDimensions() -> CGSize? {
        guard let geometry else { return nil }
        let size: CGSize
        if let anchor = geometry.loadAnchor() { size = CGSize(width: anchor.width, height: anchor.height) }
        else if let rect = geometry.load() { size = rect.size }
        else { return nil }
        return CGSize(width: max(size.width, ChatPanelGeometry.minSize.width), height: max(size.height, ChatPanelGeometry.minSize.height))
    }

    /// The display an anchor resolves against: the one it names when that is present now, else Clawd's (a removed display keeps the panel's
    /// distance from its nearest corner on the display Clawd is on, Q26).
    /// An anchor committed on an index-built id resolves on that display first, while the displays are as they were (`screen`, `signature`).
    private func targetVisible(_ display: String?, screen: String? = nil, signature kept: String? = nil) -> CGRect? {
        if let named = displayNamed(screen, signature: kept) { return named.visible }
        let all = screens()
        if let display, ChatPanelGeometry.isStableDisplayID(display), let found = all.first(where: { $0.id == display }) { return found.visible }
        return host.chatVisibleFrame() ?? all.first?.visible
    }

    private func resolved(_ anchor: ChatAnchor, screen: String? = nil, signature kept: String? = nil) -> CGRect? {
        targetVisible(anchor.display, screen: screen, signature: kept).map { ChatPanelGeometry.resolve(anchor, in: $0) }
    }

    private func resolved(_ opening: Opening) -> CGRect? {
        opening.anchor.flatMap { resolved($0, screen: opening.anchorScreen, signature: opening.anchorSignature) }
    }

    /// The displays as one string; an id built from an index means the same display only while this string stays the same.
    private func signature() -> String {
        screens().map { "\($0.id)|\($0.frame.minX),\($0.frame.minY),\($0.frame.width),\($0.frame.height)" }.joined(separator: ";")
    }

    /// The signature to keep with `id` when it is an index-built id, else nil (a UUID names its display for good).
    private func signature(for id: String?) -> String? {
        guard let id, !ChatPanelGeometry.isStableDisplayID(id) else { return nil }
        return signature()
    }

    /// The display `id` names now: a UUID by lookup; an index-built id only while the displays are as they were when it was taken.
    private func displayNamed(_ id: String?, signature kept: String?) -> ChatScreen? {
        guard let id else { return nil }
        let all = screens()
        if ChatPanelGeometry.isStableDisplayID(id) { return all.first { $0.id == id } }
        guard kept == signature() else { return nil }
        return all.first { $0.id == id }
    }

    private func screens() -> [ChatScreen] { host.chatScreens() }

    /// The visible frame of the screen `rect` is mostly on; Clawd's display when it is on none.
    private func visibleFrame(of rect: CGRect) -> CGRect? {
        ChatPanelGeometry.screen(of: rect, in: screens())?.visible ?? host.chatVisibleFrame()
    }

    /// The bridge to Claude Code, built on the first open that needs it.
    private func ensureSession() -> ChatSessionDriving? {
        if session == nil, let make = makeSession, let created = make(ChatSessionConfig(settings: settings, log: log)) { attach(created) }
        return session
    }

    /// The web kind's open: the container's chrome and geometry of the terminal kind, the stream bridge's session, and a body of the page's web
    /// view over the native composer. The page is loaded here and fed once it says `ready`.
    private func openWeb(eventTime: TimeInterval, web: ChatWebEnvironment, cause: String? = nil, recalling: Recall? = nil) {
        // The saved dimensions are read before anything resolves or clamps them; the saved position is never used for an open (R1).
        let placedSize = recalling == nil ? savedDimensions() : nil
        guard var rect = host.chatTerminalPlacement(size: placedSize) else { log("CHAT refuse reason=\(ChatRefusal.noDisplay.rawValue)"); return }
        guard let session = ensureSession() else { return }
        if recalling == nil { _ = restoredGeometry() }
        rect = recalling.map { recalledFrame($0) } ?? rect
        let bounds = CGRect(origin: .zero, size: rect.size)
        let page = ChatWebPage(environment: web, log: log)
        let body = ChatWebBody(page: page, environment: web, frame: CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - ChatTerminalContainer.headerHeight)))
        let container = ChatTerminalContainer(frame: bounds, body: body)
        let panel = ChatPanel(overFullScreen: host.chatOverFullScreen, gen: generation + 1, view: ChatPanel.placeholderView, terminal: container)
        panelPrepared?(panel)
        let violations = ChatPanelAudit.violations(of: panel, overFullScreenAllowed: host.chatOverFullScreen)
        if let first = violations.first {
            log("CHAT contract-violation \(first)")
            body.teardown()
            return
        }
        host.chatCloseMenu()
        generation += 1
        panel.onCloseShortcut = { [weak self] in self?.close(.shortcut) }
        container.onClose = { [weak self] in self?.close(.button) }
        container.onGesture = { [weak self] in self?.gesture($0) }
        wire(panel, surface: body)
        page.onGaveUp = { [weak self] in self?.live?.panel.surface.setStatus("The chat page stopped working: close and open the chat again") }
        body.inputText = draft
        body.setDraftWarning(composerStore?.saveFailed == true)
        composerStore?.recheckChips()
        body.composer.syncChips(composerStore?.content.chips ?? [])
        body.composer.onChipsChanged = { [weak self] chips in self?.composerStore?.setChips(chips) }
        body.inputView.onHistory = { [weak self] key in self?.recall(key) ?? false }
        body.onResumeListWanted = { [weak self] in self?.resumeListWanted() }
        body.onResumeListClosed = { [weak self] in self?.resumeListClosed() }
        body.onResumePick = { [weak self] row in self?.resumePicked(row) }
        body.setCatalog(catalog.pickerEntries)
        body.setQueue(queue.rows, pauseText: queue.pauseRowText)
        body.queueList.onSteer = { [weak self] id in self?.sendNow(id) }
        body.queueList.onDelete = { [weak self] id in self?.deleteCard(id) }
        body.queueList.onEdit = { [weak self] id in self?.editCard(id) }
        body.queueList.onResume = { [weak self] in self?.resumeQueue() }
        body.inputView.onSteerChord = { [weak self] in self?.steerChord() ?? false }
        body.onDraftChanged = { [weak self] in self?.draftEdited() }
        body.setConversation(session.transcript.entries, turn: session.turn)
        panel.setFrame(rect, display: false)
        let opening = Opening(gen: generation, panel: panel, terminal: true, web: body)
        opening.placedSize = placedSize
        if let recalling {
            opening.placedSize = recalling.placedSize
            // The panel as the click left it: frame, maximize state and the way back from it.
            opening.anchor = recalling.anchor
            opening.anchorScreen = recalling.anchorScreen
            opening.anchorSignature = recalling.anchorSignature
            opening.maximizedSignature = recalling.maximizedSignature
            opening.custom = recalling.custom
            opening.maximized = recalling.maximized
            opening.restoreRect = recalling.restoreRect
            opening.customBeforeMaximize = recalling.customBeforeMaximize
            opening.maximizedScreen = recalling.maximizedScreen
            if staleIndexScreen(recalling.maximizedScreen, recalling.maximizedSignature) { opening.maximizedScreen = nil; opening.maximizedSignature = nil }
            opening.recalled = true
            panel.terminal?.setMaximized(recalling.maximized)
        } else {
            applyPersistedMaximize(opening)
        }
        live = opening
        timer.cancel()
        if !editMenuInstalled { environment.chatInstallEditMenu(); editMenuInstalled = true }
        wireAttachments(opening, body: body, page: page, web: web)
        if let recalling {
            // A recall presents the panel and nothing else: no key right, no make-key, no activation request and no token. Clawd is not
            // activated and the keyboard stays where it was.
            log("CHAT recall gen=\(generation) from=\(recalling.gen)")
            recalling.recalledGen = generation
            _ = beginActivation(gen: generation, panel: panel, eventTime: eventTime)
            environment.present(panel)
            page.load()
            beginRecallEnd(recalling)
            host.chatDidOpen()
            return
        }
        log("CHAT open et=\(Self.stamp(eventTime)) gen=\(generation)\(cause.map { " cause=\($0)" } ?? "")")
        let activation = beginActivation(gen: generation, panel: panel, eventTime: eventTime)
        handlingAcceptedClick = true
        panel.allowKey()
        environment.present(panel)
        environment.chatMakeKey(panel)
        panel.focusInput()
        requestActivation(activation)
        page.load()
        handlingAcceptedClick = false
        host.chatDidOpen()
        ChatAttachmentSession.sweepStorage(web.attach)
    }

    /// The terminal path's open: the same prerequisites and the same cause as the stream path's, a panel whose content is the terminal.
    private func openTerminal(eventTime: TimeInterval) {
        guard let termPath else { return }
        // Beside Clawd at the size the user left last time, else at the default size (R1).
        let placedSize = savedDimensions()
        guard let rect = host.chatTerminalPlacement(size: placedSize) else { log("CHAT refuse reason=\(ChatRefusal.noDisplay.rawValue)"); return }
        _ = restoredGeometry()
        let bounds = CGRect(origin: .zero, size: rect.size)
        let terminalView = termPath.viewForOpening(frame: CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - ChatTerminalContainer.headerHeight)))
        let container = ChatTerminalContainer(frame: bounds, view: terminalView)
        let panel = ChatPanel(overFullScreen: host.chatOverFullScreen, gen: generation + 1, view: ChatPanel.placeholderView, terminal: container)
        panelPrepared?(panel)
        let violations = ChatPanelAudit.violations(of: panel, overFullScreenAllowed: host.chatOverFullScreen)
        if let first = violations.first {
            log("CHAT contract-violation \(first)")
            terminalView.removeFromSuperview()
            return
        }
        host.chatCloseMenu()
        generation += 1
        panel.onCloseShortcut = { [weak self] in self?.close(.shortcut) }
        container.onClose = { [weak self] in self?.close(.button) }
        container.onGesture = { [weak self] in self?.gesture($0) }
        panel.setFrame(rect, display: false)
        let opening = Opening(gen: generation, panel: panel, terminal: true)
        opening.placedSize = placedSize
        applyPersistedMaximize(opening)
        live = opening
        timer.cancel()
        if !editMenuInstalled { environment.chatInstallEditMenu(); editMenuInstalled = true }
        log("CHAT open et=\(Self.stamp(eventTime)) gen=\(generation)")
        let activation = beginActivation(gen: generation, panel: panel, eventTime: eventTime)
        handlingAcceptedClick = true
        panel.allowKey()
        environment.present(panel)
        environment.chatMakeKey(panel)
        panel.focusInput()
        requestActivation(activation)
        termPath.noteGeneration(generation)
        termPath.opened(gen: generation, container: container, size: bounds.size)
        handlingAcceptedClick = false
        host.chatDidOpen()
    }

    /// The panel was left maximized: it opens maximized on Clawd's display (the saved display is not used, R4), and Restore returns to the
    /// placement beside Clawd as it is then (R4b). Nothing happens when no screen is known.
    private func applyPersistedMaximize(_ opening: Opening) {
        guard geometry?.loadMaximized() == true else { return }
        let panel = opening.panel
        let base = panel.frame
        let screen = ChatPanelGeometry.screen(of: base, in: screens())
        let id = screen?.id
        opening.restoreRect = base
        opening.maximizedScreen = id
        opening.maximizedSignature = signature(for: id)
        guard let visible = maximizedVisible(of: opening) else { opening.restoreRect = nil; opening.maximizedScreen = nil; opening.maximizedSignature = nil; return }
        opening.customBeforeMaximize = false
        opening.maximized = true
        opening.custom = true
        panel.setFrame(ChatPanelGeometry.maximized(in: visible), display: false)
        panel.terminal?.setMaximized(true)
    }

    private func wire(_ panel: ChatPanel, surface: ChatPanelSurface) {
        panel.onEscape = { [weak self] in self?.escape() }
        surface.inputView.onEscape = { [weak self] in self?.escape() }
        surface.inputView.onOverCap = { [weak self] in self?.live?.panel.surface.setStatus("Not inserted: the message would be over 1 MiB") }
        surface.onSend = { [weak self] in self?.sendFromPanel() }
        surface.onStop = { [weak self] in self?.stopPressed() }
    }

    /// Esc. While an input method is composing it never gets here (the input leaves it to the input method).
    /// On the web chat kind Esc never closes: while a turn runs it interrupts it, otherwise it does nothing (the window closes by Cmd+W, the close
    /// control or a click elsewhere). The stream kind keeps Esc as close.
    /// The picker is the first thing Esc closes. The page's link popover is the next layer: when its last `layer` said open, the page
    /// is asked to close it. A page that answers false, or does not answer in 300 ms, has no layer: the flag is cleared and this same Esc interrupts.
    private func escape() {
        guard let opening = live, opening.web != nil else { close(.esc); return }
        // Q11, Orca's order (NC/use-native-chat-composer-keydown.ts:61-101): the `/` picker first, then the image preview, then the layer.
        if let body = opening.web, body.isPickerOpen { body.dismissPicker(); return }
        if let body = opening.web, body.isPreviewOpen { body.closePreview(); return }
        guard let page = opening.web?.page, page.layerOpen else { interruptRunningTurn(); return }
        let gen = opening.gen
        let settled = EscapeAnswer()
        let timer = focus.deadlines.after(Self.layerAnswerWindow) { [weak self, weak page] in
            guard !settled.done else { return }
            settled.done = true
            page?.clearLayerFlag()
            if self?.live?.gen == gen { self?.interruptRunningTurn() }
        }
        page.dismissLayer { [weak self, weak page] closed in
            guard !settled.done else { return }
            settled.done = true
            timer.cancel()
            guard !closed else { return }
            page?.clearLayerFlag()
            if self?.live?.gen == gen { self?.interruptRunningTurn() }
        }
    }
    /// How long Esc waits for the page to say it closed its layer.
    public static let layerAnswerWindow: TimeInterval = 0.3
    private final class EscapeAnswer { var done = false }

    private func interruptRunningTurn() {
        if session?.turn == .running { pauseQueue(.stopped); session?.interrupt() }
    }

    /// The Stop control: a running turn is interrupted, and the queue pauses with `stopped` (a Stop never withdraws a card, Orca queued-stop.ts:1-7).
    private func stopPressed() {
        guard let session else { return }
        if session.turn == .running { pauseQueue(.stopped) }
        session.interrupt()
    }

    /// Closes the open panel (a no-op when none is open). The close ends the key right first, then orders the window out.
    public func close(_ reason: ChatCloseReason) {
        // An exam, hiding or `chat` off ends the drag probe even when no panel is up.
        if reason == .exam || reason == .hidden || reason == .off { disarmRecall() }
        guard let opening = live else { return }
        live = nil
        // A recalled panel that goes (whatever closes it) ends the recall: no second recall comes of the same click-close.
        if opening.recalled { disarmRecall() }
        // The picker comes down first and the opening's attachments stop: a late completion or a running copy gets nowhere.
        opening.picker?.cancel(); opening.picker = nil
        opening.attach?.cancel()
        opening.linkStatusDeadline?.cancel(); opening.linkStatusDeadline = nil
        let byClick = reason == .outside && act?.clickedElsewhere == true
        // An outside close says what closed it: a bundle identifier or a file name, never chat text or a path (F6).
        let by = reason == .outside ? act?.closeBy.map { " by=\($0)" } ?? " by=unknown" : ""
        if opening.usesSession {
            draft = opening.panel.surface.inputText
            composerStore?.setDraft(draft); composerStore?.flush()
            log("CHAT close reason=\(reason.rawValue) gen=\(opening.gen) draft=\(draft.count)\(by)")
            // What the reader saw outlives the page: the latest view the page reported is kept in memory (ids and counts, no text).
            if opening.web != nil {
                if let latest = opening.latestView { savedView = latest }
                if let kept = savedView { log("CHAT view saved following=\(kept.following ? 1 : 0) sel=\(kept.sel != nil ? 1 : 0)") }
            }
            // The page's handler, load and view go before the panel does (R2): one web view per opening, none left behind.
            resumeListClosed()
            opening.web?.teardown()
        } else {
            // One line with the counts of the opening and the child (T-4); the view leaves the panel, so nothing draws it.
            termPath?.closed(reason: reason.rawValue, gen: opening.gen, suffix: by)
        }
        opening.panel.disallowKey()
        environment.dismiss(opening.panel)
        endActivation(reason)
        host.chatDidClose(render: reason != .hidden && reason != .contract)
        if opening.usesSession { armIdleStop() }
        // A plain click elsewhere closed it: for the next 30 s a file drag brings it back (D3b). Any other close, and a recall's own end, does not.
        if byClick, opening.web != nil, !opening.recalled { armRecall(from: opening) }
    }

    public func closeForDrag() { close(.drag) }
    public func closeForHidden() { close(.hidden) }
    public func closeForMenu() { close(.menu) }

    /// The windows were re-measured (a display change, a setting, a walk's end): only the frame changes, and the panel is never made key here.
    /// While the user holds the panel with the mouse (a move or a resize), the pet's own frames leave it alone.
    public func replace() {
        guard let opening = live, opening.gestureStart == nil else { return }
        let rect: CGRect
        if opening.terminal, opening.maximized, let visible = maximizedVisible(of: opening) {
            rect = ChatPanelGeometry.maximized(in: visible)
        } else if opening.terminal, opening.custom {
            // Orca re-resolves the committed bounds on every viewport change (use-floating-terminal-panel-geometry.ts:81-103): the anchor, not a
            // clamp of the current frame. With no anchor, today's clamp.
            rect = resolved(opening) ?? ChatPanelGeometry.clamp(opening.panel.frame, in: visibleFrame(of: opening.panel.frame))
        } else if let placed = opening.terminal ? host.chatTerminalPlacement(size: opening.placedSize) : host.chatPlacement() {
            rect = placed
        } else { return }
        if opening.panel.frame != rect { opening.panel.setFrame(rect, display: false) }
    }

    /// The screen a maximized panel fills: the one it was maximized on; if that is gone, the one its restore rect is on, else Clawd's.
    private func maximizedVisible(of opening: Opening) -> CGRect? {
        // An index-built id that missed once never matches again (Q20): clear it on the first mismatch.
        if staleIndexScreen(opening.maximizedScreen, opening.maximizedSignature) { opening.maximizedScreen = nil; opening.maximizedSignature = nil }
        return maximizedVisible(screen: opening.maximizedScreen, signature: opening.maximizedSignature, restoreRect: opening.restoreRect)
    }

    /// Whether `id` is index-built and the displays are no longer as they were when it was taken.
    private func staleIndexScreen(_ id: String?, _ kept: String?) -> Bool {
        guard let id, !ChatPanelGeometry.isStableDisplayID(id) else { return false }
        return kept != signature()
    }

    private func maximizedVisible(screen id: String?, signature kept: String?, restoreRect: CGRect?) -> CGRect? {
        if let named = displayNamed(id, signature: kept) { return named.visible }
        if let back = restoreRect, let screen = ChatPanelGeometry.screen(of: back, in: screens()) { return screen.visible }
        return host.chatVisibleFrame()
    }

    /// A recalled panel's frame (Q20 a): clamped like a restored rect. A maximized one fills its screen looked up now, else its restore rect's; one
    /// with a committed anchor resolves it.
    private func recalledFrame(_ recall: Recall) -> CGRect {
        if recall.maximized, let visible = maximizedVisible(screen: recall.maximizedScreen, signature: recall.maximizedSignature, restoreRect: recall.restoreRect) {
            return ChatPanelGeometry.maximized(in: visible)
        }
        if recall.custom, let anchor = recall.anchor, let rect = resolved(anchor, screen: recall.anchorScreen, signature: recall.anchorSignature) { return rect }
        return ChatPanelGeometry.clamp(recall.frame, in: visibleFrame(of: recall.frame))
    }

    // MARK: the panel's own geometry (v3-orca-look r2)

    /// The user's mouse work on the terminal panel's chrome: a drag of the title bar moves it, a drag of an edge or corner resizes it, the
    /// maximize control or a double-click on the bar toggles maximize. The result stays inside the visible frame, the terminal's grid follows the
    /// new size by itself, and the size and position are remembered when the gesture ends.
    public func gesture(_ gesture: ChatPanelGesture) {
        guard let opening = live, opening.terminal else { return }
        let panel = opening.panel
        switch gesture {
        case .begin:
            opening.gestureStart = opening.maximized ? nil : panel.frame
            opening.gestureKind = nil
            if !opening.maximized {
                // The panel is the user's from the first press: a pet frame between two steps of the drag cannot move it (replace()).
                opening.customBeforeGesture = opening.custom
                opening.custom = true
                opening.gestureVisible = visibleFrame(of: panel.frame)
            }
            // The grid, and with it the child's window size, changes once, when the gesture ends: not at every step of the drag.
            panel.terminal?.holdGrid(true)
        case .move(let dx, let dy, let pointer):
            guard let start = opening.gestureStart else { return }
            opening.gestureKind = "move"
            // The pointer decides the display: the panel follows it onto another one, and stops at the margin while the pointer stays on its own.
            let visible = pointer.flatMap { ChatPanelGeometry.screen(at: $0, in: screens())?.visible } ?? opening.gestureVisible
            panel.setFrame(ChatPanelGeometry.moved(start, dx: dx, dy: dy, in: visible), display: true)
        case .resize(let edge, let dx, let dy):
            guard let start = opening.gestureStart else { return }
            opening.gestureKind = "resize"
            panel.setFrame(ChatPanelGeometry.resized(start, edge: edge, dx: dx, dy: dy, in: opening.gestureVisible), display: true)
        case .end:
            panel.terminal?.holdGrid(false)
            guard let start = opening.gestureStart else { return }
            opening.gestureStart = nil
            let kind = opening.gestureKind ?? "move"
            opening.gestureKind = nil
            guard panel.frame != start else { opening.custom = opening.customBeforeGesture; return }
            // A display may have changed under the gesture (replace() is skipped while it runs): the frame is clamped to the screens as they are
            // now before anything is saved (Q20 d).
            let inside = ChatPanelGeometry.clamp(panel.frame, in: visibleFrame(of: panel.frame))
            if inside != panel.frame { panel.setFrame(inside, display: true) }
            commitAnchor(opening)
            logGesture("\(kind)-end", opening, anchor: opening.anchor)
        case .toggleMaximize:
            panel.terminal?.holdGrid(false)
            if opening.maximized {
                // A panel that still followed Clawd before the maximize goes back beside Clawd as it is now (R4b). Otherwise the committed anchor
                // resolved now; only a panel with none returns to its restore rect, clamped to the screens as they are (Q20, Q26).
                if !opening.customBeforeMaximize, let rect = host.chatTerminalPlacement(size: opening.placedSize) {
                    panel.setFrame(rect, display: true)
                } else if let rect = resolved(opening) {
                    panel.setFrame(rect, display: true)
                } else if let back = opening.restoreRect {
                    panel.setFrame(ChatPanelGeometry.clamp(back, in: visibleFrame(of: back)), display: true)
                }
                opening.restoreRect = nil
                opening.maximized = false
                opening.maximizedScreen = nil
                opening.maximizedSignature = nil
                opening.custom = opening.customBeforeMaximize
            } else {
                let screen = ChatPanelGeometry.screen(of: panel.frame, in: screens())
                guard let visible = screen?.visible ?? host.chatVisibleFrame() else { return }
                opening.restoreRect = panel.frame
                opening.customBeforeMaximize = opening.custom
                opening.maximized = true
                opening.maximizedScreen = screen?.id
                opening.maximizedSignature = signature(for: screen?.id)
                opening.custom = true
                panel.setFrame(ChatPanelGeometry.maximized(in: visible), display: true)
            }
            if geometry?.saveMaximized(opening.maximized) == false { log("CHAT panel-geometry save=failed what=maximized") }
            panel.terminal?.setMaximized(opening.maximized)
            logGesture(opening.maximized ? "maximize" : "restore", opening)
        }
    }

    /// The gesture's end commits the panel's place as a corner anchor of the display it is mostly on (FT/floating-terminal-panel-drag-actions.ts:59-68,
    /// use-floating-terminal-panel-geometry.ts:62-79). A display too small to anchor on saves nothing and clears the opening's anchor, so today's
    /// clamp applies to the frame the user dragged and the next replace() does not pull the panel back to a stale anchor.
    private func commitAnchor(_ opening: Opening) {
        let frame = opening.panel.frame
        let screen = ChatPanelGeometry.screen(of: frame, in: screens())
        guard let visible = screen?.visible ?? host.chatVisibleFrame(),
              let anchor = ChatPanelGeometry.anchor(of: frame, in: visible, display: screen?.id) else { opening.anchor = nil; return }
        opening.anchor = anchor
        opening.anchorScreen = screen?.id
        opening.anchorSignature = signature(for: screen?.id)
        if geometry?.saveAnchor(anchor) == false { log("CHAT panel-geometry save=failed what=anchor") }
    }

    /// `CHAT gesture <what> gen= frame=x,y,w,h [anchor=lt|rt|lb|rb]` in integers and a corner name (a count of points, never chat text).
    private func logGesture(_ what: String, _ opening: Opening, anchor: ChatAnchor? = nil) {
        let f = opening.panel.frame
        log("CHAT gesture \(what) gen=\(opening.gen) frame=\(Int(f.minX.rounded())),\(Int(f.minY.rounded())),\(Int(f.width.rounded())),\(Int(f.height.rounded()))\(anchor.map { " anchor=\($0.corner)" } ?? "")")
    }

    // MARK: attachments (P2, P3, P4, P5, P10)

    /// The web body's file paths: the opening's drop target, the "+" picker, the image paste, the copy button and the tab menu.
    private func wireAttachments(_ opening: Opening, body: ChatWebBody, page: ChatWebPage, web: ChatWebEnvironment) {
        let gen = opening.gen
        let attach = ChatAttachmentSession(gen: gen, body: body, environment: web.attach, nextTurn: { [weak self] block in self?.focus.nextTurn(block) },
                                            after: { [weak self] seconds, block in self?.focus.deadlines.after(seconds, block) }, log: log)
        opening.attach = attach
        // A paste saved after its opening closed still belongs to the draft: its path joins the saved chips (the web body is gone by then).
        attach.storedAfterClose = { [weak self] path in
            guard let self, let store = self.composerStore else { return }
            store.setChips((store.content.chips ?? []) + [ChatComposerChip(path: path)])
            store.flush()
            if let chips = store.content.chips { self.live?.web?.composer.syncChips(chips) }
        }
        body.attachments = attach
        body.onFileDrag = { [weak self] in
            guard let self, self.live?.gen == gen else { return }
            self.fileDragEntered()
            self.recallEntered()
        }
        body.onFileDragEnd = { [weak self] ended in
            guard let self, self.live?.gen == gen else { return }
            self.recallLeft(ended: ended)
        }
        body.onFileDrop = { [weak self] paths, promise in
            guard let self, self.live?.gen == gen else { return }
            self.promoteRecalled()
            self.live?.attach?.dropped(paths: paths, carriedPromise: promise, target: "panel")
        }
        body.composer.onAttach = { [weak self] in self?.attachPressed(gen: gen) }
        body.inputView.imagePaste = { [weak attach] in attach?.pasteImageIfAny() ?? false }
        body.inputView.onCompositionEvent = { [weak attach] in attach?.compositionMayHaveEnded() }
        page.onViewState = { [weak self] state in
            guard let self, let opening = self.live, opening.gen == gen else { return }
            opening.latestView = state
        }
        page.bridge.onSynced = { [weak self] in self?.restoreView(gen: gen) }
        page.onCopyRequest = { [weak self] id in self?.copyEntry(id, gen: gen) }
        page.onCopyCodeRequest = { [weak self] id, index in self?.copyCode(id, index, gen: gen) }
        page.onCopyLinkRequest = { [weak self] url in self?.copyLink(url, gen: gen) }
        let sessionID: () -> String? = { [weak self] in self?.session?.sessionID }
        page.view?.sessionID = sessionID
        page.view?.onMenuCopySessionID = { [weak self] in self?.copySessionID(gen: gen) }
        body.inputView.sessionID = sessionID
        body.inputView.onCopySessionID = { [weak self] in self?.copySessionID(gen: gen) }
        opening.panel.onMouseDown = { [weak self] in self?.promoteRecalled(); self?.clearLinkStatus(gen: gen) }
        opening.panel.onPressOutsideWeb = { [weak self] in
            guard let self, self.live?.gen == gen, let page = self.live?.web?.page, page.layerOpen else { return }
            page.dismissLayer { _ in }
        }
        opening.panel.terminal?.onTabMenuClose = { [weak self] in
            guard let self, self.live?.gen == gen else { return }
            self.log("CHAT tab-menu close gen=\(gen)")
            self.close(.button)
        }
    }

    /// After the page shows the conversation for the first time in an opening: the view the reader left (this opening's latest, else the one the
    /// last close kept) goes back, or nothing does and the page only starts reporting (Q18).
    private func restoreView(gen: Int) {
        guard let opening = live, opening.gen == gen, let page = opening.web?.page else { return }
        let state = opening.latestView ?? savedView
        page.restoreView(state) { [weak self] answer in
            guard let self, let state, let answer, ["found", "next", "none"].contains(answer) else { return }
            self.log("CHAT view restored anchor=\(answer) following=\(state.following ? 1 : 0)")
        }
    }

    /// The "+" control (Orca's "Attach file"): one picker at a time, above the chat, non-modal. Its file goes through the drop's rules.
    private func attachPressed(gen: Int) {
        guard let opening = live, opening.gen == gen, opening.picker == nil, let attach = opening.attach, !attach.isLocked,
              let web = environment.chatWeb else { return }
        log("CHAT picker gen=\(gen) open")
        var finished = false
        opening.pickerPresenting = true
        defer { opening.pickerPresenting = false }
        let handle = web.attach.picker().present { [weak self] path in
            finished = true
            guard let self, let current = self.live, current.gen == gen else { return }
            current.picker = nil
            guard let path else { self.log("CHAT picker gen=\(gen) cancelled"); return }
            current.attach?.dropped(paths: [path], carriedPromise: false, target: "panel")
        }
        if !finished { opening.picker = handle }
    }

    /// Whether `window` is the picker that is up for `opening`, or a window (a sheet) whose parent chain reaches it.
    private func isPickerWindow(_ window: NSWindow, of opening: Opening) -> Bool {
        guard let picker = opening.picker?.window else { return false }
        var cursor: NSWindow? = window
        var steps = 0
        while let current = cursor, steps < 16 {
            if current === picker { return true }
            cursor = current.sheetParent
            steps += 1
        }
        return false
    }

    /// The message copy button (P10): only for a known entry and only within a second of the panel's own left mouse-down, so a script in the page
    /// cannot write the pasteboard without a click. The page shows its check only when the write worked.
    private func copyEntry(_ id: Int, gen: Int) {
        guard let opening = live, opening.gen == gen, let session, let web = environment.chatWeb, let page = opening.web?.page else { return }
        let now = clock.now
        guard let click = opening.panel.lastLeftMouseDown, click <= now, now - click <= Self.copyClickWindow else { return }
        // Only the entries that show a button (Q22): a user or assistant entry with text.
        guard let entry = session.transcript.entries.first(where: { $0.id == id }), entry.kind == .user || entry.kind == .assistant, !entry.text.isEmpty else { return }
        guard let whole = ChatWebPage.clipboardText(entry.text) else { opening.panel.surface.setStatus(ChatWebPage.copyRefusedStatus); return }
        guard web.pasteboard.putString(whole) else { return }
        page.copied(id)
    }
    /// Whether the panel's own left mouse-down was within `copyClickWindow` of now: a script in the page cannot write the pasteboard without a click.
    private func recentClick(_ opening: Opening) -> Bool {
        let now = clock.now
        guard let click = opening.panel.lastLeftMouseDown, click <= now, now - click <= Self.copyClickWindow else { return false }
        return true
    }

    /// Copy code on a fence (Q1): only for a user or assistant entry with text, after the panel's own click. The text is pulled from the page by a
    /// constant function body and written under D5.
    private func copyCode(_ id: Int, _ index: Int, gen: Int) {
        guard let opening = live, opening.gen == gen, let session, let page = opening.web?.page, recentClick(opening),
              let entry = session.transcript.entries.first(where: { $0.id == id }),
              entry.kind == .user || entry.kind == .assistant, !entry.text.isEmpty else { return }
        page.codeText(id: id, index: index) { [weak self] text in
            guard let self, let current = self.live, current.gen == gen, let text, !text.isEmpty, let web = self.environment.chatWeb else { return }
            guard let whole = ChatWebPage.clipboardText(text) else { current.panel.surface.setStatus(ChatWebPage.copyRefusedStatus); return }
            guard web.pasteboard.putString(whole) else { return }
            page.codeCopied(id, index)
        }
    }

    /// Copy link in the popover (Q5): only while the popover is open, after the panel's own click, and only for the string `ChatWebLink.openable`
    /// parsed as it is: a string that the parser rewrites (whitespace, a newline) writes nothing.
    private func copyLink(_ url: String, gen: Int) {
        guard let opening = live, opening.gen == gen, let page = opening.web?.page, let web = environment.chatWeb, recentClick(opening), page.layerOpen,
              let parsed = ChatWebLink.openable(url), parsed.absoluteString == url else { return }
        guard let whole = ChatWebPage.clipboardText(url) else { showLinkStatus(opening, ChatWebPage.copyRefusedStatus); return }
        guard web.pasteboard.putString(whole) else { showLinkStatus(opening, "Failed to copy link"); return }
        page.linkCopied()
        showLinkStatus(opening, "Copied link")
    }

    /// The right-click menu's Copy Session ID (Q19): the Claude Code conversation id, with the status line saying so.
    private func copySessionID(gen: Int) {
        guard let opening = live, opening.gen == gen, let id = session?.sessionID, !id.isEmpty, let web = environment.chatWeb else { return }
        showLinkStatus(opening, web.pasteboard.putString(id) ? "Session ID copied" : "Unable to copy session ID")
    }

    /// The popover's status line lasts `linkStatusSeconds` or until the next press in the panel, as Orca's toast does.
    private func showLinkStatus(_ opening: Opening, _ text: String) {
        opening.panel.surface.setStatus(text)
        opening.linkStatus = text
        opening.linkStatusDeadline?.cancel()
        let gen = opening.gen
        opening.linkStatusDeadline = focus.deadlines.after(Self.linkStatusSeconds) { [weak self] in self?.clearLinkStatus(gen: gen) }
    }

    /// Clears the popover's status line when it is still the one showing (a newer line is left alone).
    private func clearLinkStatus(gen: Int) {
        guard let opening = live, opening.gen == gen, let shown = opening.linkStatus else { return }
        opening.linkStatusDeadline?.cancel(); opening.linkStatusDeadline = nil
        opening.linkStatus = nil
        if opening.panel.surface.statusText == shown { opening.panel.surface.setStatus("") }
    }

    public static let linkStatusSeconds: TimeInterval = 3

    /// How soon after the panel's last left mouse-down a page's `copy` counts as that click's (S7).
    public static let copyClickWindow: TimeInterval = 1

    /// The sweeps of the drop copies and the pasted images (S5): at agent start; each open runs them too.
    public func sweepStorage() {
        if let web = environment.chatWeb { ChatAttachmentSession.sweepStorage(web.attach) }
    }

    // MARK: a file dropped on Clawd's body (P11)

    /// Whether the web chat could open now: `chat` on, the web kind installed, nothing refusing it and no exam browser.
    private var webCouldOpen: Bool {
        guard enabled(), settings().view == .chat, environment.chatWeb?.isInstalled() == true else { return false }
        return host.chatRefusal() == nil && !host.chatExamBrowserRunning()
    }

    /// Why Clawd's body takes no file drop now (nil: it takes one). The word is the `reason=` of the `CHAT pet-drop refused` line.
    public func petDropRefusal() -> String? {
        if !enabled() { return ChatRefusal.off.rawValue }
        if settings().view != .chat || environment.chatWeb?.isInstalled() != true { return "view" }
        if let refusal = host.chatRefusal() { return refusal.rawValue }
        if host.chatExamBrowserRunning() { return ChatRefusal.exam.rawValue }
        return nil
    }

    /// The drop on Clawd's body: opens the chat as a double-click would (never toggling an open one closed) and inserts the paths.
    public func petDrop(paths: [String], carriedPromise: Bool, eventTime: TimeInterval) {
        guard petDropRefusal() == nil else { return }
        if live == nil { openChat(eventTime: eventTime, cause: "drop") }
        guard live != nil else { return }
        promoteRecalled()
        live?.attach?.dropped(paths: paths, carriedPromise: carriedPromise, target: "pet")
    }

    // MARK: a click-closed chat comes back for a file drag (P12)

    /// A decided click closed the panel: for 30 s the drag probe watches for a file drag (D3b).
    private func armRecall(from opening: Opening) {
        disarmRecall()
        let armed = Recall(opening: opening, changeCount: focus.dragPasteboard().changeCount)
        armed.probe = focus.observeDragProbe { [weak self, weak armed] event in
            guard let self, let armed, self.recall === armed else { return }
            self.probeEvent(armed, event)
        }
        armed.probeDeadline = focus.deadlines.after(Self.recallWindow) { [weak self, weak armed] in
            guard let self, let armed, self.recall === armed else { return }
            armed.probeDeadline = nil
            // The deadline only gates the start: a recall in progress runs until its drag ends.
            if let gen = armed.recalledGen, self.live?.gen == gen, self.live?.recalled == true { return }
            self.disarmRecall()
        }
        recall = armed
    }

    /// Removes the probe and every deadline of the recall.
    private func disarmRecall() {
        recall?.cancelAll()
        recall = nil
    }

    private func probeEvent(_ armed: Recall, _ event: ChatDragProbeEvent) {
        switch event.kind {
        case .dragged:
            if live == nil { tryRecall(armed, at: event.time) } else { recalledPanelMoved(armed) }
        case .up:
            guard let opening = live, opening.recalled, armed.recalledGen == opening.gen else {
                // No recall is live: only a drag that starts after this release counts (a finished drag leaves its change count and files behind).
                armed.changeCount = focus.dragPasteboard().changeCount
                return
            }
            // The drag ended and nothing was dropped on the recalled panel: it goes again, its draft kept. The up reaches the probe before the drop
            // reaches the body, so a drag that is inside the body gets a short grace for its drop (or its end) first.
            guard armed.inside else { endRecall(); return }
            armed.upDeadline?.cancel()
            armed.upDeadline = focus.deadlines.after(Self.recallDropGrace) { [weak self, weak armed] in
                guard let self, let armed, self.recall === armed else { return }
                armed.upDeadline = nil
                self.endRecall()
            }
        }
    }

    private func tryRecall(_ armed: Recall, at time: TimeInterval) {
        guard time - armed.lastRead >= Self.recallReadInterval else { return }
        armed.lastRead = time
        guard near(armed), webCouldOpen else { return }
        let drag = focus.dragPasteboard()
        guard drag.changeCount != armed.changeCount, drag.hasFileURLs, let web = self.web else { return }
        openWeb(eventTime: clock.now, web: web, recalling: armed)
    }

    /// The drag pointer is within 120 pt of the closed panel (a maximized one: of its edge region, whose nearest edge is where the composer is
    /// reached from) or of Clawd's body on the same display.
    private func near(_ armed: Recall) -> Bool {
        let point = focus.pointerLocation()
        let closed = armed.maximized ? ChatPanelGeometry.distanceToEdge(from: point, to: armed.frame) : ChatPanelGeometry.distance(from: point, to: armed.frame)
        if closed <= Self.recallDistance { return true }
        guard let pet = host.chatPetBodyFrame(), ChatPanelGeometry.distance(from: point, to: pet) <= Self.recallDistance else { return false }
        let all = screens()
        return ChatPanelGeometry.screen(at: point, in: all)?.id == ChatPanelGeometry.screen(at: CGPoint(x: pet.midX, y: pet.midY), in: all)?.id
    }

    /// A recalled panel the pointer has left by more than 120 pt goes again.
    private func recalledPanelMoved(_ armed: Recall) {
        guard let opening = live, opening.recalled, armed.recalledGen == opening.gen else { return }
        if ChatPanelGeometry.distance(from: focus.pointerLocation(), to: opening.panel.frame) > Self.recallDistance { endRecall() }
    }

    /// The recall's two deadlines: the drag must enter the panel within 3 s, and the left button is looked at every 10 s in case the drag's end
    /// was never seen.
    private func beginRecallEnd(_ armed: Recall) {
        armed.entered = false
        armed.entryDeadline = focus.deadlines.after(Self.recallEntry) { [weak self, weak armed] in
            guard let self, let armed, self.recall === armed, !armed.entered, let opening = self.live, opening.recalled else { return }
            self.endRecall()
        }
        scheduleRecallCheck(armed)
    }

    private func scheduleRecallCheck(_ armed: Recall) {
        armed.checkDeadline = focus.deadlines.after(Self.recallCheck) { [weak self, weak armed] in
            guard let self, let armed, self.recall === armed, let opening = self.live, opening.recalled else { return }
            if self.focus.pressedButtons() & ChatPressButton.left.bit != 0 { self.scheduleRecallCheck(armed) } else { self.endRecall() }
        }
    }

    /// The drag entered the recalled panel: the 3 s entry deadline is met.
    private func recallEntered() {
        guard let armed = recall, let opening = live, opening.recalled, armed.recalledGen == opening.gen else { return }
        armed.entered = true
        armed.inside = true
        armed.entryDeadline?.cancel(); armed.entryDeadline = nil
    }

    /// The drag left the recalled body (`exited`), or the drag ended there without a perform (`ended`, which a perform would have promoted first).
    /// After the global mouse-up an exit ends the recall at once, and so does an end; before it only the end of the drag does.
    private func recallLeft(ended: Bool) {
        guard let armed = recall, let opening = live, opening.recalled, armed.recalledGen == opening.gen else { return }
        armed.inside = false
        if ended || armed.upDeadline != nil { endRecall() }
    }

    private func endRecall() {
        guard live?.recalled == true else { return }
        disarmRecall()
        close(.recall)
    }

    /// The user's own drop or press on a recalled panel gives it its key right and nothing else (Clawd makes no window key): key then comes only
    /// from the user's click, through `keyVerdict`'s ordinary cause. The probe goes.
    private func promoteRecalled() {
        guard let opening = live, opening.recalled else { return }
        opening.recalled = false
        opening.panel.allowKey()
        disarmRecall()
        log("CHAT recall-promoted gen=\(opening.gen)")
    }

    // MARK: the session

    private func attach(_ new: ChatSessionDriving) {
        session = new
        new.onChange = { [weak self] in self?.sessionChanged() }
        new.onSendSettled = { [weak self] verdict in self?.sendSettled(verdict) }
        new.onChildLost = { [weak self] loss in self?.childLost(loss) }
        new.onConversationCleared = { [weak self] in
            // The old view belongs to the old conversation: the next open pins to the end of the new one (Q18, recheck N8).
            self?.savedView = nil
            self?.live?.latestView = nil
            self?.pauseQueue(.cleared)
        }
        new.onCatalog = { [weak self] frame in self?.catalogReported(frame) }
        new.onTurnStarted = { [weak self] in
            guard let self else { return }
            self.timer.cancel()
            self.host.chatTurnStarted()
            self.sessionChanged()
        }
        new.onTurnEnded = { [weak self] outcome in
            guard let self else { return }
            self.host.chatTurnEnded(outcome)
            self.sessionChanged()
            self.armIdleStop()
            self.afterTurnEnd()
        }
    }

    private func sessionChanged() {
        if let session, session.turn == .none, steerAfterStop != nil || queue.nextSendable != nil { afterTurnEnd() }
        guard let opening = live, opening.usesSession, let session else { return }
        opening.panel.surface.setConversation(session.transcript.entries, turn: session.turn)
    }

    /// The folder the chat runs in is the home folder (the `chatFolder` key is unset, or names it): `/init` would write ~/CLAUDE.md there.
    private var chatFolderIsHome: Bool { ChatHostCommand.folderIsHome(settings().folder, home: NSHomeDirectory()) }

    /// The exam stand-down is active or the exam browser runs: no send of any kind (D18).
    private var examIsOn: Bool { host.chatExamActive() || host.chatExamBrowserRunning() }

    /// A catalog frame from the session: the catalog changes, is saved when it did, and an open picker is made again (Q9).
    private func catalogReported(_ frame: ChatCatalogFrame) {
        guard catalog.observe(frame), let entries = catalog.entries else { return }
        log("CHAT catalog n=\(entries.count) skills=\(entries.filter { $0.kind == .skill }.count)")
        catalogStore?.save(entries)
        live?.web?.setCatalog(catalog.pickerEntries)
    }

    /// Enter (or the Send control). Locks the input until the bridge answers: accepted clears it, refused unlocks it with the text intact.
    /// This is the one send entry point (D18): the commands Clawd claims (Q25) are decided here, before anything is written, and the web kind's
    /// send while Claude answers becomes a queued card or, with chips or the queue off, a steer (Q12, Q13).
    private func sendFromPanel() {
        guard let opening = live, opening.usesSession, let session else { return }
        let view = opening.panel.surface
        guard !imageReads.contains(Self.draftReadKey), !view.inputView.hasMarkedText() else { return }   // an unconverted composition is not a message (Enter and the Send control)
        let text = view.inputText
        let chips = opening.web?.composer.chips.persisted ?? []
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chips.isEmpty else { return }
        // A pending paste or an image that could not be brought back holds Send (Orca native-chat-image-reattach.ts:24-31).
        if let hold = opening.web?.composer.chips.hold { view.setStatus(hold); return }
        var wire = text
        let decision = ChatHostCommand.decide(text, hasChips: !chips.isEmpty, turnActive: session.turn != .none,
                                              sendUnsettled: session.hasUnsettledSend || !queue.doubtCards.isEmpty, chatFolderIsHome: chatFolderIsHome)
        let name = ChatHostCommand.logName(text)
        var command = false
        switch decision {
        case .refuse(let words):
            log("CHAT command name=\(name) outcome=refused")
            view.setStatus(words)
            return
        case .answer(let words):
            if examIsOn {
                view.setStatus("Not sent: an exam browser is running")
                return
            }
            log("CHAT command name=\(name) outcome=answered")
            spent(text, in: view)
            view.setStatus(words)
            return
        case .send(let sent):
            wire = sent
            command = true
        case .openResume:
            guard opening.web != nil else { view.setStatus(ChatResume.notAvailableText); return }
            log("CHAT command name=resume outcome=opened")
            view.inputText = "/resume "
            view.inputView.setSelectedRange(NSRange(location: ("/resume " as NSString).length, length: 0))
            return
        case .resume(let argument):
            guard let body = opening.web else { view.setStatus(ChatResume.notAvailableText); return }
            resumeTyped(argument, body: body)
            return
        case .text:
            break
        }
        guard opening.web != nil else {
            // The stream kind keeps today's rule: nothing is sent while a turn runs.
            guard session.turn == .none else { return }
            if examIsOn {
                view.setStatus("Not sent: an exam browser is running")
                return
            }
            view.setInputLocked(true)
            let accepted = session.send(ChatSendRequest(text: wire))
            view.setInputLocked(false)
            if accepted {
                if command { log("CHAT command name=\(name) outcome=sent") }
                spent(text, in: view)
            } else {
                view.setStatus("Not sent: Claude Code could not take the message")
            }
            sessionChanged()
            return
        }
        // The old child of a `/resume` is still stopping behind the queue's pause: the message waits in the draft, not as a card that would sit
        // behind the pause until Resume is pressed.
        if queue.pause == .resumed, session.turn == .stopping {
            view.setStatus("Wait for the current turn to stop.")
            return
        }
        // A claimed command is never queued (Q25 refused it during a turn already); a send with chips takes the immediate path, since the queue is text only.
        // A card the drain holds back only because a steer is still unsettled does not trap a new send: that send's turn is the second idle the steer waits for.
        if !command, chips.isEmpty, settings().queueFollowUps, session.turn != .none || (queue.hasActionableCard && !session.hasUnsettledSend) {
            queueCard(text, in: view)
            return
        }
        if session.turn == .stopping {
            view.setStatus("Wait for the current turn to stop.")
            return
        }
        let request = ChatSendRequest(text: wire, origin: .draft, steer: session.turn == .running, chips: chips)
        if !chips.isEmpty {
            sendImages(request, view: view) { [weak self] sent in
                guard let self else { return }
                if sent {
                    self.spent(text, in: view)
                    self.live?.web?.composer.removeSent(chips)
                }
                self.sessionChanged()
            }
            return
        }
        view.setInputLocked(true)
        let sent = transmit(request, automatic: false, view: view)
        view.setInputLocked(false)
        if sent {
            if command { log("CHAT command name=\(name) outcome=sent") }
            spent(text, in: view)
        }
        sessionChanged()
    }

    // MARK: resuming a conversation (R9)

    /// One listing in flight, and how many have been asked for: a result for an older ask, a closed list or another folder is dropped.
    private final class ResumeLoad {
        /// Written on the main queue, read on the listing's utility queue.
        private let lock = NSLock()
        private var flag = false
        var cancelled: Bool {
            get { lock.lock(); defer { lock.unlock() }; return flag }
            set { lock.lock(); flag = newValue; lock.unlock() }
        }
    }
    private var resumeLoad: ResumeLoad?
    private var resumeLoads = 0

    /// `/resume ` was entered in an open chat: the folder's conversations are listed once, off the main thread.
    private func resumeListWanted() {
        guard let opening = live, opening.web != nil, let web = environment.chatWeb else { return }
        resumeLoad?.cancelled = true
        let load = ResumeLoad()
        resumeLoad = load
        resumeLoads += 1
        let number = resumeLoads, gen = opening.gen
        let folder = ChatResume.resolvedFolder(settings().folder)
        let started = ProcessInfo.processInfo.systemUptime
        web.resume.list(folder, session?.sessionID, { load.cancelled }) { [weak self] listing in
            guard let self, !load.cancelled, self.resumeLoads == number, let now = self.live, now.gen == gen, let body = now.web else { return }
            guard ChatResume.resolvedFolder(self.settings().folder) == folder else { return }
            self.resumeLoad = nil
            self.log("CHAT resume list rows=\(listing.rows.count) files=\(listing.files) read=\(listing.read) ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
            body.setResumeList(listing.rows)
        }
    }

    /// The conversations mode was left, or the chat closed: a listing still running is of no use.
    private func resumeListClosed() {
        resumeLoad?.cancelled = true
        resumeLoad = nil
    }

    private func clipped(_ title: String) -> String { ChatJSText.displayText(title, maxLength: 60) }

    /// `/resume <text>` with Enter: the loaded row whose id or title it equals, else a conversation file of that id in the chat's folder, else the
    /// CLI's "not found".
    private func resumeTyped(_ argument: String, body: ChatWebBody) {
        guard let opening = live else { return }
        let view = opening.panel.surface
        let wanted = argument.lowercased()
        if let row = body.resumeRows?.first(where: { $0.id.lowercased() == wanted || $0.title.lowercased() == wanted }) { resumePicked(row); return }
        let folder = ChatResume.resolvedFolder(settings().folder)
        let roots = environment.chatWeb?.resume.roots ?? .none
        // The CLI writes lower-case names: a typed id is handed on in that spelling.
        if ChatResume.isSessionId(argument), ChatResume.conversationExists(id: wanted, folder: folder, roots: roots) {
            resumePicked(ChatResumeRow(id: wanted, title: clipped(argument), subtitle: "", folder: folder, modified: Date()))
            return
        }
        log("CHAT resume pick outcome=not-found")
        view.setStatus(ChatResume.notFoundText(clipped(argument)))
    }

    /// A conversation was picked (a row, or `/resume <text>`): the gates in Orca's order, the folder, the file, the live holder; then the session
    /// resumes, the queue pauses, the draft is spent and the saved scroll place goes (as for `/clear`). A refusal keeps the draft and the list.
    private func resumePicked(_ row: ChatResumeRow) {
        guard let opening = live, opening.usesSession, let session else { return }
        let view = opening.panel.surface
        func refuse(_ outcome: String, _ words: String) {
            log("CHAT resume pick outcome=\(outcome)")
            view.setStatus(words)
        }
        let chips = opening.web?.composer.chips.persisted ?? []
        if let words = ChatHostCommand.resumeRefusal(hasChips: !chips.isEmpty, turnActive: session.turn != .none,
                                                      sendUnsettled: session.hasUnsettledSend || !queue.doubtCards.isEmpty) {
            refuse("busy", words)
            return
        }
        let roots = environment.chatWeb?.resume.roots ?? .none
        let folder = ChatResume.resolvedFolder(settings().folder)
        guard folder == row.folder else { refuse("folder", ChatResume.otherFolderText); return }
        guard ChatResume.conversationExists(id: row.id, folder: folder, roots: roots) else {
            refuse("gone", ChatResume.notFoundText("\"" + clipped(row.title) + "\""))
            return
        }
        switch ChatResume.liveHolder(id: row.id, roots: roots) {
        case .held: refuse("held", ChatResume.heldText); return
        case .unknown: refuse("unknown", ChatResume.unknownHolderText); return
        case .none: break
        }
        let text = view.inputText
        guard session.resume(row.id, title: row.title) else {
            refuse("refused", session.sessionID?.lowercased() == row.id.lowercased() ? "This conversation is already open." : "Wait for the current turn to stop.")
            return
        }
        savedView = nil
        opening.latestView = nil
        pauseQueue(.resumed)
        spent(text, in: view)
        log("CHAT resume pick outcome=ok")
    }

    // MARK: sending images (Q16)

    private static let draftReadKey = "draft"

    /// Whatever ends an image read, once: its key is free again, and a draft's read unlocks the input. The surface of the opening the read began in,
    /// or nil when that opening has closed.
    private func finishImageRead(_ read: ImageRead, key: String, gen: Int?, unlock: Bool) -> ChatPanelSurface? {
        read.settled = true
        read.timer?.cancel(); read.timer = nil
        imageReads.remove(key)
        guard let opening = live, opening.gen == gen, opening.usesSession else { return nil }
        if unlock { opening.panel.surface.setInputLocked(false) }
        return opening.panel.surface
    }

    private final class ImageRead {
        var settled = false
        private let lock = NSLock()
        private var index = 0
        var timer: ChatTimerHandle?
        /// The chip the read is on now (written off the main thread, read by the deadline).
        var current: Int { lock.lock(); defer { lock.unlock() }; return index }
        func starting(_ new: Int) { lock.lock(); index = new; lock.unlock() }
    }

    /// A send with image chips: the files are read and encoded off the main thread, then the send goes through the gate as any other. The draft and the
    /// chips stay until it is accepted; a close drops only the write that has not been made, a turn that starts meanwhile makes the send a steer.
    /// A card's send must still find its card when the read ends (a late replay can settle it meanwhile), and a read that takes longer than
    /// `imageReadSeconds` marks the chip it was on unavailable and sends nothing. `done` says whether the send was accepted.
    private func sendImages(_ request: ChatSendRequest, view: ChatPanelSurface, done: @escaping (Bool) -> Void) {
        let cardId: String?
        switch request.origin {
        case .draft: cardId = nil
        case .card(let id): cardId = id
        }
        let key = cardId ?? Self.draftReadKey
        guard !imageReads.contains(key) else { return }
        // The chip files can have gone since the draft was made (the sweeps run while it stays): they are looked at again at each send.
        let current = cardId == nil ? live?.web?.composer.chips.persisted ?? request.chips : request.chips
        let chips = ChatComposerStore.checked(current, exists: { FileManager.default.fileExists(atPath: $0) })
        if chips != current {
            if let cardId {
                queue.setChips(cardId, chips)
                queueChanged()
            } else {
                composerStore?.setChips(chips)
                live?.web?.composer.syncChips(chips)
            }
        }
        let paths = chips.compactMap(\.path)
        guard paths.count == chips.count else {
            let lost = chips.count - paths.count
            view.setStatus((cardId == nil ? live?.web?.composer.chips.hold : ChatChipModel.lostWords(lost)) ?? ChatImageRefusal.unreadable.words)
            done(false)
            return
        }
        guard let run = environment.chatWeb?.attach.background else { view.setStatus(ChatImageRefusal.unreadable.words); done(false); return }
        let gen = live?.gen
        var made = request
        made.chips = chips
        imageReads.insert(key)
        if cardId == nil { view.setInputLocked(true) }
        let read = ImageRead()
        let text = request.text
        var result: Result<ChatImagePayload, ChatImageRefusal> = .failure(.unreadable)
        read.timer = focus.deadlines.after(Self.imageReadSeconds) { [weak self, weak read] in
            guard let self, let read, !read.settled else { return }
            let surface = self.finishImageRead(read, key: key, gen: gen, unlock: cardId == nil)
            let place = min(read.current, chips.count - 1)
            var marked = chips
            marked[place] = ChatComposerChip(unavailable: (paths[place] as NSString).lastPathComponent)
            if let cardId {
                self.queue.setChips(cardId, marked)
                self.queueChanged()
            } else if surface != nil || self.composerStore?.content.chips == chips {
                // After a close and a reopen the chips are the new opening's: the old list is not written over them.
                self.composerStore?.setChips(marked)
                self.live?.web?.composer.syncChips(marked)
            }
            self.log("CHAT image-read timed-out")
            surface?.setStatus(ChatChipModel.lostWords(1) ?? ChatImageRefusal.unreadable.words)
            done(false)
        }
        run({ result = ChatImageSend.prepare(paths: paths, text: text, starting: { read.starting($0) }) }, { [weak self] in
            guard let self, !read.settled else { return }
            let surface = self.finishImageRead(read, key: key, gen: gen, unlock: cardId == nil)
            // Closed meanwhile: the write is dropped, the draft and the chips are still saved.
            guard let view = surface, let session = self.session else { done(false); return }
            // A card a late replay settled, or that was sent or deleted meanwhile, is not written a second time.
            if let cardId, self.queue.card(cardId) == nil {
                view.setStatus("This message was already sent.")
                done(false)
                return
            }
            switch result {
            case .failure(let refusal):
                view.setStatus(refusal.words)
                done(false)
            case .success(let payload):
                if session.turn == .stopping {
                    view.setStatus("Wait for the current turn to stop.")
                    done(false)
                    return
                }
                made.payload = payload
                made.steer = session.turn == .running
                done(self.transmit(made, automatic: false, view: view))
            }
        })
    }

    // MARK: queued sends and steer (Q12, Q13)

    /// Writes the queue (cards, pause, sends in flight, doubt cards) into the composer file, with the file sync the cards and sends need.
    private func persistQueue() {
        composerStore?.update(durable: true) { [queue] in queue.store(into: &$0) }
        composerStore?.flush()
    }

    private func queueChanged() {
        persistQueue()
        live?.web?.setQueue(queue.rows, pauseText: queue.pauseRowText)
    }

    /// The queue stops sending on its own for `reason`. A stop Tom did not cause (`other`) never replaces a reason already in force.
    private func pauseQueue(_ reason: ChatQueuePause) {
        guard queue.pause != reason, reason != .other || queue.pause == .none else { return }
        queue.setPause(reason)
        log("CHAT queue pause reason=\(reason.rawValue)")
        queueChanged()
    }

    /// D18's guards that apply to every send of the web kind, the drain and Resume included. A missing page means the chat-page files are not installed
    /// (CC:265-270), not a closed panel: the drain runs with the panel closed.
    private func gateRefusal(web: Bool) -> String? {
        if web {
            if !enabled() { return "Not sent: chat is turned off" }
            if settings().view != .chat { return "Not sent: the chat view changed" }
            if environment.chatWeb?.isInstalled() != true { return "Not sent: the chat page is not installed" }
        }
        if examIsOn { return "Not sent: an exam browser is running" }
        return nil
    }

    /// The one entry point of every written send of the web kind (D18): Enter, the drain, Resume, Steer or Send, a picked command and Q25's commands.
    /// A refused manual send keeps its draft and shows the guard's words; a refused automatic send leaves its card waiting and pauses the queue with
    /// `other`. The write that clears the draft or removes the card also adds the send to `inflight`, and it comes before the frame goes out (Q8).
    @discardableResult
    private func transmit(_ request: ChatSendRequest, automatic: Bool, view: ChatPanelSurface?) -> Bool {
        guard let session else { return false }
        let refuse = { (words: String) in
            if automatic { self.pauseQueue(.other) } else { view?.setStatus(words) }
        }
        if let words = gateRefusal(web: environment.chatWeb != nil) { refuse(words); return false }
        transmitting = true
        defer { transmitting = false }
        let chips = composerStore?.content.chips
        queue.begin(request)
        composerStore?.update(durable: true) { [queue] file in
            if request.origin == .draft { file.draft = nil; file.chips = Self.chips(file.chips, without: request.chips) }
            queue.store(into: &file)
        }
        composerStore?.flush()
        // A send whose in-flight entry is not on disk would come back after a crash as a draft or a card and go out a second time (deferred Low
        // S4 L4): the frame is not sent while the store cannot save. The next successful flush clears `saveFailed`, so one failure blocks no later send.
        let unsaved = composerStore?.saveFailed == true
        guard !unsaved, session.send(request) else {
            queue.abort(request.uuid)
            composerStore?.update(durable: true) { [queue] file in
                if request.origin == .draft { file.draft = view?.inputText.isEmpty == false ? view?.inputText : (self.draft.isEmpty ? nil : self.draft); file.chips = chips }
                queue.store(into: &file)
            }
            composerStore?.flush()
            refuse(unsaved ? "Not sent: Clawd could not save the message" : "Not sent: Claude Code could not take the message")
            live?.web?.setQueue(queue.rows, pauseText: queue.pauseRowText)
            return false
        }
        // A person's turn starting lifts the pause the queue was under; the queue's own drain never does (Orca queued-stop.ts:1-7).
        if request.person, queue.pause != .none {
            queue.liftPause()
            persistQueue()
        }
        live?.web?.setQueue(queue.rows, pauseText: queue.pauseRowText)
        return true
    }

    /// The draft's chips less the ones a send carried: a send without chips leaves them (Sprint 4 recheck: a text-only send must not clear them).
    private static func chips(_ chips: [ChatComposerChip]?, without sent: [ChatComposerChip]) -> [ChatComposerChip]? {
        var rest = chips ?? []
        for chip in sent { if let place = rest.firstIndex(of: chip) { rest.remove(at: place) } }
        return rest.isEmpty ? nil : rest
    }

    /// A send that becomes a card (Q12): the draft's text joins the queue and the draft clears in one write. A card that does not fit changes nothing.
    private func queueCard(_ text: String, in view: ChatPanelSurface) {
        guard queue.add(text) != nil else {
            view.setStatus(ChatQueue.fullWords)
            return
        }
        history.push(text)
        view.inputText = ""; draft = ""
        composerStore?.update(durable: true) { [queue] file in file.draft = nil; queue.store(into: &file) }
        composerStore?.flush()
        view.setStatus("")
        live?.web?.setQueue(queue.rows, pauseText: queue.pauseRowText)
        log("CHAT queue add n=\(queue.cards.count) chars=\(text.count)")
    }

    /// The queue's drain: when nothing holds it, the oldest waiting card is sent through the gate as an ordinary send (a new turn), one card per turn end.
    private func drainQueue() {
        guard !transmitting, let session, session.turn == .none, !session.hasUnsettledSend, let card = queue.nextSendable else { return }
        transmit(ChatSendRequest(text: card.text, origin: .card(card.id), steer: false, person: false), automatic: true, view: live?.panel.surface)
    }

    /// The turn is none: a Steer that waited for the stop goes first, then the drain.
    private func afterTurnEnd() {
        guard !transmitting else { return }
        if let id = steerAfterStop, session?.turn == ChatTurnState.none {
            steerAfterStop = nil
            sendNow(id)
            return
        }
        drainQueue()
    }

    /// Steer (a card waiting on the turn) or Send (a card held on its own or returned): Orca's one "Send now" action. It writes the card's text at
    /// once, into the running turn when one runs (the transcript then shows it where its replay lands), else as a plain send. While the turn is
    /// stopping it waits for the turn to be none and goes first. The card goes in the same write that puts the send in flight.
    private func sendNow(_ id: String) {
        guard let session, let row = queue.rows.first(where: { $0.id == id }) else { return }
        log("CHAT queue \(row.sendsPlainly ? "send" : "steer")")
        let view = live?.panel.surface
        let chips = row.card.chips ?? []
        // A card with images is read for its send, and nothing can read it while no panel is up: it stays where it is, never sent as text alone.
        if view == nil, !chips.isEmpty {
            steerAfterStop = nil
            return
        }
        if session.turn == .stopping {
            steerAfterStop = id
            return
        }
        let request = ChatSendRequest(text: row.text, origin: .card(id), steer: session.turn == .running, chips: chips, person: true)
        if let view, !request.chips.isEmpty {
            // A doubt or returned card that carried images: they are read again, so a file the sweeps removed refuses the send (Q16).
            sendImages(request, view: view) { [weak self] _ in self?.sessionChanged() }
        } else {
            transmit(request, automatic: false, view: view)
        }
        live?.panel.focusInput()
    }

    /// Cmd+Enter (Orca use-native-chat-composer-keydown.ts:102-114): with the draft empty and no chips it steers the newest card; otherwise it is an
    /// ordinary Enter.
    private func steerChord() -> Bool {
        guard let body = live?.web, live?.usesSession == true else { return false }
        let empty = body.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard empty, composerStore?.content.chips?.isEmpty != false, body.composer.chips.items.isEmpty, let newest = queue.newestCard else { return false }
        sendNow(newest.id)
        return true
    }

    /// Delete: the card goes. A card the drain sent already is gone from the list, and the status line says so.
    private func deleteCard(_ id: String) {
        guard queue.remove(id) != nil else {
            live?.panel.surface.setStatus("This message was already sent.")
            return
        }
        log("CHAT queue delete")
        queueChanged()
        live?.panel.focusInput()
        drainQueue()
    }

    /// Edit: the card's text is appended to the draft (Orca's rule), then the card goes. If the draft cannot be saved the card stays, and the text
    /// shows in both places, visibly.
    private func editCard(_ id: String) {
        guard let opening = live, opening.usesSession else { return }
        let view = opening.panel.surface
        guard let card = queue.card(id) else {
            view.setStatus("This message was already sent.")
            return
        }
        let merged = ChatQueue.appendReturned(draft: view.inputText, text: card.text)
        if merged != view.inputText { view.inputText = merged }
        draft = merged
        composerStore?.setDraft(merged)
        composerStore?.flush()
        log("CHAT queue edit")
        if composerStore?.saveFailed == true { return }
        // The card's images go back to the composer with its text, once the draft is saved: an images-only card is never lost, and the images are
        // never on the card and in the composer at once.
        let chips = card.chips ?? []
        if !chips.isEmpty {
            let before = composerStore?.content.chips ?? []
            opening.web?.composer.restoreChips(chips)
            composerStore?.setChips(opening.web?.composer.chips.persisted ?? chips)
            composerStore?.flush()
            if composerStore?.saveFailed == true {
                opening.web?.composer.removeSent(chips)
                composerStore?.setChips(before)
                return
            }
        }
        queue.remove(id)
        queueChanged()
        opening.panel.focusInput()
        drainQueue()
    }

    /// Resume: lifts the queue's pause, and the next send goes through the gate (at once when nothing runs).
    private func resumeQueue() {
        guard queue.pause != .none else { return }
        log("CHAT queue resume n=\(queue.cards.count)")
        queue.liftPause()
        queueChanged()
        live?.panel.focusInput()
        drainQueue()
    }

    /// What the ledger decided about a written send (Q13). Each change to the queue is one write to the file.
    private func sendSettled(_ verdict: ChatSendVerdict) {
        switch verdict {
        case .delivered(let entry, _):
            queue.delivered(entry.uuid)
            queueChanged()
        case .notDelivered(let entry, let why):
            let toDraft = queue.notDelivered(entry, why)
            queueChanged()
            if toDraft { restore(unsent: entry.text, chips: entry.chips) }
        case .doubt(let entry, _):
            queue.doubt(entry)
            queueChanged()
        case .unwritten(let entry):
            queue.unwritten(entry)
            queueChanged()
            if entry.origin == .draft { restore(unsent: entry.text, chips: entry.chips) }
        }
        afterTurnEnd()
    }

    /// The child was lost without a stop being asked for (it exited, a write to it failed, or its output overflowed): the queue pauses with `other`.
    private func childLost(_ loss: ChatChildLoss) {
        log("CHAT queue child-lost reason=\(loss.rawValue)")
        pauseQueue(.other)
    }

    /// A draft that was taken (sent, or answered by the host): it goes into the history, and the input and the saved draft are emptied.
    private func spent(_ text: String, in view: ChatPanelSurface) {
        history.push(text)
        // Only what was sent leaves: text that joined the input meanwhile (an Edit on a card during an image read) stays.
        let sent = ChatJSText.trimmedEnd(text)
        let now = view.inputText
        let rest = now == text ? "" : now.hasPrefix(sent) ? ChatJSText.trimmed(String(now.dropFirst(sent.count))) : now
        view.inputText = rest; draft = rest
        composerStore?.setDraft(rest); composerStore?.flush()
        view.setStatus("")
    }

    /// The input's text changed by an edit (typing, a paste, a drop): the next Up starts from the end, and the draft is saved 250 ms later.
    private func draftEdited() {
        guard let body = live?.web else { return }
        if !recalling { history.edited() }
        composerStore?.setDraft(body.inputText)
    }

    /// Up and Down (Orca NC/use-native-chat-composer-keydown.ts:115-133). Up recalls only from an empty draft or while recalling; otherwise the
    /// key is the caret's. The recalled text replaces the draft with the caret at its end.
    private func recall(_ key: ChatHistoryKey) -> Bool {
        guard let body = live?.web, !body.composer.isLocked else { return false }
        let recalled: String?
        switch key {
        case .up:
            guard body.inputText.isEmpty || history.index != nil else { return false }
            recalled = history.previous()
        case .down:
            recalled = history.next()
        }
        guard let recalled else { return false }
        recalling = true
        defer { recalling = false }
        body.inputText = recalled
        body.inputView.setSelectedRange(NSRange(location: (recalled as NSString).length, length: 0))
        return true
    }

    /// A send whose line never reached Claude Code: its text goes back into the input (or the draft, with the panel closed): the text alone when
    /// the input is empty, else the text, a blank line, then what is there. It is never sent again by itself.
    private func restore(unsent text: String, chips: [ChatComposerChip] = []) {
        let current = live?.panel.surface.inputText ?? draft
        let restored = current.isEmpty ? text : text + "\n\n" + current
        if let view = live?.panel.surface { view.inputText = restored }
        draft = restored
        composerStore?.setDraft(restored)
        if !chips.isEmpty {
            // The images the send had come back to the draft, after the ones it already holds.
            if let web = live?.web {
                web.composer.restoreChips(chips)
            } else {
                let held = composerStore?.content.chips ?? []
                composerStore?.setChips(held + chips.filter { !held.contains($0) })
            }
        }
        composerStore?.flush()
        log("CHAT unsent-restored chars=\(text.count)")
        sessionChanged()
    }

    /// The idle stop: 10 minutes with the panel closed and no turn, one one-shot timer that exists only then.
    private func armIdleStop() {
        guard live == nil, let session, session.turn == .none else { return }
        timer.arm(after: Self.idleStop, leeway: 5)
    }
    private func idleTimerFired() {
        guard live == nil, let session, session.turn == .none else { return }
        pauseQueue(.other)
        session.stop(.panelClosedLong)
    }

    // MARK: the paths that stop the child

    /// The end of every scheduler batch (spec section 6): an exam stand-down closes the panel and hard-stops the child, once per stand-down.
    public func batchEnded() {
        if host.chatExamActive() {
            close(.exam)
            if !examStopped { examStopped = true; pauseQueue(.other); session?.stop(.exam); termPath?.stopHard(reason: "exam") }
        } else {
            examStopped = false
        }
    }

    /// A settings generation was applied: `chat` switched off closes the panel and hard-stops the child.
    public func settingsApplied() {
        let now = enabled()
        defer { wasEnabled = now }
        let view = settings().view
        defer { lastView = view }
        if view != lastView {
            // A `chatView` change closes the panel and hard-stops the other path's child.
            close(.view)
            pauseQueue(.other)
            if view == .terminal { session?.stop(.chatOff) } else { termPath?.stopHard(reason: "view") }
        }
        guard wasEnabled, !now else { return }
        close(.off)
        pauseQueue(.other)
        session?.stop(.chatOff)
        termPath?.stopHard(reason: "off")
    }

    /// The agent is quitting: the panel goes and the child is hard-stopped. With the real bridge this returns once its sweep has ended (at most
    /// `timeout` seconds), so the agent does not die before the processes Claude Code started are gone.
    public func shutdown(timeout: TimeInterval = 4) {
        close(.quit)
        pauseQueue(.other)
        composerStore?.flush()
        termPath?.quit(timeout: timeout)
        if let real = session as? ChatSession { real.quit(timeout: timeout) } else { session?.stop(.agentQuit) }
        // The quit turned every unconfirmed send into a doubt card; the file holds them before the process goes.
        composerStore?.flush()
    }

    // MARK: focus

    /// The focus monitor asks about a key notification (F1.5, Sprint 3e). Exempt only for the live opening's panel while its key right is open
    /// and only with a cause: the opening's accepted double-click, a mouse-down inside the panel, the opening's activation token, or the
    /// activation of this opening that is still in force. A key that comes between `willBecomeActive` and `didBecomeActive` waits for that
    /// activation.
    public func keyVerdict(for window: NSWindow?) -> ChatKeyVerdict? {
        // The "+" picker, and any sheet on it, may take the key while it is up (before the guard on the panel itself).
        if let opening = live, let window, opening.pickerPresenting || isPickerWindow(window, of: opening) {
            log("CHAT picker-key gen=\(opening.gen)")
            return .exempt
        }
        guard let opening = live, let window, window === opening.panel, opening.panel.isKeyAllowed, let a = act else { return nil }
        let event = environment.chatCurrentEvent()
        let caused = handlingAcceptedClick || (event?.isMouseDown == true && event?.window === opening.panel)
        if caused || tokenIsOpen(a) {
            log("CHAT key gen=\(opening.gen)")
            // Every key the guard keeps puts the input in front of the keyboard again, so a key never lands nowhere. This is the
            // one place that decides about every key of the panel; ChatPanel has no `becomeKey` override.
            opening.panel.focusInput()
            return .exempt
        }
        if (a.active || claimedActivation()) && focus.isActive() {
            // The OS's own key changes inside the active application: one with a user event is the user's, one without is a return. An
            // activation another surface claimed is Clawd's activation too, so a panel opened after that claim is covered.
            log(event != nil ? "CHAT key gen=\(opening.gen)" : "CHAT key-returned gen=\(opening.gen)")
            opening.panel.focusInput()
            return .exempt
        }
        if a.willBecome {
            a.pendingKeys += 1
            // The input gate: the panel is its own first responder until the verdict, so no text view, web input or terminal takes a typed key or a paste.
            opening.panel.makeFirstResponder(nil)
            focus.nextTurn { [weak self] in
                guard let self, let a = self.act, a.gen == opening.gen, !self.activationStepRunning() else { return }
                a.willBecome = false
                self.resolvePendingKeys(a, exempt: false)
            }
            return .deferred
        }
        log("CHAT key-uncaused gen=\(opening.gen)")
        queueUncausedClose(a)
        return .uncaused
    }

    /// The live panel resigned key.
    public func resigned(_ window: NSWindow?) {
        guard let opening = live, let window, window === opening.panel else { return }
        let owner = focus.surfaceOwnerAt(focus.pointerLocation()).map(ChatProcessOwner.sanitized) ?? "own"
        log("CHAT resign gen=\(opening.gen) keyOwner=\(owner)")
    }

    /// `willBecomeActive`: a key notification that follows is judged with the activation that follows.
    public func appWillBecomeActive() { act?.willBecome = true }

    /// `didResignActive` while open: the exemption of an active Clawd ends at once.
    public func appResigned() {
        guard let a = act, live != nil else { return }
        log("CHAT inactive gen=\(a.gen)")
        a.active = false
        a.lastResign = clock.now
    }

    /// The old verdict, as the composition of its two halves: the claim, else the close of an unclaimed activation.
    public func activationVerdict() -> ChatActivationVerdict {
        activationClaim() ? .exempt : closeUnclaimedActivation()
    }

    /// The focus monitor's claim step (design 4.5): is this activation the chat's? These are the exempt branches of the old verdict; declining
    /// changes nothing for the surfaces and closes nothing.
    public func activationClaim() -> Bool {
        guard let opening = live, let a = act else { return false }
        func claimed() -> Bool { a.willBecome = false; return true }
        if opening.picker != nil || opening.pickerPresenting {
            // The picker activates Clawd when it opens; the panel's key comes back through `a.active` when the picker closes.
            a.active = true
            a.frontIsClawd = true
            log("CHAT active gen=\(a.gen) cause=picker")
            resolvePendingKeys(a, exempt: true)
            return claimed()
        }
        let now = clock.now
        let event = environment.chatCurrentEvent()
        let clickEvent = event?.isMouseDown == true && event?.window === opening.panel
        let clickRecent = opening.panel.lastLeftMouseDown.map { $0 <= now && now - $0 <= Self.clickWindow } ?? false
        if a.exemptReturnPending, a.exemptReturnPid == nil {
            // Clawd is active again after an exempt surface (the screenshot UI, an input method, dictation) gave the activation back.
            a.exemptReturnPending = false
            a.active = true
            a.frontIsClawd = true
            log("CHAT active gen=\(a.gen) cause=return")
            resolvePendingKeys(a, exempt: true)
            return claimed()
        }
        // Clawd is active some other way: an exempt surface that was to give the activation to another application no longer will.
        a.exemptReturnPending = false
        if tokenIsOpen(a) {
            // A click on this panel is Clawd's own press whatever the order in which AppKit activates and records it.
            // A press that belongs to the click series that opened the chat (within the system's double-click interval of the open event's own
            // time stamp, and gone to one of Clawd's windows) is Clawd's, even when the window server has it and Clawd's window has not
            // received it yet. A press elsewhere inside that interval is a press elsewhere.
            if !clickEvent, !clickRecent, let age = focus.sessionPressAge(), now - age > a.requestedAt, !pressIsOpenSeries(a, at: now - age),
               now - age > (windowPresses.latest ?? -.infinity) + Self.pressMargin {
                spend(a, cause: "outside-press")
                a.pressSpent = true
            } else {
                a.tokenOpen = false; a.deadline?.cancel(); a.deadline = nil
                a.active = true
                a.frontIsClawd = true
                log("CHAT active gen=\(a.gen) cause=open after=\(Int(((now - a.requestedAt) * 1000).rounded()))")
                resolvePendingKeys(a, exempt: true)
                return claimed()
            }
        } else if clickEvent || clickRecent || pressIsClawdsClick(a, now: now) {
            a.active = true
            a.frontIsClawd = true
            log("CHAT active gen=\(a.gen) cause=click")
            a.refused = false
            opening.panel.setActivationHint(false)
            resolvePendingKeys(a, exempt: true)
            return claimed()
        }
        return false
    }

    /// The unclaimed step's chat half: no surface claimed the activation, so the chat's keys that waited for it are uncaused and the panel closes.
    public func closeUnclaimedActivation() -> ChatActivationVerdict {
        guard live != nil, let a = act else { return .violation }
        a.willBecome = false
        resolvePendingKeys(a, exempt: false)
        queueUncausedClose(a)
        return .answeredByClose
    }

    /// Another surface claimed Clawd's activation: it is lawful. The chat clears its "will become" and exempt-return records as its own claims do,
    /// knows Clawd is in front, ends an open activation token without a line (the activation it waited for came, to another surface, so it is
    /// neither refused nor spent), and resolves its waiting keys as exempt.
    public func activationClaimedElsewhere() {
        guard live != nil, let a = act else { return }
        a.willBecome = false
        a.exemptReturnPending = false
        a.frontIsClawd = true
        a.tokenOpen = false; a.deadline?.cancel(); a.deadline = nil
        resolvePendingKeys(a, exempt: true)
    }

    /// A hand-back in flight ends (another surface opens).
    public func cancelHandBack() { handbackSteps?.cancel(); handbackSteps = nil }

    /// A mouse-down of the session that is newer than the last resign (and than the activation record), went to one of Clawd's windows and is
    /// within the click window: the click into the panel that caused this activation, when the activation is handled before the panel records it.
    private func pressIsClawdsClick(_ a: Activation, now: TimeInterval) -> Bool {
        guard let age = focus.sessionPressAge(), age >= 0, age <= Self.clickWindow, focus.latestPressWentToClawd() else { return false }
        return now - age > max(a.beganAt, a.lastResign ?? -.infinity)
    }

    /// Whether a press at `time` belongs to the click series that opened this chat: within the system's double-click interval of the open event's own
    /// time stamp, and gone to one of Clawd's windows. Time alone would let a real click elsewhere inside that interval pass for Clawd's.
    private func pressIsOpenSeries(_ a: Activation, at time: TimeInterval) -> Bool {
        time <= a.openEventTime + focus.doubleClickInterval() && focus.latestPressWentToClawd()
    }

    // MARK: activation (Sprint 3e)

    private func beginActivation(gen: Int, panel: ChatPanel, eventTime: TimeInterval) -> Activation {
        handbackSteps?.cancel(); handbackSteps = nil
        willBeginActivation?()
        let a = Activation(gen: gen)
        a.beganAt = clock.now
        a.openEventTime = eventTime
        a.target = focus.frontmost()
        a.observer = focus.observeActivations { [weak self] app in self?.otherAppActivated(app) }
        a.pressObserver = focus.observeOutsidePresses { [weak self] press in self?.outsidePressed(press) }
        panel.presses = windowPresses
        act = a
        return a
    }

    /// The open's one request, with the token and its deadline (item 2).
    private func requestActivation(_ a: Activation) {
        a.requestedAt = clock.now
        a.tokenOpen = true
        log("CHAT activate gen=\(a.gen) cause=open")
        focus.requestActivation()
        a.deadline = focus.deadlines.after(Self.activationDeadline) { [weak self] in
            guard let self, let current = self.act, current === a else { return }
            self.expireToken(a)
        }
    }

    private func tokenIsOpen(_ a: Activation) -> Bool {
        guard a.tokenOpen else { return false }
        if clock.now - a.requestedAt >= Self.activationDeadline { expireToken(a); return false }
        return true
    }

    private func expireToken(_ a: Activation) {
        guard a.tokenOpen else { return }
        a.tokenOpen = false; a.deadline?.cancel(); a.deadline = nil
        guard !a.active else { return }
        a.refused = true
        log("CHAT activate-refused gen=\(a.gen)")
        live?.panel.setActivationHint(true)
    }

    private func spend(_ a: Activation, cause: String) {
        a.tokenOpen = false; a.deadline?.cancel(); a.deadline = nil
        log("CHAT activate-spent gen=\(a.gen) cause=\(cause)")
    }

    /// Another application became active while the panel is open: it is the hand-back target now (no line), and it spends an open token.
    private func otherAppActivated(_ app: ChatAppRef) {
        guard let a = act, live != nil, app.pid != ProcessInfo.processInfo.processIdentifier else { return }
        if Self.isExempt(bundleID: app.bundleID) {
            // The screenshot UI, an input method or dictation: the panel stays. When it gives the activation back, the application that was in
            // front before it (Clawd, or the recorded target) getting it again is not a click elsewhere; any other application is.
            if !a.exemptReturnPending {
                a.exemptReturnPending = true
                a.exemptReturnPid = a.frontIsClawd ? nil : a.target?.pid
            }
            return
        }
        if a.exemptReturnPending {
            a.exemptReturnPending = false
            if let returnPid = a.exemptReturnPid, returnPid == app.pid {
                // The application the exempt surface gave the activation back to.
                a.target = app
                log("CHAT exempt-return gen=\(a.gen)")
                return
            }
        }
        a.target = app
        a.otherAppSeen = true
        a.frontIsClawd = false
        if tokenIsOpen(a) { spend(a, cause: "other-app") }
        // An activation never closes the panel (D1; Orca closes nothing on a blur). When a button is down and no press is pending, the click that
        // caused it is opened here, and its mouse-up decides; a down that comes after merges into it.
        let buttons = focus.pressedButtons()
        let label = ChatProcessOwner.sanitized(app.label)
        if a.press == nil, let button = ChatPressButton(lowestIn: buttons) {
            beginPress(a, PendingPress(button: button, down: focus.pointerLocation(), owner: label, pid: app.pid, fromActivation: true))
        }
        log("CHAT app-active gen=\(a.gen) app=\(label) buttons=\(buttons) pending=\(a.press == nil ? "none" : "press")")
    }

    /// A mouse-down another application received while the panel is open. One on an exempt surface, or while the frontmost application is an
    /// exempt one (the screenshot UI's crosshair, a candidate window, the dictation overlay), is not a click elsewhere. The press went to another
    /// application by construction, so the open's own click series is not looked at here.
    /// The down only opens a press: its mouse-up decides (a plain click closes, a drag of 4 pt or more does not).
    private func outsidePressed(_ press: ChatOutsidePress) {
        guard let a = act, live != nil else { return }
        let front = focus.frontmostLabel()
        if Self.isExempt(bundleID: front) { return }
        let owner = focus.surfaceOwnerAt(press.location)
        if Self.isExempt(bundleID: owner) { return }
        let known = (owner ?? front).map(ChatProcessOwner.sanitized)
        let pid = press.ownerPid ?? focus.surfaceOwnerPidAt(press.location)
        if var pending = a.press {
            // The activation of the clicked application came first and opened this press: the down merges into it. Any other down is ignored.
            guard pending.fromActivation, pending.button == press.button else { return }
            pending.down = press.location
            pending.owner = known ?? pending.owner
            pending.pid = pid ?? pending.pid
            pending.fromActivation = false
            a.press = pending
        } else {
            beginPress(a, PendingPress(button: press.button, down: press.location, owner: known ?? "unknown", pid: pid, fromActivation: false))
        }
        // The handler may run after the up was posted (its monitor did not exist yet): the press is decided now, by where the pointer is.
        if focus.pressedButtons() & press.button.bit == 0 { endPress(a, upAt: focus.pointerLocation()) }
    }

    /// Opens the pending press: the follow-up monitor and the one deadline, both removed by its decision and by every close.
    private func beginPress(_ a: Activation, _ pending: PendingPress) {
        a.press = pending
        a.followUp = focus.observePressFollowUps { [weak self] follow in self?.pressFollowUp(a, follow) }
        a.pressDeadline = focus.deadlines.after(Self.pressDeadline) { [weak self] in
            guard let self, self.act === a else { return }
            self.finishPress(a, decided: "timeout")
        }
    }

    private func pressFollowUp(_ a: Activation, _ follow: ChatPressFollowUp) {
        guard act === a, var pending = a.press, follow.button == pending.button else { return }
        switch follow.kind {
        case .dragged:
            if hypot(follow.location.x - pending.down.x, follow.location.y - pending.down.y) >= Self.dragThreshold { pending.moved = true; a.press = pending }
        case .up:
            endPress(a, upAt: follow.location)
        }
    }

    /// The press's mouse-up (or the pointer standing in for it): a drag when it moved 4 pt or more at any point, or at its end.
    private func endPress(_ a: Activation, upAt location: CGPoint) {
        guard let pending = a.press else { return }
        let far = hypot(location.x - pending.down.x, location.y - pending.down.y) >= Self.dragThreshold
        finishPress(a, decided: pending.moved || far ? "drag" : "click")
    }

    /// A file drag that comes to a Clawd drop target while a press is pending makes that press a drag, whatever the distance (P1 A4 c). The drop
    /// targets (the chat body, Clawd's body) call this.
    public func fileDragEntered() {
        guard let a = act, live != nil, var pending = a.press else { return }
        pending.moved = true
        a.press = pending
    }

    /// The decision: the follow-up monitor and the deadline go, one line says what it was, and a plain click closes (unless `chatOutsideClick` is
    /// `stay`). A timeout counts as a drag.
    private func finishPress(_ a: Activation, decided: String) {
        guard let pending = a.press else { return }
        a.press = nil
        a.followUp?.cancel(); a.followUp = nil
        a.pressDeadline?.cancel(); a.pressDeadline = nil
        log("CHAT press gen=\(a.gen) button=\(pending.button.rawValue) decided=\(decided) owner=\(pending.owner) pid=\(pending.pid.map(String.init) ?? "0")")
        guard decided == "click", settings().outsideClick == .close else { return }
        a.clickedElsewhere = true
        a.closeBy = "press:" + pending.owner
        closeOutside(a)
    }

    /// The click-elsewhere close: it closes at once, once per opening.
    private func closeOutside(_ a: Activation) {
        guard let opening = live, opening.gen == a.gen, !a.closeQueued else { return }
        a.closeQueued = true
        close(.outside)
    }

    /// The bundles whose activation or window never closes the panel, each found on this Mac (Info.plist read 2026-10-26) unless it says otherwise:
    /// - `com.apple.screencaptureui` (/System/Library/CoreServices/screencaptureui.app) and `com.apple.screenshot` (Screenshot.app,
    ///   `com.apple.screenshot.launcher`): Cmd+Shift+4 and 5.
    /// - `com.apple.inputmethod.`: the Japanese IM extensions (`Kotoeri.RomajiTyping` and `.KanaTyping`, `.appex` processes) and dictation
    ///   (`com.apple.inputmethod.ironwood`, DictationIM.app).
    /// - `com.apple.CharacterPaletteIM` (the Emoji & Symbols viewer), `com.apple.50onPaletteIM`, `com.apple.PressAndHold` (accent popup, `.appex`),
    ///   `com.apple.TextInputSwitcher` (Ctrl+Space), `com.apple.TextInputMenuAgent`, and `com.apple.TextInputUI.` (the caret-side input UI,
    ///   `...xpc.CursorUIViewService`, an `.xpc` in TextInputUIMacHelper.framework).
    /// - Aqua Voice, whose paste goes into the panel: `com.electron.aqua-voice` and its helper, `aquavoice.` (its native bridge
    ///   `aquavoice.macOSBridge`, AquaMacOSBridge.app inside Aqua Voice.app), and the user's ring bridge `com.tomarai.aquaringbridge`.
    /// - The system's own dialogs, which come forward by themselves (often for claude's own work: a password, Touch ID, privacy or
    ///   downloaded-file prompt) and are answered without leaving the chat: `com.apple.UserNotificationCenter` (closed the user's chat 1.4 s
    ///   after its open, 2026-10-27 08:24), `com.apple.SecurityAgent` (Security.framework's SecurityAgent.bundle),
    ///   `com.apple.LocalAuthentication.UIAgent` (coreautha.bundle) and `com.apple.LocalAuthenticationRemoteService` (LocalAuthenticationUI's
    ///   XPC service), `com.apple.tcc.AuthorizationPromptService` and `com.apple.coreservices.uiagent` (both in /System/Library/CoreServices).
    /// Not on this Mac, so not listed: `com.apple.TextInputUIAgent`, `com.apple.speech.` and `com.apple.assistant.dictation` (no Info.plist
    /// anywhere under /System, /Applications), and `SpeechRecognitionCore` and `com.apple.CharacterPicker` (frameworks, never an owner of a click).
    public static let exemptBundlePrefixes = ["com.apple.screencaptureui", "com.apple.screenshot", "com.apple.inputmethod.", "com.apple.CharacterPaletteIM",
                                              "com.apple.50onPaletteIM", "com.apple.PressAndHold", "com.apple.TextInputSwitcher",
                                              "com.apple.TextInputMenuAgent", "com.apple.TextInputUI.", "aquavoice.", "com.tomarai.aquaringbridge",
                                              AgentRuntime.aquaBundleIdentifier,
                                              "com.apple.UserNotificationCenter", "com.apple.SecurityAgent", "com.apple.LocalAuthentication.UIAgent",
                                              "com.apple.LocalAuthenticationRemoteService", "com.apple.tcc.AuthorizationPromptService",
                                              "com.apple.coreservices.uiagent"]
    public static func isExempt(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return exemptBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// The keys that waited for an activation are judged now: exempt with an exempt activation, else uncaused.
    private func resolvePendingKeys(_ a: Activation, exempt: Bool) {
        guard a.pendingKeys > 0 else { return }
        let count = a.pendingKeys
        a.pendingKeys = 0
        for _ in 0..<count {
            if exempt {
                log("CHAT key gen=\(a.gen)")
                live?.panel.focusInput()
            } else {
                log("CHAT key-uncaused gen=\(a.gen)")
                lateViolation?()
                queueUncausedClose(a)
            }
        }
    }

    /// The close of an uncaused key or activation runs on the next main-queue turn, never inside the notification; one close per opening.
    private func queueUncausedClose(_ a: Activation) {
        guard !a.closeQueued else { return }
        a.closeQueued = true
        a.closeBy = "uncaused"
        focus.nextTurn { [weak self] in
            guard let self, let opening = self.live, opening.gen == a.gen else { return }
            self.close(.outside)
        }
    }

    /// The close's end (item 7): while Clawd is active, hand activation back; nothing while it is not.
    private func endActivation(_ reason: ChatCloseReason) {
        guard let a = act else { return }
        act = nil
        a.deadline?.cancel(); a.observer?.cancel(); a.pressObserver?.cancel()
        a.followUp?.cancel(); a.followUp = nil; a.pressDeadline?.cancel(); a.pressDeadline = nil; a.press = nil
        guard focus.isActive() else { return }
        let gen = a.gen
        // After a click elsewhere the click's own application is taking the activation: handing it to the one recorded at the open would fight it.
        let deactivateOnly = reason == .exam || reason == .hidden || a.clickedElsewhere || (a.pressSpent && !a.otherAppSeen)
        if !deactivateOnly, let target = a.target {
            log("CHAT handback gen=\(gen)")
            if focus.handBack(target) {
                handbackSteps = focus.deadlines.after(Self.handbackDeadline) { [weak self] in
                    guard let self else { return }
                    if self.focus.isActive() { self.deactivateStep(gen: gen, finder: true) } else { self.log("CHAT handback gen=\(gen) ok=1") }
                }
                return
            }
        }
        deactivateStep(gen: gen, finder: !deactivateOnly)
    }

    private func deactivateStep(gen: Int, finder: Bool) {
        log("CHAT deactivate gen=\(gen)")
        focus.requestDeactivation()
        handbackSteps = focus.deadlines.after(Self.handbackDeadline) { [weak self] in
            guard let self else { return }
            if !self.focus.isActive() { self.log("CHAT deactivate gen=\(gen) ok=1"); return }
            guard finder else { self.log("CHAT handback-failed gen=\(gen)"); return }
            self.log("CHAT handback-finder gen=\(gen)")
            guard self.focus.handBackToFinder() else { self.log("CHAT handback-failed gen=\(gen)"); return }
            self.handbackSteps = self.focus.deadlines.after(Self.handbackDeadline) { [weak self] in
                guard let self else { return }
                if self.focus.isActive() { self.log("CHAT handback-failed gen=\(gen)") } else { self.log("CHAT handback-finder gen=\(gen) ok=1") }
            }
        }
    }
}
