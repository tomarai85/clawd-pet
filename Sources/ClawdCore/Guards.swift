import Foundation

/// Each member names one protective rule. Production always runs with `.all`;
/// only the negative-control tests switch a single rule off to prove it is load-bearing.
public struct GuardSet: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// On rename or delete of the log: drain the old descriptor, then read the new file from 0.
    public static let renameFollow = GuardSet(rawValue: 1 << 0)
    /// On a shorter file or an unmatched 64-byte fingerprint: seek to EOF.
    public static let fingerprintResync = GuardSet(rawValue: 1 << 1)
    /// Hold an unterminated tail until its newline arrives.
    public static let partialBuffer = GuardSet(rawValue: 1 << 2)
    /// Parse only exact keys; every other line (including `[error]` lines) is ignored.
    public static let allowlist = GuardSet(rawValue: 1 << 3)
    /// A log line older than 10 s never animates.
    public static let staleRule = GuardSet(rawValue: 1 << 4)
    /// PASTE_ACK counts only within 3 s after a completed-with-text and while no lease is open.
    public static let ackWindow = GuardSet(rawValue: 1 << 5)
    public static let all: GuardSet = [.renameFollow, .fingerprintResync, .partialBuffer, .allowlist, .staleRule, .ackWindow]
}
