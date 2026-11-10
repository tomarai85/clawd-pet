import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Sprint 4c item 2: `appliedGeneration` in status.json is the CLI's proof that a setting is in effect. These tests pin that to behaviour:
//   - every key the CLI writes is applied live, and the behaviour has already changed at the instant status.json is told (the
//     `willConfirm` seam of AgentRuntime runs right before it), key by key;
//   - the keys only a restart applies (overFullScreen, Source B, the input device, idleBudgetMode) are NOT confirmed: status.json says
//     `restartRequired` for that generation and `appliedGeneration` stays where it was;
//   - the watcher applies a generation before it confirms it.

/// One event log for a sink, so the ORDER of apply and applied is visible (the recording sink of SettingsTests keeps two arrays).
private final class OrderSink: SettingsApplySink {
    var events: [String] = []
    let semaphore = DispatchSemaphore(value: 0)
    func apply(_ settings: AppliedSettings) { events.append("apply \(settings.generation)") }
    func applied(generation: Int, settings: AppliedSettings) { events.append("applied \(generation)"); semaphore.signal() }
    func wait(count: Int) -> Bool {
        var seen = 0
        while seen < count { if semaphore.wait(timeout: .now() + 2) == .timedOut { return false }; seen += 1 }
        return true
    }
}

/// What the running pet looks like, read at one moment.
private struct Behaviour: Equatable {
    var walk: Bool, motion: MotionLevel, lookEveryHours: Int, lookPin: String?
    var bubble: Bool, bubbleExcluded: Set<Int>, hiddenUntil: Double
    var canvasWidth: Double?, scale: Double, shown: Bool, dismissed: Int
    /// When the scheduler would change the look next (it is lookSince plus the interval, read on demand).
    var nextLookChange: Date?
}

@MainActor
private func behaviour(of rig: RuntimeRig) -> Behaviour {
    let s = rig.stage.scheduler.settings
    return Behaviour(walk: s.walk, motion: s.motion, lookEveryHours: s.lookEveryHours, lookPin: s.lookPin, bubble: s.bubble,
                     bubbleExcluded: s.bubbleExcluded, hiddenUntil: s.hiddenUntil, canvasWidth: rig.stage.lastFrame.map { Double($0.canvas.width) },
                     scale: rig.stage.scheduler.geometry.scale, shown: rig.stage.lastFrame != nil, dismissed: rig.machine.dismissed,
                     nextLookChange: rig.stage.scheduler.nextLookChange)
}

@Suite("Settings applied versus behaviour", .serialized)
@MainActor
struct SettingsConfirmationSuite {
    /// The control.json the CLI would leave: a rename of a complete file, one more generation.
    private func write(_ rig: RuntimeRig, _ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: try rig.store.url("control.json"), options: .atomic)
    }

    /// Writes `changes` over `base` as `generation`, waits for status.json to name it, and returns the behaviour the seam saw at the
    /// instant of the confirmation together with the behaviour before the write.
    private func apply(_ rig: RuntimeRig, base: [String: Any], changes: [String: Any], generation: Int) async throws -> (before: Behaviour, atConfirm: Behaviour) {
        var seen: Behaviour?
        let before = behaviour(of: rig)
        rig.runtime.willConfirm = { [unowned rig] generationSeen in if generationSeen == generation { seen = behaviour(of: rig) } }
        var object = base; for (key, value) in changes { object[key] = value }; object["generation"] = generation
        try write(rig, object)
        await rig.spin(until: { (try? rig.status.appliedGeneration) == generation })
        #expect(try rig.status.appliedGeneration == generation, "generation \(generation) was confirmed")
        return (before, try #require(seen, "the seam saw generation \(generation) before status.json named it"))
    }

    @Test func Applied_walkOffIsInEffectWhenItsGenerationIsConfirmed() async throws {
        let rig = try RuntimeRig(control: ["scale": 1, "generation": 0]); await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
        let result = try await apply(rig, base: ["scale": 1], changes: ["walk": false], generation: 1)
        #expect(result.before.walk); #expect(!result.atConfirm.walk, "the scheduler no longer walks when status.json says generation 1 is applied")
        #expect(rig.lines("WALK disabled").count == 1)
    }
    @Test func Applied_motionLevelIsInEffectWhenItsGenerationIsConfirmed() async throws {
        let rig = try RuntimeRig(control: ["scale": 1, "generation": 0]); await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
        let result = try await apply(rig, base: ["scale": 1], changes: ["motion": "lively"], generation: 1)
        #expect(result.before.motion == .quiet); #expect(result.atConfirm.motion == .lively)
    }
    @Test func Applied_lookEveryIsInEffectWhenItsGenerationIsConfirmed() async throws {
        let rig = try RuntimeRig(control: ["scale": 1, "generation": 0]); await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
        let result = try await apply(rig, base: ["scale": 1], changes: ["lookEveryHours": 2], generation: 1)
        #expect(result.before.lookEveryHours == 4); #expect(result.atConfirm.lookEveryHours == 2)
        let before = try #require(result.before.nextLookChange, "a look change is due some time"), after = try #require(result.atConfirm.nextLookChange)
        let factor = rig.stage.scheduler.persisted.lookDueFactor
        #expect(abs(before.timeIntervalSince(after) - 2 * 3600 * factor) < 1, "the next look change moved up by the two hours the setting shrank, times the factor of the interval (\(factor))")
    }
    @Test func Applied_bubbleOffIsInEffectWhenItsGenerationIsConfirmed() async throws {
        let rig = try RuntimeRig(control: ["scale": 1, "generation": 0]); await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
        let result = try await apply(rig, base: ["scale": 1], changes: ["bubble": false], generation: 1)
        #expect(result.before.bubble); #expect(!result.atConfirm.bubble)
        #expect(try rig.status.bubble == false)
    }
    @Test func Applied_bubbleExcludeIsInEffectWhenItsGenerationIsConfirmed() async throws {
        let rig = try RuntimeRig(control: ["scale": 1, "generation": 0]); await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
        // Styles 1, 6 and 10 are the ones drawn today (StageRuntime offers the scheduler every other style as excluded already).
        let result = try await apply(rig, base: ["scale": 1], changes: ["bubbleExcluded": [6, 10]], generation: 1)
        #expect(!result.before.bubbleExcluded.contains(6) && !result.before.bubbleExcluded.contains(10))
        #expect(result.atConfirm.bubbleExcluded.isSuperset(of: [6, 10]), "the exclusion is in the scheduler when status.json says it is applied")
    }
    @Test func Applied_sizeIsInEffectWhenItsGenerationIsConfirmed() async throws {
        let rig = try RuntimeRig(control: ["scale": 1, "generation": 0]); await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
        let result = try await apply(rig, base: ["scale": 1], changes: ["scale": 2], generation: 1)
        #expect(result.before.canvasWidth == 48); #expect(result.atConfirm.canvasWidth == 96, "the picture is already drawn at the new size")
        #expect(result.atConfirm.scale == 2, "and the scheduler plans with it")
    }
    @Test func Applied_helmetOnIsInEffectWhenItsGenerationIsConfirmed() async throws {
        let rig = try RuntimeRig(control: ["scale": 1, "generation": 0]); await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
        let result = try await apply(rig, base: ["scale": 1], changes: ["helmet": true], generation: 1)
        #expect(result.before.lookPin == nil); #expect(result.atConfirm.lookPin == "helmet", "the helmet look is pinned when status.json says so")
    }
    @Test func Applied_hideAndShowAreInEffectWhenTheirGenerationsAreConfirmed() async throws {
        let rig = try RuntimeRig(control: ["scale": 1, "generation": 0]); await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
        let hidden = try await apply(rig, base: ["scale": 1], changes: ["hiddenUntil": -1], generation: 1)
        #expect(hidden.before.shown); #expect(hidden.atConfirm.hiddenUntil == -1)
        #expect(!hidden.atConfirm.shown, "Clawd is already off the screen when status.json says the hide is applied")
        #expect(hidden.atConfirm.dismissed > hidden.before.dismissed)
        let shown = try await apply(rig, base: ["scale": 1], changes: ["hiddenUntil": 0], generation: 2)
        #expect(shown.atConfirm.hiddenUntil == 0); #expect(shown.atConfirm.shown, "and back on it when the show is applied")
    }

    // MARK: the keys only a restart applies

    private static let restartCases: [(key: String, boot: Any, changed: Any)] = [
        ("overFullScreen", false, true), ("releaseHintsEnabled", false, true),
        ("selectedInputKeyPath", "nativeMicrophone.id", "other.input.id"), ("idleBudgetMode", false, true),
        ("aqua", "auto", "ignore"), ("aquaReact", true, false),
    ]

    @Test func Applied_aKeyOnlyARestartAppliesIsReportedAndItsGenerationIsNotConfirmed() async throws {
        #expect(Self.restartCases.map(\.key) == AgentControl.restartKeyNames, "every restart-only key has a case here")
        for (key, boot, changed) in Self.restartCases {
            let rig = try RuntimeRig(control: ["scale": 1, key: boot, "generation": 0])
            await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
            #expect(try rig.status.restartRequired == nil, "\(key): nothing pending after the start")
            // The same write carries a live key too: that one is applied, the generation is still not confirmed.
            try write(rig, ["scale": 1, key: changed, "walk": false, "generation": 1])
            await rig.spin(until: { (try? rig.status.restartRequired) != nil })
            let status = try rig.status
            #expect(status.restartRequired == [key], "\(key): the agent reports the key that needs a restart")
            #expect(status.restartGeneration == 1, "\(key): and the generation that carries it")
            #expect(status.appliedGeneration == 0, "\(key): appliedGeneration does not advance to a generation whose key is not in effect")
            #expect(!rig.stage.scheduler.settings.walk, "\(key): the live key of the same write is applied")
            #expect(rig.lines("SETTINGS restart-required generation=1 keys=\(key)").count == 1, "\(key): \(rig.log)")
            // The log tells what status.json tells: saved with a restart pending, never "applied".
            #expect(rig.lines("SETTINGS saved generation=1 restart-pending keys=\(key)").count == 1, "\(key): \(rig.log)")
            #expect(rig.lines("SETTINGS applied generation=1").isEmpty, "\(key): a generation that waits for a restart is not logged as applied: \(rig.log)")
            // Writing the boot value back leaves nothing to restart for: the generation is confirmed and the report is cleared.
            try write(rig, ["scale": 1, key: boot, "walk": false, "generation": 2])
            await rig.spin(until: { (try? rig.status.appliedGeneration) == 2 })
            let after = try rig.status
            #expect(after.appliedGeneration == 2); #expect(after.restartRequired == nil); #expect(after.restartGeneration == nil)
            #expect(rig.lines("SETTINGS applied generation=2").count == 1, "\(key): the generation with nothing left to restart for is logged as applied: \(rig.log)")
            #expect(rig.lines("SETTINGS saved generation=2").isEmpty, "\(key): and not as saved")
        }
    }
    @Test func Applied_severalRestartKeysAreListedInOrderAndALiveKeyNeverIsOne() async throws {
        let rig = try RuntimeRig(control: ["scale": 1, "generation": 0])
        await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
        try write(rig, ["scale": 2, "helmet": true, "idleBudgetMode": true, "overFullScreen": true, "generation": 1])
        await rig.spin(until: { (try? rig.status.restartRequired) != nil })
        #expect(try rig.status.restartRequired == ["overFullScreen", "idleBudgetMode"], "in the order of AgentControl.restartKeyNames")
        #expect(rig.stage.lastFrame?.canvas.width == 96, "scale is live")
        #expect(rig.stage.scheduler.settings.lookPin == "helmet", "helmet is live")
        // A live-only write after it does not hide the pending restart: the boot values still differ.
        try write(rig, ["scale": 2, "helmet": true, "idleBudgetMode": true, "overFullScreen": true, "walk": false, "generation": 2])
        await rig.spin(until: { (try? rig.status.restartGeneration) == 2 })
        #expect(try rig.status.restartRequired == ["overFullScreen", "idleBudgetMode"]); #expect(try rig.status.appliedGeneration == 0)
    }
    @Test func Applied_aNewProcessStartsWithAnEmptyReportAndConfirmsWhatItLoaded() async throws {
        // The restart the CLI asks for: the new process boots with the changed value as its boot value, so nothing is pending.
        let rig = try RuntimeRig(control: ["scale": 1, "overFullScreen": true, "idleBudgetMode": true, "generation": 7])
        await rig.spin(until: { (try? rig.status.appliedGeneration) == 7 })
        let status = try rig.status
        #expect(status.appliedGeneration == 7); #expect(status.restartRequired == nil); #expect(status.restartGeneration == nil)
        #expect(status.pid == getpid())
    }

    // MARK: pure pieces

    @Test func Applied_restartKeysComparesExactlyTheFiveKeysAgainstTheBootValues() {
        let boot = AgentControl()
        var control = boot
        #expect(control.restartKeys(since: boot) == [])
        control.scale = 4; control.helmet = true
        #expect(control.restartKeys(since: boot) == [], "scale and helmet apply live")
        control.overFullScreen = true; #expect(control.restartKeys(since: boot) == ["overFullScreen"])
        control.releaseHintsEnabled = true; #expect(control.restartKeys(since: boot) == ["overFullScreen", "releaseHintsEnabled"])
        control.selectedInputKeyPath = "x.y"; control.idleBudgetMode = true; control.aqua = .ignore; control.aquaReact = false
        #expect(control.restartKeys(since: boot) == AgentControl.restartKeyNames)
        #expect(boot.restartKeys(since: control) == AgentControl.restartKeyNames, "it is a difference, not a direction")
    }
    @Test func Applied_aStatusConfirmsAGenerationOnlyWhenNoRestartIsPending() {
        var status = AgentStatus()
        status.settingsApplied(generation: 3, restartKeys: [])
        #expect(status.appliedGeneration == 3); #expect(status.restartRequired == nil)
        status.settingsApplied(generation: 4, restartKeys: ["overFullScreen"])
        #expect(status.appliedGeneration == 3, "the old confirmation stays"); #expect(status.restartRequired == ["overFullScreen"]); #expect(status.restartGeneration == 4)
        status.settingsApplied(generation: 5, restartKeys: [])
        #expect(status.appliedGeneration == 5); #expect(status.restartRequired == nil); #expect(status.restartGeneration == nil)
    }

    // MARK: the watcher

    @Test func Applied_theWatcherAppliesAGenerationBeforeItConfirmsIt() throws {
        let store = try artifactStore()
        func write(_ object: [String: Any]) throws {
            let partial = store.root.appendingPathComponent("control.json.partial"), target = store.root.appendingPathComponent("control.json")
            try JSONSerialization.data(withJSONObject: object).write(to: partial)
            guard rename(partial.path, target.path) == 0 else { throw FileFailure.system(errno) }
        }
        try write(["walk": true, "generation": 0])
        let watcher = SettingsWatcher(store: store, queue: DispatchQueue(label: "applied.order"))
        _ = watcher.load()
        let sink = OrderSink()
        watcher.start(sink: sink)
        try write(["walk": false, "generation": 1])
        #expect(sink.wait(count: 2))
        watcher.stop()
        #expect(sink.events == ["apply 0", "applied 0", "apply 1", "applied 1"], "\(sink.events)")
    }
}
