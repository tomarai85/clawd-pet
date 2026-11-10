import AppKit
import ClawdCore

/// The full-size image preview (spec Q14, D12): an overlay inside the panel's body, never a window and never key (Orca's in-window Dialog,
/// NC/NativeChatImageAttachmentPreview.tsx:177-210). The title is the chip's label; the image is fit within 90 % of the body's width and 75 % of
/// its height, or "Preview unavailable" with an image icon. Esc (the controller's Q11 step) or a click outside the image closes it.
public final class ChatImagePreviewView: NSView {
    static let widthShare: CGFloat = 0.9, heightShare: CGFloat = 0.75
    static let pad: CGFloat = 12, titleHeight: CGFloat = 20, gap: CGFloat = 12

    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let imageLayerView = NSView()
    private let message = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var look = ChatWebLook.dark
    private var image: CGImage?
    private var unavailable = false
    /// The preview was dismissed by a click outside the image.
    var onDismiss: (() -> Void)?

    public private(set) var title = ""
    public var isShown: Bool { !isHidden }
    public var showsUnavailable: Bool { !message.isHidden && message.stringValue == "Preview unavailable" }
    public var hasImage: Bool { image != nil }
    /// The frame the image takes inside the body (for the tests).
    public var imageFrame: CGRect { imageLayerView.convert(imageLayerView.bounds, to: self) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        imageLayerView.wantsLayer = true
        imageLayerView.layer?.cornerRadius = 6
        imageLayerView.layer?.masksToBounds = true
        imageLayerView.layer?.contentsGravity = .resizeAspect
        titleLabel.font = ChatWebFonts.font(size: 14)
        titleLabel.lineBreakMode = .byTruncatingTail
        message.font = ChatWebFonts.font(size: 14)
        message.isHidden = true
        icon.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        icon.isHidden = true
        for view in [titleLabel, imageLayerView, icon, message] { card.addSubview(view) }
        addSubview(card)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Full-size image preview")
        apply(.dark)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { false }
    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ look: ChatWebLook) {
        self.look = look
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        card.layer?.backgroundColor = look.popover.cgColor
        card.layer?.borderColor = look.border.cgColor
        titleLabel.textColor = look.foreground
        message.textColor = look.mutedForeground
        icon.contentTintColor = look.mutedForeground
    }

    /// Shows the preview with its title. The picture arrives later through `setImage` or `setUnavailable`; until then the card shows the title only.
    func show(title: String) {
        self.title = title
        titleLabel.stringValue = title
        titleLabel.toolTip = title
        image = nil; unavailable = false
        imageLayerView.layer?.contents = nil
        message.isHidden = true; icon.isHidden = true
        isHidden = false
        needsLayout = true
        layoutCard()
    }

    /// A pending paste's preview: the title and a note that the image is being saved.
    func showSaving(title: String, thumbnail: CGImage?) {
        show(title: title)
        if let thumbnail { setImage(thumbnail) } else { setMessage("Saving pasted image\u{2026}") }
    }

    func setImage(_ picture: CGImage) {
        guard isShown else { return }
        image = picture
        unavailable = false
        imageLayerView.layer?.contents = picture
        message.isHidden = true; icon.isHidden = true
        layoutCard()
    }

    func setUnavailable() {
        guard isShown else { return }
        setMessage("Preview unavailable")
    }

    private func setMessage(_ text: String) {
        image = nil; unavailable = true
        imageLayerView.layer?.contents = nil
        message.stringValue = text
        message.isHidden = false; icon.isHidden = false
        layoutCard()
    }

    func hide() {
        isHidden = true
        image = nil; unavailable = false
        imageLayerView.layer?.contents = nil
    }

    /// The most the image may take: 90 % of the body's width and 75 % of its height.
    public var imageLimit: CGSize { CGSize(width: bounds.width * Self.widthShare, height: bounds.height * Self.heightShare) }

    /// The pixel size to ask ImageIO for: the limit times the backing scale.
    public var previewPixels: Int {
        let scale = window?.backingScaleFactor ?? 2
        return Int(ceil(max(imageLimit.width, imageLimit.height) * scale))
    }

    private func layoutCard() {
        let limit = imageLimit
        var content = limit
        if let image {
            let ratio = CGFloat(image.width) / max(1, CGFloat(image.height))
            var width = limit.width, height = width / ratio
            if height > limit.height { height = limit.height; width = height * ratio }
            content = CGSize(width: max(1, width), height: max(1, height))
        } else {
            content = CGSize(width: min(limit.width, 280), height: min(limit.height, 120))
        }
        let cardSize = CGSize(width: content.width + Self.pad * 2, height: content.height + Self.pad * 2 + Self.titleHeight + Self.gap)
        card.frame = CGRect(x: (bounds.width - cardSize.width) / 2, y: (bounds.height - cardSize.height) / 2, width: cardSize.width, height: cardSize.height)
        titleLabel.frame = CGRect(x: Self.pad, y: cardSize.height - Self.pad - Self.titleHeight, width: content.width, height: Self.titleHeight)
        imageLayerView.frame = CGRect(x: Self.pad, y: Self.pad, width: content.width, height: content.height)
        if unavailable {
            message.sizeToFit(); icon.sizeToFit()
            let total = icon.frame.width + 6 + message.frame.width
            let x = Self.pad + (content.width - total) / 2, mid = Self.pad + content.height / 2
            icon.frame.origin = CGPoint(x: x, y: mid - icon.frame.height / 2)
            message.frame.origin = CGPoint(x: x + icon.frame.width + 6, y: mid - message.frame.height / 2)
        }
    }

    public override func layout() { super.layout(); layoutCard() }
    public override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutCard() }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    /// A click outside the image closes the preview; a click on the image keeps it.
    public override func mouseDown(with event: NSEvent) {
        dismissByClick(at: convert(event.locationInWindow, from: nil))
    }
    public func dismissByClick(at place: CGPoint) {
        if !(imageFrame.contains(place) && image != nil) { onDismiss?() }
    }
}
