import Foundation

/// Where the reader was in the transcript page when it reported last (Q18, D2): whether the view followed the tail, the first entry whose box
/// crossed the viewport's top with the distance from that entry's top to the viewport's top, and a selection as entry ids plus character
/// offsets within each entry's text. It lives in memory, across a close and not across a restart, and carries ids and counts only.
public struct ChatViewState: Equatable {
    /// Every integer of a view message is a whole number from 0 to this.
    public static let limit = 10_000_000

    public var following: Bool
    public var anchor: Int
    public var offset: Int
    /// `[startId, startChar, endId, endChar]`, or nil when the selection was outside the transcript or collapsed.
    public var sel: [Int]?

    /// nil when a field is out of range (the page's message is then ignored).
    public init?(following: Bool, anchor: Int, offset: Int, sel: [Int]? = nil) {
        let range = 0...Self.limit
        guard range.contains(anchor), range.contains(offset) else { return nil }
        if let sel { guard sel.count == 4, sel.allSatisfy({ range.contains($0) }) else { return nil } }
        self.following = following; self.anchor = anchor; self.offset = offset; self.sel = sel
    }

    /// The argument of `ClawdChat.restoreView(state)`.
    public var arguments: [String: Any] {
        var value: [String: Any] = ["following": following, "anchor": anchor, "offset": offset]
        if let sel { value["sel"] = sel }
        return value
    }
}
