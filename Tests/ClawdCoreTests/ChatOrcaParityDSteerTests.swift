import Testing
import Foundation
@testable import ClawdCore

// Orca parity round D, sprint 4, the session against a child: how every written send settles and how a steer lands (Q13). The child is
// Tests/Fixtures/chat/stubs/replay-plan.py, which plays the frames of the contained captures (d-steer-fold, d-steer-miss, d-steer-cancel,
// d-steer-fold-then-interrupt, d-local-command-uuid) when the session's own frames come in, so the uuids the ledger matches are the session's.

private func fixtureUuid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }

/// A session over the plan stub, with every verdict, every turn start and the stub's records collected.
@MainActor
private final class SteerRig {
    let rig: ChatRig
    var verdicts: [ChatSendVerdict] = []
    var turnsAtStart: [ChatTurnState] = []
    var lost: [ChatChildLoss] = []

    var session: ChatSession { rig.session }
    /// The conversation's entries without the notices the capture's own init draws (its session id and mode are not the rig's).
    var entries: [ChatEntry] { rig.session.transcript.entries.filter { $0.kind != .notice } }
    var kinds: [ChatEntry.Kind] { entries.map(\.kind) }

    /// `subst` maps a uuid number of the fixture to the number of the user frame whose uuid replaces it.
    init(fixture: String? = nil, subst: [Int: Int] = [:], steps: [[String: Any]]) throws {
        rig = try ChatRig(stub: "replay-plan.py")
        var plan: [String: Any] = ["subst": Dictionary(uniqueKeysWithValues: subst.map { (fixtureUuid($0.key), $0.value) }), "steps": steps]
        if let fixture { plan["fixture"] = repository.appendingPathComponent("Tests/Fixtures/chat/" + fixture).path }
        try JSONSerialization.data(withJSONObject: plan).write(to: URL(fileURLWithPath: rig.folder + "/plan.json"))
        session.onSendSettled = { [unowned self] in verdicts.append($0) }
        session.onChildLost = { [unowned self] in lost.append($0) }
        let counted = session.onTurnStarted
        session.onTurnStarted = { [unowned self] in counted?(); turnsAtStart.append(session.turn) }
    }

    func file(_ name: String) -> String? { try? String(contentsOfFile: rig.folder + "/" + name, encoding: .utf8) }

    func end() async {
        session.stop(.userStop)
        _ = await rig.wait { self.session.turn == .none && self.rig.log.contains { $0.hasPrefix("CHAT sweep") } }
    }

    var delivered: [String] { verdicts.compactMap { if case .delivered(let entry, _) = $0 { return entry.uuid } else { return nil } } }
    var notDelivered: [String] { verdicts.compactMap { if case .notDelivered(let entry, _) = $0 { return entry.uuid } else { return nil } } }
    var doubts: [String] { verdicts.compactMap { if case .doubt(let entry, _) = $0 { return entry.uuid } else { return nil } } }
    func toolStatuses() -> [ChatToolStatus?] { entries.filter { $0.kind == .tool }.map(\.status) }
}

private func steer(_ text: String = "Also put the word banana at the very end of your reply.") -> ChatSendRequest {
    ChatSendRequest(text: text, origin: .draft, steer: true)
}

private func state(_ name: String) -> [String: Any] { ["type": "system", "subtype": "session_state_changed", "state": name] }
private func lifecycle(_ uuid: String, _ name: String) -> [String: Any] { ["type": "command_lifecycle", "command_uuid": uuid, "state": name] }
private func replay(_ uuid: String) -> [String: Any] { ["type": "user", "isReplay": true, "uuid": uuid, "message": ["role": "user", "content": "x"]] }
private func result(_ names: [String]?, subtype: String = "success") -> [String: Any] {
    var frame: [String: Any] = ["type": "result", "subtype": subtype, "is_error": subtype != "success", "duration_ms": 1, "total_cost_usd": 0, "session_id": "s", "result": ""]
    if let names { frame["user_message_uuids"] = names }
    return frame
}

private func initFrame(_ capabilities: [String]) -> [String: Any] {
    ["type": "system", "subtype": "init", "session_id": "s", "model": "m", "permissionMode": "default", "claude_code_version": "2.1.312", "capabilities": capabilities]
}
private func answer(_ body: [String: Any]) -> [String: Any] {
    ["type": "control_response", "response": ["subtype": "success", "request_id": "$rid", "response": body]]
}
@MainActor private func controlLines(_ r: SteerRig, _ subtype: String) -> [[String: Any]] {
    (r.file("received.jsonl") ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        .filter { (($0["request"] as? [String: Any])?["subtype"] as? String) == subtype }
}

@Suite("Chat orca parity D, how a send settles and how a steer lands", .serialized)
@MainActor
struct ChatOrcaParityDSteerSuite {
    // MARK: the captures

    /// d-steer-fold: the first send's turn runs to its first tool result (lines 69 to 87), the steer comes in, and the rest plays (88 to 123).
    private func fold() throws -> SteerRig {
        try SteerRig(fixture: "d-steer-fold.jsonl", subst: [73: 1, 91: 2],
                     steps: [["on_user": 1, "frames": [[69, 88]]], ["on_user": 2, "frames": [[88, 124]]]])
    }

    @Test func ChatOrcaD13_foldOneTurnEndAtIdleTheSteerSitsAfterTheSecondToolLineAndBeforeTheFinalTextBothToolLinesAreDoneAndBothSendsAreDelivered() async throws {
        let r = try fold()
        #expect(r.session.send("Run sleep twice, then reply DONE"))
        #expect(await r.rig.wait { r.toolStatuses().contains(.done) }, "\(r.kinds)")
        let request = steer()
        #expect(r.session.send(request), "a steer is taken while the turn runs")
        #expect(r.entries.last?.text == request.text && r.entries.last?.sending == true && r.session.hasUnsettledSend, "pending, showing Sending")
        #expect(await r.rig.wait { r.rig.outcomes.count == 1 }, "\(r.kinds) \(r.rig.log)")
        #expect(r.kinds == [.user, .tool, .tool, .user, .assistant, .footer], "\(r.kinds)")
        try #require(r.entries.count > 3, "r.entries needs 4 elements: \(r.entries.count)")
        #expect(r.entries[3].text == request.text && !r.entries[3].sending, "the steer entry sits after the second tool line and before the final text")
        #expect(r.toolStatuses() == [.done, .done], "\(r.toolStatuses()): the steer ended no bookkeeping")
        #expect(r.entries.filter { $0.kind == .assistant }.count == 1, "one answer entry")
        #expect(r.delivered.count == 2 && r.delivered.last == request.uuid && r.notDelivered.isEmpty && r.doubts.isEmpty, "\(r.verdicts)")
        #expect(r.rig.outcomes.count == 1 && !r.session.hasUnsettledSend)
        #expect(r.rig.log.contains("CHAT steer turn=1 chars=\(request.text.count)") && r.rig.log.contains("CHAT steer-delivered turn=1 folded=1"), "\(r.rig.log)")
        #expect(r.rig.log.allSatisfy { !$0.contains("banana") }, "the log rule")
        #expect(r.rig.started == 1, "the steer began no turn")
        await r.end()
    }

    /// d-steer-miss: the first send's turn runs to its result (85 to 121). The steer is written before the CLI idles, so its `queued` frame (125) comes
    /// ahead of the first turn's `completed`, idle and `running` (122 to 124), and then its own turn plays (126 to 141). The capture itself shows the steer
    /// landing after the idle, so the frames are put in the order Orca's miss capture has (MC/claude-captured-fold-steer-frames.test-fixture.ts:113-149).
    private func miss() throws -> SteerRig {
        try SteerRig(fixture: "d-steer-miss.jsonl", subst: [89: 1, 128: 2],
                     steps: [["on_user": 1, "frames": [[85, 122]]], ["on_user": 2, "frames": [125, [122, 125], [126, 142]]]])
    }

    @Test func ChatOrcaD13_missNoTurnEndAtTheFirstResultTheSteersOwnTurnShowsStopAndIdleEndsIt() async throws {
        let r = try miss()
        #expect(r.session.send("Run sleep once, then reply OK"))
        #expect(await r.rig.wait { r.kinds.contains(.footer) }, "\(r.kinds)")
        #expect(r.session.turn == .running && r.rig.outcomes.isEmpty, "the first result ends nothing: only idle does")
        let request = steer()
        #expect(r.session.send(request))
        #expect(await r.rig.wait { r.rig.outcomes.count == 2 }, "\(r.rig.outcomes) \(r.kinds) \(r.rig.log)")
        #expect(r.rig.started == 2 && r.turnsAtStart == [.running, .running], "the steer's own turn began as a turn Clawd did not start, with Stop showing")
        #expect(r.rig.log.contains { $0.hasPrefix("CHAT turn foreign turn=2") }, "\(r.rig.log)")
        #expect(r.delivered.count == 2 && r.delivered.last == request.uuid && r.doubts.isEmpty && r.notDelivered.isEmpty, "\(r.verdicts)")
        #expect(r.kinds.filter { $0 == .footer }.count == 2 && r.entries.contains { $0.text == request.text && !$0.sending })
        #expect(r.rig.log.contains("CHAT steer-delivered turn=2 folded=0"), "a replay in a later turn is a miss: \(r.rig.log)")
        #expect(r.session.turn == .none && !r.session.hasUnsettledSend)
        await r.end()
    }

    /// d-steer-cancel: the steer is written at line 83, the interrupt goes in, and the CLI answers it (84 to 129): the first send is replayed, its
    /// result is the error, its `cancelled` comes after the replay, and the steer then starts and runs on.
    @Test func ChatOrcaD13_cancelTheFirstSendsCancelledAfterItsReplayIsIgnoredAndTheSteerThatStartsAfterItIsDeliveredAndNothingIsReturnedOrResent() async throws {
        let r = try SteerRig(fixture: "d-steer-cancel.jsonl", subst: [82: 1, 87: 2],
                             steps: [["on_user": 1, "frames": [[78, 83]]], ["on_user": 2, "frames": [83]], ["on_interrupt": 1, "frames": [[84, 130]]]])
        #expect(r.session.send("Run sleep twice, then reply DONE"))
        #expect(await r.rig.wait { r.session.transcript.sessionId != nil })
        let request = steer()
        #expect(r.session.send(request))
        r.session.interrupt()
        #expect(await r.rig.wait { r.rig.outcomes.count == 1 }, "\(r.rig.outcomes) \(r.kinds) \(r.rig.log)")
        #expect(r.delivered.count == 2 && r.delivered.last == request.uuid && r.notDelivered.isEmpty && r.doubts.isEmpty, "\(r.verdicts)")
        #expect(r.entries.contains { $0.text == request.text && !$0.sending && !$0.unconfirmed })
        #expect(!r.session.hasUnsettledSend && r.session.turn == .none)
        #expect(r.rig.outcomes.map(\.isSuccess) == [true], "the steer's own result is the last one of the turn: \(r.rig.outcomes)")
        let received = (r.file("received.jsonl") ?? "").split(separator: "\n").filter { $0.contains("\"type\":\"user\"") }
        #expect(received.count == 2, "nothing was resent: \(received.count)")
        await r.end()
    }

    /// A steer withdrawn before it started comes back as not delivered: frames written out, since the captures cancel the first send, not the steer.
    @Test func ChatOrcaD13_aSteerThatTheCliCancelsBeforeItStartedIsNotDeliveredItsPendingEntryIsRemovedAndTheTurnIsInterrupted() async throws {
        let r = try SteerRig(steps: [
            ["on_user": 1, "frames": [state("running"), lifecycle("$1", "queued"), lifecycle("$1", "started"), replay("$1")]],
            ["on_user": 2, "frames": [lifecycle("$2", "queued")]],
            ["on_interrupt": 1, "frames": [lifecycle("$2", "cancelled"), result(["$1"], subtype: "error_during_execution"), state("idle")]]])
        #expect(r.session.send("first"))
        #expect(await r.rig.wait { r.delivered.count == 1 })
        let request = steer("withdrawn")
        #expect(r.session.send(request))
        #expect(r.entries.last?.text == "withdrawn")
        r.session.interrupt()
        #expect(await r.rig.wait { r.rig.outcomes.count == 1 })
        #expect(r.notDelivered == [request.uuid] && r.delivered.count == 1 && r.doubts.isEmpty, "\(r.verdicts)")
        #expect(!r.entries.contains { $0.text == "withdrawn" }, "its pending entry is removed")
        #expect(r.rig.outcomes == [.interrupted] && !r.session.hasUnsettledSend)
        if case .notDelivered(_, let why)? = r.verdicts.last { #expect(why == .cancelled) } else { Issue.record("no verdict: \(r.verdicts)") }
        await r.end()
    }

    /// The measured fact behind the two tests below: an interrupt cancels the running command and leaves a queued steer to run next (d-steer-cancel).
    /// Orca does not leave it: it asks a CLI that advertises `interrupt_cancel_queued_v1` to cancel the queue in the interrupt itself, and otherwise
    /// withdraws each send the receipt lists as `still_queued` (MC/claude-structured-control-actions.ts:36-52).
    @Test func ChatOrcaD13_anInterruptOnACliThatAdvertisesCancelQueuedAsksForItAndTheSendsTheReceiptNamesAsCancelledNeverRan() async throws {
        let r = try SteerRig(steps: [
            ["on_user": 1, "frames": [initFrame(["interrupt_receipt_v1", "interrupt_cancel_queued_v1"]), state("running"), lifecycle("$1", "started"), replay("$1")]],
            ["on_user": 2, "frames": [lifecycle("$2", "queued")]],
            ["on_interrupt": 1, "frames": [answer(["still_queued": [], "cancelled": ["$2"]]), result(["$1"], subtype: "error_during_execution"), state("idle")]]])
        #expect(r.session.send("first"))
        #expect(await r.rig.wait { r.delivered.count == 1 })
        let request = steer("withdrawn by the interrupt")
        #expect(r.session.send(request))
        r.session.interrupt()
        #expect(await r.rig.wait { r.rig.outcomes.count == 1 }, "\(r.verdicts) \(r.rig.log)")
        #expect(controlLines(r, "interrupt").first.flatMap { ($0["request"] as? [String: Any])?["cancel_queued"] as? Bool } == true, "asked in the interrupt itself")
        #expect(controlLines(r, "cancel_async_message").isEmpty, "one round trip, no single withdrawals")
        #expect(r.notDelivered == [request.uuid] && r.doubts.isEmpty, "\(r.verdicts)")
        #expect(!r.entries.contains { $0.text == "withdrawn by the interrupt" } && r.session.turn == .none && !r.session.hasUnsettledSend)
        await r.end()
    }

    @Test func ChatOrcaD13_anInterruptOnACliWithoutItWithdrawsEachStillQueuedSendOfOursAndOnlyTheAnsweredOnesNeverRan() async throws {
        let r = try SteerRig(steps: [
            ["on_user": 1, "frames": [initFrame(["interrupt_receipt_v1"]), state("running"), lifecycle("$1", "started"), replay("$1")]],
            ["on_user": 2, "frames": [lifecycle("$2", "queued")]],
            ["on_user": 3, "frames": [lifecycle("$3", "queued")]],
            ["on_interrupt": 1, "frames": [answer(["still_queued": ["$2", "$3", "not-ours"]]), result(["$1"], subtype: "error_during_execution"), state("idle")]],
            ["on_cancel_async": 1, "frames": [lifecycle("$msg", "cancelled"), answer(["cancelled": true])]],
            ["on_cancel_async": 2, "frames": [answer(["cancelled": false])]]])
        #expect(r.session.send("first"))
        #expect(await r.rig.wait { r.delivered.count == 1 })
        let withdrawn = steer("withdrawn"), refused = steer("the CLI would not withdraw it")
        #expect(r.session.send(withdrawn) && r.session.send(refused))
        r.session.interrupt()
        #expect(await r.rig.wait { r.rig.outcomes.count == 1 && r.notDelivered.count == 1 }, "\(r.verdicts) \(r.rig.log)")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(controlLines(r, "interrupt").first.flatMap { ($0["request"] as? [String: Any])?["cancel_queued"] } == nil, "no capability, so no flag")
        let asked = controlLines(r, "cancel_async_message").compactMap { ($0["request"] as? [String: Any])?["message_uuid"] as? String }
        #expect(asked == [withdrawn.uuid, refused.uuid], "each of ours, in order, and not the uuid that is not ours: \(asked)")
        #expect(r.notDelivered == [withdrawn.uuid], "only the answered one: \(r.verdicts)")
        #expect(r.entries.contains { $0.text == refused.text } && !r.entries.contains { $0.text == "withdrawn" })
        await r.end()
    }

    /// d-steer-fold-then-interrupt: the steer is folded and replayed (121), the interrupt goes in, and the CLI cancels both sends after that (126, 128).
    @Test func ChatOrcaD13_foldThenInterruptTheReplayedSteerIsDeliveredNotReturned() async throws {
        let r = try SteerRig(fixture: "d-steer-fold-then-interrupt.jsonl", subst: [93: 1, 111: 2],
                             steps: [["on_user": 1, "frames": [[89, 108]]], ["on_user": 2, "frames": [[108, 124]]], ["on_interrupt": 1, "frames": [[124, 130]]]])
        #expect(r.session.send("Run sleep twice, then reply DONE"))
        #expect(await r.rig.wait { r.toolStatuses().contains(.done) })
        let request = steer()
        #expect(r.session.send(request))
        #expect(await r.rig.wait { r.delivered.count == 2 }, "\(r.verdicts)")
        r.session.interrupt()
        #expect(await r.rig.wait { r.rig.outcomes.count == 1 })
        #expect(r.delivered.last == request.uuid && r.notDelivered.isEmpty && r.doubts.isEmpty, "the cancel that follows the replay returns nothing: \(r.verdicts)")
        #expect(r.rig.outcomes == [.interrupted] && !r.session.hasUnsettledSend)
        #expect(r.entries.contains { $0.text == request.text && !$0.sending && !$0.unconfirmed })
        await r.end()
    }

    /// d-local-command-uuid: `/context`, a local command with a uuid. The frames up to its result play first (0 to 7), and the idle is held back (8)
    /// until the interrupt asks for it, so the result alone is seen to end nothing.
    @Test func ChatOrcaD13_aLocalCommandWithAUuidEndsItsTurnAtIdleAndNotAtItsResult() async throws {
        let r = try SteerRig(fixture: "d-local-command-uuid.jsonl", subst: [3: 1],
                             steps: [["on_user": 1, "frames": [[0, 8]]], ["on_interrupt": 1, "frames": [8]]])
        #expect(r.session.send("/context"))
        #expect(await r.rig.wait { r.kinds.contains(.footer) && r.delivered.count == 1 }, "\(r.kinds) \(r.verdicts)")
        #expect(r.session.turn == .running && r.rig.outcomes.isEmpty, "the result of a local command is not the end of its turn")
        r.session.interrupt()
        #expect(await r.rig.wait { r.rig.outcomes.count == 1 })
        #expect(r.rig.outcomes.map(\.isSuccess) == [true] && r.session.turn == .none, "the idle ended it with the result's outcome: \(r.rig.outcomes)")
        #expect(!r.session.hasUnsettledSend)
        await r.end()
    }

    // MARK: frames written out

    @Test func ChatOrcaD13_aStillQueuedSteerBecomesADoubtAtTheChildsEndWhenNoFrameEverNamedItAndTheEntryShowsNotConfirmed() async throws {
        let r = try SteerRig(steps: [["on_user": 1, "frames": [state("running"), lifecycle("$1", "queued"), lifecycle("$1", "started"), replay("$1")]]])
        #expect(r.session.send("first"))
        #expect(await r.rig.wait { r.delivered.count == 1 })
        let request = steer("lost steer")
        #expect(r.session.send(request))
        #expect(await r.rig.wait { (r.file("received.jsonl") ?? "").contains(request.uuid) })
        r.session.stop(.exam)
        #expect(await r.rig.wait { r.session.turn == .none && r.rig.log.contains { $0.hasPrefix("CHAT sweep") } })
        #expect(await r.rig.wait { r.doubts == [request.uuid] }, "\(r.verdicts)")
        if case .doubt(_, let why)? = r.verdicts.last { #expect(why == .childEnded) } else { Issue.record("\(r.verdicts)") }
        let shown = try #require(r.entries.first { $0.text == "lost steer" })
        #expect(shown.unconfirmed && !shown.sending, "the entry stays, with Not confirmed in place of the time")
        #expect(!r.session.hasUnsettledSend && r.rig.log.contains("CHAT send-settled outcome=doubt n=1"), "\(r.rig.log)")
    }

    @Test func ChatOrcaD13_aStartedSendNobodyConfirmedIsADoubtAtIdleAndALaterReplayOrResultThatNamesItDeliversItAndPlacesItsEntry() async throws {
        let r = try SteerRig(steps: [
            ["on_user": 1, "frames": [state("running"), lifecycle("$1", "queued"), lifecycle("$1", "started"), replay("$1")]],
            ["on_user": 2, "frames": [lifecycle("$2", "queued"), lifecycle("$2", "started")]],
            ["on_interrupt": 1, "frames": [result(["$1"]), state("idle")]],
            ["on_user": 3, "frames": [state("running"), lifecycle("$3", "queued"), lifecycle("$3", "started"), replay("$3"), replay("$2"), result(["$3", "$2"]), state("idle")]]])
        #expect(r.session.send("first"))
        #expect(await r.rig.wait { r.delivered.count == 1 })
        let request = steer("maybe ran")
        #expect(r.session.send(request))
        r.session.interrupt()
        #expect(await r.rig.wait { r.rig.outcomes.count == 1 })
        #expect(r.doubts == [request.uuid], "started and unconfirmed when the turn went idle: \(r.verdicts)")
        if case .doubt(_, let why)? = r.verdicts.last { #expect(why == .startedAtIdle) } else { Issue.record("\(r.verdicts)") }
        #expect(r.entries.first { $0.text == "maybe ran" }?.unconfirmed == true)
        #expect(!r.session.hasUnsettledSend, "a doubt send holds nothing: it is a card")
        #expect(r.session.send("third"))
        #expect(await r.rig.wait { r.rig.outcomes.count == 2 })
        #expect(r.verdicts.contains { if case .delivered(let entry, let late) = $0 { return entry.uuid == request.uuid && late } else { return false } }, "\(r.verdicts)")
        #expect(r.entries.first { $0.text == "maybe ran" }?.unconfirmed == false)
        await r.end()
    }

    @Test func ChatOrcaD13_aReplayWithAUuidNeitherPendingNorInDoubtChangesNothingAndStartsNoTurn() async throws {
        let r = try SteerRig(steps: [
            ["on_user": 1, "frames": [state("running"), replay("$1"), result(["$1"]), state("idle")]],
            ["on_user": 1, "delay": 0.4, "frames": [replay("somebody-elses"), lifecycle("nobody", "started"), lifecycle("nobody", "cancelled"), result(["nobody"])]]])
        #expect(r.session.send("hello"))
        #expect(await r.rig.wait { r.rig.outcomes.count == 1 })
        let verdicts = r.verdicts.count
        try await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(r.verdicts.count == verdicts && r.rig.started == 1 && r.session.turn == .none && r.rig.outcomes.count == 1,
                "a frame that names a send Clawd did not write changes nothing: \(r.verdicts) \(r.rig.started)")
        await r.end()
    }

    @Test func ChatOrcaD13_quitMakesEveryUnconfirmedSendADoubtBeforeItReturns() async throws {
        let r = try SteerRig(steps: [["on_user": 1, "frames": [state("running"), lifecycle("$1", "queued"), lifecycle("$1", "started"), replay("$1")]]])
        #expect(r.session.send("first"))
        #expect(await r.rig.wait { r.delivered.count == 1 })
        let request = steer("unconfirmed at quit")
        #expect(r.session.send(request))
        #expect(await r.rig.wait { (r.file("received.jsonl") ?? "").contains(request.uuid) })
        r.session.quit(timeout: 8)
        #expect(r.doubts == [request.uuid], "converted before quit returned, with the main queue never run: \(r.verdicts)")
        #expect(r.entries.first { $0.text == "unconfirmed at quit" }?.unconfirmed == true)
    }

    @Test func ChatOrcaD13_requiresActionIsNotAnEndAndOnlyIdleEndsTheTurn() async throws {
        let r = try SteerRig(steps: [["on_user": 1, "frames": [state("running"), replay("$1"), state("requires_action")]], ["on_interrupt": 1, "frames": [result(["$1"]), state("idle")]]])
        #expect(r.session.send("hello"))
        #expect(await r.rig.wait { r.delivered.count == 1 })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(r.session.turn == .running && r.rig.outcomes.isEmpty)
        r.session.interrupt()
        #expect(await r.rig.wait { r.rig.outcomes.count == 1 })
        await r.end()
    }

    @Test func ChatOrcaD13_aChildThatSendsNoSessionStateFramesEndsItsTurnAtTheResultAsBeforeAndTheResultSettlesTheSend() async throws {
        let r = try SteerRig(steps: [["on_user": 1, "frames": [result(nil)]]])
        #expect(r.session.send("hello"))
        #expect(await r.rig.wait { r.rig.outcomes.count == 1 })
        #expect(r.rig.outcomes.count == 1 && r.session.turn == .none, "an older CLI has no idle frame")
        #expect(r.delivered.count == 1 && !r.session.hasUnsettledSend, "the result is the only settlement there is")
        await r.end()
    }

    @Test func ChatOrcaD13_spawnArgumentsEnvironmentAndEveryWrittenFrameCarryWhatTheLedgerNeeds() async throws {
        let r = try SteerRig(steps: [["on_user": 1, "frames": [state("running"), replay("$1"), result(["$1"]), state("idle")]]])
        let env = ChatSession.environment(ChatSettings(home: "/Users/example"), token: "tok")
        #expect(env["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"] == "1")
        let request = ChatSendRequest(text: "hello")
        #expect(r.session.send(request))
        #expect(await r.rig.wait { r.rig.outcomes.count == 1 })
        let argv = try #require(r.file("argv.txt")).split(separator: "\n").map(String.init)
        #expect(argv.contains("--replay-user-messages") && argv.contains("--include-partial-messages") && argv.contains("--session-id"), "\(argv)")
        #expect(r.file("env.txt") == "1\n", "the child's environment has the idle variable")
        let line = try #require((r.file("received.jsonl") ?? "").split(separator: "\n").first)
        let frame = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let sessionId = argv[(argv.firstIndex(of: "--session-id") ?? 0) + 1]
        #expect(frame["uuid"] as? String == request.uuid && frame["session_id"] as? String == sessionId && frame["type"] as? String == "user")
        #expect(frame["parent_tool_use_id"] is NSNull, "parent_tool_use_id is null")
        #expect((frame["message"] as? [String: Any])?["content"] as? String == "hello")
        await r.end()
    }

    @Test func ChatOrcaD13_aChildThatDiesOnItsOwnIsReportedAsLostAndAStopAskedForIsNot() async throws {
        let crashing = try ChatRig(stub: "crash.sh")
        var losses: [ChatChildLoss] = []
        crashing.session.onChildLost = { losses.append($0) }
        #expect(crashing.session.send("hello"))
        #expect(await crashing.wait { crashing.outcomes.count == 1 && crashing.session.turn == .none })
        #expect(losses == [.exited], "\(losses)")

        let r = try SteerRig(steps: [["on_user": 1, "frames": [state("running"), replay("$1")]]])
        #expect(r.session.send("hello"))
        #expect(await r.rig.wait { r.delivered.count == 1 })
        r.session.stop(.exam)
        #expect(await r.rig.wait { r.session.turn == .none && r.rig.log.contains { $0.hasPrefix("CHAT sweep") } })
        #expect(r.lost.isEmpty, "a stop asked for is not a loss: \(r.lost)")
    }
}

private extension ChatTurnOutcome {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}
