import Testing
import Foundation
import Darwin
import ClawdProcess
@testable import ClawdCore

/// The bytes a terminal child wrote, appended on the reader thread and read on the main one.
final class TermBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// Lines a seam saw on any thread (the channel observer), read on the main one.
final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    /// The `member` lines that name `pid`.
    func memberLines(of pid: Int32) -> [String] { all.filter { $0.hasPrefix("{\"member\"") && $0.contains("\"pid\":\(pid),") } }
}

/// What the master's close seam saw: descriptor, whether it was the reader thread, whether the wake descriptor ended the reader, and when.
final class TermCloses: @unchecked Sendable {
    struct Close { var descriptor: Int32; var onReader: Bool; var byWake: Bool; var at: UInt64 }
    private let lock = NSLock()
    private var all: [Close] = []
    func note(_ close: Close) { lock.lock(); all.append(close); lock.unlock() }
    var list: [Close] { lock.lock(); defer { lock.unlock() }; return all }
}

/// The stub in its terminal mode behind the real PTY spawn, the guard and a state file of its own. Everything a test starts is stopped by `finish`.
@MainActor
final class TermRig {
    let store: OwnState
    let state: ChatTermState
    let folder: String
    let bytes = TermBytes()
    let closes = TermCloses()
    var logs: [String] = []
    var exits: [(code: Int32?, signal: Int32?)] = []
    var stops: [(killed: Int, left: Int)] = []
    var guardLost = 0
    private(set) var children: [ChatTermChild] = []
    var config: ChatTermConfig

    static var stub: String { builtTool("ClawdChatStub").path }

    init(trackSeconds: TimeInterval = 1, agent: String? = nil, withState: Bool = true) throws {
        store = try artifactStore()
        state = ChatTermState(store: store)
        folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                              create: true).path
        config = ChatTermConfig(agent: agent ?? agentExecutable().path, state: withState ? state : nil)
        config.trackSeconds = trackSeconds
        let sink = bytes, record = closes
        config.onBytes = { sink.append($0) }
        config.masterCloseObserver = { descriptor, onReader, byWake in
            record.note(TermCloses.Close(descriptor: descriptor, onReader: onReader, byWake: byWake, at: DispatchTime.now().uptimeNanoseconds))
        }
    }

    func wire() {
        config.log = { [weak self] in self?.logs.append($0) }
        config.onExit = { [weak self] code, signal in self?.exits.append((code, signal)) }
        config.onStopped = { [weak self] killed, left in self?.stops.append((killed, left)) }
        config.onGuardLost = { [weak self] in self?.guardLost += 1 }
    }

    func launch(_ words: [String], token: String = UUID().uuidString.lowercased(), columns: Int = 80, rows: Int = 24, executable: String? = nil) -> ChatTermLaunch {
        ChatTermLaunch(executable: executable ?? Self.stub, arguments: words, environment: ChatTermLaunch.environment(ChatSettings(home: folder), token: token),
                       directory: folder, columns: columns, rows: rows, token: token)
    }

    @discardableResult
    func start(_ words: [String], token: String = UUID().uuidString.lowercased(), columns: Int = 80, rows: Int = 24) throws -> ChatTermChild {
        wire()
        let child = try ChatTermChild.start(launch(["tty"] + words, token: token, columns: columns, rows: rows), config: config)
        children.append(child)
        return child
    }

    var text: String { bytes.text }

    /// The stub's first report line as name -> value.
    func report() -> [String: String]? {
        guard let line = lines(prefix: "R ").first else { return nil }
        var result: [String: String] = [:]
        for part in line.dropFirst(2).split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { result[pair[0]] = pair[1] }
        }
        return result.count >= 10 ? result : nil
    }

    /// The complete lines (ended by CR LF) that start with `prefix`.
    func lines(prefix: String) -> [String] {
        var parts = text.components(separatedBy: "\r\n")
        parts.removeLast()
        return parts.filter { $0.hasPrefix(prefix) }
    }

    /// A real-time ceiling of 90 s or more: under the full suite the main queue is starved for tens of seconds.
    func wait(_ seconds: Double = 90, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func carriers(_ token: String) -> Int { ChatProc.carriers(of: token, in: ChatProc.table()).count }

    /// Hard-stops whatever a test left running and waits for the stops to end.
    func finish() async {
        for child in children where !child.hasEnded { child.stop(graceful: false, reason: nil) }
        _ = await wait(15) { children.allSatisfy { $0.hasEnded } }
    }
}

/// A file the stub appends to, read as lines.
func fileLines(_ path: String) -> [String] {
    ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

func processIsGone(_ identity: ProcessIdentity?) -> Bool {
    guard let identity else { return true }
    return ChatProc.identity(of: identity.pid) != identity
}

/// Descriptors of a process as (number, PROX_FDTYPE).
func descriptors(of pid: Int32) -> [(number: Int32, type: Int32)] {
    var numbers = [Int32](repeating: 0, count: 256), types = [Int32](repeating: 0, count: 256)
    let count = clawd_list_descriptors(pid, &numbers, &types, 256)
    return count < 0 ? [] : (0..<Int(count)).map { (numbers[$0], types[$0]) }
}
