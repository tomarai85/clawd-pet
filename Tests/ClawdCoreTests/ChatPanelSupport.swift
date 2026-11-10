import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Test doubles and rigs for the chat panel and its runtime wiring. No real claude, no window on screen.

/// The bridge as the panel sees it: a transcript, a turn state and the callbacks, with the calls recorded.
final class FakeChatSession: ChatSessionDriving {
    var transcript = ChatTranscript()
    var turn: ChatTurnState = .none
    var onChange: (() -> Void)?
    var onTurnStarted: (() -> Void)?
    var onTurnEnded: ((ChatTurnOutcome) -> Void)?
    var onSendFailed: ((String) -> Void)?
    var onCatalog: ((ChatCatalogFrame) -> Void)?
    var onSendSettled: ((ChatSendVerdict) -> Void)?
    var onChildLost: ((ChatChildLoss) -> Void)?
    var onConversationCleared: (() -> Void)?
    var hasUnsettledSend = false
    /// The Claude Code conversation id (Q19); nil until the test names one.
    var sessionID: String?
    /// The text of every send that was taken, in order (a steer too).
    var sent: [String] = []
    /// Every request that was taken, in order.
    var requests: [ChatSendRequest] = []
    var stops: [ChatStopReason] = []
    var interrupts = 0
    var accept = true
    /// Called at the start of `send`, before it answers (a test reads the panel's state during the call).
    var duringSend: ((String) -> Void)?

    @discardableResult func send(_ request: ChatSendRequest) -> Bool {
        let text = request.text
        duringSend?(text)
        guard accept, request.payload != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if turn == .running, request.steer {
            sent.append(text); requests.append(request)
            transcript.appendPendingUser(uuid: request.uuid, text: text, images: request.payload?.paths ?? [])
            onChange?()
            return true
        }
        guard turn == .none else { return false }
        sent.append(text); requests.append(request)
        transcript.appendUser(text, uuid: request.uuid, images: request.payload?.paths ?? [])
        turn = .running
        onTurnStarted?()
        onChange?()
        return true
    }
    /// The bridge reports a send whose line was never written.
    func failSend(_ text: String) {
        onSendFailed?(text)
        let request = requests.last(where: { $0.text == text }) ?? ChatSendRequest(text: text)
        onSendSettled?(.unwritten(ChatLedgerEntry(request: request, child: 1)))
    }
    /// The ledger's verdict on the request the test names.
    func settle(_ request: ChatSendRequest, _ make: (ChatLedgerEntry) -> ChatSendVerdict) { onSendSettled?(make(ChatLedgerEntry(request: request, child: 1))) }
    func deliver(_ request: ChatSendRequest) { settle(request) { .delivered($0, late: false) } }
    func interrupt() { interrupts += 1 }
    func stop(_ reason: ChatStopReason) {
        stops.append(reason)
        if turn == .running { turn = .none; onTurnEnded?(.interrupted); onChange?() }
    }
    /// Every `resume` call, in order; `resumeAccepts` is what it answers.
    var resumes: [(id: String, title: String)] = []
    var resumeAccepts = true
    /// The resume stops the old child, as the bridge's does: the turn state is `.stopping` until the test ends it.
    var resumeStops = false
    @discardableResult func resume(_ id: String, title: String) -> Bool {
        resumes.append((id, title))
        guard resumeAccepts else { return false }
        if resumeStops { turn = .stopping }
        sessionID = id
        transcript.appendResumed(title)
        onChange?()
        return true
    }
    /// The turn ends the way the bridge would end it.
    func finish(_ outcome: ChatTurnOutcome) { turn = .none; onTurnEnded?(outcome); onChange?() }
}

/// The chat's focus seams (Sprint 3e) as a test supplies them: every request is recorded and nothing reaches the system. The next-turn queue,
/// the deadline timers, the active state, the frontmost application and the session's latest mouse-down are the test's to set.
@MainActor
final class FakeChatFocus {
    /// The clock the controller runs on (a rig's virtual clock); `pressAt` is an absolute time on it.
    var now: () -> TimeInterval = { 0 }
    let timers = ManualChatTimers()
    var frontmost: ChatAppRef? = ChatAppRef(pid: 4001, launchDate: Date(timeIntervalSince1970: 1_000))
    var activationRequests = 0, deactivationRequests = 0, finderRequests = 0
    var handBacks: [ChatAppRef] = []
    var active = false
    var acceptsHandBack = true, acceptsFinder = true
    var pressAt: TimeInterval?
    /// Called when a hand-back is asked, before it answers (a test reads what had happened by then).
    var onHandBack: (() -> Void)?
    /// Called when a deactivation is asked.
    var onDeactivate: (() -> Void)?
    var observers: [(handler: (ChatAppRef) -> Void, handle: ManualChatTimers.Handle)] = []
    /// The monitor of other applications' mouse-downs: the handlers installed and not cancelled, and which screen points are an exempt surface.
    var pressObservers: [(handler: (ChatOutsidePress) -> Void, handle: ManualChatTimers.Handle)] = []
    var surfaceOwner: (CGPoint) -> String? = { _ in nil }
    /// The frontmost application's label at the moment of a press (nil: Clawd, or unreadable).
    var frontLabel: String?
    /// The system's double-click interval, and whether the session's latest press went to one of Clawd's windows.
    var doubleClick: TimeInterval = 0.5
    var pressWentToClawd = true
    /// The window of the mouse-down still queued for one of Clawd's windows (Settings' peek; nil: none queued).
    var queuedPressWindow: NSWindow?
    /// How often a peek ran (production peeks the queue once for whether the latest press went to Clawd and once for the queued press's window),
    /// and what each does before it answers (a test models the nested event pass draining the main queue).
    private(set) var peekCalls = 0
    var onPeek: (() -> Void)?
    /// The activation policy the `SETTINGS open` line names, and whether some window of Clawd is key now.
    var policy = "accessory"
    var clawdKey = false
    /// The mouse buttons down now (`NSEvent.pressedMouseButtons`) and the pointer's place: `outsidePress` holds the button down at the press's
    /// place, `followUp(.up)` lets it go. `held: false` is a down whose handler runs after its up (the button is not down any more).
    var pressed = 0
    var pointer = CGPoint.zero
    var surfaceOwnerPid: Int32?
    func outsidePress(_ press: ChatOutsidePress, held: Bool = true) {
        if held { pressed |= press.button.bit; pointer = press.location }
        for entry in pressObservers where !entry.handle.cancelled { entry.handler(press) }
    }
    var livePressObservers: Int { pressObservers.filter { !$0.handle.cancelled }.count }
    /// The monitor of the dragged and up events of a press that is going on: the handlers installed and not cancelled.
    var followUpObservers: [(handler: (ChatPressFollowUp) -> Void, handle: ManualChatTimers.Handle)] = []
    var liveFollowUps: Int { followUpObservers.filter { !$0.handle.cancelled }.count }
    func followUp(_ kind: ChatPressFollowUp.Kind, _ location: CGPoint, button: ChatPressButton = .left) {
        pointer = location
        if kind == .up { pressed &= ~button.bit }
        for entry in followUpObservers where !entry.handle.cancelled { entry.handler(ChatPressFollowUp(kind: kind, button: button, location: location)) }
    }
    /// The drag probe's monitor: the handlers installed and not cancelled, what the drag pasteboard reports and how often it was read.
    var dragProbes: [(handler: (ChatDragProbeEvent) -> Void, handle: ManualChatTimers.Handle)] = []
    var dragBoard = ChatDragPasteboardState(changeCount: 0, hasFileURLs: false)
    private(set) var dragBoardReads = 0
    var liveDragProbes: Int { dragProbes.filter { !$0.handle.cancelled }.count }
    func dragEvent(_ kind: ChatDragProbeEvent.Kind, time: TimeInterval, at point: CGPoint? = nil) {
        if let point { pointer = point }
        if kind == .up { pressed &= ~1 }
        for entry in dragProbes where !entry.handle.cancelled { entry.handler(ChatDragProbeEvent(kind: kind, time: time)) }
    }
    private(set) var queue: [() -> Void] = []
    /// What the system's activation notification of another application does.
    func otherAppBecomesActive(_ app: ChatAppRef) { for entry in observers where !entry.handle.cancelled { entry.handler(app) } }
    var liveObservers: Int { observers.filter { !$0.handle.cancelled }.count }
    /// One main-queue turn: everything queued before it runs now, what that queues waits for the next.
    func drain() { let turn = queue; queue = []; turn.forEach { $0() } }
    var seams: ChatFocusSeams {
        var seams = ChatFocusSeams()
        seams.frontmost = { [unowned self] in self.frontmost }
        seams.requestActivation = { [unowned self] in self.activationRequests += 1 }
        seams.requestDeactivation = { [unowned self] in self.deactivationRequests += 1; self.onDeactivate?() }
        seams.handBack = { [unowned self] app in self.onHandBack?(); self.handBacks.append(app); return self.acceptsHandBack }
        seams.handBackToFinder = { [unowned self] in self.finderRequests += 1; return self.acceptsFinder }
        seams.isActive = { [unowned self] in self.active }
        seams.sessionPressAge = { [unowned self] in self.pressAt.map { self.now() - $0 } }
        seams.observeActivations = { [unowned self] handler in
            let handle = ManualChatTimers.Handle()
            self.observers.append((handler, handle))
            return handle
        }
        seams.observeOutsidePresses = { [unowned self] handler in
            let handle = ManualChatTimers.Handle()
            self.pressObservers.append((handler, handle))
            return handle
        }
        seams.observePressFollowUps = { [unowned self] handler in
            let handle = ManualChatTimers.Handle()
            self.followUpObservers.append((handler, handle))
            return handle
        }
        seams.observeDragProbe = { [unowned self] handler in
            let handle = ManualChatTimers.Handle()
            self.dragProbes.append((handler, handle))
            return handle
        }
        seams.dragPasteboard = { [unowned self] in self.dragBoardReads += 1; return self.dragBoard }
        seams.pressedButtons = { [unowned self] in self.pressed }
        seams.pointerLocation = { [unowned self] in self.pointer }
        seams.surfaceOwnerPidAt = { [unowned self] _ in self.surfaceOwnerPid }
        seams.surfaceOwnerAt = { [unowned self] point in self.surfaceOwner(point) }
        seams.frontmostLabel = { [unowned self] in self.frontLabel }
        seams.doubleClickInterval = { [unowned self] in self.doubleClick }
        seams.latestPressWentToClawd = { [unowned self] in self.peekCalls += 1; self.onPeek?(); return self.pressWentToClawd }
        seams.queuedPressWindow = { [unowned self] in self.peekCalls += 1; self.onPeek?(); return self.queuedPressWindow }
        seams.nextTurn = { [unowned self] block in self.queue.append(block) }
        seams.activationPolicy = { [unowned self] in self.policy }
        seams.clawdWindowIsKey = { [unowned self] in self.clawdKey }
        seams.deadlines = timers
        return seams
    }
}

/// A host for controller-level tests: it answers the controller's questions from fields and records what it was told.
final class FakeChatHost: ChatHost {
    var refusal: ChatRefusal?
    var rect: CGRect? = CGRect(x: 700, y: 100, width: 380, height: 480)
    var examActive = false
    var examRunning = false
    /// The visible frame the terminal panel is kept inside (nil: unknown).
    var visible: CGRect?
    /// Every display (nil: Clawd's display alone, the protocol's default).
    var screens: [ChatScreen]?
    var events: [String] = []
    func chatRefusal() -> ChatRefusal? { examActive ? .exam : refusal }
    func chatPlacement() -> CGRect? { rect }
    /// The terminal panel's placement for a size (nil: the default): a test that moves Clawd sets this to the real rule; otherwise `rect` at that size.
    var terminalPlacement: ((CGSize?) -> CGRect?)?
    func chatTerminalPlacement(size: CGSize?) -> CGRect? {
        if let terminalPlacement { return terminalPlacement(size) }
        return rect.map { placed in size.map { CGRect(origin: placed.origin, size: $0) } ?? placed }
    }
    func chatVisibleFrame() -> CGRect? { visible }
    func chatScreens() -> [ChatScreen] { screens ?? visible.map { [ChatScreen(frame: $0, visible: $0)] } ?? [] }
    /// Clawd's body window (nil: not on screen).
    var petFrame: CGRect?
    func chatPetBodyFrame() -> CGRect? { petFrame }
    var chatOverFullScreen: Bool { false }
    func chatDidOpen() { events.append("open") }
    func chatDidClose(render: Bool) { events.append("close render=\(render)") }
    func chatCloseMenu() { events.append("menu-close") }
    func chatExamActive() -> Bool { examActive }
    func chatExamBrowserRunning() -> Bool { examRunning }
    func chatTurnStarted() { events.append("turn-start") }
    func chatTurnEnded(_ outcome: ChatTurnOutcome) { events.append("turn-end \(outcome)") }
}

/// A controller on a fake host and a fake session, with the environment's chat fields counting.
@MainActor
final class ControllerRig {
    let host = FakeChatHost()
    let session = FakeChatSession()
    let timer: MenuFakeTimer
    let clock = VirtualClock()
    var logs: [String] = []
    var enabled = true
    var chatSettings = ChatSettings()
    var keys: [ChatPanel] = []
    var presented = 0, dismissed = 0, editMenus = 0
    var currentEvent: ChatCurrentEvent?
    /// Called inside the open's make-key call (a test feeds a FocusMonitor the key notification there).
    var onMakeKey: ((ChatPanel) -> Void)?
    let focus = FakeChatFocus()
    private(set) var controller: ChatController!

    init(web: ChatWebEnvironment? = nil, geometry: ChatGeometryStoring? = nil) {
        timer = MenuFakeTimer(clock: clock)
        focus.now = { [unowned self] in self.clock.now }
        let session = self.session
        let environment = RuntimeEnvironment(
            displays: { DisplaySet(all: []) }, pointer: { .zero }, aquaLogPath: { "/nonexistent" }, aquaRunning: { false },
            present: { [unowned self] _ in self.presented += 1 }, dismiss: { [unowned self] _ in self.dismissed += 1 },
            chatSession: { _ in session },
            chatMakeKey: { [unowned self] panel in self.keys.append(panel); self.onMakeKey?(panel) },
            chatCurrentEvent: { [unowned self] in self.currentEvent },
            chatTimer: { [unowned self] in self.timer },
            chatInstallEditMenu: { [unowned self] in self.editMenus += 1 },
            chatWeb: web, chatFocus: focus.seams, chatGeometry: geometry, clock: { [unowned self] in self.clock })
        controller = ChatController(host: host, environment: environment, enabled: { [unowned self] in self.enabled },
                                    settings: { [unowned self] in self.chatSettings }, log: { [unowned self] in self.logs.append($0) })
    }
    func lines(_ prefix: String) -> [String] { logs.filter { $0.hasPrefix(prefix) } }
    func open(at time: TimeInterval = 1) { controller.toggle(eventTime: time) }
    var view: ChatPanelView { controller.livePanel!.chatView }
    /// Types into the input as the user would (through the text system, so the cap and the delegate see it).
    func type(_ text: String) {
        view.inputView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func pressEnter(modifiers: NSEvent.ModifierFlags = []) {
        view.inputView.modifiers = { modifiers }
        view.inputView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }
    func pressEsc() { view.inputView.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
}

/// The real runtime with a fake bridge. The panel is never ordered on screen.
@MainActor
final class ChatRuntimeRig {
    let rig: RuntimeRig
    let session = FakeChatSession()
    let focus = FakeChatFocus()
    var machine: RuntimeMachine { rig.machine }
    var runtime: AgentRuntime { rig.runtime }
    var panel: ChatPanel? { rig.runtime.chatPanel }

    init(control: [String: Any]? = nil, virtual: Bool = false, withChat: Bool = true, prepare: ((RuntimeMachine) -> Void)? = nil) throws {
        let session = self.session
        let focus = self.focus
        rig = try RuntimeRig(control: control, virtual: virtual, prepare: { machine in
            if withChat { machine.chatSession = { _ in session } }
            machine.chatFocus = focus.seams
            prepare?(machine)
        })
        focus.now = { [unowned rig] in rig.virtualClock?.now ?? 0 }
    }
    func lines(_ prefix: String) -> [String] { rig.lines(prefix) }
    /// A first click and a second click (clickCount 2) on Clawd's body, as the real input path takes them.
    func doubleClick() throws {
        let point = try rig.points().body
        try rig.click(at: point, clicks: 1)
        try rig.click(at: try rig.points().body, clicks: 2)
    }
    func click(count: Int) throws { try rig.click(at: try rig.points().body, clicks: count) }
    func post(_ name: Notification.Name, _ object: Any?) { rig.center.post(name: name, object: object) }
}

/// The panel geometry as a rig remembers it: in memory, with the saves counted. `saved` is a version 1 absolute rect waiting to be migrated (what a file
/// written by an older build holds); `anchor` is the version 2 form, written by a commit or a migration.
final class MemoryChatGeometry: ChatGeometryStoring {
    var saved: CGRect?
    var anchor: ChatAnchor?
    /// Commits written (`saveAnchor`) and v1 files moved (`migrate`).
    var saves = 0
    var migrations = 0
    /// The persisted `maximized` flag and every value it was saved with.
    var maximized = false
    var maximizedSaves: [Bool] = []
    /// Every write answers false while set.
    var failWrites = false
    init(_ saved: CGRect? = nil, maximized: Bool = false, anchor: ChatAnchor? = nil) { self.saved = saved; self.maximized = maximized; self.anchor = anchor }
    func load() -> CGRect? { anchor == nil ? saved : nil }
    func loadAnchor() -> ChatAnchor? { anchor }
    func saveAnchor(_ anchor: ChatAnchor) -> Bool { if failWrites { return false }; self.anchor = anchor; saved = nil; saves += 1; return true }
    func migrate(to anchor: ChatAnchor) -> Bool { self.anchor = anchor; saved = nil; migrations += 1; return true }
    func loadMaximized() -> Bool { maximized }
    func saveMaximized(_ value: Bool) -> Bool { if failWrites { return false }; maximized = value; maximizedSaves.append(value); return true }
    /// The rect the committed anchor gives on a display whose visible frame is `visible`.
    func rect(in visible: CGRect) -> CGRect? { anchor.map { ChatPanelGeometry.resolve($0, in: visible) } }
}
