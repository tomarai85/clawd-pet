import Foundation
import CoreGraphics
import ClawdCore

/// What the menu shows besides its layout: the selected values, the row and the item under the pointer, and the item that has just been
/// picked and flashes for 140 ms before the menu closes.
public struct MenuVisual: Equatable {
    public var selection: MenuSelection
    /// Index into `MenuLayout.rows`.
    public var hoverRow: Int?
    /// Index into `MenuLayout.items`.
    public var hoverItem: Int?
    public var flashItem: Int?
    public init(selection: MenuSelection = MenuSelection(), hoverRow: Int? = nil, hoverItem: Int? = nil, flashItem: Int? = nil) {
        self.selection = selection; self.hoverRow = hoverRow; self.hoverItem = hoverItem; self.flashItem = flashItem
    }
}

/// The picture of the look tiles: Clawd's rest pose in each look, the 24 x 24 cells of his canvas, one cell to the point (24 pt).
public enum MenuThumbnails {
    public static func thumbnail(look id: String, art: ClawdArt) throws -> Raster {
        let composed = StageCompose.compose(clip: try art.pose("idle"), frameIndex: 0, look: try art.look(id))
        var picture = Raster(width: StageGeometry.canvasCells, height: StageGeometry.canvasCells)
        picture.blit(composed.raster, x: -composed.canvasOrigin.x, y: -composed.canvasOrigin.y)
        return picture
    }
    /// Every look that can be drawn; a look whose art cannot be read is left out (its tile shows nothing and still picks).
    public static func all(looks: [String], art: ClawdArt) -> [String: Raster] {
        var result: [String: Raster] = [:]
        for id in looks { if let picture = try? thumbnail(look: id, art: art) { result[id] = picture } }
        return result
    }
}

/// Draws the menu in the pet's pixel language: a 1 pt edge with notched corners, the pet's own pixel font (one font pixel = 2 pt), and the
/// mock's colours. Everything is composed with integer arithmetic at one pixel to the point, then enlarged by whole device pixels, so the
/// picture is the same on every Mac.
public enum MenuRenderer {
    /// One pixel to the point.
    public static func renderPoints(layout: MenuLayout, visual: MenuVisual, thumbnails: [String: Raster]) -> Raster {
        let width = Int(layout.size.width), height = Int(layout.size.height)
        var picture = Raster(width: width, height: height)

        // The edge, then the face one pixel inside it; each loses its four corner pixels (the notches).
        fillNotched(&picture, x: 0, y: 0, width: width, height: height, MenuColors.edge, corner: .clear)
        fillNotched(&picture, x: 1, y: 1, width: width - 2, height: height - 2, MenuColors.face, corner: MenuColors.edge)

        if let hover = visual.hoverRow, layout.rows.indices.contains(hover) {
            let rect = layout.rows[hover].rect
            picture.fill(x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), height: Int(rect.height), MenuColors.rowHover)
        }
        for row in layout.rows where !row.label.isEmpty {
            text(row.label, into: &picture, x: row.labelOrigin.x, y: row.labelOrigin.y, color: MenuColors.ink)
        }
        let sep = layout.separator
        picture.fill(x: Int(sep.minX), y: Int(sep.minY), width: Int(sep.width), height: Int(sep.height), MenuColors.separator)

        for (index, item) in layout.items.enumerated() {
            let selected = visual.selection.isSelected(item)
            let hovered = visual.hoverItem == index && item.clickable
            let flashed = visual.flashItem == index
            let rect = item.rect
            switch item.kind {
            case .chip, .styleChip:
                var ink = item.clickable ? MenuColors.ink : MenuColors.muted
                var background: Pixel?
                if hovered { background = MenuColors.chipHover }
                if selected { background = MenuColors.on; ink = MenuColors.onInk }
                if flashed { background = MenuColors.flash; ink = MenuColors.onInk }
                if let background {
                    picture.fill(x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), height: Int(rect.height), background)
                }
                let textWidth = MenuLayout.textWidth(item.label)
                let x = item.kind == .styleChip ? rect.minX + ((rect.width - textWidth) / 2).rounded(.down) : rect.minX + MenuMetrics.chipPaddingX
                text(item.label, into: &picture, x: x, y: rect.minY + 2, color: ink)
            case .tile:
                if hovered { picture.fill(x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), height: Int(rect.height), MenuColors.chipHover) }
                if selected { border(&picture, rect: rect, MenuColors.on) }
                if item.value == "random" {
                    // The ✻ is 5 font pixels wide and 6 rows high, centred in the 24 pt picture area inside the 1 pt border.
                    let w = MenuLayout.textWidth(item.label)
                    text(item.label, into: &picture, x: rect.minX + 1 + ((MenuMetrics.thumbnail - w) / 2).rounded(.down),
                         y: rect.minY + 1 + ((MenuMetrics.thumbnail - Double(PixelFont.lineRows) * MenuMetrics.fontPixel) / 2).rounded(.down), color: MenuColors.on)
                } else if let thumbnail = thumbnails[item.value] {
                    picture.blit(thumbnail, x: Int(rect.minX) + 1, y: Int(rect.minY) + 1)
                }
            case .action:
                text(item.label, into: &picture, x: layout.rows[item.row].labelOrigin.x, y: layout.rows[item.row].labelOrigin.y, color: MenuColors.ink)
            }
        }
        return picture
    }

    /// The picture at device pixels: the point picture enlarged by the display's whole pixel factor (1 or 2 today).
    public static func render(layout: MenuLayout, visual: MenuVisual, thumbnails: [String: Raster], pixelScale: Double) -> Raster {
        renderPoints(layout: layout, visual: visual, thumbnails: thumbnails).upscaled(by: max(1, min(4, Int(pixelScale.rounded()))))
    }

    /// A filled rectangle without its four corner pixels, which get `corner` (clear for the edge, the edge colour for the face on top of it).
    private static func fillNotched(_ picture: inout Raster, x: Int, y: Int, width: Int, height: Int, _ color: Pixel, corner: Pixel) {
        guard width > 2, height > 2 else { return }
        picture.fill(x: x, y: y, width: width, height: height, color)
        for (cx, cy) in [(x, y), (x + width - 1, y), (x, y + height - 1), (x + width - 1, y + height - 1)] { picture[cx, cy] = corner }
    }

    private static func border(_ picture: inout Raster, rect: CGRect, _ color: Pixel) {
        let x = Int(rect.minX), y = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        picture.fill(x: x, y: y, width: w, height: 1, color); picture.fill(x: x, y: y + h - 1, width: w, height: 1, color)
        picture.fill(x: x, y: y, width: 1, height: h, color); picture.fill(x: x + w - 1, y: y, width: 1, height: h, color)
    }

    /// Pixel text, one font pixel = 2 x 2 pixels of the point picture.
    private static func text(_ string: String, into picture: inout Raster, x: Double, y: Double, color: Pixel) {
        let columns = PixelFont.width(of: string)
        guard columns > 0 else { return }
        var small = Raster(width: columns, height: PixelFont.lineRows)
        PixelFont.draw(string, into: &small, x: 0, y: 0, color: color)
        picture.blit(small.upscaled(by: Int(MenuMetrics.fontPixel)), x: Int(x), y: Int(y))
    }
}
