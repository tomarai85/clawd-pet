import Foundation

/// What a diagnostic line records about the pet beside the reconcile: the active quiet reasons, whether v1's controller thinks Aqua runs and
/// whether a window is on screen.
public struct AquaPetSnapshot {
    public var quiet: String
    public var controllerAqua: Bool
    public var window: Bool
    public init(quiet: String, controllerAqua: Bool, window: Bool) { self.quiet = quiet; self.controllerAqua = controllerAqua; self.window = window }
}

/// Follows Aqua's main process (amendment D-1 to D-4). Its liveness comes from the kernel; every trigger only asks `reconcile`, and no
/// trigger sets state by itself. Everything runs on the main queue.
public final class AquaFollower {
    public enum Trigger: String {
        case startup, exit, launch, terminate, kvo, bootstrap, shutdown, logfile, wake, unlock, retry, unwatched
    }

    private let table: AquaProcessTable
    private let registry: AquaExitRegistry
    /// Whether the pet already agrees with `notRunning` (the scheduler's reason and v1's controller both).
    private let agrees: (Bool) -> Bool
    private let apply: (Bool) -> Void
    private let log: (String) -> Void
    private let diag: AquaDiag?
    private let snapshot: () -> AquaPetSnapshot
    /// Arms (true) or drops (false) the scheduler's `aquaRetry` deadline; the follower owns no timer.
    private let setRetry: (Bool) -> Void

    /// The generation whose exit registration completed and whose verification passed (D-2): only this one is tracked.
    public private(set) var tracked: AquaGeneration?
    /// A live, verified Aqua whose registration failed twice: Clawd shows, and the retry deadline looks at it again every second.
    public private(set) var unwatched: AquaGeneration?
    private var trackedNumber = 0
    private var generations = 0
    private var exited = Set<AquaGeneration>()
    /// The pid whose exit registration is held, if any.
    private var watched: Int32?
    /// Reconciles run so far (a stale exit callback adds none).
    public private(set) var reconcileCount = 0
    public var exitedCount: Int { exited.count }

    public init(table: AquaProcessTable, registry: AquaExitRegistry, agrees: @escaping (Bool) -> Bool, apply: @escaping (Bool) -> Void,
                log: @escaping (String) -> Void, diag: AquaDiag?, snapshot: @escaping () -> AquaPetSnapshot, setRetry: @escaping (Bool) -> Void) {
        self.table = table; self.registry = registry; self.agrees = agrees; self.apply = apply
        self.log = log; self.diag = diag; self.snapshot = snapshot; self.setRetry = setRetry
        registry.onExit = { [weak self] pid in self?.exitDelivered(pid: pid) }
    }

    public var isRunning: Bool { tracked != nil || unwatched != nil }

    private enum Registration { case watched, gone, unwatched(Int32) }

    /// One registration attempt (D-2): a refusal other than ESRCH closes and recreates the kqueue once and tries again at once.
    private func register(_ pid: Int32) -> Registration {
        var watch = registry.watch(pid: pid)
        if case .failed = watch { registry.recreate(); watch = registry.watch(pid: pid) }
        switch watch {
        case .registered: return .watched
        case .gone: return .gone
        case .failed(let code): return .unwatched(code)
        }
    }

    /// The verification after a registration: the same process (start time), not a zombie, and for a newly found generation the Aqua identity.
    private func verified(_ generation: AquaGeneration, identity: Bool) -> Bool {
        guard let facts = table.facts(of: generation.pid), facts.start == generation.start, !facts.zombie else { return false }
        return !identity || table.isAqua(pid: generation.pid)
    }

    /// The one reconcile (D-1). `source` is the diagnostic text for the trigger's own details.
    public func reconcile(_ trigger: Trigger, source: String = "-") {
        reconcileCount += 1
        var changed = false
        var scanFailed = false
        var newlyUnwatched: (pid: Int32, code: Int32)?

        // 1. Keep the tracked generation while it is live; no path is read for it. An unwatched one is verified again and registered again.
        if let current = tracked ?? unwatched {
            if verified(current, identity: false) {
                if tracked == nil {
                    switch register(current.pid) {
                    case .watched:
                        if verified(current, identity: false) { tracked = current; unwatched = nil; watched = current.pid }
                        else { registry.unwatch(pid: current.pid); exited.insert(current); unwatched = nil }
                    case .gone: exited.insert(current); unwatched = nil
                    case .unwatched: break
                    }
                }
            } else {
                exited.insert(current); dropTracked()
            }
        }
        // 2. Otherwise look for a live Aqua process in the kernel, newest first, at most three passes.
        if tracked == nil, unwatched == nil {
            for _ in 0..<3 {
                guard let candidates = table.scan() else { scanFailed = true; break }
                let usable = candidates.filter { !$0.zombie && !exited.contains($0.generation) }
                guard let best = usable.max(by: { $0.generation.start < $1.generation.start }) else { break }
                let generation = best.generation
                let registration = register(generation.pid)
                if case .gone = registration { exited.insert(generation); continue }
                if verified(generation, identity: true) {
                    generations += 1; trackedNumber = generations
                    switch registration {
                    case .watched: tracked = generation; watched = generation.pid
                    case .unwatched(let code): unwatched = generation; newlyUnwatched = (generation.pid, code)
                    case .gone: break
                    }
                    break
                }
                if case .watched = registration { registry.unwatch(pid: generation.pid) }
                exited.insert(generation)
            }
        }
        // 3. Aqua runs when a generation is tracked or alive and unwatched. A kernel that could not be read finds none: Clawd stays hidden
        // and the next trigger (the diagnostics say scan=failed) corrects it.
        let notRunning = !isRunning
        if !agrees(notRunning) {
            apply(notRunning); changed = true
            log("AQUA reconcile trigger=\(trigger.rawValue) live=\(liveText) running=\(!notRunning)")
        }
        record(trigger: trigger.rawValue, source: source, changed: changed, extra: scanFailed ? " scan=failed" : "")
        if let newlyUnwatched {
            log("AQUA unwatched pid=\(newlyUnwatched.pid) errno=\(newlyUnwatched.code)")
            record(trigger: Trigger.unwatched.rawValue, source: "pid=\(newlyUnwatched.pid) errno=\(newlyUnwatched.code)", changed: false, extra: "")
        }
        // The retry deadline lives exactly while an Aqua generation is unwatched.
        setRetry(unwatched != nil)
    }

    /// The exit source's callback (D-2): only the tracked generation's pid reconciles, and only when the registration that fired is the
    /// tracked generation's own: a one-shot event has released its registration, so a registration still held for the pid means the event
    /// is an older generation's of the same pid.
    public func exitDelivered(pid: Int32) {
        guard let current = tracked, current.pid == pid, !registry.holds(pid: pid) else {
            log("AQUA exit stale pid=\(pid)")
            record(trigger: Trigger.exit.rawValue, source: "pid=\(pid) gen=0 stale=yes", changed: false, extra: "")
            return
        }
        exited.insert(current); dropTracked()
        log("AQUA exit pid=\(pid) gen=\(trackedNumber)")
        reconcile(.exit, source: "pid=\(pid) gen=\(trackedNumber) stale=no")
    }

    private func dropTracked() {
        if let pid = watched { registry.unwatch(pid: pid) }
        watched = nil; tracked = nil; unwatched = nil
    }

    private var liveText: String { (tracked ?? unwatched).map { "\($0.pid):\($0.start)" } ?? "none" }

    private func record(trigger: String, source: String, changed: Bool, extra: String) {
        guard let diag, diag.isOpen else { return }
        let state = snapshot()
        diag.append("trigger=\(trigger) src=\(source) live=\(liveText) exited=\(exited.count) quiet=\(AquaDiag.field(state.quiet)) " +
                   "controller_aqua=\(state.controllerAqua ? "yes" : "no") window=\(state.window ? "presented" : "none") " +
                   "changed=\(changed ? "yes" : "no")\(extra)", repeatable: trigger == Trigger.kvo.rawValue && !changed,
                   kvo: trigger == Trigger.kvo.rawValue)
    }

    /// The start-up line: which observers are installed (D-5).
    public func recordObservers(logWatch: Bool) {
        diag?.append("observers workspace=installed kvo=installed logwatch=\(logWatch ? "armed" : "none") kqueue=\(registry.available ? "ok" : "failed")")
    }
}
