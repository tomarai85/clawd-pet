import Foundation
import ClawdProcess
import Darwin

public enum ProcessFailure: Error { case enumeration, lookup, changed }
public struct ProcessIdentity: Equatable, Codable {
    public let pid: Int32
    public let uid: UInt32
    public let seconds: UInt64
    public let microseconds: UInt64
    init(_ value: ClawdIdentity) { pid = value.pid; uid = value.uid; seconds = value.seconds; microseconds = value.microseconds }
}
public enum OwnPids {
    public static var installPath: String {
        PetHome.stateRoot.appendingPathComponent("bin/clawd-pet-agent").path
    }
    public static func enumerate(path: String = installPath) throws -> [ProcessIdentity] {
        var result = [ClawdIdentity](repeating: ClawdIdentity(), count: 65536)
        let count = path.withCString { clawd_own_pids($0, &result, Int32(result.count)) }
        guard count >= 0 else { throw ProcessFailure.enumeration }
        return result.prefix(Int(count)).map(ProcessIdentity.init).sorted { $0.pid < $1.pid }
    }
    /// The words after `--own-pids`: none (the install path, as `bin/clawd-pet` asks) or one absolute path to look for instead. Anything else is
    /// refused with exit 2 and a line that names no path.
    public static func run(arguments: [String]) -> Int32 {
        switch arguments.count {
        case 0: return run()
        case 1 where arguments[0].hasPrefix("/"): return run(path: arguments[0])
        default:
            fputs("OWN-PIDS takes no argument or one absolute path\n", stderr)
            return 2
        }
    }

    public static func run(path: String = installPath) -> Int32 {
        do {
            let processes = try enumerate(path: path)
            for p in processes { print("PID \(p.pid) \(p.seconds) \(p.microseconds)") }
            print("OWN-PIDS \(processes.count)"); return 0
        } catch { fputs("OWN-PIDS enumeration failed\n", stderr); return 2 }
    }
}
public enum ProcessPath {
    public static func of(pid: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard clawd_pid_path(pid, &buffer, Int32(buffer.count)) == 0 else { throw ProcessFailure.lookup }
        return String(cString: buffer)
    }
}
public struct ProcessUsage {
    public let identity: ProcessIdentity
    public let cpuNanoseconds: UInt64
    public let wakeups: UInt64
    public static func read(pid: Int32) throws -> Self {
        var value = ClawdUsage()
        guard clawd_usage(pid, &value) == 0 else { throw ProcessFailure.lookup }
        return Self(identity: ProcessIdentity(value.identity), cpuNanoseconds: value.cpu_ns, wakeups: value.wakeups)
    }
    public func delta(from previous: Self) throws -> (seconds: Double, wakeups: UInt64) {
        guard identity == previous.identity, cpuNanoseconds >= previous.cpuNanoseconds, wakeups >= previous.wakeups else {
            throw ProcessFailure.changed
        }
        return (Double(cpuNanoseconds - previous.cpuNanoseconds) / 1_000_000_000, wakeups - previous.wakeups)
    }
}
public enum LaunchGuard {
    public static let label = "com.tomtim.clawd-pet"
    /// `launchctl list <label>` prints an OpenStep-like text whose last line is `};`, which is not a valid property list,
    /// so the PID key is read from the text itself.
    public static func accepts(service: String?, pid: Int32, record: Data?) -> Bool {
        guard service == label, let record, let text = String(data: record, encoding: .utf8) else { return false }
        if let range = text.range(of: #""PID"\s*=\s*(\d+)\s*;"#, options: .regularExpression) {
            let digits = text[range].filter(\.isNumber)
            return Int32(digits) == pid
        }
        // A strict property list (XML or OpenStep) is accepted as well.
        guard let plist = try? PropertyListSerialization.propertyList(from: record, format: nil) as? [String: Any] else { return false }
        if let recorded = plist["PID"] as? NSNumber { return recorded.int32Value == pid }
        if let recorded = plist["PID"] as? String { return Int32(recorded) == pid }
        return false
    }
    public static func allowed() -> Bool {
        guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label else { return false }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list", label]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return process.terminationStatus == 0 && accepts(service: label, pid: getpid(), record: data)
    }
}
