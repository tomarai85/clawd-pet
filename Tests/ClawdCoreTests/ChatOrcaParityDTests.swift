import Testing
import Foundation
import AppKit
import WebKit
@testable import ClawdCore
import ClawdDesktop

// Orca parity round D, sprint 1: the Swift side of the transcript page. The transcript's times and "sending", the bridge payload, the page's
// message checks, and the controller's gates for Copy code, Copy link, Esc and a press outside the web view.

@MainActor
private func fixedClockTranscript(_ seconds: TimeInterval = 1_700_000_000.5) -> (ChatTranscript, Box) {
    let box = Box(seconds)
    return (ChatTranscript(now: { Date(timeIntervalSince1970: box.seconds) }), box)
}

private final class Box { var seconds: TimeInterval; init(_ seconds: TimeInterval) { self.seconds = seconds } }

@Suite("Chat orca parity D, the Swift side", .serialized)
@MainActor
struct ChatOrcaParityDSuite {
    // MARK: Q3 time and sending in the transcript and the payload

    @Test func ChatOrcaD3_aUserEntryCarriesItsSendTimeAndAnAssistantEntryTheTimeOfItsFirstBlock() throws {
        var (transcript, clock) = fixedClockTranscript()
        transcript.appendUser("hi")
        clock.seconds += 7
        transcript.apply(.textDelta(messageKey: "m", blockIndex: 0, text: "hel"))
        clock.seconds += 7
        transcript.apply(.textDelta(messageKey: "m", blockIndex: 0, text: "lo"))
        let user = try #require(transcript.entries.first { $0.kind == .user }), assistant = try #require(transcript.entries.first { $0.kind == .assistant })
        #expect(user.time == 1_700_000_000_500 && user.sending == false, "the first output cleared sending: \(user)")
        #expect(assistant.time == 1_700_000_007_500, "the time of the first block, not of the last delta: \(String(describing: assistant.time))")
        let payload = ChatWebPayload.entry(assistant)
        #expect(payload["time"] as? Double == 1_700_000_007_500, "\(payload)")
        let sendingPayload = ChatWebPayload.entry(ChatEntry(id: 1, kind: .user, text: "x", time: 5, sending: true))
        #expect(sendingPayload["sending"] as? Bool == true && sendingPayload["time"] as? Double == 5, "\(sendingPayload)")
        #expect(ChatWebPayload.entry(ChatEntry(id: 2, kind: .tool, text: "")).keys.contains("time") == false, "a tool entry has no time")
        #expect(ChatWebPayload.entry(ChatEntry(id: 3, kind: .user, text: "x", time: .nan))["time"] == nil, "a time that is not finite is left out")
    }

    @Test func ChatOrcaD3_sendingStaysUntilTheFirstOutputOrTheTurnsEndWhicheverComesFirst() throws {
        var (transcript, _) = fixedClockTranscript()
        transcript.appendUser("one")
        #expect(transcript.entries.last?.sending == true)
        transcript.apply(.initialized(sessionId: "s", model: "m", permissionMode: "default", version: "1"))
        transcript.apply(.ignored(type: "system"))
        #expect(transcript.entries.last?.sending == true, "an init line and an ignored line are not output")
        transcript.apply(.toolStarted(id: "t", name: "Read"))
        #expect(transcript.entries.first?.sending == false, "a tool is output")
        transcript.appendUser("two")
        #expect(transcript.entries.last?.sending == true && transcript.entries.first?.sending == false)
        transcript.endTurnWithoutResult()
        #expect(transcript.entries.last?.sending == false, "the turn ended with no output")
        transcript.appendUser("three")
        transcript.appendUser("four")
        #expect(transcript.entries.filter { $0.kind == .user }.map(\.sending) == [false, false, false, true], "only the newest message is sending")
        transcript.apply(.result(outcome: .success, durationMs: 10, totalCost: 0, sessionId: "s", text: "done"))
        #expect(transcript.entries.filter { $0.kind == .user }.allSatisfy { !$0.sending })
    }

    // MARK: the page's messages

    @Test func ChatOrcaD5_theThreeNewMessagesAreCheckedForTypeKeysAndRange() {
        let r = WebPageRig()
        var codes: [[Int]] = [], links: [String] = []
        r.page.onCopyCodeRequest = { codes.append([$0, $1]) }
        r.page.onCopyLinkRequest = { links.append($0) }
        func post(_ message: [String: Any]) { r.page.received(message) }
        post(["type": "copy-code", "id": 4, "index": 1])
        post(["type": "copy-code", "id": 4, "index": 1.5])
        post(["type": "copy-code", "id": "4", "index": 1])
        post(["type": "copy-code", "id": true, "index": 1])
        post(["type": "copy-code", "id": 4, "index": -1])
        post(["type": "copy-code", "id": 4, "index": 10_000_001])
        post(["type": "copy-code", "id": 4])
        post(["type": "copy-code", "id": 4, "index": 1, "text": "x"])
        post(["type": "copy-code", "id": 4, "index": 1, "text": "x", "more": 1])
        post(["type": "copy", "id": 4, "index": 1])
        #expect(codes == [[4, 1]], "only the exact message passes: \(codes)")
        post(["type": "copy-link", "url": "https://example.com/a"])
        post(["type": "copy-link", "url": "javascript:alert(1)"])
        post(["type": "copy-link", "url": "https://example.com/" + String(repeating: "a", count: 2100)])
        post(["type": "copy-link", "url": 5])
        post(["type": "copy-link", "url": "https://example.com/a", "extra": 1])
        #expect(links == ["https://example.com/a"], "\(links)")
        #expect(!r.page.layerOpen)
        post(["type": "layer", "open": "yes"])
        post(["type": "layer", "open": 1])
        post(["type": "layer"])
        post(["type": "layer", "open": true, "x": 1])
        #expect(!r.page.layerOpen, "a non-Bool open, a missing one and an extra key are ignored")
        post(["type": "layer", "open": true])
        #expect(r.page.layerOpen)
        post(["type": "layer", "open": false])
        #expect(!r.page.layerOpen)
    }

    @Test func ChatOrcaD5_aReadyAndATeardownClearTheLayerFlag() async {
        let r = WebPageRig()
        r.page.received(["type": "layer", "open": true])
        #expect(r.page.layerOpen)
        r.page.received(["type": "ready"])
        #expect(!r.page.layerOpen, "ready clears the flag")
        r.page.received(["type": "layer", "open": true])
        r.page.teardown()
        #expect(!r.page.layerOpen, "teardown clears the flag")
    }

    // MARK: Copy code, Copy link, Esc and the outside press in the controller

    private func fenceRig() async throws -> (AttachRig, ChatWebPage, Int) {
        let r = try AttachRig()
        try r.open()
        let page = try #require(r.body.page)
        #expect(await webWait { page.bridge.isReady }, "the opening's page is ready")
        r.rig.session.transcript.appendUser("```swift\nlet a = 1\n```\n\n```\nplain two\n```")
        r.rig.session.onChange?()
        let id = try #require(r.rig.session.transcript.entries.first?.id)
        for _ in 0..<200 {
            let count = try await pageJS(page.view!, "return document.querySelectorAll('.code-block').length;") as? Int
            if count == 2 { return (r, page, id) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("the fences never reached the page")
        return (r, page, id)
    }

    @Test func ChatOrcaD1_aCopyCodeAfterAClickWritesExactlyThatFencesTextAndTellsThePage() async throws {
        let (r, page, id) = try await fenceRig()
        defer { r.cleanUp() }
        r.web.controller.livePanel?.recordMouseDown(at: r.rig.clock.now, left: true)
        page.received(["type": "copy-code", "id": id, "index": 1])
        #expect(await webWait { !r.web.pasteboard.sets.isEmpty })
        #expect(r.web.pasteboard.sets == ["plain two\n"] && page.copiedCode == [[id, 1]], "\(r.web.pasteboard.sets) \(page.copiedCode)")
        page.received(["type": "copy-code", "id": id, "index": 0])
        #expect(await webWait { r.web.pasteboard.sets.count == 2 })
        #expect(r.web.pasteboard.sets.last == "let a = 1\n", "Orca's code text ends in a newline")
    }

    @Test func ChatOrcaD1_noRecentClickAnUnknownIdAToolEntryOrABadIndexEachWriteNothing() async throws {
        let (r, page, id) = try await fenceRig()
        defer { r.cleanUp() }
        let panel = try #require(r.web.controller.livePanel)
        func quiet(_ why: String) async throws {
            try await Task.sleep(nanoseconds: 400_000_000)
            #expect(r.web.pasteboard.sets.isEmpty && page.copiedCode.isEmpty, Comment(rawValue: why))
        }
        page.received(["type": "copy-code", "id": id, "index": 0])
        try await quiet("no mouse-down at all")
        panel.recordMouseDown(at: r.rig.clock.now, left: true)
        r.rig.clock.advance(1.1)
        page.received(["type": "copy-code", "id": id, "index": 0])
        try await quiet("1.1 s after the click")
        panel.recordMouseDown(at: r.rig.clock.now, left: true)
        page.received(["type": "copy-code", "id": id + 99, "index": 0])
        r.rig.session.transcript.apply(.toolStarted(id: "t", name: "Bash"))
        r.rig.session.onChange?()
        let tool = try #require(r.rig.session.transcript.entries.first { $0.kind == .tool }?.id)
        page.received(["type": "copy-code", "id": tool, "index": 0])
        page.received(["type": "copy-code", "id": id, "index": 7])
        page.received(["type": "copy-code", "id": id, "index": 1.5])
        page.received(["type": "copy-code", "id": id, "index": 0, "text": "x"])
        try await quiet("an unknown id, a tool entry, an index with no fence, a fraction, an extra key")
        r.web.pasteboard.refuseWrites = true
        page.received(["type": "copy-code", "id": id, "index": 0])
        try await quiet("a pasteboard that refuses the write")
    }

    @Test func ChatOrcaD5_aCopyLinkAfterAClickWritesTheUrlSaysSoInTheStatusLineAndWithoutAClickWritesNothing() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let page = try #require(r.body.page)
        let panel = try #require(r.web.controller.livePanel)
        page.received(["type": "layer", "open": true])
        page.received(["type": "copy-link", "url": "https://example.com/x"])
        #expect(r.web.pasteboard.sets.isEmpty && page.linkCopiedCount == 0, "no click: nothing is written")
        panel.recordMouseDown(at: r.rig.clock.now, left: true)
        page.received(["type": "copy-link", "url": "javascript:alert(1)"])
        page.received(["type": "copy-link", "url": "https://example.com/x", "extra": 1])
        #expect(r.web.pasteboard.sets.isEmpty, "a URL Swift would not open is not copied")
        r.web.pasteboard.refuseWrites = true
        page.received(["type": "copy-link", "url": "https://example.com/x"])
        #expect(r.web.pasteboard.sets.isEmpty && page.linkCopiedCount == 0 && r.body.statusText == "Failed to copy link", "a refused write says so: \(r.body.statusText)")
        r.web.pasteboard.refuseWrites = false
        page.received(["type": "copy-link", "url": "https://example.com/x"])
        #expect(r.web.pasteboard.sets == ["https://example.com/x"] && page.linkCopiedCount == 1 && r.body.statusText == "Copied link", "\(r.web.pasteboard.sets) \(r.body.statusText)")
        r.rig.clock.advance(1.1)
        page.received(["type": "copy-link", "url": "https://example.com/y"])
        #expect(r.web.pasteboard.sets == ["https://example.com/x"], "1.1 s after the click")
    }

    @Test func ChatOrcaD5_aCopyLinkWritesNothingWithNoPopoverOpenAndNothingForAStringTheParserRewrites() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let page = try #require(r.body.page)
        let panel = try #require(r.web.controller.livePanel)
        panel.recordMouseDown(at: r.rig.clock.now, left: true)
        page.received(["type": "copy-link", "url": "https://example.com/a"])
        #expect(r.web.pasteboard.sets.isEmpty, "no popover is open: a valid URL writes nothing")
        page.received(["type": "layer", "open": true])
        page.received(["type": "copy-link", "url": "https://example.com/a\nb"])
        page.received(["type": "copy-link", "url": "https://example.com/a b"])
        #expect(r.web.pasteboard.sets.isEmpty, "a string with whitespace or a newline is not the URL Swift parsed: \(r.web.pasteboard.sets)")
        page.received(["type": "copy-link", "url": "https://example.com/a"])
        #expect(r.web.pasteboard.sets == ["https://example.com/a"], "with the popover open a valid URL is written")
    }

    @Test func ChatOrcaD5_theCopiedLinkLineClearsAtTheNextPressOrAfterItsDeadlineAndLeavesANewerLineAlone() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let page = try #require(r.body.page)
        let panel = try #require(r.web.controller.livePanel)
        func copy() {
            panel.recordMouseDown(at: r.rig.clock.now, left: true)
            page.received(["type": "layer", "open": true])
            page.received(["type": "copy-link", "url": "https://example.com/a"])
        }
        copy()
        #expect(r.body.statusText == "Copied link" && r.rig.focus.timers.live.contains(ChatController.linkStatusSeconds), "\(r.body.statusText)")
        r.rig.focus.timers.fire(exactly: ChatController.linkStatusSeconds)
        #expect(r.body.statusText.isEmpty, "the deadline clears the line while the panel is open")
        copy()
        #expect(r.body.statusText == "Copied link")
        panel.recordMouseDown(at: r.rig.clock.now + 0.1, left: true)
        panel.onMouseDown?()
        #expect(r.body.statusText.isEmpty, "the next press in the panel clears the line")
        copy()
        r.body.setStatus("Not sent: an exam browser is running")
        r.rig.focus.timers.fire(exactly: ChatController.linkStatusSeconds)
        #expect(r.body.statusText == "Not sent: an exam browser is running", "a newer line is left alone")
    }

    @Test func ChatOrcaD5_aWebContentProcessEndClearsTheLayerFlag() async {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        r.page.received(["type": "layer", "open": true])
        #expect(r.page.layerOpen)
        r.page.webViewWebContentProcessDidTerminate(r.page.view!)
        #expect(!r.page.layerOpen, "the page that held the popover is gone")
    }

    @Test func ChatOrcaD5_theClipboardRuleRefusesTextOverSixteenMebibytesAndKeepsLessWhole() {
        let big = String(repeating: "a", count: ChatWebPage.clipboardLimit)
        #expect(ChatWebPage.clipboardText(big)?.utf8.count == ChatWebPage.clipboardLimit, "16 MiB is written whole")
        #expect(ChatWebPage.clipboardText(big + "a") == nil, "16 MiB + 1 is not written")
        #expect(ChatWebPage.clipboardText("短い") == "短い")
    }

    private func runningRig() throws -> (WebKindRig, ChatWebPage) {
        let r = WebKindRig()
        r.rig.open()
        r.type("go")
        r.pressEnter()
        #expect(r.rig.session.turn == .running)
        return (r, try #require(r.body?.page))
    }

    @Test func ChatOrcaD5_escWithThePopoverOpenClosesItAndSendsNoInterruptAndAFalseAnswerInterruptsAtOnce() throws {
        let (r, page) = try runningRig()
        var asked = 0
        page.layerDismissSource = { completion in asked += 1; completion(true) }
        page.received(["type": "layer", "open": true])
        r.body?.inputView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(asked == 1 && r.rig.session.interrupts == 0, "the popover took the Esc: \(asked) \(r.rig.session.interrupts)")
        page.layerDismissSource = { completion in asked += 1; completion(false) }
        r.body?.inputView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(asked == 2 && r.rig.session.interrupts == 1 && !page.layerOpen, "the page had no popover: the same Esc interrupts, and the flag is cleared")
        r.body?.inputView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(asked == 2 && r.rig.session.interrupts == 2, "with no popover open the page is not asked")
        #expect(r.controller.isOpen && r.rig.lines("CHAT close").isEmpty)
    }

    @Test func ChatOrcaD5_aPageThatNeverAnswersLetsTheInterruptThroughAt300MillisecondsAndALateAnswerDoesNothing() throws {
        let (r, page) = try runningRig()
        var late: ((Bool) -> Void)?
        page.layerDismissSource = { late = $0 }
        page.received(["type": "layer", "open": true])
        r.body?.inputView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(r.rig.session.interrupts == 0 && r.rig.focus.timers.live.contains(0.3), "waiting for the page: \(r.rig.focus.timers.live)")
        r.rig.focus.timers.fire(exactly: 0.3)
        #expect(r.rig.session.interrupts == 1 && !page.layerOpen, "the flag is cleared and the Esc goes on to the interrupt")
        late?(false)
        late?(true)
        #expect(r.rig.session.interrupts == 1, "a late answer is ignored")
    }

    @Test func ChatOrcaD5_aPressOnTheComposerClosesThePopoverAndAPressInsideThePageDoesNot() throws {
        let r = WebKindRig()
        r.rig.open()
        let page = try #require(r.body?.page), panel = try #require(r.panel), body = try #require(r.body)
        var dismissals = 0
        page.layerDismissSource = { completion in dismissals += 1; completion(true) }
        let web = try #require(page.view)
        let inWeb = web.convert(CGPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
        let onComposer = body.composer.convert(CGPoint(x: body.composer.bounds.midX, y: body.composer.bounds.midY), to: nil)
        panel.noteMouseDown(mouseEvent(.leftMouseDown, at: onComposer, time: 1, window: panel))
        #expect(dismissals == 0, "nothing is open: the page is not asked")
        page.received(["type": "layer", "open": true])
        panel.noteMouseDown(mouseEvent(.leftMouseDown, at: inWeb, time: 2, window: panel))
        #expect(dismissals == 0, "a press inside the page reaches the page itself")
        panel.noteMouseDown(mouseEvent(.leftMouseDown, at: onComposer, time: 3, window: panel))
        #expect(dismissals == 1, "a press on the composer closes the popover")
        panel.noteMouseDown(mouseEvent(.rightMouseDown, at: onComposer, time: 4, window: panel))
        #expect(dismissals == 2, "so does a right press")
    }
}
