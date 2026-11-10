import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// F1.3 / section 6: lock, sleep, Space, hide and Aqua-not-running close the panel (reason hidden) and leave the child running.

@Suite("Chat quiet", .serialized)
@MainActor
struct ChatQuietSuite {
    private func check(_ reason: QuietReason) throws {
        let r = try ChatRuntimeRig()
        try r.doubleClick()
        #expect(r.panel != nil)
        _ = r.session.send("keep going")
        r.machine.sink?.setQuiet(reason, active: true)
        #expect(r.panel == nil, "\(reason): closed")
        #expect(r.lines("CHAT close").last?.hasPrefix("CHAT close reason=hidden gen=1") == true, "\(reason): \(r.lines("CHAT"))")
        #expect(r.session.stops.isEmpty && r.session.turn == .running, "\(reason): the child keeps running")
        #expect(r.rig.runtime.controller.machine.baseScene == .thinking, "the scene still follows the turn")
        #expect(!r.rig.stage.scheduler.chatOpen)
    }

    @Test func ChatQuiet_lockClosesThePanelAndKeepsTheChild() throws { try check(.screenLocked) }
    @Test func ChatQuiet_displaySleepClosesThePanelAndKeepsTheChild() throws { try check(.displayAsleep) }
    @Test func ChatQuiet_anotherSpaceClosesThePanelAndKeepsTheChild() throws { try check(.notOnActiveSpace) }
    @Test func ChatQuiet_aquaNotRunningClosesThePanelAndKeepsTheChild() throws { try check(.aquaNotRunning) }
    @Test func ChatQuiet_systemSleepClosesThePanelAndKeepsTheChild() throws { try check(.systemAsleep) }

    @Test func ChatQuiet_theHideSettingClosesThePanelAndNothingReopensIt() throws {
        let r = try ChatRuntimeRig()
        try r.doubleClick()
        r.machine.sink?.setQuiet(.screenLocked, active: true)
        r.machine.sink?.setQuiet(.screenLocked, active: false)
        #expect(r.panel == nil && r.lines("CHAT open").count == 1, "nothing re-opens the panel except a new double-click")
    }

    @Test func ChatQuiet_aDragClosesThePanelAndTheChildContinues() throws {
        let r = try ChatRuntimeRig()
        try r.doubleClick()
        _ = r.session.send("go")
        let body = try r.rig.points().body
        r.rig.machine.pointer = body
        r.rig.view.mouseDown(with: try r.rig.event(.leftMouseDown, at: r.rig.window(body)))
        r.rig.machine.pointer = CGPoint(x: body.x + 40, y: body.y)
        r.rig.view.mouseDragged(with: try r.rig.event(.leftMouseDragged, at: r.rig.window(body)))
        #expect(r.panel == nil && r.lines("CHAT close").last?.hasPrefix("CHAT close reason=drag") == true, "\(r.lines("CHAT"))")
        #expect(r.session.stops.isEmpty)
        r.rig.view.mouseUp(with: try r.rig.event(.leftMouseUp, at: r.rig.window(body)))
    }
}
