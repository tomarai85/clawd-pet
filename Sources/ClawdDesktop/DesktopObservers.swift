import AppKit
import ApplicationServices
import ClawdCore
import ClawdRendering

/// Seconds since the user's last keyboard or mouse input, from the window server's own idle counter. It needs no permission and
/// observes nothing about what was pressed. nil when the counter cannot be read (the scheduler then treats the user as just active).
public enum InputIdle {
    public static func seconds() -> TimeInterval? {
        guard let any = CGEventType(rawValue: ~0) else { return nil }
        let value = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        return value.isFinite && value >= 0 ? value : nil
    }
}

/// The macOS conditions under which nothing may move or render (spec 6.1) and Reduce Motion, turned into scheduler inputs. Every
/// observer is a notification or KVO; none polls. v1 observed system sleep and wake, Aqua start and quit and display changes; this adds
/// display sleep, screen lock and screen saver, a switched-away login session, Clawd's window leaving the active Space, and Reduce Motion.
public final class DesktopObservers {
    public static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    public static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")
    public static let screenSaverStarted = Notification.Name("com.apple.screensaver.didstart")
    public static let screenSaverStopped = Notification.Name("com.apple.screensaver.didstop")
    /// macOS posts this when the system appearance changes, Auto's switch at sunset included.
    public static let appearanceChanged = Notification.Name("AppleInterfaceThemeChangedNotification")

    private weak var sink: QuietSink?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private let panelOnActiveSpace: () -> Bool?
    private let appearance: () -> BubbleAppearance
    private var appearanceObservation: NSKeyValueObservation?
    /// Locked and screen saver are two sources of one reason.
    private var locked = false, saverRunning = false

    /// `workspace` and `distributed` are injectable so a test can post the notifications itself. `panelOnActiveSpace` answers nil while
    /// the window is not on screen (it then says nothing about the Space).
    public init(sink: QuietSink, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
                distributed: NotificationCenter = DistributedNotificationCenter.default(),
                panelOnActiveSpace: @escaping () -> Bool? = { nil },
                reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
                appearance: @escaping () -> BubbleAppearance = DesktopObservers.currentAppearance,
                observeAppearance: (@escaping () -> Void) -> NSKeyValueObservation = DesktopObservers.observeAppearance) {
        self.sink = sink; self.panelOnActiveSpace = panelOnActiveSpace; self.appearance = appearance
        func watch(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping () -> Void) {
            tokens.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() }))
        }
        watch(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.sink?.setQuiet(.displayAsleep, active: true) }
        watch(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.sink?.setQuiet(.displayAsleep, active: false) }
        watch(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.sink?.setQuiet(.sessionInactive, active: true) }
        watch(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.sink?.setQuiet(.sessionInactive, active: false) }
        watch(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in self?.spaceChanged() }
        watch(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in self?.sink?.setReduceMotion(reduceMotion()) }
        watch(distributed, Self.screenLocked) { [weak self] in self?.setLocked(true) }
        watch(distributed, Self.screenUnlocked) { [weak self] in self?.setLocked(false) }
        watch(distributed, Self.screenSaverStarted) { [weak self] in self?.setSaver(true) }
        watch(distributed, Self.screenSaverStopped) { [weak self] in self?.setSaver(false) }
        watch(distributed, Self.appearanceChanged) { [weak self] in self?.appearanceDidChange() }
        appearanceObservation = observeAppearance { [weak self] in self?.appearanceDidChange() }
        sink.setReduceMotion(reduceMotion())
        sink.setAppearance(appearance())
    }
    deinit { tokens.forEach { $0.0.removeObserver($0.1) } }

    /// KVO delivers the effective value change even when the distributed notification arrived too early or was absent.
    public static func observeAppearance(_ changed: @escaping () -> Void) -> NSKeyValueObservation {
        NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { _, _ in changed() }
    }

    /// Re-read on the main queue for both sources; a notification alone does not establish AppKit's update order.
    private func appearanceDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sink?.setAppearance(self.appearance())
        }
    }

    /// The app's effective appearance as it is now.
    public static func currentAppearance() -> BubbleAppearance {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    private func setLocked(_ value: Bool) { locked = value; publishLock() }
    private func setSaver(_ value: Bool) { saverRunning = value; publishLock() }
    private func publishLock() { sink?.setQuiet(.screenLocked, active: locked || saverRunning) }

    /// The Space changed. A window ordered out reports nothing about the Space, so the quiet reason is lifted first: the window is
    /// ordered in again and asked once; if it is not on the active Space (a full-screen app's Space) the reason is raised again.
    private func spaceChanged() {
        sink?.setQuiet(.notOnActiveSpace, active: false)
        DispatchQueue.main.async { [weak self] in
            guard let self, let onActive = self.panelOnActiveSpace(), !onActive else { return }
            self.sink?.setQuiet(.notOnActiveSpace, active: true)
        }
    }

    /// The state at start: the observers only report changes.
    public func publishInitialState(displayAsleep: Bool, locked lockedNow: Bool) {
        if displayAsleep { sink?.setQuiet(.displayAsleep, active: true) }
        if lockedNow { setLocked(true) }
    }

    /// Display asleep and screen locked as they are right now, from the window server (no permission, no private API).
    public static func currentDisplayAsleep() -> Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
    public static func currentScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
