import AppKit
import ClawdCore
import CoreText
import WebKit

/// What fills the panel container's body under the title bar: Clawd's terminal view, or the web chat.
public protocol ChatContainerBody: NSView {
    func applyLook(_ look: ChatLook)
}

extension ChatTerminalView: ChatContainerBody {}

/// The web chat's colours for the native pieces around the page (the composer and the area behind the web view): the same tokens as page.css, in
/// Orca's main.css. A dark value that Orca writes as a colour-mix is resolved here to the colour it mixes to.
struct ChatWebLook {
    /// The web chat's size against Orca's: Orca's 14 px body was too big in Clawd's small panel (Tom, 2026-11-09: "it's TOO BIG make sure the
    /// size of text is small"). The page is zoomed by it (`ChatWebPage`) and every composer size is multiplied by it, so text, rows and controls
    /// shrink together: the body is 10.5 pt, the terminal view's size.
    static let textScale: CGFloat = 0.75
    /// A composer length at `textScale`, on whole points so edges stay on the pixel grid of a 1x display.
    static func scaled(_ length: CGFloat) -> CGFloat { (length * textScale).rounded() }
    /// `--chat-canvas`: light is the background (#fff, main.css:176); dark is the foreground (#fafafa) at 5 % over the background (#0a0a0a),
    /// #161616 (main.css:313).
    let canvas: NSColor
    /// `--chat-composer-surface` (main.css:187, 324) and `--chat-composer-border` (main.css:188, 325).
    let composerSurface: NSColor, composerBorder: NSColor
    /// `--chat-foreground-strong` (main.css:178, 315) and `--chat-foreground-faint` (main.css:179, 316).
    let strong: NSColor, faint: NSColor
    /// `--primary` and `--primary-foreground` (main.css:194-195, 331-332): the send button.
    let primary: NSColor, primaryForeground: NSColor
    /// `--foreground`, `--card` and `--muted-foreground` (main.css:175, 190, 199; 312, 327, 336): the drop overlay's card.
    let foreground: NSColor, card: NSColor, mutedForeground: NSColor
    /// `--popover`, `--border`, `--accent` and `--accent-foreground` (main.css:192, 204, 200-201; 329, 341, 337-338): the `/` picker and the mention hint.
    let popover: NSColor, border: NSColor, accent: NSColor, accentForeground: NSColor

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let dark = ChatWebLook(canvas: rgb(0x161616), composerSurface: rgb(0xfafafa, alpha: 0.04), composerBorder: rgb(0xfafafa, alpha: 0.09),
                                  strong: rgb(0xe3e3e3), faint: rgb(0x898989), primary: rgb(0xe5e5e5), primaryForeground: rgb(0x171717),
                                  foreground: rgb(0xfafafa), card: rgb(0x171717), mutedForeground: rgb(0xa1a1a1),
                                  popover: rgb(0x171717), border: rgb(0xffffff, alpha: 0.07), accent: rgb(0x404040), accentForeground: rgb(0xfafafa))
    static let light = ChatWebLook(canvas: rgb(0xffffff), composerSurface: rgb(0xffffff), composerBorder: rgb(0x0a0a0a, alpha: 0.11),
                                   strong: rgb(0x1e1e1e), faint: rgb(0x737373), primary: rgb(0x171717), primaryForeground: rgb(0xfafafa),
                                   foreground: rgb(0x0a0a0a), card: rgb(0xffffff), mutedForeground: rgb(0x737373),
                                   popover: rgb(0xffffff), border: rgb(0xe5e5e5), accent: rgb(0xf5f5f5), accentForeground: rgb(0x171717))
}

/// Geist, Orca's app font (SIL OFL 1.1, shipped in the page directory), registered for this process only. CoreText may refuse the WOFF2 file; the
/// system font then stands in, as it does for every other part of Clawd's chrome.
enum ChatWebFonts {
    private static var attempted = false
    private(set) static var registered = false

    static func register(in directory: URL) {
        guard !attempted else { return }
        attempted = true
        var failure: Unmanaged<CFError>?
        registered = CTFontManagerRegisterFontsForURL(directory.appendingPathComponent("Geist-Variable.woff2") as CFURL, .process, &failure)
        failure?.release()
    }

    static func font(size: CGFloat) -> NSFont {
        NSFont(name: "Geist", size: size) ?? NSFont(name: "Geist-Regular", size: size) ?? .systemFont(ofSize: size)
    }
}

/// The composer in Orca's look (C/NativeChatComposerField.tsx:182-293): a rounded box with a 1 px border and one row in it: the plus control,
/// the input and the round send control, all on the row's bottom edge. The input starts at one line and grows to eight; the status line is one
/// faint line above the box that takes no height while it is empty. The input is Clawd's own `ChatInputTextView`, so Enter, Shift+Enter, Esc, the
/// marked-text guard and the 1 MiB cap are the ones the stream view has.
public final class ChatComposerView: NSView {
    // Orca's sizes in its px, each drawn at `ChatWebLook.textScale` (whole points; the font keeps its fraction).
    static let sidePad = ChatWebLook.scaled(12), topPad = ChatWebLook.scaled(8), bottomPad = ChatWebLook.scaled(16)  // native-chat-appearance: pt-2 px-3 pb-4 (:182-185)
    static let boxPad = ChatWebLook.scaled(6), border: CGFloat = 1, radius = ChatWebLook.scaled(14)                // p-1.5, border, rounded-xl (14 px: 1.4 x 10 px)
    static let fontSize: CGFloat = 14 * ChatWebLook.textScale, lineHeight = ChatWebLook.scaled(20)
    static let inputInset = ChatWebLook.scaled(4)                                         // py-1
    static let inputMin: CGFloat = lineHeight + inputInset * 2                            // one line
    static let inputMax: CGFloat = lineHeight * 8 + inputInset * 2                        // max-h-[calc(8lh+0.5rem)]
    static let buttonSize = ChatWebLook.scaled(32)                                        // size-8
    static let statusHeight = ChatWebLook.scaled(16)
    /// The space between the chip strip and the row (`mb-2`). Not scaled: it is the strip's own `below`, which `show` adds to the height it
    /// returns, and the image chips keep their size.
    static let stripGap: CGFloat = ChatChipStripView.below

    public let inputView: ChatInputTextView
    public let plusButton = ChatCloseButton()
    public let sendButton = ChatCloseButton()
    private let box = NSView()
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private var look = ChatWebLook.dark
    private var turn: ChatTurnState = .none
    private var locked = false
    public var onSend: (() -> Void)?
    public var onStop: (() -> Void)?
    /// The "+" control: Orca's "Attach file" (native-chat/NativeChatComposerActions.tsx:100-116).
    public var onAttach: (() -> Void)?
    /// The input's height changed: the body lays the composer out again.
    var onHeightChange: (() -> Void)?
    /// The text changed (typed, pasted, dropped or set).
    public var onDraftChanged: (() -> Void)?
    /// The text, the caret or the marked range changed: the body's `/` picker follows them.
    var onInputChanged: (() -> Void)?
    /// Orca's "couldn't be saved" icon (NC/NativeChatComposerActions.tsx:193-213): shown between the input and the send control only after storage
    /// refused the draft. 16 pt, 4 pt from each neighbour, so the input is 24 pt narrower while it shows and the row's height does not change.
    public let draftWarning = NSImageView()
    /// The image chips (Q14): the model, the strip inside the box above the row, and the loader that makes their thumbnails.
    public let chips = ChatChipModel()
    public let strip = ChatChipStripView()
    public var chipLoader = ChatChipLoader()
    /// The persisted chips changed (a chip added, removed, filled or settled): the controller saves them.
    var onChipsChanged: (([ChatComposerChip]) -> Void)?
    /// A chip was clicked: its preview opens.
    var onChipOpen: ((ChatChipItem) -> Void)?
    static let warningSize = ChatWebLook.scaled(16), warningGap = ChatWebLook.scaled(4)
    public static let draftWarningText = "This draft couldn't be saved yet. Clawd keeps trying."

    public override init(frame: NSRect) {
        inputView = ChatPanelView.makeText(ChatInputTextView.self)
        super.init(frame: frame)
        wantsLayer = true
        box.wantsLayer = true
        box.layer?.cornerRadius = Self.radius
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = Self.border
        box.layer?.shadowOpacity = 0.05                    // shadow-xs: 0 1px 2px 0 rgb(0 0 0 / 0.05)
        box.layer?.shadowRadius = 1
        box.layer?.shadowOffset = CGSize(width: 0, height: -1)
        box.layer?.shadowColor = NSColor.black.cgColor

        let font = ChatWebFonts.font(size: Self.fontSize)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = Self.lineHeight; style.maximumLineHeight = Self.lineHeight
        inputView.font = font
        inputView.defaultParagraphStyle = style
        inputView.isEditable = true; inputView.isSelectable = true
        inputView.textContainerInset = NSSize(width: ChatWebLook.scaled(8), height: Self.inputInset)  // px-2 py-1
        inputView.textContainer?.lineFragmentPadding = 0
        inputView.placeholderText = "Send a message\u{2026}"
        inputView.setAccessibilityLabel("Message to Claude Code")
        inputView.setAccessibilityPlaceholderValue(inputView.placeholderText)
        inputView.onTextChanged = { [weak self] in self?.textChanged() }
        inputView.onAutocompleteInput = { [weak self] in self?.onInputChanged?() }
        inputView.onSend = { [weak self] in self?.onSend?() }
        inputView.providesContextMenu = true
        inputView.registerForDraggedTypes(ChatDropContent.registeredTypes)
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.documentView = inputView

        for button in [plusButton, sendButton] {
            button.title = ""
            button.bezelStyle = .inline
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.refusesFirstResponder = true             // typing stays in the input
            button.wantsLayer = true
            button.target = self
        }
        plusButton.layer?.cornerRadius = ChatWebLook.scaled(8)
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Attach file")?                  // lucide Plus, size-4
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: ChatWebLook.scaled(16), weight: .regular))
        plusButton.title = plusButton.image == nil ? "+" : ""
        plusButton.action = #selector(plusPressed)
        plusButton.setAccessibilityLabel("Attach file")
        plusButton.toolTip = "Attach file"
        plusButton.isEnabled = true
        sendButton.layer?.cornerRadius = Self.buttonSize / 2
        sendButton.action = #selector(sendPressed)
        status.font = .systemFont(ofSize: 12 * ChatWebLook.textScale)
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityElement(false)

        draftWarning.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: Self.draftWarningText)?     // lucide CircleAlert
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: ChatWebLook.scaled(16), weight: .regular))
        draftWarning.contentTintColor = .systemOrange                                                                                // text-status-warning
        draftWarning.toolTip = Self.draftWarningText
        draftWarning.setAccessibilityLabel(Self.draftWarningText)
        draftWarning.isHidden = true
        strip.onOpen = { [weak self] id in if let item = self?.chips.item(id) { self?.onChipOpen?(item) } }
        // Locked while a send reads the draft's files: a chip taken out meanwhile would still be in what is sent.
        strip.onRemove = { [weak self] id in guard let self, !self.locked else { return }; self.chips.remove(id) }
        chips.onChange = { [weak self] in self?.chipsChanged() }
        box.addSubview(strip)
        box.addSubview(scroll); box.addSubview(plusButton); box.addSubview(draftWarning); box.addSubview(sendButton)
        addSubview(box); addSubview(status)
        status.isHidden = true
        applyLook(.dark)
        applyState()
    }
    public required init?(coder: NSCoder) { fatalError("ChatComposerView is built in code") }

    public override var isFlipped: Bool { false }

    // MARK: state

    public func setText(_ text: String) {
        inputView.string = text
        inputView.needsDisplay = true
        textChanged()
    }

    /// The status line, with the full text in its tooltip for when the line truncates.
    public func setStatus(_ text: String) {
        status.stringValue = text
        status.toolTip = text.isEmpty ? nil : text
        status.isHidden = text.isEmpty
        onHeightChange?()
    }
    public var statusText: String { status.stringValue }
    public var statusToolTip: String? { status.toolTip }
    public var isLocked: Bool { locked }

    public func setTurn(_ new: ChatTurnState) { turn = new; applyState() }

    public func setLocked(_ new: Bool) {
        locked = new
        inputView.isEditable = !new
        scroll.alphaValue = new ? 0.5 : 1
        applyState()
    }

    private func textChanged() {
        applyState()
        onHeightChange?()
        onDraftChanged?()
        onInputChanged?()
    }

    /// Whether the "couldn't be saved" icon is up.
    public var isDraftWarningShown: Bool { !draftWarning.isHidden }
    public func setDraftWarning(_ shown: Bool) {
        guard draftWarning.isHidden == shown else { return }
        draftWarning.isHidden = !shown
        layoutComposer()
        onHeightChange?()
    }
    private var warningReserve: CGFloat { draftWarning.isHidden ? 0 : Self.warningSize + Self.warningGap * 2 }

    /// The send control: an arrow while the draft can be sent, 50 % when there is nothing to send or a chip holds it, a square (stop) while a turn runs.
    private func applyState() {
        let running = turn != .none
        let empty = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chips.items.isEmpty
        let symbol = running ? "stop.fill" : "arrow.up"
        let label = running ? "Stop Claude" : "Send message"
        sendButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: ChatWebLook.scaled(14), weight: .semibold))
        sendButton.title = sendButton.image == nil ? (running ? "\u{25A0}" : "\u{2191}") : ""
        sendButton.setAccessibilityLabel(label)
        let hold = running ? nil : chips.hold
        sendButton.isEnabled = running ? turn == .running : (!empty && !locked && hold == nil)
        sendButton.toolTip = hold
        sendButton.alphaValue = sendButton.isEnabled ? 1 : 0.5            // disabled:opacity-50 (ui/button.tsx:8)
        sendButton.contentTintColor = look.primaryForeground
    }

    public var isSendEnabled: Bool { sendButton.isEnabled }
    public var isStopShown: Bool { turn != .none }

    @objc private func plusPressed() { onAttach?() }
    /// The click count of the event being handled, 1 for a press that is not a mouse click (a test supplies its own).
    public var clickCount: () -> Int = { ChatClickCount.current() }
    /// The second click of a double-click is ignored, so a double-click never sends and then stops (Q12): the first click turns the control into Stop.
    @objc private func sendPressed() {
        guard clickCount() <= 1 else { return }
        if turn == .none { onSend?() } else { onStop?() }
    }

    // MARK: look and layout

    func applyLook(_ look: ChatWebLook) {
        self.look = look
        layer?.backgroundColor = look.canvas.cgColor
        box.layer?.backgroundColor = look.composerSurface.cgColor
        box.layer?.borderColor = look.composerBorder.cgColor
        inputView.textColor = look.strong
        inputView.insertionPointColor = look.strong
        inputView.placeholderColor = look.faint
        status.textColor = look.faint
        strip.apply(look)
        plusButton.contentTintColor = look.faint
        sendButton.layer?.backgroundColor = look.primary.cgColor
        applyState()
        inputView.needsDisplay = true
    }

    private var inner: CGFloat { Self.border + Self.boxPad }
    private var boxWidth: CGFloat { max(0, bounds.width - Self.sidePad * 2) }
    /// The input's width: the box inside its border and padding, less the two controls.
    private var inputWidth: CGFloat { max(0, boxWidth - inner * 2 - Self.buttonSize * 2 - warningReserve) }

    /// The text's height with the input's insets, and the height the input shows: one line at least, eight at most.
    private func measureInput() -> (used: CGFloat, shown: CGFloat) {
        guard let layout = inputView.layoutManager, let container = inputView.textContainer else { return (Self.inputMin, Self.inputMin) }
        if inputWidth > 0, inputView.frame.width != inputWidth { inputView.setFrameSize(NSSize(width: inputWidth, height: inputView.frame.height)) }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height + inputView.textContainerInset.height * 2
        return (used, min(max(used, Self.inputMin), Self.inputMax))
    }

    private var statusShownHeight: CGFloat { status.stringValue.isEmpty ? 0 : Self.statusHeight }

    /// The composer's height: the top padding, the status line when there is one, the box (border, padding and the one row) and the bottom padding.
    public func preferredHeight() -> CGFloat {
        refreshStrip()
        return Self.topPad + statusShownHeight + boxHeight(input: measureInput().shown) + Self.bottomPad
    }

    /// Where the `/` picker and the mention hint rest: the top of the status line when it shows, else the top of the box, counted from the
    /// composer's bottom edge (the picker's own 4 pt gap is added by the body).
    public func floatAnchor() -> CGFloat {
        refreshStrip()
        return Self.bottomPad + boxHeight(input: measureInput().shown) + statusShownHeight
    }

    /// The row is as tall as the input or the controls, whichever is taller; the chip strip, when there is one, is above it with 8 pt between.
    private func boxHeight(input: CGFloat) -> CGFloat {
        Self.border * 2 + Self.boxPad * 2 + max(input, Self.buttonSize) + stripTotal
    }

    // MARK: image chips (Q14)

    /// The box and the chip strip inside it, in the composer's coordinates (for the tests and the audit).
    public var boxFrame: CGRect { box.frame }
    public var stripFrame: CGRect { box.convert(strip.frame, to: self) }

    /// The strip's height with the 8 pt before the row, 0 with no chip.
    private(set) var stripTotal: CGFloat = 0
    private var stripWidth: CGFloat = -1
    private var fromController = false

    private var chipScale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// The controller's saved chips replace the persisted ones (no save is asked back); the pending pastes stay.
    func syncChips(_ saved: [ChatComposerChip]) {
        fromController = true
        chips.replacePersisted(with: saved)
        fromController = false
    }

    /// Image files from a drop, a pick or a paste of paths: each becomes a chip, or fills the place of an unavailable chip of the same name.
    public func attachImages(paths: [String]) {
        for path in paths { chips.add(path: path) }
    }

    /// The chips of a send that came back unsent rejoin the draft.
    public func restoreChips(_ chips: [ChatComposerChip]) { self.chips.append(restoring: chips) }

    /// The chips an accepted send carried leave the draft.
    public func removeSent(_ chips: [ChatComposerChip]) { self.chips.remove(sent: chips) }

    /// A pasted image's chip, shown at once from the pasteboard's bytes while the PNG is saved. `thenEncode` is called with the chip's id once the
    /// thumbnail is made (or has failed), on the main queue: a large paste is decoded for its thumbnail and then for its PNG, never both at once
    /// (Q14, deferred Low S5 L4). It runs even when this view has gone, since a stored paste outlives a closed opening.
    public func beginPendingImage(data: Data, thenEncode: @escaping (Int) -> Void) -> Int {
        let id = chips.addPending()
        let images = chipLoader.images, pixels = Int(ceil(ChatChipView.size * chipScale))
        var result: ChatChipImage = .unreadable
        chipLoader.run({ result = images.load(data: data, maxPixel: pixels) }, { [weak self] in
            self?.pictureLoaded(id, result)
            thenEncode(id)
        })
        return id
    }

    /// The pending paste was stored (it becomes the file chip in its place) or failed (the chip goes).
    public func settlePendingImage(_ id: Int, path: String?) {
        if let path { chips.settle(id, path: path) } else { chips.remove(id) }
    }

    private func chipsChanged() {
        for item in chips.items { ensurePicture(item) }
        rebuildStrip()
        applyState()
        onHeightChange?()
        if !fromController { onChipsChanged?(chips.persisted) }
    }

    private func ensurePicture(_ item: ChatChipItem) {
        guard case .file(let path) = item.kind, chips.pictures[item.id] == nil else { return }
        if ChatChipImages.isSVG(path) { chips.setPicture(item.id, .icon); return }
        chips.setPicture(item.id, .loading)
        let images = chipLoader.images, pixels = Int(ceil(ChatChipView.size * chipScale)), id = item.id
        var result: ChatChipImage = .unreadable
        chipLoader.run({ result = images.load(path: path, maxPixel: pixels) }, { [weak self] in self?.pictureLoaded(id, result) })
    }

    private func pictureLoaded(_ id: Int, _ result: ChatChipImage) {
        guard chips.item(id) != nil else { return }
        switch result {
        case .image(let image): chips.setPicture(id, .image(image))
        case .tooLarge:
            chips.setPicture(id, .icon)
            setStatus("Image is too large to preview")
        case .svg, .unreadable: chips.setPicture(id, .icon)
        }
        if let view = strip.chipViews.first(where: { $0.item.id == id }), let picture = chips.pictures[id] { view.setPicture(picture) }
    }

    /// The strip is made again when the box has a different width than the one it was laid out for.
    private func refreshStrip() {
        if !chips.items.isEmpty, max(0, boxWidth - inner * 2) != stripWidth { rebuildStrip() }
    }

    private func rebuildStrip() {
        let width = max(0, boxWidth - inner * 2)
        stripWidth = width
        stripTotal = strip.show(chips.items, pictures: chips.pictures, width: width)
    }

    /// The thumbnail and preview a chip shows, for the controller's preview overlay.
    func picture(of id: Int) -> ChatChipPicture? { chips.pictures[id] }

    public func layoutComposer() {
        let (used, input) = measureInput()
        refreshStrip()
        let boxH = boxHeight(input: input)
        box.frame = CGRect(x: Self.sidePad, y: Self.bottomPad, width: boxWidth, height: boxH)
        status.frame = CGRect(x: Self.sidePad + 4, y: Self.bottomPad + boxH, width: max(0, boxWidth - 8), height: statusShownHeight)
        let innerW = max(0, boxWidth - inner * 2)
        let rowHeight = max(input, Self.buttonSize)
        strip.frame = CGRect(x: inner, y: inner + rowHeight + Self.stripGap, width: innerW, height: max(0, stripTotal - Self.stripGap))
        plusButton.frame = CGRect(x: inner, y: inner, width: Self.buttonSize, height: Self.buttonSize)
        sendButton.frame = CGRect(x: inner + innerW - Self.buttonSize, y: inner, width: Self.buttonSize, height: Self.buttonSize)
        let warningX = sendButton.frame.minX - Self.warningGap - Self.warningSize
        draftWarning.frame = CGRect(x: warningX, y: inner + (Self.buttonSize - Self.warningSize) / 2, width: Self.warningSize, height: Self.warningSize)
        let inputRight = draftWarning.isHidden ? sendButton.frame.minX : warningX - Self.warningGap
        scroll.frame = CGRect(x: plusButton.frame.maxX, y: inner, width: max(0, inputRight - plusButton.frame.maxX), height: input)
        inputView.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(input, used)))
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutComposer()
    }

    public override func layout() { super.layout(); layoutComposer() }
}

/// The web chat's body: the page's web view above Clawd's native composer. It is also the panel's text surface for the controller (draft,
/// status, send lock, turn), and it hands the conversation to the page through the bridge.
public final class ChatWebBody: NSView, ChatContainerBody, ChatPanelSurface {
    public private(set) var page: ChatWebPage?
    public let composer = ChatComposerView()
    private let environment: ChatWebEnvironment
    private var look = ChatWebLook.dark

    public var onSend: (() -> Void)? {
        get { composer.onSend }
        set { composer.onSend = newValue }
    }
    public var onStop: (() -> Void)? {
        get { composer.onStop }
        set { composer.onStop = newValue }
    }
    public var inputView: ChatInputTextView { composer.inputView }
    /// The text changed (typed, pasted, dropped or set): the controller keeps the draft and the history place.
    public var onDraftChanged: (() -> Void)? {
        get { composer.onDraftChanged }
        set { composer.onDraftChanged = newValue }
    }
    public func setDraftWarning(_ shown: Bool) { composer.setDraftWarning(shown) }
    public var inputText: String {
        get { composer.inputView.string }
        set { composer.setText(newValue) }
    }

    private let overlay = ChatDropOverlay()
    /// The full-size image preview (Q14, D12): a view inside the body, above the transcript and the composer, never a window.
    public let preview = ChatImagePreviewView()
    private var previewToken = 0
    /// The `/` picker and the mention hint (Q10): views inside the body, floating over the transcript, never windows. They take no layout height.
    public let picker = ChatPickerView()
    public let mentionHint = ChatMentionHintView()
    /// The queued messages between the transcript and the composer (Q12): part of the layout, so the web view above is as much shorter as the list is tall.
    public let queueList = ChatQueueListView()
    public private(set) var queueRows: [ChatQueueRow] = []
    private var queuePauseText: String?
    private var autocomplete = ChatAutocompleteState()
    /// `/resume <text>` was entered: the controller loads the folder's conversations (once per entry) and answers with `setResumeList`.
    public var onResumeListWanted: (() -> Void)?
    /// The conversations mode was left: a load in flight is of no use.
    public var onResumeListClosed: (() -> Void)?
    /// A conversation row was picked (a press, Tab or Enter).
    public var onResumePick: ((ChatResumeRow) -> Void)?
    /// The opening's attachments (the controller sets it): the drop's paths, the paste's image and the picker's file reach the composer through it.
    public var attachments: ChatAttachmentSession?
    /// A file drag came to the body (Orca's drop surface): a pending outside press becomes a drag (P1 A4 c).
    public var onFileDrag: (() -> Void)?
    /// A file drag left the body (`false`: exited) or ended or concluded there (`true`); a perform comes first and is answered by `onFileDrop`.
    public var onFileDragEnd: ((Bool) -> Void)?
    /// A drop's file paths, and whether it carried promises too; the controller answers.
    public var onFileDrop: (([String], Bool) -> Void)?

    public init(page: ChatWebPage, environment: ChatWebEnvironment, frame: CGRect) {
        self.page = page
        self.environment = environment
        super.init(frame: frame)
        wantsLayer = true
        ChatWebFonts.register(in: environment.pageDirectory)
        if let web = page.view { addSubview(web) }
        addSubview(composer)
        addSubview(queueList)
        addSubview(picker)
        addSubview(mentionHint)
        addSubview(preview)
        addSubview(overlay)
        composer.chipLoader = environment.attach.chipLoader
        composer.onChipOpen = { [weak self] item in self?.openPreview(item) }
        preview.onDismiss = { [weak self] in self?.closePreview() }
        composer.onHeightChange = { [weak self] in self?.layoutBody() }
        composer.onInputChanged = { [weak self] in self?.refreshAutocomplete() }
        composer.inputView.onPickerKey = { [weak self] key in self?.pickerKey(key) ?? false }
        picker.onChoose = { [weak self] item in self?.choose(item) }
        mentionHint.onAccept = { [weak self] in self?.acceptMention() }
        composer.inputView.fileDropTarget = self
        registerForDraggedTypes(ChatDropContent.registeredTypes)
        page.view?.onMenuCopy = { [weak self] in self?.copyFromMenu() }
        page.view?.onMenuPaste = { [weak self] in self?.inputView.paste(nil) }
        applyLook(ChatLook.dark)
        layoutBody()
    }
    public required init?(coder: NSCoder) { fatalError("ChatWebBody is built in code") }

    /// The web view, for the resize handles' wheel and the audit.
    public var scrollTarget: NSView? { page?.view }

    // MARK: the image preview (Q14)

    /// The preview overlay is up: Esc closes it (Q11) before the page's layer and before an interrupt.
    public var isPreviewOpen: Bool { preview.isShown }

    public func closePreview() {
        previewToken += 1
        preview.hide()
    }

    /// A chip was clicked: the overlay covers the body with the label as title and the image made at the size it shows (one ImageIO call off the
    /// main thread). An SVG, an unreadable file or an image over the pixel cap says "Preview unavailable".
    func openPreview(_ item: ChatChipItem) {
        previewToken += 1
        let token = previewToken
        switch item.kind {
        case .unavailable: return
        case .pending:
            var thumbnail: CGImage?
            if case .image(let image)? = composer.picture(of: item.id) { thumbnail = image }
            preview.showSaving(title: item.label, thumbnail: thumbnail)
        case .file(let path):
            preview.show(title: item.label)
            if ChatChipImages.isSVG(path) { preview.setUnavailable(); return }
            let images = composer.chipLoader.images, pixels = preview.previewPixels
            var result: ChatChipImage = .unreadable
            composer.chipLoader.run({ result = images.load(path: path, maxPixel: pixels) }, { [weak self] in
                guard let self, self.previewToken == token else { return }
                if case .image(let image) = result { self.preview.setImage(image) } else { self.preview.setUnavailable() }
            })
        }
    }

    // MARK: the `/` picker and the mention hint (Q10)

    /// The catalog the picker offers; an open picker is made again.
    public func setCatalog(_ entries: [ChatCommandEntry]) {
        autocomplete.setEntries(entries)
        applyAutocomplete()
    }
    /// The picker shows (rows or "No matching commands or skills").
    public var isPickerOpen: Bool { autocomplete.isOpen && picker.frame.height > 0 }
    public var autocompleteState: ChatAutocomplete { autocomplete.current }
    public var pickerActiveIndex: Int { autocomplete.active }
    /// Esc on an open picker: it stays closed for this trigger position until the token changes (Q11).
    public func dismissPicker() {
        autocomplete.dismiss()
        applyAutocomplete()
        notifyResumeMode()
    }

    /// The conversations loaded for the open list (nil: show "Loading" again). Ignored when the mode is not open.
    public func setResumeList(_ rows: [ChatResumeRow]?) {
        autocomplete.setResumeRows(rows)
        applyAutocomplete()
    }
    /// The rows of the open list, nil while loading or when no list is open.
    public var resumeRows: [ChatResumeRow]? { autocomplete.resumeRows }
    public var isResumeListOpen: Bool { autocomplete.conversations != nil }

    private func notifyResumeMode() {
        if autocomplete.takeListClosed() { onResumeListClosed?() }
        if autocomplete.takeListWanted() { onResumeListWanted?() }
    }

    private func refreshAutocomplete() {
        let input = composer.inputView
        let before = autocomplete
        autocomplete.refresh(text: input.string, caret: input.selectedRange().location, marked: input.hasMarkedText())
        if autocomplete != before { applyAutocomplete() }
        notifyResumeMode()
    }

    private func applyAutocomplete() {
        switch autocomplete.current {
        case .slash(let slash):
            picker.show(slash, active: autocomplete.active, look: look)
            mentionHint.hide()
        case .conversations(let conversations):
            picker.show(conversations, active: autocomplete.active, look: look)
            mentionHint.hide()
        case .mention(let query):
            picker.hide()
            mentionHint.show(query: query, look: look)
        case .none:
            if picker.isShown { picker.hide() }
            if mentionHint.isShown { mentionHint.hide() }
        }
        layoutFloating()
    }

    /// Down and Up wrap, Tab completes, Enter completes or, on a leading command whose name is already typed whole, sends (D17). Orca
    /// NC/use-native-chat-composer-keydown.ts:66-95. The send goes through the controller's one gate.
    private func pickerKey(_ key: ChatPickerKey) -> Bool {
        guard isPickerOpen, !autocomplete.items.isEmpty, !composer.inputView.hasMarkedText() else { return false }
        switch key {
        case .down, .up:
            _ = autocomplete.move(key == .down ? 1 : -1)
            picker.setActive(autocomplete.active)
        case .tab:
            if let item = autocomplete.activeItem { choose(item) }
        case .enter:
            guard let item = autocomplete.activeItem else { return false }
            if let slash = autocomplete.slash, item.kind == .command, slash.dispatchable, slash.query.lowercased() == item.name.lowercased() { composer.onSend?() }
            else { choose(item) }
        }
        return true
    }

    /// A picked row: a conversation resumes (the controller's gate decides); a command or skill completes the typed token.
    private func choose(_ item: ChatPickerItem) {
        guard item.kind == .conversation else { complete(item); return }
        guard let id = item.conversationId, let row = autocomplete.resumeRows?.first(where: { $0.id == id }) else { return }
        onResumePick?(row)
    }

    /// Replaces the typed `/token` with the item's token and a space, the caret after it. A pick never sends.
    private func complete(_ item: ChatPickerItem) {
        let input = composer.inputView
        guard let result = ChatPicker.apply(draft: input.string, caret: input.selectedRange().location, item: item) else { return }
        composer.setText(result.draft)
        input.setSelectedRange(NSRange(location: result.caret, length: 0))
    }

    private func acceptMention() {
        guard case .mention(let query) = autocomplete.current else { return }
        let input = composer.inputView
        guard let result = ChatPicker.applyMention(draft: input.string, caret: input.selectedRange().location, query: query) else { return }
        composer.setText(result.draft)
        input.setSelectedRange(NSRange(location: result.caret, length: 0))
    }

    public func setStatus(_ text: String) { composer.setStatus(text) }
    public var statusText: String { composer.statusText }
    public func setInputLocked(_ locked: Bool) { composer.setLocked(locked); attachments?.lockChanged() }

    /// The menu's Copy: the page's remembered selection goes to the pasteboard.
    private func copyFromMenu() { page?.menuCopy(to: environment.pasteboard, refused: { [weak self] in self?.setStatus(ChatWebPage.copyRefusedStatus) }) }
    /// The drop overlay is on screen (for the tests).
    public var isDropOverlayShown: Bool { overlay.isShown }
    public var dropOverlay: NSView { overlay }

    public func setConversation(_ entries: [ChatEntry], turn: ChatTurnState) {
        composer.setTurn(turn)
        page?.bridge.update(entries: entries, turn: turn)
    }

    /// Cmd+C with nothing selected in the input: the page's selection goes to the pasteboard.
    public func copyPageSelection() {
        pageCopyRequests += 1
        page?.copySelection(to: environment.pasteboard, refused: { [weak self] in self?.setStatus(ChatWebPage.copyRefusedStatus) })
    }
    /// How many times Cmd+C asked for the page's selection (for the tests).
    public private(set) var pageCopyRequests = 0

    /// The close: the page's handler, load and view go; the composer stays for the draft read.
    public func teardown() {
        page?.teardown()
        page = nil
    }

    public func applyLook(_ look: ChatLook) {
        self.look = look.isDark ? .dark : .light
        layer?.backgroundColor = self.look.canvas.cgColor
        page?.view?.underPageBackgroundColor = self.look.canvas
        composer.applyLook(self.look)
        overlay.apply(self.look)
        preview.apply(self.look)
        picker.apply(self.look)
        mentionHint.apply(self.look)
        queueList.apply(self.look)
    }

    // MARK: file drops (P2)

    /// The drag carries a file URL or a promise and the input takes one: the overlay shows and the drop gets `.copy` (Orca `dropEffect = 'copy'`).
    private func fileDragResult(_ sender: NSDraggingInfo, entering: Bool) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        guard ChatDropContent.carriesFiles(pasteboard) else { overlay.clear(); return [] }
        if entering { onFileDrag?() }
        guard !composer.isLocked else { overlay.clear(); return [] }
        overlay.show()
        return .copy
    }
    func fileDragEntered(_ sender: NSDraggingInfo) -> NSDragOperation { fileDragResult(sender, entering: true) }
    func fileDragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { fileDragResult(sender, entering: false) }
    func fileDragExited(_ sender: NSDraggingInfo?) { overlay.clear(); onFileDragEnd?(false) }
    func fileDragEnded(_ sender: NSDraggingInfo) { overlay.clear(); onFileDragEnd?(true) }
    func fileDragPrepare(_ sender: NSDraggingInfo) -> Bool { ChatDropContent.carriesFiles(sender.draggingPasteboard) && !composer.isLocked }
    func fileDragPerform(_ sender: NSDraggingInfo) -> Bool {
        overlay.clear()
        let pasteboard = sender.draggingPasteboard
        guard ChatDropContent.carriesFiles(pasteboard), !composer.isLocked else { return false }
        onFileDrop?(ChatDropContent.paths(pasteboard), ChatDropContent.carriesPromise(pasteboard))
        return true
    }
    func fileDragConclude(_ sender: NSDraggingInfo) { overlay.clear(); onFileDragEnd?(true) }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { fileDragEntered(sender) }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { fileDragUpdated(sender) }
    public override func draggingExited(_ sender: NSDraggingInfo?) { fileDragExited(sender) }
    public override func draggingEnded(_ sender: NSDraggingInfo) { fileDragEnded(sender) }
    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { fileDragPrepare(sender) }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { fileDragPerform(sender) }
    public override func concludeDragOperation(_ sender: NSDraggingInfo?) { if let sender { fileDragConclude(sender) } }

    func layoutBody() {
        // The width first: the chip strip wraps for it, and the height the composer asks for depends on the wrapping.
        if composer.frame.width != bounds.width { composer.setFrameSize(NSSize(width: bounds.width, height: composer.frame.height)) }
        let height = composer.preferredHeight()
        composer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        let listHeight = queueListHeight
        queueList.isHidden = listHeight <= 0
        queueList.frame = CGRect(x: 0, y: height, width: bounds.width, height: listHeight)
        page?.view?.frame = CGRect(x: 0, y: height + listHeight, width: bounds.width, height: max(0, bounds.height - height - listHeight))
        overlay.frame = bounds
        preview.frame = bounds
        layoutFloating()
    }

    /// The transcript area: the body less the composer (the queue list is stacked inside it, and the `/` picker floats over both).
    public var transcriptAreaHeight: CGFloat { max(0, bounds.height - composer.preferredHeight()) }

    /// The queue list's cap (D15): at most half the transcript area, and the area less 64 pt, so the transcript keeps at least 64 pt; never negative.
    public static func queueListCap(area: CGFloat) -> CGFloat { max(0, min(area / 2, area - 64)) }

    /// The height the queue list takes: its content up to the cap, 0 with no cards.
    public var queueListHeight: CGFloat {
        guard queueList.hasCards else { return 0 }
        return min(queueList.contentHeight, Self.queueListCap(area: transcriptAreaHeight))
    }

    /// The cards the list shows, and the pause row's words when the queue's pause holds one of them (Q12).
    public func setQueue(_ rows: [ChatQueueRow], pauseText: String?) {
        queueRows = rows
        queuePauseText = pauseText
        queueList.show(rows, pauseText: pauseText, look: look)
        layoutBody()
    }
    public var queuePauseRowText: String? { queuePauseText }

    /// The picker and the hint rest 4 pt above the status line when it shows, else above the box (Q10). The picker has the box's edges and is as
    /// tall as its rows up to max(0, min(288, the transcript area - 8)) (D15); the hint is inset 12 pt (16 from 640 pt wide) from them.
    private func layoutFloating() {
        let bottom = composer.frame.minY + composer.floatAnchor() + ChatWebLook.scaled(4)
        let side = ChatComposerView.sidePad
        let width = max(0, bounds.width - side * 2)
        if picker.isShown {
            let most = max(0, min(ChatPickerView.maxHeight, transcriptAreaHeight - ChatWebLook.scaled(8)))
            picker.frame = CGRect(x: side, y: bottom, width: width, height: min(picker.contentHeight, most))
        }
        if mentionHint.isShown {
            // Orca's `sm:` breakpoint (640 px) is in page pixels, and at the page's zoom one page pixel is `textScale` of a point.
            let inset = bounds.width / ChatWebLook.textScale >= 640 ? ChatWebLook.scaled(16) : ChatWebLook.scaled(12)
            mentionHint.frame = CGRect(x: side + inset, y: bottom, width: max(0, width - inset * 2), height: ChatMentionHintView.height)
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutBody()
    }

    public override func layout() { super.layout(); layoutBody() }

    /// The titles the audit accepts for the composer's menu, separators left out: Copy and Paste, and Copy Session ID once a session exists (Q19).
    public static func contextMenuTitlesAllowed(_ titles: [String]) -> Bool {
        titles == ["Copy", "Paste"] || titles == ["Copy", "Paste", ChatSessionIDMenu.title]
    }

    /// What the panel audit checks about the web kind (R5): the page's own audit, one web view in the body, and the input box.
    public func auditProblems() -> [String] {
        var found: [String] = []
        if let page { found += page.auditProblems() } else { found.append("the web chat has no page") }
        if subviews.filter({ $0 is WKWebView }).count != 1 { found.append("the body does not hold exactly one web view") }
        if page?.view?.superview !== self { found.append("the web view is not in the body") }
        if composer.superview !== self || inputView.enclosingScrollView?.superview == nil { found.append("the composer's input box is missing") }
        let input = inputView
        if input.isAutomaticLinkDetectionEnabled { found.append("input link detection is on") }
        if input.isAutomaticDataDetectionEnabled { found.append("input data detection is on") }
        if input.assignedMenu != nil { found.append("input has a context menu") }
        if let titles = input.contextMenuTitles, !Self.contextMenuTitlesAllowed(titles) {
            found.append("input's context menu is not exactly Copy and Paste (and Copy Session ID)")
        }
        if let web = page?.view, !web.registeredDraggedTypes.isEmpty { found.append("the web view is registered for drags") }
        let wanted = Set(ChatDropContent.registeredTypes)
        if !wanted.isSubset(of: Set(registeredDraggedTypes)) { found.append("the body is not registered for file drops") }
        return found
    }
}
