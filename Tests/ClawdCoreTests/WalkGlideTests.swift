import Testing
import Foundation
import CoreGraphics
import ClawdCore
import ClawdRendering
import ClawdDesktop

@Suite("Walk glide", .serialized)
struct WalkGlideSuite {
    /// A walk (out and back, so both facings) through the real stage runtime: the rest picture is drawn only at a leg's start and end, and whenever Clawd's picture stays the same for more than two frames of
    /// the walk's 12 fps, his canvas must not be moving. The art's rest picture is seven frames long (0.58 s, 17 pt of travel at 30 pt/s).
    @Test func WalkGlide_noPictureOfClawdStaysForMoreThanTwoFramesWhileHeMoves() throws {
        let clock = VirtualClock(), timer = FakeScheduler(clock: clock)
        var options = HeadlessOptions(); options.motion = .lively; options.seed = 7; options.walk = true
        let run = try IdleRenderRun(clock: clock, scheduler: timer, art: artDirectory, options: options, pixelScale: 2)
        var shown: [(at: Double, stage: StageFrame)] = []
        var lines: [String] = []
        let original = run.runtime.present
        run.runtime.present = { stage in shown.append((clock.now, stage)); original(stage) }
        run.runtime.log = { lines.append($0) }
        run.controller.machine.onChange = { _ in run.runtime.sceneChanged() }
        run.runtime.setQuiet(.aquaNotRunning, active: false)
        run.runtime.start()
        var spent = 0.0
        while !lines.contains(where: { $0.hasPrefix("WALK end") }), spent < 400 { advanceVirtual(clock: clock, scheduler: timer, runtime: run.runtime, by: 0.25); spent += 0.25 }
        #expect(lines.contains { $0.hasPrefix("WALK start") } && lines.contains { $0.hasPrefix("WALK end") }, "a whole walk was played")
        #expect(Set(shown.map { $0.stage.canvas.minX }).count > 40, "the canvas moved over many frames")
        let framePeriod = 1.0 / 12, allowed = 2 * framePeriod + 0.015
        var worst = 0.0, worstAt = 0.0
        var runStart = 0
        for i in 1...shown.count {
            let ended = i == shown.count || shown[i].stage.composed.raster != shown[runStart].stage.composed.raster
            guard ended else { continue }
            if i < shown.count {
                // The time in the run during which the canvas was moving: from the first change of place inside it to the last one.
                let movesAt = (runStart..<i).filter { shown[$0 + 1].stage.canvas.minX != shown[$0].stage.canvas.minX }
                if let first = movesAt.first, let last = movesAt.last {
                    let length = shown[last + 1].at - shown[first].at
                    if length > worst { worst = length; worstAt = shown[first].at }
                }
            }
            runStart = i
        }
        #expect(worst <= allowed, "the same picture stayed \(worst) s while Clawd moved (from \(worstAt) s); at most \(allowed) s")

        // Each leg is a run of moves with less than a third of a second between them. It starts on the rest picture (the picture of its first move);
        // that picture may show again only in the first and the last two frames of the leg.
        let moveIndices = (1..<shown.count).filter { shown[$0].stage.canvas.minX != shown[$0 - 1].stage.canvas.minX }
        var legs: [[Int]] = []
        for index in moveIndices {
            if let last = legs.last?.last, shown[index].at - shown[last].at < 0.3 { legs[legs.count - 1].append(index) } else { legs.append([index]) }
        }
        #expect(legs.count >= 2, "the walk went out and back")
        for leg in legs {
            guard let first = leg.first, let last = leg.last else { continue }
            let rest = shown[first].stage.composed.raster
            let from = shown[first].at + allowed, to = shown[last].at - allowed
            let restInside = (first...last).filter { shown[$0].at > from && shown[$0].at < to && shown[$0].stage.composed.raster == rest }
            #expect(restInside.isEmpty, "the rest picture was drawn at \(restInside.first.map { shown[$0].at } ?? 0) s inside the leg from \(shown[first].at) s to \(shown[last].at) s")
            #expect(to > from, "the leg is longer than its first and last two frames")
        }
    }
}
