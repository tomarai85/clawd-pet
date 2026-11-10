import Foundation

/// Where a written send came from: the composer's draft, or a queued card (Q12). A provably unwritten send goes back to its origin only.
public enum ChatSendOrigin: Equatable {
    case draft
    case card(String)
}

/// One user frame Clawd asks the session to write (Q13). The controller makes the uuid so that its own write of "this text is now in flight" can
/// name it before the frame leaves.
public struct ChatSendRequest: Equatable {
    public var uuid: String
    public var text: String
    public var origin: ChatSendOrigin
    /// Written into a running turn (a card's Steer, or a send with chips during a turn) instead of as a turn of its own.
    public var steer: Bool
    public var chips: [ChatComposerChip]
    /// A person asked for it (Enter, Send, Steer, Resume's own press). The queue's drain is not a person.
    public var person: Bool
    /// The frame's content when the chips are images (Q16): read and encoded off the main thread before the send. Nil for a text-only send.
    public var payload: ChatImagePayload?

    public init(text: String, origin: ChatSendOrigin = .draft, steer: Bool = false, chips: [ChatComposerChip] = [], person: Bool = true,
                payload: ChatImagePayload? = nil, uuid: String = UUID().uuidString.lowercased()) {
        self.uuid = uuid; self.text = text; self.origin = origin; self.steer = steer; self.chips = chips; self.person = person; self.payload = payload
    }
}

/// How far the CLI got with one send (`command_lifecycle`).
public enum ChatLifecycle: Int, Equatable { case none = 0, queued, started }

/// Why a send was not delivered (a lifecycle terminal state before `started`): Orca's verdicts (MC/claude-command-lifecycle.ts:25-29).
public enum ChatNotDelivered: String, Equatable { case cancelled, discarded, refused }

/// Why a send is in doubt (Q13).
public enum ChatDoubtReason: String, Equatable {
    /// A lifecycle terminal state came after `started` (Orca: the send may be in the conversation).
    case endedAfterStart
    /// `started` and unconfirmed when the turn went idle.
    case startedAtIdle
    /// Queued (or with no lifecycle frame) and unconfirmed at the second idle after it was written.
    case unconfirmedAtSecondIdle
    /// The child ended by any path with the send unconfirmed.
    case childEnded
}

/// One written user frame, until it is delivered, not delivered or in doubt.
public struct ChatLedgerEntry: Equatable {
    public var uuid: String
    public var origin: ChatSendOrigin
    public var text: String
    public var chips: [ChatComposerChip]
    public var steer: Bool
    public var person: Bool
    /// A `/` send: a result settles it (Orca :141), because a local command's replay comes after its own output.
    public var slash: Bool
    public var lifecycle: ChatLifecycle = .none
    /// The line was completely written to the child's stdin. Until then the send may still prove unwritten.
    public var written = false
    /// How many idle frames came after the send was written.
    public var idles = 0
    /// The child it was written to (a doubt is reported when that child ends).
    public var child: Int
    /// The turn that was running when a steer was written (0 for an ordinary send): a replay in the same turn is a fold, a later one a miss.
    public var turn = 0

    public init(request: ChatSendRequest, child: Int) {
        uuid = request.uuid; origin = request.origin; text = request.text; chips = request.chips; steer = request.steer; person = request.person
        slash = request.text.hasPrefix("/"); self.child = child
    }
}

/// What the ledger decided about one send.
public enum ChatSendVerdict: Equatable {
    /// Its replay arrived, or a result named it. `late`: it was already in doubt.
    case delivered(ChatLedgerEntry, late: Bool)
    /// A lifecycle `cancelled`, `discarded` or `refused` before `started`: it never ran.
    case notDelivered(ChatLedgerEntry, ChatNotDelivered)
    /// It may or may not have run. It is never sent again by itself.
    case doubt(ChatLedgerEntry, ChatDoubtReason)
    /// Its line was provably not written (a write error, the child gone, or a stop that abandoned the queue).
    case unwritten(ChatLedgerEntry)

    public var entry: ChatLedgerEntry {
        switch self {
        case .delivered(let entry, _), .notDelivered(let entry, _), .doubt(let entry, _), .unwritten(let entry): return entry
        }
    }
}

/// Every send Clawd wrote to the child and has not yet seen settled (Q13; Orca MC/claude-command-lifecycle.ts, MC/claude-structured-dispatch.ts:51-107).
/// A pure value: the session feeds it the parser's events and acts on the verdicts it returns.
public struct ChatSendLedger: Equatable {
    /// Sends whose fate is not known, in the order they were added.
    public private(set) var pending: [ChatLedgerEntry] = []
    /// Sends in doubt for the current child. A replay or a result that names one later makes it delivered (Orca retires its waiters, never drops them).
    public private(set) var doubt: [String: ChatLedgerEntry] = [:]

    public init() {}

    public var hasPending: Bool { !pending.isEmpty }
    /// A send Clawd wrote whose fate is still open: pending, or in doubt and so still able to be named by a late replay.
    public var hasOutstanding: Bool { !pending.isEmpty || !doubt.isEmpty }
    public var hasDoubt: Bool { !doubt.isEmpty }
    public func entry(_ uuid: String) -> ChatLedgerEntry? { pending.first { $0.uuid == uuid } }

    public mutating func add(_ entry: ChatLedgerEntry) { pending.append(entry) }

    /// The line was completely written.
    public mutating func written(_ uuid: String) {
        if let index = pending.firstIndex(where: { $0.uuid == uuid }) { pending[index].written = true }
    }

    /// The line was not completely written. Nothing reached the child, so the send goes back to its origin.
    public mutating func unwritten(_ uuid: String) -> ChatSendVerdict? {
        guard let index = pending.firstIndex(where: { $0.uuid == uuid }) else { return nil }
        return .unwritten(pending.remove(at: index))
    }

    private mutating func deliver(_ uuid: String) -> ChatSendVerdict? {
        if let index = pending.firstIndex(where: { $0.uuid == uuid }) { return .delivered(pending.remove(at: index), late: false) }
        if let late = doubt.removeValue(forKey: uuid) { return .delivered(late, late: true) }
        return nil
    }

    /// A replay of `uuid` arrived.
    public mutating func replay(_ uuid: String) -> [ChatSendVerdict] { deliver(uuid).map { [$0] } ?? [] }

    /// A result arrived. It delivers the sends it names; without `user_message_uuids` it delivers the `/` sends (Orca :141).
    public mutating func result(named names: [String]?) -> [ChatSendVerdict] {
        var verdicts: [ChatSendVerdict] = []
        if let names {
            for name in names { if let verdict = deliver(name) { verdicts.append(verdict) } }
        } else {
            for entry in pending where entry.slash && entry.written { if let verdict = deliver(entry.uuid) { verdicts.append(verdict) } }
        }
        return verdicts
    }

    /// A `command_lifecycle` frame for a send of this child. Forward only: a redelivered command re-emits `queued`, but it has still started.
    public mutating func lifecycle(_ uuid: String, _ state: String) -> [ChatSendVerdict] {
        guard let index = pending.firstIndex(where: { $0.uuid == uuid }) else { return [] }
        switch state {
        case "started": pending[index].lifecycle = .started
        case "queued": if pending[index].lifecycle != .started { pending[index].lifecycle = .queued }
        case "cancelled", "discarded", "refused":
            let entry = pending.remove(at: index)
            if entry.lifecycle == .started {
                doubt[uuid] = entry
                return [.doubt(entry, .endedAfterStart)]
            }
            return [.notDelivered(entry, ChatNotDelivered(rawValue: state) ?? .cancelled)]
        default: break
        }
        return []
    }

    /// The CLI proved it withdrew this send (an interrupt's receipt listed it as cancelled, or `cancel_async_message` answered that it was): it never
    /// ran, whatever the lifecycle said so far (Orca MC/claude-structured-control-actions.ts:42-52, rejectClaudeDispatchWaiters).
    public mutating func withdraw(_ uuid: String) -> [ChatSendVerdict] {
        guard let index = pending.firstIndex(where: { $0.uuid == uuid }) else { return [] }
        return [.notDelivered(pending.remove(at: index), .cancelled)]
    }

    /// The CLI said `idle`. A `started` send still unanswered is doubt; a `queued` one may still start, until a whole turn has passed since it was
    /// written (the second idle: the interrupted turn's CLI idles without starting or cancelling it).
    public mutating func idle() -> [ChatSendVerdict] {
        var verdicts: [ChatSendVerdict] = []
        var kept: [ChatLedgerEntry] = []
        for var entry in pending {
            guard entry.written else { kept.append(entry); continue }
            entry.idles += 1
            if entry.lifecycle == .started {
                doubt[entry.uuid] = entry
                verdicts.append(.doubt(entry, .startedAtIdle))
            } else if entry.idles >= 2 {
                doubt[entry.uuid] = entry
                verdicts.append(.doubt(entry, .unconfirmedAtSecondIdle))
            } else {
                kept.append(entry)
            }
        }
        pending = kept
        return verdicts
    }

    /// The child ended (exit, interrupt-grace hard stop, write failure, overflow, exam, chat off, view change, idle stop or quit): every written send
    /// still unconfirmed is doubt. A send whose line is not yet written stays and its write reports the outcome, unless `unreported` says the process is
    /// about to exit (quit): then it is doubt too, since the line may have reached the child and nothing will report it (it is never sent again by itself).
    public mutating func childEnded(unreported: Bool = false) -> [ChatSendVerdict] {
        var verdicts: [ChatSendVerdict] = []
        var kept: [ChatLedgerEntry] = []
        for entry in pending {
            if entry.written || unreported {
                doubt[entry.uuid] = entry
                verdicts.append(.doubt(entry, .childEnded))
            } else {
                kept.append(entry)
            }
        }
        pending = kept
        return verdicts
    }

    /// A doubt send was dealt with (Tom deleted its card, sent it again or took it back into the draft): a late replay no longer matters.
    public mutating func forgetDoubt(_ uuid: String) { doubt.removeValue(forKey: uuid) }

    /// The next child starts with a clean doubt table: a new process cannot replay the old one's frames.
    public mutating func clearDoubt() { doubt = [:] }
}
