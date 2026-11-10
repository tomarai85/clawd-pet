import AppKit

/// The chat terminal's look: the terminal colours, font and panel chrome, following Orca's floating terminal (see THIRD-PARTY-NOTICES.md).
/// Pure data and AppKit values; the one file that applies them to SwiftTerm is ChatTerminalView.swift.
public struct ChatLook {
    public struct RGB: Equatable {
        public let r: UInt8, g: UInt8, b: UInt8
        public init(_ hex: UInt32) { r = UInt8((hex >> 16) & 0xFF); g = UInt8((hex >> 8) & 0xFF); b = UInt8(hex & 0xFF) }
        public var color: NSColor { color(alpha: 1) }
        public func color(alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: alpha)
        }
    }

    public let isDark: Bool
    public let background: RGB, foreground: RGB, cursor: RGB, cursorText: RGB, selection: RGB
    /// Black, red, green, yellow, blue, magenta, cyan, white, then the eight bright ones.
    public let ansi: [RGB]
    /// The title bar's fill (Orca's `--card`) and its bottom border colour (`--border`).
    public let titleFill: RGB
    public let titleBorder: NSColor
    public let titleText: RGB
    /// The one tab's fill: the foreground at 6 % over the card (Orca's `getTabRootStateClasses` for the active tab).
    public let tabFill: RGB
    /// The close button's glyph colour and its hover fill (Orca's ghost icon button: no fill and no border at rest, `--accent` on hover).
    public let buttonText: RGB, buttonHover: NSColor
    /// The panel's 1 px outer border: white at 14 % in dark, black at 14 % in light.
    public let panelBorder: NSColor

    public static let cornerRadius: CGFloat = 10
    public static let borderWidth: CGFloat = 1
    /// The title bar and everything in it are drawn at the chat's text scale (`ChatWebLook.textScale`, Tom 2026-11-09: "still the other things are
    /// big"): Orca's 36 pt bar is 27 pt, its 24 pt buttons 18 pt, its 12 pt title 9 pt.
    public static let titleBarHeight = ChatWebLook.scaled(36)
    /// The space left of the first column and above the first row: Orca's terminal padding (terminal.css `.xterm-container`, 4 px on the left
    /// and the top by default), in the terminal's background as Orca paints its pane (terminal-appearance.ts `paneBackground`).
    public static let terminalPadding: CGFloat = 4
    public static let buttonSize = ChatWebLook.scaled(24)
    /// The tab: Orca's 180 pt at most (`TAB_CONTAINER_WIDTH_CLASSES`), 6 pt of padding (`px-1.5`) and a 2 pt line along its bottom, at the text scale.
    public static let tabWidth = ChatWebLook.scaled(180)
    public static let tabPadding = ChatWebLook.scaled(6)
    public static let tabIndicatorHeight = ChatWebLook.scaled(2)
    public static let buttonIconSize = ChatWebLook.scaled(14)
    /// The gaps right of the close button and between the two buttons (Orca's 8 and 4).
    public static let buttonEdgeGap = ChatWebLook.scaled(8), buttonGap = ChatWebLook.scaled(4)
    /// The title's size: Orca's 12 pt at the text scale.
    public static let titleSize: CGFloat = 12 * ChatWebLook.textScale
    public static let fontSize: CGFloat = 10
    public static let borderAlpha: CGFloat = 0.14

    /// Orca's "Ayu Dark" (a public theme) for macOS Dark.
    public static let dark = ChatLook(
        isDark: true, background: RGB(0x0a0e14), foreground: RGB(0xb3b1ad), cursor: RGB(0xe6b450), cursorText: RGB(0x0a0e14), selection: RGB(0x273747),
        ansi: [0x01060e, 0xea6c73, 0x91b362, 0xf9af4f, 0x53bdfa, 0xfae994, 0x90e1c6, 0xc7c7c7,
               0x686868, 0xf07178, 0xc2d94c, 0xffb454, 0x59c2ff, 0xffee99, 0x95e6cb, 0xffffff].map(RGB.init),
        titleFill: RGB(0x171717), titleBorder: RGB(0xffffff).color(alpha: 0.07), titleText: RGB(0xfafafa), tabFill: RGB(0x252525),
        buttonText: RGB(0xfafafa), buttonHover: RGB(0x404040).color, panelBorder: RGB(0xffffff).color(alpha: borderAlpha))

    /// Orca's "Orca Light" for macOS Light: background, foreground, cursor and selection as the report gives them. The report has no ANSI table for
    /// this custom theme, so the 16 colours are GitHub Light's (a public theme Orca ships), which read well on white.
    public static let light = ChatLook(
        isDark: false, background: RGB(0xffffff), foreground: RGB(0x171717), cursor: RGB(0x171717), cursorText: RGB(0xffffff), selection: RGB(0xdbe9ff),
        ansi: [0x24292e, 0xd73a49, 0x28a745, 0xdbab09, 0x0366d6, 0x5a32a3, 0x0598bc, 0x6a737d,
               0x959da5, 0xcb2431, 0x22863a, 0xb08800, 0x005cc5, 0x5a32a3, 0x3192aa, 0xd1d5da].map(RGB.init),
        titleFill: RGB(0xffffff), titleBorder: RGB(0xe5e5e5).color, titleText: RGB(0x0a0a0a), tabFill: RGB(0xf0f0f0),
        buttonText: RGB(0x171717), buttonHover: RGB(0xf5f5f5).color, panelBorder: RGB(0x000000).color(alpha: borderAlpha))

    /// The look for an appearance: Dark when it best matches dark aqua, else Light.
    public static func look(for appearance: NSAppearance) -> ChatLook {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    // MARK: fonts

    public static let terminalFamily = "UDEV Gothic NFLG"

    /// "UDEV Gothic NFLG" at 10 pt (Regular for 500; SwiftTerm takes its Bold face for 700); SF Mono (the system's monospaced font, which always
    /// exists, so no Menlo step follows it) when UDEV Gothic is not installed. Never nil.
    public static func terminalFont(size: CGFloat = fontSize) -> NSFont {
        NSFont(name: "UDEVGothicNFLG-Regular", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Orca's app font, "Geist", when installed; else the system font.
    public static func titleFont(size: CGFloat = titleSize) -> NSFont {
        NSFont(name: "Geist-Regular", size: size) ?? NSFont(name: "Geist", size: size) ?? NSFont.systemFont(ofSize: size, weight: .regular)
    }
}
