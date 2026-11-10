import Testing
import Foundation
import CoreGraphics
import ClawdCore
@testable import ClawdRendering

/// Amendment D-2 E: the placement memory. A placement changes by one of three kinds (a safety change when the shown one stops fitting, a return after
/// 0.5 s of continuous fit, a directed change on a side setting or a display, size or style change), and the tests count them over scripted sequences
/// of presented frames, measured on `StageRequest.now`.
@Suite("BubbleStabilityTests", .serialized)
struct BubbleStabilityTests {
    private let dt = 1.0 / 30
    private let eps = 1e-6
    /// Clawd stands at (`homeX`, `homeY`) at size 1: his head's centre is 24 pt right of homeX. Below fits from homeY 122 up; at 100 it does not.
    private let fits = 300.0, unfit = 100.0

    private func frames(_ seconds: Double, from start: Double = 0) -> [Double] { stride(from: start, to: start + seconds - 1e-9, by: dt).map { $0 } }

    // MARK: the opening

    /// Walking back and forth over the middle of the display faster than twice a second does not flip the opening: the shown placement keeps its
    /// opening while it still fits, and a better one is taken only after it has fitted for 0.5 s.
    @Test func BubbleStability_oscillationAroundTheMiddleHoldsTheOpening() throws {
        var player = SidePlayer()
        for t in frames(5) {
            _ = try player.present(sideRequest(style: 1, homeX: 696 + 10 * sin(2 * Double.pi * t / 0.4), homeY: fits, now: t))
        }
        #expect(player.steps.allSatisfy { $0.plan != nil })
        #expect(player.changes.isEmpty, "the opening flipped: \(player.changes.map { ($0.t, $0.change as Any) })")
        let openings = Set(player.steps.compactMap { $0.plan?.opening })
        #expect(openings.count == 1, "\(openings)")
    }

    /// A monotonic walk across the middle leaves a centered bubble as it is (amendment D-2a): at 4606804 the opening flipped once here, half a second
    /// after the crossing, because a corner-tip picture hangs to one side; a centered one has nothing to gain from the other opening. The return after
    /// 0.5 s is still tested for the placements it governs (`repeatedFitUnfitAtAnEdgeReturnsOnlyAfterHalfASecond` and the menu tests).
    @Test func BubbleStability_walkAcrossTheMiddleDoesNotFlipACenteredBubble() throws {
        var player = SidePlayer()
        var crossing: Double?
        for t in frames(6) {
            let homeX = 500 + 60 * t
            if crossing == nil, homeX + 24 >= 720 { crossing = t }
            _ = try player.present(sideRequest(style: 1, homeX: homeX, homeY: fits, now: t))
        }
        #expect(crossing != nil)
        #expect(player.changes.isEmpty, "\(player.changes.map { ($0.t, $0.change as Any) })")
        #expect(Set(player.steps.compactMap { $0.plan?.opening }) == [.right], "the opening it started with")
    }

    // MARK: fit and unfit at an edge

    /// Below fits for 0.2 s, stops fitting for 0.2 s, over and over: the bubble that fell back above never returns during it; after a steady 0.6 s of
    /// fit it returns once, 0.5 s after the fit began.
    @Test func BubbleStability_repeatedFitUnfitAtAnEdgeReturnsOnlyAfterHalfASecond() throws {
        var player = SidePlayer()
        var t = 0.0
        for _ in 0..<12 { _ = try player.present(sideRequest(style: 1, homeX: 576, homeY: unfit, now: t)); t += dt }
        #expect(player.steps.last?.plan?.side == .above)
        for round in 0..<10 {
            for _ in 0..<6 { _ = try player.present(sideRequest(style: 1, homeX: 576, homeY: fits, now: t)); t += dt }
            for _ in 0..<6 { _ = try player.present(sideRequest(style: 1, homeX: 576, homeY: unfit, now: t)); t += dt }
            _ = round
        }
        #expect(player.changes.isEmpty, "returned during the 0.2 s fits: \(player.changes.map { ($0.t, $0.change as Any) })")
        let steady = t
        for _ in 0..<30 { _ = try player.present(sideRequest(style: 1, homeX: 576, homeY: fits, now: t)); t += dt }
        #expect(player.changes.count == 1 && player.changes[0].change == .returned && player.changes[0].plan?.side == .below)
        let at = player.changes[0].t
        #expect(at >= steady + 0.5 - eps && at <= steady + 0.5 + 2 * dt, "the fit began at \(steady), the return came at \(at)")
    }

    /// The shown placement stops fitting at frame 10: it changes at that frame, not later, and as a safety change.
    @Test func BubbleStability_aRememberedPlacementThatStopsFittingChangesAtOnce() throws {
        var player = SidePlayer()
        for k in 0..<10 { _ = try player.present(sideRequest(style: 1, homeX: 576, homeY: fits, now: Double(k) * dt)) }
        #expect(player.changes.isEmpty && player.steps.allSatisfy { $0.plan?.side == .below })
        _ = try player.present(sideRequest(style: 1, homeX: 576, homeY: unfit, now: 10 * dt))
        let last = try #require(player.steps.last)
        #expect(last.change == .safety && last.plan?.side == .above, "\(String(describing: last.change)) \(String(describing: last.plan?.side))")
        for k in 11..<20 { _ = try player.present(sideRequest(style: 1, homeX: 576, homeY: unfit, now: Double(k) * dt)) }
        #expect(player.changes.count == 1)
    }

    // MARK: the menu

    /// The menu opens over the below picture (a safety change, usually to another side) and closes again (a return, 0.5 s later): one change per event.
    @Test func BubbleStability_menuOpenAndCloseChangeAtMostOncePerEvent() throws {
        let free = try #require(try stageRenderer.layout(sideRequest(style: 1, homeX: 576, homeY: fits))?.bubble).rect
        let menu = CGRect(x: free.minX + 6, y: free.minY - 20, width: 60, height: free.height + 30)
        var player = SidePlayer()
        for k in 0..<200 {
            let t = Double(k) * dt, open = k >= 20 && k < 80
            _ = try player.present(sideRequest(style: 1, homeX: 576, homeY: fits, now: t, menu: open ? menu : nil))
        }
        let changes = player.changes
        #expect(changes.count == 2, "\(changes.map { ($0.t, $0.change as Any) })")
        #expect(changes[0].change == .safety && abs(changes[0].t - 20 * dt) < eps && changes[0].plan?.side != .below)
        #expect(changes[1].change == .returned && changes[1].plan?.side == .below)
        #expect(changes[1].t >= 80 * dt + 0.5 - eps && changes[1].t <= 80 * dt + 0.5 + 2 * dt, "closed at \(80 * dt), returned at \(changes[1].t)")
        for step in player.steps { if let plan = step.plan { #expect(!plan.rect.intersects(step.t >= 20 * dt && step.t < 80 * dt ? menu : .null)) } }
    }

    /// No new frame arrives after the menu closes (a still bubble): the wake that `nextChange` returns is what lays the bubble out again at the expiry of
    /// the return delay, and the bubble returns then, not before.
    @Test func BubbleStability_aMenuCloseOnAStaticFallbackBubbleReturnsAfterHalfASecondByWake() throws {
        let free = try #require(try stageRenderer.layout(sideRequest(style: 1, scene: .error, homeX: 576, homeY: fits))?.bubble).rect
        let menu = CGRect(x: free.minX + 6, y: free.minY - 20, width: 60, height: free.height + 30)
        // frame 0: the menu is open and the bubble is above
        let open = sideRequest(style: 1, scene: .error, homeX: 576, homeY: fits, now: 0, menu: menu, elapsed: 0.2)
        let first = try #require(try stageRenderer.compose(open))
        #expect(first.bubble?.plan.side != .below)
        // the menu closes at t = 1: one frame, the target fits from now on
        var closed = sideRequest(style: 1, scene: .error, homeX: 576, homeY: fits, now: 1, elapsed: 0.2); closed.bubbleMemory = first.layout.memory
        let second = try #require(try stageRenderer.compose(closed))
        #expect(second.bubble?.plan.side == first.bubble?.plan.side, "no return yet")
        let wake = try #require(stageRenderer.nextChange(closed, composed: second), "a pending return arms a wake")
        #expect(abs(wake - 0.5) < 1e-6, "the wake is the time to the expiry: \(wake)")
        // the runtime commits the second frame; the wake fires: the layout at the expiry returns
        var early = sideRequest(style: 1, scene: .error, homeX: 576, homeY: fits, now: 1 + wake - 0.01, elapsed: 0.2); early.bubbleMemory = second.layout.memory
        #expect(try stageRenderer.layout(early)?.bubble?.plan.side == first.bubble?.plan.side, "not before 0.5 s")
        var due = sideRequest(style: 1, scene: .error, homeX: 576, homeY: fits, now: 1 + wake, elapsed: 0.2); due.bubbleMemory = second.layout.memory
        let third = try #require(try stageRenderer.layout(due))
        #expect(third.bubble?.plan.side == .below && third.placementChange == .returned, "\(String(describing: third.bubble?.plan.side))")
        // and once it has returned nothing is pending: no wake of the bubble's own
        #expect(third.memory?.pendingSince == nil)
    }

    /// During the SENT fade a still-safe fallback stays (no return, no wake); a placement that stops fitting is still replaced at once.
    @Test func BubbleStability_sentKeepsAStillSafeFallbackWithoutAReturn() throws {
        var player = SidePlayer()
        for k in 0..<5 { _ = try player.present(sideRequest(style: 1, scene: .sent, homeX: 576, homeY: unfit, now: Double(k) * dt, past: "Cooked", elapsed: 1.0)) }
        #expect(player.steps.last?.plan?.side == .above)
        for k in 5..<90 { _ = try player.present(sideRequest(style: 1, scene: .sent, homeX: 576, homeY: fits, now: Double(k) * dt, past: "Cooked", elapsed: 1.0)) }
        #expect(player.changes.isEmpty && player.steps.last?.plan?.side == .above, "SENT returned: \(player.changes.map { ($0.t, $0.change as Any) })")
        #expect(player.memory?.pendingSince == nil, "no pending return in SENT")
        // E2 still applies
        _ = try player.present(sideRequest(style: 1, scene: .sent, homeX: 576, homeY: Screens.visible.maxY - 40, now: 90 * dt, past: "Cooked", elapsed: 1.0))
        #expect(player.steps.last?.plan?.side != .above || player.steps.last?.change == .safety)
    }

    // MARK: directed changes

    private func populated(side: BubbleSide = .below, style: Int = 1, scale: Double = 1, display: CGRect = Screens.display) throws -> SidePlayer {
        var player = SidePlayer()
        // a fallback is shown (below does not fit) and, 0.1 s later, the better placement fits and is pending
        for k in 0..<5 { _ = try player.present(sideRequest(style: style, side: side, homeX: 576, homeY: unfit, scale: scale, now: Double(k) * dt, display: display)) }
        #expect(player.steps.last?.plan?.side == .above)
        return player
    }

    @Test func BubbleStability_aSettingChangeResetsTheMemory() throws {
        var player = try populated()
        _ = try player.present(sideRequest(style: 1, side: .below, homeX: 576, homeY: fits, now: 5 * dt))
        #expect(player.memory?.pendingSince != nil, "the better placement is pending")
        _ = try player.present(sideRequest(style: 1, side: .left, homeX: 576, homeY: fits, now: 6 * dt))
        let last = try #require(player.steps.last)
        #expect(last.plan?.side == .left && last.change == .directed, "\(String(describing: last.plan?.side)) \(String(describing: last.change))")
        #expect(player.memory?.context.side == .left && player.memory?.pendingSince == nil)
    }

    @Test func BubbleStability_twoSideChangesWithinHalfASecondBothApplyAtOnce() throws {
        var player = SidePlayer()
        for k in 0..<3 { _ = try player.present(sideRequest(style: 1, side: .below, homeX: 640, homeY: fits, now: Double(k) * dt)) }
        _ = try player.present(sideRequest(style: 1, side: .right, homeX: 640, homeY: fits, now: 3 * dt))
        #expect(player.steps.last?.plan?.side == .right && player.steps.last?.change == .directed)
        _ = try player.present(sideRequest(style: 1, side: .above, homeX: 640, homeY: fits, now: 6 * dt))
        #expect(player.steps.last?.plan?.side == .above && player.steps.last?.change == .directed, "the second change inside 0.5 s of the first")
        _ = try player.present(sideRequest(style: 1, side: .left, homeX: 640, homeY: fits, now: 7 * dt))
        #expect(player.steps.last?.plan?.side == .left && player.steps.last?.change == .directed)
    }

    @Test func BubbleStability_sizeAndStyleChangesResetAPopulatedMemory() throws {
        var player = try populated()
        // the size changes (the same place now has room for below): at once
        _ = try player.present(sideRequest(style: 1, homeX: 576, homeY: fits, scale: 2, now: 5 * dt))
        #expect(player.steps.last?.plan?.side == .below && player.steps.last?.change == .directed && player.memory?.context.scale == 2)
        var other = try populated()
        _ = try other.present(sideRequest(style: 13, homeX: 576, homeY: fits, now: 5 * dt))
        #expect(other.steps.last?.plan?.side == .below && other.steps.last?.change == .directed && other.memory?.context.style == 13)
    }

    @Test func BubbleStability_aCrossDisplayDragWithAPopulatedMemory() throws {
        var player = try populated()
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080), secondVisible = CGRect(x: 1440, y: 0, width: 1920, height: 1050)
        _ = try player.present(sideRequest(style: 1, homeX: 1440 + 600, homeY: 300, now: 5 * dt, display: second, visible: secondVisible))
        #expect(player.steps.last?.plan?.side == .below && player.steps.last?.change == .directed, "\(String(describing: player.steps.last?.change))")
        #expect(player.memory?.context.display == second && player.memory?.pendingSince == nil)
    }

    // MARK: the stateless answer, forms

    @Test func BubbleStability_emptyMemoryEqualsTheStatelessFirstCandidate() throws {
        for style in [1, 4, 10, 13, 15] { for side in BubbleSide.allCases {
            for (x, y) in [(400.0, 300.0), (20.0, 120.0), (1400.0, 700.0), (700.0, 105.0)] {
                let f = SideFixture(headX: x, headY: y)
                let stateless = SideRun.plan(style, f, side: side)
                let decided = SideRun.decide(style, f, side: side, memory: nil, now: 12.5)
                #expect(decided?.plan == stateless, "style \(style) \(side) at (\(x), \(y))")
                if decided != nil { #expect(decided?.change == .initial && decided?.memory.pendingSince == nil && decided?.memory.shown == stateless?.identity) }
            }
        } }
    }

    /// A slid picture whose room appears is a different placement (the form is part of its identity): the normal form replaces it after the return
    /// delay, though the rectangle is the same.
    @Test func BubbleStability_aKeptInOrSlidFormChangeIsAPlacementChange() throws {
        let style = 1
        let (narrow, _) = SideFixture.narrow(style: style, headX: 20)       // the centered picture would overhang the left edge: it slides in
        let (_, pictureWidth) = SideFixture.narrow(style: style, headX: 20)
        var near = narrow; near.headX = (pictureWidth / 2).rounded(.up) + 4  // the centered picture just fits (the frame is 10 pt wider than it), and so does the slid one
        var memory: BubbleMemory?
        var seen: [(Double, PlacementChangeKind?, PlacementForm, CGRect)] = []
        for k in 0..<60 {
            let t = Double(k) * dt, f = k < 5 ? narrow : near
            let d = try #require(SideRun.decide(style, f, side: .below, memory: memory, now: t), "frame \(k)")
            memory = d.memory
            seen.append((t, d.change, d.plan.form, d.plan.rect))
        }
        #expect(seen[0].2 == .slid && seen[4].2 == .slid)
        #expect(seen[5].1 == nil && seen[5].2 == .slid, "the slid form still fits: it stays")
        let changed = seen.dropFirst().filter { $0.1 != nil }
        #expect(changed.count == 1 && changed[0].1 == .returned && changed[0].2 == .normal, "\(changed)")
        #expect(abs(changed[0].0 - (5 * dt + 0.5)) <= 2 * dt)
        #expect(changed[0].3 == seen[5].3, "the same picture in another form")
    }
}
