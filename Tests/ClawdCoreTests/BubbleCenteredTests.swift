import Testing
import Foundation
import CoreGraphics
import ClawdCore
@testable import ClawdRendering

/// Amendment "an above or below bubble is centered on Clawd": D-1 (the centered tip column), D-2 (the order), D-2a (no flip at the middle).
@Suite("BubbleCenteredTests", .serialized)
struct BubbleCenteredTests {
    /// Every scene the golden tests cover, the longest verb and the longest SENT line.
    static func contents() -> [(name: String, content: BubbleContent)] {
        let present = stageRenderer.elements.present, past = stageRenderer.elements.past
        let longestVerb = present.max { $0.count < $1.count } ?? "Cogitating", shortestVerb = present.min { $0.count < $1.count } ?? "Run"
        let longestPast = past.max { $0.count < $1.count } ?? "Cogitated"
        return [
            ("listening", BubbleContent(scene: .listening, elapsed: 0.1)),
            ("listening cursor off", BubbleContent(scene: .listening, elapsed: 0.6)),
            ("thinking", BubbleContent(scene: .thinking, elapsed: 0.7, verb: "Cogitating")),
            ("thinking longest verb", BubbleContent(scene: .thinking, elapsed: 0.7, verb: longestVerb)),
            ("thinking shortest verb", BubbleContent(scene: .thinking, elapsed: 0.7, verb: shortestVerb)),
            ("sent", BubbleContent(scene: .sent, duration: 5, pastVerb: "Cooked")),
            ("sent longest line", BubbleContent(scene: .sent, duration: BubbleChecks.longestDuration, pastVerb: longestPast)),
            ("error", BubbleContent(scene: .error)),
            ("interrupted", BubbleContent(scene: .interrupted)),
        ]
    }

    /// D-1: for every style, every scene's variants (snug and roomy), each opening forced, and both backings, the centered tip column is legal and the
    /// painted box's centre is within one bubble unit of the tip edge that lies over H. Measured on the drawn bitmap, not on the formula.
    @Test func BubbleDesign_theCenteredTipIsLegalForEveryStyleAndVariant() {
        var failures: [String] = [], listing: [String] = []
        var worst: [Int: Double] = [:], cases = 0
        var oddWidths = 0, evenWidths = 0
        for style in BubbleDesign.allIds {
            let design = BubbleDesign.resolved(style)
            for (name, content) in Self.contents() {
                let text = BubbleText.content(content, elements: stageRenderer.elements, design: design)
                for variant in [BubbleVariant.snug, .roomy] { for opening in [BubbleOpening.right, .left] {
                    for backing in (design.isSmooth ? [1.0, 2.0] : [1.0]) {
                        let w = design.boxWidth(runs: text.runs, dots: text.dots, variant: variant)
                        let column = design.centeredTip(opening, boxWidth: w)
                        let bounds = design.verticalTipBounds(opening: opening, boxWidth: w, variant: variant)
                        let tag = "style \(style) \(variant) \(opening) backing \(Int(backing)) (box \(w); first seen in \(name))"
                        cases += 1
                        if w % 2 == 0 { evenWidths += 1 } else { oddWidths += 1 }
                        if column < bounds.low || column > bounds.high { failures.append("\(tag): column \(column) outside \(bounds)") }
                        let bitmap = design.render(runs: text.runs, dots: text.dots, opening: opening, connection: .above, variant: variant, tipColumn: column,
                                                   backing: backing)
                        let expectedTip = Double(column + design.tipEdge(opening))
                        let tipX = bitmap.tipX - Double(design.margins.side)
                        if abs(tipX - expectedTip) > 1e-9 { failures.append("\(tag): drawn tip edge \(tipX) is not the asked column edge \(expectedTip) (clamped)") }
                        let centre = Double(bitmap.box.x - design.margins.side) + Double(bitmap.box.width) / 2
                        let offset = centre - tipX
                        worst[style] = max(worst[style] ?? 0, abs(offset))
                        listing.append("\(tag): column \(column) in \(bounds.low)...\(bounds.high), offset \(offset) unit(s)")
                        if abs(offset) > 1 { failures.append("\(tag): the box centre is \(offset) units from the tip edge") }
                    }
                } }
            }
            listing.append("style \(style): worst offset \(worst[style] ?? 0) unit(s)")
        }
        print("ENUMERATION cases=\(cases) oddBoxWidths=\(oddWidths) evenBoxWidths=\(evenWidths)")
        for line in listing { print("ENUMERATION \(line)") }
        #expect(oddWidths > 0 && evenWidths > 0, "both odd and even box widths must be enumerated")
        #expect(failures.isEmpty, "\(Set(failures).sorted().prefix(40).joined(separator: "\n"))")
    }

    // MARK: the picture

    private func unit(_ design: BubbleDesign) -> Double { design.isSmooth ? 1 : BubbleChecks.pixelPt(design) }

    /// Where the painted box's centre is, from the drawn bitmap's box and the picture's x, in points.
    private func boxCentreX(_ bubble: PlacedBubble) -> Double {
        let design = BubbleDesign.resolved(bubble.style), box = bubble.bitmap.box
        return bubble.rect.minX + (Double(box.x) + Double(box.width) / 2) * unit(design)
    }

    /// Done-bar 1: in the normal form an above or below bubble's box is centered on Clawd, within one bubble pixel, for every style, every variant it
    /// draws, sizes 1 to 4 and both backings, and with Clawd in either half of the display.
    @Test func BubblePlacement_aboveAndBelowAreCenteredOnClawd() throws {
        var checked = 0, failures: [String] = [], worst = 0.0
        for style in BubbleDesign.allIds {
            let design = BubbleDesign.resolved(style)
            for scene in [Scene.listening, .thinking, .sent] { for side in [BubbleSide.above, .below] { for scale in [1.0, 2.0, 3.0, 4.0] {
                for backing in [1.0, 2.0] { for homeX in [576.0, 864.0] {
                    let request = sideRequest(style: style, scene: scene, side: side, homeX: homeX, homeY: 300, scale: scale, pixelScale: backing)
                    let layout = try #require(try stageRenderer.layout(request))
                    let bubble = try #require(layout.bubble, "style \(style) \(scene) \(side)")
                    let tag = "style \(style) \(scene) \(side) size \(Int(scale)) backing \(Int(backing)) homeX \(Int(homeX))"
                    guard bubble.plan.side == side, bubble.plan.form == .normal, !bubble.plan.connectorHidden else {
                        failures.append("\(tag): not the normal form with its connector (\(bubble.plan.side) \(bubble.plan.form) hidden \(bubble.plan.connectorHidden))"); continue
                    }
                    let offset = boxCentreX(bubble) - layout.headTop.x
                    worst = max(worst, abs(offset) / unit(design))
                    if abs(offset) > unit(design) + 1e-6 { failures.append("\(tag): the box centre is \(offset) pt from Clawd's anchor") }
                    if abs(bubble.plan.boxRect.midX - layout.headTop.x) > unit(design) + 1e-6 { failures.append("\(tag): the plan's box is \(bubble.plan.boxRect.midX - layout.headTop.x) pt off") }
                    checked += 1
                } }
            } } }
        }
        print("CENTERED checked=\(checked) worst offset \(worst) bubble pixel(s)")
        #expect(checked == 15 * 3 * 2 * 4 * 2 * 2)
        #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
    }

    /// Done-bar 2: the connector-hidden forms of above and below are centered too. The normal ones sit on the centered tip; the slid ones are the
    /// centered picture moved no further inward than the frame needs.
    @Test func BubblePlacement_connectorHiddenVerticalFormsAreCenteredToo() throws {
        var checked = 0
        for style in BubbleDesign.allIds {
            let t = SideRun.text(style)
            guard t.design.connectorRows(.roomy) > 0 || t.design.connectorColumns(.roomy) > 0 else { continue }
            let b = unit(t.design)
            for side in [BubbleSide.above, .below] {
                var fixture = SideFixture(headX: 400, headY: 300)
                func planner(_ f: SideFixture) -> BubblePlacement.Planner {
                    BubblePlacement.Planner(design: t.design, runs: t.runs, dots: t.dots, site: f.site(), scale: 1, guards: .all, backing: 1)
                }
                for opening in [BubbleOpening.right, .left] {
                    let normal = try #require(planner(fixture).fit(PlacementIdentity(side: side, opening: opening, form: .normal, connectorHidden: true)), "style \(style) \(side) \(opening)")
                    #expect(normal.connectorHidden && abs(normal.boxRect.midX - 400) <= b + 1e-6, "style \(style) \(side) \(opening): box centre \(normal.boxRect.midX) against 400")
                    // a slid hidden form at each edge: the centered picture, moved only as far as the frame needs
                    for headX in [20.0, 1420.0] {
                        fixture.headX = headX
                        let p = planner(fixture), visible = fixture.visible
                        let centred = try #require(p.fit(PlacementIdentity(side: side, opening: opening, form: .normal, connectorHidden: true), validate: false))
                        let slid = try #require(p.fit(PlacementIdentity(side: side, opening: opening, form: .slid, connectorHidden: true)), "style \(style) \(side) \(opening) at \(headX)")
                        let expected = min(max(centred.rect.minX, visible.minX), max(visible.minX, visible.maxX - centred.rect.width))
                        #expect(abs(slid.rect.minX - expected) <= 1e-6 && slid.connectorHidden, "style \(style) \(side) \(opening) at \(headX): picture x \(slid.rect.minX), expected \(expected)")
                        checked += 1
                    }
                    fixture.headX = 400
                }
            }
        }
        #expect(checked > 0)
    }

    /// Done-bar 2: near a display edge a centered bubble slides in with the tip still over Clawd, then loses its connector; it never leaves the frame and
    /// never disappears while there is room for the box. Walks the whole way to each edge, for both vertical sides, over a stateless layout per position.
    @Test func BubblePlacement_nearAnEdgeACenteredBubbleSlidesWithTheTipOverClawd() throws {
        var sawSlidWithConnector = Set<Int>(), sawHidden = Set<Int>(), problems: [String] = []
        for style in [1, 4, 6, 7, 11, 13, 14, 15] {
            let design = BubbleDesign.resolved(style), b = unit(design)
            for side in [BubbleSide.above, .below] {
                for homeXs in [Array(stride(from: 240.0, through: 0.0, by: -2.0)), Array(stride(from: 1150.0, through: 1392.0, by: 2.0))] {
                    for homeX in homeXs {
                        let request = sideRequest(style: style, side: side, homeX: homeX, homeY: 300, pixelScale: 2)
                        guard let layout = try stageRenderer.layout(request), let bubble = layout.bubble else { problems.append("style \(style) \(side) x \(homeX): no bubble"); continue }
                        let plan = bubble.plan, tag = "style \(style) \(side) x \(homeX) \(plan.form) hidden \(plan.connectorHidden)"
                        guard plan.side == side else { problems.append("\(tag): fell to \(plan.side)"); continue }
                        if bubble.rect.minX < request.geometry.visibleFrame.minX - 1e-6 || bubble.rect.maxX > request.geometry.visibleFrame.maxX + 1e-6 {
                            problems.append("\(tag): outside the frame")
                        }
                        if plan.connectorHidden { sawHidden.insert(style); continue }
                        switch plan.form {
                        case .normal:
                            if abs(boxCentreX(bubble) - layout.headTop.x) > b + 1e-6 { problems.append("\(tag): not centered (\(boxCentreX(bubble) - layout.headTop.x))") }
                        case .slid:
                            if design.connectorRows(plan.variant) > 0 {
                                sawSlidWithConnector.insert(style)
                                let edge = Double(plan.tipColumn ?? 0) + Double(design.tipEdge(plan.opening)) + Double(design.margins.side)
                                let tipEdge = bubble.rect.minX + edge * b
                                if abs(tipEdge - layout.headTop.x) > b + 1e-6 { problems.append("\(tag): the tip edge \(tipEdge) is not over the anchor \(layout.headTop.x)") }
                            }
                        }
                    }
                }
            }
        }
        print("EDGE styles that slid with the connector \(sawSlidWithConnector.sorted()), styles that lost it \(sawHidden.sorted())")
        #expect(problems.isEmpty, "\(problems.prefix(12).joined(separator: "\n"))")
        #expect(sawSlidWithConnector.isSuperset(of: [1, 4, 7, 11, 13, 14, 15]), "slid with the connector: \(sawSlidWithConnector.sorted())")
        #expect(sawHidden.isEmpty, "a wide display always has room for a connector: \(sawHidden.sorted())")
        try narrowFrames()
    }

    /// The oracle for "a connector placement exists": some opening and some legal tip column put the whole picture inside the frame. Written from the
    /// bounds and the picture width, not from the planner.
    private func connectorPossible(_ design: BubbleDesign, boxWidth: Int, width: Double, variant: BubbleVariant, anchor: Double, visible: CGRect) -> Bool {
        let b = design.pixelPt
        for opening in [BubbleOpening.right, .left] {
            let bounds = design.verticalTipBounds(opening: opening, boxWidth: boxWidth, variant: variant)
            guard bounds.low <= bounds.high else { continue }
            for tip in bounds.low...bounds.high {
                let left = anchor - Double(tip + design.tipEdge(opening)) * b
                if left >= visible.minX - 1e-6 && left + width <= visible.maxX + 1e-6 { return true }
            }
        }
        return false
    }

    /// The step to the connector-hidden form: in a frame only 2 pt wider than the picture, an anchor within the connector's margin of either frame edge has
    /// no legal tip column, so the box is kept and the connector dropped, and everywhere else the tip is over the anchor. Both are met by a walk (on a
    /// made-up Clawd: the real one never stands that close to an edge).
    private func narrowFrames() throws {
        for style in [1, 4, 7, 13] {
            let t = SideRun.text(style), design = t.design, b = unit(design)
            let variant = BubbleLayout.variant(design: design, runs: t.runs, dots: t.dots, scale: 1)
            let width = Double(design.extent(runs: t.runs, dots: t.dots, variant: variant, connection: .above).width) * b
            for side in [BubbleSide.above, .below] {
                var shown = 0, hidden = 0, firstShown: Double?, lastShown: Double?
                for anchor in stride(from: 0.0, through: width + 2, by: 1.0) {
                    var f = SideFixture(headX: anchor, headY: 300)
                    f.visible = CGRect(x: 0, y: 80, width: width + 2, height: 790); f.display = CGRect(x: 0, y: 0, width: width + 2, height: 900)
                    // The box alone always fits a frame 2 pt wider than the picture, so every anchor has a bubble on the asked side.
                    guard let plan = SideRun.plan(style, f, side: side) else { Issue.record("style \(style) \(side) anchor \(anchor): no bubble"); continue }
                    #expect(plan.side == side, "style \(style) \(side) anchor \(anchor): placed \(plan.side) instead")
                    #expect(plan.rect.minX >= -1e-6 && plan.rect.maxX <= width + 2 + 1e-6, "style \(style) \(side) anchor \(anchor): inside the frame")
                    if plan.connectorHidden { hidden += 1; continue }
                    shown += 1; firstShown = firstShown ?? anchor; lastShown = anchor
                    if plan.form == .slid {
                        let edge = Double(plan.tipColumn ?? 0) + Double(design.tipEdge(plan.opening)) + Double(design.margins.side)
                        #expect(abs(plan.rect.minX + edge * b - anchor) <= b + 1e-6, "style \(style) \(side) anchor \(anchor): the tip is over the anchor")
                    }
                }
                #expect(shown > 0 && hidden > 0, "style \(style) \(side): connector shown \(shown) times (\(firstShown ?? -1) to \(lastShown ?? -1)), hidden \(hidden) times")
            }
        }
    }

    /// A style with a tip clamp whose span is more than 0 (style 13's stepped tail) keeps a connector wherever any legal tip column puts the whole picture
    /// inside the frame: the centered rule must not hide it earlier than the corner tip did. The oracle is written here from the bounds and the picture
    /// width, not from the planner.
    @Test func BubblePlacement_asymmetricBoundStylesKeepTheirEdgeConnectorPlacements() throws {
        let clamped = BubbleDesign.all.filter { $0.tipClamp != nil && !$0.isSmooth }
        #expect(clamped.map(\.id) == [13])
        var checked = 0, possibleCount = 0, problems: [String] = []
        for design in clamped {
            for side in [BubbleSide.above, .below] {
                for homeXs in [Array(stride(from: 240.0, through: 0.0, by: -1.0)), Array(stride(from: 1150.0, through: 1392.0, by: 1.0))] {
                    for homeX in homeXs {
                        let request = sideRequest(style: design.id, side: side, homeX: homeX, homeY: 300, pixelScale: 1)
                        guard let layout = try stageRenderer.layout(request), let bubble = layout.bubble else { problems.append("x \(homeX): no bubble"); continue }
                        let plan = bubble.plan, b = design.pixelPt, visible = request.geometry.visibleFrame
                        let boxW = design.boxWidth(runs: SideRun.text(design.id).runs, dots: SideRun.text(design.id).dots, variant: plan.variant)
                        let width = Double(design.extent(runs: SideRun.text(design.id).runs, dots: SideRun.text(design.id).dots, variant: plan.variant, connection: .above).width) * b
                        var possible = false
                        for opening in [BubbleOpening.right, .left] {
                            let bounds = design.verticalTipBounds(opening: opening, boxWidth: boxW, variant: plan.variant)
                            for tip in bounds.low...bounds.high {
                                let left = layout.headTop.x - Double(tip + design.tipEdge(opening)) * b
                                if left >= visible.minX - 1e-6 && left + width <= visible.maxX + 1e-6 { possible = true }
                            }
                        }
                        checked += 1
                        if possible { possibleCount += 1 }
                        if possible && plan.connectorHidden { problems.append("side \(side) x \(homeX) (anchor \(layout.headTop.x)): a legal tip column fits, yet the connector is hidden") }
                    }
                }
            }
        }
        // The same oracle in a frame only 2 pt wider than the picture, on a made-up Clawd that can stand within the tail's margin of either edge: there
        // the other opening is the only one with a legal column on one of the sides.
        var narrowPossible = 0, narrowHidden = 0
        for design in clamped {
            let t = SideRun.text(design.id), b = design.pixelPt
            let variant = BubbleLayout.variant(design: design, runs: t.runs, dots: t.dots, scale: 1)
            let width = Double(design.extent(runs: t.runs, dots: t.dots, variant: variant, connection: .above).width) * b
            for side in [BubbleSide.above, .below] {
                for anchor in stride(from: 0.0, through: width + 2, by: 1.0) {
                    var f = SideFixture(headX: anchor, headY: 300)
                    f.visible = CGRect(x: 0, y: 80, width: width + 2, height: 790); f.display = CGRect(x: 0, y: 0, width: width + 2, height: 900)
                    // The oracle is read before the planner and whatever it does: no bubble, the other side or a hidden connector where a legal
                    // tip column fits are all failures.
                    // For each variant the planner may draw (snug, roomy), whether a legal tip column puts that variant's whole picture inside the frame.
                    var possibleFor: [BubbleVariant: Bool] = [:]
                    for v in [BubbleVariant.snug, .roomy] {
                        let w = Double(design.extent(runs: t.runs, dots: t.dots, variant: v, connection: .above).width) * b
                        possibleFor[v] = connectorPossible(design, boxWidth: design.boxWidth(runs: t.runs, dots: t.dots, variant: v), width: w, variant: v,
                                                           anchor: anchor, visible: f.visible)
                    }
                    if possibleFor.values.contains(true) { narrowPossible += 1 }
                    guard let plan = SideRun.plan(design.id, f, side: side) else { problems.append("narrow frame, \(side), anchor \(anchor): no bubble"); continue }
                    if plan.side != side { problems.append("narrow frame, \(side), anchor \(anchor): placed \(plan.side) instead"); continue }
                    if plan.connectorHidden { narrowHidden += 1 }
                    if possibleFor[plan.variant] == true && plan.connectorHidden {
                        problems.append("narrow frame, \(side), anchor \(anchor): a legal tip column fits the \(plan.variant) picture, yet the connector is hidden")
                    }
                }
            }
        }
        print("ASYMMETRIC narrow frame: legal connector placements \(narrowPossible), connector hidden \(narrowHidden)")
        #expect(narrowPossible > 0 && narrowHidden > 0, "the walk must meet both a connector and its absence")
        print("ASYMMETRIC positions \(checked), with a legal connector placement \(possibleCount)")
        #expect(possibleCount > checked / 2)
        #expect(problems.isEmpty, "\(problems.prefix(12).joined(separator: "\n"))")
    }

    // MARK: D-2a

    /// The identities a stateful player showed over a walk across the display's middle and a stand on the far side.
    private func walk(style: Int, side: BubbleSide, from start: Double, to end: Double, speed: Double, stand: Double, scenes: [Scene]? = nil) throws -> (SidePlayer, StageLayout) {
        var player = SidePlayer(), t = 0.0, last: StageLayout?
        let dt = 1.0 / 30, travel = abs(end - start) / speed
        while t < travel + stand {
            let x = start + (end > start ? 1 : -1) * min(speed * t, abs(end - start))
            let scene = scenes.map { $0[min($0.count - 1, Int(t / ((travel + stand) / Double($0.count))))] } ?? .thinking
            last = try player.present(sideRequest(style: style, scene: scene, side: side, homeX: x, homeY: 300, now: t, elapsed: scene == .sent ? 1.0 : 0.7))
            t += dt
        }
        return (player, try #require(last))
    }

    /// D-2a: crossing the display's middle never changes the opening of a centered bubble: no change of any field of the placement identity, while the
    /// stateless layout on the far side does ask for the other opening (so the rule is what keeps it).
    @Test func BubbleStability_aCenteredBubbleKeepsItsOpeningAcrossTheMiddle() throws {
        for style in [1, 4, 11, 13, 14] { for side in [BubbleSide.above, .below] { for direction in [1.0, -1.0] {
            let start = direction > 0 ? 520.0 : 880.0, end = direction > 0 ? 880.0 : 520.0
            let (player, last) = try walk(style: style, side: side, from: start, to: end, speed: 200, stand: 1.5)
            let identities = player.steps.compactMap { $0.plan?.identity }
            #expect(identities.count == player.steps.count && Set(identities.map { "\($0)" }).count == 1, "style \(style) \(side) \(direction): \(Set(identities.map { "\($0)" }))")
            #expect(player.changes.isEmpty, "style \(style) \(side) \(direction): \(player.changes.map { ($0.t, $0.change as Any) })")
            let fresh = try #require(try stageRenderer.layout(sideRequest(style: style, side: side, homeX: end, homeY: 300, now: 99)))
            #expect(fresh.bubble?.plan.opening != last.bubble?.plan.opening, "style \(style) \(side) \(direction): the stateless opening is the kept one, the walk proves nothing")
        } } }
    }

    /// D-2a does not block the safety rule: a menu that covers a centered bubble moves it at once, in the frame the menu opens.
    @Test func BubbleStability_aMenuOverACenteredBubbleStillMovesItAtOnce() throws {
        let dt = 1.0 / 30
        for side in [BubbleSide.below, .above] {
            let free = try #require(try stageRenderer.layout(sideRequest(style: 1, side: side, homeX: 576, homeY: 300))?.bubble).rect
            let menu = CGRect(x: free.minX + 6, y: free.minY - 4, width: 60, height: free.height + 8)
            var player = SidePlayer()
            for k in 0..<40 {
                let open = k >= 20
                _ = try player.present(sideRequest(style: 1, side: side, homeX: 576, homeY: 300, now: Double(k) * dt, menu: open ? menu : nil))
            }
            let changes = player.changes
            #expect(changes.count == 1 && changes[0].change == .safety && abs(changes[0].t - 20 * dt) < 1e-6, "\(side): \(changes.map { ($0.t, $0.change as Any) })")
            for step in player.steps where step.t >= 20 * dt { if let plan = step.plan { #expect(!plan.rect.intersects(menu), "\(side) at \(step.t)") } }
        }
    }

    /// A walk with scene changes (the box width changes under the memory) across the middle and a stand longer than the return delay: nothing changes.
    @Test func BubbleSequence_aWalkAcrossTheMiddleNeverFlipsACenteredBubble() throws {
        for style in [1, 7, 11, 13, 15] { for side in [BubbleSide.above, .below] {
            let (player, _) = try walk(style: style, side: side, from: 480, to: 960, speed: 120, stand: 2, scenes: [.listening, .thinking, .sent])
            #expect(player.changes.isEmpty, "style \(style) \(side): \(player.changes.map { ($0.t, $0.change as Any) })")
            #expect(Set(player.steps.compactMap { $0.plan.map { "\($0.identity)" } }).count == 1, "style \(style) \(side)")
        } }
    }

    // MARK: left and right

    /// One line per fixture of the left and right bubbles, in the format `BubbleSideBaseline` was recorded in.
    static func sideLines() throws -> [String] {
        var lines: [String] = []
        for style in BubbleDesign.allIds { for side in [BubbleSide.left, .right] { for homeX in [200.0, 864.0, 1300.0] { for scale in [1.0, 2.0] {
            let request = sideRequest(style: style, side: side, homeX: homeX, homeY: 300, scale: scale, pixelScale: 2)
            guard let layout = try stageRenderer.layout(request), let bubble = layout.bubble else { lines.append("\(style) \(side) \(Int(homeX)) \(Int(scale)) none"); continue }
            let r = bubble.rect, p = bubble.plan
            lines.append(String(format: "%d %@ %d %d %.3f %.3f %.3f %.3f %@ %@ %d", style, "\(side)", Int(homeX), Int(scale), r.minX, r.minY, r.width, r.height,
                                "\(p.opening)", "\(p.form)", p.connectorHidden ? 1 : 0))
        } } } }
        return lines
    }

    /// Done-bar 3: the left and right bubbles are what 4606804 drew, rectangle by rectangle, for every style, both sides, three positions and two sizes.
    @Test func BubblePlacement_sideBubblesAreUnchanged() throws {
        let now = try Self.sideLines(), before = BubbleSideBaseline.lines
        #expect(now.count == before.count && now.count == 15 * 2 * 3 * 2)
        let different = zip(now, before).filter { $0 != $1 }.map { "now \($0)\nwas \($1)" }
        #expect(different.isEmpty, "\(different.count) left or right bubbles moved:\n\(different.prefix(6).joined(separator: "\n"))")
    }
}
