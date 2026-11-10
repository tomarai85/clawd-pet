import Foundation
import Darwin
import ClawdProcess

/// The start sweep of the terminal path (spec T-9): at every agent start, in main.swift after the single-instance lock and before
/// `AgentBoot.start`, synchronously, before anything can spawn, also during an exam stand-down. For every token in chat-state.json's `tokens` it
/// runs the kill step at once (SIGKILL to every carrier of the token, the recorded child and its group while their identities still match, and
/// every descendant of any of them), re-enumerates every 100 ms until `seconds` after the sweep began, and checks then. A token with nothing
/// left is dropped. A recorded guard that is still alive runs its own stop in parallel (both only send identity-checked signals, and neither
/// reads what the other writes); if it is still alive at the check it is SIGKILLed, identity-checked. Each token's set also holds the members the
/// agent recorded for it in `members` (R9.12 item 1.5), identity-checked at every enumeration; the entry leaves with its token.
public enum TermStartSweep {
    public struct Result: Equatable { public var swept: Int; public var left: Int }

    @discardableResult
    public static func run(store: OwnState, seconds: TimeInterval = 3, log: (String) -> Void) -> Result {
        let state = ChatTermState(store: store)
        let content: ChatState
        do { content = try state.read() } catch {
            log("CHAT notice kind=state-unreadable")
            return Result(swept: 0, left: 0)
        }
        guard !content.tokens.isEmpty else { return Result(swept: 0, left: 0) }
        let started = ProcessInfo.processInfo.systemUptime
        func uid(_ identity: ChatState.Identity) -> ProcessIdentity {
            ProcessIdentity(ClawdIdentity(pid: identity.pid, uid: getuid(), seconds: identity.startSec, microseconds: identity.startUsec))
        }
        // One set per token. The recorded child, with its identity, belongs to the token it was recorded under.
        var sets: [(token: String, set: ChatSweepSet)] = []
        for token in content.tokens {
            let recorded = content.child?.token == token ? content.child : nil
            let identity = recorded?.identity.map(uid)
            let set = ChatSweepSet(token: token, pid: recorded?.pid ?? -1, identity: identity)
            // The members the agent tracked (R9.12 item 1.5), by their recorded identities: a pid that now names another process is never signalled.
            set.seed((content.members[token] ?? []).map(uid))
            sets.append((token, set))
        }
        let guardRecord = content.child?.guardProcess

        var killed = Set<String>()
        func killStep() {
            for entry in sets {
                for member in entry.set.grow(.fresh) where ChatProc.signal(member, SIGKILL) { killed.insert(ChatSweepSet.key(member)) }
            }
        }
        killStep()
        while ProcessInfo.processInfo.systemUptime - started < seconds {
            Thread.sleep(forTimeInterval: 0.1)
            killStep()
            if sets.allSatisfy({ $0.set.grow(.fresh).isEmpty }) { break }
        }
        // A guard still alive at the check has outlived its own stop.
        if let guardRecord {
            let live = ChatProc.identity(of: guardRecord.pid)
            if guardRecord.matches(live), let live { ChatProc.signal(live, SIGKILL) }
        }
        var left = 0
        for entry in sets {
            let remaining = entry.set.grow(.fresh).count
            left += remaining
            if remaining == 0 { try? state.dropToken(entry.token) }
        }
        if content.child.map({ child in sets.contains { $0.token == child.token } }) == true, left == 0 { try? state.clearChild(token: content.child!.token) }
        log("CHAT sweep n=\(killed.count) left=\(left) via=start")
        return Result(swept: killed.count, left: left)
    }
}
