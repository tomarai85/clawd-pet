import Testing
import Foundation
import CoreGraphics
import ClawdCore
@testable import ClawdRendering

/// Spec 4.4 and the user's later requirements (9b): the bubble is small (at most the body's 6 units tall, 200 x 48 pt), sits above the head
/// with its connector 1 unit over it, opens toward the middle of the display, goes beside the head only when there is no room above
/// (centred on the body's 6 rows), never enters the bottom 24 pt, never leaves the visible frame, never covers Clawd, and never moves him.
struct PlacementCase {
    let name: String
    let display: CGRect
    let visible: CGRect
    /// Clawd's canvas bottom-left at size 1; for other sizes the canvas keeps its anchoring edge.
    let x: Double, y: Double
    let anchor: Anchor
    enum Anchor { case left, right, top, bottom, free }

    func geometry(scale: Double) -> PetGeometry {
        let side = 48 * scale
        var x = self.x, y = self.y
        switch anchor {
        case .left: x = visible.minX
        case .right: x = visible.maxX - side
        case .top: y = visible.maxY - side
        case .bottom: y = visible.minY
        case .free: break
        }
        return PetGeometry(scale: scale, homeOrigin: CGPoint(x: x, y: y), displayFrame: display, visibleFrame: visible)
    }

    static let main = CGRect(x: 0, y: 0, width: 1440, height: 900), mainVisible = CGRect(x: 0, y: 80, width: 1440, height: 790)
    static let all: [PlacementCase] = [
        PlacementCase(name: "centre", display: main, visible: mainVisible, x: 640, y: 100, anchor: .free),
        PlacementCase(name: "left edge", display: main, visible: mainVisible, x: 0, y: 100, anchor: .left),
        PlacementCase(name: "right edge", display: main, visible: mainVisible, x: 0, y: 100, anchor: .right),
        PlacementCase(name: "near the top", display: main, visible: mainVisible, x: 300, y: 0, anchor: .top),
        PlacementCase(name: "very bottom", display: main, visible: mainVisible, x: 900, y: 0, anchor: .bottom),
        PlacementCase(name: "small display", display: CGRect(x: 0, y: 0, width: 300, height: 220), visible: CGRect(x: 0, y: 20, width: 300, height: 180),
                      x: 112, y: 40, anchor: .free),
        // 56 pt of visible height: Clawd flush with the bottom has no room above his head, and the body's centre (20 pt up) is inside the bottom band
        PlacementCase(name: "short display", display: CGRect(x: 0, y: 0, width: 800, height: 56), visible: CGRect(x: 0, y: 0, width: 800, height: 56),
                      x: 100, y: 0, anchor: .bottom),
        PlacementCase(name: "second display", display: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                      visible: CGRect(x: 1440, y: 0, width: 1920, height: 1050), x: 1440 + 1700, y: 60, anchor: .free),
    ]
    static let scales = [1.0, 1.5, 2.0, 3.0, 4.0]
    /// The small display only holds the smaller sizes (its whole visible frame is 300 x 180 pt).
    func scales() -> [Double] { name == "small display" ? [1.0, 1.5] : name == "short display" ? [1.0] : Self.scales }
}

private let verbs: [String] = stageRenderer.elements.present
private let pastVerbs: [String] = stageRenderer.elements.past
private let longestDuration = 3 * 3600 + 59 * 60 + 59.0

private func request(_ scene: Scene, style: Int, verb: String = "Clauding", past: String = "Cooked", duration: Double = 5, case c: PlacementCase,
                     scale: Double, frame pose: (name: String, now: Double) = ("idle", 0), pixelScale: Double = 1, withBubble: Bool = true,
                     side: BubbleSide = .above) -> StageRequest {
    var frame = Frames.pose(pose.name, scene: scene, bubble: withBubble ? BubbleState(style: style, scene: scene) : nil)
    if pose.name == "idle" { frame = Frames.rest(bubble: withBubble ? BubbleState(style: style, scene: scene) : nil, scene: scene) }
    return StageRequest(frame: frame, now: pose.now, geometry: c.geometry(scale: scale), pixelScale: pixelScale,
                        content: BubbleContent(scene: scene, elapsed: 0.25, duration: duration, verb: verb, pastVerb: past), bubbleSide: side)
}

/// Every rule, as a list of what was broken. Empty = the placement is right.
private func violations(_ layout: StageLayout, geometry: PetGeometry, c: PlacementCase, restPose: Bool) -> [String] {
    var broken: [String] = []
    guard let bubble = layout.bubble else { return ["no bubble was placed"] }
    let rect = bubble.rect, visible = geometry.visibleFrame, unit = geometry.unit, eps = 0.51 / layout.pixelScale
    let plan = bubble.plan, b = BubbleChecks.pixelPt(BubbleDesign.resolved(bubble.style))
    if rect.minX < visible.minX - eps || rect.maxX > visible.maxX + eps || rect.maxY > visible.maxY + eps || rect.minY < visible.minY - eps {
        broken.append("outside the visible frame: \(rect) in \(visible)")
    }
    // The picture (everything painted, a shadow included) is capped; the body-height rule measures the shape, the box and its connector.
    if rect.width > 200 + eps || rect.height > 48 + eps { broken.append("over the 200 x 48 pt cap: \(rect.size)") }
    if plan.shapeRect.height > 6 * unit + eps { broken.append("taller than the body's 6 units: \(plan.shapeRect.height) pt against \(6 * unit)") }
    if bubble.plan.boxRect.height > 6 * unit + eps { broken.append("box taller than the body's 6 units") }
    if rect.minY < visible.minY + 24 - eps { broken.append("inside the bottom 24 pt band: minY \(rect.minY - visible.minY)") }
    if layout.clawdMask.intersects(rect.insetBy(dx: 0.01, dy: 0.01)) { broken.append("covers Clawd's pixels") }
    // The box rectangle the host reports is where the bitmap's box really is (a trail that runs out to the side moves it).
    let box = bubble.bitmap.box
    if abs(plan.boxRect.minX - (rect.minX + Double(box.x) * b)) > eps || abs(plan.boxRect.width - Double(box.width) * b) > eps
        || abs(plan.boxRect.maxY - (rect.maxY - Double(box.y) * b)) > eps {
        broken.append("box rect \(plan.boxRect) is not where the picture's box is: x \(rect.minX + Double(box.x) * b), width \(Double(box.width) * b)")
    }
    switch plan.connection {
    case .above:
        // the edge of the tip that lies over H: a cell's near edge for the pixel styles, the point itself for 14 and 15
        let tipEdge = rect.minX + bubble.bitmap.tipX * b
        if abs(tipEdge - layout.headTop.x) > (c.name == "small display" ? b : eps) { broken.append("connector tip \(tipEdge) is not over H \(layout.headTop.x)") }
        if plan.shapeRect.minY < layout.headTop.y + unit - eps { broken.append("connector ends below 1 unit above H") }
        if plan.shapeRect.minY > layout.headTop.y + unit + eps, rect.minY > visible.minY + 24 + eps {
            broken.append("bubble floats \(plan.shapeRect.minY - layout.headTop.y - unit) pt higher than 1 unit above H")
        }
    case .below:
        // The edge of the tip that lies over F, 1 unit under the feet or more.
        let tipEdge = rect.minX + bubble.bitmap.tipX * b
        if let feet = layout.feetBottom {
            if abs(tipEdge - feet.x) > (c.name == "small display" ? b : eps), plan.form == .normal { broken.append("connector tip \(tipEdge) is not under F \(feet.x)") }
            if rect.maxY > feet.y - unit + eps { broken.append("the picture is closer than 1 unit under the feet: top \(rect.maxY), feet \(feet.y)") }
        } else { broken.append("no feet anchor") }
    case .side:
        let centreY = layout.canvas.maxY - Double(layout.composed.bodyCentreRow ?? 0) * layout.cellPt
        if restPose, abs(centreY - (layout.canvas.minY + 5 * unit)) > eps { broken.append("body centre is not 5 units above the baseline") }
        // the bottom band wins over the centre when it binds on the picture (a shadow row hangs below the box)
        if abs(plan.boxRect.midY - centreY) > eps, rect.minY > visible.minY + 24 + eps {
            broken.append("side bubble centre \(plan.boxRect.midY) is not the body's centre \(centreY)")
        }
        if bubble.plan.shapeRect.height > 6 * unit + eps { broken.append("side bubble too tall") }
        // The connector's tip is 1 unit from the nearest pixel of Clawd in the bubble's rows.
        if let extent = layout.clawdMask.horizontalExtent(from: rect.minY, to: rect.maxY) {
            let shape = plan.shapeRect
            // The styles that keep off the body window (13-15) stand 1 unit from Clawd's pixels, and their whole picture (a margin round the shape
            // included) touches the window's rectangle at the nearest: the bubble is pushed out only as far as the window needs.
            var wanted = plan.opening == .right ? extent.maxX + unit : extent.minX - unit
            if BubbleDesign.resolved(bubble.style).keepsOffTheBodyWindow, let hit = layout.hit.bounds {
                let backing = layout.pixelScale
                if plan.opening == .right { wanted = max(wanted, (hit.maxX * backing).rounded(.up) / backing + (shape.minX - rect.minX)) }
                else { wanted = min(wanted, (hit.minX * backing).rounded(.down) / backing - (rect.maxX - shape.maxX)) }
            }
            let edge = plan.opening == .right ? shape.minX : shape.maxX
            let gap = plan.opening == .right ? edge - extent.maxX : extent.minX - edge
            if abs(edge - wanted) > eps { broken.append("side bubble is \(gap) pt from Clawd, not 1 unit (\(unit) pt) or the body window's edge") }
        }
    }
    if c.name != "small display" {
        // Centered amendment D-4: the opening is no longer a corner choice. A normal above or below form hangs the box centered on H (the preferred
        // opening is tried first, the other when only that one fits, as style 11's lead makes the two pictures differ); the check that used to ask for
        // the opening toward the middle now asks for the centering.
        if plan.connection != .side, plan.form == .normal, let bubble = layout.bubble {
            let pixel = BubbleDesign.resolved(bubble.style).pixelPt
            if abs(plan.boxRect.midX - layout.headTop.x) > pixel + eps { broken.append("the box is centered \(plan.boxRect.midX - layout.headTop.x) pt off H") }
        }
    }
    if !layout.panel.insetBy(dx: -eps, dy: -eps).contains(rect) { broken.append("the panel does not hold the bubble") }
    if layout.panel.minX < visible.minX - eps || layout.panel.maxX > visible.maxX + eps || layout.panel.minY < visible.minY - eps || layout.panel.maxY > visible.maxY + eps {
        broken.append("the panel leaves the visible frame")
    }
    return broken
}

private func expectedCanvas(_ geometry: PetGeometry) -> CGRect {
    CGRect(x: geometry.homeOrigin.x, y: geometry.homeOrigin.y, width: 48 * geometry.scale, height: 48 * geometry.scale)
}

@Suite("BubblePlacementTests", .serialized)
struct BubblePlacementTests {
    private func layout(_ r: StageRequest, renderer: StageRenderer = stageRenderer) throws -> StageLayout { try #require(try renderer.layout(r)) }

    @Test func BubblePlacement_everyVerbOfClaudeCodeFitsEveryRule() throws {
        #expect(verbs.count == 188)
        var checked = 0
        // every case at size 1, and the three cases that matter for size (middle, flush against the top, a second display) at every size
        for c in PlacementCase.all { for scale in c.scales() where scale == 1 || ["centre", "near the top", "second display"].contains(c.name) {
            let g = c.geometry(scale: scale)
            for style in BubbleDesign.allIds { for verb in verbs {
                let r = request(.thinking, style: style, verb: verb, case: c, scale: scale)
                let broken = violations(try layout(r), geometry: g, c: c, restPose: true)
                if !broken.isEmpty { Issue.record("\(c.name) size \(scale) style \(style) \(verb): \(broken)"); return }
                checked += 1
            } }
        } }
        #expect(checked == (8 + 3 * 4) * BubbleDesign.allIds.count * 188)
    }

    @Test func BubblePlacement_everySceneAtEverySizeInEveryCase() throws {
        var checked = 0
        let frames: [(name: String, now: Double)] = [("idle", 0), ("hop", 0.1), ("hop", 0.28), ("dangle", 0.1), ("think", 0.2)]
        let longestVerb = try #require(verbs.max { $0.count < $1.count })
        let longestPast = try #require(pastVerbs.max { $0.count < $1.count })
        for c in PlacementCase.all { for scale in c.scales() {
            let g = c.geometry(scale: scale)
            for style in BubbleDesign.allIds { for scene in BubbleContent.shownScenes { for pose in frames {
                let r = request(scene, style: style, verb: longestVerb, past: longestPast, duration: longestDuration, case: c, scale: scale, frame: pose)
                let broken = violations(try layout(r), geometry: g, c: c, restPose: pose.name == "idle")
                if !broken.isEmpty { Issue.record("size \(scale) \(c.name) style \(style) \(scene) \(pose.name)@\(pose.now): \(broken)"); return }
                checked += 1
            } } }
        } }
        #expect(checked == PlacementCase.all.reduce(0) { $0 + $1.scales().count } * BubbleDesign.allIds.count * 5 * 5)
    }

    @Test func BubblePlacement_theLongestSentLineStaysInsideTheCap() throws {
        for design in BubbleDesign.all {
            let broken = BubbleChecks.capViolations(design)
            #expect(broken.isEmpty, "\(broken.prefix(3))")
        }
        for design in BubbleDesign.all {
            for past in pastVerbs {
                let content = BubbleContent(scene: .sent, duration: longestDuration, pastVerb: past)
                let text = BubbleText.content(content, elements: stageRenderer.elements, design: design)
                for connection in [BubbleConnection.above, .side] {
                    let e = design.pictureExtent(runs: text.runs, dots: text.dots, variant: .roomy, connection: connection)
                    #expect(Double(e.width) * BubbleChecks.pixelPt(design) <= 200, "style \(design.id) \(past) \(connection): \(e)")
                }
            }
        }
        for design in BubbleDesign.all { for verb in verbs {
            let text = BubbleText.content(BubbleContent(scene: .thinking, verb: verb), elements: stageRenderer.elements, design: design)
            let fitted = BubbleText.fitted(text.runs, dots: text.dots, design: design)
            #expect(fitted == text.runs, "style \(design.id): \(verb) needed shortening")
            #expect(design.pictureExtent(runs: text.runs, dots: text.dots, variant: .roomy, connection: .side).width <= Int(200 / BubbleChecks.pixelPt(design)), "\(verb)")
        } }
    }

    @Test func BubblePlacement_theBubbleIsNeverTallerThanTheBodyAtAnySize() throws {
        for scale in PlacementCase.scales {
            let unit = 4 * scale
            for design in BubbleDesign.all {
                let runs = BubbleText.content(BubbleContent(scene: .thinking), elements: stageRenderer.elements, design: design)
                let variant = BubbleLayout.variant(design: design, runs: runs.runs, dots: runs.dots, scale: scale)
                let h = Double(design.extent(runs: runs.runs, dots: runs.dots, variant: variant, connection: .above).height) * BubbleChecks.pixelPt(design)
                #expect(h <= 6 * unit, "style \(design.id) size \(scale): \(h) pt against the body's \(6 * unit) pt")
                #expect(h <= 48)
                #expect(h / (6 * unit) <= 1.0)
            }
        }
        // At size 1 a bubble is clearly smaller than v1's 30 pt box beside a 48 pt body: at most 24 pt (6 units).
        for design in BubbleDesign.all {
            let t = BubbleText.content(BubbleContent(scene: .thinking), elements: stageRenderer.elements, design: design)
            #expect(Double(design.extent(runs: t.runs, dots: t.dots, variant: .snug, connection: .above).height) * BubbleChecks.pixelPt(design) <= 24)
        }
    }

    @Test func BubblePlacement_besideTheHeadTheBubbleIsCentredOnTheBodysSixRows() throws {
        let c = PlacementCase.all[3]            // near the top: Clawd flush against the top edge, in the left half: the bubble beside him opens right
        var sides = 0
        for scale in PlacementCase.scales { for style in BubbleDesign.allIds { for scene in BubbleContent.shownScenes {
            let g = c.geometry(scale: scale)
            let l = try layout(request(scene, style: style, case: c, scale: scale, side: .right))
            let plan = try #require(l.bubble).plan
            #expect(plan.connection == .side && plan.side == .right && plan.opening == .right, "size \(scale) style \(style) \(scene): \(plan.connection)")
            guard plan.connection == .side else { continue }
            let bodyCentre = g.homeOrigin.y + 5 * g.unit            // rest pose: the torso spans units 4..10 from the top, so its centre is 5 units up
            #expect(abs(plan.boxRect.midY - bodyCentre) <= 0.51, "size \(scale) style \(style): box centre \(plan.boxRect.midY), body centre \(bodyCentre)")
            sides += 1
        } } }
        #expect(sides == PlacementCase.scales.count * BubbleDesign.allIds.count * BubbleContent.shownScenes.count)
    }

    @Test func BubblePlacement_theEdgeRulesFlipSlideAndDropBeside() throws {
        func plan(_ c: PlacementCase, scale: Double = 1, style: Int = 1) throws -> BubblePlan {
            try #require(try layout(request(.thinking, style: style, verb: "Flibbertigibbeting", case: c, scale: scale)).bubble).plan
        }
        // In the left half the bubble opens to the right, in the right half to the left.
        #expect(try plan(PlacementCase.all[1]).opening == .right && PlacementCase.all[1].geometry(scale: 1).homeOrigin.x == 0)
        #expect(try plan(PlacementCase.all[2]).opening == .left)
        #expect(try plan(PlacementCase.all[0]).opening == .right)
        // A display too narrow for the preferred side: flipped, or slid with the connector still over H.
        let small = PlacementCase.all[5]
        let p = try plan(small)
        #expect(p.connection == .above)
        #expect(p.rect.minX >= small.visible.minX && p.rect.maxX <= small.visible.maxX)
        // No room above: the next side of the order (below his feet, 1 unit under them), not beside him.
        let top = PlacementCase.all[3]
        let topLayout = try layout(request(.thinking, style: 1, verb: "Flibbertigibbeting", case: top, scale: 1))
        let s = try #require(topLayout.bubble).plan
        #expect(s.connection == .below && s.side == .below)
        #expect(s.rect.maxY <= (try #require(topLayout.feetBottom)).y - 4 + 0.01, "under Clawd's feet, 1 unit or more")
        // The bottom band holds even with Clawd at the very bottom: the bubble is above his head, far over the band.
        let bottom = PlacementCase.all[4]
        let b = try plan(bottom)
        #expect(b.connection == .above && b.rect.minY >= bottom.visible.minY + 24)
        // Clawd is in the left half of the display, but the visible frame ends 100 pt to his right (a Dock on the right). At 4606804 the corner-tip
        // picture ran 100 pt to the right of him and flipped to the other opening; the centered one hangs 53 pt each side and stays in the frame as it is.
        let flip = PlacementCase(name: "flip", display: PlacementCase.main, visible: CGRect(x: 0, y: 80, width: 400, height: 790), x: 288, y: 100, anchor: .free)
        let flipped = try plan(flip)
        #expect(flipped.connection == .above && flipped.form == .normal && !flipped.connectorHidden)
        #expect(abs(flipped.boxRect.midX - (288 + 24)) <= 2, "centered on H, no flip needed: the box centre is \(flipped.boxRect.midX)")
        #expect(flipped.rect.maxX <= flip.visible.maxX && flipped.rect.minX >= flip.visible.minX)
        // A slide: neither side fits; the bubble is moved in and its connector is still over H.
        let l = try layout(request(.thinking, style: 1, verb: "Flibbertigibbeting", case: small, scale: 1))
        let slid = try #require(l.bubble)
        #expect(slid.plan.rect.minX >= small.visible.minX && slid.plan.rect.maxX <= small.visible.maxX)
        let tipEdge = slid.plan.opening == .right ? slid.rect.minX + Double(slid.bitmap.tip.x) * 2 : slid.rect.minX + Double(slid.bitmap.tip.x + 1) * 2
        #expect(abs(tipEdge - l.headTop.x) <= 2, "the connector stays over H after the slide: tip \(tipEdge), H \(l.headTop.x)")
    }

    @Test func BubblePlacement_clawdNeverMovesWithOrWithoutTheBubbleOrTheStage() throws {
        var checked = 0
        for c in PlacementCase.all { for scale in [1.0, 2.0, 4.0] where c.scales().contains(scale) {
            let g = c.geometry(scale: scale)
            for style in BubbleDesign.allIds { for scene in BubbleContent.shownScenes {
                let with = try layout(request(scene, style: style, case: c, scale: scale))
                let without = try layout(request(scene, style: style, case: c, scale: scale, withBubble: false))
                #expect(with.canvas == without.canvas, "\(c.name) size \(scale) style \(style): the bubble moved Clawd")
                #expect(with.canvas == expectedCanvas(g), "\(c.name) size \(scale): Clawd is not at home")
                checked += 1
            } }
        } }
        #expect(checked == PlacementCase.all.reduce(0) { $0 + [1.0, 2.0, 4.0].filter($1.scales().contains).count } * BubbleDesign.allIds.count * 5)
        // v1's right-edge shift: a prop motion at the right edge and one at the left edge, the top and the bottom.
        for id in ["A20-laptop", "A7-swaying", "A12-heart", "A29-fishing", "A10-breakdancing", "A13-rainbow"] {
            for c in PlacementCase.all {
                let g = c.geometry(scale: 1)
                let l = try layout(StageRequest(frame: Frames.motion(id), now: 1.0, geometry: g))
                #expect(l.canvas == expectedCanvas(g), "\(id) at \(c.name): the stage moved Clawd")
            }
        }
    }

    @Test func BubblePlacement_pixelRulesOnTheFinishedPicture() throws {
        // The bubble's own pixels are what changes when it is added, so the finished picture is compared with and without it.
        var checked = 0
        let cases = [PlacementCase.all[0], PlacementCase.all[2], PlacementCase.all[3], PlacementCase.all[4], PlacementCase.all[6], PlacementCase.all[7]]
        for c in cases { for scale in [1.0, 2.0] { for pixelScale in [1.0, 2.0] { for style in BubbleDesign.allIds { for scene in [Scene.listening, .thinking, .error] {
            let g = c.geometry(scale: scale)
            let with = try #require(try stageRenderer.compose(request(scene, style: style, verb: "Cogitating", case: c, scale: scale, pixelScale: pixelScale)))
            let without = try #require(try stageRenderer.compose(request(scene, style: style, case: c, scale: scale, pixelScale: pixelScale, withBubble: false)))
            let label = "\(c.name) size \(scale)@\(pixelScale)x style \(style) \(scene)"
            // The same window origin lets the two pictures be compared pixel for pixel: pad the smaller to the larger.
            let panel = with.panelFrame.union(without.panelFrame)
            func place(_ f: StageFrame) -> Raster {
                var r = Raster(width: Int((panel.width * pixelScale).rounded()), height: Int((panel.height * pixelScale).rounded()))
                r.blit(f.pixels, x: Int(((f.panelFrame.minX - panel.minX) * pixelScale).rounded()), y: Int(((panel.maxY - f.panelFrame.maxY) * pixelScale).rounded()))
                return r
            }
            let a = place(with), b = place(without)
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
            // the same bounds with the drop shadow's pixels left out: the shape alone, which the body-height and centre rules measure
            var shapeMinY = Int.max, shapeMaxY = -1
            let drawn = BubbleDesign.resolved(style), shadow = drawn.dropShadow
            // a smooth style's shadow is black and translucent: premultiplied, every colour channel 0; its shape has some colour in every pixel
            func isShadow(_ p: Pixel) -> Bool { drawn.isSmooth ? (p.r == 0 && p.g == 0 && p.b == 0) : p == shadow }
            for y in 0..<a.height { for x in 0..<a.width where a[x, y] != b[x, y] {
                if b.isOpaque(x, y) { Issue.record("\(label): a bubble pixel covers Clawd at (\(x),\(y))"); return }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if !isShadow(a[x, y]) { shapeMinY = min(shapeMinY, y); shapeMaxY = max(shapeMaxY, y) }
            } }
            #expect(maxX >= 0, "\(label): the bubble drew nothing")
            // global bounds of the painted bubble
            let paintedBottom = panel.maxY - Double(maxY + 1) / pixelScale, paintedTop = panel.maxY - Double(minY) / pixelScale
            let shapeBottom = panel.maxY - Double(shapeMaxY + 1) / pixelScale, shapeTop = panel.maxY - Double(shapeMinY) / pixelScale
            let paintedLeft = panel.minX + Double(minX) / pixelScale, paintedRight = panel.minX + Double(maxX + 1) / pixelScale
            #expect(paintedBottom >= g.visibleFrame.minY + 24 - 0.01, "\(label): pixels in the bottom 24 pt band")
            #expect(shapeTop - shapeBottom <= min(6 * g.unit, 48) + 0.01, "\(label): the shape's painted height \(shapeTop - shapeBottom)")
            #expect(paintedTop - paintedBottom <= 48 + 0.01, "\(label): painted height \(paintedTop - paintedBottom)")
            #expect(paintedRight - paintedLeft <= 200 + 0.01, "\(label): painted width")
            #expect(paintedLeft >= g.visibleFrame.minX - 0.01 && paintedRight <= g.visibleFrame.maxX + 0.01 && paintedTop <= g.visibleFrame.maxY + 0.01, "\(label): outside the visible frame")
            // beside the head the box is centred on the body, unless the centre would put it in the bottom band (the band wins)
            if let plan = with.bubble?.plan, plan.connection == .side, plan.rect.minY > g.visibleFrame.minY + 24 + 0.51 {
                let bodyCentre = g.homeOrigin.y + 5 * g.unit
                #expect(abs((shapeTop + shapeBottom) / 2 - bodyCentre) <= 1.01 / pixelScale + 0.51, "\(label): painted centre \((shapeTop + shapeBottom) / 2), body \(bodyCentre)")
            }
            checked += 1
        } } } } }
        #expect(checked == cases.count * 2 * 2 * BubbleDesign.allIds.count * 3)
    }

    @Test func BubblePlacement_everyPaintedPixelIsCrispAndInThePalette() throws {
        for design in BubbleDesign.pixelDesigns {
            let broken = BubbleChecks.paletteViolations(design)
            #expect(broken.isEmpty, "\(broken.prefix(3))")
        }
    }

    @Test func BubblePlacement_everyTextRoleHasAtLeastFourPointFiveToOneContrast() throws {
        #expect(BubbleDesign.all.count == BubbleDesign.allIds.count)
        for design in BubbleDesign.all {
            let broken = BubbleChecks.contrastViolations(design)
            #expect(broken.isEmpty, "\(broken)")
            let pulse = design.isSmooth ? [] : BubbleChecks.pulseViolations(design)
            #expect(pulse.isEmpty, "\(pulse)")
            for role in design.roles { #expect(Pixel.contrast(design.color(role), design.fill) >= 4.5, "style \(design.id) \(role): \(Pixel.contrast(design.color(role), design.fill))") }
            #expect(design.contrast >= 4.5)
        }
        // The example of the spec: style 1's ink on its blue is about 6.2.
        let one = try #require(BubbleDesign.design(1))
        #expect(abs(Pixel.contrast(one.ink, one.fill) - 6.2) < 0.1)
        #expect(one.fill == Pixel(105, 154, 203), "the source value of Clawd-Thinking's light_blue, not the board's screenshot reading")
        // Style 3 has no box: its text is measured against its outline; style 12's glyph against its own segment.
        let three = try #require(BubbleDesign.design(3)), twelve = try #require(BubbleDesign.design(12))
        #expect(three.textPairs.allSatisfy { $0.background == three.fill } && three.fill == BubbleDesign.white)
        #expect(twelve.textPairs.contains { $0.name == "segment" && $0.background == twelve.segment!.fill })
    }

    // MARK: a frame too small for the bubble (spec 9b item 11a)

    /// A frame about as wide as Clawd and a bubble side by side, with Clawd flush against its top (no room above his head) and anywhere along it.
    private func narrowFrameCase(width: Double, scale: Double, fraction: Double) -> PlacementCase {
        let display = CGRect(x: 0, y: 0, width: width, height: 400)
        return PlacementCase(name: "narrow \(Int(width)) pt, size \(scale), at \(fraction)", display: display, visible: display,
                             x: fraction * (width - 48 * scale), y: 0, anchor: .top)
    }
    private static let narrowWidths = [330.0, 380.0, 420.0]
    private static let narrowSizes = [1.0, 2.0, 3.0, 4.0]
    private static let narrowFractions = [0.0, 0.25, 0.5, 0.75, 1.0]

    @Test func BubblePlacement_aFrameTooNarrowForTheBubbleNeverPutsAnyOfItOnClawd() throws {
        let off = try StageRenderer(art: artDirectory); off.guards.remove(.clearOfClawd)
        let longest = try #require(verbs.max { $0.count < $1.count }), shortest = try #require(verbs.min { $0.count < $1.count })
        let longestPast = try #require(pastVerbs.max { $0.count < $1.count })
        var checked = 0, coveringWithoutTheRule = 0, connectorLeftOut = 0, noBubble = 0
        for width in Self.narrowWidths { for scale in Self.narrowSizes { for fraction in Self.narrowFractions {
            let c = narrowFrameCase(width: width, scale: scale, fraction: fraction)
            for style in BubbleDesign.allIds { for (scene, verb) in [(Scene.thinking, longest), (.thinking, shortest), (.sent, longest)] {
                let r = request(scene, style: style, verb: verb, past: longestPast, duration: longestDuration, case: c, scale: scale, side: .right)
                let l = try layout(r)
                if let bubble = l.bubble {
                    let rect = bubble.rect
                    if l.clawdMask.intersects(rect.insetBy(dx: 0.01, dy: 0.01)) { Issue.record("\(c.name) style \(style) \(scene) \(verb): the bubble \(rect) covers Clawd's pixels"); return }
                    if !c.visible.insetBy(dx: -0.51, dy: -0.51).contains(rect) || rect.minY < c.visible.minY + 24 - 0.51 {
                        Issue.record("\(c.name) style \(style) \(scene): the bubble \(rect) leaves the visible frame or enters the bottom band"); return
                    }
                    if bubble.plan.connectorHidden {
                        connectorLeftOut += 1
                        if abs(bubble.plan.shapeRect.width - bubble.plan.boxRect.width) > 0.51 && bubble.plan.connection == .side {
                            Issue.record("\(c.name) style \(style): the connector is left out but the picture is wider than its box"); return
                        }
                    }
                } else { noBubble += 1 }
                if let uncorrected = try off.layout(r)?.bubble, l.clawdMask.intersects(uncorrected.rect.insetBy(dx: 0.01, dy: 0.01)) { coveringWithoutTheRule += 1 }
                checked += 1
            } }
        } } }
        emit("BubblePlacement narrow frames: \(checked) layouts; with the rule off \(coveringWithoutTheRule) put the bubble on Clawd; with it on, \(connectorLeftOut) leave the connector out and \(noBubble) draw no bubble")
        #expect(checked == Self.narrowWidths.count * Self.narrowSizes.count * Self.narrowFractions.count * BubbleDesign.allIds.count * 3)
        #expect(coveringWithoutTheRule > 0, "the sweep never reached the case: the rule is not load-bearing here")
    }

    private func covers(_ layout: StageLayout) throws -> Bool {
        let bubble = try #require(layout.bubble, "no bubble was placed")
        return layout.clawdMask.intersects(bubble.rect.insetBy(dx: 0.01, dy: 0.01))
    }

    @Test func BubblePlacement_whenOnlyTheConnectorWouldCoverClawdItIsLeftOutAndTheBoxStaysAboveHim() throws {
        // 380 pt wide, size 2, Clawd in the middle flush against the top. The chosen side is above: the box fits between his head and the top, the box with
        // its connector does not. The chosen side's connector-less form comes before any other side (side outranks connector), so the box stays above him.
        let off = try StageRenderer(art: artDirectory); off.guards.remove(.clearOfClawd)
        let c = narrowFrameCase(width: 380, scale: 2, fraction: 0.5)
        let longest = try #require(verbs.max { $0.count < $1.count }), shortest = try #require(verbs.min { $0.count < $1.count })
        var hidden = 0
        for style in [1, 4, 6, 7, 11] { for verb in [longest, shortest] {
            let r = request(.thinking, style: style, verb: verb, case: c, scale: 2)
            let l = try layout(r)
            guard let bubble = l.bubble, bubble.plan.connectorHidden else { continue }
            hidden += 1
            #expect(bubble.plan.connection == .above, "style \(style) \(verb): the box goes above his head")
            #expect(abs(bubble.plan.rect.height - bubble.plan.boxRect.height) < 0.51 && abs(bubble.plan.rect.width - bubble.plan.boxRect.width) < 0.51,
                    "style \(style) \(verb): the picture is the box alone")
            #expect(bubble.plan.rect.minY >= l.headTop.y + 4 * 2 - 0.51, "style \(style) \(verb): clear of his head (one unit above it)")
            #expect(!l.clawdMask.intersects(bubble.rect.insetBy(dx: 0.01, dy: 0.01)), "style \(style) \(verb): clear of his pixels")
        } }
        #expect(hidden > 0, "no style at this place leaves its connector out: the case is gone")
        // Without the connector-less forms the same places are not above him: the order falls to the next side.
        let sidesOnly = request(.thinking, style: 1, verb: longest, case: c, scale: 2, side: .right)
        #expect(try layout(sidesOnly).bubble != nil)
    }

    @Test func BubblePlacement_whenEvenTheBoxWouldCoverClawdThereIsNoBubbleRatherThanOneOnHim() throws {
        // 380 pt wide and 130 pt high, size 2, Clawd in the middle flush against the top, the chosen side right: style 5's longest line is wider than the
        // room beside him, there is none above, and the room under his feet is shorter than the bubble plus the bottom band.
        let off = try StageRenderer(art: artDirectory); off.guards.remove(.clearOfClawd)
        let display = CGRect(x: 0, y: 0, width: 380, height: 130)
        let c = PlacementCase(name: "narrow and short", display: display, visible: display, x: 0.5 * (380 - 96), y: 0, anchor: .top)
        let r = request(.thinking, style: 5, verb: try #require(verbs.max { $0.count < $1.count }), case: c, scale: 2, side: .right)
        #expect(try layout(r).bubble == nil, "no bubble: no placement is clear of Clawd")
        #expect(try covers(try #require(try off.layout(r))), "without the rule it is drawn on him")
        // the same line with room beside him is drawn as always
        let roomy = PlacementCase(name: "roomy", display: CGRect(x: 0, y: 0, width: 900, height: 400), visible: CGRect(x: 0, y: 0, width: 900, height: 400), x: 100, y: 0, anchor: .top)
        #expect(try layout(request(.thinking, style: 5, verb: try #require(verbs.max { $0.count < $1.count }), case: roomy, scale: 2)).bubble != nil)
    }

    // MARK: negative controls: each rule, switched off, makes its check fail

    @Test func BubblePlacement_negativeControl_theHeightCapMakesTheBubbleSmallerThanTheBody() throws {
        let off = try StageRenderer(art: artDirectory); off.guards.remove(.heightCap)
        var worst = 0.0
        for design in BubbleDesign.ids {
            let l = try #require(try off.layout(request(.thinking, style: design, case: PlacementCase.all[0], scale: 1)))
            worst = max(worst, try #require(l.bubble).rect.height)
        }
        negativeControl("heightCap", expectationHolds: worst <= 6 * 4)
        emit("NEGATIVE-CONTROL-DETAIL: heightCap off -> tallest bubble \(worst) pt against 24 pt")
    }

    @Test func BubblePlacement_negativeControl_theCentreRuleAlignsASideBubbleWithTheBody() throws {
        let off = try StageRenderer(art: artDirectory); off.guards.remove(.sideCentre)
        let c = PlacementCase.all[3], g = c.geometry(scale: 1)
        let l = try #require(try off.layout(request(.thinking, style: 1, case: c, scale: 1, side: .right)))
        let plan = try #require(l.bubble).plan
        #expect(plan.connection == .side)
        let off1 = abs(plan.boxRect.midY - (g.homeOrigin.y + 5 * g.unit))
        negativeControl("sideCentre", expectationHolds: off1 <= 0.51)
        emit("NEGATIVE-CONTROL-DETAIL: sideCentre off -> box centre is \(off1) pt from the body's centre")
    }

    @Test func BubblePlacement_negativeControl_theCollisionCheckKeepsTheLastFallbackOffClawd() throws {
        let off = try StageRenderer(art: artDirectory); off.guards.remove(.clearOfClawd)
        let c = narrowFrameCase(width: 380, scale: 2, fraction: 0.5)
        let longest = try #require(verbs.max { $0.count < $1.count })
        var covered = 0, styles = 0
        for style in BubbleDesign.allIds {
            styles += 1
            if try covers(try #require(try off.layout(request(.thinking, style: style, verb: longest, case: c, scale: 2, side: .right)))) { covered += 1 }
        }
        negativeControl("clearOfClawd", expectationHolds: covered == 0)
        emit("NEGATIVE-CONTROL-DETAIL: clearOfClawd off -> in a 380 pt frame the longest line lies on Clawd in \(covered) of \(styles) styles")
    }

    @Test func BubblePlacement_negativeControl_theFixedCanvasKeepsClawdWhereHeIs() throws {
        let off = try StageRenderer(art: artDirectory); off.guards.remove(.fixedClawd)
        let c = PlacementCase.all[2], g = c.geometry(scale: 1)
        let l = try #require(try off.layout(StageRequest(frame: Frames.motion("A20-laptop"), now: 1.0, geometry: g)))
        let moved = l.canvas.minX - g.homeOrigin.x
        negativeControl("fixedClawd", expectationHolds: l.canvas == expectedCanvas(g))
        emit("NEGATIVE-CONTROL-DETAIL: fixedClawd off -> Clawd is pushed \(moved) pt at the right edge (v1's shift)")
    }

    @Test func BubblePlacement_negativeControl_aTextColourUnderFourPointFiveBreaksTheContrastRule() throws {
        var worst = 99.0, mutants = 0
        var survivors: [String] = []
        for design in BubbleDesign.all {
            #expect(BubbleChecks.contrastViolations(design).isEmpty)
            // each role in turn, moved two thirds of the way into the colour it sits on
            for role in design.roles {
                var bad = design
                let faded = design.color(role).mixed(into: design.fill, third: 2)
                switch role { case .claude: bad.claude = faded; case .shimmer: bad.shimmer = faded; case .dim: bad.dim = faded; case .error: bad.error = faded; case .ink: bad.ink = faded }
                mutants += 1
                if BubbleChecks.contrastViolations(bad).isEmpty { survivors.append("style \(design.id) \(role)") }
                worst = min(worst, bad.contrast)
            }
            if let segment = design.segment {
                var bad = design; bad.segment = (fill: segment.fill, ink: segment.fill.mixed(into: segment.ink, third: 1))
                mutants += 1
                if BubbleChecks.contrastViolations(bad).isEmpty { survivors.append("style \(design.id) segment") }
            }
        }
        #expect(survivors.isEmpty, "negative control contrast did not fail for \(survivors): the rule is not load-bearing")
        if survivors.isEmpty { emit("NEGATIVE-CONTROL: contrast -> fails for all \(mutants) mutants") }
        emit("NEGATIVE-CONTROL-DETAIL: a role mixed two thirds into its fill -> the worst pair falls to \(String(format: "%.2f", worst)):1 against the 4.5:1 rule, for every role of all 12 styles and style 12's segment")
    }

    @Test func BubblePlacement_negativeControl_aWiderOrTallerBoxBreaksTheCap() throws {
        var widest = 0.0, tallest = 0.0, mutants = 0
        var survivors: [String] = []
        for design in BubbleDesign.pixelDesigns {
            #expect(BubbleChecks.capViolations(design).isEmpty)
            var wide = design; wide.padX += BubbleChecks.pixelPt(design) == 1 ? 60 : 10
            mutants += 1
            if BubbleChecks.capViolations(wide).isEmpty { survivors.append("width style \(design.id)") }
            let t = BubbleText.content(BubbleContent(scene: .thinking, verb: "Whatchamacalliting"), elements: BubbleChecks.elements, design: wide)
            widest = max(widest, Double(wide.extent(runs: t.runs, dots: t.dots, variant: .snug, connection: .side).width) * BubbleChecks.pixelPt(design))
            var tall = design; tall.padYSnug += 3
            mutants += 1
            if BubbleChecks.capViolations(tall).isEmpty { survivors.append("height style \(design.id)") }
            tallest = max(tallest, Double(tall.extent(runs: t.runs, dots: t.dots, variant: .snug, connection: .above).height) * BubbleChecks.pixelPt(design))
        }
        #expect(survivors.isEmpty, "negative control cap did not fail for \(survivors): the rule is not load-bearing")
        if survivors.isEmpty { emit("NEGATIVE-CONTROL: cap -> fails for all \(mutants) mutants") }
        emit("NEGATIVE-CONTROL-DETAIL: padX + 10 (+ 60 for the 1 pt style) -> up to \(widest) pt wide against the 200 pt cap; padY + 3 -> up to \(tallest) pt tall against the 24 pt of the body's 6 units")
    }

    @Test func BubblePlacement_negativeControl_noPaddingMakesTheTextTouchTheOutline() throws {
        var mutants = 0
        var survivors: [String] = []
        for design in BubbleDesign.pixelDesigns {
            #expect(BubbleChecks.clearanceViolations(design, verbs: ["Cogitating"]).isEmpty)
            // style 3 has no box to pad: its outline is what keeps the words clear
            var bad = design
            if design.form == .halo { bad.haloRadius = 0 } else { bad.padX = 0 }
            mutants += 1
            if BubbleChecks.clearanceViolations(bad, verbs: ["Cogitating"]).isEmpty { survivors.append("style \(design.id)") }
        }
        #expect(survivors.isEmpty, "negative control clearance did not fail for \(survivors): the rule is not load-bearing")
        if survivors.isEmpty { emit("NEGATIVE-CONTROL: clearance -> fails for all \(mutants) mutants (padX 0, or no outline for style 3: the text touches the outline, the ring, the other segment or the edge of the picture)") }
    }

    // MARK: the styles of the board's mock (13-15): the picture bounds, the shape and the shadow (D-5)

    private static var newStyles: [Int] { BubbleDesign.allIds.filter { $0 >= 13 } }

    /// Q1, ruled: at size 1 the snug form, its shape at most the body's 24 pt; from size 1.5 the mock's own dimensions, still inside the 48 pt cap.
    @Test func BubblePlacement_theNewStylesFitTheBodyAtSizeOneInTheirSnugForm() throws {
        var checked = 0
        let longest = try #require(verbs.max { $0.count < $1.count })
        for style in Self.newStyles { for c in [PlacementCase.all[0], PlacementCase.all[3]] { for verb in [longest, "Cooking"] {
            let plan = try #require(try layout(request(.thinking, style: style, verb: verb, case: c, scale: 1)).bubble).plan
            #expect(plan.variant == .snug, "style \(style) \(c.name) \(verb)")
            #expect(plan.shapeRect.height <= 24 + 0.51, "style \(style) \(c.name) \(verb): the shape is \(plan.shapeRect.height) pt tall")
            #expect(plan.rect.height <= 48 + 0.51)
            checked += 1
        } } }
        for style in Self.newStyles {
            let plan = try #require(try layout(request(.thinking, style: style, case: PlacementCase.all[0], scale: 1.5)).bubble).plan
            #expect(plan.variant == .roomy && plan.shapeRect.height <= 6 * 6 + 0.51, "style \(style) at size 1.5")
            #expect(plan.shapeRect.height > 24, "style \(style): the roomy form is taller than the snug 24 pt")
        }
        #expect(checked == Self.newStyles.count * 2 * 2)
    }

    /// What is painted under the shape (a soft shadow) is paint on the user's screen: the placement keeps it off Clawd and off a prop, not only the shape.
    @Test func BubblePlacement_aShadowNeverLiesOnClawdOrAProp() throws {
        for style in Self.newStyles {
            let design = BubbleDesign.resolved(style)
            let text = BubbleText.content(BubbleContent(scene: .thinking, elapsed: 0.7, verb: "Cogitating"), elements: stageRenderer.elements, design: design)
            let head = CGPoint(x: 300, y: 200)
            // One row of prop cells (2 pt cells) in the gap between 1 unit above H (204) and the shadow's lowest paint: only the shadow reaches it.
            var props = Raster(width: 30, height: 1)
            for x in 0..<30 { props[x, 0] = Pixel(1, 2, 3) }
            let mask = ClawdMask(raster: props, topLeft: CGPoint(x: head.x - 20, y: 204), cellPt: 2)
            let site = BubbleSite(headTop: head, bodyCentreY: 190, unit: 4, display: Screens.display, visible: Screens.visible, clawd: mask)
            let plan = try #require(BubblePlacement.plan(design: design, runs: text.runs, dots: text.dots, site: site, scale: 1, side: .above), "style \(style)")
            #expect(!mask.intersects(plan.rect), "style \(style): the picture \(plan.rect) lies on the prop")
            #expect(plan.shapeRect.minY >= 204 - 0.01, "style \(style): the shape was lifted clear of the prop with its shadow")
        }
    }

    /// Consumer 6 of the pixel size (D-3): the tests' own cap arithmetic counts each style's own pixels. A 23-row shape of style 13 is under the body's
    /// 24 pt at size 1 and a 25-row one is over; a rule that counted every row as 2 pt would turn them the other way round.
    @Test func BubblePlacement_negativeControl_theCapCountsEachStylesOwnPixels() throws {
        #expect(!BubbleChecks.exceedsTheBodyAtSizeOne(rows: 23, pixelPt: 1) && BubbleChecks.exceedsTheBodyAtSizeOne(rows: 25, pixelPt: 1))
        #expect(BubbleChecks.exceedsTheBodyAtSizeOne(rows: 23, pixelPt: 2) && !BubbleChecks.exceedsTheBodyAtSizeOne(rows: 12, pixelPt: 2))
        let thirteen = BubbleDesign.resolved(13)
        #expect(BubbleChecks.capViolations(thirteen).isEmpty, "the real style 13, a 23-row snug shape")
        var tall = thirteen; tall.padYSnug += 1          // two more rows: a 25-row snug shape
        negativeControl("capPixels", expectationHolds: BubbleChecks.capViolations(tall).isEmpty)
        emit("NEGATIVE-CONTROL-DETAIL: a 25-row style 13 at size 1 -> \(BubbleChecks.capViolations(tall).count) cap violations; the real 23-row one has none")
    }
}
