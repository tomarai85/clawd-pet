import Testing
import Foundation
import ClawdCore

/// The CPU budgets (spec 7, done-bar 3) as functions: each boundary is tested on both sides, and `scripts/check-cpu-evidence.py` is run
/// on evidence files that are built to fail one rule at a time.
@Suite("CPU budgets")
struct CPUBudgetSuite {
    private func m(cpu: Double = 0.05, wakeups: UInt64 = 0, dictation: Int = 0, renders: Int? = 100, motions: Int = 0, walks: Int = 0, looks: Int = 0,
                   sampled: Int? = nil, lifetime: Int? = nil, quiet: String? = nil) -> CPUBudget.Measurement {
        CPUBudget.Measurement(cpuSeconds: cpu, wakeups: wakeups, dictationLines: dictation, renderDelta: renders, idleMotions: motions, walks: walks,
                              lookChanges: looks, timersSampled: sampled, timersLifetime: lifetime, quietReason: quiet)
    }
    @Test func Budget_b1IsV1sBudgetExactly() {
        #expect(CPUBudget.b1.judge(m(cpu: 0.2999, wakeups: 599)) == .pass)
        #expect(CPUBudget.b1.judge(m(cpu: 0.3)) == .fail, "0.3 s is not under 0.3 s")
        #expect(CPUBudget.b1.judge(m(wakeups: 600)) == .fail)
        #expect(CPUBudget.b1.judge(m(renders: 0)) == .fail, "no render in the window means the render path was not measured")
        #expect(CPUBudget.b1.judge(m(dictation: 1)) == .fail)
        #expect(CPUBudget.b1.minimumWindow == 600)
    }
    @Test func Budget_b2IsOneAndAHalfSecondsAHourWithTheSeededScheduleInsideIt() {
        #expect(CPUBudget.b2.judge(m(cpu: 1.8, wakeups: 3599, motions: 10, walks: 1, looks: 1)) == .pass, "at most 1.8 s")
        #expect(CPUBudget.b2.judge(m(cpu: 1.81, motions: 10, walks: 1, looks: 1)) == .fail)
        #expect(CPUBudget.b2.judge(m(wakeups: 3600, motions: 10, walks: 1, looks: 1)) == .fail)
        #expect(CPUBudget.b2.judge(m(motions: 9, walks: 1, looks: 1)) == .fail, "fewer than 10 idle motions")
        #expect(CPUBudget.b2.judge(m(motions: 10, walks: 0, looks: 1)) == .fail, "no walk")
        #expect(CPUBudget.b2.judge(m(motions: 10, walks: 1, looks: 0)) == .fail, "no look change")
        #expect(CPUBudget.b2.judge(m(dictation: 1, motions: 10, walks: 1, looks: 1)) == .fail)
        #expect(CPUBudget.b2.minimumWindow == 3600)
    }
    @Test func Budget_b3NeedsNoRenderAtMostOneTimerAndAQuietConditionAtTheEnd() {
        func b3(cpu: Double = 0.01, renders: Int? = 0, sampled: Int? = 1, lifetime: Int? = 1, quiet: String? = "display-asleep") -> CPUBudget.Verdict {
            CPUBudget.b3.judge(m(cpu: cpu, wakeups: 5000, renders: renders, sampled: sampled, lifetime: lifetime, quiet: quiet))
        }
        #expect(b3() == .pass, "B3 names no wakeup limit")
        #expect(b3(cpu: 0.0499) == .pass)
        #expect(b3(cpu: 0.05) == .fail, "0.05 s is not under 0.05 s")
        #expect(b3(renders: 1) == .fail)
        #expect(b3(sampled: 2) == .fail, "two armed timers at one sample")
        #expect(b3(lifetime: 2) == .fail, "two armed timers at some time in the process's life")
        #expect(b3(sampled: nil, lifetime: nil) == .fail, "a missing gauge is a fail, never zero")
        #expect(b3(quiet: nil) == .fail, "no quiet condition held")
        #expect(b3(renders: nil) == .fail, "a mode without a render counter cannot show zero renders")
    }
    @Test func Budget_b4IsOneAndAHalfSecondsPerTenMinutes() {
        #expect(CPUBudget.b4.judge(m(cpu: 1.5, motions: 5)) == .pass)
        #expect(CPUBudget.b4.judge(m(cpu: 1.51, motions: 5)) == .fail)
        #expect(CPUBudget.b4.judge(m(motions: 4)) == .fail, "a lively window with no life measures nothing")
    }
    @Test func Budget_b5IsV1sBudgetAndAWindowWithADictationOrNoIdleLifeIsNotRun() {
        #expect(CPUBudget.b5.judge(m(cpu: 0.29, wakeups: 599, renders: nil, motions: 1)) == .pass)
        #expect(CPUBudget.b5.judge(m(cpu: 0.3, renders: nil, motions: 1)) == .fail)
        #expect(CPUBudget.b5.judge(m(wakeups: 600, renders: nil, walks: 1)) == .fail)
        #expect(CPUBudget.b5.judge(m(dictation: 2, renders: nil, motions: 3)) == .notRun, "a dictation: rerun, never PASS")
        #expect(CPUBudget.b5.judge(m(renders: nil, motions: 0, walks: 0)) == .notRun, "zero idle-life lines: rerun, never PASS")
        #expect(CPUBudget.b5.judge(m(cpu: 9, dictation: 2, renders: nil)) == .notRun)
    }
}

@Suite("check-cpu-evidence.py", .serialized)
struct CPUEvidenceCheckSuite {
    private static func report(_ budget: String, mode: String? = nil, _ change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var r: [String: Any] = [
            "mode": mode ?? (budget == "B5" ? "installed-agent" : "test-idle-render-no-window"), "budget": budget,
            "duration_s": budget == "B2" ? 3600.01 : 600.01, "pid_start": 4242, "pid_end": 4242,
            "start_time_start": "1792287122.783666", "start_time_end": "1792287122.783666", "state_log_idle_whole_window": true,
            "cpu_delta_s": 0.05, "wakeups_delta": 0, "agent_sha256": String(repeating: "ab", count: 32), "dictation_lines": 0,
            "idle_motions": 0, "walks": 0, "look_changes": 0, "render_count_delta": 160, "result": "PASS",
        ]
        switch budget {
        case "B2": r["idle_motions"] = 12; r["walks"] = 3; r["look_changes"] = 1; r["cpu_delta_s"] = 0.8
        case "B3": r["render_count_delta"] = 0; r["timers_max_sampled"] = 1; r["timers_max_lifetime"] = 1; r["quiet_reason"] = "display-asleep"; r["cpu_delta_s"] = 0.002
        case "B4": r["idle_motions"] = 13; r["walks"] = 4; r["look_changes"] = 1; r["cpu_delta_s"] = 0.4
        case "B5": r["idle_motions"] = 1; r["render_count_delta"] = NSNull(); r["cpu_delta_s"] = 0.1
        default: break
        }
        change(&r)
        return r
    }
    /// Writes the four headless files (and optionally B5) into a fresh directory with their conventional names, with `change` applied to one.
    private func files(_ changes: [String: (inout [String: Any]) -> Void] = [:], includeB5: Bool = false) throws -> [String] {
        let dir = try artifactStore().root
        var paths: [String] = []
        for (name, budget) in [("cpu-b1", "B1"), ("cpu-b2", "B2"), ("cpu-b3", "B3"), ("cpu-b4", "B4")] + (includeB5 ? [("cpu-b5-in-situ", "B5")] : []) {
            let r = Self.report(budget, changes[name] ?? { _ in })
            let url = dir.appendingPathComponent(name + ".json")
            try JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]).write(to: url)
            paths.append(url.path)
        }
        return paths
    }
    private func check(_ paths: [String]) throws -> Execution {
        try execute(URL(fileURLWithPath: "/usr/bin/python3"), ["-I", repository.appendingPathComponent("scripts/check-cpu-evidence.py").path] + paths, timeout: 30)
    }

    @Test func Evidence_aCompleteSetPassesAndAnyRuleBrokenFails() throws {
        let good = try check(try files(includeB5: true))
        #expect(good.code == 0, "\(good.output)")
        let cases: [(String, [String: (inout [String: Any]) -> Void], String)] = [
            ("B1 CPU over budget", ["cpu-b1": { $0["cpu_delta_s"] = 0.31 }], "breaks the B1 budget"),
            ("B1 wakeups at the limit", ["cpu-b1": { $0["wakeups_delta"] = 600 }], "idle wakeups"),
            ("B1 window too short", ["cpu-b1": { $0["duration_s"] = 599 }], "window"),
            ("B1 pid changed", ["cpu-b1": { $0["pid_end"] = 4243 }], "pid changed"),
            ("B1 start time changed", ["cpu-b1": { $0["start_time_end"] = "1.2" }], "start time changed"),
            ("B1 dictation in the window", ["cpu-b1": { $0["dictation_lines"] = 2 }], "dictation"),
            ("B1 no render", ["cpu-b1": { $0["render_count_delta"] = 0 }], "no render"),
            ("B2 CPU over 1.8 s", ["cpu-b2": { $0["cpu_delta_s"] = 1.9 }], "breaks the B2 budget"),
            ("B2 wakeups 3600", ["cpu-b2": { $0["wakeups_delta"] = 3600 }], "idle wakeups"),
            ("B2 window under an hour", ["cpu-b2": { $0["duration_s"] = 3000 }], "needs at least 3600"),
            ("B2 too few motions", ["cpu-b2": { $0["idle_motions"] = 9 }], "idle motions"),
            ("B2 no walk", ["cpu-b2": { $0["walks"] = 0 }], "no walk"),
            ("B2 no look change", ["cpu-b2": { $0["look_changes"] = 0 }], "no look change"),
            ("B3 a render in a quiet window", ["cpu-b3": { $0["render_count_delta"] = 3 }], "renders in a quiet window"),
            ("B3 two timers sampled", ["cpu-b3": { $0["timers_max_sampled"] = 2 }], "armed timers sampled"),
            ("B3 two timers in its life", ["cpu-b3": { $0["timers_max_lifetime"] = 2 }], "over the process's life"),
            ("B3 CPU 0.05", ["cpu-b3": { $0["cpu_delta_s"] = 0.05 }], "breaks the B3 budget"),
            ("B3 no quiet condition", ["cpu-b3": { $0["quiet_reason"] = NSNull() }], "no quiet condition"),
            ("B4 CPU over 1.5 s", ["cpu-b4": { $0["cpu_delta_s"] = 1.6 }], "breaks the B4 budget"),
            ("B4 no life", ["cpu-b4": { $0["idle_motions"] = 2 }], "needs at least 5"),
            ("a different agent build", ["cpu-b4": { $0["agent_sha256"] = String(repeating: "cd", count: 32) }], "different agent builds"),
            ("the tool's own verdict is FAIL", ["cpu-b1": { $0["result"] = "FAIL" }], "own verdict"),
            ("wrong mode", ["cpu-b1": { $0["mode"] = "test-idle-no-window" }], "headless render mode"),
            ("budget field disagrees with the file name", ["cpu-b1": { $0["budget"] = "B4" }], "file name says B1"),
        ]
        for (name, changes, needle) in cases {
            let run = try check(try files(changes))
            #expect(run.code == 1, "\(name): expected a failure, got \(run.code): \(run.output)")
            #expect(run.output.contains(needle), "\(name): the message names the broken rule (\(needle)): \(run.output)")
        }
    }
    @Test func Evidence_b5MustBeTheInstalledAgentWithIdleLifeAndNoDictation() throws {
        func b5(_ change: @escaping (inout [String: Any]) -> Void) throws -> Execution {
            let dir = try artifactStore().root
            let url = dir.appendingPathComponent("cpu-b5-in-situ.json")
            try JSONSerialization.data(withJSONObject: Self.report("B5", change)).write(to: url)
            return try check([url.path])
        }
        #expect(try b5({ _ in }).code == 0)
        #expect(try b5({ $0["cpu_delta_s"] = 0.3 }).code == 1)
        #expect(try b5({ $0["wakeups_delta"] = 600 }).code == 1)
        #expect(try b5({ $0["dictation_lines"] = 1 }).code == 1)
        #expect(try b5({ $0["idle_motions"] = 0; $0["walks"] = 0 }).output.contains("no idle-life line"))
        #expect(try b5({ $0["mode"] = "test-idle-render-no-window" }).output.contains("installed agent"))
        #expect(try b5({ $0["result"] = "NOT RUN" }).code == 1)
    }
    @Test func Evidence_missingOrDamagedFilesFailClosed() throws {
        let dir = try artifactStore().root
        #expect(try check([dir.appendingPathComponent("cpu-b1.json").path]).code == 1)
        let bad = dir.appendingPathComponent("cpu-b1.json")
        try Data("{ not json".utf8).write(to: bad)
        #expect(try check([bad.path]).code == 1)
        #expect(try check([]).code == 2)
    }
}
