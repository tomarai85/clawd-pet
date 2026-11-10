import AppKit

/// Orca's drop overlay (native-chat/NativeChatPaneFileDropSurface.tsx:98-119): a scrim in `--chat-canvas` at 80 %, and a centred card with a
/// dashed 1 pt border, a paperclip in a 36 pt circle, the title and the subtitle. It registers nothing and its hit test answers nil, so the
/// drag and every click go through it to what is below (pointer-events-none).
public final class ChatDropOverlay: NSView {
    static let title = "Drop to attach to this chat"
    static let subtitle = "Files are added to your message as paths the agent can read."
    static let cardPadX: CGFloat = 32, cardPadY: CGFloat = 20, circle: CGFloat = 36, glyph: CGFloat = 18, gap: CGFloat = 4, radius: CGFloat = 14
    /// `mb-1` on the circle plus the column's `gap-1` (:103-109): 8 pt between the circle and the title; the title and the subtitle are `gap-1` (4 pt) apart.
    public static let circleGap: CGFloat = 8
    /// `font-medium` (500), not bold.
    public static let titleWeight = NSFont.Weight.medium

    private let card = NSView()
    private let dash = CAShapeLayer()
    private let disc = NSView()
    private let clip = NSImageView()
    private let titleLabel = NSTextField(labelWithString: title)
    private let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
    private var look = ChatWebLook.dark

    /// The title's font: the page's face at the medium weight.
    public static var titleFont: NSFont {
        let base = ChatWebFonts.font(size: 14)
        let medium = NSFontDescriptor(fontAttributes: [.family: base.familyName ?? base.fontName, .traits: [NSFontDescriptor.TraitKey.weight: titleWeight]])
        return NSFont(descriptor: medium, size: 14) ?? .systemFont(ofSize: 14, weight: titleWeight)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        card.wantsLayer = true
        card.layer?.cornerRadius = Self.radius
        card.layer?.cornerCurve = .continuous
        card.layer?.shadowOpacity = 0.18; card.layer?.shadowRadius = 12; card.layer?.shadowOffset = CGSize(width: 0, height: -10)
        card.layer?.shadowColor = NSColor.black.cgColor
        dash.fillColor = nil
        dash.lineWidth = 1
        dash.lineDashPattern = [4, 3]
        card.layer?.addSublayer(dash)
        disc.wantsLayer = true
        disc.layer?.cornerRadius = Self.circle / 2
        clip.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: Self.glyph, weight: .regular))
        titleLabel.font = ChatWebFonts.font(size: 14)
        titleLabel.font = Self.titleFont
        titleLabel.alignment = .center
        subtitleLabel.font = ChatWebFonts.font(size: 12)
        subtitleLabel.alignment = .center
        subtitleLabel.isSelectable = false
        subtitleLabel.maximumNumberOfLines = 0
        disc.addSubview(clip)
        for view in [disc, titleLabel, subtitleLabel] { card.addSubview(view) }
        addSubview(card)
        setAccessibilityElement(false)
        apply(.dark)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var isFlipped: Bool { false }

    func apply(_ look: ChatWebLook) {
        self.look = look
        layer?.backgroundColor = look.canvas.withAlphaComponent(0.8).cgColor
        card.layer?.backgroundColor = look.card.cgColor
        dash.strokeColor = look.foreground.withAlphaComponent(0.3).cgColor
        disc.layer?.backgroundColor = look.foreground.withAlphaComponent(0.1).cgColor
        clip.contentTintColor = look.foreground
        titleLabel.textColor = look.foreground
        subtitleLabel.textColor = look.mutedForeground
        needsLayout = true
    }

    /// Test seam: the scale `dash` takes instead of the window's, and what it holds now.
    public var backingScaleOverride: CGFloat?
    public var dashContentsScale: CGFloat { dash.contentsScale }
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        dash.contentsScale = backingScale(override: backingScaleOverride)
    }

    var isShown: Bool { !isHidden }
    func show() { isHidden = false; needsLayout = true }
    func clear() { isHidden = true }

    public override func layout() {
        super.layout()
        let maxCard = max(0, bounds.width - 24)
        let innerMax = max(0, maxCard - Self.cardPadX * 2)
        titleLabel.sizeToFit()
        subtitleLabel.preferredMaxLayoutWidth = innerMax
        let wanted = subtitleLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: innerMax, height: 10_000)) ?? subtitleLabel.intrinsicContentSize
        let content = min(innerMax, max(titleLabel.frame.width, wanted.width))
        let subtitleHeight = ceil(wanted.height)
        let titleHeight = ceil(titleLabel.frame.height)
        let height = Self.cardPadY * 2 + Self.circle + Self.circleGap + titleHeight + Self.gap + subtitleHeight
        let width = content + Self.cardPadX * 2
        card.frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        var y = height - Self.cardPadY - Self.circle
        disc.frame = CGRect(x: (width - Self.circle) / 2, y: y, width: Self.circle, height: Self.circle)
        clip.frame = CGRect(x: (Self.circle - Self.glyph) / 2, y: (Self.circle - Self.glyph) / 2, width: Self.glyph, height: Self.glyph)
        y -= Self.circleGap + titleHeight
        titleLabel.frame = CGRect(x: Self.cardPadX, y: y, width: content, height: titleHeight)
        y -= Self.gap + subtitleHeight
        subtitleLabel.frame = CGRect(x: Self.cardPadX, y: y, width: content, height: subtitleHeight)
        dash.frame = card.bounds
        dash.path = CGPath(roundedRect: card.bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    }

    /// The card's frame inside the overlay and the texts, for the tests.
    var cardFrame: CGRect { card.frame }
    public var titleIsBold: Bool { titleLabel.font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false }
    var titleText: String { titleLabel.stringValue }
    var subtitleText: String { subtitleLabel.stringValue }
}
