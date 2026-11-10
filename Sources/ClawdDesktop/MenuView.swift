import AppKit
import ClawdCore
import ClawdRendering

/// What the menu's controller needs to do to a menu window. The real one is `MenuPanel`; a test can supply a fake.
public protocol MenuSurface: AnyObject {
    /// The number of the opening this window belongs to. A constant of the window: a click that reaches it late still names it.
    var gen: Int { get }
    func update(selection: MenuSelection)
    /// The item that has just been picked flashes until the menu closes (nil: none).
    func flash(_ item: MenuItem?)
    /// Starts and stops the hover and away tracking. Every close removes the tracking areas.
    func armTracking()
    func disarmTracking()
}

/// What the menu's view tells whoever runs the menu (the `MenuController`). `gen` is the view's own number, never the agent's live one.
public protocol MenuViewDelegate: AnyObject {
    func menuView(gen: Int, mouseDown event: NSEvent, kind: String, hit: MenuHit)
    /// The item under the pointer changed (nil: none).
    func menuView(gen: Int, hover item: MenuItem?)
    func menuView(gen: Int, pointerInside: Bool)
}

/// The menu's picture and its mouse handling. Hover is told by tracking areas (entered and exited only, active in any app: the menu
/// window is never key), never by mouse-moved events, and the areas exist only while the menu is open.
public final class MenuView: NSView {
    public let gen: Int
    public let layout: MenuLayout
    public weak var delegate: MenuViewDelegate?
    public private(set) var visual: MenuVisual
    public var thumbnails: [String: Raster]
    public var pixelScale: Double { didSet { if pixelScale != oldValue { redraw() } } }
    public private(set) var armed = false

    public init(layout: MenuLayout, gen: Int, selection: MenuSelection = MenuSelection(), thumbnails: [String: Raster] = [:], pixelScale: Double = 2) {
        self.layout = layout; self.gen = gen; self.thumbnails = thumbnails; self.pixelScale = pixelScale
        visual = MenuVisual(selection: selection)
        super.init(frame: CGRect(origin: .zero, size: layout.size))
        wantsLayer = true
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        layer?.contentsGravity = .bottomLeft
        redraw()
    }
    required init?(coder: NSCoder) { nil }

    public override var acceptsFirstResponder: Bool { false }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: picture

    func redraw() {
        guard let image = try? MenuRenderer.render(layout: layout, visual: visual, thumbnails: thumbnails, pixelScale: pixelScale).cgImage() else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contentsScale = max(1, min(4, pixelScale.rounded()))
        layer?.contents = image
        CATransaction.commit()
    }

    public func update(selection: MenuSelection) {
        guard visual.selection != selection else { return }
        visual.selection = selection; redraw()
    }
    public func flash(_ item: MenuItem?) {
        let index = item.flatMap { layout.items.firstIndex(of: $0) }
        guard visual.flashItem != index else { return }
        visual.flashItem = index; redraw()
    }

    /// The point of a mouse event in the layout's coordinates (points, y down).
    func layoutPoint(of event: NSEvent) -> (point: CGPoint, inside: Bool) {
        let p = convert(event.locationInWindow, from: nil)
        return (CGPoint(x: p.x, y: bounds.height - p.y), bounds.contains(p))
    }

    // MARK: mouse

    public override func mouseDown(with event: NSEvent) { down(event, "mouseDown") }
    public override func rightMouseDown(with event: NSEvent) { down(event, "rightMouseDown") }
    public override func otherMouseDown(with event: NSEvent) { down(event, "otherMouseDown") }
    /// The matching ups end here: a press on the menu is never somebody else's.
    public override func mouseUp(with event: NSEvent) {}
    public override func rightMouseUp(with event: NSEvent) {}
    public override func otherMouseUp(with event: NSEvent) {}
    public override func scrollWheel(with event: NSEvent) {}

    private func down(_ event: NSEvent, _ kind: String) {
        let located = layoutPoint(of: event)
        delegate?.menuView(gen: gen, mouseDown: event, kind: kind, hit: located.inside ? layout.hit(at: located.point) : .gap)
    }

    // MARK: hover

    /// Entered and exited events carry the pointer's place; the state is read from it, whichever area it was.
    public override func mouseEntered(with event: NSEvent) { pointerChanged(event) }
    public override func mouseExited(with event: NSEvent) { pointerChanged(event) }

    private func pointerChanged(_ event: NSEvent) {
        guard armed else { return }
        let located = layoutPoint(of: event)
        let item = located.inside ? layout.item(at: located.point) : nil
        let row = located.inside ? layout.row(at: located.point) : nil
        let index = item.flatMap { layout.items.firstIndex(of: $0) }
        if visual.hoverRow != row || visual.hoverItem != index {
            visual.hoverRow = row; visual.hoverItem = index; redraw()
        }
        delegate?.menuView(gen: gen, pointerInside: located.inside)
        delegate?.menuView(gen: gen, hover: item)
    }

    public func armTracking() {
        guard !armed else { return }
        armed = true
        addAreas()
    }
    public func disarmTracking() {
        armed = false
        for area in trackingAreas { removeTrackingArea(area) }
        if visual.hoverRow != nil || visual.hoverItem != nil { visual.hoverRow = nil; visual.hoverItem = nil; redraw() }
    }
    /// AppKit asks for the areas again when the view's geometry changes; while the menu is closed there are none to give.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard armed else { for area in trackingAreas { removeTrackingArea(area) }; return }
        if trackingAreas.isEmpty { addAreas() }
    }

    private func addAreas() {
        // One area over the whole panel (the 8 s away rule), one per row (the row's hover background) and one per item (its highlight).
        add(bounds)
        for row in layout.rows { add(viewRect(row.rect)) }
        for item in layout.items where item.clickable { add(viewRect(item.rect)) }
    }
    private func viewRect(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height) }
    private func add(_ rect: CGRect) {
        addTrackingArea(NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }
}

/// One menu window, for one opening. It is built when the menu opens and dropped when it closes (`PanelSet`), so a click that is still
/// on its way to it after the close can only reach this window, whose `gen` is its own.
public final class MenuPanel: PetPanel, MenuSurface {
    public let gen: Int
    public let menuView: MenuView

    public init(overFullScreen: Bool, gen: Int, view: MenuView) {
        self.gen = gen; menuView = view
        super.init(overFullScreen: overFullScreen)
        contentView = view
    }

    public func update(selection: MenuSelection) { menuView.update(selection: selection) }
    public func flash(_ item: MenuItem?) { menuView.flash(item) }
    public func armTracking() { menuView.armTracking() }
    public func disarmTracking() { menuView.disarmTracking() }
}
