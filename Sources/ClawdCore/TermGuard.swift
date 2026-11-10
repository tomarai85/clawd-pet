import Foundation
import Darwin
import ClawdProcess

/// The terminal guard (spec T-9, Interface Contract "The terminal guard"): `clawd-pet-agent --term-guard --agent-pid <p> --agent-start <sec>.<usec>
/// --token <uuid>`. A process of its own session that outlives the agent and stops claude and everything that carries the spawn token when the
/// agent dies without running any stop code. It blocks on its channel (descriptor 0) and on an event for the agent's exit, with no timer; it is
/// not an application, creates no application object, holds no descriptor of the agent's, and reads and writes no file.
///
/// Channel, one JSON object per line: `{"child":{...}}` once after claude's spawn, `{"member":{"pid":n,"startSec":n,"startUsec":n}}` for each
/// identity of the agent's sweep set other than claude (R9.12 item 1), `{"stop":{"deadlineNs":n}}` when the agent begins a stop,
/// `{"release":true}` when that stop (or the sweep after claude's reap) has ended. End-of-file, a line it cannot read, the agent's exit or an
/// agent already gone at the guard's start is the agent's death; before every stop of a death the guard drains the channel, so lines the agent
/// wrote before it died are read even when the exit event came first. Exit status: 0 after a release or after a death's stop with nothing left,
/// 1 after a death's stop with processes left, 2 bad arguments.
public enum TermGuard {
    struct Arguments { var agentPid: Int32; var startSeconds: UInt64; var startMicroseconds: UInt64; var token: String }

    static func parse(_ arguments: [String]) -> Arguments? {
        var pid: Int32?, start: (UInt64, UInt64)?, token: String?
        var rest = arguments[...]
        while let name = rest.popFirst() {
            guard let value = rest.popFirst() else { return nil }
            switch name {
            case "--agent-pid": pid = Int32(value)
            case "--agent-start":
                let parts = value.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count == 2, let sec = UInt64(parts[0]), let usec = UInt64(parts[1]) else { return nil }
                start = (sec, usec)
            case "--token": token = value.isEmpty ? nil : value
            default: return nil
            }
        }
        guard let pid, pid > 1, let start, let token else { return nil }
        return Arguments(agentPid: pid, startSeconds: start.0, startMicroseconds: start.1, token: token)
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    public static func run(_ arguments: [String]) -> Int32 {
        guard let parsed = parse(arguments) else { return 2 }
        let queue = clawd_kq_create()
        guard queue >= 0, clawd_kq_watch_read(queue, 0) == 0 else { return 2 }
        func agentIsTheSame() -> Bool {
            guard let live = ChatProc.identity(of: parsed.agentPid) else { return false }
            return live.seconds == parsed.startSeconds && live.microseconds == parsed.startMicroseconds
        }
        var childIdentity: ProcessIdentity?
        var childPid: Int32 = -1
        var stopDeadline: UInt64?
        var buffer = [UInt8]()
        var members = TermGuardMembers()

        /// True when the agent is dead (an unreadable line counts), nil to go on, and exits the process on a release.
        func handle(line: [UInt8]) -> Bool? {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return true }
            if object["release"] as? Bool == true { exit(0) }
            if let child = object["child"] as? [String: Any], let pid = (child["pid"] as? NSNumber)?.int32Value,
               let sec = (child["startSec"] as? NSNumber)?.uint64Value, let usec = (child["startUsec"] as? NSNumber)?.uint64Value {
                childPid = pid
                childIdentity = ChatProc.identity(of: pid).flatMap { $0.seconds == sec && $0.microseconds == usec ? $0 : nil }
                return nil
            }
            if let member = object["member"] as? [String: Any], let pid = (member["pid"] as? NSNumber)?.int32Value,
               let sec = (member["startSec"] as? NSNumber)?.uint64Value, let usec = (member["startUsec"] as? NSNumber)?.uint64Value {
                members.add(pid: pid, startSeconds: sec, startMicroseconds: usec)
                return nil
            }
            if let stop = object["stop"] as? [String: Any], let deadline = (stop["deadlineNs"] as? NSNumber)?.uint64Value {
                stopDeadline = stopDeadline.map { min($0, deadline) } ?? deadline
                return nil
            }
            return true
        }

        // The agent's exit is watched before the first read; an agent that is already gone (or whose pid now names another process) is the death.
        var dead = clawd_kq_watch_exit(queue, parsed.agentPid) != 0 || !agentIsTheSame()
        while !dead {
            var kind: Int32 = 0, ident: Int32 = 0
            guard clawd_kq_wait(queue, &kind, &ident) == 0 else { dead = true; break }
            if kind == 2 { dead = true; break }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(0, &chunk, chunk.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            if count <= 0 { dead = true; break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A), !dead {
                let line = Array(buffer[0..<newline])
                buffer.removeSubrange(0...newline)
                if line.isEmpty { continue }
                if handle(line: line) == true { dead = true }
            }
        }
        /// Reads descriptor 0 without blocking until EAGAIN or end of file and handles every complete line as the loop would (a member line is
        /// checked and kept, a child or stop line taken, a release ends the guard); an unreadable line is skipped, the death being seen already.
        func drainChannel() {
            func handleBuffered() {
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Array(buffer[0..<newline])
                    buffer.removeSubrange(0...newline)
                    if !line.isEmpty { _ = handle(line: line) }
                }
            }
            handleBuffered()                       // lines the loop left behind when an unreadable one ended it
            _ = fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK)
            while true {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = read(0, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return }
                buffer.append(contentsOf: chunk[0..<count])
                handleBuffered()
            }
        }

        // The death is seen. Lines the agent wrote before it died may still be in the pipe (the exit event can come first): read them all
        // before stopping. T0 stays the moment the death was seen, so the drain counts inside the 3 s.
        let seen = now()
        drainChannel()
        return stop(after: parsed.token, childPid: childPid, childIdentity: childIdentity, stopDeadline: stopDeadline, members: members.identities, seen: seen)
    }

    /// The hard stop of the death: T0 = the moment the death was seen minus 100 ms; D = T0 + 3 s, or the earlier D of a stop line the agent sent
    /// before dying. Its set is the slice's sweep set, read fresh. Before D - 1 s: SIGTERM now and the kill step at D - 1 s; from D - 1 s on, the
    /// kill step at once; the check at D.
    static func stop(after token: String, childPid: Int32, childIdentity: ProcessIdentity?, stopDeadline: UInt64?,
                     members: [ProcessIdentity] = [], seen seenAt: UInt64? = nil) -> Int32 {
        let seen = seenAt ?? now()
        let t0 = seen > 100_000_000 ? seen - 100_000_000 : seen
        let deadline = min(stopDeadline ?? UInt64.max, t0 + 3_000_000_000)
        let killAt = deadline > 1_000_000_000 ? deadline - 1_000_000_000 : deadline
        let set = ChatSweepSet(token: token, pid: childPid, identity: childIdentity)
        set.seed(members)
        func send(_ number: Int32) { for id in set.grow(.fresh) { ChatProc.signal(id, number) } }
        if now() < killAt {
            send(SIGTERM)
            while now() < killAt {
                usleep(50_000)
                if set.grow(.fresh).isEmpty { return 0 }
            }
        }
        send(SIGKILL)
        while now() < deadline {
            usleep(50_000)
            if set.grow(.fresh).isEmpty { return 0 }
            send(SIGKILL)
        }
        return set.grow(.fresh).isEmpty ? 0 : 1
    }
}

/// The members the agent sent (R9.12 item 1.3), kept by identity. A line is checked at arrival (the pid has that start time and is the user's)
/// and dropped when it does not match. No timer: the list is pruned on arrival, when it holds twice the count it kept at its last prune and at
/// least 256 entries, so it never holds more than max(256, twice the count kept at the last prune).
struct TermGuardMembers {
    private(set) var identities: [ProcessIdentity] = []
    /// The count the last prune kept.
    private(set) var keptAtLastPrune = 0
    private let identityOf: (Int32) -> ProcessIdentity?

    init(identityOf: @escaping (Int32) -> ProcessIdentity? = { ChatProc.identity(of: $0) }) { self.identityOf = identityOf }

    mutating func add(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        guard pid > 1, let live = identityOf(pid), live.uid == getuid(), live.seconds == startSeconds, live.microseconds == startMicroseconds else { return }
        guard !identities.contains(live) else { return }
        identities.append(live)
        if identities.count >= max(256, 2 * keptAtLastPrune) {
            identities = identities.filter { identityOf($0.pid) == $0 }
            keptAtLastPrune = identities.count
        }
    }
}
