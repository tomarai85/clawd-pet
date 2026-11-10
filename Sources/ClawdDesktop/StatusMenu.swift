import AppKit
import ClawdCore
import ClawdRendering

/// One status item in the menu bar, as the runtime holds it. The production surface wraps the system's item; a test supplies a fake, so no
/// real item is ever made in a test process.
public protocol StatusItemSurface: AnyObject {
    /// Set at every creation, the re-creations included, so the system finds the item's saved place again.
    var autosaveName: String? { get set }
    /// The item's menu: empty until it opens, its rows are built by the delegate.
    var menu: NSMenu? { get set }
    func setImage(_ image: NSImage, label: String)
    func setOpacity(_ alpha: Double)
    /// Takes down the menu if it is open.
    func cancelMenuTracking()
    func remove()
    /// The window of the item's button: a mouse-down on it opens the trace's interval.
    var buttonWindow: NSWindow? { get }
}

/// The rows of the icon's menu. `openChat` and `closeChat` are one slot with two faces, and so are `hide` and `show`: each face acts only when
/// the state at the pick still matches its label.
public enum StatusMenuRowKind: String, Equatable { case settings, openChat, closeChat, hide, show, quit }

/// What the rows depend on, as the runtime reads it at the moment the menu opens.
public struct StatusMenuState: Equatable {
    /// Hidden by the user (`hiddenUntil` is -1 or in the future).
    public var hiddenByUser: Bool
    /// Quiet for any other reason.
    public var quiet: Bool
    /// Chat is on in control.json and the environment has a chat.
    public var chatAvailable: Bool
    public var chatOpen: Bool
    public init(hiddenByUser: Bool = false, quiet: Bool = false, chatAvailable: Bool = true, chatOpen: Bool = false) {
        self.hiddenByUser = hiddenByUser; self.quiet = quiet; self.chatAvailable = chatAvailable; self.chatOpen = chatOpen
    }
}

/// One row of the menu; a nil kind is the separator.
public struct StatusMenuEntry: Equatable {
    public let kind: StatusMenuRowKind?
    public let title: String
    public let enabled: Bool
}

/// The icon's menu as pure data, and the constants it runs on.
public enum StatusMenu {
    /// Every hide the icon makes lasts this long (Q1): the icon's row and General's hide row read this one constant.
    public static let hideMinutes = 60
    public static let autosaveName = "ClawdStatusItem"
    public static let label = "Clawd"

    /// The rows for a state (D20): Settings…, chat, then hide or show, a separator, quit.
    public static func entries(for state: StatusMenuState) -> [StatusMenuEntry] {
        let chatEnabled = state.chatOpen || (state.chatAvailable && !state.hiddenByUser && !state.quiet)
        return [
            StatusMenuEntry(kind: .settings, title: "Settings\u{2026}", enabled: true),
            StatusMenuEntry(kind: state.chatOpen ? .closeChat : .openChat, title: state.chatOpen ? "Close Chat" : "Open Chat", enabled: chatEnabled),
            state.hiddenByUser ? StatusMenuEntry(kind: .show, title: "Show Clawd", enabled: true)
                               : StatusMenuEntry(kind: .hide, title: "Hide Clawd for 1 Hour", enabled: true),
            StatusMenuEntry(kind: nil, title: "", enabled: false),
            StatusMenuEntry(kind: .quit, title: "Quit Clawd", enabled: true),
        ]
    }

    /// Both rows write the same key, so they share the right-click menu's queue key `hide` and the newest pick wins.
    public static var hideAction: MenuAction {
        MenuAction(key: "hide", value: String(hideMinutes), queueKey: "hide", arguments: ["hide", String(hideMinutes)])
    }
    public static var showAction: MenuAction { MenuAction(key: "hide", value: "show", queueKey: "hide", arguments: ["show"]) }

    /// An opaque pixel whose luma is below this is an eye: the plain look's eyes are 20,20,19 and its body 215,119,87 (luma 144).
    public static let eyeLumaBelow = 60

    /// The idle frame as a template: Clawd cropped to his opaque bounds and centered in a square of the longer side plus 2 cells (an odd
    /// leftover cell goes right or bottom). He is black with his own alpha, so the menu bar tints him; the eyes are alpha 0, so the bar
    /// shows through them.
    public static func templateRaster(from idle: Raster) -> Raster {
        var minX = idle.width, minY = idle.height, maxX = -1, maxY = -1
        for y in 0..<idle.height { for x in 0..<idle.width where idle[x, y].a != 0 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= 0 else { return Raster(width: idle.width, height: idle.height) }
        let w = maxX - minX + 1, h = maxY - minY + 1, side = max(w, h) + 2
        let originX = (side - w) / 2, originY = (side - h) / 2
        var out = Raster(width: side, height: side)
        for y in 0..<h { for x in 0..<w {
            let p = idle[minX + x, minY + y]
            guard p.a != 0 else { continue }
            let luma = (299 * Int(p.r) + 587 * Int(p.g) + 114 * Int(p.b)) / 1000
            out[originX + x, originY + y] = Pixel(0, 0, 0, luma < eyeLumaBelow ? 0 : p.a)
        } }
        return out
    }

    /// The icon: the template at twice the cells, one cell to the point, named for accessibility.
    public static func templateImage(from idle: Raster) -> NSImage? {
        let template = templateRaster(from: idle)
        var big = Raster(width: template.width * 2, height: template.height * 2)
        for y in 0..<big.height { for x in 0..<big.width { big[x, y] = template[x / 2, y / 2] } }
        guard let cg = try? big.cgImage() else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: Double(template.width), height: Double(template.height)))
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }

    /// The system's status bar. The only place of Sources that names it; only `RuntimeEnvironment.production` names this.
    public static let productionSurface: () -> StatusItemSurface = { SystemStatusItem() }
}

/// What the trace line says about the other surfaces at the moment of a notification.
public struct StatusTraceFields {
    public var settings: String
    public var chat: String
    public var active: Bool
    public init(settings: String, chat: String, active: Bool) { self.settings = settings; self.chat = chat; self.active = active }
}

/// Owns the one item and its menu. It holds no timer and no observer; the rows are built when the menu opens, never before.
public final class StatusMenuController: NSObject, NSMenuDelegate {
    private let factory: (() -> StatusItemSurface)?
    private let state: () -> StatusMenuState
    private let image: () -> NSImage?
    private let pick: (StatusMenuRowKind) -> Void
    private let log: (String) -> Void
    /// The application's current event, the clock (the runtime's), and the other surfaces' state: the trace compares time stamps with them.
    private let event: () -> ChatCurrentEvent?
    private let now: () -> TimeInterval
    private let fields: () -> StatusTraceFields
    private var surface: StatusItemSurface?
    /// The trace's interval (M17): from the status button's mouse-down or the menu's opening, until 2 s after the menu closed or the pick ran.
    private var traceHow: String?
    private var traceEnd: TimeInterval?
    /// How long after the menu's close, or the pick, the trace goes on.
    public static let traceTail: TimeInterval = 2
    /// Whether the item was drawn dim (hidden by the user) at the last draw: nil before the first.
    private var drawnHidden: Bool?

    public var hasItem: Bool { surface != nil }

    /// `factory` nil: the environment has no status bar, so the controller never makes an item.
    public init(factory: (() -> StatusItemSurface)?, state: @escaping () -> StatusMenuState, image: @escaping () -> NSImage?,
                pick: @escaping (StatusMenuRowKind) -> Void, log: @escaping (String) -> Void,
                event: @escaping () -> ChatCurrentEvent? = { nil }, now: @escaping () -> TimeInterval = { 0 },
                fields: @escaping () -> StatusTraceFields = { StatusTraceFields(settings: "closed", chat: "closed", active: false) }) {
        self.factory = factory; self.state = state; self.image = image; self.pick = pick; self.log = log
        self.event = event; self.now = now; self.fields = fields
    }

    /// Makes the item unless one exists (the start; the end of a stand-down).
    public func build() {
        guard surface == nil else { return }
        create()
    }

    private func create() {
        guard let factory else { return }
        let made = factory()
        made.autosaveName = StatusMenu.autosaveName
        if let picture = image() { made.setImage(picture, label: StatusMenu.label) }
        let menu = NSMenu(title: StatusMenu.label)
        menu.autoenablesItems = false
        menu.delegate = self
        made.menu = menu
        surface = made
        drawnHidden = nil
        draw()
        log("STATUS item created")
    }

    /// The end of a scheduler batch and the end of a settings apply: the item goes for a stand-down and comes back when it ends; the
    /// opacity follows the hidden state.
    public func batchEnded(standDown: Bool) {
        if standDown {
            remove(reason: "exam")
        } else {
            if surface == nil { create() }
            draw()
        }
    }

    /// An open menu is taken down first, then the item goes.
    private func remove(reason: String) {
        guard let gone = surface else { return }
        gone.cancelMenuTracking()
        gone.remove()
        surface = nil
        traceHow = nil; traceEnd = nil
        drawnHidden = nil
        log("STATUS item removed reason=\(reason)")
    }

    /// Opacity 1 while shown and 0.5 while hidden by the user, set only when that state differs from the one last drawn.
    private func draw() {
        let hidden = state().hiddenByUser
        guard hidden != drawnHidden else { return }
        drawnHidden = hidden
        surface?.setOpacity(hidden ? 0.5 : 1)
    }

    // MARK: the menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in StatusMenu.entries(for: state()) {
            guard let kind = entry.kind else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.title, action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.isEnabled = entry.enabled
            menu.addItem(item)
        }
    }

    @objc private func picked(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let kind = StatusMenuRowKind(rawValue: raw) else { return }
        pick(kind)
        traceEnd = now() + Self.traceTail
    }

    // MARK: the trace (M17)

    /// How the menu was opened, from the event in hand.
    private static func how(_ event: ChatCurrentEvent?) -> String {
        guard let event else { return "none" }
        switch event.mouseDownButton {
        case .left?: return "mouse-left"
        case .right?: return "mouse-right"
        case .other?: return "mouse-other"
        case nil: return event.isMouse ? "none" : "key"
        }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        if traceHow == nil || traceEnd != nil { traceHow = Self.how(event()); traceEnd = nil }
        log("STATUS menu open how=\(traceHow ?? "none")")
    }

    public func menuDidClose(_ menu: NSMenu) {
        log("STATUS menu close")
        traceEnd = now() + Self.traceTail
    }

    /// An activation, key or main notification reached the application. A line is written only inside the interval, which the status button's
    /// mouse-down (the event in hand, any button) or the menu's opening starts; nothing observes and nothing is armed.
    public func trace(_ note: Notification.Name, window: NSWindow?) {
        let current = event()
        if let down = current?.mouseDownButton, let button = surface?.buttonWindow, current?.window === button {
            // A mouse-down on the button starts a fresh interval unless one is open.
            if traceHow == nil || traceEnd != nil { traceHow = Self.how(current); traceEnd = nil }
            _ = down
        }
        guard let how = traceHow else { return }
        if let end = traceEnd, now() > end { traceHow = nil; traceEnd = nil; return }
        let name = note.rawValue.replacingOccurrences(of: "NSApplication", with: "").replacingOccurrences(of: "NSWindow", with: "")
            .replacingOccurrences(of: "Notification", with: "")
        let kind = name.prefix(1).lowercased() + name.dropFirst()
        let seen = fields()
        let cls = window.map { String(describing: type(of: $0)) } ?? "none"
        log("STATUS trace note=\(kind) window=\(cls) settings=\(seen.settings) chat=\(seen.chat) active=\(seen.active ? 1 : 0) how=\(how)")
    }
}

/// The system's item. Its length is square, its behaviour is left empty (the user cannot remove it by dragging) and `isVisible` is never set.
final class SystemStatusItem: StatusItemSurface {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    var autosaveName: String? {
        get { item.autosaveName }
        set { if let newValue { item.autosaveName = newValue } }
    }
    var menu: NSMenu? {
        get { item.menu }
        set { item.menu = newValue }
    }
    func setImage(_ image: NSImage, label: String) {
        item.button?.image = image
        item.button?.setAccessibilityLabel(label)
        item.button?.toolTip = label
    }
    func setOpacity(_ alpha: Double) { item.button?.alphaValue = alpha }
    func cancelMenuTracking() { item.menu?.cancelTracking() }
    func remove() { NSStatusBar.system.removeStatusItem(item) }
    var buttonWindow: NSWindow? { item.button?.window }
}
