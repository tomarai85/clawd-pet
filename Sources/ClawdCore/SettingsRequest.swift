import Foundation
import Darwin

/// `$ROOT/open-settings` (design 2.2, rev 3.1 M4): one line a process leaves for the next one, asking it to open Settings. A Settings row that needs
/// a restart writes it before the CLI runs; the restarted agent reads it, removes it and judges it. This file is the parse and the judgment, both
/// pure; the write and the remove go through OwnState, and the clocks and the process table are seams.
public struct SettingsRequest: Equatable {
    public static let fileName = "open-settings"
    public static let sizeLimit = 256
    /// A request older than this (this process's CLOCK_MONOTONIC minus the writer's) is dropped.
    public static let maxAgeNanoseconds: UInt64 = 30_000_000_000
    public static let originFrontdoor = "frontdoor"
    public static let originSettingsRestart = "settings-restart"
    public static let knownOrigins = [originFrontdoor, originSettingsRestart]
    /// Settings' section ids, as the window spells them.
    public static let sections = ["general", "look", "motion", "bubble", "voice", "claude-code", "about"]

    /// `kern.boottime` as `<seconds>.<6-digit microseconds>`.
    public struct Boot: Equatable {
        public var seconds: Int64
        public var microseconds: Int32
        public init(seconds: Int64, microseconds: Int32) { self.seconds = seconds; self.microseconds = microseconds }
        public var text: String { "\(seconds)." + String(format: "%06d", Int(microseconds)) }
    }

    public var origin: String
    public var pid: Int32
    public var mono: UInt64
    public var boot: Boot
    public var section: String?

    public init(origin: String, pid: Int32, mono: UInt64, boot: Boot, section: String? = nil) {
        self.origin = origin; self.pid = pid; self.mono = mono; self.boot = boot; self.section = section
    }

    /// The file's line, ending in one newline.
    public var line: String {
        "v=1 origin=\(origin) pid=\(pid) mono=\(mono) boot=\(boot.text)" + (section.map { " section=\($0)" } ?? "") + "\n"
    }

    /// The request a text holds, or nil for any other form: at most 256 bytes, one line, the fields in order, one space between them, numbers
    /// in plain decimal, a known section. Whether the origin is a known one is the judge's question.
    public static func parse(_ data: Data) -> SettingsRequest? {
        guard !data.isEmpty, data.count <= sizeLimit, var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasSuffix("\n") { text.removeLast() }
        guard !text.contains("\n"), !text.contains("\r") else { return nil }
        let fields = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5 || fields.count == 6, fields[0] == "v=1" else { return nil }
        guard let origin = value(fields[1], "origin"), origin.count >= 1, origin.count <= 24,
              origin.allSatisfy({ ($0 >= "a" && $0 <= "z") || $0 == "-" }) else { return nil }
        guard let pidText = value(fields[2], "pid"), let pid = plain(pidText), pid > 0, pid <= UInt64(Int32.max) else { return nil }
        guard let monoText = value(fields[3], "mono"), let mono = plain(monoText) else { return nil }
        guard let bootText = value(fields[4], "boot"), let boot = bootTime(bootText) else { return nil }
        var section: String?
        if fields.count == 6 {
            guard let named = value(fields[5], "section"), sections.contains(named) else { return nil }
            section = named
        }
        return SettingsRequest(origin: origin, pid: Int32(pid), mono: mono, boot: boot, section: section)
    }

    private static func value(_ field: String, _ name: String) -> String? {
        let prefix = name + "="
        guard field.hasPrefix(prefix) else { return nil }
        return String(field.dropFirst(prefix.count))
    }

    /// A decimal number with no sign, no space and no leading zero.
    private static func plain(_ text: String) -> UInt64? {
        guard !text.isEmpty, text.count <= 20, text.allSatisfy({ $0 >= "0" && $0 <= "9" }), text == "0" || text.first != "0" else { return nil }
        return UInt64(text)
    }

    private static func bootTime(_ text: String) -> Boot? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[1].count == 6, parts[1].allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let seconds = plain(parts[0]), seconds <= UInt64(Int64.max), let micro = Int32(parts[1]) else { return nil }
        return Boot(seconds: Int64(seconds), microseconds: micro)
    }
}

/// What the process asks of the machine: its own pid, its CLOCK_MONOTONIC reading, this boot's `kern.boottime` and whether a pid is the pet.
/// The wall clock is not among them: a request's age is never read from it.
public struct SettingsRequestSeams {
    public var ownPid: () -> Int32
    public var monotonicNanoseconds: () -> UInt64
    public var boot: () -> SettingsRequest.Boot?
    /// A process with this pid exists and its executable is the pet's own.
    public var runsAsPet: (Int32) -> Bool
    public init(ownPid: @escaping () -> Int32, monotonicNanoseconds: @escaping () -> UInt64, boot: @escaping () -> SettingsRequest.Boot?,
                runsAsPet: @escaping (Int32) -> Bool) {
        self.ownPid = ownPid; self.monotonicNanoseconds = monotonicNanoseconds; self.boot = boot; self.runsAsPet = runsAsPet
    }

    /// Nothing is readable and no pid is the pet: a rig that names none of the seams writes and honours nothing by accident.
    public static let inert = SettingsRequestSeams(ownPid: { 1 }, monotonicNanoseconds: { 0 }, boot: { nil }, runsAsPet: { _ in false })

    public static let system = SettingsRequestSeams(
        ownPid: { ProcessInfo.processInfo.processIdentifier },
        monotonicNanoseconds: { clock_gettime_nsec_np(CLOCK_MONOTONIC) },
        boot: {
            var value = timeval()
            var size = MemoryLayout<timeval>.size
            guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return nil }
            return SettingsRequest.Boot(seconds: Int64(value.tv_sec), microseconds: Int32(value.tv_usec))
        },
        runsAsPet: { pid in (try? ProcessPath.of(pid: pid)) == OwnPids.installPath })
}

/// The judgment of a request read at boot.
public enum SettingsRequestVerdict: Equatable {
    /// No request file.
    case none
    /// The request passes; the caller decides what its origin may do.
    case pass(origin: String, section: String?)
    /// The request opens nothing; `reason` is the word of the `SETTINGS request dropped` line.
    case dropped(reason: String)
}

public enum SettingsRequestFile {
    /// Reads and removes the request, then judges it. A file that cannot be read is removed all the same; a request is read once.
    public static func take(store: OwnState, seams: SettingsRequestSeams) -> SettingsRequestVerdict {
        // OwnState refuses a link in the file's place: that is a request of no valid form, and it is never followed.
        let raw = store.root.appendingPathComponent(SettingsRequest.fileName).path
        var info = stat()
        guard lstat(raw, &info) == 0 else { return .none }
        guard let path = try? store.url(SettingsRequest.fileName).path else { remove(store: store); return .dropped(reason: "form") }
        let data = try? ReadOnlyFile.data(path, limit: SettingsRequest.sizeLimit)
        remove(store: store)
        return judge(data.flatMap(SettingsRequest.parse), seams: seams)
    }

    /// The rules of 2.2, in this order: the form, the origin, this boot, an age from 0 up to but not including 30 s on CLOCK_MONOTONIC, and for
    /// `settings-restart` a writer that is gone.
    public static func judge(_ request: SettingsRequest?, seams: SettingsRequestSeams) -> SettingsRequestVerdict {
        guard let request else { return .dropped(reason: "form") }
        guard SettingsRequest.knownOrigins.contains(request.origin) else { return .dropped(reason: "origin") }
        guard let boot = seams.boot(), boot == request.boot else { return .dropped(reason: "boot") }
        let now = seams.monotonicNanoseconds()
        guard now >= request.mono else { return .dropped(reason: "future") }
        guard now - request.mono < SettingsRequest.maxAgeNanoseconds else { return .dropped(reason: "old") }
        if request.origin == SettingsRequest.originSettingsRestart, seams.runsAsPet(request.pid) { return .dropped(reason: "writer") }
        return .pass(origin: request.origin, section: request.section)
    }

    /// Writes this process's request through OwnState and returns the line it wrote. Nil when the write failed or this boot's time is unreadable
    /// (no request is then left).
    @discardableResult
    public static func leave(store: OwnState, origin: String, section: String, seams: SettingsRequestSeams) -> String? {
        guard let boot = seams.boot() else { return nil }
        let request = SettingsRequest(origin: origin, pid: seams.ownPid(), mono: seams.monotonicNanoseconds(), boot: boot, section: section)
        return (try? store.write(Data(request.line.utf8), to: SettingsRequest.fileName)) != nil ? request.line : nil
    }

    public static func remove(store: OwnState) { try? store.removeFile(SettingsRequest.fileName) }

    /// Removes the request only while the file still holds the line this process wrote: a later pick's request is not an earlier pick's to remove.
    public static func remove(store: OwnState, ifLine line: String) {
        guard let path = try? store.url(SettingsRequest.fileName).path,
              let data = try? ReadOnlyFile.data(path, limit: SettingsRequest.sizeLimit), data == Data(line.utf8) else { return }
        remove(store: store)
    }
}
