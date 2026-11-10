import Foundation
import ClawdCore

/// Applies what `SettingsWatcher` reads to a `StageRuntime` and tells the host. The desktop runtime and the headless settings mode
/// both use it, so a setting has one path from control.json to the scheduler.
public final class LiveSettings: SettingsApplySink {
    public private(set) var current: AppliedSettings
    private var alias: HelmetAlias
    /// The control the process started with: a restart-only key that differs from it is saved but not in effect.
    private let boot: AgentControl
    private unowned let runtime: StageRuntime
    /// Lines for agent.log.
    public var log: (String) -> Void = { _ in }
    /// Runs a closure on the next turn of the run loop (a test collects them instead).
    public var deferred: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    /// After the settings are in effect: the generation, the settings as read and the scheduler's effective settings.
    public var didApply: (Int, AppliedSettings, SchedulerSettings) -> Void = { _, _, _ in }
    /// The helmet-off one-shot was set or dropped by a settings change, before the generation is confirmed: the host writes it to
    /// state.json. (The change that ends it, a look change, is written together with the new look by the host's look persistence.)
    public var helmetOffPendingChanged: () -> Void = {}

    /// `helmetOffPending` is the one-shot as state.json held it at the start (see `HelmetAlias`).
    public init(runtime: StageRuntime, initial: AppliedSettings, helmetOffPending: Bool = false) {
        self.runtime = runtime; current = initial; boot = initial.control
        alias = HelmetAlias(helmet: initial.control.helmet, offPending: helmetOffPending)
    }

    public var effective: SchedulerSettings { current.effectiveScheduler(helmetOffPending: alias.offPending) }
    /// `helmet off` has been applied and Clawd still wears something else: the switch back to plain is owed.
    public var helmetOffPending: Bool { alias.offPending }

    public func apply(_ settings: AppliedSettings) {
        // The log says what status.json will say: a generation that carries a key only a restart applies is saved, not applied.
        let pending = settings.control.restartKeys(since: boot)
        log(pending.isEmpty ? "SETTINGS applied generation=\(settings.generation)"
                            : "SETTINGS saved generation=\(settings.generation) restart-pending keys=\(pending.joined(separator: ","))")
        let owed = alias.offPending
        alias.settingsChanged(helmet: settings.control.helmet, currentLook: runtime.scheduler.look)
        current = settings
        if alias.offPending != owed { helmetOffPendingChanged() }
        runtime.apply(settings: effective)
    }

    public func applied(generation: Int, settings: AppliedSettings) {
        didApply(generation, settings, effective)
    }

    /// Wire to `StageRuntime.onEvent`: a change to plain ends the helmet-off one-shot.
    public func schedulerEvent(_ event: SchedulerEvent) {
        guard case .lookChange(_, let to) = event, alias.lookChanged(to: to) else { return }
        // Not inside the scheduler's own call: drop the pin on the next turn of the run loop.
        deferred { [weak self] in
            guard let self else { return }
            self.runtime.apply(settings: self.effective)
        }
    }
}
