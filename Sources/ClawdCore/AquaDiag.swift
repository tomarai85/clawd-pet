import Foundation

/// `aqua-diag.log` (amendment D-5): one line per trigger paired with the reconcile it caused, in its own file so agent.log's rotation never
/// removes it. An application-list record that changed nothing and repeats, byte for byte, the last application-list record written in full
/// is counted, not written; the count goes out as one `kvo-repeat` line just before the next line of any kind (amendment aqua-diag-coalesce). It is written from the first start of a build that carries it until `until` (seven days later, kept in state.json) and
/// while the file is under `capBytes`; at the cap one last line says so and nothing is written, rotated or truncated after. The sequence
/// number continues from the file's last line across restarts.
public final class AquaDiag {
    public static let fileName = "aqua-diag.log"
    public static let window: TimeInterval = 7 * 86400
    public static let defaultCap = 1024 * 1024
    /// Room kept free for the cap line itself, so the file never grows past its cap.
    private static let reserve = 160
    public static let fieldLimit = 64

    private let store: OwnState
    private let until: Date
    private let now: () -> Date
    private let capBytes: Int
    private var sequence = 0
    private var size = 0
    private var stopped = false
    /// The UTF-8 bytes of the last application-list record written in full in this process, and the repeats of it counted since (none survive
    /// a restart).
    private var lastKvoBytes: [UInt8] = []
    private var pending = 0
    private var pendingFirst = Date.distantPast, pendingLast = Date.distantPast
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(store: OwnState, until: Date, now: @escaping () -> Date = { Date() }, capBytes: Int = AquaDiag.defaultCap) {
        self.store = store; self.until = until; self.now = now; self.capBytes = capBytes
        if let url = try? store.url(Self.fileName), let data = try? ReadOnlyFile.data(url.path, limit: 64 * 1024 * 1024) {
            size = data.count
            let tail = String(decoding: data.suffix(4096), as: UTF8.self)
            if let last = tail.split(separator: "\n").last, last.hasPrefix("#") {
                sequence = Int(last.dropFirst().prefix { $0.isNumber }) ?? 0
                if last.contains(" CAP ") { stopped = true }
            }
        }
    }

    /// Whether a line would be written now.
    public var isOpen: Bool { !stopped && now() < until }

    /// A value as one field: whitespace and control characters become underscores, the length is capped.
    public static func field(_ value: String?) -> String {
        guard let value else { return "nil" }
        let flat = String(value.unicodeScalars.map { $0.properties.isWhitespace || $0.value < 32 ? "_" : Character($0) })
        return String(flat.prefix(fieldLimit))
    }

    /// Appends `#<seq> <time> <body>`, or, for a `repeatable` body whose bytes equal the last application-list (`kvo`) body written in full,
    /// counts it. A pending count is written as `kvo-repeat count=<n> first=<append time> last=<append time>` before the next line; the
    /// line's own time is when it is written. A count still pending when the agent exits or the window closes is never written. A line
    /// that would leave no room for the cap line is replaced by the cap line.
    public func append(_ body: String, repeatable: Bool = false, kvo: Bool = false) {
        guard isOpen else { return }
        if repeatable, Array(body.utf8) == lastKvoBytes {
            let t = now()
            if pending == 0 { pendingFirst = t }
            pending += 1; pendingLast = t
            return
        }
        if pending > 0 {
            let line = "kvo-repeat count=\(pending) first=\(formatter.string(from: pendingFirst)) last=\(formatter.string(from: pendingLast))"
            pending = 0
            if !writeLine(line), stopped { return }
        }
        if writeLine(body), kvo || repeatable { lastKvoBytes = Array(body.utf8) }
    }

    /// Writes one line; false when it was not written (the cap line took its place, or the write failed).
    private func writeLine(_ body: String) -> Bool {
        let next = sequence + 1
        let stamp = formatter.string(from: now())
        let line = "#\(next) \(stamp) \(body)\n"
        let bytes = line.utf8.count
        if size + bytes + Self.reserve > capBytes {
            let capLine = "#\(next) \(stamp) CAP reached at \(size) bytes, diagnostics stopped\n"
            if size + capLine.utf8.count <= capBytes, (try? store.append(capLine, to: Self.fileName)) != nil {
                size += capLine.utf8.count; sequence = next
            }
            stopped = true
            return false
        }
        guard (try? store.append(line, to: Self.fileName)) != nil else { return false }
        size += bytes; sequence = next
        return true
    }
}
