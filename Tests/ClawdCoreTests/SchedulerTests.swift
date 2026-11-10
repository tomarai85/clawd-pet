import Testing
import Foundation
import ClawdCore

/// Spec 7b: the scheduler invariants S-1 to S-13, each a named test on v1's VirtualClock with a fake single timer, and for each
/// rule a negative control: the same scenario with that one rule switched off must find a violation.
@Suite("SchedulerTests", .serialized)
struct SchedulerTests {
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

    @Test("S-1 nothing moves or renders while a quiet condition holds; timers 0, 1 while asleep, 1 while hidden with an end time")
    func S_1_quietConditionsFreezeEverything() { holds("S-1", SchedulerScenarios.s1(.all)) }
    @Test func S_1_negativeControl() { control("S-1", SchedulerScenarios.s1, removing: [("quietFreeze", .quietFreeze)]) }

    @Test("S-2 a lease opening cuts anything in the same tick; after a running transition the scene motion starts at most 2 s later")
    func S_2_leaseCutsInTheSameTick() { holds("S-2", SchedulerScenarios.s2(.all)) }
    @Test func S_2_negativeControl() {
        control("S-2", SchedulerScenarios.s2, removing: [("sceneCutsActivity", .sceneCutsActivity), ("sceneAfterTransition", .sceneAfterTransition)])
    }

    @Test("S-3 no immediate repeats for motions (per pool), looks and bubble styles; the last-3 rule and no look twice within a cycle of the rotation")
    func S_3_noImmediateRepeats() { holds("S-3", SchedulerScenarios.s3(.all)) }
    @Test func S_3_negativeControl() {
        control("S-3", SchedulerScenarios.s3, removing: [("noRepeatMotion", .noRepeatMotion), ("noRepeatLook", .noRepeatLook), ("bubbleNoRepeat", .bubbleNoRepeat)])
    }

    @Test("S-4 a look change is never within 30 s of a motion Clawd started itself, nor during a scene, walk, reaction, drag, SLEEP, quiet condition or hide")
    func S_4_lookChangeKeepsItsDistance() { for seed: UInt64 in [4, 14, 24] { holds("S-4 seed \(seed)", SchedulerScenarios.s4(.all, seed: seed)) } }
    @Test func S_4_negativeControl() {
        control("S-4", { SchedulerScenarios.s4($0, quick: $1) }, removing: [("lookGap30", .lookGap30), ("lookNeedsRest", .lookNeedsRest),
                                                                  ("lookNeedsAwake", .lookNeedsAwake), ("quiet and hide", [.quietFreeze, .lookNeedsVisible])])
    }

    @Test("S-5 over 7 simulated days per level every idle gap lies inside the level's interval and the mean is within 10% of its midpoint")
    func S_5_idleGapsInsideTheInterval() { for seed: UInt64 in [50, 150, 250] { holds("S-5 seed \(seed)", SchedulerScenarios.s5(.all, seed: seed)) } }
    @Test func S_5_negativeControl() {
        control("S-5", { SchedulerScenarios.s5($0, quick: $1) }, removing: [("idleCountedFromEnd", .idleCountedFromEnd), ("idleLowerBound", .idleLowerBound)])
    }

    @Test("S-6 look cadence: changes at least N hours apart, within 60 s after they are due")
    func S_6_lookCadence() { for seed: UInt64 in [6, 16, 26] { holds("S-6 seed \(seed)", SchedulerScenarios.s6(.all, seed: seed)) } }
    @Test func S_6_negativeControl() {
        control("S-6", { SchedulerScenarios.s6($0, quick: $1) }, removing: [("lookEveryN", .lookEveryN), ("lookOwnDeadline", .lookOwnDeadline)])
    }

    @Test("S-7 walks: range, keep-out band, visible frame, one display, always home, the pointer, 30 s of walking, a dictation ends the walk in the same tick")
    func S_7_walks() { for seed: UInt64 in [7, 70, 700] { holds("S-7 seed \(seed)", SchedulerScenarios.s7(.all, seed: seed)) } }
    @Test func S_7_negativeControl() {
        control("S-7", { SchedulerScenarios.s7($0, quick: $1) }, removing: [("walkKeepOut", .walkKeepOut), ("walkInsideFrame", .walkInsideFrame),
                                                          ("walkReturnsHome", .walkReturnsHome), ("walkPointerStop", .walkPointerStop),
                                                          ("walkSceneCancel", .walkSceneCancel), ("walkSpeedRange", .walkSpeedRange)])
    }

    @Test("S-8 no (look, motion) pair outside the compatible list and no excluded item is ever scheduled")
    func S_8_onlyCompatibleAndNotExcluded() { for seed: UInt64 in [8, 18, 28] { holds("S-8 seed \(seed)", SchedulerScenarios.s8(.all, seed: seed)) } }
    @Test func S_8_negativeControl() {
        control("S-8", { SchedulerScenarios.s8($0, quick: $1) }, removing: [("compatibility", .compatibility), ("exclusion", .exclusion)])
    }

    @Test("S-9 the bubble style is constant within a lease, never repeats across leases, and its shares over 100,000 leases match the stationary shares")
    func S_9_bubbleStylePerLease() { holds("S-9", SchedulerScenarios.s9(.all)) }
    @Test func S_9_negativeControl() {
        control("S-9", SchedulerScenarios.s9, removing: [("bubbleStyleKept", .bubbleStyleKept), ("bubbleNoRepeat", .bubbleNoRepeat), ("bubbleWeights", .bubbleWeights)])
    }

    @Test("S-10 scene pools are overhead-clear and SENT motions last at most 2.0 s")
    func S_10_scenePoolsAreOverheadClear() { holds("S-10", SchedulerScenarios.s10(.all)) }
    @Test func S_10_negativeControl() {
        control("S-10", SchedulerScenarios.s10, removing: [("poolOverheadClear", .poolOverheadClear), ("sentMaxDuration", .sentMaxDuration)])
    }

    @Test("S-11 Reduce Motion: no idle life, walk, entrance or transition; looks change as a cut; scenes use v1 poses")
    func S_11_reduceMotion() { holds("S-11", SchedulerScenarios.s11(.all)) }
    @Test func S_11_negativeControl() { control("S-11", SchedulerScenarios.s11, removing: [("reduceMotion", .reduceMotion)]) }

    @Test("S-12 settings changed mid-motion take effect at the next frame; walk off sends Clawd home")
    func S_12_settingsTakeEffectAtTheNextFrame() { holds("S-12", SchedulerScenarios.s12(.all)) }
    @Test func S_12_negativeControl() {
        control("S-12", SchedulerScenarios.s12, removing: [("settingExclude", .settingExclude), ("settingMotion", .settingMotion), ("settingWalk", .settingWalk),
                                                            ("settingHide", .settingHide), ("bubbleOff", .bubbleOff), ("settingLookPin", .settingLookPin)])
    }

    @Test("S-13 a bubble shows from a dictation's first scene until at most 2.0 s after its last scene starts; never with bubble off, hidden or quiet")
    func S_13_bubbleTiming() { holds("S-13", SchedulerScenarios.s13(.all)) }
    @Test func S_13_negativeControl() {
        control("S-13", SchedulerScenarios.s13, removing: [("bubbleTimingCap", .bubbleTimingCap), ("bubbleOff", .bubbleOff), ("bubbleQuietHidden", .bubbleQuietHidden)])
    }
}
