import Foundation
import CoreGraphics

/// Where a click is taken (spec 4.4): Clawd's body pixels, his costume pixels, and the menu's rectangle while it is open.
/// A prop, an effect, a transparent pixel and the bubble are not part of it: a click there goes to the app behind.
public struct HitRegion {
    /// Opaque where a click is taken, at cell resolution.
    public let raster: Raster
    /// Global point of the raster's top-left corner (y up: its top edge).
    public let topLeft: CGPoint
    public let cellPt: Double
    public var menuRect: CGRect?

    public init(raster: Raster, topLeft: CGPoint, cellPt: Double, menuRect: CGRect? = nil) {
        self.raster = raster; self.topLeft = topLeft; self.cellPt = cellPt; self.menuRect = menuRect
    }

    public func containsBody(_ point: CGPoint) -> Bool {
        let x = Int(((point.x - topLeft.x) / cellPt).rounded(.down)), y = Int(((topLeft.y - point.y) / cellPt).rounded(.down))
        return point.x >= topLeft.x && point.y <= topLeft.y && raster.isOpaque(x, y)
    }
    public func contains(_ point: CGPoint) -> Bool {
        containsBody(point) || (menuRect?.contains(point) ?? false)
    }
    /// Bounding rectangle of the body and costume pixels (the `hit=` field of the agent's GEOM line), nil when nothing takes clicks.
    public var bounds: CGRect? {
        guard let b = raster.opaqueBounds else { return nil }
        return CGRect(x: topLeft.x + Double(b.minX) * cellPt, y: topLeft.y - Double(b.maxY + 1) * cellPt,
                      width: Double(b.maxX - b.minX + 1) * cellPt, height: Double(b.maxY - b.minY + 1) * cellPt)
    }
}
