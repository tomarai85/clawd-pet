import Testing
import Foundation
import AppKit
import WebKit
import ClawdCore
import ClawdDesktop

// Orca parity round D, sprint 7a: the right-click menus (Q19), one rule for page copies (Q21), `copy` only for entries that show a button (Q22), the
// pet-drop refusal once per drag (Q23), the drop timeout of a queued copy (Q24) and the title bar's grab cursor (Q27). The pasteboards are the fakes;
// nothing is shown, no window is made key and no application is activated.

private func rightDown() -> NSEvent {
    NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}

private func titles(_ menu: NSMenu?) -> [String] { menu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? [] }

@Suite("Chat orca parity D, sprint 7a", .serialized)
@MainActor
struct ChatOrcaParityD7aSuite {
    private let sessionID = "5b2f0c1e-77aa-4c0e-9a3d-0123456789ab"

    // MARK: Q19: Copy Session ID

    @Test func ChatOrcaD7a_bothMenusHaveTheThreeTitlesOnceASessionExistsAndTwoBeforeIt() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let view = try #require(r.body.page?.view)
        let webBefore = NSMenu(); view.willOpenMenu(webBefore, with: rightDown())
        #expect(titles(webBefore) == ["Copy", "Paste"] && !webBefore.items.contains { $0.isSeparatorItem }, "no session: two items and no separator: \(titles(webBefore))")
        #expect(titles(r.input.menu(for: rightDown())) == ["Copy", "Paste"] && r.input.contextMenuTitles == ["Copy", "Paste"])
        r.rig.session.sessionID = sessionID
        let web = NSMenu(); view.willOpenMenu(web, with: rightDown())
        #expect(titles(web) == ["Copy", "Paste", "Copy Session ID"], "\(titles(web))")
        #expect(web.items.map(\.isSeparatorItem) == [false, false, true, false], "a separator sits before the id item: \(web.items.map(\.title))")
        try #require(web.items.count > 3, "web.items needs 4 elements: \(web.items.count)")
        #expect(web.items[3].image != nil)
        let input = try #require(r.input.menu(for: rightDown()))
        #expect(titles(input) == ["Copy", "Paste", "Copy Session ID"] && input.items.map(\.isSeparatorItem) == [false, false, true, false])
        #expect(r.input.contextMenuTitles == ["Copy", "Paste", "Copy Session ID"], "the audit's list leaves the separator out")
        #expect(r.body.auditProblems().isEmpty, "\(r.body.auditProblems())")
    }

    @Test func ChatOrcaD7a_theItemCopiesTheConversationIdAndSaysSoInTheStatusLine() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.rig.session.sessionID = sessionID
        let view = try #require(r.body.page?.view)
        let menu = NSMenu(); view.willOpenMenu(menu, with: rightDown())
        let item = try #require(menu.items.last)
        _ = item.target?.perform(item.action)
        #expect(r.web.pasteboard.sets == [sessionID], "\(r.web.pasteboard.sets)")
        #expect(r.body.statusText == "Session ID copied", "\(r.body.statusText)")
        let input = try #require(r.input.menu(for: rightDown())?.items.last)
        r.web.pasteboard.sets.removeAll()
        _ = input.target?.perform(input.action)
        #expect(r.web.pasteboard.sets == [sessionID])
    }

    @Test func ChatOrcaD7a_aRefusedWriteSaysSoAndAMenuOpenedBeforeTheSessionEndedCopiesNothing() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.rig.session.sessionID = sessionID
        let view = try #require(r.body.page?.view)
        r.web.pasteboard.refuseWrites = true
        view.menuCopySessionID()
        #expect(r.web.pasteboard.sets.isEmpty && r.body.statusText == "Unable to copy session ID", "\(r.body.statusText)")
        r.web.pasteboard.refuseWrites = false
        r.rig.session.sessionID = nil
        view.menuCopySessionID()
        #expect(r.web.pasteboard.sets.isEmpty, "no id: nothing is written")
    }

    @Test func ChatOrcaD7a_theAuditAcceptsOnlyCopyPasteAndCopyPasteCopySessionID() {
        #expect(ChatWebBody.contextMenuTitlesAllowed(["Copy", "Paste"]))
        #expect(ChatWebBody.contextMenuTitlesAllowed(["Copy", "Paste", "Copy Session ID"]))
        #expect(!ChatWebBody.contextMenuTitlesAllowed(["Copy", "Paste", "Select All"]))
        #expect(!ChatWebBody.contextMenuTitlesAllowed(["Copy", "Paste", "Copy Session ID", "Select All"]))
        #expect(!ChatWebBody.contextMenuTitlesAllowed(["Copy", "Copy Session ID"]))
        #expect(!ChatWebBody.contextMenuTitlesAllowed(["Copy"]))
    }

    // MARK: Q21: one rule for page copies

    @Test func ChatOrcaD7a_theClipboardRuleWritesSixteenMiBWholeAndRefusesOneByteMore() {
        let board = FakePasteboard()
        var refused = 0
        let limit = ChatWebPage.clipboardLimit
        let whole = String(repeating: "a", count: limit)
        ChatWebPage.copyWhole(whole, to: board, refused: { refused += 1 })
        #expect(board.sets.count == 1 && board.sets[0].utf8.count == limit && refused == 0, "16 MiB goes whole")
        ChatWebPage.copyWhole(whole + "a", to: board, refused: { refused += 1 })
        #expect(board.sets.count == 1 && refused == 1, "16 MiB + 1 writes nothing and reports it")
        ChatWebPage.copyWhole("", to: board, refused: { refused += 1 })
        #expect(board.sets.count == 1 && refused == 1, "an empty text is neither")
    }

    @Test func ChatOrcaD7a_aThreeHundredKiBSelectionIsCopiedWholeByCmdCAndByTheMenu() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let view = try #require(r.page.view)
        let size = 300 * 1024
        _ = try await pageJS(view, "return window.ClawdChat.apply({order: [1], upserts: [{id: 1, kind: 'assistant', text: 'x'.repeat(size)}], turn: 'none'});", ["size": size])
        _ = try await pageJS(view, "const s = window.getSelection(); s.removeAllRanges(); const r = document.createRange(); r.selectNodeContents(document.querySelector('.assistant-row')); s.addRange(r); return 1;")
        r.page.copySelection(to: r.pasteboard, refused: {})
        #expect(await webWait { !r.pasteboard.sets.isEmpty })
        #expect((size...size + 8).contains(r.pasteboard.sets.first?.utf8.count ?? 0), "Cmd+C: \(r.pasteboard.sets.first?.utf8.count ?? -1)")
        r.pasteboard.sets.removeAll()
        r.page.menuCopy(to: r.pasteboard, refused: {})
        #expect(await webWait { !r.pasteboard.sets.isEmpty })
        #expect((size...size + 8).contains(r.pasteboard.sets.first?.utf8.count ?? 0), "the menu's Copy: \(r.pasteboard.sets.first?.utf8.count ?? -1)")
    }

    // MARK: Q22: `copy` only for entries that show a button

    @Test func ChatOrcaD7a_aToolFooterNoticeAndErrorIdWriteNothingAndAUserOrAssistantIdStillDoes() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let session = r.rig.session
        session.transcript.appendUser("hello there")
        session.transcript.apply(.toolStarted(id: "t1", name: "Bash"))
        session.transcript.apply(.toolInput(id: "t1", summary: "ls -la"))
        session.transcript.apply(.result(outcome: .success, durationMs: 4800, totalCost: 0.01, sessionId: "s", text: ""))
        session.transcript.appendNotice("a notice")
        session.transcript.appendError("an error")
        session.transcript.apply(.conversationReset(trigger: "clear", newConversationId: "x"))
        session.transcript.appendUser("", images: ["/tmp/shot.png"])
        session.onChange?()
        let page = try #require(r.body.page)
        let entries = session.transcript.entries
        let byKind = { (kind: ChatEntry.Kind) in entries.first { $0.kind == kind } }
        let user = try #require(byKind(.user)), tool = try #require(byKind(.tool)), footer = try #require(byKind(.footer))
        let notice = try #require(byKind(.notice)), error = try #require(byKind(.error))
        let divider = try #require(byKind(.divider))
        let imageOnly = try #require(entries.first { $0.kind == .user && $0.text.isEmpty })
        #expect(!tool.text.isEmpty && !footer.text.isEmpty && !notice.text.isEmpty && !error.text.isEmpty && !divider.text.isEmpty, "each has text, so only the kind can refuse it")
        let panel = try #require(r.controller.livePanel)
        for other in [tool, footer, notice, error, divider, imageOnly] {
            panel.recordMouseDown(at: r.rig.clock.now, left: true)
            page.received(["type": "copy", "id": other.id])
        }
        #expect(r.web.pasteboard.sets.isEmpty && page.copiedIDs.isEmpty, "\(r.web.pasteboard.sets) \(page.copiedIDs)")
        panel.recordMouseDown(at: r.rig.clock.now, left: true)
        page.received(["type": "copy", "id": user.id])
        #expect(r.web.pasteboard.sets == ["hello there"] && page.copiedIDs == [user.id])
    }

    @Test func ChatOrcaD7a_aUserRowWithNoTextShowsNoCopyButtonUntilItHasText() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let view = try #require(r.page.view)
        let probe = "const b = document.querySelector('[data-id=\"1\"] .copy-btn'); return b ? (b.getClientRects().length > 0 ? 'shown' : 'hidden') : 'none-found';"
        _ = try await pageJS(view, "return window.ClawdChat.apply({order: [1], upserts: [{id: 1, kind: 'user', text: ''}], turn: 'none'});")
        let empty = try await pageJS(view, probe) as? String
        #expect(empty == "hidden", "an image-only prompt has no copy button: \(empty ?? "nil")")
        _ = try await pageJS(view, "return window.ClawdChat.apply({order: [1], upserts: [{id: 1, kind: 'user', text: 'hi'}], turn: 'none'});")
        let filled = try await pageJS(view, probe) as? String
        #expect(filled == "shown", "with text the button is there: \(filled ?? "nil")")
        _ = try await pageJS(view, "return window.ClawdChat.apply({order: [1, 2], upserts: [{id: 2, kind: 'assistant', text: ''}], turn: 'none'});")
        let assistant = try await pageJS(view, "const b = document.querySelector('[data-id=\"2\"] .copy-btn'); return b ? (b.getClientRects().length > 0 ? 'shown' : 'hidden') : 'none-found';") as? String
        #expect(assistant == "hidden", "an assistant row before its first text has none either: \(assistant ?? "nil")")
    }

    // MARK: Q21: the over-limit status through the real path

    @Test func ChatOrcaD7a_aSelectionOverSixteenMiBThroughCmdCWritesNothingAndTheStatusLineSaysSo() async throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let page = try #require(r.body.page)
        let view = try #require(page.view)
        #expect(await webWait { page.bridge.isReady })
        let limit = ChatWebPage.clipboardLimit
        let selection = "window.getSelection = () => ({toString: () => 'a'.repeat(limit + extra)}); return 1;"
        _ = try await pageJS(view, selection, ["limit": limit, "extra": 1])
        r.body.copyPageSelection()
        #expect(await webWait { r.body.statusText == ChatWebPage.copyRefusedStatus }, "\(r.body.statusText)")
        #expect(r.web.pasteboard.sets.isEmpty, "16 MiB + 1 writes nothing")
        #expect(r.body.statusText == "Copy failed: over 16 MiB")
        r.body.setStatus("")
        // The menu's Copy takes the text the page remembers for the context click.
        _ = try await pageJS(view, "window.ClawdChat.menuCopyText = () => 'a'.repeat(limit + 1); return 1;", ["limit": limit])
        view.menuCopy()
        #expect(await webWait { r.body.statusText == ChatWebPage.copyRefusedStatus }, "the menu's Copy: \(r.body.statusText)")
        #expect(r.web.pasteboard.sets.isEmpty, "nothing written by the menu either")
        r.body.setStatus("")
        _ = try await pageJS(view, selection, ["limit": limit, "extra": 0])
        r.body.copyPageSelection()
        #expect(await webWait { !r.web.pasteboard.sets.isEmpty }, "16 MiB is written")
        #expect(r.web.pasteboard.sets.first?.utf8.count == limit && r.body.statusText != ChatWebPage.copyRefusedStatus, "\(r.body.statusText)")
    }

    // MARK: Q19: the real session's id

    @Test func ChatOrcaD7a_theRealSessionHasNoIdBeforeItsInitTheInitsIdAfterAndAfterClearThePostClearInitsId() async throws {
        let rig = try ChatRig(stub: "replay.sh")
        #expect(rig.session.sessionID == nil, "before the first send")
        #expect(rig.session.send("one"))
        #expect(rig.session.sessionID == nil, "spawned, no init yet: the spawn's own id is not offered")
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(rig.session.sessionID == "00000000-0000-4000-8000-000000000001", "\(rig.session.sessionID ?? "nil")")
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none && rig.log.contains { $0.hasPrefix("CHAT sweep") } })
        #expect(rig.session.sessionID == "00000000-0000-4000-8000-000000000001", "kept across the child's end")

        let clear = try ChatRig(stub: "replay-clear.sh", permissions: .deny)
        #expect(clear.session.send("/clear"))
        #expect(await clear.wait { clear.outcomes.count == 1 })
        #expect(clear.session.sessionID == "00000000-0000-4000-8000-000000000096", "the post-clear init's id, not the reset's: \(clear.session.sessionID ?? "nil")")
        clear.session.stop(.userStop)
        #expect(await clear.wait { clear.session.turn == .none && clear.log.contains { $0.hasPrefix("CHAT sweep") } })
    }

    @Test func ChatOrcaD7a_aResumedChildThatEndsBeforeItsInitIsResumedAgainNotForked() async throws {
        let rig = try ChatRig(stub: "resume-fork.sh")
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        let id = try #require(rig.session.sessionID)
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none && rig.log.contains { $0.hasPrefix("CHAT sweep") } })
        #expect(rig.session.send("two"), "the resume spawn")
        #expect(await rig.wait { rig.spawns == 2 && !rig.childAlive })
        #expect(rig.session.sessionID == id, "the id is the conversation's, whatever the child did")
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none })
        #expect(rig.session.send("three"), "the next spawn")
        #expect(await rig.wait { rig.spawns == 3 })
        let argsFile = rig.folder + "/spawn-args.log"
        let read = { (try? String(contentsOfFile: argsFile, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? [] }
        #expect(await rig.wait { read().count == 3 })
        let lines = read()
        #expect(lines.count == 3, "\(lines)")
        #expect(lines.count == 3 && lines[1].contains("--resume \(id) ") && lines[2].contains("--resume \(id) "), "both later spawns resume \(id): \(lines)")
        #expect(!lines.dropFirst().contains { $0.contains("--session-id") }, "never a fresh conversation: \(lines)")
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none })
    }

    @Test func ChatOrcaD7a_aResumeTheCliRefusesIsDroppedSoTheChatStartsAgainAndTheSendIsNotLost() async throws {
        let rig = try ChatRig(stub: "resume-refused.sh")
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        let id = try #require(rig.session.sessionID)
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none && rig.log.contains { $0.hasPrefix("CHAT sweep") } })
        var settled: [ChatSendVerdict] = []
        var returned: [String] = []
        rig.session.onSendSettled = { settled.append($0) }
        rig.session.onSendFailed = { returned.append($0) }
        #expect(rig.session.send("two"), "the resume spawn meets the refusal")
        #expect(await rig.wait { rig.outcomes.count == 2 && rig.session.turn == .none })
        #expect(rig.outcomes.last == .error)
        #expect(rig.log.contains("CHAT resume refused session=\(id.prefix(8))"), "\(rig.log)")
        #expect(rig.session.sessionID == nil, "the refused id is dropped")
        let entries = rig.session.transcript.entries
        #expect(entries.contains { $0.kind == .error && $0.text == "Claude Code stopped (exit 1)" })
        #expect(entries.contains { $0.kind == .notice && $0.text.contains("No conversation found") }, "the CLI's own words stay in the transcript")
        #expect(await rig.wait { !rig.childAlive && rig.session.turn == .none })
        // The send that met the refusal is not sent again behind Tom's back and not dropped: it is Tom's to resend, as after any child that ends mid-turn
        // (a doubt card when its line was written, handed back to the draft when it was not).
        let held = settled.contains { if case .doubt(let e, _) = $0 { return e.text == "two" } else { return false } } || returned == ["two"]
        #expect(held, "settled \(settled), returned \(returned)")
        #expect(rig.session.send("three"), "the next send starts a fresh conversation")
        #expect(await rig.wait { rig.spawns == 3 })
        let argsFile = rig.folder + "/spawn-args.log"
        let read = { (try? String(contentsOfFile: argsFile, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? [] }
        #expect(await rig.wait { read().count == 3 })
        let lines = read()
        #expect(lines.count == 3 && lines[1].contains("--resume \(id) "), "\(lines)")
        #expect(lines.count == 3 && lines[2].contains("--session-id ") && !lines[2].contains("--resume") && !lines[2].contains(id), "a new id, no resume: \(lines)")
        #expect(await rig.wait { rig.outcomes.count == 3 })
        #expect(rig.outcomes.last != .error, "the fresh chat answers: \(rig.outcomes)")
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none })
    }

    // MARK: Q23: the pet-drop refusal once per drag

    private func petView() -> PetView {
        let view = PetView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.opaqueBody = { $0.x < 20 }
        return view
    }

    @Test func ChatOrcaD7a_theRefusalIsComputedOncePerDragNotOncePerUpdate() {
        let view = petView()
        var calls = 0
        view.dropRefusal = { calls += 1; return nil }
        let drag = FakeDrag(DragBoard(files: ["/a"]), at: CGPoint(x: 5, y: 5))
        #expect(view.destination.draggingEntered?(drag) == .copy)
        for _ in 0..<50 { #expect(view.destination.draggingUpdated?(drag) == .copy) }
        #expect(calls == 1, "entered plus 50 updated: \(calls)")
        #expect(view.destination.performDragOperation?(drag) == true)
        #expect(calls == 2, "the drop computes it once more: \(calls)")
    }

    @Test func ChatOrcaD7a_aDragThatEntersOverATransparentPixelComputesItWhenItReachesTheBody() {
        let view = petView()
        var calls = 0
        view.dropRefusal = { calls += 1; return nil }
        let board = DragBoard(files: ["/a"])
        #expect(view.destination.draggingEntered?(FakeDrag(board, at: CGPoint(x: 30, y: 5))) == [])
        for _ in 0..<5 { _ = view.destination.draggingUpdated?(FakeDrag(board, at: CGPoint(x: 30, y: 5))) }
        #expect(calls == 0, "over a transparent pixel nothing is asked: \(calls)")
        for _ in 0..<5 { #expect(view.destination.draggingUpdated?(FakeDrag(board, at: CGPoint(x: 5, y: 5))) == .copy) }
        #expect(calls == 1, "\(calls)")
    }

    @Test func ChatOrcaD7a_aNewDragAsksAgainAndPrepareAndPerformShareOneAnswer() {
        let view = petView()
        var calls = 0, refusal: String?
        view.dropRefusal = { calls += 1; return refusal }
        let drag = FakeDrag(DragBoard(files: ["/a"]), at: CGPoint(x: 5, y: 5))
        _ = view.destination.draggingEntered?(drag)
        _ = view.destination.draggingUpdated?(drag)
        refusal = "quiet"
        #expect(view.destination.draggingUpdated?(drag) == .copy, "the hover keeps the answer it had")
        #expect(view.destination.prepareForDragOperation?(drag) == false, "a state change during the hover is honoured at the drop")
        #expect(view.destination.performDragOperation?(drag) == false)
        #expect(calls == 2, "entered, then prepare; perform reuses prepare's answer: \(calls)")
        view.destination.draggingEnded?(drag)
        refusal = nil
        _ = view.destination.draggingEntered?(drag)
        #expect(calls == 3 && view.destination.draggingUpdated?(drag) == .copy, "ended and entered again: a new drag asks again: \(calls)")
        view.destination.draggingExited?(drag)
        _ = view.destination.draggingEntered?(drag)
        #expect(calls == 4, "\(calls)")
    }

    @Test func ChatOrcaD7a_aRefusalThatAppearsDuringTheHoverIsLoggedOnceAtTheDropAndNotTwice() {
        let view = petView()
        var refusal: String?
        var logged: [String] = []
        view.dropRefusal = { refusal }
        view.dropRefused = { logged.append($0) }
        let drag = FakeDrag(DragBoard(files: ["/a"]), at: CGPoint(x: 5, y: 5))
        _ = view.destination.draggingEntered?(drag)
        _ = view.destination.draggingUpdated?(drag)
        refusal = "exam"
        #expect(view.destination.draggingUpdated?(drag) == .copy && logged.isEmpty, "the hover keeps its answer")
        #expect(view.destination.prepareForDragOperation?(drag) == false)
        #expect(view.destination.performDragOperation?(drag) == false)
        #expect(logged == ["exam"], "the reason is logged once: \(logged)")

        logged.removeAll()
        refusal = "exam"
        view.destination.draggingExited?(drag)
        #expect(view.destination.draggingEntered?(drag) == [] && logged == ["exam"], "refused at the entry: logged there")
        #expect(view.destination.prepareForDragOperation?(drag) == false)
        #expect(logged == ["exam"], "and not again at the drop: \(logged)")
    }

    // MARK: Q24: a queued drop gets its 120 s from the start of its own copy

    @Test func ChatOrcaD7a_aDropBehindAHungCopyArmsItsDeadlineWhenItsOwnCopyStarts() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let a = try r.providerFile("a.txt"), b = try r.providerFile("b.txt")
        let timeout = DragTempCopier.dropTimeout
        r.drop(DragBoard(files: [a]))
        r.drop(DragBoard(files: [b]))
        #expect(r.rig.focus.timers.live.filter { $0 == timeout }.count == 1,
                "drop 2 is queued behind the hung copy: only drop 1's deadline runs: \(r.rig.focus.timers.live)")
        r.rig.focus.timers.fire(exactly: timeout)
        #expect(r.rig.lines("CHAT drop").count == 1 && r.rig.lines("CHAT drop")[0].contains("refused=copy-failed"), "drop 1 timed out: \(r.rig.lines("CHAT drop"))")
        #expect(r.rig.focus.timers.live.filter { $0 == timeout }.count == 1, "drop 2's own copy started, with a fresh deadline: \(r.rig.focus.timers.live)")
        #expect(r.rig.lines("CHAT drop").count == 1, "drop 2 has not timed out when drop 1 does")
        r.rig.focus.timers.fire(exactly: timeout)
        let drops = r.rig.lines("CHAT drop")
        #expect(drops.count == 2 && drops[1].contains("refused=copy-failed"), "drop 2 times out 120 s after drop 1's timeout: \(drops)")
    }

    // MARK: Q27: the title bar's grab cursor

    private func titleBar(_ events: Events) -> ChatTitleBarView {
        let bar = ChatTitleBarView(frame: CGRect(x: 0, y: 0, width: 400, height: 36))
        bar.cursorSink = { events.log.append($0 === NSCursor.closedHand ? "closed" : ($0 === NSCursor.openHand ? "open" : ($0 === NSCursor.arrow ? "arrow" : "other"))) }
        bar.onGesture = { [unowned bar] gesture in
            switch gesture {
            case .toggleMaximize: events.log.append("toggle"); events.rectsDuringToggle = bar.cursorRectCursor
            case .begin: events.log.append("begin")
            case .end: events.log.append("end")
            default: break
            }
        }
        return bar
    }
    final class Events { var log: [String] = []; var rectsDuringToggle: NSCursor? }

    private func click(_ type: NSEvent.EventType, clicks: Int) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    @Test func ChatOrcaD7a_aDoubleClicksSecondPressShowsTheClosedHandAfterTheToggleHasRun() {
        let events = Events()
        let bar = titleBar(events)
        bar.mouseDown(with: click(.leftMouseDown, clicks: 2))
        #expect(events.log == ["toggle", "closed"], "the closed hand comes after the toggle: \(events.log)")
        #expect(events.rectsDuringToggle === NSCursor.closedHand, "the rects the toggle rebuilds already carry the closed hand")
        bar.mouseUp(with: click(.leftMouseUp, clicks: 2))
        #expect(bar.cursorRectCursor === NSCursor.openHand && !bar.pressed, "the open hand is back at mouse-up")
    }

    @Test func ChatOrcaD7a_aSinglePressStillBeginsTheDragWithTheClosedHandAndMouseUpRestoresTheOpenHand() {
        let events = Events()
        let bar = titleBar(events)
        #expect(bar.cursorRectCursor === NSCursor.openHand && ChatTitleBarView.barCursor === NSCursor.openHand)
        bar.mouseDown(with: click(.leftMouseDown, clicks: 1))
        #expect(events.log == ["begin", "closed"] && bar.cursorRectCursor === NSCursor.closedHand, "\(events.log)")
        bar.mouseUp(with: click(.leftMouseUp, clicks: 1))
        #expect(events.log == ["begin", "closed", "end", "arrow"] && bar.cursorRectCursor === NSCursor.openHand, "no window, no pointer over the bar: \(events.log)")
    }

    @Test func ChatOrcaD7a_theRectsTheBarAddsCarryTheClosedHandWhileAPressLastsAndTheOpenHandOtherwise() {
        let events = Events()
        let bar = titleBar(events)
        bar.resetCursorRects()
        #expect(!bar.addedCursorRects.isEmpty && bar.addedCursorRects.allSatisfy { $0.cursor === NSCursor.openHand }, "idle: the open hand")
        bar.mouseDown(with: click(.leftMouseDown, clicks: 1))
        bar.resetCursorRects()
        #expect(!bar.addedCursorRects.isEmpty && bar.addedCursorRects.allSatisfy { $0.cursor === NSCursor.closedHand }, "a rebuild during the press: the closed hand")
        bar.mouseUp(with: click(.leftMouseUp, clicks: 1))
        bar.resetCursorRects()
        #expect(bar.addedCursorRects.allSatisfy { $0.cursor === NSCursor.openHand }, "after the up: the open hand again")
    }

    @Test func ChatOrcaD7a_mouseUpPutsACursorBackTheOpenHandOverTheEmptyBarElseTheArrow() {
        let events = Events()
        let bar = titleBar(events)
        let tab = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 36))
        bar.addSubview(tab)
        var pointer: CGPoint? = CGPoint(x: 250, y: 10)
        bar.pointerSource = { pointer }
        // A double-click's second press moves the bar; the up lands where it is no more.
        bar.mouseDown(with: click(.leftMouseDown, clicks: 2))
        pointer = CGPoint(x: 250, y: 500)
        bar.mouseUp(with: click(.leftMouseUp, clicks: 2))
        #expect(events.log == ["toggle", "closed", "arrow"], "off the bar the arrow goes back: \(events.log)")
        events.log.removeAll()
        bar.mouseDown(with: click(.leftMouseDown, clicks: 1))
        bar.mouseUp(with: click(.leftMouseUp, clicks: 1))
        #expect(events.log.last == "arrow", "the pointer is still off the bar: \(events.log)")
        events.log.removeAll()
        pointer = CGPoint(x: 250, y: 10)
        bar.mouseDown(with: click(.leftMouseDown, clicks: 1))
        bar.mouseUp(with: click(.leftMouseUp, clicks: 1))
        #expect(events.log.last == "open", "over the empty bar the open hand goes back: \(events.log)")
        events.log.removeAll()
        pointer = CGPoint(x: 50, y: 10)
        bar.mouseDown(with: click(.leftMouseDown, clicks: 1))
        bar.mouseUp(with: click(.leftMouseUp, clicks: 1))
        #expect(events.log.last == "arrow", "over the tab the bar's cursor is not the tab's: \(events.log)")
    }
}
