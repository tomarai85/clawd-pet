import Foundation

/// JavaScript's text rules as Orca's catalog code uses them (`\s`, `trim`, `String.length`), so a name or a description is judged the way Orca
/// judges it: the white space is JavaScript's (it has U+FEFF and U+00A0 and not U+0085), and a length is a count of UTF-16 units.
public enum ChatJSText {
    public static func isWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
        default: return false
        }
    }
    public static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool { scalar.value <= 0xFFFF && isWhitespace(UInt16(scalar.value)) }
    public static func isLineTerminator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || scalar == "\r" || scalar.value == 0x2028 || scalar.value == 0x2029
    }

    public static func trimmed(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, isWhitespace(first) { scalars.removeFirst() }
        while let last = scalars.last, isWhitespace(last) { scalars.removeLast() }
        return String(scalars)
    }
    public static func trimmedEnd(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let last = scalars.last, isWhitespace(last) { scalars.removeLast() }
        return String(scalars)
    }
    /// `value.replace(/\s+/gu, ' ').trim()`
    public static func collapsed(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var inRun = false
        for scalar in text.unicodeScalars {
            if isWhitespace(scalar) {
                if !inRun { out.append(" ") }
                inRun = true
            } else {
                out.append(scalar)
                inRun = false
            }
        }
        return trimmed(String(out))
    }
    public static func hasWhitespace(_ text: String) -> Bool { text.unicodeScalars.contains(where: isWhitespace) }
    public static func length(_ text: String) -> Int { text.utf16.count }

    /// Orca's `isSafeDisplayCharacter` (SH/skill-display-text.ts:6-22): no control, C1, zero-width, bidi or line-separator code point.
    public static func isSafeDisplay(_ scalar: Unicode.Scalar) -> Bool {
        let code = scalar.value
        return !(code <= 0x1F || (code >= 0x7F && code <= 0x9F) || code == 0x200B || code == 0x200E || code == 0x200F || code == 0x061C
                 || code == 0x2060 || code == 0xFEFF || code == 0x2028 || code == 0x2029 || (code >= 0x202A && code <= 0x202E)
                 || (code >= 0x2066 && code <= 0x2069))
    }
    /// `stripUnsafeDisplayCharacters(value).slice(0, maxLength)`, cut on a scalar so no pair is split.
    public static func displayText(_ text: String, maxLength: Int) -> String {
        var out = String.UnicodeScalarView()
        var units = 0
        for scalar in text.unicodeScalars where isSafeDisplay(scalar) {
            let width = scalar.value > 0xFFFF ? 2 : 1
            if units + width > maxLength { break }
            out.append(scalar)
            units += width
        }
        return String(out)
    }
}

public enum ChatCommandKind: String, Codable, Equatable { case command, skill }

/// One row of the `/` catalog: what a session reported it can run (Orca `AgentSessionSlashCommand`), with the text its descriptor carried.
public struct ChatCommandEntry: Codable, Equatable {
    public var name: String
    public var kind: ChatCommandKind
    public var description: String?
    public var argumentHint: String?
    /// "Personal", "Project", "Plugin" or "Built-in": derived from the raw descriptor (Q9, N6), never read from a folder.
    public var scope: String?
    public init(name: String, kind: ChatCommandKind, description: String? = nil, argumentHint: String? = nil, scope: String? = nil) {
        self.name = name; self.kind = kind; self.description = description; self.argumentHint = argumentHint; self.scope = scope
    }
}

/// One descriptor of a `commands_changed` frame after Orca's validation (MC/claude-slash-command-catalog.ts:46-83).
public struct ChatCommandDescriptor: Equatable {
    public var name: String
    public var description: String?
    public var argumentHint: String?
    public var scope: String?
    public init(name: String, description: String? = nil, argumentHint: String? = nil, scope: String? = nil) {
        self.name = name; self.description = description; self.argumentHint = argumentHint; self.scope = scope
    }
}

/// What a catalog-carrying frame holds. Init carries name arrays; `commands_changed` carries descriptors (and, in Orca's reading, may carry
/// name arrays too).
public struct ChatCatalogFrame: Equatable {
    public enum Body: Equatable {
        case names(slashCommands: [String], skills: [String], terminal: [String])
        case descriptors([ChatCommandDescriptor])
    }
    public var body: Body
    public init(_ body: Body) { self.body = body }
}

/// Orca's validation of the catalog's text (MC/claude-slash-command-catalog.ts:5-44, 60-62).
public enum ChatCatalogRules {
    public static let maxCommands = 512
    public static let maxNameLength = 200
    public static let maxDescriptionLength = 200
    public static let maxArgumentHintLength = 100

    /// A name: 1-200 UTF-16 units after the trim, no white space inside.
    public static func commandName(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let name = ChatJSText.trimmed(text)
        let length = ChatJSText.length(name)
        return length > 0 && length <= maxNameLength && !ChatJSText.hasWhitespace(name) ? name : nil
    }
    /// The distinct valid names of an array in order, at most 512 of them (the loop stops at the 513th distinct one).
    public static func names(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        var seen = Set<String>(), ordered: [String] = []
        for entry in array {
            if seen.count >= maxCommands { break }
            if let name = commandName(entry), seen.insert(name).inserted { ordered.append(name) }
        }
        return ordered
    }
    /// A row's text: a value over its limit is dropped, not cut; runs of white space collapse; an empty result is nothing.
    public static func rowText(_ value: Any?, maxLength: Int) -> String? {
        guard let text = value as? String, ChatJSText.length(text) <= maxLength else { return nil }
        let collapsed = ChatJSText.collapsed(text)
        return !collapsed.isEmpty && ChatJSText.length(collapsed) <= maxLength ? collapsed : nil
    }
    /// The scope label of a descriptor, read from the raw text before the length drop (Q9; an inference, N6).
    public static func scope(name: String, rawDescription: Any?, builtin: Any?) -> String? {
        if let text = rawDescription as? String {
            let end = ChatJSText.trimmedEnd(text)
            if end.hasSuffix("(user)") { return "Personal" }
            if end.hasSuffix("(project)") { return "Project" }
        }
        if name.contains(":") { return "Plugin" }
        if let flag = builtin as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue { return "Built-in" }
        return nil
    }
    /// The distinct valid descriptors of an array, in order. A repeated name keeps its first text.
    public static func descriptors(_ value: Any?) -> [ChatCommandDescriptor] {
        guard let array = value as? [Any] else { return [] }
        var seen = Set<String>(), ordered: [ChatCommandDescriptor] = []
        var position: [String: Int] = [:]
        for entry in array {
            if seen.count >= maxCommands { break }
            guard let object = entry as? [String: Any], let name = commandName(object["name"]) else { continue }
            let description = rowText(object["description"], maxLength: maxDescriptionLength)
            let hint = rowText(object["argumentHint"], maxLength: maxArgumentHintLength)
            let label = scope(name: name, rawDescription: object["description"], builtin: object["builtin"])
            if seen.insert(name).inserted {
                position[name] = ordered.count
                ordered.append(ChatCommandDescriptor(name: name, description: description, argumentHint: hint, scope: label))
            } else if let index = position[name] {
                ordered[index].description = ordered[index].description ?? description
                ordered[index].argumentHint = ordered[index].argumentHint ?? hint
                ordered[index].scope = ordered[index].scope ?? label
            }
        }
        return ordered
    }
}

/// The `/` catalog (Orca `ClaudeSlashCommandCatalog`, MC/claude-slash-command-catalog.ts:85-190): how each frame replaces the list, and the
/// row text that survives a name-only frame. `entries` is nil until a session or the saved file has reported one.
public struct ChatCatalog: Equatable {
    /// The four host commands offered before any report (SH/structured-agent-session-composer.ts:10-28): model, effort, clear, compact.
    public static let fallback: [ChatCommandEntry] = [
        ChatCommandEntry(name: "model", kind: .command, description: "Choose the model"),
        ChatCommandEntry(name: "effort", kind: .command, description: "Choose reasoning effort"),
        ChatCommandEntry(name: "clear", kind: .command, description: "Start a fresh conversation"),
        ChatCommandEntry(name: "compact", kind: .command, description: "Compact conversation context"),
        resumeEntry,
    ]
    /// The CLI's own `/resume` words (cc@262344706). A headless CLI does not list it, so Clawd offers it as a host command.
    public static let resumeEntry = ChatCommandEntry(name: "resume", kind: .command, description: "Resume a previous conversation",
                                                     argumentHint: "[conversation id or search term]")

    public private(set) var entries: [ChatCommandEntry]?
    private var hasClassification = false
    private var hidden = Set<String>()
    private var commandNames = Set<String>()
    private var details: [String: ChatCommandDescriptor] = [:]

    public init() {}
    /// A catalog seeded from the saved file: its kinds count as a classification, and its row text survives the next name-only frame.
    public init(saved: [ChatCommandEntry]) {
        entries = saved
        hasClassification = true
        commandNames = Set(saved.filter { $0.kind == .command }.map(\.name))
        for entry in saved where entry.description != nil || entry.argumentHint != nil || entry.scope != nil {
            details[entry.name] = ChatCommandDescriptor(name: entry.name, description: entry.description, argumentHint: entry.argumentHint, scope: entry.scope)
        }
    }

    /// What the picker lists: the session's report, else the saved one, else the four host commands.
    /// The `resume` row is Clawd's: added once when the report has none, never saved in the catalog file.
    public var pickerEntries: [ChatCommandEntry] {
        let list = entries ?? Self.fallback
        return list.contains { $0.name == "resume" } ? list : list + [Self.resumeEntry]
    }

    private func describe(_ list: [ChatCommandEntry]) -> [ChatCommandEntry] {
        list.map { entry in
            var described = entry
            if let detail = details[entry.name] {
                described.description = detail.description
                described.argumentHint = detail.argumentHint
                described.scope = detail.scope
            }
            return described
        }
    }

    /// True when this frame replaced the catalog with a different one.
    @discardableResult
    public mutating func observe(_ frame: ChatCatalogFrame) -> Bool {
        let next: [ChatCommandEntry]
        switch frame.body {
        case .names(let slashCommands, let skills, let terminal):
            hasClassification = true
            hidden = Set(terminal)
            let skillNames = Set(skills)
            next = describe(slashCommands.filter { !hidden.contains($0) }.map { ChatCommandEntry(name: $0, kind: skillNames.contains($0) ? .skill : .command) })
            commandNames = Set(next.filter { $0.kind == .command }.map(\.name))
        case .descriptors(let descriptors):
            details = Dictionary(descriptors.filter { $0.description != nil || $0.argumentHint != nil || $0.scope != nil }.map { ($0.name, $0) },
                                 uniquingKeysWith: { first, _ in first })
            next = describe(descriptors.map(\.name).filter { !hidden.contains($0) }.map { name in
                ChatCommandEntry(name: name, kind: hasClassification ? (commandNames.contains(name) ? .command : .skill) : .command)
            })
        }
        if entries == next { return false }
        entries = next
        return true
    }
}

/// chat-private/chat-catalog.json: the last catalog a session reported (D3). Rows hold command names, row text and scope labels only: no chat
/// text and no path. Written only when the catalog changes. Every field is optional under `version: 1`.
public struct ChatCatalogFile: Codable, Equatable {
    public var version: Int?
    public var entries: [ChatCommandEntry]?
    public init(entries: [ChatCommandEntry]?) { version = 1; self.entries = entries }
}

public final class ChatCatalogStore {
    public static let fileName = ChatComposerStore.directory + "/chat-catalog.json"
    /// 512 rows of ordinary text fit with room to spare. Control and non-ASCII text escape to 6 bytes a unit, so the worst case (about 1.5 MB) can pass
    /// it: `save` then refuses once, shows nothing, and the next start offers an older file or the four host commands. No data is lost.
    public static let capBytes = 1024 * 1024
    private static let scopes: Set<String> = ["Personal", "Project", "Plugin", "Built-in"]

    private let state: OwnState
    private let log: (String) -> Void
    public private(set) var saveFailed = false

    public init(state: OwnState, log: @escaping (String) -> Void) { self.state = state; self.log = log }

    /// The saved rows, each checked again under Orca's rules (the file is the user's to edit); nil when there is no usable file.
    public func load() -> [ChatCommandEntry]? {
        var info = stat()
        guard let path = try? state.url(Self.fileName).path, lstat(path, &info) == 0 else { log("CHAT catalog read=none"); return nil }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= Self.capBytes, let data = try? ReadOnlyFile.data(path, limit: Self.capBytes),
              let file = try? JSONDecoder().decode(ChatCatalogFile.self, from: data), file.version == 1 || file.version == nil,
              let rows = file.entries else { log("CHAT catalog read=bad"); return nil }
        var seen = Set<String>(), kept: [ChatCommandEntry] = []
        for row in rows {
            if seen.count >= ChatCatalogRules.maxCommands { break }
            guard let name = ChatCatalogRules.commandName(row.name), name == row.name, seen.insert(name).inserted else { continue }
            kept.append(ChatCommandEntry(name: name, kind: row.kind, description: ChatCatalogRules.rowText(row.description, maxLength: ChatCatalogRules.maxDescriptionLength),
                                         argumentHint: ChatCatalogRules.rowText(row.argumentHint, maxLength: ChatCatalogRules.maxArgumentHintLength),
                                         scope: row.scope.flatMap { Self.scopes.contains($0) ? $0 : nil }))
        }
        log("CHAT catalog read=ok n=\(kept.count)")
        return kept
    }

    public func save(_ entries: [ChatCommandEntry]) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            guard let data = try? encoder.encode(ChatCatalogFile(entries: entries)), data.count <= Self.capBytes else { throw OwnStorageFailure.outOfSpace }
            try state.writePrivate(data, to: Self.fileName)
            saveFailed = false
            log("CHAT catalog saved=ok n=\(entries.count)")
        } catch {
            if !saveFailed { log("CHAT catalog saved=failed n=\(entries.count)") }
            saveFailed = true
        }
    }
}
