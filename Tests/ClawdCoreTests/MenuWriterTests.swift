import Testing
import Foundation
import ClawdCore
import ClawdRendering
import ClawdDesktop

/// A stand-in for the installed CLI in a temporary HOME (never the real one): it records its arguments, its environment and its start and end
/// times, then behaves as the files `stub-delay`, `stub-release`, `stub-flood` and `stub-exit` in the HOME say. `stub-release` holds a path: the
/// stub waits, before it prints or exits, until a file exists there (it looks every 0.05 s) and gives up with exit 99 after 150 s.
final class MenuStubHome {
    static let script = """
    #!/bin/bash
    now() { /usr/bin/perl -MTime::HiRes=time -e 'printf("%.3f", time)'; }
    log="$HOME/calls.log"
    { printf 'START %s ARGS' "$(now)"; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\\n'; } >> "$log"
    { printf 'ENV'; /usr/bin/env | /usr/bin/sort | /usr/bin/sed 's/^/ /' | /usr/bin/tr '\\n' ' '; printf '\\n'; } >> "$log"
    delay=0; [ -f "$HOME/stub-delay" ] && delay="$(/bin/cat "$HOME/stub-delay")"
    [ "$delay" = 0 ] || /bin/sleep "$delay"
    if [ -f "$HOME/stub-release" ]; then
      gate="$(/bin/cat "$HOME/stub-release")"
      SECONDS=0
      while [ ! -e "$gate" ]; do
        [ "$SECONDS" -lt 150 ] || { printf 'GATE-CAPPED\\n' >> "$log"; exit 99; }
        /bin/sleep 0.05
      done
    fi
    if [ -f "$HOME/stub-flood" ]; then
      /usr/bin/head -c 1048576 /dev/zero | /usr/bin/tr '\\0' 'x'
      /usr/bin/head -c 1048576 /dev/zero | /usr/bin/tr '\\0' 'y' >&2
    fi
    code=0; [ -f "$HOME/stub-exit" ] && code="$(/bin/cat "$HOME/stub-exit")"
    [ "$code" = 0 ] || echo "clawd-pet: the stub fails with $code" >&2
    printf 'END %s\\n' "$(now)" >> "$log"
    exit "$code"
    """
    let store: OwnState
    var root: URL { store.root }
    var cli: URL { root.appendingPathComponent("bin/clawd-pet") }

    init(installCLI: Bool = true) throws {
        store = try artifactStore()
        if installCLI {
            try store.write(Data(Self.script.utf8), to: "bin/clawd-pet")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        }
    }
    func set(_ name: String, _ text: String) throws { try store.write(Data(text.utf8), to: name) }
    var calls: [String] {
        (try? String(contentsOf: root.appendingPathComponent("calls.log"), encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    }
    /// The argument lists the stub was started with, in order.
    var started: [[String]] {
        calls.filter { $0.hasPrefix("START") }.map { line in
            line.components(separatedBy: " ARGS").dropFirst().joined().split(separator: "]").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " [")) }.filter { !$0.isEmpty }
        }
    }
    /// (start, end) of each run, in order.
    var intervals: [(Double, Double)] {
        let starts = calls.filter { $0.hasPrefix("START") }.compactMap { Double($0.split(separator: " ")[1]) }
        let ends = calls.filter { $0.hasPrefix("END") }.compactMap { Double($0.split(separator: " ")[1]) }
        return Array(zip(starts, ends))
    }
}


/// A log line starts with `prefix` as a whole word: "MENU write" is a write line, not a "MENU write-output" line. A prefix that ends in a
/// separator ("MENU close reason=") is a plain prefix.
func menuLineHasPrefix(_ line: String, _ prefix: String) -> Bool {
    guard line.hasPrefix(prefix) else { return false }
    guard let last = prefix.last, last.isLetter || last.isNumber, let next = line.dropFirst(prefix.count).first else { return true }
    return !(next.isLetter || next.isNumber || next == "-")
}

/// The times of the writer's `MENU write` lines, appended on its completions queue and read by the test.
final class MenuFinishTimes {
    private let lock = NSLock()
    private var times: [Double] = []
    func add(_ time: Double) { lock.lock(); times.append(time); lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return times }
}

final class MenuWriterLines {
    private(set) var all: [String] = []
    private(set) var threads: [Bool] = []
    func add(_ line: String) { all.append(line); threads.append(Thread.isMainThread) }
    func with(_ prefix: String) -> [String] { all.filter { menuLineHasPrefix($0, prefix) } }
}

/// Waits for `condition`, returning as soon as it holds; the limit is generous because the full suite runs on a loaded Mac, where one stub CLI took 13 s to start.
func menuWait(_ limit: Double = 90, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(limit)
    while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    return condition()
}

private func pick(_ id: Int, _ arguments: [String], key: String? = nil, queueKey: String? = nil, gen: Int = 1) -> MenuPick {
    MenuPick(id: id, action: MenuAction(key: key ?? arguments[0], value: arguments.last ?? "", queueKey: queueKey ?? key ?? arguments[0], arguments: arguments), gen: gen)
}


/// A stand-in CLI that holds each verb at a gate of its own (`gate-<arguments joined with ->`) until that file exists, and then exits 0. Two
/// picks can then be held and released one by one.
func menuInstallGatedCLI(_ stub: MenuStubHome) throws {
    let script = """
    #!/bin/bash
    log="$HOME/calls.log"
    { printf 'START 0 ARGS'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\\n'; } >> "$log"
    gate="$HOME/gate-$(IFS=-; echo "$*")"
    SECONDS=0
    while [ ! -e "$gate" ]; do [ "$SECONDS" -lt 150 ] || exit 99; /bin/sleep 0.05; done
    exit 0
    """
    try stub.store.write(Data(script.utf8), to: "bin/clawd-pet")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.cli.path)
}
func menuRelease(_ stub: MenuStubHome, _ gate: String) { FileManager.default.createFile(atPath: stub.root.appendingPathComponent("gate-" + gate).path, contents: Data()) }

/// A flag a test turns over while a writer holds a closure that reads it.
final class MenuFlag { var on = false }

private func rpick(_ id: Int, _ arguments: [String], key: String? = nil, queueKey: String? = nil, gen: Int = 1) -> MenuPick {
    MenuPick(id: id, action: MenuAction(key: key ?? arguments[0], value: arguments.last ?? "", queueKey: queueKey ?? key ?? arguments[0], arguments: arguments), gen: gen, restarts: true)
}
private let fullScreenOn = ["full-screen", "on"], fullScreenOff = ["full-screen", "off"]
private func fsPick(_ id: Int, _ on: Bool) -> MenuPick { rpick(id, on ? fullScreenOn : fullScreenOff, key: "overFullScreen") }

@Suite("MenuTests writer", .serialized)
@MainActor
struct MenuTestsWriter {
    @Test func Writer_runsTheInstalledCLIWithTheArgumentArrayAndOnlyHomeAndPath() async throws {
        let stub = try MenuStubHome()
        let lines = MenuWriterLines()
        let writer = MenuWriter(home: stub.root, log: { lines.add($0) })
        #expect(writer.cliPath == stub.cli.path)
        // Words a shell would split or run are one argument each: the CLI is run directly, never through a shell string.
        let words = ["look", "a b;$(touch \(stub.root.path)/pwned)", "*", "-n"]
        writer.submit(pick(1, words))
        #expect(await menuWait { lines.with("MENU write").count == 1 })
        #expect(lines.with("MENU write") == ["MENU write id=1 key=look verb=look+a b;$(touch \(stub.root.path)/pwned)+*+-n exit=0 gen=1"])
        #expect(stub.started == [words], "exactly the array, no splitting, no expansion: \(stub.started)")
        #expect(!FileManager.default.fileExists(atPath: stub.root.appendingPathComponent("pwned").path))
        let env = try #require(stub.calls.first { $0.hasPrefix("ENV") })
        let pairs = env.split(separator: " ").dropFirst().compactMap { token -> (String, String)? in
            guard let eq = token.firstIndex(of: "=") else { return nil }
            return (String(token[..<eq]), String(token[token.index(after: eq)...]))
        }
        let table = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
        #expect(table["HOME"] == stub.root.path && table["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin", "\(table)")
        let own: Set<String> = ["PWD", "SHLVL", "_", "OLDPWD", "__CF_USER_TEXT_ENCODING"]
        #expect(Set(table.keys).subtracting(own) == ["HOME", "PATH"], "nothing else is handed to the child: \(table.keys.sorted())")
        #expect(!writer.isRunning && writer.queuedCount == 0)
    }

    @Test func Writer_everyVerbOfTheMenuRunsAsAnArgumentArray() async throws {
        let stub = try MenuStubHome()
        let lines = MenuWriterLines()
        let writer = MenuWriter(home: stub.root, log: { lines.add($0) })
        let layout = MenuLayout(looks: ["plain", "sunglasses"], drawnStyles: StageRuntime.drawnBubbleStyles)
        let picks: [(String, String, [String])] = [("walk", "off", ["walk", "off"]), ("motion", "lively", ["motion", "lively"]), ("every", "2h", ["look-every", "2h"]),
                                                   ("look", "sunglasses", ["look", "sunglasses"]), ("look", "random", ["look", "random"]), ("bubble", "off", ["bubble", "off"]),
                                                   ("style", "7", ["bubble", "exclude", "7"]), ("side", "left", ["bubble", "side", "left"]), ("side", "below", ["bubble", "side", "below"]),
                                                   ("size", "1.5", ["size", "1.5"]), ("hide", "60", ["hide", "60"])]
        for (n, (key, value, expected)) in picks.enumerated() {
            let action = try #require(MenuSelection().action(for: menuItem(layout, key, value)))
            #expect(action.arguments == expected)
            writer.submit(MenuPick(id: n + 1, action: action, gen: 1))
            #expect(await menuWait { lines.with("MENU write").count == n + 1 })
        }
        #expect(stub.started == picks.map(\.2))
        #expect(lines.with("MENU write").allSatisfy { $0.hasSuffix("exit=0 gen=1") })
    }

    /// The writer's own part of a write, measured with a private completions queue that no test's main-queue load can enter, and waited for off
    /// the main thread: from `submit` to the later of the child's start and `submit`'s return (for a queued pick, from the previous write's
    /// `MENU write` line to its child's start), plus from the child's end to its own `MENU write` line. The time the child runs is not the
    /// writer's and is left out. The bound is above the largest writer-side time measured in a loaded full suite (a 6.5 s spawn). The tests
    /// that wait on the main queue (menuWait, Settings_) use a long ceiling for the main queue's sake; a writer that becomes slow by itself
    /// fails here.
    @Test func Writer_finishesSoonAfterTheChildEndsOnItsOwnQueue() async throws {
        let stub = try MenuStubHome()
        let finishes = MenuFinishTimes()
        let done = DispatchSemaphore(value: 0)
        let writer = MenuWriter(home: stub.root, log: { line in
            guard menuLineHasPrefix(line, "MENU write") else { return }
            finishes.add(Date().timeIntervalSince1970); done.signal()
        }, completions: DispatchQueue(label: "writer-completions"))
        func finished(_ what: String) async throws {
            let signalled = await Task.detached { done.wait(timeout: .now() + 60) == .success }.value
            try #require(signalled, "\(what) finished")
        }
        for n in 1...5 {
            let submitted = Date().timeIntervalSince1970
            writer.submit(pick(n, ["walk", "on"]))
            let returned = Date().timeIntervalSince1970
            try await finished("write \(n)")
            try #require(stub.intervals.count == n && finishes.all.count == n, "one run and one finish per write")
            let (start, end) = stub.intervals[n - 1], finish = finishes.all[n - 1]
            let own = (max(start, returned) - submitted) + (finish - end)
            #expect(own < 10, "write \(n): the writer's own time was \(own) s (\(start - submitted) s to start the child, \(returned - submitted) s in submit, \(finish - end) s after it ended)")
        }
        // A pick that waits behind a running one is started by the writer when that one finishes. The first child holds at a gate until both
        // picks are submitted, so the second is queued before the first can finish.
        let gate = stub.root.appendingPathComponent("release")
        try stub.set("stub-release", gate.path)
        writer.submit(pick(6, ["walk", "off"]))
        writer.submit(pick(7, ["bubble", "off"]))
        try stub.set("release", "")
        try await finished("write 6"); try await finished("write 7")
        try #require(stub.intervals.count == 7 && finishes.all.count == 7, "one run and one finish per write")
        #expect(Array(stub.started.suffix(2)) == [["walk", "off"], ["bubble", "off"]])
        let (start, end) = stub.intervals[6], previous = finishes.all[5], finish = finishes.all[6]
        let own = (start - previous) + (finish - end)
        #expect(own < 10, "the queued write: the writer's own time was \(own) s (\(start - previous) s from the previous write's finish to its child's start, \(finish - end) s after it ended)")
    }

    @Test func Writer_exitZeroAndThreeAreLoggedAsTheyAreAndNothingIsRetried() async throws {
        let stub = try MenuStubHome()
        let lines = MenuWriterLines()
        let writer = MenuWriter(home: stub.root, log: { lines.add($0) })
        try stub.set("stub-exit", "3")
        writer.submit(pick(1, ["walk", "on"]))
        #expect(await menuWait { lines.with("MENU write").count == 1 })
        #expect(lines.with("MENU write") == ["MENU write id=1 key=walk verb=walk+on exit=3 gen=1"], "saved but not confirmed in 2 s: logged as such")
        #expect(lines.with("MENU write-output").first?.contains("the stub fails with 3") == true, "and what the CLI said")
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(stub.started.count == 1, "never retried")
        try stub.set("stub-exit", "2")
        writer.submit(pick(2, ["size", "9"]))
        let second = await menuWait { lines.with("MENU write").count == 2 }
        try #require(second, "the second write was logged: \(lines.with("MENU write"))")
        #expect(lines.with("MENU write")[1] == "MENU write id=2 key=size verb=size+9 exit=2 gen=1")
        #expect(lines.with("MENU write-output").count == 2)
        try stub.set("stub-exit", "0")
        writer.submit(pick(3, ["walk", "off"]))
        let third = await menuWait { lines.with("MENU write").count == 3 }
        try #require(third, "the third write was logged: \(lines.with("MENU write"))")
        #expect(lines.with("MENU write")[2].hasSuffix("exit=0 gen=1") && lines.with("MENU write-output").count == 2, "a success says nothing more")
        #expect(stub.started.count == 3)
    }

    @Test func Writer_oneChildAtATimeAndOfTheWaitingPicksOnlyTheNewestPerKeyRuns() async throws {
        let stub = try MenuStubHome()
        let lines = MenuWriterLines()
        let writer = MenuWriter(home: stub.root, log: { lines.add($0) })
        try stub.set("stub-delay", "0.6")
        writer.submit(pick(1, ["walk", "on"], gen: 1))
        #expect(writer.isRunning)
        writer.submit(pick(2, ["motion", "quiet"], gen: 2))          // waits
        writer.submit(pick(3, ["walk", "off"], gen: 2))              // waits, same key as the one that runs: it does not replace it
        writer.submit(pick(4, ["walk", "on"], gen: 3))               // replaces 3
        writer.submit(pick(5, ["bubble", "off"], gen: 3))            // waits
        writer.submit(pick(6, ["motion", "lively"], gen: 3))         // replaces 2
        #expect(writer.queuedCount == 3, "walk, bubble and motion, one of each")
        #expect(lines.with("MENU drop") == ["MENU drop id=3 by=4 gen=2", "MENU drop id=2 by=6 gen=2"], "a drop names the pick it replaced, the pick that replaced it, and the opening of the replaced one")
        #expect(await menuWait(120) { lines.with("MENU write").count == 4 })
        #expect(stub.started == [["walk", "on"], ["walk", "on"], ["bubble", "off"], ["motion", "lively"]], "in the order of the newest picks: 1, then 4, 5 and 6")
        let intervals = stub.intervals
        #expect(intervals.count == 4)
        for (a, b) in zip(intervals, intervals.dropFirst()) { #expect(a.1 <= b.0 + 0.001, "the next child starts after the last one ended: \(a) then \(b)") }
        // Every pick ends in exactly one write or one drop, by id; a write logged after later openings keeps its own opening's number.
        let written = lines.with("MENU write").compactMap { line in line.components(separatedBy: " ").first { $0.hasPrefix("id=") } }
        #expect(written == ["id=1", "id=4", "id=5", "id=6"])
        #expect(lines.with("MENU write").first?.hasSuffix("gen=1") == true && lines.with("MENU write").last?.hasSuffix("gen=3") == true)
    }

    @Test func Writer_twoDifferentQueueKeysAreNeverMerged() async throws {
        let stub = try MenuStubHome()
        let lines = MenuWriterLines()
        let writer = MenuWriter(home: stub.root, log: { lines.add($0) })
        try stub.set("stub-delay", "0.3")
        writer.submit(pick(1, ["walk", "on"]))
        writer.submit(pick(2, ["bubble", "exclude", "3"], key: "style", queueKey: "style-3"))
        writer.submit(pick(3, ["bubble", "exclude", "5"], key: "style", queueKey: "style-5"))
        #expect(writer.queuedCount == 2 && lines.with("MENU drop").isEmpty, "two styles are two keys: neither is lost")
        #expect(await menuWait(120) { lines.with("MENU write").count == 3 })
    }

    @Test func Writer_aMissingSymlinkedOrNonExecutableCLIDoesNothingAndSaysSo() async throws {
        // missing
        let none = try MenuStubHome(installCLI: false)
        let a = MenuWriterLines()
        let missing = MenuWriter(home: none.root, log: { a.add($0) })
        missing.submit(pick(1, ["walk", "on"]))
        #expect(a.with("MENU cli-refused") == ["MENU cli-refused id=1 why=missing gen=1"])
        #expect(a.with("MENU write") == ["MENU write id=1 key=walk verb=walk+on exit=none gen=1"], "one write line, with no exit")
        #expect(!missing.isRunning, "and the next pick can run")
        // a symlink to a perfectly good CLI: refused all the same
        let real = try MenuStubHome()
        let linked = try MenuStubHome(installCLI: false)
        try FileManager.default.createDirectory(at: linked.root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.cli, withDestinationURL: real.cli)
        let b = MenuWriterLines()
        MenuWriter(home: linked.root, log: { b.add($0) }).submit(pick(2, ["walk", "off"]))
        #expect(b.with("MENU cli-refused") == ["MENU cli-refused id=2 why=symlink gen=1"] && b.with("MENU write").first?.hasSuffix("exit=none gen=1") == true)
        // a regular file that is not executable
        let plain = try MenuStubHome()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.cli.path)
        let c = MenuWriterLines()
        MenuWriter(home: plain.root, log: { c.add($0) }).submit(pick(3, ["walk", "off"]))
        #expect(c.with("MENU cli-refused") == ["MENU cli-refused id=3 why=not-executable gen=1"])
        // a directory where the CLI should be
        let dir = try MenuStubHome(installCLI: false)
        try FileManager.default.createDirectory(at: dir.cli, withIntermediateDirectories: true)
        let d = MenuWriterLines()
        MenuWriter(home: dir.root, log: { d.add($0) }).submit(pick(4, ["walk", "off"]))
        #expect(d.with("MENU cli-refused") == ["MENU cli-refused id=4 why=not-regular gen=1"])
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(real.started.isEmpty && plain.started.isEmpty, "no child ran: not through the link, not without the execute bit")
    }

    @Test func Writer_aRefusedPickDoesNotBlockTheQueue() async throws {
        let stub = try MenuStubHome(installCLI: false)
        let lines = MenuWriterLines()
        let writer = MenuWriter(home: stub.root, log: { lines.add($0) })
        writer.submit(pick(1, ["walk", "on"])); writer.submit(pick(2, ["motion", "off"]))
        #expect(lines.with("MENU write").count == 2 && !writer.isRunning)
        // the CLI is installed afterwards: the next pick runs
        try stub.store.write(Data(MenuStubHome.script.utf8), to: "bin/clawd-pet")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.cli.path)
        writer.submit(pick(3, ["walk", "off"]))
        let third = await menuWait { lines.with("MENU write").count == 3 }
        try #require(third, "the third write was logged: \(lines.with("MENU write"))")
        #expect(lines.with("MENU write")[2].hasSuffix("exit=0 gen=1"))
    }

    @Test func Writer_aChildThatPrintsMegabytesOnBothPipesNeverStallsAndTheRunLoopStaysFree() async throws {
        let stub = try MenuStubHome()
        let lines = MenuWriterLines()
        let writer = MenuWriter(home: stub.root, log: { lines.add($0) })
        // The child holds still until a block on the main queue releases it, then prints 2 MB on both pipes and exits 2. The main queue must therefore
        // run while the child does: if anything waits for the child on the main thread or in a main-queue block, nothing can release it, it ends by its
        // 150 s cap with exit 99, and the checks below fail however loaded the Mac is. No time window decides this, except that submit itself returns at once.
        let gate = stub.root.appendingPathComponent("release")
        try stub.set("stub-flood", "1"); try stub.set("stub-exit", "2"); try stub.set("stub-release", gate.path)
        let before = Date()
        writer.submit(pick(1, ["walk", "on"]))
        #expect(Date().timeIntervalSince(before) < 0.25, "submit returns at once, while the child still waits for its release")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            lines.add("MARKER the main queue ran")
            if !FileManager.default.createFile(atPath: gate.path, contents: Data()) { Issue.record("the release file could not be created") }
        }
        #expect(await menuWait(180) { lines.with("MENU write").count == 1 }, "2 MB on two pipes did not stall it")
        let marked = lines.all.firstIndex(of: "MARKER the main queue ran"), written = lines.all.firstIndex { menuLineHasPrefix($0, "MENU write") }
        #expect(marked != nil && written != nil && marked! < written!, "the main thread was not blocked by the child: the marker came first (\(lines.all.prefix(3)))")
        #expect(lines.with("MENU write").first?.hasSuffix("exit=2 gen=1") == true, "the child was released by the main queue and ran to its own exit 2, not to its cap's 99: \(lines.with("MENU write"))")
        let output = try #require(lines.with("MENU write-output").first)
        #expect(output.count < 270, "what is logged of it is short and on one line: \(output.count)")
        #expect(!output.dropFirst().contains("\n"))
        #expect(lines.threads.allSatisfy { $0 }, "every line is written on the main thread")
    }

    @Test func Writer_theLineOfAWriteKeepsItsPicksOpeningAfterLaterOpenings() async throws {
        let stub = try MenuStubHome()
        let lines = MenuWriterLines()
        let writer = MenuWriter(home: stub.root, log: { lines.add($0) })
        try stub.set("stub-delay", "0.4")
        writer.submit(pick(1, ["walk", "on"], gen: 1))
        lines.add("MENU open et=1.000000 how=right gen=2")          // later openings while the first child runs
        writer.submit(pick(2, ["motion", "off"], gen: 2))
        lines.add("MENU open et=2.000000 how=right gen=3")
        let both = await menuWait(120) { lines.with("MENU write").count == 2 }
        try #require(both, "both writes were logged: \(lines.with("MENU write"))")
        let order = lines.all.map { String($0.prefix(18)) }
        let firstWrite = try #require(order.firstIndex { $0.hasPrefix("MENU write id=1") }, "the first write's line: \(order)")
        let thirdOpening = try #require(order.firstIndex { $0.hasPrefix("MENU open et=2") }, "the third opening's line: \(order)")
        #expect(firstWrite > thirdOpening, "the first write was logged after the third opening")
        let writes = lines.with("MENU write")
        try #require(writes.count >= 2, "two write lines: \(writes)")
        #expect(writes[0].hasSuffix("gen=1") && writes[1].hasSuffix("gen=2"))
    }

    // MARK: a restart must not strand a pick (SA5-1b)

    @Test func Writer_aPickNeverWaitsBehindARestartPick() async throws {
        let stub = try MenuStubHome(); try menuInstallGatedCLI(stub)
        let lines = MenuWriterLines()
        let writer = MenuWriter(home: stub.root, log: { lines.add($0) })
        #expect(writer.submit(pick(1, ["walk", "on"])) == nil)
        #expect(writer.submit(fsPick(2, true)) == nil)
        #expect(writer.submit(pick(3, ["bubble", "off"])) == nil)
        #expect(writer.submit(pick(4, ["motion", "quiet"])) == nil)
        for gate in ["walk-on", "bubble-off", "motion-quiet", "full-screen-on"] { menuRelease(stub, gate) }
        #expect(await menuWait(120) { lines.with("MENU write").count == 4 })
        #expect(stub.started == [["walk", "on"], ["bubble", "off"], ["motion", "quiet"], fullScreenOn], "live picks keep their order and go before the restart pick: \(stub.started)")
    }

    @Test func Writer_whileAChildThatMayRestartRunsEveryNewPickIsRefusedAtOnce() async throws {
        for pending in [false, true] {
            let stub = try MenuStubHome(); try menuInstallGatedCLI(stub)
            let lines = MenuWriterLines()
            let flag = MenuFlag()
            let writer = MenuWriter(home: stub.root, log: { lines.add($0) }, restartPending: { flag.on })
            var completed = 0, hooks = 0
            let runner: MenuPick
            if pending {
                flag.on = true
                runner = pick(1, ["walk", "on"])
            } else {
                runner = fsPick(1, true)
            }
            #expect(writer.submit(runner) == nil)
            #expect(writer.restartRunningID == 1)
            let live = writer.submit(pick(2, ["motion", "quiet"]), onStart: { hooks += 1; return true }, completion: { _ in completed += 1 })
            let restart = writer.submit(fsPick(3, false), onStart: { hooks += 1; return true }, completion: { _ in completed += 1 })
            #expect(live?.why == "restarting" && live?.by == 1 && live?.text == "Clawd is restarting; pick this again once it is back", "pending=\(pending): \(String(describing: live))")
            #expect(restart?.why == "restarting" && restart?.by == 1, "pending=\(pending): \(String(describing: restart))")
            #expect(lines.with("MENU refuse") == ["MENU refuse id=2 why=restarting by=1 gen=1", "MENU refuse id=3 why=restarting by=1 gen=1"], "\(lines.all)")
            #expect(await menuWait { stub.started.count == 1 })
            #expect(writer.queuedCount == 0 && stub.started.count == 1 && hooks == 0 && completed == 0)
            menuRelease(stub, runner.arguments.joined(separator: "-"))
            #expect(await menuWait(120) { lines.with("MENU write").count == 1 })
            #expect(completed == 0 && hooks == 0, "a refused pick never completes and never starts")
            flag.on = false
            #expect(writer.submit(pick(4, ["bubble", "on"])) == nil)
            menuRelease(stub, "bubble-on")
            #expect(await menuWait(120) { lines.with("MENU write").count == 2 })
            #expect(stub.started.last == ["bubble", "on"])
        }
    }

    @Test func Writer_restartPendingIsReadWhenAPickStarts() async throws {
        let stub = try MenuStubHome(); try menuInstallGatedCLI(stub)
        let lines = MenuWriterLines()
        let flag = MenuFlag()
        let writer = MenuWriter(home: stub.root, log: { lines.add($0) }, restartPending: { flag.on })
        #expect(writer.submit(pick(1, ["walk", "on"])) == nil)
        #expect(writer.submit(pick(2, ["motion", "quiet"])) == nil)           // X: waits behind W while restartPending is false
        #expect(!writer.restartRunning)
        flag.on = true
        menuRelease(stub, "walk-on")
        #expect(await menuWait(120) { stub.started.count == 2 })
        #expect(writer.restartRunningID == 2, "X started after restartPending turned true, so it may restart")
        let refused = writer.submit(pick(3, ["bubble", "off"]))
        #expect(refused?.why == "restarting" && refused?.by == 2)
        menuRelease(stub, "motion-quiet")
        #expect(await menuWait(120) { lines.with("MENU write").count == 2 })
    }

    @Test func Writer_startingAPickThatMayRestartRefusesEveryWaitingPick() async throws {
        let stub = try MenuStubHome(); try menuInstallGatedCLI(stub)
        let lines = MenuWriterLines()
        let flag = MenuFlag()
        let writer = MenuWriter(home: stub.root, log: { lines.add($0) }, restartPending: { flag.on })
        var results: [MenuResult] = [], hooks = 0
        #expect(writer.submit(pick(1, ["walk", "on"])) == nil)
        #expect(writer.submit(pick(2, ["motion", "quiet"])) == nil)           // X
        #expect(writer.submit(pick(3, ["bubble", "off"]), onStart: { hooks += 1; return true }, completion: { results.append($0) }) == nil)   // Y
        flag.on = true
        menuRelease(stub, "walk-on")
        #expect(await menuWait(120) { results.count == 1 })
        #expect(results == [MenuResult(exit: nil, text: "Clawd is restarting; pick this again once it is back")])
        #expect(await menuWait { stub.started.count == 2 })
        #expect(hooks == 0 && stub.started == [["walk", "on"], ["motion", "quiet"]])
        #expect(lines.with("MENU refuse") == ["MENU refuse id=3 why=restarting by=2 gen=1"], "\(lines.all)")
        menuRelease(stub, "motion-quiet")
        #expect(await menuWait(120) { lines.with("MENU write").count == 2 })
    }

    @Test func Writer_theMenuHoldAlsoHoldsAPickThatMayRestartBecauseARestartIsPending() async throws {
        let stub = try MenuStubHome(); try menuInstallGatedCLI(stub)
        let lines = MenuWriterLines()
        let flag = MenuFlag()
        let writer = MenuWriter(home: stub.root, log: { lines.add($0) }, restartPending: { flag.on })
        flag.on = true
        writer.holdRestarts()
        #expect(writer.submit(pick(1, ["walk", "on"])) == nil)
        #expect(!writer.isRunning && writer.queuedCount == 1 && stub.started.isEmpty, "X waits: it may restart because a restart is pending")
        var results: [MenuResult] = []
        #expect(writer.submit(pick(2, ["motion", "quiet"]), completion: { results.append($0) }) == nil)   // the menu's M
        writer.releaseRestarts()
        #expect(await menuWait(120) { stub.started.count == 1 })
        #expect(stub.started == [["walk", "on"]])
        #expect(results == [MenuResult(exit: nil, text: "Clawd is restarting; pick this again once it is back")] && lines.with("MENU refuse") == ["MENU refuse id=2 why=restarting by=1 gen=1"])
        menuRelease(stub, "walk-on")
        #expect(await menuWait(120) { lines.with("MENU write").count == 1 })
        // Nothing pending: the same live X starts at once while held.
        flag.on = false
        writer.holdRestarts()
        #expect(writer.submit(pick(3, ["bubble", "off"])) == nil)
        #expect(writer.isRunning)
        menuRelease(stub, "bubble-off")
        writer.releaseRestarts()
        #expect(await menuWait(120) { lines.with("MENU write").count == 2 })
    }

    @Test func Writer_aSecondRestartPickIsRefusedWhileOneWaits() async throws {
        let stub = try MenuStubHome(); try menuInstallGatedCLI(stub)
        let lines = MenuWriterLines()
        let writer = MenuWriter(home: stub.root, log: { lines.add($0) })
        #expect(writer.submit(pick(1, ["walk", "on"])) == nil)
        #expect(writer.submit(fsPick(2, true)) == nil)
        let other = writer.submit(rpick(3, ["aqua", "follow"], key: "aqua"))
        #expect(other?.why == "restart-queued" && other?.by == 2 && other?.text == "Clawd restarts for another setting first; pick this again once it is back", "\(String(describing: other))")
        #expect(lines.with("MENU refuse") == ["MENU refuse id=3 why=restart-queued by=2 gen=1"])
        #expect(writer.submit(fsPick(4, false)) == nil)
        #expect(lines.with("MENU drop") == ["MENU drop id=2 by=4 gen=1"] && writer.queuedCount == 1)
        menuRelease(stub, "walk-on"); menuRelease(stub, "full-screen-off")
        #expect(await menuWait(120) { lines.with("MENU write").count == 2 })
        #expect(stub.started == [["walk", "on"], fullScreenOff])
    }

    @Test func Writer_aWaitingRestartPickDoesNotStartWhileTheMenuHoldsASelection() async throws {
        let stub = try MenuStubHome(); try menuInstallGatedCLI(stub)
        let lines = MenuWriterLines()
        let writer = MenuWriter(home: stub.root, log: { lines.add($0) })
        #expect(writer.submit(pick(1, ["walk", "on"])) == nil)
        #expect(writer.submit(fsPick(2, true)) == nil)
        writer.holdRestarts()
        menuRelease(stub, "walk-on")
        #expect(await menuWait(120) { lines.with("MENU write").count == 1 })
        #expect(!writer.isRunning && writer.queuedCount == 1 && stub.started.count == 1, "R waits for the menu's selection")
        #expect(writer.submit(pick(3, ["motion", "quiet"])) == nil)           // the menu's M
        #expect(writer.isRunning && writer.restartRunningID == nil, "M runs before R")
        writer.releaseRestarts()
        #expect(await menuWait { stub.started.count == 2 })
        #expect(stub.started == [["walk", "on"], ["motion", "quiet"]])
        menuRelease(stub, "motion-quiet")
        #expect(await menuWait(120) { stub.started.count == 3 })
        #expect(stub.started.last == fullScreenOn)
        menuRelease(stub, "full-screen-on")
        #expect(await menuWait(120) { lines.with("MENU write").count == 3 })
        // Release with no selection: R starts at once.
        #expect(writer.submit(pick(4, ["bubble", "on"])) == nil)
        #expect(writer.submit(fsPick(5, false)) == nil)
        writer.holdRestarts()
        menuRelease(stub, "bubble-on"); menuRelease(stub, "full-screen-off")
        #expect(await menuWait(120) { lines.with("MENU write").count == 4 })
        #expect(!writer.isRunning && writer.queuedCount == 1)
        writer.releaseRestarts()
        #expect(await menuWait(120) { lines.with("MENU write").count == 5 })
        #expect(stub.started.last == fullScreenOff)
    }
}
