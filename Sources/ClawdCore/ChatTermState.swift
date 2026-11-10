import Foundation

/// chat-private/chat-state.json (it was chat-state.json at the state root until Orca parity round D, Q8) in T1 (Interface Contract, "Terminal path (r9)"): the unswept spawn tokens and the recorded child with its guard. Written
/// through OwnState (atomic), read by the start sweep. T1 leaves `sessionId`, `sessionFolder`, `recentFolders` and `lastStop` empty.
public struct ChatState: Codable, Equatable {
    public struct Identity: Codable, Equatable {
        public var pid: Int32
        public var startSec: UInt64
        public var startUsec: UInt64
        public init(pid: Int32, startSec: UInt64, startUsec: UInt64) { self.pid = pid; self.startSec = startSec; self.startUsec = startUsec }
        init(_ identity: ProcessIdentity) { self.init(pid: identity.pid, startSec: identity.seconds, startUsec: identity.microseconds) }
        func matches(_ live: ProcessIdentity?) -> Bool {
            guard let live else { return false }
            return live.pid == pid && live.seconds == startSec && live.microseconds == startUsec
        }
    }
    public struct Child: Codable, Equatable {
        public var guardProcess: Identity?
        public var pid: Int32?
        public var pgid: Int32?
        public var startSec: UInt64?
        public var startUsec: UInt64?
        public var token: String
        enum CodingKeys: String, CodingKey { case guardProcess = "guard", pid, pgid, startSec, startUsec, token }
        public init(token: String, guardProcess: Identity? = nil, pid: Int32? = nil, pgid: Int32? = nil, startSec: UInt64? = nil, startUsec: UInt64? = nil) {
            self.token = token; self.guardProcess = guardProcess; self.pid = pid; self.pgid = pgid; self.startSec = startSec; self.startUsec = startUsec
        }
        public var identity: Identity? {
            guard let pid, let startSec, let startUsec else { return nil }
            return Identity(pid: pid, startSec: startSec, startUsec: startUsec)
        }
        // The state file spells a null field as null, as the contract shows it.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(guardProcess, forKey: .guardProcess); try container.encode(pid, forKey: .pid); try container.encode(pgid, forKey: .pgid)
            try container.encode(startSec, forKey: .startSec); try container.encode(startUsec, forKey: .startUsec); try container.encode(token, forKey: .token)
        }
    }
    public struct LastStop: Codable, Equatable { public var reason: String; public var at: Double }

    public var sessionId: String?
    public var sessionFolder: String?
    public var recentFolders: [String]
    public var child: Child?
    public var tokens: [String]
    public var lastStop: LastStop?
    /// The members of each token's sweep set that the agent tracked (R9.12 item 1), claude excluded: the processes the descendant walk found that
    /// no visible token marks. Kept per token, so a token not swept clean keeps its members when a new spawn replaces `child`.
    public var members: [String: [Identity]]

    public init() { sessionId = nil; sessionFolder = nil; recentFolders = []; child = nil; tokens = []; lastStop = nil; members = [:] }

    enum CodingKeys: String, CodingKey { case sessionId, sessionFolder, recentFolders, child, tokens, lastStop, members }

    /// A file written before `members` existed (the previous build, or the stream path) reads as no members, never as malformed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        sessionFolder = try container.decodeIfPresent(String.self, forKey: .sessionFolder)
        recentFolders = try container.decode([String].self, forKey: .recentFolders)
        child = try container.decodeIfPresent(Child.self, forKey: .child)
        tokens = try container.decode([String].self, forKey: .tokens)
        lastStop = try container.decodeIfPresent(LastStop.self, forKey: .lastStop)
        members = try container.decodeIfPresent([String: [Identity]].self, forKey: .members) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId); try container.encode(sessionFolder, forKey: .sessionFolder)
        try container.encode(recentFolders, forKey: .recentFolders); try container.encode(child, forKey: .child)
        try container.encode(tokens, forKey: .tokens); try container.encode(lastStop, forKey: .lastStop)
        try container.encode(members, forKey: .members)
    }
}

/// The reader and writer of chat-state.json. Every change reads the file again, changes one field and writes it whole, under one lock, so the
/// agent's main queue, the stop queue and the reaper never overwrite each other's fields.
public final class ChatTermState {
    /// The file's one name: private (0600 in the 0700 chat-private/), since it holds the session id, the folders and the spawn tokens.
    public static let fileName = "chat-private/chat-state.json"
    /// Where earlier builds wrote it. `load()` moves it.
    public static let legacyFileName = "chat-state.json"
    public enum Failure: Error, Equatable { case unreadable, unwritable }

    private let store: OwnState
    private let lock = NSLock()
    private var writeTotal = 0

    public init(store: OwnState) { self.store = store }

    /// The file's content; an absent file is an empty state, a malformed one throws `unreadable` and is left in place.
    public func read() throws -> ChatState {
        lock.lock(); defer { lock.unlock() }
        return try load()
    }

    private func load() throws -> ChatState {
        let path: String, legacy: String
        do { path = try store.url(Self.fileName).path; legacy = try store.url(Self.legacyFileName).path } catch { throw Failure.unreadable }
        var info = stat()
        var current = false
        if lstat(path, &info) == 0 { current = true } else if errno != ENOENT { throw Failure.unreadable }
        if lstat(legacy, &info) == 0 {
            // The move runs here, under the lock, so every reader and writer (the start sweep first) passes through it.
            // The old file is closed to others first: whatever happens next (a refused chat-private/, a file that does not parse), it stays 0600.
            try? store.narrow(Self.legacyFileName, directory: false)
            if current {
                // Both present: a crash between the write and the removal. The private file stands and the old one goes, but only once the
                // private one has parsed; otherwise the old one, possibly the only good copy, is kept and the state reads as unreadable.
                let kept = try readPrivate()
                try? store.removeFile(Self.legacyFileName)
                return kept
            } else {
                let moved: ChatState
                do { moved = try store.readJSON(ChatState.self, from: Self.legacyFileName) } catch {
                    // A malformed file is not moved: it is left in place, as the unreadable file it is.
                    throw Failure.unreadable
                }
                guard (try? store.writePrivate(try Self.encoded(moved), to: Self.fileName)) != nil else { return moved }
                try? store.removeFile(Self.legacyFileName)
                return moved
            }
        } else if !current {
            return ChatState()
        }
        return try readPrivate()
    }

    private func readPrivate() throws -> ChatState {
        do { return try store.readJSON(ChatState.self, from: Self.fileName) } catch { throw Failure.unreadable }
    }

    private static func encoded(_ state: ChatState) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    /// Reads, changes and writes the file. A malformed file is not overwritten. An entry of `members` whose token is no longer in `tokens` is
    /// dropped by the write.
    @discardableResult
    public func update(_ change: (inout ChatState) -> Void) throws -> ChatState {
        try modify { state in change(&state); return true }
    }

    /// Like `update`, but nothing is written when `change` returns false.
    @discardableResult
    private func modify(_ change: (inout ChatState) -> Bool) throws -> ChatState {
        lock.lock(); defer { lock.unlock() }
        var state = try load()
        guard change(&state) else { return state }
        state.members = state.members.filter { state.tokens.contains($0.key) }
        do { try store.writePrivate(try Self.encoded(state), to: Self.fileName) } catch { throw Failure.unwritable }
        writeTotal += 1
        return state
    }

    /// How many times the file has been written by this reader (a test's counting seam).
    public var writes: Int { lock.lock(); defer { lock.unlock() }; return writeTotal }

    /// The token is appended to `tokens` and flushed, with the child's record started (spec T-9: before the guard is spawned).
    public func begin(token: String) throws {
        try update { state in
            if !state.tokens.contains(token) { state.tokens.append(token) }
            state.child = ChatState.Child(token: token)
        }
    }

    public func recordGuard(_ identity: ProcessIdentity, token: String) throws {
        try update { state in
            var child = state.child?.token == token ? state.child! : ChatState.Child(token: token)
            child.guardProcess = ChatState.Identity(identity)
            state.child = child
        }
    }

    public func recordChild(pid: Int32, pgid: Int32, identity: ProcessIdentity, token: String) throws {
        try update { state in
            var child = state.child?.token == token ? state.child! : ChatState.Child(token: token)
            child.pid = pid; child.pgid = pgid; child.startSec = identity.seconds; child.startUsec = identity.microseconds
            state.child = child
        }
    }

    /// A sweep of the token ended with nothing left: the token leaves `tokens`, and its members with it.
    public func dropToken(_ token: String) throws {
        try update { state in state.tokens.removeAll { $0 == token } }
    }

    /// `members[token]` becomes `identities`. A token no longer in `tokens` changes nothing (the tracker can run one growth past the stop's end).
    public func setMembers(_ identities: [ChatState.Identity], token: String) throws {
        try modify { state in
            guard state.tokens.contains(token) else { return false }
            state.members[token] = identities
            return true
        }
    }

    /// The guard has been reaped after its release (or the guard-lost sweep ended): the child record goes.
    public func clearChild(token: String) throws {
        try update { state in if state.child?.token == token { state.child = nil } }
    }
}
