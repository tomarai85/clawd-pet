import AppKit
import ClawdCore

/// The click count of the event being handled. Only a mouse press has one (AppKit raises on `clickCount` of a key or any other event), so a press by
/// keyboard, VoiceOver or Voice Control counts as 1: it is never a second click and never traps.
public enum ChatClickCount {
    /// The event being handled: the application's current event in production, a test's own event in a test. Every default click-count closure reads it.
    public static var source: () -> NSEvent? = { NSApp?.currentEvent }

    public static func current(of event: NSEvent? = source()) -> Int {
        guard let event, event.type == .leftMouseDown || event.type == .leftMouseUp else { return 1 }
        return event.clickCount
    }
}

/// A text-and-icon or icon-only button of the queue list (Orca's ghost `xs` and `icon-xs` buttons, h-6): never the first responder, so a press leaves
/// the keyboard in the input.
public final class ChatQueueButton: NSButton {
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The More actions button: a pull-down whose one item is "Edit message". AppKit shows the menu when it is pressed; Clawd never pops a menu up itself.
public final class ChatQueueMoreButton: NSPopUpButton {
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One card of the queue list (Orca NativeChatQueuedMessageCard.tsx:31-226): the ListEnd icon (AlertCircle in the destructive colour for a returned,
/// send-failed or doubt card), the text on one truncated line with the whole text as its tooltip, the caption below it, the Steer (or Send) button,
/// the Delete icon button and the More actions button whose menu holds "Edit message". Padding 6 x 10, an 8 pt gap; every size at the chat's text
/// scale (`ChatWebLook.textScale`), as the page is.
public final class ChatQueueRowView: NSView {
    static let padX = ChatWebLook.scaled(10), padY = ChatWebLook.scaled(6), gap = ChatWebLook.scaled(8), iconSize = ChatWebLook.scaled(14)
    static let textLine = ChatWebLook.scaled(20), captionLine = ChatWebLook.scaled(16), buttonHeight = ChatWebLook.scaled(24)
    /// The buttons' corner, the icon's 3 pt drop, the steer button's 8 pt of room past its title, and the 4 pt above the chips.
    static let buttonRadius = ChatWebLook.scaled(6), lift = ChatWebLook.scaled(3), steerRoom = ChatWebLook.scaled(8), chipGap = ChatWebLook.scaled(4)

    public let row: ChatQueueRow
    /// Only the newest card answers Cmd+Enter, so only it shows the chord in its tooltip.
    public let showsSteerShortcut: Bool
    var onSteer: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onEdit: ((String) -> Void)?
    /// The click count of the press being handled. The second click of a double-click is ignored: the first one removes the card and rebuilds the
    /// list, so a second one would land on the card that moved up under the pointer (Q12).
    var clickCount: () -> Int = { ChatClickCount.current() }
    private let icon = NSImageView()
    private let text = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    /// The card's images as small name chips (Q14), nil for a card without any.
    public private(set) var chipRow: ChatQueueChipRow?
    public let steerButton = ChatQueueButton()
    public let deleteButton = ChatQueueButton()
    public let moreButton = ChatQueueMoreButton(frame: .zero, pullsDown: true)
    private var look = ChatWebLook.dark

    /// The chip line under the caption, for a card whose send carried images: 20 pt chips with 4 pt above them, at the text scale.
    public static let chipLine = ChatWebLook.scaled(24)

    public static func height(for row: ChatQueueRow) -> CGFloat {
        padY * 2 + textLine + (row.caption == nil ? 0 : captionLine) + (row.chipLabels.isEmpty ? 0 : chipLine)
    }

    init(row: ChatQueueRow, showsSteerShortcut: Bool) {
        self.row = row; self.showsSteerShortcut = showsSteerShortcut
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: row.alerts ? "exclamationmark.circle" : "text.append", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Self.iconSize - 2, weight: .regular))
        text.stringValue = row.text
        text.toolTip = row.text
        text.font = ChatWebFonts.font(size: 14 * ChatWebLook.textScale)
        caption.stringValue = row.caption ?? ""
        caption.isHidden = row.caption == nil
        caption.font = ChatWebFonts.font(size: 12 * ChatWebLook.textScale)
        for label in [text, caption] {
            label.lineBreakMode = .byTruncatingTail
            label.isSelectable = false
            label.cell?.truncatesLastVisibleLine = true
        }
        let steers = !row.sendsPlainly
        let label = steers ? "Steer" : "Send"
        steerButton.title = label
        steerButton.image = NSImage(systemSymbolName: steers ? "arrow.turn.down.right" : "paperplane", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11 * ChatWebLook.textScale, weight: .regular))
        steerButton.imagePosition = .imageLeading
        steerButton.toolTip = (steers ? "Submit without interrupting the model" : "Send this message now") + (showsSteerShortcut ? " \u{2318}\u{23CE}" : "")
        steerButton.setAccessibilityLabel(label)
        steerButton.target = self; steerButton.action = #selector(steerPressed)
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12 * ChatWebLook.textScale, weight: .regular))
        deleteButton.toolTip = "Delete"
        deleteButton.setAccessibilityLabel("Delete")
        deleteButton.target = self; deleteButton.action = #selector(deletePressed)
        // A pull-down shows its first item as the button; the items below it are the menu.
        moreButton.addItem(withTitle: "")
        moreButton.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More actions")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12 * ChatWebLook.textScale, weight: .regular))
        let edit = NSMenuItem(title: "Edit message", action: #selector(editPressed), keyEquivalent: "")
        edit.target = self
        edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        moreButton.menu?.addItem(edit)
        (moreButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        moreButton.imagePosition = .imageOnly
        moreButton.toolTip = "More actions"
        moreButton.setAccessibilityLabel("More actions")
        moreButton.isBordered = false
        moreButton.refusesFirstResponder = true
        moreButton.wantsLayer = true
        moreButton.layer?.cornerRadius = Self.buttonRadius
        for button in [steerButton, deleteButton] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.refusesFirstResponder = true
            button.wantsLayer = true
            button.layer?.cornerRadius = Self.buttonRadius
            button.isEnabled = true
        }
        deleteButton.title = ""
        for view in [icon, text, caption, steerButton, deleteButton, moreButton] { addSubview(view) }
        if let chips = row.card.chips, !chips.isEmpty {
            chipRow = ChatQueueChipRow(chips: chips)
            addSubview(chipRow!)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel([row.text, row.caption].compactMap { $0 }.joined(separator: ", "))
        apply(look)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ look: ChatWebLook) {
        self.look = look
        icon.contentTintColor = row.alerts ? .systemRed : look.mutedForeground
        text.textColor = look.foreground
        caption.textColor = row.hold == .returned ? .systemRed : look.mutedForeground
        chipRow?.apply(look)
        let tint = look.foreground
        steerButton.attributedTitle = NSAttributedString(string: steerButton.title, attributes: [.font: ChatWebFonts.font(size: 12 * ChatWebLook.textScale), .foregroundColor: tint])
        steerButton.contentTintColor = tint
        deleteButton.contentTintColor = tint
        moreButton.contentTintColor = tint
    }

    @objc private func steerPressed() { guard clickCount() <= 1 else { return }; onSteer?(row.id) }
    @objc private func deletePressed() { guard clickCount() <= 1 else { return }; onDelete?(row.id) }
    @objc private func editPressed() { onEdit?(row.id) }

    public override func layout() {
        super.layout()
        let height = bounds.height
        var right = bounds.width - Self.padX
        let size = Self.buttonHeight
        // Centred on a whole point, so the icons and the title stay sharp on a 1x screen.
        let buttonY = ((height - size) / 2).rounded(.down)
        moreButton.frame = CGRect(x: right - size, y: buttonY, width: size, height: size); right = moreButton.frame.minX - Self.gap
        deleteButton.frame = CGRect(x: right - size, y: buttonY, width: size, height: size); right = deleteButton.frame.minX - Self.gap
        steerButton.sizeToFit()
        let steerWidth = max(size, steerButton.frame.width + Self.steerRoom)
        steerButton.frame = CGRect(x: right - steerWidth, y: buttonY, width: steerWidth, height: size); right = steerButton.frame.minX - Self.gap
        icon.frame = CGRect(x: Self.padX, y: Self.padY + Self.lift, width: Self.iconSize, height: Self.iconSize)
        let left = icon.frame.maxX + Self.gap
        let available = max(0, right - left)
        text.frame = CGRect(x: left, y: Self.padY, width: available, height: Self.textLine)
        caption.frame = CGRect(x: left, y: Self.padY + Self.textLine, width: available, height: Self.captionLine)
        chipRow?.frame = CGRect(x: left, y: Self.padY + Self.textLine + (caption.isHidden ? 0 : Self.captionLine) + Self.chipGap, width: available, height: Self.chipLine - Self.chipGap)
    }

    public var textFrame: CGRect { text.frame }
    public var captionText: String? { caption.isHidden ? nil : caption.stringValue }
    public var shownText: String { text.stringValue }
    public var textToolTip: String? { text.toolTip }
    public var iconName: String { row.alerts ? "alert" : "list-end" }
}

/// A card's images as small name chips on one line (12 pt, muted, 1 pt border, radius 8, at the chat's text scale): the same look as the transcript's
/// sent-image chips. What does not fit is cut off at the right edge.
public final class ChatQueueChipRow: NSView {
    public private(set) var labels: [String] = []
    private var chips: [(view: NSView, border: CALayer, label: NSTextField, icon: NSImageView)] = []

    init(chips saved: [ChatComposerChip]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        for chip in saved {
            let name = chip.path ?? chip.unavailable ?? ""
            let shown = ChatChipImages.label(for: name)
            labels.append(shown)
            let view = NSView()
            view.wantsLayer = true
            view.layer?.cornerRadius = ChatWebLook.scaled(8)
            view.layer?.borderWidth = 1
            view.toolTip = chip.path ?? ChatUnavailableChipView.explanation(name: name)
            let label = NSTextField(labelWithString: shown)
            label.font = ChatWebFonts.font(size: 12 * ChatWebLook.textScale)
            label.lineBreakMode = .byTruncatingTail
            label.isSelectable = false
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: chip.path == nil ? "photo.badge.exclamationmark" : "photo", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11 * ChatWebLook.textScale, weight: .regular))
            view.addSubview(icon); view.addSubview(label)
            addSubview(view)
            chips.append((view, view.layer!, label, icon))
        }
        setAccessibilityElement(true)
        setAccessibilityLabel("Attached images: " + labels.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }

    func apply(_ look: ChatWebLook) {
        for chip in chips {
            chip.border.borderColor = look.border.cgColor
            chip.label.textColor = look.mutedForeground
            chip.icon.contentTintColor = look.mutedForeground
        }
    }

    public override func layout() {
        super.layout()
        var x: CGFloat = 0
        for chip in chips {
            let text = ceil(chip.label.attributedStringValue.size().width)
            // Orca's 8 pt sides, 12 pt icon, 4 pt gap, 16 pt line, 140 pt at most and 6 pt between chips, at the text scale.
            let side = ChatWebLook.scaled(8), iconSize = ChatWebLook.scaled(12), gap = ChatWebLook.scaled(4), line = ChatWebLook.scaled(16)
            let width = min(ChatWebLook.scaled(140), side + iconSize + gap + text + side)
            chip.view.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            chip.icon.frame = CGRect(x: side, y: ((bounds.height - iconSize) / 2).rounded(.down), width: iconSize, height: iconSize)
            chip.label.frame = CGRect(x: side + iconSize + gap, y: ((bounds.height - line) / 2).rounded(.down), width: max(0, width - side * 2 - iconSize - gap), height: line)
            x += width + ChatWebLook.scaled(6)
        }
    }
}

/// The pause row, first row of the box when the queue's pause holds a card: the Pause icon at 14 pt, 12 pt muted text and a "Resume" button, at the
/// chat's text scale.
public final class ChatQueuePauseRowView: NSView {
    static let padX = ChatWebLook.scaled(10), padY = ChatWebLook.scaled(6), gap = ChatWebLook.scaled(8), iconSize = ChatWebLook.scaled(14), line = ChatWebLook.scaled(16)
    static let height: CGFloat = padY * 2 + ChatQueueRowView.buttonHeight

    var onResume: (() -> Void)?
    var clickCount: () -> Int = { ChatClickCount.current() }
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    public let resumeButton = ChatQueueButton()
    public var text: String { label.stringValue }

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: "pause", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12 * ChatWebLook.textScale, weight: .regular))
        label.stringValue = text
        label.toolTip = text
        label.font = ChatWebFonts.font(size: 12 * ChatWebLook.textScale)
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        resumeButton.title = "Resume"
        resumeButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10 * ChatWebLook.textScale, weight: .regular))
        resumeButton.imagePosition = .imageLeading
        resumeButton.bezelStyle = .inline
        resumeButton.isBordered = false
        resumeButton.refusesFirstResponder = true
        resumeButton.target = self; resumeButton.action = #selector(resumePressed)
        resumeButton.setAccessibilityLabel("Resume")
        for view in [icon, label, resumeButton] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ look: ChatWebLook) {
        icon.contentTintColor = look.mutedForeground
        label.textColor = look.mutedForeground
        resumeButton.attributedTitle = NSAttributedString(string: "Resume", attributes: [.font: ChatWebFonts.font(size: 12 * ChatWebLook.textScale), .foregroundColor: look.foreground])
        resumeButton.contentTintColor = look.foreground
    }

    @objc private func resumePressed() { guard clickCount() <= 1 else { return }; onResume?() }

    public override func layout() {
        super.layout()
        let size = ChatQueueRowView.buttonHeight
        resumeButton.sizeToFit()
        let width = resumeButton.frame.width + ChatQueueRowView.steerRoom
        resumeButton.frame = CGRect(x: bounds.width - Self.padX - width, y: ((bounds.height - size) / 2).rounded(.down), width: width, height: size)
        icon.frame = CGRect(x: Self.padX, y: ((bounds.height - Self.iconSize) / 2).rounded(.down), width: Self.iconSize, height: Self.iconSize)
        let left = icon.frame.maxX + Self.gap
        label.frame = CGRect(x: left, y: ((bounds.height - Self.line) / 2).rounded(.down), width: max(0, resumeButton.frame.minX - Self.gap - left), height: Self.line)
    }
}

/// The queued messages, stacked between the transcript and the composer (Orca NativeChatQueuedMessageList.tsx:9-127), never over the transcript: the
/// web view above it is as much shorter as this is tall. One bordered box (radius 8, card fill) holds the pause row when the pause holds a card and
/// one row per card, divided by 1 pt lines, with 16 pt on each side and 4 pt above and below it (`px-4 py-1`), at the chat's text scale but for the
/// 1 pt lines. It scrolls past its height cap (D15), and with no cards it takes no height. Every row is a view inside the panel; nothing here is a window or takes the keyboard.
public final class ChatQueueListView: NSView {
    public static let padX = ChatWebLook.scaled(16), padY = ChatWebLook.scaled(4), border: CGFloat = 1, radius = ChatWebLook.scaled(8), divider: CGFloat = 1

    var onSteer: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onEdit: ((String) -> Void)?
    var onResume: (() -> Void)?
    /// What every button of the list reads as the click count of its press (a test supplies its own).
    public var clickCount: () -> Int = { ChatClickCount.current() }

    public private(set) var rows: [ChatQueueRowView] = []
    public private(set) var pauseRow: ChatQueuePauseRowView?
    private let box = NSView()
    private let scroll = NSScrollView()
    private let document = ChatQueueDocumentView()
    private var dividers: [NSView] = []
    private var look = ChatWebLook.dark
    private var natural: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        box.wantsLayer = true
        box.layer?.cornerRadius = Self.radius
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = Self.border
        box.layer?.masksToBounds = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = document
        box.addSubview(scroll)
        addSubview(box)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Queued messages")
        apply(.dark)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { false }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point) ?? self
    }
    public override func mouseDown(with event: NSEvent) {}

    /// The height the list wants with no cap: the rows, the dividers, the box's border and the padding above and below; 0 with no cards.
    public var contentHeight: CGFloat { natural }
    public var hasCards: Bool { !rows.isEmpty }
    public var boxFrame: CGRect { box.frame }

    func apply(_ look: ChatWebLook) {
        self.look = look
        box.layer?.backgroundColor = look.card.cgColor
        box.layer?.borderColor = look.border.cgColor
        dividers.forEach { $0.layer?.backgroundColor = look.border.cgColor }
        pauseRow?.apply(look)
        rows.forEach { $0.apply(look) }
    }

    /// Shows the cards (made again on every change: at most 20 and a few doubt cards). `pauseText` is the pause row's words, when it shows.
    func show(_ queueRows: [ChatQueueRow], pauseText: String?, look: ChatWebLook) {
        self.look = look
        document.subviews.forEach { $0.removeFromSuperview() }
        rows = []; dividers = []; pauseRow = nil
        guard !queueRows.isEmpty else {
            isHidden = true; natural = 0
            return
        }
        var y: CGFloat = 0
        func divide() {
            let line = NSView()
            line.wantsLayer = true
            line.frame = CGRect(x: 0, y: y, width: 0, height: Self.divider)
            document.addSubview(line)
            dividers.append(line)
            y += Self.divider
        }
        if let pauseText {
            let pause = ChatQueuePauseRowView(text: pauseText)
            pause.onResume = { [weak self] in self?.onResume?() }
            pause.clickCount = { [weak self] in self?.clickCount() ?? 1 }
            pause.frame = CGRect(x: 0, y: y, width: 0, height: ChatQueuePauseRowView.height)
            document.addSubview(pause)
            pauseRow = pause
            y += ChatQueuePauseRowView.height
        }
        let newest = queueRows.last?.id
        for (index, queueRow) in queueRows.enumerated() {
            if pauseRow != nil || index > 0 { divide() }
            let view = ChatQueueRowView(row: queueRow, showsSteerShortcut: queueRow.id == newest)
            view.onSteer = { [weak self] id in self?.onSteer?(id) }
            view.onDelete = { [weak self] id in self?.onDelete?(id) }
            view.onEdit = { [weak self] id in self?.onEdit?(id) }
            view.clickCount = { [weak self] in self?.clickCount() ?? 1 }
            view.frame = CGRect(x: 0, y: y, width: 0, height: ChatQueueRowView.height(for: queueRow))
            document.addSubview(view)
            rows.append(view)
            y += view.frame.height
        }
        document.contentHeight = y
        natural = y + Self.border * 2 + Self.padY * 2
        isHidden = false
        apply(look)
        needsLayout = true
        layoutRows()
    }

    private func layoutRows() {
        guard !rows.isEmpty else { return }
        let boxWidth = max(0, bounds.width - Self.padX * 2)
        let boxHeight = max(0, bounds.height - Self.padY * 2)
        box.frame = CGRect(x: Self.padX, y: Self.padY, width: boxWidth, height: boxHeight)
        let inner = max(0, boxWidth - Self.border * 2)
        scroll.frame = CGRect(x: Self.border, y: Self.border, width: inner, height: max(0, boxHeight - Self.border * 2))
        document.frame = CGRect(x: 0, y: 0, width: inner, height: max(document.contentHeight, scroll.frame.height))
        for view in document.subviews { view.frame.size.width = inner }
        for line in dividers { line.frame.size.width = inner }
    }

    public override func layout() { super.layout(); layoutRows() }
    public override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutRows() }
}

/// The list's scrolled content: top-down, never the first responder.
final class ChatQueueDocumentView: NSView {
    var contentHeight: CGFloat = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) {}
}
