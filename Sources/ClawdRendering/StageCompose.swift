import Foundation
import ClawdCore

/// One finished picture of Clawd in a look: the pixels, the 24 x 24 canvas inside them, the head anchor, and which pixels take clicks.
public struct ComposedClawd {
    /// Cell resolution; covers the canvas, the clip's stage and every look layer.
    public let raster: Raster
    /// Where the canvas' top-left cell sits inside `raster`.
    public let canvasOrigin: CellPoint
    /// The head anchor in canvas cells (nil: the frame is not front-facing). After a mirror this is the mirrored anchor.
    public let head: CellPoint?
    /// Opaque where a click is taken: Clawd's body pixels and the costume pixels. Same size as `raster`.
    public let hit: Raster
    /// Canvas row of the top of the torso, or of the worn costume when that is higher (spec 4.4 anchor H).
    public let headTopRow: Int?
    /// Canvas column (a cell edge) of the centre of the torso's top row.
    public let headCentreColumn: Int?
    /// Canvas row of the vertical centre of the body's six rows (a cell edge).
    public let bodyCentreRow: Int?
    /// Canvas row (a cell edge) of the bottom of the lowest opaque cell of the picture in the torso's column band (spec amendment D-3, anchor F): the
    /// bottom of the feet, or of an item that hangs under them. nil when the frame has no head anchor.
    public let feetBottomRow: Int?
    public var canvasRect: (x: Int, y: Int, width: Int, height: Int) { (canvasOrigin.x, canvasOrigin.y, StageGeometry.canvasCells, StageGeometry.canvasCells) }
}

public enum StageCompose {
    static let orange = Pixel(215, 119, 87), shade = Pixel(190, 104, 77), shadeB = Pixel(191, 105, 77), eye = Pixel(20, 20, 19)
    static func isBodyColour(_ p: Pixel) -> Bool { p == orange || p == shade || p == shadeB }

    /// Clawd's own pixels in a frame: the body colours, and the eyes where they sit inside the torso (a black prop pixel is not Clawd).
    static func bodyMask(_ frame: ClipFrame, left: Int, up: Int) -> Raster {
        let r = frame.raster
        var mask = Raster(width: r.width, height: r.height)
        for y in 0..<r.height { for x in 0..<r.width {
            let p = r[x, y]
            guard p.a == 255 else { continue }
            var body = isBodyColour(p)
            if !body, p == eye {
                if let head = frame.head {
                    let tx = head.x - StageGeometry.torsoHalfWidth + left, ty = head.y + up
                    body = x >= tx && x < tx + 2 * StageGeometry.torsoHalfWidth && y >= ty && y < ty + StageGeometry.torsoRows
                } else {
                    let near = [(1, 0), (-1, 0), (0, 1), (0, -1)].filter { isBodyColour(r[x + $0.0, y + $0.1]) }.count
                    body = near >= 2
                }
            }
            if body { mask[x, y] = Pixel(0, 0, 0, 255) }
        } }
        return mask
    }

    /// Composes a clip frame in a look. `layersOn` is false on a look's signature motion (it draws the prop itself).
    public static func compose(clip: Clip, frameIndex: Int, look: LookArt, layersOn: Bool = true, mirrored: Bool = false) -> ComposedClawd {
        let frame = clip.frames[min(max(0, frameIndex), clip.frames.count - 1)]
        let canvas = StageGeometry.canvasCells
        let raise = look.raise
        let drawn = layersOn ? look.layers : []
        let head = frame.head.map { CellPoint($0.x, $0.y - raise) }

        // Everything in canvas coordinates first.
        struct Placed { let raster: Raster; let x: Int; let y: Int; let hit: Bool; let z: LookArt.Z }
        var placed: [Placed] = []
        for layer in drawn {
            let origin: CellPoint
            switch layer.anchor {
            case .head: guard let head else { continue }; origin = CellPoint(head.x + layer.offset.x, head.y + layer.offset.y)
            case .canvas: origin = layer.offset
            case .feet: origin = CellPoint(layer.offset.x, canvas + layer.offset.y)
            }
            placed.append(Placed(raster: layer.raster, x: origin.x, y: origin.y, hit: layer.takesClicks, z: layer.z))
        }
        let baseX = -clip.left, baseY = -clip.up - raise
        var minX = min(0, baseX), minY = min(0, baseY), maxX = max(canvas, baseX + frame.raster.width), maxY = max(canvas, baseY + frame.raster.height)
        for p in placed { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x + p.raster.width); maxY = max(maxY, p.y + p.raster.height) }

        var picture = Raster(width: maxX - minX, height: maxY - minY)
        var hit = Raster(width: picture.width, height: picture.height)
        let body = bodyMask(frame, left: clip.left, up: clip.up)
        let recoloured = frame.raster.recoloured(look.bodyMap)
        for p in placed where p.z == .back { picture.blit(p.raster, x: p.x - minX, y: p.y - minY) }
        picture.blit(recoloured, x: baseX - minX, y: baseY - minY)
        for p in placed where p.z == .front { picture.blit(p.raster, x: p.x - minX, y: p.y - minY) }
        hit.blit(body, x: baseX - minX, y: baseY - minY)
        for p in placed where p.hit { hit.blit(opaqueMask(p.raster), x: p.x - minX, y: p.y - minY) }

        var origin = CellPoint(-minX, -minY)
        var headOut = head
        if mirrored {
            picture = picture.flippedHorizontally(); hit = hit.flippedHorizontally()
            origin = CellPoint(picture.width - (origin.x + canvas), origin.y)
            headOut = head.map { CellPoint(canvas - $0.x, $0.y) }
        }
        return finish(picture: picture, hit: hit, origin: origin, head: headOut, costume: placed.filter(\.hit).compactMap { p in
            p.raster.opaqueBounds.map { p.y + $0.minY }
        }.min().map { $0 }, mirrored: mirrored)
    }

    private static func opaqueMask(_ raster: Raster) -> Raster {
        var out = Raster(width: raster.width, height: raster.height)
        for y in 0..<raster.height { for x in 0..<raster.width where raster.isOpaque(x, y) { out[x, y] = Pixel(0, 0, 0, 255) } }
        return out
    }

    /// Anchors derived from the finished masks.
    static func finish(picture: Raster, hit: Raster, origin: CellPoint, head: CellPoint?, costume: Int?, mirrored: Bool) -> ComposedClawd {
        var headTop: Int?, centreColumn: Int?, bodyCentre: Int?
        if let head {
            headTop = min(head.y, costume ?? head.y)
            centreColumn = head.x
            bodyCentre = head.y + StageGeometry.torsoHalf
        } else if let bounds = hit.opaqueBounds {
            // Not front-facing: the top of whatever is Clawd, centred on that top row.
            let top = bounds.minY - origin.y
            var lo = Int.max, hi = -1
            for x in 0..<hit.width where hit.isOpaque(x, bounds.minY) { lo = min(lo, x); hi = max(hi, x) }
            headTop = min(top, costume ?? top)
            centreColumn = (lo + hi + 1) / 2 - origin.x
            bodyCentre = top + StageGeometry.torsoHalf
        }
        return ComposedClawd(raster: picture, canvasOrigin: origin, head: head, hit: hit, headTopRow: headTop,
                             headCentreColumn: centreColumn, bodyCentreRow: bodyCentre,
                             feetBottomRow: feetBottom(picture: picture, origin: origin, headTop: headTop, centreColumn: centreColumn))
    }

    /// Anchor F: the bottom edge of the lowest opaque cell of the picture within `torsoHalfWidth` cells either side of the torso's centre column.
    /// Where the band holds no opaque cell, the torso's own bottom edge.
    static func feetBottom(picture: Raster, origin: CellPoint, headTop: Int?, centreColumn: Int?) -> Int? {
        guard let headTop, let centreColumn else { return nil }
        let lo = max(0, origin.x + centreColumn - StageGeometry.torsoHalfWidth), hi = min(picture.width, origin.x + centreColumn + StageGeometry.torsoHalfWidth)
        var lowest = -1
        for y in 0..<picture.height { for x in lo..<max(lo, hi) where picture.isOpaque(x, y) { lowest = y; break } }
        return lowest < 0 ? headTop + StageGeometry.torsoRows : lowest + 1 - origin.y
    }
}
