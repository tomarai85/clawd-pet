import AppKit
import ClawdCore

/// The Settings window (design 4.1): titled and closable, never miniaturizable, resizable, main, restorable or full screen, so it can become key
/// and Clawd active with no Dock icon and no minimized tile. It is created when Settings opens and dropped when it closes.
///
/// `canBecomeKey` is true only between `allowKey()` (the open call) and `disallowKey()` (the first step of every close). The close button,
/// Cmd-W and Esc all end in the controller's close through `onClose`; the window never closes itself, and it goes on and off screen only through
/// the runtime environment's `settingsPresent` and `settingsDismiss`. The only make-key call of this file is `makeKeyForOpening()`.
public final class SettingsWindow: NSWindow {
    public static let style: NSWindow.StyleMask = [.titled, .closable]
    public static let behavior: NSWindow.CollectionBehavior = [.auxiliary, .moveToActiveSpace, .fullScreenNone]
    /// Q8: Settings stays light in dark mode. One constant; `nil` would follow the system.
    public static let forcedAppearance: NSAppearance.Name? = .aqua
    public static let title = "Clawd"

    private var keyAllowed = false
    /// When the window last received a left mouse-down (nil: none yet): cause (b)'s late-click record, as the chat panel's `lastLeftMouseDown`.
    public private(set) var lastLeftMouseDown: TimeInterval?
    /// Cmd-W, Esc and the close button, each with its reason; wired by the controller.
    public var onClose: ((SettingsCloseReason) -> Void)?
    /// A left mouse-down in this window moved the first responder away from a field editor (a click on another control while the Model field was
    /// being edited); wired by the controller. The responder is the one the click took the focus from.
    public var onClickMovedFocus: ((NSResponder) -> Void)?
    private let editor = SettingsFieldEditor.make()

    public override var canBecomeKey: Bool { keyAllowed }
    public override var canBecomeMain: Bool { false }
    public var isKeyAllowed: Bool { keyAllowed }

    /// The title bar's height, which the geometry rule subtracts from the visible frame.
    public static var titleBarHeight: Double {
        Double(NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: style).height) - 100
    }

    public init(contentSize: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: contentSize), styleMask: Self.style, backing: .buffered, defer: true)
        title = Self.title
        isRestorable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = Self.behavior
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        if let name = Self.forcedAppearance { appearance = NSAppearance(named: name) }
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        if let button = standardWindowButton(.closeButton) {
            button.target = self
            button.action = #selector(closeButtonPressed(_:))
        }
        setAccessibilityLabel("Clawd settings")
    }

    @objc private func closeButtonPressed(_ sender: Any?) { onClose?(.button) }

    /// Records a left mouse-down the window received, before any view sees it.
    public func recordMouseDown(at time: TimeInterval) { lastLeftMouseDown = time }

    /// What `sendEvent` does with an event before any view sees it: a left mouse-down is recorded at its own time stamp; no other event is.
    public func noteMouseDown(_ event: NSEvent) {
        if event.type == .leftMouseDown { recordMouseDown(at: event.timestamp) }
    }

    public override func sendEvent(_ event: NSEvent) {
        route(event) { super.sendEvent($0) }
    }

    /// Everything `sendEvent` does around AppKit's own dispatch, which it passes as `dispatch`. A test passes a dispatch that moves the first
    /// responder the way a view's mouse-down does: a synthetic event sent to an off-screen window reaches no view, and showing or keying a window
    /// is banned in tests (SA4 M-1).
    public func route(_ event: NSEvent, dispatch: (NSEvent) -> Void) {
        noteMouseDown(event)
        let before = event.type == .leftMouseDown ? firstResponder : nil
        dispatch(event)
        if let before { clickMoved(focusFrom: before) }
    }

    /// What a left mouse-down did to the first responder: if it left `before`, a field editor's click-away is reported. Only the window's own
    /// mouse-down path calls this, so a first responder that moves for any other reason (the input gate, a key to another window) reports nothing.
    public func clickMoved(focusFrom before: NSResponder) {
        guard before is SettingsFieldEditor, firstResponder !== before else { return }
        onClickMovedFocus?(before)
    }

    /// Every text field of Settings is edited in this window's own field editor, which takes the chat's text contract.
    public override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        object is NSTextField ? editor : super.fieldEditor(createFlag, for: object)
    }

    public func allowKey() { keyAllowed = true }
    public func disallowKey() { keyAllowed = false }

    /// Cmd-W (key code 13 with exactly the Command flag, not by its characters, which a kana direct-input source changes).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if event.keyCode == 13, flags == [.command] { onClose?(.shortcut); return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc with no text view in the chain that takes it.
    public override func cancelOperation(_ sender: Any?) { onClose?(.esc) }

    /// Makes this window key: the one make-key call of the file. Called once per open, by the open call, and only after `allowKey()`.
    public func makeKeyForOpening() {
        guard keyAllowed else { return }
        makeKey()
    }
}

/// The field editor of Settings' text fields: the chat's text contract (ChatPanelView.swift): no context menu; automatic completion, spelling
/// correction, and quote, dash and text substitutions off; Esc with marked text ends the composition and neither closes Settings nor commits.
public final class SettingsFieldEditor: NSTextView, ChatNoContextMenu {
    public private(set) var assignedMenu: NSMenu?
    public override var menu: NSMenu? { get { nil } set { assignedMenu = newValue } }
    public override func menu(for event: NSEvent) -> NSMenu? { nil }
    /// Inline completion is off whatever AppKit does when editing begins (it reads the system's own setting then and turns it back on).
    public override var isAutomaticTextCompletionEnabled: Bool { get { false } set {} }

    static func make() -> SettingsFieldEditor {
        let view = SettingsFieldEditor(frame: .zero)
        view.isFieldEditor = true
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.usesFindBar = false
        if #available(macOS 15.0, *) { view.writingToolsBehavior = .none }
        return view
    }

    public override func doCommand(by selector: Selector) {
        let enter = selector == #selector(NSResponder.insertNewline(_:)), escape = selector == #selector(NSResponder.cancelOperation(_:))
        // The input method commits or cancels its composition; nothing is committed or closed.
        if hasMarkedText() && (enter || escape) { return }
        // Esc with no composition is the window's own Esc: it closes Settings.
        if escape, let window { window.cancelOperation(self); return }
        super.doCommand(by: selector)
    }

    /// What breaks the contract, empty when it holds.
    public var contractViolations: [String] {
        var found: [String] = []
        if assignedMenu != nil || menu != nil { found.append("the field editor holds a context menu") }
        let probe = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)
        if let probe, menu(for: probe) != nil { found.append("the field editor builds a context menu") }
        let flags: [(String, Bool)] = [("automatic spelling correction", isAutomaticSpellingCorrectionEnabled), ("automatic quote substitution", isAutomaticQuoteSubstitutionEnabled),
                                       ("automatic dash substitution", isAutomaticDashSubstitutionEnabled), ("automatic text replacement", isAutomaticTextReplacementEnabled),
                                       ("continuous spell checking", isContinuousSpellCheckingEnabled),
                                       ("grammar checking", isGrammarCheckingEnabled), ("automatic link detection", isAutomaticLinkDetectionEnabled)]
        for (name, on) in flags where on { found.append("the field editor has \(name) on") }
        return found
    }
}

/// The static check of what the Settings window's contract lists (D19). Empty means the contract holds. It runs before every open: a
/// violation refuses the open, so a non-conforming window is never shown.
public enum SettingsWindowAudit {
    public static func violations(of window: SettingsWindow) -> [String] {
        var found: [String] = []
        if window.canBecomeMain { found.append("canBecomeMain is true") }
        if window.canBecomeKey { found.append("canBecomeKey is true before the open") }
        if window.hidesOnDeactivate { found.append("hidesOnDeactivate is true") }
        if window.isRestorable { found.append("isRestorable is true") }
        if window.isReleasedWhenClosed { found.append("isReleasedWhenClosed is true") }
        if window.styleMask.contains(.miniaturizable) { found.append("styleMask is miniaturizable") }
        if window.styleMask.contains(.resizable) { found.append("styleMask is resizable") }
        if window.styleMask.contains(.fullScreen) { found.append("styleMask has fullScreen") }
        if window.styleMask.contains(.nonactivatingPanel) { found.append("styleMask has nonactivatingPanel (the window activates)") }
        if !window.styleMask.contains(.titled) { found.append("styleMask is not titled") }
        for flag in [NSWindow.CollectionBehavior.auxiliary, .moveToActiveSpace, .fullScreenNone]
        where !window.collectionBehavior.contains(flag) { found.append("collectionBehavior lacks \(flag.rawValue)") }
        if window.collectionBehavior.contains(.fullScreenPrimary) { found.append("collectionBehavior has fullScreenPrimary") }
        if window.level != .normal { found.append("level is not normal") }
        if String(describing: type(of: window.contentView as Any)).contains("Hosting") { found.append("the content is a hosting view") }
        if let name = SettingsWindow.forcedAppearance, window.appearance?.name != name { found.append("the appearance is not forced to \(name.rawValue)") }
        // The text contract of the Model field (M-3): the window's one field editor.
        if let editor = window.fieldEditor(true, for: NSTextField()) as? SettingsFieldEditor { found += editor.contractViolations } else { found.append("the field editor is not Settings' own") }
        return found
    }
}
