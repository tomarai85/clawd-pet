import Foundation

public enum EventKind: Equatable {
    case start, lock, completed(Int), canceled, error, pasteAck(Bool), bootstrap, shutdown
}
public struct PetEvent: Equatable {
    public let kind: EventKind
    public let key: String
    public let lease: Int?
    public let timestamp: Date
    public init(_ kind: EventKind, key: String = "fixture", lease: Int? = nil, timestamp: Date) {
        self.kind = kind; self.key = key; self.lease = lease; self.timestamp = timestamp
    }
}

/// No transcript payload is retained, returned, rendered, or logged.
public final class EventParser {
    private let header = try! NSRegularExpression(pattern: #"^\[(\d{4}-[^\]]+Z)\] \[(\w+)\] +(?:\(([^)]*)\))? *(.*)$"#)
    private let fields = try! NSRegularExpression(pattern: #"(?:^|[\s,{])(?:"?)(lease_id|text_length|reason|success)(?:"?)\s*[:=]\s*(true|false|[A-Za-z0-9_]+)(?=[\s,}]|$)"#)
    private let iso = ISO8601DateFormatter()
    private var pendingACK: (Date, Int)?
    public var guards: GuardSet = .all
    public init() { iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
    public func reset() { pendingACK = nil }
    private func values(_ body: String) -> [String: String] {
        let ns = body as NSString
        return fields.matches(in: body, range: NSRange(location: 0, length: ns.length)).reduce(into: [:]) {
            $0[ns.substring(with: $1.range(at: 1))] = ns.substring(with: $1.range(at: 2))
        }
    }
    public func parse(_ line: String) -> PetEvent? {
        let ns = line as NSString
        guard let match = header.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            // Only a bounded ACK object may have continuations. Unknown multiline objects are inert.
            if let (date, count) = pendingACK, count < 16, line.utf8.count < 4096 {
                pendingACK = line.contains("}") ? nil : (date, count + 1)
                if let value = values(line)["success"], ["true", "false"].contains(value) {
                    pendingACK = nil
                    return PetEvent(.pasteAck(value == "true"), key: "PASTE_ACK", timestamp: date)
                }
            } else { pendingACK = nil }
            return nil
        }
        pendingACK = nil
        guard let date = iso.date(from: ns.substring(with: match.range(at: 1))) else { return nil }
        let level = ns.substring(with: match.range(at: 2))
        let source = match.range(at: 3).location == NSNotFound ? "" : ns.substring(with: match.range(at: 3))
        let body = ns.substring(with: match.range(at: 4))
        let key = String(body.prefix { !$0.isWhitespace })
        let v = values(body)
        let lease = v["lease_id"].flatMap(Int.init)
        func event(_ kind: EventKind, _ name: String? = nil) -> PetEvent {
            PetEvent(kind, key: name ?? key, lease: lease, timestamp: date)
        }
        // Negative-control mode only: without the allowlist any error-level line would look like a failure.
        if !guards.contains(.allowlist), level == "error" { return event(.error, "error_level_line") }
        if source == "IPCFloating", body.hasPrefix("PASTE_ACK received {") {
            if let value = v["success"], ["true", "false"].contains(value) {
                return event(.pasteAck(value == "true"), "PASTE_ACK")
            }
            if !body.contains("}") { pendingACK = (date, 0) }
            return nil
        }
        if source == "Main", key == "app.bootstrap" { return event(.bootstrap) }
        if source == "SystemBridge", body.hasPrefix("Shutdown initiated") { return event(.shutdown, "shutdown") }
        // Real forms: "[NativeAudioCaptureProvider] Audio capture stopped unexpectedly. ..." and "Error: Audio capture stopped ...".
        if source.isEmpty {
            var text = Substring(body)
            for prefix in ["[NativeAudioCaptureProvider] ", "Error: "] where text.hasPrefix(prefix) { text = text.dropFirst(prefix.count) }
            if text.hasPrefix("Audio capture stopped unexpectedly") { return event(.error, "audio_capture_stopped") }
            return nil
        }
        guard source.hasPrefix("Dictation") else { return nil }
        switch key {
        case "dictation.start_accepted": return lease.map { _ in event(.start) }
        case "dictation.lock_accepted": return lease.map { _ in event(.lock) }
        case "dictation.completed":
            guard lease != nil, let length = v["text_length"].flatMap(Int.init), length >= 0 else { return nil }
            return event(.completed(length))
        case "dictation.cancel_accepted", "dictation.completed_canceled", "dictation.completed_canceled_stale":
            return lease.map { _ in event(.canceled) }
        case "dictation.start_failed", "dictation.native_audio_capture_failed", "dictation.owner_lost_during_session":
            return event(.error)
        case "dictation.server_stop_received" where v["reason"] == "microphone_stopped": return event(.error)
        default: return nil
        }
    }
}
