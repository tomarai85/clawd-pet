import Testing
import Foundation
import CoreGraphics
import ClawdCore
import Darwin
import ClawdDesktop
import QuartzCore

// MARK: ReadOnlyFile: the only open(2) boundary for Aqua paths

@Suite("ReadOnlyFile wrapper")
struct ReadOnlyFileSuite {
    @Test func ReadOnlyFile_acceptsOnlyReadOnlyAndEventOnlyModes() {
        #expect(ReadOnlyFile.accepts(flags: O_RDONLY))
        #expect(ReadOnlyFile.accepts(flags: O_EVTONLY))
        #expect(ReadOnlyFile.accepts(flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW))
    }
    @Test func ReadOnlyFile_rejectsWriteOnly() { #expect(!ReadOnlyFile.accepts(flags: O_WRONLY)) }
    @Test func ReadOnlyFile_rejectsReadWrite() { #expect(!ReadOnlyFile.accepts(flags: O_RDWR)) }
    @Test func ReadOnlyFile_rejectsCreate() { #expect(!ReadOnlyFile.accepts(flags: O_CREAT)); #expect(!ReadOnlyFile.accepts(flags: O_RDONLY | O_CREAT)) }
    @Test func ReadOnlyFile_rejectsTruncate() { #expect(!ReadOnlyFile.accepts(flags: O_TRUNC)) }
    @Test func ReadOnlyFile_rejectsAppend() { #expect(!ReadOnlyFile.accepts(flags: O_APPEND)) }
    @Test func ReadOnlyFile_rejectsEveryCombinationAndUnknownFlagsAndThrowsBeforeOpening() throws {
        for flags in [O_WRONLY | O_CREAT | O_TRUNC, O_RDWR | O_APPEND, O_EVTONLY | O_CREAT, O_RDONLY | O_NONBLOCK, O_RDONLY | O_EXCL] {
            #expect(!ReadOnlyFile.accepts(flags: flags))
            #expect(throws: (any Error).self) { _ = try ReadOnlyFile("/path/never/opened", flags: flags) }
        }
    }
    @Test func ReadOnlyFile_theAccessModeIsComparedWithAccmodeBecauseReadOnlyIsZero() {
        #expect(O_RDONLY == 0)                                 // a plain bit test for O_RDONLY would be vacuous
        #expect((O_RDWR & O_ACCMODE) != O_RDONLY); #expect((O_WRONLY & O_ACCMODE) != O_RDONLY)
        #expect(!ReadOnlyFile.accepts(flags: O_RDWR))
    }
    @Test func ReadOnlyFile_neverCreatesAMissingFile() throws {
        let store = try artifactStore(), missing = try store.url("missing.log").path
        #expect(throws: (any Error).self) { _ = try ReadOnlyFile(missing) }
        #expect(!FileManager.default.fileExists(atPath: missing))
    }
    @Test func ReadOnlyFile_theDescriptorItselfRefusesWrites() throws {
        let store = try artifactStore()
        try store.write(Data("abc".utf8), to: "x.log")
        let file = try ReadOnlyFile(try store.url("x.log").path)
        var byte: UInt8 = 65
        #expect(Darwin.write(file.descriptor, &byte, 1) == -1); #expect(errno == EBADF)
        #expect(try file.read(offset: 1, count: 2) == Data("bc".utf8))
        #expect(try ReadOnlyFile.data(try store.url("x.log").path) == Data("abc".utf8))
    }
    @Test func ReadOnlyFile_eventOnlyDescriptorOpens() throws {
        let store = try artifactStore()
        try store.write(Data("abc".utf8), to: "x.log")
        _ = try ReadOnlyFile(try store.url("x.log").path, flags: O_EVTONLY)
    }
    @Test func ReadOnlyFile_oversizedInputIsRejectedNotTruncated() throws {
        let store = try artifactStore()
        try store.write(Data(repeating: 1, count: 100), to: "big.bin")
        #expect(throws: (any Error).self) { _ = try ReadOnlyFile.data(try store.url("big.bin").path, limit: 99) }
        #expect(try ReadOnlyFile.data(try store.url("big.bin").path, limit: 100).count == 100)
    }
    @Test func ReadOnlyFile_ownStateRefusesAquaPathsAndSymlinksAndEscapes() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(throws: (any Error).self) { _ = try OwnState(root: home.appendingPathComponent("Library/Logs/Aqua Voice/x")) }
        #expect(throws: (any Error).self) { _ = try OwnState(root: home.appendingPathComponent("Library/Application Support/Aqua Voice")) }
        let store = try artifactStore()
        #expect(throws: (any Error).self) { _ = try store.url("../escape") }
        #expect(throws: (any Error).self) { _ = try store.url("/etc/passwd") }
        try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        #expect(throws: (any Error).self) { _ = try store.url("link/file") }
    }
    @Test func ReadOnlyFile_ownStateAcceptsSystemSymlinkAncestorsButRejectsASymlinkedRoot() throws {
        // NSTemporaryDirectory lives under /var, a system symlink: ancestors above the root are not the threat.
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clawd-ownstate-" + UUID().uuidString)
        let store = try OwnState(root: temporary)
        try store.write(Data("ok".utf8), to: "a/b.txt")
        #expect(try ReadOnlyFile.data(try store.url("a/b.txt").path) == Data("ok".utf8))
    }
    @Test func ReadOnlyFile_aRootThatIsItselfASymlinkIsRefused() throws {
        let parent = try artifactStore()
        let real = parent.root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = parent.root.appendingPathComponent("link-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: (any Error).self) { _ = try OwnState(root: link) }
    }
}

// MARK: parser

@Suite("Event parser")
struct EventParserSuite {
    @Test func parserUsesAnExactAllowlist() throws {
        let parser = EventParser()
        let parsed = try fixture("allowlist.log").split(separator: "\n").compactMap { parser.parse(String($0)) }
        #expect(parsed.map(\.kind) == [.bootstrap, .lock, .canceled, .canceled, .error, .error, .shutdown])
        #expect(parser.parse("[2026-10-17T00:00:00.000Z] [info]  (Main) message dictation.start_accepted lease_id=9") == nil)
        #expect(parser.parse("[2026-10-17T00:00:00.000Z] [info]  (DictationOrchestrator) dictation.start_accepted_renamed lease_id=9") == nil)
    }
    @Test func parserAcceptsEveryKeyOfTheRealFormatFixture() throws {
        let parser = EventParser()
        let kinds = try fixture("aqua-real-sequence.log").split(separator: "\n").map { parser.parse(String($0))?.kind }
        // Sorted by time: lock 73, completed 73 (31 chars), ACK, start 74, shutdown, LLVM (ignored), bootstrap,
        // the audio-capture-stopped error and the failed-capture warning, then the two cancel lines of lease 2.
        #expect(kinds.compactMap { $0 }.count == 10)
        #expect(kinds.first == .lock)
        #expect(kinds.contains(.completed(31)))
        #expect(kinds.contains(.pasteAck(true)))
        #expect(kinds.filter { $0 == .error }.count == 2)
        #expect(kinds.filter { $0 == .canceled }.count == 2)
        #expect(kinds.filter { $0 == nil }.count == 1)            // the LLVM Profile Error line
    }
    @Test func ackKeysAreOrderIndependentAndBounded() throws {
        let parser = EventParser()
        let parsed = try fixture("ack-reordered.log").split(separator: "\n").compactMap { parser.parse(String($0)) }
        #expect(parsed.map(\.kind) == [.pasteAck(true), .pasteAck(false)])
        _ = parser.parse("[2026-10-17T00:00:00.000Z] [info]  (IPCFloating) PASTE_ACK received {")
        for _ in 0..<17 { _ = parser.parse(" unrelated: 0,") }
        #expect(parser.parse(" success: true }") == nil)
    }
    @Test func theMicrophoneStoppedReasonIsRequired() {
        let prefix = "[2026-10-17T00:00:00.000Z] [warn] (DictationOrchestrator) dictation.server_stop_received "
        let parser = EventParser()
        #expect(parser.parse(prefix + "reason=microphone_stopped")?.kind == .error)
        #expect(parser.parse(prefix + "reason=normal") == nil)
    }
    @Test func completedNeedsALeaseAndATextLength() {
        let parser = EventParser()
        let head = "[2026-10-17T00:00:00.000Z] [info]  (DictationOrchestrator) dictation.completed "
        #expect(parser.parse(head + "lease_id=3 text_length=12")?.kind == .completed(12))
        #expect(parser.parse(head + "lease_id=3 text_length=0")?.kind == .completed(0))
        #expect(parser.parse(head + "text_length=12") == nil)
        #expect(parser.parse(head + "lease_id=3") == nil)
        #expect(parser.parse(head + "lease_id=3 text_length=abc") == nil)
    }
    @Test func theEventCarriesNoTranscriptTextAndNoRawLine() throws {
        let parser = EventParser()
        let secret = "SECRET-TRANSCRIPT-WORDS"
        let raw = "[2026-10-17T00:00:00.000Z] [info]  (DictationOrchestrator) dictation.completed lease_id=3 text_length=12 \(secret)"
        let event = try #require(parser.parse(raw))
        #expect(!"\(event)".contains(secret))
        #expect(!event.key.contains(secret))
    }
    /// Aqua Voice 0.21.4's event blocks (amendment D-12 step 5): sanitized blocks of its main.log, a header and every continuation line as observed, with the
    /// numbers, the timestamp and the quoted strings made fixed and nothing else changed. Fed line by line through one parser, they give exactly these events,
    /// whole: the kind and its value, the key, the timestamp and whether a lease is carried. The ACK of 0.21.4 lists `success` first and a field is `name: value`
    /// there, `name=value` in the other lines: a parser that read only unspaced fields would give no ACK.
    @Test func EventParser_readsAquaZeroTwentyOneFoursEventBlocks() throws {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = try #require(formatter.date(from: "2026-10-17T12:00:00.000Z"))
        let parser = EventParser()
        let lines = try fixture("aqua-0.21.4-event-blocks.log").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var events: [PetEvent] = [], silent = 0
        for line in lines { if let event = parser.parse(line) { events.append(event) } else { silent += 1 } }
        let expected = [
            PetEvent(.start, key: "dictation.start_accepted", lease: 1, timestamp: date),
            PetEvent(.start, key: "dictation.start_accepted", lease: 12, timestamp: date),
            PetEvent(.lock, key: "dictation.lock_accepted", lease: 12, timestamp: date),
            PetEvent(.completed(12), key: "dictation.completed", lease: 1, timestamp: date),
            PetEvent(.completed(1), key: "dictation.completed", lease: 1, timestamp: date),
            PetEvent(.pasteAck(true), key: "PASTE_ACK", lease: nil, timestamp: date),
            PetEvent(.pasteAck(false), key: "PASTE_ACK", lease: nil, timestamp: date),
            PetEvent(.bootstrap, key: "app.bootstrap", lease: nil, timestamp: date),
            PetEvent(.shutdown, key: "shutdown", lease: nil, timestamp: date),
        ]
        #expect(events == expected, "\(events)")
        #expect(events.count == lines.count - silent && silent == lines.filter { $0.hasPrefix("#") }.count, "no line gives any other event: \(silent) silent lines")
    }

    @Test func garbageAndHalfFormedLinesNeverParse() {
        let parser = EventParser()
        for text in ["", "[", "[2026-", "[2026-10-17T00:00:00.000Z] [info", "[not-a-date] [info] (X) y", "\u{0}\u{1}",
                     "[2026-10-17T00:00:00.000Z] [info]"] {
            #expect(parser.parse(text) == nil, "\(text.debugDescription)")
        }
    }
}

// MARK: placement, process identity, usage

@Suite("Placement and process helpers")
struct PlacementAndProcessSuite {
    @Test func placementClampsAMissingDisplayAndBoundsTheScale() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900), visible = CGRect(x: 0, y: 30, width: 1440, height: 840)
        let size = CGSize(width: 48, height: 44)
        let saved = SavedPosition(displayUUID: "unplugged", xFrac: 2, feetFrac: -1)
        #expect(Placement.origin(position: saved, display: display, visible: visible, size: size) == CGPoint(x: 1392, y: 30))
        // The size is the one picked on every display (2026-11-09): bounded to 0.5...4, never cut by the backing.
        #expect(Placement.effectiveScale(1.5) == 1.5); #expect(Placement.effectiveScale(0.75) == 0.75); #expect(Placement.effectiveScale(0.5) == 0.5)
        #expect(Placement.effectiveScale(.nan) == 1); #expect(Placement.effectiveScale(9) == 4); #expect(Placement.effectiveScale(0.25) == 0.5)
        let origin = CGPoint(x: 400, y: 50)
        let stored = Placement.fractions(origin: origin, size: size, display: display, uuid: "fixture", scale: 1)
        #expect(Placement.origin(position: stored, display: display, visible: visible, size: size) == origin)
    }
    @Test func xIsTheCentreFractionAndYIsTheFeetFraction() {
        let display = CGRect(x: 100, y: 50, width: 1000, height: 500), visible = display
        let size = CGSize(width: 48, height: 48)
        let origin = Placement.origin(position: SavedPosition(xFrac: 0.5, feetFrac: 0.2), display: display, visible: visible, size: size)
        #expect(origin == CGPoint(x: 100 + 500 - 24, y: 50 + 100))
    }
    @Test func aMissingDisplayFallsBackToMainAndAKnownOneIsFound() {
        let displays: [(uuid: String?, value: String)] = [("A", "first"), (nil, "unnamed"), ("B", "second")]
        #expect(Placement.resolveDisplay(saved: "B", displays: displays, fallback: "main") == "second")
        #expect(Placement.resolveDisplay(saved: "gone", displays: displays, fallback: "main") == "main")
        #expect(Placement.resolveDisplay(saved: nil, displays: displays, fallback: "main") == "main")
    }
    @Test func theFallbackSpotSitsLeftOfCentreAboveTheDockAndTheDefaultBodyIs48Points() {
        let spot = Placement.fallbackPosition(display: CGRect(x: 0, y: 0, width: 3440, height: 1440), visible: CGRect(x: 0, y: 30, width: 3440, height: 1410))
        #expect(abs(spot.xFrac - (0.5 - 120.0 / 3440)) < 1e-12); #expect(abs(spot.feetFrac - 45.0 / 1440) < 1e-12)
        #expect(Placement.defaultBodyWidth == 48)
    }
    @Test func usageReadsCpuAndWakeupsForTheSameProcessAndRefusesAVanishedOne() throws {
        let first = try ProcessUsage.read(pid: getpid())
        var spin = 0.0; for i in 0..<2_000_000 { spin += Double(i).squareRoot() }
        #expect(spin > 0)
        let second = try ProcessUsage.read(pid: getpid())
        let delta = try second.delta(from: first)
        #expect(delta.seconds > 0); #expect(delta.seconds < 30)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try child.run(); child.waitUntilExit()
        #expect(throws: (any Error).self) { _ = try ProcessUsage.read(pid: child.processIdentifier) }   // a failed read is never zero
    }
    @Test func usageCpuTimeIsRealNanosecondsNotMachTicks() throws {
        // proc_pid_rusage reports mach absolute time ticks (125/3 ns each on Apple Silicon). Burn about 0.3 s of CPU and compare the
        // converted delta with getrusage, which is in plain microseconds: unconverted ticks would read about 40 times too small.
        func cpuSeconds() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        }
        let firstUsage = try ProcessUsage.read(pid: getpid()), firstReference = cpuSeconds()
        var spin = 0.0
        // Burn until the reference sees 0.3 s of CPU (not 0.3 s of wall time, which a loaded machine does not turn into CPU time);
        // the 10 s wall cap only stops a machine that never schedules this thread.
        let cap = ProcessInfo.processInfo.systemUptime + 10
        while cpuSeconds() - firstReference < 0.3, ProcessInfo.processInfo.systemUptime < cap { for i in 0..<20_000 { spin += Double(i).squareRoot() } }
        #expect(spin > 0)
        let secondUsage = try ProcessUsage.read(pid: getpid()), secondReference = cpuSeconds()
        let measured = try secondUsage.delta(from: firstUsage).seconds, reference = secondReference - firstReference
        #expect(reference > 0.25, "the reference did not see the burn: \(reference)")
        #expect(measured >= reference * 0.5 && measured <= reference * 2 + 0.1, "measured \(measured) s against getrusage \(reference) s")
    }
    @Test func aDeltaAcrossDifferentIdentitiesOrABackwardsCounterIsAFailureNotZero() throws {
        let me = try ProcessUsage.read(pid: getpid())
        let other = Process(); other.executableURL = URL(fileURLWithPath: "/bin/sleep"); other.arguments = ["5"]; try other.run()
        defer { other.terminate(); other.waitUntilExit() }
        let theirs = try ProcessUsage.read(pid: other.processIdentifier)
        #expect(throws: (any Error).self) { _ = try theirs.delta(from: me) }
        let later = try ProcessUsage.read(pid: getpid())
        #expect(throws: (any Error).self) { _ = try me.delta(from: later) }
    }
}

// MARK: windowless idle entry and the CPU measurement tool

@Suite("Idle budget measurement")
struct IdleBudgetSuite {
    @Test func IdleBudget_testIdleEntryRunsWithoutAWindowAndTheMeasurementReportsItsBudget() throws {
        let home = try artifactStore().root
        let state = home.appendingPathComponent("state")
        let agent = Process(); agent.executableURL = agentExecutable()
        agent.arguments = ["--test-idle", "8", state.path]
        agent.environment = ProcessInfo.processInfo.environment.merging(["HOME": home.path]) { $1 }
        agent.environment?.removeValue(forKey: "XPC_SERVICE_NAME")
        let out = Pipe(); agent.standardOutput = out; agent.standardError = out
        try agent.run()
        defer { agent.terminate(); agent.waitUntilExit() }
        let ready = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        #expect(ready.contains("IDLE-READY pid=\(agent.processIdentifier)"))
        #expect(windowCount(ownedBy: agent.processIdentifier) == 0)
        let json = home.appendingPathComponent("measure.json")
        let run = try execute(builtTool("clawd-measure-cpu"), [String(agent.processIdentifier), state.path, "--seconds", "3", "--json", json.path])
        #expect(run.code == 0, "\(run.output)")
        let report = try #require(JSONSerialization.jsonObject(with: try ReadOnlyFile.data(json.path)) as? [String: Any])
        #expect(report["mode"] as? String == "test-idle-no-window")
        #expect((report["duration_s"] as? Double ?? 0) >= 3)
        #expect(report["pid_start"] as? Int == Int(agent.processIdentifier)); #expect(report["pid_end"] as? Int == Int(agent.processIdentifier))
        #expect(report["start_time_start"] as? String == report["start_time_end"] as? String)
        #expect(report["state_log_idle_whole_window"] as? Bool == true)
        #expect((report["cpu_delta_s"] as? Double ?? 9) < 0.3)
        #expect((report["wakeups_delta"] as? Int ?? 9999) < 600)
        #expect((report["agent_sha256"] as? String)?.count == 64)
        #expect(windowCount(ownedBy: agent.processIdentifier) == 0)
    }
    @Test func IdleBudget_aVanishedProcessIsAFailureNotAZero() throws {
        let state = try artifactStore().root
        let store = try OwnState(root: state)
        var status = AgentStatus(); status.idleBudgetMode = true
        try store.writeJSON(status, to: "status.json"); try store.append("STATE scene=idle\n", to: "agent.log")
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try child.run(); child.waitUntilExit()
        let run = try execute(builtTool("clawd-measure-cpu"), [String(child.processIdentifier), state.path, "--seconds", "1"])
        #expect(run.code == 2); #expect(run.output.contains("FAIL"))
    }
    @Test func IdleBudget_aNonIdleStateLogFailsTheMeasurement() throws {
        let home = try artifactStore().root
        let state = home.appendingPathComponent("state")
        let store = try OwnState(root: state)
        var status = AgentStatus(); status.idleBudgetMode = true
        try store.writeJSON(status, to: "status.json"); try store.append("STATE scene=idle\n", to: "agent.log")
        // The measured process outlives any loaded run (the tool's exit 2 also means a missing process, so a fixture that dies first turns
        // this test's answer into a different failure, as a 6 s sleeper did at load 20); the defer ends it.
        let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["120"]; try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        // A scene line must land AFTER the tool has taken its start offset, however late a busy machine starts it: one line every 0.2 s until it
        // ends. A thread of its own writes them: a GCD timer on the global queue starves while the other suites block its worker threads.
        final class Stop: @unchecked Sendable { private let lock = NSLock(); private var flag = false
            var stopped: Bool { lock.lock(); defer { lock.unlock() }; return flag }
            func stop() { lock.lock(); flag = true; lock.unlock() } }
        let stop = Stop()
        let appender = Thread { while !stop.stopped { try? store.append("STATE scene=listening\n", to: "agent.log"); usleep(200_000) } }
        appender.start(); defer { stop.stop() }
        let run = try execute(builtTool("clawd-measure-cpu"), [String(sleeper.processIdentifier), state.path, "--seconds", "2"])
        #expect(run.code == 1, "code \(run.code) after \(run.elapsed) s: \(run.output)"); #expect(run.output.hasPrefix("FAIL")); #expect(run.output.contains("quiet_log=false"))
        #expect(sleeper.isRunning, "the measured process ended before the tool did")
    }
    /// agent.log rotating inside the window moves the file the tool opened at the start to agent.log.1, and the window's later lines go to a
    /// new agent.log that its read would never see: the measurement fails rather than reading a quiet window (amendment agent-log-retention).
    /// The log rotates every 0.4 s for the whole run, so the window holds a rotation however late a busy machine starts the tool. The exit
    /// code tells the outcomes apart: 2 is the rotation guard; 1 would be a `STATE scene=` line the tool saw (it counts as a dictation); 0
    /// would be a rotation the tool missed, reading only the file it opened.
    @Test func MeasureCPU_aRotationInsideTheWindowFailsTheMeasurement() throws {
        let home = try artifactStore().root
        let state = home.appendingPathComponent("state")
        let store = try OwnState(root: state)
        var status = AgentStatus(); status.idleBudgetMode = true
        try store.writeJSON(status, to: "status.json"); try store.append("STATE scene=idle\n", to: "agent.log")
        // Exit 2 is also a missing process: the measured process must outlive the tool, or a dead fixture would pass this test (see below).
        let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["120"]; try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        final class Stop: @unchecked Sendable { private let lock = NSLock(); private var flag = false
            var stopped: Bool { lock.lock(); defer { lock.unlock() }; return flag }
            func stop() { lock.lock(); flag = true; lock.unlock() } }
        let stop = Stop()
        let log = state.appendingPathComponent("agent.log"), old = state.appendingPathComponent("agent.log.1")
        let rotator = Thread {
            while !stop.stopped {
                try? FileManager.default.removeItem(at: old); try? FileManager.default.moveItem(at: log, to: old)
                try? store.append("STATE scene=idle\n", to: "agent.log"); usleep(400_000)
            }
        }
        rotator.start(); defer { stop.stop() }
        let run = try execute(builtTool("clawd-measure-cpu"), [String(sleeper.processIdentifier), state.path, "--seconds", "2"])
        #expect(run.code == 2, "code \(run.code) after \(run.elapsed) s: \(run.output)"); #expect(run.output.hasPrefix("FAIL"))
        #expect(sleeper.isRunning, "the measured process ended before the tool did, so exit 2 may mean a missing process, not the rotation")
    }
}

// MARK: the render-path idle mode

@Suite("Idle budget with the production render path")
struct IdleRenderSuite {
    @Test func IdleRender_theRenderCallbackRunsOverAShortVirtualWindowAndSleepStaysOff() throws {
        let clock = VirtualClock(), scheduler = FakeScheduler(clock: clock)
        let run = try IdleRenderRun(clock: clock, scheduler: scheduler, art: artDirectory, pixelScale: 2)
        run.controller.randomUnit = { 0.5 }
        run.controller.setAquaRunning(true)
        #expect(run.renderCount > 0, "entering IDLE must render once")
        let atStart = run.renderCount
        advanceVirtual(clock: clock, scheduler: scheduler, runtime: run.runtime, by: 12)
        // Blinks every 3-7 s: a blink start and a blink end render each, so 12 s hold at least two blinks.
        #expect(run.renderCount >= atStart + 4, "renders: \(atStart) -> \(run.renderCount)")
        let frame = try #require(run.lastFrame)
        #expect(frame.pixelScale == 2); #expect(frame.size.width == 48); #expect(frame.image.width == 96)
        #expect(run.layer.contents != nil); #expect(frame.pixels.count == frame.image.width * frame.image.height * 4)
        advanceVirtual(clock: clock, scheduler: scheduler, runtime: run.runtime, by: 700)
        #expect(run.controller.machine.scene == .idle, "the SLEEP transition must stay disabled")
        #expect(run.controller.ownedTimers == 1)
    }
    @Test func IdleRender_aBlinkRendersTheBlinkPoseThroughTheSharedPipeline() throws {
        let clock = VirtualClock(), scheduler = FakeScheduler(clock: clock)
        let run = try IdleRenderRun(clock: clock, scheduler: scheduler, art: artDirectory, pixelScale: 1)
        run.controller.randomUnit = { 0.0 }       // first blink exactly 3 s after entering IDLE
        run.controller.setAquaRunning(true)
        let open = try #require(run.lastFrame).pixels
        advanceVirtual(clock: clock, scheduler: scheduler, runtime: run.runtime, by: 3.05)
        #expect(run.controller.state().blink)
        let closed = try #require(run.lastFrame).pixels
        #expect(open != closed, "the blink frame differs from the open-eyed frame")
        advanceVirtual(clock: clock, scheduler: scheduler, runtime: run.runtime, by: 0.2)
        #expect(try #require(run.lastFrame).pixels == open)
    }
    @Test func IdleRender_theCounterFileCountsEachRenderAndIsReadBack() throws {
        let store = try artifactStore()
        let counter = try store.counter("renders.count")
        let clock = VirtualClock(), scheduler = FakeScheduler(clock: clock)
        let run = try IdleRenderRun(clock: clock, scheduler: scheduler, art: artDirectory, pixelScale: 1, counter: counter)
        run.controller.setAquaRunning(true)
        advanceVirtual(clock: clock, scheduler: scheduler, runtime: run.runtime, by: 20)
        #expect(run.renderCount > 1)
        #expect(try FileCounter.read(path: try store.url("renders.count").path) == UInt64(run.renderCount))
        #expect(throws: (any Error).self) { _ = try FileCounter.read(path: try store.url("missing.count").path) }
    }
    @Test func IdleRender_theHeadlessEntryRendersWithoutAWindowAndTheMeasurementCountsTheRenders() throws {
        let home = try artifactStore().root
        let state = home.appendingPathComponent("state")
        let agent = Process(); agent.executableURL = agentExecutable()
        agent.arguments = ["--test-idle-render", "16", state.path, artDirectory.path]
        agent.environment = ProcessInfo.processInfo.environment.merging(["HOME": home.path]) { $1 }
        agent.environment?.removeValue(forKey: "XPC_SERVICE_NAME")
        let out = Pipe(); agent.standardOutput = out; agent.standardError = out
        try agent.run()
        defer { agent.terminate(); agent.waitUntilExit() }
        let ready = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        #expect(ready.contains("IDLE-READY pid=\(agent.processIdentifier)"))
        #expect(windowCount(ownedBy: agent.processIdentifier) == 0)
        let json = home.appendingPathComponent("measure.json")
        // A 9 s window starting about a second after the start always holds a blink (the first one is 3-7 s in).
        let run = try execute(builtTool("clawd-measure-cpu"), [String(agent.processIdentifier), state.path, "--seconds", "9", "--json", json.path])
        #expect(run.code == 0, "\(run.output)")
        let report = try #require(JSONSerialization.jsonObject(with: try ReadOnlyFile.data(json.path)) as? [String: Any])
        #expect(report["mode"] as? String == "test-idle-render-no-window")
        #expect((report["render_count_delta"] as? Int ?? 0) > 0, "no render inside the measured window")
        #expect(report["pid_start"] as? Int == Int(agent.processIdentifier)); #expect(report["pid_end"] as? Int == Int(agent.processIdentifier))
        #expect(report["state_log_idle_whole_window"] as? Bool == true)
        #expect((report["cpu_delta_s"] as? Double ?? 9) < 0.3); #expect((report["wakeups_delta"] as? Int ?? 9999) < 600)
        #expect(windowCount(ownedBy: agent.processIdentifier) == 0)
        #expect(try FileCounter.read(path: state.appendingPathComponent("renders.count").path) > 0)
    }
    @Test func IdleRender_aRenderModeWindowWithoutRendersFailsTheMeasurement() throws {
        let state = try artifactStore().root
        let store = try OwnState(root: state)
        var status = AgentStatus(); status.idleBudgetMode = true; status.mode = IdleRenderRun.modeName
        try store.writeJSON(status, to: "status.json"); try store.append("STATE scene=idle\n", to: "agent.log")
        _ = try store.counter(IdleRenderRun.counterFile)       // present, never incremented
        // The measured process outlives both runs, so the second run's exit 2 can only be the missing counter, never a missing process.
        let sleeper = Process(); sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["120"]; try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        let run = try execute(builtTool("clawd-measure-cpu"), [String(sleeper.processIdentifier), state.path, "--seconds", "2"])
        #expect(run.code == 1); #expect(run.output.hasPrefix("FAIL")); #expect(run.output.contains("renders=0"))
        // A render-mode state directory with no counter file at all is a failed read, never a pass.
        let bare = try artifactStore().root
        let bareStore = try OwnState(root: bare)
        try bareStore.writeJSON(status, to: "status.json"); try bareStore.append("STATE scene=idle\n", to: "agent.log")
        let missing = try execute(builtTool("clawd-measure-cpu"), [String(sleeper.processIdentifier), bare.path, "--seconds", "1"])
        #expect(missing.code == 2)
        #expect(sleeper.isRunning, "the measured process ended before the tool did")
    }
}
