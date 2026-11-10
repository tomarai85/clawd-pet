import AppKit
import ClawdCore

public enum BootStep: String, Equatable {
    case observersRegistered, accessoryPolicySet, finishedLaunching, panelCreated, running
}

/// The agent's start-up steps. The order is fixed by `AgentBoot.start`; a host only supplies the effects.
public protocol BootHost: AnyObject {
    func registerFocusObservers() throws
    func setAccessoryPolicy()
    func finishLaunching()
    func createPanelAndRuntime() throws
    func run()
}

public enum AgentBoot {
    /// Focus observers come first (before NSApplication exists), then policy, then finishLaunching, and only then the panel.
    @discardableResult public static func start(host: BootHost) throws -> [BootStep] {
        var steps: [BootStep] = []
        try host.registerFocusObservers(); steps.append(.observersRegistered)
        host.setAccessoryPolicy(); steps.append(.accessoryPolicySet)
        host.finishLaunching(); steps.append(.finishedLaunching)
        try host.createPanelAndRuntime(); steps.append(.panelCreated)
        steps.append(.running)
        host.run()
        return steps
    }
}

/// Production host. `run()` blocks inside the AppKit run loop.
public final class AppKitBootHost: BootHost {
    private let store: OwnState
    private let root: URL
    private let settingsRequest: SettingsRequestVerdict
    private var monitor: FocusMonitor?
    private var runtime: AgentRuntime?
    public init(root: URL, store: OwnState, settingsRequest: SettingsRequestVerdict = .none) {
        self.root = root; self.store = store; self.settingsRequest = settingsRequest
    }
    public func registerFocusObservers() throws { monitor = FocusMonitor(store: store); monitor?.recordBoot() }
    public func setAccessoryPolicy() { NSApplication.shared.setActivationPolicy(.accessory) }
    public func finishLaunching() {
        monitor?.onViolation = { NSApplication.shared.deactivate() }
        NSApplication.shared.finishLaunching()
    }
    public func createPanelAndRuntime() throws {
        guard let monitor else { throw FileFailure.unsafePath }
        // control.json is read by the SettingsWatcher the runtime builds; this value only stands for a missing file.
        runtime = try AgentRuntime(store: store, monitor: monitor, art: root.appendingPathComponent("art"), control: AgentControl(),
                                 environment: .production, settingsRequest: settingsRequest)
        // A SIGTERM (launchd's, at `clawd-pet update`) while a chat child lives stops that child and its processes before the agent dies; with
        // no chat child the handler lets the signal take its default at once.
        ChatQuit.install { [weak runtime] in runtime?.shutdownChat() }
    }
    public func run() { withExtendedLifetime((runtime, monitor)) { NSApplication.shared.run() } }
}
