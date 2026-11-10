import Foundation

/// The texts sent from the composer and the place the Up and Down keys have reached in them (Orca NC/native-chat-composer-state.ts:203-232). `index`
/// is nil while the user is not recalling. It lives in the controller, so it survives a close and reopen; it is empty after an agent restart.
public struct ChatComposerHistory: Equatable {
    /// Orca's history dies with its composer. Clawd's lives in the agent for days with entries up to 1 MiB, so the total is capped: the oldest go first.
    public static let capBytes = 4 * 1024 * 1024

    public private(set) var entries: [String] = []
    public private(set) var index: Int?
    private var bytes = 0

    public init() {}

    /// A text whose send was accepted (or that became a card). Whitespace-only text and a text equal to the last entry are not pushed. A push
    /// resets the index, even when nothing is added (Orca pushHistory).
    public mutating func push(_ sent: String) {
        index = nil
        guard !sent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entries.last != sent else { return }
        entries.append(sent)
        bytes += sent.utf8.count
        while bytes > Self.capBytes, !entries.isEmpty { bytes -= entries.removeFirst().utf8.count }
    }

    /// Up: the previous entry (the last when not recalling, then down to the first and staying there). Nil when there is nothing to recall.
    public mutating func previous() -> String? {
        guard !entries.isEmpty else { return nil }
        let next = index.map { max(0, $0 - 1) } ?? entries.count - 1
        index = next
        return entries[next]
    }

    /// Down: the next entry; past the last, the empty draft and no index. Nil when not recalling.
    public mutating func next() -> String? {
        guard let current = index else { return nil }
        guard current + 1 < entries.count else { index = nil; return "" }
        index = current + 1
        return entries[current + 1]
    }

    /// The user typed, pasted or dropped something: the next Up starts from the end.
    public mutating func edited() { index = nil }
}
