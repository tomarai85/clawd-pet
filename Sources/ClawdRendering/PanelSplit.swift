import Foundation
import CoreGraphics
import ClawdCore

/// One window's worth of picture: where it goes (global AppKit points, on the device pixel grid) and what it shows.
public struct PanelPicture {
    public let rect: CGRect
    public let image: CGImage
    /// The same picture as device pixels (the tests read it).
    public let pixels: Raster
    public let pixelScale: Double
}

/// Which window a click lands on, decided by structure: a window that takes mouse events exists only where a click is taken.
public enum ClickReceiver: Equatable {
    case body
    case menu
    /// No window of ours is there, or the one there ignores mouse events permanently: the click goes to the app behind.
    case appBehind
}

/// The stage as the windows that show it (spec 4.4, click-through "at the window-server level").
///
/// A window that decides at click time whether it takes the click can lose a race: the pointer moves from Clawd to a transparent pixel
/// and clicks before the process has changed `ignoresMouseEvents`. So the decision is never made at click time. The picture is cut in
/// two pieces that share no pixel:
///   - `body`: exactly the pixels that take clicks (Clawd's body and the costume), in a window as small as their bounds. It takes mouse
///     events, always.
///   - `stage`: everything else (props, effects, the bubble, the transparent rest of the stage) in the window the whole stage used to
///     have. It ignores mouse events, always, so no click can ever land on it.
/// The open menu (Sprint M) has its own rectangle and window; it takes mouse events too.
///
/// One thing this cannot do: inside the body window's bounds, a pixel that is not a body pixel (the gap between two legs) still belongs
/// to the body window, which takes the click and ignores it (v1 did the same). Outside those bounds no window of ours takes a click.
public struct PanelPictures {
    public let stage: PanelPicture
    /// nil when nothing in the picture takes clicks (a look-change frame, say).
    public let body: PanelPicture?
    public let menuRect: CGRect?

    public init(stage: PanelPicture, body: PanelPicture?, menuRect: CGRect?) {
        self.stage = stage; self.body = body; self.menuRect = menuRect
    }

    /// Cuts `frame` in two. Throws only when a CGImage cannot be made.
    public init(_ frame: StageFrame) throws {
        let layout = frame.layout
        let backing = layout.pixelScale
        let panel = layout.panel
        let full = frame.pixels
        let hit = layout.composed.hit
        let factor = layout.cellFactor, origin = layout.clawdPixelOrigin
        // The hit cells' device-pixel edges: the same cut the picture was drawn on (`StageLayout.edges`), so the body window takes exactly its cells.
        let columns = StageLayout.edges(count: hit.width, canvasAt: layout.composed.canvasOrigin.x, cellPixels: layout.cellPixels)
        let rows = StageLayout.edges(count: hit.height, canvasAt: layout.composed.canvasOrigin.y, cellPixels: layout.cellPixels)
        menuRect = layout.menuRect

        var stageData = full.data
        var bodyPicture: PanelPicture?
        if factor > 0, let cells = hit.opaqueBounds {
            // Device-pixel bounds of the hit cells, clipped to the picture.
            let x0 = max(0, origin.x + columns[cells.minX]), y0 = max(0, origin.y + rows[cells.minY])
            let x1 = min(full.width - 1, origin.x + columns[cells.maxX + 1] - 1), y1 = min(full.height - 1, origin.y + rows[cells.maxY + 1] - 1)
            if x0 <= x1, y0 <= y1 {
                let width = x1 - x0 + 1, height = y1 - y0 + 1
                var bodyData = [UInt8](repeating: 0, count: width * height * 4)
                full.data.withUnsafeBufferPointer { source in
                    bodyData.withUnsafeMutableBufferPointer { body in
                        stageData.withUnsafeMutableBufferPointer { rest in
                            for cy in 0..<hit.height {
                                for cx in 0..<hit.width where hit.isOpaque(cx, cy) {
                                    let py0 = max(y0, origin.y + rows[cy]), py1 = min(y1, origin.y + rows[cy + 1] - 1)
                                    let px0 = max(x0, origin.x + columns[cx]), px1 = min(x1, origin.x + columns[cx + 1] - 1)
                                    guard py0 <= py1, px0 <= px1 else { continue }
                                    let count = (px1 - px0 + 1) * 4
                                    for py in py0...py1 {
                                        let from = (py * full.width + px0) * 4, to = ((py - y0) * width + (px0 - x0)) * 4
                                        memcpy(body.baseAddress! + to, source.baseAddress! + from, count)
                                        memset(rest.baseAddress! + from, 0, count)
                                    }
                                }
                            }
                        }
                    }
                }
                let raster = Raster(width: width, height: height, data: bodyData)
                let rect = CGRect(x: panel.minX + Double(x0) / backing, y: panel.maxY - Double(y1 + 1) / backing,
                                  width: Double(width) / backing, height: Double(height) / backing)
                bodyPicture = PanelPicture(rect: rect, image: try raster.cgImage(), pixels: raster, pixelScale: backing)
            }
        }
        body = bodyPicture
        let stageRaster = Raster(width: full.width, height: full.height, data: stageData)
        stage = PanelPicture(rect: panel, image: try stageRaster.cgImage(), pixels: stageRaster, pixelScale: backing)
    }

    /// Every window that takes mouse events, as rectangles in global points.
    public var interactiveRects: [CGRect] { [menuRect, body?.rect].compactMap { $0 } }

    /// The window a click at `point` reaches. The menu is above the body; the stage is never a receiver.
    public func receiver(at point: CGPoint) -> ClickReceiver {
        if let menuRect, menuRect.contains(point) { return .menu }
        if let rect = body?.rect, rect.contains(point) { return .body }
        return .appBehind
    }
}
