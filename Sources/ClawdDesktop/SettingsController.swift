import AppKit
import ClawdCore
import ClawdRendering

/// What opened Settings; the raw value is the `cause=` of the `SETTINGS open` line.
public enum SettingsOpenCause: String, Equatable { case statusMenu = "status-menu", rightClick = "right-click", request }

/// Why Settings closed; the raw value is the `reason=` of the `SETTINGS close` line.
public enum SettingsCloseReason: String, CaseIterable, Equatable { case button, shortcut, esc, exam, quit, restart }

/// What the window shows, as the runtime reads it at the moment of a refresh.
public struct SettingsValues: Equatable {
    /// General's state line: one short line, empty while Settings is about to close (an exam stand-down).
    public var stateLine: String
    /// Hidden by the user (`hiddenUntil` is -1 or in the future).
    public var hiddenByUser: Bool
    /// The chat's working folder as control.json holds it (the reader's default, the home folder, when unset).
    public var chatFolder: String
    /// What the pet runs with for Look, Motion and Bubble: the values the right-click menu shows as selected.
    public var selection: MenuSelection
    /// Chat with Claude Code is on (`chat`; on unless set off).
    public var chatEnabled: Bool
    /// The model as the pet runs with it; empty means Claude Code's own default.
    public var chatModel: String
    public var chatPermissions: ChatPermissions
    /// Clawd shows over full-screen apps as control.json holds it (`overFullScreen`; restart-only, so it is what the next start will do).
    public var overFullScreen: Bool
    /// Voice: the running pet reads the dictation app's log (`aquaReact` as the pet started with it; restart-only), follows the app (the mode it
    /// resolved at its start is `follow`) and control.json holds `auto`.
    public var aquaReact: Bool
    public var aquaFollow: Bool
    public var aquaAutomatic: Bool
    public init(stateLine: String = "", hiddenByUser: Bool = false, chatFolder: String = "", selection: MenuSelection = MenuSelection(),
                chatEnabled: Bool = true, chatModel: String = "", chatPermissions: ChatPermissions = .deny,
                aquaReact: Bool = true, aquaFollow: Bool = false, aquaAutomatic: Bool = false, overFullScreen: Bool = false) {
        self.stateLine = stateLine; self.hiddenByUser = hiddenByUser; self.chatFolder = chatFolder; self.selection = selection
        self.chatEnabled = chatEnabled; self.chatModel = chatModel; self.chatPermissions = chatPermissions; self.overFullScreen = overFullScreen
        self.aquaReact = aquaReact; self.aquaFollow = aquaFollow; self.aquaAutomatic = aquaAutomatic
    }
}

/// What Settings needs from the runtime that owns the scheduler, the writer and the chat.
public protocol SettingsHost: AnyObject {
    /// The visible frame of the display Settings goes on: the one holding `point`, else Clawd's display; nil when no display is attached.
    func settingsVisibleFrame(around point: CGPoint?) -> CGRect?
    /// The exam stand-down is in force, or a LockDown Browser application runs now.
    func settingsExamBlocked() -> Bool
    func settingsValues() -> SettingsValues
    /// Runs a CLI verb through the shared writer and returns the pick's number; the completion is called on the main queue, never for a pick a
    /// newer pick replaced.
    /// `onStart` runs on the main queue just before the pick's child is spawned; false means the pick does not run and completes as a CLI that
    /// could not be run.
    /// `restarts`: the row restarts the agent. A refusal means nothing was queued: the completion and `onStart` are never called.
    func settingsSubmit(_ action: MenuAction, restarts: Bool, onStart: (() -> Bool)?,
                        completion: @escaping (MenuResult) -> Void) -> (id: Int, refusal: MenuRefusal?)
    /// The pick is still running or waiting in the writer.
    func settingsHolds(_ pick: Int) -> Bool
    /// The chat panel while it is open and may take key; nil when none.
    func settingsChatPanelForKey() -> ChatPanel?
    /// Settings is opening: a chat hand-back still in flight ends.
    func settingsWillOpen()
    /// The idle frame of the plain look for the sidebar's header.
    func settingsIcon() -> NSImage?
    /// Every look of the catalog, in order, with the right-click menu's picture of it.
    func settingsLooks() -> [SettingsLookTile]
    /// The state folder's path (About shows it).
    func settingsStateFolder() -> String
    /// Where the chat finds `claude` now (Claude Code's line shows it): the same check the chat makes before a spawn, and Q6's search.
    func settingsClaudeLocation() -> ChatSettings.ClaudeLocation
    /// Whether the dictation app is installed and its version (Voice's Status line): read at an open and at an apply, never at a scheduler batch.
    func settingsVoiceStatus() -> SettingsVoiceStatus
    /// Quit Clawd: stops the chat child and exits. Settings has closed already.
    func settingsQuit()
    /// A restart-only pick is about to run: leaves `$ROOT/open-settings` for the restarted pet (origin `settings-restart`, this pid, the clocks, the
    /// section) and returns the line it wrote. Nil when it could not be written; the verb then does not run.
    func settingsWriteRestartRequest(section: SettingsSection) -> String?
    /// The CLI returned to this process: the restart did not happen, so the request is removed, but only while the file still holds `line`.
    func settingsRemoveRestartRequest(ifLine line: String)
}

/// The Settings window's rules (design 4.4, 4.5): when it opens and closes, which opening a notification belongs to, what asks for Clawd's
/// activation and who may take it, and what each row writes. Closed, it owns no window, view, observer or timer.
public final class SettingsController {
    /// How long the open's cause lasts: the chat's own deadline.
    public static let causeWindow: TimeInterval = ChatController.activationDeadline
    public static let handbackDeadline: TimeInterval = ChatController.handbackDeadline
    /// How long a mouse-down Settings' window recorded still counts as the cause of an activation: the chat's click window.
    public static let clickWindow: TimeInterval = ChatController.clickWindow

    public private(set) var generation = 0
    public var isOpen: Bool { current != nil }
    public var liveGeneration: Int? { current?.gen }
    /// The open window (nil while closed): for the tests and the attended checks.
    public var window: SettingsWindow? { current?.window }
    public var content: SettingsContent? { current?.content }
    /// The section shown now (nil while closed).
    public var section: SettingsSection? { current?.content.section }
    /// The application the close will hand activation back to (nil: none recorded).
    public var handBackTarget: ChatAppRef? { current?.target }
    /// Whether an open's one-shot cause is armed (expired or not): it ends at the first step of every close.
    public var causeIsArmed: Bool { live?.cause != nil }

    private unowned let host: SettingsHost
    private let environment: RuntimeEnvironment
    private let focus: ChatFocusSeams
    private let clock: PetClock
    private let log: (String) -> Void
    private let claimed: () -> Bool
    /// Records a violation the controller judged late (a key that waited for its activation); wired by the runtime.
    public var lateViolation: (() -> Void)?
    /// Whether the focus monitor's activation step is running now; wired by the runtime.
    public var activationStepRunning: () -> Bool = { false }
    private var editMenuInstalled = false
    private var handbackSteps: ChatTimerHandle?

    /// The one-shot cause of an open (design 4.5 (a)): spent by the window's first key and by Clawd's first activation, gone after a second.
    private struct Cause {
        var armedAt: TimeInterval
        var keyUsed = false
        var activationUsed = false
    }

    /// A restart-only pick's request, as the pick wrote it when it started: the line is what the pick's completion may remove.
    private final class RestartRun {
        let key: String
        var line: String?
        init(key: String) { self.key = key }
    }

    private final class Opening {
        var gen: Int
        let window: SettingsWindow
        let content: SettingsContent
        var cause: Cause?
        var causeDeadline: ChatTimerHandle?
        /// The application to hand activation back to: the one in front when Settings first opened, then the last other application activated
        /// while it is open (a reopen never overwrites it with Clawd or with nothing).
        var target: ChatAppRef?
        /// Other applications' activations while the window is open; ends at the first step of the close.
        var observer: ChatTimerHandle?
        /// When Clawd last resigned: a recorded mouse-down counts as a cause only when it is newer.
        var lastResign: TimeInterval?
        /// Clawd's activation is claimed by this window.
        var active = false
        var willBecome = false
        var pendingKeys = 0
        /// What the window's first responder was when a key began to wait, to put back on an exempt verdict.
        var gateSaved: NSResponder?
        /// The text selection of a field the gate took the keyboard from.
        var gateSelection: NSRange?
        var gated = false
        /// The close has begun: nothing answers for this opening any more, though the seams of the close still see it.
        var closing = false
        /// This window's restart-only pick while it runs (from its start until its completion).
        var restartRun: RestartRun?
        var picker: ChatAttachHandle?
        var pickerPresenting = false
        /// The shown state of each row's control.
        var shown: SettingsShown
        /// The newest pick of each row; one the writer no longer holds is over (it finished, or a newer pick replaced it).
        var picks: [SettingsRow: Int] = [:]
        /// The rows an apply left alone because their pick was still in the writer: their control shows the pick, not what the pet runs with, until
        /// the pick's exit 0 re-syncs it (another writer's write of the same key may have landed in between).
        var carried: Set<SettingsRow> = []
        init(gen: Int, window: SettingsWindow, content: SettingsContent, shown: SettingsShown) {
            self.gen = gen; self.window = window; self.content = content; self.shown = shown
        }
    }
    private var live: Opening?
    /// The open window unless its close is under way: every entry point answers for this one.
    private var current: Opening? { guard let opening = live, !opening.closing else { return nil }; return opening }

    public init(host: SettingsHost, environment: RuntimeEnvironment, claimed: @escaping () -> Bool, log: @escaping (String) -> Void) {
        self.host = host; self.environment = environment; self.claimed = claimed; self.log = log
        focus = environment.chatFocus; clock = environment.clock()
    }

    // MARK: opening and closing

    /// The user's action that opens Settings: the menu bar icon's pick (`point` is where the pointer was, the display it goes on) or the
    /// right-click menu's (`point` nil: Clawd's display). A second open while it is open brings the same window forward again.
    public func begin(cause: SettingsOpenCause, at point: CGPoint? = nil, section: SettingsSection = .general) {
        if host.settingsExamBlocked() { log("SETTINGS refuse reason=exam"); return }
        // A hand-back still in flight must not deactivate Clawd under the window being opened, whether or not this open asks for an activation.
        handbackSteps?.cancel(); handbackSteps = nil
        host.settingsWillOpen()
        guard let visible = host.settingsVisibleFrame(around: point) else { log("SETTINGS refuse reason=no-display"); return }
        let opening: Opening
        if let existing = current {
            opening = existing
            existing.causeDeadline?.cancel()
            // A reopen shows what the pet runs with and ends every write still waiting (a write that straddles it is dropped).
            refreshRows(existing, keepingQueued: false)
        } else {
            let values = host.settingsValues()
            let placement = SettingsGeometry.frame(visible: visible, titleBar: SettingsWindow.titleBarHeight)
            let window = SettingsWindow(contentSize: placement.content)
            let content = SettingsContent(values: values, icon: host.settingsIcon(), sections: SettingsSection.listed, looks: host.settingsLooks(),
                                          drawnStyles: StageRuntime.drawnBubbleStyles, stateFolder: host.settingsStateFolder())
            window.contentView = content.root
            window.initialFirstResponder = content.initialFirstResponder
            window.makeFirstResponder(content.initialFirstResponder)
            window.setFrame(placement.frame, display: false)
            if let first = SettingsWindowAudit.violations(of: window).first {
                log("SETTINGS contract-violation \(first)")
                return
            }
            window.onClose = { [weak self] reason in self?.close(reason) }
            window.onClickMovedFocus = { [weak self] _ in self?.current?.content.commitModel() }
            content.delegate = self
            opening = Opening(gen: 0, window: window, content: content, shown: SettingsShown(values))
            // A first open knows who is in front; a reopen keeps the first record.
            opening.target = focus.frontmost()
            opening.observer = focus.observeActivations { [weak self] app in self?.otherAppActivated(app) }
            live = opening
            refreshClaudeLine(opening)
            opening.content.setVoiceStatus(host.settingsVoiceStatus())
            if !editMenuInstalled { environment.chatInstallEditMenu(); editMenuInstalled = true }
        }
        generation += 1
        opening.gen = generation
        opening.content.show(section)
        log("SETTINGS open policy=\(focus.activationPolicy()) cause=\(cause.rawValue) section=\(opening.content.section.rawValue)")
        // A reopen after a restart arms no cause: the user's cause was spent in the old process.
        if cause != .request { opening.cause = Cause(armedAt: clock.now) }
        opening.window.allowKey()
        environment.settingsPresent(opening.window)
        if cause == .request {
            // Shown and not made key, and no activation is asked for: the window takes key only on a click, or as a return once another surface
            // has claimed Clawd's activation.
            return
        }
        environment.settingsMakeKey(opening.window)
        if focus.isActive() {
            // No activation can come: `activate` posts nothing for an active application, so nothing waits and nothing is refused.
            opening.cause?.activationUsed = true
        } else {
            requestActivation(opening)
        }
    }

    /// The open's one request, with its deadline: an activation that is not delivered in a second was refused.
    private func requestActivation(_ opening: Opening) {
        let gen = opening.gen
        focus.requestActivation()
        opening.causeDeadline = focus.deadlines.after(Self.causeWindow) { [weak self] in
            guard let self, let current = self.current, current === opening, current.gen == gen else { return }
            current.causeDeadline = nil
            guard !current.active else { return }
            self.log("SETTINGS activate-refused")
        }
    }

    /// Closes the window: the folder picker comes down first, then every cause ends, then the key right, then the window goes off screen, then
    /// activation is handed back. A late completion of the picker or of a write reaches nothing of the next open.
    public func close(_ reason: SettingsCloseReason) {
        guard let opening = current else { return }
        opening.closing = true
        log("SETTINGS close reason=\(reason.rawValue)")
        opening.picker?.cancel(); opening.picker = nil
        opening.pickerPresenting = false
        opening.observer?.cancel(); opening.observer = nil
        opening.cause = nil
        opening.causeDeadline?.cancel(); opening.causeDeadline = nil
        opening.window.disallowKey()
        environment.settingsDismiss(opening.window)
        live = nil
        opening.window.onClose = nil
        opening.window.onClickMovedFocus = nil
        opening.content.delegate = nil
        handBack(from: opening, reason: reason)
    }

    /// An apply came while keys are pending that only a restart applies. The window closes (picker first) only while this window's own restart-only
    /// pick runs and the pending keys include that pick's key: the CLI restarts the agent next. Any other apply refreshes the rows.
    public func restartApplied(keys: [String]) {
        if let run = current?.restartRun, keys.contains(run.key) { close(.restart) } else { settingsApplied() }
    }

    /// The end of a scheduler batch: a stand-down closes Settings; otherwise the state line follows the scheduler.
    public func batchEnded(standDown: Bool) {
        guard live != nil else { return }
        if standDown { close(.exam); return }
        refreshStateLine()
    }

    /// A settings generation was applied: every control shows what the pet runs with now, except a row whose pick the writer still holds. That
    /// row keeps the state it was given and its pending mark until its pick completes or is dropped (the apply that came is another row's, as the
    /// CLI exits only after it). A pick the right-click menu replaced is no longer held, so its row ends pending here.
    public func settingsApplied() {
        guard let opening = current else { return }
        refreshRows(opening, keepingQueued: true)
    }

    private func refreshRows(_ opening: Opening, keepingQueued: Bool) {
        let values = host.settingsValues()
        let held = keepingQueued ? Set(opening.picks.filter { host.settingsHolds($0.value) }.keys) : []
        opening.picks = opening.picks.filter { held.contains($0.key) }
        opening.carried = held
        var shown = SettingsShown(values)
        for row in held { shown.carry(row, from: opening.shown) }
        opening.shown = shown
        opening.content.refresh(values, shown: shown)
        opening.content.endPending(except: held)
        refreshClaudeLine(opening)
        opening.content.setVoiceStatus(host.settingsVoiceStatus())
    }

    /// Claude Code's line under the chat's On and Off, from where the chat finds `claude` now (a stat of at most three places, at an open and at an
    /// apply, never at a scheduler batch).
    private func refreshClaudeLine(_ opening: Opening) {
        opening.content.setClaudeLine(SettingsClaudeLine.text(for: host.settingsClaudeLocation()))
    }

    /// A hand-back in flight ends (another surface opens).
    public func cancelHandBack() { handbackSteps?.cancel(); handbackSteps = nil }

    /// The state line alone, redrawn only when its text changed.
    private func refreshStateLine() {
        guard let opening = current else { return }
        opening.content.setStateLine(host.settingsValues().stateLine)
    }

    /// A display change: the rule of the window's size and place applies again, on the display it is on.
    public func displayChanged() {
        guard let opening = current else { return }
        let centre = CGPoint(x: opening.window.frame.midX, y: opening.window.frame.midY)
        guard let visible = host.settingsVisibleFrame(around: centre) else { return }
        let placement = SettingsGeometry.frame(visible: visible, titleBar: SettingsWindow.titleBarHeight)
        guard opening.window.frame != placement.frame else { return }
        opening.window.setFrame(placement.frame, display: false)
    }

    // MARK: the rows

    /// Runs a CLI verb for a row. The completion carries the open's number: after a close or a reopen it touches nothing.
    /// `prior` is the shown state just before the click that made this pick: a refusal puts the row back to it.
    private func run(_ action: MenuAction, row: SettingsRow, opening: Opening, prior: SettingsShown, restarts: Bool = false) {
        let gen = opening.gen
        opening.content.setPending(row, true, message: nil)
        // A restart-only row writes its request when its pick starts to run, not when it is submitted: a request ages from the moment it is
        // written, and a pick that waits behind another must not leave an old one. If the request cannot be written the verb does not run.
        let run = restarts ? RestartRun(key: action.key) : nil
        let section = opening.content.section
        let onStart: (() -> Bool)? = run.map { run in
            { [weak self, weak opening] in
                guard let self, let line = self.host.settingsWriteRestartRequest(section: section) else { return false }
                run.line = line
                opening?.restartRun = run
                return true
            }
        }
        // The writer keeps the completion until the pick runs: it must not keep a closed opening (its window and sections) alive meanwhile.
        let submitted = host.settingsSubmit(action, restarts: restarts, onStart: onStart) { [weak self, weak opening] result in
            // The CLI returned to this process, so the restart did not happen, whatever the exit code and whether or not the window is still up.
            // Only the request this pick wrote goes: a later pick may have left its own by now.
            if let run {
                if let line = run.line { self?.host.settingsRemoveRestartRequest(ifLine: line) }
                if opening?.restartRun === run { opening?.restartRun = nil }
            }
            guard let self, let opening, let current = self.current, current === opening, current.gen == gen else { return }
            self.completed(row, result, opening: current)
        }
        if let refusal = submitted.refusal {
            // Nothing was queued and no completion will come. The row goes back to what it showed before this click: its own earlier pick's state
            // while the writer still holds that pick, else what the pet runs with. The earlier pick's later completion replaces this line.
            let values = host.settingsValues()
            if opening.picks[row].map({ host.settingsHolds($0) }) ?? false {
                var shown = opening.shown
                shown.carry(row, from: prior)
                opening.shown = shown
            } else {
                opening.shown.revert(row, to: values)
            }
            opening.content.refresh(values, shown: opening.shown)
            opening.content.setPending(row, false, message: refusal.text)
            return
        }
        opening.picks[row] = submitted.id
    }

    private func completed(_ row: SettingsRow, _ result: MenuResult, opening: Opening) {
        switch result.exit {
        case 0?:
            opening.content.setPending(row, false, message: nil)
            resync(row, in: opening)
        case 3?:
            // Saved, but the pet did not confirm in time: the new value stays.
            opening.content.setPending(row, false, message: "saved, pending")
        default:
            // The write failed: that row's control goes back to what the pet runs with (the others keep the state they were given), and the
            // CLI's one line says why.
            let values = host.settingsValues()
            opening.shown.revert(row, to: values)
            opening.content.refresh(values, shown: opening.shown)
            opening.content.setPending(row, false, message: result.text.isEmpty ? "Clawd could not save that" : result.text)
        }
    }

    /// A row's verb exited 0: the pet has applied it. If an apply came while the pick was held (the row's control was left showing the pick), the
    /// control shows what the pet runs with now, once: a concurrent write of the same key by another writer is then not hidden behind the pick. A
    /// newer pick of the same row still in the writer keeps the control as it is until that pick completes.
    private func resync(_ row: SettingsRow, in opening: Opening) {
        guard opening.carried.contains(row), !(opening.picks[row].map { host.settingsHolds($0) } ?? false) else { return }
        opening.carried.remove(row)
        let values = host.settingsValues()
        opening.shown.revert(row, to: values)
        opening.content.refresh(values, shown: opening.shown)
    }

    // MARK: focus: keys

    /// The focus monitor asks about a key notification. Settings answers only for its own windows: the window itself and, while it is up, its folder
    /// picker and any sheet on it. Exempt only with a cause: the open's one-shot cause, a mouse-down inside the window, the picker, or a return
    /// inside an activation that is claimed. A key that comes between `willBecomeActive` and `didBecomeActive` waits for that activation.
    public func keyVerdict(for window: NSWindow?) -> ChatKeyVerdict? {
        guard let opening = current, let window else { return nil }
        if opening.pickerPresenting || isPickerWindow(window, of: opening) {
            log("SETTINGS picker-key")
            return .exempt
        }
        guard window === opening.window, opening.window.isKeyAllowed else { return nil }
        let event = environment.chatCurrentEvent()
        if causeIsLive(opening), opening.cause?.keyUsed == false {
            opening.cause?.keyUsed = true
            log("SETTINGS key")
            return exempt(opening)
        }
        if event?.mouseDownButton != nil, event?.window === opening.window {
            log("SETTINGS key")
            return exempt(opening)
        }
        if (opening.active || claimed()) && focus.isActive() {
            // The OS's own key changes inside the active application: one with a user event is the user's, one without is a return.
            log(event != nil ? "SETTINGS key" : "SETTINGS key-returned")
            return exempt(opening)
        }
        if opening.willBecome {
            opening.pendingKeys += 1
            hold(opening)
            let gen = opening.gen
            focus.nextTurn { [weak self] in
                // A peek inside the activation step may run this turn early; the step's exit judges the key then.
                guard let self, let current = self.current, current === opening, current.gen == gen, !self.activationStepRunning() else { return }
                current.willBecome = false
                self.resolvePendingKeys(current, exempt: false)
            }
            return .deferred
        }
        log("SETTINGS key-uncaused")
        return .uncaused
    }

    private func exempt(_ opening: Opening) -> ChatKeyVerdict {
        release(opening)
        return .exempt
    }

    private func causeIsLive(_ opening: Opening) -> Bool {
        guard let cause = opening.cause else { return false }
        return clock.now - cause.armedAt < Self.causeWindow
    }

    /// The input gate: while a key waits for its verdict the window is its own first responder, so no text view takes a typed key or a paste.
    private func hold(_ opening: Opening) {
        guard !opening.gated else { return }
        opening.gated = true
        let responder = opening.window.firstResponder
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            // A field being edited ends editing without committing: its text stays in the field, and the field (not its editor) is put back.
            opening.gateSaved = field
            opening.gateSelection = editor.selectedRange
        } else {
            opening.gateSaved = responder
            opening.gateSelection = nil
        }
        opening.window.makeFirstResponder(nil)
    }

    /// An exempt verdict puts back the first responder the window had.
    private func release(_ opening: Opening) {
        guard opening.gated else { return }
        opening.gated = false
        let saved = opening.gateSaved, selection = opening.gateSelection
        opening.gateSaved = nil; opening.gateSelection = nil
        guard let saved, opening.window.firstResponder !== saved else { return }
        opening.window.makeFirstResponder(saved)
        if let selection, let editor = (saved as? NSControl)?.currentEditor() {
            editor.selectedRange = NSRange(location: min(selection.location, (editor.string as NSString).length), length: 0)
        }
    }

    /// The keys that waited for an activation are judged now: exempt with a claimed activation, else uncaused.
    private func resolvePendingKeys(_ opening: Opening, exempt: Bool) {
        guard opening.pendingKeys > 0 else { return }
        let count = opening.pendingKeys
        opening.pendingKeys = 0
        for _ in 0..<count {
            if exempt {
                log("SETTINGS key")
                release(opening)
            } else {
                log("SETTINGS key-uncaused")
                lateViolation?()
            }
        }
    }

    /// Whether `window` is the folder picker that is up, or a window (a sheet) whose parent chain reaches it.
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

    // MARK: focus: activation

    /// `willBecomeActive`: a key that follows is judged with the activation that follows.
    public func appWillBecomeActive() { current?.willBecome = true }

    /// `didResignActive`: Clawd's activation is no longer this window's.
    public func appResigned() {
        guard let opening = current else { return }
        opening.active = false
        opening.lastResign = clock.now
    }

    /// Another application became active while Settings is open: it is the hand-back target now, as for the chat (no line). Clawd itself never is,
    /// and neither is a surface that gives the activation straight back (the screenshot UI, an input method, dictation).
    private func otherAppActivated(_ app: ChatAppRef) {
        guard let opening = current, app.pid != ProcessInfo.processInfo.processIdentifier, !ChatController.isExempt(bundleID: app.bundleID) else { return }
        opening.target = app
    }

    /// The claim step: is this activation Settings'? Mine with a cause, or not mine; declining changes nothing here.
    public func activationClaim() -> Bool {
        guard let opening = current else { return false }
        if opening.pickerPresenting || opening.picker != nil {
            // The picker activates Clawd when it opens.
            claim(opening, cause: "picker")
            return true
        }
        if causeIsLive(opening), opening.cause?.activationUsed == false {
            opening.cause?.activationUsed = true
            opening.causeDeadline?.cancel(); opening.causeDeadline = nil
            claim(opening, cause: "open")
            return true
        }
        let event = environment.chatCurrentEvent()
        if event?.mouseDownButton != nil {
            // A mouse-down in hand is this activation's cause: Settings' own is its click, another window's is that window's.
            guard event?.window === opening.window else { return false }
            claim(opening, cause: "click", via: "hand")
            return true
        }
        // AppKit may handle the activation before the click on this window is the event in hand: the window's own record of its last left
        // mouse-down, or a mouse-down still queued for this window, is the same click. The queue is peeked only after a recent press of the
        // session, as the chat does, so an activation with no press never runs the nested event pass.
        if clickRecorded(opening) {
            claim(opening, cause: "click", via: "recorded")
            return true
        }
        if pressIsRecent(opening) && focus.queuedPressWindow() === opening.window {
            claim(opening, cause: "click", via: "peek")
            return true
        }
        return false
    }

    /// A press of the session newer than the last resign, within the click window, that went to one of Clawd's windows (the chat's gate for its peek).
    private func pressIsRecent(_ opening: Opening) -> Bool {
        guard let age = focus.sessionPressAge(), age >= 0, age <= Self.clickWindow, focus.latestPressWentToClawd() else { return false }
        return clock.now - age > (opening.lastResign ?? -.infinity)
    }

    /// A mouse-down this window received within the click window and after Clawd last resigned.
    private func clickRecorded(_ opening: Opening) -> Bool {
        guard let time = opening.window.lastLeftMouseDown else { return false }
        let now = clock.now
        return time <= now && now - time <= Self.clickWindow && time > (opening.lastResign ?? -.infinity)
    }

    private func claim(_ opening: Opening, cause: String, via: String? = nil) {
        opening.active = true
        opening.willBecome = false
        log("SETTINGS active cause=\(cause)" + (via.map { " via=\($0)" } ?? ""))
        resolvePendingKeys(opening, exempt: true)
    }

    /// Another surface claimed Clawd's activation: it is lawful, so a key that waited on it is a return.
    public func activationClaimedElsewhere() {
        guard let opening = current else { return }
        opening.willBecome = false
        resolvePendingKeys(opening, exempt: true)
    }

    /// No surface claimed the activation: the keys that waited for it were uncaused.
    public func activationUnclaimed() {
        guard let opening = current else { return }
        opening.willBecome = false
        resolvePendingKeys(opening, exempt: false)
    }

    // MARK: focus: hand-back

    /// The close's end: while Clawd is active, activation goes back; nothing while it is not. With the chat open and Clawd itself in front at the
    /// open, nothing is handed back and the key goes to the chat; with another application in front, to it.
    private func handBack(from opening: Opening, reason: SettingsCloseReason) {
        guard focus.isActive() else { return }
        let deactivateOnly = reason == .exam
        if !deactivateOnly, opening.target == nil, let panel = host.settingsChatPanelForKey() {
            // Clawd stays active and the key goes back to the chat as a return, through the chat's own make-key call. If no Clawd window is key
            // on the next turn, the keyboard is not left with nobody: Clawd deactivates.
            environment.chatMakeKey(panel)
            focus.nextTurn { [weak self] in
                guard let self, self.focus.isActive(), !self.focus.clawdWindowIsKey() else { return }
                self.deactivateStep(finder: false)
            }
            return
        }
        if !deactivateOnly, let target = opening.target {
            log("SETTINGS handback")
            if focus.handBack(target) {
                handbackSteps = focus.deadlines.after(Self.handbackDeadline) { [weak self] in
                    guard let self else { return }
                    if self.focus.isActive() { self.deactivateStep(finder: true) } else { self.log("SETTINGS handback ok=1") }
                }
                return
            }
        }
        deactivateStep(finder: !deactivateOnly)
    }

    private func deactivateStep(finder: Bool) {
        log("SETTINGS deactivate")
        focus.requestDeactivation()
        handbackSteps = focus.deadlines.after(Self.handbackDeadline) { [weak self] in
            guard let self else { return }
            if !self.focus.isActive() { self.log("SETTINGS deactivate ok=1"); return }
            guard finder else { self.log("SETTINGS handback-failed"); return }
            self.log("SETTINGS handback-finder")
            guard self.focus.handBackToFinder() else { self.log("SETTINGS handback-failed"); return }
            self.handbackSteps = self.focus.deadlines.after(Self.handbackDeadline) { [weak self] in
                guard let self else { return }
                if self.focus.isActive() { self.log("SETTINGS handback-failed") } else { self.log("SETTINGS handback-finder ok=1") }
            }
        }
    }
}

// MARK: what the window's controls ask

extension SettingsController: SettingsContentDelegate {
    func contentCommittedModel(_ text: String) {
        guard let opening = current, text != opening.shown.model else { return }
        // The verb comes from the field's own text (empty runs `chat model default`); the CLI validates it and its one line says why when it refuses.
        let prior = opening.shown
        opening.shown.model = text
        opening.content.modelCommitted(text)
        run(SettingsActions.model(text), row: .model, opening: opening, prior: prior)
    }

    func contentPressedHide() {
        guard let opening = current else { return }
        // The verb comes from the control's new shown state, never from the applied selection.
        let prior = opening.shown
        opening.shown.hidden.toggle()
        opening.content.refresh(host.settingsValues(), shown: opening.shown)
        run(opening.shown.hidden ? SettingsActions.hide : SettingsActions.show, row: .hide, opening: opening, prior: prior)
    }

    func contentPressedQuit() {
        close(.quit)
        host.settingsQuit()
    }

    func contentPressedChooseFolder() {
        guard let opening = current, opening.picker == nil, !opening.pickerPresenting else { return }
        log("SETTINGS picker open")
        var finished = false
        opening.pickerPresenting = true
        defer { opening.pickerPresenting = false }
        let handle = environment.settingsFolderPicker().present(startingAt: opening.shown.folder) { [weak self] path in
            finished = true
            guard let self, let current = self.current, current === opening else { return }
            current.picker = nil
            guard let path else { self.log("SETTINGS picker cancelled"); return }
            self.folderChosen(path, in: current)
        }
        if !finished { opening.picker = handle }
    }

    func contentSelected(_ section: SettingsSection) {
        guard let opening = current else { return }
        opening.content.show(section)
        // Showing Voice reads the dictation app's state again (one stat at a click, never at a scheduler batch).
        if section == .voice { opening.content.setVoiceStatus(host.settingsVoiceStatus()) }
    }

    private func folderChosen(_ path: String, in opening: Opening) {
        // While the activation's verdict is pending the picker's default button could have answered Return, so nothing is written.
        guard !opening.willBecome else { log("SETTINGS picker dropped"); return }
        let prior = opening.shown
        opening.shown.folder = path
        opening.content.refresh(host.settingsValues(), shown: opening.shown)
        run(SettingsActions.folder(path), row: .folder, opening: opening, prior: prior)
    }

    /// A control of Look, Motion or Bubble was pressed. A style that is not drawn yet takes no click, as in the right-click menu.
    func contentChose(_ choice: SettingsChoice) {
        guard let opening = current else { return }
        // Follow On while the switch shows off: the dictation app may have left since Voice was shown, so read it again before anything else.
        if choice == .follow(true), !opening.shown.follow { opening.content.setVoiceStatus(host.settingsVoiceStatus()) }
        guard opening.content.button(for: choice)?.isEnabled == true else { return }
        // The control shows its new state at once, and the verb comes from that state, never from the applied selection.
        let prior = opening.shown
        opening.shown.apply(choice)
        opening.content.refresh(host.settingsValues(), shown: opening.shown)
        run(SettingsActions.action(for: choice, shownOn: opening.shown.isOn(choice)), row: choice.row, opening: opening, prior: prior, restarts: choice.restartsPet)
    }
}

/// The CLI verbs the Settings sections run; the picks name their queue key (one per control.json key).
public enum SettingsActions {
    /// Hide and Show write `hiddenUntil`, so they share the queue key of the right-click menu's hide row and the icon's.
    public static var hide: MenuAction { StatusMenu.hideAction }
    public static var show: MenuAction { StatusMenu.showAction }
    /// A Look, Motion or Bubble choice: the right-click menu's verb for the same choice (MenuSelection.action) under the same queue key. A style
    /// chip's verb comes from `shownOn`, the chip's new shown state: on runs `include N`, off `exclude N`.
    public static func action(for choice: SettingsChoice, shownOn: Bool) -> MenuAction {
        switch choice {
        case .look(let id): return MenuAction(key: "look", value: id, queueKey: "look", arguments: ["look", id])
        case .every(let hours): return MenuAction(key: "every", value: "\(hours)h", queueKey: "every", arguments: ["look-every", "\(hours)h"])
        case .size(let word): return MenuAction(key: "size", value: word, queueKey: "size", arguments: ["size", word])
        case .motion(let level): return MenuAction(key: "motion", value: level.rawValue, queueKey: "motion", arguments: ["motion", level.rawValue])
        case .walk(let on): return MenuAction(key: "walk", value: on ? "on" : "off", queueKey: "walk", arguments: ["walk", on ? "on" : "off"])
        case .bubble(let on): return MenuAction(key: "bubble", value: on ? "on" : "off", queueKey: "bubble", arguments: ["bubble", on ? "on" : "off"])
        case .side(let side): return MenuAction(key: "side", value: side.rawValue, queueKey: "side", arguments: ["bubble", "side", side.rawValue])
        case .style(let n):
            return MenuAction(key: "style", value: String(n), queueKey: "style-\(n)", arguments: ["bubble", shownOn ? "include" : "exclude", String(n)])
        case .chat(let on): return MenuAction(key: "chat", value: on ? "on" : "off", queueKey: "chat", arguments: ["chat", on ? "on" : "off"])
        case .permissions(let mode):
            return MenuAction(key: "chatPermissions", value: mode.rawValue, queueKey: "chatPermissions", arguments: ["chat", "permissions", mode.rawValue])
        case .fullScreen(let on):
            return MenuAction(key: "overFullScreen", value: on ? "on" : "off", queueKey: "overFullScreen", arguments: ["full-screen", on ? "on" : "off"])
        case .react(let on):
            return MenuAction(key: "aquaReact", value: on ? "on" : "off", queueKey: "aquaReact", arguments: ["aqua", "react", on ? "on" : "off"])
        case .follow(let on):
            // The switch writes follow or ignore from its new shown state, never `auto`.
            return MenuAction(key: "aqua", value: on ? "follow" : "ignore", queueKey: "aqua", arguments: ["aqua", on ? "follow" : "ignore"])
        }
    }

    /// The Model field's text: empty means Claude Code's own default. The writer's log names the verb without the text.
    public static func model(_ text: String) -> MenuAction {
        MenuAction(key: "chatModel", value: "model", queueKey: "chatModel", arguments: text.isEmpty ? ["chat", "model", "default"] : ["chat", "model", text],
                   logVerb: "chat+model")
    }

    /// The chosen folder is a path: the writer's log names the verb without it.
    public static func folder(_ path: String) -> MenuAction {
        MenuAction(key: "chatFolder", value: "folder", queueKey: "chatFolder", arguments: ["chat", "folder", path], logVerb: "chat+folder")
    }
}
