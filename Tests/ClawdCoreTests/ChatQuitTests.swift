import Testing
import Foundation
import Darwin
@testable import ClawdCore
import ClawdDesktop

struct ChatQuitTests {
    private func carrierCount(_ token: String) -> Int { ChatProc.carriers(of: token, in: ChatProc.table()).count }

    @Test func ChatQuit_aTermWhileAChatChildLivesStopsTheChildAndWhatItStartedBeforeTheAgentDiesOfTerm() async throws {
        let script = try filledScript("grandchild.sh", ["@STUB@": builtTool("ClawdChatStub").path,
                                                       "@FIXTURES@": repository.appendingPathComponent("Tests/Fixtures/chat").path])
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                                 create: true).path
        let agent = try AgentRun(["--test-chat-quit", script, folder, "child"])
        let ready = try #require(await agent.line(startingWith: "CHATQUIT-READY"))
        let token = try #require(agent.field("token", in: ready))
        let child = try #require(agent.field("child", in: ready).flatMap { Int32($0) })
        var seen = 0
        for _ in 0..<150 where seen == 0 { seen = carrierCount(token); try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(seen == 1, "the detached helper is alive before the signal: \(ready)")
        #expect(Darwin.kill(agent.process.processIdentifier, SIGTERM) == 0)
        #expect(await agent.ended(within: 90), "the agent quit: \(agent.output)")
        #expect(agent.diedOfTerm, "died by SIGTERM, status \(agent.process.terminationStatus) reason \(agent.process.terminationReason.rawValue)")
        #expect(carrierCount(token) == 0, "no token process is left")
        #expect(!ChatProc.table().contains { $0.identity.pid == child }, "the chat child is gone")
    }

    @Test func ChatQuit_aTermWithNoChatChildKillsTheAgentAtOnceAndBySigterm() async throws {
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                                 create: true).path
        let agent = try AgentRun(["--test-chat-quit", fixStub("replay.sh"), folder, "none"])
        #expect(await agent.line(startingWith: "CHATQUIT-READY") != nil)
        let start = Date()
        #expect(Darwin.kill(agent.process.processIdentifier, SIGTERM) == 0)
        #expect(await agent.ended(within: 3), "no wait: \(agent.output)")
        #expect(agent.diedOfTerm, "status \(agent.process.terminationStatus) reason \(agent.process.terminationReason.rawValue)")
        #expect(Date().timeIntervalSince(start) < 2.5)
    }

    @Test func ChatQuit_aTermWhileADraftWriteIsOwedWritesTheDraftBeforeTheAgentDiesOfTerm() async throws {
        let state = try artifactStore()
        let agent = try AgentRun(["--test-chat-quit", fixStub("replay.sh"), state.root.path, "draft"])
        #expect(await agent.line(startingWith: "CHATQUIT-READY") != nil, "\(agent.output)")
        let file = try state.url(ChatComposerStore.fileName).path
        #expect(!FileManager.default.fileExists(atPath: file), "the write is still owed")
        #expect(Darwin.kill(agent.process.processIdentifier, SIGTERM) == 0)
        #expect(await agent.ended(within: 10), "the agent quit: \(agent.output)")
        #expect(agent.diedOfTerm, "status \(agent.process.terminationStatus) reason \(agent.process.terminationReason.rawValue)")
        let saved = try? JSONDecoder().decode(ChatComposerFile.self, from: ReadOnlyFile.data(file))
        #expect(saved?.draft == "typed just before the quit", "the draft typed inside the 250 ms is on disk: \(String(describing: saved))")
    }

    @Test func ChatQuit_aTermWithNothingToCleanUpKillsAnAgentWhoseMainQueueIsHung() async throws {
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                                 create: true).path
        let agent = try AgentRun(["--test-chat-quit", fixStub("replay.sh"), folder, "hung"])
        #expect(await agent.line(startingWith: "CHATQUIT-READY") != nil)
        #expect(Darwin.kill(agent.process.processIdentifier, SIGTERM) == 0)
        #expect(await agent.ended(within: 3), "the handler itself ends the agent, with no help from the main queue: \(agent.output)")
        #expect(agent.diedOfTerm, "status \(agent.process.terminationStatus) reason \(agent.process.terminationReason.rawValue)")
    }

    @Test func ChatQuit_aTermWhileTheSweepOfAChildThatLeftOnItsOwnRunsWaitsForTheSweepAndTheAgentDiesOfTerm() async throws {
        let script = try filledScript("leaves.sh", ["@STUB@": builtTool("ClawdChatStub").path,
                                                    "@FIXTURES@": repository.appendingPathComponent("Tests/Fixtures/chat").path])
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                                 create: true).path
        let agent = try AgentRun(["--test-chat-quit", script, folder, "left"])
        let ready = try #require(await agent.line(startingWith: "CHATQUIT-READY"))
        let token = try #require(agent.field("token", in: ready))
        let child = try #require(agent.field("child", in: ready).flatMap { Int32($0) })
        var helper = 0
        for _ in 0..<150 where helper == 0 { helper = carrierCount(token); try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(helper >= 1, "the helper that ignores TERM is alive: \(ready)")
        // The child leaves by itself; from its reap on, the agent holds no live child, only the cleanup that follows.
        var gone = false
        for _ in 0..<250 where !gone { gone = !ChatProc.table().contains { $0.identity.pid == child }; if !gone { try await Task.sleep(nanoseconds: 20_000_000) } }
        #expect(gone, "the chat child left on its own")
        #expect(carrierCount(token) >= 1, "the helper still lives while its sweep is yet to end")
        #expect(Darwin.kill(agent.process.processIdentifier, SIGTERM) == 0)
        #expect(await agent.ended(within: 90), "the agent quit: \(agent.output)")
        #expect(agent.diedOfTerm, "died by SIGTERM, status \(agent.process.terminationStatus) reason \(agent.process.terminationReason.rawValue)")
        #expect(carrierCount(token) == 0, "no token process is left")
    }
}
