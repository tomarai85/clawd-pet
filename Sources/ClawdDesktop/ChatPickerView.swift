import AppKit
import ClawdCore

/// One option of the `/` picker (Orca NativeChatPickerOption, NC/NativeChatAutocompleteMenus.tsx:158-232): a 13 pt row with 6 x 8 padding and an
/// 8 pt radius; the token in mono medium, the argument hint in 11 pt mono muted, the description in 12 pt muted on one line, a skill's package icon
/// and its scope label on the right. Every size is drawn at the chat's text scale (`ChatWebLook.textScale`), as the page is. The active row has a border and the accent fill. A mouse-down chooses it and never takes the keyboard.
public final class ChatPickerRowView: NSView {
    static let padX = ChatWebLook.scaled(8), padY = ChatWebLook.scaled(6), radius = ChatWebLook.scaled(8), iconSize = ChatWebLook.scaled(14), gap = ChatWebLook.scaled(8)
    static let tokenLine = ChatWebLook.scaled(20), descriptionLine = ChatWebLook.scaled(16), annotationLine = ChatWebLook.scaled(16)
    /// The 16 pt line of the hint and the scope label, their 3 pt drop below the token's top, and the 6 pt gap after the token (`gap-1.5`).
    static let smallLine = ChatWebLook.scaled(16), lift = ChatWebLook.scaled(3), hintGap = ChatWebLook.scaled(6)

    public let item: ChatPickerItem
    var onChoose: ((ChatPickerItem) -> Void)?
    private let token = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let scope = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var look = ChatWebLook.dark
    private var hovered = false
    public private(set) var isActive = false
    private var tracking: NSTrackingArea?

    static func height(for item: ChatPickerItem) -> CGFloat {
        padY * 2 + tokenLine + (item.description == nil ? 0 : descriptionLine) + (item.annotation == nil ? 0 : annotationLine)
    }

    init(item: ChatPickerItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        token.stringValue = item.kind == .conversation ? item.name : item.token
        // A command's token is mono; a conversation's title is ordinary text.
        token.font = item.kind == .conversation ? .systemFont(ofSize: 13 * ChatWebLook.textScale, weight: .medium) : .monospacedSystemFont(ofSize: 13 * ChatWebLook.textScale, weight: .medium)
        hint.stringValue = item.argumentHint ?? ""
        hint.font = .monospacedSystemFont(ofSize: 11 * ChatWebLook.textScale, weight: .regular)
        detail.stringValue = item.description ?? ""
        detail.font = ChatWebFonts.font(size: 12 * ChatWebLook.textScale)
        note.stringValue = item.annotation ?? ""
        note.font = ChatWebFonts.font(size: 11 * ChatWebLook.textScale)
        scope.stringValue = item.kind == .skill ? (item.scope ?? "") : ""
        scope.font = ChatWebFonts.font(size: 11 * ChatWebLook.textScale)
        icon.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)?                 // lucide Package, size-3.5
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Self.iconSize - 2, weight: .regular))
        for label in [token, hint, detail, note, scope] {
            label.lineBreakMode = .byTruncatingTail
            label.isSelectable = false
            label.cell?.truncatesLastVisibleLine = true
        }
        icon.isHidden = item.kind != .skill
        hint.isHidden = item.argumentHint == nil
        detail.isHidden = item.description == nil
        note.isHidden = item.annotation == nil
        for view in [icon, token, hint, detail, note, scope] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel([item.kind == .conversation ? item.name : item.token, item.argumentHint, item.description, item.annotation].compactMap { $0 }.joined(separator: ", "))
        apply(look)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The labels never take a click: the row does, so a press anywhere on it chooses it.
    public override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }

    public override func mouseDown(with event: NSEvent) { onChoose?(item) }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    public override func mouseEntered(with event: NSEvent) { hovered = true; paint() }
    public override func mouseExited(with event: NSEvent) { hovered = false; paint() }

    func setActive(_ active: Bool) { isActive = active; paint() }

    func apply(_ look: ChatWebLook) {
        self.look = look
        paint()
    }

    /// `hover:bg-accent`, and `border-border bg-accent` for the selected row (:181-184).
    private func paint() {
        let filled = isActive || hovered
        layer?.backgroundColor = filled ? look.accent.cgColor : NSColor.clear.cgColor
        layer?.borderColor = (isActive ? look.border : NSColor.clear).cgColor
        let strong = filled ? look.accentForeground : look.foreground
        token.textColor = strong
        hint.textColor = look.mutedForeground
        detail.textColor = look.mutedForeground
        note.textColor = look.mutedForeground
        scope.textColor = look.mutedForeground
        icon.contentTintColor = look.mutedForeground
    }

    public override func layout() {
        super.layout()
        var left = Self.padX
        var right = bounds.width - Self.padX
        if item.kind == .skill {
            icon.frame = CGRect(x: left, y: Self.padY + Self.lift, width: Self.iconSize, height: Self.iconSize)       // mt-0.5
            left += Self.iconSize + Self.gap
            scope.sizeToFit()
            let width = min(scope.frame.width, max(0, right - left) / 2)
            scope.frame = CGRect(x: right - width, y: Self.padY + Self.lift, width: width, height: Self.smallLine)  // pt-0.5
            if width > 0 { right -= width + Self.gap }
        }
        let available = max(0, right - left)
        token.sizeToFit()
        let tokenWidth = min(token.frame.width, available)
        token.frame = CGRect(x: left, y: Self.padY, width: tokenWidth, height: Self.tokenLine)
        if !hint.isHidden {
            hint.sizeToFit()
            let room = max(0, available - tokenWidth - Self.hintGap)                                              // gap-1.5
            hint.frame = CGRect(x: left + tokenWidth + Self.hintGap, y: Self.padY + Self.lift, width: min(hint.frame.width, room), height: Self.smallLine)
        }
        var y = Self.padY + Self.tokenLine
        if !detail.isHidden {
            detail.frame = CGRect(x: left, y: y, width: available, height: Self.descriptionLine)
            y += Self.descriptionLine
        }
        if !note.isHidden { note.frame = CGRect(x: left, y: y, width: available, height: Self.annotationLine) }
    }

    public var tokenFrame: CGRect { token.frame }
    public var descriptionText: String { detail.stringValue }
    public var scopeText: String { scope.stringValue }
}

/// The `/` picker, drawn inside the panel and never as a window (Orca NativeChatPickerMenu, NC/NativeChatAutocompleteMenus.tsx:8-156): 1 pt
/// border, radius 10, popover fill, a shadow of 0 10 24 at 18 %, 4 pt padding, scrolling past its height. "COMMANDS" and "SKILLS" head the two
/// groups. It floats over the transcript and takes no layout height. Every size but the 1 pt border is at the chat's text scale.
public final class ChatPickerView: NSView {
    public static let maxHeight = ChatWebLook.scaled(288)                  // max-h-72
    static let padding = ChatWebLook.scaled(4), border: CGFloat = 1, radius = ChatWebLook.scaled(10)
    static let headingHeight = ChatWebLook.scaled(26), statusHeight = ChatWebLook.scaled(28)
    /// A heading's or the status line's label: 8 pt in from the side, 6 pt down, on a 16 pt line.
    static let labelX = ChatWebLook.scaled(8), labelDrop = ChatWebLook.scaled(6), labelLine = ChatWebLook.scaled(16)

    public var onChoose: ((ChatPickerItem) -> Void)?
    public private(set) var items: [ChatPickerItem] = []
    public private(set) var activeIndex = 0
    public private(set) var rows: [ChatPickerRowView] = []
    public private(set) var headings: [String] = []
    public private(set) var statusText: String?
    private let scroll = NSScrollView()
    private let document = ChatPickerDocumentView()
    private var look = ChatWebLook.dark
    private var headingLabels: [NSTextField] = []
    private var statusLabel: NSTextField?
    private var content: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Self.border
        layer?.shadowOpacity = 0.18; layer?.shadowRadius = ChatWebLook.scaled(12); layer?.shadowOffset = CGSize(width: 0, height: -ChatWebLook.scaled(10))
        layer?.shadowColor = NSColor.black.cgColor
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = document
        addSubview(scroll)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Commands and skills")
        apply(.dark)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { false }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// A press on the border, a heading or the padding takes the click and does nothing: the keyboard stays in the input.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point) ?? self
    }
    public override func mouseDown(with event: NSEvent) {}

    var isShown: Bool { !isHidden }

    func apply(_ look: ChatWebLook) {
        self.look = look
        layer?.backgroundColor = look.popover.cgColor
        layer?.borderColor = look.border.cgColor
        for label in headingLabels { label.textColor = look.mutedForeground }
        statusLabel?.textColor = look.mutedForeground
        rows.forEach { $0.apply(look) }
    }

    /// The natural height of the rows, the headings, the padding and the border.
    public var contentHeight: CGFloat { content }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11 * ChatWebLook.textScale, weight: .semibold), .kern: 11 * ChatWebLook.textScale * 0.05, .foregroundColor: look.mutedForeground])
        label.isSelectable = false
        return label
    }

    /// Shows the rows of `slash` with row `active` marked. The rows are made again: a catalog holds at most 100 of them.
    func show(_ slash: ChatAutocomplete.Slash, active: Int, look: ChatWebLook) {
        render(slash.items, active: active, look: look, emptyText: ChatPicker.emptyText, headingWhenEmpty: nil)
    }

    /// Shows the conversations of `/resume <text>`: the CLI's heading, then the rows or the one status line (loading, none, no match).
    func show(_ conversations: ChatAutocomplete.Conversations, active: Int, look: ChatWebLook) {
        let words: String?
        switch conversations.status {
        case .some(.loading): words = ChatResume.loadingText
        case .some(.none): words = ChatResume.noneText
        case .some(.noMatch(let query)): words = ChatResume.noMatchText(query)
        case nil: words = nil
        }
        render(conversations.items, active: active, look: look, emptyText: words ?? ChatPicker.emptyText, headingWhenEmpty: ChatResume.heading)
    }

    private func render(_ list: [ChatPickerItem], active: Int, look: ChatWebLook, emptyText: String, headingWhenEmpty: String?) {
        self.look = look
        layer?.backgroundColor = look.popover.cgColor
        layer?.borderColor = look.border.cgColor
        document.subviews.forEach { $0.removeFromSuperview() }
        rows = []; headingLabels = []; statusLabel = nil; statusText = nil; headings = []
        items = list
        var y = Self.padding
        func addHeading(_ text: String) {
            let label = heading(text)
            label.frame = CGRect(x: Self.labelX, y: y + Self.labelDrop, width: 200, height: Self.labelLine)
            document.addSubview(label)
            headingLabels.append(label); headings.append(text.uppercased())
            y += Self.headingHeight
        }
        var lastKind: ChatPickerItem.Kind?
        for item in items {
            if item.kind != lastKind {
                addHeading(item.kind == .command ? "Commands" : item.kind == .skill ? "Skills" : ChatResume.heading)
                lastKind = item.kind
            }
            let row = ChatPickerRowView(item: item)
            row.onChoose = { [weak self] picked in self?.onChoose?(picked) }
            row.apply(look)
            row.frame = CGRect(x: Self.padding, y: y, width: 0, height: ChatPickerRowView.height(for: item))
            document.addSubview(row)
            rows.append(row)
            y += row.frame.height
        }
        if items.isEmpty {
            if let headingWhenEmpty { addHeading(headingWhenEmpty) }
            let label = NSTextField(labelWithString: emptyText)
            label.font = ChatWebFonts.font(size: 12 * ChatWebLook.textScale)
            label.textColor = look.mutedForeground
            label.isSelectable = false
            label.frame = CGRect(x: Self.labelX, y: y + Self.labelDrop, width: 200, height: Self.labelLine)
            document.addSubview(label)
            statusLabel = label; statusText = emptyText
            y += Self.statusHeight
        }
        content = y + Self.padding + Self.border * 2
        document.contentHeight = y + Self.padding
        activeIndex = min(max(0, active), max(0, rows.count - 1))
        rows.enumerated().forEach { $0.element.setActive($0.offset == activeIndex) }
        isHidden = false
        needsLayout = true
        layoutRows()
        scrollActiveIntoView()
    }

    public func setActive(_ index: Int) {
        guard !rows.isEmpty else { return }
        activeIndex = min(max(0, index), rows.count - 1)
        rows.enumerated().forEach { $0.element.setActive($0.offset == activeIndex) }
        scrollActiveIntoView()
    }

    public func hide() {
        isHidden = true
        items = []; rows = []
        document.subviews.forEach { $0.removeFromSuperview() }
    }

    /// `scrollIntoView({ block: 'nearest' })` for the active row.
    private func scrollActiveIntoView() {
        guard rows.indices.contains(activeIndex) else { return }
        document.scrollToVisible(rows[activeIndex].frame.insetBy(dx: 0, dy: -Self.padding))
    }

    private func layoutRows() {
        let inner = max(0, bounds.width - Self.border * 2)
        scroll.frame = CGRect(x: Self.border, y: Self.border, width: inner, height: max(0, bounds.height - Self.border * 2))
        let width = max(0, inner - Self.padding * 2)
        document.frame = CGRect(x: 0, y: 0, width: inner, height: max(document.contentHeight, scroll.frame.height))
        for row in rows { row.frame = CGRect(x: Self.padding, y: row.frame.minY, width: width, height: row.frame.height) }
        for label in headingLabels { label.frame.size.width = max(0, inner - Self.labelX * 2) }
        statusLabel?.frame.size.width = max(0, inner - Self.labelX * 2)
    }

    public override func layout() {
        super.layout()
        layoutRows()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutRows()
    }
}

/// The picker's scrolled content: top-down, and never the first responder.
final class ChatPickerDocumentView: NSView {
    var contentHeight: CGFloat = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) {}
}

/// Orca's mention hint (NC/NativeChatAutocompleteMenus.tsx:262-283): one line, "Referencing file: @query", in a bordered popover-coloured box with
/// a medium shadow, radius 8 and 6 x 12 padding, every size but the 1 pt border at the chat's text scale. A mouse-down accepts it and never takes the
/// keyboard.
public final class ChatMentionHintView: NSView {
    static let radius = ChatWebLook.scaled(8), padX = ChatWebLook.scaled(12), padY = ChatWebLook.scaled(6), line = ChatWebLook.scaled(16), border: CGFloat = 1
    public static let height: CGFloat = padY * 2 + line + border * 2
    public static let label = "Referencing file: "

    public var onAccept: (() -> Void)?
    private let text = NSTextField(labelWithString: "")
    private var look = ChatWebLook.dark
    public private(set) var query = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Self.border
        layer?.shadowOpacity = 0.1; layer?.shadowRadius = ChatWebLook.scaled(3); layer?.shadowOffset = CGSize(width: 0, height: -ChatWebLook.scaled(3))      // shadow-md
        layer?.shadowColor = NSColor.black.cgColor
        text.lineBreakMode = .byTruncatingTail
        text.isSelectable = false
        addSubview(text)
        setAccessibilityRole(.button)
        apply(.dark)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { false }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { !isHidden && bounds.contains(convert(point, from: superview)) ? self : nil }
    public override func mouseDown(with event: NSEvent) { onAccept?() }

    var isShown: Bool { !isHidden }
    /// The text as shown: the muted words and the query, `…` for an empty one.
    public var shownText: String { text.stringValue }

    func apply(_ look: ChatWebLook) {
        self.look = look
        layer?.backgroundColor = look.popover.cgColor
        layer?.borderColor = look.border.cgColor
        render()
    }

    func show(query: String, look: ChatWebLook) {
        self.query = query
        self.look = look
        layer?.backgroundColor = look.popover.cgColor
        layer?.borderColor = look.border.cgColor
        render()
        isHidden = false
    }
    public func hide() { isHidden = true }

    private func render() {
        let font = ChatWebFonts.font(size: 12 * ChatWebLook.textScale)
        let shown = NSMutableAttributedString(string: Self.label, attributes: [.font: font, .foregroundColor: look.mutedForeground])
        shown.append(NSAttributedString(string: "@" + (query.isEmpty ? "\u{2026}" : query),
                                        attributes: [.font: NSFont.systemFont(ofSize: 12 * ChatWebLook.textScale, weight: .medium), .foregroundColor: look.foreground]))
        text.attributedStringValue = shown
        setAccessibilityLabel(shown.string)
    }

    public override func layout() {
        super.layout()
        text.frame = CGRect(x: Self.padX, y: Self.padY + Self.border, width: max(0, bounds.width - Self.padX * 2), height: Self.line)
    }
}
