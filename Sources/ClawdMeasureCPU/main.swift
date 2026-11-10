import Foundation
import CryptoKit
import ClawdCore
import Darwin

// Usage: clawd-measure-cpu PID STATE_DIRECTORY [--seconds N] [--json PATH] [--budget B1|B2|B3|B4|B5]
// Measures one running agent with proc_pid_rusage(RUSAGE_INFO_V4) at t0 and t0+N s of wall time (default 600, the done-bar window).
// It fails, never reports zero, when the pid vanishes, its start time changes, a read fails, or the state log shows any
// dictation scene or event inside the window. For the render mode (status.json mode "test-idle-render-no-window") it also
// reads the agent's render counter (renders.count) at both ends and its armed-timer gauge (timers.armed, timers.max) every second.
//
// Budgets (spec 7, done-bar 3). Without --budget the v1 budget applies: CPU under 0.3 s and idle wakeups under 600 in the window.
//   B1  motion off, v1's budget unchanged, renders happened                         (window >= 600 s)
//   B2  idle life at the default (quiet, walk on), a fixed seed: CPU <= 1.8 s, wakeups < 3600, >= 10 idle motions, >= 1 walk,
//       >= 1 look change in the window                                              (window >= 3600 s)
//   B3  600 s in a quiet condition: 0 renders, at most 1 armed timer at every sample, CPU < 0.05 s   (window >= 600 s)
//   B4  lively with walk on: CPU <= 1.5 s, >= 5 idle motions                        (window >= 600 s)
//   B5  in situ (the installed, visible agent): v1's budget exactly, >= 1 idle-life line (MOTION or WALK) and no dictation in the
//       window; a window that holds a dictation or no idle life is NOT RUN (exit 3), never PASS   (window >= 600 s)
// Exit: 0 PASS, 1 FAIL, 2 the measurement itself failed, 3 NOT RUN (B5 only).
let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
guard args.count >= 2, let pid = Int32(args[0]), pid > 0 else {
    fputs("Usage: clawd-measure-cpu PID STATE_DIRECTORY [--seconds N] [--json PATH] [--budget B1|B2|B3|B4|B5]\n", stderr); exit(2)
}
let window = option("--seconds").flatMap(Double.init) ?? 600
guard window >= 1, window <= 7200 else { fputs("bad --seconds\n", stderr); exit(2) }
let budgetName = option("--budget")
guard budgetName == nil || ["B1", "B2", "B3", "B4", "B5"].contains(budgetName!) else { fputs("bad --budget\n", stderr); exit(2) }
let root = URL(fileURLWithPath: args[1])

let budget = budgetName.flatMap(CPUBudget.init(rawValue:))
let minimumWindow = budget?.minimumWindow ?? 1
guard window >= minimumWindow else { fputs("--budget \(budgetName ?? "") needs --seconds of at least \(Int(minimumWindow))\n", stderr); exit(2) }

struct Report: Codable {
    var mode: String
    var budget: String?
    var duration_s: Double
    var pid_start: Int32
    var pid_end: Int32
    var start_time_start: String
    var start_time_end: String
    var state_log_idle_whole_window: Bool
    var cpu_delta_s: Double
    var wakeups_delta: UInt64
    var agent_sha256: String
    /// Renders the agent performed inside the window; null for modes that keep no render counter.
    var render_count_delta: Int?
    // v2: what the window's agent.log shows, and the timer gauge.
    var idle_motions: Int?
    var walks: Int?
    var look_changes: Int?
    var dictation_lines: Int?
    var timers_max_sampled: Int?
    var timers_max_lifetime: Int?
    var quiet_reason: String?
    var cpu_limit_s: Double?
    var wakeups_limit: UInt64?
    var result: String?
}
let renderMode = "test-idle-render-no-window"
func renderCount() throws -> UInt64 { try FileCounter.read(path: root.appendingPathComponent("renders.count").path) }
/// The armed-timer gauges exist only for the v2 render mode; a state directory without them (v1's) simply has none to sample.
func gauge(_ name: String) -> UInt64? { try? FileCounter.read(path: root.appendingPathComponent(name).path) }
func status() throws -> [String: Any] {
    let data = try ReadOnlyFile.data(root.appendingPathComponent("status.json").path)
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProcessFailure.lookup }
    return value
}
/// The agent shows its idle scene. The headless runs also say so with idleBudgetMode; the installed agent (B5) does not.
func idle(_ value: [String: Any], requireBudgetMode: Bool) -> Bool {
    (!requireBudgetMode || value["idleBudgetMode"] as? Bool == true) && value["scene"] as? String == "idle"
}
func lines(_ text: String, containing needle: String) -> [Substring] { text.split(separator: "\n").filter { $0.contains(needle) } }

do {
    let inSitu = budgetName == "B5"
    let begin = try status()
    guard idle(begin, requireBudgetMode: !inSitu) else { throw ProcessFailure.lookup }
    let log = try ReadOnlyFile(root.appendingPathComponent("agent.log").path)
    let offset = try log.metadata().st_size
    let path = try ProcessPath.of(pid: pid)
    let agentHash = SHA256.hash(data: try ReadOnlyFile.data(path, limit: 64 * 1024 * 1024)).map { String(format: "%02x", $0) }.joined()
    let rendering = begin["mode"] as? String == renderMode
    let rendersBefore = rendering ? try renderCount() : 0
    let first = try ProcessUsage.read(pid: pid)
    let start = ProcessInfo.processInfo.systemUptime
    var timersSampled: Int?
    if rendering, gauge("timers.armed") != nil {
        // Sleep in one-second steps and read the armed-timer gauge at each: the sampling is the measurement's, the agent does nothing for it.
        while ProcessInfo.processInfo.systemUptime - start < window {
            guard let armed = gauge("timers.armed") else { throw ProcessFailure.lookup }
            timersSampled = max(timersSampled ?? 0, Int(armed))
            Thread.sleep(forTimeInterval: min(1, max(0.01, window - (ProcessInfo.processInfo.systemUptime - start))))
        }
    } else {
        Thread.sleep(forTimeInterval: window)
    }
    let sampled = timersSampled
    let second = try ProcessUsage.read(pid: pid)
    let wall = ProcessInfo.processInfo.systemUptime - start
    let rendersAfter = rendering ? try renderCount() : 0
    let end = try status()
    guard wall >= window, idle(end, requireBudgetMode: !inSitu) else { throw ProcessFailure.lookup }
    guard rendersAfter >= rendersBefore else { throw ProcessFailure.lookup }
    let size = try log.metadata().st_size
    guard size >= offset, size - offset <= 64 * 1024 * 1024 else { throw ProcessFailure.lookup }
    // The descriptor still reads the file it opened at the start. A rotation in the window moved that file to agent.log.1 and the window's
    // later lines went to a new agent.log, which this read would never see: the measurement fails instead (amendment agent-log-retention).
    var now = stat(); let opened = try log.metadata()
    guard lstat(root.appendingPathComponent("agent.log").path, &now) == 0, now.st_ino == opened.st_ino, now.st_dev == opened.st_dev else {
        throw ProcessFailure.lookup
    }
    let changes = String(decoding: try log.read(offset: offset, count: Int(size - offset)), as: UTF8.self)
    // A dictation or an Aqua event in the window: a scene change or an accepted event.
    let dictation = lines(changes, containing: "STATE scene=").count + lines(changes, containing: "EVENT ").count
    let quiet = dictation == 0
    let motions = lines(changes, containing: "MOTION start").filter { $0.contains("use=idle") || $0.contains("use=signature:") }.count
    let walks = lines(changes, containing: "WALK start").count
    let looks = lines(changes, containing: "LOOK change").count
    var quietReason: String?
    if budgetName == "B3" {
        // The last QUIET line in the whole log says whether the condition still held at the end of the window.
        let whole = String(decoding: try log.read(offset: 0, count: Int(size)), as: UTF8.self)
        if let last = lines(whole, containing: "QUIET ").last, last.contains("QUIET on reason=") {
            quietReason = String(last).components(separatedBy: "reason=").last
        }
    }
    let delta = try second.delta(from: first)
    let renderDelta = rendering ? Int(rendersAfter - rendersBefore) : nil
    let timersMax = rendering ? gauge("timers.max").map { Int($0) } : nil
    var report = Report(mode: begin["mode"] as? String ?? "installed-agent", budget: budgetName, duration_s: wall, pid_start: first.identity.pid,
                        pid_end: second.identity.pid, start_time_start: "\(first.identity.seconds).\(first.identity.microseconds)",
                        start_time_end: "\(second.identity.seconds).\(second.identity.microseconds)",
                        state_log_idle_whole_window: quiet, cpu_delta_s: delta.seconds, wakeups_delta: delta.wakeups, agent_sha256: agentHash,
                        render_count_delta: renderDelta, idle_motions: motions, walks: walks, look_changes: looks, dictation_lines: dictation,
                        timers_max_sampled: sampled, timers_max_lifetime: timersMax, quiet_reason: quietReason,
                        cpu_limit_s: budget?.cpuLimit ?? CPUBudget.v1CPU, wakeups_limit: budget?.wakeupsLimit ?? CPUBudget.v1Wakeups, result: nil)

    let measurement = CPUBudget.Measurement(cpuSeconds: delta.seconds, wakeups: delta.wakeups, dictationLines: dictation, renderDelta: renderDelta,
                                            idleMotions: motions, walks: walks, lookChanges: looks, timersSampled: sampled,
                                            timersLifetime: timersMax, quietReason: quietReason)
    let verdict = budget?.judge(measurement) ?? CPUBudget.judgeV1(measurement)
    let pass = verdict == .pass, notRun = verdict == .notRun
    report.result = verdict.rawValue
    if let output = option("--json") {
        let destination = URL(fileURLWithPath: output)
        try OwnState(root: destination.deletingLastPathComponent()).writeJSON(report, to: destination.lastPathComponent)
    }
    let renders = renderDelta.map { " renders=\($0)" } ?? ""
    let life = " motions=\(motions) walks=\(walks) looks=\(looks)"
    print("\(report.result!) mode=\(report.mode) budget=\(budgetName ?? "v1") wall_seconds=\(wall) cpu_seconds=\(delta.seconds) idle_wakeups=\(delta.wakeups)\(renders)\(life) pid=\(pid) start=\(report.start_time_start) quiet_log=\(quiet)")
    exit(notRun ? 3 : (pass ? 0 : 1))
} catch {
    fputs("FAIL: missing process, changed identity, non-IDLE interval, agent.log rotated during the window, or unreadable measurement\n", stderr); exit(2)
}
