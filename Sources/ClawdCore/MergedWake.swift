import Foundation

/// One real timer for every wake the agent wants: the controller's (blink, scene deadlines), the scheduler's (idle slot, walk legs,
/// look change, SLEEP read) and the renderer's (the next motion frame, spinner tick or fade step). Each source arms its own `Slot`
/// as if it were the only timer; the process owns at most one armed timer, set to the earliest slot.
///
/// `batch` groups several changes into one re-arm. A slot whose deadline has passed is cleared by `fired()` at the start of a tick,
/// so a source that does not re-arm cannot make the timer fire again at once.
public final class MergedWake {
    public final class Slot: PetTimerScheduler {
        fileprivate weak var owner: MergedWake?
        fileprivate var deadline: TimeInterval?
        fileprivate var leeway: TimeInterval = 0
        /// While it answers false the slot ignores `arm` (a quiet condition: nothing may run).
        public var allowed: () -> Bool = { true }
        fileprivate init(owner: MergedWake) { self.owner = owner }
        public func arm(after delay: TimeInterval, leeway: TimeInterval) {
            guard let owner else { return }
            deadline = allowed() ? owner.clock.now + max(0, delay) : nil
            self.leeway = leeway
            owner.slotChanged()
        }
        public func cancel() {
            deadline = nil
            owner?.slotChanged()
        }
        public var armedAt: TimeInterval? { deadline }
    }

    private let timer: PetTimerScheduler
    private let clock: PetClock
    private var slots: [Slot] = []
    private var depth = 0
    private var pending = false
    /// 1 while the real timer is armed, else 0. By construction never above 1; the measurement samples it.
    public private(set) var armedTimers = 0
    /// The most the process has ever owned at once.
    public private(set) var maxArmedTimers = 0
    /// Called whenever the armed count is set (the headless mode mirrors it into a counter file for the CPU measurement).
    public var onArmedChange: ((Int) -> Void)?

    public init(timer: PetTimerScheduler, clock: PetClock) {
        self.timer = timer; self.clock = clock
    }

    public func makeSlot() -> Slot {
        let slot = Slot(owner: self)
        slots.append(slot)
        return slot
    }

    /// Runs `body`, then re-arms the real timer once if any slot changed inside it. Nests.
    public func batch(_ body: () -> Void) {
        depth += 1
        body()
        depth -= 1
        if depth == 0, pending { pending = false; commit() }
    }

    /// The real timer fired: forget every deadline that has passed. The sources re-arm what they still want.
    public func fired() {
        let now = clock.now
        for slot in slots { if let d = slot.deadline, d <= now { slot.deadline = nil } }
    }

    /// Cancels the real timer and every slot (the host is going away).
    public func stop() {
        for slot in slots { slot.deadline = nil }
        timer.cancel()
        setArmed(0)
    }

    fileprivate func slotChanged() {
        if depth > 0 { pending = true } else { commit() }
    }

    /// The timer is armed at the earliest deadline d0 with leeway L = the smallest of (deadline + leeway - d0) over the armed slots, never
    /// below 0: firing at d0 + L makes no slot later than its own deadline plus its own leeway. A long leeway of the earliest slot (the
    /// idle blink's 1 s) therefore cannot hold back a frame slot that is due a few milliseconds later.
    private func commit() {
        var earliest: TimeInterval?
        for slot in slots { if let d = slot.deadline, earliest == nil || d < earliest! { earliest = d } }
        timer.cancel()
        guard let d0 = earliest else { setArmed(0); return }
        var allowance = Double.infinity
        for slot in slots { if let d = slot.deadline { allowance = min(allowance, slot.leeway + (d - d0)) } }
        timer.arm(after: max(0.001, d0 - clock.now), leeway: max(0, allowance))
        setArmed(1)
    }

    private func setArmed(_ count: Int) {
        guard count != armedTimers else { return }
        armedTimers = count
        maxArmedTimers = max(maxArmedTimers, count)
        onArmedChange?(count)
    }
}
