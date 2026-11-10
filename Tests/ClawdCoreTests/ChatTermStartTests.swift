import Testing
import Foundation
import Darwin
@testable import ClawdCore

/// T-9's start sweep and the order of the spawn.
@Suite("ChatTermStart", .serialized)
@MainActor
struct ChatTermStartTests {
    @Test func ChatTermStart_aRecordedTokenIsSweptBeforeAnythingSpawns() async throws {
        let rig = try await GuardRig()
        defer { rig.cleanup() }
        // The recorded guard is a live process that never ends by itself: the sweep must stop it at its check.
        let stand = Process()
        stand.executableURL = URL(fileURLWithPath: TermRig.stub); stand.arguments = ["sleep", "300"]
        stand.standardInput = FileHandle.nullDevice; stand.standardOutput = FileHandle.nullDevice; stand.standardError = FileHandle.nullDevice
        try stand.run()
        let recordedGuard = try #require(ChatProc.identity(of: stand.processIdentifier))
        defer { ChatProc.signal(recordedGuard, SIGKILL) }
        let store = try artifactStore()
        let state = ChatTermState(store: store)
        try state.begin(token: rig.token)
        try state.recordGuard(recordedGuard, token: rig.token)
        try state.recordChild(pid: rig.childIdentity.pid, pgid: rig.childIdentity.pid, identity: rig.childIdentity, token: rig.token)
        // The real guard of the rig is told nothing and is left alive: the sweep acts on the recorded identities.
        var lines: [String] = []
        let began = DispatchTime.now().uptimeNanoseconds
        let result = TermStartSweep.run(store: store, seconds: 3) { lines.append($0) }
        let took = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        #expect(result.left == 0 && result.swept >= 1, "swept \(result)")
        #expect(took < 4.5, "no token process 3 s after the sweep began: \(took) s")
        #expect(lines.count == 1 && lines[0].hasPrefix("CHAT sweep n=") && lines[0].hasSuffix("left=0 via=start"), "the log line: \(lines)")
        #expect(rig.everythingGone, "the child and its escapees are gone")
        #expect(processIsGone(recordedGuard), "the recorded guard that was still alive is stopped")
        let after = try state.read()
        #expect(after.tokens.isEmpty, "the token is dropped")

        // A file with no live process ends at once; no file and no tokens do nothing at all.
        let quiet = try artifactStore()
        try ChatTermState(store: quiet).begin(token: UUID().uuidString.lowercased())
        var quietLines: [String] = []
        let quietBegan = DispatchTime.now().uptimeNanoseconds
        let quietResult = TermStartSweep.run(store: quiet, seconds: 3) { quietLines.append($0) }
        #expect(Double(DispatchTime.now().uptimeNanoseconds - quietBegan) / 1e9 < 2, "nothing alive ends the sweep at once")
        #expect(quietResult == TermStartSweep.Result(swept: 0, left: 0) && quietLines.count == 1)
        var none: [String] = []
        #expect(TermStartSweep.run(store: try artifactStore(), seconds: 3) { none.append($0) } == TermStartSweep.Result(swept: 0, left: 0) && none.isEmpty)

        // A malformed file is left in place and logged.
        let broken = try artifactStore()
        try broken.write(Data("{not json".utf8), to: ChatTermState.legacyFileName)
        var brokenLines: [String] = []
        TermStartSweep.run(store: broken, seconds: 3) { brokenLines.append($0) }
        #expect(brokenLines == ["CHAT notice kind=state-unreadable"])
        #expect(String(decoding: try ReadOnlyFile.data(try broken.url(ChatTermState.legacyFileName).path), as: UTF8.self) == "{not json")
    }

    @Test func ChatTermStart_aRecordedMemberWithoutTheTokenIsSwept() async throws {
        let rig = try await GuardRig(orphan: true, spawnGuard: false)
        defer { rig.cleanup() }
        let orphan = try #require(rig.orphanG)
        #expect(await rig.orphanTheMember(), "G is orphaned and carries no token")
        // A bystander of the test's own (no token, outside the stub's tree), which a start sweep that takes a member by its pid alone would kill.
        let other = Process(); other.executableURL = URL(fileURLWithPath: TermRig.stub); other.arguments = ["sleep", "300"]
        other.standardInput = FileHandle.nullDevice; other.standardOutput = FileHandle.nullDevice; other.standardError = FileHandle.nullDevice
        try other.run()
        let bystander = try #require(ChatProc.identity(of: other.processIdentifier))
        defer { ChatProc.signal(bystander, SIGKILL) }

        // The token has no live carrier and no recorded child; only `members[<token>]` reaches G.
        let store = try artifactStore()
        let state = ChatTermState(store: store)
        let token = UUID().uuidString.lowercased()
        try state.begin(token: token)
        try state.setMembers([ChatState.Identity(orphan),
                              ChatState.Identity(pid: bystander.pid, startSec: bystander.seconds, startUsec: bystander.microseconds + 1)], token: token)
        var lines: [String] = []
        let result = TermStartSweep.run(store: store, seconds: 3) { lines.append($0) }
        #expect(result.left == 0 && result.swept == 1, "swept \(result)")
        #expect(lines == ["CHAT sweep n=1 left=0 via=start"], "the log line: \(lines)")
        #expect(rig.orphanGone, "G, named only by its recorded identity, is killed")
        #expect(!processIsGone(bystander), "a recorded pid whose start time no longer matches is never signalled")
        let after = try state.read()
        #expect(after.tokens.isEmpty && after.members.isEmpty, "the token leaves with its entry")

        // A file in the previous build's shape (no `members` key) is swept as in Start 1 and is not unreadable.
        let old = try await GuardRig()
        defer { old.cleanup() }
        let oldStore = try artifactStore()
        let json = "{\"sessionId\":null,\"sessionFolder\":null,\"recentFolders\":[],\"child\":null,\"tokens\":[\"\(old.token)\"],\"lastStop\":null}"
        try oldStore.write(Data(json.utf8), to: ChatTermState.legacyFileName)
        var oldLines: [String] = []
        let swept = TermStartSweep.run(store: oldStore, seconds: 3) { oldLines.append($0) }
        #expect(!oldLines.contains { $0.contains("state-unreadable") }, "a file without `members` reads as no members: \(oldLines)")
        #expect(swept.swept >= 1 && swept.left == 0 && old.everythingGone, "its carrier is swept: \(swept)")
    }

    @Test func ChatTermStart_theTokenIsOnDiskBeforeTheGuardAndTheChildSpawn() async throws {
        let rig = try TermRig()
        var atGuard: ChatState?, atChild: ChatState?
        let state = rig.state
        rig.config.spawnObserver = { kind in
            let read = try? state.read()
            if kind == .terminalGuard { atGuard = read } else { atChild = read }
        }
        let child = try rig.start([])
        #expect(atGuard?.tokens == [child.token], "the token is on disk when the guard is spawned")
        #expect(atChild?.tokens == [child.token], "and when claude is spawned")
        #expect(atGuard?.child?.guardProcess == nil, "the guard is not recorded yet at its own spawn")
        #expect(atChild?.child?.guardProcess != nil, "the guard's record is on disk when claude is spawned")
        #expect(atChild?.child?.token == child.token)
        #expect(await rig.wait { rig.report() != nil })
        let running = try state.read()
        #expect(running.child?.pid == child.pid && running.child?.guardProcess?.pid == child.guardPid, "claude's identity is recorded after its spawn")
        await rig.finish()
        #expect(await rig.wait(30) { ((try? state.read())?.tokens.isEmpty ?? false) && (try? state.read())?.child == nil }, "the token and the record go when the stop ends")
    }

    @Test func ChatTermStart_runsAfterTheLockAndBeforeTheApplicationObject() throws {
        let main = String(decoding: try ReadOnlyFile.data(repository.appendingPathComponent("Sources/ClawdAgent/main.swift").path), as: UTF8.self)
        var cursor = main.startIndex
        for token in ["state.lock()", "TermStartSweep.run", "AgentBoot.start"] {
            let range = try #require(main.range(of: token, range: cursor..<main.endIndex), "missing or out of order: \(token)")
            cursor = range.upperBound
        }
    }
}
