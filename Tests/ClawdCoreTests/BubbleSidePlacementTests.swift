import Testing
import Foundation
import CoreGraphics
import ClawdCore
@testable import ClawdRendering

/// Amendment D-2, D-3, D-4, D-5: the bubble's side (below, above, left, right), default below, with the order of fallbacks, validation V and the below
/// connection of every style. Placement facts on a made-up Clawd (`SideFixture`) where a test needs exact numbers, on the real renderer where it needs a
/// real picture.
@Suite("BubbleSidePlacementTests", .serialized)
struct BubbleSidePlacementTests {
    private let eps = 0.001
    private func layout(_ r: StageRequest) throws -> StageLayout { try #require(try stageRenderer.layout(r)) }

    // MARK: the default

    /// The default is below: with no setting touched, the bubble of every style sits just under Clawd's feet, its connector pointing up at him, 1 unit
    /// under F (F2: equality, nothing in the way) and nothing painted nearer than that (F1).
    @Test func BubblePlacement_belowIsTheDefaultOrderAndSitsUnderTheFeet() throws {
        var checked = 0
        for style in BubbleDesign.allIds { for scene in [Scene.listening, .thinking] { for scale in [1.0, 2.0] {
            let l = try layout(sideRequest(style: style, scene: scene, scale: scale, pixelScale: 2))
            let bubble = try #require(l.bubble, "style \(style) \(scene)"), feet = try #require(l.feetBottom)
            let unit = 4 * scale
            #expect(bubble.plan.side == .below && bubble.plan.connection == .below && bubble.plan.form == .normal, "style \(style): \(bubble.plan.side) \(bubble.plan.connection)")
            #expect(bubble.rect.maxY <= feet.y - unit + eps, "F1, style \(style): the picture's top \(bubble.rect.maxY) is nearer than 1 unit to F \(feet.y)")
            #expect(abs(bubble.rect.maxY - (feet.y - unit)) <= eps, "F2, style \(style): the topmost painted row is \(feet.y - bubble.rect.maxY) pt under F, not 1 unit (\(unit))")
            // the opening is toward the middle of the display: Clawd is in the left half
            #expect(bubble.plan.opening == .right)
            // the connector's tip edge is over F
            let tipEdge = bubble.rect.minX + bubble.bitmap.tipX * (BubbleDesign.resolved(style).isSmooth ? 1 : BubbleChecks.pixelPt(BubbleDesign.resolved(style)))
            #expect(abs(tipEdge - feet.x) <= 1.01, "style \(style): the tip edge \(tipEdge) is not under F \(feet.x)")
            checked += 1
        } } }
        #expect(checked == 15 * 2 * 2)
    }

    @Test func BubblePlacement_aSlidTipSitsExactlyOverTheAnchorOrIsHidden() throws {
        var shown = 0, hidden = 0
        for side in [BubbleSide.below, .above] { for scale in [1.0, 2.0] {
            let wide = sideRequest(style: 1, side: side, homeX: 640, homeY: 300, scale: scale, pixelScale: 2)
            let normal = try #require(try stageRenderer.compose(wide))
            let normalBubble = try #require(normal.bubble)
            #expect(normalBubble.plan.form == .normal && !normalBubble.plan.connectorHidden)
            let width = normalBubble.rect.width, anchorOffset = normal.headTop.x - wide.geometry.homeOrigin.x
            // The painted tip row: the connector row nearest Clawd, read from the composed pixels, not from the plan or the bitmap.
            func tipColumns(_ frame: StageFrame, _ rect: CGRect) -> [Int] {
                let tipY = side == .below ? rect.maxY - 0.25 : rect.minY + 0.25
                let row = Int(((frame.panelFrame.maxY - tipY) * frame.pixelScale).rounded(.down))
                return (0..<frame.pixels.width).filter { frame.pixels.isOpaque($0, row) }
            }
            // Where the unslid form paints its tip relative to the anchor: the slid tip must sit exactly there too.
            let normalFirst = try #require(tipColumns(normal, normalBubble.rect).first)
            let normalOffset = normal.panelFrame.minX + Double(normalFirst) / normal.pixelScale - normal.headTop.x
            // Both openings overhang a display only 0 or 2 pt wider than the picture. Odd anchors exercise the original rounding bug;
            // even anchors and half-point frame edges also require an inward remainder shift or a connector-hidden form.
            // The centered picture hangs half its width to each side of the anchor, so the anchor is moved `shift` off the middle of a frame as wide as
            // the picture (amendment centered D-4: at 4606804 the picture hung to one side and the middle itself overhung).
            for extra in [0.0, 2.0] { for edge in [0.0, 0.5] { for parity in [0.0, 1.0] { for shift in [-4.0, 4.0] {
                let anchor = (width / 4).rounded(.down) * 2 + parity + shift
                let display = CGRect(x: edge, y: 0, width: width + extra, height: 900)
                let visible = CGRect(x: edge, y: 80, width: width + extra, height: 790)
                let request = sideRequest(style: 1, side: side, homeX: anchor - anchorOffset, homeY: 300, scale: scale,
                                          pixelScale: 2, display: display, visible: visible)
                let frame = try #require(try stageRenderer.compose(request))
                let bubble = try #require(frame.bubble)
                #expect(bubble.plan.side == side && bubble.plan.form == .slid)
                #expect(abs(frame.headTop.x - anchor) < eps)
                let columns = tipColumns(frame, bubble.rect)
                let first = try #require(columns.first), last = try #require(columns.last)
                if bubble.plan.connectorHidden {
                    hidden += 1
                    #expect(bubble.bitmap.height == Int(bubble.plan.boxRect.height / 2))
                    #expect(columns.count > 4, "the nearest painted row is the box, not a connector")
                } else {
                    shown += 1
                    #expect(columns.count == 4, "style 1's tip is one 2 pt column at 2x backing")
                    let centre = frame.panelFrame.minX + Double(first + last + 1) / (2 * frame.pixelScale)
                    #expect(abs(centre - anchor) <= 1.01, "the unslid form's tolerance: tip \(centre), anchor \(anchor)")
                    let offset = frame.panelFrame.minX + Double(first) / frame.pixelScale - anchor
                    // The other opening's slid form is now tried too (centered D-2): its tip column lies left of the edge that is over the anchor,
                    // as the unslid left-opening one does, so it sits one column left of the right opening's.
                    let column = Double(columns.count) / frame.pixelScale
                    let expected = bubble.plan.opening == .right ? normalOffset : normalOffset - column
                    #expect(abs(offset - expected) < eps, "the slid tip sits where the unslid one of its opening does: \(offset) vs \(expected), \(side), size \(scale), edge \(edge), parity \(parity), \(bubble.plan.opening)")
                }
            } } } }
        } }
        #expect(shown > 0 && hidden > 0, "exercise both alignment and the no-aligned-position fallback")
    }

    /// A prop under the feet that the picture would meet lowers it in steps of one bubble pixel; the gap is then more than 1 unit and never less (F1).
    @Test func BubblePlacement_aLoweredBelowKeepsAtLeastOneUnit() throws {
        for style in [1, 4, 6, 7, 11, 13, 14] {
            var f = SideFixture(headX: 400, headY: 300)
            // a prop pixel block right under the feet, inside the picture's width: it hangs 26 pt under the torso
            f.props = [CGRect(x: 396, y: 250, width: 12, height: 26)]
            let plan = try #require(SideRun.plan(style, f, side: .below), "style \(style)")
            let feet = f.feetBottom
            #expect(plan.side == .below, "style \(style): \(plan.side)")
            #expect(plan.rect.maxY <= feet.y - 4 + eps, "F1: style \(style) top \(plan.rect.maxY), F \(feet.y)")
            #expect(plan.rect.maxY < feet.y - 4 - 1, "style \(style): the prop lowered the picture")
            #expect(plan.rect.maxY <= 250 + eps, "style \(style): the picture is clear of the prop's lowest row")
            #expect(!f.mask().intersects(plan.rect), "style \(style): the picture lies on the prop")
        }
    }

    /// A low prop outside the torso's column band (a swinging item) is lowered past like any other.
    @Test func BubblePlacement_aLowPropIsLoweredPast() throws {
        var f = SideFixture(headX: 400, headY: 300)
        f.props = [CGRect(x: 428, y: 246, width: 10, height: 28)]            // x 428...438 is right of the torso band; y 246...274 reaches the picture's top
        let plan = try #require(SideRun.plan(1, f, side: .below))
        #expect(plan.side == .below)
        #expect(abs(plan.rect.maxY - 246) <= 2 + eps, "lowered to the prop's lowest row (steps of one 2 pt pixel): \(plan.rect.maxY)")
        #expect(!f.mask().intersects(plan.rect))
        // the same fixture without the prop is 1 unit under F exactly
        let free = try #require(SideRun.plan(1, SideFixture(headX: 400, headY: 300), side: .below))
        #expect(abs(free.rect.maxY - (276 - 4)) <= eps)
    }

    // MARK: the order, per chosen side

    @Test func BubblePlacement_thereIsOneOrderPerChosenSideWithRoomAllRound() throws {
        for side in BubbleSide.allCases { for style in BubbleDesign.allIds {
            let l = try layout(sideRequest(style: style, side: side, homeX: 640, homeY: 300))
            let plan = try #require(l.bubble, "\(side) style \(style)").plan
            #expect(plan.side == side, "chosen \(side), style \(style): shown \(plan.side)")
            switch side {
            case .below: #expect(plan.connection == .below)
            case .above: #expect(plan.connection == .above)
            case .left: #expect(plan.connection == .side && plan.opening == .left)
            case .right: #expect(plan.connection == .side && plan.opening == .right)
            }
            #expect(plan.form == .normal && !plan.connectorHidden)
        } }
        // every chosen side tries every side once, chosen first
        for chosen in BubbleSide.allCases { for towards in [BubbleSide.left, .right] {
            let order = BubblePlacement.sides(chosen: chosen, towardsMiddle: towards)
            #expect(order.first == chosen && Set(order) == Set(BubbleSide.allCases) && order.count == 4, "\(chosen), middle \(towards): \(order)")
        } }
        #expect(BubblePlacement.sides(chosen: .below, towardsMiddle: .right) == [.below, .above, .right, .left])
        #expect(BubblePlacement.sides(chosen: .above, towardsMiddle: .left) == [.above, .below, .left, .right])
        #expect(BubblePlacement.sides(chosen: .left, towardsMiddle: .right) == [.left, .right, .below, .above])
        #expect(BubblePlacement.sides(chosen: .right, towardsMiddle: .left) == [.right, .left, .below, .above])
    }

    @Test func BubblePlacement_belowFallsToAboveNearTheBottomBand() throws {
        let c = PlacementCase.all[4]            // very bottom: Clawd flush with the visible frame's bottom edge
        for style in BubbleDesign.allIds {
            var r = sideRequest(style: style, homeX: c.geometry(scale: 1).homeOrigin.x, homeY: c.geometry(scale: 1).homeOrigin.y, visible: c.visible)
            r.geometry = c.geometry(scale: 1)
            let plan = try #require(try layout(r).bubble, "style \(style)").plan
            #expect(plan.side == .above && plan.connection == .above, "style \(style): \(plan.side)")
            #expect(plan.rect.minY >= c.visible.minY + 24 - eps)
        }
    }

    /// A below picture that would end s points short of the bottom band (0 < s < 1 unit) is rejected, not moved up by s: moving it up would clear the
    /// band and Clawd (V passes) but leave less than 1 unit under his feet (F1). The fallback above is chosen.
    @Test func BubblePlacement_belowShortOfTheBandStaysRejectedNotNudged() throws {
        for style in [1, 4, 6, 9, 13, 14] {
            let probe = SideFixture(headX: 400, headY: 400)
            // the shortest form of the side is the one that has to be short: the picture without its connector (the same as the one with it where a style
            // has none), so that no form of the chosen side fits and the fallback above is taken
            let t = SideRun.text(style), bare = t.design.withoutConnector
            let bareHeight = Double(bare.pictureExtent(runs: t.runs, dots: t.dots, variant: BubbleLayout.variant(design: bare, runs: t.runs, dots: t.dots, scale: 1), connection: .above).height)
                * (t.design.isSmooth ? 1 : BubbleChecks.pixelPt(t.design))
            let shown = try #require(SideRun.plan(style, probe, side: .below), "style \(style)")
            let height = min(bareHeight, shown.rect.height)
            let band = Screens.visible.minY + 24
            for s in [1.0, 2.0, 3.0] {
                // the picture's bottom would be `s` under the band's top edge
                let feetY = band - s + height + 4
                let f = SideFixture(headX: 400, headY: feetY + 24)
                let plan = try #require(SideRun.plan(style, f, side: .below), "style \(style) s=\(s)")
                #expect(plan.side == .above, "style \(style), \(s) pt short of the band: the picture was \(plan.side) (rect \(plan.rect), F \(f.feetBottom.y))")
                if plan.side == .below { #expect(plan.rect.maxY <= f.feetBottom.y - 4 + eps, "F1 broken by a nudged picture") }
            }
        }
    }

    /// Wherever Clawd is relative to the band, no accepted below picture lies closer than 1 unit under his feet, in the band, or on him.
    @Test func BubblePlacement_belowDoesNotMoveUpIntoClawd() throws {
        for style in [1, 7, 10, 13, 15] {
            let height = try #require(SideRun.plan(style, SideFixture(headX: 400, headY: 400), side: .below)).rect.height
            let band = Screens.visible.minY + 24
            for step in stride(from: -30.0, through: 30.0, by: 1.0) {
                let f = SideFixture(headX: 400, headY: band + height + 28 + step)
                guard let plan = SideRun.plan(style, f, side: .below) else { continue }
                if plan.side == .below {
                    #expect(plan.rect.maxY <= f.feetBottom.y - 4 + eps, "style \(style) step \(step): F1")
                    #expect(plan.rect.minY >= band - eps, "style \(style) step \(step): the band")
                }
                #expect(!f.mask().intersects(plan.rect), "style \(style) step \(step): on Clawd")
            }
        }
    }

    @Test func BubblePlacement_leftFallsToRightAtTheLeftEdge() throws {
        let c = PlacementCase.all[1]            // left edge: Clawd flush against the left edge of the visible frame
        let r = sideRequest(side: .left, homeX: 0, homeY: 300)
        let plan = try #require(try layout(r).bubble).plan
        #expect(plan.side == .right && plan.opening == .right && plan.connection == .side, "\(plan.side)")
        #expect(c.name == "left edge")
    }

    @Test func BubblePlacement_rightFallsToLeftAtTheRightEdge() throws {
        let r = sideRequest(side: .right, homeX: Screens.visible.maxX - 48, homeY: 300)
        let plan = try #require(try layout(r).bubble).plan
        #expect(plan.side == .left && plan.opening == .left && plan.connection == .side, "\(plan.side)")
    }

    /// Left and right are absolute screen directions: a chosen left stays on Clawd's left in the right half of the display, where the opening toward the
    /// middle of a vertical side would be the same one. In the left half it must still be left (the box on his left, his tip pointing right).
    @Test func BubblePlacement_leftAndRightAreAbsoluteDirectionsInBothHalves() throws {
        for homeX in [300.0, 1000.0] { for side in [BubbleSide.left, .right] {
            let plan = try #require(try layout(sideRequest(side: side, homeX: homeX, homeY: 300)).bubble).plan
            #expect(plan.side == side && plan.opening == (side == .left ? .left : .right), "home \(homeX), chosen \(side): \(plan.side) opening \(plan.opening)")
        } }
    }

    /// Clawd in a corner: every chosen side gives some placement, and the order tries each side once.
    @Test func BubblePlacement_cornerClawdTriesEverySideOnce() throws {
        let corners: [(String, Double, Double)] = [("top left", 0, Screens.visible.maxY - 48), ("top right", Screens.visible.maxX - 48, Screens.visible.maxY - 48),
                                                   ("bottom left", 0, Screens.visible.minY), ("bottom right", Screens.visible.maxX - 48, Screens.visible.minY)]
        for (name, x, y) in corners { for chosen in BubbleSide.allCases {
            let l = try layout(sideRequest(side: chosen, homeX: x, homeY: y))
            let plan = try #require(l.bubble, "\(name), chosen \(chosen)").plan
            #expect(!l.clawdMask.intersects(plan.rect) && plan.rect.minX >= Screens.visible.minX - eps && plan.rect.maxX <= Screens.visible.maxX + eps, "\(name) \(chosen)")
            if chosen == plan.side { continue }
            // a fallback is the first side of the order that fits: every side before it was tried and failed
            let order = BubblePlacement.sides(chosen: chosen, towardsMiddle: l.headTop.x < Screens.display.midX ? .right : .left)
            #expect(order.contains(plan.side) && order.firstIndex(of: plan.side)! > 0, "\(name) \(chosen): \(plan.side)")
        } }
    }

    @Test func BubblePlacement_noRoomAnywhereGivesNoBubble() throws {
        for chosen in BubbleSide.allCases { for style in BubbleDesign.allIds {
            var f = SideFixture(headX: 30, headY: 50)
            f.display = CGRect(x: 0, y: 0, width: 60, height: 60); f.visible = f.display
            #expect(SideRun.plan(style, f, side: chosen) == nil, "chosen \(chosen), style \(style): a bubble in a 60 pt frame")
        } }
    }

    // MARK: slid, kept in, tip and obstacles (decision D)

    private func narrowFixture(style: Int, extra: Double = 10, headX: Double = 20) -> (SideFixture, Double) { SideFixture.narrow(style: style, extra: extra, headX: headX) }

    @Test func BubblePlacement_belowSlidesSidewaysOnly() throws {
        for style in [1, 4, 7, 9] {
            let (f, width) = narrowFixture(style: style)
            let plan = try #require(SideRun.plan(style, f, side: .below), "style \(style)")
            #expect(plan.side == .below && plan.form == .slid && !plan.connectorHidden, "style \(style): \(plan.side) \(plan.form)")
            #expect(plan.rect.minX >= -eps && plan.rect.maxX <= f.visible.maxX + eps, "style \(style): inside the frame")
            // a slide moves the picture along x only: the same y as in a frame with room
            var wide = f; wide.visible = Screens.visible; wide.display = Screens.display; wide.headX = 400
            let free = try #require(SideRun.plan(style, wide, side: .below))
            #expect(abs(plan.rect.maxY - free.rect.maxY) <= eps, "style \(style): slid vertically (\(plan.rect.maxY) against \(free.rect.maxY))")
            #expect(width > 0)
            // the connector is still under F
            let d = BubbleDesign.resolved(style)
            let tipEdge = plan.rect.minX + (Double(plan.tipColumn ?? 0) + (plan.opening == .left && !d.isSmooth ? 1 : 0)) * (d.isSmooth ? 1 : 2)
            if d.connectorRows(plan.variant) > 0 { #expect(abs(tipEdge - f.headX) <= 2 + eps, "style \(style): the tip edge \(tipEdge) is not under F \(f.headX)") }
        }
    }

    /// The slid position meets a prop that the unslid one missed: the obstacle step runs again after the slide and the picture goes down past it, on the
    /// chosen side. Clearance alone would also be met by a fallback, so the expected rectangle is asserted.
    @Test func BubblePlacement_aSlidPictureIsRelaunchedPastAProp() throws {
        for style in [1, 7] {
            var (f, width) = narrowFixture(style: style)
            // the slid picture spans x = 0 to `width`, the centered unslid one only as far as 20 + width / 2: a prop pixel in the part the slide
            // adds, in the picture's top rows (at 4606804 the corner-tip picture started 4 pt further right and the prop sat in the 4 pt between)
            let feet = f.feetBottom
            #expect(20 + width / 2 < width - 8, "style \(style): the prop must lie outside the unslid picture")
            f.props = [CGRect(x: width - 6, y: feet.y - 8, width: 2, height: 4)]
            let plan = try #require(SideRun.plan(style, f, side: .below), "style \(style)")
            #expect(plan.side == .below && plan.form == .slid, "style \(style): the chosen side's slid form wins, not a fallback (\(plan.side) \(plan.form))")
            #expect(abs(plan.rect.maxY - (feet.y - 8)) <= eps, "style \(style): lowered past the prop to \(feet.y - 8), not \(plan.rect.maxY)")
            #expect(!f.mask().intersects(plan.rect))
        }
    }

    /// A tip that cannot sit over the anchor after the slide is not clamped to the art (a misaligned connector): the picture is drawn without it.
    @Test func BubblePlacement_aTipThatCannotAlignDropsTheConnector() throws {
        for style in [1, 4, 6, 7, 13] {
            var f = SideFixture(headX: 2, headY: 300)
            f.visible = CGRect(x: 0, y: 80, width: 400, height: 790); f.display = f.visible
            let plan = try #require(SideRun.plan(style, f, side: .below), "style \(style)")
            #expect(plan.side == .below && plan.connectorHidden, "style \(style): \(plan.side), connector hidden \(plan.connectorHidden)")
            #expect(plan.rect.minX >= -eps)
        }
    }

    /// Side outranks connector: a chosen left whose connector form does not fit but whose connector-less form does beats the other side's connector form.
    @Test func BubblePlacement_chosenSideWithoutConnectorBeatsAFallbackWithConnector() throws {
        for style in [1, 4, 7] {
            let t = SideRun.text(style)
            let variant = BubbleLayout.variant(design: t.design, runs: t.runs, dots: t.dots, scale: 1)
            let withC = Double(t.design.extent(runs: t.runs, dots: t.dots, variant: variant, connection: .side).width) * 2
            let bare = t.design.withoutConnector
            let without = Double(bare.extent(runs: t.runs, dots: t.dots, variant: BubbleLayout.variant(design: bare, runs: t.runs, dots: t.dots, scale: 1), connection: .side).width) * 2
            #expect(withC - without > 4, "style \(style): the connector must take more than the 1 unit gap")
            // the torso's left edge is 1 pt past the room the connector-less box needs (4 pt gap + its width)
            let x0 = without + 5
            var f = SideFixture(headX: x0 + 16, headY: 300)
            f.visible = CGRect(x: 0, y: 80, width: 1440, height: 790)
            let plan = try #require(SideRun.plan(style, f, side: .left), "style \(style)")
            #expect(plan.side == .left && plan.connectorHidden && plan.form == .normal, "style \(style): chosen left, shown \(plan.side), connector hidden \(plan.connectorHidden), \(plan.form)")
        }
    }

    // MARK: V: every final candidate

    @Test func BubblePlacement_everyFinalCandidateIsInsideTheFrameAndBand() throws {
        var frames: [(String, CGRect)] = [("narrow", CGRect(x: 0, y: 80, width: 90, height: 700)), ("short", CGRect(x: 0, y: 0, width: 900, height: 40)),
                                          ("small", CGRect(x: 0, y: 20, width: 300, height: 180)), ("wide", Screens.visible)]
        frames.append(("fractional", CGRect(x: 0.3, y: 80.3, width: 1000.4, height: 700.4)))
        var plans = 0, kept = 0
        for (name, visible) in frames {
            for headX in stride(from: 20.0, through: max(40, visible.width - 20), by: max(10, (visible.width - 40) / 6)) {
                for headY in [visible.minY + 60, visible.midY, visible.maxY - 6] {
                    var f = SideFixture(headX: headX + visible.minX, headY: headY)
                    f.display = visible; f.visible = visible
                    for style in BubbleDesign.allIds { for side in BubbleSide.allCases {
                        guard let plan = SideRun.plan(style, f, side: side) else { continue }
                        plans += 1
                        if plan.form == .slid { kept += 1 }
                        let r = plan.rect, band = visible.minY + 24
                        #expect(r.minX >= visible.minX - eps && r.maxX <= visible.maxX + eps && r.maxY <= visible.maxY + eps && r.minY >= band - eps,
                                "\(name) style \(style) \(side) at (\(headX), \(headY)): \(r) in \(visible), band \(band), form \(plan.form), connector hidden \(plan.connectorHidden)")
                        #expect(!f.mask().intersects(r), "\(name) style \(style) \(side): on Clawd")
                    } }
                }
            }
        }
        #expect(plans > 500 && kept > 0, "\(plans) placements, \(kept) slid or kept in")
    }

    // MARK: under-feet items

    @Test func BubblePlacement_anUnderFeetItemMovesTheBubbleDown() throws {
        var found: [String] = []
        for look in stageRenderer.art.lookIDs {
            let composed = try stageRenderer.clawd(for: Frames.rest(look: look), now: 0, blink: false)
            guard let top = composed.headTopRow, let feetRow = composed.feetBottomRow, let head = composed.head else { continue }
            let bodyBottom = head.y + StageGeometry.torsoRows
            guard feetRow > bodyBottom else { continue }
            found.append(look)
            // F is the item's lowest opaque row in the torso's band, not the body's bottom row
            let l = try layout(sideRequest(scene: .listening, homeX: 576, homeY: 300, look: look))
            let feet = try #require(l.feetBottom)
            #expect(abs(feet.y - (l.canvas.maxY - Double(feetRow) * l.cellPt)) <= eps, "look \(look): F is \(feet.y)")
            #expect(feet.y < l.canvas.maxY - Double(bodyBottom) * l.cellPt - eps, "look \(look): F is not under the body's bottom row")
            let bubble = try #require(l.bubble, "look \(look)")
            #expect(bubble.plan.side == .below && bubble.rect.maxY <= feet.y - 4 + eps, "look \(look): the picture is \(l.canvas.maxY - bubble.rect.maxY) under the canvas top, F \(feet.y)")
            #expect(!l.clawdMask.intersects(bubble.rect), "look \(look): the picture lies on the item")
            #expect(top < feetRow)
        }
        #expect(!found.isEmpty, "no look of the catalog hangs an item under the feet: the case is gone")
    }

    // MARK: size, cap, budget

    @Test func BubblePlacement_everyStyleBelowKeepsTheCapAndTheBudget() throws {
        for design in BubbleDesign.all { for scene in BubbleContent.shownScenes { for verb in ["Cogitating", "Flibbertigibbeting"] {
            let text = BubbleText.content(BubbleContent(scene: scene, elapsed: 0.7, duration: 5, verb: verb, pastVerb: "Cogitated"), elements: stageRenderer.elements, design: design)
            for variant in [BubbleVariant.snug, .roomy] {
                let above = design.extent(runs: text.runs, dots: text.dots, variant: variant, connection: .above)
                let below = design.extent(runs: text.runs, dots: text.dots, variant: variant, connection: .below)
                #expect(above == below, "style \(design.id) \(variant): \(above) against \(below)")
                let a = design.pictureExtent(runs: text.runs, dots: text.dots, variant: variant, connection: .above)
                let b = design.pictureExtent(runs: text.runs, dots: text.dots, variant: variant, connection: .below)
                #expect(a == b)
                for opening in [BubbleOpening.right, .left] {
                    let up = design.render(runs: text.runs, dots: text.dots, opening: opening, connection: .above, variant: variant)
                    let down = design.render(runs: text.runs, dots: text.dots, opening: opening, connection: .below, variant: variant)
                    #expect(up.width == down.width && up.height == down.height, "style \(design.id) \(variant) \(opening): the pictures differ in size")
                }
            }
            #expect(BubbleLayout.variant(design: design, runs: text.runs, dots: text.dots, scale: 1) == BubbleLayout.variant(design: design, runs: text.runs, dots: text.dots, scale: 1))
        } } }
    }

    @Test func BubblePlacement_sizesOneToFourKeepTheRulesOnEverySide() throws {
        for scale in [1.0, 1.5, 2.0, 3.0, 4.0] { for side in BubbleSide.allCases { for style in [1, 4, 6, 10, 11, 13, 14, 15] {
            let l = try layout(sideRequest(style: style, side: side, homeX: 640, homeY: 300, scale: scale))
            let bubble = try #require(l.bubble, "size \(scale) \(side) style \(style)"), r = bubble.rect, unit = 4 * scale
            #expect(r.width <= 200 + eps && r.height <= 48 + eps, "size \(scale) \(side) style \(style): \(r.size)")
            #expect(bubble.plan.shapeRect.height <= 6 * unit + eps)
            #expect(r.minY >= Screens.visible.minY + 24 - eps && Screens.visible.contains(r.insetBy(dx: eps, dy: eps)))
            #expect(!l.clawdMask.intersects(r.insetBy(dx: 0.01, dy: 0.01)), "size \(scale) \(side) style \(style): on Clawd")
            if bubble.plan.side == .below, let feet = l.feetBottom { #expect(r.maxY <= feet.y - unit + eps) }
        } } }
    }

    // MARK: the menu and the body window

    @Test func BubblePlacement_neverCoversTheMenu() throws {
        for style in [1, 4, 9, 13, 15] {
            let free = try #require(try layout(sideRequest(style: style)).bubble)
            #expect(free.plan.side == .below)
            // an open menu on the part of the screen where the below picture would be
            let menu = CGRect(x: free.rect.minX + 6, y: free.rect.minY - 20, width: 60, height: free.rect.height + 30)
            let l = try layout(sideRequest(style: style, menu: menu))
            if let bubble = l.bubble {
                #expect(!bubble.rect.intersects(menu), "style \(style): the picture \(bubble.rect) lies on the menu \(menu)")
                #expect(bubble.plan.side != .below, "style \(style): the bubble stayed under the menu")
            }
            // a menu all round Clawd leaves nowhere: no bubble rather than one under the menu
            let wall = CGRect(x: 0, y: 80, width: 1440, height: 790)
            #expect(try layout(sideRequest(style: style, menu: wall)).bubble == nil, "style \(style): a bubble under a menu that covers the screen")
        }
    }

    @Test func BubblePlacement_bodyWindowClearance13to15OnAllFourSides() throws {
        for style in [13, 14, 15] { for side in BubbleSide.allCases { for (homeX, homeY) in [(640.0, 300.0), (20.0, 200.0), (1380.0, 150.0)] {
            let l = try layout(sideRequest(style: style, side: side, homeX: homeX, homeY: homeY))
            guard let bubble = l.bubble, let window = l.hit.bounds else { continue }
            #expect(!bubble.rect.intersects(window), "style \(style) \(side) at (\(homeX), \(homeY)): the picture \(bubble.rect) lies in the body window \(window)")
        } } }
    }

    @Test func BubblePlacement_clawdDoesNotMoveWhateverTheSide() throws {
        for style in [1, 13, 15] { for (homeX, homeY) in [(640.0, 300.0), (0.0, 80.0), (1392.0, 822.0)] {
            let rects = try BubbleSide.allCases.map { try layout(sideRequest(style: style, side: $0, homeX: homeX, homeY: homeY)).clawdRect }
            #expect(Set(rects.map { "\($0)" }).count == 1, "style \(style) at (\(homeX), \(homeY)): \(rects)")
            let canvases = try BubbleSide.allCases.map { try layout(sideRequest(style: style, side: $0, homeX: homeX, homeY: homeY)).canvas }
            #expect(canvases.allSatisfy { $0 == canvases[0] && $0.origin == CGPoint(x: homeX, y: homeY) })
        } }
    }

    /// Reduce Motion changes only the spinner glyph: the rectangle of a below placement is the same with and without it.
    @Test func BubblePlacement_reduceMotionDoesNotMoveABelowBubble() throws {
        for style in BubbleDesign.allIds {
            var a = sideRequest(style: style), b = sideRequest(style: style)
            a.content.reduceMotion = false; b.content.reduceMotion = true
            let ra = try #require(try layout(a).bubble?.plan.rect), rb = try #require(try layout(b).bubble?.plan.rect)
            // the dot of Reduce Motion and the spinner glyph differ in width in some styles (as before this change); the picture is centered on Clawd,
            // so what stays is its height, its y and its centre (at 4606804 the corner tip kept the left edge instead)
            #expect(ra.minY == rb.minY && ra.height == rb.height && abs(ra.midX - rb.midX) <= 1, "style \(style): \(ra) against \(rb)")
        }
    }

    // MARK: the connection of each style (D-3)

    /// The below picture is the above one turned over: the connector's cells (and the box's edge row it opens) are the vertical mirror of the above
    /// picture's, and the words are not. A style whose mirrored art did not attach would show here; style 10's near corner moves to the top.
    @Test func BubblePlacement_belowConnectorAttachesPerStyle() throws {
        for design in BubbleDesign.pixelDesigns { for variant in [BubbleVariant.snug, .roomy] { for opening in [BubbleOpening.right, .left] {
            let text = BubbleText.content(BubbleContent(scene: .thinking, elapsed: 0.7, duration: 5, verb: "Cogitating"), elements: stageRenderer.elements, design: design)
            let up = design.render(runs: text.runs, dots: text.dots, opening: opening, connection: .above, variant: variant)
            let down = design.render(runs: text.runs, dots: text.dots, opening: opening, connection: .below, variant: variant)
            let rows = design.connectorRows(variant), h = design.boxHeight(variant), total = h + rows
            let label = "style \(design.id) \(variant) \(opening)"
            #expect(down.box.y == rows && up.box.y == 0, "\(label): the box starts \(down.box.y) rows down")
            #expect(down.raster.height == up.raster.height && down.raster.width == up.raster.width)
            if rows == 0 {
                if design.id != 10 { #expect(down.raster == up.raster, "\(label): a style without a connector is the same picture under the feet") }
                continue
            }
            // the connector and the edge row it opens: row y above is row total-1-y below; the box's own cells (words, fill) are not compared
            var compared = 0
            for y in 0..<total { for x in 0..<up.raster.width {
                let inBox = x >= up.box.x && x < up.box.x + up.box.width && y < h - 1
                if inBox { continue }
                // the drop shadow stays under the box (it is painted after the turn): it is not part of the connector
                if let shadow = design.dropShadow, up.raster[x, y] == shadow || down.raster[x, total - 1 - y] == shadow { continue }
                compared += 1
                #expect(down.raster[x, total - 1 - y] == up.raster[x, y], "\(label): cell (\(x), \(y)) is not the mirror of the above picture's")
            } }
            #expect(compared > 0)
            // attachment: the connector row nearest to the box touches the box's top row, with no gap and no overlap in the opening
            if design.id != 11 && design.id != 6 {
                let touching = (0..<down.raster.width).filter { down.raster.isOpaque($0, rows - 1) && down.raster.isOpaque($0, rows) }
                #expect(!touching.isEmpty, "\(label): the connector does not meet the box")
            }
            // the tip is the topmost row
            #expect(down.tip.y == 0, "\(label): the tip is on row \(down.tip.y)")
            #expect(down.raster.isOpaque(down.tip.x, 0), "\(label): no pixel at the tip")
        } } }
        // style 10: the small near-Clawd corner of the above picture (lower, on the side of the anchor) is the upper corner under the feet
        let ten = BubbleDesign.resolved(10)
        let text = BubbleText.content(BubbleContent(scene: .thinking, elapsed: 0.7, duration: 5, verb: "Cogitating"), elements: stageRenderer.elements, design: ten)
        for opening in [BubbleOpening.right, .left] {
            let up = ten.render(runs: text.runs, dots: text.dots, opening: opening, connection: .above, variant: .snug)
            let down = ten.render(runs: text.runs, dots: text.dots, opening: opening, connection: .below, variant: .snug)
            func clear(_ r: Raster, x: Range<Int>, y: Range<Int>) -> Int { y.flatMap { yy in x.map { (xx: $0, yy: yy) } }.filter { !r.isOpaque($0.xx, $0.yy) }.count }
            let w = up.raster.width, near: Range<Int> = opening == .right ? 0..<3 : (w - 3)..<w, far: Range<Int> = opening == .right ? (w - 3)..<w : 0..<3
            let last = up.raster.height - 1
            #expect(clear(up.raster, x: near, y: (last - 2)..<(last + 1)) < clear(up.raster, x: far, y: (last - 2)..<(last + 1)), "style 10 above \(opening): the near corner is the smaller one")
            #expect(clear(down.raster, x: near, y: 0..<3) < clear(down.raster, x: far, y: 0..<3), "style 10 below \(opening): the near corner (the top one) is the smaller one")
            #expect(clear(down.raster, x: near, y: (last - 2)..<(last + 1)) == clear(down.raster, x: far, y: (last - 2)..<(last + 1)), "style 10 below \(opening): the lower corners are alike")
        }
        // the smooth styles: the tail hangs from the box's top and its tip is the topmost painted point
        for style in [14, 15] { for variant in [BubbleVariant.snug, .roomy] { for opening in [BubbleOpening.right, .left] {
            let design = BubbleDesign.resolved(style)
            let t = BubbleText.content(BubbleContent(scene: .thinking, elapsed: 0.7, duration: 5, verb: "Cogitating"), elements: stageRenderer.elements, design: design)
            let down = design.render(runs: t.runs, dots: t.dots, opening: opening, connection: .below, variant: variant, backing: 2)
            let label = "style \(style) \(variant) \(opening)"
            let scale = down.pixelsPerUnit
            let tipX = Int((down.tipX * scale).rounded())
            let boxTop = Int((Double(down.box.y) * scale).rounded())
            #expect(down.tip.y < down.box.y, "\(label): the tip is above the box")
            // a column of the tail's fill from the box's top edge up to near the tip, at the tip's column
            #expect(down.raster.isOpaque(tipX, boxTop - 1), "\(label): the tail does not meet the box's top edge")
            let above = design.render(runs: t.runs, dots: t.dots, opening: opening, connection: .above, variant: variant, backing: 2)
            #expect(above.raster.width == down.raster.width && above.raster.height == down.raster.height, "\(label)")
            // the soft shadow stays under the box: the bottom margin rows of the below picture hold shadow, the top margin row holds none that is not the tail's
            let underBox = ((down.raster.height - 6)..<down.raster.height).contains { down.raster.isOpaque(down.raster.width / 2, $0) }
            #expect(underBox, "\(label): the shadow under the box")
        } } }
    }
}
