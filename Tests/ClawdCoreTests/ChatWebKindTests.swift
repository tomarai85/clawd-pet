import Testing
import Foundation
import AppKit
import WebKit
import ClawdCore
import ClawdDesktop

// Stage 2: the chat kind (the web transcript over the native composer) in the controller: open, close, Esc, Cmd+W, Cmd+C, the draft, the audit,
// the fallback, and the teardown of the web view at close. The panel is never ordered on screen and never made key.

@MainActor
final class WebKindRig {
    let rig: ControllerRig
    let pasteboard: FakePasteboard

    init(isInstalled: @escaping () -> Bool = { true }, geometry: ChatGeometryStoring? = nil, attach: ChatAttachEnvironment = ChatAttachEnvironment(),
         composerTimers: ChatTimers = ManualChatTimers()) {
        let board = FakePasteboard()
        pasteboard = board
        rig = ControllerRig(web: ChatWebEnvironment(pageDirectory: chatPageDirectory, openLink: { _ in }, pasteboard: board, isInstalled: isInstalled, attach: attach,
                                                    composerTimers: composerTimers),
                            geometry: geometry)
    }

    var controller: ChatController { rig.controller }
    var panel: ChatPanel? { controller.livePanel }
    var body: ChatWebBody? { panel?.terminal?.webBody }

    func keyEvent(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    func type(_ text: String) { body?.inputView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    func pressEnter(modifiers: NSEvent.ModifierFlags = []) {
        body?.inputView.modifiers = { modifiers }
        body?.inputView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }
}

@Suite("Chat web kind", .serialized)
@MainActor
struct ChatWebKindSuite {
    @Test func ChatWebKind_theDefaultViewOpensTheWebChatWithTheContainersChromeAndAnInputAndAnEmptyAuditLog() throws {
        let r = WebKindRig()
        r.rig.open()
        let panel = try #require(r.panel)
        let body = try #require(r.body)
        #expect(panel.terminal?.terminalView == nil && panel.terminal?.titleBarView != nil && panel.terminal?.handles.count == 8)
        #expect(r.rig.lines("CHAT contract-violation").isEmpty && r.rig.lines("CHAT open").count == 1 && r.rig.keys.count == 1)
        #expect(panel.contentView === panel.terminal && body.superview === panel.terminal)
        #expect(body.page?.view?.superview === body && body.inputView.window === panel, "the web view and the input are in the panel")
        #expect(panel.terminal?.handles.allSatisfy { $0.scrollTarget === body.page?.view } == true, "the wheel over a handle goes to the web view")
        #expect(body.auditProblems().isEmpty)
        #expect(panel.surface === body)
    }

    @Test func ChatWebKind_aViewOfStreamOrAMissingPageOpensTheStreamViewInstead() throws {
        let stream = WebKindRig()
        stream.rig.chatSettings.view = .stream
        stream.rig.open()
        #expect(stream.panel?.terminal == nil && stream.panel?.chatView != nil)
        let missing = WebKindRig(isInstalled: { false })
        missing.rig.open()
        #expect(missing.panel?.terminal == nil, "an install without the page uses the stream view")
        #expect(missing.rig.lines("CHAT web-page-missing").count == 1)
        let off = ControllerRig()
        off.open()
        #expect(off.controller.livePanel?.terminal == nil, "an environment with no web chat (every older rig) keeps the stream view")
    }

    @Test func ChatWebKind_theAuditRefusesAWebViewThatWebKitsOwnSurfacesAreOnFor() {
        let r = WebKindRig()
        r.rig.controller.panelPrepared = { $0.terminal?.webBody?.page?.view?.allowsLinkPreview = true }
        r.rig.open()
        #expect(!r.controller.isOpen && r.rig.lines("CHAT contract-violation the web view allows link previews").count == 1, "\(r.rig.logs)")
        #expect(r.rig.presented == 0)
    }

    @Test func ChatWebKind_enterSendsShiftEnterDoesNotAndTheSessionGetsTheText() throws {
        let r = WebKindRig()
        r.rig.open()
        r.type("hello 日本")
        r.pressEnter(modifiers: .shift)
        #expect(r.rig.session.sent.isEmpty && r.body?.inputText == "hello 日本\n", "Shift+Enter is a newline")
        r.pressEnter()
        #expect(r.rig.session.sent == ["hello 日本\n"] && r.body?.inputText == "")
    }

    @Test func ChatWebKind_theSendControlDoesNotSendWhileTheInputIsComposing() throws {
        let r = WebKindRig()
        r.rig.open()
        let body = try #require(r.body)
        r.type("x")
        body.inputView.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(body.inputView.hasMarkedText() && body.composer.isSendEnabled)
        body.composer.sendButton.performClick(nil)
        #expect(r.rig.session.sent.isEmpty, "an unconverted composition is not sent: \(r.rig.session.sent)")
        #expect(body.inputText.contains("にほんご"), "and the input keeps it")
        body.inputView.unmarkText()
        body.composer.sendButton.performClick(nil)
        #expect(r.rig.session.sent.count == 1, "the same click sends once the composition is committed")
    }

    @Test func ChatWebKind_theStreamViewsSendButtonDoesNotSendWhileTheInputIsComposing() throws {
        let rig = ControllerRig()
        rig.open()
        let view = rig.view
        let send = try #require(view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Send" })
        rig.type("x")
        view.inputView.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.inputView.hasMarkedText() && send.isEnabled)
        send.performClick(nil)
        #expect(rig.session.sent.isEmpty, "\(rig.session.sent)")
        view.inputView.unmarkText()
        send.performClick(nil)
        #expect(rig.session.sent.count == 1, "the same click sends once the composition is committed")
    }

    @Test func ChatWebKind_escInterruptsARunningTurnAndLeavesThePanelOpen() throws {
        let r = WebKindRig()
        r.rig.open()
        r.type("go")
        r.pressEnter()
        #expect(r.rig.session.turn == .running)
        r.body?.inputView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(r.rig.session.interrupts == 1 && r.controller.isOpen && r.rig.lines("CHAT close").isEmpty)
        r.panel?.cancelOperation(nil)
        #expect(r.rig.session.interrupts == 2 && r.controller.isOpen, "Esc with no text view in the chain does the same")
    }

    @Test func ChatWebKind_escWhileIdleLeavesThePanelOpenAndSendsNothing() throws {
        let r = WebKindRig()
        r.rig.open()
        r.type("draft")
        r.body?.inputView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(r.controller.isOpen && r.rig.session.interrupts == 0 && r.rig.session.sent.isEmpty && r.body?.inputText == "draft")
    }

    @Test func ChatWebKind_escWithMarkedTextIsTheInputMethodsAndDoesNeither() throws {
        let r = WebKindRig()
        r.rig.open()
        r.type("go")
        r.pressEnter()
        r.body?.inputView.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        r.body?.inputView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(r.controller.isOpen && r.rig.session.interrupts == 0)
    }

    @Test func ChatWebKind_theDraftSurvivesACloseAndReturns() throws {
        let r = WebKindRig()
        r.rig.open()
        r.type("half a thought")
        r.controller.close(.button)
        #expect(r.rig.lines("CHAT close reason=button gen=1 draft=14").count == 1, "\(r.rig.logs)")
        r.rig.open(at: 2)
        #expect(r.body?.inputText == "half a thought")
    }

    @Test func ChatWebKind_cmdWClosesWithTheShortcutReason() throws {
        let r = WebKindRig()
        r.rig.open()
        let handled = r.panel?.performKeyEquivalent(with: r.keyEvent(code: 13, characters: "w", modifiers: [.command]))
        #expect(handled == true && !r.controller.isOpen && r.rig.lines("CHAT close reason=shortcut").count == 1)
    }

    @Test func ChatWebKind_cmdCForwardsToThePageOnlyWhenTheInputHasNoSelection() throws {
        let r = WebKindRig()
        r.rig.open()
        let copy = r.keyEvent(code: 8, characters: "c", modifiers: [.command])
        #expect(r.panel?.performKeyEquivalent(with: copy) == true)
        #expect(r.body?.pageCopyRequests == 1, "an empty input selection: the page's selection is copied")
        r.type("typed words")
        r.body?.inputView.setSelectedRange(NSRange(location: 0, length: 5))
        _ = r.panel?.performKeyEquivalent(with: copy)
        #expect(r.body?.pageCopyRequests == 1, "the input has a selection: Cmd+C is the input's")
        let shifted = r.keyEvent(code: 8, characters: "c", modifiers: [.command, .shift])
        r.body?.inputView.setSelectedRange(NSRange(location: 0, length: 0))
        _ = r.panel?.performKeyEquivalent(with: shifted)
        #expect(r.body?.pageCopyRequests == 1, "only exactly Command")
    }

    @Test func ChatWebKind_theConversationReachesThePageOnlyAfterItsReadyAndThenAsChanges() async throws {
        let r = WebKindRig()
        r.rig.session.transcript.appendUser("first")
        r.rig.open()
        let page = try #require(r.body?.page)
        #expect(page.bridge.calls == 0, "nothing before ready")
        #expect(await webWait { page.bridge.calls >= 1 })
        #expect(page.bridge.resets == 1)
        let text = try await pageJS(page.view!, "return document.querySelector('.user-bubble').textContent;") as? String
        #expect(text?.contains("first") == true)
        r.rig.session.transcript.appendUser("second")
        r.rig.session.onChange?()
        #expect(await webWait { page.bridge.calls >= 2 })
        #expect(page.bridge.resets == 1, "the second call is a change, not another snapshot")
    }

    @Test func ChatWebKind_closeTearsTheWebViewDownAndItIsFreedEvenWithACallInFlight() async throws {
        weak var weakView: WKWebView?
        weak var weakPage: ChatWebPage?
        do {
            let r = WebKindRig()
            r.rig.session.transcript.appendUser("in flight")
            r.rig.open()
            let page = try #require(r.body?.page)
            weakView = page.view
            weakPage = page
            #expect(await webWait { page.bridge.calls >= 1 })
            r.controller.close(.button)          // the reset may still be in flight here
            #expect(page.view == nil, "the page let go of its web view at close")
            #expect(page.bridge.isReady == false)
            let body = r.body
            #expect(body == nil && r.panel == nil)
        }
        #expect(await webWait(20) { weakView == nil && weakPage == nil }, "the web view and its page are gone after close (no retain cycle through the message handler)")
    }

    @Test func ChatWebKind_everyReopenGetsANewWebViewAndANewDataStore() async throws {
        let r = WebKindRig()
        r.rig.open()
        let first = try #require(r.body?.page?.view)
        let firstStore = first.configuration.websiteDataStore
        r.controller.close(.button)
        r.rig.open(at: 2)
        let second = try #require(r.body?.page?.view)
        #expect(second !== first && second.configuration.websiteDataStore !== firstStore)
        #expect(!second.configuration.websiteDataStore.isPersistent)
    }

    @Test func ChatWebKind_theChatViewSettingChangeClosesTheWebChat() throws {
        let r = WebKindRig()
        r.rig.open()
        r.rig.chatSettings.view = .stream
        r.controller.settingsApplied()
        #expect(!r.controller.isOpen && r.rig.lines("CHAT close reason=view").count == 1)
    }
}
