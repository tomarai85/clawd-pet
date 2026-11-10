import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop

// Orca parity round C: the fixes of the round A+B code review (H1, H2, M1-M3, L1-L7 and two log words). A drag is delivered by calling the
// destination view's own methods with a fake NSDraggingInfo; nothing is shown, no window is made key and no application is activated.

@Suite("ChatOrcaParityC", .serialized)
@MainActor
struct ChatOrcaParityCSuite {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let near = CGPoint(x: 900, y: 300)

    private func recallRig() throws -> AttachRig {
        let r = try AttachRig()
        r.rig.host.visible = screen
        return r
    }

    private func clickClose(_ r: AttachRig) throws {
        try r.open()
        r.rig.focus.surfaceOwner = { _ in "com.apple.Safari" }
        r.rig.focus.outsidePress(ChatOutsidePress(time: 5, location: CGPoint(x: 50, y: 50), button: .left, ownerPid: 321))
        r.rig.focus.followUp(.up, CGPoint(x: 50, y: 50))
    }

    private func fileDrag(_ r: AttachRig, at point: CGPoint, time: TimeInterval, count: Int = 1) {
        r.rig.focus.dragBoard = ChatDragPasteboardState(changeCount: count, hasFileURLs: true)
        r.rig.focus.dragEvent(.dragged, time: time, at: point)
    }

    /// The panel is recalled and a file drag has entered its body.
    private func recalledWithDragInside(_ r: AttachRig) throws -> FakeDrag {
        try clickClose(r)
        fileDrag(r, at: near, time: 2)
        try #require(r.controller.isOpen && r.rig.lines("CHAT recall gen=2").count == 1, "\(r.rig.lines("CHAT"))")
        let drag = FakeDrag(DragBoard(files: ["/x"]))
        _ = r.body.destination.draggingEntered?(drag)
        return drag
    }

    // MARK: H1: the global mouse-up comes before the drop

    @Test func ChatRecallC_theUpBeforeTheDropKeepsTheRecalledPanelAndTheDropInsertsAndPromotes() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        let drag = try recalledWithDragInside(r)
        r.rig.focus.dragEvent(.up, time: 3)
        #expect(r.controller.isOpen && r.rig.lines("CHAT close reason=recall").isEmpty, "the drag is inside the body: the up does not end the recall: \(r.rig.lines("CHAT"))")
        #expect(r.body.destination.performDragOperation?(drag) == true)
        r.body.destination.concludeDragOperation?(drag)
        r.body.destination.draggingEnded?(drag)
        #expect(r.input.string == "@/x ", "the drop that follows the up inserts: \(r.input.string)")
        #expect(r.rig.lines("CHAT recall-promoted gen=2").count == 1 && r.controller.livePanel?.canBecomeKey == true)
        r.rig.focus.timers.fire(exactly: ChatController.recallDropGrace)
        #expect(r.controller.isOpen && r.rig.lines("CHAT close reason=recall").isEmpty && r.rig.focus.liveDragProbes == 0, "nothing closes it later: \(r.rig.lines("CHAT"))")
    }

    @Test func ChatRecallC_anUpWithTheDragInsideAndNoDropClosesAtTheGraceDeadline() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        _ = try recalledWithDragInside(r)
        r.rig.focus.dragEvent(.up, time: 3)
        #expect(r.controller.isOpen)
        r.rig.focus.timers.fire(exactly: ChatController.recallDropGrace)
        #expect(!r.controller.isOpen && r.rig.lines("CHAT close reason=recall").count == 1, "\(r.rig.lines("CHAT close"))")
        #expect(ChatController.recallDropGrace == 0.5)
    }

    @Test func ChatRecallC_aDragThatEndedInTheBodyWithoutADropClosesAtOnceAfterTheUp() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        let drag = try recalledWithDragInside(r)
        r.rig.focus.dragEvent(.up, time: 3)
        #expect(r.controller.isOpen)
        r.body.destination.draggingEnded?(drag)
        #expect(!r.controller.isOpen && r.rig.lines("CHAT close reason=recall").count == 1, "the end of the drag without a perform ends the recall: \(r.rig.lines("CHAT close"))")
    }

    @Test func ChatRecallC_aDragThatExitedTheBodyBeforeTheUpClosesAtOnceAsBefore() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        let drag = try recalledWithDragInside(r)
        r.body.destination.draggingExited?(drag)
        #expect(r.controller.isOpen, "an exit alone does not end it: the up decides")
        r.rig.focus.dragEvent(.up, time: 3)
        #expect(!r.controller.isOpen && r.rig.lines("CHAT close reason=recall").count == 1, "\(r.rig.lines("CHAT close"))")
        // Exit after the up (inside the grace) ends it at once too.
        let late = try recallRig()
        defer { late.cleanUp() }
        let second = try recalledWithDragInside(late)
        late.rig.focus.dragEvent(.up, time: 3)
        #expect(late.controller.isOpen)
        late.body.destination.draggingExited?(second)
        #expect(!late.controller.isOpen && late.rig.lines("CHAT close reason=recall").count == 1)
    }

    // MARK: H2: the picker's own key comes inside `present`

    @Test func ChatAttachC_aPickerThatBecomesKeyInsideThePresentCallIsNotAViolation() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let center = NotificationCenter()
        let store = try OwnState(root: r.root.appendingPathComponent("monitor", isDirectory: true))
        let monitor = FocusMonitor(store: store, center: center)
        var violations = 0
        monitor.onViolation = { violations += 1 }
        monitor.keyExemption = { [controller = r.controller] in controller.keyVerdict(for: $0) }
        var verdict: ChatActivationVerdict?
        r.picker.duringPresent = { window in
            center.post(name: NSWindow.didBecomeKeyNotification, object: window)
            verdict = r.controller.activationVerdict()
        }
        r.body.composer.plusButton.performClick(nil)
        #expect(r.picker.presented == 1)
        #expect(monitor.status.focusViolations == 0 && violations == 0, "the picker's key inside present is not a violation: \(monitor.status.focusViolations)")
        #expect(verdict == .exempt, "nor is the activation that comes with it: \(String(describing: verdict))")
        #expect(r.rig.lines("CHAT picker-key").count == 1, "\(r.rig.lines("CHAT"))")
        // The flag is only for the call: afterwards an unrelated window is not exempt.
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(r.controller.keyVerdict(for: other) == nil)
    }

    // MARK: M1: a finished drag leaves its change count behind

    @Test func ChatRecallC_aDragThatEndedFarAwayLeavesNoCountThatALaterNearDragCanUse() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try clickClose(r)
        // A file drag far from the closed panel starts and ends: the board now has a new count and still lists the files.
        r.rig.focus.dragBoard = ChatDragPasteboardState(changeCount: 1, hasFileURLs: true)
        r.rig.focus.dragEvent(.dragged, time: 1, at: CGPoint(x: 100, y: 900))
        r.rig.focus.dragEvent(.up, time: 2)
        // Then a drag of something else (a selection, a window) near the closed panel: the board is unchanged.
        r.rig.focus.dragEvent(.dragged, time: 3, at: near)
        #expect(!r.controller.isOpen, "the same board state is not a new file drag: \(r.rig.lines("CHAT"))")
        // A file drag that starts after that release is one.
        fileDrag(r, at: near, time: 4, count: 2)
        #expect(r.controller.isOpen && r.rig.lines("CHAT recall gen=2 from=1").count == 1, "\(r.rig.lines("CHAT"))")
    }

    // MARK: M2, L2: copies run one at a time and each has a deadline

    @Test func ChatDropCopyC_aCopyThatNeverReturnsDoesNotHoldALaterDropPastTheDeadline() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let slow = try r.providerFile("a.txt")
        r.drop(DragBoard(files: [slow]))
        #expect(r.background.pending.count == 1, "the copy started and does not return")
        r.drop(DragBoard(files: ["/plain"]))
        #expect(r.input.string.isEmpty, "a later drop is inserted after the earlier one: it waits")
        #expect(r.rig.focus.timers.live.contains(DragTempCopier.dropTimeout), "\(r.rig.focus.timers.live)")
        r.rig.focus.timers.fire(exactly: DragTempCopier.dropTimeout)
        #expect(r.input.string == "@/plain ", "the deadline fails the stalled drop and the queue drains: \(r.input.string)")
        let drops = r.rig.lines("CHAT drop")
        #expect(drops.count == 2 && drops[0].contains("refused=copy-failed") && drops[1].contains("refused=none"), "\(drops)")
        // The stalled work comes back late: nothing changes and nothing is inserted twice.
        r.background.runAll()
        #expect(r.input.string == "@/plain " && r.rig.lines("CHAT drop").count == 2, "\(r.input.string) \(r.rig.lines("CHAT drop"))")
    }

    @Test func ChatDropCopyC_theDeadlineWordsAreOrcasTimedOutAndAPlainPathOfTheSameDropPasses() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let slow = try r.providerFile("a.txt")
        r.drop(DragBoard(files: [slow, "/plain"]))
        r.rig.focus.timers.fire(exactly: DragTempCopier.dropTimeout)
        #expect(r.input.string == "@/plain ", "\(r.input.string)")
        #expect(r.body.statusText == "Clawd couldn't copy 1 dropped file. Copying took too long. Try the drop again.", "\(r.body.statusText)")
    }

    @Test func ChatDropCopyC_copiesRunOneAtATimeInDropOrder() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let a = try r.providerFile("a.txt"), b = try r.providerFile("b.txt")
        r.drop(DragBoard(files: [a]))
        r.drop(DragBoard(files: [b]))
        #expect(r.background.pending.count == 1, "the second copy waits for the first: \(r.background.pending.count)")
        r.background.runWork(); r.background.runDone()
        #expect(r.background.pending.count == 1, "the second starts when the first has ended")
        r.background.runWork(); r.background.runDone()
        let names = r.input.string.split(separator: " ").map { ($0 as NSString).lastPathComponent }
        #expect(names == ["a.txt", "b.txt"], "\(r.input.string)")
        #expect(r.background.pending.isEmpty)
    }

    @Test func ChatDropCopyC_aCopyStopsBetweenChunksWhenCancelledAndLeavesNoFile() throws {
        let (state, root) = try makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let temp = root.appendingPathComponent("tmp", isDirectory: true)
        let dir = temp.appendingPathComponent("TemporaryItems/NSIRD_abc123", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("big.bin")
        try Data(count: 1024 * 1024).write(to: file)
        let copier = DragTempCopier(state: state, temporaryDirectory: temp.path)
        var polls = 0
        let results = copier.materialize([file.path], isCancelled: { polls += 1; return polls > 2 }, now: { 0 }, deadline: 100)
        #expect(results.isEmpty, "a close in the middle of a 1 MiB copy: nothing is handed over: \(results)")
        #expect(state.entries(of: DragTempCopier.rootName).allSatisfy { !$0.name.hasPrefix(DragTempCopier.dirPrefix) }, "the partial copy is removed: \(state.entries(of: DragTempCopier.rootName).map(\.name))")
    }

    @Test func ChatDropCopyC_aCopyStopsBetweenChunksWhenTheDeadlinePasses() throws {
        let (state, root) = try makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let temp = root.appendingPathComponent("tmp", isDirectory: true)
        let dir = temp.appendingPathComponent("TemporaryItems/NSIRD_abc123", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("big.bin")
        try Data(count: 1024 * 1024).write(to: file)
        let copier = DragTempCopier(state: state, temporaryDirectory: temp.path)
        var clock = 0.0
        let results = copier.materialize([file.path], isCancelled: { false }, now: { clock += 1; return clock }, deadline: 3.5)
        #expect(results == [.failed(path: file.path, reason: .timedOut)], "the third chunk is past the deadline: \(results)")
        #expect(state.entries(of: DragTempCopier.rootName).allSatisfy { !$0.name.hasPrefix(DragTempCopier.dirPrefix) })
    }

    @Test func ChatDropCopyC_aSourceThatBecameAFifoOpensAtOnceAndIsRefused() throws {
        let path = NSTemporaryDirectory() + "clawd-fifo-" + UUID().uuidString
        #expect(mkfifo(path, 0o600) == 0)
        defer { unlink(path) }
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var file: ReadOnlyFile?; var error: Error? }
        let box = Box()
        DispatchQueue.global().async {
            do { box.file = try ReadOnlyFile(path, flags: O_RDONLY | O_NOFOLLOW, nonBlocking: true) } catch { box.error = error }
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 3) == .success
        if !finished {
            // Without O_NONBLOCK the open waits for a writer: let it go so the thread does not outlive the test.
            let writer = open(path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            _ = done.wait(timeout: .now() + 3)
        }
        #expect(finished, "the open of a FIFO must not wait for a writer")
        let info = try box.file?.metadata()
        #expect(info.map { $0.st_mode & S_IFMT == S_IFIFO } == true, "the caller's fstat sees a FIFO and refuses it")
        #expect(!ReadOnlyFile.accepts(flags: O_RDONLY | O_NONBLOCK), "the flag is not one the read-only boundary takes in general")
    }

    // MARK: M3: control-click Copy

    @Test func ChatMenuC_aControlClickStoresItsOwnSelectionAndAPlainPressEndsTheStoredOne() async throws {
        let rig = WebPageRig()
        #expect(await rig.loadAndWaitReady())
        let view = try #require(rig.page.view)
        _ = try await pageJS(view, "return window.ClawdChat.apply({order: [1], upserts: [{id: 1, kind: 'assistant', text: 'alpha\\n\\nbeta'}], turn: 'none'});")
        let result = try await pageJS(view, """
            const paragraphs = document.querySelectorAll('.native-chat-markdown p');
            const select = (p) => { const s = window.getSelection(); s.removeAllRanges(); const r = document.createRange(); r.selectNodeContents(p); s.addRange(r); };
            const row = document.querySelector('.assistant-row');
            const press = (init) => row.dispatchEvent(new MouseEvent('mousedown', Object.assign({bubbles: true, cancelable: true}, init)));
            select(paragraphs[0]); press({button: 2});
            const afterRight = window.ClawdChat.menuCopyText();
            select(paragraphs[1]); press({button: 0, ctrlKey: true});
            const afterControlClick = window.ClawdChat.menuCopyText();
            select(paragraphs[0]); press({button: 2});
            select(paragraphs[1]); press({button: 0});
            const afterPlain = window.ClawdChat.menuCopyText();
            return [afterRight, afterControlClick, afterPlain];
            """)
        let values = try #require(result as? [String])
        #expect(values == ["alpha", "beta", "beta"], "right-click keeps its press-time text, a control-click takes the current one, a plain press clears the stored one: \(values)")
    }

    // MARK: L1-L6 and the words

    @Test func ChatDropC_oneFailedFileUsesTheSingularForm() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let missing = r.temp.appendingPathComponent("TemporaryItems/NSIRD_zzz999/gone.txt").path
        r.drop(DragBoard(files: [missing]))
        r.background.runAll()
        #expect(r.body.statusText == "Clawd couldn't copy 1 dropped file. No longer at its original path.", "\(r.body.statusText)")
        #expect(ChatDropText.copyFailed(count: 2, reason: "x") == "Clawd couldn't copy 2 dropped files. x")
    }

    @Test func ChatOverlayC_theTitleIsMediumNotBoldAndTheCircleIsEightPointsAboveIt() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.body.frame = CGRect(x: 0, y: 0, width: 520, height: 300)
        r.body.layoutSubtreeIfNeeded()
        _ = r.body.destination.draggingEntered?(FakeDrag(DragBoard(files: ["/a"])))
        let overlay = try #require(r.body.dropOverlay as? ChatDropOverlay)
        overlay.layoutSubtreeIfNeeded()
        #expect(ChatDropOverlay.titleWeight == .medium && !overlay.titleIsBold && ChatDropOverlay.circleGap == 8)
        #expect(!ChatDropOverlay.titleFont.fontDescriptor.symbolicTraits.contains(.bold))
        let card = try #require(overlay.subviews.first)
        let parts = card.subviews
        try #require(parts.count == 3)
        let disc = parts[0], title = parts[1], subtitle = parts[2]
        #expect(abs((disc.frame.minY - title.frame.maxY) - 8) <= 0.5, "circle to title: \(disc.frame) \(title.frame)")
        #expect(abs((title.frame.minY - subtitle.frame.maxY) - 4) <= 0.5, "title to subtitle: \(title.frame) \(subtitle.frame)")
        let height = 20 * 2 + 36 + 8 + title.frame.height + 4 + subtitle.frame.height
        #expect(abs(card.frame.height - height) <= 0.5, "the card height follows: \(card.frame.height) vs \(height)")
    }

    @Test func ChatDropC_theImeQueueRefusalSaysWaitingAndADropWithNothingInItSaysEmpty() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.input.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        r.drop(DragBoard(files: (0..<200).map { "/a/\($0)" }))
        r.drop(DragBoard(files: (0..<57).map { "/b/\($0)" }))
        #expect(r.rig.lines("CHAT drop").last?.contains("refused=waiting") == true, "\(r.rig.lines("CHAT drop"))")
        let empty = try AttachRig()
        defer { empty.cleanUp() }
        try empty.open()
        empty.drop(DragBoard(string: "just text"))
        _ = empty.body.destination.draggingEntered?(FakeDrag(DragBoard(files: ["/q"])))
        empty.controller.livePanel?.terminal?.webBody?.attachments?.dropped(paths: [], carriedPromise: false, target: "panel")
        let lines = empty.rig.lines("CHAT drop")
        #expect(lines == ["CHAT drop gen=1 target=panel paths=0 copied=0 queued=0 refused=empty"], "\(lines)")
    }

    @Test func ChatDropC_aDropIsItsOwnUndoStepAfterTyping() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let manager = try #require(r.input.undoManager)
        r.input.allowsUndo = true
        manager.groupsByEvent = false
        // Two run-loop turns: the typing, then the drop.
        manager.beginUndoGrouping()
        r.web.type("ab")
        manager.endUndoGrouping()
        manager.beginUndoGrouping()
        r.drop(DragBoard(files: ["/x"]))
        manager.endUndoGrouping()
        #expect(r.input.string == "ab@/x ", "\(r.input.string)")
        manager.undo()
        #expect(r.input.string == "ab", "one Undo takes the reference away and leaves the typing: \(r.input.string)")
    }

    @Test func ChatPasteC_aPastedImageNeverTouchesTheTextOrItsCaretWhateverTheTextDoesWhileItIsEncoded() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.body.inputText = "abcd"
        r.input.setSelectedRange(NSRange(location: 2, length: 0))
        r.setPaste(ChatPasteContents(hasText: false, image: pngData()))
        r.input.paste(nil)
        // While the image is encoded the text changes and the caret goes to its end.
        r.body.inputText = "wxyz"
        r.input.setSelectedRange(NSRange(location: 4, length: 0))
        r.background.runAll()
        #expect(r.input.string == "wxyz" && r.input.selectedRange() == NSRange(location: 4, length: 0), "the image is a chip, not a reference: \(r.input.string)")
        #expect(r.body.composer.chips.items.count == 1)
    }

    @Test func ChatPasteC_aDroppedReferenceNeverLandsInsideACharacterOrBetweenTheHalvesOfASurrogatePair() throws {
        let pair = try AttachRig()
        defer { pair.cleanUp() }
        try pair.open()
        pair.body.inputText = "x😀y"
        pair.input.setSelectedRange(NSRange(location: 2, length: 0))
        pair.drop(DragBoard(files: ["/x"]))
        #expect(pair.input.string == "x@/x 😀y", "a caret between the two halves of a pair is moved to the pair's start: \(pair.input.string)")
    }

    // MARK: L7: the click that is recorded after the activation

    private func resigned(_ r: ControllerRig) throws -> ChatPanel {
        r.open()
        let panel = try #require(r.controller.livePanel)
        r.clock.advance(0.1)
        #expect(r.controller.activationVerdict() == .exempt)
        r.focus.active = true
        r.clock.advance(5)
        r.controller.appResigned()
        r.focus.active = false
        r.clock.advance(5)
        return panel
    }

    @Test func ChatActivateC_aSessionPressIntoClawdAfterTheResignExemptsAnActivationHandledBeforeThePanelRecordsIt() throws {
        let r = ControllerRig()
        var late = 0
        r.controller.lateViolation = { late += 1 }
        let panel = try resigned(r)
        r.focus.pressAt = r.clock.now - 0.05            // the window server has the press; the panel has not recorded it
        r.controller.appWillBecomeActive()
        r.currentEvent = ChatCurrentEvent(isMouseDown: false, window: nil, isMouse: false)
        r.clock.advance(0.01)
        r.focus.active = true
        #expect(r.controller.activationVerdict() == .exempt)
        #expect(r.lines("CHAT active gen=1 cause=click").count == 1, "\(r.lines("CHAT"))")
        r.focus.drain()
        #expect(r.controller.isOpen && late == 0 && r.lines("CHAT close").isEmpty)
        _ = panel
    }

    @Test func ChatActivateC_withoutAPressAfterTheResignOrThatWentElsewhereTheActivationStillCloses() throws {
        func verdict(_ prepare: (ControllerRig) -> Void) throws -> (ChatActivationVerdict, Bool) {
            let r = ControllerRig()
            _ = try resigned(r)
            prepare(r)
            r.controller.appWillBecomeActive()
            r.currentEvent = ChatCurrentEvent(isMouseDown: false, window: nil, isMouse: false)
            r.clock.advance(0.01)
            r.focus.active = true
            let result = r.controller.activationVerdict()
            r.focus.drain()
            return (result, r.controller.isOpen)
        }
        let none = try verdict { _ in }
        #expect(none.0 == .answeredByClose && !none.1, "no press at all")
        let old = try verdict { $0.focus.pressAt = $0.clock.now - 3 }
        #expect(old.0 == .answeredByClose && !old.1, "a press from seconds ago is not this activation's click")
        // A press that is recent but older than the resign: Clawd lost the activation after it.
        let r = ControllerRig()
        r.open()
        r.clock.advance(0.1)
        #expect(r.controller.activationVerdict() == .exempt)
        r.focus.active = true
        r.clock.advance(5)
        r.focus.pressAt = r.clock.now
        r.clock.advance(0.2)
        r.controller.appResigned()
        r.focus.active = false
        r.clock.advance(0.2)
        r.controller.appWillBecomeActive()
        r.currentEvent = ChatCurrentEvent(isMouseDown: false, window: nil, isMouse: false)
        r.focus.active = true
        #expect(r.controller.activationVerdict() == .answeredByClose, "the press came before the last resign")
        let elsewhere = try verdict { $0.focus.pressAt = $0.clock.now - 0.05; $0.focus.pressWentToClawd = false }
        #expect(elsewhere.0 == .answeredByClose && !elsewhere.1, "a press that went to another application")
    }
}
