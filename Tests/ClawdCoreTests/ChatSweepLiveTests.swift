import Testing
import Foundation
import Darwin
@testable import ClawdCore
import ClawdDesktop

@MainActor
struct ChatSweepLiveTests {
    @Test func ChatSession_aProcessThatLeftTheChildBetweenTwoStopsIsStillSweptByTheLiveSnapshot() async throws {
        let pidFile = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                                  create: true).appendingPathComponent("sleeper.pid").path
        let script = try filledScript("orphan.sh", ["@PIDFILE@": pidFile, "@FIXTURES@": repository.appendingPathComponent("Tests/Fixtures/chat").path])
        let rig = try ChatRig(stub: "orphan.sh", claude: script, permissions: .bypass)
        let began = ProcessInfo.processInfo.systemUptime
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        while ProcessInfo.processInfo.systemUptime - began < 2.7 { try await Task.sleep(nanoseconds: 20_000_000) }
        let text = (try? String(contentsOfFile: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sleeper = try #require(Int32(text), "the stub wrote the pid of its detached tool")
        let identity = try #require(ChatProc.identity(of: sleeper))
        defer { ChatProc.signal(identity, SIGKILL) }
        let parent = ChatProc.table().first { $0.identity.pid == sleeper }
        #expect(parent?.parent == 1, "the tool was reparented to launchd before the stop")
        #expect(parent.map { $0.group != rig.session.spawnedForTests?.pid } ?? false, "and it is outside the child's group")
        rig.session.stop(.exam)
        #expect(await rig.wait { rig.session.turn == .none })
        #expect(ChatProc.identity(of: sleeper) != identity, "the detached tool is gone after the stop")
    }
}

