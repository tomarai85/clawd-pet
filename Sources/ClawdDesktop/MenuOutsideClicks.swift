import AppKit

/// Where "a click outside the menu" comes from (spec 5.2). Only mouse-downs, only clicks posted to OTHER applications: the system hands
/// a global monitor a copy and the click still reaches the app behind. A click on one of our own windows (Clawd, the menu) is never
/// delivered here, so the menu's own items and Clawd's body are not "outside".
public protocol MenuOutsideClickSource: AnyObject {
    /// Starts listening; `handler` gets the event's own timestamp for every mouse-down. The token goes back to `remove`; nil: nothing is
    /// listening (the system gave no monitor).
    func install(_ handler: @escaping (TimeInterval) -> Void) -> AnyObject?
    func remove(_ token: AnyObject)
}

/// The listen-only global monitor. It needs no permission and shows no prompt for mouse events. It exists only between a menu's opening
/// and its close (the controller installs one per opening and removes it on every close path).
public final class GlobalMouseDownSource: MenuOutsideClickSource {
    public init() {}
    public func install(_ handler: @escaping (TimeInterval) -> Void) -> AnyObject? {
        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { handler($0.timestamp) }) else { return nil }
        return monitor as AnyObject
    }
    public func remove(_ token: AnyObject) { NSEvent.removeMonitor(token) }
}

/// The same monitor for the chat panel's outside-press rule: one source file holds the app's global mouse-down monitor. The handler gets the
/// press's own time stamp and place (a global event has no window: its `locationInWindow` is in screen coordinates).
public enum GlobalMousePressSource {
    public static func install(_ handler: @escaping (_ time: TimeInterval, _ location: CGPoint, _ button: ChatPressButton) -> Void) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { event in
            guard let button = ChatPressButton(event.type) else { return }
            handler(event.timestamp, event.locationInWindow, button)
        })
    }

    /// The follow-up monitor of a pending outside press: the dragged and up events of all three buttons. It exists only between a down and the
    /// decision that down gets (the controller installs it with the pending press and removes it with it).
    public static func installFollowUps(_ handler: @escaping (ChatPressFollowUp) -> Void) -> Any? {
        let types: NSEvent.EventTypeMask = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp]
        return NSEvent.addGlobalMonitorForEvents(matching: types, handler: { event in
            guard let button = ChatPressButton(event.type) else { return }
            let up = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type)
            handler(ChatPressFollowUp(kind: up ? .up : .dragged, button: button, location: event.locationInWindow))
        })
    }

    /// The drag probe (P12): the left button's dragged and up events, installed only for the 30 s after a click-close and removed by the first
    /// open, an exam, `chat` off, hiding or that deadline.
    public static func installDragProbe(_ handler: @escaping (ChatDragProbeEvent) -> Void) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp], handler: { event in
            handler(ChatDragProbeEvent(kind: event.type == .leftMouseUp ? .up : .dragged, time: event.timestamp))
        })
    }
}
