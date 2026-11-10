import Testing
import Foundation
import ClawdCore
import ClawdDesktop

// agent.log's one policy (amendment agent-log-retention): every append through OwnState, under any name that resolves to agent.log, rotates
// to agent.log.1 before an append that would take the file past 3 MiB and cuts one line to 64 KiB; the headless modes have one named way
// around it; agent.log is never written whole.

private func fill(_ store: OwnState, _ name: String, bytes: Int) throws {
    #expect(FileManager.default.createFile(atPath: try store.url(name).path, contents: Data(repeating: 0x78, count: bytes)))
}
private func size(_ store: OwnState, _ name: String) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: try store.url(name).path)[.size] as? Int) ?? -1
}
private func exists(_ store: OwnState, _ name: String) throws -> Bool { FileManager.default.fileExists(atPath: try store.url(name).path) }

@Suite("Agent log policy")
struct AgentLogSuite {
    @Test func AgentLog_limitsAreThreeMebibytesAndSixtyFourKibibytes() {
        #expect(OwnState.agentLogLimit == 3_145_728)
        #expect(OwnState.agentLogLineLimit == 65_536)
        #expect(OwnState.agentLogName == "agent.log")
    }

    @Test func AgentLog_rotatesBeforeAnAppendThatWouldPassTheLimit() throws {
        let line = String(repeating: "y", count: 19) + "\n"                      // 20 bytes
        // Ten bytes short of the limit: the line does not fit, so the file moves to agent.log.1 unchanged and agent.log holds the line alone.
        let a = try artifactStore()
        try fill(a, "agent.log", bytes: OwnState.agentLogLimit - 10)
        try a.append(line, to: "agent.log")
        #expect(try size(a, "agent.log.1") == OwnState.agentLogLimit - 10)
        #expect(try ReadOnlyFile.data(try a.url("agent.log").path) == Data(line.utf8))
        // Thirty bytes short: the line fits and nothing rotates.
        let b = try artifactStore()
        try fill(b, "agent.log", bytes: OwnState.agentLogLimit - 30)
        try b.append(line, to: "agent.log")
        #expect(try !exists(b, "agent.log.1")); #expect(try size(b, "agent.log") == OwnState.agentLogLimit - 10)
        // 600 KiB is far below the limit (the old 512 KiB rule rotated there).
        let c = try artifactStore()
        try fill(c, "agent.log", bytes: 600 * 1024)
        try c.append(line, to: "agent.log")
        #expect(try !exists(c, "agent.log.1")); #expect(try size(c, "agent.log") == 600 * 1024 + 20)
        // An empty file takes a line of any size up to the cut.
        let d = try artifactStore()
        try fill(d, "agent.log", bytes: 0)
        try d.append(String(repeating: "z", count: 60_000) + "\n", to: "agent.log")
        #expect(try !exists(d, "agent.log.1")); #expect(try size(d, "agent.log") == 60_001)
    }

    @Test func AgentLog_aLongLineIsCutAtAScalarBoundaryAndMarked() throws {
        for unit in ["a", "é", "😀"] {
            let store = try artifactStore()
            let text = String(repeating: unit, count: 100 * 1024 / unit.utf8.count) + "\n"
            try store.append(text, to: "agent.log")
            let written = try ReadOnlyFile.data(try store.url("agent.log").path)
            #expect(written.count <= OwnState.agentLogLineLimit, "\(unit): \(written.count) bytes")
            let decoded = try #require(String(data: written, encoding: .utf8), "\(unit): the cut line is valid UTF-8")
            #expect(decoded.hasSuffix(OwnState.agentLogCutMarker), "\(unit)")
            #expect(decoded.dropLast(OwnState.agentLogCutMarker.count).allSatisfy { String($0) == unit }, "\(unit): only whole characters are kept")
            #expect(written.count > OwnState.agentLogLineLimit - OwnState.agentLogCutMarker.utf8.count - unit.utf8.count, "\(unit): the cut keeps as much as fits")
        }
        // A line that fits is written as it is.
        let store = try artifactStore()
        try store.append("STATE scene=idle\n", to: "agent.log")
        #expect(try ReadOnlyFile.data(try store.url("agent.log").path) == Data("STATE scene=idle\n".utf8))
    }

    @Test func AgentLog_everyAppendToAgentLogFollowsThePolicy() throws {
        let name = ["agent", "log"].joined(separator: ".")                         // the path in a variable, built at run time
        let line = "x\n"
        for (route, write) in [("append", { (s: OwnState) in try s.append(line, to: name) }),
                               ("appendRaw", { (s: OwnState) in try s.appendRaw(Data(line.utf8), to: "./" + name) }),
                               ("appendRotating", { (s: OwnState) in try s.appendRotating(line, to: name, limit: 512 * 1024) })] {
            let below = try artifactStore()
            try fill(below, "agent.log", bytes: 600 * 1024)
            try write(below)
            #expect(try !exists(below, "agent.log.1"), "\(route): 600 KiB is under the agent log's limit, whatever limit is passed")
            let at = try artifactStore()
            try fill(at, "agent.log", bytes: OwnState.agentLogLimit)
            try write(at)
            #expect(try size(at, "agent.log.1") == OwnState.agentLogLimit, "\(route): a full agent.log rotates before the line")
            #expect(try size(at, "agent.log") == 2, "\(route)")
        }
    }

    @Test func AgentLog_theUnmanagedExceptionKeepsItsOwnRule() throws {
        let plain = try artifactStore()
        try fill(plain, "agent.log", bytes: OwnState.agentLogLimit)
        try plain.appendAgentLogUnmanaged("x\n", rotatingAt: nil)
        #expect(try !exists(plain, "agent.log.1")); #expect(try size(plain, "agent.log") == OwnState.agentLogLimit + 2)
        let own = try artifactStore()
        try fill(own, "agent.log", bytes: 600 * 1024)
        try own.appendAgentLogUnmanaged("x\n", rotatingAt: 512 * 1024)
        #expect(try size(own, "agent.log.1") == 600 * 1024); #expect(try size(own, "agent.log") == 2)
    }

    @Test func AgentLog_aWholeFileWriteOfAgentLogIsRefused() throws {
        let store = try artifactStore()
        try store.append("kept\n", to: "agent.log")
        #expect(throws: (any Error).self) { try store.write(Data("replaced\n".utf8), to: "agent.log") }
        #expect(throws: (any Error).self) { try store.writeJSON(["a": 1], to: "./agent.log") }
        #expect(try ReadOnlyFile.data(try store.url("agent.log").path) == Data("kept\n".utf8))
        try store.write(Data("other\n".utf8), to: "other.log")                    // any other file is written as before
    }

    /// Every OwnState writer other than the policy and its named exception refuses agent.log and agent.log.1, under any spelling that resolves
    /// to them (the user's volume is case-insensitive); an append to agent.log follows the policy under every spelling, one to agent.log.1 is refused.
    @Test func AgentLog_everyOtherWriterRefusesTheAgentLogsUnderAnySpelling() throws {
        let liveNames = ["agent.log", "./agent.log", "AGENT.LOG", "Agent.Log"]
        let oldNames = ["agent.log.1", "AGENT.LOG.1"]
        for name in liveNames + oldNames {
            let store = try artifactStore()
            try fill(store, "agent.log", bytes: 10); try fill(store, "agent.log.1", bytes: 10)
            try store.append("o\n", to: "other.log")
            let refusals: [(String, () throws -> Void)] = [
                ("write", { try store.write(Data("x".utf8), to: name) }),
                ("writeJSON", { try store.writeJSON(["a": 1], to: name) }),
                ("appendLedger", { try store.appendLedger("x\n", to: name) }),
                ("rewriteInPlace", { try store.rewriteInPlace(Data("x".utf8), to: name) }),
                ("rename from", { try store.rename(name, to: "moved.log") }),
                ("rename to", { try store.rename("other.log", to: name) }),
                ("counter", { _ = try store.counter(name) }),
            ]
            for (what, call) in refusals { #expect(throws: (any Error).self, "\(what) \(name)") { try call() } }
            #expect(try size(store, "agent.log") == 10, "\(name): agent.log unchanged")
            #expect(try size(store, "agent.log.1") == 10, "\(name): agent.log.1 unchanged")
        }
        for name in oldNames {
            let store = try artifactStore()
            #expect(throws: (any Error).self, "append \(name)") { try store.append("x\n", to: name) }
            #expect(throws: (any Error).self, "appendRotating \(name)") { try store.appendRotating("x\n", to: name, limit: 512 * 1024) }
        }
        for name in liveNames {
            let store = try artifactStore()
            try fill(store, "agent.log", bytes: OwnState.agentLogLimit)
            try store.append("x\n", to: name)
            #expect(try size(store, "agent.log.1") == OwnState.agentLogLimit, "\(name): a full agent.log rotates before the line")
            #expect(try size(store, "agent.log") == 2, "\(name)")
        }
    }

    @Test func AgentLog_theLedgerAppendRefusesAgentLog() throws {
        let store = try artifactStore()
        let name = ["agent", "log"].joined(separator: ".")
        try store.append("kept\n", to: name)
        #expect(throws: LedgerFailure.write(EPERM)) { try store.appendLedger("ledger line\n", to: name) }
        #expect(try ReadOnlyFile.data(try store.url("agent.log").path) == Data("kept\n".utf8))
    }

    /// The exception API has exactly two callers, the headless measurement modes; any other production writer of agent.log goes through the
    /// policy (every OwnState append to agent.log does).
    @Test func AgentLog_theUnmanagedAPIIsUsedOnlyByTheHeadlessModes() throws {
        let sources = repository.appendingPathComponent("Sources")
        var calls: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension == "swift" {
            let text = String(decoding: try ReadOnlyFile.data(file.path), as: UTF8.self)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("appendAgentLogUnmanaged(") && !line.contains("func appendAgentLogUnmanaged(") {
                calls.append("\(file.lastPathComponent):\(n + 1)")
            }
        }
        #expect(calls.count == 2 && calls.allSatisfy { $0.hasPrefix("HeadlessModes.swift:") }, "\(calls)")
    }

    @MainActor @Test func AgentLog_theFocusMonitorWritesThroughThePolicy() throws {
        let store = try artifactStore()
        try fill(store, "agent.log", bytes: OwnState.agentLogLimit - 5)
        let monitor = FocusMonitor(store: store, center: NotificationCenter())
        monitor.log("STATE scene=idle")
        #expect(try size(store, "agent.log.1") == OwnState.agentLogLimit - 5, "a full agent.log rotates before the monitor's line")
        let text = String(decoding: try ReadOnlyFile.data(try store.url("agent.log").path), as: UTF8.self)
        #expect(text.hasSuffix(" STATE scene=idle\n") && text.split(separator: "\n").count == 1, "\(text)")
        // 600 KiB: the old 512 KiB rule would have rotated here.
        let below = try artifactStore()
        try fill(below, "agent.log", bytes: 600 * 1024)
        FocusMonitor(store: below, center: NotificationCenter()).log("STATE scene=idle")
        #expect(try !exists(below, "agent.log.1"))
    }
}
