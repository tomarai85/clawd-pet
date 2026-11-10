import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop
import Darwin

// The focus-violation ledger (focus-violations.log): the agent appends to it, never creates it, never rotates it.
// None of these tests shows a window or activates anything; notifications are posted on private centers or recorded directly.

private let ledgerHeader = "LEDGER 1 born=1792000000 how=install\n"

private final class SyscallProbe {
    var writes = 0
    var fsyncs = 0
    var failFsync = false
    var failWrite = false
    var shortBy = 0
    var onWrite: (() -> Void)?
    var io: LedgerIO {
        LedgerIO(write: { fd, pointer, count in
            self.writes += 1
            self.onWrite?()
            if self.failWrite { errno = ENOSPC; return -1 }
            let wanted = count - self.shortBy
            return Darwin.write(fd, pointer, wanted)
        }, fsync: { fd in
            self.fsyncs += 1
            if self.failFsync { errno = EIO; return -1 }
            return Darwin.fsync(fd)
        })
    }
}

private func ledgerStore(header: String? = ledgerHeader, extra: String = "") throws -> OwnState {
    let store = try artifactStore()
    if let header { try store.write(Data((header + extra).utf8), to: FocusMonitor.ledgerFile) }
    return store
}
private func text(_ store: OwnState, _ name: String) -> String {
    guard let path = try? store.url(name).path, let data = try? ReadOnlyFile.data(path) else { return "" }
    return String(decoding: data, as: UTF8.self)
}
private let activation = NSApplication.didBecomeActiveNotification

@Suite("Focus-violation ledger", .serialized)
@MainActor
struct LedgerSuite {
    @Test func Ledger_aViolationWritesOneLineBeforeTheCounterPersists() throws {
        let store = try ledgerStore()
        let probe = SyscallProbe()
        store.ledgerIO = probe.io
        var counterOnDiskAtWrite: Int?
        var logHadViolationAtWrite = false
        probe.onWrite = {
            counterOnDiskAtWrite = (try? store.readJSON(AgentStatus.self, from: "status.json"))?.focusViolations ?? 0
            logHadViolationAtWrite = text(store, "agent.log").contains("FOCUS_VIOLATION")
        }
        let monitor = FocusMonitor(store: store, center: NotificationCenter())
        monitor.context = "click"
        monitor.record(activation)
        #expect(counterOnDiskAtWrite == 0, "the ledger line is written before status.json holds the new counter")
        #expect(!logHadViolationAtWrite, "and before the agent.log line")
        let lines = text(store, FocusMonitor.ledgerFile).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 3 && lines.first == String(ledgerHeader.dropLast()) && lines.last == "")
        let violation = (lines.dropFirst().first ?? "").split(separator: " ").map(String.init)
        #expect(violation.count == 6)
        #expect(Double(violation.first ?? "") != nil)
        #expect(Array(violation.dropFirst()) == ["VIOLATION", "n=1", "pid=\(getpid())", "trigger=click", "notification=\(activation.rawValue)"])
        #expect((try store.readJSON(AgentStatus.self, from: "status.json")).focusViolations == 1)
        #expect(probe.writes == 1)
    }

    @Test func Ledger_survivesLogRotationAndRestart() throws {
        let padding = String(repeating: "BOOT 1792000000.000000 pid=1 counter=0 violations=0\n", count: 14_000)
        #expect(padding.utf8.count > 512 * 1024)
        let store = try ledgerStore(extra: padding)
        let first = FocusMonitor(store: store, center: NotificationCenter())
        first.record(activation)
        let second = FocusMonitor(store: store, center: NotificationCenter())
        #expect(second.recordBoot())
        let all = text(store, FocusMonitor.ledgerFile)
        #expect(all.hasPrefix(ledgerHeader + "BOOT 1792000000.000000 pid=1"))
        #expect(all.contains(" VIOLATION n=1 "))
        let boots = all.split(separator: "\n").filter { $0.hasPrefix("BOOT ") }
        #expect(boots.count == 14_001)
        #expect(boots.last.map { $0.contains("counter=1 violations=1") } == true)
        #expect(!FileManager.default.fileExists(atPath: try store.url("focus-violations.log.1").path))
    }

    @Test func Ledger_failedAppendIsCountedLoggedAndDoesNotStopTheViolationPath() throws {
        let store = try ledgerStore()
        #expect(chmod(try store.url(FocusMonitor.ledgerFile).path, 0) == 0)
        let monitor = FocusMonitor(store: store, center: NotificationCenter())
        var handed = 0
        monitor.onViolation = { handed += 1 }
        monitor.record(activation)
        #expect(monitor.status.ledgerFailures == 1)
        #expect(monitor.status.focusViolations == 1); #expect(handed == 1)
        let log = text(store, "agent.log")
        #expect(log.contains("FOCUS_VIOLATION_LEDGER_FAILED errno=13"))
        #expect(log.contains("FOCUS_VIOLATION trigger=launch"))
        let onDisk = try store.readJSON(AgentStatus.self, from: "status.json")
        #expect(onDisk.ledgerFailures == 1); #expect(onDisk.focusViolations == 1)
        chmod(try store.url(FocusMonitor.ledgerFile).path, 0o600)
    }

    @Test func Ledger_fsyncIsCalledAndItsFailureIsCounted() throws {
        let store = try ledgerStore()
        let probe = SyscallProbe()
        store.ledgerIO = probe.io
        let monitor = FocusMonitor(store: store, center: NotificationCenter())
        monitor.record(activation)
        #expect(probe.fsyncs == 1, "one fsync per appended line")
        #expect(monitor.status.ledgerFailures == nil)
        probe.failFsync = true
        monitor.record(activation)
        #expect(probe.fsyncs == 2)
        #expect(monitor.status.ledgerFailures == 1, "a failed fsync is a failed append even though the bytes are present")
        #expect(text(store, FocusMonitor.ledgerFile).components(separatedBy: " VIOLATION ").count == 3)
        #expect(text(store, "agent.log").contains("FOCUS_VIOLATION_LEDGER_FAILED errno=\(EIO)"))
        #expect(monitor.status.focusViolations == 2)
    }

    @Test func Ledger_shortWriteIsRejectedAndCounted() throws {
        let store = try ledgerStore()
        let probe = SyscallProbe()
        probe.shortBy = 7
        store.ledgerIO = probe.io
        let monitor = FocusMonitor(store: store, center: NotificationCenter())
        monitor.record(activation)
        #expect(probe.writes == 1, "a short write is not retried")
        #expect(monitor.status.ledgerFailures == 1)
        #expect(monitor.status.focusViolations == 1)
        #expect(!text(store, FocusMonitor.ledgerFile).hasSuffix("\n"), "the torn bytes stay in the file")
        #expect(text(store, "agent.log").contains("FOCUS_VIOLATION_LEDGER_FAILED"))
        #expect(throws: LedgerFailure.self) { try store.appendLedger("x\n", to: FocusMonitor.ledgerFile) }
    }

    @Test func Ledger_bootWriteFailureIsLoggedAndDoesNotStopTheAgent() throws {
        // (a) no ledger at all: the BOOT cannot be written; (b) the write itself fails.
        for variant in ["missing", "write-fails"] {
            let store = try ledgerStore(header: variant == "missing" ? nil : ledgerHeader)
            if variant == "write-fails" { let probe = SyscallProbe(); probe.failWrite = true; store.ledgerIO = probe.io }
            let host = AppKitBootHost(root: store.root, store: store)
            try host.registerFocusObservers()    // does not throw: the agent starts
            let log = text(store, "agent.log")
            #expect(log.contains("LEDGER_BOOT_FAILED errno="), "\(variant)")
            #expect(!log.contains("LEDGER_BOOT_SYNC_FAILED"), "\(variant)")
            let status = try? store.readJSON(AgentStatus.self, from: "status.json")
            #expect(status?.ledgerFailures == nil, "\(variant): a failed BOOT is not a violation failure")
            let monitor = FocusMonitor(store: store, center: NotificationCenter())
            #expect(monitor.recordBoot() == false)
            #expect((monitor.status.ledgerFailures ?? 0) == 0, "\(variant)")
            #expect(!text(store, FocusMonitor.ledgerFile).contains("BOOT "), "\(variant): no BOOT bytes")
        }
    }

    @Test func Ledger_bootSyncFailureKeepsTheReadableBootAndIsLogged() throws {
        let store = try ledgerStore()
        let probe = SyscallProbe()
        probe.failFsync = true
        store.ledgerIO = probe.io
        let monitor = FocusMonitor(store: store, center: NotificationCenter())
        #expect(monitor.recordBoot() == true)
        #expect(text(store, FocusMonitor.ledgerFile).contains("BOOT "), "the complete BOOT line is in the file")
        let log = text(store, "agent.log")
        #expect(log.contains("LEDGER_BOOT_SYNC_FAILED errno=\(EIO)"))
        #expect(!log.contains("LEDGER_BOOT_FAILED"))
        #expect((monitor.status.ledgerFailures ?? 0) == 0)
        // and the agent starts
        let host = AppKitBootHost(root: store.root, store: store)
        try host.registerFocusObservers()
    }

    @Test func Ledger_bootAfterATornTailStartsOnANewLine() throws {
        let store = try ledgerStore(extra: "BOOT 1792000001.000000 pid=2 coun")
        let monitor = FocusMonitor(store: store, center: NotificationCenter())
        #expect(monitor.recordBoot())
        let lines = text(store, FocusMonitor.ledgerFile).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 4 && lines.dropFirst().first == "BOOT 1792000001.000000 pid=2 coun", "the torn tail is sealed as its own line")
        #expect(lines.dropFirst(2).first.map { $0.hasPrefix("BOOT ") && $0.contains(" pid=\(getpid()) counter=0 violations=0") } == true)
        // a clean tail gets no extra newline
        #expect(monitor.recordBoot())
        #expect(!text(store, FocusMonitor.ledgerFile).contains("\n\n"))
    }

    @Test func Ledger_agentNeverCreatesAMissingLedger() throws {
        let store = try ledgerStore(header: nil)
        let monitor = FocusMonitor(store: store, center: NotificationCenter())
        monitor.record(activation)
        #expect(monitor.recordBoot() == false)
        #expect(!FileManager.default.fileExists(atPath: try store.url(FocusMonitor.ledgerFile).path))
        #expect(monitor.status.ledgerFailures == 1)
    }

    @Test func Ledger_bootLineCarriesPidCounterAndLedgerCount() throws {
        let prior = "1792000002.000000 VIOLATION n=1 pid=3 trigger=launch notification=X\n1792000003.000000 VIOLATION n=2 pid=3 trigger=click notification=Y\n"
        let store = try ledgerStore(extra: prior)
        var status = AgentStatus(); status.focusViolations = 2
        try store.writeJSON(status, to: "status.json")
        let monitor = FocusMonitor(store: store, center: NotificationCenter())
        #expect(monitor.recordBoot())
        let boot = try #require(text(store, FocusMonitor.ledgerFile).split(separator: "\n").last.map(String.init))
        let parts = boot.split(separator: " ").map(String.init)
        #expect(parts.count == 5 && parts[0] == "BOOT" && Double(parts[1]) != nil)
        #expect(Array(parts.dropFirst(2)) == ["pid=\(getpid())", "counter=2", "violations=2"])
    }

    @Test func Ledger_refusesSymlink() throws {
        let store = try ledgerStore(header: nil)
        let target = try store.url("elsewhere.txt")
        try Data("untouched\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: store.root.appendingPathComponent(FocusMonitor.ledgerFile).path, withDestinationPath: target.path)
        let monitor = FocusMonitor(store: store, center: NotificationCenter())
        monitor.record(activation)
        #expect(monitor.recordBoot() == false)
        #expect(monitor.status.ledgerFailures == 1)
        #expect(text(store, "elsewhere.txt") == "untouched\n", "nothing was written through the link")
    }

    @Test func Ledger_oldStatusJSONWithoutNewKeysDecodes() throws {
        let old = #"{"focusViolations":3,"wakeCount":1,"displayChangeCount":0,"scene":"idle","sourceBEnabled":false,"idleBudgetMode":false,"pid":42}"#
        let status = try JSONDecoder().decode(AgentStatus.self, from: Data(old.utf8))
        #expect(status.focusViolations == 3); #expect(status.ledgerFailures == nil)
        var newer = status; newer.ledgerFailures = 2
        let again = try JSONDecoder().decode(AgentStatus.self, from: try JSONEncoder().encode(newer))
        #expect(again.ledgerFailures == 2)
        // an older build reads a newer file: unknown keys are ignored by its decoder, modelled here by a struct without the key
        struct Older: Codable { var focusViolations = 0; var pid: Int32? }
        let json = try JSONEncoder().encode(newer)
        #expect(try JSONDecoder().decode(Older.self, from: json).focusViolations == 3)
    }
}
