import Foundation
import CoreGraphics
import ClawdCore

/// Each member names one rule of spec 4.4 and the user's later requirements (9b). Production runs with `.all`; a test switches one
/// off to show that the rule's test turns red without it (the same convention as v1's GuardSet and the scheduler's guards).
public struct StageGuards: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// A bubble is never taller than the body's 6 units (and never over 48 pt).
    public static let heightCap = StageGuards(rawValue: 1 << 0)
    /// Beside Clawd, the bubble's vertical centre is the vertical centre of the body's 6 rows.
    public static let sideCentre = StageGuards(rawValue: 1 << 1)
    /// Clawd's on-screen position never depends on the bubble or the stage.
    public static let fixedClawd = StageGuards(rawValue: 1 << 2)
    /// The bubble never lies on Clawd's pixels, also in the fallbacks for a frame too small for it: the next placement that is clear of him
    /// is used, else the connector is left out, else there is no bubble.
    public static let clearOfClawd = StageGuards(rawValue: 1 << 3)
    /// The bubble never lies on the open menu (amendment D-5): a candidate that does is rejected like one that lies on Clawd.
    public static let clearOfMenu = StageGuards(rawValue: 1 << 4)
    public static let all: StageGuards = [.heightCap, .sideCentre, .fixedClawd, .clearOfClawd, .clearOfMenu]
}

public enum BubbleLayout {
    /// One bubble pixel in points: Clawd's half-unit at size 1, at every Clawd size (the 200 pt cap holds the longest verb at this size).
    public static let pixelPt = 2.0
    /// The cap of spec 4.4, in points.
    public static let maxWidthPt = 200.0, maxHeightPt = 48.0
    /// Nothing of a bubble may lie in the bottom band of the visible frame (apps' status lines).
    public static let bottomBandPt = 24.0
    /// Seconds a better placement must fit, without a break, before a bubble that fell back returns to it (amendment E3).
    public static let returnDelay = 0.5
    /// Rows a bubble may be tall: the body's 6 units at this size, and never more than the 48 pt cap, in the style's own pixels (`pixelPt`; styles
    /// 1-12 take 2 pt). `heightCap` off lifts the body limit.
    public static func rowBudget(scale: Double, pixelPt: Double = BubbleLayout.pixelPt, guards: StageGuards = .all) -> Int {
        let body = guards.contains(.heightCap) ? 6 * PetCatalog.pointsPerUnit * scale : maxHeightPt
        return Int((min(body, maxHeightPt) / pixelPt).rounded(.down))
    }
    /// The roomiest variant whose whole shape (box and connector) fits the budget. The below connection has the same extent as the above one
    /// (amendment D-3), so the budget is measured on `.above` for every side.
    public static func variant(design: BubbleDesign, runs: [BubbleRun], dots: BubbleDots?, scale: Double, guards: StageGuards = .all) -> BubbleVariant {
        let budget = rowBudget(scale: scale, pixelPt: design.pixelPt, guards: guards)
        return design.extent(runs: runs, dots: dots, variant: .roomy, connection: .above).height <= budget ? .roomy : .snug
    }
}

/// Clawd's pixels in global points, for the checks that a bubble never covers him.
public struct ClawdMask {
    public let raster: Raster
    /// Global point of the raster's top-left corner (y up: this is the top edge).
    public let topLeft: CGPoint
    public let cellPt: Double
    public init(raster: Raster, topLeft: CGPoint, cellPt: Double) { self.raster = raster; self.topLeft = topLeft; self.cellPt = cellPt }

    func cellRange(_ rect: CGRect) -> (x: Range<Int>, y: Range<Int>)? {
        let x0 = Int(((rect.minX - topLeft.x) / cellPt).rounded(.down)), x1 = Int(((rect.maxX - topLeft.x) / cellPt).rounded(.up))
        let y0 = Int(((topLeft.y - rect.maxY) / cellPt).rounded(.down)), y1 = Int(((topLeft.y - rect.minY) / cellPt).rounded(.up))
        let xLow = max(0, x0), xHigh = min(raster.width, x1), yLow = max(0, y0), yHigh = min(raster.height, y1)
        return xLow < xHigh && yLow < yHigh ? (xLow..<xHigh, yLow..<yHigh) : nil
    }
    public func intersects(_ rect: CGRect) -> Bool {
        guard let r = cellRange(rect) else { return false }
        for y in r.y { for x in r.x where raster.isOpaque(x, y) { return true } }
        return false
    }
    /// The horizontal extent of Clawd's pixels within a band of rows (global y range).
    public func horizontalExtent(from bottom: Double, to top: Double) -> (minX: Double, maxX: Double)? {
        guard let r = cellRange(CGRect(x: topLeft.x, y: bottom, width: Double(raster.width) * cellPt, height: top - bottom)) else { return nil }
        var lo = Int.max, hi = -1
        for y in r.y { for x in 0..<raster.width where raster.isOpaque(x, y) { lo = min(lo, x); hi = max(hi, x) } }
        return hi < 0 ? nil : (topLeft.x + Double(lo) * cellPt, topLeft.x + Double(hi + 1) * cellPt)
    }
    /// The global y of the bottom edge of the lowest opaque cell in the columns `centre - half ..< centre + half` (global x).
    public func bottomEdge(centreX: Double, halfWidthCells half: Int) -> Double? {
        let c = Int(((centreX - topLeft.x) / cellPt).rounded())
        let lo = max(0, c - half), hi = min(raster.width, c + half)
        guard lo < hi else { return nil }
        var lowest = -1
        for y in 0..<raster.height { for x in lo..<hi where raster.isOpaque(x, y) { lowest = y; break } }
        return lowest < 0 ? nil : topLeft.y - Double(lowest + 1) * cellPt
    }
}

/// Everything rule 4.4 needs about where Clawd is. Global AppKit points, y up.
public struct BubbleSite {
    /// H: x = centre of the torso's top row, y = top of the torso, or of the worn costume when that is higher.
    public var headTop: CGPoint
    /// F (amendment D-3): x = the torso's centre column (H's), y = the bottom of the lowest opaque cell of Clawd's mask in the torso's column band,
    /// so an item that hangs under the feet counts.
    public var feetBottom: CGPoint
    /// Vertical centre of the body's 6 rows.
    public var bodyCentreY: Double
    /// Points per Clawd unit: 4 x the size.
    public var unit: Double
    public var display: CGRect
    public var visible: CGRect
    public var clawd: ClawdMask
    /// The body window's rectangle: the bounds of the hit cells, widened to whole device pixels. A click anywhere inside it is taken by the body
    /// window, hit cell or not, so a style that keeps off it (13-15) is placed clear of it as well as of Clawd's pixels. nil: no such rule.
    public var bodyWindow: CGRect?
    /// The open menu's rectangle: no bubble may lie on it.
    public var menu: CGRect?
    /// `feetBottom` nil: worked out from the mask (the torso's column band around H).
    public init(headTop: CGPoint, bodyCentreY: Double, unit: Double, display: CGRect, visible: CGRect, clawd: ClawdMask, bodyWindow: CGRect? = nil,
                feetBottom: CGPoint? = nil, menu: CGRect? = nil) {
        self.headTop = headTop; self.bodyCentreY = bodyCentreY; self.unit = unit; self.display = display; self.visible = visible; self.clawd = clawd
        self.bodyWindow = bodyWindow; self.menu = menu
        self.feetBottom = feetBottom ?? CGPoint(x: headTop.x,
                                                y: clawd.bottomEdge(centreX: headTop.x, halfWidthCells: StageGeometry.torsoHalfWidth) ?? headTop.y - Double(StageGeometry.torsoRows) * clawd.cellPt)
    }
}

/// Where a placement lies relative to its chosen form: the picture as first drawn, or slid (above and below) / kept inside a narrow frame
/// (left and right).
public enum PlacementForm: Equatable { case normal, slid }

/// What a placement is, for the memory of amendment D-2 E: the actual side, the opening, the form and whether the connector shows. A change in any
/// field is a placement change.
public struct PlacementIdentity: Equatable {
    public var side: BubbleSide
    public var opening: BubbleOpening
    public var form: PlacementForm
    public var connectorHidden: Bool
    public init(side: BubbleSide, opening: BubbleOpening, form: PlacementForm, connectorHidden: Bool) {
        self.side = side; self.opening = opening; self.form = form; self.connectorHidden = connectorHidden
    }
}

public struct BubblePlan: Equatable {
    public var connection: BubbleConnection
    public var opening: BubbleOpening
    public var variant: BubbleVariant
    /// The whole bubble picture, everything painted (connector and shadow included), in global points.
    public var rect: CGRect
    /// The shape: the box and its connector, without what is painted around them. The body-height rule is measured on it.
    public var shapeRect: CGRect
    /// The box alone.
    public var boxRect: CGRect
    /// Above and below placement: the box column of the connector's tip cell.
    public var tipColumn: Int?
    /// The bubble is drawn without its connector (a frame so small that the connector would lie on Clawd): `rect` is the box alone.
    public var connectorHidden = false
    /// The side Clawd's bubble actually sits on (the chosen one, or the fallback that replaced it).
    public var side: BubbleSide = .below
    public var form: PlacementForm = .normal
    public var identity: PlacementIdentity { PlacementIdentity(side: side, opening: opening, form: form, connectorHidden: connectorHidden) }
}

/// Why a placement changed (amendment D-2 E): `safety` the shown placement stopped fitting, `returned` a better one had fitted for the return delay,
/// `directed` the side setting or a display, size or style change, `initial` the first placement of a bubble.
public enum PlacementChangeKind: Equatable { case initial, safety, returned, directed }

/// The placement memory of one bubble (amendment D-2 E1-E6). It lives in the runtime, is committed only from a presented frame and is cleared when
/// the bubble ends; the renderer stays pure: the memory goes in with the request and the proposed one comes out with the layout.
public struct BubbleMemory: Equatable {
    /// What a memory is valid for: the chosen side, the style, the size and the display. Any difference is a directed event and starts afresh.
    public struct Context: Equatable {
        public var side: BubbleSide, style: Int, scale: Double, display: CGRect
        public init(side: BubbleSide, style: Int, scale: Double, display: CGRect) { self.side = side; self.style = style; self.scale = scale; self.display = display }
    }
    public var context: Context
    public var shown: PlacementIdentity
    /// The better placement that fits now and has since `pendingSince` (E3), nil when the shown one is the best.
    public var pendingTarget: PlacementIdentity?
    public var pendingSince: TimeInterval?
    public init(context: Context, shown: PlacementIdentity, pendingTarget: PlacementIdentity? = nil, pendingSince: TimeInterval? = nil) {
        self.context = context; self.shown = shown; self.pendingTarget = pendingTarget; self.pendingSince = pendingSince
    }
}

public struct BubbleDecision {
    public var plan: BubblePlan
    public var memory: BubbleMemory
    /// How this frame's placement differs from the one shown before it (nil: it does not).
    public var change: PlacementChangeKind?
}

public enum BubblePlacement {
    /// The stateless placement: the first candidate of the order of amendment D-2 that passes V, nil when none does.
    public static func plan(design: BubbleDesign, runs: [BubbleRun], dots: BubbleDots?, site: BubbleSite, scale: Double,
                            guards: StageGuards = .all, side: BubbleSide = .below, backing: Double = 1) -> BubblePlan? {
        decide(design: design, runs: runs, dots: dots, site: site, scale: scale, guards: guards, side: side, backing: backing, memory: nil, now: 0, holdReturn: false)?.plan
    }

    /// The side order: the chosen side first, then the fallbacks. Left and right are absolute screen directions; the one toward the display middle
    /// comes first where both are fallbacks of a vertical side.
    static func sides(chosen: BubbleSide, towardsMiddle: BubbleSide) -> [BubbleSide] {
        let other: BubbleSide = towardsMiddle == .right ? .left : .right
        switch chosen {
        case .below: return [.below, .above, towardsMiddle, other]
        case .above: return [.above, .below, towardsMiddle, other]
        case .left: return [.left, .right, .below, .above]
        case .right: return [.right, .left, .below, .above]
        }
    }

    /// Decides the placement of one frame. Without a memory (or with one for another context) the result is the stateless first candidate (E6).
    /// With one, the shown placement stays while it passes V (E1) and changes at once when it stops (E2); a better one is taken only after it
    /// has passed V for `BubbleLayout.returnDelay` (E3), and not during the SENT fade (`holdReturn`).
    public static func decide(design: BubbleDesign, runs: [BubbleRun], dots: BubbleDots?, site: BubbleSite, scale: Double,
                              guards: StageGuards = .all, side chosen: BubbleSide = .below, backing: Double = 1,
                              memory: BubbleMemory?, now: TimeInterval, holdReturn: Bool) -> BubbleDecision? {
        let planner = Planner(design: design, runs: runs, dots: dots, site: site, scale: scale, guards: guards, backing: backing)
        let towards: BubbleSide = site.headTop.x < site.display.midX ? .right : .left
        let context = BubbleMemory.Context(side: chosen, style: design.id, scale: scale, display: site.display)
        var target: (identity: PlacementIdentity, plan: BubblePlan)?
        search: for side in sides(chosen: chosen, towardsMiddle: towards) {
            for identity in planner.order(side) {
                if let plan = planner.fit(identity) { target = (identity, plan); break search }
            }
        }
        guard let target else { return nil }
        func result(_ plan: BubblePlan, shown: PlacementIdentity, pending: (PlacementIdentity, TimeInterval)?, change: PlacementChangeKind?) -> BubbleDecision {
            BubbleDecision(plan: plan, memory: BubbleMemory(context: context, shown: shown, pendingTarget: pending?.0, pendingSince: pending?.1), change: change)
        }
        // An empty memory, or one made for another side, style, size or display: the target stands at once.
        guard let memory, memory.context == context else {
            let change: PlacementChangeKind? = memory == nil ? .initial : (memory?.shown == target.identity ? nil : .directed)
            return result(target.plan, shown: target.identity, pending: nil, change: change)
        }
        // E1: the shown placement stays while it passes V, recomputed from this frame's anchor and geometry.
        guard let shown = planner.fit(memory.shown) else {
            // E2: it stopped fitting.
            return result(target.plan, shown: target.identity, pending: nil, change: target.identity == memory.shown ? nil : .safety)
        }
        if target.identity == memory.shown || holdReturn { return result(shown, shown: memory.shown, pending: nil, change: nil) }
        // D-2a: a centered normal form of the chosen above or below side, connector shown, that still fits is kept whatever the opening that faces the
        // display's middle is now. Crossing the middle never changes it; the return of E3 is for a placement that is not that form.
        if memory.shown.side == chosen, chosen == .above || chosen == .below, memory.shown.form == .normal, !memory.shown.connectorHidden {
            return result(shown, shown: memory.shown, pending: nil, change: nil)
        }
        // E3: a better placement fits; it is taken after the return delay.
        let since = memory.pendingTarget == target.identity ? (memory.pendingSince ?? now) : now
        if now - since >= BubbleLayout.returnDelay - 1e-6 { return result(target.plan, shown: target.identity, pending: nil, change: .returned) }
        return result(shown, shown: memory.shown, pending: (target.identity, since), change: nil)
    }

    /// The placements of one frame: the style as it is drawn, and without its connector.
    final class Planner {
        let hasConnector: Bool
        let toMiddle: BubbleOpening
        let full: Builder
        lazy var bare: Builder = Builder(design: design.withoutConnector, runs: runs, dots: dots, site: site, scale: scale, guards: guards)
        let design: BubbleDesign, runs: [BubbleRun], dots: BubbleDots?, scale: Double, guards: StageGuards
        let site: BubbleSite

        init(design: BubbleDesign, runs: [BubbleRun], dots: BubbleDots?, site: BubbleSite, scale: Double, guards: StageGuards, backing: Double) {
            self.design = design; self.runs = runs; self.dots = dots; self.scale = scale; self.guards = guards
            var site = site
            // The visible frame, shrunk to the device pixel grid: every position taken from its edges is then on the grid, so that the renderer's snap
            // can never move a picture out of the frame.
            let g = max(1, backing), v = site.visible
            let minX = (v.minX * g).rounded(.up) / g, minY = (v.minY * g).rounded(.up) / g
            let maxX = (v.maxX * g).rounded(.down) / g, maxY = (v.maxY * g).rounded(.down) / g
            site.visible = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
            self.site = site
            full = Builder(design: design, runs: runs, dots: dots, site: site, scale: scale, guards: guards)
            hasConnector = design.connectorRows(full.variant) > 0 || design.connectorColumns(full.variant) > 0
            toMiddle = site.headTop.x < site.display.midX ? .right : .left
        }

        /// The forms of one side in the order of amendment D-2 (a)-(d): with the connector, normal then slid or kept in; then the same without it.
        func order(_ side: BubbleSide) -> [PlacementIdentity] {
            let preferred = toMiddle, other: BubbleOpening = preferred == .right ? .left : .right
            let forms: [(BubbleOpening, PlacementForm)]
            switch side {
            case .below, .above: forms = [(preferred, .normal), (other, .normal), (preferred, .slid), (other, .slid)]
            case .left: forms = [(.left, .normal), (.left, .slid)]
            case .right: forms = [(.right, .normal), (.right, .slid)]
            }
            var list = forms.map { PlacementIdentity(side: side, opening: $0.0, form: $0.1, connectorHidden: false) }
            if hasConnector { list += forms.map { PlacementIdentity(side: side, opening: $0.0, form: $0.1, connectorHidden: true) } }
            return list
        }

        /// The placement, if it passes V (`validate` false: as built, for a test that shows what V rejects).
        func fit(_ identity: PlacementIdentity, validate: Bool = true) -> BubblePlan? {
            guard !identity.connectorHidden || hasConnector else { return nil }
            let builder = identity.connectorHidden ? bare : full
            guard var plan = builder.build(identity) else { return nil }
            plan.connectorHidden = identity.connectorHidden
            return !validate || builder.valid(plan) ? plan : nil
        }
    }

    /// One drawing of the style placed on one side.
    struct Builder {
        let design: BubbleDesign, site: BubbleSite, guards: StageGuards
        let b: Double, m: (top: Int, side: Int, bottom: Int)
        let variant: BubbleVariant
        let boxW: Int, boxH: Int
        let verticalExtent: (width: Int, height: Int), besideExtent: (width: Int, height: Int)
        let visible: CGRect, band: Double
        let h: CGPoint, f: CGPoint

        init(design: BubbleDesign, runs: [BubbleRun], dots: BubbleDots?, site: BubbleSite, scale: Double, guards: StageGuards) {
            self.design = design; self.site = site; self.guards = guards
            b = design.pixelPt; m = design.margins
            variant = BubbleLayout.variant(design: design, runs: runs, dots: dots, scale: scale, guards: guards)
            boxW = design.boxWidth(runs: runs, dots: dots, variant: variant); boxH = design.boxHeight(variant)
            // `above`, `below` and `side` are the shapes; the picture is each of them and the margins around it (a drop shadow). Above and below have
            // the same extent (amendment D-3).
            verticalExtent = design.extent(runs: runs, dots: dots, variant: variant, connection: .above)
            besideExtent = design.extent(runs: runs, dots: dots, variant: variant, connection: .side)
            visible = site.visible; band = site.visible.minY + BubbleLayout.bottomBandPt
            h = site.headTop; f = site.feetBottom
        }

        /// Where an above or below picture puts the connector's tip: the column that centres the box on the anchor (amendment D-1).
        func centeredTip(_ opening: BubbleOpening) -> Int { design.centeredTip(opening, boxWidth: boxW) }

        /// The picture of an above or below placement: its x from the tip column, its vertical position from `y` (the shape's bottom edge for above,
        /// the picture's top edge for below).
        func verticalRect(_ opening: BubbleOpening, tip: Int) -> (left: Double, width: Double, height: Double) {
            let left = h.x - Double(tip + design.tipEdge(opening)) * b - Double(m.side) * b
            return (left, Double(verticalExtent.width + 2 * m.side) * b, Double(verticalExtent.height + m.top + m.bottom) * b)
        }
        func shapeIn(_ rect: CGRect, _ connection: BubbleConnection) -> CGRect {
            let size = connection == .side ? besideExtent : verticalExtent
            return CGRect(x: rect.minX + Double(m.side) * b, y: rect.minY + Double(m.bottom) * b, width: Double(size.width) * b, height: Double(size.height) * b)
        }
        func boxIn(_ rect: CGRect, _ connection: BubbleConnection, _ opening: BubbleOpening) -> CGRect {
            let shape = shapeIn(rect, connection)
            switch connection {
            case .above:
                let lead = opening == .right ? Double(design.aboveLead) * b : 0
                return CGRect(x: shape.minX + lead, y: shape.maxY - Double(boxH) * b, width: Double(boxW) * b, height: Double(boxH) * b)
            case .below:
                // The connector hangs from the box's top edge: the box is the shape's lower part.
                let lead = opening == .right ? Double(design.aboveLead) * b : 0
                return CGRect(x: shape.minX + lead, y: shape.minY, width: Double(boxW) * b, height: Double(boxH) * b)
            case .side:
                let cols = Double(design.connectorColumns(variant)) * b
                return CGRect(x: opening == .right ? shape.minX + cols : shape.minX, y: shape.minY, width: Double(boxW) * b, height: shape.height)
            }
        }
        func plan(_ side: BubbleSide, _ connection: BubbleConnection, _ opening: BubbleOpening, _ form: PlacementForm, _ r: CGRect, tip: Int?) -> BubblePlan {
            var plan = BubblePlan(connection: connection, opening: opening, variant: variant, rect: r, shapeRect: shapeIn(r, connection),
                                  boxRect: boxIn(r, connection, opening), tipColumn: tip)
            plan.side = side; plan.form = form
            return plan
        }

        /// A picture lies on Clawd's pixels or, for a style that keeps off it, inside the body window's rectangle.
        func blocked(_ r: CGRect) -> Bool {
            site.clawd.intersects(r) || (site.bodyWindow.map { r.intersects($0) } ?? false)
        }

        /// V (amendment D-2): the whole painted picture lies inside the visible frame, outside the bottom band, clear of Clawd, of his props, of the
        /// body window of styles 13-15 and of the open menu.
        func valid(_ plan: BubblePlan) -> Bool {
            let r = plan.rect, eps = 1e-6
            guard r.minX >= visible.minX - eps, r.maxX <= visible.maxX + eps, r.maxY <= visible.maxY + eps, r.minY >= band - eps else { return false }
            if guards.contains(.clearOfClawd), blocked(r) { return false }
            if guards.contains(.clearOfMenu), let menu = site.menu, r.intersects(menu) { return false }
            return true
        }

        // MARK: above and below

        /// The shape's bottom edge is 1 unit above H; what is painted under it (a drop shadow) lies in that gap.
        var aboveBottom: Double { max(h.y + site.unit - Double(m.bottom) * b, band) }
        /// The picture's top edge is 1 unit under F: the margin above the shape (a smooth style's) is part of the picture and keeps the gap too.
        var belowTop: Double { f.y - site.unit }

        /// A prop pixel above the head (a frame that is not overhead-clear) moves the bubble up; it never covers Clawd.
        func lifted(_ r: CGRect) -> CGRect {
            var r = r
            while blocked(r), r.maxY + b <= visible.maxY { r.origin.y += b }
            return r
        }
        /// The mirror of `lifted`: a prop pixel under the feet moves the bubble down in steps of one bubble pixel. It never moves it up.
        func lowered(_ r: CGRect) -> CGRect {
            var r = r
            while blocked(r), r.minY - b >= visible.minY - 4 * b { r.origin.y -= b }
            return r
        }
        func place(below: Bool, _ opening: BubbleOpening, tip: Int) -> CGRect {
            let v = verticalRect(opening, tip: tip)
            let y = below ? belowTop - v.height : aboveBottom
            let r = CGRect(x: v.left, y: y, width: v.width, height: v.height)
            return below ? lowered(r) : lifted(r)
        }

        func buildVertical(_ side: BubbleSide, _ opening: BubbleOpening, _ form: PlacementForm) -> BubblePlan? {
            let below = side == .below, connection: BubbleConnection = below ? .below : .above
            switch form {
            case .normal:
                let tip = centeredTip(opening)
                return plan(side, connection, opening, form, place(below: below, opening, tip: tip), tip: tip)
            case .slid:
                // Neither opening fits: slide the picture inward; the connector stays over the anchor. After the slide the obstacle step runs again.
                var r = place(below: below, opening, tip: centeredTip(opening))
                r.origin.x = min(max(r.minX, visible.minX), max(visible.minX, visible.maxX - r.width))
                let raw = Int(((h.x - (r.minX + Double(m.side) * b)) / b).rounded()) - design.tipEdge(opening)
                let low: Int, high: Int
                if design.tipClamp != nil || design.isSmooth {
                    let bounds = design.tipBounds(opening: opening, boxWidth: boxW, variant: variant)
                    low = bounds.low; high = max(bounds.low, bounds.high)
                } else {
                    let floor = design.tipMargin == 0 ? 0 : 3
                    low = floor; high = max(floor, verticalExtent.width - 1 - floor)
                }
                let connectorDrawn = design.connectorRows(variant) > 0
                var tip = min(max(raw, low), high)
                if connectorDrawn {
                    var aligned = false
                    // The tip sits over the anchor exactly as in the normal form: the picture's x is the one `verticalRect` gives for that tip column,
                    // so the slide only chooses the column. The nearest column may need the picture to move a fraction outward at a frame edge, so
                    // its neighbours are tried too; a column outside the artwork's tip bounds is never drawn there, so it is not a candidate.
                    for candidate in [raw, raw - 1, raw + 1] where candidate >= low && candidate <= high {
                        let left = verticalRect(opening, tip: candidate).left
                        guard left >= visible.minX - 1e-6, left + r.width <= visible.maxX + 1e-6 else { continue }
                        r.origin.x = left
                        tip = candidate; aligned = true
                        break
                    }
                    // No aligned position fits: the connector-hidden form comes later in the order.
                    guard aligned else { return nil }
                }
                r = below ? lowered(r) : lifted(r)
                return plan(side, connection, opening, form, r, tip: tip)
            }
        }

        // MARK: left and right

        /// Beside Clawd, on the body's vertical centre. The opening is the side itself, never the half of the display Clawd stands in.
        func sideRect(_ opening: BubbleOpening) -> CGRect {
            let centre = guards.contains(.sideCentre) ? site.bodyCentreY : h.y - Double(boxH) * b / 2
            // The box is centred on the body; what is painted under it (a drop shadow) is no part of that and still keeps out of the bottom band.
            let sideBottom = max(centre - Double(boxH) * b / 2 - Double(m.bottom) * b, band)
            let height = Double(besideExtent.height + m.top + m.bottom) * b, width = Double(besideExtent.width + 2 * m.side) * b
            let gap = site.unit
            let extent = site.clawd.horizontalExtent(from: sideBottom, to: sideBottom + height)
            let fallbackHalf = Double(StageGeometry.torsoHalfWidth) * site.clawd.cellPt
            var r: CGRect
            if opening == .right {
                let edge = (extent?.maxX ?? h.x + fallbackHalf) + gap
                r = CGRect(x: edge - Double(m.side) * b, y: sideBottom, width: width, height: height)
            } else {
                let edge = (extent?.minX ?? h.x - fallbackHalf) - gap
                r = CGRect(x: edge + Double(m.side) * b - width, y: sideBottom, width: width, height: height)
            }
            var guardCount = 0
            // up to 128 pt of pushing: 64 steps of a 2 pt pixel (as it always was), 128 of a 1 pt pixel
            while blocked(r), guardCount < Int(128 / b) { r.origin.x += (opening == .right ? b : -b); guardCount += 1 }
            return r
        }

        func buildBeside(_ side: BubbleSide, _ form: PlacementForm) -> BubblePlan? {
            let opening: BubbleOpening = side == .right ? .right : .left
            var r = sideRect(opening)
            if form == .slid {
                // A display too small for either side: keep the side as far in as the frame allows.
                r.origin.x = min(max(r.minX, visible.minX), max(visible.minX, visible.maxX - r.width))
                r.origin.y = max(r.minY, band)
            }
            return plan(side, .side, opening, form, r, tip: nil)
        }

        func build(_ identity: PlacementIdentity) -> BubblePlan? {
            switch identity.side {
            case .above, .below: return buildVertical(identity.side, identity.opening, identity.form)
            case .left, .right: return buildBeside(identity.side, identity.form)
            }
        }
    }
}
