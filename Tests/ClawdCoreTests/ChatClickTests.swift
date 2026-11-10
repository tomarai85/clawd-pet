import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// F1.1: the double-click toggle, its refusals and the menu interplay, through the real input path.

@Suite("Chat click", .serialized)
@MainActor
struct ChatClickSuite {
    @Test func ChatClick_aDoubleClickOpensTheChatOnceAndTheNextOneClosesIt() throws {
        let r = try ChatRuntimeRig()
        try r.doubleClick()
        #expect(r.lines("CHAT open").count == 1 && r.lines("CHAT open")[0].hasSuffix("gen=1"), "\(r.lines("CHAT"))")
        #expect(r.panel != nil && r.runtime.chatPanelIsOpen)
        #expect(r.machine.chatKeys.count == 1, "made key once, by the open call")
        try r.doubleClick()
        #expect(r.lines("CHAT close").count == 1 && r.lines("CHAT close")[0].hasPrefix("CHAT close reason=toggle gen=1 draft=0"), "\(r.lines("CHAT close"))")
        #expect(r.panel == nil)
        try r.doubleClick()
        #expect(r.lines("CHAT open").last?.hasSuffix("gen=2") == true, "a new opening has the next number")
    }

    @Test func ChatClick_clickCountThreeFourAndFiveNeverToggle() throws {
        let r = try ChatRuntimeRig()
        for n in 3...5 { try r.click(count: n) }
        #expect(r.lines("CHAT").isEmpty && r.panel == nil, "\(r.lines("CHAT"))")
        try r.doubleClick()
        #expect(r.panel != nil)
        for n in 3...5 { try r.click(count: n) }
        #expect(r.lines("CHAT close").isEmpty && r.panel != nil, "one series toggles at most once: \(r.lines("CHAT"))")
    }

    @Test func ChatClick_theClickCountTwoEventIsStillASchedulerClick() throws {
        let r = try ChatRuntimeRig()
        var clicks = 0
        let original = r.rig.stage.scheduler.onEvent
        r.rig.stage.scheduler.onEvent = { at, event in
            switch event { case .touch, .multiTouch, .clickIgnored: clicks += 1; default: break }
            original?(at, event)
        }
        try r.doubleClick()
        #expect(clicks == 2, "both clicks of the series reached the scheduler")
        #expect(r.panel != nil)
    }

    @Test func ChatClick_withTheMenuOpenAClickCountTwoClosesTheMenuAndDoesNotToggle() throws {
        let r = try ChatRuntimeRig()
        let body = try r.rig.points().body
        r.rig.view.rightMouseDown(with: try r.rig.event(.rightMouseDown, at: r.rig.window(body)))
        #expect(r.rig.runtime.panels.menu != nil, "the menu opened")
        try r.rig.click(at: try r.rig.points().body, clicks: 2)
        #expect(r.lines("MENU close").count == 1 && r.rig.runtime.panels.menu == nil)
        #expect(r.lines("CHAT").isEmpty && r.panel == nil, "no toggle: \(r.lines("CHAT"))")
    }

    @Test func ChatClick_aSeriesWhoseFirstPressClosedTheMenuDoesNotToggle() throws {
        let r = try ChatRuntimeRig()
        let body = try r.rig.points().body
        r.rig.view.rightMouseDown(with: try r.rig.event(.rightMouseDown, at: r.rig.window(body)))
        #expect(r.rig.runtime.panels.menu != nil)
        // The first press of the series closes the open menu (R-BODY); its second click arrives with the menu already closed.
        try r.rig.click(at: try r.rig.points().body, clicks: 1)
        #expect(r.rig.runtime.panels.menu == nil)
        try r.rig.click(at: try r.rig.points().body, clicks: 2)
        #expect(r.lines("CHAT").isEmpty, "\(r.lines("CHAT"))")
        // The next series is a fresh one.
        try r.doubleClick()
        #expect(r.panel != nil)
    }

    @Test func ChatClick_aMenuThatWillOpenClosesTheChatFirstAndABusyMenuLeavesItOpen() throws {
        let r = try ChatRuntimeRig()
        try r.doubleClick()
        #expect(r.panel != nil)
        // A dictation does not close the chat, and while it plays the menu is refused (busy): the chat stays open.
        r.rig.runtime.controller.receive(line: startLine(SystemPetClock()).trimmingCharacters(in: .newlines))
        #expect(r.panel != nil, "a dictation does not close the chat")
        let busy = try r.rig.points().body
        r.rig.view.rightMouseDown(with: try r.rig.event(.rightMouseDown, at: r.rig.window(busy)))
        #expect(r.rig.runtime.panels.menu == nil && r.panel != nil, "the menu was refused and the chat stays: \(r.lines("CHAT"))")
        r.rig.runtime.controller.machine.reset()
        #expect(r.rig.stage.scheduler.sceneActive == false)
        let body = try r.rig.points().body
        r.rig.view.rightMouseDown(with: try r.rig.event(.rightMouseDown, at: r.rig.window(body)))
        #expect(r.rig.runtime.panels.menu != nil && r.panel == nil)
        let close = try #require(r.lines("CHAT close").last)
        #expect(close.hasPrefix("CHAT close reason=menu gen=1"), "\(close)")
    }

    @Test func ChatClick_everyRefusalIsLoggedWithItsReasonAndOpensNothing() {
        let r = ControllerRig()
        r.enabled = false
        r.open()
        #expect(r.lines("CHAT refuse") == ["CHAT refuse reason=off"])
        r.enabled = true
        for reason in [ChatRefusal.quiet, .hidden, .exam, .drag, .noDisplay] {
            r.host.refusal = reason
            r.open()
        }
        #expect(r.lines("CHAT refuse").dropFirst().map { $0 } == ["quiet", "hidden", "exam", "drag", "no-display"].map { "CHAT refuse reason=\($0)" })
        r.host.refusal = nil; r.host.examRunning = true
        r.open()
        #expect(r.lines("CHAT refuse").last == "CHAT refuse reason=exam", "the exam browser running now refuses even when the scheduler does not know yet")
        r.host.examRunning = false; r.host.rect = nil
        r.open()
        #expect(r.lines("CHAT refuse").last == "CHAT refuse reason=no-display")
        #expect(r.controller.generation == 0 && !r.controller.isOpen, "a refused open takes no number")
    }

    @Test func ChatClick_theChatSettingOffRefusesAtTheDoubleClick() throws {
        let r = try ChatRuntimeRig(control: ["chat": false])
        try r.doubleClick()
        #expect(r.lines("CHAT refuse").first?.hasSuffix("reason=off") == true, Comment(rawValue: "\(r.lines("CHAT"))"))
        #expect(r.panel == nil)
    }

    @Test func ChatClick_withoutAChatEnvironmentADoubleClickIsWhatItWasInV2() throws {
        let r = try ChatRuntimeRig(withChat: false)
        try r.doubleClick()
        #expect(r.lines("CHAT").isEmpty && r.panel == nil)
    }

    @Test func ChatClick_aRunningExamBrowserRefusesTheOpenThroughTheRuntime() throws {
        let r = try ChatRuntimeRig()
        r.machine.examRunning = true
        try r.doubleClick()
        #expect(r.lines("CHAT refuse").contains("CHAT refuse reason=exam"), "\(r.lines("CHAT"))")
        #expect(r.panel == nil)
    }
}
