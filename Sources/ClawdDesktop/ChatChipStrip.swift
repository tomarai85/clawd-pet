import AppKit
import ClawdCore

/// One image chip of the composer (spec Q14): a file the draft will send, an image the draft names but could not bring back, or a pasted image
/// that is still being saved.
public struct ChatChipItem: Equatable {
    public enum Kind: Equatable {
        case file(String)
        case unavailable(String)
        case pending
    }
    public let id: Int
    public var kind: Kind

    /// "Pasted image" for a `clawd-paste-*.png`, else the file's name (NC/NativeChatImageAttachmentPreview.tsx:25-29).
    public var label: String {
        switch kind {
        case .file(let path): return ChatChipImages.label(for: path)
        case .unavailable(let name): return ChatChipImages.label(for: name)
        case .pending: return "Saving pasted image\u{2026}"
        }
    }
}

/// How a chip's picture stands: being made, ready, or none to show (an SVG, a file ImageIO cannot read, or an image over the pixel cap).
public enum ChatChipPicture {
    case loading
    case image(CGImage)
    case icon
}

/// The composer's chips and what holds Send: the persisted ones (files and unavailable names, saved in the draft file) and the pending pastes
/// (never saved). Orca's reattach rules (NC/native-chat-image-reattach.ts:24-36).
public final class ChatChipModel {
    public private(set) var items: [ChatChipItem] = []
    public private(set) var pictures: [Int: ChatChipPicture] = [:]
    private var nextId = 1
    /// The items changed.
    var onChange: (() -> Void)?

    public init() {}

    /// The chips the draft file keeps: files and unavailable names in order, never a pending paste.
    public var persisted: [ChatComposerChip] {
        items.compactMap { item in
            switch item.kind {
            case .file(let path): return ChatComposerChip(path: path)
            case .unavailable(let name): return ChatComposerChip(unavailable: name)
            case .pending: return nil
            }
        }
    }
    public var hasPending: Bool { items.contains { $0.kind == .pending } }
    public var unavailableCount: Int { items.filter { if case .unavailable = $0.kind { return true } else { return false } }.count }
    public var filePaths: [String] { items.compactMap { if case .file(let path) = $0.kind { return path } else { return nil } } }

    /// Why Send is held, or nil: a pending paste, or an image that could not be brought back (Orca's two sentences).
    public var hold: String? {
        Self.lostWords(unavailableCount) ?? (hasPending ? "Saving pasted image\u{2026}" : nil)
    }

    /// The sentence for `lost` images that could not be brought back, or nil for none.
    public static func lostWords(_ lost: Int) -> String? {
        if lost == 1 { return "An image couldn't be brought back. Remove it to send." }
        if lost > 1 { return "Some images couldn't be brought back. Remove them to send." }
        return nil
    }

    private func make(_ kind: ChatChipItem.Kind) -> ChatChipItem {
        defer { nextId += 1 }
        return ChatChipItem(id: nextId, kind: kind)
    }

    /// The saved chips replace the persisted ones; the pending pastes stay (at the end).
    func replacePersisted(with chips: [ChatComposerChip]) {
        guard chips != persisted else { return }
        let pending = items.filter { $0.kind == .pending }
        let before = items
        let keep = Set(pending.map(\.id))
        pictures = pictures.filter { keep.contains($0.key) }
        items = chips.compactMap { chip in
            if let path = chip.path { return make(.file(path)) }
            if let name = chip.unavailable { return make(.unavailable(name)) }
            return nil
        } + pending
        if items != before { onChange?() }
    }

    /// Adds a file chip, or fills the place of an unavailable chip of the same name (Orca native-chat-composer-draft-addition.ts:36-43). A pasted
    /// name never matches: a new paste cannot bring a pasted image back.
    @discardableResult
    func add(path: String) -> Int {
        let name = ChatChipImages.basename(path)
        if !ChatChipImages.isPastedName(name),
           let place = items.firstIndex(where: { if case .unavailable(let lost) = $0.kind { return ChatChipImages.basename(lost) == name } else { return false } }) {
            let id = items[place].id
            items[place].kind = .file(path)
            pictures[id] = nil
            onChange?()
            return id
        }
        let item = make(.file(path))
        items.append(item)
        onChange?()
        return item.id
    }

    /// The chips of a send that came back unsent join the draft after the ones it holds (a chip it already holds is not added twice).
    func append(restoring chips: [ChatComposerChip]) {
        let held = persisted
        var added = false
        for chip in chips where !held.contains(chip) {
            if let path = chip.path { items.append(make(.file(path))) } else if let name = chip.unavailable { items.append(make(.unavailable(name))) } else { continue }
            added = true
        }
        if added { onChange?() }
    }

    /// The chips a send carried leave the draft, one item for each.
    func remove(sent chips: [ChatComposerChip]) {
        var removed = false
        for chip in chips {
            let place = items.firstIndex { item in
                switch item.kind {
                case .file(let path): return chip.path == path
                case .unavailable(let name): return chip.unavailable == name
                case .pending: return false
                }
            }
            guard let place else { continue }
            pictures[items[place].id] = nil
            items.remove(at: place)
            removed = true
        }
        if removed { onChange?() }
    }

    @discardableResult
    func addPending() -> Int {
        let item = make(.pending)
        items.append(item)
        onChange?()
        return item.id
    }

    /// A pending paste was saved: it becomes the file chip in the same place, keeping its picture.
    func settle(_ id: Int, path: String) {
        guard let place = items.firstIndex(where: { $0.id == id }), items[place].kind == .pending else { return }
        items[place].kind = .file(path)
        onChange?()
    }

    func remove(_ id: Int) {
        guard let place = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: place)
        pictures[id] = nil
        onChange?()
    }

    func setPicture(_ id: Int, _ picture: ChatChipPicture) {
        guard items.contains(where: { $0.id == id }) else { return }
        pictures[id] = picture
    }

    func item(_ id: Int) -> ChatChipItem? { items.first { $0.id == id } }
}

/// Runs a chip's file reading off the main thread, one at a time (ImageIO may decode a large PNG in full inside one thumbnail call, about 128 MB at
/// 32 Mi pixels), and says the result on the main queue. The default runs both halves at once (the tests step it).
public struct ChatChipLoader {
    public var images = ChatChipImages()
    public var run: (_ work: @escaping () -> Void, _ done: @escaping () -> Void) -> Void = { work, done in work(); done() }
    public init() {}

    public static var production: ChatChipLoader {
        var loader = ChatChipLoader()
        let queue = DispatchQueue(label: "clawd.chat.chip-images", qos: .utility)
        loader.run = { work, done in queue.async { work(); DispatchQueue.main.async(execute: done) } }
        return loader
    }
}

/// A button of the strip that never takes the keyboard from the input.
public final class ChatChipButton: NSButton {
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One thumbnail chip (NC/NativeChatImageAttachmentPreview.tsx:150-212): 56 x 56, radius 8, a 1 pt border that rings on hover, the picture
/// aspect-filled (50 % with a spinner while the paste is saved), and a 16 pt round remove button hanging 6 pt outside the top right corner.
public final class ChatChipView: NSView {
    static let size: CGFloat = 56, radius: CGFloat = 8, removeSize: CGFloat = 16, hang: CGFloat = 6
    public let item: ChatChipItem
    public let button = ChatChipButton()
    public let removeButton = ChatChipButton()
    private let picture = CALayer()
    /// Test seam: the scale `picture` takes instead of the window's, and what it holds now.
    public var backingScaleOverride: CGFloat?
    public var pictureContentsScale: CGFloat { picture.contentsScale }
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        picture.contentsScale = backingScale(override: backingScaleOverride)
    }
    private let spinner = NSProgressIndicator()
    private let iconView = NSImageView()
    private var look = ChatWebLook.dark
    var onOpen: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?
    public private(set) var isHovered = false

    init(item: ChatChipItem) {
        self.item = item
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        picture.cornerRadius = Self.radius - 1
        picture.cornerCurve = .continuous
        picture.masksToBounds = true
        picture.contentsGravity = .resizeAspectFill
        picture.frame = bounds.insetBy(dx: 1, dy: 1)
        layer?.addSublayer(picture)
        iconView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        iconView.frame = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        iconView.imageAlignment = .alignCenter
        addSubview(iconView)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true
        spinner.frame = CGRect(x: (Self.size - 16) / 2, y: (Self.size - 16) / 2, width: 16, height: 16)
        addSubview(spinner)
        button.title = ""
        button.isBordered = false
        button.frame = bounds
        button.target = self; button.action = #selector(openPressed)
        let label = item.kind == .pending ? item.label : "View image: " + item.label
        button.setAccessibilityLabel(label)
        button.toolTip = item.label
        addSubview(button)
        removeButton.title = ""
        removeButton.isBordered = false
        removeButton.bezelStyle = .inline
        removeButton.wantsLayer = true
        removeButton.layer?.cornerRadius = Self.removeSize / 2
        removeButton.layer?.borderWidth = 1
        removeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove attachment")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        removeButton.setAccessibilityLabel("Remove attachment")
        removeButton.toolTip = "Remove attachment"
        removeButton.frame = CGRect(x: Self.size - Self.removeSize + Self.hang, y: -Self.hang, width: Self.removeSize, height: Self.removeSize)
        removeButton.target = self; removeButton.action = #selector(removePressed)
        addSubview(removeButton)
        setPicture(.loading)
        apply(look)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ look: ChatWebLook) {
        self.look = look
        layer?.backgroundColor = look.canvas.cgColor
        layer?.borderColor = (isHovered ? look.mutedForeground : look.border).cgColor
        iconView.contentTintColor = look.mutedForeground
        removeButton.layer?.backgroundColor = look.canvas.cgColor
        removeButton.layer?.borderColor = look.border.cgColor
        removeButton.contentTintColor = look.mutedForeground
    }

    func setPicture(_ state: ChatChipPicture) {
        let pending = item.kind == .pending
        picture.opacity = pending ? 0.5 : 1
        switch state {
        case .image(let image):
            picture.contents = image
            iconView.isHidden = true
        case .loading, .icon:
            picture.contents = nil
            iconView.isHidden = false
        }
        spinner.isHidden = !pending
        if pending { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// The hover ring (`hover:border-ring`). Nothing in the agent watches the pointer (R-NP), so only `setHovered` sets it, as for the close control;
    /// no tracking area is made here.
    public func setHovered(_ hovered: Bool) {
        isHovered = hovered
        layer?.borderColor = (hovered ? look.mutedForeground : look.border).cgColor
    }

    @objc private func openPressed() { onOpen?(item.id) }
    @objc private func removePressed() { onRemove?(item.id) }
}

/// A chip whose file the draft could not bring back (NC/NativeChatImageAttachmentPreview.tsx:62-104): 56 pt tall, at most 160 wide, a dashed
/// border, the ImageOff icon, the name and "Not kept" (a paste) or "Attach again".
public final class ChatUnavailableChipView: NSView {
    static let maxWidth: CGFloat = 160
    public let item: ChatChipItem
    public let removeButton = ChatChipButton()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let dash = CAShapeLayer()
    var onRemove: ((Int) -> Void)?
    /// Test seam: the scale `dash` takes instead of the window's, and what it holds now.
    public var backingScaleOverride: CGFloat?
    public var dashContentsScale: CGFloat { dash.contentsScale }
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        dash.contentsScale = backingScale(override: backingScaleOverride)
    }

    /// Orca's two sentences, for the tooltip and the accessibility label.
    static func explanation(name: String) -> String {
        ChatChipImages.isPastedName(ChatChipImages.basename(name))
            ? "This pasted image couldn't be brought back with this draft. Remove it, and paste it again if you still need it."
            : "\(ChatChipImages.label(for: name)) couldn't be brought back with this draft. Attach it again or remove it."
    }

    init(item: ChatChipItem, lostName: String) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        let pasted = ChatChipImages.isPastedName(ChatChipImages.basename(lostName))
        let words = Self.explanation(name: lostName)
        toolTip = words
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(words)
        layer?.cornerRadius = ChatChipView.radius
        layer?.cornerCurve = .continuous
        dash.fillColor = nil
        dash.lineWidth = 1
        dash.lineDashPattern = [4, 3]
        layer?.addSublayer(dash)
        icon.image = NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        name.stringValue = item.label
        hint.stringValue = pasted ? "Not kept" : "Attach again"
        name.font = ChatWebFonts.font(size: 12); hint.font = ChatWebFonts.font(size: 12)
        for label in [name, hint] { label.lineBreakMode = .byTruncatingTail; label.isSelectable = false }
        removeButton.title = ""
        removeButton.isBordered = false
        removeButton.bezelStyle = .inline
        removeButton.wantsLayer = true
        removeButton.layer?.cornerRadius = ChatChipView.removeSize / 2
        removeButton.layer?.borderWidth = 1
        removeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove attachment")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        removeButton.setAccessibilityLabel("Remove attachment")
        removeButton.toolTip = "Remove attachment"
        removeButton.target = self; removeButton.action = #selector(removePressed)
        for view in [icon, name, hint, removeButton] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The width the chip wants: the icon, the text and the 8 pt padding and gap, capped at 160.
    static func width(for item: ChatChipItem, lostName: String) -> CGFloat {
        let font = ChatWebFonts.font(size: 12)
        let hint = ChatChipImages.isPastedName(ChatChipImages.basename(lostName)) ? "Not kept" : "Attach again"
        let text = max((item.label as NSString).size(withAttributes: [.font: font]).width, (hint as NSString).size(withAttributes: [.font: font]).width)
        return min(maxWidth, ceil(8 + 16 + 8 + text + 8))
    }

    func apply(_ look: ChatWebLook) {
        layer?.backgroundColor = look.canvas.cgColor
        dash.strokeColor = look.border.cgColor
        icon.contentTintColor = look.mutedForeground
        name.textColor = look.foreground
        hint.textColor = look.mutedForeground
        removeButton.layer?.backgroundColor = look.canvas.cgColor
        removeButton.layer?.borderColor = look.border.cgColor
        removeButton.contentTintColor = look.mutedForeground
    }

    public override func layout() {
        super.layout()
        dash.frame = bounds
        dash.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: ChatChipView.radius, cornerHeight: ChatChipView.radius, transform: nil)
        icon.frame = CGRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let left = icon.frame.maxX + 8
        let width = max(0, bounds.width - left - 8)
        name.frame = CGRect(x: left, y: bounds.height / 2 - 16, width: width, height: 16)
        hint.frame = CGRect(x: left, y: bounds.height / 2, width: width, height: 16)
        removeButton.frame = CGRect(x: bounds.width - ChatChipView.removeSize + ChatChipView.hang, y: -ChatChipView.hang,
                                    width: ChatChipView.removeSize, height: ChatChipView.removeSize)
    }

    @objc private func removePressed() { onRemove?(item.id) }
}

/// The chip strip's scrolled content: the chips laid out in wrapping rows (flipped, top-down).
final class ChatChipDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

/// The chip strip inside the composer box (Orca NativeChatComposerField.tsx:213-233): `mb-2 flex flex-wrap gap-2 px-1 pt-1.5`, which is 6 pt above,
/// 4 pt on each side and an 8 pt gap, then 8 pt before the row. At most two chip rows show, then it scrolls (D15). The remove buttons hang 6 pt outside
/// a chip, so the rows leave 6 pt more than the side padding at the right edge.
public final class ChatChipStripView: NSScrollView {
    static let gap: CGFloat = 8, topPad: CGFloat = 6, sidePad: CGFloat = 4, below: CGFloat = 8
    static let maxRows = 2
    /// The strip's visible height at most: the top padding and two chip rows with their gap.
    static let maxShown: CGFloat = topPad + ChatChipView.size * CGFloat(maxRows) + gap * CGFloat(maxRows - 1)

    private let document = ChatChipDocumentView()
    public private(set) var chipViews: [ChatChipView] = []
    public private(set) var unavailableViews: [ChatUnavailableChipView] = []
    private var look = ChatWebLook.dark
    public private(set) var contentHeight: CGFloat = 0
    var onOpen: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true; hasHorizontalScroller = false
        autohidesScrollers = true; scrollerStyle = .overlay
        documentView = document
        isHidden = true
        setAccessibilityRole(.list)
        setAccessibilityLabel("Attached images")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var acceptsFirstResponder: Bool { false }

    func apply(_ look: ChatWebLook) {
        self.look = look
        chipViews.forEach { $0.apply(look) }
        unavailableViews.forEach { $0.apply(look) }
    }

    /// The rows the chips fill in `width`, and the strip's height: 0 with no chip, else the visible part of the rows plus the 8 pt before the row.
    func show(_ items: [ChatChipItem], pictures: [Int: ChatChipPicture], width: CGFloat) -> CGFloat {
        document.subviews.forEach { $0.removeFromSuperview() }
        chipViews = []; unavailableViews = []
        guard !items.isEmpty else {
            isHidden = true; contentHeight = 0
            return 0
        }
        isHidden = false
        let limit = max(Self.sidePad, width - Self.sidePad - ChatChipView.hang)
        var x = Self.sidePad, y = Self.topPad
        for item in items {
            let view: NSView
            let size: CGSize
            if case .unavailable(let lost) = item.kind {
                let chip = ChatUnavailableChipView(item: item, lostName: lost)
                chip.onRemove = { [weak self] id in self?.onRemove?(id) }
                chip.apply(look)
                unavailableViews.append(chip)
                view = chip
                size = CGSize(width: ChatUnavailableChipView.width(for: item, lostName: lost), height: ChatChipView.size)
            } else {
                let chip = ChatChipView(item: item)
                chip.onOpen = { [weak self] id in self?.onOpen?(id) }
                chip.onRemove = { [weak self] id in self?.onRemove?(id) }
                chip.setPicture(pictures[item.id] ?? .loading)
                chip.apply(look)
                chipViews.append(chip)
                view = chip
                size = CGSize(width: ChatChipView.size, height: ChatChipView.size)
            }
            if x > Self.sidePad, x + size.width > limit { x = Self.sidePad; y += ChatChipView.size + Self.gap }
            view.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            document.addSubview(view)
            x += size.width + Self.gap
        }
        contentHeight = y + ChatChipView.size
        let shown = min(contentHeight, Self.maxShown)
        document.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        verticalScrollElasticity = contentHeight > shown ? .automatic : .none
        return shown + Self.below
    }
}
