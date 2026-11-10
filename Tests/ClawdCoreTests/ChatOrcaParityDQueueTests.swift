import Testing
import Foundation
@testable import ClawdCore

// Orca parity round D, sprint 4, the rules without a process or a window: the parser's new frames (Q13), the send ledger, the transcript's pending
// entries, the queue's cards, holds, budget and pause (Q12), and the setting that turns the queue off (D13).

private func request(_ text: String = "steer", origin: ChatSendOrigin = .draft, steer: Bool = true, uuid: String) -> ChatSendRequest {
    ChatSendRequest(text: text, origin: origin, steer: steer, uuid: uuid)
}

private func entry(_ uuid: String, text: String = "steer", origin: ChatSendOrigin = .draft, steer: Bool = true, written: Bool = true) -> ChatLedgerEntry {
    var made = ChatLedgerEntry(request: request(text, origin: origin, steer: steer, uuid: uuid), child: 1)
    made.written = written
    return made
}

private func ledger(_ entries: ChatLedgerEntry...) -> ChatSendLedger {
    var made = ChatSendLedger()
    for item in entries { made.add(item) }
    return made
}

@Suite("Chat orca parity D, queue and ledger rules")
struct ChatOrcaParityDQueueSuite {
    // MARK: Q13, the parser

    @Test func ChatOrcaD13_theParserReadsAReplayBySessionStateByLifecycleAndTheResultsUuidsAndNothingElseFromThem() {
        let replay = #"{"type":"user","isReplay":true,"uuid":"u-1","message":{"role":"user","content":"<command-name>/context</command-name> a very long report"},"session_id":"s"}"#
        #expect(ChatStreamParser.parse(line: replay) == [.replay(uuid: "u-1")], "the content is never read")
        let notReplay = #"{"type":"user","uuid":"u-1","message":{"role":"user","content":"hello"}}"#
        #expect(ChatStreamParser.parse(line: notReplay) == [.ignored(type: "user")])
        #expect(ChatStreamParser.parse(line: #"{"type":"user","isReplay":false,"uuid":"u-1","message":{"role":"user","content":"hello"}}"#) == [.ignored(type: "user")])
        #expect(ChatStreamParser.parse(line: #"{"type":"user","isReplay":true,"message":{"role":"user","content":"x"}}"#) == [.ignored(type: "user/replay")], "a replay with no uuid")
        #expect(ChatStreamParser.parse(line: #"{"type":"user","isReplay":true,"uuid":"u","parent_tool_use_id":"t","message":{"content":"x"}}"#) == [.ignored(type: "user/subagent")])
        for state in ["running", "idle", "requires_action"] {
            #expect(ChatStreamParser.parse(line: #"{"type":"system","subtype":"session_state_changed","state":"\#(state)","session_id":"s"}"#) == [.sessionState(state)])
        }
        #expect(ChatStreamParser.parse(line: #"{"type":"system","subtype":"session_state_changed","state":"sleeping"}"#) == [.ignored(type: "system/session_state_changed")])
        #expect(ChatStreamParser.parse(line: #"{"type":"command_lifecycle","command_uuid":"c-1","state":"queued","session_id":"s"}"#) == [.commandLifecycle(uuid: "c-1", state: "queued")])
        #expect(ChatStreamParser.parse(line: #"{"type":"command_lifecycle","state":"queued"}"#) == [.ignored(type: "command_lifecycle")])
        func result(_ field: String) -> [ChatEvent] {
            ChatStreamParser.parse(line: #"{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"total_cost_usd":0,"session_id":"s","result":""\#(field)}"#)
        }
        func names(_ events: [ChatEvent]) -> [String]? {
            if case .result(_, _, _, _, _, let names)? = events.first { return names }
            return nil
        }
        #expect(names(result(#","user_message_uuids":["a","b"]"#)) == ["a", "b"])
        #expect(names(result("")) == nil && names(result(#","user_message_uuids":[1,"b"]"#)) == nil && names(result(#","user_message_uuids":"a""#)) == nil,
                "anything but an array of strings reads as absent")
    }

    @Test func ChatOrcaD13_theNewFramesAreNeverDroppedAndTheyChangeNothingInTheTranscript() {
        for event in [ChatEvent.replay(uuid: "u"), .sessionState("idle"), .commandLifecycle(uuid: "u", state: "started")] {
            #expect(!ChatHandoff.isDroppable(event), "\(event)")
        }
        var transcript = ChatTranscript()
        transcript.appendUser("hi", uuid: "u")
        let before = transcript.entries
        for event in [ChatEvent.replay(uuid: "u"), .sessionState("running"), .sessionState("idle"), .commandLifecycle(uuid: "u", state: "started")] { transcript.apply(event) }
        #expect(transcript.entries == before && transcript.ignoredCounts.isEmpty)
    }

    // MARK: Q13, the ledger

    @Test func ChatOrcaD13_aReplayDeliversASendAndAResultThatNamesItDoesTooAndASlashSendIsDeliveredByItsFirstResult() {
        var made = ledger(entry("a"), entry("b"), entry("/compact", text: "/compact", steer: false))
        #expect(made.replay("a") == [.delivered(entry("a"), late: false)] && made.pending.count == 2)
        #expect(made.replay("a").isEmpty, "a second replay changes nothing")
        #expect(made.result(named: ["b"]).map(\.entry.uuid) == ["b"] && made.pending.map(\.uuid) == ["/compact"])
        #expect(made.result(named: nil).map(\.entry.uuid) == ["/compact"], "a result with no names delivers the / send (Orca :141)")
        var plain = ledger(entry("a", steer: false))
        #expect(plain.result(named: nil).isEmpty, "a plain send with no names is not delivered by a result alone")
    }

    @Test func ChatOrcaD13_aTerminalLifecycleBeforeStartedIsNotDeliveredWithItsKindAndAfterStartedItIsDoubt() {
        for kind in ["cancelled", "discarded", "refused"] {
            var made = ledger(entry("a"))
            _ = made.lifecycle("a", "queued")
            let verdicts = made.lifecycle("a", kind)
            #expect(verdicts == [.notDelivered(entry("a").with(.queued), ChatNotDelivered(rawValue: kind)!)] && !made.hasPending, "\(kind)")
        }
        var started = ledger(entry("a"))
        _ = started.lifecycle("a", "started")
        let verdicts = started.lifecycle("a", "cancelled")
        #expect(verdicts == [.doubt(entry("a").with(.started), .endedAfterStart)] && started.doubt["a"] != nil, "after started the send may be in the conversation")
        #expect(started.replay("a").map { if case .delivered(_, let late) = $0 { return late } else { return false } } == [true], "and a replay that follows delivers it")
    }

    @Test func ChatOrcaD13_aLifecycleMovesOnlyForwardAndAnUnknownUuidIsIgnored() {
        var made = ledger(entry("a"))
        _ = made.lifecycle("a", "started")
        _ = made.lifecycle("a", "queued")
        #expect(made.entry("a")?.lifecycle == .started, "a redelivered command re-emits queued but has still started")
        #expect(made.lifecycle("zzz", "cancelled").isEmpty && made.lifecycle("a", "completed").isEmpty && made.hasPending)
    }

    @Test func ChatOrcaD13_idleMakesAStartedSendDoubtAndAQueuedOneWaitsForTheSecondIdle() {
        var made = ledger(entry("started"), entry("queued"), entry("silent"))
        _ = made.lifecycle("started", "started")
        _ = made.lifecycle("queued", "queued")
        let first = made.idle()
        #expect(first.map(\.entry.uuid) == ["started"] && first.allSatisfy { if case .doubt(_, .startedAtIdle) = $0 { return true } else { return false } })
        #expect(made.pending.map(\.uuid) == ["queued", "silent"], "a queued send may still start")
        let second = made.idle()
        #expect(second.map(\.entry.uuid) == ["queued", "silent"] && second.allSatisfy { if case .doubt(_, .unconfirmedAtSecondIdle) = $0 { return true } else { return false } })
        #expect(!made.hasPending && made.doubt.count == 3)
    }

    @Test func ChatOrcaD13_aSendNotWrittenYetIsNotCountedByIdleAndIsGivenBackWhenItsWriteFails() {
        var made = ledger(entry("a", written: false))
        #expect(made.idle().isEmpty && made.idle().isEmpty && made.hasPending)
        #expect(made.unwritten("a") == .unwritten(entry("a", written: false)) && !made.hasPending && made.unwritten("a") == nil)
    }

    @Test func ChatOrcaD13_theChildEndingMakesEveryWrittenUnconfirmedSendDoubtAndLeavesAnUnwrittenOneToItsWrite() {
        var made = ledger(entry("a"), entry("b", written: false))
        let verdicts = made.childEnded()
        #expect(verdicts == [.doubt(entry("a"), .childEnded)] && made.pending.map(\.uuid) == ["b"] && made.hasOutstanding)
        made.clearDoubt()
        #expect(made.doubt.isEmpty, "a new child cannot replay the old one's frames")
        var quitting = ledger(entry("a"), entry("b", written: false))
        #expect(quitting.childEnded(unreported: true) == [.doubt(entry("a"), .childEnded), .doubt(entry("b", written: false), .childEnded)] && quitting.pending.isEmpty,
                "at quit nothing will report a write, so an unwritten line may still have reached the child")
    }

    @Test func ChatOrcaD13_aReplayOrAResultThatNamesADoubtSendDeliversItLateAndAnUnknownUuidChangesNothing() {
        var made = ledger(entry("a"), entry("b"))
        _ = made.childEnded()
        #expect(made.replay("zzz").isEmpty && made.result(named: ["zzz"]).isEmpty && made.doubt.count == 2)
        #expect(made.replay("a") == [.delivered(entry("a"), late: true)] && made.doubt.keys.sorted() == ["b"])
        #expect(made.result(named: ["b"]) == [.delivered(entry("b"), late: true)] && made.doubt.isEmpty)
        var forgotten = ledger(entry("c"))
        _ = forgotten.childEnded()
        forgotten.forgetDoubt("c")
        #expect(forgotten.replay("c").isEmpty, "a doubt send Tom dealt with no longer matters")
    }

    // MARK: Q13, the transcript

    @Test func ChatOrcaD13_aPendingUserEntryEndsNothingAndItsReplayMovesItAfterWhatTheStreamProducedAndAnOrdinaryEntryNeverMoves() throws {
        var t = ChatTranscript()
        t.appendUser("first", uuid: "u1")
        t.apply(.toolStarted(id: "t1", name: "Bash"))
        t.appendPendingUser(uuid: "u2", text: "steer")
        try #require(t.entries.count > 2, "t.entries needs 3 elements: \(t.entries.count)")
        #expect(t.entries.map(\.kind) == [.user, .tool, .user] && t.entries[2].sending, "the pending entry is added and shows Sending")
        try #require(t.entries.count > 1, "t.entries needs 2 elements: \(t.entries.count)")
        #expect(t.entries[1].status == .running, "running tools keep their status")
        t.apply(.toolResult(id: "t1", isError: false))
        try #require(t.entries.count > 1, "t.entries needs 2 elements: \(t.entries.count)")
        #expect(t.entries[1].status == .done, "the tool's bookkeeping stayed, so its result still finds its line")
        t.apply(.toolStarted(id: "t2", name: "Bash"))
        t.placeUser(uuid: "u2")
        try #require(t.entries.count > 3, "t.entries needs 4 elements: \(t.entries.count)")
        #expect(t.entries.map(\.kind) == [.user, .tool, .tool, .user] && !t.entries[3].sending && t.entries[3].text == "steer", "after everything produced before the replay")
        t.placeUser(uuid: "u1")
        try #require(t.entries.count > 0, "t.entries needs 1 elements: \(t.entries.count)")
        #expect(t.entries.map(\.text).first == "first" && !t.entries[0].sending, "an ordinary entry only settles, a local command's replay comes after its own output")
    }

    @Test func ChatOrcaD13_L2_aSteersSendingDoesNotTakeTheRunningTurnsAndItsOwnClearsOnlyWhenTheLedgerSettlesIt() throws {
        var t = ChatTranscript()
        t.appendUser("first", uuid: "u1")
        t.appendPendingUser(uuid: "u2", text: "steer")
        t.apply(.textDelta(messageKey: "m", blockIndex: 0, text: "answer"))
        try #require(t.entries.count > 0, "t.entries needs 1 elements: \(t.entries.count)")
        #expect(!t.entries[0].sending, "the turn's first output clears the first send's Sending")
        try #require(t.entries.count > 1, "t.entries needs 2 elements: \(t.entries.count)")
        #expect(t.entries[1].sending, "the steer still shows Sending: the CLI only queued it")
        t.removeUser(uuid: "u2")
        #expect(t.entries.map(\.text).first == "first" && !t.entries.contains { $0.text == "steer" })
        var kept = ChatTranscript()
        kept.appendUser("first", uuid: "u1")
        kept.appendPendingUser(uuid: "u2", text: "steer")
        try #require(kept.entries.count > 0, "kept.entries needs 1 elements: \(kept.entries.count)")
        #expect(kept.entries[0].sending, "the first send's Sending is not orphaned by the steer")
    }

    @Test func ChatOrcaD13_aSendNotDeliveredLosesItsEntryAndADoubtOneKeepsItWithNotConfirmedUntilAReplayNamesIt() throws {
        var t = ChatTranscript()
        t.appendUser("first", uuid: "u1")
        t.appendPendingUser(uuid: "u2", text: "gone")
        t.appendPendingUser(uuid: "u3", text: "doubtful")
        t.removeUser(uuid: "u2")
        #expect(t.entries.map(\.text) == ["first", "doubtful"])
        t.markUnconfirmed(uuid: "u3")
        try #require(t.entries.count > 1, "t.entries needs 2 elements: \(t.entries.count)")
        #expect(t.entries[1].unconfirmed && !t.entries[1].sending)
        try #require(t.entries.count > 1, "t.entries needs 2 elements: \(t.entries.count)")
        #expect(ChatWebPayload.entry(t.entries[1])["unconfirmed"] as? Bool == true && ChatWebPayload.entry(t.entries[0])["unconfirmed"] == nil)
        t.confirmUser(uuid: "u3")
        try #require(t.entries.count > 1, "t.entries needs 2 elements: \(t.entries.count)")
        #expect(!t.entries[1].unconfirmed, "the entry shows its time again")
    }

    // MARK: Q12, the queue

    @Test func ChatOrcaD12_theBudgetIsTwentyCardsAndOneMiBOfTheBlocksJsonAndANewCardOverEitherChangesNothing() {
        var q = ChatQueue()
        for index in 0..<20 { #expect(q.add("m\(index)") != nil) }
        #expect(q.add("one more") == nil && q.cards.count == 20, "the 21st card is refused")
        var big = ChatQueue()
        let half = String(repeating: "x", count: 510_000)
        #expect(big.add(half) != nil && big.add(half) != nil, "two halves fit")
        #expect(big.add(String(repeating: "z", count: 30_000)) == nil && big.cards.count == 2, "over 1 MiB in all is refused with nothing changed")
        #expect(big.add("y") != nil, "a small one still fits: the bytes decide, not the count")
        #expect(ChatQueue.fullWords == "The message queue is full. Send again after the current turn ends.")
        var doubts = ChatQueue()
        doubts.doubt(entry("d1", text: "held"))
        for index in 0..<20 { #expect(doubts.add("m\(index)") != nil, "a doubt card is not queued work") }
    }

    @Test func ChatOrcaD12_theBlocksBytesAreTheUtf8LengthOfJsonStringifyOfTheTextBlock() throws {
        for text in ["plain", "quote \" and \\ slash / ok", "line\nbreak\ttab\rcr", "control \u{01}\u{1F}", "日本語 \u{1F600}", "", "a/b"] {
            let data = try JSONSerialization.data(withJSONObject: [["type": "text", "text": text]], options: [.withoutEscapingSlashes])
            #expect(ChatQueue.blocksBytes(text) == data.count, "\(text.debugDescription): \(ChatQueue.blocksBytes(text)) vs \(data.count)")
        }
    }

    @Test func ChatOrcaD12_theDrainPicksTheOldestWaitingCardUnlessAReturnedCardOrThePauseComesFirstAndPassesOverACardHeldOnItsOwn() {
        var q = ChatQueue()
        let a = q.add("a")!, b = q.add("b")!, c = q.add("c")!
        #expect(q.nextSendable?.id == a && q.hasActionableCard)
        q.setPause(.stopped)
        #expect(q.nextSendable == nil && !q.hasActionableCard, "a paused queue sends nothing")
        q.liftPause()
        q.begin(ChatSendRequest(text: "a", origin: .card(a), person: false))
        q.unwritten(entry("x", origin: .card(a)).with(uuid: q.inflight[0].uuid))
        #expect(q.card(a)?.paused == "send-failed" && q.nextSendable?.id == b, "a card held on its own is passed over")
        q.begin(ChatSendRequest(text: "b", origin: .card(b), person: false))
        let returned = q.inflight[0]
        _ = q.notDelivered(entry(returned.uuid, text: "b", origin: .card(b), steer: false), .cancelled)
        #expect(q.card(b)?.state == "returned" && q.nextSendable == nil, "a returned card ahead stops the drain: the queue never reorders")
        #expect(q.cards.map(\.id) == [a, b, c], "a card gets back its place")
    }

    @Test func ChatOrcaD12_holdsFollowOrcasNamesAndOnlyAPausedQueueOverAWaitingCardShowsTheResumeRow() throws {
        var q = ChatQueue()
        _ = q.add("w1")
        try #require(q.rows.count > 0, "q.rows needs 1 elements: \(q.rows.count)")
        #expect(q.rows.map(\.hold) == [.turn] && q.pauseRowText == nil && q.rows[0].caption == nil)
        q.setPause(.cleared)
        try #require(q.rows.count > 0, "q.rows needs 1 elements: \(q.rows.count)")
        #expect(q.rows[0].hold == .queuePaused && q.pauseRowText == "Queue paused after you cleared the conversation")
        for (pause, words) in [(ChatQueuePause.stopped, "Queue paused because you interrupted"), (.restarted, "Queue paused because Clawd restarted"), (.other, "Queue paused")] {
            q.setPause(pause)
            #expect(q.pauseRowText == words)
        }
        q.liftPause()
        q.doubt(entry("d", text: "doubted"))
        _ = q.add("w2")
        var held = q.rows
        #expect(held[0].hold == .paused("doubt") && held[0].caption == "Clawd couldn't confirm your message reached Claude Code. Check the chat, then send it again if needed.")
        #expect(held[0].alerts && held[0].sendsPlainly && !held[1].sendsPlainly)
        let card = q.cards[1]
        q.begin(ChatSendRequest(text: "w1", origin: .card(card.id), person: false))
        _ = q.notDelivered(entry(q.inflight[0].uuid, text: "w1", origin: .card(card.id), steer: false), .discarded)
        held = q.rows
        #expect(held.map(\.hold) == [.paused("doubt"), .returned, .behindReturned], "\(held.map(\.hold))")
        #expect(held[1].caption == "This message was not delivered." && held[2].caption == "Waiting \u{2014} a message ahead needs attention")
        q.setPause(.stopped)
        #expect(q.pauseRowText == nil, "a pause over cards Resume would not send offers nothing to press")
        let failed = ChatQueueRow(card: .init(id: "x", text: "t", state: "waiting", hold: "paused", paused: "send-failed"), hold: .paused("send-failed"))
        #expect(failed.caption == "Couldn't send \u{2014} press Send to retry." && failed.alerts)
        let kept = ChatQueueRow(card: .init(id: "x", text: "t", state: "waiting", hold: "paused", paused: "kept"), hold: .paused("kept"))
        #expect(kept.caption == "Not sent yet \u{2014} press Send to send it." && !kept.alerts)
    }

    @Test func ChatOrcaD12_editOnXWithTheDraftYGivesYBlankLineXAndTheDraftAlreadyEndingInItIsLeftAlone() {
        #expect(ChatQueue.appendReturned(draft: "y", text: "x") == "y\n\nx")
        #expect(ChatQueue.appendReturned(draft: "y\n\nx", text: "x") == "y\n\nx" && ChatQueue.appendReturned(draft: "x", text: "x") == "x")
        #expect(ChatQueue.appendReturned(draft: "", text: "x") == "x" && ChatQueue.appendReturned(draft: "  \n", text: "x") == "x", "a whitespace-only draft counts as empty")
        #expect(ChatQueue.appendReturned(draft: "y  \n", text: "x") == "y\n\nx" && ChatQueue.appendReturned(draft: "y", text: " \n") == "y")
    }

    @Test func ChatOrcaD12_aStartFindsCardsUnderTheRestartedPauseAndEverySendInFlightAndEveryDoubtAsAHeldDoubtCardWithItsUuid() {
        var file = ChatComposerFile()
        file.cards = [.init(id: "c1", text: "one", state: "waiting", hold: "turn"), .init(id: "c2", text: "two", state: "returned", hold: "returned", paused: "cancelled")]
        file.inflight = [.init(uuid: "f1", text: "written before the crash", origin: "draft")]
        file.doubt = [.init(uuid: "d1", text: "doubted")]
        file.pause = "stopped"
        let q = ChatQueue(restoring: file)
        #expect(q.pause == .restarted, "the pause of the last run is replaced by the restart's")
        #expect(q.cards.map(\.id) == ["d1", "f1", "c1", "c2"], "\(q.cards.map(\.id))")
        #expect(q.doubtCards.map(\.id) == ["d1", "f1"] && q.rows.prefix(2).allSatisfy { $0.hold == .paused("doubt") })
        var written = ChatComposerFile()
        q.store(into: &written)
        #expect(written.doubt?.map(\.uuid) == ["d1", "f1"] && written.inflight == nil && written.cards?.map(\.id) == ["c1", "c2"] && written.pause == "restarted")
        let again = ChatQueue(restoring: written)
        #expect(again.cards.map(\.id) == q.cards.map(\.id), "a second restart changes nothing")
        var empty = ChatComposerFile()
        empty.pause = "other"
        #expect(ChatQueue(restoring: empty).pause == .none, "no cards, nothing to hold")
        var onlyPaused = ChatComposerFile()
        onlyPaused.cards = [.init(id: "p", text: "p", state: "waiting", hold: "paused", paused: "kept")]
        #expect(ChatQueue(restoring: onlyPaused).pause == .none, "a card held on its own is outside every pause")
    }

    @Test func ChatOrcaD12_aSendInFlightLeavesTheCardAndIsInTheInflightListInTheSameChangeAndEveryEndOfItIsHandled() throws {
        var q = ChatQueue()
        let id = q.add("steer me")!
        _ = q.add("other")
        let send = ChatSendRequest(text: "steer me", origin: .card(id), steer: true, person: true)
        q.begin(send)
        #expect(q.cards.map(\.text) == ["other"] && q.inflight.map(\.uuid) == [send.uuid] && q.inflight[0].origin == "card:" + id)
        var file = ChatComposerFile()
        q.store(into: &file)
        #expect(file.inflight?.first?.text == "steer me" && file.cards?.count == 1, "one write holds both the missing card and the send")
        var refused = q
        refused.abort(send.uuid)
        #expect(refused.cards.map(\.text) == ["steer me", "other"] && refused.inflight.isEmpty, "a refused send undoes everything")
        var delivered = q
        delivered.delivered(send.uuid)
        #expect(delivered.cards.map(\.text) == ["other"] && delivered.inflight.isEmpty)
        var failed = q
        failed.unwritten(entry(send.uuid, text: "steer me", origin: .card(id)))
        try #require(failed.cards.count > 0, "failed.cards needs 1 elements: \(failed.cards.count)")
        #expect(failed.cards.map(\.text) == ["steer me", "other"] && failed.cards[0].paused == "send-failed" && failed.inflight.isEmpty, "its card comes back where it was, held")
        var withdrawn = q
        let withdrawnToOrigin = withdrawn.notDelivered(entry(send.uuid, text: "steer me", origin: .card(id)), .cancelled)
        #expect(!withdrawnToOrigin)
        try #require(withdrawn.cards.count > 0, "withdrawn.cards needs 1 elements: \(withdrawn.cards.count)")
        try #require(withdrawn.rows.count > 0, "withdrawn.rows needs 1 elements: \(withdrawn.rows.count)")
        #expect(withdrawn.cards[0].state == "returned" && withdrawn.cards[0].paused == "cancelled" && withdrawn.rows[0].caption == "Stopped before it was sent")
        var doubted = q
        doubted.doubt(entry(send.uuid, text: "steer me", origin: .card(id)))
        #expect(doubted.doubtCards.map(\.id) == [send.uuid] && doubted.inflight.isEmpty && doubted.cards.map(\.text) == ["steer me", "other"])
        doubted.delivered(send.uuid)
        #expect(doubted.cards.map(\.text) == ["other"], "a late replay removes the doubt card")
    }

    @Test func ChatOrcaD12_aDraftSendNotDeliveredGoesBackToTheDraftAndASteerOfTheDraftBecomesAReturnedCard() throws {
        var q = ChatQueue()
        let plain = ChatSendRequest(text: "plain", origin: .draft, steer: false)
        q.begin(plain)
        let plainBack = q.notDelivered(entry(plain.uuid, text: "plain", origin: .draft, steer: false), .cancelled)
        #expect(plainBack, "an ordinary draft send is the caller's: the text returns to the draft")
        let steer = ChatSendRequest(text: "with chips", origin: .draft, steer: true)
        q.begin(steer)
        let steerBack = q.notDelivered(entry(steer.uuid, text: "with chips", origin: .draft, steer: true), .refused)
        #expect(!steerBack)
        try #require(q.cards.count > 0, "q.cards needs 1 elements: \(q.cards.count)")
        try #require(q.rows.count > 0, "q.rows needs 1 elements: \(q.rows.count)")
        #expect(q.cards.map(\.text) == ["with chips"] && q.cards[0].state == "returned" && q.rows[0].caption == "The provider did not accept this message.")
        #expect(q.inflight.isEmpty)
    }

    // MARK: D13

    @Test func ChatOrcaD12_M4_aDoubtCardAReturnedCardAndTheRestartConversionKeepTheChipsOfTheirSendInTheStoredForm() throws {
        let chips = [ChatComposerChip(path: "/tmp/a.png"), ChatComposerChip(unavailable: "b.png")]
        func withChips(_ uuid: String, steer: Bool = false) -> ChatLedgerEntry {
            var made = entry(uuid, text: "with chips", steer: steer)
            made.chips = chips
            return made
        }
        // a doubt card
        var queue = ChatQueue()
        queue.begin(ChatSendRequest(text: "with chips", origin: .draft, steer: false, chips: chips, uuid: "d1"))
        queue.doubt(withChips("d1"))
        #expect(queue.doubtCards.map(\.chips) == [chips], "the card carries the chips")
        var file = ChatComposerFile()
        queue.store(into: &file)
        #expect(file.doubt?.first?.chips == chips && file.inflight == nil, "and so does the stored doubt entry")
        let reread = try JSONDecoder().decode(ChatComposerFile.self, from: JSONEncoder().encode(file))
        #expect(ChatQueue(restoring: reread).doubtCards.map(\.chips) == [chips], "a start finds the doubt card with its chips")
        // the restart conversion of a send in flight
        var flying = ChatQueue()
        flying.begin(ChatSendRequest(text: "with chips", origin: .draft, steer: false, chips: chips, uuid: "f1"))
        var flyingFile = ChatComposerFile()
        flying.store(into: &flyingFile)
        #expect(flyingFile.inflight?.first?.chips == chips)
        #expect(ChatQueue(restoring: flyingFile).doubtCards.map(\.chips) == [chips], "a send in flight at a restart becomes a doubt card with its chips")
        // a withdrawn steer becomes a returned card
        var steered = ChatQueue()
        steered.begin(ChatSendRequest(text: "with chips", origin: .draft, steer: true, chips: chips, uuid: "s1"))
        let backToDraft = steered.notDelivered(withChips("s1", steer: true), .cancelled)
        #expect(!backToDraft)
        #expect(steered.cards.first?.state == "returned" && steered.cards.first?.chips == chips, "the returned card keeps the chips")
        // a plain card keeps writing no chips field
        var plain = ChatQueue()
        _ = plain.add("plain")
        var plainFile = ChatComposerFile()
        plain.store(into: &plainFile)
        #expect(String(data: try JSONEncoder().encode(plainFile), encoding: .utf8)?.contains("chips") == false)
    }

    @Test func ChatOrcaD13_chatQueueFollowUpsIsABooleanThatDefaultsOnAndAWrongTypeIsIgnored() {
        #expect(ChatSettings(home: "/h").queueFollowUps)
        #expect(!ChatSettings(object: ["chatQueueFollowUps": false], home: "/h").queueFollowUps)
        #expect(ChatSettings(object: ["chatQueueFollowUps": true], home: "/h").queueFollowUps)
        #expect(ChatSettings(object: ["chatQueueFollowUps": "no"], home: "/h").queueFollowUps && ChatSettings(object: ["chatQueueFollowUps": 0], home: "/h").queueFollowUps)
    }
}

private extension ChatLedgerEntry {
    func with(_ lifecycle: ChatLifecycle) -> ChatLedgerEntry { var copy = self; copy.lifecycle = lifecycle; return copy }
    func with(uuid: String) -> ChatLedgerEntry { var copy = self; copy.uuid = uuid; return copy }
}
