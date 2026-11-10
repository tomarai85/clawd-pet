import Testing
import Foundation
@testable import ClawdCore

private let targetId = "11111111-2222-4333-8444-555555555555"

/// `/resume` in the bridge: the next child continues a conversation by id. Every stub is a script; no real claude runs, and the registry is a
/// temporary folder.
@MainActor
struct ChatSessionResumeTests {
    private func argsLines(_ rig: ChatRig) -> [String] {
        (try? String(contentsOfFile: rig.folder + "/spawn-args.log", encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    }
    private func settle(_ rig: ChatRig) async -> Bool {
        await rig.wait { rig.session.turn == .none && rig.log.contains { $0.hasPrefix("CHAT sweep") } }
    }
    private func registry() throws -> String {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                    create: true).path
    }

    @Test func ChatSession_resumeSpawnsTheNextChildWithResumeAndTheId() async throws {
        let rig = try ChatRig(stub: "resume-fork.sh")
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(rig.session.resume(targetId, title: "Older talk"))
        #expect(rig.session.sessionID == targetId, "the id is the resumed one at once")
        #expect(rig.log.contains("CHAT resume session=11111111"), "\(rig.log)")
        #expect(rig.log.contains("CHAT stop reason=resume"))
        #expect(await settle(rig))
        #expect(rig.session.transcript.entries.last?.kind == .divider)
        #expect(rig.session.transcript.entries.last?.text == "Resumed: Older talk")
        #expect(rig.session.send("two"))
        #expect(await rig.wait { rig.spawns == 2 })
        #expect(await rig.wait { argsLines(rig).count == 2 })
        let lines = argsLines(rig)
        #expect(lines.count == 2 && lines[1].contains("--resume \(targetId) "), "\(lines)")
        #expect(!lines.dropFirst().contains { $0.contains("--session-id") }, "never a fresh conversation: \(lines)")
        #expect(rig.log.contains { $0.hasPrefix("CHAT spawn ") && $0.contains("mode=resume") })
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none })
    }

    @Test func ChatSession_resumeIsRefusedWhileATurnRunsOrASendIsUnsettled() async throws {
        let rig = try ChatRig(stub: "deaf.sh")
        #expect(rig.session.send("one"))
        #expect(rig.session.turn == .running)
        let before = rig.session.sessionID
        #expect(!rig.session.resume(targetId, title: "x"), "a turn runs")
        #expect(rig.session.sessionID == before)
        #expect(!rig.log.contains { $0.hasPrefix("CHAT resume ") })
        rig.session.stop(.userStop)
        #expect(rig.session.turn == .stopping)
        #expect(!rig.session.resume(targetId, title: "x"), "the child is stopping")
        #expect(await settle(rig))
        #expect(rig.session.transcript.entries.allSatisfy { $0.kind != .divider })
        // The conversation already in use is refused; another one is taken.
        #expect(rig.session.resume(targetId, title: "x"))
        #expect(!rig.session.resume(targetId.uppercased(), title: "x"), "already the next conversation")
    }

    @Test func ChatSession_resumeAndSpawnPassOnlyAUUID() async throws {
        let rig = try ChatRig(stub: "nonuuid-init.sh")
        for bad in ["-p", "../x", "a title", "", "11111111-2222-4333-8444-55555555555", targetId + "0"] {
            #expect(!rig.session.resume(bad, title: "x"), "\(bad)")
        }
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(rig.session.sessionID == "-p", "the init's own word, kept as it is")
        rig.session.stop(.userStop)
        #expect(await settle(rig))
        #expect(rig.session.send("two"))
        #expect(await rig.wait { rig.outcomes.count == 2 })
        #expect(rig.log.contains("CHAT resume dropped reason=not-uuid"), "\(rig.log)")
        let lines = argsLines(rig)
        #expect(lines.count == 2 && lines[1].contains("--session-id ") && !lines[1].contains("--resume") && !lines[1].contains(" -p -p"), "\(lines)")
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none })
    }

    @Test func ChatSession_aRetiredChildsLateInitDoesNotNameTheConversation() async throws {
        let rig = try ChatRig(stub: "late-init.sh")
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(rig.session.resume(targetId, title: "Older talk"))
        #expect(await settle(rig))
        #expect(rig.session.sessionID == targetId, "the old child's last init (000000000099) did not name the conversation: \(rig.session.sessionID ?? "nil")")
        #expect(rig.session.transcript.entries.filter { $0.text.contains("another session") }.count <= 1, "only the first turn's stub id differs from the one asked for")
        #expect(rig.session.send("two"))
        #expect(await rig.wait { argsLines(rig).count == 2 })
        #expect(argsLines(rig).last?.contains("--resume \(targetId) ") == true, "\(argsLines(rig))")
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none })
    }

    @Test func ChatSession_aRetiredChildsFramesAfterItsStopAreDropped() async throws {
        let rig = try ChatRig(stub: "resume-fork.sh")
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        let old = try #require(rig.session.childForTests)
        #expect(rig.session.resume(targetId, title: "Older talk"))
        #expect(await settle(rig))
        let before = rig.session.transcript.sessionId, entries = rig.session.transcript.entries.count
        // The reader of the stopped child had one more batch in its hand-off: it reaches the drain after stopped() ran.
        old.handoff.push(.initialized(sessionId: "00000000-0000-4000-8000-000000000077", model: "m", permissionMode: "p", version: "v"))
        old.handoff.push(.assistantBlocks(messageKey: "late", blocks: [.text("late words")]))
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(rig.session.transcript.sessionId == before, "the old child's init did not name the transcript: \(String(describing: rig.session.transcript.sessionId))")
        #expect(rig.session.transcript.entries.count == entries && !rig.session.transcript.entries.contains { $0.text.contains("late words") }, "nothing it said landed under the divider")
        #expect(rig.session.sessionID == targetId)
    }

    @Test func ChatSession_aResumeHeldInAnotherTerminalIsNotSpawned() async throws {
        let sessions = try registry()
        let rig = try ChatRig(stub: "resume-fork.sh") { $0.resume = ChatResume.Roots(projects: nil, sessions: sessions) }
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(rig.session.resume(targetId, title: "Older talk"))
        #expect(await settle(rig))
        let me = getpid()
        let record = sessions + "/\(me).json"
        try "{\"pid\":\(me),\"sessionId\":\"\(targetId)\",\"kind\":\"interactive\"}".write(toFile: record, atomically: true, encoding: .utf8)
        var times = [timeval(tv_sec: Int(Date().timeIntervalSince1970) + 5, tv_usec: 0), timeval(tv_sec: Int(Date().timeIntervalSince1970) + 5, tv_usec: 0)]
        utimes(record, &times)
        #expect(!rig.session.send("two"), "another process holds the conversation")
        #expect(rig.session.transcript.entries.contains { $0.kind == .error && $0.text == ChatResume.heldText })
        #expect(argsLines(rig).count == 1, "no child was spawned: \(argsLines(rig))")
        #expect(rig.session.sessionID == targetId, "the id stays for the next send")
        // A record no longer there: the same send goes through, resuming.
        try FileManager.default.removeItem(atPath: record)
        #expect(rig.session.send("three"))
        #expect(await rig.wait { argsLines(rig).count == 2 })
        #expect(argsLines(rig).last?.contains("--resume \(targetId) ") == true)
        // A live record that says nothing about its session is not a free conversation.
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none })
        try "{\"pid\":\(me)}".write(toFile: record, atomically: true, encoding: .utf8)
        utimes(record, &times)
        #expect(!rig.session.send("four"))
        #expect(rig.session.transcript.entries.contains { $0.kind == .error && $0.text == ChatResume.unknownHolderText })
        #expect(argsLines(rig).count == 2)
    }

    @Test func ChatSession_aGoneConversationFallsBackFresh() async throws {
        let rig = try ChatRig(stub: "resume-refused.sh")
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(rig.session.resume(targetId, title: "Gone"))
        #expect(await settle(rig))
        #expect(rig.session.send("two"), "the resume spawn meets the refusal")
        #expect(await rig.wait { rig.outcomes.count == 2 && rig.session.turn == .none })
        #expect(rig.log.contains("CHAT resume refused session=11111111"), "\(rig.log)")
        #expect(rig.session.sessionID == nil, "the refused id is dropped")
        #expect(rig.session.transcript.entries.contains { $0.kind == .error && $0.text == "Claude Code stopped (exit 1)" })
        #expect(await rig.wait { !rig.childAlive && rig.session.turn == .none })
        #expect(rig.session.send("three"), "the next send starts fresh")
        #expect(await rig.wait { argsLines(rig).count == 3 })
        let lines = argsLines(rig)
        #expect(lines.count == 3 && lines[1].contains("--resume \(targetId) ") && lines[2].contains("--session-id ") && !lines[2].contains("--resume"), "\(lines)")
        #expect(await rig.wait { rig.outcomes.count == 3 })
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none })
    }
}
