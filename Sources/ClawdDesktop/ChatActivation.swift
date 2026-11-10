import AppKit
import ClawdCore

/// An application as the hand-back names it: its pid and launch date (a pid reused by another application has another launch date).
public struct ChatAppRef: Equatable {
    public var pid: Int32
    public var launchDate: Date?
    /// The application's bundle identifier, when the system gave one (or `ChatProcessOwner` found one from the executable's path): the
    /// outside-click rule exempts the screenshot UI, input methods and dictation by it.
    public var bundleID: String?
    /// The executable's file name, when no bundle was found: only for the `by=` field of the close line.
    public var executableName: String?
    public init(pid: Int32, launchDate: Date? = nil, bundleID: String? = nil, executableName: String? = nil) {
        self.pid = pid; self.launchDate = launchDate; self.bundleID = bundleID; self.executableName = executableName
    }
    /// What the close line says closed the panel: the bundle identifier, else `exe:<file name>`, else `unknown`. Never a path.
    public var label: String { bundleID ?? executableName.map { "exe:" + $0 } ?? "unknown" }
}

/// Who owns a process, for the outside-click rule. `NSRunningApplication` knows applications; it can answer nil for the `.appex` and `.xpc`
/// processes that own an input method's candidate window or the caret-side input UI, so the owner is also read from the executable's path
/// (`proc_pidpath`): the innermost `.app`, `.appex` or `.xpc` around it, and that bundle's identifier.
public enum ChatProcessOwner {
    /// The innermost bundle directory (`.app`, `.appex` or `.xpc`) that contains the executable at `path`; nil when there is none.
    public static func enclosingBundle(ofExecutable path: String) -> URL? {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard let index = parts.lastIndex(where: { ["app", "appex", "xpc"].contains(($0 as NSString).pathExtension) }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[0...index])))
    }

    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The bundle identifier of the process: from the running application when it is one, else from its executable's enclosing bundle.
    public static func bundleID(pid: Int32, running: NSRunningApplication? = nil) -> String? {
        if let id = (running ?? NSRunningApplication(processIdentifier: pid))?.bundleIdentifier { return id }
        guard let path = executablePath(pid: pid) else { return nil }
        return bundleID(ofExecutable: path)
    }

    /// The identifier of the innermost bundle around the executable at `path`.
    public static func bundleID(ofExecutable path: String) -> String? {
        guard let url = enclosingBundle(ofExecutable: path) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    /// The text a close line carries for the process: its bundle identifier, else `exe:<file name>`. A bundle identifier or a file name is neither
    /// chat text nor a folder path; anything outside `[A-Za-z0-9._:-]` becomes `_`, and the length is capped.
    public static func label(pid: Int32, running: NSRunningApplication? = nil) -> String? {
        let raw: String
        if let id = bundleID(pid: pid, running: running) {
            raw = id
        } else if let path = executablePath(pid: pid) {
            raw = "exe:" + (path as NSString).lastPathComponent
        } else {
            return nil
        }
        return sanitized(raw)
    }

    public static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(80).map {
            ($0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0))) ? $0 : "_"
        }))
    }

    public static func appRef(_ app: NSRunningApplication) -> ChatAppRef {
        let id = bundleID(pid: app.processIdentifier, running: app)
        let name = id == nil ? executablePath(pid: app.processIdentifier).map { ($0 as NSString).lastPathComponent } : nil
        return ChatAppRef(pid: app.processIdentifier, launchDate: app.launchDate, bundleID: id, executableName: name)
    }
}

/// A mouse-down another application received, as the global monitor reports it: its own time stamp (the clock of `NSEvent.timestamp`) and where it fell.
public struct ChatOutsidePress: Equatable {
    public var time: TimeInterval
    public var location: CGPoint
    public var button: ChatPressButton
    /// The pid of the topmost other-application window at the point (nil: none found). The press's owner is a process, not a label.
    public var ownerPid: Int32?
    public init(time: TimeInterval, location: CGPoint = .zero, button: ChatPressButton = .left, ownerPid: Int32? = nil) {
        self.time = time; self.location = location; self.button = button; self.ownerPid = ownerPid
    }
}

/// The three mouse buttons an outside press can come from. `bit` is the button's bit in `NSEvent.pressedMouseButtons`.
public enum ChatPressButton: String, Equatable {
    case left, right, other
    public var bit: Int { switch self { case .left: return 1; case .right: return 2; case .other: return 4 } }
    public init?(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: self = .left
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp: self = .right
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp: self = .other
        default: return nil
        }
    }
    /// The lowest button of a `pressedMouseButtons` mask (nil: none is down).
    public init?(lowestIn mask: Int) {
        guard let first = [ChatPressButton.left, .right, .other].first(where: { mask & $0.bit != 0 }) else { return nil }
        self = first
    }
}

/// What a global monitor reports about a press that is going on: a dragged or an up event of one button, with its place.
public struct ChatPressFollowUp: Equatable {
    public enum Kind: Equatable { case dragged, up }
    public var kind: Kind
    public var button: ChatPressButton
    public var location: CGPoint
    public init(kind: Kind, button: ChatPressButton, location: CGPoint) { self.kind = kind; self.button = button; self.location = location }
}

/// What the drag probe's monitor reports during the 30 s after a click-close: a left-button drag event or the button's release, with the event's
/// own time stamp (the clock of `NSEvent.timestamp`).
public struct ChatDragProbeEvent: Equatable {
    public enum Kind: Equatable { case dragged, up }
    public var kind: Kind
    public var time: TimeInterval
    public init(kind: Kind, time: TimeInterval) { self.kind = kind; self.time = time }
}

/// The drag pasteboard as the probe reads it: how many times it changed and whether it holds file URLs. Never its contents.
public struct ChatDragPasteboardState: Equatable {
    public var changeCount: Int
    public var hasFileURLs: Bool
    public init(changeCount: Int, hasFileURLs: Bool) { self.changeCount = changeCount; self.hasFileURLs = hasFileURLs }
}

/// The timestamps of the mouse-downs Clawd's own windows received (the pet, the menu and the chat panel), on the clock of `NSEvent.timestamp`.
/// The chat's activation token compares them with the session's latest mouse-down to tell a press elsewhere from a press on Clawd.
public final class WindowPressLog {
    public private(set) var latest: TimeInterval?
    public init() {}
    public func record(_ time: TimeInterval) { latest = max(latest ?? time, time) }
}

/// A timer source that never fires: the default of the chat's deadline timers, so a test that supplies none arms nothing real.
public final class InertChatTimers: ChatTimers {
    private struct Handle: ChatTimerHandle { func cancel() {} }
    public init() {}
    public func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) -> ChatTimerHandle { Handle() }
}

/// What the open chat asks of the system about focus (spec Sprint 3e). Every default does nothing; the real values exist only in
/// `RuntimeEnvironment.production`, which no test may name, so a test never activates, hands back to or deactivates a real application.
public struct ChatFocusSeams {
    /// The frontmost application now (nil: unreadable, or Clawd itself).
    public var frontmost: () -> ChatAppRef? = { nil }
    /// Asks the system to activate Clawd (once per opening).
    public var requestActivation: () -> Void = {}
    /// Asks the system to deactivate Clawd.
    public var requestDeactivation: () -> Void = {}
    /// Activates the recorded application; false when it is gone or refuses.
    public var handBack: (ChatAppRef) -> Bool = { _ in false }
    /// Activates Finder, the last step before a hand-back is reported failed.
    public var handBackToFinder: () -> Bool = { false }
    /// Whether Clawd is the active application now.
    public var isActive: () -> Bool = { false }
    /// Seconds since the session's latest mouse-down of any button (nil: unreadable).
    public var sessionPressAge: () -> TimeInterval? = { nil }
    /// Installs the observer of other applications' activations while the panel is open; the handler runs on the main queue.
    public var observeActivations: (@escaping (ChatAppRef) -> Void) -> ChatTimerHandle? = { _ in nil }
    /// Installs the monitor of mouse-downs that other applications receive, only while the panel is open; the handler runs on the main queue.
    public var observeOutsidePresses: (@escaping (ChatOutsidePress) -> Void) -> ChatTimerHandle? = { _ in nil }
    /// Installs the monitor of the dragged and up events of all three buttons. The controller installs it only while an outside press is pending
    /// and removes it with the decision; the handler runs on the main queue.
    public var observePressFollowUps: (@escaping (ChatPressFollowUp) -> Void) -> ChatTimerHandle? = { _ in nil }
    /// Installs the drag probe: the global left-mouse dragged and up monitor, only for the 30 s after a click-close (P12); the handler runs on the main queue.
    public var observeDragProbe: (@escaping (ChatDragProbeEvent) -> Void) -> ChatTimerHandle? = { _ in nil }
    /// The drag pasteboard's change count and whether it holds file URLs (never the contents, so no paste prompt can come of it).
    public var dragPasteboard: () -> ChatDragPasteboardState = { ChatDragPasteboardState(changeCount: 0, hasFileURLs: false) }
    /// The mouse buttons down now, as `NSEvent.pressedMouseButtons` (bit 0 left, 1 right, 2 other).
    public var pressedButtons: () -> Int = { 0 }
    /// The pointer's place now (`NSEvent.mouseLocation`).
    public var pointerLocation: () -> CGPoint = { .zero }
    /// The pid of the topmost window of another application at a screen point (nil: none found).
    public var surfaceOwnerPidAt: (CGPoint) -> Int32? = { _ in nil }
    /// Who owns the topmost window of another application at a screen point (its bundle identifier, else `exe:<name>`; nil: none found). The
    /// controller exempts the screenshot UI, an input method's candidate window and the dictation overlay by it, and logs it when the press closes.
    public var surfaceOwnerAt: (CGPoint) -> String? = { _ in nil }
    /// Who owns the frontmost application now (the same label; nil: unreadable, or Clawd itself).
    public var frontmostLabel: () -> String? = { nil }
    /// The system's double-click interval (`NSEvent.doubleClickInterval`), which bounds the click series that opened the chat.
    public var doubleClickInterval: () -> TimeInterval = { 0.5 }
    /// Whether the latest press of the session went to one of Clawd's own windows: a mouse-down still queued for them. The open's activation token treats such a press as the open's own click series, never as a press elsewhere.
    public var latestPressWentToClawd: () -> Bool = { true }
    /// The window of the mouse-down (any button) still queued for one of Clawd's windows (nil: none, or the queue cannot be read). Settings'
    /// own late-click path: AppKit may handle the activation before the press is the event in hand. Peeking leaves the queue as it is.
    public var queuedPressWindow: () -> NSWindow? = { nil }
    /// Runs a block on the next main-queue turn.
    public var nextTurn: (@escaping () -> Void) -> Void = { _ in }
    /// The activation policy as the `SETTINGS open` line names it ("accessory" in the pet).
    public var activationPolicy: () -> String = { "unknown" }
    /// Whether any window of Clawd is key now.
    public var clawdWindowIsKey: () -> Bool = { false }
    /// The one-shot deadlines of the activation token and of the hand-back steps.
    public var deadlines: ChatTimers = InertChatTimers()
    public init() {}
}

/// The only file of Sources that calls `activate(`: the real values of `ChatFocusSeams`.
extension ChatFocusSeams {
    public static func production() -> ChatFocusSeams {
        var seams = ChatFocusSeams()
        seams.frontmost = {
            guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
            return ChatProcessOwner.appRef(app)
        }
        seams.requestActivation = {
            if #available(macOS 14.0, *) { NSApplication.shared.activate() } else { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        seams.requestDeactivation = { NSApplication.shared.deactivate() }
        seams.handBack = { ref in
            guard let app = NSRunningApplication(processIdentifier: ref.pid), !app.isTerminated else { return false }
            if let launched = ref.launchDate, app.launchDate != launched { return false }
            return Self.bringForward(app)
        }
        seams.handBackToFinder = {
            guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return false }
            return Self.bringForward(finder)
        }
        seams.isActive = { NSApplication.shared.isActive }
        seams.sessionPressAge = {
            let ages = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].map {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
            }
            return ages.filter { $0 >= 0 }.min()
        }
        seams.observeActivations = { handler in
            let token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                handler(ChatProcessOwner.appRef(app))
            }
            return ObserverHandle(token)
        }
        seams.observeOutsidePresses = { handler in
            // Other applications' presses only: a press in one of Clawd's own windows never reaches a global monitor.
            let monitor = GlobalMousePressSource.install { time, location, button in
                handler(ChatOutsidePress(time: time, location: location, button: button, ownerPid: Self.topWindowOwnerPid(at: location)))
            }
            return monitor.map { MonitorHandle($0) }
        }
        seams.observePressFollowUps = { handler in GlobalMousePressSource.installFollowUps(handler).map { MonitorHandle($0) } }
        seams.observeDragProbe = { handler in GlobalMousePressSource.installDragProbe(handler).map { MonitorHandle($0) } }
        seams.dragPasteboard = {
            let board = NSPasteboard(name: .drag)
            return ChatDragPasteboardState(changeCount: board.changeCount, hasFileURLs: board.types?.contains(.fileURL) ?? false)
        }
        seams.pressedButtons = { Int(NSEvent.pressedMouseButtons) }
        seams.pointerLocation = { NSEvent.mouseLocation }
        seams.surfaceOwnerPidAt = { point in Self.topWindowOwnerPid(at: point) }
        seams.surfaceOwnerAt = { point in Self.topWindowOwner(at: point) }
        seams.frontmostLabel = {
            guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
            return ChatProcessOwner.label(pid: app.processIdentifier, running: app)
        }
        seams.doubleClickInterval = { NSEvent.doubleClickInterval }
        seams.latestPressWentToClawd = { Self.pressWentToClawd() }
        seams.queuedPressWindow = { Self.queuedPress()?.window }
        seams.nextTurn = { block in DispatchQueue.main.async(execute: block) }
        seams.activationPolicy = {
            switch NSApplication.shared.activationPolicy() {
            case .accessory: return "accessory"
            case .regular: return "regular"
            case .prohibited: return "prohibited"
            @unknown default: return "unknown"
            }
        }
        seams.clawdWindowIsKey = { NSApplication.shared.keyWindow != nil }
        seams.deadlines = DispatchChatTimers()
        return seams
    }

    private struct ObserverHandle: ChatTimerHandle {
        let token: NSObjectProtocol
        init(_ token: NSObjectProtocol) { self.token = token }
        func cancel() { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    private struct MonitorHandle: ChatTimerHandle {
        let monitor: Any
        init(_ monitor: Any) { self.monitor = monitor }
        func cancel() { NSEvent.removeMonitor(monitor) }
    }

    /// The owner of the topmost on-screen window of another application at `point` (AppKit screen coordinates), asked once per outside press.
    /// Clawd's own windows are skipped (the stage panel ignores the mouse, so a press under it belongs to what is below), as are fully
    /// transparent ones.
    private static func topWindowOwner(at point: CGPoint) -> String? {
        topWindowPid(at: point).flatMap { ChatProcessOwner.label(pid: $0) }
    }

    private static func topWindowOwnerPid(at point: CGPoint) -> Int32? { topWindowPid(at: point) }

    private static func topWindowPid(at point: CGPoint) -> Int32? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let spot = CGPoint(x: point.x, y: primaryHeight - point.y)
        let own = ProcessInfo.processInfo.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary), bounds.contains(spot),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = window[kCGWindowOwnerPID as String] as? Int32, pid != own else { continue }
            return pid
        }
        return nil
    }

    /// Whether the session's latest press went to Clawd: a mouse-down that Clawd's windows still have queued. Peeking leaves the queue as it is.
    private static func pressWentToClawd() -> Bool { queuedPress()?.window != nil }

    private static func queuedPress() -> NSEvent? {
        NSApp.nextEvent(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], until: .distantPast, inMode: .default, dequeue: false)
    }

    /// Brings another application forward: from macOS 14 on, Clawd first yields its activation to it (cooperative activation).
    private static func bringForward(_ app: NSRunningApplication) -> Bool {
        if #available(macOS 14.0, *) {
            NSApplication.shared.yieldActivation(to: app)
            return app.activate(from: NSRunningApplication.current, options: [])
        }
        return app.activate(options: [])
    }
}
