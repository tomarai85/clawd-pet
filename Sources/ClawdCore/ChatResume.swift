import Foundation
import Darwin

/// One conversation of the chat's folder as `/resume` lists it (Claude Code 2.1.316's list, read from its own project folder).
public struct ChatResumeRow: Equatable {
    public var id: String
    public var title: String
    /// The CLI's second line: relative time, branch, size, tag, agent, PR.
    public var subtitle: String
    /// The folder the list was made for (`realpath` of the chat folder at load time).
    public var folder: String
    public var modified: Date
    public var branch: String?
    public var tag: String?
    public var pr: String?
    public init(id: String, title: String, subtitle: String, folder: String, modified: Date, branch: String? = nil, tag: String? = nil, pr: String? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.folder = folder; self.modified = modified
        self.branch = branch; self.tag = tag; self.pr = pr
    }
}

/// `/resume`'s reading of Claude Code's project folder and live-session registry. Pure: it reads only the roots it is given, treats every byte
/// of both as untrusted, and never starts a process. The environment's default roots list nothing; the production roots are built in the
/// runtime wiring.
public enum ChatResume {
    // MARK: roots

    public struct Roots: Equatable {
        /// `<claude folder>/projects`, or nil: nothing is listed.
        public var projects: String?
        /// `<claude folder>/sessions`, or nil: no live holder is known.
        public var sessions: String?
        public init(projects: String?, sessions: String?) { self.projects = projects; self.sessions = sessions }
        public static let none = Roots(projects: nil, sessions: nil)
        /// The folders under a home folder the way Claude Code's child sees them (no `CLAUDE_CONFIG_DIR`).
        public init(home: String) { self.init(projects: home + "/.claude/projects", sessions: home + "/.claude/sessions") }
        /// The same source as the child's `HOME` (ChatSession.environment): the passwd record.
        public static func production() -> Roots {
            guard let record = getpwuid(getuid()) else { return .none }
            return Roots(home: String(cString: record.pointee.pw_dir))
        }
    }

    // MARK: limits (the CLI's, and the caps Clawd adds)

    public static let sampleBytes = 64 * 1024
    public static let visibleRows = 50
    public static let maxNames = 5000
    public static let maxReads = 200
    public static let maxTitle = 200
    public static let maxSmall = 80

    // MARK: the words (the CLI's)

    public static let heading = "Resume session"
    public static let loadingText = "Loading conversations\u{2026}"
    public static let noneText = "No conversations found to resume."
    public static func noMatchText(_ query: String) -> String { "No sessions match \"\(query)\"." }
    public static func notFoundText(_ what: String) -> String { "Session \(what) was not found." }
    public static let otherFolderText = "This conversation is from a different directory."
    public static let heldText = "Can't open \u{2014} this session is running in another terminal"
    public static let unknownHolderText = "Couldn't check whether this session is open in another terminal. Try again."
    public static let notAvailableText = "Resume is available in the chat view."

    // MARK: ids and folders

    /// The CLI's UUID rule, case-insensitive.
    public static func isSessionId(_ text: String) -> Bool {
        let units = Array(text.utf8)
        guard units.count == 36 else { return false }
        for (index, unit) in units.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                if unit != 0x2D { return false }
            } else if !((0x30...0x39).contains(unit) || (0x61...0x66).contains(unit) || (0x41...0x46).contains(unit)) {
                return false
            }
        }
        return true
    }

    /// Claude Code's project folder name for a path: every UTF-16 unit outside `[a-zA-Z0-9]` becomes `-`; over 200 units, the first 200 plus `-`
    /// plus base 36 of the absolute value of the 32-bit hash `h = (h << 5) - h + unit` over the path's units (cc@252201431 `EL`, cc@251225573).
    public static func slug(_ path: String) -> String {
        let units = Array(path.utf16)
        let clean = String(decoding: units.map { unit -> UInt16 in
            (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) ? unit : 0x2D
        }, as: UTF16.self)
        guard units.count > 200 else { return clean }
        var hash: Int32 = 0
        for unit in units { hash = (hash << 5) &- hash &+ Int32(unit) }
        let magnitude = abs(Int64(hash))
        return String(decoding: Array(clean.utf16.prefix(200)), as: UTF16.self) + "-" + String(magnitude, radix: 36)
    }

    private static func trimmedSlash(_ path: String) -> String {
        var text = path
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// `realpath` of the folder, or the folder itself when it cannot be resolved; a trailing slash is trimmed.
    public static func resolvedFolder(_ folder: String) -> String {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX) + 1)
        if realpath(folder, &buffer) != nil { return trimmedSlash(String(cString: buffer)) }
        return trimmedSlash(folder)
    }

    /// The spellings of the folder Claude Code may have used for its project folder: the resolved path and its NFC form (macOS hands out NFD).
    static func spellings(_ folder: String) -> [String] {
        let resolved = resolvedFolder(folder)
        // Swift's == treats NFC and NFD as equal, and the two spellings name different project folders: they are told apart by their scalars.
        var out: [String] = []
        for spelling in [resolved, resolved.precomposedStringWithCanonicalMapping, trimmedSlash(folder)]
        where !out.contains(where: { $0.unicodeScalars.elementsEqual(spelling.unicodeScalars) }) { out.append(spelling) }
        return out
    }

    /// The project folders to read for a chat folder: one per distinct slug.
    public static func projectDirectories(folder: String, roots: Roots) -> [String] {
        guard let base = roots.projects else { return [] }
        var seen = Set<String>(), out: [String] = []
        for spelling in spellings(folder) where seen.insert(slug(spelling)).inserted { out.append(base + "/" + slug(spelling)) }
        return out
    }

    /// Whether `<project folder>/<id>.jsonl` is a regular file for this chat folder (the pick's check).
    public static func conversationExists(id: String, folder: String, roots: Roots) -> Bool {
        guard isSessionId(id) else { return false }
        for directory in projectDirectories(folder: folder, roots: roots) {
            var info = stat()
            if lstat(directory + "/" + id + ".jsonl", &info) == 0, info.st_mode & S_IFMT == S_IFREG { return true }
        }
        return false
    }

    // MARK: listing

    public struct Listing: Equatable {
        public var rows: [ChatResumeRow] = []
        /// UUID-named regular files found, and files whose head and tail were read.
        public var files = 0
        public var read = 0
        public init(rows: [ChatResumeRow] = [], files: Int = 0, read: Int = 0) { self.rows = rows; self.files = files; self.read = read }
    }

    /// Reads `count` bytes of a file at `offset`; nil when it cannot be opened safely or is not a regular file.
    public typealias Reader = (_ path: String, _ offset: Int64, _ count: Int) -> Data?

    public static let defaultReader: Reader = { path, offset, count in
        guard let file = try? ReadOnlyFile(path, flags: O_RDONLY | O_NOFOLLOW, nonBlocking: true), let info = try? file.metadata(),
              info.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? file.read(offset: offset, count: count)
    }

    /// The CLI's list for this folder, seen from an SDK process when `includeSDK` (Clawd's child is one, so its own chats are listed): the
    /// UUID-named regular files of the project folder, newest first; the head and tail of each until 50 rows are visible or 200 files were read.
    public static func list(folder: String, roots: Roots, excluding current: String?, includeSDK: Bool = true, now: Date = Date(),
                            reader: Reader = defaultReader, cancelled: () -> Bool = { false }) -> Listing {
        var listing = Listing()
        let resolved = resolvedFolder(folder)
        let folders = Set(spellings(folder))
        let skip = current?.lowercased()
        var found: [(id: String, path: String, size: Int64, modified: Date)] = []
        var byId: [String: Int] = [:]
        var names = 0
        for directory in projectDirectories(folder: folder, roots: roots) {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for name in entries where name.hasSuffix(".jsonl") {
                names += 1
                if names > maxNames { break }
                let id = String(name.dropLast(6))
                guard isSessionId(id) else { continue }
                var info = stat()
                guard lstat(directory + "/" + name, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
                let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
                let record = (id: id, path: directory + "/" + name, size: Int64(info.st_size), modified: modified)
                if let index = byId[id.lowercased()] {
                    if found[index].modified < modified { found[index] = record }
                } else {
                    byId[id.lowercased()] = found.count
                    found.append(record)
                }
            }
        }
        listing.files = found.count
        found.sort { $0.modified != $1.modified ? $0.modified > $1.modified : $0.id < $1.id }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for file in found {
            if cancelled() || listing.rows.count >= visibleRows || listing.read >= maxReads { break }
            if file.id.lowercased() == skip { continue }
            listing.read += 1
            let want = Int(min(file.size, Int64(sampleBytes)))
            guard let head = reader(file.path, 0, want) else { continue }
            let tail = file.size > Int64(sampleBytes) ? reader(file.path, file.size - Int64(sampleBytes), sampleBytes) ?? Data() : head
            guard let row = row(id: file.id, size: file.size, modified: file.modified, head: head, tail: tail, tailIsPartial: file.size > Int64(sampleBytes),
                                folders: folders, folder: resolved, includeSDK: includeSDK, now: now, parse: { text in
                                    formatter.date(from: text) ?? plain.date(from: text)
                                }) else { continue }
            listing.rows.append(row)
        }
        listing.rows.sort { $0.modified > $1.modified }
        return listing
    }

    // MARK: one file

    private static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private static func lines(_ text: String, dropFirst: Bool) -> [Substring] {
        var parts = text.split(separator: "\n", omittingEmptySubsequences: true)
        if dropFirst, !parts.isEmpty { parts.removeFirst() }
        return parts
    }

    private static func row(id: String, size: Int64, modified: Date, head headData: Data, tail tailData: Data, tailIsPartial: Bool,
                            folders: Set<String>, folder: String, includeSDK: Bool, now: Date, parse: (String) -> Date?) -> ChatResumeRow? {
        let head = text(headData), tail = text(tailData)
        let headLines = lines(head, dropFirst: false)
        // The tail starts inside a line when the file is longer than the sample: its first line is a fragment.
        let tailLines = lines(tail, dropFirst: tailIsPartial)
        let hasConversation = { (list: [Substring]) in list.contains { isType($0, "user") || isType($0, "assistant") } }
        guard hasConversation(headLines) || hasConversation(tailLines) else { return nil }
        if head.contains("\"isSidechain\":true") || head.contains("\"isSidechain\": true") { return nil }
        if let team = stringField("teamName", in: head, last: false), !team.isEmpty { return nil }
        let kind = stringField("sessionKind", in: head, last: false)
        if kind == "daemon" || kind == "daemon-worker" { return nil }
        if !includeSDK {
            if let entrypoint = stringField("entrypoint", in: head, last: false), ["sdk-cli", "sdk-ts", "sdk-py"].contains(entrypoint) { return nil }
            if headLines.contains(where: { isType($0, "user") && $0.contains("<command-name>/loop</command-name>") }) { return nil }
        }
        if let cwd = stringField("cwd", in: head, last: false) {
            let trimmed = trimmedSlash(cwd)
            guard folders.contains(trimmed) || folders.contains(trimmed.precomposedStringWithCanonicalMapping) else { return nil }
        }
        let tailText = tailLines.joined(separator: "\n")
        func pick(_ key: String) -> String? { stringField(key, in: tailText, last: true) ?? stringField(key, in: head, last: true) }
        let custom = pick("customTitle"), ai = pick("aiTitle")
        let summary = tailLines.filter { isType($0, "summary") }.compactMap { stringField("summary", in: String($0), last: true) }.last
        let lastPrompt = stringField("lastPrompt", in: tailText, last: true)
        let branch = pick("gitBranch"), tag = stringField("tag", in: tailText, last: true), agent = pick("agentSetting")
        var title: String?
        for candidate in [custom, ai, summary] {
            if let candidate, !ChatJSText.collapsed(candidate).isEmpty { title = clip(candidate, ellipsis: false); break }
        }
        if title == nil, let lastPrompt, !ChatJSText.collapsed(lastPrompt).isEmpty { title = clip(lastPrompt, ellipsis: true) }
        if title == nil, let first = firstPrompt(headLines), !first.isEmpty { title = clip(first, ellipsis: true) }
        let shownBranch = branch.map { ChatJSText.displayText($0, maxLength: maxSmall) }.flatMap { $0.isEmpty ? nil : $0 }
        let shownTag = tag.map { ChatJSText.displayText($0, maxLength: maxSmall) }.flatMap { $0.isEmpty ? nil : $0 }
        let shownAgent = agent.map { ChatJSText.displayText($0, maxLength: maxSmall) }.flatMap { $0.isEmpty ? nil : $0 }
        var pr: String?
        if let number = integerField("prNumber", in: tailText), number > 0 {
            let repository = stringField("prRepository", in: tailText, last: true).map { ChatJSText.displayText($0, maxLength: maxSmall) } ?? ""
            pr = repository.isEmpty ? "PR #\(number)" : "\(repository)#\(number)"
        }
        var when = modified
        if let stamp = tailLines.last(where: { isType($0, "user") || isType($0, "assistant") }).flatMap({ stringField("timestamp", in: String($0), last: true) }),
           let date = parse(stamp) {
            when = min(date, modified)
        }
        var pieces = [relative(when, now: now)]
        if let shownBranch { pieces.append(shownBranch) }
        pieces.append(sizeText(size))
        if let shownTag { pieces.append("#" + shownTag) }
        if let shownAgent { pieces.append("@" + shownAgent) }
        if let pr { pieces.append(pr) }
        return ChatResumeRow(id: id, title: title ?? "(session)", subtitle: pieces.joined(separator: " \u{00B7} "), folder: folder, modified: when,
                             branch: shownBranch, tag: shownTag, pr: pr)
    }

    private static func isType(_ line: Substring, _ type: String) -> Bool {
        line.contains("\"type\":\"\(type)\"") || line.contains("\"type\": \"\(type)\"")
    }

    /// The first real user prompt of the head: not meta, not a compact summary, no tool result, and text that does not start with `<`.
    private static func firstPrompt(_ lines: [Substring]) -> String? {
        for line in lines where isType(line, "user") {
            if line.contains("\"tool_result\"") || line.contains("\"isMeta\":true") || line.contains("\"isMeta\": true")
                || line.contains("\"isCompactSummary\":true") || line.contains("\"isCompactSummary\": true") { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any] else { continue }
            var candidates: [String] = []
            if let content = message["content"] as? String { candidates = [content] }
            else if let blocks = message["content"] as? [[String: Any]] {
                if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { continue }
                candidates = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            }
            for candidate in candidates {
                let flat = ChatJSText.trimmed(candidate)
                if flat.isEmpty || flat.hasPrefix("<") { continue }
                return flat
            }
        }
        return nil
    }

    /// A shown title: no control, bidi or zero-width code point, line breaks as spaces, cut to 200 units (a prompt gets an ellipsis when cut).
    static func clip(_ raw: String, ellipsis: Bool) -> String {
        let spaced = String(String.UnicodeScalarView(raw.unicodeScalars.map { ChatJSText.isLineTerminator($0) ? " " : $0 }))
        let full = ChatJSText.displayText(spaced, maxLength: 1 << 16)
        let shown = ChatJSText.displayText(full, maxLength: maxTitle)
        return ellipsis && ChatJSText.length(full) > maxTitle ? shown + "\u{2026}" : shown
    }

    // MARK: fields (bounded string search, as the CLI reads them)

    /// `"key":"value"` or `"key": "value"`: the first occurrence, or the last. The literal ends at the first quote no backslash escapes; one that
    /// is not closed, or whose escapes do not decode, is absent.
    static func stringField(_ key: String, in text: String, last: Bool) -> String? {
        let bytes = Array(text.utf8)
        var best: String?
        var bestAt = -1
        for pattern in ["\"\(key)\":\"", "\"\(key)\": \""] {
            let needle = Array(pattern.utf8)
            guard bytes.count >= needle.count else { continue }
            var start = 0
            while start <= bytes.count - needle.count {
                guard let at = find(needle, in: bytes, from: start) else { break }
                let valueStart = at + needle.count
                var end = valueStart
                var closed = false
                while end < bytes.count {
                    if bytes[end] == 0x5C { end += 2; continue }
                    if bytes[end] == 0x22 { closed = true; break }
                    end += 1
                }
                if closed, let value = decode(Array(bytes[valueStart..<end])) {
                    if !last { if best == nil || at < bestAt { best = value; bestAt = at }; break }
                    if at > bestAt { best = value; bestAt = at }
                }
                start = closed ? end + 1 : valueStart
            }
        }
        return best
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        var index = from
        while index <= bytes.count - needle.count {
            if bytes[index] == needle[0], bytes[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }

    private static func decode(_ literal: [UInt8]) -> String? {
        if !literal.contains(0x5C) { return String(decoding: literal, as: UTF8.self) }
        let wrapped = Data([0x22] + literal + [0x22])
        return (try? JSONSerialization.jsonObject(with: wrapped, options: .fragmentsAllowed)) as? String
    }

    private static func integerField(_ key: String, in text: String) -> Int? {
        guard let range = text.range(of: "\"\(key)\":", options: .backwards) else { return nil }
        let digits = text[range.upperBound...].drop(while: { $0 == " " }).prefix(12).prefix(while: { $0.isNumber })
        return Int(digits)
    }

    // MARK: the second line

    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// `en`: bytes, KB, MB, GB with one decimal and no ".0".
    static func sizeText(_ bytes: Int64) -> String {
        func number(_ value: Double) -> String {
            let text = String(format: "%.1f", value)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        if bytes < 1024 { return "\(bytes)B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return number(kb) + "KB" }
        let mb = kb / 1024
        if mb < 1024 { return number(mb) + "MB" }
        return number(mb / 1024) + "GB"
    }

    // MARK: search

    /// The CLI's search over the loaded rows: a case-insensitive substring of the title, branch, tag or PR text, or the whole text equal to a row's id.
    public static func search(_ rows: [ChatResumeRow], _ query: String) -> [ChatResumeRow] {
        let wanted = ChatJSText.trimmed(query).lowercased()
        guard !wanted.isEmpty else { return rows }
        return rows.filter { row in
            row.id.lowercased() == wanted
                || [row.title, row.branch, row.tag, row.pr].contains { ($0 ?? "").lowercased().contains(wanted) }
        }
    }

    // MARK: the live-session registry

    public enum Holder: Equatable { case none, held, unknown }

    /// Whether another process holds the conversation: Claude Code's `<sessions>/<pid>.json` records, names `^[0-9]+\.json$` only, each at most 64 KiB.
    /// A record holds the id when its pid is alive, that process started no later than the record file's mtime (a reused pid does not count), it is
    /// not `spare`, and the pid is not one of the session's own children. A live, non-spare record that cannot be read has no `sessionId`: `unknown`.
    public static func liveHolder(id: String, roots: Roots, ownPids: Set<Int32> = [],
                                  identity: (Int32) -> ProcessIdentity? = { ChatProc.identity(of: $0) }) -> Holder {
        guard let base = roots.sessions, let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else { return .none }
        var result = Holder.none
        for name in entries.prefix(maxNames) where name.hasSuffix(".json") {
            let stem = String(name.dropLast(5))
            guard !stem.isEmpty, stem.utf8.count <= 10, stem.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let pid = Int32(stem), pid > 0 else { continue }
            if ownPids.contains(pid) { continue }
            guard let process = identity(pid) else { continue }
            let path = base + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let written = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            let started = Double(process.seconds) + Double(process.microseconds) / 1e6
            if started > written { continue }
            // A live pid's record that is a link, a folder or anything but a regular file of at most 64 KiB cannot be read: unknown, never free.
            guard let file = try? ReadOnlyFile(path, flags: O_RDONLY | O_NOFOLLOW, nonBlocking: true), let opened = try? file.metadata(),
                  opened.st_mode & S_IFMT == S_IFREG, opened.st_size <= 64 * 1024, let data = try? file.read(offset: 0, count: 64 * 1024),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { result = .unknown; continue }
            if object["spare"] as? Bool == true { continue }
            guard let session = object["sessionId"] as? String else { result = .unknown; continue }
            if session.lowercased() == id.lowercased() { return .held }
        }
        return result
    }
}
