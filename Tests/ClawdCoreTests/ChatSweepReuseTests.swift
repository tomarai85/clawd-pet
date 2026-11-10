import Testing
import Foundation
import Darwin
@testable import ClawdCore
import ClawdProcess

struct ChatSweepReuseTests {
    private func row(_ pid: Int32, start: UInt64, parent: Int32, group: Int32) -> ChatProc.Row {
        ChatProc.Row(identity: ProcessIdentity(ClawdIdentity(pid: pid, uid: getuid(), seconds: start, microseconds: 0)), parent: parent, group: group)
    }

    @Test func ChatSweepSet_aMembersPidReusedByAnotherProcessWithAChildAdoptsNeitherButARealDescendantIsStillAdopted() {
        var table: [ChatProc.Row] = []
        let set = ChatSweepSet(token: "t", pid: 100, identity: row(100, start: 1, parent: 1, group: 100).identity,
                               table: { table }, carriers: { _, _ in [] })
        // The child (100) and a helper it started (200, in its group).
        table = [row(100, start: 1, parent: 1, group: 100), row(200, start: 2, parent: 100, group: 100)]
        #expect(Set(set.grow(.tracking).map(\.pid)) == [100, 200])
        // 200 died; its pid went to an unrelated process (another start time, another group) that has a child. 100 started a real new process, 400.
        table = [row(100, start: 1, parent: 1, group: 100), row(200, start: 9, parent: 1, group: 555),
                 row(300, start: 10, parent: 200, group: 555), row(400, start: 11, parent: 100, group: 100)]
        let grown = set.grow(.tracking)
        #expect(Set(grown.map(\.pid)) == [100, 400], "got \(grown.map(\.pid).sorted())")
        #expect(!grown.contains { $0.pid == 200 || $0.pid == 300 })
    }
}

/// The CPU cost of one ChatSweepSet growth on this machine's process table, in both modes: `tracking` (what the live set does every second: a
/// readable environment without the token is read once per identity, a hidden one again only when its path changes) and `fresh` (what a stop,
/// the guard and the start sweep do: every environment of every non-member). Runs only when CLAWD_MEASURE_GROW names a result file.
struct ChatSweepCostMeasure {
    @Test func ChatSweepSet_growCostMeasure() throws {
        guard let out = ProcessInfo.processInfo.environment["CLAWD_MEASURE_GROW"] else { return }
        var lines: [String] = []
        for (name, mode) in [("tracking", ChatSweepSet.Mode.tracking), ("fresh", .fresh)] {
            let set = ChatSweepSet(token: "00000000-measure", pid: 1, identity: nil)
            _ = set.grow(mode)
            var millis: [Double] = []
            for _ in 0..<200 {
                let start = ProcessInfo.processInfo.systemUptime
                _ = set.grow(mode)
                millis.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            millis.sort()
            lines.append(String(format: "%@ processes=%d median_ms=%.2f p95_ms=%.2f max_ms=%.2f", name, ChatProc.table().count, millis[100], millis[189], millis[199]))
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }
}
