import Testing
import Foundation
import AppKit
import SwiftUI
import ClawdCore
import ClawdRendering
import ClawdDesktop

// F1.2 audit and F1.5: the one window that may become key, and only with the user's cause.

@Suite("Chat focus", .serialized)
@MainActor
struct ChatFocusSuite {
    private func opened(virtual: Bool = false) throws -> ChatRuntimeRig {
        let r = try ChatRuntimeRig(virtual: virtual)
        r.machine.onChatKey = { [unowned r] panel in r.post(NSWindow.didBecomeKeyNotification, panel) }
        try r.doubleClick()
        return r
    }
    /// Opens the chat on a virtual clock and lets the opening's activation token (1 s) lapse, so a key that follows has no cause but its own.
    private func openedPastTheToken() throws -> ChatRuntimeRig {
        let r = try opened(virtual: true)
        r.rig.advance(2)
        return r
    }
    private func reopen(_ r: ChatRuntimeRig) throws {
        #expect(r.panel == nil)
        try r.doubleClick()
        r.rig.advance(2)
    }

    @Test func ChatFocus_theOpenCallsKeyIsCausedByTheAcceptedDoubleClickAndIsNotAViolation() throws {
        let r = try opened()
        #expect(r.lines("CHAT key gen=1").count == 1 && r.lines("CHAT key-uncaused").isEmpty, "\(r.lines("CHAT"))")
        #expect(r.rig.monitor.status.focusViolations == 0)
        #expect(r.lines("FOCUS_VIOLATION").isEmpty)
    }

    @Test func ChatFocus_aMouseDownInThePanelIsTheUsersCauseButAnyOtherCauseIsAViolation() throws {
        let r = try openedPastTheToken()
        var panel = try #require(r.panel)
        r.machine.chatEvent = ChatCurrentEvent(isMouseDown: true, window: panel)
        r.post(NSWindow.didBecomeKeyNotification, panel)
        #expect(r.rig.monitor.status.focusViolations == 0 && r.lines("CHAT key gen=1").count == 2)
        // The first uncaused key closes the panel, so each uncaused cause has an opening of its own.
        var causes: [(String, (ChatPanel) -> ChatCurrentEvent?)] = [("no event", { _ in nil }), ("a key", { ChatCurrentEvent(isMouseDown: false, window: $0) }),
                                                                    ("a mouse-down in another window", { [unowned r] _ in ChatCurrentEvent(isMouseDown: true, window: r.rig.bodyPanel) })]
        var expected = 0
        while let (name, cause) = causes.first {
            causes.removeFirst()
            r.machine.chatEvent = cause(panel)
            r.post(NSWindow.didBecomeKeyNotification, panel)
            expected += 1
            #expect(r.rig.monitor.status.focusViolations == expected, "\(name)")
            r.focus.drain()
            guard !causes.isEmpty else { break }
            try reopen(r)
            panel = try #require(r.panel)
        }
        #expect(r.lines("CHAT key-uncaused").count == 3)
        #expect(r.lines("FOCUS_VIOLATION trigger").count == 3)
        #expect(r.lines("CHAT close reason=outside").count == 3)
    }

    /// SA3 code review r1 L-5, the chat alone: a click back after a resign, the key waiting between will and did, and the claim's peek draining the main
    /// queue as a nested event pass. The claim judges the key; the resolver judges nothing while the step runs.
    @Test func ChatFocus_aKeyWaitingOnThePanelIsJudgedByTheClaimWhenThePeekDrainsTheQueue() throws {
        let r = try opened(virtual: true)
        let panel = try #require(r.panel)
        r.focus.active = true
        r.post(NSApplication.willBecomeActiveNotification, nil)
        r.post(NSApplication.didBecomeActiveNotification, nil)
        #expect(r.lines("CHAT active gen=1 cause=open").count == 1 && r.focus.peekCalls == 0, "\(r.lines("CHAT"))")
        r.rig.advance(2)
        r.focus.active = false
        r.post(NSApplication.didResignActiveNotification, nil)
        r.rig.advance(5)
        r.machine.chatEvent = nil
        let before = r.lines("CHAT").count
        r.focus.onPeek = { r.focus.drain() }
        r.focus.pressAt = (r.rig.virtualClock?.now ?? 0) - 0.05
        r.post(NSApplication.willBecomeActiveNotification, nil)
        r.focus.active = true
        r.post(NSWindow.didBecomeKeyNotification, panel)
        r.post(NSApplication.didBecomeActiveNotification, nil)
        let chat = Array(r.lines("CHAT").dropFirst(before))
        let active = chat.firstIndex(of: "CHAT active gen=1 cause=click")
        let key = chat.firstIndex(of: "CHAT key gen=1")
        #expect(r.focus.peekCalls == 1, "\(r.focus.peekCalls)")
        #expect(active != nil && key != nil && active! < key!, "the key is judged after the claim: \(chat)")
        #expect(r.lines("CHAT key-uncaused").isEmpty && r.rig.monitor.status.focusViolations == 0, "\(r.lines("CHAT")) \(r.lines("FOCUS"))")
        #expect(panel.firstResponder !== panel, "the input gate is released")
        r.focus.drain()
        #expect(r.panel === panel && r.lines("CHAT close").isEmpty, "\(r.lines("CHAT"))")
    }

    @Test func ChatFocus_anUncausedKeyClosesThePanelKeepsTheDraftAndDoesNotDeactivate() throws {
        let r = try openedPastTheToken()
        var deactivations = 0
        r.rig.monitor.onViolation = { deactivations += 1 }
        try r.rig.store.write(Data("BOOT 1792000000.000000 pid=1 counter=0 violations=0\n".utf8), to: FocusMonitor.ledgerFile)
        let panel = try #require(r.panel)
        panel.chatView.inputText = "hello"
        r.machine.chatEvent = nil
        r.post(NSWindow.didBecomeKeyNotification, panel)
        #expect(r.rig.monitor.status.focusViolations == 1)
        r.focus.drain()
        #expect(r.panel == nil, "the panel closed on the next turn")
        #expect(r.lines("CHAT key-uncaused gen=1").count == 1 && r.lines("CHAT close reason=outside gen=1 draft=5").count == 1, "\(r.lines("CHAT"))")
        #expect(r.lines("FOCUS_VIOLATION trigger").count == 1)
        let ledger = String(decoding: (try? ReadOnlyFile.data(try r.rig.store.url(FocusMonitor.ledgerFile).path)) ?? Data(), as: UTF8.self)
        #expect(ledger.split(separator: "\n").filter { $0.contains(" VIOLATION ") }.count == 1)
        #expect(deactivations == 0, "the production hand-back (onViolation) never ran")
        try r.doubleClick()
        #expect(r.panel?.chatView.inputText == "hello", "the next open shows the draft")
    }

    @Test func ChatFocus_theUncausedCloseRunsOnTheNextMainQueueTurn() throws {
        let r = try openedPastTheToken()
        let panel = try #require(r.panel)
        r.machine.chatEvent = nil
        r.post(NSWindow.didBecomeKeyNotification, panel)
        #expect(r.panel === panel && panel.canBecomeKey, "inside the notification only the record happens: the panel is still live and keyable")
        // A second uncaused key of the same opening before the drain records a second violation and still gives one close.
        r.post(NSWindow.didBecomeKeyNotification, panel)
        #expect(r.rig.monitor.status.focusViolations == 2 && r.lines("CHAT close").isEmpty)
        r.focus.drain()
        #expect(r.panel == nil && !panel.canBecomeKey)
        #expect(r.lines("CHAT close reason=outside").count == 1 && r.lines("CHAT close").count == 1, "\(r.lines("CHAT close"))")
        // An Esc before the drain closes with esc, and the pending close then does nothing.
        try reopen(r)
        let second = try #require(r.panel)
        r.machine.chatEvent = nil
        r.post(NSWindow.didBecomeKeyNotification, second)
        second.onEscape?()
        #expect(r.panel == nil && r.lines("CHAT close reason=esc").count == 1)
        r.focus.drain()
        #expect(r.lines("CHAT close reason=outside").count == 1 && r.lines("CHAT close").count == 2, "\(r.lines("CHAT close"))")
    }

    @Test func ChatFocus_otherViolationsStillCallOnViolation() throws {
        let r = try opened()
        var recorded = 0
        r.rig.monitor.onViolation = { recorded += 1 }
        let panel = try #require(r.panel)
        r.machine.chatEvent = ChatCurrentEvent(isMouseDown: true, window: r.rig.bodyPanel)
        r.post(NSWindow.didBecomeKeyNotification, r.rig.bodyPanel)
        #expect(recorded == 1, "the body panel's key")
        r.post(NSWindow.didBecomeMainNotification, panel)
        #expect(recorded == 2, "the chat panel's main")
        try r.doubleClick()
        #expect(r.panel == nil)
        r.post(NSApplication.didBecomeActiveNotification, nil)
        #expect(recorded == 3 && r.rig.monitor.status.focusViolations == 3, "an activation with no chat open")
    }

    @Test func ChatFocus_theSamePanelsKeyAfterCloseIsAViolationWithNoChatLine() throws {
        let r = try opened()
        let panel = try #require(r.panel)
        try r.doubleClick()
        #expect(r.panel == nil)
        r.machine.chatEvent = ChatCurrentEvent(isMouseDown: true, window: panel)
        let keyLines = r.lines("CHAT key").count
        r.post(NSWindow.didBecomeKeyNotification, panel)
        #expect(r.rig.monitor.status.focusViolations == 1 && r.lines("CHAT key").count == keyLines)
        #expect(!panel.canBecomeKey, "canBecomeKey is false from the moment close begins")
    }

    @Test func ChatFocus_anotherWindowsKeyAnyMainAndAnyActivationStayViolations() throws {
        let r = try opened()
        let panel = try #require(r.panel)
        try r.rig.store.write(Data("BOOT 1792000000.000000 pid=1 counter=0 violations=0\n".utf8), to: FocusMonitor.ledgerFile)
        r.machine.chatEvent = ChatCurrentEvent(isMouseDown: true, window: r.rig.bodyPanel)
        r.post(NSWindow.didBecomeKeyNotification, r.rig.bodyPanel)
        r.post(NSWindow.didBecomeMainNotification, panel)
        try r.doubleClick()
        r.post(NSApplication.didBecomeActiveNotification, nil)
        #expect(r.rig.monitor.status.focusViolations == 3)
        let ledger = String(decoding: (try? ReadOnlyFile.data(try r.rig.store.url(FocusMonitor.ledgerFile).path)) ?? Data(), as: UTF8.self)
        #expect(ledger.split(separator: "\n").filter { $0.contains(" VIOLATION ") }.count == 3)
        #expect(!ledger.contains("CHAT"), "no chat line ever goes to the ledger")
    }

    @Test func ChatFocus_withNoQueryInstalledNothingIsExempt() throws {
        let r = try opened()
        r.rig.monitor.activationVerdict = nil
        let panel = try #require(r.panel)
        r.rig.monitor.keyExemption = nil
        r.machine.chatEvent = ChatCurrentEvent(isMouseDown: true, window: panel)
        r.post(NSWindow.didBecomeKeyNotification, panel)
        #expect(r.rig.monitor.status.focusViolations == 1)
    }

    @Test func ChatFocus_resigningKeyIsLogged() throws {
        let r = try opened()
        r.post(NSWindow.didResignKeyNotification, try #require(r.panel))
        #expect(r.lines("CHAT resign gen=1").count == 1)
    }

    @Test func ChatFocus_aReplacementOnADisplayChangeNeverMakesKey() throws {
        let r = try opened()
        let panel = try #require(r.panel)
        let before = panel.frame
        #expect(r.machine.chatKeys.count == 1)
        r.machine.display = DisplayInfo(uuid: "D", frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
                                        visibleFrame: CGRect(x: 0, y: 40, width: 1600, height: 860), backingScaleFactor: 2)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(r.panel === panel && r.machine.chatKeys.count == 1, "re-placed, never re-keyed")
        #expect(panel.frame != before || before.maxX <= 1600 - 8, "\(before) -> \(panel.frame)")
        #expect(CGRect(x: 0, y: 40, width: 1600, height: 860).contains(panel.frame))
    }

    @Test func ChatFocus_aPanelThatIsNotKeyableBeforeOpenAndAfterCloseIsKeyableOnlyInBetween() throws {
        let r = ControllerRig()
        var seen: [Bool] = []
        r.controller.panelPrepared = { seen.append($0.canBecomeKey) }
        r.open()
        let panel = try #require(r.controller.livePanel)
        #expect(seen == [false] && panel.canBecomeKey && !panel.canBecomeMain)
        r.controller.close(.toggle)
        #expect(!panel.canBecomeKey)
    }

    @Test func ChatFocus_theAuditFlagsEachBrokenPropertyAndARefusedOpenShowsNothing() throws {
        let breakers: [(String, (ChatPanel) -> Void)] = [
            ("closable", { $0.styleMask.insert(.closable) }),
            ("miniaturizable", { $0.styleMask.insert(.miniaturizable) }),
            ("resizable", { $0.styleMask.insert(.resizable) }),
            ("released when closed", { $0.isReleasedWhenClosed = true }),
            ("link detection", { $0.chatView.inputView.isAutomaticLinkDetectionEnabled = true }),
            ("data detection", { $0.chatView.transcriptView.isAutomaticDataDetectionEnabled = true }),
            ("hides on deactivate", { $0.hidesOnDeactivate = true }),
            ("level", { $0.level = .normal }),
            ("key before open", { $0.allowKey() }),
            ("collection behavior", { $0.collectionBehavior = [] }),
            ("context menu", { $0.chatView.inputView.menu = NSMenu(title: "x") }),
            ("hosting view", { $0.contentView = NSHostingView(rootView: Text("x")) }),
            ("link attribute", { panel in
                panel.chatView.transcriptView.textStorage?.setAttributedString(NSAttributedString(string: "https://example.com", attributes: [.link: URL(string: "https://example.com")!]))
            }),
        ]
        for (name, breakIt) in breakers {
            let r = ControllerRig()
            r.controller.panelPrepared = breakIt
            r.open()
            #expect(r.controller.livePanel == nil && r.presented == 0 && r.keys.isEmpty, "\(name): nothing is shown")
            #expect(r.lines("CHAT contract-violation").count == 1, "\(name): \(r.logs)")
            #expect(r.lines("CHAT open").isEmpty)
        }
        // The "bit outside the allowed style" line flags these three as well, so a count of violations cannot tell whether the audit still
        // has its own line for each: the named violation must be there.
        for (name, breakIt) in breakers where ["closable", "miniaturizable", "resizable"].contains(name) {
            let broken = ChatPanel(overFullScreen: false, gen: 1, view: ChatPanelView(height: 480))
            breakIt(broken)
            #expect(ChatPanelAudit.violations(of: broken).contains("styleMask is \(name)"), "\(name): \(ChatPanelAudit.violations(of: broken))")
        }
        let fresh = ChatPanel(overFullScreen: false, gen: 1, view: ChatPanelView(height: 480))
        #expect(ChatPanelAudit.violations(of: fresh).isEmpty, "\(ChatPanelAudit.violations(of: fresh))")
    }

    @Test func ChatFocus_aRenderedTranscriptWithAURLCarriesNoLinkAttribute() throws {
        let r = ControllerRig()
        r.open()
        var transcript = ChatTranscript()
        transcript.appendUser("see https://example.com/a?b=c and `https://x.y`")
        transcript.apply(.assistantBlocks(messageKey: "m", blocks: [.text("go to https://example.com now")]))
        r.view.setTranscript(transcript.entries)
        #expect(r.view.transcriptView.string.contains("https://example.com"))
        #expect(!r.view.transcriptHasLink)
        #expect(ChatPanelAudit.violations(of: r.controller.livePanel!, overFullScreenAllowed: false).filter { $0.contains("link") }.isEmpty)
    }
}
