import Testing
import Foundation
import CoreGraphics
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Sprint 11 (spec 9b item 16, item 6 of the brief): Reduce Motion turned on in the middle of a LISTENING, THINKING or SENT scene replaces the
// scene's v2 motion at once with v1's pose, which is what the scene would have picked under Reduce Motion.

private func lively(_ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
    var s = SchedulerSettings(); s.motion = .lively; edit(&s); return s
}
private func calm(_ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
    var s = SchedulerSettings(); s.motion = .off; edit(&s); return s
}

extension Sprint11Scenarios {
    static func reduceMotionInAScene(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        enum Step { case listening, thinking, sent }
        func sceneRig(at step: Step, seed: UInt64) -> SchedulerRig {
            let rig = SchedulerRig(settings: calm(), seed: seed, guards: guards)
            rig.start(1)
            if step == .listening { return rig }
            rig.advance(1.2); rig.complete(1)
            if step == .thinking { return rig }
            rig.advance(1.0); rig.ack()
            return rig
        }
        for (step, pose, scene) in [(Step.listening, "listen", Scene.listening), (.thinking, "think", .thinking), (.sent, "hop", .sent)] {
            // A seed whose scene starts with a v2 motion (the pool also holds v1's pose).
            var found: SchedulerRig?
            for seed in UInt64(1)...60 {
                let candidate = sceneRig(at: step, seed: seed)
                if candidate.frame.scene == scene, candidate.frame.playback?.motionID != nil { found = candidate; break }
            }
            guard let rig = found else { v.check(false, "\(scene): no seed gave a scene that plays a v2 motion"); continue }
            let motion = rig.frame.playback?.motionID ?? ""
            let ended = rig.events.count
            rig.scheduler.setReduceMotion(true)
            v.check(rig.frame.playback?.source == .pose(pose), "\(scene): after Reduce Motion came on the scene shows \(String(describing: rig.frame.playback?.source)) instead of v1's pose \(pose)")
            v.check(rig.eventsSince(ended).contains { $0.event == .motionEnd(id: motion) }, "\(scene): the motion \(motion) was never logged as ended")
            v.check(rig.frame.scene == scene && rig.frame.bubble != nil, "\(scene): the scene or its bubble went with the motion")
            rig.advance(1.0)
            v.check(rig.frame.playback?.motionID == nil || rig.frame.scene != scene, "\(scene): a v2 motion is playing again one second later")
            if v.done { return v }
        }
        return v
    }
}

@Suite("Sprint 11 Reduce Motion", .serialized)
struct Sprint11ReduceMotionTests {
    private func holds(_ id: String, _ found: Violations, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(found.isEmpty, "\(id): \(found.summary)", sourceLocation: sourceLocation)
    }
    private func control(_ id: String, _ scenario: (SchedulerGuards, Bool) -> Violations, removing rules: [(String, SchedulerGuards)],
                         sourceLocation: SourceLocation = #_sourceLocation) {
        for (name, rule) in rules {
            let found = scenario(.all.subtracting(rule), true)
            negativeControl("\(id) without \(name)", expectationHolds: found.isEmpty, sourceLocation: sourceLocation)
            emit("    first violation: \(found.list.first ?? "none")")
        }
    }

    @Test func ReduceMotion_comingOnInTheMiddleOfAListeningThinkingOrSentSceneReplacesItsMotionAtOnce() { holds("scene motion", Sprint11Scenarios.reduceMotionInAScene(.all)) }

    @Test func ReduceMotion_comingOnInTheMiddleOfASceneNegativeControl() {
        control("reduce motion in a scene", { Sprint11Scenarios.reduceMotionInAScene($0, quick: $1) }, removing: [("reduceMotionEndsSceneMotion", .reduceMotionEndsSceneMotion)])
    }
}
