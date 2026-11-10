import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop

// Orca parity round B, P11 (a file dropped on Clawd's body) and P12 (a click-closed chat comes back for a file drag). Drags are fake
// NSDraggingInfo calls and probe events; nothing is shown, no window is made key and no application is activated.

@Suite("ChatOrcaParityB pet drop and recall", .serialized)
@MainActor
struct ChatPetDropRecallSuite {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let closed = CGRect(x: 700, y: 100, width: 380, height: 480)   // the rig's 380x480 host rect, at least ChatPanelGeometry.minSize (300x200): a recall leaves it unclamped (Q20)

    // MARK: P11: Clawd's body is a drop target

    private func petView(opaque: @escaping (CGPoint) -> Bool = { $0.x < 20 }) -> PetView {
        let view = PetView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        view.opaqueBody = opaque
        return view
    }

    @Test func ChatPet_theBodyViewIsRegisteredForFileDrops() {
        let view = petView()
        for type in ChatDropContent.registeredTypes { #expect(view.registeredDraggedTypes.contains(type)) }
    }

    @Test func ChatPet_aFileDragOverAnOpaquePixelAnswersCopyAndOverATransparentPixelNothing() {
        let view = petView()
        view.dropRefusal = { nil }
        let board = DragBoard(files: ["/a"])
        #expect(view.destination.draggingEntered?(FakeDrag(board, at: CGPoint(x: 5, y: 5))) == .copy)
        #expect(view.destination.draggingUpdated?(FakeDrag(board, at: CGPoint(x: 30, y: 5))) == [], "a transparent pixel is not Clawd's")
        #expect(view.destination.prepareForDragOperation?(FakeDrag(board, at: CGPoint(x: 30, y: 5))) == false)
        #expect(view.destination.performDragOperation?(FakeDrag(board, at: CGPoint(x: 30, y: 5))) == false)
        #expect(view.destination.draggingEntered?(FakeDrag(DragBoard(string: "text"), at: CGPoint(x: 5, y: 5))) == [], "text is not a file drag")
    }

    @Test func ChatPet_aRefusedChatAnswersNoOperationAndLogsTheRefusalOncePerDrag() {
        let view = petView()
        var logged: [String] = []
        view.dropRefusal = { "quiet" }
        view.dropRefused = { logged.append($0) }
        let drag = FakeDrag(DragBoard(files: ["/a"]), at: CGPoint(x: 5, y: 5))
        #expect(view.destination.draggingEntered?(drag) == [] && view.destination.draggingUpdated?(drag) == [] && view.destination.draggingUpdated?(drag) == [])
        #expect(logged == ["quiet"], "once per drag: \(logged)")
        view.destination.draggingExited?(drag)
        _ = view.destination.draggingEntered?(drag)
        #expect(logged == ["quiet", "quiet"], "a new drag logs again")
    }

    @Test func ChatPet_aTransparentPixelStillIgnoresAClickAfterTheRegistration() {
        let view = petView()
        var ignored: [String] = [], inputs = 0
        view.ignored = { kind, _, why in ignored.append("\(kind):\(why)") }
        view.input = { _, _ in inputs += 1 }
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 30, y: 5)))
        #expect(ignored == ["mouseDown:transparent"] && inputs == 0, "\(ignored)")
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 5, y: 5)))
        #expect(inputs == 1)
    }

    @Test func ChatPet_theDropsEventTimeFallsBackToTheUptimeWhenThereIsNoCurrentEvent() {
        let view = petView()
        view.dropRefusal = { nil }
        var time: TimeInterval?
        view.fileDrop = { _, _, t in time = t }
        let drag = FakeDrag(DragBoard(files: ["/a"]), at: CGPoint(x: 5, y: 5))
        _ = view.destination.draggingEntered?(drag)
        #expect(view.destination.performDragOperation?(drag) == true)
        let uptime = ProcessInfo.processInfo.systemUptime
        #expect(time != nil && abs(uptime - time!) < 5, "\(String(describing: time)) vs \(uptime)")
    }

    @Test func ChatPet_aDropWithTheChatClosedOpensItOnceWithTheDropCauseAndInsertsAfterTheRestoredDraft() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.web.type("draft ")
        r.controller.close(.button)
        let center = NotificationCenter()
        let store = try OwnState(root: r.root.appendingPathComponent("monitor", isDirectory: true))
        let monitor = FocusMonitor(store: store, center: center)
        monitor.keyExemption = { [controller = r.controller] in controller.keyVerdict(for: $0) }
        r.rig.onMakeKey = { center.post(name: NSWindow.didBecomeKeyNotification, object: $0) }
        r.controller.petDrop(paths: ["/x"], carriedPromise: false, eventTime: 7)
        #expect(r.rig.lines("CHAT open").count == 2 && r.rig.lines("CHAT open").last == "CHAT open et=7.000000 gen=2 cause=drop", "\(r.rig.lines("CHAT open"))")
        let text = r.input.string
        #expect(text.hasPrefix("draft ") || text.contains("draft "), "\(text)")
        #expect(text.contains("@/x ") && text.range(of: "draft")!.lowerBound < text.range(of: "@/x")!.lowerBound || text.hasPrefix("@/x "), "\(text)")
        #expect(monitor.status.focusViolations == 0, "the open's key is exempt as for the double-click")
        #expect(r.rig.lines("CHAT drop").last?.contains("target=pet paths=1") == true, "\(r.rig.lines("CHAT drop"))")
    }

    @Test func ChatPet_aDropWithTheChatOpenInsertsAndNeverClosesIt() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.controller.petDrop(paths: ["/x"], carriedPromise: false, eventTime: 3)
        try #require(r.controller.isOpen, "a drop on Clawd never closes the open chat: \(r.rig.logs)")
        #expect(r.rig.lines("CHAT open").count == 1 && r.input.string == "@/x ", "\(r.input.string)")
        r.controller.petDrop(paths: ["/y"], carriedPromise: false, eventTime: 4)
        try #require(r.controller.isOpen)
        #expect(r.input.string.contains("@/y "))
    }

    @Test func ChatPet_257PathsOpenTheChatWithTheLimitStatus() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        r.controller.petDrop(paths: (0..<257).map { "/f/\($0)" }, carriedPromise: false, eventTime: 3)
        #expect(r.controller.isOpen && r.body.statusText == "Drop contains too many files. Drop 256 or fewer files at a time." && r.input.string.isEmpty, "\(r.body.statusText)")
    }

    @Test func ChatPet_aDropDuringMarkedTextIsHeld() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        r.input.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        r.controller.petDrop(paths: ["/x"], carriedPromise: false, eventTime: 3)
        #expect(r.input.string == "に" && r.input.hasMarkedText())
        r.input.insertText("日", replacementRange: NSRange(location: NSNotFound, length: 0))
        r.rig.focus.drain()
        #expect(r.input.string == "日@/x ", "\(r.input.string)")
    }

    @Test func ChatPet_aRefusedDropOpensNothing() throws {
        let off = try AttachRig()
        defer { off.cleanUp() }
        off.rig.chatSettings.view = .stream
        #expect(off.controller.petDropRefusal() == "view")
        let quiet = try AttachRig()
        defer { quiet.cleanUp() }
        quiet.rig.host.refusal = .quiet
        #expect(quiet.controller.petDropRefusal() == "quiet")
        quiet.controller.petDrop(paths: ["/x"], carriedPromise: false, eventTime: 1)
        #expect(!quiet.controller.isOpen)
        let exam = try AttachRig()
        defer { exam.cleanUp() }
        exam.rig.host.examRunning = true
        #expect(exam.controller.petDropRefusal() == "exam")
        let disabled = try AttachRig()
        defer { disabled.cleanUp() }
        disabled.rig.enabled = false
        #expect(disabled.controller.petDropRefusal() == "off")
        let fine = try AttachRig()
        defer { fine.cleanUp() }
        #expect(fine.controller.petDropRefusal() == nil)
    }

    @Test func ChatPet_aFileDragEnteringClawdsBodyTurnsAPendingPressIntoADrag() throws {
        let r = try AttachRig()
        defer { r.cleanUp() }
        try r.open()
        let view = petView()
        view.dropRefusal = { nil }
        view.fileDragEntered = { [controller = r.controller] in controller.fileDragEntered() }
        let here = CGPoint(x: 800, y: 500)
        r.rig.focus.surfaceOwner = { _ in "com.apple.finder" }
        r.rig.focus.outsidePress(ChatOutsidePress(time: 5, location: here, button: .left, ownerPid: 321))
        _ = view.destination.draggingEntered?(FakeDrag(DragBoard(files: ["/a"]), at: CGPoint(x: 5, y: 5)))
        r.rig.focus.followUp(.up, CGPoint(x: here.x + 1, y: here.y))
        #expect(r.controller.isOpen && r.rig.lines("CHAT press").first?.contains("decided=drag") == true, "\(r.rig.lines("CHAT"))")
    }

    // MARK: P12: the recall

    private func recallRig() throws -> AttachRig {
        let r = try AttachRig()
        r.rig.host.visible = screen
        return r
    }

    /// Opens the chat and closes it with a plain click elsewhere (which arms the probe).
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

    @Test func ChatRecall_aFileDragNearTheClosedPanelBringsItBackWithoutAKeyAnActivationOrAMakeKey() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try clickClose(r)
        #expect(!r.controller.isOpen && r.rig.focus.liveDragProbes == 1)
        let keys = r.rig.keys.count, activations = r.rig.focus.activationRequests
        r.rig.focus.dragBoard = ChatDragPasteboardState(changeCount: 0, hasFileURLs: true)      // an old drag's files are still on the board
        r.rig.focus.dragEvent(.dragged, time: 1, at: CGPoint(x: 900, y: 300))
        #expect(!r.controller.isOpen, "the change count did not change: no recall")
        fileDrag(r, at: CGPoint(x: 900, y: 300), time: 2)
        let panel = try #require(r.controller.livePanel)
        #expect(panel.frame == closed && !panel.canBecomeKey, "\(panel.frame) key=\(panel.canBecomeKey)")
        #expect(r.rig.keys.count == keys && r.rig.focus.activationRequests == activations, "no make-key and no activation request")
        #expect(r.rig.lines("CHAT recall gen=2 from=1").count == 1 && r.rig.lines("CHAT open").count == 1, "\(r.rig.lines("CHAT"))")
        #expect(r.controller.keyVerdict(for: panel) == nil, "the panel has no key right to be exempt on")
    }

    @Test func ChatRecall_aDropOnTheRecalledBodyInsertsAndPromotesButMakesNothingKey() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try clickClose(r)
        fileDrag(r, at: CGPoint(x: 900, y: 300), time: 2)
        let panel = try #require(r.controller.livePanel)
        let keys = r.rig.keys.count
        r.drop(DragBoard(files: ["/x"]))
        #expect(r.input.string == "@/x " && panel.canBecomeKey && r.rig.keys.count == keys && !panel.isKeyWindow, "\(r.input.string) key=\(panel.canBecomeKey)")
        #expect(r.rig.focus.liveDragProbes == 0, "promotion removes the probe")
        r.rig.focus.dragEvent(.up, time: 3)
        #expect(r.controller.isOpen, "the up does not close a promoted panel")
        #expect(r.rig.lines("CHAT close reason=recall").isEmpty)
    }

    @Test func ChatRecall_aDragThatEndsElsewhereClosesWithReasonRecallAndKeepsTheDraft() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try r.open()
        r.web.type("my draft")
        r.rig.focus.surfaceOwner = { _ in "com.apple.Safari" }
        r.rig.focus.outsidePress(ChatOutsidePress(time: 5, location: CGPoint(x: 50, y: 50), button: .left, ownerPid: 321))
        r.rig.focus.followUp(.up, CGPoint(x: 50, y: 50))
        fileDrag(r, at: CGPoint(x: 900, y: 300), time: 2)
        #expect(r.controller.isOpen && r.input.string == "my draft", "the draft is restored into the recalled panel")
        r.rig.focus.dragEvent(.up, time: 3)
        #expect(!r.controller.isOpen && r.rig.lines("CHAT close reason=recall gen=2 draft=8").count == 1, "\(r.rig.lines("CHAT close"))")
        #expect(r.controller.draft == "my draft")
        #expect(r.rig.focus.liveDragProbes == 0 && r.rig.focus.activationRequests == 1)
    }

    @Test func ChatRecall_aDragThirtyOneSecondsAfterTheCloseDoesNotRecall() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try clickClose(r)
        r.rig.focus.timers.fire(exactly: 30)
        #expect(r.rig.focus.liveDragProbes == 0, "the probe was removed at 30 s")
        fileDrag(r, at: CGPoint(x: 900, y: 300), time: 31)
        #expect(!r.controller.isOpen)
    }

    @Test func ChatRecall_aDragOfTextOnlyDoesNotRecall() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try clickClose(r)
        r.rig.focus.dragBoard = ChatDragPasteboardState(changeCount: 1, hasFileURLs: false)
        r.rig.focus.dragEvent(.dragged, time: 2, at: CGPoint(x: 900, y: 300))
        #expect(!r.controller.isOpen)
    }

    @Test func ChatRecall_onlyAPlainClickCloseArmsTheProbe() throws {
        func closed(_ how: (AttachRig) -> Void) throws -> Int {
            let r = try recallRig()
            defer { r.cleanUp() }
            try r.open()
            how(r)
            return r.rig.focus.liveDragProbes
        }
        #expect(try closed { $0.controller.close(.button) } == 0)
        #expect(try closed { $0.controller.close(.shortcut) } == 0)
        #expect(try closed { $0.controller.toggle(eventTime: 3) } == 0)
        #expect(try closed { $0.controller.close(.esc) } == 0)
        // A press that timed out is a drag and closes nothing at all.
        let r = try recallRig()
        defer { r.cleanUp() }
        try r.open()
        r.rig.focus.surfaceOwner = { _ in "com.apple.Safari" }
        r.rig.focus.outsidePress(ChatOutsidePress(time: 5, location: CGPoint(x: 50, y: 50), button: .left, ownerPid: 321))
        r.rig.focus.timers.fire(exactly: 10)
        #expect(r.controller.isOpen && r.rig.focus.liveDragProbes == 0)
    }

    @Test func ChatRecall_aMouseDownOnTheRecalledPanelGivesItsKeyRightBeforeAnythingElseAndItsActivationIsExempt() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try clickClose(r)
        fileDrag(r, at: CGPoint(x: 900, y: 300), time: 2)
        let panel = try #require(r.controller.livePanel)
        #expect(!panel.canBecomeKey)
        panel.noteMouseDown(mouseEvent(.leftMouseDown, time: r.rig.clock.now))
        #expect(panel.canBecomeKey, "allowKey ran in the hook that sendEvent calls before super.sendEvent")
        #expect(r.rig.keys.count == 1, "nothing made it key")
        r.rig.currentEvent = ChatCurrentEvent(isMouseDown: true, window: panel)
        #expect(r.controller.activationVerdict() == .exempt)
        #expect(r.rig.lines("CHAT active gen=2 cause=click").count == 1, "\(r.rig.lines("CHAT"))")
        #expect(r.rig.focus.liveDragProbes == 0)
    }

    @Test func ChatRecall_aRefusingStateDoesNotRecall() throws {
        let quiet = try recallRig()
        defer { quiet.cleanUp() }
        try clickClose(quiet)
        quiet.rig.host.refusal = .quiet
        fileDrag(quiet, at: CGPoint(x: 900, y: 300), time: 2)
        #expect(!quiet.controller.isOpen)
        let exam = try recallRig()
        defer { exam.cleanUp() }
        try clickClose(exam)
        exam.rig.host.examRunning = true
        fileDrag(exam, at: CGPoint(x: 900, y: 300), time: 2)
        #expect(!exam.controller.isOpen)
        let examBatch = try recallRig()
        defer { examBatch.cleanUp() }
        try clickClose(examBatch)
        examBatch.rig.host.examActive = true
        examBatch.controller.batchEnded()
        #expect(examBatch.rig.focus.liveDragProbes == 0, "an exam removes the probe")
        let off = try recallRig()
        defer { off.cleanUp() }
        try clickClose(off)
        off.rig.enabled = false
        off.controller.settingsApplied()
        #expect(off.rig.focus.liveDragProbes == 0, "chat off removes the probe")
        let hidden = try recallRig()
        defer { hidden.cleanUp() }
        try clickClose(hidden)
        hidden.controller.closeForHidden()
        #expect(hidden.rig.focus.liveDragProbes == 0, "hiding removes the probe")
    }

    @Test func ChatRecall_aMaximizedPanelClosedByAClickComesBackMaximizedAndRestoreGoesToItsRestoreRect() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try r.open()
        r.controller.gesture(.toggleMaximize)
        let maximized = try #require(r.controller.livePanel).frame
        #expect(maximized != closed)
        r.rig.focus.surfaceOwner = { _ in "com.apple.Safari" }
        r.rig.focus.outsidePress(ChatOutsidePress(time: 5, location: CGPoint(x: 50, y: 50), button: .left, ownerPid: 321))
        r.rig.focus.followUp(.up, CGPoint(x: 50, y: 50))
        #expect(!r.controller.isOpen)
        // The interior of a screen-sized frame is not near it: only its edge region is.
        fileDrag(r, at: CGPoint(x: 800, y: 500), time: 2)
        #expect(!r.controller.isOpen, "the middle of a maximized frame is far from its edges")
        fileDrag(r, at: CGPoint(x: 800, y: 40), time: 3)
        #expect(r.controller.livePanel?.frame == maximized, "\(String(describing: r.controller.livePanel?.frame))")
        r.controller.gesture(.toggleMaximize)
        #expect(r.controller.livePanel?.frame == closed, "Restore returns to the restore rect: \(String(describing: r.controller.livePanel?.frame))")
    }

    @Test func ChatRecall_aDragFarFromBothTheClosedPanelAndClawdNeverRecallsAndOneNearClawdDoes() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        r.rig.host.petFrame = CGRect(x: 100, y: 700, width: 60, height: 60)
        try clickClose(r)
        fileDrag(r, at: CGPoint(x: 1400, y: 900), time: 2)
        #expect(!r.controller.isOpen, "far from both")
        fileDrag(r, at: CGPoint(x: 130, y: 570), time: 3)
        #expect(!r.controller.isOpen, "130 pt below Clawd's body is not near it")
        fileDrag(r, at: CGPoint(x: 130, y: 600), time: 4)
        #expect(r.controller.isOpen && r.rig.lines("CHAT recall").count == 1, "within 120 pt of Clawd: \(r.rig.lines("CHAT"))")
    }

    @Test func ChatRecall_theDragProximityIsExactly120Points() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try clickClose(r)
        fileDrag(r, at: CGPoint(x: closed.minX - 120.5, y: 300), time: 2)
        #expect(!r.controller.isOpen, "120.5 pt left of the closed panel")
        fileDrag(r, at: CGPoint(x: closed.minX - 120, y: 300), time: 3)
        #expect(r.controller.isOpen, "120 pt")
    }

    @Test func ChatRecall_aRecalledPanelThePointerLeavesByMoreThan120PointsClosesAgain() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try clickClose(r)
        fileDrag(r, at: CGPoint(x: 900, y: 300), time: 2)
        #expect(r.controller.isOpen)
        r.rig.focus.dragEvent(.dragged, time: 3, at: CGPoint(x: closed.minX - 100, y: 300))
        #expect(r.controller.isOpen, "100 pt away is still near")
        r.rig.focus.dragEvent(.dragged, time: 4, at: CGPoint(x: closed.minX - 130, y: 300))
        #expect(!r.controller.isOpen && r.rig.lines("CHAT close reason=recall").count == 1, "\(r.rig.lines("CHAT close"))")
    }

    @Test func ChatRecall_aRecalledPanelTheDragDoesNotEnterWithinThreeSecondsClosesAndOneItEntersStays() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try clickClose(r)
        fileDrag(r, at: CGPoint(x: 900, y: 300), time: 2)
        r.rig.focus.timers.fire(exactly: 3)
        #expect(!r.controller.isOpen && r.rig.lines("CHAT close reason=recall").count == 1)
        let stay = try recallRig()
        defer { stay.cleanUp() }
        try clickClose(stay)
        fileDrag(stay, at: CGPoint(x: 900, y: 300), time: 2)
        _ = stay.body.destination.draggingEntered?(FakeDrag(DragBoard(files: ["/a"])))
        stay.rig.focus.timers.fire(exactly: 3)
        #expect(stay.controller.isOpen, "the drag entered the panel in time")
    }

    @Test func ChatRecall_aDragEndNeverSeenClosesAtTheTenSecondCheckAndAHeldButtonReArmsIt() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try clickClose(r)
        fileDrag(r, at: CGPoint(x: 900, y: 300), time: 2)
        _ = r.body.destination.draggingEntered?(FakeDrag(DragBoard(files: ["/a"])))
        r.rig.focus.pressed = 1
        r.rig.focus.timers.fire(exactly: 10)
        #expect(r.controller.isOpen, "the left button is still down: the check re-arms")
        r.rig.focus.pressed = 0
        r.rig.focus.timers.fire(exactly: 10)
        #expect(!r.controller.isOpen && r.rig.lines("CHAT close reason=recall").count == 1, "closed within 10 s of the button going up: \(r.rig.lines("CHAT"))")
    }

    @Test func ChatRecall_theThirtySecondDeadlineGatesOnlyTheStartOfARecall() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try clickClose(r)
        fileDrag(r, at: CGPoint(x: 900, y: 300), time: 2)
        _ = r.body.destination.draggingEntered?(FakeDrag(DragBoard(files: ["/a"])))
        r.rig.focus.timers.fire(exactly: 30)
        #expect(r.controller.isOpen && r.rig.focus.liveDragProbes == 1, "the recall continues until its drag ends")
        r.rig.focus.dragEvent(.up, time: 40)
        #expect(r.controller.isOpen, "the drag is inside the body: its drop may still follow the up (H1)")
        r.rig.focus.timers.fire(exactly: ChatController.recallDropGrace)
        #expect(!r.controller.isOpen && r.rig.lines("CHAT close reason=recall").count == 1)
    }

    @Test func ChatRecall_thePasteboardIsReadAtMostOncePer50MillisecondsOfEventTimeAndNeverItsContents() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try clickClose(r)
        r.rig.focus.dragBoard = ChatDragPasteboardState(changeCount: 0, hasFileURLs: true)
        let before = r.rig.focus.dragBoardReads
        for i in 0..<100 { r.rig.focus.dragEvent(.dragged, time: Double(i) * 0.005, at: CGPoint(x: 900, y: 300)) }
        let reads = r.rig.focus.dragBoardReads - before
        #expect(reads <= 11, "100 events over 0.5 s of event time read the board \(reads) times")
        // The seam's value carries a change count and a flag: there is no call that returns contents.
        let state = ChatDragPasteboardState(changeCount: 1, hasFileURLs: true)
        #expect(Mirror(reflecting: state).children.map { $0.label ?? "" } == ["changeCount", "hasFileURLs"])
    }

    @Test func ChatRecall_aSecondOpenBeforeTheDragRemovesTheProbe() throws {
        let r = try recallRig()
        defer { r.cleanUp() }
        try clickClose(r)
        r.rig.open(at: 9)
        #expect(r.controller.isOpen && r.rig.focus.liveDragProbes == 0, "any open removes the probe")
    }
}
