import AppKit
import ClawdCore

/// The one window of the agent that may become key (spec F1.2, invariant I-6b): the chat panel of one opening. It is created when the chat
/// opens and dropped when it closes, so a late notification of a closed opening's window can never be taken for the live one.
///
/// Activating (Sprint 3e: an ordinary window of an active application while the user uses it), never main, floating, in every Space, with no
/// title bar controls of its own (the close control is a button in the content).
/// `canBecomeKey` is true only between `allowKey()` (the open call) and `disallowKey()` (the first step of every close). The make-key calls in
/// Sources are `makeKeyForOpening()` below and the Settings window's own (SettingsWindow.swift, the second file of the lint row `make-key`).
public final class ChatPanel: NSPanel {
    /// Both kinds activate (Sprint 3e item 1): there is no `.nonactivatingPanel` bit, and the audit refuses a panel that has it.
    public static let style: NSWindow.StyleMask = [.borderless]
    public static let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

    /// The number of the opening this window belongs to.
    public let gen: Int
    public let chatView: ChatPanelView
    /// What the terminal kind holds in `chatView`: one shared view that is never installed (the stream kind's content is not used there).
    public static let placeholderView = ChatPanelView(height: 100)
    /// The container kinds' content (nil for the stream kind): a header above Clawd's terminal view, or above the web chat's body.
    public let terminal: ChatTerminalContainer?
    /// What the controller types into and reads back: the web chat's body, else the stream view (the terminal kind never uses it).
    public var surface: ChatPanelSurface {
        if let web = terminal?.webBody { return web }
        return chatView
    }
    private var keyAllowed = false
    /// The mouse-downs of Clawd's windows (the controller sets it at the open) and this panel's own latest left mouse-down.
    public var presses: WindowPressLog?
    public private(set) var lastLeftMouseDown: TimeInterval?

    public override var canBecomeKey: Bool { keyAllowed }
    public override var canBecomeMain: Bool { false }
    public var isKeyAllowed: Bool { keyAllowed }

    /// Wired by the controller: Esc anywhere in the panel closes it (the input handles its own Esc, with the marked-text rule).
    public var onEscape: (() -> Void)?
    /// Cmd+W on the container kinds (reason `shortcut`): wired by the controller.
    public var onCloseShortcut: (() -> Void)?

    /// The stream kind takes `view`; the terminal kind takes `terminal` and keeps `view` as an unused placeholder.
    public init(overFullScreen: Bool, gen: Int, view: ChatPanelView, terminal: ChatTerminalContainer? = nil) {
        self.gen = gen
        chatView = view
        self.terminal = terminal
        super.init(contentRect: NSRect(origin: .zero, size: terminal?.frame.size ?? view.frame.size),
                   styleMask: Self.style, backing: .buffered, defer: true)
        hidesOnDeactivate = false
        isFloatingPanel = true; level = .floating
        collectionBehavior = Self.behavior
        if overFullScreen { collectionBehavior.insert(.fullScreenAuxiliary) }
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        animationBehavior = .none; isExcludedFromWindowsMenu = true; isReleasedWhenClosed = false
        if let terminal { contentView = terminal } else { contentView = view }
        setAccessibilityLabel("Claude Code chat")
    }

    /// Records a mouse-down the panel received, before any view sees it (Sprint 3e item 3).
    public func recordMouseDown(at time: TimeInterval, left: Bool) {
        presses?.record(time)
        if left { lastLeftMouseDown = time }
    }
    /// Called before the panel handles any mouse-down: a recalled panel (P12) gets its key right here, before AppKit decides what the click does.
    public var onMouseDown: (() -> Void)?
    /// Called for a mouse-down that did not land in the web chat's page (the composer's, the header's): the page never sees those, so its link
    /// popover is closed from here.
    public var onPressOutsideWeb: (() -> Void)?
    /// What `sendEvent` does with an event before any view sees it: the press is recorded, then the controller's hook runs.
    public func noteMouseDown(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: recordMouseDown(at: event.timestamp, left: true)
        case .rightMouseDown, .otherMouseDown: recordMouseDown(at: event.timestamp, left: false)
        default: return
        }
        onMouseDown?()
        if let web = terminal?.webBody?.page?.view, web.window === self, !web.bounds.contains(web.convert(event.locationInWindow, from: nil)) {
            onPressOutsideWeb?()
        }
    }
    public override func sendEvent(_ event: NSEvent) {
        noteMouseDown(event)
        super.sendEvent(event)
    }

    /// While the opening's activation is refused the header says how to type (Sprint 3e item 2).
    public func setActivationHint(_ shown: Bool) {
        if let terminal { terminal.setActivationHint(shown) } else { chatView.setActivationHint(shown) }
    }
    /// The header text as shown (for the tests).
    public var headerText: String { terminal?.headerText ?? chatView.headerText }

    public func allowKey() { keyAllowed = true }
    public func disallowKey() { keyAllowed = false }

    /// Puts the input in front of the keyboard: typed keys and a dictation paste land in it (never in a button or the transcript).
    public func focusInput() {
        if let terminal {
            if let view = terminal.terminalView { makeFirstResponder(view) } else if let input = terminal.webBody?.inputView { makeFirstResponder(input) }
        } else {
            makeFirstResponder(chatView.inputView)
        }
    }

    /// The panel's own keys on the container kinds, taken before the view or the menu (spec T-4): Cmd+W closes (key code 13 with exactly the
    /// Command flag, not by its characters, which a kana direct-input source changes); Cmd+Option+O (key code 31) is taken and does nothing, so
    /// SwiftTerm never toggles `optionAsMetaKey` and Option+yen keeps typing a backslash. Only key-downs reach this method.
    /// On the web kind Cmd+C (key code 8) copies the page's selection when the native input has none: the web view never takes the keyboard,
    /// so without this the key would only ever reach the input.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let terminal else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if event.keyCode == 13, flags == [.command] { onCloseShortcut?(); return true }
        if event.keyCode == 31, flags == [.command, .option] { return true }
        if event.keyCode == 8, flags == [.command], let web = terminal.webBody, web.inputView.selectedRange().length == 0 {
            web.copyPageSelection()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc with no text view in the chain (focus on a button or the transcript).
    public override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// Makes this window key. Called once per opening, by the open call, and only after `allowKey()`; and by Settings' close, which puts the key
    /// back on an open chat through the environment's `chatMakeKey` (the second caller; the key goes to the chat as a return).
    public func makeKeyForOpening() {
        guard keyAllowed else { return }
        makeKey()
    }
}

/// The static check of everything the chat panel's contract lists (F1.2). Empty means the contract holds. It runs before every open: a
/// violation refuses the open, so a non-conforming panel is never shown.
public enum ChatPanelAudit {
    public static func violations(of panel: ChatPanel, overFullScreenAllowed: Bool = false) -> [String] {
        var found: [String] = []
        if panel.canBecomeMain { found.append("canBecomeMain is true") }
        if panel.canBecomeKey { found.append("canBecomeKey is true before the open") }
        if panel.hidesOnDeactivate { found.append("hidesOnDeactivate is true") }
        if panel.level != .floating { found.append("level is not floating") }
        if panel.styleMask.contains(.nonactivatingPanel) { found.append("styleMask has nonactivatingPanel (the chat panel activates)") }
        if let terminal = panel.terminal { found += terminal.auditProblems() }
        let allowedStyle: NSWindow.StyleMask = [.borderless, .titled, .fullSizeContentView]
        if !panel.styleMask.subtracting(allowedStyle).isEmpty { found.append("styleMask has a bit outside borderless, titled, fullSizeContentView") }
        if panel.styleMask.contains(.closable) { found.append("styleMask is closable") }
        if panel.styleMask.contains(.miniaturizable) { found.append("styleMask is miniaturizable") }
        if panel.styleMask.contains(.resizable) { found.append("styleMask is resizable") }
        for flag in [NSWindow.CollectionBehavior.canJoinAllSpaces, .stationary, .ignoresCycle]
        where !panel.collectionBehavior.contains(flag) { found.append("collectionBehavior lacks \(flag.rawValue)") }
        if !overFullScreenAllowed, panel.collectionBehavior.contains(.fullScreenAuxiliary) { found.append("fullScreenAuxiliary set") }
        if panel.isReleasedWhenClosed { found.append("isReleasedWhenClosed is true") }
        if panel.animationBehavior != .none { found.append("animationBehavior is not none") }
        if let terminal = panel.terminal {
            if panel.contentView !== terminal { found.append("the content view is not the terminal container") }
        } else if panel.contentView !== panel.chatView { found.append("the content view is not the chat view") }
        if String(describing: type(of: panel.contentView as Any)).contains("Hosting") { found.append("the content is a hosting view") }
        for (name, text) in (panel.terminal != nil ? [] : [("transcript", panel.chatView.transcriptView), ("input", panel.chatView.inputView)]) as [(String, NSTextView)] {
            if text.isAutomaticLinkDetectionEnabled { found.append("\(name) link detection is on") }
            if text.isAutomaticDataDetectionEnabled { found.append("\(name) data detection is on") }
            if (text as? ChatNoContextMenu)?.assignedMenu != nil || !(text is ChatNoContextMenu) { found.append("\(name) has a context menu") }
            if text.delegate?.responds(to: NSSelectorFromString("textView:clickedOnLink:atIndex:")) == true { found.append("\(name) handles link clicks") }
        }
        if panel.terminal == nil, panel.chatView.transcriptHasLink { found.append("a link attribute is in the rendered transcript") }
        return found
    }
}

/// What a notification's cause looked like when it was taken: the current event of the application, reduced to what the focus rule asks.
public struct ChatCurrentEvent {
    /// A LEFT mouse-down only: the chat's causes read it.
    public var isMouseDown: Bool
    /// The button of any mouse-down in hand (left, right or other); nil for every other event. Settings' cause (b) and the status menu's trace
    /// read it; `isMouseDown` above stays left-only.
    public var mouseDownButton: ChatPressButton?
    public var window: NSWindow?
    /// Any mouse event (a mouse report the terminal view sends is not a key).
    public var isMouse: Bool
    /// The device-independent modifier flags of the event.
    public var modifiers: NSEvent.ModifierFlags
    /// The event's own timestamp: one key event counts one key however many sends it makes. Nil for an event built without one.
    public var timestamp: TimeInterval?
    public init(isMouseDown: Bool, window: NSWindow?, isMouse: Bool? = nil, modifiers: NSEvent.ModifierFlags = [], timestamp: TimeInterval? = nil,
                mouseDownButton: ChatPressButton? = nil) {
        self.isMouseDown = isMouseDown; self.window = window; self.isMouse = isMouse ?? (isMouseDown || mouseDownButton != nil)
        self.modifiers = modifiers; self.timestamp = timestamp
        self.mouseDownButton = mouseDownButton ?? (isMouseDown ? .left : nil)
    }
    public init(_ event: NSEvent) {
        let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let down: ChatPressButton?
        switch event.type {
        case .leftMouseDown: down = .left
        case .rightMouseDown: down = .right
        case .otherMouseDown: down = .other
        default: down = nil
        }
        self.init(isMouseDown: event.type == .leftMouseDown, window: event.window, isMouse: mouse.contains(event.type),
                  modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask), timestamp: event.timestamp, mouseDownButton: down)
    }
}

/// The Edit menu the accessory app needs so the standard key equivalents work: Undo, Redo, Cut, Copy, Paste, Select All. Never visible (the
/// app is never active); no Quit, Hide or window items.
public enum ChatEditMenu {
    public static func make() -> NSMenu {
        let main = NSMenu(title: "Main")
        let holder = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        func item(_ title: String, _ action: Selector, _ key: String, shift: Bool = false) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = shift ? [.command, .shift] : [.command]
            edit.addItem(entry)
        }
        item("Undo", Selector(("undo:")), "z")
        item("Redo", Selector(("redo:")), "z", shift: true)
        edit.addItem(.separator())
        item("Cut", #selector(NSText.cut(_:)), "x")
        item("Copy", #selector(NSText.copy(_:)), "c")
        item("Paste", #selector(NSText.paste(_:)), "v")
        item("Select All", #selector(NSText.selectAll(_:)), "a")
        holder.submenu = edit
        main.addItem(holder)
        return main
    }
    public static func install() {
        if NSApp.mainMenu == nil { NSApp.mainMenu = make() }
    }
}
