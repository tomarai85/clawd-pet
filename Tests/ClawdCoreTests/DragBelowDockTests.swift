import Testing
import Foundation
import AppKit
import CoreGraphics
@testable import ClawdCore
import ClawdRendering
import ClawdDesktop

// Clawd can be dragged down over the Dock, to the display's bottom edge. Motions play there in place; walks and the bubble never use the Dock.

private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let docked = CGRect(x: 0, y: 80, width: 1440, height: 790)

@Suite("DragBelowDock", .serialized)
struct DragBelowDock {
    @Test func DragBelowDock_dragAreaRunsFromTheDisplayBottomToTheTopOfTheVisibleFrame() {
        #expect(Placement.dragArea(display: display, visible: docked) == CGRect(x: 0, y: 0, width: 1440, height: 870))
        let side = CGRect(x: 60, y: 0, width: 1380, height: 870)
        #expect(Placement.dragArea(display: display, visible: side) == CGRect(x: 0, y: 0, width: 1440, height: 870), "a side Dock is inside the area")
    }

    @Test func DragBelowDock_aClampBelowTheDockLandsAtTheDisplayBottomAndAboveTheMenuBarStaysOut() {
        let size = CGSize(width: 48, height: 48), area = Placement.dragArea(display: display, visible: docked)
        #expect(Placement.clamp(CGPoint(x: 300, y: 20), visible: area, size: size) == CGPoint(x: 300, y: 20))
        #expect(Placement.clamp(CGPoint(x: 300, y: -50), visible: area, size: size) == CGPoint(x: 300, y: 0))
        #expect(Placement.clamp(CGPoint(x: 300, y: 890), visible: area, size: size) == CGPoint(x: 300, y: 822))
    }

    @Test func DragBelowDock_aSavedPositionBelowTheDockRestoresThere() {
        let size = CGSize(width: 48, height: 48), area = Placement.dragArea(display: display, visible: docked)
        let saved = Placement.fractions(origin: CGPoint(x: 300, y: 12), size: size, display: display, uuid: "D", scale: 1)
        #expect(Placement.origin(position: saved, display: display, visible: area, size: size) == CGPoint(x: 300, y: 12))
    }

    @Test func DragBelowDock_aDockHiddenDisplayKeepsItsOldPositions() {
        let hidden = CGRect(x: 0, y: 0, width: 1440, height: 870), size = CGSize(width: 48, height: 48)
        #expect(Placement.dragArea(display: display, visible: hidden) == hidden)
        #expect(Placement.clamp(CGPoint(x: 300, y: -50), visible: Placement.dragArea(display: display, visible: hidden), size: size)
                == Placement.clamp(CGPoint(x: 300, y: -50), visible: hidden, size: size))
    }

    @Test func DragBelowDock_anInPlaceIdleMotionIsPickedWhereClawdWasDroppedOverTheDock() {
        let rig = SchedulerRig(geometry: SchedulerFixture.geometry(homeX: 300, homeY: 10))
        #expect(rig.scheduler.planIdleMotion() != nil)
    }

    @Test func DragBelowDock_aMotionWhoseStageLeavesTheDragAreaIsStillRefused() {
        let rig = SchedulerRig(geometry: SchedulerFixture.geometry(homeX: 300, homeY: 10))
        let tall = rig.scheduler.catalog.motions.first { $0.id == "A12-heart" }!
        #expect(rig.scheduler.eligible(tall, look: "plain", pointerCheck: false))
        let top = SchedulerRig(geometry: SchedulerFixture.geometry(homeX: 300, homeY: 850))
        #expect(!top.scheduler.eligible(tall, look: "plain", pointerCheck: false))
    }

    @Test func DragBelowDock_noWalkStartsFromAHomeOverTheDock() {
        var settings = SchedulerSettings(); settings.motion = .lively
        let over = SchedulerRig(settings: settings, geometry: SchedulerFixture.geometry(homeX: 300, homeY: 10))
        #expect(over.scheduler.planWalk(at: over.now) == nil)
        let edge = SchedulerRig(settings: settings, geometry: SchedulerFixture.geometry(homeX: 300, homeY: 79))
        #expect(edge.scheduler.planWalk(at: edge.now) == nil, "one point into the Dock is over it")
    }

    @Test func DragBelowDock_walksFromAHomeAboveTheDockAreUnchanged() throws {
        var settings = SchedulerSettings(); settings.motion = .lively
        let rig = SchedulerRig(settings: settings, geometry: SchedulerFixture.geometry(homeX: 300, homeY: 100))
        let run = try #require(rig.scheduler.planWalk(at: rig.now))
        #expect(run.homeX == 300 && run.targetX >= 0 && run.targetX + 48 <= 1440)
        // A Dock on the left edge (visible x from 60) still bounds every walk: the walk range is the visible frame, not the drag area.
        let side = PetGeometry(scale: 1, homeOrigin: CGPoint(x: 100, y: 100), displayFrame: display, visibleFrame: CGRect(x: 60, y: 0, width: 1380, height: 870))
        var planned = 0
        for seed in UInt64(1)...40 {
            let rig = SchedulerRig(settings: settings, geometry: side, seed: seed)
            guard let run = rig.scheduler.planWalk(at: rig.now) else { continue }
            planned += 1
            #expect(run.targetX >= 60, "seed \(seed): target \(run.targetX) is inside the side Dock")
        }
        #expect(planned == 40)
    }

    @Test func DragBelowDock_theBubbleOfAClawdOverTheDockLiesInsideTheVisibleFrame() throws {
        for homeY in [0.0, 30, 79] { for scale in [1.0, 2.0] { for side in [BubbleSide.above, .below] {
            let geometry = SchedulerFixture.geometry(scale: scale, homeX: 700, homeY: homeY)
            let bubble = BubbleState(style: 0, scene: .thinking)
            let request = StageRequest(frame: Frames.rest(bubble: bubble, scene: .thinking), now: 0, geometry: geometry, pixelScale: 1,
                                       content: BubbleContent(scene: .thinking, elapsed: 0.25, duration: 5, verb: "Clauding", pastVerb: "Cooked"), bubbleSide: side)
            let layout = try #require(try stageRenderer.layout(request))
            #expect(layout.panel.contains(layout.clawdRect), "home y \(homeY): Clawd's whole picture is in his window, \(layout.clawdRect) against \(layout.panel)")
            guard let rect = layout.bubble?.rect else { continue }
            let visible = geometry.visibleFrame, eps = 0.51
            #expect(rect.minX >= visible.minX - eps && rect.maxX <= visible.maxX + eps && rect.minY >= visible.minY - eps && rect.maxY <= visible.maxY + eps,
                    "home y \(homeY) size \(scale) \(side): \(rect) outside \(visible)")
        } } }
    }

    @MainActor @Test func DragBelowDock_aDragReleasedBelowTheDockLandsAtTheDisplayBottomAndSurvivesARestart() throws {
        let rig = try RuntimeRig()
        let body = try rig.points().body
        rig.machine.pointer = body
        rig.view.mouseDown(with: try rig.event(.leftMouseDown, at: rig.window(body)))
        rig.machine.pointer = CGPoint(x: body.x, y: 0)
        rig.view.mouseDragged(with: try rig.event(.leftMouseDragged, at: rig.window(body)))
        rig.view.mouseUp(with: try rig.event(.leftMouseUp, at: rig.window(body)))
        let saved = try rig.state.position
        #expect(saved.feetFrac == 0, "the display's bottom edge, not the Dock's top (40 pt)")
        let home = try #require(rig.stage.lastRequest?.geometry.homeOrigin)
        #expect(home.y == 0)
        let again = try RuntimeRig(state: AgentState(position: SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.01, scale: 1)))
        _ = try again.points()
        let restored = try #require(again.stage.lastRequest?.geometry.homeOrigin)
        #expect(abs(restored.y - 10.8) < 0.01, "a position over the Dock is restored where it was saved: \(restored.y)")
    }

    @MainActor @Test func DragBelowDock_aHomeOverTheDockPutsHisWindowsAboveTheDock() throws {
        let rig = try RuntimeRig(state: AgentState(position: SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.01, scale: 1)))
        _ = try rig.points()
        #expect(PanelContract.level.rawValue == Int(CGWindowLevelForKey(.dockWindow)) + 1)
        #expect(rig.panel.level == PanelContract.level && rig.bodyPanel.level == PanelContract.level)
        #expect(rig.runtime.panels.violations() == [])
    }

    /// Since 2026-11-09 the level no longer drops to `.floating` above the Dock: there other apps' floating windows went over him.
    @MainActor @Test func DragBelowDock_aHomeAboveTheDockHasTheSameLevel() throws {
        let rig = try RuntimeRig()
        _ = try rig.points()
        #expect(rig.panel.level == PanelContract.level && rig.bodyPanel.level == PanelContract.level)
        #expect(rig.runtime.panels.violations() == [])
    }

    @MainActor @Test func DragBelowDock_theLevelStaysThroughADragOverTheDockAndBackUp() throws {
        let rig = try RuntimeRig(virtual: true)
        let body = try rig.points().body
        func drag(to y: Double, from at: CGPoint) throws {
            rig.machine.pointer = at
            rig.view.mouseDown(with: try rig.event(.leftMouseDown, at: rig.window(at)))
            rig.machine.pointer = CGPoint(x: at.x, y: y)
            rig.view.mouseDragged(with: try rig.event(.leftMouseDragged, at: rig.window(at)))
        }
        func atThePetLevel() -> Bool { rig.panel.level == PanelContract.level && rig.bodyPanel.level == PanelContract.level }
        try drag(to: 0, from: body)
        #expect(atThePetLevel(), "carried over the Dock")
        rig.view.mouseUp(with: try rig.event(.leftMouseUp, at: rig.window(body)))
        #expect(atThePetLevel(), "released over the Dock")
        rig.advance(5)         // the landing is over and he stands at rest
        let low = try rig.points().body
        try drag(to: 600, from: low)
        #expect(atThePetLevel(), "carried back up")
        rig.view.mouseUp(with: try rig.event(.leftMouseUp, at: rig.window(low)))
        #expect(atThePetLevel(), "released above the Dock")
        #expect(rig.runtime.panels.violations() == [])
    }
}
