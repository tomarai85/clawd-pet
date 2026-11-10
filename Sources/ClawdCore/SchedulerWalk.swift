import Foundation
import CoreGraphics

/// A walk along the bottom of the screen: out, a pause, and back (spec 6.2). Positions are canvas-origin x in global points.
struct WalkRun {
    enum Phase { case out, pause, back }
    var phase: Phase = .out
    var homeX: Double
    var targetX: Double
    /// Points per second at the current size. A skateboard stretch runs up to 10 % faster or slower than `nominalSpeed` so that its stop begins
    /// on a cruise-cycle boundary (restartRide).
    var speed: Double
    var nominalSpeed: Double = 0
    var glide: Bool
    var stepMotionID: String?
    var pauseMotionID: String?
    var cycle: TimeInterval
    /// Seconds before the cycle repeats (the rest picture and the step-off of the art); a leg is this plus whole cycles.
    var leadIn: TimeInterval = 0
    var pauseDuration: TimeInterval = 0
    /// Where Clawd stood at `since`.
    var x: Double
    var since: TimeInterval
    var moving = true
    var pauseEnd: TimeInterval = 0
    /// Standing still because the pointer is in the way.
    var waitingSince: TimeInterval?
    /// Seconds spent in the walk cycle before `since` (pauses, pointer waits and dictation time are not counted).
    var walked: TimeInterval = 0
    var dir: Double = 1
    /// A skateboard glide plays the ride (the art has it and the exclusions leave it on).
    var rideOn = false
    /// The ride of the stretch that began at `since` (the leg's start, or the last restart of the clock inside the leg). nil: the rest picture.
    var ride: GlideRide?

    var goal: Double { phase == .out ? targetX : homeX }
    var arrival: TimeInterval { since + abs(goal - x) / speed }
    func position(at t: TimeInterval) -> Double {
        guard moving else { return x }
        let travelled = speed * max(0, t - since)
        return goal >= x ? min(goal, x + travelled) : max(goal, x - travelled)
    }
    func walkedSeconds(at t: TimeInterval) -> TimeInterval { walked + (moving ? max(0, t - since) : 0) }
}

extension PetScheduler {
    // MARK: planning

    /// Settings and conditions that allow a walk at all (the 1/4 chance is drawn only when this holds).
    func walkIsPossibleInPrinciple() -> Bool {
        let walkOn = guards.contains(.settingWalk) ? settings.walk : true
        return walkOn && settings.motion != .off && !(reduceMotion && guards.contains(.reduceMotion))
    }

    func walkMotion(look: String) -> CatalogMotion? {
        catalog.motions.first { m in
            m.uses.contains(.walk) && m.mirrorOf == nil && !(guards.contains(.exclusion) && settings.excludes(m))
                && (!guards.contains(.compatibility) || catalog.isCompatible(m, with: look))
        }
    }

    /// The target is drawn uniformly over the places the walk may go: inside the visible frame of Clawd's display, outside the
    /// keep-out band and on the same side of it as home, between 1.5 and 5 Clawd widths from home (spec 6.2).
    /// nil when no walk is possible from here.
    func planWalk(at t: TimeInterval) -> WalkRun? {
        let look = lookForMotion
        let glide = catalog.look(id: look)?.glides ?? false
        var stage = StageExtent.none
        let rideOn = glide && rideAvailable(look: look)
        var stepID: String?
        var cycle = 0.0, leadIn = 0.0
        var speedAtOne = Self.glideSpeedAtSizeOne
        if !glide {
            guard let m = walkMotion(look: look), m.duration > 0 else { return nil }
            if let stride = m.strideUnits {
                speedAtOne = stride * PetCatalog.pointsPerUnit / m.duration
            } else if let declared = walkSpeedWhenStrideUndeclared {
                speedAtOne = declared
            } else {
                return nil      // the art says nothing about how far one cycle travels: no walk rather than sliding feet
            }
            if guards.contains(.walkSpeedRange), !Self.walkSpeedRange.contains(speedAtOne) { return nil }
            stage = m.stage; stepID = m.id; cycle = m.duration; leadIn = m.leadIn
        } else if rideOn {
            // The ride reaches half a unit beyond the canvas on the leading side (either side over the two legs) and two and a half units above it.
            stage = Self.rideExtent
        }
        let u = geometry.unit, width = geometry.width
        let visible = geometry.visibleFrame
        let homeX = Double(geometry.homeOrigin.x)
        let homeRect = geometry.stageRect(stage, originX: homeX)
        if guards.contains(.walkInsideFrame), !(homeRect.minY >= visible.minY && homeRect.maxY <= visible.maxY) { return nil }
        // The whole path of a ride, home included: the margin the target gets below applies at home too (the return leg ends there).
        if rideOn, guards.contains(.walkInsideFrame), !(homeRect.minX >= visible.minX && homeRect.maxX <= visible.maxX) { return nil }
        var lo = homeX - Self.walkMaxWidths * width, hi = homeX + Self.walkMaxWidths * width
        if guards.contains(.walkInsideFrame) {
            lo = max(lo, Double(visible.minX) + stage.left * u)
            hi = min(hi, Double(visible.maxX) - (width + stage.right * u))
        }
        if guards.contains(.walkKeepOut) {
            let bandCentre = (geometry.bandMin + geometry.bandMax) / 2
            let homeCentre = homeX + width / 2
            if homeCentre < bandCentre { hi = min(hi, geometry.bandMin - width - stage.right * u) }
            else if homeCentre > bandCentre { lo = max(lo, geometry.bandMax + stage.left * u) }
            else { return nil }
        }
        let nearest = Self.walkMinWidths * width
        var spans: [(Double, Double)] = []
        let leftHi = min(hi, homeX - nearest)
        if leftHi > lo { spans.append((lo, leftHi)) }
        let rightLo = max(lo, homeX + nearest)
        if hi > rightLo { spans.append((rightLo, hi)) }
        let total = spans.reduce(0) { $0 + ($1.1 - $1.0) }
        guard total > 1e-6 else { return nil }
        var draw = random() * total
        var target = spans[spans.count - 1].1
        for span in spans {
            let length = span.1 - span.0
            if draw < length { target = span.0 + draw; break }
            draw -= length
        }
        var speed = speedAtOne * geometry.scale
        if !glide, cycle > 0 {
            // The leg is its lead-in and a whole number of step cycles, so it ends where the art's own walk ends its stepping and goes back to
            // the rest picture. Both legs have this length and this speed.
            let allowed = spans.first { $0.0 <= target && target <= $0.1 } ?? (target, target)
            let limits = guards.contains(.walkSpeedRange) ? Self.walkSpeedRange.lowerBound * geometry.scale...Self.walkSpeedRange.upperBound * geometry.scale
                                                          : 0...Double.infinity
            let sized = Self.sizedWalk(distance: abs(target - homeX), speed: speed, cycle: cycle, leadIn: leadIn, limits: limits,
                                       targetRange: (min(abs(allowed.0 - homeX), abs(allowed.1 - homeX)), max(abs(allowed.0 - homeX), abs(allowed.1 - homeX))))
            speed = sized.speed
            target = homeX + (target >= homeX ? 1 : -1) * sized.distance
        }
        let pause = catalog.motions.first { $0.uses.contains(.walkPause) && eligible($0, look: look, pointerCheck: false) }
        var run = WalkRun(homeX: homeX, targetX: target, speed: speed, glide: glide, stepMotionID: stepID,
                          pauseMotionID: pause?.id, cycle: cycle, leadIn: leadIn, x: homeX, since: t)
        run.dir = target >= homeX ? 1 : -1
        run.nominalSpeed = speed
        run.rideOn = rideOn
        if pointerBlocks(run, atX: homeX) { return nil }
        return run
    }

    /// The most the walk speed may change to fit whole step cycles into a leg.
    static let walkSizingSpeedChange = 0.15

    /// A leg of `distance` at `speed` that plays `leadIn` seconds and then a step cycle of `cycle` seconds, sized to a whole number of cycles: the
    /// speed changes by at most `walkSizingSpeedChange` (and stays inside `limits`); when no whole number of cycles fits, the distance changes by
    /// at most half a cycle's distance and stays inside `targetRange` (the distances from home the walk may go to). Unchanged when neither is possible.
    static func sizedWalk(distance: Double, speed: Double, cycle: TimeInterval, leadIn: TimeInterval = 0, limits: ClosedRange<Double>,
                          targetRange: (Double, Double)) -> (distance: Double, speed: Double) {
        guard distance > 0, speed > 0, cycle > 0 else { return (distance, speed) }
        let lo = max(speed * (1 - walkSizingSpeedChange), limits.lowerBound), hi = min(speed * (1 + walkSizingSpeedChange), limits.upperBound)
        guard lo <= hi else { return (distance, speed) }
        let wanted = (distance / speed - leadIn) / cycle
        let counts = [wanted.rounded(), wanted.rounded(.down), wanted.rounded(.up), wanted.rounded() - 1, wanted.rounded() + 1]
            .map { Int(max(1, $0)) }.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
            .sorted { abs(Double($0) - wanted) < abs(Double($1) - wanted) }
        for n in counts {
            let v = distance / (leadIn + Double(n) * cycle)
            if v >= lo, v <= hi { return (distance, v) }
        }
        for n in counts {
            let v = min(hi, max(lo, distance / (leadIn + Double(n) * cycle)))
            let d = (leadIn + Double(n) * cycle) * v
            if abs(d - distance) <= speed * cycle / 2 + 1e-9, d >= targetRange.0 - 1e-9, d <= targetRange.1 + 1e-9 { return (d, v) }
        }
        return (distance, speed)
    }

    func startWalk(_ run: WalkRun, at t: TimeInterval) {
        var run = run
        restartRide(&run, resumed: false)
        activity = .walk(run)
        counters.walks += 1
        lastActivityStart = t
        emit(.walkStart(dx: run.targetX - run.homeX), at: t)
        dirty = true
        syncRest(at: t)
    }

    // MARK: the pointer

    /// The pointer is within one Clawd width of the path ahead (spec 6.2).
    func pointerBlocks(_ w: WalkRun, atX x: Double) -> Bool {
        guard guards.contains(.walkPointerStop), let p = pointer else { return false }
        let width = geometry.width
        let goal = w.goal
        let (x0, x1) = goal >= x ? (x, goal + 2 * width) : (goal - width, x + width)
        let y0 = Double(geometry.homeOrigin.y), height = PetCatalog.canvasUnits * geometry.unit
        return Double(p.x) >= x0 && Double(p.x) <= x1 && Double(p.y) >= y0 - width && Double(p.y) <= y0 + height + width
    }

    /// Faces the way it goes and moves, or stands and waits when the pointer is in the way.
    func tryMove(_ w: inout WalkRun, at t: TimeInterval) {
        if abs(w.goal - w.x) > 1e-9 { w.dir = w.goal >= w.x ? 1 : -1 }
        if pointerBlocks(w, atX: w.x) { w.moving = false; w.waitingSince = t }
        else { w.moving = true; w.waitingSince = nil }
    }

    func reevaluateWalkPointer(at t: TimeInterval) {
        guard case .walk(var w) = activity, w.phase != .pause else { return }
        let x = w.position(at: t)
        let blocked = pointerBlocks(w, atX: x)
        if w.moving && blocked {
            holdRide(&w, at: t)
            w.walked += max(0, t - w.since); w.x = x; w.since = t; w.moving = false; w.waitingSince = t
            activity = .walk(w); dirty = true
        } else if !w.moving && !blocked && w.waitingSince != nil {
            w.since = t; w.moving = true; w.waitingSince = nil
            releaseRide(&w)
            activity = .walk(w); dirty = true
        }
    }

    // MARK: the legs of a walk

    func walkArrived(at t: TimeInterval) {
        guard case .walk(var w) = activity, w.moving else { return }
        w.walked += max(0, t - w.since); w.x = w.goal; w.since = t; w.moving = false; w.ride = nil
        if w.phase == .out {
            w.phase = .pause
            w.pauseDuration = Self.walkPause.lowerBound + random() * (Self.walkPause.upperBound - Self.walkPause.lowerBound)
            w.pauseEnd = t + w.pauseDuration
            activity = .walk(w)
            dirty = true
        } else {
            finishWalk(w, at: t, snapHome: false)
            syncRest(at: t)
        }
    }

    /// The most a leg that starts late may catch up: just under one frame of the walk (83 ms), so its first drawn frame is still frame 0.
    static let catchUpAfterLateWake: TimeInterval = 0.08

    func walkPauseEnded(at t: TimeInterval) {
        guard case .walk(var w) = activity, w.phase == .pause else { return }
        // Handled late by L (the host's timer was held back): the leg begins at the planned time plus L less one frame, so the picture catches up
        // at most one frame, never skips the first frames of the ride, and the way still to go is the whole leg.
        w.phase = .back; w.since = t + max(0, max(0, clock.now - t) - Self.catchUpAfterLateWake)
        tryMove(&w, at: t)
        restartRide(&w, resumed: false)
        activity = .walk(w)
        dirty = true
    }

    /// The pointer stayed in the way for 5 s: on the way out Clawd turns and heads home; on the way home it looks again, goes on when the
    /// pointer has left and otherwise waits another 5 s. While Clawd stands there is no tick of the renderer, so the only ticks are the
    /// blink (3 to 7 s apart) and this deadline: a wait on either leg ends within 5 s of the pointer leaving.
    func walkPatienceRanOut(at t: TimeInterval) {
        guard case .walk(var w) = activity, w.phase != .pause, w.waitingSince != nil else { return }
        if w.phase == .back {
            if pointerBlocks(w, atX: w.x) { w.waitingSince = max(t, clock.now) }      // looked at now: the next look is 5 s from now, whatever a late wake missed
            else { w.since = t; w.moving = true; w.waitingSince = nil; releaseRide(&w); dirty = true }
            activity = .walk(w)
            return
        }
        if guards.contains(.walkPatienceRechecks), !pointerBlocks(w, atX: w.x) {
            // "Heads home if it is still there after 5 s": it is not any more (the pointer was last looked at before this deadline and
            // has left), so Clawd goes on out instead of turning back.
            w.since = t; w.moving = true; w.waitingSince = nil
            releaseRide(&w)
            activity = .walk(w)
            dirty = true
            return
        }
        w.phase = .back; w.since = t; w.waitingSince = nil
        tryMove(&w, at: t)
        restartRide(&w, resumed: true)
        activity = .walk(w)
        dirty = true
    }

    /// The walk is over. `snapHome` marks the cuts (hide, quiet, geometry change, Reduce Motion) that put Clawd back at home at once.
    func finishWalk(_ w: WalkRun, at t: TimeInterval, snapHome: Bool) {
        emit(.walkEnd(walkedSeconds: w.walkedSeconds(at: t)), at: t)
        lastSelfEnd = t
        if case .walk = activity { activity = .rest }
        pendingWalk = nil
        dirty = true
    }

    /// A dictation or a click stops the walk where it stands; Clawd walks home once nothing else is going on.
    func freezeWalk(_ w: WalkRun, at t: TimeInterval) {
        var frozen = w
        frozen.walked = w.walkedSeconds(at: t)
        frozen.x = w.position(at: t)
        frozen.moving = false; frozen.waitingSince = nil; frozen.phase = .back; frozen.since = t
        activity = .rest
        if abs(frozen.x - frozen.homeX) < 0.01 { finishWalk(frozen, at: t, snapHome: false) }
        else { pendingWalk = frozen }
        dirty = true
    }

    func resumeWalkHome(at t: TimeInterval) {
        guard var w = pendingWalk else { return }
        pendingWalk = nil
        guard guards.contains(.walkReturnsHome) else { finishWalk(w, at: t, snapHome: true); return }
        w.since = t
        if guards.contains(.pointerOnWalkTicks) { readPointer() }      // the walk home is part of the walk
        tryMove(&w, at: t)
        restartRide(&w, resumed: true)
        activity = .walk(w)
        dirty = true
    }

    /// `walk off`, `motion off`, an excluded walk motion: Clawd goes straight home (at its walking speed), no new walk starts.
    func sendHome(at t: TimeInterval) {
        guard case .walk(var w) = activity else { return }
        w.x = w.position(at: t)
        w.walked = w.walkedSeconds(at: t)
        w.since = t; w.phase = .back; w.waitingSince = nil
        if abs(w.x - w.homeX) < 0.01 {
            finishWalk(w, at: t, snapHome: false)
            syncRest(at: t)
        } else {
            tryMove(&w, at: t)
            restartRide(&w, resumed: true)
            activity = .walk(w)
        }
        dirty = true
    }

    // MARK: the ride of a glide

    /// The ride's extent beyond the canvas, in units: half a unit on either side and two and a half above (R3-1: planned for the whole path).
    static let rideExtent = StageExtent(left: 0.5, right: 0.5, up: 2.5)

    /// The worn skateboard look plays the ride when the art has it whole and the exclusions leave it on.
    func rideAvailable(look: String) -> Bool {
        guard let l = catalog.look(id: look), l.glides, l.signature.contains(GlideRide.motionID),
              let m = catalog.motion(id: GlideRide.motionID), m.uses.contains(.ride), m.frameCount == GlideRide.frameCount else { return false }
        return !(guards.contains(.exclusion) && settings.excludes(m))
    }

    /// A stretch of the walk begins at `since`: the ride for the way left to go. A leg's own start plays the whole ride; every restart of the clock
    /// inside a leg that re-times the way left (the patience turn, a walk home, a dictation freeze, a click) makes it a resumed ride; a pointer stall is no re-timing (see releaseRide). While the walk is not
    /// moving the frame held at the stall stays on screen.
    func restartRide(_ w: inout WalkRun, resumed: Bool) {
        guard w.rideOn else { w.ride = nil; return }
        let held = w.ride?.held
        let distance = abs(w.goal - w.x)
        if w.nominalSpeed <= 0 { w.nominalSpeed = w.speed }
        var ride = GlideRide.plan(travel: distance / w.nominalSpeed, resumed: resumed, random: random)
        w.speed = w.nominalSpeed
        if let travel = ride?.travel, travel > 0, distance > 0 { w.speed = distance / travel }
        if !w.moving, let held {
            // Standing, the frame on screen stays whatever the next stretch's plan is: a stretch too short to ride has none, and a placeholder holds
            // the frame until the walk moves again (releaseRide then applies the short-leg rule).
            if ride == nil { ride = GlideRide(travel: 0, playsStart: false, tricks: []) }
            ride?.held = held
        }
        w.ride = ride
    }

    /// The pointer left: the walk goes on, and so does the ride from the frame it holds (same plan, same stop deadline). A placeholder for a stretch
    /// too short to ride goes, and the rest picture shows from the moment Clawd moves.
    func releaseRide(_ w: inout WalkRun) {
        guard var ride = w.ride else { return }
        if ride.travel + GlideRide.tolerance < GlideRide.shortest { w.ride = nil; return }
        ride.held = nil
        w.ride = ride
    }

    /// The pointer stops the walk: the frame on screen now is the one that stays.
    func holdRide(_ w: inout WalkRun, at t: TimeInterval) {
        guard var ride = w.ride else { return }
        let played = max(0, t - w.since)
        ride.held = ride.frame(at: played)
        ride.offset += played
        w.ride = ride
    }

    // MARK: output

    func walkPlayback(_ w: WalkRun) -> MotionPlayback? {
        if w.moving {
            guard !w.glide, let stepID = w.stepMotionID else {
                return MotionPlayback(source: .glide, use: "walk", startedAt: w.since, duration: 0.001, loops: true,
                                      holdsLastFrame: false, mirrored: w.dir < 0, ride: w.ride)
            }
            // Leftward legs play the catalog's own mirrored entry when it has one, else the base entry flipped.
            if w.dir < 0, let mirror = catalog.motions.first(where: { $0.mirrorOf == stepID }) {
                return MotionPlayback(source: .motion(mirror.id), use: "walk", startedAt: w.since, duration: max(w.cycle, 0.001),
                                      loops: true, holdsLastFrame: false, mirrored: false)
            }
            return MotionPlayback(source: .motion(stepID), use: "walk", startedAt: w.since, duration: max(w.cycle, 0.001), loops: true,
                                  holdsLastFrame: false, mirrored: w.dir < 0)
        }
        if w.phase != .pause, w.glide, let ride = w.ride, ride.held != nil {
            // Standing because the pointer is in the way: the ride's frame stays, mirrored the way Clawd faces.
            return MotionPlayback(source: .glide, use: "walk", startedAt: w.since, duration: 0.001, loops: true,
                                  holdsLastFrame: false, mirrored: w.dir < 0, ride: ride)
        }
        if w.phase == .pause, let pause = w.pauseMotionID, let m = catalog.motion(id: pause) {
            return MotionPlayback(source: .motion(pause), use: "walk-pause", startedAt: w.pauseEnd - w.pauseDuration,
                                  duration: m.duration, loops: false, holdsLastFrame: false, mirrored: w.dir < 0)
        }
        return nil
    }
}
