import AppKit
import ClawdCore

/// Marks the panel's text views: neither builds a context menu (F1.2), and the audit requires the mark.
public protocol ChatNoContextMenu: AnyObject {
    /// A menu somebody assigned to the view (the view itself answers nil for its `menu` and for `menu(for:)`); the audit requires nil.
    var assignedMenu: NSMenu? { get }
}

/// The cap of the input (F1.4): it never holds more than 1 MiB of UTF-8.
public enum ChatInputCap {
    public static let bytes = 1024 * 1024
    /// Whether replacing `range` of `current` with `replacement` leaves the input within the cap.
    public static func accepts(current: String, range: NSRange, replacement: String) -> Bool {
        let whole = current as NSString
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: whole.length))
        let removed = whole.substring(with: safe).utf8.count
        return current.utf8.count - removed + replacement.utf8.count <= bytes
    }
}

/// The transcript: selectable, not editable, no links, no context menu. Cmd+C and Cmd+A work in it.
public final class ChatTranscriptTextView: NSTextView, ChatNoContextMenu {
    public private(set) var assignedMenu: NSMenu?
    public override var menu: NSMenu? { get { nil } set { assignedMenu = newValue } }
    public override func menu(for event: NSEvent) -> NSMenu? { nil }
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": copy(nil); return true
        case "a": selectAll(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

/// The arrow keys the composer's history takes.
public enum ChatHistoryKey { case up, down }

/// The keys the `/` picker takes while it shows (Orca NC/use-native-chat-composer-keydown.ts:66-95). Esc is the controller's (Q11).
public enum ChatPickerKey { case up, down, tab, enter }

/// The input: Enter sends, Shift+Enter and Option+Enter insert a newline, Esc closes; while an input method is composing (marked text) Enter
/// and Esc are the input method's and do nothing here. No autocorrect, smart quotes, smart dashes or text replacement; a 1 MiB cap.
public final class ChatInputTextView: NSTextView, ChatNoContextMenu {
    public private(set) var assignedMenu: NSMenu?
    public override var menu: NSMenu? { get { nil } set { assignedMenu = newValue } }
    /// The web chat's composer gives the input Orca's two-item menu (Copy, Paste); the stream view's input has none.
    public var providesContextMenu = false
    /// The destination of a file drag over the input (the web chat's body): the input forwards every call about a file drag to it and keeps
    /// the drags of text for itself, as Orca's textarea does.
    public weak var fileDropTarget: ChatWebBody?
    private var forwardingFileDrag = false
    /// Cmd+V and the menu's Paste: true when the paste was an image taken as a file (the pasteboard had no text).
    public var imagePaste: (() -> Bool)?
    /// An insertion, a commit or a mark ended: the attachment queue may apply.
    public var onCompositionEvent: (() -> Void)?
    public var onSend: (() -> Void)?
    /// The conversation id the menu offers to copy (nil: no item), and the item's action (Q19).
    public var sessionID: (() -> String?)?
    public var onCopySessionID: (() -> Void)?
    /// Cmd+Enter (Orca NC/use-native-chat-composer-keydown.ts:102-114): it answers whether it took the chord. The controller steers the newest queued
    /// card when the draft is empty and has no chips; otherwise the chord is an ordinary Enter.
    public var onSteerChord: (() -> Bool)?
    public var onEscape: (() -> Void)?
    /// Up or Down arrow outside a composition (Orca's history recall, NC/use-native-chat-composer-keydown.ts:115-133). It answers whether it took
    /// the key; when it did not, the key moves the caret as it always did.
    public var onHistory: ((ChatHistoryKey) -> Bool)?
    /// Up, Down, Tab and Enter outside a composition while the `/` picker shows. It answers whether it took the key. It runs before the history,
    /// so an open picker owns the arrows (Q7, Q10); Enter and Tab reach it with any modifier, as in Orca.
    public var onPickerKey: ((ChatPickerKey) -> Bool)?
    /// The text, the caret, the selection or the marked range changed (the picker follows the text before the caret).
    public var onAutocompleteInput: (() -> Void)?
    /// An insertion that would take the input over the cap was refused whole.
    public var onOverCap: (() -> Void)?
    /// The modifier keys of the event being handled (a test supplies its own).
    public var modifiers: () -> NSEvent.ModifierFlags = { NSApp.currentEvent?.modifierFlags ?? [] }

    /// Orca's chat menu (native-chat/use-native-chat-context-menu.tsx:116-198): Copy, enabled while the input has a selection, and Paste. It is
    /// built per request; the assigned `menu` stays nil.
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard providesContextMenu else { return nil }
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copy.target = self
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copy.isEnabled = selectedRange().length > 0
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        paste.target = self
        paste.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        menu.addItem(copy); menu.addItem(paste)
        for item in ChatSessionIDMenu.items(for: sessionID?(), target: self, action: #selector(copySessionIDItem)) { menu.addItem(item) }
        return menu
    }

    @objc func copySessionIDItem() { onCopySessionID?() }

    /// The titles of the menu a right-click would show, separators left out (nil: it shows none). The panel audit requires exactly Copy and Paste,
    /// with Copy Session ID after them once a session exists, or nothing.
    public var contextMenuTitles: [String]? {
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
        return menu(for: event)?.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    public override func paste(_ sender: Any?) {
        if imagePaste?() == true { return }
        super.paste(sender)
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onCompositionEvent?()
    }

    // MARK: file drags (P2 B1)

    public override var acceptableDragTypes: [NSPasteboard.PasteboardType] { super.acceptableDragTypes + ChatDropContent.registeredTypes }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let target = fileDropTarget, ChatDropContent.carriesFiles(sender.draggingPasteboard) {
            forwardingFileDrag = true
            return target.fileDragEntered(sender)
        }
        forwardingFileDrag = false
        return super.draggingEntered(sender)
    }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if forwardingFileDrag, let target = fileDropTarget { return target.fileDragUpdated(sender) }
        return super.draggingUpdated(sender)
    }
    public override func draggingExited(_ sender: NSDraggingInfo?) {
        if forwardingFileDrag, let target = fileDropTarget { forwardingFileDrag = false; target.fileDragExited(sender); return }
        super.draggingExited(sender)
    }
    public override func draggingEnded(_ sender: NSDraggingInfo) {
        if forwardingFileDrag, let target = fileDropTarget { forwardingFileDrag = false; target.fileDragEnded(sender); return }
        super.draggingEnded(sender)
    }
    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let target = fileDropTarget, ChatDropContent.carriesFiles(sender.draggingPasteboard) { return target.fileDragPrepare(sender) }
        return super.prepareForDragOperation(sender)
    }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let target = fileDropTarget, ChatDropContent.carriesFiles(sender.draggingPasteboard) { forwardingFileDrag = false; return target.fileDragPerform(sender) }
        return super.performDragOperation(sender)
    }
    public override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let target = fileDropTarget, let sender, ChatDropContent.carriesFiles(sender.draggingPasteboard) { target.fileDragConclude(sender); return }
        super.concludeDragOperation(sender)
    }

    /// The grey words shown while the input is empty (and no input method is composing); the web chat's composer sets its own.
    public static let placeholder = "Message Claude Code (Enter to send)"
    public var placeholderText = ChatInputTextView.placeholder
    public var placeholderColor = NSColor.placeholderTextColor
    /// The text changed (typed, pasted, or set): the composer around the input re-measures its height.
    public var onTextChanged: (() -> Void)?
    public var isPlaceholderShown: Bool { string.isEmpty && !hasMarkedText() }

    public override func didChangeText() { super.didChangeText(); needsDisplay = true; onTextChanged?(); onAutocompleteInput?() }
    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        onAutocompleteInput?()
    }
    public override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange); needsDisplay = true
        onCompositionEvent?()
        onAutocompleteInput?()
    }
    public override func unmarkText() { super.unmarkText(); needsDisplay = true; onCompositionEvent?(); onAutocompleteInput?() }
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isPlaceholderShown else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholderText as NSString).draw(at: origin, withAttributes: [.font: font ?? ChatPanelRender.body, .foregroundColor: placeholderColor])
    }

    public override func doCommand(by selector: Selector) {
        let enter = selector == #selector(NSResponder.insertNewline(_:)), escape = selector == #selector(NSResponder.cancelOperation(_:))
        if hasMarkedText() && (enter || escape) { return }   // the input method commits or cancels its composition; nothing is sent or closed
        // Enter reaches the picker with any modifier, as in Orca (NC/use-native-chat-composer-keydown.ts:78-89 has no shiftKey check): Shift+Enter on a
        // fully typed command sends it. Option+Enter is a different selector (insertNewlineIgnoringFieldEditor) and inserts the line.
        if !hasMarkedText(), let onPickerKey {
            if selector == #selector(NSResponder.moveUp(_:)), onPickerKey(.up) { return }
            if selector == #selector(NSResponder.moveDown(_:)), onPickerKey(.down) { return }
            if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)), onPickerKey(.tab) { return }
            if enter, onPickerKey(.enter) { return }
        }
        if enter, modifiers().isDisjoint(with: [.shift, .option]) {
            if modifiers().contains(.command), onSteerChord?() == true { return }
            onSend?()
            return
        }
        if escape { onEscape?(); return }
        if !hasMarkedText(), let onHistory {
            if selector == #selector(NSResponder.moveUp(_:)), onHistory(.up) { return }
            if selector == #selector(NSResponder.moveDown(_:)), onHistory(.down) { return }
        }
        super.doCommand(by: selector)
    }

    public override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let replacementString, !ChatInputCap.accepts(current: string, range: affectedCharRange, replacement: replacementString) {
            onOverCap?()
            return false
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    /// The standard edit keys, handled here so they work whether or not the application's Edit menu is dispatched to an inactive app.
    public func handleEditKey(_ key: String, shift: Bool) -> Bool {
        switch key.lowercased() {
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": paste(nil)
        case "a": selectAll(nil)
        case "z": if shift { undoManager?.redo() } else { undoManager?.undo() }
        default: return false
        }
        return true
    }
    /// Cmd+Enter has no text-system binding, and a Command chord reaches a view as a key equivalent: it goes to the same `insertNewline:` path as
    /// Enter, with the Command flag the path reads. The standard edit keys are handled here too.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Keypad Enter (76) carries the numeric-pad flag. A repeat of a held chord is taken and does nothing: it is not a second request (Q12).
        if (event.keyCode == 36 || event.keyCode == 76), flags.subtracting(.numericPad) == [.command], !hasMarkedText() {
            if event.isARepeat { return true }
            doCommand(by: #selector(NSResponder.insertNewline(_:)))
            return true
        }
        guard window?.firstResponder === self, !hasMarkedText(), event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        return handleEditKey(key, shift: event.modifierFlags.contains(.shift)) || super.performKeyEquivalent(with: event)
    }
}

/// What the controller drives on the panel's text surface: the stream kind's `ChatPanelView` and the web kind's `ChatWebBody` (the web
/// transcript over the native composer) both answer it, so the send, stop, draft and status paths are one.
public protocol ChatPanelSurface: AnyObject {
    var inputView: ChatInputTextView { get }
    var inputText: String { get set }
    var onSend: (() -> Void)? { get set }
    var onStop: (() -> Void)? { get set }
    var statusText: String { get }
    func setStatus(_ text: String)
    func setInputLocked(_ locked: Bool)
    func setConversation(_ entries: [ChatEntry], turn: ChatTurnState)
}

/// The panel's content: a header (title and the close control), the transcript, a "new output" marker, the input and the Send or Stop control.
/// AppKit only (no SwiftUI), manual layout, 380 pt wide.
public final class ChatPanelView: NSView {
    public static let width: CGFloat = 380
    static let headerHeight: CGFloat = 30
    static let footerPad: CGFloat = 8
    static let buttonHeight: CGFloat = 26
    static let lineHeight: CGFloat = 17
    /// The input is at least two lines high.
    static let inputMinHeight: CGFloat = lineHeight * 2 + 8

    public let transcriptView: ChatTranscriptTextView
    public let inputView: ChatInputTextView
    private let transcriptScroll = NSScrollView()
    private let inputScroll = NSScrollView()
    private let title = NSTextField(labelWithString: "Claude Code")
    private let status = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "✕", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let newOutput = NSButton(title: "↓ new output", target: nil, action: nil)
    private var inputLocked = false
    private var turn: ChatTurnState = .none

    public var onSend: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onClose: (() -> Void)?

    public override var isFlipped: Bool { false }
    public override var wantsUpdateLayer: Bool { true }

    public init(height: CGFloat) {
        transcriptView = Self.makeText(ChatTranscriptTextView.self)
        inputView = Self.makeText(ChatInputTextView.self)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        wantsLayer = true
        layer?.cornerRadius = 10; layer?.masksToBounds = true
        layer?.borderWidth = 0.5

        transcriptView.isEditable = false; transcriptView.isSelectable = true
        transcriptView.textContainerInset = NSSize(width: 8, height: 6)
        transcriptView.setAccessibilityLabel("Conversation")
        inputView.isEditable = true; inputView.isSelectable = true
        inputView.font = ChatPanelRender.body
        inputView.textContainerInset = NSSize(width: 4, height: 4)
        inputView.setAccessibilityLabel("Message to Claude Code")
        inputView.setAccessibilityPlaceholderValue(ChatInputTextView.placeholder)
        inputView.onSend = { [weak self] in self?.onSend?() }
        for scroll in [transcriptScroll, inputScroll] {
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
            scroll.drawsBackground = false; scroll.borderType = .noBorder
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
        }
        transcriptScroll.documentView = transcriptView
        inputScroll.documentView = inputView
        inputScroll.wantsLayer = true
        inputScroll.layer?.cornerRadius = 6; inputScroll.layer?.borderWidth = 1

        title.font = .systemFont(ofSize: 12, weight: .semibold); title.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        for button in [closeButton, sendButton, stopButton, newOutput] {
            button.target = self
            button.bezelStyle = .rounded
        }
        closeButton.bezelStyle = .inline; closeButton.isBordered = false
        closeButton.action = #selector(closePressed); closeButton.setAccessibilityLabel("Close chat")
        sendButton.action = #selector(sendPressed); sendButton.setAccessibilityLabel("Send message")
        stopButton.action = #selector(stopPressed); stopButton.setAccessibilityLabel("Stop Claude")
        newOutput.action = #selector(scrollToEnd); newOutput.bezelStyle = .inline
        newOutput.setAccessibilityLabel("Show new output")
        newOutput.isHidden = true; stopButton.isHidden = true
        for sub in [transcriptScroll, inputScroll, title, status, closeButton, sendButton, stopButton, newOutput] { addSubview(sub) }
        applyTurn()
    }
    public required init?(coder: NSCoder) { fatalError("ChatPanelView is built in code") }

    static func makeText<T: NSTextView>(_ type: T.Type) -> T {
        let view = T(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.isRichText = false; view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.usesFindBar = false
        return view
    }

    // MARK: state shown

    /// The draft in the input.
    public var inputText: String {
        get { inputView.string }
        set { inputView.string = newValue; inputView.needsDisplay = true; needsLayout = true }
    }
    public func setConversation(_ entries: [ChatEntry], turn: ChatTurnState) { setTranscript(entries); setTurn(turn) }
    public var isInputLocked: Bool { inputLocked }
    public var isSendEnabled: Bool { sendButton.isEnabled }
    /// While the opening's activation is refused (Sprint 3e item 2) the header says how to type.
    public func setActivationHint(_ shown: Bool) { title.stringValue = shown ? "Click here to type" : "Claude Code" }
    /// The header text as shown (for the tests).
    public var headerText: String { title.stringValue }
    public var sendTitle: String { sendButton.title }
    public var isStopVisible: Bool { !stopButton.isHidden }
    public var statusText: String { status.stringValue }
    public var isNewOutputShown: Bool { !newOutput.isHidden }
    /// Whether the transcript is scrolled to its end (within a point).
    public var isAtBottom: Bool {
        let visible = transcriptScroll.contentView.bounds
        return visible.maxY >= transcriptView.frame.height - 2
    }
    /// True when any rendered character carries a link attribute (F1.2: URLs stay plain text).
    public var transcriptHasLink: Bool {
        guard let storage = transcriptView.textStorage, storage.length > 0 else { return false }
        var found = false
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// Shows the entries. Auto-scrolls only while the view was at the bottom; scrolled up it shows a "new output" marker instead of jumping.
    public func setTranscript(_ entries: [ChatEntry]) {
        // An empty transcript (the open) has nothing to be scrolled away from: it follows.
        let follow = isAtBottom || transcriptView.textStorage?.length == 0
        let text = ChatPanelRender.render(entries)
        transcriptView.textStorage?.setAttributedString(text)
        transcriptView.layoutManager?.ensureLayout(for: transcriptView.textContainer!)
        layoutTranscriptDocument()
        if follow { scrollToEnd(); newOutput.isHidden = true }
        else {
            // The marker is for output that arrived out of sight: the user is scrolled up and the text is taller than the viewport.
            let viewport = transcriptScroll.contentSize.height
            newOutput.isHidden = !(viewport > 0 && transcriptView.frame.height > viewport + 2)
        }
    }

    public func setStatus(_ text: String) { status.stringValue = text }

    public func setTurn(_ new: ChatTurnState) { turn = new; applyTurn() }

    /// Enter locks the input (dimmed, not editable) until the bridge accepts the send or it fails.
    public func setInputLocked(_ locked: Bool) {
        inputLocked = locked
        inputView.isEditable = !locked
        inputScroll.alphaValue = locked ? 0.5 : 1
        applyTurn()
    }

    private func applyTurn() {
        switch turn {
        case .none: sendButton.title = "Send"
        case .running: sendButton.title = "Claude is working"
        case .stopping: sendButton.title = "Claude is stopping"
        }
        sendButton.isEnabled = turn == .none && !inputLocked
        stopButton.isHidden = turn != .running
        needsLayout = true
    }

    @objc private func closePressed() { onClose?() }
    @objc private func sendPressed() { onSend?() }
    @objc private func stopPressed() { onStop?() }
    @objc public func scrollToEnd() {
        transcriptView.scrollToEndOfDocument(nil)
        newOutput.isHidden = true
    }

    // MARK: layout

    private func layoutTranscriptDocument() {
        guard let layout = transcriptView.layoutManager, let container = transcriptView.textContainer else { return }
        let used = layout.usedRect(for: container).height + transcriptView.textContainerInset.height * 2
        let height = max(used, transcriptScroll.contentSize.height)
        transcriptView.setFrameSize(NSSize(width: transcriptScroll.contentSize.width, height: height))
    }

    private func inputHeight() -> CGFloat {
        guard let layout = inputView.layoutManager, let container = inputView.textContainer else { return Self.inputMinHeight }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height + inputView.textContainerInset.height * 2
        return min(max(used, Self.inputMinHeight), Self.lineHeight * 6 + 8)
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, pad = Self.footerPad
        let input = inputHeight()
        let footer = pad + input + pad + Self.buttonHeight + pad
        title.frame = NSRect(x: pad + 2, y: h - Self.headerHeight + 6, width: w - 80, height: 18)
        closeButton.frame = NSRect(x: w - 30, y: h - Self.headerHeight + 3, width: 24, height: 24)
        let transcriptTop = h - Self.headerHeight
        transcriptScroll.frame = NSRect(x: 0, y: footer, width: w, height: max(0, transcriptTop - footer))
        newOutput.frame = NSRect(x: w - 108, y: footer + 4, width: 100, height: 20)
        inputScroll.frame = NSRect(x: pad, y: pad + Self.buttonHeight + pad, width: w - pad * 2, height: input)
        status.frame = NSRect(x: pad, y: pad + 4, width: w - 200, height: 16)
        stopButton.frame = NSRect(x: w - pad - 190, y: pad, width: 60, height: Self.buttonHeight)
        sendButton.frame = NSRect(x: w - pad - 124, y: pad, width: 124, height: Self.buttonHeight)
        layoutTranscriptDocument()
    }

    /// The input box against the panel's `windowBackgroundColor`: a lifted fill and a 1 pt accent border, in light and in dark mode.
    static var inputBackground: NSColor { NSColor.labelColor.withAlphaComponent(0.10) }
    static var inputBorder: NSColor { NSColor.controlAccentColor }
    public var inputBackgroundColor: CGColor? { inputScroll.layer?.backgroundColor }
    public var inputBorderColor: CGColor? { inputScroll.layer?.borderColor }
    public var inputBorderWidth: CGFloat { inputScroll.layer?.borderWidth ?? 0 }
    public var panelBackgroundColor: CGColor? { layer?.backgroundColor }
    public var inputHeightNow: CGFloat { inputScroll.frame.height }

    public override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        inputScroll.layer?.backgroundColor = Self.inputBackground.cgColor
        inputScroll.layer?.borderColor = Self.inputBorder.cgColor
    }
    public override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

extension ChatPanelView: ChatPanelSurface {}
