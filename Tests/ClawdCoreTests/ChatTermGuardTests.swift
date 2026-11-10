import Testing
import Foundation
import Darwin
import AppKit
import ClawdProcess
@testable import ClawdCore

/// The agent stood in by a process the test controls. The test itself spawns the built `clawd-pet-agent --term-guard` (so it can reap it and read
/// its exit status), holds the channel's write end, and starts the stub's `tree` mode as claude with the token and two escapees. With `orphan`
/// the stub is `tty orphan-clean=FILE deaf` instead (R9.12): its intermediate (a session of its own, an empty environment) starts G, which carries no
/// token, and G is orphaned (ppid 1) once the test creates `goFile`.
@MainActor
final class GuardRig {
    let token = UUID().uuidString.lowercased()
    let folder: String
    private(set) var agent: Process
    private(set) var agentIdentity: ProcessIdentity
    private(set) var child: Process
    private(set) var childIdentity: ProcessIdentity
    private(set) var escapees: [ProcessIdentity] = []
    private(set) var guardPid: Int32 = -1
    private(set) var guardIdentity: ProcessIdentity?
    private(set) var middle: ProcessIdentity?
    private(set) var orphanG: ProcessIdentity?
    private var channelWrite: Int32 = -1
    private var channelRead: Int32 = -1
    var goFile: String { folder + "/go" }
    private let exit = GuardExit()

    final class GuardExit: @unchecked Sendable {
        private let lock = NSLock()
        private var statusValue: Int32?
        private var atValue: UInt64?
        func set(_ status: Int32?) { lock.lock(); statusValue = status ?? -1; atValue = DispatchTime.now().uptimeNanoseconds; lock.unlock() }
        var status: Int32? { lock.lock(); defer { lock.unlock() }; return statusValue }
        var at: UInt64? { lock.lock(); defer { lock.unlock() }; return atValue }
    }

    var environment: [String: String] { ChatTermLaunch.environment(ChatSettings(home: folder), token: token) }

    init(orphan: Bool = false, spawnGuard: Bool = true) async throws {
        folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                              create: true).path
        let stub = TermRig.stub
        agent = Process(); agent.executableURL = URL(fileURLWithPath: stub); agent.arguments = ["sleep", "300"]
        agent.standardInput = FileHandle.nullDevice; agent.standardOutput = FileHandle.nullDevice; agent.standardError = FileHandle.nullDevice
        try agent.run()
        agentIdentity = try #require(ChatProc.identity(of: agent.processIdentifier))
        let pidFile = folder + "/escapees.txt"
        child = Process(); child.executableURL = URL(fileURLWithPath: stub)
        child.arguments = orphan ? ["tty", "orphan-clean=" + folder + "/go", "deaf"] : ["tree", pidFile]
        child.environment = ChatTermLaunch.environment(ChatSettings(home: folder), token: token)
        child.standardInput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        let outPath = folder + "/stub.out"
        if orphan {
            FileManager.default.createFile(atPath: outPath, contents: Data())
            child.standardOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
        } else {
            child.standardOutput = FileHandle.nullDevice
        }
        try child.run()
        childIdentity = try #require(ChatProc.identity(of: child.processIdentifier))
        let end = Date().addingTimeInterval(60)
        if orphan {
            // The stub ends its lines with CR LF, which Swift reads as one character: split on the pair.
            func reported() -> String? {
                ((try? String(contentsOfFile: outPath, encoding: .utf8)) ?? "").components(separatedBy: "\r\n").first { $0.hasPrefix("O ") && $0.split(separator: " ").count == 3 }
            }
            while Date() < end, reported() == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
            let pids = (reported() ?? "").split(separator: " ").dropFirst().compactMap { Int32($0) }
            try #require(pids.count == 2, "the stub started the intermediate and G")
            middle = ChatProc.identity(of: pids[0]); orphanG = ChatProc.identity(of: pids[1])
            try #require(orphanG != nil)
        } else {
            while Date() < end, fileLines(pidFile).isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
            let pids = (fileLines(pidFile).first ?? "").split(separator: " ").compactMap { Int32($0) }
            escapees = pids.compactMap { ChatProc.identity(of: $0) }
            try #require(escapees.count == 2, "the stub started both escapees: \(fileLines(pidFile))")
        }

        let ends = try TermProc.makePipe()
        TermProc.setNonBlocking(ends.write)
        channelRead = ends.read
        channelWrite = ends.write
        if spawnGuard {
            startGuard()
            sendChildLine()
        }
    }

    /// Spawns the built guard for the stand-in agent, handing it the channel's read end (which this process then closes).
    func startGuard() {
        guardPid = (try? TermProc.spawnGuard(agent: agentExecutable().path,
                                            arguments: ["--agent-pid", String(agentIdentity.pid), "--agent-start", "\(agentIdentity.seconds).\(agentIdentity.microseconds)", "--token", token],
                                            environment: ChatTermLaunch.guardEnvironment(environment), channelRead: channelRead)) ?? -1
        close(channelRead)
        channelRead = -1
        guardIdentity = ChatProc.identity(of: guardPid)
        let pid = guardPid, record = exit
        Thread { record.set(TermProc.reapGuard(pid)) }.start()
    }

    func sendChildLine() {
        send("{\"child\":{\"pid\":\(childIdentity.pid),\"pgid\":\(childIdentity.pid),\"startSec\":\(childIdentity.seconds),\"startUsec\":\(childIdentity.microseconds)}}")
    }
    /// A member line naming `identity`, its start microseconds moved by `skew`.
    func sendMember(_ identity: ProcessIdentity, skew: UInt64 = 0) {
        send("{\"member\":{\"pid\":\(identity.pid),\"startSec\":\(identity.seconds),\"startUsec\":\(identity.microseconds + skew)}}")
    }

    /// The test creates `goFile`: the intermediate exits and G is orphaned (ppid 1).
    func orphanTheMember() async -> Bool {
        FileManager.default.createFile(atPath: goFile, contents: Data())
        guard let orphanG else { return false }
        return await wait(30) { ChatProc.table().first { $0.identity.pid == orphanG.pid }?.parent == 1 }
    }

    func send(_ text: String) { _ = TermProc.sendLine(channelWrite, text) }
    func closeChannel() { if channelWrite >= 0 { close(channelWrite); channelWrite = -1 } }
    func killAgent() { ChatProc.signal(agentIdentity, SIGKILL) }
    func terminateAgent() { agent.terminate() }
    /// SIGKILL, and the stand-in is reaped before this returns, so it is gone for good (a pid the guard cannot mistake for it).
    func killAgentAndReap() { killAgent(); agent.waitUntilExit() }

    var guardStatus: Int32? { exit.status }
    var guardExitedAt: UInt64? { exit.at }
    var carriers: Int { ChatProc.carriers(of: token, in: ChatProc.table()).count }
    var everythingGone: Bool { processIsGone(childIdentity) && escapees.allSatisfy { processIsGone($0) } && carriers == 0 }
    var orphanGone: Bool { processIsGone(orphanG) }

    func wait(_ seconds: Double = 60, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// Kills whatever a test left (identity-checked; these are all processes this test started).
    func cleanup() {
        closeChannel()
        if channelRead >= 0 { close(channelRead); channelRead = -1 }
        for identity in [agentIdentity, childIdentity] + escapees + [middle, orphanG, guardIdentity].compactMap({ $0 }) { ChatProc.signal(identity, SIGKILL) }
    }
}

@Suite("ChatTermGuard", .serialized)
@MainActor
struct ChatTermGuardTests {
    @Test func ChatTermGuard_theAgentsDeathStopsTheChildAndItsEscapeesWithin3s() async throws {
        let rig = try await GuardRig()
        defer { rig.cleanup() }
        #expect(rig.carriers >= 3, "the stub and both escapees carry the token")
        let killed = DispatchTime.now().uptimeNanoseconds
        rig.killAgent()
        #expect(await rig.wait(30) { rig.guardStatus != nil })
        #expect(rig.guardStatus == 0, "the guard exits 0 after a stop with nothing left")
        let took = (rig.guardExitedAt ?? 0) &- killed
        #expect(Double(took) / 1e9 < 3.5, "the guard is done within about 3 s of the death: \(Double(took) / 1e9)")
        #expect(rig.everythingGone, "no token process is left: \(rig.carriers)")
    }

    @Test func ChatTermGuard_endOfFileAloneAndTheAgentsExitAloneEachCountAsTheDeath() async throws {
        let eof = try await GuardRig()
        defer { eof.cleanup() }
        eof.closeChannel()                                    // the write end closed while the agent lives: fail closed
        #expect(await eof.wait(15) { eof.guardStatus != nil })
        #expect(eof.guardStatus == 0 && eof.everythingGone, "end-of-file alone is the death: \(eof.carriers) left")
        #expect(!processIsGone(eof.agentIdentity), "the stand-in agent was alive throughout")

        // The agent's exit alone: a second holder keeps the write end open, so only the exit event can tell.
        let exit = try await GuardRig()
        defer { exit.cleanup() }
        exit.terminateAgent()
        #expect(await exit.wait(30) { exit.guardStatus != nil })
        #expect(exit.guardStatus == 0 && exit.everythingGone, "the agent's exit alone is the death: \(exit.carriers) left")
    }

    @Test func ChatTermGuard_isNotATokenCarrierNotAnApplicationAndHoldsOnlyItsChannel() async throws {
        let rig = try await GuardRig()
        defer { rig.cleanup() }
        let pid = rig.guardPid
        // The guard registers its kqueue, which is descriptor 3: the check is on what crossed the spawn (0-2), plus what the guard itself needs
        // to wait without a timer. Anything else is a fault.
        #expect(await rig.wait(30) { descriptors(of: pid).contains { $0.type == 5 } }, "the guard is blocked on its kqueue")
        let held = descriptors(of: pid)
        let inherited = held.filter { $0.type != 5 }.map(\.number).sorted()
        #expect(inherited == [0, 1, 2], "descriptors inherited across the spawn: \(held)")
        #expect(held.filter { $0.type == 5 }.count == 1, "one kqueue and nothing else")
        #expect(held.first { $0.number == 0 }?.type == 6, "descriptor 0 is the channel (a pipe)")
        let names = ChatProc.environmentEntries(of: pid).map { String(decoding: $0, as: UTF8.self) }
        #expect(!names.contains { $0.hasPrefix("CLAWD_CHAT_SPAWN") }, "no sweep counts the guard as a token carrier")
        #expect(NSRunningApplication(processIdentifier: pid) == nil, "the guard is not an application")
        #expect(getsid(pid) == pid && getpgid(pid) == pid, "a session of its own")
    }

    @Test func ChatTermGuard_aReleaseEndsItWithoutASignal() async throws {
        let rig = try await GuardRig()
        defer { rig.cleanup() }
        rig.send("{\"release\":true}")
        #expect(await rig.wait(30) { rig.guardStatus != nil })
        #expect(rig.guardStatus == 0)
        #expect(!processIsGone(rig.childIdentity) && rig.escapees.allSatisfy { !processIsGone($0) }, "the child and its escapees were sent nothing")
        #expect(rig.carriers >= 3)
    }

    @Test func ChatTermGuard_aStopsDeadlineCarriesOverWhenTheAgentDiesMidStop() async throws {
        let rig = try await GuardRig()
        defer { rig.cleanup() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        rig.send("{\"stop\":{\"deadlineNs\":\(deadline)}}")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        rig.killAgent()
        while DispatchTime.now().uptimeNanoseconds < deadline + 100_000_000 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(rig.everythingGone, "nothing of the token is left at D (the stop's deadline), not at the death + 3 s: \(rig.carriers) left")
        #expect(await rig.wait(30) { rig.guardStatus != nil })
        #expect(rig.guardStatus == 0)
    }

    @Test func ChatTermGuard_aLostGuardHardStopsTheChild() async throws {
        let rig = try TermRig()
        let child = try rig.start(["escapees"])
        #expect(await rig.wait { rig.lines(prefix: "E ").count == 1 })
        let pids = rig.lines(prefix: "E ")[0].split(separator: " ").dropFirst().compactMap { Int32($0) }
        let escapees = pids.compactMap { ChatProc.identity(of: $0) }
        let guardIdentity = try #require(ChatProc.identity(of: child.guardPid))
        ChatProc.signal(guardIdentity, SIGKILL)
        #expect(await rig.wait(15) { rig.guardLost == 1 && child.hasEnded })
        #expect(rig.logs.contains("CHAT guard-lost pid=\(child.guardPid)"))
        #expect(rig.logs.contains("CHAT stop reason=guard-lost"))
        #expect(rig.stops.last?.left == 0)
        #expect(rig.carriers(child.token) == 0 && escapees.allSatisfy { processIsGone($0) }, "no token process is left")
        await rig.finish()
    }

    /// A bystander of the test's own: `clawd-chat-stub sleep 300`, no token, outside every tree under test.
    private func bystander() throws -> (process: Process, identity: ProcessIdentity) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: TermRig.stub); process.arguments = ["sleep", "300"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, try #require(ChatProc.identity(of: process.processIdentifier)))
    }

    private func isStopped(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { return false }
        return info.pbi_status == UInt32(SSTOP)
    }

    @Test func ChatTermGuard_aMemberWithoutTheTokenIsStoppedAfterTheAgentsDeath() async throws {
        let rig = try await GuardRig(orphan: true)
        defer { rig.cleanup() }
        let orphan = try #require(rig.orphanG)
        #expect(await rig.orphanTheMember(), "G is orphaned: its parent is 1")
        #expect(!ChatProc.carriers(of: rig.token, in: ChatProc.table()).contains(orphan), "G carries no token, and no parent chain reaches it")
        rig.sendMember(orphan)
        let killed = DispatchTime.now().uptimeNanoseconds
        rig.killAgent()
        #expect(await rig.wait(30) { rig.guardStatus != nil })
        #expect(rig.guardStatus == 0, "the guard exits 0 after a stop with nothing left")
        #expect((Double((rig.guardExitedAt ?? 0) &- killed)) / 1e9 < 3.5, "within about 3 s of the death")
        #expect(rig.orphanGone, "G, which only its member line names, is gone")
        #expect(processIsGone(rig.childIdentity), "and so is the child")
    }

    @Test func ChatTermGuard_aMemberWhoseStartTimeNoLongerMatchesIsNeverSignalled() async throws {
        let rig = try await GuardRig()
        defer { rig.cleanup() }
        let other = try bystander()
        defer { ChatProc.signal(other.identity, SIGKILL) }
        rig.sendMember(other.identity, skew: 1)          // the pid of the bystander with another start time: a reused pid
        rig.killAgent()
        #expect(await rig.wait(30) { rig.guardStatus != nil })
        try await Task.sleep(nanoseconds: 3_500_000_000)
        #expect(!processIsGone(other.identity), "a member whose pid now names another process is never signalled")
        #expect(rig.everythingGone)
    }

    @Test func ChatTermGuard_theMemberListIsPrunedWhenItDoubles() {
        func identity(_ n: Int) -> ProcessIdentity {
            ProcessIdentity(ClawdIdentity(pid: Int32(1_000 + n), uid: getuid(), seconds: 1, microseconds: UInt64(n)))
        }
        var arrived = 0
        // The fake table: of everything that arrived, only the latest 10 are still alive.
        var members = TermGuardMembers(identityOf: { pid in
            let n = Int(pid) - 1_000
            return n > arrived - 10 && n <= arrived ? identity(n) : nil
        })
        for n in 1...600 {
            arrived = n
            members.add(pid: Int32(1_000 + n), startSeconds: 1, startMicroseconds: UInt64(n))
            let bound = max(256, 2 * members.keptAtLastPrune)
            #expect(members.identities.count <= bound, "after \(n) arrivals the list holds \(members.identities.count), over max(256, twice \(members.keptAtLastPrune))")
        }
        #expect(members.identities.count < 600)
        #expect(members.identities.suffix(10).map { Int($0.pid) - 1_000 } == Array(591...600), "the latest arrivals are kept")
    }

    @Test func ChatTermGuard_aFullChannelNeverHoldsTheAgent() async throws {
        let ends = try TermProc.makePipe()
        TermProc.setNonBlocking(ends.write)
        // Nobody reads the read end. A red run (an unbounded write) is unblocked by closing it after 1 s, which fails the write at once.
        let readEnd = ends.read
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { close(readEnd) }
        var logs: [String] = []
        let channel = ChatTermChannel(descriptor: ends.write, log: { logs.append($0) })
        var block = [UInt8](repeating: 0x20, count: 4_096)
        while write(ends.write, &block, block.count) > 0 {}
        var one: UInt8 = 0x20
        while write(ends.write, &one, 1) > 0 {}
        let identity = try #require(ChatProc.identity(of: getpid()))

        var began = ProcessInfo.processInfo.systemUptime
        let memberWritten = channel.member(identity)
        let memberTook = ProcessInfo.processInfo.systemUptime - began
        began = ProcessInfo.processInfo.systemUptime
        let stopWritten = channel.stop(deadlineNs: 1)            // this test runs on the main queue, where the exam close runs
        let stopTook = ProcessInfo.processInfo.systemUptime - began
        #expect(!memberWritten && memberTook < 0.15, "a member line returns false within 150 ms: \(memberTook) s")
        #expect(!stopWritten && stopTook < 0.15, "and so does a stop line on the main queue: \(stopTook) s")
        let end = Date().addingTimeInterval(5)
        while Date() < end, logs.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!logs.isEmpty, "the first drop is logged")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(logs == ["CHAT notice kind=guard-channel-full"] && channel.dropped == 2, "once per child: \(logs), dropped \(channel.dropped)")
        channel.close()
    }

    @Test func ChatTermGuard_memberLinesStillInTheChannelAtTheDeathAreRead() async throws {
        let pad = try bystander()
        let padIdentity = pad.identity
        pad.process.terminate()
        pad.process.waitUntilExit()                              // reaped: its identity pads the channel and matches nothing

        // (a) the guard is stopped while the lines are written and the agent dies; the guard cannot see the death before its SIGCONT.
        let a = try await GuardRig(orphan: true)
        defer { a.cleanup() }
        let orphan = try #require(a.orphanG)
        #expect(await a.orphanTheMember())
        let guardIdentity = try #require(a.guardIdentity)
        ChatProc.signal(guardIdentity, SIGSTOP)
        #expect(await a.wait(30) { isStopped(guardIdentity.pid) }, "the guard is stopped")
        for _ in 0..<70 { a.sendMember(padIdentity) }            // about 4.6 KB: more than one read of 4,096 bytes
        a.sendMember(orphan)
        a.killAgentAndReap()
        let continued = DispatchTime.now().uptimeNanoseconds
        ChatProc.signal(guardIdentity, SIGCONT)
        #expect(await a.wait(30) { a.orphanGone }, "G is gone after the SIGCONT")
        #expect(Double(DispatchTime.now().uptimeNanoseconds - continued) / 1e9 < 3.5, "within 3 s of it")
        #expect(await a.wait(30) { a.guardStatus != nil } && a.guardStatus == 0)

        // (b) the agent is gone before the guard starts: the lines were written first and the guard is spawned for a dead agent.
        let b = try await GuardRig(orphan: true, spawnGuard: false)
        defer { b.cleanup() }
        let second = try #require(b.orphanG)
        #expect(await b.orphanTheMember())
        b.killAgentAndReap()
        b.sendChildLine()
        b.sendMember(second)
        let started = DispatchTime.now().uptimeNanoseconds
        b.startGuard()
        #expect(await b.wait(30) { b.orphanGone }, "G is gone after the guard's start")
        #expect(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 < 3.5, "within 3 s of it")
        #expect(await b.wait(30) { b.guardStatus != nil } && b.guardStatus == 0)
    }

    @Test func ChatTermGuard_noGuardNoSpawn() async throws {
        let rig = try TermRig(agent: "/private/tmp/clawd-no-such-agent-" + UUID().uuidString)
        var kinds: [ChatTermSpawnKind] = []
        rig.config.spawnObserver = { kinds.append($0) }
        rig.wire()
        let token = UUID().uuidString.lowercased()
        var refusal: ChatTermRefusal?
        do { _ = try ChatTermChild.start(rig.launch(["tty"], token: token), config: rig.config) } catch { refusal = error as? ChatTermRefusal }
        #expect(refusal == .guardFailed && refusal?.reason == "guard-failed")
        #expect(kinds == [.terminalGuard], "claude was never spawned: \(kinds)")
        let state = try rig.state.read()
        #expect(!state.tokens.contains(token) && state.child == nil, "the token is dropped")
        #expect(rig.carriers(token) == 0)
    }
}
