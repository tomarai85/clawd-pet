import AppKit
import ClawdCore

public enum PanelContract {
    public static let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    public static let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    /// The level of every window of the pet (body, stage, open menu), wherever he stands: one above the Dock's own window. At `.floating`
    /// he shared his level with other apps' floating windows (an Orca session pane, Aqua Voice), and among windows of one level the one
    /// raised last covers the rest, so they went over him (Tom, 2026-11-09). Above this level stay the menu bar, status items, pop-up
    /// menus and the screen saver.
    public static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
}

/// A window of the pet. Every one keeps v1's focus guarantees (non-activating, never key or main, `.accessory` app) and takes mouse
/// events: it exists only where a click is taken (Clawd's body and costume, the open menu). The window that carries the rest of the
/// picture is a `StagePanel`.
public class PetPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
    /// The mouse-downs of Clawd's windows (Sprint 3e item 2): the runtime hands every window the same log.
    public var presses: WindowPressLog?
    public override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: presses?.record(event.timestamp)
        default: break
        }
        super.sendEvent(event)
    }
    public init(overFullScreen: Bool) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 48, height: 44), styleMask: PanelContract.style, backing: .buffered, defer: true)
        becomesKeyOnlyIfNeeded = true; hidesOnDeactivate = false
        isFloatingPanel = true; level = PanelContract.level
        collectionBehavior = PanelContract.behavior
        if overFullScreen { collectionBehavior.insert(.fullScreenAuxiliary) }
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        animationBehavior = .none; isExcludedFromWindowsMenu = true; isReleasedWhenClosed = false
    }
}

/// The window that carries everything that does not take clicks: props, effects, the bubble and the transparent stage. It ignores
/// mouse events for its whole life and nothing can change that: a click on it cannot be taken, so it goes to the app behind, with no
/// moment in which the flag could be wrong (spec 4.4).
public final class StagePanel: PetPanel {
    public override var ignoresMouseEvents: Bool {
        get { true }
        set { /* locked: this window never takes a mouse event */ }
    }
    /// What the window server was told: the flag of the underlying window, which no caller can change (the audit reads it).
    public var windowServerIgnoresMouseEvents: Bool { super.ignoresMouseEvents }
    public override init(overFullScreen: Bool) {
        super.init(overFullScreen: overFullScreen)
        super.ignoresMouseEvents = true
    }
}

/// Static check of everything that keeps a panel from taking focus. An empty result means the contract holds.
public enum FocusAudit {
    public static func violations(of panel: NSPanel, overFullScreenAllowed: Bool = false) -> [String] {
        var found: [String] = []
        if !panel.styleMask.contains(.nonactivatingPanel) { found.append("styleMask lacks nonactivatingPanel") }
        if !panel.styleMask.contains(.borderless) { found.append("styleMask lacks borderless") }
        if panel.canBecomeKey { found.append("canBecomeKey is true") }
        if panel.canBecomeMain { found.append("canBecomeMain is true") }
        if panel.hidesOnDeactivate { found.append("hidesOnDeactivate is true") }
        if !panel.becomesKeyOnlyIfNeeded { found.append("becomesKeyOnlyIfNeeded is false") }
        if !panel.isFloatingPanel { found.append("isFloatingPanel is false") }
        if panel.level != PanelContract.level { found.append("level is not the pet's (the Dock's plus one)") }
        for flag in [NSWindow.CollectionBehavior.canJoinAllSpaces, .stationary, .ignoresCycle]
        where !panel.collectionBehavior.contains(flag) { found.append("collectionBehavior lacks \(flag.rawValue)") }
        if !overFullScreenAllowed, panel.collectionBehavior.contains(.fullScreenAuxiliary) { found.append("fullScreenAuxiliary set") }
        if panel.isOpaque { found.append("isOpaque is true") }
        if panel.animationBehavior != .none { found.append("animationBehavior is not none") }
        return found
    }
}

public final class PetView: NSView {
    public var input: ((String, NSEvent) -> Void)?
    /// Every mouse or scroll event the view receives and does nothing with, with the reason. The live check needs these: a person
    /// clicking a transparent pixel, double-clicking or right-clicking is still a person at the pet.
    public var ignored: ((String, NSEvent, String) -> Void)?
    public var opaqueBody: ((CGPoint) -> Bool)?
    /// A click that is not the first of a series (clickCount 2 or more), on Clawd's body or costume.
    public var repeatedClick: ((NSEvent) -> Void)?
    /// A right-click or a control-click on Clawd's body or costume (the menu). True: it opened or closed the menu; false: it was refused
    /// (a higher state holds), and the view logs it as ignored. Without it a right-click is ignored as it was in v1.
    public var menuRequest: ((NSEvent, MenuOpenHow) -> Bool)?
    /// A file drag over Clawd's body (D3a). `dropRefusal` says why the chat could not take a drop now (nil: it could); `fileDragEntered` tells the
    /// controller a file drag came to a Clawd drop target (a pending outside press becomes a drag); `dropRefused` logs a refusal once per drag;
    /// `fileDrop` receives the paths, whether promises came too, and the event time of the drop.
    public var dropRefusal: (() -> String?)?
    public var fileDragEntered: (() -> Void)?
    public var dropRefused: ((String) -> Void)?
    public var fileDrop: (([String], Bool, TimeInterval) -> Void)?
    private var refusalLogged = false
    /// The refusal of the drag in progress (Q23): computed at the first event over an opaque pixel and reused until the drag ends or exits. The
    /// outer optional says whether it was computed.
    private var dragRefusal: String??
    /// What `prepareForDragOperation` computed for the drop, for `performDragOperation` to reuse.
    private var preparedRefusal: String??
    /// The drag-and-drop calls `dropRefusal` once for each drag, not once for each update (it checks the install and the exam browser).
    private func refusalForDrag() -> String? {
        if let cached = dragRefusal { return cached }
        let fresh = dropRefusal?()
        dragRefusal = .some(fresh)
        return fresh
    }
    private var trackingPress = false

    public override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(ChatDropContent.registeredTypes)
    }
    public required init?(coder: NSCoder) { fatalError("PetView is built in code") }

    /// The drop is taken over Clawd's opaque body or costume pixels only, by the hit mask the clicks use; over a transparent pixel of the window
    /// the answer is no operation, so the drag is Clawd's no more than a click there is. (Residual cost, named: AppKit cannot let a drag pass
    /// through a window to the one behind it, so a file drag over a transparent pixel inside Clawd's window shows the not-allowed cursor.)
    private func dragOperation(_ sender: NSDraggingInfo, entering: Bool) -> NSDragOperation {
        guard ChatDropContent.carriesFiles(sender.draggingPasteboard) else { return [] }
        guard opaqueBody?(convert(sender.draggingLocation, from: nil)) == true else { return [] }
        if entering { fileDragEntered?() }
        if let reason = refusalForDrag() {
            if !refusalLogged { refusalLogged = true; dropRefused?(reason) }
            return []
        }
        return .copy
    }
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        refusalLogged = false; dragRefusal = nil; preparedRefusal = nil
        return dragOperation(sender, entering: true)
    }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragOperation(sender, entering: false) }
    public override func draggingExited(_ sender: NSDraggingInfo?) { refusalLogged = false; dragRefusal = nil; preparedRefusal = nil }
    public override func draggingEnded(_ sender: NSDraggingInfo) { refusalLogged = false; dragRefusal = nil; preparedRefusal = nil }
    /// The drop computes the refusal once more, so a state change during the hover is honoured (Q23); `prepare` and `perform` share that one value.
    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let fresh = dropRefusal?()
        dragRefusal = .some(fresh); preparedRefusal = .some(fresh)
        let ours = ChatDropContent.carriesFiles(sender.draggingPasteboard) && opaqueBody?(convert(sender.draggingLocation, from: nil)) == true
        // A refusal that began during the hover is logged once, here, as the hover's own would have been.
        if ours, let fresh, !refusalLogged { refusalLogged = true; dropRefused?(fresh) }
        return ours && fresh == nil
    }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        refusalLogged = false
        let refusal: String? = (preparedRefusal ?? .some(dropRefusal?())) ?? nil
        dragRefusal = nil; preparedRefusal = nil
        let board = sender.draggingPasteboard
        guard ChatDropContent.carriesFiles(board), opaqueBody?(convert(sender.draggingLocation, from: nil)) == true, refusal == nil else { return false }
        // The drop's own event time; with no current event, the uptime (the double-click's `eventTime` is on the same clock).
        let time = NSApp?.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime
        fileDrop?(ChatDropContent.paths(board), ChatDropContent.carriesPromise(board), time)
        return true
    }
    public override var acceptsFirstResponder: Bool { false }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A control-click is a right-click: it opens the menu and never starts a press, a drag or a click.
        if event.modifierFlags.contains(.control) { menuClick(event, point, kind: "mouseDown", how: .control); return }
        // A second or third click is not the start of a press (it never drags), but it is a click (spec 6.4: three quick clicks make
        // Clawd dizzy): it goes to `repeatedClick`, never to `input`.
        guard event.clickCount == 1 else {
            if opaqueBody?(point) == true, let repeatedClick { repeatedClick(event) } else { ignored?("mouseDown", event, "clickcount") }
            return
        }
        guard opaqueBody?(point) == true else { ignored?("mouseDown", event, "transparent"); return }
        trackingPress = true; input?("mouseDown", event)
    }
    public override func mouseDragged(with event: NSEvent) {
        if trackingPress { input?("mouseDragged", event) } else { ignored?("mouseDragged", event, "untracked") }
    }
    public override func mouseUp(with event: NSEvent) {
        if trackingPress { input?("mouseUp", event) } else { ignored?("mouseUp", event, "untracked") }
        trackingPress = false
    }
    /// The press this view is following lost its window (hidden, a quiet condition): its drag and its button-up will never come, and a
    /// stray one that does come later must not be taken for the end of that press.
    public func cancelPress() { trackingPress = false }
    public override func rightMouseDown(with event: NSEvent) {
        menuClick(event, convert(event.locationInWindow, from: nil), kind: "rightMouseDown", how: .right)
    }
    /// A right-click or a control-click: on Clawd's body or costume pixels it asks for the menu; elsewhere, or when it is refused, it is a
    /// mouse event the view received and did nothing with, and says why.
    private func menuClick(_ event: NSEvent, _ point: CGPoint, kind: String, how: MenuOpenHow) {
        guard opaqueBody?(point) == true else { ignored?(kind, event, "transparent"); return }
        if menuRequest?(event, how) != true { ignored?(kind, event, menuRequest == nil ? "unused" : "busy") }
    }
    public override func otherMouseDown(with event: NSEvent) { ignored?("otherMouseDown", event, "unused") }
    public override func scrollWheel(with event: NSEvent) { ignored?("scrollWheel", event, "unused") }
}
