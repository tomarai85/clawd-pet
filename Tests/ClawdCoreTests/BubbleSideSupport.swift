import Testing
import Foundation
import CoreGraphics
import ClawdCore
@testable import ClawdRendering

/// Shared pieces of the bubble-side tests (amendment D-6): a made-up Clawd for placement tests that need exact numbers, request builders for the real
/// renderer, and the pixel facts of a placed bubble.

/// A torso 16 x 12 cells (32 x 24 pt at size 1) with its head top at (`headX`, `headY`), optional prop pixels, an optional open menu, and the visible
/// frame. The feet anchor F is the torso's bottom unless a test names another.
struct SideFixture {
    var headX: Double, headY: Double
    var display = Screens.display
    var visible = Screens.visible
    var props: [CGRect] = []
    var menu: CGRect?
    var feet: CGPoint?
    var bodyWindow: CGRect?

    var feetBottom: CGPoint { feet ?? CGPoint(x: headX, y: headY - 24) }
    var torso: CGRect { CGRect(x: headX - 16, y: headY - 24, width: 32, height: 24) }

    func mask() -> ClawdMask {
        let cell = 2.0, cols = 220, rows = 220
        var raster = Raster(width: cols, height: rows)
        let topLeft = CGPoint(x: headX - Double(cols) * cell / 2, y: headY + 110)
        func fill(_ rect: CGRect) {
            // the cells whose centre lies in the rectangle
            let x0 = max(0, Int(((rect.minX - topLeft.x) / cell - 0.5).rounded(.up))), x1 = min(cols - 1, Int(((rect.maxX - topLeft.x) / cell - 0.5).rounded(.down)))
            let y0 = max(0, Int(((topLeft.y - rect.maxY) / cell - 0.5).rounded(.up))), y1 = min(rows - 1, Int(((topLeft.y - rect.minY) / cell - 0.5).rounded(.down)))
            guard x0 <= x1, y0 <= y1 else { return }
            for y in y0...y1 { for x in x0...x1 { raster[x, y] = Pixel(1, 2, 3) } }
        }
        fill(torso)
        for prop in props { fill(prop) }
        return ClawdMask(raster: raster, topLeft: topLeft, cellPt: cell)
    }
    /// A frame just wider than the picture of `style` (by `extra` pt), Clawd near its left edge: neither opening fits and the picture slides in.
    static func narrow(style: Int, extra: Double = 10, headX: Double = 20) -> (SideFixture, Double) {
        let t = SideRun.text(style)
        let variant = BubbleLayout.variant(design: t.design, runs: t.runs, dots: t.dots, scale: 1)
        let e = t.design.pictureExtent(runs: t.runs, dots: t.dots, variant: variant, connection: .above)
        let width = Double(e.width) * (t.design.isSmooth ? 1 : BubbleChecks.pixelPt(t.design))
        var f = SideFixture(headX: headX, headY: 300)
        f.visible = CGRect(x: 0, y: 80, width: width + extra, height: 790); f.display = CGRect(x: 0, y: 0, width: width + extra, height: 900)
        return (f, width)
    }
    func site() -> BubbleSite {
        BubbleSite(headTop: CGPoint(x: headX, y: headY), bodyCentreY: headY - 12, unit: 4, display: display, visible: visible, clawd: mask(),
                   bodyWindow: bodyWindow, feetBottom: feetBottom, menu: menu)
    }
}

enum SideRun {
    static func text(_ style: Int, scene: Scene = .thinking, verb: String = "Cogitating") -> (design: BubbleDesign, runs: [BubbleRun], dots: BubbleDots?) {
        let design = BubbleDesign.resolved(style)
        let text = BubbleText.content(BubbleContent(scene: scene, elapsed: 0.7, duration: 5, verb: verb, pastVerb: "Cooked"), elements: stageRenderer.elements, design: design)
        return (design, text.runs, text.dots)
    }
    static func plan(_ style: Int, _ fixture: SideFixture, side: BubbleSide, scale: Double = 1, guards: StageGuards = .all, backing: Double = 1,
                     scene: Scene = .thinking, verb: String = "Cogitating") -> BubblePlan? {
        let t = text(style, scene: scene, verb: verb)
        return BubblePlacement.plan(design: t.design, runs: t.runs, dots: t.dots, site: fixture.site(), scale: scale, guards: guards, side: side, backing: backing)
    }
    static func decide(_ style: Int, _ fixture: SideFixture, side: BubbleSide, memory: BubbleMemory?, now: Double, scale: Double = 1,
                       scene: Scene = .thinking, verb: String = "Cogitating") -> BubbleDecision? {
        let t = text(style, scene: scene, verb: verb)
        return BubblePlacement.decide(design: t.design, runs: t.runs, dots: t.dots, site: fixture.site(), scale: scale, side: side, memory: memory, now: now,
                                      holdReturn: scene == .sent)
    }
}

/// A request on the real renderer: Clawd at rest on the 1440 x 900 fixture display, with a bubble of `style` in `scene`.
func sideRequest(style: Int = 1, scene: Scene = .thinking, side: BubbleSide? = nil, homeX: Double = 576, homeY: Double = 300, scale: Double = 1,
                 now: Double = 0, pixelScale: Double = 1, display: CGRect = Screens.display, visible: CGRect = Screens.visible, menu: CGRect? = nil,
                 memory: BubbleMemory? = nil, verb: String = "Cogitating", past: String = "Cooked", duration: Double = 5, frame base: SchedulerFrame? = nil,
                 elapsed: Double = 0.7, look: String = "plain") -> StageRequest {
    var frame = base ?? Frames.rest(look: look, bubble: BubbleState(style: style, scene: scene), scene: scene)
    if base != nil { frame.bubble = BubbleState(style: style, scene: scene) }
    let geometry = PetGeometry(scale: scale, homeOrigin: CGPoint(x: homeX, y: homeY), displayFrame: display, visibleFrame: visible)
    let content = BubbleContent(scene: scene, elapsed: elapsed, duration: duration, verb: verb, pastVerb: past)
    var request = StageRequest(frame: frame, now: now, geometry: geometry, pixelScale: pixelScale, content: content, menuRect: menu, bubbleMemory: memory)
    if let side { request.bubbleSide = side }
    return request
}

/// Every bubble pixel with any alpha, as the global rectangle of that pixel.
func paintedRects(_ bubble: PlacedBubble, backing: Double) -> [CGRect] {
    let design = BubbleDesign.resolved(bubble.style), raster = bubble.bitmap.raster
    let pt = design.isSmooth ? 1 / backing : BubbleChecks.pixelPt(design)
    var rects: [CGRect] = []
    for y in 0..<raster.height { for x in 0..<raster.width where raster.isOpaque(x, y) {
        rects.append(CGRect(x: bubble.rect.minX + Double(x) * pt, y: bubble.rect.maxY - Double(y + 1) * pt, width: pt, height: pt))
    } }
    return rects
}

/// What a scripted sequence of presented frames did: the placement of each frame and the change kind.
struct SideStep {
    var t: Double
    var plan: BubblePlan?
    var change: PlacementChangeKind?
}

/// The runtime's loop in miniature: each frame is a request, the memory of the last presented frame goes in, the proposed memory is committed after it.
struct SidePlayer {
    var memory: BubbleMemory?
    var steps: [SideStep] = []
    var layouts: [StageLayout?] = []
    mutating func present(_ request: StageRequest) throws -> StageLayout? {
        var r = request; r.bubbleMemory = memory
        let layout = try stageRenderer.layout(r)
        memory = layout?.memory
        steps.append(SideStep(t: request.now, plan: layout?.bubble?.plan, change: layout?.placementChange))
        layouts.append(layout)
        return layout
    }
    /// The frames at which the placement changed after the first one, with their kinds.
    var changes: [SideStep] { steps.dropFirst().filter { $0.change != nil } }
}
