import Testing
import Foundation
@testable import ClawdCore

// Amendment "the skateboard ride": the plan of one stretch of a glide and the motion frame it shows at each moment. Everything here is the
// pure value `GlideRide`; the scheduler's use of it is in SkateRideSchedulerTests, the pictures in SkateRideStageTests.

private let never: () -> Double = { 0.99 }         // the random seam never chooses the trick
private let always: () -> Double = { 0.0 }          // ... and here it would choose it at every boundary

/// The motion frame at the middle of each 1/12 s slot of a stretch of `travel` seconds.
private func slots(_ ride: GlideRide, upTo travel: TimeInterval) -> [Int] {
    (0..<Int((travel * 12 + 1e-9).rounded(.down))).map { ride.frame(at: (Double($0) + 0.5) / 12) }
}

/// How many separate runs of frames in `range` a sequence holds.
private func spans(_ sequence: [Int], in range: Range<Int>) -> Int {
    var count = 0, inside = false
    for frame in sequence {
        let now = range.contains(frame)
        if now && !inside { count += 1 }
        inside = now
    }
    return count
}

/// The frames one cruise cycle plays: cruiseA, (trick,) cruiseB, push.
private func cycle(first: Bool = false, trick: Bool = false) -> [Int] {
    Array(first ? GlideRide.cruiseFirst..<GlideRide.cruiseA.upperBound : GlideRide.cruiseA)
        + (trick ? Array(GlideRide.trick) : []) + Array(GlideRide.cruiseB) + Array(GlideRide.push)
}

@Suite("SkateRide: the plan and its frames")
struct SkateRidePlan {
    @Test func SkateRide_aLegShorterThanTheWholeStopKeepsTheRestPicture() {
        for travel in [0.0, 0.05, 0.1, 0.2, 0.25, 0.4, GlideRide.stopDuration - 0.001] {
            #expect(GlideRide.plan(travel: travel, resumed: false, random: never) == nil, "T = \(travel)")
            #expect(GlideRide.plan(travel: travel, resumed: true, random: never) == nil, "resumed, T = \(travel)")
        }
    }

    @Test func SkateRide_aLegOfTheStopsLengthShowsTheStopAndNothingElse() throws {
        let ride = try #require(GlideRide.plan(travel: GlideRide.stopDuration, resumed: false, random: never))
        #expect(!ride.playsStart && ride.tricks.isEmpty)
        // The crouch (36-38) and then the rise (39, 40) the art's tail bridge draws: five twelfths of a second, the last frame held to arrival.
        #expect(GlideRide.stop == 36..<41 && GlideRide.frameCount == 41)
        for (k, frame) in [36, 37, 38, 39, 40].enumerated() { #expect(ride.frame(at: Double(k) / 12 + 0.01) == frame, "slot \(k)") }
        #expect(ride.frame(at: GlideRide.stopDuration) == 40)
    }

    @Test func SkateRide_aLegBetweenTheStopAndStartPlusStopBeginsOnFrameThirtyTwoWithNoStart() throws {
        for travel in [GlideRide.stopDuration + 0.01, 0.5, 0.9, 1.0, 13.0 / 12 - 0.001] {
            let ride = try #require(GlideRide.plan(travel: travel, resumed: false, random: always), "T = \(travel)")
            #expect(!ride.playsStart && ride.tricks.isEmpty, "T = \(travel): no start, and no trick fits")
            #expect(ride.frame(at: 0) == GlideRide.cruiseFirst, "T = \(travel): the first frame is sprite frame 32")
            let legTime = ride.travel                       // the plan may move the stop to a cruise-cycle boundary: at most 10 % of speed
            let cruise = slots(ride, upTo: legTime - GlideRide.stopDuration)
            let want = Array((Array(GlideRide.cruiseFirst..<GlideRide.cruiseA.upperBound) + Array(GlideRide.cruiseB)).prefix(cruise.count))
            #expect(cruise == want, "T = \(travel): \(cruise)")
            #expect(ride.frame(at: legTime - GlideRide.stopDuration) == GlideRide.stop.lowerBound, "T = \(travel): stop begins at the deadline")
        }
    }

    @Test func SkateRide_thirteenTwelfthsPlayStartAndThenStopAtOnce() throws {
        let travel = 13.0 / 12
        let ride = try #require(GlideRide.plan(travel: travel, resumed: false, random: always))
        #expect(ride.playsStart && ride.tricks.isEmpty, "the cruise lasts 0 s, so no trick fits")
        #expect(slots(ride, upTo: travel) == Array(GlideRide.start) + Array(GlideRide.stop))
        #expect(ride.frame(at: 8.0 / 12 - 0.0001) == 7 && ride.frame(at: 8.0 / 12) == 36)
    }

    @Test func SkateRide_aLongLegPlaysStartThenCruiseCyclesWithAPushAfterEveryCruiseB() throws {
        let travel = 9.0
        let ride = try #require(GlideRide.plan(travel: travel, resumed: false, random: never))
        #expect(ride.playsStart && ride.tricks.isEmpty)
        let played = slots(ride, upTo: ride.travel)
        var want = Array(GlideRide.start)
        while want.count < played.count - GlideRide.stop.count { want += cycle() }
        want = Array(want.prefix(played.count - GlideRide.stop.count)) + Array(GlideRide.stop)
        #expect(played == want)
        #expect(played.contains(GlideRide.push.lowerBound) && !played.contains(where: { GlideRide.trick.contains($0) }))
    }

    @Test func SkateRide_aCruiseCutByTheDeadlineStopsThereAndStopBeginsThere() throws {
        let travel = 2.1                                    // the deadline (2.1 s less the stop) falls inside a cruise slot
        let deadline = travel - GlideRide.stopDuration
        let ride = try #require(GlideRide.plan(travel: travel, resumed: false, random: never))
        let before = ride.frame(at: deadline - 0.0001)
        #expect(!GlideRide.stop.contains(before))
        #expect(ride.frame(at: deadline) == GlideRide.stop.lowerBound)
    }

    @Test(arguments: [GlideRide.stopDuration, 0.5, 13.0 / 12, 1.2, 1.8, 2.1, 6.0, 20.0])
    func SkateRide_stopTakesTheLastFiveTwelfthsAndEndsExactlyAtArrival(travel: Double) throws {
        let ride = try #require(GlideRide.plan(travel: travel, resumed: false, random: never))
        let travel = ride.travel      // the plan may move the stop to a cruise-cycle boundary (at most 10 % of speed)
        let deadline = travel - GlideRide.stopDuration
        for (k, frame) in GlideRide.stop.enumerated() { #expect(ride.frame(at: deadline + Double(k) / 12 + 0.01) == frame, "T = \(travel), slot \(k)") }
        #expect(ride.frame(at: travel - 0.0001) == GlideRide.stop.upperBound - 1)
        if deadline > 0.01 { #expect(!GlideRide.stop.contains(ride.frame(at: deadline - 0.01))) }
    }

    @Test func SkateRide_stopBeginsAtACruiseCycleBoundaryWhenTenPercentOfSpeedReachesOne() throws {
        var seed: UInt64 = 12345
        func unit() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        var snapped = 0
        for i in 0..<300 {
            let asked = 2.2 + unit() * 6.5
            let ride = try #require(GlideRide.plan(travel: asked, resumed: i % 7 == 6, random: unit))
            let ratio = asked / ride.travel
            #expect(ratio >= 0.9 - 1e-9 && ratio <= 1.1 + 1e-9, "speed changed by \(ratio) for a leg of \(asked) s")
            let stopAt = ride.travel - GlideRide.stopDuration
            #expect(ride.frame(at: stopAt + 1e-3) == GlideRide.stop.lowerBound, "stop begins at the end of the leg minus the stop's five twelfths")
            if abs(ratio - 1) > 1e-12 {
                snapped += 1
                #expect(ride.frame(at: stopAt - 1e-3) == GlideRide.cruiseA.upperBound - 1, "the frame before stop is the last cruiseA frame: \(ride.frame(at: stopAt - 1e-3))")
            }
        }
        #expect(snapped >= 100, "legs that can reach a boundary within 10 %: \(snapped) of 300")
    }

    @Test func SkateRide_aLegThatNoBoundaryReachesKeepsItsStopAtTheNaturalDeadline() throws {
        // 2.4 s: the boundaries are at 1.33 and 3.17 s (a leg of 1.75 and 3.58 s), 37 % and 33 % away.
        let ride = try #require(GlideRide.plan(travel: 2.4, resumed: false, random: never))
        #expect(ride.travel == 2.4)
        #expect(ride.frame(at: 2.4 - GlideRide.stopDuration + 1e-3) == 36)
    }

    @Test func SkateRide_theTrickPlaysAtMostOncePerGlide() throws {
        // A 20 s glide whose random seam would choose the trick at every boundary it is asked at.
        var draws = 0
        let ride = try #require(GlideRide.plan(travel: 20, resumed: false, random: { draws += 1; return 0.0 }))
        #expect(ride.tricks.count == 1 && draws == 1, "one trick, and the seam is not asked again: \(ride.tricks), \(draws) draws")
        let played = slots(ride, upTo: 20)
        #expect(spans(played, in: GlideRide.trick) == 1, "the trick frames appear in exactly one span")
        // The trick sits between a cruiseA and the cruiseB that follows it, six frames long.
        let at = try #require(played.firstIndex(of: GlideRide.trick.lowerBound))
        #expect(Array(played[at..<(at + 6)]) == Array(GlideRide.trick) && played[at - 1] == GlideRide.cruiseA.upperBound - 1
                && played[at + 6] == GlideRide.cruiseB.lowerBound)
    }

    @Test func SkateRide_aTrickIsOfferedOnlyWhereItEndsBeforeStopBegins() throws {
        // T = 1.3 s: the first cruise boundary (start 8/12 + cruiseA 8/12 = 1.333 s) is past the deadline 0.883 s: no draw at all.
        var draws = 0
        _ = GlideRide.plan(travel: 1.3, resumed: false, random: { draws += 1; return 0.0 })
        #expect(draws == 0)
        // T = 2.2 s: the deadline is 1.783 s and the first boundary is at 1.333 s, 0.45 s before it: less than the trick's 0.5 s.
        _ = GlideRide.plan(travel: 2.2, resumed: false, random: { draws += 1; return 0.0 })
        #expect(draws == 0)
        // T = 2.5 s: the deadline is 2.083 s, 0.75 s after the boundary: the seam is asked, and the trick ends before stop begins.
        let ride = try #require(GlideRide.plan(travel: 2.5, resumed: false, random: { draws += 1; return 0.0 }))
        #expect(draws == 1 && ride.tricks == [0] && ride.travel == 2.5)
        let played = slots(ride, upTo: 2.5)
        let last = try #require(played.lastIndex(where: { GlideRide.trick.contains($0) }))
        let deadline = 2.5 - GlideRide.stopDuration
        #expect(Double(last + 1) / 12 <= deadline + 1e-9, "the trick ends at \(Double(last + 1) / 12) s, stop begins at \(deadline) s")
        #expect(Array(played.suffix(GlideRide.stop.count)) == Array(GlideRide.stop))
    }

    @Test func SkateRide_theTrickIsChosenWithProbabilityOneThird() throws {
        let chosen = try #require(GlideRide.plan(travel: 6, resumed: false, random: { 1.0 / 3 - 1e-9 }))
        #expect(chosen.tricks == [0])
        let refused = try #require(GlideRide.plan(travel: 6, resumed: false, random: { 1.0 / 3 }))
        #expect(refused.tricks.isEmpty, "a draw of exactly 1/3 is not below 1/3")
    }

    @Test func SkateRide_aResumedRideNeverPlaysStartOrATrickAndNeverAsksTheSeam() throws {
        var draws = 0
        for travel in [GlideRide.stopDuration, 0.7, 13.0 / 12, 3.0, 20.0] {
            let ride = try #require(GlideRide.plan(travel: travel, resumed: true, random: { draws += 1; return 0.0 }))
            #expect(!ride.playsStart && ride.tricks.isEmpty, "T = \(travel)")
            #expect(ride.frame(at: 0) == (travel > GlideRide.stopDuration + 0.01 ? GlideRide.cruiseFirst : GlideRide.stop.lowerBound))
            let played = slots(ride, upTo: ride.travel)
            #expect(!played.contains(where: { GlideRide.start.contains($0) || GlideRide.trick.contains($0) }), "T = \(travel)")
            #expect(Array(played.suffix(GlideRide.stop.count)) == Array(GlideRide.stop))
        }
        #expect(draws == 0)
        #expect(GlideRide.plan(travel: 0.2, resumed: true, random: never) == nil, "a resumed ride shorter than the whole stop keeps the rest picture")
    }

    @Test func SkateRide_aResumedRideStillRunsCruiseCyclesWithPushes() throws {
        let ride = try #require(GlideRide.plan(travel: 5, resumed: true, random: never))
        let played = slots(ride, upTo: ride.travel)
        // Every cycle of a resumed ride starts at sprite frame 32 (motion frame 9): 32..38, 45..55, push 56..58, back to 32. Written out, not derived.
        let loop = [9, 10, 11, 12, 13, 14, 15, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35]
        var want: [Int] = []
        while want.count < played.count { want += loop }
        #expect(Array(played.dropLast(GlideRide.stop.count)) == Array(want.prefix(played.count - GlideRide.stop.count)), "\(played)")
        #expect(played.count > loop.count * 2, "the ride loops at least twice")
    }

    @Test func SkateRide_aHeldFrameStaysWhateverTheClockSays() throws {
        var ride = try #require(GlideRide.plan(travel: 5, resumed: false, random: never))
        ride.held = 12
        for t in [0.0, 0.3, 2.0, 4.9, 5.0, 50.0] { #expect(ride.frame(at: t) == 12) }
    }

    @Test(arguments: [GlideRide.stopDuration, 0.5, 0.7, 13.0 / 12, 1.2, 1.8, 2.5, 7.0])
    func SkateRide_everyFrameIsAFrameOfTheMotionAtEveryMoment(travel: Double) throws {
        for resumed in [false, true] {
            for random in [never, always] {
                let ride = try #require(GlideRide.plan(travel: travel, resumed: resumed, random: random))
                var t = -0.1
                while t < travel + 0.3 {
                    #expect((0..<GlideRide.frameCount).contains(ride.frame(at: t)), "T = \(travel), t = \(t)")
                    t += 0.013
                }
            }
        }
    }
}
