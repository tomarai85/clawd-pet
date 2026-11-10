import Foundation
import AppKit
import CoreText
import CryptoKit
import ClawdCore

/// The system fonts styles 14 and 15 draw with, resolved from the system and never from a path written here: SF Pro (the system UI font) at weight 500 for
/// 14, SF Mono for 15, and Menlo, which draws 15's prompt and spinner glyphs (SF Mono has none of them; its own cascade picks Menlo for them, so the style names
/// Menlo instead of leaving the choice to the cascade). Nothing is bundled. A font's file is read only to hash it for the smooth sidecar (amendment D-1, D-13).
public enum SmoothFonts {
    static let uiSize: CGFloat = 12, monoSize: CGFloat = 11
    /// 14's tracking: -0.005 em (mock :52).
    static let tracking: CGFloat = -0.005 * 12

    /// SF Pro at weight 500 (the mock's `font: 500 12px -apple-system`).
    static let ui: CTFont = NSFont.systemFont(ofSize: uiSize, weight: .medium) as CTFont
    /// SF Mono, regular (the mock's `ui-monospace, "SF Mono"`).
    static let mono: CTFont = NSFont.monospacedSystemFont(ofSize: monoSize, weight: .regular) as CTFont
    /// 15's marks: the first of these fonts that draws the prompt and all six spinner glyphs.
    static let marks: CTFont = {
        for name in ["Menlo-Regular", "ZapfDingbatsITC"] {
            let font = CTFontCreateWithName(name as CFString, monoSize, nil)
            if "\u{00B7}\u{2722}\u{2733}\u{2736}\u{273B}\u{273D}\u{276F}".allSatisfy({ covers(font, $0) }) { return font }
        }
        return mono
    }()

    /// The font's own glyph exists (a cascade substitute or a LastResort box does not count).
    static func covers(_ font: CTFont, _ character: Character) -> Bool {
        let units = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) && glyphs.allSatisfy { $0 != 0 }
    }

    static func name(_ font: CTFont) -> String { CTFontCopyPostScriptName(font) as String }
    static func fileURL(_ font: CTFont) -> URL? { CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL }
    /// The SHA-256 of the font in use: every table of the font, by tag, with its length. For a font backed by a file this is the file's own content (or
    /// one face of a collection); the system monospaced font has no file URL to read, so the font itself is what is hashed.
    static func fingerprint(_ font: CTFont) -> String {
        let graphics = CTFontCopyGraphicsFont(font, nil)
        var hash = SHA256()
        // the tags are four-character codes stored in the array as plain values, not as objects: read them as integers
        var tags: [UInt32] = []
        if let array = graphics.tableTags {
            for index in 0..<CFArrayGetCount(array) {
                if let value = CFArrayGetValueAtIndex(array, index) { tags.append(UInt32(truncatingIfNeeded: UInt(bitPattern: value))) }
            }
        }
        for tag in tags.sorted() {
            hash.update(data: Data("\(tag):".utf8))
            if let table = graphics.table(for: tag) as Data? { hash.update(data: Data("\(table.count):".utf8)); hash.update(data: table) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The fonts the smooth styles draw with, for the smooth sidecar: each one's file when it has one (read to hash it) and its fingerprint.
    public static func fontFiles() throws -> [SmoothEnvironment.FontFile] {
        try [("ui", ui), ("mono", mono), ("marks", marks)].map { role, font in
            let path = fileURL(font)?.path ?? "system font " + name(font)
            if let url = fileURL(font) { _ = try ReadOnlyFile.data(url.path, limit: 64 * 1024 * 1024) }
            return SmoothEnvironment.FontFile(role: role, path: path, sha256: fingerprint(font))
        }
    }
}
