import Testing
import Foundation
@testable import ClawdCore

private func stub(_ name: String) -> String {
    repository.appendingPathComponent("Tests/Fixtures/chat/stubs/" + name).path
}

/// grandchild.sh with the helper's and the fixtures' paths filled in, written to a fresh folder. The helper is a non-platform binary: the system
/// tools hide their environment from the kernel's argument query, so only a process like this one can be found by the spawn token.
private func detachedGrandchildScript() throws -> String {
    let template = try String(contentsOfFile: stub("grandchild.sh"), encoding: .utf8)
    let text = template.replacingOccurrences(of: "@STUB@", with: builtTool("ClawdChatStub").path)
        .replacingOccurrences(of: "@FIXTURES@", with: repository.appendingPathComponent("Tests/Fixtures/chat").path)
    let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                             create: true)
    let path = folder.appendingPathComponent("grandchild.sh").path
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

/// A timer source the test fires by hand.
final class ManualChatTimers: ChatTimers {
    final class Handle: ChatTimerHandle {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    private(set) var pending: [(delay: TimeInterval, handle: Handle, block: () -> Void)] = []
    func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) -> ChatTimerHandle {
        let handle = Handle()
        pending.append((seconds, handle, block))
        return handle
    }
    var live: [TimeInterval] { pending.filter { !$0.handle.cancelled }.map(\.delay) }
    /// Fires the live timers whose delay is exactly `delay`.
    func fire(exactly delay: TimeInterval) {
        let due = pending.filter { !$0.handle.cancelled && $0.delay == delay }
        pending.removeAll { entry in due.contains { $0.handle === entry.handle } }
        for entry in due { entry.block() }
    }
    /// Fires every live timer whose delay is at least `delay`.
    func fire(atLeast delay: TimeInterval) {
        let due = pending.filter { !$0.handle.cancelled && $0.delay >= delay }
        pending.removeAll { entry in due.contains { $0.handle === entry.handle } }
        for entry in due { entry.block() }
    }
}

@MainActor
final class ChatRig {
    let session: ChatSession
    let timers = ManualChatTimers()
    let folder: String
    var logs: [String] = []
    var outcomes: [ChatTurnOutcome] = []
    var started = 0
    var changes = 0

    /// `search`: no `chatClaude` is set and the Q6 search looks in these folders (stubbed ones) instead.
    init(stub name: String, claude: String? = nil, search: [String]? = nil, permissions: ChatPermissions = .bypass, configure: (inout ChatSessionConfig) -> Void = { _ in }) throws {
        folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                              create: true).path
        let claudePath = claude ?? stub(name)
        let directory = folder
        var config = ChatSessionConfig(settings: {
            var settings = ChatSettings(home: directory)
            if let search { settings.claudeSearch = search } else { settings.claude = claudePath }
            settings.folder = directory
            settings.permissions = permissions
            return settings
        })
        let box = LogBox()
        config.log = { box.lines.append($0) }
        config.timers = timers
        configure(&config)
        session = ChatSession(config: config, timeZone: TimeZone(identifier: "UTC")!)
        logBox = box
        session.onChange = { [unowned self] in changes += 1 }
        session.onTurnStarted = { [unowned self] in started += 1 }
        session.onTurnEnded = { [unowned self] in outcomes.append($0) }
    }
    final class LogBox { var lines: [String] = [] }
    private var logBox: LogBox!
    var log: [String] { logBox.lines }

    /// A real-time ceiling on a main-queue delivery is 90 s or more: under the full suite the main queue is starved for tens of seconds.
    func wait(_ seconds: Double = 90, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
    func carriers() -> Int {
        guard let token = session.lastToken else { return 0 }
        return ChatProc.carriers(of: token, in: ChatProc.table()).count
    }
    var spawns: Int { log.filter { $0.hasPrefix("CHAT spawn ") }.count }
    /// Whether the newest child's pid is still a process (it is reaped by the bridge, so a gone child is gone).
    var childAlive: Bool {
        guard let line = log.last(where: { $0.hasPrefix("CHAT spawn pid=") }), let pid = Int32(line.dropFirst("CHAT spawn pid=".count).prefix { $0 != " " }) else { return false }
        return ChatProc.identity(of: pid) != nil
    }
    var texts: [String] { session.transcript.entries.map(\.text) }
}

@MainActor
struct ChatSessionTests {
    @Test func ChatSession_settingsAreReadEachKeyOnItsOwn() {
        let defaults = ChatSettings(home: "/Users/example")
        #expect(defaults.enabled && defaults.permissions == .deny && defaults.model == nil)
        #expect(defaults.claude == "/Users/example/.local/bin/claude" && defaults.folder == "/Users/example")
        #expect(defaults.path.hasPrefix("/Users/example/.local/bin:/Users/example/bin:/opt/homebrew/bin"))
        let mixed = ChatSettings(object: ["chat": false, "chatClaude": "relative/claude", "chatFolder": "~/work", "chatPermissions": "ask",
                                          "chatModel": "opus-4.5[1m]", "chatPath": "/usr/bin:/bin"], home: "/Users/example")
        #expect(!mixed.enabled)
        #expect(mixed.claude == defaults.claude)
        #expect(mixed.folder == "/Users/example/work")
        #expect(mixed.permissions == .deny)
        #expect(mixed.model == "opus-4.5[1m]")
        #expect(mixed.path == "/usr/bin:/bin")
        let wrong = ChatSettings(object: ["chat": "yes", "chatModel": "bad model!", "chatPath": "usr/bin", "chatPermissions": 3, "chatFolder": ""], home: "/Users/example")
        #expect(wrong == defaults)
        #expect(ChatSettings(object: ["chatPermissions": "bypass"], home: "/h").permissions == .bypass)
        #expect(ChatPermissions.bypass.arguments == ["--permission-mode", "bypassPermissions", "--permission-prompts", "none"])
    }

    @Test func ChatSession_theEnvironmentIsBuiltFromScratch() {
        let env = ChatSession.environment(ChatSettings(home: "/Users/example"), token: "tok")
        #expect(env["CLAWD_CHAT"] == "1" && env[ChatProc.tokenVariable] == "tok")
        #expect(Set(env.keys).isSubset(of: ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "PATH", "CLAWD_CHAT", "CLAWD_CHAT_SPAWN",
                                                 "CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"]))
        #expect(env["CLAUDECODE"] == nil && env["XPC_SERVICE_NAME"] == nil)
    }

    @Test func ChatSession_twoTurnsOverOneChild() async throws {
        let rig = try ChatRig(stub: "replay.sh")
        #expect(rig.session.send("Reply with the word ok"))
        #expect(rig.session.turn == .running)
        #expect(!rig.session.send("a second message while the first runs"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        guard rig.outcomes.count >= 1, case .success = rig.outcomes[0] else { Issue.record("first turn: \(rig.outcomes)"); return }
        #expect(rig.session.turn == .none)
        #expect(rig.session.send("Create hello.txt containing hi, then say done"))
        #expect(await rig.wait { rig.outcomes.count == 2 })
        guard rig.outcomes.count >= 2, case .success = rig.outcomes[1] else { Issue.record("second turn: \(rig.outcomes)"); return }
        #expect(rig.started == 2)
        #expect(rig.spawns == 1)
        #expect(rig.log.contains { $0.hasPrefix("CHAT send turn=1 chars=22") })
        #expect(rig.log.contains { $0.hasPrefix("CHAT turn end turn=2 outcome=success") })
        #expect(rig.log.contains { $0.contains("permissions=bypass") && $0.contains("mode=fresh") })
        #expect(rig.session.transcript.entries.filter { $0.kind == .user }.map(\.text) == ["Reply with the word ok", "Create hello.txt containing hi, then say done"])
        #expect(rig.session.transcript.entries.contains { $0.kind == .footer })
        #expect(rig.log.allSatisfy { !$0.contains("hello.txt") && !$0.contains(rig.folder) })
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none && rig.log.contains { $0.hasPrefix("CHAT sweep") } })
        #expect(rig.carriers() == 0)
    }

    @Test func ChatSession_blankTextIsIgnored() throws {
        let rig = try ChatRig(stub: "replay.sh")
        #expect(!rig.session.send(""))
        #expect(!rig.session.send("  \n\t "))
        #expect(rig.spawns == 0 && rig.session.turn == .none)
    }

    @Test func ChatSession_aChildThatDiesMidTurnEndsTheTurnAsAnErrorAndIsNotRespawned() async throws {
        let rig = try ChatRig(stub: "crash.sh")
        #expect(rig.session.send("hello"))
        #expect(await rig.wait { rig.outcomes.count == 1 && rig.session.turn == .none })
        #expect(rig.outcomes == [.error])
        let errors = rig.session.transcript.entries.filter { $0.kind == .error }.map(\.text)
        #expect(errors == ["Claude Code stopped (exit 3)"])
        #expect(rig.session.transcript.entries.contains { $0.kind == .notice && $0.text == "first stderr line\nsecond stderr line" })
        #expect(rig.log.contains { $0.hasPrefix("CHAT exit ") && $0.contains("code=3") && $0.hasSuffix("during=turn") })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig.spawns == 1)
        #expect(rig.session.send("again"))
        #expect(await rig.wait { rig.spawns == 2 })
        #expect(await rig.wait { rig.outcomes.count == 2 })
    }

    @Test func ChatSession_aMissingBinaryIsRefusedWithoutASpawn() throws {
        let rig = try ChatRig(stub: "replay.sh", claude: "/private/tmp/clawd-no-such-claude")
        #expect(!rig.session.send("hello"))
        #expect(rig.log == ["CHAT refuse reason=missing-binary"])
        #expect(rig.session.transcript.entries.map(\.kind) == [.error])
        #expect(rig.session.transcript.entries.first?.text.contains("Claude Code was not found") == true)
        #expect(rig.session.turn == .none && rig.started == 0)
        let notExecutable = try ChatRig(stub: "replay.sh", claude: "/private/tmp")
        #expect(!notExecutable.session.send("hello"))
        #expect(notExecutable.log == ["CHAT refuse reason=missing-binary"])
    }

    @Test func ChatSession_aMissingFolderIsRefused() throws {
        let rig = try ChatRig(stub: "replay.sh")
        let folder = rig.folder + "/gone"
        let session = ChatSession(config: ChatSessionConfig(settings: {
            var s = ChatSettings(home: rig.folder); s.claude = stub("replay.sh"); s.folder = folder; return s
        }, log: { _ in }, timers: rig.timers))
        #expect(!session.send("hello"))
        #expect(session.transcript.entries.first?.text.contains("does not exist") == true)
    }

    @Test func ChatSession_interruptEndsTheTurnWhenTheChildAnswers() async throws {
        let rig = try ChatRig(stub: "interrupt-ok.sh")
        #expect(rig.session.send("work"))
        #expect(await rig.wait { rig.session.transcript.sessionId != nil })
        rig.session.interrupt()
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(rig.outcomes == [.interrupted])
        #expect(rig.session.turn == .none)
        #expect(rig.log.contains { $0.hasPrefix("CHAT turn end turn=1 outcome=interrupted") })
        #expect(rig.childAlive)                                       // the child was kept, not stopped
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.log.contains { $0.hasPrefix("CHAT sweep") } })
        #expect(rig.carriers() == 0)
    }

    @Test func ChatSession_interruptFallsBackToAHardStopAfterTheGrace() async throws {
        let rig = try ChatRig(stub: "interrupt-deaf.sh")
        #expect(rig.session.send("work"))
        try await Task.sleep(nanoseconds: 300_000_000)
        rig.session.interrupt()
        #expect(rig.timers.live == [5])
        rig.timers.fire(atLeast: 5)
        #expect(rig.outcomes == [.interrupted])
        #expect(rig.session.turn == .stopping)
        #expect(!rig.session.send("too early"))
        #expect(await rig.wait { rig.session.turn == .none && rig.log.contains { $0.hasPrefix("CHAT sweep") } })
        #expect(rig.log.contains("CHAT sweep n=\(rig.log.compactMap { $0.hasPrefix("CHAT sweep n=") ? $0 : nil }.first.flatMap { Int($0.split(separator: " ")[2].dropFirst(2)) } ?? -1) left=0"))
        #expect(rig.carriers() == 0)
    }

    @Test func ChatSession_aGracefulStopLeavesNoTokenProcessAndNeverNeedsASignalWhenStdinCloses() async throws {
        let rig = try ChatRig(stub: "replay.sh")
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        rig.session.stop(.userStop)
        #expect(rig.session.turn == .stopping)
        #expect(await rig.wait { rig.session.turn == .none })        // no real-time bound: the full suite starves the main queue for seconds
        #expect(rig.log.contains { $0.hasPrefix("CHAT exit ") && $0.contains("code=0 signal=none") })   // claude left on the closed stdin: no SIGTERM was needed
        #expect(rig.log.contains("CHAT stop reason=userStop"))
        #expect(rig.log.contains { $0.hasPrefix("CHAT sweep n=") && $0.hasSuffix("left=0") })
        #expect(rig.carriers() == 0)
    }

    @Test func ChatSession_aGracefulStopKillsADetachedGrandchildByTheToken() async throws {
        let rig = try ChatRig(stub: "grandchild.sh", claude: try detachedGrandchildScript())
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig.carriers() == 1)                                   // the detached helper (the stub shell hides its environment)
        let detached = rig.carriers()
        rig.session.stop(.panelClosedLong)
        #expect(await rig.wait { rig.session.turn == .none })
        #expect(rig.carriers() == 0 && !rig.childAlive)
        #expect(rig.log.contains { $0.hasPrefix("CHAT sweep n=") && $0.hasSuffix("left=0") })
        #expect(detached == 1)
    }

    @Test func ChatSession_aHardStopKillsADetachedGrandchildByTheToken() async throws {
        let rig = try ChatRig(stub: "grandchild.sh", claude: try detachedGrandchildScript())
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig.carriers() == 1)
        rig.session.stop(.exam)
        #expect(await rig.wait { rig.session.turn == .none })
        #expect(rig.carriers() == 0)
        #expect(rig.log.contains("CHAT stop reason=exam"))
        #expect(rig.log.contains { $0.hasPrefix("CHAT sweep n=") && $0.hasSuffix("left=0") })
    }

    @Test func ChatSession_theIdleExitStopsTheChildAndTheNextSendResumes() async throws {
        let rig = try ChatRig(stub: "replay.sh")
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(rig.timers.live == [600])
        #expect(rig.childAlive)
        rig.timers.fire(atLeast: 600)
        #expect(await rig.wait { rig.session.turn == .none && rig.log.contains { $0.hasPrefix("CHAT sweep") } })
        #expect(rig.log.contains("CHAT stop reason=idle"))
        #expect(rig.carriers() == 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(rig.spawns == 1)                                      // never respawned without a send
        #expect(rig.timers.live.isEmpty)
        #expect(rig.session.send("two"))
        #expect(rig.log.last { $0.hasPrefix("CHAT spawn ") }?.contains("mode=resume") == true)
        rig.session.stop(.agentQuit)
        #expect(await rig.wait { rig.session.turn == .none })
        #expect(rig.carriers() == 0)
    }

    @Test func ChatSession_theIdleStopReportsTheLossSoTheQueueCanPause() async throws {
        let rig = try ChatRig(stub: "replay.sh")
        var lost: [ChatChildLoss] = []
        rig.session.onChildLost = { lost.append($0) }
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(lost.isEmpty)
        rig.timers.fire(atLeast: 600)
        #expect(lost == [.idle], "\(lost)")
        #expect(await rig.wait { rig.session.turn == .none && rig.log.contains { $0.hasPrefix("CHAT sweep") } })
    }

    @Test func ChatSession_aSendCancelsTheIdleTimer() async throws {
        let rig = try ChatRig(stub: "replay.sh")
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(rig.timers.live == [600])
        #expect(rig.session.send("two"))
        #expect(rig.timers.live.isEmpty)
        rig.session.stop(.agentQuit)
        #expect(await rig.wait { rig.session.turn == .none })
    }

    @Test func ChatSession_everyControlRequestIsAnsweredWithTheErrorResponse() async throws {
        let rig = try ChatRig(stub: "control.sh")
        #expect(rig.session.send("hello"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none })
        let answers = try String(contentsOfFile: rig.folder + "/control-answers.txt", encoding: .utf8)
        let line = try #require(answers.split(separator: "\n").first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let response = try #require(object["response"] as? [String: Any])
        #expect(object["type"] as? String == "control_response")
        #expect(response["subtype"] as? String == "error" && response["request_id"] as? String == "req-1")
        #expect(response["error"] as? String == "not supported by Clawd")
    }

    @Test func ChatSession_aLineOverTheCapIsSkippedToItsNewline() async throws {
        let rig = try ChatRig(stub: "hugeline.sh") { $0.maxLineBytes = 64 * 1024 }
        #expect(rig.session.send("hello"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(rig.session.transcript.entries.contains { $0.kind == .notice && $0.text == "A very long line from Claude Code was skipped" })
        #expect(rig.session.transcript.entries.contains { $0.text == "after the long line" })
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none })
    }

    @Test func ChatSession_updatesAreBatchedAtMostOncePer50ms() async throws {
        let rig = try ChatRig(stub: "burst.sh")
        let began = Date()
        #expect(rig.session.send("go"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        let seconds = Date().timeIntervalSince(began)
        #expect(rig.session.transcript.entries.contains { $0.kind == .assistant && $0.text == String(repeating: "x", count: 3000) })
        #expect(Double(rig.changes) <= seconds / 0.05 + 4)
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none })
    }

    @Test func ChatSession_aSendIsRefusedWhileStopping() async throws {
        let rig = try ChatRig(stub: "replay.sh")
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        rig.session.stop(.userStop)
        #expect(!rig.session.send("two"))
        #expect(await rig.wait { rig.session.turn == .none })
        #expect(rig.session.send("two"))
        rig.session.stop(.agentQuit)
        #expect(await rig.wait { rig.session.turn == .none })
    }

    @Test func ChatSession_stopAndWaitReturnsAfterTheSweep() async throws {
        let rig = try ChatRig(stub: "grandchild.sh", claude: try detachedGrandchildScript())
        #expect(rig.session.send("one"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        try await Task.sleep(nanoseconds: 300_000_000)
        rig.session.stopAndWait(.agentQuit)
        #expect(rig.carriers() == 0)
    }
}

struct ChatHandoffTests {
    private func delta(_ text: String, block: Int = 0) -> ChatEvent { .textDelta(messageKey: "m", blockIndex: block, text: text) }

    @Test func ChatHandoff_consecutiveDeltasOfOneBlockBecomeOne() {
        let handoff = ChatHandoff()
        handoff.push(delta("a")); handoff.push(delta("b")); handoff.push(delta("c", block: 1)); handoff.push(.toolProgress(id: "t", seconds: 1))
        handoff.push(.toolProgress(id: "t", seconds: 2))
        #expect(handoff.take() == [.event(delta("ab")), .event(delta("c", block: 1)), .event(.toolProgress(id: "t", seconds: 2))])
        #expect(handoff.take().isEmpty)
    }

    @Test func ChatHandoff_droppableEventsPastTheCapBecomeOneBacklogAndTheRestIsKept() {
        let handoff = ChatHandoff()
        handoff.push(.initialized(sessionId: "s", model: "m", permissionMode: "p", version: "v"))
        let big = String(repeating: "x", count: 1024 * 1024)
        for index in 0..<8 { handoff.push(delta(big, block: index)) }
        handoff.push(.toolStarted(id: "t", name: "Bash"))
        handoff.push(delta("late", block: 99))
        handoff.push(.result(outcome: .success, durationMs: 1, totalCost: 0, sessionId: "s", text: ""))
        handoff.push(.ignored(type: "result/unknown"))
        handoff.push(.ignored(type: "something"))
        let items = handoff.take()
        #expect(items.filter { $0 == .backlog }.count == 1)
        #expect(items.contains(.event(.toolStarted(id: "t", name: "Bash"))))
        #expect(items.contains(.event(.ignored(type: "result/unknown"))))
        #expect(items.contains { if case .event(.result) = $0 { return true } else { return false } })
        #expect(!items.contains(.event(delta("late", block: 99))))
        #expect(items.first == .event(.initialized(sessionId: "s", model: "m", permissionMode: "p", version: "v")))
        handoff.push(delta(big)); handoff.push(.toolProgress(id: "t", seconds: 1))
        #expect(handoff.take().count == 2)                               // a new episode after the main queue took everything
    }

    @Test func ChatHandoff_overTheHardCapOneOverflowStandsAndOnlyBridgeItemsFollow() {
        let handoff = ChatHandoff()
        for index in 0..<ChatHandoff.hardEvents { handoff.push(.toolStarted(id: "t\(index)", name: "x")) }
        handoff.push(.toolStarted(id: "extra", name: "x"))
        handoff.push(.toolStarted(id: "more", name: "x"))
        handoff.push(bridge: .exited(code: 0, signal: nil, stderrTail: []))
        let items = handoff.take()
        #expect(items.filter { $0 == .overflow }.count == 1)
        #expect(items.last == .exited(code: 0, signal: nil, stderrTail: []))
        #expect(!items.contains(.event(.toolStarted(id: "extra", name: "x"))))
    }
}
