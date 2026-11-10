import Testing
import Foundation
import CoreGraphics
@testable import ClawdCore

// A step walk is sized to whole step cycles, so the leg ends on frame 0 of the walk, which is the rest picture: no pop on arrival.

@Suite("WalkSizing: a step walk ends on the rest picture")
struct WalkSizing {
    private struct Plan { var look: String; var run: WalkRun; var nominal: Double; var home: Double; var width: Double; var scale: Double }

    private func plans(count: Int) -> (plans: [Plan], attempts: Int) {
        let looks = ["plain", "helmet", "sunglasses", "headphones", "coffee", "shiny"]
        let strides: [Double] = [40 * 2.3333 / 4, 30 * 2.3333 / 4, 25 * 2.3333 / 4, 50 * 2.3333 / 4]
        var out: [Plan] = []
        var attempts = 0
        var seed: UInt64 = 1
        while out.count < count, attempts < count * 3 {
            let look = looks[attempts % looks.count]
            let scale = attempts % 5 == 4 ? 1.5 : 1.0
            let home = 150 + Double((attempts * 97) % 1000)
            var settings = SchedulerSettings(); settings.motion = .lively; settings.lookPin = look
            let wall = 1_800_000_000.0
            let rig = SchedulerRig(catalog: SchedulerFixture.catalog(walkStride: strides[attempts % strides.count]), settings: settings,
                                   geometry: SchedulerFixture.geometry(scale: scale, homeX: home), seed: seed,
                                   persisted: SchedulerPersisted(look: look, lookSince: wall, lookUsed: [look]), startWall: wall)
            let dice = SeededRandom(seed: seed &* 7919 &+ 13)
            rig.scheduler.random = { dice.unit() }
            seed += 1; attempts += 1
            guard let run = rig.scheduler.planWalk(at: rig.now), !run.glide, run.stepMotionID != nil else { continue }
            let stride = strides[(attempts - 1) % strides.count]
            let nominal = stride * PetCatalog.pointsPerUnit / run.cycle * scale
            out.append(Plan(look: look, run: run, nominal: nominal, home: home, width: rig.scheduler.geometry.width, scale: scale))
        }
        return (out, attempts)
    }

    @Test func WalkSizing_everyPlannedLegIsAWholeNumberOfStepCyclesWithinTheAllowedSpeedAndRange() {
        let (all, attempts) = plans(count: 500)
        #expect(all.count >= 450, "most attempts plan a walk: \(all.count) of \(attempts)")
        var bySpeed = 0
        for p in all {
            let distance = abs(p.run.targetX - p.home)
            let cycles = distance / (p.run.speed * p.run.cycle)
            #expect(abs(cycles - cycles.rounded()) < 1e-6 && cycles.rounded() >= 1, "\(p.look): \(cycles) cycles, so the last frame is not frame 0 or the last of a cycle")
            let ratio = p.run.speed / p.nominal
            #expect(ratio >= 0.85 - 1e-9 && ratio <= 1.15 + 1e-9, "\(p.look): speed changed by \(ratio)")
            #expect(p.run.speed / p.scale >= PetScheduler.walkSpeedRange.lowerBound - 1e-9 && p.run.speed / p.scale <= PetScheduler.walkSpeedRange.upperBound + 1e-9)
            #expect(distance >= PetScheduler.walkMinWidths * p.width - 1e-6 && distance <= PetScheduler.walkMaxWidths * p.width + 1e-6, "\(p.look): target \(distance / p.width) widths from home")
            if abs(ratio - 1) > 1e-9 { bySpeed += 1 }
        }
        #expect(bySpeed > 0, "the speed is what gets adjusted")
    }

    @Test func WalkSizing_whenNoWholeCycleFitsInsideFifteenPercentTheTargetMovesByAtMostHalfACycle() {
        // 100 pt/s-cycle of 2 s, so a cycle is 80 pt; 110 pt is 1.375 cycles: 1 cycle needs -27 %, 2 cycles +45 %.
        let sized = PetScheduler.sizedWalk(distance: 110, speed: 40, cycle: 2, limits: 0...Double.infinity, targetRange: (0, 1000))
        let cycles = sized.distance / (sized.speed * 2)
        #expect(abs(cycles - cycles.rounded()) < 1e-9)
        #expect(abs(sized.distance - 110) <= 40 + 1e-9, "at most half a cycle's distance: \(sized.distance - 110)")
        #expect(sized.speed / 40 >= 0.85 - 1e-9 && sized.speed / 40 <= 1.15 + 1e-9)
        // The span ends where it would have moved: the other rounding is taken, or nothing changes.
        let capped = PetScheduler.sizedWalk(distance: 110, speed: 40, cycle: 2, limits: 0...Double.infinity, targetRange: (100, 110))
        #expect(capped.distance >= 100 - 1e-9 && capped.distance <= 110 + 1e-9)
    }
}
