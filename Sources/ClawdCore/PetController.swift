import Foundation

/// One timer at most. `arm` replaces any pending wake; `cancel` leaves the process with no timer at all.
public protocol PetTimerScheduler: AnyObject {
    func arm(after delay: TimeInterval, leeway: TimeInterval)
    func cancel()
}

/// Source B: running state of ONE input device. CoreAudio supplies the real one; tests supply a fake.
public protocol ReleaseDeviceSource: AnyObject {
    var onChange: ((String?, Bool?) -> Void)? { get set }
    @discardableResult func start(uid: String?) -> Bool?
    func running() -> Bool?
    func stop()
}

/// Everything the renderer needs for one frame, independent of AppKit.
public struct PetViewState: Equatable {
    public var scene: Scene
    public var chipScene: Scene
    public var elapsed: TimeInterval
    public var duration: TimeInterval
    public var verbSeed: Int
    public var pastSeed: Int
    public var blink: Bool
    public var visible: Bool
}

/// Glue between events, the scene machine, release hints, blink and timers.
/// It owns no AppKit object, so the same code runs in the agent and in the virtual-clock tests.
public final class PetController {
    public static let blinkDuration: TimeInterval = 0.12
    public static let blinkRange: ClosedRange<Double> = 3...7
    public static let idleLeeway: TimeInterval = 1
    public static let animationLeeway: TimeInterval = 0.005

    public let clock: PetClock
    public let machine: SceneMachine
    public let parser = EventParser()
    public var device: ReleaseDeviceSource? {
        didSet { device?.onChange = { [weak self] uid, running in self?.deviceCallback(uid: uid, running: running) } }
    }
    /// Disabled by default: until a probe passes and `control.json` says so, the device is never touched.
    public var sourceBEnabled = false
    public var selectedUID: () -> String? = { nil }
    public var animationInterval: (PetViewState) -> TimeInterval? = { _ in nil }
    public var onRender: ((PetViewState) -> Void)?
    public var onAccepted: ((PetEvent) -> Void)?
    /// Every event a line parses to, before the machine hears it: whatever the machine does with it, Aqua's own lifecycle lines are seen.
    public var onParsed: ((PetEvent) -> Void)?
    public var randomUnit: () -> Double = { Double.random(in: 0..<1) }
    public var randomSeed: () -> Int = { Int.random(in: 0..<1_000_000) }
    public private(set) var aquaRunning = false
    public private(set) var systemAsleep = false
    public private(set) var timerIsArmed = false
    public private(set) var hints = ReleaseHintTracker()
    public var ownedTimers: Int { timerIsArmed ? 1 : 0 }
    public var visible: Bool { aquaRunning && !systemAsleep }

    private let scheduler: PetTimerScheduler
    private var nextBlink: TimeInterval = 0
    private var blinking = false
    private var blinkEnds: TimeInterval = 0
    private var previousScene: Scene = .sleep
    private var verbSeed = 0
    private var pastSeed = 0

    public init(clock: PetClock, scheduler: PetTimerScheduler) {
        self.clock = clock; self.scheduler = scheduler
        machine = SceneMachine(clock: clock)
        verbSeed = randomSeed(); pastSeed = randomSeed()
    }

    // MARK: inputs

    public func receive(line: String) {
        if let event = parser.parse(line) { onParsed?(event); receive(event: event) }
    }

    public func receive(event: PetEvent) {
        let prior = machine.lease
        guard machine.receive(event) else { return }
        onAccepted?(event)
        if let lease = machine.lease, lease != prior {
            verbSeed = randomSeed(); pastSeed = randomSeed()
            if sourceBEnabled, let device {
                let uid = selectedUID()
                hints.begin(uid: uid, running: device.start(uid: uid))
            }
        }
        if machine.lease == nil { device?.stop() }
        refresh()
    }

    /// A chat turn started (F4 C-1, C-7): new verb seeds, THINKING until it ends.
    public func chatTurnStarted() {
        verbSeed = randomSeed(); pastSeed = randomSeed()
        machine.chatTurnStarted()
        refresh()
    }

    /// The chat turn ended (F4 C-2 to C-4).
    public func chatTurnEnded(_ outcome: ChatTurnOutcome) {
        machine.chatTurnEnded(outcome)
        refresh()
    }

    public func deviceCallback(uid: String?, running: Bool?) {
        guard sourceBEnabled else { return }
        // Re-read the selected input only here, on a device callback; a changed input invalidates the hint.
        if selectedUID() != hints.selectedUID { hints.invalidate() }
        machine.deviceChanged(running: running == true)
        if hints.observe(uid: uid, running: running) { machine.releaseHint() }
        refresh()
    }

    public func setAquaRunning(_ running: Bool) {
        aquaRunning = running
        machine.reset(); device?.stop(); hints.invalidate()
        previousScene = .sleep          // forces a fresh blink schedule
        refresh()
    }
    public func systemWillSleep() { systemAsleep = true; device?.stop(); refresh() }
    public func systemDidWake() { systemAsleep = false; machine.reset(); previousScene = .sleep; refresh() }

    public func mouseDown() { machine.mouseDown(); refresh() }
    public func mouseDragged() { machine.mouseDragged(); refresh() }
    public func mouseUp() { machine.mouseUp(); refresh() }

    // MARK: output

    public func state() -> PetViewState {
        let now = clock.now
        return PetViewState(scene: machine.scene, chipScene: machine.baseScene, elapsed: max(0, now - machine.sceneSince),
                            duration: machine.duration, verbSeed: verbSeed, pastSeed: pastSeed,
                            blink: blinking && now < blinkEnds, visible: visible)
    }

    private func scheduleBlink(from now: TimeInterval) {
        nextBlink = now + Self.blinkRange.lowerBound + randomUnit() * (Self.blinkRange.upperBound - Self.blinkRange.lowerBound)
    }

    /// Applies due deadlines, renders, and re-arms the single timer (or none).
    public func refresh() {
        scheduler.cancel(); timerIsArmed = false
        guard visible else {
            previousScene = .sleep
            onRender?(state())
            return
        }
        if machine.baseScene == .thinking, machine.lease != nil, sourceBEnabled, let device {
            machine.deviceChanged(running: device.running() == true)
        }
        machine.tick()
        let now = clock.now
        if machine.scene == .idle {
            if previousScene != .idle { blinking = false; scheduleBlink(from: now) }
            if blinking, now >= blinkEnds { blinking = false; scheduleBlink(from: now) }
            else if !blinking, now >= nextBlink { blinking = true; blinkEnds = now + Self.blinkDuration }
        } else { blinking = false }
        previousScene = machine.scene
        let current = state()
        onRender?(current)

        var delays: [TimeInterval] = []
        if let deadline = machine.nextDeadline { delays.append(deadline - now) }
        if machine.scene == .idle { delays.append((blinking ? blinkEnds : nextBlink) - now) }
        else if let interval = animationInterval(current) { delays.append(interval) }
        guard let delay = delays.min() else { return }
        scheduler.arm(after: max(0.001, delay), leeway: machine.scene == .idle ? Self.idleLeeway : Self.animationLeeway)
        timerIsArmed = true
    }
}
