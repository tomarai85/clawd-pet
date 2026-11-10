import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop

// Orca parity round B, P2 and P3: the chat is a file drop target (the right receiving views, Orca's overlay, `@path` insertion with Orca's quoting,
// the IME hold, the limits and the drag-temp copies) and the "+" control picks one file. Every drag is delivered to the destination view's own methods.

@Suite("ChatOrcaParityB drops", .serialized)
@MainActor
struct ChatDropSuite {
    private static let eight = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: B1: which view receives the drag

    @Test func ChatDrop_theWebViewRefusesEveryRegistrationAndTheBodyTakesFileDrops() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let web = try #require(r.body.page?.view)
        #expect(web.registeredDraggedTypes.isEmpty, "\(web.registeredDraggedTypes)")
        web.registerForDraggedTypes([.fileURL, .URL])
        #expect(web.registeredDraggedTypes.isEmpty, "a registration is refused: \(web.registeredDraggedTypes)")
        for type in ChatDropContent.registeredTypes { #expect(r.body.registeredDraggedTypes.contains(type), "the body is registered for \(type)") }
        #expect(r.body.auditProblems().isEmpty, "\(r.body.auditProblems())")
    }

    @Test func ChatDrop_aDragOverTheTranscriptTheHandlesAndTheComposerReachesTheRightViewAndInsertsTheReferences() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let panel = try #require(r.web.panel), container = try #require(panel.terminal)
        let web = try #require(r.body.page?.view)
        container.layoutSubtreeIfNeeded()
        func inContainer(_ rect: CGRect, from view: NSView) -> CGPoint { container.convert(CGPoint(x: rect.midX, y: rect.midY), from: view.superview) }
        let transcript = inContainer(web.frame, from: web)
        let handle = container.handle(.e)
        let onHandle = CGPoint(x: handle.frame.midX, y: container.bounds.midY)
        let scroll = try #require(r.input.enclosingScrollView)
        let composer = inContainer(scroll.frame, from: scroll)
        let viewAt = { (p: CGPoint) in dragDestination(in: container, at: container.convert(p, to: container.superview)) }
        let atTranscript = viewAt(transcript), atHandle = viewAt(onHandle), atComposer = viewAt(composer)
        #expect(atTranscript === r.body, "the transcript's drop is the body's: \(String(describing: atTranscript))")
        #expect(atHandle === r.body, "the resize handle's drop is the body's: \(String(describing: atHandle))")
        #expect(atComposer === r.input, "the composer's own drop is the input's: \(String(describing: atComposer))")
        for target in [atTranscript, atHandle, atComposer] {
            r.input.string = ""
            let board = DragBoard(files: ["/a/one.txt", "/a/two words.txt"])
            let drag = FakeDrag(board)
            let view = try #require(target)
            #expect(view.destination.draggingEntered?(drag) == .copy)
            #expect(view.destination.performDragOperation?(drag) == true)
            #expect(r.input.string == "@/a/one.txt @\"/a/two words.txt\" ", "\(type(of: view)): \(r.input.string)")
        }
    }

    // MARK: B5: the format and the insertion

    @Test func ChatDrop_theReferenceFormatIsOrcas() {
        #expect(ChatFileReference.format("/a/b.txt") == "@/a/b.txt")
        #expect(ChatFileReference.format("/a/b c.txt") == "@\"/a/b c.txt\"")
        #expect(ChatFileReference.format("/a/@b") == "@\"/a/@b\"")
        #expect(ChatFileReference.format("/a/\"q\".txt") == "@/a/\"q\".txt", "quotes alone need no quoting: only whitespace or @ do (Orca's test is /[\\s@]/)")
        #expect(ChatFileReference.format("/a/b \"q\".txt") == "@'/a/b \"q\".txt'")
        #expect(ChatFileReference.format("/a/b \"q'.txt") == "@\"/a/b \\\"q'.txt\"")
        // L1: JavaScript tests for the quote per UTF-16 code unit, so a quote followed by a combining mark is still a quote. (The values are built
        // outside #expect: the macro cannot re-lex a quote fused with an accent.)
        let accent = "\u{0301}"
        let quoteThenAccent = ChatFileReference.format("/a/b \"" + accent + ".txt")
        #expect(quoteThenAccent == "@'/a/b \"" + accent + ".txt'", "the quote is found under its accent, so the apostrophe form is used")
        let bothKinds = ChatFileReference.format("/a/b \"" + accent + "'.txt")
        #expect(bothKinds == "@\"/a/b \\\"" + accent + "'.txt\"", "and it is escaped under its accent")
        let apostropheThenAccent = ChatFileReference.format("/a/b '" + accent + ".txt")
        #expect(apostropheThenAccent == "@\"/a/b '" + accent + ".txt\"")
        #expect(ChatFileReference.format("/a/b\nc") == "@\"/a/b\nc\"")
        #expect(ChatFileReference.format("/a/b\u{00A0}c") == "@\"/a/b\u{00A0}c\"", "a no-break space is JavaScript whitespace")
        #expect(ChatFileReference.format("/a/b\u{3000}c") == "@\"/a/b\u{3000}c\"")
        #expect(ChatFileReference.text(for: ["/a", "/b c"]) == "@/a @\"/b c\" ")
        let long = "/" + String(repeating: "x", count: 3_999)
        #expect(ChatFileReference.format(long) == "@" + long)
    }

    @Test func ChatDrop_aLongPathIsInsertedWholeAndTwoPathsHaveOneSpaceBetweenAndOneAfter() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let long = "/" + String(repeating: "x", count: 3_999)
        r.drop(DragBoard(files: [long, "/b"]))
        #expect(r.input.string == "@\(long) @/b ", "\(r.input.string.count)")
    }

    @Test func ChatDrop_theReferencesGoAtTheCaretNeverReplaceASelectionAndOneUndoRemovesThem() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.body.inputText = "abcd"
        r.input.setSelectedRange(NSRange(location: 2, length: 0))
        r.drop(DragBoard(files: ["/x"]))
        #expect(r.input.string == "ab@/x cd" && r.input.selectedRange() == NSRange(location: 6, length: 0), "\(r.input.string) \(r.input.selectedRange())")
        r.input.undoManager?.undo()
        #expect(r.input.string == "abcd", "one Undo removes the insertion: \(r.input.string)")
        r.body.inputText = "cd"
        r.input.setSelectedRange(NSRange(location: 0, length: 2))
        r.drop(DragBoard(files: ["/x"]))
        #expect(r.input.string == "@/x cd", "the selection is not replaced: \(r.input.string)")
    }

    // MARK: B4: the limits

    @Test func ChatDrop_moreThan256PathsOrMoreThan256KiBInsertNothingAndSayWhy() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.drop(DragBoard(files: (0..<257).map { "/f/\($0)" }))
        #expect(r.input.string.isEmpty && r.body.statusText == "Drop contains too many files. Drop 256 or fewer files at a time.", "\(r.body.statusText)")
        let chunk = String(repeating: "y", count: 87_382)
        r.drop(DragBoard(files: ["/\(chunk)", "/\(chunk)", "/\(chunk)"]))
        let total = ["/\(chunk)", "/\(chunk)", "/\(chunk)"].reduce(0) { $0 + $1.utf8.count }
        #expect(total > 262_144 && r.input.string.isEmpty && r.body.statusText == "Drop path list is too large. Drop fewer files or use a shorter path list.", "\(total) \(r.body.statusText)")
        r.drop(DragBoard(files: (0..<256).map { "/f/\($0)" }))
        #expect(!r.input.string.isEmpty, "exactly 256 paths are taken")
        #expect(r.rig.lines("CHAT drop").contains { $0.contains("refused=too-many") } && r.rig.lines("CHAT drop").contains { $0.contains("refused=too-large") }, "\(r.rig.lines("CHAT drop"))")
    }

    @Test func ChatDrop_aListThatWouldTakeTheInputOverOneMiBIsRefusedWholeWithTheCapsStatus() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.body.inputText = String(repeating: "a", count: 1_048_570)
        r.drop(DragBoard(files: ["/a/b/c/d.txt"]))
        #expect(r.input.string.utf8.count == 1_048_570 && r.body.statusText == "Not inserted: the message would be over 1 MiB", "\(r.body.statusText)")
    }

    // MARK: B6: the input method

    @Test func ChatDrop_aDropDuringComposingTextIsHeldAndFollowsTheCommittedText() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let none = NSRange(location: NSNotFound, length: 0)
        r.input.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
        #expect(r.input.hasMarkedText())
        r.drop(DragBoard(files: ["/x"]))
        #expect(r.input.hasMarkedText() && r.input.string == "にほ", "nothing is inserted into the composition: \(r.input.string)")
        r.rig.focus.drain()
        #expect(r.input.string == "にほ", "still composing: it stays held")
        r.input.insertText("日本", replacementRange: none)
        #expect(r.input.string == "日本", "the references wait for the next turn")
        r.rig.focus.drain()
        #expect(r.input.string == "日本@/x ", "the references follow the committed text: \(r.input.string)")
    }

    @Test func ChatDrop_the257thWaitingPathIsRefusedWithTheWaitingText() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.input.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        r.drop(DragBoard(files: (0..<200).map { "/a/\($0)" }))
        r.drop(DragBoard(files: (0..<57).map { "/b/\($0)" }))
        #expect(r.body.statusText == "Too many attachments are waiting. Finish composing before attaching more.", "\(r.body.statusText)")
        r.input.insertText("日", replacementRange: NSRange(location: NSNotFound, length: 0))
        r.rig.focus.drain()
        #expect(r.input.string.contains("@/a/199 ") && !r.input.string.contains("/b/0"), "the refused batch is not applied, the first one is")
    }

    // MARK: B2: the overlay

    @Test func ChatDrop_theOverlayShowsOnEnteredStaysThroughUpdatedAndClearsOnExitedEndedAndPerform() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let overlay = r.body.dropOverlay
        #expect(!r.body.isDropOverlayShown && overlay.hitTest(CGPoint(x: 5, y: 5)) == nil && overlay.registeredDraggedTypes.isEmpty)
        let board = DragBoard(files: ["/a"])
        let drag = FakeDrag(board)
        #expect(r.body.destination.draggingEntered?(drag) == .copy && r.body.isDropOverlayShown)
        #expect(r.body.destination.draggingUpdated?(drag) == .copy && r.body.isDropOverlayShown)
        r.body.destination.draggingExited?(drag)
        #expect(!r.body.isDropOverlayShown)
        _ = r.body.destination.draggingEntered?(drag)
        r.body.destination.draggingEnded?(drag)
        #expect(!r.body.isDropOverlayShown)
        _ = r.body.destination.draggingEntered?(drag)
        _ = r.body.destination.performDragOperation?(drag)
        #expect(!r.body.isDropOverlayShown)
        // A drag of text only, or of a web address only, shows no overlay and gets no operation.
        for other in [DragBoard(string: "hello"), DragBoard(url: "https://example.com")] {
            let d = FakeDrag(other)
            #expect(r.body.destination.draggingEntered?(d) == [] && !r.body.isDropOverlayShown)
        }
    }

    @Test func ChatDrop_theOverlayCardHasOrcasWordsAndSitsInTheMiddle() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let overlay = r.body.dropOverlay
        r.body.frame = CGRect(x: 0, y: 0, width: 520, height: 300)
        r.body.layoutSubtreeIfNeeded()
        _ = r.body.destination.draggingEntered?(FakeDrag(DragBoard(files: ["/a"])))
        overlay.layoutSubtreeIfNeeded()
        var texts: [String] = []
        for card in overlay.subviews { for label in card.subviews { if let field = label as? NSTextField { texts.append(field.stringValue) } } }
        #expect(texts == ["Drop to attach to this chat", "Files are added to your message as paths the agent can read."], "\(texts)")
        let card = try #require(overlay.subviews.first)
        #expect(abs(card.frame.midX - overlay.bounds.midX) <= 1 && abs(card.frame.midY - overlay.bounds.midY) <= 1, "\(card.frame) in \(overlay.bounds)")
        #expect(overlay.layer?.backgroundColor != nil)
    }

    @Test func ChatDrop_aLockedInputShowsNoOverlayAndAnswersNoOperation() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.body.setInputLocked(true)
        let drag = FakeDrag(DragBoard(files: ["/a"]))
        #expect(r.body.destination.draggingEntered?(drag) == [] && !r.body.isDropOverlayShown)
        #expect(r.body.destination.performDragOperation?(drag) == false && r.input.string.isEmpty)
        r.body.setInputLocked(false)
        #expect(r.body.destination.draggingEntered?(drag) == .copy)
    }

    // MARK: B3: promises

    @Test func ChatDrop_aPromiseOnlyDropShowsTheOverlayInsertsNothingAndSaysItCouldNotReadAPath() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let drag = FakeDrag(DragBoard(promise: true))
        #expect(r.body.destination.draggingEntered?(drag) == .copy && r.body.isDropOverlayShown)
        #expect(r.body.destination.performDragOperation?(drag) == true)
        #expect(r.input.string.isEmpty && r.body.statusText == "Clawd couldn't read a path for the dropped files. Save them to disk first, then drop the saved files.")
        #expect(r.body.composer.statusToolTip == r.body.statusText, "the tooltip holds the full text")
        #expect(r.rig.lines("CHAT drop").last?.contains("refused=unresolved") == true, "\(r.rig.lines("CHAT drop"))")
    }

    @Test func ChatDrop_aStringDragOverTheComposerGoesToTheTextViewAndInsertsItsString() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let drag = FakeDrag(DragBoard(string: "plain words"))
        _ = r.input.destination.draggingEntered?(drag)
        _ = r.input.destination.performDragOperation?(drag)
        #expect(r.input.string.contains("plain words"), "a text drag keeps its own behaviour: \(r.input.string)")
    }

    // MARK: B8: drag-temp copies

    @Test func ChatDrop_aProviderFileIsCopiedIntoClawdsStorageAndTheCopysPathIsInserted() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let source = try r.providerFile("shot.png", contents: Data("pixels".utf8))
        r.drop(DragBoard(files: [source]))
        #expect(r.input.string.isEmpty && r.body.composer.chips.items.isEmpty, "nothing is inserted before the copy ends")
        r.background.runAll()
        // shot.png is an image, so its copy becomes a chip (Q14) and the input stays empty.
        guard case .file(let copy)? = r.body.composer.chips.items.first?.kind else { Issue.record("a chip of the copy: \(r.body.composer.chips.items) \(r.input.string)"); return }
        #expect(r.input.string.isEmpty && copy.hasSuffix("/shot.png"), "\(copy)")
        #expect(copy.contains("/chat-drops/clawd-drop-") && !copy.contains(source), "\(copy)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: copy)) == Data("pixels".utf8))
        var info = stat()
        #expect(lstat(copy, &info) == 0 && info.st_mode & 0o777 == 0o600, "mode \(String(info.st_mode & 0o777, radix: 8))")
        var dir = stat()
        #expect(lstat((copy as NSString).deletingLastPathComponent, &dir) == 0 && dir.st_mode & 0o777 == 0o700)
        #expect(r.rig.lines("CHAT drop").last?.contains("copied=1") == true, "\(r.rig.lines("CHAT drop"))")
    }

    @Test func ChatDrop_aLookalikeOutsideTheTemporaryItemsRootAndASymlinkPassThroughUnchanged() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let other = r.temp.appendingPathComponent("elsewhere/TemporaryItems/NSIRD_zzz", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let lookalike = other.appendingPathComponent("a.txt").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: lookalike))
        let real = try r.providerFile("real.txt")
        let link = r.temp.appendingPathComponent("TemporaryItems/NSIRD_abc123/link.txt").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        r.drop(DragBoard(files: [lookalike, link]))
        r.background.runAll()
        #expect(r.input.string == "@\(lookalike) @\(link) ", "\(r.input.string)")
        #expect(r.state.entries(of: "chat-drops").isEmpty)
    }

    @Test func ChatDrop_aFileOverTheCapIsNotInsertedAndItsReasonIsShown() throws {
        let r = try AttachRig(fileCap: 3)
        defer { r.cleanUp() }
        try r.open()
        let source = try r.providerFile("big.bin", contents: Data("0123456789".utf8))
        r.drop(DragBoard(files: [source]))
        r.background.runAll()
        #expect(r.input.string.isEmpty, "an uncopied original is never handed over: \(r.input.string)")
        #expect(r.body.statusText == "Clawd couldn't copy 1 dropped file. Too large to copy, so Clawd couldn't hand it to the agent.", "\(r.body.statusText)")
        #expect(r.rig.lines("CHAT drop").last?.contains("refused=copy-failed") == true)
    }

    @Test func ChatDrop_aCloseBeforeTheCopyRunsInsertsNothingAndLeavesNoDirectory() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let source = try r.providerFile("a.txt")
        r.drop(DragBoard(files: [source]))
        r.controller.close(.button)
        r.background.runAll()
        #expect(r.state.entries(of: "chat-drops").isEmpty, "\(r.state.entries(of: "chat-drops").map(\.name))")
        #expect(r.controller.draft.isEmpty)
    }

    @Test func ChatDrop_aCloseAfterTheCopyRanButBeforeItsDoneRemovesTheCopy() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let source = try r.providerFile("a.txt")
        r.drop(DragBoard(files: [source]))
        r.background.runWork()
        #expect(r.state.entries(of: "chat-drops").count == 1, "the copy exists while the work has run")
        r.controller.close(.button)
        r.background.runDone()
        #expect(r.state.entries(of: "chat-drops").isEmpty && r.controller.draft.isEmpty, "\(r.state.entries(of: "chat-drops").map(\.name))")
    }

    @Test func ChatDrop_dropsAreInsertedInTheOrderTheyWereMadeEvenWhenAnEarlierOneIsStillCopying() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let source = try r.providerFile("a.txt")
        r.drop(DragBoard(files: [source]))
        r.drop(DragBoard(files: ["/plain"]))
        #expect(r.input.string.isEmpty, "the plain drop waits behind the copy")
        r.background.runAll()
        #expect(r.input.string.hasSuffix("@/plain ") && r.input.string.contains("/a.txt "), "\(r.input.string)")
        #expect(r.input.string.range(of: "/a.txt")!.lowerBound < r.input.string.range(of: "/plain")!.lowerBound)
    }

    @Test func ChatDrop_theSweepRemovesAnEightDayOldDropDirectoryAndKeepsTheRest() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.state.privateDirectory("chat-drops")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func make(_ name: String, daysOld: Double) throws {
            let url = r.root.appendingPathComponent("chat-drops/" + name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path)
        }
        try make("clawd-drop-AAAAAA", daysOld: 8)
        try make("clawd-drop-BBBBBB", daysOld: 6)
        try make("other-CCCCCC", daysOld: 20)
        let target = r.root.appendingPathComponent("somewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = r.root.appendingPathComponent("chat-drops/clawd-drop-DDDDDD").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target.path)
        var times = [timeval(tv_sec: Int(now.timeIntervalSince1970) - 20 * 86_400, tv_usec: 0), timeval(tv_sec: Int(now.timeIntervalSince1970) - 20 * 86_400, tv_usec: 0)]
        #expect(lutimes(link, &times) == 0)
        r.setNow(now)
        var env = ChatAttachEnvironment()
        env.state = r.state; env.wall = { now }
        ChatAttachmentSession.sweepStorage(env)
        let left = Set(r.state.entries(of: "chat-drops").map(\.name))
        #expect(left == ["clawd-drop-BBBBBB", "other-CCCCCC", "clawd-drop-DDDDDD"], "\(left)")
    }

    // MARK: P3: the "+" control

    @Test func ChatAttach_thePlusControlIsEnabledAndSaysAttachFile() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let plus = r.body.composer.plusButton
        #expect(plus.isEnabled && plus.accessibilityLabel() == "Attach file" && plus.toolTip == "Attach file")
    }

    @Test func ChatAttach_thePickersFileIsInsertedAsAReferenceAndCancelInsertsNothing() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.body.composer.plusButton.performClick(nil)
        #expect(r.picker.presented == 1)
        r.body.composer.plusButton.performClick(nil)
        #expect(r.picker.presented == 1, "only one picker is open at a time")
        r.picker.choose("/some/file.txt")
        #expect(r.input.string == "@/some/file.txt ", "\(r.input.string)")
        r.body.composer.plusButton.performClick(nil)
        #expect(r.picker.presented == 2)
        let before = r.input.string
        r.picker.choose(nil)
        #expect(r.input.string == before)
    }

    @Test func ChatAttach_aCloseWhileThePickerIsUpCancelsItAndALateCompletionInsertsNothing() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.body.composer.plusButton.performClick(nil)
        let handle = try #require(r.picker.handles.last)
        r.controller.close(.button)
        #expect(handle.cancelled, "close() cancels the picker first")
        r.picker.choose("/late.txt")
        #expect(r.controller.draft.isEmpty, "\(r.controller.draft)")
        try r.open()
        #expect(r.input.string.isEmpty, "the next opening does not get a stale completion")
    }

    @Test func ChatAttach_theKeyOfThePickerWindowAndOfASheetOnItIsExemptAndRecordsNoViolation() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let panel = try #require(r.web.panel)
        let center = NotificationCenter()
        let store = try OwnState(root: r.root.appendingPathComponent("monitor", isDirectory: true))
        let monitor = FocusMonitor(store: store, center: center)
        var violations = 0
        monitor.onViolation = { violations += 1 }
        monitor.keyExemption = { [controller = r.controller] in controller.keyVerdict(for: $0) }
        r.body.composer.plusButton.performClick(nil)
        let picker = try #require(r.picker.window)
        #expect(r.controller.keyVerdict(for: picker) == .exempt)
        center.post(name: NSWindow.didBecomeKeyNotification, object: picker)
        #expect(monitor.status.focusViolations == 0 && violations == 0, "the picker's key is not a violation")
        #expect(r.rig.lines("CHAT picker-key").count == 2, "\(r.rig.lines("CHAT picker-key"))")
        _ = panel
        // A window that is not the picker, nor on it, is not exempt.
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(r.controller.keyVerdict(for: other) == nil)
    }

    @Test func ChatAttach_theProductionPickerIsAboveTheChatAndTakesOneFile() {
        let panel = ChatAttachPicker.makePanel()
        #expect(panel.level.rawValue > NSWindow.Level.floating.rawValue)
        #expect(!panel.allowsMultipleSelection && panel.canChooseFiles && !panel.canChooseDirectories)
        #expect(panel.level == .modalPanel)
    }
}
