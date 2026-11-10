import Testing
import Foundation
@testable import ClawdCore

// Stage 2 R1, R6: the bridge feeds the chat page changes only, one call in flight, the confirmed state advancing only on success. No web view.

/// A page as the bridge sees it: every call recorded, each completion held until the test answers it.
final class RecordingTransport: ChatWebTransport {
    var calls: [ChatWebCall] = []
    private var completions: [(Bool) -> Void] = []
    /// The most calls that were outstanding (sent, not answered) at any one moment.
    private(set) var maxOutstanding = 0
    func send(_ call: ChatWebCall, completion: @escaping (Bool) -> Void) {
        calls.append(call)
        completions.append(completion)
        maxOutstanding = max(maxOutstanding, completions.count)
    }
    /// Answers the oldest call that has not been answered.
    func answer(_ succeeded: Bool) {
        guard !completions.isEmpty else { return }
        completions.removeFirst()(succeeded)
    }
    var outstanding: Int { completions.count }
}

@MainActor
final class ChatWebBridgeRig {
    final class LogBox { var lines: [String] = [] }
    let transport: RecordingTransport
    let timers: ManualChatTimers
    let bridge: ChatWebBridge
    private let logBox: LogBox
    var logs: [String] { logBox.lines }

    init() {
        let box = LogBox(), recorder = RecordingTransport(), manual = ManualChatTimers()
        logBox = box; transport = recorder; timers = manual
        bridge = ChatWebBridge(transport: recorder, timers: manual, log: { box.lines.append($0) })
    }

    static func entry(_ id: Int, _ text: String, kind: ChatEntry.Kind = .assistant) -> ChatEntry {
        ChatEntry(id: id, kind: kind, text: text)
    }
}

@Suite("Chat web bridge", .serialized)
@MainActor
struct ChatWebBridgeSuite {
    typealias Rig = ChatWebBridgeRig

    @Test func ChatWebBridge_nothingIsSentBeforeTheReady() throws {
        let r = Rig()
        r.bridge.update(entries: [Rig.entry(1, "a")], turn: .running)
        r.bridge.update(entries: [Rig.entry(1, "ab")], turn: .running)
        #expect(r.transport.calls.isEmpty && !r.bridge.isReady)
        r.bridge.pageReady()
        #expect(r.transport.calls.count == 1 && r.transport.calls[0].kind == .reset, "the first call after ready is a reset with the whole conversation")
        try #require(r.transport.calls.count > 0, "r.transport.calls needs 1 elements: \(r.transport.calls.count)")
        #expect(r.transport.calls[0].upserts.map(\.text) == ["ab"] && r.transport.calls[0].turn == .running)
    }

    @Test func ChatWebBridge_onlyChangedEntriesAreSentAndOrderOnlyWhenTheIdListChanged() {
        let r = Rig()
        let first = [Rig.entry(1, "hello", kind: .user), Rig.entry(2, "one"), Rig.entry(3, "two")]
        r.bridge.pageReady()
        r.bridge.update(entries: first, turn: .none)
        r.transport.answer(true)
        r.bridge.update(entries: [first[0], Rig.entry(2, "one more"), first[2]], turn: .none)
        #expect(r.transport.calls.count == 2)
        let call = r.transport.calls[1]
        #expect(call.kind == .apply && call.upserts.map(\.id) == [2] && call.order == nil && call.turn == nil, "one changed entry: no order, no turn")
        r.transport.answer(true)
        r.bridge.update(entries: [first[0], Rig.entry(2, "one more"), first[2]], turn: .none)
        #expect(r.transport.calls.count == 2, "nothing changed: nothing is sent")
        r.bridge.update(entries: [first[0], Rig.entry(2, "one more"), first[2], Rig.entry(4, "three")], turn: .none)
        let added = r.transport.calls[2]
        #expect(added.upserts.map(\.id) == [4] && added.order == [1, 2, 3, 4], "a new entry carries the id list")
        r.transport.answer(true)
        r.bridge.update(entries: [first[0], Rig.entry(2, "one more"), first[2], Rig.entry(4, "three")], turn: .running)
        let turn = r.transport.calls[3]
        #expect(turn.upserts.isEmpty && turn.order == nil && turn.turn == .running, "a turn change alone")
        r.transport.answer(true)
        // The trim marker takes the place of the oldest entries: the id list changes.
        r.bridge.update(entries: [Rig.entry(9, "Earlier messages trimmed", kind: .notice), first[2], Rig.entry(4, "three")], turn: .running)
        let trimmed = r.transport.calls[4]
        #expect(trimmed.order == [9, 3, 4] && trimmed.upserts.map(\.id) == [9])
    }

    @Test func ChatWebBridge_oneCallIsInFlightAndWhatChangesMeanwhileGoesOutMergedWhenItReturns() throws {
        let r = Rig()
        r.bridge.pageReady()
        r.bridge.update(entries: [Rig.entry(1, "a")], turn: .running)
        r.bridge.update(entries: [Rig.entry(1, "ab")], turn: .running)
        r.bridge.update(entries: [Rig.entry(1, "abc")], turn: .running)
        #expect(r.transport.calls.count == 1 && r.transport.outstanding == 1)
        r.transport.answer(true)
        #expect(r.transport.calls.count == 2)
        try #require(r.transport.calls.count > 1, "r.transport.calls needs 2 elements: \(r.transport.calls.count)")
        #expect(r.transport.calls[1].upserts.map(\.text) == ["abc"], "the two changes that came meanwhile are one call")
    }

    @Test func ChatWebBridge_aFailingCallIsFollowedByAResetThatCarriesTheLostUpserts() {
        let r = Rig()
        r.bridge.pageReady()
        r.bridge.update(entries: [Rig.entry(1, "a")], turn: .none)
        r.transport.answer(true)
        r.bridge.update(entries: [Rig.entry(1, "a"), Rig.entry(2, "lost unless a reset follows")], turn: .none)
        #expect(r.transport.calls.last?.kind == .apply)
        r.transport.answer(false)
        let next = r.transport.calls.last
        #expect(next?.kind == .reset, "after an error the next call is a reset")
        #expect(next?.upserts.map(\.text) == ["a", "lost unless a reset follows"], "the reset carries the upsert the failed call lost")
        #expect(next?.order == [1, 2])
        r.transport.answer(true)
        r.bridge.update(entries: [Rig.entry(1, "a"), Rig.entry(2, "lost unless a reset follows")], turn: .none)
        #expect(r.transport.calls.count == 3, "the reset was confirmed: nothing more to send")
    }

    @Test func ChatWebBridge_aCallThatNeverCompletesKeepsItsSlotPastTheDeadlineAndNothingPilesUpBehindIt() throws {
        let r = Rig()
        r.bridge.pageReady()
        r.bridge.update(entries: [Rig.entry(1, "a")], turn: .none)
        #expect(r.timers.live == [ChatWebBridge.timeoutSeconds])
        r.timers.fire(atLeast: ChatWebBridge.timeoutSeconds)
        #expect(r.logs.contains("CHAT web apply-timeout"))
        #expect(r.transport.calls.count == 1 && r.transport.outstanding == 1, "the deadline passed: the call is still the one in flight, nothing was sent")
        r.bridge.update(entries: [Rig.entry(1, "a"), Rig.entry(2, "b")], turn: .none)
        r.timers.fire(atLeast: 60)
        #expect(r.transport.calls.count == 1 && r.transport.outstanding == 1, "a change after the deadline waits for the late call")
        r.transport.answer(true)                       // the first call's late answer
        #expect(r.transport.calls.count == 2 && r.transport.outstanding == 1, "the next call goes out from the late call's own completion")
        try #require(r.transport.calls.count > 1, "r.transport.calls needs 2 elements: \(r.transport.calls.count)")
        #expect(r.transport.calls[1].kind == .apply && r.transport.calls[1].upserts.map(\.id) == [2], "the late success confirmed what it carried: only the new entry goes")
        r.transport.answer(true)
        r.bridge.update(entries: [Rig.entry(1, "a"), Rig.entry(2, "b")], turn: .none)
        #expect(r.transport.calls.count == 2, "everything is confirmed")
        #expect(r.transport.maxOutstanding == 1, "never more than one call outstanding, at any moment")
    }

    @Test func ChatWebBridge_aCallThatFailsAfterItsDeadlineIsFollowedByOneResetAndNeverTwoCallsAtOnce() {
        let r = Rig()
        r.bridge.pageReady()
        r.bridge.update(entries: [Rig.entry(1, "a")], turn: .none)
        r.timers.fire(atLeast: ChatWebBridge.timeoutSeconds)
        r.bridge.update(entries: [Rig.entry(1, "ab")], turn: .none)
        r.transport.answer(false)
        #expect(r.transport.calls.count == 2 && r.transport.calls[1].kind == .reset && r.transport.calls[1].upserts.map(\.text) == ["ab"])
        r.timers.fire(atLeast: ChatWebBridge.timeoutSeconds)
        r.timers.fire(atLeast: ChatWebBridge.timeoutSeconds)
        #expect(r.transport.calls.count == 2, "the reset is slow too: still nothing behind it")
        r.transport.answer(true)
        r.bridge.update(entries: [Rig.entry(1, "ab")], turn: .none)
        #expect(r.transport.calls.count == 2 && r.transport.maxOutstanding == 1)
    }

    @Test func ChatWebBridge_aPageThatKeepsFailingIsNotHammeredAndRecoversOnTheNextChange() {
        let r = Rig()
        r.bridge.pageReady()
        r.bridge.update(entries: [Rig.entry(1, "a")], turn: .none)
        for _ in 0..<10 { r.transport.answer(false) }
        #expect(r.transport.calls.count == ChatWebBridge.retries + 1, "the first call and its retries, then it waits")
        r.bridge.update(entries: [Rig.entry(1, "ab")], turn: .none)
        #expect(r.transport.calls.count == ChatWebBridge.retries + 2 && r.transport.calls.last?.kind == .reset, "the next change tries again, with a reset")
    }

    @Test func ChatWebBridge_aLostPageSendsNothingUntilItIsReadyAgainAndThenResets() {
        let r = Rig()
        r.bridge.pageReady()
        r.bridge.update(entries: [Rig.entry(1, "a")], turn: .none)
        r.transport.answer(true)
        r.bridge.pageLost()
        r.bridge.update(entries: [Rig.entry(1, "ab")], turn: .none)
        #expect(r.transport.calls.count == 1)
        r.bridge.pageReady()
        #expect(r.transport.calls.count == 2 && r.transport.calls[1].kind == .reset && r.transport.calls[1].upserts.map(\.text) == ["ab"])
    }

    @Test func ChatWebBridge_everyCallIsLoggedWithItsCountsAndNoText() {
        let r = Rig()
        r.bridge.pageReady()
        r.bridge.update(entries: [Rig.entry(1, "secret words")], turn: .none)
        #expect(r.logs == ["CHAT web apply n=1 bytes=\(64 + 64 + "secret words".utf8.count + 2)"], "the entry's text and keys plus the id list \"1,\": \(r.logs)")
        r.transport.answer(true)
        r.bridge.update(entries: [Rig.entry(1, "secret words!")], turn: .none)
        #expect(r.logs.last?.hasPrefix("CHAT web apply n=1 bytes=") == true && !r.logs.joined().contains("secret"))
    }

    @Test func ChatWebBridge_aCallsBytesAreTheChangedEntriesPlusAFixedMargin() throws {
        let r = Rig()
        r.bridge.pageReady()
        var entries = (1...50).map { Rig.entry($0, String(repeating: "x", count: 40_000)) }
        r.bridge.update(entries: entries, turn: .running)
        r.transport.answer(true)
        entries[49].text += String(repeating: "y", count: 1000)
        r.bridge.update(entries: entries, turn: .running)
        try #require(r.transport.calls.count > 1, "calls needs 2 elements: \(r.transport.calls.count)")
        let call = r.transport.calls[1]
        try #require(entries.count > 49, "entries needs 50 elements: \(entries.count)")
        #expect(call.upserts.count == 1 && call.bytes <= entries[49].text.utf8.count + 2048, "the 2 MB conversation does not go again: \(call.bytes) bytes")
    }

    @Test func ChatWebBridge_aCallsBytesCountTheIdListWhenOnlyTheOrderChanged() {
        let r = Rig()
        r.bridge.pageReady()
        let entries = (1...8000).map { Rig.entry($0, "x") }
        r.bridge.update(entries: entries, turn: .none)
        r.transport.answer(true)
        let trimmed = Array(entries.dropFirst())
        r.bridge.update(entries: trimmed, turn: .none)
        let call = r.transport.calls[1]
        let idBytes = trimmed.reduce(0) { $0 + String($1.id).utf8.count + 1 }
        #expect(call.upserts.isEmpty && call.order?.count == 7999, "only the id list changed")
        #expect(call.bytes == 64 + idBytes, "the call's bytes are its id list too: \(call.bytes) (the list is \(idBytes))")
        #expect(r.logs.last == "CHAT web apply n=0 bytes=\(64 + idBytes)", "\(r.logs.last ?? "")")
    }

    @Test func ChatWebPayload_anEntryKeepsItsFieldsAndLeavesOutWhatItLacks() {
        var tool = ChatEntry(id: 7, kind: .tool, text: "ls", tool: "Bash", status: .running)
        tool.seconds = 2.5
        let value = ChatWebPayload.entry(tool)
        #expect(value["id"] as? Int == 7 && value["kind"] as? String == "tool" && value["tool"] as? String == "Bash" && value["status"] as? String == "running")
        #expect(value["seconds"] as? Double == 2.5 && value["ms"] == nil && value["cost"] == nil && value["elided"] == nil)
        #expect(ChatWebPayload.turn(.stopping) == "stopping")
    }

    @Test func ChatWebLink_onlyHttpAndHttpsWithAHostUpTo2KiBMayBeOpened() {
        #expect(ChatWebLink.openable("https://example.com/a?b=c#d")?.host == "example.com")
        #expect(ChatWebLink.openable("http://example.com") != nil)
        #expect(ChatWebLink.openable("HTTPS://Example.com") != nil)
        for bad in ["javascript:alert(1)", "file:///etc/passwd", "ftp://example.com", "mailto:a@b.c", "data:text/html,x", "x-apple.systempreferences:", "https://", "http:///path",
                    "example.com", "", " https://example.com", "https://exa mple.com"] {
            #expect(ChatWebLink.openable(bad) == nil, "\(bad)")
        }
        let longest = "https://example.com/" + String(repeating: "a", count: ChatWebLink.maxBytes - 20)
        #expect(longest.utf8.count == ChatWebLink.maxBytes && ChatWebLink.openable(longest) != nil)
        #expect(ChatWebLink.openable(longest + "a") == nil)
    }
}
