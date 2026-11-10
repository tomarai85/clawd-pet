import Foundation

/// What the readers hand to the main queue: a parser event, or one of the bridge's own facts.
enum ChatItem: Equatable {
    case event(ChatEvent)
    /// Droppable events were dropped here while the main queue lagged (spec F2.3, X2).
    case backlog
    /// The child was reaped, after everything it wrote that the pipe still held.
    case exited(code: Int32?, signal: Int32?, stderrTail: [String])
    /// A write to the child's stdin failed (the child is gone or not reading).
    case writeFailed
    /// More than the hard cap is pending: the turn ends as an error and the child is stopped.
    case overflow
}

/// The bounded, ordered hand-off between a child's reader threads and the main queue (spec F2.3, cross-vendor X2). A reader appends; the main
/// queue takes everything pending in one call. Droppable kinds (text deltas, tool progress, `ignored` other than a result subtype) coalesce with
/// their predecessor and are dropped past 4 MiB of text or 4,096 events, leaving one `backlog` item at the first drop of an episode (an episode
/// ends when the main queue has taken everything). Everything else is never dropped and never merged, up to the hard cap of 64 MiB or 65,536
/// events, past which the hand-off reports `overflow` once and keeps only the bridge's own items.
final class ChatHandoff {
    static let softBytes = 4 * 1024 * 1024
    static let softEvents = 4096
    static let hardBytes = 64 * 1024 * 1024
    static let hardEvents = 65536

    private let lock = NSLock()
    private var items: [ChatItem] = []
    private var bytes = 0
    private var dropping = false
    private var overflowed = false
    /// Called outside the lock when the pending list goes from empty to non-empty.
    var onReady: (() -> Void)?

    static func isDroppable(_ event: ChatEvent) -> Bool {
        switch event {
        case .textDelta, .toolProgress: return true
        case .ignored(let type): return !type.hasPrefix("result/")
        default: return false
        }
    }
    private static func weight(_ event: ChatEvent) -> Int {
        switch event {
        case .textDelta(_, _, let text): return text.utf8.count + 32
        case .assistantBlocks(_, let blocks):
            return blocks.reduce(32) { total, block in
                if case .text(let text) = block { return total + text.utf8.count }
                return total + 64
            }
        case .result(_, _, _, _, let text, _): return text.utf8.count + 64
        case .controlRequest(_, _, let payload): return payload.utf8.count + 64
        default: return 128
        }
    }

    func push(_ event: ChatEvent) {
        if append({ self.add(event) }) { onReady?() }
    }

    func push(bridge item: ChatItem) {
        if append({ self.items.append(item); self.bytes += 128 }) { onReady?() }
    }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return items.isEmpty }

    func take() -> [ChatItem] {
        lock.lock(); defer { lock.unlock() }
        let taken = items
        items = []; bytes = 0; dropping = false
        return taken
    }

    private func append(_ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wasEmpty = items.isEmpty
        body()
        return wasEmpty && !items.isEmpty
    }

    private func add(_ event: ChatEvent) {
        if overflowed { return }
        let droppable = Self.isDroppable(event)
        if droppable {
            if bytes >= Self.softBytes { drop(); return }
            if merge(event) { return }
            if items.count >= Self.softEvents { drop(); return }
        }
        if !droppable, bytes >= Self.hardBytes || items.count >= Self.hardEvents {
            overflowed = true
            items.append(.overflow)
            return
        }
        items.append(.event(event)); bytes += Self.weight(event)
    }

    private func drop() {
        if !dropping { dropping = true; items.append(.backlog) }
    }

    /// Consecutive deltas of one block become one; consecutive progress of one tool keeps the latest.
    private func merge(_ event: ChatEvent) -> Bool {
        guard let last = items.last, case .event(let previous) = last else { return false }
        switch (previous, event) {
        case (.textDelta(let k1, let i1, let t1), .textDelta(let k2, let i2, let t2)) where k1 == k2 && i1 == i2:
            items[items.count - 1] = .event(.textDelta(messageKey: k1, blockIndex: i1, text: t1 + t2))
            bytes += t2.utf8.count
            return true
        case (.toolProgress(let a, _), .toolProgress(let b, _)) where a == b:
            items[items.count - 1] = .event(event)
            return true
        default:
            return false
        }
    }
}
