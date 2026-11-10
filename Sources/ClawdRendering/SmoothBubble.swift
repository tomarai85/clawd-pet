import Foundation
import CoreGraphics
import CoreText

/// Styles 14 and 15 of the board's mock, drawn at device pixels (amendment D-1). The bitmap is the Raster's own format (sRGB, 8-bit, premultiplied
/// RGBA); its size is the picture's size in points times the backing; shapes and text are anti-aliased; the compositor blits it 1:1, so nothing is
/// resampled after drawing. The backing is an input of this call, never something applied at the blit.

/// How the context a 14 or 15 picture is drawn in is configured (R3-3). One function builds it, so a test asserts the value and a red row flips each flag.
public struct SmoothDrawingConfiguration: Equatable {
    public var antialiasing: Bool
    public var fontSmoothing: Bool
    public var fontSubpixelPositioning: Bool
    public var fontSubpixelQuantization: Bool
    public var interpolation: CGInterpolationQuality
    public var colorSpace: String
    /// Device pixels per point.
    public var scale: Double
    /// Bumped whenever a flag above changes; the smooth sidecar records it.
    public static let version = 1
}

/// The two smooth styles.
enum SmoothKind { case macOS, terminal }

public enum SmoothBubble {
    public static func drawingConfiguration(backing: Double) -> SmoothDrawingConfiguration {
        SmoothDrawingConfiguration(
            antialiasing: true,
            fontSmoothing: false,
            fontSubpixelPositioning: true,
            fontSubpixelQuantization: false,
            interpolation: .none,
            colorSpace: CGColorSpace.sRGB as String,
            scale: max(1, min(4, backing)))
    }

    // MARK: metrics, in points (the mock's numbers; D-4)

    struct Metrics {
        let boxHeight: Int
        let radius: Double
        /// Distance from the shape's edge to the first and the last item.
        let insetLeft: Double, insetRight: Double
        /// Between two items.
        let gap: Double
        /// Rows the connector hangs below the box (above placement) and columns it takes beside it (side placement), whole points.
        let tailRows: Int
        /// The height of the caret (14) or the block cursor (15).
        let markHeight: Double
        /// Where the tip sits along the box's near edge, from that edge.
        let tipOffset: Int
        let tailScale: Double
    }
    static func metrics(_ kind: SmoothKind, _ variant: BubbleVariant) -> Metrics {
        switch (kind, variant) {
        case (.macOS, .roomy): return Metrics(boxHeight: 24, radius: 9, insetLeft: 9, insetRight: 10, gap: 5, tailRows: 7, markHeight: 14, tipOffset: 12, tailScale: 1)
        case (.macOS, .snug): return Metrics(boxHeight: 18, radius: 7, insetLeft: 7, insetRight: 8, gap: 4, tailRows: 5, markHeight: 12, tipOffset: 12, tailScale: 0.75)
        case (.terminal, .roomy): return Metrics(boxHeight: 22, radius: 5, insetLeft: 8, insetRight: 8, gap: 0, tailRows: 6, markHeight: 13, tipOffset: 14, tailScale: 1)
        case (.terminal, .snug): return Metrics(boxHeight: 18, radius: 5, insetLeft: 8, insetRight: 8, gap: 0, tailRows: 6, markHeight: 11, tipOffset: 14, tailScale: 1)
        }
    }

    // Marks, from the mock's SVG (bubble-mock.html :291, :294) and CSS (:59, :61, :74).
    static let chevronSize = (width: 7.0, height: 10.0)
    static let asteriskSize = 12.0
    static let caretWidth = 2.0
    static let blockWidth = 7.0
    static let discDiameter = 6.0
    static let dotDiameter = 3.5, dotGap = 2.5, dotsMarginLeft = 1.0
    static let strokeWidth = 1.7
    /// 15's spinner slot (mock :75).
    static let spinnerSlot = 12.0
    /// 14's tail path, the mock's (:299), 14 x 8 with its tip at (3.2, 7.6).
    static let curvedTailSize = (width: 14.0, height: 8.0)
    static let curvedTailTip = (x: 3.2, y: 7.6)
    /// 15's tail: an 8 x 8 square turned 45 degrees has this half diagonal; its centre sits 0.5 inside the box's edge.
    static let diamondHalfDiagonal = 4.0 * 2.0.squareRoot()
    static let diamondCentreInset = 0.5

    /// The columns the tip of an above connector may take, from the box's left edge, so that the whole connector lies on the straight part of the
    /// bottom edge, never on a corner arc.
    static func tipBounds(_ kind: SmoothKind, opening: BubbleOpening, boxWidth w: Int, variant: BubbleVariant) -> (low: Int, high: Int) {
        let m = metrics(kind, variant)
        let near: Double, far: Double          // how far the connector reaches towards the near side of the tip and away from it
        switch kind {
        case .macOS:
            let s = m.tailScale
            near = (curvedTailTip.x - 1) * s; far = (13 - curvedTailTip.x) * s
        case .terminal:
            near = diamondHalfDiagonal; far = diamondHalfDiagonal
        }
        let left = opening == .right ? near : far, right = opening == .right ? far : near
        // The macOS tail is long and its tip is near one end, so with the tip at the middle of a narrow box its far end reaches into the corner arc. The
        // arc there is almost flat: the tail may run over it while the arc has risen no more than half a point (a device pixel at 2x), which is
        // sqrt(radius - 1/4) columns of it. The terminal's diamond keeps to the straight part.
        let slack = kind == .macOS ? (m.radius - 0.25).squareRoot() : 0
        return (Int((m.radius + left - slack).rounded(.up)), Int((Double(w) - m.radius - right + slack).rounded(.down)))
    }

    // MARK: layout

    /// One thing in the line: a mark, a run of text or the dots, with its place along the box.
    struct Item {
        enum Content { case mark(BubbleMark), text(String), dots }
        let content: Content
        let run: BubbleRun?
        let x: Double
        let width: Double
    }
    struct Layout {
        let boxWidth: Int
        let items: [Item]
    }

    /// The line's items with their widths (CoreText's, for text) and the whole-point width of the box that holds them.
    static func layout(_ design: BubbleDesign, runs: [BubbleRun], dots: BubbleDots?, variant: BubbleVariant) -> Layout {
        guard let kind = design.smooth else { return Layout(boxWidth: 0, items: []) }
        let m = metrics(kind, variant)
        var items: [Item] = []
        var x = m.insetLeft
        let cell = SmoothFonts.cellWidth(for: kind)
        for (i, run) in runs.enumerated() {
            let width: Double, content: Item.Content
            if let mark = run.mark {
                content = .mark(mark)
                let own: Double
                switch mark {
                case .chevron, .hook: own = chevronSize.width
                case .asterisk: own = asteriskSize
                case .caret: own = caretWidth
                case .block: own = blockWidth
                case .disc: own = kind == .terminal ? spinnerSlot : discDiameter
                }
                width = max(run.slot ?? 0, own)
            } else {
                content = .text(run.text)
                width = max(run.slot ?? 0, SmoothFonts.width(of: run.text, design: design))
            }
            items.append(Item(content: content, run: run, x: x, width: width))
            x += width
            if i < runs.count - 1 {
                // 14: the box's gap. 15: nothing between items, except one character cell after its prompt.
                switch kind {
                case .macOS: x += m.gap
                case .terminal: if case .block? = runs[i + 1].mark { x += cell }
                }
            }
        }
        if let dots {
            switch (kind, dots.kind) {
            case (.macOS, _):
                x += m.gap + dotsMarginLeft
                items.append(Item(content: .dots, run: nil, x: x, width: 3 * dotDiameter + 2 * dotGap))
                x += 3 * dotDiameter + 2 * dotGap
            case (.terminal, _):
                items.append(Item(content: .dots, run: nil, x: x, width: 3 * cell))
                x += 3 * cell
            }
        }
        return Layout(boxWidth: Int((x + m.insetRight).rounded(.up)), items: items)
    }
}


// MARK: rendering (styles 14 and 15)

extension SmoothBubble {
    /// The geometry of one picture, in points of the picture (y down).
    struct Geometry {
        let box: CGRect
        /// Everything painted with the fill colour: the box and the connector.
        let fillPaths: [CGPath]
        let boxPath: CGPath
        /// 15's outline of the box (inset by half the stroke) and of the connector's two outer sides.
        let tailOutline: CGPath?
        let tip: CGPoint
    }

    static func srgb(_ p: Pixel, alpha: Double = 1) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [Double(p.r) / 255, Double(p.g) / 255, Double(p.b) / 255, alpha])!
    }

    /// A rounded rectangle. Every shape of the picture is filled by a call of its own, so winding directions never matter.
    static func roundedRect(_ r: CGRect, radius: Double) -> CGPath {
        let p = CGMutablePath()
        let k = min(radius, r.width / 2, r.height / 2)
        p.move(to: CGPoint(x: r.minX + k, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - k, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + k), radius: k)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - k))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - k, y: r.maxY), radius: k)
        p.addLine(to: CGPoint(x: r.minX + k, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - k), radius: k)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + k))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + k, y: r.minY), radius: k)
        p.closeSubpath()
        return p
    }

    /// The mock's curved tail (path `M1 0H13C9.6 1.3 6.3 4.1 3.2 7.6 3.7 4.7 3.1 2.1 1 0Z`) with its tip at `tip`, scaled by `scale`; `mirrored`
    /// when the bubble opens left.
    static func curvedTail(tip: CGPoint, scale s: Double, mirrored: Bool, upsideDown: Bool = false) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 1, y: 0)); p.addLine(to: CGPoint(x: 13, y: 0))
        p.addCurve(to: CGPoint(x: 3.2, y: 7.6), control1: CGPoint(x: 9.6, y: 1.3), control2: CGPoint(x: 6.3, y: 4.1))
        p.addCurve(to: CGPoint(x: 1, y: 0), control1: CGPoint(x: 3.7, y: 4.7), control2: CGPoint(x: 3.1, y: 2.1))
        p.closeSubpath()
        // upsideDown: the tail turned about the box's horizontal axis (under the feet, pointing up at Clawd); the picture's y runs down.
        var t = CGAffineTransform(translationX: tip.x, y: tip.y).scaledBy(x: mirrored ? -s : s, y: upsideDown ? -s : s).translatedBy(x: -3.2, y: -7.6)
        return p.copy(using: &t) ?? p
    }

    /// The beak 14 uses beside the head: the same curved sweep turned to point sideways, rooted on the straight part of the box's side.
    static func beak(edgeX: Double, centreY: Double, reach: Double, half: Double, towardsLeft: Bool) -> CGPath {
        let d = towardsLeft ? -1.0 : 1.0
        let p = CGMutablePath()
        p.move(to: CGPoint(x: edgeX - d * 1, y: centreY - half))
        p.addLine(to: CGPoint(x: edgeX, y: centreY - half))
        p.addCurve(to: CGPoint(x: edgeX + d * reach, y: centreY), control1: CGPoint(x: edgeX + d * reach * 0.36, y: centreY - half * 0.9),
                   control2: CGPoint(x: edgeX + d * reach * 0.7, y: centreY - half * 0.4))
        p.addCurve(to: CGPoint(x: edgeX, y: centreY + half), control1: CGPoint(x: edgeX + d * reach * 0.7, y: centreY + half * 0.4),
                   control2: CGPoint(x: edgeX + d * reach * 0.36, y: centreY + half * 0.9))
        p.addLine(to: CGPoint(x: edgeX - d * 1, y: centreY + half))
        p.closeSubpath()
        return p
    }

    static func diamond(centre c: CGPoint, half d: Double) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y - d)); p.addLine(to: CGPoint(x: c.x + d, y: c.y)); p.addLine(to: CGPoint(x: c.x, y: c.y + d)); p.addLine(to: CGPoint(x: c.x - d, y: c.y))
        p.closeSubpath()
        return p
    }

    /// Where everything of a picture lies. `boxOrigin` is the box's top-left in the picture; `tipX` the tip's distance from the box's left edge.
    static func geometry(_ kind: SmoothKind, variant: BubbleVariant, boxWidth w: Int, boxOrigin: CGPoint, tipX: Double, opening: BubbleOpening,
                         connection: BubbleConnection, connectorShown: Bool) -> Geometry {
        let m = metrics(kind, variant), h = Double(m.boxHeight)
        let box = CGRect(x: boxOrigin.x, y: boxOrigin.y, width: Double(w), height: h)
        let boxPath = roundedRect(box, radius: m.radius)
        var fill: [CGPath] = [boxPath]
        var outline: CGPath?
        var tip = CGPoint(x: box.minX + tipX, y: connection == .below ? box.minY : box.maxY)
        guard connectorShown else { return Geometry(box: box, fillPaths: fill, boxPath: boxPath, tailOutline: nil, tip: tip) }
        switch (kind, connection) {
        case (.macOS, .above):
            let s = m.tailScale
            let top = box.maxY - 1
            let tipPoint = CGPoint(x: box.minX + tipX, y: top + curvedTailSize.height * s * (curvedTailTip.y / curvedTailSize.height))
            fill.append(curvedTail(tip: tipPoint, scale: s, mirrored: opening == .left))
            tip = tipPoint
        case (.macOS, .side):
            let reach = Double(m.tailRows), half = variant == .snug ? 2.4 : 3.2
            let edge = opening == .right ? box.minX : box.maxX
            fill.append(beak(edgeX: edge, centreY: box.midY, reach: reach, half: half, towardsLeft: opening == .right))
            tip = CGPoint(x: edge + (opening == .right ? -reach : reach), y: box.midY)
        case (.macOS, .below):
            // The tail mirrored about the box's horizontal axis: it hangs from the box's top edge and its tip points up.
            let s = m.tailScale
            let bottom = box.minY + 1
            let tipPoint = CGPoint(x: box.minX + tipX, y: bottom - curvedTailSize.height * s * (curvedTailTip.y / curvedTailSize.height))
            fill.append(curvedTail(tip: tipPoint, scale: s, mirrored: opening == .left, upsideDown: true))
            tip = tipPoint
        case (.terminal, .below):
            let d = diamondHalfDiagonal, centre = CGPoint(x: box.minX + tipX, y: box.minY + diamondCentreInset)
            fill.append(diamond(centre: centre, half: d))
            let inner = d - 0.5 * 2.0.squareRoot()
            let line = CGMutablePath()
            line.move(to: CGPoint(x: centre.x + inner, y: centre.y)); line.addLine(to: CGPoint(x: centre.x, y: centre.y - inner)); line.addLine(to: CGPoint(x: centre.x - inner, y: centre.y))
            outline = line
            tip = CGPoint(x: centre.x, y: centre.y - d)
        case (.terminal, .above):
            let d = diamondHalfDiagonal, centre = CGPoint(x: box.minX + tipX, y: box.maxY - diamondCentreInset)
            fill.append(diamond(centre: centre, half: d))
            let inner = d - 0.5 * 2.0.squareRoot()
            let line = CGMutablePath()
            line.move(to: CGPoint(x: centre.x + inner, y: centre.y)); line.addLine(to: CGPoint(x: centre.x, y: centre.y + inner)); line.addLine(to: CGPoint(x: centre.x - inner, y: centre.y))
            outline = line
            tip = CGPoint(x: centre.x, y: centre.y + d)
        case (.terminal, .side):
            let d = diamondHalfDiagonal
            let cx = opening == .right ? box.minX + diamondCentreInset : box.maxX - diamondCentreInset
            let centre = CGPoint(x: cx, y: box.midY)
            fill.append(diamond(centre: centre, half: d))
            let inner = d - 0.5 * 2.0.squareRoot()
            let line = CGMutablePath()
            let outwards = opening == .right ? -1.0 : 1.0
            line.move(to: CGPoint(x: centre.x, y: centre.y - inner)); line.addLine(to: CGPoint(x: centre.x + outwards * inner, y: centre.y)); line.addLine(to: CGPoint(x: centre.x, y: centre.y + inner))
            outline = line
            tip = CGPoint(x: centre.x + outwards * d, y: centre.y)
        }
        return Geometry(box: box, fillPaths: fill, boxPath: boxPath, tailOutline: outline, tip: tip)
    }

    // MARK: contexts

    static func makeContext(width: Int, height: Int, configuration c: SmoothDrawingConfiguration, gray: Bool = false) -> CGContext? {
        let context: CGContext?
        if gray {
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        } else {
            guard let space = CGColorSpace(name: c.colorSpace as CFString) else { return nil }
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = context else { return nil }
        ctx.setAllowsAntialiasing(c.antialiasing); ctx.setShouldAntialias(c.antialiasing)
        ctx.setAllowsFontSmoothing(c.fontSmoothing); ctx.setShouldSmoothFonts(c.fontSmoothing)
        ctx.setAllowsFontSubpixelPositioning(c.fontSubpixelPositioning); ctx.setShouldSubpixelPositionFonts(c.fontSubpixelPositioning)
        ctx.setAllowsFontSubpixelQuantization(c.fontSubpixelQuantization); ctx.setShouldSubpixelQuantizeFonts(c.fontSubpixelQuantization)
        ctx.interpolationQuality = c.interpolation
        // y down, in points of the picture
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: c.scale, y: -c.scale)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        return ctx
    }

    // MARK: the shadow

    /// A soft shadow's alpha for every device pixel: the shape's coverage, blurred by a raised-cosine kernel of support `radius` points, shifted by
    /// (`dx`, `dy`) points and scaled by `alpha`. The kernel has finite support, so the shadow ends exactly where D-2 c needs it to.
    static func shadowAlpha(mask: [UInt8], width: Int, height: Int, scale: Double, radius: Double, dx: Double, dy: Double, alpha: Double) -> [Float] {
        let r = radius * scale
        let n = max(0, Int(r.rounded(.up)) - 1)
        var kernel: [Float] = []
        for d in -n...n { kernel.append(n == 0 ? 1 : Float((1 + cos(Double.pi * Double(d) / r)) / 2)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var horizontal = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            var sum: Float = 0
            for (k, w) in kernel.enumerated() { let sx = x + k - n; if sx >= 0 && sx < width { sum += w * Float(mask[y * width + sx]) / 255 } }
            horizontal[y * width + x] = sum
        } }
        var out = [Float](repeating: 0, count: width * height)
        let shiftX = Int((dx * scale).rounded()), shiftY = Int((dy * scale).rounded())
        for y in 0..<height { for x in 0..<width {
            var sum: Float = 0
            for (k, w) in kernel.enumerated() { let sy = y - shiftY + k - n; if sy >= 0 && sy < height && x - shiftX >= 0 && x - shiftX < width { sum += w * horizontal[sy * width + x - shiftX] } }
            out[y * width + x] = sum * Float(alpha)
        } }
        return out
    }

    /// The shadows of a style in an appearance, as the mock states them with the soft one tightened to fit the margins (D-2 c, D-5): black with
    /// alpha, a blur radius and an offset, in points.
    static func shadowLayers(_ kind: SmoothKind, _ appearance: BubbleAppearance) -> [(radius: Double, dx: Double, dy: Double, alpha: Double)] {
        switch (kind, appearance) {
        case (.macOS, .light): return [(2, 0, 1, 0.16), (1, 0, 0, 0.30)]
        case (.macOS, .dark): return [(2, 0, 1, 0.50), (1, 0, 0, 0.75)]
        case (.terminal, .light): return [(1.5, 0, 1, 0.12)]
        case (.terminal, .dark): return [(2, 0, 1, 0.50)]
        }
    }
}


// MARK: drawing the line (styles 14 and 15)

extension SmoothBubble {
    static func strokeStyle(_ ctx: CGContext, _ colour: CGColor, width: Double = strokeWidth) {
        ctx.setStrokeColor(colour); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    }

    /// 14's chevron (mock :291): `M1.6 1.6 5.2 5 1.6 8.4`, 7 x 10, stroke 1.7, round caps and joins.
    static func drawChevron(_ ctx: CGContext, x: Double, centreY: Double, colour: CGColor) {
        ctx.saveGState(); ctx.translateBy(x: x, y: centreY - chevronSize.height / 2)
        let p = CGMutablePath(); p.move(to: CGPoint(x: 1.6, y: 1.6)); p.addLine(to: CGPoint(x: 5.2, y: 5)); p.addLine(to: CGPoint(x: 1.6, y: 8.4))
        strokeStyle(ctx, colour); ctx.addPath(p); ctx.strokePath(); ctx.restoreGState()
    }
    /// ⎿ as a shape: an L at the chevron's weight and size, the bar down the left and the foot along the bottom.
    static func drawHook(_ ctx: CGContext, x: Double, centreY: Double, colour: CGColor) {
        ctx.saveGState(); ctx.translateBy(x: x, y: centreY - chevronSize.height / 2)
        let p = CGMutablePath(); p.move(to: CGPoint(x: 1.6, y: 1.6)); p.addLine(to: CGPoint(x: 1.6, y: 8.4)); p.addLine(to: CGPoint(x: 5.4, y: 8.4))
        strokeStyle(ctx, colour); ctx.addPath(p); ctx.strokePath(); ctx.restoreGState()
    }
    /// 14's asterisk (mock :294): eight strokes in a 12 x 12 box, turned by `degrees` about its centre.
    static func drawAsterisk(_ ctx: CGContext, x: Double, centreY: Double, degrees: Double, colour: CGColor) {
        ctx.saveGState(); ctx.translateBy(x: x + asteriskSize / 2, y: centreY); ctx.rotate(by: degrees * .pi / 180)
        let p = CGMutablePath()
        func line(_ a: (Double, Double), _ b: (Double, Double)) { p.move(to: CGPoint(x: a.0, y: a.1)); p.addLine(to: CGPoint(x: b.0, y: b.1)) }
        line((0, -5), (0, -1.7)); line((0, 5), (0, 1.7)); line((-5, 0), (-1.7, 0)); line((5, 0), (1.7, 0))
        line((-3.5, -3.5), (-1.2, -1.2)); line((3.5, 3.5), (1.2, 1.2)); line((3.5, -3.5), (1.2, -1.2)); line((-3.5, 3.5), (-1.2, 1.2))
        strokeStyle(ctx, colour); ctx.addPath(p); ctx.strokePath(); ctx.restoreGState()
    }
    static func drawBar(_ ctx: CGContext, x: Double, centreY: Double, width: Double, height: Double, radius: Double, colour: CGColor) {
        ctx.setFillColor(colour); ctx.addPath(roundedRect(CGRect(x: x, y: centreY - height / 2, width: width, height: height), radius: radius)); ctx.fillPath()
    }
    static func drawDisc(_ ctx: CGContext, centre: CGPoint, diameter: Double, colour: CGColor) {
        ctx.setFillColor(colour); ctx.fillEllipse(in: CGRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2, width: diameter, height: diameter))
    }

    /// Draws one line of attributed text with its baseline at `baseline`.
    static func drawText(_ ctx: CGContext, _ text: NSAttributedString, x: Double, baseline: Double) {
        ctx.saveGState()
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        ctx.restoreGState()
    }

    /// Draws everything of the line into `ctx` (points of the picture, y down).
    static func drawContent(_ ctx: CGContext, design d: BubbleDesign, layout: Layout, runs: [BubbleRun], dots: BubbleDots?, box: CGRect, variant: BubbleVariant) {
        guard let kind = d.smooth else { return }
        let m = metrics(kind, variant)
        let centre = box.midY
        let font = SmoothFonts.primary(d)
        let baseline = centre + Double(CTFontGetAscent(font) - CTFontGetDescent(font)) / 2
        for item in layout.items {
            let x = box.minX + item.x
            switch item.content {
            case .mark(let mark):
                guard let run = item.run, run.visible else { continue }
                let colour = srgb(d.color(run.role).pulsed(level: run.dimLevel, against: d.fill))
                switch mark {
                case .chevron: drawChevron(ctx, x: x, centreY: centre, colour: colour)
                case .hook: drawHook(ctx, x: x, centreY: centre, colour: colour)
                case .asterisk(let degrees): drawAsterisk(ctx, x: x, centreY: centre, degrees: degrees, colour: colour)
                case .caret: drawBar(ctx, x: x, centreY: centre, width: caretWidth, height: m.markHeight, radius: 1, colour: colour)
                case .block: drawBar(ctx, x: x, centreY: centre, width: blockWidth, height: m.markHeight, radius: 0, colour: srgb(d.cursorColour ?? d.ink))
                case .disc: drawDisc(ctx, centre: CGPoint(x: x + (kind == .terminal ? SmoothFonts.cellWidth(for: kind) / 2 : discDiameter / 2), y: centre), diameter: discDiameter, colour: colour)
                }
            case .text(let text):
                guard let run = item.run, run.visible else { continue }
                let base = srgb(d.color(run.role).pulsed(level: run.dimLevel, against: d.fill))
                var glint: ClosedRange<Int>?
                if let g = run.glint { glint = (g - 1)...(g + 1) }
                drawText(ctx, SmoothFonts.attributed(text, design: d, colour: base, glint: glint, glintColour: srgb(d.color(.shimmer))), x: x, baseline: baseline)
            case .dots:
                guard let dots else { continue }
                switch dots.kind {
                case .wave:
                    for i in 0..<3 {
                        let alpha = i < dots.opacities.count ? dots.opacities[i] : 1
                        let cx = x + dotDiameter / 2 + Double(i) * (dotDiameter + dotGap)
                        drawDisc(ctx, centre: CGPoint(x: cx, y: centre), diameter: dotDiameter, colour: srgb(d.color(.claude), alpha: alpha))
                    }
                case .counting:
                    // "..." with the first `shown` periods drawn: the others keep their cells
                    let shown = String(repeating: ".", count: dots.shown)
                    drawText(ctx, SmoothFonts.attributed(shown, design: d, colour: srgb(d.color(.claude))), x: x, baseline: baseline)
                case .lit: break
                }
            }
        }
    }
}


// MARK: one picture (styles 14 and 15)

extension SmoothBubble {
    /// Everything a picture's drawing needs, worked out before any pixel is drawn.
    struct Prepared {
        let design: BubbleDesign
        let kind: SmoothKind
        let variant: BubbleVariant
        let metrics: Metrics
        let layout: Layout
        let geometry: Geometry
        let configuration: SmoothDrawingConfiguration
        let pictureWidth: Int, pictureHeight: Int          // points
        let pixelWidth: Int, pixelHeight: Int              // device pixels
        let tipX: Double
        let opening: BubbleOpening
        let connection: BubbleConnection
        let appearance: BubbleAppearance
    }

    static func prepare(design: BubbleDesign, runs: [BubbleRun], dots: BubbleDots?, opening: BubbleOpening, connection: BubbleConnection, variant: BubbleVariant,
                        tipColumn: Int?, backing: Double, appearance: BubbleAppearance) -> Prepared {
        let d = design.appearing(appearance)
        let kind = d.smooth ?? .macOS
        let m = metrics(kind, variant)
        let configuration = drawingConfiguration(backing: backing)
        let layout = layout(d, runs: runs, dots: dots, variant: variant)
        let w = layout.boxWidth
        let margins = d.margins
        let cols = connection == .side ? d.connectorColumns(variant) : 0, rows = connection == .side ? 0 : d.connectorRows(variant)
        let picW = w + cols + 2 * margins.side, picH = m.boxHeight + rows + margins.top + margins.bottom
        // Under the feet the connector stands above the box: the box starts `rows` lower.
        let boxOrigin = CGPoint(x: Double(margins.side) + (connection == .side && opening == .right ? Double(cols) : 0),
                                y: Double(margins.top) + (connection == .below ? Double(rows) : 0))
        let bounds = tipBounds(kind, opening: opening, boxWidth: w, variant: variant)
        let wanted = tipColumn ?? (opening == .right ? m.tipOffset : w - m.tipOffset)
        let tipX = Double(min(max(wanted, bounds.low), max(bounds.low, bounds.high)))
        let geometry = geometry(kind, variant: variant, boxWidth: w, boxOrigin: boxOrigin, tipX: tipX, opening: opening, connection: connection, connectorShown: d.connectorShown)
        return Prepared(design: d, kind: kind, variant: variant, metrics: m, layout: layout, geometry: geometry, configuration: configuration, pictureWidth: picW, pictureHeight: picH,
                        pixelWidth: max(1, Int((Double(picW) * configuration.scale).rounded())), pixelHeight: max(1, Int((Double(picH) * configuration.scale).rounded())),
                        tipX: tipX, opening: opening, connection: connection, appearance: appearance)
    }

    /// The shape's coverage of every device pixel (0...255), drawn with the same configuration as the picture: what the shadow is cast from and what the
    /// tests measure the picture against.
    static func shapeCoverage(_ p: Prepared) -> [UInt8] {
        guard let context = makeContext(width: p.pixelWidth, height: p.pixelHeight, configuration: p.configuration, gray: true), let data = context.data else {
            return [UInt8](repeating: 0, count: p.pixelWidth * p.pixelHeight)
        }
        context.setFillColor(gray: 1, alpha: 1)
        for path in p.geometry.fillPaths { context.addPath(path); context.fillPath() }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: p.pixelWidth * p.pixelHeight))
    }

    /// A picture is made again only when something its pixels depend on changes: the style, its words and animation state, the placement, the fade,
    /// the backing and the appearance. Bounded; an entry is never reused across backing, appearance or opacity.
    struct CacheKey: Hashable {
        let style: Int, content: String, opening: BubbleOpening, connection: BubbleConnection, variant: BubbleVariant
        let tip: Int?, fadeLevel: Int, backing: Double, appearance: BubbleAppearance, connectorShown: Bool
    }
    static let cacheLimit = 64
    private static let cacheLock = NSLock()
    private static var cache: [CacheKey: BubbleBitmap] = [:]
    private static var cacheOrder: [CacheKey] = []
    static var cachedPictures: Int { cacheLock.lock(); defer { cacheLock.unlock() }; return cache.count }

    /// The bubble's picture, from the cache when this very picture was drawn before.
    static func render(design: BubbleDesign, runs: [BubbleRun], dots: BubbleDots?, opening: BubbleOpening, connection: BubbleConnection,
                       variant: BubbleVariant, tipColumn: Int?, fadeLevel: Int, backing: Double, appearance: BubbleAppearance) -> BubbleBitmap {
        let key = CacheKey(style: design.id, content: "\(runs)\(String(describing: dots))", opening: opening, connection: connection, variant: variant,
                           tip: tipColumn, fadeLevel: fadeLevel, backing: backing, appearance: appearance, connectorShown: design.connectorShown)
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let made = draw(design: design, runs: runs, dots: dots, opening: opening, connection: connection, variant: variant, tipColumn: tipColumn,
                        fadeLevel: fadeLevel, backing: backing, appearance: appearance)
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cache[key] == nil {
            cache[key] = made; cacheOrder.append(key)
            if cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        }
        return made
    }

    /// Draws the picture: the shadow, the fill, the border, the line, and the fade over all of it.
    static func draw(design: BubbleDesign, runs: [BubbleRun], dots: BubbleDots?, opening: BubbleOpening, connection: BubbleConnection,
                     variant: BubbleVariant, tipColumn: Int?, fadeLevel: Int, backing: Double, appearance: BubbleAppearance) -> BubbleBitmap {
        let p = prepare(design: design, runs: runs, dots: dots, opening: opening, connection: connection, variant: variant, tipColumn: tipColumn, backing: backing, appearance: appearance)
        let d = p.design, geometry = p.geometry, m = p.metrics
        let pxW = p.pixelWidth, pxH = p.pixelHeight
        guard let ctx = makeContext(width: pxW, height: pxH, configuration: p.configuration), let data = ctx.data else {
            return BubbleBitmap(raster: Raster(width: 0, height: 0), box: (0, 0, 0, 0), tip: (0, 0), connection: connection, opening: opening)
        }

        // the shadow goes into the bitmap first, black and premultiplied; the shape is painted over it
        let mask = shapeCoverage(p)
        var shadow = [Float](repeating: 0, count: pxW * pxH)
        for layer in shadowLayers(p.kind, appearance) {
            let a = shadowAlpha(mask: mask, width: pxW, height: pxH, scale: p.configuration.scale, radius: layer.radius, dx: layer.dx, dy: layer.dy, alpha: layer.alpha)
            // the nearer shadow lies over the farther one
            for i in 0..<shadow.count { shadow[i] = a[i] + shadow[i] * (1 - a[i]) }
        }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(pxW * pxH) {
            bytes[i * 4] = 0; bytes[i * 4 + 1] = 0; bytes[i * 4 + 2] = 0
            bytes[i * 4 + 3] = UInt8(max(0, min(255, (shadow[i] * 255).rounded())))
        }

        // the fill, the border
        ctx.setFillColor(srgb(d.fill))
        for path in geometry.fillPaths { ctx.addPath(path); ctx.fillPath() }
        if let border = d.border {
            // 15: a 1 pt border inside the box's edge; the connector's fill then covers it where they join, and its outer sides carry it on
            strokeStyle(ctx, srgb(border), width: 1); ctx.setLineJoin(.miter)
            ctx.addPath(roundedRect(geometry.box.insetBy(dx: 0.5, dy: 0.5), radius: m.radius - 0.5)); ctx.strokePath()
            if let tail = geometry.fillPaths.dropFirst().first { ctx.setFillColor(srgb(d.fill)); ctx.addPath(tail); ctx.fillPath() }
            if let outline = geometry.tailOutline { strokeStyle(ctx, srgb(border), width: 1); ctx.setLineJoin(.miter); ctx.addPath(outline); ctx.strokePath() }
        }
        if let rim = d.rim {
            // 14 in Dark Mode: an inner rim of white at 13%, 0.5 pt wide, round the box; the tail covers it where they join
            // clipped to the box, so that the stroke's anti-aliasing never paints a hair outside the shape's own outline
            ctx.saveGState()
            ctx.addPath(roundedRect(geometry.box, radius: m.radius)); ctx.clip()
            strokeStyle(ctx, srgb(rim.colour, alpha: rim.alpha), width: 0.5)
            ctx.addPath(roundedRect(geometry.box.insetBy(dx: 0.25, dy: 0.25), radius: m.radius - 0.25)); ctx.strokePath()
            ctx.restoreGState()
            ctx.setFillColor(srgb(d.fill))
            for path in geometry.fillPaths.dropFirst() { ctx.addPath(path); ctx.fillPath() }
        }

        drawContent(ctx, design: d, layout: p.layout, runs: runs, dots: dots, box: geometry.box, variant: variant)

        // the fade scales every channel of every pixel, the shadow included
        var pixels = Array(UnsafeBufferPointer(start: bytes, count: pxW * pxH * 4))
        if fadeLevel < 4 {
            let opacity = Double(max(0, fadeLevel)) / 4
            for i in 0..<pixels.count { pixels[i] = UInt8((Double(pixels[i]) * opacity).rounded()) }
        }
        let tip = (x: Int(geometry.tip.x.rounded()), y: Int(geometry.tip.y.rounded()))
        return BubbleBitmap(raster: Raster(width: pxW, height: pxH, data: pixels), box: (Int(geometry.box.minX), Int(geometry.box.minY), p.layout.boxWidth, m.boxHeight), tip: tip,
                            connection: connection, opening: opening, tipX: Double(Int(geometry.box.minX) + Int(p.tipX)), pixelsPerUnit: p.configuration.scale)
    }
}
