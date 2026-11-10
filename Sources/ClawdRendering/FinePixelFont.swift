import Foundation

/// Which pixel font a bubble style draws with. A style names its face; today's styles keep `.classic`.
public enum PixelFace: Equatable {
    /// The 6-row font of styles 1-12 (`PixelFont`).
    case classic
    /// The 10-row font of style 13 (`FinePixelFont`): twice the detail at 1 pt pixels.
    case fine

    public var lineRows: Int { self == .classic ? PixelFont.lineRows : FinePixelFont.lineRows }
    public func glyph(_ character: Character) -> PixelGlyph { self == .classic ? PixelFont.glyph(character) : FinePixelFont.glyph(character) }
    public func supports(_ character: Character) -> Bool { self == .classic ? PixelFont.supports(character) : FinePixelFont.supports(character) }
    /// Width in columns of `text`, without the gap after the last glyph.
    public func width(of text: String) -> Int { self == .classic ? PixelFont.width(of: text) : FinePixelFont.width(of: text) }
    @discardableResult
    public func draw(_ text: String, into raster: inout Raster, x: Int, y: Int, color: Pixel) -> Int {
        self == .classic ? PixelFont.draw(text, into: &raster, x: x, y: y, color: color) : FinePixelFont.draw(text, into: &raster, x: x, y: y, color: color)
    }
}

/// Style 13's pixel font, drawn at 1 pt per pixel. The glyphs of the board's mock (bubble-mock.html, `BF`) are kept as drawn; every other
/// glyph is drawn in the same hand.
///
/// Geometry: a line is 10 rows. Capitals, digits and ascenders fill rows 0-7, x-height letters rows 2-7, descenders reach rows 8-9. Lowercase
/// letters are 5 columns (m and w 7, i and l 1, k and f and r and t 4), capitals 5 (I 3, M and W 7); the gap after a glyph is 1 column.
public enum FinePixelFont {
    public static let lineRows = 10

    private static let table: [UInt32: PixelGlyph] = {
        var t: [UInt32: PixelGlyph] = [:]
        func add(_ c: Character, _ top: Int, _ rows: String) {
            t[c.unicodeScalars.first!.value] = PixelGlyph(top: top, rows: rows.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
        }
        // capitals
        add("A", 0, ".XXX./X...X/X...X/X...X/XXXXX/X...X/X...X/X...X"); add("B", 0, "XXXX./X...X/X...X/XXXX./X...X/X...X/X...X/XXXX.")
        add("C", 0, ".XXX./X...X/X..../X..../X..../X..../X...X/.XXX."); add("D", 0, "XXXX./X...X/X...X/X...X/X...X/X...X/X...X/XXXX.")
        add("E", 0, "XXXXX/X..../X..../XXXX./X..../X..../X..../XXXXX"); add("F", 0, "XXXXX/X..../X..../XXXX./X..../X..../X..../X....")
        add("G", 0, ".XXX./X...X/X..../X.XXX/X...X/X...X/X...X/.XXX."); add("H", 0, "X...X/X...X/X...X/XXXXX/X...X/X...X/X...X/X...X")
        add("I", 0, "XXX/.X./.X./.X./.X./.X./.X./XXX"); add("J", 0, "....X/....X/....X/....X/....X/X...X/X...X/.XXX.")
        add("K", 0, "X...X/X...X/X..X./X.X../XX.../X.X../X..X./X...X"); add("L", 0, "X..../X..../X..../X..../X..../X..../X..../XXXXX")
        add("M", 0, "X.....X/XX...XX/X.X.X.X/X..X..X/X.....X/X.....X/X.....X/X.....X")
        add("N", 0, "X...X/XX..X/XX..X/X.X.X/X.X.X/X..XX/X..XX/X...X"); add("O", 0, ".XXX./X...X/X...X/X...X/X...X/X...X/X...X/.XXX.")
        add("P", 0, "XXXX./X...X/X...X/X...X/XXXX./X..../X..../X...."); add("Q", 0, ".XXX./X...X/X...X/X...X/X...X/X.X.X/X..X./.XX.X")
        add("R", 0, "XXXX./X...X/X...X/X...X/XXXX./X.X../X..X./X...X"); add("S", 0, ".XXXX/X..../X..../.XXX./....X/....X/X...X/XXXX.")
        add("T", 0, "XXXXX/..X../..X../..X../..X../..X../..X../..X.."); add("U", 0, "X...X/X...X/X...X/X...X/X...X/X...X/X...X/.XXX.")
        add("V", 0, "X...X/X...X/X...X/X...X/X...X/.X.X./.X.X./..X.."); add("W", 0, "X.....X/X.....X/X.....X/X.....X/X..X..X/X..X..X/XX.X.XX/.X...X.")
        add("X", 0, "X...X/X...X/.X.X./..X../..X../.X.X./X...X/X...X"); add("Y", 0, "X...X/X...X/.X.X./..X../..X../..X../..X../..X..")
        add("Z", 0, "XXXXX/....X/...X./...X./..X../.X.../X..../XXXXX")
        // lowercase
        add("a", 2, ".XXX./....X/.XXXX/X...X/X...X/.XXXX"); add("b", 0, "X..../X..../XXXX./X...X/X...X/X...X/X...X/XXXX.")
        add("c", 2, ".XXX./X...X/X..../X..../X...X/.XXX."); add("d", 0, "....X/....X/.XXXX/X...X/X...X/X...X/X...X/.XXXX")
        add("e", 2, ".XXX./X...X/XXXXX/X..../X...X/.XXX."); add("f", 0, "..XX/.X../.X../XXX./.X../.X../.X../.X..")
        add("g", 2, ".XXXX/X...X/X...X/X...X/X...X/.XXXX/....X/.XXX."); add("h", 0, "X..../X..../XXXX./X...X/X...X/X...X/X...X/X...X")
        add("i", 0, "X/./X/X/X/X/X/X"); add("j", 0, "..X/.../..X/..X/..X/..X/..X/..X/..X/XX.")
        add("k", 0, "X.../X.../X..X/X.X./XX../XX../X.X./X..X"); add("l", 0, "X/X/X/X/X/X/X/X")
        add("m", 2, "XXX.XX./X..X..X/X..X..X/X..X..X/X..X..X/X..X..X"); add("n", 2, "XXXX./X...X/X...X/X...X/X...X/X...X")
        add("o", 2, ".XXX./X...X/X...X/X...X/X...X/.XXX."); add("p", 2, "XXXX./X...X/X...X/X...X/X...X/XXXX./X..../X....")
        add("q", 2, ".XXXX/X...X/X...X/X...X/X...X/.XXXX/....X/....X"); add("r", 2, "X.XX/XX../X.../X.../X.../X...")
        add("s", 2, ".XXXX/X..../.XXX./....X/....X/XXXX."); add("t", 1, ".X../XXX./.X../.X../.X../.X.X/..XX")
        add("u", 2, "X...X/X...X/X...X/X...X/X...X/.XXXX"); add("v", 2, "X...X/X...X/X...X/X...X/.X.X./..X..")
        add("w", 2, "X.....X/X..X..X/X..X..X/X..X..X/X.X.X.X/.X...X."); add("x", 2, "X...X/.X.X./..X../..X../.X.X./X...X")
        add("y", 2, "X...X/X...X/X...X/X...X/.XXXX/....X/....X/.XXX."); add("z", 2, "XXXXX/....X/...X./..X../.X.../XXXXX")
        add("é", 0, "...X./..X../.XXX./X...X/XXXXX/X..../X...X/.XXX.")
        // digits
        add("0", 0, ".XXX./X...X/X..XX/X.X.X/XX..X/X...X/X...X/.XXX."); add("1", 0, "..X../.XX../..X../..X../..X../..X../..X../.XXX.")
        add("2", 0, ".XXX./X...X/....X/...X./..X../.X.../X..../XXXXX"); add("3", 0, ".XXX./X...X/....X/..XX./....X/....X/X...X/.XXX.")
        add("4", 0, "...X./..XX./.X.X./X..X./XXXXX/...X./...X./...X."); add("5", 0, "XXXXX/X..../X..../XXXX./....X/....X/X...X/.XXX.")
        add("6", 0, ".XXX./X..../X..../XXXX./X...X/X...X/X...X/.XXX."); add("7", 0, "XXXXX/....X/...X./...X./..X../..X../.X.../.X...")
        add("8", 0, ".XXX./X...X/X...X/.XXX./X...X/X...X/X...X/.XXX."); add("9", 0, ".XXX./X...X/X...X/X...X/.XXXX/....X/....X/.XXX.")
        // punctuation: a space is 3 columns, so a word gap (3 + two column gaps) is as wide as the classic font's 4 pt
        add(" ", 0, "..."); add("-", 4, "XXXX"); add("'", 0, "X/X/X"); add(".", 6, "XX/XX"); add(",", 6, "XX/XX/X."); add(":", 2, "XX/XX/../../XX/XX")
        add("\u{2026}", 6, "XX.XX.XX/XX.XX.XX")      // …
        add("*", 1, "X.X.X/.XXX./XXXXX/.XXX./X.X.X")
        // Claude Code's own marks: the board's mock as drawn
        add("\u{276F}", 1, "XX.../.XX../..XX./...XX/..XX./.XX../XX...")    // ❯ prompt
        add("\u{2588}", 0, "XXXX/XXXX/XXXX/XXXX/XXXX/XXXX/XXXX/XXXX/XXXX")  // block cursor
        add("\u{00B7}", 1, "......./......./......./...X.../......./......./.......")
        add("\u{2722}", 1, "......./...X.../...X.../.XX.XX./...X.../...X.../.......")
        add("\u{2733}", 1, "......./.X.X.X./..XXX../.XX.XX./..XXX../.X.X.X./.......")
        add("\u{2736}", 1, "...X.../.X.X.X./..XXX../XXX.XXX/..XXX../.X.X.X./...X...")
        add("\u{273B}", 1, "X..X..X/.X.X.X./..X.X../XX...XX/..X.X../.X.X.X./X..X..X")
        add("\u{273D}", 1, "X..X..X/.X.X.X./..XXX../XXXXXXX/..XXX../.X.X.X./X..X..X")
        // not in the mock, drawn in its hand: ⎿ the response hook, ● the reduced-motion dot and ⏺ (a 7 x 7 disc, the spinner's slot)
        add("\u{23BF}", 0, "X.../X.../X.../X.../X.../X.../X.../XXXX")
        add("\u{25CF}", 1, "..XXX../.XXXXX./XXXXXXX/XXXXXXX/XXXXXXX/.XXXXX./..XXX.."); add("\u{23FA}", 1, "..XXX../.XXXXX./XXXXXXX/XXXXXXX/XXXXXXX/.XXXXX./..XXX..")
        return t
    }()
    private static let unknown = PixelGlyph(top: 0, rows: ["XXXXX", "X...X", "X...X", "X...X", "X...X", "X...X", "X...X", "XXXXX"])

    public static func glyph(_ character: Character) -> PixelGlyph { character.unicodeScalars.first.flatMap { table[$0.value] } ?? unknown }
    public static func supports(_ character: Character) -> Bool { character.unicodeScalars.first.map { table[$0.value] != nil } ?? false }

    /// Width in columns of `text`, without the gap after the last glyph.
    public static func width(of text: String) -> Int {
        var total = 0, count = 0
        for scalar in text.unicodeScalars { total += (table[scalar.value] ?? unknown).advance; count += 1 }
        return count == 0 ? 0 : total - 1
    }

    /// Draws one run with its top-left at (x, y); returns the x after the run's last gap.
    @discardableResult
    public static func draw(_ text: String, into raster: inout Raster, x: Int, y: Int, color: Pixel) -> Int {
        var cursor = x
        for scalar in text.unicodeScalars {
            let g = table[scalar.value] ?? unknown
            for row in 0..<g.bits.count {
                let line = g.bits[row]
                for column in 0..<g.width where line & UInt8(1 << column) != 0 { raster[cursor + column, y + g.top + row] = color }
            }
            cursor += g.advance
        }
        return cursor
    }
}
