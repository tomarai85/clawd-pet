import Foundation

/// One call to the chat page (the page's `ClawdChat.apply` or `ClawdChat.reset`): what the bridge sends, kept in Swift values so a test reads
/// it without a web view. `arguments` is the property-list payload `callAsyncJavaScript` takes as its one `message` argument.
public struct ChatWebCall {
    public enum Kind: String { case apply, reset }
    public let kind: Kind
    /// `apply`: the id list, only when it differs from the last list the page confirmed. `reset`: always the whole list.
    public let order: [Int]?
    /// `apply`: the entries whose value differs from the page's. `reset`: every entry.
    public let upserts: [ChatEntry]
    public let turn: ChatTurnState?
    /// The payload's size in bytes as the log line reports it: the entries' text plus a fixed 64 bytes of keys per entry, the id list as it is
    /// encoded (each id's digits and a separator), and 64 for the rest.
    public let bytes: Int

    public var arguments: [String: Any] {
        var message: [String: Any] = [:]
        let entries = upserts.map(ChatWebPayload.entry)
        if kind == .reset {
            message["entries"] = entries
        } else {
            message["upserts"] = entries
            if let order { message["order"] = order }
        }
        if let turn { message["turn"] = ChatWebPayload.turn(turn) }
        return message
    }
}

public enum ChatWebPayload {
    public static func kind(_ kind: ChatEntry.Kind) -> String {
        switch kind {
        case .user: return "user"
        case .assistant: return "assistant"
        case .tool: return "tool"
        case .notice: return "notice"
        case .error: return "error"
        case .footer: return "footer"
        case .divider: return "divider"
        }
    }

    public static func status(_ status: ChatToolStatus) -> String {
        switch status {
        case .running: return "running"
        case .done: return "done"
        case .failed: return "failed"
        case .unknown: return "unknown"
        }
    }

    public static func turn(_ turn: ChatTurnState) -> String {
        switch turn {
        case .none: return "none"
        case .running: return "running"
        case .stopping: return "stopping"
        }
    }

    /// An entry as the page reads it; a field the entry does not have is left out.
    public static func entry(_ entry: ChatEntry) -> [String: Any] {
        var value: [String: Any] = ["id": entry.id, "kind": kind(entry.kind), "text": entry.text]
        if let tool = entry.tool { value["tool"] = tool }
        if let status = entry.status { value["status"] = Self.status(status) }
        if let seconds = entry.seconds, seconds.isFinite { value["seconds"] = seconds }
        if let ms = entry.ms { value["ms"] = ms }
        if let cost = entry.cost, cost.isFinite { value["cost"] = cost }
        if entry.elided { value["elided"] = true }
        if let time = entry.time, time.isFinite { value["time"] = time }
        if entry.sending { value["sending"] = true }
        if entry.unconfirmed { value["unconfirmed"] = true }
        if !entry.images.isEmpty { value["images"] = entry.images }
        return value
    }

    static func size(of entries: [ChatEntry], order: [Int]?) -> Int {
        let ids = order?.reduce(0) { $0 + String($1).utf8.count + 1 } ?? 0
        return entries.reduce(64 + ids) { $0 + 64 + $1.text.utf8.count + ($1.tool?.utf8.count ?? 0) + $1.images.reduce(0) { $0 + $1.utf8.count } }
    }
}

/// How a call reaches the page: `callAsyncJavaScript` in production, a recorder in the tests. The completion says whether the page ran the call
/// without an error; it runs on the main queue, once, and may never run at all (a hung page: the bridge's own timeout covers that).
public protocol ChatWebTransport: AnyObject {
    func send(_ call: ChatWebCall, completion: @escaping (Bool) -> Void)
}

/// Feeds the chat page the changes of the conversation (Stage 2 R1, R6).
///
/// It keeps the last state the page confirmed, keyed by `ChatEntry.id`, and sends only the difference: `order` when the id list changed, the
/// entries whose value changed, `turn` when it changed, and nothing when none of the three did. One call is in flight at a time; what changes
/// meanwhile goes out in the next call, made from the previous one's completion. There is no repeating timer.
///
/// The confirmed state advances only when a call completes without an error. Nothing is sent before the page said `ready`. A call that fails
/// leaves the page in an unknown state, so the next call is a `reset` with the whole conversation. A call that does not complete within
/// `timeoutSeconds` is logged and still waited for: nothing else is sent while it is outstanding.
public final class ChatWebBridge {
    public static let timeoutSeconds: TimeInterval = 2
    /// After this many failed calls in a row nothing is retried until the conversation changes again, so a page that cannot answer is not
    /// sent the whole conversation over and over.
    public static let retries = 2

    private weak var transport: ChatWebTransport?
    private let timers: ChatTimers
    private let log: (String) -> Void

    public private(set) var isReady = false
    private var entries: [ChatEntry] = []
    private var turn: ChatTurnState = .none
    private var confirmed: [Int: ChatEntry] = [:]
    private var confirmedOrder: [Int]?
    private var confirmedTurn: ChatTurnState?
    private var needsReset = true
    private var inFlight: Int?
    private var token = 0
    private var deadline: ChatTimerHandle?
    private var failures = 0
    /// The page is known to be empty (it just said `ready`, and no call has failed since).
    private var pageIsFresh = false
    /// Called once per `ready`, when the page first shows what the bridge holds: after its first confirmed reset, or at once for a page that is
    /// empty and has nothing to show. The controller puts the reader's view back from here (Q18).
    public var onSynced: (() -> Void)?
    private var synced = false

    /// How many calls were made, and how many of them were resets (for the tests and the close line).
    public private(set) var calls = 0
    public private(set) var resets = 0

    public init(transport: ChatWebTransport, timers: ChatTimers, log: @escaping (String) -> Void = { _ in }) {
        self.transport = transport; self.timers = timers; self.log = log
    }

    /// The conversation as it is now.
    public func update(entries: [ChatEntry], turn: ChatTurnState) {
        self.entries = entries
        self.turn = turn
        pump()
    }

    /// The page said `ready`: it holds nothing yet, so the first call is a reset.
    public func pageReady() {
        isReady = true
        forget()
        pageIsFresh = true
        synced = false
        pump()
    }

    /// The page is gone (its process ended, or it is being reloaded): nothing is sent until it says `ready` again.
    public func pageLost() {
        isReady = false
        forget()
        pageIsFresh = false
        synced = false
    }

    private func markSynced() {
        guard !synced else { return }
        synced = true
        onSynced?()
    }

    private func forget() {
        token += 1
        inFlight = nil
        deadline?.cancel(); deadline = nil
        confirmed = [:]; confirmedOrder = nil; confirmedTurn = nil
        needsReset = true
        failures = 0
    }

    private func pump() {
        guard isReady, inFlight == nil, let transport else { return }
        let call: ChatWebCall
        if needsReset, pageIsFresh, entries.isEmpty, turn == .none {
            // A page that just said ready and has nothing to show already is what a reset would make it.
            needsReset = false; confirmedOrder = []; confirmedTurn = .none
            markSynced()
            return
        }
        if needsReset {
            call = ChatWebCall(kind: .reset, order: entries.map(\.id), upserts: entries, turn: turn, bytes: ChatWebPayload.size(of: entries, order: entries.map(\.id)))
        } else {
            let ids = entries.map(\.id)
            let order = ids == confirmedOrder ? nil : ids
            let changed = entries.filter { confirmed[$0.id] != $0 }
            let turnChange = turn == confirmedTurn ? nil : turn
            if order == nil, changed.isEmpty, turnChange == nil { return }
            call = ChatWebCall(kind: .apply, order: order, upserts: changed, turn: turnChange, bytes: ChatWebPayload.size(of: changed, order: order))
        }
        calls += 1
        if call.kind == .reset { resets += 1 }
        token += 1
        let mine = token
        inFlight = mine
        let snapshot = (entries: Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }), order: entries.map(\.id), turn: turn)
        log("CHAT web \(call.kind.rawValue) n=\(call.upserts.count) bytes=\(call.bytes)")
        deadline = timers.after(Self.timeoutSeconds) { [weak self] in self?.timedOut(mine) }
        let wasReset = call.kind == .reset
        transport.send(call) { [weak self] succeeded in self?.finished(mine, succeeded, snapshot, wasReset: wasReset) }
    }

    private func finished(_ mine: Int, _ succeeded: Bool, _ snapshot: (entries: [Int: ChatEntry], order: [Int], turn: ChatTurnState), wasReset: Bool) {
        guard inFlight == mine else { return }
        inFlight = nil
        deadline?.cancel(); deadline = nil
        if succeeded {
            confirmed = snapshot.entries; confirmedOrder = snapshot.order; confirmedTurn = snapshot.turn
            needsReset = false
            failures = 0
            if wasReset { markSynced() }
            pump()
        } else {
            log("CHAT web apply-failed")
            retryAfterFailure()
        }
    }

    /// The deadline only says so in the log. The call is still queued or running in the page, so its slot stays taken: a second call now would
    /// pile up behind it. Its own completion, late or not, frees the slot: a success confirms exactly what it carried, a failure asks for a reset.
    private func timedOut(_ mine: Int) {
        guard inFlight == mine else { return }
        deadline = nil
        log("CHAT web apply-timeout")
    }

    private func retryAfterFailure() {
        needsReset = true
        pageIsFresh = false
        failures += 1
        if failures <= Self.retries { pump() }
    }
}

/// What a Cmd-click on a link may open: an http or https URL of at most 2 KiB with a host (Stage 2 "Vocabulary fixed").
public enum ChatWebLink {
    public static let maxBytes = 2048

    public static func openable(_ text: String) -> URL? {
        guard text.utf8.count <= maxBytes, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
