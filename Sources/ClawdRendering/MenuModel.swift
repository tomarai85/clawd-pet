import Foundation
import CoreGraphics
import ClawdCore

/// The right-click menu (spec 5.2, Sprint M), as numbers: where every row, chip and tile lies, what a point hits, what a pick runs.
/// Everything here is in points with the origin at the panel's top-left corner and y growing downward (the mock's CSS box model), so
/// the mock's measurements read straight off the code. The panel is 236 pt wide and does not scale with Clawd's size.
public enum MenuMetrics {
    public static let width = 236.0
    /// The outer edge (1 pt) and the face inside it.
    public static let edge = 1.0
    public static let facePaddingY = 3.0
    public static let rowPaddingX = 5.0
    public static let rowPaddingY = 2.0
    public static let rowMinHeight = 20.0
    public static let labelWidth = 52.0
    public static let gap = 4.0
    public static let chipHeight = 16.0
    public static let chipPaddingX = 2.0
    public static let tileSize = 26.0
    public static let tileGap = 2.0
    public static let thumbnail = 24.0
    public static let styleChipWidth = 18.0
    public static let styleGap = 2.0
    public static let styleColumns = 6
    public static let separatorMargin = 3.0
    /// One font pixel is 2 pt: Clawd's half-unit at size 1, the same grid as the bubble text.
    public static let fontPixel = 2.0
    /// A pick shows its flash this long before the menu closes.
    public static let flashSeconds = 0.14
    /// The menu closes after this long with the pointer away from it.
    public static let awaySeconds = 8.0
    /// Distance between Clawd's body and the menu, and between the menu and the edge of the visible frame.
    public static let bodyGap = 8.0
    public static let screenMargin = 8.0
}

/// The mock's colours (menu-mock.html `:root` and `.menu` rules).
public enum MenuColors {
    public static let edge = Pixel(rgb: 0x8f8f88)
    public static let face = Pixel(rgb: 0xfbfaf6)
    public static let ink = Pixel(rgb: 0x2b2a27)
    public static let muted = Pixel(rgb: 0x9b978e)
    public static let rowHover = Pixel(rgb: 0xf1ebe2)
    public static let chipHover = Pixel(rgb: 0xe5dccf)
    public static let on = Pixel(rgb: 0xd77757)
    public static let onInk = Pixel(rgb: 0xffffff)
    public static let flash = Pixel(rgb: 0xb9573a)
    public static let separator = Pixel(rgb: 0xe2ddd3)
}

/// One thing in the menu that a click can pick (or that is shown and cannot be picked).
public struct MenuItem: Equatable {
    public enum Kind: Equatable { case chip, tile, styleChip, action }
    /// The row's key and this item's value as the logs and the CLI name them: walk/on, motion/quiet, look/sunglasses, every/3h,
    /// bubble/off, style/7, size/1.5, hide/60.
    public let key: String
    public let value: String
    public let kind: Kind
    /// Panel points, y down.
    public let rect: CGRect
    public let row: Int
    /// The text drawn on it (a tile has none: its picture is the look; the ✻ tile draws its glyph).
    public let label: String
    /// False for a bubble style that is not drawn yet: shown muted, takes no click.
    public let clickable: Bool
}

public struct MenuRow: Equatable {
    public let key: String
    /// The row's whole box, from face edge to face edge (the hover background; the hide row's click area).
    public let rect: CGRect
    /// The row's label ("Walk"); empty for the hide row, whose only text is its action.
    public let label: String
    public let labelOrigin: CGPoint
}

/// What a point in the panel hits.
public enum MenuHit: Equatable {
    case item(MenuItem)
    /// A bubble style chip that is not drawn yet.
    case muted(MenuItem)
    case separator
    /// Anything else inside the panel: a label, the space between chips, a row's padding, the face's padding, the notched corners.
    case gap
}

/// What a pick runs: the exact CLI arguments (the one writer path of spec 5.1), and the key the writer keeps only the newest pick of.
public struct MenuAction: Equatable {
    public let key: String
    public let value: String
    /// The writer keeps only the newest queued pick per queue key. Two different bubble styles are two keys, so neither is lost.
    public let queueKey: String
    public let arguments: [String]
    /// What the writer's log names instead of the arguments, for a verb whose arguments hold a path (no log line carries one).
    public let logVerb: String?
    public init(key: String, value: String, queueKey: String, arguments: [String], logVerb: String? = nil) {
        self.key = key; self.value = value; self.queueKey = queueKey; self.arguments = arguments; self.logVerb = logVerb
    }
}

/// The values the menu shows as selected: what the agent runs with now.
public struct MenuSelection: Equatable {
    public var walk = true
    public var motion: MotionLevel = .quiet
    /// nil: the look rotates (the ✻ tile).
    public var lookPin: String?
    public var lookEveryHours = 4
    public var bubble = true
    public var excludedStyles: Set<Int> = []
    public var bubbleSide: BubbleSide = .below
    public var scale = 1.0
    public init() {}
    public init(walk: Bool, motion: MotionLevel, lookPin: String?, lookEveryHours: Int, bubble: Bool, excludedStyles: Set<Int>, scale: Double,
                bubbleSide: BubbleSide = .below) {
        self.walk = walk; self.motion = motion; self.lookPin = lookPin; self.lookEveryHours = lookEveryHours
        self.bubble = bubble; self.excludedStyles = excludedStyles; self.scale = scale; self.bubbleSide = bubbleSide
    }
    /// The settings of the current generation. The v1 `helmet` key counts as a pin on the helmet look (spec 5.1: `helmet on` pins it), but
    /// the one-shot "back to plain" after `helmet off` is not a pin the user chose, so it is not shown.
    public init(settings: AppliedSettings) {
        walk = settings.scheduler.walk; motion = settings.scheduler.motion
        lookPin = settings.scheduler.lookPin ?? (settings.control.helmet ? "helmet" : nil)
        lookEveryHours = settings.scheduler.lookEveryHours; bubble = settings.scheduler.bubble
        excludedStyles = settings.scheduler.bubbleExcluded; scale = settings.control.scale
        bubbleSide = settings.scheduler.bubbleSide
    }

    public func isSelected(_ item: MenuItem) -> Bool {
        guard item.clickable else { return false }
        switch item.key {
        case "walk": return (walk ? "on" : "off") == item.value
        case "motion": return motion.rawValue == item.value
        case "look": return (lookPin ?? "random") == item.value
        case "every": return "\(lookEveryHours)h" == item.value
        case "bubble": return (bubble ? "on" : "off") == item.value
        case "style": return Int(item.value).map { !excludedStyles.contains($0) } ?? false
        case "side": return bubbleSide.rawValue == item.value
        case "size": return Double(item.value) == scale
        default: return false
        }
    }

    /// What picking `item` runs now; nil for an item that takes no click.
    public func action(for item: MenuItem) -> MenuAction? {
        guard item.clickable else { return nil }
        let arguments: [String]
        var queueKey = item.key
        switch item.key {
        case "walk", "motion", "look", "bubble", "size": arguments = [item.key, item.value]
        case "every": arguments = ["look-every", item.value]
        case "style":
            guard let n = Int(item.value) else { return nil }
            arguments = ["bubble", excludedStyles.contains(n) ? "include" : "exclude", item.value]
            queueKey = "style-" + item.value
        case "side": arguments = ["bubble", "side", item.value]
        case "hide": arguments = ["hide", item.value]
        default: return nil
        }
        return MenuAction(key: item.key, value: item.value, queueKey: queueKey, arguments: arguments)
    }
}

/// Whether the menu has a chat row and which words it carries: none when chat is off; "Chat with Claude Code" while the panel is closed;
/// "Close chat" while it is open.
public enum MenuChatRow: Hashable {
    case absent, closed, open
    public var label: String? {
        switch self {
        case .absent: return nil
        case .closed: return "Chat with Claude Code"
        case .open: return "Close chat"
        }
    }
}

/// Every rectangle of the menu, from the looks of the catalog and the bubble styles the renderer draws.
public struct MenuLayout: Equatable {
    public let size: CGSize
    public let rows: [MenuRow]
    public let items: [MenuItem]
    public let separator: CGRect
    public let looks: [String]
    public let drawnStyles: Set<Int>
    public let chat: MenuChatRow

    /// Width in points of a string in the pet's pixel font (one font pixel is 2 pt).
    public static func textWidth(_ text: String) -> Double { Double(PixelFont.width(of: text)) * MenuMetrics.fontPixel }

    public init(looks: [String], drawnStyles: Set<Int>, chat: MenuChatRow = .absent) {
        self.looks = looks; self.drawnStyles = drawnStyles; self.chat = chat
        let faceLeft = MenuMetrics.edge, faceRight = MenuMetrics.width - MenuMetrics.edge
        let contentLeft = faceLeft + MenuMetrics.rowPaddingX
        let chipsLeft = contentLeft + MenuMetrics.labelWidth + MenuMetrics.gap
        let chipsRight = faceRight - MenuMetrics.rowPaddingX
        var rows: [MenuRow] = [], items: [MenuItem] = []
        var y = MenuMetrics.edge + MenuMetrics.facePaddingY

        func addRow(_ key: String, label: String, height: Double) {
            let rect = CGRect(x: faceLeft, y: y, width: faceRight - faceLeft, height: height)
            rows.append(MenuRow(key: key, rect: rect, label: label, labelOrigin: CGPoint(x: contentLeft, y: y + MenuMetrics.rowPaddingY + 2)))
            y += height
        }
        /// A row of text chips that wrap inside the chip column. Returns the height the chips take.
        func chips(row: Int, key: String, _ values: [(String, String)], top: Double) -> Double {
            var x = chipsLeft, cy = top
            for (value, label) in values {
                let width = Self.textWidth(label) + 2 * MenuMetrics.chipPaddingX
                if x > chipsLeft, x + width > chipsRight { x = chipsLeft; cy += MenuMetrics.chipHeight + MenuMetrics.gap }
                items.append(MenuItem(key: key, value: value, kind: .chip, rect: CGRect(x: x, y: cy, width: width, height: MenuMetrics.chipHeight),
                                      row: row, label: label, clickable: true))
                x += width + MenuMetrics.gap
            }
            return cy + MenuMetrics.chipHeight - top
        }
        func chipRow(_ key: String, _ label: String, _ values: [(String, String)]) {
            let index = rows.count
            let top = y + MenuMetrics.rowPaddingY
            let used = chips(row: index, key: key, values, top: top)
            addRow(key, label: label, height: max(MenuMetrics.rowMinHeight, used + 2 * MenuMetrics.rowPaddingY))
        }

        // The chat entry is the first row, a whole-row action like "Hide for 1 hour"; nothing below it changes but its position.
        if let label = chat.label {
            let rowRect = CGRect(x: faceLeft, y: y, width: faceRight - faceLeft, height: MenuMetrics.rowMinHeight)
            items.append(MenuItem(key: "chat", value: "toggle", kind: .action, rect: rowRect, row: rows.count, label: label, clickable: true))
            rows.append(MenuRow(key: "chat", rect: rowRect, label: "", labelOrigin: CGPoint(x: contentLeft, y: y + MenuMetrics.rowPaddingY + 2)))
            y += MenuMetrics.rowMinHeight
        }

        chipRow("walk", "Walk", [("on", "on"), ("off", "off")])
        chipRow("motion", "Motion", MotionLevel.allCases.map { ($0.rawValue, $0.rawValue) })

        // Look: the random tile, then one tile per look of the catalog, wrapping.
        do {
            let index = rows.count
            let top = y + MenuMetrics.rowPaddingY
            let step = MenuMetrics.tileSize + MenuMetrics.tileGap
            let perLine = max(1, Int(((chipsRight - chipsLeft) + MenuMetrics.tileGap) / step))
            let ids = ["random"] + looks
            for (n, id) in ids.enumerated() {
                let rect = CGRect(x: chipsLeft + Double(n % perLine) * step, y: top + Double(n / perLine) * step,
                                  width: MenuMetrics.tileSize, height: MenuMetrics.tileSize)
                items.append(MenuItem(key: "look", value: id, kind: .tile, rect: rect, row: index, label: id == "random" ? "\u{273B}" : "", clickable: true))
            }
            let lines = (ids.count + perLine - 1) / perLine
            let used = Double(lines) * MenuMetrics.tileSize + Double(max(0, lines - 1)) * MenuMetrics.tileGap
            addRow("look", label: "Look", height: max(MenuMetrics.rowMinHeight, used + 2 * MenuMetrics.rowPaddingY))
        }

        chipRow("every", "Every", [("2h", "2h"), ("3h", "3h"), ("4h", "4h")])

        // Bubble: on and off, then the fifteen styles in a grid of 18 pt chips, six to a line.
        do {
            let index = rows.count
            let top = y + MenuMetrics.rowPaddingY
            _ = chips(row: index, key: "bubble", [("on", "on"), ("off", "off")], top: top)
            let gridTop = top + MenuMetrics.chipHeight + MenuMetrics.styleGap
            let step = MenuMetrics.styleChipWidth + MenuMetrics.styleGap
            for n in SchedulerSettings.bubbleStyles {
                let col = (n - 1) % MenuMetrics.styleColumns, line = (n - 1) / MenuMetrics.styleColumns
                let rect = CGRect(x: chipsLeft + Double(col) * step, y: gridTop + Double(line) * (MenuMetrics.chipHeight + MenuMetrics.styleGap),
                                  width: MenuMetrics.styleChipWidth, height: MenuMetrics.chipHeight)
                items.append(MenuItem(key: "style", value: String(n), kind: .styleChip, rect: rect, row: index, label: String(n), clickable: drawnStyles.contains(n)))
            }
            let lines = (SchedulerSettings.bubbleStyles.count + MenuMetrics.styleColumns - 1) / MenuMetrics.styleColumns
            let used = MenuMetrics.chipHeight + MenuMetrics.styleGap + Double(lines) * MenuMetrics.chipHeight + Double(lines - 1) * MenuMetrics.styleGap
            addRow("bubble", label: "Bubble", height: max(MenuMetrics.rowMinHeight, used + 2 * MenuMetrics.rowPaddingY))
        }

        chipRow("side", "Side", BubbleSide.allCases.map { ($0.rawValue, $0.rawValue) })

        chipRow("size", "Size", [("0.5", "0.5"), ("0.75", "0.75"), ("1", "1"), ("1.5", "1.5"), ("2", "2"), ("3", "3"), ("4", "4")])

        y += MenuMetrics.separatorMargin
        separator = CGRect(x: contentLeft, y: y, width: chipsRight - contentLeft, height: 1)
        y += 1 + MenuMetrics.separatorMargin

        do {
            let index = rows.count
            let rowRect = CGRect(x: faceLeft, y: y, width: faceRight - faceLeft, height: MenuMetrics.rowMinHeight)
            items.append(MenuItem(key: "hide", value: "60", kind: .action, rect: rowRect, row: index, label: "Hide for 1 hour", clickable: true))
            rows.append(MenuRow(key: "hide", rect: rowRect, label: "", labelOrigin: CGPoint(x: contentLeft, y: y + MenuMetrics.rowPaddingY + 2)))
            y += MenuMetrics.rowMinHeight
        }
        // Settings… and Quit Clawd: two more whole-row actions under the hide row, so every row above keeps its rectangle.
        for (key, value, label) in [("settings", "open", "Settings\u{2026}"), ("quit", "quit", "Quit Clawd")] {
            let index = rows.count
            let rowRect = CGRect(x: faceLeft, y: y, width: faceRight - faceLeft, height: MenuMetrics.rowMinHeight)
            items.append(MenuItem(key: key, value: value, kind: .action, rect: rowRect, row: index, label: label, clickable: true))
            rows.append(MenuRow(key: key, rect: rowRect, label: "", labelOrigin: CGPoint(x: contentLeft, y: y + MenuMetrics.rowPaddingY + 2)))
            y += MenuMetrics.rowMinHeight
        }
        y += MenuMetrics.facePaddingY + MenuMetrics.edge
        size = CGSize(width: MenuMetrics.width, height: y)
        self.rows = rows; self.items = items
    }

    /// What a point of the panel hits (panel points, y down).
    public func hit(at point: CGPoint) -> MenuHit {
        for item in items where item.rect.contains(point) { return item.clickable ? .item(item) : .muted(item) }
        if separator.insetBy(dx: 0, dy: -MenuMetrics.separatorMargin).contains(point) && point.x >= separator.minX && point.x < separator.maxX { return .separator }
        return .gap
    }

    public func item(at point: CGPoint) -> MenuItem? { if case .item(let item) = hit(at: point) { return item } else { return nil } }

    /// The row whose box holds the point (the hover background), nil outside every row.
    public func row(at point: CGPoint) -> Int? { rows.firstIndex { $0.rect.contains(point) } }

    public func items(inRow row: Int) -> [MenuItem] { items.filter { $0.row == row } }
}

/// Where the menu opens (spec 5.2, ruling 4): to the right of Clawd's canvas with an 8 pt gap, centred on it vertically, inside the visible
/// frame with an 8 pt margin; on the left when the right side does not fit. Global points, y up.
public enum MenuPlacement {
    public static func rect(size: CGSize, canvas: CGRect, visible: CGRect) -> CGRect {
        let margin = MenuMetrics.screenMargin
        var x = canvas.maxX + MenuMetrics.bodyGap
        if x + size.width > visible.maxX - margin { x = canvas.minX - MenuMetrics.bodyGap - size.width }
        // Neither side fits (a very narrow frame): the right edge keeps its margin, as the mock does.
        x = min(x, visible.maxX - margin - size.width)
        x = max(x, visible.minX + margin)
        var y = canvas.midY - size.height / 2
        // A frame too short for the menu keeps the top margin (the mock does the same: the bottom edge is the one that gives).
        y = max(y, visible.minY + margin)
        y = min(y, visible.maxY - margin - size.height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}
