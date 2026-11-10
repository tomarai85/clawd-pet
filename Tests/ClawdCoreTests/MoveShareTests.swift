import Testing
import Foundation
import CoreGraphics
@testable import ClawdCore

// Amendment "moves as often as in-place motions": among the idle slots where a walk is possible, a walk starts in about half, and never three
// self-started in-place motions in a row while there is room. A slot where planWalk finds no room takes an in-place motion as it always did.

private func plainSettings() -> SchedulerSettings {
    var s = SchedulerSettings(); s.motion = .lively; s.lookPin = "plain"; return s
}

private enum Slot: Equatable { case walk, inPlace(String) }

/// The idle slots of a run on a virtual clock, in order: a walk start, or a self-started in-place motion (use `idle`).
private func slots(_ rig: SchedulerRig, count: Int) -> [Slot] {
    var seen = 0
    var out: [Slot] = []
    func collect() {
        while seen < rig.events.count {
            switch rig.events[seen].event {
            case .walkStart: out.append(.walk)
            case .motionStart(let id, let use) where use == "idle": out.append(.inPlace(id))
            default: break
            }
            seen += 1
        }
    }
    var guardSteps = 0
    while out.count < count, guardSteps < 20_000, !rig.runaway {
        rig.advance(60); collect(); guardSteps += 1
    }
    return Array(out.prefix(count))
}

private func roomyRig(seed: UInt64 = 3) -> SchedulerRig {
    let rig = SchedulerRig(settings: plainSettings(), seed: seed)
    rig.scheduler.random = { Double.random(in: 0..<1) }
    return rig
}

@Suite("MoveShare", .serialized)
struct MoveShare {
    @Test func MoveShare_withRoomAboutHalfOfTheIdleSlotsAreWalks() {
        let all = slots(roomyRig(), count: 4000)
        #expect(all.count == 4000)
        let share = Double(all.filter { $0 == .walk }.count) / Double(all.count)
        #expect(share >= 0.45 && share <= 0.58, "walk share \(share)")
    }

    @Test func MoveShare_whenPlanningFailsAboutAQuarterOfTheTimeTheShareStaysNearHalf() {
        let rig = roomyRig(seed: 12)
        let fails = SeededRandom(seed: 77)
        rig.scheduler.walkPlanFails = { fails.unit() < 0.28 }
        let all = slots(rig, count: 4000)
        #expect(all.count == 4000)
        let share = Double(all.filter { $0 == .walk }.count) / Double(all.count)
        #expect(share >= 0.44, "walk share \(share)")
    }

    @Test func MoveShare_withRoomNeverThreeInPlaceMotionsInARow() {
        let all = slots(roomyRig(seed: 8), count: 2000)
        var run = 0, longest = 0
        for s in all { if case .inPlace = s { run += 1; longest = max(longest, run) } else { run = 0 } }
        #expect(all.count == 2000)
        #expect(longest <= PetScheduler.inPlaceRunBeforeWalk, "longest in-place run \(longest)")
    }

    @Test func MoveShare_withNoRoomThereIsNoWalkAndTheInPlacePickIsTheOldOne() {
        // A visible frame 160 pt wide round home: planWalk finds no room at every slot.
        let narrow = PetGeometry(scale: 1, homeOrigin: CGPoint(x: 576, y: 100), displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                 visibleFrame: CGRect(x: 520, y: 80, width: 160, height: 790))
        let rig = SchedulerRig(settings: plainSettings(), geometry: narrow, seed: 5)
        #expect(rig.scheduler.planWalk(at: rig.now) == nil)
        let all = slots(rig, count: 30)
        #expect(!all.contains(.walk))
        let ids = all.compactMap { s -> String? in if case .inPlace(let id) = s { return id } else { return nil } }
        #expect(ids == MoveShare.frozenInPlacePicks, "\(ids)")
    }

    /// Recorded on the tree before this change (seed 5, the narrow frame): the in-place picks of the first 30 slots.
    static let frozenInPlacePicks: [String] = ["A16-meditating", "A9-dancing", "A22-notebook", "A8-excited", "A12-heart", "A14-lightbulb", "A7-swaying", "A2-looking", "A6-turning", "A10-breakdancing", "A26-juggling", "A19-coffee", "A27-hulahoop", "A4-waving", "A33-rose", "A20-laptop", "A1-thinking", "A3-jumping", "A25-spark", "A27-hulahoop", "A16-meditating", "A26-juggling", "A33-rose", "A9-dancing", "A7-swaying", "A6-turning", "A4-waving", "A22-notebook", "A25-spark", "A19-coffee"]
}
