import Testing
import Foundation
import CoreGraphics
import ClawdCore
import ClawdRendering

/// The design-pass renders (spec 9b item 3): every state and every phase-1 bubble style as a crop of a made-up desktop, dark and light,
/// at real size (1 device pixel per point) and at 2x (a Retina display). Nothing is shown on screen: the pictures are written as PNGs
/// to .evidence/v2/previews/ for the user to look at. They are rebuilt from the production renderer on every run.
@Suite("Previews of every state and style", .serialized)
struct StagePreviewTests {
    private static let styleNames = [1: "blue pixel bubble", 6: "pixel cloud", 10: "typing bubble"]
    private let crop = CGRect(x: 548, y: 84, width: 300, height: 110)      // around Clawd at home (576, 100)

    private func label(_ text: String, width: Int, backing: Int) -> Raster {
        var strip = Raster(width: width / (2 * backing), height: 10)
        strip.fill(x: 0, y: 0, width: strip.width, height: strip.height, Pixel(rgb: 0x2A2A27))
        PixelFont.draw(text, into: &strip, x: 2, y: 2, color: Pixel(rgb: 0xE8E6DC))
        return strip.upscaled(by: 2 * backing)
    }

    private func tile(_ frame: SchedulerFrame, now: Double, content: BubbleContent = BubbleContent(scene: .listening), light: Bool, backing: Int,
                      geometry: PetGeometry = Screens.geometry(), name: String, blink: Bool = false) throws -> Raster {
        let stage = try #require(try stageRenderer.compose(StageRequest(frame: frame, now: now, blink: blink, geometry: geometry, pixelScale: Double(backing), content: content)))
        let picture = Desktop.crop(stage, around: crop, light: light, backing: backing)
        var out = Raster(width: picture.width, height: picture.height + 10 * 2 * backing)
        out.blit(label(name, width: picture.width, backing: backing), x: 0, y: 0)
        out.blit(picture, x: 0, y: 10 * 2 * backing)
        return out
    }

    private func sheet(_ tiles: [Raster], columns: Int, backing: Int) -> Raster {
        let pad = 6 * backing
        let w = tiles[0].width, h = tiles[0].height, rows = (tiles.count + columns - 1) / columns
        var out = Raster(width: columns * (w + pad) + pad, height: rows * (h + pad) + pad)
        out.fill(x: 0, y: 0, width: out.width, height: out.height, Pixel(rgb: 0x111110))
        for (i, t) in tiles.enumerated() { out.blit(t, x: pad + (i % columns) * (w + pad), y: pad + (i / columns) * (h + pad)) }
        return out
    }

    private func bubbleFrame(_ style: Int, _ scene: Scene) -> (SchedulerFrame, BubbleContent, Double) {
        let pose = scene == .listening ? "listen" : scene == .thinking ? "think" : scene == .sent ? "hop" : "idle"
        let elapsed: Double = scene == .thinking ? 0.7 : scene == .sent ? 0.5 : 0.1
        let frame = Frames.pose(pose, scene: scene, bubble: BubbleState(style: style, scene: scene))
        return (frame, BubbleContent(scene: scene, elapsed: elapsed, duration: 5, verb: "Cogitating", pastVerb: "Cooked"), pose == "hop" ? 0.34 : 0.1)
    }

    @Test func Preview_everyStyleInEveryScene() throws {
        let store = try evidenceStore("v2/previews")
        for backing in [1, 2] {
            var tiles: [Raster] = []
            for style in BubbleDesign.ids { for scene in BubbleContent.shownScenes { for light in [false, true] {
                let (frame, content, now) = bubbleFrame(style, scene)
                let name = "style \(style) \(Self.styleNames[style] ?? "") \(scene.rawValue) \(light ? "light" : "dark")"
                let t = try tile(frame, now: now, content: content, light: light, backing: backing, name: name)
                tiles.append(t)
                if scene == .thinking || scene == .listening {
                    try store.write(SceneRenderer.png(try t.cgImage()), to: "bubble-style\(style)-\(scene.rawValue)-\(light ? "light" : "dark")-\(backing == 1 ? "real" : "2x").png")
                }
            } } }
            try store.write(SceneRenderer.png(try sheet(tiles, columns: 2, backing: backing).cgImage()), to: "sheet-bubbles-\(backing == 1 ? "real" : "2x").png")
        }
    }

    @Test func Preview_theBubbleBesideTheHeadAndAtTheEdges() throws {
        let store = try evidenceStore("v2/previews")
        for backing in [1, 2] {
            var tiles: [Raster] = []
            let top = PlacementCase.all[3].geometry(scale: 1)
            let left = PlacementCase.all[1].geometry(scale: 1), right = PlacementCase.all[2].geometry(scale: 1)
            for style in BubbleDesign.ids {
                for (name, geometry, around) in [("beside the head, no room above", top, CGRect(x: top.homeOrigin.x - 20, y: top.homeOrigin.y - 40, width: 300, height: 110)),
                                                 ("left screen edge", left, CGRect(x: 0, y: left.homeOrigin.y - 16, width: 300, height: 110)),
                                                 ("right screen edge", right, CGRect(x: 1140, y: right.homeOrigin.y - 16, width: 300, height: 110))] {
                    let (frame, content, now) = bubbleFrame(style, .thinking)
                    let stage = try #require(try stageRenderer.compose(StageRequest(frame: frame, now: now, geometry: geometry, pixelScale: Double(backing), content: content)))
                    let picture = Desktop.crop(stage, around: around, light: style == 6, backing: backing)
                    var out = Raster(width: picture.width, height: picture.height + 10 * 2 * backing)
                    out.blit(label("style \(style) \(name)", width: picture.width, backing: backing), x: 0, y: 0)
                    out.blit(picture, x: 0, y: 10 * 2 * backing)
                    tiles.append(out)
                }
            }
            try store.write(SceneRenderer.png(try sheet(tiles, columns: 3, backing: backing).cgImage()), to: "sheet-placement-\(backing == 1 ? "real" : "2x").png")
        }
    }

    @Test func Preview_clawdsStatesAndLooks() throws {
        let store = try evidenceStore("v2/previews")
        for backing in [1, 2] {
            var tiles: [Raster] = []
            let states: [(String, SchedulerFrame, Double, Bool)] = [
                ("rest", Frames.rest(), 0, false), ("blink", Frames.rest(), 0, true),
                ("listen", Frames.pose("listen", scene: .listening), 0.1, false), ("think", Frames.pose("think", scene: .thinking), 0.1, false),
                ("hop", Frames.pose("hop", scene: .sent), 0.1, false), ("sleep", Frames.pose("sleep", scene: .sleep), 0, false),
                ("drag", Frames.pose("dangle", scene: .drag), 0.1, false),
            ]
            for (name, frame, now, blink) in states {
                tiles.append(try tile(frame, now: now, light: false, backing: backing, name: name, blink: blink))
            }
            for look in ["plain", "helmet", "sunglasses", "headphones"] {
                tiles.append(try tile(Frames.rest(look: look), now: 0, light: true, backing: backing, name: "look \(look)"))
            }
            try store.write(SceneRenderer.png(try sheet(tiles, columns: 3, backing: backing).cgImage()), to: "sheet-states-\(backing == 1 ? "real" : "2x").png")

            // the look change, all 20 frames
            var strip: [Raster] = []
            for k in 0..<LookTransition.frameCount {
                let rising = k >= LookTransition.sinkFrames
                let progress = (Double(k) + 0.5) / Double(LookTransition.frameCount)
                let frame = SchedulerFrame(playback: MotionPlayback(source: .transition(from: rising ? "plain" : "plain", to: rising ? "helmet" : "plain"), use: "transition", startedAt: 0, duration: 1.6),
                                           look: "helmet", displayedLook: rising ? "helmet" : "plain", transitionProgress: progress)
                strip.append(try tile(frame, now: progress * 1.6, light: false, backing: backing, name: "frame \(k)"))
            }
            var narrow: [Raster] = []
            for t in strip {      // keep only the 56 pt around Clawd so 20 frames fit one picture
                var cut = Raster(width: 56 * backing, height: t.height)
                cut.blit(t, x: -20 * backing, y: 0)
                narrow.append(cut)
            }
            try store.write(SceneRenderer.png(try sheet(narrow, columns: 10, backing: backing).cgImage()), to: "sheet-look-change-\(backing == 1 ? "real" : "2x").png")
        }
    }
}
