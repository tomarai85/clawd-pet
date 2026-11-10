import Foundation

/// Why the whole queue sends nothing on its own (Terms, Q12). Every stop Tom did not cause is `other`.
public enum ChatQueuePause: String, Equatable {
    case none, stopped, restarted, cleared, resumed, other
}

/// Why one card is not on its way, in Orca's names (NC/structured-agent-session-queued-cards.ts:18-27; `awaiting-answer` never applies, Clawd has
/// no question cards).
public enum ChatCardHold: Equatable {
    case turn, queuePaused, paused(String), behindReturned, returned
}

/// What a card is for the list: the stored card and the hold derived for it.
public struct ChatQueueRow: Equatable {
    public var card: ChatComposerFile.Card
    public var hold: ChatCardHold
    public var text: String { card.text }
    public var id: String { card.id }
    /// The caption under the text (Orca NativeChatQueuedMessageCard.tsx:54-97), or nil for a card that is plainly waiting.
    public var caption: String? {
        switch hold {
        case .returned:
            switch card.paused {
            case "discarded": return "This message was not delivered."
            case "refused": return "The provider did not accept this message."
            default: return "Stopped before it was sent"
            }
        case .paused(let reason):
            switch reason {
            case "send-failed": return "Couldn't send \u{2014} press Send to retry."
            case "kept": return "Not sent yet \u{2014} press Send to send it."
            case "doubt": return "Clawd couldn't confirm your message reached Claude Code. Check the chat, then send it again if needed."
            default: return "Paused"
            }
        case .behindReturned: return "Waiting \u{2014} a message ahead needs attention"
        case .turn, .queuePaused: return nil
        }
    }
    /// The images the card's send carried (Q14), one label per chip: "Pasted image" or the file's name; an image that could not be brought back keeps its name.
    public var chipLabels: [String] {
        (card.chips ?? []).compactMap { chip in
            if let path = chip.path { return ChatChipImages.label(for: path) }
            return chip.unavailable.map(ChatChipImages.label(for:))
        }
    }
    /// An alert icon instead of the list-end icon: a returned, send-failed or doubt card.
    public var alerts: Bool {
        if case .returned = hold { return true }
        if case .paused(let reason) = hold { return reason == "send-failed" || reason == "doubt" }
        return false
    }
    /// The card's one action is Send (a paper plane), not Steer: it is held on its own or returned, so it is not waiting on the turn (Orca :104-122).
    public var sendsPlainly: Bool {
        switch hold {
        case .paused, .returned: return true
        default: return false
        }
    }
}

/// The queued sends of one conversation (Q12, Q13): the cards, the queue's pause, and the sends written to the CLI and not yet settled. A pure value
/// that mirrors `chat-private/chat-composer.json` (`cards`, `pause`, `inflight`, `doubt`); the controller applies the rules here and writes the file.
public struct ChatQueue: Equatable {
    public static let maxCards = 20
    public static let maxBytes = 1024 * 1024
    public static let fullWords = "The message queue is full. Send again after the current turn ends."
    public static let pausedWords: [ChatQueuePause: String] = [
        .stopped: "Queue paused because you interrupted",
        .restarted: "Queue paused because Clawd restarted",
        .cleared: "Queue paused after you cleared the conversation",
        .resumed: "Queue paused after you resumed a conversation",
        .other: "Queue paused"
    ]

    public private(set) var cards: [ChatComposerFile.Card] = []
    public private(set) var pause: ChatQueuePause = .none
    /// Every send written (or about to be) and not yet delivered or converted: the file keeps it so a crash loses nothing.
    public private(set) var inflight: [ChatComposerFile.Send] = []
    /// The card of each card-origin send in flight, and the place it had, so a send that provably did not happen gives it back where it was.
    private var taken: [String: (card: ChatComposerFile.Card, index: Int)] = [:]
    private static func equal(_ a: [String: (card: ChatComposerFile.Card, index: Int)], _ b: [String: (card: ChatComposerFile.Card, index: Int)]) -> Bool {
        a.count == b.count && a.allSatisfy { b[$0.key]?.card == $0.value.card && b[$0.key]?.index == $0.value.index }
    }
    public static func == (lhs: ChatQueue, rhs: ChatQueue) -> Bool {
        lhs.cards == rhs.cards && lhs.pause == rhs.pause && lhs.inflight == rhs.inflight && equal(lhs.taken, rhs.taken)
    }

    public init() {}

    /// The queue as a start finds it. Cards waiting from a run that ended are under the `restarted` pause; every send that was in flight, and
    /// every one left in doubt, is a held doubt card with its uuid and is never sent by itself (Q8, Q13).
    public init(restoring file: ChatComposerFile) {
        cards = (file.cards ?? []).filter { $0.state == "waiting" || $0.state == "returned" }
        for send in (file.doubt ?? []) + (file.inflight ?? []) where !doubtCards.contains(where: { $0.id == send.uuid }) {
            cards.insert(Self.doubtCard(uuid: send.uuid, text: send.text, chips: send.chips), at: doubtCards.count)
        }
        if cards.contains(where: { $0.state == "waiting" && $0.paused == nil }) { pause = .restarted }
    }

    private static func doubtCard(uuid: String, text: String, chips: [ChatComposerChip]?) -> ChatComposerFile.Card {
        ChatComposerFile.Card(id: uuid, text: text, state: "waiting", hold: "paused", paused: "doubt", chips: chips)
    }

    public var doubtCards: [ChatComposerFile.Card] { cards.filter { $0.state == "waiting" && $0.paused == "doubt" } }

    /// Writes the queue into the file's fields (the doubt cards go to `doubt`, the rest to `cards`).
    public func store(into file: inout ChatComposerFile) {
        let rest = cards.filter { !($0.state == "waiting" && $0.paused == "doubt") }
        file.cards = rest.isEmpty ? nil : rest
        file.pause = pause == .none ? nil : pause.rawValue
        file.inflight = inflight.isEmpty ? nil : inflight
        let doubt = doubtCards.map { ChatComposerFile.Send(uuid: $0.id, text: $0.text, chips: $0.chips) }
        file.doubt = doubt.isEmpty ? nil : doubt
    }

    // MARK: the list

    /// The cards as the list shows them, each with its hold (Orca projectQueuedMessageCards, :52-80).
    public var rows: [ChatQueueRow] {
        var behindReturned = false
        return cards.map { card in
            let hold: ChatCardHold
            if card.state == "returned" { hold = .returned }
            else if let own = card.paused { hold = .paused(own) }
            else if behindReturned { hold = .behindReturned }
            else if pause != .none { hold = .queuePaused }
            else { hold = .turn }
            behindReturned = behindReturned || card.state == "returned"
            return ChatQueueRow(card: card, hold: hold)
        }
    }

    /// The pause row shows only when some card is held by the pause: a pause over cards Resume would not send offers nothing to press.
    public var pauseRowText: String? {
        rows.contains { $0.hold == .queuePaused } ? Self.pausedWords[pause] : nil
    }

    public func card(_ id: String) -> ChatComposerFile.Card? { cards.first { $0.id == id } }

    /// The card Cmd+Enter steers: the newest one, whatever holds it.
    public var newestCard: ChatComposerFile.Card? { cards.last }

    // MARK: budget and adding

    /// The UTF-8 size of `[{"type":"text","text":<text>}]` as JSON (Orca QUEUED_MESSAGES_MAX_TOTAL_BYTES counts `JSON.stringify(row.body.blocks)`).
    public static func blocksBytes(_ text: String) -> Int {
        var count = "[{\"type\":\"text\",\"text\":\"\"}]".utf8.count
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22, 0x5C, 0x08, 0x0C, 0x0A, 0x0D, 0x09: count += 2
            case 0..<0x20: count += 6
            default: count += String(scalar).utf8.count
            }
        }
        return count
    }

    /// Waiting or returned cards: the ones the budget counts (a doubt card is a held send, not queued work).
    private var unsettled: [ChatComposerFile.Card] { cards.filter { $0.paused != "doubt" } }

    /// Whether one more card of this text fits (at most 20 unsettled cards, at most 1 MiB in all).
    public func fits(_ text: String) -> Bool {
        let existing = unsettled
        let bytes = existing.reduce(Self.blocksBytes(text)) { $0 + Self.blocksBytes($1.text) }
        return existing.count < Self.maxCards && bytes <= Self.maxBytes
    }

    /// Adds a waiting card at the end; nil when it does not fit (nothing changes).
    @discardableResult
    public mutating func add(_ text: String, id: String = UUID().uuidString.lowercased()) -> String? {
        guard fits(text) else { return nil }
        cards.append(ChatComposerFile.Card(id: id, text: text, state: "waiting", hold: "turn"))
        return id
    }

    /// Whether the queue would send a card now: a waiting card that nothing holds is first in line. A new send queues behind it (FIFO), and a
    /// returned card or a paused queue ahead does not trap a new send (Orca shouldQueueStructuredAgentSessionSend).
    public var hasActionableCard: Bool { nextSendable != nil }

    /// The card the drain sends next: the oldest waiting one with no hold of its own, unless a returned card or the queue's pause comes first
    /// (Orca nextSendableQueuedCard). A card held on its own is passed over.
    public var nextSendable: ChatComposerFile.Card? {
        for card in cards {
            if card.state == "returned" { return nil }
            if card.paused != nil { continue }
            if pause != .none { return nil }
            return card
        }
        return nil
    }

    // MARK: pause

    public mutating func setPause(_ reason: ChatQueuePause) { pause = reason }

    /// Lifts the pause (Resume, or a person's turn starting).
    public mutating func liftPause() { pause = .none }

    // MARK: sends in flight

    /// A send is about to leave: it is added to `inflight`, and a card-origin send takes its card out of the list. This is the one change that
    /// clears the draft's or the card's text for a send, made before the frame goes to the CLI, so no moment exists with the text only in memory.
    public mutating func begin(_ request: ChatSendRequest) {
        if case .card(let id) = request.origin, let index = cards.firstIndex(where: { $0.id == id }) {
            taken[request.uuid] = (cards[index], index)
            cards.remove(at: index)
        }
        let origin: String
        switch request.origin {
        case .draft: origin = "draft"
        case .card(let id): origin = "card:" + id
        }
        inflight.removeAll { $0.uuid == request.uuid }
        inflight.append(ChatComposerFile.Send(uuid: request.uuid, text: request.text, origin: origin, chips: request.chips.isEmpty ? nil : request.chips))
    }

    /// The send did not leave (the session refused it): everything `begin` did is undone.
    public mutating func abort(_ uuid: String) {
        inflight.removeAll { $0.uuid == uuid }
        if let back = taken.removeValue(forKey: uuid) { cards.insert(back.card, at: min(back.index, cards.count)) }
    }

    /// It was delivered: the send is settled and its card is gone for good.
    public mutating func delivered(_ uuid: String) {
        inflight.removeAll { $0.uuid == uuid }
        taken[uuid] = nil
        removeDoubt(uuid)
    }

    /// The send's line was provably not written. A card-origin send gives its card back, held on its own (`send-failed`), where it was. A draft
    /// send returns its text to the draft (nil here: the caller restores it).
    public mutating func unwritten(_ entry: ChatLedgerEntry) {
        inflight.removeAll { $0.uuid == entry.uuid }
        guard let back = taken.removeValue(forKey: entry.uuid) else { return }
        var card = back.card
        card.hold = "paused"; card.paused = "send-failed"
        cards.insert(card, at: min(back.index, cards.count))
    }

    /// The CLI withdrew the send before it started. A card-origin send, and any steer, becomes a `returned` card with the reason. An ordinary draft
    /// send is for the caller to put back into the draft (this returns true then).
    @discardableResult
    public mutating func notDelivered(_ entry: ChatLedgerEntry, _ why: ChatNotDelivered) -> Bool {
        inflight.removeAll { $0.uuid == entry.uuid }
        let back = taken.removeValue(forKey: entry.uuid)
        guard back != nil || entry.steer else { return true }
        var card = back?.card ?? ChatComposerFile.Card(id: UUID().uuidString.lowercased(), text: entry.text, state: "waiting", hold: "turn",
                                                           chips: entry.chips.isEmpty ? nil : entry.chips)
        card.state = "returned"; card.hold = "returned"; card.paused = why.rawValue
        let index = back?.index ?? cards.count
        cards.insert(card, at: min(index, cards.count))
        return false
    }

    /// The send may or may not have run: it becomes a held doubt card with its uuid, in the same change that drops it from `inflight`.
    public mutating func doubt(_ entry: ChatLedgerEntry) {
        inflight.removeAll { $0.uuid == entry.uuid }
        taken[entry.uuid] = nil
        guard !cards.contains(where: { $0.id == entry.uuid }) else { return }
        cards.insert(Self.doubtCard(uuid: entry.uuid, text: entry.text, chips: entry.chips.isEmpty ? nil : entry.chips), at: doubtCards.count)
    }

    private mutating func removeDoubt(_ uuid: String) {
        cards.removeAll { $0.id == uuid && $0.paused == "doubt" }
    }

    // MARK: card actions

    /// A card's chips are replaced (an image of a doubt or returned card that could not be brought back is marked so).
    public mutating func setChips(_ id: String, _ chips: [ChatComposerChip]) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].chips = chips
    }

    /// Removes a card (Delete, or Edit once the draft holds its text). Nil when it is not in the list (it was already sent).
    @discardableResult
    public mutating func remove(_ id: String) -> ChatComposerFile.Card? {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return nil }
        return cards.remove(at: index)
    }

    /// The text a card hands back to the draft with Orca's rule (SH/returned-draft-text.ts:6-19): after what the draft holds, a blank line apart; a
    /// whitespace-only draft counts as empty; nothing is added when the draft already ends with that text.
    public static func appendReturned(draft: String, text: String) -> String {
        let returned = ChatJSText.trimmedEnd(text)
        if ChatJSText.trimmed(returned).isEmpty { return draft }
        let kept = ChatJSText.trimmedEnd(draft)
        if kept.isEmpty { return text }
        if kept == returned || kept.hasSuffix("\n\n" + returned) { return draft }
        return kept + "\n\n" + text
    }
}
