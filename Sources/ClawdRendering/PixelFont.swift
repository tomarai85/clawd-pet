import Foundation

/// The one pixel font every bubble draws with. A font pixel is one bubble pixel (2 pt, Clawd's half-unit at size 1), so the
/// text sits on the same grid as the bubble and Clawd: no smooth system font is ever drawn beside the pixel art.
///
/// Geometry: a line is 6 rows. Capitals, digits and ascenders fill rows 0-4, x-height letters rows 1-4, descenders reach
/// row 5. Letters are 3 columns wide (m and w 5, i and l 1); the gap after a glyph is 1 column.
public struct PixelGlyph: Equatable {
    public let top: Int
    public let rows: [String]
    /// Column `c` of row `r` is lit when bit `c` of `bits[r]` is set.
    let bits: [UInt8]
    public let width: Int
    public var advance: Int { width + 1 }
    public init(top: Int, rows: [String]) {
        self.top = top; self.rows = rows; width = rows.map(\.count).max() ?? 0
        bits = rows.map { row in row.enumerated().reduce(UInt8(0)) { $1.element == "X" ? $0 | UInt8(1 << $1.offset) : $0 } }
    }
}

public enum PixelFont {
    public static let lineRows = 6

    private static let table: [UInt32: PixelGlyph] = {
        var t: [UInt32: PixelGlyph] = [:]
        func add(_ c: Character, _ top: Int, _ rows: String) { t[c.unicodeScalars.first!.value] = PixelGlyph(top: top, rows: rows.split(separator: "/", omittingEmptySubsequences: false).map(String.init)) }
        // capitals
        add("A", 0, ".X./X.X/XXX/X.X/X.X"); add("B", 0, "XX./X.X/XX./X.X/XX.")
        add("C", 0, ".XX/X../X../X../.XX"); add("D", 0, "XX./X.X/X.X/X.X/XX.")
        add("E", 0, "XXX/X../XX./X../XXX"); add("F", 0, "XXX/X../XX./X../X..")
        add("G", 0, ".XX/X../X.X/X.X/.XX"); add("H", 0, "X.X/X.X/XXX/X.X/X.X")
        add("I", 0, "XXX/.X./.X./.X./XXX"); add("J", 0, "..X/..X/..X/X.X/.X.")
        add("K", 0, "X.X/X.X/XX./X.X/X.X"); add("L", 0, "X../X../X../X../XXX")
        add("M", 0, "X...X/XX.XX/X.X.X/X...X/X...X"); add("N", 0, "XX./X.X/X.X/X.X/X.X")
        add("O", 0, ".X./X.X/X.X/X.X/.X."); add("P", 0, "XX./X.X/XX./X../X..")
        add("Q", 0, ".X./X.X/X.X/XX./.XX"); add("R", 0, "XX./X.X/XX./X.X/X.X")
        add("S", 0, ".XX/X../.X./..X/XX."); add("T", 0, "XXX/.X./.X./.X./.X.")
        add("U", 0, "X.X/X.X/X.X/X.X/XXX"); add("V", 0, "X.X/X.X/X.X/X.X/.X.")
        add("W", 0, "X...X/X...X/X.X.X/XX.XX/X...X"); add("X", 0, "X.X/X.X/.X./X.X/X.X")
        add("Y", 0, "X.X/X.X/.X./.X./.X."); add("Z", 0, "XXX/..X/.X./X../XXX")
        // lowercase
        add("a", 1, ".XX/X.X/X.X/.XX"); add("b", 0, "X../X../XX./X.X/XX.")
        add("c", 1, ".XX/X../X../.XX"); add("d", 0, "..X/..X/.XX/X.X/.XX")
        add("e", 1, ".XX/XXX/X../.XX"); add("f", 0, ".XX/X../XX./X../X..")
        add("g", 1, ".XX/X.X/.XX/..X/XX."); add("h", 0, "X../X../XX./X.X/X.X")
        add("i", 0, "X/./X/X/X"); add("j", 0, ".X/../.X/.X/.X/X.")
        add("k", 0, "X../X../X.X/XX./X.X"); add("l", 0, "X/X/X/X/X")
        add("m", 1, "XXXXX/X.X.X/X.X.X/X.X.X"); add("n", 1, "XX./X.X/X.X/X.X")
        add("o", 1, "XXX/X.X/X.X/XXX"); add("p", 1, "XX./X.X/XX./X../X..")
        add("q", 1, ".XX/X.X/.XX/..X/..X"); add("r", 1, "XX/X./X./X.")
        add("s", 1, ".XX/X../..X/XX."); add("t", 0, ".X./XXX/.X./.X./..X")
        add("u", 1, "X.X/X.X/X.X/.XX"); add("v", 1, "X.X/X.X/X.X/.X.")
        add("w", 1, "X...X/X.X.X/X.X.X/.X.X."); add("x", 1, "X.X/.X./.X./X.X")
        add("y", 1, "X.X/X.X/.XX/..X/XX."); add("z", 1, "XXX/..X/X../XXX")
        add("é", 0, "..X/.XX/XXX/X../.XX")
        // digits
        add("0", 0, "XXX/X.X/X.X/X.X/XXX"); add("1", 0, ".X./XX./.X./.X./XXX")
        add("2", 0, "XX./..X/.X./X../XXX"); add("3", 0, "XX./..X/.X./..X/XX.")
        add("4", 0, "X.X/X.X/XXX/..X/..X"); add("5", 0, "XXX/X../XX./..X/XX.")
        add("6", 0, ".XX/X../XXX/X.X/XXX"); add("7", 0, "XXX/..X/.X./.X./.X.")
        add("8", 0, "XXX/X.X/XXX/X.X/XXX"); add("9", 0, "XXX/X.X/XXX/..X/XX.")
        // punctuation
        add(" ", 0, "."); add("-", 2, "XXX"); add("'", 0, "X/X"); add(".", 4, "X"); add(",", 4, "X/X"); add(":", 1, "X/././X")
        add("\u{2026}", 4, "X.X.X")              // …
        // Claude Code's own marks
        add("\u{276F}", 0, "X../.X./..X/.X./X..")  // ❯ prompt
        add("\u{23BF}", 0, "X../X../X../X../XXX")  // ⎿ response hook
        add("\u{2588}", 0, "XX/XX/XX/XX/XX")        // block cursor
        add("\u{25CF}", 1, ".X./XXX/.X."); add("\u{23FA}", 1, ".X./XXX/.X.")  // ● reduced-motion spinner, ⏺ sent
        // spinner sequence, small to large: · ✢ ✳ ✶ ✻ ✽
        add("\u{00B7}", 0, "...../...../..X../...../.....")
        add("\u{2722}", 0, "..X../..X../XX.XX/..X../..X..")
        add("\u{2733}", 0, "X...X/.X.X./..X../.X.X./X...X")
        add("\u{2736}", 0, "..X../X.X.X/.XXX./X.X.X/..X..")
        add("\u{273B}", 0, "X.X.X/.XXX./XX.XX/.XXX./X.X.X")
        add("\u{273D}", 0, ".XXX./XXXXX/XX.XX/XXXXX/.XXX.")
        add("*", 0, "X.X.X/.XXX./XXXXX/.XXX./X.X.X")
        return t
    }()
    private static let unknown = PixelGlyph(top: 0, rows: ["XXX", "X.X", "X.X", "X.X", "XXX"])

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
