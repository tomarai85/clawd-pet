import Foundation
import QuartzCore
import ClawdCore
import ClawdRendering
import Darwin

/// What the scheduler would do under a set of settings, found by running the real `PetScheduler` for two simulated hours on a virtual
/// clock with a fixed seed. The headless settings mode logs it after every applied generation, so a test (and a person) can see
/// that `walk off` leaves no walk, `motion off` no idle motion and `bubble off` no bubble frame.
public struct SchedulerPlan: Equatable {
    public var walks = 0
    public var motions = 0
    public var lookChanges = 0
    /// Seconds from the start of the simulation to each look change.
    public var lookChangeTimes: [TimeInterval] = []
    public var bubbleShown = false
    public static let simulatedHours = 2.0

    private final class NullTimer: PetTimerScheduler {
        func arm(after delay: TimeInterval, leeway: TimeInterval) {}
        func cancel() {}
    }

    /// Runs the real scheduler for `seconds` on a virtual clock, with the headless stage's geometry and nothing drawn, and counts what
    /// it started. `lookDueIn` makes the first look change due that many seconds in (as the headless render mode does).
    public static func plan(settings: SchedulerSettings, art: URL, seed: UInt64 = 7, seconds: TimeInterval = simulatedHours * 3600,
                            lookDueIn: TimeInterval? = nil) throws -> SchedulerPlan {
        let catalog = try ClawdArt(directory: art).catalog
        let clock = VirtualClock()
        let random = SeededRandom(seed: seed)
        var persisted: SchedulerPersisted?
        if let due = lookDueIn {
            persisted = SchedulerPersisted(look: PetCatalog.plainLook,
                                           lookSince: clock.wallNow.timeIntervalSince1970 - Double(settings.lookEveryHours) * 3600 + due)
        }
        let scheduler = PetScheduler(clock: clock, timer: NullTimer(), catalog: catalog, settings: settings, geometry: HeadlessStage.geometry(),
                                     persisted: persisted, random: { random.unit() })
        scheduler.walkSpeedWhenStrideUndeclared = StageRuntime.walkSpeedWhenStrideUndeclared
        var plan = SchedulerPlan()
        let origin = clock.now
        scheduler.onEvent = { at, event in
            switch event {
            case .walkStart: plan.walks += 1
            case .motionStart(_, let use) where use == "idle" || use.hasPrefix("signature:"): plan.motions += 1
            case .lookChange: plan.lookChanges += 1; plan.lookChangeTimes.append(at - origin)
            default: break
            }
        }
        scheduler.refresh()
        let end = clock.now + seconds
        var guardCount = 0
        while let wake = scheduler.nextWake, wake <= end, guardCount < 200_000 {
            guardCount += 1
            clock.advance(max(0, wake - clock.now))
            scheduler.refresh()
        }
        scheduler.sceneChanged(.listening, lease: 1)
        plan.bubbleShown = scheduler.frame().bubble != nil
        return plan
    }
}

/// The headless settings mode (`--test-settings SECONDS STATE ART`): the real agent binary with the same `SettingsWatcher` and
/// `StageRuntime` the desktop runtime constructs, and no window. It applies every control.json change live, writes
/// `appliedGeneration` to status.json, and logs `SETTINGS applied generation=<n>`, the scheduler's own `WALK enabled|disabled`
/// lines and a `PLAN` line (SchedulerPlan) per applied generation. The process id never changes.
final class SettingsRun {
    static func run(seconds: Double, stateDirectory: URL, art: URL) -> Int32 {
        do {
            let store = try OwnState(root: stateDirectory)
            let run = try SettingsRun(store: store, art: art)
            run.start()
            say("SETTINGS-READY pid=\(getpid())")
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                withExtendedLifetime(run) { say("SETTINGS-DONE generation=\(run.status.appliedGeneration.map(String.init) ?? "none")"); exit(0) }
            }
            dispatchMain()
        } catch { fputs("settings mode failed: \(error)\n", stderr); return 2 }
    }
    private static func say(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

    private let store: OwnState
    private let art: URL
    private let watcher: SettingsWatcher
    private let timer = DispatchPetTimer()
    private let runtime: StageRuntime
    private let live: LiveSettings
    /// The two layers the desktop path has (the stage window's and the body window's).
    private let layer = CALayer(), bodyLayer = CALayer()
    private(set) var status = AgentStatus()
    private let bootControl: AgentControl

    private func log(_ text: String) {
        try? store.append("\(String(format: "%.6f", Date().timeIntervalSince1970)) \(text)\n", to: OwnState.agentLogName)
    }

    init(store: OwnState, art: URL) throws {
        self.store = store; self.art = art
        watcher = SettingsWatcher(store: store)
        let initial = watcher.load()
        bootControl = initial.control
        status.mode = "test-settings-no-window"; status.idleBudgetMode = true
        status.pid = ProcessInfo.processInfo.processIdentifier
        let geometry = HeadlessStage.geometry(scale: Placement.effectiveScale(initial.control.scale))
        let random = SeededRandom.fromSystem()
        runtime = try StageRuntime(clock: SystemPetClock(), timer: timer, art: art,
                                   settings: initial.effectiveScheduler(helmetOffPending: false), geometry: geometry, random: { random.unit() })
        live = LiveSettings(runtime: runtime, initial: initial)
        runtime.hostGeometry = { StageHostGeometry(geometry: geometry, pixelScale: 2) }
        runtime.present = { [unowned self] stage in
            guard let pictures = try? PanelPictures(stage) else { return }
            RenderPipeline.apply(pictures.stage, to: self.layer)
            if let body = pictures.body { RenderPipeline.apply(body, to: self.bodyLayer) }
        }
        runtime.log = { [unowned self] text in self.log(text) }
        runtime.onEvent = { [unowned self] event in self.live.schedulerEvent(event) }
        live.log = { [unowned self] text in self.log(text) }
        live.didApply = { [unowned self] generation, settings, effective in
            self.status.settingsApplied(generation: generation, restartKeys: settings.control.restartKeys(since: self.bootControl))
            self.status.walk = effective.walk; self.status.motion = effective.motion.rawValue; self.status.bubble = effective.bubble
            self.status.look = self.runtime.scheduler.look
            try? self.store.writeJSON(self.status, to: "status.json")
            if let plan = try? SchedulerPlan.plan(settings: effective, art: self.art) {
                self.log("PLAN generation=\(generation) walks=\(plan.walks) motions=\(plan.motions) bubble=\(plan.bubbleShown ? "yes" : "no") hours=\(Int(SchedulerPlan.simulatedHours))")
            }
        }
        timer.onFire = { [unowned self] in self.runtime.tick() }
        runtime.controller.machine.onChange = { [unowned self] _ in self.runtime.sceneChanged() }
    }

    func start() {
        try? store.writeJSON(status, to: "status.json")
        runtime.setQuiet(.aquaNotRunning, active: false)
        runtime.start()
        watcher.start(sink: live)
    }
}
