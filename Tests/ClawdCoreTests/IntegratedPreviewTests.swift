import Testing
import Foundation
import CoreGraphics
import ClawdCore
import ClawdRendering
import ClawdDesktop

/// Previews drawn by the integrated build (spec 9b item 3): the pictures below are what `StageRuntime` hands the panel, with the
/// scheduler and the controller running on a virtual clock. Every state, every phase-1 bubble style in every scene, a walk, a look
/// change and a few motions, on a made-up dark and light desktop, at real size (1 device pixel per point) and at 2x. Nothing is shown
/// on screen; the pictures are PNGs in .evidence/v2/previews/.
@Suite("Previews from the integrated build", .serialized)
struct IntegratedPreviewSuite {
    private static let styleNames = [1: "blue pixel bubble", 6: "pixel cloud", 10: "typing bubble"]

    private final class Studio {
        let clock = VirtualClock()
        let timer: FakeScheduler
        let run: IdleRenderRun
        var runtime: StageRuntime { run.runtime }
        let backing: Int
        init(backing: Int, motion: MotionLevel = .off, seed: UInt64 = 7, lookDueIn: Double? = nil, idle: TimeInterval? = nil) throws {
            self.backing = backing
            timer = FakeScheduler(clock: clock)
            var options = HeadlessOptions(); options.motion = motion; options.seed = seed; options.lookDueIn = lookDueIn
            run = try IdleRenderRun(clock: clock, scheduler: timer, art: artDirectory, options: options, pixelScale: Double(backing))
            run.controller.machine.onChange = { [unowned self] _ in self.run.runtime.sceneChanged() }
            run.controller.randomUnit = { 0 }
            if let idle { run.runtime.scheduler.inputIdle = { idle } }
            run.runtime.setQuiet(.aquaNotRunning, active: false)
            run.runtime.start()
        }
        func advance(_ seconds: Double) { advanceVirtual(clock: clock, scheduler: timer, runtime: runtime, by: seconds) }
        func feed(_ text: String) { for raw in text.split(separator: "\n") { run.controller.receive(line: String(raw)) } }
        func only(style: Int) {
            var settings = SchedulerSettings(); settings.bubbleExcluded = Set(SchedulerSettings.bubbleStyles).subtracting([style])
            runtime.apply(settings: settings)
        }
        var home: CGPoint { HeadlessStage.geometry().homeOrigin }
        /// The crop of the made-up desktop around Clawd, with the current picture on it.
        func shot(light: Bool, wide: Bool = false) throws -> Raster {
            let stage = try #require(runtime.lastFrame, "nothing is shown")
            let width: CGFloat = wide ? 560 : 300
            let around = CGRect(x: home.x - (wide ? 280 : 100), y: home.y - 20, width: width, height: 110)
            return Desktop.crop(stage, around: around, light: light, backing: backing)
        }
    }

    private func label(_ text: String, width: Int, backing: Int) -> Raster {
        var strip = Raster(width: max(1, width / (2 * backing)), height: 10)
        strip.fill(x: 0, y: 0, width: strip.width, height: strip.height, Pixel(rgb: 0x2A2A27))
        PixelFont.draw(text, into: &strip, x: 2, y: 2, color: Pixel(rgb: 0xE8E6DC))
        return strip.upscaled(by: 2 * backing)
    }
    private func labelled(_ picture: Raster, _ text: String, backing: Int) -> Raster {
        var out = Raster(width: picture.width, height: picture.height + 20 * backing)
        out.blit(label(text, width: picture.width, backing: backing), x: 0, y: 0)
        out.blit(picture, x: 0, y: 20 * backing)
        return out
    }
    private func sheet(_ tiles: [Raster], columns: Int, backing: Int) -> Raster {
        let pad = 6 * backing
        let w = tiles.map(\.width).max() ?? 1, h = tiles.map(\.height).max() ?? 1, rows = (tiles.count + columns - 1) / columns
        var out = Raster(width: columns * (w + pad) + pad, height: rows * (h + pad) + pad)
        out.fill(x: 0, y: 0, width: out.width, height: out.height, Pixel(rgb: 0x111110))
        for (i, t) in tiles.enumerated() { out.blit(t, x: pad + (i % columns) * (w + pad), y: pad + (i / columns) * (h + pad)) }
        return out
    }
    private func suffix(_ backing: Int) -> String { backing == 1 ? "real" : "2x" }

    @Test func Integrated_everyStateAndEveryPhaseOneStyleInEveryScene() throws {
        let store = try evidenceStore("v2/previews")
        for backing in [1, 2] {
            var states: [Raster] = [], bubbles: [Raster] = []
            for light in [false, true] {
                let tone = light ? "light" : "dark"
                func state(_ name: String, _ studio: Studio, wide: Bool = false) throws {
                    let picture = try studio.shot(light: light, wide: wide)
                    let tile = labelled(picture, "\(name) \(tone)", backing: backing)
                    states.append(tile)
                    try store.write(SceneRenderer.png(try tile.cgImage()), to: "state-\(name.replacingOccurrences(of: " ", with: "-"))-\(tone)-\(suffix(backing)).png")
                }
                // rest, blink
                let rest = try Studio(backing: backing)
                try state("rest", rest)
                rest.advance(3.05)
                #expect(rest.run.controller.state().blink)
                try state("blink", rest)
                // sleep: the user has been away
                let asleep = try Studio(backing: backing, idle: 700)
                asleep.advance(6)
                #expect(asleep.runtime.scheduler.asleep)
                try state("sleep", asleep)
                // drag
                let drag = try Studio(backing: backing)
                drag.runtime.perform { drag.runtime.scheduler.dragStarted(); drag.runtime.dragOrigin = CGPoint(x: drag.home.x + 40, y: drag.home.y + 30) }
                drag.advance(0.3)
                try state("drag", drag)
                // a click reaction
                let touch = try Studio(backing: backing)
                touch.runtime.perform { touch.runtime.scheduler.click() }
                touch.advance(0.4)
                try state("touch", touch)
                // a walk, a few seconds in
                let walk = try Studio(backing: backing, motion: .lively, seed: 7)
                var spent = 0.0
                while walk.runtime.scheduler.counters.walks == 0, spent < 300 { walk.advance(0.5); spent += 0.5 }
                #expect(walk.runtime.scheduler.counters.walks > 0)
                walk.advance(4)
                try state("walk", walk, wide: true)
                // a look change, the middle of the duck
                let look = try Studio(backing: backing, lookDueIn: 2)
                var waited = 0.0
                while look.runtime.lastRequest?.frame.transitionProgress == nil, waited < 120 { look.advance(0.1); waited += 0.1 }
                look.advance(0.4)
                try state("look change", look)

                // bubbles: phase-1 styles in every scene
                for style in BubbleDesign.ids {
                    func bubble(_ scene: String, _ studio: Studio) throws {
                        let tile = labelled(try studio.shot(light: light), "style \(style) \(Self.styleNames[style] ?? "") \(scene) \(tone)", backing: backing)
                        bubbles.append(tile)
                        if scene == "listening" || scene == "thinking" {
                            try store.write(SceneRenderer.png(try tile.cgImage()), to: "bubble-style\(style)-\(scene)-\(tone)-\(suffix(backing)).png")
                        }
                    }
                    let studio = try Studio(backing: backing)
                    studio.only(style: style)
                    studio.feed(startLine(studio.clock)); studio.advance(0.1)
                    #expect(studio.runtime.lastFrame?.bubble?.style == style, "the integrated runtime drew style \(style)")
                    try bubble("listening", studio)
                    studio.feed(completedLine(studio.clock)); studio.advance(0.7)
                    try bubble("thinking", studio)
                    studio.feed(ackLine(studio.clock)); studio.advance(0.5)
                    try bubble("sent", studio)
                    studio.advance(4)
                    studio.feed(startLine(studio.clock, lease: 2)); studio.advance(0.1)
                    studio.feed(line(studio.clock, "DictationOrchestrator", "dictation.cancel_accepted lease_id=2")); studio.advance(0.3)
                    try bubble("interrupted", studio)
                    studio.advance(4)
                    studio.feed(line(studio.clock, "DictationRuntimeAdapter", "dictation.native_audio_capture_failed lease_id=3", level: "warn")); studio.advance(0.3)
                    try bubble("error", studio)
                }
            }
            try store.write(SceneRenderer.png(try sheet(states, columns: 3, backing: backing).cgImage()), to: "integrated-states-\(suffix(backing)).png")
            try store.write(SceneRenderer.png(try sheet(bubbles, columns: 2, backing: backing).cgImage()), to: "integrated-bubbles-\(suffix(backing)).png")
        }
    }

    @Test func Integrated_theMotionsOfARealSeededRun() throws {
        let store = try evidenceStore("v2/previews")
        for backing in [1, 2] {
            let studio = try Studio(backing: backing, motion: .lively, seed: 21)
            var seen = Set<String>(), tiles: [Raster] = []
            var last = studio.clock.now
            while studio.clock.now - last < 1800, tiles.count < 12 {
                studio.advance(0.5)
                guard let playback = studio.runtime.lastRequest?.frame.playback, let id = playback.motionID, playback.use == "idle",
                      studio.clock.now - playback.startedAt > 1.2, seen.insert(id).inserted else { continue }
                tiles.append(labelled(try studio.shot(light: false, wide: true), id, backing: backing))
                last = studio.clock.now
            }
            #expect(tiles.count >= 6, "a lively half hour shows at least six different motions (saw \(seen.sorted()))")
            try store.write(SceneRenderer.png(try sheet(tiles, columns: 2, backing: backing).cgImage()), to: "integrated-motions-\(suffix(backing)).png")
        }
    }
}
