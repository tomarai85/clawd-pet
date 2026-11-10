import Testing
import Foundation
import Darwin
@testable import ClawdCore
import ClawdDesktop

@MainActor
struct ChatSendFailedTests {
    private final class Failures { var texts: [String] = [] }

    private func rig(_ stub: String, _ failures: Failures) throws -> ChatRig {
        let rig = try ChatRig(stub: stub)
        rig.session.onSendFailed = { failures.texts.append($0) }
        return rig
    }

    @Test func ChatSession_aWriteThatFailsGivesTheTextBackExactlyOnce() async throws {
        let failures = Failures()
        let rig = try rig("closed-stdin.sh", failures)
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(failures.texts.isEmpty, "the first line was written")
        #expect(rig.session.send("two"))
        #expect(await rig.wait { failures.texts.count == 1 })
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(failures.texts == ["two"])
        rig.session.stop(.exam)
        #expect(await rig.wait { rig.session.turn == .none })
        #expect(failures.texts == ["two"])
    }

    @Test func ChatSession_aChildThatLeavesWhileTheLineIsStillBeingWrittenGivesTheFullTextBackOnce() async throws {
        let failures = Failures()
        let rig = try rig("deaf-exit.sh", failures)
        let long = String(repeating: "x", count: 1_000_000)
        #expect(rig.session.send(long))
        #expect(await rig.wait { failures.texts.count == 1 })
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(failures.texts == [long])
        #expect(await rig.wait { rig.session.turn == .none })
    }

    @Test func ChatSession_aStopThatAbandonsTheQueuedLineGivesTheFullTextBackOnce() async throws {
        let failures = Failures()
        let rig = try rig("deaf.sh", failures)
        let long = String(repeating: "y", count: 1_000_000)
        #expect(rig.session.send(long))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(failures.texts.isEmpty, "still being written")
        rig.session.stop(.userStop)
        #expect(await rig.wait { failures.texts.count == 1 })
        #expect(await rig.wait { rig.session.turn == .none })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(failures.texts == [long])
    }

    @Test func ChatSession_aSendWhoseLineWasWrittenNeverCallsOnSendFailed() async throws {
        let failures = Failures()
        let rig = try rig("replay.sh", failures)
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(rig.session.send("two"))
        #expect(await rig.wait { rig.outcomes.count == 2 })
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(failures.texts.isEmpty)
    }
}

@MainActor
struct ChatRestoreTests {
    @Test func ChatPanel_anUnsentTextGoesBackIntoAnEmptyInputAndStaysAheadOfWhatWasTypedSince() {
        let r = ControllerRig()
        r.open()
        r.type("first message"); r.pressEnter()
        #expect(r.session.sent == ["first message"] && r.view.inputText == "")
        r.session.failSend("first message")
        #expect(r.view.inputText == "first message", "an empty input takes the text alone")
        #expect(r.session.sent == ["first message"], "it is never sent again by itself")
        r.view.inputText = ""
        r.type("second draft")
        r.session.failSend("lost text")
        #expect(r.view.inputText == "lost text\n\nsecond draft")
    }

    @Test func ChatPanel_anUnsentTextWithThePanelClosedWaitsInTheDraft() {
        let r = ControllerRig()
        r.open()
        r.type("hello"); r.pressEnter()
        r.controller.close(.esc)
        r.session.failSend("hello")
        #expect(r.controller.draft == "hello")
        r.open(at: 3)
        #expect(r.view.inputText == "hello")
    }
}
