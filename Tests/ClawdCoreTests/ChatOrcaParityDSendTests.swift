import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop

// Orca parity round D, sprint 4, the panel side: queued sends while Claude answers (Q12), Steer and Cmd+Enter (Q13), the one send gate (D18), the
// queue list inside the body and the doubt cards that survive a restart. No window is shown or made key; the timers are manual and the state root
// is a temporary directory. The session is the fake one, which takes a steer while a turn runs and lets a test settle a send as the ledger would.

@MainActor
private final class QueueRig {
    let state: OwnState
    let timers = ManualChatTimers()
    let web: WebKindRig

    init(state: OwnState? = nil, isInstalled: @escaping () -> Bool = { true }) throws {
        self.state = try state ?? artifactStore()
        var attach = ChatAttachEnvironment()
        attach.state = self.state
        web = WebKindRig(isInstalled: isInstalled, attach: attach, composerTimers: timers)
    }

    var rig: ControllerRig { web.rig }
    var controller: ChatController { web.controller }
    var body: ChatWebBody { web.body! }
    var input: ChatInputTextView { body.inputView }
    var session: FakeChatSession { rig.session }
    var queue: ChatQueue { controller.queue }

    func open(at time: TimeInterval = 1) throws {
        rig.open(at: time)
        try #require(controller.isOpen, "the chat opened: \(rig.logs)")
    }
    /// Enter with `text` in the input.
    func enter(_ text: String) {
        body.inputText = text
        web.pressEnter()
    }
    /// A turn that runs: the first send.
    func startTurn(_ text: String = "first") {
        enter(text)
        #expect(session.turn == .running, "the first send began a turn")
        if let first = session.requests.last { session.deliver(first) }
    }
    func savedFile() throws -> ChatComposerFile {
        try JSONDecoder().decode(ChatComposerFile.self, from: ReadOnlyFile.data(state.root.appendingPathComponent(ChatComposerStore.fileName).path, limit: ChatComposerStore.capBytes))
    }
    var texts: [String] { queue.cards.map(\.text) }
    var list: ChatQueueListView { body.queueList }
    /// A real PNG file in the rig's state folder: a send with chips reads its files (Q16).
    func picture(_ name: String) throws -> String {
        let url = state.root.appendingPathComponent(name)
        try pngData().write(to: url)
        return url.path
    }
    func pressStop() { body.composer.sendButton.performClick(nil) }
    var examActive: Bool {
        get { rig.host.examActive }
        set { rig.host.examActive = newValue }
    }
    var log: [String] { rig.logs }
}

@Suite("Chat orca parity D, queued sends, steer and the send gate", .serialized)
@MainActor
struct ChatOrcaParityDSendSuite {
    // MARK: Q12, cards

    @Test func ChatOrcaD12_twoEntersDuringARunningTurnMakeTwoCardsAndSendNothingAndTheDraftClearsAndHistoryGetsThem() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("second")
        r.enter("third")
        #expect(r.texts == ["second", "third"] && r.session.sent == ["first"], "two cards, nothing sent: \(r.texts) \(r.session.sent)")
        #expect(r.body.inputText.isEmpty && r.controller.draft.isEmpty)
        #expect(r.controller.history.entries == ["first", "second", "third"])
        #expect(r.log.contains("CHAT queue add n=1 chars=6") && r.log.contains("CHAT queue add n=2 chars=5"), "\(r.log)")
        let file = try r.savedFile()
        #expect(file.cards?.map(\.text) == ["second", "third"] && file.draft == nil, "saved at once")
        #expect(r.list.rows.map(\.shownText) == ["second", "third"] && r.log.allSatisfy { !$0.contains("second") }, "the log rule: counts only")
    }

    @Test func ChatOrcaD12_theTurnsIdleSendsTheFirstCardAndOnlyThatOneAndItsIdleSendsTheSecond() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("second"); r.enter("third")
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent == ["first", "second"] && r.session.turn == .running, "only the first card, as an ordinary new turn: \(r.session.sent)")
        #expect(r.texts == ["third"] && r.session.requests.last?.steer == false && r.session.requests.last?.person == false)
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent == ["first", "second", "third"] && r.texts.isEmpty && r.list.rows.isEmpty)
        #expect(r.controller.history.entries == ["first", "second", "third"], "a drained card is not pushed again")
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent.count == 3, "an empty queue sends nothing")
    }

    @Test func ChatOrcaD12_anInterruptPausesWithStoppedAndTheCardStaysAndResumeSendsItAtTheNextTurnEndOrAtOnceWhenIdle() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("later")
        r.pressStop()
        #expect(r.session.interrupts == 1 && r.queue.pause == .stopped && r.list.pauseRow?.text == "Queue paused because you interrupted", "\(r.queue.pause)")
        r.session.finish(.interrupted)
        #expect(r.session.sent == ["first"] && r.texts == ["later"], "a Stop never withdraws and the paused queue sends nothing")
        r.list.pauseRow?.resumeButton.performClick(nil)
        #expect(r.queue.pause == .none && r.session.sent == ["first", "later"] && r.texts.isEmpty, "Resume sends it at once when idle: \(r.session.sent)")
        // And while the turn still runs: Resume lifts the pause and the card goes at the turn's end.
        r.enter("again")
        r.pressStop()
        r.list.pauseRow?.resumeButton.performClick(nil)
        #expect(r.queue.pause == .none && r.session.sent.count == 2 && r.texts == ["again"], "\(r.session.sent)")
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent.last == "again")
    }

    @Test func ChatOrcaD12_escDuringARunningTurnPausesTheQueueWithStoppedToo() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("later")
        r.input.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(r.session.interrupts == 1 && r.queue.pause == .stopped)
    }

    @Test func ChatOrcaD12_theExamStandDownActiveAtATurnEndWithACardWaitingSpawnsNothingKeepsTheCardAndPausesWithOther() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("waiting")
        r.examActive = true
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent == ["first"] && r.texts == ["waiting"], "no send: \(r.session.sent)")
        #expect(r.queue.pause == .other && r.log.contains("CHAT queue pause reason=other"), "\(r.log)")
        r.examActive = false
        r.rig.host.examRunning = true
        r.enter("manual")
        #expect(r.session.sent == ["first"] && r.body.inputText == "manual" && r.body.statusText == "Not sent: an exam browser is running", "a refused manual send keeps the draft")
    }

    @Test func ChatOrcaD12_aChatViewChangeAndAChildExitWithCardsWaitingPauseWithOtherAndTheDrainDoesNotRespawn() throws {
        let view = try QueueRig()
        try view.open()
        view.startTurn()
        view.enter("waiting")
        view.rig.chatSettings.view = .stream
        view.controller.settingsApplied()
        #expect(view.queue.pause == .other)
        view.session.finish(.success(seconds: 1))
        #expect(view.session.sent == ["first"] && view.texts == ["waiting"], "no respawn by the drain: \(view.session.sent)")
        let exit = try QueueRig()
        try exit.open()
        exit.startTurn()
        exit.enter("waiting")
        exit.session.onChildLost?(.exited)
        #expect(exit.queue.pause == .other)
        exit.session.finish(.error)
        #expect(exit.session.sent == ["first"] && exit.texts == ["waiting"])
        let off = try QueueRig()
        try off.open()
        off.startTurn()
        off.enter("waiting")
        off.controller.settingsApplied()
        #expect(off.queue.pause == .none, "nothing changed yet")
        off.rig.enabled = false
        off.controller.settingsApplied()
        #expect(off.queue.pause == .other && off.rig.session.stops == [.chatOff])
        // With no card waiting the drain's refused gate cannot pause the queue: the stop itself must.
        let bare = try QueueRig()
        try bare.open()
        bare.startTurn()
        bare.controller.settingsApplied()
        bare.rig.enabled = false
        bare.controller.settingsApplied()
        #expect(bare.queue.pause == .other && bare.rig.session.stops == [.chatOff], "\(bare.queue.pause)")
    }

    @Test func ChatOrcaD12_aSendWhilePausedAndIdleGoesAtOnceAndItsTurnStartingLiftsThePauseSoTheCardGoesAtItsEnd() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("later")
        r.pressStop()
        r.session.finish(.interrupted)
        #expect(r.queue.pause == .stopped)
        r.enter("now")
        #expect(r.session.sent == ["first", "now"] && r.texts == ["later"], "a paused queue does not trap a new send: \(r.session.sent)")
        #expect(r.queue.pause == .none, "its turn starting lifted the pause")
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent == ["first", "now", "later"])
    }

    @Test func ChatOrcaD12_theTwentyFirstCardIsRefusedWithTheWordsAndSoIsACardPastOneMiBAndTheDraftIsKept() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        for index in 0..<20 { r.enter("m\(index)") }
        #expect(r.texts.count == 20)
        r.enter("one too many")
        #expect(r.texts.count == 20 && r.body.inputText == "one too many" && r.body.statusText == "The message queue is full. Send again after the current turn ends.")
        let big = try QueueRig()
        try big.open()
        big.startTurn()
        big.enter(String(repeating: "x ", count: 175_000)); big.enter(String(repeating: "y ", count: 175_000))
        #expect(big.texts.count == 2)
        let over = String(repeating: "z ", count: 180_000)
        big.enter(over)
        #expect(big.texts.count == 2 && big.body.inputText == over && big.body.statusText.hasPrefix("The message queue is full"), "past 1 MiB in all")
    }

    @Test func ChatOrcaD12_aDrainedCardWhoseWriteFailsBecomesSendFailedInItsPlaceAndTheDraftIsUnchanged() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("card one"); r.enter("card two")
        r.body.inputText = "what I am typing"
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent.last == "card one")
        r.session.failSend("card one")
        try #require(r.queue.cards.count > 0, "r.queue.cards needs 1 elements: \(r.queue.cards.count)")
        #expect(r.texts == ["card one", "card two"] && r.queue.cards[0].paused == "send-failed", "it keeps its place, held on its own: \(r.queue.cards)")
        #expect(r.body.inputText == "what I am typing" && r.controller.draft != "card one", "a card's failure never touches the draft")
        try #require(r.list.rows.count > 0, "r.list.rows needs 1 elements: \(r.list.rows.count)")
        #expect(r.list.rows[0].captionText == "Couldn't send \u{2014} press Send to retry.")
        #expect((try r.savedFile()).inflight == nil)
    }

    @Test func ChatOrcaD12_aDraftSendWhoseWriteFailsGoesBackToTheDraftOnly() throws {
        let r = try QueueRig()
        try r.open()
        r.enter("lost text")
        r.session.failSend("lost text")
        try #expect(r.body.inputText == "lost text" && r.texts.isEmpty && (try r.savedFile()).inflight == nil && (try r.savedFile()).draft == "lost text")
    }

    @Test func ChatOrcaD12_aSendWithAChipDuringATurnIsNotQueuedItIsWrittenIntoTheTurn() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        let picture = try r.picture("example.png")
        r.body.composer.attachImages(paths: [picture])
        r.enter("look at this")
        #expect(r.texts.isEmpty && r.session.requests.last?.steer == true && r.session.sent == ["first", "look at this"], "\(r.session.sent)")
        #expect(r.session.requests.last?.chips.count == 1 && r.controller.composerStore?.content.chips == nil, "the chips went with the send")
        #expect((try r.savedFile()).inflight?.first?.chips?.count == 1, "and are kept in the in-flight list")
    }

    @Test func ChatOrcaD12_withTheQueueTurnedOffASendMidTurnIsWrittenIntoTheTurnAtOnce() throws {
        let r = try QueueRig()
        try r.open()
        r.rig.chatSettings.queueFollowUps = false
        r.startTurn()
        r.enter("right now")
        #expect(r.texts.isEmpty && r.session.requests.last?.steer == true && r.session.sent == ["first", "right now"])
        #expect(r.session.transcript.entries.last?.sending == true, "a pending entry in the transcript")
    }

    @Test func ChatOrcaD12_editOnXWithTheDraftYGivesYBlankLineXAndTheDraftAlreadyEndingInItLeavesItAndTheCardGoes() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("x")
        r.body.inputText = "y"
        r.list.rows[0].moreButton.menu?.performActionForItem(at: 1)
        #expect(r.body.inputText == "y\n\nx" && r.texts.isEmpty && r.log.contains("CHAT queue edit"), "\(r.body.inputText.debugDescription)")
        try #expect((try r.savedFile()).draft == "y\n\nx" && (try r.savedFile()).cards == nil)
        r.enter("x")
        r.body.inputText = "y\n\nx"
        r.list.rows[0].moreButton.menu?.performActionForItem(at: 1)
        #expect(r.body.inputText == "y\n\nx" && r.texts.isEmpty, "never a duplicate")
    }

    @Test func ChatOrcaD12_theCardMenuHoldsOnlyEditMessage() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("x")
        let titles = (r.list.rows[0].moreButton.menu?.items ?? []).dropFirst().map(\.title)
        #expect(Array(titles) == ["Edit message"], "Turn off queueing needs a settings write the panel cannot make (D13): \(titles)")
    }

    @Test func ChatOrcaD12_editWithADraftThatCannotBeSavedKeepsTheCardAndShowsTheTextInBothPlaces() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("keep me")
        try FileManager.default.removeItem(at: r.state.root.appendingPathComponent("chat-private"))
        try FileManager.default.createDirectory(at: r.state.root.appendingPathComponent("chat-private"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        r.list.rows[0].moreButton.menu?.performActionForItem(at: 1)
        #expect(r.body.inputText == "keep me" && r.texts == ["keep me"], "the card stays: \(r.texts)")
        #expect(r.controller.composerStore?.saveFailed == true && r.body.composer.isDraftWarningShown)
    }

    @Test func ChatOrcaD12_deleteRemovesTheCardAndADeleteOfOneThatIsAlreadyGoneSaysSo() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("one"); r.enter("two")
        let stale = r.list.rows[0]
        stale.deleteButton.performClick(nil)
        try #expect(r.texts == ["two"] && r.log.contains("CHAT queue delete") && (try r.savedFile()).cards?.map(\.text) == ["two"])
        stale.deleteButton.performClick(nil)
        #expect(r.texts == ["two"] && r.body.statusText == "This message was already sent.", "a card the drain sent is gone from the list anyway")
    }

    @Test func ChatOrcaD12_afterSteerDeleteOrEditTheKeyboardGoesToTheInput() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("one"); r.enter("two"); r.enter("three")
        let panel = try #require(r.controller.livePanel)
        for action in [{ r.list.rows[0].steerButton.performClick(nil) }, { r.list.rows[0].deleteButton.performClick(nil) }] {
            _ = panel.makeFirstResponder(nil)
            action()
            #expect(panel.firstResponder === r.input, "the input has the keyboard again")
        }
    }

    // MARK: Q12, the list in the body

    @Test func ChatOrcaD12_theListSitsBetweenTheTranscriptAndTheComposerTheWebViewShrinksByItsHeightAndTheComposersHeightIsUnchanged() throws {
        let r = try QueueRig()
        try r.open()
        let before = (composer: r.body.composer.frame, web: r.body.page?.view?.frame ?? .zero)
        #expect(r.list.isHidden && r.body.queueListHeight == 0, "with none it takes no height")
        r.startTurn()
        r.enter("one"); r.enter("two")
        let list = r.list.frame
        #expect(!r.list.isHidden && list.height > 0 && list.minY == r.body.composer.frame.maxY, "directly above the composer")
        #expect(r.body.composer.frame.height == before.composer.height, "the composer's height is unchanged")
        let web = try #require(r.body.page?.view?.frame)
        #expect(web.minY == list.maxY && web.height == before.web.height - list.height, "the web view is as much shorter as the list is tall: \(web) \(list)")
        r.body.setStatus("a status line")
        #expect(r.list.frame.minY == r.body.composer.frame.maxY, "above the status line, which is the composer's top")
        #expect(r.list.boxFrame.minX == ChatQueueListView.padX && r.list.boxFrame.width == list.width - ChatQueueListView.padX * 2, "the box has 12 pt on each side (16 at the 0.75 text scale)")
    }

    @Test func ChatOrcaD12_twentyCardsInA340PointPanelStayInsideTheCapAndTheTranscriptKeeps64Points() throws {
        let r = try QueueRig()
        r.rig.host.rect = CGRect(x: 700, y: 100, width: 520, height: 340)
        try r.open()
        r.startTurn()
        for index in 0..<20 { r.enter("card number \(index)") }
        let area = r.body.transcriptAreaHeight
        let cap = ChatWebBody.queueListCap(area: area)
        #expect(r.body.queueListHeight <= cap && r.body.queueListHeight == min(r.list.contentHeight, cap) && r.list.contentHeight > cap, "\(r.body.queueListHeight) \(cap) \(r.list.contentHeight)")
        let web = try #require(r.body.page?.view?.frame)
        #expect(web.height >= 64 && r.list.frame.height == r.body.queueListHeight, "the transcript keeps 64 pt: \(web.height)")
        #expect(ChatWebBody.queueListCap(area: 100) == 36 && ChatWebBody.queueListCap(area: 400) == 200 && ChatWebBody.queueListCap(area: 50) == 0 && ChatWebBody.queueListCap(area: 0) == 0)
    }

    @Test func ChatOrcaD12_theRowsShowTheTextOnOneTruncatedLineWithItsTooltipTheCaptionTheButtonsAndOnlyTheNewestShowsTheChord() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        let long = String(repeating: "long ", count: 200)
        r.enter(long); r.enter("short")
        r.body.layoutSubtreeIfNeeded()
        let rows = r.list.rows
        #expect(rows.count == 2 && rows[0].shownText == long && rows[0].textFrame.height == 15, "one line (20 pt at the 0.75 text scale): \(rows[0].textFrame)")
        try #require(rows.count > 0, "rows needs 1 elements: \(rows.count)")
        #expect(rows[0].textToolTip == long, "the whole text is its tooltip")
        try #require(rows.count > 0, "rows needs 1 elements: \(rows.count)")
        #expect(rows[0].steerButton.title == "Steer" && rows[0].steerButton.toolTip == "Submit without interrupting the model")
        try #require(rows.count > 1, "rows needs 2 elements: \(rows.count)")
        #expect(rows[1].steerButton.toolTip == "Submit without interrupting the model \u{2318}\u{23CE}", "the newest card adds the chord: \(rows[1].steerButton.toolTip ?? "")")
        try #require(rows.count > 0, "rows needs 1 elements: \(rows.count)")
        #expect(rows[0].deleteButton.toolTip == "Delete" && rows[0].moreButton.toolTip == "More actions" && rows[0].captionText == nil)
        r.pressStop()
        #expect(r.list.pauseRow?.text == "Queue paused because you interrupted")
        #expect(r.list.pauseRow?.resumeButton.title == "Resume")
    }

    @Test func ChatOrcaD12_theEmptyComposerKeepsItsHeightWhateverTheListHolds() throws {
        let r = try QueueRig()
        try r.open()
        let empty = r.body.composer.preferredHeight()
        r.startTurn()
        r.enter("one"); r.enter("two")
        #expect(r.body.composer.preferredHeight() == empty, "the list takes its height from the transcript, not from the composer")
    }

    // MARK: Q12, restore

    @Test func ChatOrcaD12_aRestartFindsTheCardsUnderTheRestartedPauseAndResumeSendsAtOnce() throws {
        let first = try QueueRig()
        try first.open()
        first.startTurn()
        first.enter("kept one"); first.enter("kept two")
        let second = try QueueRig(state: first.state)
        try second.open()
        #expect(second.texts == ["kept one", "kept two"] && second.queue.pause == .restarted, "\(second.queue.pause)")
        #expect(second.list.pauseRow?.text == "Queue paused because Clawd restarted" && second.list.rows.count == 2)
        second.list.pauseRow?.resumeButton.performClick(nil)
        #expect(second.session.sent == ["kept one"] && second.texts == ["kept two"] && second.queue.pause == .none)
    }

    // MARK: Q13

    @Test func ChatOrcaD13_cmdEnterWithAnEmptyDraftAndTwoCardsSteersTheSecondAndWithTextItIsAnOrdinaryEnter() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("one"); r.enter("two")
        r.body.inputText = ""
        r.input.modifiers = { [.command] }
        r.input.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(r.session.sent == ["first", "two"] && r.session.requests.last?.steer == true && r.texts == ["one"], "the newest card is steered: \(r.session.sent)")
        r.body.inputText = "typed text"
        r.input.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(r.session.sent == ["first", "two"] && r.texts == ["one", "typed text"], "with text it is an ordinary Enter, which queues, and steers nothing: \(r.texts)")
        r.body.inputText = ""
        r.session.finish(.success(seconds: 1)); r.session.finish(.success(seconds: 1)); r.session.finish(.success(seconds: 1))
        r.input.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(r.session.sent.count == 4, "with no card it sends nothing: \(r.session.sent)")
    }

    @Test func ChatOrcaD13_cmdEnterIsAKeyEquivalentWithTheCommandFlagAndShiftCmdEnterIsNot() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("one")
        r.body.inputText = ""
        let down = r.web.keyEvent(code: 36, characters: "\r", modifiers: [.command])
        r.input.modifiers = { [.command] }
        #expect(r.input.performKeyEquivalent(with: down), "the chord is taken as a key equivalent")
        #expect(r.session.requests.last?.steer == true && r.session.sent == ["first", "one"], "\(r.session.sent)")
        r.enter("two")
        r.body.inputText = ""
        r.input.modifiers = { [.command, .shift] }
        r.input.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(r.texts == ["two"], "Shift keeps the line break and steers nothing")
    }

    @Test func ChatOrcaD13_steerWritesTheCardsTextIntoTheRunningTurnInTheSameWriteThatPutsItInFlightAndItsReplayClearsTheEntry() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("steer me")
        var atSend: ChatComposerFile?
        r.session.duringSend = { text in if text == "steer me" { atSend = try? r.savedFile() } }
        r.list.rows[0].steerButton.performClick(nil)
        let request = try #require(r.session.requests.last)
        #expect(request.steer && request.text == "steer me" && request.origin != .draft && r.texts.isEmpty && r.log.contains("CHAT queue steer"))
        let seen = try #require(atSend, "the file was read while the send was being taken")
        #expect(seen.inflight?.map(\.uuid) == [request.uuid] && seen.cards == nil, "the card is gone and the send is in flight before the frame leaves: \(seen)")
        #expect(r.session.transcript.entries.last?.sending == true)
        r.session.deliver(request)
        #expect((try r.savedFile()).inflight == nil, "a delivery removes the entry")
    }

    @Test func ChatOrcaD13_aDraftSendClearsTheDraftAndAddsItToInflightInOneWriteBeforeTheFrameGoesOut() throws {
        let r = try QueueRig()
        try r.open()
        var atSend: ChatComposerFile?
        r.session.duringSend = { _ in atSend = try? r.savedFile() }
        r.enter("plain send")
        let request = try #require(r.session.requests.last)
        let seen = try #require(atSend)
        #expect(seen.inflight?.map(\.uuid) == [request.uuid] && seen.draft == nil, "no moment exists with the text only in memory: \(seen)")
        r.session.deliver(request)
        #expect((try r.savedFile()).inflight == nil)
    }

    @Test func ChatOrcaD13_aRefusedSessionSendUndoesTheInflightEntryAndKeepsTheDraft() throws {
        let r = try QueueRig()
        try r.open()
        r.session.accept = false
        r.enter("refused")
        #expect(r.body.inputText == "refused" && r.body.statusText == "Not sent: Claude Code could not take the message")
        let file = try r.savedFile()
        #expect(file.inflight == nil && file.draft == "refused", "\(file)")
    }

    @Test func ChatOrcaD13_withNoTurnRunningSteerIsAPlainSendAndSendOnAHeldCardIsPlainToo() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("held one")
        r.pressStop()
        r.session.finish(.interrupted)
        try #require(r.list.rows.count > 0, "r.list.rows needs 1 elements: \(r.list.rows.count)")
        #expect(r.list.rows[0].steerButton.title == "Steer", "waiting under the queue's pause, a card still says Steer")
        r.list.rows[0].steerButton.performClick(nil)
        #expect(r.session.sent.last == "held one" && r.session.requests.last?.steer == false && r.session.requests.last?.person == true && r.queue.pause == .none,
                "with no turn running it is a plain send, and a person's turn starting lifted the pause")
        r.session.finish(.success(seconds: 1))
        r.session.failSend("held one")
        #expect(r.list.rows.first?.steerButton.title == "Send" && r.list.rows.first?.steerButton.toolTip == "Send this message now \u{2318}\u{23CE}", "a card held on its own says Send, and the newest adds the chord")
    }

    @Test func ChatOrcaD13_aSteerWhileTheTurnIsStoppingWaitsForTheTurnToBeNoneAndGoesFirst() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("one"); r.enter("two")
        r.session.turn = .stopping
        r.list.rows[1].steerButton.performClick(nil)
        #expect(r.session.sent == ["first"] && r.texts == ["one", "two"], "nothing is written while the turn stops")
        r.session.turn = .none
        r.session.onChange?()
        #expect(r.session.sent == ["first", "two"] && r.texts == ["one"], "the chosen card goes first, not the oldest: \(r.session.sent) \(r.log)")
    }

    @Test func ChatOrcaD13_theDrainHoldsWhileASendIsUnsettledAndGoesOnceItIsSettled() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("later")
        r.session.hasUnsettledSend = true
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent == ["first"] && r.texts == ["later"], "a steer still queued in the CLI holds the queue")
        r.session.hasUnsettledSend = false
        r.session.onChange?()
        #expect(r.session.sent == ["first", "later"])
    }

    @Test func ChatOrcaD13_aVerdictOfNotDeliveredMakesAReturnedCardForACardOrASteerAndPutsAnOrdinarySendBackInTheDraft() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("steered")
        r.list.rows[0].steerButton.performClick(nil)
        let steer = try #require(r.session.requests.last)
        r.session.settle(steer) { .notDelivered($0, .cancelled) }
        try #require(r.queue.cards.count > 0, "r.queue.cards needs 1 elements: \(r.queue.cards.count)")
        try #require(r.list.rows.count > 0, "r.list.rows needs 1 elements: \(r.list.rows.count)")
        #expect(r.texts == ["steered"] && r.queue.cards[0].state == "returned" && r.list.rows[0].captionText == "Stopped before it was sent", "\(r.queue.cards)")
        try #require(r.list.rows.count > 0, "r.list.rows needs 1 elements: \(r.list.rows.count)")
        #expect(r.list.rows[0].steerButton.title == "Send")
        #expect(r.session.sent == ["first", "steered"], "nothing is resent")
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent.count == 2, "a returned card is never drained")
        r.enter("ordinary")
        let plain = try #require(r.session.requests.last)
        r.session.settle(plain) { .notDelivered($0, .refused) }
        #expect(r.body.inputText == "ordinary", "an ordinary send is put back into the draft")
    }

    @Test func ChatOrcaD13_aDoubtVerdictMakesAHeldCardSavedToTheFileThatSurvivesARestartAndIsNeverSentByItself() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("maybe")
        r.list.rows[0].steerButton.performClick(nil)
        let steer = try #require(r.session.requests.last)
        r.session.settle(steer) { .doubt($0, .childEnded) }
        try #require(r.list.rows.count > 0, "r.list.rows needs 1 elements: \(r.list.rows.count)")
        #expect(r.queue.doubtCards.map(\.id) == [steer.uuid] && r.list.rows[0].captionText?.hasPrefix("Clawd couldn't confirm your message reached Claude Code") == true)
        let file = try r.savedFile()
        #expect(file.doubt?.map(\.uuid) == [steer.uuid] && file.inflight == nil, "\(file)")
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent == ["first", "maybe"], "a doubt card is never sent by itself")
        let again = try QueueRig(state: r.state)
        try again.open()
        #expect(again.queue.doubtCards.map(\.id) == [steer.uuid] && again.texts == ["maybe"] && again.queue.pause == .none, "the doubt card is held, not paused: \(again.queue.pause)")
        again.rig.session.finish(.success(seconds: 1))
        #expect(again.session.sent.isEmpty)
    }

    @Test func ChatOrcaD13_aSendInFlightWhenTheControllerIsDroppedComesBackAsADoubtCardWithItsUuid() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("drained")
        r.session.finish(.success(seconds: 1))
        let request = try #require(r.session.requests.last)
        try #expect(request.text == "drained" && (try r.savedFile()).inflight?.map(\.uuid) == [request.uuid])
        let again = try QueueRig(state: r.state)
        try again.open()
        #expect(again.queue.doubtCards.map(\.id) == [request.uuid] && again.texts == ["drained"], "a drained card unconfirmed at quit is a doubt card after restart")
        try #expect((try again.savedFile()).inflight == nil && (try again.savedFile()).doubt?.map(\.uuid) == [request.uuid], "converted and written at once")
    }

    @Test func ChatOrcaD13_aDoubtCardLateReplayedIsRemovedAndSendOnItSendsAgainWithAFreshUuid() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("maybe")
        r.list.rows[0].steerButton.performClick(nil)
        let steer = try #require(r.session.requests.last)
        r.session.settle(steer) { .doubt($0, .startedAtIdle) }
        r.session.settle(steer) { .delivered($0, late: true) }
        #expect(r.texts.isEmpty && r.list.rows.isEmpty, "a following Send is impossible: the card is gone")
        r.session.settle(steer) { .doubt($0, .childEnded) }
        r.session.finish(.success(seconds: 1))
        r.list.rows[0].steerButton.performClick(nil)
        let resent = try #require(r.session.requests.last)
        #expect(resent.uuid != steer.uuid && r.session.sent.last == "maybe" && r.texts.isEmpty && resent.steer == false)
    }

    @Test func ChatOrcaD13_slashClearIsRefusedWhileADoubtCardExistsAndAcceptedOnceTomDeletesIt() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("maybe")
        r.list.rows[0].steerButton.performClick(nil)
        let steer = try #require(r.session.requests.last)
        r.session.settle(steer) { .doubt($0, .childEnded) }
        r.session.finish(.success(seconds: 1))
        r.enter("/clear")
        #expect(r.session.sent == ["first", "maybe"] && r.body.statusText == "Resolve pending or unconfirmed messages before using this command." && r.body.inputText == "/clear")
        r.list.rows[0].deleteButton.performClick(nil)
        r.web.pressEnter()
        #expect(r.session.sent.last == "/clear", "\(r.session.sent)")
    }

    @Test func ChatOrcaD13_theResetFramePausesTheQueueWithClearedAndTheCardsStay() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("carried")
        r.session.onConversationCleared?()
        #expect(r.queue.pause == .cleared && r.texts == ["carried"] && r.list.pauseRow?.text == "Queue paused after you cleared the conversation")
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent == ["first"], "paused after the clear")
    }

    // MARK: D18, the gate

    @Test func ChatOrcaD18_theDrainWithTheChatPageNotInstalledOrChatOffLeavesTheCardAndPausesWithOther() throws {
        var installed = true
        let r = try QueueRig(isInstalled: { installed })
        try r.open()
        r.startTurn()
        r.enter("later")
        installed = false
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent == ["first"] && r.texts == ["later"] && r.queue.pause == .other, "a missing page means the files are not installed: \(r.queue.pause)")
    }

    @Test func ChatOrcaD18_aManualSteerWithTheExamBrowserRunningKeepsTheCardAndShowsTheWords() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("steer me")
        r.rig.host.examRunning = true
        r.list.rows[0].steerButton.performClick(nil)
        #expect(r.texts == ["steer me"] && r.session.sent == ["first"] && r.body.statusText == "Not sent: an exam browser is running")
        #expect((try r.savedFile()).inflight == nil, "nothing was put in flight")
    }

    @Test func ChatOrcaD18_theQueueRunsWhileThePanelIsClosed() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("while closed")
        r.controller.close(.button)
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent == ["first", "while closed"] && r.texts.isEmpty, "the drain runs with the panel closed, as Orca's host queue does: \(r.session.sent)")
    }

    @Test func ChatOrcaD18_theStreamKindKeepsEnterIgnoredWhileATurnRuns() throws {
        let rig = ControllerRig()
        rig.open()
        rig.type("first")
        rig.pressEnter()
        rig.type("second")
        rig.pressEnter()
        #expect(rig.session.sent == ["first"] && rig.controller.queue.cards.isEmpty, "no queue on the stream kind")
    }

    // MARK: the Send/Stop control

    @Test func ChatOrcaD12_aDoubleClickOnSendSendsOnceAndDoesNotStop() throws {
        let r = try QueueRig()
        try r.open()
        r.body.inputText = "once"
        r.body.composer.clickCount = { 1 }
        r.body.composer.sendButton.performClick(nil)
        #expect(r.session.sent == ["once"] && r.session.turn == .running)
        r.body.composer.clickCount = { 2 }
        r.body.composer.sendButton.performClick(nil)
        #expect(r.session.interrupts == 0 && r.session.sent == ["once"], "the second click of a double-click does nothing")
        r.body.composer.clickCount = { 1 }
        r.body.composer.sendButton.performClick(nil)
        #expect(r.session.interrupts == 1, "a later single click stops")
    }

    @Test func ChatOrcaD12_logsCarryCountsOnly() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn("SECRET-FIRST")
        r.enter("SECRET-CARD")
        r.list.rows[0].steerButton.performClick(nil)
        r.enter("SECRET-OTHER")
        r.list.rows[0].deleteButton.performClick(nil)
        #expect(r.log.contains { $0.hasPrefix("CHAT queue ") } && r.log.allSatisfy { !$0.contains("SECRET") }, "\(r.log)")
    }

    @Test func ChatOrcaD12_aHistoryEntryIsPushedWhenACardIsQueuedAndNotAgainWhenItIsSent() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn("a")
        r.enter("b")
        r.session.finish(.success(seconds: 1))
        #expect(r.controller.history.entries == ["a", "b"])
    }
}

// Sprint 4 fixes (review r1): a second click or a repeat is not a second request, a keyboard press never reads a click count, and a session's own
// idle stop pauses the queue.
@Suite("Chat orca parity D, Sprint 4 review fixes", .serialized)
@MainActor
struct ChatOrcaParityDSendFixSuite {
    private func keyDown(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags, repeating: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: code)!
    }

    // MARK: H1, M2

    @Test func ChatOrcaD12_H1_aDoubleClickOnTheNewestCardsSteerSteersThatCardOnlyAndNotTheCardThatMovedUpUnderThePointer() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("older"); r.enter("newer")
        r.list.clickCount = { 1 }
        r.list.rows[1].steerButton.performClick(nil)
        #expect(r.session.sent == ["first", "newer"] && r.texts == ["older"], "the first click steers the newer card: \(r.session.sent)")
        r.list.clickCount = { 2 }
        r.list.rows[0].steerButton.performClick(nil)
        #expect(r.session.sent == ["first", "newer"] && r.texts == ["older"], "the second click of the double-click acts on nothing: \(r.session.sent) \(r.texts)")
        r.list.clickCount = { 1 }
        r.list.rows[0].steerButton.performClick(nil)
        #expect(r.session.sent == ["first", "newer", "older"], "a later single click steers it")
    }

    @Test func ChatOrcaD12_H1_aDoubleClickOnTheNewestCardsDeleteDeletesThatCardOnly() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("older"); r.enter("newer")
        r.list.clickCount = { 1 }
        r.list.rows[1].deleteButton.performClick(nil)
        #expect(r.texts == ["older"])
        r.list.clickCount = { 2 }
        r.list.rows[0].deleteButton.performClick(nil)
        #expect(r.texts == ["older"], "the second click deletes nothing: \(r.texts)")
        r.list.clickCount = { 1 }
        r.list.rows[0].deleteButton.performClick(nil)
        #expect(r.texts.isEmpty)
    }

    @Test func ChatOrcaD12_H1_aDoubleClickOnResumeResumesOnceAndDoesNotPressTheCardThatMovedUpIntoItsPlace() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("one"); r.enter("two")
        r.pressStop()
        r.session.finish(.interrupted)
        r.session.turn = .running
        r.list.clickCount = { 2 }
        r.list.pauseRow?.resumeButton.performClick(nil)
        #expect(r.queue.pause == .stopped, "the second click of a double-click is not a Resume")
        r.list.clickCount = { 1 }
        r.list.pauseRow?.resumeButton.performClick(nil)
        #expect(r.queue.pause == .none)
    }

    @Test func ChatOrcaD12_M2_aPressThatIsNotAMouseClickCountsAsOneAndNeverReadsAClickCount() {
        #expect(ChatClickCount.current(of: keyDown(code: 49, characters: " ", modifiers: [])) == 1, "Space on the focused button, VoiceOver and Voice Control")
        #expect(ChatClickCount.current(of: nil) == 1)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 3, pressure: 1)
        #expect(ChatClickCount.current(of: down) == 2 && ChatClickCount.current(of: up) == 3, "a mouse press keeps its count")
    }

    // MARK: M1, L6

    @Test func ChatOrcaD13_M1_aRepeatOfAHeldCmdEnterSteersNothingAndTheFirstPressSteersOnce() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("one"); r.enter("two"); r.enter("three")
        r.body.inputText = ""
        r.input.modifiers = { [.command] }
        let held = keyDown(code: 36, characters: "\r", modifiers: [.command], repeating: true)
        #expect(r.input.performKeyEquivalent(with: held), "a repeat is taken")
        #expect(r.session.sent == ["first"] && r.texts == ["one", "two", "three"], "and steers nothing: \(r.session.sent)")
        #expect(r.input.performKeyEquivalent(with: keyDown(code: 36, characters: "\r", modifiers: [.command])))
        #expect(r.session.sent == ["first", "three"] && r.texts == ["one", "two"])
        #expect(r.input.performKeyEquivalent(with: held))
        #expect(r.session.sent == ["first", "three"], "the held key goes on steering nothing")
    }

    @Test func ChatOrcaD13_L6_theKeypadEnterWithCommandSteersToo() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("one")
        r.body.inputText = ""
        r.input.modifiers = { [.command] }
        #expect(r.input.performKeyEquivalent(with: keyDown(code: 76, characters: "\u{3}", modifiers: [.command, .numericPad])))
        #expect(r.session.sent == ["first", "one"] && r.session.requests.last?.steer == true, "\(r.session.sent)")
    }

    // MARK: M3

    @Test func ChatOrcaD18_M3_theSessionsOwnIdleStopPausesTheQueueWithOtherSoNothingDrainsByItselfAfterIt() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("later")
        r.session.hasUnsettledSend = true
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent == ["first"] && r.texts == ["later"], "held while a steer is unsettled")
        let steer = ChatSendRequest(text: "steer", origin: .draft, steer: true)
        r.session.onChildLost?(.idle)
        #expect(r.queue.pause == .other && r.log.contains("CHAT queue child-lost reason=idle"), "\(r.queue.pause) \(r.log)")
        r.session.settle(steer) { .doubt($0, .childEnded) }
        r.session.hasUnsettledSend = false
        r.session.onChange?()
        #expect(r.session.sent == ["first"] && r.texts == ["steer", "later"], "the stop made a doubt card and its turn change sends nothing: \(r.session.sent) \(r.texts)")
    }

    @Test func ChatOrcaD13_M3_aSteerLeftQueuedAtAnIdleDoesNotTrapANewSendAndTheQueueDrainsOnceTheNextIdleMadeItADoubtCard() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("A"); r.enter("B")
        r.list.rows[1].steerButton.performClick(nil)
        let steer = try #require(r.session.requests.last)
        #expect(steer.text == "B" && steer.steer)
        r.session.hasUnsettledSend = true
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent == ["first", "B"] && r.texts == ["A"], "the drain waits for the steer's second idle: \(r.session.sent)")
        r.enter("typed")
        #expect(r.session.sent == ["first", "B", "typed"] && r.texts == ["A"] && r.session.turn == .running, "Enter at an idle starts a turn instead of queuing behind the held card: \(r.texts)")
        r.session.settle(steer) { .doubt($0, .unconfirmedAtSecondIdle) }
        r.session.hasUnsettledSend = false
        #expect(r.queue.doubtCards.map(\.text) == ["B"], "the stale steer is a doubt card")
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent == ["first", "B", "typed", "A"] && r.texts == ["B"], "and the queue drains after it: \(r.session.sent)")
    }

    // MARK: M4

    @Test func ChatOrcaD12_M4_sendingADoubtCardAgainCarriesItsChipsIntoTheNewSendInFlight() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        let chips = [ChatComposerChip(path: try r.picture("a.png"))]
        let lost = ChatSendRequest(text: "had a picture", origin: .draft, steer: true, chips: chips)
        r.session.settle(lost) { .doubt($0, .childEnded) }
        #expect(r.queue.doubtCards.first?.chips == chips)
        r.list.rows[0].steerButton.performClick(nil)
        let again = try #require(r.session.requests.last)
        #expect(again.text == "had a picture" && again.chips == chips, "the new send has the chips: \(again.chips)")
        #expect((try r.savedFile()).inflight?.first?.chips == chips, "and so has its entry in flight")
    }

    // MARK: L1

    @Test func ChatOrcaD12_L1_sendNowOnOneCardAfterAStopLiftsThePauseForTheRestAndTheyDrainOnePerTurnEnd() throws {
        let r = try QueueRig()
        try r.open()
        r.startTurn()
        r.enter("one"); r.enter("two"); r.enter("three")
        r.pressStop()
        r.session.finish(.interrupted)
        r.list.rows[0].steerButton.performClick(nil)
        #expect(r.session.sent == ["first", "one"] && r.queue.pause == .none && r.texts == ["two", "three"], "Orca queued-stop.ts:5-6: with no turn running the send starts that turn at once")
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent == ["first", "one", "two"] && r.texts == ["three"], "the rest go one per turn end")
    }
}
