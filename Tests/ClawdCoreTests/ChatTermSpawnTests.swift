import Testing
import Foundation
import Darwin
import ClawdProcess
@testable import ClawdCore

/// Part B, against the real PTY spawn (the agent binary's trampoline and guard) with the stub's `tty` mode as claude.
@Suite("ChatTermSpawn", .serialized)
@MainActor
struct ChatTermSpawnTests {
    @Test func ChatTermSpawn_theChildHasThePtyAsItsControllingTerminalAndOnlyDescriptorsZeroToTwo() async throws {
        // A descriptor without close-on-exec, opened just before the spawn, gives the check below something to leak.
        let leak = Darwin.open("/dev/null", O_RDONLY)
        defer { close(leak) }
        #expect(fcntl(leak, F_GETFD) & FD_CLOEXEC == 0)
        let rig = try TermRig()
        try rig.start([])
        #expect(await rig.wait { rig.report() != nil }, "the stub reported: \(rig.text)")
        let report = try #require(rig.report())
        #expect(report["isatty"] == "1,1,1")
        #expect(report["tty"] == "ok", "/dev/tty opens: the PTY slave is the controlling terminal")
        #expect(report["pid"] == report["pgid"] && report["pid"] == report["sid"], "a session leader: \(report)")
        #expect(report["fds"] == "0,1,2", "no descriptor of the agent reaches claude: \(report["fds"] ?? "-")")
        await rig.finish()
    }

    @Test func ChatTermSpawn_theEnvironmentIsF21sPlusTermWithAFreshTokenPerSpawn() async throws {
        let rig = try TermRig()
        let first = try rig.start([])
        #expect(await rig.wait { rig.report() != nil })
        let one = try #require(rig.report())
        var expected: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "LANG", "PATH", "CLAWD_CHAT", "CLAWD_CHAT_SPAWN", "TERM", "COLORTERM"]
        if ProcessInfo.processInfo.environment["TMPDIR"] != nil { expected.insert("TMPDIR") }
        // CoreFoundation adds __CF_USER_TEXT_ENCODING to the stub's own environment when it starts; the agent passes nothing of the kind.
        let names = Set((one["env"] ?? "").split(separator: ",").map(String.init)).subtracting(["__CF_USER_TEXT_ENCODING"])
        #expect(names == expected, "the names: \(one["env"] ?? "-")")
        #expect(one["token"] == first.token)
        let other = try TermRig()
        let second = try other.start([])
        #expect(await other.wait { other.report() != nil })
        #expect(other.report()?["token"] == second.token && second.token != first.token, "two spawns, two tokens")
        await rig.finish(); await other.finish()
    }

    @Test func ChatTermSpawn_theArgumentsForFreshResumeEachPermissionAndModel() {
        let fresh = ChatTermLaunch.arguments(mode: .fresh("u-1"), permissions: .bypass, model: nil)
        #expect(fresh == ["--session-id", "u-1", "--permission-mode", "bypassPermissions"])
        let resume = ChatTermLaunch.arguments(mode: .resume("u-2"), permissions: .deny, model: "opus-4.5")
        #expect(resume == ["--resume", "u-2", "--permission-mode", "dontAsk", "--model", "opus-4.5"])
        for arguments in [fresh, resume] {
            for banned in ["-p", "--continue", "--permission-prompts", "--output-format", "--input-format", "stream-json"] {
                #expect(!arguments.contains(banned), "\(banned) is never passed")
            }
        }
        #expect(!fresh.contains("--model"), "--model only when set")
    }

    @Test func ChatTermSpawn_theMasterIsCloseOnExecAndNeverReachesALaterChild() async throws {
        let rig = try TermRig()
        var master: Int32 = -1
        rig.config.ptyObserver = { opened, _ in master = opened }
        try rig.start([])
        #expect(master >= 0)
        #expect(fcntl(master, F_GETFD) & FD_CLOEXEC != 0, "the master is close-on-exec")
        // A child started the way MenuWriter starts its own (Foundation's Process) lists descriptors 0-2 only.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TermRig.stub)
        process.arguments = ["tty", "report"]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        defer { process.terminate() }
        var collected = Data()
        let end = Date().addingTimeInterval(30)
        while Date() < end, !String(decoding: collected, as: UTF8.self).contains("\r\n") {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            collected.append(chunk)
        }
        #expect(String(decoding: collected, as: UTF8.self).hasPrefix("F 0,1,2\r\n"), "a later child inherits neither end of the PTY: \(String(decoding: collected, as: UTF8.self))")
        await rig.finish()
    }

    @Test func ChatTermSpawn_aHardStopLeavesNoTokenProcessAt3sDetachedEscapeesIncluded() async throws {
        let rig = try TermRig()
        let child = try rig.start(["escapees"])
        #expect(await rig.wait { rig.lines(prefix: "E ").count == 1 })
        let pids = rig.lines(prefix: "E ")[0].split(separator: " ").dropFirst().compactMap { Int32($0) }
        try #require(pids.count == 2 && pids.allSatisfy { $0 > 1 }, "the escapees' pids: \(rig.lines(prefix: "E "))")
        let identities = pids.compactMap { ChatProc.identity(of: $0) }
        #expect(identities.count == 2, "both escapees run")
        let parent = ChatProc.table().first { $0.identity.pid == pids[1] }
        #expect(parent?.parent == 1 || parent == nil, "the double-forked one is an orphan of launchd")
        child.stop(graceful: false, reason: "exam")
        #expect(await rig.wait { child.hasEnded })
        #expect(rig.stops.last?.left == 0, "the check at D finds nothing left: \(rig.stops)")
        #expect(identities.allSatisfy { processIsGone($0) }, "the escapees are gone")
        #expect(rig.carriers(child.token) == 0)
        #expect(rig.logs.contains { $0.hasPrefix("CHAT stop reason=exam") } && rig.logs.contains { $0.hasPrefix("CHAT sweep n=") && $0.hasSuffix("left=0") })
        await rig.finish()
    }

    @Test func ChatTermSpawn_closingTheMasterHangsUpTheChild() async throws {
        let rig = try TermRig()
        let record = rig.folder + "/hup.txt"
        let child = try rig.start(["record=" + record])
        #expect(await rig.wait { rig.report() != nil })
        let began = DispatchTime.now().uptimeNanoseconds
        child.teardown()
        #expect(await rig.wait { fileLines(record).contains { $0.hasPrefix("HUP ") } })
        let hup = fileLines(record).first { $0.hasPrefix("HUP ") }.flatMap { UInt64($0.dropFirst(4)) }
        let seconds: Double = hup.map { Double($0 &- began) / 1e9 } ?? -1
        #expect(seconds >= 0 && seconds < 1.0, "SIGHUP within 1 s of the master's close: \(seconds)")
        await rig.finish()
    }

    @Test func ChatTermSpawn_aNewGridSizeReachesTheChildAsItsWindowSize() async throws {
        let rig = try TermRig()
        let child = try rig.start([], columns: 80, rows: 24)
        #expect(await rig.wait { rig.report() != nil })
        #expect(rig.report()?["size"] == "80x24", "the size at the start")
        child.resize(columns: 100, rows: 40)
        #expect(await rig.wait(5) { rig.lines(prefix: "W ").contains("W 100x40") }, "the stub reports the new size: \(rig.text)")
        await rig.finish()
    }

    @Test func ChatTermSpawn_aChildThatStopsItselfIsContinued() async throws {
        let rig = try TermRig()
        try rig.start(["stop-self"])
        #expect(await rig.wait(10) { rig.text.contains("RESUMED") }, "the stub runs again after it stopped itself: \(rig.text)")
        #expect(rig.logs.contains { $0.hasPrefix("CHAT term continued pid=") && $0.hasSuffix("cause=stopped") })
        await rig.finish()
        // A Ctrl+Z byte typed in the view reaches the stub, which then records a SIGCONT.
        let other = try TermRig()
        let record = other.folder + "/cont.txt"
        let child = try other.start(["record=" + record])
        #expect(await other.wait { other.report() != nil })
        let sent = DispatchTime.now().uptimeNanoseconds
        #expect(child.send(Data([0x1a])))
        #expect(await other.wait(10) { other.text.contains("H 1a") }, "the byte reached the stub")
        #expect(await other.wait(10) { fileLines(record).contains { $0.hasPrefix("CONT ") } })
        let at = fileLines(record).first { $0.hasPrefix("CONT ") }.flatMap { UInt64($0.dropFirst(5)) }
        let after: Double = at.map { Double($0 &- sent) / 1e9 } ?? -1
        #expect(after >= 0 && after < 1.0, "the SIGCONT comes within 1 s of the key: \(after)")
        #expect(await other.wait(10) { other.logs.contains { $0.hasPrefix("CHAT term continued pid=") && $0.hasSuffix("cause=ctrl-z") } })
        await other.finish()
    }

    @Test func ChatTermSpawn_aMissingClaudeOrFolderRefusesAndSpawnsNothing() async throws {
        var settings = ChatSettings(home: NSTemporaryDirectory())
        settings.claude = "/private/tmp/clawd-no-such-claude-" + UUID().uuidString
        settings.folder = NSTemporaryDirectory()
        #expect(ChatTermRefusal.resolve(settings) == .failure(.missingBinary))
        #expect(ChatTermRefusal.missingBinary.reason == "missing-binary")
        settings.claude = TermRig.stub
        settings.folder = "/private/tmp/clawd-no-such-folder-" + UUID().uuidString
        #expect(ChatTermRefusal.resolve(settings) == .failure(.folderMissing))
        #expect(ChatTermRefusal.folderMissing.reason == "folder-missing")
        settings.folder = NSTemporaryDirectory()
        #expect(ChatTermRefusal.resolve(settings) == .success(URL(fileURLWithPath: TermRig.stub).resolvingSymlinksInPath().path))
        // A refusal before the spawn writes no token: nothing was started.
        let rig = try TermRig()
        #expect(try rig.state.read().tokens.isEmpty)
    }

    /// SA4 N-1: the terminal view's own refusal line, not only ChatSession's. With no path set it names the places searched; with a path set
    /// that is missing, it names that path. Either way nothing is spawned.
    @Test func ChatTermSpawn_theRefusalLineNamesTheSearchedPlacesOrTheGivenPath() async throws {
        let r = try TermControllerRig()
        r.claudeSearch = [r.folder + "/no-such-a", r.folder + "/no-such-b"]
        r.open()
        #expect(await r.wait(10) { r.lines("CHAT refuse").contains("CHAT refuse reason=missing-binary") }, "\(r.lines("CHAT"))")
        #expect(await r.waitScreen("Claude Code was not found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin. Install it, or set the path with",
                                   10), "\(r.screen)")
        #expect(r.spawns == 0)
        await r.finish()
        let g = try TermControllerRig()
        let missing = "/private/tmp/clawd-no-such-claude-" + UUID().uuidString
        g.claude = missing
        g.open()
        #expect(await g.waitScreen("Claude Code was not found at \(missing). Install it", 10), "\(g.screen)")
        #expect(g.spawns == 0)
        await g.finish()
    }

    @Test func ChatTermSpawn_theTrampolineIsDispatchedBeforeTheLaunchGuardAndExecsInPlace() async throws {
        let main = String(decoding: try ReadOnlyFile.data(repository.appendingPathComponent("Sources/ClawdAgent/main.swift").path), as: UTF8.self)
        var cursor = main.startIndex
        for token in ["\"--pty-exec\"", "LaunchGuard.allowed()"] {
            let range = try #require(main.range(of: token, range: cursor..<main.endIndex), "missing or out of order: \(token)")
            cursor = range.upperBound
        }
        let rig = try TermRig()
        let child = try rig.start([])
        #expect(await rig.wait { rig.report() != nil })
        #expect(rig.report()?["pid"] == String(child.pid), "the pid posix_spawn returned is the stub's own: it exec'd in place")
        await rig.finish()
    }

    @Test func ChatTermSpawn_theTrampolineClosesEveryDescriptorAboveTwoBeforeItsExec() async throws {
        let pair = try TermProc.openPair(columns: 80, rows: 24)
        defer { close(pair.master); close(pair.slave) }
        let spare = Darwin.open("/dev/null", O_RDONLY)
        defer { close(spare) }
        // posix_spawn without CLOEXEC_DEFAULT, on purpose: descriptors 5 and 9 are inherited, with whatever else this process holds.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes); defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions); defer { posix_spawn_file_actions_destroy(&actions) }
        for number: Int32 in 0...2 { posix_spawn_file_actions_adddup2(&actions, pair.slave, number) }
        posix_spawn_file_actions_adddup2(&actions, spare, 5)
        posix_spawn_file_actions_adddup2(&actions, spare, 9)
        // Typed locals: Swift 6.3.1 (Friday) cannot pick the URL.path overload inside the array literal.
        let exePath: String = agentExecutable().path
        let argStrings: [String] = [exePath, "--pty-exec", "--", TermRig.stub, "tty", "report"]
        let argv: [UnsafeMutablePointer<CChar>?] = argStrings.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        #expect(posix_spawn(&pid, exePath, &actions, &attributes, argv, environ) == 0)
        let identity = ChatProc.identity(of: pid)
        defer { if let identity { ChatProc.signal(identity, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) } }
        var collected = Data()
        let end = Date().addingTimeInterval(60)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < end, !String(decoding: collected, as: UTF8.self).contains("\r\n") {
            var wait = pollfd(fd: pair.master, events: Int16(POLLIN), revents: 0)
            if poll(&wait, 1, 100) > 0 {
                let n = read(pair.master, &buffer, buffer.count)
                if n > 0 { collected.append(contentsOf: buffer[0..<n]) }
            }
        }
        #expect(String(decoding: collected, as: UTF8.self).contains("F 0,1,2\r\n"), "the stub lists exactly 0, 1 and 2: \(String(decoding: collected, as: UTF8.self))")
    }

    @Test func ChatTermSpawn_ptyDescriptorsAreCloseOnExecFromTheirOpenAndTheAgentsSlaveIsClosedAfterTheSpawn() async throws {
        let rig = try TermRig()
        var atOpen: (master: Int32, slave: Int32, masterFlags: Int32, slaveFlags: Int32, slaveDevice: dev_t)?
        rig.config.ptyObserver = { master, slave in
            var info = stat(); fstat(slave, &info)
            atOpen = (master, slave, fcntl(master, F_GETFD), fcntl(slave, F_GETFD), info.st_rdev)
        }
        let child = try rig.start([])
        let opened = try #require(atOpen)
        #expect(opened.masterFlags & FD_CLOEXEC != 0 && opened.slaveFlags & FD_CLOEXEC != 0, "both are close-on-exec right after the open")
        var info = stat()
        let stillTheSlave = fstat(opened.slave, &info) == 0 && info.st_rdev == opened.slaveDevice
        #expect(!stillTheSlave, "the agent's slave descriptor is closed after the spawn (EBADF, or the number names another file)")
        #expect(await rig.wait { rig.report() != nil })
        // With the stub gone and nothing else holding the slave, the reader sees the end of the master and closes it itself.
        let identity = try #require(child.identity)
        ChatProc.signal(identity, SIGKILL)
        #expect(await rig.wait(30) { !rig.closes.list.isEmpty }, "the master was closed")
        let closes = rig.closes.list
        #expect(closes.count == 1 && closes[0].descriptor == opened.master && closes[0].onReader, "closed once, by the reader thread")
        #expect(closes.first?.byWake == false, "the reader saw the end of the master, not the wake descriptor")
        await rig.finish()
    }

    @Test func ChatTermSpawn_aStopHangsUpByASignalAndOnlyTheReaderClosesTheMaster() async throws {
        let rig = try TermRig()
        let record = rig.folder + "/hup.txt"
        var master: (number: Int32, device: dev_t)?
        rig.config.ptyObserver = { opened, slave in
            var info = stat(); fstat(opened, &info)
            master = (opened, info.st_rdev)
        }
        let child = try rig.start(["record=" + record])
        let opened = try #require(master)
        #expect(await rig.wait { rig.report() != nil })
        #expect(rig.closes.list.isEmpty)
        child.stop(graceful: true, reason: "idle")
        #expect(await rig.wait(30) { fileLines(record).contains { $0.hasPrefix("HUP ") } }, "the stub recorded the SIGHUP")
        // The hang-up is a signal, not a close: at this sync point (the stop is still in its first second) the master is still open.
        var info = stat()
        #expect(fstat(opened.number, &info) == 0 && info.st_rdev == opened.device && rig.closes.list.isEmpty, "the stop closed no descriptor of the master")
        #expect(await rig.wait(30) { child.hasEnded })
        #expect(await rig.wait(30) { !rig.closes.list.isEmpty })
        let closes = rig.closes.list
        #expect(closes.count == 1 && closes[0].onReader, "the master is closed exactly once, by the reader thread, after the stop: \(closes)")
        await rig.finish()
    }

    @Test func ChatTermSpawn_aHiddenOrphanThatExecsIntoATokenCarrierJoinsTheSetAndIsStopped() async throws {
        let rig = try TermRig(trackSeconds: 0)
        let gate = rig.folder + "/go"
        let child = try rig.start(["exec-late=" + gate])
        #expect(await rig.wait(60) { rig.lines(prefix: "L ").count == 1 })
        let perl = try #require(rig.lines(prefix: "L ").first.flatMap { Int32($0.dropFirst(2)) }, "the stub reported perl's pid: \(rig.text)")
        // Orphaned (its subshell is gone), a platform binary: its environment is hidden, so a growth leaves it out.
        #expect(await rig.wait(30) { ChatProc.table().first { $0.identity.pid == perl }?.parent == 1 })
        #expect(!child.growOnce().contains { $0.pid == perl }, "perl is not in the set before it execs")
        FileManager.default.createFile(atPath: gate, contents: Data())
        let stubPath = URL(fileURLWithPath: TermRig.stub).resolvingSymlinksInPath().path
        #expect(await rig.wait(60) { (try? ProcessPath.of(pid: perl)).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == stubPath })
        #expect(child.growOnce().contains { $0.pid == perl }, "after the exec its environment is readable: it carries the token and joins the set")
        let identity = ChatProc.identity(of: perl)
        child.stop(graceful: false, reason: "exam")
        #expect(await rig.wait { child.hasEnded })
        #expect(rig.stops.last?.left == 0)
        #expect(processIsGone(identity), "no token process is left at 3 s")
        await rig.finish()
    }

    @Test func ChatTermSpawn_aTrackedMemberWithoutTheTokenIsSentToTheGuardAndRecorded() async throws {
        let rig = try TermRig(trackSeconds: 0)
        let channel = LineLog()
        rig.config.channelObserver = { channel.append($0) }
        let gate = rig.folder + "/go"
        let child = try rig.start(["orphan-clean=" + gate])
        #expect(await rig.wait(60) { rig.lines(prefix: "O ").count == 1 })
        let pids = rig.lines(prefix: "O ")[0].split(separator: " ").dropFirst().compactMap { Int32($0) }
        try #require(pids.count == 2, "the stub reported the intermediate and G: \(rig.text)")
        let middle = try #require(ChatProc.identity(of: pids[0])), orphan = try #require(ChatProc.identity(of: pids[1]))
        func recorded() throws -> [ChatState.Identity] { try rig.state.read().members[child.token] ?? [] }

        // With the intermediate alive, one growth makes it and G members: one line each on the channel, both in the list.
        child.growOnce()
        #expect(channel.memberLines(of: middle.pid).count == 1 && channel.memberLines(of: orphan.pid).count == 1, "\(channel.all)")
        let first = try recorded()
        #expect(first.contains(ChatState.Identity(middle)) && first.contains(ChatState.Identity(orphan)), "recorded: \(first)")
        #expect(!first.contains { $0.pid == child.pid }, "claude is not its own member")

        // A growth with nothing new sends no line and writes nothing.
        var lines = channel.all.count, writes = rig.state.writes
        child.growOnce()
        #expect(channel.all.count == lines && rig.state.writes == writes, "a growth that added nothing costs nothing")

        // The intermediate exits, G is orphaned: the next growth adds nothing, so nothing is written, and the list still holds the intermediate.
        FileManager.default.createFile(atPath: gate, contents: Data())
        #expect(await rig.wait(30) { ChatProc.table().first { $0.identity.pid == orphan.pid }?.parent == 1 })
        #expect(processIsGone(middle))
        child.growOnce()
        #expect(channel.all.count == lines && rig.state.writes == writes, "no write for a growth that added no member")
        #expect(try recorded().contains(ChatState.Identity(middle)), "the dead entry stays until the next write")

        // The stub starts H, its own child that carries the token: the next growth sends H's line and writes the list once, without the intermediate.
        _ = child.send(Data([0x01]) + Data("carry\n".utf8))
        #expect(await rig.wait(30) { ChatProc.table().contains { $0.parent == child.pid } })
        let hold = try #require(ChatProc.table().first { $0.parent == child.pid }?.identity)
        lines = channel.all.count; writes = rig.state.writes
        child.growOnce()
        #expect(channel.memberLines(of: hold.pid).count == 1 && channel.all.count == lines + 1, "one new line, for H: \(channel.all)")
        #expect(rig.state.writes == writes + 1, "one write")
        let second = try recorded()
        #expect(second.count == 2 && second.contains(ChatState.Identity(orphan)) && second.contains(ChatState.Identity(hold)) && !second.contains(ChatState.Identity(middle)),
                "G and H, without the intermediate: \(second)")

        // A hard stop leaves G and H gone at 3 s, and the token's entry leaves with the token.
        child.stop(graceful: false, reason: "exam")
        #expect(await rig.wait { child.hasEnded })
        #expect(rig.stops.last?.left == 0)
        #expect(processIsGone(orphan) && processIsGone(hold), "G and H are gone")
        let token = child.token
        #expect(await rig.wait(30) { ((try? rig.state.read())?.tokens.isEmpty ?? false) })
        #expect(try rig.state.read().members[token] == nil, "the entry left with its token")
        await rig.finish()
    }
}
