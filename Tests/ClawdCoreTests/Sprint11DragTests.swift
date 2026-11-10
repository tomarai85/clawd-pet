import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Sprint 11 (spec 9b item 16, item 5 of the brief): a drag whose press went away with the window (a lock, a hide, a display that sleeps) is
// cancelled: Clawd is back at the home it had before the press, no new home is saved, no landing plays, and idle life resumes.

private func lively(_ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
    var s = SchedulerSettings(); s.motion = .lively; edit(&s); return s
}
private func calm(_ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
    var s = SchedulerSettings(); s.motion = .off; edit(&s); return s
}

extension Sprint11Scenarios {
    static func dragLostToAQuietCondition(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        func resumes(_ rig: SchedulerRig, _ what: String) {
            let n = rig.events.count
            v.check(!rig.frame.dragging && rig.frame.playback?.use != "drag", "\(what): the drag pose is still shown")
            v.check(rig.run(upTo: 900) { rig.eventsSince(n).contains { isMotionStart($0.event) || isWalkStart($0.event) } }, "\(what): idle life never resumed")
        }
        for reason in [QuietReason.screenLocked, .displayAsleep, .notOnActiveSpace] {
            let rig = SchedulerRig(settings: lively(), seed: 5, guards: guards)
            rig.advance(1)
            rig.scheduler.dragStarted()
            v.check(rig.frame.dragging && rig.scheduler.isDragging, "\(reason): the drag did not start")
            rig.scheduler.setQuiet(reason, active: true)
            v.check(!rig.scheduler.isDragging, "\(reason): the drag outlived the quiet condition")
            rig.advance(60)
            rig.scheduler.setQuiet(reason, active: false)
            resumes(rig, "\(reason)")
            if v.done { return v }
        }
        do {   // hide
            let rig = SchedulerRig(settings: lively(), seed: 5, guards: guards)
            rig.advance(1)
            rig.scheduler.dragStarted()
            var hidden = rig.scheduler.settings; hidden.hiddenUntil = -1
            rig.scheduler.update(settings: hidden)
            v.check(!rig.scheduler.isDragging, "hide: the drag outlived the hide")
            hidden.hiddenUntil = 0
            rig.scheduler.update(settings: hidden)
            resumes(rig, "hide")
        }
        return v
    }
}

@Suite("Sprint 11 drag (scheduler)", .serialized)
struct Sprint11DragSchedulerTests {
    private func holds(_ id: String, _ found: Violations, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(found.isEmpty, "\(id): \(found.summary)", sourceLocation: sourceLocation)
    }
    private func control(_ id: String, _ scenario: (SchedulerGuards, Bool) -> Violations, removing rules: [(String, SchedulerGuards)],
                         sourceLocation: SourceLocation = #_sourceLocation) {
        for (name, rule) in rules {
            let found = scenario(.all.subtracting(rule), true)
            negativeControl("\(id) without \(name)", expectationHolds: found.isEmpty, sourceLocation: sourceLocation)
            emit("    first violation: \(found.list.first ?? "none")")
        }
    }

    @Test func Drag_aQuietConditionOrAHideEndsTheDragAndIdleLifeResumes() { holds("drag", Sprint11Scenarios.dragLostToAQuietCondition(.all)) }

    @Test func Drag_aQuietConditionOrAHideEndsTheDragNegativeControl() {
        control("drag", { Sprint11Scenarios.dragLostToAQuietCondition($0, quick: $1) }, removing: [("quietCancelsDrag", .quietCancelsDrag)])
    }

    @Test func Drag_theHostCancelsADragWhoseWindowWentAwayWithoutALanding() {
        let rig = SchedulerRig(settings: lively(), seed: 5)
        rig.advance(1)
        rig.scheduler.dragStarted()
        #expect(rig.scheduler.isDragging)
        let n = rig.events.count
        rig.scheduler.dragCancelled()
        #expect(!rig.scheduler.isDragging); #expect(!rig.frame.dragging); #expect(rig.frame.playback?.use != "drag")
        rig.scheduler.dragEnded(newHome: CGPoint(x: 10, y: 10))          // a release that arrives afterwards finds no drag to end
        #expect(rig.scheduler.geometry.homeOrigin == SchedulerFixture.geometry().homeOrigin, "no new home was taken from a cancelled drag")
        #expect(!rig.eventsSince(n).contains { if case .motionStart(_, "drop") = $0.event { return true } else { return false } }, "and no landing played")
        #expect(rig.run(upTo: 900) { rig.eventsSince(n).contains { isMotionStart($0.event) || isWalkStart($0.event) } }, "idle life resumed")
        rig.scheduler.dragCancelled()            // nothing to cancel: nothing happens
        #expect(!rig.scheduler.isDragging)
    }
}

@Suite("Sprint 11 drag (runtime)", .serialized)
@MainActor
struct Sprint11DragRuntimeTests {
    @Test func Drag_aScreenLockInTheMiddleOfADragCancelsItAndClawdIsBackAtItsHomeWithTheIdleLifeGoingOn() async throws {
        let rig = try HardenRig()
        await rig.spin(0.2)
        let sink = try #require(rig.machine.sink)
        let startPosition = try rig.state.position
        let homeCanvas = try #require(rig.stage.lastFrame).canvas.origin
        let body = try rig.bodyPoint()
        try rig.press(at: body)
        try rig.drag(to: CGPoint(x: body.x + 300, y: body.y + 120), from: body)
        #expect(rig.stage.lastRequest?.frame.dragging == true); #expect(rig.stage.dragOrigin != nil)
        #expect(rig.runtime.currentPosition != startPosition, "the dragged position is held while the press lasts")
        sink.setQuiet(.screenLocked, active: true)                           // the screen locks; the button is released on the lock screen
        #expect(rig.stage.lastFrame == nil)
        #expect(rig.stage.dragOrigin == nil, "the picture no longer follows a pointer that is not pressing")
        #expect(!rig.stage.scheduler.isDragging, "the scheduler's drag is over")
        sink.setQuiet(.screenLocked, active: false)                          // unlock
        let frame = try #require(rig.stage.lastFrame)
        #expect(rig.stage.lastRequest?.frame.dragging == false, "no drag pose after the unlock"); #expect(rig.stage.lastRequest?.frame.playback?.use != "drag")
        #expect(frame.canvas.origin == homeCanvas, "Clawd is back where it stood before the press: \(frame.canvas.origin) against \(homeCanvas)")
        #expect(rig.runtime.currentPosition == startPosition); #expect(try rig.state.position == startPosition, "no new home was saved from a gesture that never finished")
        #expect(!rig.stage.scheduler.isDragging)
        #expect(rig.stage.scheduler.nextWake != nil, "the idle wait runs again")
        // The button-up of that press, should one arrive later, is not a click and not the end of a drag.
        try rig.release(at: body, window: body)
        #expect(rig.lines("TOUCH").isEmpty, "\(rig.log)")
        #expect(rig.lines("MOUSE-IGNORED kind=mouseUp").count == 1 && rig.lines("MOUSE-IGNORED kind=mouseUp")[0].contains("why=untracked"))
        // A new press and drag work as before (the entrance that follows an unlock has to be over: its first frames can be all but empty).
        await rig.spin(until: { rig.stage.lastRequest?.frame.playback == nil }, limit: 30)
        let again = try rig.bodyPoint()
        try rig.press(at: again)
        try rig.drag(to: CGPoint(x: again.x + 200, y: again.y + 50), from: again)
        #expect(rig.stage.lastRequest?.frame.dragging == true)
        try rig.release(at: CGPoint(x: again.x + 200, y: again.y + 50), window: again)
        #expect(rig.stage.lastRequest?.frame.dragging == false); #expect(try rig.state.position != startPosition, "a drag that ends with its release saves the new home")
    }

    /// Codex's finding A on round 1: the lost gesture cleared the scheduler, the runtime and the view but not the controller's own drag, so its
    /// scene stayed DRAG after the unlock: a scene that is not idle arms no blink, and with no tick left nothing looked at the pointer again
    /// while Clawd stood away from home waiting for it.
    @Test func Drag_aLostGestureEndsTheControllersDragTooAndItsNextTickIsScheduled() async throws {
        let rig = try HardenRig()
        await rig.spin(0.2)
        let sink = try #require(rig.machine.sink)
        let controller = rig.runtime.controller
        let body = try rig.bodyPoint()
        try rig.press(at: body)
        try rig.drag(to: CGPoint(x: body.x + 300, y: body.y + 120), from: body)
        #expect(controller.machine.dragging && controller.machine.scene == .drag, "premise: the controller is dragging")
        #expect(!controller.timerIsArmed, "premise: a dragged pet arms no blink")
        sink.setQuiet(.screenLocked, active: true)                           // the screen locks; the button is released on the lock screen
        #expect(!controller.machine.dragging, "the controller's drag ended with the gesture")
        #expect(controller.machine.scene == .idle)
        sink.setQuiet(.screenLocked, active: false)                          // unlock
        #expect(controller.state().scene == .idle, "idle again: the scene is not DRAG")
        #expect(controller.timerIsArmed, "and its next tick (the blink) is scheduled")
        #expect(try rig.state.position == rig.home, "no new home was saved by ending it")
    }

    @Test func Drag_theSchedulerIsToldWhereHomeIsWhenADragThatSawADisplayChangeIsCancelled() async throws {
        let rig = try HardenRig()
        await rig.spin(0.2)
        let sink = try #require(rig.machine.sink)
        let home = rig.stage.scheduler.geometry.homeOrigin
        let body = try rig.bodyPoint()
        try rig.press(at: body)
        try rig.drag(to: CGPoint(x: body.x + 300, y: body.y + 120), from: body)
        // A display change in the middle of the drag: the host re-reads where Clawd lives, and that is where it is dragged to.
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(rig.stage.scheduler.geometry.homeOrigin != home, "premise: the scheduler took the dragged place as home during the drag")
        sink.setQuiet(.screenLocked, active: true)
        sink.setQuiet(.screenLocked, active: false)
        let planning = rig.stage.scheduler.geometry.homeOrigin
        #expect(abs(planning.x - home.x) < 0.5 && abs(planning.y - home.y) < 0.5, "walks are planned from the home Clawd is drawn at: \(planning) against \(home)")
        let frame = try #require(rig.stage.lastFrame)
        #expect(abs(frame.canvas.minX - home.x) < 1 && abs(frame.canvas.minY - home.y) < 1, "and Clawd is drawn there: \(frame.canvas.origin) against \(home)")
    }

    @Test func Drag_aHideInTheMiddleOfADragCancelsItToo() async throws {
        let rig = try HardenRig(control: ["scale": 1, "generation": 0])
        await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
        await rig.spin(0.2)
        let startPosition = try rig.state.position
        let body = try rig.bodyPoint()
        try rig.press(at: body)
        try rig.drag(to: CGPoint(x: body.x + 250, y: body.y + 90), from: body)
        #expect(rig.stage.lastRequest?.frame.dragging == true)
        try rig.write(["hiddenUntil": -1])                                   // clawd-pet hide
        await rig.spin(until: { rig.stage.lastFrame == nil })
        #expect(rig.stage.lastFrame == nil); #expect(!rig.stage.scheduler.isDragging); #expect(rig.stage.dragOrigin == nil)
        #expect(!rig.runtime.controller.machine.dragging, "the controller's drag is over too")
        try rig.write(["hiddenUntil": 0])                                    // clawd-pet show
        await rig.spin(until: { rig.stage.lastFrame != nil })
        #expect(rig.stage.lastRequest?.frame.dragging == false)
        #expect(rig.runtime.currentPosition == startPosition); #expect(try rig.state.position == startPosition)
    }
}
