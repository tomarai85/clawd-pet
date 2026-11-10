import Testing
import Foundation
import AppKit
import WebKit
import ClawdCore
import ClawdDesktop

// Orca parity round B, P4 (image paste), P5 (right-click menus) and P10 (the per-message copy button). The pasteboard of the chat is a fake; the
// real one is never read or written. Menus are built and inspected, never shown.

@Suite("ChatOrcaParityB paste and menus", .serialized)
@MainActor
struct ChatPasteMenuSuite {
    // MARK: P4: image paste

    private func imageOnly(_ r: AttachRig, _ data: Data) { r.setPaste(ChatPasteContents(hasText: false, image: data)) }

    @Test func ChatPaste_anImageOnlyPasteboardBecomesAPngUnderChatPastesAndAChipHoldsItAndTheTextIsLeftAlone() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.body.inputText = "abcd"
        r.input.setSelectedRange(NSRange(location: 2, length: 0))
        imageOnly(r, pngData())
        r.input.paste(nil)
        #expect(r.input.string == "abcd", "the encode and write run off the main thread, and the image never goes into the text")
        #expect(r.body.composer.chips.items.map(\.kind) == [.pending], "a pending chip at once")
        r.background.runAll()
        let name = "clawd-paste-1700000000123-11111111-2222-3333-4444-555555555555.png"
        let path = r.root.appendingPathComponent("chat-pastes/" + name).path
        #expect(r.input.string == "abcd" && r.body.composer.chips.items.map(\.kind) == [.file(path)], "\(r.input.string) \(r.body.composer.chips.items)")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(Array(bytes.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG magic bytes")
        #expect(r.rig.lines("CHAT paste-image").last?.hasSuffix("result=ok") == true, "\(r.rig.lines("CHAT paste-image"))")
    }

    @Test func ChatPaste_aPasteboardWithTextAndAnImageIsNotTakenAsAnImage() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let session = try #require(r.controller.livePanel).terminal?.webBody?.attachments
        r.setPaste(ChatPasteContents(hasText: true, image: pngData()))
        #expect(session?.pasteImageIfAny() == false, "the text paste goes on as it always did")
        #expect(r.background.pending.isEmpty && r.state.entries(of: "chat-pastes").isEmpty)
    }

    @Test func ChatPaste_anImageOverThirtyTwoMiPixelsGivesTheTooLargeStatusAndNoFile() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let huge = monochromePNG(width: 5_793, height: 5_793)        // 33,558,849 pixels, 4 more than 32 Mi: a few KB on disk
        imageOnly(r, huge)
        r.input.paste(nil)
        r.background.runAll()
        #expect(r.body.statusText == "Clipboard image is too large", "\(r.body.statusText) \(r.rig.lines("CHAT paste-image")) \(String(describing: ClipboardImage.pixelSize(of: huge)))")
        #expect(r.state.entries(of: "chat-pastes").isEmpty && r.input.string.isEmpty)
        #expect(r.rig.lines("CHAT paste-image").last?.hasSuffix("result=too-large") == true, "\(r.rig.lines("CHAT paste-image"))")
        let size = ClipboardImage.pixelSize(of: monochromePNG(width: 5_792, height: 5_792))
        #expect(size.map { ClipboardImage.pixelsAcceptable(width: $0.width, height: $0.height) } == true, "5792 x 5792 is under the cap")
        // Exactly 32 Mi pixels is taken (the pixel rule alone).
        #expect(ClipboardImage.pixelsAcceptable(width: 33_554_432, height: 1) && !ClipboardImage.pixelsAcceptable(width: 33_554_433, height: 1))
        #expect(!ClipboardImage.pixelsAcceptable(width: 0, height: 5) && !ClipboardImage.pixelsAcceptable(width: Int.max, height: 2))
    }

    @Test func ChatPaste_aPngOverEighteenMiBGivesTheSameStatusAndNoFile() throws {
        let r = try AttachRig(encoder: { _ in Data(count: 18_874_369) })
        defer { r.cleanUp() }
        try r.open()
        imageOnly(r, pngData())
        r.input.paste(nil)
        r.background.runAll()
        #expect(r.body.statusText == "Clipboard image is too large" && r.state.entries(of: "chat-pastes").isEmpty && r.input.string.isEmpty, "\(r.body.statusText)")
        let ok = try AttachRig(encoder: { _ in Data(pngData()) })
        defer { ok.cleanUp() }
        try ok.open()
        imageOnly(ok, pngData())
        ok.input.paste(nil)
        ok.background.runAll()
        #expect(ok.state.entries(of: "chat-pastes").count == 1, "the cap is 18,874,368 bytes: one under it is taken")
    }

    @Test func ChatPaste_anEncoderThatFailsShowsImagePasteFailed() throws {
        let r = try AttachRig(encoder: { _ in nil })
        defer { r.cleanUp() }
        try r.open()
        imageOnly(r, pngData())
        r.input.paste(nil)
        r.background.runAll()
        #expect(r.body.statusText == "Image paste failed." && r.input.string.isEmpty, "\(r.body.statusText)")
    }

    @Test func ChatPaste_theSweepRemovesA31DayFileAndKeepsA29DayFileOtherNamesAndLinks() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try r.state.write(Data("a".utf8), to: "chat-pastes/clawd-paste-1-A.png")
        try r.state.write(Data("b".utf8), to: "chat-pastes/clawd-paste-2-B.png")
        try r.state.write(Data("c".utf8), to: "chat-pastes/notes.txt")
        try r.state.write(Data("d".utf8), to: "chat-pastes/clawd-paste-3-D.jpg")
        let dir = r.root.appendingPathComponent("chat-pastes")
        func age(_ name: String, days: Double) throws {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86_400)], ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        try age("clawd-paste-1-A.png", days: 31); try age("clawd-paste-2-B.png", days: 29); try age("notes.txt", days: 90); try age("clawd-paste-3-D.jpg", days: 90)
        let outside = r.root.appendingPathComponent("outside.png")
        try Data("x".utf8).write(to: outside)
        let link = dir.appendingPathComponent("clawd-paste-9-L.png").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside.path)
        var times = [timeval(tv_sec: Int(now.timeIntervalSince1970) - 90 * 86_400, tv_usec: 0), timeval(tv_sec: Int(now.timeIntervalSince1970) - 90 * 86_400, tv_usec: 0)]
        #expect(lutimes(link, &times) == 0)
        ClipboardImage.sweep(in: r.state, now: now)
        let left = Set(r.state.entries(of: "chat-pastes").map(\.name))
        #expect(left == ["clawd-paste-2-B.png", "notes.txt", "clawd-paste-3-D.jpg", "clawd-paste-9-L.png"], "\(left)")
        #expect(FileManager.default.fileExists(atPath: outside.path), "a link's target is never touched")
    }

    @Test func ChatPaste_aPastedFileSurvivesTheCloseAndTheIdleStop() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        imageOnly(r, pngData())
        r.input.paste(nil)
        r.background.runAll()
        let before = r.state.entries(of: "chat-pastes").map(\.name)
        #expect(before.count == 1)
        r.controller.close(.button)
        r.rig.timer.onFire?()
        #expect(r.rig.session.stops == [.panelClosedLong], "the child was stopped by the idle timer: \(r.rig.session.stops)")
        #expect(r.state.entries(of: "chat-pastes").map(\.name) == before, "nothing is cleaned at close or when the child stops")
        #expect(r.controller.composerStore?.content.chips?.first?.path?.contains("clawd-paste-") == true, "the draft still names the file as a chip")
        try r.open()
        #expect(r.state.entries(of: "chat-pastes").map(\.name) == before && r.body.composer.chips.items.count == 1, "the sweep at the next open keeps a file the draft names")
    }

    @Test func ChatPaste_aPasteWhoseOpeningClosedMeanwhileInsertsNothingAndKeepsTheFile() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        imageOnly(r, pngData())
        r.input.paste(nil)
        r.controller.close(.button)
        r.background.runAll()
        #expect(r.controller.draft.isEmpty && r.state.entries(of: "chat-pastes").count == 1)
    }

    // MARK: P5: menus

    private func rightDown() -> NSEvent { mouseEvent(.rightMouseDown) }

    @Test func ChatMenu_theTranscriptsMenuIsExactlyCopyAndPasteAndCopyFollowsTheSelectionFlag() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let page = try #require(r.body.page), view = try #require(page.view)
        let menu = NSMenu()
        menu.addItem(withTitle: "Look Up", action: nil, keyEquivalent: "")
        view.willOpenMenu(menu, with: rightDown())
        try #require(menu.items.map(\.title) == ["Copy", "Paste"], "WebKit's items are replaced by Orca's two: \(menu.items.map(\.title))")
        try #require(menu.items.count > 1, "menu.items needs 2 elements: \(menu.items.count)")
        #expect(menu.items[0].keyEquivalent == "c" && menu.items[1].keyEquivalent.isEmpty, "only Copy shows its shortcut (Orca's menu gives only Copy a DropdownMenuShortcut)")
        try #require(menu.items.count > 0, "menu.items needs 1 elements: \(menu.items.count)")
        #expect(!menu.items[0].isEnabled, "no selection: Copy is off")
        page.received(["type": "selection", "has": true])
        let on = NSMenu(); view.willOpenMenu(on, with: rightDown())
        try #require(on.items.count == 2)
        try #require(on.items.count > 1, "on.items needs 2 elements: \(on.items.count)")
        #expect(on.items[0].isEnabled && on.items[1].isEnabled)
        page.received(["type": "selection", "has": false])
        let off = NSMenu(); view.willOpenMenu(off, with: rightDown())
        try #require(off.items.count == 2)
        try #require(off.items.count > 0, "off.items needs 1 elements: \(off.items.count)")
        #expect(!off.items[0].isEnabled)
        #expect(view.menu(for: rightDown()) == nil, "WKWebView shows its menu only through willOpenMenu")
    }

    @Test func ChatMenu_aSelectionMessageWithANonBoolValueOrExtraKeysIsIgnored() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let page = try #require(r.body.page), view = try #require(page.view)
        for bad: [String: Any] in [["type": "selection", "has": "yes"], ["type": "selection", "has": 1], ["type": "selection", "has": true, "text": "secret"],
                                   ["type": "selection"], ["type": "selection", "has": NSNull()]] {
            page.received(bad)
            #expect(!view.hasSelection, "ignored: \(bad)")
        }
        page.received(["type": "selection", "has": true])
        #expect(view.hasSelection)
    }

    @Test func ChatMenu_choosingCopyPutsTheRememberedSelectionOnThePasteboardAndAnEmptyOneNothing() async throws {
        let rig = WebPageRig()
        #expect(await rig.loadAndWaitReady())
        let view = try #require(rig.page.view)
        rig.page.menuCopy(to: rig.pasteboard, refused: {})
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig.pasteboard.sets.isEmpty, "an empty answer puts nothing: \(rig.pasteboard.sets)")
        _ = try await pageJS(view, "return window.ClawdChat.apply({order: [1], upserts: [{id: 1, kind: 'assistant', text: 'abc def'}], turn: 'none'});")
        // Select the text, then a right press: the press-time selection is remembered even when the selection goes away before Copy.
        _ = try await pageJS(view, "const s = window.getSelection(); s.removeAllRanges(); const r = document.createRange(); r.selectNodeContents(document.querySelector('.native-chat-markdown p')); s.addRange(r); return 1;")
        #expect(await webWait { view.hasSelection }, "the page posts `selection has=true`")
        _ = try await pageJS(view, "document.querySelector('.assistant-row').dispatchEvent(new MouseEvent('mousedown', {button: 2, bubbles: true, cancelable: true})); window.getSelection().removeAllRanges(); return 1;")
        rig.page.menuCopy(to: rig.pasteboard, refused: {})
        #expect(await webWait { !rig.pasteboard.sets.isEmpty })
        #expect(rig.pasteboard.sets == ["abc def"], "\(rig.pasteboard.sets)")
    }

    @Test func ChatMenu_aRightMouseDownInThePageIsStoppedInTheCapturePhase() async throws {
        let rig = WebPageRig()
        #expect(await rig.loadAndWaitReady())
        let view = try #require(rig.page.view)
        let result = try await pageJS(view, """
            let seen = 0;
            document.querySelector('#column').addEventListener('mousedown', () => { seen += 1; });
            const down = new MouseEvent('mousedown', {button: 2, bubbles: true, cancelable: true});
            document.querySelector('#column').dispatchEvent(down);
            const left = new MouseEvent('mousedown', {button: 0, bubbles: true, cancelable: true});
            document.querySelector('#column').dispatchEvent(left);
            return [seen, down.defaultPrevented, left.defaultPrevented];
            """)
        let values = try #require(result as? [Any])
        #expect(values.map { "\($0)" } == ["1", "1", "0"], "the right press is stopped and prevented, the left one is not: \(values)")
    }

    @Test func ChatMenu_theComposersMenuIsCopyAndPasteAndCopyFollowsTheSelection() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let input = r.input
        let empty = try #require(input.menu(for: rightDown()))
        try #require(empty.items.count > 1, "empty.items needs 2 elements: \(empty.items.count)")
        #expect(empty.items.map(\.title) == ["Copy", "Paste"] && !empty.items[0].isEnabled && empty.items[1].isEnabled)
        try #require(empty.items.count > 1, "empty.items needs 2 elements: \(empty.items.count)")
        #expect(empty.items[0].keyEquivalent == "c" && empty.items[1].keyEquivalent.isEmpty, "Paste shows no shortcut; Cmd+V pastes through the key handler, not the menu")
        try #require(empty.items.count > 0, "empty.items needs 1 elements: \(empty.items.count)")
        #expect(empty.items[0].action == #selector(NSText.copy(_:)) && empty.items[0].target === input)
        try #require(empty.items.count > 1, "empty.items needs 2 elements: \(empty.items.count)")
        #expect(empty.items[1].action == #selector(NSText.paste(_:)) && empty.items[1].target === input)
        input.string = "some text"
        input.setSelectedRange(NSRange(location: 0, length: 4))
        let items = try #require(input.menu(for: rightDown())?.items, "the input has a menu")
        try #require(items.count > 0, "items needs 1 element: \(items.count)")
        #expect(items[0].isEnabled == true)
        #expect(input.assignedMenu == nil && input.menu == nil, "the assigned menu stays nil")
        #expect(input.contextMenuTitles == ["Copy", "Paste"])
    }

    @Test func ChatMenu_theStreamViewsInputKeepsItsNoMenuRule() {
        let rig = ControllerRig()
        rig.open()
        #expect(rig.view.inputView.menu(for: rightDown()) == nil && rig.view.inputView.contextMenuTitles == nil)
    }

    @Test func ChatMenu_theAuditRefusesAnInputWithAnAssignedMenu() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        #expect(r.body.auditProblems().isEmpty)
        r.input.menu = NSMenu(title: "assigned")
        #expect(r.body.auditProblems().contains("input has a context menu"), "\(r.body.auditProblems())")
    }

    @Test func ChatMenu_aMenuPasteWithAnImageOnlyPasteboardGoesThroughTheImagePaste() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        imageOnly(r, pngData())
        let item = try #require(r.input.menu(for: rightDown())?.items.last)
        _ = NSApp  // the action is the text view's own paste(_:)
        r.input.perform(item.action!, with: nil)
        r.background.runAll()
        guard case .file(let first)? = r.body.composer.chips.items.first?.kind else { Issue.record("a chip: \(r.body.composer.chips.items)"); return }
        #expect(first.contains("/chat-pastes/clawd-paste-") && r.input.string.isEmpty, "\(first) \(r.input.string)")
        // The transcript's menu Paste goes to the composer too.
        r.input.string = "xy"
        let view = try #require(r.body.page?.view)
        view.menuPaste()
        r.background.runAll()
        #expect(r.body.composer.chips.items.count == 2 && r.input.string == "xy", "\(r.body.composer.chips.items) \(r.input.string)")
    }

    @Test func ChatMenu_theTabsMenuIsCloseWithTheShortcutAndLogsThenClosesWithReasonButton() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let tab = try #require(r.web.panel?.terminal?.tab)
        let menu = try #require(tab.menu(for: rightDown()))
        try #require(menu.items.map(\.title) == ["Close"], "\(menu.items.map(\.title))")
        try #require(menu.items.count > 0, "menu.items needs 1 elements: \(menu.items.count)")
        #expect(menu.items[0].keyEquivalent == "w")
        let item = menu.items[0]
        _ = (item.target as? NSObject)?.perform(item.action!)
        #expect(!r.controller.isOpen)
        #expect(r.rig.lines("CHAT tab-menu close gen=1").count == 1 && r.rig.lines("CHAT close reason=button gen=1").count == 1, "\(r.rig.lines("CHAT"))")
    }

    @Test func ChatMenu_aMenuPasteAndACopyLeaveThePanelOpenAndItsKeyStateUnchanged() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let keys = r.rig.keys.count, activations = r.rig.focus.activationRequests
        let view = try #require(r.body.page?.view)
        r.web.pasteboard.text = "hello"
        view.menuPaste()
        view.menuCopy()
        #expect(r.controller.isOpen && r.rig.keys.count == keys && r.rig.focus.activationRequests == activations)
    }

    // MARK: P10: the copy button

    private func openWithMessage(_ r: AttachRig) throws -> (Int, ChatWebPage) {
        try r.open()
        r.rig.session.transcript.appendUser("hello there")
        r.rig.session.onChange?()
        let id = try #require(r.rig.session.transcript.entries.first?.id)
        return (id, try #require(r.body.page))
    }

    @Test func ChatCopy_aCopyAfterAClickPutsTheEntrysTextOnThePasteboardAndTellsThePage() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        let (id, page) = try openWithMessage(r)
        r.web.controller.livePanel?.recordMouseDown(at: r.rig.clock.now, left: true)
        page.received(["type": "copy", "id": id])
        #expect(r.web.pasteboard.sets == ["hello there"] && page.copiedIDs == [id], "\(r.web.pasteboard.sets) \(page.copiedIDs)")
    }

    @Test func ChatCopy_anUnknownIdACopyAfterTheClickWindowAndARefusedWriteEachDoNothing() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        let (id, page) = try openWithMessage(r)
        let panel = try #require(r.controller.livePanel)
        panel.recordMouseDown(at: r.rig.clock.now, left: true)
        page.received(["type": "copy", "id": id + 99])
        #expect(r.web.pasteboard.sets.isEmpty && page.copiedIDs.isEmpty, "an unknown id")
        r.rig.clock.advance(1.1)
        page.received(["type": "copy", "id": id])
        #expect(r.web.pasteboard.sets.isEmpty && page.copiedIDs.isEmpty, "1.1 s after the click")
        panel.recordMouseDown(at: r.rig.clock.now, left: true)
        r.web.pasteboard.refuseWrites = true
        page.received(["type": "copy", "id": id])
        #expect(r.web.pasteboard.sets.isEmpty && page.copiedIDs.isEmpty, "a pasteboard that refuses the write")
        r.web.pasteboard.refuseWrites = false
        page.received(["type": "copy", "id": id])
        #expect(page.copiedIDs == [id], "the same click is good for it once the write works")
    }

    @Test func ChatCopy_aScriptWithNoClickCannotWriteThePasteboard() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        let (id, page) = try openWithMessage(r)
        page.received(["type": "copy", "id": id])
        #expect(r.web.pasteboard.sets.isEmpty && page.copiedIDs.isEmpty, "no mouse-down on the panel at all")
        page.received(["type": "copy", "id": "1"])
        page.received(["type": "copy", "id": 1.5])
        page.received(["type": "copy", "id": true])
        page.received(["type": "copy", "id": id, "text": "x"])
        #expect(r.web.pasteboard.sets.isEmpty)
    }
}
