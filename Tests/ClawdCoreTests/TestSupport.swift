import Foundation
import Testing
import ClawdCore
import ClawdRendering
import ClawdDesktop
import CoreGraphics
import Darwin

let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let artDirectory = repository.appendingPathComponent("art")

func fixture(_ name: String) throws -> String {
    String(decoding: try ReadOnlyFile.data(repository.appendingPathComponent("Tests/Fixtures/" + name).path), as: UTF8.self)
}

/// One scratch directory per test process, one subdirectory per call. Nothing is ever deleted by the suite.
private let runDirectory: URL = {
    let stamp = String(Int(Date().timeIntervalSince1970)) + "-" + String(getpid())
    return repository.appendingPathComponent(".build/test-artifacts/" + stamp)
}()
func artifactStore() throws -> OwnState {
    try OwnState(root: runDirectory.appendingPathComponent(UUID().uuidString))
}
func evidenceStore(_ name: String = "") throws -> OwnState {
    try OwnState(root: repository.appendingPathComponent(".evidence/" + name))
}

func event(_ clock: PetClock, _ kind: EventKind, lease: Int? = 1, age: Double = 0) -> PetEvent {
    PetEvent(kind, lease: lease, timestamp: clock.wallNow.addingTimeInterval(-age))
}
private let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
func stamp(_ date: Date) -> String { timestampFormatter.string(from: date) }

/// Real Aqua line formats (`[ts] [level]  (Source)  body`), keys and lease ids only.
func startLine(_ clock: PetClock, lease: Int = 1, age: Double = 0) -> String {
    "[\(stamp(clock.wallNow.addingTimeInterval(-age)))] [info]  (DictationOrchestrator)                  dictation.start_accepted lease_id=\(lease) provider=online\n"
}
func line(_ clock: PetClock, _ source: String, _ body: String, level: String = "info", age: Double = 0) -> String {
    "[\(stamp(clock.wallNow.addingTimeInterval(-age)))] [\(level)] \(source.isEmpty ? "" : "(\(source))") \(body)\n"
}
func completedLine(_ clock: PetClock, lease: Int = 1, length: Int = 12) -> String {
    line(clock, "DictationOrchestrator", "dictation.completed audio_duration_s=3.5 auto_enter=false has_audio_data=true lease_id=\(lease) result_source=\(length > 0 ? "live" : "none") session_id=1 text_length=\(length)")
}
func ackLine(_ clock: PetClock, success: Bool = true) -> String {
    line(clock, "IPCFloating", "PASTE_ACK received { timestamp: 1791993032.572922, success: \(success) }")
}

func agentExecutable() -> URL {
    let debug = repository.appendingPathComponent(".build/debug/clawd-pet-agent")
    return FileManager.default.isExecutableFile(atPath: debug.path) ? debug : repository.appendingPathComponent(".build/release/clawd-pet-agent")
}
func builtTool(_ name: String) -> URL {
    let debug = repository.appendingPathComponent(".build/debug/" + name)
    return FileManager.default.isExecutableFile(atPath: debug.path) ? debug : repository.appendingPathComponent(".build/release/" + name)
}

struct Execution {
    var code: Int32; var output: String; var elapsed: Double; var windowPids: Set<Int32>
    /// CPU seconds (user + system) the child used, from the kernel's accounting of the children this process has waited for. What a process
    /// that does next to nothing costs is the same on a loaded machine, unlike the wall time it needs to run.
    var cpu = 0.0
    /// How many times the window list was read while the process lived, and how many of those reads failed.
    var windowSamples = 0
    var windowEnumerationFailures = 0
    /// "No window" is a claim that needs evidence: the list was read at least once, every read worked, and none showed a window of the process.
    /// A read that fails is its own failure here, never "no window".
    var provedWindowless: Bool { windowSamples > 0 && windowEnumerationFailures == 0 && windowPids.isEmpty }
}

/// CPU seconds (user + system) of every child of this process that has ended and been waited for.
func childrenCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_CHILDREN, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// Windows currently owned by `pid` according to the window server's list. Read-only, shows nothing. -1 means the list could not be read.
func windowCount(ownedBy pid: Int32) -> Int {
    guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return -1 }
    return list.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }.count
}

/// Runs a built executable with a scrubbed environment. A child that outlives `timeout` is terminated: it is our own child.
/// The window list is read once right after the start (so even an instant exit is looked at) and every 10 ms while it runs.
func execute(_ executable: URL, _ arguments: [String], environment overrides: [String: String] = [:],
             removing removed: [String] = ["XPC_SERVICE_NAME"], timeout: Double = 20,
             windowProbe: (Int32) -> Int = { windowCount(ownedBy: $0) }) throws -> Execution {
    let process = Process(); process.executableURL = executable; process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    for key in removed { environment.removeValue(forKey: key) }
    for (key, value) in overrides { environment[key] = value }
    process.environment = environment
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
    let started = ProcessInfo.processInfo.systemUptime, cpuBefore = childrenCPUSeconds()
    try process.run()
    let pid = process.processIdentifier
    var windows: Set<Int32> = []
    var samples = 0, failures = 0
    func look() {
        samples += 1
        let count = windowProbe(pid)
        if count < 0 { failures += 1 } else if count > 0 { windows.insert(pid) }
    }
    look()
    let deadline = started + timeout
    while process.isRunning {
        look()
        if ProcessInfo.processInfo.systemUptime > deadline { process.terminate(); break }
        usleep(10_000)
    }
    let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    return Execution(code: process.terminationStatus, output: String(decoding: output, as: UTF8.self),
                     elapsed: ProcessInfo.processInfo.systemUptime - started, windowPids: windows, cpu: childrenCPUSeconds() - cpuBefore,
                     windowSamples: samples, windowEnumerationFailures: failures)
}

/// A single write(2) per line: cannot be split by buffering or interleaved with the test runner's own output.
func emit(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }

/// A negative control passes only when the scenario's expectation FAILS with its guard switched off.
func negativeControl(_ name: String, expectationHolds: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!expectationHolds, "negative control \(name) did not fail: the guard is not load-bearing", sourceLocation: sourceLocation)
    if !expectationHolds { emit("NEGATIVE-CONTROL: \(name) -> fails") }
}

// MARK: virtual-clock rig

final class FakeScheduler: PetFiringTimer {
    var onFire: (() -> Void)?
    private(set) var fireAt: TimeInterval?
    private(set) var leeway: TimeInterval = 0
    private(set) var armCount = 0
    private let clock: PetClock
    init(clock: PetClock) { self.clock = clock }
    func arm(after delay: TimeInterval, leeway: TimeInterval) { fireAt = clock.now + delay; self.leeway = leeway; armCount += 1 }
    func cancel() { fireAt = nil }
    var isArmed: Bool { fireAt != nil }
}

final class FakeDevice: ReleaseDeviceSource {
    var onChange: ((String?, Bool?) -> Void)?
    var uid: String?
    var state: Bool?
    private(set) var startedUIDs: [String?] = []
    private(set) var stopCount = 0
    func start(uid: String?) -> Bool? { startedUIDs.append(uid); self.uid = uid; return state }
    func running() -> Bool? { state }
    func stop() { stopCount += 1 }
    /// Simulates the CoreAudio callback.
    func fire(running: Bool?, uid override: String? = nil) {
        state = running; onChange?(override ?? uid, running)
    }
}

/// Moves virtual time forward, firing the controller's one armed timer at its own instant like the production run loop would.
func advanceVirtual(clock: VirtualClock, scheduler: FakeScheduler, controller: PetController, by seconds: TimeInterval) {
    let target = clock.now + seconds
    var steps = 0
    while let fire = scheduler.fireAt, fire <= target, steps < 200_000 {
        clock.advance(max(0, fire - clock.now)); scheduler.cancel(); controller.refresh(); steps += 1
    }
    clock.advance(max(0, target - clock.now))
}

/// The same for the whole stage runtime: the one real timer fires `tick()`, which refreshes the controller, the scheduler and the picture.
func advanceVirtual(clock: VirtualClock, scheduler: FakeScheduler, runtime: StageRuntime, by seconds: TimeInterval) {
    let target = clock.now + seconds
    var steps = 0
    while let fire = scheduler.fireAt, fire <= target, steps < 200_000 {
        clock.advance(max(0, fire - clock.now)); scheduler.cancel(); runtime.tick(); steps += 1
    }
    clock.advance(max(0, target - clock.now))
}

/// Drives the real PetController on a virtual clock, honouring exactly the one timer it arms.
final class Rig {
    let clock: VirtualClock
    let scheduler: FakeScheduler
    let controller: PetController
    let device = FakeDevice()
    private(set) var changes: [(scene: Scene, at: TimeInterval)] = []
    private(set) var renders: [PetViewState] = []
    var scenes: [Scene] { [.idle] + changes.map(\.scene) }
    var scene: Scene { controller.machine.scene }
    var started: TimeInterval

    init(aquaRunning: Bool = true, sourceB: Bool = false, renderer: SceneRenderer? = nil, wall: Date? = nil) {
        clock = wall.map { VirtualClock(wallNow: $0) } ?? VirtualClock()
        scheduler = FakeScheduler(clock: clock)
        controller = PetController(clock: clock, scheduler: scheduler)
        started = clock.now
        controller.randomUnit = { 0.5 }
        controller.randomSeed = { 7 }
        controller.machine.onChange = { [unowned self] scene in self.changes.append((scene, self.clock.now)) }
        controller.onRender = { [unowned self] state in self.renders.append(state) }
        if let renderer {
            controller.animationInterval = { state in renderer.animationInterval(for: state, scale: 1, helmet: false) }
        }
        if sourceB {
            controller.sourceBEnabled = true
            controller.device = device
            controller.selectedUID = { "fixture-device" }
            device.state = true
        }
        controller.setAquaRunning(aquaRunning)
    }

    func feed(_ text: String) {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) { controller.receive(line: String(raw)) }
    }
    func start(_ lease: Int = 1) { feed(startLine(clock, lease: lease)) }
    func lock(lease: Int = 1) { feed(line(clock, "DictationOrchestrator", "dictation.lock_accepted lease_id=\(lease) provider=online")) }
    func complete(lease: Int = 1, length: Int = 12) { feed(completedLine(clock, lease: lease, length: length)) }
    func ack(_ success: Bool = true) { feed(ackLine(clock, success: success)) }
    func cancel(lease: Int = 1) { feed(line(clock, "DictationOrchestrator", "dictation.cancel_accepted lease_id=\(lease)")) }
    func fail() { feed(line(clock, "DictationRuntimeAdapter", "dictation.native_audio_capture_failed lease_id=1", level: "warn")) }

    /// Advances virtual time, firing the armed timer at its own instant like the production run loop would.
    func advance(_ seconds: TimeInterval) { advanceVirtual(clock: clock, scheduler: scheduler, controller: controller, by: seconds) }
    func at(_ scene: Scene) -> TimeInterval? { changes.first { $0.scene == scene }?.at }
    func seconds(_ time: TimeInterval) -> TimeInterval { (time - started) }
}
