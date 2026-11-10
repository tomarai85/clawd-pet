import AppKit
import ClawdCore
import SwiftTerm

/// Where Clawd's copy and paste read and write (spec R9.2 T-2, r10): the system pasteboard in production, a fake in the tests.
public protocol ChatPasteboardSource: AnyObject {
    func string() -> String?
    func setString(_ text: String)
    /// Writes `text` and says whether the pasteboard took it (the copy button shows its check only on success).
    func putString(_ text: String) -> Bool
}

public extension ChatPasteboardSource {
    func putString(_ text: String) -> Bool { setString(text); return true }
}

/// The production pasteboard source. Only `RuntimeEnvironment.production` names it.
public final class SystemChatPasteboard: ChatPasteboardSource {
    public init() {}
    public func string() -> String? { NSPasteboard.general.string(forType: .string) }
    public func setString(_ text: String) { _ = putString(text) }
    public func putString(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The only file that imports SwiftTerm (lint `swiftterm-import`). Clawd's subclass of SwiftTerm's `TerminalView`: its `copy(_:)` and `paste(_:)`
/// go through the injected pasteboard source (SwiftTerm's own use `NSPasteboard.general`), and the paste goes on through SwiftTerm's public
/// `pasteText`, which brackets the text while DECSET 2004 is on. It has no context menu. Every test builds this class, never `TerminalView`.
public final class ChatTerminalView: TerminalView {
    public var pasteboard: ChatPasteboardSource?
    public weak var chatDelegate: ChatTerminalDelegate?
    /// How many times `paste(_:)` went on to SwiftTerm's `pasteText` (a test's counting seam: a refused paste never gets there).
    public private(set) var pasteTextCalls = 0

    /// A menu somebody assigned; the view itself answers nil, and the audit requires nil here.
    public private(set) var assignedMenu: NSMenu?
    public override var menu: NSMenu? { get { nil } set { assignedMenu = newValue } }
    public override func menu(for event: NSEvent) -> NSMenu? { nil }

    public static let scrollback = 3_000
    /// Orca's cursor: a blinking block (the blink is SwiftTerm's own Core Animation opacity animation, which needs no timer).
    public static let cursorStyle: CursorStyle = .blinkBlock

    public override init(frame: CGRect) {
        super.init(frame: frame, font: ChatLook.terminalFont(), options: TerminalOptions(scrollback: Self.scrollback))
        configure()
    }
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        // Option is Meta only on keys that type nothing: Option+Return reaches Claude Code as Meta-Return, Option+arrows move by word, and a
        // character the user's layout puts behind Option (a backslash on a JIS keyboard) is typed as that character.
        optionAsMetaKey = false
        optionAsMetaKeyForFunctionalKeys = true
        setCursorStyle(Self.cursorStyle)
        allowMouseReporting = true
        scrollerStyle = .overlay
        applyLook(ChatLook.look(for: effectiveAppearance))
    }

    /// The look last applied (Orca's Ayu Dark or Orca Light colours), for the tests and the change check below.
    public private(set) var appliedLook: ChatLook?

    /// Applies `look`: the 16 ANSI colours, background, foreground, cursor and its text, and the selection. The font is set once at init.
    public func applyLook(_ look: ChatLook) {
        installColors(look.ansi.map { Color(red8: UInt16($0.r), green8: UInt16($0.g), blue8: UInt16($0.b)) })
        nativeBackgroundColor = look.background.color
        nativeForegroundColor = look.foreground.color
        caretColor = look.cursor.color
        caretTextColor = look.cursorText.color
        selectedTextBackgroundColor = look.selection.color
        appliedLook = look
    }

    /// Cmd+V and the Edit menu's Paste: the text of the injected pasteboard, counted and sent once. A paste the write queue has no room for is
    /// refused here, before SwiftTerm encodes anything.
    @objc public override func paste(_ sender: Any) {
        guard let text = pasteboard?.string(), !text.isEmpty else { return }
        guard chatDelegate?.pasteBegins(text) != false else { return }
        pasteTextCalls += 1
        pasteText(text)
        chatDelegate?.pasteEnded()
    }

    /// The terminal engine's own sends (replies to queries, focus and mouse reports) and Clawd's paste, which SwiftTerm's `pasteText` hands to the
    /// engine's send. SwiftTerm's version reaches the delegate's `send(source:data:)`, the input path, on a later main-queue turn. This one copies
    /// the bytes, reads nothing else (it can run off the main queue with the terminal lock held) and hands them to the main queue, where Clawd's
    /// delegate tells Clawd's paste (inside its bracket) from a reply by the bracket's markers, which share that queue.
    public nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        let captured = Array(data)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.chatDelegate?.engineSent(captured) }
        }
    }

    /// Cmd+C and the Edit menu's Copy: the selection to the injected pasteboard.
    @objc public override func copy(_ sender: Any) {
        pasteboard?.setString(getSelection() ?? "")
    }

    /// The screen's text, for the tests and nothing else (never logged).
    public var screenText: String { String(decoding: getBufferAsData(kind: .active), as: UTF8.self) }
}

/// Clawd's terminal delegate (spec R9.2 T-2, T-3, T-4): the bytes the view sends go to claude, a link opens nothing, the bell is silent, the
/// title feeds T-6 and the header, and the keys, pastes and pasted bytes of the opening are counted for the close line.
public final class ChatTerminalDelegate {
    /// Bytes for claude; false when the write queue refused them whole (a paste over 16 MiB).
    public var deliver: ([UInt8]) -> Bool = { _ in false }
    public var currentEvent: () -> ChatCurrentEvent? = { nil }
    public var titleChanged: (String) -> Void = { _ in }
    public var gridChanged: (Int, Int) -> Void = { _, _ in }
    public var refused: () -> Void = {}
    /// The bytes just sent, for the draft tracking and the output-free rules.
    public var sent: ([UInt8], Bool) -> Void = { _, _ in }
    /// What the write queue can still take, in bytes.
    public var room: () -> Int = { Int.max }

    /// Counted for the close line of one opening.
    public private(set) var keys = 0
    public private(set) var pastes = 0
    public private(set) var pasted = 0
    /// Links the view asked to open (nothing is ever opened).
    public private(set) var dropped = 0
    /// Bells the view rang (counted, never sounded).
    public private(set) var bells = 0
    private var insidePaste = false
    /// The timestamp of the last current event a key was counted under: one key event counts one, whatever it sends.
    private var lastCountedEvent: TimeInterval?
    /// SwiftTerm's bracketed-paste markers, `ESC[200~` and `ESC[201~`.
    static let markerBytes = 12
    /// The longest a hand-over of bytes to the write queue took, in seconds: it must stay small whatever the child does (for the tests).
    public private(set) var longestDelivery: TimeInterval = 0

    public init() {}

    public func resetCounts() { keys = 0; pastes = 0; pasted = 0; lastCountedEvent = nil }

    // MARK: paste (SwiftTerm hands the bytes over on a later main-queue turn: two markers bracket its sends)

    /// Counts the paste. A paste whose UTF-8 length plus the 12 marker bytes is more than the write queue has room for is refused here, before
    /// SwiftTerm encodes anything (the queue's own check stays for the encoded bytes).
    func pasteBegins(_ text: String) -> Bool {
        pastes += 1; pasted += text.utf8.count
        guard text.utf8.count + Self.markerBytes <= room() else { refused(); return false }
        DispatchQueue.main.async { [self] in insidePaste = true }
        return true
    }
    func pasteEnded() { DispatchQueue.main.async { [self] in insidePaste = false } }

    /// The terminal engine's send, on the main queue after the hop (ChatTerminalView.send(source:data:)). Bytes that arrive while the paste
    /// bracket is open are Clawd's paste: delivered, timed and fed to the draft in the order claude receives them, `paste-refused` when the write
    /// queue refuses them. Everything else is a reply or a report: delivered, never counted and never seen by the draft, the Shift+Return rule or
    /// the exit-key record. A refused reply is dropped with no line.
    func engineSent(_ bytes: [UInt8]) {
        guard insidePaste else { _ = deliver(bytes); return }
        let began = ProcessInfo.processInfo.systemUptime
        let taken = deliver(bytes)
        longestDelivery = max(longestDelivery, ProcessInfo.processInfo.systemUptime - began)
        if taken { sent(bytes, true) } else { refused() }
    }

    /// Whether a key under `event` is counted: one per current event, told by its timestamp; a send with no current event counts one.
    private func counts(_ event: ChatCurrentEvent?) -> Bool {
        if event?.isMouse == true { return false }
        guard let stamp = event?.timestamp else { return true }
        if lastCountedEvent == stamp { return false }
        lastCountedEvent = stamp
        return true
    }
}

/// The delegate's protocol methods: SwiftTerm calls them on the main actor (the protocol is main-actor isolated), and they are the only part of
/// the class that is. The state they touch is plain.
extension ChatTerminalDelegate: TerminalViewDelegate {

    /// SwiftTerm's input path only: a key's bytes, an IME commit, the system's text insertion. The terminal engine's own sends and Clawd's paste
    /// come by `ChatTerminalView.send(source:data:)` and `engineSent`.
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        var bytes = Array(data)
        let event = currentEvent()
        // Shift+Return is a newline: SwiftTerm without the kitty protocol sends a lone CR, which would submit. The rule reads the bytes and the
        // current event's modifier flags reduced to Shift, Control, Option and Command (Caps Lock, the keypad and function-key flags ignored),
        // never an event type.
        let flags = event?.modifiers.intersection([.shift, .control, .option, .command])
        if bytes == [0x0D], flags == .shift { bytes = [0x1B, 0x0D] }
        if !insidePaste, counts(event) { keys += 1 }
        let began = ProcessInfo.processInfo.systemUptime
        _ = deliver(bytes)
        longestDelivery = max(longestDelivery, ProcessInfo.processInfo.systemUptime - began)
        sent(bytes, false)
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { gridChanged(newCols, newRows) }
    public func setTerminalTitle(source: TerminalView, title: String) { titleChanged(title) }
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func scrolled(source: TerminalView, position: Double) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// A link opens nothing: SwiftTerm's default would hand it to NSWorkspace. Declared here so this method, not the protocol's default
    /// extension, is the witness.
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { dropped += 1 }
    /// The bell does nothing (SwiftTerm's default beeps).
    public func bell(source: TerminalView) { bells += 1 }
}

/// The header's close control: it takes the first mouse, so a click on it while Clawd is inactive closes the panel instead of only activating Clawd.
public final class ChatCloseButton: NSButton {
    /// True in production; the audit test turns it off to see the audit refuse.
    public var takesFirstMouse = true
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { takesFirstMouse }

    /// The ghost button's hover fill (Orca's `--accent`): clear at rest. Nothing in the agent watches the pointer, so only `setHovered` sets it.
    public var hoverFill: CGColor = .clear
    public private(set) var isHovered = false
    public func setHovered(_ hovered: Bool) {
        isHovered = hovered
        layer?.backgroundColor = hovered ? hoverFill : .clear
    }
}

/// What the panel's chrome asks of the controller while the user works it with the mouse. A gesture is `begin`, any number of `move` or `resize`
/// (the offsets are from the begin point, in screen points, y up), then `end`; `toggleMaximize` stands alone. A move also carries the pointer's
/// global place, which decides the display the panel is on.
public enum ChatPanelGesture: Equatable {
    case begin
    case move(dx: CGFloat, dy: CGFloat, pointer: CGPoint? = nil)
    case resize(ChatPanelGeometry.Edge, dx: CGFloat, dy: CGFloat)
    case end
    case toggleMaximize
}

/// The title bar: dragging it moves the panel, a double-click toggles maximize (Orca's floating-terminal-titlebar-drag-target.ts and
/// floating-terminal-panel-drag-actions.ts:69-75). The mouse methods only read `NSEvent.mouseLocation` and hand it to `beginDrag`, `drag` and
/// `endDrag`, which a test calls with its own points.
public final class ChatTitleBarView: NSView {
    public var onGesture: ((ChatPanelGesture) -> Void)?
    private var origin: CGPoint?
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public func beginDrag(at point: CGPoint) { origin = point; onGesture?(.begin) }
    public func drag(to point: CGPoint) {
        guard let origin else { return }
        onGesture?(.move(dx: point.x - origin.x, dy: point.y - origin.y, pointer: point))
    }
    public func endDrag() {
        guard origin != nil else { return }
        origin = nil
        onGesture?(.end)
    }
    /// Where the bar's cursor goes (`NSCursor.set()` is global state, so a test takes it here).
    public var cursorSink: (NSCursor) -> Void = { $0.set() }
    /// A primary press on the empty bar is down (Orca's `active:cursor-grabbing`, FloatingTerminalPanelSurface.tsx:139): the rects carry the closed hand.
    public private(set) var pressed = false
    /// Every press shows the closed hand, a double-click's second one too. That press sets it after the toggle has run: the toggle resizes the panel
    /// and rebuilds the bar's rects, which would otherwise put the open hand back during the press.
    public override func mouseDown(with event: NSEvent) {
        pressed = true
        if event.clickCount == 2 { onGesture?(.toggleMaximize) } else { beginDrag(at: NSEvent.mouseLocation) }
        window?.invalidateCursorRects(for: self)
        cursorSink(.closedHand)
    }
    public override func mouseDragged(with event: NSEvent) { drag(to: NSEvent.mouseLocation) }
    public override func mouseUp(with event: NSEvent) {
        endDrag()
        pressed = false
        window?.invalidateCursorRects(for: self)
        // The bar may have moved from under the pointer (a double-click toggles the panel), and the rects only take effect under it: put a cursor back.
        let over = pointerInBar().map { point in emptyBarRects.contains { $0.contains(point) } } ?? false
        cursorSink(over ? Self.barCursor : .arrow)
    }
    /// Where the pointer is, in the bar's own coordinates (nil without a window); a test takes it here.
    public var pointerSource: (() -> CGPoint?)?
    private func pointerInBar() -> CGPoint? {
        if let pointerSource { return pointerSource() }
        return window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
    }

    /// Orca's bar is `cursor-grab active:cursor-grabbing` (FloatingTerminalPanelSurface.tsx:139): the open hand over the empty bar, the closed
    /// hand while a drag runs. The tab and the buttons keep their own cursor.
    public static var barCursor: NSCursor { .openHand }

    /// The empty part of the bar: the gaps between the tab and the buttons (the full-width rule under them is not one), full height.
    public var emptyBarRects: [CGRect] {
        var rects: [CGRect] = []
        var x: CGFloat = 0
        for frame in subviews.filter({ !$0.isHidden && $0.frame.width > 0 && $0.frame.width < bounds.width }).map(\.frame).sorted(by: { $0.minX < $1.minX }) {
            if frame.minX > x { rects.append(CGRect(x: x, y: 0, width: frame.minX - x, height: bounds.height)) }
            x = max(x, frame.maxX)
        }
        if bounds.width > x { rects.append(CGRect(x: x, y: 0, width: bounds.width - x, height: bounds.height)) }
        return rects
    }

    /// The cursor the empty bar's rects carry: the closed hand while a press lasts, else the open hand.
    public var cursorRectCursor: NSCursor { pressed ? .closedHand : Self.barCursor }

    public override func resetCursorRects() {
        addedCursorRects = []
        for rect in emptyBarRects { addCursorRect(rect, cursor: cursorRectCursor) }
    }
    /// The rects the last `resetCursorRects` added, with the cursor each carries (for the tests).
    public private(set) var addedCursorRects: [(rect: CGRect, cursor: NSCursor)] = []
    public override func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
        addedCursorRects.append((rect, cursor))
        super.addCursorRect(rect, cursor: cursor)
    }
}

/// One of the eight invisible resize handles (FloatingTerminalResizeHandles.tsx): the edge it drags, and the same begin, drag, end entry points.
/// All of each handle takes the mouse, as Orca's do, also where the e, w and s ones run over the terminal (its scroller, its last row, the
/// padding and the start of its first column); the wheel there still scrolls the terminal.
public final class ChatResizeHandle: NSView {
    public let edge: ChatPanelGeometry.Edge
    public var onGesture: ((ChatPanelGesture) -> Void)?
    private var origin: CGPoint?
    public init(edge: ChatPanelGeometry.Edge) { self.edge = edge; super.init(frame: .zero) }
    public required init?(coder: NSCoder) { fatalError("not used") }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where the wheel goes when it turns over a handle: the terminal's view.
    public weak var scrollTarget: NSView?
    public override func scrollWheel(with event: NSEvent) {
        if let scrollTarget { scrollTarget.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    public func beginDrag(at point: CGPoint) { origin = point; onGesture?(.begin) }
    public func drag(to point: CGPoint) {
        guard let origin else { return }
        onGesture?(.resize(edge, dx: point.x - origin.x, dy: point.y - origin.y))
    }
    public func endDrag() {
        guard origin != nil else { return }
        origin = nil
        onGesture?(.end)
    }
    public override func mouseDown(with event: NSEvent) { beginDrag(at: NSEvent.mouseLocation) }
    public override func mouseDragged(with event: NSEvent) { drag(to: NSEvent.mouseLocation) }
    public override func mouseUp(with event: NSEvent) { endDrag() }

    public override func resetCursorRects() {
        // Orca unmounts the handles while the panel is maximized (FloatingTerminalPanelSurface.tsx:327-333): a hidden one has no cursor rect.
        guard !isHidden else { return }
        let cursor: NSCursor
        switch edge {
        case .n, .s: cursor = .resizeUpDown
        case .e, .w: cursor = .resizeLeftRight
        case .ne, .sw, .nw, .se:
            if #available(macOS 15.0, *) {
                let diagonal: NSCursor.FrameResizePosition = (edge == .ne || edge == .sw) ? .topRight : .topLeft
                cursor = NSCursor.frameResize(position: diagonal, directions: .all)
            } else {
                cursor = .crosshair
            }
        }
        addCursorRect(bounds, cursor: cursor)
    }
}

/// Orca's tab (tab-bar/SortableTab.tsx, drop-indicator.ts:15-21): the active tab's fill is the foreground at 6 % over the card, its label is the
/// foreground with padding each side, and a foreground line runs along its bottom (sizes in `ChatLook`, at the chat's text scale).
final class ChatTabView: NSView {
    let label = NSTextField(labelWithString: "Claude Code")
    let indicator = NSView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        indicator.wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        addSubview(label); addSubview(indicator)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    /// The tab takes the whole press, as Orca's tab does (the title-bar drag target ignores it, floating-terminal-titlebar-drag-target.ts): it is
    /// the hit for any point inside it (not its label, which would track the click), and it does nothing with the press, so the press never
    /// reaches the title bar through the responder chain. The empty bar keeps the drag and the double-click.
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    /// Orca's tab menu (tab-bar/SortableTabContextMenu.tsx), Close only: it is the one item the chat has (the rest are workspace features). The
    /// close shortcut is shown beside it.
    var onMenuClose: (() -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        let close = NSMenuItem(title: "Close", action: #selector(menuClose), keyEquivalent: "w")
        close.target = self
        menu.addItem(close)
        return menu
    }
    @objc func menuClose() { onMenuClose?() }
    override func layout() {
        super.layout()
        indicator.frame = CGRect(x: 0, y: 0, width: bounds.width, height: ChatLook.tabIndicatorHeight)
        label.sizeToFit()
        let height = label.frame.height
        label.frame = CGRect(x: ChatLook.tabPadding, y: (bounds.height - height) / 2, width: max(0, bounds.width - ChatLook.tabPadding * 2), height: height)
    }
}

/// The terminal panel's content, in the look and with the behaviour of Orca's floating terminal: a rounded shell with a 1 px border, a 27 pt
/// title bar (one tab with the title Claude Code sets, then maximize and close), a body below it (Clawd's terminal view with Orca's 4 pt padding
/// on the left and the top, or the web chat's `ChatWebBody`, which fills the area), and eight resize handles over the edges. It follows the system appearance through `viewDidChangeEffectiveAppearance`,
/// which AppKit calls itself: no observer, timer or poll.
public final class ChatTerminalContainer: NSView {
    public static let headerHeight: CGFloat = ChatLook.titleBarHeight
    /// What fills the area under the title bar.
    public let body: ChatContainerBody
    /// The terminal kind's view; nil for the web kind.
    public var terminalView: ChatTerminalView? { body as? ChatTerminalView }
    /// The web kind's body; nil for the terminal kind.
    public var webBody: ChatWebBody? { body as? ChatWebBody }
    public let closeButton = ChatCloseButton()
    public let maximizeButton = ChatCloseButton()
    public let titleBarView = ChatTitleBarView()
    public private(set) var handles: [ChatResizeHandle] = []
    public var onClose: (() -> Void)?
    /// The user's mouse work on the chrome (move, resize, maximize); wired by the controller.
    public var onGesture: ((ChatPanelGesture) -> Void)? {
        didSet {
            titleBarView.onGesture = onGesture
            for handle in handles { handle.onGesture = onGesture }
        }
    }
    private let tabView = ChatTabView()
    /// The tab menu's Close (wired by the controller).
    public var onTabMenuClose: (() -> Void)? {
        get { tabView.onMenuClose }
        set { tabView.onMenuClose = newValue }
    }
    private let titleRule = NSView()
    /// The area under the title bar in the terminal's background: what shows in the padding left of and above the terminal view.
    private let terminalBacking = NSView()
    /// While a resize drag runs the terminal view keeps the size it had when the drag began, so SwiftTerm's grid, and the child's window size,
    /// change once when the drag ends and not at every step (each change is a SIGWINCH to claude and a reflow of its lines).
    public private(set) var holdsGrid = false
    private var heldSize = CGSize.zero
    public private(set) var showsActivationHint = false
    public private(set) var isMaximized = false
    public private(set) var look = ChatLook.dark
    private var shownTitle = "Claude Code"

    public convenience init(frame: CGRect, view: ChatTerminalView) { self.init(frame: frame, body: view) }

    public init(frame: CGRect, body: ChatContainerBody) {
        self.body = body
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = ChatLook.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = ChatLook.borderWidth
        titleBarView.wantsLayer = true
        titleRule.wantsLayer = true
        terminalBacking.wantsLayer = true
        tabView.label.font = ChatLook.titleFont()
        for button in [closeButton, maximizeButton] {
            button.title = ""
            button.bezelStyle = .inline
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.target = self
        }
        closeButton.setAccessibilityLabel("Close chat")
        closeButton.action = #selector(closePressed)
        maximizeButton.action = #selector(maximizePressed)
        titleBarView.addSubview(tabView); titleBarView.addSubview(titleRule)
        titleBarView.addSubview(maximizeButton); titleBarView.addSubview(closeButton)
        addSubview(titleBarView); addSubview(terminalBacking); addSubview(body)
        for edge in ChatPanelGeometry.Edge.allCases {
            let handle = ChatResizeHandle(edge: edge)
            handles.append(handle)
            addSubview(handle)
        }
        applyLook(ChatLook.look(for: effectiveAppearance))
        setMaximized(false)
        layoutContents()
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func closePressed() { onClose?() }
    @objc private func maximizePressed() { onGesture?(.toggleMaximize) }

    /// The tab, for the tests (a press over the title is a press on it).
    public var tab: NSView { tabView }

    public func handle(_ edge: ChatPanelGeometry.Edge) -> ChatResizeHandle { handles.first { $0.edge == edge }! }

    /// Holds or releases the terminal's size for the length of a gesture. Releasing applies the container's current size once.
    public func holdGrid(_ hold: Bool) {
        guard hold != holdsGrid else { return }
        holdsGrid = hold
        if hold { heldSize = body.frame.size }
        layoutContents()
    }

    public override func layout() { super.layout(); layoutContents() }
    /// A resize of the window reaches the terminal view in the same turn, so SwiftTerm's grid (and with it the PTY's window size) follows at once.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if body.superview === self { layoutContents() }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let next = ChatLook.look(for: effectiveAppearance)
        if next.isDark != look.isDark { applyLook(next) }
    }

    /// Paints the shell, the title bar and the terminal in `look`.
    public func applyLook(_ look: ChatLook) {
        self.look = look
        layer?.borderColor = look.panelBorder.cgColor
        layer?.backgroundColor = look.titleFill.color.cgColor
        titleBarView.layer?.backgroundColor = look.titleFill.color.cgColor
        titleRule.layer?.backgroundColor = look.titleBorder.cgColor
        terminalBacking.layer?.backgroundColor = look.background.color.cgColor
        tabView.layer?.backgroundColor = look.tabFill.color.cgColor
        tabView.indicator.layer?.backgroundColor = look.titleText.color.cgColor
        tabView.label.textColor = look.titleText.color
        for button in [closeButton, maximizeButton] {
            button.hoverFill = look.buttonHover.cgColor
            button.layer?.backgroundColor = button.isHovered ? button.hoverFill : .clear
            button.contentTintColor = look.buttonText.color
        }
        setSymbols()
        body.applyLook(look)
    }

    private func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: ChatLook.buttonIconSize, weight: .regular))
    }

    private func setSymbols() {
        let close = symbol("xmark", "Close chat")
        closeButton.image = close
        closeButton.title = close == nil ? "\u{2715}" : ""
        // Orca's Maximize2 and Minimize2 (FloatingTerminalWindowControls.tsx:147).
        let label = isMaximized ? "Restore chat" : "Maximize chat"
        let maximize = symbol(isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", label)
        maximizeButton.image = maximize
        maximizeButton.title = maximize == nil ? (isMaximized ? "\u{25A3}" : "\u{25A1}") : ""
        maximizeButton.setAccessibilityLabel(label)
        // FloatingTerminalWindowControls.tsx:145-160: "Maximize" or "Restore", with no shortcut hint (the shortcut is not ported).
        maximizeButton.toolTip = isMaximized ? "Restore" : "Maximize"
    }

    /// Shows the maximize control as pressed (restore icon) or not.
    public func setMaximized(_ maximized: Bool) {
        isMaximized = maximized
        setSymbols()
        // Orca unmounts the resize handles while the panel is maximized (FloatingTerminalPanelSurface.tsx:327-333): hidden here, which takes
        // their hit area and their cursor rects with them.
        for handle in handles { handle.isHidden = maximized }
        window?.invalidateCursorRects(for: self)
        for handle in handles { window?.invalidateCursorRects(for: handle) }
    }

    /// The shell's inner rectangle: inside the 1 px border, so the border never covers a cell.
    private var inner: CGRect { bounds.insetBy(dx: ChatLook.borderWidth, dy: ChatLook.borderWidth) }

    private func layoutContents() {
        let area = inner
        let header = ChatLook.titleBarHeight
        titleBarView.frame = CGRect(x: area.minX, y: area.maxY - header, width: area.width, height: header)
        titleRule.frame = CGRect(x: 0, y: 0, width: area.width, height: ChatLook.borderWidth)
        let button = ChatLook.buttonSize
        // On a whole point, so the icons stay sharp on a 1x screen.
        let y = ((header - button) / 2).rounded(.down)
        closeButton.frame = CGRect(x: area.width - ChatLook.buttonEdgeGap - button, y: y, width: button, height: button)
        maximizeButton.frame = CGRect(x: closeButton.frame.minX - ChatLook.buttonGap - button, y: y, width: button, height: button)
        let tabWidth = min(ChatLook.tabWidth, max(0, maximizeButton.frame.minX - ChatLook.buttonGap))
        tabView.frame = CGRect(x: 0, y: ChatLook.borderWidth, width: tabWidth, height: header - ChatLook.borderWidth)
        let body = CGRect(x: area.minX, y: area.minY, width: area.width, height: max(0, area.height - header))
        terminalBacking.frame = body
        let pad = ChatLook.terminalPadding
        if terminalView == nil {
            // The web chat fills the area (its page has its own padding), and a resize reaches the page at once.
            self.body.frame = body
        } else if holdsGrid {
            // Same size, kept under the title bar and its padding: only the origin follows.
            self.body.frame = CGRect(x: body.minX + pad, y: body.maxY - pad - heldSize.height, width: heldSize.width, height: heldSize.height)
        } else {
            self.body.frame = CGRect(x: body.minX + pad, y: body.minY, width: max(0, body.width - pad), height: max(0, body.height - pad))
        }
        for handle in handles { handle.frame = ChatPanelGeometry.handleFrame(handle.edge, in: bounds.size); handle.scrollTarget = webBody?.scrollTarget ?? self.body }
        window?.invalidateCursorRects(for: self)
    }

    /// The title Claude Code set (shown, truncated, never logged).
    public func setTitle(_ title: String) {
        shownTitle = title.isEmpty ? "Claude Code" : title
        if !showsActivationHint { tabView.label.stringValue = shownTitle }
    }

    /// While the opening's activation is refused (Sprint 3e item 2) the header says how to type.
    public func setActivationHint(_ shown: Bool) {
        showsActivationHint = shown
        tabView.label.stringValue = shown ? "Click here to type" : shownTitle
    }

    /// The header text as shown (for the tests).
    public var headerText: String { tabView.label.stringValue }

    /// What the panel audit checks about the terminal kind (spec T-2): the container holds exactly Clawd's terminal view, its delegate is
    /// Clawd's, it has no menu, Metal is off and the close control takes the first mouse. The web kind answers with its own audit (R5).
    public func auditProblems() -> [String] {
        var found: [String] = []
        if let terminalView {
            let terminals = subviews.filter { $0 is TerminalView }
            if terminals.count != 1 || terminals.first !== terminalView { found.append("the container does not hold exactly Clawd's terminal view") }
            if !(terminalView.terminalDelegate is ChatTerminalDelegate) { found.append("the terminal view's delegate is not Clawd's") }
            if terminalView.assignedMenu != nil || terminalView.menu != nil { found.append("the terminal view has a menu") }
            if terminalView.isUsingMetalRenderer { found.append("the terminal view uses Metal") }
        } else if let webBody {
            if subviews.contains(where: { $0 is TerminalView }) { found.append("the web chat's container holds a terminal view") }
            found += webBody.auditProblems()
        } else {
            found.append("the container's body is neither the terminal view nor the web chat")
        }
        if !closeButton.acceptsFirstMouse(for: nil) { found.append("the close control does not take the first mouse") }
        return found
    }
}
