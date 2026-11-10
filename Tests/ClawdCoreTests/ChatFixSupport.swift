import Testing
import Foundation
import Darwin
@testable import ClawdCore
import ClawdDesktop

// Fix round 1 of the chat slice: the agent's quit, the live snapshot of what a child started, a huge duration from the stream, and a send whose
// line was never written.

func fixStub(_ name: String) -> String {
    repository.appendingPathComponent("Tests/Fixtures/chat/stubs/" + name).path
}

/// A copy of the stub script `name` with `substitutions` filled in, written to a fresh folder.
func filledScript(_ name: String, _ substitutions: [String: String]) throws -> String {
    var text = try String(contentsOfFile: fixStub(name), encoding: .utf8)
    for (key, value) in substitutions { text = text.replacingOccurrences(of: key, with: value) }
    let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                             create: true)
    let path = folder.appendingPathComponent(name).path
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

/// The agent binary in a headless mode, watched by the test.
final class AgentRun {
    let process = Process()
    private let lock = NSLock()
    private var text = ""

    init(_ arguments: [String]) throws {
        process.executableURL = agentExecutable()
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "XPC_SERVICE_NAME")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }
            lock.lock(); text += String(decoding: data, as: UTF8.self); lock.unlock()
        }
        try process.run()
    }
    deinit { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }

    var output: String { lock.lock(); defer { lock.unlock() }; return text }
    func line(startingWith prefix: String, seconds: Double = 90) async -> String? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let found = output.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) { return String(found) }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }
    func field(_ name: String, in line: String) -> String? {
        line.split(separator: " ").first(where: { $0.hasPrefix(name + "=") }).map { String($0.dropFirst(name.count + 1)) }
    }
    /// Waits for the process to end; false when it outlives `seconds`.
    func ended(within seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if !process.isRunning { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return !process.isRunning
    }
    var diedOfTerm: Bool { !process.isRunning && process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM }
}

