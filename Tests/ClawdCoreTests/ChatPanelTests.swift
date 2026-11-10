import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// F1.2 to F1.4, F3, F4: placement, close paths, keys, the input, the rendering and the scenes. No window is ever on screen.

@Suite("Chat panel", .serialized)
@MainActor
struct ChatPanelSuite {
    // MARK: placement

    @Test func ChatPanel_placementIsInsideTheVisibleFrameOnBothSidesAtEverySize() {
        let visible = CGRect(x: 0, y: 40, width: 1920, height: 1040)
        for x in stride(from: 0.0, through: 1850.0, by: 37) {
            for side in BubbleSide.allCases {
                let canvas = CGRect(x: x, y: 40, width: 64, height: 64)
                let rect = ChatPanelPlacement.rect(canvas: canvas, bubbleSide: side, visible: visible)
                #expect(visible.contains(rect), "x=\(x) \(side): \(rect)")
                #expect(rect.width == 380 && rect.height == 480)
                #expect(!rect.intersects(canvas) || rect.minX >= canvas.maxX - 1 || rect.maxX <= canvas.minX + 1, "beside, not over, Clawd: \(rect) \(canvas)")
            }
        }
        let short = CGRect(x: 0, y: 0, width: 1000, height: 300)
        let rect = ChatPanelPlacement.rect(canvas: CGRect(x: 400, y: 0, width: 64, height: 64), bubbleSide: .below, visible: short)
        #expect(rect.height == 284 && short.contains(rect), "\(rect)")
    }

    @Test func ChatPanel_theSideIsOppositeALeftOrRightBubbleElseTheSideWithMoreRoom() {
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let middle = CGRect(x: 900, y: 100, width: 64, height: 64)
        #expect(ChatPanelPlacement.rect(canvas: middle, bubbleSide: .left, visible: visible).minX >= middle.maxX)
        #expect(ChatPanelPlacement.rect(canvas: middle, bubbleSide: .right, visible: visible).maxX <= middle.minX)
        let nearLeft = CGRect(x: 100, y: 100, width: 64, height: 64)
        #expect(ChatPanelPlacement.rect(canvas: nearLeft, bubbleSide: .below, visible: visible).minX >= nearLeft.maxX, "more room on the right")
        let nearRight = CGRect(x: 1700, y: 100, width: 64, height: 64)
        #expect(ChatPanelPlacement.rect(canvas: nearRight, bubbleSide: .above, visible: visible).maxX <= nearRight.minX, "more room on the left")
        #expect(ChatPanelPlacement.rect(canvas: middle, bubbleSide: .below, visible: visible).minY == middle.minY, "level with Clawd's feet")
    }

    @Test func ChatPanel_aReplacementKeepsItOpenAndOnlyMovesTheFrame() {
        let r = ControllerRig()
        r.open()
        let panel = r.controller.livePanel
        r.host.rect = CGRect(x: 100, y: 50, width: 380, height: 400)
        r.controller.replace()
        #expect(r.controller.livePanel === panel && panel?.frame == r.host.rect)
        #expect(r.keys.count == 1 && r.lines("CHAT close").isEmpty)
    }

    // MARK: close paths and the draft

    @Test func ChatPanel_everyCloseReasonLogsItsLineWithTheDraftLength() {
        for reason in ChatCloseReason.allCases {
            let r = ControllerRig()
            r.open()
            r.type("héllo 日本")
            switch reason {
            case .esc: r.pressEsc()
            case .toggle: r.controller.toggle(eventTime: 2)
            case .button: r.view.onClose?()
            case .menu: r.controller.closeForMenu()
            case .drag: r.controller.closeForDrag()
            case .hidden: r.controller.closeForHidden()
            case .exam: r.host.examActive = true; r.controller.batchEnded()
            case .off: r.enabled = false; r.controller.settingsApplied()
            case .contract: r.controller.close(.contract)
            case .quit: r.controller.shutdown()
            case .outside:
                r.focus.surfaceOwner = { _ in "unknown" }
                r.focus.outsidePress(ChatOutsidePress(time: 3, location: CGPoint(x: 5, y: 5)))
                r.focus.followUp(.up, CGPoint(x: 5, y: 5))
            case .recall: r.controller.close(.recall)   // a recalled panel's own end (ChatOrcaParityB_*)
            case .shortcut, .view: continue          // the terminal path's own reasons (ChatTermIO_*, ChatFocus_*)
            }
            // Only an outside close says what closed it.
            let by = reason == .outside ? " by=press:unknown" : ""
            #expect(r.lines("CHAT close") == ["CHAT close reason=\(reason.rawValue) gen=1 draft=8\(by)"], "\(reason): \(r.logs)")
            #expect(r.controller.livePanel == nil && r.dismissed == 1)
        }
    }

    @Test func ChatPanel_hiddenAndContractClosesDrawNothingAndOthersDo() {
        let r = ControllerRig()
        r.open(); r.controller.closeForHidden()
        r.open(); r.controller.close(.toggle)
        #expect(r.host.events == ["menu-close", "open", "close render=false", "menu-close", "open", "close render=true"])
    }

    @Test func ChatPanel_theDraftSurvivesCloseAndReopenAndAnOutsideEventClosesNothing() {
        let r = ControllerRig()
        r.open()
        r.type("half a message")
        r.controller.resigned(r.controller.livePanel)
        #expect(r.controller.isOpen, "losing key does not close")
        r.controller.close(.esc)
        #expect(r.lines("CHAT close")[0].hasSuffix("draft=14"))
        r.open(at: 3)
        #expect(r.view.inputText == "half a message")
        #expect(r.lines("CHAT open").count == 2 && r.lines("CHAT open")[1].hasPrefix("CHAT open et=3.000000 gen=2"))
        #expect(r.editMenus == 1, "the Edit menu is installed once")
    }

    // MARK: keys

    @Test func ChatPanel_enterSendsShiftAndOptionEnterInsertANewlineEscCloses() {
        let r = ControllerRig()
        r.open()
        r.type("one")
        r.pressEnter(modifiers: .shift); r.type("two")
        r.pressEnter(modifiers: .option); r.type("three")
        #expect(r.view.inputText == "one\ntwo\nthree" && r.session.sent.isEmpty)
        r.pressEnter()
        #expect(r.session.sent == ["one\ntwo\nthree"] && r.view.inputText == "", "accepted: the input clears")
        r.pressEsc()
        #expect(!r.controller.isOpen && r.lines("CHAT close")[0].hasPrefix("CHAT close reason=esc"))
    }

    @Test func ChatPanel_enterAndEscWhileMarkedTextExistsDoNothingOfTheirOwn() {
        let r = ControllerRig()
        r.open()
        let input = r.view.inputView
        input.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(input.hasMarkedText())
        r.pressEnter(); r.pressEsc()
        #expect(r.session.sent.isEmpty && r.controller.isOpen, "nothing sent, nothing closed: \(r.logs)")
    }

    @Test func ChatPanel_sendIsDisabledWhileATurnRunsOrStopsAndTheDraftStaysEditable() {
        let r = ControllerRig()
        r.open()
        r.type("first"); r.pressEnter()
        #expect(r.session.turn == .running && !r.view.isSendEnabled && r.view.sendTitle == "Claude is working" && r.view.isStopVisible)
        r.type("second")
        r.pressEnter()
        #expect(r.session.sent == ["first"] && r.view.inputText == "second", "a send while a turn runs does nothing; the draft stays")
        r.session.turn = .stopping; r.session.onChange?()
        #expect(!r.view.isSendEnabled && r.view.sendTitle == "Claude is stopping")
        r.session.finish(.success(seconds: 1))
        #expect(r.view.isSendEnabled && r.view.sendTitle == "Send" && !r.view.isStopVisible)
    }

    @Test func ChatPanel_aBlankDraftSendsNothing() {
        let r = ControllerRig()
        r.open(); r.type("  \n "); r.pressEnter()
        #expect(r.session.sent.isEmpty && r.view.inputText == "  \n ")
    }

    @Test func ChatPanel_anInsertionOverOneMiBIsRefusedWholeWithANotice() {
        let r = ControllerRig()
        r.open()
        r.type("x")
        let big = String(repeating: "a", count: ChatInputCap.bytes + 1 - 1)   // 1 byte draft + this = exactly 1 MiB + 1
        r.type(big)
        #expect(r.view.inputText == "x", "the draft is unchanged")
        #expect(r.view.statusText.contains("1 MiB"))
        r.type(String(repeating: "b", count: ChatInputCap.bytes - 1))
        #expect(r.view.inputText.utf8.count == ChatInputCap.bytes, "exactly the cap is accepted")
        #expect(ChatInputCap.accepts(current: "日本", range: NSRange(location: 0, length: 2), replacement: String(repeating: "あ", count: 349_525)))
        #expect(!ChatInputCap.accepts(current: "日本", range: NSRange(location: 0, length: 0), replacement: String(repeating: "あ", count: 349_525)))
    }

    @Test func ChatPanel_enterLocksTheInputUntilTheBridgeAnswers() {
        let r = ControllerRig()
        r.open()
        var lockedDuringSend = false, textDuringSend = ""
        r.session.duringSend = { [unowned r] _ in lockedDuringSend = r.view.isInputLocked; textDuringSend = r.view.inputText }
        r.type("go")
        r.pressEnter()
        #expect(lockedDuringSend && textDuringSend == "go", "locked, text still there, while the bridge answers")
        #expect(!r.view.isInputLocked && r.view.inputText == "")
        // A refused send unlocks with the text intact.
        r.session.finish(.success(seconds: 1))
        r.session.accept = false
        r.type("again"); r.pressEnter()
        #expect(!r.view.isInputLocked && r.view.inputText == "again", "the text is kept when the bridge refuses")
        #expect(r.view.statusText.hasPrefix("Not sent"))
    }

    @Test func ChatPanel_theEditKeysWorkInTheInput() {
        let r = ControllerRig()
        r.open()
        let input = r.view.inputView
        r.type("abc")
        input.selectAll(nil)
        #expect(input.handleEditKey("c", shift: false) && input.handleEditKey("x", shift: false) && input.string == "")
        #expect(input.handleEditKey("v", shift: false) && input.string == "abc", "cut then paste through the pasteboard")
        #expect(!input.handleEditKey("q", shift: false))
        #expect(!input.isAutomaticSpellingCorrectionEnabled && !input.isAutomaticQuoteSubstitutionEnabled
                && !input.isAutomaticDashSubstitutionEnabled && !input.isAutomaticTextReplacementEnabled)
    }

    // MARK: rendering

    @Test func ChatPanel_theTranscriptShowsEveryEntryKindWithCodeMonospacedAndToolGlyphs() {
        var transcript = ChatTranscript()
        transcript.appendUser("fix it")
        transcript.apply(.assistantBlocks(messageKey: "m", blocks: [.text("Here:\n```swift\nlet a = 1\n```\nuse `a` now")]))
        transcript.apply(.toolStarted(id: "t1", name: "Bash"))
        transcript.apply(.toolInput(id: "t1", summary: "ls -la"))
        transcript.apply(.toolResult(id: "t1", isError: false))
        transcript.apply(.toolStarted(id: "t2", name: "Edit"))
        transcript.apply(.toolResult(id: "t2", isError: true))
        transcript.apply(.compacted)
        transcript.apply(.result(outcome: .success, durationMs: 2500, totalCost: 0.0123, sessionId: "s", text: ""))
        let text = ChatPanelRender.render(transcript.entries)
        let plain = text.string
        for expected in ["fix it", "Here:", "let a = 1", "use a now", "✓ Bash  ls -la", "✕ Edit", "2.5 s", "as Claude Code reports it"] {
            #expect(plain.contains(expected), "\(expected) in \(plain)")
        }
        #expect(!plain.contains("```"))
        func font(of needle: String) -> NSFont? {
            let range = (plain as NSString).range(of: needle)
            return range.location == NSNotFound ? nil : text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        }
        #expect(font(of: "let a = 1")?.isFixedPitch == true, "a fenced block is monospaced")
        #expect(font(of: "use ")?.isFixedPitch == false)
        #expect(font(of: "a now") != nil)
        let inline = (plain as NSString).range(of: "a", options: [], range: (plain as NSString).range(of: "use a now"))
        _ = inline
        var longer = ChatTranscript()
        longer.apply(.toolStarted(id: "t", name: "Bash"))
        longer.apply(.toolInput(id: "t", summary: String(repeating: "z", count: 300)))
        longer.apply(.toolProgress(id: "t", seconds: 4))
        let line = ChatPanelRender.toolLine(longer.entries[0])
        #expect(line.hasSuffix("(4s)") && line.hasPrefix("… Bash") && line.count < 120 + 30, "cut to 120 characters: \(line.count)")
    }

    @Test func ChatPanel_autoScrollFollowsOnlyWhileAtTheBottomAndMarksNewOutputOtherwise() {
        let r = ControllerRig()
        r.open()
        var transcript = ChatTranscript()
        for i in 0..<80 { transcript.appendUser("line \(i)") }
        r.view.frame = NSRect(x: 0, y: 0, width: 380, height: 300)
        r.view.layoutSubtreeIfNeeded()
        r.view.setTranscript(transcript.entries)
        #expect(r.view.isAtBottom && !r.view.isNewOutputShown)
        // Scrolled up by the user: new output does not jump.
        r.view.transcriptView.scroll(NSPoint(x: 0, y: 0))
        let scroller = r.view.transcriptView.enclosingScrollView!
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 0)); scroller.reflectScrolledClipView(scroller.contentView)
        #expect(!r.view.isAtBottom)
        transcript.appendUser("new")
        r.view.setTranscript(transcript.entries)
        #expect(!r.view.isAtBottom && r.view.isNewOutputShown, "a marker instead of a jump")
        r.view.scrollToEnd()
        #expect(r.view.isAtBottom && !r.view.isNewOutputShown)
    }

    @Test func ChatPanel_theSessionsChangesReachTheOpenPanelAndAClosedPanelIsNotTouched() {
        let r = ControllerRig()
        r.open()
        r.type("hi"); r.pressEnter()
        #expect(r.view.transcriptView.string.contains("hi"))
        r.controller.close(.esc)
        r.session.transcript.appendUser("later")
        r.session.onChange?()   // no panel: nothing to update, nothing breaks
        r.open(at: 5)
        #expect(r.view.transcriptView.string.contains("later"), "reopening shows what happened while closed")
    }

    // MARK: the child's stops

    @Test func ChatPanel_theIdleStopRunsTenMinutesAfterTheCloseWithNoTurn() {
        let r = ControllerRig()
        r.open()
        r.controller.close(.esc)
        #expect(r.timer.fireAt == r.clock.now + 600, "one one-shot timer, armed at the close")
        r.open(at: 9)
        #expect(r.timer.fireAt == nil, "an open panel cancels it")
        r.controller.close(.esc)
        r.timer.onFire?()
        #expect(r.session.stops == [.panelClosedLong])
        // A running turn never arms it; the end of the turn does.
        let busy = ControllerRig()
        busy.open(); busy.type("go"); busy.pressEnter(); busy.controller.close(.esc)
        #expect(busy.timer.fireAt == nil)
        busy.session.finish(.success(seconds: 2))
        #expect(busy.timer.fireAt != nil)
    }

    @Test func ChatPanel_examChatOffAndQuitHardStopTheChild() {
        let exam = ControllerRig()
        exam.open(); exam.host.examActive = true
        exam.controller.batchEnded(); exam.controller.batchEnded()
        #expect(exam.session.stops == [.exam], "once per stand-down")
        exam.host.examActive = false; exam.controller.batchEnded()
        exam.host.examActive = true; exam.controller.batchEnded()
        #expect(exam.session.stops == [.exam, .exam])
        let off = ControllerRig()
        off.open(); off.enabled = false; off.controller.settingsApplied(); off.controller.settingsApplied()
        #expect(off.session.stops == [.chatOff])
        let quit = ControllerRig()
        quit.open(); quit.controller.shutdown()
        #expect(quit.session.stops == [.agentQuit])
        #expect(quit.lines("CHAT close")[0].hasPrefix("CHAT close reason=quit"))
    }

    // MARK: chatHold and the scenes

    @Test func ChatPanel_chatHoldStopsWalksAndAWalkInProgressStandsStill() throws {
        let r = try ChatRuntimeRig(virtual: true)
        let scheduler = r.rig.stage.scheduler
        scheduler.chatOpened()
        #expect(scheduler.chatOpen)
        var starts = 0
        let original = scheduler.onEvent
        scheduler.onEvent = { at, event in if case .walkStart = event { starts += 1 }; original?(at, event) }
        r.rig.advance(900)
        #expect(starts == 0, "no walk starts while the chat is open")
        scheduler.chatClosed()
        #expect(!scheduler.chatOpen)
    }

    @Test func ChatPanel_aChatTurnPlaysThinkingWithNoTimeoutThenSentWithTheDurationOrErrorOrInterrupted() throws {
        let r = try ChatRuntimeRig(virtual: true)
        try r.doubleClick()
        let session = r.session
        _ = session.send("work")
        #expect(r.rig.runtime.controller.machine.baseScene == .thinking, "a send starts THINKING")
        r.rig.advance(600)
        #expect(r.rig.runtime.controller.machine.baseScene == .thinking, "10 minutes later it is still THINKING (no timeout)")
        session.finish(.success(seconds: 42))
        r.rig.advance(1.1)
        let machine = r.rig.runtime.controller.machine
        #expect(machine.baseScene == .sent && machine.duration == 42, "SENT shows the result's duration")
        r.rig.advance(2.1)
        #expect(machine.baseScene == .idle)
        r.session.turn = .none
        _ = session.send("again"); r.rig.advance(1.1)
        session.finish(.error)
        #expect(machine.baseScene == .error)
        r.rig.advance(1.6)
        #expect(machine.baseScene == .idle)
        _ = session.send("third"); r.rig.advance(1.1)
        session.finish(.interrupted)
        #expect(machine.baseScene == .interrupted)
        r.rig.advance(1.6)
        #expect(machine.baseScene == .idle)
    }

    @Test func ChatPanel_aDictationInsideATurnReturnsToThinkingAndAResetKeepsTheTurn() throws {
        let r = try ChatRuntimeRig(virtual: true)
        try r.doubleClick()
        _ = r.session.send("work")
        let machine = r.rig.runtime.controller.machine
        machine.reset()
        #expect(machine.baseScene == .thinking, "reset keeps the chat turn")
        let clock = r.rig.virtualClock!
        r.rig.advance(1.1)   // THINKING is shown for at least one second before another scene replaces it
        r.rig.runtime.controller.receive(line: startLine(clock).trimmingCharacters(in: .newlines))
        #expect(machine.baseScene == .listening)
        r.rig.advance(200)   // the 180 s listening timeout would end in IDLE
        #expect(machine.baseScene == .thinking, "where it would return to IDLE it returns to THINKING")
        r.session.finish(.success(seconds: 1))
        r.rig.advance(1.1)
        #expect(machine.baseScene == .sent)
    }
}
