import Foundation
import CoreText
import ClawdCore

/// What a smooth style's text needs of the fonts and of its design: which font draws which character, how wide a line is, and the attributed string that is
/// drawn.
extension SmoothFonts {
    static func kind(_ design: BubbleDesign) -> SmoothKind { design.smooth ?? .macOS }
    static func primary(_ design: BubbleDesign) -> CTFont { kind(design) == .macOS ? ui : mono }

    /// Where a character of a smooth style's text comes from.
    public enum Source: Equatable { case font(String), shape, missing }
    /// The font that draws `character` in `design`, or nil when the style draws it as a shape.
    static func font(for character: Character, in design: BubbleDesign) -> CTFont? {
        let primary = primary(design)
        if covers(primary, character) { return primary }
        if kind(design) == .terminal, covers(marks, character) { return marks }
        return nil
    }
    public static func source(of character: Character, design: BubbleDesign) -> Source {
        if let font = font(for: character, in: design) { return .font(name(font)) }
        return shapeCharacters(design).contains(character) ? .shape : .missing
    }
    /// The characters a style draws as shapes instead of text: 14 draws every mark of Claude Code's lines as a stroke or a disc; 15 draws the response hook
    /// and the dots (no font it names has them).
    static func shapeCharacters(_ design: BubbleDesign) -> Set<Character> {
        kind(design) == .macOS ? ["\u{276F}", "\u{23BF}", "\u{25CF}", "\u{273B}", "\u{00B7}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273D}", "\u{23FA}"] : ["\u{23BF}", "\u{25CF}", "\u{23FA}"]
    }

    /// One monospaced character cell of 15's text, in points.
    static func cellWidth(for kind: SmoothKind) -> Double { kind == .terminal ? width(of: "M", font: mono) : 0 }

    static func width(of text: String, design: BubbleDesign) -> Double { width(of: attributed(text, design: design)) }
    static func width(of text: String, font: CTFont) -> Double { width(of: NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])) }
    static func width(of attributed: NSAttributedString) -> Double { CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil) }

    /// The text as an attributed string with the font of each character named explicitly, so that CoreText never cascades. `colour` paints every character,
    /// `glint` (an index range of the text) paints those characters in `glintColour`.
    static func attributed(_ text: String, design: BubbleDesign, colour: CGColor? = nil, glint: ClosedRange<Int>? = nil, glintColour: CGColor? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, character) in text.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font(for: character, in: design) ?? primary(design)
            ]
            if kind(design) == .macOS { attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = tracking }
            if let colour { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = (glint?.contains(i) == true ? glintColour : nil) ?? colour }
            out.append(NSAttributedString(string: String(character), attributes: attributes))
        }
        return out
    }
}
