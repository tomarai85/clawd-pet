import Testing
import Foundation
import CoreGraphics
@testable import ClawdCore

// Amendment "the skateboard ride": the scheduler plans the ride of each stretch of a glide and hands it to the renderer inside the playback. The
// catalog here is the scheduler fixture plus the ride motion and the skateboard look's signature, so no art is needed; the pictures are in
// SkateRideStageTests.

private func lively(_ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
    var s = SchedulerSettings(); s.motion = .lively; s.lookPin = "skateboard"; edit(&s); return s
}

enum RideFixture {
    /// The fixture catalog; with `ride` it has the motion D14-ride (use `ride`, 39 sprite frames and the 2 of the tail bridge) and the skateboard look names it as its signature.
    static func catalog(ride: Bool = true) -> PetCatalog {
        let base = SchedulerFixture.catalog()
        guard ride else { return base }
        var motions = base.motions
        motions.append(CatalogMotion(id: GlideRide.motionID, board: "D14", uses: [.ride], frameCount: GlideRide.frameCount, duration: 3.4167,
                                     stage: StageExtent(right: 0.5, down: 3), compatibleLooks: ["plain", "skateboard"]))
        let looks = base.looks.map { $0.id == "skateboard" ? CatalogLook(id: "skateboard", board: "D14", classes: ["under-feet"], signature: [GlideRide.motionID]) : $0 }
        return PetCatalog(motions: motions, looks: looks)
    }
}

/// A random source the test steers: the queued values first, then `fallback` for every draw.
final class Dice {
    private var queue: [Double]
    let fallback: Double
    private(set) var draws = 0
    init(_ queue: [Double] = [], fallback: Double) { self.queue = queue; self.fallback = fallback }
    func next() -> Double { draws += 1; return queue.isEmpty ? fallback : queue.removeFirst() }
}

/// What one look at the scheduler showed.
struct Shot {
    var t: TimeInterval
    var offset: Double
    var playback: MotionPlayback?
    var visibility: PetVisibility
    var dragging: Bool
    var look: String
    /// The motion frame the renderer would draw: the ride's frame at the seconds walked since the stretch began.
    var ride: Int? {
        guard let p = playback, p.source == .glide, let r = p.ride else { return nil }
        return r.frame(at: t - p.startedAt)
    }
    var gliding: Bool { playback?.source == .glide }
}

extension SchedulerRig {
    func shot() -> Shot {
        let f = frame
        return Shot(t: now, offset: f.walkOffset, playback: f.playback, visibility: f.visibility, dragging: f.dragging, look: f.displayedLook)
    }
}

/// The skateboard look worn from the start, a steered random source, and the first walk started.
final class RideRig {
    let rig: SchedulerRig
    let dice: Dice
    private(set) var dx = 0.0
    private(set) var t0 = 0.0
    /// The first leg as the scheduler planned it: its speed may differ from the nominal one by at most 10 % (the stop sits on a cruise-cycle boundary).
    private var planned: (travel: TimeInterval, speed: Double)?
    var scheduler: PetScheduler { rig.scheduler }
    var speed: Double { PetScheduler.glideSpeedAtSizeOne * rig.scheduler.geometry.scale }
    /// The speed the first leg was planned at (within 10 % of `speed`).
    var legSpeed: Double { planned?.speed ?? speed }

    init(homeX: Double = 576, homeY: Double = 100, scale: Double = 1, ride: Bool = true, seed: UInt64 = 11, dice: Dice,
         settings: SchedulerSettings? = nil, persisted: SchedulerPersisted? = nil) {
        let wall = 1_800_000_000.0
        rig = SchedulerRig(catalog: RideFixture.catalog(ride: ride), settings: settings ?? lively(),
                           geometry: SchedulerFixture.geometry(scale: scale, homeX: homeX, homeY: homeY), seed: seed,
                           persisted: persisted ?? SchedulerPersisted(look: "skateboard", lookSince: wall, lookUsed: ["skateboard"]), startWall: wall)
        self.dice = dice
        rig.scheduler.random = { dice.next() }
    }

    /// Leftward and as far as the keep-out band and the screen allow, from home x 576: 240 pt, 6 s.
    static func leftward(trick: Bool = false, homeX: Double = 576) -> RideRig { RideRig(homeX: homeX, dice: Dice([0.0, 0.0], fallback: trick ? 0.0 : 0.99)) }
    /// Rightward and as far as allowed, from home x 100.
    static func rightward(trick: Bool = false) -> RideRig { RideRig(homeX: 100, dice: Dice([0.0, 0.99], fallback: trick ? 0.0 : 0.99)) }

    /// Runs to the start of the first walk. False when none starts within `limit`.
    @discardableResult
    func begin(within limit: TimeInterval = 3600) -> Bool {
        let before = rig.events.count
        guard rig.run(upTo: limit, until: { rig.eventsSince(before).contains { isWalkStart($0.event) } }) else { return false }
        dx = rig.eventsSince(before).compactMap { e -> Double? in if case .walkStart(let d) = e.event { return d } else { return nil } }.first ?? 0
        t0 = rig.now
        if case .walk(let w) = scheduler.activity { planned = (w.arrival - w.since, w.speed) }
        return true
    }
    var travel: TimeInterval { planned?.travel ?? abs(dx) / legSpeed }
    var arrival: TimeInterval { t0 + travel }

    /// Looks every 1/30 s until `condition` holds or `limit` passes.
    func watch(_ limit: TimeInterval, until condition: (Shot) -> Bool = { _ in false }) -> [Shot] {
        var shots = [rig.shot()]
        let end = rig.now + limit
        while rig.now < end - 1e-9, !condition(shots[shots.count - 1]) {
            rig.advance(1.0 / 30)
            shots.append(rig.shot())
        }
        return shots
    }
    func advance(_ span: TimeInterval) { rig.advance(span) }
    var walkEnded: Bool { rig.events.contains { if case .walkEnd = $0.event { return true } else { return false } } }
}

/// Separate stretches of gliding in a list of shots: a new one begins after any shot that is not gliding.
func legs(_ shots: [Shot]) -> [[Shot]] {
    var out: [[Shot]] = []
    var inside = false
    for shot in shots {
        if shot.gliding { if inside { out[out.count - 1].append(shot) } else { out.append([shot]); inside = true } } else { inside = false }
    }
    return out
}

/// The frames of a leg with consecutive repeats dropped.
func distinct(_ frames: [Int]) -> [Int] { frames.enumerated().filter { $0.offset == 0 || frames[$0.offset - 1] != $0.element }.map(\.element) }

@Suite("SkateRide: the scheduler plays the ride", .serialized)
struct SkateRideScheduler {
    // MARK: the stop on a cruise-cycle boundary

    @Test func SkateRide_aLegChangesItsSpeedByAtMostTenPercentSoTheBoardArrivesAtTheTargetWhenStopBegins() throws {
        for homeX in [100.0, 180.0, 260.0, 340.0, 420.0, 500.0, 576.0] {
            let walk = RideRig(homeX: homeX, dice: Dice([0.0, 0.5], fallback: 0.99))
            guard walk.begin() else { continue }
            guard case .walk(let w) = walk.scheduler.activity, let ride = w.ride else { Issue.record("no ride at \(homeX)"); continue }
            let ratio = w.speed / w.nominalSpeed
            #expect(ratio >= 0.9 - 1e-9 && ratio <= 1.1 + 1e-9, "speed ratio \(ratio) at home \(homeX)")
            #expect(abs(w.speed * ride.travel - abs(w.goal - w.x)) < 1e-6, "the ride's travel is the leg's time at the speed in force")
            #expect(abs(w.arrival - (w.since + ride.travel)) < 1e-6)
            #expect(walk.rig.run(upTo: 60) { if case .walk(let now) = walk.scheduler.activity { return now.phase == .pause } else { return false } })
            if case .walk(let paused) = walk.scheduler.activity { #expect(abs(paused.x - paused.targetX) < 1e-6, "the board ends at the target") }
        }
    }

    // MARK: a pause end handled late

    @Test func SkateRide_aPauseEndHandledLateStartsTheNextLegOnItsFirstFrameNotAheadOfIt() throws {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        let reachedPause = walk.rig.run(upTo: 60) { if case .walk(let w) = walk.scheduler.activity { return w.phase == .pause } else { return false } }
        #expect(reachedPause)
        guard case .walk(let paused) = walk.scheduler.activity else { Issue.record("no walk"); return }
        let planned = paused.pauseEnd
        // The host's timer wakes 0.8 s after the planned end of the pause.
        walk.rig.clock.advance(planned + 0.8 - walk.rig.clock.now)
        walk.scheduler.refresh()
        guard case .walk(let back) = walk.scheduler.activity else { Issue.record("no walk after the pause"); return }
        #expect(back.phase == .back)
        #expect(back.since >= planned + 0.8 - PetScheduler.catchUpAfterLateWake - 1e-9 && back.since <= planned + 0.8, "the leg begins at most one frame before now: \(back.since - planned)")
        let shot = walk.rig.shot()
        #expect(shot.ride == 0, "the first drawn frame of the return ride is frame 0, not frame \(shot.ride ?? -1)")
        // On time is unchanged: the leg begins at the planned instant.
        let ontime = RideRig.rightward()
        #expect(ontime.begin())
        #expect(ontime.rig.run(upTo: 60) { if case .walk(let w) = ontime.scheduler.activity { return w.phase == .back } else { return false } })
        if case .walk(let w) = ontime.scheduler.activity { #expect(abs(w.since - ontime.rig.now) < 1e-6) }
    }

    // MARK: the whole walk

    @Test func SkateRide_everyLegOfAWalkPlaysTheRideFromStartToStopAndEndsOnTheRestPicture() throws {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        let shots = walk.watch(60) { _ in walk.walkEnded }
        let ridden = legs(shots)
        #expect(ridden.count == 2, "an outbound leg and a return leg: \(ridden.count)")
        for (n, leg) in ridden.enumerated() {
            let frames = leg.compactMap(\.ride)
            #expect(Array(frames.prefix(1)) == [0], "leg \(n) begins on the first start frame: \(frames.prefix(3))")
            #expect(Array(distinct(frames).prefix(8)) == Array(0..<8), "leg \(n): start plays once, in order")
            #expect(Array(distinct(frames).suffix(GlideRide.stop.count)) == Array(GlideRide.stop), "leg \(n): the last frames are stop (the crouch and its rise), in order")
            var startRuns = 0, inside = false
            for f in frames { let now = GlideRide.start.contains(f); if now && !inside { startRuns += 1 }; inside = now }
            #expect(startRuns == 1, "leg \(n): start plays once")
            let length = (leg.last!.t - leg.first!.t)
            #expect(abs(length - walk.travel) < 0.08, "leg \(n) takes \(length) s for \(walk.travel) s of travel")
        }
        #expect(ridden[0].allSatisfy { $0.playback?.mirrored == false } && ridden[1].allSatisfy { $0.playback?.mirrored == true }, "rightward out, leftward back")
        let rest = try #require(shots.last)
        #expect(!rest.gliding && rest.offset == 0, "after the return the rest picture is at home")
    }

    @Test func SkateRide_aLeftwardLegIsMirroredAndTheReturnIsNot() {
        let walk = RideRig.leftward()
        #expect(walk.begin() && walk.dx < 0)
        let ridden = legs(walk.watch(60) { _ in walk.walkEnded })
        #expect(ridden.count == 2)
        #expect(ridden[0].allSatisfy { $0.playback?.mirrored == true } && ridden[1].allSatisfy { $0.playback?.mirrored == false })
    }

    @Test func SkateRide_theLastFiveTwelfthsBeforeArrivalPlayStopInOrder() throws {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        let shots = walk.watch(walk.travel + 0.5)
        let ending = shots.filter { $0.gliding && $0.t >= walk.arrival - GlideRide.stopDuration + 1e-6 }
        let frames = distinct(ending.compactMap(\.ride))
        #expect(frames == Array(GlideRide.stop), "playback history of the last \(GlideRide.stopDuration) s before arrival: \(frames)")
        let before = shots.filter { $0.gliding && $0.t < walk.arrival - GlideRide.stopDuration - 1e-6 }.compactMap(\.ride)
        #expect(!before.contains { GlideRide.stop.contains($0) }, "and no stop frame before that")
        // Arrival: the picture is the rest picture again (no ride on it).
        let after = try #require(shots.last { $0.t >= walk.arrival + 1e-6 })
        #expect(!after.gliding)
    }

    @Test func SkateRide_thePositionKeepsMovingAtTodaysSpeedThroughEverySegment() {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        for shot in walk.watch(walk.travel) where shot.gliding {
            let want = min(abs(walk.dx), walk.legSpeed * (shot.t - walk.t0))
            #expect(abs(shot.offset - want * (walk.dx < 0 ? -1 : 1)) < 0.5, "at \(shot.t - walk.t0) s: \(shot.offset), want \(want)")
        }
        #expect(walk.speed == 40 && abs(walk.legSpeed / walk.speed - 1) <= GlideRide.speedChange + 1e-9, "today's speed, changed by at most the stop's snap to a cruise boundary")
    }

    @Test func SkateRide_atMostOneTrickPerLegEvenWhenTheSeamWouldChooseItAtEveryBoundary() {
        let walk = RideRig.leftward(trick: true)
        #expect(walk.begin())
        let ridden = legs(walk.watch(60) { _ in walk.walkEnded })
        #expect(ridden.count == 2)
        for leg in ridden {
            let frames = leg.compactMap(\.ride)
            var runs = 0, inside = false
            for f in frames { let now = GlideRide.trick.contains(f); if now && !inside { runs += 1 }; inside = now }
            #expect(runs == 1, "exactly one trick in a leg of \(walk.travel) s: \(runs)")
        }
    }

    @Test func SkateRide_eachLegBeginsItsOwnRideAndTheReturnIsNotAResumedOne() throws {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        let ridden = legs(walk.watch(60) { _ in walk.walkEnded })
        #expect(ridden.count == 2)
        for leg in ridden { #expect(leg.first?.playback?.ride?.playsStart == true) }
    }

    // MARK: the planner (R3-1)

    private func walkTargets(_ walk: RideRig, count: Int = 3, within: TimeInterval = 3 * 3600) -> [Double] {
        SchedulerScenarios.observeWalks(walk.rig, count: count, within: within).map(\.dx)
    }

    @Test func SkateRide_aWalkIsPlannedOnlyWhereTheWholePathHasTheRidesMargin() {
        let margin = PetScheduler.rideExtent
        func rig(homeX: Double, homeY: Double = 100, ride: Bool = true) -> RideRig {
            RideRig(homeX: homeX, homeY: homeY, ride: ride, seed: 3, dice: Dice(fallback: 0.5))
        }
        func walks(_ r: RideRig) -> [Double] {
            r.rig.scheduler.random = SeededRandom(seed: 5).callAsFunction
            return walkTargets(r)
        }
        // Left edge: half a unit (2 pt) of room at home is needed.
        #expect(walks(rig(homeX: 1.5)).isEmpty, "home 0.5 pt too close to the left edge: Clawd stays")
        let leftOK = rig(homeX: 2)
        let leftWalks = walks(leftOK)
        #expect(!leftWalks.isEmpty, "exactly the margin is enough")
        for dx in leftWalks {
            let target = 2 + dx
            let rect = leftOK.scheduler.geometry.stageRect(margin, originX: target)
            #expect(rect.minX >= 0 && rect.maxX <= 1440, "target \(target) has the margin on both sides")
        }
        #expect(leftOK.scheduler.geometry.homeOrigin.x == 2, "home is never moved to make room")
        // Right edge (home right of the keep-out band): 2 pt on the right of the 48 pt canvas.
        #expect(walks(rig(homeX: 1390.5)).isEmpty, "home 0.5 pt too close to the right edge")
        let rightOK = rig(homeX: 1390)
        let rightWalks = walks(rightOK)
        #expect(!rightWalks.isEmpty)
        for dx in rightWalks {
            let rect = rightOK.scheduler.geometry.stageRect(margin, originX: 1390 + dx)
            #expect(rect.minX >= 0 && rect.maxX <= 1440)
        }
        // Above: the ride reaches 2.5 units (10 pt) over the canvas; the visible frame ends at y 870.
        #expect(walks(rig(homeX: 576, homeY: 812.5)).isEmpty, "10 pt of room above the canvas is needed all along the way")
        #expect(!walks(rig(homeX: 576, homeY: 812)).isEmpty)
        // Without the ride in the art a glide needs the margins it always did.
        #expect(!walks(rig(homeX: 1.5, ride: false)).isEmpty, "a glide with no ride keeps today's planning")
    }

    // MARK: stalls, turns and sends home (R4-2)

    @Test func SkateRide_aPointerStallHoldsTheCurrentRideFrameAndItsReleaseResumesTheRide() throws {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        walk.advance(1.2)
        let moving = walk.rig.shot()
        let atStall = try #require(moving.ride)
        #expect(!GlideRide.stop.contains(atStall))
        let target = 100 + walk.dx
        walk.scheduler.pointerMoved(CGPoint(x: target + 10, y: 110))
        let held = walk.rig.shot()
        #expect(held.gliding && held.playback?.ride?.held == atStall, "the stalled picture holds frame \(atStall): \(String(describing: held.playback?.ride?.held))")
        #expect(held.playback?.mirrored == false)
        let standing = walk.watch(2)
        #expect(standing.allSatisfy { $0.gliding && $0.ride == atStall && $0.offset == held.offset }, "the frame and the place stay while the pointer is in the way")
        // The pointer leaves: a stall is no re-timing, so the same ride goes on from the frame it holds (R4-2 as corrected).
        walk.scheduler.pointerMoved(CGPoint(x: 700, y: 600))
        let freed = walk.rig.shot()
        let ride = try #require(freed.playback?.ride)
        #expect(ride.held == nil && ride.playsStart, "the plan is the same one: start was played")
        #expect(abs(ride.travel - walk.travel) < 1e-6, "the stretch's whole travel time: \(ride.travel)")
        #expect(freed.ride == atStall, "the ride goes on at the held frame")
    }

    @Test func SkateRide_aStalledLeftwardGlideHoldsItsFrameMirrored() throws {
        let walk = RideRig.leftward()
        #expect(walk.begin() && walk.dx < 0)
        walk.advance(1.2)
        let atStall = try #require(walk.rig.shot().ride)
        walk.scheduler.pointerMoved(CGPoint(x: 576 + walk.dx - 10, y: 110))
        let held = walk.rig.shot()
        #expect(held.gliding && held.playback?.ride?.held == atStall && held.playback?.mirrored == true, "the held frame faces the way Clawd goes")
    }

    @Test func SkateRide_aStallInTheMiddleOfTheTrickContinuesTheSamePlanAfterTheRelease() throws {
        let walk = RideRig.rightward(trick: true)
        #expect(walk.begin())
        walk.advance(1.5)                                              // start 8/12 s, cruiseA 8/12 s: the trick is on (frames 16..21)
        let atStall = try #require(walk.rig.shot().ride)
        #expect(GlideRide.trick.contains(atStall), "the stall catches the board in the air: \(atStall)")
        walk.scheduler.pointerMoved(CGPoint(x: 100 + walk.dx + 10, y: 110))
        #expect(walk.rig.shot().playback?.ride?.held == atStall)
        walk.advance(2)
        walk.scheduler.pointerMoved(CGPoint(x: 700, y: 600))
        let freed = walk.rig.shot()
        #expect(freed.ride == atStall, "the release goes on from the held frame, not from a replanned one: \(String(describing: freed.ride))")
        let after = distinct((legs(walk.watch(walk.travel)).first ?? []).compactMap(\.ride))      // the rest of this leg only
        let landing = Array(atStall...GlideRide.trick.upperBound - 1)
        #expect(Array(after.prefix(landing.count + 1)) == landing + [GlideRide.cruiseB.lowerBound], "the trick finishes and lands: \(after.prefix(12))")
        #expect(Array(after.suffix(GlideRide.stop.count)) == Array(GlideRide.stop), "the stop deadline is where it was")
    }

    @Test func SkateRide_aStallThatOutlastsAShortReturnStillShowsTheHeldFrame() throws {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        walk.advance(0.1)
        let atStall = try #require(walk.rig.shot().ride)
        walk.scheduler.pointerMoved(CGPoint(x: 130, y: 110))           // near the way out and the way back alike
        #expect(walk.rig.shot().playback?.ride?.held == atStall)
        walk.advance(5.05)                                             // the patience turn: a return of 0.1 s of travel, under a quarter second
        let turned = walk.rig.shot()
        #expect(turned.playback?.mirrored == true)
        #expect(turned.gliding && turned.ride == atStall, "still stalled: the held frame stays, not the rest picture: \(String(describing: turned.playback))")
    }

    @Test func SkateRide_theDeadlineStopsTheRestOfTheWayAfterAStallToo() throws {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        walk.advance(1.2)
        walk.scheduler.pointerMoved(CGPoint(x: 100 + walk.dx + 10, y: 110))
        walk.advance(1)
        walk.scheduler.pointerMoved(CGPoint(x: 700, y: 600))
        let ride = try #require(walk.rig.shot().playback?.ride)
        let remaining = ride.travel - 1.2                               // the seconds still to walk: the stall did not advance the ride's clock
        let freedAt = walk.rig.now
        let ending = (legs(walk.watch(remaining + 0.2)).first ?? []).filter { $0.t >= freedAt + remaining - GlideRide.stopDuration + 1e-6 }
        #expect(distinct(ending.compactMap(\.ride)) == Array(GlideRide.stop))
    }

    @Test func SkateRide_thePatienceTurnStartsTheReturnAsAResumedRideNotWithTheOutboundLegsState() throws {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        walk.advance(1.2)
        walk.scheduler.pointerMoved(CGPoint(x: 100 + walk.dx + 10, y: 110))
        let stalledAt = walk.rig.shot().offset
        walk.advance(5.05)
        let turned = walk.rig.shot()
        let ride = try #require(turned.playback?.ride)
        #expect(turned.playback?.mirrored == true, "Clawd turned and heads home")
        #expect(ride.held == nil && !ride.playsStart && ride.tricks.isEmpty)
        #expect(abs(ride.travel - stalledAt / 40) < 1e-6, "the way home from where Clawd stood: \(ride.travel) s for \(stalledAt) pt")
    }

    @Test func SkateRide_walkOffSendsHomeAsAResumedRide() throws {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        walk.advance(1.5)
        let at = walk.rig.shot().offset
        var off = walk.scheduler.settings; off.walk = false
        walk.scheduler.update(settings: off)
        let shot = walk.rig.shot()
        let ride = try #require(shot.playback?.ride)
        #expect(shot.playback?.mirrored == true && !ride.playsStart && ride.tricks.isEmpty)
        #expect(abs(ride.travel - at / 40) < 1e-6)
    }

    // MARK: reactions and cuts (R3-4)

    @Test func SkateRide_aClickReplacesTheRideAtOnceWithNoStopAndTheReturnIsAResumedRide() throws {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        walk.advance(1.5)
        let at = walk.rig.shot().offset
        walk.scheduler.click()
        let reacting = walk.rig.shot()
        #expect(!reacting.gliding && reacting.playback?.use == "touch", "the reaction replaces the ride frame at once")
        let during = walk.watch(30) { $0.gliding }
        #expect(during.dropLast().allSatisfy { !$0.gliding } && during.last?.gliding == true, "the return follows the reaction")
        let ride = try #require(during.last?.playback?.ride)
        #expect(!ride.playsStart && ride.tricks.isEmpty && ride.held == nil)
        #expect(abs(ride.travel - at / 40) < 1e-6, "from where Clawd stood: \(ride.travel) s for \(at) pt")
        #expect(during.last?.playback?.mirrored == true)
        #expect(during.last?.ride == GlideRide.cruiseFirst)
    }

    @Test func SkateRide_aDictationStopsTheRideWhereItStandsAndTheWalkHomeIsAResumedRide() throws {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        walk.advance(1.5)
        let at = walk.rig.shot().offset
        walk.rig.start()
        let shot = walk.rig.shot()
        #expect(!shot.gliding, "the dictation's picture replaces the ride")
        walk.rig.advance(1); walk.rig.complete(); walk.advance(1); walk.rig.ack(); walk.advance(SceneMachine.sentDuration + 0.05)
        let back = walk.watch(30) { $0.gliding }
        let ride = try #require(back.last?.playback?.ride)
        #expect(back.last?.gliding == true && !ride.playsStart && ride.tricks.isEmpty)
        #expect(abs(ride.travel - at / 40) < 1e-6)
    }

    @Test func SkateRide_aDragCutsTheWalkAtOnceWithNoStopAndNoReturn() throws {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        walk.advance(1.5)
        walk.scheduler.dragStarted()
        let shot = walk.rig.shot()
        #expect(shot.dragging && !shot.gliding, "the dangle pose follows: \(String(describing: shot.playback))")
        walk.scheduler.dragEnded()
        let later = walk.watch(40)
        #expect(!later.contains { $0.gliding }, "the walk does not go on after the drop")
        #expect(walk.walkEnded)
    }

    @Test func SkateRide_aQuietConditionEndsTheWalkAndNothingIsDrawn() {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        walk.advance(1.5)
        walk.scheduler.setQuiet(.screenLocked, active: true)
        let locked = walk.watch(20)
        #expect(locked.allSatisfy { $0.visibility != .visible && $0.playback == nil })
        walk.scheduler.setQuiet(.screenLocked, active: false)
        walk.advance(1)
        #expect(!walk.rig.shot().gliding && walk.rig.shot().offset == 0, "back at home, the walk is not taken up again")
    }

    @Test func SkateRide_hidingEndsTheWalkAndNothingIsDrawn() {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        walk.advance(1.5)
        var hidden = walk.scheduler.settings; hidden.hiddenUntil = -1
        walk.scheduler.update(settings: hidden)
        let shot = walk.rig.shot()
        #expect(shot.visibility == .hidden && shot.playback == nil)
        #expect(walk.watch(20).allSatisfy { $0.playback == nil })
    }

    @Test func SkateRide_aSizeChangeEndsTheWalkAndDrawsTheRestPictureAtTheNewHome() {
        let walk = RideRig.rightward()
        #expect(walk.begin())
        walk.advance(1.5)
        walk.scheduler.update(geometry: SchedulerFixture.geometry(scale: 2, homeX: 100))
        let shot = walk.rig.shot()
        #expect(!shot.gliding && shot.playback == nil && shot.offset == 0, "the rest picture at the new geometry's home")
        #expect(walk.walkEnded)
    }

    @Test func SkateRide_aLookChangeWaitsForTheWalkSoTheRideEndsWithStop() throws {
        // The look is due while Clawd rides: the change waits for rest and its gap (30 s), so the leg ends with stop first.
        let wall = 1_800_000_000.0
        func rig(due: Double?) -> RideRig {
            var s = lively(); s.lookPin = nil; s.lookEveryHours = 2
            let state = SchedulerPersisted(look: "skateboard", lookSince: wall, lookUsed: ["skateboard"], lookDueAt: due)
            return RideRig(homeX: 100, dice: Dice([0.0, 0.99], fallback: 0.99), settings: s, persisted: state)
        }
        let probe = rig(due: wall + 100_000)
        #expect(probe.begin())
        let walk = rig(due: wall + probe.t0 - probe.rig.started + 2.5)
        #expect(walk.begin())
        let shots = walk.watch(60) { _ in walk.walkEnded }
        let ridden = legs(shots)
        #expect(ridden.count == 2 && shots.allSatisfy { $0.look == "skateboard" }, "no look change during the walk")
        for leg in ridden { #expect(Array(distinct(leg.compactMap(\.ride)).suffix(GlideRide.stop.count)) == Array(GlideRide.stop)) }
        walk.advance(120)
        #expect(walk.rig.events.contains { if case .lookTransition = $0.event { return true } else { return false } }, "the due look change came after the walk")
    }

    // MARK: nothing else changes

    @Test func SkateRide_aGlideWithNoRideInTheArtDrawsTheRestPictureAsBefore() {
        let walk = RideRig(homeX: 100, ride: false, dice: Dice([0.0, 0.99], fallback: 0.99))
        #expect(walk.begin())
        let shots = walk.watch(60) { _ in walk.walkEnded }
        #expect(legs(shots).count == 2 && legs(shots).joined().allSatisfy { $0.playback?.ride == nil })
    }

    @Test func SkateRide_noRideTimerExistsWhileNoGlideRuns() {
        // Same seed, walking off: the ride changes nothing the scheduler wakes for, draws or logs.
        func run(ride: Bool) -> (Int, Int, [String]) {
            let walk = RideRig(ride: ride, seed: 21, dice: Dice(fallback: 0.5), settings: lively { $0.walk = false })
            walk.rig.scheduler.random = SeededRandom(seed: 9).callAsFunction
            walk.advance(3600)
            let wake = walk.scheduler.nextWake.map { $0 - walk.rig.now } ?? 99
            #expect(wake > 0.5, "the next wake at rest is not a frame interval away: \(wake)")
            return (walk.rig.renders, walk.rig.events.count, walk.rig.events.map { "\($0.t) \($0.event)" })
        }
        let with = run(ride: true), without = run(ride: false)
        #expect(with.0 == without.0 && with.1 == without.1 && with.2 == without.2, "renders \(with.0)/\(without.0), events \(with.1)/\(without.1)")
        #expect(with.1 > 10)
    }
}
