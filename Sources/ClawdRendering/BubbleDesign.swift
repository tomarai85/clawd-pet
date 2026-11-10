import Foundation

/// The macOS appearance a bubble is drawn for. Only styles 14 and 15 differ between the two.
public enum BubbleAppearance: Equatable, Hashable { case light, dark }

/// Where a text colour role lands on a style's fill. Every role is at least 4.5:1 against its fill (BubbleDesign.contrast).
public enum BubbleRole: Equatable { case claude, shimmer, dim, error, ink }

/// One run of bubble text. A run that is not `visible` still takes its width, so a blinking cursor never moves the box.
public struct BubbleRun: Equatable {
    public var text: String
    public var role: BubbleRole
    public var visible: Bool
    /// The reduced-motion pulse: 0 = the role's colour, 1 and 2 = that colour moved one and two thirds of the way towards black or white,
    /// whichever the fill is far from (`Pixel.pulsed`). No step is less contrasty than the role's colour, so the 4.5:1 rule holds at every step.
    public var dimLevel: Int
    /// Columns between this run and the next. nil: the style's own gap (one column in every style but 13).
    public var gapAfter: Int?
    /// A shape instead of text (styles 14 and 15 draw their chevron, asterisk, caret, block cursor and dot as shapes).
    public var mark: BubbleMark?
    /// The shimmer's centre: the characters one either side of this index are drawn in the shimmer colour (style 15's verb).
    public var glint: Int?
    /// The run takes at least this many points (style 15's spinner slot).
    public var slot: Double?
    public init(_ text: String, _ role: BubbleRole, visible: Bool = true, dimLevel: Int = 0, gapAfter: Int? = nil, mark: BubbleMark? = nil, glint: Int? = nil,
                slot: Double? = nil) {
        self.text = text; self.role = role; self.visible = visible; self.dimLevel = dimLevel; self.gapAfter = gapAfter
        self.mark = mark; self.glint = glint; self.slot = slot
    }
}

/// The shapes styles 14 and 15 draw in place of text.
public enum BubbleMark: Equatable {
    /// 14's prompt: a chevron.
    case chevron
    /// ⎿ as an L-shaped stroke at the chevron's weight.
    case hook
    /// 14's caret, a 2 pt bar.
    case caret
    /// 15's block cursor.
    case block
    /// The reduced-motion dot, 6 pt across, and 14's still SENT asterisk is `.asterisk(degrees: 0)`.
    case disc
    /// 14's asterisk, turned by `degrees`.
    case asterisk(degrees: Double)
}

/// Three small dots after or before the words. Style 10's kind is `.lit`: three 2 x 2 dots in front of the words, the `lit` one in the brighter
/// colour. Style 13's kind is `.counting`: after the words, 2 x 2 dots 4 columns apart, the first `shown` of them drawn and the slot of all three
/// always reserved, so the box never changes width while they count.
public struct BubbleDots: Equatable {
    public enum Kind: Equatable { case lit, counting, wave }
    public var kind: Kind
    public var lit: Int
    /// `.counting`: how many dots are drawn (1...3).
    public var shown: Int
    /// `.wave` (style 14): the opacity of each of the three dots.
    public var opacities: [Double]
    public init(lit: Int) { kind = .lit; self.lit = lit; shown = 0; opacities = [] }
    public init(count: Int) { kind = .counting; lit = 0; shown = min(3, max(1, count)); opacities = [] }
    public init(opacities: [Double]) { kind = .wave; lit = 0; shown = 0; self.opacities = opacities }
    public static let width = 8      // 2 + 1 + 2 + 1 + 2
    /// The counting kind's slot: three 2 x 2 dots 4 apart.
    public static let countingWidth = 10
    /// Columns between the last word and the counting dots.
    public static let countingGap = 2
}

public enum BubbleConnection: Equatable {
    /// Above Clawd's head: the connector hangs below the box.
    case above
    /// Under Clawd's feet: the connector hangs from the box's top edge and points up at him. It is `.above` turned over top to bottom; the words and
    /// the glyphs are never turned, and the drop shadow stays under the box.
    case below
    /// Beside the head: the connector points sideways at it.
    case side
}
/// Which way the box extends from the anchor. `.right`: the box lies to the right of the anchor (Clawd in the left half of the display).
public enum BubbleOpening: Equatable { case right, left }

public enum BubbleVariant: Equatable {
    /// Fits the 12-row budget of size 1 (6 units tall).
    case snug
    /// One more row of air above and below the text; only used when the body is tall enough (size 1.5 and up).
    case roomy
}

/// A connector drawn cell by cell: the style's own pointer (NES stair, Clippy's flag, the thought bubble's three circles).
/// `F` paints the fill, `B` and `D` the border (or the fill when the style has none), `M` the style's grey ink, `.` leaves the cell alone.
struct BubbleSprite {
    /// Above Clawd's head. Row 0 is the box's own last row (it can open a gap in the outline); the rows after it hang below the box.
    /// Column 0 is the tip column; the sprite extends away from it (to the right when the box opens right, mirrored when it opens left).
    let above: [String]
    /// Beside the head, tip on the left (the box opens right; mirrored otherwise). The last column is the box's own edge column.
    let side: [String]
    /// The row of `side` that holds the tip.
    let sideTipRow: Int
    /// A trail that runs out to the side of the box instead of hanging under it (the thought bubble's circles): the cells that lie
    /// left of the box when it opens right (right of it when it opens left), bottom-aligned to the whole picture. The tip is the
    /// picture's bottom corner on that side, so the connector still ends 1 unit above the head.
    var lead: [String] = []
    var leadColumns: Int { lead.first?.count ?? 0 }
    var hangRows: Int { above.count - 1 }
    var sideColumns: Int { (side.first?.count ?? 1) - 1 }
    func colour(_ cell: Character, fill: Pixel, border: Pixel?, mid: Pixel) -> Pixel? {
        switch cell { case "F": return fill; case "B", "D": return border ?? fill; case "M": return mid; default: return nil }
    }
}

/// How a style is put together.
enum BubbleForm {
    /// A filled box (corners, an outline, a ring, a connector).
    case box
    /// No box: the text is lifted off the desktop by a thick outline (a die-cut sticker).
    case halo
    /// A bar of two coloured segments joined by arrows (powerline); the first run lives in the first segment.
    case segments
}

/// Which sides of a style's outline are drawn.
enum BubbleEdges { case all, topBottom }

/// One of the board's styles drawn in Clawd's pixel language: only straight horizontal and vertical edges on the bubble grid. Styles 1-12 step in
/// 2 pt pixels; style 13 steps in 1 pt pixels with a finer font.
/// The colours 14 and 15 take in Dark Mode.
struct SmoothColours {
    var fill: Pixel, border: Pixel?
    var claude: Pixel, shimmer: Pixel, dim: Pixel, error: Pixel, ink: Pixel
    var cursor: Pixel?
    var rim: (colour: Pixel, alpha: Double)?
}

public struct BubbleDesign {
    public let id: Int
    /// The colour the text sits on (style 3, which has no box, takes its outline colour here).
    public internal(set) var fill: Pixel
    public internal(set) var border: Pixel?
    public internal(set) var claude: Pixel, shimmer: Pixel, dim: Pixel, error: Pixel, ink: Pixel
    /// Insets of the corner cells, from the corner edge inwards (row 0 first). Bottom-left and bottom-right can differ.
    var topCorner: [Int]
    var bottomCorner: [Int]
    /// Style 10's small corner at the side the connector would be on (the lower side next to Clawd).
    var nearBottomCorner: [Int]?
    var connector: Connector
    var padX: Int
    var padYSnug: Int
    var padYRoomy: Int
    var usesDots: Bool
    // Phase 2 styles. The defaults leave styles 1, 6 and 10 exactly as phase 1 drew them.
    var form: BubbleForm = .box
    var edges: BubbleEdges = .all
    /// Both ends rounded to a half circle (style 8).
    var capsule = false
    /// A one-cell ring outside the outline (style 5's second frame).
    var ring: Pixel? = nil
    /// Capital letters only (style 5).
    var uppercase = false
    /// Style 12's first segment: the colour behind the glyph and the glyph's own colour.
    var segment: (fill: Pixel, ink: Pixel)? = nil
    /// The outline's thickness around text that has no box (style 3).
    var haloRadius = 0
    // Style 13 (the board's refined pixel art, 1 pt pixels). Every default below is what styles 1-12 do today.
    /// One bubble pixel in points: Clawd's half-unit (2 pt) for styles 1-12, 1 pt for style 13.
    var pixelPt = BubbleLayout.pixelPt
    /// The pixel font the text is drawn in.
    var face = PixelFace.classic
    /// The rows of air above the text are `padY + padSkew` and below it `padY - padSkew`: style 13's text sits one row high.
    var padSkew = 0
    /// The connector of the snug form, when it is not the roomy form's.
    var snugSprite: BubbleSprite? = nil
    /// Distance of the connector's tip from the near edge of the box (nil: `tipMargin`) and how far in from the corner it may be slid.
    var tipDefault: Int? = nil
    var tipClamp: Int? = nil
    /// The narrowest a box may be, in columns.
    var minWidth = 12
    /// Columns between two runs that name no gap of their own.
    var runGap = 1
    /// One translucent row under every bottom-edge pixel of the box and the connector (premultiplied, like every pixel).
    var dropShadow: Pixel? = nil
    /// The bubble's picture also keeps out of the body window's rectangle, not only off Clawd's pixels (styles 13-15; amendment D-5, R3-2).
    var keepsOffTheBodyWindow = false
    // Styles 14 and 15 (the board's smooth macOS bubble and Claude Code's panel), drawn at device pixels by `SmoothBubble`.
    var smooth: SmoothKind? = nil
    /// The colours in Dark Mode: 14 and 15 follow the macOS appearance, and the colours above are their Light ones.
    var dark: SmoothColours? = nil
    /// The block cursor's own colour where it is not the text's (15 in Dark Mode).
    var cursorColour: Pixel? = nil
    /// 14 in Dark Mode: a 0.5 pt inner rim of white at 13% round the box.
    var rim: (colour: Pixel, alpha: Double)? = nil
    /// False once the connector is left out (a frame too small for it).
    var connectorShown = true

    enum Connector { case none, tail, dots, sprite(BubbleSprite) }

    public func color(_ role: BubbleRole) -> Pixel {
        switch role { case .claude: return claude; case .shimmer: return shimmer; case .dim: return dim; case .error: return error; case .ink: return ink }
    }
    public var roles: [BubbleRole] { [.claude, .shimmer, .dim, .error, .ink] }
    /// Every pairing of a text colour with the colour it sits on (spec 4.1: at least 4.5:1 each).
    public var textPairs: [(name: String, foreground: Pixel, background: Pixel)] {
        var pairs = roles.map { (name: "\($0)", foreground: color($0), background: fill) }
        if let segment { pairs.append((name: "segment", foreground: segment.ink, background: segment.fill)) }
        return pairs
    }
    /// Worst contrast of any text colour against the colour under it.
    public var contrast: Double { textPairs.map { Pixel.contrast($0.foreground, $0.background) }.min() ?? 0 }
    /// Every colour the style may paint (the finished picture holds nothing else and no half-tones).
    public var palette: Set<Pixel> {
        var set: Set<Pixel> = [fill, ink]
        if let border { set.insert(border) }
        if let ring { set.insert(ring) }
        for role in roles { set.insert(color(role)) }
        // The reduced-motion pulse paints the dot (the claude role, or style 12's glyph on its segment) in two more colours.
        for level in 1...2 { set.insert(color(.claude).pulsed(level: level, against: fill)) }
        if let segment {
            set.formUnion([segment.fill, segment.ink])
            for level in 1...2 { set.insert(segment.ink.pulsed(level: level, against: segment.fill)) }
        }
        if usesDots { set.insert(BubbleDesign.dotsOff) }
        return set
    }

    /// The sprite a variant draws its connector with.
    func sprite(_ variant: BubbleVariant) -> BubbleSprite? {
        guard case .sprite(let roomy) = connector else { return nil }
        return variant == .snug ? (snugSprite ?? roomy) : roomy
    }
    /// Rows of the connector below the box (above placement) or columns beside it (side placement).
    func connectorRows(_ variant: BubbleVariant) -> Int {
        if let smooth { return connectorShown ? SmoothBubble.metrics(smooth, variant).tailRows : 0 }
        switch connector {
        case .none: return 0
        case .tail: return 3
        case .dots: return variant == .snug ? 2 : 4
        case .sprite: return sprite(variant)?.hangRows ?? 0
        }
    }
    /// `variant` matters only to a style whose two forms have connectors of their own; before it is known the roomier form's width is the safe one.
    func connectorColumns(_ variant: BubbleVariant = .roomy) -> Int {
        if let smooth { return connectorShown ? SmoothBubble.metrics(smooth, variant).tailRows : 0 }
        switch connector {
        case .none: return 0
        case .tail: return 3
        case .dots: return 4
        case .sprite: return sprite(variant)?.sideColumns ?? 0
        }
    }
    /// Columns the picture gains beside the box when the connector hangs above Clawd (a trail that runs out to the side).
    var aboveLead: Int { if case .sprite(let sprite) = connector { return sprite.leadColumns }; return 0 }
    func padY(_ variant: BubbleVariant) -> Int { variant == .snug ? padYSnug : padYRoomy }
    /// Rows of air above and below the text. Both are `padY` unless the style skews its text.
    func padTop(_ variant: BubbleVariant) -> Int { padY(variant) + padSkew }
    func padBottom(_ variant: BubbleVariant) -> Int { padY(variant) - padSkew }
    /// What the picture holds beyond the shape (the box and its connector), in bubble pixels: a drop shadow.
    var margins: (top: Int, side: Int, bottom: Int) { isSmooth ? (1, 2, 3) : (dropShadow == nil ? (0, 0, 0) : (0, 0, 1)) }
    /// Cells the outline (and the ring) take on each side, across and down.
    var frameX: Int { (border != nil && edges == .all ? 1 : 0) + (ring == nil ? 0 : 1) }
    var frameY: Int { (border == nil ? 0 : 1) + (ring == nil ? 0 : 1) }
    /// Smallest and default distance of the connector's tip cell from the box's left or right edge.
    var tipMargin: Int {
        if let tipDefault { return tipDefault }
        if let smooth { return SmoothBubble.metrics(smooth, .roomy).tipOffset }
        switch connector { case .none: return 3; case .tail: return 3; case .dots: return 4; case .sprite(let sprite): return sprite.leadColumns > 0 ? 0 : 3 }
    }
    /// The columns the tip of an above connector may take in a box `w` wide. Styles 1-12 keep it `margin` columns in from either side. A style with
    /// a `tipClamp` keeps the whole connector, which extends away from the tip, on the straight part of the bottom edge.
    func tipBounds(opening: BubbleOpening, boxWidth w: Int, variant: BubbleVariant, margin: Int = 3) -> (low: Int, high: Int) {
        if let smooth { return SmoothBubble.tipBounds(smooth, opening: opening, boxWidth: w, variant: variant) }
        guard let tipClamp else { return (margin, w - 1 - margin) }
        let span = (sprite(variant)?.above.map(\.count).max() ?? 1) - 1
        return opening == .right ? (tipClamp, w - 1 - tipClamp - span) : (tipClamp + span, w - 1 - tipClamp)
    }

    /// This style drawn without its connector (a frame too small to put it where it would not lie on Clawd).
    var withoutConnector: BubbleDesign { var bare = self; bare.connector = .none; bare.connectorShown = false; return bare }

    /// Styles 14 and 15 are drawn smooth, at device pixels.
    public var isSmooth: Bool { smooth != nil }
    /// The styles drawn on the pixel grid (1-13).
    public static var pixelDesigns: [BubbleDesign] { all.filter { !$0.isSmooth } }
    /// This style in an appearance. The pixel styles have one palette and ignore it.
    func appearing(_ appearance: BubbleAppearance) -> BubbleDesign {
        guard appearance == .dark, let c = dark else { return self }
        var d = self
        d.fill = c.fill; d.border = c.border; d.claude = c.claude; d.shimmer = c.shimmer; d.dim = c.dim; d.error = c.error; d.ink = c.ink
        d.cursorColour = c.cursor; d.rim = c.rim
        return d
    }
    /// How far from the tip's column the edge that lies over H is, in units.
    func tipEdge(_ opening: BubbleOpening) -> Int { isSmooth || opening == .right ? 0 : 1 }
    /// The tip column, in shape columns, that centres the box on the anchor in an above or below placement: through the picture's x the box's
    /// centre lands within one bubble unit of H (half a unit when the box is odd). A connector that runs out to the side (`aboveLead`, opening right)
    /// starts the box `aboveLead` columns into the shape.
    func centeredTip(_ opening: BubbleOpening, boxWidth w: Int) -> Int {
        (opening == .right ? aboveLead : 0) + w / 2 - tipEdge(opening)
    }
    /// The columns, in shape columns, the tip of an above or below connector may take: `tipBounds` for the box, moved by the lead where the box starts
    /// after one. A trail with a lead keeps the whole trail on the straight part of the bottom edge, as a clamped style does.
    func verticalTipBounds(opening: BubbleOpening, boxWidth w: Int, variant: BubbleVariant) -> (low: Int, high: Int) {
        let lead = opening == .right ? aboveLead : 0
        if aboveLead > 0 {
            let span = (sprite(variant)?.above.map(\.count).max() ?? 1) - 1, margin = 3
            return opening == .right ? (lead + margin, lead + w - 1 - margin - span) : (margin + span, w - 1 - margin)
        }
        let bounds = tipBounds(opening: opening, boxWidth: w, variant: variant)
        return (bounds.low + lead, bounds.high + lead)
    }

    public static let ids = Array(1...12)
    /// The nine styles phase 2 adds.
    public static let phase2Ids = [2, 3, 4, 5, 7, 8, 9, 11, 12]
    /// The styles drawn: the board's twelve, the refined pixel art of 13 and the smooth 14 and 15.
    public static let allIds = Array(1...15)
    public static func design(_ id: Int) -> BubbleDesign? { all.first { $0.id == id } }
    /// An id outside the drawn styles falls back to style 1, the official blue bubble.
    public static func resolved(_ id: Int) -> BubbleDesign { design(id) ?? all[0] }

    /// The two typing dots that are not lit.
    public static let dotsOff = Pixel(rgb: 0x5C5C5C)
    static let ivory = Pixel(rgb: 0xFAF9F5), slate = Pixel(rgb: 0x141413), sky = Pixel(rgb: 0x699ACB)
    static let white = Pixel(rgb: 0xFFFFFF)

    /// Text colours of the board's mocks on a light fill, taken from `.o` and `.dim` and darkened just enough for 4.5:1.
    static let ember = Pixel(rgb: 0xB0502E), emberLight = Pixel(rgb: 0xB85A36), roseDark = Pixel(rgb: 0xB02040)

    static let nesTail = BubbleSprite(above: [".FF.", "BFB.", "BB.."], side: ["..B.", ".BFF", "BFFF", ".BFF", "..B."], sideTipRow: 2)
    static let clippyTail = BubbleSprite(above: [".FFF", "BFFB", "BB.."], side: ["...B.", "..BFF", ".BFFF", "BFFFF", "BBBB."], sideTipRow: 4)
    // Three circles shrinking towards the head: a ring with a white eye, a 2 x 2 dot, a single pixel, in the style's grey ink so they show on dark and light windows.
    static let thoughtTrail = BubbleSprite(above: ["", "", "M.M.MM"],
                                           side: ["......M...", "..MM.MFM..", "M.MM..M..."], sideTipRow: 2,
                                           lead: ["......M.", ".....MFM", "..MM..M.", "..MM....", "M......."])

    // Style 13's connector (the board's mock `renderB`): a stepped triangle under the box, its vertical edge on the tip column, row k of the tail
    // spanning the tip column and the columns to its right while the box and the tail are outlined as one shape. Row 0 is the box's own last row,
    // opened over the tail. Beside the head the tail is a symmetric stepped arrow, its tip on the box's vertical centre.
    static let refinedTail = BubbleSprite(above: ["FFFFFF", "BFFFFB", "BFFFB.", "BFFB..", "BFB...", "BB....", "B....."],
                                          side: [".....BF", "....BFF", "...BFFF", "..BFFFF", ".BFFFFF", "BFFFFFF", ".BFFFFF", "..BFFFF", "...BFFF", "....BFF", ".....BF"], sideTipRow: 5)
    static let refinedTailSnug = BubbleSprite(above: ["FFFFF", "BFFFB", "BFFB.", "BFB..", "BB...", "B...."],
                                              side: ["....BF", "...BFF", "..BFFF", ".BFFFF", "BFFFFF", ".BFFFF", "..BFFF", "...BFF", "....BF"], sideTipRow: 4)

    public static let all: [BubbleDesign] = [
        // 1: the official blue pixel bubble of claude.dev Clawd-Thinking (light_blue rgb(105,154,203) with the near-black of Clawd's eyes).
        BubbleDesign(id: 1, fill: sky, border: nil,
                     claude: slate, shimmer: Pixel(rgb: 0x142846), dim: Pixel(rgb: 0x142846), error: Pixel(rgb: 0x5A0A1E), ink: slate,
                     topCorner: [1], bottomCorner: [1], nearBottomCorner: nil, connector: .tail, padX: 2, padYSnug: 1, padYRoomy: 2, usesDots: false),
        // 2: Claude Code's input box: terminal black, no frame at the sides, a thin grey rule above and below.
        BubbleDesign(id: 2, fill: Pixel(rgb: 0x0C0C0C), border: Pixel(rgb: 0x888888),
                     claude: Pixel(rgb: 0xD77757), shimmer: Pixel(rgb: 0xEB9F7F), dim: Pixel(rgb: 0x999999), error: Pixel(rgb: 0xFF6B80), ink: white,
                     topCorner: [1], bottomCorner: [1], nearBottomCorner: nil, connector: .none, padX: 3, padYSnug: 1, padYRoomy: 2, usesDots: false,
                     edges: .topBottom),
        // 3: no box, a white die-cut outline round the words, like the official sticker.
        BubbleDesign(id: 3, fill: white, border: nil,
                     claude: ember, shimmer: emberLight, dim: Pixel(rgb: 0x6C6C6C), error: roseDark, ink: Pixel(rgb: 0x555555),
                     topCorner: [], bottomCorner: [], nearBottomCorner: nil, connector: .none, padX: 0, padYSnug: 0, padYRoomy: 1, usesDots: false,
                     form: .halo, haloRadius: 2),
        // 4: NES.css balloon: white, a one-cell near-black outline with stepped corners, a stair tail.
        BubbleDesign(id: 4, fill: white, border: Pixel(rgb: 0x212529),
                     claude: ember, shimmer: emberLight, dim: Pixel(rgb: 0x6B6F76), error: roseDark, ink: Pixel(rgb: 0x212529),
                     topCorner: [1], bottomCorner: [1], nearBottomCorner: nil, connector: .sprite(nesTail), padX: 3, padYSnug: 1, padYRoomy: 2, usesDots: false),
        // 5: papercade's dialogue window: dark, a cream frame with cut corners and a dark ring round it, capitals, yellow for the accent.
        BubbleDesign(id: 5, fill: Pixel(rgb: 0x1B1A17), border: Pixel(rgb: 0xE9E2CF),
                     claude: Pixel(rgb: 0xF5C400), shimmer: Pixel(rgb: 0xFFF1A8), dim: Pixel(rgb: 0xBDB6A3), error: Pixel(rgb: 0xFF6B80), ink: Pixel(rgb: 0xF1EAD6),
                     topCorner: [1], bottomCorner: [1], nearBottomCorner: nil, connector: .none, padX: 3, padYSnug: 1, padYRoomy: 2, usesDots: false,
                     ring: Pixel(rgb: 0x1B1A17), uppercase: true),
        // 6: the pixel cloud above the head (Clawd on Desk's idea), drawn in Anthropic's ivory and slate.
        BubbleDesign(id: 6, fill: ivory, border: Pixel(rgb: 0xB0AEA5),
                     claude: Pixel(rgb: 0xA0563C), shimmer: Pixel(rgb: 0xB45532), dim: Pixel(rgb: 0x5E5D59), error: Pixel(rgb: 0xB02040), ink: slate,
                     topCorner: [2, 1], bottomCorner: [2, 1], nearBottomCorner: nil, connector: .dots, padX: 3, padYSnug: 1, padYRoomy: 2, usesDots: false),
        // 7: Clippy's balloon: pale yellow, a black outline, small corners, a pointed tail.
        BubbleDesign(id: 7, fill: Pixel(rgb: 0xFFFFCC), border: Pixel(rgb: 0x000000),
                     claude: Pixel(rgb: 0xB8501F), shimmer: Pixel(rgb: 0xB04A22), dim: Pixel(rgb: 0x555555), error: roseDark, ink: Pixel(rgb: 0x000000),
                     topCorner: [1], bottomCorner: [1], nearBottomCorner: nil, connector: .sprite(clippyTail), padX: 3, padYSnug: 1, padYRoomy: 2, usesDots: false),
        // 8: the Dynamic Island: a black capsule, round at both ends.
        BubbleDesign(id: 8, fill: Pixel(rgb: 0x000000), border: nil,
                     claude: Pixel(rgb: 0xD77757), shimmer: Pixel(rgb: 0xEB9F7F), dim: Pixel(rgb: 0x9A9A9F), error: Pixel(rgb: 0xFF6B80), ink: white,
                     topCorner: [], bottomCorner: [], nearBottomCorner: nil, connector: .none, padX: 4, padYSnug: 1, padYRoomy: 2, usesDots: false,
                     capsule: true),
        // 9: Sonner's toast: white, a pale grey outline, rounded corners.
        BubbleDesign(id: 9, fill: white, border: Pixel(rgb: 0xCDCDCD),
                     claude: ember, shimmer: emberLight, dim: Pixel(rgb: 0x6F6F6F), error: roseDark, ink: Pixel(rgb: 0x171717),
                     topCorner: [2, 1], bottomCorner: [2, 1], nearBottomCorner: nil, connector: .none, padX: 3, padYSnug: 1, padYRoomy: 2, usesDots: false),
        // 10: the rounded typing bubble: slate fill, a one-cell grey outline, a small corner on the side next to Clawd, three dots while thinking.
        BubbleDesign(id: 10, fill: slate, border: Pixel(rgb: 0x888888),
                     claude: Pixel(rgb: 0xD77757), shimmer: Pixel(rgb: 0xEB9F7F), dim: Pixel(rgb: 0x999999), error: Pixel(rgb: 0xFF6B80), ink: Pixel(rgb: 0xFFFFFF),
                     topCorner: [2, 1], bottomCorner: [2, 1], nearBottomCorner: [1], connector: .none, padX: 3, padYSnug: 1, padYRoomy: 2, usesDots: true),
        // 11: the comic thought bubble: a white oval with a navy outline and three circles shrinking towards the head.
        BubbleDesign(id: 11, fill: white, border: Pixel(rgb: 0x0B2234),
                     claude: ember, shimmer: emberLight, dim: Pixel(rgb: 0x546472), error: roseDark, ink: Pixel(rgb: 0x0B2234),
                     topCorner: [4, 2, 1], bottomCorner: [4, 2, 1], nearBottomCorner: nil, connector: .sprite(thoughtTrail), padX: 4, padYSnug: 1, padYRoomy: 2, usesDots: false),
        // 12: tmux powerline: an orange segment with the glyph, a slate segment with the words, arrow joints, square corners.
        BubbleDesign(id: 12, fill: Pixel(rgb: 0x303446), border: nil,
                     claude: Pixel(rgb: 0xF0A080), shimmer: Pixel(rgb: 0xFFD0BB), dim: Pixel(rgb: 0xA5ADCE), error: Pixel(rgb: 0xFF8092), ink: Pixel(rgb: 0xE6E9EF),
                     topCorner: [], bottomCorner: [], nearBottomCorner: nil, connector: .none, padX: 2, padYSnug: 1, padYRoomy: 2, usesDots: false,
                     form: .segments, segment: (fill: Pixel(rgb: 0xD77757), ink: Pixel(rgb: 0x1A1A1A))),
        // 13: the board's mock B: the ivory pixel bubble at 1 pt pixels, a stepped tail, a 10-row font, one drop-shadow row. Spinner, prompt and the
        // reduced-motion dot are `claude` (the mock's orange, darkened to 4.5:1); the verb and the dots are `shimmer` (B has no shimmer: its ember).
        BubbleDesign(id: 13, fill: ivory, border: Pixel(rgb: 0x4A463F),
                     claude: Pixel(rgb: 0xAA5E45), shimmer: Pixel(rgb: 0xA0563C), dim: Pixel(rgb: 0x5E5D59), error: Pixel(rgb: 0xB02040), ink: Pixel(rgb: 0x2B2A27),
                     topCorner: [4, 2, 1, 1], bottomCorner: [4, 2, 1, 1], nearBottomCorner: nil, connector: .sprite(refinedTail), padX: 6, padYSnug: 3, padYRoomy: 5,
                     usesDots: false, pixelPt: 1, face: .fine, padSkew: 1, snugSprite: refinedTailSnug, tipDefault: 6, tipClamp: 4, minWidth: 28,
                     dropShadow: Pixel(4, 4, 4, 56), keepsOffTheBodyWindow: true),
        // 14: the board's mock C, the macOS bubble, white or graphite with the system font. Roles: ink is the text, dim the chevron and the SENT and
        // INTERRUPTED words, claude the caret, the asterisk, the dots and the disc (shimmer is claude: C has no shimmer). Light is the base; Dark is `dark`.
        // The mock's greys and orange are darkened to 4.5:1 (D-4).
        BubbleDesign(id: 14, fill: Pixel(rgb: 0xFFFFFF), border: nil,
                     claude: Pixel(rgb: 0xAF6147), shimmer: Pixel(rgb: 0xAF6147), dim: Pixel(rgb: 0x76767B), error: Pixel(rgb: 0xB02040), ink: Pixel(rgb: 0x1D1D1F),
                     topCorner: [], bottomCorner: [], nearBottomCorner: nil, connector: .none, padX: 0, padYSnug: 0, padYRoomy: 0, usesDots: false,
                     pixelPt: 1, minWidth: 0, keepsOffTheBodyWindow: true, smooth: .macOS,
                     dark: SmoothColours(fill: Pixel(rgb: 0x2F2F31), border: nil, claude: Pixel(rgb: 0xE0896B), shimmer: Pixel(rgb: 0xE0896B), dim: Pixel(rgb: 0x98989D),
                                         error: Pixel(rgb: 0xFF6B80), ink: Pixel(rgb: 0xF5F5F7), cursor: nil, rim: (colour: Pixel(rgb: 0xFFFFFF), alpha: 0.13))),
        // 15: the board's mock D, Claude Code's panel: parchment or near-black, a 1 pt border, the system monospaced font, a diamond tail. ink is the text and
        // the block cursor (Dark has its own cursor colour), dim the prompt and the SENT and INTERRUPTED words, claude the spinner, the verb and the dots.
        BubbleDesign(id: 15, fill: Pixel(rgb: 0xF6F2E8), border: Pixel(rgb: 0xA9A395),
                     claude: Pixel(rgb: 0x994B30), shimmer: Pixel(rgb: 0xAD5536), dim: Pixel(rgb: 0x726E63), error: Pixel(rgb: 0xB02040), ink: Pixel(rgb: 0x3D3929),
                     topCorner: [], bottomCorner: [], nearBottomCorner: nil, connector: .none, padX: 0, padYSnug: 0, padYRoomy: 0, usesDots: false,
                     pixelPt: 1, minWidth: 0, keepsOffTheBodyWindow: true, smooth: .terminal,
                     dark: SmoothColours(fill: Pixel(rgb: 0x181816), border: Pixel(rgb: 0x888888), claude: Pixel(rgb: 0xD77757), shimmer: Pixel(rgb: 0xEB9F7F),
                                         dim: Pixel(rgb: 0x999999), error: Pixel(rgb: 0xFF6B80), ink: Pixel(rgb: 0xFFFFFF), cursor: Pixel(rgb: 0xE8E6DC), rim: nil)),
    ]
}

/// The finished bubble picture and where its parts are, in bubble pixels from the raster's top-left.
public struct BubbleBitmap {
    public let raster: Raster
    /// The box without the connector, in the style's units (bubble pixels; points for 14 and 15).
    public let box: (x: Int, y: Int, width: Int, height: Int)
    /// Above: the tip cell (bottom of the connector). Side: the cell of the connector nearest to Clawd.
    public let tip: (x: Int, y: Int)
    public let connection: BubbleConnection
    public let opening: BubbleOpening
    /// Above: the x, in units from the picture's left edge, of the edge of the tip that is over H (a cell's left edge opening right and its right edge
    /// opening left; the point itself for 14 and 15).
    public let tipX: Double
    /// Raster pixels per unit: 1 for the pixel styles (the compositor enlarges them), the backing for 14 and 15 (drawn at device pixels).
    public let pixelsPerUnit: Double
    public init(raster: Raster, box: (x: Int, y: Int, width: Int, height: Int), tip: (x: Int, y: Int), connection: BubbleConnection, opening: BubbleOpening,
                tipX: Double? = nil, pixelsPerUnit: Double = 1) {
        self.raster = raster; self.box = box; self.tip = tip; self.connection = connection; self.opening = opening
        self.tipX = tipX ?? (opening == .right ? Double(tip.x) : Double(tip.x + 1)); self.pixelsPerUnit = pixelsPerUnit
    }
    public var width: Int { raster.width }
    public var height: Int { raster.height }
}

extension BubbleDesign {
    /// A style's words in the case it draws them in.
    func cased(_ text: String) -> String {
        guard uppercase else { return text }
        return String(text.map { character -> Character in
            let upper = String(character).uppercased()
            return upper.count == 1 && face.supports(upper.first!) ? upper.first! : character
        })
    }

    /// Columns the runs take with the gaps between them, the last run's own gap not counted.
    private func width(of runs: [BubbleRun]) -> Int {
        var total = 0
        for (i, run) in runs.enumerated() {
            total += face.width(of: run.text)
            if i < runs.count - 1 { total += run.gapAfter ?? runGap }
        }
        return total
    }

    /// Style 12 keeps the first run (the glyph) in its own segment and drops the space that follows it.
    private func segmentSplit(_ runs: [BubbleRun]) -> (lead: BubbleRun, rest: [BubbleRun]) {
        guard let lead = runs.first else { return (BubbleRun("", .dim), []) }
        var rest = Array(runs.dropFirst())
        if let first = rest.first, first.text.allSatisfy({ $0 == " " }) { rest.removeFirst() }
        return (lead, rest)
    }

    /// Box width in bubble pixels for these runs.
    public func boxWidth(runs: [BubbleRun], dots: BubbleDots?, variant: BubbleVariant = .roomy) -> Int {
        if isSmooth { return SmoothBubble.layout(self, runs: runs, dots: dots, variant: variant).boxWidth }
        switch form {
        case .box:
            let dotsWidth: Int
            switch dots?.kind {
            case nil: dotsWidth = 0
            // a pixel style never gets 14's wave; it is sized like the lit kind if one is ever passed
            case .lit?, .wave?: dotsWidth = BubbleDots.width + 2
            case .counting?: dotsWidth = BubbleDots.countingGap + BubbleDots.countingWidth
            }
            return max(minWidth, width(of: runs) + dotsWidth + 2 * padX + 2 * frameX)
        case .halo:
            return max(minWidth, width(of: runs) + 2 * haloRadius + 2 * padX)
        case .segments:
            let (lead, rest) = segmentSplit(runs)
            // first segment: padding + glyph + padding; the arrow into the second; 1 gap; the words; padding; the closing arrow.
            return max(minWidth, (padX + face.width(of: lead.text) + padX) + SegmentLayout.depth + 1 + width(of: rest) + padX + SegmentLayout.depth)
        }
    }
    public func boxHeight(_ variant: BubbleVariant) -> Int {
        if let smooth { return SmoothBubble.metrics(smooth, variant).boxHeight }
        switch form {
        case .box: return face.lineRows + padTop(variant) + padBottom(variant) + 2 * frameY
        case .halo: return face.lineRows + padTop(variant) + padBottom(variant) + 2 * haloRadius
        case .segments: return face.lineRows + padTop(variant) + padBottom(variant)
        }
    }

    /// Whole bubble height (above placement) or width (side placement) including the connector, in bubble pixels.
    public func extent(runs: [BubbleRun], dots: BubbleDots?, variant: BubbleVariant, connection: BubbleConnection) -> (width: Int, height: Int) {
        let w = boxWidth(runs: runs, dots: dots, variant: variant), h = boxHeight(variant)
        return connection == .side ? (w + connectorColumns(variant), h) : (w + aboveLead, h + connectorRows(variant))
    }
    /// The picture's size: the shape (`extent`) and what is painted around it (the drop shadow).
    public func pictureExtent(runs: [BubbleRun], dots: BubbleDots?, variant: BubbleVariant, connection: BubbleConnection) -> (width: Int, height: Int) {
        let shape = extent(runs: runs, dots: dots, variant: variant, connection: connection), m = margins
        return (shape.width + 2 * m.side, shape.height + m.top + m.bottom)
    }

    /// Draws the bubble.
    /// - tipColumn: for `.above`, the box column the connector's tip cell sits in (clamped so the connector stays on the box).
    /// - fadeLevel: 4 = whole, 3...1 = a Bayer dither that thins the bubble out; 0 = nothing.
    public func render(runs: [BubbleRun], dots: BubbleDots? = nil, opening: BubbleOpening, connection: BubbleConnection,
                       variant: BubbleVariant, tipColumn: Int? = nil, fadeLevel: Int = 4, backing: Double = 1, appearance: BubbleAppearance = .light) -> BubbleBitmap {
        if isSmooth {
            return SmoothBubble.render(design: self, runs: runs, dots: dots, opening: opening, connection: connection, variant: variant, tipColumn: tipColumn,
                                       fadeLevel: fadeLevel, backing: backing, appearance: appearance)
        }
        var bitmap: BubbleBitmap
        switch form {
        case .box: bitmap = renderBox(runs: runs, dots: dots, opening: opening, connection: connection, variant: variant, tipColumn: tipColumn)
        case .halo: bitmap = renderHalo(runs: runs, opening: opening, connection: connection, variant: variant, tipColumn: tipColumn)
        case .segments: bitmap = renderSegments(runs: runs, opening: opening, connection: connection, variant: variant, tipColumn: tipColumn)
        }
        if fadeLevel < 4 {
            let level = max(0, fadeLevel)
            var raster = bitmap.raster
            for y in 0..<raster.height { for x in 0..<raster.width where raster.isOpaque(x, y) {
                if BubbleDesign.bayer[(y & 3) * 4 + (x & 3)] >= level * 4 { raster[x, y] = .clear }
            } }
            bitmap = BubbleBitmap(raster: raster, box: bitmap.box, tip: bitmap.tip, connection: bitmap.connection, opening: bitmap.opening)
        }
        return bitmap
    }

    /// Draws runs left to right from `x` and returns the x after the last glyph. A run that is not visible takes its width and draws nothing.
    @discardableResult
    private func draw(_ runs: [BubbleRun], into raster: inout Raster, x: Int, y: Int, background: Pixel) -> Int {
        var cursor = x
        for (i, run) in runs.enumerated() {
            if run.visible {
                let base = color(run.role)
                face.draw(run.text, into: &raster, x: cursor, y: y, color: base.pulsed(level: run.dimLevel, against: background))
            }
            cursor += face.width(of: run.text)
            if i < runs.count - 1 { cursor += run.gapAfter ?? runGap }
        }
        return cursor
    }

    private func connectorAnchorTip(connection: BubbleConnection, opening: BubbleOpening, boxX: Int, w: Int, h: Int, totalW: Int,
                                    tipColumn: Int?, margin: Int = 3) -> (x: Int, y: Int) {
        switch connection {
        case .above, .below:
            let col = min(max(tipColumn ?? (opening == .right ? tipMargin : w - 1 - tipMargin), margin), w - 1 - margin)
            return (boxX + col, connection == .below ? 0 : h - 1)
        case .side:
            return (opening == .right ? boxX : boxX + w - 1, h / 2)
        }
    }

    // MARK: box

    /// The connector hangs from the box (above and below placements; the below one is the above one turned over) or stands beside it.
    private enum Placement { case hanging, beside }

    private func renderBox(runs: [BubbleRun], dots: BubbleDots?, opening: BubbleOpening, connection: BubbleConnection,
                           variant: BubbleVariant, tipColumn: Int?) -> BubbleBitmap {
        let w = boxWidth(runs: runs, dots: dots), h = boxHeight(variant)
        let below = connection == .below
        let rows = connection == .side ? 0 : connectorRows(variant)
        let cols = connection == .side ? connectorColumns(variant) : aboveLead
        // Under the feet the box is the lower part of the shape and the connector stands above it: the box starts `oy` rows down, and a row of the
        // connector that the above placement draws at `r` (counted from the top of the box) is drawn at `cy(r)`, its mirror in the shape.
        let oy = below ? rows : 0
        func cy(_ aboveRow: Int) -> Int { below ? rows + h - 1 - aboveRow : aboveRow }
        // The connector sits on the side of the box that faces Clawd. Opening right: Clawd is on the left of a side box.
        let boxX = ((connection == .side || aboveLead > 0) && opening == .right) ? cols : 0
        let totalW = w + cols, totalH = h + rows
        // The shape is `totalW` x `totalH`; the picture also holds the drop shadow's row under it.
        var raster = Raster(width: totalW, height: totalH + margins.bottom)
        // A trail of dots takes the outline's colour (an ivory dot on a light window would not be seen).
        let dotColour = border ?? fill
        // The ring, when there is one, is the outermost cell; the outline and the fill lie inside it.
        let ringW = ring == nil ? 0 : 1
        let sw = w - 2 * ringW, sh = h - 2 * ringW

        // Box: filled cells, then the outline.
        func inset(_ y: Int) -> (left: Int, right: Int) {
            if capsule {
                let radius = Double(sh) / 2
                let dy = Double(min(y, sh - 1 - y)) + 0.5
                let half = (radius * radius - (radius - dy) * (radius - dy)).squareRoot()
                let both = max(0, Int((radius - half).rounded()))
                return (both, both)
            }
            func corner(_ profile: [Int], _ index: Int) -> Int { index < profile.count ? profile[index] : 0 }
            let fromTop = y, fromBottom = sh - 1 - y
            let top = corner(topCorner, fromTop), bottom = corner(bottomCorner, fromBottom)
            var left = max(top, bottom), right = left
            if let near = nearBottomCorner {
                // Small corner on the near (connector) side only: the corner next to Clawd (the lower one above him, the upper one under his feet);
                // the far one keeps the big radius.
                let nearIsLeft = opening == .right
                if below {
                    let small = corner(near, fromTop), farTop = corner(topCorner, fromTop)
                    let leftTop = nearIsLeft ? small : farTop, rightTop = nearIsLeft ? farTop : small
                    left = max(leftTop, bottom); right = max(rightTop, bottom)
                } else {
                    let small = corner(near, fromBottom), farBottom = corner(bottomCorner, fromBottom)
                    let leftBottom = nearIsLeft ? small : farBottom, rightBottom = nearIsLeft ? farBottom : small
                    left = max(top, leftBottom); right = max(top, rightBottom)
                }
            }
            return (left, right)
        }
        let insets = (0..<max(0, sh)).map(inset)
        func inside(_ x: Int, _ y: Int) -> Bool {
            // x and y in the box's own cells; the shape lies `ringW` cells in.
            let sx = x - ringW, sy = y - ringW
            guard sx >= 0, sy >= 0, sx < sw, sy < sh else { return false }
            let i = insets[sy]; return sx >= i.left && sx < sw - i.right
        }
        for y in 0..<h { for x in 0..<w {
            if inside(x, y) {
                let edge: Bool
                switch edges {
                case .all: edge = !(inside(x - 1, y) && inside(x + 1, y) && inside(x, y - 1) && inside(x, y + 1))
                case .topBottom: edge = y - ringW == 0 || y - ringW == sh - 1
                }
                raster[boxX + x, y + oy] = (edge ? border : nil) ?? fill
            } else if let ring, inside(x - 1, y) || inside(x + 1, y) || inside(x, y - 1) || inside(x, y + 1) {
                raster[boxX + x, y + oy] = ring
            }
        } }

        // Connector and its tip.
        var tip = (x: boxX, y: cy(h - 1))
        switch (connection == .side ? Placement.beside : Placement.hanging, connector) {
        case (.hanging, .tail):
            let margin = 3
            let col = min(max(tipColumn ?? (opening == .right ? tipMargin : w - 1 - tipMargin), margin), w - 1 - margin)
            for k in 0..<3 {
                let span = 3 - k
                for c in 0..<span {
                    let x = opening == .right ? col + c : col - c
                    raster[boxX + x, cy(h + k)] = fill
                }
            }
            tip = (boxX + col, cy(h + 2))
        case (.hanging, .dots):
            let col = min(max(tipColumn ?? (opening == .right ? tipMargin : w - 1 - tipMargin), 4), w - 5)
            if variant == .snug {
                // Two rows under the box: a gap, then a flat trail, the small dot nearest Clawd.
                let d1: [Int] = opening == .right ? [col + 2, col + 3] : [col - 3, col - 2]
                for x in d1 { raster[boxX + x, cy(h + 1)] = dotColour }
                raster[boxX + col, cy(h + 1)] = dotColour
                tip = (boxX + col, cy(h + 1))
            } else {
                let d1: [Int] = opening == .right ? [col + 1, col + 2] : [col - 2, col - 1]
                for y in [h + 1, h + 2] { for x in d1 { raster[boxX + x, cy(y)] = dotColour } }
                raster[boxX + col, cy(h + 3)] = dotColour
                tip = (boxX + col, cy(h + 3))
            }
        case (.hanging, .none):
            let col = min(max(tipColumn ?? (opening == .right ? tipMargin : w - 1 - tipMargin), 3), w - 4)
            tip = (boxX + col, cy(h - 1))
        case (.hanging, .sprite(let sprite)) where sprite.leadColumns > 0:
            let home = opening == .right ? 0 : totalW - 1
            if tipColumn == nil || tipColumn == home {
                for (k, row) in sprite.lead.enumerated() { for (c, cell) in row.enumerated() {
                    guard let colour = sprite.colour(cell, fill: fill, border: border, mid: dim) else { continue }
                    raster[opening == .right ? c : totalW - 1 - c, cy(totalH - sprite.lead.count + k)] = colour
                } }
                tip = (home, cy(totalH - 1))
            } else {
                // The display is too narrow for the bubble and it was slid inwards: the connector must stay over the head, so the three
                // circles hang under the box at the tip column instead of running out to the side.
                let col = tipColumn ?? home
                for (k, row) in sprite.above.enumerated() { for (c, cell) in row.enumerated() {
                    guard let colour = sprite.colour(cell, fill: fill, border: border, mid: dim) else { continue }
                    raster[opening == .right ? col + c : col - c, cy(h - 1 + k)] = colour
                } }
                tip = (col, cy(h - 1 + sprite.hangRows))
            }
        case (.hanging, .sprite(let roomy)):
            let sprite = variant == .snug ? (snugSprite ?? roomy) : roomy
            let bounds = tipBounds(opening: opening, boxWidth: w, variant: variant)
            let col = min(max(tipColumn ?? (opening == .right ? tipMargin : w - 1 - tipMargin), bounds.low), bounds.high)
            for (k, row) in sprite.above.enumerated() { for (c, cell) in row.enumerated() {
                guard let colour = sprite.colour(cell, fill: fill, border: border, mid: dim) else { continue }
                raster[boxX + (opening == .right ? col + c : col - c), cy(h - 1 + k)] = colour
            } }
            tip = (boxX + col, cy(h - 1 + sprite.hangRows))
        case (.beside, .tail):
            // Triangle pointing at Clawd: top edge straight, stair underneath, three columns from the box outwards.
            let top = h / 2 - 1
            for k in 0..<3 {
                let x = opening == .right ? boxX - 1 - k : boxX + w + k
                for r in 0..<(3 - k) { raster[x, top + r] = fill }
            }
            tip = (opening == .right ? 0 : totalW - 1, top)
        case (.beside, .dots):
            // gap, a 2 x 2 dot, a 1 x 1 dot, on the box's middle line, pointing at Clawd.
            let mid = h / 2
            for r in 0..<2 { for c in 0..<2 {
                let x = opening == .right ? boxX - 3 + c : boxX + w + 1 + c
                raster[x, mid - 1 + r] = dotColour
            } }
            let x = opening == .right ? boxX - 4 : boxX + w + 3
            raster[x, mid] = dotColour
            tip = (x, mid)
        case (.beside, .none):
            tip = (opening == .right ? boxX : boxX + w - 1, h / 2)
        case (.beside, .sprite(let roomy)):
            let sprite = variant == .snug ? (snugSprite ?? roomy) : roomy
            let n = sprite.side[0].count
            let top = h / 2 - sprite.side.count / 2
            for (k, row) in sprite.side.enumerated() { for (c, cell) in row.enumerated() {
                guard let colour = sprite.colour(cell, fill: fill, border: border, mid: dim) else { continue }
                raster[opening == .right ? boxX - (n - 1) + c : boxX + w - 1 + (n - 1 - c), top + k] = colour
            } }
            tip = (opening == .right ? 0 : totalW - 1, top + sprite.sideTipRow)
        }

        // The drop shadow: one row under every bottom-edge pixel of the box and the connector (a shape pixel with no shape pixel below it).
        if let dropShadow {
            var shadowed: [(x: Int, y: Int)] = []
            for y in 0..<totalH { for x in 0..<totalW where raster.isOpaque(x, y) && !raster.isOpaque(x, y + 1) { shadowed.append((x, y + 1)) } }
            for cell in shadowed { raster[cell.x, cell.y] = dropShadow }
        }

        // Text.
        let pad = padX + frameX
        var cursor = boxX + pad
        let textY = oy + frameY + padTop(variant)
        if let dots, dots.kind == .lit {
            let y = textY + 2
            for i in 0..<3 {
                let colour = i == dots.lit ? dim : BubbleDesign.dotsOff
                raster.fill(x: cursor + i * 3, y: y, width: 2, height: 2, colour)
            }
            cursor += BubbleDots.width + 2
        }
        let end = draw(runs, into: &raster, x: cursor, y: textY, background: fill)
        if let dots, dots.kind == .counting {
            // 2 x 2 dots 4 apart, standing on the line of the x-height letters, in the verb's colour; the dots not shown are not drawn.
            for i in 0..<dots.shown { raster.fill(x: end + BubbleDots.countingGap + i * 4, y: textY + 6, width: 2, height: 2, color(.shimmer)) }
        }
        return BubbleBitmap(raster: raster, box: (boxX, oy, w, h), tip: tip, connection: connection, opening: opening)
    }

    // MARK: halo

    /// Offsets inside a disc of the halo's radius (the corners of the square left out), so the outline is round like a die-cut.
    private var haloStencil: [(Int, Int)] {
        var cells: [(Int, Int)] = []
        let r = haloRadius
        for dy in -r...r { for dx in -r...r where dx * dx + dy * dy <= r * r + 1 { cells.append((dx, dy)) } }
        return cells
    }

    private func renderHalo(runs: [BubbleRun], opening: BubbleOpening, connection: BubbleConnection, variant: BubbleVariant,
                            tipColumn: Int?) -> BubbleBitmap {
        let w = boxWidth(runs: runs, dots: nil), h = boxHeight(variant)
        let cols = connection == .side ? connectorColumns(variant) : 0
        let rows = connection == .side ? 0 : connectorRows(variant)
        let boxX = (connection == .side && opening == .right) ? cols : 0
        var raster = Raster(width: w + cols, height: h + rows)
        // The words first, on their own, to know where the outline goes.
        var words = Raster(width: w, height: h)
        let x0 = haloRadius + padX + (w - (2 * haloRadius + 2 * padX + width(of: runs))) / 2, y0 = haloRadius + padTop(variant)
        draw(runs, into: &words, x: x0, y: y0, background: fill)
        let stencil = haloStencil
        for y in 0..<h { for x in 0..<w where words.isOpaque(x, y) {
            for (dx, dy) in stencil { raster[boxX + x + dx, y + dy] = fill }
        } }
        for y in 0..<h { for x in 0..<w where words.isOpaque(x, y) { raster[boxX + x, y] = words[x, y] } }
        let tip = connectorAnchorTip(connection: connection, opening: opening, boxX: boxX, w: w, h: h, totalW: w + cols, tipColumn: tipColumn)
        return BubbleBitmap(raster: raster, box: (boxX, 0, w, h), tip: tip, connection: connection, opening: opening)
    }

    // MARK: segments

    private func renderSegments(runs: [BubbleRun], opening: BubbleOpening, connection: BubbleConnection, variant: BubbleVariant,
                                tipColumn: Int?) -> BubbleBitmap {
        guard let segment else { return renderBox(runs: runs, dots: nil, opening: opening, connection: connection, variant: variant, tipColumn: tipColumn) }
        let w = boxWidth(runs: runs, dots: nil), h = boxHeight(variant)
        var raster = Raster(width: w, height: h)
        let (lead, rest) = segmentSplit(runs)
        let depth = SegmentLayout.depth
        let edge = padX + face.width(of: lead.text) + padX         // where the first segment ends
        let barEnd = w - depth                                      // where the second segment ends
        // An arrow, tip pointing right, is `depth` cells wide at the middle rows and one cell at the top and bottom row.
        func arrow(_ y: Int) -> Int { min(depth, min(y + 1, h - y)) }
        for y in 0..<h {
            for x in 0..<edge { raster[x, y] = segment.fill }
            for x in edge..<barEnd { raster[x, y] = fill }
            for c in 0..<arrow(y) { raster[edge + c, y] = segment.fill }
            for c in 0..<arrow(y) { raster[barEnd + c, y] = fill }
        }
        let textY = padTop(variant)
        if lead.visible {
            let ink = segment.ink.pulsed(level: lead.dimLevel, against: segment.fill)
            face.draw(lead.text, into: &raster, x: padX, y: textY, color: ink)
        }
        draw(rest, into: &raster, x: edge + depth + 1, y: textY, background: fill)
        let tip = connectorAnchorTip(connection: connection, opening: opening, boxX: 0, w: w, h: h, totalW: w, tipColumn: tipColumn)
        return BubbleBitmap(raster: raster, box: (0, 0, w, h), tip: tip, connection: connection, opening: opening)
    }

    static let bayer: [Int] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
}

/// Style 12's joints: an arrow is 4 cells deep (half the snug bar's height) in both variants.
enum SegmentLayout {
    static let depth = 4
}

extension Pixel {
    /// Step `level` (0...2) of the reduced-motion pulse of a colour drawn on `background`: the colour itself, then moved one and two thirds of the
    /// way towards black (when it is darker than the background) or white (when it is lighter). Moving away from the background never lowers
    /// the contrast, so a colour that has 4.5:1 keeps it at every step; the pulse used to move towards the background, down to 1.6:1.
    public func pulsed(level: Int, against background: Pixel) -> Pixel {
        guard level > 0 else { return self }
        let extreme = luminance >= background.luminance ? Pixel(255, 255, 255, 255) : Pixel(0, 0, 0, 255)
        return mixed(into: extreme, third: min(level, 2))
    }

    /// This opaque colour moved `third` thirds of the way towards `other`.
    public func mixed(into other: Pixel, third: Int) -> Pixel {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Int(a) * (3 - third) + Int(b) * third + 1) / 3) }
        return Pixel(mix(r, other.r), mix(g, other.g), mix(b, other.b), 255)
    }
}
