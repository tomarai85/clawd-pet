import Foundation
import CoreGraphics
import ClawdCore
import ClawdRendering

/// One shared renderer for the stage tests: it decodes the art once.
let stageRenderer: StageRenderer = {
    do { return try StageRenderer(art: artDirectory) } catch { fatalError("stage art unreadable: \(error)") }
}()

/// A 1440 x 900 display with a 30 pt menu bar and an 80 pt Dock, like the scheduler fixture.
enum Screens {
    static let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    static let visible = CGRect(x: 0, y: 80, width: 1440, height: 790)
    static func geometry(scale: Double = 1, homeX: Double = 576, homeY: Double = 100, display: CGRect = Screens.display,
                         visible: CGRect = Screens.visible) -> PetGeometry {
        PetGeometry(scale: scale, homeOrigin: CGPoint(x: homeX, y: homeY), displayFrame: display, visibleFrame: visible)
    }
}

/// Frames the scheduler would hand the renderer.
enum Frames {
    static func rest(look: String = "plain", bubble: BubbleState? = nil, scene: Scene = .idle) -> SchedulerFrame {
        SchedulerFrame(scene: scene, look: look, bubble: bubble)
    }
    static func pose(_ name: String, scene: Scene, look: String = "plain", bubble: BubbleState? = nil, startedAt: Double = 0) -> SchedulerFrame {
        SchedulerFrame(scene: scene, playback: MotionPlayback(source: .pose(name), use: scene.rawValue, startedAt: startedAt, duration: 1, loops: true),
                       look: look, bubble: bubble)
    }
    static func motion(_ id: String, look: String = "plain", startedAt: Double = 0, duration: Double = 100, loops: Bool = false) -> SchedulerFrame {
        SchedulerFrame(playback: MotionPlayback(source: .motion(id), use: "idle", startedAt: startedAt, duration: duration, loops: loops), look: look)
    }
}

/// A made-up piece of desktop (a terminal and a light window with a status line) so a preview shows the bubble where it will be seen.
enum Desktop {
    static func crop(_ stage: StageFrame, around: CGRect, light: Bool, backing: Int = 1) -> Raster {
        let scale = Double(backing)
        let w = Int(around.width * scale), h = Int(around.height * scale)
        var picture = Raster(width: w, height: h)
        let bg = light ? Pixel(rgb: 0xF2F0EA) : Pixel(rgb: 0x1E1E1C)
        let ink = light ? Pixel(rgb: 0x9A978E) : Pixel(rgb: 0x6B6A64)
        picture.fill(x: 0, y: 0, width: w, height: h, bg)
        // text lines and a status line near the bottom
        var y = 6 * backing
        while y < h - 40 * backing {
            let width = Int(Double(60 + (y / backing * 37) % 150) * scale)
            picture.fill(x: 10 * backing, y: y, width: min(w - 20 * backing, width), height: 3 * backing, ink)
            y += 12 * backing
        }
        picture.fill(x: 0, y: h - 22 * backing, width: w, height: 22 * backing, light ? Pixel(rgb: 0xDAD6CB) : Pixel(rgb: 0x2C2C29))
        picture.fill(x: 10 * backing, y: h - 14 * backing, width: Int(140 * scale), height: 3 * backing, ink)
        let x = Int(((stage.panelFrame.minX - around.minX) * scale).rounded()), top = Int(((around.maxY - stage.panelFrame.maxY) * scale).rounded())
        picture.blit(stage.pixels, x: x, y: top)
        return picture
    }
}

func savePNG(_ raster: Raster, scratch name: String, in directory: URL) throws {
    let state = try OwnState(root: directory)
    try state.write(SceneRenderer.png(try raster.cgImage()), to: name)
}
