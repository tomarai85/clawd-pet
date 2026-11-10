import Testing
import Foundation
import Darwin
import ClawdProcess
import ClawdCore

// The kernel side of the Aqua follow: process facts, zombies, the kqueue exit registration and the bundle identity, run against real
// processes this test starts itself (a copy of /bin/sleep). No other application or process is ever touched.

/// A child started with posix_spawn and not reaped by anything but the test: its zombie stays visible until `reap`.
final class SpawnedChild {
    let pid: Int32
    private var reaped = false
    init(executable: String, arguments: [String] = ["30"]) throws {
        var child: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let status = posix_spawn(&child, executable, nil, nil, argv, environ)
        guard status == 0 else { throw FileFailure.system(status) }
        pid = child
    }
    func kill() { Darwin.kill(pid, SIGKILL) }
    func reap() {
        guard !reaped else { return }
        var status: Int32 = 0
        waitpid(pid, &status, 0); reaped = true
    }
    deinit { if !reaped { Darwin.kill(pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0) } }
}

/// A scratch application bundle `<root>/<bundle>.app` whose executable is a copy of /bin/sleep and whose Info.plist names `identifier`.
func makeFakeBundle(under root: URL, bundle: String, identifier: String, executable: String) throws -> URL {
    let app = root.appendingPathComponent(bundle + ".app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": executable]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let target = macOS.appendingPathComponent(executable)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: target)
    // A copy of a platform binary is killed at exec; signed ad hoc it runs.
    let signer = Process()
    signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    signer.arguments = ["-s", "-", "-f", target.path]
    signer.standardError = FileHandle.nullDevice; signer.standardOutput = FileHandle.nullDevice
    try signer.run(); signer.waitUntilExit()
    guard signer.terminationStatus == 0 else { throw FileFailure.system(Int32(signer.terminationStatus)) }
    return target
}

func waitUntil(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if condition() { return true }; usleep(10_000) }
    return condition()
}

@Suite("AquaFollow kernel")
struct AquaKernelSuite {
    private func scratch() throws -> URL { try artifactStore().root }

    @Test func AquaFollow_theRealZombieFallbackReportsTheStartTime() throws {
        let child = try SpawnedChild(executable: "/bin/sleep")
        var start: UInt64 = 0, zombie: Int32 = -1
        #expect(clawd_proc_facts(child.pid, &start, &zombie) == 0)
        #expect(start > 0); #expect(zombie == 0)
        var again: UInt64 = 0
        #expect(clawd_proc_facts(child.pid, &again, &zombie) == 0); #expect(again == start, "the start time is the generation's, stable")
        var runningVia: Int32 = 0
        #expect(clawd_proc_facts_via(child.pid, &again, &zombie, &runningVia) == 0); #expect(runningVia == 1, "a running process is described by libproc")
        child.kill()
        var zombieVia: Int32 = 0, zombieStart: UInt64 = 0
        #expect(waitUntil { var z: Int32 = 0; return clawd_proc_facts_via(child.pid, &zombieStart, &z, &zombieVia) == 0 && z != 0 }, "an exited, unreaped child is a zombie")
        #expect(zombieStart == start, "the zombie's start time is the one seen while it ran, whichever path reported it")
        // Which path reported it depends on the system (libproc = 1, the sysctl fallback = 2; on the Mac this was written on, libproc returns
        // nothing for a zombie, so 2). Either is correct as long as the zombie and its start time are reported, which the lines above assert.
        #expect(zombieVia == 1 || zombieVia == 2, "a known path reported the zombie: \(zombieVia)")
        child.reap()
        var s: UInt64 = 0, z: Int32 = 0
        #expect(clawd_proc_facts(child.pid, &s, &z) == -1, "a reaped pid is gone")
    }

    @Test func AquaFollow_kernelExitRegistrationIsSynchronousAndDeliversTheExit() throws {
        let kq = clawd_kq_create(); #expect(kq >= 0)
        defer { close(kq) }
        let child = try SpawnedChild(executable: "/bin/sleep")
        #expect(clawd_kq_watch_exit(kq, child.pid) == 0, "registration complete when the call returns")
        var pids = [Int32](repeating: 0, count: 4)
        #expect(clawd_kq_drain(kq, &pids, 4) == 0, "nothing is delivered while the process runs")
        child.kill()
        var got: [Int32] = []
        #expect(waitUntil { let n = Int(clawd_kq_drain(kq, &pids, 4)); got += pids.prefix(max(0, n)); return !got.isEmpty })
        #expect(got == [child.pid])
        child.reap()
    }

    @Test func AquaFollow_kernelRegistrationOfAGoneProcessIsEsrchAndUnwatchIgnoresIt() throws {
        let kq = clawd_kq_create(); defer { close(kq) }
        let child = try SpawnedChild(executable: "/bin/sleep")
        child.kill(); child.reap()
        #expect(clawd_kq_watch_exit(kq, child.pid) == 1, "ESRCH: the process is already gone")
        #expect(clawd_kq_unwatch(kq, child.pid) == 0, "deleting a registration that is not there is not an error")
    }

    @Test func AquaFollow_kernelUnwatchRemovesTheRegistration() throws {
        let kq = clawd_kq_create(); defer { close(kq) }
        let child = try SpawnedChild(executable: "/bin/sleep")
        #expect(clawd_kq_watch_exit(kq, child.pid) == 0)
        #expect(clawd_kq_unwatch(kq, child.pid) == 0)
        child.kill()
        _ = waitUntil { var s: UInt64 = 0, z: Int32 = 0; return clawd_proc_facts(child.pid, &s, &z) == 0 && z != 0 }
        var pids = [Int32](repeating: 0, count: 4)
        #expect(clawd_kq_drain(kq, &pids, 4) == 0, "a deleted registration delivers nothing")
        child.reap()
    }

    @MainActor @Test func AquaFollow_theRegistryDeliversAnExitOnTheMainQueue() async throws {
        let registry = KqueueExitRegistry()
        #expect(registry.available)
        var delivered: [Int32] = []
        var onMain = true
        registry.onExit = { pid in delivered.append(pid); onMain = onMain && Thread.isMainThread }
        let child = try SpawnedChild(executable: "/bin/sleep")
        #expect(registry.watch(pid: child.pid) == .registered)
        child.kill()
        for _ in 0..<200 where delivered.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(delivered == [child.pid]); #expect(onMain)
        child.reap()
        #expect(registry.watch(pid: child.pid) == .gone)
    }

    @Test func AquaFollow_anotherCopyOfAquaIsRecognisedByItsBundleId() throws {
        let identity = AppBundleIdentity()
        let elsewhere = try scratch().appendingPathComponent("Staged Update")
        let executable = try makeFakeBundle(under: elsewhere, bundle: "Aqua Voice", identifier: KernelAquaTable.bundleIdentifier, executable: "Aqua Voice")
        #expect(identity.matches(executable: executable.path, identifier: KernelAquaTable.bundleIdentifier), "any install location counts")
        // The real kernel table finds a live process running that copy.
        let child = try SpawnedChild(executable: executable.path)
        let table = KernelAquaTable()
        let found = try #require(table.scan())
        #expect(found.contains { $0.generation.pid == child.pid && !$0.zombie }, "a process of another copy is an Aqua process")
        #expect(table.isAqua(pid: child.pid))
        let facts = try #require(table.facts(of: child.pid))
        #expect(found.first { $0.generation.pid == child.pid }?.generation.start == facts.start)
    }

    @Test func AquaFollow_aHelperOrAnotherBundleIsNotAqua() throws {
        let identity = AppBundleIdentity()
        let root = try scratch()
        let other = try makeFakeBundle(under: root, bundle: "Other App", identifier: "com.example.other", executable: "Other App")
        #expect(!identity.matches(executable: other.path, identifier: KernelAquaTable.bundleIdentifier))
        // An executable whose plist names Aqua's id but another executable name is not the main process.
        let wrongName = try makeFakeBundle(under: root, bundle: "Aqua Voice Two", identifier: KernelAquaTable.bundleIdentifier, executable: "Helper")
        let renamed = wrongName.deletingLastPathComponent().appendingPathComponent("Aqua Voice Two")
        #expect(!identity.matches(executable: renamed.path, identifier: KernelAquaTable.bundleIdentifier))
        // A helper bundle nested in Aqua's has its own plist and its own id.
        let main = try makeFakeBundle(under: root, bundle: "Aqua Voice Three", identifier: KernelAquaTable.bundleIdentifier, executable: "Aqua Voice Three")
        let nested = try makeFakeBundle(under: main.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Contents/Frameworks"),
                                        bundle: "Helper", identifier: "com.electron.aqua-voice.helper", executable: "Helper")
        #expect(!identity.matches(executable: nested.path, identifier: KernelAquaTable.bundleIdentifier))
        #expect(!identity.matches(executable: "/usr/bin/true", identifier: KernelAquaTable.bundleIdentifier))
    }

    @Test func AquaFollow_theBundleIdentityIsCachedByPathAndModificationTime() throws {
        var reads = 0
        let identity = AppBundleIdentity(readPlist: { reads += 1; return try? ReadOnlyFile.data($0) })
        let executable = try makeFakeBundle(under: try scratch(), bundle: "Cached", identifier: KernelAquaTable.bundleIdentifier, executable: "Cached")
        for _ in 0..<5 { #expect(identity.matches(executable: executable.path, identifier: KernelAquaTable.bundleIdentifier)) }
        #expect(reads == 1, "five lookups read the plist once")
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        let changed: [String: Any] = ["CFBundleIdentifier": "com.example.changed", "CFBundleExecutable": "Cached"]
        try PropertyListSerialization.data(fromPropertyList: changed, format: .xml, options: 0).write(to: plist)
        var times = [timeval(), timeval()]
        times[0].tv_sec = Int(Date().timeIntervalSince1970) + 100; times[1].tv_sec = times[0].tv_sec
        #expect(utimes(plist.path, &times) == 0)
        #expect(!identity.matches(executable: executable.path, identifier: KernelAquaTable.bundleIdentifier), "a newer plist is read again")
        #expect(reads == 2)
    }
}
