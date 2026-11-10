import Foundation

/// `unknown`: the turn ended and Claude Code never reported this tool's result (a lost line, or a crash); it is neither a success nor a failure.
public enum ChatToolStatus: Equatable {
    case running, done, failed, unknown
}

public struct ChatEntry: Equatable {
    /// `divider`: the rule Orca draws for a cleared conversation (NC/NativeChatNoticeRow.tsx:38-49); the entries above it stay.
    public enum Kind: Equatable { case user, assistant, tool, notice, error, footer, divider }
    public let id: Int
    public let kind: Kind
    public var text: String
    /// Tool entries: the tool name, its status and the seconds Claude Code last reported for it.
    public var tool: String?
    public var status: ChatToolStatus?
    public var seconds: Double?
    /// Footer entries: the turn's duration and cost.
    public var ms: Int?
    public var cost: Double?
    /// An entry whose text was cut at the 256 KiB cap (an assistant message's cap is shared by all of its blocks).
    public var elided = false
    /// User and assistant entries: milliseconds since 1970. A user entry's is its send time; an assistant entry's is when its first block arrived.
    public var time: Double?
    /// A user entry the turn has not answered yet: the page shows "Sending…" in the time's place. It clears at the turn's first output event or the
    /// turn's end, whichever comes first (Sprint 1: there is no replay before the queue round).
    public var sending = false
    /// A user entry whose send is in doubt (Q13): the page shows "Not confirmed" in place of the time. A later replay that names it clears this.
    public var unconfirmed = false
    /// A user entry's image paths (Q17): the page shows one name chip per path and loads no image.
    public var images: [String] = []
}

/// The conversation as the panel shows it: built only from parser events and the user's own sends, with no AppKit and no process. Streamed
/// text is replaced by the final block when it arrives; tool lines follow their tool_result; every cap of F3 holds after every call.
/// The final `assistant` line carries no block index of its own (it holds one block, and thinking lines are dropped by the parser). In the P-1
/// captures a block's final line sits after its last delta and before its `content_block_stop`, so the parser's `blockStarted` / `blockStopped`
/// events name the block a final text belongs to: the text block that was started (or last streamed) and not stopped, per message. A final text
/// of message m goes, in this order, to (a) an unfinalized streamed block of m whose text equals it (the open block first); else (b) m's open
/// block, when no line was lost (parse error, oversized line) since that block's last start or delta was read, or when the final text contains
/// what that block streamed (only deltas went missing); an open block with no streamed text takes the final text as its text; else (c) a new
/// entry. A final text is never written over another block's text: when the stream order does not name its block (a start or stop line was
/// lost and later lines of the block with it), the streamed text stays and the final text is added as its own entry. A final text that equals
/// a streamed block's text adds nothing.
/// A successful result's text completes the turn's last answer block: it replaces that block's text when its final text never arrived, and
/// is added when the turn had no answer block text or only an interim block whose text differs; it is never shown beside a finalized answer.
/// Bookkeeping lives for one turn and for as long as its entries do.
public struct ChatTranscript {
    public static let messageCap = 256 * 1024
    public static let conversationCap = 2 * 1024 * 1024
    /// Every entry counts this many bytes toward the conversation cap besides its text, so entries with no text (tool lines) are bounded too.
    public static let entryOverhead = 256
    public static let trimMarker = "Earlier messages trimmed"
    public static let elidedNotice = "The rest of this message is not shown (over 256 KiB)"
    public static let notLoggedIn = "Claude Code is not logged in: run `claude` in a terminal and log in"
    public static let clearedDivider = "Conversation cleared"
    public static let resumedDivider = "Resumed: "

    public private(set) var entries: [ChatEntry] = []
    public private(set) var sessionId: String?
    public private(set) var ignoredCounts: [String: Int] = [:]
    public private(set) var parseErrorCount = 0
    /// What Clawd asked for; a different answer in the init line gives a notice (once per distinct answer).
    public var expectedSessionId: String?
    public var expectedPermissionMode: String?

    /// One API message of the current turn: the entry of each streamed block, the blocks whose final text arrived, and the text shown for it.
    private struct Message {
        var blocks: [Int: Int] = [:]
        var finalized: Set<Int> = []
        var shown = 0
        var elided = false
        /// The newest entry id this message owns (or the next id, before it owns one); older than every surviving entry means the message is gone.
        var anchor: Int
        /// The text block whose start or latest delta was read and whose stop was not (nil: none), and `lostLines` as it stood at that line.
        var open: Int?
        var lostAtOpen = 0
    }
    /// The turn's last answer block: its entry (nil while the block has none), and whether its final text arrived.
    private struct Answer {
        var id: Int?
        var finalized: Bool
    }
    private var nextId = 1
    /// Lines the parser skipped (parse errors and oversized lines).
    private var lostLines = 0
    private var messages: [String: Message] = [:]
    private var tools: [String: Int] = [:]
    private var answer: Answer?
    /// The last value shown for each kind of once-only notice (a window type's reset time, the session, the mode): one row per kind, not per value.
    private var noticeState: [String: String] = [:]
    private var retryEntry: Int?
    private var rejectedThisTurn = false
    private var trimmedSincePrune = false
    private var lastTotalCost: Double?
    private var bytes = 0
    private let timeZone: TimeZone
    private let now: () -> Date
    /// The user entry that still shows "Sending…".
    private var sendingId: Int?
    /// The user entry of each send that carries a uuid (Q13), until its send settles: the replay, the lifecycle and the doubt find it by uuid.
    private var userEntries: [String: Int] = [:]
    /// The sends added with `appendPendingUser` whose replay has not come: only these move when their replay arrives.
    private var pendingUsers: Set<String> = []

    public init(timeZone: TimeZone = .current, now: @escaping () -> Date = Date.init) { self.timeZone = timeZone; self.now = now }

    /// How many table rows the model keeps: the current turn's messages, their blocks and tools (zero between turns), and one row per kind of
    /// once-only notice. For the tests.
    public var bookkeepingCount: Int { noticeState.count + tools.count + messages.values.reduce(messages.count) { $0 + $1.blocks.count + $1.finalized.count } }

    // MARK: input

    public mutating func appendUser(_ text: String, uuid: String? = nil, images: [String] = []) {
        endTurn()
        rejectedThisTurn = false
        let id = add(.user, text)
        setImages(id, images)
        if let uuid { rememberUser(uuid, id) }
        pruneIfNeeded()
    }

    /// A steer (Q13): a user entry added while a turn runs, which ends nothing: running tools keep their status, and the message and answer
    /// bookkeeping stays. It shows "Sending…" until its replay arrives (`placeUser`).
    public mutating func appendPendingUser(uuid: String, text: String, images: [String] = []) {
        rejectedThisTurn = false
        let sending = sendingId          // the running turn's own "Sending…" is not the steer's: this entry clears only when the ledger settles it
        let id = add(.user, text)
        setImages(id, images)
        sendingId = sending
        rememberUser(uuid, id)
        pendingUsers.insert(uuid)
        pruneIfNeeded()
    }

    private mutating func rememberUser(_ uuid: String, _ id: Int) {
        userEntries[uuid] = id
        // A settled send's id is forgotten with it; the table only outgrows the entries when sends in doubt were never resolved.
        if userEntries.count > 256 {
            let alive = Set(entries.map(\.id))
            userEntries = userEntries.filter { alive.contains($0.value) }
            pendingUsers = pendingUsers.filter { userEntries[$0] != nil }
        }
    }

    /// The replay of a pending user entry arrived: the entry moves to the replay's position, after everything the stream produced before it, and
    /// nothing else in the bookkeeping is touched. It is delivered.
    /// An entry that was not added as pending (an ordinary send) does not move: a local command's replay comes after its own output.
    public mutating func placeUser(uuid: String) {
        guard let id = userEntries[uuid] else { return }
        if pendingUsers.remove(uuid) != nil, let position = index(of: id), position != entries.count - 1 {
            let entry = entries.remove(at: position)
            entries.append(entry)
        }
        settleUser(id: id)
        userEntries[uuid] = nil
    }

    /// The send named `uuid` was delivered (a result named it, or its replay arrived with the entry already in place): "Sending…" and "Not confirmed"
    /// go and the entry shows its time.
    public mutating func confirmUser(uuid: String) {
        pendingUsers.remove(uuid)
        guard let id = userEntries[uuid] else { return }
        settleUser(id: id)
        userEntries[uuid] = nil
    }

    /// The send named `uuid` is in doubt: its entry stays, with "Not confirmed" in place of the time.
    public mutating func markUnconfirmed(uuid: String) {
        pendingUsers.remove(uuid)
        guard let id = userEntries[uuid], let position = index(of: id) else { return }
        entries[position].sending = false
        entries[position].unconfirmed = true
        if sendingId == id { sendingId = nil }
    }

    /// The send named `uuid` was not delivered: its pending entry is removed.
    public mutating func removeUser(uuid: String) {
        pendingUsers.remove(uuid)
        guard let id = userEntries.removeValue(forKey: uuid), let position = index(of: id) else { return }
        bytes -= Self.entryOverhead + entries[position].text.utf8.count
        entries.remove(at: position)
        if sendingId == id { sendingId = nil }
    }

    private mutating func settleUser(id: Int) {
        if let position = index(of: id) {
            entries[position].sending = false
            entries[position].unconfirmed = false
        }
        if sendingId == id { sendingId = nil }
    }

    public mutating func apply(_ event: ChatEvent) {
        if Self.isOutput(event) { clearSending() }
        applyEvent(event)
        pruneIfNeeded()
    }

    /// The events that are the turn's first output: text, a tool, a final message, a result or an error of the answer.
    private static func isOutput(_ event: ChatEvent) -> Bool {
        switch event {
        case .textDelta, .blockStarted, .assistantBlocks, .toolStarted, .result, .assistantError: return true
        default: return false
        }
    }

    private mutating func clearSending() {
        guard let id = sendingId else { return }
        sendingId = nil
        if let position = index(of: id) { entries[position].sending = false }
    }

    // MARK: the bridge's own lines (a child that exited, a refused spawn, a hand-off that dropped deltas)

    public mutating func appendNotice(_ text: String) { add(.notice, text); pruneIfNeeded() }
    public mutating func appendError(_ text: String) { add(.error, text); pruneIfNeeded() }
    /// The turn ended without a result line (the child exited, the user stopped it): its running tools become `unknown`.
    public mutating func endTurnWithoutResult() { endTurn() }
    /// The bridge dropped droppable events while the main queue lagged; the transcript counts it as a lost line, like a parse error.
    public mutating func noteBacklog() {
        lostLines += 1
        noticeOnce("backlog", "", "Some streamed output was skipped while Clawd caught up")
    }

    /// `/resume`: a rule in the clear's place, naming the conversation the next message continues. The entries above it stay. The init that follows
    /// names the resumed session, as the one a pick asked for.
    public mutating func appendResumed(_ title: String) {
        add(.divider, Self.resumedDivider + ChatJSText.displayText(title, maxLength: 60))
        expectedSessionId = nil
    }

    private mutating func applyEvent(_ event: ChatEvent) {
        switch event {
        case .initialized(let session, _, let mode, _, _):
            sessionId = session
            if let expected = expectedSessionId, expected != session { noticeOnce("session", session, "Claude Code continued another session than the one requested") }
            if let expected = expectedPermissionMode, !mode.isEmpty, expected != mode { noticeOnce("mode", mode, "Claude Code is running in \(mode) mode, not \(expected)") }
        case .textDelta(let key, let index, let text): delta(key: key, index: index, text: text)
        case .blockStarted(let key, let index, let isText): blockStarted(key: key, index: index, isText: isText)
        case .blockStopped(let key, let index): blockStopped(key: key, index: index)
        case .assistantBlocks(let key, let blocks): finalize(key: key, blocks: blocks)
        case .toolStarted(let id, let name): startTool(id: id, name: name)
        case .toolInput(let id, let summary): editTool(id) { $0.text = summary }
        case .toolResult(let id, let isError): editTool(id) { $0.status = isError ? .failed : .done }
        case .toolProgress(let id, let seconds): editTool(id) { $0.seconds = seconds }
        case .retry(let attempt, let max): retryLine("Retrying (attempt \(attempt) of \(max))")
        case .rateLimit(let status, let type, let resetsAt, let utilization): rateLimit(status: status, type: type, resetsAt: resetsAt, utilization: utilization)
        case .assistantError(let kind): assistantError(kind)
        case .hook(let name, let code, let outcome):
            if !outcome.isEmpty, outcome != "success" { add(.notice, "Hook \(name) did not succeed (exit \(code))") }
        case .compacted: add(.notice, "Conversation compacted")
        case .commandCatalog, .replay, .sessionState, .commandLifecycle, .controlResponse: break
        case .conversationReset(let trigger, _):
            if trigger == "clear" {
                // The old entries stay above the rule and the new conversation starts below it. The init that follows names the new session, and
                // that is expected: a reset is the one way a session id changes without a notice (the id the reset itself carries is a conversation
                // id, not the session id the init and the results use).
                add(.divider, Self.clearedDivider)
                expectedSessionId = nil
            } else {
                ignoredCounts["conversation_reset/" + trigger, default: 0] += 1
            }
        case .result(let outcome, let ms, let total, _, let text, _): finish(outcome: outcome, ms: ms, total: total, text: text)
        case .parseError:
            parseErrorCount += 1
            lostLines += 1
            noticeOnce("parse-error", "", "Some output from Claude Code could not be read")
        case .oversized:
            lostLines += 1
            add(.notice, "A very long line from Claude Code was skipped")
        case .ignored(let type): ignoredCounts[type, default: 0] += 1
        case .controlRequest, .controlCancel: break
        }
    }

    // MARK: entries and caps

    private func index(of id: Int) -> Int? { entries.lastIndex { $0.id == id } }

    /// Adds an entry. Any single entry is cut at the message cap (an assistant message's cap is tracked by `Message`, which hands over text that
    /// already fits); a cut is announced by one notice behind it.
    @discardableResult
    private mutating func add(_ kind: ChatEntry.Kind, _ text: String, tool: String? = nil, status: ChatToolStatus? = nil) -> Int {
        let id = nextId
        nextId += 1
        let (kept, cut) = Self.capped(text, limit: Self.messageCap)
        var entry = ChatEntry(id: id, kind: kind, text: kept, tool: tool, status: status)
        entry.elided = cut
        if kind == .user || kind == .assistant {
            let milliseconds = (now().timeIntervalSince1970 * 1000).rounded()
            if milliseconds.isFinite { entry.time = milliseconds }
        }
        if kind == .user { entry.sending = true; sendingId = id }
        entries.append(entry)
        bytes += Self.entryOverhead + kept.utf8.count
        trim()
        if cut { add(.notice, Self.elidedNotice) }
        return id
    }

    /// The image paths a user entry shows (Interface Contract: at most 20, each at most 1 KiB). They add nothing to the entry's byte count.
    private mutating func setImages(_ id: Int, _ images: [String]) {
        guard !images.isEmpty, let position = index(of: id) else { return }
        entries[position].images = images.filter { $0.utf8.count <= 1024 }.prefix(20).map { $0 }
    }

    /// A notice shown when `value` differs from the last value shown for `key`.
    private mutating func noticeOnce(_ key: String, _ value: String, _ text: String) {
        guard noticeState[key] != value else { return }
        noticeState[key] = value
        add(.notice, text)
    }

    private mutating func setText(_ position: Int, _ text: String) {
        bytes += text.utf8.count - entries[position].text.utf8.count
        entries[position].text = text
        trim()
    }

    /// Oldest entries go first, behind one marker line at the top (not counted); the newest entry always stays. Each entry counts its text plus
    /// `entryOverhead`.
    private mutating func trim() {
        guard bytes > Self.conversationCap else { return }
        var dropped = false
        while bytes > Self.conversationCap {
            let first = entries.first?.text == Self.trimMarker && entries.first?.kind == .notice ? 1 : 0
            guard entries.count - first > 1 else { break }
            bytes -= Self.entryOverhead + entries[first].text.utf8.count
            entries.remove(at: first)
            dropped = true
        }
        if dropped {
            trimmedSincePrune = true
            if entries.first?.text != Self.trimMarker {
                entries.insert(ChatEntry(id: nextId, kind: .notice, text: Self.trimMarker), at: 0)
                nextId += 1
            }
        }
    }

    /// The bookkeeping of entries that were trimmed goes with them. The tables are scanned only when they have grown past twice the number of
    /// entries (plus slack), so a long run of adds costs a scan per doubling, not per add.
    private mutating func pruneIfNeeded() {
        guard trimmedSincePrune, tools.count + messages.count > 2 * entries.count + 64 else { return }
        trimmedSincePrune = false
        let oldest = entries.first { !($0.kind == .notice && $0.text == Self.trimMarker) }?.id ?? nextId
        tools = tools.filter { $0.value >= oldest }
        for (key, var message) in messages {
            message.blocks = message.blocks.filter { $0.value >= oldest }
            if message.blocks.isEmpty && message.anchor < oldest { messages[key] = nil } else { messages[key] = message }
        }
    }

    /// The text cut to `limit` bytes at a Character boundary; `cut` says whether anything was dropped.
    private static func capped(_ text: String, limit: Int) -> (String, cut: Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var used = 0
        var end = text.startIndex
        for character in text {
            let width = character.utf8.count
            if used + width > limit { break }
            used += width
            end = text.index(after: end)
        }
        return (String(text[..<end]), true)
    }

    // MARK: text

    private mutating func delta(key: String, index blockIndex: Int, text: String) {
        guard !text.isEmpty else { return }
        var message = messages[key] ?? Message(anchor: nextId)
        if message.finalized.contains(blockIndex) || message.elided { return }
        message.open = blockIndex
        message.lostAtOpen = lostLines
        let (kept, cut) = Self.capped(text, limit: Self.messageCap - message.shown)
        var position: Int?
        if !kept.isEmpty {
            if let id = message.blocks[blockIndex] {
                if let found = index(of: id) {
                    entries[found].text.append(kept)             // in place: a long answer arrives in thousands of deltas
                    bytes += kept.utf8.count
                    position = found
                    message.shown += kept.utf8.count
                }
            } else {
                let id = add(.assistant, kept)
                message.blocks[blockIndex] = id
                message.anchor = id
                message.shown += kept.utf8.count
                answer = Answer(id: id, finalized: false)
            }
        }
        if cut {
            message.elided = true
            if let found = position ?? message.blocks[blockIndex].flatMap({ index(of: $0) }) { entries[found].elided = true }
        }
        messages[key] = message
        if position != nil { trim() }
        if cut { add(.notice, Self.elidedNotice) }
    }

    private mutating func blockStarted(key: String, index blockIndex: Int, isText: Bool) {
        guard isText else {
            if var message = messages[key] { message.open = nil; messages[key] = message }
            return
        }
        var message = messages[key] ?? Message(anchor: nextId)
        message.open = blockIndex
        message.lostAtOpen = lostLines
        messages[key] = message
        if message.blocks[blockIndex] == nil, !message.finalized.contains(blockIndex) { answer = Answer(id: nil, finalized: false) }
    }

    private mutating func blockStopped(key: String, index blockIndex: Int) {
        guard var message = messages[key] else { return }
        if message.open == blockIndex { message.open = nil }
        let empty = message.blocks.isEmpty && message.finalized.isEmpty && message.shown == 0 && !message.elided
        messages[key] = empty ? nil : message
    }

    private mutating func finalize(key: String, blocks: [ChatBlock]) {
        for block in blocks {
            switch block {
            case .text(let text): finalText(key: key, text: text)
            case .toolUse(let id, let name): startTool(id: id, name: name)
            }
        }
    }

    /// The streamed block this final text belongs to; the rule is in the doc comment of `ChatTranscript`.
    private func streamedBlock(for text: String, in message: Message) -> (index: Int, id: Int, position: Int)? {
        func candidate(_ blockIndex: Int) -> (index: Int, id: Int, position: Int)? {
            guard !message.finalized.contains(blockIndex), let id = message.blocks[blockIndex], let position = index(of: id) else { return nil }
            return (blockIndex, id, position)
        }
        let open = message.open.flatMap(candidate)
        if let open, entries[open.position].text == text { return open }
        for blockIndex in message.blocks.keys.sorted() {
            if let same = candidate(blockIndex), entries[same.position].text == text { return same }
        }
        guard let open else { return nil }
        return lostLines == message.lostAtOpen || text.contains(entries[open.position].text) ? open : nil
    }

    private mutating func finalText(key: String, text: String) {
        guard !text.isEmpty else { return }
        var message = messages[key] ?? Message(anchor: nextId)
        let streamed = streamedBlock(for: text, in: message)
        let current = streamed.map { entries[$0.position].text.utf8.count } ?? 0
        let (kept, cut) = Self.capped(text, limit: Self.messageCap - (message.shown - current))
        let announce = cut && !message.elided
        if cut { message.elided = true }
        message.shown += kept.utf8.count - current
        if let streamed {
            message.finalized.insert(streamed.index)
            message.anchor = max(message.anchor, streamed.id)
            messages[key] = message
            if answer?.id == streamed.id { answer?.finalized = true } else if answer == nil || answer?.id == nil { answer = Answer(id: streamed.id, finalized: true) }
            setText(streamed.position, kept)
            if cut, let found = index(of: streamed.id) { entries[found].elided = true }
        } else if !kept.isEmpty {
            let id = add(.assistant, kept)
            message.anchor = id
            if let open = message.open, message.blocks[open] == nil, !message.finalized.contains(open) {
                message.blocks[open] = id                    // the open block streamed nothing: this is its text, and a late delta adds nothing
                message.finalized.insert(open)
            }
            messages[key] = message
            if answer == nil || answer?.id == nil || answer?.finalized == true { answer = Answer(id: id, finalized: true) }
            if cut, let found = index(of: id) { entries[found].elided = true }
        } else {
            messages[key] = message
        }
        if announce { add(.notice, Self.elidedNotice) }
    }

    // MARK: tools

    private mutating func startTool(id: String, name: String) {
        if let known = tools[id], index(of: known) != nil { return }
        tools[id] = add(.tool, "", tool: name, status: .running)
    }

    private mutating func editTool(_ id: String, _ change: (inout ChatEntry) -> Void) {
        guard let entryId = tools[id], let position = index(of: entryId) else { return }
        let before = entries[position].text.utf8.count
        change(&entries[position])
        bytes += entries[position].text.utf8.count - before
        trim()
    }

    /// A tool of the current turn that never reported back is neither done nor failed.
    private mutating func settleRunningTools() {
        for entryId in tools.values {
            if let position = index(of: entryId), entries[position].status == .running { entries[position].status = .unknown }
        }
    }

    private mutating func endTurn() {
        clearSending()
        settleRunningTools()
        messages = [:]; tools = [:]; answer = nil; retryEntry = nil
    }

    // MARK: notices and the end of a turn

    private mutating func retryLine(_ text: String) {
        if let id = retryEntry, let position = index(of: id) { setText(position, text) } else { retryEntry = add(.notice, text) }
    }

    private func windowName(_ type: String) -> String {
        switch type {
        case "five_hour": return "5-hour"
        case "seven_day": return "7-day"
        default: return type.replacingOccurrences(of: "_", with: " ")
        }
    }

    private mutating func rateLimit(status: String, type: String, resetsAt: Double?, utilization: Double?) {
        switch status {
        case "allowed_warning":
            let percent = utilization.flatMap { $0.isFinite && $0 >= 0 && $0 <= 1000 ? ($0 <= 1 ? $0 * 100 : $0) : nil }
            noticeOnce("warning:" + type, "", percent.map { "\(windowName(type)) usage at \(Int($0.rounded()))%" } ?? "\(windowName(type)) usage is high")
        case "rejected":
            rejectedThisTurn = true
            var text = "Usage limit reached"
            if let epoch = resetsAt, epoch.isFinite, epoch >= 0, epoch <= 1e13 {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = timeZone
                formatter.dateFormat = "MMM d, HH:mm"
                text += ", resets " + formatter.string(from: Date(timeIntervalSince1970: epoch))
            }
            noticeOnce("rejected:" + type, "\(resetsAt ?? 0)", text)
        default: break
        }
    }

    private mutating func assistantError(_ kind: String) {
        switch kind {
        case "authentication_failed": noticeOnce("auth", "", Self.notLoggedIn)
        case "rate_limit": if !rejectedThisTurn { add(.error, "Usage limit reached") }
        default: add(.error, "Claude Code reported an error: " + kind.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// A result ends the turn. An error result's text is an error entry; a successful result's text completes the turn's last answer block (see
    /// the doc comment of `ChatTranscript`), never as a second copy of an answer that arrived whole.
    private mutating func completeAnswer(with text: String) {
        guard let answer, let id = answer.id, let position = index(of: id) else {
            if answer?.finalized != true { add(.assistant, text) }
            return
        }
        let shown = entries[position]
        if answer.finalized {
            let same = shown.text.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !same && !shown.elided { add(.assistant, text) }
            return
        }
        let (kept, cut) = Self.capped(text, limit: Self.messageCap)
        setText(position, kept)
        if cut, let found = index(of: id) {
            entries[found].elided = true
            if !shown.elided { add(.notice, Self.elidedNotice) }
        }
    }

    private mutating func finish(outcome: ChatResultOutcome, ms: Int, total: Double, text: String) {
        settleRunningTools()
        if outcome == .error {
            add(.error, text.isEmpty ? "Claude Code reported an error" : text)
        } else if !text.isEmpty {
            completeAnswer(with: text)
        }
        let last = lastTotalCost ?? 0
        let cost = total >= last ? total - last : total
        lastTotalCost = total
        let id = add(.footer, String(format: "%.1f s, $%.4f (reported by Claude Code)", Double(ms) / 1000, cost))
        if let position = index(of: id) { entries[position].ms = ms; entries[position].cost = cost }
        endTurn()
    }
}
