import Foundation
import CoreGraphics
import ClawdCore
import ClawdRendering

/// Where Clawd lives right now, as the host knows it: the geometry the scheduler plans with and the display's pixel density.
public struct StageHostGeometry: Equatable {
    public var geometry: PetGeometry
    public var pixelScale: Double
    public init(geometry: PetGeometry, pixelScale: Double) { self.geometry = geometry; self.pixelScale = pixelScale }
}

/// The pet without a window: the v1 controller (scenes, blink), the v2 scheduler (idle life, walks, looks, touch, SLEEP, bubble
/// style) and the stage renderer, driven by ONE timer (`MergedWake`). The desktop runtime puts the finished picture in a panel and
/// the headless render mode puts it in a layer; both run this same code, so the CPU a headless run measures is the shown agent's
/// scene, scheduling and picture work.
///
/// Threading: everything runs on the queue the timer fires on (main).
public final class StageRuntime: QuietSink {
    /// v1's blink rate and the idle wait both lean on the scene machine; SLEEP is the scheduler's (10 min of input idle), never the machine's.
    public static let walkSpeedWhenStrideUndeclared = 30.0
    /// The bubble styles the renderer draws today (twelve since Sprint 6; the ids 13 to 15 are offered once they are drawn). Offering an undrawn style would show style 1 under
    /// another name, so the scheduler is never offered one.
    public static let drawnBubbleStyles: Set<Int> = Set(BubbleDesign.allIds)
    /// The settings as the scheduler gets them: the user's exclusions plus every style that is not drawn yet.
    public static func offered(_ settings: SchedulerSettings) -> SchedulerSettings {
        var offered = settings
        offered.bubbleExcluded.formUnion(Set(SchedulerSettings.bubbleStyles).subtracting(drawnBubbleStyles))
        return offered
    }

    public let clock: PetClock
    public let controller: PetController
    public let scheduler: PetScheduler
    public let renderer: StageRenderer
    public let wake: MergedWake
    public private(set) var settings: SchedulerSettings

    /// nil while no display is attached: nothing is shown.
    public var hostGeometry: () -> StageHostGeometry? = { nil }
    /// A finished picture, to put on screen (desktop) or in a layer (headless).
    public var present: (StageFrame) -> Void = { _ in }
    /// Nothing is shown (hidden, a quiet condition, no display).
    public var dismiss: () -> Void = {}
    /// Lines for agent.log (without the timestamp).
    public var log: (String) -> Void = { _ in }
    public var persist: (SchedulerPersisted) -> Void = { _ in }
    /// Every scheduler event, after it has been written to the log.
    public var onEvent: (SchedulerEvent) -> Void = { _ in }
    /// The outermost batch has finished, including updates while hidden or quiet that need no picture.
    public var onUpdate: () -> Void = {}
    /// The scheduler's Aqua retry deadline passed (amendment D-2, round 2): the host asks its follower to look again.
    public var onAquaRetry: () -> Void = {}
    /// While Clawd is dragged, the canvas origin under the pointer replaces home in the picture.
    public var dragOrigin: CGPoint?
    /// The open menu's rectangle (Sprint M); it joins the hit region while open.
    public var menuRect: CGRect?

    public private(set) var lastFrame: StageFrame?
    public private(set) var lastRequest: StageRequest?
    public private(set) var renderCount = 0
    public private(set) var lastScene: Scene = .idle
    /// The macOS appearance, as the desktop observers last reported it. It travels with the bubble's content to the renderer.
    public private(set) var appearance: BubbleAppearance = .light
    /// The placement memory of the bubble on screen (amendment D-2 E5): committed here, after a frame is presented, from the layout of that frame;
    /// cleared when the bubble ends. The renderer reads it through the request and never writes it.
    public private(set) var bubbleMemory: BubbleMemory?

    private let controllerSlot: MergedWake.Slot
    private let schedulerSlot: MergedWake.Slot
    private let rendererSlot: MergedWake.Slot
    private var depth = 0
    private var needsRender = false
    private var started = false
    /// The last `apply(settings:)` changed only the side (see `renderAfterSettings()`).
    private var lastApplyWasSideOnly = false

    /// `timer` is the one real timer (a `DispatchPetTimer` in production, a fake on a virtual clock in tests).
    public init(clock: PetClock, timer: PetTimerScheduler, art: URL, settings: SchedulerSettings = SchedulerSettings(),
                geometry: PetGeometry, persisted: SchedulerPersisted? = nil, random: @escaping () -> Double = { Double.random(in: 0..<1) }) throws {
        self.clock = clock
        renderer = try StageRenderer(art: art)
        self.settings = Self.offered(settings)
        wake = MergedWake(timer: timer, clock: clock)
        controllerSlot = wake.makeSlot(); schedulerSlot = wake.makeSlot(); rendererSlot = wake.makeSlot()
        controller = PetController(clock: clock, scheduler: controllerSlot)
        scheduler = PetScheduler(clock: clock, timer: schedulerSlot, catalog: renderer.art.catalog, settings: Self.offered(settings), geometry: geometry,
                                 persisted: persisted, random: random)
        scheduler.walkSpeedWhenStrideUndeclared = Self.walkSpeedWhenStrideUndeclared
        controller.machine.sleepEnabled = false
        controller.animationInterval = { _ in nil }
        // Nothing may run in a quiet condition or while hidden (spec 6.1): a source's arm is ignored then.
        let visible: () -> Bool = { [unowned self] in self.scheduler.visibility == .visible }
        controllerSlot.allowed = visible; rendererSlot.allowed = visible
        controller.onRender = { [unowned self] _ in self.needsRender = true; if self.depth == 0 { self.perform {} } }
        scheduler.onFrameChange = { [unowned self] in self.needsRender = true; if self.depth == 0 { self.perform {} } }
        scheduler.onPersist = { [unowned self] state in self.persist(state) }
        scheduler.onEvent = { [unowned self] _, event in self.logEvent(event); self.onEvent(event) }
    }

    deinit { wake.stop() }

    // MARK: the loop

    /// Starts the schedule: the first idle wait, the first picture. Call once after every closure is set.
    public func start() {
        guard !started else { return }
        started = true
        perform { scheduler.refresh(); controller.refresh() }
    }

    /// The timer fired.
    public func tick() {
        wake.fired()
        needsRender = true
        perform { withExamResume { controller.refresh(); scheduler.refresh() } }
    }

    /// The exam stand-down (amendment D-4) ends inside the scheduler (a deadline or a notification): v1's controller, which armed nothing while
    /// Clawd was away, is asked once more when it does, as after any other quiet reason.
    private func withExamResume(_ body: () -> Void) {
        let standingDown = scheduler.quietReasons.contains(.examBrowser)
        body()
        if standingDown, !scheduler.quietReasons.contains(.examBrowser) { needsRender = true; controller.refresh() }
    }

    /// The host starts: whether a LockDown Browser application is running (or the stand-down is still owed). Call before any window can be
    /// shown; the host raises the quiet reason when this says so.
    public func examStartup(running: Bool) -> Bool { scheduler.examStartup(running: running) }

    /// A LockDown Browser application launched: from this turn on there is no window.
    public func examApplicationLaunched() { perform { withExamResume { scheduler.examApplicationLaunched() } } }

    /// An application that matched quit: the running applications are asked again.
    public func examApplicationTerminated() { perform { withExamResume { scheduler.examApplicationTerminated() } } }

    /// The running applications are asked now: a wake, an unlock, a Space change.
    public func examRecheck() {
        // Nothing to correct (no stand-down, none running): no pass through the scheduler, so an ordinary wake changes nothing it did before.
        guard scheduler.examActive || scheduler.examBrowserRunning() else { return }
        perform { withExamResume { scheduler.examRecheckNow() } }
    }

    /// Runs `body` with every re-arm and every render merged: one timer commit and at most one picture at the end.
    public func perform(_ body: () -> Void) {
        wake.batch {
            depth += 1
            body()
            depth -= 1
            if depth == 0, needsRender { render() }
            if depth == 0 { onUpdate() }
        }
        // The follower's retry deadline passed during this pass: it runs after the pass, so its own changes are a pass of their own.
        if depth == 0, scheduler.takeAquaRetryDue() { onAquaRetry() }
    }

    /// Re-renders now (after a drag step or a geometry change).
    public func renderNow() {
        needsRender = true
        perform {}
    }

    // MARK: picture

    func bubbleContent(for frame: SchedulerFrame) -> BubbleContent {
        let state = controller.state()
        let elements = renderer.elements
        let verbs = elements.present, past = elements.past
        return BubbleContent(scene: frame.bubble?.scene ?? state.chipScene, elapsed: state.elapsed, duration: state.duration,
                             verb: verbs.isEmpty ? "Clauding" : verbs[state.verbSeed % verbs.count],
                             pastVerb: past.isEmpty ? nil : past[state.pastSeed % past.count], reduceMotion: scheduler.reduceMotion, appearance: appearance)
    }

    private func render() {
        needsRender = false
        rendererSlot.cancel()
        guard let host = hostGeometry() else { stopSources(); lastFrame = nil; bubbleMemory = nil; dismiss(); return }
        let frame = scheduler.frame()
        lastScene = frame.scene
        // Nothing runs while hidden or in a quiet condition (spec 6.1): the controller's blink and the renderer's frame wake go too.
        guard frame.visibility == .visible else { stopSources(); lastFrame = nil; bubbleMemory = nil; dismiss(); return }
        var geometry = host.geometry
        if let origin = dragOrigin { geometry.homeOrigin = origin }
        // The menu holds Clawd still (R-HOLD): the blink is held too, so the body's bounds never change while the menu is open.
        let request = StageRequest(frame: frame, now: clock.now, blink: controller.state().blink && !scheduler.menuOpen, geometry: geometry,
                                   pixelScale: host.pixelScale, content: bubbleContent(for: frame), menuRect: menuRect, bubbleSide: settings.bubbleSide,
                                   bubbleMemory: bubbleMemory)
        do {
            guard let stage = try renderer.compose(request) else { lastFrame = nil; bubbleMemory = nil; dismiss(); return }
            lastFrame = stage; lastRequest = request; renderCount += 1
            present(stage)
            // Committed from a presented frame only: a layout nobody presented commits nothing, and one presented frame commits once.
            bubbleMemory = stage.layout.memory
            // The wake follows the picture just composed, not the scheduler's frame: a bubble placement dropped adds no boundary.
            if let next = renderer.nextChange(request, composed: stage) { rendererSlot.arm(after: max(0.001, next), leeway: 0.005) }
        } catch {
            lastFrame = nil; bubbleMemory = nil
            log("RENDER failed")
            dismiss()
        }
    }

    private func stopSources() { controllerSlot.cancel(); rendererSlot.cancel() }

    // MARK: inputs from the host

    /// Re-reads where Clawd lives (display, size, home) and tells the scheduler when it changed.
    public func syncGeometry() {
        guard let host = hostGeometry() else { return }
        if differs(host) { perform { scheduler.update(geometry: host.geometry) } }
    }

    /// Whether `syncGeometry()` called now would move Clawd (amendment R-GEOM): the host is read afresh, and the same comparison decides.
    /// False when there is no display to read.
    public func geometryWillChange() -> Bool {
        guard let host = hostGeometry() else { return false }
        return differs(host)
    }

    private func differs(_ host: StageHostGeometry) -> Bool { !Self.sameGeometry(host.geometry, scheduler.geometry) }

    /// Equal up to float noise: a home saved as display fractions comes back a few ulps away from the point it was dropped at, and that
    /// must not count as "Clawd moved" (it would end a walk).
    static func sameGeometry(_ a: PetGeometry, _ b: PetGeometry) -> Bool {
        a.scale == b.scale && a.displayFrame == b.displayFrame && a.visibleFrame == b.visibleFrame
            && abs(a.homeOrigin.x - b.homeOrigin.x) < 0.01 && abs(a.homeOrigin.y - b.homeOrigin.y) < 0.01
    }

    public func apply(settings new: SchedulerSettings) {
        let old = settings
        settings = Self.offered(new)
        // The side is a placement-time input only: the scheduler never reads it. A generation that changes nothing else (the side, and the generation
        // counter that every write bumps) does not touch the scheduler, so a side change with no bubble on screen renders nothing and arms nothing.
        var others = settings; others.bubbleSide = old.bubbleSide; others.generation = old.generation
        let sideOnly = settings.bubbleSide != old.bubbleSide && others == old
        lastApplyWasSideOnly = sideOnly
        guard !sideOnly else {
            // A shown bubble is drawn again on the new side within this committed frame.
            if lastFrame?.bubble != nil { renderNow() }
            return
        }
        let sideChanged = settings.bubbleSide != old.bubbleSide
        perform {
            scheduler.update(settings: settings)
            if sideChanged, lastFrame?.bubble != nil { needsRender = true }
        }
    }

    /// The draw the agent makes after a settings generation (for the size and the rest). A side-only generation was already drawn, or needed
    /// no drawing, in `apply(settings:)`, so it draws nothing here either.
    public func renderAfterSettings() {
        guard !lastApplyWasSideOnly else { return }
        renderNow()
    }

    /// The press that began a drag lost its window (hidden, a quiet condition): the drag ends without a landing and Clawd is at home.
    public func cancelDrag() {
        dragOrigin = nil
        guard scheduler.isDragging else { return }
        perform { scheduler.dragCancelled() }
    }

    /// The follower asks for its retry deadline (one second ahead) or drops it; the scheduler's timer carries it.
    public func setAquaRetry(_ armed: Bool) { perform { scheduler.setAquaRetry(armed) } }

    public func sceneChanged() {
        perform { scheduler.sceneChanged(controller.machine.baseScene, lease: controller.machine.lease) }
    }

    // MARK: QuietSink

    public func setQuiet(_ reason: QuietReason, active: Bool) {
        perform {
            scheduler.setQuiet(reason, active: active)
            // v1's controller keeps its own view of "Aqua running" and "system asleep"; it renders nothing while they hold.
            if reason == .aquaNotRunning { controller.setAquaRunning(!active) }
            if reason == .systemAsleep { if active { controller.systemWillSleep() } else { controller.systemDidWake() } }
            if !active { needsRender = true; controller.refresh() }
        }
        // A wake, an unlock or a Space change is also the moment a missed launch or quit of a LockDown Browser application is corrected.
        if !active, reason != .examBrowser { examRecheck() }
    }

    public func setReduceMotion(_ on: Bool) {
        perform { scheduler.setReduceMotion(on) }
    }

    /// The appearance changed (or is reported for the first time). One render when a bubble is shown, so the new palette is drawn from that
    /// frame on, a still bubble included; nothing otherwise: no render and no timer with no bubble on screen or in a quiet condition.
    public func setAppearance(_ new: BubbleAppearance) {
        guard new != appearance else { return }
        appearance = new
        guard lastFrame?.bubble != nil else { return }
        renderNow()
    }

    // MARK: agent.log

    private func logEvent(_ event: SchedulerEvent) {
        switch event {
        case .motionStart(let id, let use): log("MOTION start id=\(id) use=\(use)" + (scheduler.fallback(forMotion: id).map { " fallback=\($0)" } ?? ""))
        case .motionEnd(let id): log("MOTION end id=\(id)")
        case .walkStart(let dx): log("WALK start dx=\(Int(dx.rounded()))")
        case .walkEnd: log("WALK end")
        case .walkEnabled: log("WALK enabled")
        case .walkDisabled: log("WALK disabled")
        case .lookChange(let from, let to): log("LOOK change from=\(from) to=\(to)")
        case .lookTransition, .lookTransitionEnd: break
        case .quietOn(let reason): log("QUIET on reason=\(reason)")
        case .quietOff: log("QUIET off")
        case .hidden: log("HIDDEN")
        case .shown: log("SHOWN")
        case .sleepStart: log("SLEEP start")
        case .wake: log("SLEEP wake")
        case .touch: log("TOUCH")
        case .multiTouch: log("TOUCH multi")
        case .clickIgnored(let reason): log("CLICK-IGNORED why=\(reason)")
        case .examClear: log("EXAM clear")
        case .examSettleEnd: log("EXAM settle-end")
        case .examRecheckHealed: log("EXAM recheck-healed")
        case .bubbleStyle(let style): log("BUBBLE style=\(style)")
        }
    }
}

/// What the desktop observers drive. The scheduler hears every quiet condition and Reduce Motion through it.
public protocol QuietSink: AnyObject {
    func setQuiet(_ reason: QuietReason, active: Bool)
    func setReduceMotion(_ on: Bool)
    func setAppearance(_ appearance: BubbleAppearance)
}
