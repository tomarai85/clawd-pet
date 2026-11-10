import Testing
import Foundation
import CoreGraphics
import ClawdCore
@testable import ClawdRendering

/// Amendment D-6: scripted sequences of presented frames, each rendered through the offscreen renderer and asserted on the composed picture's pixels, not
/// on placement rectangles. Every frame: no bubble pixel on Clawd, a prop, or the open menu, outside the visible frame, or in the bottom 24 pt band;
/// on a frame whose actual side is below, nothing within 1 unit under F (F1) and, with nothing in the way, exactly 1 unit (F2); on a frame whose actual
/// side is above or beside, today's geometry (a correct fallback above must not fail a below-only assertion).
@Suite("BubbleSequenceTests", .serialized)
struct BubbleSequenceTests {
    private let dt = 1.0 / 30
    private let eps = 1e-6

    /// The invariants of one presented frame. Returns what was broken.
    private func broken(_ layout: StageLayout?, _ request: StageRequest, label: String, f2: Bool = false) -> [String] {
        guard let layout, let bubble = layout.bubble else { return [] }
        var out: [String] = []
        let visible = request.geometry.visibleFrame, band = visible.minY + BubbleLayout.bottomBandPt, unit = request.geometry.unit
        let backing = layout.pixelScale, mask = layout.clawdMask
        var covers = 0, outside = 0, inBand = 0, onMenu = 0
        for r in paintedRects(bubble, backing: backing) {
            if mask.intersects(r.insetBy(dx: 0.01, dy: 0.01)) { covers += 1 }
            if r.minX < visible.minX - eps || r.maxX > visible.maxX + eps || r.maxY > visible.maxY + eps || r.minY < visible.minY - eps { outside += 1 }
            if r.minY < band - eps { inBand += 1 }
            if let menu = request.menuRect, r.intersects(menu) { onMenu += 1 }
        }
        if covers > 0 { out.append("\(label): \(covers) bubble pixels lie on Clawd or a prop") }
        if outside > 0 { out.append("\(label): \(outside) bubble pixels lie outside the visible frame \(visible)") }
        if inBand > 0 { out.append("\(label): \(inBand) bubble pixels lie in the bottom band") }
        if onMenu > 0 { out.append("\(label): \(onMenu) bubble pixels lie on the menu") }
        let plan = bubble.plan
        switch plan.side {
        case .below:
            if let feet = layout.feetBottom {
                if bubble.rect.maxY > feet.y - unit + eps { out.append("\(label): F1, the picture's top \(bubble.rect.maxY) is within 1 unit of F \(feet.y)") }
                // F2: nothing in the way means exactly 1 unit (a picture lowered past a prop has more, so the sequences with props leave this out)
                if f2, abs(bubble.rect.maxY - (feet.y - unit)) > eps { out.append("\(label): F2, the picture's top is \(feet.y - bubble.rect.maxY) pt under F, not 1 unit (\(unit))") }
            }
        case .above:
            if plan.shapeRect.minY < layout.headTop.y + unit - eps { out.append("\(label): the connector ends below 1 unit above H") }
        case .left, .right:
            if let extent = mask.horizontalExtent(from: plan.rect.minY, to: plan.rect.maxY) {
                let gap = plan.opening == .right ? plan.shapeRect.minX - extent.maxX : extent.minX - plan.shapeRect.maxX
                if gap < unit - 0.51 / backing && !(BubbleDesign.resolved(bubble.style).keepsOffTheBodyWindow) { out.append("\(label): \(gap) pt from Clawd, less than 1 unit") }
            }
        }
        return out
    }

    private func returnsPerHalfSecond(_ steps: [SideStep]) -> Int {
        let returns = steps.filter { $0.change == .returned }.map(\.t)
        var most = 0
        for t in returns { most = max(most, returns.filter { $0 >= t && $0 < t + 0.5 - 1e-9 }.count) }
        return most
    }

    // MARK: (a)

    /// Hops, a drag down to the bottom band and up again, walks across the middle, and scene changes, with the motions that carry props around Clawd.
    @Test func BubbleSequence_hopDragAndSceneTransitionsWithASwingingProp() throws {
        let scenes: [Scene] = [.listening, .thinking, .sent, .interrupted, .error]
        var frames = 0, bubbles = 0, kinds = Set<String>()
        var problems: [String] = []
        for style in [1, 4, 13, 15] { for side in BubbleSide.allCases {
            var player = SidePlayer()
            for (m, motion) in ["A20-laptop", "A7-swaying", "A12-heart", "A29-fishing", "A10-breakdancing", "A3-jumping", "A13-rainbow"].enumerated() {
                for k in 0..<60 {
                    let t = Double(m * 60 + k) * dt
                    // a walk across the display middle, a hop-like rise, and a drag that dips into the bottom band
                    let homeX = 560 + 4 * Double(k) + 20 * Double(m)
                    let homeY = 150 + 90 * sin(Double(k) / 60 * 2 * Double.pi) - (m == 3 ? 100 : 0)
                    let scene = scenes[(k / 12) % scenes.count]
                    let base = k % 20 < 10 ? Frames.motion(motion, startedAt: 0, duration: 1000, loops: true) : Frames.pose(k % 20 < 15 ? "hop" : "dangle", scene: scene)
                    let request = sideRequest(style: style, scene: scene, side: side, homeX: homeX, homeY: max(Screens.visible.minY, homeY), now: t, frame: base,
                                              elapsed: scene == .sent ? 1.0 : 0.7)
                    var r = request; r.bubbleMemory = player.memory
                    let layout = try player.present(request)
                    problems += broken(layout, r, label: "style \(style) \(side) \(motion) k=\(k)")
                    frames += 1
                    if layout?.bubble != nil { bubbles += 1 }
                    if let c = layout?.placementChange { kinds.insert("\(c)") }
                }
            }
            #expect(returnsPerHalfSecond(player.steps) <= 1, "style \(style) \(side): more than one return per 0.5 s")
        } }
        #expect(problems.isEmpty, "\(problems.prefix(6))")
        #expect(frames == 4 * 4 * 7 * 60 && bubbles > frames / 2, "\(bubbles) of \(frames) frames drew a bubble")
        #expect(kinds.isSuperset(of: ["initial"]), "\(kinds)")
    }

    // MARK: (b)

    /// A visible frame whose edges are not on the device grid: the bubble's snapped picture still lies inside it.
    @Test func BubbleSequence_aVisibleFrameWithFractionalEdgesSnapsInside() throws {
        let visible = CGRect(x: 0.3, y: 80.3, width: 1439.4, height: 789.4), display = Screens.display
        var checked = 0, problems: [String] = []
        for style in [1, 13, 14, 15] { for side in BubbleSide.allCases { for (hx, hy) in [(0.3, 80.3), (1391.7, 80.3), (0.3, 821.7), (1391.7, 821.7), (700.1, 300.3), (0.9, 400.7), (1390.9, 450.2)] {
            let request = sideRequest(style: style, side: side, homeX: hx, homeY: hy, pixelScale: 2, display: display, visible: visible)
            let layout = try stageRenderer.layout(request)
            problems += broken(layout, request, label: "style \(style) \(side) at (\(hx), \(hy))", f2: true)
            checked += 1
        } } }
        #expect(problems.isEmpty, "\(problems.prefix(6))")
        #expect(checked == 4 * 4 * 7)
    }

    // MARK: (c)

    /// A Dock or work-area change under a still bubble (no new frame): the bubble is laid out again against the new frame, and again at the expiry of the
    /// return delay when the Dock goes.
    @Test func BubbleSequence_aDockOrWorkAreaChangeUnderAStaticBubble() throws {
        let noDock = CGRect(x: 0, y: 0, width: 1440, height: 870), dock = CGRect(x: 0, y: 90, width: 1440, height: 780)
        var player = SidePlayer()
        func request(_ t: Double, visible: CGRect) -> StageRequest { sideRequest(style: 1, scene: .interrupted, homeX: 576, homeY: 60, now: t, visible: visible, elapsed: 0.2) }
        var problems: [String] = []
        let first = request(0, visible: noDock)
        _ = try player.present(first)
        problems += broken(player.layouts.last ?? nil, first, label: "before")
        #expect(player.steps.last?.plan?.side == .below, "below fits with no Dock")
        // the Dock appears: no new frame of the scene, one layout
        let docked = request(0.4, visible: dock)
        var d = docked; d.bubbleMemory = player.memory
        _ = try player.present(docked)
        problems += broken(player.layouts.last ?? nil, d, label: "docked")
        #expect(player.steps.last?.change == .safety && player.steps.last?.plan?.side == .above, "\(String(describing: player.steps.last?.change)) \(String(describing: player.steps.last?.plan?.side))")
        // the Dock goes away: the bubble comes back after 0.5 s, by its wake
        let gone = request(1.0, visible: noDock)
        let stage = try #require(try { var g = gone; g.bubbleMemory = player.memory; return try stageRenderer.compose(g) }())
        player.memory = stage.layout.memory
        #expect(stage.bubble?.plan.side == .above, "not yet")
        var g = gone; g.bubbleMemory = player.memory
        let wake = try #require(stageRenderer.nextChange(g, composed: stage), "a wake is armed for the pending return")
        #expect(abs(wake - 0.5) < 1e-6, "\(wake)")
        var due = request(1.0 + wake, visible: noDock); due.bubbleMemory = player.memory
        let back = try #require(try stageRenderer.layout(due))
        #expect(back.bubble?.plan.side == .below && back.placementChange == .returned)
        problems += broken(back, due, label: "back")
        #expect(problems.isEmpty, "\(problems.prefix(6))")
    }

    // MARK: (d)

    /// A menu opens over a still bubble and closes: the bubble moves out of its way at once, and returns 0.5 s after the target fits again, by the wake
    /// and not before.
    @Test func BubbleSequence_menuOpenThenCloseOnAStaticFallbackBubble() throws {
        let free = try #require(try stageRenderer.layout(sideRequest(style: 4, scene: .error, homeX: 576, homeY: 300, elapsed: 0.2))?.bubble).rect
        let menu = CGRect(x: free.minX + 6, y: free.minY - 20, width: 60, height: free.height + 30)
        var memory: BubbleMemory?
        var problems: [String] = []
        func frame(_ t: Double, menu: CGRect?) throws -> (StageFrame, StageRequest) {
            var r = sideRequest(style: 4, scene: .error, homeX: 576, homeY: 300, now: t, menu: menu, elapsed: 0.2); r.bubbleMemory = memory
            let stage = try #require(try stageRenderer.compose(r))
            memory = stage.layout.memory
            problems += broken(stage.layout, r, label: "t=\(t)")
            return (stage, r)
        }
        let (a, _) = try frame(0, menu: nil)
        #expect(a.bubble?.plan.side == .below)
        let (b, _) = try frame(2, menu: menu)
        #expect(b.bubble?.plan.side != .below && b.layout.placementChange == .safety, "the bubble leaves the menu at once")
        let (c, rc) = try frame(4, menu: nil)
        #expect(c.bubble?.plan.side == b.bubble?.plan.side && c.layout.placementChange == nil, "the menu has just closed: still the fallback")
        let wake = try #require(stageRenderer.nextChange(rc, composed: c), "the pending return arms a wake")
        #expect(abs(wake - 0.5) < 1e-6, "\(wake)")
        let (early, _) = try frame(4 + wake - 0.02, menu: nil)
        #expect(early.bubble?.plan.side == b.bubble?.plan.side, "not before 0.5 s of fit")
        memory = c.layout.memory
        let (due, _) = try frame(4 + wake, menu: nil)
        #expect(due.bubble?.plan.side == .below && due.layout.placementChange == .returned)
        #expect(problems.isEmpty, "\(problems.prefix(6))")
    }
}

/// Amendment D-6 "Footprint": the 4.4 cap and V hold for every style, scene, side and size, with the longest string of each scene, and for the 188 verbs of
/// Claude Code at size 1 on each side.
@Suite("BubbleFootprintTests", .serialized)
struct BubbleFootprintTests {
    private func check(_ layout: StageLayout?, geometry: PetGeometry, label: String) -> [String] {
        guard let layout, let bubble = layout.bubble else { return [] }
        var out: [String] = []
        let r = bubble.rect, visible = geometry.visibleFrame, eps = 0.51 / layout.pixelScale, unit = geometry.unit
        if r.width > 200 + eps || r.height > 48 + eps { out.append("\(label): \(r.size) over the 200 x 48 cap") }
        if bubble.plan.shapeRect.height > 6 * unit + eps { out.append("\(label): the shape is \(bubble.plan.shapeRect.height) pt, over the body's 6 units") }
        if r.minX < visible.minX - eps || r.maxX > visible.maxX + eps || r.maxY > visible.maxY + eps || r.minY < visible.minY + 24 - eps { out.append("\(label): V, outside the frame or in the band: \(r)") }
        if layout.clawdMask.intersects(r.insetBy(dx: 0.01, dy: 0.01)) { out.append("\(label): on Clawd") }
        if bubble.plan.side == .below, let feet = layout.feetBottom, r.maxY > feet.y - unit + eps { out.append("\(label): F1") }
        return out
    }

    @Test func BubbleFootprint_matrix() throws {
        let longestVerb = try #require(stageRenderer.elements.present.max { $0.count < $1.count })
        let longestPast = try #require(stageRenderer.elements.past.max { $0.count < $1.count })
        let longestDuration = 3 * 3600 + 59 * 60 + 59.0
        var checked = 0, problems: [String] = []
        for style in BubbleDesign.allIds { for scene in BubbleContent.shownScenes { for side in BubbleSide.allCases { for scale in [1.0, 1.5, 2.0, 3.0, 4.0] {
            for (homeX, homeY) in [(640.0, 300.0), (20.0, 120.0)] {
                let r = sideRequest(style: style, scene: scene, side: side, homeX: homeX, homeY: homeY, scale: scale, verb: longestVerb, past: longestPast, duration: longestDuration)
                problems += check(try stageRenderer.layout(r), geometry: r.geometry, label: "style \(style) \(scene) \(side) size \(scale) at \(homeX)")
                checked += 1
            }
        } } } }
        #expect(problems.isEmpty, "\(problems.prefix(6))")
        #expect(checked == 15 * 5 * 4 * 5 * 2)
    }

    @Test func BubbleFootprint_theVerbSweepAtSizeOneOnEachSide() throws {
        let verbs = stageRenderer.elements.present
        #expect(verbs.count == 188)
        var checked = 0, problems: [String] = []
        for side in BubbleSide.allCases { for style in BubbleDesign.allIds { for verb in verbs {
            let r = sideRequest(style: style, side: side, homeX: 640, homeY: 300, verb: verb)
            problems += check(try stageRenderer.layout(r), geometry: r.geometry, label: "style \(style) \(side) \(verb)")
            if !problems.isEmpty { break }
            checked += 1
        } } }
        #expect(problems.isEmpty, "\(problems.prefix(6))")
        #expect(checked == 4 * 15 * 188)
    }
}
