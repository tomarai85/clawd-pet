import Testing
import Foundation
import CoreGraphics
import ClawdCore
import ClawdRendering
import ClawdDesktop

/// Spec 9b item 7: letting go after a drag plays a drop motion from the real catalog (A3 both faces, A8, and C7 from phase 4), and it renders.
@Suite("Drop after a drag on the real catalog") struct DropAfterDragTests {
    @Test func DropAfterDrag_playsADropMotionThatRenders() throws {
        var ids = Set<String>()
        for seed in UInt64(1)...12 {
            let clock = VirtualClock()
            let timer = FakeScheduler(clock: clock)
            var options = HeadlessOptions(); options.motion = .quiet; options.seed = seed
            let run = try IdleRenderRun(clock: clock, scheduler: timer, art: artDirectory, options: options, pixelScale: 2)
            var lines: [String] = []
            run.runtime.log = { lines.append($0) }
            run.controller.machine.onChange = { _ in run.runtime.sceneChanged() }
            run.runtime.scheduler.inputIdle = { 0 }
            run.runtime.setQuiet(.aquaNotRunning, active: false)
            run.runtime.start()
            advanceVirtual(clock: clock, scheduler: timer, runtime: run.runtime, by: 3)
            run.runtime.scheduler.dragStarted()
            advanceVirtual(clock: clock, scheduler: timer, runtime: run.runtime, by: 1)
            let before = run.runtime.renderCount
            run.runtime.scheduler.dragEnded(newHome: nil)
            run.runtime.sceneChanged()
            advanceVirtual(clock: clock, scheduler: timer, runtime: run.runtime, by: 0.2)
            let playback = try #require(run.runtime.lastRequest?.frame.playback, "seed \(seed): nothing plays after the drop")
            #expect(playback.use == "drop", "seed \(seed): use \(String(describing: playback.use))")
            if let id = playback.motionID { ids.insert(id) }
            advanceVirtual(clock: clock, scheduler: timer, runtime: run.runtime, by: 3)
            #expect(run.runtime.renderCount - before >= 10, "seed \(seed): only \(run.runtime.renderCount - before) renders after the drop")
            #expect(!lines.contains("RENDER failed"), "seed \(seed): \(lines)")
        }
        #expect(!ids.isEmpty && ids.isSubset(of: ["A3-jumping", "A3-jumping-happy", "A8-excited", "C7-drop"]), "drop motions seen: \(ids.sorted())")
    }
}
