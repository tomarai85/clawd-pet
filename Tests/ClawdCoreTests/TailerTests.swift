import Testing
import Foundation
import ClawdCore
import Darwin

/// The real LogTailer over real files, feeding the real parser and PetController on a virtual clock.
final class TailRig {
    let store: OwnState
    let rig = Rig()
    let tailer: LogTailer
    var machine: SceneMachine { rig.controller.machine }
    var clock: VirtualClock { rig.clock }

    init(guards: GuardSet = .all, initial: Data? = Data()) throws {
        store = try artifactStore()
        if let initial { try store.write(initial, to: "main.log") }
        let rig = self.rig
        rig.controller.machine.guards = guards
        rig.controller.parser.guards = guards
        tailer = LogTailer(path: try store.url("main.log").path) { rig.controller.receive(line: $0) }
        tailer.guards = guards
        tailer.onBoundary = { rig.controller.parser.reset() }
    }
    func appendStart(_ lease: Int = 1, age: Double = 0) throws { try store.append(startLine(clock, lease: lease, age: age), to: "main.log") }
    func append(_ text: String) throws { try store.append(text, to: "main.log") }
    func poll() { tailer.poll() }
    /// After any disturbance a fresh START must still be seen and shown.
    func freshStartListens(lease: Int) throws -> Bool {
        try append("\n"); try appendStart(lease); poll()
        rig.advance(1.0)    // a new lease may wait out THINKING's one-second minimum
        return machine.lease == lease && machine.scene == .listening
    }
}

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: scenarios shared by the positive tests and the negative controls

private func renameScenario(_ guards: GuardSet) throws -> Bool {
    let t = try TailRig(guards: guards)
    try t.appendStart(1); t.poll()
    guard t.machine.lease == 1 else { return false }
    try t.store.rename("main.log", to: "main.old.log")
    try t.store.write(Data(startLine(t.clock, lease: 2).utf8), to: "main.log")
    t.poll()
    guard t.machine.lease == 2, t.machine.scene == .listening else { return false }
    t.rig.advance(180)
    guard t.machine.scene == .idle else { return false }
    return try t.freshStartListens(lease: 3)
}

private func trimScenario(_ guards: GuardSet, regrow: Bool) throws -> Bool {
    let t = try TailRig(guards: guards, initial: Data(String(repeating: "a", count: 256).utf8))
    let replaced = String(repeating: "b", count: regrow ? 400 : 5) + "\n" + startLine(t.clock, lease: 2)
    try t.store.rewriteInPlace(Data(replaced.utf8), to: "main.log")
    t.poll()
    guard t.machine.scene == .idle else { return false }
    return try t.freshStartListens(lease: 3)
}

private func partialScenario(_ guards: GuardSet) throws -> Bool {
    let t = try TailRig(guards: guards)
    let bytes = Array(startLine(t.clock).utf8), half = bytes.count / 2
    try t.append(String(decoding: bytes.prefix(half), as: UTF8.self)); t.poll()
    guard t.machine.scene == .idle else { return false }
    t.clock.advance(0.2)
    try t.append(String(decoding: bytes.suffix(from: half), as: UTF8.self)); t.poll()
    return t.machine.scene == .listening && t.machine.lease == 1
}

private func staleScenario(_ guards: GuardSet) throws -> Bool {
    let t = try TailRig(guards: guards)
    try t.appendStart(1, age: 20); t.poll()
    guard t.machine.scene == .idle, t.machine.lease == nil else { return false }
    return try t.freshStartListens(lease: 2)
}

private func allowlistScenario(_ guards: GuardSet) throws -> Bool {
    let t = try TailRig(guards: guards)
    try t.append(line(t.clock, "Main", "app.bootstrap arch=arm64 pid=1 platform=darwin"))
    try t.append(line(t.clock, "SystemBridge", "Bridge stderr: LLVM Profile Error: Failed to write file \"default.profraw\": Read-only file system", level: "error"))
    t.poll()
    guard t.machine.scene == .idle, !t.rig.scenes.contains(.error) else { return false }
    return try t.freshStartListens(lease: 1)
}

// MARK: Rotation

@Suite("Tailer rotation, trim, restart, stale, partial, long, fuzz")
struct TailerSuite {
    @Test func Rotation_singleRenameDrainsOldFDThenReadsNewFromZero() throws {
        #expect(try renameScenario(.all))
    }
    @Test func Rotation_negativeControl_renameHandlingOff() throws {
        negativeControl("rename-handling", expectationHolds: try renameScenario(.all.subtracting(.renameFollow)))
    }
    @Test func Rotation_twoRenamesBeforeTheReaderRuns() throws {
        let t = try TailRig()
        try t.appendStart(1)
        try t.store.rename("main.log", to: "first.log")
        try t.store.write(Data(startLine(t.clock, lease: 2).utf8), to: "main.log")
        try t.store.rename("main.log", to: "second.log")
        try t.store.write(Data(startLine(t.clock, lease: 3).utf8), to: "main.log")
        t.poll()
        // The middle file is unreachable; the drained old descriptor and the newest file are both read.
        #expect(t.machine.lease == 3)
        t.rig.advance(180); #expect(t.machine.scene == .idle)
        #expect(try t.freshStartListens(lease: 4))
    }
    @Test func Rotation_missingFileAtStartIsPickedUpWhenCreated() throws {
        let parent = try artifactStore(), rig = Rig()
        let path = try parent.url("main.log").path
        let tailer = LogTailer(path: path) { rig.controller.receive(line: $0) }
        tailer.poll(); #expect(rig.scene == .idle)
        try parent.append(startLine(rig.clock, lease: 1), to: "main.log"); tailer.poll()
        #expect(rig.scene == .listening)
    }
    @Test func Rotation_missingDirectoryAtStartIsPickedUpWhenCreated() throws {
        let parent = try artifactStore(), rig = Rig()
        let path = try parent.url("missing/deeper/main.log").path
        let tailer = LogTailer(path: path) { rig.controller.receive(line: $0) }
        tailer.poll(); #expect(rig.scene == .idle)
        let child = try OwnState(root: URL(fileURLWithPath: path).deletingLastPathComponent())
        try child.append(startLine(rig.clock, lease: 1), to: "main.log"); tailer.poll()
        #expect(rig.scene == .listening)
    }
    @Test func Rotation_deleteThenRecreateFollowsTheNewFile() throws {
        let t = try TailRig()
        try t.appendStart(1); t.poll(); #expect(t.machine.lease == 1)
        try FileManager.default.removeItem(at: try t.store.url("main.log"))
        t.poll()
        try t.store.write(Data(startLine(t.clock, lease: 2).utf8), to: "main.log"); t.poll()
        #expect(t.machine.lease == 2)
    }
    @Test func Rotation_afterDroppedEventsEveryScenesReachesIdleThroughItsTimeout() throws {
        // Each setup drops the event that would normally end the scene (rotate the log away), then only timers run.
        let setups: [(String, (TailRig) throws -> Void, Scene, Double)] = [
            ("listening", { try $0.appendStart(1) }, .listening, 180),
            ("thinking", { try $0.appendStart(1); try $0.append(completedLine($0.clock, lease: 1)) }, .thinking, 5),
            ("interrupted", { try $0.appendStart(1); try $0.append(line($0.clock, "DictationOrchestrator", "dictation.cancel_accepted lease_id=1")) }, .interrupted, 1.5),
            ("error", { try $0.append(line($0.clock, "DictationRuntimeAdapter", "dictation.native_audio_capture_failed lease_id=1", level: "warn")) }, .error, 1.5),
        ]
        for (name, setup, scene, timeout) in setups {
            let t = try TailRig()
            try setup(t); t.poll()
            #expect(t.machine.scene == scene, "\(name) not reached")
            try t.store.rename("main.log", to: "gone.log")          // the closing events are dropped
            try t.store.write(Data(), to: "main.log"); t.poll()
            t.rig.advance(timeout - 0.01); #expect(t.machine.scene == scene, "\(name) left too early")
            t.rig.advance(0.02); #expect(t.machine.scene == .idle, "\(name) did not reach IDLE")
            #expect(t.rig.controller.ownedTimers == 1, "\(name): only the blink timer may remain")
            #expect(try t.freshStartListens(lease: 9), "\(name): fresh START after the drop")
        }
        // SENT: completed + ACK seen, nothing further needed; it times out on its own.
        let t = try TailRig()
        try t.appendStart(1); try t.append(completedLine(t.clock, lease: 1)); try t.append(ackLine(t.clock)); t.poll()
        t.rig.advance(1.0); #expect(t.machine.scene == .sent)
        t.rig.advance(2.0); #expect(t.machine.scene == .idle)
    }

    // MARK: Trim

    @Test func Trim_sameInodeShorterFileSeeksToEOF() throws {
        #expect(try trimScenario(.all, regrow: false))
    }
    @Test func Trim_regrowthPastTheOldSizeIsDetectedByTheFingerprint() throws {
        #expect(try trimScenario(.all, regrow: true))
    }
    @Test func Trim_negativeControl_fingerprintResyncOff() throws {
        negativeControl("fingerprint-resync", expectationHolds: try trimScenario(.all.subtracting(.fingerprintResync), regrow: true))
    }
    @Test func Trim_negativeControl_sizeCheckOffMissesShorterFile() throws {
        // Both resync checks hang off the same guard: with it off, content below the old offset is never read again.
        negativeControl("trim-resync", expectationHolds: try trimScenario(.all.subtracting(.fingerprintResync), regrow: false))
    }

    // MARK: Restart

    @Test func Restart_leaseIdReuseAfterBootstrapStartsANewGeneration() throws {
        let t = try TailRig()
        try t.appendStart(1); t.poll(); #expect(t.machine.lease == 1)
        try t.append(line(t.clock, "SystemBridge", "Shutdown initiated (pid: 1)"))
        try t.append(line(t.clock, "Main", "app.bootstrap arch=arm64 pid=2 platform=darwin"))
        t.poll(); #expect(t.machine.lease == nil); #expect(t.machine.generation >= 1)
        try t.appendStart(1); t.poll()            // the same lease id again
        #expect(t.machine.lease == 1); #expect(t.machine.scene == .listening)
    }
    @Test func Restart_oldCompletedCannotCloseTheNewLease() throws {
        let rig = Rig()
        rig.start(1)
        let old = event(rig.clock, .completed(10), lease: 1)
        rig.advance(1)
        rig.feed(line(rig.clock, "Main", "app.bootstrap arch=arm64 pid=2 platform=darwin"))
        rig.lock(lease: 1)
        #expect(!rig.controller.machine.receive(old))
        #expect(rig.scene == .listening)
    }
    @Test func Restart_llvmProfileErrorAndUnknownBlocksNeverBecomeErrors() throws {
        #expect(try allowlistScenario(.all))
    }
    @Test func Restart_negativeControl_allowlistOff() throws {
        negativeControl("allowlist", expectationHolds: try allowlistScenario(.all.subtracting(.allowlist)))
    }
    @Test func Restart_inPlaceTrimAtBootstrapKeepsTheTailerAlive() throws {
        // Aqua trims main.log in place at every start: same inode, first line cut mid-line.
        let t = try TailRig()
        try t.appendStart(1); t.poll()
        let keep = String(repeating: "x", count: 30) + "\n" + line(t.clock, "Main", "app.bootstrap arch=arm64 pid=2 platform=darwin")
        try t.store.rewriteInPlace(Data(keep.utf8), to: "main.log"); t.poll()
        #expect(try t.freshStartListens(lease: 5))
    }

    // MARK: StaleLine

    @Test func StaleLine_startTwentySecondsOldAtAgentStartDoesNotAnimate() throws {
        let t = try TailRig(initial: nil)
        try t.store.write(Data(startLine(t.clock, lease: 1, age: 20).utf8), to: "main.log")
        // The agent starts after the line was written: it begins at EOF and never replays it.
        let rig = t.rig
        let late = LogTailer(path: try t.store.url("main.log").path) { rig.controller.receive(line: $0) }
        late.poll(); #expect(rig.scene == .idle)
        try t.append(startLine(t.clock, lease: 2)); late.poll()
        #expect(rig.scene == .listening); #expect(rig.controller.machine.lease == 2)
    }
    @Test func StaleLine_startupAlwaysBeginsAtEOFEvenForFreshLines() throws {
        let t = try TailRig(initial: Data(startLine(Rig().clock).utf8))
        t.poll(); #expect(t.machine.scene == .idle)
    }
    @Test func StaleLine_appendedStaleLineNeverAnimates() throws {
        #expect(try staleScenario(.all))
    }
    @Test func StaleLine_negativeControl_ruleOff() throws {
        negativeControl("stale-line-rule", expectationHolds: try staleScenario(.all.subtracting(.staleRule)))
    }
    @Test func StaleLine_lineJustInsideTenSecondsAnimatesAndJustOutsideDoesNot() throws {
        let rig = Rig()
        rig.feed(startLine(rig.clock, lease: 1, age: 9.9)); #expect(rig.scene == .listening)
        let other = Rig()
        other.feed(startLine(other.clock, lease: 1, age: 10.1)); #expect(other.scene == .idle)
    }

    // MARK: PartialLine

    @Test func PartialLine_halfLineWaitsThenCompletes() throws {
        #expect(try partialScenario(.all))
    }
    @Test func PartialLine_negativeControl_bufferOff() throws {
        negativeControl("partial-line-buffer", expectationHolds: try partialScenario(.all.subtracting(.partialBuffer)))
    }
    @Test func PartialLine_unterminatedTailIsDroppedOnRotation() throws {
        let t = try TailRig()
        let bytes = Array(startLine(t.clock).utf8)
        try t.append(String(decoding: bytes.dropLast(), as: UTF8.self)); t.poll()
        var diagnostics: [String] = []
        t.tailer.onDiagnostic = { diagnostics.append($0) }
        try t.store.rename("main.log", to: "rotated.log")
        try t.store.write(Data(startLine(t.clock, lease: 2).utf8), to: "main.log"); t.poll()
        #expect(diagnostics.contains("partial_dropped"))
        #expect(t.machine.lease == 2)
    }
    @Test func PartialLine_startupPartialCannotBecomeAStartAfterAppend() throws {
        let probe = Rig(); let bytes = Array(startLine(probe.clock).utf8), half = bytes.count / 2
        let t = try TailRig(initial: Data(bytes.prefix(half)))
        try t.append(String(decoding: bytes.suffix(from: half), as: UTF8.self)); t.poll()
        #expect(t.machine.scene == .idle)
        #expect(try t.freshStartListens(lease: 2))
    }

    // MARK: LongLine

    @Test func LongLine_fourHundredKilobyteLineIsBoundedAndTheNextLineSurvives() throws {
        let t = try TailRig()
        try t.append(String(repeating: "x", count: 400 * 1024)); t.poll()
        #expect(t.tailer.bufferedBytes <= LogTailer.lineLimit); #expect(t.machine.scene == .idle)
        try t.append("\n" + startLine(t.clock)); t.poll()
        #expect(t.machine.scene == .listening)
    }
    @Test func LongLine_exactlyAtTheCapIsKeptAndOneOverIsDropped() throws {
        let t = try TailRig()
        var diagnostics: [String] = []
        t.tailer.onDiagnostic = { diagnostics.append($0) }
        try t.append(String(repeating: "y", count: LogTailer.lineLimit) + "\n"); t.poll()
        #expect(!diagnostics.contains("oversize_dropped"))
        try t.append(String(repeating: "y", count: LogTailer.lineLimit + 1) + "\n"); t.poll()
        #expect(diagnostics.contains("oversize_dropped"))
    }

    // MARK: TailerFuzz

    @Test func TailerFuzz_thousandRandomByteCasesNeverCrashAndAFreshStartStillListens() throws {
        var random = SplitMix(state: 0xC1A5D)
        let t = try TailRig()
        let fragments = [
            { startLine(t.clock, lease: Int.random(in: 1...9, using: &random)) },
            { completedLine(t.clock, lease: Int.random(in: 1...9, using: &random), length: Int.random(in: 0...50, using: &random)) },
            { ackLine(t.clock, success: Bool.random(using: &random)) },
            { line(t.clock, "Main", "app.bootstrap arch=arm64 pid=1 platform=darwin") },
            { "PASTE_ACK received {\n" }, { "  success: true\n}\n" }, { "[2026-" }, { "\u{0}\u{1}\u{2}" },
        ]
        var survived = 0, nextLease = 1000
        for round in 0..<1000 {
            if !FileManager.default.fileExists(atPath: try t.store.url("main.log").path) { try t.store.write(Data(), to: "main.log") }
            switch Int.random(in: 0..<10, using: &random) {
            case 0...4:
                var bytes = [UInt8](repeating: 0, count: Int.random(in: 0...600, using: &random))
                for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &random) }
                if Bool.random(using: &random) { bytes.insert(10, at: bytes.count / 2) }
                try t.store.appendRaw(Data(bytes), to: "main.log")
            case 5, 6:
                try t.append(fragments[Int.random(in: 0..<fragments.count, using: &random)]())
            case 7:
                try t.store.rename("main.log", to: "fuzz-old-\(round % 3).log")
                try t.store.write(Data(fragments[0]().utf8), to: "main.log")
            case 8:
                try t.store.rewriteInPlace(Data(String(repeating: "z", count: Int.random(in: 0...300, using: &random)).utf8), to: "main.log")
            default:
                try FileManager.default.removeItem(at: try t.store.url("main.log"))
            }
            t.poll()
            if round % 3 == 0 { t.rig.advance(Double.random(in: 0...12, using: &random)) }
            #expect(t.tailer.bufferedBytes <= LogTailer.lineLimit)
            if round % 25 == 24 {
                if !FileManager.default.fileExists(atPath: try t.store.url("main.log").path) { try t.store.write(Data(), to: "main.log"); t.poll() }
                nextLease += 1
                if try t.freshStartListens(lease: nextLease) { survived += 1 }
            }
        }
        #expect(survived == 40, "every fresh START after fuzz must give LISTENING (\(survived)/40)")
    }
}

// MARK: LogWatch over real vnode events

/// A LogWatch armed on a real file on its own serial queue. Nothing here calls `poll()`: every read happens because the kernel
/// delivered a vnode event, so the tests cover the notification and re-arm path that the direct `poll()` cases skip.
final class WatchRig {
    let queue = DispatchQueue(label: "clawd.watch-test")
    let path: String
    let tailer: LogTailer
    private let lock = NSLock()
    private var received: [String] = []
    private var diagnosed: [String] = []
    private var watch: LogWatch?

    init(path: String) {
        self.path = path
        tailer = LogTailer(path: path) { _ in }
        tailer.onLine = { [unowned self] line in self.lock.lock(); self.received.append(line); self.lock.unlock() }
        tailer.onDiagnostic = { [unowned self] key in self.lock.lock(); self.diagnosed.append(key); self.lock.unlock() }
        watch = LogWatch(reader: tailer, queue: queue)
    }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return received }
    var diagnostics: [String] { lock.lock(); defer { lock.unlock() }; return diagnosed }
    /// Polls the collected output every 5 ms, for at most `timeout` seconds: a wait that cannot hang the suite.
    func wait(timeout: Double = 5, _ condition: () -> Bool) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < end {
            if condition() { return true }
            usleep(5_000)
        }
        return condition()
    }
    func seen(_ line: String, timeout: Double = 5) -> Bool { wait(timeout: timeout) { lines.contains(line) } }
}

@Suite("LogWatch recovers through real vnode events")
struct TailerWatchSuite {
    @Test func Watch_anAppendIsDeliveredByTheVnodeEventAlone() throws {
        let store = try artifactStore()
        try store.write(Data("before\n".utf8), to: "main.log")
        let rig = WatchRig(path: try store.url("main.log").path)
        try store.append("first\n", to: "main.log")
        #expect(rig.seen("first"))
        try store.append("second\nthird\n", to: "main.log")
        #expect(rig.wait { rig.lines == ["first", "second", "third"] }, "\(rig.lines)")
        #expect(!rig.lines.contains("before"), "the start-up content is never replayed")
    }
    @Test func Watch_twoRenamesInARowAreFollowedToTheNewestFileAndItsLaterAppends() throws {
        let store = try artifactStore()
        try store.write(Data(), to: "main.log")
        let rig = WatchRig(path: try store.url("main.log").path)
        try store.append("one\n", to: "main.log")
        #expect(rig.seen("one"))
        // Both renames and both new files before the watcher thread can possibly keep up.
        try store.rename("main.log", to: "first.log")
        try store.write(Data("two\n".utf8), to: "main.log")
        try store.rename("main.log", to: "second.log")
        try store.write(Data("three\n".utf8), to: "main.log")
        #expect(rig.seen("three"), "the newest file was not read: \(rig.lines) \(rig.diagnostics)")
        #expect(rig.diagnostics.contains("rotation_followed"))
        // The watch must now sit on the newest file, not on either renamed one.
        try store.append("four\n", to: "main.log")
        #expect(rig.seen("four"), "an append to the newest file was missed: \(rig.lines)")
        try store.append("late\n", to: "second.log")
        usleep(200_000)
        #expect(!rig.lines.contains("late"), "a renamed file is no longer followed")
        #expect(rig.lines.filter { $0 == "one" }.count == 1, "\(rig.lines)")
    }
    @Test func Watch_trimInPlaceSeeksToEOFAndTheNextAppendIsDelivered() throws {
        let store = try artifactStore()
        try store.write(Data((String(repeating: "a", count: 255) + "\n").utf8), to: "main.log")
        let rig = WatchRig(path: try store.url("main.log").path)
        try store.rewriteInPlace(Data("bbbbb\n".utf8), to: "main.log")
        #expect(rig.wait { rig.diagnostics.contains("tail_resync_eof") }, "no resync: \(rig.diagnostics)")
        try store.append("fresh\n", to: "main.log")
        #expect(rig.seen("fresh"), "\(rig.lines) \(rig.diagnostics)")
        #expect(!rig.lines.contains("bbbbb"), "trimmed content is never replayed")
    }
    @Test func Watch_trimThenRegrowthPastTheOldSizeIsDetectedAndRecovered() throws {
        let store = try artifactStore()
        try store.write(Data((String(repeating: "a", count: 255) + "\n").utf8), to: "main.log")
        let rig = WatchRig(path: try store.url("main.log").path)
        // Different content, longer than the old file: only the fingerprint can tell it is not the old file continuing.
        try store.rewriteInPlace(Data((String(repeating: "b", count: 399) + "\n").utf8), to: "main.log")
        #expect(rig.wait { rig.diagnostics.contains("tail_resync_eof") }, "no resync: \(rig.diagnostics)")
        try store.append("after\n", to: "main.log")
        #expect(rig.seen("after"), "\(rig.lines) \(rig.diagnostics)")
        #expect(rig.lines.filter { $0 == "after" }.count == 1)
        try store.append("again\n", to: "main.log")
        #expect(rig.seen("again"))
    }
    @Test func Watch_aMissingDirectoryIsWatchedFromItsNearestParentAndTheFileIsReadWhenItAppears() throws {
        let parent = try artifactStore()
        let path = try parent.url("missing/deeper/main.log").path
        let rig = WatchRig(path: path)
        usleep(50_000)
        #expect(rig.lines.isEmpty)
        let child = try OwnState(root: URL(fileURLWithPath: path).deletingLastPathComponent())    // creates missing/ and deeper/
        try child.append("hello\n", to: "main.log")
        #expect(rig.seen("hello"), "\(rig.lines) \(rig.diagnostics)")
        try child.append("again\n", to: "main.log")
        #expect(rig.seen("again"), "the file created later was not watched: \(rig.lines)")
    }
    @Test func Watch_aDirectoryCreatedStepByStepIsFollowedDownToTheFile() throws {
        let parent = try artifactStore()
        let path = try parent.url("a/b/main.log").path
        let rig = WatchRig(path: path)
        let first = try OwnState(root: try parent.url("a"))
        usleep(100_000)
        let second = try OwnState(root: try first.url("b"))
        usleep(100_000)
        try second.append("one\n", to: "main.log")
        #expect(rig.seen("one"), "\(rig.lines) \(rig.diagnostics)")
        try second.append("two\n", to: "main.log")
        #expect(rig.seen("two"))
    }
    @Test func Watch_deleteThenRecreateFollowsTheNewFile() throws {
        let store = try artifactStore()
        try store.write(Data(), to: "main.log")
        let rig = WatchRig(path: try store.url("main.log").path)
        try store.append("old\n", to: "main.log")
        #expect(rig.seen("old"))
        try FileManager.default.removeItem(at: try store.url("main.log"))
        usleep(100_000)
        try store.write(Data("new\n".utf8), to: "main.log")
        #expect(rig.seen("new"), "\(rig.lines) \(rig.diagnostics)")
        try store.append("newer\n", to: "main.log")
        #expect(rig.seen("newer"))
    }
}
