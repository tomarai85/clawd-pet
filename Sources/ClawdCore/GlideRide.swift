import Foundation

/// The skateboard look's glide: the frames of the motion `D14-ride` (sprite 1 frames 23-61 of the claude.dev page) played over the seconds
/// actually walked, so the wheels turn and Clawd leans into the way he goes. One value is one stretch of a leg: the scheduler plans it where the
/// stretch begins (a leg's start, or any later restart of the clock inside a leg, which makes the rest of the way a "resumed" ride) and the
/// renderer reads `frame(at:)` for the seconds walked since.
///
/// The frames of the motion, by index: start 0-7, cruiseA 8-15, trick 16-21, cruiseB 22-32, push 33-35, stop 36-40, 12 fps. Frames 0-38 are the
/// sprite's; 39 and 40 are the art's tail bridge (`D14-ride-tail`: the crouch rises towards the rest picture in two frames, so that the arrival is not
/// one jump from the crouch to the rest pose). A ride plays `start` once, then cruiseA and cruiseB alternately with a `push` after every cruiseB, and
/// `stop` (crouch and rise) for its last five twelfths of a second, so that `stop` ends exactly at arrival. One `trick` at most is put between a
/// cruiseA and the cruiseB that follows it (the order of the sprite).
public struct GlideRide: Equatable {
    public static let motionID = "D14-ride"
    /// The motion as the stage plays it: the atlas entry's 39 sprite frames and the 2 frames of its tail bridge.
    public static let frameCount = 41
    /// The frames of the atlas entry itself (sprite 1, frames 23-61).
    public static let spriteFrameCount = 39
    public static let framesPerSecond = 12.0
    public static let start = 0..<8
    public static let cruiseA = 8..<16
    public static let trick = 16..<22
    public static let cruiseB = 22..<33
    public static let push = 33..<36
    public static let stop = 36..<41
    /// A ride without `start` begins on sprite frame 32 (motion frame 9): its board is the rest picture's board cell for cell, frame 31's is not.
    public static let cruiseFirst = 9
    public static let stopDuration: TimeInterval = 5.0 / 12
    public static let startDuration: TimeInterval = 8.0 / 12
    /// A leg shorter than this (too short to hold the whole stop) keeps the rest picture, as a glide always did.
    public static let shortest: TimeInterval = stopDuration
    /// The trick is offered at a cruise boundary only when it would end before `stop` begins.
    public static let trickLength: TimeInterval = 6.0 / 12
    public static let trickChance = 1.0 / 3
    static let tolerance = 1e-9
    /// The most a leg's speed changes to put the stop on a cruise-cycle boundary.
    public static let speedChange = 0.10

    /// Seconds of travel from the start of the stretch to arrival. `plan` may return a travel up to `speedChange` away from the one asked for.
    public let travel: TimeInterval
    public let playsStart: Bool
    /// The cruise cycles (0, 1, ...) after whose cruiseA the trick plays. One at most; the plan draws no more once it has chosen.
    public let tricks: [Int]
    /// The walk is stalled (the pointer is in the way): this frame stays on screen until the walk goes on.
    public var held: Int?
    /// Seconds of the ride already played before the clock of the stretch was last restarted by a stall: the ride's clock is the seconds actually
    /// walked, which do not advance while the walk stands, so the release goes on from here (a pointer stall is not a re-timing of the ride).
    public var offset: TimeInterval = 0

    init(travel: TimeInterval, playsStart: Bool, tricks: [Int], held: Int? = nil) {
        self.travel = travel; self.playsStart = playsStart; self.tricks = tricks; self.held = held
    }

    /// The ride of a stretch that takes `travel` seconds, or nil when it is too short to ride (the rest picture throughout).
    /// A resumed ride never plays `start` and never a trick: a ride was already going on. `random` is the scheduler's own source; it is asked once
    /// for each cruise boundary at which a trick would still fit, until one trick is chosen.
    public static func plan(travel: TimeInterval, resumed: Bool, random: () -> Double) -> GlideRide? {
        guard travel + tolerance >= shortest else { return nil }
        let deadline = travel - stopDuration
        let playsStart = !resumed && travel + tolerance >= startDuration + stopDuration
        var tricks: [Int] = []
        let cruiseA = (playsStart ? 8.0 : 7.0) / framesPerSecond
        if !resumed {
            var clock = playsStart ? startDuration : 0
            var cycle = 0
            while true {
                let boundary = clock + cruiseA
                guard deadline - boundary + tolerance >= trickLength else { break }
                if tricks.isEmpty, random() < trickChance { tricks.append(cycle) }
                clock = boundary + (tricks.last == cycle ? trickLength : 0) + (11.0 + 3.0) / framesPerSecond
                cycle += 1
            }
        }
        // `stop` begins at a cruise-cycle boundary (the end of a cruiseA, where the board is nearest the stop's): the first one at or after the
        // natural deadline when the leg's speed can change by at most `speedChange` to reach it, else the last one before it, else the natural
        // deadline. The leg then takes `stop begins + stopDuration`, and the scheduler sets the speed to the way left over that time.
        var boundaries: [(time: TimeInterval, cycle: Int)] = []
        var clock = playsStart ? startDuration : 0
        var cycle = 0
        while clock < travel * (1 + speedChange) + stopDuration {
            let boundary = clock + cruiseA
            boundaries.append((boundary, cycle))
            clock = boundary + (tricks.contains(cycle) ? trickLength : 0) + (11.0 + 3.0) / framesPerSecond
            cycle += 1
        }
        let fits: (TimeInterval) -> Bool = { abs(travel / ($0 + stopDuration) - 1) <= speedChange + tolerance }
        var chosen = boundaries.first { $0.time + tolerance >= deadline && fits($0.time) }
        if chosen == nil { chosen = boundaries.last { $0.time < deadline && fits($0.time) } }
        guard let chosen else { return GlideRide(travel: travel, playsStart: playsStart, tricks: tricks) }
        // A trick at or after the stop's boundary does not play: the stop takes its place.
        return GlideRide(travel: chosen.time + stopDuration, playsStart: playsStart, tricks: tricks.filter { $0 < chosen.cycle })
    }

    /// The motion frame on screen `elapsed` seconds into the stretch: the held frame while stalled, `stop` from its deadline, else the cruise.
    public func frame(at elapsed: TimeInterval) -> Int {
        if let held { return held }
        let t = max(0, elapsed) + offset
        let deadline = travel - Self.stopDuration
        if t + Self.tolerance >= deadline {
            let k = Int(((t - deadline) * Self.framesPerSecond + Self.tolerance).rounded(.down))
            return Self.stop.lowerBound + min(Self.stop.count - 1, max(0, k))
        }
        var tick = Int((t * Self.framesPerSecond + Self.tolerance).rounded(.down))
        if playsStart {
            if tick < Self.start.count { return Self.start.lowerBound + tick }
            tick -= Self.start.count
        }
        var cycle = 0
        while true {
            // After `start` the cruise runs on from sprite frame 31; without it (a short leg, a resumed ride) every cycle begins at frame 32, whose
            // board is the rest picture's cell for cell. The loop's wrap, 55 to 32, moves 8 wheel-interior cells: one more step of the wheel.
            let a = playsStart ? Self.cruiseA.count : Self.cruiseA.count - 1
            if tick < a { return Self.cruiseA.upperBound - a + tick }
            tick -= a
            if tricks.contains(cycle) {
                if tick < Self.trick.count { return Self.trick.lowerBound + tick }
                tick -= Self.trick.count
            }
            if tick < Self.cruiseB.count { return Self.cruiseB.lowerBound + tick }
            tick -= Self.cruiseB.count
            if tick < Self.push.count { return Self.push.lowerBound + tick }
            tick -= Self.push.count
            cycle += 1
        }
    }
}
