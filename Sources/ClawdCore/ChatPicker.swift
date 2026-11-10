import Foundation

/// One row of the `/` picker (Orca `NativeChatPickerItem`, NC/native-chat-picker-items.ts:12-34).
public struct ChatPickerItem: Equatable {
    public enum Kind: Equatable { case command, skill, conversation }
    public var kind: Kind
    public var name: String
    /// Exactly what a pick inserts.
    public var token: String
    public var description: String?
    public var argumentHint: String?
    /// A command whose name a skill shares: Orca keeps only the command row and annotates it.
    public var skillCollision: Bool
    /// A skill's scope label ("Personal", "Project", "Plugin", "Built-in"), when its descriptor gave one.
    public var scope: String?
    /// A `/resume` row: the Claude Code session id it resumes (`name` is its title, `description` its second line).
    public var conversationId: String? = nil
    public var id: String {
        switch kind {
        case .command: return "command:" + name
        case .skill: return "skill:" + name
        case .conversation: return "conversation:" + (conversationId ?? name)
        }
    }
    public var annotation: String? { kind == .command && skillCollision ? ChatPicker.collisionText : nil }
}

/// The `/` picker's rules, ported from Orca's NC/native-chat-picker-items.ts and NC/native-chat-composer-state.ts. Offsets are UTF-16 units, as a
/// JavaScript string and an NSTextView count them.
public enum ChatPicker {
    public static let resultLimit = 50
    public static let collisionText = "Also a skill name - agent decides"
    public static let emptyText = "No matching commands or skills"

    // MARK: triggers (NC/native-chat-picker-items.ts:272-274)

    /// `^/(\S*)$`
    static func leadingQuery(_ before: [UInt16]) -> String? {
        guard before.first == 0x2F, !before.dropFirst().contains(where: ChatJSText.isWhitespace) else { return nil }
        return String(decoding: before.dropFirst(), as: UTF16.self)
    }
    /// `\s/([^\s/]*)$`, the leftmost match.
    static func midPromptQuery(_ before: [UInt16]) -> String? {
        guard before.count >= 2 else { return nil }
        for index in 0..<(before.count - 1) where ChatJSText.isWhitespace(before[index]) && before[index + 1] == 0x2F {
            let rest = before[(index + 2)...]
            if !rest.contains(where: { ChatJSText.isWhitespace($0) || $0 == 0x2F }) { return String(decoding: rest, as: UTF16.self) }
        }
        return nil
    }
    /// `(?:^|\s)@(\S*)$`, the leftmost match.
    static func mentionQuery(_ before: [UInt16]) -> String? {
        for index in 0..<before.count where before[index] == 0x40 && (index == 0 || ChatJSText.isWhitespace(before[index - 1])) {
            let rest = before[(index + 1)...]
            if !rest.contains(where: ChatJSText.isWhitespace) { return String(decoding: rest, as: UTF16.self) }
        }
        return nil
    }

    // MARK: items

    /// A skill name that can be inserted as a token (NC/native-chat-picker-items.ts:220-227).
    static func isTokenSafe(_ name: String) -> Bool {
        !name.isEmpty && ChatJSText.length(name) <= 200 && !ChatJSText.hasWhitespace(name) && name.unicodeScalars.allSatisfy(ChatJSText.isSafeDisplay)
    }

    private static func scopePriority(_ scope: String?) -> Int {
        switch scope {
        case "Project": return 0
        case "Personal": return 1
        case "Built-in": return 2
        case "Plugin": return 3
        default: return 4
        }
    }

    private static func rank(name: String, description: String?, query: String) -> Int? {
        let wanted = query.lowercased(), candidate = name.lowercased()
        if candidate == wanted { return 0 }
        if candidate.hasPrefix(wanted) { return 1 }
        if candidate.contains(wanted) { return 2 }
        let needle = Array(wanted.utf16)
        var matched = 0
        for unit in candidate.utf16 {
            if matched < needle.count, unit == needle[matched] { matched += 1 }
            if matched == needle.count { return 3 }
        }
        if let description, description.lowercased().contains(wanted) { return 4 }
        return nil
    }

    private static func ranked(_ items: [ChatPickerItem], query: String) -> [ChatPickerItem] {
        guard !query.isEmpty else { return items }
        return items.enumerated().compactMap { offset, item in rank(name: item.name, description: item.description, query: query).map { (offset, $0, item) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { $0.2 }
    }

    /// The commands and then the skills the catalog offers for `query`, each group ranked on its own and cut at 50. Commands come in the catalog's
    /// order; skills in Orca's (scope, then name). A skill whose name a command has is not listed; that command is annotated instead.
    public static func items(entries: [ChatCommandEntry], query: String) -> [ChatPickerItem] {
        var seenSkills = Set<String>()
        let skills: [ChatPickerItem] = entries.filter { $0.kind == .skill && isTokenSafe($0.name) && seenSkills.insert($0.name).inserted }
            .enumerated().sorted { a, b in
                let (left, right) = (scopePriority(a.element.scope), scopePriority(b.element.scope))
                if left != right { return left < right }
                let order = a.element.name.compare(b.element.name, options: [.caseInsensitive, .diacriticInsensitive])
                return order != .orderedSame ? order == .orderedAscending : a.offset < b.offset
            }.map { pair in
                let entry = pair.element
                return ChatPickerItem(kind: .skill, name: entry.name, token: "/" + entry.name, description: display(entry.description, 240), argumentHint: nil,
                                      skillCollision: false, scope: entry.scope)
            }
        let skillNames = Set(skills.map(\.name))
        let commands: [ChatPickerItem] = entries.filter { $0.kind == .command && isTokenSafe($0.name) }.map { entry in
            ChatPickerItem(kind: .command, name: entry.name, token: "/" + entry.name, description: display(entry.description, 240),
                           argumentHint: display(entry.argumentHint, 80), skillCollision: skillNames.contains(entry.name), scope: nil)
        }
        let commandNames = Set(commands.map(\.name))
        return Array(ranked(commands, query: query).prefix(resultLimit)) + Array(ranked(skills.filter { !commandNames.contains($0.name) }, query: query).prefix(resultLimit))
    }

    private static func display(_ text: String?, _ limit: Int) -> String? {
        guard let text else { return nil }
        let shown = ChatJSText.displayText(text, maxLength: limit)
        return shown.isEmpty ? nil : shown
    }

    // MARK: picking

    /// Replaces the typed `/token` before the caret with the item's token and one space (NC/native-chat-picker-items.ts:276-293).
    public static func apply(draft: String, caret: Int, item: ChatPickerItem) -> (draft: String, caret: Int)? {
        let units = Array(draft.utf16)
        let at = min(max(caret, 0), units.count)
        let before = Array(units[0..<at])
        guard let query = leadingQuery(before) ?? midPromptQuery(before) else { return nil }
        let tokenStart = before.count - ChatJSText.length(query) - 1
        let head = String(decoding: before[0..<tokenStart], as: UTF16.self) + item.token + " "
        return (head + String(decoding: units[at...], as: UTF16.self), ChatJSText.length(head))
    }

    /// The click on the mention hint: the token becomes `@<query> ` (NC/native-chat-composer-state.ts:178-185).
    public static func applyMention(draft: String, caret: Int, query: String) -> (draft: String, caret: Int)? {
        let units = Array(draft.utf16)
        let at = min(max(caret, 0), units.count)
        let before = Array(units[0..<at])
        guard let found = mentionQuery(before) else { return nil }
        let tokenStart = before.count - ChatJSText.length(found) - 1
        let head = String(decoding: before[0..<tokenStart], as: UTF16.self) + "@" + query + " "
        return (head + String(decoding: units[at...], as: UTF16.self), ChatJSText.length(head))
    }

    /// True when one edit both removed and inserted text across the dismissed token (NC/native-chat-composer-state.ts:128-165): a wholesale
    /// replacement is a new trigger even though a trigger character lands on the same position.
    public static func editReplacesTriggerToken(previous: String, next: String, triggerKey: String) -> Bool {
        guard let colon = triggerKey.firstIndex(of: ":"), let position = Int(triggerKey[triggerKey.index(after: colon)...]), previous != next else { return false }
        let old = Array(previous.utf16), new = Array(next.utf16)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let removed = old.count - prefix - suffix, inserted = new.count - prefix - suffix
        if removed == 0 || inserted == 0 { return false }
        var tokenEnd = position + 1
        while tokenEnd < old.count, !ChatJSText.isWhitespace(old[tokenEnd]) { tokenEnd += 1 }
        return prefix < tokenEnd && old.count - suffix > position
    }
}

/// What the text before the caret asks the composer to show (Orca `ComposerAutocomplete`).
public enum ChatAutocomplete: Equatable {
    case none
    case slash(Slash)
    case mention(query: String)
    /// `/resume <text>`: the chat folder's conversations, filtered by the text.
    case conversations(Conversations)

    public struct Conversations: Equatable {
        public enum Status: Equatable { case loading, none, noMatch(String) }
        /// `resume` or `continue`, lower-cased.
        public var command: String
        public var query: String
        public var triggerKey: String
        /// Why no row is shown, or nil when rows are.
        public var status: Status?
        public var items: [ChatPickerItem]
    }

    /// The key the Esc dismissal remembers.
    public var triggerKey: String? {
        switch self {
        case .slash(let value): return value.triggerKey
        case .conversations(let value): return value.triggerKey
        default: return nil
        }
    }

    /// `^/(resume|continue)[ \t]+([^\n]*)$` on the whole draft, case-insensitive, with the caret after the first space or tab.
    static func conversationsQuery(draft units: [UInt16], caret: Int) -> (command: String, query: String)? {
        for name in ["resume", "continue"] {
            let prefix = Array(("/" + name).utf16)
            guard units.count > prefix.count, caret > prefix.count else { continue }
            let head = units[0..<prefix.count].map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }
            guard head == prefix, units[prefix.count] == 0x20 || units[prefix.count] == 0x09 else { continue }
            var index = prefix.count
            while index < units.count, units[index] == 0x20 || units[index] == 0x09 { index += 1 }
            let rest = units[index...]
            guard !rest.contains(where: { $0 == 0x0A || $0 == 0x0D || $0 == 0x2028 || $0 == 0x2029 }) else { return nil }
            return (name, String(decoding: rest, as: UTF16.self))
        }
        return nil
    }

    public struct Slash: Equatable {
        /// The typed token without its slash.
        public var query: String
        public var triggerKey: String
        /// A leading token can dispatch; a mid-prompt one is part of the sentence and only completes.
        public var dispatchable: Bool
        public var items: [ChatPickerItem]
    }

    /// NC/native-chat-composer-state.ts:61-109: a leading `/` first, then a mention, then a mid-prompt `/`.
    public static func derive(draft: String, caret: Int, entries: [ChatCommandEntry], dismissedKey: String?, resume: [ChatResumeRow]? = nil) -> ChatAutocomplete {
        let units = Array(draft.utf16)
        let before = Array(units[0..<min(max(caret, 0), units.count)])
        if let found = conversationsQuery(draft: units, caret: caret) {
            let key = "resume:0"
            if dismissedKey == key { return .none }
            var status: Conversations.Status?
            var items: [ChatPickerItem] = []
            if let resume {
                let shown = ChatResume.search(resume, found.query)
                items = shown.map { row in
                    ChatPickerItem(kind: .conversation, name: row.title, token: row.id, description: row.subtitle, argumentHint: nil, skillCollision: false,
                                   scope: nil, conversationId: row.id)
                }
                if resume.isEmpty { status = Conversations.Status.none }
                else if shown.isEmpty { status = .noMatch(ChatJSText.trimmed(found.query)) }
            } else {
                status = .loading
            }
            return .conversations(Conversations(command: found.command, query: found.query, triggerKey: key, status: status, items: items))
        }
        func slash(_ query: String, _ position: Int) -> ChatAutocomplete {
            let key = "/:\(position)"
            if dismissedKey == key { return .none }
            return .slash(Slash(query: query, triggerKey: key, dispatchable: position == 0, items: ChatPicker.items(entries: entries, query: query)))
        }
        if let query = ChatPicker.leadingQuery(before) { return slash(query, 0) }
        if let query = ChatPicker.mentionQuery(before) { return .mention(query: query) }
        if let query = ChatPicker.midPromptQuery(before) { return slash(query, before.count - ChatJSText.length(query) - 1) }
        return .none
    }
}

/// The picker's state in a composer: the catalog, the last text, which trigger Esc dismissed and the active row. One value, no view in it.
public struct ChatAutocompleteState: Equatable {
    public private(set) var current: ChatAutocomplete = .none
    public private(set) var active = 0
    public private(set) var entries: [ChatCommandEntry]
    private var dismissed: String?
    private var text = ""
    private var caret = 0
    /// The last refresh was a marked one: the next unmarked one must run even for the same text.
    private var refreshOwed = false
    /// The conversations `/resume` loaded for the open list; nil until they arrive (and while no list is open).
    public private(set) var resumeRows: [ChatResumeRow]?
    private var listOpen = false
    private var listWanted = false
    private var listClosed = false

    public init(entries: [ChatCommandEntry] = ChatCatalog.fallback) { self.entries = entries }

    /// The text or the caret changed (Orca `handleDraftOrCaretChange` and `deriveComposerAutocomplete`). While text is marked the picker is
    /// hidden and nothing about it changes. A dismissal ends when an edit leaves its token or replaces it wholesale.
    public mutating func refresh(text newText: String, caret newCaret: Int, marked: Bool) {
        // The same text and caret again (a layout pass re-sets the selection): nothing changed, so the active row stays where the keys put it.
        if !marked, newText == text, newCaret == caret, !refreshOwed { return }
        refreshOwed = false
        if marked {
            text = newText; caret = newCaret; current = .none; refreshOwed = true
            return
        }
        if let key = dismissed {
            if ChatPicker.editReplacesTriggerToken(previous: text, next: newText, triggerKey: key) {
                dismissed = nil
            } else if ChatAutocomplete.derive(draft: newText, caret: newCaret, entries: entries, dismissedKey: nil, resume: resumeRows).triggerKey == key {
                // still the dismissed trigger
            } else {
                dismissed = nil
            }
        }
        // An unchanged text and caret returned at the top, so what reaches here is a new text or a moved caret: a new token, and the first row.
        text = newText; caret = newCaret
        let wasOpen = listOpen
        current = ChatAutocomplete.derive(draft: newText, caret: newCaret, entries: entries, dismissedKey: dismissed, resume: wasOpen ? resumeRows : nil)
        let nowOpen = conversations != nil
        if nowOpen && !wasOpen { resumeRows = nil; listWanted = true }
        if wasOpen && !nowOpen { resumeRows = nil; listClosed = true }
        listOpen = nowOpen
        active = firstActive()
    }

    /// The conversations list is wanted: the mode was just entered. True once per entry.
    public mutating func takeListWanted() -> Bool { defer { listWanted = false }; return listWanted }
    /// The mode was just left (closed, dismissed or the draft changed): a load still in flight is of no use. True once per exit.
    public mutating func takeListClosed() -> Bool { defer { listClosed = false }; return listClosed }

    /// The loaded conversations for the open list, or nil to show "Loading" again.
    public mutating func setResumeRows(_ rows: [ChatResumeRow]?) {
        guard listOpen else { return }
        resumeRows = rows
        guard case .conversations = current else { return }
        current = ChatAutocomplete.derive(draft: text, caret: caret, entries: entries, dismissedKey: dismissed, resume: resumeRows)
        active = 0
    }

    /// The row of the item with this id in the rows now shown.
    private func index(of id: String?) -> Int? {
        guard let id else { return nil }
        return items.firstIndex { $0.id == id }
    }

    /// The rows now shown: the commands and skills, or the conversations.
    public var items: [ChatPickerItem] {
        switch current {
        case .slash(let value): return value.items
        case .conversations(let value): return value.items
        default: return []
        }
    }

    /// The row Enter and Tab act on at first: the one whose name is the typed query, whole (case-insensitive; the commands group is looked at first),
    /// else row 0. Orca takes row 0, which here would turn `/review` into `/ultrareview` when that command's name contains the query (a Clawd
    /// deviation under D17: nothing runs that was not typed).
    private func firstActive() -> Int {
        guard let slash else { return 0 }
        let wanted = slash.query.lowercased()
        return !wanted.isEmpty ? (slash.items.firstIndex { $0.name.lowercased() == wanted } ?? 0) : 0
    }

    /// The catalog changed under an open picker: the rows are made again for the same text.
    public mutating func setEntries(_ new: [ChatCommandEntry]) {
        guard new != entries else { return }
        let kept = activeItem?.id                                  // the catalog changes under the user's hands: the row they chose stays chosen
        entries = new
        if case .none = current { return }
        current = ChatAutocomplete.derive(draft: text, caret: caret, entries: entries, dismissedKey: dismissed, resume: resumeRows)
        active = index(of: kept) ?? firstActive()
    }

    public var slash: ChatAutocomplete.Slash? { if case .slash(let value) = current { return value }; return nil }
    public var conversations: ChatAutocomplete.Conversations? { if case .conversations(let value) = current { return value }; return nil }
    public var isOpen: Bool { slash != nil || conversations != nil }
    public var activeItem: ChatPickerItem? { items.indices.contains(active) ? items[active] : items.first }

    /// Down and Up wrap (NC/use-native-chat-composer-keydown.ts:68-77). False when there is nothing to move over.
    public mutating func move(_ delta: Int) -> Bool {
        let count = items.count
        guard count > 0 else { return false }
        active = ((active + delta) % count + count) % count
        return true
    }

    /// Esc: the picker stays closed for this trigger position until an edit leaves the token or replaces it.
    public mutating func dismiss() {
        guard let key = current.triggerKey else { return }
        dismissed = key
        current = .none
        if listOpen { listClosed = true; listOpen = false; resumeRows = nil }
    }
}
