import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Spec section 6: every exam path closes the panel and hard-stops the child.

@Suite("Chat exam", .serialized)
@MainActor
struct ChatExamSuite {
    func openRig() throws -> ChatRuntimeRig {
        let r = try ChatRuntimeRig()
        try r.doubleClick()
        #expect(r.panel != nil)
        return r
    }

    @Test func ChatExam_theLaunchNotificationClosesThePanelAndHardStopsTheChild() throws {
        let r = try openRig()
        _ = r.session.send("run")
        r.rig.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.Respondus.LockDownBrowser", name: "LockDown Browser", pid: 77)
        #expect(r.panel == nil && r.lines("CHAT close").last?.hasPrefix("CHAT close reason=exam") == true, "\(r.lines("CHAT"))")
        #expect(r.session.stops == [.exam])
        #expect(r.session.turn == .none, "the turn ended (INTERRUPTED)")
        #expect(r.rig.runtime.controller.machine.chatTurnRunning == false)
    }

    @Test func ChatExam_aWakeRecheckThatFindsTheBrowserStopsTheChatToo() throws {
        let r = try openRig()
        r.machine.examRunning = true
        r.machine.sink?.setQuiet(.systemAsleep, active: true)
        r.machine.sink?.setQuiet(.systemAsleep, active: false)
        #expect(r.panel == nil && r.session.stops == [.exam], "\(r.lines("CHAT")) \(r.lines("EXAM"))")
    }

    @Test func ChatExam_startupStandDownRefusesThePanelAndCreatesNoChild() throws {
        let r = try ChatRuntimeRig(prepare: { $0.examRunning = true })
        // Clawd is not on screen during the stand-down, so there is nothing to double-click; the controller refuses a toggle all the same.
        r.rig.runtime.chatController.toggle(eventTime: 1)
        #expect(r.panel == nil && r.session.sent.isEmpty && r.session.stops.isEmpty)
        #expect(r.lines("CHAT open").isEmpty && r.lines("CHAT refuse").first?.hasSuffix("reason=exam") == true, Comment(rawValue: "\(r.lines("CHAT"))"))
    }

    @Test func ChatExam_noOpenAndNoSendWhileTheStandDownIsActiveOrTheBrowserRuns() {
        let r = ControllerRig()
        r.host.examActive = true
        r.open()
        #expect(r.controller.livePanel == nil)
        r.host.examActive = false
        r.open()
        r.type("hello")
        r.host.examRunning = true
        r.pressEnter()
        #expect(r.session.sent.isEmpty && r.view.inputText == "hello" && r.view.statusText.contains("exam"), "the spawn site asks again: \(r.view.statusText)")
        r.host.examRunning = false; r.host.examActive = true
        r.pressEnter()
        #expect(r.session.sent.isEmpty)
    }

    @Test func ChatExam_theStopHappensOnceAndAgainForTheNextStandDown() throws {
        let r = try openRig()
        r.rig.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.Respondus.LockDownBrowser", name: "LockDown Browser", pid: 1)
        r.rig.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.Respondus.LockDownBrowser", name: "LockDown Browser", pid: 2)
        #expect(r.session.stops == [.exam])
    }
}
