import Foundation

/// A one-shot timer that reports its firing through `onFire`: what `AgentRuntime` owns (a `DispatchPetTimer` in production, a fake on a
/// virtual clock in a test).
public protocol PetFiringTimer: PetTimerScheduler {
    var onFire: (() -> Void)? { get set }
}

/// The single wake-up the agent may own: one-shot, replaced on every refresh, absent when nothing is due.
public final class DispatchPetTimer: PetFiringTimer {
    public var onFire: (() -> Void)?
    private var timer: DispatchSourceTimer?
    public init() {}
    public func arm(after delay: TimeInterval, leeway: TimeInterval) {
        cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + delay, leeway: .nanoseconds(Int(leeway * 1_000_000_000)))
        source.setEventHandler { [weak self] in self?.onFire?() }
        timer = source; source.resume()
    }
    public func cancel() { timer?.cancel(); timer = nil }
}
