import Testing
import Foundation
import Darwin
@testable import ClawdCore

/// `/resume`'s reading of Claude Code's project folder and registry. Every root is a temporary folder: nothing here reads the real ~/.claude.
private final class ResumeFixture {
    let base: String
    let folder: String
    let roots: ChatResume.Roots
    let projects: String
    let sessions: String

    init(folderName: String = "chat-folder") throws {
        base = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                           create: true).path
        folder = base + "/" + folderName
        projects = base + "/claude/projects"
        sessions = base + "/claude/sessions"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sessions, withIntermediateDirectories: true)
        roots = ChatResume.Roots(projects: projects, sessions: sessions)
    }
    deinit { try? FileManager.default.removeItem(atPath: base) }

    /// The folder Claude Code files this chat folder's conversations under.
    var directory: String {
        let path = projects + "/" + ChatResume.slug(ChatResume.resolvedFolder(folder))
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func uuid() -> String { UUID().uuidString.lowercased() }

    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
    func user(_ text: String, cwd: String? = nil, branch: String? = nil, entrypoint: String? = "cli", extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        object["cwd"] = cwd ?? folder
        if let branch { object["gitBranch"] = branch }
        if let entrypoint { object["entrypoint"] = entrypoint }
        for (key, value) in extra { object[key] = value }
        return Self.json(object)
    }
    func assistant(_ text: String, timestamp: String? = nil) -> String {
        var object: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]]
        if let timestamp { object["timestamp"] = timestamp }
        return Self.json(object)
    }

    /// Writes `<directory>/<id>.jsonl` with these lines and an mtime `age` seconds before `now`.
    @discardableResult
    func conversation(_ id: String = ResumeFixture.uuid(), _ lines: [String], age: TimeInterval = 0, now: Date = Date(), in dir: String? = nil) throws -> String {
        let path = (dir ?? directory) + "/" + id + ".jsonl"
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        setModified(path, now.addingTimeInterval(-age))
        return id
    }
    func setModified(_ path: String, _ date: Date) {
        let seconds = Int(date.timeIntervalSince1970)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        utimes(path, &times)
    }
    func list(excluding: String? = nil, includeSDK: Bool = true, now: Date = Date(), reader: ChatResume.Reader? = nil) -> ChatResume.Listing {
        ChatResume.list(folder: folder, roots: roots, excluding: excluding, includeSDK: includeSDK, now: now, reader: reader ?? ChatResume.defaultReader)
    }
}

struct ChatResumeTests {
    @Test func ChatResume_slugIsTheCLIsRuleWithTheLongPathHash() {
        // Hand-computed from the formula in Tests/Fixtures/resume/PROVENANCE.md (cc@252201431 and cc@251225573).
        #expect(ChatResume.slug("/Users/tomtim") == "-Users-tomtim")
        #expect(ChatResume.slug("/Users/tomtim/") == "-Users-tomtim-")
        #expect(ChatResume.slug("/Users/tomtim/.claude") == "-Users-tomtim--claude")
        let long = "/Users/tomtim/" + String(repeating: "a", count: 236)
        #expect(long.utf16.count == 250)
        #expect(ChatResume.slug(long) == "-Users-tomtim-" + String(repeating: "a", count: 186) + "-52ty5v")
        let twisted = "/x/" + String(repeating: "ab_", count: 83)
        #expect(twisted.utf16.count == 252)
        #expect(ChatResume.slug(twisted) == String(("-x-" + String(repeating: "ab-", count: 83)).prefix(200)) + "-4cvp6w")
        #expect(ChatResume.slug("/tmp/\u{1F600}x") == "-tmp---x")
    }

    @Test func ChatResume_theNFCSpellingOfTheFolderIsListedToo() throws {
        let nfd = "cafe\u{301}"
        let fixture = try ResumeFixture(folderName: nfd)
        let nfc = ChatResume.resolvedFolder(fixture.folder).precomposedStringWithCanonicalMapping
        #expect(ChatResume.slug(nfc) != ChatResume.slug(ChatResume.resolvedFolder(fixture.folder).decomposedStringWithCanonicalMapping))
        let dir = fixture.projects + "/" + ChatResume.slug(nfc)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let id = ResumeFixture.uuid()
        try fixture.conversation(id, [fixture.user("hi")], in: dir)
        let rows = fixture.list().rows
        #expect(rows.map(\.id) == [id])
    }

    @Test func ChatResume_listsOnlyUUIDNamedRegularFilesNewestFirst() throws {
        let fixture = try ResumeFixture()
        let now = Date()
        let old = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("old")], age: 3000, now: now)
        let upper = ResumeFixture.uuid().uppercased()
        try fixture.conversation(upper, [fixture.user("upper")], age: 2000, now: now)
        let new = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("new")], age: 10, now: now)
        let dir = fixture.directory
        try fixture.conversation("notes", [fixture.user("notes")], age: 1, now: now)
        try FileManager.default.createSymbolicLink(atPath: dir + "/" + ResumeFixture.uuid() + ".jsonl", withDestinationPath: dir + "/" + new + ".jsonl")
        try FileManager.default.createDirectory(atPath: dir + "/" + ResumeFixture.uuid() + ".jsonl", withIntermediateDirectories: false)
        #expect(mkfifo(dir + "/" + ResumeFixture.uuid() + ".jsonl", 0o600) == 0)
        let listing = fixture.list(now: now)
        #expect(listing.rows.map(\.id) == [new, upper, old])
        #expect(listing.files == 3)
    }

    @Test func ChatResume_titleOrderIsCustomThenAITitleThenSummaryThenPrompt() throws {
        let fixture = try ResumeFixture()
        let now = Date()
        func title(_ extra: [String]) throws -> String {
            let id = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("first prompt")] + extra + [fixture.assistant("ok")], now: now)
            return fixture.list(now: now).rows.first { $0.id == id }!.title
        }
        let custom = ResumeFixture.json(["type": "custom-title", "customTitle": "My name"])
        let ai1 = ResumeFixture.json(["type": "ai-title", "aiTitle": "First AI"])
        let ai2 = ResumeFixture.json(["type": "ai-title", "aiTitle": "Latest AI"])
        let summary = ResumeFixture.json(["type": "summary", "summary": "A summary", "leafUuid": "x"])
        let last = ResumeFixture.json(["type": "last-prompt", "lastPrompt": "the last prompt"])
        #expect(try title([ai1, summary, last, custom]) == "My name")
        #expect(try title([ai1, summary, last, ai2]) == "Latest AI")
        #expect(try title([summary, last]) == "A summary")
        #expect(try title([last]) == "the last prompt")
        #expect(try title([]) == "first prompt")
        let long = String(repeating: "x", count: 300)
        let id = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("line one\nline two " + long), fixture.assistant("ok")], now: now)
        let shown = fixture.list(now: now).rows.first { $0.id == id }!.title
        #expect(shown == "line one line two " + String(repeating: "x", count: 182) + "\u{2026}")
        #expect(shown.utf16.count == 201)
    }

    @Test func ChatResume_readsOnlyTheHeadAndTailOfEachFile() throws {
        let fixture = try ResumeFixture()
        let now = Date()
        let filler = ResumeFixture.json(["type": "progress", "pad": String(repeating: "p", count: 900)])
        let middle = ResumeFixture.json(["type": "custom-title", "customTitle": "Middle title"])
        let tailTitle = ResumeFixture.json(["type": "custom-title", "customTitle": "Tail title"])
        let body = Array(repeating: filler, count: 600)
        let hidden = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("the prompt")] + body[0..<300] + [middle] + body[300...], now: now)
        let shown = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("the prompt")] + body + [tailTitle], age: 5, now: now)
        var reads: [(count: Int, offset: Int64)] = []
        let counting: ChatResume.Reader = { path, offset, count in
            reads.append((count, offset))
            return ChatResume.defaultReader(path, offset, count)
        }
        let rows = fixture.list(now: now, reader: counting).rows
        #expect(rows.first { $0.id == hidden }?.title == "the prompt")
        #expect(rows.first { $0.id == shown }?.title == "Tail title")
        #expect(reads.count == 4)
        #expect(reads.allSatisfy { $0.count <= 64 * 1024 })
        #expect(reads.map(\.count).reduce(0, +) <= 2 * 2 * 64 * 1024)
    }

    @Test func ChatResume_dropsSidechainTeamDaemonEmptyAndOtherFolderRows() throws {
        let fixture = try ResumeFixture()
        let now = Date()
        let keep = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("keep"), fixture.assistant("ok")], now: now)
        try fixture.conversation(ResumeFixture.uuid(), [fixture.user("side", extra: ["isSidechain": true])], now: now)
        try fixture.conversation(ResumeFixture.uuid(), [fixture.user("team", extra: ["teamName": "red"])], now: now)
        try fixture.conversation(ResumeFixture.uuid(), [fixture.user("daemon", extra: ["sessionKind": "daemon"])], now: now)
        try fixture.conversation(ResumeFixture.uuid(), [fixture.user("worker", extra: ["sessionKind": "daemon-worker"])], now: now)
        try fixture.conversation(ResumeFixture.uuid(), [ResumeFixture.json(["type": "custom-title", "customTitle": "empty"])], now: now)
        try fixture.conversation(ResumeFixture.uuid(), [fixture.user("elsewhere", cwd: "/somewhere/else")], now: now)
        let nocwd = try fixture.conversation(ResumeFixture.uuid(), [ResumeFixture.json(["type": "user", "message": ["role": "user", "content": "no cwd"]])], now: now)
        let slashed = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("slash", cwd: ChatResume.resolvedFolder(fixture.folder) + "/")], now: now)
        let ids = Set(fixture.list(now: now).rows.map(\.id))
        #expect(ids == [keep, nocwd, slashed])
    }

    @Test func ChatResume_keepsSDKAndLoopRowsBecauseTheChatIsAnSDKProcess() throws {
        let fixture = try ResumeFixture()
        let now = Date()
        let cli = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("cli", entrypoint: "cli")], now: now)
        let sdk = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("sdk", entrypoint: "sdk-cli")], now: now)
        let loop = try fixture.conversation(ResumeFixture.uuid(),
                                            [fixture.user("<command-name>/loop</command-name><command-args>5m</command-args>", entrypoint: "cli"), fixture.assistant("ok")], now: now)
        #expect(Set(fixture.list(now: now).rows.map(\.id)) == [cli, sdk, loop])
        #expect(Set(fixture.list(includeSDK: false, now: now).rows.map(\.id)) == [cli])
    }

    @Test func ChatResume_neverListsTheCurrentConversation() throws {
        let fixture = try ResumeFixture()
        let a = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("a")])
        let b = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("b")], age: 10)
        #expect(Set(fixture.list().rows.map(\.id)) == [a, b])
        #expect(fixture.list(excluding: a).rows.map(\.id) == [b])
        #expect(fixture.list(excluding: a.uppercased()).rows.map(\.id) == [b])
    }

    @Test func ChatResume_stopsAtFiftyRowsAndTwoHundredReads() throws {
        let fixture = try ResumeFixture()
        let now = Date()
        for index in 0..<60 { try fixture.conversation(ResumeFixture.uuid(), [fixture.user("row \(index)")], age: TimeInterval(index), now: now) }
        let fifty = fixture.list(now: now)
        #expect(fifty.rows.count == 50)
        #expect(fifty.read == 50)
        #expect(fifty.files == 60)
        let empty = try ResumeFixture()
        for index in 0..<260 { try empty.conversation(ResumeFixture.uuid(), [ResumeFixture.json(["type": "progress"])], age: TimeInterval(index), now: now) }
        let none = empty.list(now: now)
        #expect(none.rows.isEmpty)
        #expect(none.read == 200)
        #expect(none.files == 260)
    }

    @Test func ChatResume_hostileTextIsShownSafe() throws {
        let fixture = try ResumeFixture()
        let now = Date()
        let nasty = "a\u{202E}b\u{200B}c\u{0007}d\u{2066}e"
        let title = ResumeFixture.json(["type": "custom-title", "customTitle": nasty])
        let id = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("p", branch: "br\u{202E}anch"), title], now: now)
        let row = fixture.list(now: now).rows.first { $0.id == id }!
        #expect(row.title == "abcde")
        #expect(row.branch == "branch")
        #expect(!row.subtitle.unicodeScalars.contains { !ChatJSText.isSafeDisplay($0) })
        // A bad escape is absent (the next title source shows), and a 100 KiB value is cut.
        let bad = "{\"type\":\"custom-title\",\"customTitle\":\"bad \\q escape\"}"
        let id2 = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("fallback prompt"), bad], now: now)
        #expect(fixture.list(now: now).rows.first { $0.id == id2 }?.title == "fallback prompt")
        let huge = ResumeFixture.json(["type": "custom-title", "customTitle": String(repeating: "h", count: 100 * 1024)])
        let id3 = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("p"), huge], now: now)
        let shown = fixture.list(now: now).rows.first { $0.id == id3 }!.title
        #expect(shown.utf16.count <= 201)
    }

    @Test func ChatResume_subtitleIsTheCLIsLine() throws {
        let fixture = try ResumeFixture()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var lines = [fixture.user("hi", branch: "main"), ResumeFixture.json(["type": "tag", "tag": "wip"]), fixture.assistant("ok")]
        let used = (lines.joined(separator: "\n") + "\n").utf8.count
        let want = 12_595
        let pad = want - used - "{\"type\":\"x\",\"p\":\"\"}\n".utf8.count
        lines.append("{\"type\":\"x\",\"p\":\"" + String(repeating: "z", count: pad) + "\"}")
        let id = try fixture.conversation(ResumeFixture.uuid(), lines, age: 3 * 3600, now: now)
        let row = fixture.list(now: now).rows.first { $0.id == id }!
        #expect(row.subtitle == "3 hr. ago \u{00B7} main \u{00B7} 12.3KB \u{00B7} #wip")
        #expect(ChatResume.sizeText(500) == "500B")
        #expect(ChatResume.sizeText(2048) == "2KB")
        #expect(ChatResume.sizeText(5 * 1024 * 1024) == "5MB")
        #expect(ChatResume.sizeText(Int64(1.5 * 1024 * 1024 * 1024)) == "1.5GB")
        // The row's time is the older of the mtime and the last message in the tail.
        let older = try fixture.conversation(ResumeFixture.uuid(), [fixture.user("hi"), fixture.assistant("ok", timestamp: "2027-01-15T07:00:00.000Z")], age: 60, now: now)
        let when = fixture.list(now: now).rows.first { $0.id == older }!.modified
        #expect(when <= now.addingTimeInterval(-60))
    }

    @Test func ChatResume_searchMatchesTitleBranchTagPRAndAWholeId() {
        func row(_ title: String, branch: String? = nil, tag: String? = nil, pr: String? = nil) -> ChatResumeRow {
            ChatResumeRow(id: UUID().uuidString.lowercased(), title: title, subtitle: "", folder: "/f", modified: Date(), branch: branch, tag: tag, pr: pr)
        }
        let rows = [row("Fix the Parser"), row("other", branch: "feature/Login"), row("third", tag: "release"), row("fourth", pr: "acme/app#42")]
        #expect(ChatResume.search(rows, "parser").map(\.title) == ["Fix the Parser"])
        #expect(ChatResume.search(rows, "LOGIN").map(\.title) == ["other"])
        #expect(ChatResume.search(rows, "rele").map(\.title) == ["third"])
        #expect(ChatResume.search(rows, "#42").map(\.title) == ["fourth"])
        #expect(ChatResume.search(rows, rows[2].id.uppercased()).map(\.title) == ["third"])
        #expect(ChatResume.search(rows, "  ").count == 4)
        #expect(ChatResume.search(rows, "nothing").isEmpty)
    }

    @Test func ChatResume_liveHolderReadsTheRegistry() throws {
        let fixture = try ResumeFixture()
        let id = ResumeFixture.uuid()
        let me = getpid()
        func record(_ pid: Int32, _ body: String, name: String? = nil, age: TimeInterval = -3) throws {
            let path = fixture.sessions + "/" + (name ?? "\(pid).json")
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            fixture.setModified(path, Date().addingTimeInterval(-age))
        }
        let held = "{\"pid\":\(me),\"sessionId\":\"\(id.uppercased())\",\"kind\":\"interactive\"}"
        #expect(ChatResume.liveHolder(id: id, roots: fixture.roots) == .none)
        try record(me, held)
        #expect(ChatResume.liveHolder(id: id, roots: fixture.roots) == .held)
        #expect(ChatResume.liveHolder(id: ResumeFixture.uuid(), roots: fixture.roots) == .none)
        // The session's own children are not holders.
        #expect(ChatResume.liveHolder(id: id, roots: fixture.roots, ownPids: [me]) == .none)
        // A dead pid does not hold.
        var dead: Int32 = 999_999
        while ChatProc.identity(of: dead) != nil { dead += 1 }
        try FileManager.default.removeItem(atPath: fixture.sessions + "/\(me).json")
        try record(dead, "{\"pid\":\(dead),\"sessionId\":\"\(id)\"}")
        #expect(ChatResume.liveHolder(id: id, roots: fixture.roots) == .none)
        // A record written before its pid's process started is a reused pid.
        try record(me, held, age: 10 * 365 * 24 * 3600)
        #expect(ChatResume.liveHolder(id: id, roots: fixture.roots) == .none)
        // Spare records and .key / .md names are ignored.
        try record(me, "{\"pid\":\(me),\"sessionId\":\"\(id)\",\"spare\":true}")
        #expect(ChatResume.liveHolder(id: id, roots: fixture.roots) == .none)
        try record(me, held, name: "\(me).abc.key")
        try record(me, held, name: "notes.md")
        try FileManager.default.removeItem(atPath: fixture.sessions + "/\(me).json")
        #expect(ChatResume.liveHolder(id: id, roots: fixture.roots) == .none)
        // An unreadable record of a live pid is unknown, never silently free.
        try record(me, "not json")
        #expect(ChatResume.liveHolder(id: id, roots: fixture.roots) == .unknown)
        try record(me, "{\"pid\":\(me)}")
        #expect(ChatResume.liveHolder(id: id, roots: fixture.roots) == .unknown)
        // A record that is a link or a folder cannot be read the safe way: unknown, whatever it leads to.
        let target = fixture.sessions + "/target.txt"
        try held.write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: fixture.sessions + "/\(me).json")
        try FileManager.default.createSymbolicLink(atPath: fixture.sessions + "/\(me).json", withDestinationPath: target)
        #expect(ChatResume.liveHolder(id: id, roots: fixture.roots) == .unknown, "a symlink")
        try FileManager.default.removeItem(atPath: fixture.sessions + "/\(me).json")
        try FileManager.default.createDirectory(atPath: fixture.sessions + "/\(me).json", withIntermediateDirectories: false)
        #expect(ChatResume.liveHolder(id: id, roots: fixture.roots) == .unknown, "a folder")
        try FileManager.default.removeItem(atPath: fixture.sessions + "/\(me).json")
        // No registry folder: no holder.
        #expect(ChatResume.liveHolder(id: id, roots: .none) == .none)
    }

    @Test func ChatResume_theNoMatchLineIsTheCLIsWithItsPeriod() {
        #expect(ChatResume.noMatchText("zzz") == "No sessions match \"zzz\".")
    }

    @Test func ChatResume_fieldSearchComparesPositionsAcrossSpellings() {
        let spacedFirst = "{\"title\": \"spaced\", \"n\":1, \"title\":\"compact\"}"
        #expect(ChatResume.stringField("title", in: spacedFirst, last: false) == "spaced")
        #expect(ChatResume.stringField("title", in: spacedFirst, last: true) == "compact")
        let compactFirst = "{\"title\":\"compact\", \"n\":1, \"title\": \"spaced\"}"
        #expect(ChatResume.stringField("title", in: compactFirst, last: false) == "compact")
        #expect(ChatResume.stringField("title", in: compactFirst, last: true) == "spaced")
    }

    @Test func ChatResume_productionRootsAreTheChildsClaudeFolder() {
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
        #expect(ChatResume.Roots.production() == ChatResume.Roots(projects: home + "/.claude/projects", sessions: home + "/.claude/sessions"))
        #expect(ChatResume.Roots(home: "/h") == ChatResume.Roots(projects: "/h/.claude/projects", sessions: "/h/.claude/sessions"))
        #expect(ChatResume.Roots.none.projects == nil)
        // The environment's default roots list nothing.
        #expect(ChatResume.list(folder: "/", roots: .none, excluding: nil).rows.isEmpty)
    }
}
