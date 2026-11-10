import Testing
import Foundation
import ClawdCore

// Stage SA, Sprint SA4 (Q6): the chat finds `claude` in ~/.local/bin, /opt/homebrew/bin and /usr/local/bin, in that order, only while control.json
// holds no `chatClaude` the reader accepts; the result lives in memory and is never written. Every place here is a stubbed file in a temporary folder;
// no test reads the real folders or runs a real `claude`.

/// A temporary home with three stubbed search folders `a`, `b` and `c` (the stand-ins of the three places) and the stub executable they link to.
private final class ClaudeFolders {
    let root: URL
    let home: String
    let a: String, b: String, c: String
    let stub: String

    init() throws {
        root = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()), create: true)
        home = root.appendingPathComponent("home").path
        a = root.appendingPathComponent("a").path; b = root.appendingPathComponent("b").path; c = root.appendingPathComponent("c").path
        for folder in [home, a, b, c] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        stub = repository.appendingPathComponent("Tests/Fixtures/chat/stubs/replay.sh").path
    }

    /// An executable `claude` in `folder`: a symlink to the stub script, as Homebrew and the native installer lay theirs out.
    func put(_ folder: String) throws { try FileManager.default.createSymbolicLink(atPath: folder + "/claude", withDestinationPath: stub) }
    func put(plainFile folder: String, executable: Bool) throws {
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: folder + "/claude"))
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: folder + "/claude")
    }
    /// Every path under the root with its size, to show the search wrote nothing.
    var listing: [String] {
        let walker = FileManager.default.enumerator(atPath: root.path)
        return (walker?.allObjects as? [String] ?? []).sorted()
    }
    var resolvedStub: String { URL(fileURLWithPath: stub).resolvingSymlinksInPath().path }
}

@Suite("ClaudePath", .serialized)
@MainActor
struct ClaudePathSuite {
    @Test func ClaudePath_theSearchFindsTheFirstOfTheThreePlacesAndWritesNothing() throws {
        // The one constant: the three places, in this order.
        #expect(ChatSettings.claudeSearchList == ["$HOME/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
        let f = try ClaudeFolders()
        let control = f.root.appendingPathComponent("control.json")
        try Data(#"{"generation":4,"walk":false}"#.utf8).write(to: control)
        let controlBefore = try Data(contentsOf: control)
        var settings = ChatSettings(object: ["walk": false], home: f.home)
        settings.claudeSearch = [f.a, f.b, f.c]
        #expect(!settings.claudeIsSet)
        #expect(settings.claudeLocation() == .nowhere, "nothing anywhere")
        try f.put(f.c)
        #expect(settings.claudeLocation() == .searched(path: f.c + "/claude", resolved: f.resolvedStub), "only the last place has one")
        try f.put(f.b)
        #expect(settings.claudeLocation() == .searched(path: f.b + "/claude", resolved: f.resolvedStub), "the second place wins over the third")
        // A file that is not an executable, and a folder named claude, are not found: the next place is looked at.
        try f.put(plainFile: f.a, executable: false)
        #expect(settings.claudeLocation() == .searched(path: f.b + "/claude", resolved: f.resolvedStub), "a file that cannot run is skipped")
        try FileManager.default.removeItem(atPath: f.a + "/claude")
        try FileManager.default.createDirectory(atPath: f.a + "/claude", withIntermediateDirectories: true)
        #expect(settings.claudeLocation() == .searched(path: f.b + "/claude", resolved: f.resolvedStub), "a folder is skipped")
        try FileManager.default.removeItem(atPath: f.a + "/claude")
        try f.put(plainFile: f.a, executable: true)
        let first = settings.claudeLocation()
        #expect(first == .searched(path: f.a + "/claude", resolved: URL(fileURLWithPath: f.a + "/claude").resolvingSymlinksInPath().path), "the first place wins: \(first)")
        // Found at the default place is its own case (the first entry of the list, `$HOME/.local/bin`).
        var native = ChatSettings(home: f.home)
        try FileManager.default.createDirectory(atPath: f.home + "/.local/bin", withIntermediateDirectories: true)
        native.claudeSearch = ["$HOME/.local/bin", f.b]
        try f.put(f.home + "/.local/bin")
        #expect(native.claudeLocation() == .defaultPlace(path: f.home + "/.local/bin/claude", resolved: f.resolvedStub))
        // The spawn takes the same answer: the real binary behind the link.
        settings.folder = f.home
        #expect(ChatTermRefusal.resolve(settings) == .success(URL(fileURLWithPath: f.a + "/claude").resolvingSymlinksInPath().path))
        // Nothing was written: the setting still names the default, control.json is the bytes it was, and the stubbed tree holds only what this test made.
        #expect(settings.claude == f.home + "/.local/bin/claude" && !settings.claudeIsSet, "the result is not stored in the setting")
        #expect(try Data(contentsOf: control) == controlBefore)
        #expect(f.listing == ["a", "a/claude", "b", "b/claude", "c", "c/claude", "control.json", "home", "home/.local", "home/.local/bin", "home/.local/bin/claude"], "\(f.listing)")
    }

    @Test func ClaudePath_aSetPathThatIsMissingSaysNotFoundAndSpawnsNothing() throws {
        let f = try ClaudeFolders()
        try f.put(f.a); try f.put(f.b)
        let missing = f.root.path + "/no-such-claude"
        var settings = ChatSettings(object: ["chatClaude": missing], home: f.home)
        settings.claudeSearch = [f.a, f.b]
        settings.folder = f.home
        #expect(settings.claudeIsSet && settings.claude == missing)
        // A set path always wins, also when nothing is there and a search would find one: no search runs.
        #expect(settings.claudeLocation() == .given(path: missing, resolved: nil))
        #expect(ChatTermRefusal.resolve(settings) == .failure(.missingBinary))
        // The path as the reader expands it: `~/` is the home folder.
        let tilde = ChatSettings(object: ["chatClaude": "~/gone/claude"], home: f.home)
        #expect(tilde.claudeLocation() == .given(path: f.home + "/gone/claude", resolved: nil))
        // A set path that is there is the one used, though the search list has another.
        var present = ChatSettings(object: ["chatClaude": f.b + "/claude"], home: f.home)
        present.claudeSearch = [f.a]
        #expect(present.claudeLocation() == .given(path: f.b + "/claude", resolved: f.resolvedStub))
        // A path the reader rejects is not set, so the search runs (and the line says so).
        var rejected = ChatSettings(object: ["chatClaude": "relative/claude"], home: f.home)
        rejected.claudeSearch = [f.a]
        #expect(!rejected.claudeIsSet && rejected.claudeLocation() == .searched(path: f.a + "/claude", resolved: f.resolvedStub))
        // The chat's own refusal: the session says not found, logs the refusal and spawns nothing.
        let log = ClaudeLogBox()
        let config = ChatSessionConfig(settings: { settings }, log: { log.lines.append($0) }, timers: ManualChatTimers())
        let session = ChatSession(config: config, timeZone: TimeZone(identifier: "UTC")!)
        #expect(!session.send("hello"))
        #expect(log.lines == ["CHAT refuse reason=missing-binary"], "\(log.lines)")
        let text = session.transcript.entries.first?.text ?? ""
        #expect(text.contains("Claude Code was not found at \(missing)"), "\(text)")
        #expect(log.lines.allSatisfy { !$0.hasPrefix("CHAT spawn ") })
    }

    /// The chat session starts the claude the search found, when no path is set.
    @Test func ClaudePath_aSessionWithNoPathSetStartsTheClaudeTheSearchFound() async throws {
        let f = try ClaudeFolders()
        try f.put(f.b)
        let rig = try ChatRig(stub: "replay.sh", search: [f.a, f.b])
        #expect(rig.session.send("Reply with the word ok"))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(rig.spawns == 1, "\(rig.log)")
        #expect(!rig.log.contains { $0.hasPrefix("CHAT refuse") })
        let none = try ChatRig(stub: "replay.sh", search: [f.a])
        #expect(!none.session.send("hello"))
        #expect(none.log == ["CHAT refuse reason=missing-binary"], "\(none.log)")
        let refusal = none.session.transcript.entries.first?.text ?? ""
        #expect(refusal.contains("Claude Code was not found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin"), "no path set: the refusal names the places searched: \(refusal)")
    }
}

private final class ClaudeLogBox { var lines: [String] = [] }
